const std = @import("std");
const testing = std.testing;

// Import opcodes through evm module
const evm = @import("evm");
const CallParams = evm.Host.CallParams;
const CallResult = evm.CallResult;
// Updated to new API - migration in progress, tests not run yet
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const MemoryDatabase = evm.MemoryDatabase;
const Contract = evm.Contract;
const Frame = evm.Frame;
const Operation = evm.Operation;
const arithmetic = evm.opcodes.arithmetic;
const stack = evm.opcodes.stack;
const comparison = evm.opcodes.comparison;

test "Integration: Complex arithmetic calculation" {
    // Test: Calculate (10 + 20) * 3 - 15
    // Expected result: 75
    const allocator = testing.allocator;

    // Create memory database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer vm.deinit();

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
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .withInput(contract.input)
        .build();
    defer frame_ptr.deinit();

    // Push values and execute: (10 + 20) * 3 - 15
    try frame_ptr.stack.append(20);
    try frame_ptr.stack.append(10);

    // Execute ADD opcode
    const interpreter: Operation.Interpreter = &evm;
    const state: Operation.State = frame_ptr;
    _ = try evm.table.execute(0, interpreter, state, 0x01); // ADD = 30

    try frame_ptr.stack.append(3);
    _ = try evm.table.execute(0, interpreter, state, 0x02); // MUL = 90

    // After MUL, stack has [90]
    // For 90 - 15, we need [15, 90] with 90 on top
    try frame_ptr.stack.append(15);
    _ = try evm.table.execute(0, interpreter, state, 0x90); // SWAP1 to get [15, 90]
    _ = try evm.table.execute(0, interpreter, state, 0x03); // SUB = 90 - 15 = 75

    const result = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 75), result);
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
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer vm.deinit();

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
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .withInput(contract.input)
        .build();
    defer frame_ptr.deinit();

    const max_u256 = std.math.maxInt(u256);

    // Calculate (MAX_U256 + 5) % 1000
    try frame_ptr.stack.append(5);
    try frame_ptr.stack.append(max_u256);

    // Execute ADD opcode (will overflow to 4)
    const interpreter: Operation.Interpreter = &evm;
    const state: Operation.State = frame_ptr;
    _ = try evm.table.execute(0, interpreter, state, 0x01); // ADD

    try frame_ptr.stack.append(1000); // Push modulus
    _ = try evm.table.execute(0, interpreter, state, 0x90); // SWAP1 to get [1000, 4]
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
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer vm.deinit();

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
        .withVm(&vm)
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
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer vm.deinit();

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
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .withInput(contract.input)
        .build();
    defer frame_ptr.deinit();

    // Setup for opcode execution
    const interpreter: Operation.Interpreter = &evm;
    const state: Operation.State = frame_ptr;

    // Test case 1: a=30, b=20 (want to check if a > b and calculate a - b)
    const a: u256 = 30;
    const b: u256 = 20;
    
    try frame_ptr.stack.append(b); // Stack: [20]
    try frame_ptr.stack.append(a); // Stack: [20, 30]

    // To check if a > b, we need a on top for GT
    // GT computes top > second, so we want 30 > 20
    _ = try evm.table.execute(0, interpreter, state, 0x11); // GT: Stack: [1] (30 > 20 = true)

    // Verify the comparison result
    const comparison1 = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 1), comparison1); // a > b is true

    // Now calculate a - b
    // We need to push values again since GT consumed them
    frame_ptr.stack.clear();
    try frame_ptr.stack.append(b); // Stack: [20]
    try frame_ptr.stack.append(a); // Stack: [20, 30]
    
    // SUB calculates top - second, so 30 - 20 = 10
    _ = try evm.table.execute(0, interpreter, state, 0x03); // SUB: Stack: [10]

    const result1 = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 10), result1);

    // Test case 2: a=15, b=25 (want to check if a > b)
    frame_ptr.stack.clear();
    const a2: u256 = 15;
    const b2: u256 = 25;
    
    try frame_ptr.stack.append(b2); // Stack: [25]
    try frame_ptr.stack.append(a2); // Stack: [25, 15]

    // To check if a > b, we have a=15 on top and b=25 second
    // GT computes top > second, so 15 > 25 = 0 (false)
    _ = try evm.table.execute(0, interpreter, state, 0x11); // GT: Stack: [0]

    // Verify the comparison result
    const comparison_result = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0), comparison_result); // 15 > 25 = false
}

