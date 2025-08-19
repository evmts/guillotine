const std = @import("std");
const Evm = @import("evm");
const OpcodeMetadata = Evm.OpcodeMetadata;
const Operation = Evm.Operation;
const OperationModule = Evm.OperationModule;
const Stack = Evm.Stack;
const Frame = Evm.Frame;
const Contract = Evm.Contract;
const MemoryDatabase = Evm.MemoryDatabase;
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const execution = Evm.execution;
const gas_constants = Evm.GasConstants;
const testing = std.testing;
const Vm = Evm.Evm;
const Context = Evm.Context;

test {
    // std.testing.log_level = .warn;
}

test "OpcodeMetadata basic operations" {
    const jt = OpcodeMetadata.init_from_hardfork(.FRONTIER);

    // Test a couple of operations
    const stop_op = jt.get_operation(0x00);
    try std.testing.expectEqual(@as(u64, 0), stop_op.constant_gas);

    const add_op = jt.get_operation(0x01);
    try std.testing.expectEqual(@as(u64, gas_constants.GasFastestStep), add_op.constant_gas);

    // Test an undefined operation
    const undef_op = jt.get_operation(0xef);
    try std.testing.expect(undef_op.undefined);
}

test "OpcodeMetadata initialization and validation" {
    const jt = OpcodeMetadata.init();
    try std.testing.expectEqual(@as(usize, 256), jt.execute_funcs.len);

    // Check that all entries are initially set to undefined
    for (0..256) |_| {
        try std.testing.expectEqual(true, jt.undefined_flags[i]);
    }

    // Validate should check consistency
    var mutable_jt = jt;
    mutable_jt.validate();

    // Check that all entries still have consistent state
    for (0..256) |_| {
        const is_undefined = mutable_jt.undefined_flags[i];
        if (is_undefined) {
            try std.testing.expectEqual(@as(u64, 0), mutable_jt.constant_gas[i]);
        }
    }
}

