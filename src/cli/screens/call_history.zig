const std = @import("std");
const Style = @import("../style.zig");

const CallRecord = struct {
    timestamp: []const u8,
    call_type: []const u8,
    target_address: []const u8,
    result: []const u8,
    gas_used: []const u8,
    success: bool,
};

// Mock data
const mock_history = [_]CallRecord{
    .{ .timestamp = "2024-04-24 17", .call_type = "CREATE2", .target_address = "0xd4c69...99bc1e", .result = "SUCCESS", .gas_used = "2007234", .success = true },
    .{ .timestamp = "2024-04-24 16", .call_type = "STATICCALL", .target_address = "0xf8a62...777356", .result = "FAIL", .gas_used = "1983422", .success = false },
    .{ .timestamp = "2024-04-24 16", .call_type = "CALL", .target_address = "0x62b0c1..cce8c8", .result = "SUCCESS", .gas_used = "30268", .success = true },
    .{ .timestamp = "2024-04-24 15", .call_type = "CREATE", .target_address = "0xd24a6...8d8ca6", .result = "SUCCESS", .gas_used = "1370664", .success = true },
    .{ .timestamp = "2024-04-24 15", .call_type = "DELEGATECALL", .target_address = "0x31922...f23a73", .result = "SUCCESS", .gas_used = "91450", .success = true },
};

const MenuItem = enum {
    history_list,
    view_details,
    replay_call,
    clear_history,
};

pub const CallHistory = @This();

allocator: std.mem.Allocator,
selected_row: usize,
selected_menu: MenuItem,
scroll_offset: usize,
total_entries: usize,

pub fn init(allocator: std.mem.Allocator) !CallHistory {
    return CallHistory{
        .allocator = allocator,
        .selected_row = 0,
        .selected_menu = .history_list,
        .scroll_offset = 0,
        .total_entries = 23, // Mock total
    };
}

pub fn deinit(self: *CallHistory) void {
    _ = self;
}

pub fn render(self: *CallHistory, writer: anytype, width: u16, height: u16) !void {
    // Calculate dimensions
    const box_width: u16 = @min(width - 4, 120);
    const box_height: u16 = @min(height - 4, 35);
    const box_x = (width - box_width) / 2;
    const box_y = (height - box_height) / 2;
    
    // Draw main box
    try Style.drawBox(writer, box_x, box_y, box_width, box_height, false);
    
    // Title
    try writer.print("\x1b[{};{}H{}{}{}", .{
        box_y + 2,
        box_x + 4,
        Style.Colors.secondary,
        "CALL HISTORY",
        Style.Colors.reset
    });
    
    try writer.print("\x1b[{};{}H{}{}{}", .{
        box_y + 3,
        box_x + 4,
        Style.Colors.text_dim,
        "Browse previous EVM calls",
        Style.Colors.reset
    });
    
    // Table box
    const table_y = box_y + 5;
    const table_height = box_height - 14;
    const table_width = box_width - 8;
    const table_x = box_x + 4;
    
    try Style.drawBox(writer, table_x, table_y, table_width, table_height, false);
    
    // Table header
    try writer.print("\x1b[{};{}H{}", .{
        table_y + 1,
        table_x + 2,
        Style.Colors.text_dim
    });
    
    try writer.print("{s:<15} {s:<13} {s:<20} {s:<10} {s:<10}", .{
        "Timestamp",
        "Call Type",
        "Target Address",
        "Result",
        "Gas Used"
    });
    try writer.writeAll(Style.Colors.reset);
    
    // Header separator
    try writer.print("\x1b[{};{}H{}", .{ table_y + 2, table_x + 1, Style.Colors.border });
    var i: u16 = 0;
    while (i < table_width - 2) : (i += 1) {
        try writer.writeAll(Style.Box.horizontal);
    }
    try writer.writeAll(Style.Colors.reset);
    
    // Table rows
    const visible_rows = @min(mock_history.len, table_height - 4);
    
    for (0..visible_rows) |row_idx| {
        const record = mock_history[row_idx + self.scroll_offset];
        const y = table_y + 3 + @as(u16, @intCast(row_idx));
        const selected = self.selected_menu == .history_list and row_idx == self.selected_row;
        
        try writer.print("\x1b[{};{}H", .{ y, table_x + 2 });
        
        if (selected) {
            try writer.print("{}{}", .{ Style.Colors.primary_bright, Style.Colors.bold });
        } else {
            try writer.writeAll(Style.Colors.text);
        }
        
        // Timestamp
        try writer.print("{s:<15} ", .{record.timestamp});
        
        // Call type
        try writer.print("{s:<13} ", .{record.call_type});
        
        // Target address
        try writer.print("{s:<20} ", .{record.target_address});
        
        // Result with color
        if (record.success) {
            try writer.print("{s}{s:<10}{s} ", .{ 
                Style.Colors.success, 
                record.result,
                if (selected) Style.Colors.primary_bright else Style.Colors.text
            });
        } else {
            try writer.print("{s}{s:<10}{s} ", .{ 
                Style.Colors.err, 
                record.result,
                if (selected) Style.Colors.primary_bright else Style.Colors.text
            });
        }
        
        // Gas used
        try writer.print("{s:<10}", .{record.gas_used});
        
        try writer.writeAll(Style.Colors.reset);
    }
    
    // Entry count
    try writer.print("\x1b[{};{}H{}{} entries{}", .{
        table_y + table_height - 2,
        table_x + 2,
        Style.Colors.warning,
        self.total_entries,
        Style.Colors.reset
    });
    
    // Menu options
    const menu_y = box_y + box_height - 6;
    const menu_items = [_]struct { item: MenuItem, label: []const u8 }{
        .{ .item = .view_details, .label = "View details" },
        .{ .item = .replay_call, .label = "Replay call" },
        .{ .item = .clear_history, .label = "Clear history" },
    };
    
    for (menu_items, 0..) |menu_item, idx| {
        const y = menu_y + @as(u16, @intCast(idx));
        const selected = self.selected_menu == menu_item.item;
        
        try writer.print("\x1b[{};{}H", .{ y, table_x + 2 });
        
        if (selected) {
            try writer.print("{}{}{} {}{}", .{
                Style.Colors.primary_bright,
                Style.Colors.bold,
                Style.Icons.chevron_right,
                menu_item.label,
                Style.Colors.reset
            });
        } else {
            try writer.print("{}  {}{}", .{
                Style.Colors.text_dim,
                menu_item.label,
                Style.Colors.reset
            });
        }
    }
    
    // Help text
    const help_y = box_y + box_height - 2;
    try Style.drawHelpText(
        writer,
        help_y,
        width,
        "↑↓ navigate  ENTER view details  c clear  Esc back"
    );
}

