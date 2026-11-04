use crate::postgres::PostgresPair;
use crate::world::AttachWorld;
use cucumber::{gherkin::Step, given, then, when};
use std::time::Duration;

const BLOCK_SIZE: usize = 8192;
/// A revmap page's `rm_tids` array starts right after the 24-byte page
/// header. The nonzero BRIN page type lives in the page's final halfword,
/// so the nonempty check must exclude the special space or it would pass on
/// an all-zero TID array.
const REVMAP_TID_START: usize = 24;
/// `MAXALIGN(sizeof(BrinSpecialSpace))`: the revmap TID array ends here.
const REVMAP_SPECIAL_SIZE: usize = 16;
/// `BRIN_PAGETYPE_REVMAP`, stored little-endian in the last halfword.
const BRIN_PAGETYPE_REVMAP: u16 = 0xF092;
/// Replay always stamps an applied page with the WAL record's LSN, and
/// `pc_prepare_page` had set LSN 1 on disk, so `pd_lsn` legitimately
/// differs after recovery. The page checksum covers the page contents
/// including that LSN, so it legitimately differs too; with checksums
/// disabled the field is not maintained at all. Every byte after the
/// checksum field must match.
const PAGE_HEADER_UNSTABLE_LEN: usize = 10;
/// `BRIN_PAGETYPE_REGULAR`, the summary pages, stored little-endian in the
/// last halfword.
const BRIN_PAGETYPE_REGULAR: u16 = 0xF093;
/// `MAXALIGN(sizeof(HashPageOpaqueData))`: every hash page ends with this
/// 16-byte special space on the supported ABIs.
const HASH_SPECIAL_SIZE: usize = 16;
/// `HASHO_PAGE_ID`, stored little-endian in the page's final halfword.
const HASHO_PAGE_ID: u16 = 0xFF80;
/// `LH_PAGE_TYPE` masks the page-type bits of `hasho_flag`.
const HASH_PAGE_TYPE_MASK: u16 = 0x000F;
/// `LH_BUCKET_PAGE`.
const LH_BUCKET_PAGE: u16 = 0x0002;
/// `LH_OVERFLOW_PAGE`.
const LH_OVERFLOW_PAGE: u16 = 0x0001;
/// `LH_BITMAP_PAGE`.
const LH_BITMAP_PAGE: u16 = 0x0004;
/// `LH_META_PAGE`.
const LH_META_PAGE: u16 = 0x0008;
/// `MAXALIGN(sizeof(GinPageOpaqueData))`: every GIN page ends with this
/// 8-byte special space; GIN carries no page id word.
const GIN_SPECIAL_SIZE: usize = 8;
/// `GIN_META`, stored little-endian in the flags halfword of the special
/// space.
const GIN_META: u16 = 1 << 3;
/// `GIN_LEAF`: entry-tree leaf pages.
const GIN_LEAF: u16 = 1 << 1;
/// `GIN_DATA`: posting-tree pages.
const GIN_DATA: u16 = 1 << 0;
/// `GIN_LIST`: pending-list pages.
const GIN_LIST: u16 = 1 << 4;
/// `MAXALIGN(sizeof(ItemPointerData))`: the right bound of a posting-tree
/// data page sits right after the page header.
const GIN_DATA_HEADER_SIZE: usize = 24 + 8;

/// Whether a block is a revmap page whose TID array carries entries: the
/// BRIN revmap page type is present and some TID byte outside the special
/// space is nonzero.
fn revmap_carries_entries(page: &[u8]) -> bool {
    assert_eq!(page.len(), BLOCK_SIZE);
    let type_offset = BLOCK_SIZE - 2;
    let page_type = u16::from_le_bytes([page[type_offset], page[type_offset + 1]]);
    page_type == BRIN_PAGETYPE_REVMAP
        && page[REVMAP_TID_START..BLOCK_SIZE - REVMAP_SPECIAL_SIZE]
            .iter()
            .any(|byte| *byte != 0)
}

/// Whether a block is a populated BRIN summary (regular) page: the regular
/// page type is present and the line pointer array has started past the
/// page header (`pd_lower`), so at least one summary tuple is stored.
fn brin_summary_carries_tuples(page: &[u8]) -> bool {
    assert_eq!(page.len(), BLOCK_SIZE);
    let type_offset = BLOCK_SIZE - 2;
    let page_type = u16::from_le_bytes([page[type_offset], page[type_offset + 1]]);
    let lower = u16::from_le_bytes([page[12], page[13]]) as usize;
    page_type == BRIN_PAGETYPE_REGULAR && lower > REVMAP_TID_START
}

/// A hash page's `hasho_flag` field, little-endian, in the special space.
fn hash_page_flag(page: &[u8]) -> u16 {
    assert_eq!(page.len(), BLOCK_SIZE);
    let offset = BLOCK_SIZE - HASH_SPECIAL_SIZE + 12;
    u16::from_le_bytes([page[offset], page[offset + 1]])
}

