// ============================================================================
// BYTECODE DISASSEMBLY C API - FFI wrapper for bytecode disassembly
// ============================================================================
//
// This module provides a thin C-compatible wrapper around the existing
// BytecodeDisassembly.analyze function, exposing it directly to FFI consumers.

const std = @import("std");
const BytecodeDisassembly = @import("bytecode_disassembly.zig").BytecodeDisassembly;
const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig;
const BytecodeType = @import("bytecode.zig").Bytecode(BytecodeConfig{});

// Default frame configuration for disassembly
const frame_config = @import("frame_config.zig").FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 24576,
    .block_gas_limit = 30_000_000,
    .DatabaseType = @import("database.zig").Database,
    .TracerType = null,
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF,
};
const FrameType = @import("frame.zig").Frame(frame_config);

const allocator = std.heap.c_allocator;

/// Main struct to organize C API functions, similar to BytecodeDisassembly
pub const BytecodeDisassemblyC = struct {
    // ============================================================================
    // ERROR CODES
    // ============================================================================
    
    pub const EVM_DISASM_SUCCESS: c_int = 0;
    pub const EVM_DISASM_ERROR_NULL_POINTER: c_int = -1;
    pub const EVM_DISASM_ERROR_INVALID_BYTECODE: c_int = -2;
    pub const EVM_DISASM_ERROR_OUT_OF_MEMORY: c_int = -3;
    
    // ============================================================================
    // C-COMPATIBLE STRUCTURES (mirrors the Zig structures)
    // ============================================================================
    
    /// C-compatible instruction representation
    pub const CInstruction = extern struct {
    pc: u32,
    opcode_name: [*:0]const u8,  // Null-terminated string for C
    opcode_hex: u8,
    gas_cost: u16,
    stack_inputs: u8,
    stack_outputs: u8,
    // Push value decomposed into 4 u64s for C compatibility
    push_value_low: u64,
    push_value_high: u64,
    push_value_extra_high: u64,
    push_value_top: u64,
    has_push_value: u8,
};

/// C-compatible basic block representation
pub const CBasicBlock = extern struct {
    start: u32,
    end: u32,
};

/// C-compatible statistics structure
pub const CStats = extern struct {
    original_size: u32,
    dispatch_size: u32,
    gas_first_block: u32,
    jumpdest_count: u32,
    basic_block_count: u32,
};

/// C-compatible complete result structure
pub const CResult = extern struct {
    instructions: [*]CInstruction,
    instruction_count: u32,
    jumpdests: [*]u32,
    jumpdest_count: u32,
    basic_blocks: [*]CBasicBlock,
    basic_block_count: u32,
    stats: CStats,
};

    // ============================================================================
    // MAIN API - Direct wrapper around BytecodeDisassembly.analyze
    // ============================================================================
    
    /// Disassemble bytecode - direct wrapper of BytecodeDisassembly.analyze
    /// @param data Raw bytecode bytes
    /// @param data_len Length of bytecode
    /// @param result_out Pointer to CResult structure to fill
    /// @return Error code (0 for success)
    pub fn analyze(
    data: [*]const u8,
    data_len: usize,
    result_out: *CResult
) c_int {
    // Create bytecode from input
    var bytecode = BytecodeType.init(allocator, data[0..data_len]) catch {
        return EVM_DISASM_ERROR_INVALID_BYTECODE;
    };
    defer bytecode.deinit();

    // Call the actual disassemble function from bytecode_disassembly.zig
    var zig_result = BytecodeDisassembly.analyze(allocator, bytecode, FrameType) catch {
        return EVM_DISASM_ERROR_OUT_OF_MEMORY;
    };
    defer zig_result.deinit(allocator);

    // Convert instructions to C format
    const c_instructions = allocator.alloc(CInstruction, zig_result.bytecode_instructions.len) catch {
        return EVM_DISASM_ERROR_OUT_OF_MEMORY;
    };
    errdefer allocator.free(c_instructions);

    for (zig_result.bytecode_instructions, 0..) |inst, i| {
        var push_low: u64 = 0;
        var push_high: u64 = 0;
        var push_extra_high: u64 = 0;
        var push_top: u64 = 0;
        var has_push: u8 = 0;

        if (inst.push_value) |value| {
            has_push = 1;
            push_low = @truncate(value);
            push_high = @truncate(value >> 64);
            push_extra_high = @truncate(value >> 128);
            push_top = @truncate(value >> 192);
        }

        // Allocate and copy the opcode name string for C
        const name_z = allocator.dupeZ(u8, inst.opcode_name) catch {
            // Clean up previously allocated names
            for (0..i) |j| {
                allocator.free(std.mem.span(c_instructions[j].opcode_name));
            }
            allocator.free(c_instructions);
            return EVM_DISASM_ERROR_OUT_OF_MEMORY;
        };

        c_instructions[i] = .{
            .pc = inst.pc,
            .opcode_name = name_z.ptr,
            .opcode_hex = inst.opcode_hex,
            .gas_cost = inst.gas_cost,
            .stack_inputs = inst.stack_inputs,
            .stack_outputs = inst.stack_outputs,
            .push_value_low = push_low,
            .push_value_high = push_high,
            .push_value_extra_high = push_extra_high,
            .push_value_top = push_top,
            .has_push_value = has_push,
        };
    }

    // Copy jumpdests (already u32)
    const c_jumpdests = allocator.dupe(u32, zig_result.jumpdests) catch {
        // Clean up allocated names
        for (0..c_instructions.len) |j| {
            allocator.free(std.mem.span(c_instructions[j].opcode_name));
        }
        allocator.free(c_instructions);
        return EVM_DISASM_ERROR_OUT_OF_MEMORY;
    };
    errdefer allocator.free(c_jumpdests);

    // Convert basic blocks to C format
    const c_blocks = allocator.alloc(CBasicBlock, zig_result.basic_blocks.len) catch {
        // Clean up allocated names
        for (0..c_instructions.len) |j| {
            allocator.free(std.mem.span(c_instructions[j].opcode_name));
        }
        allocator.free(c_instructions);
        allocator.free(c_jumpdests);
        return EVM_DISASM_ERROR_OUT_OF_MEMORY;
    };
    errdefer allocator.free(c_blocks);

    for (zig_result.basic_blocks, 0..) |block, i| {
        c_blocks[i] = .{
            .start = block.start,
            .end = block.end,
        };
    }

    // Fill result structure
    result_out.* = .{
        .instructions = c_instructions.ptr,
        .instruction_count = @intCast(c_instructions.len),
        .jumpdests = c_jumpdests.ptr,
        .jumpdest_count = @intCast(c_jumpdests.len),
        .basic_blocks = c_blocks.ptr,
        .basic_block_count = @intCast(c_blocks.len),
        .stats = .{
            .original_size = @intCast(zig_result.stats.original_size),
            .dispatch_size = @intCast(zig_result.stats.dispatch_size),
            .gas_first_block = zig_result.stats.gas_first_block,
            .jumpdest_count = @intCast(zig_result.stats.jumpdest_count),
            .basic_block_count = @intCast(zig_result.stats.basic_block_count),
        },
    };

    return EVM_DISASM_SUCCESS;
}

    /// Free memory allocated by analyze function
    /// @param result Pointer to result structure returned by analyze
    pub fn free_result(result: *CResult) void {
    if (result.instruction_count > 0) {
        // Free opcode name strings
        for (0..result.instruction_count) |i| {
            allocator.free(std.mem.span(result.instructions[i].opcode_name));
        }
        allocator.free(result.instructions[0..result.instruction_count]);
    }
    if (result.jumpdest_count > 0) {
        allocator.free(result.jumpdests[0..result.jumpdest_count]);
    }
    if (result.basic_block_count > 0) {
        allocator.free(result.basic_blocks[0..result.basic_block_count]);
    }
    result.* = std.mem.zeroes(CResult);
}

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

    /// Convert error code to string
    pub fn error_string(error_code: c_int) [*:0]const u8 {
    return switch (error_code) {
        EVM_DISASM_SUCCESS => "Success",
        EVM_DISASM_ERROR_NULL_POINTER => "Null pointer",
        EVM_DISASM_ERROR_INVALID_BYTECODE => "Invalid bytecode",
        EVM_DISASM_ERROR_OUT_OF_MEMORY => "Out of memory",
        else => "Unknown error",
    };
    }
};

