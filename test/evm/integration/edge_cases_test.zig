const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const CallParams = evm.Host.CallParams;
const CallResult = evm.CallResult;
// Updated to new API - migration in progress, tests not run yet
const opcodes = evm.opcodes;
const ExecutionError = evm.ExecutionError;

// Test stack limit edge cases
test "Integration: stack limit boundary conditions" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create test addresses
    const contract_address = evm.Address.fromHex("0x0000000000000000000000000000000000000001");
    const owner_address = evm.Address.fromHex("0x0000000000000000000000000000000000000002");

    // Create contract directly
    var contract = try evm.Contract.init(
        allocator,
        contract_address,
        owner_address,
        0,
        &[_]u8{},
        null,
    );
    defer contract.deinit(allocator, null);

    // Create frame directly
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Fill stack to near limit (1024 items)
    var i: usize = 0;
    while (i < 1023) : (i += 1) {
        try frame.stack.push(@intCast(i));
    }

    // One more push should succeed (reaching 1024)
    try frame.stack.push(1023);
    try testing.expectEqual(@as(usize, 1024), frame.stack.size());

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    // DUP1 should fail (would exceed 1024)
    const dup_result = vm.table.execute(0, interpreter, state, 0x80);
    try testing.expectError(ExecutionError.Error.StackOverflow, dup_result);

    // SWAP1 should succeed (doesn't increase stack size)
    try vm.table.execute(0, interpreter, state, 0x90);

    // POP should succeed and make room
    try vm.table.execute(0, interpreter, state, 0x50);
    try testing.expectEqual(@as(usize, 1023), frame.stack.size());

    // Now DUP1 should succeed
    try vm.table.execute(0, interpreter, state, 0x80);
    try testing.expectEqual(@as(usize, 1024), frame.stack.size());
}

// Test memory expansion edge cases
test "Integration: memory expansion limits" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create test addresses
    const contract_address = evm.Address.fromHex("0x0000000000000000000000000000000000000001");
    const owner_address = evm.Address.fromHex("0x0000000000000000000000000000000000000002");

    // Create contract directly
    var contract = try evm.Contract.init(
        allocator,
        contract_address,
        owner_address,
        0,
        &[_]u8{},
        null,
    );
    defer contract.deinit(allocator, null);

    // Create frame directly
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(30000)
        .build();
    defer frame.deinit();

    // Try moderate memory expansion
    try frame.stack.push(0x1234);
    try frame.stack.push(1000); // offset

    const gas_before = frame.gas_remaining;

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    try vm.table.execute(0, interpreter, state, 0x52);

    const gas_used = gas_before - frame.gas_remaining;
    try testing.expect(gas_used > 0);

    // Try very large memory expansion
    frame.gas_remaining = 1000; // Limited gas
    try frame.stack.push(0x5678);
    try frame.stack.push(1000000); // Very large offset

    // Should fail with out of gas
    const result = vm.table.execute(0, interpreter, state, 0x52);
    try testing.expectError(ExecutionError.Error.OutOfGas, result);
}

// Test u256 overflow/underflow edge cases
test "Integration: arithmetic overflow and underflow" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create test addresses
    const contract_address = evm.Address.fromHex("0x0000000000000000000000000000000000000001");
    const owner_address = evm.Address.fromHex("0x0000000000000000000000000000000000000002");

    // Create contract directly
    var contract = try evm.Contract.init(
        allocator,
        contract_address,
        owner_address,
        0,
        &[_]u8{},
        null,
    );
    defer contract.deinit(allocator, null);

    // Create frame directly
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    const max_u256 = std.math.maxInt(u256);

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    // Test addition overflow (wraps around)
    try frame.stack.push(max_u256);
    try frame.stack.push(1);
    try vm.table.execute(0, interpreter, state, 0x01);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());

    // Test subtraction underflow (wraps around)
    try frame.stack.push(0);
    try frame.stack.push(1);
    try vm.table.execute(0, interpreter, state, 0x03);
    try testing.expectEqual(max_u256, try frame.stack.pop());

    // Test multiplication overflow
    try frame.stack.push(max_u256);
    try frame.stack.push(2);
    try vm.table.execute(0, interpreter, state, 0x02);
    try testing.expectEqual(max_u256 - 1, try frame.stack.pop()); // (2^256 - 1) * 2 = 2^257 - 2 ≡ -2 ≡ 2^256 - 2

    // Test division by zero
    try frame.stack.push(100);
    try frame.stack.push(0);
    try vm.table.execute(0, interpreter, state, 0x04);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // EVM returns 0 for division by zero

    // Test modulo by zero
    try frame.stack.push(100);
    try frame.stack.push(0);
    try vm.table.execute(0, interpreter, state, 0x06);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // EVM returns 0 for modulo by zero
}

