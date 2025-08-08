const std = @import("std");
const testing = std.testing;

// Import opcodes through evm module
const evm = @import("evm");
const CallParams = evm.Host.CallParams;
const CallResult = evm.CallResult;
// Updated to new API - migration in progress, tests not run yet
const memory = evm.opcodes.memory;
const storage = evm.opcodes.storage;
const bitwise = evm.opcodes.bitwise;
const arithmetic = evm.opcodes.arithmetic;
const crypto = evm.opcodes.crypto;
const stack = evm.opcodes.stack;
const comparison = evm.opcodes.comparison;

test "Integration: Token balance check pattern" {
    // Simulate checking and updating a token balance
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create database interface
    const db_interface = memory_db.to_database_interface();

    // Create VM
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create addresses
    const contract_address = evm.primitives.Address.from_u256(0x02);
    const alice_address = evm.primitives.Address.from_u256(0x01);

    // Calculate proper code hash
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    // Create contract
    var contract = evm.Contract.init(
        alice_address, // caller
        contract_address, // address
        0, // value
        100000, // gas
        &[_]u8{}, // code
        code_hash, // code hash
        &[_]u8{}, // input
        false, // is_static
    );
    defer contract.deinit(allocator, null);

    // Create frame with gas
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Simulate ERC20 balance mapping: mapping(address => uint256)
    // Storage slot = keccak256(address . uint256(0))

    // Store Alice's address in memory at offset 0
    const alice_addr = evm.primitives.Address.to_u256(alice_address);
    try frame.stack.append(alice_addr); // value
    try frame.stack.append(0); // offset
    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x52); // MSTORE

    // Store mapping slot (0) at offset 32
    try frame.stack.append(0); // value
    try frame.stack.append(32); // offset
    _ = try vm.table.execute(0, interpreter, state, 0x52); // MSTORE

    // Hash to get storage slot
    try frame.stack.append(0); // offset
    try frame.stack.append(64); // size
    _ = try vm.table.execute(0, interpreter, state, 0x20); // SHA3

    // Set initial balance
    const initial_balance: u256 = 1000;
    _ = try vm.table.execute(0, interpreter, state, 0x80); // DUP1 - duplicate slot
    try frame.stack.append(initial_balance); // Stack: [slot_hash, slot_hash, initial_balance]
    _ = try vm.table.execute(0, interpreter, state, 0x90); // SWAP1: [slot_hash, initial_balance, slot_hash]
    _ = try vm.table.execute(0, interpreter, state, 0x55); // SSTORE: pops slot_hash, then initial_balance

    // Load balance
    _ = try vm.table.execute(0, interpreter, state, 0x54); // SLOAD using the remaining slot_hash

    // Check if balance >= 100 using corrected stack order
    // With the fixed LT opcode: LT now computes (top < second)
    // Original stack after SLOAD: [balance]
    try frame.stack.append(100); // Stack: [balance, 100]
    // LT will compute: 100 < balance (which should be true since 1000 > 100)
    _ = try vm.table.execute(0, interpreter, state, 0x10); // LT pops 100, compares 100 < balance

    // Result should be 1 (true) since 100 < 1000
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result);
}

