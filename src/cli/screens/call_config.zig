const std = @import("std");
const Style = @import("../style.zig");

pub const CallType = enum {
    CALL,
    STATICCALL,
    DELEGATECALL,
    CREATE,
    CREATE2,
};

const Field = enum {
    call_type,
    caller_address,
    target_address,
    value,
    input_data,
    gas_limit,
    salt,
    execute_button,
    back_button,
};

pub const CallConfig = @This();

allocator: std.mem.Allocator,
call_type: CallType,
caller_address: std.ArrayList(u8),
target_address: std.ArrayList(u8),
value: std.ArrayList(u8),
input_data: std.ArrayList(u8),
gas_limit: std.ArrayList(u8),
salt: std.ArrayList(u8),
selected_field: Field,
editing: bool,

pub fn init(allocator: std.mem.Allocator) !CallConfig {
    var config = CallConfig{
        .allocator = allocator,
        .call_type = .CALL,
        .caller_address = std.ArrayList(u8){},
        .target_address = std.ArrayList(u8){},
        .value = std.ArrayList(u8){},
        .input_data = std.ArrayList(u8){},
        .gas_limit = std.ArrayList(u8){},
        .salt = std.ArrayList(u8){},
        .selected_field = .call_type,
        .editing = false,
    };
    
    // Set default values
    try config.caller_address.appendSlice(allocator, "0x0c000aaac0d20c0bC3c832c");
    try config.target_address.appendSlice(allocator, "0x0c000aaac0d20c0bC3c832c");
    try config.input_data.append(allocator, '0');
    try config.gas_limit.append(allocator, '0');
    
    return config;
}

pub fn deinit(self: *CallConfig) void {
    self.caller_address.deinit(self.allocator);
    self.target_address.deinit(self.allocator);
    self.value.deinit(self.allocator);
    self.input_data.deinit(self.allocator);
    self.gas_limit.deinit(self.allocator);
    self.salt.deinit(self.allocator);
}

pub fn render(self: *CallConfig, writer: anytype, width: u16, height: u16) !void {
    // Draw main box
    const box_width: u16 = @min(width - 4, 100);
    const box_height: u16 = @min(height - 4, 35);
    const box_x = (width - box_width) / 2;
    const box_y = (height - box_height) / 2;
    
    try Style.drawBox(writer, box_x, box_y, box_width, box_height, false);
    
    // Title
    try writer.print("\x1b[{};{}H{}{}{}", .{
        box_y + 2,
        box_x + 4,
        Style.Colors.primary_bright,
        Style.Colors.bold,
        "GUILLOTINE"
    });
    try writer.writeAll(Style.Colors.reset);
    
    // Separator
    try Style.drawSeparator(writer, box_y + 4, box_width);
    
    // Subtitle
    try writer.print("\x1b[{};{}H{}{}{}", .{
        box_y + 6,
        box_x + 4,
        Style.Colors.secondary,
        "Configure call parameters",
        Style.Colors.reset
    });
    
    // Another separator
    try Style.drawSeparator(writer, box_y + 8, box_width);
    
    // Render fields
    const field_x = box_x + 4;
    var field_y = box_y + 10;
    
    // Call type
    try self.renderCallTypeField(writer, field_x, field_y, box_width - 8);
    field_y += 2;
    
    // Caller address
    try self.renderField(writer, field_x, field_y, "Caller address", self.caller_address.items, 
        box_width - 8, self.selected_field == .caller_address);
    field_y += 2;
    
    // Target address
    try self.renderField(writer, field_x, field_y, "Target address", self.target_address.items,
        box_width - 8, self.selected_field == .target_address);
    field_y += 2;
    
    // Value
    const value_str = if (self.value.items.len > 0) self.value.items else "";
    try self.renderField(writer, field_x, field_y, "Value (wei)", value_str,
        box_width - 8, self.selected_field == .value);
    field_y += 2;
    
    // Input data
    try self.renderField(writer, field_x, field_y, "Input data", self.input_data.items,
        box_width - 8, self.selected_field == .input_data);
    field_y += 2;
    
    // Gas limit
    try self.renderField(writer, field_x, field_y, "Gas limit", self.gas_limit.items,
        box_width - 8, self.selected_field == .gas_limit);
    field_y += 2;
    
    // Salt (only for CREATE2)
    if (self.call_type == .CREATE2) {
        try self.renderField(writer, field_x, field_y, "Salt", self.salt.items,
            box_width - 8, self.selected_field == .salt);
        field_y += 2;
    } else {
        try self.renderField(writer, field_x, field_y, "Salt", "-",
            box_width - 8, false);
        field_y += 2;
    }
    
    // Separator before buttons
    try Style.drawSeparator(writer, field_y + 1, box_width);
    
    // Buttons
    const button_y = field_y + 3;
    const button_spacing: u16 = 25;
    const execute_x = box_x + (box_width / 2) - button_spacing;
    const back_x = box_x + (box_width / 2) + 5;
    
    try Style.drawButton(writer, execute_x, button_y, "Execute call", 
        self.selected_field == .execute_button);
    try Style.drawButton(writer, back_x, button_y, "Back to menu",
        self.selected_field == .back_button);
    
    // Help text
    const help_y = box_y + box_height - 2;
    const help_text = if (self.editing)
        "Type to edit • Enter to confirm • Esc to cancel"
    else
        "↑↓ navigate  Enter edit  e execute  Esc back";
    try Style.drawHelpText(writer, help_y, width, help_text);
}

