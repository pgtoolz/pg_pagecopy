//! Index classification, degradation and target matching shared by every
//! transfer path. Catalog identity reads (definition, shape, opclass) come
//! from `ffi`, btree physicals from [`btree`] and brin physicals from
//! [`brin`]; this module owns the policy: which index transfers as page
//! images, which degrades to its definition, how each manifest index is
//! matched and installed on the target, and how incoming index pages are
//! verified against their manifest entries.

use super::super::ffi::{self, Rel};
use super::brin;
use super::btree;
use super::gist;
use super::hash;
use super::wire::IndexTransfer;
use super::{BrinMetadata, BtreeMetadata, GistMetadata, HashMetadata};
use pgrx::pg_sys;

/// How one source index crosses to the target. The metadata callback selects
/// catalog-only preflight or the full physical checks, sharing all other rules.
pub enum ClassifyIndex<T> {
    Physical(T),
    /// Transfer the definition only; the target index stays INVALID until REINDEX.
    Invalid {
        definition: String,
        unique: bool,
        reason: String,
    },
}

/// Classify one opened source index. Everything that cannot move as page
/// images degrades to its definition. Custom opclasses remain a hard error.
///
/// # Safety
/// Reads the source catalog; runs inside PostgreSQL. The callback decides
/// whether physical metadata is read.
pub unsafe fn classify_index_with<T>(
    index: &Rel,
    metadata: impl FnOnce(pg_sys::Oid) -> Result<T, String>,
) -> Result<ClassifyIndex<T>, String> {
    let index_oid = index.oid();
    let degradable = |reason: String| -> Result<ClassifyIndex<T>, String> {
        ffi::ensure_no_custom_opclass(index_oid)?;
        Ok(ClassifyIndex::Invalid {
            definition: ffi::index_definition(index_oid)?,
            unique: index.is_unique(),
            reason,
        })
    };
    if let Some(reason) = index.non_physical_reason() {
        return degradable(reason);
    }
    match metadata(index_oid) {
        Ok(metadata) => Ok(ClassifyIndex::Physical(metadata)),
        Err(reason) => degradable(reason),
    }
}

/// Physical metadata of the supported access methods; the access method is
/// selected here from the index's relam, never at the call sites.
pub enum PhysicalMetadata {
    Btree(BtreeMetadata),
    Brin(BrinMetadata),
    Hash(HashMetadata),
    Gist(GistMetadata),
}

/// Classify one opened source index for transfer, reading the full physical
/// metadata of indexes that move as page images.
///
/// # Safety
/// Reads the source catalog; runs inside PostgreSQL.
pub unsafe fn classify_index(index: &Rel) -> Result<ClassifyIndex<PhysicalMetadata>, String> {
    classify_index_with(index, |oid| {
        if index.is_hash_am() {
            hash::metadata(oid).map(PhysicalMetadata::Hash)
        } else if index.is_brin_am() {
            brin::metadata(oid).map(PhysicalMetadata::Brin)
        } else if index.is_gist_am() {
            gist::metadata(oid).map(PhysicalMetadata::Gist)
        } else {
            btree::metadata(oid).map(PhysicalMetadata::Btree)
        }
    })
}

/// Catalog-only preflight mirroring [`classify_index`] for `pagecopy.check`:
/// the same verdicts and degrade reasons without reading index pages.
///
/// # Safety
/// Reads the source catalog; runs inside PostgreSQL.
pub unsafe fn catalog_preflight(index: &Rel, index_oid: pg_sys::Oid) -> Result<(), String> {
    if index.is_hash_am() {
        hash::catalog_preflight(index_oid)
    } else if index.is_brin_am() {
        brin::catalog_preflight(index_oid)
    } else if index.is_gist_am() {
        gist::catalog_preflight(index_oid)
    } else {
        ffi::index_catalog_metadata(index_oid).map(|_| ())
    }
}

/// Manifest entry for a classified source index: physical classifications
/// transfer as page images, everything else degrades to its definition.
impl From<ClassifyIndex<PhysicalMetadata>> for IndexTransfer {
    fn from(classified: ClassifyIndex<PhysicalMetadata>) -> Self {
        match classified {
            ClassifyIndex::Physical(PhysicalMetadata::Btree(metadata)) => {
                IndexTransfer::Btree(metadata)
            }
            ClassifyIndex::Physical(PhysicalMetadata::Brin(metadata)) => {
                IndexTransfer::Brin(metadata)
            }
            ClassifyIndex::Physical(PhysicalMetadata::Hash(metadata)) => {
                IndexTransfer::Hash(metadata)
            }
            ClassifyIndex::Physical(PhysicalMetadata::Gist(metadata)) => {
                IndexTransfer::Gist(metadata)
            }
            ClassifyIndex::Invalid {
                definition,
                unique,
                reason: _,
            } => IndexTransfer::Invalid { definition, unique },
        }
    }
}

/// Shared verdict for a source TOAST index: unlike user indexes it can
/// never degrade to a definition, so a non-btree is a hard error and the
/// metadata callback decides the rest. `pagecopy.check` reports the same
/// reasons with a catalog-only callback.
///
/// # Safety
/// Opens the index under `AccessShareLock` until the statement ends.
pub unsafe fn toast_index_verdict<T>(
    toast_index_oid: pg_sys::Oid,
    metadata: impl FnOnce(pg_sys::Oid) -> Result<T, String>,
) -> Result<T, String> {
    let toast_index = Rel::open(toast_index_oid, pg_sys::AccessShareLock.cast_signed());
    if !toast_index.is_btree() {
        return Err("source TOAST index is not a supported btree".into());
    }
    metadata(toast_index_oid)
}

