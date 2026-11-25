//! Shared allocator selector and std.testing.fuzz adapter for Guillotine fuzz targets.
//!
//! - Inside `zig build test-fuzz` / `zig build test-fuzz --fuzz` (`builtin.is_test == true`):
//!   uses `std.testing.allocator` for strict leak detection on every single fuzz input.
//! - Inside the standalone multi-threaded `fuzz-campaign` runner (`builtin.is_test == false`):
//!   uses `std.heap.c_allocator` (thread-safe, high-throughput, works across all worker threads).

const std = @import("std");
const builtin = @import("builtin");

pub fn get() std.mem.Allocator {
    if (builtin.is_test) {
        return std.testing.allocator;
    }
    return std.heap.c_allocator;
}

/// Largest input the coverage-guided fuzzer passes to a byte-oriented target.
pub const max_input_len = 4096;

/// Adapt a byte-oriented target `fn (void, []const u8) !void` to Zig 0.17's
/// `std.testing.fuzz`, which passes a `*std.testing.Smith`. Corpus replay
/// (`smith.in != null`) hands each seed to the target byte-for-byte, so seeds
/// keep their meaning; under `--fuzz` the fuzzer generates the byte slice.
pub fn bytes(comptime target: anytype) fn (void, *std.testing.Smith) anyerror!void {
    return struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            if (smith.in) |input| return target({}, input);
            var buffer: [max_input_len]u8 = undefined;
            const len = smith.slice(&buffer);
            return target({}, buffer[0..len]);
        }
    }.run;
}

test "bytes adapter replays corpus input unchanged" {
    const Probe = struct {
        var seen: []const u8 = "";
        fn target(_: void, input: []const u8) !void {
            seen = input;
        }
    };
    var smith: std.testing.Smith = .{ .in = "\x01\x02\x03" };
    try bytes(Probe.target)({}, &smith);
    try std.testing.expectEqualSlices(u8, "\x01\x02\x03", Probe.seen);
}
