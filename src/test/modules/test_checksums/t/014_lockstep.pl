# Copyright (c) 2026, PostgreSQL Global Development Group

# The lockstep procedure for offline checksum changes in a replication
# setup: stop all nodes, run pg_checksums on all of them, restart.
# Replay of checkpoint records written before the change must not
# revert the state of the standby.
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
$primary->append_conf(
	'postgresql.conf', qq[
autovacuum = off
wal_keep_size = '1GB'
]);
$primary->start;
$primary->safe_psql('postgres',
	"CREATE TABLE t AS SELECT generate_series(1,10000) AS a;");

$primary->backup('backup');
my $standby = PostgreSQL::Test::Cluster->new('standby');
$standby->init_from_backup($primary, 'backup', has_streaming => 1);
$standby->start;
$primary->wait_for_catchup($standby);

# Stop the standby first: the WAL written after this point is replayed
# only after the offline switch, and every checkpoint record in it
# still carries the old state.
$standby->stop;
$primary->safe_psql('postgres', "UPDATE t SET a = a WHERE a % 10 = 0;");
$primary->safe_psql('postgres', "CHECKPOINT;");
$primary->safe_psql('postgres', "UPDATE t SET a = a WHERE a % 10 = 1;");
$primary->safe_psql('postgres', "CHECKPOINT;");
$primary->stop;

# The lockstep procedure.
$primary->checksum_enable_offline;
$standby->checksum_enable_offline;
$primary->start;
$standby->start;

# The standby replays the pre-switch checkpoints; its state must not
# revert to off.
$primary->wait_for_catchup($standby);
$standby->wait_for_log(
	qr/does not match the state "off" in the replayed WAL/, 0);
test_checksum_state($standby, 'on');
test_checksum_state($primary, 'on');

is( $standby->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'10000', 'standby readable after lockstep enable');

# Crash the standby and replay the same stretch again.
$standby->stop('immediate');
$standby->start;
$primary->wait_for_catchup($standby);
test_checksum_state($standby, 'on');
is( $standby->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'10000', 'standby readable after crash restart');

# Once a post-switch checkpoint has been replayed the states match and
# no warning may be logged.
my $logstart = -s $standby->logfile;
$primary->safe_psql('postgres', "CHECKPOINT;");
$primary->wait_for_catchup($standby);
my $log = PostgreSQL::Test::Utils::slurp_file($standby->logfile, $logstart);
unlike(
	$log,
	qr/does not match the state/,
	'no mismatch warning once the states match');

# Every page the standby wrote in this window must carry a checksum.
$standby->safe_psql('postgres', 'CHECKPOINT;');
$standby->stop;
command_ok([ 'pg_checksums', '--check', '-D', $standby->data_dir ],
	'checksums valid on the standby');

$primary->stop;
done_testing();
