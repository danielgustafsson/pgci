# Copyright (c) 2026, PostgreSQL Global Development Group

# Test that a base backup taken from a standby keeps the standby's data
# checksum state.
#
# A backup taken on a standby uses the last restartpoint as its starting
# checkpoint (do_pg_backup_start()), so the record at the redo point was
# written by the upstream primary and carries the primary's state.  Recovery
# from such a backup must not adopt that state: the files were copied from
# the standby, and with the standby diverged to "off" under an "on" primary
# the new node would come up verifying checksums its files do not have.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin;
use lib $FindBin::RealBin;

use DataChecksums::Utils;

my $primary = PostgreSQL::Test::Cluster->new('primary');
$primary->init(allows_streaming => 1, no_data_checksums => 1);
$primary->append_conf('postgresql.conf', 'autovacuum = off');
$primary->start;
$primary->safe_psql('postgres',
	"CREATE TABLE t AS SELECT generate_series(1,10000) AS a;");

$primary->backup('backup');
my $standby = PostgreSQL::Test::Cluster->new('standby');
$standby->init_from_backup($primary, 'backup', has_streaming => 1);
$standby->start;
$primary->wait_for_catchup($standby);

test_checksum_state($primary, 'off');
test_checksum_state($standby, 'off');

# Offline enable on the primary only.  Per 012_offline_standby.pl this is a
# divergence the standby is expected to survive: it keeps its own "off"
# state, warns once, and stays readable.
$standby->stop;
$primary->stop;
system_or_bail('pg_checksums', '--enable', '--pgdata', $primary->data_dir);
$primary->start;
$standby->start;
$primary->wait_for_catchup($standby);

test_checksum_state($primary, 'on');
test_checksum_state($standby, 'off');

# Make sure the standby has written pages under its own "off" state, so its
# files really do lack checksums.
$primary->safe_psql('postgres',
	"CREATE TABLE t2 AS SELECT generate_series(1,50000) AS a;");
$primary->safe_psql('postgres', "CHECKPOINT;");
$primary->wait_for_catchup($standby);
$standby->safe_psql('postgres', "SELECT count(*) FROM t2;");

# Now take a base backup *from the standby* and bring the copy up.
$standby->backup('from_standby');
my $newnode = PostgreSQL::Test::Cluster->new('newnode');
$newnode->init_from_backup($standby, 'from_standby', has_streaming => 1);
$newnode->append_conf('postgresql.conf',
	"primary_conninfo = '" . $primary->connstr . "'");
$newnode->start;

# The new node's files all came from a cluster running with checksums off.
# Anything but "off" here means it adopted the primary's state through the
# checkpoint record at the redo point.
my ($rc, $stdout, $stderr) = $newnode->psql('postgres',
	"SELECT setting FROM pg_settings WHERE name = 'data_checksums';");
is($rc, 0, 'the node copied from the standby accepts connections')
  or diag("stderr: $stderr");
is($stdout, 'off', 'backup of an "off" standby comes up with checksums off');

# And it must be able to read the pages the standby wrote without checksums.
($rc, $stdout, $stderr) =
  $newnode->psql('postgres', "SELECT count(*) FROM t2;");
is($rc, 0, 'pages copied from the standby are readable')
  or diag("stderr: $stderr");

my $log = PostgreSQL::Test::Utils::slurp_file($newnode->logfile);
unlike($log, qr/page verification failed/,
	'no checksum verification failures on the node copied from the standby');

$newnode->stop('immediate');

print "# newnode pg_control: "
  . `pg_controldata -D @{[ $newnode->data_dir ]} | grep 'Data page checksum'`;

$standby->stop;
$primary->stop;

done_testing();
