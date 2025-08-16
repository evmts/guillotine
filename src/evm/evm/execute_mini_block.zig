const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const Evm = @import("../evm.zig");
const opcode_mod = @import("../opcodes/opcode.zig");
const Log = @import("../log.zig");

/// Result of block execution in Mini EVM
pub const BlockResult = struct {
    /// Final PC after executing the block
    final_pc: usize,
    /// Number of opcodes executed
    opcodes_executed: usize,
    /// Error if execution failed
    @"error": ?ExecutionError.Error,
    /// Whether execution terminated (STOP, RETURN, REVERT, etc.)
    terminated: bool,
};

/// Execute a block of opcodes in Mini EVM to match Main EVM's instruction block
/// 
/// This function executes opcodes starting from `start_pc` until:
/// 1. It reaches `end_pc` (exclusive)
/// 2. It encounters a terminating opcode (STOP, RETURN, REVERT)
/// 3. It encounters a jump that leaves the block
/// 4. An error occurs
///
/// @param self - The EVM instance
/// @param frame - The execution frame (stack, memory, etc.)
/// @param start_pc - Starting PC of the block
/// @param end_pc - Ending PC of the block (exclusive)
/// @param code - The bytecode being executed
/// @return BlockResult with execution details
pub fn execute_mini_block(
    self: *Evm,
    frame: *Frame,
    start_pc: usize,
    end_pc: usize,
    code: []const u8,
) BlockResult {
    Log.debug("[execute_mini_block] Executing block from PC {} to {}", .{ start_pc, end_pc });
    
    var pc = start_pc;
    var opcodes_executed: usize = 0;
    
    // Execute opcodes until we reach the end of the block or terminate
    while (pc < end_pc and pc < code.len) {
        const op = code[pc];
        const operation = self.table.get_operation(op);
        
        Log.debug("[execute_mini_block] PC={}, opcode=0x{x:0>2}", .{ pc, op });
        
        // Check if opcode is undefined
        if (operation.undefined) {
            return BlockResult{
                .final_pc = pc,
                .opcodes_executed = opcodes_executed,
                .@"error" = ExecutionError.Error.InvalidOpcode,
                .terminated = true,
            };
        }
        
        // Gas validation
        if (frame.gas_remaining < operation.constant_gas) {
            return BlockResult{
                .final_pc = pc,
                .opcodes_executed = opcodes_executed,
                .@"error" = ExecutionError.Error.OutOfGas,
                .terminated = true,
            };
        }
        frame.gas_remaining -= operation.constant_gas;
        
        // Stack validation
        if (frame.stack.size() < operation.min_stack) {
            return BlockResult{
                .final_pc = pc,
                .opcodes_executed = opcodes_executed,
                .@"error" = ExecutionError.Error.StackUnderflow,
                .terminated = true,
            };
        }
        if (frame.stack.size() > operation.max_stack) {
            return BlockResult{
                .final_pc = pc,
                .opcodes_executed = opcodes_executed,
                .@"error" = ExecutionError.Error.StackOverflow,
                .terminated = true,
            };
        }
        
        // Handle specific opcodes that affect control flow
        switch (op) {
            @intFromEnum(opcode_mod.Enum.STOP) => {
                return BlockResult{
                    .final_pc = pc,
                    .opcodes_executed = opcodes_executed + 1,
                    .@"error" = ExecutionError.Error.STOP,
                    .terminated = true,
                };
            },
            @intFromEnum(opcode_mod.Enum.JUMP) => {
                const dest = frame.stack.pop() catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                
                // Validate jump destination
                if (dest > code.len) {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = ExecutionError.Error.InvalidJump,
                        .terminated = true,
                    };
                }
                
                const dest_usize = @as(usize, @intCast(dest));
                if (dest_usize >= code.len or code[dest_usize] != @intFromEnum(opcode_mod.Enum.JUMPDEST)) {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = ExecutionError.Error.InvalidJump,
                        .terminated = true,
                    };
                }
                
                // Jump leaves the current block
                return BlockResult{
                    .final_pc = dest_usize,
                    .opcodes_executed = opcodes_executed + 1,
                    .@"error" = null,
                    .terminated = false,
                };
            },
            @intFromEnum(opcode_mod.Enum.JUMPI) => {
                const dest = frame.stack.pop() catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                const cond = frame.stack.pop() catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                
                if (cond != 0) {
                    // Taking the jump
                    if (dest > code.len) {
                        return BlockResult{
                            .final_pc = pc,
                            .opcodes_executed = opcodes_executed,
                            .@"error" = ExecutionError.Error.InvalidJump,
                            .terminated = true,
                        };
                    }
                    
                    const dest_usize = @as(usize, @intCast(dest));
                    if (dest_usize >= code.len or code[dest_usize] != @intFromEnum(opcode_mod.Enum.JUMPDEST)) {
                        return BlockResult{
                            .final_pc = pc,
                            .opcodes_executed = opcodes_executed,
                            .@"error" = ExecutionError.Error.InvalidJump,
                            .terminated = true,
                        };
                    }
                    
                    return BlockResult{
                        .final_pc = dest_usize,
                        .opcodes_executed = opcodes_executed + 1,
                        .@"error" = null,
                        .terminated = false,
                    };
                }
                
                // Not taking jump, continue to next instruction
                pc += 1;
                opcodes_executed += 1;
                continue;
            },
            @intFromEnum(opcode_mod.Enum.PC) => {
                frame.stack.append(@intCast(pc)) catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                pc += 1;
                opcodes_executed += 1;
                continue;
            },
            @intFromEnum(opcode_mod.Enum.RETURN) => {
                const offset = frame.stack.pop() catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                const size = frame.stack.pop() catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                
                // Set return data
                if (size > 0) {
                    const offset_usize = @as(usize, @intCast(offset));
                    const size_usize = @as(usize, @intCast(size));
                    const data = frame.memory.get_slice(offset_usize, size_usize) catch |err| {
                        return BlockResult{
                            .final_pc = pc,
                            .opcodes_executed = opcodes_executed,
                            .@"error" = err,
                            .terminated = true,
                        };
                    };
                    frame.host.set_output(data) catch {
                        return BlockResult{
                            .final_pc = pc,
                            .opcodes_executed = opcodes_executed,
                            .@"error" = ExecutionError.Error.DatabaseCorrupted,
                            .terminated = true,
                        };
                    };
                }
                
                return BlockResult{
                    .final_pc = pc,
                    .opcodes_executed = opcodes_executed + 1,
                    .@"error" = ExecutionError.Error.RETURN,
                    .terminated = true,
                };
            },
            @intFromEnum(opcode_mod.Enum.REVERT) => {
                const offset = frame.stack.pop() catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                const size = frame.stack.pop() catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                
                // Set revert data
                if (size > 0) {
                    const offset_usize = @as(usize, @intCast(offset));
                    const size_usize = @as(usize, @intCast(size));
                    const data = frame.memory.get_slice(offset_usize, size_usize) catch |err| {
                        return BlockResult{
                            .final_pc = pc,
                            .opcodes_executed = opcodes_executed,
                            .@"error" = err,
                            .terminated = true,
                        };
                    };
                    frame.host.set_output(data) catch {
                        return BlockResult{
                            .final_pc = pc,
                            .opcodes_executed = opcodes_executed,
                            .@"error" = ExecutionError.Error.DatabaseCorrupted,
                            .terminated = true,
                        };
                    };
                }
                
                return BlockResult{
                    .final_pc = pc,
                    .opcodes_executed = opcodes_executed + 1,
                    .@"error" = ExecutionError.Error.REVERT,
                    .terminated = true,
                };
            },
            else => {
                // Handle PUSH opcodes
                if (opcode_mod.is_push(op)) {
                    const push_size = opcode_mod.get_push_size(op);
                    
                    if (pc + push_size >= code.len) {
                        return BlockResult{
                            .final_pc = pc,
                            .opcodes_executed = opcodes_executed,
                            .@"error" = ExecutionError.Error.OutOfOffset,
                            .terminated = true,
                        };
                    }
                    
                    // Read push data
                    var value: u256 = 0;
                    const data_start = pc + 1;
                    const data_end = @min(data_start + push_size, code.len);
                    const data = code[data_start..data_end];
                    
                    // Convert bytes to u256 (big-endian)
                    for (data) |byte| {
                        value = (value << 8) | byte;
                    }
                    
                    frame.stack.append(value) catch |err| {
                        return BlockResult{
                            .final_pc = pc,
                            .opcodes_executed = opcodes_executed,
                            .@"error" = err,
                            .terminated = true,
                        };
                    };
                    
                    pc += 1 + push_size;
                    opcodes_executed += 1;
                    continue;
                }
                
                // For all other opcodes, use the execution function
                const execute_func = self.table.execute_funcs[op];
                execute_func(@ptrCast(frame)) catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                
                pc += 1;
                opcodes_executed += 1;
            },
        }
    }
    
    // Reached end of block normally
    return BlockResult{
        .final_pc = pc,
        .opcodes_executed = opcodes_executed,
        .@"error" = null,
        .terminated = false,
    };
}