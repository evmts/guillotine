const std = @import("std");

pub const Stats = struct {
    median_ns: f64,
    mean_ns: f64,
    p95_ns: u64,
    ops_per_sec: f64,
    mgas_per_sec: f64,
};

/// Samples are full EVM invocations. Sort only after measurement. p95 uses
/// nearest rank; median averages the two central observations for even N.
pub fn summarize(samples: []u64, operations: u32, gas: u64) !Stats {
    if (samples.len == 0 or operations == 0) return error.EmptySamples;
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    var sum: u128 = 0;
    for (samples) |sample| sum += sample;
    const mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(samples.len));
    if (mean == 0) return error.TimerResolution;
    const mid = samples.len / 2;
    const median = if (samples.len % 2 == 0)
        (@as(f64, @floatFromInt(samples[mid - 1])) + @as(f64, @floatFromInt(samples[mid]))) / 2
    else
        @as(f64, @floatFromInt(samples[mid]));
    return .{
        .median_ns = median,
        .mean_ns = mean,
        .p95_ns = samples[(samples.len * 95 + 99) / 100 - 1],
        .ops_per_sec = @as(f64, @floatFromInt(operations)) * 1e9 / mean,
        .mgas_per_sec = @as(f64, @floatFromInt(gas)) * 1e3 / mean,
    };
}

test "statistics use even median, nearest-rank p95, and explicit operation count" {
    var samples = [_]u64{ 40, 10, 30, 20 };
    const result = try summarize(&samples, 2, 100);
    try std.testing.expectEqual(@as(f64, 25), result.median_ns);
    try std.testing.expectEqual(@as(f64, 25), result.mean_ns);
    try std.testing.expectEqual(@as(u64, 40), result.p95_ns);
    try std.testing.expectEqual(@as(f64, 80_000_000), result.ops_per_sec);
    try std.testing.expectEqual(@as(f64, 4000), result.mgas_per_sec);
}

test "statistics reject empty and zero duration samples" {
    var empty: [0]u64 = .{};
    try std.testing.expectError(error.EmptySamples, summarize(&empty, 1, 1));
    var zero = [_]u64{0};
    try std.testing.expectError(error.TimerResolution, summarize(&zero, 1, 1));
    var one = [_]u64{7};
    const result = try summarize(&one, 1, 0);
    try std.testing.expectEqual(@as(f64, 7), result.median_ns);
    try std.testing.expectEqual(@as(u64, 7), result.p95_ns);
}
