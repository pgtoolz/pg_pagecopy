use super::ffi::{self, Rel, MAIN_FORK};
use super::indexes;
use super::source_client::SourceClient;
use super::wire::{self, Manifest, RelationKind, TableSchema};
use pgrx::pg_sys;
use pgrx::prelude::*;
use pgrx::spi::Spi;
use std::io::Cursor;

struct ImportState {
    manifest: Manifest,
    targets: Vec<Rel>,
    routes: Vec<(usize, pg_sys::ForkNumber::Type)>,
    next_blocks: Vec<u32>,
    done: bool,
}

fn quote_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn quote_ident(value: &str) -> String {
    format!("\"{}\"", value.replace('\"', "\"\""))
}

fn conninfo_option(option: &str) -> Result<String, String> {
    if option.contains('\0') {
        return Err("foreign server option contains NUL".into());
    }
    let (key, value) = option
        .split_once('=')
        .ok_or_else(|| "invalid foreign server option; expected key=value".to_owned())?;
    if key.is_empty() || !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return Err(format!("invalid libpq option name: {key}"));
    }
    let escaped = value.replace('\\', "\\\\").replace('\'', "\\'");
    Ok(format!("{key}='{escaped}'"))
}

fn foreign_server_conninfo(server_name: &str) -> Result<String, String> {
    let user_oid = unsafe { pg_sys::GetUserId() };
    let options = Spi::connect(|client| {
        let table = client.select(
            "SELECT s.srvoptions, m.umoptions \
             FROM pg_catalog.pg_foreign_server AS s \
             JOIN pg_catalog.pg_user_mappings AS m ON m.srvid = s.oid \
             WHERE s.srvname::pg_catalog.text = $1 AND m.umuser = $2 \
               AND pg_catalog.has_server_privilege(s.oid, 'USAGE')",
            Some(1),
            &[server_name.into(), user_oid.into()],
        )?;
        if table.is_empty() {
            return Ok(None);
        }
        let (server_options, user_options) = table.first().get_two::<Vec<String>, Vec<String>>()?;
        Ok(Some(
            server_options
                .unwrap_or_default()
                .into_iter()
                .chain(user_options.unwrap_or_default())
                .collect::<Vec<_>>(),
        ))
    })
    .map_err(|error: pgrx::spi::Error| error.to_string())?
    .ok_or_else(|| {
        format!(
            "foreign server {server_name} does not exist, lacks USAGE, or has no current-user mapping"
        )
    })?;
    options
        .iter()
        .map(|option| conninfo_option(option))
        .collect::<Result<Vec<_>, _>>()
        .map(|options| options.join(" "))
}

fn quote_qualified_relation(value: &str) -> Result<(String, Vec<String>), String> {
    let parts =
        Spi::get_one_with_args::<Vec<String>>("SELECT pg_catalog.parse_ident($1)", &[value.into()])
            .map_err(|error| error.to_string())?
            .ok_or_else(|| "target table name is empty".to_owned())?;
    if parts.is_empty() || parts.len() > 2 {
        return Err("target table must be an optionally schema-qualified name".into());
    }
    let quoted = parts
        .iter()
        .map(|part| quote_ident(part))
        .collect::<Vec<_>>()
        .join(".");
    Ok((quoted, parts))
}

fn qualify_target(target_table: &str) -> Result<String, String> {
    let (quoted, parts) = quote_qualified_relation(target_table)?;
    if parts.len() == 2 {
        return Ok(quoted);
    }
    let existing = Spi::get_one_with_args::<String>(
        "SELECT (SELECT pg_catalog.format('%I.%I', n.nspname, c.relname) \
         FROM pg_catalog.pg_class c \
         JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace \
         WHERE c.oid = pg_catalog.to_regclass($1))",
        &[target_table.into()],
    )
    .map_err(|error| error.to_string())?;
    if let Some(existing) = existing {
        return Ok(existing);
    }
    let schema = Spi::get_one::<String>("SELECT current_schema()::text")
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "target has no current schema".to_owned())?;
    Ok(format!("{}.{quoted}", quote_ident(&schema)))
}

