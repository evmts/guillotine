const std = @import("std");
const Evm = @import("evm");
const JumpTable = Evm.JumpTable;
const Operation = Evm.Operation;
const OperationModule = Evm.OperationModule;
const Stack = Evm.Stack;
const Frame = Evm.Frame;
const Contract = Evm.Contract;
const MemoryDatabase = Evm.MemoryDatabase;
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const execution = Evm.execution;
const gas_constants = Evm.gas_constants;
const testing = std.testing;
const Vm = Evm.Evm;
const Context = Evm.Context;

test {
    // std.testing.log_level = .debug;
}

test "JumpTable basic operations" {
    const jt = JumpTable.init_from_hardfork(.FRONTIER);

    // Test a couple of operations
    const stop_op = jt.get_operation(0x00);
    try std.testing.expectEqual(@as(u64, 0), stop_op.constant_gas);

    const add_op = jt.get_operation(0x01);
    try std.testing.expectEqual(@as(u64, gas_constants.GasFastestStep), add_op.constant_gas);

    // Test an undefined operation
    const undef_op = jt.get_operation(0xef);
    try std.testing.expect(undef_op.undefined);
}

test "JumpTable initialization and validation" {
    const jt = JumpTable.init();
    try std.testing.expectEqual(@as(usize, 256), jt.table.len);

    // Check that all entries are initially set to NULL_OPERATION
    for (0..256) |i| {
        const entry = jt.table[i];
        // All entries should point to NULL_OPERATION (which has undefined=true)
        try std.testing.expectEqual(true, entry.undefined);
    }

    // Validate should check for invalid configurations
    var mutable_jt = jt;
    mutable_jt.validate();

    // After validation, all entries should still be valid operations
    for (0..256) |i| {
        const entry = mutable_jt.table[i];
        // Entry is always non-null now
        try std.testing.expectEqual(true, entry.undefined);
    }
}

test "JumpTable gas constants" {
    try std.testing.expectEqual(@as(u64, 2), gas_constants.GasQuickStep);
    try std.testing.expectEqual(@as(u64, 3), gas_constants.GasFastestStep);
    try std.testing.expectEqual(@as(u64, 5), gas_constants.GasFastStep);
    try std.testing.expectEqual(@as(u64, 8), gas_constants.GasMidStep);
    try std.testing.expectEqual(@as(u64, 10), gas_constants.GasSlowStep);
    try std.testing.expectEqual(@as(u64, 20), gas_constants.GasExtStep);

    try std.testing.expectEqual(@as(u64, 30), gas_constants.Keccak256Gas);
    try std.testing.expectEqual(@as(u64, 375), gas_constants.LogGas);
    try std.testing.expectEqual(@as(u64, 32000), gas_constants.CreateGas);
}

test "JumpTable basic initialization" {
    // Test minimal jump table functionality without VM
    const jt = JumpTable.init_from_hardfork(.FRONTIER);

    // Verify the jump table was created
    try std.testing.expect(jt.table.len == 256);

    // Test a basic operation lookup
    const add_op = jt.get_operation(0x01);
    try std.testing.expect(!add_op.undefined);
}

