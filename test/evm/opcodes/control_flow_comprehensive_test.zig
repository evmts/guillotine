const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const CallParams = Evm.Host.CallParams;
const CallResult = Evm.CallResult;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const MemoryDatabase = Evm.MemoryDatabase;
const ExecutionError = Evm.ExecutionError;
// Updated to new API - migration in progress, tests not run yet

// ============================
// Control Flow Instructions (0x56-0x58, 0x5A-0x5B)
// JUMP, JUMPI, PC, GAS, JUMPDEST
// ============================

// ============================
// 0x56: JUMP - Unconditional jump to destination
// ============================

test "JUMP (0x56): Basic unconditional jump" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    // Create bytecode with JUMPDEST at position 5
    var code = [_]u8{0} ** 8;
    code[0] = 0x60; // PUSH1
    code[1] = 0x05; // 5 (jump destination)
    code[2] = 0x56; // JUMP
    code[3] = 0x00; // STOP (should be skipped)
    code[4] = 0x00; // padding
    code[5] = 0x5B; // JUMPDEST at position 5
    code[6] = 0x60; // PUSH1
    code[7] = 0x42; // 0x42

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Analyze jumpdests in the contract

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Push jump destination
    try frame.stack.append(5);

    // Execute JUMP
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0x56);

    // Program counter should now be at position 5
    try testing.expectEqual(@as(usize, 5), frame.pc);
}

test "JUMP: Simple JUMPDEST validation" {
    const allocator = testing.allocator;
    defer Contract.clear_analysis_cache(allocator);

    // Simple test: just verify that JUMPDEST validation works
    const code = [_]u8{
        0x5B, // JUMPDEST at position 0
        0x60, 0x00, // PUSH1 0
        0x56, // JUMP back to 0
    };

    const caller: Address = [_]u8{0x11} ** 20;
    const contract_addr: Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Analyze jumpdests

    // Test that position 0 is valid
    const is_valid = contract.valid_jumpdest(allocator, 0);
    try testing.expect(is_valid);

    // Test that position 1 is invalid (it's a PUSH1 opcode)
    const is_invalid = contract.valid_jumpdest(allocator, 1);
    try testing.expect(!is_invalid);
}

test "JUMP: Jump to various valid destinations" {
    const allocator = testing.allocator;
    defer Contract.clear_analysis_cache(allocator);

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    // Complex bytecode with multiple JUMPDESTs
    const code = [_]u8{
        0x5B, // JUMPDEST at position 0
        0x60, 0x05, // PUSH1 5 (positions 1-2)
        0x5B, // JUMPDEST at position 3
        0x60, 0x08, // PUSH1 8 (positions 4-5)
        0x5B, // JUMPDEST at position 6
        0x60, 0x0C, // PUSH1 12 (positions 7-8)
        0x5B, // JUMPDEST at position 9
        0x60, 0x0F, // PUSH1 15 (positions 10-11)
        0x5B, // JUMPDEST at position 12
        0x60, 0x10, // PUSH1 16 (positions 13-14)
        0x00, // STOP at position 15
        0x5B, // JUMPDEST at position 16
        0x00, // STOP at position 17
    };

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Analyze jumpdests in the contract

    // Test jumping to each valid JUMPDEST (check positions carefully!)
    // Position 0: 0x5B, Position 3: 0x5B, Position 6: 0x5B, Position 9: 0x5B, Position 12: 0x5B, Position 16: 0x5B
    const destinations = [_]u256{ 0, 3, 6, 9, 12, 16 };
    for (destinations) |dest| {
        var test_frame_builder = Frame.builder(allocator);
        var test_frame = try test_frame_builder
            .withVm(&evm)
            .withContract(&contract)
            .withGas(1000)
            .build();
        defer test_frame.deinit();

        try test_frame.stack.append(dest);
        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &test_frame;
        _ = try evm.table.execute(0, interpreter, state, 0x56);
        try testing.expectEqual(@as(usize, @intCast(dest)), test_frame.pc);
    }
}

