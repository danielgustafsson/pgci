
# Copyright (c) 2025, PostgreSQL Global Development Group

# Test suite for testing enabling data checksums in an online cluster with
# injection point tests injecting failures into the processing

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

# ---------------------------------------------------------------------------
# Test cluster setup
#

# Initiate testcluster
my $node = PostgreSQL::Test::Cluster->new('main');
$node->init(no_data_checksums => 1);
$node->start;

# Set up test environment
$node->safe_psql('postgres', 'CREATE EXTENSION test_checksums;');

# ---------------------------------------------------------------------------
# Inducing failures and crashes in processing

# Force enabling checksums to fail by marking one of the databases as having
# failed in processing.
disable_data_checksums($node, wait => 1);
$node->safe_psql('postgres', 'SELECT dcw_inject_fail_database(true);');
enable_data_checksums($node, wait => 'off');
$node->safe_psql('postgres', 'SELECT dcw_inject_fail_database(false);');

# Force the server to crash after enabling data checksums but before issuing
# the checkpoint.  Since the switch has been WAL logged the server should come
# up with checksums enabled after replay.
test_checksum_state($node, 'off');
$node->safe_psql('postgres', 'SELECT dc_crash_before_checkpoint();');
enable_data_checksums($node, fast => 'true');
my $ret = wait_for_cluster_crash($node);
ok($ret == 1, "Cluster crash detection timeout");
ok(!$node->is_alive, "Cluster crashed due to abort() before checkpointing");
$node->_update_pid(-1);
$node->start;
test_checksum_state($node, 'on');

# Another test just like the previous, but for disabling data checksums (and
# crashing just before checkpointing).  The previous injection points were all
# detached from through the crash so they need to be reattached.
$node->safe_psql('postgres', 'SELECT dc_crash_before_checkpoint();');
disable_data_checksums($node);
$ret = wait_for_cluster_crash($node);
ok($ret == 1, "Cluster crash detection timeout");
ok(!$node->is_alive, "Cluster crashed due to abort() before checkpointing");
$node->_update_pid(-1);
$node->start;
test_checksum_state($node, 'off');

# Now inject a crash before inserting the WAL record for data checksum state
# change, when the server comes back up again the state should not have been
# set to the new value since the process didn't succeed.
$node->safe_psql('postgres', 'SELECT dc_crash_before_xlog();');
enable_data_checksums($node);
$ret = wait_for_cluster_crash($node);
ok($ret == 1, "Cluster crash detection timeout");
ok(!$node->is_alive, "Cluster crashed");
$node->_update_pid(-1);
$node->start;
test_checksum_state($node, 'off');

# This re-runs the same test again but with first disabling data checksums and
# then enabling again, crashing right before inserting the WAL record.  When
# it comes back up the checksums must not be enabled.
$node->safe_psql('postgres', 'SELECT dc_crash_before_xlog();');
enable_data_checksums($node);
$ret = wait_for_cluster_crash($node);
ok($ret == 1, "Cluster crash detection timeout");
ok(!$node->is_alive, "Cluster crashed");
$node->_update_pid(-1);
$node->start;
test_checksum_state($node, 'off');

# ---------------------------------------------------------------------------
# Timing and retry related tests
#

# Force the enable checksums processing to make multiple passes by removing
# one database from the list in the first pass.  This will simulate a CREATE
# DATABASE during processing.  Doing this via fault injection makes the test
# not be subject to exact timing.
$node->safe_psql('postgres', 'SELECT dcw_prune_dblist(true);');
enable_data_checksums($node, wait => 'on');

SKIP:
{
	skip 'Data checksum delay tests not enabled in PG_TEST_EXTRA', 4
	  if (!$ENV{PG_TEST_EXTRA}
		|| $ENV{PG_TEST_EXTRA} !~ /\bchecksum_extended\b/);

	# Inject a delay in the barrier for enabling checksums
	disable_data_checksums($node, wait => 1);
	$node->safe_psql('postgres', 'SELECT dcw_inject_delay_barrier();');
	enable_data_checksums($node, wait => 'on');

	# Fake the existence of a temporary table at the start of processing, which
	# will force the processing to wait and retry in order to wait for it to
	# disappear.
	disable_data_checksums($node, wait => 1);
	$node->safe_psql('postgres', 'SELECT dcw_fake_temptable(true);');
	enable_data_checksums($node, wait => 'on');
}

$node->stop;
done_testing();
