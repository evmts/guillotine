const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const CallParams = evm.Host.CallParams;
const CallResult = evm.CallResult;
// Updated to new API - migration in progress, tests not run yet
const opcodes = evm.opcodes;
const MemoryDatabase = evm.MemoryDatabase;
const Contract = evm.Contract;
const Frame = evm.Frame;
const Address = evm.Address;
const Operation = evm.Operation;
const ExecutionError = evm.ExecutionError;

// Comprehensive integration tests combining multiple opcode categories

test "Integration: Complete ERC20 transfer simulation" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Set up accounts
    const alice_balance: u256 = 1000;
    const bob_balance: u256 = 500;

    // Create addresses
    const contract_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = Address.from_u256(0x1111111111111111111111111111111111111111);
    const bob_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Storage slots for balances (slot 0 for Alice, slot 1 for Bob)
    try vm.set_storage(contract_address, 0, alice_balance);
    try vm.set_storage(contract_address, 1, bob_balance);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address, // Alice is calling
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Transfer amount
    const transfer_amount: u256 = 100;

    // 1. Load Alice's balance
    try frame.stack.append(0); // Alice's slot
    const interpreter1: Operation.Interpreter = &vm;
    const state1: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter1, state1, 0x54);
    const alice_initial = try frame.stack.pop();
    try testing.expectEqual(alice_balance, alice_initial);

    // 2. Check if Alice has enough balance
    try frame.stack.append(transfer_amount); // b
    try frame.stack.append(alice_initial); // a
    const interpreter2: Operation.Interpreter = &vm;
    const state2: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter2, state2, 0x10);
    const insufficient = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), insufficient); // Should be false (sufficient balance)

    // 3. Calculate new balances
    try frame.stack.append(transfer_amount); // b
    try frame.stack.append(alice_initial); // a
    const interpreter3: Operation.Interpreter = &vm;
    const state3: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter3, state3, 0x03);
    const alice_new = try frame.stack.pop();

    try frame.stack.append(1); // Bob's slot
    const interpreter4: Operation.Interpreter = &vm;
    const state4: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter4, &state4, 0x54);
    const bob_initial = try frame.stack.pop();

    try frame.stack.append(transfer_amount); // b
    try frame.stack.append(bob_initial); // a
    const interpreter5: Operation.Interpreter = &vm;
    const state5: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter5, &state5, 0x01);
    const bob_new = try frame.stack.pop();

    // 4. Update storage
    try frame.stack.append(0); // slot
    try frame.stack.append(alice_new); // value
    const interpreter6: Operation.Interpreter = &vm;
    const state6: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter6, &state6, 0x55);

    try frame.stack.append(1); // slot
    try frame.stack.append(bob_new); // value
    const interpreter7: Operation.Interpreter = &vm;
    const state7: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter7, &state7, 0x55);

    // 5. Emit Transfer event
    const transfer_sig: u256 = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    // Store transfer amount in memory for event data
    var amount_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &amount_bytes, transfer_amount, .big);
    try frame.memory.set_data(0, &amount_bytes);

    // Push values in reverse order for LOG3
    try frame.stack.append(0); // data offset
    try frame.stack.append(32); // data size
    try frame.stack.append(transfer_sig); // event signature
    try frame.stack.append(Address.to_u256(alice_address)); // from (indexed)
    try frame.stack.append(Address.to_u256(bob_address)); // to (indexed)

    const interpreter8: Operation.Interpreter = &vm;
    const state8: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter8, &state8, 0xA3);

    // 6. Verify final balances
    const alice_final = try vm.get_storage(contract_address, 0);
    const bob_final = try vm.get_storage(contract_address, 1);

    try testing.expectEqual(@as(u256, 900), alice_final);
    try testing.expectEqual(@as(u256, 600), bob_final);
}

