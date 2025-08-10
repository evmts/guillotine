const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const CallParams = Evm.Host.CallParams;
const CallResult = Evm.CallResult;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const MemoryDatabase = Evm.MemoryDatabase;
const ExecutionError = Evm.ExecutionError;
// Updated to new API - migration in progress, tests not run yet

// ============================
// 0x30-0x39 Environmental Information Opcodes
// ============================

test "ADDRESS (0x30): Push current contract address" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);

    defer evm.deinit();

    // Create contract with specific address
    const contract_addr = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF } ++ [_]u8{0} ** 12;
    const caller: Address.Address = [_]u8{0x11} ** 20;
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

    // Execute ADDRESS opcode
    _ = try evm.table.execute(0, interpreter, state, 0x30);

    // Check result - address should be zero-extended to u256
    const expected = primitives.Address.to_u256(contract_addr);
    const result = try frame.stack.pop();
    try testing.expectEqual(expected, result);
}

test "BALANCE (0x31): Get account balance" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);

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

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Set balances for test addresses
    const alice_addr: Address.Address = [_]u8{0x11} ** 20;
    const bob_addr: Address.Address = [_]u8{0x22} ** 20;
    const test_balance: u256 = 1_000_000_000_000_000_000; // 1 ETH in wei
    try evm.state.set_balance(alice_addr, test_balance);
    try evm.state.set_balance(bob_addr, test_balance * 2);

    // Test 1: Check ALICE's balance
    try frame.stack.append(primitives.Address.to_u256(alice_addr));
    _ = try evm.table.execute(0, interpreter, state, 0x31);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(test_balance, result1);

    // Test 2: Check BOB's balance
    try frame.stack.append(primitives.Address.to_u256(bob_addr));
    _ = try evm.table.execute(0, interpreter, state, 0x31);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(test_balance * 2, result2);

    // Test 3: Check non-existent account (should return 0)
    const zero_addr = primitives.Address.ZERO_ADDRESS;
    try frame.stack.append(primitives.Address.to_u256(zero_addr));
    _ = try evm.table.execute(0, interpreter, state, 0x31);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result3);
}

test "ORIGIN (0x32): Get transaction origin" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);

    defer evm.deinit();

    // Set transaction origin
    const alice_addr: Address.Address = [_]u8{0x11} ** 20;
    const context = Evm.Context.init_with_values(alice_addr, 0, 0, 0, alice_addr, 0, 0, 1, 0, &[_]u256{}, 0);
    evm.set_context(context);

    const bob_addr: Address.Address = [_]u8{0x22} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        bob_addr, // Caller is different from origin
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

    // Execute ORIGIN opcode
    _ = try evm.table.execute(0, interpreter, state, 0x32);

    // Should push tx_origin (ALICE), not caller (BOB)
    const expected = primitives.Address.to_u256(alice_addr);
    const result = try frame.stack.pop();
    try testing.expectEqual(expected, result);
}

test "CALLER (0x33): Get immediate caller" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);

    defer evm.deinit();

    // Set transaction origin different from caller
    const alice_addr: Address.Address = [_]u8{0x11} ** 20;
    const context = Evm.Context.init_with_values(alice_addr, 0, 0, 0, alice_addr, 0, 0, 1, 0, &[_]u256{}, 0);
    evm.set_context(context);

    const bob_addr: Address.Address = [_]u8{0x22} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        bob_addr, // Immediate caller
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

    // Execute CALLER opcode
    _ = try evm.table.execute(0, interpreter, state, 0x33);

    // Should push caller (BOB), not origin (ALICE)
    const expected = primitives.Address.to_u256(bob_addr);
    const result = try frame.stack.pop();
    try testing.expectEqual(expected, result);
}

test "CALLVALUE (0x34): Get msg.value" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);

    defer evm.deinit();

    const test_cases = [_]u256{
        0, // No value
        1, // 1 wei
        1_000_000_000_000_000_000, // 1 ETH
        std.math.maxInt(u256), // Max value
    };

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    for (test_cases) |value| {
        var contract = Contract.init(
            caller,
            contract_addr,
            value, // Set call value
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

        // Execute CALLVALUE opcode
        _ = try evm.table.execute(0, interpreter, state, 0x34);

        const result = try frame.stack.pop();
        try testing.expectEqual(value, result);
    }
}

