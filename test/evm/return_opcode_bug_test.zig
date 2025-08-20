const std = @import("std");
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const CallParams = @import("evm").CallParams;

test "minimal repro - RETURN opcode returns 0 bytes during contract deployment" {
    // std.testing.log_level = .warn;

    const allocator = std.testing.allocator;

    // Create a minimal contract deployment bytecode
    // This simulates what Solidity generates:
    // 1. Constructor code that copies runtime code to memory
    // 2. RETURN opcode to return the runtime code

    // Runtime code (what should be deployed): just a simple STOP
    // const runtime_code = [_]u8{0x00}; // STOP opcode (commented out - not used directly)

    // Deployment bytecode:
    // PUSH1 0x01    (runtime code length)
    // PUSH1 0x0c    (offset of runtime code in bytecode)
    // PUSH1 0x00    (destination in memory)
    // CODECOPY      (copy runtime code to memory)
    // PUSH1 0x01    (length to return)
    // PUSH1 0x00    (offset in memory)
    // RETURN        (return runtime code)
    // [runtime code follows]
    const deployment_bytecode = [_]u8{
        0x60, 0x01, // PUSH1 0x01 (size)
        0x60, 0x0c, // PUSH1 0x0c (offset in code)
        0x60, 0x00, // PUSH1 0x00 (dest in memory)
        0x39, // CODECOPY
        0x60, 0x01, // PUSH1 0x01 (size to return)
        0x60, 0x00, // PUSH1 0x00 (offset in memory)
        0xf3, // RETURN
        0x00, // Runtime code: STOP
    };

    std.log.debug("Deployment bytecode: {x}", .{std.fmt.fmtSliceHexLower(&deployment_bytecode)});

    // Initialize EVM
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null, null, null);
    defer vm.deinit();

    // Deploy the contract by setting the deployment bytecode directly
    const caller = Address.from_u256(0x1000);
    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Set the deployment bytecode for the contract address
    try vm.state.set_code(contract_address, &deployment_bytecode);

    // Execute the deployment bytecode to see what gets returned
    const call_params = CallParams{ .call = .{
        .caller = caller,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1_000_000,
    } };

    const deploy_result = try vm.call(call_params);
    // VM owns deploy_result.output; do not free here

    std.log.debug("Deploy result: success={}, gas_left={}", .{
        deploy_result.success,
        deploy_result.gas_left,
    });

    if (deploy_result.output) |output| {
        std.log.debug("Deployment output length: {}", .{output.len});

        // This should fail - we expect 1 byte of runtime code, not 0
        try std.testing.expect(output.len > 0);
        try std.testing.expectEqual(@as(usize, 1), output.len);
        try std.testing.expectEqual(@as(u8, 0x00), output[0]);
    } else {
        // If no output, that's also a problem for this test
        try std.testing.expect(false);
    }
}
