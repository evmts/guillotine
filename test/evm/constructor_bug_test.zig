const std = @import("std");
const testing = std.testing;

// test {
//     std.testing.log_level = .debug;
// }
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

test "constructor should return runtime code" {
    const allocator = testing.allocator;

    // Test if logging is working
    std.log.info("[TEST] Starting constructor test", .{});
    std.log.debug("[TEST] Debug logging test", .{});

    // Set up EVM
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = comptime Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var vm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer vm.deinit();

    // Set up deployer account
    const deployer = primitives.Address.from_u256(0x1111);
    try vm.state.set_balance(deployer, 1000000000000000000); // 1 ETH

    // Minimal constructor bytecode that returns runtime code
    // This is the simplest possible Solidity-style constructor:
    // 1. PUSH the runtime code to memory
    // 2. RETURN it
    // Let me trace through this bytecode:
    // Stack starts empty []
    const init_code = &[_]u8{
        // Constructor code (returns runtime code)
        0x60, 0x0a, // PUSH1 10 (size of runtime code) - Stack: [10]
        0x60, 0x0c, // PUSH1 12 (offset of runtime code in this bytecode) - Stack: [10, 12]
        0x60, 0x00, // PUSH1 0 (destination in memory) - Stack: [10, 12, 0]
        0x39, // CODECOPY (copy code to memory) - pops 3, Stack: []
        0x60, 0x0a, // PUSH1 10 (size to return) - Stack: [10]
        0x60, 0x00, // PUSH1 0 (offset in memory) - Stack: [10, 0]
        0xf3, // RETURN - pops 2, returns memory[0..10]

        // Runtime code (10 bytes) - just returns 42
        0x60, 0x2a, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    // Deploy contract using CREATE
    const create_result = try vm.create_contract(deployer, 0, // value
        init_code, 1000000 // gas
    );
    defer if (create_result.output) |output| allocator.free(output);

    // Check deployment
    try testing.expect(create_result.success);

    // Get deployed code
    const deployed_code = vm.state.get_code(create_result.address);

    // This should pass but currently fails
    try testing.expectEqual(@as(usize, 10), deployed_code.len);

    // Verify the deployed code matches expected runtime code
    const expected_runtime = init_code[12..22];
    try testing.expectEqualSlices(u8, expected_runtime, deployed_code);
}

test "manual constructor execution to debug" {
    const allocator = testing.allocator;

    // Set up EVM
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = comptime Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var vm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer vm.deinit();

    // Set up deployer account
    const deployer = primitives.Address.from_u256(0x1111);
    try vm.state.set_balance(deployer, 1000000000000000000);

    // Same init code as above
    const init_code = &[_]u8{
        0x60, 0x0a, // PUSH1 10 (size of runtime code)
        0x60, 0x0c, // PUSH1 12 (offset of runtime code)
        0x60, 0x00, // PUSH1 0 (destination in memory)
        0x39, // CODECOPY (copy code to memory)
        0x60, 0x0a, // PUSH1 10 (size to return)
        0x60, 0x00, // PUSH1 0 (offset in memory)
        0xf3, // RETURN
        // Runtime code (starts at byte 12)
        0x60,
        0x2a,
        0x60,
        0x00,
        0x52,
        0x60,
        0x20,
        0x60,
        0x00,
        0xf3,
    };

    // Create a contract for deployment
    var contract = Evm.Contract.init_deployment(deployer, 0, // value
        1000000, // gas
        init_code, null // CREATE, not CREATE2
    );
    defer contract.deinit(allocator, null);

    // Execute the constructor
    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);

    // Verify constructor executed successfully
    try testing.expectEqual(Evm.RunResult.Status.Success, result.status);
    try testing.expect(result.output != null);
    try testing.expectEqual(@as(usize, 10), result.output.?.len);
}
