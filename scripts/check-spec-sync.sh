#!/usr/bin/env bash
# Fail if the vendored spec/ drifts from the pinned nqlite commit (.spec-pin).
# The spec lives in devstroop/nqlite (canonical owner); nqlite-zig vendors a
# pinned copy and CI re-checks it — spec changes flow nqlite-first, then land
# here as a deliberate pin bump (same change updates .spec-pin + spec/).
set -euo pipefail
cd "$(dirname "$0")/.."

PIN=$(cat .spec-pin)
BASE="https://raw.githubusercontent.com/devstroop/nqlite/${PIN}/spec"
fail=0
for f in nql.md file-format.md; do
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
