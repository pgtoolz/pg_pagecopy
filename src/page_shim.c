#include "postgres.h"

#include "access/detoast.h"
#include "access/heapam.h"
#include "access/heaptoast.h"
#include "access/htup_details.h"
#if PG_VERSION_NUM >= 140000
#include "access/toast_compression.h"
#endif
#include "access/xact.h"
#include "access/xlog.h"
#include "access/xloginsert.h"
#include "access/xlogrecord.h"
#include "catalog/catalog.h"
#include "catalog/indexing.h"
#include "catalog/pg_am_d.h"
#include "catalog/pg_index.h"
#include "miscadmin.h"
#include "catalog/namespace.h"
#include "libpq/libpq-be-fe-helpers.h"
#include "storage/bufmgr.h"
#include "storage/bufpage.h"
#include "storage/checksum.h"
#include "storage/smgr.h"
#include "utils/builtins.h"
#include "utils/acl.h"
#include "utils/fmgrprotos.h"
#include "utils/rel.h"
#include "utils/relcache.h"
#include "utils/ruleutils.h"
#include "utils/regproc.h"
#include "utils/syscache.h"
#include "utils/timestamp.h"

typedef struct PcAttribute
{
    char        name[NAMEDATALEN];
    int32       typmod;
    int16       len;
    uint8       align;
    bool        by_val;
    uint8       storage;
    bool        has_missing;
    uint8       generated;
    bool        not_null;
    bool        dropped;
} PcAttribute;

bool pc_verify_page(Page page, BlockNumber blkno, bool checksums);
bool pc_heap_page_is_frozen(Page page);

Oid
pc_resolve_relation(const char *name)
{
    List       *names;

#if PG_VERSION_NUM >= 160000
    names = stringToQualifiedNameList(name, NULL);
#else
    names = stringToQualifiedNameList(name);
#endif
    return RangeVarGetRelid(makeRangeVarFromNameList(names), NoLock, true);
}

bool
pc_target_owner(Oid relation_oid)
{
#if PG_VERSION_NUM >= 160000
    return object_ownercheck(RelationRelationId, relation_oid, GetUserId());
#else
    return pg_class_ownercheck(relation_oid, GetUserId());
#endif
}

void
pc_reset_storage(Relation rel)
{
#if PG_VERSION_NUM >= 160000
    RelationSetNewRelfilenumber(rel, RELPERSISTENCE_PERMANENT);
#else
    RelationSetNewRelfilenode(rel, RELPERSISTENCE_PERMANENT);
#endif
}

void
pc_flush_relation(Relation rel)
{
    FlushRelationBuffers(rel);
}

/* Streaming reads require the locked relation tree to be flushed first. */
void
pc_read_page(Relation rel, ForkNumber fork, BlockNumber blkno, char *dst)
{
    SMgrRelation smgr = RelationGetSmgr(rel);

    if (!smgrexists(smgr, fork))
        elog(ERROR, "pg_pagecopy: relation fork %d does not exist", fork);
    smgrread(smgr, fork, blkno, dst);
    if (fork == MAIN_FORKNUM &&
        !pc_verify_page(dst, blkno, DataChecksumsEnabled()))
        ereport(ERROR,
                (errcode(ERRCODE_DATA_CORRUPTED),
                 errmsg("pg_pagecopy: source page verification failed (checksum/layout) for block %u", blkno)));
}

bool
pc_heap_page_is_frozen(Page page)
{
    OffsetNumber offnum;
    OffsetNumber maxoff = PageGetMaxOffsetNumber(page);

    for (offnum = FirstOffsetNumber; offnum <= maxoff; offnum++)
    {
        ItemId itemid;
        HeapTupleHeader header;

        CHECK_FOR_INTERRUPTS();
        itemid = PageGetItemId(page, offnum);
        if (!ItemIdIsNormal(itemid))
            continue;
        header = (HeapTupleHeader) PageGetItem(page, itemid);
        if (!HeapTupleHeaderXminFrozen(header) ||
            !(header->t_infomask & HEAP_XMAX_INVALID))
            return false;
    }
    return true;
}

void
pc_assert_heap_page_frozen(Relation rel, Page page, BlockNumber blkno)
{
    if (!pc_heap_page_is_frozen(page))
        ereport(ERROR,
                (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                 errmsg("pg_pagecopy: direct source block %u of relation %u is not frozen",
                        blkno, RelationGetRelid(rel))));
}

