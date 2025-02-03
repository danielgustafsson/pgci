/*-------------------------------------------------------------------------
 *
 * mcxtfuncs.c
 *	  Functions to show backend memory context.
 *
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  src/backend/utils/adt/mcxtfuncs.c
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "funcapi.h"
#include "mb/pg_wchar.h"
#include "miscadmin.h"
#include "access/twophase.h"
#include "catalog/pg_authid_d.h"
#include "nodes/pg_list.h"
#include "storage/proc.h"
#include "storage/procarray.h"
#include "utils/acl.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/hsearch.h"
#include "utils/memutils.h"
#include "utils/wait_event_types.h"

/* ----------
 * The max bytes for showing identifiers of MemoryContext.
 * ----------
 */

struct MemoryContextBackendState *memCtxState = NULL;
struct MemoryContextState *memCtxArea = NULL;

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
	datum_array = (Datum *) palloc(length * sizeof(Datum));

	foreach_int(i, list)
		datum_array[foreach_current_index(i)] = Int32GetDatum(i);

	result_array = construct_array_builtin(datum_array, length, INT4OID);

	return PointerGetDatum(result_array);
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
#define PG_GET_BACKEND_MEMORY_CONTEXTS_COLS	11

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

	type = AssignContextType(context->type);

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

const char *
AssignContextType(NodeTag type)
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
	return (context_type);
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
 *	Signal a backend or an auxiliary process to log its memory contexts.
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
 * By default, only superusers or users with PG_READ_ALL_STATS are allowed to
 * signal to return the memory contexts because allowing any users to issue
 * this request at an unbounded rate would cause lots of requests to be sent
 * and which can lead to denial of service. Additional roles can be permitted
 * with GRANT.
 *
 * On receipt of this signal, a backend or an auxiliary process sets the flag
 * in the signal handler, which causes the next CHECK_FOR_INTERRUPTS()
 * or process-specific interrupt handler to copy the memory context details
 * to a dynamic shared memory space.
 *
 * The shared memory buffer has a limited size - it the process has too many
 * memory contexts, the memory contexts into that do not fit are summarized
 * and represented as cumulative total at the end of the buffer.
 *
 * After sending the signal, wait on a condition variable. The publishing
 * backend, after copying the data to shared memory, sends signal on that
 * condition variable.
 * Once condition variable comes out of sleep, check if the memory context
 * information is available for read and display.
 *
 * If the publishing backend does not respond before the condition variable
 * times out, which is set to MEMSTATS_WAIT_TIMEOUT, retry for max_tries
 * number of times, which is defined by user, before giving up and
 * returning previously published statistics, if any.
 */