test "CALLDATALOAD (0x35): Load 32 bytes from calldata" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);

    defer evm.deinit();

    // Create test calldata
    const calldata = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
        0x21, 0x22, 0x23, 0x24, // Extra bytes
    };

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

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Set calldata in frame
    frame.input = &calldata;

    // Test 1: Load from offset 0
    try frame.stack.append(0);
    _ = try evm.table.execute(0, interpreter, state, 0x35);

    // Expected: first 32 bytes as big-endian u256
    const expected1: u256 = 0x0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20;
    const result1 = try frame.stack.pop();
    try testing.expectEqual(expected1, result1);

    // Test 2: Load from offset 4
    try frame.stack.append(4);
    _ = try evm.table.execute(0, interpreter, state, 0x35);

    const expected2: u256 = 0x05060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F2021222324;
    const result2 = try frame.stack.pop();
    try testing.expectEqual(expected2, result2);

    // Test 3: Load beyond calldata (should pad with zeros)
    try frame.stack.append(32);
    _ = try evm.table.execute(0, interpreter, state, 0x35);

    const expected3: u256 = 0x2122232400000000000000000000000000000000000000000000000000000000;
    const result3 = try frame.stack.pop();
    try testing.expectEqual(expected3, result3);

    // Test 4: Load from very large offset (should return 0)
    try frame.stack.append(std.math.maxInt(u256) - 10);
    _ = try evm.table.execute(0, interpreter, state, 0x35);

    const result4 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result4);
}

test "CALLDATASIZE (0x36): Get calldata size" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);

    defer evm.deinit();

    const test_cases = [_]struct {
        data: []const u8,
        desc: []const u8,
    }{
        .{ .data = &[_]u8{}, .desc = "empty calldata" },
        .{ .data = &[_]u8{0x42}, .desc = "1 byte" },
        .{ .data = &[_]u8{0x00} ** 32, .desc = "32 bytes" },
        .{ .data = &[_]u8{0xFF} ** 100, .desc = "100 bytes" },
    };

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    for (test_cases) |tc| {
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

        // Set calldata
        frame.input = tc.data;

        // Execute CALLDATASIZE
        _ = try evm.table.execute(0, interpreter, state, 0x36);

        const result = try frame.stack.pop();
        try testing.expectEqual(@as(u256, tc.data.len), result);
    }
}

test "CALLDATACOPY (0x37): Copy calldata to memory" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);

    defer evm.deinit();

    const calldata = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
    };

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

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Set calldata
    frame.input = &calldata;

    // Test 1: Copy all calldata to memory at offset 0
    try frame.stack.append(calldata.len); // size (will be popped 3rd)
    try frame.stack.append(0); // data_offset (will be popped 2nd)
    try frame.stack.append(0); // mem_offset (will be popped 1st)
    _ = try evm.table.execute(0, interpreter, state, 0x37);

    // Check memory contents
    const mem_slice1 = try frame.memory.get_slice(0, calldata.len);
    try testing.expectEqualSlices(u8, &calldata, mem_slice1);

    // Test 2: Copy partial calldata to different memory offset
    frame.memory.resize_context(0) catch unreachable;
    try frame.stack.append(8); // size=8 (will be popped 3rd)
    try frame.stack.append(4); // data_offset=4 (will be popped 2nd)
    try frame.stack.append(32); // mem_offset=32 (will be popped 1st)
    _ = try evm.table.execute(0, interpreter, state, 0x37);

    const mem_slice2 = try frame.memory.get_slice(32, 8);
    try testing.expectEqualSlices(u8, calldata[4..12], mem_slice2);

    // Test 3: Copy with data offset beyond calldata (should pad with zeros)
    frame.memory.resize_context(0) catch unreachable;
    try frame.stack.append(8); // size=8 (will be popped 3rd)
    try frame.stack.append(12); // data_offset=12 (will be popped 2nd)
    try frame.stack.append(0); // mem_offset=0 (will be popped 1st)
    _ = try evm.table.execute(0, interpreter, state, 0x37);

    const mem_slice3 = try frame.memory.get_slice(0, 8);
    const expected3 = [_]u8{ 0x0D, 0x0E, 0x0F, 0x10, 0x00, 0x00, 0x00, 0x00 };
    try testing.expectEqualSlices(u8, &expected3, mem_slice3);

    // Test 4: Zero size copy (no-op)
    const gas_before = frame.gas_remaining;
    try frame.stack.append(0); // size=0 (will be popped 3rd)
    try frame.stack.append(0); // data_offset=0 (will be popped 2nd)
    try frame.stack.append(0); // mem_offset=0 (will be popped 1st)
    _ = try evm.table.execute(0, interpreter, state, 0x37);

    // Should only consume base gas (3)
    try testing.expectEqual(gas_before - 3, frame.gas_remaining);
}