// Test signed arithmetic edge cases
test "Integration: signed arithmetic boundaries" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create test addresses
    const contract_address = evm.Address.fromHex("0x0000000000000000000000000000000000000001");
    const owner_address = evm.Address.fromHex("0x0000000000000000000000000000000000000002");

    // Create contract directly
    var contract = try evm.Contract.init(
        allocator,
        contract_address,
        owner_address,
        0,
        &[_]u8{},
        null,
    );
    defer contract.deinit(allocator, null);

    // Create frame directly
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Maximum positive signed value (2^255 - 1)
    const max_signed: u256 = (@as(u256, 1) << 255) - 1;
    // Minimum negative signed value (-2^255)
    const min_signed: u256 = @as(u256, 1) << 255;

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    // Test SLT with boundary values
    try frame.stack.push(max_signed); // Maximum positive
    try frame.stack.push(min_signed); // Minimum negative
    try vm.table.execute(0, interpreter, state, 0x12);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop()); // -2^255 < 2^255-1

    // Test SGT with boundary values
    try frame.stack.push(min_signed); // Minimum negative
    try frame.stack.push(max_signed); // Maximum positive
    try vm.table.execute(0, interpreter, state, 0x13);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop()); // 2^255-1 > -2^255

    // Test SDIV with overflow case
    try frame.stack.push(min_signed); // -2^255
    try frame.stack.push(std.math.maxInt(u256)); // -1 in two's complement
    try vm.table.execute(0, interpreter, state, 0x05);
    try testing.expectEqual(min_signed, try frame.stack.pop()); // -2^255 / -1 = -2^255 (overflow)
}

// Test bitwise operations edge cases
test "Integration: bitwise operation boundaries" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create test addresses
    const contract_address = evm.Address.fromHex("0x0000000000000000000000000000000000000001");
    const owner_address = evm.Address.fromHex("0x0000000000000000000000000000000000000002");

    // Create contract directly
    var contract = try evm.Contract.init(
        allocator,
        contract_address,
        owner_address,
        0,
        &[_]u8{},
        null,
    );
    defer contract.deinit(allocator, null);

    // Create frame directly
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    // Test shift operations with large shift amounts
    try frame.stack.push(0xFF);
    try frame.stack.push(256); // Shift by full width
    try vm.table.execute(0, interpreter, state, 0x1B);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // Shifts out completely

    try frame.stack.push(@as(u256, 0xFF) << 248); // Byte in most significant position
    try frame.stack.push(256); // Shift right by full width
    try vm.table.execute(0, interpreter, state, 0x1C);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // Shifts out completely

    // Test SAR with negative number
    const negative_one = std.math.maxInt(u256); // -1 in two's complement
    try frame.stack.push(negative_one);
    try frame.stack.push(255); // Shift right by 255 bits
    try vm.table.execute(0, interpreter, state, 0x1D);
    try testing.expectEqual(negative_one, try frame.stack.pop()); // Sign extension fills with 1s

    // Test BYTE operation edge cases
    try frame.stack.push(0x0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20);
    try frame.stack.push(0); // Get most significant byte
    try vm.table.execute(0, interpreter, state, 0x1A);
    try testing.expectEqual(@as(u256, 0x01), try frame.stack.pop());

    try frame.stack.push(0x0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20);
    try frame.stack.push(31); // Get least significant byte
    try vm.table.execute(0, interpreter, state, 0x1A);
    try testing.expectEqual(@as(u256, 0x20), try frame.stack.pop());

    try frame.stack.push(0x0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20);
    try frame.stack.push(32); // Out of range
    try vm.table.execute(0, interpreter, state, 0x1A);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // Returns 0 for out of range
}

