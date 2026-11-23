//! Shared allocator selector for Guillotine fuzz targets.
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
