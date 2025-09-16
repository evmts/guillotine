// ============================================================================
// BYTECODE C API - FFI interface for EVM bytecode analysis and validation
// ============================================================================

const std = @import("std");
const evm = @import("evm");
const Opcode = evm.Opcode;
const BytecodeConfig = evm.BytecodeConfig;
const BytecodeType = evm.Bytecode(BytecodeConfig{});
const bytecodeAnalyze = @import("bytecode_analyze.zig").bytecodeAnalyze;
const opcode_data = evm.OpcodeData;

const allocator = std.heap.c_allocator;

// ============================================================================
// ERROR CODES
// ============================================================================

pub const EVM_BYTECODE_SUCCESS: c_int = 0;
pub const EVM_BYTECODE_ERROR_NULL_POINTER: c_int = -1;
pub const EVM_BYTECODE_ERROR_INVALID_BYTECODE: c_int = -2;
pub const EVM_BYTECODE_ERROR_OUT_OF_MEMORY: c_int = -3;
pub const EVM_BYTECODE_ERROR_BYTECODE_TOO_LARGE: c_int = -4;
pub const EVM_BYTECODE_ERROR_INVALID_OPCODE: c_int = -5;
pub const EVM_BYTECODE_ERROR_OUT_OF_BOUNDS: c_int = -6;

// ============================================================================
// OPAQUE HANDLE
// ============================================================================

pub const CBytecodeHandle = struct {
    allocator: std.mem.Allocator,
    raw_data: []u8, // Owned input bytes (may include metadata)
    bytecode: BytecodeType, // Validated runtime bytecode wrapper
};

// ============================================================================
// BYTECODE LIFECYCLE
// ============================================================================

/// Create and analyze bytecode from raw bytes
/// @param data Pointer to bytecode data
/// @param data_len Length of bytecode data
/// @return Opaque bytecode handle, or NULL on failure
pub fn evm_bytecode_create(data: [*]const u8, data_len: usize) callconv(.c) ?*CBytecodeHandle {
    return evm_bytecode_create_with_allocator(allocator, data, data_len);
}

pub fn evm_bytecode_create_with_allocator(alloc: std.mem.Allocator, data: [*]const u8, data_len: usize) ?*CBytecodeHandle {
    const handle = alloc.create(CBytecodeHandle) catch return null;
    errdefer alloc.destroy(handle);

    // Copy input (may include Solidity metadata suffix)
    const owned_data = alloc.dupe(u8, data[0..data_len]) catch {
        alloc.destroy(handle);
        return null;
    };
    errdefer alloc.free(owned_data);

    // Validate and build bitmaps against runtime portion
    var bytecode = BytecodeType.init(alloc, owned_data) catch {
        return null;
    };
    errdefer bytecode.deinit();

    handle.* = .{
        .allocator = alloc,
        .raw_data = owned_data,
        .bytecode = bytecode,
    };
    return handle;
}

/// Destroy bytecode and free memory
/// @param handle Bytecode handle
pub fn evm_bytecode_destroy(handle: ?*CBytecodeHandle) callconv(.c) void {
    if (handle) |h| {
        h.bytecode.deinit();
        h.allocator.free(h.raw_data);
        h.allocator.destroy(h);
    }
}

// ============================================================================
// BYTECODE INSPECTION
// ============================================================================

/// Get the length of the bytecode
/// @param handle Bytecode handle
/// @return Bytecode length in bytes, or 0 on error
pub fn evm_bytecode_get_length(handle: ?*const CBytecodeHandle) callconv(.c) usize {
    const h = handle orelse return 0;
    // Runtime length (excludes metadata)
    return @intCast(h.bytecode.len());
}

