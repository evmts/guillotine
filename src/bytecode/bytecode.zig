const std = @import("std");
const log = @import("../log.zig");
const builtin = @import("builtin");
const ArrayList = std.ArrayListAligned;
const Opcode = @import("../opcodes/opcode.zig").Opcode;
const bytecode_config = @import("bytecode_config.zig");
const BytecodeConfig = bytecode_config.BytecodeConfig;

// NOTE: This implementation does not support EOF (Ethereum Object Format) EIPs including:
// - EIP-3540: EOF - EVM Object Format v1
// - EIP-3670: EOF - Code Validation
// - EIP-4750: EOF - Functions
// - EIP-5450: EOF - Stack Validation

const BITS_PER_BYTE = 8;
const BITMAP_SHIFT = 3; // log2(BITS_PER_BYTE) for efficient division by 8
const BITMAP_MASK = 7; // BITS_PER_BYTE - 1 for modulo 8
const INITCODE_GAS_PER_WORD = 2; // EIP-3860: 2 gas per 32-byte word
const BYTES_PER_WORD = 32; // EVM word size in bytes
const MAX_PUSH_BYTES = 32; // Maximum bytes for PUSH32
const OPCODE_TABLE_SIZE = 256; // Total possible opcode values (0x00-0xFF)
const CACHE_LINE_SIZE = 64; // Common cache line size for x86-64 and ARM64
const PREFETCH_DISTANCE = 256; // How far ahead to prefetch in bytes