test "Integration: Smart contract deployment flow" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create addresses
    const contract_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = Address.from_u256(0x1111111111111111111111111111111111111111);
    const bob_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var deployer_contract = Contract.init(
        alice_address,
        contract_address,
        10000, // Deployer has funds
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer deployer_contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&deployer_contract)
        .withGas(200000)
        .build();
    defer frame.deinit();

    // Build constructor arguments
    const initial_supply: u256 = 1_000_000;
    _ = initial_supply; // autofix
    const decimals: u256 = 18;
    _ = decimals; // autofix

    // Constructor bytecode that:
    // 1. Stores initial supply at slot 0
    // 2. Stores decimals at slot 1
    // 3. Returns runtime code
    const constructor_code = [_]u8{
        // Store initial supply
        0x69, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x42, 0x40, 0x00, 0x00, // PUSH10 1000000
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE

        // Store decimals
        0x60, 0x12, // PUSH1 18
        0x60, 0x01, // PUSH1 1
        0x55, // SSTORE

        // Return runtime code (just a STOP for simplicity)
        0x60, 0x01, // PUSH1 1 (size)
        0x60, 0x20, // PUSH1 32 (offset of runtime code)
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x39, // CODECOPY
        0x60, 0x01, // PUSH1 1 (size)
        0x60, 0x00, // PUSH1 0 (memory offset)
        0xf3, // RETURN

        // Runtime code
        0x00, // STOP
    };

    // Copy constructor code to memory
    try frame.memory.set_data(0, &constructor_code);

    // Mock successful deployment
    vm.create_result = .{
        .success = true,
        .address = bob_address,
        .gas_left = 150000,
        .output = &[_]u8{0x00}, // Runtime code
    };

    // Deploy contract
    try frame.stack.append(0); // offset
    try frame.stack.append(constructor_code.len); // size
    try frame.stack.append(0); // value

    const interpreter1: Operation.Interpreter = &vm;
    const state1: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter1, state1, 0xF0);

    const deployed_address = try frame.stack.pop();
    try testing.expectEqual(Address.to_u256(bob_address), deployed_address);

    // Verify deployment by calling the contract
    frame.stack.clear();
    vm.call_result = .{
        .success = true,
        .gas_left = 90000,
        .output = null,
    };

    try frame.stack.append(50000); // gas
    try frame.stack.append(deployed_address); // to
    try frame.stack.append(0); // value
    try frame.stack.append(0); // args_offset
    try frame.stack.append(0); // args_size
    try frame.stack.append(0); // ret_offset
    try frame.stack.append(0); // ret_size

    const interpreter2: Operation.Interpreter = &vm;
    const state2: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter2, state2, 0xF1);
    const success = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), success); // Success
}

