use pgrx::prelude::*;

pgrx::pg_module_magic!();

use pgrx::guc::{GucContext, GucFlags, GucRegistry, GucSetting};

/// Debug-only corruption hook for the BDD suite: flips one byte of the chosen
/// heap block before page verification. Negative values disable the hook.
#[cfg(feature = "test-hooks")]
static DEBUG_CORRUPT_PAGE: GucSetting<i32> = GucSetting::<i32>::new(-1);
#[cfg(feature = "test-hooks")]
static DEBUG_CORRUPT_OFFSET: GucSetting<i32> = GucSetting::<i32>::new(-1);
#[cfg(feature = "test-hooks")]
static DEBUG_DISABLE_LZ4: GucSetting<bool> = GucSetting::<bool>::new(false);
/// Progress cadence in pages: 0 disables both `NOTICE`s and `application_name`
/// updates.
static PROGRESS_PAGES: GucSetting<i32> = GucSetting::<i32>::new(1024);

#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    #[cfg(feature = "test-hooks")]
    {
        GucRegistry::define_int_guc(
            c"pagecopy.debug_corrupt_page",
            c"Heap block to corrupt during import (debug)",
            c"Flips one byte of this heap relation block before page verification. -1 disables.",
            &DEBUG_CORRUPT_PAGE,
            -1,
            i32::MAX,
            GucContext::Suset,
            GucFlags::default(),
        );
        GucRegistry::define_int_guc(
            c"pagecopy.debug_corrupt_offset",
            c"Byte offset to corrupt during import (debug)",
            c"Flips the byte at this offset of the block chosen by pagecopy.debug_corrupt_page.",
            &DEBUG_CORRUPT_OFFSET,
            -1,
            8191,
            GucContext::Suset,
            GucFlags::default(),
        );
        GucRegistry::define_bool_guc(
            c"pagecopy.debug_disable_lz4",
            c"Simulate a target without lz4 support (debug)",
            c"Rejects lz4-compressed values during this transfer.",
            &DEBUG_DISABLE_LZ4,
            GucContext::Suset,
            GucFlags::default(),
        );
    }
    GucRegistry::define_int_guc(
        c"pagecopy.progress_pages",
        c"Import progress cadence in pages (0 disables)",
        c"Every N pages the import raises a NOTICE and updates application_name \
         with the transfer progress; 0 disables both.",
        &PROGRESS_PAGES,
        0,
        i32::MAX,
        GucContext::Userset,
        GucFlags::default(),
    );
}

#[pg_schema]
mod pagecopy_internal {}

pub mod pg_pagecopy {
    use super::{default, name, pg_extern, pg_sys, SetOfIterator, TableIterator};
    use pgrx::spi::Spi;

    mod exporter;
    mod ffi;
    mod importer;
    mod source_client;
    mod wire;