fn create_target(schema: &TableSchema, target_table: &str) -> Result<(), String> {
    ffi::with_canonical_sql(|| create_target_inner(schema, target_table))
}

#[allow(clippy::too_many_lines)] // One CREATE sequence; no hidden helper state.
fn create_target_inner(schema: &TableSchema, target_table: &str) -> Result<(), String> {
    if !schema.sequences.is_empty() {
        return Err(
            "automatic target creation does not support serial/nextval defaults; create target first"
                .into(),
        );
    }
    let (target_name, parts) = quote_qualified_relation(target_table)?;
    let namespace = if parts.len() == 2 {
        parts[0].clone()
    } else {
        Spi::get_one::<String>("SELECT current_schema()::text")
            .map_err(|error| error.to_string())?
            .ok_or_else(|| "target has no current schema".to_owned())?
    };
    if parts.len() == 2 {
        Spi::run(&format!(
            "CREATE SCHEMA IF NOT EXISTS {}",
            quote_ident(&parts[0])
        ))
        .map_err(|error| error.to_string())?;
    }

    let mut definitions = Vec::new();
    for column in &schema.columns {
        if !column.identity.is_empty() {
            return Err(
                "automatic target creation does not support identity columns; create target first"
                    .into(),
            );
        }
        let mut definition = format!("{} {}", quote_ident(&column.name), column.type_name);
        if let Some(collation) = &column.collation_name {
            definition.push_str(" COLLATE ");
            definition.push_str(collation);
        }
        if let Some(expression) = &column.generated_expr {
            definition.push_str(" GENERATED ALWAYS AS (");
            definition.push_str(expression);
            definition.push_str(") STORED");
        } else if let Some(expression) = &column.default_expr {
            definition.push_str(" DEFAULT ");
            definition.push_str(expression);
        }
        if column.not_null {
            definition.push_str(" NOT NULL");
        }
        definitions.push(definition);
    }
    definitions.extend(schema.constraints.iter().cloned());
    Spi::run(&format!(
        "CREATE TABLE {target_name} ({})",
        definitions.join(", ")
    ))
    .map_err(|error| error.to_string())?;

    for column in &schema.columns {
        let storage = match column.storage {
            b'p' => "PLAIN",
            b'e' => "EXTERNAL",
            b'm' => "MAIN",
            b'x' => "EXTENDED",
            other => return Err(format!("unsupported attribute storage code {other}")),
        };
        Spi::run(&format!(
            "ALTER TABLE {target_name} ALTER COLUMN {} SET STORAGE {storage}",
            quote_ident(&column.name)
        ))
        .map_err(|error| error.to_string())?;
    }

    // Recreate dropped attribute numbers as well: heap pages retain their physical layout.
    for column in schema.columns.iter().filter(|column| column.dropped) {
        Spi::run(&format!(
            "ALTER TABLE {target_name} DROP COLUMN {}",
            quote_ident(&column.name)
        ))
        .map_err(|error| error.to_string())?;
    }
    for index in &schema.indexes {
        // A same-schema clone necessarily collides with the source index's
        // own name; keep the source name only when the target namespace has
        // it free and otherwise let PostgreSQL generate a collision-free
        // target-local name (including duplicate-definition suffixes).
        let name_free = Spi::get_one_with_args::<bool>(
            "SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class AS c \
             JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace \
             WHERE n.nspname = $1 AND c.relname = $2)",
            &[namespace.clone().into(), index.name.clone().into()],
        )
        .map_err(|error| error.to_string())?
        .unwrap_or(false);
        let index_name = if name_free {
            format!("{} ", quote_ident(&index.name))
        } else {
            String::new()
        };
        Spi::run(&format!(
            "CREATE {}INDEX {index_name}ON {target_name} USING {}",
            if index.unique { "UNIQUE " } else { "" },
            index.definition
        ))
        .map_err(|error| error.to_string())?;
    }
    Ok(())
}

