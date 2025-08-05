/// Tests for the advanced interpreter with instruction stream architecture.

const std = @import("std");
const testing = std.testing;
const Vm = @import("evm").Vm;
const Frame = @import("evm").frame.Frame;
const Contract = @import("evm").frame.Contract;
const MemoryDatabase = @import("evm").state.MemoryDatabase;
const CodeAnalysis = @import("evm").frame.CodeAnalysis;
const instruction_stream = @import("evm").advanced_interpreter.instruction_stream;
const execute_advanced = @import("evm").advanced_interpreter.execute_advanced;
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const RunResult = @import("evm").evm.RunResult;

test "advanced interpreter with static jumps" {
    const allocator = testing.allocator;
    
    // Setup
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Bytecode with static jump:
    // PUSH1 0x05  (target)
    // JUMP
    // PUSH1 0xFF  (skipped)
    // JUMPDEST    (at PC 5)
    // PUSH1 0xAA
    // STOP
    const bytecode = [_]u8{
        0x60, 0x05,  // PUSH1 0x05
        0x56,        // JUMP
        0x60, 0xFF,  // PUSH1 0xFF (should be skipped)
        0x5B,        // JUMPDEST (at PC 5)
        0x60, 0xAA,  // PUSH1 0xAA
        0x00,        // STOP
    };
    
    // Create contract
    var contract = try Contract.init(allocator, &bytecode, .{
        .address = Address.ZERO,
    });
    defer contract.deinit(allocator, null);
    
    // Analyze code with jump analysis enabled
    contract.analysis = try CodeAnalysis.analyze_with_jumps(allocator, &bytecode);
    
    // Verify jump analysis found the static jump
    try testing.expect(contract.analysis.?.jump_analysis != null);
    try testing.expect(contract.analysis.?.jump_analysis.?.all_jumps_static);
    try testing.expectEqual(@as(u32, 1), contract.analysis.?.jump_analysis.?.static_jump_count);
    
    // Generate instruction stream
    var stream = try instruction_stream.generate_instruction_stream(
        allocator,
        &bytecode,
        contract.analysis.?,
    );
    defer stream.deinit();
    
    // Create frame
    var frame = try Frame.init(allocator, &vm, 100000, contract, Address.ZERO, &[_]u8{});
    defer frame.deinit();
    
    // Execute using advanced interpreter
    const result = try execute_advanced.execute_advanced(&vm, &frame, &stream);
    
    // Verify result
    try testing.expectEqual(RunResult.Status.Success, result.status);
    
    // Stack should have 0xAA (0xFF should be skipped)
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0xAA), value);
}

test "advanced interpreter with conditional static jump" {
    const allocator = testing.allocator;
    
    // Setup
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Bytecode with static JUMPI:
    // PUSH1 0x01  (condition: true)
    // PUSH1 0x08  (target)
    // JUMPI
    // PUSH1 0xFF  (skipped)
    // JUMPDEST    (at PC 8)
    // PUSH1 0xBB
    // STOP
    const bytecode = [_]u8{
        0x60, 0x01,  // PUSH1 0x01 (condition)
        0x60, 0x08,  // PUSH1 0x08 (target)
        0x57,        // JUMPI
        0x60, 0xFF,  // PUSH1 0xFF (should be skipped)
        0x00,        // STOP (should be skipped)
        0x5B,        // JUMPDEST (at PC 8)
        0x60, 0xBB,  // PUSH1 0xBB
        0x00,        // STOP
    };
    
    // Create contract
    var contract = try Contract.init(allocator, &bytecode, .{
        .address = Address.ZERO,
    });
    defer contract.deinit(allocator, null);
    
    // Analyze code
    contract.analysis = try CodeAnalysis.analyze_with_jumps(allocator, &bytecode);
    
    // Generate instruction stream
    var stream = try instruction_stream.generate_instruction_stream(
        allocator,
        &bytecode,
        contract.analysis.?,
    );
    defer stream.deinit();
    
    // Create frame
    var frame = try Frame.init(allocator, &vm, 100000, contract, Address.ZERO, &[_]u8{});
    defer frame.deinit();
    
    // Execute
    const result = try execute_advanced.execute_advanced(&vm, &frame, &stream);
    
    // Verify result
    try testing.expectEqual(RunResult.Status.Success, result.status);
    
    // Stack should have 0xBB
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0xBB), value);
}

