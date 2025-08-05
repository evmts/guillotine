const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const MemoryDatabase = Evm.MemoryDatabase;
const ExecutionError = Evm.ExecutionError;
const Context = Evm.Context;

test "Arithmetic: ADD basic operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm_builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try evm_builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
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

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, primitives.Address.ZERO, &.{}, context);
    defer frame.deinit();

    // Test 1: Simple addition
    try frame.stack_push(5);
    try frame.stack_push(10);
    _ = try evm.table.execute(&evm, &frame, 0x01);
    const result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 15), result);
    try testing.expectEqual(@as(usize, 0), frame.stack_size);

    // Test 2: Addition with overflow
    frame.stack_clear();
    const max_u256 = std.math.maxInt(u256);
    try frame.stack_push(max_u256);
    try frame.stack_push(1);
    _ = try evm.table.execute(&evm, &frame, 0x01);
    const overflow_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0), overflow_result); // Should wrap around

    // Test 3: Adding zero
    frame.stack_clear();
    try frame.stack_push(0);
    try frame.stack_push(42);
    _ = try evm.table.execute(&evm, &frame, 0x01);
    const zero_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 42), zero_result);

    // Test gas consumption
    frame.stack_clear();
    frame.gas_remaining = 1000;
    try frame.stack_push(5);
    try frame.stack_push(10);
    _ = try evm.table.execute(&evm, &frame, 0x01);
    const gas_used = 1000 - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 3), gas_used); // ADD costs GasFastestStep = 3
}

test "Arithmetic: SUB basic operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm_builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try evm_builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
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

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, primitives.Address.ZERO, &.{}, context);
    defer frame.deinit();

    // Test 1: Simple subtraction
    try frame.stack_push(58);
    try frame.stack_push(100);
    _ = try evm.table.execute(&evm, &frame, 0x03);
    const result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 42), result); // 100 - 58 = 42

    // Test 2: Subtraction with underflow
    frame.stack_clear();
    try frame.stack_push(10);
    try frame.stack_push(5);
    _ = try evm.table.execute(&evm, &frame, 0x03);
    const underflow_result = try frame.stack_pop();
    const expected = std.math.maxInt(u256) - 4; // 5 - 10 wraps to max - 4
    try testing.expectEqual(expected, underflow_result);

    // Test 3: Subtracting from zero - SUB calculates top - second
    frame.stack_clear();
    try frame.stack_push(0);
    try frame.stack_push(42);
    _ = try evm.table.execute(&evm, &frame, 0x03);
    const zero_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 42), zero_result); // 42 - 0 = 42
}

test "Arithmetic: MUL basic operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm_builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try evm_builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
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

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, primitives.Address.ZERO, &.{}, context);
    defer frame.deinit();

    // Test 1: Simple multiplication
    try frame.stack_push(7);
    try frame.stack_push(6);
    _ = try evm.table.execute(&evm, &frame, 0x02);
    const result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 42), result);

    // Test 2: Multiplication by zero
    frame.stack_clear();
    try frame.stack_push(0);
    try frame.stack_push(42);
    _ = try evm.table.execute(&evm, &frame, 0x02);
    const zero_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0), zero_result);

    // Test 3: Multiplication overflow
    frame.stack_clear();
    const large_val = @as(u256, 1) << 200;
    try frame.stack_push(large_val);
    try frame.stack_push(large_val);
    _ = try evm.table.execute(&evm, &frame, 0x02);
    const overflow_result = try frame.stack_pop();
    // Result should be truncated to 256 bits
    const expected = (large_val *% large_val) & std.math.maxInt(u256);
    try testing.expectEqual(expected, overflow_result);
}

test "Arithmetic: DIV basic operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm_builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try evm_builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
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

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, primitives.Address.ZERO, &.{}, context);
    defer frame.deinit();

    // Test 1: Simple division - DIV pops dividend first, then divisor
    // To compute 42 / 6, we need divisor (6) on bottom, dividend (42) on top
    try frame.stack_push(6);  // divisor (bottom)
    try frame.stack_push(42); // dividend (top)
    _ = try evm.table.execute(&evm, &frame, 0x04);
    const result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 7), result); // 42 / 6 = 7

    // Test 2: Division by zero - DIV pops dividend first, then divisor
    frame.stack_clear();
    try frame.stack_push(0);  // divisor (bottom)
    try frame.stack_push(42); // dividend (top)
    _ = try evm.table.execute(&evm, &frame, 0x04);
    const zero_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0), zero_result); // Division by zero returns 0

    // Test 3: Division with remainder - DIV pops dividend first, then divisor
    frame.stack_clear();
    try frame.stack_push(7);  // divisor (bottom)
    try frame.stack_push(50); // dividend (top)
    _ = try evm.table.execute(&evm, &frame, 0x04);
    const remainder_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 7), remainder_result); // 50 / 7 = 7 (integer division)
}

test "Arithmetic: MOD basic operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm_builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try evm_builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
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

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, primitives.Address.ZERO, &.{}, context);
    defer frame.deinit();

    // Test 1: Simple modulo - MOD pops dividend first, then divisor
    // To compute 50 % 7, we need divisor (7) on bottom, dividend (50) on top
    try frame.stack_push(7);  // divisor (bottom)
    try frame.stack_push(50); // dividend (top)
    _ = try evm.table.execute(&evm, &frame, 0x06);
    const result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 1), result); // 50 % 7 = 1

    // Test 2: Modulo by zero - MOD pops dividend first, then divisor
    frame.stack_clear();
    try frame.stack_push(0);  // divisor (bottom)
    try frame.stack_push(42); // dividend (top)
    _ = try evm.table.execute(&evm, &frame, 0x06);
    const zero_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0), zero_result); // Modulo by zero returns 0

    // Test 3: Perfect division - MOD pops dividend first, then divisor
    frame.stack_clear();
    try frame.stack_push(6);  // divisor (bottom)
    try frame.stack_push(42); // dividend (top)
    _ = try evm.table.execute(&evm, &frame, 0x06);
    const perfect_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0), perfect_result); // 42 % 6 = 0
}