#[allow(clippy::too_many_lines)] // Keep catalog matching and physical routing in one transaction.
fn prepare_state(
    manifest: Manifest,
    target_table: &str,
    target_main: Rel,
    target_toast: Option<Rel>,
    mut target_indexes: Vec<(String, Rel)>,
    target_toast_index: Option<Rel>,
) -> Result<ImportState, String> {
    if manifest.target_table != target_table {
        return Err("source manifest names a different target table".into());
    }
    if manifest.source_checksums != manifest.target_checksums {
        return Err("transfers between different checksum modes are not supported".into());
    }
    if manifest.target_checksums != ffi::data_checksums_enabled() {
        return Err("manifest checksum setting differs from target".into());
    }
    wire::validate_attributes(&manifest.attributes)?;
    let target_attributes = target_main.attributes()?;
    if manifest.attributes != target_attributes {
        return Err(format!(
            "source and target table attributes differ: source={:?}, target={:?}",
            manifest.attributes, target_attributes
        ));
    }

    let source_has_toast = manifest
        .relations
        .iter()
        .any(|relation| relation.kind == RelationKind::Toast);
    if source_has_toast != target_toast.is_some()
        || source_has_toast != target_toast_index.is_some()
    {
        return Err("source and target TOAST layout differs".into());
    }
    let user_index_start = usize::from(source_has_toast);
    if manifest.indexes.len() != target_indexes.len() + user_index_start {
        return Err("source and target index counts differ".into());
    }

    if source_has_toast {
        let target = target_toast_index
            .as_ref()
            .ok_or_else(|| "missing target TOAST index".to_owned())?;
        indexes::verify_toast_layout(&manifest.indexes[0], target)?;
    }

    let mut targets = Vec::with_capacity(manifest.relations.len());
    targets.push(target_main);
    if source_has_toast {
        targets.push(target_toast.ok_or_else(|| "missing target TOAST relation".to_owned())?);
        targets.push(target_toast_index.ok_or_else(|| "missing target TOAST index".to_owned())?);
    }
    targets.extend(indexes::match_user_indexes(
        &manifest.indexes[user_index_start..],
        &mut target_indexes,
    )?);

    for target in &targets {
        target.reset_storage();
    }
    let mut routes = Vec::with_capacity(manifest.relations.len());
    let mut main_count = 0usize;
    let mut owner: Option<usize> = None;
    for relation in &manifest.relations {
        let fork = ffi::fork_from_wire(relation.fork)?;
        if fork == MAIN_FORK {
            if main_count >= targets.len() {
                return Err("manifest main relations exceed target relations".into());
            }
            if targets[main_count].blocks(MAIN_FORK) != 0 {
                return Err(format!(
                    "target relation {} is not empty",
                    targets[main_count].name()
                ));
            }
            routes.push((main_count, MAIN_FORK));
            owner = Some(main_count);
            main_count += 1;
        } else {
            let owner =
                owner.ok_or_else(|| "fork entry before its relation main entry".to_string())?;
            routes.push((owner, fork));
        }
    }
    if main_count != targets.len() {
        return Err("manifest relation count does not match target".into());
    }
    let next_blocks = vec![0; manifest.relations.len()];
    Ok(ImportState {
        manifest,
        targets,
        routes,
        next_blocks,
        done: false,
    })
}

impl ImportState {
    /// Zero-based stream ordinal of the index main fork ending at
    /// `relation_index`, shared by metapage verification and test hooks.
    fn index_ordinal(&self, relation_index: usize, fork: u8) -> Option<usize> {
        self.manifest.relations[..=relation_index]
            .iter()
            .filter(|relation| relation.kind == RelationKind::Index && relation.fork == fork)
            .count()
            .checked_sub(1)
    }