/// Get raw bytecode data (copy to buffer)
/// @param handle Bytecode handle
/// @param buffer Output buffer
/// @param buffer_len Buffer length
/// @return Number of bytes copied, or 0 on error
pub fn evm_bytecode_get_data(handle: ?*const CBytecodeHandle, buffer: [*]u8, buffer_len: usize) callconv(.c) usize {
    const h = handle orelse return 0;
    
    const copy_len = @min(h.raw_data.len, buffer_len);
    @memcpy(buffer[0..copy_len], h.raw_data[0..copy_len]);
    return copy_len;
}

/// Get opcode at specific position
/// @param handle Bytecode handle
/// @param position Position in bytecode
/// @return Opcode value (0-255), or 0xFF if out of bounds
pub fn evm_bytecode_get_opcode_at(handle: ?*const CBytecodeHandle, position: usize) callconv(.c) u8 {
    const h = handle orelse return 0xFF;
    const len: usize = @intCast(h.bytecode.len());
    if (position >= len) return 0xFF;
    const pc: BytecodeType.PcType = @intCast(position);
    return h.bytecode.get(pc) orelse 0xFF;
}

/// Check if position is a valid jump destination (JUMPDEST)
/// @param handle Bytecode handle
/// @param position Position to check
/// @return 1 if valid jump destination, 0 otherwise
pub fn evm_bytecode_is_jump_dest(handle: ?*const CBytecodeHandle, position: usize) callconv(.c) c_int {
    const h = handle orelse return 0;
    const len: usize = @intCast(h.bytecode.len());
    if (position >= len) return 0;
    const pc: BytecodeType.PcType = @intCast(position);
    return if (h.bytecode.isValidJumpDest(pc)) 1 else 0;
}

// ============================================================================
// RUNTIME VS FULL BYTES
// ============================================================================

/// Get the full input length (may include Solidity metadata)
pub fn evm_bytecode_get_full_length(handle: ?*const CBytecodeHandle) callconv(.c) usize {
    const h = handle orelse return 0;
    return h.raw_data.len;
}

/// Copy validated runtime code (excludes metadata) to buffer
/// Returns number of bytes copied
pub fn evm_bytecode_get_runtime_data(handle: ?*const CBytecodeHandle, buffer: [*]u8, buffer_len: usize) callconv(.c) usize {
    const h = handle orelse return 0;
    const runtime = h.bytecode.raw();
    const copy_len = @min(runtime.len, buffer_len);
    @memcpy(buffer[0..copy_len], runtime[0..copy_len]);
    return copy_len;
}

// ============================================================================
// BYTECODE VALIDATION
// ============================================================================

/// Find all jump destinations in bytecode
/// @param handle Bytecode handle
/// @param jump_dests Output buffer for jump destinations
/// @param max_dests Maximum number of destinations to find
/// @param count_out Actual number of destinations found
/// @return Error code
pub fn evm_bytecode_find_jump_dests(
    handle: ?*const CBytecodeHandle,
    jump_dests: [*]u32,
    max_dests: u32,
    count_out: *u32
) callconv(.c) c_int {
    const h = handle orelse return EVM_BYTECODE_ERROR_NULL_POINTER;
    var count: u32 = 0;
    var pos: usize = 0;
    const len: usize = @intCast(h.bytecode.len());
    while (pos < len and count < max_dests) : (pos += 1) {
        if (h.bytecode.isValidJumpDest(@intCast(pos))) {
            jump_dests[count] = @intCast(pos);
            count += 1;
        }
    }
    count_out.* = count;
    return EVM_BYTECODE_SUCCESS;
}

// ============================================================================
// BYTECODE ANALYSIS - Advanced fusion and control flow analysis
// ============================================================================

/// C structure for basic block information
pub const CBasicBlock = extern struct {
    start: u32,
    end: u32,
};

/// C structure for fusion information
pub const CFusionInfo = extern struct {
    fusion_type: CFusionType,
    original_length: u32,
    folded_value_low: u64,
    folded_value_high: u64,
    folded_value_extra_high: u64,
    folded_value_top: u64,
    count: u8,
};

/// Fusion type enum for C
pub const CFusionType = enum(u8) {
    constant_fold = 0,
    multi_push = 1,
    multi_pop = 2,
    iszero_jumpi = 3,
    dup2_mstore_push = 4,
};

