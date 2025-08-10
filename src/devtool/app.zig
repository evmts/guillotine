const std = @import("std");
const webui = @import("webui/webui.zig");
const assets = @import("assets.zig");
const DevtoolEvm = @import("evm.zig");

const App = @This();

window: webui,
allocator: std.mem.Allocator,
devtool_evm: ?DevtoolEvm,

// Hello world handler function
fn helloWorldHandler(e: *webui.Event) void {
    const name = e.get_string(); // Get the name parameter from JavaScript

    // Create a response message
    var buffer: [256]u8 = undefined;
    const response = std.fmt.bufPrint(&buffer, "Hello from Zig, {s}! The backend is working.", .{name}) catch "Hello from Zig! Buffer overflow.";

    // Return the response to JavaScript
    // We need to convert the response to a null-terminated string
    var null_terminated_buffer: [256:0]u8 = undefined;
    const len = @min(response.len, 255);
    @memcpy(null_terminated_buffer[0..len], response[0..len]);
    null_terminated_buffer[len] = 0;

    e.return_string(null_terminated_buffer[0..len :0]);
}

// EVM Handler Functions
fn loadBytecodeHandler(e: *webui.Event) void {
    const bytecode_hex = e.get_string();
    const app_ptr = e.get_ptr();
    const app: *App = @ptrCast(@alignCast(app_ptr));

    if (app.devtool_evm) |*evm| {
        evm.loadBytecodeHex(bytecode_hex) catch |err| {
            const error_msg = switch (err) {
                error.EmptyBytecode => "Bytecode cannot be empty",
                error.InvalidHexLength => "Hex string must have even number of characters",
                error.InvalidHexCharacter => "Bytecode contains invalid hex characters",
                error.OutOfMemory => "Out of memory",
                else => "Unknown error loading bytecode",
            };

            var buffer: [512]u8 = undefined;
            const json_msg = std.fmt.bufPrint(&buffer, "{{\"error\": \"{s}\"}}", .{error_msg}) catch "{{\"error\": \"Failed to load bytecode\"}}";

            var null_terminated_buffer: [512:0]u8 = undefined;
            const len = @min(json_msg.len, 511);
            @memcpy(null_terminated_buffer[0..len], json_msg[0..len]);
            null_terminated_buffer[len] = 0;
            e.return_string(null_terminated_buffer[0..len :0]);
            return;
        };
    }

    e.return_string("{\"success\": true}");
}

fn resetEvmHandler(e: *webui.Event) void {
    const app_ptr = e.get_ptr();
    const app: *App = @ptrCast(@alignCast(app_ptr));

    if (app.devtool_evm) |*evm| {
        evm.resetExecution() catch |err| {
            var buffer: [512]u8 = undefined;
            const error_msg = std.fmt.bufPrint(&buffer, "{{\"error\": \"Failed to reset EVM: {}\"}}", .{err}) catch "{{\"error\": \"Failed to reset EVM\"}}";

            var null_terminated_buffer: [512:0]u8 = undefined;
            const len = @min(error_msg.len, 511);
            @memcpy(null_terminated_buffer[0..len], error_msg[0..len]);
            null_terminated_buffer[len] = 0;
            e.return_string(null_terminated_buffer[0..len :0]);
            return;
        };

        const state_json = evm.serializeEvmState() catch |err| {
            var buffer: [512]u8 = undefined;
            const error_msg = std.fmt.bufPrint(&buffer, "{{\"error\": \"Failed to serialize state: {}\"}}", .{err}) catch "{{\"error\": \"Failed to serialize state\"}}";

            var null_terminated_buffer: [512:0]u8 = undefined;
            const len = @min(error_msg.len, 511);
            @memcpy(null_terminated_buffer[0..len], error_msg[0..len]);
            null_terminated_buffer[len] = 0;
            e.return_string(null_terminated_buffer[0..len :0]);
            return;
        };
        defer app.allocator.free(state_json);

        var null_terminated_buffer: [4096:0]u8 = undefined;
        const len = @min(state_json.len, 4095);
        @memcpy(null_terminated_buffer[0..len], state_json[0..len]);
        null_terminated_buffer[len] = 0;
        e.return_string(null_terminated_buffer[0..len :0]);
    } else {
        e.return_string("{\"error\": \"EVM not initialized\"}");
    }
}

