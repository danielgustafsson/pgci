# Copyright (c) 2026, PostgreSQL Global Development Group

# Exercise request changes and launcher ownership handoff.
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

subtest 'exiting launcher does not disturb its replacement' => sub {
	my $node = PostgreSQL::Test::Cluster->new('handoff');
	$node->init;
	$node->start;
	$node->safe_psql('postgres', 'CREATE EXTENSION injection_points;');

	# Stop the old launcher after it has relinquished ownership, but before
	# its exit callback runs.
	$node->safe_psql('postgres',
		"SELECT injection_points_attach('datachecksumsworker-launcher-before-exit', 'wait');"
	);
	disable_data_checksums($node);
	$node->wait_for_event('datachecksums launcher',
		'datachecksumsworker-launcher-before-exit');
	my $old_pid = $node->safe_psql('postgres',
		"SELECT pid FROM pg_stat_activity WHERE backend_type = 'datachecksums launcher';"
	);
	$node->safe_psql('postgres',
		"SELECT injection_points_detach('datachecksumsworker-launcher-before-exit');"
	);

	# Keep the replacement in inprogress-on while the old launcher exits.
	my $hold = $node->background_psql('postgres');
	$hold->query_safe('CREATE TEMP TABLE holdme (a int);');
	enable_data_checksums($node);
	$node->wait_for_event('datachecksums worker',
		'ChecksumEnableTemptableWait');
	$node->safe_psql('postgres',
		"SELECT injection_points_wakeup('datachecksumsworker-launcher-before-exit');"
	);
	$node->poll_query_until('postgres',
		"SELECT NOT EXISTS (SELECT FROM pg_stat_activity WHERE pid = $old_pid);"
	) or die 'old launcher did not exit';
	test_checksum_state($node, 'inprogress-on');

	# The replacement must still own the operation: a repeated enable request
	# must not register another launcher.
	$node->safe_psql('postgres',
		"SELECT injection_points_attach('datachecksumsworker-launcher-delay', 'error');"
	);
	my $log_offset = -s $node->logfile;
	enable_data_checksums($node);
	$hold->query_safe('DROP TABLE holdme;');
	$hold->quit;
	$node->poll_query_until('postgres',
		"SELECT NOT EXISTS (SELECT FROM pg_stat_activity WHERE backend_type = 'datachecksums launcher');"
	) or die 'replacement launcher did not exit';
	test_checksum_state($node, 'on');
	unlike(
		slurp_file($node->logfile, $log_offset),
		qr/datachecksumsworker-launcher-delay/,
		'repeated request did not start another launcher');
	$node->stop;
};

subtest 'new requests do not inherit an earlier abort' => sub {
	my $node = PostgreSQL::Test::Cluster->new('requests');
	$node->init(no_data_checksums => 1);
	$node->start;
	$node->safe_psql('postgres', 'CREATE EXTENSION injection_points;');

	my $hold = $node->background_psql('postgres');
	$hold->query_safe('CREATE TEMP TABLE holdme (a int);');
	enable_data_checksums($node);
	$node->wait_for_event('datachecksums worker',
		'ChecksumEnableTemptableWait');
	my $launcher_pid = $node->safe_psql('postgres',
		"SELECT pid FROM pg_stat_activity WHERE backend_type = 'datachecksums launcher';"
	);

	# Abort the first enable, and pause after the same launcher disables.
	$node->safe_psql('postgres',
		"SELECT injection_points_attach('datachecksumsworker-disable-complete', 'wait');"
	);
	disable_data_checksums($node);
	$node->wait_for_event('datachecksums launcher',
		'datachecksumsworker-disable-complete');
	is(
		$node->safe_psql('postgres',
			"SELECT pid FROM pg_stat_activity WHERE backend_type = 'datachecksums launcher';"
		),
		$launcher_pid,
		'original launcher processed the disable request');
	$hold->query_safe('DROP TABLE holdme;');
	$hold->quit;

	# Queue another enable before the launcher checks for new requests.
	enable_data_checksums($node);
	$node->safe_psql('postgres',
		"SELECT injection_points_detach('datachecksumsworker-disable-complete');
		 SELECT injection_points_wakeup('datachecksumsworker-disable-complete');"
	);
	$node->poll_query_until('postgres',
		"SELECT NOT EXISTS (SELECT FROM pg_stat_activity WHERE backend_type = 'datachecksums launcher');"
	) or die 'launcher did not finish processing requests';
	test_checksum_state($node, 'on');

	# SIGINT without a replacement request must still roll back an unfinished
	# enable before the launcher releases ownership.
	disable_data_checksums($node, wait => 1);
	$hold = $node->background_psql('postgres');
	$hold->query_safe('CREATE TEMP TABLE holdme (a int);');
	enable_data_checksums($node);
	$node->wait_for_event('datachecksums worker',
		'ChecksumEnableTemptableWait');
	is(
		$node->safe_psql('postgres',
			"SELECT pg_cancel_backend(pid) FROM pg_stat_activity
			 WHERE backend_type = 'datachecksums launcher';"),
		't',
		'cancel signal sent to launcher');
	$node->poll_query_until('postgres',
		"SELECT NOT EXISTS (SELECT FROM pg_stat_activity
		 WHERE backend_type IN ('datachecksums launcher', 'datachecksums worker'));"
	) or die 'canceled launcher or worker did not exit';
	test_checksum_state($node, 'off');
	$hold->query_safe('DROP TABLE holdme;');
	$hold->quit;
	$node->stop;
};

subtest 'disable cancels a worker blocked on a relation lock' => sub {
	my $node = PostgreSQL::Test::Cluster->new('blocked');
	$node->init(no_data_checksums => 1);
	$node->start;
	$node->safe_psql('postgres',
		'CREATE TABLE locked_table AS SELECT generate_series(1,100) AS a;');

	# LOCK does not assign an XID, so the launcher can finish its initial
	# transaction wait, but the worker cannot acquire AccessShareLock.
	my $hold = $node->background_psql('postgres');
	$hold->set_query_timer_restart();
	my $holder_pid = $hold->query_safe('SELECT pg_backend_pid();');
	$hold->query_safe('BEGIN; LOCK TABLE locked_table IN ACCESS EXCLUSIVE MODE;');
	enable_data_checksums($node);
	$node->poll_query_until(
		'postgres', qq[
		SELECT EXISTS (SELECT FROM pg_stat_activity
			WHERE backend_type = 'datachecksums worker'
			  AND $holder_pid = ANY (pg_blocking_pids(pid)));]
	) or die 'worker did not block on the relation lock';

	disable_data_checksums($node);
	ok(
		$node->poll_query_until(
			'postgres', qq[
			SELECT current_setting('data_checksums') = 'off'
				AND NOT EXISTS (SELECT FROM pg_stat_activity
					WHERE backend_type IN
						('datachecksums launcher', 'datachecksums worker'));]
		),
		'disable completes without releasing the relation lock');

	# Release the lock even on failure, so the node can shut down normally.
	$hold->query_safe('ROLLBACK;');
	$hold->quit;
	disable_data_checksums($node, wait => 1);
	enable_data_checksums($node, wait => 'on');
	is($node->safe_psql('postgres', 'SELECT count(*) FROM locked_table;'),
		'100', 'data remains readable after re-enabling checksums');
	$node->stop;
	command_ok(
		[ 'pg_checksums', '--check', '-D', $node->data_dir ],
		'offline verification succeeds after cancellation and re-enable');
};

done_testing();
