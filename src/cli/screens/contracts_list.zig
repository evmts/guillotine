const std = @import("std");
const Style = @import("../style.zig");

const Contract = struct {
    address: []const u8,
    name: []const u8,
    balance: []const u8,
    tx_count: u32,
    last_interaction: []const u8,
};

// Mock data
const mock_contracts = [_]Contract{
    .{ .address = "0x7a250d5630B4cF539...", .name = "Uniswap V2 Router", .balance = "0.00 ETH", .tx_count = 1523489, .last_interaction = "2 mins ago" },
    .{ .address = "0xA0b86991c6218b36c1...", .name = "USDC Token", .balance = "0.00 ETH", .tx_count = 892341, .last_interaction = "5 mins ago" },
    .{ .address = "0xdAC17F958D2ee523a2...", .name = "Tether USD", .balance = "0.00 ETH", .tx_count = 734521, .last_interaction = "12 mins ago" },
    .{ .address = "0x514910771AF9Ca656a...", .name = "Chainlink Token", .balance = "0.00 ETH", .tx_count = 234156, .last_interaction = "1 hour ago" },
    .{ .address = "0xC02aaA39b223FE8D0A...", .name = "Wrapped Ether", .balance = "125.34 ETH", .tx_count = 1823456, .last_interaction = "3 hours ago" },
    .{ .address = "0x1f9840a85d5aF5bf1D...", .name = "Uniswap Token", .balance = "0.00 ETH", .tx_count = 123890, .last_interaction = "1 day ago" },
};

pub const ContractsList = @This();

allocator: std.mem.Allocator,
selected_index: usize,
scroll_offset: usize,

pub fn init(allocator: std.mem.Allocator) !ContractsList {
    return ContractsList{
        .allocator = allocator,
        .selected_index = 0,
        .scroll_offset = 0,
    };
}

pub fn deinit(self: *ContractsList) void {
    _ = self;
}

pub fn render(self: *ContractsList, writer: anytype, width: u16, height: u16) !void {
    // Calculate dimensions
    const box_width: u16 = @min(width - 4, 110);
    const box_height: u16 = @min(height - 4, 35);
    const box_x = (width - box_width) / 2;
    const box_y = (height - box_height) / 2;
    
    // Draw main box
    try Style.drawBox(writer, box_x, box_y, box_width, box_height, false);
    
    // Title section
    try writer.print("\x1b[{};{}H{}{}{}", .{
        box_y + 2,
        box_x + 4,
        Style.Colors.secondary,
        "CONTRACTS",
        Style.Colors.reset
    });
    
    try writer.print("\x1b[{};{}H{}{}{}", .{
        box_y + 3,
        box_x + 4,
        Style.Colors.text_dim,
        "Deployed smart contracts",
        Style.Colors.reset
    });
    
    // Separator
    try Style.drawSeparator(writer, box_y + 5, box_width);
    
    // Stats bar
    try writer.print("\x1b[{};{}H", .{ box_y + 7, box_x + 4 });
    try writer.print("{}Total: {}{} contracts   ", .{
        Style.Colors.text_dim,
        Style.Colors.warning,
        mock_contracts.len
    });
    try writer.print("{}Active: {}{}   ", .{
        Style.Colors.text_dim,
        Style.Colors.success,
        "4"
    });
    try writer.print("{}Inactive: {}{}{}", .{
        Style.Colors.text_dim,
        Style.Colors.err,
        "2",
        Style.Colors.reset
    });
    
    // Contracts list
    const list_start_y = box_y + 9;
    const visible_contracts = @min(mock_contracts.len, box_height - 15);
    
    for (0..visible_contracts) |i| {
        const contract = mock_contracts[i + self.scroll_offset];
        const y = list_start_y + @as(u16, @intCast(i)) * 3;
        const selected = i == self.selected_index;
        
        // Draw contract card
        if (selected) {
            // Highlight box for selected item
            const card_x = box_x + 4;
            const card_width = box_width - 8;
            
            try writer.print("\x1b[{};{}H{}", .{ y - 1, card_x, Style.Colors.primary });
            var j: u16 = 0;
            while (j < card_width) : (j += 1) {
                try writer.writeAll("─");
            }
            
            try writer.print("\x1b[{};{}H{}", .{ y + 1, card_x, Style.Colors.primary });
            j = 0;
            while (j < card_width) : (j += 1) {
                try writer.writeAll("─");
            }
            try writer.writeAll(Style.Colors.reset);
        }
        
        // Contract info line
        try writer.print("\x1b[{};{}H", .{ y, box_x + 6 });
        
        if (selected) {
            try writer.print("{}{}", .{ Style.Colors.primary_bright, Style.Icons.chevron_right });
        } else {
            try writer.writeAll("  ");
        }
        
        // Address and name
        try writer.print(" {s}{s:<25}{s} {s}{s:<20}{s}", .{
            if (selected) Style.Colors.primary_bright else Style.Colors.text_dim,
            contract.address,
            Style.Colors.reset,
            if (selected) Style.Colors.bold else "",
            contract.name,
            Style.Colors.reset
        });
        
        // Balance
        try writer.print(" {s}{s:<12}{s}", .{
            Style.Colors.warning,
            contract.balance,
            Style.Colors.reset
        });
        
        // Transaction count
        try writer.print(" {}TX: {}{}", .{
            Style.Colors.text_dim,
            Style.Colors.text,
            contract.tx_count
        });
        
        // Last interaction
        try writer.print("  {}{}{}", .{
            Style.Colors.text_dim,
            contract.last_interaction,
            Style.Colors.reset
        });
    }
    
    // Action buttons at bottom
    const button_y = box_y + box_height - 4;
    const center_x = box_x + (box_width / 2);
    
    try writer.print("\x1b[{};{}H", .{ button_y, center_x - 30 });
    try writer.print("{}[v] View Details   [i] Interact   [d] Deploy New   [Esc] Back{}", .{
        Style.Colors.text_dim,
        Style.Colors.reset
    });
    
    // Help text
    const help_y = box_y + box_height - 2;
    try Style.drawHelpText(
        writer,
        help_y,
        width,
        "↑↓ navigate • Enter to interact • Esc back"
    );
}