    /// Validate and install one decoded page packet.
    #[allow(clippy::too_many_lines)] // The debug hooks sit beside the checks they target.
    fn accept(&mut self, mut packet: wire::PagePacket) -> Result<(), String> {
        let relation_index = usize::from(packet.relation);
        if relation_index >= self.routes.len() {
            return Err(format!("invalid relation index {}", packet.relation));
        }
        let metadata = &self.manifest.relations[relation_index];
        if packet.fork != metadata.fork {
            return Err(format!(
                "fork mismatch for relation {}: expected {}, got {}",
                relation_index, metadata.fork, packet.fork
            ));
        }
        let (target_index, fork) = self.routes[relation_index];
        if packet.block != self.next_blocks[relation_index] {
            return Err(format!(
                "out-of-order block {} for relation {}",
                packet.block, relation_index
            ));
        }
        if packet.block >= metadata.blocks {
            return Err("page exceeds manifest relation length".into());
        }
        // Debug-only corruption hook for the BDD suite: flips one byte of a
        // chosen main-fork block to exercise page verification end to end.
        #[cfg(feature = "test-hooks")]
        if relation_index
            == usize::try_from(crate::DEBUG_CORRUPT_PAGE_RELATION.get()).unwrap_or(usize::MAX)
        {
            let block = crate::DEBUG_CORRUPT_PAGE.get();
            let offset = crate::DEBUG_CORRUPT_OFFSET.get();
            if block >= 0
                && offset >= 0
                && packet.block == u32::try_from(block).expect("nonnegative block fits u32")
                && usize::try_from(offset).is_ok_and(|offset| offset < packet.bytes.len())
            {
                packet.bytes[usize::try_from(offset).expect("nonnegative offset fits usize")] ^=
                    0xFF;
            }
        }
        // Only main-fork pages get full layout verification; VM and FSM
        // pages arrive pre-stamped by the exporter (LSN reset, checksum).
        if fork == MAIN_FORK
            && !Rel::verify_page(
                packet.block,
                &mut packet.bytes,
                self.manifest.target_checksums,
            )
        {
            return Err(format!(
                "page verification failed for block {} of relation {}",
                packet.block, relation_index
            ));
        }
        if fork == MAIN_FORK && metadata.kind == RelationKind::Index && packet.block == 0 {
            let ordinal = self
                .index_ordinal(relation_index, metadata.fork)
                .ok_or_else(|| "index metadata ordinal underflow".to_owned())?;
            // Debug-only corruption hook for the BDD suite: flip one byte of
            // an incoming index metapage to exercise its validator end to
            // end; restricted to one physical index ordinal when configured.
            #[cfg(feature = "test-hooks")]
            if usize::try_from(crate::DEBUG_CORRUPT_INDEX_METAPAGE.get())
                .is_ok_and(|offset| offset < packet.bytes.len())
                && (crate::DEBUG_CORRUPT_INDEX_ORDINAL.get() < 0
                    || i32::try_from(ordinal)
                        .is_ok_and(|ordinal| ordinal == crate::DEBUG_CORRUPT_INDEX_ORDINAL.get()))
            {
                packet.bytes[usize::try_from(crate::DEBUG_CORRUPT_INDEX_METAPAGE.get())
                    .expect("nonnegative offset fits usize")] ^= 0xFF;
            }
            let entry = indexes::physical_index(&self.manifest.indexes, ordinal)
                .ok_or_else(|| "missing index metadata in manifest".to_owned())?;
            if !indexes::verify_index_metapage(entry, &mut packet.bytes, metadata.blocks) {
                return Err(format!(
                    "index metapage verification failed for relation {relation_index}"
                ));
            }
        }
        // Debug-only BDD hook: drop one incoming index page without
        // installing it or advancing the expected block, so the next packet
        // exercises the out-of-order rejection and a short stream the
        // stream-ended-early rejection.
        #[cfg(feature = "test-hooks")]
        if fork == MAIN_FORK
            && metadata.kind == RelationKind::Index
            && relation_index
                == usize::try_from(crate::DEBUG_DROP_INDEX_PAGE_RELATION.get())
                    .unwrap_or(usize::MAX)
            && packet.block
                == u32::try_from(crate::DEBUG_DROP_INDEX_PAGE_BLOCK.get()).unwrap_or(u32::MAX)
        {
            return Ok(());
        }
        self.targets[target_index].write_page(fork, packet.block, &packet.bytes);
        self.next_blocks[relation_index] += 1;
        // Debug-only BDD milestone: park the import immediately after this
        // index page is installed, so the suite can cancel from a
        // deterministic post-index phase instead of a timer. Publishing the
        // marker through pg_stat_activity makes the park observable from
        // another session; the loop exits when the cancel lands and the next
        // source read raises the query-cancel error. The 30-second bound
        // only fails visibly if no cancellation is ever delivered.
        #[cfg(feature = "test-hooks")]
        if fork == MAIN_FORK
            && metadata.kind == RelationKind::Index
            && crate::DEBUG_HOLD_INDEX_PAGE_BLOCK.get() >= 0
            && packet.block
                == u32::try_from(crate::DEBUG_HOLD_INDEX_PAGE_BLOCK.get()).unwrap_or(u32::MAX)
            && self
                .index_ordinal(relation_index, metadata.fork)
                .and_then(|ordinal| indexes::physical_index(&self.manifest.indexes, ordinal))
                .is_some_and(|entry| {
                    matches!(
                        entry,
                        indexes::IndexTransfer::Brin(_) | indexes::IndexTransfer::Hash(_)
                    )
                })
        {
            let _ = Spi::get_one_with_args::<String>(
                "SELECT set_config('application_name', 'pg_pagecopy index hold', false)",
                &["pg_pagecopy index hold".into()],
            );
            for _ in 0..3000 {
                let cancel_pending = unsafe {
                    std::ptr::read_volatile(std::ptr::addr_of!(pg_sys::QueryCancelPending))
                };
                if cancel_pending != 0 {
                    break;
                }
                unsafe { pg_sys::pg_usleep(10_000) };
            }
        }
        Ok(())
    }

