/// Memory expansion analysis for pre-calculating gas costs during bytecode analysis.
///
/// This module analyzes memory access patterns during code analysis to:
/// 1. Pre-calculate memory expansion costs for static offsets
/// 2. Identify maximum memory usage per block
/// 3. Enable optimized memory operations without runtime gas calculations
///
/// ## Key Optimizations:
/// - Pre-calculated expansion costs stored in instruction arguments
/// - Block-level memory bounds checking
/// - Elimination of per-instruction expansion calculations

const std = @import("std");
const Allocator = std.mem.Allocator;
const opcode = @import("../opcodes/opcode.zig");
const primitives = @import("primitives");
const gas_constants = primitives.GasConstants;
const Log = @import("../log.zig");

/// Memory access information for an instruction
pub const MemoryAccess = struct {
    /// Type of memory access
    access_type: enum {
        read,       // MLOAD
        write,      // MSTORE, MSTORE8
        copy_read,  // Source for copy operations
        copy_write, // Destination for copy operations
        return_data, // RETURN, REVERT output
    },
    
    /// Offset into memory (if statically known)
    static_offset: ?u64 = null,
    
    /// Size of access (if statically known)
    static_size: ?u64 = null,
    
    /// Pre-calculated expansion cost (if offset/size are static)
    expansion_cost: ?u64 = null,
    
    /// Maximum possible memory size after this operation
    max_memory_size: u64 = 0,
};

/// Memory analysis result for a basic block
pub const BlockMemoryAnalysis = struct {
    /// Maximum memory size accessed in this block
    max_memory_size: u64 = 0,
    
    /// Total memory expansion cost for all static accesses
    total_static_expansion_cost: u64 = 0,
    
    /// Whether block has dynamic memory accesses
    has_dynamic_access: bool = false,
    
    /// Memory accesses by instruction PC
    accesses: std.AutoHashMap(usize, MemoryAccess),
};

