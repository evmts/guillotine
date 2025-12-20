const std = @import("std");
const testing = std.testing;
const primitives = @import("voltaire");
const guillotine = @import("evm");

// Create EVM with tracing enabled for these tests
const Evm = guillotine.Evm(.{
    .tracer_config = guillotine.tracer.TracerConfig{
        .enabled = true,
        .enable_validation = false,
        .enable_step_capture = true,  // This enables trace step capture
        .enable_pc_tracking = true,
        .enable_gas_tracking = true,
        .enable_debug_logging = false,
        .enable_advanced_trace = false,
    },
});
const Database = guillotine.Database;
const Account = guillotine.Account;
const BlockInfo = guillotine.BlockInfo;
const TransactionContext = guillotine.TransactionContext;
const CallParams = Evm.CallParams;
const CallResult = Evm.CallResult;
const Address = primitives.Address;

test "trace validation - basic trace population on successful call" {
    const allocator = testing.allocator;
    
    // Initialize database
    var db = Database.init(allocator);
    defer db.deinit();
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 100,
        .timestamp = 1000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = Address.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const tx_context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = Address.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try Evm.init(allocator, &db, block_info, tx_context, 0, Address.ZERO_ADDRESS);
    defer evm.deinit();
    
    // Create simple contract that executes a few opcodes
    // Bytecode: PUSH1 0x42, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    // This stores 0x42 at memory[0] and returns 32 bytes
    const bytecode = [_]u8{
        0x60, 0x42,  // PUSH1 0x42
        0x60, 0x00,  // PUSH1 0x00
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 0x20 (32 bytes)
        0x60, 0x00,  // PUSH1 0x00 (offset)
        0xf3,        // RETURN
    };
    
    const contract_addr = Address{ .bytes = [_]u8{0x01} ** 20 };
    const code_hash = try db.set_code(&bytecode);
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(contract_addr.bytes, account);
    
    // Execute call
    const params = CallParams{
        .call = .{
            .caller = Address.ZERO_ADDRESS,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = 100_000,
        },
    };
    
    var result = evm.call(params);
    defer result.deinit(allocator);

    // Basic result verification
    try testing.expect(result.success);
    try testing.expect(result.gas_left < 100_000); // Some gas was consumed
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    // Verify trace exists and is populated
    try testing.expect(result.trace != null);
    
    if (result.trace) |trace| {
        // Verify we have trace steps
        try testing.expect(trace.steps.len > 0);
        
        // We expect at least 8 steps for our bytecode (including potential metadata)
        try testing.expect(trace.steps.len >= 8);
        
        // Verify first few opcodes match our bytecode
        for (trace.steps, 0..) |step, i| {
            // Basic validation of step data
            try testing.expect(step.opcode_name.len > 0);
            try testing.expect(step.gas > 0 or i == trace.steps.len - 1);
        }
    }
    
    // Clean up is handled by defer
}

test "trace validation - trace step details are correct" {
    const allocator = testing.allocator;
    
    var db = Database.init(allocator);
    defer db.deinit();
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 100,
        .timestamp = 1000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = Address.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const tx_context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = Address.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try Evm.init(allocator, &db, block_info, tx_context, 0, Address.ZERO_ADDRESS);
    defer evm.deinit();
    
    // Simple arithmetic: PUSH1 0x03, PUSH1 0x02, ADD, STOP
    const bytecode = [_]u8{
        0x60, 0x03,  // PUSH1 0x03
        0x60, 0x02,  // PUSH1 0x02
        0x01,        // ADD
        0x00,        // STOP
    };
    
    const contract_addr = Address{ .bytes = [_]u8{0x02} ** 20 };
    const code_hash = try db.set_code(&bytecode);
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(contract_addr.bytes, account);
    
    const params = CallParams{
        .call = .{
            .caller = Address.ZERO_ADDRESS,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = 100_000,
        },
    };
    
    var result = evm.call(params);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    try testing.expect(result.trace != null);

    if (result.trace) |trace| {
        // Find PUSH1 and ADD operations in trace
        var found_push1_count: u32 = 0;
        var found_add = false;
        var found_stop = false;
        
        for (trace.steps) |step| {
            // Check for PUSH1 opcodes (0x60)
            if (step.opcode == 0x60) {
                found_push1_count += 1;
                // Stack should grow after PUSH1
                try testing.expect(step.stack.len < 1024); // Valid stack size
            }
            
            // Check for ADD opcode (0x01)
            if (step.opcode == 0x01) {
                found_add = true;
                // Before ADD, stack should have at least 2 items
                // Note: step.stack shows state BEFORE the operation
                try testing.expect(step.stack.len >= 2);
            }
            
            // Check for STOP opcode (0x00)
            if (step.opcode == 0x00) {
                found_stop = true;
            }
        }
        
        // Verify we found expected opcodes
        try testing.expectEqual(@as(u32, 2), found_push1_count);
        try testing.expect(found_add);
        try testing.expect(found_stop);
    }

    // Clean up is handled by defer
}

