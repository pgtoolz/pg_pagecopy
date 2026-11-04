//! GIN access-method specifics of index transfer: physical metadata read
//! from the source catalog and metapage, the exact opclass/type pairs that
//! transfer as page images, physical-layout compatibility between source and
//! target, and verification of transferred metapages. The C half lives in
//! `src/index_gin.c`; its FFI declarations stay here so the access method
//! owns its C surface. Only `indexes` dispatches here, so the transfer paths
//! stay access-method agnostic.

use super::super::ffi::{self, Rel};
use pgrx::pg_sys;
use pgrx::spi::Spi;
use std::os::raw::c_char;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GinMetadata {
    pub definition: String,
    pub shape: String,
    pub gin_version: u32,
}

impl GinMetadata {
    pub fn has_same_physical_layout(&self, other: &Self) -> bool {
        // The metapage's pending-list pointers and planner statistics are
        // mutable state of the source index; they transfer with the pages,
        // so a freshly created empty target legitimately differs.
        self.definition == other.definition
            && self.shape == other.shape
            && self.gin_version == other.gin_version
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct RawGinMetadata {
    version: u32,
}

unsafe extern "C" {
    fn pc_verify_gin_metapage(page: *mut c_char, version: u32, blocks: u32) -> bool;
    fn pc_gin_metadata(rel: pg_sys::Relation, metadata: *mut RawGinMetadata);
}

/// Exact core opclass and indexed-type pairs that transfer as page images.
/// `array_ops` on `int[]` stores each element as a pass-by-value int4 key
/// whose comparator resolves identically from the catalog on every major,
/// and `jsonb_ops` on `jsonb` stores text keys that `gin_compare_jsonb`
/// compares under the C collation regardless of cluster locale; both key
/// builders are unchanged from PG13 through PG18. Every other GIN index
/// (`tsvector`, trigram, `jsonb_path_ops`, other element types, arrays of
/// collatable types, expressions, partials) stays on the degraded
/// definition-only path; custom opclasses remain a hard error.
const APPROVED_GIN: [(&str, pg_sys::Oid); 2] = [
    ("array_ops", pg_sys::INT4ARRAYOID),
    ("jsonb_ops", pg_sys::JSONBOID),
];

/// Reject GIN indexes whose key is not one plain column of the approved
/// exact core opclass/type pairs. The indexed type is compared by its
/// built-in OID, so binary-compatible user types and custom opclasses named
/// like core ones never pass. Expression, partial and multicolumn indexes
/// degrade because their catalog shape proves neither the extracted keys'
/// semantics nor the predicate's on the target.
fn ensure_approved_gin(index_oid: pg_sys::Oid) -> Result<(), String> {
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
                "gin expression or partial indexes are not transferred".into()
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
                && APPROVED_GIN
                    .iter()
                    .any(|(name, approved_type)| *name == opcname && typoid == *approved_type);
            if !approved {
                return Ok::<_, String>(Err(format!(
                    "gin opclass {opcnamespace}.{opcname} on {typname} is not one of the core array_ops/jsonb_ops pairs"
                )));
            }
            keys += 1;
        }
        if keys != key_count || key_count != 1 || total_count != 1 {
            return Ok::<_, String>(Err("gin multicolumn indexes are not transferred".into()));
        }
        Ok(Ok(()))
    })?
}

/// Catalog-only checks so `pagecopy.check` reports the same verdicts as the
/// physical transfer without reading index pages.
pub(super) fn catalog_preflight(index_oid: pg_sys::Oid) -> Result<(), String> {
    ffi::index_catalog_metadata(index_oid).map(|_| ())?;
    ensure_approved_gin(index_oid)
}

/// Full physical metadata of one source gin index: catalog identity plus
/// the metapage format, read under a share lock. A nonempty pending list
/// (fastupdate state) is walked there, so the transfer copies it fully.
///
/// # Safety
/// Opens the index under `ShareLock` until the statement ends.
pub(super) fn metadata(oid: pg_sys::Oid) -> Result<GinMetadata, String> {
    let (definition, shape) = ffi::index_catalog_metadata(oid)?;
    ensure_approved_gin(oid)?;
    let rel = unsafe { Rel::open(oid, pg_sys::ShareLock.cast_signed()) };
    let mut raw = RawGinMetadata::default();
    unsafe { ffi::guard(|| pc_gin_metadata(rel.raw(), &raw mut raw)) };
    Ok(GinMetadata {
        definition,
        shape,
        gin_version: raw.version,
    })
}

/// Whether an open target index is a gin with the source physical layout.
pub(super) fn matches_layout(expected: &GinMetadata, index: &Rel) -> bool {
    index.is_gin()
        && metadata(index.oid()).is_ok_and(|actual| actual.has_same_physical_layout(expected))
}

/// Verify the metapage (block 0) of a transferred gin index against the
/// manifest: exact format identity and a coherent pending-list geometry
/// checked against the incoming main-fork block count. Mutable source
/// geometry is validated, never compared with a fresh target's.
pub(super) fn verify_metapage(page: &mut [u8], expected: &GinMetadata, blocks: u32) -> bool {
    assert_eq!(page.len(), ffi::PAGE_SIZE);
    unsafe {
        ffi::guard(|| {
            pc_verify_gin_metapage(page.as_mut_ptr().cast(), expected.gin_version, blocks)
        })
    }
}

// The layout rule guards AM compatibility; see the BRIN/btree equivalents.
#[cfg(test)]
mod tests {
    use super::GinMetadata;

    fn gin() -> GinMetadata {
        GinMetadata {
            definition: "gin (tags)".into(),
            shape: "1|1|f|f|1|0|pg_catalog.array_ops|".into(),
            gin_version: 2,
        }
    }

    #[test]
    fn gin_layout_compares_only_format_identity_not_geometry() {
        // A freshly created target index carries the same definition, shape
        // and format version, while its empty metapage has no pending list
        // and different planner statistics; none of those are compared.
        let target = GinMetadata {
            definition: "gin (tags)".into(),
            shape: "1|1|f|f|1|0|pg_catalog.array_ops|".into(),
            gin_version: 2,
        };
        assert!(gin().has_same_physical_layout(&target));
        // A different opclass changes the stored keys' semantics, and a
        // foreign format version cannot be interpreted; both must fail.
        let target = GinMetadata {
            shape: "1|1|f|f|1|0|pg_catalog.tsvector_ops|".into(),
            ..gin()
        };
        assert!(!gin().has_same_physical_layout(&target));
        let target = GinMetadata {
            gin_version: 1,
            ..gin()
        };
        assert!(!gin().has_same_physical_layout(&target));
    }
}
