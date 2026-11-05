/*
 * GiST access-method helpers for pg_pagecopy, kept apart from the generic
 * page shim (src/page_shim.c) so AM-specific code stays isolated.
 */

#include "postgres.h"

#include "access/gist.h"
#include "storage/bufmgr.h"
#include "storage/bufpage.h"
#include "utils/rel.h"

void pc_prepare_page(Page page, BlockNumber blkno, bool checksums);

/* The root block number lives in gist_private.h, which is not an installed
 * stable header; the GiST root has been block 0 on every supported major. */
#define PC_GIST_ROOT_BLKNO ((BlockNumber) 0)

/* Only these flag bits exist on disk in every supported major. */
#define PC_GIST_KNOWN_FLAGS \
    (F_LEAF | F_DELETED | F_TUPLES_DELETED | F_FOLLOW_RIGHT | F_HAS_GARBAGE)

/*
 * Structural checks shared by every reader: a real GiST page whose special
 * area carries only the flag bits this code knows.
 */
static bool
pc_gist_page_ok(Page page, const char **detail)
{
    GISTPageOpaque opaque;

    if (PageGetSpecialSize(page) != MAXALIGN(sizeof(GISTPageOpaqueData)))
    {
        *detail = "gist page has an unexpected special area";
        return false;
    }
    opaque = GistPageGetOpaque(page);
    if (opaque->gist_page_id != GIST_PAGE_ID)
    {
        *detail = "gist page has an unexpected page id";
        return false;
    }
    if ((opaque->flags & ~PC_GIST_KNOWN_FLAGS) != 0)
    {
        *detail = "gist page has unknown flag bits";
        return false;
    }
    return true;
}

/*
 * The root (block 0) of a valid GiST index: never deleted (pages are only
 * deleted below the root), never follow-right (a root split installs every
 * downlink into the new root inside the same WAL record) and never linked
 * right. GiST has no metapage, so the root is the only page whose geometry
 * is self-evident.
 */
static bool
pc_gist_root_ok(Page page, const char **detail)
{
    GISTPageOpaque opaque;

    if (!pc_gist_page_ok(page, detail))
        return false;
    opaque = GistPageGetOpaque(page);
    if (opaque->flags & F_DELETED)
    {
        *detail = "gist root page is deleted";
        return false;
    }
    if (opaque->flags & F_FOLLOW_RIGHT)
    {
        *detail = "gist root page has an incomplete split";
        return false;
    }
    if (opaque->rightlink != InvalidBlockNumber)
    {
        *detail = "gist root page has a rightlink";
        return false;
    }
    return true;
}

/*
 * Validate the root of a source GiST index before its pages transfer.
 */
void
pc_gist_check_root(Relation rel)
{
    Buffer      buffer;
    Page        page;
    const char *detail;

    buffer = ReadBuffer(rel, PC_GIST_ROOT_BLKNO);
    LockBuffer(buffer, BUFFER_LOCK_SHARE);
    page = BufferGetPage(buffer);
    if (PageIsNew(page))
        elog(ERROR, "pg_pagecopy: gist root page is uninitialized");
    if (!pc_gist_root_ok(page, &detail))
        elog(ERROR, "pg_pagecopy: %s", detail);
    UnlockReleaseBuffer(buffer);
}

/*
 * Prepare one GiST main-fork page: the page LSN is reset like every page's,
 * and the NSN is stamped with GistBuildLSN for the same reason. A copied
 * NSN is an LSN of the source cluster, so next to reset target page LSNs it
 * would exceed every parent LSN forever: scans would treat each completed
 * split as in progress, follow rightlinks into pages the parent already
 * covers through their own downlinks and return those rows twice.
 * GistBuildLSN is the value an index build leaves behind, so every
 * pre-transfer split counts as complete while a post-transfer split, whose
 * WAL LSN is larger, still reads as in progress. Pages of a genuinely
 * incomplete split keep their F_FOLLOW_RIGHT flag and rightlink, so
 * chain-following keeps working off the flag alone.
 */
void
pc_prepare_gist_page(Page page, BlockNumber blkno, bool checksums)
{
    const char *detail;

    if (PageIsNew(page))
    {
        pc_prepare_page(page, blkno, checksums);
        return;
    }
    if (!pc_gist_page_ok(page, &detail))
        elog(ERROR, "pg_pagecopy: %s", detail);
    GistPageSetNSN(page, GistBuildLSN);
    pc_prepare_page(page, blkno, checksums);
}

/*
 * Verify the root (block 0) of an incoming GiST index: the root invariants
 * above plus the NSN stamp every transferred GiST page carries.
 */
bool
pc_verify_gist_root(Page page, BlockNumber nblocks)
{
    const char *detail;

    if (PageIsNew(page) || nblocks < 1)
        return false;
    if (!pc_gist_root_ok(page, &detail))
        return false;
    return GistPageGetNSN(page) == GistBuildLSN;
}
