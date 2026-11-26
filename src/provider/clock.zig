//! Monotonic clock and sleep for the provider module.
//!
//! Zig 0.17 moved time and sleep behind `std.Io`. The provider has no `Io`
//! parameter in its public API, so it reads the `.awake` monotonic clock
//! through the process-wide single-threaded `Io` instance (the same pattern
//! as `src/native_stack.zig`). Both calls are plain syscalls and are safe to
//! use from any thread.

const std = @import("std");

/// The process-wide `Io` the provider uses for clocks, sleeps and HTTP clients.
pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Nanoseconds on the monotonic clock. Only differences are meaningful.
pub fn nanoTimestamp() i96 {
    return std.Io.Timestamp.now(io(), .awake).nanoseconds;
}

/// Milliseconds on the monotonic clock. Only differences are meaningful.
pub fn milliTimestamp() i64 {
    return @intCast(@divFloor(nanoTimestamp(), std.time.ns_per_ms));
}

/// Block the calling thread for `ns` nanoseconds.
pub fn sleep(ns: u64) std.Io.Cancelable!void {
    return io().sleep(.fromNanoseconds(ns), .awake);
}

test "clock is monotonic across a sleep" {
    const start = nanoTimestamp();
    try sleep(2 * std.time.ns_per_ms);
    const elapsed = nanoTimestamp() - start;
    try std.testing.expect(elapsed >= 2 * std.time.ns_per_ms);
}
