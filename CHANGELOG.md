# Changelog

All notable changes to nqlite-zig are documented here, newest first.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning starts at 0.0.x until the cutover criteria in [PLAN.md](PLAN.md)
are met.

## [Unreleased]

### Added

- **M8b lazy history seam (open parity)** — the reference's issue #133
  design ported: `v4.decodeCore` records the HISTORY section range
  instead of decoding it; `StoreFile.ensureHistory` (one-shot take)
  decodes + **prepends** file frames to the WAL-era log on first use.
  Triggers = the reference's `needs_history` (AS OF / HISTORY SINCE /
  PRUNE in a plan, at the server), **before replaying a PRUNE WAL
  frame** (compaction must retain file-era declarations), and **before
  every checkpoint** (the encoded history must include the file era or
  the rewrite would silently drop it). Measured: `decodeCore`204 ms vs
 345 ms eager on the62.5 MB /100k store (history ≈140 ms); reopen
  total is noise-bound on this box (unit tests pin the seam:
  `hist` non-null until the first temporal read, null after — exactly
  once). Gates: **37/37 tests** (2 new seam tests: temporal-after-
  reopen + PRUNE-in-WAL edge), fmt/build/spec-sync, **full `--all`
  parity57/57** (exp05/07/10 reopen+AS OF byte-identical).

