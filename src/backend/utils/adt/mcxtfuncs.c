/*-------------------------------------------------------------------------
 *
 * mcxtfuncs.c
 *	  Functions to show backend memory context.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  src/backend/utils/adt/mcxtfuncs.c
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "access/xact.h"
#include "funcapi.h"
#include "mb/pg_wchar.h"
#include "miscadmin.h"
#include "storage/dsm_registry.h"
#include "storage/proc.h"
#include "storage/procarray.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/hsearch.h"
#include "utils/injection_point.h"
#include "utils/memutils.h"
#include "utils/wait_event_types.h"

/*
 * Memory Context reporting size limits.
 */

/* Max length of context name and ident, to keep it consistent
 * with ProcessLogMemoryContext()
 */
#define MEMORY_CONTEXT_IDENT_SHMEM_SIZE 100
#define MEMORY_CONTEXT_NAME_SHMEM_SIZE 100

/* Maximum size (in bytes) of DSA area per process */
#define MEMORY_CONTEXT_REPORT_MAX_PER_BACKEND  ((size_t) (1 * 1024 * 1024))

/*
 * Maximum number of memory context statistics is calculated by dividing
 * max memory allocated per backend with maximum size per context statistics.
 * The identifier and name are statically allocated arrays of size 100 bytes.
 * The path depth is limited to 100 like for memory context logging.
 */
#define MAX_MEMORY_CONTEXT_STATS_NUM MEMORY_CONTEXT_REPORT_MAX_PER_BACKEND / (sizeof(MemoryStatsEntry))

/*
 * Size of dshash key. The key is a uint32 rendered as a string, 10 chars
 * plus space for a NULL terminator can hold all the values.
 */
#define CLIENT_KEY_SIZE (10 + 1)

/* Dynamic shared memory state for reporting statistics per context */
typedef struct MemoryStatsEntry
{
	char		name[MEMORY_CONTEXT_NAME_SHMEM_SIZE];
	char		ident[MEMORY_CONTEXT_IDENT_SHMEM_SIZE];
	int			path[100];
	NodeTag		type;
	int			path_length;
	int			levels;
	int64		totalspace;
	int64		nblocks;
	int64		freespace;
	int64		freechunks;
	int			num_agg_stats;
} MemoryStatsEntry;

/*
 * Per backend dynamic shared hash entry for memory context statistics
 * reporting.
 */
typedef struct MemoryStatsDSHashEntry
{
	char		key[64];
	ConditionVariable memcxt_cv;
	bool		stats_written;
	int			target_server_id;
	int			total_stats;
	bool		summary;
	dsa_pointer memstats_dsa_pointer;
} MemoryStatsDSHashEntry;

static const dshash_parameters memctx_dsh_params = {
	offsetof(MemoryStatsDSHashEntry, memcxt_cv),
	sizeof(MemoryStatsDSHashEntry),
	dshash_strcmp,
	dshash_strhash,
	dshash_strcpy
};

/*
 * These are used for reporting memory context statistics of a process.
 */

/* Array to store the keys of MemoryStatsDsHash */
static int *client_keys = NULL;

/*
 * Table to store pointers to DSA memory containing memory statistics and other
 * metadata. There is one entry per client backend request, keyed by ProcNumber
 * of the client obtained from client_keys array above.
 */
static dshash_table *MemoryStatsDsHash = NULL;

/*
 * Dsa area which stores the actual memory context
 * statistics.
 */
static dsa_area *MemoryStatsDsaArea = NULL;

static void memstats_dsa_cleanup(char *key);
static void memstats_client_key_reset(int ProcNumber);
static void PublishMemoryContext(MemoryStatsEntry *memcxt_info,
								 int curr_id, MemoryContext context,
								 List *path,
								 MemoryContextCounters stat,
								 int num_contexts);

/* ----------
 * The max bytes for showing identifiers of MemoryContext.
 * This is used by pg_get_backend_memory_context - view used for local backend.
 * ----------
 */
#define MEMORY_CONTEXT_IDENT_DISPLAY_SIZE	1024

#define MAX_PATH_DISPLAY_LENGTH	100
/* Timeout in seconds */
#define MEMORY_STATS_MAX_TIMEOUT 5

/*
 * MemoryContextId
 *		Used for storage of transient identifiers for memory context reporting
 */
typedef struct MemoryContextId
{
	MemoryContext context;
	int			context_id;
} MemoryContextId;

/*
 * int_list_to_array
 *		Convert an IntList to an array of INT4OIDs.
 */
static Datum
int_list_to_array(const List *list)
{
	Datum	   *datum_array;
	int			length;
	ArrayType  *result_array;

	length = list_length(list);
	datum_array = palloc_array(Datum, length);

	foreach_int(i, list)
		datum_array[foreach_current_index(i)] = Int32GetDatum(i);

	result_array = construct_array_builtin(datum_array, length, INT4OID);

	return PointerGetDatum(result_array);
}

/*
 * context_type_to_string
 *		Returns a textual representation of a context type
 *
 * This should cover the same types as MemoryContextIsValid.
 */
static const char *
context_type_to_string(NodeTag type)
{
	const char *context_type;

	switch (type)
	{
		case T_AllocSetContext:
			context_type = "AllocSet";
			break;
		case T_GenerationContext:
			context_type = "Generation";
			break;
		case T_SlabContext:
			context_type = "Slab";
			break;
		case T_BumpContext:
			context_type = "Bump";
			break;
		default:
			context_type = "???";
			break;
	}
	return context_type;
}