static bool
pc_page_is_all_zero(Page page)
{
    int i;

    for (i = 0; i < BLCKSZ; i++)
        if (((const char *) page)[i] != 0)
            return false;
    return true;
}

static void
pc_finish_page(Page page, BlockNumber blkno, bool checksums)
{
    if (PageIsNew(page) && pc_page_is_all_zero(page))
    {
        /* A legitimately unallocated page (hash bucket allocation reserves
         * whole phases of all-zero blocks between used pages) must stay
         * byte-exact: stamping an LSN or checksum would make the imported
         * page fail verification, and crash recovery must keep restoring it
         * as zero. A partially nonzero uninitialized page still passes
         * through untouched here and pc_verify_page rejects it. */
        return;
    }
    PageSetLSN(page, (XLogRecPtr) 1);
    ((PageHeader) page)->pd_prune_xid = 0;
    if (checksums)
#if PG_VERSION_NUM >= 190000
        PageSetChecksum(page, blkno);
#else
        PageSetChecksumInplace(page, blkno);
#endif
    else
        ((PageHeader) page)->pd_checksum = 0;
}

void
pc_prepare_page(Page page, BlockNumber blkno, bool checksums)
{
    pc_finish_page(page, blkno, checksums);
}

bool
pc_verify_page(Page page, BlockNumber blkno, bool checksums)
{
    PageHeader phdr = (PageHeader) page;
    uint16 stored;
    bool ok;

    if (PageIsNew(page))
    {
        /* A new page is legitimate only when entirely zeroed; the checksum
         * setters skip such pages, so they must never pass by default. */
        return pc_page_is_all_zero(page);
    }

    if (PageGetPageLayoutVersion(page) != PG_PAGE_LAYOUT_VERSION ||
        PageGetPageSize(page) != BLCKSZ ||
        phdr->pd_lower < SizeOfPageHeaderData ||
        phdr->pd_lower > phdr->pd_upper ||
        phdr->pd_upper > phdr->pd_special ||
        phdr->pd_special > BLCKSZ ||
        phdr->pd_special != MAXALIGN(phdr->pd_special))
        return false;

    if (!checksums)
        return true;

    stored = phdr->pd_checksum;
#if PG_VERSION_NUM >= 190000
    PageSetChecksum(page, blkno);
#else
    PageSetChecksumInplace(page, blkno);
#endif
    ok = phdr->pd_checksum == stored;
    phdr->pd_checksum = stored;
    return ok;
}

int
pc_max_toast_chunk_size(void)
{
    return TOAST_MAX_CHUNK_SIZE;
}

int
pc_max_identifier_length(void)
{
    return NAMEDATALEN - 1;
}

int
pc_checksum_algorithm_version(void)
{
    return PG_DATA_CHECKSUM_VERSION;
}

bool
pc_lz4_supported(void)
{
#ifdef USE_LZ4
    return true;
#else
    return false;
#endif
}