test "JUMP: Invalid jump destinations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{
        0x60, 0x05, // PUSH1 5 - position 0,1
        0x56, // JUMP - position 2
        0x00, // STOP - position 3
        0x5B, // JUMPDEST - position 4
        0x00, // STOP - position 5
    };

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Analyze jumpdests in the contract

    // Test jumping to invalid destinations
    const invalid_destinations = [_]u256{ 1, 2, 3, 5, 100, std.math.maxInt(usize) };

    for (invalid_destinations) |dest| {
        var test_frame_builder = Frame.builder(allocator);
        var test_frame = try test_frame_builder
            .withVm(&evm)
            .withContract(&contract)
            .withGas(1000)
            .build();
        defer test_frame.deinit();

        try test_frame.stack.append(dest);
        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &test_frame;
        const result = evm.table.execute(0, interpreter, state, 0x56);
        try testing.expectError(ExecutionError.Error.InvalidJump, result);
    }
}

test "JUMP: Stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{0x5B}; // Just a JUMPDEST

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Analyze jumpdests in the contract

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    // Don't push anything to stack - should cause stack underflow
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    const result = evm.table.execute(0, interpreter, state, 0x56);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

// ============================
// 0x57: JUMPI - Conditional jump to destination
// ============================

test "JUMPI (0x57): Conditional jump with true condition" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    var code = [_]u8{0} ** 10;
    code[0] = 0x60; // PUSH1
    code[1] = 0x01; // 1 (condition)
    code[2] = 0x60; // PUSH1
    code[3] = 0x08; // 8 (destination)
    code[4] = 0x57; // JUMPI
    code[5] = 0x00; // STOP (should be skipped)
    code[6] = 0x00; // padding
    code[7] = 0x00; // padding
    code[8] = 0x5B; // JUMPDEST at position 8
    code[9] = 0x60; // PUSH1

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Force analysis to identify JUMPDEST positions

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Execute the PUSH1 instructions in the bytecode
    // PUSH1 1 (condition)
    frame.pc = 0;
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60); // PUSH1 1

    // PUSH1 8 (destination)
    frame.pc = 2;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60); // PUSH1 8

    // Execute JUMPI
    frame.pc = 4;
    _ = try evm.table.execute(0, interpreter, state, 0x57);

    // Should have jumped to position 8
    try testing.expectEqual(@as(usize, 8), frame.pc);
}

test "JUMPI: Conditional jump with false condition" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    var code = [_]u8{0} ** 12;
    code[0] = 0x60; // PUSH1
    code[1] = 0x00; // 0 (false condition)
    code[2] = 0x60; // PUSH1
    code[3] = 0x09; // 9 (destination)
    code[4] = 0x57; // JUMPI
    code[5] = 0x60; // PUSH1
    code[6] = 0x42; // 0x42 (should execute)
    code[7] = 0x00; // STOP
    code[8] = 0x00; // padding
    code[9] = 0x5B; // JUMPDEST at position 9
    code[10] = 0x60; // PUSH1
    code[11] = 0x99; // 0x99 (should not execute)

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Set PC to start of JUMPI instruction
    frame.pc = 4; // Position of JUMPI

    // Push condition and destination
    try frame.stack.append(0); // condition = 0 (false)
    try frame.stack.append(9); // destination = 9

    // Execute JUMPI
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0x57);

    // Should not have jumped - PC should remain at 4
    try testing.expectEqual(@as(usize, 4), frame.pc);
}

test "JUMPI: Various condition values" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{
        0x5B, // JUMPDEST at position 0
        0x00, // STOP
    };

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Test true conditions (any non-zero value)
    const true_conditions = [_]u256{ 1, 255, 1000, std.math.maxInt(u256) };

    for (true_conditions) |condition| {
        var test_frame_builder = Frame.builder(allocator);
        var test_frame = try test_frame_builder
            .withVm(&evm)
            .withContract(&contract)
            .withGas(1000)
            .build();
        defer test_frame.deinit();

        test_frame.pc = 10; // Set to non-zero position
        try test_frame.stack.append(condition); // condition
        try test_frame.stack.append(0); // dest=0
        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &test_frame;
        _ = try evm.table.execute(0, interpreter, state, 0x57);
        try testing.expectEqual(@as(usize, 0), test_frame.pc); // Should jump
    }

    // Test false condition (only zero)
    {
        var test_frame_builder = Frame.builder(allocator);
        var test_frame = try test_frame_builder
            .withVm(&evm)
            .withContract(&contract)
            .withGas(1000)
            .build();
        defer test_frame.deinit();

        test_frame.pc = 10;
        try test_frame.stack.append(0); // condition=0
        try test_frame.stack.append(0); // dest=0
        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &test_frame;
        _ = try evm.table.execute(0, interpreter, state, 0x57);
        try testing.expectEqual(@as(usize, 10), test_frame.pc); // Should not jump
    }
}

