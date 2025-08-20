const std = @import("std");
const Opcode = @import("../opcodes/opcode.zig").Enum;
const opcode_mod = @import("../opcodes/opcode.zig");
const tailcalls = @import("tailcalls.zig");
const Log = @import("../log.zig");
const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");

/// Bucket IDs for different metadata sizes
pub const MetadataBucket = enum(u8) {
    none = 0, // No metadata needed
    u16_bucket = 1,
    u32_bucket = 2,
    u64_bucket = 3,
    u256_bucket = 4,
};

/// Metadata bucket index - maps instruction index to bucket ID and index within bucket
pub const BucketIndex = struct {
    bucket: MetadataBucket,
    index: u16, // Index within the specific bucket
};

/// Metadata stored in u16 bucket (2 bytes)
pub const U16Metadata = union(enum) {
    pc: u16, // PC instruction value
    dest_inst_idx: u16, // PUSH+JUMP/JUMPI destination
    static_gas_cost: u16, // JUMPDEST gas cost
    loop_limit: u16, // Loop condition limit
};

/// Metadata stored in u32 bucket (4 bytes)
pub const U32Metadata = union(enum) {
    loop_condition: packed struct {
        loop_limit: u16,
        dest_inst_idx: u16,
    },
    push_jump: packed struct {
        dest_inst_idx: u16,
        _unused: u16,
    },
    push_jumpi: packed struct {
        dest_inst_idx: u16,
        _unused: u16,
    },
};

/// Metadata stored in u64 bucket (8 bytes)
pub const U64Metadata = union(enum) {
    push_value: u64, // PUSH1-8 precomputed values
    default: u64, // Default padding for compatibility
};

/// Metadata stored in u256 bucket (32 bytes)
pub const U256Metadata = union(enum) {
    push_large_value: u256, // PUSH9-32 precomputed values
};