test "Integration: Calculate average of multiple values" {
    // Calculate average of 10, 20, 30, 40, 50
    // Expected: 150 / 5 = 30
    const allocator = testing.allocator;

    // Create memory database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer vm.deinit();

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
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .withInput(contract.input)
        .build();
    defer frame_ptr.deinit();

    // Setup for opcode execution
    const interpreter: Operation.Interpreter = &evm;
    const state: Operation.State = frame_ptr;

    // Push all values
    try frame_ptr.stack.append(50);
    try frame_ptr.stack.append(40);
    try frame_ptr.stack.append(30);
    try frame_ptr.stack.append(20);
    try frame_ptr.stack.append(10);

    // Add them all together
    _ = try evm.table.execute(0, interpreter, state, 0x01); // ADD: 10+20=30
    _ = try evm.table.execute(0, interpreter, state, 0x01); // ADD: 30+30=60
    _ = try evm.table.execute(0, interpreter, state, 0x01); // ADD: 60+40=100
    _ = try evm.table.execute(0, interpreter, state, 0x01); // ADD: 100+50=150

    // Divide by count
    try frame_ptr.stack.append(5);
    _ = try evm.table.execute(0, interpreter, state, 0x90); // SWAP1 to get [5, 150]
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
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer vm.deinit();

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
        .withVm(&vm)
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
    // ADDMOD pops a, pops b, then peeks n (and overwrites n with result)
    // So we need stack: [n, b, a] (a on top)
    // a = MAX_U256 - 10, b = 20, n = 100
    // Correct: a + b = 2^256 + 9, and (2^256 + 9) % 100 = 45
    try frame_ptr.stack.append(n); // modulus (bottom)
    try frame_ptr.stack.append(b); // second addend (middle)
    try frame_ptr.stack.append(a); // first addend (top)
    _ = try evm.table.execute(0, interpreter, state, 0x08); // ADDMOD

    const addmod_result = try frame_ptr.stack.peek_n(0);
    // Correct calculation: (a + b) % n should be 45
    // a = 2^256 - 11, b = 20, so a + b = 2^256 + 9
    // 2^256 ≡ 36 (mod 100), so (2^256 + 9) ≡ 45 (mod 100)
    try testing.expectEqual(@as(u256, 45), addmod_result);

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
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer vm.deinit();

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
        .withVm(&vm)
        .withContract(&contract)
        .withGas(50000)
        .withInput(contract.input)
        .build();
    defer frame_ptr.deinit();

    // Setup for opcode execution
    const interpreter: Operation.Interpreter = &evm;
    const state: Operation.State = frame_ptr;

    // First calculate 3^2
    // EXP pops base then peeks exp, so for 3^2 we need [2, 3] on stack (3 on top)
    try frame_ptr.stack.append(2); // exponent
    try frame_ptr.stack.append(3); // base
    _ = try evm.table.execute(0, interpreter, state, 0x0A); // EXP: 3^2 = 9

    // Verify intermediate result
    const intermediate = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 9), intermediate);

    // Then calculate 2^9
    // Stack currently has [9], we need [9, 2] for 2^9 (2 on top as base)
    try frame_ptr.stack.append(2); // Push base
    _ = try evm.table.execute(0, interpreter, state, 0x0A); // EXP: 2^9 = 512

    const result = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 512), result);
}
