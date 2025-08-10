const std = @import("std");
const App = @import("app.zig");

extern fn createApplicationMenu() void;
extern fn setMainWindow(window: usize) void;
extern fn setWebuiRunFunction(func: *const fn (usize, [*:0]const u8) callconv(.C) void) void;

// Import webui_run function
pub extern fn webui_run(window: usize, script: [*:0]const u8) callconv(.C) void;

pub fn main() !void {
    if (@import("builtin").target.os.tag == .macos) {
        createApplicationMenu();
    }
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try App.init(allocator);
    defer app.deinit();

    if (@import("builtin").target.os.tag == .macos) {
        setMainWindow(app.window.window_handle);
        setWebuiRunFunction(webui_run);
    }

    try app.run();
}
