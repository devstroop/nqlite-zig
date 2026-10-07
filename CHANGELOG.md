# Changelog

All notable changes to nqlite-zig are documented here, newest first.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning starts at 0.0.x until the cutover criteria in [PLAN.md](PLAN.md)
are met.

## [Unreleased]

### Added

- **M0 bootstrap** — repository scaffold on **Zig 0.17.0** (pinned in
  `.zigversion` + `minimum_zig_version`; CI enforces the match): package
  module `nqlite_zig`, starter executable, test wiring (`zig build` /
  `zig build test` / `zig fmt --check` all green), vendored nqlite spec at
  pin `3aad8d0` with CI drift check (`scripts/check-spec-sync.sh`),
  charter ADR-001 (determinism-by-hand + toolchain policy), PLAN with
  milestones M0–M9 and cutover criteria, Apache-2.0 license.
