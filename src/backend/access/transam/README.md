src/backend/access/transam/README

The Transaction System
======================

PostgreSQL's transaction system is a three-layer system.  The bottom layer
implements low-level transactions and subtransactions, on top of which rests
the mainloop's control code, which in turn implements user-visible
transactions and savepoints.

The middle layer of code is called by postgres.c before and after the
processing of each query, or after detecting an error:

		StartTransactionCommand
		CommitTransactionCommand
		AbortCurrentTransaction

Meanwhile, the user can alter the system's state by issuing the SQL commands
BEGIN, COMMIT, ROLLBACK, SAVEPOINT, ROLLBACK TO or RELEASE.  The traffic cop
redirects these calls to the toplevel routines

		BeginTransactionBlock
		EndTransactionBlock
		UserAbortTransactionBlock
		DefineSavepoint
		RollbackToSavepoint
		ReleaseSavepoint

respectively.  Depending on the current state of the system, these functions
call low level functions to activate the real transaction system:

		StartTransaction
		CommitTransaction
		AbortTransaction
		CleanupTransaction
		StartSubTransaction
		CommitSubTransaction
		AbortSubTransaction
		CleanupSubTransaction

Additionally, within a transaction, CommandCounterIncrement is called to
increment the command counter, which allows future commands to "see" the
effects of previous commands within the same transaction.  Note that this is
done automatically by CommitTransactionCommand after each query inside a
transaction block, but some utility functions also do it internally to allow
some operations (usually in the system catalogs) to be seen by future
operations in the same utility command.  (For example, in DefineRelation it is
done after creating the heap so the pg_class row is visible, to be able to
lock it.)


For example, consider the following sequence of user commands:

1)		BEGIN
2)		SELECT * FROM foo
3)		INSERT INTO foo VALUES (...)
4)		COMMIT

In the main processing loop, this results in the following function call
sequence:

	     /  StartTransactionCommand;
	    /       StartTransaction;
	1) <    ProcessUtility;                 << BEGIN
	    \       BeginTransactionBlock;
	     \  CommitTransactionCommand;

	    /   StartTransactionCommand;
	2) /    PortalRunSelect;                << SELECT ...
	   \    CommitTransactionCommand;
	    \       CommandCounterIncrement;

	    /   StartTransactionCommand;
	3) /    ProcessQuery;                   << INSERT ...
	   \    CommitTransactionCommand;
	    \       CommandCounterIncrement;

	     /  StartTransactionCommand;
	    /   ProcessUtility;                 << COMMIT
	4) <        EndTransactionBlock;
	    \   CommitTransactionCommand;
	     \      CommitTransaction;

The point of this example is to demonstrate the need for
StartTransactionCommand and CommitTransactionCommand to be state smart -- they
should call CommandCounterIncrement between the calls to BeginTransactionBlock
and EndTransactionBlock and outside these calls they need to do normal start,
commit or abort processing.

Furthermore, suppose the "SELECT * FROM foo" caused an abort condition. In
this case AbortCurrentTransaction is called, and the transaction is put in
aborted state.  In this state, any user input is ignored except for
transaction-termination statements, or ROLLBACK TO <savepoint> commands.

Transaction aborts can occur in two ways:

1) system dies from some internal cause  (syntax error, etc)
2) user types ROLLBACK

The reason we have to distinguish them is illustrated by the following two
situations:

	        case 1                                  case 2
	        ------                                  ------
	1) user types BEGIN                     1) user types BEGIN
	2) user does something                  2) user does something
	3) user does not like what              3) system aborts for some reason
	   she sees and types ABORT                (syntax error, etc)

In case 1, we want to abort the transaction and return to the default state.
In case 2, there may be more commands coming our way which are part of the
same transaction block; we have to ignore these commands until we see a COMMIT
or ROLLBACK.

Internal aborts are handled by AbortCurrentTransaction, while user aborts are
handled by UserAbortTransactionBlock.  Both of them rely on AbortTransaction
to do all the real work.  The only difference is what state we enter after
AbortTransaction does its work:

* AbortCurrentTransaction leaves us in TBLOCK_ABORT,
* UserAbortTransactionBlock leaves us in TBLOCK_ABORT_END

Low-level transaction abort handling is divided in two phases:
* AbortTransaction executes as soon as we realize the transaction has
  failed.  It should release all shared resources (locks etc) so that we do
  not delay other backends unnecessarily.
* CleanupTransaction executes when we finally see a user COMMIT
  or ROLLBACK command; it cleans things up and gets us out of the transaction
  completely.  In particular, we mustn't destroy TopTransactionContext until
  this point.

Also, note that when a transaction is committed, we don't close it right away.
Rather it's put in TBLOCK_END state, which means that when
CommitTransactionCommand is called after the query has finished processing,
the transaction has to be closed.  The distinction is subtle but important,
because it means that control will leave the xact.c code with the transaction
open, and the main loop will be able to keep processing inside the same
transaction.  So, in a sense, transaction commit is also handled in two
phases, the first at EndTransactionBlock and the second at
CommitTransactionCommand (which is where CommitTransaction is actually
called).

The rest of the code in xact.c are routines to support the creation and
finishing of transactions and subtransactions.  For example, AtStart_Memory
takes care of initializing the memory subsystem at main transaction start.


