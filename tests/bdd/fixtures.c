/* Test-only page surgery; this library is never installed in the extension image. */
#include "postgres.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "access/heapam.h"
#include "access/htup_details.h"
#include "access/relation.h"
#include "access/table.h"
#include "access/xloginsert.h"
#include "access/xact.h"
#include "access/genam.h"
#include "catalog/indexing.h"
#include "catalog/pg_index.h"
#include "storage/bufmgr.h"
#include "storage/smgr.h"
#include "utils/syscache.h"

PG_MODULE_MAGIC;
PG_FUNCTION_INFO_V1(pc_test_legacy_xmin);
PG_FUNCTION_INFO_V1(pc_test_corrupt_page);
PG_FUNCTION_INFO_V1(pc_test_empty_index_state);
PG_FUNCTION_INFO_V1(pc_test_corrupt_index_byte);
PG_FUNCTION_INFO_V1(pc_test_zero_index_page);
PG_FUNCTION_INFO_V1(pc_test_corrupt_index_page);

Datum
pc_test_empty_index_state(PG_FUNCTION_ARGS)
{
    Relation index_rel;
    Relation pg_index;
    HeapTuple tuple;
    Form_pg_index form;
    Oid index_oid = PG_GETARG_OID(0);

    if (!superuser())
        elog(ERROR, "invalid-index fixture requires superuser");
    index_rel = relation_open(index_oid, AccessExclusiveLock);
    if (index_rel->rd_rel->relkind != RELKIND_INDEX)
        elog(ERROR, "invalid-index fixture requires an index");
#if PG_VERSION_NUM >= 160000
    RelationSetNewRelfilenumber(index_rel, index_rel->rd_rel->relpersistence);
#else
    RelationSetNewRelfilenode(index_rel, index_rel->rd_rel->relpersistence);
#endif

    pg_index = relation_open(IndexRelationId, RowExclusiveLock);
    tuple = SearchSysCacheCopy1(INDEXRELID, ObjectIdGetDatum(index_oid));
    if (!HeapTupleIsValid(tuple))
        elog(ERROR, "invalid-index fixture cannot find the catalog row");
    form = (Form_pg_index) GETSTRUCT(tuple);
    form->indisvalid = PG_GETARG_BOOL(1);
    form->indisready = PG_GETARG_BOOL(2);
    CatalogTupleUpdate(pg_index, &tuple->t_self, tuple);
    heap_freetuple(tuple);
    relation_close(pg_index, RowExclusiveLock);
    relation_close(index_rel, NoLock);
    CommandCounterIncrement();
    PG_RETURN_VOID();
}

Datum
pc_test_corrupt_page(PG_FUNCTION_ARGS)
{
    Relation rel;
    SMgrRelation smgr;
    BlockNumber blkno;
    int offset;
    Page page;

    if (!superuser())
        elog(ERROR, "corruption fixture requires superuser");
    rel = table_open(PG_GETARG_OID(0), AccessExclusiveLock);
    blkno = PG_GETARG_INT32(1);
    offset = PG_GETARG_INT32(2);
    if (blkno >= RelationGetNumberOfBlocks(rel) || offset < 0 || offset >= BLCKSZ)
        elog(ERROR, "corruption fixture requires an existing byte in the relation");
    smgr = RelationGetSmgr(rel);
    page = palloc(BLCKSZ);
    smgrread(smgr, MAIN_FORKNUM, blkno, page);
    page[offset] ^= 0xFF;
    smgrwrite(smgr, MAIN_FORKNUM, blkno, page, false);
    smgrimmedsync(smgr, MAIN_FORKNUM);
    pfree(page);
    table_close(rel, NoLock);
    PG_RETURN_VOID();
}

/*
 * Flip one byte of an index page through the buffer manager, so every later
 * reader (cached ReadBuffer and post-flush smgr reads alike) sees it. Unlike
 * pc_test_corrupt_page this cannot be masked by a shared buffer holding the
 * original page; use it only on clusters with data checksums disabled.
 */
Datum
pc_test_corrupt_index_byte(PG_FUNCTION_ARGS)
{
    Relation index_rel;
    Buffer buffer;
    Page page;
    BlockNumber blkno;
    int offset;

    if (!superuser())
        elog(ERROR, "index corruption fixture requires superuser");
    index_rel = index_open(PG_GETARG_OID(0), AccessExclusiveLock);
    if (index_rel->rd_rel->relkind != RELKIND_INDEX)
        elog(ERROR, "index corruption fixture requires an index");
    blkno = PG_GETARG_INT32(1);
    offset = PG_GETARG_INT32(2);
    if (blkno >= RelationGetNumberOfBlocks(index_rel) || offset < 0 || offset >= BLCKSZ)
        elog(ERROR, "index corruption fixture requires an existing byte in the relation");
    buffer = ReadBuffer(index_rel, blkno);
    LockBuffer(buffer, BUFFER_LOCK_EXCLUSIVE);
    page = BufferGetPage(buffer);
    page[offset] ^= 0xFF;
    MarkBufferDirty(buffer);
    UnlockReleaseBuffer(buffer);
    index_close(index_rel, NoLock);
    CommandCounterIncrement();
    PG_RETURN_VOID();
}

