const std = @import("std");
const webui = @import("webui/webui.zig");
const assets = @import("assets.zig");
const DevtoolEvm = @import("evm.zig");

const App = @This();

window: webui,
allocator: std.mem.Allocator,
devtool_evm: ?DevtoolEvm,

fn return_json_owned(e: *webui.Event, allocator: std.mem.Allocator, json_owned: []u8) void {
    // Create a null-terminated copy, return, then free both buffers
    const nt = allocator.allocSentinel(u8, json_owned.len, 0) catch {
        // Fallback to truncated static buffer on allocation failure
        var buf: [512:0]u8 = undefined;
        const n = @min(json_owned.len, 511);
        @memcpy(buf[0..n], json_owned[0..n]);
        buf[n] = 0;
        e.return_string(buf[0..n :0]);
        allocator.free(json_owned);
        return;
    };
    defer allocator.free(nt);
    @memcpy(nt[0..json_owned.len], json_owned);
    e.return_string(nt[0..json_owned.len :0]);
    allocator.free(json_owned);
}

fn return_json_from_evm(e: *webui.Event, app_alloc: std.mem.Allocator, evm_alloc: std.mem.Allocator, json_evm_owned: []u8) void {
    const nt = app_alloc.allocSentinel(u8, json_evm_owned.len, 0) catch {
        var buf: [512:0]u8 = undefined;
        const n = @min(json_evm_owned.len, 511);
        @memcpy(buf[0..n], json_evm_owned[0..n]);
        buf[n] = 0;
        e.return_string(buf[0..n :0]);
        evm_alloc.free(json_evm_owned);
        return;
    };
    defer app_alloc.free(nt);
    @memcpy(nt[0..json_evm_owned.len], json_evm_owned);
    e.return_string(nt[0..json_evm_owned.len :0]);
    evm_alloc.free(json_evm_owned);
}

fn alloc_error_json(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    // Minimal JSON construction; assumes msg contains no quotes
    return try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{msg});
}

fn alloc_breakpoints_json(allocator: std.mem.Allocator, bps: []const u32) ![]u8 {
    var s = try allocator.dupe(u8, "{\"breakpoints\":[");
    errdefer allocator.free(s);
    var i: usize = 0;
    while (i < bps.len) : (i += 1) {
        if (i > 0) {
            const next = try std.fmt.allocPrint(allocator, "{s},", .{s});
            allocator.free(s);
            s = next;
        }
        const next2 = try std.fmt.allocPrint(allocator, "{s}{d}", .{ s, bps[i] });
        allocator.free(s);
        s = next2;
    }
    const out = try std.fmt.allocPrint(allocator, "{s}]}}", .{s});
    allocator.free(s);
    return out;
}

// EVM Handler Functions
fn loadBytecodeHandler(e: *webui.Event) void {
    const bytecode_hex = e.get_string();
    const app_ptr = e.get_ptr();
    const app: *App = @ptrCast(@alignCast(app_ptr));

    if (app.devtool_evm) |*evm| {
        evm.loadBytecodeHex(bytecode_hex) catch |err| {
            const msg = switch (err) {
                error.EmptyBytecode => "Bytecode cannot be empty",
                error.InvalidHexLength => "Hex string must have even number of characters",
                error.InvalidHexCharacter => "Bytecode contains invalid hex characters",
                error.OutOfMemory => "Out of memory",
                else => "Unknown error loading bytecode",
            };
            const json = alloc_error_json(app.allocator, msg) catch {
                e.return_string("{\"error\":\"Failed to load bytecode\"}");
                return;
            };
            return_json_owned(e, app.allocator, json);
            return;
        };
    }

    e.return_string("{\"success\": true}");
}

fn resetEvmHandler(e: *webui.Event) void {
    const app_ptr = e.get_ptr();
    const app: *App = @ptrCast(@alignCast(app_ptr));

    if (app.devtool_evm) |*evm| {
        evm.resetExecution() catch {
            const json = alloc_error_json(app.allocator, "Failed to reset EVM") catch {
                e.return_string("{\"error\":\"Failed to reset EVM\"}");
                return;
            };
            return_json_owned(e, app.allocator, json);
            return;
        };

        const state_json = evm.serializeEvmState() catch {
            const json = alloc_error_json(app.allocator, "Failed to serialize state") catch {
                e.return_string("{\"error\":\"Failed to serialize state\"}");
                return;
            };
            return_json_owned(e, app.allocator, json);
            return;
        };
        return_json_from_evm(e, app.allocator, evm.allocator, state_json);
    } else {
        const json = alloc_error_json(app.allocator, "EVM not initialized") catch {
            e.return_string("{\"error\":\"EVM not initialized\"}");
            return;
        };
        return_json_owned(e, app.allocator, json);
    }
}

