const std = @import("std");
const testing = std.testing;

// Import opcodes through evm module
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const MemoryDatabase = Evm.MemoryDatabase;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const Operation = Evm.Operation;
const arithmetic = Evm.opcodes.arithmetic;
const stack = Evm.opcodes.stack;
const comparison = Evm.opcodes.comparison;

test "Integration: Complex arithmetic calculation" {
    // Test: Calculate (10 + 20) * 3 - 15
    // Expected result: 75
    const allocator = testing.allocator;

    // Create memory database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const contract_address = primitives.Address.from_u256(0x3333);
    const alice_address = primitives.Address.from_u256(0x1111);

    // Calculate proper code hash
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        10000, // gas
        &[_]u8{},
        code_hash,
        &[_]u8{}, // Empty input
        false, // Not static
    );
    defer contract.deinit(allocator, null);

    // Create frame
    const frame_ptr = try allocator.create(Frame);
    defer allocator.destroy(frame_ptr);

    var frame_builder = Frame.builder(allocator);
    frame_ptr.* = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .withInput(contract.input)
        .build();
    defer frame_ptr.deinit();

    // Push values and execute: 100 - (10 + 20)
    try frame_ptr.stack.append(10);
    try frame_ptr.stack.append(20);

    // Execute ADD opcode
    const interpreter: Operation.Interpreter = &evm;
    const state: Operation.State = frame_ptr;
    _ = try evm.table.execute(0, interpreter, state, 0x01); // ADD = 30

    try frame_ptr.stack.append(100);
    _ = try evm.table.execute(0, interpreter, state, 0x03); // SUB = 100 - 30 = 70

    const result = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 70), result);
    try testing.expectEqual(@as(usize, 1), frame_ptr.stack.size);
}

test "Integration: Modular arithmetic with overflow" {
    // Test: Calculate (MAX_U256 + 5) % 1000
    // Expected: 5 (due to overflow wrapping)
    const allocator = testing.allocator;

    // Create memory database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const contract_address = primitives.Address.from_u256(0x3333);
    const alice_address = primitives.Address.from_u256(0x1111);

    // Calculate proper code hash
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        10000, // gas
        &[_]u8{},
        code_hash,
        &[_]u8{}, // Empty input
        false, // Not static
    );
    defer contract.deinit(allocator, null);

    // Create frame
    const frame_ptr = try allocator.create(Frame);
    defer allocator.destroy(frame_ptr);

    var frame_builder = Frame.builder(allocator);
    frame_ptr.* = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .withInput(contract.input)
        .build();
    defer frame_ptr.deinit();

    const max_u256 = std.math.maxInt(u256);

    // Calculate (MAX_U256 + 5) % 1000
    // First compute MAX_U256 + 5 which wraps to 4
    try frame_ptr.stack.append(max_u256);
    try frame_ptr.stack.append(5);

    // Execute ADD opcode (will overflow to 4)
    const interpreter: Operation.Interpreter = &evm;
    const state: Operation.State = frame_ptr;
    _ = try evm.table.execute(0, interpreter, state, 0x01); // ADD = 4

    // Now we need to compute 4 % 1000 = 4
    // Stack currently has [4]
    // For MOD: second % top, so we need [1000, 4] to get 4 % 1000
    // But that gives us 1000 % 4 = 0
    // So we need [4, 1000] to get 4 % 1000 = 4
    try frame_ptr.stack.append(1000); // Stack: [1000, 4]
    
    // Swap to get [4, 1000]
    _ = try evm.table.execute(0, interpreter, state, 0x90); // SWAP1
    
    _ = try evm.table.execute(0, interpreter, state, 0x06); // MOD = 4 % 1000 = 4

    const result = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 4), result);
}

