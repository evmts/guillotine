const std = @import("std");
const Instruction = @import("src/evm/instruction.zig").Instruction;
const Frame = @import("src/evm/frame.zig").Frame;
const Stack = @import("src/evm/stack/stack.zig");
const Memory = @import("src/evm/memory/memory.zig");
const instruction_limits = @import("src/evm/constants/instruction_limits.zig");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    // Measure struct sizes
    try stdout.print("=== Actual Memory Sizes ===\n", .{});
    try stdout.print("Instruction size: {} bytes\n", .{@sizeOf(Instruction)});
    try stdout.print("Frame size: {} bytes\n", .{@sizeOf(Frame)});
    try stdout.print("Stack.CAPACITY: {} elements\n", .{Stack.CAPACITY});
    try stdout.print("u256 size: {} bytes\n", .{@sizeOf(u256)});

    // Calculate array sizes
    const max_instructions = instruction_limits.MAX_INSTRUCTIONS;
    try stdout.print("\nMAX_INSTRUCTIONS: {}\n", .{max_instructions});

    const inst_array_size = (max_instructions + 1) * @sizeOf(Instruction);
    try stdout.print("Instructions array size: {} bytes ({} MB)\n", .{ inst_array_size, inst_array_size / (1024 * 1024) });

    const stack_data_size = Stack.CAPACITY * @sizeOf(u256);
    try stdout.print("Stack data size: {} bytes ({} KB)\n", .{ stack_data_size, stack_data_size / 1024 });

    const frame_array_initial = 16 * @sizeOf(Frame);
    try stdout.print("Initial frame array (16 frames): {} bytes ({} KB)\n", .{ frame_array_initial, frame_array_initial / 1024 });

    const pc_map_max = 24576 * @sizeOf(u16); // MAX_CONTRACT_SIZE
    try stdout.print("PC mapping max size (24KB contract): {} bytes ({} KB)\n", .{ pc_map_max, pc_map_max / 1024 });
}