test "Integration: Packed struct storage" {
    // Simulate Solidity packed struct storage
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create database interface
    const db_interface = memory_db.to_database_interface();

    // Create VM
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create addresses
    const contract_address = evm.primitives.Address.from_u256(0x02);
    const alice_address = evm.primitives.Address.from_u256(0x01);

    // Calculate proper code hash
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    // Create contract
    var contract = evm.Contract.init(
        alice_address, // caller
        contract_address, // address
        0, // value
        100000, // gas
        &[_]u8{}, // code
        code_hash, // code hash
        &[_]u8{}, // input
        false, // is_static
    );
    defer contract.deinit(allocator, null);

    // Create frame with gas
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Simulate struct { uint128 a; uint128 b; } packed in one slot
    const a: u256 = 12345; // Lower 128 bits
    const b: u256 = 67890; // Upper 128 bits

    // Pack values: b << 128 | a
    try frame.stack.append(b);
    try frame.stack.append(128);
    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x1B); // SHL

    try frame.stack.append(a);
    _ = try vm.table.execute(0, interpreter, state, 0x17); // OR

    // Store packed value
    const slot: u256 = 5;
    try frame.stack.append(slot); // Now stack is [packed_value, slot]
    _ = try vm.table.execute(0, interpreter, state, 0x55); // SSTORE: pops slot, then packed_value

    // Load and unpack 'a' (lower 128 bits)
    try frame.stack.append(slot);
    _ = try vm.table.execute(0, interpreter, state, 0x54); // SLOAD

    // Mask to get lower 128 bits
    const mask_128 = ((@as(u256, 1) << 128) - 1);
    try frame.stack.append(mask_128);
    _ = try vm.table.execute(0, interpreter, state, 0x16); // AND

    const result_a = try frame.stack.pop();
    try testing.expectEqual(@as(u256, a), result_a);

    // Load and unpack 'b' (upper 128 bits)
    try frame.stack.append(slot);
    _ = try vm.table.execute(0, interpreter, state, 0x54); // SLOAD
    try frame.stack.append(128);
    _ = try vm.table.execute(0, interpreter, state, 0x1C); // SHR

    const result_b = try frame.stack.pop();
    try testing.expectEqual(@as(u256, b), result_b);
}

test "Integration: Dynamic array length update" {
    // Simulate updating a dynamic array's length
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create database interface
    const db_interface = memory_db.to_database_interface();

    // Create VM
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create addresses
    const contract_address = evm.primitives.Address.from_u256(0x02);
    const alice_address = evm.primitives.Address.from_u256(0x01);

    // Calculate proper code hash
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    // Create contract
    var contract = evm.Contract.init(
        alice_address, // caller
        contract_address, // address
        0, // value
        100000, // gas
        &[_]u8{}, // code
        code_hash, // code hash
        &[_]u8{}, // input
        false, // is_static
    );
    defer contract.deinit(allocator, null);

    // Create frame with gas
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Dynamic array base slot
    const array_slot: u256 = 10;

    // Load current length
    try frame.stack.append(array_slot);
    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x54); // SLOAD

    // Increment length
    try frame.stack.append(1);
    _ = try vm.table.execute(0, interpreter, state, 0x01); // ADD

    // Store new length
    _ = try vm.table.execute(0, interpreter, state, 0x80); // DUP1 - Duplicate new length
    try frame.stack.append(array_slot); // Stack: [new_length, new_length, array_slot]
    _ = try vm.table.execute(0, interpreter, state, 0x55); // SSTORE: pops array_slot, then new_length

    // New length should be 1
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result);
}

test "Integration: Reentrancy guard pattern" {
    // Simulate a reentrancy guard check and set
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create database interface
    const db_interface = memory_db.to_database_interface();

    // Create VM
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create addresses
    const contract_address = evm.primitives.Address.from_u256(0x02);
    const alice_address = evm.primitives.Address.from_u256(0x01);

    // Calculate proper code hash
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    // Create contract
    var contract = evm.Contract.init(
        alice_address, // caller
        contract_address, // address
        0, // value
        100000, // gas
        &[_]u8{}, // code
        code_hash, // code hash
        &[_]u8{}, // input
        false, // is_static
    );
    defer contract.deinit(allocator, null);

    // Create frame with gas
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    const guard_slot: u256 = 99;
    _ = 1; // NOT_ENTERED constant (not used in this test)
    const ENTERED: u256 = 2;

    // Check guard status
    try frame.stack.append(guard_slot);
    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x54); // SLOAD

    // If not set, it's 0, so we need to check against NOT_ENTERED
    _ = try vm.table.execute(0, interpreter, state, 0x80); // DUP1
    try frame.stack.append(ENTERED);
    _ = try vm.table.execute(0, interpreter, state, 0x14); // EQ

    // Should be 0 (not entered)
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result1);

    // Set guard to ENTERED
    _ = try vm.table.execute(0, interpreter, state, 0x50); // POP - Remove old value from stack
    try frame.stack.append(ENTERED);
    try frame.stack.append(guard_slot); // Stack: [ENTERED, guard_slot]
    _ = try vm.table.execute(0, interpreter, state, 0x55); // SSTORE: pops guard_slot, then ENTERED

    // Verify guard is set
    try frame.stack.append(guard_slot);
    _ = try vm.table.execute(0, interpreter, state, 0x54); // SLOAD

    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, ENTERED), result2);
}

