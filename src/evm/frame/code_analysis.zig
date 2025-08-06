const std = @import("std");
const limits = @import("../constants/code_analysis_limits.zig");
const StaticBitSet = std.bit_set.StaticBitSet;

// Import structs from their own files
pub const BlockMetadata = @import("block_metadata.zig");
pub const BlockMetadataSoA = @import("block_metadata_soa.zig");

/// Advanced code analysis for EVM bytecode optimization.
///
/// This structure holds pre-computed analysis results for a contract's bytecode,
/// enabling efficient execution by pre-identifying jump destinations, code segments,
/// and other properties that would otherwise need to be computed at runtime.
///
/// The analysis is performed once when a contract is first loaded and cached for
/// subsequent executions, significantly improving performance for frequently-used
/// contracts.
///
/// ## Fields
/// - `code_segments`: Bit vector marking which bytes are executable code vs data
/// - `jumpdest_bitmap`: Bitmap of valid JUMPDEST positions for O(1) validation
/// - `block_gas_costs`: Optional pre-computed gas costs for basic blocks
/// - `max_stack_depth`: Maximum stack depth required by the contract
/// - `has_dynamic_jumps`: Whether the code contains JUMP/JUMPI with dynamic targets
/// - `has_static_jumps`: Whether the code contains JUMP/JUMPI with static targets
/// - `has_selfdestruct`: Whether the code contains SELFDESTRUCT opcode
/// - `has_create`: Whether the code contains CREATE/CREATE2 opcodes
///
/// ## Performance
/// - Jump destination validation: O(1) using bitmap lookup
/// - Code segment checking: O(1) using bit vector
/// - Enables dead code elimination and other optimizations
///
/// ## Memory Management
/// The analysis owns its allocated memory and must be properly cleaned up
/// using the `deinit` method to prevent memory leaks.
const CodeAnalysis = @This();

/// Bit set marking which bytes in the bytecode are executable code vs data.
///
/// Each bit corresponds to a byte in the contract bytecode:
/// - 1 = executable code byte
/// - 0 = data byte (e.g., PUSH arguments)
///
/// This is critical for JUMPDEST validation since jump destinations
/// must point to actual code, not data bytes within PUSH instructions.
code_segments: StaticBitSet(limits.MAX_CONTRACT_SIZE),

/// Bitmap marking all valid JUMPDEST positions in the bytecode.
///
/// Each bit corresponds to a byte position in the code:
/// - 1 = valid JUMPDEST at this position
/// - 0 = not a valid JUMPDEST
///
/// This enables O(1) jump destination validation instead of O(log n) binary search.
jumpdest_bitmap: StaticBitSet(limits.MAX_CONTRACT_SIZE),

/// Optional pre-computed gas costs for each basic block.
///
/// When present, enables advanced gas optimization by pre-calculating
/// the gas cost of straight-line code sequences between jumps.
/// This is an optional optimization that may not be computed for all contracts.
block_gas_costs: ?[]const u32,

/// Maximum stack depth required by any execution path in the contract.
///
/// Pre-computed through static analysis to enable early detection of
/// stack overflow conditions. A value of 0 indicates the depth wasn't analyzed.
max_stack_depth: u16,

/// Indicates whether the contract contains JUMP/JUMPI opcodes with dynamic targets.
///
/// Dynamic jumps (where the target is computed at runtime) prevent certain
/// optimizations and require full jump destination validation at runtime.
has_dynamic_jumps: bool,

/// Indicates whether the contract contains JUMP/JUMPI opcodes with static targets.
///
/// Static jumps (where the target is a constant) can be pre-validated
/// and optimized during analysis.
has_static_jumps: bool,

/// Indicates whether the contract contains the SELFDESTRUCT opcode (0xFF).
///
/// Contracts with SELFDESTRUCT require special handling for state management
/// and cannot be marked as "pure" or side-effect free.
has_selfdestruct: bool,

/// Indicates whether the contract contains CREATE or CREATE2 opcodes.
///
/// Contracts that can deploy other contracts require additional
/// gas reservation and state management considerations.
has_create: bool,

/// Bit set marking the start positions of basic blocks.
///
/// Each bit corresponds to a byte position in the bytecode:
/// - 1 = start of a new basic block
/// - 0 = continuation of current block
///
/// Basic blocks are sequences of instructions with single entry/exit points,
/// enabling batch gas and stack validation for performance optimization.
block_starts: StaticBitSet(limits.MAX_CONTRACT_SIZE),

