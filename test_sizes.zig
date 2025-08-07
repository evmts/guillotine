const std = @import("std");
const ExecutionContext = @import("src/evm/execution_context.zig").ExecutionContext;
const Stack = @import("src/evm/stack/stack.zig");
const Memory = @import("src/evm/memory/memory.zig");

test "Component sizes" {
    std.debug.print("Component sizes:\n", .{});
    std.debug.print("  Stack: {} bytes\n", .{@sizeOf(Stack)});
    std.debug.print("  Memory: {} bytes\n", .{@sizeOf(Memory)});
    std.debug.print("  ExecutionContext total: {} bytes\n", .{@sizeOf(ExecutionContext)});
}