const std = @import("std");
const limits = @import("constants/code_analysis_limits.zig");
const StaticBitSet = std.bit_set.StaticBitSet;
const DynamicBitSet = std.DynamicBitSet;
const Instruction = @import("instruction.zig").Instruction;
const BlockInfo = @import("instruction.zig").BlockInfo;
const JumpType = @import("instruction.zig").JumpType;
const JumpTarget = @import("instruction.zig").JumpTarget;
const DynamicGas = @import("instruction.zig").DynamicGas;
const DynamicGasFunc = @import("instruction.zig").DynamicGasFunc;
const Opcode = @import("opcodes/opcode.zig");
const JumpTable = @import("jump_table/jump_table.zig");
const instruction_limits = @import("constants/instruction_limits.zig");
const ExecutionError = @import("execution/execution_error.zig");
const execution = @import("execution/package.zig");
const Frame = @import("frame.zig").Frame;
const Log = @import("log.zig");
const stack_height_changes = @import("opcodes/stack_height_changes.zig");
const dynamic_gas = @import("gas/dynamic_gas.zig");

/// Optimized code analysis for EVM bytecode execution.
/// Contains only the essential data needed during execution.
pub const CodeAnalysis = @This();

/// Heap-allocated instruction stream for execution.
/// Must be freed by caller using deinit().
instructions: []Instruction,

/// Original contract bytecode for this analysis (used by CODECOPY).
code: []const u8,

/// Heap-allocated bitmap marking all valid JUMPDEST positions in the bytecode.
/// Required for JUMP/JUMPI validation during execution.
jumpdest_bitmap: DynamicBitSet,

/// Mapping from bytecode PC to the BEGINBLOCK instruction index that contains that PC.
/// Size = code_len. Value = maxInt(u16) if unmapped.
pc_to_block_start: []u16,

/// For each instruction index, indicates if it is a JUMP or JUMPI (or other).
/// Size = instructions.len
inst_jump_type: []JumpType,

/// Original code length (used for bounds checks)
code_len: usize,

/// Allocator used for the instruction array (needed for cleanup)
allocator: std.mem.Allocator,

/// Handler for opcodes that should never be executed directly.
/// Used for JUMP, JUMPI, and PUSH opcodes that are handled inline by the interpreter.
/// This function should never be called - if it is, there's a bug in the analysis or interpreter.
pub fn UnreachableHandler(frame: *anyopaque) ExecutionError.Error!void {
    _ = frame;
    Log.err("UnreachableHandler called - this indicates a bug where an opcode marked for inline handling was executed through the jump table", .{});
    unreachable;
}

/// Handler for BEGINBLOCK instructions that validates an entire basic block upfront.
/// This performs gas and stack validation for all instructions in the block in one operation,
/// eliminating the need for per-instruction validation during execution.
///
/// The block information (gas cost, stack requirements) is stored in the instruction's arg.block_info.
/// This handler must be called before executing any instructions in the basic block.
pub fn BeginBlockHandler(frame: *anyopaque) ExecutionError.Error!void {
    // BEGINBLOCK validation is intentionally handled in the interpreter
    // (see evm/interpret.zig under the `.block_info` case). The opcode_fn
    // for BEGINBLOCK is a no-op to avoid double-charging gas or duplicating
    // stack validation. Keeping this as a no-op also prevents accidental
    // misuse if called directly.
    _ = frame;
    return;
}

