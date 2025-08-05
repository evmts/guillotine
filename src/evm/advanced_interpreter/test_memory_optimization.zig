/// Comprehensive tests for advanced interpreter memory optimization.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const instruction_stream = @import("instruction_stream.zig");
const memory_expansion_analysis = @import("memory_expansion_analysis.zig");
const memory_optimized_ops = @import("memory_optimized_ops.zig");
const advanced_interpreter_integration = @import("advanced_interpreter_integration.zig");
const execute_advanced = @import("execute_advanced.zig");

const MemoryDatabase = @import("../state/memory_database.zig");
const Contract = @import("../frame/contract.zig");
const Frame = @import("../frame/frame.zig");
const CodeAnalysis = @import("../frame/code_analysis.zig");
const Vm = @import("../evm.zig");
const primitives = @import("primitives");
const opcode = @import("../opcodes/opcode.zig");

/// Test contract: Simple memory store and load
fn bytecode_simple_memory() [_]u8 {
    return [_]u8{
        // PUSH1 0x42, PUSH1 0x00, MSTORE (store 0x42 at offset 0)
        0x60, 0x42, 0x60, 0x00, 0x52,
        // PUSH1 0x00, MLOAD (load from offset 0)
        0x60, 0x00, 0x51,
        // STOP
        0x00,
    };
}

/// Test contract: Array initialization pattern
fn bytecode_array_init() [_]u8 {
    return [_]u8{
        // Initialize array[0] = 10
        0x60, 0x0A, 0x60, 0x00, 0x52,
        // Initialize array[1] = 20
        0x60, 0x14, 0x60, 0x20, 0x52,
        // Initialize array[2] = 30
        0x60, 0x1E, 0x60, 0x40, 0x52,
        // Initialize array[3] = 40
        0x60, 0x28, 0x60, 0x60, 0x52,
        // Load and sum array[0] + array[1]
        0x60, 0x00, 0x51, 0x60, 0x20, 0x51, 0x01,
        // STOP
        0x00,
    };
}

/// Test contract: Dynamic memory access (loop)
fn bytecode_dynamic_memory() [_]u8 {
    return [_]u8{
        // PUSH1 0x00 (counter)
        0x60, 0x00,
        // JUMPDEST (loop start)
        0x5B,
        // DUP1, PUSH1 0x20, MUL (calculate offset = counter * 32)
        0x80, 0x60, 0x20, 0x02,
        // DUP2, SWAP1, MSTORE (store counter at calculated offset)
        0x81, 0x90, 0x52,
        // PUSH1 0x01, ADD (increment counter)
        0x60, 0x01, 0x01,
        // DUP1, PUSH1 0x04, LT (check if counter < 4)
        0x80, 0x60, 0x04, 0x10,
        // PUSH1 0x03, JUMPI (jump back to loop start if true)
        0x60, 0x03, 0x57,
        // POP, STOP
        0x50, 0x00,
    };
}

/// Test contract: Memory copy operations
fn bytecode_memory_copy() [_]u8 {
    return [_]u8{
        // Store some data first
        0x60, 0xAA, 0x60, 0x00, 0x52, // Store 0xAA at offset 0
        0x60, 0xBB, 0x60, 0x20, 0x52, // Store 0xBB at offset 32
        // PUSH1 0x40, PUSH1 0x00, PUSH1 0x40, CALLDATACOPY
        0x60, 0x40, 0x60, 0x00, 0x60, 0x40, 0x37,
        // PUSH1 0x40, PUSH1 0x00, RETURN
        0x60, 0x40, 0x60, 0x00, 0xF3,
    };
}

