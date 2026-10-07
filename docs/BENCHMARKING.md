# Benchmarking (nqlite-zig)

House rule (plan M8): **every published number binds to commit, profile
and machine** — a number without its bindings is an anecdote.

## Bindings

| | |
| --- | --- |
| Machine | Intel Xeon E5-2640 v4 @ 2.40 GHz (32 threads), 64 GB RAM, Linux x86_64 |
| Date | 2026-10-07 |
| Profiles | zig **ReleaseFast** (`zig build -Doptimize=ReleaseFast`) for all numbers below; the parity reference runs `nqlite/target/debug/nql-server` (harness default) |
| Commit | M8 work — see the `M8` CHANGELOG entry / PR for the exact sha |
| Artifacts | `nqlite-experiments/results/exp08_scale_ladder.json` (harness metrics), `nqlite-experiments/results/parity_rust_vs_zig.json` (57/57 digest report), probe: `nqlite-experiments/scripts/profile_query_mix.py` |

Reproduce:

```bash
zig build -Doptimize=ReleaseFast
python3 scripts/profile_query_mix.py 1000,5000,20000,100000   # query-mix probe
python3 scripts/compare_impls.py exp08 --b ../nqlite-zig/zig-out/bin/nqlite_zig
python3 scripts/compare_impls.py --all                        # full wire parity
```

## M8 results (2026-10-07)

### The problem the gate caught

`compare_impls.py exp08` reported **B-TIMEOUT**: the scale ladder
(ingest → kNN/BM25/hybrid medians → scan at 1k/5k/20k, `QUERY_REPS=10`)
exceeded the300 s per-side limit on the zig binary *even in ReleaseFast*.
Profile at 20 k rows (median of 10, warm cache):

| phase | before | after | speedup |
| --- | ---: | ---: | ---: |
| kNN (k=10) | 3 920 ms | **31 ms** | ×125 |
| BM25 (k=10) | 2 906 ms | **68 ms** | ×43 |
| hybrid (BM25+kNN RRF) | 16 819 ms | **180 ms** | ×93 |
| full scan (projection) | 80 ms | ~80–150 ms | — |
| ingest (50-stmt lines) | 1.74 s (11.5k TPS) | 1.18 s (16.9k TPS) | ×1.5 |

All three query regressions were **quadratic** (×5 rows → ×19 time):

1. **Insertion sorts on corpus-sized slices** (`ORDER BY` / kNN / RRF
   lists) → `std.mem.sortUnstable` (PDQ). Every comparator ends in a
   unique-key `RecordId` tie-break — a *total order* — so the sorted
   result (and therefore every transcript byte) is unchanged.
2. **Per-row id scans**: `computeScore` linear-searched the kNN and
   fusion lists for every candidate, `vector_l` re-derived kNN scores by
   id scan, `upsertFused` linear-searched a growing list — all replaced
   by **candidate-aligned dense arrays** (positions via binary search on
   canonical order). Fusion accumulates in the identical `+=` sequence,
   so f32 sums stay bit-identical.
3. **BM25 index build**: the `df` table was re-sorted *inside the
   per-doc loop* (`O(n_docs · |df| log |df|)`); `score()` linear-scanned
   docs per row. Sort now happens once after the merge (df is read by
   token equality — order never affects scores), and doc lookup is a
   binary search over canonical order.

### Final ladder (ReleaseFast, this machine)

| rows | ingest | kNN | BM25 | hybrid | scan |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 000 | 0.04 s (24.7k TPS) | 1.3 ms | 2.0 ms | 3.5 ms | 6 ms |
| 5 000 | 0.27 s (18.6k TPS) | 9.7 ms | 19.4 ms | 20.4 ms | 19 ms |
| 20 000 | 1.18 s (16.9k TPS) | 31.5 ms | 67.7 ms | 180 ms | 148 ms |
| 100 000 | 7.68 s (13.0k TPS) | 205 ms | 381 ms | 778 ms | 571 ms |

### Gates

- **E08 parity: 4/4 digests byte-identical** (`exp08_scale_ladder`,
  both sides complete well inside the limit; was `B-TIMEOUT`).
- **Full wire parity: 57/57 across all 11 experiments**, `--all`
  exit 0 — including every float-sensitive kNN/BM25/hybrid score at
  every ladder size.
- All unit/fixture/corpus/golden gates green (34 tests) in the same
  commit as the optimizations.

### Known gaps / deferred (honest list)

- **SIMD exact kNN** and **mmap open** (plan M8's ceiling targets):
  deferred — zig kNN @100k is205 ms vs the plan's single-digit-ms
  ambition; profile shows the f32 cosine loop as the next candidate
  (SIMD) and the v4 decode path as the reopen candidate (mmap).
- **BM25 index is rebuilt per query** (parity with the reference's
  behavior); at ≥100k a cached index keyed on store state is the next
  lever (~381 ms → likely tens of ms).
- **Ingest** uses sorted-insert memmove (O(n²) worst case) — flat
  enough through 100k (13k TPS) but will bend at bigger stores.
- **MATCH/CLOSURE adjacency index** — edge scans are linear per step;
  not on exp08's path, deferred with the experiment suites still green.
