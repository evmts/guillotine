const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const CallParams = evm.Host.CallParams;
const CallResult = evm.CallResult;
// Updated to new API - migration in progress, tests not run yet

// Integration tests for arithmetic operations combined with control flow

test "Integration: Arithmetic with conditional jumps" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.evm.init(allocator, db_interface, null, null, null, null);
    defer vm.deinit();

    // Create a simple contract that:
    // 1. Adds two numbers
    // 2. Compares result with a threshold
    // 3. Jumps based on comparison
    var code = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0a, // PUSH1 10
        0x01, // ADD
        0x60, 0x0c, // PUSH1 12 (threshold)
        0x11, // GT (result > threshold)
        0x60, 0x0c, // PUSH1 12 (jump destination)
        0x57, // JUMPI
        0x60, 0x00, // PUSH1 0
        0x00, // STOP
        0x5b, // JUMPDEST (at position 12)
        0x60, 0x01, // PUSH1 1
        0x00, // STOP
    };

    // Create test addresses
    const contract_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000001);
    const owner_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000002);

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

    // Execute sequence: PUSH 5, PUSH 10, ADD
    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    _ = try vm.table.execute(0, interpreter, state, 0x60);
    frame.pc += 2; // Advance past PUSH1 data

    _ = try vm.table.execute(0, interpreter, state, 0x60);
    frame.pc += 2; // Advance past PUSH1 data

    _ = try vm.table.execute(0, interpreter, state, 0x01);

    // Stack should have 15
    const stack_top = try frame.stack.peek(0);
    try testing.expectEqual(@as(u256, 15), stack_top);

    // Continue: PUSH 12, GT
    frame.pc += 1;
    _ = try vm.table.execute(0, interpreter, state, 0x60);
    frame.pc += 2;

    _ = try vm.table.execute(0, interpreter, state, 0x11);

    // 15 > 12 should be 1
    const gt_result = try frame.stack.peek(0);
    try testing.expectEqual(@as(u256, 1), gt_result);

    // Continue: PUSH 12, JUMPI
    frame.pc += 1;
    _ = try vm.table.execute(0, interpreter, state, 0x60);
    frame.pc += 2;

    _ = try vm.table.execute(0, interpreter, state, 0x57);

    // Should have jumped to position 12
    try testing.expectEqual(@as(usize, 12), frame.pc);
}

test "Integration: Complex arithmetic expression evaluation" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.evm.init(allocator, db_interface, null, null, null, null);
    defer vm.deinit();

    // Create test addresses
    const contract_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000001);
    const owner_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000002);

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

    // Calculate: ((10 + 5) * 3) - 7
    // Expected: ((15) * 3) - 7 = 45 - 7 = 38

    // Push values and execute
    try frame.stack.push(10);
    try frame.stack.push(5);

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    _ = try vm.table.execute(0, interpreter, state, 0x01);

    try frame.stack.push(3);
    _ = try vm.table.execute(0, interpreter, state, 0x02);

    try frame.stack.push(7);
    _ = try vm.table.execute(0, interpreter, state, 0x03);

    const result = try frame.stack.peek(0);
    try testing.expectEqual(@as(u256, 38), result);
}

test "Integration: Modular arithmetic chain" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.evm.init(allocator, db_interface, null, null, null, null);
    defer vm.deinit();

    // Create test addresses
    const contract_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000001);
    const owner_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000002);

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

    // Test ADDMOD followed by MULMOD
    // (10 + 15) % 7 = 25 % 7 = 4
    // (4 * 3) % 5 = 12 % 5 = 2

    try frame.stack.push(10);
    try frame.stack.push(15);
    try frame.stack.push(7);

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    _ = try vm.table.execute(0, interpreter, state, 0x08);
    const addmod_result = try frame.stack.peek(0);
    try testing.expectEqual(@as(u256, 4), addmod_result);

    try frame.stack.push(3);
    try frame.stack.push(5);
    _ = try vm.table.execute(0, interpreter, state, 0x09);
    const mulmod_result = try frame.stack.peek(0);
    try testing.expectEqual(@as(u256, 2), mulmod_result);
}

test "Integration: Division by zero handling in expression" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.evm.init(allocator, db_interface, null, null, null, null);
    defer vm.deinit();

    // Create test addresses
    const contract_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000001);
    const owner_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000002);

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

    // Test: 10 / 0 = 0, then 0 + 5 = 5
    try frame.stack.push(10);
    try frame.stack.push(0);

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    _ = try vm.table.execute(0, interpreter, state, 0x04);
    const div_result = try frame.stack.peek(0);
    try testing.expectEqual(@as(u256, 0), div_result); // Division by zero returns 0

    try frame.stack.push(5);
    _ = try vm.table.execute(0, interpreter, state, 0x01);
    const add_result = try frame.stack.peek(0);
    try testing.expectEqual(@as(u256, 5), add_result);
}