fn stepEvmHandler(e: *webui.Event) void {
    const app_ptr = e.get_ptr();
    const app: *App = @ptrCast(@alignCast(app_ptr));

    if (app.devtool_evm) |*evm| {
        const step_result = evm.singleStep() catch {
            const json = alloc_error_json(app.allocator, "Failed to step EVM") catch {
                e.return_string("{\"error\":\"Failed to step EVM\"}");
                return;
            };
            return_json_owned(e, app.allocator, json);
            return;
        };
        _ = step_result;

        const state_json = evm.serializeEvmState() catch {
            const json = alloc_error_json(app.allocator, "Failed to serialize state") catch {
                e.return_string("{\"error\":\"Failed to serialize state\"}");
                return;
            };
            return_json_owned(e, app.allocator, json);
            return;
        };
        return_json_from_evm(e, app.allocator, evm.allocator, state_json);
    } else {
        const json = alloc_error_json(app.allocator, "EVM not initialized") catch {
            e.return_string("{\"error\":\"EVM not initialized\"}");
            return;
        };
        return_json_owned(e, app.allocator, json);
    }
}

fn runEvmHandler(e: *webui.Event) void {
    const app_ptr = e.get_ptr();
    const app: *App = @ptrCast(@alignCast(app_ptr));

    if (app.devtool_evm) |*evm| {
        const run_result = evm.runUntilHalt() catch {
            const json = alloc_error_json(app.allocator, "Failed to run EVM") catch {
                e.return_string("{\"error\":\"Failed to run EVM\"}");
                return;
            };
            return_json_owned(e, app.allocator, json);
            return;
        };
        _ = run_result;

        const state_json = evm.serializeEvmState() catch {
            const json = alloc_error_json(app.allocator, "Failed to serialize state") catch {
                e.return_string("{\"error\":\"Failed to serialize state\"}");
                return;
            };
            return_json_owned(e, app.allocator, json);
            return;
        };
        return_json_from_evm(e, app.allocator, evm.allocator, state_json);
    } else {
        const json = alloc_error_json(app.allocator, "EVM not initialized") catch {
            e.return_string("{\"error\":\"EVM not initialized\"}");
            return;
        };
        return_json_owned(e, app.allocator, json);
    }
}

fn blockEvmHandler(e: *webui.Event) void {
    const app_ptr = e.get_ptr();
    const app: *App = @ptrCast(@alignCast(app_ptr));

    if (app.devtool_evm) |*evm| {
        const run_result = evm.runUntilNextBlock() catch {
            const json = alloc_error_json(app.allocator, "Failed to run block") catch {
                e.return_string("{\"error\":\"Failed to run block\"}");
                return;
            };
            return_json_owned(e, app.allocator, json);
            return;
        };
        _ = run_result;

        const state_json = evm.serializeEvmState() catch {
            const json = alloc_error_json(app.allocator, "Failed to serialize state") catch {
                e.return_string("{\"error\":\"Failed to serialize state\"}");
                return;
            };
            return_json_owned(e, app.allocator, json);
            return;
        };
        return_json_from_evm(e, app.allocator, evm.allocator, state_json);
    } else {
        const json = alloc_error_json(app.allocator, "EVM not initialized") catch {
            e.return_string("{\"error\":\"EVM not initialized\"}");
            return;
        };
        return_json_owned(e, app.allocator, json);
    }
}