/*
 * compute_context_path
 *
 * Append the transient context_id of this context and each of its ancestors
 * to a list, in order to compute a path.
 */
static List *
compute_context_path(MemoryContext c, HTAB *context_id_lookup)
{
	bool		found;
	List	   *path = NIL;
	MemoryContext cur_context;

	for (cur_context = c; cur_context != NULL; cur_context = cur_context->parent)
	{
		MemoryContextId *cur_entry;

		cur_entry = hash_search(context_id_lookup, &cur_context, HASH_FIND, &found);

		if (!found)
		{
			elog(NOTICE, "hash table corrupted, can't construct path value");
			return NIL;
		}
		path = lcons_int(cur_entry->context_id, path);
	}
	return path;
}

/*
 * PutMemoryContextsStatsTupleStore
 *		Add details for the given MemoryContext to 'tupstore'.
 */
static void
PutMemoryContextsStatsTupleStore(Tuplestorestate *tupstore,
								 TupleDesc tupdesc, MemoryContext context,
								 HTAB *context_id_lookup)
{
#define PG_GET_BACKEND_MEMORY_CONTEXTS_COLS	10

	Datum		values[PG_GET_BACKEND_MEMORY_CONTEXTS_COLS];
	bool		nulls[PG_GET_BACKEND_MEMORY_CONTEXTS_COLS];
	MemoryContextCounters stat;
	List	   *path = NIL;
	const char *name;
	const char *ident;
	const char *type;

	Assert(MemoryContextIsValid(context));

	/*
	 * Figure out the transient context_id of this context and each of its
	 * ancestors.
	 */
	for (MemoryContext cur = context; cur != NULL; cur = cur->parent)
	{
		MemoryContextId *entry;
		bool		found;

		entry = hash_search(context_id_lookup, &cur, HASH_FIND, &found);

		if (!found)
			elog(ERROR, "hash table corrupted");
		path = lcons_int(entry->context_id, path);
	}

	/* Examine the context itself */
	memset(&stat, 0, sizeof(stat));
	(*context->methods->stats) (context, NULL, NULL, &stat, true);

	memset(values, 0, sizeof(values));
	memset(nulls, 0, sizeof(nulls));

	name = context->name;
	ident = context->ident;

	/*
	 * To be consistent with logging output, we label dynahash contexts with
	 * just the hash table name as with MemoryContextStatsPrint().
	 */
	if (ident && strcmp(name, "dynahash") == 0)
	{
		name = ident;
		ident = NULL;
	}

	if (name)
		values[0] = CStringGetTextDatum(name);
	else
		nulls[0] = true;

	if (ident)
	{
		int			idlen = strlen(ident);
		char		clipped_ident[MEMORY_CONTEXT_IDENT_DISPLAY_SIZE];

		/*
		 * Some identifiers such as SQL query string can be very long,
		 * truncate oversize identifiers.
		 */
		if (idlen >= MEMORY_CONTEXT_IDENT_DISPLAY_SIZE)
			idlen = pg_mbcliplen(ident, idlen, MEMORY_CONTEXT_IDENT_DISPLAY_SIZE - 1);

		memcpy(clipped_ident, ident, idlen);
		clipped_ident[idlen] = '\0';
		values[1] = CStringGetTextDatum(clipped_ident);
	}
	else
		nulls[1] = true;

	type = context_type_to_string(context->type);

	values[2] = CStringGetTextDatum(type);
	values[3] = Int32GetDatum(list_length(path));	/* level */
	values[4] = int_list_to_array(path);
	values[5] = Int64GetDatum(stat.totalspace);
	values[6] = Int64GetDatum(stat.nblocks);
	values[7] = Int64GetDatum(stat.freespace);
	values[8] = Int64GetDatum(stat.freechunks);
	values[9] = Int64GetDatum(stat.totalspace - stat.freespace);

	tuplestore_putvalues(tupstore, tupdesc, values, nulls);
	list_free(path);
}

/*
 * pg_get_backend_memory_contexts
 *		SQL SRF showing backend memory context.
 */
Datum
pg_get_backend_memory_contexts(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	int			context_id;
	List	   *contexts;
	HASHCTL		ctl;
	HTAB	   *context_id_lookup;

	ctl.keysize = sizeof(MemoryContext);
	ctl.entrysize = sizeof(MemoryContextId);
	ctl.hcxt = CurrentMemoryContext;

	context_id_lookup = hash_create("pg_get_backend_memory_contexts",
									256,
									&ctl,
									HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);

	InitMaterializedSRF(fcinfo, 0);

	/*
	 * Here we use a non-recursive algorithm to visit all MemoryContexts
	 * starting with TopMemoryContext.  The reason we avoid using a recursive
	 * algorithm is because we want to assign the context_id breadth-first.
	 * I.e. all contexts at level 1 are assigned IDs before contexts at level
	 * 2.  Because contexts closer to TopMemoryContext are less likely to
	 * change, this makes the assigned context_id more stable.  Otherwise, if
	 * the first child of TopMemoryContext obtained an additional grandchild,
	 * the context_id for the second child of TopMemoryContext would change.
	 */
	contexts = list_make1(TopMemoryContext);

	/* TopMemoryContext will always have a context_id of 1 */
	context_id = 1;

	foreach_ptr(MemoryContextData, cur, contexts)
	{
		MemoryContextId *entry;
		bool		found;

		/*
		 * Record the context_id that we've assigned to each MemoryContext.
		 * PutMemoryContextsStatsTupleStore needs this to populate the "path"
		 * column with the parent context_ids.
		 */
		entry = (MemoryContextId *) hash_search(context_id_lookup, &cur,
												HASH_ENTER, &found);
		entry->context_id = context_id++;
		Assert(!found);

		PutMemoryContextsStatsTupleStore(rsinfo->setResult,
										 rsinfo->setDesc,
										 cur,
										 context_id_lookup);

		/*
		 * Append all children onto the contexts list so they're processed by
		 * subsequent iterations.
		 */
		for (MemoryContext c = cur->firstchild; c != NULL; c = c->nextchild)
			contexts = lappend(contexts, c);
	}

	hash_destroy(context_id_lookup);

	return (Datum) 0;
}