/// Whether a block is a hash page of the given `LH_PAGE_TYPE` kind with the
/// HASH page id set, so the special space really is a `HashPageOpaqueData`.
fn is_hash_page_type(page: &[u8], page_type: u16) -> bool {
    let id_offset = BLOCK_SIZE - 2;
    let page_id = u16::from_le_bytes([page[id_offset], page[id_offset + 1]]);
    page_id == HASHO_PAGE_ID && (hash_page_flag(page) & HASH_PAGE_TYPE_MASK) == page_type
}

/// Whether a block is a populated hash bucket or overflow page: the right
/// page type is present and the line pointer array has started past the
/// page header (`pd_lower`), so at least one index tuple is stored.
fn hash_page_carries_tuples(page: &[u8], page_type: u16) -> bool {
    let lower = u16::from_le_bytes([page[12], page[13]]) as usize;
    is_hash_page_type(page, page_type) && lower > 24
}

/// Whether a block is entirely zero: hash bucket allocation reserves whole
/// allocation phases up front and initializes only each batch's final page,
/// so a valid hash index legitimately contains all-zero sparse blocks.
fn hash_page_is_all_zero(page: &[u8]) -> bool {
    page_is_all_zero(page)
}

fn page_is_all_zero(page: &[u8]) -> bool {
    assert_eq!(page.len(), BLOCK_SIZE);
    page.iter().all(|byte| *byte == 0)
}

/// A GIN page's `flags` halfword, little-endian, in the special space.
fn gin_page_flags(page: &[u8]) -> u16 {
    assert_eq!(page.len(), BLOCK_SIZE);
    assert_eq!(GIN_SPECIAL_SIZE, 8);
    u16::from_le_bytes([page[BLOCK_SIZE - 2], page[BLOCK_SIZE - 1]])
}

/// Whether a block is a GIN page of the given kind. Kinds mirror the
/// `GinPageOpaqueData` flag bits: `meta` is exactly `GIN_META`, `entry` an
/// entry-tree leaf (legitimately empty while the whole index lives in the
/// pending list), `data` any populated posting-tree page and `pending` a
/// populated pending-list page.
fn is_gin_page_kind(page: &[u8], kind: &str) -> bool {
    let flags = gin_page_flags(page);
    let lower = u16::from_le_bytes([page[12], page[13]]) as usize;
    match kind {
        "meta" => flags == GIN_META,
        "entry" => flags == GIN_LEAF,
        "data" => flags & GIN_DATA != 0 && lower > GIN_DATA_HEADER_SIZE,
        "pending" => flags & GIN_LIST != 0 && lower > 24,
        "all-zero" => page_is_all_zero(page),
        _ => panic!("gin page kind must be meta, entry, data, pending or all-zero, not {kind:?}"),
    }
}

#[given("a fresh PostgreSQL pair")]
async fn fresh_pair(world: &mut AttachWorld) {
    let pair = tokio::time::timeout(Duration::from_secs(60), PostgresPair::start())
        .await
        .expect("PostgreSQL pair startup timed out")
        .unwrap_or_else(|error| panic!("failed to start PostgreSQL pair: {error}"));
    world.pair = Some(pair);
}

#[given(expr = "a fresh PostgreSQL pair with checksums {string}")]
async fn fresh_pair_with_checksums(world: &mut AttachWorld, enabled: String) {
    let pair = tokio::time::timeout(
        Duration::from_secs(60),
        PostgresPair::start_with_checksums(checksum_setting(&enabled)),
    )
    .await
    .expect("PostgreSQL pair startup timed out")
    .unwrap_or_else(|error| panic!("failed to start PostgreSQL pair: {error}"));
    world.pair = Some(pair);
}

#[given(expr = "a fresh PostgreSQL {int} to {int} pair with checksums {string}")]
async fn fresh_cross_pair(world: &mut AttachWorld, source: u16, target: u16, enabled: String) {
    let pair = tokio::time::timeout(
        Duration::from_secs(60),
        PostgresPair::start_versions(source, target, checksum_setting(&enabled)),
    )
    .await
    .expect("PostgreSQL pair startup timed out")
    .unwrap_or_else(|error| panic!("failed to start PostgreSQL pair: {error}"));
    world.pair = Some(pair);
}

#[given(
    expr = "a fresh PostgreSQL {int} to {int} pair with source checksums {string} and target checksums {string}"
)]
async fn fresh_cross_pair_checksum_mismatch(
    world: &mut AttachWorld,
    source: u16,
    target: u16,
    source_enabled: String,
    target_enabled: String,
) {
    let pair = tokio::time::timeout(
        Duration::from_secs(60),
        PostgresPair::start_with_options(
            source,
            target,
            checksum_setting(&source_enabled),
            checksum_setting(&target_enabled),
        ),
    )
    .await
    .expect("PostgreSQL pair startup timed out")
    .unwrap_or_else(|error| panic!("failed to start PostgreSQL pair: {error}"));
    world.pair = Some(pair);
}