/// Block analysis structure used during instruction stream generation.
/// Tracks the accumulated requirements for a basic block during analysis.
const BlockAnalysis = struct {
    /// Total static gas cost accumulated for all instructions in the block
    gas_cost: u32 = 0,
    /// Stack height requirement relative to block start
    stack_req: i16 = 0,
    /// Maximum stack growth during block execution
    stack_max_growth: i16 = 0,
    /// Current stack change from block start
    stack_change: i16 = 0,
    /// Index of the BEGINBLOCK instruction that starts this block
    begin_block_index: usize,

    /// Initialize a new block analysis at the given instruction index
    fn init(begin_index: usize) BlockAnalysis {
        return BlockAnalysis{
            .begin_block_index = begin_index,
        };
    }

    /// Close the current block by producing compressed information about the block
    fn close(self: *const BlockAnalysis) BlockInfo {
        return BlockInfo{
            .gas_cost = self.gas_cost,
            .stack_req = @intCast(@max(0, self.stack_req)),
            .stack_max_growth = @intCast(@max(0, self.stack_max_growth)),
        };
    }

    /// Update stack tracking for an operation
    fn updateStackTracking(self: *BlockAnalysis, opcode: u8, min_stack: u32) void {
        // Get the precise net stack change from the lookup table
        const net_change = stack_height_changes.get_stack_height_change(opcode);

        // min_stack tells us how many items the operation pops
        const stack_inputs = @as(i16, @intCast(min_stack));

        // Calculate requirement relative to block start
        const current_stack_req = stack_inputs - self.stack_change;
        self.stack_req = @max(self.stack_req, current_stack_req);

        // Update stack change using the precise net change
        self.stack_change += net_change;
        self.stack_max_growth = @max(self.stack_max_growth, self.stack_change);
    }
};