/// Array of metadata for each basic block in the bytecode.
///
/// Each entry contains the gas cost and stack requirements for one block,
/// indexed by block number. This enables the interpreter to validate entire
/// blocks at once instead of per-instruction validation.
/// @deprecated Use block_metadata_soa for better cache efficiency
block_metadata: [limits.MAX_BLOCKS]BlockMetadata,

/// Structure of Arrays version of block metadata for better cache efficiency.
/// This separates hot (gas, stack) and cold (max growth) data into different arrays.
block_metadata_soa: BlockMetadataSoA,

/// Maps each bytecode position (PC) to its containing block index.
///
/// This lookup table enables O(1) determination of which block contains
/// any given instruction, critical for efficient block-based execution.
/// Values are limited to u16 to save memory (max 65535 blocks per contract).
pc_to_block: [limits.MAX_CONTRACT_SIZE]u16,

/// Total number of basic blocks identified in the bytecode.
///
/// Limited to u16 as contracts larger than 24KB are rejected, and typical
/// contracts have far fewer than 65535 blocks. Most contracts have < 1000 blocks.
block_count: u16,

/// Clean up any remaining allocated memory.
/// With StaticBitSet and fixed arrays, only block_gas_costs needs cleanup.
pub fn deinit(self: *CodeAnalysis, allocator: std.mem.Allocator) void {
    if (self.block_gas_costs) |costs| {
        allocator.free(costs);
    }
    // StaticBitSet and fixed arrays don't need deallocation
    self.* = undefined;
}


test "CodeAnalysis with block data initializes and deinits correctly" {
    const allocator = std.testing.allocator;

    var analysis = CodeAnalysis{
        .code_segments = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .jumpdest_bitmap = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .block_starts = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .block_metadata = undefined,
        .block_metadata_soa = BlockMetadataSoA.init(),
        .pc_to_block = undefined,
        .block_count = 10,
        .max_stack_depth = 0,
        .has_dynamic_jumps = false,
        .has_static_jumps = false,
        .has_selfdestruct = false,
        .has_create = false,
        .block_gas_costs = null,
    };
    defer analysis.deinit(allocator);
    
    // Initialize some test data
    analysis.block_metadata_soa.count = 10;
    @memset(&analysis.pc_to_block, 0);

    // Verify fields are accessible
    try std.testing.expectEqual(@as(u16, 10), analysis.block_count);
    try std.testing.expectEqual(@as(usize, limits.MAX_BLOCKS), analysis.block_metadata.len);
    try std.testing.expectEqual(@as(usize, limits.MAX_CONTRACT_SIZE), analysis.pc_to_block.len);

    // Test pc_to_block mapping
    analysis.pc_to_block[50] = 5;
    try std.testing.expectEqual(@as(u16, 5), analysis.pc_to_block[50]);
}

test "CodeAnalysis deinit handles partially initialized state" {
    const allocator = std.testing.allocator;

    // Test with empty block data
    var analysis = CodeAnalysis{
        .code_segments = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .jumpdest_bitmap = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .block_starts = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .block_metadata = undefined,
        .block_metadata_soa = BlockMetadataSoA.init(),
        .pc_to_block = undefined,
        .block_count = 0,
        .max_stack_depth = 0,
        .has_dynamic_jumps = false,
        .has_static_jumps = false,
        .has_selfdestruct = false,
        .has_create = false,
        .block_gas_costs = null,
    };

    // Should not crash on deinit
    analysis.deinit(allocator);
}