#[given(
    expr = "a fresh PostgreSQL {int} to {int} pair with default ICU locales {string} and {string}"
)]
async fn fresh_cross_pair_icu_locales(
    world: &mut AttachWorld,
    source: u16,
    target: u16,
    source_locale: String,
    target_locale: String,
) {
    let pair = tokio::time::timeout(
        Duration::from_secs(60),
        PostgresPair::start_with_icu_locales(source, target, &source_locale, &target_locale),
    )
    .await
    .expect("PostgreSQL pair startup timed out")
    .unwrap_or_else(|error| panic!("failed to start PostgreSQL pair: {error}"));
    world.pair = Some(pair);
}

fn checksum_setting(enabled: &str) -> bool {
    match enabled {
        "enabled" => true,
        "disabled" => false,
        _ => panic!("checksums must be enabled or disabled"),
    }
}

/// Same-major pair with independent checksum settings, so the
/// checksum-mismatch regressions run on every configured major.
#[given(
    expr = "a fresh PostgreSQL pair with source checksums {string} and target checksums {string}"
)]
async fn fresh_pair_mismatched_checksums(
    world: &mut AttachWorld,
    source_enabled: String,
    target_enabled: String,
) {
    let pair = tokio::time::timeout(
        Duration::from_secs(60),
        PostgresPair::start_with_mismatched_checksums(
            checksum_setting(&source_enabled),
            checksum_setting(&target_enabled),
        ),
    )
    .await
    .expect("PostgreSQL pair startup timed out")
    .unwrap_or_else(|error| panic!("failed to start PostgreSQL pair: {error}"));
    world.pair = Some(pair);
}

#[given(expr = "the following SQL is executed on {string}:")]
async fn given_sql(world: &mut AttachWorld, side: String, step: &Step) {
    execute_sql(world, &side, step).await;
}

#[when(expr = "the following SQL is executed on {string}:")]
async fn when_sql(world: &mut AttachWorld, side: String, step: &Step) {
    execute_sql(world, &side, step).await;
}

async fn execute_sql(world: &AttachWorld, side: &str, step: &Step) {
    let sql = docstring(step);
    tokio::time::timeout(Duration::from_secs(30), world.execute(side, sql))
        .await
        .expect("SQL execution timed out")
        .unwrap_or_else(|error| panic!("SQL on {side} failed: {error}\nSQL:\n{sql}"));
}

#[given(expr = "a non-default tablespace is available on {string}")]
async fn create_tablespace(world: &mut AttachWorld, side: String) {
    let pair = world.pair.as_ref().expect("PostgreSQL pair is not running");
    tokio::time::timeout(Duration::from_secs(30), pair.create_tablespace(&side))
        .await
        .expect("tablespace creation timed out")
        .unwrap_or_else(|error| panic!("failed to create tablespace: {error}"));
}

#[when(expr = "the data file path of target relation {string} is recorded")]
async fn record_target_data_file(world: &mut AttachWorld, relation: String) {
    let sql = format!("SELECT pg_relation_filepath('{relation}')");
    let relative = tokio::time::timeout(Duration::from_secs(30), world.query("target", &sql))
        .await
        .expect("SQL query timed out")
        .unwrap_or_else(|error| panic!("query on target failed: {error}\nSQL:\n{sql}"));
    let pair = world.pair.as_ref().expect("PostgreSQL pair is not started");
    world.recorded_data_file = Some(pair.target_data_path(&relative));
}

#[when("target postmaster is crashed")]
fn crash_target_without_restart(world: &mut AttachWorld) {
    world
        .pair
        .as_mut()
        .expect("PostgreSQL pair is not started")
        .crash_target_only()
        .expect("failed to crash target postmaster");
}

#[when("the recorded target data file is removed")]
fn remove_recorded_data_file(world: &mut AttachWorld) {
    let path = world
        .recorded_data_file
        .clone()
        .expect("no recorded target data file");
    assert!(
        path.exists(),
        "recorded data file {} does not exist",
        path.display()
    );
    std::fs::remove_file(&path)
        .unwrap_or_else(|error| panic!("failed to remove {}: {error}", path.display()));
    let stem = path
        .file_name()
        .expect("file name")
        .to_string_lossy()
        .into_owned();
    for segment in 1.. {
        let sibling = path.with_file_name(format!("{stem}_{segment}"));
        if !sibling.exists() {
            break;
        }
        std::fs::remove_file(&sibling)
            .unwrap_or_else(|error| panic!("failed to remove {}: {error}", sibling.display()));
    }
}

#[when("target postmaster is started")]
async fn start_target_postmaster(world: &mut AttachWorld) {
    let start = world
        .pair
        .as_mut()
        .expect("PostgreSQL pair is not started")
        .start_target();
    tokio::time::timeout(Duration::from_secs(60), start)
        .await
        .expect("target postmaster start timed out")
        .unwrap_or_else(|error| panic!("failed to start target: {error}"));
}

#[given("source PostgreSQL is stopped")]
fn stop_source(world: &mut AttachWorld) {
    let pair = world.pair.as_ref().expect("PostgreSQL pair is not running");
    pair.stop_source()
        .unwrap_or_else(|error| panic!("failed to stop source PostgreSQL: {error}"));
}

#[when("target postmaster is crashed and restarted")]
async fn crash_target(world: &mut AttachWorld) {
    let pair = world.pair.as_ref().expect("PostgreSQL pair is not running");
    pair.crash_target()
        .await
        .unwrap_or_else(|error| panic!("failed to crash and restart target: {error}"));
}

