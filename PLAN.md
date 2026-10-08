# nqlite-zig Plan

Milestone plan. House rules (mirrored from both parent repos): one milestone
per PR; SPEC-first — behavior changes land in `spec/` (via the nqlite pin
bump) before code; gates below are *exit criteria*, not aspirations.

| ID | Milestone | Scope | Exit gate |
|---|---|---|---|
| **M0** | Bootstrap | toolchain pin (0.17.0), CI (fmt/build/test/spec-sync), charter ADR-001, vendored spec, PLAN/README/CHANGELOG | CI green; spec-drift check red on tamper |
| **M1** | Values + format v4 | `Value`/`RecordId` (traps as required tests: digit-first ids, `-` splitting, dangling edges), zero-copy v4 writer/reader + mmap-friendly layout; **v4 spec PR in nqlite (track A)** | golden byte fixtures (Rust-exported) round-trip exact |
| **M2** | NQL parser | lexer/parser/analyzer port; AST golden corpus exported from Rust `nql::parse` | corpus green + grammar-trap tests (comments, `id`, escapes) |
| **M3** | Engine core (in-memory) | SELECT/INSERT/RELATE/FORGET/COUNT/OFFSET/ORDER BY (`cmp_total` semantics), vectors exact scan | unit + golden result-JSON parity |
| **M4** | Line server (stdio/TCP) | line-protocol server binary | **first harness gate: E01–E05 green via `NQL_SERVER_BIN`** |
| **M5** | Harness parity | full suite | **E01–E10 green AND `transcript_sha256` == Rust digests** |
| **M6** | Persistence | v4 + WAL + CRC, single-writer flock, reopen; **v3 importer** | persistence suite green + **import answers identical on the E08 100k store ✓** (2026-10-08: `nqlite-experiments/scripts/prove_migrate_100k.py` — **v3(rust) == v4(rust) == v4(zig)** triangle, `history = 100001`; surfaced reference checkpoint fixes nqlite #155/#156; Rust serving v4 ✓ nqlite #157/#158) |
| **M7** | Temporal & graph | AS OF / HISTORY SINCE / PRUNE incl. `HistoryPruned` contracts; MATCH/CLOSURE + AS OF | E07-style rotation-equivalence checks green |
| **M8** | Performance | **landed**: O(n log n) sorts, candidate-aligned kNN/RRF lookups, BM25 build/score fixes, top-k selection + index cache + slice-by-8 CRC + **lazy history decode** (bound numbers: docs/BENCHMARKING.md); **deferred**: SIMD CRC/kNN, mmap, adjacency index | **E08 gate: 4/4 + full parity 57/57** (was `B-TIMEOUT`); **kNN @100k49 ms beats Rust75–140**; open decode345→204 ms (`decodeCore`), seam unit-pinned |
| **M9** | Cutover kit | experiments default flip (flagged ✓ — `NQL_IMPL=zig` flips **server + CLI**; MCP stays Rust), knot sidecar ADR (**ADR-002 ✓**), optional WASM spike, release ✓ (**v0.1.0**) | cutover criteria met (below) |

## Parallel tracks (worktrees)

`/root/ai-workspace/worktrees/<repo>-<track>` — one branch = one worktree;
main checkouts stay clean and buildable for harness runs.

- **A** — format-v4 spec PR in `devstroop/nqlite` (∥ everything)
- **B** — SIMD exact-scan spike in `devstroop/nqlite` (∥ everything)
- **C** — M0→M3 in this repo (M0 blocks only zig milestones)
- After M4: tests ∥ docs ∥ perf worktrees.

## Cutover criteria (coexistence → default)

E01–E11 digests equal ✓ (57/57) · persistence gates green ✓ · v3 importer
proven on the 100k store ✓ (`prove_migrate_100k.py`, history=100001) ·
perf ≥ Rust on open + exact kNN ✓ (kNN 49 ms @100k; open attributed +
lazy + slice-by-8 CRC) · knot sidecar ADR written ✓ (**ADR-002**: keep
Rust linkage for knot) · release tagged ✓ (**v0.1.0**, cut on this merge).

## Open decisions (deliberately unresolved)

- ~~Whether the Zig engine ever becomes the default for knot's audit seam~~
  — **resolved by ADR-002** (2026-10-08): knot keeps in-process Rust
  linkage; sidecar-over-wire / FFI only via a future ADR with
  operations evidence.
- WASM/edge packaging (nqlite-in-the-worker) — spike only after M8.
- Zig version bumps (0.18) — deliberate PR moving both pins, with a
  full-gate run first.