void
pc_prepare_heap_page(Page page, Relation rel, BlockNumber blkno,
                            Oid source_toast_oid, Oid target_toast_oid,
                            bool patch_toast, bool target_lz4_supported,
                            bool checksums, bool keep_xids)
{
    TupleDesc desc = RelationGetDescr(rel);
    Datum *values = NULL;
    bool *isnull = NULL;
    OffsetNumber offnum;
    OffsetNumber maxoff = PageGetMaxOffsetNumber(page);

    ((PageHeader) page)->pd_prune_xid = 0;

    for (offnum = FirstOffsetNumber; offnum <= maxoff; offnum++)
    {
        ItemId itemid;
        HeapTupleHeader header;
        HeapTupleData tuple;
        int attno;
        int tuple_natts;

        CHECK_FOR_INTERRUPTS();
        itemid = PageGetItemId(page, offnum);
        if (!ItemIdIsNormal(itemid))
            continue;

        header = (HeapTupleHeader) PageGetItem(page, itemid);
        if (!keep_xids &&
            (!HeapTupleHeaderXminFrozen(header) ||
             !(header->t_infomask & HEAP_XMAX_INVALID)))
            ereport(ERROR,
                    (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                     errmsg("pg_pagecopy: block %u contains a tuple that is not frozen; rerun VACUUM (FREEZE)", blkno)));

        tuple_natts = HeapTupleHeaderGetNatts(header);
        if (tuple_natts > desc->natts)
            ereport(ERROR,
                    (errcode(ERRCODE_DATA_CORRUPTED),
                     errmsg("pg_pagecopy: tuple attribute count exceeds target descriptor")));
        for (attno = tuple_natts; attno < desc->natts; attno++)
            if (TupleDescAttr(desc, attno)->atthasmissing)
                ereport(ERROR,
                        (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                         errmsg("pg_pagecopy: fast defaults/missing values are not supported")));

        if (!keep_xids)
        {
            HeapTupleHeaderSetXmin(header, FrozenTransactionId);
            HeapTupleHeaderSetXmax(header, InvalidTransactionId);
        }

        if (target_lz4_supported &&
            (!patch_toast || !(header->t_infomask & HEAP_HASEXTERNAL)))
            continue;

        if (values == NULL)
        {
            values = palloc(sizeof(Datum) * desc->natts);
            isnull = palloc(sizeof(bool) * desc->natts);
        }

        memset(&tuple, 0, sizeof(tuple));
        tuple.t_len = ItemIdGetLength(itemid);
        tuple.t_data = header;
        ItemPointerSetInvalid(&tuple.t_self);
        heap_deform_tuple(&tuple, desc, values, isnull);

        for (attno = 0; attno < desc->natts; attno++)
        {
            Form_pg_attribute attr = TupleDescAttr(desc, attno);
            struct varlena *value;

            if (isnull[attno] || attr->attisdropped || attr->attlen != -1)
                continue;

            value = (struct varlena *) DatumGetPointer(values[attno]);
#if PG_VERSION_NUM >= 140000
            if (!target_lz4_supported && VARATT_IS_4B_C(value) &&
                VARDATA_COMPRESSED_GET_COMPRESS_METHOD(value) == TOAST_LZ4_COMPRESSION_ID)
                ereport(ERROR,
                        (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                         errmsg("pg_pagecopy: target does not support lz4-compressed inline values")));
#endif

            if (VARATT_IS_EXTERNAL_ONDISK(value))
            {
                varatt_external external;

                VARATT_EXTERNAL_GET_POINTER(external, value);
#if PG_VERSION_NUM >= 140000
                if (!target_lz4_supported && VARATT_EXTERNAL_IS_COMPRESSED(external) &&
                    VARATT_EXTERNAL_GET_COMPRESS_METHOD(external) == TOAST_LZ4_COMPRESSION_ID)
                    ereport(ERROR,
                            (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                             errmsg("pg_pagecopy: target does not support lz4-compressed TOAST values")));
#endif
                if (!patch_toast)
                    continue;
                if (target_toast_oid == InvalidOid)
                    ereport(ERROR,
                            (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                             errmsg("pg_pagecopy: target table has no TOAST relation")));
                if (external.va_toastrelid != source_toast_oid)
                    ereport(ERROR,
                            (errcode(ERRCODE_DATA_CORRUPTED),
                             errmsg("pg_pagecopy: unexpected TOAST relation OID %u in block %u",
                                    external.va_toastrelid, blkno)));
                external.va_toastrelid = target_toast_oid;
                memcpy(VARDATA_EXTERNAL(value), &external, sizeof(external));
            }
        }
    }

    if (values != NULL)
    {
        pfree(values);
        pfree(isnull);
    }
    pc_finish_page(page, blkno, checksums);
}

Oid
pc_toast_index_oid(Relation toast_rel)
{
    List *indexes = RelationGetIndexList(toast_rel);
    Oid result = list_length(indexes) == 1 ? linitial_oid(indexes) : InvalidOid;

    list_free(indexes);
    return result;
}

int
pc_index_oids(Relation rel, Oid **oids)
{
    List *index_list = RelationGetIndexList(rel);
    int count = list_length(index_list);
    Oid *result = palloc(sizeof(Oid) * (count > 0 ? count : 1));
    ListCell *cell;
    int i = 0;

    foreach(cell, index_list)
        result[i++] = lfirst_oid(cell);
    list_free(index_list);
    *oids = result;
    return count;
}

