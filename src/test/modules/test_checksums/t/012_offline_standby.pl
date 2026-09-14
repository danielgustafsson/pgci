# Copyright (c) 2026, PostgreSQL Global Development Group

# Offline checksum changes with pg_checksums are local to one node.  A
# standby must neither adopt the state of the primary from replayed
# checkpoint records, nor lose its own offline change to them.
use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin;
use lib $FindBin::RealBin;

use DataChecksums::Utils;

# Primary and standby, checksums off.
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

# Scenario 1: enable offline on the primary only.  The standby must
# stay off, warn about the mismatch, and remain readable.
$standby->stop;
$primary->stop;
$primary->checksum_enable_offline;
$primary->start;
$standby->start;

test_checksum_state($primary, 'on');
test_checksum_state($standby, 'off');

my $logstart = -s $standby->logfile;
$primary->safe_psql('postgres', "INSERT INTO t VALUES (0);");
$primary->safe_psql('postgres', "CHECKPOINT;");
$primary->wait_for_catchup($standby);

test_checksum_state($standby, 'off');
is( $standby->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'10001', 'standby readable after offline enable on the primary');

$standby->wait_for_log(
	qr/does not match the state "on" in the replayed WAL/,
	$logstart);

# Only one warning for the same remote value.
$primary->safe_psql('postgres', "CHECKPOINT;");
$primary->wait_for_catchup($standby);
my $log = PostgreSQL::Test::Utils::slurp_file($standby->logfile, $logstart);
my @warnings = $log =~ /(does not match the state)/g;
is(scalar(@warnings), 1, 'mismatch warned once per remote value');

# Matching states re-arm the warning: undo the divergence on the primary,
# then diverge again to the same value, all without restarting the standby.
$primary->stop;
$primary->checksum_disable_offline;
$primary->start;
$logstart = -s $standby->logfile;
$primary->safe_psql('postgres', "CHECKPOINT;");
$primary->wait_for_catchup($standby);
$log = PostgreSQL::Test::Utils::slurp_file($standby->logfile, $logstart);
unlike(
	$log,
	qr/does not match the state/,
	'no warning while the states match again');

$primary->stop;
$primary->checksum_enable_offline;
$primary->start;
$primary->safe_psql('postgres', "CHECKPOINT;");
$primary->wait_for_catchup($standby);
$standby->wait_for_log(
	qr/does not match the state "on" in the replayed WAL/,
	$logstart);
test_checksum_state($standby, 'off');

# The local state survives both clean and immediate restarts.
$standby->restart;
test_checksum_state($standby, 'off');
$standby->stop('immediate');
$standby->start;
test_checksum_state($standby, 'off');

# Converge the cluster: enable offline on the standby too.
$standby->stop;
command_checks_all(
	[ 'pg_checksums', '--enable', '-D', $standby->data_dir ],
	0,
	[qr/appears to be a standby/],
	[],
	'standby-role notice on offline enable');
$standby->start;
test_checksum_state($standby, 'on');
$primary->wait_for_catchup($standby);
is( $standby->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'10001', 'standby readable after converging');

# Scenario 2: disable offline on the standby only.  The replayed
# checkpoint records of the still-enabled primary must not override it.
$standby->stop;
$standby->checksum_disable_offline;
$standby->start;
test_checksum_state($standby, 'off');
test_checksum_state($primary, 'on');

$primary->safe_psql('postgres', "CHECKPOINT;");
$primary->wait_for_catchup($standby);
test_checksum_state($standby, 'off');

# Restart points must persist the local state, not the replayed copy.
$standby->safe_psql('postgres', "CHECKPOINT;");
$standby->restart;
test_checksum_state($standby, 'off');
$standby->stop('immediate');
$standby->start;
test_checksum_state($standby, 'off');

is( $standby->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'10001', 'standby readable with checksums disabled locally');

# Scenario 3: crash-restart right after an online transition, before the
# next restartpoint.  Replay then resumes from an older restartpoint whose
# checkpoint records still carry the pre-transition state.  Those must
# still match the state seeded from the control file, and the transition
# itself must be re-established by re-replaying the XLOG2_CHECKSUMS record,
# without a spurious mismatch warning along the way.

# Converge first: bring the standby back to "on" offline.
$standby->stop;
$standby->checksum_enable_offline;
$standby->start;
test_checksum_state($standby, 'on');
test_checksum_state($primary, 'on');

# Online-disable on the primary and let it propagate to the standby.
disable_data_checksums($primary, wait => 'off');
$primary->wait_for_catchup($standby);
wait_for_checksum_state($standby, 'off');

# Crash-restart the standby immediately, before any restartpoint has had a
# chance to persist the new state to its control file.
$logstart = -s $standby->logfile;
$standby->stop('immediate');
$standby->start;
$primary->wait_for_catchup($standby);

test_checksum_state($standby, 'off');
is( $standby->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'10001',
	'standby readable after crash-restart across an online transition');

$log = PostgreSQL::Test::Utils::slurp_file($standby->logfile, $logstart);
unlike(
	$log,
	qr/does not match the state/,
	'no spurious mismatch warning after crash-restart across an online transition'
);

# Scenario 4: a standby stopped while replaying an interrupted online
# transition keeps the interrupted state in its own control file, and
# pg_checksums must refuse to touch it.  The primary can never be
# caught this way: its checksums launcher process resolves inprogress-on
# back to off from its own exit cleanup whenever it exits, which happens
# on any graceful stop.  A standby has no launcher; it only carries
# forward whatever state the last replayed record left it in, and a
# restartpoint persists that as-is when the standby itself is stopped.

# Block an online enable on the primary at inprogress-on with a
# blocking temp table, same trick as in 004_offline.pl.
my $bsession = $primary->background_psql('postgres');
$bsession->query_safe('CREATE TEMPORARY TABLE tt (a integer);');
enable_data_checksums($primary, wait => 'inprogress-on');

# The standby replays the XLOG2_CHECKSUMS record and picks up the
# in-progress state itself.
wait_for_checksum_state($standby, 'inprogress-on');

# Stop the standby cleanly; its restartpoint persists inprogress-on to
# its own control file, since nothing on a standby resolves it away.
$standby->stop;

command_fails_like(
	[ 'pg_checksums', '--enable', '-D', $standby->data_dir ],
	qr/online data checksum state transition was interrupted/,
	'pg_checksums --enable refuses a standby stopped mid-transition');
command_fails_like(
	[ 'pg_checksums', '--check', '-D', $standby->data_dir ],
	qr/online data checksum state transition was interrupted/,
	'pg_checksums --check refuses a standby stopped mid-transition');
command_fails_like(
	[ 'pg_checksums', '--disable', '-D', $standby->data_dir ],
	qr/online data checksum state transition was interrupted/,
	'pg_checksums --disable refuses a standby stopped mid-transition');

# Bring the standby back, then let the primary's transition complete.
$standby->start;
$bsession->quit;
wait_for_checksum_state($primary, 'on');
$primary->wait_for_catchup($standby);
wait_for_checksum_state($standby, 'on');

is( $standby->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'10001', 'standby readable once the transition completes');

$standby->stop;
$primary->stop;
done_testing();
