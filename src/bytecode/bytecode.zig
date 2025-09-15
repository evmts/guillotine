/// EVM bytecode representation and validation
///
/// Provides safe bytecode handling with:
/// - Size validation (max 24576 bytes per EIP-170)
/// - Format validation and parsing
/// - Security-conscious design preventing buffer overflows
/// - Integration with the Planner system for analysis
/// - Support for both raw bytecode and analyzed instruction streams
///
/// All bytecode operations are bounds-checked and memory-safe.
const std = @import("std");
const log = @import("../log.zig");
const builtin = @import("builtin");
const ArrayList = std.ArrayListAligned;
const Opcode = @import("../opcodes/opcode.zig").Opcode;
const bytecode_config = @import("bytecode_config.zig");
const BytecodeConfig = bytecode_config.BytecodeConfig;

// SECURITY MODEL: Untrusted Bytecode Validation
// ==============================================
// This module implements a two-phase security model for handling untrusted EVM bytecode:
//
// NOTE: This implementation does not support EOF (Ethereum Object Format) EIPs including:
// - EIP-3540: EOF - EVM Object Format v1
// - EIP-3670: EOF - Code Validation
// - EIP-4750: EOF - Functions
// - EIP-5450: EOF - Stack Validation
//
// Phase 1 - Validation (in init/buildBitmapsAndValidate):
// - Treat ALL bytecode as untrusted and potentially malicious
// - Use safe std library functions (e.g., std.meta.intToEnum) that perform runtime checks
// - Validate ALL assumptions about bytecode structure
// - Check for invalid opcodes, truncated PUSH instructions, invalid jump destinations
// - Build validated bitmaps that mark safe regions of code
//
// Phase 2 - Execution (after successful validation):
// - Once bytecode passes validation, we can use unsafe builtins for performance
// - @intFromEnum and @enumFromInt have no safety checks in release mode
// - We can use these because we've already validated all opcodes are valid
// - Bitmap lookups ensure we only execute at valid positions
//
// CRITICAL: Never use unsafe builtins during validation phase!
// CRITICAL: Never trust bytecode indices without checking bitmaps first!

// Constants for magic numbers used throughout the bytecode module
// These constants replace magic numbers to improve code readability and maintainability
const BITS_PER_BYTE = 8;
const BITMAP_SHIFT = 3; // log2(BITS_PER_BYTE) for efficient division by 8
const BITMAP_MASK = 7; // BITS_PER_BYTE - 1 for modulo 8
const INITCODE_GAS_PER_WORD = 2; // EIP-3860: 2 gas per 32-byte word
const BYTES_PER_WORD = 32; // EVM word size in bytes
const MAX_PUSH_BYTES = 32; // Maximum bytes for PUSH32
const OPCODE_TABLE_SIZE = 256; // Total possible opcode values (0x00-0xFF)
const CACHE_LINE_SIZE = 64; // Common cache line size for x86-64 and ARM64
const PREFETCH_DISTANCE = 256; // How far ahead to prefetch in bytes

