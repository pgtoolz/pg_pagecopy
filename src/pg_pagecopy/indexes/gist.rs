//! `GiST` access-method specifics of index transfer: physical metadata read
//! from the source catalog and root page, the exact opclass/type pairs that
//! transfer as page images, physical-layout compatibility between source and
//! target, and verification of transferred roots. The C half lives in
//! `src/index_gist.c`; its FFI declarations stay here so the access method
//! owns its C surface. Only `indexes` dispatches here, so the transfer paths
//! stay access-method agnostic.

use super::super::ffi::{self, Rel};
use pgrx::pg_sys;
use pgrx::spi::Spi;
use std::os::raw::c_char;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GistMetadata {
    pub definition: String,
    pub shape: String,
    /// `procnum:functionoid` pairs of the indexed opclasses' support
    /// procedures; the target must resolve every source function to the
    /// same OID, because those functions produced the on-page keys.
    pub procs: String,
}

fn proc_pairs(procs: &str) -> Vec<&str> {
    procs.split(['|', ',']).collect()
}

impl GistMetadata {
    /// `self` is the source and `other` the target: the target must resolve
    /// every source support procedure to the same function OID. A newer
    /// major may add procedures (`GiST` sortsupport arrived in 17); extra
    /// target procedures never interpret transferred pages.
    pub fn has_same_physical_layout(&self, other: &Self) -> bool {
        self.definition == other.definition
            && self.shape == other.shape
            && proc_pairs(&self.procs)
                .iter()
                .all(|pair| proc_pairs(&other.procs).contains(pair))
    }
}

unsafe extern "C" {
    fn pc_gist_check_root(rel: pg_sys::Relation);
    fn pc_verify_gist_root(page: *mut c_char, blocks: u32) -> bool;
}

/// Exact core opclass and indexed-type pairs that transfer as page images.
/// `point_ops` on `point` is the one core `GiST` opclass whose page keys are
/// the fixed 16-byte `point` and its `box` unions, produced by the same
/// functions on every supported major. Every other `GiST` index (the other
/// core opclasses whose key encodings were never audited across majors,
/// expressions, partials) stays on the degraded definition-only path;
/// custom opclasses, including contrib extension ones like `btree_gist`,
/// remain a hard error.
const APPROVED_GIST: [(&str, pg_sys::Oid); 1] = [("point_ops", pg_sys::POINTOID)];

/// Reject `GiST` indexes whose key is not one plain column of the approved
/// exact core opclass/type pairs. The indexed type is compared by its
/// built-in OID, so binary-compatible user types and custom opclasses named
/// like core ones never pass. Expression and partial indexes degrade because
/// their catalog shape proves neither the key expression's semantics nor
/// the predicate's on the target.
fn ensure_approved_gist(index_oid: pg_sys::Oid) -> Result<(), String> {
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
                "gist expression or partial indexes are not transferred".into(),
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
                && APPROVED_GIST
                    .iter()
                    .any(|(name, approved_type)| *name == opcname && typoid == *approved_type);
            if !approved {
                return Ok::<_, String>(Err(format!(
                    "gist opclass {opcnamespace}.{opcname} on {typname} is not the core point_ops on point"
                )));
            }
            keys += 1;
        }
        if keys != key_count || key_count != 1 || total_count != 1 {
            return Ok::<_, String>(Err(
                "gist expression or partial indexes are not transferred".into(),
            ));
        }
        Ok(Ok(()))
    })?
}

/// `GiST` support procedures of the indexed opclasses, keyed by proc number
/// and function OID: the functions whose output is the on-page key format.
fn gist_procs(index_oid: pg_sys::Oid) -> Result<String, String> {
    Spi::get_one_with_args::<String>(
        "SELECT coalesce(string_agg( \
            (SELECT coalesce(string_agg(a.amprocnum::text || ':' || a.amproc::oid::text, ',' \
                                       ORDER BY a.amprocnum), '') \
             FROM pg_amproc a WHERE a.amprocfamily = o.opcfamily), '|' \
            ORDER BY u.ord), '') \
         FROM pg_index i, \
              unnest(i.indclass) WITH ORDINALITY AS u(opcoid, ord) \
         JOIN pg_opclass o ON o.oid = u.opcoid \
         WHERE i.indexrelid = $1",
        &[index_oid.into()],
    )
    .map_err(|error| error.to_string())?
    .ok_or_else(|| "index opclass metadata is missing".to_owned())
}