const char *
pc_index_definition(Oid index_oid)
{
    /* The SQL deparser deliberately omits the source-local tablespace. */
    char *definition = text_to_cstring(DatumGetTextPP(
        DirectFunctionCall1(pg_get_indexdef, ObjectIdGetDatum(index_oid))));
    char *p = definition;
    bool in_identifier = false;
    bool in_literal = false;

    while (*p != '\0')
    {
        if (*p == '"' && !in_literal)
        {
            if (in_identifier && p[1] == '"')
                p++;
            else
                in_identifier = !in_identifier;
        }
        else if (*p == '\'' && !in_identifier)
        {
            if (in_literal && p[1] == '\'')
                p++;
            else
                in_literal = !in_literal;
        }
        else if (!in_identifier && !in_literal && strncmp(p, " USING ", 7) == 0)
            return p + 7;
        p++;
    }
    return definition;
}

void
pc_set_index_validity(Oid index_oid, bool valid)
{
    Relation    pg_index;
    HeapTuple   tuple;
    Form_pg_index form;

    pg_index = relation_open(IndexRelationId, RowExclusiveLock);
    tuple = SearchSysCacheCopy1(INDEXRELID, ObjectIdGetDatum(index_oid));
    if (!HeapTupleIsValid(tuple))
        elog(ERROR, "pg_pagecopy: index catalog row %u is missing", index_oid);
    form = (Form_pg_index) GETSTRUCT(tuple);
    form->indisvalid = valid;
    form->indisready = valid;
    if (!valid)
        form->indisclustered = false;
    CatalogTupleUpdate(pg_index, &tuple->t_self, tuple);
    heap_freetuple(tuple);
    relation_close(pg_index, RowExclusiveLock);
    CommandCounterIncrement();
}

void
pc_attributes(Relation rel, PcAttribute *attrs)
{
    TupleDesc desc = RelationGetDescr(rel);
    int i;

    for (i = 0; i < desc->natts; i++)
    {
        Form_pg_attribute src = TupleDescAttr(desc, i);
        PcAttribute *dst = &attrs[i];

        memset(dst, 0, sizeof(*dst));
        strlcpy(dst->name, NameStr(src->attname), NAMEDATALEN);
        dst->typmod = src->atttypmod;
        dst->len = src->attlen;
        dst->align = (uint8) src->attalign;
        dst->by_val = src->attbyval;
        dst->storage = (uint8) src->attstorage;
        dst->has_missing = src->atthasmissing;
        dst->generated = (uint8) src->attgenerated;
        dst->not_null = src->attnotnull;
        dst->dropped = src->attisdropped;
    }
}

int
pc_attribute_count(Relation rel)
{
    return RelationGetDescr(rel)->natts;
}

/*
 * Size of an optional fork, 0 when its file does not exist: unlike
 * smgrnblocks this never ereports, which manifest building relies on.
 */
BlockNumber
pc_blocks_safe(Relation rel, ForkNumber fork)
{
    SMgrRelation smgr = RelationGetSmgr(rel);

    if (!smgrexists(smgr, fork))
        return 0;
    return smgrnblocks(smgr, fork);
}

void
pc_write_page(Relation rel, ForkNumber fork, BlockNumber blkno, const char *page)
{
    SMgrRelation smgr = RelationGetSmgr(rel);
    BlockNumber blocks;

    if (!smgrexists(smgr, fork))
        smgrcreate(smgr, fork, false);

    blocks = smgrnblocks(smgr, fork);
    if (blkno == blocks)
        smgrextend(smgr, fork, blkno, (char *) page, false);
    else if (blkno < blocks)
        smgrwrite(smgr, fork, blkno, (char *) page, false);
    else
        ereport(ERROR,
                (errcode(ERRCODE_DATA_CORRUPTED),
                 errmsg("pg_pagecopy: non-contiguous block %u, relation has %u blocks", blkno, blocks)));
}

/* RelFileLocator replaced RelFileNode in PostgreSQL 16. */
#if PG_VERSION_NUM >= 160000
#define PC_SMGR_RELFILE(smgr) (&(smgr)->smgr_rlocator.locator)
#else
#define PC_SMGR_RELFILE(smgr) (&(smgr)->smgr_rnode.node)
#endif

