const std = @import("std");
const build_options = @import("build_options");

/// Comptime flag to enable/disable Tracy
pub const enabled = build_options.enable_tracy;

// Import tracy only when enabled
const tracy = if (enabled) @import("tracy") else undefined;

/// Zero-cost zone wrapper
pub inline fn zone(comptime src: std.builtin.SourceLocation, comptime name: ?[]const u8) Zone {
    if (comptime enabled) {
        const tracy_name = name orelse src.fn_name;
        const null_terminated_name = tracy_name ++ "\x00";
        return .{ 
            .inner = tracy.ZoneNC(src, null_terminated_name[0..null_terminated_name.len-1:0], 0x00_00_ff_00),
        };
    } else {
        return .{ .inner = {} };
    }
}

pub const Zone = struct {
    inner: if (enabled) tracy.ZoneCtx else void,
    
    pub inline fn end(self: Zone) void {
        if (comptime enabled) {
            self.inner.End();
        }
    }
    
    pub inline fn setText(self: Zone, text: []const u8) void {
        if (comptime enabled) {
            self.inner.Text(text);
        }
    }
    
    pub inline fn setName(self: Zone, name: []const u8) void {
        if (comptime enabled) {
            self.inner.Name(name);
        }
    }
};

/// Frame marker for marking frame boundaries
pub inline fn frameMarker() void {
    if (comptime enabled) {
        tracy.FrameMark();
    }
}

/// Message logging
pub inline fn message(text: []const u8) void {
    if (comptime enabled) {
        tracy.Message(text);
    }
}