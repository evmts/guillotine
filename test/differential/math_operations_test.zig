const std = @import("std");
const primitives = @import("primitives");
const guillotine_evm = @import("evm");
const revm = @import("revm");
const log = std.log.scoped(.differential);

const testing = std.testing;

/// Test case structure for differential testing
const TestCase = struct {
    name: []const u8,
    bytecode: []const u8,
    expected_output: []const u8,
    gas_limit: u64 = 100000,
};

/// Execute bytecode on both EVMs and compare results
fn executeAndCompare(allocator: std.mem.Allocator, test_case: TestCase) !void {
    log.info("Running differential test: {s}", .{test_case.name});
    
    // Setup addresses
    const caller = primitives.Address.ZERO_ADDRESS;
    const contract = try primitives.Address.from_hex("0xc0de000000000000000000000000000000000000");
    
    // Execute with REVM first
    log.debug("Executing with REVM...", .{});
    var revm_vm = try revm.Revm.init(allocator, .{
        .gas_limit = test_case.gas_limit,
        .chain_id = 1,
    });
    defer revm_vm.deinit();
    
    // Set up account with balance for gas
    try revm_vm.setBalance(caller, 10000000);
    
    // Deploy contract with the bytecode
    try revm_vm.setCode(contract, test_case.bytecode);
    
    // Execute
    var revm_result = try revm_vm.call(caller, contract, 0, &.{}, test_case.gas_limit);
    defer revm_result.deinit();
    
    log.debug("REVM result: success={}, gas_used={}, output_len={}", .{ 
        revm_result.success, 
        revm_result.gas_used,
        revm_result.output.len 
    });
    
    // Execute with Guillotine EVM
    log.debug("Executing with Guillotine EVM...", .{});
    
    // Create a simple in-memory database
    var db = guillotine_evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    // Set up caller account
    try db.set_account(caller.bytes, .{
        .balance = 10000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Set contract code
    log.debug("Setting contract code, length: {}", .{test_case.bytecode.len});
    const code_hash = try db.set_code(test_case.bytecode);
    try db.set_account(contract.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Verify code was set correctly
    const stored_code = try db.get_code_by_address(contract.bytes);
    log.debug("Stored code length: {}", .{stored_code.len});
    try testing.expectEqual(test_case.bytecode.len, stored_code.len);
    try testing.expect(stored_code.len > 0);
    
    // Create EVM instance
    const block_info = guillotine_evm.BlockInfo{
        .number = 1,
        .timestamp = 0,
        .gas_limit = test_case.gas_limit,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .difficulty = 0,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const tx_context = guillotine_evm.TransactionContext{
        .chain_id = 1,
        .gas_limit = test_case.gas_limit,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .blob_versioned_hashes = &.{},
        .blob_base_fee = 0,
    };
    
    var evm = try guillotine_evm.Evm(.{}).init(
        allocator,
        db.to_database_interface(),
        block_info,
        tx_context,
        0, // gas_price
        caller, // origin
        .CANCUN,
    );
    defer evm.deinit();
    
    const call_result = evm.call(.{
        .call = .{
            .caller = caller,
            .to = contract,
            .value = 0,
            .input = &.{},
            .gas = test_case.gas_limit,
        },
    });
    
    log.debug("Guillotine result: success={}, gas_left={}, output_len={}", .{ 
        call_result.success, 
        call_result.gas_left,
        call_result.output.len 
    });
    
    // Compare results
    try testing.expect(revm_result.success == call_result.success);
    
    // Calculate gas used for guillotine (gas_limit - gas_left)
    const guillotine_gas_used = test_case.gas_limit - call_result.gas_left;
    
    // Allow some variance in gas usage (within 10%)
    const gas_diff = if (revm_result.gas_used > guillotine_gas_used) 
        revm_result.gas_used - guillotine_gas_used 
    else 
        guillotine_gas_used - revm_result.gas_used;
    
    const max_gas_diff = @max(revm_result.gas_used, guillotine_gas_used) / 10;
    
    if (gas_diff > max_gas_diff) {
        log.err("Gas usage differs significantly: REVM={}, Guillotine={}", .{
            revm_result.gas_used,
            guillotine_gas_used,
        });
        return error.GasMismatch;
    }
    
    // Compare outputs
    try testing.expectEqualSlices(u8, revm_result.output, call_result.output);
    
    // If we have expected output, verify both match it
    if (test_case.expected_output.len > 0) {
        try testing.expectEqualSlices(u8, test_case.expected_output, call_result.output);
    }
    
    log.info("Test passed: {s}", .{test_case.name});
}

test "differential: basic arithmetic operations" {
    const allocator = testing.allocator;
    
    log.info("Starting basic arithmetic operations test", .{});
    
    // Bytecode that performs various arithmetic operations and returns the result
    // Operations: 
    // 1. ADD: 5 + 3 = 8
    // 2. SUB: 10 - 4 = 6  
    // 3. MUL: 8 * 6 = 48 (0x30)
    // 4. DIV: 48 / 2 = 24 (0x18)
    // 5. MOD: 24 % 7 = 3
    // 6. ADDMOD: (3 + 5) % 5 = 3
    // 7. MULMOD: (3 * 4) % 5 = 2
    // 8. EXP: 2 ^ 3 = 8
    // 9. Final ADD: 8 + 1 = 9
    // Return 9 as 32-byte word
    
    const bytecode = [_]u8{
        // 1. ADD: 5 + 3
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x01,       // ADD (result: 8)
        
        // 2. SUB: 10 - 4
        0x60, 0x0a, // PUSH1 10
        0x60, 0x04, // PUSH1 4
        0x03,       // SUB (result: 6)
        
        // 3. MUL: 8 * 6
        0x02,       // MUL (result: 48)
        
        // 4. DIV: 48 / 2
        0x60, 0x02, // PUSH1 2
        0x04,       // DIV (result: 24)
        
        // 5. MOD: 24 % 7
        0x60, 0x07, // PUSH1 7
        0x06,       // MOD (result: 3)
        
        // 6. ADDMOD: (3 + 5) % 5
        0x60, 0x05, // PUSH1 5
        0x60, 0x05, // PUSH1 5
        0x08,       // ADDMOD (result: 3)
        
        // 7. MULMOD: (3 * 4) % 5
        0x60, 0x04, // PUSH1 4
        0x60, 0x05, // PUSH1 5
        0x09,       // MULMOD (result: 2)
        
        // 8. EXP: 2 ^ 3
        0x60, 0x03, // PUSH1 3
        0x0a,       // EXP (result: 8)
        
        // 9. Final ADD: 8 + 1
        0x60, 0x01, // PUSH1 1
        0x01,       // ADD (result: 9)
        
        // Store result in memory and return
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32 (return size)
        0x60, 0x00, // PUSH1 0 (return offset)
        0xf3,       // RETURN
    };
    
    // Expected output: 9 as 32-byte word
    var expected_output = [_]u8{0} ** 32;
    expected_output[31] = 9;
    
    const test_case = TestCase{
        .name = "Basic arithmetic operations",
        .bytecode = &bytecode,
        .expected_output = &expected_output,
    };
    
    log.info("Test bytecode length: {}", .{bytecode.len});
    
    try executeAndCompare(allocator, test_case);
}

test "differential: signed arithmetic operations" {
    const allocator = testing.allocator;
    
    // Test SDIV, SMOD, and SIGNEXTEND
    const bytecode = [_]u8{
        // SDIV: -8 / 3 = -2 (in two's complement)
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xf8, // PUSH32 -8
        0x60, 0x03, // PUSH1 3
        0x05,       // SDIV (result: -2)
        
        // Convert to positive for easier testing: -(-2) = 2
        0x60, 0x00, // PUSH1 0
        0x03,       // SUB (0 - (-2) = 2)
        
        // Store and return
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    var expected_output = [_]u8{0} ** 32;
    expected_output[31] = 2;
    
    const test_case = TestCase{
        .name = "Signed arithmetic operations",
        .bytecode = &bytecode,
        .expected_output = &expected_output,
    };
    
    try executeAndCompare(allocator, test_case);
}

test "differential: comparison operations" {
    const allocator = testing.allocator;
    
    // Test LT, GT, EQ, ISZERO
    const bytecode = [_]u8{
        // LT: 5 < 10 = 1
        0x60, 0x05, // PUSH1 5
        0x60, 0x0a, // PUSH1 10
        0x10,       // LT (result: 1)
        
        // GT: 10 > 5 = 1
        0x60, 0x0a, // PUSH1 10
        0x60, 0x05, // PUSH1 5
        0x11,       // GT (result: 1)
        
        // ADD: 1 + 1 = 2
        0x01,       // ADD
        
        // EQ: 2 == 2 = 1
        0x60, 0x02, // PUSH1 2
        0x14,       // EQ (result: 1)
        
        // ISZERO: !1 = 0, then !0 = 1
        0x15,       // ISZERO (result: 0)
        0x15,       // ISZERO (result: 1)
        
        // Store and return
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    var expected_output = [_]u8{0} ** 32;
    expected_output[31] = 1;
    
    const test_case = TestCase{
        .name = "Comparison operations",
        .bytecode = &bytecode,
        .expected_output = &expected_output,
    };
    
    try executeAndCompare(allocator, test_case);
}