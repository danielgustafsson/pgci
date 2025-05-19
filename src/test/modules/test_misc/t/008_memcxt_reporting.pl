
# Copyright (c) 2025, PostgreSQL Global Development Group

# Test process memory context reporting, right now we are testing interacting
# with aborted transactions.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('node');
$node->init;
$node->start;

# Start up a node which we can keep open in an aborted state, and grab the pid
# from the backend function. If the pid fails to get registered, the tests will
# still execute but will fail using pid 0.
my $bsession = $node->interactive_psql('postgres');
my $bpid = $bsession->query_safe('SELECT pg_backend_pid();');
my $pid = 0;
if ($bpid =~ /([0-9]{3,})/)
{
	$pid = $1;
}

# First get a memory context report from the backend in a good state
my $pre = $node->safe_psql('postgres',
	"SELECT pg_get_process_memory_contexts($pid,false,0.5);");

# Then set the backend in an aborted state and retry the process, it should
# return the previous report due to it being aborted.
$bsession->query('BEGIN;');
$bsession->query('SELECT 1/0;');
my $post = $node->safe_psql('postgres',
	"SELECT pg_get_process_memory_contexts($pid,false,0.5);");
ok($pre eq $post, "Check that aborted backend returned previous stats");

# There should be no errors in the log and the backend should still be in an
# aborted state.
$node->log_check("Check for backend exit", 0, log_unlike => [qr/FATAL/]);
ok($bsession->quit, "Check that aborted backend hadn't terminated");

# Make sure the backend has exited and cannot be queried anymore
my ($stdout, $stderr, $timed_out);
$post = $node->psql(
	'postgres', "SELECT pg_get_process_memory_contexts($pid,false,0.5);",
	stdout => \$stdout,
	stderr => \$stderr);
ok(!$post, "Check that we didn't get any results");
ok($stderr =~ /is not a PostgreSQL server process/,
	"Check STDERR for WARNING");

# Restart and again set the backend in aborted state, this time without any
# memory context report from it before aborting.
$bsession = $node->interactive_psql('postgres');
$bpid = $bsession->query_safe('SELECT pg_backend_pid();');
$pid = 0;
if ($bpid =~ /([0-9]{3,})/)
{
	$pid = $1;
}
$bsession->query('BEGIN;');
$bsession->query('SELECT 1/0;');
$post = $node->safe_psql('postgres',
	"SELECT pg_get_process_memory_contexts($pid,false,0.5);");

# Since there was no fallback we should have a NULL return and not a report.§
ok( $post eq '',
	"Check that an aborted backend returns NULL when no previous stats exist"
);
ok($bsession->quit, "Check that aborted backend hadn't terminated");

$node->stop;

done_testing();