Datum
pg_get_process_memory_contexts(PG_FUNCTION_ARGS)
{
	int			pid = PG_GETARG_INT32(0);
	bool		get_summary = PG_GETARG_BOOL(1);
	PGPROC	   *proc;
	ProcNumber	procNumber = INVALID_PROC_NUMBER;
	int			i;
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	dsa_area   *area;
	MemoryContextEntry *memctx_info;
	int			num_retries = 0;
	TimestampTz curr_timestamp;
	int			max_tries = PG_GETARG_INT32(2);
	bool		prev_stats = false;

	/*
	 * Only superusers or users with pg_read_all_stats privileges can view the
	 * memory context statistics of another process
	 */
	if (!has_privs_of_role(GetUserId(), ROLE_PG_READ_ALL_STATS))
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("memory context statistics privilege error")));

	InitMaterializedSRF(fcinfo, 0);

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
				(errmsg("PID %d is not a PostgreSQL server process",
						pid)));
		PG_RETURN_NULL();
	}

	procNumber = GetNumberFromPGProc(proc);
	if (procNumber == MyProcNumber)
	{
		ereport(WARNING,
				(errmsg("cannot return statistics for local backend"),
				 errhint("Use pg_backend_memory_contexts view instead")));
		PG_RETURN_NULL();
	}

	LWLockAcquire(&memCtxState[procNumber].lw_lock, LW_EXCLUSIVE);
	memCtxState[procNumber].get_summary = get_summary;
	LWLockRelease(&memCtxState[procNumber].lw_lock);

	curr_timestamp = GetCurrentTimestamp();

	/*
	 * Send a signal to a postgresql process, informing it we want it to
	 * produce information about memory contexts.
	 */
	if (SendProcSignal(pid, PROCSIG_GET_MEMORY_CONTEXT, procNumber) < 0)
	{
		ereport(WARNING,
				(errmsg("could not send signal to process %d: %m", pid)));

		goto end;
	}

	/*
	 * Wait for a postgresql process to publish stats, indicated by a valid
	 * dsa pointer set by the backend. A dsa pointer could be valid if
	 * statitics have previously been published by the backend. In which case,
	 * check if statistics are not older than curr_timestamp, if they are wait
	 * for newer statistics. Wait for max_tries * MEMSTATS_WAIT_TIMEOUT,
	 * following which display older statistics if available.
	 */
	while (1)
	{
		long		msecs;

		/*
		 * We expect to come out of sleep when the requested process has
		 * finished publishing the statistics, verified using the valid dsa
		 * pointer.
		 *
		 * Make sure that the information belongs to pid we requested
		 * information for, Otherwise loop back and wait for the server
		 * process to finish publishing statistics.
		 */
		LWLockAcquire(&memCtxState[procNumber].lw_lock, LW_EXCLUSIVE);
		msecs =
			TimestampDifferenceMilliseconds(curr_timestamp,
											memCtxState[procNumber].stats_timestamp);

		/*
		 * Note in procnumber.h file says that a procNumber can be re-used for
		 * a different backend immediately after a backend exits. In case an
		 * old process' data was there and not updated by the current process
		 * in the slot identified by the procNumber, the pid of the requested
		 * process and the proc_id might not match.
		 */
		if (memCtxState[procNumber].proc_id == pid)
		{
			/*
			 * Break if the latest stats have been read, indicated by
			 * statistics timestamp being newer than the current request
			 * timestamp.
			 */
			if (DsaPointerIsValid(memCtxState[procNumber].memstats_dsa_pointer)
				&& msecs > 0)
			{
				LWLockRelease(&memCtxState[procNumber].lw_lock);
				break;
			}

		}
		LWLockRelease(&memCtxState[procNumber].lw_lock);

		/*
		 * Recheck the state of the backend before sleeping on the condition
		 * variable
		 */
		proc = BackendPidGetProc(pid);

#define MEMSTATS_WAIT_TIMEOUT 1000
		if (proc == NULL)
			proc = AuxiliaryPidGetProc(pid);
		if (proc == NULL)
		{
			ereport(WARNING,
					(errmsg("PID %d is not a PostgreSQL server process",
							pid)));
			goto end;
		}
		if (ConditionVariableTimedSleep(&memCtxState[procNumber].memctx_cv,
										MEMSTATS_WAIT_TIMEOUT,
										WAIT_EVENT_MEM_CTX_PUBLISH))
		{
			ereport(LOG,
					(errmsg("Wait for %d process to publish stats timed out, trying again",
							pid)));

			/*
			 * Wait for max_tries defined by user, display previously
			 * published statistics if any, when max_tries are over.
			 */
			if (num_retries > max_tries)
			{
				LWLockAcquire(&memCtxState[procNumber].lw_lock, LW_EXCLUSIVE);
				if (DsaPointerIsValid(memCtxState[procNumber].memstats_prev_dsa_pointer))
				{
					prev_stats = true;
					LWLockRelease(&memCtxState[procNumber].lw_lock);
					break;
				}
				else
				{
					LWLockRelease(&memCtxState[procNumber].lw_lock);
					goto end;
				}
			}
			num_retries = num_retries + 1;
		}

	}
	/* XXX. Check if this lock is required */
	LWLockAcquire(&memCtxArea->lw_lock, LW_EXCLUSIVE);
	/* Assert for dsa_handle to be valid */
	area = dsa_attach(memCtxArea->memstats_dsa_handle);
	/* We should land here only with a valid memstats_dsa_pointer */

	LWLockRelease(&memCtxArea->lw_lock);

	/*
	 * Backend has finished publishing the stats, read them
	 *
	 * Read statistics of top level 1 and 2 contexts, if get_summary is true.
	 */
	LWLockAcquire(&memCtxState[procNumber].lw_lock, LW_EXCLUSIVE);
	if (prev_stats == true)
		memctx_info = (MemoryContextEntry *) dsa_get_address(area,
															 memCtxState[procNumber].memstats_prev_dsa_pointer);
	else
		memctx_info = (MemoryContextEntry *) dsa_get_address(area,
															 memCtxState[procNumber].memstats_dsa_pointer);

	for (i = 0; i < memCtxState[procNumber].num_individual_stats; i++)
	{
		ArrayType  *path_array;
		int			path_length;
		Datum		values[PG_GET_BACKEND_MEMORY_CONTEXTS_COLS];
		bool		nulls[PG_GET_BACKEND_MEMORY_CONTEXTS_COLS];
		char	   *name;
		char	   *ident;
		Datum	   *path_datum_array;

		memset(values, 0, sizeof(values));
		memset(nulls, 0, sizeof(nulls));

		if (DsaPointerIsValid(memctx_info[i].name))
		{
			name = (char *) dsa_get_address(area, memctx_info[i].name);
			values[0] = CStringGetTextDatum(name);
		}
		else
			nulls[0] = true;
		if (DsaPointerIsValid(memctx_info[i].ident))
		{
			ident = (char *) dsa_get_address(area, memctx_info[i].ident);
			values[1] = CStringGetTextDatum(ident);
		}
		else
			nulls[1] = true;

		values[2] = CStringGetTextDatum(memctx_info[i].type);

		path_length = memctx_info[i].path_length;

		path_datum_array = (Datum *) dsa_get_address(area, memctx_info[i].path);
		path_array = construct_array_builtin(path_datum_array,
											 path_length, INT4OID);
		values[3] = PointerGetDatum(path_array);
		values[4] = Int64GetDatum(memctx_info[i].totalspace);
		values[5] = Int64GetDatum(memctx_info[i].nblocks);
		values[6] = Int64GetDatum(memctx_info[i].freespace);
		values[7] = Int64GetDatum(memctx_info[i].freechunks);
		values[8] = Int64GetDatum(memctx_info[i].totalspace -
								  memctx_info[i].freespace);
		values[9] = Int32GetDatum(memctx_info[i].num_agg_stats);
		values[10] = TimestampTzGetDatum(memCtxState[procNumber].stats_timestamp);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc,
							 values, nulls);
	}

	/* If there are more contexts, display a cumulative total of those */
	if (memCtxState[procNumber].total_stats > i)
	{
		Datum		values[PG_GET_BACKEND_MEMORY_CONTEXTS_COLS];
		bool		nulls[PG_GET_BACKEND_MEMORY_CONTEXTS_COLS];
		char	   *name;

		name = (char *) dsa_get_address(area, memctx_info[i].name);
		values[0] = CStringGetTextDatum(name);
		nulls[1] = true;
		nulls[2] = true;
		nulls[3] = true;
		values[4] = Int64GetDatum(memctx_info[i].totalspace);
		values[5] = Int64GetDatum(memctx_info[i].nblocks);
		values[6] = Int64GetDatum(memctx_info[i].freespace);
		values[7] = Int64GetDatum(memctx_info[i].freechunks);
		values[8] = Int64GetDatum(memctx_info[i].totalspace - memctx_info[i].freespace);
		values[9] = Int32GetDatum(memctx_info[i].num_agg_stats);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	LWLockRelease(&memCtxState[procNumber].lw_lock);

	ConditionVariableCancelSleep();
	dsa_detach(area);

end:
	PG_RETURN_NULL();
}

