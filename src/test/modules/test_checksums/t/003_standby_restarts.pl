
# Copyright (c) 2026, PostgreSQL Global Development Group

# Test suite for testing enabling data checksums in an online cluster with
# streaming replication
use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin;
use lib $FindBin::RealBin;

use DataChecksums::Utils;

# Initialize primary node
my $node_primary = PostgreSQL::Test::Cluster->new('standby_restarts_primary');
$node_primary->init(allows_streaming => 1, no_data_checksums => 1);
$node_primary->start;

my $slotname = 'physical_slot';
$node_primary->safe_psql('postgres',
	"SELECT pg_create_physical_replication_slot('$slotname')");

# Take backup
my $backup_name = 'my_backup';
$node_primary->backup($backup_name);

# Create streaming standby linking to primary
my $node_standby = PostgreSQL::Test::Cluster->new('standby_restarts_standby');
$node_standby->init_from_backup($node_primary, $backup_name,
	has_streaming => 1);
$node_standby->append_conf(
	'postgresql.conf', qq[
primary_slot_name = '$slotname'
]);
$node_standby->start;

# Create some content on the primary to have un-checksummed data in the cluster
$node_primary->safe_psql('postgres',
	"CREATE TABLE t AS SELECT generate_series(1,10000) AS a;");

# Wait for standby to catch up
$node_primary->wait_for_catchup($node_standby, 'replay',
	$node_primary->lsn('insert'));

# Check that checksums are turned off on all nodes
test_checksum_state($node_primary, 'off');
test_checksum_state($node_standby, 'off');

# ---------------------------------------------------------------------------
# Enable checksums for the cluster, and make sure that both the primary and
# standby change state.
#

# Initiate enabling of checksums and ensure that the primary switches to
# either "inprogress-on" or "on"
enable_data_checksums($node_primary);
my $result = $node_primary->poll_query_until(
	'postgres',
	"SELECT setting = 'off' FROM pg_catalog.pg_settings WHERE name = 'data_checksums';",
	'f');
is($result, 1, 'ensure primary has transitioned from off');
# Wait for checksum enable to be replayed
$node_primary->wait_for_catchup($node_standby, 'replay');

# Ensure that the standby has switched to "inprogress-on" or "on".  Normally it
# would be "inprogress-on", but it is theoretically possible for the primary to
# complete the checksum enabling *and* have the standby replay that record
# before we reach the check below.
$result = $node_standby->poll_query_until(
	'postgres',
	"SELECT setting = 'off' FROM pg_catalog.pg_settings WHERE name = 'data_checksums';",
	'f');
is($result, 1, 'ensure standby has absorbed the inprogress-on barrier');
$result = $node_standby->safe_psql('postgres',
	"SELECT setting FROM pg_catalog.pg_settings WHERE name = 'data_checksums';"
);

is(($result eq 'inprogress-on' || $result eq 'on'),
	1, 'ensure checksums are on, or in progress, on standby_1');

# Insert some more data which should be checksummed on INSERT
$node_primary->safe_psql('postgres',
	"INSERT INTO t VALUES (generate_series(1, 10000));");

# Wait for checksums enabled on the primary and standby
wait_for_checksum_state($node_primary, 'on');
wait_for_checksum_state($node_standby, 'on');

$result =
  $node_primary->safe_psql('postgres', "SELECT count(a) FROM t WHERE a > 1");
is($result, '19998', 'ensure we can safely read all data with checksums');

$result = $node_primary->poll_query_until(
	'postgres',
	"SELECT count(*) FROM pg_stat_activity WHERE backend_type LIKE 'datachecksum%';",
	'0');
is($result, 1, 'await datachecksums worker/launcher termination');

#
# Disable checksums and ensure it's propagated to standby and that we can
# still read all data
#

# Disable checksums and wait for the operation to be replayed
disable_data_checksums($node_primary);
$node_primary->wait_for_catchup($node_standby, 'replay');
# Ensure that the primary and standby has switched to off
wait_for_checksum_state($node_primary, 'off');
wait_for_checksum_state($node_standby, 'off');
# Double-check reading data without errors
$result =
  $node_primary->safe_psql('postgres', "SELECT count(a) FROM t WHERE a > 1");
is($result, "19998", 'ensure we can safely read all data without checksums');

# ---------------------------------------------------------------------------
# Test that enabling checksums does not emit WAL for unlogged relations.
# Unlogged relations are wiped on recovery, so FPIs for them would be
# pointless and waste WAL traffic / standby I/O.
#

$node_primary->safe_psql('postgres',
	'CREATE UNLOGGED TABLE unlogged_tbl AS SELECT generate_series(1,1000) AS a;');
$node_primary->wait_for_catchup($node_standby, 'replay',
	$node_primary->lsn('insert'));

# Get the relfilenode and database OID so we can search the WAL for it
my $unlogged_rfn = $node_primary->safe_psql('postgres',
	"SELECT relfilenode FROM pg_class WHERE relname = 'unlogged_tbl';");
my $db_oid = $node_primary->safe_psql('postgres',
	"SELECT oid FROM pg_database WHERE datname = 'postgres';");

# Verify the standby only has the init fork (no main fork)
my $standby_datadir = $node_standby->data_dir;
ok(!-f "$standby_datadir/base/$db_oid/$unlogged_rfn",
	'standby has no main fork for unlogged table before enable');

# Re-enable data checksums
enable_data_checksums($node_primary, wait => 'on');
wait_for_checksum_state($node_standby, 'on');

# After standby replays, the unlogged main file must still not exist.
# If the bug were present, FPI replay would materialize the full table.
$node_primary->wait_for_catchup($node_standby, 'replay',
	$node_primary->lsn('insert'));
ok(!-f "$standby_datadir/base/$db_oid/$unlogged_rfn",
	'standby has no main fork for unlogged table after enable');

# Verify unlogged relation size is 0 on the standby (main fork missing)
my $standby_size = $node_standby->safe_psql('postgres',
	"SELECT pg_relation_size('unlogged_tbl', 'main');");
is($standby_size, '0',
	'unlogged table has zero size on standby after checksum enable');

# Unlogged table should still be readable on primary
$result = $node_primary->safe_psql('postgres',
	'SELECT count(*) FROM unlogged_tbl;');
is($result, '1000',
	'unlogged table readable on primary after checksum enable');

# Alter persistence to to logged, and make sure we can read it on both the
# primary and standby without any page verification errors in the logfiles.
$node_primary->safe_psql('postgres', 'ALTER TABLE unlogged_tbl SET logged;');
$node_primary->wait_for_catchup($node_standby, 'replay',
	$node_primary->lsn('insert'));

$result = $node_primary->safe_psql('postgres', 'SELECT sum(a) FROM unlogged_tbl;');
is($result, '500500', 'previously unlogged table can be read on primary');
$result = $node_standby->safe_psql('postgres', 'SELECT sum(a) FROM unlogged_tbl;');
is($result, '500500', 'previously unlogged table can be read on standby');

$node_standby->stop;
$node_primary->stop;

# Perform one final pass over the logs and hunt for unexpected errors
my $log =
  PostgreSQL::Test::Utils::slurp_file($node_primary->logfile, 0);
unlike(
	$log,
	qr/page verification failed,.+\d$/,
	"no checksum validation errors in primary log");
$log =
  PostgreSQL::Test::Utils::slurp_file($node_standby->logfile, 0);
unlike(
	$log,
	qr/page verification failed,.+\d$/,
	"no checksum validation errors in standby log");

done_testing();
