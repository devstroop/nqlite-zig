# ADR-001: charter — determinism-by-hand and toolchain policy

- Status: accepted
- Supersedes: —

## Context

nqlite-zig is a second implementation of nqlite (the Rust engine stays
canonical until parity gates pass — PLAN.md). Two properties of Zig force
charter-level decisions *before* the first engine line is written:

1. **No ordered map in Zig std.** The Rust engine's observable ordering
   (every `ORDER BY`, replay, transcript digest) partly rides on `BTreeMap`'s
   sorted iteration. Zig's std has hash maps with unspecified bucket order —
   deterministic output becomes something this codebase enforces by hand.
2. **Toolchain churn.** The scaffold itself broke across two Zig majors
   (0.15 → 0.17: `b.args`, `std.fs.File.stdout()`, `testing.fuzz` signature)
   before any project code existed. Unpinned Zig would make builds a moving
   target.

The spec (`spec/`, vendored from devstroop/nqlite) and the E01–E10 harness
are the language-neutral contracts; this ADR pins how this repo stays inside
them.

## Decision

1. **Toolchain pinned twice**: `.zigversion` (0.17.0, CI asserts
   `zig version` equality) and `build.zig.zon`
   `minimum_zig_version`. Upgrades move both pins in one PR, full gates
   first.
2. **Determinism-by-hand rules** (enforced in review, then by gates):
   - Never iterate a hash map into observable output. Small tables =
     sorted arrays; large = explicit sort with a total order at the
     boundary.
   - Canonical tie-break for records = **RecordId string order** —
     byte-identical to the Rust engine's `BTreeMap<RecordId, _>` order.
     Matching this is what lets M5 compare `transcript_sha256` directly.
   - Float/format rendering follows the wire contract (4-decimal
     probabilities, Python-compatible JSON where the spec says so —
     `pyjson` semantics).
3. **Spec flows nqlite-first**: `spec/` is a vendored copy pinned by
   `.spec-pin`; CI runs `scripts/check-spec-sync.sh` and fails on drift.
   A spec change = nqlite PR first, then a deliberate pin bump here
   (`.spec-pin` + `spec/` in the same commit).
4. **Validation order**: golden fixtures (exported from the Rust engine,
   the current canonical writer) → harness gates (E01–E05 at M4, full
   E01–E10 + digest equality at M5). Failing a digest gate blocks merge —
   same discipline as the parent repos.
5. **Out of scope until revisited**: knot integration (sidecar/FFI),
   WASM packaging, publishing to any registry.

## Consequences

- Slower start: sorted-array discipline everywhere instead of reaching for
  a hash map; paid back by transcript-digest parity being *checkable*.
- Two pins to maintain on Zig upgrades; the first 0.15→0.17 breakage was
  the proof, before code existed.
- If a future Zig version changes std APIs under us, the fix is a pinned
  bump PR with green gates — never an ambient upgrade.