test "OpcodeMetadata gas constants" {
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

test "OpcodeMetadata basic initialization" {
    // Test minimal opcode metadata functionality without VM
    const jt = OpcodeMetadata.init_from_hardfork(.FRONTIER);

    // Verify the opcode metadata was created
    try std.testing.expectEqual(@as(usize, 256), jt.execute_funcs.len);

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

    // Step 2: Use normal allocator (EVM will handle internal arena allocation)
    std.log.debug("Step 2: Using normal allocator", .{});
    const evm_alloc = test_allocator;
    std.log.debug("Step 2: Normal allocator setup complete", .{});

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
    const opcode_metadata = OpcodeMetadata.DEFAULT;
    const ChainRules = @import("evm").ChainRules;
    const chain_rules = ChainRules.DEFAULT;
    _ = opcode_metadata;
    _ = chain_rules;
    std.log.debug("Step 6: Static defaults work", .{});

    std.log.debug("Manual VM.init reproduction completed successfully!", .{});
}

test "OpcodeMetadata Constantinople opcodes" {
    // Test that Constantinople opcodes are properly configured
    const jt_frontier = OpcodeMetadata.init_from_hardfork(.FRONTIER);
    const jt_byzantium = OpcodeMetadata.init_from_hardfork(.BYZANTIUM);
    const jt_constantinople = OpcodeMetadata.init_from_hardfork(.CONSTANTINOPLE);

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

test "OpcodeMetadata Istanbul opcodes" {
    // Test that Istanbul opcodes are properly configured
    const jt_constantinople = OpcodeMetadata.init_from_hardfork(.CONSTANTINOPLE);
    const jt_istanbul = OpcodeMetadata.init_from_hardfork(.ISTANBUL);
    const jt_london = OpcodeMetadata.init_from_hardfork(.LONDON);

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

test "OpcodeMetadata Shanghai opcodes" {
    // Test that Shanghai opcodes are properly configured
    const jt_london = OpcodeMetadata.init_from_hardfork(.LONDON);
    const jt_merge = OpcodeMetadata.init_from_hardfork(.MERGE);
    const jt_shanghai = OpcodeMetadata.init_from_hardfork(.SHANGHAI);

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

test "OpcodeMetadata Cancun opcodes" {
    // Test that Cancun opcodes are properly configured
    const jt_shanghai = OpcodeMetadata.init_from_hardfork(.SHANGHAI);
    const jt_cancun = OpcodeMetadata.init_from_hardfork(.CANCUN);

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

test "OpcodeMetadata @constCast memory safety issue reproduction" {
    // This test verifies that our safe hardfork-specific operation variants work correctly
    // Previously this would segfault in CI due to @constCast modifying read-only memory
    const jt = OpcodeMetadata.init_from_hardfork(.TANGERINE_WHISTLE);

    // This should work without @constCast modifications
    const balance_op = jt.get_operation(0x31); // BALANCE

    // The operation should now have the correct gas cost for Tangerine Whistle (400)
    // using our safe hardfork-specific operation variants
    try std.testing.expectEqual(@as(u64, 400), balance_op.constant_gas);
}

test "benchmark current AoS opcode metadata memory access pattern" {
    // Create opcode metadata
    const table = OpcodeMetadata.DEFAULT;

    // Simulate typical opcode execution pattern from real EVM workloads
    // These are the most common opcodes in order of frequency
    const common_opcodes = [_]u8{
        0x60, // PUSH1
        0x61, // PUSH2
        0x80, // DUP1
        0x81, // DUP2
        0x01, // ADD
        0x50, // POP
        0x52, // MSTORE
        0x51, // MLOAD
        0x14, // EQ
        0x57, // JUMPI
        0x56, // JUMP
        0x5b, // JUMPDEST
        0x15, // ISZERO
        0x02, // MUL
        0x04, // DIV
        0x10, // LT
        0x11, // GT
        0x16, // AND
        0x35, // CALLDATALOAD
        0x36, // CALLDATASIZE
    };

    // Measure memory access pattern
    var timer = try std.time.Timer.start();
    const iterations = 1_000_000;

    var total_gas: u64 = 0;
    var total_stack_checks: u64 = 0;

    for (0..iterations) |_| {
        // Simulate real execution pattern
        for (common_opcodes) |opcode| {
            const op = table.get_operation(opcode);
            // Access hot fields that would be in inner loop
            total_gas += op.constant_gas;
            total_stack_checks += op.min_stack;
            total_stack_checks += op.max_stack;
            // Note: In real execution we'd also call op.execute
        }
    }

    const elapsed_ns = timer.read();
    const ops_per_sec = (iterations * common_opcodes.len * 1_000_000_000) / elapsed_ns;

    std.log.info("Current AoS Performance:", .{});
    std.log.info("  Time: {}ns", .{elapsed_ns});
    std.log.info("  Ops/sec: {}", .{ops_per_sec});
    std.log.info("  Total gas: {}", .{total_gas});
    std.log.info("  Total stack checks: {}", .{total_stack_checks});

    // These values should be deterministic
    try std.testing.expect(total_gas > 0);
    try std.testing.expect(total_stack_checks > 0);
}

test "benchmark SoA jump table memory access pattern" {
    const SoaOpcodeMetadata = @import("evm").SoaOpcodeMetadata;

    // Create both jump tables
    const aos_table = OpcodeMetadata.DEFAULT;
    const soa_table = SoaOpcodeMetadata.init_from_aos(&aos_table);

    // Same opcode pattern as AoS test
    const common_opcodes = [_]u8{
        0x60, // PUSH1
        0x61, // PUSH2
        0x80, // DUP1
        0x81, // DUP2
        0x01, // ADD
        0x50, // POP
        0x52, // MSTORE
        0x51, // MLOAD
        0x14, // EQ
        0x57, // JUMPI
        0x56, // JUMP
        0x5b, // JUMPDEST
        0x15, // ISZERO
        0x02, // MUL
        0x04, // DIV
        0x10, // LT
        0x11, // GT
        0x16, // AND
        0x35, // CALLDATALOAD
        0x36, // CALLDATASIZE
    };

    // Measure SoA performance
    var timer = try std.time.Timer.start();
    const iterations = 1_000_000;

    var total_gas: u64 = 0;
    var total_stack_checks: u64 = 0;

    for (0..iterations) |_| {
        for (common_opcodes) |opcode| {
            // Use optimized SoA access patterns
            const hot = soa_table.get_hot_fields(opcode);
            const stack_req = soa_table.get_stack_requirements(opcode);

            total_gas += hot.gas;
            total_stack_checks += stack_req.min_stack;
            total_stack_checks += stack_req.max_stack;
        }
    }

    const elapsed_ns = timer.read();
    const ops_per_sec = (iterations * common_opcodes.len * 1_000_000_000) / elapsed_ns;

    std.log.info("SoA Performance:", .{});
    std.log.info("  Time: {}ns", .{elapsed_ns});
    std.log.info("  Ops/sec: {}", .{ops_per_sec});
    std.log.info("  Total gas: {}", .{total_gas});
    std.log.info("  Total stack checks: {}", .{total_stack_checks});

    // Values should match AoS
    try std.testing.expect(total_gas > 0);
    try std.testing.expect(total_stack_checks > 0);
}

test "struct-of-arrays maintains operation correctness" {
    const SoaOpcodeMetadata = @import("evm").SoaOpcodeMetadata;

    // Create both implementations
    const aos_table = OpcodeMetadata.DEFAULT;
    const soa_table = SoaOpcodeMetadata.init_from_aos(&aos_table);

    // Test that SoA returns same values as AoS
    const opcodes_to_test = [_]u8{ 0x01, 0x60, 0x52, 0x00, 0xfe };

    for (opcodes_to_test) |opcode| {
        const aos_op = aos_table.get_operation(opcode);
        const soa_op = soa_table.get_operation_soa(opcode);

        try std.testing.expectEqual(aos_op.execute, soa_op.execute);
        try std.testing.expectEqual(aos_op.constant_gas, soa_op.gas);
        try std.testing.expectEqual(aos_op.min_stack, soa_op.min_stack);
        try std.testing.expectEqual(aos_op.max_stack, soa_op.max_stack);
        try std.testing.expectEqual(aos_op.undefined, soa_op.undefined);
    }
}
