# Copyright (c) 2026, PostgreSQL Global Development Group

# Online enabling must reject orphan relation files rather than leave a
# checksummed cluster whose base backups fail verification.
#
# Save heap files before dropping their relations, then restore them with the
# server stopped.  This deterministically models the files left by a crashed
# CREATE TABLE, without depending on the timing of crash recovery cleanup.
# Offline enabling remains the supported way to checksum these physical files.

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

	my $tablespace = PostgreSQL::Test::Utils::tempdir_short();
	my $tablespace_sql = $tablespace;
	$tablespace_sql =~ s/'/''/g;
	$node->safe_psql('postgres',
		"CREATE TABLESPACE orphan_ts LOCATION '$tablespace_sql';");
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

	# Each orphan must independently prevent enabling.  Remove the first one
	# reported before retrying, without depending on directory traversal order.
	my %remaining = reverse %paths;
	while (%remaining)
	{
		my $offset = -s $node->logfile;
		enable_data_checksums($node, wait => 'off');
		ok( $node->poll_query_until(
				'postgres',
				"SELECT count(*) = 0 FROM pg_stat_activity "
				  . "WHERE backend_type = 'datachecksums launcher';"),
			"$kind: failed launcher exits");
		my $log = slurp_file($node->logfile, $offset);
		my ($path) =
		  $log =~
		  /cannot enable data checksums with unaccounted relation file "([^"]+)"/;
		ok(defined($path), "$kind: reports unaccounted relation file");
		like(
			$log,
			qr/Use pg_checksums --enable while the cluster is shut down to checksum all physical relation files\./,
			"$kind: reports offline enabling hint");
		BAIL_OUT("unexpected orphan path in log: $log")
		  unless defined($path) && exists($remaining{$path});
		my $table = delete $remaining{$path};
		is( slurp_file($node->data_dir . "/$path"),
			slurp_file("$saved/$table"),
			"$kind: rejected $table orphan remains unchanged");
		$node->stop;
		unlink($node->data_dir . "/$path")
		  or die "could not remove orphan $table: $!";
		$node->start;
		test_checksum_state($node, 'off');
	}
	is( $node->safe_psql(
			'postgres', 'SELECT count(*) FROM live WHERE a = 2;'),
		'1000',
		"$kind: catalogued data remains readable after rejection");

	# Tar format avoids restoring the tablespace into its original location.
	my $backupdir = $node->backup_dir . '/orphan';
	my @backup = (
		'pg_basebackup', '-D', $backupdir, '--format=tar',
		'--wal-method=fetch', '--no-sync', '--checkpoint=fast');
	# Restore both unchanged orphans for the offline fallback.
	$node->stop;
	for my $table (sort keys %paths)
	{
		copy("$saved/$table", $node->data_dir . "/$paths{$table}")
		  or die "could not restore orphan $table: $!";
	}
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