test "Integration: Bitfield manipulation" {
    // Simulate complex bitfield operations
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create database interface
    const db_interface = memory_db.to_database_interface();

    // Create VM
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create addresses
    const contract_address = evm.primitives.Address.from_u256(0x02);
    const alice_address = evm.primitives.Address.from_u256(0x01);

    // Calculate proper code hash
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    // Create contract
    var contract = evm.Contract.init(
        alice_address, // caller
        contract_address, // address
        0, // value
        100000, // gas
        &[_]u8{}, // code
        code_hash, // code hash
        &[_]u8{}, // input
        false, // is_static
    );
    defer contract.deinit(allocator, null);

    // Create frame with gas
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    // Create a bitfield with flags at different positions
    var bitfield: u256 = 0;

    // Set bit 0 (0x1)
    try frame.stack.append(bitfield);
    try frame.stack.append(1);
    _ = try vm.table.execute(0, interpreter, state, 0x17); // OR
    bitfield = try frame.stack.pop();

    // Set bit 7 (0x80)
    try frame.stack.append(bitfield);
    try frame.stack.append(0x80);
    _ = try vm.table.execute(0, interpreter, state, 0x17); // OR
    bitfield = try frame.stack.pop();

    // Set bit 255 (highest bit)
    try frame.stack.append(bitfield);
    try frame.stack.append(@as(u256, 1) << 255);
    _ = try vm.table.execute(0, interpreter, state, 0x17); // OR
    bitfield = try frame.stack.pop();

    // Check if bit 7 is set
    try frame.stack.append(bitfield);
    try frame.stack.append(0x80);
    _ = try vm.table.execute(0, interpreter, state, 0x16); // AND
    // Stack now has [result_of_AND] where result should be 0x80 if bit 7 is set
    // We want to check if result > 0
    // With corrected GT: GT computes (top > second)
    // So we need stack [0, and_result] for and_result > 0
    const and_result = try frame.stack.pop(); // Get AND result  
    try frame.stack.append(0); // Push 0 (second)
    try frame.stack.append(and_result); // Push AND result (top), Stack: [0, and_result]
    _ = try vm.table.execute(0, interpreter, state, 0x11); // GT: computes and_result > 0

    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result1); // Bit 7 is set

    // Clear bit 0
    try frame.stack.append(bitfield);
    try frame.stack.append(1);
    _ = try vm.table.execute(0, interpreter, state, 0x18); // XOR
    bitfield = try frame.stack.pop();

    // Check if bit 0 is clear
    try frame.stack.append(bitfield);
    try frame.stack.append(1);
    _ = try vm.table.execute(0, interpreter, state, 0x16); // AND

    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result2); // Bit 0 is clear
}

