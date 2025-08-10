const std = @import("std");
const testing = std.testing;
const revm = @import("revm.zig");
const Address = @import("primitives").Address;

test "REVM wrapper - basic initialization" {
    const allocator = testing.allocator;

    // Test creating REVM instance
    var vm = try revm.Revm.init(allocator, .{});
    defer vm.deinit();

    // Test should pass if we can create and destroy the VM
    try testing.expect(true);
}

test "REVM wrapper - set balance" {
    const allocator = testing.allocator;

    var vm = try revm.Revm.init(allocator, .{});
    defer vm.deinit();

    const address = Address.from_u256(0x1234567890123456789012345678901234567890);
    const balance: u256 = 1_000_000_000_000_000_000; // 1 ETH

    // Set balance
    try vm.setBalance(address, balance);

    // Get balance
    const retrieved_balance = try vm.getBalance(address);
    try testing.expectEqual(balance, retrieved_balance);
}

test "REVM wrapper - deploy and execute simple bytecode" {
    const allocator = testing.allocator;

    var vm = try revm.Revm.init(allocator, .{});
    defer vm.deinit();

    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract = Address.from_u256(0x3300000000000000000000000000000000000000);

    // Set up caller with balance
    try vm.setBalance(caller, std.math.maxInt(u256));

    // Simple bytecode: PUSH1 0x42, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    // This stores 0x42 at memory position 0 and returns 32 bytes
    const bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xf3, // RETURN
    };

    // Deploy contract
    try vm.setCode(contract, bytecode);

    // Execute contract
    var result = try vm.call(caller, contract, 0, &[_]u8{}, 100_000);
    defer result.deinit();

    // Check result
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);

    // Check output value (should be 0x42 in the last byte)
    try testing.expectEqual(@as(u8, 0x42), result.output[31]);

    // First 31 bytes should be zero
    for (result.output[0..31]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "REVM wrapper - ADD opcode" {
    const allocator = testing.allocator;

    var vm = try revm.Revm.init(allocator, .{});
    defer vm.deinit();

    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract = Address.from_u256(0x3300000000000000000000000000000000000000);

    try vm.setBalance(caller, std.math.maxInt(u256));

    // Bytecode: PUSH1 0x05, PUSH1 0x0A, ADD, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    // This computes 5 + 10 = 15 and returns it
    const bytecode = &[_]u8{
        0x60, 0x05, // PUSH1 0x05
        0x60, 0x0A, // PUSH1 0x0A
        0x01, // ADD
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xf3, // RETURN
    };

    try vm.setCode(contract, bytecode);

    var result = try vm.call(caller, contract, 0, &[_]u8{}, 100_000);
    defer result.deinit();

    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    try testing.expectEqual(@as(u8, 15), result.output[31]); // 5 + 10 = 15
}

test "REVM wrapper - gas consumption" {
    const allocator = testing.allocator;

    var vm = try revm.Revm.init(allocator, .{});
    defer vm.deinit();

    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract = Address.from_u256(0x3300000000000000000000000000000000000000);

    try vm.setBalance(caller, std.math.maxInt(u256));

    // Simple bytecode with known gas cost
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 0x01 (3 gas)
        0x60, 0x02, // PUSH1 0x02 (3 gas)
        0x01, // ADD (3 gas)
        0x00, // STOP (0 gas)
    };

    try vm.setCode(contract, bytecode);

    const gas_limit: u64 = 100_000;
    var result = try vm.call(caller, contract, 0, &[_]u8{}, gas_limit);
    defer result.deinit();

    try testing.expect(result.success);

    // Check that gas was consumed (should be at least 9 gas for the operations plus intrinsic gas)
    try testing.expect(result.gas_used > 9);
    try testing.expect(result.gas_used < gas_limit);

    std.debug.print("Gas used: {}\n", .{result.gas_used});
}