/// Main public API: Analyzes bytecode and returns optimized CodeAnalysis with instruction stream.
/// The caller must call deinit() to free the instruction array.
/// TODO: Add chain_rules parameter to validate EIP-specific opcodes during analysis:
/// - EIP-3855 (PUSH0): Reject PUSH0 in pre-Shanghai contracts
/// - EIP-5656 (MCOPY): Reject MCOPY in pre-Cancun contracts
/// - EIP-3198 (BASEFEE): Reject BASEFEE in pre-London contracts
pub fn from_code(allocator: std.mem.Allocator, code: []const u8, jump_table: *const JumpTable) !CodeAnalysis {
    if (code.len > limits.MAX_CONTRACT_SIZE) {
        return error.CodeTooLarge;
    }

    // Create temporary analysis data that will be discarded
    var code_segments = try createCodeBitmap(allocator, code);
    defer code_segments.deinit();
    var jumpdest_bitmap = try DynamicBitSet.initEmpty(allocator, code.len);
    errdefer jumpdest_bitmap.deinit();

    if (code.len == 0) {
        // For empty code, just create empty instruction array
        const empty_instructions = try allocator.alloc(Instruction, 0);
        const empty_jump_types = try allocator.alloc(JumpType, 0);
        const empty_pc_map = try allocator.alloc(u16, 0);
        return CodeAnalysis{
            .instructions = empty_instructions,
            .code = &[_]u8{},
            .jumpdest_bitmap = jumpdest_bitmap,
            .pc_to_block_start = empty_pc_map,
            .inst_jump_type = empty_jump_types,
            .code_len = 0,
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
        const net_change = stack_height_changes.get_stack_height_change(op);

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

    return CodeAnalysis{
        .instructions = gen.instructions,
        .code = code,
        .jumpdest_bitmap = jumpdest_bitmap,
        .pc_to_block_start = gen.pc_to_block_start,
        .inst_jump_type = gen.inst_jump_type,
        .code_len = code.len,
        .allocator = allocator,
    };
}

/// Clean up allocated instruction array and bitmap.
/// Must be called by the caller to prevent memory leaks.
pub fn deinit(self: *CodeAnalysis) void {
    // Free the instruction array (now a slice)
    self.allocator.free(self.instructions);

    // Free auxiliary arrays
    self.allocator.free(self.inst_jump_type);
    self.allocator.free(self.pc_to_block_start);

    // Free the bitmap
    self.jumpdest_bitmap.deinit();
}

/// Get the dynamic gas function for a specific opcode
fn getDynamicGasFunction(opcode: Opcode.Enum) ?DynamicGasFunc {
    return switch (opcode) {
        .CALL => dynamic_gas.call_dynamic_gas,
        .CALLCODE => dynamic_gas.callcode_dynamic_gas,
        .DELEGATECALL => dynamic_gas.delegatecall_dynamic_gas,
        .STATICCALL => dynamic_gas.staticcall_dynamic_gas,
        .CREATE => dynamic_gas.create_dynamic_gas,
        .CREATE2 => dynamic_gas.create2_dynamic_gas,
        .SSTORE => dynamic_gas.sstore_dynamic_gas,
        .GAS => dynamic_gas.gas_dynamic_gas,
        else => null,
    };
}

/// Creates a code bitmap that marks which bytes are opcodes vs data.
fn createCodeBitmap(allocator: std.mem.Allocator, code: []const u8) !DynamicBitSet {
    std.debug.assert(code.len <= limits.MAX_CONTRACT_SIZE);

    var bitmap = try DynamicBitSet.initFull(allocator, code.len);
    errdefer bitmap.deinit();

    var i: usize = 0;
    while (i < code.len) {
        const op = code[i];

        // If the opcode is a PUSH, mark pushed bytes as data (not code)
        if (Opcode.is_push(op)) {
            const push_bytes = Opcode.get_push_size(op);
            var j: usize = 1;
            while (j <= push_bytes and i + j < code.len) : (j += 1) {
                bitmap.unset(i + j);
            }
            i += 1 + push_bytes;
        } else {
            i += 1;
        }
    }

    return bitmap;
}

/// Convert bytecode to null-terminated instruction stream with block-based optimization.
/// This implementation follows evmone's advanced analysis approach by:
/// 1. Injecting BEGINBLOCK instructions at basic block boundaries
/// 2. Pre-calculating gas and stack requirements for entire blocks
/// 3. Eliminating per-instruction validation during execution
const CodeGenResult = struct {
    instructions: []Instruction,
    pc_to_block_start: []u16,
    inst_jump_type: []JumpType,
};

fn codeToInstructions(allocator: std.mem.Allocator, code: []const u8, jump_table: *const JumpTable, jumpdest_bitmap: *const DynamicBitSet) !CodeGenResult {
    Log.debug("[analysis] Converting {} bytes of code to instructions", .{code.len});

    // Allocate instruction array with extra space for BEGINBLOCK instructions
    const instructions = try allocator.alloc(Instruction, instruction_limits.MAX_INSTRUCTIONS + 1);
    errdefer allocator.free(instructions);

    // Allocate PC to instruction index mapping - tracks which instruction index corresponds to each PC
    const pc_to_instruction = try allocator.alloc(u16, code.len);
    defer allocator.free(pc_to_instruction);
    @memset(pc_to_instruction, std.math.maxInt(u16)); // Initialize with invalid values

    // Allocate per-instruction jump type tracker (will shrink later)
    var inst_jump_type = try allocator.alloc(JumpType, instruction_limits.MAX_INSTRUCTIONS + 1);
    errdefer allocator.free(inst_jump_type);
    // Initialize to .other
    var t: usize = 0;
    while (t < inst_jump_type.len) : (t += 1) inst_jump_type[t] = .other;

    var pc: usize = 0;
    var instruction_count: usize = 0;

    // Start first block with BEGINBLOCK instruction
    instructions[instruction_count] = Instruction{
        .opcode_fn = BeginBlockHandler,
        .arg = .{ .block_info = BlockInfo{} }, // Will be filled when block closes
    };
    var block = BlockAnalysis.init(instruction_count);
    instruction_count += 1;

    while (pc < code.len) {
        if (instruction_count >= instruction_limits.MAX_INSTRUCTIONS) {
            return error.InstructionLimitExceeded;
        }

        const opcode_byte = code[pc];
        const opcode = std.meta.intToEnum(Opcode.Enum, opcode_byte) catch {
            // Invalid opcode - accumulate in block and create instruction
            const operation = jump_table.get_operation(opcode_byte);
            block.gas_cost += @intCast(operation.constant_gas);
            block.updateStackTracking(opcode_byte, operation.min_stack);

            // Record PC to instruction mapping BEFORE incrementing instruction_count
            pc_to_instruction[pc] = @intCast(instruction_count);

            instructions[instruction_count] = Instruction{
                .opcode_fn = operation.execute,
                .arg = .none, // No individual gas cost - handled by BEGINBLOCK
            };
            instruction_count += 1;
            pc += 1;
            continue;
        };

        // Handle basic block boundaries and special opcodes
        switch (opcode) {
            .JUMPDEST => {
                // Close current block and start new one
                instructions[block.begin_block_index].arg.block_info = block.close();

                // Start new block with BEGINBLOCK
                instructions[instruction_count] = Instruction{
                    .opcode_fn = BeginBlockHandler,
                    .arg = .{ .block_info = BlockInfo{} },
                };
                block = BlockAnalysis.init(instruction_count);
                instruction_count += 1;

                // Add the JUMPDEST instruction to the new block
                const operation = jump_table.get_operation(opcode_byte);
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);

                // Record PC to instruction mapping for JUMPDEST
                pc_to_instruction[pc] = @intCast(instruction_count);

                instructions[instruction_count] = Instruction{
                    .opcode_fn = operation.execute,
                    .arg = .none,
                };
                instruction_count += 1;
                pc += 1;
            },

            // Terminating instructions - end current block
            .JUMP, .STOP, .RETURN, .REVERT, .SELFDESTRUCT => {
                Log.debug("[analysis] Found terminating instruction {} at pc={}", .{ opcode, pc });

                const operation = jump_table.get_operation(opcode_byte);
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);

                // Record PC to instruction mapping for terminating instructions
                pc_to_instruction[pc] = @intCast(instruction_count);

                if (opcode == .JUMP) {
                    instructions[instruction_count] = Instruction{
                        .opcode_fn = UnreachableHandler, // Handled inline by interpreter
                        .arg = .none, // May be filled by resolveJumpTargets; runtime resolution otherwise
                    };
                    inst_jump_type[instruction_count] = .jump;
                } else {
                    instructions[instruction_count] = Instruction{
                        .opcode_fn = operation.execute,
                        .arg = .none,
                    };
                }
                instruction_count += 1;
                pc += 1;

                // Close current block
                instructions[block.begin_block_index].arg.block_info = block.close();

                // Skip dead code until next JUMPDEST - but if we've reached the end, stop
                if (pc >= code.len) {
                    Log.debug("[analysis] Reached end of code after terminating instruction", .{});
                    break;
                }

                // Start new block for any code after the terminator
                instructions[instruction_count] = Instruction{
                    .opcode_fn = BeginBlockHandler,
                    .arg = .{ .block_info = BlockInfo{} },
                };
                block = BlockAnalysis.init(instruction_count);
                instruction_count += 1;
            },

            .JUMPI => {
                const operation = jump_table.get_operation(opcode_byte);
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);

                // Record PC to instruction mapping for JUMPI
                pc_to_instruction[pc] = @intCast(instruction_count);

                instructions[instruction_count] = Instruction{
                    .opcode_fn = UnreachableHandler, // Handled inline by interpreter
                    .arg = .none, // May be filled by resolveJumpTargets; runtime resolution otherwise
                };
                inst_jump_type[instruction_count] = .jumpi;
                instruction_count += 1;
                pc += 1;

                // Close current block and start new one (for fall-through path)
                instructions[block.begin_block_index].arg.block_info = block.close();
                instructions[instruction_count] = Instruction{
                    .opcode_fn = BeginBlockHandler,
                    .arg = .{ .block_info = BlockInfo{} },
                };
                block = BlockAnalysis.init(instruction_count);
                instruction_count += 1;
            },

            // PUSH operations - handled inline by interpreter
            .PUSH0 => {
                const operation = jump_table.get_operation(opcode_byte);
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);

                // Record PC to instruction mapping for PUSH0
                pc_to_instruction[pc] = @intCast(instruction_count);

                instructions[instruction_count] = Instruction{
                    .opcode_fn = UnreachableHandler,
                    .arg = .{ .push_value = 0 },
                };
                instruction_count += 1;
                pc += 1;
            },

            .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8, .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                const operation = jump_table.get_operation(opcode_byte);
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);

                const push_size = Opcode.get_push_size(opcode_byte);
                var value: u256 = 0;

                // Record PC to instruction mapping for PUSH BEFORE advancing PC
                const original_pc = pc;

                // Read push value with bounds checking
                if (pc + 1 + push_size <= code.len) {
                    var i: usize = 0;
                    while (i < push_size) : (i += 1) {
                        value = (value << 8) | code[pc + 1 + i];
                    }
                    pc += 1 + push_size;
                } else {
                    // Handle truncated PUSH at end of code
                    const available = code.len - (pc + 1);
                    if (available > 0) {
                        const bytes_to_read = @min(push_size, available);
                        var i: usize = 0;
                        while (i < bytes_to_read) : (i += 1) {
                            value = (value << 8) | code[pc + 1 + i];
                        }
                        const missing_bytes = push_size - bytes_to_read;
                        if (missing_bytes > 0) {
                            value = value << (8 * missing_bytes);
                        }
                    }
                    pc = code.len; // End of code
                }

                pc_to_instruction[original_pc] = @intCast(instruction_count);

                instructions[instruction_count] = Instruction{
                    .opcode_fn = UnreachableHandler,
                    .arg = .{ .push_value = value },
                };
                instruction_count += 1;
            },

            // Special opcodes that need individual gas tracking for dynamic calculations
            .GAS, .CALL, .CALLCODE, .DELEGATECALL, .STATICCALL, .CREATE, .CREATE2, .SSTORE => {
                const operation = jump_table.get_operation(opcode_byte);
                // Don't accumulate static gas in block - it will be handled individually
                block.updateStackTracking(opcode_byte, operation.min_stack);

                // Record PC to instruction mapping for special opcodes
                pc_to_instruction[pc] = @intCast(instruction_count);

                instructions[instruction_count] = Instruction{
                    .opcode_fn = operation.execute,
                    .arg = .{
                        .dynamic_gas = DynamicGas{
                            .static_cost = @intCast(operation.constant_gas),
                            .gas_fn = getDynamicGasFunction(opcode),
                        },
                    },
                };
                instruction_count += 1;
                pc += 1;
            },

            // Regular opcodes - accumulate in block
            else => {
                const operation = jump_table.get_operation(opcode_byte);

                // Record PC to instruction mapping for regular opcodes
                pc_to_instruction[pc] = @intCast(instruction_count);

                if (operation.undefined) {
                    // Treat undefined opcodes as INVALID
                    const invalid_operation = jump_table.get_operation(@intFromEnum(Opcode.Enum.INVALID));
                    block.gas_cost += @intCast(invalid_operation.constant_gas);
                    block.updateStackTracking(@intFromEnum(Opcode.Enum.INVALID), invalid_operation.min_stack);

                    instructions[instruction_count] = Instruction{
                        .opcode_fn = invalid_operation.execute,
                        .arg = .none,
                    };
                } else {
                    block.gas_cost += @intCast(operation.constant_gas);
                    block.updateStackTracking(opcode_byte, operation.min_stack);

                    instructions[instruction_count] = Instruction{
                        .opcode_fn = operation.execute,
                        .arg = .none, // No individual gas cost - handled by BEGINBLOCK
                    };
                }
                instruction_count += 1;
                pc += 1;
            },
        }
    }

    // Close final block
    instructions[block.begin_block_index].arg.block_info = block.close();

    // Only add implicit STOP if the last instruction is not already a terminator
    // Check if we need to add an implicit STOP
    var needs_stop = true;
    if (instruction_count > 1) {
        // Check if the previous instruction was a terminating instruction
        // We can't easily check this without tracking state, so for now just check if we ended the loop naturally
        if (pc >= code.len and code.len > 0) {
            // Check the last opcode in the bytecode
            const last_pc = code.len - 1;
            const last_opcode = code[last_pc];
            const is_terminator = switch (last_opcode) {
                0x00, // STOP
                0xF3, // RETURN
                0xFD, // REVERT
                0xFF,
                => true, // SELFDESTRUCT
                else => false,
            };
            if (is_terminator) {
                needs_stop = false;
                Log.debug("[analysis] Last opcode is terminator (0x{x}), skipping implicit STOP", .{last_opcode});
            }
        }
    }

    if (needs_stop and instruction_count < instruction_limits.MAX_INSTRUCTIONS) {
        const stop_operation = jump_table.get_operation(@intFromEnum(Opcode.Enum.STOP));
        instructions[instruction_count] = Instruction{
            .opcode_fn = stop_operation.execute,
            .arg = .none,
        };
        instruction_count += 1;
        Log.debug("[analysis] Added implicit STOP at end, total instructions: {}", .{instruction_count});
    }

    // No terminator needed for slices

    // Resolve jump targets after initial translation, passing the PC to instruction mapping
    resolveJumpTargets(code, instructions[0..instruction_count], jumpdest_bitmap, pc_to_instruction) catch {
        // If we can't resolve jumps, it's still OK - runtime will handle it
    };

    // Build pc_to_block_start mapping for runtime resolution
    var pc_to_block_start = try allocator.alloc(u16, code.len);
    errdefer allocator.free(pc_to_block_start);
    @memset(pc_to_block_start, std.math.maxInt(u16));
    // For each mapped PC, find the BEGINBLOCK for its instruction by searching backwards
    var pc_it: usize = 0;
    while (pc_it < code.len) : (pc_it += 1) {
        const inst_idx = pc_to_instruction[pc_it];
        if (inst_idx == std.math.maxInt(u16)) continue;
        var search_idx: usize = inst_idx;
        while (search_idx > 0) : (search_idx -= 1) {
            if (instructions[search_idx].arg == .block_info) {
                pc_to_block_start[pc_it] = @intCast(search_idx);
                break;
            }
        }
    }

    // Resize arrays to actual sizes
    const final_instructions = try allocator.realloc(instructions, instruction_count);
    const final_jump_types = try allocator.realloc(inst_jump_type, instruction_count);

    return CodeGenResult{
        .instructions = final_instructions,
        .pc_to_block_start = pc_to_block_start,
        .inst_jump_type = final_jump_types,
    };
}

