const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const MemoryDatabase = Evm.MemoryDatabase;
const ExecutionError = Evm.ExecutionError;
// Updated to new API - migration in progress, tests not run yet

// Test PUSH0 operation
test "PUSH0: append zero value" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
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
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Execute PUSH0
    _ = try evm.table.execute(0, interpreter, state, 0x5F);

    // Should append 0
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// Test PUSH1 operation
test "PUSH1: append 1 byte value" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set contract code with PUSH1 0xAB
    const code = [_]u8{ 0x60, 0xAB };

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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Set PC to 0 (at PUSH1 opcode)
    frame.pc = 0;

    // Execute PUSH1
    const result = try evm.table.execute(0, interpreter, state, 0x60);

    // Should consume 2 bytes (opcode + data)
    try testing.expectEqual(@as(usize, 2), result.bytes_consumed);

    // Should append 0xAB
    try testing.expectEqual(@as(u256, 0xAB), try frame.stack.pop());
}

// Test PUSH2 through PUSH32
test "PUSH2: append 2 byte value" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set contract code with PUSH2 0x1234
    const code = [_]u8{ 0x61, 0x12, 0x34 };

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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    frame.pc = 0;

    // Execute PUSH2
    const result = try evm.table.execute(0, interpreter, state, 0x61);

    // Should consume 3 bytes
    try testing.expectEqual(@as(usize, 3), result.bytes_consumed);

    // Should append 0x1234
    try testing.expectEqual(@as(u256, 0x1234), try frame.stack.pop());
}

test "PUSH32: append 32 byte value" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set contract code with PUSH32 followed by 32 bytes
    var code: [33]u8 = undefined;
    code[0] = 0x7f; // PUSH32 opcode
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        code[i + 1] = @intCast(i + 1); // 0x01, 0x02, ..., 0x20
    }

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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    frame.pc = 0;

    // Execute PUSH32
    const result = try evm.table.execute(0, interpreter, state, 0x7F);

    // Should consume 33 bytes
    try testing.expectEqual(@as(usize, 33), result.bytes_consumed);

    // Should append the value (first byte 0x01 in most significant position)
    const value = try frame.stack.pop();
    try testing.expect((value >> 248) == 0x01);
    try testing.expect(((value >> 240) & 0xFF) == 0x02);
    try testing.expect((value & 0xFF) == 0x20);
}

// Test POP operation
test "POP: remove top stack item" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
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
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push some values
    try frame.stack.append(0x123);
    try frame.stack.append(0x456);

    // Execute POP
    _ = try evm.table.execute(0, interpreter, state, 0x50);

    // Should have removed top item (0x456)
    try testing.expectEqual(@as(u256, 0x123), try frame.stack.pop());
    try testing.expectEqual(@as(usize, 0), frame.stack.size);
}

// Test DUP operations
test "DUP1: duplicate top stack item" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
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
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push a value
    try frame.stack.append(0xABCD);

    // Execute DUP1
    _ = try evm.table.execute(0, interpreter, state, 0x80);

    // Should have two copies of the value
    try testing.expectEqual(@as(u256, 0xABCD), try frame.stack.pop());
    try testing.expectEqual(@as(u256, 0xABCD), try frame.stack.pop());
}

test "DUP2: duplicate second stack item" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
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
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push two values
    try frame.stack.append(0x111); // bottom
    try frame.stack.append(0x222); // top

    // Execute DUP2
    _ = try evm.table.execute(0, interpreter, state, 0x81);

    // Stack should be: 0x111, 0x222, 0x111
    try testing.expectEqual(@as(u256, 0x111), try frame.stack.pop());
    try testing.expectEqual(@as(u256, 0x222), try frame.stack.pop());
    try testing.expectEqual(@as(u256, 0x111), try frame.stack.pop());
}

test "DUP16: duplicate 16th stack item" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
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
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push 16 values
    var i: u256 = 1;
    while (i <= 16) : (i += 1) {
        try frame.stack.append(i * 100);
    }

    // Execute DUP16
    _ = try evm.table.execute(0, interpreter, state, 0x8F);

    // Should duplicate the bottom item (100)
    try testing.expectEqual(@as(u256, 100), try frame.stack.pop());

    // Original stack should still be intact
    i = 16;
    while (i >= 1) : (i -= 1) {
        try testing.expectEqual(i * 100, try frame.stack.pop());
    }
}