pub fn Bytecode(cfg: BytecodeConfig) type {
    cfg.validate();

    return struct {
        const Self = @This();

        pub const fusions_enabled = cfg.fusions_enabled;
        pub const ValidationError = error{
            InvalidOpcode,
            TruncatedPush,
            InvalidJumpDestination,
            OutOfMemory,
            InitcodeTooLarge,
        };

        pub const Stats = @import("bytecode_stats.zig").BytecodeStats;
        pub const PcType = cfg.PcType();

        const PackedBits = packed struct(u4) {
            is_push_data: bool,
            is_op_start: bool,
            is_jumpdest: bool,
            is_fusion_candidate: bool,
        };

        // Basic block information for gas calculation
        pub const BasicBlock = struct {
            start: PcType,
            end: PcType,
            gas_cost: u32 = 0, // Total static gas cost for the block
        };

        // Fusion information for bytecode analysis
        pub const FusionInfo = union(enum) {
            constant_fold: struct {
                value: u256,
                original_length: PcType,
            },
            multi_push: struct {
                values: [3]u256,
                count: u8,
                original_length: PcType,
            },
            multi_pop: struct {
                count: u8,
                original_length: PcType,
            },
            iszero_jumpi: struct {
                target: u256,
                original_length: PcType,
            },
            dup2_mstore_push: struct {
                push_value: u256,
                original_length: PcType,
            },
        };

        /// Iterator for traversing bytecode instructions
        /// Handles fusion patterns and provides sequential access to opcodes with their metadata
        /// Note: Current implementation works well. Future optimization could potentially merge
        /// iterator logic into the initial bytecode analysis pass, but this would require
        /// careful refactoring to maintain fusion detection and gas calculation accuracy.
        pub const Iterator = struct {
            bytecode: *const Self,
            pc: PcType,

            pub fn next(iterator: *Iterator) ?OpcodeData {
                if (iterator.pc >= iterator.bytecode.len()) return null;

                const opcode = iterator.bytecode.get_unsafe(iterator.pc);
                if (iterator.pc >= iterator.bytecode.packed_bitmap.len) {
                    log.err("Iterator PC {} exceeds packed_bitmap len {}", .{ iterator.pc, iterator.bytecode.packed_bitmap.len });
                    return null;
                }
                const packed_bits = iterator.bytecode.packed_bitmap[iterator.pc];

                // Handle fusion opcodes first (only if fusions are enabled)
                if (fusions_enabled and packed_bits.is_fusion_candidate) {
                    const fusion_data = iterator.bytecode.getFusionData(iterator.pc);
                    // Advance PC properly for fusion opcodes
                    switch (fusion_data) {
                        // 2-opcode fusions: PUSH + op
                        .push_add_fusion, .push_mul_fusion, .push_sub_fusion, .push_div_fusion, .push_and_fusion, .push_or_fusion, .push_xor_fusion, .push_jump_fusion, .push_jumpi_fusion, .push_mload_fusion, .push_mstore_fusion, .push_mstore8_fusion => {
                            const push_size = opcode - 0x5F;
                            iterator.pc += 1 + push_size + 1;
                        },
                        // Advanced fusion patterns
                        .multi_push => |mp| {
                            iterator.pc += mp.original_length;
                        },
                        .multi_pop => |mp| {
                            iterator.pc += mp.original_length;
                        },
                        .iszero_jumpi => |ij| {
                            iterator.pc += ij.original_length;
                        },
                        .dup2_mstore_push => |dmp| {
                            iterator.pc += dmp.original_length;
                        },
                        // New high-impact fusions
                        .dup3_add_mstore => |dam| {
                            iterator.pc += dam.original_length;
                        },
                        .swap1_dup2_add => |sda| {
                            iterator.pc += sda.original_length;
                        },
                        .push_dup3_add => |pda| {
                            iterator.pc += pda.original_length;
                        },
                        .function_dispatch => |fd| {
                            iterator.pc += fd.original_length;
                        },
                        .callvalue_check => |cc| {
                            iterator.pc += cc.original_length;
                        },
                        .push0_revert => |pr| {
                            iterator.pc += pr.original_length;
                        },
                        .push_add_dup1 => |pad| {
                            iterator.pc += pad.original_length;
                        },
                        .mload_swap1_dup2 => |msd| {
                            iterator.pc += msd.original_length;
                        },
                        .push => |push_data| {
                            iterator.pc += 1 + push_data.size;
                        },
                        else => {
                            iterator.pc += 1;
                        },
                    }
                    return fusion_data;
                }

                // push

                // Handle regular opcodes
                switch (opcode) {
                    0x60...0x7F => { // PUSH1-PUSH32
                        const push_size = opcode - 0x5F;
                        var value: u256 = 0;

                        // Read push value using proper endianness
                        const end_pc = @min(iterator.pc + 1 + push_size, @as(PcType, @intCast(iterator.bytecode.len())));
                        for (iterator.pc + 1..end_pc) |i| {
                            value = std.math.shl(u256, value, 8) | iterator.bytecode.get_unsafe(@intCast(i));
                        }

                        iterator.pc = end_pc;
                        return OpcodeData{ .push = .{ .value = value, .size = push_size } };
                    },
                    0x5B => { // JUMPDEST
                        const block_info = iterator.calculateBlockInfoAtJumpdest();
                        iterator.pc += 1;
                        return OpcodeData{ .jumpdest = .{
                            .gas_cost = block_info.gas,
                            .min_stack = block_info.min_stack,
                            .max_stack = block_info.max_stack,
                        } };
                    },
                    0x56 => { // JUMP - Dynamic jump (not fused)
                        iterator.pc += 1;
                        return OpcodeData{ .jump = {} };
                    },
                    0x57 => { // JUMPI - Dynamic jump (not fused)
                        iterator.pc += 1;
                        return OpcodeData{ .jumpi = {} };
                    },
                    0x58 => { // PC
                        const current_pc = iterator.pc;
                        iterator.pc += 1;
                        return OpcodeData{ .pc = .{ .value = current_pc } };
                    },
                    0x00 => { // STOP
                        iterator.pc += 1;
                        return OpcodeData{ .stop = {} };
                    },
                    0xFE => { // INVALID
                        iterator.pc += 1;
                        return OpcodeData{ .invalid = {} };
                    },
                    else => {
                        iterator.pc += 1;
                        return OpcodeData{ .regular = .{ .opcode = opcode } };
                    },
                }
            }

            // Calculate gas cost and stack requirements for the block starting at current JUMPDEST
            pub fn calculateBlockInfoAtJumpdest(iterator: *Iterator) struct { gas: u32, min_stack: i16, max_stack: i16 } {
                const opcode_info = @import("../opcodes/opcode_data.zig").OPCODE_INFO;
                var gas: u32 = 1; // JUMPDEST itself costs 1 gas
                var stack_effect: i32 = 0;
                var min_stack: i32 = 0;
                var max_stack: i32 = 0;
                var pc = iterator.pc + 1; // Start after the JUMPDEST
                var loop_counter = cfg.createLoopSafetyCounter().init(cfg.loop_quota orelse 0);

                while (pc < iterator.bytecode.len()) {
                    loop_counter.inc();
                    const opcode = iterator.bytecode.get_unsafe(pc);

                    // Check for block terminators
                    switch (opcode) {
                        0x5B, // Another JUMPDEST - end of block
                        0x00, // STOP
                        0x56, // JUMP
                        0x57, // JUMPI
                        0xF3, // RETURN
                        0xFD, // REVERT
                        0xFE, // INVALID
                        0xFF, // SELFDESTRUCT
                        => {
                            return .{
                                .gas = gas,
                                .min_stack = @intCast(@abs(min_stack)),
                                .max_stack = @intCast(@max(0, max_stack)),
                            };
                        },
                        0x60...0x7F => { // PUSH1-PUSH32
                            gas += opcode_info[opcode].gas_cost;
                            const push_size = opcode - 0x5F;
                            pc += 1 + push_size;
                            // PUSH operations: 0 inputs, 1 output
                            stack_effect += 1;
                            if (stack_effect > max_stack) max_stack = stack_effect;
                        },
                        // Special handling for DUP operations
                        0x80...0x8f => { // DUP1-DUP16
                            gas += opcode_info[opcode].gas_cost;
                            const dup_n = @as(i32, opcode - 0x80 + 1);
                            // DUP needs N items
                            const min_required = stack_effect - dup_n;
                            if (min_required < min_stack) {
                                min_stack = min_required;
                            }
                            stack_effect += 1; // DUP pushes 1 item
                            if (stack_effect > max_stack) max_stack = stack_effect;
                            pc += 1;
                        },
                        // Special handling for SWAP operations
                        0x90...0x9f => { // SWAP1-SWAP16
                            gas += opcode_info[opcode].gas_cost;
                            const swap_n = @as(i32, opcode - 0x90 + 2); // SWAP1 needs 2 items, SWAP2 needs 3, etc.
                            // SWAP needs N+1 items
                            const min_required = stack_effect - swap_n;
                            if (min_required < min_stack) {
                                min_stack = min_required;
                            }
                            // SWAP doesn't change stack size
                            pc += 1;
                        },
                        else => {
                            gas += opcode_info[opcode].gas_cost;
                            // Regular opcodes - use opcode_info for stack effects
                            if (opcode < opcode_info.len) {
                                stack_effect -= opcode_info[opcode].stack_inputs;
                                if (stack_effect < min_stack) min_stack = stack_effect;
                                stack_effect += opcode_info[opcode].stack_outputs;
                                if (stack_effect > max_stack) max_stack = stack_effect;
                            }
                            pc += 1;
                        },
                    }
                }

                return .{
                    .gas = gas,
                    .min_stack = @intCast(@abs(min_stack)),
                    .max_stack = @intCast(@max(0, max_stack)),
                };
            }
        };

        // Tagged union for opcode data returned by iterator
        pub const OpcodeData = union(enum) {
            regular: struct { opcode: u8 },
            push: struct { value: u256, size: u8 },
            jumpdest: struct { gas_cost: u32, min_stack: i16, max_stack: i16 },
            jump: void, // Dynamic JUMP (not fused)
            jumpi: void, // Dynamic JUMPI (not fused)
            pc: struct { value: PcType }, // PC opcode with current PC value
            push_add_fusion: struct { value: u256 },
            push_mul_fusion: struct { value: u256 },
            push_sub_fusion: struct { value: u256 },
            push_div_fusion: struct { value: u256 },
            push_and_fusion: struct { value: u256 },
            push_or_fusion: struct { value: u256 },
            push_xor_fusion: struct { value: u256 },
            push_jump_fusion: struct { value: u256 },
            push_jumpi_fusion: struct { value: u256 },
            push_mload_fusion: struct { value: u256 },
            push_mstore_fusion: struct { value: u256 },
            push_mstore8_fusion: struct { value: u256 },
            // Advanced fusion patterns
            multi_push: struct { count: u8, original_length: u8, values: [3]u256 },
            multi_pop: struct { count: u8, original_length: u8 },
            iszero_jumpi: struct { target: u256, original_length: u8 },
            dup2_mstore_push: struct { push_value: u256, original_length: u8 },
            // New high-impact fusions
            dup3_add_mstore: struct { original_length: u8 },
            swap1_dup2_add: struct { original_length: u8 },
            push_dup3_add: struct { value: u256, original_length: u8 },
            function_dispatch: struct { selector: u32, target: u256, original_length: u8 },
            callvalue_check: struct { original_length: u8 },
            push0_revert: struct { original_length: u8 },
            push_add_dup1: struct { value: u256, original_length: u8 },
            mload_swap1_dup2: struct { original_length: u8 },
            stop: void,
            invalid: void,
        };

        // Full bytecode including any metadata
        full_code: []const u8,
        // Runtime bytecode (excludes trailing metadata)
        runtime_code: []const u8,
        allocator: std.mem.Allocator,
        // Packed bitmap (4 bits per byte position) for efficient storage
        packed_bitmap: []PackedBits,

        pub fn init(allocator: std.mem.Allocator, code: []const u8) ValidationError!Self {
            return initWithTracer(allocator, code, null);
        }

        pub fn initWithTracer(allocator: std.mem.Allocator, code: []const u8, tracer: anytype) ValidationError!Self {
            // Notify tracer of analysis start
            if (tracer) |t| {
                t.onBytecodeAnalysisStart(code.len);
            }

            // Note: Size validation is done by the caller (EVM) based on context:
            // - execute_init_code checks against max_initcode_size (49KB)
            // - runtime code is checked against max_bytecode_size (24KB)

            // Validate bytecode length fits in PcType (required for len() method)
            if (tracer) |t| {
                t.assert(code.len <= std.math.maxInt(PcType), "Bytecode length must fit in PcType");
            }

            // Detect and strip Solidity metadata from the end of bytecode.
            // Per the Solidity specification, metadata is appended to the bytecode.
            // The last two bytes of the contract's raw bytecode form a big-endian
            // integer that specifies the length of the CBOR-encoded metadata section.
            // This allows for efficient O(1) retrieval of the metadata without scanning.
            var runtime_code = code;
            if (code.len >= 4) { // Minimal length for metadata to be present.
                const metadata_len = std.mem.readInt(u16, code[code.len - 2 ..][0..2], .big);

                if (metadata_len > 0 and @as(usize, metadata_len) + 2 <= code.len) {
                    const metadata_start_idx = code.len - @as(usize, metadata_len) - 2;
                    const metadata_slice = code[metadata_start_idx .. code.len - 2];

                    // A valid metadata block is a CBOR map. We check for common Solidity patterns for robustness.
                    if (metadata_slice.len > 6) {
                        const ipfs_pattern = &.{ 0xa2, 0x64, 'i', 'p', 'f', 's' };
                        const bzzr0_pattern = &.{ 0xa1, 0x65, 'b', 'z', 'z', 'r', '0' };
                        const bzzr1_pattern = &.{ 0xa1, 0x65, 'b', 'z', 'z', 'r', '1' };

                        if (std.mem.startsWith(u8, metadata_slice, ipfs_pattern) or
                            std.mem.startsWith(u8, metadata_slice, bzzr0_pattern) or
                            std.mem.startsWith(u8, metadata_slice, bzzr1_pattern))
                        {
                            runtime_code = code[0..metadata_start_idx];
                            if (tracer) |t| {
                                t.debug("Detected Solidity metadata, trimming bytecode from {} to {} bytes", .{ code.len, runtime_code.len });
                            }
                        }
                    }
                }
            }

            var self = Self{
                .full_code = code,
                .runtime_code = runtime_code,
                .allocator = allocator,
                .packed_bitmap = &.{},
            };
            // Build bitmaps and validate only the runtime code
            try self.buildBitmapsAndValidateWithTracer(runtime_code.len, tracer);

            // Notify tracer of analysis completion if not already done
            if (tracer) |t| {
                if (runtime_code.len == 0) {
                    // For empty bytecode, notify completion with zero counts
                    t.onBytecodeAnalysisComplete(0, 0, 0);
                }
            }

            return self;
        }

        /// Calculate the gas cost for initcode (EIP-3860)
        /// Returns 2 gas per 32-byte word of initcode
        pub fn calculateInitcodeGas(initcode_len: usize) u64 {
            // Gas cost is 2 per 32-byte word, rounding up
            const words = (initcode_len + BYTES_PER_WORD - 1) / BYTES_PER_WORD;
            return words * INITCODE_GAS_PER_WORD;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.packed_bitmap);
            self.* = undefined;
        }

        /// Create an iterator for efficient bytecode traversal
        pub fn createIterator(self: *const Self) Iterator {
            return Iterator{
                .bytecode = self,
                .pc = 0,
            };
        }

        // Advanced pattern detection functions

        fn checkMultiPushPattern(self: *const Self, pc: PcType, n: u8) ?OpcodeData {
            if (pc + n > self.len()) return null;

            var current_pc = pc;
            var total_length: PcType = 0;
            var values: [3]u256 = .{ 0, 0, 0 };

            // Check for n consecutive PUSH instructions
            var i: u8 = 0;
            while (i < n) : (i += 1) {
                if (current_pc >= self.len()) return null;
                const op = self.get_unsafe(current_pc);
                if (op < 0x60 or op > 0x7F) { // Not a PUSH opcode
                    return null;
                }
                const push_size = op - 0x5F;

                // Extract value
                var value: u256 = 0;
                const end = @min(current_pc + 1 + push_size, self.len());
                for (current_pc + 1..end) |j| {
                    value = std.math.shl(u256, value, 8) | self.get_unsafe(@intCast(j));
                }
                if (i < 3) values[i] = value;

                current_pc += 1 + push_size;
                total_length += 1 + push_size;
            }

            return OpcodeData{ .multi_push = .{ .count = n, .original_length = @intCast(total_length), .values = values } };
        }

        fn checkMultiPopPattern(self: *const Self, pc: PcType, n: u8) ?OpcodeData {
            if (pc + n > self.len()) return null;

            // Check if we have n consecutive POP instructions
            var i: u8 = 0;
            while (i < n) : (i += 1) {
                if (self.get_unsafe(pc + i) != 0x50) { // POP opcode
                    return null;
                }
            }

            return OpcodeData{ .multi_pop = .{ .count = n, .original_length = n } };
        }

        fn checkIszeroJumpiPattern(self: *const Self, pc: PcType) ?OpcodeData {
            if (pc + 2 >= self.len()) return null;

            // Check for ISZERO
            if (self.get_unsafe(pc) != 0x15) return null;

            // Check for PUSH after ISZERO
            const push_pc = pc + 1;
            const push_op = self.get_unsafe(push_pc);
            if (push_op < 0x60 or push_op > 0x7F) {
                return null;
            }

            const push_size = push_op - 0x5F;
            const jumpi_pc = push_pc + 1 + push_size;

            // Check for JUMPI
            if (jumpi_pc >= self.len() or self.get_unsafe(jumpi_pc) != 0x57) {
                return null;
            }

            // Extract target
            var target: u256 = 0;
            const end = @min(push_pc + 1 + push_size, self.len());
            for (push_pc + 1..end) |i| {
                target = std.math.shl(u256, target, 8) | self.get_unsafe(@intCast(i));
            }

            return OpcodeData{ .iszero_jumpi = .{ .target = target, .original_length = @intCast(jumpi_pc + 1 - pc) } };
        }

        fn checkDup2MstorePushPattern(self: *const Self, pc: PcType) ?OpcodeData {
            if (pc + 3 >= self.len()) return null;

            // Check for DUP2
            if (self.get_unsafe(pc) != 0x81) return null;

            // Check for MSTORE
            if (self.get_unsafe(pc + 1) != 0x52) return null;

            // Check for PUSH after MSTORE
            const push_pc = pc + 2;
            const push_op = self.get_unsafe(push_pc);
            if (push_op < 0x60 or push_op > 0x7F) {
                return null;
            }

            const push_size = push_op - 0x5F;

            // Extract push value
            var value: u256 = 0;
            const end = @min(push_pc + 1 + push_size, self.len());
            for (push_pc + 1..end) |i| {
                value = std.math.shl(u256, value, 8) | self.get_unsafe(@intCast(i));
            }

            return OpcodeData{ .dup2_mstore_push = .{ .push_value = value, .original_length = @intCast(3 + push_size) } };
        }

        // New high-impact pattern detection functions
        fn checkDup3AddMstorePattern(self: *const Self, pc: PcType) ?OpcodeData {
            if (pc + 3 > self.len()) return null;

            // Check for DUP3 + ADD + MSTORE
            if (self.get_unsafe(pc) != 0x82) return null; // DUP3
            if (self.get_unsafe(pc + 1) != 0x01) return null; // ADD
            if (self.get_unsafe(pc + 2) != 0x52) return null; // MSTORE

            return OpcodeData{ .dup3_add_mstore = .{ .original_length = 3 } };
        }

        fn checkSwap1Dup2AddPattern(self: *const Self, pc: PcType) ?OpcodeData {
            if (pc + 3 > self.len()) return null;

            // Check for SWAP1 + DUP2 + ADD
            if (self.get_unsafe(pc) != 0x90) return null; // SWAP1
            if (self.get_unsafe(pc + 1) != 0x81) return null; // DUP2
            if (self.get_unsafe(pc + 2) != 0x01) return null; // ADD

            return OpcodeData{ .swap1_dup2_add = .{ .original_length = 3 } };
        }

        fn checkPushDup3AddPattern(self: *const Self, pc: PcType) ?OpcodeData {
            if (pc + 3 >= self.len()) return null;

            // Check for PUSH + DUP3 + ADD
            const push_op = self.get_unsafe(pc);
            if (push_op < 0x5F or push_op > 0x7F) return null; // PUSH0-PUSH32

            const push_size = if (push_op == 0x5F) 0 else push_op - 0x5F;
            const dup3_pc = pc + 1 + push_size;

            if (dup3_pc + 2 > self.len()) return null;
            if (self.get_unsafe(dup3_pc) != 0x82) return null; // DUP3
            if (self.get_unsafe(dup3_pc + 1) != 0x01) return null; // ADD

            // Extract push value
            var value: u256 = 0;
            if (push_op != 0x5F) { // Not PUSH0
                const end = @min(pc + 1 + push_size, self.len());
                for (pc + 1..end) |i| {
                    value = std.math.shl(u256, value, 8) | self.get_unsafe(@intCast(i));
                }
            }

            return OpcodeData{ .push_dup3_add = .{ .value = value, .original_length = @intCast(1 + push_size + 2) } };
        }

        fn checkFunctionDispatchPattern(self: *const Self, pc: PcType) ?OpcodeData {
            if (pc + 8 >= self.len()) return null;

            // Check for PUSH4 + EQ + PUSH + JUMPI (function selector pattern)
            if (self.get_unsafe(pc) != 0x63) return null; // PUSH4

            // Extract selector (4 bytes)
            var selector: u32 = 0;
            for (pc + 1..pc + 5) |i| {
                selector = std.math.shl(u32, selector, 8) | @as(u32, self.get_unsafe(@intCast(i)));
            }

            if (self.get_unsafe(pc + 5) != 0x14) return null; // EQ

            // Check for PUSH after EQ
            const push_pc = pc + 6;
            const push_op = self.get_unsafe(push_pc);
            if (push_op < 0x60 or push_op > 0x62) return null; // PUSH1 or PUSH2 typically

            const push_size = push_op - 0x5F;

            // Extract jump target
            var target: u256 = 0;
            const end = @min(push_pc + 1 + push_size, self.len());
            for (push_pc + 1..end) |i| {
                target = std.math.shl(u256, target, 8) | self.get_unsafe(@intCast(i));
            }

            const jumpi_pc = push_pc + 1 + push_size;
            if (jumpi_pc >= self.len() or self.get_unsafe(jumpi_pc) != 0x57) return null; // JUMPI

            return OpcodeData{ .function_dispatch = .{ .selector = selector, .target = target, .original_length = @intCast(8 + push_size) } };
        }

        fn checkCallvalueCheckPattern(self: *const Self, pc: PcType) ?OpcodeData {
            if (pc + 3 > self.len()) return null;

            // Check for CALLVALUE + DUP1 + ISZERO
            if (self.get_unsafe(pc) != 0x34) return null; // CALLVALUE
            if (self.get_unsafe(pc + 1) != 0x80) return null; // DUP1
            if (self.get_unsafe(pc + 2) != 0x15) return null; // ISZERO

            return OpcodeData{ .callvalue_check = .{ .original_length = 3 } };
        }

        fn checkPush0RevertPattern(self: *const Self, pc: PcType) ?OpcodeData {
            if (pc + 3 > self.len()) return null;

            // Check for PUSH0 + PUSH0 + REVERT
            if (self.get_unsafe(pc) != 0x5F) return null; // PUSH0
            if (self.get_unsafe(pc + 1) != 0x5F) return null; // PUSH0
            if (self.get_unsafe(pc + 2) != 0xFD) return null; // REVERT

            return OpcodeData{ .push0_revert = .{ .original_length = 3 } };
        }

        fn checkPushAddDup1Pattern(self: *const Self, pc: PcType) ?OpcodeData {
            if (pc + 3 >= self.len()) return null;

            // Check for PUSH + ADD + DUP1
            const push_op = self.get_unsafe(pc);
            if (push_op < 0x5F or push_op > 0x7F) return null; // PUSH0-PUSH32

            const push_size = if (push_op == 0x5F) 0 else push_op - 0x5F;
            const add_pc = pc + 1 + push_size;

            if (add_pc + 2 > self.len()) return null;
            if (self.get_unsafe(add_pc) != 0x01) return null; // ADD
            if (self.get_unsafe(add_pc + 1) != 0x80) return null; // DUP1

            // Extract push value
            var value: u256 = 0;
            if (push_op != 0x5F) { // Not PUSH0
                const end = @min(pc + 1 + push_size, self.len());
                for (pc + 1..end) |i| {
                    value = std.math.shl(u256, value, 8) | self.get_unsafe(@intCast(i));
                }
            }

            return OpcodeData{ .push_add_dup1 = .{ .value = value, .original_length = @intCast(1 + push_size + 2) } };
        }

        fn checkMloadSwap1Dup2Pattern(self: *const Self, pc: PcType) ?OpcodeData {
            if (pc + 3 > self.len()) return null;

            // Check for MLOAD + SWAP1 + DUP2
            if (self.get_unsafe(pc) != 0x51) return null; // MLOAD
            if (self.get_unsafe(pc + 1) != 0x90) return null; // SWAP1
            if (self.get_unsafe(pc + 2) != 0x81) return null; // DUP2

            return OpcodeData{ .mload_swap1_dup2 = .{ .original_length = 3 } };
        }

        /// Get fusion data for a bytecode position marked as fusion candidate
        /// This method checks for advanced patterns first (in priority order)
        pub fn getFusionData(self: *const Self, pc: PcType) OpcodeData {
            if (pc >= self.len()) {
                return OpcodeData{ .regular = .{ .opcode = 0x00 } }; // STOP fallback
            }

            // Check advanced fusion patterns in priority order (longest first)

            // Check function dispatch pattern first (can be 8+ bytes)
            if (self.checkFunctionDispatchPattern(pc)) |fusion| {
                return fusion;
            }

            // 1. Check for ISZERO-JUMPI pattern (highest priority) (variable length)
            if (self.checkIszeroJumpiPattern(pc)) |fusion| {
                return fusion;
            }

            // Check PUSH + DUP3 + ADD pattern
            if (self.checkPushDup3AddPattern(pc)) |fusion| {
                return fusion;
            }

            // Check PUSH + ADD + DUP1 pattern
            if (self.checkPushAddDup1Pattern(pc)) |fusion| {
                return fusion;
            }

            // 3. Check for DUP2-MSTORE-PUSH pattern (variable length)
            if (self.checkDup2MstorePushPattern(pc)) |fusion| {
                return fusion;
            }

            // Check new 3-opcode patterns
            if (self.checkDup3AddMstorePattern(pc)) |fusion| {
                return fusion;
            }

            if (self.checkSwap1Dup2AddPattern(pc)) |fusion| {
                return fusion;
            }

            if (self.checkCallvalueCheckPattern(pc)) |fusion| {
                return fusion;
            }

            if (self.checkPush0RevertPattern(pc)) |fusion| {
                return fusion;
            }

            if (self.checkMloadSwap1Dup2Pattern(pc)) |fusion| {
                return fusion;
            }

            // 4. Check for 3-PUSH fusion
            if (self.checkMultiPushPattern(pc, 3)) |fusion| {
                return fusion;
            }

            // 5. Check for 3-POP fusion
            if (self.checkMultiPopPattern(pc, 3)) |fusion| {
                return fusion;
            }

            // 6. Check for 2-PUSH fusion
            if (self.checkMultiPushPattern(pc, 2)) |fusion| {
                return fusion;
            }

            // 7. Check for 2-POP fusion
            if (self.checkMultiPopPattern(pc, 2)) |fusion| {
                return fusion;
            }

            const first_op = self.get_unsafe(pc);

            // Check for existing 2-opcode fusions (PUSH + op)
            if (first_op >= 0x60 and first_op <= 0x7F) { // PUSH opcode
                const push_size = first_op - 0x5F;
                var value: u256 = 0;
                const end_pc = @min(pc + 1 + push_size, self.len());
                for (pc + 1..end_pc) |i| {
                    value = std.math.shl(u256, value, 8) | self.get_unsafe(@intCast(i));
                }

                // The second opcode comes AFTER the push data
                const second_op_pc = pc + 1 + push_size;
                const second_op = if (second_op_pc < self.len()) self.get_unsafe(second_op_pc) else 0x00;

                // Return appropriate fusion type based on second opcode
                switch (second_op) {
                    0x01 => return OpcodeData{ .push_add_fusion = .{ .value = value } },
                    0x02 => return OpcodeData{ .push_mul_fusion = .{ .value = value } }, // MUL
                    0x03 => return OpcodeData{ .push_sub_fusion = .{ .value = value } }, // SUB
                    0x04 => return OpcodeData{ .push_div_fusion = .{ .value = value } }, // DIV
                    0x16 => return OpcodeData{ .push_and_fusion = .{ .value = value } }, // AND
                    0x17 => return OpcodeData{ .push_or_fusion = .{ .value = value } }, // OR
                    0x18 => return OpcodeData{ .push_xor_fusion = .{ .value = value } }, // XOR
                    0x51 => return OpcodeData{ .push_mload_fusion = .{ .value = value } }, // MLOAD
                    0x52 => return OpcodeData{ .push_mstore_fusion = .{ .value = value } },
                    0x53 => return OpcodeData{ .push_mstore8_fusion = .{ .value = value } }, // MSTORE8
                    0x56 => return OpcodeData{ .push_jump_fusion = .{ .value = value } }, // JUMP
                    0x57 => return OpcodeData{ .push_jumpi_fusion = .{ .value = value } }, // JUMPI
                    else => {
                        // No fusion detected, return regular PUSH
                        return OpcodeData{ .push = .{ .value = value, .size = push_size } };
                    },
                }
            }

            // No fusion pattern detected, return regular opcode
            return OpcodeData{ .regular = .{ .opcode = first_op } };
        }

        /// Get the length of the bytecode
        pub inline fn len(self: Self) PcType {
            // Guaranteed by config that runtime_code.len fits in PcType
            // This is validated during init(), so this should always be true
            return @intCast(self.runtime_code.len);
        }

        /// Get the raw bytecode slice
        pub inline fn raw(self: Self) []const u8 {
            return self.runtime_code;
        }

        /// Get bytecode without Solidity metadata
        /// Returns a slice excluding the metadata at the end, or the full bytecode if no metadata found
        pub fn rawWithoutMetadata(self: Self) []const u8 {
            // Since we already separated metadata during init, just return runtime_code
            return self.runtime_code;
        }

        /// Get byte at index
        pub inline fn get(self: Self, index: PcType) ?u8 {
            if (index >= self.runtime_code.len) return null;
            return self.runtime_code[index];
        }
        /// Get byte at index
        pub inline fn get_unsafe(self: Self, index: PcType) u8 {
            return self.runtime_code[index];
        }

        /// Get opcode at position (doesn't check if it's actually an opcode start)
        pub inline fn getOpcode(self: Self, pc: PcType) ?u8 {
            return self.get(pc);
        }
        /// Get opcode at position (doesn't check if it's actually an opcode start)
        pub inline fn getOpcodeUnsafe(self: Self, pc: PcType) u8 {
            return self.get_unsafe(pc);
        }

        /// Read a PUSH value at the given PC with the specified size
        /// Returns null if the PC doesn't point to a PUSH instruction of the correct size
        pub fn readPushValue(self: Self, pc: PcType, comptime size: comptime_int) ?std.meta.Int(.unsigned, size * 8) {
            const opcode = self.get(pc) orelse return null;
            const expected_push = 0x60 + (size - 1);  // PUSH1 = 0x60, PUSH2 = 0x61, etc.
            if (opcode != expected_push) return null;
            
            var value: std.meta.Int(.unsigned, size * 8) = 0;
            const end_pc = @min(pc + 1 + size, self.len());
            if (pc + 1 + size > self.len()) return null;
            
            for (pc + 1..end_pc) |i| {
                value = std.math.shl(@TypeOf(value), value, 8) | self.get_unsafe(@intCast(i));
            }
            return value;
        }

        /// Read a PUSH value at the given PC with dynamic size (returns u256)
        pub fn readPushValueN(self: Self, pc: PcType, size: u8) ?u256 {
            const opcode = self.get(pc) orelse return null;
            const expected_push = 0x60 + (size - 1);  // PUSH1 = 0x60, PUSH2 = 0x61, etc.
            if (opcode != expected_push and opcode != 0x5F) return null;  // Also allow PUSH0
            
            if (opcode == 0x5F) return 0;  // PUSH0
            
            var value: u256 = 0;
            const end_pc = @min(pc + 1 + size, self.len());
            if (pc + 1 + size > self.len()) return null;
            
            for (pc + 1..end_pc) |i| {
                value = std.math.shl(u256, value, 8) | self.get_unsafe(@intCast(i));
            }
            return value;
        }

        /// Get the size of the instruction at the given PC
        pub fn getInstructionSize(self: Self, pc: PcType) PcType {
            const opcode = self.get(pc) orelse return 1;
            if (opcode >= 0x60 and opcode <= 0x7F) {
                // PUSH1 through PUSH32
                const push_size = opcode - 0x5F;
                return 1 + push_size;
            }
            return 1;
        }

        /// Get the PC of the next instruction after the one at the given PC
        /// Returns null if we're at the end of the bytecode
        pub fn getNextPc(self: Self, pc: PcType) ?PcType {
            const size = self.getInstructionSize(pc);
            const next = pc + size;
            if (next >= self.len()) return null;
            return next;
        }

        /// Check if a position is a valid jump destination
        /// Uses precomputed bitmap for O(1) lookup
        pub fn isValidJumpDest(self: Self, pc: PcType) bool {
            if (pc >= self.len()) return false;
            return self.packed_bitmap[pc].is_jumpdest;
        }

        /// Analyze bytecode and call callbacks for jump destinations
        /// This allows callers to build their own data structures
        pub fn analyzeJumpDests(
            self: Self,
            context: anytype,
            callback: fn (@TypeOf(context), pc: PcType) void,
        ) void {
            var i: PcType = 0;
            while (i < self.runtime_code.len) {
                @branchHint(.likely);
                const op = self.runtime_code[i];
                // https://ziglang.org/documentation/master/#intFromEnum
                // @intFromEnum converts an enum value to its integer representation
                if (op >= @intFromEnum(Opcode.PUSH1) and op <= @intFromEnum(Opcode.PUSH32)) {
                    const n = op - (@intFromEnum(Opcode.PUSH1) - 1);
                    i += 1 + n;
                } else {
                    if (op == @intFromEnum(Opcode.JUMPDEST)) {
                        callback(context, i);
                    }
                    i += 1;
                }
            }
        }

        // NOTE: Opcode validation occurs during bitmap construction via safe enum conversion.

        // Fusion detection uses scalar approach in getStats for simplicity and robustness

        /// Build bitmaps and validate bytecode in a single pass
        fn buildBitmapsAndValidate(self: *Self) ValidationError!void {
            return self.buildBitmapsAndValidateWithTracer(self.runtime_code.len, null);
        }

        fn buildBitmapsAndValidateWithTracer(self: *Self, validation_length: usize, tracer: anytype) ValidationError!void {
            return self.buildBitmapsAndValidateWithLengthAndTracer(validation_length, tracer);
        }

        /// Build bitmaps and validate bytecode with a specific validation length
        /// This allows validating only the code portion of deployment bytecode, excluding metadata
        fn buildBitmapsAndValidateWithLength(self: *Self, validation_length: usize) ValidationError!void {
            return self.buildBitmapsAndValidateWithLengthAndTracer(validation_length, null);
        }

        fn buildBitmapsAndValidateWithLengthAndTracer(self: *Self, validation_length: usize, tracer: anytype) ValidationError!void {
            const N = self.runtime_code.len;
            const validate_up_to = @min(validation_length, N);

            // Set up cleanup in case of errors
            var cleanup_state: struct {
                packed_bitmap_allocated: bool = false,
            } = .{};

            errdefer {
                if (cleanup_state.packed_bitmap_allocated) self.allocator.free(self.packed_bitmap);
            }

            // Empty bytecode is valid, allocate minimal bitmaps
            if (N == 0) {
                self.packed_bitmap = try self.allocator.alloc(PackedBits, 1);
                cleanup_state.packed_bitmap_allocated = true;
                self.packed_bitmap[0] = PackedBits{ .is_push_data = false, .is_op_start = false, .is_jumpdest = false, .is_fusion_candidate = false };
                return;
            }

            // NEW: Allocate packed bitmap (4 bits per byte, so N packed bits)
            self.packed_bitmap = self.allocator.alloc(PackedBits, N) catch return error.OutOfMemory;
            cleanup_state.packed_bitmap_allocated = true;
            // Initialize all packed bits to false
            for (self.packed_bitmap) |*packed_bits| {
                packed_bits.* = PackedBits{ .is_push_data = false, .is_op_start = false, .is_jumpdest = false, .is_fusion_candidate = false };
            }

            // Single pass: validate opcodes, mark bitmaps, detect JUMPDEST and fusions
            // Track state for immediate jump validation
            var last_push_value: ?u256 = null;
            var last_push_end: PcType = 0;

            // Collect immediate jumps to validate after first pass
            var immediate_jumps = std.ArrayList(PcType){};
            defer immediate_jumps.deinit(self.allocator);

            var opcode_count: usize = 0;
            var jumpdest_count: usize = 0;
            var i: PcType = 0;
            while (i < validate_up_to) {
                @branchHint(.likely);

                // Prefetch ahead for better cache performance on large bytecode
                if (@as(usize, i) + PREFETCH_DISTANCE < validate_up_to) {
                    @prefetch(&self.runtime_code[@as(usize, i) + PREFETCH_DISTANCE], .{
                        .rw = .read,
                        .locality = 3, // Low temporal locality
                        .cache = .data,
                    });
                }

                // Mark operation start
                self.packed_bitmap[i].is_op_start = true;

                const op = self.runtime_code[i];

                // Validate opcode - undefined opcodes are valid but treated as INVALID
                const opcode_enum = std.meta.intToEnum(Opcode, op) catch blk: {
                    // Undefined opcodes are valid in EVM - they execute as INVALID operation
                    // which consumes all gas and reverts. We'll treat them as INVALID (0xFE)
                    if (tracer) |t| {
                        t.onInvalidOpcode(@intCast(i), op);
                    }
                    break :blk Opcode.INVALID;
                };
                opcode_count += 1;

                // Check if it's a JUMPDEST (and not push data)
                if (op == @intFromEnum(Opcode.JUMPDEST)) {
                    self.packed_bitmap[i].is_jumpdest = true;
                    jumpdest_count += 1;
                    if (tracer) |t| {
                        // Calculate gas cost for this JUMPDEST's basic block
                        // (simplified for now - actual gas calculation happens during schedule build)
                        t.onJumpdestFound(@intCast(i), 1);
                    }
                }

                // Check for fusion candidates if enabled
                if (comptime fusions_enabled) {
                    // Check for ISZERO+PUSH+JUMPI pattern
                    if (op == @intFromEnum(Opcode.ISZERO)) {
                        const push_pc = i + 1;
                        if (push_pc < validate_up_to) {
                            const push_op = self.runtime_code[push_pc];
                            if (push_op >= @intFromEnum(Opcode.PUSH1) and push_op <= @intFromEnum(Opcode.PUSH32)) {
                                const push_size: PcType = push_op - (@intFromEnum(Opcode.PUSH1) - 1);
                                const jumpi_pc = push_pc + 1 + push_size;
                                if (jumpi_pc < validate_up_to and self.runtime_code[jumpi_pc] == @intFromEnum(Opcode.JUMPI)) {
                                    // Mark ISZERO as fusion candidate for ISZERO+PUSH+JUMPI pattern
                                    self.packed_bitmap[i].is_fusion_candidate = true;
                                    if (tracer) |t| {
                                        t.debug("Marked ISZERO at PC {} as fusion candidate for ISZERO+PUSH+JUMPI pattern", .{i});
                                    }
                                }
                            }
                        }
                    }
                    
                    // Check if this is a PUSH that could be part of a fusion
                    if (op >= @intFromEnum(Opcode.PUSH1) and op <= @intFromEnum(Opcode.PUSH32)) {
                        const push_size: PcType = op - (@intFromEnum(Opcode.PUSH1) - 1);
                        const next_op_idx = i + 1 + push_size;

                        // Ensure we can read the next opcode
                        if (next_op_idx < validate_up_to) {
                            const next_op = self.runtime_code[next_op_idx];
                            // Check for fusable patterns
                            const is_fusable = switch (next_op) {
                                @intFromEnum(Opcode.ADD), @intFromEnum(Opcode.MUL), @intFromEnum(Opcode.SUB), @intFromEnum(Opcode.DIV), @intFromEnum(Opcode.AND), @intFromEnum(Opcode.OR), @intFromEnum(Opcode.XOR), @intFromEnum(Opcode.JUMP), @intFromEnum(Opcode.JUMPI), @intFromEnum(Opcode.MLOAD), @intFromEnum(Opcode.MSTORE), @intFromEnum(Opcode.MSTORE8) => true,
                                else => false,
                            };

                            if (is_fusable) {
                                self.packed_bitmap[i].is_fusion_candidate = true;
                            }
                        }
                    }
                }

                // Handle PUSH instructions
                if (@intFromEnum(opcode_enum) >= @intFromEnum(Opcode.PUSH1) and
                    @intFromEnum(opcode_enum) <= @intFromEnum(Opcode.PUSH32))
                {
                    const n: PcType = op - (@intFromEnum(Opcode.PUSH1) - 1);

                    // We need to read n bytes after the opcode at position i
                    // So we need positions i+1 through i+n to be valid
                    // This means i+n must be less than the validation length
                    // PUSH32 at position 0 needs to read bytes 1-32, so position 32 must be valid
                    // Therefore i+1+n must be <= validate_up_to, or i+n < validate_up_to
                    if (i + 1 + n > validate_up_to) {
                        if (tracer) |t| {
                            t.onTruncatedPush(@intCast(i), @intCast(n), validate_up_to - i - 1);
                        }
                        return error.TruncatedPush;
                    }

                    // Extract push value for immediate jump validation (only if fusions enabled)
                    var push_value: u256 = 0;
                    if (comptime fusions_enabled) {
                        var byte_idx: PcType = 0;
                        while (byte_idx < n) : (byte_idx += 1) {
                            push_value = std.math.shl(u256, push_value, 8) | self.runtime_code[i + 1 + byte_idx];
                        }
                    }

                    // Mark push data bytes
                    var j: PcType = 0;
                    while (j < n) : (j += 1) {
                        const idx = i + 1 + j;
                        self.packed_bitmap[idx].is_push_data = true;
                    }

                    const push_end = i + 1 + n;

                    // ONLY check for immediate jump patterns if fusions are enabled
                    // This is for optimization purposes, not correctness validation
                    if (comptime fusions_enabled) {
                        if (push_end < validate_up_to) {
                            const next_op = self.runtime_code[push_end];

                            // Case 1: PUSH + JUMP (for fusion optimization)
                            if (next_op == @intFromEnum(Opcode.JUMP)) {
                                if (tracer) |t| {
                                    t.debug("Detected PUSH + JUMP fusion opportunity at pc={}, push_value={}, next_op={x}", .{ i, push_value, next_op });
                                }
                                // Note: We do NOT validate jump targets here - that happens at runtime
                                // This is only for marking fusion opportunities
                            }

                            // Case 2: PUSH + JUMPI (check if previous was also a PUSH)
                            else if (push_end < validate_up_to and next_op == @intFromEnum(Opcode.JUMPI) and
                                last_push_value != null and
                                last_push_end == i)
                            {
                                // We have PUSH(dest) + PUSH(cond) + JUMPI pattern
                                const jump_dest = last_push_value.?;
                                if (tracer) |t| {
                                    t.debug("Detected PUSH + PUSH + JUMPI fusion opportunity at pc={}, jump_dest={}, next_op={x}", .{ i, jump_dest, next_op });
                                }
                                // Note: We do NOT validate jump targets here - that happens at runtime
                            }
                        }

                        // Update state for next iteration
                        last_push_value = push_value;
                        last_push_end = push_end;
                    }

                    i = push_end;
                } else {
                    // Reset state when we see non-PUSH opcodes (unless it's JUMPI)
                    if (op != @intFromEnum(Opcode.JUMPI) and op != @intFromEnum(Opcode.JUMP)) {
                        last_push_value = null;
                        last_push_end = 0;
                    }
                    i += 1;
                }
            }
            // Note: We do NOT validate immediate jumps during bytecode initialization because:
            // 1. Not all PUSH+JUMP patterns in bytecode are actually executed (dead code, data sections)
            // 2. The EVM spec requires jump validation at execution time, not initialization time
            // 3. Validating jumps here would reject valid contracts that contain unreachable PUSH+JUMP patterns
            // The immediate jump detection above is ONLY for fusion optimization, not correctness validation.

            // Notify tracer of analysis completion
            if (tracer) |t| {
                t.onBytecodeAnalysisComplete(validate_up_to, opcode_count, jumpdest_count);
            }
        }


        /// Pretty print bytecode with human-readable formatting, colors, and metadata
        pub fn pretty_print(self: Self, allocator: std.mem.Allocator) ![]u8 {
            const opcode_data = @import("../opcodes/opcode_data.zig");

            // ANSI color codes
            const Colors = struct {
                const reset = "\x1b[0m";
                const bold = "\x1b[1m";
                const dim = "\x1b[2m";
                const red = "\x1b[31m";
                const green = "\x1b[32m";
                const yellow = "\x1b[33m";
                const blue = "\x1b[34m";
                const magenta = "\x1b[35m";
                const cyan = "\x1b[36m";
                const white = "\x1b[37m";
                const black = "\x1b[30m";
                const bright_red = "\x1b[91m";
                const bright_green = "\x1b[92m";
                const bright_yellow = "\x1b[93m";
                const bright_blue = "\x1b[94m";
                const bright_magenta = "\x1b[95m";
                const bright_cyan = "\x1b[96m";
                const bright_white = "\x1b[97m";
                const bg_yellow = "\x1b[43m";
                const bg_green = "\x1b[42m";
                const bg_red = "\x1b[41m";
                const bg_magenta = "\x1b[45m";
            };

            var output = std.ArrayListAligned(u8, null){};
            defer output.deinit(allocator);

            // Add new colors for different instruction categories

            const InstructionColors = struct {
                const push = Colors.blue;
                const arithmetic = Colors.cyan;
                const comparison = Colors.magenta;
                const bitwise = Colors.bright_cyan;
                const memory = Colors.bright_blue;
                const storage = Colors.bright_magenta;
                const jump_yellow = "\x1b[93m"; // Yellow for JUMP
                const jump_gold = "\x1b[33m"; // Gold (darker yellow) for JUMPI
                const jumpdest_bg = "\x1b[42m"; // Green background
                const stack = Colors.green;
                const flow_control = Colors.red;
                const system = Colors.bright_yellow;
            };

            // Header with improved styling
            try output.writer(allocator).print("\n{s}╔══════════════════════════════════════╗{s}\n", .{ Colors.bright_cyan, Colors.reset });
            try output.writer(allocator).print("{s}║     EVM Bytecode Disassembly         ║{s}\n", .{ Colors.bright_cyan, Colors.reset });
            try output.writer(allocator).print("{s}╚══════════════════════════════════════╝{s}\n\n", .{ Colors.bright_cyan, Colors.reset });

            try output.writer(allocator).print("{s}📊 Length: {s}{}{s} bytes{s}\n", .{ Colors.dim, Colors.bright_white, self.runtime_code.len, Colors.dim, Colors.reset });
            try output.writer(allocator).print("{s}📍 Legend: {s}{s}●{s}=JUMPDEST  {s}{s}⚡{s}=Fusion  {s}✗{s}=Invalid Jump{s}\n\n", .{ Colors.dim, InstructionColors.jumpdest_bg, Colors.black, Colors.reset, Colors.bg_green, Colors.black, Colors.reset, Colors.bg_red, Colors.reset, Colors.reset });

            // Column headers with stack depth
            try output.writer(allocator).print("{s} #   | PC   | Stack | Hex                     | Opcode         | Jump      | Details{s}\n", .{ Colors.bold, Colors.reset });
            try output.writer(allocator).print("{s}-----|------|-------|-------------------------|----------------|-----------|-------------------------------------------{s}\n", .{ Colors.dim, Colors.reset });

            // First pass: collect all JUMPs, JUMPIs and their targets
            var jump_map = std.ArrayList(struct { from_pc: PcType, to_pc: ?PcType, is_conditional: bool, line_from: u32, line_to: ?u32 }){};
            defer jump_map.deinit(allocator);
            var line_pc_map = std.ArrayList(struct { pc: PcType, line: u32 }){};
            defer line_pc_map.deinit(allocator);

            // First pass - build line/pc mapping
            var scan_pc: PcType = 0;
            var scan_line: u32 = 1;
            while (scan_pc < self.runtime_code.len) {
                try line_pc_map.append(allocator, .{ .pc = scan_pc, .line = scan_line });
                const op = self.runtime_code[scan_pc];
                const size: PcType = if (op >= 0x60 and op <= 0x7f) op - 0x5f + 1 else 1;
                scan_pc += size;
                scan_line += 1;
            }

            // Find JUMPs and their targets
            scan_pc = 0;
            scan_line = 1;
            while (scan_pc < self.runtime_code.len) {
                const op = self.runtime_code[scan_pc];

                // Check for JUMP or JUMPI preceded by PUSH
                if ((op == 0x56 or op == 0x57) and scan_pc > 0) {
                    // Look for preceding PUSH to get the jump target
                    var target: ?PcType = null;
                    var check_pc = if (scan_pc > 0) scan_pc - 1 else 0;

                    // Search backwards for a PUSH instruction
                    while (check_pc > 0 and scan_pc - check_pc < 33) : (check_pc -= 1) {
                        const prev_op = self.runtime_code[check_pc];
                        if (prev_op >= 0x60 and prev_op <= 0x7f) {
                            // Found a PUSH, extract the value
                            const push_size = prev_op - 0x5f;
                            if (check_pc + 1 + push_size == scan_pc) {
                                // This PUSH provides the value for our JUMP
                                var value: PcType = 0;
                                for (check_pc + 1..check_pc + 1 + push_size) |i| {
                                    value = (value << 8) | self.runtime_code[i];
                                }
                                target = value;
                                break;
                            }
                        }
                        if (check_pc == 0) break;
                    }

                    // Find line number for target
                    var target_line: ?u32 = null;
                    if (target) |t| {
                        for (line_pc_map.items) |mapping| {
                            if (mapping.pc == t) {
                                target_line = mapping.line;
                                break;
                            }
                        }
                    }

                    try jump_map.append(allocator, .{
                        .from_pc = scan_pc,
                        .to_pc = target,
                        .is_conditional = op == 0x57,
                        .line_from = scan_line,
                        .line_to = target_line,
                    });
                }

                const size: PcType = if (op >= 0x60 and op <= 0x7f) op - 0x5f + 1 else 1;
                scan_pc += size;
                scan_line += 1;
            }

            // Function to analyze a basic block
            const BlockInfo = struct {
                gas: u64,
                min_stack: u16,
                max_stack: u16,
                length: u32,
            };

            const analyzeBlock = struct {
                fn analyze(bytecode: *const Self, start_pc: PcType) BlockInfo {
                    var gas: u64 = 0;
                    var stack_effect: i32 = 0;
                    var min_stack: i32 = 0;
                    var max_stack: i32 = 0;
                    var current_pc = start_pc;
                    var length: u32 = 0;
                    const opcode_info = @import("../opcodes/opcode_data.zig").OPCODE_INFO;

                    while (current_pc < bytecode.runtime_code.len) {
                        const opcode = bytecode.runtime_code[current_pc];
                        length += 1;

                        // Add gas cost for this instruction
                        if (opcode < opcode_info.len) {
                            gas = std.math.add(u64, gas, opcode_info[opcode].gas_cost) catch std.math.maxInt(u64);

                            // Update stack effect
                            stack_effect -= opcode_info[opcode].stack_inputs;
                            if (stack_effect < min_stack) min_stack = stack_effect;
                            stack_effect += opcode_info[opcode].stack_outputs;
                            if (stack_effect > max_stack) max_stack = stack_effect;
                        }

                        // Move to next instruction
                        const instruction_size: PcType = if (opcode >= 0x60 and opcode <= 0x7f) opcode - 0x5f + 1 else 1;
                        current_pc += instruction_size;

                        // Check if this opcode terminates the block
                        const terminates = switch (opcode) {
                            0x00, // STOP
                            0x56, // JUMP
                            0x57, // JUMPI
                            0xf3, // RETURN
                            0xfd, // REVERT
                            0xfe, // INVALID
                            0xff, // SELFDESTRUCT
                            => true,
                            else => false,
                        };

                        if (terminates) break; // End of this block

                        // Check if next instruction is a JUMPDEST (starts new block)
                        if (current_pc < bytecode.runtime_code.len) {
                            const next_op = if (current_pc < bytecode.runtime_code.len) bytecode.runtime_code[current_pc] else 0x00;
                            if (next_op == 0x5b) break; // Next instruction is JUMPDEST, end this block
                        }
                    }

                    return .{
                        .gas = gas,
                        .min_stack = @intCast(@abs(min_stack)),
                        .max_stack = @intCast(@max(0, max_stack)),
                        .length = length,
                    };
                }
            }.analyze;

            // Track basic blocks and stack depth
            var pc: PcType = 0;
            var line_num: u32 = 1;
            var stack_depth: i32 = 0;
            var current_block: u32 = 0;
            var last_was_terminator = false;
            var block_start_line: u32 = 1;
            var block_start_pc: PcType = 0;

            while (pc < self.runtime_code.len) {
                const opcode_byte = self.runtime_code[pc];

                // Check if we're starting a new basic block
                const is_new_block = (pc == 0) or last_was_terminator or self.isValidJumpDest(pc);
                if (is_new_block) {
                    // Add blank line between blocks for visual separation (except for first block)
                    if (pc > 0) {
                        try output.writer(allocator).print("\n", .{});
                    }
                    if (pc == 0) {
                        block_start_pc = 0;
                    } else if (last_was_terminator or self.isValidJumpDest(pc)) {
                        if (last_was_terminator) current_block += 1;
                        block_start_line = line_num;
                        block_start_pc = pc;
                    }
                }

                // Add block header with analysis at start of each block
                if (is_new_block or line_num == block_start_line) {
                    const block_info = analyzeBlock(&self, block_start_pc);

                    // Format block header with gas, stack requirements, and length
                    try output.writer(allocator).print("{s}[Block {}]{s} ", .{
                        "\x1b[38;5;240m", // Very muted gray color
                        current_block,
                        Colors.reset,
                    });

                    // Add block analysis info
                    try output.writer(allocator).print("{s}gas: {}{s} ", .{
                        Colors.dim,
                        block_info.gas,
                        Colors.reset,
                    });

                    try output.writer(allocator).print("{s}stack: [{}, {}]{s} ", .{
                        Colors.dim,
                        block_info.min_stack,
                        block_info.max_stack,
                        Colors.reset,
                    });

                    try output.writer(allocator).print("{s}len: {}{s}\n", .{
                        Colors.dim,
                        block_info.length,
                        Colors.reset,
                    });

                    // Add green "Begin" marker for JUMPDEST blocks
                    if (self.isValidJumpDest(block_start_pc)) {
                        try output.writer(allocator).print("{s}{s} Begin {s}\n", .{
                            Colors.bg_green,
                            Colors.black,
                            Colors.reset,
                        });
                    }
                }

                // Line number
                try output.writer(allocator).print("{s}{d:4}{s} | ", .{ Colors.dim, line_num, Colors.reset });

                // PC address column (decimal)
                try output.writer(allocator).print("{s}{d:4}{s} | ", .{ Colors.cyan, pc, Colors.reset });

                // Stack depth column
                const stack_color = if (stack_depth < 0) Colors.red else if (stack_depth > 10) Colors.yellow else Colors.dim;
                try output.writer(allocator).print("{s}{d:5}{s} | ", .{ stack_color, stack_depth, Colors.reset });

                // Check if this is a jump destination or fusion candidate
                const is_jumpdest = self.isValidJumpDest(pc);
                const is_fusion = self.packed_bitmap[pc].is_fusion_candidate;

                // Raw hex bytes (show opcode + data for PUSH instructions)
                // Calculate instruction size based on opcode
                const instruction_size: usize = blk: {
                    if (opcode_byte >= 0x60 and opcode_byte <= 0x7f) {
                        // PUSH1-PUSH32: size = 1 + (opcode - 0x5f)
                        const push_size = opcode_byte - 0x5f;
                        break :blk 1 + push_size;
                    } else {
                        break :blk 1;
                    }
                };
                var hex_output = std.ArrayListAligned(u8, null){};
                defer hex_output.deinit(allocator);

                // Format the raw hex bytes first
                for (0..instruction_size) |i| {
                    if (pc + i < self.runtime_code.len) {
                        try hex_output.writer(allocator).print("{x:0>2}", .{self.runtime_code[pc + i]});
                        if (i + 1 < instruction_size) try hex_output.writer(allocator).print(" ", .{});
                    }
                }

                // Format the hex column with proper padding and optional markers
                if (is_jumpdest) {
                    // JUMPDEST marker - emoji takes ~2 display columns, so reduce padding by 2
                    try output.writer(allocator).print("{s}{s}●{s} {s}{s:<21}{s} | ", .{ InstructionColors.jumpdest_bg, Colors.black, Colors.reset, Colors.dim, hex_output.items, Colors.reset });
                } else if (is_fusion) {
                    // Fusion marker - emoji takes ~2 display columns, so reduce padding by 2
                    try output.writer(allocator).print("{s}{s}⚡{s} {s}{s:<20}{s} | ", .{ Colors.bg_green, Colors.black, Colors.reset, Colors.dim, hex_output.items, Colors.reset });
                } else {
                    // No marker, full width for hex bytes
                    try output.writer(allocator).print("{s}{s:<23}{s} | ", .{ Colors.dim, hex_output.items, Colors.reset });
                }

                // Parse and format the opcode name ONLY (no values)
                if (std.meta.intToEnum(Opcode, opcode_byte)) |opcode| {
                    // Store push value for later use in details column
                    var push_value: ?u256 = null;

                    switch (opcode) {
                        .PUSH0 => {
                            try output.writer(allocator).print("{s}{s:<14}{s}", .{ InstructionColors.push, @tagName(opcode), Colors.reset });
                            push_value = 0;
                        },
                        .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8, .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                            const push_size = @intFromEnum(opcode) - @intFromEnum(Opcode.PUSH1) + 1;
                            try output.writer(allocator).print("{s}{s:<14}{s}", .{ InstructionColors.push, @tagName(opcode), Colors.reset });

                            // Extract push value for details column
                            var value: u256 = 0;
                            const end_pc = @min(pc + 1 + push_size, self.len());
                            if (pc + 1 < self.len()) {
                                for (pc + 1..end_pc) |i| {
                                    value = std.math.shl(u256, value, 8) | self.get_unsafe(@intCast(i));
                                }
                                push_value = value;
                            }
                        },
                        .JUMPDEST => {
                            try output.writer(allocator).print("{s}{s}{s:<14}{s}", .{ InstructionColors.jumpdest_bg, Colors.black, @tagName(opcode), Colors.reset });
                        },
                        .JUMP => {
                            try output.writer(allocator).print("{s}{s:<14}{s}", .{ InstructionColors.jump_yellow, @tagName(opcode), Colors.reset });
                        },
                        .JUMPI => {
                            try output.writer(allocator).print("{s}{s:<14}{s}", .{ InstructionColors.jump_gold, @tagName(opcode), Colors.reset });
                        },
                        .STOP, .RETURN, .REVERT, .INVALID, .SELFDESTRUCT => {
                            try output.writer(allocator).print("{s}{s:<14}{s}", .{ InstructionColors.flow_control, @tagName(opcode), Colors.reset });
                        },
                        .ADD, .SUB, .MUL, .DIV, .SDIV, .MOD, .SMOD, .ADDMOD, .MULMOD, .EXP, .SIGNEXTEND => {
                            try output.writer(allocator).print("{s}{s:<14}{s}", .{ InstructionColors.arithmetic, @tagName(opcode), Colors.reset });
                        },
                        .LT, .GT, .SLT, .SGT, .EQ, .ISZERO => {
                            try output.writer(allocator).print("{s}{s:<14}{s}", .{ InstructionColors.comparison, @tagName(opcode), Colors.reset });
                        },
                        .AND, .OR, .XOR, .NOT, .BYTE, .SHL, .SHR, .SAR => {
                            try output.writer(allocator).print("{s}{s:<14}{s}", .{ InstructionColors.bitwise, @tagName(opcode), Colors.reset });
                        },
                        .MLOAD, .MSTORE, .MSTORE8, .MSIZE, .MCOPY => {
                            try output.writer(allocator).print("{s}{s:<14}{s}", .{ InstructionColors.memory, @tagName(opcode), Colors.reset });
                        },
                        .SLOAD, .SSTORE, .TLOAD, .TSTORE => {
                            try output.writer(allocator).print("{s}{s:<14}{s}", .{ InstructionColors.storage, @tagName(opcode), Colors.reset });
                        },
                        .POP, .DUP1, .DUP2, .DUP3, .DUP4, .DUP5, .DUP6, .DUP7, .DUP8, .DUP9, .DUP10, .DUP11, .DUP12, .DUP13, .DUP14, .DUP15, .DUP16, .SWAP1, .SWAP2, .SWAP3, .SWAP4, .SWAP5, .SWAP6, .SWAP7, .SWAP8, .SWAP9, .SWAP10, .SWAP11, .SWAP12, .SWAP13, .SWAP14, .SWAP15, .SWAP16 => {
                            try output.writer(allocator).print("{s}{s:<14}{s}", .{ InstructionColors.stack, @tagName(opcode), Colors.reset });
                        },
                        .ADDRESS, .BALANCE, .ORIGIN, .CALLER, .CALLVALUE, .CALLDATALOAD, .CALLDATASIZE, .CALLDATACOPY, .CODESIZE, .CODECOPY, .GASPRICE, .EXTCODESIZE, .EXTCODECOPY, .RETURNDATASIZE, .RETURNDATACOPY, .EXTCODEHASH, .BLOCKHASH, .COINBASE, .TIMESTAMP, .NUMBER, .DIFFICULTY, .GASLIMIT, .CHAINID, .SELFBALANCE, .BASEFEE, .BLOBHASH, .BLOBBASEFEE, .PC, .GAS, .CREATE, .CREATE2, .CALL, .CALLCODE, .DELEGATECALL, .STATICCALL, .LOG0, .LOG1, .LOG2, .LOG3, .LOG4, .KECCAK256 => {
                            try output.writer(allocator).print("{s}{s:<14}{s}", .{ InstructionColors.system, @tagName(opcode), Colors.reset });
                        },
                        else => {
                            try output.writer(allocator).print("{s}{s:<14}{s}", .{ Colors.white, @tagName(opcode), Colors.reset });
                        },
                    }

                    // Now handle the rest of the columns
                    // Jump visualization column
                    try output.writer(allocator).print(" | ", .{});

                    // Check if this line has a jump connection
                    var jump_visual = std.ArrayListAligned(u8, null){};
                    defer jump_visual.deinit(allocator);

                    // Find if this line is part of a jump
                    for (jump_map.items) |jump| {
                        if (jump.line_from == line_num) {
                            // This is where a jump originates
                            if (jump.to_pc) |target| {
                                if (jump.line_to) |target_line| {
                                    const color = if (jump.is_conditional) InstructionColors.jump_gold else InstructionColors.jump_yellow;
                                    if (target_line > line_num) {
                                        try jump_visual.writer(allocator).print("{s}┐→{d}{s}", .{ color, target, Colors.reset });
                                    } else {
                                        try jump_visual.writer(allocator).print("{s}┘→{d}{s}", .{ color, target, Colors.reset });
                                    }
                                } else {
                                    try jump_visual.writer(allocator).print("{s}→?{s}", .{ Colors.red, Colors.reset });
                                }
                            }
                            break; // Found the jump from this line
                        }
                    }
                    // Check if this PC is a jump destination
                    for (jump_map.items) |jump| {
                        if (jump.to_pc) |target| {
                            if (target == pc) {
                                if (self.isValidJumpDest(pc)) {
                                    // Valid jump destination
                                    const color = InstructionColors.jumpdest_bg;
                                    try jump_visual.writer(allocator).print("{s}←●{s}", .{ color, Colors.reset });
                                } else {
                                    // INVALID jump destination! This is a bug!
                                    try jump_visual.writer(allocator).print("{s}←✗{s}", .{ Colors.bg_red, Colors.reset });
                                }
                                break;
                            }
                        }
                    }

                    try output.writer(allocator).print("{s:<10}| ", .{jump_visual.items});

                    // Details column
                    if (push_value) |value| {
                        // Show push value in details
                        try output.writer(allocator).print("{s}0x{x}{s}", .{ Colors.bright_magenta, value, Colors.reset });
                        if (value <= 0xFFFF) {
                            try output.writer(allocator).print(" {s}({}){s} ", .{ Colors.dim, value, Colors.reset });
                        } else {
                            try output.writer(allocator).print(" ", .{});
                        }
                    }

                    // Add remaining details that apply to all opcodes
                    const opcode_info = opcode_data.OPCODE_INFO[opcode_byte];

                    // Special details for specific opcodes
                    if (opcode == .JUMPDEST) {
                        try output.writer(allocator).print("{s}[target: PC={d}]{s} ", .{ Colors.bright_green, pc, Colors.reset });
                    } else if (opcode == .JUMP) {
                        try output.writer(allocator).print("{s}[unconditional jump]{s} ", .{ InstructionColors.jump_yellow, Colors.reset });
                    } else if (opcode == .JUMPI) {
                        try output.writer(allocator).print("{s}[conditional jump]{s} ", .{ InstructionColors.jump_gold, Colors.reset });
                    }

                    // Gas cost
                    try output.writer(allocator).print("{s}[gas: {}]{s}", .{ Colors.dim, opcode_info.gas_cost, Colors.reset });

                    // Stack effects
                    if (opcode_info.stack_inputs > 0 or opcode_info.stack_outputs > 0) {
                        try output.writer(allocator).print(" {s}[stack: -{}, +{}]{s}", .{ Colors.dim, opcode_info.stack_inputs, opcode_info.stack_outputs, Colors.reset });
                        // Update stack depth based on this instruction
                        stack_depth = stack_depth - @as(i32, @intCast(opcode_info.stack_inputs)) + @as(i32, @intCast(opcode_info.stack_outputs));
                    }

                    // Check if this is a block terminator
                    last_was_terminator = switch (opcode) {
                        .STOP, .RETURN, .REVERT, .INVALID, .SELFDESTRUCT, .JUMP, .JUMPI => true,
                        else => false,
                    };
                } else |_| {
                    // Invalid opcode case
                    try output.writer(allocator).print("{s}INVALID(0x{x:0>2}){s}", .{ Colors.bright_red, opcode_byte, Colors.reset });
                    try output.writer(allocator).print(" | ", .{}); // Jump column
                    try output.writer(allocator).print("          | ", .{}); // Empty jump visual
                    last_was_terminator = true; // INVALID terminates block
                }

                // Check for fusion patterns and show what they fuse into
                if (self.packed_bitmap[pc].is_fusion_candidate) {
                    const fusion_data = self.getFusionData(pc);
                    switch (fusion_data) {
                        .push_add_fusion => try output.writer(allocator).print(" {s}⚡ PUSH+ADD{s}", .{ Colors.bright_green, Colors.reset }),
                        .push_mul_fusion => try output.writer(allocator).print(" {s}⚡ PUSH+MUL{s}", .{ Colors.bright_green, Colors.reset }),
                        .push_sub_fusion => try output.writer(allocator).print(" {s}⚡ PUSH+SUB{s}", .{ Colors.bright_green, Colors.reset }),
                        .push_mstore_fusion => try output.writer(allocator).print(" {s}⚡ PUSH+MSTORE{s}", .{ Colors.bright_green, Colors.reset }),
                        .push_mstore8_fusion => try output.writer(allocator).print(" {s}⚡ PUSH+MSTORE8{s}", .{ Colors.bright_green, Colors.reset }),
                        .push_mload_fusion => try output.writer(allocator).print(" {s}⚡ PUSH+MLOAD{s}", .{ Colors.bright_green, Colors.reset }),
                        .push_jump_fusion => try output.writer(allocator).print(" {s}⚡ PUSH+JUMP{s}", .{ Colors.bright_green, Colors.reset }),
                        .push_jumpi_fusion => try output.writer(allocator).print(" {s}⚡ PUSH+JUMPI{s}", .{ Colors.bright_green, Colors.reset }),
                        .push_and_fusion => try output.writer(allocator).print(" {s}⚡ PUSH+AND{s}", .{ Colors.bright_green, Colors.reset }),
                        .push_or_fusion => try output.writer(allocator).print(" {s}⚡ PUSH+OR{s}", .{ Colors.bright_green, Colors.reset }),
                        .push_xor_fusion => try output.writer(allocator).print(" {s}⚡ PUSH+XOR{s}", .{ Colors.bright_green, Colors.reset }),
                        .push_div_fusion => try output.writer(allocator).print(" {s}⚡ PUSH+DIV{s}", .{ Colors.bright_green, Colors.reset }),
                        .push_dup3_add => try output.writer(allocator).print(" {s}⚡ PUSH+DUP3+ADD{s}", .{ Colors.bright_green, Colors.reset }),
                        .push_add_dup1 => try output.writer(allocator).print(" {s}⚡ PUSH+ADD+DUP1{s}", .{ Colors.bright_green, Colors.reset }),
                        .multi_push => |mp| try output.writer(allocator).print(" {s}⚡ {}xPUSH{s}", .{ Colors.bright_green, mp.count, Colors.reset }),
                        .multi_pop => |mp| try output.writer(allocator).print(" {s}⚡ {}xPOP{s}", .{ Colors.bright_green, mp.count, Colors.reset }),
                        .iszero_jumpi => try output.writer(allocator).print(" {s}⚡ ISZERO+JUMPI{s}", .{ Colors.bright_green, Colors.reset }),
                        .dup2_mstore_push => try output.writer(allocator).print(" {s}⚡ DUP2+MSTORE+PUSH{s}", .{ Colors.bright_green, Colors.reset }),
                        .function_dispatch => try output.writer(allocator).print(" {s}⚡ FUNCTION_DISPATCH{s}", .{ Colors.bright_green, Colors.reset }),
                        .dup3_add_mstore => try output.writer(allocator).print(" {s}⚡ DUP3+ADD+MSTORE{s}", .{ Colors.bright_green, Colors.reset }),
                        .swap1_dup2_add => try output.writer(allocator).print(" {s}⚡ SWAP1+DUP2+ADD{s}", .{ Colors.bright_green, Colors.reset }),
                        .callvalue_check => try output.writer(allocator).print(" {s}⚡ CALLVALUE_CHECK{s}", .{ Colors.bright_green, Colors.reset }),
                        .push0_revert => try output.writer(allocator).print(" {s}⚡ PUSH0+REVERT{s}", .{ Colors.bright_green, Colors.reset }),
                        .mload_swap1_dup2 => try output.writer(allocator).print(" {s}⚡ MLOAD+SWAP1+DUP2{s}", .{ Colors.bright_green, Colors.reset }),
                        else => {},
                    }
                }

                try output.writer(allocator).print("\n", .{});

                pc += @intCast(instruction_size);
                line_num += 1;
            }

            // Footer with enhanced summary
            try output.writer(allocator).print("\n{s}╔══════════════════════════════════════╗{s}\n", .{ Colors.bright_cyan, Colors.reset });
            try output.writer(allocator).print("{s}║            Summary                   ║{s}\n", .{ Colors.bright_cyan, Colors.reset });
            try output.writer(allocator).print("{s}╚══════════════════════════════════════╝{s}\n", .{ Colors.bright_cyan, Colors.reset });

            // Count jump destinations and fusions
            var jumpdest_count: u32 = 0;
            var jump_count: u32 = 0;
            var jumpi_count: u32 = 0;
            var fusion_count: u32 = 0;
            var invalid_jump_count: u32 = 0;

            for (0..self.runtime_code.len) |i| {
                if (self.isValidJumpDest(@intCast(i))) {
                    jumpdest_count += 1;
                }
                if (i < self.runtime_code.len) {
                    const byte = self.runtime_code[i];
                    if (byte == 0x56) jump_count += 1;
                    if (byte == 0x57) jumpi_count += 1;
                }
                if (self.packed_bitmap[i].is_fusion_candidate) {
                    fusion_count += 1;
                }
            }

            // Count invalid jumps
            for (jump_map.items) |jump| {
                if (jump.to_pc) |target| {
                    if (!self.isValidJumpDest(target)) {
                        invalid_jump_count += 1;
                    }
                }
            }

            try output.writer(allocator).print("{s}📈 Basic blocks: {s}{}{s}\n", .{ Colors.dim, Colors.bright_white, current_block + 1, Colors.reset });
            try output.writer(allocator).print("{s}🎯 Jump destinations: {s}{}{s}\n", .{ Colors.dim, Colors.bright_green, jumpdest_count, Colors.reset });
            try output.writer(allocator).print("{s}➡️  Unconditional jumps: {s}{}{s}\n", .{ Colors.dim, Colors.bright_yellow, jump_count, Colors.reset });
            try output.writer(allocator).print("{s}❓ Conditional jumps: {s}{}{s}\n", .{ Colors.dim, Colors.yellow, jumpi_count, Colors.reset });
            if (invalid_jump_count > 0) {
                try output.writer(allocator).print("{s}⚠️  Invalid jumps: {s}{}{s}\n", .{ Colors.dim, Colors.bright_red, invalid_jump_count, Colors.reset });
            }
            try output.writer(allocator).print("{s}⚡ Fusion candidates: {s}{}{s}\n", .{ Colors.dim, Colors.bright_cyan, fusion_count, Colors.reset });
            try output.writer(allocator).print("{s}📝 Total instructions: {s}{}{s}\n", .{ Colors.dim, Colors.bright_white, line_num - 1, Colors.reset });

            // Stack analysis summary
            if (stack_depth != 0) {
                const stack_msg = if (stack_depth > 0) "⚠️  Final stack depth:" else "❌ Stack underflow:";
                const stack_color = if (stack_depth > 0) Colors.yellow else Colors.red;
                try output.writer(allocator).print("{s}{s} {s}{}{s}\n", .{ Colors.dim, stack_msg, stack_color, stack_depth, Colors.reset });
            }

            return output.toOwnedSlice(allocator);
        }
    };
}