fn getEvmStateHandler(e: *webui.Event) void {
    const app_ptr = e.get_ptr();
    const app: *App = @ptrCast(@alignCast(app_ptr));

    if (app.devtool_evm) |*evm| {
        const state_json = evm.serializeEvmState() catch {
            const json = alloc_error_json(app.allocator, "Failed to serialize state") catch {
                e.return_string("{\"error\":\"Failed to serialize state\"}");
                return;
            };
            return_json_owned(e, app.allocator, json);
            return;
        };
        return_json_from_evm(e, app.allocator, evm.allocator, state_json);
    } else {
        const json = alloc_error_json(app.allocator, "EVM not initialized") catch {
            e.return_string("{\"error\":\"EVM not initialized\"}");
            return;
        };
        return_json_owned(e, app.allocator, json);
    }
}

// Breakpoint Handlers
fn addBreakpointHandler(e: *webui.Event) void {
    const pc_str = e.get_string();
    const app_ptr = e.get_ptr();
    const app: *App = @ptrCast(@alignCast(app_ptr));

    if (app.devtool_evm) |*evm| {
        const pc: u32 = blk: {
            // Parse decimal or 0x-prefixed hex
            if (pc_str.len >= 2 and pc_str[0] == '0' and (pc_str[1] == 'x' or pc_str[1] == 'X')) {
                break :blk std.fmt.parseInt(u32, pc_str[2..], 16) catch |err| {
                    const msg = std.fmt.allocPrint(app.allocator, "Invalid hex PC: {}", .{err}) catch "Invalid hex PC";
                    const json = alloc_error_json(app.allocator, if (@TypeOf(msg) == []const u8) msg else msg) catch null;
                    if (@TypeOf(msg) == []u8) app.allocator.free(msg);
                    if (json) |j| return_json_owned(e, app.allocator, j);
                    e.return_string("{\"error\":\"Invalid hex PC\"}");
                    return;
                };
            } else {
                break :blk std.fmt.parseInt(u32, pc_str, 10) catch |err| {
                    const msg = std.fmt.allocPrint(app.allocator, "Invalid PC: {}", .{err}) catch "Invalid PC";
                    const json = alloc_error_json(app.allocator, if (@TypeOf(msg) == []const u8) msg else msg) catch null;
                    if (@TypeOf(msg) == []u8) app.allocator.free(msg);
                    if (json) |j| return_json_owned(e, app.allocator, j);
                    e.return_string("{\"error\":\"Invalid PC\"}");
                    return;
                };
            }
        };

        evm.addBreakpoint(pc) catch |err| {
            const msg = std.fmt.allocPrint(app.allocator, "Failed to add breakpoint: {}", .{err}) catch "Failed to add breakpoint";
            const json = alloc_error_json(app.allocator, if (@TypeOf(msg) == []const u8) msg else msg) catch null;
            if (@TypeOf(msg) == []u8) app.allocator.free(msg);
            if (json) |j| return_json_owned(e, app.allocator, j);
            e.return_string("{\"error\":\"Failed to add breakpoint\"}");
            return;
        };

        const bps = evm.getBreakpoints(app.allocator) catch |err| {
            const msg = std.fmt.allocPrint(app.allocator, "Failed to get breakpoints: {}", .{err}) catch "Failed to get breakpoints";
            const json = alloc_error_json(app.allocator, if (@TypeOf(msg) == []const u8) msg else msg) catch null;
            if (@TypeOf(msg) == []u8) app.allocator.free(msg);
            if (json) |j| return_json_owned(e, app.allocator, j);
            e.return_string("{\"error\":\"Failed to get breakpoints\"}");
            return;
        };
        defer app.allocator.free(bps);

        const json = alloc_breakpoints_json(app.allocator, bps) catch {
            e.return_string("{\"error\":\"Failed to format breakpoints\"}");
            return;
        };
        return_json_owned(e, app.allocator, json);
        return;
    }

    {
        const json = alloc_error_json(app.allocator, "EVM not initialized") catch {
            e.return_string("{\"error\":\"EVM not initialized\"}");
            return;
        };
        return_json_owned(e, app.allocator, json);
    }
}