fn renderCallTypeField(self: *CallConfig, writer: anytype, x: u16, y: u16, width: u16) !void {
    const label = "Call type";
    const value = switch (self.call_type) {
        .CALL => "CALL",
        .STATICCALL => "STATICCALL",
        .DELEGATECALL => "DELEGATECALL",
        .CREATE => "CREATE",
        .CREATE2 => "CREATE2",
    };
    
    try Style.drawInput(writer, x, y, label, value, width, self.selected_field == .call_type);
}

fn renderField(self: *CallConfig, writer: anytype, x: u16, y: u16, label: []const u8, 
               value: []const u8, width: u16, focused: bool) !void {
    _ = self;
    try Style.drawInput(writer, x, y, label, value, width, focused);
}

pub fn handleInput(self: *CallConfig, input: []const u8) !?@import("../main.zig").Screen {
    if (input.len == 0) return null;
    
    if (self.editing) {
        return try self.handleEditMode(input);
    }
    
    // Handle arrow keys
    if (input.len == 3 and input[0] == 27 and input[1] == '[') {
        switch (input[2]) {
            'A' => { // Up arrow
                self.navigateUp();
            },
            'B' => { // Down arrow
                self.navigateDown();
            },
            else => {},
        }
    }
    
    // Handle single key presses
    if (input.len == 1) {
        switch (input[0]) {
            'k', 'K' => self.navigateUp(),
            'j', 'J' => self.navigateDown(),
            '\r', '\n' => {
                switch (self.selected_field) {
                    .execute_button => {
                        // TODO: Execute the call
                        return null;
                    },
                    .back_button => {
                        return .main_menu;
                    },
                    .call_type => {
                        return .call_type_select;
                    },
                    else => {
                        self.editing = true;
                    },
                }
            },
            'e', 'E' => {
                // Quick execute
                // TODO: Execute the call
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

fn handleEditMode(self: *CallConfig, input: []const u8) !?@import("../main.zig").Screen {
    if (input.len == 1) {
        switch (input[0]) {
            27 => { // ESC - cancel editing
                self.editing = false;
                return null;
            },
            '\r', '\n' => { // Enter - confirm editing
                self.editing = false;
                return null;
            },
            127, 8 => { // Backspace
                const list = self.getCurrentFieldList() orelse return null;
                if (list.items.len > 0) {
                    _ = list.pop();
                }
            },
            else => |c| {
                if (std.ascii.isPrint(c)) {
                    const list = self.getCurrentFieldList() orelse return null;
                    try list.append(self.allocator, c);
                }
            },
        }
    }
    
    return null;
}

fn getCurrentFieldList(self: *CallConfig) ?*std.ArrayList(u8) {
    return switch (self.selected_field) {
        .caller_address => &self.caller_address,
        .target_address => &self.target_address,
        .value => &self.value,
        .input_data => &self.input_data,
        .gas_limit => &self.gas_limit,
        .salt => if (self.call_type == .CREATE2) &self.salt else null,
        else => null,
    };
}

fn navigateUp(self: *CallConfig) void {
    self.selected_field = switch (self.selected_field) {
        .call_type => .back_button,
        .caller_address => .call_type,
        .target_address => .caller_address,
        .value => .target_address,
        .input_data => .value,
        .gas_limit => .input_data,
        .salt => .gas_limit,
        .execute_button => if (self.call_type == .CREATE2) .salt else .gas_limit,
        .back_button => .execute_button,
    };
}

fn navigateDown(self: *CallConfig) void {
    self.selected_field = switch (self.selected_field) {
        .call_type => .caller_address,
        .caller_address => .target_address,
        .target_address => .value,
        .value => .input_data,
        .input_data => .gas_limit,
        .gas_limit => if (self.call_type == .CREATE2) .salt else .execute_button,
        .salt => .execute_button,
        .execute_button => .back_button,
        .back_button => .call_type,
    };
}