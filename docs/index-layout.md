# Index layout for contributors

Index transfer is a static, exhaustive match over the `IndexTransfer` enum —
there is no registry, no plugin hook and no runtime AM discovery. Four
access methods transfer physically today: B-tree, BRIN, HASH and SP-GiST,
each with its own narrow approved-opclass whitelist. Every other access
method (GiST, GIN, …), and every index of a supported method outside its
whitelist, degrades to an invalid definition.

- `src/pg_pagecopy/indexes/{mod,catalog,wire}.rs` — the AM-agnostic core:
  classification and degradation of source indexes, matching against target
  indexes, and the manifest index entries (wire tags `0` = btree, `1` =
  invalid, `2` = brin, `3` = hash, `4` = spgist; never renumbered —
  existing manifests must decode identically).
- `src/pg_pagecopy/indexes/{btree,brin,hash,spgist}.rs` — the per-AM modules:
  metadata layout comparison, metapage verification and the FFI into
  `src/index_<am>.c`. Access-method specifics live there and nowhere else.
- `src/pg_pagecopy/exporter.rs` / `importer.rs` — generic transport: they
  dispatch over `IndexTransfer` and never interpret AM-specific fields.
- TOAST indexes are strictly physical B-tree: a TOAST index that is not a
  plain B-tree fails the transfer instead of degrading.

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
   not these other integration points; `exporter.rs`/`importer.rs` stay generic.
