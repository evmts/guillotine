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
        return .{ 
            .inner = tracy.ZoneNC(src, tracy_name, 0x00_00_ff_00),
        };
    } else {
        return .{ .inner = {} };
    }
}

/// Zone with dynamic name for PC-based tracking
pub inline fn zonePC(comptime src: std.builtin.SourceLocation, pc: usize) Zone {
    if (comptime enabled) {
        return .{ 
            .inner = tracy.ZoneNC(src, "PC", 0x00_ff_00_00),
            .pc = pc,
        };
    } else {
        return .{ .inner = {} };
    }
}

pub const Zone = struct {
    inner: if (enabled) tracy.ZoneCtx else void,
    pc: usize = 0,
    
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
    
    pub inline fn setPCName(self: Zone) void {
        if (comptime enabled) {
            var buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, "PC_{}", .{self.pc}) catch "PC_???";
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