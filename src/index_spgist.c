/*
 * SP-GiST access-method helpers for pg_pagecopy, kept apart from the generic
 * page shim (src/page_shim.c) so AM-specific code stays isolated.
 *
 * All constants and structures come from the installed server headers
 * (access/spgist.h, access/spgist_private.h), never from local copies.
 */

#include "postgres.h"

#include "access/genam.h"
#include "access/spgist.h"
#include "access/spgist_private.h"
#include "catalog/index.h"
#include "storage/bufmgr.h"
#include "storage/bufpage.h"
#include "utils/rel.h"

typedef struct PcSpgistMetadata
{
    uint32      config_proc;
    uint32      choose_proc;
    uint32      picksplit_proc;
    uint32      inner_consistent_proc;
    uint32      leaf_consistent_proc;
} PcSpgistMetadata;

static bool pc_spgist_metapage_ok(Page page, BlockNumber nblocks,
                                  const char **detail);
static bool pc_spgist_tree_page_ok(Page page, bool nulls,
                                   const char **detail);
void pc_spgist_metadata(Relation rel, PcSpgistMetadata *metadata);
bool pc_verify_spgist_metapage(Page page, uint32 nblocks);

/*
 * Validate the metapage against the allocation geometry it claims, with the
 * incoming main-fork block count as the only size bound. Every check is
 * fail-closed: page layout and the derived geometry must be internally
 * consistent. lastUsedPages is mutable shared state (a page cache whose
 * freeSpace hints may be stale by design), so it is validated for sanity,
 * never compared against a freshly built target index.
 */
static bool
pc_spgist_metapage_ok(Page page, BlockNumber nblocks, const char **detail)
{
    PageHeader  phdr = (PageHeader) page;
    SpGistPageOpaque opaque;
    SpGistMetaPageData *metap;
    int         i;

    if (PageIsNew(page))
    {
        *detail = "spgist metapage is uninitialized";
        return false;
    }
    /* Bind pd_special absolutely before any special-area dereference: the
     * size check alone derives from the header-advertised page size and can
     * pass while the special area sits outside this buffer. */
    if (phdr->pd_special != BLCKSZ - MAXALIGN(sizeof(SpGistPageOpaqueData)))    {
        *detail = "spgist metapage has an unexpected special area";
        return false;
    }
    if (PageGetSpecialSize(page) != MAXALIGN(sizeof(SpGistPageOpaqueData)))
    {
        *detail = "spgist metapage has an unexpected special area";
        return false;
    }
    opaque = SpGistPageGetOpaque(page);
    if (opaque->spgist_page_id != SPGIST_PAGE_ID)
    {
        *detail = "spgist metapage has an unexpected page id";
        return false;
    }
    if (opaque->flags != SPGIST_META)
    {
        *detail = "spgist metapage is not a metapage";
        return false;
    }
    /* The metadata must survive standard-page WAL compression, whose hole is
     * [pd_lower, pd_upper); upstream sets pd_lower exactly past the complete
     * SpGistMetaPageData for exactly this reason (SpGistInitMetapage),
     * without an extra MAXALIGN. */
    if (phdr->pd_lower < SizeOfPageHeaderData + sizeof(SpGistMetaPageData) ||
        phdr->pd_upper != phdr->pd_special ||
        phdr->pd_special != BLCKSZ - MAXALIGN(sizeof(SpGistPageOpaqueData)))
    {
        *detail = "spgist metapage does not cover its metadata";
        return false;
    }

    metap = SpGistPageGetMeta(page);
    if (metap->magicNumber != SPGIST_MAGIC_NUMBER)
    {
        *detail = "spgist metapage magic mismatch";
        return false;
    }

    /* The fixed metapage/root/nulls-root pages must all exist; unlike hash
     * the metapage carries no allocation counts, so this is the whole
     * geometry derivable from it. */
    if (nblocks <= SPGIST_LAST_FIXED_BLKNO)
    {
        *detail = "spgist metapage geometry exceeds the index size";
        return false;
    }
    for (i = 0; i < SPGIST_CACHED_PAGES; i++)
    {
        BlockNumber blkno = metap->lastUsedPages.cachedPage[i].blkno;

        /* Upstream never caches the fixed metapage/root pages and asserts
         * !SpGistBlockIsFixed for every cache entry (spgutils.c); accepting
         * one would let a later write allocate over a fixed page. */
        if (blkno != InvalidBlockNumber &&
            (SpGistBlockIsFixed(blkno) || blkno >= nblocks))
        {
            *detail = "spgist metapage cached page address is invalid";
            return false;
        }
    }
    return true;
}

/*
 * Validate one fixed tree page (the normal root or the nulls root): the
 * SP-GiST page id, the special-area size and the page-type flags. A tree
 * page is either a leaf or an inner page (there is no inner flag bit), and
 * the nulls root alone carries SPGIST_NULLS.
 */