/*
 * pg_log_backend_memory_contexts
 *		Signal a backend or an auxiliary process to log its memory contexts.
 *
 * By default, only superusers are allowed to signal to log the memory
 * contexts because allowing any users to issue this request at an unbounded
 * rate would cause lots of log messages and which can lead to denial of
 * service. Additional roles can be permitted with GRANT.
 *
 * On receipt of this signal, a backend or an auxiliary process sets the flag
 * in the signal handler, which causes the next CHECK_FOR_INTERRUPTS()
 * or process-specific interrupt handler to log the memory contexts.
 */
Datum
pg_log_backend_memory_contexts(PG_FUNCTION_ARGS)
{
	int			pid = PG_GETARG_INT32(0);
	PGPROC	   *proc;
	ProcNumber	procNumber = INVALID_PROC_NUMBER;

	/*
	 * See if the process with given pid is a backend or an auxiliary process.
	 */
	proc = BackendPidGetProc(pid);
	if (proc == NULL)
		proc = AuxiliaryPidGetProc(pid);

	/*
	 * BackendPidGetProc() and AuxiliaryPidGetProc() return NULL if the pid
	 * isn't valid; but by the time we reach kill(), a process for which we
	 * get a valid proc here might have terminated on its own.  There's no way
	 * to acquire a lock on an arbitrary process to prevent that. But since
	 * this mechanism is usually used to debug a backend or an auxiliary
	 * process running and consuming lots of memory, that it might end on its
	 * own first and its memory contexts are not logged is not a problem.
	 */
	if (proc == NULL)
	{
		/*
		 * This is just a warning so a loop-through-resultset will not abort
		 * if one backend terminated on its own during the run.
		 */
		ereport(WARNING,
				(errmsg("PID %d is not a PostgreSQL server process", pid)));
		PG_RETURN_BOOL(false);
	}

	procNumber = GetNumberFromPGProc(proc);
	if (SendProcSignal(pid, PROCSIG_LOG_MEMORY_CONTEXT, procNumber) < 0)
	{
		/* Again, just a warning to allow loops */
		ereport(WARNING,
				(errmsg("could not send signal to process %d: %m", pid)));
		PG_RETURN_BOOL(false);
	}

	PG_RETURN_BOOL(true);
}

/*
 * pg_get_process_memory_contexts
 *		Signal a backend or an auxiliary process to send its memory contexts,
 *		wait for the results and display them.
 *
 * By default, only superusers or users with ROLE_PG_READ_ALL_STATS are allowed
 * to signal a process to return the memory contexts.  Additional roles can be
 * permitted with GRANT.
 *
 * On receipt of this signal, a backend or an auxiliary process sets the flag
 * in the signal handler, which causes the next CHECK_FOR_INTERRUPTS()
 * or process-specific interrupt handler to copy the memory context details
 * to a dynamic shared memory space.
 *
 * We have defined a limit on DSA memory that could be allocated per process -
 * if the process has more memory contexts than what can fit in the allocated
 * size, the excess contexts are summarized and represented as cumulative total
 * at the end of the buffer.
 *
 * After sending the signal, wait on a condition variable. The publishing
 * backend, after copying the data to shared memory, sends a signal on that
 * condition variable. There is one condition variable per client process.
 * Once the condition variable is signalled, check if the latest memory context
 * information is available and display.
 *
 * If the publishing backend does not respond before the condition variable
 * times out, which is set to a predefined value MEMORY_STATS_MAX_TIMEOUT, give
 * up and return NULL.
 */