pub fn handleInput(self: *CallHistory, input: []const u8) !?@import("../main.zig").Screen {
    if (input.len == 0) return null;
    
    // Handle arrow keys
    if (input.len == 3 and input[0] == 27 and input[1] == '[') {
        switch (input[2]) {
            'A' => { // Up arrow
                if (self.selected_menu == .history_list) {
                    if (self.selected_row > 0) {
                        self.selected_row -= 1;
                    }
                } else {
                    self.navigateMenuUp();
                }
            },
            'B' => { // Down arrow
                if (self.selected_menu == .history_list) {
                    const max_rows = @min(mock_history.len, 10) - 1;
                    if (self.selected_row < max_rows) {
                        self.selected_row += 1;
                    } else {
                        self.selected_menu = .view_details;
                    }
                } else {
                    self.navigateMenuDown();
                }
            },
            else => {},
        }
    }
    
    // Handle single key presses
    if (input.len == 1) {
        switch (input[0]) {
            'k', 'K' => { // Vim-style up
                if (self.selected_menu == .history_list) {
                    if (self.selected_row > 0) {
                        self.selected_row -= 1;
                    }
                } else {
                    self.navigateMenuUp();
                }
            },
            'j', 'J' => { // Vim-style down
                if (self.selected_menu == .history_list) {
                    const max_rows = @min(mock_history.len, 10) - 1;
                    if (self.selected_row < max_rows) {
                        self.selected_row += 1;
                    } else {
                        self.selected_menu = .view_details;
                    }
                } else {
                    self.navigateMenuDown();
                }
            },
            '\r', '\n' => { // Enter
                switch (self.selected_menu) {
                    .view_details => {
                        // TODO: Show details view
                        return null;
                    },
                    .replay_call => {
                        // TODO: Replay the selected call
                        return .call_config;
                    },
                    .clear_history => {
                        // TODO: Clear history
                        return null;
                    },
                    .history_list => {
                        // View details of selected row
                        return null;
                    },
                }
            },
            'c', 'C' => { // Clear history shortcut
                // TODO: Clear history
                return null;
            },
            27 => { // ESC
                return .main_menu;
            },
            else => {},
        }
    }
    
    return null;
}

fn navigateMenuUp(self: *CallHistory) void {
    self.selected_menu = switch (self.selected_menu) {
        .history_list => .history_list,
        .view_details => .history_list,
        .replay_call => .view_details,
        .clear_history => .replay_call,
    };
}

fn navigateMenuDown(self: *CallHistory) void {
    self.selected_menu = switch (self.selected_menu) {
        .history_list => .view_details,
        .view_details => .replay_call,
        .replay_call => .clear_history,
        .clear_history => .clear_history,
    };
}