#[when("source is stopped during the following SQL on \"target\":")]
async fn stop_source_during_import(world: &mut AttachWorld, step: &Step) {
    let sql = world.expand_sql(docstring(step));
    let pair = world.pair.as_ref().expect("PostgreSQL pair is not running");
    let import = pair.execute("target", &sql);
    tokio::pin!(import);
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    loop {
        assert!(
            std::time::Instant::now() < deadline,
            "source COPY did not start"
        );
        let check = pair.query(
            "source",
            "SELECT count(*)::text FROM pg_stat_activity \
             WHERE state = 'active' AND query LIKE 'COPY (SELECT pagecopy_internal.pagecopy_export_stream(%'",
        );
        tokio::pin!(check);
        let result = tokio::select! {
            result = &mut import => panic!("import finished before source shutdown: {result:?}"),
            result = &mut check => result.unwrap_or_else(|error| panic!("COPY query failed: {error}")),
        };
        if result == "1" {
            break;
        }
    }
    pair.stop_source()
        .unwrap_or_else(|error| panic!("failed to stop source PostgreSQL: {error}"));
    let error = import
        .await
        .expect_err("import succeeded despite source shutdown");
    eprintln!("source disconnect import error: {error}");
}

#[when("a source writer is blocked during the following SQL on \"target\":")]
async fn source_writer_is_blocked(world: &mut AttachWorld, step: &Step) {
    let sql = world.expand_sql(docstring(step));
    let pair = world.pair.as_ref().expect("PostgreSQL pair is not running");
    let import = pair.execute("target", &sql);
    tokio::pin!(import);
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    loop {
        assert!(
            std::time::Instant::now() < deadline,
            "source import did not reach the streaming read lock"
        );
        // The auto-freeze protocol may release its first AccessExclusiveLock
        // and reopen it after VACUUM FREEZE; writers may commit in that gap
        // legitimately. The blocking guarantee starts only when the lock is
        // held by the streaming COPY, which never retries and ends in COMMIT.
        let check = pair.query(
            "source",
            "SELECT count(*)::text FROM pg_locks l JOIN pg_class c ON c.oid = l.relation JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_stat_activity a ON a.pid = l.pid WHERE n.nspname = 'public' AND c.relname = 'events' AND l.mode = 'AccessExclusiveLock' AND l.granted AND a.state = 'active' AND a.query LIKE 'COPY (SELECT pagecopy_internal.pagecopy_export_stream(%'",
        );
        tokio::pin!(check);
        let result = tokio::select! {
            result = &mut import => panic!("import finished before lock was observed: {result:?}"),
            result = &mut check => result.unwrap_or_else(|error| panic!("lock query failed: {error}")),
        };
        if result == "1" {
            break;
        }
    }
    let writer = pair.execute(
        "source",
        "INSERT INTO public.events VALUES (20001, encode(gen_random_bytes(1000), 'hex'), 'writer')",
    );
    tokio::pin!(writer);
    // The freeze gap between the first AccessExclusiveLock release and the
    // streaming re-acquisition can legitimately let the writer commit; the
    // export snapshot predates it, so the row is never copied either way.
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    loop {
        assert!(
            std::time::Instant::now() < deadline,
            "writer outcome was not observed"
        );
        let waiting = pair.query(
            "source",
            "SELECT count(*)::text FROM pg_locks l JOIN pg_class c ON c.oid = l.relation WHERE c.relname = 'events' AND l.mode = 'RowExclusiveLock' AND NOT l.granted",
        );
        tokio::pin!(waiting);
        let result = tokio::select! {
            result = &mut import => { result.expect("direct import failed"); writer.await.expect("source writer failed"); return; }
            result = &mut writer => { result.expect("source writer failed"); return; }
            result = &mut waiting => result.unwrap_or_else(|error| panic!("lock query failed: {error}")),
        };
        if result == "1" {
            break;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    import
        .await
        .unwrap_or_else(|error| panic!("direct import failed: {error}"));
    writer
        .await
        .unwrap_or_else(|error| panic!("blocked source writer failed: {error}"));
}

#[when("a source writer holds row locks during the following SQL on \"source\":")]
async fn source_writer_during_check(world: &mut AttachWorld, step: &Step) {
    let sql = world.expand_sql(docstring(step));
    let pair = world.pair.as_ref().expect("PostgreSQL pair is not running");
    let dsn = format!(
        "host=127.0.0.1 port={} dbname=postgres user=postgres",
        pair.source_port()
    );
    let (writer, connection) = tokio_postgres::connect(&dsn, tokio_postgres::NoTls)
        .await
        .expect("source writer connection failed");
    let connection_task = tokio::spawn(async move {
        if let Err(error) = connection.await {
            eprintln!("source writer connection error: {error}");
        }
    });
    writer
        .batch_execute("BEGIN; INSERT INTO public.events VALUES (99, 'writer')")
        .await
        .expect("source writer did not acquire its row locks");

    let check = tokio::time::timeout(Duration::from_secs(10), pair.execute("source", &sql)).await;
    let commit = writer.batch_execute("COMMIT").await;
    drop(writer);
    connection_task
        .await
        .expect("source writer connection task failed");
    check
        .expect("pagecopy.check waited for an ordinary source writer")
        .unwrap_or_else(|error| panic!("pagecopy.check failed: {error}"));
    commit.expect("source writer did not commit");
}

#[when("target ownership changes during the following SQL on \"target\":")]
async fn target_ownership_change(world: &mut AttachWorld, step: &Step) {
    let sql = world.expand_sql(docstring(step));
    let pair = world.pair.as_ref().expect("PostgreSQL pair is not running");
    tokio::time::timeout(
        Duration::from_secs(45),
        pair.change_target_owner_during_import(&sql),
    )
    .await
    .expect("ownership race test timed out")
    .unwrap_or_else(|error| panic!("ownership race test failed: {error}"));
}

#[when("an import to a blackholed source times out on \"target\"")]
async fn blackholed_source_connect_timeout(world: &mut AttachWorld) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind blackhole listener");
    let port = listener
        .local_addr()
        .expect("blackhole listener address")
        .port();
    let server = std::thread::spawn(move || {
        let (_socket, _) = listener.accept().expect("accept blackhole connection");
        std::thread::sleep(Duration::from_secs(3));
    });
    let sql = format!(
        "SELECT pagecopy.pull(\
         'host=127.0.0.1 port={port} dbname=postgres user=postgres connect_timeout=1', \
         'public.events', 'public.events', false)"
    );
    let pair = world.pair.as_ref().expect("PostgreSQL pair is not running");
    let started = std::time::Instant::now();
    let error = tokio::time::timeout(Duration::from_secs(10), pair.execute("target", &sql))
        .await
        .expect("blackholed connection did not time out")
        .expect_err("blackholed connection unexpectedly succeeded");
    assert!(
        error.contains("connect_timeout expired"),
        "unexpected blackhole connection error: {error}"
    );
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "connect_timeout took {:?}",
        started.elapsed()
    );
    server.join().expect("blackhole listener thread");
}

