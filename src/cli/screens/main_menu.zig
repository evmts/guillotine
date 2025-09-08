const std = @import("std");
const Style = @import("../style.zig");

const MenuItem = struct {
    label: []const u8,
    screen: ?@import("../main.zig").Screen,
};

const menu_items = [_]MenuItem{
    .{ .label = "Make call", .screen = .call_type_select },
    .{ .label = "Call History", .screen = .call_history },
    .{ .label = "Contracts", .screen = .contracts_list },
    .{ .label = "Reset State", .screen = null },
    .{ .label = "Exit", .screen = null },
};

pub const MainMenu = @This();

allocator: std.mem.Allocator,
selected_index: usize,
animation_frame: u32,

pub fn init(allocator: std.mem.Allocator) !MainMenu {
    return MainMenu{
        .allocator = allocator,
        .selected_index = 0,
        .animation_frame = 0,
    };
}

pub fn deinit(self: *MainMenu) void {
    _ = self;
}

pub fn render(self: *MainMenu, writer: anytype, width: u16, height: u16) !void {
    // Animate
    self.animation_frame +%= 1;
    
    // Calculate positions
    const box_width: u16 = @min(width - 4, 80);
    const box_height: u16 = @min(height - 4, 30);
    const box_x = (width - box_width) / 2;
    const box_y = (height - box_height) / 2;
    
    // Draw outer box with double lines
    try Style.drawBox(writer, box_x, box_y, box_width, box_height, true);
    
    // Draw inner box for title
    const title_box_width = box_width - 4;
    const title_box_height: u16 = 7;
    try Style.drawBox(writer, box_x + 2, box_y + 2, title_box_width, title_box_height, false);
    
    // Draw title with animation
    const title = "GUILLOTINE";
    const subtitle = "HIGH-PERFORMANCE EVM IMPLEMENTATION";
    
    try writer.print("\x1b[{};{}H", .{ box_y + 4, box_x + 2 });
    try writer.print("{}{}{}", .{ 
        Style.Colors.primary_bright, 
        Style.Colors.bold,
        ""
    });
    try Style.centerText(writer, title, title_box_width);
    
    try writer.print("\x1b[{};{}H{}", .{ 
        box_y + 5, 
        box_x + 2,
        Style.Colors.secondary
    });
    try Style.centerText(writer, subtitle, title_box_width);
    try writer.writeAll(Style.Colors.reset);
    
    // Draw menu items
    const menu_start_y = box_y + 11;
    const menu_x = box_x + (box_width / 2) - 20;
    
    for (menu_items, 0..) |item, i| {
        const y = menu_start_y + @as(u16, @intCast(i)) * 2;
        const selected = i == self.selected_index;
        
        try writer.print("\x1b[{};{}H", .{ y, menu_x });
        
        if (selected) {
            // Animated selection indicator
            const anim_char = if ((self.animation_frame / 10) % 2 == 0) 
                Style.Icons.chevron_right 
            else 
                Style.Icons.arrow_right;
                
            try writer.print("{}{}{} {}{}{}", .{
                Style.Colors.primary_bright,
                Style.Colors.bold,
                anim_char,
                item.label,
                Style.Colors.reset,
                ""
            });
        } else {
            try writer.print("{}  {}{}", .{
                Style.Colors.text,
                item.label,
                Style.Colors.reset
            });
        }
    }
    
    // Draw help text
    const help_y = box_y + box_height - 2;
    try Style.drawHelpText(
        writer, 
        help_y, 
        width,
        "↑/↓ to navigate • Enter to select • q to quit"
    );
}

pub fn handleInput(self: *MainMenu, input: []const u8) !?@import("../main.zig").Screen {
    if (input.len == 0) return null;
    
    // Handle arrow keys
    if (input.len == 3 and input[0] == 27 and input[1] == '[') {
        switch (input[2]) {
            'A' => { // Up arrow
                if (self.selected_index > 0) {
                    self.selected_index -= 1;
                } else {
                    self.selected_index = menu_items.len - 1;
                }
            },
            'B' => { // Down arrow
                self.selected_index = (self.selected_index + 1) % menu_items.len;
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
                } else {
                    self.selected_index = menu_items.len - 1;
                }
            },
            'j', 'J' => { // Vim-style down
                self.selected_index = (self.selected_index + 1) % menu_items.len;
            },
            '\r', '\n' => { // Enter
                const item = menu_items[self.selected_index];
                
                // Handle special cases
                if (std.mem.eql(u8, item.label, "Exit")) {
                    std.process.exit(0);
                } else if (std.mem.eql(u8, item.label, "Reset State")) {
                    // TODO: Implement state reset
                    return null;
                }
                
                return item.screen;
            },
            else => {},
        }
    }
    
    return null;
}