//! SP-GiST access-method specifics of index transfer: physical metadata read
//! from the source catalog and fixed pages, the exact opclass/type pairs
//! that transfer as page images, physical-layout compatibility between
//! source and target, and verification of transferred metapages. The C half
//! lives in `src/index_spgist.c`; its FFI declarations stay here so the
//! access method owns its C surface. Only `indexes` dispatches here, so the
//! transfer paths stay access-method agnostic.

use super::super::ffi::{self, Rel};
use pgrx::pg_sys;
use pgrx::spi::Spi;
use std::os::raw::c_char;

#[allow(clippy::struct_field_names)] // The five required support procedures, named after their proc numbers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpgistMetadata {
    pub definition: String,
    pub shape: String,
    /// The five required support procedures (`SPGIST_CONFIG_PROC` through
    /// `SPGIST_LEAF_CONSISTENT_PROC`) as the source catalog resolves them.
    /// The SP-GiST metapage stores no opclass identity of its own, so these
    /// pinned core function OIDs are the format identity compared across
    /// clusters, exactly like the hash metapage's stored `hashm_procid`.
    pub config_proc: u32,
    pub choose_proc: u32,
    pub picksplit_proc: u32,
    pub inner_consistent_proc: u32,
    pub leaf_consistent_proc: u32,
}

impl SpgistMetadata {
    pub fn has_same_physical_layout(&self, other: &Self) -> bool {
        // lastUsedPages of the metapage is mutable shared page-cache state;
        // it transfers with the pages, so a freshly created empty target
        // legitimately differs.
        self.definition == other.definition
            && self.shape == other.shape
            && self.config_proc == other.config_proc
            && self.choose_proc == other.choose_proc
            && self.picksplit_proc == other.picksplit_proc
            && self.inner_consistent_proc == other.inner_consistent_proc
            && self.leaf_consistent_proc == other.leaf_consistent_proc
    }
}

#[repr(C)]
#[allow(clippy::struct_field_names)] // Mirrors the five C support-procedure fields.
#[derive(Clone, Copy, Default)]
struct RawSpgistMetadata {
    config_proc: u32,
    choose_proc: u32,
    picksplit_proc: u32,
    inner_consistent_proc: u32,
    leaf_consistent_proc: u32,
}

unsafe extern "C" {
    fn pc_verify_spgist_metapage(page: *mut c_char, blocks: u32) -> bool;
    fn pc_verify_spgist_tree_page(page: *mut c_char, blkno: u32) -> bool;
    fn pc_spgist_metadata(rel: pg_sys::Relation, metadata: *mut RawSpgistMetadata);
}

/// Exact core opclass and indexed-type pairs that transfer as page images.
/// `quad_point_ops` and `kd_point_ops` (implemented in
/// `spgquadtreeproc.c`/`spgkdtreeproc.c`) store fixed-width `point` leaf
/// datums with `point` (quad) or `float8` (kd) prefixes and no node labels
/// — no varlena, TOAST, collation or datum-size dependence — and their
/// support functions plus pinned `pg_proc` OIDs (4018–4026) are identical
/// on every supported major, so the tree pages mean the same thing on any
/// target. Every other SP-GiST index (`text_ops` radix trees whose label
/// layout and long-value handling were never audited across majors,
/// `poly_ops`, `box_ops`, `range_ops`, `inet_ops`, expressions, partials,
/// included columns) stays on the degraded definition-only path; custom
/// opclasses remain a hard error.
const APPROVED_SPGIST: [(&str, pg_sys::Oid); 2] = [
    ("quad_point_ops", pg_sys::POINTOID),
    ("kd_point_ops", pg_sys::POINTOID),
];