test "memory expansion analysis - simple store/load" {
    const allocator = testing.allocator;
    const bytecode = bytecode_simple_memory();
    const block_starts = [_]usize{0};
    
    const blocks = try memory_expansion_analysis.analyze_memory_expansion(
        allocator,
        &bytecode,
        &block_starts,
    );
    defer {
        for (blocks) |*block| {
            block.accesses.deinit();
        }
        allocator.free(blocks);
    }
    
    // Should have one block with memory accesses
    try testing.expectEqual(@as(usize, 1), blocks.len);
    
    const block = &blocks[0];
    try testing.expectEqual(@as(u64, 32), block.max_memory_size);
    try testing.expectEqual(false, block.has_dynamic_access);
    
    // Check MSTORE at PC 4
    const mstore_access = block.accesses.get(4).?;
    try testing.expectEqual(memory_expansion_analysis.MemoryAccess.AccessType.write, mstore_access.access_type);
    try testing.expectEqual(@as(u64, 0), mstore_access.static_offset.?);
    try testing.expectEqual(@as(u64, 32), mstore_access.static_size.?);
    try testing.expect(mstore_access.expansion_cost.? > 0);
    
    // Check MLOAD at PC 7
    const mload_access = block.accesses.get(7).?;
    try testing.expectEqual(memory_expansion_analysis.MemoryAccess.AccessType.read, mload_access.access_type);
    try testing.expectEqual(@as(u64, 0), mload_access.static_offset.?);
    try testing.expectEqual(@as(u64, 0), mload_access.expansion_cost.?); // No expansion needed
}

test "memory expansion analysis - array initialization" {
    const allocator = testing.allocator;
    const bytecode = bytecode_array_init();
    const block_starts = [_]usize{0};
    
    const blocks = try memory_expansion_analysis.analyze_memory_expansion(
        allocator,
        &bytecode,
        &block_starts,
    );
    defer {
        for (blocks) |*block| {
            block.accesses.deinit();
        }
        allocator.free(blocks);
    }
    
    const block = &blocks[0];
    try testing.expectEqual(@as(u64, 128), block.max_memory_size); // 4 * 32 bytes
    try testing.expectEqual(false, block.has_dynamic_access);
    
    // Check that each MSTORE has appropriate expansion cost
    var total_expansion_cost: u64 = 0;
    var it = block.accesses.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.access_type == .write) {
            total_expansion_cost += entry.value_ptr.expansion_cost.?;
        }
    }
    
    // Total expansion cost should be significant
    try testing.expect(total_expansion_cost > 0);
}

test "memory expansion analysis - dynamic access detection" {
    const allocator = testing.allocator;
    const bytecode = bytecode_dynamic_memory();
    const block_starts = [_]usize{0, 3}; // Two blocks: init and loop
    
    const blocks = try memory_expansion_analysis.analyze_memory_expansion(
        allocator,
        &bytecode,
        &block_starts,
    );
    defer {
        for (blocks) |*block| {
            block.accesses.deinit();
        }
        allocator.free(blocks);
    }
    
    // Loop block should have dynamic memory access
    try testing.expect(blocks[1].has_dynamic_access);
}

test "optimized memory operations - pre-calculated expansion" {
    const allocator = testing.allocator;
    const Memory = @import("../memory/memory.zig");
    const Stack = @import("../stack/stack.zig");
    
    // Create test state
    var memory = try Memory.init_default(allocator);
    defer memory.deinit();
    
    var stack = Stack.init();
    var gas_left: i64 = 100000;
    
    // Mock VM and frame
    var vm_instance: Vm = undefined;
    var frame_instance: Frame = undefined;
    
    var state = instruction_stream.AdvancedExecutionState{
        .stack = &stack,
        .memory = &memory,
        .gas_left = &gas_left,
        .vm = &vm_instance,
        .frame = &frame_instance,
        .exit_status = null,
        .push_values = &.{},
    };
    
    // Test MSTORE with pre-calculated cost
    try stack.append(0x12345678); // value
    try stack.append(64);         // offset (third word)
    
    const expansion_cost: u64 = 9; // Cost for expanding to 96 bytes (3 words)
    const mstore_instr = instruction_stream.Instruction{
        .fn_ptr = &memory_optimized_ops.op_mstore_precalc,
        .arg = .{ .data = expansion_cost },
    };
    
    const initial_gas = gas_left;
    const next = memory_optimized_ops.op_mstore_precalc(&mstore_instr, &state);
    
    try testing.expect(next != null);
    try testing.expect(state.exit_status == null);
    try testing.expectEqual(@as(i64, initial_gas - 9), gas_left);
    
    // Verify memory was expanded and written
    try testing.expectEqual(@as(usize, 96), memory.context_size());
    const stored_value = try memory.get_u256(64);
    try testing.expectEqual(@as(u256, 0x12345678), stored_value);
}