    /// Complete the stream: WAL or sync every installed relation fork.
    fn finish(&mut self, generate_wal: bool) -> Result<(), String> {
        for (index, relation) in self.manifest.relations.iter().enumerate() {
            if self.next_blocks[index] != relation.blocks {
                return Err(format!(
                    "stream ended early for {}: block {} of {}",
                    relation.name, self.next_blocks[index], relation.blocks
                ));
            }
        }
        for (target_index, fork) in &self.routes {
            if generate_wal {
                self.targets[*target_index].log_relation(*fork);
            } else {
                self.targets[*target_index].sync_relation(*fork);
            }
        }
        self.done = true;
        Ok(())
    }
}

/// Relations of a prepared target, opened under ACCESS EXCLUSIVE.
struct TargetRelations {
    main: Rel,
    toast: Option<Rel>,
    toast_index: Option<Rel>,
    indexes: Vec<(String, Rel)>,
}

/// Resolve or create the target table, then open all its relations. The
/// schema descriptor is only needed when the target has to be created.
///
/// # Safety
/// Opens relations under ACCESS EXCLUSIVE; callers keep the handles in the
/// same transaction until commit.
unsafe fn open_target(schema: &TableSchema, target_table: &str) -> Result<TargetRelations, String> {
    let target_table = qualify_target(target_table)?;
    let target_oid = if let Ok(oid) = ffi::resolve_relation(&target_table) {
        oid
    } else {
        create_target(schema, &target_table)?;
        ffi::resolve_relation(&target_table)?
    };
    let main = Rel::open(target_oid, pg_sys::AccessExclusiveLock.cast_signed());
    // Ownership may have changed while waiting for ACCESS EXCLUSIVE.
    ffi::require_target_owner(target_oid)?;
    if let Some((_type_name, reason)) = main.plain_logged_reason() {
        return Err(format!("target: {reason}"));
    }
    let unsupported_constraints = Spi::get_one_with_args::<bool>(
        "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint \
         WHERE contype = 'f' AND (conrelid = $1 OR confrelid = $1))",
        &[target_oid.into()],
    )
    .map_err(|error| error.to_string())?
    .unwrap_or(false);
    if unsupported_constraints {
        return Err("target table participates in foreign key constraints".into());
    }
    let toast_oid = main.toast_oid();
    let toast = if toast_oid == pg_sys::Oid::INVALID {
        None
    } else {
        Some(Rel::open(
            toast_oid,
            pg_sys::AccessExclusiveLock.cast_signed(),
        ))
    };
    let toast_index = if let Some(ref toast) = toast {
        let oid = toast.toast_index_oid();
        if oid == pg_sys::Oid::INVALID {
            return Err("target TOAST relation has no valid index".into());
        }
        let index = Rel::open(oid, pg_sys::AccessExclusiveLock.cast_signed());
        if !index.is_btree() {
            return Err("target TOAST index is not a supported btree".into());
        }
        Some(index)
    } else {
        None
    };
    // Any target index may stay INVALID for a later REINDEX; only the TOAST
    // index checked above must transfer physically.
    let mut indexes = Vec::new();
    for oid in main.index_oids() {
        let index = Rel::open(oid, pg_sys::AccessExclusiveLock.cast_signed());
        indexes.push((ffi::index_definition(oid)?, index));
    }
    Ok(TargetRelations {
        main,
        toast,
        toast_index,
        indexes,
    })
}

