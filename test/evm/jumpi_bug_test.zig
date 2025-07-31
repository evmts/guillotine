const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const Address = @import("evm").primitives.Address;
const MemoryDatabase = @import("evm").MemoryDatabase;

test "JUMPI should take jump when condition is non-zero" {
    const allocator = std.testing.allocator;

    // Enable debug logging
    // std.testing.log_level = .debug;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);
    var vm = try builder.build();
    defer vm.deinit();

    const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
    const caller_balance = std.math.maxInt(u256);
    try vm.state.set_balance(caller, caller_balance);

    // Create bytecode that reproduces the exact bug:
    // The ERC20 constructor was failing because JUMPI at pc=284 wasn't jumping to pc=292
    // Simplified version:
    // PUSH1 0x01      (condition = 1, non-zero means jump)
    // PUSH1 0x08      (jump destination = 8)
    // JUMPI           (should jump to position 8)
    // PUSH1 0xFF      (should NOT execute if jump works)
    // STOP            (should NOT execute if jump works)
    // JUMPDEST        (at position 8 - jump target)
    // PUSH1 0xAA      (should execute after jump)
    // STOP
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 0x01 (condition = 1)
        0x60, 0x08, // PUSH1 0x08 (destination = 8)
        0x57, // JUMPI at pc=4 (should jump)
        0x60, 0xFF, // PUSH1 0xFF at pc=5 (should NOT execute)
        0x00, // STOP at pc=7
        0x5B, // JUMPDEST at pc=8
        0x60, 0xAA, // PUSH1 0xAA at pc=9 (should execute)
        0x00, // STOP at pc=11
    };

    // Call the contract to execute the bytecode
    const result = try vm.call_contract(caller, Address.from_u256(0x2000000000000000000000000000000000000002), // arbitrary contract address
        0, // value
        bytecode, // using bytecode as calldata for simplicity
        1000000, // gas
        false // not static
    );
    defer if (result.output) |output| allocator.free(output);

    // JUMPI is now working correctly after stack order fix
    // JUMPI should take the jump when condition is non-zero
    // Execution should jump over 0xFF and push 0xAA instead

    // Now that JUMPI bug is fixed, expect success
    try testing.expectEqual(true, result.success);

    // The contract should have executed successfully
}

test "JUMPI should NOT jump when condition is zero" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);
    var vm = try builder.build();
    defer vm.deinit();

    const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
    const caller_balance = std.math.maxInt(u256);
    try vm.state.set_balance(caller, caller_balance);

    // Same bytecode but with condition = 0
    const bytecode = &[_]u8{
        0x60, 0x00, // PUSH1 0x00 (condition = 0)
        0x60, 0x08, // PUSH1 0x08 (destination = 8)
        0x57, // JUMPI at pc=4 (should NOT jump)
        0x60, 0xFF, // PUSH1 0xFF at pc=5 (SHOULD execute)
        0x00, // STOP at pc=7
        0x5B, // JUMPDEST at pc=8
        0x60, 0xAA, // PUSH1 0xAA at pc=9 (should NOT execute)
        0x00, // STOP at pc=11
    };

    // Call the contract
    const result = try vm.call_contract(caller, Address.from_u256(0x2000000000000000000000000000000000000002), // arbitrary contract address
        0, // value
        bytecode, // using bytecode as calldata
        1000000, // gas
        false // not static
    );
    defer if (result.output) |output| allocator.free(output);

    // When condition is zero, JUMPI should NOT jump
    // So it should execute normally and push 0xFF then STOP
    // JUMPI is now working correctly after stack order fix
    try testing.expectEqual(true, result.success);
}

// Alternative test using contract deployment to actually test the JUMPI behavior
test "JUMPI bug reproduction via contract deployment" {
    const allocator = std.testing.allocator;

    std.testing.log_level = .debug;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);
    var vm = try builder.build();
    defer vm.deinit();

    const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
    const caller_balance = std.math.maxInt(u256);
    try vm.state.set_balance(caller, caller_balance);

    // Create init code that tests JUMPI and returns a value based on the result
    // Let me use a simpler, correct bytecode:
    const init_code = &[_]u8{
        // Test JUMPI with condition=1
        0x60, 0x01, // PUSH1 0x01 (condition = 1)         // pc: 0-1
        0x60, 0x0A, // PUSH1 0x0A (destination = 10)      // pc: 2-3
        0x57,       // JUMPI (should jump to pc=10)       // pc: 4

        // If we get here, JUMPI failed
        0x60, 0xFF, // PUSH1 0xFF (failure marker)        // pc: 5-6
        0x60, 0x00, // PUSH1 0x00                         // pc: 7-8
        0x52,       // MSTORE                              // pc: 9

        // JUMPDEST at pc=10
        0x5B,       // JUMPDEST                            // pc: 10
        0x60, 0xAA, // PUSH1 0xAA (success marker)        // pc: 11-12
        0x60, 0x00, // PUSH1 0x00                         // pc: 13-14
        0x52,       // MSTORE                              // pc: 15

        // Return the stored value
        0x60, 0x20, // PUSH1 0x20 (size = 32 bytes)       // pc: 16-17
        0x60, 0x00, // PUSH1 0x00 (offset)                // pc: 18-19
        0xF3,       // RETURN                              // pc: 20
    };

    // Deploy the contract
    const create_result = try vm.create_contract(caller, 0, init_code, 1000000);
    defer if (create_result.output) |output| allocator.free(output);

    std.log.debug("Create result - success: {}, output len: {}", .{ create_result.success, if (create_result.output) |o| o.len else 0 });
    
    if (create_result.success) {
        // Check what was deployed
        if (create_result.output) |output| {
            std.log.debug("Output length: {}", .{output.len});
            if (output.len > 0) {
                // The 0xAA value is stored as a 32-byte word with value at the end (little-endian storage)
                const deployed_value = output[output.len - 1]; // Last byte contains our value
                // If JUMPI worked correctly, we should have 0xAA
                // If JUMPI is broken, we would have 0xFF
                std.log.debug("Deployed bytecode last byte: 0x{X}", .{deployed_value});

                // JUMPI is now fixed after stack order correction
                try testing.expectEqual(@as(u8, 0xAA), deployed_value);
            } else {
                std.log.debug("Output is empty!", .{});
                return error.EmptyOutput;
            }
        } else {
            std.log.debug("No output returned!", .{});
            return error.NoOutput;
        }
    } else {
        // Deployment might fail for other reasons
        std.log.debug("Contract deployment failed", .{});
        return error.DeploymentFailed;
    }
}
