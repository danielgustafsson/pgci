
# Copyright (c) 2026, PostgreSQL Global Development Group

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

# This test suite is expensive, or very expensive, to execute.  There are two
# PG_TEST_EXTRA options for running it, "checksum" for a pared-down test suite
# an "checksum_extended" for the full suite.  The full suite can run for hours
# on slow or constrained systems.
my $extended = undef;
if ($ENV{PG_TEST_EXTRA})
{
	$extended = 1 if ($ENV{PG_TEST_EXTRA} =~ /\bchecksum_extended\b/);
	plan skip_all => 'Expensive data checksums test disabled'
	  unless ($ENV{PG_TEST_EXTRA} =~ /\bchecksum(_extended)?\b/);
}

if ($ENV{enable_injection_points} ne 'yes')
{
	plan skip_all => 'Injection points not supported by this build';
}

# ---------------------------------------------------------------------------
# Test cluster setup
#

# Initiate testcluster
my $node = PostgreSQL::Test::Cluster->new('injection_node');
$node->init(no_data_checksums => 1);
$node->start;

# Set up test environment
$node->safe_psql('postgres', 'CREATE EXTENSION test_checksums;');
$node->safe_psql('postgres', 'CREATE EXTENSION injection_points;');

my $pgbench = undef;
my $scalefactor = ($extended ? 10 : 1);
my $node_loglocation = 0;

$node->command_ok(
	[
		'pgbench', '-p', $node->port, '-i',
		'-s', $scalefactor, '-q', 'postgres'
	]);

# Check the server log for page verification failures. To speed up parsing it
# keeps track of what it has already read and starts from there. A TODO is to
# move this to the DataChecksums helper module and use across all testsuites.
sub parse_log_for_failures
{
	my $log =
	  PostgreSQL::Test::Utils::slurp_file($node->logfile, $node_loglocation);
	unlike(
		$log,
		qr/page verification failed,.+\d$/,
		"no checksum validation errors in primary log (during WAL recovery)");
	$node_loglocation = -s $node->logfile;
}

# Start a pgbench run in the background against the server specified via the
# port passed as parameter.
sub background_rw_pgbench
{
	my ($port, $restart) = shift;

	# If a previous pgbench is still running, start by shutting it down if
	# we are asked to restart, otherwise we are done.
	if ($pgbench)
	{
		if ($restart)
		{
			$pgbench->finish if $restart;
		}
		else
		{
			return;
		}
	}

	my $clients = 1;
	my $runtime = 2;

	if ($extended)
	{
		# Randomize the number of pgbench clients a bit (range 1-16)
		$clients = 1 + int(rand(15));
		$runtime = 600;
	}
	my @cmd = ('pgbench', '-p', $port, '-T', $runtime, '-c', $clients);

	# Randomize whether we spawn connections or not
	push(@cmd, '-C') if ($extended && cointoss);
	# Finally add the database name to use
	push(@cmd, 'postgres');

	$pgbench = IPC::Run::start(
		\@cmd,
		'<' => '/dev/null',
		'>' => '/dev/null',
		'2>' => '/dev/null',
		IPC::Run::timer($PostgreSQL::Test::Utils::timeout_default));
}

