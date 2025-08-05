/// Integration module for advanced interpreter with memory optimization.
///
/// This module enhances the instruction stream generation to use pre-calculated
/// memory expansion costs when available, significantly improving performance
/// for contracts with predictable memory access patterns.

const std = @import("std");
const Allocator = std.mem.Allocator;
const instruction_stream = @import("instruction_stream.zig");
const memory_expansion_analysis = @import("memory_expansion_analysis.zig");
const memory_optimized_ops = @import("memory_optimized_ops.zig");
const CodeAnalysis = @import("../frame/code_analysis.zig");
const primitives = @import("primitives");
const opcode = @import("../opcodes/opcode.zig");
const Log = @import("../log.zig");

/// Enhanced instruction stream generation with memory optimization
pub fn generate_optimized_instruction_stream(
    allocator: Allocator,
    bytecode: []const u8,
    analysis: *const CodeAnalysis,
) !instruction_stream.InstructionStream {
    // First, perform memory expansion analysis
    const block_starts = try extract_block_starts(allocator, analysis);
    defer allocator.free(block_starts);
    
    const memory_blocks = try memory_expansion_analysis.analyze_memory_expansion(
        allocator,
        bytecode,
        block_starts,
    );
    defer {
        for (memory_blocks) |*block| {
            block.accesses.deinit();
        }
        allocator.free(memory_blocks);
    }
    
    // Generate the base instruction stream
    var stream = try instruction_stream.generate_instruction_stream(allocator, bytecode, analysis);
    
    // Enhance with memory optimization
    try enhance_with_memory_optimization(&stream, memory_blocks, analysis);
    
    return stream;
}

/// Extract block start positions from code analysis
fn extract_block_starts(allocator: Allocator, analysis: *const CodeAnalysis) ![]usize {
    var starts = try allocator.alloc(usize, analysis.block_count);
    var idx: usize = 0;
    
    var it = analysis.block_starts.iterator();
    while (it.next()) |bit_idx| : (idx += 1) {
        starts[idx] = bit_idx;
    }
    
    return starts;
}

/// Enhance instruction stream with memory optimization
fn enhance_with_memory_optimization(
    stream: *instruction_stream.InstructionStream,
    memory_blocks: []const memory_expansion_analysis.BlockMemoryAnalysis,
    analysis: *const CodeAnalysis,
) !void {
    // Map PC to block index
    const pc_to_block = analysis.pc_to_block;
    
    // Update instructions that can use pre-calculated memory expansion
    for (stream.instructions) |*instr| {
        const pc = instr.arg.data; // Assuming PC is stored in data for most ops
        
        // Find which block this instruction belongs to
        if (pc >= pc_to_block.len) continue;
        const block_idx = pc_to_block[pc];
        if (block_idx >= memory_blocks.len) continue;
        
        const block = &memory_blocks[block_idx];
        
        // Check if this PC has a memory access with pre-calculated cost
        if (block.accesses.get(pc)) |access| {
            if (access.expansion_cost) |cost| {
                // Update instruction to use pre-calculated version
                switch (@as(opcode.Enum, @enumFromInt(instr.arg.data))) {
                    .MLOAD => {
                        instr.fn_ptr = &memory_optimized_ops.op_mload_precalc;
                        instr.arg = .{ .data = cost };
                    },
                    .MSTORE => {
                        instr.fn_ptr = &memory_optimized_ops.op_mstore_precalc;
                        instr.arg = .{ .data = cost };
                    },
                    .MSTORE8 => {
                        instr.fn_ptr = &memory_optimized_ops.op_mstore8_precalc;
                        instr.arg = .{ .data = cost };
                    },
                    .CALLDATACOPY => {
                        instr.fn_ptr = &memory_optimized_ops.op_calldatacopy_precalc;
                        instr.arg = .{ .data = cost };
                    },
                    .RETURN, .REVERT => {
                        instr.fn_ptr = &memory_optimized_ops.op_return_precalc;
                        instr.arg = .{ .data = cost };
                    },
                    else => {},
                }
            }
        }
    }
}

/// Check if advanced execution with memory optimization should be used
pub fn should_use_memory_optimization(
    contract: *const @import("../frame/contract.zig"),
    analysis: *const CodeAnalysis,
) bool {
    // Use memory optimization for contracts with:
    // 1. Code analysis available
    // 2. Reasonable size (optimization overhead worth it)
    // 3. Not too many dynamic jumps (predictable flow)
    
    if (analysis.block_count == 0) return false;
    if (contract.code_size < 200) return false; // Too small
    if (contract.code_size > 24576) return false; // Too large (24KB limit like EVM)
    if (analysis.has_dynamic_jumps) return false;
    
    // Check if contract has significant memory operations
    var memory_op_count: usize = 0;
    for (contract.code) |byte| {
        switch (@as(opcode.Enum, @enumFromInt(byte))) {
            .MLOAD, .MSTORE, .MSTORE8, .CALLDATACOPY, .CODECOPY, .RETURNDATACOPY => {
                memory_op_count += 1;
            },
            else => {},
        }
    }
    
    // Use optimization if at least 5% of opcodes are memory operations
    return memory_op_count * 20 >= contract.code_size;
}

// Test helper to create a contract with memory operations
fn create_memory_test_contract() [_]u8{
    // PUSH1 0x20, PUSH1 0x00, MSTORE (store 32 at offset 0)
    // PUSH1 0x00, MLOAD (load from offset 0)
    // PUSH1 0x40, PUSH1 0x20, MSTORE (store 64 at offset 32)
    return [_]u8{
        0x60, 0x20, 0x60, 0x00, 0x52, // PUSH1 32, PUSH1 0, MSTORE
        0x60, 0x00, 0x51,             // PUSH1 0, MLOAD
        0x60, 0x40, 0x60, 0x20, 0x52, // PUSH1 64, PUSH1 32, MSTORE
        0x00,                          // STOP
    };
}

test "memory optimization integration" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const bytecode = create_memory_test_contract();
    
    // Create mock analysis
    var analysis = CodeAnalysis{
        .jumpdest_analysis = undefined,
        .jumpdest_bitmap = undefined,
        .block_starts = try @import("../frame/bitvec.zig").BitVec(u64).init(allocator, bytecode.len),
        .block_count = 1,
        .block_metadata = try allocator.alloc(@import("../frame/code_analysis.zig").BlockMetadata, 1),
        .has_dynamic_jumps = false,
        .max_stack_depth = 4,
        .pc_to_block = try allocator.alloc(u16, bytecode.len),
        .block_start_positions = try allocator.alloc(usize, 1),
        .jump_analysis = null,
        .memory_expansion_info = null,
    };
    defer analysis.deinit(allocator);
    
    // Mark block start
    analysis.block_starts.setBit(0);
    analysis.block_metadata[0] = .{
        .gas_cost = 50,
        .stack_req = 0,
        .stack_max = 4,
    };
    analysis.block_start_positions[0] = 0;
    @memset(analysis.pc_to_block, 0);
    
    // Generate optimized instruction stream
    var stream = try generate_optimized_instruction_stream(allocator, &bytecode, &analysis);
    defer stream.deinit();
    
    // Verify that memory operations were optimized
    var optimized_count: usize = 0;
    for (stream.instructions) |instr| {
        if (instr.fn_ptr == &memory_optimized_ops.op_mstore_precalc or
            instr.fn_ptr == &memory_optimized_ops.op_mload_precalc) {
            optimized_count += 1;
        }
    }
    
    // Should have optimized at least some memory operations
    try testing.expect(optimized_count > 0);
}