/// Reject SP-GiST indexes whose key is not one plain column of the approved
/// exact core opclass/type pairs. The indexed type is compared by its
/// built-in OID, so binary-compatible user types and custom opclasses named
/// like core ones never pass. Expression and partial indexes degrade because
/// their catalog shape proves neither the indexed expression's semantics nor
/// the predicate's on the target, and included or multiple columns change
/// the leaf-tuple layout itself.
fn ensure_approved_spgist(index_oid: pg_sys::Oid) -> Result<(), String> {
    Spi::connect(|client| {
        let flags = client
            .select(
                "SELECT i.indnkeyatts, i.indnatts, \
                        EXISTS (SELECT 1 FROM unnest(i.indkey) AS k(attnum) WHERE k.attnum = 0), \
                        i.indexprs IS NOT NULL OR i.indpred IS NOT NULL \
                 FROM pg_index i WHERE i.indexrelid = $1",
                Some(1),
                &[index_oid.into()],
            )
            .map_err(|error| error.to_string())?
            .first();
        let key_count = i64::from(
            flags
                .get::<i32>(1)
                .map_err(|error| error.to_string())?
                .ok_or_else(|| "index catalog metadata is missing".to_owned())?,
        );
        let total_count = i64::from(
            flags
                .get::<i32>(2)
                .map_err(|error| error.to_string())?
                .unwrap_or(0),
        );
        let not_plain_column = flags
            .get::<bool>(3)
            .map_err(|error| error.to_string())?
            .unwrap_or(true);
        let has_expressions_or_predicate = flags
            .get::<bool>(4)
            .map_err(|error| error.to_string())?
            .unwrap_or(true);
        if not_plain_column || has_expressions_or_predicate {
            return Ok::<_, String>(Err(
                "spgist expression or partial indexes are not transferred".into(),
            ));
        }
        let rows = client
            .select(
                "SELECT n.nspname::text, o.opcname::text, a.atttypid, t.typname::text \
                 FROM pg_index i \
                 JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord) ON k.attnum <> 0 \
                 JOIN LATERAL unnest(i.indclass) WITH ORDINALITY AS c(opcoid, ord) ON c.ord = k.ord \
                 JOIN pg_opclass o ON o.oid = c.opcoid \
                 JOIN pg_namespace n ON n.oid = o.opcnamespace \
                 JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum \
                 JOIN pg_type t ON t.oid = a.atttypid \
                 WHERE i.indexrelid = $1 ORDER BY k.ord",
                None,
                &[index_oid.into()],
            )
            .map_err(|error| error.to_string())?;
        let mut keys = 0i64;
        for row in rows {
            let opcnamespace = row
                .get::<String>(1)
                .map_err(|error| error.to_string())?
                .unwrap_or_default();
            let opcname = row
                .get::<String>(2)
                .map_err(|error| error.to_string())?
                .unwrap_or_default();
            let typoid = row
                .get::<pg_sys::Oid>(3)
                .map_err(|error| error.to_string())?
                .unwrap_or(pg_sys::Oid::INVALID);
            let typname = row
                .get::<String>(4)
                .map_err(|error| error.to_string())?
                .unwrap_or_default();
            let approved = opcnamespace == "pg_catalog"
                && APPROVED_SPGIST
                    .iter()
                    .any(|(name, approved_type)| *name == opcname && typoid == *approved_type);
            if !approved {
                return Ok::<_, String>(Err(format!(
                    "spgist opclass {opcnamespace}.{opcname} on {typname} is not one of the core point pairs"
                )));
            }
            keys += 1;
        }
        if keys != key_count || key_count != 1 || total_count != 1 {
            return Ok::<_, String>(Err(
                "spgist indexes with included or multiple columns are not transferred".into(),
            ));
        }
        Ok(Ok(()))
    })?
}

/// Catalog-only checks so `pagecopy.check` reports the same verdicts as the
/// physical transfer without reading index pages.
pub(super) fn catalog_preflight(index_oid: pg_sys::Oid) -> Result<(), String> {
    ffi::index_catalog_metadata(index_oid).map(|_| ())?;
    ensure_approved_spgist(index_oid)
}

