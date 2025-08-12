const std = @import("std");
const Frame = @import("../frame.zig").Frame;
const ExecutionError = @import("../execution/execution_error.zig");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;

/// Dynamic gas calculation for CALL operation
pub fn call_dynamic_gas(frame: *Frame) ExecutionError.Error!u64 {
    // Stack layout: gas, to, value, args_offset, args_size, ret_offset, ret_size
    const stack_size = frame.stack.size();
    if (stack_size < 7) return 0; // Safety check
    
    // Get memory expansion parameters from stack (peek without popping)
    // Stack grows upward, so current - 1 is top of stack
    const stack_base = frame.stack.base;
    
    const to = stack_base[stack_size - 2];
    const args_offset = stack_base[stack_size - 4];
    const args_size = stack_base[stack_size - 5];
    const ret_offset = stack_base[stack_size - 6];
    const ret_size = stack_base[stack_size - 7];
    
    var total_gas: u64 = 0;
    
    // Calculate memory expansion for arguments
    if (args_size > 0) {
        if (args_offset > std.math.maxInt(usize) or args_size > std.math.maxInt(usize)) {
            return ExecutionError.Error.OutOfOffset;
        }
        const args_end = @as(usize, @intCast(args_offset)) + @as(usize, @intCast(args_size));
        total_gas += frame.memory.get_expansion_cost(@as(u64, @intCast(args_end)));
    }
    
    // Calculate memory expansion for return data
    if (ret_size > 0) {
        if (ret_offset > std.math.maxInt(usize) or ret_size > std.math.maxInt(usize)) {
            return ExecutionError.Error.OutOfOffset;
        }
        const ret_end = @as(usize, @intCast(ret_offset)) + @as(usize, @intCast(ret_size));
        const ret_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(ret_end)));
        // Only add if it's more than what we already calculated
        if (ret_gas > total_gas) {
            total_gas = ret_gas;
        }
    }
    
    // EIP-2929: Add cold/warm access costs
    if (frame.is_at_least(.BERLIN)) {
        const to_address = primitives.Address.from_u256(to);
        const access_cost = try frame.access_address(to_address);
        total_gas += access_cost;
    }
    
    return total_gas;
}

/// Dynamic gas calculation for CALLCODE operation
pub fn callcode_dynamic_gas(frame: *Frame) ExecutionError.Error!u64 {
    // CALLCODE has same memory expansion as CALL
    return call_dynamic_gas(frame);
}

/// Dynamic gas calculation for DELEGATECALL operation
pub fn delegatecall_dynamic_gas(frame: *Frame) ExecutionError.Error!u64 {
    // Stack layout: gas, to, args_offset, args_size, ret_offset, ret_size (no value)
    const stack_size = frame.stack.size();
    if (stack_size < 6) return 0;
    
    const stack_base = frame.stack.base;
    
    const to = stack_base[stack_size - 2];
    const args_offset = stack_base[stack_size - 3];
    const args_size = stack_base[stack_size - 4];
    const ret_offset = stack_base[stack_size - 5];
    const ret_size = stack_base[stack_size - 6];
    
    var total_gas: u64 = 0;
    
    // Calculate memory expansion for arguments
    if (args_size > 0) {
        if (args_offset > std.math.maxInt(usize) or args_size > std.math.maxInt(usize)) {
            return ExecutionError.Error.OutOfOffset;
        }
        const args_end = @as(usize, @intCast(args_offset)) + @as(usize, @intCast(args_size));
        total_gas += frame.memory.get_expansion_cost(@as(u64, @intCast(args_end)));
    }
    
    // Calculate memory expansion for return data
    if (ret_size > 0) {
        if (ret_offset > std.math.maxInt(usize) or ret_size > std.math.maxInt(usize)) {
            return ExecutionError.Error.OutOfOffset;
        }
        const ret_end = @as(usize, @intCast(ret_offset)) + @as(usize, @intCast(ret_size));
        const ret_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(ret_end)));
        if (ret_gas > total_gas) {
            total_gas = ret_gas;
        }
    }
    
    // EIP-2929: Add cold/warm access costs
    if (frame.is_at_least(.BERLIN)) {
        const to_address = primitives.Address.from_u256(to);
        const access_cost = try frame.access_address(to_address);
        total_gas += access_cost;
    }
    
    return total_gas;
}

/// Dynamic gas calculation for STATICCALL operation
pub fn staticcall_dynamic_gas(frame: *Frame) ExecutionError.Error!u64 {
    // STATICCALL has same stack layout as DELEGATECALL
    return delegatecall_dynamic_gas(frame);
}

/// Dynamic gas calculation for CREATE operation
pub fn create_dynamic_gas(frame: *Frame) ExecutionError.Error!u64 {
    // Stack layout: value, offset, size
    const stack_size = frame.stack.size();
    if (stack_size < 3) return 0;
    
    const stack_base = frame.stack.base;
    
    const offset = stack_base[stack_size - 2];
    const size = stack_base[stack_size - 3];
    
    if (size == 0) return 0;
    
    if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
        return ExecutionError.Error.OutOfOffset;
    }
    
    const end_offset = @as(usize, @intCast(offset)) + @as(usize, @intCast(size));
    return frame.memory.get_expansion_cost(@as(u64, @intCast(end_offset)));
}

/// Dynamic gas calculation for CREATE2 operation
pub fn create2_dynamic_gas(frame: *Frame) ExecutionError.Error!u64 {
    // Stack layout: value, offset, size, salt
    const stack_size = frame.stack.size();
    if (stack_size < 4) return 0;
    
    const stack_base = frame.stack.base;
    
    const offset = stack_base[stack_size - 2];
    const size = stack_base[stack_size - 3];
    
    var total_gas: u64 = 0;
    
    // Memory expansion cost
    if (size > 0) {
        if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
            return ExecutionError.Error.OutOfOffset;
        }
        const end_offset = @as(usize, @intCast(offset)) + @as(usize, @intCast(size));
        total_gas += frame.memory.get_expansion_cost(@as(u64, @intCast(end_offset)));
    }
    
    // CREATE2 has additional cost for hashing init code
    // Cost is proportional to init code size
    const word_size = (size + 31) / 32;
    total_gas += GasConstants.Keccak256WordGas * @as(u64, @intCast(word_size));
    
    return total_gas;
}

/// Dynamic gas calculation for SSTORE operation
pub fn sstore_dynamic_gas(frame: *Frame) ExecutionError.Error!u64 {
    // Stack layout: key, value
    const stack_size = frame.stack.size();
    if (stack_size < 2) return 0;
    
    // TODO: Implement proper SSTORE gas calculation
    // This requires:
    // 1. Check if storage slot is warm/cold (EIP-2929)
    // 2. Check current value vs new value for refunds
    // 3. Apply EIP-2200 gas metering rules
    
    // For now, return 0 as the static cost handles basic cases
    return 0;
}

/// Dynamic gas calculation for GAS opcode
/// GAS opcode doesn't have dynamic cost, but needs special handling
pub fn gas_dynamic_gas(frame: *Frame) ExecutionError.Error!u64 {
    _ = frame;
    return 0; // GAS opcode has no dynamic cost
}