const std = @import("std");
const tracy = @import("root").tracy_support;

pub fn main() !void {
    tracy.setThreadName("main\x00");
    
    const zone = tracy.zone(@src(), "main\x00");
    defer zone.end();
    
    std.debug.print("Tracy enabled: {}\n", .{tracy.enabled});
    
    // Simulate some work
    var sum: u64 = 0;
    for (0..1_000_000) |i| {
        const work_zone = tracy.zone(@src(), "computation\x00");
        defer work_zone.end();
        
        sum += i;
        
        if (i % 100_000 == 0) {
            tracy.plot("progress\x00", @as(f64, @floatFromInt(i)));
        }
    }
    
    tracy.message("Work complete!\x00");
    tracy.frameMarker();
    
    std.debug.print("Sum: {}\n", .{sum});
}