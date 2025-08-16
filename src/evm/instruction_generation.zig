const std = @import("std");
const builtin = @import("builtin");
const Instruction = @import("instruction.zig").Instruction;
const Tag = @import("instruction.zig").Tag;
const JumpType = @import("instruction.zig").JumpType;
const isRealOpcode = @import("instruction.zig").isRealOpcode;
const opcodeToTag = @import("instruction.zig").opcodeToTag;
const WordRef = @import("instruction.zig").WordRef;
const DynamicGas = @import("instruction.zig").DynamicGas;
const BlockInfo = @import("instruction.zig").BlockInfo;
const NoopInstruction = @import("instruction.zig").NoopInstruction;
const JumpPcInstruction = @import("instruction.zig").JumpPcInstruction;
const ConditionalJumpUnresolvedInstruction = @import("instruction.zig").ConditionalJumpUnresolvedInstruction;
const ConditionalJumpInvalidInstruction = @import("instruction.zig").ConditionalJumpInvalidInstruction;
const ConditionalJumpPcInstruction = @import("instruction.zig").ConditionalJumpPcInstruction;
const PcInstruction = @import("instruction.zig").PcInstruction;
const WordInstruction = @import("instruction.zig").WordInstruction;
const BlockInstruction = @import("instruction.zig").BlockInstruction;
const Opcode = @import("opcodes/opcode.zig");
const OpcodeMetadata = @import("opcode_metadata/opcode_metadata.zig");
const DynamicBitSet = std.DynamicBitSet;
const execution = @import("execution/package.zig");
const ExecutionError = @import("execution/execution_error.zig");
const instruction_limits = @import("constants/instruction_limits.zig");
const limits = @import("constants/code_analysis_limits.zig");
const Log = @import("log.zig");

const BlockAnalysis = @import("block_analysis.zig").BlockAnalysis;
const getDynamicGasFunction = @import("dynamic_gas_mapping.zig").getDynamicGasFunction;
const Bucket2 = @import("size_buckets.zig").Bucket2;
const Bucket8 = @import("size_buckets.zig").Bucket8;
const Bucket16 = @import("size_buckets.zig").Bucket16;
const Size0Counts = @import("size_buckets.zig").Size0Counts;
const Size2Counts = @import("size_buckets.zig").Size2Counts;
const Size8Counts = @import("size_buckets.zig").Size8Counts;
const Size16Counts = @import("size_buckets.zig").Size16Counts;

/// Convert bytecode to null-terminated instruction stream with block-based optimization.
/// This implementation follows evmone's advanced analysis approach by:
/// 1. Injecting BEGINBLOCK instructions at basic block boundaries
/// 2. Pre-calculating gas and stack requirements for entire blocks
/// 3. Eliminating per-instruction validation during execution
pub const CodeGenResult = struct {
    instructions: []Instruction,
    pc_to_block_start: []u16,
    inst_jump_type: []JumpType,
    inst_to_pc: []u16,
    size2_instructions: []Bucket2,
    size8_instructions: []Bucket8,
    size16_instructions: []Bucket16,
    size0_counts: Size0Counts,
    size2_counts: Size2Counts,
    size8_counts: Size8Counts,
    size16_counts: Size16Counts,
};

const Stats = struct {
    push_add_fusions: u32 = 0,
    push_sub_fusions: u32 = 0,
    push_mul_fusions: u32 = 0,
    push_div_fusions: u32 = 0,
    keccak_optimizations: u32 = 0,
    inline_opcodes: u32 = 0,
    total_opcodes: u32 = 0,
    total_blocks: u32 = 0,
    eliminated_opcodes: u32 = 0,
    start_time: i64 = 0, // Will be set at runtime
};