/// Simple analysis result for tailcall dispatch with precomputed mappings
pub const SimpleAnalysis = struct {
    /// Mapping from instruction index to PC value
    inst_to_pc: []u16,
    /// Mapping from PC to instruction index (MAX_USIZE if not an instruction start)
    pc_to_inst: []u16,
    /// Reference to the original bytecode for reading push values
    bytecode: []const u8,
    /// Block boundaries bitset - true for each instruction that starts a basic block
    block_boundaries: std.bit_set.DynamicBitSet,
    /// Jump table for opcode metadata lookup
    jump_table: *const OpcodeMetadata = &OpcodeMetadata.CANCUN,
    /// Total number of instructions
    inst_count: u16,

    // Bucketed metadata storage
    /// Maps instruction index to bucket and index within bucket
    bucket_indices: []BucketIndex,
    /// u16 metadata bucket
    u16_bucket: []U16Metadata,
    /// u32 metadata bucket
    u32_bucket: []U32Metadata,
    /// u64 metadata bucket
    u64_bucket: []U64Metadata,
    /// u256 metadata bucket
    u256_bucket: []U256Metadata,

    pub const MAX_USIZE: u16 = std.math.maxInt(u16);

    pub fn deinit(self: *SimpleAnalysis, allocator: std.mem.Allocator) void {
        allocator.free(self.inst_to_pc);
        allocator.free(self.pc_to_inst);
        self.block_boundaries.deinit();
        allocator.free(self.bucket_indices);
        allocator.free(self.u16_bucket);
        allocator.free(self.u32_bucket);
        allocator.free(self.u64_bucket);
        allocator.free(self.u256_bucket);
    }

    /// Get the PC value for a given instruction index
    pub fn getPc(self: *const SimpleAnalysis, inst_idx: u16) u16 {
        return self.inst_to_pc[inst_idx];
    }

    /// Get the instruction index for a given PC
    pub fn getInstIdx(self: *const SimpleAnalysis, pc: u16) u16 {
        return self.pc_to_inst[pc];
    }

    /// Check if an instruction starts a basic block
    pub fn isBlockStart(self: *const SimpleAnalysis, inst_idx: u16) bool {
        return self.block_boundaries.isSet(inst_idx);
    }

    /// Validate if a PC location is a valid jump destination and return instruction index
    pub fn validate_jump_dest(self: *const SimpleAnalysis, dest_pc: usize) ?u16 {
        if (dest_pc >= self.bytecode.len) return null;
        if (self.bytecode[dest_pc] != 0x5B) return null; // Must be JUMPDEST

        const dest_inst_idx = self.getInstIdx(@intCast(dest_pc));
        if (dest_inst_idx == SimpleAnalysis.MAX_USIZE) return null;

        return dest_inst_idx;
    }

    /// Check if an opcode is a block terminator
    inline fn isTerminator(opcode: u8) bool {
        return switch (opcode) {
            0x00, // STOP
            0x56, // JUMP
            0x57, // JUMPI
            0xF3, // RETURN
            0xFD, // REVERT
            0xFF, // SELFDESTRUCT
            0xFE, // INVALID
            => true,
            else => false,
        };
    }

    /// Build analysis from bytecode and return bucketed metadata separately
    pub fn analyze(allocator: std.mem.Allocator, code: []const u8) !struct { analysis: SimpleAnalysis, block_gas_costs: []u64 } {
        if (code.len > std.math.maxInt(u16)) return error.OutOfMemory; // enforce u16 bounds
        var inst_to_pc_list = std.ArrayList(u16).init(allocator);
        defer inst_to_pc_list.deinit();

        // Bucket lists for metadata storage
        var bucket_indices_list = std.ArrayList(BucketIndex).init(allocator);
        defer bucket_indices_list.deinit();
        var u16_bucket_list = std.ArrayList(U16Metadata).init(allocator);
        defer u16_bucket_list.deinit();
        var u32_bucket_list = std.ArrayList(U32Metadata).init(allocator);
        defer u32_bucket_list.deinit();
        var u64_bucket_list = std.ArrayList(U64Metadata).init(allocator);
        defer u64_bucket_list.deinit();
        var u256_bucket_list = std.ArrayList(U256Metadata).init(allocator);
        defer u256_bucket_list.deinit();

        var pc_to_inst = try allocator.alloc(u16, code.len);
        @memset(pc_to_inst, MAX_USIZE);

        // Estimate max instructions (each byte could be an instruction)
        var block_boundaries = try std.bit_set.DynamicBitSet.initEmpty(allocator, code.len);
        errdefer block_boundaries.deinit();

        var pc: u16 = 0;
        var inst_idx: u16 = 0;
        var prev_byte: u8 = 0;

        while (pc < code.len) {
            const byte = code[pc];

            // Record instruction start
            try inst_to_pc_list.append(pc);
            pc_to_inst[pc] = inst_idx;

            // Mark block boundaries
            if (inst_idx == 0) {
                // First instruction is always a block start
                block_boundaries.set(inst_idx);
            } else if (byte == 0x5B) {
                // JUMPDEST starts a new block
                block_boundaries.set(inst_idx);
            } else if (inst_idx > 0 and isTerminator(prev_byte)) {
                // Instruction after terminator starts new block
                block_boundaries.set(inst_idx);
            }

            // Build metadata for this instruction
            if (byte >= 0x60 and byte <= 0x7F) {
                // PUSH1-PUSH32
                const push_size = byte - 0x5F;

                // Store push values in appropriate buckets based on size
                if (push_size <= 8 and @as(usize, pc) + 1 + push_size <= code.len) {
                    // PUSH1-8: store in u64 bucket
                    var value: u64 = 0;
                    var i: usize = 0;
                    while (i < push_size) : (i += 1) {
                        value = (value << 8) | code[@as(usize, pc) + 1 + i];
                    }
                    const bucket_idx = @as(u16, @intCast(u64_bucket_list.items.len));
                    try u64_bucket_list.append(.{ .push_value = value });
                    try bucket_indices_list.append(.{ .bucket = .u64_bucket, .index = bucket_idx });
                } else if (push_size <= 32 and @as(usize, pc) + 1 + push_size <= code.len) {
                    // PUSH9-32: store in u256 bucket (no more PC storage!)
                    var value: u256 = 0;
                    var i: usize = 0;
                    while (i < push_size and @as(usize, pc) + 1 + i < code.len) : (i += 1) {
                        value = (value << 8) | code[@as(usize, pc) + 1 + i];
                    }
                    const bucket_idx = @as(u16, @intCast(u256_bucket_list.items.len));
                    try u256_bucket_list.append(.{ .push_large_value = value });
                    try bucket_indices_list.append(.{ .bucket = .u256_bucket, .index = bucket_idx });
                } else {
                    // Truncated push - no metadata needed
                    try bucket_indices_list.append(.{ .bucket = .none, .index = 0 });
                }

                pc += 1 + push_size;
            } else if (byte == 0x5F) {
                // PUSH0 - store 0 in u64 bucket
                const bucket_idx = @as(u16, @intCast(u64_bucket_list.items.len));
                try u64_bucket_list.append(.{ .push_value = 0 });
                try bucket_indices_list.append(.{ .bucket = .u64_bucket, .index = bucket_idx });
                pc += 1;
            } else if (byte == 0x58) {
                // PC opcode - store in u16 bucket
                const bucket_idx = @as(u16, @intCast(u16_bucket_list.items.len));
                try u16_bucket_list.append(.{ .pc = @intCast(pc) });
                try bucket_indices_list.append(.{ .bucket = .u16_bucket, .index = bucket_idx });
                pc += 1;
            } else if (byte == 0x5B) {
                // JUMPDEST - placeholder in u16 bucket, will be updated with gas costs later
                const bucket_idx = @as(u16, @intCast(u16_bucket_list.items.len));
                try u16_bucket_list.append(.{ .static_gas_cost = 0 });
                try bucket_indices_list.append(.{ .bucket = .u16_bucket, .index = bucket_idx });
                pc += 1;
            } else {
                // Other opcodes - no metadata needed
                try bucket_indices_list.append(.{ .bucket = .none, .index = 0 });
                pc += 1;
            }

            prev_byte = byte;
            inst_idx += 1;
        }

        // Resize block_boundaries to actual instruction count
        var final_block_boundaries = try std.bit_set.DynamicBitSet.initEmpty(allocator, inst_idx);
        errdefer final_block_boundaries.deinit();

        // Copy over the block boundary information
        var i: u16 = 0;
        while (i < inst_idx) : (i += 1) {
            if (block_boundaries.isSet(i)) {
                final_block_boundaries.set(i);
            }
        }

        block_boundaries.deinit();

        // Calculate static gas costs for each basic block
        const block_gas_costs = try allocator.alloc(u64, inst_idx);
        const analysis = SimpleAnalysis{
            .inst_to_pc = try inst_to_pc_list.toOwnedSlice(),
            .pc_to_inst = pc_to_inst,
            .bytecode = code,
            .inst_count = inst_idx,
            .block_boundaries = final_block_boundaries,
            .bucket_indices = try bucket_indices_list.toOwnedSlice(),
            .u16_bucket = try u16_bucket_list.toOwnedSlice(),
            .u32_bucket = try u32_bucket_list.toOwnedSlice(),
            .u64_bucket = try u64_bucket_list.toOwnedSlice(),
            .u256_bucket = try u256_bucket_list.toOwnedSlice(),
        };

        // Calculate gas costs for each basic block
        try calculateBlockGasCosts(code, &analysis, block_gas_costs);

        // Update JUMPDEST metadata with calculated gas costs
        var inst_idx_update: u16 = 0;
        while (inst_idx_update < analysis.inst_count) : (inst_idx_update += 1) {
            const inst_pc = analysis.getPc(inst_idx_update);
            if (inst_pc < code.len and code[inst_pc] == 0x5B) { // JUMPDEST
                const bucket_info = analysis.bucket_indices[inst_idx_update];
                if (bucket_info.bucket == .u16_bucket) {
                    const gas_cost = block_gas_costs[inst_idx_update];
                    if (gas_cost <= std.math.maxInt(u16)) {
                        // Update the gas cost directly in the u16 bucket
                        analysis.u16_bucket[bucket_info.index] = .{ .static_gas_cost = @intCast(gas_cost) };
                    }
                }
            }
        }

        return .{
            .analysis = analysis,
            .block_gas_costs = block_gas_costs,
        };
    }
};

