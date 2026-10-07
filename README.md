# nqlite-zig

A Zig implementation of [nqlite](https://github.com/devstroop/nqlite) — the
context-first, deterministic, single-file database for AI agents (records,
typed graph relations, BYO embeddings, time; one ACID transaction; No-LLM by
contract).

**Status: M0 bootstrap.** The Rust engine remains canonical while this port
converges behind parity gates — see [PLAN.md](PLAN.md) for milestones and
cutover criteria. Until those gates pass, use `devstroop/nqlite`.

## Why a second implementation exists

The contracts that make nqlite *nqlite* are language-neutral: the
[grammar/spec](spec/nql.md), the E01–E10 validation harness (transcript
digests, forensics sweeps, rotation equivalence), and golden fixtures. Zig is
pursued for the storage core's hot spots — mmap-style open, SIMD exact scan,
tight allocation control — while the harness and the spec define done, not a
calendar (charter: [docs/ADR/001-charter-and-toolchain.md](docs/ADR/001-charter-and-toolchain.md)).

## Toolchain

- **Zig 0.17.0** — pinned twice: [.zigversion](.zigversion) (checked by CI
  against `zig version`) and `minimum_zig_version` in `build.zig.zon`.
  Upgrades are deliberate PRs that move both pins.

## Build & test

```sh
zig build          # library + starter executable
zig build test     # test blocks (src/root.zig, src/main.zig)
zig fmt --check .  # house gate
```

## Layout

```
build.zig(.zon)   package + modules (nqlite_zig)
src/              library root (root.zig) + starter executable (main.zig)
spec/             VENDORED copy of nqlite's spec, pinned by .spec-pin
scripts/          check-spec-sync.sh (CI drift check vs devstroop/nqlite)
docs/ADR/         append-only decisions (charter, toolchain, format)
PLAN.md           milestones M0–M9 with exit gates
```

## Validation (how "done" is defined)

1. **Spec sync** — `spec/` is a pinned mirror of `devstroop/nqlite`'s spec;
   CI fails on drift (`scripts/check-spec-sync.sh`). Changes flow
   nqlite-first, then land here as a deliberate `.spec-pin` bump.
2. **Golden fixtures** — exported from the Rust engine (the current
   canonical writer); byte-exact round-trips are the format gate.
3. **Harness parity** — `nqlite-experiments` drives any server via
   `NQL_SERVER_BIN=…`; M4/M5 require E01–E05 then E01–E10 green with
   `transcript_sha256` equal to the Rust runs' digests.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