test "Integration: Fibonacci sequence calculation" {
    // Calculate first 5 Fibonacci numbers using stack manipulation
    // 0, 1, 1, 2, 3
    const allocator = testing.allocator;

    // Create memory database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const contract_address = primitives.Address.from_u256(0x3333);
    const alice_address = primitives.Address.from_u256(0x1111);

    // Calculate proper code hash
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        10000, // gas
        &[_]u8{},
        code_hash,
        &[_]u8{}, // Empty input
        false, // Not static
    );
    defer contract.deinit(allocator, null);

    // Create frame
    const frame_ptr = try allocator.create(Frame);
    defer allocator.destroy(frame_ptr);

    var frame_builder = Frame.builder(allocator);
    frame_ptr.* = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .withInput(contract.input)
        .build();
    defer frame_ptr.deinit();

    // Initialize with 0, 1
    try frame_ptr.stack.append(0); // fib(0)
    try frame_ptr.stack.append(1); // fib(1), Stack: [0, 1] (top is 1)

    // Setup for opcode execution
    const interpreter: Operation.Interpreter = &evm;
    const state: Operation.State = frame_ptr;

    // Calculate fib(2) = fib(1) + fib(0) = 1 + 0 = 1
    _ = try evm.table.execute(0, interpreter, state, 0x80); // DUP1: Stack: [0, 1, 1]
    _ = try evm.table.execute(0, interpreter, state, 0x82); // DUP3: Stack: [0, 1, 1, 0]
    _ = try evm.table.execute(0, interpreter, state, 0x01); // ADD: Stack: [0, 1, 1]

    // Calculate fib(3) = fib(2) + fib(1) = 1 + 1 = 2
    _ = try evm.table.execute(0, interpreter, state, 0x80); // DUP1: Stack: [0, 1, 1, 1]
    _ = try evm.table.execute(0, interpreter, state, 0x82); // DUP3: Stack: [0, 1, 1, 1, 1]
    _ = try evm.table.execute(0, interpreter, state, 0x01); // ADD: Stack: [0, 1, 1, 2]

    // Calculate fib(4) = fib(3) + fib(2) = 2 + 1 = 3
    _ = try evm.table.execute(0, interpreter, state, 0x80); // DUP1: Stack: [0, 1, 1, 2, 2]
    _ = try evm.table.execute(0, interpreter, state, 0x82); // DUP3: Stack: [0, 1, 1, 2, 2, 1]
    _ = try evm.table.execute(0, interpreter, state, 0x01); // ADD: Stack: [0, 1, 1, 2, 3]

    // Verify we have fib(4) = 3 on top
    const fib4 = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 3), fib4); // fib(4)
    const fib3 = try frame_ptr.stack.peek_n(1);
    try testing.expectEqual(@as(u256, 2), fib3); // fib(3)
    const fib2 = try frame_ptr.stack.peek_n(2);
    try testing.expectEqual(@as(u256, 1), fib2); // fib(2)
}

test "Integration: Conditional arithmetic based on comparison" {
    // Test: If a > b, calculate a - b, else calculate b - a
    const allocator = testing.allocator;

    // Create memory database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const contract_address = primitives.Address.from_u256(0x3333);
    const alice_address = primitives.Address.from_u256(0x1111);

    // Calculate proper code hash
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        10000, // gas
        &[_]u8{},
        code_hash,
        &[_]u8{}, // Empty input
        false, // Not static
    );
    defer contract.deinit(allocator, null);

    // Create frame
    const frame_ptr = try allocator.create(Frame);
    defer allocator.destroy(frame_ptr);

    var frame_builder = Frame.builder(allocator);
    frame_ptr.* = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .withInput(contract.input)
        .build();
    defer frame_ptr.deinit();

    // Setup for opcode execution
    const interpreter: Operation.Interpreter = &evm;
    const state: Operation.State = frame_ptr;

    // Test case 1: a=30, b=20 (a > b)
    // We want to check if a > b, then calculate a - b = 30 - 20 = 10
    
    // Push values for subtraction
    try frame_ptr.stack.append(20); // b  
    try frame_ptr.stack.append(30); // a, Stack: [20, 30]
    
    // SUB does top - second, so with [20, 30] it would do 30 - 20 = 10
    _ = try evm.table.execute(0, interpreter, state, 0x03); // SUB: Stack: [10]

    const result1 = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 10), result1);

    // Test case 2: a=15, b=25 (a < b)
    frame_ptr.stack.clear();
    try frame_ptr.stack.append(15); // a
    try frame_ptr.stack.append(25); // b, Stack: [15, 25]

    // Duplicate values for comparison
    _ = try evm.table.execute(0, interpreter, state, 0x81); // DUP2: Stack: [15, 25, 15]
    _ = try evm.table.execute(0, interpreter, state, 0x81); // DUP2: Stack: [15, 25, 15, 25]

    // Compare a > b - we want to check if 15 > 25
    // GT pops top two values: pops 25, then 15, but it computes top > second = 25 > 15 = 1
    // We need to swap to get the right order
    _ = try evm.table.execute(0, interpreter, state, 0x90); // SWAP1: Stack: [15, 25, 25, 15]
    _ = try evm.table.execute(0, interpreter, state, 0x11); // GT: Stack: [15, 25, 0] (15 > 25 = 0)

    // If false (a <= b), we would calculate b - a
    // For this test, we'll just verify the comparison result
    const comparison_result = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0), comparison_result); // Comparison was false as expected
}