/// Calculate static gas costs for each basic block
fn calculateBlockGasCosts(code: []const u8, analysis: *const SimpleAnalysis, block_gas_costs: []u64) !void {
    const opcode_metadata = &OpcodeMetadata.CANCUN;

    // Initialize all block costs to 0
    @memset(block_gas_costs, 0);

    var current_block_start: u16 = 0;
    var current_block_cost: u64 = 0;

    var inst_idx: u16 = 0;
    while (inst_idx < analysis.inst_count) : (inst_idx += 1) {
        const pc = analysis.getPc(inst_idx);
        if (pc >= code.len) break;

        const opcode = code[pc];
        const operation = opcode_metadata.get_operation(opcode);

        // Add this instruction's static gas cost to current block
        current_block_cost += operation.constant_gas;

        // Check if next instruction starts a new block
        const is_next_block_start = (inst_idx + 1 < analysis.inst_count) and
            analysis.isBlockStart(inst_idx + 1);

        // Check if this is a terminating instruction (ends current block)
        const is_terminator = SimpleAnalysis.isTerminator(opcode);

        // If we're at the end of a block, store the accumulated cost
        if (is_next_block_start or is_terminator or inst_idx == analysis.inst_count - 1) {
            // Store cost for all JUMPDEST instructions in this block
            var block_inst = current_block_start;
            while (block_inst <= inst_idx) : (block_inst += 1) {
                const block_pc = analysis.getPc(block_inst);
                if (block_pc < code.len and code[block_pc] == 0x5B) { // JUMPDEST
                    block_gas_costs[block_inst] = current_block_cost;
                }
            }

            // Reset for next block
            if (is_next_block_start) {
                current_block_start = inst_idx + 1;
                current_block_cost = 0;
            }
        }
    }
}

