/// Advanced interpreter execution using instruction stream.
///
/// This module provides the main execution loop for the instruction stream
/// architecture, replacing the traditional PC-based execution with direct
/// function pointer dispatch.

const std = @import("std");
const Frame = @import("../frame/frame.zig");
const Vm = @import("../evm.zig");
const RunResult = @import("../evm/run_result.zig").RunResult;
const ExecutionError = @import("../execution/execution_error.zig");
const instruction_stream = @import("instruction_stream.zig");
const Log = @import("../log.zig");

/// Execute bytecode using advanced interpreter with instruction stream.
///
/// This function serves as a drop-in replacement for the traditional interpret
/// function but uses the instruction stream architecture for better performance.
///
/// @param vm The VM instance
/// @param frame Current execution frame
/// @param stream Pre-generated instruction stream
/// @return Execution result
pub fn execute_advanced(
    vm: *Vm,
    frame: *Frame,
    stream: *const instruction_stream.InstructionStream,
) ExecutionError.Error!RunResult {
    Log.debug("execute_advanced: Starting advanced execution", .{});
    
    const initial_gas = frame.gas_remaining;
    
    // Convert gas to signed for easier underflow detection
    var gas_left: i64 = @intCast(frame.gas_remaining);
    
    // Create advanced execution state
    var state = instruction_stream.AdvancedExecutionState{
        .stack = &frame.stack,
        .memory = &frame.memory,
        .gas_left = &gas_left,
        .vm = vm,
        .frame = frame,
        .exit_status = null,
    };
    
    // Main execution loop
    var instr: ?*const instruction_stream.Instruction = &stream.instructions[0];
    
    while (instr) |current| {
        // Execute instruction
        instr = current.fn_ptr(current, &state);
        
        // Check for exit conditions
        if (state.exit_status) |status| {
            // Update frame gas
            frame.gas_remaining = if (gas_left > 0) @intCast(gas_left) else 0;
            
            return switch (status) {
                ExecutionError.Error.STOP => RunResult.init(
                    initial_gas,
                    frame.gas_remaining,
                    .Success,
                    null,
                    frame.output,
                ),
                ExecutionError.Error.REVERT => RunResult.init(
                    initial_gas,
                    frame.gas_remaining,
                    .Revert,
                    status,
                    frame.output,
                ),
                ExecutionError.Error.OutOfGas => RunResult.init(
                    initial_gas,
                    0,
                    .OutOfGas,
                    status,
                    null,
                ),
                ExecutionError.Error.InvalidOpcode => RunResult.init(
                    initial_gas,
                    0,
                    .Invalid,
                    status,
                    null,
                ),
                else => RunResult.init(
                    initial_gas,
                    frame.gas_remaining,
                    .Invalid,
                    status,
                    frame.output,
                ),
            };
        }
        
        // If instruction returned null without setting exit status,
        // we need to re-enter at new PC (jump occurred)
        if (instr == null and state.exit_status == null) {
            // Find instruction for new PC
            const new_pc = frame.pc;
            if (new_pc >= stream.pc_to_instruction.len) {
                return ExecutionError.Error.InvalidJump;
            }
            
            const instr_idx = stream.pc_to_instruction[new_pc];
            if (instr_idx == std.math.maxInt(u32)) {
                return ExecutionError.Error.InvalidJump;
            }
            
            instr = &stream.instructions[instr_idx];
        }
    }
    
    // Update final gas
    frame.gas_remaining = if (gas_left > 0) @intCast(gas_left) else 0;
    
    // Normal completion (reached end of code)
    return RunResult.init(
        initial_gas,
        frame.gas_remaining,
        .Success,
        null,
        frame.output,
    );
}

/// Check if advanced execution should be used.
///
/// Advanced execution is beneficial when:
/// - Code analysis is available
/// - No dynamic jumps present
/// - Contract is non-trivial size
pub fn should_use_advanced(
    contract: *const @import("../frame/contract.zig"),
) bool {
    if (contract.analysis) |analysis| {
        return analysis.block_count > 0 and
               !analysis.has_dynamic_jumps and
               contract.code_size > 100;
    }
    return false;
}

// Tests
test "execute_advanced basic execution" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const MemoryDatabase = @import("../state/memory_database.zig");
    const Contract = @import("../frame/contract.zig");
    const CodeAnalysis = @import("../frame/code_analysis.zig");
    const primitives = @import("primitives");
    
    // Setup
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var builder = @import("../evm_builder.zig").EvmBuilder.init(allocator, db_interface);
    var vm = try builder.build();
    defer vm.deinit();
    
    // Simple bytecode: PUSH1 0x02, PUSH1 0x03, ADD, STOP
    const bytecode = [_]u8{ 0x60, 0x02, 0x60, 0x03, 0x01, 0x00 };
    
    // Create contract
    var contract = Contract.init(
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        100000,
        &bytecode,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    contract.code_size = bytecode.len;
    
    // Create mock analysis
    var analysis = CodeAnalysis{
        .jumpdest_analysis = undefined,
        .jumpdest_bitmap = undefined,
        .block_starts = try @import("../frame/bitvec.zig").BitVec(u64).init(allocator, bytecode.len),
        .block_count = 1,
        .block_metadata = try allocator.alloc(@import("../frame/code_analysis.zig").BlockMetadata, 1),
        .has_dynamic_jumps = false,
        .max_stack_depth = 2,
        .pc_to_block = try allocator.alloc(u16, bytecode.len),
        .block_start_positions = try allocator.alloc(usize, 1),
        .jump_analysis = null,
    };
    defer analysis.deinit(allocator);
    
    analysis.block_starts.setBit(0);
    analysis.block_metadata[0] = .{
        .gas_cost = 9,
        .stack_req = 0,
        .stack_max = 2,
    };
    analysis.block_start_positions[0] = 0;
    @memset(analysis.pc_to_block, 0);
    
    // Generate instruction stream
    var stream = try instruction_stream.generate_instruction_stream(allocator, &bytecode, &analysis);
    defer stream.deinit();
    
    // Create frame
    var frame = try Frame.init(allocator, &contract);
    defer frame.deinit();
    frame.gas_remaining = 100000;
    
    // Execute
    const result = try execute_advanced(&vm, &frame, &stream);
    
    // Verify result
    try testing.expectEqual(RunResult.Status.Success, result.status);
    try testing.expect(result.gas_left > 0);
    
    // Stack should have result (5)
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    const stack_top = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 5), stack_top);
}