/// C structure for jump fusion entry
pub const CJumpFusion = extern struct {
    source_pc: u32,
    target_pc: u32,
};

/// C structure for advanced fusion entry
pub const CAdvancedFusion = extern struct {
    pc: u32,
    info: CFusionInfo,
};

/// C structure for bytecode analysis result
pub const CBytecodeAnalysis = extern struct {
    // Arrays of program counters
    push_pcs: [*]u32,
    push_pcs_count: u32,
    
    jumpdests: [*]u32,
    jumpdests_count: u32,
    
    // Basic blocks
    basic_blocks: [*]CBasicBlock,
    basic_blocks_count: u32,
    
    // Jump fusions
    jump_fusions: [*]CJumpFusion,
    jump_fusions_count: u32,
    
    // Advanced fusions
    advanced_fusions: [*]CAdvancedFusion,
    advanced_fusions_count: u32,
};

/// Analyze bytecode for advanced patterns and control flow
/// @param handle Bytecode handle
/// @param analysis_out Output analysis structure
/// @return Error code
pub fn evm_bytecode_analyze(handle: ?*const CBytecodeHandle, analysis_out: *CBytecodeAnalysis) callconv(.c) c_int {
    return evm_bytecode_analyze_with_allocator(allocator, handle, analysis_out);
}