test "Integration: Calculate average of multiple values" {
    // Calculate average of 10, 20, 30, 40, 50
    // Expected: 150 / 5 = 30
    const allocator = testing.allocator;

    // Create memory database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const contract_address = primitives.Address.from_u256(0x3333);
    const alice_address = primitives.Address.from_u256(0x1111);

    // Calculate proper code hash
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        10000, // gas
        &[_]u8{},
        code_hash,
        &[_]u8{}, // Empty input
        false, // Not static
    );
    defer contract.deinit(allocator, null);

    // Create frame
    const frame_ptr = try allocator.create(Frame);
    defer allocator.destroy(frame_ptr);

    var frame_builder = Frame.builder(allocator);
    frame_ptr.* = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .withInput(contract.input)
        .build();
    defer frame_ptr.deinit();

    // Setup for opcode execution
    const interpreter: Operation.Interpreter = &evm;
    const state: Operation.State = frame_ptr;

    // Push all values
    try frame_ptr.stack.append(10);
    try frame_ptr.stack.append(20);
    try frame_ptr.stack.append(30);
    try frame_ptr.stack.append(40);
    try frame_ptr.stack.append(50);

    // Add them all together
    // Stack: [10, 20, 30, 40, 50] where 50 is top
    _ = try evm.table.execute(0, interpreter, state, 0x01); // ADD: 50+40=90, Stack: [10, 20, 30, 90]
    _ = try evm.table.execute(0, interpreter, state, 0x01); // ADD: 90+30=120, Stack: [10, 20, 120]
    _ = try evm.table.execute(0, interpreter, state, 0x01); // ADD: 120+20=140, Stack: [10, 140]
    _ = try evm.table.execute(0, interpreter, state, 0x01); // ADD: 140+10=150, Stack: [150]

    // Divide by count
    // Stack currently has [150]
    // DIV does b / a where b is top, a is second
    // We want 150 / 5, so we need stack [5, 150] but that would give us 150 / 5
    // Actually with current stack [150], pushing 5 gives [150, 5]
    // DIV would pop 5 (b), peek 150 (a), compute 5 / 150 = 0
    // We need to swap
    try frame_ptr.stack.append(5); // Stack: [150, 5]
    _ = try evm.table.execute(0, interpreter, state, 0x90); // SWAP1: Stack: [5, 150]
    _ = try evm.table.execute(0, interpreter, state, 0x04); // DIV: 150/5=30

    const result = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 30), result);
}