/*
 * Zero an entire index page through the buffer manager, producing the
 * uninitialized (PageIsNew) page state a fresh relfilenode can expose, so
 * the metapage reader's uninitialized-page rejection can be exercised.
 */
Datum
pc_test_zero_index_page(PG_FUNCTION_ARGS)
{
    Relation index_rel;
    Buffer buffer;
    Page page;
    BlockNumber blkno;

    if (!superuser())
        elog(ERROR, "zero-page fixture requires superuser");
    index_rel = index_open(PG_GETARG_OID(0), AccessExclusiveLock);
    if (index_rel->rd_rel->relkind != RELKIND_INDEX)
        elog(ERROR, "zero-page fixture requires an index");
    blkno = PG_GETARG_INT32(1);
    if (blkno >= RelationGetNumberOfBlocks(index_rel))
        elog(ERROR, "zero-page fixture requires an existing index block");
    buffer = ReadBuffer(index_rel, blkno);
    LockBuffer(buffer, BUFFER_LOCK_EXCLUSIVE);
    page = BufferGetPage(buffer);
    MemSet(page, 0, BLCKSZ);
    MarkBufferDirty(buffer);
    UnlockReleaseBuffer(buffer);
    index_close(index_rel, NoLock);
    CommandCounterIncrement();
    PG_RETURN_VOID();
}

/*
 * Flip one byte of an index page through a direct smgr write, so the
 * on-disk checksum stays stale: unlike pc_test_corrupt_index_byte this
 * bypasses the buffer manager and is detectable by checksum verification
 * on clusters with data checksums enabled.
 */
Datum
pc_test_corrupt_index_page(PG_FUNCTION_ARGS)
{
    Relation index_rel;
    SMgrRelation smgr;
    BlockNumber blkno;
    int offset;
    Page page;

    if (!superuser())
        elog(ERROR, "direct index corruption fixture requires superuser");
    index_rel = index_open(PG_GETARG_OID(0), AccessExclusiveLock);
    if (index_rel->rd_rel->relkind != RELKIND_INDEX)
        elog(ERROR, "direct index corruption fixture requires an index");
    blkno = PG_GETARG_INT32(1);
    offset = PG_GETARG_INT32(2);
    if (blkno >= RelationGetNumberOfBlocks(index_rel) || offset < 0 || offset >= BLCKSZ)
        elog(ERROR, "direct index corruption fixture requires an existing byte");
    smgr = RelationGetSmgr(index_rel);
    page = palloc(BLCKSZ);
    smgrread(smgr, MAIN_FORKNUM, blkno, page);
    page[offset] ^= 0xFF;
    smgrwrite(smgr, MAIN_FORKNUM, blkno, page, false);
    smgrimmedsync(smgr, MAIN_FORKNUM);
    pfree(page);
    index_close(index_rel, NoLock);
    CommandCounterIncrement();
    PG_RETURN_VOID();
}

Datum
pc_test_legacy_xmin(PG_FUNCTION_ARGS)
{
    Relation rel;
    BlockNumber blocks;
    Buffer buffer;
    Page page;
    ItemId item;
    HeapTupleHeader header;

    if (!superuser())
        elog(ERROR, "legacy fixture requires superuser");
    rel = table_open(PG_GETARG_OID(0), AccessExclusiveLock);
    blocks = RelationGetNumberOfBlocks(rel);
    if (blocks == 0)
        elog(ERROR, "legacy fixture requires a nonempty heap");
    buffer = ReadBuffer(rel, blocks - 1);
    LockBuffer(buffer, BUFFER_LOCK_EXCLUSIVE);
    page = BufferGetPage(buffer);
    if (PageGetMaxOffsetNumber(page) < FirstOffsetNumber)
        elog(ERROR, "legacy fixture requires a tuple on the last block");
    item = PageGetItemId(page, FirstOffsetNumber);
    if (!ItemIdIsNormal(item))
        elog(ERROR, "legacy fixture requires a normal tuple");
    header = (HeapTupleHeader) PageGetItem(page, item);
    if (!HeapTupleHeaderXminFrozen(header) ||
        !(header->t_infomask & HEAP_XMAX_INVALID))
        elog(ERROR, "legacy fixture requires VACUUM FREEZE first");

    /* Pre-9.4 representation: raw xmin=2, without modern frozen hint bits.
     * Preserve VM intentionally: PostgreSQL considers this representation frozen. */
    START_CRIT_SECTION();
    HeapTupleHeaderSetXmin(header, FrozenTransactionId);
    header->t_infomask &= ~HEAP_XMIN_FROZEN;
    header->t_infomask |= HEAP_XMIN_COMMITTED;
    MarkBufferDirty(buffer);
    log_newpage_buffer(buffer, true);
    END_CRIT_SECTION();

    UnlockReleaseBuffer(buffer);
    table_close(rel, NoLock);
    PG_RETURN_VOID();
}