pub fn handleInput(self: *ContractsList, input: []const u8) !?@import("../main.zig").Screen {
    if (input.len == 0) return null;
    
    // Handle arrow keys
    if (input.len == 3 and input[0] == 27 and input[1] == '[') {
        switch (input[2]) {
            'A' => { // Up arrow
                if (self.selected_index > 0) {
                    self.selected_index -= 1;
                    if (self.selected_index < self.scroll_offset) {
                        self.scroll_offset = self.selected_index;
                    }
                }
            },
            'B' => { // Down arrow
                const max_index = @min(mock_contracts.len - 1, 20);
                if (self.selected_index < max_index) {
                    self.selected_index += 1;
                    const visible_rows = 8;
                    if (self.selected_index >= self.scroll_offset + visible_rows) {
                        self.scroll_offset = self.selected_index - visible_rows + 1;
                    }
                }
            },
            else => {},
        }
    }
    
    // Handle single key presses
    if (input.len == 1) {
        switch (input[0]) {
            'k', 'K' => { // Vim-style up
                if (self.selected_index > 0) {
                    self.selected_index -= 1;
                    if (self.selected_index < self.scroll_offset) {
                        self.scroll_offset = self.selected_index;
                    }
                }
            },
            'j', 'J' => { // Vim-style down
                const max_index = @min(mock_contracts.len - 1, 20);
                if (self.selected_index < max_index) {
                    self.selected_index += 1;
                    const visible_rows = 8;
                    if (self.selected_index >= self.scroll_offset + visible_rows) {
                        self.scroll_offset = self.selected_index - visible_rows + 1;
                    }
                }
            },
            '\r', '\n', 'i', 'I' => { // Enter or 'i' - interact with contract
                // TODO: Open interaction screen for selected contract
                return .call_config;
            },
            'v', 'V' => { // View details
                // TODO: Show contract details
                return null;
            },
            'd', 'D' => { // Deploy new contract
                // Switch to CREATE call type
                return .call_type_select;
            },
            27 => { // ESC
                return .main_menu;
            },
            else => {},
        }
    }
    
    return null;
}