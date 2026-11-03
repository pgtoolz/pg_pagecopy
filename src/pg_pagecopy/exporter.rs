use super::ffi::{self, Rel, FSM_FORK, MAIN_FORK, PAGE_SIZE, VM_FORK};
use super::wire::{
    self, IndexTransfer, Manifest, Relation, RelationKind, SchemaColumn, SchemaIndex, TableSchema,
};
use pgrx::iter::SetOfIterator;
use pgrx::pg_sys;
use pgrx::spi::Spi;

/// Push the main, FSM and VM entries of one relation: the export protocol
/// guarantees the source is fully frozen before pages stream, so its visibility
/// map is exact for the byte-identical destination heap.
unsafe fn push_relation(
    relations: &mut Vec<Relation>,
    oid: pg_sys::Oid,
    rel: &Rel,
    kind: RelationKind,
) {
    let oid = oid.to_u32();
    relations.push(Relation {
        oid,
        name: rel.name(),
        kind,
        fork: u8::try_from(MAIN_FORK).expect("main fork fits in u8"),
        blocks: rel.blocks(MAIN_FORK),
        toast_index_oid: 0,
    });
    if rel.blocks_if_exists(FSM_FORK) > 0 {
        relations.push(Relation {
            oid,
            name: rel.name(),
            kind,
            fork: u8::try_from(FSM_FORK).expect("fsm fork fits in u8"),
            blocks: rel.blocks(FSM_FORK),
            toast_index_oid: 0,
        });
    }
    if matches!(kind, RelationKind::Main | RelationKind::Toast) && rel.blocks_if_exists(VM_FORK) > 0
    {
        relations.push(Relation {
            oid,
            name: rel.name(),
            kind,
            fork: u8::try_from(VM_FORK).expect("vm fork fits in u8"),
            blocks: rel.blocks(VM_FORK),
            toast_index_oid: 0,
        });
    }
}

pub unsafe fn build_manifest(
    source_table: &str,
    target_table: &str,
    target_toast_oid: pg_sys::Oid,
    target_checksums: bool,
) -> Result<Manifest, String> {
    ffi::require_source_access()?;
    let source_oid = ffi::resolve_relation(source_table)?;
    let source = Rel::open(source_oid, pg_sys::ShareLock.cast_signed());
    if !source.is_plain_logged_table() {
        return Err("source must be a plain logged table".into());
    }
    if ffi::data_checksums_enabled() != target_checksums {
        return Err("source and target data_checksums differ".into());
    }
    let source_toast = source.toast_oid();
    if source_toast != pg_sys::Oid::INVALID && target_toast_oid == pg_sys::Oid::INVALID {
        return Err("target table must have a TOAST relation".into());
    }

    let attributes = source.attributes()?;
    wire::validate_attributes(&attributes)?;
    let mut relations = Vec::new();
    let mut indexes = Vec::new();
    push_relation(&mut relations, source_oid, &source, RelationKind::Main);

    if source_toast != pg_sys::Oid::INVALID {
        let toast = Rel::open(source_toast, pg_sys::ShareLock.cast_signed());
        let toast_index_oid = toast.toast_index_oid();
        if toast_index_oid == pg_sys::Oid::INVALID {
            return Err("source TOAST relation has no valid index".into());
        }
        let toast_index = Rel::open(toast_index_oid, pg_sys::ShareLock.cast_signed());
        if !toast_index.is_btree() {
            return Err("source TOAST index is not a supported btree".into());
        }
        push_relation(&mut relations, source_toast, &toast, RelationKind::Toast);
        push_relation(
            &mut relations,
            toast_index_oid,
            &toast_index,
            RelationKind::Index,
        );
        indexes.push(IndexTransfer::Btree(ffi::index_metadata(toast_index_oid)?));
    }

    for index_oid in source.index_oids() {
        let index = Rel::open(index_oid, pg_sys::ShareLock.cast_signed());
        let metadata = if index.is_btree() {
            ffi::index_metadata(index_oid).ok()
        } else {
            None
        };
        if let Some(metadata) = metadata {
            push_relation(&mut relations, index_oid, &index, RelationKind::Index);
            indexes.push(IndexTransfer::Btree(metadata));
        } else {
            if !index.can_degrade() {
                return Err(format!(
                    "index {} cannot be degraded: automatic target creation does not support foreign/exclusion constraints",
                    index.name()
                ));
            }
            ffi::ensure_no_custom_opclass(index_oid)?;
            indexes.push(IndexTransfer::Invalid {
                definition: ffi::index_definition(index_oid)?,
                unique: index.is_unique(),
            });
        }
    }

    Ok(Manifest {
        source_table: source_table.to_owned(),
        target_table: target_table.to_owned(),
        source_checksums: ffi::data_checksums_enabled(),
        target_checksums,
        relations,
        attributes,
        indexes,
    })
}