Datum
pg_get_process_memory_contexts(PG_FUNCTION_ARGS)
{
	int			pid = PG_GETARG_INT32(0);
	bool		summary = PG_GETARG_BOOL(1);
	PGPROC	   *proc;
	ProcNumber	procNumber;
	bool		proc_is_aux = false;
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	MemoryStatsEntry *memcxt_info;
	MemoryStatsDSHashEntry *entry;
	bool		found;
	char		key[CLIENT_KEY_SIZE];
	TimestampTz start_timestamp;

	/*
	 * See if the process with given pid is a backend or an auxiliary process
	 * and remember the type for when we requery the process later.
	 */
	proc = BackendPidGetProc(pid);
	if (proc == NULL)
	{
		proc = AuxiliaryPidGetProc(pid);
		proc_is_aux = true;
	}

	/*
	 * BackendPidGetProc() and AuxiliaryPidGetProc() return NULL if the pid
	 * isn't valid; this is however not a problem and leave with a WARNING.
	 * See comment in pg_log_backend_memory_contexts for a discussion on this.
	 */
	if (proc == NULL)
	{
		ereport(WARNING,
				errmsg("PID %d is not a PostgreSQL server process", pid));
		PG_RETURN_NULL();
	}

	procNumber = GetNumberFromPGProc(proc);

	/*
	 * Check if the server process slot is not empty and exit early Non-empty
	 * slot means some other client backend is requesting the statistics from
	 * the same server process.
	 */
	LWLockAcquire(MemContextReportingClientKeysLock, LW_EXCLUSIVE);
	if (client_keys[procNumber] != -1)
	{
		LWLockRelease(MemContextReportingClientKeysLock);
		ereport(WARNING,
				errmsg("server process %d is processing previous request",
					   pid));
		PG_RETURN_NULL();
	}
	LWLockRelease(MemContextReportingClientKeysLock);

	/*
	 * Create a DSA to allocate memory for copying memory contexts statistics.
	 * Allocate the memory in the DSA and send DSA pointer to the server
	 * process for storing the context statistics. If number of contexts
	 * exceed a predefined limit (1MB), a cumulative total is stored for such
	 * contexts.
	 *
	 * The DSA is created once for the lifetime of the server, and only
	 * attached in subsequent calls.
	 */
	if (MemoryStatsDsaArea == NULL)
		MemoryStatsDsaArea = GetNamedDSA("memory_context_statistics_dsa",
										 &found);

	/*
	 * The DSA pointers containing statistics for each client are stored in a
	 * dshash table. In addition to DSA pointer, each entry in this table also
	 * contains information about the statistics, condition variable for
	 * signalling between client and the server and miscellaneous data
	 * specific to a request. There is one entry per client request in the
	 * hash table.
	 */
	if (MemoryStatsDsHash == NULL)
		MemoryStatsDsHash = GetNamedDSHash("memory_context_statistics_dshash",
										   &memctx_dsh_params, &found);

	snprintf(key, sizeof(key), "%d", MyProcNumber);

	/*
	 * Insert an entry for this client in DSHASH table the first time this
	 * function is called. This entry is deleted when the process exits in
	 * before_shmem_exit call.
	 *
	 * dshash_find_or_insert locks the entry to prevent the publisher from
	 * reading before client has updated the entry.
	 */
	entry = dshash_find_or_insert(MemoryStatsDsHash, key, &found);
	if (!found)
	{
		entry->stats_written = false;
		ConditionVariableInit(&entry->memcxt_cv);
	}

	/*
	 * Allocate 1MB of memory for the backend to publish its statistics on
	 * every call to this function. The memory is freed at the end of the
	 * function.
	 */
	entry->memstats_dsa_pointer =
		dsa_allocate0(MemoryStatsDsaArea, MEMORY_CONTEXT_REPORT_MAX_PER_BACKEND);

	/*
	 * Specify whether a summary of statistics is requested, before signalling
	 * the server.
	 */
	entry->summary = summary;

	/*
	 * Indicate which server process statistics are being requested from. If
	 * this client times out before the last requested process can publish its
	 * statistics, it may send a new request to another server process. Since
	 * the previous server was notified, it might attempt to read the same
	 * client entry and respond incorrectly with its statistics. By storing
	 * the server ID in the client entry, we prevent any previously signalled
	 * server process from writing its statistics in the space meant for the
	 * newly requested process.
	 */
	entry->target_server_id = pid;
	dshash_release_lock(MemoryStatsDsHash, entry);

	/*
	 * Check if the publishing process slot is empty and store this clients
	 * key i.e its procNumber. This informs the publishing process that it is
	 * supposed to write statistics in the hash entry corresponding to this
	 * client.
	 */
	LWLockAcquire(MemContextReportingClientKeysLock, LW_EXCLUSIVE);
	if (client_keys[procNumber] == -1)
		client_keys[procNumber] = MyProcNumber;
	else
	{
		LWLockRelease(MemContextReportingClientKeysLock);
		ereport(WARNING,
				errmsg("server process %d is processing previous request",
					   pid));
		PG_RETURN_NULL();
	}
	LWLockRelease(MemContextReportingClientKeysLock);

	/*
	 * Send a signal to a PostgreSQL process, informing it we want it to
	 * produce information about its memory contexts.
	 */
	if (SendProcSignal(pid, PROCSIG_GET_MEMORY_CONTEXT, procNumber) < 0)
	{
		memstats_dsa_cleanup(key);
		memstats_client_key_reset(procNumber);
		ereport(WARNING,
				errmsg("could not send signal to process %d: %m",
					   pid));
		PG_RETURN_NULL();
	}
	start_timestamp = GetCurrentTimestamp();

	while (1)
	{
		long		elapsed_time;

		INJECTION_POINT("memcontext-client-injection", NULL);

		elapsed_time = TimestampDifferenceMilliseconds(start_timestamp,
													   GetCurrentTimestamp());
		/* Return if we have already exceeded the timeout */
		if (elapsed_time >= MEMORY_STATS_MAX_TIMEOUT * 1000)
		{
			memstats_dsa_cleanup(key);
			memstats_client_key_reset(procNumber);
			ConditionVariableCancelSleep();
			ereport(NOTICE,
					errmsg("request for memory context statistics for PID %d timed out",
						   pid));
			PG_RETURN_NULL();
		}

		/*
		 * Recheck the state of the backend before sleeping on the condition
		 * variable to ensure the process is still alive.  Only check the
		 * relevant process type based on the earlier PID check.
		 */
		if (proc_is_aux)
			proc = AuxiliaryPidGetProc(pid);
		else
			proc = BackendPidGetProc(pid);

		/*
		 * The target server process ending during memory context processing
		 * is not an error.
		 */
		if (proc == NULL)
		{
			memstats_dsa_cleanup(key);
			memstats_client_key_reset(procNumber);
			ConditionVariableCancelSleep();
			ereport(WARNING,
					errmsg("PID %d is no longer a PostgreSQL server process",
						   pid));
			PG_RETURN_NULL();
		}

		/*
		 * Wait for MEMORY_STATS_MAX_TIMEOUT. If no statistics are available
		 * within the allowed time then return NULL. The timer is defined in
		 * milliseconds since that's what the condition variable sleep uses.
		 */
		if (ConditionVariableTimedSleep(&entry->memcxt_cv,
										(MEMORY_STATS_MAX_TIMEOUT * 1000),
										WAIT_EVENT_MEM_CXT_PUBLISH))
		{
			/* Timeout has expired, return NULL */
			memstats_dsa_cleanup(key);
			memstats_client_key_reset(procNumber);
			ConditionVariableCancelSleep();
			ereport(NOTICE,
					errmsg("request for memory context statistics for PID %d timed out",
						   pid));
			PG_RETURN_NULL();
		}
		entry = dshash_find_or_insert(MemoryStatsDsHash, key, &found);
		Assert(found);

		memcxt_info = (MemoryStatsEntry *)
			dsa_get_address(MemoryStatsDsaArea, entry->memstats_dsa_pointer);

		/*
		 * We expect to come out of sleep when the requested process has
		 * finished publishing the statistics, verified using a boolean
		 * stats_written.
		 *
		 * Make sure that the statistics are actually written by checking that
		 * the name of the context is not NULL. This is done to ensure that
		 * the subsequent waits for statistics do not return spuriously if the
		 * previous call to the function ended in error and thus could not
		 * clear the stats_written flag.
		 */
		if (entry->stats_written && memcxt_info[0].name[0] != '\0')
			break;

		dshash_release_lock(MemoryStatsDsHash, entry);

	}

	InitMaterializedSRF(fcinfo, 0);

	/*
	 * Backend has finished publishing the stats, project them.
	 */
#define PG_GET_PROCESS_MEMORY_CONTEXTS_COLS	11
	for (int i = 0; i < entry->total_stats; i++)
	{
		ArrayType  *path_array;
		Datum		values[PG_GET_PROCESS_MEMORY_CONTEXTS_COLS];
		bool		nulls[PG_GET_PROCESS_MEMORY_CONTEXTS_COLS];
		Datum	   *path_datum = NULL;

		memset(values, 0, sizeof(values));
		memset(nulls, 0, sizeof(nulls));

		Assert(memcxt_info[i].name[0] != '\0');
		values[0] = CStringGetTextDatum(memcxt_info[i].name);

		if (memcxt_info[i].ident[0] != '\0')
			values[1] = CStringGetTextDatum(memcxt_info[i].ident);
		else
			nulls[1] = true;

		values[2] = CStringGetTextDatum(context_type_to_string(memcxt_info[i].type));

		if (memcxt_info[i].levels != 0)
			values[3] = Int32GetDatum(memcxt_info[i].levels);
		else
			nulls[3] = true;

		if (memcxt_info[i].path[0] != 0)
		{
			int			path_length;

			path_length = memcxt_info[i].path_length;
			path_datum = (Datum *) palloc(path_length * sizeof(Datum));

			for (int j = 0; j < path_length; j++)
				path_datum[j] = Int32GetDatum(memcxt_info[i].path[j]);
			path_array = construct_array_builtin(path_datum,
												 path_length,
												 INT4OID);
			values[4] = PointerGetDatum(path_array);
		}
		else
			nulls[4] = true;

		values[5] = Int64GetDatum(memcxt_info[i].totalspace);
		values[6] = Int64GetDatum(memcxt_info[i].nblocks);
		values[7] = Int64GetDatum(memcxt_info[i].freespace);
		values[8] = Int64GetDatum(memcxt_info[i].freechunks);
		values[9] = Int64GetDatum(memcxt_info[i].totalspace -
								  memcxt_info[i].freespace);
		values[10] = Int32GetDatum(memcxt_info[i].num_agg_stats);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc,
							 values, nulls);
	}
	dshash_release_lock(MemoryStatsDsHash, entry);
	memstats_dsa_cleanup(key);

	ConditionVariableCancelSleep();

	PG_RETURN_NULL();
}

