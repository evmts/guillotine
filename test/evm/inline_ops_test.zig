const std = @import("std");
const Evm = @import("evm");
const primitives = @import("primitives");
const testing = std.testing;

test "measure function call overhead for hot opcodes" {
    // This test establishes a baseline for the overhead of going through
    // the jump table vs direct execution
    const allocator = testing.allocator;

    // Create a simple contract with hot opcodes
    // PUSH1 0x05, PUSH1 0x0A, ADD, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0a, // PUSH1 10
        0x01, // ADD
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = comptime Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var vm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer vm.deinit();

    // Set up test account with balance
    const caller = primitives.Address.ZERO;
    const contract_addr = primitives.Address.from_u256(0x100);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Deploy contract
    try vm.state.set_code(contract_addr, &bytecode);

    // Measure execution time
    const iterations = 100_000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        var contract = Evm.Contract.init_at_address(caller, contract_addr, 0, 100000, &bytecode, &.{}, false);
        const result = try vm.interpret(&contract, &.{}, false);
        defer if (result.output) |output| allocator.free(output);

        try testing.expectEqual(Evm.RunResult.Status.Success, result.status);
        try testing.expectEqual(@as(usize, 32), result.output.?.len);

        // Check result is 15 (5 + 10)
        const value = std.mem.readInt(u256, result.output.?[0..32], .big);
        try testing.expectEqual(@as(u256, 15), value);
    }

    const elapsed_ns = timer.read();
    const ns_per_execution = elapsed_ns / iterations;
    const executions_per_sec = (iterations * 1_000_000_000) / elapsed_ns;

    std.log.info("Current implementation performance:", .{});
    std.log.info("  Nanoseconds per execution: {}", .{ns_per_execution});
    std.log.info("  Executions per second: {}", .{executions_per_sec});
    std.log.info("  Total time: {}ms", .{elapsed_ns / 1_000_000});
}

test "hot opcode pattern - tight loop" {
    // Test a tight loop pattern common in EVM contracts
    // This simulates the overhead of repeated simple operations
    const allocator = testing.allocator;

    // DUP1, DUP1, ADD, DUP1, DUP1, ADD... pattern
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();

    // PUSH1 1 to start
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x01 });

    // Repeat DUP1, DUP1, ADD pattern
    for (0..50) |_| {
        try bytecode.appendSlice(&[_]u8{
            0x80, // DUP1
            0x80, // DUP1
            0x01, // ADD
        });
    }

    // End with PUSH1 0, MSTORE, STOP
    try bytecode.appendSlice(&[_]u8{
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x00, // STOP
    });

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = comptime Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var vm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer vm.deinit();

    const caller = primitives.Address.ZERO;
    const contract_addr = primitives.Address.from_u256(0x200);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    try vm.state.set_code(contract_addr, bytecode.items);

    const iterations = 10_000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        var contract = Evm.Contract.init_at_address(caller, contract_addr, 0, 1000000, bytecode.items, &.{}, false);
        const result = try vm.interpret(&contract, &.{}, false);
        defer if (result.output) |output| allocator.free(output);

        try testing.expectEqual(Evm.RunResult.Status.Success, result.status);
    }

    const elapsed_ns = timer.read();
    const total_opcodes = iterations * (2 + 50 * 3 + 3); // PUSH1 + loops + end
    const ns_per_opcode = elapsed_ns / total_opcodes;
    const opcodes_per_sec = (total_opcodes * 1_000_000_000) / elapsed_ns;

    std.log.info("Tight loop performance:", .{});
    std.log.info("  Nanoseconds per opcode: {}", .{ns_per_opcode});
    std.log.info("  Opcodes per second: {}M", .{opcodes_per_sec / 1_000_000});
    std.log.info("  Total opcodes: {}", .{total_opcodes});
}