/// Resolve jump targets in the instruction stream.
/// This creates direct pointers from JUMP/JUMPI instructions to their target BEGINBLOCK.
/// Uses the pre-built PC to instruction mapping to correctly handle injected BEGINBLOCK instructions.
fn resolveJumpTargets(code: []const u8, instructions: []Instruction, jumpdest_bitmap: *const DynamicBitSet, pc_to_instruction: []const u16) !void {
    // Find the BEGINBLOCK instruction that starts the block containing each JUMPDEST
    // We need to map from PC -> BEGINBLOCK instruction index
    var pc_to_block_start = [_]u16{std.math.maxInt(u16)} ** limits.MAX_CONTRACT_SIZE;

    // Walk through instructions to find BEGINBLOCKs and their corresponding PCs
    var current_block_start: ?u16 = null;
    for (instructions, 0..) |inst, idx| {
        if (inst.arg == .block_info) {
            // This is a BEGINBLOCK instruction
            current_block_start = @intCast(idx);
        }
    }

    // Now map each PC to its containing BEGINBLOCK by looking at pc_to_instruction
    for (pc_to_instruction, 0..) |inst_idx, pc| {
        if (inst_idx == std.math.maxInt(u16)) continue; // Skip unmapped PCs

        // Find the BEGINBLOCK for this instruction by searching backwards
        var search_idx = inst_idx;
        while (search_idx > 0) : (search_idx -= 1) {
            if (instructions[search_idx].arg == .block_info) {
                pc_to_block_start[pc] = @intCast(search_idx);
                break;
            }
        }
    }

    // Now resolve JUMP and JUMPI targets
    for (instructions, 0..) |*inst, idx| {
        // Check if this is a JUMP or JUMPI by looking for UnreachableHandler with no arg yet
        if (inst.opcode_fn == UnreachableHandler and inst.arg == .none) {
            // Look at the previous instruction for a PUSH value
            if (idx > 0 and instructions[idx - 1].arg == .push_value) {
                const target_pc = instructions[idx - 1].arg.push_value;

                // Validate the jump target is a valid JUMPDEST
                if (target_pc < code.len and jumpdest_bitmap.isSet(@intCast(target_pc))) {
                    // Find the BEGINBLOCK for this target PC
                    const block_idx = pc_to_block_start[@intCast(target_pc)];
                    if (block_idx != std.math.maxInt(u16) and block_idx < instructions.len) {
                        // Determine if this is JUMP or JUMPI by checking the original bytecode
                        // We need to find the PC for this instruction
                        var original_pc: ?usize = null;
                        for (pc_to_instruction, 0..) |mapped_idx, pc| {
                            if (mapped_idx == idx) {
                                original_pc = pc;
                                break;
                            }
                        }

                        if (original_pc) |pc| {
                            const opcode_byte = code[pc];
                            const jump_type: JumpType = if (opcode_byte == 0x56) .jump else .jumpi;
                            inst.arg = .{ .jump_target = JumpTarget{
                                .instruction = &instructions[block_idx],
                                .jump_type = jump_type,
                            } };
                        }
                    }
                }
            }
        }
    }
}