/*
 * Shared memory sizing for reporting memory context information.
 */
static Size
MemCtxShmemSize(void)
{
	Size		TotalProcs =
		add_size(MaxBackends, add_size(NUM_AUXILIARY_PROCS, max_prepared_xacts));

	return mul_size(TotalProcs, sizeof(MemoryContextBackendState));
}

/*
 * Init shared memory for reporting memory context information.
 */
void
MemCtxBackendShmemInit(void)
{
	bool		found;
	Size		TotalProcs =
		add_size(MaxBackends, add_size(NUM_AUXILIARY_PROCS, max_prepared_xacts));

	memCtxState = (MemoryContextBackendState *) ShmemInitStruct("MemoryContextBackendState",
																MemCtxShmemSize(),
																&found);
	if (!IsUnderPostmaster)
	{
		Assert(!found);

		for (int i = 0; i < TotalProcs; i++)
		{
			ConditionVariableInit(&memCtxState[i].memctx_cv);

			LWLockInitialize(&memCtxState[i].lw_lock,
							 LWLockNewTrancheId());
			LWLockRegisterTranche(memCtxState[i].lw_lock.tranche,
								  "mem_context_backend_stats_reporting");

			memCtxState[i].memstats_dsa_pointer = InvalidDsaPointer;
			memCtxState[i].memstats_prev_dsa_pointer = InvalidDsaPointer;
		}
	}
	else
	{
		Assert(found);
	}
}

/*
 * Initialize shared memory for displaying memory
 * context statistics
 */
void
MemCtxShmemInit(void)
{
	bool		found;

	memCtxArea = (MemoryContextState *) ShmemInitStruct("MemoryContextState", sizeof(MemoryContextState),
														&found);
	if (!IsUnderPostmaster)
	{
		Assert(!found);

		LWLockInitialize(&memCtxArea->lw_lock,
						 LWLockNewTrancheId());
		LWLockRegisterTranche(memCtxArea->lw_lock.tranche,
							  "mem_context_stats_reporting");
		memCtxArea->memstats_dsa_handle = DSA_HANDLE_INVALID;
	}
	else
	{
		Assert(found);
	}
}