/// # Safety
/// Runs inside PostgreSQL. All target relations remain exclusively locked until commit.
/// Human-readable transfer progress for `pg_stat_activity`; fits the 63-byte
/// `application_name` limit with room for a 24-char table name.
fn progress_label(done: u64, total: u64, table: &str) -> String {
    let short = if table.chars().count() > 24 {
        table.chars().take(24).collect::<String>()
    } else {
        table.to_owned()
    };
    let pct = if done >= total {
        100
    } else {
        done * 100 / total
    };
    format!(
        "pg_pagecopy {} {}/{}MB {}%",
        short,
        done / 128,
        total / 128,
        pct
    )
}

fn report_progress(done: u64, total: u64, table: &str) {
    let label = progress_label(done, total, table);
    // Progress must never fail the import.
    let _ = Spi::get_one_with_args::<String>(
        "SELECT set_config('application_name', $1, false)",
        &[label.clone().into()],
    );
    notice!("{}", label);
}

/// Replays the source's owned-sequence state on the target before the source
/// lock is released. Targets without a serial default have nothing to advance.
fn advance_sequences(schema: &TableSchema, target_table: &str) -> Result<(), String> {
    for sequence in &schema.sequences {
        let target_sequence = Spi::get_one_with_args::<String>(
            "SELECT pg_get_serial_sequence($1, $2)",
            &[target_table.into(), sequence.column.as_str().into()],
        )
        .map_err(|error| error.to_string())?;
        let Some(target_sequence) = target_sequence else {
            // Distinguish a column without a sequence from one fed by a
            // sequence the column does not own: pg_get_serial_sequence
            // returns NULL for both, but only the latter needs the state.
            let default = Spi::get_one_with_args::<String>(
                "SELECT (SELECT pg_get_expr(adbin, adrelid) \
                 FROM pg_attrdef ad \
                 JOIN pg_attribute a ON a.attrelid = ad.adrelid AND a.attnum = ad.adnum \
                 WHERE ad.adrelid = $1::regclass AND a.attname = $2)",
                &[target_table.into(), sequence.column.as_str().into()],
            )
            .map_err(|error| error.to_string())?;
            if default.as_deref().is_some_and(|d| d.contains("nextval(")) {
                return Err(format!(
                    "target column {} uses nextval() on a sequence the column does not own; \
                     transfer its state manually or use ALTER SEQUENCE ... OWNED BY",
                    sequence.column
                ));
            }
            continue;
        };
        Spi::get_one_with_args::<i64>(
            "SELECT setval($1::regclass, $2, $3)",
            &[
                target_sequence.into(),
                sequence.last_value.into(),
                sequence.is_called.into(),
            ],
        )
        .map_err(|error| error.to_string())?;
    }
    Ok(())
}