static void
pc_log_pages(SMgrRelation smgr, ForkNumber fork, int npages,
             BlockNumber *blknos, Page *pages, bool page_std)
{
#if PG_VERSION_NUM >= 140000
    log_newpages(PC_SMGR_RELFILE(smgr), fork, npages,
                 blknos, pages, page_std);
#else
    int         i;

    for (i = 0; i < npages; i++)
        log_newpage(PC_SMGR_RELFILE(smgr), fork, blknos[i], pages[i], page_std);
#endif
}

/*
 * Emit WAL full-page images for a relation whose pages were written directly
 * through SMGR: reread them without the buffer manager and log them in
 * batches of XLR_MAX_BLOCK_ID, the same batching core's bulk writer uses.
 * No explicit XLogFlush: the caller commits right after, and the commit
 * record's own WAL flush makes these earlier images durable.
 */
void
pc_log_relation(Relation rel, ForkNumber fork)
{
    SMgrRelation smgr = RelationGetSmgr(rel);
    BlockNumber nblocks;
    Page       *pages;
    BlockNumber *blknos;
    BlockNumber blkno;
    int         npending = 0;
    int         i;
    /*
     * BRIN revmap pages keep their entry array between pd_lower and
     * pd_upper, which standard-page full images omit as a hole; replayed
     * revmaps would silently read as unsummarized ranges, so every BRIN
     * main-fork page is logged whole. GIN is logged whole for the same
     * fail-closed reason: a pre-9.4 posting page binary-upgraded into the
     * file may carry a stale pd_lower, which core itself refuses to log
     * as a standard page (ginvacuum.c).
     */
    bool        page_std = fork == MAIN_FORKNUM &&
        rel->rd_rel->relam != BRIN_AM_OID &&
        rel->rd_rel->relam != GIN_AM_OID;

    if (!smgrexists(smgr, fork))
        return;
    nblocks = smgrnblocks(smgr, fork);
    if (nblocks == 0)
        return;

    pages = palloc(sizeof(Page) * XLR_MAX_BLOCK_ID);
    blknos = palloc(sizeof(BlockNumber) * XLR_MAX_BLOCK_ID);
    for (i = 0; i < XLR_MAX_BLOCK_ID; i++)
        pages[i] = palloc(BLCKSZ);

    for (blkno = 0; blkno < nblocks; blkno++)
    {
        CHECK_FOR_INTERRUPTS();
        smgrread(smgr, fork, blkno, pages[npending]);
        blknos[npending] = blkno;
        if (++npending == XLR_MAX_BLOCK_ID)
        {
            pc_log_pages(smgr, fork, npending, blknos, pages, page_std);
            npending = 0;
        }
    }
    if (npending > 0)
        pc_log_pages(smgr, fork, npending, blknos, pages, page_std);

    for (i = 0; i < XLR_MAX_BLOCK_ID; i++)
        pfree(pages[i]);
    pfree(pages);
    pfree(blknos);

    smgrimmedsync(smgr, fork);
}

void
pc_sync_relation(Relation rel, ForkNumber fork)
{
    SMgrRelation smgr = RelationGetSmgr(rel);

    if (smgrexists(smgr, fork))
        smgrimmedsync(smgr, fork);
}

/* Backend-safe libpq waits: keep target cancellation and external FD accounting. */
static int
pc_source_wait(PGconn *conn, int events, long timeout_ms)
{
    int         rc;

    CHECK_FOR_INTERRUPTS();
    rc = WaitLatchOrSocket(MyLatch,
                           WL_EXIT_ON_PM_DEATH | WL_LATCH_SET | events | (timeout_ms >= 0 ? WL_TIMEOUT : 0),
                           PQsocket(conn), timeout_ms, PG_WAIT_EXTENSION);
    if (rc & WL_LATCH_SET)
    {
        ResetLatch(MyLatch);
        CHECK_FOR_INTERRUPTS();
    }
    return rc;
}

