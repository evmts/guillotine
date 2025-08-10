const std = @import("std");
const evm = @import("evm");

test "collect metrics during block execution" {
    const allocator = std.testing.allocator;

    // Create bytecode with multiple operations:
    // PUSH1 5, PUSH1 10, ADD, DUP1, PUSH1 20, MUL, POP, STOP
    const bytecode = &[_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0A, // PUSH1 10
        0x01, // ADD
        0x80, // DUP1
        0x60, 0x14, // PUSH1 20
        0x02, // MUL
        0x50, // POP
        0x00, // STOP
    };

    // Analyze bytecode
    var analysis = try evm.CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode);
    defer analysis.deinit(allocator);

    // Create instruction buffer
    var instructions: [20]evm.Instruction = undefined;

    // Create jump table
    const jump_table = evm.JumpTable.init_from_hardfork(.CANCUN);

    // Translate bytecode to instructions
    var translator = evm.InstructionTranslator.init(
        allocator,
        bytecode,
        &analysis,
        &instructions,
        &jump_table,
    );

    const start_translation = std.time.nanoTimestamp();
    const instruction_count = try translator.translate_bytecode();
    const translation_time = std.time.nanoTimestamp() - start_translation;

    // Add null terminator
    instructions[instruction_count] = .{
        .opcode_fn = null,
        .arg = .none,
    };

    // Set up VM and frame
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Create a contract
    var contract = try evm.Contract.init(
        allocator,
        bytecode,
        null,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        1000000,
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame = try evm.Frame.init(allocator, &vm, 1000000, contract, evm.primitives.Address.ZERO, &.{});
    defer frame.deinit();

    // Create metrics collector
    var metrics = evm.block_metrics.BlockExecutionMetrics.init();
    metrics.translation_time_ns = @intCast(translation_time);

    // Execute with metrics
    const inst_ptr: [*]const evm.Instruction = &instructions;
    const start_execution = std.time.nanoTimestamp();

    try evm.BlockExecutor.execute_block_with_metrics(inst_ptr, &frame, &metrics);

    metrics.execution_time_ns = @intCast(std.time.nanoTimestamp() - start_execution);

    // Verify metrics
    try std.testing.expect(metrics.instructions_executed > 0);
    try std.testing.expect(metrics.blocks_executed > 0);
    try std.testing.expectEqual(@as(u64, 8), metrics.instructions_executed);
    try std.testing.expect(metrics.max_stack_depth >= 2); // We push values and do operations

    // Print metrics for debugging
    if (false) { // Set to true to see metrics output
        metrics.print_summary();
    }
}

test "compare block execution with regular execution metrics" {
    const allocator = std.testing.allocator;

    // Create a simple bytecode program
    const bytecode = &[_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x02, // MUL
        0x60, 0x02, // PUSH1 2
        0x01, // ADD
        0x00, // STOP
    };

    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // === Regular execution ===
    var contract1 = try evm.Contract.init(
        allocator,
        bytecode,
        null,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        1000000,
        false,
    );
    defer contract1.deinit(allocator, null);

    var baseline_metrics = evm.block_metrics.BlockExecutionMetrics.init();
    const start_regular = std.time.nanoTimestamp();

    const result1 = try vm.interpret(&contract1, &.{}, false);
    defer if (result1.output) |output| allocator.free(output);

    baseline_metrics.execution_time_ns = @intCast(std.time.nanoTimestamp() - start_regular);
    baseline_metrics.gas_consumed = result1.gas_used;
    baseline_metrics.instructions_executed = 6; // Approximate

    // === Block-based execution ===
    var contract2 = try evm.Contract.init(
        allocator,
        bytecode,
        null,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        1000000,
        false,
    );
    defer contract2.deinit(allocator, null);

    var block_metrics = evm.block_metrics.BlockExecutionMetrics.init();
    const start_block = std.time.nanoTimestamp();

    const result2 = try vm.interpret_block(&contract2, &.{}, false);
    defer if (result2.output) |output| allocator.free(output);

    block_metrics.execution_time_ns = @intCast(std.time.nanoTimestamp() - start_block);
    block_metrics.gas_consumed = result2.gas_used;

    // Compare results
    try std.testing.expectEqual(result1.status, result2.status);
    try std.testing.expectEqual(result1.gas_used, result2.gas_used);

    // Compare metrics (for debugging)
    if (false) { // Set to true to see comparison
        std.log.info("=== Regular Execution ===", .{});
        baseline_metrics.print_summary();

        std.log.info("\n=== Block Execution ===", .{});
        block_metrics.print_summary();

        std.log.info("\n=== Comparison ===", .{});
        block_metrics.compare_with(&baseline_metrics);
    }
}

test "block cache functionality" {
    const allocator = std.testing.allocator;

    // Create a cache with max 10 entries
    var cache = evm.block_metrics.BlockCache.init(allocator, 10);
    defer cache.deinit();

    // Create some test instructions
    var instructions = [_]evm.Instruction{
        .{ .opcode_fn = null, .arg = .none },
        .{ .opcode_fn = null, .arg = .{ .push_value = 42 } },
    };

    // Create a test code hash
    const code_hash = [_]u8{1} ** 32;

    // Store in cache
    const test_metrics = evm.CodeAnalysis.BlockMetadata{
        .gas_cost = 100,
        .stack_req = 2,
        .stack_max = 3,
    };

    try cache.put(code_hash, &instructions, test_metrics);

    // Retrieve from cache
    const cached = cache.get(code_hash);
    try std.testing.expect(cached != null);
    try std.testing.expectEqual(@as(usize, 2), cached.?.len);

    // Test cache miss
    const other_hash = [_]u8{2} ** 32;
    const not_cached = cache.get(other_hash);
    try std.testing.expect(not_cached == null);

    // Test cache statistics
    const stats = cache.get_stats();
    try std.testing.expectEqual(@as(usize, 1), stats.entry_count);
    try std.testing.expect(stats.total_accesses > 0);
}