/*
 * This function is executed before returning from the
 * pg_get_process_memory_contexts() function.
 * It releases the DSA memory allocated for storing the memory statistics
 * retrieved by that function. The caller must ensure that the LWLock for
 * MemoryStatsDsHash is not already held.
*/
static void
memstats_dsa_cleanup(char *key)
{
	MemoryStatsDSHashEntry *entry;

	entry = dshash_find(MemoryStatsDsHash, key, true);

	Assert(MemoryStatsDsaArea != NULL);
	dsa_free(MemoryStatsDsaArea, entry->memstats_dsa_pointer);
	entry->memstats_dsa_pointer = InvalidDsaPointer;
	entry->stats_written = false;
	entry->target_server_id = 0;

	dshash_release_lock(MemoryStatsDsHash, entry);
}

/*
 * Remove this process from the publishing process'
 * client key slot, if the stats publishing process has failed to do so.
 */
static void
memstats_client_key_reset(int procNumber)
{
	LWLockAcquire(MemContextReportingClientKeysLock, LW_EXCLUSIVE);

	if (client_keys[procNumber] == MyProcNumber)
		client_keys[procNumber] = -1;
	LWLockRelease(MemContextReportingClientKeysLock);
}

void
MemoryContextKeysShmemInit(void)
{
	bool		found;

	client_keys = (int *)
		ShmemInitStruct("MemoryContextKeys",
						MemoryContextKeysShmemSize(), &found);

	if (!found)
		MemSet(client_keys, -1, MemoryContextKeysShmemSize());
}