const default_config = BytecodeConfig{};
pub const BytecodeDefault = Bytecode(default_config);
pub const BytecodeValidationError = BytecodeDefault.ValidationError;

// Export the factory function for creating Bytecode types
pub const createBytecode = Bytecode;

test "pretty_print: should format bytecode with colors and metadata" {
    const allocator = std.testing.allocator;

    // Simple bytecode: PUSH1 0x42, PUSH1 0x24, ADD, JUMPDEST, STOP
    const code = [_]u8{ 0x60, 0x42, 0x60, 0x24, 0x01, 0x5B, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    const formatted = try bytecode.pretty_print(allocator);
    defer allocator.free(formatted);

    // Expected output should contain:
    // - PC addresses (0x00, 0x02, etc.)
    // - Opcode names (PUSH1, ADD, JUMPDEST, STOP)
    // - Push values (0x42, 0x24)
    // - Gas costs
    // - Jump destinations highlighted
    // - ANSI colors

    const expected_parts = [_][]const u8{
        "0x00", // PC address
        "PUSH1", // Opcode name
        "0x42", // Push value
        "0x02", // Next PC
        "0x24", // Second push value
        "ADD", // Add opcode
        "JUMPDEST", // Jump destination
        "STOP", // Stop opcode
        "gas:", // Gas cost indicator
        "\x1b[", // ANSI escape sequence for colors
    };

    for (expected_parts) |part| {
        std.testing.expect(std.mem.indexOf(u8, formatted, part) != null) catch |err| {
            log.err("Expected to find '{s}' in:\n{s}", .{ part, formatted });
            return err;
        };
    }

    // Verify it's a valid string
    try std.testing.expect(formatted.len > 0);
}

test "pretty_print: enhanced visualization with JUMP/JUMPDEST/fusions" {
    std.testing.log_level = .err;
    const allocator = std.testing.allocator;

    // Complex bytecode with JUMPs, JUMPDESTs and fusion patterns
    const code = [_]u8{
        0x60, 0x0A, // PC=0: PUSH1 10
        0x60, 0x20, // PC=2: PUSH1 32 (fusion candidate with ADD)
        0x01, // PC=4: ADD
        0x60, 0x0B, // PC=5: PUSH1 11 (jump target)
        0x57, // PC=7: JUMPI (conditional jump)
        0x60, 0x0D, // PC=8: PUSH1 13 (jump to JUMPDEST at PC=13)
        0x56, // PC=10: JUMP (unconditional jump)
        0x5B, // PC=11: JUMPDEST (jump target 1)
        0x5F, // PC=12: PUSH0
        0x5B, // PC=13: JUMPDEST (jump target 2)
        0x00, // PC=14: STOP
    };

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    const formatted = try bytecode.pretty_print(allocator);
    defer allocator.free(formatted);

    // Log for visual inspection during test
    log.debug("\n=== Enhanced Pretty Print Output ===\n{s}", .{formatted});

    // Verify new features are present
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Legend") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, " PC") != null); // PC column header
    try std.testing.expect(std.mem.indexOf(u8, formatted, "[target:") != null or
        std.mem.indexOf(u8, formatted, "[unconditional") != null or
        std.mem.indexOf(u8, formatted, "[conditional") != null);

    // Verify formatting structure
    try std.testing.expect(std.mem.indexOf(u8, formatted, "---|------") != null); // Table separator
}

// Additional comprehensive test coverage for bytecode.zig

const testing = std.testing;

test "debug: fusion detection for CALL bytecode" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;

    // The exact bytecode from failing CALL test
    const test_bytecode = &[_]u8{
        0x5f, // PC=0: PUSH0
        0x5f, // PC=1: PUSH0
        0x5f, // PC=2: PUSH0
        0x5f, // PC=3: PUSH0
        0x5f, // PC=4: PUSH0
        0x30, // PC=5: ADDRESS
        0x61, // PC=6: PUSH2
        0x27, // PC=7: value byte 1
        0x10, // PC=8: value byte 2
        0xf1, // PC=9: CALL
        0x60, // PC=10: PUSH1
        0x00, // PC=11: value 0
        0x52, // PC=12: MSTORE
        0x60, // PC=13: PUSH1
        0x20, // PC=14: value 32
        0x60, // PC=15: PUSH1
        0x00, // PC=16: value 0
        0xf3, // PC=17: RETURN
    };

    const BytecodeType = Bytecode(.{
        .max_bytecode_size = 24576,
        .fusions_enabled = true,
    });

    var bytecode = try BytecodeType.init(allocator, test_bytecode);
    defer bytecode.deinit();

    var iter = bytecode.createIterator();
    var op_count: usize = 0;

    while (iter.next()) |_| {
        op_count += 1;
    }
}