test "Block analysis correctly identifies basic blocks" {
    const allocator = std.testing.allocator;

    // Test bytecode with multiple basic blocks:
    // Block 0: PUSH1 0x10 PUSH1 0x20 ADD
    // Block 1: JUMPDEST PUSH1 0x30 MUL
    // Block 2: JUMPDEST STOP
    const code = &[_]u8{
        0x60, 0x10, // PUSH1 0x10
        0x60, 0x20, // PUSH1 0x20
        0x01, // ADD
        0x5b, // JUMPDEST (starts block 1)
        0x60, 0x30, // PUSH1 0x30
        0x02, // MUL
        0x5b, // JUMPDEST (starts block 2)
        0x00, // STOP
    };

    var analysis = try analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);

    // Verify block count
    try std.testing.expectEqual(@as(u16, 3), analysis.block_count);

    // Verify block starts
    try std.testing.expect(!analysis.block_starts.isSet(0)); // Block 0 starts at 0 (implicit)
    try std.testing.expect(!analysis.block_starts.isSet(1));
    try std.testing.expect(!analysis.block_starts.isSet(2));
    try std.testing.expect(!analysis.block_starts.isSet(3));
    try std.testing.expect(!analysis.block_starts.isSet(4));
    try std.testing.expect(analysis.block_starts.isSet(5)); // Block 1 starts at JUMPDEST
    try std.testing.expect(!analysis.block_starts.isSet(6));
    try std.testing.expect(!analysis.block_starts.isSet(7));
    try std.testing.expect(!analysis.block_starts.isSet(8));
    try std.testing.expect(analysis.block_starts.isSet(9)); // Block 2 starts at JUMPDEST

    // Verify PC to block mapping
    try std.testing.expectEqual(@as(u16, 0), analysis.pc_to_block[0]);
    try std.testing.expectEqual(@as(u16, 0), analysis.pc_to_block[1]);
    try std.testing.expectEqual(@as(u16, 0), analysis.pc_to_block[2]);
    try std.testing.expectEqual(@as(u16, 0), analysis.pc_to_block[3]);
    try std.testing.expectEqual(@as(u16, 0), analysis.pc_to_block[4]);
    try std.testing.expectEqual(@as(u16, 1), analysis.pc_to_block[5]);
    try std.testing.expectEqual(@as(u16, 1), analysis.pc_to_block[6]);
    try std.testing.expectEqual(@as(u16, 1), analysis.pc_to_block[7]);
    try std.testing.expectEqual(@as(u16, 1), analysis.pc_to_block[8]);
    try std.testing.expectEqual(@as(u16, 2), analysis.pc_to_block[9]);
    try std.testing.expectEqual(@as(u16, 2), analysis.pc_to_block[10]);

    // Verify block metadata count
    try std.testing.expectEqual(@as(u16, 3), analysis.block_count);

    // Block 0: PUSH1 (3) + PUSH1 (3) + ADD (3) = 9 gas
    try std.testing.expectEqual(@as(u32, 9), analysis.block_metadata[0].gas_cost);
    try std.testing.expectEqual(@as(i16, 0), analysis.block_metadata[0].stack_req);
    try std.testing.expectEqual(@as(i16, 1), analysis.block_metadata[0].stack_max); // Pushes 2, pops 2, net +1

    // Block 1: JUMPDEST (1) + PUSH1 (3) + MUL (5) = 9 gas
    try std.testing.expectEqual(@as(u32, 9), analysis.block_metadata[1].gas_cost);
    try std.testing.expectEqual(@as(i16, 1), analysis.block_metadata[1].stack_req); // Needs 1 from previous block
    try std.testing.expectEqual(@as(i16, 1), analysis.block_metadata[1].stack_max); // Has 1, pushes 1, pops 2, net 0

    // Block 2: JUMPDEST (1) + STOP (0) = 1 gas
    try std.testing.expectEqual(@as(u32, 1), analysis.block_metadata[2].gas_cost);
    try std.testing.expectEqual(@as(i16, 0), analysis.block_metadata[2].stack_req);
    try std.testing.expectEqual(@as(i16, 0), analysis.block_metadata[2].stack_max);
}

test "Block analysis handles jumps correctly" {
    const allocator = std.testing.allocator;

    // Test bytecode with conditional and unconditional jumps:
    // PUSH1 0x08 PUSH1 0x01 EQ PUSH1 0x0a JUMPI STOP JUMPDEST PUSH1 0x42 STOP
    const code = &[_]u8{
        0x60, 0x08, // PUSH1 0x08
        0x60, 0x01, // PUSH1 0x01
        0x14, // EQ
        0x60, 0x0a, // PUSH1 0x0a (jump target)
        0x57, // JUMPI (conditional jump)
        0x00, // STOP
        0x5b, // JUMPDEST (at position 0x0a)
        0x60, 0x42, // PUSH1 0x42
        0x00, // STOP
    };

    var analysis = try analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);

    // Should have 3 blocks:
    // Block 0: 0-8 (up to JUMPI)
    // Block 1: 9 (STOP after JUMPI)
    // Block 2: 10-13 (JUMPDEST onwards)
    try std.testing.expectEqual(@as(u16, 3), analysis.block_count);

    // Verify JUMPI creates block boundaries
    try std.testing.expect(analysis.block_starts.isSet(9)); // New block after JUMPI
    try std.testing.expect(analysis.block_starts.isSet(10)); // JUMPDEST starts new block
}

