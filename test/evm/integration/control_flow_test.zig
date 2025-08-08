const std = @import("std");
const testing = std.testing;

// test {
//     std.testing.log_level = .debug;
// }

// Import EVM components directly
const evm = @import("evm");
const CallParams = evm.Host.CallParams;
const CallResult = evm.CallResult;
// Updated to new API - migration in progress, tests not run yet
const primitives = @import("primitives");
const Frame = evm.Frame;
const Contract = evm.Contract;
const Address = primitives.Address;
const Operation = evm.Operation;
const ExecutionError = evm.ExecutionError;
const MemoryDatabase = evm.MemoryDatabase;
const opcodes = evm.opcodes;

test "Integration: Conditional jump patterns" {
    // Test JUMPI with various conditions
    const allocator = testing.allocator;

    // Create memory database and VM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create bytecode with jump destinations
    var code = [_]u8{0} ** 100;
    code[10] = 0x5b; // JUMPDEST at position 10
    code[20] = 0x5b; // JUMPDEST at position 20
    code[30] = 0x5b; // JUMPDEST at position 30

    // Calculate proper code hash after setting up the code
    var code_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&code, &code_hash, .{});

    const alice_address = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);
    const contract_address = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &code,
        code_hash,
        &[_]u8{},
        false,
    );

    // Pre-analyze jump destinations

    // Create frame
    const frame_ptr = try allocator.create(Frame);
    defer allocator.destroy(frame_ptr);

    var frame_builder = Frame.builder(allocator);
    frame_ptr.* = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame_ptr.deinit();
    frame_ptr.input = contract.input;

    // Test 1: Jump when condition is true
    frame_ptr.pc = 0;
    // JUMPI expects stack: [condition, destination] with destination on top
    try frame_ptr.stack.append(1); // condition=1
    try frame_ptr.stack.append(10); // destination=10

    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = frame_ptr;
    _ = try vm.table.execute(0, interpreter, state, 0x57); // JUMPI

    try testing.expectEqual(@as(usize, 10), frame_ptr.pc);

    // Test 2: Don't jump when condition is false
    frame_ptr.pc = 0;
    // JUMPI expects stack: [condition, destination] with destination on top
    try frame_ptr.stack.append(0); // condition=0
    try frame_ptr.stack.append(20); // destination=20

    _ = try vm.table.execute(0, interpreter, state, 0x57); // JUMPI
    try testing.expectEqual(@as(usize, 0), frame_ptr.pc); // PC unchanged

    // Test 3: Complex condition evaluation
    frame_ptr.pc = 0;

    // Calculate condition: 5 > 3
    // GT computes top > second, so we need 5 on top
    try frame_ptr.stack.append(3);
    try frame_ptr.stack.append(5);
    _ = try vm.table.execute(0, interpreter, state, 0x11); // GT Result: 1, Stack: [1] (5 > 3 = true)

    // Push destination (30) on top of condition
    try frame_ptr.stack.append(30); // Stack: [1, 30] with 30 on top
    // Now stack is [condition=1, destination=30] which is correct for JUMPI

    _ = try vm.table.execute(0, interpreter, state, 0x57); // JUMPI
    try testing.expectEqual(@as(usize, 30), frame_ptr.pc);
}

test "Integration: Loop implementation with JUMP" {
    // Implement a simple counter loop
    const allocator = testing.allocator;

    // Create memory database and VM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create bytecode for loop
    var code = [_]u8{0} ** 100;
    code[0] = 0x5b; // JUMPDEST (loop start)
    code[50] = 0x5b; // JUMPDEST (loop end)

    // Calculate proper code hash after setting up the code
    var code_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&code, &code_hash, .{});

    const alice_address = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);
    const contract_address = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &code,
        code_hash,
        &[_]u8{},
        false,
    );


    // Create frame
    const frame_ptr = try allocator.create(Frame);
    defer allocator.destroy(frame_ptr);

    var frame_builder = Frame.builder(allocator);
    frame_ptr.* = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame_ptr.deinit();
    frame_ptr.input = contract.input;

    // Initialize counter to 5
    try frame_ptr.stack.append(5);

    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = frame_ptr;

    // Simulate loop iterations
    var iterations: u32 = 0;
    while (iterations < 5) : (iterations += 1) {
        // Decrement counter
        // SUB now does top - second, so we need [1, counter] to get counter - 1
        try frame_ptr.stack.append(1); // Stack: [counter, 1]
        _ = try vm.table.execute(0, interpreter, state, 0x90); // SWAP1 to get [1, counter]
        _ = try vm.table.execute(0, interpreter, state, 0x03); // SUB = counter - 1

        // Duplicate for comparison
        _ = try vm.table.execute(0, interpreter, state, 0x80); // DUP1

        // Check if counter > 0
        // Stack after DUP1: [counter, counter]
        // GT computes top > second, so we need counter on top and 0 second
        // Current stack has counter, so we push 0 then swap
        try frame_ptr.stack.append(0); // Stack: [counter, counter, 0]
        _ = try vm.table.execute(0, interpreter, state, 0x90); // SWAP1: Stack: [counter, 0, counter]
        _ = try vm.table.execute(0, interpreter, state, 0x11); // GT: counter > 0

        // If counter > 0, we would jump back to loop start
        const condition = try frame_ptr.stack.pop();
        if (condition == 0) break;
    }

    // Counter should be 0
    const result = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0), result);
}