Size
MemoryContextKeysShmemSize(void)
{
	Size		TotalProcs = 0;

	TotalProcs = add_size(TotalProcs, NUM_AUXILIARY_PROCS);
	TotalProcs = add_size(TotalProcs, MaxBackends);

	return mul_size(TotalProcs, sizeof(int));
}

/*
 * HandleGetMemoryContextInterrupt
 *		Handle receipt of an interrupt indicating a request to publish memory
 *		contexts statistics.
 *
 * All the actual work is deferred to ProcessGetMemoryContextInterrupt() as
 * this cannot be performed in a signal handler.
 */
void
HandleGetMemoryContextInterrupt(void)
{
	InterruptPending = true;
	PublishMemoryContextPending = true;
	/* latch will be set by procsignal_sigusr1_handler */
}

/*
 * ProcessGetMemoryContextInterrupt
 *		Generate information about memory contexts used by the process.
 *
 * Performs a breadth first search on the memory context tree, thus parents
 * statistics are reported before their children in the monitoring function
 * output.
 *
 * Statistics for all the processes are shared via the same dynamic shared
 * area. Individual statistics are tracked independently in per-process DSA
 * pointers. These pointers are stored in a dshash table with key as requesting
 * clients ProcNumber.
 *
 * We calculate maximum number of context's statistics that can be displayed
 * using a pre-determined limit for memory available per process for this
 * utility and maximum size of statistics for each context.  The remaining
 * context statistics if any are captured as a cumulative total at the end of
 * individual context's statistics.
 *
 * If summary is true, we capture the level 1 and level 2 contexts statistics.
 * For that we traverse the memory context tree recursively in depth first
 * search manner to cover all the children of a parent context, to be able to
 * display a cumulative total of memory consumption by a parent at level 2 and
 * all its children.
 */