/// Manifest entry of the source TOAST index: unlike user indexes it can
/// never degrade, so it always transfers as physical pages of a supported
/// btree.
///
/// # Safety
/// Opens the index under `AccessShareLock` until the statement ends.
pub unsafe fn toast_index_transfer(toast_index_oid: pg_sys::Oid) -> Result<IndexTransfer, String> {
    toast_index_verdict(toast_index_oid, btree::metadata).map(IndexTransfer::Btree)
}

/// The target TOAST index must match the manifest entry physically; the
/// dispatch is exhaustive and a degraded (`Invalid`) entry is an error.
pub fn verify_toast_layout(entry: &IndexTransfer, target: &Rel) -> Result<(), String> {
    match entry {
        IndexTransfer::Btree(expected) => btree::toast_layout(expected, target),
        // A TOAST index is always a btree; no other kind can be physical.
        IndexTransfer::Invalid { .. }
        | IndexTransfer::Brin(_)
        | IndexTransfer::Hash(_)
        | IndexTransfer::Gist(_) => Err("source TOAST index is not physical".into()),
    }
}

/// Manifest entry of the n-th physically transferred index in stream order;
/// `Invalid` entries are never streamed, so this counts physical entries.
pub fn physical_index(indexes: &[IndexTransfer], ordinal: usize) -> Option<&IndexTransfer> {
    indexes
        .iter()
        .filter(|entry| !matches!(entry, IndexTransfer::Invalid { .. }))
        .nth(ordinal)
}

/// Verify the first page of a physically transferred index against its
/// manifest entry; entries that never stream fail closed.
pub fn verify_index_metapage(entry: &IndexTransfer, page: &mut [u8], blocks: u32) -> bool {
    match entry {
        IndexTransfer::Btree(metadata) => btree::verify_metapage(page, metadata.all_equal_image),
        IndexTransfer::Brin(metadata) => brin::verify_metapage(page, metadata, blocks),
        IndexTransfer::Hash(metadata) => hash::verify_metapage(page, metadata, blocks),
        IndexTransfer::Gist(_) => gist::verify_metapage(page, blocks),
        IndexTransfer::Invalid { .. } => false,
    }
}

/// Match every manifest user index to one target index and dispatch on the
/// transfer kind: physical matches are enabled and returned in manifest order
/// for page installation, `Invalid` matches stay INVALID on the target with
/// a warning. Every target index must be matched exactly once.
pub fn match_user_indexes(
    source_indexes: &[IndexTransfer],
    target_indexes: &mut Vec<(String, Rel)>,
) -> Result<Vec<Rel>, String> {
    let mut physical = Vec::with_capacity(source_indexes.len());
    for source_index in source_indexes {
        let position = match source_index {
            IndexTransfer::Btree(expected) => target_indexes
                .iter()
                .position(|(_, index)| btree::matches_layout(expected, index)),
            IndexTransfer::Brin(expected) => target_indexes
                .iter()
                .position(|(_, index)| brin::matches_layout(expected, index)),
            IndexTransfer::Hash(expected) => target_indexes
                .iter()
                .position(|(_, index)| hash::matches_layout(expected, index)),
            IndexTransfer::Gist(expected) => target_indexes
                .iter()
                .position(|(_, index)| gist::matches_layout(expected, index)),
            IndexTransfer::Invalid { definition, unique } => target_indexes
                .iter()
                .position(|(candidate, index)| {
                    // Exclude every target that could be a physical
                    // candidate: `is_btree`/`is_brin`/`is_hash`/`is_gist`
                    // are true only for a valid, ready, non-exclusion index
                    // of that AM, so this keeps invalid targets preferred
                    // while a degraded source entry can never consume the
                    // only valid target matching a later physical source
                    // entry.
                    candidate == definition
                        && index.is_unique() == *unique
                        && !index.is_btree()
                        && !index.is_brin()
                        && !index.is_hash()
                        && !index.is_gist()
                })
                .or_else(|| {
                    target_indexes.iter().position(|(candidate, index)| {
                        candidate == definition && index.is_unique() == *unique
                    })
                }),
        }
        .ok_or_else(|| format!("target lacks source index ({source_index:?})"))?;
        let (_, index) = target_indexes.remove(position);
        match source_index {
            IndexTransfer::Btree(_)
            | IndexTransfer::Brin(_)
            | IndexTransfer::Hash(_)
            | IndexTransfer::Gist(_) => {
                index.set_validity(true);
                physical.push(index);
            }
            IndexTransfer::Invalid { .. } => {
                index.set_validity(false);
                pgrx::warning!(
                    "pg_pagecopy: index {} was transferred as INVALID and is not maintained; any uniqueness/exclusion enforcement it provides is disabled, and replica identity using it may be unusable; prevent duplicate/conflicting writes and run REINDEX INDEX before use",
                    index.name()
                );
            }
        }
    }
    if !target_indexes.is_empty() {
        return Err("target has unmatched indexes".into());
    }
    Ok(physical)
}
