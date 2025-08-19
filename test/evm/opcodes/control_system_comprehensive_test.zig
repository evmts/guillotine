const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const CallParams = Evm.Host.CallParams;
const CallResult = Evm.CallResult;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const MemoryDatabase = Evm.MemoryDatabase;
const ExecutionError = Evm.ExecutionError;
// Updated to new API - migration in progress, tests not run yet

// ============================
// 0xF3: RETURN opcode
// ============================

test "RETURN (0xF3): Return data from execution" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{
        0x60, 0x20, // PUSH1 0x20 (size = 32 bytes)
        0x60, 0x00, // PUSH1 0x00 (offset = 0)
        0xF3, // RETURN
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
        .withGas(1000)
        .build();
    defer frame.deinit(allocator);

    // Write data to memory
    const return_data = "Hello from RETURN!" ++ ([_]u8{0} ** 14);
    _ = try frame.memory.set_data(0, return_data[0..]);

    // Execute push operations
    frame.pc = 0;
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60);
    frame.pc = 2;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60);
    frame.pc = 4;

    // Execute RETURN
    const result = evm.table.execute(0, interpreter, state, 0xF3);

    // RETURN should trigger STOP error with return data
    try testing.expectError(ExecutionError.Error.STOP, result);

    // Check output was set
    try testing.expectEqualSlices(u8, return_data[0..], frame.output);
}

test "RETURN: Empty return data" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{
        0x60, 0x00, // PUSH1 0x00 (size = 0)
        0x60, 0x00, // PUSH1 0x00 (offset = 0)
        0xF3, // RETURN
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
        .withGas(1000)
        .build();
    defer frame.deinit(allocator);

    // Execute push operations
    frame.pc = 0;
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60);
    frame.pc = 2;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60);
    frame.pc = 4;

    // Execute RETURN
    const result = evm.table.execute(0, interpreter, state, 0xF3);
    try testing.expectError(ExecutionError.Error.STOP, result);

    // Check empty output
    try testing.expectEqual(@as(usize, 0), frame.output.len);
}

// ============================
// 0xFD: REVERT opcode
// ============================

test "REVERT (0xFD): Revert with data" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{
        0x60, 0x10, // PUSH1 0x10 (size = 16 bytes)
        0x60, 0x00, // PUSH1 0x00 (offset = 0)
        0xFD, // REVERT
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
        .withGas(1000)
        .build();
    defer frame.deinit(allocator);

    // Write revert reason to memory
    const revert_data = "Revert reason!" ++ ([_]u8{0} ** 2);
    _ = try frame.memory.set_data(0, revert_data[0..]);

    // Execute push operations
    frame.pc = 0;
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60);
    frame.pc = 2;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60);
    frame.pc = 4;

    // Execute REVERT
    const result = evm.table.execute(0, interpreter, state, 0xFD);

    // REVERT should trigger REVERT error
    try testing.expectError(ExecutionError.Error.REVERT, result);

    // Check revert data was set in output
    try testing.expectEqualSlices(u8, revert_data[0..], frame.output);
}

test "REVERT: Empty revert data" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{
        0x60, 0x00, // PUSH1 0x00 (offset = 0)
        0x60, 0x00, // PUSH1 0x00 (size = 0)
        0xFD, // REVERT
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
        .withGas(1000)
        .build();
    defer frame.deinit(allocator);

    // Execute instructions
    for (0..2) |_| {
        frame.pc = i * 2;
        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &frame;
        _ = try evm.table.execute(frame.pc, interpreter, state, 0x60);
    }
    frame.pc = 4;

    // Execute REVERT
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    const result = evm.table.execute(0, interpreter, state, 0xFD);
    try testing.expectError(ExecutionError.Error.REVERT, result);

    // Check empty revert data in output
    try testing.expectEqual(@as(usize, 0), frame.output.len);
}

// ============================
// 0xFE: INVALID opcode
// ============================

test "INVALID (0xFE): Consume all gas and fail" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{0xFE}; // INVALID

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

    const gas_before = frame.gas_remaining;

    // Execute INVALID
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    const result = evm.table.execute(0, interpreter, state, 0xFE);

    // Should return InvalidOpcode error
    try testing.expectError(ExecutionError.Error.InvalidOpcode, result);

    // Should consume all gas
    try testing.expectEqual(@as(u64, 0), frame.gas_remaining);
    try testing.expect(gas_before > 0); // Had gas before
}

// ============================
// 0xFF: SELFDESTRUCT opcode
// ============================

test "SELFDESTRUCT (0xFF): Schedule contract destruction" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{
        0x73, // PUSH20 (beneficiary address)
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0x11,
        0xFF, // SELFDESTRUCT
    };

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        1000, // Give contract some balance
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

    // Execute PUSH20
    frame.pc = 0;
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0x73);
    frame.pc = 21;

    // Execute SELFDESTRUCT
    const result = evm.table.execute(0, interpreter, state, 0xFF);

    // SELFDESTRUCT returns STOP
    try testing.expectError(ExecutionError.Error.STOP, result);
}

test "SELFDESTRUCT: Static call protection" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{0xFF}; // SELFDESTRUCT

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

    // Set static mode
    frame.is_static = true;

    // Push beneficiary address
    const bob_addr = [_]u8{0x11} ** 20;
    try frame.stack.append(primitives.Address.to_u256(bob_addr));

    // Execute SELFDESTRUCT
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    const result = evm.table.execute(0, interpreter, state, 0xFF);
    try testing.expectError(ExecutionError.Error.WriteProtection, result);
}