#[allow(clippy::too_many_lines)] // One streaming transaction; no hidden background work.
pub unsafe fn import(
    source_conninfo: &str,
    source_table: &str,
    target_table: &str,
    generate_wal: bool,
    local: bool,
) -> Result<(), String> {
    let target_for_sequences = qualify_target(target_table)?;
    if let Ok(target_oid) = ffi::resolve_relation(&target_for_sequences) {
        ffi::require_target_owner(target_oid)?;
    }
    let mut source = SourceClient::connect(source_conninfo)?;
    source.check_compatibility()?;
    if local {
        source.prepare_direct_local(source_table)?;
    } else {
        source.prepare_direct(source_table)?;
    }
    let schema = source.schema(source_table)?;
    let targets = open_target(&schema, &target_for_sequences)
        .map_err(|error| format!("open target relations: {error}"))?;
    let target_toast_oid = targets.main.toast_oid();
    let mut target_main = Some(targets.main);
    let mut target_toast = targets.toast;
    let mut target_toast_index = targets.toast_index;
    let mut target_indexes = targets.indexes;

    let target_checksums = ffi::data_checksums_enabled();
    #[cfg(feature = "test-hooks")]
    let debug_disable_lz4 = crate::DEBUG_DISABLE_LZ4.get();
    #[cfg(not(feature = "test-hooks"))]
    let debug_disable_lz4 = false;
    let target_lz4_supported = ffi::lz4_supported() && !debug_disable_lz4;
    let command =
        format!(
        "COPY (SELECT pagecopy_internal.pagecopy_export_stream({}, {}, {}::oid, {}, {}, {})) TO STDOUT (FORMAT binary)",
        quote_literal(source_table),
        quote_literal(target_table),
        target_toast_oid.to_u32(),
        if target_lz4_supported { "true" } else { "false" },
        if target_checksums { "true" } else { "false" },
        if local { "true" } else { "false" },
    );
    let mut state: Option<ImportState> = None;
    let orig_application_name = Spi::get_one_with_args::<String>(
        "SELECT current_setting($1)",
        &["application_name".into()],
    )
    .map_err(|error| error.to_string())?;
    let mut pages_done: u64 = 0;
    let mut pages_total: u64 = 0;

    source.copy_out(&command, |row| {
        if state.as_ref().is_some_and(|state| state.done) {
            return Err("received a row after the stream terminator".into());
        }
        if state.is_none() {
            let reader = wire::StreamReader::new(Cursor::new(row))
                .map_err(|error| format!("invalid pg_pagecopy header: {error}"))?;
            let manifest = reader.manifest;
            pages_total = manifest
                .relations
                .iter()
                .map(|r| u64::from(r.blocks))
                .sum::<u64>();
            let main = target_main
                .take()
                .ok_or_else(|| "target table was already consumed".to_owned())?;
            let next = prepare_state(
                manifest,
                target_table,
                main,
                target_toast.take(),
                std::mem::take(&mut target_indexes),
                target_toast_index.take(),
            )?;
            state = Some(next);
            return Ok(());
        }

        let import = state.as_mut().unwrap();
        let packets = wire::decode_pages(row).map_err(|error| error.to_string())?;
        match packets {
            Some(packets) => {
                for packet in packets {
                    let packet = packet.map_err(|error| error.to_string())?;
                    pages_done += 1;
                    let cadence = u64::try_from(crate::PROGRESS_PAGES.get()).unwrap_or(0);
                    if cadence > 0 && pages_total > 0 && pages_done.is_multiple_of(cadence) {
                        report_progress(pages_done, pages_total, source_table);
                    }
                    import.accept(packet)?;
                }
                Ok(())
            }
            None => import.finish(generate_wal),
        }
    })?;

    let state = state.ok_or_else(|| "source returned no pg_pagecopy header".to_owned())?;
    if !state.done {
        return Err("source COPY ended without pg_pagecopy terminator".into());
    }
    advance_sequences(&schema, &target_for_sequences)
        .map_err(|error| format!("advance target sequences: {error}"))?;
    if local {
        apply_freeze_horizons(&state.manifest, &target_for_sequences, target_toast_oid)?;
    }
    source.commit()?;
    // On error the whole transaction (and the name change) rolls back; on
    // success the session must keep whatever application_name it had.
    Spi::get_one_with_args::<String>(
        "SELECT set_config('application_name', $1, false)",
        &[orig_application_name.into()],
    )
    .map_err(|error| format!("restore target application_name: {error}"))?;
    Ok(())
}

