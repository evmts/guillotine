const std = @import("std");
const Operation = @import("../opcodes/operation.zig").Operation;
const ExecutionFunc = @import("../opcodes/operation.zig").ExecutionFunc;

/// Struct-of-Arrays implementation of the jump table for improved cache locality.
/// 
/// Instead of storing an array of Operation structs (AoS), we store separate arrays
/// for each field (SoA). This improves cache utilization because:
/// 1. Hot fields (execute, gas) are accessed together in tight loops
/// 2. Cold fields (dynamic_gas, memory_size) don't pollute cache lines
/// 3. Better SIMD opportunities for batch operations
///
/// Memory layout:
/// - execute_funcs: 256 * 8 bytes = 2KB (fits in L1 cache)
/// - constant_gas: 256 * 8 bytes = 2KB (fits in L1 cache)
/// - min_stack: 256 * 4 bytes = 1KB
/// - max_stack: 256 * 4 bytes = 1KB
/// - undefined_flags: 256 * 1 byte = 256 bytes
/// Total: ~6.25KB vs 10KB+ for AoS
pub const SoaJumpTable = struct {
    /// Execution function pointers - hot path, accessed every opcode
    execute_funcs: [256]ExecutionFunc align(64),
    
    /// Constant gas costs - hot path, accessed every opcode
    constant_gas: [256]u64 align(64),
    
    /// Stack validation data - warm path, accessed every opcode but predictable
    min_stack: [256]u32 align(64),
    max_stack: [256]u32 align(64),
    
    /// Undefined flags - cold path, rarely accessed
    undefined_flags: [256]bool align(64),
    
    /// Initialize from existing AoS jump table
    pub fn init_from_aos(aos_table: *const @import("jump_table.zig")) SoaJumpTable {
        var soa = SoaJumpTable{
            .execute_funcs = undefined,
            .constant_gas = undefined,
            .min_stack = undefined,
            .max_stack = undefined,
            .undefined_flags = undefined,
        };
        
        // Convert AoS to SoA
        for (0..256) |i| {
            const op = aos_table.get_operation(@intCast(i));
            soa.execute_funcs[i] = op.execute;
            soa.constant_gas[i] = op.constant_gas;
            soa.min_stack[i] = op.min_stack;
            soa.max_stack[i] = op.max_stack;
            soa.undefined_flags[i] = op.undefined;
        }
        
        return soa;
    }
    
    /// Get operation data using SoA access pattern
    pub inline fn get_operation_soa(self: *const SoaJumpTable, opcode: u8) struct {
        execute: ExecutionFunc,
        gas: u64,
        min_stack: u32,
        max_stack: u32,
        undefined: bool,
    } {
        return .{
            .execute = self.execute_funcs[opcode],
            .gas = self.constant_gas[opcode],
            .min_stack = self.min_stack[opcode],
            .max_stack = self.max_stack[opcode],
            .undefined = self.undefined_flags[opcode],
        };
    }
    
    /// Optimized hot path - just get execute and gas
    pub inline fn get_hot_fields(self: *const SoaJumpTable, opcode: u8) struct {
        execute: ExecutionFunc,
        gas: u64,
    } {
        return .{
            .execute = self.execute_funcs[opcode],
            .gas = self.constant_gas[opcode],
        };
    }
    
    /// Optimized stack validation - just get min/max stack
    pub inline fn get_stack_requirements(self: *const SoaJumpTable, opcode: u8) struct {
        min_stack: u32,
        max_stack: u32,
    } {
        return .{
            .min_stack = self.min_stack[opcode],
            .max_stack = self.max_stack[opcode],
        };
    }
};