pub fn evm_bytecode_analyze_with_allocator(alloc: std.mem.Allocator, handle: ?*const CBytecodeHandle, analysis_out: *CBytecodeAnalysis) c_int {
    const h = handle orelse return EVM_BYTECODE_ERROR_NULL_POINTER;
    
    // Call the Zig analyzer with correct types
    const BasicBlock = struct {
        start: BytecodeType.PcType,
        end: BytecodeType.PcType,
    };
    const FusionInfo = struct {
        fusion_type: enum { constant_fold, multi_push, multi_pop, iszero_jumpi, dup2_mstore_push },
        original_length: BytecodeType.PcType,
        folded_value: u256 = 0,
        count: u8 = 0,
    };
    
    const analysis = bytecodeAnalyze(
        BytecodeType.PcType,
        BasicBlock,
        FusionInfo,
        alloc,
        h.bytecode.raw(),
    ) catch return EVM_BYTECODE_ERROR_INVALID_BYTECODE;
    
    defer {
        alloc.free(analysis.push_pcs);
        alloc.free(analysis.jumpdests);
        alloc.free(analysis.basic_blocks);
        var mut_jump_fusions = analysis.jump_fusions;
        mut_jump_fusions.deinit();
        var mut_advanced_fusions = analysis.advanced_fusions;
        mut_advanced_fusions.deinit();
    }
    
    // Convert push_pcs
    const c_push_pcs = alloc.alloc(u32, analysis.push_pcs.len) catch 
        return EVM_BYTECODE_ERROR_OUT_OF_MEMORY;
    for (analysis.push_pcs, 0..) |pc, i| {
        c_push_pcs[i] = @intCast(pc);
    }
    
    // Convert jumpdests
    const c_jumpdests = alloc.alloc(u32, analysis.jumpdests.len) catch {
        alloc.free(c_push_pcs);
        return EVM_BYTECODE_ERROR_OUT_OF_MEMORY;
    };
    for (analysis.jumpdests, 0..) |pc, i| {
        c_jumpdests[i] = @intCast(pc);
    }
    
    // Convert basic blocks
    const c_blocks = alloc.alloc(CBasicBlock, analysis.basic_blocks.len) catch {
        alloc.free(c_push_pcs);
        alloc.free(c_jumpdests);
        return EVM_BYTECODE_ERROR_OUT_OF_MEMORY;
    };
    for (analysis.basic_blocks, 0..) |block, i| {
        c_blocks[i] = .{
            .start = @intCast(block.start),
            .end = @intCast(block.end),
        };
    }
    
    // Convert jump fusions
    const c_jump_fusions = alloc.alloc(CJumpFusion, analysis.jump_fusions.count()) catch {
        alloc.free(c_push_pcs);
        alloc.free(c_jumpdests);
        alloc.free(c_blocks);
        return EVM_BYTECODE_ERROR_OUT_OF_MEMORY;
    };
    {
        var iter = analysis.jump_fusions.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| : (i += 1) {
            c_jump_fusions[i] = .{
                .source_pc = @intCast(entry.key_ptr.*),
                .target_pc = @intCast(entry.value_ptr.*),
            };
        }
    }
    
    // Convert advanced fusions
    const c_advanced = alloc.alloc(CAdvancedFusion, analysis.advanced_fusions.count()) catch {
        alloc.free(c_push_pcs);
        alloc.free(c_jumpdests);
        alloc.free(c_blocks);
        alloc.free(c_jump_fusions);
        return EVM_BYTECODE_ERROR_OUT_OF_MEMORY;
    };
    {
        var iter = analysis.advanced_fusions.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| : (i += 1) {
            const fusion = entry.value_ptr.*;
            c_advanced[i] = .{
                .pc = @intCast(entry.key_ptr.*),
                .info = .{
                    .fusion_type = switch (fusion.fusion_type) {
                        .constant_fold => CFusionType.constant_fold,
                        .multi_push => CFusionType.multi_push,
                        .multi_pop => CFusionType.multi_pop,
                        .iszero_jumpi => CFusionType.iszero_jumpi,
                        .dup2_mstore_push => CFusionType.dup2_mstore_push,
                    },
                    .original_length = @intCast(fusion.original_length),
                    .folded_value_low = @truncate(fusion.folded_value),
                    .folded_value_high = @truncate(fusion.folded_value >> 64),
                    .folded_value_extra_high = @truncate(fusion.folded_value >> 128),
                    .folded_value_top = @truncate(fusion.folded_value >> 192),
                    .count = fusion.count,
                },
            };
        }
    }
    
    // Fill output structure
    analysis_out.* = .{
        .push_pcs = c_push_pcs.ptr,
        .push_pcs_count = @intCast(c_push_pcs.len),
        
        .jumpdests = c_jumpdests.ptr,
        .jumpdests_count = @intCast(c_jumpdests.len),
        
        .basic_blocks = c_blocks.ptr,
        .basic_blocks_count = @intCast(c_blocks.len),
        
        .jump_fusions = c_jump_fusions.ptr,
        .jump_fusions_count = @intCast(c_jump_fusions.len),
        
        .advanced_fusions = c_advanced.ptr,
        .advanced_fusions_count = @intCast(c_advanced.len),
    };
    
    return EVM_BYTECODE_SUCCESS;
}

/// Free memory allocated by bytecode analysis
/// @param analysis Analysis structure to free
pub fn evm_bytecode_free_analysis(analysis: *CBytecodeAnalysis) callconv(.c) void {
    return evm_bytecode_free_analysis_with_allocator(allocator, analysis);
}

pub fn evm_bytecode_free_analysis_with_allocator(alloc: std.mem.Allocator, analysis: *CBytecodeAnalysis) void {
    if (analysis.push_pcs_count > 0) {
        alloc.free(analysis.push_pcs[0..analysis.push_pcs_count]);
    }
    if (analysis.jumpdests_count > 0) {
        alloc.free(analysis.jumpdests[0..analysis.jumpdests_count]);
    }
    if (analysis.basic_blocks_count > 0) {
        alloc.free(analysis.basic_blocks[0..analysis.basic_blocks_count]);
    }
    if (analysis.jump_fusions_count > 0) {
        alloc.free(analysis.jump_fusions[0..analysis.jump_fusions_count]);
    }
    if (analysis.advanced_fusions_count > 0) {
        alloc.free(analysis.advanced_fusions[0..analysis.advanced_fusions_count]);
    }
    analysis.* = std.mem.zeroes(CBytecodeAnalysis);
}