fn stepEvmHandler(e: *webui.Event) void {
    const app_ptr = e.get_ptr();
    const app: *App = @ptrCast(@alignCast(app_ptr));

    if (app.devtool_evm) |*evm| {
        const step_result = evm.stepExecute() catch |err| {
            var buffer: [512]u8 = undefined;
            const error_msg = std.fmt.bufPrint(&buffer, "{{\"error\": \"Failed to step EVM: {}\"}}", .{err}) catch "{{\"error\": \"Failed to step EVM\"}}";

            var null_terminated_buffer: [512:0]u8 = undefined;
            const len = @min(error_msg.len, 511);
            @memcpy(null_terminated_buffer[0..len], error_msg[0..len]);
            null_terminated_buffer[len] = 0;
            e.return_string(null_terminated_buffer[0..len :0]);
            return;
        };
        _ = step_result; // Use the step result if needed for logging

        const state_json = evm.serializeEvmState() catch |err| {
            var buffer: [512]u8 = undefined;
            const error_msg = std.fmt.bufPrint(&buffer, "{{\"error\": \"Failed to serialize state: {}\"}}", .{err}) catch "{{\"error\": \"Failed to serialize state\"}}";

            var null_terminated_buffer: [512:0]u8 = undefined;
            const len = @min(error_msg.len, 511);
            @memcpy(null_terminated_buffer[0..len], error_msg[0..len]);
            null_terminated_buffer[len] = 0;
            e.return_string(null_terminated_buffer[0..len :0]);
            return;
        };
        defer app.allocator.free(state_json);

        var null_terminated_buffer: [4096:0]u8 = undefined;
        const len = @min(state_json.len, 4095);
        @memcpy(null_terminated_buffer[0..len], state_json[0..len]);
        null_terminated_buffer[len] = 0;
        e.return_string(null_terminated_buffer[0..len :0]);
    } else {
        e.return_string("{\"error\": \"EVM not initialized\"}");
    }
}

fn getEvmStateHandler(e: *webui.Event) void {
    const app_ptr = e.get_ptr();
    const app: *App = @ptrCast(@alignCast(app_ptr));

    if (app.devtool_evm) |*evm| {
        const state_json = evm.serializeEvmState() catch |err| {
            var buffer: [512]u8 = undefined;
            const error_msg = std.fmt.bufPrint(&buffer, "{{\"error\": \"Failed to serialize state: {}\"}}", .{err}) catch "{{\"error\": \"Failed to serialize state\"}}";

            var null_terminated_buffer: [512:0]u8 = undefined;
            const len = @min(error_msg.len, 511);
            @memcpy(null_terminated_buffer[0..len], error_msg[0..len]);
            null_terminated_buffer[len] = 0;
            e.return_string(null_terminated_buffer[0..len :0]);
            return;
        };
        defer app.allocator.free(state_json);

        var null_terminated_buffer: [4096:0]u8 = undefined;
        const len = @min(state_json.len, 4095);
        @memcpy(null_terminated_buffer[0..len], state_json[0..len]);
        null_terminated_buffer[len] = 0;
        e.return_string(null_terminated_buffer[0..len :0]);
    } else {
        e.return_string("{\"error\": \"EVM not initialized\"}");
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

    // Bind the hello world function so JavaScript can call it
    _ = try self.window.bind("hello_world", helloWorldHandler);

    // Bind EVM functions and set context
    _ = try self.window.bind("load_bytecode", loadBytecodeHandler);
    self.window.set_context("load_bytecode", self);

    _ = try self.window.bind("reset_evm", resetEvmHandler);
    self.window.set_context("reset_evm", self);

    _ = try self.window.bind("step_evm", stepEvmHandler);
    self.window.set_context("step_evm", self);

    _ = try self.window.bind("get_evm_state", getEvmStateHandler);
    self.window.set_context("get_evm_state", self);

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