PGconn *
pc_source_connect(const char *conninfo)
{
    PGconn *volatile conn = NULL;
    bool        volatile prepared = false;

    PG_TRY();
    {
        PQconninfoOption *options;
        PQconninfoOption *option;
        PostgresPollingStatusType polling;
        TimestampTz started = GetCurrentTimestamp();
        int         timeout_seconds = 0;

        libpqsrv_connect_prepare();
        prepared = true;
        conn = PQconnectStart(conninfo);
        if (conn == NULL)
            ereport(ERROR, (errmsg("source connection allocation failed")));
        if (PQstatus(conn) == CONNECTION_BAD)
            ereport(ERROR, (errmsg("source connection failed: %s", PQerrorMessage(conn))));

        options = PQconninfo(conn);
        if (options != NULL)
        {
            for (option = options; option->keyword != NULL; option++)
            {
                if (strcmp(option->keyword, "connect_timeout") == 0 && option->val != NULL)
                    timeout_seconds = atoi(option->val);
            }
            PQconninfoFree(options);
        }

        while ((polling = PQconnectPoll(conn)) != PGRES_POLLING_OK)
        {
            int         events;
            long        timeout_ms = -1;

            if (polling == PGRES_POLLING_FAILED)
                ereport(ERROR, (errmsg("source connection failed: %s", PQerrorMessage(conn))));
            if (polling != PGRES_POLLING_READING && polling != PGRES_POLLING_WRITING)
                ereport(ERROR, (errmsg("source connection failed: unexpected libpq polling state")));

            if (timeout_seconds > 0)
            {
                long        secs;
                int         microsecs;
                int64       remaining;

                TimestampDifference(started, GetCurrentTimestamp(), &secs, &microsecs);
                remaining = (int64) timeout_seconds * 1000 - (int64) secs * 1000 - microsecs / 1000;
                if (remaining <= 0)
                    ereport(ERROR, (errmsg("source connection failed: connect_timeout expired")));
                timeout_ms = remaining > INT_MAX ? INT_MAX : (long) remaining;
            }

            events = polling == PGRES_POLLING_READING ? WL_SOCKET_READABLE : WL_SOCKET_WRITEABLE;
            if (pc_source_wait(conn, events, timeout_ms) & WL_TIMEOUT)
                ereport(ERROR, (errmsg("source connection failed: connect_timeout expired")));
        }
    }
    PG_CATCH();
    {
        if (conn != NULL)
            libpqsrv_disconnect(conn);
        else if (prepared)
            ReleaseExternalFD();
        PG_RE_THROW();
    }
    PG_END_TRY();
    return conn;
}

void
pc_source_disconnect(PGconn *conn)
{
    if (PQtransactionStatus(conn) == PQTRANS_ACTIVE)
    {
        PGcancel   *cancel = PQgetCancel(conn);
        char        error[256];

        if (cancel != NULL)
        {
            /* A closed socket alone does not interrupt a running source query. */
            (void) PQcancel(cancel, error, sizeof(error));
            PQfreeCancel(cancel);
        }
    }
    libpqsrv_disconnect(conn);
}

static int
pc_source_flush(PGconn *conn)
{
    int         rc;

    while ((rc = PQflush(conn)) == 1)
    {
        int         events = pc_source_wait(conn, WL_SOCKET_READABLE | WL_SOCKET_WRITEABLE, -1);

        if ((events & WL_SOCKET_READABLE) && PQconsumeInput(conn) == 0)
            return -1;
    }
    return rc;
}

PGresult *
pc_source_exec(PGconn *conn, const char *query)
{
    if (!PQsendQuery(conn, query) || pc_source_flush(conn) < 0)
        return NULL;
    return libpqsrv_get_result_last(conn, PG_WAIT_EXTENSION);
}

PGresult *
pc_source_exec_params(PGconn *conn, const char *query, int n_params,
                       const char *const *values)
{
    if (!PQsendQueryParams(conn, query, n_params, NULL, values, NULL, NULL, 0) ||
        pc_source_flush(conn) < 0)
        return NULL;
    return libpqsrv_get_result_last(conn, PG_WAIT_EXTENSION);
}

PGresult *
pc_source_get_result(PGconn *conn)
{
    return libpqsrv_get_result(conn, PG_WAIT_EXTENSION);
}

int
pc_source_copy_data(PGconn *conn, char **buffer)
{
    for (;;)
    {
        int         length;
        int         events;

        CHECK_FOR_INTERRUPTS();
        length = PQgetCopyData(conn, buffer, 1);
        if (length != 0)
            return length;

        events = pc_source_wait(conn, WL_SOCKET_READABLE, -1);
        if ((events & WL_SOCKET_READABLE) && PQconsumeInput(conn) == 0)
            return -2;
    }
}