// ============================================================================
// BYTECODE UTILITIES
// ============================================================================

/// Get opcode name for a given opcode value
/// @param opcode_value Opcode value (0-255)
/// @return Opcode name, or "INVALID" if not recognized
pub fn evm_bytecode_opcode_name(opcode_value: u8) callconv(.c) [*:0]const u8 {
    const opcode = std.meta.intToEnum(Opcode, opcode_value) catch return "INVALID";
    
    return switch (opcode) {
        .STOP => "STOP",
        .ADD => "ADD",
        .MUL => "MUL",
        .SUB => "SUB",
        .DIV => "DIV",
        .SDIV => "SDIV",
        .MOD => "MOD",
        .SMOD => "SMOD",
        .ADDMOD => "ADDMOD",
        .MULMOD => "MULMOD",
        .EXP => "EXP",
        .SIGNEXTEND => "SIGNEXTEND",
        .LT => "LT",
        .GT => "GT",
        .SLT => "SLT",
        .SGT => "SGT",
        .EQ => "EQ",
        .ISZERO => "ISZERO",
        .AND => "AND",
        .OR => "OR",
        .XOR => "XOR",
        .NOT => "NOT",
        .BYTE => "BYTE",
        .SHL => "SHL",
        .SHR => "SHR",
        .SAR => "SAR",
        .KECCAK256 => "KECCAK256",
        .ADDRESS => "ADDRESS",
        .BALANCE => "BALANCE",
        .ORIGIN => "ORIGIN",
        .CALLER => "CALLER",
        .CALLVALUE => "CALLVALUE",
        .CALLDATALOAD => "CALLDATALOAD",
        .CALLDATASIZE => "CALLDATASIZE",
        .CALLDATACOPY => "CALLDATACOPY",
        .CODESIZE => "CODESIZE",
        .CODECOPY => "CODECOPY",
        .GASPRICE => "GASPRICE",
        .EXTCODESIZE => "EXTCODESIZE",
        .EXTCODECOPY => "EXTCODECOPY",
        .RETURNDATASIZE => "RETURNDATASIZE",
        .RETURNDATACOPY => "RETURNDATACOPY",
        .EXTCODEHASH => "EXTCODEHASH",
        .BLOCKHASH => "BLOCKHASH",
        .COINBASE => "COINBASE",
        .TIMESTAMP => "TIMESTAMP",
        .NUMBER => "NUMBER",
        .DIFFICULTY => "DIFFICULTY",
        .GASLIMIT => "GASLIMIT",
        .CHAINID => "CHAINID",
        .SELFBALANCE => "SELFBALANCE",
        .BASEFEE => "BASEFEE",
        .POP => "POP",
        .MLOAD => "MLOAD",
        .MSTORE => "MSTORE",
        .MSTORE8 => "MSTORE8",
        .SLOAD => "SLOAD",
        .SSTORE => "SSTORE",
        .JUMP => "JUMP",
        .JUMPI => "JUMPI",
        .PC => "PC",
        .MSIZE => "MSIZE",
        .GAS => "GAS",
        .JUMPDEST => "JUMPDEST",
        .TLOAD => "TLOAD",
        .TSTORE => "TSTORE",
        .MCOPY => "MCOPY",
        .PUSH0 => "PUSH0",
        .PUSH1 => "PUSH1",
        .PUSH2 => "PUSH2",
        .PUSH3 => "PUSH3",
        .PUSH4 => "PUSH4",
        .PUSH5 => "PUSH5",
        .PUSH6 => "PUSH6",
        .PUSH7 => "PUSH7",
        .PUSH8 => "PUSH8",
        .PUSH9 => "PUSH9",
        .PUSH10 => "PUSH10",
        .PUSH11 => "PUSH11",
        .PUSH12 => "PUSH12",
        .PUSH13 => "PUSH13",
        .PUSH14 => "PUSH14",
        .PUSH15 => "PUSH15",
        .PUSH16 => "PUSH16",
        .PUSH17 => "PUSH17",
        .PUSH18 => "PUSH18",
        .PUSH19 => "PUSH19",
        .PUSH20 => "PUSH20",
        .PUSH21 => "PUSH21",
        .PUSH22 => "PUSH22",
        .PUSH23 => "PUSH23",
        .PUSH24 => "PUSH24",
        .PUSH25 => "PUSH25",
        .PUSH26 => "PUSH26",
        .PUSH27 => "PUSH27",
        .PUSH28 => "PUSH28",
        .PUSH29 => "PUSH29",
        .PUSH30 => "PUSH30",
        .PUSH31 => "PUSH31",
        .PUSH32 => "PUSH32",
        .DUP1 => "DUP1",
        .DUP2 => "DUP2",
        .DUP3 => "DUP3",
        .DUP4 => "DUP4",
        .DUP5 => "DUP5",
        .DUP6 => "DUP6",
        .DUP7 => "DUP7",
        .DUP8 => "DUP8",
        .DUP9 => "DUP9",
        .DUP10 => "DUP10",
        .DUP11 => "DUP11",
        .DUP12 => "DUP12",
        .DUP13 => "DUP13",
        .DUP14 => "DUP14",
        .DUP15 => "DUP15",
        .DUP16 => "DUP16",
        .SWAP1 => "SWAP1",
        .SWAP2 => "SWAP2",
        .SWAP3 => "SWAP3",
        .SWAP4 => "SWAP4",
        .SWAP5 => "SWAP5",
        .SWAP6 => "SWAP6",
        .SWAP7 => "SWAP7",
        .SWAP8 => "SWAP8",
        .SWAP9 => "SWAP9",
        .SWAP10 => "SWAP10",
        .SWAP11 => "SWAP11",
        .SWAP12 => "SWAP12",
        .SWAP13 => "SWAP13",
        .SWAP14 => "SWAP14",
        .SWAP15 => "SWAP15",
        .SWAP16 => "SWAP16",
        .LOG0 => "LOG0",
        .LOG1 => "LOG1",
        .LOG2 => "LOG2",
        .LOG3 => "LOG3",
        .LOG4 => "LOG4",
        .CREATE => "CREATE",
        .CALL => "CALL",
        .CALLCODE => "CALLCODE",
        .RETURN => "RETURN",
        .DELEGATECALL => "DELEGATECALL",
        .CREATE2 => "CREATE2",
        .STATICCALL => "STATICCALL",
        .REVERT => "REVERT",
        .INVALID => "INVALID",
        .SELFDESTRUCT => "SELFDESTRUCT",
        .BLOBHASH => "BLOBHASH",
        .BLOBBASEFEE => "BLOBBASEFEE",
        .AUTH => "AUTH",
        .AUTHCALL => "AUTHCALL",
    };
}

