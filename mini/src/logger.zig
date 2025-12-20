const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch == .wasm32 or builtin.target.cpu.arch == .wasm64;

pub const LogLevel = enum(u8) {
    none = 0,
    err = 1,
    warn = 2,
    info = 3,
    debug = 4,
};

// Thread-local log level (defaults to none for performance)
threadlocal var current_log_level: LogLevel = .none;

pub fn setLogLevel(level: LogLevel) void {
    current_log_level = level;
}

pub fn getLogLevel() LogLevel {
    return current_log_level;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (!is_wasm) {
        std.debug.print(fmt, args);
    }
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (!is_wasm and @intFromEnum(current_log_level) >= @intFromEnum(LogLevel.warn)) {
        std.log.warn(fmt, args);
    }
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    if (!is_wasm and @intFromEnum(current_log_level) >= @intFromEnum(LogLevel.err)) {
        std.log.err(fmt, args);
    }
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (!is_wasm and @intFromEnum(current_log_level) >= @intFromEnum(LogLevel.info)) {
        std.log.info(fmt, args);
    }
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (!is_wasm and @intFromEnum(current_log_level) >= @intFromEnum(LogLevel.debug)) {
        std.log.debug(fmt, args);
    }
}