test "Integration: Return data handling" {
    // Test RETURN with memory data
    const allocator = testing.allocator;

    // Create memory database and VM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    const alice_address = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);
    const contract_address = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);

    // Calculate proper code hash for empty code
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );

    // Create frame
    const frame_ptr = try allocator.create(Frame);
    defer allocator.destroy(frame_ptr);

    var frame_builder = Frame.builder(allocator);
    frame_ptr.* = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame_ptr.deinit();
    frame_ptr.input = contract.input;

    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = frame_ptr;

    // Store data in memory
    const return_value: u256 = 0x42424242;
    try frame_ptr.stack.append(return_value); // value
    try frame_ptr.stack.append(0); // offset - corrected order for MSTORE
    _ = try vm.table.execute(0, interpreter, state, 0x52); // MSTORE

    // Return 32 bytes from offset 0
    // Stack order: [size, offset] with offset on top
    try frame_ptr.stack.append(32); // size (second from top)
    try frame_ptr.stack.append(0); // offset (top)

    // RETURN will throw an error (ExecutionError.STOP) which is expected
    const result = vm.table.execute(0, interpreter, state, 0xF3); // RETURN
    try testing.expectError(ExecutionError.Error.STOP, result);

    // The output data is available in frame.output
    try testing.expectEqual(@as(usize, 32), frame_ptr.output.len);
}

test "Integration: Revert with reason" {
    // Test REVERT with error message
    const allocator = testing.allocator;

    // Create memory database and VM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    const alice_address = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);
    const contract_address = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);

    // Calculate proper code hash for empty code
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );

    // Create frame
    const frame_ptr = try allocator.create(Frame);
    defer allocator.destroy(frame_ptr);

    var frame_builder = Frame.builder(allocator);
    frame_ptr.* = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame_ptr.deinit();
    frame_ptr.input = contract.input;

    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = frame_ptr;

    // Store error message in memory
    const error_msg = "Insufficient balance";
    try frame_ptr.memory.set_data(0, error_msg);

    // Revert with error message
    // Stack order: [size, offset] with offset on top
    try frame_ptr.stack.append(error_msg.len); // size (second from top)
    try frame_ptr.stack.append(0); // offset (top)

    // REVERT will throw an error (ExecutionError.REVERT) which is expected
    const result = vm.table.execute(0, interpreter, state, 0xFD); // REVERT
    try testing.expectError(ExecutionError.Error.REVERT, result);

    // The revert data is available in frame.output
    try testing.expectEqual(@as(usize, error_msg.len), frame_ptr.output.len);
    try testing.expectEqualSlices(u8, error_msg, frame_ptr.output);
}

test "Integration: PC tracking through operations" {
    // Test PC opcode and tracking
    const allocator = testing.allocator;

    // Create memory database and VM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    const alice_address = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);
    const contract_address = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);

    // Calculate proper code hash for empty code
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );

    // Create frame
    const frame_ptr = try allocator.create(Frame);
    defer allocator.destroy(frame_ptr);

    var frame_builder = Frame.builder(allocator);
    frame_ptr.* = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame_ptr.deinit();
    frame_ptr.input = contract.input;

    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = frame_ptr;

    // Set PC to a specific value
    frame_ptr.pc = 42;

    // Get current PC - PC opcode uses frame's pc value
    _ = try vm.table.execute(frame_ptr.pc, interpreter, state, 0x58); // PC

    const result1 = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 42), result1);

    // Change PC and get again
    frame_ptr.pc = 100;
    _ = try vm.table.execute(frame_ptr.pc, interpreter, state, 0x58); // PC

    const result2 = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 100), result2);
}

