# Copyright (c) 2026, PostgreSQL Global Development Group

# Test a primary crashing inside SetDataChecksumsOn(), just before the forced
# checkpoint that flushes the rewritten pages, when those pages are resident
# in shared buffers.
#
# The rewriting worker reads through a BAS_VACUUM ring, which writes the pages
# back as the ring recycles, but a page already resident in shared buffers is
# not read through the ring: ReadBufferExtended() hands back the existing
# buffer, and it stays dirty until a checkpoint.  The control file may
# therefore not say "on" before that checkpoint has run, or crash recovery
# would resume from a checkpoint older than the transition with verification
# already enabled, and replay records that read those still-unchecksummed
# pages.  full_page_writes is off so that the records do not simply overwrite
# the pages with a full page image.

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

my $node = PostgreSQL::Test::Cluster->new('resident_enable_crash');
$node->init(no_data_checksums => 1);
$node->append_conf(
	'postgresql.conf', qq(
autovacuum = off
checkpoint_timeout = 1h
max_wal_size = 10GB
wal_level = replica
full_page_writes = off
wal_log_hints = off
shared_buffers = 512MB
bgwriter_lru_maxpages = 0
));
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION injection_points;');
$node->safe_psql('postgres', 'CREATE EXTENSION pg_buffercache;');

test_checksum_state($node, 'off');

$node->safe_psql('postgres',
	'CREATE TABLE t AS SELECT generate_series(1,100000) AS a;');
my $relpath = $node->safe_psql('postgres',
	"SELECT pg_relation_filepath('t'::regclass);");

# Establish the checkpoint that crash recovery will resume from, with the
# pages of "t" written out while checksums are still off.
$node->safe_psql('postgres', 'CHECKPOINT;');

# Dirty those pages again without emitting full page images, and leave them in
# shared buffers.  Replay of these records has to read the pages from disk.
$node->safe_psql('postgres', 'UPDATE t SET a = a + 1;');

my $dirty_before = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_buffercache "
	  . "WHERE relfilenode = pg_relation_filenode('t'::regclass) "
	  . "AND relforknumber = 0 AND isdirty;");
cmp_ok($dirty_before, '>', 0,
	'pages of t are resident and dirty before enabling checksums');

# Hold the enabling right before the checkpoint that flushes the rewritten
# pages.
$node->safe_psql('postgres',
	"SELECT injection_points_attach('datachecksums-on-before-checkpoint','wait');"
);

enable_data_checksums($node);
$node->wait_for_event('datachecksums launcher',
	'datachecksums-on-before-checkpoint');

my $ctl = `pg_controldata -D @{[ $node->data_dir ]}`;
my ($ctl_state) = $ctl =~ /Data page checksum version:\s+(\d+)/;
note("control file data_checksum_version before the crash: $ctl_state");
is($ctl_state, '3',
	'control file still says "inprogress-on" before the checkpoint');

# The rewritten pages must still be sitting dirty in shared buffers, or the
# window this test is about does not exist.
my $dirty_after = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_buffercache "
	  . "WHERE relfilenode = pg_relation_filenode('t'::regclass) "
	  . "AND relforknumber = 0 AND isdirty;");
cmp_ok($dirty_after, '>', 0,
	'rewritten pages of t are still dirty before the checkpoint');

$node->stop('immediate');

# The on-disk copy is the one written before the transition, without a
# checksum.
my $page;
open(my $fh, '<', $node->data_dir . '/' . $relpath) or die $!;
binmode $fh;
read($fh, $page, 8192);
close($fh);
my ($pd_checksum) = unpack('x8 v', $page);
note("on-disk pd_checksum of t block 0: $pd_checksum");
is($pd_checksum, 0, 'block 0 of t on disk carries no checksum');

my $started = $node->start(fail_ok => 1);
ok($started, 'primary restarts after crashing inside the online enable');

my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile);
unlike($log, qr/page verification failed/,
	'no checksum verification failures while replaying');
unlike($log, qr/invalid page in block/, 'no invalid pages while replaying');

if ($started)
{
	my ($rc, $stdout, $stderr) =
	  $node->psql('postgres', 'SELECT count(*) FROM t;');
	is($rc, 0, 'table readable after the crash restart')
	  or diag("stderr: $stderr");
	$node->stop('immediate');
}
else
{
	my @lines = grep { /FATAL|PANIC|invalid page|verification failed/ }
	  split(/\n/, $log);
	diag("log tail:\n" . join("\n", @lines));
	fail('table readable after the crash restart');
}

done_testing();