#[when("the following SQL on \"target\" is cancelled:")]
async fn cancel_target_import(world: &mut AttachWorld, step: &Step) {
    let sql = world.expand_sql(docstring(step));
    let pair = world.pair.as_ref().expect("PostgreSQL pair is not running");
    pair.cancel_target(&sql, Duration::from_millis(1))
        .await
        .unwrap_or_else(|error| panic!("target cancellation failed: {error}"));
}

#[when(expr = "the following SQL on \"target\" is cancelled after {int} ms:")]
async fn cancel_target_import_after(world: &mut AttachWorld, delay: u64, step: &Step) {
    let sql = world.expand_sql(docstring(step));
    let pair = world.pair.as_ref().expect("PostgreSQL pair is not running");
    pair.cancel_target(&sql, Duration::from_millis(delay))
        .await
        .unwrap_or_else(|error| panic!("target cancellation failed: {error}"));
}

#[when(expr = "the following SQL on \"target\" is cancelled after the index page milestone:")]
async fn cancel_target_import_after_index_milestone(world: &mut AttachWorld, step: &Step) {
    let sql = world.expand_sql(docstring(step));
    let pair = world.pair.as_ref().expect("PostgreSQL pair is not running");
    pair.cancel_target_after_index_milestone(&sql)
        .await
        .unwrap_or_else(|error| panic!("target cancellation failed: {error}"));
}

#[when(expr = "the following SQL on {string} is interrupted by timeout:")]
async fn timeout_sql(world: &mut AttachWorld, side: String, step: &Step) {
    let sql = world.expand_sql(docstring(step));
    let pair = world.pair.as_ref().expect("PostgreSQL pair is not running");
    tokio::time::timeout(Duration::from_millis(50), pair.execute(&side, &sql))
        .await
        .expect_err("SQL was not interrupted by timeout");
}

#[then(expr = "the following SQL on {string} returns {string}:")]
async fn query_result(world: &mut AttachWorld, side: String, expected: String, step: &Step) {
    let sql = docstring(step);
    let actual = tokio::time::timeout(Duration::from_secs(30), world.query(&side, sql))
        .await
        .expect("SQL query timed out")
        .unwrap_or_else(|error| panic!("query on {side} failed: {error}\nSQL:\n{sql}"));
    assert_eq!(actual, expected, "unexpected query result\nSQL:\n{sql}");
}

#[then(expr = "the following SQL on {string} contains {string}:")]
async fn query_result_contains(
    world: &mut AttachWorld,
    side: String,
    expected: String,
    step: &Step,
) {
    let sql = docstring(step);
    let actual = tokio::time::timeout(Duration::from_secs(30), world.query(&side, sql))
        .await
        .expect("SQL query timed out")
        .unwrap_or_else(|error| panic!("query on {side} failed: {error}\nSQL:\n{sql}"));
    assert!(
        actual.contains(&expected),
        "query result does not contain {expected:?}: {actual}\nSQL:\n{sql}"
    );
}

