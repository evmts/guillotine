const std = @import("std");
const testing = std.testing;

// Import opcodes to test
const Evm = @import("evm");
const CallParams = Evm.Host.CallParams;
const CallResult = Evm.CallResult;
// Updated to new API - migration in progress, tests not run yet

test "SELFDESTRUCT: Basic functionality" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    // Create contract
    const contract_address = Evm.Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{1});
    const caller_address = Evm.Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{2});
    var contract = try Evm.Contract.init(
        allocator,
        null,
        10000,
        contract_address,
        contract_address,
        caller_address,
        0,
        &[_]u8{},
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Set contract balance
    try evm.state.set_balance(contract_address, 1000);

    // Push recipient address to stack
    const bob_address = Evm.Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{3});
    try frame.stack.push(bob_address.to_u256());

    // Execute SELFDESTRUCT opcode - should halt execution
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    const result = evm.jump_table.get(0xFF).execute(&interpreter, &state);
    try testing.expectError(Evm.ExecutionError.Error.STOP, result);

    // Stack should be empty after consuming recipient address
    try testing.expectEqual(@as(usize, 0), frame.stack.size);

    // Contract should be marked for destruction
    try testing.expect(evm.state.is_marked_for_destruction(contract_address));

    // Recipient should be correct
    const recipient = evm.state.get_destruction_recipient(contract_address);
    try testing.expect(recipient != null);
    try testing.expect(recipient.?.eql(bob_address));
}

test "SELFDESTRUCT: Forbidden in static call" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    // Create contract
    const contract_address = Evm.Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{1});
    const caller_address = Evm.Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{2});
    var contract = try Evm.Contract.init(
        allocator,
        null,
        10000,
        contract_address,
        contract_address,
        caller_address,
        0,
        &[_]u8{},
    );
    defer contract.deinit(allocator, null);

    // Create frame with static call flag
    var frame_builder = Evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .withStaticFlag(true)
        .build();
    defer frame.deinit();

    // Push recipient address to stack
    const bob_address = Evm.Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{3});
    try frame.stack.push(bob_address.to_u256());

    // Execute SELFDESTRUCT opcode - should fail in static context
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    const result = evm.jump_table.get(0xFF).execute(&interpreter, &state);
    try testing.expectError(Evm.ExecutionError.Error.WriteProtection, result);

    // Contract should NOT be marked for destruction
    try testing.expect(!evm.state.is_marked_for_destruction(contract_address));
}

test "SELFDESTRUCT: Gas costs by hardfork" {
    const allocator = testing.allocator;

    // Test Frontier: 0 gas
    {
        // Create memory database
        var memory_db = Evm.Database.Memory.init(allocator);
        defer memory_db.deinit();

        // Create EVM instance with Frontier hardfork
        const db_interface = memory_db.to_database_interface();
        var evm = try Evm.init(allocator, db_interface, null, null, null, null);

        defer evm.deinit();
        evm.hardfork = .FRONTIER;

        // Create contract
        const contract_address = Evm.Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{1});
        const caller_address = Evm.Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{2});
        var contract = try Evm.Contract.init(
            allocator,
            null,
            10000,
            contract_address,
            contract_address,
            caller_address,
            0,
            &[_]u8{},
        );
        defer contract.deinit(allocator, null);

        // Create frame
        var frame_builder = Evm.Frame.builder(allocator);
        var frame = try frame_builder
            .withVm(&evm)
            .withContract(&contract)
            .withGas(10000)
            .build();
        defer frame.deinit();

        // Push recipient address to stack
        const bob_address = Evm.Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{3});
        try frame.stack.push(bob_address.to_u256());

        const gas_before = frame.gas_remaining;

        // Execute SELFDESTRUCT
        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &frame;
        _ = evm.jump_table.get(0xFF).execute(&interpreter, &state);

        // Should consume 0 gas in Frontier (plus any access list costs)
        const gas_consumed = gas_before - frame.gas_remaining;
        // Note: actual gas might include access list costs, so we check it's reasonable
        try testing.expect(gas_consumed < 3000); // Should be much less than Tangerine Whistle
    }

    // Test Tangerine Whistle: 5000 gas base
    {
        // Create memory database
        var memory_db = Evm.Database.Memory.init(allocator);
        defer memory_db.deinit();

        // Create EVM instance with Tangerine Whistle hardfork
        const db_interface = memory_db.to_database_interface();
        var evm = try Evm.init(allocator, db_interface, null, null, null, null);

        defer evm.deinit();
        evm.hardfork = .TANGERINE_WHISTLE;

        // Create contract
        const contract_address = Evm.Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{1});
        const caller_address = Evm.Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{2});
        var contract = try Evm.Contract.init(
            allocator,
            null,
            50000,
            contract_address,
            contract_address,
            caller_address,
            0,
            &[_]u8{},
        );
        defer contract.deinit(allocator, null);

        // Create frame
        var frame_builder = Evm.Frame.builder(allocator);
        var frame = try frame_builder
            .withVm(&evm)
            .withContract(&contract)
            .withGas(50000)
            .build();
        defer frame.deinit();

        // Push recipient address to stack
        const bob_address = Evm.Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{3});
        try frame.stack.push(bob_address.to_u256());

        const gas_before = frame.gas_remaining;

        // Execute SELFDESTRUCT
        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &frame;
        _ = evm.jump_table.get(0xFF).execute(&interpreter, &state);

        const gas_consumed = gas_before - frame.gas_remaining;
        // Should consume 5000 base + access costs
        try testing.expect(gas_consumed >= 5000);
        try testing.expect(gas_consumed < 10000); // Reasonable upper bound
    }
}

test "SELFDESTRUCT: Account creation cost (EIP-161)" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = Evm.Database.Memory.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance with Spurious Dragon hardfork
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();
    evm.hardfork = .SPURIOUS_DRAGON; // First hardfork with EIP-161

    // Create contract
    const contract_address = Evm.Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{1});
    const caller_address = Evm.Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{2});
    var contract = try Evm.Contract.init(
        allocator,
        null,
        50000,
        contract_address,
        contract_address,
        caller_address,
        0,
        &[_]u8{},
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(50000)
        .build();
    defer frame.deinit();

    // Use a fresh address that doesn't exist (no balance, code, or nonce)
    var rng = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    var new_address_bytes: [20]u8 = undefined;
    rng.fill(&new_address_bytes);
    const new_address = Evm.Address.fromBytes(new_address_bytes);

    // Push non-existent recipient address to stack
    try frame.stack.push(new_address.to_u256());

    const gas_before = frame.gas_remaining;

    // Execute SELFDESTRUCT
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = evm.jump_table.get(0xFF).execute(&interpreter, &state);

    const gas_consumed = gas_before - frame.gas_remaining;
    // Should consume 5000 base + 25000 account creation + access costs
    try testing.expect(gas_consumed >= 30000);
    try testing.expect(gas_consumed < 35000); // Reasonable upper bound
}
