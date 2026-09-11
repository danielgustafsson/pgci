# Copyright (c) 2026, PostgreSQL Global Development Group

# Reproduce checksum failures in base backups after online enabling leaves
# orphan relation files untouched.  Unlike the transition races exercised in
# 010_backup_straddle.pl, these failures persist after enabling and subsequent
# checkpoints have completed.
#
# Save heap files before dropping their relations, then restore them with the
# server stopped.  This deterministically models the files left by a crashed
# CREATE TABLE, without depending on the timing of crash recovery cleanup.
# Assert the current failure, rather than suppressing verification or treating
# catalog absence as sufficient reason for a backup to exclude a file.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use File::Copy qw(copy);
use File::Path qw(rmtree);
use Test::More;

use FindBin;
use lib $FindBin::RealBin;

use DataChecksums::Utils;

for my $kind ('missing', 'stale')
{
	my $node = PostgreSQL::Test::Cluster->new($kind);
	$node->init(
		no_data_checksums => $kind eq 'missing',
		allows_streaming => 1);
	$node->append_conf('postgresql.conf', 'autovacuum = off');
	$node->start;

	my $tablespace = PostgreSQL::Test::Utils::tempdir();
	my $tablespace_sql = $node->quote_str($tablespace);
	$node->safe_psql('postgres',
		"CREATE TABLESPACE orphan_ts LOCATION $tablespace_sql;");
	$node->safe_psql(
		'postgres', q{
		CREATE TABLE live AS SELECT 1 AS a FROM generate_series(1,1000);
		CREATE TABLE orphan_default AS TABLE live;
		CREATE TABLE orphan_tablespace TABLESPACE orphan_ts AS TABLE live;
		CHECKPOINT;
	});

	if ($kind eq 'stale')
	{
		disable_data_checksums($node, wait => 1);
		# Read the previously checksummed pages from disk, rather than using
		# buffers whose checksum fields need not reflect the on-disk values.
		$node->restart;
	}
	$node->safe_psql(
		'postgres', q{
		UPDATE live SET a = 2;
		UPDATE orphan_default SET a = 2;
		UPDATE orphan_tablespace SET a = 2;
		CHECKPOINT;
	});

	my %paths;
	for my $table ('orphan_default', 'orphan_tablespace')
	{
		$paths{$table} = $node->safe_psql('postgres',
			"SELECT pg_relation_filepath('$table');");
	}
	my $saved = PostgreSQL::Test::Utils::tempdir();
	$node->stop;
	for my $table (sort keys %paths)
	{
		copy($node->data_dir . "/$paths{$table}", "$saved/$table")
		  or die "could not save $table: $!";
	}

	$node->start;
	$node->safe_psql('postgres',
		'DROP TABLE orphan_default, orphan_tablespace; CHECKPOINT;');
	$node->stop;
	for my $table (sort keys %paths)
	{
		my $file = $node->data_dir . "/$paths{$table}";
		ok(!-e $file, "$kind: DROP removed $table storage");
		copy("$saved/$table", $file)
		  or die "could not restore orphan $table: $!";
	}
	$node->start;
	for my $table (sort keys %paths)
	{
		my ($filenode) = $paths{$table} =~ m{(\d+)$};
		my $spcoid =
		  $table eq 'orphan_default'
		  ? '0'
		  : "(SELECT oid FROM pg_tablespace WHERE spcname = 'orphan_ts')";
		is( $node->safe_psql(
				'postgres',
				"SELECT pg_filenode_relation($spcoid, $filenode) IS NULL;"),
			't',
			"$kind: $table file has no catalogued relation");
	}

	enable_data_checksums($node, wait => 'on');
	is( $node->safe_psql(
			'postgres', 'SELECT count(*) FROM live WHERE a = 2;'),
		'1000',
		"$kind: catalogued data remains readable after enabling");
	for my $table (sort keys %paths)
	{
		is( slurp_file($node->data_dir . "/$paths{$table}"),
			slurp_file("$saved/$table"),
			"$kind: online enabling left $table orphan unchanged");
	}

	# Tar format avoids restoring the tablespace into its original location.
	my $backupdir = $node->backup_dir . '/orphan';
	my @backup = (
		'pg_basebackup', '-D', $backupdir, '--format=tar',
		'--wal-method=none', '--no-sync', '--checkpoint=fast');
	my @failures = map {
		my ($filename) = $paths{$_} =~ m{([^/]+)$};
		qr/checksum verification failed in file "[^"]*\/\Q$filename\E", block/
	} sort keys %paths;

	for my $attempt (1 .. 2)
	{
		# In particular, another checkpoint cannot repair untouched orphans.
		$node->safe_psql('postgres', 'CHECKPOINT;');
		$node->command_checks_all(\@backup, 1, [qr/^$/], \@failures,
			"$kind: backup reports both orphans after checkpoint $attempt");
		rmtree($backupdir);
	}

	# Offline enabling scans physical files, including these same orphans.
	# This is a control, not a proposed way for base backup to hide failures.
	$node->stop;
	command_ok([ 'pg_checksums', '--disable', '-D', $node->data_dir ],
		"$kind: disable checksums offline");
	command_ok([ 'pg_checksums', '--enable', '-D', $node->data_dir ],
		"$kind: enable checksums offline");
	command_ok(
		[ 'pg_checksums', '--check', '-D', $node->data_dir ],
		"$kind: offline enabling checksummed all physical files");
	$node->start;
	$node->command_checks_all(\@backup, 0, [qr/^$/], [qr/^$/],
		"$kind: backup including orphans succeeds after offline enabling");
	rmtree($backupdir);
	$node->stop;
}

done_testing();
