//! Logging utilities with platform-aware panic handling
//!
//! This module provides a wrapper around standard logging that handles
//! panic situations differently based on the target platform:
//! - Native platforms: Log then panic normally
//! - WASM: Log then unreachable (panics don't work well in WASM)

const std = @import("std");
const builtin = @import("builtin");

/// Platform-aware panic that logs before terminating
///
/// On native platforms: Logs the message then calls std.debug.panic
/// On WASM: Logs the message then executes unreachable
///
/// This is necessary because std.debug.panic doesn't work correctly in WASM
/// environments where there's no stderr or process to terminate.
pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    // Always log the panic message first
    std.log.err(fmt, args);

    // Platform-specific termination
    if (builtin.target.isWasm()) {
        // In WASM, unreachable is more appropriate than panic
        // This will trap the WASM execution
        unreachable;
    } else {
        // On native platforms, use standard panic
        std.debug.panic(fmt, args);
    }
}

/// Log an error message
pub fn err(comptime fmt: []const u8, args: anytype) void {
    std.log.err(fmt, args);
}

/// Log a warning message
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    std.log.warn(fmt, args);
}

/// Log an info message
pub fn info(comptime fmt: []const u8, args: anytype) void {
    std.log.info(fmt, args);
}

/// Log a debug message
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    std.log.debug(fmt, args);
}

// Tests
test "log module exports" {
    // Just verify the module compiles and exports are available
    _ = panic;
    _ = err;
    _ = warn;
    _ = info;
    _ = debug;
}