test "Integration: Bitwise operations with arithmetic" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.evm.init(allocator, db_interface, null, null, null, null);
    defer vm.deinit();

    // Create test addresses
    const contract_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000001);
    const owner_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000002);

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

    // Test: ((0xFF AND 0x0F) << 4) + 10
    // Expected: ((0x0F) << 4) + 10 = 0xF0 + 10 = 240 + 10 = 250

    try frame.stack.push(0xFF);
    try frame.stack.push(0x0F);

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    _ = try vm.table.execute(0, interpreter, state, 0x16);
    const and_result = try frame.stack.peek(0);
    try testing.expectEqual(@as(u256, 0x0F), and_result);

    try frame.stack.push(4);
    _ = try vm.table.execute(0, interpreter, state, 0x1B);
    const shl_result = try frame.stack.peek(0);
    try testing.expectEqual(@as(u256, 0xF0), shl_result);

    try frame.stack.push(10);
    _ = try vm.table.execute(0, interpreter, state, 0x01);
    const final_result = try frame.stack.peek(0);
    try testing.expectEqual(@as(u256, 250), final_result);
}

test "Integration: Stack manipulation with arithmetic" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.evm.init(allocator, db_interface, null, null, null, null);
    defer vm.deinit();

    // Create test addresses
    const contract_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000001);
    const owner_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000002);

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

    // Test DUP and SWAP with arithmetic
    // Stack: [10, 20]
    // DUP1 -> [10, 20, 20]
    // ADD -> [10, 40]
    // SWAP1 -> [40, 10]
    // SUB -> [30]

    try frame.stack.push(10);
    try frame.stack.push(20);

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    _ = try vm.table.execute(0, interpreter, state, 0x80);
    try testing.expectEqual(@as(usize, 3), frame.stack.size());

    _ = try vm.table.execute(0, interpreter, state, 0x01);
    try testing.expectEqual(@as(usize, 2), frame.stack.size());
    const after_add_top = try frame.stack.peek(0);
    const after_add_next = try frame.stack.peek(1);
    try testing.expectEqual(@as(u256, 40), after_add_top);
    try testing.expectEqual(@as(u256, 10), after_add_next);

    _ = try vm.table.execute(0, interpreter, state, 0x90);
    const after_swap_top = try frame.stack.peek(0);
    const after_swap_next = try frame.stack.peek(1);
    try testing.expectEqual(@as(u256, 10), after_swap_top);
    try testing.expectEqual(@as(u256, 40), after_swap_next);

    _ = try vm.table.execute(0, interpreter, state, 0x03);
    const final_result = try frame.stack.peek(0);
    try testing.expectEqual(@as(u256, 30), final_result);
}

test "Integration: Comparison chain for range checking" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.evm.init(allocator, db_interface, null, null, null, null);
    defer vm.deinit();

    // Create test addresses
    const contract_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000001);
    const owner_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000002);

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

    // Check if value is in range [10, 20]
    // value >= 10 AND value <= 20
    const value: u256 = 15;

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    // Check value >= 10
    try frame.stack.push(value);
    try frame.stack.push(10);
    _ = try vm.table.execute(0, interpreter, state, 0x10);
    _ = try vm.table.execute(0, interpreter, state, 0x15);
    const ge_10 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), ge_10); // 15 >= 10 is true

    // Check value <= 20
    try frame.stack.push(20);
    try frame.stack.push(value);
    _ = try vm.table.execute(0, interpreter, state, 0x10);
    _ = try vm.table.execute(0, interpreter, state, 0x15);
    const le_20 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), le_20); // 15 <= 20 is true

    // AND the results
    try frame.stack.push(ge_10);
    try frame.stack.push(le_20);
    _ = try vm.table.execute(0, interpreter, state, 0x16);
    const final_result = try frame.stack.peek(0);
    try testing.expectEqual(@as(u256, 1), final_result); // In range
}

test "Integration: EXP with modular arithmetic" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.evm.init(allocator, db_interface, null, null, null, null);
    defer vm.deinit();

    // Create test addresses
    const contract_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000001);
    const owner_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000002);

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

    // Calculate (2^8) % 100 = 256 % 100 = 56
    try frame.stack.push(2);
    try frame.stack.push(8);

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    _ = try vm.table.execute(0, interpreter, state, 0x0A);
    const exp_result = try frame.stack.peek(0);
    try testing.expectEqual(@as(u256, 256), exp_result);

    try frame.stack.push(100);
    _ = try vm.table.execute(0, interpreter, state, 0x06);
    const mod_result = try frame.stack.peek(0);
    try testing.expectEqual(@as(u256, 56), mod_result);
}

test "Integration: Signed arithmetic with comparisons" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.evm.init(allocator, db_interface, null, null, null, null);
    defer vm.deinit();

    // Create test addresses
    const contract_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000001);
    const owner_address = primitives.Address.from_u256(0x0000000000000000000000000000000000000002);

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

    // Test signed operations
    // -5 (two's complement) compared with 10
    const neg_5 = std.math.maxInt(u256) - 4; // Two's complement of -5

    try frame.stack.push(neg_5);
    try frame.stack.push(10);

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    _ = try vm.table.execute(0, interpreter, state, 0x12);
    const slt_result = try frame.stack.peek(0);
    try testing.expectEqual(@as(u256, 1), slt_result); // -5 < 10 is true

    // SDIV: -10 / 3 = -3 (rounds toward zero)
    frame.stack.clear();
    const neg_10 = std.math.maxInt(u256) - 9; // Two's complement of -10
    try frame.stack.push(neg_10);
    try frame.stack.push(3);
    _ = try vm.table.execute(0, interpreter, state, 0x05);

    const result = try frame.stack.pop();
    const expected_neg_3 = std.math.maxInt(u256) - 2; // Two's complement of -3
    try testing.expectEqual(expected_neg_3, result);
}
