# Copyright (c) 2026, PostgreSQL Global Development Group

# Test suite for testing memory context statistics reporting

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

if ($ENV{enable_injection_points} ne 'yes')
{
	plan skip_all => 'Injection points not supported by this build';
}
my $psql_err;
my $psql_out;
# Create and start a cluster with one node
my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf(
	'postgresql.conf',
	qq[
max_connections = 100
log_statement = none
restart_after_crash = false
]);
$node->start;
$node->safe_psql('postgres', 'CREATE EXTENSION injection_points;');

# Attaching to a client process's injection point that throws an error
$node->safe_psql('postgres',
	"select injection_points_attach('memcontext-client-injection', 'error');"
);

my $pid = $node->safe_psql('postgres',
	"SELECT pid from pg_stat_activity where backend_type='checkpointer'");

#Client should have thrown error
$node->psql(
	'postgres',
	qq(select pg_get_process_memory_contexts($pid, true);),
	stderr => \$psql_err);
like($psql_err,
	qr/error triggered for injection point memcontext-client-injection/);

#Query the same process after detaching the injection point, using some other client and it should succeed.
$node->safe_psql('postgres',
	"select injection_points_detach('memcontext-client-injection');");
my $topcontext_name = $node->safe_psql('postgres',
	"select name from pg_get_process_memory_contexts($pid, true) where path = '{1}';"
);
ok($topcontext_name = 'TopMemoryContext');

# Attaching to a target process injection point that throws an error
$node->safe_psql('postgres',
	"select injection_points_attach('memcontext-server-injection', 'error');"
);

#Server should have thrown error
$node->psql(
	'postgres',
	qq(select pg_get_process_memory_contexts($pid, true);),
	stderr => \$psql_err);

#Query the same process after detaching the injection point, using some other client and it should succeed.
$node->safe_psql('postgres',
	"select injection_points_detach('memcontext-server-injection');");
$topcontext_name = $node->safe_psql('postgres',
	"select name from pg_get_process_memory_contexts($pid, true) where path = '{1}';"
);
ok($topcontext_name = 'TopMemoryContext');

# Test that two concurrent requests to the same process results in a warning for
# one of those

$node->safe_psql('postgres',
	"SELECT injection_points_attach('memcontext-client-injection', 'wait');");
$node->safe_psql('postgres',
	"SELECT injection_points_attach('memcontext-server-wait', 'wait');");
my $psql_session1 = $node->background_psql('postgres');
$psql_session1->query_until(
	qr//,
	qq(
    SELECT pg_get_process_memory_contexts($pid, true);
));
$node->wait_for_event('client backend', 'memcontext-client-injection');
$node->psql(
	'postgres',
	qq(select pg_get_process_memory_contexts($pid, true);),
	stderr => \$psql_err);
ok($psql_err =~
	  /WARNING:  server process $pid is processing previous request/);
#Wake the client up.
$node->safe_psql('postgres',
	"SELECT injection_points_wakeup('memcontext-client-injection');");

$node->safe_psql('postgres',
	"select injection_points_detach('memcontext-client-injection');");
$node->safe_psql('postgres',
	"select injection_points_detach('memcontext-server-wait');");

# Test the client process exiting with timeout does not break the server process

$node->safe_psql('postgres',
	"SELECT injection_points_attach('memcontext-server-wait', 'wait');");
# Following client query times out, returning NULL as output
$node->psql(
	'postgres',
	qq(select name from pg_get_process_memory_contexts($pid, true) where path = '{1}';),
	stdout => \$psql_out);
ok($psql_out = 'NULL');
#Wakeup the server process up and detach the injection point.
$node->safe_psql('postgres',
	"SELECT injection_points_wakeup('memcontext-server-wait');");
$node->safe_psql('postgres',
	"select injection_points_detach('memcontext-server-wait');");
#Query the same server process again and it should succeed.
$topcontext_name = $node->safe_psql('postgres',
	"select name from pg_get_process_memory_contexts($pid, true) where path = '{1}';"
);
ok($topcontext_name = 'TopMemoryContext');

# Test if the monitoring works fine, when the client backend crashes.
$node->safe_psql('postgres',
	"select injection_points_attach('memcontext-client-injection', 'test_memcontext_reporting', 'crash', NULL);"
);

#Client will crash
$node->psql(
	'postgres',
	qq(select name from pg_get_process_memory_contexts($pid, true) where path = '{1}';),
	stderr => \$psql_err);
like($psql_err,
	qr/WARNING:  terminating connection because of crash of another server process|server closed the connection unexpectedly|connection to server was lost|could not send data to server/
);

# Wait till server restarts
$node->restart;
$node->poll_query_until('postgres', "SELECT 1;", '1');

#Querying memory stats should succeed after server start
$pid = $node->safe_psql('postgres',
	"SELECT pid from pg_stat_activity where backend_type='checkpointer'");
$topcontext_name = $node->safe_psql('postgres',
	"select name from pg_get_process_memory_contexts($pid, true) where path = '{1}';"
);
ok($topcontext_name = 'TopMemoryContext');

done_testing();