test "JUMPI: Invalid destination with true condition" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{0x5B}; // JUMPDEST at position 0

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    // Try to jump to invalid destination with true condition
    try frame.stack.append(1); // condition=1 (true)
    try frame.stack.append(5); // dest=5 (invalid)
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    const result = evm.table.execute(0, interpreter, state, 0x57);
    try testing.expectError(ExecutionError.Error.InvalidJump, result);
}

test "JUMPI: Stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{0x5B}; // JUMPDEST

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    // Test with empty stack
    {
        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &frame;
        const result = evm.table.execute(0, interpreter, state, 0x57);
        try testing.expectError(ExecutionError.Error.StackUnderflow, result);
    }

    // Test with only one value on stack (need two)
    {
        frame.stack.clear();
        try frame.stack.append(5);
        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &frame;
        const result = evm.table.execute(0, interpreter, state, 0x57);
        try testing.expectError(ExecutionError.Error.StackUnderflow, result);
    }
}

// ============================
// 0x58: PC - Get current program counter
// ============================

test "PC (0x58): Get program counter at various positions" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{
        0x58, // PC at position 0
        0x58, // PC at position 1
        0x60, 0x42, // PUSH1 0x42 at position 2-3
        0x58, // PC at position 4
        0x00, // STOP at position 5
    };

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test PC at position 0
    frame.pc = 0;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x58);
    const val0 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), val0);

    // Test PC at position 1
    frame.pc = 1;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x58);
    const val1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), val1);

    // Test PC at position 4
    frame.pc = 4;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x58);
    const val4 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 4), val4);

    // Test PC at large position
    frame.pc = 1000;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x58);
    const val1000 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1000), val1000);
}

test "PC: Stack overflow protection" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x58}, // PC
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Fill stack to capacity - 1 (so PC can still push one value)
    const stack_capacity = Evm.Stack.CAPACITY;
    for (0..stack_capacity - 1) |_| {
        try frame.stack.append(0);
    }

    // This should succeed
    frame.pc = 42;
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x58);
    const val = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 42), val);

    // Fill stack to capacity
    try frame.stack.append(0);

    // This should fail with stack overflow
    const result = evm.table.execute(frame.pc, interpreter, state, 0x58);
    try testing.expectError(ExecutionError.Error.StackOverflow, result);
}

// ============================
// 0x5A: GAS - Get remaining gas
// ============================

test "GAS (0x5A): Get remaining gas" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x5A}, // GAS
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Test with different gas amounts
    const test_gas_amounts = [_]u64{ 100, 1000, 10000, 100000, 1000000 };

    for (test_gas_amounts) |initial_gas| {
        var test_frame_builder = Frame.builder(allocator);
        var test_frame = try test_frame_builder
            .withVm(&evm)
            .withContract(&contract)
            .withGas(initial_gas)
            .build();
        defer test_frame.deinit();

        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &test_frame;
        _ = try evm.table.execute(0, interpreter, state, 0x5A);

        // GAS opcode should return remaining gas minus its own cost (2)
        const expected_gas = initial_gas - 2;
        const val = try test_frame.stack.pop();
        try testing.expectEqual(@as(u256, expected_gas), val);
    }
}

test "GAS: After consuming gas with operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x5A}, // GAS
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Execute some operations to consume gas
    try frame.stack.append(5);
    try frame.stack.append(10);
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0x01); // ADD (costs 3)
    _ = try frame.stack.pop();

    try frame.stack.append(2);
    try frame.stack.append(3);
    _ = try evm.table.execute(0, interpreter, state, 0x02); // MUL (costs 5)
    _ = try frame.stack.pop();

    // Now execute GAS opcode
    _ = try evm.table.execute(0, interpreter, state, 0x5A);

    // Calculate expected remaining gas: initial - ADD - MUL - GAS
    const expected_gas = initial_gas - 3 - 5 - 2;
    const val = try frame.stack.pop();
    try testing.expectEqual(@as(u256, expected_gas), val);
}

