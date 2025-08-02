const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("../execution/execution_error.zig");
const Contract = @import("../frame/contract.zig");
const Frame = @import("../frame/frame.zig");
const Operation = @import("../opcodes/operation.zig");
const RunResult = @import("run_result.zig").RunResult;
const Log = @import("../log.zig");
const Vm = @import("../evm.zig");
const primitives = @import("primitives");
const opcode = @import("../opcodes/opcode.zig");
const CodeAnalysis = @import("../frame/code_analysis.zig");


/// Execute using threaded code (indirect call threading)
pub fn interpret(
    self: *Vm,
    contract: *Contract,
    input: []const u8,
    is_static: bool,
) ExecutionError.Error!RunResult {
    const threaded_analysis = @import("../frame/threaded_analysis.zig");
    
    // Ensure threaded analysis is available
    if (contract.threaded_analysis == null and contract.code_size > 0) {
        if (threaded_analysis.analyzeThreaded(
            self.allocator,
            contract.code,
            contract.code_hash,
            &self.table,
        )) |analysis| {
            // Allocate and store analysis
            const analysis_ptr = try self.allocator.create(threaded_analysis.ThreadedAnalysis);
            analysis_ptr.* = analysis;
            contract.threaded_analysis = analysis_ptr;
        } else |err| {
            Log.debug("Failed to create threaded analysis: {}", .{err});
            return err;
        }
    }
    
    const analysis = contract.threaded_analysis orelse return ExecutionError.Error.InvalidOpcode;
    
    const initial_gas = contract.gas;
    self.depth += 1;
    defer self.depth -= 1;
    
    const prev_read_only = self.read_only;
    defer self.read_only = prev_read_only;
    
    self.read_only = self.read_only or is_static;
    
    // Create frame with threaded execution context
    var builder = Frame.builder(self.allocator);
    var frame = builder
        .withVm(self)
        .withContract(contract)
        .withGas(contract.gas)
        .withCaller(contract.caller)
        .withInput(input)
        .isStatic(self.read_only)
        .withDepth(@as(u32, @intCast(self.depth)))
        .build() catch |err| switch (err) {
        error.OutOfMemory => return ExecutionError.Error.OutOfMemory,
        error.MissingVm => unreachable,
        error.MissingContract => unreachable,
    };
    defer frame.deinit();
    
    // Set threaded execution fields
    frame.instructions = analysis.instructions;
    frame.push_values = analysis.push_values;
    frame.jumpdest_map = @constCast(&analysis.jumpdest_map);
    frame.current_block_gas = 0;
    frame.return_reason = .Continue;
    
    // Initialize stack
    frame.stack.ensureInitialized();
    
    // CRITICAL: The threaded execution loop - just 3 lines!
    var instr: ?*const @import("../frame/threaded_instruction.zig").ThreadedInstruction = 
        if (analysis.instructions.len > 0) &analysis.instructions[0] else null;
    
    Log.debug("Starting threaded execution: instructions_len={}, first_instr={any}", .{analysis.instructions.len, instr});
    
    var instruction_count: usize = 0;
    while (instr) |current| {
        instruction_count += 1;
        instr = current.exec_fn(current, &frame);
        if (frame.return_reason != .Continue) {
            Log.debug("Execution stopped after {} instructions, reason={}", .{instruction_count, frame.return_reason});
            break;
        }
    }
    
    // For empty code, set return reason to Stop
    if (analysis.instructions.len == 0 and frame.return_reason == .Continue) {
        frame.return_reason = .Stop;
    }
    
    // Handle results based on return reason
    contract.gas = frame.gas_remaining;
    
    const output_data = frame.output;
    self.return_data = @constCast(output_data);
    const output: ?[]const u8 = if (output_data.len > 0) 
        try self.allocator.dupe(u8, output_data) 
    else 
        null;
    
    return RunResult.init(
        initial_gas,
        frame.gas_remaining,
        switch (frame.return_reason) {
            .Stop, .Return => .Success,
            .Revert => .Revert,
            .OutOfGas => .OutOfGas,
            else => .Invalid,
        },
        switch (frame.return_reason) {
            .Stop => null,
            .Return => null,
            .Revert => ExecutionError.Error.REVERT,
            .OutOfGas => ExecutionError.Error.OutOfGas,
            else => ExecutionError.Error.InvalidOpcode,
        },
        output,
    );
}