fn removeBreakpointHandler(e: *webui.Event) void {
    const pc_str = e.get_string();
    const app_ptr = e.get_ptr();
    const app: *App = @ptrCast(@alignCast(app_ptr));

    if (app.devtool_evm) |*evm| {
        const pc: u32 = blk: {
            if (pc_str.len >= 2 and pc_str[0] == '0' and (pc_str[1] == 'x' or pc_str[1] == 'X')) {
                break :blk std.fmt.parseInt(u32, pc_str[2..], 16) catch |err| {
                    const msg = std.fmt.allocPrint(app.allocator, "Invalid hex PC: {}", .{err}) catch "Invalid hex PC";
                    const json = alloc_error_json(app.allocator, if (@TypeOf(msg) == []const u8) msg else msg) catch null;
                    if (@TypeOf(msg) == []u8) app.allocator.free(msg);
                    if (json) |j| return_json_owned(e, app.allocator, j);
                    e.return_string("{\"error\":\"Invalid hex PC\"}");
                    return;
                };
            } else {
                break :blk std.fmt.parseInt(u32, pc_str, 10) catch |err| {
                    const msg = std.fmt.allocPrint(app.allocator, "Invalid PC: {}", .{err}) catch "Invalid PC";
                    const json = alloc_error_json(app.allocator, if (@TypeOf(msg) == []const u8) msg else msg) catch null;
                    if (@TypeOf(msg) == []u8) app.allocator.free(msg);
                    if (json) |j| return_json_owned(e, app.allocator, j);
                    e.return_string("{\"error\":\"Invalid PC\"}");
                    return;
                };
            }
        };

        _ = evm.removeBreakpoint(pc) catch false;
        const bps = evm.getBreakpoints(app.allocator) catch |err| {
            const msg = std.fmt.allocPrint(app.allocator, "Failed to get breakpoints: {}", .{err}) catch "Failed to get breakpoints";
            const json = alloc_error_json(app.allocator, if (@TypeOf(msg) == []const u8) msg else msg) catch null;
            if (@TypeOf(msg) == []u8) app.allocator.free(msg);
            if (json) |j| return_json_owned(e, app.allocator, j);
            e.return_string("{\"error\":\"Failed to get breakpoints\"}");
            return;
        };
        defer app.allocator.free(bps);

        const json = alloc_breakpoints_json(app.allocator, bps) catch {
            e.return_string("{\"error\":\"Failed to format breakpoints\"}");
            return;
        };
        return_json_owned(e, app.allocator, json);
        return;
    }

    {
        const json = alloc_error_json(app.allocator, "EVM not initialized") catch {
            e.return_string("{\"error\":\"EVM not initialized\"}");
            return;
        };
        return_json_owned(e, app.allocator, json);
    }
}

fn clearBreakpointsHandler(e: *webui.Event) void {
    const app_ptr = e.get_ptr();
    const app: *App = @ptrCast(@alignCast(app_ptr));

    if (app.devtool_evm) |*evm| {
        evm.clearBreakpoints();
        const empty: []const u32 = &.{};
        const json = alloc_breakpoints_json(app.allocator, empty) catch {
            e.return_string("{\"error\":\"Failed to format breakpoints\"}");
            return;
        };
        return_json_owned(e, app.allocator, json);
        return;
    }

    {
        const json = alloc_error_json(app.allocator, "EVM not initialized") catch {
            e.return_string("{\"error\":\"EVM not initialized\"}");
            return;
        };
        return_json_owned(e, app.allocator, json);
    }
}

fn getBreakpointsHandler(e: *webui.Event) void {
    const app_ptr = e.get_ptr();
    const app: *App = @ptrCast(@alignCast(app_ptr));

    if (app.devtool_evm) |*evm| {
        const bps = evm.getBreakpoints(app.allocator) catch |err| {
            const msg = std.fmt.allocPrint(app.allocator, "Failed to get breakpoints: {}", .{err}) catch "Failed to get breakpoints";
            const json = alloc_error_json(app.allocator, if (@TypeOf(msg) == []const u8) msg else msg) catch null;
            if (@TypeOf(msg) == []u8) app.allocator.free(msg);
            if (json) |j| return_json_owned(e, app.allocator, j);
            e.return_string("{\"error\":\"Failed to get breakpoints\"}");
            return;
        };
        defer app.allocator.free(bps);

        const json = alloc_breakpoints_json(app.allocator, bps) catch {
            e.return_string("{\"error\":\"Failed to format breakpoints\"}");
            return;
        };
        return_json_owned(e, app.allocator, json);
        return;
    }

    {
        const json = alloc_error_json(app.allocator, "EVM not initialized") catch {
            e.return_string("{\"error\":\"EVM not initialized\"}");
            return;
        };
        return_json_owned(e, app.allocator, json);
    }
}