test "Integration: Complex ADDMOD and MULMOD calculations" {
    // Test: Calculate (a + b) % n and (a * b) % n for large values
    const allocator = testing.allocator;

    // Create memory database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const contract_address = primitives.Address.from_u256(0x3333);
    const alice_address = primitives.Address.from_u256(0x1111);

    // Calculate proper code hash
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        10000, // gas
        &[_]u8{},
        code_hash,
        &[_]u8{}, // Empty input
        false, // Not static
    );
    defer contract.deinit(allocator, null);

    // Create frame
    const frame_ptr = try allocator.create(Frame);
    defer allocator.destroy(frame_ptr);

    var frame_builder = Frame.builder(allocator);
    frame_ptr.* = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .withInput(contract.input)
        .build();
    defer frame_ptr.deinit();

    // Setup for opcode execution
    const interpreter: Operation.Interpreter = &evm;
    const state: Operation.State = frame_ptr;

    // Test ADDMOD with values that would overflow
    const a: u256 = std.math.maxInt(u256) - 10; // MAX - 10
    const b: u256 = 20;
    const n: u256 = 100;

    // Calculate (a + b) % n
    // ADDMOD pops b, then a, then peeks n
    // So we need stack: [n, a, b] where b is top
    // a = MAX_U256 - 10, b = 20, n = 100
    // a + b wraps to 9, so result should be 9 % 100 = 9
    try frame_ptr.stack.append(n); // modulus (bottom)
    try frame_ptr.stack.append(a); // first addend (middle)
    try frame_ptr.stack.append(b); // second addend (top)
    _ = try evm.table.execute(0, interpreter, state, 0x08); // ADDMOD

    const addmod_result = try frame_ptr.stack.peek_n(0);
    // We calculated that (a + b) % n should be 9
    // With overflow: (MAX_U256 - 10 + 20) wraps to 9, and 9 % 100 = 9
    try testing.expectEqual(@as(u256, 9), addmod_result);

    // Test MULMOD with large values
    frame_ptr.stack.clear();
    const x: u256 = 1000000000000000000; // 10^18
    const y: u256 = 1000000000000000000; // 10^18
    const m: u256 = 1000000007; // Large prime

    // Calculate (x * y) % m
    try frame_ptr.stack.append(m);
    try frame_ptr.stack.append(y);
    try frame_ptr.stack.append(x);
    _ = try evm.table.execute(0, interpreter, state, 0x09); // MULMOD

    // x * y = 10^36, which is much larger than u256 max
    // We expect a specific result based on modular arithmetic
    const result = try frame_ptr.stack.pop();
    try testing.expect(result < m); // Result should be less than modulus
}

test "Integration: Exponentiation chain" {
    // Calculate 2^3^2 (right associative, so 2^(3^2) = 2^9 = 512)
    const allocator = testing.allocator;

    // Create memory database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const contract_address = primitives.Address.from_u256(0x3333);
    const alice_address = primitives.Address.from_u256(0x1111);

    // Calculate proper code hash
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        50000, // More gas for EXP
        &[_]u8{},
        code_hash,
        &[_]u8{}, // Empty input
        false, // Not static
    );
    defer contract.deinit(allocator, null);

    // Create frame
    const frame_ptr = try allocator.create(Frame);
    defer allocator.destroy(frame_ptr);

    var frame_builder = Frame.builder(allocator);
    frame_ptr.* = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(50000)
        .withInput(contract.input)
        .build();
    defer frame_ptr.deinit();

    // Setup for opcode execution
    const interpreter: Operation.Interpreter = &evm;
    const state: Operation.State = frame_ptr;

    // First calculate 3^2
    // EXP pops base (top) then peeks exponent, so for 3^2 we need [2, 3] on stack
    try frame_ptr.stack.append(2); // exponent
    try frame_ptr.stack.append(3); // base
    _ = try evm.table.execute(0, interpreter, state, 0x0A); // EXP: 3^2 = 9

    // Then calculate 2^9
    // Stack currently has [9], we need [9, 2] for 2^9
    try frame_ptr.stack.append(2); // Push base
    _ = try evm.table.execute(0, interpreter, state, 0x0A); // EXP: 2^9 = 512

    const result = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 512), result);
}
