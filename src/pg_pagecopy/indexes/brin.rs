//! BRIN access-method specifics of index transfer: physical metadata read
//! from the source catalog and metapage, the exact opclass/type pairs that
//! transfer as page images, physical-layout compatibility between source and
//! target, and verification of transferred metapages. The C half lives in
//! `src/index_brin.c`; its FFI declarations stay here so the access method
//! owns its C surface. Only `indexes` dispatches here, so the transfer paths
//! stay access-method agnostic.

use super::super::ffi::{self, Rel};
use pgrx::pg_sys;
use pgrx::spi::Spi;
use std::os::raw::c_char;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BrinMetadata {
    pub definition: String,
    pub shape: String,
    pub brin_version: u32,
    pub pages_per_range: u32,
    pub last_revmap_page: u32,
}

impl BrinMetadata {
    pub fn has_same_physical_layout(&self, other: &Self) -> bool {
        // last_revmap_page belongs to the source geometry; a freshly created
        // target index is empty there and receives the source revmap with
        // its pages.
        self.definition == other.definition
            && self.shape == other.shape
            && self.brin_version == other.brin_version
            && self.pages_per_range == other.pages_per_range
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct RawBrinMetadata {
    version: u32,
    pages_per_range: u32,
    last_revmap_page: u32,
}

unsafe extern "C" {
    fn pc_verify_brin_metapage(
        page: *mut c_char,
        version: u32,
        pages_per_range: u32,
        last_revmap_page: u32,
        blocks: u32,
    ) -> bool;
    fn pc_brin_metadata(rel: pg_sys::Relation, metadata: *mut RawBrinMetadata);
}

/// Exact core opclass and indexed-type pairs that transfer as page images:
/// ordinary fixed-width minmax summaries with no compression, TOAST,
/// collation or embedded-type-OID dependence, available on every supported
/// major. Every other BRIN index (varlena summaries, inclusion, bloom,
/// minmax-multi, binary-compatible or custom types) stays on the degraded
/// definition-only path.
const APPROVED_MINMAX: [(&str, pg_sys::Oid); 6] = [
    ("int2_minmax_ops", pg_sys::INT2OID),
    ("int4_minmax_ops", pg_sys::INT4OID),
    ("int8_minmax_ops", pg_sys::INT8OID),
    ("date_minmax_ops", pg_sys::DATEOID),
    ("timestamp_minmax_ops", pg_sys::TIMESTAMPOID),
    ("timestamptz_minmax_ops", pg_sys::TIMESTAMPTZOID),
];

/// Reject BRIN indexes whose keys are not plain columns of the approved
/// exact core opclass/type pairs; the indexed type is compared by its
/// built-in OID so binary-compatible user types and custom opclasses named
/// like core ones never pass. Expression and partial indexes degrade because
/// their catalog shape proves neither the summary type nor the predicate
/// semantics on the target.
fn ensure_approved_minmax(index_oid: pg_sys::Oid) -> Result<(), String> {
    Spi::connect(|client| {
        let flags = client
            .select(
                "SELECT i.indnkeyatts, \
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
        let not_plain_column = flags
            .get::<bool>(2)
            .map_err(|error| error.to_string())?
            .unwrap_or(true);
        let has_expressions_or_predicate = flags
            .get::<bool>(3)
            .map_err(|error| error.to_string())?
            .unwrap_or(true);
        if not_plain_column || has_expressions_or_predicate {
            return Ok::<_, String>(Err(
                "brin expression or partial indexes are not transferred".into(),
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
                && APPROVED_MINMAX
                    .iter()
                    .any(|(name, approved_type)| *name == opcname && typoid == *approved_type);
            if !approved {
                return Ok::<_, String>(Err(format!(
                    "brin opclass {opcnamespace}.{opcname} on {typname} is not one of the core int2/int4/int8/date/timestamp/timestamptz minmax pairs"
                )));
            }
            keys += 1;
        }
        if keys != key_count {
            return Ok::<_, String>(Err(
                "brin expression or partial indexes are not transferred".into(),
            ));
        }
        Ok(Ok(()))
    })?
}

/// Catalog-only checks so `pagecopy.check` reports the same verdicts as the
/// physical transfer without reading index pages.
pub(super) fn catalog_preflight(index_oid: pg_sys::Oid) -> Result<(), String> {
    ffi::index_catalog_metadata(index_oid).map(|_| ())?;
    ensure_approved_minmax(index_oid)
}

/// Full physical metadata of one source brin index: catalog identity plus
/// the metapage geometry, read under a share lock.
///
/// # Safety
/// Opens the index under `ShareLock` until the statement ends.
pub(super) fn metadata(oid: pg_sys::Oid) -> Result<BrinMetadata, String> {
    let (definition, shape) = ffi::index_catalog_metadata(oid)?;
    ensure_approved_minmax(oid)?;
    let rel = unsafe { Rel::open(oid, pg_sys::ShareLock.cast_signed()) };
    let mut raw = RawBrinMetadata::default();
    unsafe { ffi::guard(|| pc_brin_metadata(rel.raw(), &raw mut raw)) };
    Ok(BrinMetadata {
        definition,
        shape,
        brin_version: raw.version,
        pages_per_range: raw.pages_per_range,
        last_revmap_page: raw.last_revmap_page,
    })
}

/// Whether an open target index is a brin with the source physical layout.
pub(super) fn matches_layout(expected: &BrinMetadata, index: &Rel) -> bool {
    index.is_brin()
        && metadata(index.oid()).is_ok_and(|actual| actual.has_same_physical_layout(expected))
}

/// Verify the metapage (block 0) of a transferred brin index against the
/// manifest: exact format and geometry, with the source revmap bounds
/// checked against the incoming main-fork block count.
pub(super) fn verify_metapage(page: &mut [u8], expected: &BrinMetadata, blocks: u32) -> bool {
    assert_eq!(page.len(), ffi::PAGE_SIZE);
    unsafe {
        ffi::guard(|| {
            pc_verify_brin_metapage(
                page.as_mut_ptr().cast(),
                expected.brin_version,
                expected.pages_per_range,
                expected.last_revmap_page,
                blocks,
            )
        })
    }
}

// The layout rule moved here from the wire tests; it guards AM compatibility.
#[cfg(test)]
mod tests {
    use super::BrinMetadata;

    fn brin() -> BrinMetadata {
        BrinMetadata {
            definition: "brin (id) WITH (pages_per_range=4)".into(),
            shape: "1|1|f|f|1|0|pg_catalog.int4_minmax_ops|".into(),
            brin_version: 1,
            pages_per_range: 4,
            last_revmap_page: 1,
        }
    }

    #[test]
    fn brin_layout_allows_a_fresh_targets_revmap_extent() {
        // An empty freshly created target index has last_revmap_page = 0;
        // it receives the source geometry with the copied pages.
        let mut target = BrinMetadata {
            last_revmap_page: 0,
            ..brin()
        };
        assert!(brin().has_same_physical_layout(&target));
        // Everything else is part of the physical interpretation.
        target.pages_per_range = 128;
        assert!(!brin().has_same_physical_layout(&target));
        let target = BrinMetadata {
            brin_version: 2,
            ..brin()
        };
        assert!(!brin().has_same_physical_layout(&target));
    }
}