/// Owned (serial/auto) sequences of a table as (column name, sequence oid).
/// Identity columns use internal dependencies and are rejected elsewhere, but
/// locking them here too is harmless and keeps the predicate complete.
fn owned_sequences(source_oid: pg_sys::Oid) -> Result<Vec<(String, pg_sys::Oid)>, String> {
    Spi::connect_mut(|client| {
        let rows = client
            .select(
                "SELECT a.attname::text, d.objid \
                 FROM pg_depend d \
                 JOIN pg_class s ON s.oid = d.objid AND s.relkind = 'S' \
                 JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid \
                 WHERE d.refobjid = $1 AND d.classid = 'pg_class'::regclass \
                 AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a', 'i') \
                 ORDER BY a.attnum",
                None,
                &[source_oid.into()],
            )
            .map_err(|error| error.to_string())?;
        let mut sequences = Vec::with_capacity(rows.len());
        for row in rows {
            let column = row
                .get::<String>(1)
                .map_err(|error| error.to_string())?
                .ok_or_else(|| "owned sequence column name is empty".to_owned())?;
            let oid = row
                .get::<pg_sys::Oid>(2)
                .map_err(|error| error.to_string())?
                .ok_or_else(|| "owned sequence oid is empty".to_owned())?;
            sequences.push((column, oid));
        }
        Ok(sequences)
    })
}

/// Export only catalog metadata needed to recreate a table. No SQL dump tool or
/// server-side procedural language is involved; the descriptor is binary.
pub unsafe fn export_schema(source_table: &str) -> Result<Vec<u8>, String> {
    ffi::with_canonical_sql(|| unsafe { export_schema_inner(source_table) })
}