/// Analyze memory access patterns in bytecode
pub fn analyze_memory_expansion(
    allocator: Allocator,
    bytecode: []const u8,
    block_starts: []const usize,
) ![]BlockMemoryAnalysis {
    var blocks = try allocator.alloc(BlockMemoryAnalysis, block_starts.len);
    errdefer allocator.free(blocks);
    
    // Initialize blocks
    for (blocks) |*block| {
        block.* = .{
            .accesses = std.AutoHashMap(usize, MemoryAccess).init(allocator),
        };
    }
    
    var pc: usize = 0;
    var current_block: usize = 0;
    var current_memory_size: u64 = 0;
    
    // Track push values for static analysis
    var push_stack = std.ArrayList(?u256).init(allocator);
    defer push_stack.deinit();
    
    while (pc < bytecode.len) {
        // Check if we're at a new block
        if (current_block + 1 < block_starts.len and pc >= block_starts[current_block + 1]) {
            current_block += 1;
            // Reset memory size tracking for new block (conservative)
            current_memory_size = 0;
            push_stack.clearRetainingCapacity();
        }
        
        const op = bytecode[pc];
        const op_enum = @as(opcode.Enum, @enumFromInt(op));
        
        switch (op_enum) {
            // Memory read operations
            .MLOAD => {
                if (push_stack.items.len > 0) {
                    const static_offset_opt_opt = push_stack.pop();
                    if (static_offset_opt_opt) |static_offset_opt| {
                        if (static_offset_opt) |static_offset| {
                            // Static offset - pre-calculate expansion
                            // SAFETY: We convert u256 to u64 here because:
                            // 1. Memory offsets beyond 2^64 are impractical due to gas costs
                            // 2. The EVM would run out of gas long before reaching such offsets
                            // 3. Memory expansion costs grow quadratically, making large offsets prohibitively expensive
                            // If the offset doesn't fit in u64, we treat it as a dynamic access
                            const max_u64 = std.math.maxInt(u64);
                                // Offset too large for u64 - treat as dynamic access
                                blocks[current_block].has_dynamic_access = true;
                                try blocks[current_block].accesses.put(pc, .{
                                    .access_type = .read,
                                });
                                continue;
                            }
                            const offset_u64 = @as(u64, static_offset);
                            
                            const required_size = offset_u64 + 32;
                            const expansion_cost = calculate_expansion_cost(current_memory_size, required_size);
                            
                            try blocks[current_block].accesses.put(pc, .{
                                .access_type = .read,
                                .static_offset = offset_u64,
                                .static_size = 32,
                                .expansion_cost = expansion_cost,
                                .max_memory_size = required_size,
                            });
                            
                            blocks[current_block].total_static_expansion_cost += expansion_cost;
                            current_memory_size = @max(current_memory_size, required_size);
                        } else {
                            // Dynamic offset (inner optional is null)
                            blocks[current_block].has_dynamic_access = true;
                            try blocks[current_block].accesses.put(pc, .{
                                .access_type = .read,
                            });
                        }
                    }
                } else {
                    // No value on stack to analyze
                    blocks[current_block].has_dynamic_access = true;
                    try blocks[current_block].accesses.put(pc, .{
                        .access_type = .read,
                    });
                }
                
                // Result replaces consumed value
                try push_stack.append(null);
            },
            
            // Memory write operations
            .MSTORE => {
                const value = if (push_stack.items.len > 0) push_stack.pop() else null;
                const offset = if (push_stack.items.len > 0) push_stack.pop() else null;
                _ = value;
                
                if (offset) |static_offset| {
                    // Static offset - pre-calculate expansion
                    // SAFETY: See MLOAD for rationale on u256 to u64 conversion
                    if (static_offset > std.math.maxInt(u64)) {
                        // Offset too large - treat as dynamic
                        blocks[current_block].has_dynamic_access = true;
                        try blocks[current_block].accesses.put(pc, .{
                            .access_type = .write,
                        });
                        continue;
                    }
                    const offset_u64 = @as(u64, static_offset);
                    const required_size = offset_u64 + 32;
                    const expansion_cost = calculate_expansion_cost(current_memory_size, required_size);
                    
                    try blocks[current_block].accesses.put(pc, .{
                        .access_type = .write,
                        .static_offset = offset_u64,
                        .static_size = 32,
                        .expansion_cost = expansion_cost,
                        .max_memory_size = required_size,
                    });
                    
                    blocks[current_block].total_static_expansion_cost += expansion_cost;
                    current_memory_size = @max(current_memory_size, required_size);
                } else {
                    // Dynamic offset
                    blocks[current_block].has_dynamic_access = true;
                    try blocks[current_block].accesses.put(pc, .{
                        .access_type = .write,
                    });
                }
            },
            
            .MSTORE8 => {
                const value = if (push_stack.items.len > 0) push_stack.pop() else null;
                const offset = if (push_stack.items.len > 0) push_stack.pop() else null;
                _ = value;
                
                if (offset) |static_offset| {
                    // Static offset - pre-calculate expansion
                    // SAFETY: See MLOAD for rationale on u256 to u64 conversion
                    if (static_offset > std.math.maxInt(u64)) {
                        // Offset too large - treat as dynamic
                        blocks[current_block].has_dynamic_access = true;
                        try blocks[current_block].accesses.put(pc, .{
                            .access_type = .write,
                        });
                        continue;
                    }
                    const offset_u64 = @as(u64, static_offset);
                    const required_size = offset_u64 + 1;
                    const expansion_cost = calculate_expansion_cost(current_memory_size, required_size);
                    
                    try blocks[current_block].accesses.put(pc, .{
                        .access_type = .write,
                        .static_offset = offset_u64,
                        .static_size = 1,
                        .expansion_cost = expansion_cost,
                        .max_memory_size = required_size,
                    });
                    
                    blocks[current_block].total_static_expansion_cost += expansion_cost;
                    current_memory_size = @max(current_memory_size, required_size);
                } else {
                    // Dynamic offset
                    blocks[current_block].has_dynamic_access = true;
                    try blocks[current_block].accesses.put(pc, .{
                        .access_type = .write,
                    });
                }
            },
            
            // Copy operations
            .CALLDATACOPY, .CODECOPY, .RETURNDATACOPY => {
                const size = if (push_stack.items.len > 0) push_stack.pop() else null;
                const src_offset = if (push_stack.items.len > 0) push_stack.pop() else null;
                const dest_offset = if (push_stack.items.len > 0) push_stack.pop() else null;
                _ = src_offset;
                
                if (dest_offset != null and size != null) {
                    // Static copy - pre-calculate expansion
                    // SAFETY: See MLOAD for rationale on u256 to u64 conversion
                    if (dest_offset.? > std.math.maxInt(u64)) {
                        // Values too large - treat as dynamic
                        blocks[current_block].has_dynamic_access = true;
                        try blocks[current_block].accesses.put(pc, .{
                            .access_type = .copy_write,
                        });
                        continue;
                    }
                    const dest_u64 = @as(u64, dest_offset.?);
                    if (size.? > std.math.maxInt(u64)) {
                        // Size too large - treat as dynamic
                        blocks[current_block].has_dynamic_access = true;
                        try blocks[current_block].accesses.put(pc, .{
                            .access_type = .copy_write,
                        });
                        continue;
                    }
                    const size_u64 = @as(u64, size.?);
                    const required_size = dest_u64 + size_u64;
                    const expansion_cost = calculate_expansion_cost(current_memory_size, required_size);
                    
                    try blocks[current_block].accesses.put(pc, .{
                        .access_type = .copy_write,
                        .static_offset = dest_u64,
                        .static_size = size_u64,
                        .expansion_cost = expansion_cost,
                        .max_memory_size = required_size,
                    });
                    
                    blocks[current_block].total_static_expansion_cost += expansion_cost;
                    current_memory_size = @max(current_memory_size, required_size);
                } else {
                    // Dynamic copy
                    blocks[current_block].has_dynamic_access = true;
                    try blocks[current_block].accesses.put(pc, .{
                        .access_type = .copy_write,
                    });
                }
            },
            
            // Return operations
            .RETURN, .REVERT => {
                const size = if (push_stack.items.len > 0) push_stack.pop() else null;
                const offset = if (push_stack.items.len > 0) push_stack.pop() else null;
                
                if (offset != null and size != null) {
                    // Skip zero-size returns as they don't expand memory
                    if (size.? == 0) {
                        continue;
                    }
                    // Static return data
                    // SAFETY: See MLOAD for rationale on u256 to u64 conversion
                    if (offset.? > std.math.maxInt(u64)) {
                        // Values too large - treat as dynamic
                        blocks[current_block].has_dynamic_access = true;
                        try blocks[current_block].accesses.put(pc, .{
                            .access_type = .return_data,
                        });
                        continue;
                    }
                    const offset_u64 = @as(u64, offset.?);
                    if (size.? > std.math.maxInt(u64)) {
                        // Size too large - treat as dynamic
                        blocks[current_block].has_dynamic_access = true;
                        try blocks[current_block].accesses.put(pc, .{
                            .access_type = .return_data,
                        });
                        continue;
                    }
                    const size_u64 = @as(u64, size.?);
                    const required_size = offset_u64 + size_u64;
                    const expansion_cost = calculate_expansion_cost(current_memory_size, required_size);
                    
                    try blocks[current_block].accesses.put(pc, .{
                        .access_type = .return_data,
                        .static_offset = offset_u64,
                        .static_size = size_u64,
                        .expansion_cost = expansion_cost,
                        .max_memory_size = required_size,
                    });
                    
                    blocks[current_block].total_static_expansion_cost += expansion_cost;
                    current_memory_size = @max(current_memory_size, required_size);
                } else if (size == null or (size != null and size.? > 0)) {
                    // Dynamic return data
                    blocks[current_block].has_dynamic_access = true;
                    try blocks[current_block].accesses.put(pc, .{
                        .access_type = .return_data,
                    });
                }
            },
            
            // Push operations - track for static analysis
            .PUSH0 => try push_stack.append(0),
            .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8,
            .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16,
            .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24,
            .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => |push_op| {
                _ = push_op;
                const n = @intFromEnum(op_enum) - @intFromEnum(opcode.Enum.PUSH1) + 1;
                const bytes = bytecode[pc + 1..][0..n];
                var value: u256 = 0;
                for (bytes) |byte| {
                    value = (value << 8) | byte;
                }
                try push_stack.append(value);
                pc += n; // Skip push data bytes
            },
            
            // DUP operations
            .DUP1, .DUP2, .DUP3, .DUP4, .DUP5, .DUP6, .DUP7, .DUP8,
            .DUP9, .DUP10, .DUP11, .DUP12, .DUP13, .DUP14, .DUP15, .DUP16 => {
                const n = @intFromEnum(op_enum) - @intFromEnum(opcode.Enum.DUP1) + 1;
                if (push_stack.items.len >= n) {
                    const value = push_stack.items[push_stack.items.len - n];
                    try push_stack.append(value);
                } else {
                    try push_stack.append(null);
                }
            },
            
            // Operations that consume stack values
            .POP => _ = if (push_stack.items.len > 0) push_stack.pop() else null,
            .ADD, .SUB, .MUL, .DIV, .MOD, .LT, .GT, .EQ => {
                _ = if (push_stack.items.len > 0) push_stack.pop() else null;
                _ = if (push_stack.items.len > 0) push_stack.pop() else null;
                try push_stack.append(null); // Result is dynamic
            },
            
            // Operations that invalidate static analysis
            .JUMP, .JUMPI => {
                // Clear stack on jumps as we can't track control flow statically
                push_stack.clearRetainingCapacity();
            },
            
            else => {
                // For other operations, conservatively assume they invalidate static values
                // This could be refined for specific opcodes
                const stack_consumed = get_stack_consumed(op_enum);
                var i: usize = 0;
                while (i < stack_consumed and push_stack.items.len > 0) : (i += 1) {
                    _ = push_stack.pop();
                }
                
                const stack_produced = get_stack_produced(op_enum);
                i = 0;
                while (i < stack_produced) : (i += 1) {
                    try push_stack.append(null);
                }
            },
        }
        
        // Update block's max memory size
        blocks[current_block].max_memory_size = @max(blocks[current_block].max_memory_size, current_memory_size);
        
        // Advance PC
        pc += 1;
    }
    
    return blocks;
}

