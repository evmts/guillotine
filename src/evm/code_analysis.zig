const std = @import("std");
const builtin = @import("builtin");
const limits = @import("constants/code_analysis_limits.zig");
const DynamicBitSet = std.DynamicBitSet;
const Instruction = @import("instruction.zig").Instruction;
const Tag = @import("instruction.zig").Tag;
const JumpType = @import("instruction.zig").JumpType;
const InstructionType = @import("instruction.zig").InstructionType;
const ExecutionError = @import("execution/execution_error.zig");
const Opcode = @import("opcodes/opcode.zig");
const OpcodeMetadata = @import("opcode_metadata/opcode_metadata.zig");
const Log = @import("log.zig");

// Import modular components
const createCodeBitmap = @import("code_bitmap.zig").createCodeBitmap;
const codeToInstructions = @import("instruction_generation.zig").codeToInstructions;
const applyPatternOptimizations = @import("pattern_optimization.zig").applyPatternOptimizations;
const size_buckets = @import("size_buckets.zig");
const Bucket8 = size_buckets.Bucket8;
const Bucket16 = size_buckets.Bucket16;
const Bucket24 = size_buckets.Bucket24;
const Size8Counts = size_buckets.Size8Counts;
const Size16Counts = size_buckets.Size16Counts;
const Size24Counts = size_buckets.Size24Counts;
pub const JumpdestArray = size_buckets.JumpdestArray;

/// Handler for opcodes that should never be executed directly.
/// Used for JUMP, JUMPI, and PUSH opcodes that are handled inline by the interpreter.
/// This function should never be called - if it is, there's a bug in the analysis or interpreter.
pub fn UnreachableHandler(frame: *anyopaque) ExecutionError.Error!void {
    _ = frame;
    // Noop by design: instructions that should be handled inline (e.g., PUSH/PC) or via control-flow
    // metadata (.next_instruction / .conditional_jump) will never need their execute fn invoked.
    return;
}

/// Handler for BEGINBLOCK instructions that validates an entire basic block upfront.
/// This performs gas and stack validation for all instructions in the block in one operation,
/// eliminating the need for per-instruction validation during execution.
///
/// The block information (gas cost, stack requirements) is stored in the instruction's arg.block_info.
/// This handler must be called before executing any instructions in the basic block.
pub const BeginBlockHandler = @import("instruction.zig").NoopHandler;

/// Optimized code analysis for EVM bytecode execution.
/// Contains only the essential data needed during execution.
/// Fields are organized by access frequency for optimal cache performance.
pub const CodeAnalysis = @This();

// === FIRST CACHE LINE - ULTRA HOT (accessed on every instruction) ===
/// Heap-allocated instruction header stream for execution.
/// Compact headers reference payloads stored in SoA arrays below.
instructions: []Instruction, // compact headers

/// Size-based arrays for better cache efficiency
/// 8-byte structs (NoopInstruction, JumpPcInstruction, ConditionalJumpUnresolvedInstruction, ConditionalJumpInvalidInstruction)
size8_instructions: []Bucket8,
/// 16-byte structs (ExecInstruction, ConditionalJumpPcInstruction, WordInstruction, PcInstruction)
size16_instructions: []Bucket16,
/// 24-byte structs (BlockInstruction, DynamicGasInstruction)
size24_instructions: []Bucket24,

/// Tracking counters for each struct type within size categories
size8_counts: Size8Counts,
size16_counts: Size16Counts,
size24_counts: Size24Counts,

/// Mapping from bytecode PC to the BEGINBLOCK instruction index that contains that PC.
/// Size = code_len. Value = maxInt(u16) if unmapped.
pc_to_block_start: []u16, // 16 bytes - accessed on EVERY jump

/// Packed array of valid JUMPDEST positions in the bytecode.
/// Required for JUMP/JUMPI validation during execution.
/// Uses cache-efficient linear search on packed u15 array.
jumpdest_array: JumpdestArray, // 24 bytes - accessed on jump validation

// === SECOND CACHE LINE - WARM (accessed during specific operations) ===
/// Original contract bytecode for this analysis (used by CODECOPY).
code: []const u8, // 16 bytes - accessed by CODECOPY/CODESIZE

/// Original code length (used for bounds checks)
code_len: usize, // 8 bytes - accessed with code operations

/// For each instruction index, indicates if it is a JUMP or JUMPI (or other).
/// Size = instructions.len
inst_jump_type: []JumpType, // 16 bytes - accessed during control flow

// === THIRD CACHE LINE - COLD (rarely accessed) ===
/// Mapping from instruction index to original bytecode PC (for debugging/tracing)
inst_to_pc: []u16, // 16 bytes - only for debugging/tracing