test "SELFDESTRUCT: Cold beneficiary address (EIP-2929)" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{0xFF}; // SELFDESTRUCT

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

    // Ensure beneficiary is cold
    evm.access_list.clear();

    // Push cold beneficiary address
    const cold_address = [_]u8{0xDD} ** 20;
    try frame.stack.append(primitives.Address.to_u256(cold_address));

    const gas_before = frame.gas_remaining;
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    const result = evm.table.execute(0, interpreter, state, 0xFF);
    try testing.expectError(ExecutionError.Error.STOP, result);

    // Check that cold address access cost was consumed
    const gas_used = gas_before - frame.gas_remaining;
    // Base SELFDESTRUCT (5000) + cold access (2600) = 7600
    try testing.expect(gas_used >= 7600);
}

// ============================
// Gas consumption tests
// ============================

test "Control opcodes: Gas consumption" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    // Test RETURN gas consumption (memory expansion)
    const return_code = [_]u8{0xF3}; // RETURN

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &return_code,
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

    // Return large data requiring memory expansion
    try frame.stack.append(0x1000); // size (4096 bytes)
    try frame.stack.append(0); // offset

    const gas_before = frame.gas_remaining;
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    const result = evm.table.execute(0, interpreter, state, 0xF3);
    try testing.expectError(ExecutionError.Error.STOP, result);

    const gas_used = gas_before - frame.gas_remaining;
    // Should include memory expansion cost
    try testing.expect(gas_used > 400); // Significant gas for memory
}

// ============================
// Edge cases
// ============================

test "RETURN/REVERT: Large memory offset" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const opcodes = [_]u8{ 0xF3, 0xFD }; // RETURN, REVERT

    for (opcodes) |opcode| {
        const caller = [_]u8{0x11} ** 20;
        const contract_addr = [_]u8{0x11} ** 20;
        var contract = Contract.init(
            caller,
            contract_addr,
            0,
            1000,
            &[_]u8{opcode},
            [_]u8{0} ** 32,
            &[_]u8{},
            false,
        );
        defer contract.deinit(allocator, null);

        var frame_builder = Frame.builder(allocator);
        var test_frame = try frame_builder
            .withVm(&evm)
            .withContract(&contract)
            .withGas(10000)
            .build();
        defer test_frame.deinit(allocator);

        // Push large offset
        try test_frame.stack.append(0x1000); // offset = 4096
        try test_frame.stack.append(32); // size = 32

        const gas_before = test_frame.gas_remaining;
        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &test_frame;
        const result = evm.table.execute(0, interpreter, state, opcode);

        if (opcode == 0xF3) {
            try testing.expectError(ExecutionError.Error.STOP, result);
        } else {
            try testing.expectError(ExecutionError.Error.REVERT, result);
        }

        // Check memory expansion gas was consumed
        const gas_used = gas_before - test_frame.gas_remaining;
        try testing.expect(gas_used > 400);
    }
}

test "RETURN/REVERT: Stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const opcodes = [_]u8{ 0xF3, 0xFD }; // RETURN, REVERT

    for (opcodes) |opcode| {
        const caller = [_]u8{0x11} ** 20;
        const contract_addr = [_]u8{0x11} ** 20;
        var contract = Contract.init(
            caller,
            contract_addr,
            0,
            1000,
            &[_]u8{opcode},
            [_]u8{0} ** 32,
            &[_]u8{},
            false,
        );
        defer contract.deinit(allocator, null);

        var frame_builder = Frame.builder(allocator);
        var test_frame = try frame_builder
            .withVm(&evm)
            .withContract(&contract)
            .withGas(1000)
            .build();
        defer test_frame.deinit(allocator);

        // Empty stack
        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &test_frame;
        const result = evm.table.execute(0, interpreter, state, opcode);
        try testing.expectError(ExecutionError.Error.StackUnderflow, result);

        // Only one item on stack (need 2)
        try test_frame.stack.append(0);
        const result2 = evm.table.execute(0, interpreter, state, opcode);
        try testing.expectError(ExecutionError.Error.StackUnderflow, result2);
    }
}

test "Control flow interaction: Call with REVERT" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{0xF1}; // CALL

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
    defer frame.deinit(allocator);

    // Push CALL parameters in reverse order (stack is LIFO)
    // EVM pops: gas, to, value, args_offset, args_size, ret_offset, ret_size
    // So push: ret_size, ret_offset, args_size, args_offset, value, to, gas
    try frame.stack.append(32); // ret_size
    try frame.stack.append(0); // ret_offset
    try frame.stack.append(0); // args_size
    try frame.stack.append(0); // args_offset
    try frame.stack.append(0); // value
    const bob_addr = [_]u8{0x11} ** 20;
    try frame.stack.append(primitives.Address.to_u256(bob_addr)); // to
    try frame.stack.append(2000); // gas

    // Execute the CALL (VM handles the actual call)
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0xF1);

    // Check success status pushed to stack
    const success = try frame.stack.pop();

    // Calling an empty address should succeed per EVM specification
    try testing.expectEqual(@as(u256, 1), success);

    // Note: This test verifies CALL behavior when calling an empty address.
    // Per EVM specification, calling an address with no code should succeed,
    // transferring any value and returning success (1).
    // The test has been updated to expect the correct behavior.
}