test "Arithmetic: ADDMOD complex operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm_builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try evm_builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
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

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, primitives.Address.ZERO, &.{}, context);
    defer frame.deinit();

    // Test 1: Simple addmod
    try frame.stack_push(5);  // bottom (will be modulus after pops)
    try frame.stack_push(7);  // middle 
    try frame.stack_push(10); // top (will be first addend)
    _ = try evm.table.execute(&evm, &frame, 0x08);
    const result = try frame.stack_pop();
    // ADDMOD pops a=10, b=7, peeks n=5: (10 + 7) % 5 = 17 % 5 = 2
    try testing.expectEqual(@as(u256, 2), result);

    // Test 2: Addmod with overflow
    frame.stack_clear();
    const max = std.math.maxInt(u256);
    try frame.stack_push(50);
    try frame.stack_push(max);
    try frame.stack_push(100);
    _ = try evm.table.execute(&evm, &frame, 0x08);
    const overflow_result = try frame.stack_pop();
    try testing.expect(overflow_result < 100); // Result should be less than modulus

    // Test 3: Modulo by zero
    frame.stack_clear();
    try frame.stack_push(0);  // n (modulus) - bottom
    try frame.stack_push(5);  // b (second addend) - middle
    try frame.stack_push(7);  // a (first addend) - top
    _ = try evm.table.execute(&evm, &frame, 0x08);
    const zero_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0), zero_result); // Modulo by zero returns 0
}

test "Arithmetic: MULMOD complex operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm_builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try evm_builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
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

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, primitives.Address.ZERO, &.{}, context);
    defer frame.deinit();

    // Test 1: Simple mulmod
    try frame.stack_push(10); // bottom (will be modulus after pops)
    try frame.stack_push(7);  // middle
    try frame.stack_push(5);  // top (will be first multiplicand)
    _ = try evm.table.execute(&evm, &frame, 0x09);
    const result = try frame.stack_pop();
    // MULMOD pops a=5, b=7, peeks n=10: (5 * 7) % 10 = 35 % 10 = 5
    try testing.expectEqual(@as(u256, 5), result);

    // Test 2: Mulmod with large numbers
    frame.stack_clear();
    const large = @as(u256, 1) << 200;
    try frame.stack_push(large);
    try frame.stack_push(large);
    try frame.stack_push(1000);
    _ = try evm.table.execute(&evm, &frame, 0x09);
    const large_result = try frame.stack_pop();
    // The result should be correct even though large * large overflows
    try testing.expect(large_result < 1000);

    // Test 3: Modulo by zero
    frame.stack_clear();
    try frame.stack_push(5);
    try frame.stack_push(7);
    try frame.stack_push(0);
    _ = try evm.table.execute(&evm, &frame, 0x09);
    const zero_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0), zero_result); // Modulo by zero returns 0
}

test "Arithmetic: EXP exponential operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm_builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try evm_builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        10000, // More gas for EXP
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 10000, &contract, primitives.Address.ZERO, &.{}, context);
    defer frame.deinit();

    // Test 1: Simple exponentiation - EXP pops base first, then exponent
    // To compute 2^3, we need exponent (3) on bottom, base (2) on top
    try frame.stack_push(3); // exponent (bottom)
    try frame.stack_push(2); // base (top)
    _ = try evm.table.execute(&evm, &frame, 0x0A);
    const result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 8), result); // 2^3 = 8

    // Test 2: Zero exponent - EXP pops base first, then exponent
    frame.stack_clear();
    try frame.stack_push(0);  // exponent (bottom)
    try frame.stack_push(42); // base (top)
    _ = try evm.table.execute(&evm, &frame, 0x0A);
    const zero_exp_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 1), zero_exp_result); // 42^0 = 1

    // Test 3: Zero base - EXP pops base first, then exponent
    frame.stack_clear();
    try frame.stack_push(5); // exponent (bottom)
    try frame.stack_push(0); // base (top)
    _ = try evm.table.execute(&evm, &frame, 0x0A);
    const zero_base_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0), zero_base_result); // 0^5 = 0

    // Test 4: Large exponent (gas consumption) - EXP pops base first, then exponent
    frame.stack_clear();
    frame.gas_remaining = 10000;
    try frame.stack_push(256); // exponent (bottom)
    try frame.stack_push(2);   // base (top)
    _ = try evm.table.execute(&evm, &frame, 0x0A);
    // Gas should be consumed: 10 (base) + 50 * 2 (256 = 0x100 = 2 bytes)
    const expected_gas = 10 + 50 * 2;
    const actual_gas_used = 10000 - frame.gas_remaining;
    try testing.expectEqual(@as(u64, expected_gas), actual_gas_used);
}

test "Arithmetic: Stack underflow errors" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm_builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try evm_builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
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

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, primitives.Address.ZERO, &.{}, context);
    defer frame.deinit();

    // Test ADD with empty stack
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(&evm, &frame, 0x01));

    // Test ADD with only one item
    try frame.stack_push(42);
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(&evm, &frame, 0x01));

    // Test ADDMOD with only two items (needs three)
    frame.stack_clear();
    try frame.stack_push(42);
    try frame.stack_push(7);
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(&evm, &frame, 0x08));
}