test "Integration: Complex control flow with nested conditions" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Contract that implements:
    // if (value >= 100) {
    //     if (value <= 200) {
    //         result = value * 2;
    //     } else {
    //         result = value + 50;
    //     }
    // } else {
    //     result = value;
    // }
    var code = [_]u8{
        // Load value (150 for this test)
        0x60, 0x96, // PUSH1 150
        0x80, // DUP1

        // Check >= 100
        0x60, 0x64, // PUSH1 100
        0x10, // LT
        0x15, // ISZERO (now have value >= 100)
        0x60, 0x0E, // PUSH1 14 (jump to first branch)
        0x57, // JUMPI

        // Else branch: result = value
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x00, // STOP

        // First branch (offset 14)
        0x5b, // JUMPDEST
        0x80, // DUP1
        0x60, 0xC8, // PUSH1 200
        0x11, // GT
        0x60, 0x1E, // PUSH1 30 (jump to > 200 branch)
        0x57, // JUMPI

        // 100 <= value <= 200: result = value * 2
        0x60, 0x02, // PUSH1 2
        0x02, // MUL
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x00, // STOP

        // > 200 branch (offset 30)
        0x5b, // JUMPDEST
        0x60, 0x32, // PUSH1 50
        0x01, // ADD
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x00, // STOP
    };

    // Create addresses
    const contract_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = Address.from_u256(0x1111111111111111111111111111111111111111);

    // Calculate code hash
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(&code);
    var code_hash: [32]u8 = undefined;
    hasher.final(&code_hash);

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
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Execute the contract logic step by step
    // We'll test with value = 150, which should result in 300 (150 * 2)

    // Push 150
    frame.pc = 0;
    const interpreter1: Operation.Interpreter = &vm;
    const state1: Operation.State = &frame;
    _ = try vm.table.execute(frame.pc, &interpreter1, state1, 0x60);
    frame.pc = 2;

    // DUP1
    const interpreter2: Operation.Interpreter = &vm;
    const state2: Operation.State = &frame;
    _ = try vm.table.execute(frame.pc, &interpreter2, state2, 0x80);
    frame.pc = 3;

    // Push 100
    frame.pc = 3;
    const interpreter3: Operation.Interpreter = &vm;
    const state3: Operation.State = &frame;
    _ = try vm.table.execute(frame.pc, &interpreter3, state3, 0x60);
    frame.pc = 5;

    // LT
    const interpreter4: Operation.Interpreter = &vm;
    const state4: Operation.State = &frame;
    _ = try vm.table.execute(frame.pc, &interpreter4, &state4, 0x10);
    frame.pc = 6;

    // ISZERO
    const interpreter5: Operation.Interpreter = &vm;
    const state5: Operation.State = &frame;
    _ = try vm.table.execute(frame.pc, &interpreter5, &state5, 0x15);
    frame.pc = 7;

    // Push jump destination
    frame.pc = 7;
    const interpreter6: Operation.Interpreter = &vm;
    const state6: Operation.State = &frame;
    _ = try vm.table.execute(frame.pc, &interpreter6, &state6, 0x60);
    frame.pc = 9;

    // JUMPI (should jump to 14)
    const interpreter7: Operation.Interpreter = &vm;
    const state7: Operation.State = &frame;
    _ = try vm.table.execute(frame.pc, &interpreter7, &state7, 0x57);
    try testing.expectEqual(@as(usize, 14), frame.pc);

    // Continue execution from JUMPDEST at 14
    frame.pc = 15; // Skip JUMPDEST

    // DUP1
    const interpreter8: Operation.Interpreter = &vm;
    const state8: Operation.State = &frame;
    _ = try vm.table.execute(frame.pc, &interpreter8, &state8, 0x80);
    frame.pc = 16;

    // Push 200
    frame.pc = 16;
    const interpreter9: Operation.Interpreter = &vm;
    const state9: Operation.State = &frame;
    _ = try vm.table.execute(frame.pc, &interpreter9, &state9, 0x60);
    frame.pc = 18;

    // GT
    const interpreter10: Operation.Interpreter = &vm;
    const state10: Operation.State = &frame;
    _ = try vm.table.execute(frame.pc, &interpreter10, state10, 0x11);
    const gt_result = frame.stack.peek_n(0) catch unreachable;
    try testing.expectEqual(@as(u256, 0), gt_result); // 150 > 200 is false
    frame.pc = 19;

    // Push jump destination
    frame.pc = 19;
    const interpreter11: Operation.Interpreter = &vm;
    const state11: Operation.State = &frame;
    _ = try vm.table.execute(frame.pc, &interpreter11, state11, 0x60);
    frame.pc = 21;

    // JUMPI (should not jump)
    const interpreter12: Operation.Interpreter = &vm;
    const state12: Operation.State = &frame;
    _ = try vm.table.execute(frame.pc, &interpreter12, state12, 0x57);
    try testing.expectEqual(@as(usize, 21), frame.pc); // No jump

    // Continue with multiplication
    frame.pc = 22;

    // Push 2
    frame.pc = 22;
    const interpreter13: Operation.Interpreter = &vm;
    const state13: Operation.State = &frame;
    _ = try vm.table.execute(frame.pc, &interpreter13, state13, 0x60);
    frame.pc = 24;

    // MUL
    const interpreter14: Operation.Interpreter = &vm;
    const state14: Operation.State = &frame;
    _ = try vm.table.execute(frame.pc, &interpreter14, state14, 0x02);
    const mul_result = frame.stack.peek_n(0) catch unreachable;
    try testing.expectEqual(@as(u256, 300), mul_result); // 150 * 2

    // Store result
    frame.pc = 25;
    try frame.stack.append(0); // offset
    const interpreter15: Operation.Interpreter = &vm;
    const state15: Operation.State = &frame;
    _ = try vm.table.execute(frame.pc, &interpreter15, state15, 0x52);

    // Verify result in memory
    try frame.stack.append(0);
    const interpreter16: Operation.Interpreter = &vm;
    const state16: Operation.State = &frame;
    _ = try vm.table.execute(frame.pc, &interpreter16, state16, 0x51);
    const memory_result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 300), memory_result);
}