test "Integration: Safe math operations" {
    // Simulate SafeMath-style overflow checks
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create database interface
    const db_interface = memory_db.to_database_interface();

    // Create VM
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create addresses
    const contract_address = evm.primitives.Address.from_u256(0x02);
    const alice_address = evm.primitives.Address.from_u256(0x01);

    // Calculate proper code hash
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    // Create contract
    var contract = evm.Contract.init(
        alice_address, // caller
        contract_address, // address
        0, // value
        100000, // gas
        &[_]u8{}, // code
        code_hash, // code hash
        &[_]u8{}, // input
        false, // is_static
    );
    defer contract.deinit(allocator, null);

    // Create frame with gas
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    // Safe addition: check if a + b overflows
    const a: u256 = std.math.maxInt(u256) - 100;
    const b: u256 = 50;

    // Calculate a + b
    try frame.stack.append(a);
    try frame.stack.append(b);
    _ = try vm.table.execute(0, interpreter, state, 0x01); // ADD
    const sum = try frame.stack.pop();

    // Check if sum < a (overflow occurred)
    // With corrected LT: LT computes (top < second)
    // We want to test sum < a to detect overflow
    try frame.stack.append(a); // Push a (second)
    try frame.stack.append(sum); // Push sum (top), Stack: [a, sum]
    _ = try vm.table.execute(0, interpreter, state, 0x10); // LT: computes sum < a

    // Should be 0 (no overflow since sum >= a when no overflow)
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result1);

    // Test actual overflow
    const c: u256 = 200; // This will overflow
    try frame.stack.append(a);
    try frame.stack.append(c);
    _ = try vm.table.execute(0, interpreter, state, 0x01); // ADD
    const overflow_sum = try frame.stack.pop();

    // Check if overflow_sum < a (overflow occurred)
    // We want to test if overflow_sum < a
    try frame.stack.append(a); // Push a
    try frame.stack.append(overflow_sum); // Push overflow_sum, Stack: [a, overflow_sum]
    _ = try vm.table.execute(0, interpreter, state, 0x10); // LT: computes overflow_sum < a

    // Should be 1 (overflow occurred, so overflow_sum < a)
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result2);
}

test "Integration: Signature verification simulation" {
    // Simulate part of signature verification process
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create database interface
    const db_interface = memory_db.to_database_interface();

    // Create VM
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create addresses
    const contract_address = evm.primitives.Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = evm.primitives.Address.from_u256(0x1111111111111111111111111111111111111111);

    // Calculate proper code hash
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    // Create contract
    var contract = evm.Contract.init(
        alice_address, // caller
        contract_address, // address
        0, // value
        100000, // gas
        &[_]u8{}, // code
        code_hash, // code hash
        &[_]u8{}, // input
        false, // is_static
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Simulate message hash computation
    const message = "Hello, Ethereum!";

    // Store message in memory
    try frame.memory.set_data(0, message);

    // Hash the message
    try frame.stack.append(0); // offset
    try frame.stack.append(message.len); // size
    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x20); // SHA3
    const message_hash = try frame.stack.pop();

    // Store Ethereum signed message prefix
    const prefix = "\x19Ethereum Signed Message:\n16";
    try frame.memory.set_data(100, prefix);

    // Store message length as ASCII
    try frame.stack.append(0x3136); // value
    try frame.stack.append(100 + prefix.len); // offset
    _ = try vm.table.execute(0, interpreter, state, 0x52); // MSTORE

    // Final hash would include prefix + length + message hash
    // This demonstrates the pattern even if not complete

    try testing.expect(message_hash != 0); // We got a hash
}