test "from_code basic functionality" {
    const allocator = std.testing.allocator;

    // Simple bytecode: PUSH1 0x01, STOP
    const code = &[_]u8{ 0x60, 0x01, 0x00 };

    const table = JumpTable.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Verify we got instructions
    try std.testing.expect(analysis.instructions[0] != null);
    try std.testing.expect(analysis.instructions[1] != null);
    try std.testing.expect(analysis.instructions[2] == null); // null terminator

}

test "from_code with jumpdest" {
    const allocator = std.testing.allocator;

    // Bytecode: JUMPDEST, PUSH1 0x01, STOP
    const code = &[_]u8{ 0x5B, 0x60, 0x01, 0x00 };

    const table = JumpTable.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Verify jumpdest is marked
    try std.testing.expect(analysis.jumpdest_bitmap.isSet(0));
    try std.testing.expect(!analysis.jumpdest_bitmap.isSet(1));
}

test "jump target resolution with BEGINBLOCK injections" {
    const allocator = std.testing.allocator;

    // Bytecode that has jumps:
    // PC 0: PUSH1 0x05 (push jump destination)
    // PC 2: JUMP (jump to PC 5)
    // PC 3: PUSH1 0x00
    // PC 5: JUMPDEST (jump destination)
    // PC 6: PUSH1 0x01
    // PC 8: STOP
    const code = &[_]u8{
        0x60, 0x05, // PUSH1 0x05
        0x56, // JUMP
        0x60, 0x00, // PUSH1 0x00
        0x5B, // JUMPDEST at PC 5
        0x60, 0x01, // PUSH1 0x01
        0x00, // STOP
    };
    const table = JumpTable.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Verify JUMPDEST is marked correctly
    try std.testing.expect(analysis.jumpdest_bitmap.isSet(5));

    // Count BEGINBLOCK instructions - should have at least 2:
    // 1. At the start
    // 2. At the JUMPDEST (PC 5)
    var begin_block_count: usize = 0;
    var jump_found = false;
    var jump_target_valid = false;

    for (analysis.instructions) |inst| {
        if (inst.opcode_fn == BeginBlockHandler) {
            begin_block_count += 1;
        }
        // Check if JUMP has been resolved to point to a valid target
        if (inst.arg == .jump_target) {
            jump_found = true;
            if (inst.arg.jump_target.jump_type == .jump) {
                // Verify the target points to a BEGINBLOCK instruction
                if (inst.arg.jump_target.instruction.opcode_fn == BeginBlockHandler) {
                    jump_target_valid = true;
                }
            }
        }
    }

    try std.testing.expect(begin_block_count >= 2);
    try std.testing.expect(jump_found);
    try std.testing.expect(jump_target_valid);
}