test "GAS: Low gas scenarios" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x5A}, // GAS
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Test with exactly enough gas for GAS opcode
    {
        var test_frame_builder = Frame.builder(allocator);
        var test_frame = try test_frame_builder
            .withVm(&evm)
            .withContract(&contract)
            .withGas(2)
            .build();
        defer test_frame.deinit();

        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &test_frame;
        _ = try evm.table.execute(0, interpreter, state, 0x5A);
        const val = try test_frame.stack.pop();
        try testing.expectEqual(@as(u256, 0), val); // All gas consumed
    }

    // Test with not enough gas
    {
        var test_frame_builder = Frame.builder(allocator);
        var test_frame = try test_frame_builder
            .withVm(&evm)
            .withContract(&contract)
            .withGas(1)
            .build();
        defer test_frame.deinit();

        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &test_frame;
        const result = evm.table.execute(0, interpreter, state, 0x5A);
        try testing.expectError(ExecutionError.Error.OutOfGas, result);
    }
}

test "GAS: Stack overflow protection" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x5A}, // GAS
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Fill stack to capacity
    const stack_capacity = Evm.Stack.CAPACITY;
    for (0..stack_capacity) |_| {
        try frame.stack.append(0);
    }

    // This should fail with stack overflow
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    const result = evm.table.execute(0, interpreter, state, 0x5A);
    try testing.expectError(ExecutionError.Error.StackOverflow, result);
}

// ============================
// 0x5B: JUMPDEST - Valid jump destination marker
// ============================

test "JUMPDEST (0x5B): Basic operation" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{
        0x5B, // JUMPDEST at position 0
        0x60, 0x42, // PUSH1 0x42
        0x5B, // JUMPDEST at position 3
        0x00, // STOP
    };

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // JUMPDEST should be a no-op
    const stack_size_before = frame.stack.size;
    const gas_before = frame.gas_remaining;

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0x5B);

    // Stack should be unchanged
    try testing.expectEqual(stack_size_before, frame.stack.size);

    // Should consume only JUMPDEST gas (1)
    try testing.expectEqual(@as(u64, gas_before - 1), frame.gas_remaining);
}

test "JUMPDEST: Jump destination validation" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    // Create bytecode with JUMPDEST in various positions (like working test)
    var code = [_]u8{0} ** 12;
    code[0] = 0x5B; // JUMPDEST at position 0
    code[1] = 0x60; // PUSH1
    code[2] = 0x05; // 5
    code[3] = 0x5B; // JUMPDEST at position 3
    code[4] = 0x60; // PUSH1
    code[5] = 0x09; // 9
    code[6] = 0x56; // JUMP
    code[7] = 0x00; // STOP (should be skipped)
    code[8] = 0x00; // padding
    code[9] = 0x5B; // JUMPDEST at position 9
    code[10] = 0x60; // PUSH1
    code[11] = 0x42; // 0x42

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Force analysis to ensure JUMPDEST positions are identified

    // Verify JUMPDEST positions are valid
    try testing.expect(contract.valid_jumpdest(allocator, 0)); // Position 0
    try testing.expect(contract.valid_jumpdest(allocator, 3)); // Position 3
    try testing.expect(contract.valid_jumpdest(allocator, 9)); // Position 9

    // Verify non-JUMPDEST positions are invalid
    try testing.expect(!contract.valid_jumpdest(allocator, 1)); // PUSH1 opcode
    try testing.expect(!contract.valid_jumpdest(allocator, 2)); // PUSH1 data
    try testing.expect(!contract.valid_jumpdest(allocator, 6)); // JUMP opcode
    try testing.expect(!contract.valid_jumpdest(allocator, 8)); // padding

    // Test actual jumping to valid JUMPDEST
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    frame.pc = 5; // Position before JUMP
    try frame.stack.append(9); // Jump to JUMPDEST at position 9
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0x56); // JUMP
    try testing.expectEqual(@as(usize, 9), frame.pc);
}