/// Calculate memory expansion gas cost
fn calculate_expansion_cost(current_size: u64, new_size: u64) u64 {
    if (new_size <= current_size) return 0;
    
    const current_words = gas_constants.wordCount(current_size);
    const new_words = gas_constants.wordCount(new_size);
    
    const current_cost = 3 * current_words + (current_words * current_words) / 512;
    const new_cost = 3 * new_words + (new_words * new_words) / 512;
    
    return new_cost - current_cost;
}

/// Get number of stack items consumed by opcode (simplified)
fn get_stack_consumed(op: opcode.Enum) usize {
    return switch (op) {
        .STOP, .RETURN, .REVERT, .INVALID => 2,
        .ADD, .SUB, .MUL, .DIV, .SDIV, .MOD, .SMOD, .EXP, .LT, .GT, .SLT, .SGT, .EQ, .AND, .OR, .XOR => 2,
        .ADDMOD, .MULMOD => 3,
        .SIGNEXTEND, .SHL, .SHR, .SAR => 2,
        .KECCAK256 => 2,
        .CALLDATALOAD, .MLOAD, .SLOAD => 1,
        .MSTORE, .MSTORE8, .SSTORE => 2,
        .JUMP => 1,
        .JUMPI => 2,
        .CALLDATACOPY, .CODECOPY, .RETURNDATACOPY => 3,
        .POP => 1,
        .LOG0 => 2,
        .LOG1 => 3,
        .LOG2 => 4,
        .LOG3 => 5,
        .LOG4 => 6,
        .CREATE => 3,
        .CREATE2 => 4,
        .CALL, .CALLCODE => 7,
        .DELEGATECALL, .STATICCALL => 6,
        .SELFDESTRUCT => 1,
        else => 0,
    };
}