test "Integration: Multi-sig wallet threshold check" {
    // Simulate multi-sig wallet confirmation counting
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create database interface
    const db_interface = memory_db.to_database_interface();

    // Create VM
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create addresses
    const contract_address = evm.primitives.Address.from_u256(0x02);
    const caller_address = evm.primitives.Address.from_u256(0x01);

    // Calculate proper code hash
    const code_hash: [32]u8 = [_]u8{0} ** 32;

    // Create contract
    var contract = evm.Contract.init(
        caller_address, // caller
        contract_address, // address
        0, // value
        100000, // gas
        &[_]u8{}, // code
        code_hash, // code hash
        &[_]u8{}, // input
        false, // is_static
    );
    defer contract.deinit(allocator, null);

    // Create frame with gas
    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Execute SSTORE through jump table
    const interpreter: evm.Operation.Interpreter = &vm;
    const state: evm.Operation.State = &frame;

    // Storage layout:
    // slot 0: required confirmations
    // slot 1: confirmation count for current transaction

    // Set required confirmations to 3
    // SSTORE pops key first, then value, so we need [value, key] with key on top
    try frame.stack.append(3); // value 3
    try frame.stack.append(0); // slot 0 (key on top)
    _ = try vm.table.execute(0, interpreter, state, 0x55); // SSTORE

    // Initialize confirmation count to 0
    try frame.stack.append(0); // value 0
    try frame.stack.append(1); // slot 1 (key on top)
    _ = try vm.table.execute(0, interpreter, state, 0x55); // SSTORE

    // First confirmation - load, increment, store
    try frame.stack.append(1); // slot 1
    _ = try vm.table.execute(0, interpreter, state, 0x54); // SLOAD
    try frame.stack.append(1);
    _ = try vm.table.execute(0, interpreter, state, 0x01); // ADD
    // Stack has incremented value on top
    try frame.stack.append(1); // slot 1 (key on top)
    _ = try vm.table.execute(0, interpreter, state, 0x55); // SSTORE

    // Second confirmation - load, increment, store
    try frame.stack.append(1); // slot 1
    _ = try vm.table.execute(0, interpreter, state, 0x54); // SLOAD
    try frame.stack.append(1);
    _ = try vm.table.execute(0, interpreter, state, 0x01); // ADD
    // Stack has incremented value on top
    try frame.stack.append(1); // slot 1 (key on top)
    _ = try vm.table.execute(0, interpreter, state, 0x55); // SSTORE

    // Check if we have enough confirmations
    try frame.stack.append(1); // slot 1
    _ = try vm.table.execute(0, interpreter, state, 0x54); // SLOAD - loads confirmation count (2)
    const confirmations_val = try frame.stack.pop();

    try frame.stack.append(0); // slot 0
    _ = try vm.table.execute(0, interpreter, state, 0x54); // SLOAD - loads required confirmations (3)
    const required_val = try frame.stack.pop();

    // Compare: confirmations >= required using corrected stack order
    // We want to check if confirmations >= required
    // This is equivalent to NOT(confirmations < required)
    try frame.stack.append(required_val); // Push required
    try frame.stack.append(confirmations_val); // Push confirmations, Stack: [required, confirmations]  
    _ = try vm.table.execute(0, interpreter, state, 0x10); // LT: confirmations < required
    _ = try vm.table.execute(0, interpreter, state, 0x15); // ISZERO: NOT(confirmations < required) = confirmations >= required

    // Should be 0 (false) since 2 >= 3 is false
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result1);

    // Add third confirmation
    try frame.stack.append(1); // slot 1
    _ = try vm.table.execute(0, interpreter, state, 0x54); // SLOAD
    try frame.stack.append(1);
    _ = try vm.table.execute(0, interpreter, state, 0x01); // ADD
    // Stack has incremented value on top
    try frame.stack.append(1); // slot 1 (key on top)
    _ = try vm.table.execute(0, interpreter, state, 0x55); // SSTORE

    // Check again
    try frame.stack.append(1); // slot 1
    _ = try vm.table.execute(0, interpreter, state, 0x54); // SLOAD - loads confirmation count (3)
    const confirmations = try frame.stack.pop();

    try frame.stack.append(0); // slot 0
    _ = try vm.table.execute(0, interpreter, state, 0x54); // SLOAD - loads required confirmations (3)
    const required = try frame.stack.pop();

    // Multi-sig test: check confirmations vs required

    // Put them back on stack for comparison
    try frame.stack.append(confirmations);
    try frame.stack.append(required);

    // Compare: confirmations >= required with corrected stack order
    // Stack is [confirmations, required], LT computes required < confirmations
    try frame.stack.append(required); // Push required
    try frame.stack.append(confirmations); // Push confirmations, Stack: [required, confirmations]  
    _ = try vm.table.execute(0, interpreter, state, 0x10); // LT: confirmations < required
    _ = try vm.table.execute(0, interpreter, state, 0x15); // ISZERO: NOT(confirmations < required) = confirmations >= required

    // Should be 1 (true) since 3 >= 3 is true, so NOT(3 < 3) = NOT(false) = true
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result2);
}
