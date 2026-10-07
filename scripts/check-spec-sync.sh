#!/usr/bin/env bash
# Fail if the vendored spec/ drifts from the pinned nqlite commit (.spec-pin).
# Spec + golden fixtures live in devstroop/nqlite (canonical owner); nqlite-zig
# vendors a pinned copy and CI re-checks it — spec changes flow nqlite-first,
# then land here as a deliberate pin bump (same change updates .spec-pin + spec/).
set -euo pipefail
cd "$(dirname "$0")/.."

PIN=$(cat .spec-pin)
BASE="https://raw.githubusercontent.com/devstroop/nqlite/${PIN}/spec"
fail=0
# file-format.md (§5) + the format-v4 golden-fixture oracle (§5.7: the
# fixtures ARE the contract where prose is ambiguous).
for f in nql.md file-format.md \
         fixtures/v4/README.md fixtures/v4/empty.nql fixtures/v4/plain.nql \
         fixtures/v4/rich.nql fixtures/v4/pruned.nql \
         fixtures/v4/statements.json fixtures/v4/manifest.json; do
  tmp=$(mktemp)
  if ! curl -sSf --max-time 30 "${BASE}/${f}" -o "$tmp"; then
    echo "spec-sync: cannot fetch ${BASE}/${f}" >&2
    fail=1
    continue
  fi
  if ! diff -u "spec/${f}" "$tmp" >&2; then
    echo "spec-sync: spec/${f} drifted from devstroop/nqlite@${PIN}" >&2
    fail=1
  fi
  rm -f "$tmp"
done
if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "spec-sync: spec/ in sync with devstroop/nqlite@${PIN}"
