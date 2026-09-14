# Copyright (c) 2026, PostgreSQL Global Development Group

# A base backup taken while an online checksum enable is running.  The
# control file copied with the backup, and the redo point of the backup
# checkpoint, both carry the in-progress state; replay of the
# XLOG2_CHECKSUMS records completes the transition on the new standby.
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

# Hold the enable at inprogress-on with a pre-existing temp table the
# checksum worker has to wait out, same trick as in 004_offline.pl and
# scenario 4 of 012_offline_standby.pl.
my $bsession = $primary->background_psql('postgres');
$bsession->query_safe('CREATE TEMPORARY TABLE tt (a integer);');

enable_data_checksums($primary, wait => 'inprogress-on');

# The backup's checkpoint is taken while the primary sits at
# inprogress-on, so both the control file and the redo point's
# XLOG_CHECKPOINT_REDO record carry that state.
$primary->backup('backup');
my $standby = PostgreSQL::Test::Cluster->new('standby');
$standby->init_from_backup($primary, 'backup', has_streaming => 1);
$standby->start;

# Backup label recovery adopts the redo point's state immediately, before
# any further WAL is replayed.
wait_for_checksum_state($standby, 'inprogress-on');

# Release the barrier; the transition completes on the primary and
# replicates.  Nothing before this point can legitimately disagree: the
# standby starts out at the same inprogress-on state as the primary, so
# there is nothing yet to warn about.
$bsession->quit;
wait_for_checksum_state($primary, 'on');
$primary->wait_for_catchup($standby);
wait_for_checksum_state($standby, 'on');

is( $standby->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'10000', 'standby readable after the transition completed');

my $log = PostgreSQL::Test::Utils::slurp_file($standby->logfile);
unlike(
	$log,
	qr/does not match the state/,
	'no mismatch warning at any point during a backup taken mid-transition'
);

# No extra CHECKPOINT needed before this: the transition's own completion
# checkpoint already wrote every page with a checksum, and the shutdown
# restartpoint triggered by stop() flushes anything since then and
# persists the completed state to the control file.
$standby->stop;
command_ok([ 'pg_checksums', '--check', '-D', $standby->data_dir ],
	'checksums valid on the standby');

$primary->stop;
done_testing();