fn getAvailableBreakpointsHandler(e: *webui.Event) void {
    const app_ptr = e.get_ptr();
    const app: *App = @ptrCast(@alignCast(app_ptr));

    if (app.devtool_evm) |*evm| {
        const bps = evm.getAvailableBreakpoints(app.allocator) catch |err| {
            const msg = std.fmt.allocPrint(app.allocator, "Failed to get available breakpoints: {}", .{err}) catch "Failed to get available breakpoints";
            const json = alloc_error_json(app.allocator, if (@TypeOf(msg) == []const u8) msg else msg) catch null;
            if (@TypeOf(msg) == []u8) app.allocator.free(msg);
            if (json) |j| return_json_owned(e, app.allocator, j);
            e.return_string("{\"error\":\"Failed to get available breakpoints\"}");
            return;
        };
        defer app.allocator.free(bps);

        const json = alloc_breakpoints_json(app.allocator, bps) catch {
            e.return_string("{\"error\":\"Failed to format breakpoints\"}");
            return;
        };
        return_json_owned(e, app.allocator, json);
        return;
    }

    {
        const json = alloc_error_json(app.allocator, "EVM not initialized") catch {
            e.return_string("{\"error\":\"EVM not initialized\"}");
            return;
        };
        return_json_owned(e, app.allocator, json);
    }
}

pub fn init(allocator: std.mem.Allocator) !App {
    const window = webui.new_window();
    webui.set_config(.multi_client, true);

    // Initialize the DevtoolEvm
    const devtool_evm = DevtoolEvm.init(allocator) catch |err| {
        std.log.err("Failed to initialize DevtoolEvm: {}", .{err});
        return err;
    };

    return App{
        .window = window,
        .allocator = allocator,
        .devtool_evm = devtool_evm,
    };
}

pub fn deinit(self: *App) void {
    if (self.devtool_evm) |*evm| {
        evm.deinit();
    }
    webui.clean();
}

pub fn handler(filename: []const u8) ?[]const u8 {
    // If requesting root, serve index.html
    const path = if (std.mem.eql(u8, filename, "/")) "/index.html" else filename;

    const asset = assets.get_asset(path);
    return asset.response;
}

pub fn run(self: *App) !void {
    self.window.set_file_handler(handler);

    // Bind EVM functions and set context
    _ = try self.window.bind("load_bytecode", loadBytecodeHandler);
    self.window.set_context("load_bytecode", self);

    _ = try self.window.bind("reset_evm", resetEvmHandler);
    self.window.set_context("reset_evm", self);

    _ = try self.window.bind("step_evm", stepEvmHandler);
    self.window.set_context("step_evm", self);
    _ = try self.window.bind("block_evm", blockEvmHandler);
    self.window.set_context("block_evm", self);
    _ = try self.window.bind("run_evm", runEvmHandler);
    self.window.set_context("run_evm", self);

    _ = try self.window.bind("get_evm_state", getEvmStateHandler);
    self.window.set_context("get_evm_state", self);

    // Breakpoint management bindings
    _ = try self.window.bind("add_breakpoint", addBreakpointHandler);
    self.window.set_context("add_breakpoint", self);
    _ = try self.window.bind("remove_breakpoint", removeBreakpointHandler);
    self.window.set_context("remove_breakpoint", self);
    _ = try self.window.bind("clear_breakpoints", clearBreakpointsHandler);
    self.window.set_context("clear_breakpoints", self);
    _ = try self.window.bind("get_breakpoints", getBreakpointsHandler);
    self.window.set_context("get_breakpoints", self);
    _ = try self.window.bind("get_available_breakpoints", getAvailableBreakpointsHandler);
    self.window.set_context("get_available_breakpoints", self);

    // Try using the embedded file directly with @embedFile
    const html_content = @embedFile("dist/index.html");
    try self.window.show(html_content);

    // After showing the window, WebUI bindings are ready
    // Execute JavaScript to trigger initialization
    self.window.run(
        \\if (window.on_web_ui_ready) {
        \\    window.on_web_ui_ready();
        \\}
    );

    webui.wait();
}
