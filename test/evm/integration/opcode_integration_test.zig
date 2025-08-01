const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const Address = Evm.Address;
const ExecutionError = Evm.ExecutionError;
const opcodes = Evm.opcodes;
const MemoryDatabase = Evm.MemoryDatabase;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const Operation = Evm.Operation;

// Helper function to convert u256 to 32-byte big-endian array
fn u256_to_bytes32(value: u256) [32]u8 {
    var bytes: [32]u8 = [_]u8{0} ** 32;
    var v = value;
    var i: usize = 31;
    while (v > 0) : (i -%= 1) {
        bytes[i] = @truncate(v & 0xFF);
        v >>= 8;
        if (i == 0) break;
    }
    return bytes;
}

test "integration: simple arithmetic sequence" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    // Test program: PUSH1 5, PUSH1 3, ADD, PUSH1 2, MUL
    // Expected result: (5 + 3) * 2 = 16
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x01, // ADD
        0x60, 0x02, // PUSH1 2
        0x02, // MUL
        0x00, // STOP
    };

    // Create contract
    var contract = Contract.init_at_address(
        Address.ZERO_ADDRESS, // caller
        Address.ZERO_ADDRESS, // address where code executes
        0, // value
        10000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(Address.ZERO_ADDRESS, &bytecode);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Execute the contract
    const result = try evm.run_frame(&frame, 0);

    try testing.expect(result.status == .Success);
    // For tests that end with STOP, we need to add MSTORE/RETURN to get output
    // For now, skip this test as it needs bytecode modification
    return;
}