# Test checksum transition. The function has these arguments:
#
# - start checksum state (enabled/disabled)
# - first - first checksum change
# - second - second checksum change
# - point - injection point the first change should wait on
# - final - expected checksum state at the end
#
# The test puts the instance into the initial checksum state, triggers two
# checksum changes, and verifies the final state is as expected. The first
# state change is paused on a selected injection point, and unpaused after
# the second change gets initiated.
#
# The injection point is triggered only by the datachecksum launcher, and
# there can be only one such process. So there's no risk of hitting the
# injection point by both changes.
sub test_checksum_transition
{
	my ($start, $first, $second, $point, $final) = @_;

	# Start the test suite with pgbench running.
	background_rw_pgbench($node->port, 0);

	$node->safe_psql('postgres',
			"SELECT '========== "
		  . $start . " / "
		  . $first . " / "
		  . $second . " / "
		  . $point . " / "
		  . $final
		  . " =========='");

	note(   $start . " / "
		  . $first . " / "
		  . $second . " / "
		  . $point . " / "
		  . $final);

	note('changing checksums into initial state: ' . $start);

	enable_data_checksums($node, wait => 'on') if ($start eq 'enabled');
	disable_data_checksums($node, wait => 'off') if ($start eq 'disabled');

	note('attaching injection point: ' . $point);
	$node->safe_psql('postgres',
		"SELECT injection_points_attach('" . $point . "','wait');");

	note("triggering first checksum change: " . $first);

	enable_data_checksums($node) if ($first eq 'enable');
	disable_data_checksums($node) if ($first eq 'disable');

	note("waiting for the injection point to be hit");
	$node->poll_query_until(
		'postgres',
		"SELECT COUNT(*) FROM pg_catalog.pg_stat_activity WHERE wait_event = '"
		  . $point . "'",
		'1');

	note("triggering second checksum change: " . $second);

	enable_data_checksums($node) if ($second eq 'enable');
	disable_data_checksums($node) if ($second eq 'disable');

	note("waking and detaching injection point");
	$node->safe_psql('postgres',
		"SELECT injection_points_wakeup('" . $point . "');");

	note("detaching injection point");
	$node->safe_psql('postgres',
		"SELECT injection_points_detach('" . $point . "');");

	note('wait for the checksum launcher to exit');
	$node->poll_query_until('postgres',
			"SELECT count(*) = 0 "
		  . "FROM pg_catalog.pg_stat_activity "
		  . "WHERE backend_type = 'datachecksum launcher';");

	test_checksum_state($node, $final);

	# Parse the log and check for instances of checksum verification failures
	parse_log_for_failures();
}

# Test checksum transition concurrent with a checkpoint.
#
# The function has these arguments:
#
# - start checksum state (enabled/disabled)
# - change - checksum change to initiate
# - point1 - injection point before checkpoint
# - point2 - injection point after checkpoint
# - final - expected checksum state at the end
#
# The test puts the instance into the initial checksum state, triggers a
# checksum change that pauses on a selected injection point. Then performs
# a checkpoint, unpauses the change so that it proceeds to a second
# injection point.
#
# Then the instance is restarted in immediate mode to simulate failure,
# and the final checksum state is validated against the expected value.
# The server log is checked for checksum failures.
sub test_checksum_transition_chkpt
{
	my ($start, $change, $point1, $point2, $final, $stopmode) = @_;

	# Start the test suite with pgbench running.
	background_rw_pgbench($node->port, 1);

	$node->safe_psql('postgres',
			"SELECT '========== "
		  . $start . " / "
		  . $change . " / "
		  . $point1 . " / "
		  . $final
		  . " =========='");

	note($start . " / " . $change . " / " . $point1 . " / " . $final);

	note('changing checksums into initial state: ' . $start);

	enable_data_checksums($node, wait => 'on') if ($start eq 'enabled');
	disable_data_checksums($node, wait => 'off') if ($start eq 'disabled');

	note('attaching injection point: ' . $point1);
	$node->safe_psql('postgres',
		"SELECT injection_points_attach('" . $point1 . "','wait');");

	if (defined($point2))
	{
		note('attaching injection point: ' . $point2);
		$node->safe_psql('postgres',
			"SELECT injection_points_attach('" . $point2 . "','wait');");
	}

	note("triggering checksum change: " . $change);

	enable_data_checksums($node) if ($change eq 'enable');
	disable_data_checksums($node) if ($change eq 'disable');

	note("waiting for the injection point to be hit");
	$node->poll_query_until(
		'postgres',
		"SELECT COUNT(*) FROM pg_catalog.pg_stat_activity WHERE wait_event = '"
		  . $point1 . "'",
		'1');

	note('checkpoint');
	$node->safe_psql('postgres', "CHECKPOINT");

	note("waking and detaching injection point");
	$node->safe_psql('postgres',
		"SELECT injection_points_wakeup('" . $point1 . "');");

	note("detaching injection point");
	$node->safe_psql('postgres',
		"SELECT injection_points_detach('" . $point1 . "');");

	if (defined($point2))
	{
		note("waiting for the injection point to be hit");
		$node->poll_query_until(
			'postgres',
			"SELECT COUNT(*) FROM pg_catalog.pg_stat_activity WHERE wait_event = '"
			  . $point2 . "'",
			'1');
	}
	else
	{
		note('wait for the checksum launcher to exit');
		$node->poll_query_until('postgres',
				"SELECT count(*) = 0 "
			  . "FROM pg_catalog.pg_stat_activity "
			  . "WHERE backend_type = 'datachecksum launcher';");
	}

	$stopmode = stopmode() unless (defined($stopmode));
	$node->stop($stopmode);
	$node->start;

	test_checksum_state($node, $final);

	# Parse the log and check for instances of checksum verification failures
	parse_log_for_failures();
}

