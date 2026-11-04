/*
 * HASH access-method helpers for pg_pagecopy, kept apart from the generic
 * page shim (src/page_shim.c) so AM-specific code stays isolated.
 */

#include "postgres.h"

#include "access/genam.h"
#include "access/hash.h"
#include "port/pg_bitutils.h"
#include "storage/bufmgr.h"
#include "storage/bufpage.h"
#include "utils/rel.h"

typedef struct PcHashMetadata
{
    uint32      version;
    uint32      hash_proc;
} PcHashMetadata;

static bool pc_hash_metapage_ok(Page page, BlockNumber nblocks,
                                HashMetaPageData *metap, const char **detail);
void pc_hash_metadata(Relation rel, PcHashMetadata *metadata);
bool pc_verify_hash_metapage(Page page, uint32 version, uint32 hash_proc,
                             uint32 nblocks);

/*
 * _hash_spareindex/_hash_get_totalbuckets decide where buckets and overflow
 * pages live on disk. They live in the backend and are not exported through
 * any stable API, so the formulas are reproduced here exactly as they are in
 * src/backend/access/hash/hashutil.c on every supported major.
 */
static uint32
pc_hash_spareindex(uint32 num_bucket)
{
    uint32      splitpoint_group;

    splitpoint_group = pg_ceil_log2_32(num_bucket);
    if (splitpoint_group < HASH_SPLITPOINT_GROUPS_WITH_ONE_PHASE)
        return splitpoint_group;

    return HASH_SPLITPOINT_GROUPS_WITH_ONE_PHASE +
        ((splitpoint_group - HASH_SPLITPOINT_GROUPS_WITH_ONE_PHASE) <<
         HASH_SPLITPOINT_PHASE_BITS) +
        (((num_bucket - 1) >> (splitpoint_group -
                               (HASH_SPLITPOINT_PHASE_BITS + 1))) &
         HASH_SPLITPOINT_PHASE_MASK);
}

static uint64
pc_hash_totalbuckets(uint32 splitpoint_phase)
{
    uint32      splitpoint_group;
    uint32      phases_within_group;

    if (splitpoint_phase < HASH_SPLITPOINT_GROUPS_WITH_ONE_PHASE)
        return 1ULL << splitpoint_phase;

    splitpoint_group = HASH_SPLITPOINT_GROUPS_WITH_ONE_PHASE +
        ((splitpoint_phase - HASH_SPLITPOINT_GROUPS_WITH_ONE_PHASE) >>
         HASH_SPLITPOINT_PHASE_BITS);
    phases_within_group =
        ((splitpoint_phase - HASH_SPLITPOINT_GROUPS_WITH_ONE_PHASE) &
         HASH_SPLITPOINT_PHASE_MASK) + 1;

    return (1ULL << (splitpoint_group - 1)) +
        ((1ULL << (splitpoint_group - 1)) >> HASH_SPLITPOINT_PHASE_BITS) *
        phases_within_group;
}

/*
 * Validate the whole metapage against the allocation geometry it claims,
 * with the incoming main-fork block count as the only size bound. Every
 * check is fail-closed: page layout, disk format, and the derived geometry
 * must all be internally consistent. Mutable control state (ffactor,
 * ntuples, spares, mapp) is validated for sanity, never compared against a
 * freshly built target index, whose state legitimately differs.
 */
