const std = @import("std");
const testing = std.testing;

test "SUB operand order verification" {
    // In EVM, for SUB:
    // - Stack before: [bottom, ..., a, b] where b is on top
    // - SUB pops b, peeks a
    // - Result should be a - b
    // - Stack after: [bottom, ..., result]

    // Test case from ERC20:
    // Stack: [..., 0x1, 0x10000000000000000]
    // So: a = 0x1, b = 0x10000000000000000
    // Expected: a - b = 0x1 - 0x10000000000000000

    const a: u256 = 0x1;
    const b: u256 = 0x10000000000000000;

    // What we're calculating
    const our_result = a -% b;
    std.debug.print("\nOur calculation: 0x{x} - 0x{x} = 0x{x}\n", .{ a, b, our_result });

    // What REVM gets
    const revm_result: u256 = 0xffffffffffffffff;
    std.debug.print("REVM result: 0x{x}\n", .{revm_result});

    // What would produce REVM's result?
    const reverse_result = b -% a;
    std.debug.print("Reverse: 0x{x} - 0x{x} = 0x{x}\n", .{ b, a, reverse_result });

    std.debug.print("\nConclusion: ", .{});
    if (reverse_result == revm_result) {
        std.debug.print("REVM is calculating b - a (0x{x} - 0x{x})\n", .{ b, a });
        std.debug.print("This means we have the operands backwards!\n", .{});
    }
}
