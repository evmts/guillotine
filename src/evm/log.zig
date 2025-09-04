const std = @import("std");
const builtin = @import("builtin");

//
// COMPTIME LOGGING INTERFACE - Proof of Concept
// This demonstrates the proposed flexible logging backend system
//

/// Backend types for different logging environments
const LoggerBackend = enum {
    std_log,    // Standard Zig logging (native platforms)
    js_console, // JavaScript console injection (WASM + JS host)
    no_op,      // Silent operation (WASM freestanding)
};

/// Comptime backend selection logic
/// TODO: Add @hasDecl check for JavaScript console injection
/// TODO: Add build-time configuration flags
const backend = comptime blk: {
    // TODO: if (@hasDecl(@This(), "WASM_JS_LOGGING")) break :blk LoggerBackend.js_console;
    if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding) {
        break :blk LoggerBackend.no_op;
    }
    break :blk LoggerBackend.std_log;
};

/// TODO: JavaScript console bridge functions (to be injected by JS host)
/// extern fn js_console_debug(ptr: [*]const u8, len: usize) void;
/// extern fn js_console_error(ptr: [*]const u8, len: usize) void;
/// extern fn js_console_warn(ptr: [*]const u8, len: usize) void;
/// extern fn js_console_info(ptr: [*]const u8, len: usize) void;

/// Debug log for development and troubleshooting
/// Compile-time no-op in ReleaseFast/ReleaseSmall for performance
pub fn debug(comptime format: []const u8, args: anytype) void {
    if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
        switch (comptime backend) {
            .std_log => std.log.debug("[EVM2] " ++ format, args),
            .js_console => {
                // TODO: Convert format+args to C string and call js_console_debug
                // For now, fall back to no-op
            },
            .no_op => {}, // Silent operation
        }
    }
}

/// Error log for critical issues that require attention
pub fn err(comptime format: []const u8, args: anytype) void {
    switch (comptime backend) {
        .std_log => std.log.err("[EVM2] " ++ format, args),
        .js_console => {
            // TODO: Call js_console_error with formatted string
            // TODO: Handle string conversion from Zig format to C string
        },
        .no_op => {}, // Silent operation
    }
}

/// Warning log for non-critical issues and unexpected conditions
pub fn warn(comptime format: []const u8, args: anytype) void {
    switch (comptime backend) {
        .std_log => std.log.warn("[EVM2] " ++ format, args),
        .js_console => {
            // TODO: Call js_console_warn with formatted string
        },
        .no_op => {}, // Silent operation
    }
}

/// Info log for general information (use sparingly for performance)
pub fn info(comptime format: []const u8, args: anytype) void {
    switch (comptime backend) {
        .std_log => std.log.info("[EVM2] " ++ format, args),
        .js_console => {
            // TODO: Call js_console_info with formatted string
        },
        .no_op => {}, // Silent operation
    }
}

test "log functions compile and execute without error" {
    debug("test debug message: {}", .{42});
    err("test error message: {s}", .{"error"});
    warn("test warning message: {d:.2}", .{3.14});
    info("test info message: {any}", .{true});
}

test "log functions handle different argument types" {
    debug("string: {s}, number: {d}, hex: {x}", .{ "test", 123, 0xABC });
    err("boolean: {}, float: {d:.3}", .{ false, 2.718 });
    warn("array: {any}", .{[_]u32{ 1, 2, 3 }});
    info("no args: {s}", .{""});
}