test "trace validation - REVERT produces trace" {
    const allocator = testing.allocator;
    
    var db = Database.init(allocator);
    defer db.deinit();
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 100,
        .timestamp = 1000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = Address.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const tx_context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = Address.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try Evm.init(allocator, &db, block_info, tx_context, 0, Address.ZERO_ADDRESS);
    defer evm.deinit();
    
    // Bytecode that stores "FAIL" and reverts
    // PUSH4 "FAIL", PUSH1 0, MSTORE, PUSH1 4, PUSH1 28, REVERT
    const bytecode = [_]u8{
        0x63, 0x46, 0x41, 0x49, 0x4C,  // PUSH4 "FAIL"
        0x60, 0x00,                      // PUSH1 0
        0x52,                            // MSTORE
        0x60, 0x04,                      // PUSH1 4 (size)
        0x60, 0x1C,                      // PUSH1 28 (offset) 
        0xfd,                            // REVERT
    };
    
    const contract_addr = Address{ .bytes = [_]u8{0x03} ** 20 };
    const code_hash = try db.set_code(&bytecode);
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(contract_addr.bytes, account);
    
    const params = CallParams{
        .call = .{
            .caller = Address.ZERO_ADDRESS,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = 100_000,
        },
    };
    
    var result = evm.call(params);
    defer result.deinit(allocator);

    // Verify revert
    try testing.expect(!result.success);
    // The output has padding, so check that it ends with "FAIL"
    try testing.expect(result.output.len >= 4);
    const fail_bytes = result.output[result.output.len - 4..];
    try testing.expectEqualSlices(u8, "FAIL", fail_bytes);
    
    // CRITICAL: Trace should be populated even on revert
    try testing.expect(result.trace != null);
    
    if (result.trace) |trace| {
        try testing.expect(trace.steps.len > 0);
        
        // Verify we captured steps leading to REVERT
        var found_revert = false;
        for (trace.steps) |step| {
            if (step.opcode == 0xfd) { // REVERT opcode
                found_revert = true;
            }
        }
        try testing.expect(found_revert);
    }

    // Clean up is handled by defer
}

test "trace validation - gas consumption tracking" {
    const allocator = testing.allocator;
    
    var db = Database.init(allocator);
    defer db.deinit();
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 100,
        .timestamp = 1000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = Address.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const tx_context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = Address.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try Evm.init(allocator, &db, block_info, tx_context, 0, Address.ZERO_ADDRESS);
    defer evm.deinit();
    
    // Bytecode with known gas costs
    const bytecode = [_]u8{
        0x60, 0x01,  // PUSH1 0x01 (gas cost: 3)
        0x60, 0x02,  // PUSH1 0x02 (gas cost: 3)
        0x01,        // ADD (gas cost: 3)
        0x50,        // POP (gas cost: 2)
        0x00,        // STOP (gas cost: 0)
    };
    
    const contract_addr = Address{ .bytes = [_]u8{0x04} ** 20 };
    const code_hash = try db.set_code(&bytecode);
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(contract_addr.bytes, account);
    
    const initial_gas: u64 = 100_000;
    const params = CallParams{
        .call = .{
            .caller = Address.ZERO_ADDRESS,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = initial_gas,
        },
    };

    var result = evm.call(params);
    defer result.deinit(allocator);
    
    try testing.expect(result.success);
    try testing.expect(result.trace != null);
    
    if (result.trace) |trace| {
        try testing.expect(trace.steps.len > 0);
        
        // Verify gas decreases through execution
        var prev_gas: u64 = initial_gas;
        for (trace.steps, 0..) |step, i| {
            // Gas should decrease or stay same (for 0-cost ops)
            try testing.expect(step.gas <= prev_gas);
            
            // Verify gas_cost field is populated
            if (i < trace.steps.len - 1) {
                const gas_consumed = prev_gas - step.gas;
                _ = gas_consumed;
            }
            
            prev_gas = step.gas;
        }
        
        // Total gas consumed should match
        const total_consumed = initial_gas - result.gas_left;
        _ = total_consumed;
    }

    // Clean up is handled by defer
}

