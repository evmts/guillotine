const std = @import("std");
const Frame = @import("../frame/frame.zig");
const Stack = @import("../stack/stack.zig");
const ThreadedInstruction = @import("../frame/threaded_instruction.zig").ThreadedInstruction;
const ThreadedExecFunc = @import("../frame/threaded_instruction.zig").ThreadedExecFunc;
const primitives = @import("primitives");

/// Generic wrapper for simple operations
pub fn makeThreadedOp(comptime op_fn: fn(*Frame) void) ThreadedExecFunc {
    return struct {
        fn exec(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
            op_fn(state);
            return instr + 1;
        }
    }.exec;
}

/// Wrapper for operations that can fail
pub fn makeThreadedOpWithError(comptime op_fn: fn(*Frame) !void) ThreadedExecFunc {
    return struct {
        fn exec(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
            op_fn(state) catch return null;
            return instr + 1;
        }
    }.exec;
}

// Arithmetic operations
pub const op_add_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        state.stack.push_unsafe(a +% b);
    }
}.op);

pub const op_mul_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        state.stack.push_unsafe(a *% b);
    }
}.op);

pub const op_sub_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        state.stack.push_unsafe(a -% b);
    }
}.op);

pub const op_div_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        if (b == 0) {
            state.stack.push_unsafe(0);
        } else {
            state.stack.push_unsafe(a / b);
        }
    }
}.op);

// Stack operations with embedded values
pub fn op_push_small_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    state.stack.push_unsafe(@as(primitives.U256, instr.arg.small_push));
    return instr + 1;
}

pub fn op_push_large_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    const value = state.push_values[instr.arg.large_push_idx];
    state.stack.push_unsafe(value);
    return instr + 1;
}

pub fn op_pop_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    _ = state.stack.pop_unsafe();
    return instr + 1;
}

// Control flow
pub fn op_jump_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    const target = state.stack.pop_unsafe();
    
    // Use pre-validated jump destination
    if (target > std.math.maxInt(u32)) return null;
    const target_idx = state.jumpdest_map.get(@intCast(target)) orelse return null;
    
    return &state.instructions[target_idx];
}

pub fn op_jumpi_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    const target = state.stack.pop_unsafe();
    const condition = state.stack.pop_unsafe();
    
    if (condition != 0) {
        if (target > std.math.maxInt(u32)) return null;
        const target_idx = state.jumpdest_map.get(@intCast(target)) orelse return null;
        return &state.instructions[target_idx];
    }
    
    return instr + 1;
}

pub fn op_jumpdest_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    _ = state;
    return instr + 1;
}

// Block boundaries
pub fn opx_beginblock_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    const block = instr.arg.block_info;
    
    // Consume gas for entire block
    if (state.gas_remaining < block.gas_cost) return null;
    state.gas_remaining -= block.gas_cost;
    
    // Validate stack requirements
    const stack_size: i32 = @intCast(state.stack.size());
    if (stack_size < block.stack_req) return null;
    if (stack_size + block.stack_max_growth > Stack.CAPACITY) return null;
    
    state.current_block_gas = block.gas_cost;
    return instr + 1;
}

// Termination
pub fn op_stop_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    _ = instr;
    state.return_reason = .Stop;
    return null;
}

pub fn op_return_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    _ = instr;
    const size = state.stack.pop_unsafe();
    const offset = state.stack.pop_unsafe();
    
    // Set output data
    if (size > 0) {
        const size_usize: usize = @intCast(@min(size, std.math.maxInt(usize)));
        const offset_usize: usize = @intCast(@min(offset, std.math.maxInt(usize)));
        
        const data = state.memory.read_slice(offset_usize, size_usize) catch return null;
        state.output = data;
    }
    
    state.return_reason = .Return;
    return null;
}

pub fn op_revert_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    _ = instr;
    const size = state.stack.pop_unsafe();
    const offset = state.stack.pop_unsafe();
    
    // Set output data
    if (size > 0) {
        const size_usize: usize = @intCast(@min(size, std.math.maxInt(usize)));
        const offset_usize: usize = @intCast(@min(offset, std.math.maxInt(usize)));
        
        const data = state.memory.read_slice(offset_usize, size_usize) catch return null;
        state.output = data;
    }
    
    state.return_reason = .Revert;
    return null;
}

// Operations with embedded PC value
pub fn op_pc_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    state.stack.push_unsafe(@as(primitives.U256, instr.arg.pc_value));
    return instr + 1;
}

// Operations with gas correction
pub fn op_gas_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    const correction = state.current_block_gas - instr.arg.gas_correction;
    const gas: primitives.U256 = @intCast(state.gas_remaining + correction);
    state.stack.push_unsafe(gas);
    return instr + 1;
}

// Invalid operation
pub fn op_invalid_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    _ = instr;
    _ = state;
    return null;
}

// DUP operations generator
pub fn makeDupThreaded(comptime n: u8) ThreadedExecFunc {
    return struct {
        fn exec(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
            _ = instr;
            const value = state.stack.peek(n - 1) catch return null;
            state.stack.push_unsafe(value);
            return instr + 1;
        }
    }.exec;
}

// SWAP operations generator
pub fn makeSwapThreaded(comptime n: u8) ThreadedExecFunc {
    return struct {
        fn exec(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
            _ = instr;
            state.stack.swap(0, n) catch return null;
            return instr + 1;
        }
    }.exec;
}

// LOG operations generator
pub fn makeLogThreaded(comptime topics: u8) ThreadedExecFunc {
    return struct {
        fn exec(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
            _ = instr;
            _ = state;
            _ = topics;
            // TODO: Implement LOG operations
            return instr + 1;
        }
    }.exec;
}

/// Get threaded function for an opcode
pub fn getThreadedFunction(opcode: u8) ThreadedExecFunc {
    return switch (opcode) {
        // Arithmetic
        0x01 => op_add_threaded,
        0x02 => op_mul_threaded,
        0x03 => op_sub_threaded,
        0x04 => op_div_threaded,
        // ... all arithmetic ops would be mapped here
        
        // Stack operations handled specially for PUSH
        0x50 => op_pop_threaded,
        // ... memory ops would be mapped here
        
        // Control flow
        0x56 => op_jump_threaded,
        0x57 => op_jumpi_threaded,
        0x58 => op_pc_threaded,
        0x5a => op_gas_threaded,
        0x5b => op_jumpdest_threaded,
        
        // System
        0x00 => op_stop_threaded,
        0xf3 => op_return_threaded,
        0xfd => op_revert_threaded,
        
        // DUP operations
        0x80...0x8f => makeDupThreaded(opcode - 0x7f),
        
        // SWAP operations  
        0x90...0x9f => makeSwapThreaded(opcode - 0x8f),
        
        // LOG operations
        0xa0...0xa4 => makeLogThreaded(opcode - 0xa0),
        
        // Invalid/undefined
        else => op_invalid_threaded,
    };
}