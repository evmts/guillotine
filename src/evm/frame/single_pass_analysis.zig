const std = @import("std");
const builtin = @import("builtin");
const opcode = @import("../opcodes/opcode.zig");
const Operation = @import("../opcodes/operation.zig");
const CodeAnalysis = @import("code_analysis.zig");
const BlockInfo = CodeAnalysis.BlockInfo;
const BlockTerminator = CodeAnalysis.BlockTerminator;
const bitvec = @import("bitvec.zig");
const JumpTable = @import("../jump_table/jump_table.zig");
const Log = @import("../log.zig");
const tracy = @import("../tracy_support.zig");

/// Single-pass code analysis that builds all analysis data in one scan.
/// This approach improves cache efficiency and reduces overhead compared to multi-pass analysis.
pub fn analyzeSinglePass(
    allocator: std.mem.Allocator,
    code: []const u8,
    _: [32]u8,
    jt: ?*const JumpTable.JumpTable,
) !*CodeAnalysis {
    const zone = tracy.zone(@src(), "analyze_single_pass\x00");
    defer zone.end();
    
    const analysis = try allocator.create(CodeAnalysis);
    errdefer allocator.destroy(analysis);

    // Initialize code segments (for JUMPDEST validation)
    analysis.code_segments = try bitvec.BitVec64.codeBitmap(allocator, code);
    errdefer analysis.code_segments.deinit(allocator);

    // Pre-allocate arrays with reasonable sizes
    var jumpdests = try std.ArrayList(u32).initCapacity(allocator, code.len / 64);
    defer jumpdests.deinit();
    
    var blocks = try std.ArrayList(BlockInfo).initCapacity(allocator, code.len / 32);
    defer blocks.deinit();

    // State for current block being analyzed
    var current_block = BlockAnalysis{
        .start_pc = 0,
        .start_block_idx = 0,
    };

    // Build PC-to-operation table if jump table provided
    var pc_to_op_entries: ?[]CodeAnalysis.PcToOpEntry = null;
    if (jt != null) {
        pc_to_op_entries = try allocator.alloc(CodeAnalysis.PcToOpEntry, code.len);
        errdefer allocator.free(pc_to_op_entries.?);
    }

    // Single pass through bytecode
    var i: usize = 0;
    while (i < code.len) {
        const op = code[i];
        
        // Store operation entry if building table
        if (pc_to_op_entries) |entries| {
            if (jt) |table| {
                const operation = table.table[op];
                entries[i] = CodeAnalysis.PcToOpEntry{
                    .operation = operation,
                    .opcode_byte = op,
                    .min_stack = operation.min_stack,
                    .max_stack = operation.max_stack,
                    .constant_gas = operation.constant_gas,
                    .undefined = operation.undefined,
                };
            }
        }

        // Handle JUMPDEST opcodes
        if (op == @intFromEnum(opcode.Enum.JUMPDEST) and analysis.code_segments.isSetUnchecked(i)) {
            // If we have accumulated instructions, close current block
            if (i > current_block.start_pc) {
                // Set block terminator for previous block
                if (i > 0) {
                    current_block.terminator = .fall_through;
                }
                try blocks.append(current_block.toBlockInfo());
            }

            // Record JUMPDEST position
            try jumpdests.append(@intCast(i));

            // Start new block at JUMPDEST
            current_block = BlockAnalysis{
                .start_pc = @intCast(i),
                .start_block_idx = @intCast(blocks.items.len),
            };
        }

        // Update block analysis based on opcode
        if (jt) |table| {
            if (op < table.table.len) {
                const info = table.table[op];
                // Update stack requirements
                const stack_effect = getStackChange(op);
                current_block.stack_req = @max(
                    current_block.stack_req,
                    @as(i32, @intCast(info.min_stack)) - current_block.stack_change
                );
                current_block.stack_change += stack_effect;
                current_block.stack_max_growth = @max(
                    current_block.stack_max_growth,
                    current_block.stack_change
                );

                // Add gas cost
                current_block.gas_cost += @intCast(info.constant_gas);
            }
        }

        // Handle block terminators
        const is_terminator = switch (op) {
            @intFromEnum(opcode.Enum.JUMP),
            @intFromEnum(opcode.Enum.JUMPI),
            @intFromEnum(opcode.Enum.STOP),
            @intFromEnum(opcode.Enum.RETURN),
            @intFromEnum(opcode.Enum.REVERT),
            @intFromEnum(opcode.Enum.SELFDESTRUCT),
            @intFromEnum(opcode.Enum.INVALID),
            => true,
            else => false,
        };

        if (is_terminator) {
            current_block.end_pc = @intCast(i);
            current_block.terminator = switch (op) {
                @intFromEnum(opcode.Enum.JUMP) => .jump,
                @intFromEnum(opcode.Enum.JUMPI) => .jumpi,
                @intFromEnum(opcode.Enum.STOP) => .stop,
                @intFromEnum(opcode.Enum.RETURN) => .return_,
                @intFromEnum(opcode.Enum.REVERT) => .revert,
                @intFromEnum(opcode.Enum.SELFDESTRUCT) => .selfdestruct,
                @intFromEnum(opcode.Enum.INVALID) => .invalid,
                else => unreachable,
            };

            // Handle static jump analysis for JUMP
            if (op == @intFromEnum(opcode.Enum.JUMP) and i > 0) {
                const prev_op = if (i > 0) code[i - 1] else 0;
                if (prev_op >= @intFromEnum(opcode.Enum.PUSH1) and 
                    prev_op <= @intFromEnum(opcode.Enum.PUSH32)) {
                    const push_size = prev_op - @intFromEnum(opcode.Enum.PUSH1) + 1;
                    if (i >= push_size + 1) {
                        const push_start = i - push_size - 1;
                        const push_data = code[push_start + 1..i];
                        current_block.static_jump_target = extractJumpTarget(push_data);
                        current_block.static_jump_valid = true;
                    }
                }
            }

            try blocks.append(current_block.toBlockInfo());

            // Start new block after terminator if not at end
            if (i + 1 < code.len) {
                current_block = BlockAnalysis{
                    .start_pc = @intCast(i + 1),
                    .start_block_idx = @intCast(blocks.items.len),
                };
            }
        }

        // Advance PC based on opcode
        if (op >= @intFromEnum(opcode.Enum.PUSH1) and op <= @intFromEnum(opcode.Enum.PUSH32)) {
            const push_size = op - @intFromEnum(opcode.Enum.PUSH1) + 1;
            i += push_size;
        }
        i += 1;
    }

    // Close final block if needed
    if (current_block.start_pc < code.len and 
        (blocks.items.len == 0 or blocks.items[blocks.items.len - 1].end_pc < current_block.start_pc)) {
        current_block.end_pc = @intCast(code.len - 1);
        current_block.terminator = .fall_through;
        try blocks.append(current_block.toBlockInfo());
    }

    // Sort jumpdests for binary search
    std.mem.sort(u32, jumpdests.items, {}, comptime std.sort.asc(u32));

    // Build PC-to-block mapping
    const pc_to_block = try buildPcToBlockMapping(allocator, blocks.items, code.len);
    errdefer allocator.free(pc_to_block);

    // Detect special opcodes using SIMD if available
    analysis.has_dynamic_jumps = containsOpSimd(code, &[_]u8{ 
        @intFromEnum(opcode.Enum.JUMP), 
        @intFromEnum(opcode.Enum.JUMPI) 
    });
    analysis.has_selfdestruct = containsOpSimd(code, &[_]u8{
        @intFromEnum(opcode.Enum.SELFDESTRUCT)
    });
    analysis.has_create = containsOpSimd(code, &[_]u8{ 
        @intFromEnum(opcode.Enum.CREATE), 
        @intFromEnum(opcode.Enum.CREATE2) 
    });

    // Finalize analysis
    analysis.jumpdest_positions = try jumpdests.toOwnedSlice();
    analysis.blocks = try blocks.toOwnedSlice();
    analysis.pc_to_block = pc_to_block;
    analysis.pc_to_op_entries = pc_to_op_entries;
    analysis.max_stack_depth = 0; // TODO: Calculate during pass
    analysis.block_gas_costs = null; // TODO: Extract if needed
    analysis.has_static_jumps = false; // TODO: Track during pass

    return analysis;
}