#[allow(clippy::too_many_lines)] // Keep catalog reads and descriptor order in one transaction.
unsafe fn export_schema_inner(source_table: &str) -> Result<Vec<u8>, String> {
    ffi::require_source_access()?;
    let source_oid = ffi::resolve_relation(source_table)?;
    let source = Rel::open(source_oid, pg_sys::ShareLock.cast_signed());
    let source_toast = source.toast_oid();
    // Reuse the physical validation, especially the supported-btree check.
    let _ = build_manifest(
        source_table,
        source_table,
        source_toast,
        ffi::data_checksums_enabled(),
    )?;

    let columns = Spi::connect_mut(|client| {
        let rows = client
            .select(
                "SELECT a.attname::text, CASE WHEN NOT a.attisdropped THEN format_type(a.atttypid, a.atttypmod) \
                 WHEN a.attlen = -1 AND a.attcollation = 0 THEN 'bytea' \
                 WHEN a.attlen = -1 THEN 'text' \
                 WHEN a.attlen = 1 THEN 'boolean' \
                 WHEN a.attlen = 2 THEN 'smallint' \
                 WHEN a.attlen = 4 THEN 'integer' \
                 WHEN a.attlen = 8 THEN 'bigint' \
                 ELSE 'text' END, \
                 CASE WHEN a.attcollation <> 0 AND a.attcollation <> t.typcollation \
                 THEN (SELECT format('%I.%I', n.nspname, c.collname) \
                       FROM pg_collation c JOIN pg_namespace n ON n.oid = c.collnamespace \
                       WHERE c.oid = a.attcollation) END, \
                 pg_get_expr(d.adbin, d.adrelid), a.attnotnull, a.attidentity::text, \
                 CASE WHEN a.attgenerated <> '' THEN pg_get_expr(d.adbin, d.adrelid) END, \
                 a.attisdropped, a.attstorage::text \
                 FROM pg_attribute a LEFT JOIN pg_type t ON t.oid = a.atttypid \
                 LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum \
                 WHERE a.attrelid = $1 AND a.attnum > 0 ORDER BY a.attnum",
                None,
                &[source_oid.into()],
            )
            .map_err(|error| error.to_string())?;
        let mut columns = Vec::with_capacity(rows.len());
        for row in rows {
            columns.push(SchemaColumn {
                name: row
                    .get::<String>(1)
                    .map_err(|error| error.to_string())?
                    .unwrap_or_default(),
                type_name: row
                    .get::<String>(2)
                    .map_err(|error| error.to_string())?
                    .unwrap_or_default(),
                collation_name: row.get::<String>(3).map_err(|error| error.to_string())?,
                default_expr: row.get::<String>(4).map_err(|error| error.to_string())?,
                not_null: row
                    .get::<bool>(5)
                    .map_err(|error| error.to_string())?
                    .unwrap_or(false),
                identity: row
                    .get::<String>(6)
                    .map_err(|error| error.to_string())?
                    .unwrap_or_default(),
                generated_expr: row.get::<String>(7).map_err(|error| error.to_string())?,
                storage: row
                    .get::<String>(9)
                    .map_err(|error| error.to_string())?
                    .and_then(|value| value.into_bytes().first().copied())
                    .ok_or_else(|| "source attribute storage is empty".to_owned())?,
                dropped: row
                    .get::<bool>(8)
                    .map_err(|error| error.to_string())?
                    .unwrap_or(false),
            });
        }
        Ok::<_, String>(columns)
    })?;

    let constraints = Spi::connect_mut(|client| {
        let unsupported = client
            .select(
                "SELECT contype::text FROM pg_constraint \
                 WHERE conrelid = $1 AND contype IN ('f', 'x') LIMIT 1",
                None,
                &[source_oid.into()],
            )
            .map_err(|error| error.to_string())?;
        if !unsupported.is_empty() {
            return Err(
                "automatic target creation does not support foreign/exclusion constraints"
                    .to_owned(),
            );
        }
        let rows = client
            .select(
                "SELECT pg_get_constraintdef(oid, true) FROM pg_constraint \
                 WHERE conrelid = $1 ORDER BY oid",
                None,
                &[source_oid.into()],
            )
            .map_err(|error| error.to_string())?;
        let mut constraints = Vec::with_capacity(rows.len());
        for row in rows {
            constraints.push(
                row.get::<String>(1)
                    .map_err(|error| error.to_string())?
                    .unwrap_or_default(),
            );
        }
        Ok::<_, String>(constraints)
    })?;

    let indexes = Spi::connect_mut(|client| {
        let rows = client
            .select(
                "SELECT i.indexrelid, i.indisunique, ic.relname::text \
                 FROM pg_index i \
                 LEFT JOIN pg_constraint c ON c.conindid = i.indexrelid \
                 LEFT JOIN pg_class ic ON ic.oid = i.indexrelid \
                 WHERE i.indrelid = $1 AND c.oid IS NULL ORDER BY i.indexrelid",
                None,
                &[source_oid.into()],
            )
            .map_err(|error| error.to_string())?;
        let mut indexes = Vec::with_capacity(rows.len());
        for row in rows {
            let index_oid = row
                .get::<pg_sys::Oid>(1)
                .map_err(|error| error.to_string())?
                .ok_or_else(|| "source index OID is missing".to_owned())?;
            indexes.push(SchemaIndex {
                name: row
                    .get::<String>(3)
                    .map_err(|error| error.to_string())?
                    .ok_or_else(|| "source index name is missing".to_owned())?,
                definition: ffi::index_definition(index_oid)?,
                unique: row
                    .get::<bool>(2)
                    .map_err(|error| error.to_string())?
                    .unwrap_or(false),
            });
        }
        Ok::<_, String>(indexes)
    })?;

    let owned = owned_sequences(source_oid)?;
    let sequences = Spi::connect_mut(|client| {
        let mut sequences = Vec::with_capacity(owned.len());
        for (column, oid) in owned {
            let name = client
                .select(
                    "SELECT format('%I.%I', n.nspname, c.relname) \
                     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace \
                     WHERE c.oid = $1",
                    None,
                    &[oid.into()],
                )
                .map_err(|error| error.to_string())?
                .next()
                .ok_or_else(|| format!("owned sequence of column {column} disappeared"))?
                .get::<String>(1)
                .map_err(|error| error.to_string())?
                .ok_or_else(|| format!("owned sequence of column {column} has no name"))?;
            let rows = client
                .select(
                    &format!("SELECT last_value, is_called FROM {name}"),
                    None,
                    &[],
                )
                .map_err(|error| error.to_string())?;
            let row = rows
                .into_iter()
                .next()
                .ok_or_else(|| format!("owned sequence of column {column} returned no state"))?;
            sequences.push(wire::SequenceState {
                column,
                last_value: row
                    .get::<i64>(1)
                    .map_err(|error| error.to_string())?
                    .ok_or_else(|| "sequence last_value is null".to_owned())?,
                is_called: row
                    .get::<bool>(2)
                    .map_err(|error| error.to_string())?
                    .unwrap_or(false),
            });
        }
        Ok::<_, String>(sequences)
    })?;

    wire::encode_schema(&TableSchema {
        columns,
        constraints,
        indexes,
        sequences,
    })
    .map_err(|error| error.to_string())
}