void
ProcessGetMemoryContextInterrupt(void)
{
	List	   *contexts;
	HASHCTL		ctl;
	HTAB	   *context_id_lookup;
	int			context_id = 0;
	MemoryStatsEntry *meminfo;
	MemoryContextCounters stat;
	int			num_individual_stats = 0;
	bool		found;
	MemoryStatsDSHashEntry *entry;
	char		key[CLIENT_KEY_SIZE];
	int			clientProcNumber;
	MemoryContext memstats_ctx = NULL;
	MemoryContext oldcontext = NULL;

	PublishMemoryContextPending = false;

	/*
	 * Avoid performing any shared memory operations in aborted transaction,
	 * the caller will timeout and return NULL.
	 */
	if (IsAbortedTransactionBlockState())
		return;

	INJECTION_POINT("memcontext-server-wait", NULL);

	/*
	 * Retrieve the client key for publishing statistics and reset it to -1,
	 * so other clients can request memory statistics from this process.
	 * Return if the client_key is -1, which means the requesting client has
	 * timed out.
	 */
	LWLockAcquire(MemContextReportingClientKeysLock, LW_SHARED);
	if (client_keys[MyProcNumber] == -1)
	{
		LWLockRelease(MemContextReportingClientKeysLock);
		return;
	}
	clientProcNumber = client_keys[MyProcNumber];
	client_keys[MyProcNumber] = -1;
	LWLockRelease(MemContextReportingClientKeysLock);

	/*
	 * Create a new memory context which is not a part of TopMemoryContext
	 * tree. This context is used to allocate all memory in this function.
	 * This helps in keeping the memory allocation in this function to report
	 * memory consumption statistics separate. So that it does not affect the
	 * output of this function.
	 */
	memstats_ctx = AllocSetContextCreate((MemoryContext) NULL,
										 "publish_memory_context_statistics",
										 ALLOCSET_SMALL_SIZES);
	oldcontext = MemoryContextSwitchTo(memstats_ctx);

	/*
	 * The hash table is used for constructing "path" column of the view,
	 * similar to its local backend counterpart.
	 */
	ctl.keysize = sizeof(MemoryContext);
	ctl.entrysize = sizeof(MemoryContextId);
	ctl.hcxt = CurrentMemoryContext;

	context_id_lookup = hash_create("pg_get_process_memory_contexts",
									256,
									&ctl,
									HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);

	/* List of contexts to process in the next round - start at the top. */
	contexts = list_make1(TopMemoryContext);

	/*
	 * The client process should have created the required DSA and DSHash
	 * table. Here we just attach to those.
	 */
	if (MemoryStatsDsaArea == NULL)
		MemoryStatsDsaArea = GetNamedDSA("memory_context_statistics_dsa",
										 &found);

	if (MemoryStatsDsHash == NULL)
		MemoryStatsDsHash = GetNamedDSHash("memory_context_statistics_dshash",
										   &memctx_dsh_params, &found);

	snprintf(key, CLIENT_KEY_SIZE, "%d", clientProcNumber);

	/*
	 * The entry lock is held by dshash_find_or_insert to protect writes to
	 * process specific memory. Two different processes publishing statistics
	 * do not block each other.
	 */
	entry = dshash_find_or_insert(MemoryStatsDsHash, key, &found);
	INJECTION_POINT("memcontext-server-injection", NULL);

	/*
	 * Check if the entry has been deleted due to calling process exiting, or
	 * if the caller has timed out waiting for us and have issued a request to
	 * another backend.
	 *
	 * Make sure that the client always deletes the entry after taking
	 * required lock or this function may end up writing to unallocated
	 * memory.
	 */
	if (!found || entry->target_server_id != MyProcPid)
	{
		entry->stats_written = false;

		dshash_release_lock(MemoryStatsDsHash, entry);

		hash_destroy(context_id_lookup);
		MemoryContextSwitchTo(oldcontext);
		MemoryContextReset(memstats_ctx);

		return;
	}

	/* Should be allocated by a client backend that is requesting statistics */
	Assert(entry->memstats_dsa_pointer != InvalidDsaPointer);
	meminfo = (MemoryStatsEntry *)
		dsa_get_address(MemoryStatsDsaArea, entry->memstats_dsa_pointer);

	if (entry->summary)
	{
		int			cxt_id = 0;
		List	   *path = NIL;
		MemoryContextId *contextid_entry;

		/* Copy TopMemoryContext statistics to DSA */
		memset(&stat, 0, sizeof(stat));
		(*TopMemoryContext->methods->stats) (TopMemoryContext, NULL, NULL,
											 &stat, true);
		path = lcons_int(1, path);
		PublishMemoryContext(meminfo, cxt_id, TopMemoryContext, path, stat,
							 1);

		contextid_entry = (MemoryContextId *) hash_search(context_id_lookup,
														  &TopMemoryContext,
														  HASH_ENTER, &found);
		Assert(!found);

		/*
		 * context id starts with 1
		 */
		contextid_entry->context_id = cxt_id + 1;

		/*
		 * Copy statistics for each of TopMemoryContexts children.  This
		 * includes statistics of at most 100 children per node, with each
		 * child node limited to a depth of 100 in its subtree.
		 */
		for (MemoryContext c = TopMemoryContext->firstchild; c != NULL;
			 c = c->nextchild)
		{
			MemoryContextCounters grand_totals;
			int			num_contexts = 0;

			path = NIL;
			memset(&grand_totals, 0, sizeof(grand_totals));

			cxt_id++;
			contextid_entry = (MemoryContextId *) hash_search(context_id_lookup,
															  &c, HASH_ENTER, &found);
			Assert(!found);
			contextid_entry->context_id = cxt_id + 1;

			MemoryContextStatsCounter(c, &grand_totals, &num_contexts);

			path = compute_context_path(c, context_id_lookup);

			PublishMemoryContext(meminfo, cxt_id, c, path,
								 grand_totals, num_contexts);
		}
		entry->total_stats = cxt_id + 1;
	}
	else
	{
		foreach_ptr(MemoryContextData, cur, contexts)
		{
			List	   *path = NIL;
			MemoryContextId *contextid_entry;

			contextid_entry = (MemoryContextId *) hash_search(context_id_lookup,
															  &cur,
															  HASH_ENTER, &found);
			Assert(!found);

			/*
			 * context id starts with 1
			 */
			contextid_entry->context_id = context_id + 1;

			/*
			 * Figure out the transient context_id of this context and each of
			 * its ancestors, to compute a path for this context.
			 */
			path = compute_context_path(cur, context_id_lookup);

			/* Examine the context stats */
			memset(&stat, 0, sizeof(stat));
			(*cur->methods->stats) (cur, NULL, NULL, &stat, true);

			/* Account for saving one statistics slot for cumulative reporting */
			if (context_id < (MAX_MEMORY_CONTEXT_STATS_NUM - 1))
			{
				/* Copy statistics to DSA memory */
				PublishMemoryContext(meminfo, context_id, cur, path, stat, 1);
			}
			else
			{
				meminfo[MAX_MEMORY_CONTEXT_STATS_NUM - 1].totalspace += stat.totalspace;
				meminfo[MAX_MEMORY_CONTEXT_STATS_NUM - 1].nblocks += stat.nblocks;
				meminfo[MAX_MEMORY_CONTEXT_STATS_NUM - 1].freespace += stat.freespace;
				meminfo[MAX_MEMORY_CONTEXT_STATS_NUM - 1].freechunks += stat.freechunks;
			}

			/*
			 * DSA max limit per process is reached, write aggregate of the
			 * remaining statistics.
			 *
			 * We can store contexts from 0 to max_stats - 1. When context_id
			 * is greater than max_stats, we stop reporting individual
			 * statistics when context_id equals max_stats - 2. As we use
			 * max_stats - 1 array slot for reporting cumulative statistics or
			 * "Remaining Totals".
			 */
			if (context_id == (MAX_MEMORY_CONTEXT_STATS_NUM - 2))
			{
				int			namelen = strlen("Remaining Totals");

				num_individual_stats = context_id + 1;
				strlcpy(meminfo[MAX_MEMORY_CONTEXT_STATS_NUM - 1].name,
						"Remaining Totals", namelen + 1);
				meminfo[MAX_MEMORY_CONTEXT_STATS_NUM - 1].ident[0] = '\0';
				meminfo[MAX_MEMORY_CONTEXT_STATS_NUM - 1].path[0] = 0;
				meminfo[MAX_MEMORY_CONTEXT_STATS_NUM - 1].type = 0;
				meminfo[MAX_MEMORY_CONTEXT_STATS_NUM - 1].levels = 0;
			}
			context_id++;

			for (MemoryContext c = cur->firstchild; c != NULL; c = c->nextchild)
				contexts = lappend(contexts, c);
		}

		/*
		 * Check if there are aggregated statistics or not in the result set.
		 * Statistics are individually reported when context_id <= max_stats,
		 * only if context_id > max_stats will there be aggregates.
		 */
		if (context_id <= MAX_MEMORY_CONTEXT_STATS_NUM)
		{
			entry->total_stats = context_id;
			meminfo[MAX_MEMORY_CONTEXT_STATS_NUM - 1].num_agg_stats = 1;
		}

		/*
		 * The number of contexts exceeded the space available, so report the
		 * number of aggregated memory contexts
		 */
		else
		{
			meminfo[MAX_MEMORY_CONTEXT_STATS_NUM - 1].num_agg_stats =
				context_id - num_individual_stats;

			/*
			 * Total stats equals num_individual_stats + 1 record for
			 * cumulative statistics.
			 */
			entry->total_stats = num_individual_stats + 1;
		}
	}

	entry->stats_written = true;
	dshash_release_lock(MemoryStatsDsHash, entry);
	hash_destroy(context_id_lookup);

	MemoryContextSwitchTo(oldcontext);
	MemoryContextReset(memstats_ctx);
	/* Notify waiting client backend and return */
	ConditionVariableSignal(&entry->memcxt_cv);
}