test "JUMPDEST: Code analysis edge cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    // JUMPDEST opcode appearing as data in PUSH instructions
    var code = [_]u8{0} ** 7;
    code[0] = 0x60; // PUSH1
    code[1] = 0x5B; // 0x5B (JUMPDEST as data)
    code[2] = 0x50; // POP
    code[3] = 0x5B; // Real JUMPDEST at position 3
    code[4] = 0x60; // PUSH1
    code[5] = 0x42; // 0x42
    code[6] = 0x00; // STOP

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Force analysis

    // The 0x5B at position 1 should NOT be a valid jump destination (it's data)
    try testing.expect(!contract.valid_jumpdest(allocator, 1));

    // The 0x5B at position 3 SHOULD be a valid jump destination
    try testing.expect(contract.valid_jumpdest(allocator, 3));

    // Test jumping to the valid JUMPDEST
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    try frame.stack.append(3);
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0x56); // JUMP
    try testing.expectEqual(@as(usize, 3), frame.pc);
}

test "JUMPDEST: Empty code and no JUMPDEST scenarios" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    // Code with no JUMPDESTs
    const code_no_jumpdest = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x24, // PUSH1 0x24
        0x01, // ADD
        0x00, // STOP
    };

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code_no_jumpdest,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // No positions should be valid jump destinations
    for (0..code_no_jumpdest.len) |i| {
        try testing.expect(!contract.valid_jumpdest(allocator, @intCast(i)));
    }

    // Test empty code
    var empty_contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer empty_contract.deinit(allocator, null);

    // No positions should be valid in empty code
    try testing.expect(!empty_contract.valid_jumpdest(allocator, 0));
    try testing.expect(!empty_contract.valid_jumpdest(allocator, 100));
}

// ============================
// Gas consumption tests
// ============================

test "Control Flow: Gas consumption verification" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{0x5B}; // Include JUMPDEST for JUMP/JUMPI tests

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const opcodes = [_]struct {
        opcode: u8,
        name: []const u8,
        expected_gas: u64,
        setup: ?*const fn (*Frame) anyerror!void,
    }{
        .{ .opcode = 0x56, .name = "JUMP", .expected_gas = 8, .setup = &setup_jump },
        .{ .opcode = 0x57, .name = "JUMPI", .expected_gas = 10, .setup = &setup_jumpi },
        .{ .opcode = 0x58, .name = "PC", .expected_gas = 2, .setup = null },
        .{ .opcode = 0x5A, .name = "GAS", .expected_gas = 2, .setup = null },
        .{ .opcode = 0x5B, .name = "JUMPDEST", .expected_gas = 1, .setup = null },
    };

    for (opcodes) |op| {
        var test_frame_builder = Frame.builder(allocator);
        var test_frame = try test_frame_builder
            .withVm(&evm)
            .withContract(&contract)
            .withGas(1000)
            .build();
        defer test_frame.deinit();

        const gas_before = test_frame.gas_remaining;

        if (op.setup) |setup_fn| {
            try setup_fn(&test_frame);
        }

        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &test_frame;
        _ = try evm.table.execute(0, interpreter, state, op.opcode);

        const gas_used = gas_before - test_frame.gas_remaining;
        try testing.expectEqual(op.expected_gas, gas_used);
    }
}

fn setup_jump(test_frame: *Frame) !void {
    try test_frame.stack.append(0); // Jump to position 0 (valid JUMPDEST)
}

fn setup_jumpi(test_frame: *Frame) !void {
    try test_frame.stack.append(0); // condition=0 (don't jump)
    try test_frame.stack.append(0); // dest=0
}

// ============================
// Complex control flow scenarios
// ============================