#[then(expr = "the following SQL on {string} fails with {string}:")]
async fn query_error(world: &mut AttachWorld, side: String, expected: String, step: &Step) {
    let sql = docstring(step);
    let error = tokio::time::timeout(Duration::from_secs(30), world.execute(&side, sql))
        .await
        .expect("SQL execution timed out")
        .expect_err("SQL unexpectedly succeeded");
    assert!(
        error.contains(&expected),
        "unexpected SQL error: {error}\nexpected substring: {expected}\nSQL:\n{sql}"
    );
}

#[then(expr = "frozen validation reads {int} data pages across {int} relations")]
fn validation_reads(world: &mut AttachWorld, expected_reads: u32, expected_relations: usize) {
    let log = world
        .pair
        .as_ref()
        .expect("PostgreSQL pair is not running")
        .source_log()
        .expect("cannot read source log");
    let reads: Vec<u32> = log
        .lines()
        .filter(|line| line.contains("pg_pagecopy: frozen validation "))
        .map(|line| {
            line.rsplit_once("data pages read=")
                .expect("missing validation read count")
                .1
                .parse()
                .expect("invalid validation read count")
        })
        .collect();
    assert_eq!(
        reads.len(),
        expected_relations,
        "missing validation diagnostics"
    );
    assert_eq!(reads.iter().sum::<u32>(), expected_reads, "{reads:?}");
}

async fn record_target_block_checked(
    world: &mut AttachWorld,
    relation: String,
    block: u64,
    check: impl Fn(&[u8]) -> bool,
    kind: &str,
) {
    let sql = format!("SELECT pg_relation_filepath('{relation}')");
    let relative = tokio::time::timeout(Duration::from_secs(30), world.query("target", &sql))
        .await
        .expect("SQL query timed out")
        .unwrap_or_else(|error| panic!("query on target failed: {error}\nSQL:\n{sql}"));
    let pair = world.pair.as_ref().expect("PostgreSQL pair is not started");
    let path = pair.target_data_path(&relative);
    assert!(
        path.exists(),
        "target data file {} does not exist",
        path.display()
    );
    let bytes = std::fs::read(&path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()));
    let block = usize::try_from(block).expect("block number fits usize");
    let start = block * BLOCK_SIZE;
    let recorded = bytes[start..start + BLOCK_SIZE].to_vec();
    assert!(
        check(&recorded),
        "recorded block {block} of {relation} is not a populated index {kind} page; \
         the fixture is too small",
    );
    world.recorded_data_file = Some(path);
    world
        .recorded_relation_blocks
        .push((block as u64, recorded));
}

#[when(expr = "target relation {string} block {int} is recorded")]
async fn record_target_block(world: &mut AttachWorld, relation: String, block: u64) {
    record_target_block_checked(world, relation, block, revmap_carries_entries, "revmap").await;
}

#[when(expr = "target relation {string} block {int} is recorded as a brin {string} page")]
async fn record_target_brin_page(
    world: &mut AttachWorld,
    relation: String,
    block: u64,
    kind: String,
) {
    let check = match kind.as_str() {
        "revmap" => revmap_carries_entries,
        "summary" => brin_summary_carries_tuples,
        _ => panic!("brin page kind must be revmap or summary, not {kind:?}"),
    };
    record_target_block_checked(world, relation, block, check, &kind).await;
}

#[when(expr = "target relation {string} block {int} is recorded as a hash {string} page")]
async fn record_target_hash_page(
    world: &mut AttachWorld,
    relation: String,
    block: u64,
    kind: String,
) {
    let check = match kind.as_str() {
        "meta" => |page: &[u8]| is_hash_page_type(page, LH_META_PAGE),
        "bucket" => |page: &[u8]| hash_page_carries_tuples(page, LH_BUCKET_PAGE),
        "overflow" => |page: &[u8]| hash_page_carries_tuples(page, LH_OVERFLOW_PAGE),
        "bitmap" => |page: &[u8]| is_hash_page_type(page, LH_BITMAP_PAGE),
        "all-zero" => hash_page_is_all_zero,
        _ => panic!("hash page kind must be meta, bucket, overflow, bitmap or all-zero, not {kind:?}"),
    };
    record_target_block_checked(world, relation, block, check, &kind).await;
}

#[when(expr = "target relation {string} block {int} is recorded as a gin {string} page")]
async fn record_target_gin_page(
    world: &mut AttachWorld,
    relation: String,
    block: u64,
    kind: String,
) {
    let owned = kind.clone();
    let check = move |page: &[u8]| is_gin_page_kind(page, &owned);
    record_target_block_checked(world, relation, block, check, &kind).await;
}

#[then("the recorded target block is unchanged after crash recovery")]
fn recorded_block_survives_recovery(world: &mut AttachWorld) {
    let path = world
        .recorded_data_file
        .clone()
        .expect("no recorded target data file");
    let recorded = std::mem::take(&mut world.recorded_relation_blocks);
    assert!(
        !recorded.is_empty(),
        "no recorded target blocks to compare after recovery"
    );
    assert!(
        path.exists(),
        "recorded data file {} was not rebuilt by WAL recovery",
        path.display()
    );
    let bytes = std::fs::read(&path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()));
    for (block, expected) in recorded {
        let start = usize::try_from(block).expect("block number fits usize") * BLOCK_SIZE;
        let recovered = &bytes[start + PAGE_HEADER_UNSTABLE_LEN..start + BLOCK_SIZE];
        assert_eq!(
            recovered,
            &expected[PAGE_HEADER_UNSTABLE_LEN..],
            "crash recovery restored different bytes for block {block}; \
             revmap or summary contents were lost"
        );
    }
}

