const std = @import("std");

// Color scheme - Professional gold/amber theme
pub const Colors = struct {
    pub const primary = "\x1b[38;2;255;183;77m";      // Gold/Amber
    pub const primary_bright = "\x1b[38;2;255;213;79m"; // Bright Gold
    pub const secondary = "\x1b[38;2;255;167;38m";     // Dark Orange
    pub const background = "\x1b[48;2;13;17;23m";      // Deep Dark Blue
    pub const text = "\x1b[38;2;248;248;242m";         // Off-white
    pub const text_dim = "\x1b[38;2;139;148;158m";     // Dimmed text
    pub const success = "\x1b[38;2;80;250;123m";       // Green
    pub const err = "\x1b[38;2;255;85;85m";            // Red
    pub const warning = "\x1b[38;2;255;184;108m";      // Orange
    pub const border = "\x1b[38;2;255;183;77m";        // Gold border
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const italic = "\x1b[3m";
    pub const underline = "\x1b[4m";
    pub const inverse = "\x1b[7m";
};

// Box drawing characters
pub const Box = struct {
    pub const horizontal = "─";
    pub const vertical = "│";
    pub const top_left = "┌";
    pub const top_right = "┐";
    pub const bottom_left = "└";
    pub const bottom_right = "┘";
    pub const cross = "┼";
    pub const t_down = "┬";
    pub const t_up = "┴";
    pub const t_right = "├";
    pub const t_left = "┤";
    
    // Double line variants
    pub const double_horizontal = "═";
    pub const double_vertical = "║";
    pub const double_top_left = "╔";
    pub const double_top_right = "╗";
    pub const double_bottom_left = "╚";
    pub const double_bottom_right = "╝";
};

// Icons and symbols
pub const Icons = struct {
    pub const arrow_right = "›";
    pub const arrow_down = "↓";
    pub const arrow_up = "↑";
    pub const chevron_right = "❯";
    pub const bullet = "•";
    pub const check = "✓";
    pub const cross = "✗";
    pub const star = "★";
    pub const dot = "·";
};

pub fn centerText(writer: anytype, text: []const u8, width: u16) !void {
    const padding = (width -| text.len) / 2;
    try writer.writeByteNTimes(' ', padding);
    try writer.writeAll(text);
}

pub fn drawBox(writer: anytype, x: u16, y: u16, width: u16, height: u16, double: bool) !void {
    const tl = if (double) Box.double_top_left else Box.top_left;
    const tr = if (double) Box.double_top_right else Box.top_right;
    const bl = if (double) Box.double_bottom_left else Box.bottom_left;
    const br = if (double) Box.double_bottom_right else Box.bottom_right;
    const h = if (double) Box.double_horizontal else Box.horizontal;
    const v = if (double) Box.double_vertical else Box.vertical;
    
    // Top border
    try writer.print("\x1b[{};{}H{}{}", .{ y, x, Colors.border, tl });
    var i: u16 = 0;
    while (i < width - 2) : (i += 1) {
        try writer.writeAll(h);
    }
    try writer.writeAll(tr);
    
    // Side borders
    i = 1;
    while (i < height - 1) : (i += 1) {
        try writer.print("\x1b[{};{}H{}", .{ y + i, x, v });
        try writer.print("\x1b[{};{}H{}", .{ y + i, x + width - 1, v });
    }
    
    // Bottom border
    try writer.print("\x1b[{};{}H{}", .{ y + height - 1, x, bl });
    i = 0;
    while (i < width - 2) : (i += 1) {
        try writer.writeAll(h);
    }
    try writer.writeAll(br);
    try writer.writeAll(Colors.reset);
}

pub fn drawTitle(writer: anytype, title: []const u8, subtitle: []const u8, y: u16, width: u16) !void {
    // Main title
    try writer.print("\x1b[{};{}H", .{ y, 1 });
    try writer.print("{}{}{}", .{ Colors.primary_bright, Colors.bold, "" });
    try centerText(writer, title, width);
    try writer.writeAll(Colors.reset);
    
    // Subtitle
    if (subtitle.len > 0) {
        try writer.print("\x1b[{};{}H", .{ y + 1, 1 });
        try writer.print("{}", .{Colors.text_dim});
        try centerText(writer, subtitle, width);
        try writer.writeAll(Colors.reset);
    }
}

pub fn drawSeparator(writer: anytype, y: u16, width: u16) !void {
    try writer.print("\x1b[{};1H{}", .{ y, Colors.border });
    var i: u16 = 0;
    while (i < width) : (i += 1) {
        try writer.writeAll(Box.horizontal);
    }
    try writer.writeAll(Colors.reset);
}

pub fn drawMenuItem(writer: anytype, x: u16, y: u16, text: []const u8, selected: bool, width: u16) !void {
    try writer.print("\x1b[{};{}H", .{ y, x });
    
    if (selected) {
        try writer.print("{}{} {} {} {}", .{
            Colors.primary_bright,
            Icons.chevron_right,
            Colors.bold,
            text,
            Colors.reset,
        });
    } else {
        try writer.print("  {}{}{}", .{
            Colors.text,
            text,
            Colors.reset,
        });
    }
    
    // Clear rest of line
    const text_len = text.len + 3;
    if (text_len < width) {
        var i: usize = text_len;
        while (i < width) : (i += 1) {
            try writer.writeAll(" ");
        }
    }
}

pub fn drawInput(writer: anytype, x: u16, y: u16, label: []const u8, value: []const u8, width: u16, focused: bool) !void {
    // Label
    try writer.print("\x1b[{};{}H{}{:<20}{}", .{ 
        y, x, 
        Colors.text_dim,
        label,
        Colors.reset 
    });
    
    // Value box
    const value_x = x + 20;
    const value_width = width -| 22;
    
    if (focused) {
        try writer.print("\x1b[{};{}H{}", .{ y, value_x, Colors.primary_bright });
    } else {
        try writer.print("\x1b[{};{}H{}", .{ y, value_x, Colors.text });
    }
    
    if (value.len > 0) {
        try writer.writeAll(value);
    } else {
        try writer.print("{}<empty>{}", .{ Colors.text_dim, Colors.reset });
    }
    
    // Clear rest of field
    const content_len = if (value.len > 0) value.len else 7; // "<empty>" is 7 chars
    if (content_len < value_width) {
        var i: usize = content_len;
        while (i < value_width) : (i += 1) {
            try writer.writeAll(" ");
        }
    }
    
    try writer.writeAll(Colors.reset);
}

pub fn drawButton(writer: anytype, x: u16, y: u16, text: []const u8, selected: bool) !void {
    try writer.print("\x1b[{};{}H", .{ y, x });
    
    if (selected) {
        try writer.print("{}{}[{}{}{}{}{}]{}", .{
            Colors.primary_bright,
            Colors.bold,
            Colors.background,
            Colors.primary_bright,
            " ",
            text,
            " ",
            Colors.reset,
        });
    } else {
        try writer.print("{}[ {} ]{}", .{
            Colors.border,
            text,
            Colors.reset,
        });
    }
}

pub fn drawHelpText(writer: anytype, y: u16, width: u16, text: []const u8) !void {
    try writer.print("\x1b[{};{}H{}", .{ y, 1, Colors.text_dim });
    try centerText(writer, text, width);
    try writer.writeAll(Colors.reset);
}