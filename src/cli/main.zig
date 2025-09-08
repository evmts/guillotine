const std = @import("std");
const builtin = @import("builtin");

pub const c = @cImport({
    @cInclude("locale.h");
    @cInclude("termios.h");
});

const Style = @import("style.zig");
const MainMenu = @import("screens/main_menu.zig");
const CallConfig = @import("screens/call_config.zig");
const CallTypeSelect = @import("screens/call_type_select.zig");
const CallHistory = @import("screens/call_history.zig");
const ContractsList = @import("screens/contracts_list.zig");

pub const Screen = enum {
    main_menu,
    call_config,
    call_type_select,
    call_history,
    contracts_list,
};

const App = struct {
    allocator: std.mem.Allocator,
    screen: Screen,
    main_menu: MainMenu,
    call_config: CallConfig,
    call_type_select: CallTypeSelect,
    call_history: CallHistory,
    contracts_list: ContractsList,
    running: bool,
    tty: std.fs.File,
    original_termios: c.termios,
    width: u16,
    height: u16,

    pub fn init(allocator: std.mem.Allocator) !App {
        const tty = try std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write });
        
        // Get terminal size (simplified for now)
        const width: u16 = 80;
        const height: u16 = 24;
        
        var app = App{
            .allocator = allocator,
            .screen = .main_menu,
            .main_menu = try MainMenu.init(allocator),
            .call_config = try CallConfig.init(allocator),
            .call_type_select = try CallTypeSelect.init(allocator),
            .call_history = try CallHistory.init(allocator),
            .contracts_list = try ContractsList.init(allocator),
            .running = true,
            .tty = tty,
            .original_termios = undefined,
            .width = width,
            .height = height,
        };

        // Setup terminal
        try app.setupTerminal();
        
        return app;
    }

    pub fn deinit(self: *App) void {
        self.restoreTerminal() catch {};
        self.tty.close();
        self.main_menu.deinit();
        self.call_config.deinit();
        self.call_type_select.deinit();
        self.call_history.deinit();
        self.contracts_list.deinit();
    }

    fn setupTerminal(self: *App) !void {
        // Save original terminal settings
        _ = c.tcgetattr(self.tty.handle, &self.original_termios);

        // Setup raw mode
        var raw = self.original_termios;
        raw.c_iflag &= ~@as(c_uint, c.BRKINT | c.ICRNL | c.INPCK | c.ISTRIP | c.IXON);
        raw.c_oflag &= ~@as(c_uint, c.OPOST);
        raw.c_cflag |= c.CS8;
        raw.c_lflag &= ~@as(c_uint, c.ECHO | c.ICANON | c.IEXTEN | c.ISIG);
        raw.c_cc[c.VMIN] = 0;
        raw.c_cc[c.VTIME] = 1;

        _ = c.tcsetattr(self.tty.handle, c.TCSAFLUSH, &raw);

        // Hide cursor and clear screen
        _ = try self.tty.write("\x1b[?25l\x1b[2J\x1b[H");
    }

    fn restoreTerminal(self: *App) !void {
        // Show cursor and clear screen
        _ = try self.tty.write("\x1b[?25h\x1b[2J\x1b[H");
        
        // Restore original terminal settings
        _ = c.tcsetattr(self.tty.handle, c.TCSAFLUSH, &self.original_termios);
    }

    pub fn run(self: *App) !void {
        var buf: [256]u8 = undefined;
        
        while (self.running) {
            try self.render();
            
            // Read input
            const bytes_read = try self.tty.read(&buf);
            if (bytes_read > 0) {
                try self.handleInput(buf[0..bytes_read]);
            }
            
            std.Thread.sleep(16_666_667); // ~60 FPS
        }
    }

    fn render(self: *App) !void {
        // Clear screen and move to top
        _ = try self.tty.write("\x1b[2J\x1b[H");
        
        // Create a buffered writer for efficiency
        var buffer: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        const writer = fbs.writer();
        
        switch (self.screen) {
            .main_menu => try self.main_menu.render(writer, self.width, self.height),
            .call_config => try self.call_config.render(writer, self.width, self.height),
            .call_type_select => try self.call_type_select.render(writer, self.width, self.height),
            .call_history => try self.call_history.render(writer, self.width, self.height),
            .contracts_list => try self.contracts_list.render(writer, self.width, self.height),
        }
        
        // Write the buffer to the terminal
        _ = try self.tty.write(fbs.getWritten());
    }

    fn handleInput(self: *App, input: []const u8) !void {
        // Handle global quit command
        if (input.len == 1 and (input[0] == 'q' or input[0] == 'Q')) {
            if (self.screen == .main_menu) {
                self.running = false;
                return;
            }
        }

        // Handle ESC key (go back)
        if (input.len == 1 and input[0] == 27) {
            if (self.screen != .main_menu) {
                self.screen = .main_menu;
                return;
            }
        }

        // Delegate to current screen
        const result = switch (self.screen) {
            .main_menu => try self.main_menu.handleInput(input),
            .call_config => try self.call_config.handleInput(input),
            .call_type_select => try self.call_type_select.handleInput(input),
            .call_history => try self.call_history.handleInput(input),
            .contracts_list => try self.contracts_list.handleInput(input),
        };

        // Handle screen transitions
        if (result) |new_screen| {
            self.screen = new_screen;
            
            // Pass data between screens if needed
            switch (new_screen) {
                .call_config => {
                    if (self.call_type_select.selected_type) |call_type| {
                        self.call_config.call_type = call_type;
                    }
                },
                else => {},
            }
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try App.init(allocator);
    defer app.deinit();

    try app.run();
}