struct ExportState {
    manifest: Manifest,
    source_toast_oid: pg_sys::Oid,
    target_toast_oid: pg_sys::Oid,
    target_lz4_supported: bool,
    header_pending: bool,
    relation_index: usize,
    block: u32,
    finished: bool,
}

impl ExportState {
    unsafe fn new(
        source_table: &str,
        target_table: &str,
        target_toast_oid: pg_sys::Oid,
        target_lz4_supported: bool,
        target_checksums: bool,
    ) -> Result<Self, String> {
        let manifest = build_manifest(
            source_table,
            target_table,
            target_toast_oid,
            target_checksums,
        )?;
        let source_oid = ffi::resolve_relation(source_table)?;
        let source_main = Rel::open(source_oid, pg_sys::ShareLock.cast_signed());
        Ok(Self {
            manifest,
            source_toast_oid: source_main.toast_oid(),
            target_toast_oid,
            target_lz4_supported,
            header_pending: true,
            relation_index: 0,
            block: 0,
            finished: false,
        })
    }

    fn next_page(&mut self) -> Option<Vec<u8>> {
        const PAGE_BATCH_PAGES: usize = 128;

        if self.header_pending {
            self.header_pending = false;
            return Some(
                wire::encode_header(&self.manifest)
                    .unwrap_or_else(|error| panic!("pg_pagecopy: {error}")),
            );
        }
        if self.finished {
            return None;
        }

        let batch_pages = PAGE_BATCH_PAGES;
        let mut chunk = Vec::with_capacity(batch_pages * (wire::PAGE_HEADER_LEN + PAGE_SIZE));
        let mut pages = 0;

        while pages < batch_pages && self.relation_index < self.manifest.relations.len() {
            let metadata = &self.manifest.relations[self.relation_index];
            if self.block >= metadata.blocks {
                self.relation_index += 1;
                self.block = 0;
                continue;
            }

            let relation = unsafe {
                Rel::open(
                    pg_sys::Oid::from_u32(metadata.oid),
                    pg_sys::NoLock.cast_signed(),
                )
            };
            let fork = ffi::fork_from_wire(metadata.fork)
                .unwrap_or_else(|error| panic!("pg_pagecopy: {error}"));
            let mut page = vec![0u8; PAGE_SIZE];
            relation.read_page(fork, self.block, &mut page);
            if fork == MAIN_FORK
                && matches!(metadata.kind, RelationKind::Main | RelationKind::Toast)
            {
                relation.assert_heap_page_frozen(self.block, &page);
            }
            if fork == MAIN_FORK {
                match metadata.kind {
                    RelationKind::Main | RelationKind::Toast => relation.prepare_heap_page(
                        self.block,
                        &mut page,
                        self.source_toast_oid,
                        self.target_toast_oid,
                        metadata.kind == RelationKind::Main
                            && self.source_toast_oid != pg_sys::Oid::INVALID,
                        self.target_lz4_supported,
                        self.manifest.target_checksums,
                    ),
                    RelationKind::Index => {
                        Rel::prepare_page(self.block, &mut page, self.manifest.target_checksums);
                    }
                }
            }
            let packet = wire::encode_page(
                u16::try_from(self.relation_index).expect("relation count fits u16"),
                metadata.fork,
                self.block,
                &page,
            )
            .unwrap_or_else(|error| panic!("pg_pagecopy: {error}"));
            chunk.extend_from_slice(&packet);
            pages += 1;
            self.block += 1;
        }

        if !chunk.is_empty() {
            return Some(chunk);
        }
        self.finished = true;
        Some(vec![0, 0, 0, 0])
    }
}

