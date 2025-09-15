const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Build the CALL bytecode exactly as in common.zig
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    // This is what 0xf1 (CALL) generates:
    try buf.append(allocator, 0x5f); // PUSH0 for retLength
    try buf.append(allocator, 0x5f); // PUSH0 for retOffset
    try buf.append(allocator, 0x5f); // PUSH0 for argsLength
    try buf.append(allocator, 0x5f); // PUSH0 for argsOffset
    try buf.append(allocator, 0x5f); // PUSH0 for value
    try buf.append(allocator, 0x30); // ADDRESS
    try buf.append(allocator, 0x61); // PUSH2
    try buf.append(allocator, 0x27); // 0x2710 >> 8
    try buf.append(allocator, 0x10); // 0x2710 & 0xff (10000 gas)
    try buf.append(allocator, 0xf1); // CALL

    // ret_top32 sequence
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x00); // 0 (memory offset)
    try buf.append(allocator, 0x52); // MSTORE - stores top of stack at memory[0]
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x20); // 32 (length)
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x00); // 0 (offset)
    try buf.append(allocator, 0xf3); // RETURN

    const bytecode = buf.items;

    std.debug.print("CALL test bytecode (hex):\n", .{});
    for (bytecode, 0..) |byte, i| {
        std.debug.print("{d:2}: 0x{x:0>2}", .{i, byte});
        if (byte == 0x5f) std.debug.print(" PUSH0", .{});
        if (byte == 0x30) std.debug.print(" ADDRESS", .{});
        if (byte == 0x60) std.debug.print(" PUSH1", .{});
        if (byte == 0x61) std.debug.print(" PUSH2", .{});
        if (byte == 0x52) std.debug.print(" MSTORE", .{});
        if (byte == 0xf1) std.debug.print(" CALL", .{});
        if (byte == 0xf3) std.debug.print(" RETURN", .{});
        std.debug.print("\n", .{});
    }

    std.debug.print("\n", .{});
    std.debug.print("The issue: at PC=0, we have PUSH0 (0x5f)\n", .{});
    std.debug.print("Frame is incorrectly reporting this as PUSH_MSTORE_INLINE\n", .{});
    std.debug.print("This means the dispatch is being built wrong.\n", .{});
}