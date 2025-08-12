const std = @import("std");
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const CallParams = @import("evm").CallParams;

test "RETURN opcode must stop execution during contract deployment - reproduces ten-thousand-hashes issue" {
    const allocator = std.testing.allocator;

    // This reproduces the exact issue from the ten-thousand-hashes trace
    // The deployment code copies runtime code and returns it
    // Bug: Zig continues executing the runtime code after RETURN
    const deployment_bytecode = [_]u8{
        // Deployment code (what we see in the trace steps 10-16)
        0x60, 0x08, // PUSH1 0x08 (size of runtime code)
        0x80,       // DUP1 
        0x60, 0x0c, // PUSH1 0x0c (offset of runtime code)
        0x5f,       // PUSH0 (destination in memory)
        0x39,       // CODECOPY
        0x5f,       // PUSH0 (offset in memory)
        0xf3,       // RETURN <-- Execution should STOP here
        
        // Runtime code (should NOT execute during deployment)
        0x60, 0x80, // PUSH1 0x80
        0x60, 0x40, // PUSH1 0x40  
        0x52,       // MSTORE
        0x34,       // CALLVALUE
        0x80,       // DUP1
        0x15,       // ISZERO
        0x60, 0x0e, // PUSH1 0x0e
        0x57,       // JUMPI
    };

    std.log.debug("Testing RETURN stops execution bug", .{});
    std.log.debug("Bytecode length: {}", .{deployment_bytecode.len});

    // Initialize EVM
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Set up contract for deployment
    const deployer = Address.from_u256(0x1000);
    const contract_address = Address.from_u256(0x5FbDB2315678afecb367f032d93F642f64180aa3);

    // Set deployment bytecode directly
    try vm.state.set_code(contract_address, &deployment_bytecode);

    // Execute deployment
    const call_params = CallParams{ .call = .{
        .caller = deployer,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1_000_000,
    } };

    // Enable tracing to see what happens
    // std.testing.log_level = .debug;
    
    const result = try vm.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    // Check if RETURN properly stopped execution
    try std.testing.expect(result.success);
    
    // Should have returned the runtime code
    try std.testing.expect(result.output != null);
    const output = result.output.?;
    
    std.log.debug("RETURN output length: {} bytes", .{output.len});
    
    // We expect exactly 8 bytes of runtime code
    try std.testing.expectEqual(@as(usize, 8), output.len);
    
    // Verify the returned data matches our runtime code  
    const expected_runtime = deployment_bytecode[12..20];
    try std.testing.expectEqualSlices(u8, expected_runtime, output);
    
    // CRITICAL: If execution continued after RETURN, we would see:
    // 1. More gas consumed than necessary
    // 2. Stack operations from the runtime code
    // 3. Possible errors from executing deployment code as runtime
    
    // The gas consumption should be minimal (just deployment operations)
    const gas_used = 1_000_000 - result.gas_left;
    std.log.debug("Gas used for deployment: {}", .{gas_used});
    
    // Gas should be reasonable for deployment only (not executing runtime)
    // Rough estimate: PUSH1(3) + DUP1(3) + PUSH1(3) + PUSH0(2) + CODECOPY(?) + PUSH0(2) + RETURN(?)
    try std.testing.expect(gas_used < 50_000); // Should be much less if RETURN works
}

test "Minimal RETURN stops execution test" {
    const allocator = std.testing.allocator;

    // Even simpler test: just PUSH some data and RETURN
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00  
        0x52,       // MSTORE (store 0x42 at memory[0])
        0x60, 0x20, // PUSH1 0x20 (32 bytes)
        0x60, 0x00, // PUSH1 0x00 (offset)
        0xf3,       // RETURN
        // If execution continues past RETURN, these will execute:
        0x60, 0xFF, // PUSH1 0xFF
        0x60, 0xFF, // PUSH1 0xFF
        0x00,       // STOP
    };

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const caller = Address.from_u256(0x1000);
    const contract = Address.from_u256(0x2000);

    // Set code
    try vm.state.set_code(contract, &bytecode);

    const call_params = CallParams{ .call = .{
        .caller = caller,
        .to = contract,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100_000,
    } };

    const result = try vm.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    // Verify RETURN worked
    try std.testing.expect(result.success);
    try std.testing.expect(result.output != null);
    
    // Should return 32 bytes with 0x42 in the last byte
    const output = result.output.?;
    try std.testing.expectEqual(@as(usize, 32), output.len);
    try std.testing.expectEqual(@as(u8, 0x42), output[31]);
    
    // Gas should not include the PUSH 0xFF operations after RETURN
    const gas_used = 100_000 - result.gas_left;
    std.log.debug("Gas used: {}", .{gas_used});
    
    // If RETURN didn't stop, we'd use more gas for the extra PUSHes
    // Account for base transaction cost of 21000
    const base_tx_cost = 21000;
    const execution_gas = if (gas_used > base_tx_cost) gas_used - base_tx_cost else gas_used;
    try std.testing.expect(execution_gas < 1000);
}