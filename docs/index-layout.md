# Index layout for contributors

Index transfer is a static, exhaustive match over the `IndexTransfer` enum —
there is no registry, no plugin hook and no runtime AM discovery. Six
access methods transfer physically today — B-tree, BRIN, HASH, SP-GiST,
GIN and GiST — each behind a narrow whitelist of exact core opclass/type
pairs (B-tree: any `pg_catalog` opclass including partial and expression
forms; BRIN: fixed-width minmax; hash: int2/int4/int8; SP-GiST:
`quad_point_ops`/`kd_point_ops` on `point`; GIN: `array_ops` on `int[]`
and `jsonb_ops` on `jsonb`, plain single-column keys; GiST: `point_ops`
on `point`). Every other index — off-whitelist opclasses of those methods,
  expression or partial forms, or multicolumn/INCLUDE forms on the
  single-key methods (HASH, SP-GiST, GIN, GiST) — degrades to an invalid
definition.

- `src/pg_pagecopy/indexes/{mod,catalog,wire}.rs` — the AM-agnostic core:
  classification and degradation of source indexes, matching against target
  indexes, and the manifest index entries (wire tags `0` = btree, `1` =
  invalid, `2` = brin, `3` = hash, `4` = spgist, `5` = gin, `6` = gist;
  never renumbered — existing manifests must decode identically).
- `src/pg_pagecopy/indexes/{btree,brin,hash,spgist,gin,gist}.rs` — one
  module per access method: metadata layout comparison, metapage or root
  verification and the FFI into `src/index_<am>.c`. Access-method
  specifics live in these modules and nowhere else.
- `src/pg_pagecopy/exporter.rs` / `importer.rs` — generic transport: they
  dispatch over `IndexTransfer` and never interpret AM-specific fields.
  Page preparation is the one AM-aware exception: `Rel::prepare_index_page`
  routes GiST pages through the NSN-stamping helper in `src/index_gist.c`.
- TOAST indexes are strictly physical B-tree: a TOAST index that is not a
  plain B-tree fails the transfer instead of degrading.

GiST deserves a note: pages carry an NSN (node sequence number) in
`GISTPageOpaqueData` used by the `parentlsn < NSN` interlock to detect
concurrent page splits. Because transfer resets every page LSN, a copied
NSN would exceed all parent LSNs forever and scans would follow rightlinks
into pages their parent already covers, returning duplicate rows. Export
therefore stamps every GiST page's NSN with `GistBuildLSN` — exactly what
an index build leaves behind — while F_FOLLOW_RIGHT flags and rightlinks
of genuinely incomplete splits are kept verbatim so chain-following still
works.

The byte-level guard tests in `indexes/wire.rs` and `wire.rs` pin this wire
contract; a format change must fail there, not in a cross-version transfer.

Adding a future access method means, in order:

1. a new `IndexTransfer` variant in `indexes/wire.rs` with the next free wire
   tag in `encode_index`/`decode_index` (never renumber existing tags);
2. an `indexes/<am>.rs` module with its metadata, target matching and metapage
   verification, plus its C half in `src/<am>.c`, a `build.rs` entry and the
   corresponding Docker dependency-stage stub/rebuild entry;
3. source classification/gating in `Rel::non_physical_reason()` and
   `classify_index()`, plus conversion into the new manifest variant;
4. the new `indexes/catalog.rs` match arms, including physical metadata
   routing in `physical_index()`. Exhaustive matches catch missing arms, but
   not these other integration points; `exporter.rs`/`importer.rs` stay
   generic.
