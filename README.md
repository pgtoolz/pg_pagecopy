# pg_pagecopy

Copies a PostgreSQL table to another instance as ready-made data pages: heap,
TOAST, visibility maps and plain btree indexes. No row decoding. On a
~1.2 GB TOAST-heavy benchmark table it was 2.5× faster than
`COPY ... FORMAT binary` with 4.7× less CPU, and 6.2× faster than
`pg_dump -Fc`. The margin is workload-dependent: it grows with more indexes
and TOAST bloat, and shrinks on narrow heap-only tables — measure on your
own data (`docs/benchmark-results.md`).

Works on PostgreSQL 16, 17 and 18, for same-major transfers and upward
upgrades (16→17, 16→18, 17→18). Downgrades are rejected.

```sql
-- both databases
CREATE EXTENSION pg_pagecopy;

-- on the target
SELECT pagecopy.pull(
  'host=source dbname=postgres user=postgres',
  'public.events',       -- source table
  'public.events_copy'); -- target table, may not exist

VACUUM (ANALYZE) public.events_copy;
```

A missing target is created from the source schema (columns, defaults, CHECKs,
index definitions) in the same transaction, and any failure rolls everything
back.

Same database:

```sql
SELECT pagecopy.clone('public.events', 'public.events_archive');
```

There is also `pagecopy.pull_server(server_name, ...)` taking a foreign
server + user mapping instead of a connection string, so credentials do not
appear in SQL, logs and `pg_stat_activity`.

## What happens during a transfer

The big picture — the remote `pull` path (`clone` reuses the same machinery
over a loopback connection, `pull_server` differs only in the connect step):

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 280}}}%%
flowchart TD
    entry["🖥️ Target database<br/>SELECT pagecopy.pull(dsn, source, target, wal)"]
    entry -->|"libpq · superuser"| hs["🤝 server_info(): extension version,<br/>major pair, BLCKSZ, endianness,<br/>checksums, TOAST geometry"]

    subgraph SOURCE["🔒 Source database"]
        freeze["❄️ VACUUM (FREEZE)"]
        freeze --> lock["🔒 pagecopy_lock_source(): ACCESS EXCLUSIVE<br/>+ pagecopy_source_is_frozen(): every tuple<br/>validated frozen, ALL_FROZEN pages skipped"]
        lock --> flush["💧 FlushRelationBuffers: heap,<br/>TOAST, indexes —<br/>no cluster checkpoint"]
        flush --> read["📖 pagecopy_export_schema() descriptor,<br/>then pagecopy_export_stream(): one COPY<br/>stream of raw SMGR page reads —<br/>checksums verified on the source"]
    end

    hs --> freeze
    lock -.->|"writer raced —<br/>rollback, retry ×3"| freeze

    read -->|"1️⃣ logical: schema descriptor —<br/>columns, defaults, CHECKs,<br/>index definitions"| create["🧱 Create or fully overwrite<br/>the target table (one txn,<br/>rolls back on failure)"]
    read -->|"2️⃣ binary: pages as-is —<br/>heap · TOAST · btree · VM · FSM"| fixup["🛡️ Validate on arrival:<br/>manifest ↔ target (checksum mode,<br/>TOAST layout, attributes),<br/>page bounds, relation/fork routing"]
    read -.->|"unsupported secondary indexes:<br/>definitions only, no pages"| invalid["⚠️ invalid definitions preserved"]

    create --> write
    fixup --> write["💾 Fix up + write every page:<br/>remap TOAST OIDs source → target,<br/>reset LSN, recompute checksums,<br/>then full-page WAL or direct fsync —<br/>one txn, any failure rolls back all"]
    write --> done["🧹 VACUUM (ANALYZE) —<br/>VM/FSM arrive warm"]
    invalid -.->|"REINDEX"| done

    linkStyle 6 stroke:#43a047,stroke-width:2px
    linkStyle 7 stroke:#3949ab,stroke-width:2px
    linkStyle 8 stroke:#f9a825,stroke-width:2px

    classDef control fill:#e3f2fd,stroke:#1e88e5,color:#0d47a1
    classDef src fill:#f3e5f5,stroke:#8e24aa,stroke-width:2px,color:#4a148c
    classDef logical fill:#e8f5e9,stroke:#43a047,color:#1b5e20
    classDef binary fill:#e8eaf6,stroke:#3949ab,color:#1a237e
    classDef shield fill:#deebe9,stroke:#00897b,color:#004d40
    classDef warn fill:#fff8e1,stroke:#f9a825,color:#5d4037
    classDef edge fill:#eceff1,stroke:#546e7a,color:#263238
    class entry,hs control
    class freeze,lock,flush,read src
    class create logical
    class fixup shield
    class write binary
    class invalid warn
    class done edge
