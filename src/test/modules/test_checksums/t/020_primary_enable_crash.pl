# Copyright (c) 2026, PostgreSQL Global Development Group

# Test a primary crashing inside SetDataChecksumsOn(), just before the forced
# checkpoint that flushes the rewritten pages, with crash recovery resuming
# from a checkpoint older than the transition.
#
# The control file must still say "inprogress-on" there.  Replay does not
# adopt the state of the checkpoint record it resumes from, so an "on" written
# before the flush would stay in effect while replay reads pages whose rewrite
# never reached disk.  Here the pages went out through the rewriting worker's
# ring buffer, so only the control file state discriminates; see
# 022_resident_enable_crash.pl for the case where they did not.

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

my $node = PostgreSQL::Test::Cluster->new('primary_enable_crash');
$node->init(no_data_checksums => 1);
$node->append_conf(
	'postgresql.conf', qq(
autovacuum = off
checkpoint_timeout = 1h
max_wal_size = 10GB
full_page_writes = off
shared_buffers = 512MB
bgwriter_lru_maxpages = 0
));
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION injection_points;');
$node->safe_psql('postgres', 'CREATE EXTENSION pg_buffercache;');

test_checksum_state($node, 'off');

$node->safe_psql('postgres',
	'CREATE TABLE t AS SELECT generate_series(1,10000) AS a;');

# Establish the checkpoint that crash recovery will resume from.
$node->safe_psql('postgres', 'CHECKPOINT;');

# Dirty the pages of "t" without full page images, then push them out to disk
# while checksums are still off.
$node->safe_psql('postgres', 'UPDATE t SET a = a + 1;');
my $relpath = $node->safe_psql('postgres',
	"SELECT pg_relation_filepath('t'::regclass);");
my $evicted = $node->safe_psql('postgres',
	"SELECT pg_buffercache_evict_relation('t'::regclass);");
note("evict_relation on t: $evicted, relpath $relpath");

# Stop the enable right after the control file has been updated to "on" but
# before the checkpoint that flushes the rewritten pages.
$node->safe_psql('postgres',
	"SELECT injection_points_attach('datachecksums-on-before-checkpoint','wait');"
);
$node->safe_psql('postgres', 'SELECT pg_enable_data_checksums();');

$node->poll_query_until('postgres',
	"SELECT count(*) > 0 FROM pg_stat_activity WHERE wait_event = 'datachecksums-on-before-checkpoint';"
) or die 'timed out waiting for the injection point';

my $ctl = `pg_controldata -D @{[ $node->data_dir ]}`;
my ($ctl_state) = $ctl =~ /Data page checksum version:\s+(\d+)/;
note("control file data_checksum_version before the crash: $ctl_state");
is($ctl_state, '3',
	'control file still says "inprogress-on" before the checkpoint');

$node->stop('immediate');

# Show the on-disk checksum field of the first page of "t".
my $page;
open(my $fh, '<', $node->data_dir . '/' . $relpath) or die $!;
binmode $fh;
read($fh, $page, 8192);
close($fh);
my ($pd_checksum) = unpack('x8 v', $page);
note("on-disk pd_checksum of t block 0: $pd_checksum");

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