pub fn codeToInstructions(allocator: std.mem.Allocator, code: []const u8, jump_table: *const OpcodeMetadata, jumpdest_bitmap: *const DynamicBitSet) !CodeGenResult {
    Log.debug("[analysis] Converting {} bytes of code to instructions", .{code.len});

    // Debug statistics for fusion rates and analysis cost
    var stats = Stats{};

    if (builtin.mode == .Debug) {
        stats.start_time = std.time.milliTimestamp();
    }

    // MEMORY ALLOCATION: Instructions array
    // Expected size: MAX_INSTRUCTIONS * sizeof(Instruction) ≈ 3-5MB max
    // Lifetime: Per analysis (cached or per-call)
    // Frequency: Once per unique contract bytecode
    // Note: MAX_INSTRUCTIONS=65536, Instruction contains fn ptr + u256 union (~48 bytes)
    const instructions = try allocator.alloc(Instruction, instruction_limits.MAX_INSTRUCTIONS + 1);
    errdefer allocator.free(instructions);

    if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        // Verify instruction allocation is within expected bounds
        const inst_size = instructions.len * @sizeOf(Instruction);
        // MAX_INSTRUCTIONS is 65536, Instruction is ~48 bytes (8 byte ptr + 32 byte u256 + padding)
        // Total: 65537 * 48 = ~3.1MB, allow up to 5MB for safety
        std.debug.assert(inst_size <= 5 * 1024 * 1024); // 5MB max
    }

    // MEMORY ALLOCATION: PC to instruction mapping (temporary)
    // Expected size: code_len * 2 bytes
    // Lifetime: During analysis only (freed immediately)
    // Frequency: Once per analysis
    const pc_to_instruction = try allocator.alloc(u16, code.len);
    defer allocator.free(pc_to_instruction);
    @memset(pc_to_instruction, std.math.maxInt(u16)); // Initialize with invalid values

    if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        // PC mapping should be proportional to code size
        const pc_map_size = pc_to_instruction.len * @sizeOf(u16);
        // Max contract size is 24KB, so mapping should be max 48KB
        std.debug.assert(pc_map_size <= 49152); // 48KB max
    }

    // MEMORY ALLOCATION: Jump type array
    // Expected size: instruction_count * 1 byte (shrunk later)
    // Lifetime: Per analysis
    // Frequency: Once per unique contract bytecode
    var inst_jump_type = try allocator.alloc(JumpType, instruction_limits.MAX_INSTRUCTIONS + 1);
    errdefer allocator.free(inst_jump_type);

    if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        // Jump type array should be MAX_INSTRUCTIONS * 1 byte
        const jump_type_size = inst_jump_type.len * @sizeOf(JumpType);
        // Should be ~65KB for max instructions
        std.debug.assert(jump_type_size <= 128 * 1024); // 128KB max (generous for enum size)
    }
    // Initialize to .other
    var t: usize = 0;
    while (t < inst_jump_type.len) : (t += 1) inst_jump_type[t] = .other;

    var pc: usize = 0;
    var instruction_count: usize = 0;

    // Builders for payload SoA
    var words_builder = std.ArrayList(WordRef).init(allocator);
    defer words_builder.deinit();
    var pcs_builder = std.ArrayList(u16).init(allocator);
    defer pcs_builder.deinit();
    var jump_pcs_builder = std.ArrayList(u16).init(allocator);
    defer jump_pcs_builder.deinit();
    var cond_jump_pcs_builder = std.ArrayList(u16).init(allocator);
    defer cond_jump_pcs_builder.deinit();
    var blocks_builder = std.ArrayList(BlockInfo).init(allocator);
    defer blocks_builder.deinit();
    var noop_count: usize = 0;
    var block_count: usize = 0;

    // Start first block with BEGINBLOCK instruction
    const begin_block_id: u16 = @intCast(blocks_builder.items.len);
    try blocks_builder.append(.{});
    instructions[instruction_count] = .{ .tag = .block_info, .id = begin_block_id };
    var block = BlockAnalysis.init(instruction_count);
    var block_payload_id = begin_block_id;
    instruction_count += 1;
    block_count += 1;
    if (builtin.mode == .Debug) stats.total_blocks += 1;

    while (pc < code.len) {
        if (instruction_count >= instruction_limits.MAX_INSTRUCTIONS) {
            return error.InstructionLimitExceeded;
        }

        const opcode_byte = code[pc];
        if (builtin.mode == .Debug) stats.total_opcodes += 1;

        // Debug logging for specific PC range
        if (pc >= 38 and pc <= 42) {
            Log.debug("[analysis] Processing byte 0x{x:0>2} at pc={}", .{ opcode_byte, pc });
        }

        const opcode = std.meta.intToEnum(Opcode.Enum, opcode_byte) catch {
            // Invalid opcode - accumulate in block and create instruction
            const operation = jump_table.get_operation(opcode_byte);
            block.gas_cost += @intCast(operation.constant_gas);
            block.updateStackTracking(opcode_byte, operation.min_stack);

            // Record PC to instruction mapping BEFORE incrementing instruction_count
            pc_to_instruction[pc] = @intCast(instruction_count);

            instructions[instruction_count] = .{ .tag = .noop, .id = @intCast(noop_count) };
            noop_count += 1;
            instruction_count += 1;
            pc += 1;
            continue;
        };

        // Handle basic block boundaries and special opcodes
        switch (opcode) {
            .JUMPDEST => {
                // Close current block and start new one
                blocks_builder.items[block_payload_id] = block.close();

                // Start new block with BEGINBLOCK
                const nbid_start: u16 = @intCast(blocks_builder.items.len);
                try blocks_builder.append(.{});
                instructions[instruction_count] = .{ .tag = .block_info, .id = nbid_start };
                block = BlockAnalysis.init(instruction_count);
                block_payload_id = nbid_start;
                instruction_count += 1;
                if (builtin.mode == .Debug) stats.total_blocks += 1;

                // Add the JUMPDEST instruction to the new block
                const operation = jump_table.get_operation(opcode_byte);
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);

                // Record PC to instruction mapping for JUMPDEST
                pc_to_instruction[pc] = @intCast(instruction_count);

                // Emit per-opcode tag for JUMPDEST
                instructions[instruction_count] = .{ .tag = opcodeToTag(@intFromEnum(Opcode.Enum.JUMPDEST)), .id = 0 };
                Log.debug("[analysis] JUMPDEST at pc={}", .{pc});
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
                    // Always emit unresolved; resolution pass will convert to pointer when possible
                    instructions[instruction_count] = .{ .tag = .jump_unresolved, .id = 0 };
                    inst_jump_type[instruction_count] = .jump;
                } else {
                    // Emit per-opcode tag for terminal instructions (STOP, RETURN, etc.)
                    instructions[instruction_count] = .{ .tag = opcodeToTag(opcode_byte), .id = 0 };
                }
                instruction_count += 1;
                pc += 1;

                // Close current block
                blocks_builder.items[block_payload_id] = block.close();

                // Conservative behavior: start a new block if any code remains.
                // Some toolchains place valid code immediately after terminators
                // that is only reached via computed jumps. We conservatively
                // continue analysis instead of skipping until a JUMPDEST.
                if (pc < code.len) {
                    const nbid_after: u16 = @intCast(blocks_builder.items.len);
                    try blocks_builder.append(.{});
                    instructions[instruction_count] = .{ .tag = .block_info, .id = nbid_after };
                    block = BlockAnalysis.init(instruction_count);
                    block_payload_id = nbid_after;
                    instruction_count += 1;
                    if (builtin.mode == .Debug) stats.total_blocks += 1;
                } else {
                    Log.debug("[analysis] No more code after terminating instruction", .{});
                    break;
                }
            },

            .JUMPI => {
                Log.debug("[analysis] JUMPI at pc={}, instruction_count={}", .{pc, instruction_count});
                const operation = jump_table.get_operation(opcode_byte);
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);

                // Record PC to instruction mapping for JUMPI
                pc_to_instruction[pc] = @intCast(instruction_count);

                // Do not emit fused pc form. Keep preceding PUSH (if any) and tag JUMPI;
                // resolveJumpTargets will convert PUSH+JUMPI into pointer form.
                instructions[instruction_count] = .{ .tag = .conditional_jump_unresolved, .id = 0 };
                inst_jump_type[instruction_count] = .jumpi;
                instruction_count += 1;
                pc += 1;

                // Close current block and start new one (for fall-through path)
                blocks_builder.items[block_payload_id] = block.close();
                const nbid_fall: u16 = @intCast(blocks_builder.items.len);
                try blocks_builder.append(.{});
                instructions[instruction_count] = .{ .tag = .block_info, .id = nbid_fall };
                block = BlockAnalysis.init(instruction_count);
                block_payload_id = nbid_fall;
                instruction_count += 1;
                if (builtin.mode == .Debug) stats.total_blocks += 1;
            },

            // PUSH operations - handled inline by interpreter
            .PUSH0 => {
                const operation = jump_table.get_operation(opcode_byte);
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);

                // Record PC to instruction mapping for PUSH0
                pc_to_instruction[pc] = @intCast(instruction_count);

                const wid0: u16 = @intCast(words_builder.items.len);
                try words_builder.append(.{ .start_pc = 0, .len = 0 });
                instructions[instruction_count] = .{ .tag = .word, .id = wid0 };
                instruction_count += 1;
                pc += 1;
            },

            .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8, .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                const operation = jump_table.get_operation(opcode_byte);
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);

                const push_size = Opcode.get_push_size(opcode_byte);
                // Record PC to instruction mapping for PUSH BEFORE advancing PC
                const original_pc = pc;

                const start = original_pc + 1;
                const end = @min(start + push_size, code.len);
                pc = end;

                pc_to_instruction[original_pc] = @intCast(instruction_count);
                const wid: u16 = @intCast(words_builder.items.len);
                try words_builder.append(.{ .start_pc = @intCast(start), .len = @intCast(end - start) });
                instructions[instruction_count] = .{ .tag = .word, .id = wid };
                Log.debug("[analysis] PUSH at pc={} size={} instruction_count={}", .{ original_pc, push_size, instruction_count });
                instruction_count += 1;
            },

            // PC opcode - needs special handling to store the PC value
            .PC => {
                const operation = jump_table.get_operation(opcode_byte);
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);

                // Record PC to instruction mapping for PC opcode
                pc_to_instruction[pc] = @intCast(instruction_count);

                const pid: u16 = @intCast(pcs_builder.items.len);
                try pcs_builder.append(@intCast(pc));
                instructions[instruction_count] = .{ .tag = .pc, .id = pid };
                Log.debug("[analysis] PC opcode at pc={}", .{pc});
                instruction_count += 1;
                pc += 1;
            },

            // Special opcodes that need individual gas tracking for dynamic calculations
            .GAS, .CALL, .CALLCODE, .DELEGATECALL, .STATICCALL, .CREATE, .CREATE2, .SSTORE => {
                // Isolate dynamic/special ops into their own blocks so that stack_req
                // validation reflects only the actual instructions present in this block.
                // This reduces the risk that previous fusion/elimination in the same block
                // makes the validator underestimate the required stack height.
                blocks_builder.items[block_payload_id] = block.close();
                const nbid_dyn: u16 = @intCast(blocks_builder.items.len);
                try blocks_builder.append(.{});
                instructions[instruction_count] = .{ .tag = .block_info, .id = nbid_dyn };
                block = BlockAnalysis.init(instruction_count);
                block_payload_id = nbid_dyn;
                instruction_count += 1;
                if (builtin.mode == .Debug) stats.total_blocks += 1;

                const operation = jump_table.get_operation(opcode_byte);
                // Accumulate static gas in block; dynamic part handled by .dynamic_gas
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);

                // Record PC to instruction mapping for special opcodes
                pc_to_instruction[pc] = @intCast(instruction_count);

                // Emit per-opcode tag for dynamic gas opcodes
                instructions[instruction_count] = .{ .tag = opcodeToTag(opcode_byte), .id = 0 };
                instruction_count += 1;
                pc += 1;

                // Close the block after the dynamic/special op to avoid combining
                // following instructions into the same validation unit.
                blocks_builder.items[block_payload_id] = block.close();
                const nbid_after_dyn: u16 = @intCast(blocks_builder.items.len);
                try blocks_builder.append(.{});
                instructions[instruction_count] = .{ .tag = .block_info, .id = nbid_after_dyn };
                block = BlockAnalysis.init(instruction_count);
                block_payload_id = nbid_after_dyn;
                instruction_count += 1;
                if (builtin.mode == .Debug) stats.total_blocks += 1;
            },

            // SHA3/KECCAK256 - for now just use regular handling
            .KECCAK256 => {
                const operation = jump_table.get_operation(opcode_byte);

                // Record PC to instruction mapping
                pc_to_instruction[pc] = @intCast(instruction_count);

                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);
                // Emit per-opcode tag for KECCAK256
                instructions[instruction_count] = .{ .tag = opcodeToTag(opcode_byte), .id = 0 };
                instruction_count += 1;
                pc += 1;
            },

            // ISZERO - use inline version for hot path
            .ISZERO => {
                const operation = jump_table.get_operation(opcode_byte);
                // synthetic helpers no longer used

                // Record PC to instruction mapping
                pc_to_instruction[pc] = @intCast(instruction_count);

                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);
                // Emit per-opcode tag for ISZERO
                instructions[instruction_count] = .{ .tag = opcodeToTag(opcode_byte), .id = 0 };
                if (builtin.mode == .Debug) stats.inline_opcodes += 1;
                Log.debug("[analysis] Using inline ISZERO at pc={}", .{pc});
                instruction_count += 1;
                pc += 1;
            },

            // EQ - use inline version for hot path
            .EQ => {
                const operation = jump_table.get_operation(opcode_byte);
                // synthetic helpers no longer used

                // Record PC to instruction mapping
                pc_to_instruction[pc] = @intCast(instruction_count);

                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);
                // Emit per-opcode tag for EQ
                instructions[instruction_count] = .{ .tag = opcodeToTag(opcode_byte), .id = 0 };
                if (builtin.mode == .Debug) stats.inline_opcodes += 1;
                Log.debug("[analysis] Using inline EQ at pc={}", .{pc});
                instruction_count += 1;
                pc += 1;
            },

            // DUP1 - check for DUP1+PUSH0+EQ pattern
            .DUP1 => {
                const operation = jump_table.get_operation(opcode_byte);

                // Look ahead for PUSH0+EQ pattern
                if (pc + 2 < code.len and code[pc + 1] == 0x5f and code[pc + 2] == 0x14) { // PUSH0, EQ
                    // This is DUP1+PUSH0+EQ = ISZERO pattern
                    // Record PC to instruction mapping
                    pc_to_instruction[pc] = @intCast(instruction_count);

                    // synthetic helpers no longer used
                    block.gas_cost += 3 + 3 + 3; // DUP1 + PUSH0 + EQ gas
                    block.updateStackTracking(0x80, 1); // DUP1 needs 1 item

                    // Emit per-opcode tag for ISZERO in fused pattern
                    instructions[instruction_count] = .{ .tag = opcodeToTag(@intFromEnum(Opcode.Enum.ISZERO)), .id = 0 };
                    instruction_count += 1;
                    pc += 3; // Skip DUP1, PUSH0, and EQ
                    if (builtin.mode == .Debug) stats.eliminated_opcodes += 2; // Saved 2 operations
                    Log.debug("[analysis] Converted DUP1+PUSH0+EQ to ISZERO at pc={}", .{pc - 3});
                    continue;
                }

                // Check for DUP+DROP pattern
                if (pc + 1 < code.len and code[pc + 1] == 0x50) { // DROP
                    // DUP1+DROP = NOP
                    pc += 2; // Skip both DUP1 and DROP
                    if (builtin.mode == .Debug) stats.eliminated_opcodes += 2;
                    Log.debug("[analysis] Eliminated DUP1+DROP at pc={}", .{pc - 2});
                    continue;
                }

                // Regular DUP1 handling
                pc_to_instruction[pc] = @intCast(instruction_count);
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);
                // Emit per-opcode tag for DUP1
                instructions[instruction_count] = .{ .tag = opcodeToTag(opcode_byte), .id = 0 };
                instruction_count += 1;
                pc += 1;
            },

            // POP - check if previous instruction was a PUSH
            .POP => {
                // Check if the previous instruction was a PUSH
                if (instruction_count > 0) {
                    const prev_instruction = instructions[instruction_count - 1];

                    // Check if it was a push by looking at the arg type
                    if (prev_instruction.tag == .word) {
                        // PUSH+POP = NOP, remove the PUSH
                        instruction_count -= 1;
                        pc += 1; // Skip POP
                        if (builtin.mode == .Debug) stats.eliminated_opcodes += 2;
                        Log.debug("[analysis] Eliminated PUSH+POP at pc={}", .{pc - 1});
                        continue;
                    }
                }

                // Regular POP handling
                const operation = jump_table.get_operation(opcode_byte);
                pc_to_instruction[pc] = @intCast(instruction_count);
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);
                // Emit per-opcode tag for POP
                instructions[instruction_count] = .{ .tag = opcodeToTag(opcode_byte), .id = 0 };
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

                    // Emit per-opcode tag for INVALID
                    instructions[instruction_count] = .{ .tag = opcodeToTag(@intFromEnum(Opcode.Enum.INVALID)), .id = 0 };
                } else {
                    block.gas_cost += @intCast(operation.constant_gas);
                    block.updateStackTracking(opcode_byte, operation.min_stack);

                    // Emit per-opcode tag for regular opcodes
                    instructions[instruction_count] = .{ .tag = opcodeToTag(opcode_byte), .id = 0 };
                }
                instruction_count += 1;
                pc += 1;
            },
        }
    }

    // Close final block
    blocks_builder.items[block_payload_id] = block.close();

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
        // Emit per-opcode tag for implicit STOP
        instructions[instruction_count] = .{ .tag = opcodeToTag(@intFromEnum(Opcode.Enum.STOP)), .id = 0 };
        instruction_count += 1;
        Log.debug("[analysis] Added implicit STOP at end, total instructions: {}", .{instruction_count});
    }

    // No explicit next_instruction pointers; fallthrough is computed in interpreter

    // Resolve fused immediate jump targets using preceding PUSH when valid
    {
        var ji: usize = 0;
        while (ji < instruction_count) : (ji += 1) {
            const jt = inst_jump_type[ji];
            switch (jt) {
                .jump => {
                    if (ji > 0 and instructions[ji - 1].tag == .word) {
                        const wr = words_builder.items[instructions[ji - 1].id];
                        var v: usize = 0;
                        var k: usize = 0;
                        const start = wr.start_pc;
                        const end = @min(start + wr.len, code.len);
                        while (k < end - start) : (k += 1) v = (v << 8) | code[start + k];
                        if (v < code.len and jumpdest_bitmap.isSet(v)) {
                            const jpid: u16 = @intCast(jump_pcs_builder.items.len);
                            try jump_pcs_builder.append(@intCast(v));
                            instructions[ji] = .{ .tag = .jump_pc, .id = jpid };
                            // neutralize preceding PUSH
                            instructions[ji - 1] = .{ .tag = .noop, .id = @intCast(noop_count) };
                            noop_count += 1;
                        }
                    }
                },
                .jumpi => {
                    if (ji > 0 and instructions[ji - 1].tag == .word) {
                        const wr2 = words_builder.items[instructions[ji - 1].id];
                        var v2: usize = 0;
                        var k2: usize = 0;
                        const start2 = wr2.start_pc;
                        const end2 = @min(start2 + wr2.len, code.len);
                        while (k2 < end2 - start2) : (k2 += 1) v2 = (v2 << 8) | code[start2 + k2];
                        
                        // Debug logging for JUMPI resolution
                        if (builtin.mode == .Debug) {
                            Log.debug("[JUMPI_RESOLVE] JUMPI at inst {}, preceded by PUSH value={}, start_pc={}, len={}", .{ ji, v2, start2, wr2.len });
                            if (v2 < code.len) {
                                Log.debug("[JUMPI_RESOLVE]   Checking jumpdest_bitmap.isSet({})={}, code[{}]=0x{x:0>2}", .{ v2, jumpdest_bitmap.isSet(v2), v2, if (v2 < code.len) code[v2] else 0xff });
                            }
                        }
                        
                        if (v2 < code.len and jumpdest_bitmap.isSet(v2)) {
                            const cid: u16 = @intCast(cond_jump_pcs_builder.items.len);
                            try cond_jump_pcs_builder.append(@intCast(v2));
                            instructions[ji] = .{ .tag = .conditional_jump_pc, .id = cid };
                            instructions[ji - 1] = .{ .tag = .noop, .id = 0 };
                            Log.debug("[JUMPI_RESOLVE]   Converted to conditional_jump_pc with target {}", .{v2});
                        } else {
                            Log.debug("[JUMPI_RESOLVE]   Keeping as conditional_jump_unresolved", .{});
                        }
                    }
                },
                else => {},
            }
        }
    }

    // No extra sentinel past-the-end when using a regular slice

    // MEMORY ALLOCATION: PC to block start mapping
    // Expected size: code_len * 2 bytes
    // Lifetime: Per analysis
    // Frequency: Once per unique contract bytecode
    var pc_to_block_start = try allocator.alloc(u16, code.len);
    errdefer allocator.free(pc_to_block_start);

    if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        // PC to block mapping should be proportional to code size
        const block_map_size = pc_to_block_start.len * @sizeOf(u16);
        // Max contract size is 24KB, so mapping should be max 48KB
        std.debug.assert(block_map_size <= 49152); // 48KB max
    }
    @memset(pc_to_block_start, std.math.maxInt(u16));
    // For each mapped PC, find the BEGINBLOCK for its instruction by searching backwards
    var pc_it: usize = 0;
    while (pc_it < code.len) : (pc_it += 1) {
        const inst_idx = pc_to_instruction[pc_it];
        if (inst_idx == std.math.maxInt(u16)) continue;
        var search_idx: usize = inst_idx;
        while (search_idx > 0) : (search_idx -= 1) {
            if (instructions[search_idx].tag == .block_info) {
                pc_to_block_start[pc_it] = @intCast(search_idx);
                break;
            }
        }
    }

    // Resize arrays to actual sizes (final instruction stream already includes STOP when needed)
    Log.debug("[analysis] Resizing arrays: instruction_count={}, inst_jump_type.len={}", .{ instruction_count, inst_jump_type.len });
    const final_instructions = try allocator.realloc(instructions, instruction_count);
    const final_jump_types = try allocator.realloc(inst_jump_type, instruction_count);
    Log.debug("[analysis] After resize: final_instructions.len={}, final_jump_types.len={}", .{ final_instructions.len, final_jump_types.len });

    // Build inst_to_pc mapping
    var inst_to_pc = try allocator.alloc(u16, instruction_count);
    errdefer allocator.free(inst_to_pc);
    @memset(inst_to_pc, std.math.maxInt(u16));
    var map_pc: usize = 0;
    while (map_pc < code.len) : (map_pc += 1) {
        const idx = pc_to_instruction[map_pc];
        if (idx != std.math.maxInt(u16) and idx < instruction_count) {
            inst_to_pc[idx] = @intCast(map_pc);
        }
    }

    // No explicit next pointers; interpreter computes fallthrough

    // Count per-tag to size buckets
    var c_noop: u24 = 0;
    var c_jump_pc: u24 = 0;
    var c_cju: u24 = 0; // conditional_jump_unresolved
    var c_cji: u24 = 0; // conditional_jump_invalid
    var c_real_opcodes: u24 = 0; // Count of real opcodes
    var c_cjp: u24 = 0; // conditional_jump_pc
    var c_pc: u24 = 0;
    var c_block: u24 = 0;
    var c_word: u24 = 0;

    for (final_instructions) |hdr| {
        switch (hdr.tag) {
            .noop => c_noop += 1,
            .jump_pc => c_jump_pc += 1,
            .conditional_jump_unresolved => c_cju += 1,
            .conditional_jump_invalid => c_cji += 1,
            .conditional_jump_pc => c_cjp += 1,
            .pc => c_pc += 1,
            .block_info => c_block += 1,
            .word => c_word += 1,
            .jump_unresolved, .conditional_jump_idx => {},
            // Real opcodes are stored as 8-byte instructions
            else => if (isRealOpcode(hdr.tag)) {
                c_real_opcodes += 1;
            } else {},
        }
    }

    // New bucket totals based on instruction sizes
    // Note: 0-byte instructions don't need storage allocation
    const total2: usize = @intCast(c_jump_pc + c_cjp + c_pc); // 2-byte instructions  
    const total8: usize = @intCast(c_real_opcodes + c_block); // 8-byte instructions
    const total16: usize = @intCast(c_word); // 16-byte instructions

    var size2_instructions = try allocator.alloc(Bucket2, total2);
    var size8_instructions = try allocator.alloc(Bucket8, total8);
    var size16_instructions = try allocator.alloc(Bucket16, total16);

    var idx0: u16 = 0; // For 0-byte instructions (tag-only)
    var idx2: u16 = 0; // For 2-byte instructions
    var idx8: u16 = 0; // For 8-byte instructions
    var idx16: u16 = 0; // For 16-byte instructions

    var it_cjp_pc: usize = 0;
    var it_jump_pc: usize = 0;
    var it_pc: usize = 0;
    var it_block: usize = 0;
    // it_word removed - we now use instruction IDs directly to index into words_builder

    for (final_instructions, 0..) |hdr, i| {
        switch (hdr.tag) {
            .noop => {
                // 0-byte instruction - no payload needed
                final_instructions[i].id = idx0;
                idx0 += 1;
            },
            .jump_pc => {
                const pc_val = jump_pcs_builder.items[it_jump_pc];
                it_jump_pc += 1;
                const jump_idx = pc_to_block_start[pc_val];
                const target_idx: u16 = if (jump_idx != std.math.maxInt(u16) and jump_idx < final_instructions.len) @intCast(jump_idx) else 0;
                Log.debug("[CODEGEN] JUMP_PC: pc_val={}, jump_idx={}", .{ pc_val, target_idx });
                const payload: JumpPcInstruction = .{ .jump_idx = target_idx };
                final_instructions[i].id = idx2;
                {
                    const bytes = std.mem.asBytes(&payload);
                    @memcpy(size2_instructions[@intCast(idx2)].bytes[0..bytes.len], bytes);
                }
                idx2 += 1;
            },
            .conditional_jump_unresolved => {
                // 0-byte instruction - no payload needed
                final_instructions[i].id = idx0;
                idx0 += 1;
            },
            .conditional_jump_invalid => {
                // 0-byte instruction - no payload needed
                final_instructions[i].id = idx0;
                idx0 += 1;
            },
            .conditional_jump_pc => {
                const pc_val = cond_jump_pcs_builder.items[it_cjp_pc];
                it_cjp_pc += 1;
                const jump_idx = pc_to_block_start[pc_val];
                const target_idx: u16 = if (jump_idx != std.math.maxInt(u16) and jump_idx < final_instructions.len) @intCast(jump_idx) else 0;
                const payload: ConditionalJumpPcInstruction = .{ .jump_idx = target_idx };
                final_instructions[i].id = idx2;
                {
                    const bytes = std.mem.asBytes(&payload);
                    @memcpy(size2_instructions[@intCast(idx2)].bytes[0..bytes.len], bytes);
                }
                idx2 += 1;
            },
            .pc => {
                const pc_value = pcs_builder.items[it_pc];
                it_pc += 1;
                const payload: PcInstruction = .{ .pc_value = @intCast(pc_value) };
                final_instructions[i].id = idx2;
                {
                    const bytes = std.mem.asBytes(&payload);
                    @memcpy(size2_instructions[@intCast(idx2)].bytes[0..bytes.len], bytes);
                }
                idx2 += 1;
            },
            .block_info => {
                const bi = blocks_builder.items[it_block];
                it_block += 1;
                const payload: BlockInstruction = .{ .gas_cost = bi.gas_cost, .stack_req = bi.stack_req, .stack_max_growth = bi.stack_max_growth };
                final_instructions[i].id = idx8;
                {
                    const bytes = std.mem.asBytes(&payload);
                    @memcpy(size8_instructions[@intCast(idx8)].bytes[0..bytes.len], bytes);
                }
                idx8 += 1;
            },
            .word => {
                // Use the instruction's ID to index into words_builder, not a sequential iterator
                const word_id = final_instructions[i].id;
                const wr = words_builder.items[word_id];
                const start = wr.start_pc;
                const end = @min(start + wr.len, code.len);
                const payload: WordInstruction = .{ .word_bytes = if (end > start) code[start..end] else &[_]u8{0} };
                final_instructions[i].id = idx16;
                {
                    const bytes = std.mem.asBytes(&payload);
                    @memcpy(size16_instructions[@intCast(idx16)].bytes[0..bytes.len], bytes);
                }
                idx16 += 1;
            },
            .jump_unresolved, .conditional_jump_idx => {},
            // Real opcodes are handled as exec instructions
            else => if (isRealOpcode(hdr.tag)) {
                // Real opcodes use the same format as exec instructions
                var exec_bytes: [8]u8 = [_]u8{0} ** 8;
                const hdr_bytes = std.mem.asBytes(&hdr);
                @memcpy(exec_bytes[0..@sizeOf(@TypeOf(hdr))], hdr_bytes);
                size8_instructions[@intCast(idx8)] = .{ .bytes = exec_bytes };
                idx8 += 1;
            } else {},
        }
    }

    // Output analysis statistics in debug builds
    if (builtin.mode == .Debug) {
        const elapsed_ms = std.time.milliTimestamp() - stats.start_time;
        const total_fusions = stats.push_add_fusions + stats.push_sub_fusions +
            stats.push_mul_fusions + stats.push_div_fusions;
        const total_optimizations = total_fusions + stats.keccak_optimizations + stats.inline_opcodes;

        Log.debug("[analysis] Code analysis complete for {} bytes in {}ms", .{ code.len, elapsed_ms });
        Log.debug("[analysis] Statistics:", .{});
        Log.debug("[analysis]   Total opcodes analyzed: {}", .{stats.total_opcodes});
        Log.debug("[analysis]   Total blocks created: {}", .{stats.total_blocks});
        Log.debug("[analysis]   Instructions generated: {}", .{instruction_count});
        Log.debug("[analysis]   Opcodes eliminated: {}", .{stats.eliminated_opcodes});
        Log.debug("[analysis] Fusion optimizations:", .{});
        Log.debug("[analysis]   PUSH+ADD fusions: {}", .{stats.push_add_fusions});
        Log.debug("[analysis]   PUSH+SUB fusions: {}", .{stats.push_sub_fusions});
        Log.debug("[analysis]   PUSH+MUL fusions: {}", .{stats.push_mul_fusions});
        Log.debug("[analysis]   PUSH+DIV fusions: {}", .{stats.push_div_fusions});
        Log.debug("[analysis]   Total arithmetic fusions: {}", .{total_fusions});
        Log.debug("[analysis] Other optimizations:", .{});
        Log.debug("[analysis]   KECCAK256 immediate size: {}", .{stats.keccak_optimizations});
        Log.debug("[analysis]   Inline opcodes (ISZERO/EQ): {}", .{stats.inline_opcodes});
        Log.debug("[analysis]   Total optimizations: {}", .{total_optimizations});

        if (stats.total_opcodes > 0) {
            const fusion_rate = (total_fusions * 100) / stats.total_opcodes;
            const optimization_rate = (total_optimizations * 100) / stats.total_opcodes;
            Log.debug("[analysis] Optimization rates:", .{});
            Log.debug("[analysis]   Arithmetic fusion rate: {}%", .{fusion_rate});
            Log.debug("[analysis]   Total optimization rate: {}%", .{optimization_rate});
        }
    }

    return CodeGenResult{
        .instructions = final_instructions,
        .pc_to_block_start = pc_to_block_start,
        .inst_jump_type = final_jump_types,
        .inst_to_pc = inst_to_pc,
        .size2_instructions = size2_instructions,
        .size8_instructions = size8_instructions,
        .size16_instructions = size16_instructions,
        .size0_counts = .{ .noop = c_noop, .conditional_jump_unresolved = c_cju, .conditional_jump_invalid = c_cji },
        .size2_counts = .{ .jump_pc = c_jump_pc, .conditional_jump_pc = c_cjp, .pc = c_pc },
        .size8_counts = .{ .real_opcodes = c_real_opcodes, .block_info = c_block },
        .size16_counts = .{ .word = c_word },
    };
}