/// Catalog-only checks so `pagecopy.check` reports the same verdicts as the
/// physical transfer without reading index pages.
pub(super) fn catalog_preflight(index_oid: pg_sys::Oid) -> Result<(), String> {
    ffi::index_catalog_metadata(index_oid).map(|_| ())?;
    ensure_approved_gist(index_oid)?;
    gist_procs(index_oid).map(|_| ())
}

/// Full physical metadata of one source gist index: catalog identity, the
/// support-procedure identity and the root page, read under a share lock.
/// `GiST` has no metapage, so the root is the only page checked here.
///
/// # Safety
/// Opens the index under `ShareLock` until the statement ends.
pub(super) fn metadata(oid: pg_sys::Oid) -> Result<GistMetadata, String> {
    let (definition, shape) = ffi::index_catalog_metadata(oid)?;
    ensure_approved_gist(oid)?;
    let procs = gist_procs(oid)?;
    let rel = unsafe { Rel::open(oid, pg_sys::ShareLock.cast_signed()) };
    unsafe { ffi::guard(|| pc_gist_check_root(rel.raw())) };
    Ok(GistMetadata {
        definition,
        shape,
        procs,
    })
}

/// Whether an open target index is a gist with the source physical layout.
pub(super) fn matches_layout(expected: &GistMetadata, index: &Rel) -> bool {
    index.is_gist()
        && metadata(index.oid()).is_ok_and(|actual| expected.has_same_physical_layout(&actual))
}

/// Verify the root (block 0) of a transferred gist index against the
/// manifest: the root invariants (page id, special size, known flags, no
/// deletion, no incomplete split, no rightlink), the incoming main-fork
/// block count and the NSN stamp every transferred page carries.
pub(super) fn verify_metapage(page: &mut [u8], blocks: u32) -> bool {
    assert_eq!(page.len(), ffi::PAGE_SIZE);
    unsafe { ffi::guard(|| pc_verify_gist_root(page.as_mut_ptr().cast(), blocks)) }
}

// The layout rule guards AM compatibility; see the BRIN/btree equivalents.
#[cfg(test)]
mod tests {
    use super::GistMetadata;

    fn gist() -> GistMetadata {
        GistMetadata {
            definition: "gist (loc)".into(),
            shape: "1|1|f|f|1|0|pg_catalog.point_ops|".into(),
            procs: "1:3295,2:3290,3:3285,5:3292,6:3288,7:3291,8:3298,9:3299".into(),
        }
    }

    #[test]
    fn gist_layout_requires_the_target_to_resolve_every_source_procedure() {
        // PostgreSQL 17 added GiST sortsupport to point_ops; a newer target
        // resolving every older function still reads the pages correctly.
        let target = GistMetadata {
            procs: "1:3295,2:3290,3:3285,5:3292,6:3288,7:3291,8:3298,9:3299,11:9551".into(),
            ..gist()
        };
        assert!(gist().has_same_physical_layout(&target));
        // A target missing one source procedure, or resolving the same
        // proc number to a different function, cannot interpret the keys.
        let target = GistMetadata {
            procs: "1:3295,2:3290,3:3285,5:3292,6:3288,7:3291,8:3298".into(),
            ..gist()
        };
        assert!(!gist().has_same_physical_layout(&target));
        let target = GistMetadata {
            procs: "1:3295,2:3290,3:9999,5:3292,6:3288,7:3291,8:3298,9:3299".into(),
            ..gist()
        };
        assert!(!gist().has_same_physical_layout(&target));
    }

    #[test]
    fn gist_layout_keeps_comparing_catalog_identity() {
        let target = GistMetadata {
            definition: "gist (other)".into(),
            ..gist()
        };
        assert!(!gist().has_same_physical_layout(&target));
        let target = GistMetadata {
            shape: "1|1|f|f|1|0|pg_catalog.box_ops|".into(),
            ..gist()
        };
        assert!(!gist().has_same_physical_layout(&target));
    }
}