test_checksum_transition('disabled', 'enable', 'disable',
	'datachecksums-enable-inprogress-checksums-delay', 'off');
test_checksum_transition('disabled', 'enable', 'disable',
	'datachecksums-enable-inprogress-checksums-after-barrier-emit', 'off');
test_checksum_transition('disabled', 'enable', 'disable',
	'datachecksums-enable-checksums-delay', 'off');
test_checksum_transition('disabled', 'enable', 'disable',
	'datachecksums-enable-checksums-after-barrier-emit', 'off');
test_checksum_transition('disabled', 'enable', 'disable',
	'datachecksums-enable-checksums-after-checkpoint', 'off');

test_checksum_transition('disabled', 'enable', 'enable',
	'datachecksums-enable-inprogress-checksums-delay', 'on');
test_checksum_transition('disabled', 'enable', 'enable',
	'datachecksums-enable-inprogress-checksums-after-barrier-emit', 'on');
test_checksum_transition('disabled', 'enable', 'enable',
	'datachecksums-enable-checksums-delay', 'on');
test_checksum_transition('disabled', 'enable', 'enable',
	'datachecksums-enable-checksums-after-barrier-emit', 'on');
test_checksum_transition('disabled', 'enable', 'enable',
	'datachecksums-enable-checksums-after-checkpoint', 'on');

test_checksum_transition('enabled', 'disable', 'disable',
	'datachecksums-disable-inprogress-checksums-delay', 'off');
test_checksum_transition('enabled', 'disable', 'disable',
	'datachecksums-disable-inprogress-checksums-after-barrier-emit', 'off');
test_checksum_transition('enabled', 'disable', 'disable',
	'datachecksums-disable-checksums-delay', 'off');
test_checksum_transition('enabled', 'disable', 'disable',
	'datachecksums-disable-checksums-after-barrier-emit', 'off');
test_checksum_transition('enabled', 'disable', 'disable',
	'datachecksums-disable-checksums-after-checkpoint', 'off');

test_checksum_transition('enabled', 'disable', 'enable',
	'datachecksums-disable-inprogress-checksums-delay', 'on');
test_checksum_transition('enabled', 'disable', 'enable',
	'datachecksums-disable-inprogress-checksums-after-barrier-emit', 'on');
test_checksum_transition('enabled', 'disable', 'enable',
	'datachecksums-disable-inprogress-checksums-after-checkpoint', 'on');
test_checksum_transition('enabled', 'disable', 'enable',
	'datachecksums-disable-checksums-delay', 'on');
test_checksum_transition('enabled', 'disable', 'enable',
	'datachecksums-disable-checksums-after-barrier-emit', 'on');
test_checksum_transition('enabled', 'disable', 'enable',
	'datachecksums-disable-checksums-after-checkpoint', 'on');

test_checksum_transition_chkpt('disabled', 'enable',
	'datachecksums-enable-inprogress-checksums-delay',
	undef, 'on', undef);