/// Replay of a standard-page full-page image preserves every byte outside
/// `[pd_lower, pd_upper)` but always zero-fills the hole itself, and stamps
/// the page LSN/checksum in the first 16 bytes; an all-zero page is never
/// stamped (`PageIsNew` guard) and must recover fully zero.
#[then("the recorded target block is unchanged after crash recovery except the WAL hole")]
fn recorded_block_survives_recovery_excluding_hole(world: &mut AttachWorld) {
    let path = world
        .recorded_data_file
        .clone()
        .expect("no recorded target data file");
    let recorded = std::mem::take(&mut world.recorded_relation_blocks);
    assert!(
        !recorded.is_empty(),
        "no recorded target blocks to compare after recovery"
    );
    assert!(
        path.exists(),
        "recorded data file {} was not rebuilt by WAL recovery",
        path.display()
    );
    let bytes = std::fs::read(&path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()));
    for (block, expected) in recorded {
        let start = usize::try_from(block).expect("block number fits usize") * BLOCK_SIZE;
        let recovered = &bytes[start..start + BLOCK_SIZE];
        if hash_page_is_all_zero(&expected) {
            // Replay never stamps an uninitialized page (PageIsNew guard),
            // so a reserved all-zero block must recover fully zero.
            assert!(
                recovered.iter().all(|byte| *byte == 0),
                "crash recovery changed originally all-zero block {block}"
            );
            continue;
        }
        let lower = u16::from_le_bytes([expected[12], expected[13]]) as usize;
        let upper = u16::from_le_bytes([expected[14], expected[15]]) as usize;
        assert_eq!(
            &recovered[PAGE_HEADER_UNSTABLE_LEN..lower],
            &expected[PAGE_HEADER_UNSTABLE_LEN..lower],
            "crash recovery lost page data below the WAL hole for block {block}"
        );
        assert!(
            recovered[lower..upper].iter().all(|byte| *byte == 0),
            "crash recovery left nonzero bytes in the WAL hole of block {block}"
        );
        assert_eq!(
            &recovered[upper..],
            &expected[upper..],
            "crash recovery restored different bytes for block {block} above the WAL hole"
        );
    }
}

#[then("target data checksums verify after a clean shutdown")]
async fn target_checksums_verify(world: &mut AttachWorld) {
    let pair = world.pair.as_mut().expect("PostgreSQL pair is not started");
    tokio::time::timeout(Duration::from_secs(60), pair.verify_target_checksums())
        .await
        .expect("checksum verification timed out")
        .unwrap_or_else(|error| panic!("target checksum verification failed: {error}"));
}

#[then("source PostgreSQL did not crash")]
fn source_did_not_crash(world: &mut AttachWorld) {
    let log = world
        .pair
        .as_ref()
        .expect("PostgreSQL pair is not running")
        .source_log()
        .expect("cannot read source log");
    assert!(
        !log.contains("terminated by signal")
            && !log.contains("non-unwinding panic")
            && !log.contains("reinitializing")
            && !log.contains("automatic recovery in progress"),
        "source backend crashed:\n{log}"
    );
}

fn docstring(step: &Step) -> &str {
    step.docstring
        .as_deref()
        .expect("SQL docstring is required")
}

#[cfg(test)]
mod tests {
    use super::{revmap_carries_entries, BLOCK_SIZE, BRIN_PAGETYPE_REVMAP, REVMAP_SPECIAL_SIZE};

    fn revmap_page(page_type: u16, tid_byte: u8) -> [u8; BLOCK_SIZE] {
        let mut page = [0u8; BLOCK_SIZE];
        let type_offset = BLOCK_SIZE - 2;
        page[type_offset..type_offset + 2].copy_from_slice(&page_type.to_le_bytes());
        page[BLOCK_SIZE - REVMAP_SPECIAL_SIZE - 1] = tid_byte;
        page
    }

    #[test]
    fn a_valid_page_type_with_an_all_zero_tid_array_is_rejected() {
        // Self-check of the guard the crash scenario relies on: the nonzero
        // page type sits in the special space, so it must not count as an
        // entry. A TID byte inside the array makes the page qualify.
        assert!(!revmap_carries_entries(&revmap_page(
            BRIN_PAGETYPE_REVMAP,
            0
        )));
        assert!(revmap_carries_entries(&revmap_page(
            BRIN_PAGETYPE_REVMAP,
            1
        )));
        assert!(!revmap_carries_entries(&revmap_page(0xF093, 1)));
    }