/// Build the tailcall ops array and return together with analysis and metadata
/// This encapsulates opcode decoding and fusion logic for PUSH+X patterns
pub fn prepare(allocator: std.mem.Allocator, code: []const u8) !struct {
    analysis: SimpleAnalysis,
    ops: []*const fn (*@import("../stack_frame.zig").StackFrame) @import("../execution/execution_error.zig").Error!noreturn,
    block_gas_costs: []u64,
} {
    if (code.len > std.math.maxInt(u16)) return error.OutOfMemory;

    // Phase 1: basic analysis + bucketed metadata
    const res = try SimpleAnalysis.analyze(allocator, code);
    var analysis = res.analysis;
    const block_gas_costs = res.block_gas_costs;

    // Phase 1.5: decode to ops array
    const TailcallFunc = *const fn (*@import("../stack_frame.zig").StackFrame) @import("../execution/execution_error.zig").Error!noreturn;
    var ops_list = std.ArrayList(TailcallFunc).init(allocator);
    errdefer ops_list.deinit();

    var pc: usize = 0;
    while (pc < code.len) {
        const byte = code[pc];

        if (opcode_mod.is_push(byte)) {
            const push_size = opcode_mod.get_push_size(byte);
            try ops_list.append(&tailcalls.op_push);
            pc += 1 + push_size;
            continue;
        }

        if (!opcode_mod.is_valid_opcode(byte)) {
            // Solidity metadata markers 0xa1/0xa2 followed by 0x65
            if ((byte == 0xa1 or byte == 0xa2) and pc + 1 < code.len and code[pc + 1] == 0x65) {
                break;
            }
            try ops_list.append(&tailcalls.op_invalid);
            pc += 1;
            continue;
        }

        const opcode = @as(Opcode, @enumFromInt(byte));

        // TODO: Replace this giant switch statement with jump table lookup
        // Replace this switch with: analysis.jump_table.get_tailcall_func(byte)
        const fn_ptr: TailcallFunc = switch (opcode) {
            .STOP => &tailcalls.op_stop,
            .ADD => &tailcalls.op_add,
            .MUL => &tailcalls.op_mul,
            .SUB => &tailcalls.op_sub,
            .DIV => &tailcalls.op_div,
            .SDIV => &tailcalls.op_sdiv,
            .MOD => &tailcalls.op_mod,
            .SMOD => &tailcalls.op_smod,
            .ADDMOD => &tailcalls.op_addmod,
            .MULMOD => &tailcalls.op_mulmod,
            .EXP => &tailcalls.op_exp,
            .SIGNEXTEND => &tailcalls.op_signextend,
            .LT => &tailcalls.op_lt,
            .GT => &tailcalls.op_gt,
            .SLT => &tailcalls.op_slt,
            .SGT => &tailcalls.op_sgt,
            .EQ => &tailcalls.op_eq,
            .ISZERO => &tailcalls.op_iszero,
            .AND => &tailcalls.op_and,
            .OR => &tailcalls.op_or,
            .XOR => &tailcalls.op_xor,
            .NOT => &tailcalls.op_not,
            .BYTE => &tailcalls.op_byte,
            .SHL => &tailcalls.op_shl,
            .SHR => &tailcalls.op_shr,
            .SAR => &tailcalls.op_sar,
            .KECCAK256 => &tailcalls.op_keccak256,
            .ADDRESS => &tailcalls.op_address,
            .BALANCE => &tailcalls.op_balance,
            .ORIGIN => &tailcalls.op_origin,
            .CALLER => &tailcalls.op_caller,
            .CALLVALUE => &tailcalls.op_callvalue,
            .CALLDATALOAD => &tailcalls.op_calldataload,
            .CALLDATASIZE => &tailcalls.op_calldatasize,
            .CALLDATACOPY => &tailcalls.op_calldatacopy,
            .CODESIZE => &tailcalls.op_codesize,
            .CODECOPY => &tailcalls.op_codecopy,
            .GASPRICE => &tailcalls.op_gasprice,
            .EXTCODESIZE => &tailcalls.op_extcodesize,
            .EXTCODECOPY => &tailcalls.op_extcodecopy,
            .RETURNDATASIZE => &tailcalls.op_returndatasize,
            .RETURNDATACOPY => &tailcalls.op_returndatacopy,
            .EXTCODEHASH => &tailcalls.op_extcodehash,
            .BLOCKHASH => &tailcalls.op_blockhash,
            .COINBASE => &tailcalls.op_coinbase,
            .TIMESTAMP => &tailcalls.op_timestamp,
            .NUMBER => &tailcalls.op_number,
            .PREVRANDAO => &tailcalls.op_difficulty,
            .GASLIMIT => &tailcalls.op_gaslimit,
            .CHAINID => &tailcalls.op_chainid,
            .SELFBALANCE => &tailcalls.op_selfbalance,
            .BASEFEE => &tailcalls.op_basefee,
            .BLOBHASH => &tailcalls.op_blobhash,
            .BLOBBASEFEE => &tailcalls.op_blobbasefee,
            .POP => &tailcalls.op_pop,
            .MLOAD => &tailcalls.op_mload,
            .MSTORE => &tailcalls.op_mstore,
            .MSTORE8 => &tailcalls.op_mstore8,
            .SLOAD => &tailcalls.op_sload,
            .SSTORE => &tailcalls.op_sstore,
            .JUMP => &tailcalls.op_jump,
            .JUMPI => &tailcalls.op_jumpi,
            .PC => &tailcalls.op_pc,
            .MSIZE => &tailcalls.op_msize,
            .GAS => &tailcalls.op_gas,
            .JUMPDEST => &tailcalls.op_jumpdest,
            .TLOAD => &tailcalls.op_tload,
            .TSTORE => &tailcalls.op_tstore,
            .MCOPY => &tailcalls.op_mcopy,
            .PUSH0 => &tailcalls.op_push0,
            .DUP1 => &tailcalls.op_dup1,
            .DUP2 => &tailcalls.op_dup2,
            .DUP3 => &tailcalls.op_dup3,
            .DUP4 => &tailcalls.op_dup4,
            .DUP5 => &tailcalls.op_dup5,
            .DUP6 => &tailcalls.op_dup6,
            .DUP7 => &tailcalls.op_dup7,
            .DUP8 => &tailcalls.op_dup8,
            .DUP9 => &tailcalls.op_dup9,
            .DUP10 => &tailcalls.op_dup10,
            .DUP11 => &tailcalls.op_dup11,
            .DUP12 => &tailcalls.op_dup12,
            .DUP13 => &tailcalls.op_dup13,
            .DUP14 => &tailcalls.op_dup14,
            .DUP15 => &tailcalls.op_dup15,
            .DUP16 => &tailcalls.op_dup16,
            .SWAP1 => &tailcalls.op_swap1,
            .SWAP2 => &tailcalls.op_swap2,
            .SWAP3 => &tailcalls.op_swap3,
            .SWAP4 => &tailcalls.op_swap4,
            .SWAP5 => &tailcalls.op_swap5,
            .SWAP6 => &tailcalls.op_swap6,
            .SWAP7 => &tailcalls.op_swap7,
            .SWAP8 => &tailcalls.op_swap8,
            .SWAP9 => &tailcalls.op_swap9,
            .SWAP10 => &tailcalls.op_swap10,
            .SWAP11 => &tailcalls.op_swap11,
            .SWAP12 => &tailcalls.op_swap12,
            .SWAP13 => &tailcalls.op_swap13,
            .SWAP14 => &tailcalls.op_swap14,
            .SWAP15 => &tailcalls.op_swap15,
            .SWAP16 => &tailcalls.op_swap16,
            .LOG0 => &tailcalls.op_log0,
            .LOG1 => &tailcalls.op_log1,
            .LOG2 => &tailcalls.op_log2,
            .LOG3 => &tailcalls.op_log3,
            .LOG4 => &tailcalls.op_log4,
            .CREATE => &tailcalls.op_create,
            .CALL => &tailcalls.op_call,
            .CALLCODE => &tailcalls.op_callcode,
            .RETURN => &tailcalls.op_return,
            .DELEGATECALL => &tailcalls.op_delegatecall,
            .CREATE2 => &tailcalls.op_create2,
            .STATICCALL => &tailcalls.op_staticcall,
            .REVERT => &tailcalls.op_revert,
            .INVALID => &tailcalls.op_invalid,
            .SELFDESTRUCT => &tailcalls.op_selfdestruct,
            else => &tailcalls.op_invalid,
        };

        try ops_list.append(fn_ptr);
        pc += 1;
    }

    // Always append STOP at the end for proper termination
    try ops_list.append(&tailcalls.op_stop);

    var ops_slice = try ops_list.toOwnedSlice();

    // Create mutable bucket lists for fusion phase
    var u16_bucket_list = std.ArrayList(U16Metadata).fromOwnedSlice(allocator, analysis.u16_bucket);
    defer analysis.u16_bucket = u16_bucket_list.toOwnedSlice() catch analysis.u16_bucket;
    var u32_bucket_list = std.ArrayList(U32Metadata).fromOwnedSlice(allocator, analysis.u32_bucket);
    defer analysis.u32_bucket = u32_bucket_list.toOwnedSlice() catch analysis.u32_bucket;
    var bucket_indices_list = std.ArrayList(BucketIndex).fromOwnedSlice(allocator, analysis.bucket_indices);
    defer analysis.bucket_indices = bucket_indices_list.toOwnedSlice() catch analysis.bucket_indices;

    // Phase 2: fusion pass
    if (ops_slice.len > 1) {
        // Precompute typed pointers for comparisons
        const OP_PUSH: TailcallFunc = &tailcalls.op_push;
        const OP_JUMP: TailcallFunc = &tailcalls.op_jump;
        const OP_JUMPI: TailcallFunc = &tailcalls.op_jumpi;
        const OP_MLOAD: TailcallFunc = &tailcalls.op_mload;
        const OP_MSTORE: TailcallFunc = &tailcalls.op_mstore;
        const OP_EQ: TailcallFunc = &tailcalls.op_eq;
        const OP_LT: TailcallFunc = &tailcalls.op_lt;
        const OP_GT: TailcallFunc = &tailcalls.op_gt;
        const OP_AND: TailcallFunc = &tailcalls.op_and;
        const OP_ADD: TailcallFunc = &tailcalls.op_add;
        const OP_SUB: TailcallFunc = &tailcalls.op_sub;
        const OP_MUL: TailcallFunc = &tailcalls.op_mul;
        const OP_DIV: TailcallFunc = &tailcalls.op_div;
        const OP_SLOAD: TailcallFunc = &tailcalls.op_sload;
        const OP_DUP1: TailcallFunc = &tailcalls.op_dup1;
        const OP_SWAP1: TailcallFunc = &tailcalls.op_swap1;

        // First pass: Check for 5-instruction loop patterns (DUP1, PUSH, LT, PUSH, JUMPI)
        var i: usize = 0;
        while (i + 4 < ops_slice.len) : (i += 1) {
            // Check for DUP1, PUSH, LT, PUSH, JUMPI pattern
            if (ops_slice[i] == OP_DUP1 and
                ops_slice[i + 1] == OP_PUSH and
                ops_slice[i + 2] == OP_LT and
                ops_slice[i + 3] == OP_PUSH and
                ops_slice[i + 4] == OP_JUMPI)
            {
                // First, extract and validate the loop limit from the first PUSH (i+1)
                const limit_push_pc = analysis.getPc(@intCast(i + 1));
                if (limit_push_pc != SimpleAnalysis.MAX_USIZE and limit_push_pc < code.len) {
                    const limit_opcode = code[limit_push_pc];
                    if (limit_opcode >= 0x60 and limit_opcode <= 0x7F) {
                        const limit_push_size = limit_opcode - 0x5F;
                        const limit_value_start = limit_push_pc + 1;

                        // Read the loop limit value
                        var loop_limit_val: u64 = 0;
                        var k: usize = 0;
                        while (k < limit_push_size and limit_value_start + k < code.len) : (k += 1) {
                            loop_limit_val = (loop_limit_val << 8) | code[limit_value_start + k];
                        }

                        // Only proceed with fusion if loop limit fits in u16
                        if (loop_limit_val <= std.math.maxInt(u16)) {
                            // Now validate the second PUSH has a valid JUMPDEST
                            const push_inst_pc = analysis.getPc(@intCast(i + 3));
                            if (push_inst_pc != SimpleAnalysis.MAX_USIZE and push_inst_pc < code.len) {
                                const push_opcode = code[push_inst_pc];
                                if (push_opcode >= 0x60 and push_opcode <= 0x7F) {
                                    const push_size = push_opcode - 0x5F;
                                    const value_start = push_inst_pc + 1;

                                    // Read the jump destination
                                    var dest_val: usize = 0;
                                    var j: usize = 0;
                                    while (j < push_size and value_start + j < code.len) : (j += 1) {
                                        dest_val = (dest_val << 8) | code[value_start + j];
                                    }

                                    // Validate it's a valid JUMPDEST using reusable method
                                    if (analysis.validate_jump_dest(dest_val)) |dest_inst_idx| {
                                        // Store loop condition metadata in u32 bucket
                                        const bucket_idx = @as(u16, @intCast(u32_bucket_list.items.len));
                                        try u32_bucket_list.append(.{ .loop_condition = .{
                                            .loop_limit = @intCast(loop_limit_val),
                                            .dest_inst_idx = dest_inst_idx,
                                        } });

                                        // Update bucket index for the fused instruction
                                        bucket_indices_list.items[i] = .{ .bucket = .u32_bucket, .index = bucket_idx };

                                        // Replace the 5-instruction sequence with loop fusion
                                        ops_slice[i] = &tailcalls.op_loop_condition;
                                        ops_slice[i + 1] = &tailcalls.op_nop;
                                        ops_slice[i + 2] = &tailcalls.op_nop;
                                        ops_slice[i + 3] = &tailcalls.op_nop;
                                        ops_slice[i + 4] = &tailcalls.op_nop;

                                        // Skip the fused instructions
                                        i += 4;
                                        continue;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Second pass: Existing PUSH-based fusion patterns
        i = 0;
        while (i < ops_slice.len - 1) : (i += 1) {
            const is_push = ops_slice[i] == OP_PUSH;
            if (!is_push) continue;

            const inst_pc_u16 = analysis.getPc(@intCast(i));
            if (inst_pc_u16 == SimpleAnalysis.MAX_USIZE) continue;
            const inst_pc: usize = inst_pc_u16;
            if (inst_pc >= code.len) continue;

            const opbyte = code[inst_pc];
            if (opbyte < 0x60 or opbyte > 0x7F) continue;

            const next_op = ops_slice[i + 1];
            const push_size: usize = opbyte - 0x5F;

            var fused: ?TailcallFunc = null;

            // JUMP / JUMPI validation
            if (next_op == OP_JUMP or next_op == OP_JUMPI) {
                const value_start = inst_pc + 1;
                var val: usize = 0;
                var j: usize = 0;
                while (j < push_size and value_start + j < code.len) : (j += 1) {
                    val = (val << 8) | code[value_start + j];
                }

                if (analysis.validate_jump_dest(val)) |dest_inst_idx| {
                    // Store destination instruction index in u32 bucket for both JUMP and JUMPI
                    const bucket_idx = @as(u16, @intCast(u32_bucket_list.items.len));
                    if (next_op == OP_JUMP) {
                        try u32_bucket_list.append(.{ .push_jump = .{ .dest_inst_idx = dest_inst_idx, ._unused = 0 } });
                        bucket_indices_list.items[i] = .{ .bucket = .u32_bucket, .index = bucket_idx };
                        fused = &tailcalls.op_push_then_jump;
                    } else {
                        try u32_bucket_list.append(.{ .push_jumpi = .{ .dest_inst_idx = dest_inst_idx, ._unused = 0 } });
                        bucket_indices_list.items[i] = .{ .bucket = .u32_bucket, .index = bucket_idx };
                        fused = &tailcalls.op_push_then_jumpi;
                    }
                }
            }

            // Check if this is a small push (PUSH1-4) that has value stored in metadata
            const is_small_push = push_size <= 4 and @as(usize, inst_pc) + 1 + push_size <= code.len;

            if (fused == null and next_op == OP_MLOAD) {
                fused = if (is_small_push) &tailcalls.op_push_then_mload_small else &tailcalls.op_push_then_mload;
            }
            if (fused == null and next_op == OP_MSTORE) {
                fused = if (is_small_push) &tailcalls.op_push_then_mstore_small else &tailcalls.op_push_then_mstore;
            }
            if (fused == null and next_op == OP_EQ) {
                fused = if (is_small_push) &tailcalls.op_push_then_eq_small else &tailcalls.op_push_then_eq;
            }
            if (fused == null and next_op == OP_LT) {
                fused = if (is_small_push) &tailcalls.op_push_then_lt_small else &tailcalls.op_push_then_lt;
            }
            if (fused == null and next_op == OP_GT) {
                fused = if (is_small_push) &tailcalls.op_push_then_gt_small else &tailcalls.op_push_then_gt;
            }
            if (fused == null and next_op == OP_AND) {
                fused = if (is_small_push) &tailcalls.op_push_then_and_small else &tailcalls.op_push_then_and;
            }
            if (fused == null and next_op == OP_ADD) {
                fused = if (is_small_push) &tailcalls.op_push_then_add_small else &tailcalls.op_push_then_add;
            }
            if (fused == null and next_op == OP_SUB) {
                fused = if (is_small_push) &tailcalls.op_push_then_sub_small else &tailcalls.op_push_then_sub;
            }
            if (fused == null and next_op == OP_MUL) {
                fused = if (is_small_push) &tailcalls.op_push_then_mul_small else &tailcalls.op_push_then_mul;
            }
            if (fused == null and next_op == OP_DIV) {
                fused = if (is_small_push) &tailcalls.op_push_then_div_small else &tailcalls.op_push_then_div;
            }
            if (fused == null and next_op == OP_SLOAD) {
                fused = if (is_small_push) &tailcalls.op_push_then_sload_small else &tailcalls.op_push_then_sload;
            }
            if (fused == null and next_op == OP_DUP1) {
                fused = if (is_small_push) &tailcalls.op_push_then_dup1_small else &tailcalls.op_push_then_dup1;
            }
            if (fused == null and next_op == OP_SWAP1) {
                fused = if (is_small_push) &tailcalls.op_push_then_swap1_small else &tailcalls.op_push_then_swap1;
            }

            if (fused == null) continue;

            ops_slice[i] = fused.?;
            ops_slice[i + 1] = &tailcalls.op_nop;
            i += 1;
        }
    }

    return .{ .analysis = analysis, .ops = ops_slice, .block_gas_costs = block_gas_costs };
}

test "analysis2: PUSH small value bounds check and metadata" {
    const allocator = std.testing.allocator;
    // PUSH1 0xAA; STOP
    const code = &[_]u8{ 0x60, 0xAA, 0x00 };
    var result = try SimpleAnalysis.analyze(allocator, code);
    defer result.analysis.deinit(allocator);
    defer allocator.free(result.block_gas_costs);
    try std.testing.expectEqual(@as(u16, 0), result.analysis.getInstIdx(0));
    try std.testing.expectEqual(@as(u16, SimpleAnalysis.MAX_USIZE), result.analysis.getInstIdx(1)); // PC 1 is push data, not instruction
    try std.testing.expectEqual(@as(u16, 1), result.analysis.getInstIdx(2));

    // First instruction is PUSH1: should be in u64 bucket with value 0xAA
    const bucket_info = result.analysis.bucket_indices[0];
    try std.testing.expectEqual(MetadataBucket.u64_bucket, bucket_info.bucket);
    try std.testing.expectEqual(U64Metadata{ .push_value = 0xAA }, result.analysis.u64_bucket[bucket_info.index]);
}

test "analysis2: PUSH0 metadata and length" {
    const allocator = std.testing.allocator;
    // PUSH0; STOP
    const code = &[_]u8{ 0x5F, 0x00 };
    var result = try SimpleAnalysis.analyze(allocator, code);
    defer result.analysis.deinit(allocator);
    defer allocator.free(result.block_gas_costs);
    // Two instructions
    try std.testing.expectEqual(@as(u16, 2), result.analysis.inst_count);

    // First is PUSH0 -> should be in u64 bucket with value 0
    const bucket_info = result.analysis.bucket_indices[0];
    try std.testing.expectEqual(MetadataBucket.u64_bucket, bucket_info.bucket);
    try std.testing.expectEqual(U64Metadata{ .push_value = 0 }, result.analysis.u64_bucket[bucket_info.index]);
}

test "analysis2: PUSH1-4 metadata fast path optimization" {
    const allocator = std.testing.allocator;
    // PUSH1 0xAA, PUSH2 0x1234, PUSH3 0xABCDEF, PUSH4 0x11223344, STOP
    const code = &[_]u8{
        0x60, 0xAA, // PUSH1 0xAA
        0x61, 0x12, 0x34, // PUSH2 0x1234
        0x62, 0xAB, 0xCD, 0xEF, // PUSH3 0xABCDEF
        0x63, 0x11, 0x22, 0x33, 0x44, // PUSH4 0x11223344
        0x00, // STOP
    };

    var result = try SimpleAnalysis.analyze(allocator, code);
    defer result.analysis.deinit(allocator);
    defer allocator.free(result.block_gas_costs);

    // Verify all PUSH1-4 values are stored in u64 bucket
    const bucket_info_0 = result.analysis.bucket_indices[0];
    try std.testing.expectEqual(MetadataBucket.u64_bucket, bucket_info_0.bucket);
    try std.testing.expectEqual(U64Metadata{ .push_value = 0xAA }, result.analysis.u64_bucket[bucket_info_0.index]);

    const bucket_info_1 = result.analysis.bucket_indices[1];
    try std.testing.expectEqual(MetadataBucket.u64_bucket, bucket_info_1.bucket);
    try std.testing.expectEqual(U64Metadata{ .push_value = 0x1234 }, result.analysis.u64_bucket[bucket_info_1.index]);

    const bucket_info_2 = result.analysis.bucket_indices[2];
    try std.testing.expectEqual(MetadataBucket.u64_bucket, bucket_info_2.bucket);
    try std.testing.expectEqual(U64Metadata{ .push_value = 0xABCDEF }, result.analysis.u64_bucket[bucket_info_2.index]);

    const bucket_info_3 = result.analysis.bucket_indices[3];
    try std.testing.expectEqual(MetadataBucket.u64_bucket, bucket_info_3.bucket);
    try std.testing.expectEqual(U64Metadata{ .push_value = 0x11223344 }, result.analysis.u64_bucket[bucket_info_3.index]);

    // STOP should have no metadata
    const bucket_info_4 = result.analysis.bucket_indices[4];
    try std.testing.expectEqual(MetadataBucket.none, bucket_info_4.bucket);
}

test "analysis2: loop fusion pattern detection" {
    const allocator = std.testing.allocator;
    // Create a simple loop pattern: DUP1, PUSH1 10, LT, PUSH1 dest, JUMPI, JUMPDEST
    // PC layout: DUP1@0, PUSH1@1-2, LT@3, PUSH1@4-5, JUMPI@6, JUMPDEST@7, STOP@8
    const code = &[_]u8{
        0x80, // DUP1 (instruction 0, PC 0)
        0x60, 0x0A, // PUSH1 10 (instruction 1, PC 1-2)
        0x10, // LT (instruction 2, PC 3)
        0x60, 0x07, // PUSH1 7 (jump to PC 7 where JUMPDEST is, instruction 3, PC 4-5)
        0x57, // JUMPI (instruction 4, PC 6)
        0x5B, // JUMPDEST (instruction 5, PC 7)
        0x00, // STOP (instruction 6, PC 8)
    };

    var prep_result = try prepare(allocator, code);
    defer prep_result.analysis.deinit(allocator);
    defer allocator.free(prep_result.ops);
    defer allocator.free(prep_result.block_gas_costs);

    // Verify loop fusion was applied
    try std.testing.expect(prep_result.ops[0] == @as(*const anyopaque, &tailcalls.op_loop_condition));
    try std.testing.expect(prep_result.ops[1] == @as(*const anyopaque, &tailcalls.op_nop));
    try std.testing.expect(prep_result.ops[2] == @as(*const anyopaque, &tailcalls.op_nop));
    try std.testing.expect(prep_result.ops[3] == @as(*const anyopaque, &tailcalls.op_nop));
    try std.testing.expect(prep_result.ops[4] == @as(*const anyopaque, &tailcalls.op_nop));

    // Verify metadata contains the loop condition in u32 bucket for the fused instruction
    const bucket_info = prep_result.analysis.bucket_indices[0];
    try std.testing.expectEqual(MetadataBucket.u32_bucket, bucket_info.bucket);
    const loop_metadata = prep_result.analysis.u32_bucket[bucket_info.index];
    try std.testing.expectEqual(U32Metadata{ .loop_condition = .{ .loop_limit = 10, .dest_inst_idx = 5 } }, loop_metadata);
}

test "analysis2: block boundary detection basic" {
    const allocator = std.testing.allocator;

    // Simple bytecode: PUSH1 0, JUMPDEST, STOP, PUSH1 1, STOP
    // Block boundaries should be at: 0 (start, 1 (JUMPDEST, 3 (after STOP)
    const code = &[_]u8{
        0x60, 0x00, // PUSH1 0 (instruction 0)
        0x5B, // JUMPDEST (instruction 1) - block boundary
        0x00, // STOP (instruction 2) - terminator
        0x60, 0x01, // PUSH1 1 (instruction 3) - should be block boundary after STOP
        0x00, // STOP (instruction 4)
    };

    var result = try SimpleAnalysis.analyze(allocator, code);
    defer result.analysis.deinit(allocator);
    defer allocator.free(result.block_gas_costs);

    // Check that block boundaries are correctly identified
    try std.testing.expect(result.analysis.isBlockStart(0)); // First instruction
    try std.testing.expect(result.analysis.isBlockStart(1)); // JUMPDEST
    try std.testing.expect(result.analysis.isBlockStart(3)); // After STOP

    // Non-block boundaries
    try std.testing.expect(!result.analysis.isBlockStart(2)); // STOP itself is not a block start
    try std.testing.expect(!result.analysis.isBlockStart(4)); // Regular instruction
}

test "analysis2: block boundary detection with jumps" {
    const allocator = std.testing.allocator;

    // Code with JUMP and JUMPI: PUSH1 5, JUMP, STOP, JUMPDEST, PUSH1 0, JUMPI, STOP
    // Block boundaries: 0 (start, 2 (after JUMP, 3 (JUMPDEST, 6 (after JUMPI)
    const code = &[_]u8{
        0x60, 0x05, // PUSH1 5 (instruction 0)
        0x56, // JUMP (instruction 1) - terminator
        0x00, // STOP (instruction 2) - should be block boundary after JUMP
        0x5B, // JUMPDEST (instruction 3) - block boundary
        0x60, 0x00, // PUSH1 0 (instruction 4)
        0x57, // JUMPI (instruction 5) - terminator
        0x00, // STOP (instruction 6) - should be block boundary after JUMPI
    };

    var result = try SimpleAnalysis.analyze(allocator, code);
    defer result.analysis.deinit(allocator);
    defer allocator.free(result.block_gas_costs);

    // Verify block boundaries
    try std.testing.expect(result.analysis.isBlockStart(0)); // First instruction
    try std.testing.expect(result.analysis.isBlockStart(2)); // After JUMP
    try std.testing.expect(result.analysis.isBlockStart(3)); // JUMPDEST
    try std.testing.expect(result.analysis.isBlockStart(6)); // After JUMPI

    // Non-block boundaries
    try std.testing.expect(!result.analysis.isBlockStart(1)); // JUMP itself
    try std.testing.expect(!result.analysis.isBlockStart(4)); // PUSH1 after JUMPDEST
    try std.testing.expect(!result.analysis.isBlockStart(5)); // JUMPI itself
}