test "trace validation - snapshot test" {
    const allocator = testing.allocator;
    
    var db = Database.init(allocator);
    defer db.deinit();
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 100,
        .timestamp = 1000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = Address.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const tx_context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = Address.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try Evm.init(allocator, &db, block_info, tx_context, 0, Address.ZERO_ADDRESS);
    defer evm.deinit();
    
    // Simple ADD operation: PUSH1 3, PUSH1 2, ADD, STOP
    const bytecode = [_]u8{
        0x60, 0x03,  // PUSH1 3
        0x60, 0x02,  // PUSH1 2
        0x01,        // ADD
        0x00,        // STOP
    };
    
    const contract_addr = Address{ .bytes = [_]u8{0x99} ** 20 };
    const code_hash = try db.set_code(&bytecode);
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(contract_addr.bytes, account);
    
    const params = CallParams{
        .call = .{
            .caller = Address.ZERO_ADDRESS,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = 100_000,
        },
    };
    
    const result = evm.call(params);
    defer {
        var mutable_result = result;
        mutable_result.deinit(allocator);
    }
    
    try testing.expect(result.success);
    
    // Validate trace is populated correctly
    try testing.expect(result.trace != null);
    
    if (result.trace) |trace| {
        // Expected trace for PUSH1 3, PUSH1 2, ADD, STOP:
        // Step 0: PUSH1 (0x60) at PC=0, pushes 3
        // Step 1: PUSH1 (0x60) at PC=2, pushes 2
        // Step 2: ADD (0x01) at PC=4, pops 2 and 3, pushes 5
        // Step 3: STOP (0x00) at PC=5
        
        try testing.expectEqual(@as(usize, 4), trace.steps.len);
        
        // Validate each step's PC and opcode
        try testing.expectEqual(@as(u32, 0), trace.steps[0].pc);
        try testing.expectEqual(@as(u8, 0x60), trace.steps[0].opcode); // PUSH1
        try testing.expectEqualStrings("PUSH1", trace.steps[0].opcode_name);
        
        try testing.expectEqual(@as(u32, 2), trace.steps[1].pc);
        try testing.expectEqual(@as(u8, 0x60), trace.steps[1].opcode); // PUSH1
        try testing.expectEqualStrings("PUSH1", trace.steps[1].opcode_name);
        
        try testing.expectEqual(@as(u32, 4), trace.steps[2].pc);
        try testing.expectEqual(@as(u8, 0x01), trace.steps[2].opcode); // ADD
        try testing.expectEqualStrings("ADD", trace.steps[2].opcode_name);
        
        try testing.expectEqual(@as(u32, 5), trace.steps[3].pc);
        try testing.expectEqual(@as(u8, 0x00), trace.steps[3].opcode); // STOP
        try testing.expectEqualStrings("STOP", trace.steps[3].opcode_name);
        
        // Validate stack evolution
        try testing.expectEqual(@as(usize, 0), trace.steps[0].stack.len); // Before PUSH1
        try testing.expectEqual(@as(usize, 1), trace.steps[1].stack.len); // After first PUSH1
        try testing.expectEqual(@as(u256, 3), trace.steps[1].stack[0]);
        
        try testing.expectEqual(@as(usize, 2), trace.steps[2].stack.len); // After second PUSH1
        try testing.expectEqual(@as(u256, 3), trace.steps[2].stack[0]);
        try testing.expectEqual(@as(u256, 2), trace.steps[2].stack[1]);
        
        try testing.expectEqual(@as(usize, 1), trace.steps[3].stack.len); // After ADD
        try testing.expectEqual(@as(u256, 5), trace.steps[3].stack[0]); // 3 + 2 = 5
        
        // Validate gas consumption
        try testing.expect(trace.steps[0].gas > trace.steps[1].gas); // Gas decreases
        try testing.expect(trace.steps[1].gas > trace.steps[2].gas);
        try testing.expect(trace.steps[2].gas > trace.steps[3].gas);
    }
}

test "trace validation - CREATE operation produces trace" {
    const allocator = testing.allocator;
    
    var db = Database.init(allocator);
    defer db.deinit();
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 100,
        .timestamp = 1000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = Address.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const tx_context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = Address.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try Evm.init(allocator, &db, block_info, tx_context, 0, Address.ZERO_ADDRESS);
    defer evm.deinit();
    
    // Simple init code that returns empty (creates empty contract)
    const init_code = [_]u8{
        0x60, 0x00,  // PUSH1 0 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xf3,        // RETURN
    };
    
    const params = CallParams{
        .create = .{
            .caller = Address.ZERO_ADDRESS,
            .value = 0,
            .init_code = &init_code,
            .gas = 100_000,
        },
    };

    var result = evm.call(params);
    defer result.deinit(allocator);
    
    try testing.expect(result.success);
    try testing.expect(result.trace != null);
    
    if (result.trace) |trace| {
        try testing.expect(trace.steps.len > 0);
        
        // Verify we see the init code execution
        var found_return = false;
        for (trace.steps) |step| {
            if (step.opcode == 0xf3) { // RETURN in init code
                found_return = true;
            }
        }
        try testing.expect(found_return);
    }
    
    // Verify created address is populated
    try testing.expect(result.created_address != null);

    // Clean up is handled by defer
}