static bool
pc_spgist_tree_page_ok(Page page, bool nulls, const char **detail)
{
    SpGistPageOpaque opaque;
    PageHeader phdr = (PageHeader) page;

    if (PageIsNew(page))
    {
        *detail = "spgist tree page is uninitialized";
        return false;
    }
    /* Same absolute special-area binding as the metapage, before any
     * special-area dereference. */
    if (phdr->pd_special != BLCKSZ - MAXALIGN(sizeof(SpGistPageOpaqueData)))
    {
        *detail = "spgist tree page has an unexpected special area";
        return false;
    }
    if (PageGetSpecialSize(page) != MAXALIGN(sizeof(SpGistPageOpaqueData)))
    {
        *detail = "spgist tree page has an unexpected special area";
        return false;
    }
    opaque = SpGistPageGetOpaque(page);
    if (opaque->spgist_page_id != SPGIST_PAGE_ID)
    {
        *detail = "spgist tree page has an unexpected page id";
        return false;
    }
    if ((opaque->flags & SPGIST_META) != 0 ||
        (nulls ? (opaque->flags & SPGIST_NULLS) == 0
               : (opaque->flags & SPGIST_NULLS) != 0))
    {
        *detail = "spgist tree page has an unexpected type";
        return false;
    }
    return true;
}

/*
 * Read the source index format identity from its metapage and fixed tree
 * pages under buffer share locks, then resolve the five required support
 * functions through the index catalog: the metapage stores no opclass
 * identity of its own, so the opclass procedures are the format identity
 * compared across clusters (core function OIDs are pinned by initdb).
 */
void
pc_spgist_metadata(Relation rel, PcSpgistMetadata *metadata)
{
    Buffer      buffer;
    Page        page;
    BlockNumber nblocks;
    const char *detail = NULL;
    RegProcedure config_proc;
    RegProcedure choose_proc;
    RegProcedure picksplit_proc;
    RegProcedure inner_consistent_proc;
    RegProcedure leaf_consistent_proc;

    nblocks = RelationGetNumberOfBlocks(rel);

    buffer = ReadBuffer(rel, SPGIST_METAPAGE_BLKNO);
    LockBuffer(buffer, BUFFER_LOCK_SHARE);
    page = BufferGetPage(buffer);
    if (!pc_spgist_metapage_ok(page, nblocks, &detail))
        elog(ERROR, "pg_pagecopy: %s", detail);
    UnlockReleaseBuffer(buffer);

    buffer = ReadBuffer(rel, SPGIST_ROOT_BLKNO);
    LockBuffer(buffer, BUFFER_LOCK_SHARE);
    page = BufferGetPage(buffer);
    if (!pc_spgist_tree_page_ok(page, false, &detail))
        elog(ERROR, "pg_pagecopy: %s", detail);
    UnlockReleaseBuffer(buffer);

    buffer = ReadBuffer(rel, SPGIST_NULL_BLKNO);
    LockBuffer(buffer, BUFFER_LOCK_SHARE);
    page = BufferGetPage(buffer);
    if (!pc_spgist_tree_page_ok(page, true, &detail))
        elog(ERROR, "pg_pagecopy: %s", detail);
    UnlockReleaseBuffer(buffer);

    config_proc = index_getprocid(rel, 1, SPGIST_CONFIG_PROC);
    choose_proc = index_getprocid(rel, 1, SPGIST_CHOOSE_PROC);
    picksplit_proc = index_getprocid(rel, 1, SPGIST_PICKSPLIT_PROC);
    inner_consistent_proc = index_getprocid(rel, 1, SPGIST_INNER_CONSISTENT_PROC);
    leaf_consistent_proc = index_getprocid(rel, 1, SPGIST_LEAF_CONSISTENT_PROC);
    if (config_proc == InvalidOid || choose_proc == InvalidOid ||
        picksplit_proc == InvalidOid || inner_consistent_proc == InvalidOid ||
        leaf_consistent_proc == InvalidOid)
        elog(ERROR, "pg_pagecopy: spgist support function is missing");
    metadata->config_proc = config_proc;
    metadata->choose_proc = choose_proc;
    metadata->picksplit_proc = picksplit_proc;
    metadata->inner_consistent_proc = inner_consistent_proc;
    metadata->leaf_consistent_proc = leaf_consistent_proc;
}

/*
 * Verify the metapage (block 0) of an incoming spgist index against the
 * source manifest: the complete format and geometry validation of
 * pc_spgist_metapage_ok with the incoming main-fork block count as the
 * size bound. The opclass procedures are not stored on the page; the
 * manifest comparison happens through the target catalog instead.
 */
bool
pc_verify_spgist_metapage(Page page, uint32 nblocks)
{
    const char *detail = NULL;

    return pc_spgist_metapage_ok(page, nblocks, &detail);
}

/*
 * Verify one incoming fixed tree page: block 1 is the normal root and
 * block 2 the nulls root; both bypass the metapage-only dispatch above,
 * and the generic page-header checks alone would accept a corrupted or
 * all-zero root. Anything but those two blocks is not validated here.
 */
bool
pc_verify_spgist_tree_page(Page page, uint32 blkno)
{
    const char *detail = NULL;

    if (blkno != SPGIST_ROOT_BLKNO && blkno != SPGIST_NULL_BLKNO)
        return true;
    return pc_spgist_tree_page_ok(page, blkno == SPGIST_NULL_BLKNO, &detail);
}