test "end-to-end execution with memory optimization" {
    const allocator = testing.allocator;
    
    // Setup VM and database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var builder = @import("../evm_builder.zig").EvmBuilder.init(allocator, db_interface);
    var vm = try builder.build();
    defer vm.deinit();
    
    // Create contract with array initialization
    const bytecode = bytecode_array_init();
    
    var contract = Contract.init(
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        1000000,
        &bytecode,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    contract.code_size = bytecode.len;
    
    // Perform code analysis
    const analysis_result = try CodeAnalysis.analyze_bytecode_blocks(allocator, &bytecode);
    defer analysis_result.deinit(allocator);
    contract.analysis = &analysis_result;
    
    // Generate optimized instruction stream
    var stream = try advanced_interpreter_integration.generate_optimized_instruction_stream(
        allocator,
        &bytecode,
        &analysis_result,
    );
    defer stream.deinit();
    
    // Create frame and execute
    var frame = try Frame.init(allocator, &contract);
    defer frame.deinit();
    frame.gas_remaining = 100000;
    
    const result = try execute_advanced.execute_advanced(&vm, &frame, &stream);
    
    // Verify execution succeeded
    try testing.expectEqual(execute_advanced.RunResult.Status.Success, result.status);
    
    // Verify gas usage is reasonable
    const gas_used = 100000 - result.gas_left;
    try testing.expect(gas_used < 1000); // Should be efficient with pre-calculation
    
    // Verify final stack has sum of array[0] + array[1] = 10 + 20 = 30
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    const sum = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 30), sum);
}

test "memory optimization decision heuristic" {
    const allocator = testing.allocator;
    
    // Small contract - should not use optimization
    {
        const small_bytecode = [_]u8{0x60, 0x00, 0x60, 0x00, 0x52, 0x00}; // Simple MSTORE
        var contract = Contract.init(
            primitives.Address.ZERO_ADDRESS,
            primitives.Address.ZERO_ADDRESS,
            0,
            100000,
            &small_bytecode,
            [_]u8{0} ** 32,
            &[_]u8{},
            false,
        );
        contract.code_size = small_bytecode.len;
        
        const analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, &small_bytecode);
        defer analysis.deinit(allocator);
        
        const should_optimize = advanced_interpreter_integration.should_use_memory_optimization(&contract, &analysis);
        try testing.expect(!should_optimize); // Too small
    }
    
    // Contract with many memory operations - should use optimization
    {
        const memory_heavy = bytecode_array_init();
        var contract = Contract.init(
            primitives.Address.ZERO_ADDRESS,
            primitives.Address.ZERO_ADDRESS,
            0,
            100000,
            &memory_heavy,
            [_]u8{0} ** 32,
            &[_]u8{},
            false,
        );
        contract.code_size = memory_heavy.len;
        
        const analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, &memory_heavy);
        defer analysis.deinit(allocator);
        
        const should_optimize = advanced_interpreter_integration.should_use_memory_optimization(&contract, &analysis);
        try testing.expect(should_optimize); // Has enough memory operations
    }
}

test "memory copy operations with pre-calculation" {
    const allocator = testing.allocator;
    const bytecode = bytecode_memory_copy();
    const block_starts = [_]usize{0};
    
    const blocks = try memory_expansion_analysis.analyze_memory_expansion(
        allocator,
        &bytecode,
        &block_starts,
    );
    defer {
        for (blocks) |*block| {
            block.accesses.deinit();
        }
        allocator.free(blocks);
    }
    
    const block = &blocks[0];
    
    // Should detect CALLDATACOPY
    var found_calldatacopy = false;
    var it = block.accesses.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.access_type == .copy_write) {
            found_calldatacopy = true;
            // Should have static offset and size
            try testing.expect(entry.value_ptr.static_offset != null);
            try testing.expect(entry.value_ptr.static_size != null);
            try testing.expect(entry.value_ptr.expansion_cost != null);
        }
    }
    
    try testing.expect(found_calldatacopy);
}