test "Bytecode init - valid simple bytecode" {
    const allocator = testing.allocator;

    // Simple valid bytecode: PUSH1 0x01, PUSH1 0x02, ADD, STOP
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    try testing.expectEqual(@as(usize, 6), bytecode.len());
    try testing.expect(bytecode.isValidJumpDest(4) == false); // ADD is not a JUMPDEST
}

test "Bytecode init - empty bytecode" {
    const allocator = testing.allocator;

    const code = [_]u8{};
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    try testing.expectEqual(@as(usize, 0), bytecode.len());
}

test "Bytecode validation - undefined opcode treated as INVALID" {
    const allocator = testing.allocator;

    // Undefined opcode 0x0c (gap in opcode range) should be accepted as INVALID
    const code = [_]u8{0x0c};
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    try testing.expectEqual(@as(usize, 1), bytecode.len());
}

test "Bytecode validation - truncated PUSH instruction" {
    const allocator = testing.allocator;

    // PUSH1 without data byte
    const code = [_]u8{0x60};
    try testing.expectError(BytecodeDefault.ValidationError.TruncatedPush, BytecodeDefault.init(allocator, &code));
}

test "Bytecode validation - truncated PUSH32" {
    const allocator = testing.allocator;

    // PUSH32 with only 31 bytes of data (should have 32)
    var code = [_]u8{0x7F} ++ [_]u8{0xFF} ** 31;
    try testing.expectError(BytecodeDefault.ValidationError.TruncatedPush, BytecodeDefault.init(allocator, &code));
}