test "Block analysis calculates gas costs correctly" {
    const allocator = std.testing.allocator;

    // Test with various opcodes to verify gas calculation
    const code = &[_]u8{
        0x60, 0x01, // PUSH1 (3 gas)
        0x60, 0x02, // PUSH1 (3 gas)
        0x01, // ADD (3 gas)
        0x60, 0x03, // PUSH1 (3 gas)
        0x02, // MUL (5 gas)
        0x5b, // JUMPDEST (1 gas) - new block
        0x80, // DUP1 (3 gas)
        0x50, // POP (2 gas)
        0x00, // STOP (0 gas)
    };

    var analysis = try analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 2), analysis.block_count);

    // Block 0: 3+3+3+3+5 = 17 gas
    try std.testing.expectEqual(@as(u32, 17), analysis.block_metadata[0].gas_cost);

    // Block 1: 1+3+2+0 = 6 gas
    try std.testing.expectEqual(@as(u32, 6), analysis.block_metadata[1].gas_cost);
}

test "Block analysis tracks stack effects" {
    const allocator = std.testing.allocator;

    // Test stack tracking across blocks
    const code = &[_]u8{
        0x60, 0x01, // PUSH1 (stack: +1)
        0x60, 0x02, // PUSH1 (stack: +1)
        0x60, 0x03, // PUSH1 (stack: +1)
        0x5b, // JUMPDEST - new block, inherits stack depth 3
        0x01, // ADD (stack: -1)
        0x02, // MUL (stack: -1)
        0x5b, // JUMPDEST - new block, inherits stack depth 1
        0x50, // POP (stack: -1)
        0x00, // STOP
    };

    var analysis = try analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 3), analysis.block_count);

    // Block 0: starts with 0, max growth to 3
    try std.testing.expectEqual(@as(i16, 0), analysis.block_metadata[0].stack_req);
    try std.testing.expectEqual(@as(i16, 3), analysis.block_metadata[0].stack_max);

    // Block 1: needs 3 items (for ADD and MUL), ends with 1
    try std.testing.expectEqual(@as(i16, 3), analysis.block_metadata[1].stack_req);
    try std.testing.expectEqual(@as(i16, 0), analysis.block_metadata[1].stack_max); // No growth, only consumption

    // Block 2: needs 1 item (for POP)
    try std.testing.expectEqual(@as(i16, 1), analysis.block_metadata[2].stack_req);
    try std.testing.expectEqual(@as(i16, 0), analysis.block_metadata[2].stack_max);
}

/// Creates a code bitmap that marks which bytes are opcodes vs data.
fn createCodeBitmap(code: []const u8) StaticBitSet(limits.MAX_CONTRACT_SIZE) {
    const opcode = @import("../opcodes/opcode.zig");
    var bitmap = StaticBitSet(limits.MAX_CONTRACT_SIZE).initFull();
    
    var i: usize = 0;
    while (i < code.len and i < limits.MAX_CONTRACT_SIZE) {
        const op = code[i];
        
        // If the opcode is a PUSH, mark pushed bytes as data (not code)
        if (opcode.is_push(op)) {
            const push_bytes = opcode.get_push_size(op);
            var j: usize = 1;
            while (j <= push_bytes and i + j < code.len and i + j < limits.MAX_CONTRACT_SIZE) : (j += 1) {
                bitmap.unset(i + j);
            }
            i += 1 + push_bytes;
        } else {
            i += 1;
        }
    }
    
    return bitmap;
}