// ============================================================================
// TESTING
// ============================================================================

test "C API direct analyze function" {
    const code = [_]u8{ 0x60, 0x42, 0x60, 0x10, 0x01, 0x00 }; // PUSH1 42 PUSH1 16 ADD STOP
    
    var result: BytecodeDisassemblyC.CResult = undefined;
    const rc = BytecodeDisassemblyC.analyze(&code, code.len, &result);
    defer BytecodeDisassemblyC.free_result(&result);
    
    try std.testing.expectEqual(BytecodeDisassemblyC.EVM_DISASM_SUCCESS, rc);
    try std.testing.expectEqual(@as(u32, 4), result.instruction_count);
    try std.testing.expectEqual(@as(u32, 0), result.jumpdest_count);
    
    // Check first instruction
    try std.testing.expectEqual(@as(u32, 0), result.instructions[0].pc);
    try std.testing.expectEqual(@as(u8, 0x60), result.instructions[0].opcode_hex);
    try std.testing.expectEqual(@as(u8, 1), result.instructions[0].has_push_value);
    try std.testing.expectEqual(@as(u64, 0x42), result.instructions[0].push_value_low);
}

test "C API with jumpdests" {
    const code = [_]u8{ 0x5b, 0x60, 0x01, 0x5b, 0x00 }; // JUMPDEST PUSH1 1 JUMPDEST STOP
    
    var result: BytecodeDisassemblyC.CResult = undefined;
    const rc = BytecodeDisassemblyC.analyze(&code, code.len, &result);
    defer BytecodeDisassemblyC.free_result(&result);
    
    try std.testing.expectEqual(BytecodeDisassemblyC.EVM_DISASM_SUCCESS, rc);
    try std.testing.expectEqual(@as(u32, 4), result.instruction_count);
    try std.testing.expectEqual(@as(u32, 2), result.jumpdest_count);
    try std.testing.expectEqual(@as(u32, 0), result.jumpdests[0]);
    try std.testing.expectEqual(@as(u32, 3), result.jumpdests[1]);
}

test "C API opcode names in instructions" {
    const code = [_]u8{ 0x60, 0x42, 0x01, 0x00 }; // PUSH1 42 ADD STOP
    
    var result: BytecodeDisassemblyC.CResult = undefined;
    const rc = BytecodeDisassemblyC.analyze(&code, code.len, &result);
    defer BytecodeDisassemblyC.free_result(&result);
    
    try std.testing.expectEqual(BytecodeDisassemblyC.EVM_DISASM_SUCCESS, rc);
    try std.testing.expectEqual(@as(u32, 3), result.instruction_count);
    
    // Check opcode names are correctly set
    try std.testing.expect(std.mem.eql(u8, std.mem.span(result.instructions[0].opcode_name), "PUSH1"));
    try std.testing.expect(std.mem.eql(u8, std.mem.span(result.instructions[1].opcode_name), "ADD"));
    try std.testing.expect(std.mem.eql(u8, std.mem.span(result.instructions[2].opcode_name), "STOP"));
}