// Test SWAP operations
test "SWAP1: swap top two stack items" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
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
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push two values
    try frame.stack.append(0x111); // bottom
    try frame.stack.append(0x222); // top

    // Execute SWAP1
    _ = try evm.table.execute(0, interpreter, state, 0x90);

    // Order should be swapped
    try testing.expectEqual(@as(u256, 0x111), try frame.stack.pop());
    try testing.expectEqual(@as(u256, 0x222), try frame.stack.pop());
}

test "SWAP2: swap 1st and 3rd stack items" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
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
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push three values
    try frame.stack.append(0x111); // bottom
    try frame.stack.append(0x222); // middle
    try frame.stack.append(0x333); // top

    // Execute SWAP2
    _ = try evm.table.execute(0, interpreter, state, 0x91);

    // Stack should be: 0x222, 0x111, 0x333
    try testing.expectEqual(@as(u256, 0x111), try frame.stack.pop());
    try testing.expectEqual(@as(u256, 0x222), try frame.stack.pop());
    try testing.expectEqual(@as(u256, 0x333), try frame.stack.pop());
}

test "SWAP16: swap 1st and 17th stack items" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
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
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push 17 values
    var i: u256 = 1;
    while (i <= 17) : (i += 1) {
        try frame.stack.append(i);
    }

    // Execute SWAP16
    _ = try evm.table.execute(0, interpreter, state, 0x9F);

    // Top should now be 1, bottom should be 17
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    // Pop middle values
    i = 16;
    while (i >= 2) : (i -= 1) {
        try testing.expectEqual(i, try frame.stack.pop());
    }

    // Bottom should be 17
    try testing.expectEqual(@as(u256, 17), try frame.stack.pop());
}

// Test edge cases
test "PUSH1: at end of code" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set contract code with PUSH1 but no data byte
    const code = [_]u8{0x60}; // Just PUSH1 opcode

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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    frame.pc = 0;

    // Execute PUSH1
    const result = try evm.table.execute(0, interpreter, state, 0x60);

    // Should consume 2 bytes (even though only 1 exists)
    try testing.expectEqual(@as(usize, 2), result.bytes_consumed);

    // Should append 0 (padding)
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "PUSH32: partial data available" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set contract code with PUSH32 but only 10 data bytes
    var code: [11]u8 = undefined;
    code[0] = 0x7f; // PUSH32 opcode
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        code[i + 1] = 0xFF;
    }

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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    frame.pc = 0;

    // Execute PUSH32
    const result = try evm.table.execute(0, interpreter, state, 0x7F);

    // Should consume 33 bytes
    try testing.expectEqual(@as(usize, 33), result.bytes_consumed);

    // Should append value with padding
    const value = try frame.stack.pop();
    // First 10 bytes should be 0xFF
    var j: usize = 0;
    while (j < 10) : (j += 1) {
        try testing.expectEqual(@as(u8, 0xFF), @as(u8, @intCast((value >> @intCast(8 * (31 - j))) & 0xFF)));
    }
    // Remaining bytes should be 0
    while (j < 32) : (j += 1) {
        try testing.expectEqual(@as(u8, 0), @as(u8, @intCast((value >> @intCast(8 * (31 - j))) & 0xFF)));
    }
}

// Test stack errors
test "POP: stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
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
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Empty stack

    // Execute POP - should fail
    const result = evm.table.execute(0, interpreter, state, 0x50);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "DUP1: stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
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
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Empty stack

    // Execute DUP1 - should fail
    const result = evm.table.execute(0, interpreter, state, 0x80);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "DUP16: insufficient stack items" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
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
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push only 15 values (need 16)
    var i: u256 = 0;
    while (i < 15) : (i += 1) {
        try frame.stack.append(i);
    }

    // Execute DUP16 - should fail
    const result = evm.table.execute(0, interpreter, state, 0x8F);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "SWAP1: stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
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
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push only one value (need two)
    try frame.stack.append(0x123);

    // Execute SWAP1 - should fail
    const result = evm.table.execute(0, interpreter, state, 0x90);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "PUSH1: stack overflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set contract code
    const code = [_]u8{ 0x60, 0x01 };

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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Fill stack to maximum (1024 items)
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        try frame.stack.append(i);
    }

    frame.pc = 0;

    // Execute PUSH1 - should fail with stack overflow
    const result = evm.table.execute(0, interpreter, state, 0x60);
    try testing.expectError(ExecutionError.Error.StackOverflow, result);
}

test "DUP1: stack overflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
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
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Fill stack to maximum (1024 items)
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        try frame.stack.append(i);
    }

    // Execute DUP1 - should fail with stack overflow
    const result = evm.table.execute(0, interpreter, state, 0x80);
    try testing.expectError(ExecutionError.Error.StackOverflow, result);
}
