/*
 * GIN access-method helpers for pg_pagecopy, kept apart from the generic
 * page shim (src/page_shim.c) so AM-specific code stays isolated.
 *
 * Every constant and layout rule comes from the installed server headers
 * (access/ginblock.h): GIN pages carry no magic number or page id word,
 * the opaque area is identified by its size and the flags word, and the
 * metapage format is governed by GinMetaPageData/ginVersion.
 */

#include "postgres.h"

#include "access/gin.h"
#include "access/ginblock.h"
#include "storage/bufmgr.h"
#include "storage/bufpage.h"
#include "utils/rel.h"

typedef struct PcGinMetadata
{
    uint32      version;
} PcGinMetadata;

static bool pc_gin_metapage_ok(Page page, BlockNumber nblocks,
                               GinMetaPageData *metap_out, const char **detail);
static void pc_gin_check_pending_list(Relation rel, BlockNumber nblocks,
                                      GinMetaPageData *metap);
void pc_gin_metadata(Relation rel, PcGinMetadata *metadata);
bool pc_verify_gin_metapage(Page page, uint32 version, uint32 nblocks);

/*
 * Validate the metapage (block 0) against its declared geometry, with the
 * incoming main-fork block count as the only size bound. The checks are
 * fail-closed: page layout, GIN_META flag, format version and the pending
 * list bounds must all be internally consistent. Planner statistics
 * (nEntryPages/nDataPages/nEntries) are validated for sanity only, and the
 * pending head/tail pointers must be consistent with the pending page
 * count; the pending list itself is walked by pc_gin_metadata on the
 * source, never trusted from the metapage alone.
 */
static bool
pc_gin_metapage_ok(Page page, BlockNumber nblocks,
                   GinMetaPageData *metap_out, const char **detail)
{
    PageHeader  phdr = (PageHeader) page;
    GinPageOpaque opaque;
    GinMetaPageData *metap;

    if (PageIsNew(page))
    {
        *detail = "gin metapage is uninitialized";
        return false;
    }
    /* GIN pages carry no page id: the opaque area is identified by size.
     * Bind pd_special absolutely first: the size check alone derives from
     * the header-advertised page size, which can pass while pointing the
     * special area outside this buffer on a malformed header. */
    if (phdr->pd_special != BLCKSZ - MAXALIGN(sizeof(GinPageOpaqueData)))
    {
        *detail = "gin metapage has an unexpected special area";
        return false;
    }
    if (PageGetSpecialSize(page) != MAXALIGN(sizeof(GinPageOpaqueData)))
    {
        *detail = "gin metapage has an unexpected special area size";
        return false;
    }
    opaque = (GinPageOpaque) PageGetSpecialPointer(page);
    if (opaque->flags != GIN_META)
    {
        *detail = "gin metapage is not a metapage";
        return false;
    }
    /* The metadata must survive standard-page WAL compression, whose hole
     * is [pd_lower, pd_upper); upstream sets pd_lower past the complete
     * GinMetaPageData for exactly this reason (see GinInitMetabuffer). */
    if (phdr->pd_lower < SizeOfPageHeaderData + sizeof(GinMetaPageData) ||
        phdr->pd_upper != phdr->pd_special ||
        phdr->pd_special != BLCKSZ - MAXALIGN(sizeof(GinPageOpaqueData)))
    {
        *detail = "gin metapage does not cover its metadata";
        return false;
    }

    metap = GinPageGetMeta(page);
    if (metap->ginVersion != GIN_CURRENT_VERSION)
    {
        *detail = "gin metapage version mismatch";
        return false;
    }

    /* nTotalPages is refreshed by VACUUM and at build end, so it can lag
     * behind a fastupdate-grown file but never exceed it; the per-kind
     * page counts must fit inside the total. */
    if (metap->nTotalPages < 1 || metap->nTotalPages > nblocks ||
        metap->nEntryPages > metap->nTotalPages ||
        metap->nDataPages > metap->nTotalPages)
    {
        *detail = "gin metapage statistics exceed the index size";
        return false;
    }

    if (metap->nPendingPages == 0)
    {
        /* An empty pending list is initialized to InvalidBlockNumber with
         * zeroed statistics (see GinInitMetabuffer / ginInsertCleanup). */
        if (metap->head != InvalidBlockNumber || metap->tail != InvalidBlockNumber)
        {
            *detail = "gin pending list pointers are set on an empty pending list";
            return false;
        }
        if (metap->nPendingHeapTuples != 0 || metap->tailFreeSize != 0)
        {
            *detail = "gin pending list statistics are set on an empty pending list";
            return false;
        }
    }
    else
    {
        if (metap->nPendingPages > nblocks || metap->nPendingHeapTuples < 1)
        {
            *detail = "gin pending list extent is inconsistent";
            return false;
        }
        if (metap->head == InvalidBlockNumber || metap->head >= nblocks)
        {
            *detail = "gin pending list head is out of range";
            return false;
        }
        if (metap->tail == InvalidBlockNumber || metap->tail >= nblocks)
        {
            *detail = "gin pending list tail is out of range";
            return false;
        }
        /* Blocks 0 and 1 are reserved for the metapage and the entry-tree
         * root; a pending list head or tail pointing there describes an
         * impossible state. */
        if (metap->head <= GIN_ROOT_BLKNO || metap->tail <= GIN_ROOT_BLKNO)
        {
            *detail = "gin pending list pointers overlap reserved pages";
            return false;
        }
        if (metap->tailFreeSize > GinListPageSize)
        {
            *detail = "gin pending list tail free space is out of range";
            return false;
        }
    }

    *metap_out = *metap;
    return true;
}

