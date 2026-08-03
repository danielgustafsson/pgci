
# Copyright (c) 2026, PostgreSQL Global Development Group

# Enabling data checksums while the relcache is being invalidated.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin;
use lib $FindBin::RealBin;

use DataChecksums::Utils;

# debug_discard_caches only does anything where DISCARD_CACHES_ENABLED is
# defined, which follows USE_ASSERT_CHECKING; elsewhere the GUC rejects
# any value above zero and the server would refuse to start.
if (!check_pg_config('#define USE_ASSERT_CHECKING 1'))
{
	plan skip_all => 'this build does not have debug_discard_caches';
}

my $node = PostgreSQL::Test::Cluster->new('discard_caches');
$node->init(no_data_checksums => 1);
$node->append_conf('postgresql.conf', 'debug_discard_caches = 1');
$node->start;

test_checksum_state($node, 'off');

# A little user data, so the worker has relations of its own to walk
# besides the catalogs.
$node->safe_psql('postgres',
	'CREATE TABLE t AS SELECT generate_series(1, 1000) AS a');

# The whole test: the worker must survive walking the cluster while every
# catalog access flushes the caches.
enable_data_checksums($node, wait => 'on');

test_checksum_state($node, 'on');

is($node->safe_psql('postgres', 'SELECT count(*) FROM t'),
	'1000', 'the cluster survived enabling checksums');

$node->stop;

done_testing();