/// Allocator used for the instruction array (needed for cleanup)
allocator: std.mem.Allocator, // 16 bytes - only accessed on deinit

/// Generic function to get instruction parameters from size-based arrays
pub fn getInstructionParams(self: *const CodeAnalysis, comptime tag: Tag, id: u24) InstructionType(tag) {
    return size_buckets.getInstructionParams(self.size8_instructions, self.size16_instructions, self.size24_instructions, tag, id);
}

/// Main public API: Analyzes bytecode and returns optimized CodeAnalysis with instruction stream.
/// The caller must call deinit() to free the instruction array.
/// TODO: Add chain_rules parameter to validate EIP-specific opcodes during analysis:
/// - EIP-3855 (PUSH0): Reject PUSH0 in pre-Shanghai contracts
/// - EIP-5656 (MCOPY): Reject MCOPY in pre-Cancun contracts
/// - EIP-3198 (BASEFEE): Reject BASEFEE in pre-London contracts
pub fn from_code(allocator: std.mem.Allocator, code: []const u8, jump_table: *const OpcodeMetadata) !CodeAnalysis {
    if (code.len > limits.MAX_CONTRACT_SIZE) {
        return error.CodeTooLarge;
    }

    // MEMORY ALLOCATION: Temporary code bitmap (freed after analysis)
    // Expected size: code_len bits (rounded up)
    // Lifetime: During analysis only (freed immediately)
    // Frequency: Once per analysis
    var code_segments = try createCodeBitmap(allocator, code);
    defer code_segments.deinit();

    // MEMORY ALLOCATION: Jumpdest bitmap
    // Expected size: code_len bits (rounded up)
    // Lifetime: Per analysis
    // Frequency: Once per unique contract bytecode
    var jumpdest_bitmap = try DynamicBitSet.initEmpty(allocator, code.len);
    errdefer jumpdest_bitmap.deinit();

    if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        // Bitmap sizes should be proportional to code length
        // Each bit represents one byte of code
        const bitmap_bytes = (code.len + 7) / 8; // Round up to nearest byte
        // Max contract is 24KB, so bitmaps should be max 3KB each
        std.debug.assert(bitmap_bytes <= 3072); // 3KB max
    }

    if (code.len == 0) {
        Log.debug("[analysis] Empty code, returning empty analysis", .{});
        // For empty code, convert empty bitmap to empty array and create 1-element array with sentinel
        const jumpdest_array = try JumpdestArray.from_bitmap(allocator, &jumpdest_bitmap, code.len);
        jumpdest_bitmap.deinit(); // Free the temporary bitmap

        const empty_instructions = try allocator.alloc(Instruction, 1);
        empty_instructions[0] = .{ .tag = .exec, .id = 0 };

        // Allocate size-based arrays
        const empty_size8 = try allocator.alloc(Bucket8, 0);
        const empty_size16 = try allocator.alloc(Bucket16, 1); // Need 1 exec instruction for STOP
        const empty_size24 = try allocator.alloc(Bucket24, 0);

        // Create and copy the STOP exec instruction to size16 array
        const stop_op = jump_table.get_operation(@intFromEnum(Opcode.Enum.STOP));
        const exec_inst = @import("instruction.zig").ExecInstruction{
            .exec_fn = stop_op.execute,
            .next_inst = &empty_instructions[0], // Points to itself (STOP terminates anyway)
        };
        @memcpy(empty_size16[0].bytes[0..@sizeOf(@import("instruction.zig").ExecInstruction)], std.mem.asBytes(&exec_inst));

        const empty_jump_types = try allocator.alloc(JumpType, 0);
        const empty_pc_map = try allocator.alloc(u16, 0);
        const empty_inst_to_pc = try allocator.alloc(u16, 0);
        return CodeAnalysis{
            // First cache line - hot
            .instructions = empty_instructions,
            .size8_instructions = empty_size8,
            .size16_instructions = empty_size16,
            .size24_instructions = empty_size24,
            .size8_counts = .{},
            .size16_counts = .{ .exec = 1 },
            .size24_counts = .{},
            .pc_to_block_start = empty_pc_map,
            .jumpdest_array = jumpdest_array,
            // Second cache line - warm
            .code = &[_]u8{},
            .code_len = 0,
            .inst_jump_type = empty_jump_types,
            // Third cache line - cold
            .inst_to_pc = empty_inst_to_pc,
            .allocator = allocator,
        };
    }

    // First pass: identify JUMPDESTs and contract properties
    var i: usize = 0;
    var loop_iterations: u32 = 0;
    const max_iterations = limits.MAX_CONTRACT_SIZE * 2; // Safety check
    while (i < code.len) {
        // Safety check to prevent infinite loops
        loop_iterations += 1;
        if (loop_iterations > max_iterations) {
            return error.InstructionLimitExceeded;
        }

        const op = code[i];

        // Mark JUMPDEST positions
        if (op == @intFromEnum(Opcode.Enum.JUMPDEST) and code_segments.isSet(i)) {
            jumpdest_bitmap.set(i);
            if (builtin.mode == .Debug and code.len < 100) {
                Log.debug("[JUMPDEST_SCAN] Found JUMPDEST at pc={}, code_segment={}", .{ i, code_segments.isSet(i) });
            }
        }

        // Handle opcodes that affect contract properties - skip invalid opcodes
        const maybe_opcode = std.meta.intToEnum(Opcode.Enum, op) catch {
            // Invalid opcode, skip it but MUST increment i to avoid infinite loop
            i += 1;
            continue;
        };
        switch (maybe_opcode) {
            .JUMP, .JUMPI => {},
            .SELFDESTRUCT => {},
            .CREATE, .CREATE2 => {},
            else => {},
        }

        // Advance PC
        if (Opcode.is_push(op)) {
            const push_bytes = Opcode.get_push_size(op);
            i += 1 + push_bytes;
        } else {
            i += 1;
        }
    }

    // Simple stack depth analysis
    var stack_depth: i16 = 0;
    i = 0;
    loop_iterations = 0;
    while (i < code.len) {
        loop_iterations += 1;
        if (loop_iterations > max_iterations) {
            return error.InstructionLimitExceeded;
        }

        const op = code[i];

        // Skip non-code bytes (PUSH data)
        if (!code_segments.isSet(i)) {
            i += 1;
            continue;
        }

        // Get precise stack height change from lookup table
        const net_change = @import("opcodes/stack_height_changes.zig").get_stack_height_change(op);

        // Update stack depth
        stack_depth = stack_depth + net_change;

        // Track max stack depth (for potential future use)
        _ = @as(u16, @intCast(@max(0, stack_depth)));

        // Advance PC
        if (Opcode.is_push(op)) {
            const push_bytes = Opcode.get_push_size(op);
            i += 1 + push_bytes;
        } else {
            i += 1;
        }
    }

    // Convert to instruction stream using temporary data
    const gen = try codeToInstructions(allocator, code, jump_table, &jumpdest_bitmap);

    // Apply pattern optimizations (like SHA3 precomputation)
    try applyPatternOptimizations(gen.instructions, code);

    // Convert bitmap to packed array for cache-efficient validation
    const jumpdest_array = try JumpdestArray.from_bitmap(allocator, &jumpdest_bitmap, code.len);
    jumpdest_bitmap.deinit(); // Free the temporary bitmap
    

    return CodeAnalysis{
        // === FIRST CACHE LINE - ULTRA HOT ===
        .instructions = gen.instructions,
        .size8_instructions = gen.size8_instructions,
        .size16_instructions = gen.size16_instructions,
        .size24_instructions = gen.size24_instructions,
        .size8_counts = gen.size8_counts,
        .size16_counts = gen.size16_counts,
        .size24_counts = gen.size24_counts,
        .pc_to_block_start = gen.pc_to_block_start,
        .jumpdest_array = jumpdest_array,
        // === SECOND CACHE LINE - WARM ===
        .code = code,
        .code_len = code.len,
        .inst_jump_type = gen.inst_jump_type,
        // === THIRD CACHE LINE - COLD ===
        .inst_to_pc = gen.inst_to_pc,
        .allocator = allocator,
    };
}

/// Clean up allocated instruction array and packed jumpdest array.
/// Must be called by the caller to prevent memory leaks.
pub fn deinit(self: *CodeAnalysis) void {
    // Free the instruction array and size-based arrays
    self.allocator.free(self.instructions);
    self.allocator.free(self.size8_instructions);
    self.allocator.free(self.size16_instructions);
    self.allocator.free(self.size24_instructions);

    // Free auxiliary arrays
    self.allocator.free(self.inst_jump_type);
    self.allocator.free(self.pc_to_block_start);
    self.allocator.free(self.inst_to_pc);

    // Free the packed jumpdest array
    self.jumpdest_array.deinit(self.allocator);
}

// ============================================================================
// Compile-time layout assertions documenting expected characteristics
comptime {
    // Keep CodeAnalysis reasonably small to preserve cache behavior
    if (@sizeOf(CodeAnalysis) >= 256) @compileError("CodeAnalysis grew beyond expected footprint (<256 bytes)");
    // Slices and pointers should be naturally aligned; ensure struct alignment is not weaker
    if (@alignOf(CodeAnalysis) < @alignOf(*anyopaque)) @compileError("CodeAnalysis alignment must be at least pointer alignment");
}