test "CODESIZE (0x38): Get code size" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);

    defer evm.deinit();

    const test_cases = [_]struct {
        code: []const u8,
        desc: []const u8,
    }{
        .{ .code = &[_]u8{}, .desc = "empty code" },
        .{ .code = &[_]u8{ 0x60, 0x00, 0x60, 0x00, 0x01 }, .desc = "5 byte code" },
        .{ .code = &[_]u8{0xFF} ** 100, .desc = "100 byte code" },
    };

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    for (test_cases) |tc| {
        var contract = Contract.init(
            caller,
            contract_addr,
            0,
            1000,
            tc.code,
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

        // Execute CODESIZE
        _ = try evm.table.execute(0, interpreter, state, 0x38);

        const result = try frame.stack.pop();
        try testing.expectEqual(@as(u256, tc.code.len), result);
    }
}

test "CODECOPY (0x39): Copy code to memory" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x60, 0x01, // PUSH1 1
        0x01, // ADD
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE
        0x00, // STOP
    };

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
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
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Copy all code to memory
    try frame.stack.append(code.len); // size (will be popped 3rd)
    try frame.stack.append(0); // code_offset (will be popped 2nd)
    try frame.stack.append(0); // mem_offset (will be popped 1st)
    _ = try evm.table.execute(0, interpreter, state, 0x39);

    const mem_slice1 = try frame.memory.get_slice(0, code.len);
    try testing.expectEqualSlices(u8, &code, mem_slice1);

    // Test 2: Copy partial code
    frame.memory.resize_context(0) catch unreachable;
    try frame.stack.append(4); // size=4 (will be popped 3rd)
    try frame.stack.append(2); // code_offset=2 (will be popped 2nd)
    try frame.stack.append(10); // mem_offset=10 (will be popped 1st)
    _ = try evm.table.execute(0, interpreter, state, 0x39);

    const mem_slice2 = try frame.memory.get_slice(10, 4);
    try testing.expectEqualSlices(u8, code[2..6], mem_slice2);

    // Test 3: Copy beyond code size (should pad with zeros)
    frame.memory.resize_context(0) catch unreachable;
    try frame.stack.append(10); // size=10 (will be popped 3rd)
    try frame.stack.append(5); // code_offset=5 (will be popped 2nd)
    try frame.stack.append(0); // mem_offset=0 (will be popped 1st)
    _ = try evm.table.execute(0, interpreter, state, 0x39);

    const mem_slice3 = try frame.memory.get_slice(0, 10);
    var expected: [10]u8 = undefined;
    const remaining = code.len - 5; // 9 - 5 = 4 bytes remaining
    @memcpy(expected[0..remaining], code[5..]);
    @memset(expected[remaining..], 0x00);
    try testing.expectEqualSlices(u8, &expected, mem_slice3);
}