/// Analyzes bytecode to identify basic blocks and calculate metadata for each block.
///
/// A basic block is a sequence of instructions with:
/// - Single entry point (first instruction or jump target)
/// - Single exit point (jump/stop/return or fall-through to next block)
///
/// This analysis enables block-based execution optimization by pre-calculating:
/// - Gas costs for the entire block
/// - Stack requirements and effects
/// - PC to block mapping for fast lookup
/// 
/// Returns CodeAnalysis by value - no allocation required (except for optional block_gas_costs).
pub fn analyze_bytecode_blocks(allocator: std.mem.Allocator, code: []const u8) !CodeAnalysis {
    const opcode = @import("../opcodes/opcode.zig");
    const jump_table = @import("../jump_table/jump_table.zig");

    // Initialize analysis structure with fixed arrays
    var analysis = CodeAnalysis{
        .code_segments = createCodeBitmap(code),
        .jumpdest_bitmap = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .block_starts = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .block_metadata = undefined,  // Will be filled during analysis
        .block_metadata_soa = BlockMetadataSoA.init(),
        .pc_to_block = undefined,  // Will be filled during analysis
        .block_count = 0,
        .max_stack_depth = 0,
        .has_dynamic_jumps = false,
        .has_static_jumps = false,
        .has_selfdestruct = false,
        .has_create = false,
        .block_gas_costs = null,
    };
    errdefer analysis.deinit(allocator);

    if (code.len == 0) return analysis;

    // First pass: identify JUMPDESTs and block boundaries
    var i: usize = 0;
    while (i < code.len) {
        const op = code[i];

        // Mark JUMPDEST positions
        if (op == @intFromEnum(opcode.Enum.JUMPDEST) and analysis.code_segments.isSet(i)) {
            analysis.jumpdest_bitmap.set(i);
            // JUMPDESTs always start new blocks (except at position 0)
            if (i > 0) {
                analysis.block_starts.set(i);
            }
        }

        // Handle opcodes that end blocks - skip invalid opcodes
        const maybe_opcode = std.meta.intToEnum(opcode.Enum, op) catch {
            // Invalid opcode, skip it
            continue;
        };
        switch (maybe_opcode) {
            .JUMP, .JUMPI => {
                analysis.has_static_jumps = true;
                // Next instruction starts new block (if exists)
                if (i + 1 < code.len) {
                    analysis.block_starts.set(i + 1);
                }
            },
            .STOP, .RETURN, .REVERT, .INVALID, .SELFDESTRUCT => {
                if (op == @intFromEnum(opcode.Enum.SELFDESTRUCT)) {
                    analysis.has_selfdestruct = true;
                }
                // Next instruction starts new block (if exists)
                if (i + 1 < code.len) {
                    analysis.block_starts.set(i + 1);
                }
            },
            .CREATE, .CREATE2 => {
                analysis.has_create = true;
            },
            else => {},
        }

        // Advance PC
        if (opcode.is_push(op)) {
            const push_bytes = opcode.get_push_size(op);
            i += 1 + push_bytes;
        } else {
            i += 1;
        }
    }

    // Count blocks
    var block_count: u16 = 1; // First block starts at 0 (implicit)
    i = 1;
    while (i < code.len) : (i += 1) {
        if (analysis.block_starts.isSet(i)) {
            block_count += 1;
        }
    }
    analysis.block_count = block_count;

    // Set the count for SoA structure
    analysis.block_metadata_soa.count = block_count;
    
    // Initialize pc_to_block array with zeros
    @memset(&analysis.pc_to_block, 0);

    // Initialize jump table for gas cost lookup
    const table = jump_table.JumpTable.DEFAULT;

    // Second pass: analyze each block
    var current_block: u16 = 0;
    var block_start_pc: usize = 0;
    var gas_cost: u32 = 0;
    var stack_depth: i16 = 0;
    var block_stack_start: i16 = 0;
    var min_stack_in_block: i16 = 0;
    var max_stack_in_block: i16 = 0;

    i = 0;
    while (i < code.len) {
        // Record PC to block mapping (only if within bounds)
        if (i < limits.MAX_CONTRACT_SIZE) {
            analysis.pc_to_block[i] = current_block;
        }

        // Check if this starts a new block (except at 0)
        if (i > 0 and analysis.block_starts.isSet(i)) {
            // Save metadata for completed block
            const metadata = BlockMetadata{
                .gas_cost = gas_cost,
                .stack_req = @max(0, block_stack_start + min_stack_in_block),
                .stack_max = max_stack_in_block - block_stack_start,
            };
            analysis.block_metadata[current_block] = metadata;
            // Also populate SoA structure
            analysis.block_metadata_soa.setBlock(current_block, metadata.gas_cost, metadata.stack_req, metadata.stack_max);

            // Start new block
            current_block += 1;
            block_start_pc = i;
            gas_cost = 0;
            // New block inherits stack depth from previous
            block_stack_start = stack_depth;
            min_stack_in_block = 0;
            max_stack_in_block = stack_depth;
        }

        const op = code[i];

        // Skip non-code bytes (PUSH data)
        if (!analysis.code_segments.isSet(i)) {
            i += 1;
            continue;
        }

        // Get operation from jump table
        const operation_ptr = table.get_operation(op);

        // Add constant gas cost
        gas_cost = @min(gas_cost + @as(u32, @intCast(operation_ptr.constant_gas)), std.math.maxInt(u32));

        // Track stack effects
        const stack_inputs = @as(i16, @intCast(operation_ptr.min_stack));
        // For simplicity, assume operations that consume min_stack items push back max_stack items
        // This is a conservative approximation good enough for block analysis
        const stack_outputs: i16 = if (operation_ptr.max_stack > operation_ptr.min_stack) 1 else 0;

        // First check if we have enough stack items
        const pre_stack = stack_depth;

        // Calculate net stack effect
        const net_effect = stack_outputs - stack_inputs;
        stack_depth += net_effect;

        // Track minimum stack depth reached in block
        if (pre_stack - stack_inputs < min_stack_in_block) {
            min_stack_in_block = pre_stack - stack_inputs;
        }

        // Track maximum stack depth in block
        if (stack_depth > max_stack_in_block) {
            max_stack_in_block = stack_depth;
        }

        // Track overall max stack depth
        const abs_stack_depth = @as(u16, @intCast(@max(0, stack_depth)));
        if (abs_stack_depth > analysis.max_stack_depth) {
            analysis.max_stack_depth = abs_stack_depth;
        }

        // Advance PC
        if (opcode.is_push(op)) {
            const push_bytes = opcode.get_push_size(op);
            var j: usize = 1;
            while (j <= push_bytes and i + j < code.len) : (j += 1) {
                if (i + j < limits.MAX_CONTRACT_SIZE) {
                    analysis.pc_to_block[i + j] = current_block;
                }
            }
            i += 1 + push_bytes;
        } else {
            i += 1;
        }
    }

    // Save metadata for final block
    if (current_block < block_count) {
        const metadata = BlockMetadata{
            .gas_cost = gas_cost,
            .stack_req = @max(0, block_stack_start + min_stack_in_block),
            .stack_max = max_stack_in_block - block_stack_start,
        };
        analysis.block_metadata[current_block] = metadata;
        // Also populate SoA structure
        analysis.block_metadata_soa.setBlock(current_block, metadata.gas_cost, metadata.stack_req, metadata.stack_max);
    }

    return analysis;
}