    /// Return physical and extension compatibility metadata for this server.
    ///
    /// # Panics
    /// Panics if the database encoding or installed extension version cannot be read.
    #[must_use]
    #[pg_extern]
    #[allow(clippy::type_complexity)] // Keep pgrx SQL column names beside their Rust types.
    pub fn server_info() -> TableIterator<
        'static,
        (
            name!(server_version_num, i32),
            name!(catversion, i32),
            name!(block_size, i32),
            name!(max_align, i32),
            name!(endianness, &'static str),
            name!(server_encoding, String),
            name!(data_checksums, bool),
            name!(extension_version, String),
            name!(max_toast_chunk_size, i32),
            name!(max_identifier_length, i32),
            name!(checksum_algorithm_version, i32),
            name!(lz4_supported, bool),
        ),
    > {
        let server_encoding = Spi::connect(|client| {
            client
                .select("SELECT current_setting('server_encoding')", Some(1), &[])?
                .first()
                .get_one::<String>()
        })
        .unwrap_or_else(|error| panic!("pg_pagecopy: cannot read server encoding: {error}"))
        .unwrap_or_else(|| panic!("pg_pagecopy: server encoding is NULL"));
        let extension_version =
            Spi::connect(|client| {
                client.select(
                "SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_pagecopy'",
                Some(1),
                &[],
            )?.first().get_one::<String>()
            })
            .unwrap_or_else(|error| panic!("pg_pagecopy: cannot read extension version: {error}"))
            .unwrap_or_else(|| panic!("pg_pagecopy: extension version is missing"));
        let endianness = if cfg!(target_endian = "little") {
            "little"
        } else {
            "big"
        };

        TableIterator::new(std::iter::once((
            i32::try_from(pg_sys::PG_VERSION_NUM).expect("server version fits i32"),
            i32::try_from(pg_sys::CATALOG_VERSION_NO).expect("catalog version fits i32"),
            i32::try_from(pg_sys::BLCKSZ).expect("block size fits i32"),
            i32::try_from(pg_sys::MAXIMUM_ALIGNOF).expect("alignment fits i32"),
            endianness,
            server_encoding,
            unsafe { pg_sys::DataChecksumsEnabled() },
            extension_version,
            ffi::max_toast_chunk_size(),
            ffi::max_identifier_length(),
            ffi::checksum_algorithm_version(),
            ffi::lz4_supported(),
        )))
    }

    /// Export one table as a value-per-call COPY bytea stream. Cross-cluster
    /// transfers require frozen tuples; `local_transfer` keeps original xids
    /// for a same-cluster clone instead.
    #[must_use]
    #[pg_extern(schema = "pagecopy_internal")]
    pub fn pagecopy_export_stream(
        source_table: &str,
        target_table: &str,
        target_toast_oid: pg_sys::Oid,
        target_lz4_supported: bool,
        target_checksums: bool,
        local_transfer: bool,
    ) -> SetOfIterator<'static, Vec<u8>> {
        unsafe {
            exporter::export_stream(
                source_table,
                target_table,
                target_toast_oid,
                target_lz4_supported,
                target_checksums,
                local_transfer,
            )
        }
    }

    /// Lock a source table for a direct-read transfer in the current transaction.
    ///
    /// # Panics
    /// Panics if the relation cannot be resolved or is not a plain logged table.
    #[pg_extern(schema = "pagecopy_internal")]
    pub fn pagecopy_lock_source(source_table: &str) {
        unsafe { exporter::lock_source(source_table) }
            .unwrap_or_else(|error| panic!("pg_pagecopy: {error}"));
    }

    /// Check heap and TOAST tuples while ACCESS EXCLUSIVE is held, before direct reads.
    ///
    /// # Panics
    /// Panics if the relation cannot be resolved or a page cannot be read.
    #[must_use]
    #[pg_extern(schema = "pagecopy_internal")]
    pub fn pagecopy_source_is_frozen(source_table: &str) -> bool {
        unsafe { exporter::source_is_frozen(source_table) }
            .unwrap_or_else(|error| panic!("pg_pagecopy: {error}"))
    }

    /// Export a compact, target-name-independent schema descriptor.
    ///
    /// # Panics
    /// Panics if the source catalog cannot be read or the descriptor cannot be encoded.
    #[must_use]
    #[pg_extern(schema = "pagecopy_internal")]
    pub fn pagecopy_export_schema(source_table: &str) -> Vec<u8> {
        unsafe { exporter::export_schema(source_table) }
            .unwrap_or_else(|error| panic!("pg_pagecopy: {error}"))
    }

    /// Pull a table from another PostgreSQL instance and install its pages locally.
    ///
    /// # Panics
    /// Panics if validation, target creation, streaming or page installation fails.
    #[pg_extern]
    pub fn pull(
        source_conninfo: &str,
        source_table: &str,
        target_table: &str,
        generate_wal: default!(bool, "true"),
    ) {
        unsafe {
            importer::import(
                source_conninfo,
                source_table,
                target_table,
                generate_wal,
                false,
            )
            .unwrap_or_else(|error| panic!("pg_pagecopy: {error}"));
        }
    }