/// Check if an opcode value is valid
/// @param opcode_value Opcode value (0-255)
/// @return 1 if valid opcode, 0 otherwise
pub fn evm_bytecode_is_valid_opcode(opcode_value: u8) callconv(.c) c_int {
    _ = std.meta.intToEnum(Opcode, opcode_value) catch return 0;
    return 1;
}

/// C structure for opcode information
pub const COpcodeInfo = extern struct {
    gas_cost: u16,
    stack_inputs: u8,
    stack_outputs: u8,
};

/// Get opcode information for a given opcode value
/// @param opcode_value Opcode value (0-255)
/// @return Opcode information structure
pub fn evm_bytecode_opcode_info(opcode_value: u8) callconv(.c) COpcodeInfo {
    const info = opcode_data.OPCODE_INFO[opcode_value];
    return COpcodeInfo{
        .gas_cost = info.gas_cost,
        .stack_inputs = info.stack_inputs,
        .stack_outputs = info.stack_outputs,
    };
}

// ============================================================================
// ERROR HANDLING
// ============================================================================

/// Convert error code to human-readable string
pub fn evm_bytecode_error_string(error_code: c_int) callconv(.c) [*:0]const u8 {
    return switch (error_code) {
        EVM_BYTECODE_SUCCESS => "Success",
        EVM_BYTECODE_ERROR_NULL_POINTER => "Null pointer",
        EVM_BYTECODE_ERROR_INVALID_BYTECODE => "Invalid bytecode",
        EVM_BYTECODE_ERROR_OUT_OF_MEMORY => "Out of memory",
        EVM_BYTECODE_ERROR_BYTECODE_TOO_LARGE => "Bytecode too large",
        EVM_BYTECODE_ERROR_INVALID_OPCODE => "Invalid opcode",
        EVM_BYTECODE_ERROR_OUT_OF_BOUNDS => "Out of bounds",
        else => "Unknown error",
    };
}