/// Get number of stack items produced by opcode (simplified)
fn get_stack_produced(op: opcode.Enum) usize {
    return switch (op) {
        .STOP, .RETURN, .REVERT, .INVALID, .SELFDESTRUCT => 0,
        .CALLDATACOPY, .CODECOPY, .RETURNDATACOPY => 0,
        .MSTORE, .MSTORE8, .SSTORE => 0,
        .JUMP, .JUMPI => 0,
        .POP => 0,
        .LOG0, .LOG1, .LOG2, .LOG3, .LOG4 => 0,
        .CREATE, .CREATE2, .CALL, .CALLCODE, .DELEGATECALL, .STATICCALL => 1,
        else => 1, // Most operations produce 1 value
    };
}

test "memory expansion analysis" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Bytecode: PUSH1 0x20, PUSH1 0x00, MSTORE (store 32 at offset 0)
    const bytecode = [_]u8{ 0x60, 0x20, 0x60, 0x00, 0x52 };
    const block_starts = [_]usize{0};
    
    const blocks = try analyze_memory_expansion(allocator, &bytecode, &block_starts);
    defer {
        for (blocks) |*block| {
            block.accesses.deinit();
        }
        allocator.free(blocks);
    }
    
    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expectEqual(@as(u64, 32), blocks[0].max_memory_size);
    try testing.expect(blocks[0].accesses.contains(4)); // MSTORE at PC 4
    
    const mstore_access = blocks[0].accesses.get(4).?;
    try testing.expectEqual(@as(u64, 0), mstore_access.static_offset.?);
    try testing.expectEqual(@as(u64, 32), mstore_access.static_size.?);
    try testing.expect(mstore_access.expansion_cost.? > 0);
}