/// Helper struct for tracking block analysis state during single pass
const BlockAnalysis = struct {
    start_pc: u32,
    end_pc: u32 = 0,
    gas_cost: u64 = 0,
    stack_req: i32 = 0,
    stack_max_growth: i32 = 0,
    stack_change: i32 = 0,
    terminator: BlockTerminator = .fall_through,
    static_jump_target: ?u32 = null,
    static_jump_valid: bool = false,
    start_block_idx: u32,

    fn toBlockInfo(self: BlockAnalysis) BlockInfo {
        return .{
            .gas_cost = @intCast(self.gas_cost),
            .stack_req = @intCast(@max(0, self.stack_req)),
            .stack_max_growth = @intCast(@max(0, self.stack_max_growth)),
            .start_pc = self.start_pc,
            .end_pc = self.end_pc,
            .terminator = self.terminator,
            .static_jump_target = self.static_jump_target,
            .static_jump_valid = self.static_jump_valid,
        };
    }
};

/// Calculate stack change for an opcode
fn getStackChange(op: u8) i32 {
    return switch (op) {
        // Stack operations
        @intFromEnum(opcode.Enum.POP) => -1,
        @intFromEnum(opcode.Enum.PUSH0)...@intFromEnum(opcode.Enum.PUSH32) => 1,
        @intFromEnum(opcode.Enum.DUP1)...@intFromEnum(opcode.Enum.DUP16) => 1,
        @intFromEnum(opcode.Enum.SWAP1)...@intFromEnum(opcode.Enum.SWAP16) => 0,
        
        // Arithmetic operations
        @intFromEnum(opcode.Enum.ADD),
        @intFromEnum(opcode.Enum.MUL),
        @intFromEnum(opcode.Enum.SUB),
        @intFromEnum(opcode.Enum.DIV),
        @intFromEnum(opcode.Enum.SDIV),
        @intFromEnum(opcode.Enum.MOD),
        @intFromEnum(opcode.Enum.SMOD),
        @intFromEnum(opcode.Enum.EXP),
        @intFromEnum(opcode.Enum.SIGNEXTEND),
        => -1,
        
        @intFromEnum(opcode.Enum.ADDMOD),
        @intFromEnum(opcode.Enum.MULMOD),
        => -2,
        
        // Comparison operations
        @intFromEnum(opcode.Enum.LT),
        @intFromEnum(opcode.Enum.GT),
        @intFromEnum(opcode.Enum.SLT),
        @intFromEnum(opcode.Enum.SGT),
        @intFromEnum(opcode.Enum.EQ),
        => -1,
        
        @intFromEnum(opcode.Enum.ISZERO),
        @intFromEnum(opcode.Enum.NOT),
        => 0,
        
        // Bitwise operations
        @intFromEnum(opcode.Enum.AND),
        @intFromEnum(opcode.Enum.OR),
        @intFromEnum(opcode.Enum.XOR),
        @intFromEnum(opcode.Enum.BYTE),
        @intFromEnum(opcode.Enum.SHL),
        @intFromEnum(opcode.Enum.SHR),
        @intFromEnum(opcode.Enum.SAR),
        => -1,
        
        // Environmental operations
        @intFromEnum(opcode.Enum.ADDRESS),
        @intFromEnum(opcode.Enum.BALANCE),
        @intFromEnum(opcode.Enum.ORIGIN),
        @intFromEnum(opcode.Enum.CALLER),
        @intFromEnum(opcode.Enum.CALLVALUE),
        @intFromEnum(opcode.Enum.CALLDATASIZE),
        @intFromEnum(opcode.Enum.CODESIZE),
        @intFromEnum(opcode.Enum.GASPRICE),
        @intFromEnum(opcode.Enum.RETURNDATASIZE),
        @intFromEnum(opcode.Enum.COINBASE),
        @intFromEnum(opcode.Enum.TIMESTAMP),
        @intFromEnum(opcode.Enum.NUMBER),
        @intFromEnum(opcode.Enum.PREVRANDAO),
        @intFromEnum(opcode.Enum.GASLIMIT),
        @intFromEnum(opcode.Enum.CHAINID),
        @intFromEnum(opcode.Enum.SELFBALANCE),
        @intFromEnum(opcode.Enum.BASEFEE),
        @intFromEnum(opcode.Enum.BLOBBASEFEE),
        @intFromEnum(opcode.Enum.PC),
        @intFromEnum(opcode.Enum.MSIZE),
        @intFromEnum(opcode.Enum.GAS),
        => 1,
        
        @intFromEnum(opcode.Enum.BLOCKHASH),
        @intFromEnum(opcode.Enum.BLOBHASH),
        @intFromEnum(opcode.Enum.CALLDATALOAD),
        @intFromEnum(opcode.Enum.EXTCODESIZE),
        @intFromEnum(opcode.Enum.EXTCODEHASH),
        @intFromEnum(opcode.Enum.MLOAD),
        @intFromEnum(opcode.Enum.SLOAD),
        => 0,
        
        // Copy operations
        @intFromEnum(opcode.Enum.CALLDATACOPY),
        @intFromEnum(opcode.Enum.CODECOPY),
        @intFromEnum(opcode.Enum.RETURNDATACOPY),
        @intFromEnum(opcode.Enum.MCOPY),
        => -3,
        
        @intFromEnum(opcode.Enum.EXTCODECOPY) => -4,
        
        // Storage operations
        @intFromEnum(opcode.Enum.MSTORE),
        @intFromEnum(opcode.Enum.MSTORE8),
        @intFromEnum(opcode.Enum.SSTORE),
        => -2,
        
        // Flow control
        @intFromEnum(opcode.Enum.JUMP) => -1,
        @intFromEnum(opcode.Enum.JUMPI) => -2,
        @intFromEnum(opcode.Enum.JUMPDEST) => 0,
        
        // System operations
        @intFromEnum(opcode.Enum.CREATE) => -2,  // value, offset, size -> address
        @intFromEnum(opcode.Enum.CREATE2) => -3, // value, offset, size, salt -> address
        @intFromEnum(opcode.Enum.CALL),
        @intFromEnum(opcode.Enum.CALLCODE),
        => -6,  // gas, to, value, in_offset, in_size, out_offset, out_size -> success
        @intFromEnum(opcode.Enum.DELEGATECALL),
        @intFromEnum(opcode.Enum.STATICCALL),
        => -5,  // gas, to, in_offset, in_size, out_offset, out_size -> success
        
        // Terminating operations
        @intFromEnum(opcode.Enum.RETURN),
        @intFromEnum(opcode.Enum.REVERT),
        => -2,
        @intFromEnum(opcode.Enum.SELFDESTRUCT) => -1,
        @intFromEnum(opcode.Enum.STOP) => 0,
        
        // KECCAK256
        @intFromEnum(opcode.Enum.KECCAK256) => -1,
        
        // LOG operations
        @intFromEnum(opcode.Enum.LOG0) => -2,
        @intFromEnum(opcode.Enum.LOG1) => -3,
        @intFromEnum(opcode.Enum.LOG2) => -4,
        @intFromEnum(opcode.Enum.LOG3) => -5,
        @intFromEnum(opcode.Enum.LOG4) => -6,
        
        else => 0,
    };
}

/// Extract jump target from push data
fn extractJumpTarget(data: []const u8) u32 {
    if (data.len > 4) return 0;
    
    var target: u32 = 0;
    for (data) |byte| {
        target = (target << 8) | byte;
    }
    return target;
}

/// Build PC-to-block index mapping
fn buildPcToBlockMapping(
    allocator: std.mem.Allocator,
    blocks: []const BlockInfo,
    code_len: usize,
) ![]u32 {
    const mapping = try allocator.alloc(u32, code_len);
    @memset(mapping, std.math.maxInt(u32));

    for (blocks, 0..) |block, idx| {
        var pc = block.start_pc;
        while (pc <= block.end_pc and pc < code_len) : (pc += 1) {
            mapping[pc] = @intCast(idx);
        }
    }

    return mapping;
}

/// SIMD-optimized search for specific opcodes
fn containsOpSimd(code: []const u8, opcodes: []const u8) bool {
    // TODO: Implement SIMD version for supported architectures
    // Fallback to simple search
    for (code) |byte| {
        for (opcodes) |op| {
            if (byte == op) return true;
        }
    }
    return false;
}