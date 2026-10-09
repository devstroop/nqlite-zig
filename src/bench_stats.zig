//! Shared sample statistics for the in-process benches (issue #28).
//!
//! The trusted method stays what it was — in-process timing, median of
//! REPS — the benches just stop throwing the rest of the distribution
//! away: p50/p95/p99/max/mean (and a rate from the kept per-iteration
//! samples). Percentiles use linear interpolation over the sorted samples
//! (index = q·(n−1)), the same rule as the reference side's
//! `nqlite/scripts/bench-percentiles.py`, so both sides describe a run
//! the same way.
const std = @import("std");

/// Sort ns samples ascending in place (REPS-sized — insertion sort, no allocator).
pub fn sortSamples(samples: []u64) void {
    var i: usize = 1;
    while (i < samples.len) : (i += 1) {
        var j = i;
        while (j > 0 and samples[j] < samples[j - 1]) : (j -= 1)
            std.mem.swap(u64, &samples[j], &samples[j - 1]);
    }
}

/// Linear-interpolation percentile over SORTED ns samples; returns ns.
pub fn percentileNs(sorted: []const u64, q: f64) f64 {
    std.debug.assert(sorted.len > 0);
    const idx = q * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(idx));
    const hi: usize = @min(lo + 1, sorted.len - 1);
    const frac = idx - @as(f64, @floatFromInt(lo));
    const a: f64 = @floatFromInt(sorted[lo]);
    const b: f64 = @floatFromInt(sorted[hi]);
    return a + (b - a) * frac;
}

/// Distribution of a bench's kept samples, in milliseconds.
/// `median` keeps the old code's exact definition (`sorted[len / 2]` —
/// no two-middle averaging) so published medians stay comparable.
pub const Stats = struct {
    median: f64,
    p95: f64,
    p99: f64,
    max: f64,
    mean: f64,

    pub fn from(samples: []u64) Stats {
        std.debug.assert(samples.len > 0);
        sortSamples(samples);
        var sum_ns: f64 = 0;
        for (samples) |s| sum_ns += @floatFromInt(s);
        const ms = struct {
            fn f(ns: f64) f64 {
                return ns / 1_000_000.0;
            }
        }.f;
        return .{
            .median = ms(@floatFromInt(samples[samples.len / 2])),
            .p95 = ms(percentileNs(samples, 0.95)),
            .p99 = ms(percentileNs(samples, 0.99)),
            .max = ms(@floatFromInt(samples[samples.len - 1])),
            .mean = ms(sum_ns / @as(f64, @floatFromInt(samples.len))),
        };
    }

    /// Rate from the mean: `elements` work units per iteration → units/s.
    pub fn ratePerSec(self: Stats, elements: f64) f64 {
        return elements / (self.mean / 1000.0);
    }
};
