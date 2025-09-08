const std = @import("std");
const Style = @import("../style.zig");
const CallType = @import("call_config.zig").CallType;

const CallTypeInfo = struct {
    type: CallType,
    name: []const u8,
    description: []const u8,
};

const call_types = [_]CallTypeInfo{
    .{ 
        .type = .CALL, 
        .name = "CALL",
        .description = "Standard message call with value transfer"
    },
    .{ 
        .type = .STATICCALL, 
        .name = "STATICCALL",
        .description = "Read-only call, no state changes"
    },
    .{ 
        .type = .DELEGATECALL, 
        .name = "DELEGATECALL",
        .description = "Execute in caller's context"
    },
    .{ 
        .type = .CREATE, 
        .name = "CREATE",
        .description = "Deploy new contract"
    },
    .{ 
        .type = .CREATE2, 
        .name = "CREATE2",
        .description = "Deploy with deterministic address"
    },
};

pub const CallTypeSelect = @This();

allocator: std.mem.Allocator,
selected_index: usize,
selected_type: ?CallType,
animation_frame: u32,

pub fn init(allocator: std.mem.Allocator) !CallTypeSelect {
    return CallTypeSelect{
        .allocator = allocator,
        .selected_index = 0,
        .selected_type = null,
        .animation_frame = 0,
    };
}

pub fn deinit(self: *CallTypeSelect) void {
    _ = self;
}

pub fn render(self: *CallTypeSelect, writer: anytype, width: u16, height: u16) !void {
    self.animation_frame +%= 1;
    
    // Calculate dimensions
    const box_width: u16 = @min(width - 4, 80);
    const box_height: u16 = @min(height - 4, 25);
    const box_x = (width - box_width) / 2;
    const box_y = (height - box_height) / 2;
    
    // Clear area and draw main box
    try Style.drawBox(writer, box_x, box_y, box_width, box_height, false);
    
    // Title
    const title_y = box_y + 2;
    try writer.print("\x1b[{};{}H{}{}{}", .{
        title_y,
        box_x + 4,
        Style.Colors.secondary,
        "Select call type",
        Style.Colors.reset
    });
    
    // Separator
    try Style.drawSeparator(writer, box_y + 4, box_width);
    
    // Render call type options
    const options_start_y = box_y + 6;
    
    for (call_types, 0..) |call_type, i| {
        const y = options_start_y + @as(u16, @intCast(i)) * 3;
        const selected = i == self.selected_index;
        
        // Draw selection box if selected
        if (selected) {
            const select_box_width = box_width - 8;
            const select_box_x = box_x + 4;
            
            // Highlight box
            try writer.print("\x1b[{};{}H{}", .{ y - 1, select_box_x, Style.Colors.primary });
            var j: u16 = 0;
            while (j < select_box_width) : (j += 1) {
                try writer.writeAll(Style.Box.horizontal);
            }
            
            try writer.print("\x1b[{};{}H{}", .{ y + 1, select_box_x, Style.Colors.primary });
            j = 0;
            while (j < select_box_width) : (j += 1) {
                try writer.writeAll(Style.Box.horizontal);
            }
            try writer.writeAll(Style.Colors.reset);
        }
        
        // Type name with selection indicator
        try writer.print("\x1b[{};{}H", .{ y, box_x + 4 });
        
        if (selected) {
            try writer.print("{s}{s}{s}{s:<15}", .{
                Style.Colors.primary_bright,
                Style.Colors.bold,
                call_type.name,
                ""
            });
        } else {
            try writer.print("{s}{s:<15}", .{
                Style.Colors.warning,
                call_type.name
            });
        }
        
        // Description
        try writer.print("  {}{}{}", .{
            Style.Colors.text,
            call_type.description,
            Style.Colors.reset
        });
    }
    
    // Help text
    const help_y = box_y + box_height - 2;
    try Style.drawHelpText(
        writer,
        help_y,
        width,
        "↑↓ navigate • Enter select • Esc cancel"
    );
}

pub fn handleInput(self: *CallTypeSelect, input: []const u8) !?@import("../main.zig").Screen {
    if (input.len == 0) return null;
    
    // Handle arrow keys
    if (input.len == 3 and input[0] == 27 and input[1] == '[') {
        switch (input[2]) {
            'A' => { // Up arrow
                if (self.selected_index > 0) {
                    self.selected_index -= 1;
                } else {
                    self.selected_index = call_types.len - 1;
                }
            },
            'B' => { // Down arrow
                self.selected_index = (self.selected_index + 1) % call_types.len;
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
                    self.selected_index = call_types.len - 1;
                }
            },
            'j', 'J' => { // Vim-style down
                self.selected_index = (self.selected_index + 1) % call_types.len;
            },
            '\r', '\n' => { // Enter - select type
                self.selected_type = call_types[self.selected_index].type;
                return .call_config;
            },
            27 => { // ESC - go back
                return .main_menu;
            },
            // Number shortcuts
            '1' => {
                self.selected_index = 0;
                self.selected_type = call_types[0].type;
                return .call_config;
            },
            '2' => {
                self.selected_index = 1;
                self.selected_type = call_types[1].type;
                return .call_config;
            },
            '3' => {
                self.selected_index = 2;
                self.selected_type = call_types[2].type;
                return .call_config;
            },
            '4' => {
                self.selected_index = 3;
                self.selected_type = call_types[3].type;
                return .call_config;
            },
            '5' => {
                self.selected_index = 4;
                self.selected_type = call_types[4].type;
                return .call_config;
            },
            else => {},
        }
    }
    
    return null;
}