// ============================================================================
// TESTING
// ============================================================================

/// Pretty print bytecode with human-readable formatting
/// @param data Bytecode data
/// @param data_len Length of the bytecode data
/// @param buffer Buffer to store the output string
/// @param buffer_len Length of the buffer
/// @return Number of bytes written (including null terminator), or 0 on error
pub fn evm_bytecode_pretty_print(data: [*]const u8, data_len: usize, buffer: [*]u8, buffer_len: usize) usize {
   return evm_bytecode_pretty_print_with_allocator(allocator, data, data_len, buffer, buffer_len);
}

pub fn evm_bytecode_pretty_print_with_allocator(alloc: std.mem.Allocator, data: [*]const u8, data_len: usize, buffer: [*]u8, buffer_len: usize) usize {
    if (data_len == 0) return 0;
    
    const bytecode_slice = data[0..data_len];
    
    // Create bytecode instance
    const bytecode = BytecodeType.init(alloc, bytecode_slice) catch return 0;
    
    // Call pretty_print 
    const output = bytecode.pretty_print(alloc) catch return 0;
    defer alloc.free(output);
    
    // Copy to buffer
    if (buffer_len == 0) return output.len + 1; // Return required size
    
    const copy_len = @min(output.len, buffer_len - 1);
    @memcpy(buffer[0..copy_len], output[0..copy_len]);
    buffer[copy_len] = 0; // Null terminate
    
    return copy_len + 1;
}

// ============================================================================

/// Test opcode utilities
pub fn evm_bytecode_test_opcodes() callconv(.c) c_int {
    // Test valid opcodes
    if (evm_bytecode_is_valid_opcode(0x00) != 1) return -1; // STOP
    if (evm_bytecode_is_valid_opcode(0x01) != 1) return -2; // ADD
    if (evm_bytecode_is_valid_opcode(0x60) != 1) return -3; // PUSH1
    
    // Test invalid opcode
    if (evm_bytecode_is_valid_opcode(0x0C) != 0) return -4; // Invalid opcode
    
    // Test opcode names
    const stop_name = evm_bytecode_opcode_name(0x00);
    const add_name = evm_bytecode_opcode_name(0x01);
    
    // Simple check - names should not be "INVALID"
    if (std.mem.eql(u8, std.mem.span(stop_name), "INVALID")) return -5;
    if (std.mem.eql(u8, std.mem.span(add_name), "INVALID")) return -6;
    
    return 0;
}

test "Bytecode C API compilation" {
    std.testing.refAllDecls(@This());
}

