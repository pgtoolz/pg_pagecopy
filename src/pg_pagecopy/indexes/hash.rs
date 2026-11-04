//! HASH access-method specifics of index transfer: physical metadata read
//! from the source catalog and metapage, the exact opclass/type pairs that
//! transfer as page images, physical-layout compatibility between source and
//! target, and verification of transferred metapages. The C half lives in
//! `src/index_hash.c`; its FFI declarations stay here so the access method
//! owns its C surface. Only `indexes` dispatches here, so the transfer paths
//! stay access-method agnostic.

use super::super::ffi::{self, Rel};
use pgrx::pg_sys;
use pgrx::spi::Spi;
use std::os::raw::c_char;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HashMetadata {
    pub definition: String,
    pub shape: String,
    pub hash_version: u32,
    /// The metapage's forensic `hashm_procid`, checked against the catalog
    /// on the source and required to match the target cluster's resolution.
    pub hash_proc: u32,
}

impl HashMetadata {
    pub fn has_same_physical_layout(&self, other: &Self) -> bool {
        // ffactor, ntuples, maxbucket, masks, spares and mapp are mutable
        // control state of the source geometry; they transfer with the
        // pages, so a freshly created empty target legitimately differs.
        self.definition == other.definition
            && self.shape == other.shape
            && self.hash_version == other.hash_version
            && self.hash_proc == other.hash_proc
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct RawHashMetadata {
    version: u32,
    hash_proc: u32,
}

unsafe extern "C" {
    fn pc_verify_hash_metapage(
        page: *mut c_char,
        version: u32,
        hash_proc: u32,
        blocks: u32,
    ) -> bool;
    fn pc_hash_metadata(rel: pg_sys::Relation, metadata: *mut RawHashMetadata);
}

/// Exact core opclass and indexed-type pairs that transfer as page images.
/// The stored hash is a plain uint32 of the value, and the core int2/int4
/// and int8 hash functions are identical on every supported major, so their
/// buckets resolve the same on the target. Every other HASH index (other
/// core opclasses whose hash functions were never audited across majors,
/// arrays, expressions, partials) stays on the degraded definition-only
/// path; custom opclasses remain a hard error.
const APPROVED_HASH: [(&str, pg_sys::Oid); 3] = [
    ("int2_ops", pg_sys::INT2OID),
    ("int4_ops", pg_sys::INT4OID),
    ("int8_ops", pg_sys::INT8OID),
];

/// Reject HASH indexes whose key is not one plain column of the approved
/// exact core opclass/type pairs. The indexed type is compared by its
/// built-in OID, so binary-compatible user types and custom opclasses named
/// like core ones never pass. Expression and partial indexes degrade because
/// their catalog shape proves neither the hashed expression's semantics nor
/// the predicate's on the target.
fn ensure_approved_hash(index_oid: pg_sys::Oid) -> Result<(), String> {
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
                "hash expression or partial indexes are not transferred".into(),
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
                && APPROVED_HASH
                    .iter()
                    .any(|(name, approved_type)| *name == opcname && typoid == *approved_type);
            if !approved {
                return Ok::<_, String>(Err(format!(
                    "hash opclass {opcnamespace}.{opcname} on {typname} is not one of the core int2/int4/int8 pairs"
                )));
            }
            keys += 1;
        }
        if keys != key_count || key_count != 1 || total_count != 1 {
            return Ok::<_, String>(Err(
                "hash expression or partial indexes are not transferred".into(),
            ));
        }
        Ok(Ok(()))
    })?
}

/// Catalog-only checks so `pagecopy.check` reports the same verdicts as the
/// physical transfer without reading index pages.
pub(super) fn catalog_preflight(index_oid: pg_sys::Oid) -> Result<(), String> {
    ffi::index_catalog_metadata(index_oid).map(|_| ())?;
    ensure_approved_hash(index_oid)
}

/// Full physical metadata of one source hash index: catalog identity plus
/// the metapage format and hash support procedure, read under a share lock.
///
/// # Safety
/// Opens the index under `ShareLock` until the statement ends.
pub(super) fn metadata(oid: pg_sys::Oid) -> Result<HashMetadata, String> {
    let (definition, shape) = ffi::index_catalog_metadata(oid)?;
    ensure_approved_hash(oid)?;
    let rel = unsafe { Rel::open(oid, pg_sys::ShareLock.cast_signed()) };
    let mut raw = RawHashMetadata::default();
    unsafe { ffi::guard(|| pc_hash_metadata(rel.raw(), &raw mut raw)) };
    Ok(HashMetadata {
        definition,
        shape,
        hash_version: raw.version,
        hash_proc: raw.hash_proc,
    })
}

/// Whether an open target index is a hash with the source physical layout.
pub(super) fn matches_layout(expected: &HashMetadata, index: &Rel) -> bool {
    index.is_hash()
        && metadata(index.oid()).is_ok_and(|actual| actual.has_same_physical_layout(expected))
}

/// Verify the metapage (block 0) of a transferred hash index against the
/// manifest: exact format identity, coherent allocation geometry checked
/// against the incoming main-fork block count, and the approved hash
/// procedure. Mutable source geometry is validated, never compared with a
/// fresh target's.
pub(super) fn verify_metapage(page: &mut [u8], expected: &HashMetadata, blocks: u32) -> bool {
    assert_eq!(page.len(), ffi::PAGE_SIZE);
    unsafe {
        ffi::guard(|| {
            pc_verify_hash_metapage(
                page.as_mut_ptr().cast(),
                expected.hash_version,
                expected.hash_proc,
                blocks,
            )
        })
    }
}

// The layout rule guards AM compatibility; see the BRIN/btree equivalents.
#[cfg(test)]
mod tests {
    use super::HashMetadata;

    fn hash() -> HashMetadata {
        HashMetadata {
            definition: "hash (id)".into(),
            shape: "1|1|f|f|1|0|pg_catalog.int4_ops|".into(),
            hash_version: 4,
            hash_proc: 451,
        }
    }

    #[test]
    fn hash_layout_compares_only_format_identity_not_geometry() {
        // A freshly created target index carries the same definition, shape,
        // format version and hash procedure, while its empty metapage differs
        // in every mutable geometry field; none of those are compared here.
        let target = HashMetadata {
            definition: "hash (id)".into(),
            shape: "1|1|f|f|1|0|pg_catalog.int4_ops|".into(),
            hash_version: 4,
            hash_proc: 451,
        };
        assert!(hash().has_same_physical_layout(&target));
        // A different opclass resolves a different hash procedure, and a
        // foreign format version cannot be interpreted; both must fail.
        let target = HashMetadata {
            hash_proc: 449,
            ..hash()
        };
        assert!(!hash().has_same_physical_layout(&target));
        let target = HashMetadata {
            hash_version: 3,
            ..hash()
        };
        assert!(!hash().has_same_physical_layout(&target));
    }
}
