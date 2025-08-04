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

/// Runtime zone wrapper - uses dynamic allocation for truly unique zones
pub inline fn zoneRuntime(comptime src: std.builtin.SourceLocation, name: [:0]const u8) Zone {
    if (comptime enabled) {
        // Use dynamic allocation to create a unique zone for each name
        // This matches how REVM's tracing-tracy creates unique statistics entries
        return .{ 
            .inner = tracy.ZoneDynamic(
                name,                        // zone name (already null-terminated slice)
                src.fn_name,                 // function name
                src.file,                    // file path
                src.line,                    // line number
                0x00_00_ff_00,              // color (green)
            ),
        };
    } else {
        return .{ .inner = {} };
    }
}

/// Zone with dynamic name for PC-based tracking
pub inline fn zonePC(comptime src: std.builtin.SourceLocation, pc: usize) Zone {
    if (comptime enabled) {
        return .{ 
            .inner = tracy.ZoneNC(src, "PC\x00"[0..2:0], 0x00_ff_00_00),
            .pc = pc,
        };
    } else {
        return .{ .inner = {} };
    }
}

/// Zone with dynamic name - creates unique zone names
pub inline fn zoneDynamic(comptime src: std.builtin.SourceLocation, name_buf: []u8, pc: usize, opcode: u8) Zone {
    if (comptime enabled) {
        // Format: "evm.exec.XXXX" where XXXX is the PC in hex
        // Using decimal format to match what we see in the UI (3393)
        const name = std.fmt.bufPrint(name_buf, "evm.exec.{d}\x00", .{pc}) catch "evm.exec.????\x00";
        // Ensure we have a null-terminated string
        const null_term_name = name[0..name.len-1:0];
        return .{ 
            .inner = tracy.ZoneNC(src, null_term_name, 0x00_ff_00_00),
            .pc = pc,
            .opcode = opcode,
        };
    } else {
        return .{ .inner = {} };
    }
}

pub const Zone = struct {
    inner: if (enabled) tracy.ZoneCtx else void,
    pc: usize = 0,
    opcode: u8 = 0,
    
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
    
    pub inline fn Value(self: Zone, value: u64) void {
        if (comptime enabled) {
            self.inner.Value(value);
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