```

Step by step:

1. `VACUUM (FREEZE)` runs on the source, then the table is locked `ACCESS
   EXCLUSIVE` and every tuple is validated as frozen. A racing writer aborts
   the attempt (up to 3 retries).
2. `FlushRelationBuffers` flushes heap, TOAST and indexes. No cluster-wide
   checkpoint is needed.
3. Heap, TOAST, btree, visibility-map and free-space-map pages stream to the
   target as binary packets over a single libpq COPY channel. COPY is only
   the transport here — the payload is raw page images in a private format,
   no table data is decoded. Page checksums are verified on the source.
4. The target installs pages in one transaction, rewriting TOAST pointers,
   checksums and LSNs.
5. Indexes: plain btree (`pg_catalog` opclasses, not partial or expression)
   is copied as pages. An unsupported secondary index (hash, GiST, GIN,
   BRIN, SP-GiST, partial/expression btree) does **not** stop the transfer —
   it is created on the target from its definition marked invalid
   (`indisvalid=false, indisready=false`) and needs `REINDEX` after the
   transfer. The only index-related stop factors: an index backing a
   constraint (primary, unique, exclusion) or replica identity — those
   cannot be left invalid, so the transfer is rejected up front. Custom
   opclasses are always rejected (a same-named opclass on the target could
   silently change sort semantics).

Source writers are blocked for the read window. This is a full overwrite,
not a merge. Progress: every 1024 pages a `NOTICE` fires and
`pg_stat_activity.application_name` shows
`pg_pagecopy public.events 412/1023MB 40%`.

## Limits

- Both sides: same architecture, `BLCKSZ`, alignment, endianness, encoding,
  TOAST geometry, checksum mode. Same extension version, verified at connect
  along with the major pair and everything above.
- Heap tables only: no partitions, foreign or unlogged tables, downgrades,
  differing checksum modes.
- Plain btree indexes (`pg_catalog` opclasses, not partial or expression)
  are copied as pages. An unsupported secondary index (hash, GiST, GIN,
  BRIN, SP-GiST, partial/expression btree) does **not** fail the transfer:
  it is created on the target from its definition marked invalid
  (`indisvalid=false, indisready=false`), the data transfer succeeds, and
  you run `REINDEX` afterwards to make it usable. A transfer fails up front
  only when an index backs a constraint (primary, unique, exclusion) or
  replica identity — those cannot be degraded. Custom opclasses are always
  rejected: a same-named opclass on the target could silently change sort
  semantics.
- Whitelisted built-in types and arrays of them. Enums, `reg*`, OID,
  composite, range, domain and extension types are rejected. Collation
  identity must match. Fast defaults and virtual generated columns are
  rejected. Auto-created targets reject identity columns and `nextval`
  defaults. A pre-created target with a `nextval` default requires the
  sequence to be owned by the column, and its state is then advanced under
  the source lock.
- Foreign and exclusion constraints are unsupported. ACLs, ownership and
  roles are not transferred.
- The source connection must be a superuser, because physical export
  bypasses RLS. The target caller must own an existing target. Internal
  helpers live in `pagecopy_internal` and are revoked from `PUBLIC`.

## Build and test

```sh
make build PG_VERSION=18
make test  PG_VERSION=18
make lint  PG_VERSION=18
make bdd   PG_VERSION=17
```

`PG_CONFIG`/`PATH` selects the PostgreSQL build. The BDD suite needs Docker
and runs two postmasters in one container. Scenarios cover TOAST, btree,
overwrite, auto-creation, validation, rollback and cross-major transfers,
verified with `verify_heapam` and `bt_index_check(..., heapallindexed=true)`.

## License

MIT
