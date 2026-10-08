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

- ~~SIMD exact kNN~~ — **superseded**: top-k selection got kNN to
  49 ms @100k (beats the reference band); literal SIMD on the cosine
  loop remains optional (see M8+ below).
- **mmap open** (plan M8's ceiling target): deferred — the decode path
  was the actual open bottleneck (see M8+ attribution below).
- ~~BM25 index rebuilt per query~~ — **fixed in M8+** (version-keyed
  cache); see below.
- **Ingest** uses sorted-insert memmove (O(n²) worst case) — flat
  enough through 100k (13k TPS) but will bend at bigger stores.
- **MATCH/CLOSURE adjacency index** — edge scans are linear per step;
  not on exp08's path, deferred with the experiment suites still green.

## M8+ results (2026-10-08) — query ceiling + open attribution

All numbers below: same machine/profile bindings as above (ReleaseFast,
Xeon box — note: the box was running a heavy neighbour workload,
load ≈ 17/32, so small numbers carry ±noise; trends are large enough
to be sound). Probe: `scripts/probe_ceiling.py` / `scripts/probe_reopen.py`.

### Query pipeline @100k (median of 7)

| query | before | after | mechanism |
| --- | ---: | ---: | --- |
| kNN k=10 | 143 ms | **49 ms** | top-k windowed selection (heap, window ≤ n/8) instead of full sort |
| BM25 k=10 | 263 ms | **80 ms** | version-keyed index cache + binary-search tf/df |
| hybrid (RRF) | 496 ms | **326 ms** | both of the above (fusion still needs two full rankings for ranks) |
| `ORDER BY … LIMIT 10` | 75 ms | **40 ms** | top-k selection |
| full-scan + response100k | 551 ms | ~550–660 | response formatting (deferred; fits budget) |

**kNN @100k = 49 ms beats the reference band (Rust release75–140 ms)** —
the plan's "exact kNN ≥ Rust" cutover criterion. All changes are
byte-safe by construction (total-order comparators; fusion keeps the
identical `+=` sequence) and verified: **`compare_impls --all` = 57/57
digests across all 11 experiments, exit 0.**

### Open path @100k (attributed with in-process phase timers)

| phase | ms | note |
| --- | ---: | --- |
| file read (62.5 MB) | 43–76 | page-cache warm |
| `v4.decode` | 200–345 | **before the CRC fix, `dir+crc` alone was253 ms (66%)** — the byte-at-a-time CRC ran at ~247 MB/s |
| ├ dir + section CRCs | **100 after slice-by-8** | same IEEE algorithm, bit-identical (vectors + fixture/WAL gates) |
| ├ records | 55–103 | bodies + embeddings |
| └ history | 75–141 | eager today — lazy decode is the next lever |
| `fromIr` (100k inserts) | 58–84 | canonical append order |
| WAL replay + seed | 6–9 | |
| **process reopen (spawn → first response)** | **~305–330 best-of-3** (was ~460–625) | vs Rust reference: cold ~459 / warm ~260 |

### Open: what's still deferred

- ~~Lazy history decode~~ — **done in M8b below**.
- **CRC32 SIMD** (crc32fast-class, ~5–10× over slice-by-8): −80…−90 ms.
- **mmap** instead of read-into-arena.
- The in-test attribution harness (phase timers inside a `zig build
  test`) proved unreliable at `-Ofast` under machine load (a false
  “hang”); server-side phase timers + the reopen probe were the
  workable method — use those.

## M8b results (2026-10-08) — lazy history seam

The reference's issue #133 design, ported: `decodeCore` skips the
HISTORY section (records its range), `ensureHistory` decodes it once
and prepends file frames to the WAL-era log at the first temporal use
(`needs_history`: AS OF / HISTORY SINCE / PRUNE at the server), before
replaying a PRUNE WAL frame, and before every checkpoint (so a rewrite
can never drop the file era).

| phase (62.5 MB /100k store) | eager | lazy |
| --- | ---: | ---: |
| `v4` decode | 345 ms | **204 ms** (`decodeCore`, history ≈140 ms deferred) |
| hist range recorded | — | `hist != null` until first temporal read (one-shot, unit-pinned) |
| process reopen | ~305–390 | ~387–394 measured — **noise-bound on this box** (read43–83 + core204 + fromIr58–84 + spawn≈15; the box's neighbour workload moves totals ±90 ms run-to-run) |

Byte-parity is the proof that matters: **full `--all` =57/57** with
exp05 (reopen + AS OF), exp07 (temporal sweeps) and exp10 (forensics
AS OF) byte-identical through the seam, plus the two new seam tests
(temporal-after-reopen; PRUNE-in-WAL-with-main edge — without the
ensure, compaction would drop file-era declarations).
