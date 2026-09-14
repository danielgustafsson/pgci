# Copyright (c) 2026, PostgreSQL Global Development Group

# Exercise physical-file reconciliation, its cancellation boundary, and the
# limitation that a primary cannot inspect files local to a standby.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use File::Copy qw(copy);
use File::Path qw(make_path rmtree);
use Test::More;

use FindBin;
use lib $FindBin::RealBin;
use DataChecksums::Utils;

sub wait_finished
{
	my ($node, $state) = @_;
	wait_for_checksum_state($node, $state);
	ok( $node->poll_query_until(
			'postgres',
			"SELECT count(*) = 0 FROM pg_stat_activity "
			  . "WHERE backend_type IN ('datachecksums launcher', 'datachecksums worker');"
		),
		"checksum processes exit with state $state");
}

sub check_rejection
{
	my ($node, $path, $offset) = @_;
	wait_finished($node, 'off');
	my $log = slurp_file($node->logfile, $offset);
	like(
		$log,
		qr/cannot enable data checksums with unaccounted relation file "\Q$path\E"/,
		"reports unaccounted file $path");
	like(
		$log,
		qr/Use pg_checksums --enable while the cluster is shut down to checksum all physical relation files\./,
		'offline enabling hint accompanies rejection');
}

my $node = PostgreSQL::Test::Cluster->new('reconciliation');
$node->init(no_data_checksums => 1, allows_streaming => 1);
$node->append_conf('postgresql.conf', 'autovacuum = off');
$node->start;
$node->safe_psql(
	'postgres', q{
	CREATE TABLE live AS SELECT generate_series(1,1000) AS a;
	CREATE INDEX live_idx ON live(a);
	CREATE TABLE saved AS TABLE live;
	VACUUM live;
	CHECKPOINT;
});
my $livepath =
  $node->safe_psql('postgres', "SELECT pg_relation_filepath('live');");
my $orphanpath =
  $node->safe_psql('postgres', "SELECT pg_relation_filepath('saved');");
my ($filenode) = $orphanpath =~ m{(\d+)$};
my $saved = PostgreSQL::Test::Utils::tempdir() . '/pagefile';
$node->stop;
copy($node->data_dir . "/$orphanpath", $saved) or die $!;
$node->start;
$node->safe_psql('postgres', 'DROP TABLE saved; CHECKPOINT;');

# These names are valid physical relation files even when only a non-main
# fork remains, a segment follows a gap, or the database no longer exists.
my $missingdb = 'base/4294967294';
my @paths = (
	"${orphanpath}_fsm", "$livepath.2",
	"global/$filenode", "$missingdb/$filenode");
for my $path (@paths)
{
	$node->stop;
	make_path($node->data_dir . "/$missingdb")
	  if $path =~ m{^\Q$missingdb\E/};
	ok(!-e $node->data_dir . "/$path", "$path does not replace live storage");
	copy($saved, $node->data_dir . "/$path") or die $!;
	$node->start;
	my $offset = -s $node->logfile;
	enable_data_checksums($node);
	check_rejection($node, $path, $offset);
	is(slurp_file($node->data_dir . "/$path"),
		slurp_file($saved), "$path remains byte-for-byte unchanged");
	$node->stop;
	unlink($node->data_dir . "/$path") or die $!;
	rmtree($node->data_dir . "/$missingdb") if $path =~ m{^\Q$missingdb\E/};
	$node->start;
}

# Empty orphan forks and empty detached segments do not contain any pages.
$node->stop;
for my $path ("${orphanpath}_vm", "$livepath.2")
{
	open(my $fh, '>', $node->data_dir . "/$path") or die $!;
	close($fh) or die $!;
}
$node->start;
enable_data_checksums($node, wait => 'on');
is($node->safe_psql('postgres', 'SELECT count(*) FROM live;'),
	'1000', 'healthy heap, index, FSM and VM survive reconciliation');
cmp_ok($node->safe_psql('postgres', 'SELECT count(*) FROM pg_class;'),
	'>', 0, 'mapped local catalog remains readable');
cmp_ok($node->safe_psql('postgres', 'SELECT count(*) FROM pg_database;'),
	'>', 0, 'shared mapped catalog remains readable');
