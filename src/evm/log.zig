const std = @import("std");
const builtin = @import("builtin");

/// Logger backend types for comptime selection
const LoggerBackend = enum { std_log, js_console, no_op };

/// Determine logger backend at compile time based on target and injected symbols
fn getLoggerBackend() LoggerBackend {
    // Check for JavaScript logging injection
    if (@hasDecl(@This(), "WASM_JS_LOGGING")) {
        return .js_console;
    }
    
    // Check for WASM freestanding (no std.log available)
    if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding) {
        return .no_op;
    }
    
    // Default to std.log for native platforms
    return .std_log;
}

/// Select logger backend at compile time
const backend = comptime getLoggerBackend();

/// Backend implementations
const StdLogBackend = struct {
    pub fn debug(comptime format: []const u8, args: anytype) void {
        std.log.debug("[EVM2] " ++ format, args);
    }
    
    pub fn err(comptime format: []const u8, args: anytype) void {
        std.log.err("[EVM2] " ++ format, args);
    }
    
    pub fn warn(comptime format: []const u8, args: anytype) void {
        std.log.warn("[EVM2] " ++ format, args);
    }
    
    pub fn info(comptime format: []const u8, args: anytype) void {
        std.log.info("[EVM2] " ++ format, args);
    }
};

const NoOpBackend = struct {
    pub fn debug(comptime format: []const u8, args: anytype) void {
        _ = format;
        _ = args;
    }
    
    pub fn err(comptime format: []const u8, args: anytype) void {
        _ = format;
        _ = args;
    }
    
    pub fn warn(comptime format: []const u8, args: anytype) void {
        _ = format;
        _ = args;
    }
    
    pub fn info(comptime format: []const u8, args: anytype) void {
        _ = format;
        _ = args;
    }
};

const JsConsoleBackend = struct {
    pub fn debug(comptime format: []const u8, args: anytype) void {
        // JavaScript host should inject these external functions
        if (@hasDecl(@import("root"), "js_console_debug")) {
            @import("root").js_console_debug("[EVM2] " ++ format, args);
        }
    }
    
    pub fn err(comptime format: []const u8, args: anytype) void {
        if (@hasDecl(@import("root"), "js_console_error")) {
            @import("root").js_console_error("[EVM2] " ++ format, args);
        }
    }
    
    pub fn warn(comptime format: []const u8, args: anytype) void {
        if (@hasDecl(@import("root"), "js_console_warn")) {
            @import("root").js_console_warn("[EVM2] " ++ format, args);
        }
    }
    
    pub fn info(comptime format: []const u8, args: anytype) void {
        if (@hasDecl(@import("root"), "js_console_info")) {
            @import("root").js_console_info("[EVM2] " ++ format, args);
        }
    }
};

/// Professional isomorphic logger for the EVM2 that works across all target architectures
/// including native platforms, WASI, and WASM environments. Uses the std_options.logFn
/// system for automatic platform adaptation.
///
/// Provides debug, error, and warning logging with EVM2-specific prefixing.
/// Debug logs are optimized away in release builds for performance.
/// Debug log for development and troubleshooting
/// Compile-time no-op in ReleaseFast/ReleaseSmall for performance
pub fn debug(comptime format: []const u8, args: anytype) void {
    if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
        switch (comptime backend) {
            .std_log => StdLogBackend.debug(format, args),
            .js_console => JsConsoleBackend.debug(format, args),
            .no_op => NoOpBackend.debug(format, args),
        }
    }
}

/// Error log for critical issues that require attention
pub fn err(comptime format: []const u8, args: anytype) void {
    switch (comptime backend) {
        .std_log => StdLogBackend.err(format, args),
        .js_console => JsConsoleBackend.err(format, args),
        .no_op => NoOpBackend.err(format, args),
    }
}

/// Warning log for non-critical issues and unexpected conditions
pub fn warn(comptime format: []const u8, args: anytype) void {
    switch (comptime backend) {
        .std_log => StdLogBackend.warn(format, args),
        .js_console => JsConsoleBackend.warn(format, args),
        .no_op => NoOpBackend.warn(format, args),
    }
}

/// Info log for general information (use sparingly for performance)
pub fn info(comptime format: []const u8, args: anytype) void {
    switch (comptime backend) {
        .std_log => StdLogBackend.info(format, args),
        .js_console => JsConsoleBackend.info(format, args),
        .no_op => NoOpBackend.info(format, args),
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

// TDD RED PHASE: These tests will fail until backend system is implemented
test "backend selection logic" {
    const LoggerBackend = enum { std_log, js_console, no_op };
    
    // This will fail - getLoggerBackend doesn't exist yet
    const backend = comptime getLoggerBackend();
    
    // Backend should be determined at compile time based on target and JS injection
    try std.testing.expect(backend == LoggerBackend.std_log or 
                          backend == LoggerBackend.js_console or 
                          backend == LoggerBackend.no_op);
}

test "comptime backend configuration responds to environment" {
    // This will fail - backend selection system doesn't exist yet
    const has_js_logging = @hasDecl(@This(), "WASM_JS_LOGGING");
    const is_wasm_freestanding = builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding;
    
    if (has_js_logging) {
        // Should select JavaScript console backend
        try std.testing.expect(comptime getLoggerBackend() == .js_console);
    } else if (is_wasm_freestanding) {
        // Should select no-op backend
        try std.testing.expect(comptime getLoggerBackend() == .no_op);
    } else {
        // Should select std.log backend
        try std.testing.expect(comptime getLoggerBackend() == .std_log);
    }
}