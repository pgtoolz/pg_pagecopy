//! B-tree access-method specifics of index transfer: physical metadata read
//! from the source catalog and metapage, physical-layout compatibility
//! between source and target, and verification of transferred metapages. The
//! C half lives in `src/index_btree.c`; its FFI declarations stay here so
//! the access method owns its C surface. Only `indexes` dispatches here, so
//! the transfer paths stay access-method agnostic.

use super::super::ffi::{self, Rel};
use pgrx::pg_sys;
use std::os::raw::c_char;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BtreeMetadata {
    pub definition: String,
    pub shape: String,
    pub btree_version: u32,
    pub all_equal_image: bool,
    pub expected_all_equal_image: bool,
}

impl BtreeMetadata {
    pub fn has_same_physical_layout(&self, other: &Self) -> bool {
        // Dedup flags belong to the source metapage; newer majors can read older non-dedup pages.
        self.definition == other.definition
            && self.shape == other.shape
            && self.btree_version == other.btree_version
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct RawBtreeMetadata {
    version: u32,
    all_equal_image: bool,
    expected_all_equal_image: bool,
}

unsafe extern "C" {
    fn pc_verify_btree_metapage(page: *mut c_char, all_equal_image: bool) -> bool;
    fn pc_btree_metadata(rel: pg_sys::Relation, metadata: *mut RawBtreeMetadata);
}

/// Full physical metadata of one source btree index: catalog identity plus
/// the metapage version and dedup flags.
///
/// # Safety
/// Opens the index under `ShareLock` until the statement ends.
pub(super) fn metadata(oid: pg_sys::Oid) -> Result<BtreeMetadata, String> {
    let (definition, shape) = ffi::index_catalog_metadata(oid)?;
    let rel = unsafe { Rel::open(oid, pg_sys::ShareLock.cast_signed()) };
    let mut raw = RawBtreeMetadata::default();
    unsafe { ffi::guard(|| pc_btree_metadata(rel.raw(), &raw mut raw)) };
    Ok(BtreeMetadata {
        definition,
        shape,
        btree_version: raw.version,
        all_equal_image: raw.all_equal_image,
        expected_all_equal_image: raw.expected_all_equal_image,
    })
}

/// Whether an open target index is a btree with the source physical layout.
pub(super) fn matches_layout(expected: &BtreeMetadata, index: &Rel) -> bool {
    index.is_btree()
        && metadata(index.oid()).is_ok_and(|actual| actual.has_same_physical_layout(expected))
}

/// The target TOAST index must match the source physical layout exactly;
/// unlike user indexes it can never degrade to a definition.
pub(super) fn toast_layout(expected: &BtreeMetadata, target: &Rel) -> Result<(), String> {
    let actual = metadata(target.oid())?;
    if !actual.has_same_physical_layout(expected) {
        return Err(format!(
            "source and target TOAST btree metadata differ: source={expected:?}, target={actual:?}"
        ));
    }
    Ok(())
}

/// Verify the metapage (block 0) of a transferred btree index against the
/// expected dedup flag.
pub(super) fn verify_metapage(page: &mut [u8], all_equal_image: bool) -> bool {
    assert_eq!(page.len(), ffi::PAGE_SIZE);
    unsafe { ffi::guard(|| pc_verify_btree_metapage(page.as_mut_ptr().cast(), all_equal_image)) }
}

// The layout rule moved here from the wire tests; it guards AM compatibility.
#[cfg(test)]
mod tests {
    use super::BtreeMetadata;

    #[test]
    fn btree_layout_allows_dedup_flag_changes_across_majors() {
        let source = BtreeMetadata {
            definition: "btree (chunk_id, chunk_seq)".into(),
            shape: "2|2|t|f|1 2|0 0|pg_catalog.oid_ops,pg_catalog.int4_ops|".into(),
            btree_version: 4,
            all_equal_image: false,
            expected_all_equal_image: false,
        };
        let mut target = BtreeMetadata {
            all_equal_image: true,
            expected_all_equal_image: true,
            ..source.clone()
        };
        assert!(source.has_same_physical_layout(&target));
        target.btree_version = 3;
        assert!(!source.has_same_physical_layout(&target));
    }
}