test_checksum_transition_chkpt('disabled', 'enable',
	'datachecksums-enable-inprogress-checksums-after-barrier-emit',
	undef, 'on', undef);
test_checksum_transition_chkpt('disabled', 'enable',
	'datachecksums-enable-checksums-delay',
	undef, 'on', undef, undef);
test_checksum_transition_chkpt('disabled', 'enable',
	'datachecksums-enable-checksums-after-barrier-emit',
	undef, 'on', undef);
test_checksum_transition_chkpt('disabled', 'enable',
	'datachecksums-enable-checksums-after-checkpoint',
	undef, 'on', undef);

test_checksum_transition_chkpt('enabled', 'disable',
	'datachecksums-disable-inprogress-checksums-delay',
	undef, 'off', undef);
test_checksum_transition_chkpt('enabled', 'disable',
	'datachecksums-disable-inprogress-checksums-after-barrier-emit',
	undef, 'off', undef);
test_checksum_transition_chkpt('enabled', 'disable',
	'datachecksums-disable-inprogress-checksums-after-checkpoint',
	undef, 'off', undef);
test_checksum_transition_chkpt('enabled', 'disable',
	'datachecksums-disable-checksums-delay',
	undef, 'off', undef);
test_checksum_transition_chkpt('enabled', 'disable',
	'datachecksums-disable-checksums-after-barrier-emit',
	undef, 'off', undef);
test_checksum_transition_chkpt('enabled', 'disable',
	'datachecksums-disable-checksums-after-checkpoint',
	undef, 'off', undef);

test_checksum_transition_chkpt(
	'disabled',
	'enable',
	'datachecksums-enable-inprogress-checksums-delay',
	'datachecksums-enable-inprogress-checksums-after-barrier-emit',
	'off',
	'immediate');
test_checksum_transition_chkpt(
	'disabled',
	'enable',
	'datachecksums-enable-inprogress-checksums-after-barrier-emit',
	'datachecksums-enable-checksums-delay',
	'off',
	'immediate');
test_checksum_transition_chkpt(
	'disabled', 'enable',
	'datachecksums-enable-checksums-delay',
	'datachecksums-enable-checksums-after-barrier-emit',
	'on', 'immediate');
test_checksum_transition_chkpt(
	'disabled', 'enable',
	'datachecksums-enable-checksums-after-barrier-emit',
	'datachecksums-enable-checksums-after-checkpoint',
	'on', 'immediate');
test_checksum_transition_chkpt('disabled', 'enable',
	'datachecksums-enable-checksums-after-checkpoint',
	undef, 'on', 'immediate');

test_checksum_transition_chkpt(
	'enabled',
	'disable',
	'datachecksums-disable-inprogress-checksums-delay',
	'datachecksums-disable-inprogress-checksums-after-barrier-emit',
	'off',
	'immediate');
test_checksum_transition_chkpt(
	'enabled',
	'disable',
	'datachecksums-disable-inprogress-checksums-after-barrier-emit',
	'datachecksums-disable-inprogress-checksums-after-checkpoint',
	'off',
	'immediate');
test_checksum_transition_chkpt(
	'enabled',
	'disable',
	'datachecksums-disable-inprogress-checksums-after-checkpoint',
	'datachecksums-disable-checksums-delay',
	'off',
	'immediate');
test_checksum_transition_chkpt(
	'enabled', 'disable',
	'datachecksums-disable-checksums-delay',
	'datachecksums-disable-checksums-after-barrier-emit',
	'off', 'immediate');
test_checksum_transition_chkpt(
	'enabled',
	'disable',
	'datachecksums-disable-checksums-after-barrier-emit',
	'datachecksums-disable-checksums-after-checkpoint',
	'off',
	'immediate');
test_checksum_transition_chkpt('enabled', 'disable',
	'datachecksums-disable-checksums-after-checkpoint',
	undef, 'off', 'immediate');

$node->stop;
done_testing();