test "advanced interpreter with dynamic jump" {
    const allocator = testing.allocator;
    
    // Setup
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Bytecode with dynamic jump (computed destination):
    // PUSH1 0x02
    // PUSH1 0x04
    // ADD         (result: 0x06)
    // JUMP        (dynamic jump to PC 6)
    // JUMPDEST    (at PC 6)
    // PUSH1 0xCC
    // STOP
    const bytecode = [_]u8{
        0x60, 0x02,  // PUSH1 0x02
        0x60, 0x04,  // PUSH1 0x04
        0x01,        // ADD
        0x56,        // JUMP (dynamic)
        0x5B,        // JUMPDEST (at PC 6)
        0x60, 0xCC,  // PUSH1 0xCC
        0x00,        // STOP
    };
    
    // Create contract
    var contract = try Contract.init(allocator, &bytecode, .{
        .address = Address.ZERO,
    });
    defer contract.deinit(allocator, null);
    
    // Analyze code
    contract.analysis = try CodeAnalysis.analyze_with_jumps(allocator, &bytecode);
    
    // Verify this is detected as dynamic jump
    try testing.expect(contract.analysis.?.jump_analysis != null);
    try testing.expect(!contract.analysis.?.jump_analysis.?.all_jumps_static);
    try testing.expectEqual(@as(u32, 1), contract.analysis.?.jump_analysis.?.dynamic_jump_count);
    
    // Generate instruction stream
    var stream = try instruction_stream.generate_instruction_stream(
        allocator,
        &bytecode,
        contract.analysis.?,
    );
    defer stream.deinit();
    
    // Create frame
    var frame = try Frame.init(allocator, &vm, 100000, contract, Address.ZERO, &[_]u8{});
    defer frame.deinit();
    
    // Execute
    const result = try execute_advanced.execute_advanced(&vm, &frame, &stream);
    
    // Verify result
    try testing.expectEqual(RunResult.Status.Success, result.status);
    
    // Stack should have 0xCC
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0xCC), value);
}

test "advanced interpreter gas opcode with block correction" {
    const allocator = testing.allocator;
    
    // Setup
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Simple bytecode with GAS opcode:
    // GAS
    // PUSH1 0x02
    // GAS
    // STOP
    const bytecode = [_]u8{
        0x5A,        // GAS
        0x60, 0x02,  // PUSH1 0x02
        0x5A,        // GAS
        0x00,        // STOP
    };
    
    // Create contract
    var contract = try Contract.init(allocator, &bytecode, .{
        .address = Address.ZERO,
    });
    defer contract.deinit(allocator, null);
    
    // Analyze code
    contract.analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, &bytecode);
    
    // Generate instruction stream
    var stream = try instruction_stream.generate_instruction_stream(
        allocator,
        &bytecode,
        contract.analysis.?,
    );
    defer stream.deinit();
    
    // Create frame with specific gas
    var frame = try Frame.init(allocator, &vm, 10000, contract, Address.ZERO, &[_]u8{});
    defer frame.deinit();
    
    // Execute
    const result = try execute_advanced.execute_advanced(&vm, &frame, &stream);
    
    // Verify result
    try testing.expectEqual(RunResult.Status.Success, result.status);
    
    // Stack should have two gas values
    try testing.expectEqual(@as(usize, 3), frame.stack.size());
    
    // The gas values should reflect the block correction
    const gas2 = try frame.stack.pop();
    const push_value = try frame.stack.pop();
    const gas1 = try frame.stack.pop();
    
    try testing.expectEqual(@as(u256, 0x02), push_value);
    
    // Gas values should be different (gas consumed between them)
    try testing.expect(gas1 > gas2);
}

test "advanced interpreter performance comparison" {
    const allocator = testing.allocator;
    
    // Setup
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Complex bytecode with multiple static jumps
    const bytecode = [_]u8{
        // Block 1
        0x60, 0x01,  // PUSH1 0x01
        0x60, 0x0A,  // PUSH1 0x0A (jump to block 2)
        0x56,        // JUMP
        
        // Block 2 (PC 10)
        0x5B,        // JUMPDEST
        0x60, 0x02,  // PUSH1 0x02
        0x01,        // ADD
        0x60, 0x14,  // PUSH1 0x14 (jump to block 3)
        0x56,        // JUMP
        
        // Block 3 (PC 20)
        0x5B,        // JUMPDEST
        0x60, 0x03,  // PUSH1 0x03
        0x01,        // ADD
        0x00,        // STOP
    };
    
    // Create contract
    var contract = try Contract.init(allocator, &bytecode, .{
        .address = Address.ZERO,
    });
    defer contract.deinit(allocator, null);
    
    // Analyze code with jump analysis
    contract.analysis = try CodeAnalysis.analyze_with_jumps(allocator, &bytecode);
    
    // Verify all jumps are static
    try testing.expect(contract.analysis.?.jump_analysis.?.all_jumps_static);
    try testing.expectEqual(@as(u32, 2), contract.analysis.?.jump_analysis.?.static_jump_count);
    
    // Generate instruction stream
    var stream = try instruction_stream.generate_instruction_stream(
        allocator,
        &bytecode,
        contract.analysis.?,
    );
    defer stream.deinit();
    
    // Create frame
    var frame = try Frame.init(allocator, &vm, 100000, contract, Address.ZERO, &[_]u8{});
    defer frame.deinit();
    
    // Execute
    const result = try execute_advanced.execute_advanced(&vm, &frame, &stream);
    
    // Verify result
    try testing.expectEqual(RunResult.Status.Success, result.status);
    
    // Final result should be 1 + 2 + 3 = 6
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 6), value);
    
    // Gas usage should be optimized (block-based deduction)
    try testing.expect(result.gas_left < 100000);
}