$node->stop;
command_ok(
	[ 'pg_checksums', '--check', '-D', $node->data_dir ],
	'healthy physical files pass offline verification');

for my $path ("${orphanpath}_vm", "$livepath.2")
{
	unlink($node->data_dir . "/$path") or die $!;
}
$node->start;
disable_data_checksums($node, wait => 1);

SKIP:
{
	skip 'Injection points not supported by this build', 1
	  unless ($ENV{enable_injection_points} // '') eq 'yes';

	subtest 'reconciliation races' => sub {
		$node->safe_psql('postgres', 'CREATE EXTENSION injection_points;');
		my $point = 'datachecksums-before-file-check';
		my $pause = sub {
			$node->safe_psql('postgres',
				"SELECT injection_points_attach('$point', 'wait');");
			enable_data_checksums($node);
			$node->poll_query_until('postgres',
					"SELECT count(*) > 0 FROM pg_stat_activity "
				  . "WHERE backend_type = 'datachecksums worker' "
				  . "AND datname = 'postgres' AND wait_event = '$point';")
			  or die 'timed out waiting for postgres reconciliation';
			test_checksum_state($node, 'inprogress-on');
		};
		my $resume = sub {
			$node->safe_psql('postgres',
				"SELECT injection_points_detach('$point');");
			$node->safe_psql('postgres',
				"SELECT injection_points_wakeup('$point');");
		};

		$pause->();
		$node->safe_psql('postgres', 'SELECT pg_disable_data_checksums();');
		$resume->();
		wait_finished($node, 'off');

		$pause->();
		$node->stop('immediate');
		$node->start;
		test_checksum_state($node, 'off');
		is($node->safe_psql('postgres', 'SELECT count(*) FROM live;'),
			'1000', 'crash during reconciliation leaves live data readable');

		# An uncommitted CREATE has storage but no visible catalog identity.
		# Reject conservatively, then demonstrate that retry after commit works.
		$pause->();
		my $creator = $node->background_psql('postgres');
		$creator->query_safe(
			'BEGIN; CREATE TABLE concurrent_create AS TABLE live;');
		my $createdpath = $creator->query_safe(
			"SELECT pg_relation_filepath('concurrent_create');");
		$node->safe_psql('postgres', 'CHECKPOINT;');
		my $offset = -s $node->logfile;
		$resume->();
		check_rejection($node, $createdpath, $offset);
		$creator->query_safe('COMMIT;');
		$creator->quit;
		enable_data_checksums($node, wait => 'on');
		disable_data_checksums($node, wait => 1);

		# The relation snapshot is obsolete after a committed DROP or rewrite.
		# Reconciliation must recheck identity rather than trust that snapshot.
		$pause->();
		$node->safe_psql('postgres',
			'DROP TABLE concurrent_create; VACUUM FULL live; CHECKPOINT;');
		$resume->();
		wait_finished($node, 'on');
		is($node->safe_psql('postgres', 'SELECT count(*) FROM live;'),
			'1000',
			'committed rewrite and concurrent removal reconcile safely');
		disable_data_checksums($node, wait => 1);
	};
}

# A standby-local orphan is not visible to the primary's physical scan.
# Successful enabling on the primary must not be mistaken for a guarantee
# about out-of-band files on other nodes.
$node->backup('standby');
my $standby = PostgreSQL::Test::Cluster->new('local_orphan');
$standby->init_from_backup($node, 'standby', has_streaming => 1);
copy($saved, $standby->data_dir . "/$orphanpath") or die $!;
$standby->start;
enable_data_checksums($node, wait => 'on');
$node->wait_for_catchup($standby);
wait_for_checksum_state($standby, 'on');
is(slurp_file($standby->data_dir . "/$orphanpath"),
	slurp_file($saved),
	'primary enabling cannot rewrite a standby-local orphan');
my $backupdir = $standby->backup_dir . '/orphan';
$standby->command_checks_all(
	[
		'pg_basebackup', '-D',
		$backupdir, '--format=tar',
		'--wal-method=stream', '--no-sync',
		'--checkpoint=fast'
	],
	1,
	[qr/^$/],
	[qr/checksum verification failed in file "[^"]*\/\Q$filenode\E", block/],
	'standby backup still reports its local orphan despite primary enabling');
rmtree($backupdir);
$standby->stop;
$node->stop;

done_testing();
