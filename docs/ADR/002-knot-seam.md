# ADR-002: knot keeps in-process Rust linkage — zig reaches it only via the wire

- Status: accepted
- Supersedes: —
- Related: ADR-001 (charter — scoped knot out of v1; this is the deferred record)

## Context

`knot-nqlite` (the audit adapter, used by `knot-serve`) integrates nqlite
**as a library, in the same process**:

| seam layer | what it actually is |
| --- | --- |
| dependency | git deps on `nql` + `nqlite` (`devstroop/nqlite`) |
| storage | `Database::open(&path)` — the Rust file format (v2/v3/v4 since nqlite#157) |
| execution | `nql::parse` → `db.execute(&plan)` → `nqlite` error/result types |
| contract surface | the spec's semantics directly — its load tests assert the retention contract itself (`PRUNE HISTORY` binding history, `AS OF` failing with `HistoryPruned`, durability counts) |

The migration (PLAN.md M0–M9) adds a **second implementation** of the
same spec. The two engines share the language-neutral contracts —
`spec/`, the golden fixtures, the E01–E11 harness (**57/57 transcripts
byte-identical**) and the importer proof (`nql-migrate` output served
identically by both) — but they cannot share *linkage*: a Rust consumer
cannot link a Zig binary. ADR-001 scoped the knot seam out of v1 and
plan decision 4 (2026-10-07) deferred this record; the cutover criteria
require it, explicitly allowing "keep Rust for knot" as an outcome.

## Decision

1. **`knot-nqlite` keeps linking the Rust `nql` + `nqlite` crates
   in-process for v1 / v1.x.** The seam stays a crate boundary: storage
   (`Database::open`), execution (`execute`), and error types
   (`nqlite::Error`, e.g. `HistoryPruned`) are Rust-crate APIs, not wire
   APIs — and knot's own contract tests bind to exactly those. Cutover
   of the *default* implementation elsewhere does not disturb this pin;
   the Rust crate remains canonical and released during coexistence.

2. **Zig reaches knot only through the wire** — the spec'd line
   protocol (`nqlite-zig --stdio`, future TCP) behind a transport,
   never through FFI, WASM, or an in-process shim. House rule:
   *transports over linkage*. Every cross-implementation integration so
   far went through the wire with byte-level evidence; a linkage story
   would have none of that machinery.

3. **A switch, if ever justified, is a transport decision with its own
   ADR**: sidecar-over-line-protocol (process lifecycle, single-writer
   locking, health, deployment) or FFI (ABI/unwind/safety). Both are
   *operations* questions — evidence methodology exists (knot's own
   ADR-006 load-test ladder is the template), and the byte-parity gate
   that would validate the engine half already runs green.

## Consequences

- **knot users see zero change** from this record: same crates, same
  semantics, same storage files — the audit adapter's behavior is
  pinned by the Rust crate for the coexistence period.
- **Two engines coexist with knot on one of them.** Alignment is the
  spec + shared harness (57/57) + fixtures + the importer proof
  (`v3(rust) == v4(rust) == v4(zig)` on the E08 100k store). A
  migrated store (`nql-migrate` output) is readable by **both** sides
  since nqlite#157/#158 (v4 open + version-preserving checkpoint) —
  knot may consume v4 inputs directly, and the zig server reads them
  natively.
- **Nothing here blocks cutover**: the criteria wanted this decision
  *recorded*, not a migration. The M9 default-flip applies to the
  experiments/harness layer, which already dual-runs both engines.

## Revisit when

- nqlite would deprecate the Rust crate (not planned), **or**
- knot's audit path has a measured need for the zig engine (perf /
  memory) *and* a sidecar ops story is proven with load evidence
  (ADR-006-style), **or**
- a stable FFI/WASM story exists (plan: spike-only after M8).

Until then: **link Rust, transport Zig.**