/// Factory function to create a Bytecode type with the given configuration
pub fn Bytecode(comptime cfg: BytecodeConfig) type {
    comptime cfg.validate();

    return struct {
        pub const fusions_enabled = cfg.fusions_enabled;
        pub const ValidationError = error{
            InvalidOpcode,
            TruncatedPush,
            InvalidJumpDestination,
            OutOfMemory,
            InitcodeTooLarge,
            BytecodeTooLarge,
        };

        pub const Stats = @import("bytecode_stats.zig").BytecodeStats;
        pub const PcType = cfg.PcType();

        const Self = @This();

        // Packed 4-bit data per bytecode byte
        const PackedBits = packed struct(u4) {
            is_push_data: bool, // This byte is PUSH operand data
            is_op_start: bool, // This byte starts an instruction
            is_jumpdest: bool, // This byte is a valid JUMPDEST
            is_fusion_candidate: bool, // This byte can be part of fusion
        };

        /// Simple bytecode analysis for Schedule generation
        /// This replaces complex planner logic with straightforward analysis
        pub const Analysis = struct {
            jump_destinations: std.ArrayList(JumpDestInfo),
            push_data: std.ArrayList(PushInfo),

            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                self.jump_destinations.deinit(allocator);
                self.push_data.deinit(allocator);
            }
        };

        pub const JumpDestInfo = struct {
            pc: PcType,
            gas_cost: u32 = 1, // Static gas cost for JUMPDEST
        };

        pub const PushInfo = struct {
            pc: PcType,
            size: u8, // 1-32 bytes
            value: u256, // The actual pushed value
            is_inline: bool, // true if <= 8 bytes (can inline)
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

        // Iterator for efficient bytecode traversal
        pub const Iterator = struct {
            bytecode: *const Self,
            pc: PcType,

            pub fn next(iterator: *Iterator) ?OpcodeData {
                if (iterator.pc >= iterator.bytecode.len()) return null;

                const opcode = iterator.bytecode.get_unsafe(iterator.pc);
                // Check if packed_bitmap has enough elements
                if (iterator.pc >= iterator.bytecode.packed_bitmap.len) {
                    // Log error and return null
                    log.err("Iterator PC {} exceeds packed_bitmap len {}", .{ iterator.pc, iterator.bytecode.packed_bitmap.len });
                    return null;
                }
                const packed_bits = iterator.bytecode.packed_bitmap[iterator.pc];

                // Debug logging for observability
                log.debug("Iterator.next: PC={d}, opcode=0x{x:0>2}, packed_bits={{push_data={}, op_start={}, jumpdest={}, fusion={}}}", .{
                    iterator.pc,
                    opcode,
                    packed_bits.is_push_data,
                    packed_bits.is_op_start,
                    packed_bits.is_jumpdest,
                    packed_bits.is_fusion_candidate,
                });

                // Handle fusion opcodes first (only if fusions are enabled)
                if (fusions_enabled and packed_bits.is_fusion_candidate) {
                    log.debug("  Checking for fusion at PC={d}", .{iterator.pc});
                    const fusion_data = iterator.bytecode.getFusionData(iterator.pc);
                    log.debug("  Fusion detected: {any}", .{fusion_data});
                    // Advance PC properly for fusion opcodes
                    switch (fusion_data) {
                        // 2-opcode fusions: PUSH + op
                        .push_add_fusion, .push_mul_fusion, .push_sub_fusion, .push_div_fusion, 
                        .push_and_fusion, .push_or_fusion, .push_xor_fusion, 
                        .push_jump_fusion, .push_jumpi_fusion,
                        .push_mload_fusion, .push_mstore_fusion, .push_mstore8_fusion => {
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
                        const block_gas = iterator.calculateBlockGasAtJumpdest();
                        iterator.pc += 1;
                        return OpcodeData{ .jumpdest = .{ .gas_cost = @intCast(block_gas) } };
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
            
            // Calculate gas cost for the block starting at current JUMPDEST
            pub fn calculateBlockGasAtJumpdest(iterator: *Iterator) u32 {
                const opcode_info = @import("../opcodes/opcode_data.zig").OPCODE_INFO;
                var gas: u32 = 1; // JUMPDEST itself costs 1 gas
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
                        0xFF  // SELFDESTRUCT
                        => {
                            return gas;
                        },
                        0x60...0x7F => { // PUSH1-PUSH32
                            gas += opcode_info[opcode].gas_cost;
                            const push_size = opcode - 0x5F;
                            pc += 1 + push_size;
                        },
                        else => {
                            gas += opcode_info[opcode].gas_cost;
                            pc += 1;
                        },
                    }
                }
                
                return gas;
            }
        };

        // Tagged union for opcode data returned by iterator
        pub const OpcodeData = union(enum) {
            regular: struct { opcode: u8 },
            push: struct { value: u256, size: u8 },
            jumpdest: struct { gas_cost: u16 },
            jump: void,  // Dynamic JUMP (not fused)
            jumpi: void,  // Dynamic JUMPI (not fused)
            pc: struct { value: PcType },  // PC opcode with current PC value
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

            // Enforce EIP-170: maximum runtime bytecode size
            if (code.len > cfg.max_bytecode_size) {
                return error.BytecodeTooLarge;
            }

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

                if (metadata_len > 0 and metadata_len + 2 <= code.len) {
                    const metadata_start_idx = code.len - metadata_len - 2;
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
            var values: [3]u256 = .{0, 0, 0};
            
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
            
            return OpcodeData{ .multi_push = .{ 
                .count = n, 
                .original_length = @intCast(total_length),
                .values = values
            }};
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
            
            return OpcodeData{ .multi_pop = .{ 
                .count = n, 
                .original_length = n 
            }};
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
            
            return OpcodeData{ .iszero_jumpi = .{ 
                .target = target, 
                .original_length = @intCast(jumpi_pc + 1 - pc)
            }};
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
            
            return OpcodeData{ .dup2_mstore_push = .{ 
                .push_value = value, 
                .original_length = @intCast(3 + push_size)
            }};
        }
        
        // New high-impact pattern detection functions
        fn checkDup3AddMstorePattern(self: *const Self, pc: PcType) ?OpcodeData {
            if (pc + 3 > self.len()) return null;
            
            // Check for DUP3 + ADD + MSTORE
            if (self.get_unsafe(pc) != 0x82) return null;     // DUP3
            if (self.get_unsafe(pc + 1) != 0x01) return null; // ADD
            if (self.get_unsafe(pc + 2) != 0x52) return null; // MSTORE
            
            return OpcodeData{ .dup3_add_mstore = .{ .original_length = 3 }};
        }
        
        fn checkSwap1Dup2AddPattern(self: *const Self, pc: PcType) ?OpcodeData {
            if (pc + 3 > self.len()) return null;
            
            // Check for SWAP1 + DUP2 + ADD
            if (self.get_unsafe(pc) != 0x90) return null;     // SWAP1
            if (self.get_unsafe(pc + 1) != 0x81) return null; // DUP2
            if (self.get_unsafe(pc + 2) != 0x01) return null; // ADD
            
            return OpcodeData{ .swap1_dup2_add = .{ .original_length = 3 }};
        }
        
        fn checkPushDup3AddPattern(self: *const Self, pc: PcType) ?OpcodeData {
            if (pc + 3 >= self.len()) return null;
            
            // Check for PUSH + DUP3 + ADD
            const push_op = self.get_unsafe(pc);
            if (push_op < 0x5F or push_op > 0x7F) return null; // PUSH0-PUSH32
            
            const push_size = if (push_op == 0x5F) 0 else push_op - 0x5F;
            const dup3_pc = pc + 1 + push_size;
            
            if (dup3_pc + 2 > self.len()) return null;
            if (self.get_unsafe(dup3_pc) != 0x82) return null;     // DUP3
            if (self.get_unsafe(dup3_pc + 1) != 0x01) return null; // ADD
            
            // Extract push value
            var value: u256 = 0;
            if (push_op != 0x5F) { // Not PUSH0
                const end = @min(pc + 1 + push_size, self.len());
                for (pc + 1..end) |i| {
                    value = std.math.shl(u256, value, 8) | self.get_unsafe(@intCast(i));
                }
            }
            
            return OpcodeData{ .push_dup3_add = .{ 
                .value = value,
                .original_length = @intCast(1 + push_size + 2)
            }};
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
            
            return OpcodeData{ .function_dispatch = .{
                .selector = selector,
                .target = target,
                .original_length = @intCast(8 + push_size)
            }};
        }
        
        fn checkCallvalueCheckPattern(self: *const Self, pc: PcType) ?OpcodeData {
            if (pc + 3 > self.len()) return null;
            
            // Check for CALLVALUE + DUP1 + ISZERO
            if (self.get_unsafe(pc) != 0x34) return null;     // CALLVALUE
            if (self.get_unsafe(pc + 1) != 0x80) return null; // DUP1
            if (self.get_unsafe(pc + 2) != 0x15) return null; // ISZERO
            
            return OpcodeData{ .callvalue_check = .{ .original_length = 3 }};
        }
        
        fn checkPush0RevertPattern(self: *const Self, pc: PcType) ?OpcodeData {
            if (pc + 3 > self.len()) return null;
            
            // Check for PUSH0 + PUSH0 + REVERT
            if (self.get_unsafe(pc) != 0x5F) return null;     // PUSH0
            if (self.get_unsafe(pc + 1) != 0x5F) return null; // PUSH0
            if (self.get_unsafe(pc + 2) != 0xFD) return null; // REVERT
            
            return OpcodeData{ .push0_revert = .{ .original_length = 3 }};
        }
        
        fn checkPushAddDup1Pattern(self: *const Self, pc: PcType) ?OpcodeData {
            if (pc + 3 >= self.len()) return null;
            
            // Check for PUSH + ADD + DUP1
            const push_op = self.get_unsafe(pc);
            if (push_op < 0x5F or push_op > 0x7F) return null; // PUSH0-PUSH32
            
            const push_size = if (push_op == 0x5F) 0 else push_op - 0x5F;
            const add_pc = pc + 1 + push_size;
            
            if (add_pc + 2 > self.len()) return null;
            if (self.get_unsafe(add_pc) != 0x01) return null;     // ADD
            if (self.get_unsafe(add_pc + 1) != 0x80) return null; // DUP1
            
            // Extract push value
            var value: u256 = 0;
            if (push_op != 0x5F) { // Not PUSH0
                const end = @min(pc + 1 + push_size, self.len());
                for (pc + 1..end) |i| {
                    value = std.math.shl(u256, value, 8) | self.get_unsafe(@intCast(i));
                }
            }
            
            return OpcodeData{ .push_add_dup1 = .{ 
                .value = value,
                .original_length = @intCast(1 + push_size + 2)
            }};
        }
        
        fn checkMloadSwap1Dup2Pattern(self: *const Self, pc: PcType) ?OpcodeData {
            if (pc + 3 > self.len()) return null;
            
            // Check for MLOAD + SWAP1 + DUP2
            if (self.get_unsafe(pc) != 0x51) return null;     // MLOAD
            if (self.get_unsafe(pc + 1) != 0x90) return null; // SWAP1
            if (self.get_unsafe(pc + 2) != 0x81) return null; // DUP2
            
            return OpcodeData{ .mload_swap1_dup2 = .{ .original_length = 3 }};
        }
        
        /// Get fusion data for a bytecode position marked as fusion candidate
        /// This method checks for advanced patterns first (in priority order)
        pub fn getFusionData(self: *const Self, pc: PcType) OpcodeData {
            log.debug("getFusionData called at PC={d}", .{pc});
            if (pc >= self.len()) {
                log.debug("  PC out of bounds, returning STOP", .{});
                return OpcodeData{ .regular = .{ .opcode = 0x00 } }; // STOP fallback
            }

            // Log what opcodes we're looking at for fusion
            const opcode = self.get_unsafe(pc);
            log.debug("  Checking fusion for opcode 0x{x:0>2} at PC={d}", .{opcode, pc});

            // Special debug for PC=0
            if (pc == 0) {
                log.debug("    Debug PC=0: Bytecode[0]=0x{x:0>2} (PUSH0=0x5f)", .{opcode});
                if (self.runtime_code.len > 1) {
                    log.debug("    Debug PC=1: Bytecode[1]=0x{x:0>2}", .{self.get_unsafe(1)});
                }
                if (self.runtime_code.len > 2) {
                    log.debug("    Debug PC=2: Bytecode[2]=0x{x:0>2}", .{self.get_unsafe(2)});
                }
            }

            // Check advanced fusion patterns in priority order (longest first)

            // Check function dispatch pattern first (can be 8+ bytes)
            if (self.checkFunctionDispatchPattern(pc)) |fusion| {
                log.debug("  Found FUNCTION_DISPATCH fusion", .{});
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
            log.debug("  First opcode at PC={d}: 0x{x:0>2} (PUSH range: 0x60-0x7F, PUSH0=0x5F)", .{pc, first_op});

            // Check for existing 2-opcode fusions (PUSH + op)
            if (first_op >= 0x60 and first_op <= 0x7F) { // PUSH opcode
                log.debug("  Checking PUSH fusion: PUSH{d} at PC={d}", .{first_op - 0x5F, pc});
                const push_size = first_op - 0x5F;
                var value: u256 = 0;
                const end_pc = @min(pc + 1 + push_size, self.len());
                for (pc + 1..end_pc) |i| {
                    value = std.math.shl(u256, value, 8) | self.get_unsafe(@intCast(i));
                }

                // The second opcode comes AFTER the push data
                const second_op_pc = pc + 1 + push_size;
                const second_op = if (second_op_pc < self.len()) self.get_unsafe(second_op_pc) else 0x00;
                log.debug("    Second opcode at PC={d}: 0x{x:0>2}", .{second_op_pc, second_op});

                // Return appropriate fusion type based on second opcode
                switch (second_op) {
                    0x01 => {
                        log.debug("    FUSION: PUSH_ADD_FUSION", .{});
                        return OpcodeData{ .push_add_fusion = .{ .value = value } };
                    },
                    0x02 => return OpcodeData{ .push_mul_fusion = .{ .value = value } }, // MUL
                    0x03 => return OpcodeData{ .push_sub_fusion = .{ .value = value } }, // SUB
                    0x04 => return OpcodeData{ .push_div_fusion = .{ .value = value } }, // DIV
                    0x16 => return OpcodeData{ .push_and_fusion = .{ .value = value } }, // AND
                    0x17 => return OpcodeData{ .push_or_fusion = .{ .value = value } }, // OR
                    0x18 => return OpcodeData{ .push_xor_fusion = .{ .value = value } }, // XOR
                    0x51 => return OpcodeData{ .push_mload_fusion = .{ .value = value } }, // MLOAD
                    0x52 => {
                        log.debug("    FUSION: PUSH_MSTORE_FUSION with value={d}", .{value});
                        return OpcodeData{ .push_mstore_fusion = .{ .value = value } };
                    },
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
            log.debug("  No fusion detected for opcode 0x{x:0>2}, returning regular", .{first_op});
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
                                log.debug("Marking PC={d} as fusion candidate (PUSH{d} + 0x{x:0>2})", .{i, push_size, next_op});
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

        pub fn analyze(self: Self, allocator: std.mem.Allocator) !Analysis {
            var analysis = Analysis{
                .jump_destinations = try std.ArrayList(JumpDestInfo).initCapacity(allocator, 0),
                .push_data = try std.ArrayList(PushInfo).initCapacity(allocator, 0),
            };
            errdefer analysis.deinit(allocator);

            var pc: PcType = 0;
            while (pc < self.runtime_code.len) {
                // Skip if not an opcode start
                if (!self.packed_bitmap[pc].is_op_start) {
                    pc += 1;
                    continue;
                }

                const opcode_byte = self.runtime_code[pc];
                const opcode = std.meta.intToEnum(Opcode, opcode_byte) catch {
                    pc += 1;
                    continue;
                };

                switch (opcode) {
                    .JUMPDEST => {
                        try analysis.jump_destinations.append(allocator, .{
                            .pc = pc,
                            .gas_cost = 1,
                        });
                        pc += 1;
                    },
                    .PUSH0 => {
                        // EIP-3855: PUSH0 pushes zero onto the stack
                        try analysis.push_data.append(allocator, .{
                            .pc = pc,
                            .size = 0,
                            .value = 0,
                            .is_inline = true,
                        });
                        pc += 1;
                    },
                    .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8, .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                        const push_size = @intFromEnum(opcode) - @intFromEnum(Opcode.PUSH1) + 1;

                        // Extract the push value
                        var value: u256 = 0;
                        const data_start = pc + 1;
                        const data_end = @min(data_start + push_size, @as(PcType, @intCast(self.runtime_code.len)));

                        for (data_start..data_end) |byte_pc| {
                            if (byte_pc < self.runtime_code.len) {
                                value = std.math.shl(u256, value, 8) | self.runtime_code[byte_pc];
                            }
                        }

                        try analysis.push_data.append(allocator, .{
                            .pc = pc,
                            .size = push_size,
                            .value = value,
                            .is_inline = push_size <= 8,
                        });

                        pc += 1 + push_size;
                    },
                    else => {
                        pc += 1;
                    },
                }
            }

            return analysis;
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
                const bright_red = "\x1b[91m";
                const bright_green = "\x1b[92m";
                const bright_yellow = "\x1b[93m";
                const bright_blue = "\x1b[94m";
                const bright_magenta = "\x1b[95m";
                const bright_cyan = "\x1b[96m";
            };

            var output = std.ArrayListAligned(u8, null){};
            defer output.deinit(allocator);

            // Header
            try output.writer(allocator).print("{s}=== EVM Bytecode Disassembly ==={s}\n", .{ Colors.bold, Colors.reset });
            try output.writer(allocator).print("{s}Length: {} bytes{s}\n\n", .{ Colors.dim, self.runtime_code.len, Colors.reset });

            var pc: PcType = 0;
            var line_num: u32 = 1;

            while (pc < self.runtime_code.len) {
                const opcode_byte = self.runtime_code[pc];

                // Line number and PC address
                try output.writer(allocator).print("{s}{d:3}:{s} {s}0x{x:0>4}{s} ", .{ Colors.dim, line_num, Colors.reset, Colors.cyan, pc, Colors.reset });

                // Check if this is a jump destination
                if (self.isValidJumpDest(pc)) {
                    try output.writer(allocator).print("{s}►{s} ", .{ Colors.bright_yellow, Colors.reset });
                } else {
                    try output.writer(allocator).print("  ", .{});
                }

                // Raw hex bytes (show opcode + data for PUSH instructions)
                const instruction_size = self.getInstructionSize(pc);
                var hex_output = std.ArrayListAligned(u8, null){};
                defer hex_output.deinit(allocator);

                for (0..instruction_size) |i| {
                    if (pc + i < self.runtime_code.len) {
                        try hex_output.writer(allocator).print("{x:0>2}", .{self.runtime_code[pc + i]});
                        if (i + 1 < instruction_size) try hex_output.writer(allocator).print(" ", .{});
                    }
                }

                // Pad hex to fixed width for alignment
                const hex_str = hex_output.items;
                try output.writer(allocator).print("{s}{s:<24}{s} ", .{ Colors.dim, hex_str, Colors.reset });

                // Parse and format the instruction
                if (std.meta.intToEnum(Opcode, opcode_byte)) |opcode| {
                    const opcode_info = opcode_data.OPCODE_INFO[opcode_byte];

                    switch (opcode) {
                        .PUSH0 => {
                            // EIP-3855: PUSH0 pushes zero
                            try output.writer(allocator).print("{s}{s:<12}{s}", .{ Colors.green, @tagName(opcode), Colors.reset });
                            try output.writer(allocator).print(" {s}0x0{s} {s}(0){s}", .{ Colors.bright_magenta, Colors.reset, Colors.dim, Colors.reset });
                        },
                        .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8, .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                            const push_size = @intFromEnum(opcode) - @intFromEnum(Opcode.PUSH1) + 1;
                            try output.writer(allocator).print("{s}{s:<12}{s}", .{ Colors.green, @tagName(opcode), Colors.reset });

                            // Extract and format push value
                            if (self.readPushValueN(pc, push_size)) |value| {
                                try output.writer(allocator).print(" {s}0x{x}{s}", .{ Colors.bright_magenta, value, Colors.reset });

                                // Show decimal if small value
                                if (value <= 0xFFFF) {
                                    try output.writer(allocator).print(" {s}({}){s}", .{ Colors.dim, value, Colors.reset });
                                }
                            }
                        },
                        .JUMPDEST => {
                            try output.writer(allocator).print("{s}{s}{s:<12}{s}", .{ Colors.bright_yellow, Colors.bold, @tagName(opcode), Colors.reset });
                        },
                        .JUMP, .JUMPI => {
                            try output.writer(allocator).print("{s}{s:<12}{s}", .{ Colors.yellow, @tagName(opcode), Colors.reset });
                        },
                        .STOP, .RETURN, .REVERT => {
                            try output.writer(allocator).print("{s}{s:<12}{s}", .{ Colors.red, @tagName(opcode), Colors.reset });
                        },
                        .ADD, .SUB, .MUL, .DIV, .SDIV, .MOD, .SMOD, .ADDMOD, .MULMOD, .EXP => {
                            try output.writer(allocator).print("{s}{s:<12}{s}", .{ Colors.blue, @tagName(opcode), Colors.reset });
                        },
                        .LT, .GT, .SLT, .SGT, .EQ, .ISZERO => {
                            try output.writer(allocator).print("{s}{s:<12}{s}", .{ Colors.magenta, @tagName(opcode), Colors.reset });
                        },
                        .AND, .OR, .XOR, .NOT, .BYTE, .SHL, .SHR, .SAR => {
                            try output.writer(allocator).print("{s}{s:<12}{s}", .{ Colors.cyan, @tagName(opcode), Colors.reset });
                        },
                        else => {
                            try output.writer(allocator).print("{s}{s:<12}{s}", .{ Colors.white, @tagName(opcode), Colors.reset });
                        },
                    }

                    // Gas cost
                    try output.writer(allocator).print(" {s}[gas: {}]{s}", .{ Colors.dim, opcode_info.gas_cost, Colors.reset });

                    // Stack effects
                    if (opcode_info.stack_inputs > 0 or opcode_info.stack_outputs > 0) {
                        try output.writer(allocator).print(" {s}[stack: -{}, +{}]{s}", .{ Colors.dim, opcode_info.stack_inputs, opcode_info.stack_outputs, Colors.reset });
                    }
                } else |_| {
                    // Invalid opcode
                    try output.writer(allocator).print("{s}INVALID(0x{x:0>2}){s}", .{ Colors.bright_red, opcode_byte, Colors.reset });
                }

                try output.writer(allocator).print("\n", .{});

                pc += instruction_size;
                line_num += 1;
            }

            // Footer with summary
            try output.writer(allocator).print("\n{s}=== Summary ==={s}\n", .{ Colors.bold, Colors.reset });

            // Count jump destinations
            var jumpdest_count: u32 = 0;
            for (0..self.runtime_code.len) |i| {
                if (self.isValidJumpDest(@intCast(i))) {
                    jumpdest_count += 1;
                }
            }

            try output.writer(allocator).print("{s}Jump destinations: {}{s}\n", .{ Colors.dim, jumpdest_count, Colors.reset });
            try output.writer(allocator).print("{s}Total instructions: {}{s}\n", .{ Colors.dim, line_num - 1, Colors.reset });

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
            std.debug.print("Expected to find '{s}' in:\n{s}\n", .{ part, formatted });
            return err;
        };
    }

    // Verify it's a valid string
    try std.testing.expect(formatted.len > 0);
}

// Additional comprehensive test coverage for bytecode.zig

const testing = std.testing;

test "debug: fusion detection for CALL bytecode" {
    std.testing.log_level = .debug;
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
        .pc_type = u16,
        .fusions_enabled = true,
    });

    log.debug("\n=== Creating bytecode object ===", .{});
    var bytecode = try BytecodeType.init(allocator, test_bytecode);
    defer bytecode.deinit();

    log.debug("\n=== Testing iterator ===", .{});
    var iter = bytecode.createIterator();
    var op_count: usize = 0;

    while (iter.next()) |op_data| {
        log.debug("\nOp {d}: PC={d}, type={s}", .{op_count, iter.pc, @tagName(op_data)});
        op_count += 1;
    }

    log.debug("\nTotal operations: {d}", .{op_count});
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

test "Jump destination validation - invalid jump target" {
    const allocator = testing.allocator;

    // PUSH1 3, JUMP, STOP (no JUMPDEST at PC 3)
    const code = [_]u8{ 0x60, 0x03, 0x56, 0x00 };
    try testing.expectError(BytecodeDefault.ValidationError.InvalidJumpDestination, BytecodeDefault.init(allocator, &code));
}

test "Jump destination validation - jump to push data" {
    const allocator = testing.allocator;

    // PUSH1 1, JUMP, 0x5B (this 0x5B is push data, not a real JUMPDEST)
    const code = [_]u8{ 0x60, 0x01, 0x56, 0x60, 0x5B };
    try testing.expectError(BytecodeDefault.ValidationError.InvalidJumpDestination, BytecodeDefault.init(allocator, &code));
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
    var bytecode = try TestBytecode.init(allocator, &code, null);
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

test "Error resilience - out of bounds jump" {
    const allocator = testing.allocator;

    // PUSH1 100, JUMP (target 100 is beyond bytecode end)
    const code = [_]u8{ 0x60, 100, 0x56 };
    try testing.expectError(BytecodeDefault.ValidationError.InvalidJumpDestination, BytecodeDefault.init(allocator, &code));
}

test "Bitmap utility functions - countBitsInRange" {
    // Test the bitmap counting utility
    const bitmap = [_]u8{ 0b10101010, 0b11110000, 0b00001111 };

    const count1 = BytecodeDefault.countBitsInRange(&bitmap, 0, 8);
    try testing.expectEqual(@as(usize, 4), count1); // First byte has 4 bits set

    const count2 = BytecodeDefault.countBitsInRange(&bitmap, 8, 16);
    try testing.expectEqual(@as(usize, 4), count2); // Second byte has 4 bits set

    const count3 = BytecodeDefault.countBitsInRange(&bitmap, 0, 24);
    try testing.expectEqual(@as(usize, 12), count3); // All three bytes have 12 bits total
}

test "Bitmap utility functions - findNextSetBit" {
    // Test finding next set bit in bitmap
    const bitmap = [_]u8{ 0b00000000, 0b00010000, 0b10000000 };

    const next_bit1 = BytecodeDefault.findNextSetBit(&bitmap, 0);
    try testing.expectEqual(@as(?usize, 12), next_bit1); // Bit 12 (4th bit of second byte)

    const next_bit2 = BytecodeDefault.findNextSetBit(&bitmap, 13);
    try testing.expectEqual(@as(?usize, 16), next_bit2); // Bit 16 (0th bit of third byte)

    const next_bit3 = BytecodeDefault.findNextSetBit(&bitmap, 17);
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

test "Security - malformed jump patterns" {
    const allocator = testing.allocator;

    // PUSH1 2, JUMP, JUMPDEST (but jump target is push data, not the JUMPDEST)
    const code = [_]u8{ 0x60, 0x02, 0x56, 0x5B };
    try testing.expectError(BytecodeDefault.ValidationError.InvalidJumpDestination, BytecodeDefault.init(allocator, &code));
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
    try code.append(allocator, 37);   // Jump to position 37 (ISZERO) instead of 36 (JUMPDEST)

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
    try code.append(allocator, 36);   // Jump to position 36 (JUMPDEST)

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
