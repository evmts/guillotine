const std = @import("std");

extern fn console_log(ptr: [*]const u8, len: usize) void;
extern fn console_warn(ptr: [*]const u8, len: usize) void;
extern fn console_error(ptr: [*]const u8, len: usize) void;

pub const WasmLogger = struct {
    pub fn log(
        comptime level: std.log.Level,
        comptime scope: @TypeOf(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const prefix = comptime level.asText();
        const scope_text = comptime @tagName(scope);

        var buf: [4096]u8 = undefined;
        const message = std.fmt.bufPrint(buf[0..], "[" ++ prefix ++ "] " ++ "(" ++ scope_text ++ ") " ++ format, args) catch |err| switch (err) {
            error.NoSpaceLeft => "Log message too long",
        };

        switch (level) {
            .err => console_error(message.ptr, message.len),
            .warn => console_warn(message.ptr, message.len),
            .info, .debug => console_log(message.ptr, message.len),
        }
    }
};

pub const log = WasmLogger.log;