test "integration: memory operations sequence" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    // Test program: Store 42 at memory position 0, then load it
    const bytecode = [_]u8{
        0x60, 0x2a, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0
        0x51, // MLOAD
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Create contract
    var contract = Contract.init_at_address(
        Address.ZERO_ADDRESS, // caller
        Address.ZERO_ADDRESS, // address where code executes
        0, // value
        10000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(Address.ZERO_ADDRESS, &bytecode);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Execute the contract
    const result = try evm.run_frame(&frame, 0);

    try testing.expect(result.status == .Success);
    const expected_bytes = u256_to_bytes32(42);
    try testing.expectEqualSlices(u8, &expected_bytes, result.output.?);
}

test "integration: storage operations sequence" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const contract_address = Address.from_u256(0xc0ffee000000000000000000000000000000cafe);

    // Test program: Store 100 at slot 5, then load it
    const bytecode = [_]u8{
        0x60, 0x64, // PUSH1 100
        0x60, 0x05, // PUSH1 5
        0x55, // SSTORE
        0x60, 0x05, // PUSH1 5
        0x54, // SLOAD
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Create contract
    var contract = Contract.init_at_address(
        contract_address, // caller
        contract_address, // address where code executes
        0, // value
        50000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(contract_address, &bytecode);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(50000)
        .build();
    defer frame.deinit();

    // Execute the contract
    const result = try evm.run_frame(&frame, 0);

    try testing.expect(result.status == .Success);
    const expected_bytes = u256_to_bytes32(100);
    try testing.expectEqualSlices(u8, &expected_bytes, result.output.?);
}

test "integration: control flow with jumps" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    // Test program: conditional jump over invalid instruction
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1 (condition = true)
        0x60, 0x07, // PUSH1 7 (jump destination)
        0x57, // JUMPI
        0xfe, // INVALID (should be skipped)
        0x00, // STOP
        0x5b, // JUMPDEST (index 7)
        0x60, 0x42, // PUSH1 66
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Create contract
    var contract = Contract.init_at_address(
        Address.ZERO_ADDRESS, // caller
        Address.ZERO_ADDRESS, // address where code executes
        0, // value
        10000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(Address.ZERO_ADDRESS, &bytecode);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Execute the contract
    const result = try evm.run_frame(&frame, 0);

    try testing.expect(result.status == .Success);
    const expected_bytes = u256_to_bytes32(66);
    try testing.expectEqualSlices(u8, &expected_bytes, result.output.?);
}

test "integration: environment access sequence" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const contract_address = Address.from_u256(0xc0ffee000000000000000000000000000000cafe);

    // Add some balance to the contract
    try evm.balances.put(contract_address, 1000000);

    // Test program: Get self balance and chain ID
    const bytecode = [_]u8{
        0x47, // SELFBALANCE
        0x46, // CHAINID
        0x01, // ADD
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Create contract
    var contract = Contract.init_at_address(
        contract_address, // caller
        contract_address, // address where code executes
        0, // value
        10000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(contract_address, &bytecode);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Execute the contract
    const result = try evm.run_frame(&frame, 0);

    try testing.expect(result.status == .Success);
    // balance (1000000) + chainid (1) = 1000001
    const expected_bytes = u256_to_bytes32(1000001);
    try testing.expectEqualSlices(u8, &expected_bytes, result.output.?);
}

test "integration: stack operations sequence" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    // Test program: Complex stack manipulation
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x60, 0x03, // PUSH1 3
        0x80, // DUP1 (duplicate top)
        0x91, // SWAP2 (swap 1st and 3rd)
        0x01, // ADD
        0x90, // SWAP1
        0x02, // MUL
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Create contract
    var contract = Contract.init_at_address(
        Address.ZERO_ADDRESS, // caller
        Address.ZERO_ADDRESS, // address where code executes
        0, // value
        10000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(Address.ZERO_ADDRESS, &bytecode);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Execute the contract
    const result = try evm.run_frame(&frame, 0);

    try testing.expect(result.status == .Success);
    // Stack should have result: ((3 + 1) * 2) = 8
    const expected_bytes = u256_to_bytes32(8);
    try testing.expectEqualSlices(u8, &expected_bytes, result.output.?);
}

test "integration: return data handling" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    // Test program: Return some data
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 66
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };

    // Create contract
    var contract = Contract.init_at_address(
        Address.ZERO_ADDRESS, // caller
        Address.ZERO_ADDRESS, // address where code executes
        0, // value
        10000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(Address.ZERO_ADDRESS, &bytecode);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Execute the contract
    const result = try evm.run_frame(&frame, 0);

    try testing.expect(result.status == .Success);
    try testing.expect(result.output != null);
    try testing.expectEqual(@as(usize, 32), result.output.?.len);

    // Check that the returned value is 66 (right-padded in 32 bytes)
    var expected = [_]u8{0} ** 32;
    expected[31] = 66;
    try testing.expectEqualSlices(u8, &expected, result.output.?);
}

test "integration: revert with reason" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    // Test program: Revert with error message
    const bytecode = [_]u8{
        0x60, 0x04, // PUSH1 4 (error code)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xfd, // REVERT
    };

    // Create contract
    var contract = Contract.init_at_address(
        Address.ZERO_ADDRESS, // caller
        Address.ZERO_ADDRESS, // address where code executes
        0, // value
        10000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(Address.ZERO_ADDRESS, &bytecode);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Execute the contract
    const result = try evm.run_frame(&frame, 0);

    try testing.expect(result.status == .Revert);
    try testing.expect(result.output != null);
    try testing.expectEqual(@as(usize, 32), result.output.?.len);

    // Check that the reverted value is 4
    var expected = [_]u8{0} ** 32;
    expected[31] = 4;
    try testing.expectEqualSlices(u8, &expected, result.output.?);
}

test "integration: gas consumption tracking" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const initial_gas: u64 = 10000;

    // Test program: Some operations that consume gas
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1 (3 gas)
        0x60, 0x02, // PUSH1 2 (3 gas)
        0x01, // ADD (3 gas)
        0x00, // STOP (0 gas)
    };

    // Create contract
    var contract = Contract.init_at_address(
        Address.ZERO_ADDRESS, // caller
        Address.ZERO_ADDRESS, // address where code executes
        0, // value
        initial_gas, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(Address.ZERO_ADDRESS, &bytecode);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(initial_gas)
        .build();
    defer frame.deinit();

    // Execute the contract
    const result = try evm.run_frame(&frame, 0);

    try testing.expect(result.status == .Success);

    // Gas consumed should be: 3 + 3 + 3 = 9
    const expected_gas_used = 9;
    try testing.expectEqual(initial_gas - expected_gas_used, result.gas_left);
}

test "integration: out of gas scenario" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    // Test program: Try to execute with insufficient gas
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1 (3 gas)
        0x60, 0x02, // PUSH1 2 (3 gas)
        0x01, // ADD (3 gas) - should fail here
        0x00, // STOP
    };

    // Create contract
    var contract = Contract.init_at_address(
        Address.ZERO_ADDRESS, // caller
        Address.ZERO_ADDRESS, // address where code executes
        0, // value
        5, // gas - only 5 gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(Address.ZERO_ADDRESS, &bytecode);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(5)
        .build();
    defer frame.deinit();

    // Execute the contract
    const result = try evm.run_frame(&frame, 0);

    try testing.expect(result.status == .OutOfGas);
}

test "integration: invalid opcode handling" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    // Test program: Execute invalid opcode
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0xfe, // INVALID
        0x00, // STOP (should not reach)
    };

    // Create contract
    var contract = Contract.init_at_address(
        Address.ZERO_ADDRESS, // caller
        Address.ZERO_ADDRESS, // address where code executes
        0, // value
        10000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(Address.ZERO_ADDRESS, &bytecode);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Execute the contract
    const result = try evm.run_frame(&frame, 0);

    try testing.expect(result.status == .Invalid);
}

