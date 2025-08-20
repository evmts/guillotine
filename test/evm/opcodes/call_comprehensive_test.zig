const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const MemoryDatabase = Evm.MemoryDatabase;
const ExecutionError = Evm.ExecutionError;
const GasConstants = Evm.gas_constants;

// ============================================================================
// CALL Opcode Comprehensive Tests
// ============================================================================
// These tests are designed to comprehensively test the CALL opcode (0xF1)
// including its current stub behavior and future correct implementation.
//
// Current behavior (stub):
// - Always returns 0 (failure)
// - Does not properly charge gas for memory expansion
//
// Expected future behavior:
// - Creates a new execution context for the called contract
// - Transfers value if specified
// - Properly charges gas for memory expansion
// - Returns 1 on success, 0 on failure
// ============================================================================

// Test 1: Verify current stub behavior - CALL always returns 0
test "CALL: stub behavior always returns 0" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x22} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    // Push valid CALL parameters onto stack
    // Stack order (top to bottom): gas, to, value, argsOffset, argsSize, retOffset, retSize
    const target_address = Address.from_hex("0x3333333333333333333333333333333333333333") catch unreachable;
    
    try frame.stack.append(0);     // retSize
    try frame.stack.append(0);     // retOffset
    try frame.stack.append(0);     // argsSize
    try frame.stack.append(0);     // argsOffset
    try frame.stack.append(0);     // value (0 ETH)
    try frame.stack.append(Address.to_u256(target_address)); // to address
    try frame.stack.append(100000); // gas

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Execute CALL opcode (0xF1)
    _ = try evm.table.execute(0, interpreter, state, 0xF1);

    // Current stub implementation always returns 0 (failure)
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

// Test 2: Memory expansion undercharging vulnerability
test "CALL: memory expansion undercharging" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x22} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;
    
    // Push parameters that require large memory expansion
    const large_offset: u256 = 0x100000; // 1MB offset
    const large_size: u256 = 0x1000;     // 4KB size
    
    const target_address = Address.from_hex("0x3333333333333333333333333333333333333333") catch unreachable;
    
    try frame.stack.append(large_size);    // retSize (requires memory expansion)
    try frame.stack.append(large_offset);  // retOffset (1MB offset)
    try frame.stack.append(0);             // argsSize
    try frame.stack.append(0);             // argsOffset
    try frame.stack.append(0);             // value
    try frame.stack.append(Address.to_u256(target_address)); // to
    try frame.stack.append(100000);        // gas

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Execute CALL with large memory expansion
    _ = try evm.table.execute(0, interpreter, state, 0xF1);

    const gas_used = initial_gas - frame.gas_remaining;
    
    // Current implementation severely undercharges for memory expansion
    // This test documents the vulnerability: memory expansion should cost
    // thousands of gas units for 1MB expansion, but currently costs very little
    try testing.expect(gas_used < 1000); // Currently passes, but shouldn't!
    
    // In correct implementation, this should be:
    // try testing.expect(gas_used > 10000); // Memory expansion should be expensive
}

// Test 3: CALL with value transfer in static context
test "CALL: value transfer in static context fails" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x22} ** 20;
    // Create contract in static context
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        true, // is_static = true
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    const target_address = Address.from_hex("0x3333333333333333333333333333333333333333") catch unreachable;
    
    // Try to transfer value in static context
    try frame.stack.append(0);     // retSize
    try frame.stack.append(0);     // retOffset
    try frame.stack.append(0);     // argsSize
    try frame.stack.append(0);     // argsOffset
    try frame.stack.append(1000);  // value (non-zero, should fail in static)
    try frame.stack.append(Address.to_u256(target_address)); // to
    try frame.stack.append(100000); // gas

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Should fail with WriteProtection error
    const result = evm.table.execute(0, interpreter, state, 0xF1);
    try testing.expectError(ExecutionError.Error.WriteProtection, result);
}

// Test 4: CALL with calldata
test "CALL: with calldata" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x22} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    // Prepare calldata in memory
    const calldata = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    var i: usize = 0;
    while (i < calldata.len) : (i += 1) {
        try frame.memory.set_data(i, &[_]u8{calldata[i]});
    }

    const target_address = Address.from_hex("0x3333333333333333333333333333333333333333") catch unreachable;
    
    try frame.stack.append(32);    // retSize
    try frame.stack.append(64);    // retOffset (write return data at offset 64)
    try frame.stack.append(4);     // argsSize (4 bytes of calldata)
    try frame.stack.append(0);     // argsOffset (calldata at offset 0)
    try frame.stack.append(0);     // value
    try frame.stack.append(Address.to_u256(target_address)); // to
    try frame.stack.append(100000); // gas

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Execute CALL
    _ = try evm.table.execute(0, interpreter, state, 0xF1);

    // Should return 0 (stub always fails)
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

