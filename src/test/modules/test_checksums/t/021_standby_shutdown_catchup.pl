# Copyright (c) 2026, PostgreSQL Global Development Group

# Test a standby stopped after replaying an online enable, but before the
# checkpoint record that follows it on the primary.
#
# The shutdown restartpoint has no new checkpoint record to work from and is
# skipped, so the control file would keep the in-progress state the transition
# passed through, even though replay left the node at "on" and rewrote every
# page.  pg_checksums reads that field and refuses to run on an in-progress
# state, so the shutdown has to flush and catch it up instead.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin;
use lib $FindBin::RealBin;

use DataChecksums::Utils;

if ($ENV{enable_injection_points} ne 'yes')
{
	plan skip_all => 'Injection points not supported by this build';
}

my $primary = PostgreSQL::Test::Cluster->new('primary');
$primary->init(allows_streaming => 1, no_data_checksums => 1);
$primary->append_conf(
	'postgresql.conf', qq(
autovacuum = off
checkpoint_timeout = 1h
max_wal_size = 10GB
));
$primary->start;

$primary->safe_psql('postgres', 'CREATE EXTENSION injection_points;');
$primary->safe_psql('postgres',
	'CREATE TABLE t AS SELECT generate_series(1,10000) AS a;');

$primary->backup('backup');
my $standby = PostgreSQL::Test::Cluster->new('standby');
$standby->init_from_backup($primary, 'backup', has_streaming => 1);
$standby->append_conf(
	'postgresql.conf', qq(
checkpoint_timeout = 1h
max_wal_size = 10GB
));
$standby->start;
$primary->wait_for_catchup($standby);

# Anchor the standby's last restartpoint here, so that nothing replayed from
# now on gives the shutdown restartpoint a newer checkpoint record to use.
$primary->safe_psql('postgres', 'CHECKPOINT;');
$primary->wait_for_catchup($standby);
$standby->safe_psql('postgres', 'CHECKPOINT;');

# Hold the enable right after the state change record, before the checkpoint
# it requests once the transition is complete.
$primary->safe_psql('postgres',
	"SELECT injection_points_attach('datachecksums-on-before-checkpoint','wait');"
);
enable_data_checksums($primary);
$primary->poll_query_until('postgres',
	"SELECT count(*) > 0 FROM pg_stat_activity WHERE wait_event = 'datachecksums-on-before-checkpoint';"
) or die 'timed out waiting for the injection point';
wait_for_checksum_state($primary, 'on');

# Flush the state change record out to the standby without writing a
# checkpoint record of any kind.
$primary->safe_psql('postgres', 'CREATE TABLE flush_marker (a int);');
$primary->wait_for_catchup($standby);
wait_for_checksum_state($standby, 'on');

$standby->stop;

my $ctl = `pg_controldata -D @{[ $standby->data_dir ]}`;
my ($state) = $ctl =~ /Data page checksum version:\s+(\d+)/;
is($state, '1',
	'shutdown catches the control file up with the replayed state');

command_ok([ 'pg_checksums', '--check', '-D', $standby->data_dir ],
	'pg_checksums verifies the stopped standby');

$primary->safe_psql('postgres',
	"SELECT injection_points_wakeup('datachecksums-on-before-checkpoint');");
$primary->safe_psql('postgres',
	"SELECT injection_points_detach('datachecksums-on-before-checkpoint');");
$primary->stop;

done_testing();