/*
 * Walk the pending list from head to tail: a nonempty pending list is
 * fastupdate state whose pages transfer with the file, so the whole chain
 * must be present, consist of GIN_LIST pages, end exactly at the metapage
 * tail and match the metapage page count. Anything else fails closed.
 */
static void
pc_gin_check_pending_list(Relation rel, BlockNumber nblocks,
                          GinMetaPageData *metap)
{
    BlockNumber blkno = metap->head;
    uint32      visited = 0;

    while (blkno != InvalidBlockNumber)
    {
        Buffer      buffer;
        Page        page;
        GinPageOpaque opaque;

        if (visited >= nblocks)
            elog(ERROR, "pg_pagecopy: gin pending list does not terminate");
        buffer = ReadBuffer(rel, blkno);
        LockBuffer(buffer, BUFFER_LOCK_SHARE);
        page = BufferGetPage(buffer);
        if (PageIsNew(page))
            elog(ERROR, "pg_pagecopy: gin pending list page %u is uninitialized", blkno);
        if (((PageHeader) page)->pd_special != BLCKSZ - MAXALIGN(sizeof(GinPageOpaqueData)) ||
            PageGetSpecialSize(page) != MAXALIGN(sizeof(GinPageOpaqueData)))
            elog(ERROR, "pg_pagecopy: gin pending list page %u has an unexpected special area", blkno);
        opaque = (GinPageOpaque) PageGetSpecialPointer(page);
        if (!GinPageIsList(page) || GinPageIsDeleted(page))
            elog(ERROR, "pg_pagecopy: gin pending list page %u is not a pending page", blkno);
        blkno = opaque->rightlink;
        if (blkno == InvalidBlockNumber && metap->tail != BufferGetBlockNumber(buffer))
            elog(ERROR, "pg_pagecopy: gin pending list does not end at its tail");
        if (blkno != InvalidBlockNumber && blkno >= nblocks)
            elog(ERROR, "pg_pagecopy: gin pending list page address is out of range");
        UnlockReleaseBuffer(buffer);
        visited++;
        if (blkno == InvalidBlockNumber)
            break;
    }
    if (visited != metap->nPendingPages)
        elog(ERROR, "pg_pagecopy: gin pending list length is inconsistent");
}

/*
 * Read the source index format identity from its metapage under a buffer
 * share lock, walking a nonempty pending list so the transfer copies a
 * provably complete build state.
 */
void
pc_gin_metadata(Relation rel, PcGinMetadata *metadata)
{
    Buffer      buffer;
    Page        page;
    GinMetaPageData metap;
    const char *detail = NULL;
    BlockNumber nblocks;

    nblocks = RelationGetNumberOfBlocks(rel);
    buffer = ReadBuffer(rel, GIN_METAPAGE_BLKNO);
    LockBuffer(buffer, BUFFER_LOCK_SHARE);
    page = BufferGetPage(buffer);
    if (!pc_gin_metapage_ok(page, nblocks, &metap, &detail))
        elog(ERROR, "pg_pagecopy: %s", detail);
    UnlockReleaseBuffer(buffer);

    if (metap.nPendingPages != 0)
        pc_gin_check_pending_list(rel, nblocks, &metap);
    metadata->version = metap.ginVersion;
}

/*
 * Verify the metapage (block 0) of an incoming gin index against the source
 * manifest: the complete format and geometry validation of
 * pc_gin_metapage_ok plus an exact match of the recorded format version.
 */
bool
pc_verify_gin_metapage(Page page, uint32 version, uint32 nblocks)
{
    GinMetaPageData metap;
    const char *detail = NULL;

    return pc_gin_metapage_ok(page, nblocks, &metap, &detail) &&
        metap.ginVersion == version;
}