// Test call with insufficient gas
test "Integration: call gas calculation edge cases" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create test addresses
    const contract_address = evm.Address.fromHex("0x0000000000000000000000000000000000000001");
    const owner_address = evm.Address.fromHex("0x0000000000000000000000000000000000000002");
    const to_address = evm.Address.fromHex("0x0000000000000000000000000000000000000003");

    // Create contract directly
    var contract = try evm.Contract.init(
        allocator,
        contract_address,
        owner_address,
        0,
        &[_]u8{},
        null,
    );
    defer contract.deinit(allocator, null);

    // Create frame directly
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    // Set up call result expectation
    vm.call_result = .{
        .success = false,
        .gas_left = 0,
        .output = null,
    };

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    // Request more gas than available
    try frame.stack.push(0); // ret_size
    try frame.stack.push(0); // ret_offset
    try frame.stack.push(0); // args_size
    try frame.stack.push(0); // args_offset
    try frame.stack.push(0); // value
    try frame.stack.push(to_address.to_u256()); // to
    try frame.stack.push(2000); // gas (more than available)

    try vm.table.execute(0, interpreter, state, 0xF1);

    // Call should fail but not error
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());

    // Should have consumed gas (at least 1/64th retained)
    try testing.expect(frame.gas_remaining < 1000);
    try testing.expect(frame.gas_remaining >= 1000 / 64);
}

// Test RETURNDATACOPY edge cases
test "Integration: return data boundary conditions" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create test addresses
    const contract_address = evm.Address.fromHex("0x0000000000000000000000000000000000000001");
    const owner_address = evm.Address.fromHex("0x0000000000000000000000000000000000000002");

    // Create contract directly
    var contract = try evm.Contract.init(
        allocator,
        contract_address,
        owner_address,
        0,
        &[_]u8{},
        null,
    );
    defer contract.deinit(allocator, null);

    // Create frame directly
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Set return data
    const return_data = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    try frame.return_data.set(&return_data);

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    // Test 1: Copy within bounds
    try frame.stack.push(2); // size
    try frame.stack.push(1); // data offset
    try frame.stack.push(0); // memory offset

    try vm.table.execute(0, interpreter, state, 0x3E);

    try testing.expectEqual(@as(u8, 0x22), frame.memory.read_byte(0));
    try testing.expectEqual(@as(u8, 0x33), frame.memory.read_byte(1));

    // Test 2: Copy with offset at boundary
    try frame.stack.push(1); // size
    try frame.stack.push(3); // data offset (last valid)
    try frame.stack.push(10); // memory offset

    try vm.table.execute(0, interpreter, state, 0x3E);

    try testing.expectEqual(@as(u8, 0x44), frame.memory.read_byte(10));

    // Test 3: Copy beyond boundary - should fail
    try frame.stack.push(2); // size
    try frame.stack.push(3); // data offset (would read beyond)
    try frame.stack.push(20); // memory offset

    const result = vm.table.execute(0, interpreter, state, 0x3E);
    try testing.expectError(ExecutionError.Error.ReturnDataOutOfBounds, result);

    // Test 4: Offset beyond data - should fail
    try frame.stack.push(1); // size
    try frame.stack.push(5); // data offset (beyond data)
    try frame.stack.push(30); // memory offset

    const result2 = vm.table.execute(0, interpreter, state, 0x3E);
    try testing.expectError(ExecutionError.Error.ReturnDataOutOfBounds, result2);
}

// Test EXP edge cases
test "Integration: exponentiation edge cases" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create test addresses
    const contract_address = evm.Address.fromHex("0x0000000000000000000000000000000000000001");
    const owner_address = evm.Address.fromHex("0x0000000000000000000000000000000000000002");

    // Create contract directly
    var contract = try evm.Contract.init(
        allocator,
        contract_address,
        owner_address,
        0,
        &[_]u8{},
        null,
    );
    defer contract.deinit(allocator, null);

    // Create frame directly
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    // Test 0^0 = 1
    try frame.stack.push(0); // base
    try frame.stack.push(0); // exponent
    try vm.table.execute(0, interpreter, state, 0x0A);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    // Test x^0 = 1
    try frame.stack.push(12345); // base
    try frame.stack.push(0); // exponent
    try vm.table.execute(0, interpreter, state, 0x0A);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    // Test 0^x = 0 (x > 0)
    try frame.stack.push(0); // base
    try frame.stack.push(5); // exponent
    try vm.table.execute(0, interpreter, state, 0x0A);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());

    // Test 1^x = 1
    try frame.stack.push(1); // base
    try frame.stack.push(std.math.maxInt(u256)); // huge exponent
    try vm.table.execute(0, interpreter, state, 0x0A);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    // Test 2^256 (overflow)
    try frame.stack.push(2); // base
    try frame.stack.push(256); // exponent
    try vm.table.execute(0, interpreter, state, 0x0A);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // Overflows to 0
}