test "Integration: Gas metering across operations" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create addresses
    const contract_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = Address.from_u256(0x1111111111111111111111111111111111111111);
    const charlie_address = Address.from_u256(0x4444444444444444444444444444444444444444);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

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
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;
    var total_gas_used: u64 = 0;

    // 1. Arithmetic operations
    try frame.stack.append(20); // b
    try frame.stack.append(10); // a
    const interpreter1: Operation.Interpreter = &vm;
    const state1: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter1, state1, 0x01);
    total_gas_used += initial_gas - frame.gas_remaining;

    // 2. Memory operation
    try frame.stack.append(0); // offset
    const gas_before_mstore = frame.gas_remaining;
    const interpreter2: Operation.Interpreter = &vm;
    const state2: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter2, state2, 0x52);
    const mstore_gas = gas_before_mstore - frame.gas_remaining;
    total_gas_used += mstore_gas;
    try testing.expect(mstore_gas > 3); // Should include memory expansion

    // 3. Storage operation (cold)
    const slot: u256 = 999;
    try frame.stack.append(slot);
    const gas_before_sload = frame.gas_remaining;
    const interpreter3: Operation.Interpreter = &vm;
    const state3: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter3, state3, 0x54);
    const sload_gas = gas_before_sload - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 2100), sload_gas); // Cold access
    total_gas_used += sload_gas;

    // 4. SHA3 with data
    frame.stack.clear();
    try frame.stack.append(0); // offset
    try frame.stack.append(32); // size
    const gas_before_sha3 = frame.gas_remaining;
    const interpreter4: Operation.Interpreter = &vm;
    const state4: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter4, &state4, 0x20);
    const sha3_gas = gas_before_sha3 - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 30 + 6), sha3_gas); // Base + 1 word
    total_gas_used += sha3_gas;

    // 5. Environment operation (cold address)
    frame.stack.clear();
    const cold_address = Address.to_u256(charlie_address);
    try frame.stack.append(cold_address);
    const gas_before_balance = frame.gas_remaining;
    const interpreter5: Operation.Interpreter = &vm;
    const state5: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter5, &state5, 0x31);
    const balance_gas = gas_before_balance - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 2600), balance_gas); // Cold address
    total_gas_used += balance_gas;

    // Verify total gas consumption
    try testing.expectEqual(total_gas_used, initial_gas - frame.gas_remaining);
}

test "Integration: Error propagation and recovery" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create addresses
    const contract_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = Address.from_u256(0x1111111111111111111111111111111111111111);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        1000,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Test 1: Stack underflow recovery
    const div_result = opcodes.arithmetic.op_div(0, &vm, &frame);
    try testing.expectError(ExecutionError.Error.StackUnderflow, div_result);

    // Stack should still be usable
    try frame.stack.append(5); // b
    try frame.stack.append(10); // a
    const interpreter1: Operation.Interpreter = &vm;
    const state1: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter1, state1, 0x04);
    const div_value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 2), div_value);

    // Test 2: Out of gas recovery
    frame.stack.clear();
    frame.gas_remaining = 50; // Very low gas

    // Try expensive operation
    try frame.stack.append(999); // Cold storage slot
    const sload_result = opcodes.storage.op_sload(0, &vm, &frame);
    try testing.expectError(ExecutionError.Error.OutOfGas, sload_result);

    // Test 3: Invalid jump recovery
    frame.stack.clear();
    frame.gas_remaining = 10000; // Reset gas

    try frame.stack.append(999); // Invalid jump destination
    const jump_result = opcodes.control.op_jump(0, &vm, &frame);
    try testing.expectError(ExecutionError.Error.InvalidJump, jump_result);

    // Test 4: Write protection in static context
    frame.stack.clear();
    frame.is_static = true;

    try frame.stack.append(0); // slot
    try frame.stack.append(42); // value
    const sstore_result = opcodes.storage.op_sstore(0, &vm, &frame);
    try testing.expectError(ExecutionError.Error.WriteProtection, sstore_result);

    // Reset static flag and verify normal operation works
    frame.is_static = false;
    frame.stack.clear();
    try frame.stack.append(0); // slot
    try frame.stack.append(42); // value
    const interpreter2: Operation.Interpreter = &vm;
    const state2: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter2, state2, 0x55);

    // Verify storage was updated
    const storage_key = evm.evm.StorageKey{ .address = contract_address, .slot = 0 };
    const stored_value = vm.storage.get(storage_key) orelse 0;
    try testing.expectEqual(@as(u256, 42), stored_value);
}
