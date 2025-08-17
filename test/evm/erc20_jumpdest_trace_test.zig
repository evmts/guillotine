const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const Log = @import("evm").Log;

test {
    std.testing.log_level = .warn;
}

test "trace ERC20 deployment jumpdest issue" {
    const allocator = std.testing.allocator;

    // Set up VM with tracing
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Caller with funds
    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // The actual ERC20 bytecode prefix that's failing
    // 0x608060405234801561000f575f5ffd5b50...
    const bytecode = [_]u8{
        0x60, 0x80, // PUSH1 0x80
        0x60, 0x40, // PUSH1 0x40
        0x52, // MSTORE (position 4)
        0x34, // CALLVALUE (position 5)
        0x80, // DUP1 (position 6)
        0x15, // ISZERO (position 7)
        0x61, 0x00, 0x0f, // PUSH2 0x000f (position 8-10, pushes 15)
        0x57, // JUMPI (position 11)
        0x5f, // PUSH0 (position 12)
        0x5f, // PUSH0 (position 13)
        0xfd, // REVERT (position 14)
        0x5b, // JUMPDEST (position 15)
        0x50, // POP (position 16)
        0x00, // STOP (position 17)
    };

    std.log.debug("Bytecode layout:", .{});
    for (bytecode, 0..) |opcode, pc| {
        std.log.debug("  PC {}: 0x{x:0>2} ({})", .{ pc, opcode, getOpcodeName(opcode) });
    }

    // Deploy with logging
    std.log.debug("Deploying contract...", .{});
    const create_result = vm.create_contract(caller, 0, &bytecode, 10_000_000) catch |err| {
        std.log.debug("create_contract failed: {}", .{err});
        return err;
    };

    std.log.debug("Create result: success={}, address={}", .{ create_result.success, create_result.address });

    try std.testing.expect(create_result.success);
}

fn getOpcodeName(opcode: u8) []const u8 {
    return switch (opcode) {
        0x00 => "STOP",
        0x15 => "ISZERO",
        0x34 => "CALLVALUE",
        0x50 => "POP",
        0x52 => "MSTORE",
        0x57 => "JUMPI",
        0x5b => "JUMPDEST",
        0x5f => "PUSH0",
        0x60 => "PUSH1",
        0x61 => "PUSH2",
        0x80 => "DUP1",
        0xfd => "REVERT",
        else => "UNKNOWN",
    };
}

test "trace incorrect jump destination calculation" {
    const allocator = std.testing.allocator;

    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Caller with funds
    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Even simpler test case
    const bytecode = [_]u8{
        0x34, // CALLVALUE (position 0) - pushes msg.value to stack
        0x60, 0x05, // PUSH1 0x05 (position 1-2) - pushes jump dest 5
        0x57, // JUMPI (position 3) - jumps to 5 if callvalue != 0
        0x00, // STOP (position 4)
        0x5b, // JUMPDEST (position 5)
        0x00, // STOP (position 6)
    };

    std.log.debug("Testing JUMPI with callvalue=0 (should not jump)", .{});

    const create_result = try vm.create_contract(caller, 0, &bytecode, 10_000_000);

    std.log.debug("Create result: success={}, address={}", .{ create_result.success, create_result.address });

    try std.testing.expect(create_result.success);
}
