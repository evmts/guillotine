// ============================================================================
// BYTECODE DISASSEMBLY C API - FFI wrapper for bytecode disassembly
// ============================================================================
//
// This module provides a thin C-compatible wrapper around the
// BytecodeDisassembly.analyze function, exposing it directly to FFI consumers.

const std = @import("std");
const BytecodeDisassembly = @import("bytecode_disassembly.zig").BytecodeDisassembly;
const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig;
const BytecodeType = @import("bytecode.zig").Bytecode(BytecodeConfig{});

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
    // ANALYSIS STRUCTURES
    // ============================================================================

    /// C-compatible analysis instruction representation (matches Go struct)
    pub const CAnalysisInstruction = extern struct {
        original_pc: u32,
        instruction_type: CInstructionType,
        gas_cost: u32,
        stack_inputs: u8,
        stack_outputs: u8,
        
        // Regular instruction data
        regular_opcode: u8,
        regular_name: [*:0]const u8,
        
        // Fusion value data (for push fusions)
        fusion_value_low: u64,
        fusion_value_high: u64,
        fusion_value_extra_high: u64,
        fusion_value_top: u64,
        has_fusion_value: u8,
        value_storage: CValueStorage,
        
        // Advanced fusion data
        folded_value_low: u64,
        folded_value_high: u64,
        folded_value_extra_high: u64,
        folded_value_top: u64,
        fusion_count: u8,
        original_length: u8,
        target_pc: u32, // for static jump candidates
        operation_name: [*:0]const u8,
        
        // Original opcodes array
        original_opcodes: [*]COriginalOpcode,
        original_opcodes_count: u32,
    };

    /// C-compatible original opcode representation
    pub const COriginalOpcode = extern struct {
        pc: u32,
        opcode: u8,
        name: [*:0]const u8,
        has_push_value: u8,
        push_value_low: u64,
        push_value_high: u64,
        push_value_extra_high: u64,
        push_value_top: u64,
    };

    /// Value storage type for C compatibility
    pub const CValueStorage = enum(u8) {
        VALUE_STORAGE_INLINE_64BIT = 0,
        VALUE_STORAGE_POINTER_LARGE = 1,
    };

    /// C-compatible analysis statistics
    pub const CAnalysisStats = extern struct {
        original_count: u32,
        optimized_count: u32,
        fusion_count: u32,
        inline_value_count: u32,
        pointer_value_count: u32,
        static_jump_candidates: u32,
        gas_saved_estimate: u32,
        compression_ratio: f32,
    };

    /// C-compatible analysis result structure
    pub const CAnalysisResult = extern struct {
        instructions: [*]CAnalysisInstruction,
        instruction_count: u32,
        stats: CAnalysisStats,
    };

    /// Instruction type enum for C
    pub const CInstructionType = enum(u8) {
        REGULAR = 0,
        PUSH_ADD_FUSION = 1,
        PUSH_MUL_FUSION = 2,
        PUSH_SUB_FUSION = 3,
        PUSH_DIV_FUSION = 4,
        PUSH_AND_FUSION = 5,
        PUSH_OR_FUSION = 6,
        PUSH_XOR_FUSION = 7,
        PUSH_JUMP_FUSION = 8,
        PUSH_JUMPI_FUSION = 9,
        CONSTANT_FOLD = 10,
        MULTI_PUSH = 11,
        MULTI_POP = 12,
        ISZERO_JUMPI = 13,
        DUP2_MSTORE_PUSH = 14,
        STATIC_JUMP_CANDIDATE = 15,
    };

    // ============================================================================
    // MAIN API - BytecodeDisassembly.analyze wrapper
    // ============================================================================

    /// Analyze bytecode with analysis information - wrapper of BytecodeDisassembly.analyze
    /// @param data Raw bytecode bytes
    /// @param data_len Length of bytecode
    /// @param result_out Pointer to CAnalysisResult structure to fill
    /// @return Error code (0 for success)
    pub fn analyze(
        data: [*]const u8,
        data_len: usize,
        result_out: *CAnalysisResult
    ) c_int {
        // Create bytecode from input
        var bytecode = BytecodeType.init(allocator, data[0..data_len]) catch {
            return EVM_DISASM_ERROR_INVALID_BYTECODE;
        };
        defer bytecode.deinit();

        // Call the analyze function
        var zig_result = BytecodeDisassembly.analyze(allocator, bytecode) catch {
            return EVM_DISASM_ERROR_OUT_OF_MEMORY;
        };
        defer zig_result.deinit();

        // Convert instructions to C format
        const c_instructions = allocator.alloc(CAnalysisInstruction, zig_result.instructions.len) catch {
            return EVM_DISASM_ERROR_OUT_OF_MEMORY;
        };

        for (zig_result.instructions, 0..) |instr, i| {
            // Convert original opcodes
            const c_original_opcodes = allocator.alloc(COriginalOpcode, instr.original_opcodes.len) catch {
                return EVM_DISASM_ERROR_OUT_OF_MEMORY;
            };

            for (instr.original_opcodes, 0..) |orig, j| {
                var push_low: u64 = 0;
                var push_high: u64 = 0;
                var push_extra_high: u64 = 0;
                var push_top: u64 = 0;
                var has_push: u8 = 0;

                if (orig.push_value) |value| {
                    has_push = 1;
                    push_low = @truncate(value);
                    push_high = @truncate(value >> 64);
                    push_extra_high = @truncate(value >> 128);
                    push_top = @truncate(value >> 192);
                }

                const name_z = allocator.dupeZ(u8, orig.name) catch {
                    return EVM_DISASM_ERROR_OUT_OF_MEMORY;
                };

                c_original_opcodes[j] = .{
                    .pc = orig.pc,
                    .opcode = orig.opcode,
                    .name = name_z.ptr,
                    .has_push_value = has_push,
                    .push_value_low = push_low,
                    .push_value_high = push_high,
                    .push_value_extra_high = push_extra_high,
                    .push_value_top = push_top,
                };
            }

            // Initialize all fields with defaults
            var c_instr = CAnalysisInstruction{
                .original_pc = instr.original_pc,
                .instruction_type = CInstructionType.REGULAR,
                .gas_cost = instr.gas_cost,
                .stack_inputs = instr.stack_inputs,
                .stack_outputs = instr.stack_outputs,
                .regular_opcode = 0,
                .regular_name = "",
                .fusion_value_low = 0,
                .fusion_value_high = 0,
                .fusion_value_extra_high = 0,
                .fusion_value_top = 0,
                .has_fusion_value = 0,
                .value_storage = CValueStorage.VALUE_STORAGE_INLINE_64BIT,
                .folded_value_low = 0,
                .folded_value_high = 0,
                .folded_value_extra_high = 0,
                .folded_value_top = 0,
                .fusion_count = 0,
                .original_length = 0, // Default value, will be set based on instruction type
                .target_pc = 0,
                .operation_name = "",
                .original_opcodes = c_original_opcodes.ptr,
                .original_opcodes_count = @intCast(c_original_opcodes.len),
            };

            // Fill type-specific fields
            switch (instr.type) {
                .regular => |reg| {
                    c_instr.instruction_type = CInstructionType.REGULAR;
                    c_instr.regular_opcode = reg.opcode;
                    const name_z = allocator.dupeZ(u8, reg.name) catch {
                        return EVM_DISASM_ERROR_OUT_OF_MEMORY;
                    };
                    c_instr.regular_name = name_z.ptr;
                },
                .push_add_fusion => |fusion| {
                    c_instr.instruction_type = CInstructionType.PUSH_ADD_FUSION;
                    c_instr.fusion_value_low = @truncate(fusion.value);
                    c_instr.fusion_value_high = @truncate(fusion.value >> 64);
                    c_instr.fusion_value_extra_high = @truncate(fusion.value >> 128);
                    c_instr.fusion_value_top = @truncate(fusion.value >> 192);
                    c_instr.has_fusion_value = 1;
                    c_instr.value_storage = if (fusion.value_storage == .inline_64bit) CValueStorage.VALUE_STORAGE_INLINE_64BIT else CValueStorage.VALUE_STORAGE_POINTER_LARGE;
                },
                inline .push_mul_fusion, .push_sub_fusion, .push_div_fusion, .push_and_fusion, .push_or_fusion, .push_xor_fusion, .push_jump_fusion, .push_jumpi_fusion => |fusion| {
                    c_instr.instruction_type = switch (instr.type) {
                        .push_mul_fusion => CInstructionType.PUSH_MUL_FUSION,
                        .push_sub_fusion => CInstructionType.PUSH_SUB_FUSION,
                        .push_div_fusion => CInstructionType.PUSH_DIV_FUSION,
                        .push_and_fusion => CInstructionType.PUSH_AND_FUSION,
                        .push_or_fusion => CInstructionType.PUSH_OR_FUSION,
                        .push_xor_fusion => CInstructionType.PUSH_XOR_FUSION,
                        .push_jump_fusion => CInstructionType.PUSH_JUMP_FUSION,
                        .push_jumpi_fusion => CInstructionType.PUSH_JUMPI_FUSION,
                        else => unreachable,
                    };
                    c_instr.fusion_value_low = @truncate(fusion.value);
                    c_instr.fusion_value_high = @truncate(fusion.value >> 64);
                    c_instr.fusion_value_extra_high = @truncate(fusion.value >> 128);
                    c_instr.fusion_value_top = @truncate(fusion.value >> 192);
                    c_instr.has_fusion_value = 1;
                    c_instr.value_storage = if (fusion.value_storage == .inline_64bit) CValueStorage.VALUE_STORAGE_INLINE_64BIT else CValueStorage.VALUE_STORAGE_POINTER_LARGE;
                },
                .constant_fold => |fold| {
                    c_instr.instruction_type = CInstructionType.CONSTANT_FOLD;
                    c_instr.folded_value_low = @truncate(fold.folded_value);
                    c_instr.folded_value_high = @truncate(fold.folded_value >> 64);
                    c_instr.folded_value_extra_high = @truncate(fold.folded_value >> 128);
                    c_instr.folded_value_top = @truncate(fold.folded_value >> 192);
                    c_instr.original_length = fold.original_length;
                    const op_z = allocator.dupeZ(u8, fold.operation) catch {
                        return EVM_DISASM_ERROR_OUT_OF_MEMORY;
                    };
                    c_instr.operation_name = op_z.ptr;
                },
                .multi_push => |multi| {
                    c_instr.instruction_type = CInstructionType.MULTI_PUSH;
                    c_instr.fusion_count = multi.count;
                    c_instr.original_length = multi.original_length;
                },
                .multi_pop => |multi| {
                    c_instr.instruction_type = CInstructionType.MULTI_POP;
                    c_instr.fusion_count = multi.count;
                    c_instr.original_length = multi.original_length;
                },
                .iszero_jumpi => |iszero| {
                    c_instr.instruction_type = CInstructionType.ISZERO_JUMPI;
                    c_instr.original_length = iszero.original_length;
                },
                .dup2_mstore_push => |dup2| {
                    c_instr.instruction_type = CInstructionType.DUP2_MSTORE_PUSH;
                    c_instr.original_length = dup2.original_length;
                },
                .static_jump_candidate => |jump| {
                    c_instr.instruction_type = CInstructionType.STATIC_JUMP_CANDIDATE;
                    c_instr.target_pc = jump.target_pc;
                },
            }

            c_instructions[i] = c_instr;
        }

        // Fill result structure
        result_out.* = .{
            .instructions = c_instructions.ptr,
            .instruction_count = @intCast(c_instructions.len),
            .stats = .{
                .original_count = @intCast(zig_result.stats.original_count),
                .optimized_count = @intCast(zig_result.stats.optimized_count),
                .fusion_count = @intCast(zig_result.stats.fusion_count),
                .inline_value_count = @intCast(zig_result.stats.inline_value_count),
                .pointer_value_count = @intCast(zig_result.stats.pointer_value_count),
                .static_jump_candidates = @intCast(zig_result.stats.static_jump_candidates),
                .gas_saved_estimate = zig_result.stats.gas_saved_estimate,
                .compression_ratio = zig_result.stats.compression_ratio,
            },
        };

        return EVM_DISASM_SUCCESS;
    }

    /// Free memory allocated by analyzeWithAnalysis function
    /// @param result Pointer to analysis result structure returned by analyzeWithAnalysis
    pub fn free_analysis_result(result: *CAnalysisResult) void {
        if (result.instruction_count > 0) {
            // Free each instruction's data
            for (0..result.instruction_count) |i| {
                const instr = &result.instructions[i];
                
                // Free original opcodes
                if (instr.original_opcodes_count > 0) {
                    for (0..instr.original_opcodes_count) |j| {
                        allocator.free(std.mem.span(instr.original_opcodes[j].name));
                    }
                    allocator.free(instr.original_opcodes[0..instr.original_opcodes_count]);
                }
                
                // Free instruction-specific strings
                switch (instr.instruction_type) {
                    .REGULAR => {
                        const name_span = std.mem.span(instr.regular_name);
                        if (name_span.len > 0) {
                            allocator.free(name_span);
                        }
                    },
                    .CONSTANT_FOLD => {
                        const op_span = std.mem.span(instr.operation_name);
                        if (op_span.len > 0) {
                            allocator.free(op_span);
                        }
                    },
                    else => {},
                }
            }
            allocator.free(result.instructions[0..result.instruction_count]);
        }
        result.* = std.mem.zeroes(CAnalysisResult);
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