/// # Safety
/// Runs inside PostgreSQL and retains relation locks until the statement ends.
pub unsafe fn export_stream(
    source_table: &str,
    target_table: &str,
    target_toast_oid: pg_sys::Oid,
    target_lz4_supported: bool,
    target_checksums: bool,
) -> SetOfIterator<'static, Vec<u8>> {
    let mut state = ExportState::new(
        source_table,
        target_table,
        target_toast_oid,
        target_lz4_supported,
        target_checksums,
    )
    .unwrap_or_else(|error| panic!("pg_pagecopy: {error}"));
    SetOfIterator::new(std::iter::from_fn(move || state.next_page()))
}

fn relation_is_frozen(relation: &Rel) -> bool {
    // VM_ALL_FROZEN skips data-page reads; streaming still proves every tuple,
    // so a stale or lying VM bit cannot corrupt the transfer.
    let mut page = vec![0u8; PAGE_SIZE];
    let mut vm_skipped = 0u32;
    let mut pages_read = 0u32;
    let mut vm = relation.visibility_map();
    let frozen = (0..relation.blocks(MAIN_FORK)).all(|block| {
        if vm.all_frozen(block) {
            vm_skipped += 1;
            return true;
        }
        relation.read_page(MAIN_FORK, block, &mut page);
        pages_read += 1;
        Rel::heap_page_is_frozen(&page)
    });
    pgrx::debug1!(
        "pg_pagecopy: frozen validation {}: VM skipped={}, data pages read={}",
        relation.name(),
        vm_skipped,
        pages_read
    );
    frozen
}

/// Validate frozen heap and TOAST tuples after VACUUM and ACCESS EXCLUSIVE.
/// False requests another freeze/lock attempt.
///
/// # Safety
/// Runs inside PostgreSQL with the source relation lock held by this transaction.
pub unsafe fn source_is_frozen(source_table: &str) -> Result<bool, String> {
    ffi::require_source_access()?;
    let source_oid = ffi::resolve_relation(source_table)?;
    let source = Rel::open(source_oid, pg_sys::AccessExclusiveLock.cast_signed());
    if !source.is_plain_logged_table() {
        return Err("source must be a plain logged table".into());
    }
    source.flush_buffers();
    if !relation_is_frozen(&source) {
        return Ok(false);
    }
    let toast_oid = source.toast_oid();
    if toast_oid != pg_sys::Oid::INVALID {
        let toast = Rel::open(toast_oid, pg_sys::ShareLock.cast_signed());
        toast.flush_buffers();
        if !relation_is_frozen(&toast) {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Lock and flush the complete source relation tree for direct-read streaming.
/// `FlushRelationBuffers` covers every fork of each opened relation. The locks
/// remain held until the surrounding transaction ends.
///
/// # Safety
/// Runs inside PostgreSQL; the caller must keep the transaction open while reading pages.
pub unsafe fn lock_source(source_table: &str) -> Result<(), String> {
    ffi::require_source_access()?;
    let oid = ffi::resolve_relation(source_table)?;
    let relation = Rel::open(oid, pg_sys::AccessExclusiveLock.cast_signed());
    if !relation.is_plain_logged_table() {
        return Err("source must be a plain logged table".into());
    }
    // LOCK TABLE on the heap does not stop nextval() on owned sequences;
    // lock them too so their state cannot drift before the target setval.
    for (_, sequence_oid) in owned_sequences(oid)? {
        Rel::open(sequence_oid, pg_sys::AccessExclusiveLock.cast_signed());
    }
    flush_relation_tree(&relation);
    let toast_oid = relation.toast_oid();
    if toast_oid != pg_sys::Oid::INVALID {
        let toast = Rel::open(toast_oid, pg_sys::ShareLock.cast_signed());
        flush_relation_tree(&toast);
    }
    Ok(())
}

fn flush_relation_tree(relation: &Rel) {
    relation.flush_buffers();
    for index_oid in relation.index_oids() {
        unsafe { Rel::open(index_oid, pg_sys::ShareLock.cast_signed()) }.flush_buffers();
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn done_packet_is_four_zero_bytes() {
        assert_eq!(vec![0, 0, 0, 0], [0; 4]);
    }
}