test "Bytecode C API basic getters and data copy" {
    // PUSH1 0x2A PUSH1 0x0A ADD STOP
    const code = [_]u8{ 0x60, 0x2A, 0x60, 0x0A, 0x01, 0x00 };
    const h_opt = evm_bytecode_create(&code, code.len);
    try std.testing.expect(h_opt != null);
    const h = h_opt.?;
    defer evm_bytecode_destroy(h);

    // Lengths
    try std.testing.expectEqual(code.len, evm_bytecode_get_length(h));
    try std.testing.expectEqual(code.len, evm_bytecode_get_full_length(h));

    // Full data copy
    var buf_full: [64]u8 = undefined;
    const copied_full = evm_bytecode_get_data(h, &buf_full, buf_full.len);
    try std.testing.expectEqual(code.len, copied_full);
    try std.testing.expect(std.mem.eql(u8, buf_full[0..copied_full], code[0..]));

    // Runtime data copy
    var buf_runtime: [64]u8 = undefined;
    const copied_runtime = evm_bytecode_get_runtime_data(h, &buf_runtime, buf_runtime.len);
    try std.testing.expectEqual(code.len, copied_runtime);
    try std.testing.expect(std.mem.eql(u8, buf_runtime[0..copied_runtime], code[0..]));
}

test "Bytecode C API opcode/jumpdest/bounds and stats" {
    // JUMPDEST STOP JUMPDEST
    const code = [_]u8{ 0x5b, 0x00, 0x5b };
    const h_opt = evm_bytecode_create(&code, code.len);
    try std.testing.expect(h_opt != null);
    const h = h_opt.?;
    defer evm_bytecode_destroy(h);

    // Opcode at bounds
    try std.testing.expectEqual(@as(u8, 0x5b), evm_bytecode_get_opcode_at(h, 0));
    try std.testing.expectEqual(@as(u8, 0x00), evm_bytecode_get_opcode_at(h, 1));
    try std.testing.expectEqual(@as(u8, 0x5b), evm_bytecode_get_opcode_at(h, 2));
    try std.testing.expectEqual(@as(u8, 0xFF), evm_bytecode_get_opcode_at(h, 3)); // out of bounds
    try std.testing.expectEqual(@as(u8, 0xFF), evm_bytecode_get_opcode_at(h, std.math.maxInt(usize)));

    // Jumpdest queries
    try std.testing.expectEqual(@as(c_int, 1), evm_bytecode_is_jump_dest(h, 0));
    try std.testing.expectEqual(@as(c_int, 0), evm_bytecode_is_jump_dest(h, 1));
    try std.testing.expectEqual(@as(c_int, 1), evm_bytecode_is_jump_dest(h, 2));
    try std.testing.expectEqual(@as(c_int, 0), evm_bytecode_is_jump_dest(h, 3));

    // Find jumpdests
    var out: [8]u32 = undefined; var found: u32 = 0;
    const rc = evm_bytecode_find_jump_dests(h, &out, out.len, &found);
    try std.testing.expectEqual(@as(c_int, EVM_BYTECODE_SUCCESS), rc);
    try std.testing.expectEqual(@as(u32, 2), found);
    try std.testing.expectEqual(@as(u32, 0), out[0]);
    try std.testing.expectEqual(@as(u32, 2), out[1]);
}

test "Bytecode C API analysis" {
    // PUSH1 0x05 PUSH1 0x03 ADD (constant folding pattern)
    const code = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01 };
    const h_opt = evm_bytecode_create(&code, code.len);
    try std.testing.expect(h_opt != null);
    const h = h_opt.?;
    defer evm_bytecode_destroy(h);
    
    var analysis: CBytecodeAnalysis = undefined;
    const rc = evm_bytecode_analyze(h, &analysis);
    defer evm_bytecode_free_analysis(&analysis);
    
    try std.testing.expectEqual(@as(c_int, EVM_BYTECODE_SUCCESS), rc);
    
    // Should have detected the constant folding fusion
    try std.testing.expectEqual(@as(u32, 1), analysis.advanced_fusions_count);
    try std.testing.expectEqual(@as(u32, 0), analysis.advanced_fusions[0].pc);
    try std.testing.expectEqual(CFusionType.constant_fold, analysis.advanced_fusions[0].info.fusion_type);
    try std.testing.expectEqual(@as(u32, 5), analysis.advanced_fusions[0].info.original_length);
    
    // Folded value should be 8 (5 + 3)
    try std.testing.expectEqual(@as(u64, 8), analysis.advanced_fusions[0].info.folded_value_low);
}