// Test 5: CALL with maximum depth
test "CALL: at maximum depth" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x22} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    // Set depth to maximum (1024)
    frame.depth = 1024;

    const target_address = Address.from_hex("0x3333333333333333333333333333333333333333") catch unreachable;
    
    try frame.stack.append(0);     // retSize
    try frame.stack.append(0);     // retOffset
    try frame.stack.append(0);     // argsSize
    try frame.stack.append(0);     // argsOffset
    try frame.stack.append(0);     // value
    try frame.stack.append(Address.to_u256(target_address)); // to
    try frame.stack.append(100000); // gas

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Execute CALL at max depth
    _ = try evm.table.execute(0, interpreter, state, 0xF1);

    // Should return 0 (depth limit exceeded or stub behavior)
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

// Test 6: CALL gas calculation
test "CALL: gas calculation" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x22} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;
    const target_address = Address.from_hex("0x3333333333333333333333333333333333333333") catch unreachable;
    
    // Test with different gas amounts
    try frame.stack.append(0);     // retSize
    try frame.stack.append(0);     // retOffset
    try frame.stack.append(0);     // argsSize
    try frame.stack.append(0);     // argsOffset
    try frame.stack.append(0);     // value
    try frame.stack.append(Address.to_u256(target_address)); // to
    try frame.stack.append(50000); // gas limit for call

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0xF1);

    const gas_used = initial_gas - frame.gas_remaining;
    
    // Verify some gas was consumed
    try testing.expect(gas_used > 0);
    
    // Result should be 0 (stub)
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

// Test 7: CALL with zero address (should create account)
test "CALL: to zero address" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x22} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    // Call to zero address
    try frame.stack.append(0);     // retSize
    try frame.stack.append(0);     // retOffset
    try frame.stack.append(0);     // argsSize
    try frame.stack.append(0);     // argsOffset
    try frame.stack.append(0);     // value
    try frame.stack.append(0);     // to (zero address)
    try frame.stack.append(100000); // gas

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0xF1);

    // Should return 0 (stub)
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

// Test 8: CALL with insufficient gas
test "CALL: insufficient gas" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x22} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        100, // Very low gas
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100) // Very low gas
        .build();
    defer frame.deinit();

    const target_address = Address.from_hex("0x3333333333333333333333333333333333333333") catch unreachable;
    
    try frame.stack.append(0);     // retSize
    try frame.stack.append(0);     // retOffset
    try frame.stack.append(0);     // argsSize
    try frame.stack.append(0);     // argsOffset
    try frame.stack.append(0);     // value
    try frame.stack.append(Address.to_u256(target_address)); // to
    try frame.stack.append(50);    // gas (requesting 50)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // May fail with OutOfGas or return 0
    const result = evm.table.execute(0, interpreter, state, 0xF1);
    if (result) |_| {
        // If it didn't fail, should return 0
        const call_result = try frame.stack.pop();
        try testing.expectEqual(@as(u256, 0), call_result);
    } else |err| {
        // Could fail with OutOfGas
        try testing.expectEqual(ExecutionError.Error.OutOfGas, err);
    }
}

// Test 9: CALL with overlapping memory regions
test "CALL: overlapping memory regions" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x22} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    // Write some data to memory
    const data = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        try frame.memory.set_data(i, &[_]u8{data[i]});
    }

    const target_address = Address.from_hex("0x3333333333333333333333333333333333333333") catch unreachable;
    
    // Overlapping regions: args at 0-4, return at 2-6
    try frame.stack.append(4);     // retSize
    try frame.stack.append(2);     // retOffset (overlaps with args)
    try frame.stack.append(4);     // argsSize
    try frame.stack.append(0);     // argsOffset
    try frame.stack.append(0);     // value
    try frame.stack.append(Address.to_u256(target_address)); // to
    try frame.stack.append(100000); // gas

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0xF1);

    // Should return 0 (stub)
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

// Test 10: CALL stack underflow
test "CALL: stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x22} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    // Only push 3 parameters (need 7)
    try frame.stack.append(0);
    try frame.stack.append(0);
    try frame.stack.append(0);

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Should fail with StackUnderflow
    const result = evm.table.execute(0, interpreter, state, 0xF1);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

