const std = @import("std");
const build_options = @import("build_options");

/// Comptime flag to enable/disable Tracy
pub const enabled = build_options.enable_tracy;

// Import ztracy only when enabled
const ztracy = if (enabled) @import("ztracy") else undefined;

/// Zero-cost zone wrapper
pub inline fn zone(comptime src: std.builtin.SourceLocation, comptime name: ?[*:0]const u8) Zone {
    if (comptime enabled) {
        const tracy_name = name orelse src.fn_name;
        return .{ 
            .inner = ztracy.ZoneNC(src, tracy_name, 0x00_00_ff_00),
        };
    } else {
        return .{ .inner = {} };
    }
}

pub const Zone = struct {
    inner: if (enabled) ztracy.ZoneCtx else void,
    
    pub inline fn end(self: Zone) void {
        if (comptime enabled) {
            self.inner.End();
        }
    }
    
    pub inline fn setText(self: Zone, text: [*:0]const u8) void {
        if (comptime enabled) {
            self.inner.Text(text);
        }
    }
    
    pub inline fn setName(self: Zone, name: [*:0]const u8) void {
        if (comptime enabled) {
            self.inner.Name(name);
        }
    }
};

/// Zero-cost frame marker
pub inline fn frameMarker() void {
    if (comptime enabled) {
        ztracy.FrameMark();
    }
}

/// Zero-cost frame marker with name
pub inline fn frameMarkerNamed(name: [*:0]const u8) void {
    if (comptime enabled) {
        ztracy.FrameMarkNamed(name);
    }
}

/// Plot a value
pub inline fn plot(name: [*:0]const u8, value: f64) void {
    if (comptime enabled) {
        ztracy.PlotF(name, value);
    }
}

/// Message logging
pub inline fn message(text: [*:0]const u8) void {
    if (comptime enabled) {
        ztracy.Message(text);
    }
}

/// Allocator wrapper that reports to Tracy when enabled
pub fn TrackedAllocator(comptime T: type) type {
    return struct {
        child: T,
        tracy_allocator: if (enabled) ztracy.TrackedAllocator else void,
        
        const Self = @This();
        
        pub fn init(child: T, name: [*:0]const u8) Self {
            if (comptime enabled) {
                return .{
                    .child = child,
                    .tracy_allocator = ztracy.TrackedAllocator.init(child, name),
                };
            } else {
                return .{ .child = child, .tracy_allocator = {} };
            }
        }
        
        pub fn allocator(self: *Self) std.mem.Allocator {
            if (comptime enabled) {
                return self.tracy_allocator.allocator();
            } else {
                return self.child;
            }
        }
        
        pub fn deinit(self: *Self) void {
            if (comptime enabled) {
                self.tracy_allocator.deinit();
            }
        }
    };
}

/// Set thread name for Tracy
pub inline fn setThreadName(name: [*:0]const u8) void {
    if (comptime enabled) {
        ztracy.SetThreadName(name);
    }
}

test "tracy support compiles" {
    // This test ensures tracy_support compiles correctly
    const z = zone(@src(), "test_zone\x00");
    defer z.end();
    
    frameMarker();
    message("Test message\x00");
    plot("test_value\x00", 42.0);
    
    if (enabled) {
        std.debug.print("Tracy is enabled in this build\n", .{});
    } else {
        std.debug.print("Tracy is disabled in this build\n", .{});
    }
}