- **M8+ ceiling work (query + open)** — profile-driven follow-up bound
  in `docs/BENCHMARKING.md`: **kNN @100k143→49 ms** (beats the Rust
  release band75–140 — the cutover's "exact kNN ≥ Rust" criterion) via
  top-k windowed selection (bounded heap, window ≤ n/8, total-order
  comparators ⇒ identical bytes); **BM25263→80 ms** via a
  version-keyed index cache (structurally sound only at the top-level
  `.bm25` arm where candidates == the table — `matchesFilter` never
  prunes) + binary-search tf/df; hybrid496→326 ms. **Open @100k
  attributed**: `dir+crc` dominated `v4.decode` (253 ms of345) →
  `crc32` rewritten slice-by-8 (same IEEE algorithm, bit-identical —
  vectors + fixture/WAL gates; new cross-validation test) → reopen
  ~460–625 → ~305–330 ms. Gates:35/35 tests, fmt/build/spec-sync,
  **full `--all` parity57/57**. Deferred (documented): lazy history
  decode (#133 seam), SIMD CRC, response formatting, mmap.

- **M8 performance (E08 gate)** — the scale ladder (`compare_impls
  exp08`) no longer times out: **4/4 digests byte-identical, full
  `--all` parity 57/57 across all 11 experiments**. Profile-driven fixes
  (ReleaseFast, bound numbers in `docs/BENCHMARKING.md`): corpus-sized
  sorts moved from O(n²) insertion to PDQ (`std.mem.sortUnstable` — every
  comparator is a total order, so results are byte-identical); per-row id
  scans in the kNN/RRF score path replaced with candidate-aligned dense
  lookups (fusion keeps the identical `+=` sequence → bit-identical f32
  sums); BM25 builds sort `df` once after the merge and `score()` binary
  searches docs. At 20k rows: kNN 3 920→31 ms, BM25 2 906→68 ms, hybrid
  16 819→180 ms. Dead code removed (`upsertFused`/`Fused`, vestigial
  kNN list). Deferred with gaps documented: SIMD kNN, mmap open, BM25
  index caching, adjacency index.

- **M7 temporal retention** — `PRUNE HISTORY` + `HISTORY SINCE` (the two
  statements still `NotImplemented` since M4): compaction replaces the
  history with the retained `CREATE TABLE` declarations (original
  timestamps) plus one `Snapshot` at the current clock — memories
  depth-first, re-prune rebuilds in place instead of stacking, no clock
  bump; snapshot payloads carry BTree-ordered `tables`/`vector_dims` for
  reference-byte fidelity. `HISTORY SINCE` returns one row per mutation
  strictly after the cutoff (`history:<ts>` ids, `kind` + subject fields:
  CREATE table/dim, INSERT id, RELATE from/to/name, FORGET tombstone) and
  respects the loud `HistoryPruned` horizon — now shared with `AS OF`
  through one `failPruned` helper (message byte-identical to the
  reference), including **memory blocks** (own clock/deltas/horizon;
  block errors surface on the root the server renders). New
  `QueryKind.history` label (`HISTORY SINCE <ts>`). **Gates: the
  `history_surface_transcript` golden test — same strings as the Rust
  oracle (nqlite #153) — plus prune-reseed-across-reopen; harness exp11
  (new, the first experiment to issue these statements) = 4/4 digests
  byte-identical to Rust, full parity run 53/53.**

- **M6 persistence** — `src/storage.zig`: single-writer `--db` stores as
  format-v4 files (`v4.encode`/`v4.decode`, spec/file-format.md §5) with a
  CRC32-framed WAL (`crc32 || len_le || payload`, torn-tail truncation on
  replay), checkpoint-to-main every 1 MiB (atomic rename; directory fsync
  still TODO), and `flock(LOCK_EX|LOCK_NB)` single-writer locking
  (concurrent open → `error: Locked`, exit 1 — nqlite #109). Server
  wiring: `--stdio --db PATH` opens/replays/seeds declared tables +
  memory blocks from persisted history (`seed_declared` parity with
  nqlite #111), appends mutating statements to the WAL (context resets
  stay in-memory), and checkpoints past the threshold; `main.zig` gains
  `--db`/`-d`. Engine seams: `fromIr`/`toIr` store converters,
  `executeInContext` (WAL replay), `isMutating` (WAL hook predicate).
  **Gate: 32/32 tests (4 storage tests incl. single-writer lock and
  #109 context replay + a full `--db` restart/reseed session); E2E smoke:
  same lifecycle transcript byte-identical to `nql-server --stdio --db`,
  concurrent open locked.** Ported from nqlite #152 (`nql-migrate` /
  `nqlite::v4`).

- **M4 stdio line server** — `src/server.zig` (nql-server parity: one
  program per line, multi-result lines + `OK` / single `ERR <Display>`
  line, cross-line declared-table context with synthetic `CREATE TABLE`
  prefixes, byte-exact response formatting: `MATCH`/`CLOSURE`/`SELECT`
  labels, Rust-`{:.4}` scores with **half-to-even tie rounding**
  (`0.03125` → `0.0312`), Rust-debug strings, `short_value` truncation)
  + `src/main.zig` `--stdio` loop (1 MiB line buffer, per-line flush) +
  the engine's graph/temporal surface (MATCH/CLOSURE/`MATCH COUNT`,
  edge-prop filters, `AS OF` replay, `HistoryPruned`, snapshot install).
  **Gate: the nqlite-experiments harness with `NQL_SERVER_BIN=<zig>` —
  E01–E07 + E10: 43/43 `transcript_sha256` byte-identical to the Rust
  server, all deterministic, zero errors** (the plan's M5 wire-parity
  bar, hit at M4). Key fix: lines are arena-duped at the boundary —
  parser tokens borrow the reused stdin buffer, which silently rotted
  cross-line state until the harness caught it.

- **M3 engine core** — `src/engine.zig` (canonical-order store with
  BTreeMap insert semantics, `execute_plan` with memory contexts, the full
  SELECT pipeline: all field predicates + `id` pseudo-field, exact cosine
  kNN with id tie-breaks, BM25/hybrid-RRF score dominance, `cmp_total`
  ordering incl. exact int/float rules, every ORDER BY — field/`::recency`/
  `::score` Laplace votes/`::votes`/`::feedback` decay/`::salience`
  blends — `COUNT(*)`, `OFFSET`/`LIMIT`/k-caps, projection, typo guard),
  `src/bm25.zig` (Okapi BM25, f32-exact, bit-identical `@log` vs Rust
  `f32::ln`), and `src/results.zig`: **the M3 gate — 36 golden cases
  against `spec/fixtures/engine/results.json`** (`rows_hex` bit-for-bit
  + structural row JSON + error variants). Spec pin `bafa7e0`.

- **M2 NQL parser** — `src/lexer.zig` (tokens, spans, comments, escapes,
  number/string literals — 1-based byte columns, the reference's
  post-bump error positions), `src/parser.zig` (full spec §1 grammar:
  all statements, WHERE conjunctions + kNN/BM25/hybrid, ORDER keys with
  field-DESC rules, MATCH/CLOSURE paths with edge props, JSON-ish values
  with all-numeric→vector collapse, canonical doc bodies), and
  `src/analyzer.zig` (declaration context, embedding-dim contract, kNN
  enrichment). Gate: **`spec/fixtures/nql/corpus.json` — 77 cases
  bit-for-bit** (statement hex via the M1 codec, error kind+line:col,
  analyzer variants, enriched `analyzed_hex`) + lexer-trap tests
  (digit-first ids, bare `-` at the exact column, escapes). Spec pin
  `b8e82fd`.

- **M1 values + format-v4 codec** — `src/ir.zig` (Value/RecordId/Record/
  RelationEdge/Statement/Store mirrors of `nql_ir`, incl. the two store
  flavours: section stores carry `tables`, statement-embedded stores don't
  — `serde(skip)` wire truth), `src/payload.zig` (§5.7: uleb128, zigzag,
  f32/f64 bit-exact, all 13 Statement tags), `src/v4.zig` (§5.1–§5.6
  container: writer with canonical packing + loud reader — magic/version/
  flags/alignment/CRC32/required-sections/`Truncated`-class errors, never
  a partial load), `src/crc32.zig` (IEEE, `crc32fast`-compatible). Gate:
  **golden-fixture round-trip byte-exact** against `spec/fixtures/v4/`
  (empty/plain/rich/pruned), `manifest.json` section tables, and
  `statements.json` hex+JSON oracles — plus the corruption suite and
  canonical `RecordId` ordering tests. Spec pin `68c6417`.

- **M0 bootstrap** — repository scaffold on **Zig 0.17.0** (pinned in
  `.zigversion` + `minimum_zig_version`; CI enforces the match): package
  module `nqlite_zig`, starter executable, test wiring (`zig build` /
  `zig build test` / `zig fmt --check` all green), vendored nqlite spec at
  pin `3aad8d0` with CI drift check (`scripts/check-spec-sync.sh`),
  charter ADR-001 (determinism-by-hand + toolchain policy), PLAN with
  milestones M0–M9 and cutover criteria, Apache-2.0 license.
