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
- ~~mmap open~~ — **done (see "mmap results" below)**: decode reads a
  whole-file read-only mapping directly (read path kept as fallback).
- ~~BM25 index rebuilt per query~~ — **fixed in M8+** (version-keyed
  cache); see below.
- ~~Ingest sorted-insert memmove (O(n²) worst case)~~ — **done:
  deferred insert queue (below)** — reverse-id worst case19.2s →
  ~0.25s @100k.
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
| full-scan + response100k | 551 ms | **zig-side ≈55 ms** (engine27 + format28, in-process) | formatting −5× (M8++) + projection zero-alloc; the external row was mostly **harness-python parsing the5 MB line** + box noise — see M8++ |

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
- ~~CRC32 SIMD~~ — **done: PCLMULQDQ path,10.7× over slice-by-8**
  (see "CRC SIMD results" below).
- ~~mmap~~ instead of read-into-arena — **done (below)**.
- The in-test attribution harness (phase timers inside a `zig build
  test`) proved unreliable at `-Ofast` under machine load (a false
  “hang”); server-side phase timers + the reopen probe were the
  workable method — use those.

## M8++ results (2026-10-08) — response formatting (the M8+ deferral, closed)

**Method** (the only one this box's neighbour load leaves trustworthy):
in-process micro-bench, `zig build bench-format -Doptimize=ReleaseFast` —
`formatResult` over100k probe-shaped rows (one string field, scores with
an exact4dp tie), median of7. **External** process timing of the same
work swings ±2× run-to-run (an interleaved A/B of old/new binaries
measured291–647 ms for identical code) — do not cite it.

| metric (100k rows,3.96 MB response line) | before | after |
| --- | ---: | ---: |
| `formatResult` in-process median | **138.34 ms** | **27.78 ms (5.0×)** |
| heap allocations per row | ~6 (id, score, fields, template) | **0** (stack scratch + one buffer) |

Mechanism: one pre-sized response buffer; `score4Into`/`idInto`/
`fieldsInto`/`shortValueInto`/`debugStrInto` append into it (the math is
byte-identical — same half-to-even tie rule, same escaping; pub wrappers
keep `rustFormat4`/`formatFields` for CLI/MCP callers). Byte-proof:
golden/transcript tests + explicit exp01–exp11 digests + `tcp_probe`.

**Second pass — engine select attribution (`zig build bench-query`)**,
also median-of7 ×100k synthesized rows, in-process:

| shape (`SELECT … FROM doc`,100k rows) | before | after |
| --- | ---: | ---: |
| star (`SELECT *`) | 22–25 ms | (unchanged) |
| projection (`SELECT topic`) | **48.0 ms** | **27.0 ms** |
| filter (`WHERE topic = …`,25k matches) | 12–14 ms | (unchanged) |

Projection kept a per-row `ArrayList` (`kept.append` =2–4 heap allocs
per row); now fully-kept bodies reuse the same slice (zero alloc),
empty results share one static slice, partial matches copy once.

**Attribution correction (replaces the earlier note)**: formatting was
~138 ms of the old551 ms full-scan+response row — engine select was
NEVER the dominant cost (27–48 ms). The external row is dominated by
**harness-python parsing the multi-MB response line** plus box noise
(an interleaved old/new A/B measured291–647 ms for identical code).
Zig-side full-scan pipeline today: engine ≈27 + formatting ≈28 ≈
**55 ms @100k rows** (was ≈48 +138 ≈186 ms). Remaining zig-side
open item by honest size: ingest O(n²) beyond100k (CRC and mmap both
landed below — CRC −85 ms of reopen, mmap −84 ms of open).

## CRC SIMD results (2026-10-08) — PCLMULQDQ, the crc32fast-class lever

**Method**: `zig build bench-crc -Doptimize=ReleaseFast` — both paths on
the same 64 MB buffer, back-to-back in-process (median of7). The XOR
checksum across the two loops cancels to0, i.e. **identical outputs in
the same run**, on top of the every-length ladder test, golden fixtures,
WAL frames and exp01–exp11 digests.

| path | time (64 MB ×7) | throughput |
| --- | ---: | ---: |
| slice-by-8 (baseline/CI/non-x86) | 100.16 ms | 670 MB/s |
| **PCLMULQDQ** | **9.37 ms** | **7158 MB/s** |
| | | **10.68×** |

Impact: section CRCs at open are ~62.5 MB → the CRC share of
`dir+crc ≈100 ms` drops to ~9 ms (**−85 ms** on reopen; the earlier
"−80…−90" estimate is now MEASUREED, not assumed).

Implementation notes (why C): the crc32fast1.5.2
`specialized/pclmulqdq.rs` algorithm ported **verbatim** (K-constants,
fold-by-4, runtime tail masks, step-3 + Barrett) to
`src/crc32_simd.c` — clang's per-function `target("pclmulqdq,...")`
does what Rust's `#[target_feature]` does. zig inline asm was the dead
end (the self-hosted encoder only assembles baseline features), and
zig's vendored `<emmintrin.h>` chains into libc — so the file is
header-free: one builtin (`__builtin_ia32_pclmulqdq128`) + vector
extensions + scalar helpers for the cold shuffles. Runtime gate =
`usePclmul()` (cpuid leaf1 ECX bit1), cached once; non-x86 builds never
reference the symbol (comptime arch gate + build.zig only attaches the C
on x86).

## mmap results (2026-10-08) — read-into-arena → read-only mapping

**Mechanism**: `StoreFile.loadMain` (and the lazy `takeHistory` re-read)
now decode straight from a whole-file read-only `posix.mmap`
(`MAP_PRIVATE`, page-aligned length) instead of `alloc +
readPositionalAll`. The decode is zero-copy — the store BORROWS the
bytes — so the mapping lives on `StoreFile` and is unmapped in
`close()` (an earlier "map, decode, unmap" attempt segfaulted exactly
there: table names dangle after unmap — the reopen/lazy-history tests
catched it). Any mmap failure falls back to the read path.

**Measured** (66.4 MB / 100k-row store, interleaved A/B,5 rounds,
spawn → first response line):

| binary | median | min |
| --- | ---: | ---: |
| read-into-arena | 315.5 ms | 311.8 ms |
| **mmap** | **231.5 ms** | **196.2 ms** |

**−84 ms median (−27%) on open** — larger than the estimated −20…40
(the whole-file `read()` pass over a page-cache-warm file cost ≈50–70 ms
here; page faults now happen inline with decode). VmRSS is unchanged by
design (~144 MB either way — file pages count as resident while
mapped); the memory win is *reclaimability*: clean file-backed pages
evict under pressure, where the old ~62.5 MB arena copy was anonymous
and pinned for the process lifetime.

Byte proof: fixtures + reopen/lazy-history suite + **exp01–exp11 =
57/57** + `tcp_probe` IDENTICAL (the mapping feeds the same
`v4.decodeCore`).

## Ingest results (2026-10-08) — deferred insert queue (the O(n²) item)

**Measured first** (`zig build bench-ingest -Doptimize=ReleaseFast`,
engine inserts only — no parser — three id orders × scaling sizes):
the sorted-insert memmove was **quadratic in the worst case** —
reverse ids:1.36s @20k → **19.19s @100k (191.9 µs/row)** — while
ascending stayed linear (98.6 ms) and lexicographic string ids (the
E08/probe shape) sat in between (1.77 s).

**Design**: `EngineStore.pending` — inserts are O(1) pushes (seq-tagged
for deterministic last-write-wins) and the sorted invariant is restored
**once per write burst** at reader seams: the `executeStatement` reader
arm (covers every context incl. MEMORY sub-stores), `toIr` (all
checkpoint/encode paths), WAL-replay end, `replayAsOf` view build,
`dumpStore`. Flush = sort by (id, seq) → dedup → two-pointer merge (LWW),
with a pure-append fast path (time-ordered loads skip sort+merge).
A first-draft per-insert pending scan re-introduced quadratic cost
(14.8 s @100k) — that lesson is why dedup happens at flush, not push.

| insert order @100k | before | insert after | flush (once) | total |
| --- | ---: | ---: | ---: | ---: |
| ascending | 98.6 ms | ~105 ms (~1 µs/row) | ~60–230 ms* | ~0.3 s |
| **reverse (worst)** | **19,189 ms** | **93 ms** | ~156 ms | **~244 ms (≈77×)** |
| lex strings | 1,768 ms | 95 ms | ~191 ms | **~280 ms (≈6×)** |

\* flush timings swing ±4× run-to-run on this box (memory-subsystem
noise under the neighbour workload; insert numbers are stable) — the
structural claim is the one that matters: **flat ~1 µs/row for every
id order**, no quadratic anywhere. Correctness: pending never reaches
output unordered (every reader flushes first); parity **57/57** + the
full suite (upsert-LWW, forget-after-queue, replay, AS OF) pin it.

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