/*
 * PublishMemoryContext
 *
 * Copy the memory context statistics of a single context to a DSA memory
 */
static void
PublishMemoryContext(MemoryStatsEntry *memcxt_info, int curr_id,
					 MemoryContext context, List *path,
					 MemoryContextCounters stat, int num_contexts)
{
	char	   *ident = unconstify(char *, context->ident);
	char	   *name = unconstify(char *, context->name);

	/*
	 * To be consistent with logging output, we label dynahash contexts with
	 * just the hash table name as with MemoryContextStatsPrint().
	 */
	if (context->ident && strncmp(context->name, "dynahash", 8) == 0)
	{
		name = unconstify(char *, context->ident);
		ident = NULL;
	}

	if (name != NULL)
	{
		int			namelen = strlen(name);

		if (namelen >= MEMORY_CONTEXT_NAME_SHMEM_SIZE)
			namelen = pg_mbcliplen(name, namelen,
								   MEMORY_CONTEXT_NAME_SHMEM_SIZE - 1);

		strlcpy(memcxt_info[curr_id].name, name, namelen + 1);
	}
	else
		/* Clearing the array */
		memcxt_info[curr_id].name[0] = '\0';

	/* Trim and copy the identifier if it is not set to NULL */
	if (ident != NULL)
	{
		int			idlen = strlen(context->ident);

		/*
		 * Some identifiers such as SQL query string can be very long,
		 * truncate oversize identifiers.
		 */
		if (idlen >= MEMORY_CONTEXT_IDENT_SHMEM_SIZE)
			idlen = pg_mbcliplen(ident, idlen,
								 MEMORY_CONTEXT_IDENT_SHMEM_SIZE - 1);

		strlcpy(memcxt_info[curr_id].ident, ident, idlen + 1);
	}
	else
		memcxt_info[curr_id].ident[0] = '\0';

	/* Store the path */
	if (path == NIL)
		memcxt_info[curr_id].path[0] = 0;
	else
	{
		int			levels = Min(list_length(path), MAX_PATH_DISPLAY_LENGTH);

		memcxt_info[curr_id].path_length = levels;
		memcxt_info[curr_id].levels = list_length(path);

		foreach_int(i, path)
		{
			memcxt_info[curr_id].path[foreach_current_index(i)] = i;
			if (--levels == 0)
				break;
		}
	}
	memcxt_info[curr_id].type = context->type;
	memcxt_info[curr_id].totalspace = stat.totalspace;
	memcxt_info[curr_id].nblocks = stat.nblocks;
	memcxt_info[curr_id].freespace = stat.freespace;
	memcxt_info[curr_id].freechunks = stat.freechunks;
	memcxt_info[curr_id].num_agg_stats = num_contexts;
}

void
AtProcExit_memstats_cleanup(int code, Datum arg)
{
	int			idx = MyProcNumber;
	MemoryStatsDSHashEntry *entry;
	char		key[CLIENT_KEY_SIZE];
	bool		found;

	if (MemoryStatsDsHash != NULL)
	{
		snprintf(key, CLIENT_KEY_SIZE, "%d", idx);
		entry = dshash_find_or_insert(MemoryStatsDsHash, key, &found);

		if (found)
		{
			if (MemoryStatsDsaArea != NULL &&
				DsaPointerIsValid(entry->memstats_dsa_pointer))
				dsa_free(MemoryStatsDsaArea, entry->memstats_dsa_pointer);
		}
		dshash_delete_entry(MemoryStatsDsHash, entry);
	}
	LWLockAcquire(MemContextReportingClientKeysLock, LW_EXCLUSIVE);
	client_keys[idx] = -1;
	LWLockRelease(MemContextReportingClientKeysLock);
}