/// Full physical metadata of one source spgist index: catalog identity plus
/// the metapage format and the required support procedures, read under a
/// share lock.
///
/// # Safety
/// Opens the index under `ShareLock` until the statement ends.
pub(super) fn metadata(oid: pg_sys::Oid) -> Result<SpgistMetadata, String> {
    let (definition, shape) = ffi::index_catalog_metadata(oid)?;
    ensure_approved_spgist(oid)?;
    let rel = unsafe { Rel::open(oid, pg_sys::ShareLock.cast_signed()) };
    let mut raw = RawSpgistMetadata::default();
    unsafe { ffi::guard(|| pc_spgist_metadata(rel.raw(), &raw mut raw)) };
    Ok(SpgistMetadata {
        definition,
        shape,
        config_proc: raw.config_proc,
        choose_proc: raw.choose_proc,
        picksplit_proc: raw.picksplit_proc,
        inner_consistent_proc: raw.inner_consistent_proc,
        leaf_consistent_proc: raw.leaf_consistent_proc,
    })
}

/// Whether an open target index is a spgist with the source physical layout.
pub(super) fn matches_layout(expected: &SpgistMetadata, index: &Rel) -> bool {
    index.is_spgist()
        && metadata(index.oid()).is_ok_and(|actual| actual.has_same_physical_layout(expected))
}

/// Verify the metapage (block 0) of a transferred spgist index against the
/// manifest: exact magic and page identity, coherent fixed-page geometry
/// checked against the incoming main-fork block count, and a lastUsedPages
/// cache whose addresses stay inside the transferred file. The metapage
/// stores no per-index format identity to compare with the manifest entry;
/// the opclass procedures are checked through the target catalog instead,
/// so unlike the hash verifier this takes no manifest metadata.
pub(super) fn verify_metapage(page: &mut [u8], blocks: u32) -> bool {
    assert_eq!(page.len(), ffi::PAGE_SIZE);
    unsafe { ffi::guard(|| pc_verify_spgist_metapage(page.as_mut_ptr().cast(), blocks)) }
}

/// Verify one incoming fixed tree page (block 1 root / block 2 nulls
/// root) of a transferred spgist index: the generic page-header checks
/// alone would accept a corrupted or all-zero root. Other blocks are not
/// fixed pages and return true untouched.
pub(super) fn verify_tree_page(page: &mut [u8], blkno: u32) -> bool {
    assert_eq!(page.len(), ffi::PAGE_SIZE);
    unsafe { ffi::guard(|| pc_verify_spgist_tree_page(page.as_mut_ptr().cast(), blkno)) }
}

// The layout rule guards AM compatibility; see the BRIN/btree equivalents.
#[cfg(test)]
mod tests {
    use super::SpgistMetadata;

    fn spgist() -> SpgistMetadata {
        SpgistMetadata {
            definition: "spgist (p)".into(),
            shape: "1|1|f|f|1|0|pg_catalog.quad_point_ops|".into(),
            config_proc: 4018,
            choose_proc: 4019,
            picksplit_proc: 4020,
            inner_consistent_proc: 4021,
            leaf_consistent_proc: 4022,
        }
    }

    #[test]
    fn spgist_layout_compares_only_the_opclass_identity_not_the_cache() {
        // A freshly created target index resolves the same pinned core
        // support procedures while its metapage cache differs; only the
        // opclass identity is compared.
        assert!(spgist().has_same_physical_layout(&spgist()));
        // Any one procedure resolving differently means a different opclass
        // implementation must interpret the pages, which must fail.
        let target = SpgistMetadata {
            leaf_consistent_proc: 4022 + 1,
            ..spgist()
        };
        assert!(!spgist().has_same_physical_layout(&target));
        let target = SpgistMetadata {
            definition: "spgist (p kd_point_ops)".into(),
            ..spgist()
        };
        assert!(!spgist().has_same_physical_layout(&target));
    }
}
