/* src/crc32_simd.c — PCLMULQDQ CRC-32 (IEEE, reflected), a faithful port of
 * crc32fast1.5.2 `src/specialized/pclmulqdq.rs` (the128-bit SSE fold-by-4
 * path; K-constants and the step-3/Barrett reductions copied verbatim,
 * including the reference's "doesn't follow the paper" comment — Chrome/
 * Linux diverge the same way).
 *
 * WHY C + HEADER-FREE: zig's self-hosted asm encoder only assembles
 * baseline instructions (inline-asm `pclmulqdq` fails to build), while
 * zig's vendored <emmintrin.h> chains into <stdlib.h> (needs libc). So
 * this file uses exactly one clang builtin (`__builtin_ia32_pclmulqdq128`)
 * plus C vector extensions and scalar helpers for the cold shuffle/shift
 * ops — no intrinsics headers, no libc, one per-function target attribute
 * doing what Rust's `#[target_feature]` does. Execution is gated at
 * runtime by zig's `usePclmul()` cpuid check.
 *
 * One-shot contract: `nql_crc32_simd(data, len) == crc32Slice8(data)` —
 * pinned by the every-length ladder test in crc32.zig, the golden-fixture
 * gate, WAL frame checks, and the exp01–exp11 parity digests.
 *
 * Compiled only on x86 targets (build.zig).
 */
#include <stddef.h>
#include <stdint.h>

/* Our XMM: two64-bit lanes (bit patterns identical to __m128i). */
typedef long long v2di __attribute__((vector_size(16)));

/* Fold constants for the reflected IEEE poly (crc32fast1.5.2). */
#define K1 UINT64_C(0x154442bd4)
#define K2 UINT64_C(0x1c6e41596)
#define K3 UINT64_C(0x1751997d0)
#define K4 UINT64_C(0x0ccaa009e)
#define K5 UINT64_C(0x163cd6124)
#define P_X UINT64_C(0x1DB710641)
#define U_PRIME UINT64_C(0x1F7011641)

/* Carry-less multiply with a literal immediate (the builtin needs one). */
#define CLMUL(a, b, imm) __builtin_ia32_pclmulqdq128((a), (b), (imm))

static inline v2di v_load16(const uint8_t **p) {
    v2di v;
    __builtin_memcpy(&v, *p, 16);
    *p += 16;
    return v;
}

static inline v2di v_set2(uint64_t lo, uint64_t hi) {
    v2di v;
    uint64_t t[2] = {lo, hi};
    __builtin_memcpy(&v, t, 16);
    return v;
}

/* _mm_cvtsi32_si128: low32 = value, everything above zeroed. */
static inline v2di v_cvtsi32(uint32_t x) {
    v2di v;
    uint32_t t[4] = {x, 0u, 0u, 0u};
    __builtin_memcpy(&v, t, 16);
    return v;
}

/* _mm_set_epi32(e3, e2, e1, e0) — memory order e0 first. */
static inline v2di v_set4(uint32_t e0, uint32_t e1, uint32_t e2, uint32_t e3) {
    v2di v;
    uint32_t t[4] = {e0, e1, e2, e3};
    __builtin_memcpy(&v, t, 16);
    return v;
}

/* _mm_extract_epi32(x, 1) — bytes4..7 (little-endian host). */
static inline uint32_t v_extract32_1(v2di x) {
    uint32_t t[4];
    __builtin_memcpy(t, &x, 16);
    return t[1];
}

/* _mm_srli_si128(x, c) — shift right BY c BYTES (zero-fill). */
static inline v2di v_srli_bytes(v2di x, unsigned c) {
    uint8_t b[16], out[16] = {0};
    __builtin_memcpy(b, &x, 16);
    for (unsigned i = 0; i + c < 16; i++)
        out[i] = b[i + c];
    v2di v;
    __builtin_memcpy(&v, out, 16);
    return v;
}

/* _mm_shuffle_epi8(a, m) — pshufb: out[i] = m[i] < 0 ? 0 : a[m[i] & 0xF]
 * (scalar: at most3× per call, in the cold tail). */
static inline v2di v_pshufb(v2di a, v2di m) {
    uint8_t ab[16], mb[16], out[16];
    __builtin_memcpy(ab, &a, 16);
    __builtin_memcpy(mb, &m, 16);
    for (int i = 0; i < 16; i++) {
        if ((int8_t)mb[i] < 0)
            out[i] = 0;
        else
            out[i] = ab[mb[i] & 0xF];
    }
    v2di v;
    __builtin_memcpy(&v, out, 16);
    return v;
}

/* Lane-wise XOR/AND — identical to _mm_xor/and_si128. */
#define V_XOR(a, b) ((a) ^ (b))
#define V_AND(a, b) ((a) & (b))

/* Fold `a` over `b` (reference `reduce128`). */
static inline v2di reduce128(v2di a, v2di b, v2di keys) {
    v2di t1 = CLMUL(a, keys, 0x00);
    v2di t2 = CLMUL(a, keys, 0x11);
    return V_XOR(V_XOR(b, t1), t2);
}

