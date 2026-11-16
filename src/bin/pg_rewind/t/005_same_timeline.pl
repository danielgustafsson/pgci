
# Copyright (c) 2021-2026, PostgreSQL Global Development Group

#
# Cases where pg_rewind needs no rewind.  Same timeline, and a target
# that is a direct ancestor whose WAL stopped short of the divergence
# LSN.  The latter used to trip Assert "target_wal_endrec == divergerec".
#
use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin;
use lib $FindBin::RealBin;

use RewindTest;

# Same timeline
RewindTest::setup_cluster();
RewindTest::start_primary();
RewindTest::create_standby();
RewindTest::run_pg_rewind('local');
RewindTest::clean_rewind_test();

# Direct ancestor whose WAL ends before divergence
my $anc_primary = PostgreSQL::Test::Cluster->new('anc_primary');
$anc_primary->init(allows_streaming => 1);
$anc_primary->append_conf(
	'postgresql.conf', qq(
wal_keep_size = '64MB'
wal_log_hints = on
));
$anc_primary->start;

$anc_primary->safe_psql('postgres',
	"CREATE TABLE early AS SELECT generate_series(1, 1000); CHECKPOINT;");

my $anc_target = PostgreSQL::Test::Cluster->new('anc_target');
$anc_primary->backup('early');
$anc_target->init_from_backup($anc_primary, 'early');
$anc_target->start;
$anc_target->stop('fast');

$anc_primary->safe_psql('postgres',
	"CREATE TABLE late AS SELECT generate_series(1, 1000); CHECKPOINT;");

my $anc_source = PostgreSQL::Test::Cluster->new('anc_source');
$anc_primary->backup('late');
$anc_source->init_from_backup($anc_primary, 'late', has_streaming => 1);
$anc_source->start;
$anc_primary->wait_for_catchup($anc_source);
$anc_source->promote;

command_checks_all(
	[
		'pg_rewind',
		'--dry-run',
		'--source-server' => $anc_source->connstr('postgres'),
		'--target-pgdata' => $anc_target->data_dir,
	],
	0,
	[qr//],
	[qr/no rewind required/],
	'pg_rewind reports "no rewind required" for ancestor target');

$anc_primary->stop;
$anc_source->stop;

done_testing();