test "Manual VM.init reproduction" {
    // Manually reproduce VM.init steps to isolate the ARM64 issue
    std.log.debug("=== Manual VM.init reproduction ===", .{});

    const test_allocator = testing.allocator;

    // Step 1: Database setup (we know this works)
    std.log.debug("Step 1: Setting up database", .{});
    var memory_db = MemoryDatabase.init(test_allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    std.log.debug("Step 1: Database setup complete", .{});

    // Step 2: EvmMemoryAllocator (we know this works individually)
    std.log.debug("Step 2: Setting up EvmMemoryAllocator", .{});
    const EvmMemoryAllocator = @import("evm").memory.EvmMemoryAllocator;
    var evm_allocator = try EvmMemoryAllocator.init(test_allocator);
    defer evm_allocator.deinit();
    const evm_alloc = evm_allocator.allocator();
    std.log.debug("Step 2: EvmMemoryAllocator setup complete", .{});

    // Step 3: EvmState (we know this works individually)
    std.log.debug("Step 3: Setting up EvmState", .{});
    var state = try Evm.EvmState.init(evm_alloc, db_interface);
    defer state.deinit();
    std.log.debug("Step 3: EvmState setup complete", .{});

    // Step 4: Context.init (test this step specifically)
    std.log.debug("Step 4: Setting up Context", .{});
    const context = Context.init();
    _ = context; // Use the context
    std.log.debug("Step 4: Context setup complete", .{});

    // Step 5: AccessList.init (test this step specifically)
    std.log.debug("Step 5: Setting up AccessList", .{});
    // We'll skip this for now since we couldn't import it earlier

    // Step 6: Test static defaults
    std.log.debug("Step 6: Testing static defaults", .{});
    const jump_table = JumpTable.DEFAULT;
    const ChainRules = @import("evm").chain_rules.ChainRules;
    const chain_rules = ChainRules.DEFAULT;
    _ = jump_table;
    _ = chain_rules;
    std.log.debug("Step 6: Static defaults work", .{});

    std.log.debug("Manual VM.init reproduction completed successfully!", .{});
}

test "JumpTable Constantinople opcodes" {
    // Test that Constantinople opcodes are properly configured
    const jt_frontier = JumpTable.init_from_hardfork(.FRONTIER);
    const jt_byzantium = JumpTable.init_from_hardfork(.BYZANTIUM);
    const jt_constantinople = JumpTable.init_from_hardfork(.CONSTANTINOPLE);

    // Constantinople opcodes should not be in Frontier
    try std.testing.expect(jt_frontier.get_operation(0xf5).undefined); // CREATE2
    try std.testing.expect(jt_frontier.get_operation(0x3f).undefined); // EXTCODEHASH
    try std.testing.expect(jt_frontier.get_operation(0x1b).undefined); // SHL
    try std.testing.expect(jt_frontier.get_operation(0x1c).undefined); // SHR
    try std.testing.expect(jt_frontier.get_operation(0x1d).undefined); // SAR

    // Constantinople opcodes should not be in Byzantium
    try std.testing.expect(jt_byzantium.get_operation(0xf5).undefined); // CREATE2
    try std.testing.expect(jt_byzantium.get_operation(0x3f).undefined); // EXTCODEHASH
    try std.testing.expect(jt_byzantium.get_operation(0x1b).undefined); // SHL
    try std.testing.expect(jt_byzantium.get_operation(0x1c).undefined); // SHR
    try std.testing.expect(jt_byzantium.get_operation(0x1d).undefined); // SAR

    // Constantinople opcodes should be in Constantinople
    try std.testing.expect(!jt_constantinople.get_operation(0xf5).undefined); // CREATE2
    try std.testing.expect(!jt_constantinople.get_operation(0x3f).undefined); // EXTCODEHASH
    try std.testing.expect(!jt_constantinople.get_operation(0x1b).undefined); // SHL
    try std.testing.expect(!jt_constantinople.get_operation(0x1c).undefined); // SHR
    try std.testing.expect(!jt_constantinople.get_operation(0x1d).undefined); // SAR

    // Verify correct operation properties
    const create2_op = jt_constantinople.get_operation(0xf5);
    try std.testing.expectEqual(@as(u64, gas_constants.CreateGas), create2_op.constant_gas);
    try std.testing.expectEqual(@as(u32, 4), create2_op.min_stack);

    const extcodehash_op = jt_constantinople.get_operation(0x3f);
    // EXTCODEHASH gas is handled dynamically via access list, not constant
    try std.testing.expectEqual(@as(u64, 0), extcodehash_op.constant_gas);
    try std.testing.expectEqual(@as(u32, 1), extcodehash_op.min_stack);

    const shl_op = jt_constantinople.get_operation(0x1b);
    try std.testing.expectEqual(@as(u64, gas_constants.GasFastestStep), shl_op.constant_gas);
    try std.testing.expectEqual(@as(u32, 2), shl_op.min_stack);
}

test "JumpTable Istanbul opcodes" {
    // Test that Istanbul opcodes are properly configured
    const jt_constantinople = JumpTable.init_from_hardfork(.CONSTANTINOPLE);
    const jt_istanbul = JumpTable.init_from_hardfork(.ISTANBUL);
    const jt_london = JumpTable.init_from_hardfork(.LONDON);

    // Istanbul opcodes should not be in Constantinople
    try std.testing.expect(jt_constantinople.get_operation(0x46).undefined); // CHAINID
    try std.testing.expect(jt_constantinople.get_operation(0x47).undefined); // SELFBALANCE

    // Istanbul opcodes should be in Istanbul
    try std.testing.expect(!jt_istanbul.get_operation(0x46).undefined); // CHAINID
    try std.testing.expect(!jt_istanbul.get_operation(0x47).undefined); // SELFBALANCE

    // BASEFEE should not be in Istanbul
    try std.testing.expect(jt_istanbul.get_operation(0x48).undefined); // BASEFEE

    // BASEFEE should be in London
    try std.testing.expect(!jt_london.get_operation(0x48).undefined); // BASEFEE

    // Verify correct operation properties
    const chainid_op = jt_istanbul.get_operation(0x46);
    try std.testing.expectEqual(@as(u64, gas_constants.GasQuickStep), chainid_op.constant_gas);
    try std.testing.expectEqual(@as(u32, 0), chainid_op.min_stack);

    const selfbalance_op = jt_istanbul.get_operation(0x47);
    try std.testing.expectEqual(@as(u64, gas_constants.GasFastStep), selfbalance_op.constant_gas);
    try std.testing.expectEqual(@as(u32, 0), selfbalance_op.min_stack);

    const basefee_op = jt_london.get_operation(0x48);
    try std.testing.expectEqual(@as(u64, gas_constants.GasQuickStep), basefee_op.constant_gas);
    try std.testing.expectEqual(@as(u32, 0), basefee_op.min_stack);
}

test "JumpTable Shanghai opcodes" {
    // Test that Shanghai opcodes are properly configured
    const jt_london = JumpTable.init_from_hardfork(.LONDON);
    const jt_merge = JumpTable.init_from_hardfork(.MERGE);
    const jt_shanghai = JumpTable.init_from_hardfork(.SHANGHAI);

    // PUSH0 should not be in London/Merge
    try std.testing.expect(jt_london.get_operation(0x5f).undefined); // PUSH0
    try std.testing.expect(jt_merge.get_operation(0x5f).undefined); // PUSH0

    // PUSH0 should be in Shanghai
    try std.testing.expect(!jt_shanghai.get_operation(0x5f).undefined); // PUSH0

    // Verify correct operation properties
    const push0_op = jt_shanghai.get_operation(0x5f);
    try std.testing.expectEqual(@as(u64, gas_constants.GasQuickStep), push0_op.constant_gas);
    try std.testing.expectEqual(@as(u32, 0), push0_op.min_stack);
    try std.testing.expectEqual(@as(u32, Stack.CAPACITY - 1), push0_op.max_stack);
}

test "JumpTable Cancun opcodes" {
    // Test that Cancun opcodes are properly configured
    const jt_shanghai = JumpTable.init_from_hardfork(.SHANGHAI);
    const jt_cancun = JumpTable.init_from_hardfork(.CANCUN);

    // Cancun opcodes should not be in Shanghai
    try std.testing.expect(jt_shanghai.get_operation(0x49).undefined); // BLOBHASH
    try std.testing.expect(jt_shanghai.get_operation(0x4a).undefined); // BLOBBASEFEE
    try std.testing.expect(jt_shanghai.get_operation(0x5e).undefined); // MCOPY
    try std.testing.expect(jt_shanghai.get_operation(0x5c).undefined); // TLOAD
    try std.testing.expect(jt_shanghai.get_operation(0x5d).undefined); // TSTORE

    // Cancun opcodes should be in Cancun
    try std.testing.expect(!jt_cancun.get_operation(0x49).undefined); // BLOBHASH
    try std.testing.expect(!jt_cancun.get_operation(0x4a).undefined); // BLOBBASEFEE
    try std.testing.expect(!jt_cancun.get_operation(0x5e).undefined); // MCOPY
    try std.testing.expect(!jt_cancun.get_operation(0x5c).undefined); // TLOAD
    try std.testing.expect(!jt_cancun.get_operation(0x5d).undefined); // TSTORE

    // Verify correct operation properties
    const blobhash_op = jt_cancun.get_operation(0x49);
    try std.testing.expectEqual(@as(u64, gas_constants.BlobHashGas), blobhash_op.constant_gas);
    try std.testing.expectEqual(@as(u32, 1), blobhash_op.min_stack);

    const blobbasefee_op = jt_cancun.get_operation(0x4a);
    try std.testing.expectEqual(@as(u64, gas_constants.GasQuickStep), blobbasefee_op.constant_gas);
    try std.testing.expectEqual(@as(u32, 0), blobbasefee_op.min_stack);

    const mcopy_op = jt_cancun.get_operation(0x5e);
    try std.testing.expectEqual(@as(u64, gas_constants.GasFastestStep), mcopy_op.constant_gas);
    try std.testing.expectEqual(@as(u32, 3), mcopy_op.min_stack);

    const tload_op = jt_cancun.get_operation(0x5c);
    try std.testing.expectEqual(@as(u64, 100), tload_op.constant_gas);
    try std.testing.expectEqual(@as(u32, 1), tload_op.min_stack);

    const tstore_op = jt_cancun.get_operation(0x5d);
    try std.testing.expectEqual(@as(u64, 100), tstore_op.constant_gas);
    try std.testing.expectEqual(@as(u32, 2), tstore_op.min_stack);
}

test "JumpTable @constCast memory safety issue reproduction" {
    // This test verifies that our safe hardfork-specific operation variants work correctly
    // Previously this would segfault in CI due to @constCast modifying read-only memory
    const jt = JumpTable.init_from_hardfork(.TANGERINE_WHISTLE);

    // This should work without @constCast modifications
    const balance_op = jt.get_operation(0x31); // BALANCE

    // The operation should now have the correct gas cost for Tangerine Whistle (400)
    // using our safe hardfork-specific operation variants
    try std.testing.expectEqual(@as(u64, 400), balance_op.constant_gas);
}
