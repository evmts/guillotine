const std = @import("std");
const testing = std.testing;

// test {
//     std.testing.log_level = .debug;
// }

// Import EVM components directly
const Evm = @import("evm");
const primitives = @import("primitives");
const Frame = Evm.Frame;
const Contract = Evm.Contract;
const Address = primitives.Address;
const Operation = Evm.Operation;
const ExecutionError = Evm.ExecutionError;
const MemoryDatabase = Evm.MemoryDatabase;
const opcodes = Evm.opcodes;
const Context = Evm.Context;

test "Integration: Conditional jump patterns" {
    // Test JUMPI with various conditions
    const allocator = testing.allocator;

    // Create memory database and VM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

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
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        primitives.Address.ZERO_ADDRESS, // caller
        &.{}, // input
        vm.context
    );
    defer frame.deinit();

    // Test 1: Jump when condition is true
    frame.pc = 0;
    // JUMPI expects stack: [condition, destination] with destination on top
    try frame.stack_push(1); // condition=1
    try frame.stack_push(10); // destination=10

    _ = try vm.table.execute(&vm, &frame, 0x57); // JUMPI

    try testing.expectEqual(@as(usize, 10), frame.pc);

    // Test 2: Don't jump when condition is false
    frame.pc = 0;
    // JUMPI expects stack: [condition, destination] with destination on top
    try frame.stack_push(0); // condition=0
    try frame.stack_push(20); // destination=20

    _ = try vm.table.execute(&vm, &frame, 0x57); // JUMPI
    try testing.expectEqual(@as(usize, 0), frame.pc); // PC unchanged

    // Test 3: Complex condition evaluation
    frame.pc = 0;

    // Calculate condition: 5 > 3
    // GT computes top > second, so we need 5 on top
    try frame.stack_push(3);
    try frame.stack_push(5);
    _ = try vm.table.execute(&vm, &frame, 0x11); // GT Result: 1, Stack: [1] (5 > 3 = true)

    // Push destination (30) on top of condition
    try frame.stack_push(30); // Stack: [1, 30] with 30 on top
    // Now stack is [condition=1, destination=30] which is correct for JUMPI

    _ = try vm.table.execute(&vm, &frame, 0x57); // JUMPI
    try testing.expectEqual(@as(usize, 30), frame.pc);
}

test "Integration: Loop implementation with JUMP" {
    // Implement a simple counter loop
    const allocator = testing.allocator;

    // Create memory database and VM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

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
    var frame = try Frame.init(
        allocator,
        &vm,
        100000, // gas_limit
        &contract,
        primitives.Address.ZERO_ADDRESS, // caller
        &.{}, // input
        vm.context
    );
    defer frame.deinit();

    // Initialize counter to 5
    try frame.stack_push(5);


    // Simulate loop iterations
    var iterations: u32 = 0;
    while (iterations < 5) : (iterations += 1) {
        // Decrement counter
        // SUB now does top - second, so we need [1, counter] to get counter - 1
        try frame.stack_push(1); // Stack: [counter, 1]
        _ = try vm.table.execute(&vm, &frame, 0x90); // SWAP1 to get [1, counter]
        _ = try vm.table.execute(&vm, &frame, 0x03); // SUB = counter - 1

        // Duplicate for comparison
        _ = try vm.table.execute(&vm, &frame, 0x80); // DUP1

        // Check if counter > 0
        // Stack after DUP1: [counter, counter]
        // GT computes top > second, so we need counter on top and 0 second
        // Current stack has counter, so we push 0 then swap
        try frame.stack_push(0); // Stack: [counter, counter, 0]
        _ = try vm.table.execute(&vm, &frame, 0x90); // SWAP1: Stack: [counter, 0, counter]
        _ = try vm.table.execute(&vm, &frame, 0x11); // GT: counter > 0

        // If counter > 0, we would jump back to loop start
        const condition = try frame.stack_pop();
        if (condition == 0) break;
    }

    // Counter should be 0
    const result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0), result);
}

test "Integration: Return data handling" {
    // Test RETURN with memory data
    const allocator = testing.allocator;

    // Create memory database and VM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

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
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        primitives.Address.ZERO_ADDRESS, // caller
        &.{}, // input
        vm.context
    );
    defer frame.deinit();


    // Store data in memory
    const return_value: u256 = 0x42424242;
    try frame.stack_push(return_value); // value
    try frame.stack_push(0); // offset - corrected order for MSTORE
    _ = try vm.table.execute(&vm, &frame, 0x52); // MSTORE

    // Return 32 bytes from offset 0
    // Stack order: [size, offset] with offset on top
    try frame.stack_push(32); // size (second from top)
    try frame.stack_push(0); // offset (top)

    // RETURN will throw an error (ExecutionError.STOP) which is expected
    const result = vm.table.execute(&vm, &frame, 0xF3); // RETURN
    try testing.expectError(ExecutionError.Error.STOP, result);

    // The output data is available in frame.output
    try testing.expectEqual(@as(usize, 32), frame.output.len);
}