    fn summary_page(lower: u16) -> [u8; BLOCK_SIZE] {
        let mut page = [0u8; BLOCK_SIZE];
        let type_offset = BLOCK_SIZE - 2;
        page[type_offset..type_offset + 2]
            .copy_from_slice(&super::BRIN_PAGETYPE_REGULAR.to_le_bytes());
        page[12..14].copy_from_slice(&lower.to_le_bytes());
        page
    }

    #[test]
    fn a_summary_page_is_recognized_only_with_tuples() {
        // Self-check for the crash scenarios' summary-page guard: an empty
        // regular page must not count as a populated summary page.
        assert!(!super::brin_summary_carries_tuples(&summary_page(0)));
        assert!(!super::brin_summary_carries_tuples(&summary_page(24)));
        assert!(super::brin_summary_carries_tuples(&summary_page(32)));
        assert!(!super::brin_summary_carries_tuples(&revmap_page(
            BRIN_PAGETYPE_REVMAP,
            1
        )));
    }

    fn hash_page(page_type: u16, lower: u16) -> [u8; BLOCK_SIZE] {
        let mut page = [0u8; BLOCK_SIZE];
        let id_offset = BLOCK_SIZE - 2;
        page[id_offset..id_offset + 2].copy_from_slice(&super::HASHO_PAGE_ID.to_le_bytes());
        let flag_offset = BLOCK_SIZE - super::HASH_SPECIAL_SIZE + 12;
        page[flag_offset..flag_offset + 2].copy_from_slice(&page_type.to_le_bytes());
        page[12..14].copy_from_slice(&lower.to_le_bytes());
        page
    }

    #[test]
    fn a_hash_bucket_page_is_recognized_only_with_the_page_id_and_tuples() {
        // Self-check for the sparse-page crash scenarios: only the right
        // page id plus type plus stored tuples make a bucket page qualify.
        assert!(super::hash_page_carries_tuples(
            &hash_page(super::LH_BUCKET_PAGE, 32),
            super::LH_BUCKET_PAGE
        ));
        assert!(!super::hash_page_carries_tuples(
            &hash_page(super::LH_BUCKET_PAGE, 24),
            super::LH_BUCKET_PAGE
        ));
        assert!(!super::hash_page_carries_tuples(
            &hash_page(super::LH_BITMAP_PAGE, 32),
            super::LH_BUCKET_PAGE
        ));
        let mut wrong_id = hash_page(super::LH_BUCKET_PAGE, 32);
        wrong_id[BLOCK_SIZE - 2] = 0;
        assert!(!super::hash_page_carries_tuples(
            &wrong_id,
            super::LH_BUCKET_PAGE
        ));
        assert!(!super::hash_page_carries_tuples(
            &[0u8; BLOCK_SIZE],
            super::LH_BUCKET_PAGE
        ));
        assert!(super::hash_page_is_all_zero(&[0u8; BLOCK_SIZE]));
        assert!(!super::hash_page_is_all_zero(&hash_page(
            super::LH_BUCKET_PAGE,
            32
        )));
    }

    fn gin_page(flags: u16, lower: u16) -> [u8; BLOCK_SIZE] {
        let mut page = [0u8; BLOCK_SIZE];
        page[BLOCK_SIZE - 2..BLOCK_SIZE].copy_from_slice(&flags.to_le_bytes());
        page[12..14].copy_from_slice(&lower.to_le_bytes());
        page
    }

    #[test]
    fn a_gin_page_is_recognized_only_by_its_flag_kind_and_content() {
        // Self-check for the crash scenarios' page-kind guards: every kind
        // needs its exact flag bits, and entry/data/pending pages must carry
        // content below or past the page header, not just flag bits.
        assert_eq!(super::GIN_SPECIAL_SIZE, 8);
        assert!(super::is_gin_page_kind(
            &gin_page(super::GIN_META, 80),
            "meta"
        ));
        assert!(!super::is_gin_page_kind(
            &gin_page(super::GIN_DATA, 80),
            "meta"
        ));
        assert!(super::is_gin_page_kind(
            &gin_page(super::GIN_LEAF, 32),
            "entry"
        ));
        assert!(super::is_gin_page_kind(
            &gin_page(super::GIN_LEAF, 24),
            "entry"
        ));
        assert!(!super::is_gin_page_kind(
            &gin_page(super::GIN_META, 32),
            "entry"
        ));
        assert!(super::is_gin_page_kind(
            &gin_page(super::GIN_DATA | super::GIN_LEAF, 40),
            "data"
        ));
        assert!(super::is_gin_page_kind(
            &gin_page(super::GIN_DATA, 40),
            "data"
        ));
        assert!(!super::is_gin_page_kind(
            &gin_page(super::GIN_DATA, 24),
            "data"
        ));
        assert!(super::is_gin_page_kind(
            &gin_page(super::GIN_LIST, 32),
            "pending"
        ));
        assert!(!super::is_gin_page_kind(
            &gin_page(super::GIN_LIST, 24),
            "pending"
        ));
        assert!(super::is_gin_page_kind(&[0u8; BLOCK_SIZE], "all-zero"));
        assert!(!super::is_gin_page_kind(
            &gin_page(super::GIN_META, 80),
            "all-zero"
        ));
    }
}
