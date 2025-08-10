const std = @import("std");
const Instruction = @import("instruction.zig").Instruction;
const Frame = @import("frame.zig").Frame;
const Stack = @import("stack/stack.zig");
const instruction_limits = @import("constants/instruction_limits.zig");

test "measure actual memory sizes" {
    std.debug.print("\n=== Actual Memory Sizes ===\n", .{});
    std.debug.print("Instruction size: {} bytes\n", .{@sizeOf(Instruction)});
    std.debug.print("Frame size: {} bytes\n", .{@sizeOf(Frame)});
    std.debug.print("Stack.CAPACITY: {} elements\n", .{Stack.CAPACITY});
    std.debug.print("u256 size: {} bytes\n", .{@sizeOf(u256)});

    // Calculate array sizes
    const max_instructions = instruction_limits.MAX_INSTRUCTIONS;
    std.debug.print("\nMAX_INSTRUCTIONS: {}\n", .{max_instructions});

    const inst_array_size = (max_instructions + 1) * @sizeOf(Instruction);
    std.debug.print("Instructions array size: {} bytes ({d:.2} MB)\n", .{ inst_array_size, @as(f64, @floatFromInt(inst_array_size)) / (1024.0 * 1024.0) });

    const stack_data_size = Stack.CAPACITY * @sizeOf(u256);
    std.debug.print("Stack data size: {} bytes ({} KB)\n", .{ stack_data_size, stack_data_size / 1024 });

    const frame_array_initial = 16 * @sizeOf(Frame);
    std.debug.print("Initial frame array (16 frames): {} bytes ({d:.2} KB)\n", .{ frame_array_initial, @as(f64, @floatFromInt(frame_array_initial)) / 1024.0 });

    const pc_map_max = 24576 * @sizeOf(u16); // MAX_CONTRACT_SIZE
    std.debug.print("PC mapping max size (24KB contract): {} bytes ({} KB)\n", .{ pc_map_max, pc_map_max / 1024 });

    std.debug.print("\n", .{});
}