test "Integration: Revert with reason" {
    // Test REVERT with error message
    const allocator = testing.allocator;

    // Create memory database and VM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

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
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        primitives.Address.ZERO_ADDRESS, // caller
        &.{}, // input
        vm.context
    );
    defer frame.deinit();


    // Store error message in memory
    const error_msg = "Insufficient balance";
    try frame.memory_set_data(0, error_msg.len, error_msg);

    // Revert with error message
    // Stack order: [size, offset] with offset on top
    try frame.stack_push(error_msg.len); // size (second from top)
    try frame.stack_push(0); // offset (top)

    // REVERT will throw an error (ExecutionError.REVERT) which is expected
    const result = vm.table.execute(&vm, &frame, 0xFD); // REVERT
    try testing.expectError(ExecutionError.Error.REVERT, result);

    // The revert data is available in frame.output
    try testing.expectEqual(@as(usize, error_msg.len), frame.output.len);
    try testing.expectEqualSlices(u8, error_msg, frame.output);
}

test "Integration: PC tracking through operations" {
    // Test PC opcode and tracking
    const allocator = testing.allocator;

    // Create memory database and VM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

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
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        primitives.Address.ZERO_ADDRESS, // caller
        &.{}, // input
        vm.context
    );
    defer frame.deinit();


    // Set PC to a specific value
    frame.pc = 42;

    // Get current PC - PC opcode uses frame's pc value
    _ = try vm.table.execute(&vm, &frame, 0x58); // PC

    const result1 = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 42), result1);

    // Change PC and get again
    frame.pc = 100;
    _ = try vm.table.execute(&vm, &frame, 0x58); // PC

    const result2 = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 100), result2);
}

test "Integration: Invalid opcode handling" {
    // Test INVALID opcode
    const allocator = testing.allocator;

    // Create memory database and VM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

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
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        primitives.Address.ZERO_ADDRESS, // caller
        &.{}, // input
        vm.context
    );
    defer frame.deinit();


    // Execute INVALID opcode
    // Check gas before execution
    const result = vm.table.execute(&vm, &frame, 0xFE); // INVALID
    // Check gas after execution
    try testing.expectError(ExecutionError.Error.InvalidOpcode, result);

    // All gas should be consumed
    try testing.expectEqual(@as(u64, 0), frame.gas_remaining);
}

test "Integration: Nested conditions with jumps" {
    // Test complex control flow: if (a > b && c < d) { ... }
    const allocator = testing.allocator;

    // Create memory database and VM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

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
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        primitives.Address.ZERO_ADDRESS, // caller
        &.{}, // input
        vm.context
    );
    defer frame.deinit();


    // Test values: a=10, b=5, c=3, d=8
    const a: u256 = 10;
    const b: u256 = 5;
    const c: u256 = 3;
    const d: u256 = 8;

    // First condition: a > b (should be true) with corrected GT
    // GT now computes (top > second), so we need [b, a] for a > b
    try frame.stack_push(b); // Push b (second)
    try frame.stack_push(a); // Push a (top), Stack: [b, a]
    _ = try vm.table.execute(&vm, &frame, 0x11); // GT: computes a > b

    // If first condition is false, jump to end
    _ = try vm.table.execute(&vm, &frame, 0x80); // DUP1
    _ = try vm.table.execute(&vm, &frame, 0x15); // ISZERO
    try frame.stack_push(60); // Jump to end if false
    _ = try vm.table.execute(&vm, &frame, 0x90); // SWAP1

    // This would be a JUMPI in real execution
    const should_skip_first = try frame.stack_pop();
    _ = try frame.stack_pop(); // Pop destination
    try testing.expectEqual(@as(u256, 0), should_skip_first); // Should not skip

    // Second condition: c < d (should be true) with corrected LT  
    // LT now computes (top < second), so we need [d, c] for c < d
    try frame.stack_push(d); // Push d (second)
    try frame.stack_push(c); // Push c (top), Stack: [d, c] 
    _ = try vm.table.execute(&vm, &frame, 0x10); // LT: computes c < d

    // AND the conditions
    _ = try vm.table.execute(&vm, &frame, 0x02); // MUL (using as AND for 0/1 values)

    const result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 1), result); // Both conditions true
}

test "Integration: Self-destruct with beneficiary" {
    // Test SELFDESTRUCT operation
    const allocator = testing.allocator;

    // Create memory database and VM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

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
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        primitives.Address.ZERO_ADDRESS, // caller
        &.{}, // input
        vm.context
    );
    defer frame.deinit();


    // Get initial beneficiary balance directly from the HashMap
    const initial_balance = vm.state.get_balance(bob_address);
    try testing.expectEqual(beneficiary_initial, initial_balance);

    // Execute selfdestruct with BOB as beneficiary
    try frame.stack_push(primitives.Address.to_u256(bob_address));

    // Note: Actual selfdestruct implementation would transfer balance and mark for deletion
    // For this test, we're just verifying the opcode executes
    const result = vm.table.execute(&vm, &frame, 0xFF); // SELFDESTRUCT
    try testing.expectError(ExecutionError.Error.STOP, result);
}