test "Control Flow: Complex jump sequences" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    // Create a program with complex control flow
    var code = [_]u8{0} ** 20;
    code[0] = 0x5B; // JUMPDEST at 0 - entry point
    code[1] = 0x60; // PUSH1
    code[2] = 0x08; // 8 - jump to subroutine
    code[3] = 0x56; // JUMP
    code[4] = 0x60; // PUSH1 0xFF (should not execute)
    code[5] = 0xFF; // 0xFF
    code[6] = 0x00; // STOP
    code[7] = 0x00; // padding
    code[8] = 0x5B; // JUMPDEST at 8 - subroutine
    code[9] = 0x60; // PUSH1
    code[10] = 0x42; // 0x42
    code[11] = 0x60; // PUSH1
    code[12] = 0x01; // 1 (true condition)
    code[13] = 0x60; // PUSH1
    code[14] = 0x11; // 17 (conditional jump target)
    code[15] = 0x57; // JUMPI
    code[16] = 0x00; // STOP (should not execute)
    code[17] = 0x5B; // JUMPDEST at 17 - conditional target
    code[18] = 0x60; // PUSH1
    code[19] = 0x24; // 0x24

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Execute the complex flow manually
    // 1. Start at JUMPDEST 0
    frame.pc = 0;
    _ = try evm.table.execute(0, interpreter, state, 0x5B); // JUMPDEST

    // 2. PUSH1 8
    frame.pc = 1;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60); // PUSH1 8

    // 3. JUMP to 8
    frame.pc = 3;
    _ = try evm.table.execute(0, interpreter, state, 0x56); // JUMP
    try testing.expectEqual(@as(usize, 8), frame.pc);

    // 4. Execute JUMPDEST at 8
    _ = try evm.table.execute(0, interpreter, state, 0x5B); // JUMPDEST

    // 5. PUSH1 0x42
    frame.pc = 9;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60); // PUSH1 0x42

    // 6. PUSH1 1
    frame.pc = 11;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60); // PUSH1 1

    // 7. PUSH1 17
    frame.pc = 13;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60); // PUSH1 17

    // 8. JUMPI (should jump because condition is 1)
    frame.pc = 15;
    _ = try evm.table.execute(0, interpreter, state, 0x57); // JUMPI
    try testing.expectEqual(@as(usize, 17), frame.pc);

    // Verify stack state
    const val3 = try frame.stack.pop(); // Should be 0x42
    try testing.expectEqual(@as(u256, 0x42), val3);
}

test "Control Flow: Simple JUMPDEST validation" {
    const allocator = testing.allocator;
    defer Contract.clear_analysis_cache(allocator); // Clean up cache after test

    // Simple test: just validate that a JUMPDEST at position 0 is recognized
    const code = [_]u8{0x5B}; // Just a JUMPDEST

    const caller: Address = [_]u8{0x11} ** 20;
    const contract_addr: Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Analyze jumpdests

    // This should return true for position 0
    const is_valid = contract.valid_jumpdest(allocator, 0);
    try testing.expect(is_valid);

    // This should return false for position 1 (out of bounds)
    const is_invalid = contract.valid_jumpdest(allocator, 1);
    try testing.expect(!is_invalid);
}

test "Control Flow: Stack operations validation" {
    const allocator = testing.allocator;
    defer Contract.clear_analysis_cache(allocator);

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    var code = [_]u8{0} ** 8;
    code[0] = 0x58; // PC
    code[1] = 0x58; // PC
    code[2] = 0x60; // PUSH1
    code[3] = 0x06; // 6 (data for PUSH1)
    code[4] = 0x56; // JUMP
    code[5] = 0x58; // PC
    code[6] = 0x5B; // JUMPDEST
    code[7] = 0x58; // PC

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test the individual operations
    // Execute PC at position 0 → should push 0
    frame.pc = 0;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x58);
    const val0 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), val0);
    try frame.stack.append(val0); // Put it back

    // Execute PC at position 1 → should push 1
    frame.pc = 1;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x58);
    const val1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), val1);
    try frame.stack.append(val1); // Put it back

    // Execute PUSH1 6 → should push 6
    frame.pc = 2;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60);
    const val6 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 6), val6);
    try frame.stack.append(val6); // Put it back

    // Verify final stack state before JUMP
    // Stack should be [0, 1, 6] (bottom to top)
    const top = try frame.stack.pop(); // Should be 6
    try testing.expectEqual(@as(u256, 6), top);

    const middle = try frame.stack.pop(); // Should be 1
    try testing.expectEqual(@as(u256, 1), middle);

    const bottom = try frame.stack.pop(); // Should be 0
    try testing.expectEqual(@as(u256, 0), bottom);
}