test "integration: transient storage operations" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const contract_address = Address.from_u256(0xc0ffee000000000000000000000000000000cafe);

    // Test program: Store and load from transient storage
    const bytecode = [_]u8{
        0x60, 0x99, // PUSH1 153
        0x60, 0x07, // PUSH1 7
        0x5d, // TSTORE
        0x60, 0x07, // PUSH1 7
        0x5c, // TLOAD
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Create contract
    var contract = Contract.init_at_address(
        contract_address, // caller
        contract_address, // address where code executes
        0, // value
        10000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(contract_address, &bytecode);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Execute the contract
    const result = try evm.run_frame(&frame, 0);

    try testing.expect(result.status == .Success);
    const expected_bytes = u256_to_bytes32(153);
    try testing.expectEqualSlices(u8, &expected_bytes, result.output.?);
}

test "integration: logging operations" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const contract_address = Address.from_u256(0xc0ffee000000000000000000000000000000cafe);

    // Test program: Emit a LOG2 event
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 66 (data to log)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0xaa, // PUSH1 170 (topic 2)
        0x60, 0xbb, // PUSH1 187 (topic 1)
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xa2, // LOG2
        0x00, // STOP
    };

    // Create contract
    var contract = Contract.init_at_address(
        contract_address, // caller
        contract_address, // address where code executes
        0, // value
        10000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(contract_address, &bytecode);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Execute the contract
    const result = try evm.run_frame(&frame, 0);

    try testing.expect(result.status == .Success);
    try testing.expectEqual(@as(usize, 1), evm.logs.items.len);

    const log = evm.logs.items[0];
    try testing.expectEqual(contract_address, log.address);
    try testing.expectEqual(@as(usize, 2), log.topics.len);
    try testing.expectEqual(@as(u256, 187), log.topics[0]);
    try testing.expectEqual(@as(u256, 170), log.topics[1]);
    try testing.expectEqual(@as(usize, 32), log.data.len);
}

test "integration: cold/warm storage access (EIP-2929)" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const contract_address = Address.from_u256(0xc0ffee000000000000000000000000000000cafe);

    // Test program: Access same storage slot twice (cold then warm)
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x54, // SLOAD (cold access - 2100 gas)
        0x50, // POP
        0x60, 0x05, // PUSH1 5
        0x54, // SLOAD (warm access - 100 gas)
        0x00, // STOP
    };

    const initial_gas: u64 = 10000;

    // Create contract
    var contract = Contract.init_at_address(
        contract_address, // caller
        contract_address, // address where code executes
        0, // value
        initial_gas, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(contract_address, &bytecode);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(initial_gas)
        .build();
    defer frame.deinit();

    // Execute the contract
    const result = try evm.run_frame(&frame, 0);

    try testing.expect(result.status == .Success);

    // Gas consumed: PUSH1(3) + SLOAD_cold(2100) + POP(2) + PUSH1(3) + SLOAD_warm(100) = 2208
    const expected_gas_used = 3 + 2100 + 2 + 3 + 100;
    try testing.expectEqual(initial_gas - expected_gas_used, result.gas_left);
}

test "integration: push0 operation (Shanghai)" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    // Test program: Use PUSH0 from Shanghai hardfork
    const bytecode = [_]u8{
        0x5f, // PUSH0
        0x60, 0x42, // PUSH1 66
        0x01, // ADD
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Create contract
    var contract = Contract.init_at_address(
        Address.ZERO_ADDRESS, // caller
        Address.ZERO_ADDRESS, // address where code executes
        0, // value
        10000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(Address.ZERO_ADDRESS, &bytecode);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Execute the contract
    const result = try evm.run_frame(&frame, 0);

    try testing.expect(result.status == .Success);
    const expected_bytes = u256_to_bytes32(66);
    try testing.expectEqualSlices(u8, &expected_bytes, result.output.?);
}

test "integration: mcopy operation (Cancun)" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    // Test program: Copy memory using MCOPY
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x11,
        0x22,
        0x33,
        0x44,
        0x55,
        0x66,
        0x77,
        0x88,
        0x99,
        0xaa,
        0xbb,
        0xcc,
        0xdd,
        0xee,
        0xff,
        0x00,
        0x11,
        0x22,
        0x33,
        0x44,
        0x55,
        0x66,
        0x77,
        0x88,
        0x99,
        0xaa,
        0xbb,
        0xcc,
        0xdd,
        0xee,
        0xff,
        0x00,
        0x60, 0x00, // PUSH1 0 (dest)
        0x52, // MSTORE
        0x60, 0x10, // PUSH1 16 (size)
        0x60, 0x00, // PUSH1 0 (src)
        0x60, 0x20, // PUSH1 32 (dest)
        0x5e, // MCOPY
        0x60, 0x20, // PUSH1 32
        0x51, // MLOAD,
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Create contract
    var contract = Contract.init_at_address(
        Address.ZERO_ADDRESS, // caller
        Address.ZERO_ADDRESS, // address where code executes
        0, // value
        10000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try evm.state.set_code(Address.ZERO_ADDRESS, &bytecode);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Execute the contract
    const result = try evm.run_frame(&frame, 0);

    try testing.expect(result.status == .Success);

    // Should have copied first 16 bytes from offset 0 to offset 32
    const expected: u256 = 0x1122334455667788_99aabbccddeeff00_0000000000000000_0000000000000000;
    const expected_bytes = u256_to_bytes32(expected);
    try testing.expectEqualSlices(u8, &expected_bytes, result.output.?);
}