    /// Pull a table using a foreign server and the current user's mapping.
    ///
    /// # Panics
    /// Panics if catalog lookup, validation, streaming or installation fails.
    #[pg_extern]
    pub fn pull_server(
        server_name: &str,
        source_table: &str,
        target_table: &str,
        generate_wal: default!(bool, "true"),
    ) {
        unsafe {
            importer::import_server(server_name, source_table, target_table, generate_wal)
                .unwrap_or_else(|error| panic!("pg_pagecopy: {error}"));
        }
    }

    /// Clone a table inside the current database. Inside one cluster the
    /// original xids stay valid, so the source is not frozen: pages keep
    /// their xmin/xmax and the target inherits the source freeze horizons
    /// (pg_class.relfrozenxid/relminmxid).
    ///
    /// # Panics
    /// Panics if locking, target creation or page installation fails.
    #[pg_extern]
    pub fn clone(source_table: &str, target_table: &str, generate_wal: default!(bool, "true")) {
        unsafe {
            importer::import_local(source_table, target_table, generate_wal)
                .unwrap_or_else(|error| panic!("pg_pagecopy: {error}"));
        }
    }

    /// Read-only file inventory for a relation in the current (source)
    /// database: one row per file of the relation tree (heap, TOAST chain,
    /// every user index, and the vm/fsm forks of each physically transferred
    /// object), with its source size in bytes and how it will transfer.
    /// Uses `AccessShareLock` without reading relation pages or blocking
    /// writers; `pagecopy.pull` revalidates the target and current source
    /// state. Forks are never copied: the target starts with empty forks, so
    /// all-visible bits return only after a target VACUUM. Indexes that
    /// cannot move as page images transfer as definitions and stay INVALID on
    /// the target until REINDEX, so their constraints are not enforced until
    /// then. A relation that cannot transfer at all (view, unlogged,
    /// partitioned, ...) yields one error row with the same text every
    /// transfer path fails with: one shared policy, no drift.
    ///
    /// # Panics
    /// Panics if the relation cannot be resolved or its catalog cannot be read.
    #[must_use]
    #[pg_extern]
    pub fn check(
        source_relation: &str,
    ) -> TableIterator<
        'static,
        (
            name!(name, String),
            name!(type, String),
            name!(supported, bool),
            name!(method, String),
            name!(size, i64),
            name!(detail, String),
        ),
    > {
        let rows = unsafe { exporter::check_index(source_relation) }
            .unwrap_or_else(|error| panic!("pg_pagecopy: {error}"));
        TableIterator::new(rows)
    }

    // Installation does not grant raw-page access to every database user.
    // Administrators may grant execute to trusted roles; table ACLs still apply.
    pgrx::extension_sql!(
        r"
GRANT USAGE ON SCHEMA pagecopy TO PUBLIC;
REVOKE ALL ON SCHEMA pagecopy_internal FROM PUBLIC;
REVOKE ALL ON FUNCTION pagecopy.server_info() FROM PUBLIC;
REVOKE ALL ON FUNCTION pagecopy_internal.pagecopy_export_stream(text, text, oid, boolean, boolean, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION pagecopy_internal.pagecopy_lock_source(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pagecopy_internal.pagecopy_source_is_frozen(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pagecopy_internal.pagecopy_export_schema(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pagecopy.pull(text, text, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION pagecopy.pull_server(text, text, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION pagecopy.clone(text, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION pagecopy.check(text) FROM PUBLIC;
",
        name = "pagecopy_revoke_public_execute",
        requires = [
            server_info,
            pagecopy_export_stream,
            pagecopy_lock_source,
            pagecopy_source_is_frozen,
            pagecopy_export_schema,
            pull,
            pull_server,
            clone,
            check
        ]
    );
}
