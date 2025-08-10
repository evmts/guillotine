const std = @import("std");
const testing = std.testing;
const evm = @import("evm");

test "trace SUB operation step by step" {
    const allocator = testing.allocator;

    // Exact sequence from ERC20 that fails:
    // PUSH1 0x01, PUSH1 0x01, PUSH1 0x40, SHL, SUB
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x40, // PUSH1 0x40
        0x1b, // SHL
        0x03, // SUB
        0x00, // STOP
    };

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.Evm(config);
    var vm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer vm.deinit();

    const caller = evm.primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Execute directly
    const result = try vm.create_contract(caller, 0, bytecode, 1_000_000);
    defer if (result.output) |output| allocator.free(output);

    // Let's also manually trace through the operations
    std.debug.print("\nManual SUB calculation:\n", .{});
    const val1: u256 = 1;
    const val2: u256 = 1;
    const shift_amount: u256 = 0x40; // 64

    const shifted = val2 << @intCast(shift_amount);
    std.debug.print("  1 << 64 = 0x{x}\n", .{shifted});

    const sub_result = val1 -% shifted;
    std.debug.print("  1 - (1 << 64) = 0x{x}\n", .{sub_result});
    std.debug.print("  Expected:       0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\n", .{});

    // Also check with explicit values
    const a: u256 = 1;
    const b: u256 = 0x10000000000000000;
    const result2 = a -% b;
    std.debug.print("\n  Direct: 1 - 0x10000000000000000 = 0x{x}\n", .{result2});
}
