/*
 * BRIN access-method helpers for pg_pagecopy, kept apart from the generic
 * page shim (src/page_shim.c) so AM-specific code stays isolated.
 */

#include "postgres.h"

#include "access/brin.h"
#include "access/brin_page.h"
#include "storage/bufmgr.h"
#include "storage/bufpage.h"
#include "utils/rel.h"

typedef struct PcBrinMetadata
{
    uint32      version;
    uint32      pages_per_range;
    uint32      last_revmap_page;
} PcBrinMetadata;

static void pc_brin_check_page(Page page, uint16 type);
void pc_brin_metadata(Relation rel, PcBrinMetadata *metadata);
bool pc_verify_brin_metapage(Page page, uint32 version, uint32 pages_per_range,
                             uint32 last_revmap_page, uint32 nblocks);

/*
 * Reject pages whose special area is not a BRIN special space before reading
 * the page type out of it, mirroring contrib/pageinspect's checks.
 */
static void
pc_brin_check_page(Page page, uint16 type)
{
    if (PageIsNew(page))
        elog(ERROR, "pg_pagecopy: brin page is uninitialized");
    if (PageGetSpecialSize(page) != MAXALIGN(sizeof(BrinSpecialSpace)))
        elog(ERROR, "pg_pagecopy: brin page has an unexpected special area");
    if (BrinPageType(page) != type)
        elog(ERROR, "pg_pagecopy: brin page has an unexpected type");
}

/*
 * Read the source index geometry from its metapage under a buffer share
 * lock. The metapage, not the catalog reloption, governs how the existing
 * revmap and summaries must be interpreted, so a catalog value that drifted
 * apart (ALTER INDEX ... SET pages_per_range does not rewrite the index) is
 * rejected instead of being guessed at.
 */
void
pc_brin_metadata(Relation rel, PcBrinMetadata *metadata)
{
    Buffer      buffer;
    Page        page;
    BrinMetaPageData *contents;
    uint32      catalog_pages_per_range;
    BlockNumber nblocks;

    catalog_pages_per_range = BrinGetPagesPerRange(rel);

    buffer = ReadBuffer(rel, BRIN_METAPAGE_BLKNO);
    LockBuffer(buffer, BUFFER_LOCK_SHARE);
    page = BufferGetPage(buffer);
    pc_brin_check_page(page, BRIN_PAGETYPE_META);
    contents = (BrinMetaPageData *) PageGetContents(page);
    if (contents->brinMagic != BRIN_META_MAGIC)
        elog(ERROR, "pg_pagecopy: brin metapage magic mismatch");
    if (contents->brinVersion != BRIN_CURRENT_VERSION)
        elog(ERROR, "pg_pagecopy: unsupported brin metapage version");
    if (contents->pagesPerRange == 0)
        elog(ERROR, "pg_pagecopy: brin pages_per_range out of range");
    nblocks = RelationGetNumberOfBlocks(rel);
    if (nblocks == 0 || contents->lastRevmapPage >= nblocks)
        elog(ERROR, "pg_pagecopy: brin revmap exceeds the index size");
    if (catalog_pages_per_range != contents->pagesPerRange)
        elog(ERROR, "pg_pagecopy: brin catalog pages_per_range differs from the metapage");
    metadata->version = contents->brinVersion;
    metadata->pages_per_range = contents->pagesPerRange;
    metadata->last_revmap_page = contents->lastRevmapPage;
    UnlockReleaseBuffer(buffer);
}

/*
 * Verify the metapage (block 0) of an incoming brin index against the source
 * manifest. The incoming metadata must match exactly, including
 * last_revmap_page, and stay within the incoming main-fork block count.
 */
bool
pc_verify_brin_metapage(Page page, uint32 version, uint32 pages_per_range,
                        uint32 last_revmap_page, uint32 nblocks)
{
    BrinMetaPageData *contents;

    if (PageIsNew(page))
        return false;
    if (PageGetSpecialSize(page) != MAXALIGN(sizeof(BrinSpecialSpace)))
        return false;
    if (BrinPageType(page) != BRIN_PAGETYPE_META)
        return false;
    contents = (BrinMetaPageData *) PageGetContents(page);
    return contents->brinMagic == BRIN_META_MAGIC &&
        contents->brinVersion == version &&
        contents->pagesPerRange == pages_per_range &&
        contents->lastRevmapPage == last_revmap_page &&
        nblocks >= 1 && last_revmap_page < nblocks;
}