Subtransaction Handling
-----------------------

Subtransactions are implemented using a stack of TransactionState structures,
each of which has a pointer to its parent transaction's struct.  When a new
subtransaction is to be opened, PushTransaction is called, which creates a new
TransactionState, with its parent link pointing to the current transaction.
StartSubTransaction is in charge of initializing the new TransactionState to
sane values, and properly initializing other subsystems (AtSubStart routines).

When closing a subtransaction, either CommitSubTransaction has to be called
(if the subtransaction is committing), or AbortSubTransaction and
CleanupSubTransaction (if it's aborting).  In either case, PopTransaction is
called so the system returns to the parent transaction.

One important point regarding subtransaction handling is that several may need
to be closed in response to a single user command.  That's because savepoints
have names, and we allow to commit or rollback a savepoint by name, which is
not necessarily the one that was last opened.  Also a COMMIT or ROLLBACK
command must be able to close out the entire stack.  We handle this by having
the utility command subroutine mark all the state stack entries as commit-
pending or abort-pending, and then when the main loop reaches
CommitTransactionCommand, the real work is done.  The main point of doing
things this way is that if we get an error while popping state stack entries,
the remaining stack entries still show what we need to do to finish up.

In the case of ROLLBACK TO `<savepoint>`, we abort all the subtransactions up
through the one identified by the savepoint name, and then re-create that
subtransaction level with the same name.  So it's a completely new
subtransaction as far as the internals are concerned.

Other subsystems are allowed to start "internal" subtransactions, which are
handled by BeginInternalSubTransaction.  This is to allow implementing
exception handling, e.g. in PL/pgSQL.  ReleaseCurrentSubTransaction and
RollbackAndReleaseCurrentSubTransaction allows the subsystem to close said
subtransactions.  The main difference between this and the savepoint/release
path is that we execute the complete state transition immediately in each
subroutine, rather than deferring some work until CommitTransactionCommand.
Another difference is that BeginInternalSubTransaction is allowed when no
explicit transaction block has been established, while DefineSavepoint is not.


Transaction and Subtransaction Numbering
----------------------------------------

Transactions and subtransactions are assigned permanent XIDs only when/if
they first do something that requires one --- typically, insert/update/delete
a tuple, though there are a few other places that need an XID assigned.
If a subtransaction requires an XID, we always first assign one to its
parent.  This maintains the invariant that child transactions have XIDs later
than their parents, which is assumed in a number of places.

The subsidiary actions of obtaining a lock on the XID and entering it into
pg_subtrans and PGPROC are done at the time it is assigned.

A transaction that has no XID still needs to be identified for various
purposes, notably holding locks.  For this purpose we assign a "virtual
transaction ID" or VXID to each top-level transaction.  VXIDs are formed from
two fields, the procNumber and a backend-local counter; this arrangement
allows assignment of a new VXID at transaction start without any contention
for shared memory.  To ensure that a VXID isn't re-used too soon after backend
exit, we store the last local counter value into shared memory at backend
exit, and initialize it from the previous value for the same PGPROC slot at
backend start.  All these counters go back to zero at shared memory
re-initialization, but that's OK because VXIDs never appear anywhere on-disk.

Internally, a backend needs a way to identify subtransactions whether or not
they have XIDs; but this need only lasts as long as the parent top transaction
endures.  Therefore, we have SubTransactionId, which is somewhat like
CommandId in that it's generated from a counter that we reset at the start of
each top transaction.  The top-level transaction itself has SubTransactionId 1,
and subtransactions have IDs 2 and up.  (Zero is reserved for
InvalidSubTransactionId.)  Note that subtransactions do not have their
own VXIDs; they use the parent top transaction's VXID.


Interlocking Transaction Begin, Transaction End, and Snapshots
--------------------------------------------------------------

We try hard to minimize the amount of overhead and lock contention involved
in the frequent activities of beginning/ending a transaction and taking a
snapshot.  Unfortunately, we must have some interlocking for this, because
we must ensure consistency about the commit order of transactions.
For example, suppose an UPDATE in xact A is blocked by xact B's prior
update of the same row, and xact B is doing commit while xact C gets a
snapshot.  Xact A can complete and commit as soon as B releases its locks.
If xact C's GetSnapshotData sees xact B as still running, then it had
better see xact A as still running as well, or it will be able to see two
tuple versions - one deleted by xact B and one inserted by xact A.  Another
reason why this would be bad is that C would see (in the row inserted by A)
earlier changes by B, and it would be inconsistent for C not to see any
of B's changes elsewhere in the database.

Formally, the correctness requirement is "if a snapshot A considers
transaction X as committed, and any of transaction X's snapshots considered
transaction Y as committed, then snapshot A must consider transaction Y as
committed".

What we actually enforce is strict serialization of commits and rollbacks
with snapshot-taking: we do not allow any transaction to exit the set of
running transactions while a snapshot is being taken.  (This rule is
stronger than necessary for consistency, but is relatively simple to
enforce, and it assists with some other issues as explained below.)  The
implementation of this is that GetSnapshotData takes the ProcArrayLock in
shared mode (so that multiple backends can take snapshots in parallel),
but ProcArrayEndTransaction must take the ProcArrayLock in exclusive mode
while clearing the ProcGlobal->xids[] entry at transaction end (either
commit or abort). (To reduce context switching, when multiple transactions
commit nearly simultaneously, we have one backend take ProcArrayLock and
clear the XIDs of multiple processes at once.)

ProcArrayEndTransaction also holds the lock while advancing the shared
latestCompletedXid variable.  This allows GetSnapshotData to use
latestCompletedXid + 1 as xmax for its snapshot: there can be no
transaction >= this xid value that the snapshot needs to consider as
completed.

In short, then, the rule is that no transaction may exit the set of
currently-running transactions between the time we fetch latestCompletedXid
and the time we finish building our snapshot.  However, this restriction
only applies to transactions that have an XID --- read-only transactions
can end without acquiring ProcArrayLock, since they don't affect anyone
else's snapshot nor latestCompletedXid.

Transaction start, per se, doesn't have any interlocking with these
considerations, since we no longer assign an XID immediately at transaction
start.  But when we do decide to allocate an XID, GetNewTransactionId must
store the new XID into the shared ProcArray before releasing XidGenLock.
This ensures that all top-level XIDs <= latestCompletedXid are either
present in the ProcArray, or not running anymore.  (This guarantee doesn't
apply to subtransaction XIDs, because of the possibility that there's not
room for them in the subxid array; instead we guarantee that they are
present or the overflow flag is set.)  If a backend released XidGenLock
before storing its XID into ProcGlobal->xids[], then it would be possible for
another backend to allocate and commit a later XID, causing latestCompletedXid
to pass the first backend's XID, before that value became visible in the
ProcArray.  That would break ComputeXidHorizons, as discussed below.

We allow GetNewTransactionId to store the XID into ProcGlobal->xids[] (or the
subxid array) without taking ProcArrayLock.  This was once necessary to
avoid deadlock; while that is no longer the case, it's still beneficial for
performance.  We are thereby relying on fetch/store of an XID to be atomic,
else other backends might see a partially-set XID.  This also means that
readers of the ProcArray xid fields must be careful to fetch a value only
once, rather than assume they can read it multiple times and get the same
answer each time.  (Use volatile-qualified pointers when doing this, to
ensure that the C compiler does exactly what you tell it to.)

Another important activity that uses the shared ProcArray is
ComputeXidHorizons, which must determine a lower bound for the oldest xmin
of any active MVCC snapshot, system-wide.  Each individual backend
advertises the smallest xmin of its own snapshots in MyProc->xmin, or zero
if it currently has no live snapshots (eg, if it's between transactions or
hasn't yet set a snapshot for a new transaction).  ComputeXidHorizons takes
the MIN() of the valid xmin fields.  It does this with only shared lock on
ProcArrayLock, which means there is a potential race condition against other
backends doing GetSnapshotData concurrently: we must be certain that a
concurrent backend that is about to set its xmin does not compute an xmin
less than what ComputeXidHorizons determines.  We ensure that by including
all the active XIDs into the MIN() calculation, along with the valid xmins.
The rule that transactions can't exit without taking exclusive ProcArrayLock
ensures that concurrent holders of shared ProcArrayLock will compute the
same minimum of currently-active XIDs: no xact, in particular not the
oldest, can exit while we hold shared ProcArrayLock.  So
ComputeXidHorizons's view of the minimum active XID will be the same as that
of any concurrent GetSnapshotData, and so it can't produce an overestimate.
If there is no active transaction at all, ComputeXidHorizons uses
latestCompletedXid + 1, which is a lower bound for the xmin that might
be computed by concurrent or later GetSnapshotData calls.  (We know that no
XID less than this could be about to appear in the ProcArray, because of the
XidGenLock interlock discussed above.)

As GetSnapshotData is performance critical, it does not perform an accurate
oldest-xmin calculation (it used to, until v14). The contents of a snapshot
only depend on the xids of other backends, not their xmin. As backend's xmin
changes much more often than its xid, having GetSnapshotData look at xmins
can lead to a lot of unnecessary cacheline ping-pong.  Instead
GetSnapshotData updates approximate thresholds (one that guarantees that all
deleted rows older than it can be removed, another determining that deleted
rows newer than it can not be removed). GlobalVisTest* uses those thresholds
to make invisibility decision, falling back to ComputeXidHorizons if
necessary.

Note that while it is certain that two concurrent executions of
GetSnapshotData will compute the same xmin for their own snapshots, there is
no such guarantee for the horizons computed by ComputeXidHorizons.  This is
because we allow XID-less transactions to clear their MyProc->xmin
asynchronously (without taking ProcArrayLock), so one execution might see
what had been the oldest xmin, and another not.  This is OK since the
thresholds need only be a valid lower bound.  As noted above, we are already
assuming that fetch/store of the xid fields is atomic, so assuming it for
xmin as well is no extra risk.


pg_xact and pg_subtrans
-----------------------

pg_xact and pg_subtrans are permanent (on-disk) storage of transaction related
information.  There is a limited number of pages of each kept in memory, so
in many cases there is no need to actually read from disk.  However, if
there's a long running transaction or a backend sitting idle with an open
transaction, it may be necessary to be able to read and write this information
from disk.  They also allow information to be permanent across server restarts.

pg_xact records the commit status for each transaction that has been assigned
an XID.  A transaction can be in progress, committed, aborted, or
"sub-committed".  This last state means that it's a subtransaction that's no
longer running, but its parent has not updated its state yet.  It is not
necessary to update a subtransaction's transaction status to subcommit, so we
can just defer it until main transaction commit.  The main role of marking
transactions as sub-committed is to provide an atomic commit protocol when
transaction status is spread across multiple clog pages. As a result, whenever
transaction status spreads across multiple pages we must use a two-phase commit
protocol: the first phase is to mark the subtransactions as sub-committed, then
we mark the top level transaction and all its subtransactions committed (in
that order).  Thus, subtransactions that have not aborted appear as in-progress
even when they have already finished, and the subcommit status appears as a
very short transitory state during main transaction commit.  Subtransaction
abort is always marked in clog as soon as it occurs.  When the transaction
status all fit in a single CLOG page, we atomically mark them all as committed
without bothering with the intermediate sub-commit state.

Savepoints are implemented using subtransactions.  A subtransaction is a
transaction inside a transaction; its commit or abort status is not only
dependent on whether it committed itself, but also whether its parent
transaction committed.  To implement multiple savepoints in a transaction we
allow unlimited transaction nesting depth, so any particular subtransaction's
commit state is dependent on the commit status of each and every ancestor
transaction.

The "subtransaction parent" (pg_subtrans) mechanism records, for each
transaction with an XID, the TransactionId of its parent transaction.  This
information is stored as soon as the subtransaction is assigned an XID.
Top-level transactions do not have a parent, so they leave their pg_subtrans
entries set to the default value of zero (InvalidTransactionId).

pg_subtrans is used to check whether the transaction in question is still
running --- the main Xid of a transaction is recorded in ProcGlobal->xids[],
with a copy in PGPROC->xid, but since we allow arbitrary nesting of
subtransactions, we can't fit all Xids in shared memory, so we have to store
them on disk.  Note, however, that for each transaction we keep a "cache" of
Xids that are known to be part of the transaction tree, so we can skip looking
at pg_subtrans unless we know the cache has been overflowed.  See
storage/ipc/procarray.c for the gory details.

slru.c is the supporting mechanism for both pg_xact and pg_subtrans.  It
implements the LRU policy for in-memory buffer pages.  The high-level routines
for pg_xact are implemented in transam.c, while the low-level functions are in
clog.c.  pg_subtrans is contained completely in subtrans.c.


Write-Ahead Log Coding
----------------------

The WAL subsystem (also called XLOG in the code) exists to guarantee crash
recovery.  It can also be used to provide point-in-time recovery, as well as
hot-standby replication via log shipping.  Here are some notes about
non-obvious aspects of its design.

A basic assumption of a write AHEAD log is that log entries must reach stable
storage before the data-page changes they describe.  This ensures that
replaying the log to its end will bring us to a consistent state where there
are no partially-performed transactions.  To guarantee this, each data page
(either heap or index) is marked with the LSN (log sequence number --- in
practice, a WAL file location) of the latest XLOG record affecting the page.
Before the bufmgr can write out a dirty page, it must ensure that xlog has
been flushed to disk at least up to the page's LSN.  This low-level
interaction improves performance by not waiting for XLOG I/O until necessary.
The LSN check exists only in the shared-buffer manager, not in the local
buffer manager used for temp tables; hence operations on temp tables must not
be WAL-logged.

During WAL replay, we can check the LSN of a page to detect whether the change
recorded by the current log entry is already applied (it has been, if the page
LSN is >= the log entry's WAL location).

Usually, log entries contain just enough information to redo a single
incremental update on a page (or small group of pages).  This will work only
if the filesystem and hardware implement data page writes as atomic actions,
so that a page is never left in a corrupt partly-written state.  Since that's
often an untenable assumption in practice, we log additional information to
allow complete reconstruction of modified pages.  The first WAL record
affecting a given page after a checkpoint is made to contain a copy of the
entire page, and we implement replay by restoring that page copy instead of
redoing the update.  (This is more reliable than the data storage itself would
be because we can check the validity of the WAL record's CRC.)  We can detect
the "first change after checkpoint" by noting whether the page's old LSN
precedes the end of WAL as of the last checkpoint (the RedoRecPtr).

The general schema for executing a WAL-logged action is

1. Pin and exclusive-lock the shared buffer(s) containing the data page(s)
to be modified.

2. START_CRIT_SECTION()  (Any error during the next three steps must cause a
PANIC because the shared buffers will contain unlogged changes, which we
have to ensure don't get to disk.  Obviously, you should check conditions
such as whether there's enough free space on the page before you start the
critical section.)

3. Apply the required changes to the shared buffer(s).

4. Mark the shared buffer(s) as dirty with MarkBufferDirty().  (This must
happen before the WAL record is inserted; see notes in SyncOneBuffer().)
Note that marking a buffer dirty with MarkBufferDirty() should only
happen iff you write a WAL record; see Writing Hints below.

5. If the relation requires WAL-logging, build a WAL record using
XLogBeginInsert and XLogRegister* functions, and insert it.  (See
"Constructing a WAL record" below).  Then update the page's LSN using the
returned XLOG location.  For instance,

		XLogBeginInsert();
		XLogRegisterBuffer(...)
		XLogRegisterData(...)
		recptr = XLogInsert(rmgr_id, info);

		PageSetLSN(dp, recptr);

6. END_CRIT_SECTION()

7. Unlock and unpin the buffer(s).

Complex changes (such as a multilevel index insertion) normally need to be
described by a series of atomic-action WAL records.  The intermediate states
must be self-consistent, so that if the replay is interrupted between any
two actions, the system is fully functional.  In btree indexes, for example,
a page split requires a new page to be allocated, and an insertion of a new
key in the parent btree level, but for locking reasons this has to be
reflected by two separate WAL records.  Replaying the first record, to
allocate the new page and move tuples to it, sets a flag on the page to
indicate that the key has not been inserted to the parent yet.  Replaying the
second record clears the flag.  This intermediate state is never seen by
other backends during normal operation, because the lock on the child page
is held across the two actions, but will be seen if the operation is
interrupted before writing the second WAL record.  The search algorithm works
with the intermediate state as normal, but if an insertion encounters a page
with the incomplete-split flag set, it will finish the interrupted split by
inserting the key to the parent, before proceeding.


Constructing a WAL record
-------------------------

A WAL record consists of a header common to all WAL record types,
record-specific data, and information about the data blocks modified.  Each
modified data block is identified by an ID number, and can optionally have
more record-specific data associated with the block.  If XLogInsert decides
that a full-page image of a block needs to be taken, the data associated
with that block is not included.

The API for constructing a WAL record consists of five functions:
XLogBeginInsert, XLogRegisterBuffer, XLogRegisterData, XLogRegisterBufData,
and XLogInsert.  First, call XLogBeginInsert().  Then register all the buffers
modified, and data needed to replay the changes, using XLogRegister*
functions.  Finally, insert the constructed record to the WAL by calling
XLogInsert().

	XLogBeginInsert();

	/* register buffers modified as part of this WAL-logged action */
	XLogRegisterBuffer(0, lbuffer, REGBUF_STANDARD);
	XLogRegisterBuffer(1, rbuffer, REGBUF_STANDARD);

	/* register data that is always included in the WAL record */
	XLogRegisterData(&xlrec, SizeOfFictionalAction);

	/*
	 * register data associated with a buffer. This will not be included
	 * in the record if a full-page image is taken.
	 */
	XLogRegisterBufData(0, tuple->data, tuple->len);

	/* more data associated with the buffer */
	XLogRegisterBufData(0, data2, len2);

	/*
	 * Ok, all the data and buffers to include in the WAL record have
	 * been registered. Insert the record.
	 */
	recptr = XLogInsert(RM_FOO_ID, XLOG_FOOBAR_DO_STUFF);

Details of the API functions:

void XLogBeginInsert(void)

    Must be called before XLogRegisterBuffer and XLogRegisterData.

void XLogResetInsertion(void)

    Clear any currently registered data and buffers from the WAL record
    construction workspace.  This is only needed if you have already called
    XLogBeginInsert(), but decide to not insert the record after all.

void XLogEnsureRecordSpace(int max_block_id, int ndatas)

    Normally, the WAL record construction buffers have the following limits:

    * highest block ID that can be used is 4 (allowing five block references)
    * Max 20 chunks of registered data

    These default limits are enough for most record types that change some
    on-disk structures.  For the odd case that requires more data, or needs to
    modify more buffers, these limits can be raised by calling
    XLogEnsureRecordSpace().  XLogEnsureRecordSpace() must be called before
    XLogBeginInsert(), and outside a critical section.

void XLogRegisterBuffer(uint8 block_id, Buffer buf, uint8 flags);

    XLogRegisterBuffer adds information about a data block to the WAL record.
    block_id is an arbitrary number used to identify this page reference in
    the redo routine.  The information needed to re-find the page at redo -
    relfilelocator, fork, and block number - are included in the WAL record.

    XLogInsert will automatically include a full copy of the page contents, if
    this is the first modification of the buffer since the last checkpoint.
    It is important to register every buffer modified by the action with
    XLogRegisterBuffer, to avoid torn-page hazards.

    The flags control when and how the buffer contents are included in the
    WAL record.  Normally, a full-page image is taken only if the page has not
    been modified since the last checkpoint, and only if full_page_writes=on
    or an online backup is in progress.  The REGBUF_FORCE_IMAGE flag can be
    used to force a full-page image to always be included; that is useful
    e.g. for an operation that rewrites most of the page, so that tracking the
    details is not worth it.  For the rare case where it is not necessary to
    protect from torn pages, REGBUF_NO_IMAGE flag can be used to suppress
    full page image from being taken.  REGBUF_WILL_INIT also suppresses a full
    page image, but the redo routine must re-generate the page from scratch,
    without looking at the old page contents.  Re-initializing the page
    protects from torn page hazards like a full page image does.

    The REGBUF_STANDARD flag can be specified together with the other flags to
    indicate that the page follows the standard page layout.  It causes the
    area between pd_lower and pd_upper to be left out from the image, reducing
    WAL volume.

    If the REGBUF_KEEP_DATA flag is given, any per-buffer data registered with
    XLogRegisterBufData() is included in the WAL record even if a full-page
    image is taken.

void XLogRegisterData(char *data, int len);

    XLogRegisterData is used to include arbitrary data in the WAL record.  If
    XLogRegisterData() is called multiple times, the data are appended, and
    will be made available to the redo routine as one contiguous chunk.

void XLogRegisterBufData(uint8 block_id, char *data, int len);

    XLogRegisterBufData is used to include data associated with a particular
    buffer that was registered earlier with XLogRegisterBuffer().  If
    XLogRegisterBufData() is called multiple times with the same block ID, the
    data are appended, and will be made available to the redo routine as one
    contiguous chunk.

    If a full-page image of the buffer is taken at insertion, the data is not
    included in the WAL record, unless the REGBUF_KEEP_DATA flag is used.


Writing a REDO routine
----------------------

A REDO routine uses the data and page references included in the WAL record
to reconstruct the new state of the page.  The record decoding functions
and macros in xlogreader.c/h can be used to extract the data from the record.

When replaying a WAL record that describes changes on multiple pages, you
must be careful to lock the pages properly to prevent concurrent Hot Standby
queries from seeing an inconsistent state.  If this requires that two
or more buffer locks be held concurrently, you must lock the pages in
appropriate order, and not release the locks until all the changes are done.

Note that we must only use PageSetLSN/PageGetLSN() when we know the action
is serialised. Only Startup process may modify data blocks during recovery,
so Startup process may execute PageGetLSN() without fear of serialisation
problems. All other processes must only call PageSet/GetLSN when holding
either an exclusive buffer lock or a shared lock plus buffer header lock,
or be writing the data block directly rather than through shared buffers
while holding AccessExclusiveLock on the relation.


Writing Hints
-------------

In some cases, we write additional information to data blocks without
writing a preceding WAL record. This should only happen iff the data can
be reconstructed later following a crash and the action is simply a way
of optimising for performance. When a hint is written we use
MarkBufferDirtyHint() to mark the block dirty.

If the buffer is clean and checksums are in use then MarkBufferDirtyHint()
inserts an XLOG_FPI_FOR_HINT record to ensure that we take a full page image
that includes the hint. We do this to avoid a partial page write, when we
write the dirtied page. WAL is not written during recovery, so we simply skip
dirtying blocks because of hints when in recovery.

If you do decide to optimise away a WAL record, then any calls to
MarkBufferDirty() must be replaced by MarkBufferDirtyHint(),
otherwise you will expose the risk of partial page writes.

The all-visible hint in a heap page (PD_ALL_VISIBLE) is a special
case, because it is treated like a durable change in some respects and
a hint in other respects. It must satisfy the invariant that, if a
heap page's associated visibilitymap (VM) bit is set, then
PD_ALL_VISIBLE is set on the heap page itself. Clearing of
PD_ALL_VISIBLE is always treated like a fully-durable change to
maintain this invariant. Additionally, if checksums or wal_log_hints
are enabled, setting PD_ALL_VISIBLE is also treated like a
fully-durable change to protect against torn pages.

But, if neither checksums nor wal_log_hints are enabled, torn pages
are of no consequence if the only change is to PD_ALL_VISIBLE; so no
full heap page image is taken, and the heap page's LSN is not
updated. NB: it would be incorrect to update the heap page's LSN when
applying this optimization, even though there is an associated WAL
record, because subsequent modifiers (e.g. an unrelated UPDATE) of the
page may falsely believe that a full page image is not required.

Write-Ahead Logging for Filesystem Actions
------------------------------------------

The previous section described how to WAL-log actions that only change page
contents within shared buffers.  For that type of action it is generally
possible to check all likely error cases (such as insufficient space on the
page) before beginning to make the actual change.  Therefore we can make
the change and the creation of the associated WAL log record "atomic" by
wrapping them into a critical section --- the odds of failure partway
through are low enough that PANIC is acceptable if it does happen.

Clearly, that approach doesn't work for cases where there's a significant
probability of failure within the action to be logged, such as creation
of a new file or database.  We don't want to PANIC, and we especially don't
want to PANIC after having already written a WAL record that says we did
the action --- if we did, replay of the record would probably fail again
and PANIC again, making the failure unrecoverable.  This means that the
ordinary WAL rule of "write WAL before the changes it describes" doesn't
work, and we need a different design for such cases.

There are several basic types of filesystem actions that have this
issue.  Here is how we deal with each:

1. Adding a disk page to an existing table.

This action isn't WAL-logged at all.  We extend a table by writing a page
of zeroes at its end.  We must actually do this write so that we are sure
the filesystem has allocated the space.  If the write fails we can just
error out normally.  Once the space is known allocated, we can initialize
and fill the page via one or more normal WAL-logged actions.  Because it's
possible that we crash between extending the file and writing out the WAL
entries, we have to treat discovery of an all-zeroes page in a table or
index as being a non-error condition.  In such cases we can just reclaim
the space for re-use.

2. Creating a new table, which requires a new file in the filesystem.

We try to create the file, and if successful we make a WAL record saying
we did it.  If not successful, we can just throw an error.  Notice that
there is a window where we have created the file but not yet written any
WAL about it to disk.  If we crash during this window, the file remains
on disk as an "orphan".  It would be possible to clean up such orphans
by having database restart search for files that don't have any committed
entry in pg_class, but that currently isn't done because of the possibility
of deleting data that is useful for forensic analysis of the crash.
Orphan files are harmless --- at worst they waste a bit of disk space ---
because we check for on-disk collisions when allocating new relfilenumber
OIDs.  So cleaning up isn't really necessary.

3. Deleting a table, which requires an unlink() that could fail.

Our approach here is to WAL-log the operation first, but to treat failure
of the actual unlink() call as a warning rather than error condition.
Again, this can leave an orphan file behind, but that's cheap compared to
the alternatives.  Since we can't actually do the unlink() until after
we've committed the DROP TABLE transaction, throwing an error would be out
of the question anyway.  (It may be worth noting that the WAL entry about
the file deletion is actually part of the commit record for the dropping
transaction.)

4. Creating and deleting databases and tablespaces, which requires creating
and deleting directories and entire directory trees.

These cases are handled similarly to creating individual files, ie, we
try to do the action first and then write a WAL entry if it succeeded.
The potential amount of wasted disk space is rather larger, of course.
In the creation case we try to delete the directory tree again if creation
fails, so as to reduce the risk of wasted space.  Failure partway through
a deletion operation results in a corrupt database: the DROP failed, but
some of the data is gone anyway.  There is little we can do about that,
though, and in any case it was presumably data the user no longer wants.

In all of these cases, if WAL replay fails to redo the original action
we must panic and abort recovery.  The DBA will have to manually clean up
(for instance, free up some disk space or fix directory permissions) and
then restart recovery.  This is part of the reason for not writing a WAL
entry until we've successfully done the original action.


Skipping WAL for New RelFileLocator
--------------------------------

Under wal_level=minimal, if a change modifies a relfilenumber that ROLLBACK
would unlink, in-tree access methods write no WAL for that change.  Code that
writes WAL without calling RelationNeedsWAL() must check for this case.  This
skipping is mandatory.  If a WAL-writing change preceded a WAL-skipping change
for the same block, REDO could overwrite the WAL-skipping change.  If a
WAL-writing change followed a WAL-skipping change for the same block, a
related problem would arise.  When a WAL record contains no full-page image,
REDO expects the page to match its contents from just before record insertion.
A WAL-skipping change may not reach disk at all, violating REDO's expectation
under full_page_writes=off.  For any access method, CommitTransaction() writes
and fsyncs affected blocks before recording the commit.

Prefer to do the same in future access methods.  However, two other approaches
can work.  First, an access method can irreversibly transition a given fork
from WAL-skipping to WAL-writing by calling FlushRelationBuffers() and
smgrimmedsync().  Second, an access method can opt to write WAL
unconditionally for permanent relations.  Under these approaches, the access
method callbacks must not call functions that react to RelationNeedsWAL().

This applies only to WAL records whose replay would modify bytes stored in the
new relfilenumber.  It does not apply to other records about the relfilenumber,
such as XLOG_SMGR_CREATE.  Because it operates at the level of individual
relfilenumbers, RelationNeedsWAL() can differ for tightly-coupled relations.
Consider "CREATE TABLE t (); BEGIN; ALTER TABLE t ADD c text; ..." in which
ALTER TABLE adds a TOAST relation.  The TOAST relation will skip WAL, while
the table owning it will not.  ALTER TABLE SET TABLESPACE will cause a table
to skip WAL, but that won't affect its indexes.


Asynchronous Commit
-------------------

As of PostgreSQL 8.3 it is possible to perform asynchronous commits - i.e.,
we don't wait while the WAL record for the commit is fsync'ed.
We perform an asynchronous commit when synchronous_commit = off.  Instead
of performing an XLogFlush() up to the LSN of the commit, we merely note
the LSN in shared memory.  The backend then continues with other work.
We record the LSN only for an asynchronous commit, not an abort; there's
never any need to flush an abort record, since the presumption after a
crash would be that the transaction aborted anyway.

We always force synchronous commit when the transaction is deleting
relations, to ensure the commit record is down to disk before the relations
are removed from the filesystem.  Also, certain utility commands that have
non-roll-backable side effects (such as filesystem changes) force sync
commit to minimize the window in which the filesystem change has been made
but the transaction isn't guaranteed committed.

The walwriter regularly wakes up (via wal_writer_delay) or is woken up
(via its latch, which is set by backends committing asynchronously) and
performs an XLogBackgroundFlush().  This checks the location of the last
completely filled WAL page.  If that has moved forwards, then we write all
the changed buffers up to that point, so that under full load we write
only whole buffers.  If there has been a break in activity and the current
WAL page is the same as before, then we find out the LSN of the most
recent asynchronous commit, and write up to that point, if required (i.e.
if it's in the current WAL page).  If more than wal_writer_delay has
passed, or more than wal_writer_flush_after blocks have been written, since
the last flush, WAL is also flushed up to the current location.  This
arrangement in itself would guarantee that an async commit record reaches
disk after at most two times wal_writer_delay after the transaction
completes. However, we also allow XLogFlush to write/flush full buffers
"flexibly" (ie, not wrapping around at the end of the circular WAL buffer
area), so as to minimize the number of writes issued under high load when
multiple WAL pages are filled per walwriter cycle. This makes the worst-case
delay three wal_writer_delay cycles.

There are some other subtle points to consider with asynchronous commits.
First, for each page of CLOG we must remember the LSN of the latest commit
affecting the page, so that we can enforce the same flush-WAL-before-write
rule that we do for ordinary relation pages.  Otherwise the record of the
commit might reach disk before the WAL record does.  Again, abort records
need not factor into this consideration.

In fact, we store more than one LSN for each clog page.  This relates to
the way we set transaction status hint bits during visibility tests.
We must not set a transaction-committed hint bit on a relation page and
have that record make it to disk prior to the WAL record of the commit.
Since visibility tests are normally made while holding buffer share locks,
we do not have the option of changing the page's LSN to guarantee WAL
synchronization.  Instead, we defer the setting of the hint bit if we have
not yet flushed WAL as far as the LSN associated with the transaction.
This requires tracking the LSN of each unflushed async commit.  It is
convenient to associate this data with clog buffers: because we will flush
WAL before writing a clog page, we know that we do not need to remember a
transaction's LSN longer than the clog page holding its commit status
remains in memory.  However, the naive approach of storing an LSN for each
clog position is unattractive: the LSNs are 32x bigger than the two-bit
commit status fields, and so we'd need 256K of additional shared memory for
each 8K clog buffer page.  We choose instead to store a smaller number of
LSNs per page, where each LSN is the highest LSN associated with any
transaction commit in a contiguous range of transaction IDs on that page.
This saves storage at the price of some possibly-unnecessary delay in
setting transaction hint bits.

How many transactions should share the same cached LSN (N)?  If the
system's workload consists only of small async-commit transactions, then
it's reasonable to have N similar to the number of transactions per
walwriter cycle, since that is the granularity with which transactions will
become truly committed (and thus hintable) anyway.  The worst case is where
a sync-commit xact shares a cached LSN with an async-commit xact that
commits a bit later; even though we paid to sync the first xact to disk,
we won't be able to hint its outputs until the second xact is sync'd, up to
three walwriter cycles later.  This argues for keeping N (the group size)
as small as possible.  For the moment we are setting the group size to 32,
which makes the LSN cache space the same size as the actual clog buffer
space (independently of BLCKSZ).

It is useful that we can run both synchronous and asynchronous commit
transactions concurrently, but the safety of this is perhaps not
immediately obvious.  Assume we have two transactions, T1 and T2.  The Log
Sequence Number (LSN) is the point in the WAL sequence where a transaction
commit is recorded, so LSN1 and LSN2 are the commit records of those
transactions.  If T2 can see changes made by T1 then when T2 commits it
must be true that LSN2 follows LSN1.  Thus when T2 commits it is certain
that all of the changes made by T1 are also now recorded in the WAL.  This
is true whether T1 was asynchronous or synchronous.  As a result, it is
safe for asynchronous commits and synchronous commits to work concurrently
without endangering data written by synchronous commits.  Sub-transactions
are not important here since the final write to disk only occurs at the
commit of the top level transaction.

Changes to data blocks cannot reach disk unless WAL is flushed up to the
point of the LSN of the data blocks.  Any attempt to write unsafe data to
disk will trigger a write which ensures the safety of all data written by
that and prior transactions.  Data blocks and clog pages are both protected
by LSNs.

Changes to a temp table are not WAL-logged, hence could reach disk in
advance of T1's commit, but we don't care since temp table contents don't
survive crashes anyway.

Database writes that skip WAL for new relfilenumbers are also safe.  In these
cases it's entirely possible for the data to reach disk before T1's commit,
because T1 will fsync it down to disk without any sort of interlock.  However,
all these paths are designed to write data that no other transaction can see
until after T1 commits.  The situation is thus not different from ordinary
WAL-logged updates.

Transaction Emulation during Recovery
-------------------------------------

During Recovery we replay transaction changes in the order they occurred.
As part of this replay we emulate some transactional behaviour, so that
read only backends can take MVCC snapshots. We do this by maintaining a
list of XIDs belonging to transactions that are being replayed, so that
each transaction that has recorded WAL records for database writes exist
in the array until it commits. Further details are given in comments in
procarray.c.

Many actions write no WAL records at all, for example read only transactions.
These have no effect on MVCC in recovery and we can pretend they never
occurred at all. Subtransaction commit does not write a WAL record either
and has very little effect, since lock waiters need to wait for the
parent transaction to complete.

Not all transactional behaviour is emulated, for example we do not insert
a transaction entry into the lock table, nor do we maintain the transaction
stack in memory. Clog, multixact and commit_ts entries are made normally.
Subtrans is maintained during recovery but the details of the transaction
tree are ignored and all subtransactions reference the top-level TransactionId
directly. Since commit is atomic this provides correct lock wait behaviour
yet simplifies emulation of subtransactions considerably.

Further details on locking mechanics in recovery are given in comments
with the Lock rmgr code.