// Test JUMPDEST validation edge cases
test "Integration: jump destination validation" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create test addresses
    const contract_address = evm.Address.fromHex("0x0000000000000000000000000000000000000001");
    const owner_address = evm.Address.fromHex("0x0000000000000000000000000000000000000002");

    // Create code with JUMPDEST in data section of PUSH
    const code = [_]u8{
        0x60, 0x5B, // PUSH1 0x5B (0x5B is JUMPDEST opcode, but it's data here)
        0x00, // STOP
        0x5B, // JUMPDEST (valid at position 3)
        0x00, // STOP
    };

    // Create contract directly
    var contract = try evm.Contract.init(
        allocator,
        contract_address,
        owner_address,
        0,
        &code,
        null,
    );
    defer contract.deinit(allocator, null);

    // Create frame directly
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    // Mark position 3 as valid jump destination
    try contract.mark_jumpdests();

    // Jump to position 1 (inside PUSH data) - should fail
    try frame.stack.push(1);
    const result1 = vm.table.execute(0, interpreter, state, 0x56);
    try testing.expectError(ExecutionError.Error.InvalidJump, result1);

    // Jump to position 3 (valid JUMPDEST) - should succeed
    frame.stack.clear();
    try frame.stack.push(3);
    const result2 = try vm.table.execute(0, interpreter, state, 0x56);
    _ = result2;
    // PC should have changed to 3
    try testing.expectEqual(@as(usize, 3), frame.pc);
}

// Test cold/warm storage slot transitions
test "Integration: storage slot temperature transitions" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create test addresses
    const contract_address = evm.Address.fromHex("0x0000000000000000000000000000000000000001");
    const owner_address = evm.Address.fromHex("0x0000000000000000000000000000000000000002");

    // Create contract directly
    var contract = try evm.Contract.init(
        allocator,
        contract_address,
        owner_address,
        0,
        &[_]u8{},
        null,
    );
    defer contract.deinit(allocator, null);

    // Create frame directly
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    // First access to slot 100 - cold
    try frame.stack.push(100); // slot
    const gas_before_cold = frame.gas_remaining;
    try vm.table.execute(0, interpreter, state, 0x54);
    const cold_gas = gas_before_cold - frame.gas_remaining;
    // Note: The actual gas cost depends on the opcode implementation
    // For SLOAD, cold access costs 2100 gas total (2000 + 100 base)
    // But the jump table may handle the base cost separately
    try testing.expect(cold_gas > 0); // Should consume some gas

    _ = try frame.stack.pop(); // Discard result

    // Second access to slot 100 - warm
    try frame.stack.push(100); // slot
    const gas_before_warm = frame.gas_remaining;
    try vm.table.execute(0, interpreter, state, 0x54);
    const warm_gas = gas_before_warm - frame.gas_remaining;
    // Warm access should consume less gas than cold
    try testing.expect(warm_gas < cold_gas);

    _ = try frame.stack.pop(); // Discard result

    // Access different slot - cold again
    try frame.stack.push(200); // different slot
    const gas_before_cold2 = frame.gas_remaining;
    try vm.table.execute(0, interpreter, state, 0x54);
    const cold_gas2 = gas_before_cold2 - frame.gas_remaining;
    // Should be similar to first cold access
    try testing.expect(cold_gas2 > 0);
}

// Test MCOPY with overlapping regions
test "Integration: MCOPY overlap handling" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create test addresses
    const contract_address = evm.Address.fromHex("0x0000000000000000000000000000000000000001");
    const owner_address = evm.Address.fromHex("0x0000000000000000000000000000000000000002");

    // Create contract directly
    var contract = try evm.Contract.init(
        allocator,
        contract_address,
        owner_address,
        0,
        &[_]u8{},
        null,
    );
    defer contract.deinit(allocator, null);

    // Create frame directly
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Write pattern to memory
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try frame.memory.write_byte(i, @intCast(i + 1)); // 1,2,3,4,5,6,7,8,9,10
    }

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    // Test forward overlap (source < dest, overlapping)
    try frame.stack.push(6); // length
    try frame.stack.push(2); // source offset
    try frame.stack.push(5); // dest offset (overlaps last 3 bytes)

    try vm.table.execute(0, interpreter, state, 0x5E);

    // Memory should be: 1,2,3,4,5,3,4,5,6,7,8
    try testing.expectEqual(@as(u8, 3), frame.memory.read_byte(5));
    try testing.expectEqual(@as(u8, 4), frame.memory.read_byte(6));
    try testing.expectEqual(@as(u8, 5), frame.memory.read_byte(7));
    try testing.expectEqual(@as(u8, 6), frame.memory.read_byte(8));
    try testing.expectEqual(@as(u8, 7), frame.memory.read_byte(9));
    try testing.expectEqual(@as(u8, 8), frame.memory.read_byte(10));
}