/* Raw (non-inverted) reflected byte loop — the definition, used only for
 * inputs below16 bytes (zig's dispatcher normally never sends those). */
static uint32_t crc32_raw(uint32_t raw, const uint8_t *d, size_t n) {
    size_t i;
    for (i = 0; i < n; i++) {
        raw ^= (uint32_t)d[i];
        int b;
        for (b = 0; b < 8; b++)
            raw = (raw >> 1) ^ (0xEDB88320u & (uint32_t)-(int32_t)(raw & 1u));
    }
    return raw;
}

/* Fold remaining whole blocks + a final partial block, then reduce the
 * 128-bit accumulator to the 32-bit CRC (reference `reduce_128_to_crc`). */
static uint32_t reduce_to_crc(v2di x, const uint8_t *data, size_t rem) {
    const v2di k3k4 = v_set2(K3, K4);

    while (rem >= 16) {
        x = reduce128(x, v_load16(&data), k3k4);
        rem -= 16;
    }

    /* Final partial block of n (1..=15) bytes: the last n bytes of the
     * accumulator shift out (`overflow`), x shifts down to make room, the
     * bytes slide into the vacated high lanes (runtime masks built the
     * same way as the reference's _mm_setr_epi8/add/xor sequence). */
    if (rem > 0) {
        const size_t n = rem;
        uint8_t shl_b[16], shr_b[16];
        for (int i = 0; i < 16; i++) {
            shl_b[i] = (uint8_t)(i + (int)n - 16);    /* add_epi8(seq, n-16) */
            shr_b[i] = (uint8_t)(shl_b[i] ^ 0x80u);   /* xor(shl, -128)      */
        }
        v2di shl, shr;
        __builtin_memcpy(&shl, shl_b, 16);
        __builtin_memcpy(&shr, shr_b, 16);

        v2di overflow = v_pshufb(x, shl);
        x = v_pshufb(x, shr);

        uint8_t part[16] = {0};
        for (size_t j = 0; j < n; j++)
            part[j] = data[j];
        v2di partv;
        __builtin_memcpy(&partv, part, 16);
        x = V_XOR(x, v_pshufb(partv, shl));
        x = reduce128(overflow, x, k3k4);
    }

    /* Step 3: 128 -> 64 bits.
     *
     * It's... not clear to me what's going on here. The paper itself is
     * pretty vague on this part but definitely uses different constants at
     * least. This implementation... appears to work though! (verbatim from
     * the reference — Chrome/Linux diverge the same way.) */
    x = V_XOR(CLMUL(x, k3k4, 0x10), v_srli_bytes(x, 8));
    x = V_XOR(
        CLMUL(V_AND(x, v_set4(~0u, 0u, 0u, 0u)), v_set2(K5, 0), 0x00),
        v_srli_bytes(x, 4));

    /* Barrett reduction 64 -> 32 (bit-reflected variant: take the upper
     * 32 bits of the product and invert). */
    const v2di pu = v_set2(P_X, U_PRIME);
    v2di t1 = CLMUL(V_AND(x, v_set4(~0u, 0u, 0u, 0u)), pu, 0x10);
    v2di t2 = CLMUL(V_AND(t1, v_set4(~0u, 0u, 0u, 0u)), pu, 0x00);
    return ~v_extract32_1(V_XOR(x, t2));
}

__attribute__((target("pclmulqdq,sse4.1,ssse3")))
uint32_t nql_crc32_simd(const uint8_t *data, size_t len) {
    if (len < 16)
        return ~crc32_raw(0xFFFFFFFFu, data, len);

    /*16..127: single accumulator. */
    if (len < 128) {
        const uint8_t *p = data;
        v2di x = v_load16(&p);
        x = V_XOR(x, v_cvtsi32(~0u)); /* !crc with crc = 0 */
        return reduce_to_crc(x, p, len - 16);
    }

    /* Fold-by-4 (>=128): four 16-byte streams, stride 64 per round. */
    const uint8_t *p = data;
    v2di x3 = v_load16(&p);
    v2di x2 = v_load16(&p);
    v2di x1 = v_load16(&p);
    v2di x0 = v_load16(&p);
    x3 = V_XOR(x3, v_cvtsi32(~0u)); /* fold the seed in */

    const v2di k1k2 = v_set2(K1, K2);
    while ((size_t)(data + len - p) >= 64) {
        x3 = reduce128(x3, v_load16(&p), k1k2);
        x2 = reduce128(x2, v_load16(&p), k1k2);
        x1 = reduce128(x1, v_load16(&p), k1k2);
        x0 = reduce128(x0, v_load16(&p), k1k2);
    }

    const v2di k3k4 = v_set2(K3, K4);
    v2di x = reduce128(x3, x2, k3k4);
    x = reduce128(x, x1, k3k4);
    x = reduce128(x, x0, k3k4);
    return reduce_to_crc(x, p, (size_t)(data + len - p));
}
