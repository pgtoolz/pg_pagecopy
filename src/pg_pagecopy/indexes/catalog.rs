//! Index classification, degradation and target matching shared by every
//! transfer path. Catalog identity reads (definition, shape, opclass and
//! metapage metadata) come from `ffi`; this module owns the policy: which
//! index transfers as page images, which degrades to its definition, and how
//! each manifest index is matched and installed on the target.

use super::super::ffi::{self, Rel};
use super::wire::{BtreeMetadata, IndexTransfer};
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

/// The target TOAST index must match the source physical layout exactly;
/// unlike user indexes it can never degrade to a definition.
pub fn toast_layout(expected: &BtreeMetadata, target: &Rel) -> Result<(), String> {
    let actual = ffi::index_metadata(target.oid())?;
    if !actual.has_same_physical_layout(expected) {
        return Err(format!(
            "source and target TOAST btree metadata differ: source={expected:?}, target={actual:?}"
        ));
    }
    Ok(())
}

/// Match every manifest user index to one target index and dispatch on the
/// transfer kind: `Btree` matches are enabled and returned in manifest order
/// for page installation, `Invalid` matches stay INVALID on the target with
/// a warning. Every target index must be matched exactly once.
pub fn match_user_indexes(
    source_indexes: &[IndexTransfer],
    target_indexes: &mut Vec<(String, Rel)>,
) -> Result<Vec<Rel>, String> {
    let mut physical = Vec::with_capacity(source_indexes.len());
    for source_index in source_indexes {
        let position = match source_index {
            IndexTransfer::Btree(expected) => target_indexes.iter().position(|(_, index)| {
                index.is_btree()
                    && ffi::index_metadata(index.oid())
                        .is_ok_and(|actual| actual.has_same_physical_layout(expected))
            }),
            IndexTransfer::Invalid { definition, unique } => target_indexes
                .iter()
                .position(|(candidate, index)| {
                    candidate == definition && index.is_unique() == *unique && !index.is_btree()
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
            IndexTransfer::Btree(_) => {
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