test "Control Flow: Program counter tracking" {
    const allocator = testing.allocator;
    defer Contract.clear_analysis_cache(allocator); // Clean up cache after test

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    var code = [_]u8{0} ** 8;
    code[0] = 0x58; // PC (should push 0)
    code[1] = 0x58; // PC (should push 1)
    code[2] = 0x60; // PUSH1
    code[3] = 0x06; // 6 (jump to position 6)
    code[4] = 0x56; // JUMP
    code[5] = 0x58; // PC (should not execute)
    code[6] = 0x5B; // JUMPDEST at position 6
    code[7] = 0x58; // PC (should push 6)

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Analyze jumpdests in the contract

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Execute PC at position 0
    frame.pc = 0;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x58);

    // Execute PC at position 1
    frame.pc = 1;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x58);

    // Execute PUSH1 6
    frame.pc = 2;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60);

    // Execute JUMP
    frame.pc = 4;
    _ = try evm.table.execute(0, interpreter, state, 0x56);
    try testing.expectEqual(@as(usize, 6), frame.pc);

    // Execute PC at position 6
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x58);

    // Verify stack contains correct PC values
    // Expected stack from bottom to top: PC(0), PC(1), PC(6)
    // Note: The PUSH1 6 value was consumed by the JUMP instruction
    const pc_at_6 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 6), pc_at_6);

    const pc_at_1 = try frame.stack.pop(); // PC at position 1
    try testing.expectEqual(@as(u256, 1), pc_at_1);

    const pc_at_0 = try frame.stack.pop(); // PC at position 0
    try testing.expectEqual(@as(u256, 0), pc_at_0);
}

// ============================
// Error handling and edge cases
// ============================

test "Control Flow: Out of gas scenarios" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{0x5B}; // JUMPDEST

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const test_cases = [_]struct {
        opcode: u8,
        min_gas: u64,
        setup: ?*const fn (*Frame) anyerror!void,
    }{
        .{ .opcode = 0x56, .min_gas = 8, .setup = &setup_jump },
        .{ .opcode = 0x57, .min_gas = 10, .setup = &setup_jumpi },
        .{ .opcode = 0x58, .min_gas = 2, .setup = null },
        .{ .opcode = 0x5A, .min_gas = 2, .setup = null },
        .{ .opcode = 0x5B, .min_gas = 1, .setup = null },
    };

    for (test_cases) |case| {
        // Test with insufficient gas
        var test_frame_builder = Frame.builder(allocator);
        var test_frame = try test_frame_builder
            .withVm(&evm)
            .withContract(&contract)
            .withGas(case.min_gas - 1)
            .build();
        defer test_frame.deinit();

        if (case.setup) |setup_fn| {
            try setup_fn(&test_frame);
        }

        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &test_frame;
        const result = evm.table.execute(0, interpreter, state, case.opcode);
        try testing.expectError(ExecutionError.Error.OutOfGas, result);
    }
}

test "Control Flow: Stack operations edge cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    const bytecode = [_]u8{0x5B}; // JUMPDEST
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &bytecode,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Analyze jumpdests in the contract

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test PC and GAS push exactly one value
    const stack_ops = [_]u8{ 0x58, 0x5A }; // PC, GAS

    for (stack_ops) |opcode| {
        frame.stack.clear();
        const initial_size = frame.stack.size;

        _ = try evm.table.execute(0, interpreter, state, opcode);

        // Should push exactly one value
        try testing.expectEqual(initial_size + 1, frame.stack.size);
        _ = try frame.stack.pop(); // Clean up
    }

    // Test JUMP and JUMPI consume correct number of stack items
    frame.stack.clear();
    try frame.stack.append(0); // Only one value for JUMP
    _ = try evm.table.execute(0, interpreter, state, 0x56); // JUMP
    try testing.expectEqual(@as(usize, 0), frame.stack.size);

    frame.stack.clear();
    try frame.stack.append(0); // condition=0
    try frame.stack.append(0); // dest=0
    _ = try evm.table.execute(0, interpreter, state, 0x57); // JUMPI
    try testing.expectEqual(@as(usize, 0), frame.stack.size);

    // Test JUMPDEST doesn't affect stack
    frame.stack.clear();
    try frame.stack.append(42);
    _ = try evm.table.execute(0, interpreter, state, 0x5B); // JUMPDEST
    try testing.expectEqual(@as(usize, 1), frame.stack.size);
    const val = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 42), val);
}