static bool
pc_hash_metapage_ok(Page page, BlockNumber nblocks,
                    HashMetaPageData *metap_out, const char **detail)
{
    PageHeader  phdr = (PageHeader) page;
    HashPageOpaque opaque;
    HashMetaPageData *metap;
    uint16      expected_bsize;
    uint16      expected_bmsize;
    uint16      expected_bmshift;
    uint64      min_blocks;
    uint32      ovflpoint;
    uint32      i;
    uint32      j;

    if (PageIsNew(page))
    {
        *detail = "hash metapage is uninitialized";
        return false;
    }
    if (PageGetSpecialSize(page) != MAXALIGN(sizeof(HashPageOpaqueData)))
    {
        *detail = "hash metapage has an unexpected special area";
        return false;
    }
    opaque = (HashPageOpaque) PageGetSpecialPointer(page);
    if (opaque->hasho_page_id != HASHO_PAGE_ID)
    {
        *detail = "hash metapage has an unexpected page id";
        return false;
    }
    if ((opaque->hasho_flag & LH_PAGE_TYPE) != LH_META_PAGE)
    {
        *detail = "hash metapage is not a metapage";
        return false;
    }
    /* The metadata must survive standard-page WAL compression, whose hole
     * is [pd_lower, pd_upper); upstream sets pd_lower past the complete
     * HashMetaPageData for exactly this reason. */
    if (phdr->pd_lower < SizeOfPageHeaderData + MAXALIGN(sizeof(HashMetaPageData)) ||
        phdr->pd_upper != phdr->pd_special ||
        phdr->pd_special != BLCKSZ - MAXALIGN(sizeof(HashPageOpaqueData)))
    {
        *detail = "hash metapage does not cover its metadata";
        return false;
    }

    metap = HashPageGetMeta(page);
    if (metap->hashm_magic != HASH_MAGIC)
    {
        *detail = "hash metapage magic mismatch";
        return false;
    }
    if (metap->hashm_version != HASH_VERSION)
    {
        *detail = "hash metapage version mismatch";
        return false;
    }

    /* bsize/bmsize/bmshift are derived from the page layout, not options. */
    expected_bsize = BLCKSZ -
        (MAXALIGN(SizeOfPageHeaderData) +
         MAXALIGN(sizeof(HashPageOpaqueData)));
    if (metap->hashm_bsize != expected_bsize)
    {
        *detail = "hash metapage bsize mismatch";
        return false;
    }
    expected_bmsize = 1;
    while ((uint32) expected_bmsize * 2 <= expected_bsize)
        expected_bmsize *= 2;
    if (metap->hashm_bmsize != expected_bmsize)
    {
        *detail = "hash metapage bmsize mismatch";
        return false;
    }
    expected_bmshift = pg_ceil_log2_32(expected_bmsize) + 3;
    if (metap->hashm_bmshift != expected_bmshift)
    {
        *detail = "hash metapage bmshift mismatch";
        return false;
    }

    /* ffactor is the split threshold, at least HASH_MIN_FILLFACTOR-derived
     * and never wider than a page of tuple slots. */
    if (metap->hashm_ffactor < HASH_MIN_FILLFACTOR ||
        metap->hashm_ffactor > expected_bsize)
    {
        *detail = "hash metapage fillfactor out of range";
        return false;
    }
    if (isnan(metap->hashm_ntuples) || isinf(metap->hashm_ntuples) ||
        metap->hashm_ntuples < 0.0)
    {
        *detail = "hash metapage tuple count out of range";
        return false;
    }

    if (metap->hashm_maxbucket < 1 || metap->hashm_maxbucket > 0x7FFFFFFE)
    {
        *detail = "hash metapage maxbucket out of range";
        return false;
    }
    if ((metap->hashm_highmask & (metap->hashm_highmask + 1)) != 0 ||
        metap->hashm_highmask < 1 ||
        metap->hashm_lowmask != metap->hashm_highmask >> 1 ||
        metap->hashm_lowmask > metap->hashm_maxbucket ||
        metap->hashm_maxbucket > metap->hashm_highmask)
    {
        *detail = "hash metapage masks are inconsistent";
        return false;
    }

    ovflpoint = metap->hashm_ovflpoint;
    if (ovflpoint >= HASH_MAX_SPLITPOINTS ||
        ovflpoint != pc_hash_spareindex(metap->hashm_maxbucket + 1))
    {
        *detail = "hash metapage ovflpoint is inconsistent with maxbucket";
        return false;
    }
    for (i = 0; i < ovflpoint; i++)
    {
        if (metap->hashm_spares[i] > metap->hashm_spares[i + 1])
        {
            *detail = "hash metapage spares are not cumulative";
            return false;
        }
    }
    if (metap->hashm_firstfree > metap->hashm_spares[ovflpoint])
    {
        *detail = "hash metapage firstfree is out of range";
        return false;
    }

    if (metap->hashm_nmaps < 1 || metap->hashm_nmaps > HASH_MAX_BITMAPS)
    {
        *detail = "hash metapage bitmap count out of range";
        return false;
    }
    for (i = 0; i < metap->hashm_nmaps; i++)
    {
        if (metap->hashm_mapp[i] < 1 || metap->hashm_mapp[i] >= nblocks)
        {
            *detail = "hash metapage bitmap address out of range";
            return false;
        }
        for (j = 0; j < i; j++)
        {
            if (metap->hashm_mapp[i] == metap->hashm_mapp[j])
            {
                *detail = "hash metapage bitmap addresses are not distinct";
                return false;
            }
        }
    }

    /* One metapage, the whole allocated bucket space of the current phase
     * and every allocated overflow/bitmap page must fit in the file;
     * bucket allocation reserves whole phases ahead of hashm_maxbucket, so
     * a longer file is legitimate reserved space, a shorter one is not. */
    min_blocks = 1 + pc_hash_totalbuckets(ovflpoint) +
        (uint64) metap->hashm_spares[ovflpoint];
    if (nblocks < min_blocks)
    {
        *detail = "hash metapage geometry exceeds the index size";
        return false;
    }

    *metap_out = *metap;
    return true;
}

/*
 * Read the source index format identity from its metapage under a buffer
 * share lock. The stored hashm_procid is forensic but must still match the
 * procedure the source catalog resolves for the index's first key, so an
 * index whose hashing semantics changed underneath its pages fails closed.
 */
void
pc_hash_metadata(Relation rel, PcHashMetadata *metadata)
{
    Buffer      buffer;
    Page        page;
    HashMetaPageData metap;
    const char *detail = NULL;
    RegProcedure hash_proc;

    buffer = ReadBuffer(rel, HASH_METAPAGE);
    LockBuffer(buffer, BUFFER_LOCK_SHARE);
    page = BufferGetPage(buffer);
    if (!pc_hash_metapage_ok(page, RelationGetNumberOfBlocks(rel), &metap, &detail))
        elog(ERROR, "pg_pagecopy: %s", detail);
    UnlockReleaseBuffer(buffer);

    hash_proc = index_getprocid(rel, 1, HASHSTANDARD_PROC);
    if (hash_proc == InvalidOid || metap.hashm_procid != hash_proc)
        elog(ERROR, "pg_pagecopy: hash metapage support function mismatch");
    metadata->version = metap.hashm_version;
    metadata->hash_proc = metap.hashm_procid;
}

/*
 * Verify the metapage (block 0) of an incoming hash index against the
 * source manifest: the complete format and geometry validation of
 * pc_hash_metapage_ok plus an exact match of the recorded format version
 * and hash support procedure.
 */
bool
pc_verify_hash_metapage(Page page, uint32 version, uint32 hash_proc,
                        uint32 nblocks)
{
    HashMetaPageData metap;
    const char *detail = NULL;

    return pc_hash_metapage_ok(page, nblocks, &metap, &detail) &&
        metap.hashm_version == version &&
        metap.hashm_procid == hash_proc;
}
