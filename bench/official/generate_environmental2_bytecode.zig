const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();

    // Runtime code starts here
    const runtime_start = bytecode.items.len;

    // Initialize loop counter
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x00); // 0 (counter)

    // Loop start position
    const loop_start = bytecode.items.len;

    // DUP1 to duplicate counter for comparison
    try bytecode.append(0x80); // DUP1

    // Push 1000 (0x03E8) for comparison
    try bytecode.append(0x61); // PUSH2
    try bytecode.append(0x03); // 0x03E8 (1000)
    try bytecode.append(0xE8);

    // LT - check if counter < 1000
    try bytecode.append(0x10); // LT

    // JUMPI to exit if counter >= 1000
    const jumpi_pos = bytecode.items.len;
    try bytecode.append(0x61); // PUSH2
    try bytecode.append(0x00); // Placeholder for jump destination
    try bytecode.append(0x00);
    try bytecode.append(0x57); // JUMPI

    // Loop body - Environmental operations part 2

    // CALLDATASIZE
    try bytecode.append(0x36); // CALLDATASIZE
    try bytecode.append(0x50); // POP

    // CODESIZE
    try bytecode.append(0x38); // CODESIZE
    try bytecode.append(0x50); // POP

    // GASPRICE
    try bytecode.append(0x3A); // GASPRICE
    try bytecode.append(0x50); // POP

    // BASEFEE
    try bytecode.append(0x48); // BASEFEE
    try bytecode.append(0x50); // POP

    // Increment counter
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x01); // 1
    try bytecode.append(0x01); // ADD

    // Jump back to loop start
    try bytecode.append(0x61); // PUSH2
    const jump_back_dest = loop_start;
    try bytecode.append(@intCast(jump_back_dest >> 8));
    try bytecode.append(@intCast(jump_back_dest & 0xFF));
    try bytecode.append(0x56); // JUMP

    // Loop exit - JUMPDEST
    const loop_exit = bytecode.items.len;
    try bytecode.append(0x5B); // JUMPDEST

    // Clean up stack (pop the counter)
    try bytecode.append(0x50); // POP

    // Return success (push 1 to memory and return it)
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x01); // value 1 (success)
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x00); // memory offset 0
    try bytecode.append(0x52); // MSTORE

    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x20); // size 32
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x00); // offset 0
    try bytecode.append(0xF3); // RETURN

    // Update the jump destination for loop exit
    bytecode.items[jumpi_pos + 1] = @intCast(loop_exit >> 8);
    bytecode.items[jumpi_pos + 2] = @intCast(loop_exit & 0xFF);

    // Calculate runtime code size
    const runtime_size = bytecode.items.len - runtime_start;

    // Create final bytecode with constructor
    var final_bytecode = std.ArrayList(u8).init(allocator);
    defer final_bytecode.deinit();

    // Constructor that returns runtime code
    try final_bytecode.append(0x61); // PUSH2
    try final_bytecode.append(@intCast(runtime_size >> 8));
    try final_bytecode.append(@intCast(runtime_size & 0xFF));
    try final_bytecode.append(0x80); // DUP1
    try final_bytecode.append(0x61); // PUSH2
    try final_bytecode.append(0x00);
    try final_bytecode.append(0x0C); // Position after this constructor
    try final_bytecode.append(0x60); // PUSH1
    try final_bytecode.append(0x00); // Memory position 0
    try final_bytecode.append(0x39); // CODECOPY
    try final_bytecode.append(0x60); // PUSH1
    try final_bytecode.append(0x00); // Memory position 0
    try final_bytecode.append(0xF3); // RETURN

    // Append runtime code
    try final_bytecode.appendSlice(bytecode.items[runtime_start..]);

    // Output the bytecode as hex
    const stdout = std.io.getStdOut().writer();
    for (final_bytecode.items) |byte| {
        try stdout.print("{x:0>2}", .{byte});
    }
    try stdout.print("\n", .{});
}
