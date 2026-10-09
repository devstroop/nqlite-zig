# Changelog

All notable changes to nqlite-zig are documented here, newest first.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning started at 0.0.x during bootstrap — **v0.1.0 is the first
release, cut once the cutover criteria in [PLAN.md](PLAN.md) were met**
(digests · persistence · importer · perf · knot ADR · flagged default).

## [Unreleased]

### Added

- **Bench percentiles + kept per-iteration samples (#28)** — the four
  in-process benches (`bench-format`/`bench-query`/`bench-crc`/
  `bench-ingest`) no longer reduce their REPS samples to a median at
  print time: a shared `src/bench_stats.zig` reports **p50/p95/p99/max
  + mean + rate** from the kept samples (linear-interpolation
  percentiles — the same rule as the Rust side's
  `bench-percentiles.py`; median keeps its exact old definition so
  published medians stay comparable). `bench-ingest` now measures
  REPS fresh-store iterations per (size, order) instead of one sample
  per row. Tables recorded in `docs/BENCHMARKING.md` (ReleaseFast,
  bound to box/profile/date): e.g. format p99 18.13 ms, query-star p99
  21.95 ms @100k, pclmul p99 13.58 ms, ingest reverse@100k p99
  98.95 ms — flat, no quadratic. Method unchanged: in-process, median
  of 7 (external process timing on this box is unusable).

### Changed

- **Response formatting −5× (the M8+ deferral, closed)** —
  `formatResult` now builds ONE pre-sized buffer with stack scratch
  (`score4Into`/`idInto`/`fieldsInto`/`shortValueInto` — same math,
  same escaping, byte-identical) instead of ~6 heap allocations per
  row: in-process bench (`zig build bench-format`,100k rows /
  3.96 MB line, median of7) **138.34 →27.78 ms**. New committed
  micro-bench = the trusted method (external process timing on this
  box swings ±2×). Pub wrappers keep `rustFormat4`/`formatFields`
  for CLI/MCP callers.
- **Field-projection path zero-alloc** — `SELECT <fields>` kept a
  per-row `ArrayList` (engine `runSelect`): projection was48 ms vs22
  ms star @100k (`zig build bench-query`). Fully-kept bodies now keep
  the SAME slice (zero alloc), empty results share a static slice,
  partial matches copy once → **48.0 →27.0 ms**, byte-identical order
  and values (suite + exp01–exp11 digests pin it). Together with the
  formatting fix: zig-side full-scan pipeline ≈**186 →55 ms @100k**
  (engine + response); attribution note in BENCHMARKING.md corrected
  (the external551 ms row was mostly harness-python line parsing).
- **CRC-32 SIMD (PCLMULQDQ) — the crc32fast-class lever, measured10.7×** —
  `crc32fast1.5.2`'s pclmul algorithm ported verbatim to
  `src/crc32_simd.c` (header-free: one clang builtin + vector
  extensions; per-function `target(...)` = Rust's `#[target_feature]`;
  zig's asm encoder can't assemble non-baseline instructions and
  `<emmintrin.h>` drags in libc — hence C). Runtime cpuid gate
  (`usePclmul`), non-x86 comptime-dead, slice-by-8 stays the fallback.
  Bench `zig build bench-crc`: **64 MB — slice-by-8100.16 ms (670
  MB/s) → PCLMUL9.37 ms (7158 MB/s) =10.68×**; CRC share of reopen
  `dir+crc ≈100 ms` → ~9 ms (**−85 ms**). Byte-identity: every-length
  ladder test + fixtures/WAL + exp01–exp11 digests (the bench's XOR
  checksums cancel to0 in-process).
- **mmap open (read-into-arena → read-only mapping)** — `loadMain` and
  the lazy `takeHistory` re-read now decode straight from a
  whole-file `posix.mmap` (`MAP_PRIVATE`, page-aligned; read path kept
  as fallback). Zero-copy decode means the store BORROWS the mapping —
  it lives on `StoreFile` and is unmapped in `close()` (the naive
  map-decode-unmap segfaulted; reopen/lazy-history tests caught it).
  Measured on a66.4 MB /100k store (interleaved A/B,5 rounds,
  spawn→first response): **315.5 →231.5 ms median (−84 ms, −27%)**.
  VmRSS unchanged by design (file pages count either way) — the memory
  win is reclaimability (clean file-backed vs pinned anonymous arena).
  Byte-identity: fixtures + reopen suite + exp01–exp11 =57/57 +
  tcp_probe IDENTICAL.
- **Ingest O(n²) removed — deferred insert queue (worst case ≈77×)** —
  `EngineStore.pending`: O(1) seq-tagged pushes (any id order), sorted
  + merged once per write burst at every reader seam (executeStatement
  reader arm / `toIr` / WAL-replay end / `replayAsOf` / `dumpStore`),
  deterministic last-write-wins, pure-append fast path. `bench-ingest`
  @100k: reverse ids **19.19s → ~0.25s**, lex1.77s → ~0.28s, insert
  flat ~1 µs/row for ALL orders (was191.9 µs/row worst); flush =
  ~60–230 ms once per burst (noise-bound on this box). A first-draft
  per-insert pending scan re-introduced the quadratic (14.8 s — why
  dedup lives at flush, keyed by seq). Gates: suite (incl. upsert-LWW /
  forget / replay / AS OF) + **exp01–exp11 =57/57** + tcp IDENTICAL.

- **Harness default flip — zig runs all three legs out of the box** —
  `NQL_IMPL` now *opts out* (`=rust`) instead of opting in; unset (or
  `=zig`) = zig for server + CLI + MCP (`nqlite_zig --mcp`).
  Precedence unchanged: explicit `NQL_*_BIN` > `NQL_IMPL` > default.
  Evidence binding records the RESOLVED profile (default → `zig`,
  `NQL_IMPL=rust` → `debug`, cross-wired → `mixed`). Gates: default
  `run_all exp05 exp09` failures 0 with `profile: zig`; opt-out
  failures 0 with `profile: debug`; explicit exp01–exp11 parity
  **57/57**. (The experiments README section describing the old flag
  semantics is the user's active editor file — handed over as a patch.)

- **Spec pin → `a1ed5ff` — file-extension split (`.ndb` vs `.nql`)** —
  the store is now the **neural database file** (`.ndb`; sidecars
  `.ndb.wal` / `.ndb.lock`), while **`.nql` is reserved for NQL program
  files** (spec/nql.md "File conventions"; file-format.md "Extensions").
  Contract files renamed in place: golden fixtures `*.nql` → `*.ndb`
  (bytes unchanged — content is the oracle), manifest + fixtures README,
  `fixtures.zig` `FIXTURES`, `check-spec-sync.sh` list; test store
  paths updated. Content-addressed format → **no runtime change**, old
  `.nql`-named stores stay valid.

### Added

- **TCP mode (`--tcp`) — nql-server's default transport** — listen on
  `127.0.0.1:$PORT` (env `PORT`, default 7878): one shared server
  (database) across connections, **sequential accept** (the reference's
  "deterministic for sequential/single clients" design), one program
  per line → response flushed per line; a disconnect ends only that
  connection. `--db` opens once (single-writer lock held for the
  process); stderr banner `nqlite_zig listening on …`. Parity probe
  `scripts/tcp_probe.py` byte-compares Rust-vs-zig transcripts
  (queries + reconnect persistence) over real sockets. Mode
  divergence: the zig binary stays CLI-first — TCP is opt-in via
  `--tcp` (nql-server makes it the no-flag default; `USAGE` is
  untouched = the nql CLI contract, test-pinned).

- **MCP stdio server (`--mcp`) — the last leg of `NQL_IMPL=zig`** —
  `nqlite_zig` now speaks the MCP protocol directly: a hand-rolled
  newline-JSON-RPC loop (no rmcp/tokio — wire contract captured from
  the reference: `initialize` → rmcp `3.5.1` handshake, `tools/list`
  with the8 tools in alphabetical order + byte-identical
  descriptions/schemas, `tools/call` for all8), a serde_json
  `to_string_pretty`-shaped payload printer (2-space indent, sorted
  map keys, widened-shortest floats, `0.0` never `0`), the reference's
  exact messages (`OK` / `ERR {e}` / `invalid record id …` /
  `steps must contain at least one hop` / `ERR unknown ORDER BY …`),
  `MATCH {start}` kind labels (no hops — unlike the line protocol),
  `-32601` for unknown methods, notifications answered with silence.
  Reuses `cli.Session` — the shared Database path (lazy history + WAL
  duties) after extracting `Session::execPlan` from the CLI runner.
  **Oracle-proven: deep-equal against the captured `nql-mcp`
  responses on every value** (handshake, all schemas, execute_nql +
  select payloads, stderr banner); exp09 `mcp_parity` green fully-on
  (`NQL_IMPL=zig`: tools_present, as_of_via_nql, memory_via_nql,
  deterministic_results, select_tool_as_of_param all ✓) and the
  explicit-11 parity holds **57/57** with MCP flipped. The flag now
  selects **all three legs: server + CLI + MCP**. +5 tests (46 total).

- **CLI (`--script` / REPL / `--db`)** — `nqlite_zig` now carries the
  reference `nql` CLI surface: parse → execute with **no analyzer pass
  and no cross-line context** (`Session::run` parity), CLI result
  format (`label (N rows)` + two-space-indented rows, Rust
  half-to-even scores), `error: …` on stdout, byte-exact banner / HELP
  / `:flush`→`flushed` / `:store` / `:clear`, and `--db` WAL +
  checkpoint through the shared `server.walAfterPlan` (extracted from
  handleLine — one hook, both frontends). **Stdout byte-identical to
  `nql`** on script and REPL probes (kNN / AS OF / HISTORY SINCE /
  parse-error / `:store` / trailing blank line); `NQL_IMPL=zig` flips
  the CLI legs too — exp05/exp08/exp10 green fully-on with
  `profile: zig` — while `nql-mcp` stays Rust. +6 golden tests
  (44 total).

## [0.1.0] - 2026-10-08

First release: the complete nqlite → Zig migration (PLAN M0–M9).

### Added

- **M9 kit — flagged default (`NQL_IMPL=zig`)** — the harness now
  selects the zig server as its default behind an opt-in flag
  (precedence: explicit `NQL_SERVER_BIN` > `NQL_IMPL=zig` > Rust;
  auto-builds ReleaseFast when missing). Demo: all 11 experiments
  green (failures 0, deterministic) with the flag ON; report binding
  now records the RESOLVED selection (`mixed` = zig server + Rust
  CLI/MCP — the flag is server-only, since `nqlite_zig` is
  `--stdio`-only). The unset-default flip happens at release.

- **ADR-002 — knot seam decided (cutover criterion ✓)** — knot keeps its
  **in-process Rust `nql`/`nqlite` linkage** for v1/v1.x (git deps,
  `Database::open`/`execute`, error-type contract asserted by its own
  load tests); **zig reaches knot only via the wire** (line protocol /
  future TCP) — house rule *transports over linkage*. Any switch = a
  future ADR with operations evidence (sidecar lifecycle/locking or
  FFI). PLAN open decision resolved; cutover criteria now leave only
  *release tagged* outstanding.

- **Importer proof — cutover criterion ✓** — the E08 100k store is
  built exactly as `exp08` does (chunked `nql --db` → v3) and migrated
  with `nql-migrate`; answers for7 query kinds (count / kNN / BM25 /
  hybrid / LIMIT / AS OF / HISTORY SINCE) are **byte-identical**
  between Rust-on-v3 (pre-migration) and **this implementation serving
  the migrated v4** (post-migration + cross-impl file compatibility at
  scale; `history = 100001` hard-asserted). Driver:
  `nqlite-experiments/scripts/prove_migrate_100k.py` →
  `results/migrate_100k.json`. The first run caught two reference-side
  checkpoint bugs (nqlite **#155/#156** — lazy-tail history silently
  rewritten as empty); Rust serving the migrated v4 **landed in nqlite
  #157/#158** (v4 open + version-preserving checkpoint) — the proof now
  runs the full **v3(rust) == v4(rust) == v4(zig)** triangle.

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