test "GASPRICE (0x3A): Get gas price" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);

    defer evm.deinit();

    const test_prices = [_]u256{
        0, // Zero gas price (possible in some contexts)
        1_000_000_000, // 1 Gwei
        20_000_000_000, // 20 Gwei (typical)
        100_000_000_000, // 100 Gwei (high)
        std.math.maxInt(u256), // Max possible
    };

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    for (test_prices) |price| {
        // Create context with test values
        const alice_addr: Address.Address = [_]u8{0x11} ** 20;
        const context = Evm.Context.init_with_values(alice_addr, price, 0, 0, alice_addr, 0, 0, 1, 0, &[_]u256{}, 0);
        evm.set_context(context);

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

        // Execute GASPRICE
        _ = try evm.table.execute(0, interpreter, state, 0x3A);

        const result = try frame.stack.pop();
        try testing.expectEqual(price, result);
    }
}

// ============================
// Gas consumption tests
// ============================

test "Environmental opcodes: Gas consumption" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{ 0x60, 0x00 }; // Simple code
    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
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
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const simple_opcodes = [_]struct {
        opcode: u8,
        name: []const u8,
        expected_gas: u64,
    }{
        .{ .opcode = 0x30, .name = "ADDRESS", .expected_gas = 2 },
        .{ .opcode = 0x32, .name = "ORIGIN", .expected_gas = 2 },
        .{ .opcode = 0x33, .name = "CALLER", .expected_gas = 2 },
        .{ .opcode = 0x34, .name = "CALLVALUE", .expected_gas = 2 },
        .{ .opcode = 0x36, .name = "CALLDATASIZE", .expected_gas = 2 },
        .{ .opcode = 0x38, .name = "CODESIZE", .expected_gas = 2 },
        .{ .opcode = 0x3A, .name = "GASPRICE", .expected_gas = 2 },
    };

    for (simple_opcodes) |op| {
        frame.stack.clear();
        const gas_before = 1000;
        frame.gas_remaining = gas_before;

        _ = try evm.table.execute(0, interpreter, state, op.opcode);

        const gas_used = gas_before - frame.gas_remaining;
        try testing.expectEqual(op.expected_gas, gas_used);
    }
}

// ============================
// Edge cases and error conditions
// ============================

test "Environmental opcodes: Stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);

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

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Opcodes that require stack arguments
    const stack_opcodes = [_]u8{
        0x31, // BALANCE - needs 1 arg
        0x35, // CALLDATALOAD - needs 1 arg
        0x37, // CALLDATACOPY - needs 3 args
        0x39, // CODECOPY - needs 3 args
    };

    for (stack_opcodes) |opcode| {
        frame.stack.clear();

        const result = evm.table.execute(0, interpreter, state, opcode);
        try testing.expectError(ExecutionError.Error.StackUnderflow, result);
    }
}

test "Environmental opcodes: Memory expansion limits" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{0x00}; // Minimal code
    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
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
        .withGas(100)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test CODECOPY with huge memory offset
    const huge_offset = 1_000_000;
    try frame.stack.append(huge_offset); // mem_offset=huge
    try frame.stack.append(0); // code_offset=0
    try frame.stack.append(32); // size=32

    const result = evm.table.execute(0, interpreter, state, 0x39);
    try testing.expectError(ExecutionError.Error.OutOfGas, result);
}

test "BALANCE: EIP-2929 cold/warm account access" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);

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

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const bob_addr: Address.Address = [_]u8{0x22} ** 20;

    // First access to an address should be cold (2600 gas)
    try frame.stack.append(primitives.Address.to_u256(bob_addr));
    const gas_before_cold = frame.gas_remaining;
    _ = try evm.table.execute(0, interpreter, state, 0x31);
    const gas_cold = gas_before_cold - frame.gas_remaining;

    // Second access should be warm (100 gas)
    _ = try frame.stack.pop();
    try frame.stack.append(primitives.Address.to_u256(bob_addr));
    const gas_before_warm = frame.gas_remaining;
    _ = try evm.table.execute(0, interpreter, state, 0x31);
    const gas_warm = gas_before_warm - frame.gas_remaining;

    // Cold access should cost more than warm
    try testing.expect(gas_cold > gas_warm);
    try testing.expectEqual(@as(u64, 2600), gas_cold);
    try testing.expectEqual(@as(u64, 100), gas_warm);
}
