
# Copyright (c) 2026, PostgreSQL Global Development Group

# Test base backups running while the data checksum state changes.  The
# transition to "on" happens before the checkpoint which flushes the rewritten
# pages, so a backup straddling it reads on-disk pages which legitimately lack
# checksums and carry LSNs older than the backup start.  The same applies to
# checksums being disabled and re-enabled while a backup runs: hint bit
# updates made while checksums were off reach disk without a checksum update
# and without moving the page LSN, so once the re-enabling completes the
# backup would resume verification and misjudge those pages until the
# rewritten versions are flushed.
#
# Both scenarios hold the two sides with injection points: the backup after
# its starting checkpoint but before it sends any file data, and the enabling
# after the state changed to "on" but before the checkpoint which flushes the
# rewritten pages.  The backup is thus guaranteed to read the stale on-disk
# pages after the state change, without any timing assumptions.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use IPC::Run;

use FindBin;
use lib $FindBin::RealBin;

use DataChecksums::Utils;

if ($ENV{enable_injection_points} ne 'yes')
{
	plan skip_all => 'Injection points not supported by this build';
}

my $node = PostgreSQL::Test::Cluster->new('backup_node');
$node->init(no_data_checksums => 1, allows_streaming => 1);
# The pages rewritten while enabling must stay dirty in shared buffers until
# the final checkpoint, otherwise they reach disk with checksums on their own
# and nothing is left to misjudge.  Autovacuum is disabled so that nothing
# sets hint bits behind our back, and wal_log_hints (implied by
# allows_streaming) must be off so that setting them does not move the page
# LSNs past the backup start.
$node->append_conf('postgresql.conf', 'shared_buffers = 128MB');
$node->append_conf('postgresql.conf', 'autovacuum = off');
$node->append_conf('postgresql.conf', 'wal_log_hints = off');
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION injection_points;');

# A body of relation pages for the backup to misjudge.  The scan pulls the
# table into shared buffers so that enabling doesn't read it through a ring
# buffer, which would write the pages back out.
$node->safe_psql('postgres',
	"CREATE TABLE t AS SELECT generate_series(1,100000) AS a;");
$node->safe_psql('postgres', "SELECT count(*) FROM t;");
test_checksum_state($node, 'off');

$node->safe_psql('postgres',
	"SELECT injection_points_attach('basebackup-before-send-files','wait');");
$node->safe_psql('postgres',
	"SELECT injection_points_attach('datachecksums-on-before-checkpoint','wait');"
);

my $backupdir = $node->backup_dir . '/straddle';
my ($out, $err) = ('', '');
my $backup = IPC::Run::start(
	[
		'pg_basebackup', '-D', $backupdir,
		'--wal-method=none', '--no-sync',
		'--checkpoint=fast',
		'-d', $node->connstr('postgres')
	],
	'>', \$out, '2>', \$err,
	IPC::Run::timeout(180));

$node->wait_for_event('walsender', 'basebackup-before-send-files');

# Enable checksums while the backup is held, then release the backup once the
# enabling has reached the "on" state and is held before its checkpoint.
enable_data_checksums($node);
$node->wait_for_event('datachecksums launcher',
	'datachecksums-on-before-checkpoint');

$node->safe_psql('postgres',
	"SELECT injection_points_wakeup('basebackup-before-send-files');");
$node->safe_psql('postgres',
	"SELECT injection_points_detach('basebackup-before-send-files');");

ok($backup->finish, 'backup straddling enable completion succeeds')
  or diag("stderr: $err");

$node->safe_psql('postgres',
	"SELECT injection_points_wakeup('datachecksums-on-before-checkpoint');");
$node->safe_psql('postgres',
	"SELECT injection_points_detach('datachecksums-on-before-checkpoint');");

wait_for_checksum_state($node, 'on');
$node->poll_query_until('postgres',
	    "SELECT count(*) = 0 FROM pg_catalog.pg_stat_activity "
	  . "WHERE backend_type = 'datachecksums launcher';");

my $result = $node->safe_psql('postgres',
	"SELECT coalesce(sum(checksum_failures), 0) FROM pg_catalog.pg_stat_database;"
);
is($result, '0', 'no spurious checksum failures after enable');

# A backup started once enabling has completed must verify, and pass
$node->command_ok(
	[
		'pg_basebackup', '-D', $node->backup_dir . '/after_enable',
		'--wal-method=none', '--no-sync', '--checkpoint=fast'
	],
	'backup after enable completion succeeds');

# Now test a backup which straddles checksums being disabled and re-enabled.
# Recreate the table since the earlier scan set its hint bits and the rewrite
# gave the pages checksums; the new contents are not read here, leaving the
# hint bits unset until checksums are off.
$node->safe_psql('postgres', "DROP TABLE t;");
$node->safe_psql('postgres',
	"CREATE TABLE t AS SELECT generate_series(1,100000) AS a;");

$node->safe_psql('postgres',
	"SELECT injection_points_attach('basebackup-before-send-files','wait');");

$backupdir = $node->backup_dir . '/onoffon';
($out, $err) = ('', '');
$backup = IPC::Run::start(
	[
		'pg_basebackup', '-D', $backupdir,
		'--wal-method=none', '--no-sync',
		'--checkpoint=fast',
		'-d', $node->connstr('postgres')
	],
	'>', \$out, '2>', \$err,
	IPC::Run::timeout(180));

$node->wait_for_event('walsender', 'basebackup-before-send-files');

disable_data_checksums($node, wait => 1);

# With checksums off, the scan sets hint bits without WAL logging them, and
# the checkpoint flushes the modified pages without updating their checksums.
# The on-disk pages now carry stale checksums and LSNs older than the backup
# start.
$node->safe_psql('postgres', "SELECT count(*) FROM t;");
$node->safe_psql('postgres', "CHECKPOINT;");

$node->safe_psql('postgres',
	"SELECT injection_points_attach('datachecksums-on-before-checkpoint','wait');"
);

enable_data_checksums($node);
$node->wait_for_event('datachecksums launcher',
	'datachecksums-on-before-checkpoint');

$node->safe_psql('postgres',
	"SELECT injection_points_wakeup('basebackup-before-send-files');");
$node->safe_psql('postgres',
	"SELECT injection_points_detach('basebackup-before-send-files');");

ok($backup->finish, 'backup straddling disable and re-enable succeeds')
  or diag("stderr: $err");

$node->safe_psql('postgres',
	"SELECT injection_points_wakeup('datachecksums-on-before-checkpoint');");
$node->safe_psql('postgres',
	"SELECT injection_points_detach('datachecksums-on-before-checkpoint');");

wait_for_checksum_state($node, 'on');
$node->poll_query_until('postgres',
	    "SELECT count(*) = 0 FROM pg_catalog.pg_stat_activity "
	  . "WHERE backend_type = 'datachecksums launcher';");

$result = $node->safe_psql('postgres',
	"SELECT coalesce(sum(checksum_failures), 0) FROM pg_catalog.pg_stat_database;"
);
is($result, '0', 'no spurious checksum failures after disable and re-enable');

# A backup started once re-enabling has completed must verify, and pass
$node->command_ok(
	[
		'pg_basebackup', '-D', $node->backup_dir . '/after_onoffon',
		'--wal-method=none', '--no-sync', '--checkpoint=fast'
	],
	'backup after re-enable completion succeeds');

$node->stop;
done_testing();