/// A local (same-cluster) transfer keeps original xids, so the new relation
/// must inherit the source freeze horizons: `pg_class.relfrozenxid` newer than
/// a copied xid would let vacuum skip freezing it and wraparound could then
/// truncate its CLOG slot while the tuple is still unfrozen.
fn apply_freeze_horizons(
    manifest: &Manifest,
    target_table: &str,
    target_toast_oid: pg_sys::Oid,
) -> Result<(), String> {
    let target_oid = ffi::resolve_relation(target_table)?;
    let mut targets = vec![(target_oid, manifest.source_horizons)];
    if let Some(toast_horizons) = manifest.toast_horizons {
        if target_toast_oid != pg_sys::Oid::INVALID {
            targets.push((target_toast_oid, toast_horizons));
        }
    }
    for (oid, horizons) in targets {
        Spi::get_one_with_args::<i64>(
            "UPDATE pg_class SET relfrozenxid = $1::text::xid, relminmxid = $2::text::xid \
             WHERE oid = $3::text::oid RETURNING 1",
            &[
                horizons.relfrozenxid.to_string().into(),
                horizons.relminmxid.to_string().into(),
                oid.to_u32().to_string().into(),
            ],
        )
        .map_err(|error| format!("set target freeze horizons: {error}"))?;
    }
    Ok(())
}

/// Import using connection and credential options from a foreign server.
///
/// # Safety
/// Uses the same physical import transaction as `import`.
pub unsafe fn import_server(
    server_name: &str,
    source_table: &str,
    target_table: &str,
    generate_wal: bool,
) -> Result<(), String> {
    let conninfo = foreign_server_conninfo(server_name)?;
    import(&conninfo, source_table, target_table, generate_wal, false)
}

/// Clone a table inside the current database with no client transport.
/// Reuses the network import against this backend's own postmaster: the
/// self connection runs the lock/flush and streams the pages, this backend
/// only installs them. Building source metadata here instead would deadlock
/// against the self connection's ACCESS EXCLUSIVE lock on the source.
/// Inside one cluster original xids stay valid, so there is no VACUUM FREEZE
/// here: the target inherits the source freeze horizons instead.
///
/// # Safety
/// Runs inside PostgreSQL.
pub unsafe fn import_local(
    source_table: &str,
    target_table: &str,
    generate_wal: bool,
) -> Result<(), String> {
    ffi::require_source_access()?;
    let source_oid = ffi::resolve_relation(source_table)?;
    if ffi::resolve_relation(target_table) == Ok(source_oid) {
        return Err("target table must differ from the source table".into());
    }
    pgrx::log!("pg_pagecopy: local clone {source_table} -> {target_table}");
    import(
        &ffi::self_conninfo()?,
        source_table,
        target_table,
        generate_wal,
        true,
    )
}

#[cfg(test)]
mod progress_tests {
    use super::{conninfo_option, progress_label};

    #[test]
    fn conninfo_options_are_escaped() {
        assert_eq!(
            conninfo_option("password=p'a\\ss=word").unwrap(),
            r"password='p\'a\\ss=word'"
        );
        assert_eq!(
            conninfo_option("application_name=two words").unwrap(),
            "application_name='two words'"
        );
        assert_eq!(conninfo_option("password=").unwrap(), "password=''");
        assert!(conninfo_option("password").is_err());
        assert!(conninfo_option("bad key=value").is_err());
        assert!(conninfo_option("password=bad\0secret").is_err());
    }

    #[test]
    fn label_fits_application_name_limit() {
        let cases = [
            (0u64, 1u64, "public.events"),
            (128, 256, "public.events"),
            (1_000_000, 4_000_000, "public.imported_events"),
            (
                128 * 1024,
                0,
                "public.a_very_long_table_name_beyond_twenty_four_chars",
            ),
        ];
        for (done, total, table) in cases {
            let label = progress_label(done, total, table);
            assert!(label.len() <= 63, "{label} is {} bytes", label.len());
            assert!(label.starts_with("pg_pagecopy "), "{label}");
        }
    }

    #[test]
    fn label_counts_and_percent() {
        assert_eq!(
            progress_label(128, 256, "public.events"),
            "pg_pagecopy public.events 1/2MB 50%"
        );
        assert_eq!(
            progress_label(128 * 1024, 0, "public.events"),
            "pg_pagecopy public.events 1024/0MB 100%"
        );
    }
}
