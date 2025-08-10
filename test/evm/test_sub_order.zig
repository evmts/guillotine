const std = @import("std");
const Evm = @import("evm");
const Address = @import("primitives").Address;
const revm = @import("revm");

test "SUB opcode stack order verification" {
    const allocator = std.testing.allocator;

    // Test bytecode: PUSH 10, PUSH 5, SUB
    const bytecode = &[_]u8{
        0x60, 0x0a, // PUSH1 10
        0x60, 0x05, // PUSH1 5
        0x03, // SUB
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    // Test with REVM
    var vm = try revm.Revm.init(allocator, .{});
    defer vm.deinit();

    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract = Address.from_u256(0x3300000000000000000000000000000000000000);

    try vm.setBalance(caller, std.math.maxInt(u256));
    try vm.setCode(contract, bytecode);

    var result = try vm.execute(caller, contract, 0, &[_]u8{}, 1_000_000);
    defer result.deinit();

    std.debug.print("\nSUB Order Test:\n", .{});
    std.debug.print("Bytecode: PUSH 10, PUSH 5, SUB\n", .{});
    std.debug.print("Stack before SUB: [10, 5] (5 on top)\n", .{});

    if (result.output.len == 32) {
        const value = std.mem.readInt(u256, result.output[0..32], .big);
        std.debug.print("REVM result: {}\n", .{value});

        if (value == 5) {
            std.debug.print("REVM does: 10 - 5 = 5 (second - top)\n", .{});
        } else if (value == std.math.maxInt(u256) - 4) {
            std.debug.print("REVM does: 5 - 10 = -5 (top - second) with underflow\n", .{});
        }
    }

    // Also test the reverse order
    const bytecode2 = &[_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0a, // PUSH1 10
        0x03, // SUB
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    try vm.setCode(contract, bytecode2);
    var result2 = try vm.execute(caller, contract, 0, &[_]u8{}, 1_000_000);
    defer result2.deinit();

    std.debug.print("\nReverse test - PUSH 5, PUSH 10, SUB:\n", .{});
    std.debug.print("Stack before SUB: [5, 10] (10 on top)\n", .{});

    if (result2.output.len == 32) {
        const value = std.mem.readInt(u256, result2.output[0..32], .big);
        std.debug.print("REVM result: {}\n", .{value});

        if (value == 5) {
            std.debug.print("REVM does: 10 - 5 = 5 (top - second)\n", .{});
        } else if (value == std.math.maxInt(u256) - 4) {
            std.debug.print("REVM does: 5 - 10 = -5 (second - top) with underflow\n", .{});
        }
    }
}