test "pc_to_block mapping edge cases" {
    // Test with fixed array
    var mapping: [limits.MAX_CONTRACT_SIZE]u16 = undefined;
    
    // Simulate block assignments
    var current_block: u16 = 0;
    for (&mapping, 0..) |*pc_block, i| {
        if (i % 100 == 0) current_block += 1; // New block every 100 bytes
        pc_block.* = current_block;
    }

    // Test boundary conditions
    try std.testing.expectEqual(@as(u16, 1), mapping[0]);
    try std.testing.expectEqual(@as(u16, 2), mapping[100]);
    try std.testing.expectEqual(@as(u16, 246), mapping[24500]);
}

test "BlockMetadata with contract deployment scenarios" {
    const allocator = std.testing.allocator;

    // Simulate analysis for different contract types
    const test_cases = .{
        .{ .size = 0, .blocks = 0 }, // Empty contract
        .{ .size = 1, .blocks = 1 }, // Minimal contract (STOP)
        .{ .size = 100, .blocks = 5 }, // Small contract
        .{ .size = 24576, .blocks = 1000 }, // Max size contract
    };

    inline for (test_cases) |tc| {
        var analysis = CodeAnalysis{
            .code_segments = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
            .jumpdest_bitmap = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
            .block_starts = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
            .block_metadata = undefined,
            .block_metadata_soa = BlockMetadataSoA.init(),
            .pc_to_block = undefined,
            .block_count = tc.blocks,
            .max_stack_depth = 0,
            .has_dynamic_jumps = false,
            .has_static_jumps = false,
            .has_selfdestruct = false,
            .has_create = false,
            .block_gas_costs = null,
        };
        defer analysis.deinit(allocator);
        
        analysis.block_metadata_soa.count = tc.blocks;

        // Verify fields are correctly set
        try std.testing.expectEqual(tc.blocks, analysis.block_count);
        try std.testing.expectEqual(tc.blocks, analysis.block_metadata_soa.count);
    }
}