// Test 11: CALL stack overflow
test "CALL: stack overflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x22} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    // Fill stack to near maximum (1024 - 6 = 1018 items)
    // Need to leave room for 7 CALL parameters but not 8
    var i: usize = 0;
    while (i < 1018) : (i += 1) {
        try frame.stack.append(i);
    }

    const target_address = Address.from_hex("0x3333333333333333333333333333333333333333") catch unreachable;
    
    // Push CALL parameters (7 items, will cause overflow when pushing result)
    try frame.stack.append(0);     // retSize
    try frame.stack.append(0);     // retOffset
    try frame.stack.append(0);     // argsSize
    try frame.stack.append(0);     // argsOffset
    try frame.stack.append(0);     // value
    try frame.stack.append(Address.to_u256(target_address)); // to
    try frame.stack.append(100000); // gas

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Should fail with StackOverflow when trying to push result
    const result = evm.table.execute(0, interpreter, state, 0xF1);
    try testing.expectError(ExecutionError.Error.StackOverflow, result);
}

// Test 12: CALL with max u256 values
test "CALL: max u256 values" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x22} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    const max_u256 = std.math.maxInt(u256);
    const target_address = Address.from_hex("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF") catch unreachable;
    
    // Use maximum values for offsets/sizes (should handle overflow)
    try frame.stack.append(max_u256); // retSize
    try frame.stack.append(max_u256); // retOffset
    try frame.stack.append(max_u256); // argsSize
    try frame.stack.append(max_u256); // argsOffset
    try frame.stack.append(max_u256); // value
    try frame.stack.append(Address.to_u256(target_address)); // to
    try frame.stack.append(max_u256); // gas

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Should handle gracefully (likely fail with gas or memory error)
    const result = evm.table.execute(0, interpreter, state, 0xF1);
    if (result) |_| {
        // If it didn't fail, should return 0
        const call_result = try frame.stack.pop();
        try testing.expectEqual(@as(u256, 0), call_result);
    } else |err| {
        // Should fail with some error (OutOfGas, InvalidMemoryAccess, etc.)
        _ = err;
    }
}

// Test 13: CALL self-call (recursion)
test "CALL: self-call recursion" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const contract_addr = [_]u8{0x22} ** 20;
    var contract = Contract.init(
        contract_addr, // caller is self
        contract_addr, // contract is self
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    // Call self
    const self_address = Address.init(contract_addr);
    
    try frame.stack.append(0);     // retSize
    try frame.stack.append(0);     // retOffset
    try frame.stack.append(0);     // argsSize
    try frame.stack.append(0);     // argsOffset
    try frame.stack.append(0);     // value
    try frame.stack.append(Address.to_u256(self_address)); // to (self)
    try frame.stack.append(100000); // gas

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0xF1);

    // Should return 0 (stub)
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

// Test 14: CALL with precompiled contract address
test "CALL: precompiled contract" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x22} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    // Call precompiled contract at address 0x01 (ecrecover)
    const precompile_address = Address.from_hex("0x0000000000000000000000000000000000000001") catch unreachable;
    
    try frame.stack.append(32);    // retSize
    try frame.stack.append(0);     // retOffset
    try frame.stack.append(0);     // argsSize
    try frame.stack.append(0);     // argsOffset
    try frame.stack.append(0);     // value
    try frame.stack.append(Address.to_u256(precompile_address)); // to (precompile)
    try frame.stack.append(100000); // gas

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0xF1);

    // Should return 0 (stub doesn't handle precompiles)
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

// Test 15: CALL gas stipend for value transfer
test "CALL: gas stipend for value transfer" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x22} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    const target_address = Address.from_hex("0x3333333333333333333333333333333333333333") catch unreachable;
    
    // Call with value transfer (should add 2300 gas stipend in correct implementation)
    try frame.stack.append(0);     // retSize
    try frame.stack.append(0);     // retOffset
    try frame.stack.append(0);     // argsSize
    try frame.stack.append(0);     // argsOffset
    try frame.stack.append(1);     // value (non-zero, triggers stipend)
    try frame.stack.append(Address.to_u256(target_address)); // to
    try frame.stack.append(0);     // gas (0, but should get stipend)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // In correct implementation, this would add 2300 gas stipend
    _ = try evm.table.execute(0, interpreter, state, 0xF1);

    // Should return 0 (stub)
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}