test "Integration: Invalid opcode handling" {
    // Test INVALID opcode
    const allocator = testing.allocator;

    // Create memory database and VM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    const alice_address = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);
    const contract_address = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);

    // Calculate proper code hash for empty code
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );

    // Create frame
    const frame_ptr = try allocator.create(Frame);
    defer allocator.destroy(frame_ptr);

    var frame_builder = Frame.builder(allocator);
    frame_ptr.* = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame_ptr.deinit();
    frame_ptr.input = contract.input;

    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = frame_ptr;

    // Execute INVALID opcode
    // Check gas before execution
    const result = vm.table.execute(0, interpreter, state, 0xFE); // INVALID
    // Check gas after execution
    try testing.expectError(ExecutionError.Error.InvalidOpcode, result);

    // All gas should be consumed
    try testing.expectEqual(@as(u64, 0), frame_ptr.gas_remaining);
}

test "Integration: Nested conditions with jumps" {
    // Test complex control flow: if (a > b && c < d) { ... }
    const allocator = testing.allocator;

    // Create memory database and VM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create bytecode with multiple jump destinations
    var code = [_]u8{0} ** 100;
    code[20] = 0x5b; // JUMPDEST (first condition false)
    code[40] = 0x5b; // JUMPDEST (both conditions true)
    code[60] = 0x5b; // JUMPDEST (end)

    // Calculate proper code hash after setting up the code
    var code_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&code, &code_hash, .{});

    const alice_address = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);
    const contract_address = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &code,
        code_hash,
        &[_]u8{},
        false,
    );


    // Create frame
    const frame_ptr = try allocator.create(Frame);
    defer allocator.destroy(frame_ptr);

    var frame_builder = Frame.builder(allocator);
    frame_ptr.* = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame_ptr.deinit();
    frame_ptr.input = contract.input;

    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = frame_ptr;

    // Test values: a=10, b=5, c=3, d=8
    const a: u256 = 10;
    const b: u256 = 5;
    const c: u256 = 3;
    const d: u256 = 8;

    // First condition: a > b (should be true) with corrected GT
    // GT now computes (top > second), so we need [b, a] for a > b
    try frame_ptr.stack.append(b); // Push b (second)
    try frame_ptr.stack.append(a); // Push a (top), Stack: [b, a]
    _ = try vm.table.execute(0, interpreter, state, 0x11); // GT: computes a > b

    // If first condition is false, jump to end
    _ = try vm.table.execute(0, interpreter, state, 0x80); // DUP1
    _ = try vm.table.execute(0, interpreter, state, 0x15); // ISZERO
    try frame_ptr.stack.append(60); // Jump to end if false
    _ = try vm.table.execute(0, interpreter, state, 0x90); // SWAP1

    // This would be a JUMPI in real execution
    const should_skip_first = try frame_ptr.stack.pop();
    _ = try frame_ptr.stack.pop(); // Pop destination
    try testing.expectEqual(@as(u256, 0), should_skip_first); // Should not skip

    // Second condition: c < d (should be true) with corrected LT  
    // LT now computes (top < second), so we need [d, c] for c < d
    try frame_ptr.stack.append(d); // Push d (second)
    try frame_ptr.stack.append(c); // Push c (top), Stack: [d, c] 
    _ = try vm.table.execute(0, interpreter, state, 0x10); // LT: computes c < d

    // AND the conditions
    _ = try vm.table.execute(0, interpreter, state, 0x02); // MUL (using as AND for 0/1 values)

    const result = try frame_ptr.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 1), result); // Both conditions true
}

test "Integration: Self-destruct with beneficiary" {
    // Test SELFDESTRUCT operation
    const allocator = testing.allocator;

    // Create memory database and VM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    const alice_address = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);
    const bob_address = primitives.Address.from_u256(0x2222222222222222222222222222222222222222);
    const contract_address = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);

    // Set up contract with balance
    const contract_balance: u256 = 1000;
    try vm.state.set_balance(contract_address, contract_balance);

    // Set up beneficiary
    const beneficiary_initial: u256 = 500;
    try vm.state.set_balance(bob_address, beneficiary_initial);

    // Calculate proper code hash for empty code
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );

    // Create frame
    const frame_ptr = try allocator.create(Frame);
    defer allocator.destroy(frame_ptr);

    var frame_builder = Frame.builder(allocator);
    frame_ptr.* = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame_ptr.deinit();
    frame_ptr.input = contract.input;

    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = frame_ptr;

    // Get initial beneficiary balance directly from the HashMap
    const initial_balance = vm.state.get_balance(bob_address);
    try testing.expectEqual(beneficiary_initial, initial_balance);

    // Execute selfdestruct with BOB as beneficiary
    try frame_ptr.stack.append(primitives.Address.to_u256(bob_address));

    // Note: Actual selfdestruct implementation would transfer balance and mark for deletion
    // For this test, we're just verifying the opcode executes
    const result = vm.table.execute(0, interpreter, state, 0xFF); // SELFDESTRUCT
    try testing.expectError(ExecutionError.Error.STOP, result);
}
