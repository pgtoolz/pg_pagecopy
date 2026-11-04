/*
 * B-tree access-method helpers for pg_pagecopy, kept apart from the generic
 * page shim (src/page_shim.c) so AM-specific code stays isolated.
 */

#include "postgres.h"

#include "access/nbtree.h"
#include "storage/bufmgr.h"
#include "storage/bufpage.h"
#include "utils/rel.h"

typedef struct PcBtreeMetadata
{
    uint32      version;
    bool        all_equal_image;
    bool        expected_all_equal_image;
} PcBtreeMetadata;

bool pc_verify_btree_metapage(Page page, bool all_equal_image);
void pc_btree_metadata(Relation rel, PcBtreeMetadata *metadata);

bool
pc_verify_btree_metapage(Page page, bool all_equal_image)
{
    BTMetaPageData *metadata;

    if (PageIsNew(page))
        return false;
    metadata = BTPageGetMeta(page);
    return metadata->btm_magic == BTREE_MAGIC &&
        metadata->btm_version >= BTREE_MIN_VERSION &&
        metadata->btm_version <= BTREE_VERSION &&
        metadata->btm_allequalimage == all_equal_image;
}

void
pc_btree_metadata(Relation rel, PcBtreeMetadata *metadata)
{
    Buffer buffer;
    Page page;
    BTMetaPageData *metapage;

    buffer = ReadBuffer(rel, BTREE_METAPAGE);
    LockBuffer(buffer, BUFFER_LOCK_SHARE);
    page = BufferGetPage(buffer);
    if (PageIsNew(page))
        elog(ERROR, "pg_pagecopy: btree metapage is uninitialized");
    metapage = BTPageGetMeta(page);
    if (metapage->btm_magic != BTREE_MAGIC ||
        metapage->btm_version < BTREE_MIN_VERSION ||
        metapage->btm_version > BTREE_VERSION)
        elog(ERROR, "pg_pagecopy: unsupported btree metapage format");
    metadata->version = metapage->btm_version;
    metadata->all_equal_image = metapage->btm_allequalimage;
    metadata->expected_all_equal_image = _bt_allequalimage(rel, false);
    UnlockReleaseBuffer(buffer);
}