test "conditional jump (JUMPI) target resolution" {
    const allocator = std.testing.allocator;

    // Bytecode with conditional jump:
    // PC 0: PUSH1 0x01 (condition)
    // PC 2: PUSH1 0x06 (jump destination)
    // PC 4: JUMPI (conditional jump to PC 6)
    // PC 5: STOP (fall-through if condition is false)
    // PC 6: JUMPDEST (jump destination)
    // PC 7: PUSH1 0x42
    // PC 9: STOP
    const code = &[_]u8{
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x06, // PUSH1 0x06
        0x57, // JUMPI
        0x00, // STOP
        0x5B, // JUMPDEST at PC 6
        0x60, 0x42, // PUSH1 0x42
        0x00, // STOP
    };
    const table = JumpTable.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Verify JUMPDEST is marked correctly
    try std.testing.expect(analysis.jumpdest_bitmap.isSet(6));

    var jumpi_found = false;
    var jumpi_target_valid = false;

    for (analysis.instructions) |inst| {
        // Check if JUMPI has been resolved to point to a valid target
        if (inst.arg == .jump_target) {
            if (inst.arg.jump_target.jump_type == .jumpi) {
                jumpi_found = true;
                // Verify the target points to a BEGINBLOCK instruction
                if (inst.arg.jump_target.instruction.opcode_fn == BeginBlockHandler) {
                    jumpi_target_valid = true;
                }
            }
        }
    }

    try std.testing.expect(jumpi_found);
    try std.testing.expect(jumpi_target_valid);
}

test "invalid jump target handling" {
    const allocator = std.testing.allocator;

    // Bytecode with invalid jump (no JUMPDEST at target):
    // PC 0: PUSH1 0x05 (push invalid jump destination)
    // PC 2: JUMP (jump to PC 5 which is not a JUMPDEST)
    // PC 3: PUSH1 0x00
    // PC 5: PUSH1 0x01 (NOT a JUMPDEST)
    // PC 7: STOP
    const code = &[_]u8{
        0x60, 0x05, // PUSH1 0x05
        0x56, // JUMP
        0x60, 0x00, // PUSH1 0x00
        0x60, 0x01, // PUSH1 0x01 (at PC 5, NOT a JUMPDEST)
        0x00, // STOP
    };
    const table = JumpTable.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Verify PC 5 is NOT marked as JUMPDEST
    try std.testing.expect(!analysis.jumpdest_bitmap.isSet(5));

    // The JUMP instruction should not have a resolved target
    var unresolved_jump_found = false;

    for (analysis.instructions) |inst| {
        // UnreachableHandler with .none arg means unresolved jump
        if (inst.opcode_fn == UnreachableHandler and inst.arg == .none) {
            unresolved_jump_found = true;
        }
    }

    try std.testing.expect(unresolved_jump_found);
}