test "Jump destination validation - valid JUMPDEST" {
    const allocator = testing.allocator;

    // PUSH1 3, JUMP, JUMPDEST, STOP
    const code = [_]u8{ 0x60, 0x03, 0x56, 0x5B, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    try testing.expect(bytecode.isValidJumpDest(3) == true); // JUMPDEST at PC 3
    try testing.expect(bytecode.isValidJumpDest(0) == false); // PUSH1 is not a JUMPDEST
    try testing.expect(bytecode.isValidJumpDest(2) == false); // JUMP is not a JUMPDEST
}



test "Jump destination validation - JUMPI pattern" {
    const allocator = testing.allocator;

    // PUSH1 6, PUSH1 1, JUMPI, STOP, JUMPDEST, STOP
    const code = [_]u8{ 0x60, 0x06, 0x60, 0x01, 0x57, 0x00, 0x5B, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    try testing.expect(bytecode.isValidJumpDest(6) == true);
}

test "PUSH instruction handling - all PUSH sizes" {
    const allocator = testing.allocator;

    // Test PUSH1 through PUSH4
    const push1_code = [_]u8{ 0x60, 0x42, 0x00 }; // PUSH1 0x42, STOP
    var bytecode1 = try BytecodeDefault.init(allocator, &push1_code);
    defer bytecode1.deinit();

    const push2_code = [_]u8{ 0x61, 0x12, 0x34, 0x00 }; // PUSH2 0x1234, STOP
    var bytecode2 = try BytecodeDefault.init(allocator, &push2_code);
    defer bytecode2.deinit();

    const push4_code = [_]u8{ 0x63, 0x12, 0x34, 0x56, 0x78, 0x00 }; // PUSH4 0x12345678, STOP
    var bytecode4 = try BytecodeDefault.init(allocator, &push4_code);
    defer bytecode4.deinit();

    try testing.expectEqual(@as(usize, 3), bytecode1.len());
    try testing.expectEqual(@as(usize, 4), bytecode2.len());
    try testing.expectEqual(@as(usize, 6), bytecode4.len());
}

test "PUSH value reading - readPushValue" {
    const allocator = testing.allocator;

    // PUSH4 0x12345678, STOP
    const code = [_]u8{ 0x63, 0x12, 0x34, 0x56, 0x78, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    const value = bytecode.readPushValue(0, 4);
    try testing.expect(value != null);
    try testing.expectEqual(@as(u32, 0x12345678), value.?);
}

test "PUSH value reading - readPushValueN" {
    const allocator = testing.allocator;

    // PUSH8 with max value that fits in u64
    const code = [_]u8{ 0x67, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    const value = bytecode.readPushValueN(0, 8);
    try testing.expect(value != null);
    try testing.expectEqual(@as(u256, 0xFFFFFFFFFFFFFFFF), value.?);
}

test "Iterator functionality - basic iteration" {
    const allocator = testing.allocator;

    // PUSH1 0x42, ADD, JUMPDEST, STOP
    const code = [_]u8{ 0x60, 0x42, 0x01, 0x5B, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    var iter = bytecode.createIterator();

    // First instruction: PUSH1
    var opcode_data = iter.next();
    try testing.expect(opcode_data != null);
    switch (opcode_data.?) {
        .push => |p| {
            try testing.expectEqual(@as(u8, 1), p.size);
            try testing.expectEqual(@as(u256, 0x42), p.value);
        },
        else => return error.UnexpectedToken,
    }

    // Second instruction: ADD (should skip push data)
    opcode_data = iter.next();
    try testing.expect(opcode_data != null);
    switch (opcode_data.?) {
        .regular => |r| try testing.expectEqual(@as(u8, 0x01), r.opcode),
        else => return error.UnexpectedToken,
    }

    // Third instruction: JUMPDEST
    opcode_data = iter.next();
    try testing.expect(opcode_data != null);
    switch (opcode_data.?) {
        .jumpdest => |j| {
            _ = j; // gas_cost checked elsewhere
        },
        else => return error.UnexpectedToken,
    }

    // Fourth instruction: STOP
    opcode_data = iter.next();
    try testing.expect(opcode_data != null);
    switch (opcode_data.?) {
        .stop => {},
        else => return error.UnexpectedToken,
    }

    // Should be at end
    opcode_data = iter.next();
    try testing.expect(opcode_data == null);
}

test "Bitmap operations - push data detection" {
    const allocator = testing.allocator;

    // PUSH2 0x1234, STOP
    const code = [_]u8{ 0x61, 0x12, 0x34, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // PC 0: PUSH2 instruction (not push data)
    try testing.expect(!bytecode.packed_bitmap[0].is_push_data);
    try testing.expect(bytecode.packed_bitmap[0].is_op_start);

    // PC 1, 2: Push data bytes
    try testing.expect(bytecode.packed_bitmap[1].is_push_data);
    try testing.expect(!bytecode.packed_bitmap[1].is_op_start);
    try testing.expect(bytecode.packed_bitmap[2].is_push_data);
    try testing.expect(!bytecode.packed_bitmap[2].is_op_start);

    // PC 3: STOP instruction
    try testing.expect(!bytecode.packed_bitmap[3].is_push_data);
    try testing.expect(bytecode.packed_bitmap[3].is_op_start);
}

test "Instruction size calculation - getInstructionSize" {
    const allocator = testing.allocator;

    // PUSH1 0x42, PUSH4 0x12345678, ADD, STOP
    const code = [_]u8{ 0x60, 0x42, 0x63, 0x12, 0x34, 0x56, 0x78, 0x01, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    try testing.expectEqual(@as(BytecodeDefault.PcType, 2), bytecode.getInstructionSize(0)); // PUSH1
    try testing.expectEqual(@as(BytecodeDefault.PcType, 5), bytecode.getInstructionSize(2)); // PUSH4
    try testing.expectEqual(@as(BytecodeDefault.PcType, 1), bytecode.getInstructionSize(7)); // ADD
    try testing.expectEqual(@as(BytecodeDefault.PcType, 1), bytecode.getInstructionSize(8)); // STOP
}

test "PC navigation - getNextPc" {
    const allocator = testing.allocator;

    // PUSH2 0x1234, ADD, STOP
    const code = [_]u8{ 0x61, 0x12, 0x34, 0x01, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    try testing.expectEqual(@as(?BytecodeDefault.PcType, 3), bytecode.getNextPc(0)); // PUSH2 -> ADD
    try testing.expectEqual(@as(?BytecodeDefault.PcType, 4), bytecode.getNextPc(3)); // ADD -> STOP
    try testing.expectEqual(@as(?BytecodeDefault.PcType, null), bytecode.getNextPc(4)); // STOP -> end
}

test "Fusion candidate detection" {
    const allocator = testing.allocator;

    // PUSH1 0x42, ADD, PUSH1 0x24, MUL, STOP
    const code = [_]u8{ 0x60, 0x42, 0x01, 0x60, 0x24, 0x02, 0x00 };
    const config = BytecodeConfig{
        .max_bytecode_size = 1024,
        .fusions_enabled = true,
    };
    const TestBytecode = Bytecode(config);
    var bytecode = try TestBytecode.init(allocator, &code);
    defer bytecode.deinit();

    // PUSH1 at PC 0 followed by ADD should be fusion candidate
    try testing.expect(bytecode.packed_bitmap[0].is_fusion_candidate);

    // PUSH1 at PC 3 followed by MUL should be fusion candidate
    try testing.expect(bytecode.packed_bitmap[3].is_fusion_candidate);
}

test "Large bytecode handling - EIP-170 limit" {
    const allocator = testing.allocator;

    // Test bytecode exactly at EIP-170 limit (24576 bytes)
    const max_size = 24576;
    const large_code = try allocator.alloc(u8, max_size);
    defer allocator.free(large_code);

    // Fill with STOP opcodes (valid)
    @memset(large_code, 0x00);

    var bytecode = try BytecodeDefault.init(allocator, large_code);
    defer bytecode.deinit();

    try testing.expectEqual(@as(usize, max_size), bytecode.len());
}

test "Complex jump patterns - multiple JUMPDESTs" {
    const allocator = testing.allocator;

    // PUSH1 5, JUMP, PUSH1 9, JUMP, JUMPDEST (PC 5), PUSH1 7, JUMP, STOP, JUMPDEST (PC 9), STOP
    const code = [_]u8{ 0x60, 0x05, 0x56, 0x60, 0x09, 0x56, 0x5B, 0x60, 0x07, 0x56, 0x00, 0x5B, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    try testing.expect(bytecode.isValidJumpDest(6) == true); // JUMPDEST at PC 6
    try testing.expect(bytecode.isValidJumpDest(11) == true); // JUMPDEST at PC 11
    try testing.expect(bytecode.isValidJumpDest(0) == false); // PUSH1 is not a JUMPDEST
}


test "Bitmap utility functions - countBitsInRange" {
    // Test the bitmap counting utility
    const bitmap = [_]u8{ 0b10101010, 0b11110000, 0b00001111 };

    const count1 = countBitsInRange(&bitmap, 0, 8);
    try testing.expectEqual(@as(usize, 4), count1); // First byte has 4 bits set

    const count2 = countBitsInRange(&bitmap, 8, 16);
    try testing.expectEqual(@as(usize, 4), count2); // Second byte has 4 bits set

    const count3 = countBitsInRange(&bitmap, 0, 24);
    try testing.expectEqual(@as(usize, 12), count3); // All three bytes have 12 bits total
}

test "Bitmap utility functions - findNextSetBit" {
    // Test finding next set bit in bitmap
    const bitmap = [_]u8{ 0b00000000, 0b00010000, 0b00000001 };

    const next_bit1 = findNextSetBit(&bitmap, 0);
    try testing.expectEqual(@as(?usize, 12), next_bit1); // Bit 12 (4th bit of second byte)

    const next_bit2 = findNextSetBit(&bitmap, 13);
    try testing.expectEqual(@as(?usize, 23), next_bit2); // Bit 23 (7th bit of third byte)

    const next_bit3 = findNextSetBit(&bitmap, 24);
    try testing.expectEqual(@as(?usize, null), next_bit3); // No more set bits
}

test "Initcode gas calculation - EIP-3860" {
    // Test initcode gas calculation per EIP-3860
    const gas1 = BytecodeDefault.calculateInitcodeGas(32);
    try testing.expectEqual(@as(u64, 2), gas1); // 32 bytes = 1 word = 2 gas

    const gas2 = BytecodeDefault.calculateInitcodeGas(64);
    try testing.expectEqual(@as(u64, 4), gas2); // 64 bytes = 2 words = 4 gas

    const gas3 = BytecodeDefault.calculateInitcodeGas(33);
    try testing.expectEqual(@as(u64, 4), gas3); // 33 bytes = 2 words (rounded up) = 4 gas

    const gas4 = BytecodeDefault.calculateInitcodeGas(0);
    try testing.expectEqual(@as(u64, 0), gas4); // 0 bytes = 0 gas
}

test "Memory management - proper cleanup" {
    const allocator = testing.allocator;

    // Test that multiple init/deinit cycles work properly
    for (0..10) |_| {
        const code = [_]u8{ 0x60, 0x42, 0x01, 0x5B, 0x00 };
        var bytecode = try BytecodeDefault.init(allocator, &code);
        defer bytecode.deinit();

        try testing.expectEqual(@as(usize, 5), bytecode.len());
    }
}

/// Count set bits in a bitmap range
pub fn countBitsInRange(bitmap: []const u8, start: usize, end: usize) usize {
    var count: usize = 0;
    const start_byte = start / 8;
    const end_byte = (end + 7) / 8;
    
    for (start_byte..@min(end_byte, bitmap.len)) |i| {
        const byte = bitmap[i];
        const start_bit = if (i == start_byte) start % 8 else 0;
        const end_bit = if (i == end_byte - 1) end % 8 else 8;
        
        for (start_bit..end_bit) |bit| {
            if ((byte >> @intCast(bit)) & 1 == 1) {
                count += 1;
            }
        }
    }
    return count;
}

/// Find the next set bit in a bitmap starting from a given position
pub fn findNextSetBit(bitmap: []const u8, start: usize) ?usize {
    const start_byte = start / 8;
    const start_bit = start % 8;
    
    for (start_byte..bitmap.len) |i| {
        const byte = bitmap[i];
        const first_bit = if (i == start_byte) start_bit else 0;
        
        for (first_bit..8) |bit| {
            if ((byte >> @intCast(bit)) & 1 == 1) {
                return i * 8 + bit;
            }
        }
    }
    return null;
}

test "Edge cases - single byte bytecode" {
    const allocator = testing.allocator;

    // Single STOP instruction
    const code = [_]u8{0x00};
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    try testing.expectEqual(@as(usize, 1), bytecode.len());
    try testing.expect(bytecode.packed_bitmap[0].is_op_start);
    try testing.expect(!bytecode.packed_bitmap[0].is_push_data);
    try testing.expect(!bytecode.packed_bitmap[0].is_jumpdest);
}

test "Edge cases - maximum PUSH32 instruction" {
    const allocator = testing.allocator;

    // PUSH32 with 32 bytes of data
    var code = [_]u8{0x7F} ++ [_]u8{0xFF} ** 32 ++ [_]u8{0x00}; // PUSH32 + 32 bytes + STOP
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    try testing.expectEqual(@as(usize, 34), bytecode.len()); // PUSH32 + 32 data bytes + STOP

    // Verify push data is marked correctly
    for (1..33) |i| {
        try testing.expect(bytecode.packed_bitmap[i].is_push_data);
        try testing.expect(!bytecode.packed_bitmap[i].is_op_start);
    }
}

test "Boundary conditions - jump to last instruction" {
    const allocator = testing.allocator;

    // PUSH1 3, JUMP, JUMPDEST
    const code = [_]u8{ 0x60, 0x03, 0x56, 0x5B };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    try testing.expect(bytecode.isValidJumpDest(3) == true);
}


test "Invalid jump - jumping to non-JUMPDEST opcode" {
    const allocator = testing.allocator;

    // This test reproduces the bug from 15_test.zig where we jump to position 37
    // instead of position 36 where the JUMPDEST is located
    // PUSH32 value (33 bytes total), PUSH1 37, JUMP, JUMPDEST (at 36), ISZERO (at 37)
    var code = std.ArrayList(u8){};
    defer code.deinit(allocator);

    // PUSH32 with value 0
    try code.append(allocator, 0x7F); // PUSH32 opcode
    try code.appendNTimes(allocator, 0x00, 32); // 32 zero bytes

    // PUSH1 37 - incorrect jump destination (should be 36)
    try code.append(allocator, 0x60); // PUSH1
    try code.append(allocator, 37); // Jump to position 37 (ISZERO) instead of 36 (JUMPDEST)

    // JUMP
    try code.append(allocator, 0x56);

    // JUMPDEST at position 36
    try code.append(allocator, 0x5B);

    // ISZERO at position 37
    try code.append(allocator, 0x15);

    // STOP
    try code.append(allocator, 0x00);

    // This bytecode is valid from a structural perspective (no truncated pushes)
    // but contains an invalid jump that should be caught at runtime
    var bytecode = try BytecodeDefault.init(allocator, code.items);
    defer bytecode.deinit();

    // Verify that position 36 is a valid JUMPDEST
    try testing.expect(bytecode.isValidJumpDest(36) == true);

    // Verify that position 37 is NOT a valid JUMPDEST (it's an ISZERO opcode)
    try testing.expect(bytecode.isValidJumpDest(37) == false);

    // The bytecode itself is valid - the invalid jump will be caught at runtime
    // This test documents that bytecode validation does NOT catch runtime jump errors
}

test "Valid jump - jumping to correct JUMPDEST" {
    const allocator = testing.allocator;

    // Same as above but with correct jump destination
    var code = std.ArrayList(u8){};
    defer code.deinit(allocator);

    // PUSH32 with value 0
    try code.append(allocator, 0x7F); // PUSH32 opcode
    try code.appendNTimes(allocator, 0x00, 32); // 32 zero bytes

    // PUSH1 36 - correct jump destination
    try code.append(allocator, 0x60); // PUSH1
    try code.append(allocator, 36); // Jump to position 36 (JUMPDEST)

    // JUMP
    try code.append(allocator, 0x56);

    // JUMPDEST at position 36
    try code.append(allocator, 0x5B);

    // ISZERO at position 37
    try code.append(allocator, 0x15);

    // STOP
    try code.append(allocator, 0x00);

    var bytecode = try BytecodeDefault.init(allocator, code.items);
    defer bytecode.deinit();

    // Verify that position 36 is a valid JUMPDEST
    try testing.expect(bytecode.isValidJumpDest(36) == true);

    // This is valid bytecode with a valid jump
}

test "Minimal repro - deployment bytecode with apparent truncated PUSH" {
    const allocator = testing.allocator;

    // Minimal case that triggers TruncatedPush
    // This simulates the end of deployment bytecode where a PUSH instruction
    // appears to be truncated but is actually part of the constructor return data
    const code = [_]u8{
        0x60, 0x80, // PUSH1 0x80
        0x60, 0x40, // PUSH1 0x40
        0x52, // MSTORE
        0x60, 0x97, // PUSH1 0x97 (size of runtime code)
        0x80, // DUP1
        0x60, 0x1a, // PUSH1 0x1a (offset in memory)
        0x5f, // PUSH0
        0x39, // CODECOPY
        0x5f, // PUSH0
        0xf3, // RETURN
        0xfe, // INVALID (start of runtime code)
        0x60, // PUSH1 without data - this triggers TruncatedPush
    };

    // This should fail with TruncatedPush because the last byte is PUSH1 without data
    try testing.expectError(BytecodeDefault.ValidationError.TruncatedPush, BytecodeDefault.init(allocator, &code));
}

test "Deployment bytecode - actual ten-thousand-hashes fixture" {
    const allocator = testing.allocator;

    // First 32 bytes of the actual ten-thousand-hashes bytecode that's failing
    // This is deployment bytecode that ends with what looks like a truncated PUSH
    const code = [_]u8{
        0x60, 0x80, 0x60, 0x40, 0x52, 0x34, 0x80, 0x15,
        0x60, 0x0e, 0x57, 0x5f, 0x5f, 0xfd, 0x5b, 0x50,
        0x60, 0x97, 0x80, 0x60, 0x1a, 0x5f, 0x39, 0x5f,
        0xf3, 0xfe, // RETURN opcode followed by INVALID
        0x60, 0x80, 0x60, 0x40, 0x52, 0x34, // Start of runtime bytecode
        0x80, 0x15, 0x60, // This ends with 0x60 (PUSH1) without the data byte
    };

    // This should fail because it ends with an incomplete PUSH1
    try testing.expectError(BytecodeDefault.ValidationError.TruncatedPush, BytecodeDefault.init(allocator, &code));
}

test "Iterator should not read past truncated PUSH32" {
    const allocator = testing.allocator;

    // PUSH32 with only 31 bytes of data (malformed)
    // Total: 1 byte opcode + 31 bytes data = 32 bytes (should be 33)
    var code = [_]u8{0x7F} ++ [_]u8{0x00} ** 31; // PUSH32 (truncated)

    // This should fail validation
    try testing.expectError(BytecodeDefault.ValidationError.TruncatedPush, BytecodeDefault.init(allocator, &code));
}

test "Deployment vs Runtime bytecode handling" {
    const allocator = testing.allocator;

    // Simplified deployment bytecode that deploys a simple runtime code
    // Constructor bytecode that returns runtime bytecode
    const deployment_code = [_]u8{
        // Constructor code
        0x60, 0x04, // PUSH1 0x04 (size of runtime code)
        0x80, // DUP1
        0x60, 0x0c, // PUSH1 0x0c (offset of runtime code)
        0x5f, // PUSH0 (destination in memory)
        0x39, // CODECOPY
        0x5f, // PUSH0 (offset in memory)
        0xf3, // RETURN
        // Runtime code (what gets deployed)
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x55, // SSTORE
        0x00, // STOP
    };

    // This should work because it's complete deployment bytecode
    var bytecode = try BytecodeDefault.init(allocator, &deployment_code);
    defer bytecode.deinit();

    // The bytecode init detects deployment pattern and uses full code
    try testing.expect(bytecode.runtime_code.len == deployment_code.len);
}

test "Bytecode with Solidity metadata - ipfs format" {
    const allocator = testing.allocator;

    // Real bytecode pattern with IPFS metadata
    const code_with_metadata = [_]u8{
        // Some valid bytecode
        0x60, 0x80, // PUSH1 0x80
        0x60, 0x40, // PUSH1 0x40
        0x52, // MSTORE
        0x00, // STOP
        // IPFS metadata (CBOR encoded)
        0xa2, // CBOR map with 2 entries
        0x64, // string of length 4
        0x69, 0x70, 0x66, 0x73, // "ipfs"
        0x58, 0x22, // bytes of length 34
        // 34 bytes of IPFS hash would follow...
        0x12, 0x20, // multihash: SHA256
    } ++ [_]u8{0xAA} ** 32 ++ // 32 bytes of hash data
        [_]u8{
            0x64, // string of length 4
            0x73, 0x6f, 0x6c, 0x63, // "solc"
            0x43, // bytes of length 3
            0x00, 0x08, 0x13, // version 0.8.19
        };

    var bytecode = try BytecodeDefault.init(allocator, &code_with_metadata);
    defer bytecode.deinit();

    // Should detect metadata and trim to just the actual code
    try testing.expectEqual(@as(usize, 6), bytecode.runtime_code.len);
    try testing.expectEqual(@as(u8, 0x60), bytecode.runtime_code[0]);
    try testing.expectEqual(@as(u8, 0x00), bytecode.runtime_code[5]);
}

test "Bytecode with Solidity metadata - bzzr format" {
    const allocator = testing.allocator;

    // Older Solidity versions use bzzr0 or bzzr1 format
    const code_with_metadata = [_]u8{
        // Some valid bytecode
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x02, // PUSH1 0x02
        0x01, // ADD
        0x00, // STOP
        // bzzr metadata (CBOR encoded)
        0xa1, // CBOR map with 1 entry
        0x65, // string of length 5
        0x62, 0x7a, 0x7a, 0x72, 0x30, // "bzzr0"
        0x58, 0x20, // bytes of length 32
    } ++ [_]u8{0xBB} ** 32; // 32 bytes of swarm hash

    var bytecode = try BytecodeDefault.init(allocator, &code_with_metadata);
    defer bytecode.deinit();

    // Should detect metadata and trim to just the actual code
    try testing.expectEqual(@as(usize, 6), bytecode.runtime_code.len);
    try testing.expectEqual(@as(u8, 0x60), bytecode.runtime_code[0]);
    try testing.expectEqual(@as(u8, 0x00), bytecode.runtime_code[5]);
}

test "Bytecode without metadata should remain unchanged" {
    const allocator = testing.allocator;

    // Bytecode without any metadata
    const clean_code = [_]u8{
        0x60, 0x80, // PUSH1 0x80
        0x60, 0x40, // PUSH1 0x40
        0x52, // MSTORE
        0x34, // CALLVALUE
        0x80, // DUP1
        0x15, // ISZERO
        0x60, 0x0e, // PUSH1 0x0e
        0x57, // JUMPI
        0x00, // STOP
    };

    var bytecode = try BytecodeDefault.init(allocator, &clean_code);
    defer bytecode.deinit();

    // Should not modify bytecode without metadata
    try testing.expectEqual(clean_code.len, bytecode.runtime_code.len);
    try testing.expectEqualSlices(u8, &clean_code, bytecode.runtime_code);
}
