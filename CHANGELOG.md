# Changelog

All notable changes to nqlite-zig are documented here, newest first.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning starts at 0.0.x until the cutover criteria in [PLAN.md](PLAN.md)
are met.

## [Unreleased]

### Added

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
