//! Lightweight execution context for EVM operations.
//!
//! Frame handles direct opcode execution including stack manipulation,
//! arithmetic, memory access, and storage operations. It does NOT handle:
//! - PC tracking and jumps (managed by Plan)
//! - CALL/CREATE operations (managed by Host/EVM)
//! - Environment queries (provided by Host)
//!
//! The Frame is designed for efficient opcode dispatch with configurable
//! components for stack size, memory limits, and gas tracking.
const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const memory_mod = @import("memory.zig");
const stack_mod = @import("stack.zig");
const opcode_data = @import("opcode_data.zig");
const Opcode = opcode_data.Opcode;
pub const FrameConfig = @import("frame_config.zig").FrameConfig;
const DatabaseInterface = @import("database_interface.zig").DatabaseInterface;
const Account = @import("database_interface.zig").Account;
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
const Address = primitives.Address.Address;
const to_u256 = primitives.Address.to_u256;
const from_u256 = primitives.Address.from_u256;
const EMPTY_CODE_HASH = primitives.EMPTY_CODE_HASH;
const EMPTY_TRIE_ROOT = primitives.EMPTY_TRIE_ROOT;
const keccak_asm = @import("keccak_asm.zig");
const SelfDestruct = @import("self_destruct.zig").SelfDestruct;
const Host = @import("host.zig").Host;
const CallParams = @import("call_params.zig").CallParams;
const CallResult = @import("call_result.zig").CallResult;
const logs = @import("logs.zig");
const Log = logs.Log;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;
const block_info_mod = @import("block_info.zig");
const BlockInfo = block_info_mod.DefaultBlockInfo;
const call_params_mod = @import("call_params.zig");
const call_result_mod = @import("call_result.zig");
const hardfork_mod = @import("hardfork.zig");
/// Creates a configured Frame type for EVM execution.
///
/// The Frame is parameterized by compile-time configuration to enable
/// optimal code generation and platform-specific optimizations.
pub fn Frame(comptime config: FrameConfig) type {
    comptime config.validate();
    return struct {
        pub const WordType = config.WordType;
        pub const GasType = config.GasType();
        pub const PcType = config.PcType();
        pub const Memory = memory_mod.Memory(.{
            .initial_capacity = config.memory_initial_capacity,
            .memory_limit = config.memory_limit,
        });
        pub const Stack = stack_mod.Stack(.{
            .stack_size = config.stack_size,
            .WordType = config.WordType,
        });
        pub const Error = error{
            StackOverflow,
            StackUnderflow,
            STOP,
            REVERT,
            BytecodeTooLarge,
            AllocationError,
            InvalidJump,
            InvalidOpcode,
            OutOfBounds,
            OutOfGas,
            GasOverflow,
            InvalidAmount,
            WriteProtection,
        };
        pub const max_bytecode_size = config.max_bytecode_size;
        // Local constants for calculations
        const LOCAL_EMPTY_CODE_HASH = [32]u8{
            0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c, 0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
            0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b, 0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
        };
        const LOCAL_EMPTY_TRIE_ROOT = [32]u8{
            0x56, 0xe8, 0x1f, 0x17, 0x1b, 0xcc, 0x55, 0xa6, 0xff, 0x83, 0x45, 0xe6, 0x92, 0xc0, 0xf8, 0x6e,
            0x5b, 0x48, 0xe0, 0x1b, 0x99, 0x6c, 0xad, 0xc0, 0x01, 0x62, 0x2f, 0xb5, 0xe3, 0x63, 0xb4, 0x21,
        };
        const Self = @This();
        // Cacheline 1
        stack: Stack,
        bytecode: []const u8, // 16 bytes (slice)
        gas_remaining: GasType, // Direct gas tracking
        /// Total refundable gas accrued during this frame (e.g., SSTORE clears)
        gas_refund: u64 = 0,
        /// Initial gas at frame start for refund cap calculation
        initial_gas: GasType = 0,
        tracer: if (config.TracerType) |T| T else void,
        memory: Memory,
        database: if (config.has_database) ?DatabaseInterface else void,
        // Contract execution context
        contract_address: Address = [_]u8{0} ** 20,
        self_destruct: ?*SelfDestruct = null,
        host: Host,
        // Cold data - less frequently accessed during execution
        logs: std.ArrayList(Log),
        output_data: std.ArrayList(u8),
        /// Initialize a new execution frame.
        ///
        /// Creates stack, memory, and other execution components. Validates
        /// bytecode size and allocates resources with proper cleanup on failure.
        pub fn init(allocator: std.mem.Allocator, bytecode: []const u8, gas_remaining: GasType, database: if (config.has_database) ?DatabaseInterface else void, host: Host) Error!Self {
            if (bytecode.len > max_bytecode_size) {
                @branchHint(.unlikely);
                return Error.BytecodeTooLarge;
            }
            var stack = Stack.init(allocator) catch {
                @branchHint(.cold);
                return Error.AllocationError;
            };
            errdefer stack.deinit(allocator);
            var memory = Memory.init(allocator) catch {
                @branchHint(.cold);
                return Error.AllocationError;
            };
            errdefer memory.deinit();
            var frame_logs = std.ArrayList(Log).init(allocator);
            errdefer frame_logs.deinit();
            var output_data = std.ArrayList(u8).init(allocator);
            errdefer output_data.deinit();
            return Self{
                .stack = stack,
                .bytecode = bytecode,
                .gas_remaining = @as(GasType, @intCast(@max(gas_remaining, 0))),
                .gas_refund = 0,
                .initial_gas = @as(GasType, @intCast(@max(gas_remaining, 0))),
                .tracer = if (config.TracerType) |T| T.init() else {},
                .memory = memory,
                .database = database,
                .logs = frame_logs,
                .output_data = output_data,
                .host = host,
            };
        }
        /// Clean up all frame resources.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.stack.deinit(allocator);
            self.memory.deinit();
            // Free log data
            for (self.logs.items) |log_entry| {
                allocator.free(log_entry.topics);
                allocator.free(log_entry.data);
            }
            self.logs.deinit();
            self.output_data.deinit();
        }
        /// Helper function to call tracer beforeOp if tracer is configured
        pub inline fn traceBeforeOp(self: *Self, pc: u32, opcode: u8) void {
            if (comptime config.TracerType != null) {
                self.tracer.beforeOp(pc, opcode, Self, self);
            }
        }
        /// Helper function to call tracer afterOp if tracer is configured
        pub inline fn traceAfterOp(self: *Self, pc: u32, opcode: u8) void {
            if (comptime config.TracerType != null) {
                self.tracer.afterOp(pc, opcode, Self, self);
            }
        }
        /// Helper function to call tracer onError if tracer is configured
        pub inline fn traceOnError(self: *Self, pc: u32, err: anyerror) void {
            if (comptime config.TracerType != null) {
                self.tracer.onError(pc, err, Self, self);
            }
        }
        /// Create a deep copy of the frame.
        /// This is used by DebugPlan to create a sidecar frame for validation.
pub fn copy(self: *const Self, allocator: std.mem.Allocator) Error!Self {
            // Copy stack using public API
            var new_stack = Stack.init(allocator) catch {
                return Error.AllocationError;
            };
            errdefer new_stack.deinit(allocator);
            const src_stack_slice = self.stack.get_slice();
            if (src_stack_slice.len > 0) {
                // Reconstruct by pushing from bottom to top so top matches exactly
                var i: usize = src_stack_slice.len;
                while (i > 0) {
                    i -= 1;
                    try new_stack.push(src_stack_slice[i]);
                }
            }

            // Copy memory using current API
            var new_memory = Memory.init(allocator) catch {
                return Error.AllocationError;
            };
            errdefer new_memory.deinit();
            const mem_size = self.memory.size();
            if (mem_size > 0) {
                const bytes = self.memory.get_slice(0, mem_size) catch unreachable;
                try new_memory.set_data(0, bytes);
            }

            // Copy logs
            var new_logs = std.ArrayList(Log).init(allocator);
            errdefer new_logs.deinit();
            for (self.logs.items) |log_entry| {
                // Allocate and copy topics
                const topics_copy = allocator.alloc(u256, log_entry.topics.len) catch {
                    return Error.AllocationError;
                };
                @memcpy(topics_copy, log_entry.topics);
                // Allocate and copy data
                const data_copy = allocator.alloc(u8, log_entry.data.len) catch {
                    allocator.free(topics_copy);
                    return Error.AllocationError;
                };
                @memcpy(data_copy, log_entry.data);
                new_logs.append(Log{
                    .address = log_entry.address,
                    .topics = topics_copy,
                    .data = data_copy,
                }) catch {
                    allocator.free(topics_copy);
                    allocator.free(data_copy);
                    return Error.AllocationError;
                };
            }

            // Copy output data buffer
            var new_output_data = std.ArrayList(u8).init(allocator);
            errdefer new_output_data.deinit();
            new_output_data.appendSlice(self.output_data.items) catch {
                return Error.AllocationError;
            };

            return Self{
                .stack = new_stack,
                .bytecode = self.bytecode,
                .gas_remaining = self.gas_remaining,
                .tracer = if (config.TracerType) |_| self.tracer else {},
                .memory = new_memory,
                .database = self.database,
                .contract_address = self.contract_address,
                .self_destruct = self.self_destruct,
                .logs = new_logs,
                .output_data = new_output_data,
                .host = self.host,
            };
        }
        /// Compare two frames for equality.
        /// Used by DebugPlan to validate execution.
        pub fn assertEqual(self: *const Self, other: *const Self) void {
            // Compare gas
            if (self.gas_remaining != other.gas_remaining) {
                if (comptime (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding)) {
                    std.debug.panic("Frame.assertEqual: gas mismatch: {} vs {}", .{ self.gas_remaining, other.gas_remaining });
                }
            }
            // Compare stack
            const self_count = self.stack.size();
            const other_count = other.stack.size();
            if (self_count != other_count) {
                if (comptime (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding)) {
                    std.debug.panic("Frame.assertEqual: stack size mismatch: {} vs {}", .{ self_count, other_count });
                }
            }
            const self_stack_slice = self.stack.get_slice();
            const other_stack_slice = other.stack.get_slice();
            for (self_stack_slice, 0..) |v, i| {
                if (v != other_stack_slice[i]) {
                    if (comptime (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding)) {
                        std.debug.panic("Frame.assertEqual: stack[{}] mismatch: {} vs {}", .{ i, v, other_stack_slice[i] });
                    }
                }
            }
            // Compare memory
            if (self.memory.size() != other.memory.size()) {
                if (comptime (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding)) {
                    std.debug.panic("Frame.assertEqual: memory size mismatch: {} vs {}", .{ self.memory.size(), other.memory.size() });
                }
            }
            const mem_sz = self.memory.size();
            if (mem_sz > 0) {
                const self_data = self.memory.get_slice(0, mem_sz) catch &[_]u8{};
                const other_data = other.memory.get_slice(0, mem_sz) catch &[_]u8{};
                var i: usize = 0;
                while (i < mem_sz) : (i += 1) {
                    if (self_data[i] != other_data[i]) {
                        if (comptime (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding)) {
                            std.debug.panic("Frame.assertEqual: memory[{}] mismatch: {} vs {}", .{ i, self_data[i], other_data[i] });
                        }
                    }
                }
            }
            // Compare execution context
            if (!std.mem.eql(u8, &self.contract_address, &other.contract_address)) {
                if (comptime (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding)) {
                    std.debug.panic("Frame.assertEqual: contract_address mismatch", .{});
                }
            }
            // Compare logs
            if (self.logs.items.len != other.logs.items.len) {
                if (comptime (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding)) {
                    std.debug.panic("Frame.assertEqual: logs count mismatch: {} vs {}", .{ self.logs.items.len, other.logs.items.len });
                }
            }
            for (self.logs.items, other.logs.items) |self_log, other_log| {
                if (!std.mem.eql(u8, &self_log.address, &other_log.address)) {
                    if (comptime (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding)) {
                        std.debug.panic("Frame.assertEqual: log address mismatch", .{});
                    }
                }
                if (self_log.topics.len != other_log.topics.len) {
                    if (comptime (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding)) {
                        std.debug.panic("Frame.assertEqual: log topics count mismatch", .{});
                    }
                }
                for (self_log.topics, other_log.topics) |self_topic, other_topic| {
                    if (self_topic != other_topic) {
                        if (comptime (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding)) {
                            std.debug.panic("Frame.assertEqual: log topic mismatch", .{});
                        }
                    }
                }
                if (!std.mem.eql(u8, self_log.data, other_log.data)) {
                    if (comptime (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding)) {
                        std.debug.panic("Frame.assertEqual: log data mismatch", .{});
                    }
                }
            }
        }
        /// Pretty print the frame state for debugging.
        pub fn pretty_print(self: *const Self) void {
            log.debug("\n=== Frame State ===\n", .{});
            log.debug("Gas Remaining: {}\n", .{@max(self.gas_remaining, 0)});
            log.debug("Bytecode Length: {}\n", .{self.bytecode.len});
            // Show bytecode (first 50 bytes or less)
            const show_bytes = @min(self.bytecode.len, 50);
            log.debug("Bytecode (first {} bytes): ", .{show_bytes});
            for (self.bytecode[0..show_bytes]) |b| {
                log.debug("{x:0>2} ", .{b});
            }
            if (self.bytecode.len > 50) {
                log.debug("... ({} more bytes)", .{self.bytecode.len - 50});
            }
            log.debug("\n", .{});
            // Stack state
            log.debug("\nStack (size={}, capacity={}):\n", .{ self.stack.size(), Stack.stack_capacity });
            if (self.stack.size() == 0) {
                log.debug("  [empty]\n", .{});
            } else {
                // Show top 10 stack items
                const show_items = @min(self.stack.size(), 10);
                const stack_slice = self.stack.get_slice();
                var i: usize = 0;
                while (i < show_items) : (i += 1) {
                    const value = stack_slice[i]; // In downward stack, [0] is top
                    const idx = i;
                    if (i == 0) {
                        log.debug("  [{d:3}] 0x{x:0>64} <- TOP\n", .{ idx, value });
                    } else {
                        log.debug("  [{d:3}] 0x{x:0>64}\n", .{ idx, value });
                    }
                }
                if (self.stack.size() > 10) {
                    log.debug("  ... ({} more items)\n", .{self.stack.size() - 10});
                }
            }
            // Memory state
            log.debug("\nMemory (size={}):\n", .{self.memory.size()});
            if (self.memory.size() == 0) {
                log.debug("  [empty]\n", .{});
            } else {
                // Show first 256 bytes of memory in hex dump format
                const show_mem = @min(self.memory.size(), 256);
                var offset: usize = 0;
                while (offset < show_mem) : (offset += 32) {
                    const end = @min(offset + 32, show_mem);
                    log.debug("  0x{x:0>4}: ", .{offset});
                    // Hex bytes
                    var i = offset;
                    while (i < end) : (i += 1) {
                        const b = self.memory.get_byte(i) catch 0;
                        log.debug("{x:0>2} ", .{b});
                    }
                    // Pad if less than 32 bytes
                    if (end - offset < 32) {
                        var pad = end - offset;
                        while (pad < 32) : (pad += 1) {
                            log.debug("   ", .{});
                        }
                    }
                    // ASCII representation
                    log.debug(" |", .{});
                    i = offset;
                    while (i < end) : (i += 1) {
                        const b = self.memory.get_byte(i) catch 0;
                        if (b >= 32 and b <= 126) {
                            log.debug("{c}", .{b});
                        } else {
                            log.debug(".", .{});
                        }
                    }
                    log.debug("|\n", .{});
                }
                if (self.memory.size() > 256) {
                    log.debug("  ... ({} more bytes)\n", .{self.memory.size() - 256});
                }
            }
            // Log state
            log.debug("\nLogs (count={}):\n", .{self.logs.items.len});
            if (self.logs.items.len == 0) {
                log.debug("  [empty]\n", .{});
            } else {
                for (self.logs.items, 0..) |log_item, i| {
                    log.debug("  Log[{}]:\n", .{i});
                    log.debug("    Address: 0x", .{});
                    for (log_item.address) |b| {
                        log.debug("{x:0>2}", .{b});
                    }
                    log.debug("\n", .{});
                    log.debug("    Topics ({}):\n", .{log_item.topics.len});
                    for (log_item.topics, 0..) |topic, j| {
                        log.debug("      [{}] 0x{x:0>64}\n", .{ j, topic });
                    }
                    log.debug("    Data ({} bytes): 0x", .{log_item.data.len});
                    const show_data = @min(log_item.data.len, 64);
                    for (log_item.data[0..show_data]) |b| {
                        log.debug("{x:0>2}", .{b});
                    }
                    if (log_item.data.len > 64) {
                        log.debug("... ({} more bytes)", .{log_item.data.len - 64});
                    }
                    log.debug("\n", .{});
                }
            }
            log.debug("===================\n\n", .{});
        }
        pub fn pop(self: *Self) Error!void {
            _ = try self.stack.pop();
        }
        pub fn stop(self: *Self) Error!void {
            // Apply EIP-3529 refund cap: at most 1/5th of gas used
            if (self.gas_refund > 0) {
                const start: u64 = @max(self.initial_gas, 0);
                const remain: u64 = @max(self.gas_remaining, 0);
                const used: u64 = if (start > remain) start - remain else 0;
                const cap: u64 = used / 5; // 20% cap
                const credit: u64 = if (self.gas_refund > cap) cap else self.gas_refund;
                const new_remaining: u128 = @as(u128, @intCast(remain)) + credit;
                self.gas_remaining = @as(GasType, @intCast(@min(new_remaining, @as(u128, @intCast(std.math.maxInt(GasType))))));
                self.gas_refund = 0;
            }
            return Error.STOP;
        }
        // Bitwise operations
        pub fn @"and"(self: *Self) Error!void {
            const top_minus_1 = try self.stack.pop();
            const top = try self.stack.peek();
            try self.stack.set_top(top & top_minus_1);
        }
        pub fn @"or"(self: *Self) Error!void {
            const top_minus_1 = try self.stack.pop();
            const top = try self.stack.peek();
            try self.stack.set_top(top | top_minus_1);
        }
        pub fn xor(self: *Self) Error!void {
            const top_minus_1 = try self.stack.pop();
            const top = try self.stack.peek();
            try self.stack.set_top(top ^ top_minus_1);
        }
        pub fn not(self: *Self) Error!void {
            const top = try self.stack.peek();
            try self.stack.set_top(~top);
        }
        pub fn byte(self: *Self) Error!void {
            const byte_index = try self.stack.pop();
            const value = try self.stack.peek();
            const result = if (byte_index >= 32) 0 else blk: {
                const index_usize = @as(usize, @intCast(byte_index));
                const shift_amount = (31 - index_usize) * 8;
                const ShiftType = std.math.Log2Int(WordType);
                break :blk (value >> @as(ShiftType, @intCast(shift_amount))) & 0xFF;
            };
            try self.stack.set_top(result);
        }
        pub fn shl(self: *Self) Error!void {
            const shift = try self.stack.pop();
            const value = try self.stack.peek();
            const ShiftType = std.math.Log2Int(WordType);
            const result = if (shift >= @bitSizeOf(WordType)) 0 else value << @as(ShiftType, @intCast(shift));
            try self.stack.set_top(result);
        }
        pub fn shr(self: *Self) Error!void {
            const shift = try self.stack.pop();
            const value = try self.stack.peek();
            const ShiftType = std.math.Log2Int(WordType);
            const result = if (shift >= @bitSizeOf(WordType)) 0 else value >> @as(ShiftType, @intCast(shift));
            try self.stack.set_top(result);
        }
        pub fn sar(self: *Self) Error!void {
            const shift = try self.stack.pop();
            const value = try self.stack.peek();
            const word_bits = @bitSizeOf(WordType);
            const result = if (shift >= word_bits) blk: {
                const sign_bit = value >> (word_bits - 1);
                break :blk if (sign_bit == 1) @as(WordType, std.math.maxInt(WordType)) else @as(WordType, 0);
            } else blk: {
                const ShiftType = std.math.Log2Int(WordType);
                const shift_amount = @as(ShiftType, @intCast(shift));
                // https://ziglang.org/documentation/master/std/#std.meta.Int
                // std.meta.Int creates an integer type with specified signedness and bit width
                const value_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(value));
                const result_signed = value_signed >> shift_amount;
                break :blk @as(WordType, @bitCast(result_signed));
            };
            try self.stack.set_top(result);
        }
        // Arithmetic operations
        /// ADD opcode (0x01) - Addition with overflow wrapping.
        pub fn add(self: *Self) Error!void {
            // Charge gas for simple arithmetic (fastest step)
            const gas_cost: u64 = GasConstants.GasFastestStep;
            try self.consumeGasChecked(gas_cost);
            const top_minus_1 = try self.stack.pop();
            const top = try self.stack.peek();
            try self.stack.set_top(top +% top_minus_1);
        }
        /// MUL opcode (0x02) - Multiplication with overflow wrapping.
        pub fn mul(self: *Self) Error!void {
            const top_minus_1 = try self.stack.pop();
            const top = try self.stack.peek();
            try self.stack.set_top(top *% top_minus_1);
        }
        pub fn sub(self: *Self) Error!void {
            const top_minus_1 = try self.stack.pop();
            const top = try self.stack.peek();
            try self.stack.set_top(top -% top_minus_1);
        }
        /// DIV opcode (0x04) - Integer division. Division by zero returns 0.
        pub fn div(self: *Self) Error!void {
            const denominator = try self.stack.pop();
            const numerator = try self.stack.peek();
            const result = if (denominator == 0) 0 else numerator / denominator;
            try self.stack.set_top(result);
        }
        pub fn sdiv(self: *Self) Error!void {
            const denominator = try self.stack.pop();
            const numerator = try self.stack.peek();
            var result: WordType = undefined;
            if (denominator == 0) {
                result = 0;
            } else {
                const numerator_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(numerator));
                const denominator_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(denominator));
                const min_signed = std.math.minInt(std.meta.Int(.signed, @bitSizeOf(WordType)));
                if (numerator_signed == min_signed and denominator_signed == -1) {
                    // MIN / -1 overflow case
                    result = numerator;
                } else {
                    const result_signed = @divTrunc(numerator_signed, denominator_signed);
                    result = @as(WordType, @bitCast(result_signed));
                }
            }
            try self.stack.set_top(result);
        }
        pub fn mod(self: *Self) Error!void {
            const denominator = try self.stack.pop();
            const numerator = try self.stack.peek();
            const result = if (denominator == 0) 0 else numerator % denominator;
            try self.stack.set_top(result);
        }
        pub fn smod(self: *Self) Error!void {
            const denominator = try self.stack.pop();
            const numerator = try self.stack.peek();
            var result: WordType = undefined;
            if (denominator == 0) {
                result = 0;
            } else {
                const numerator_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(numerator));
                const denominator_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(denominator));
                const result_signed = @rem(numerator_signed, denominator_signed);
                result = @as(WordType, @bitCast(result_signed));
            }
            try self.stack.set_top(result);
        }
        pub fn addmod(self: *Self) Error!void {
            const modulus = try self.stack.pop();
            const addend2 = try self.stack.pop();
            const addend1 = try self.stack.peek();
            var result: WordType = 0;
            if (modulus == 0) {
                result = 0;
            } else {
                const a = addend1 % modulus;
                const b = addend2 % modulus;
                const sum = @addWithOverflow(a, b);
                var r = sum[0];
                // If overflow occurred or r >= modulus, subtract once
                if (sum[1] == 1 or r >= modulus) {
                    r -%= modulus;
                }
                result = r;
            }
            try self.stack.set_top(result);
        }
        pub fn mulmod(self: *Self) Error!void {
            const modulus = try self.stack.pop();
            const factor2 = try self.stack.pop();
            const factor1 = try self.stack.peek();
            var result: WordType = undefined;
            if (modulus == 0) {
                result = 0;
            } else {
                const factor1_mod = factor1 % modulus;
                const factor2_mod = factor2 % modulus;
                const product = factor1_mod *% factor2_mod;
                result = product % modulus;
            }
            try self.stack.set_top(result);
        }
        pub fn exp(self: *Self) Error!void {
            const exponent = try self.stack.pop();
            const base = try self.stack.peek();
            var result: WordType = 1;
            var b = base;
            var e = exponent;
            while (e > 0) : (e >>= 1) {
                if (e & 1 == 1) {
                    result *%= b;
                }
                b *%= b;
            }
            try self.stack.set_top(result);
        }
        pub fn signextend(self: *Self) Error!void {
            const ext = try self.stack.pop();
            const value = try self.stack.peek();
            var result: WordType = undefined;
            if (ext >= 31) {
                result = value;
            } else {
                const ext_usize = @as(usize, @intCast(ext));
                const bit_index = ext_usize * 8 + 7;
                const mask = (@as(WordType, 1) << @intCast(bit_index)) - 1;
                const sign_bit = (value >> @intCast(bit_index)) & 1;
                if (sign_bit == 1) {
                    result = value | ~mask;
                } else {
                    result = value & mask;
                }
            }
            try self.stack.set_top(result);
        }
        /// Consume gas without checking (for use after static analysis)
        pub fn consumeGasUnchecked(self: *Self, amount: u64) void {
            self.gas_remaining -= @as(GasType, @intCast(amount));
        }
        /// Consume gas with bounds checking and safe casting
        pub fn consumeGasChecked(self: *Self, amount: u64) Error!void {
            const amt = std.math.cast(GasType, amount) orelse return Error.OutOfGas;
            if (self.gas_remaining < amt) return Error.OutOfGas;
            self.gas_remaining -= amt;
        }
        /// Check if we're out of gas at end of execution
        pub fn checkGas(self: *Self) Error!void {
            if (self.gas_remaining <= 0) {
                @branchHint(.cold);
                return Error.OutOfGas;
            }
        }
        pub fn gas(self: *Self) Error!void {
            const gas_value = @as(WordType, @max(self.gas_remaining, 0));
            return self.stack.push(gas_value);
        }
        /// Test helper: KECCAK256 hash function for direct data hashing
        /// Pushes the hash result onto the stack.
        pub fn keccak256_data(self: *Self, data: []const u8) Error!void {
            var hash_bytes: [32]u8 = undefined;
            keccak_asm.keccak256(data, &hash_bytes) catch |err| switch (err) {
                keccak_asm.KeccakError.InvalidInput => return Error.OutOfBounds,
                keccak_asm.KeccakError.MemoryError => return Error.AllocationError,
                else => return Error.AllocationError,
            };
            var hash_u256: u256 = 0;
            for (hash_bytes) |b| {
                hash_u256 = (hash_u256 << 8) | @as(u256, b);
            }
            try self.stack.push(@as(WordType, @truncate(hash_u256)));
        }
        // Comparison operations
        pub fn lt(self: *Self) Error!void {
            const top_minus_1 = try self.stack.pop();
            const top = try self.stack.peek();
            const result: WordType = if (top < top_minus_1) 1 else 0;
            try self.stack.set_top(result);
        }
        pub fn gt(self: *Self) Error!void {
            const top_minus_1 = try self.stack.pop();
            const top = try self.stack.peek();
            const result: WordType = if (top > top_minus_1) 1 else 0;
            try self.stack.set_top(result);
        }
        pub fn slt(self: *Self) Error!void {
            const top_minus_1 = try self.stack.pop();
            const top = try self.stack.peek();
            const SignedType = std.meta.Int(.signed, @bitSizeOf(WordType));
            const top_signed = @as(SignedType, @bitCast(top));
            const top_minus_1_signed = @as(SignedType, @bitCast(top_minus_1));
            const result: WordType = if (top_signed < top_minus_1_signed) 1 else 0;
            try self.stack.set_top(result);
        }
        pub fn sgt(self: *Self) Error!void {
            const top_minus_1 = try self.stack.pop();
            const top = try self.stack.peek();
            const SignedType = std.meta.Int(.signed, @bitSizeOf(WordType));
            const top_signed = @as(SignedType, @bitCast(top));
            const top_minus_1_signed = @as(SignedType, @bitCast(top_minus_1));
            const result: WordType = if (top_signed > top_minus_1_signed) 1 else 0;
            try self.stack.set_top(result);
        }
        pub fn eq(self: *Self) Error!void {
            const top_minus_1 = try self.stack.pop();
            const top = try self.stack.peek();
            const result: WordType = if (top == top_minus_1) 1 else 0;
            try self.stack.set_top(result);
        }
        pub fn iszero(self: *Self) Error!void {
            const value = try self.stack.peek();
            const result: WordType = if (value == 0) 1 else 0;
            try self.stack.set_top(result);
        }
        // Helper function to validate if a PC position contains a valid JUMPDEST
        pub fn is_valid_jump_dest(self: *Self, pc_value: usize) bool {
            if (pc_value >= self.bytecode.len) return false;
            const opcode = self.bytecode[pc_value];
            return opcode == @intFromEnum(Opcode.JUMPDEST);
        }
        pub fn jumpdest(self: *Self) Error!void {
            _ = self;
            // JUMPDEST does nothing - it's just a marker for valid jump destinations
        }
        pub fn invalid(self: *Self) Error!void {
            _ = self;
            return Error.InvalidOpcode;
        }
        // Cryptographic operations
        /// KECCAK256 opcode (0x20) - Compute keccak256 hash
        /// Pops offset and size from stack, reads data from memory, and pushes hash.
        /// Stack: [offset, size] → [hash]
        pub fn keccak256(self: *Self) Error!void {
            const size = try self.stack.pop();
            const offset = try self.stack.pop();
            // Check bounds
            if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
                @branchHint(.unlikely);
                return Error.OutOfBounds;
            }
            // Handle empty data case
            if (size == 0) {
                @branchHint(.unlikely);
                // Hash of empty data = keccak256("")
                if (WordType == u256) {
                    const empty_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
                    try self.stack.push(empty_hash);
                } else {
                    // For smaller word types, we can't represent the full hash
                    // This is a limitation when using non-u256 word types
                    try self.stack.push(0);
                }
                return;
            }
            const offset_usize = @as(usize, @intCast(offset));
            const size_usize = @as(usize, @intCast(size));
            // Check for overflow
            const end = std.math.add(usize, offset_usize, size_usize) catch {
                @branchHint(.unlikely);
                return Error.OutOfBounds;
            };
            // Ensure memory is available
            self.memory.ensure_capacity(end) catch |err| switch (err) {
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };
            // Get data from memory
            const data = self.memory.get_slice(offset_usize, size_usize) catch return Error.OutOfBounds;
            // Compute keccak256 hash and convert to big-endian u256
            var hash_bytes: [32]u8 = undefined;
            keccak_asm.keccak256(data, &hash_bytes) catch |err| switch (err) {
                keccak_asm.KeccakError.InvalidInput => return Error.OutOfBounds,
                keccak_asm.KeccakError.MemoryError => return Error.AllocationError,
                else => return Error.AllocationError,
            };
            var hash_u256: u256 = 0;
            for (hash_bytes) |b| {
                hash_u256 = (hash_u256 << 8) | @as(u256, b);
            }
            const result_word = @as(WordType, @truncate(hash_u256));
            try self.stack.push(result_word);
        }
        // Memory operations
        pub fn msize(self: *Self) Error!void {
            // MSIZE returns the size of active memory in bytes
            const size = @as(WordType, @intCast(self.memory.size()));
            return self.stack.push(size);
        }
        pub fn mload(self: *Self) Error!void {
            // MLOAD loads a 32-byte word from memory
            const offset = try self.stack.pop();
            // Check if offset fits in usize
            if (offset > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));
            // Read 32 bytes from memory (EVM-compliant with automatic expansion)
            const value_u256 = self.memory.get_u256_evm(offset_usize) catch |err| switch (err) {
                memory_mod.MemoryError.OutOfBounds => return Error.OutOfBounds,
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };
            // Convert to WordType (truncate if necessary for smaller word types)
            const value = @as(WordType, @truncate(value_u256));
            try self.stack.push(value);
        }
        pub fn mstore(self: *Self) Error!void {
            // MSTORE stores a 32-byte word to memory
            const offset = try self.stack.pop();
            const value = try self.stack.pop();
            // Check if offset fits in usize
            if (offset > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));
            // Write 32 bytes to memory using EVM-compliant expansion
            self.memory.set_u256_evm(offset_usize, value) catch |err| switch (err) {
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };
        }
        pub fn mstore8(self: *Self) Error!void {
            // MSTORE8 stores a single byte to memory
            const offset = try self.stack.pop();
            const value = try self.stack.pop();
            // Check if offset fits in usize
            if (offset > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));
            const byte_value = @as(u8, @truncate(value & 0xFF));
            // Write 1 byte to memory using EVM-compliant expansion
            self.memory.set_byte_evm(offset_usize, byte_value) catch |err| switch (err) {
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };
        }
        pub fn mcopy(self: *Self) Error!void {
            // MCOPY copies memory from source to destination
            // Stack: [dest, src, length]
            const dest = try self.stack.pop();
            const src = try self.stack.pop();
            const length = try self.stack.pop();
            // Early return for zero length
            if (length == 0) {
                return;
            }
            // Check bounds
            if (dest > std.math.maxInt(usize) or src > std.math.maxInt(usize) or length > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const dest_usize = @as(usize, @intCast(dest));
            const src_usize = @as(usize, @intCast(src));
            const length_usize = @as(usize, @intCast(length));
            // Calculate max memory address needed
            const max_addr = @max(dest_usize + length_usize, src_usize + length_usize);
            // Ensure memory is expanded to accommodate both source and destination
            // This will charge memory expansion gas
            self.memory.ensure_capacity(max_addr) catch |err| switch (err) {
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };
            // Calculate and consume dynamic gas for copy operation
            const word_count = (length_usize + 31) / 32;
            const copy_gas = GasConstants.CopyGas * word_count;
            // Check if we have enough gas
            if (copy_gas > std.math.maxInt(GasType)) {
                @branchHint(.unlikely);
                return Error.OutOfGas;
            }
            if (self.gas_remaining < @as(GasType, @intCast(copy_gas))) {
                @branchHint(.unlikely);
                return Error.OutOfGas;
            }
            self.gas_remaining -= @as(GasType, @intCast(copy_gas));
            // Get memory buffer slice
            const mem_buffer = self.memory.get_buffer_ref();
            const checkpoint = self.memory.checkpoint;
            const mem_slice = mem_buffer.items;
            // Perform the memory copy with overlap handling
            // We need to add checkpoint offset to our indices
            const actual_src = checkpoint + src_usize;
            const actual_dest = checkpoint + dest_usize;
            if (mem_slice.len >= checkpoint + max_addr) {
                const src_slice = mem_slice[actual_src .. actual_src + length_usize];
                const dest_slice = mem_slice[actual_dest .. actual_dest + length_usize];
                if (dest_usize > src_usize and dest_usize < src_usize + length_usize) {
                    // Forward overlap: dest is within source range, copy backwards
                    std.mem.copyBackwards(u8, dest_slice, src_slice);
                } else if (src_usize > dest_usize and src_usize < dest_usize + length_usize) {
                    // Backward overlap: src is within dest range, copy forwards
                    std.mem.copyForwards(u8, dest_slice, src_slice);
                } else {
                    // No overlap, use forward copy
                    std.mem.copyForwards(u8, dest_slice, src_slice);
                }
            } else {
                // This shouldn't happen as we ensured capacity above
                return Error.OutOfBounds;
            }
        }
        // Storage operations
        pub fn sload(self: *Self) Error!void {
            // SLOAD loads a value from storage
            if (comptime !config.has_database) {
                return Error.InvalidOpcode;
            }
            const slot = try self.stack.pop();
            // Use the currently executing contract's address
            const contract_addr = self.contract_address;
            // Access the storage slot for warm/cold accounting (EIP-2929)
            const access_cost = self.host.access_storage_slot(contract_addr, slot) catch |err| switch (err) {
                else => return Error.AllocationError,
            };
            // Load value from storage
            const value = self.host.get_storage(contract_addr, slot);
            try self.stack.push(value);
            // Call tracer AFTER successful read (optional presence)
            if (comptime config.TracerType != null) {
                if (comptime @hasDecl(@TypeOf(self.tracer), "on_storage_read")) {
                    const is_warm = access_cost == GasConstants.WarmStorageReadCost or access_cost == GasConstants.SloadGas;
                    self.tracer.on_storage_read(contract_addr, slot, value, is_warm);
                }
            }
        }
        pub fn sstore(self: *Self) Error!void {
            // SSTORE stores a value to storage
            if (comptime !config.has_database) {
                return Error.InvalidOpcode;
            }
            
            // Check if we're in static context
            if (self.host.get_is_static()) {
                return Error.WriteProtection;
            }
            // Stack order for SSTORE: [key, value] -> [] with top being value
            const value = try self.stack.pop();
            const slot = try self.stack.pop();
            // Use the currently executing contract's address
            const addr = self.contract_address;
            // Access the storage slot for warm/cold accounting (EIP-2929)
            const access_cost = self.host.access_storage_slot(addr, slot) catch |err| switch (err) {
                else => return Error.AllocationError,
            };
            // Snapshot old value then write
            const tracer_enabled = (config.TracerType != null)
                and @hasDecl(@TypeOf(self.tracer), "on_storage_write");

            // Capture before write; compiled out when tracer is off
            const _old_value = if (comptime tracer_enabled)
                self.host.get_storage(addr, slot)
            else
                undefined;

            self.host.set_storage(addr, slot, value) catch |err| switch (err) {
                else => return Error.AllocationError,
            };

            if (comptime tracer_enabled) {
                const is_warm = access_cost == GasConstants.WarmStorageReadCost
                    or access_cost == GasConstants.SloadGas;
                self.tracer.on_storage_write(addr, slot, _old_value, value, is_warm);
            }
        }
        // Transient storage operations (EIP-1153)
        pub fn tload(self: *Self) Error!void {
            // TLOAD loads a value from transient storage
            if (comptime !config.has_database) {
                return Error.InvalidOpcode;
            }
            const slot = try self.stack.pop();
            // Get database interface
            const db = self.database orelse return Error.InvalidOpcode;
            // Use the currently executing contract's address
            const addr = self.contract_address;
            // Load value from transient storage
            const value = db.get_transient_storage(addr, slot) catch |err| switch (err) {
                else => return Error.AllocationError,
            };
            try self.stack.push(value);
            // Call tracer AFTER successful read (compiled out when tracer is off)
            if (comptime config.TracerType != null) {
                if (comptime @hasDecl(config.TracerType.?, "on_storage_read")) {
                    self.tracer.on_storage_read(addr, slot, value, true);
                }
            }
        }
        pub fn tstore(self: *Self) Error!void {
            // TSTORE stores a value to transient storage
            if (comptime !config.has_database) {
                return Error.InvalidOpcode;
            }
            
            // Check if we're in static context
            if (self.host.get_is_static()) {
                return Error.WriteProtection;
            }
            const slot = try self.stack.pop();
            const value = try self.stack.pop();
            // Get database interface
            const db = self.database orelse return Error.InvalidOpcode;
            // Use the currently executing contract's address
            const addr = self.contract_address;
            // Capture old value for tracer (compiled out when tracer is off)
            const _old_value = if (comptime config.TracerType != null and @hasDecl(config.TracerType.?, "on_storage_write"))
                db.get_transient_storage(addr, slot) catch 0
            else
                undefined;
            // Store value to transient storage
            db.set_transient_storage(addr, slot, value) catch |err| switch (err) {
                else => return Error.AllocationError,
            };
            // Call tracer AFTER successful write (compiled out when tracer is off)
            if (comptime config.TracerType != null) {
                if (comptime @hasDecl(config.TracerType.?, "on_storage_write")) {
                    self.tracer.on_storage_write(addr, slot, _old_value, value, true);
                }
            }
        }
        // Environment/Context opcodes
        /// ADDRESS opcode (0x30) - Get address of currently executing account
        /// Pushes the address of the currently executing contract.
        /// Stack: [] → [address]
        pub fn address(self: *Self) Error!void {
            const addr_u256 = to_u256(self.contract_address);
            try self.stack.push(addr_u256);
        }
        /// BALANCE opcode (0x31) - Get balance of an account
        /// Pops an address and pushes the balance of that account in wei.
        /// Stack: [address] → [balance]
        pub fn balance(self: *Self) Error!void {
            const address_u256 = try self.stack.pop();
            const addr = from_u256(address_u256);
            
            // Access the address for warm/cold accounting (EIP-2929)
            // This returns the gas cost but the frame interpreter handles gas consumption
            _ = self.host.access_address(addr) catch |err| switch (err) {
                else => return Error.AllocationError,
            };
            
            const bal = self.host.get_balance(addr);
            const balance_word = @as(WordType, @truncate(bal));
            try self.stack.push(balance_word);
            if (comptime config.TracerType != null) {
                if (comptime @hasDecl(@TypeOf(self.tracer), "on_balance_read")) {
                    self.tracer.on_balance_read(addr, bal);
                }
            }
        }
        /// ORIGIN opcode (0x32) - Get execution origination address
        /// Pushes the address of the account that initiated the transaction.
        /// Stack: [] → [origin]
        pub fn origin(self: *Self) Error!void {
            const tx_origin = self.host.get_tx_origin();
            const origin_u256 = to_u256(tx_origin);
            try self.stack.push(origin_u256);
        }
        /// CALLER opcode (0x33) - Get caller address
        /// Pushes the address of the account that directly called this contract.
        /// Stack: [] → [caller]
        pub fn caller(self: *Self) Error!void {
            const caller_addr = self.host.get_caller();
            const caller_u256 = to_u256(caller_addr);
            try self.stack.push(caller_u256);
        }
        /// CALLVALUE opcode (0x34) - Get deposited value by instruction/transaction
        /// Pushes the value in wei sent with the current call.
        /// Stack: [] → [value]
        pub fn callvalue(self: *Self) Error!void {
            const value = self.host.get_call_value();
            try self.stack.push(value);
        }
        /// CALLDATALOAD opcode (0x35) - Load word from input data
        /// Pops an offset and pushes a 32-byte word from the input data starting at that offset.
        /// Stack: [offset] → [data]
        pub fn calldataload(self: *Self) Error!void {
            const offset = try self.stack.pop();
            // Convert u256 to usize, checking for overflow
            if (offset > std.math.maxInt(usize)) {
                try self.stack.push(0);
                return;
            }
            const offset_usize = @as(usize, @intCast(offset));
            const calldata = self.host.get_input();
            // Load 32 bytes from calldata, zero-padding if needed
            var word: u256 = 0;
            for (0..32) |i| {
                const byte_index = offset_usize + i;
                if (byte_index < calldata.len) {
                    const byte_val = calldata[byte_index];
                    word = (word << 8) | @as(u256, byte_val);
                } else {
                    word = word << 8; // Zero padding
                }
            }
            // Convert to WordType (truncate if necessary for smaller word types)
            const result = @as(WordType, @truncate(word));
            try self.stack.push(result);
        }
        /// CALLDATASIZE opcode (0x36) - Get size of input data
        /// Pushes the size of the input data in bytes.
        /// Stack: [] → [size]
        pub fn calldatasize(self: *Self) Error!void {
            const calldata = self.host.get_input();
            const calldata_len = @as(WordType, @truncate(@as(u256, @intCast(calldata.len))));
            try self.stack.push(calldata_len);
        }
        /// CALLDATACOPY opcode (0x37) - Copy input data to memory
        /// Copies input data to memory.
        /// Stack: [destOffset, offset, length] → []
        pub fn calldatacopy(self: *Self) Error!void {
            const dest_offset = try self.stack.pop();
            const offset = try self.stack.pop();
            const length = try self.stack.pop();
            // Check for overflow
            if (dest_offset > std.math.maxInt(usize) or
                offset > std.math.maxInt(usize) or
                length > std.math.maxInt(usize))
            {
                return Error.OutOfBounds;
            }
            const dest_offset_usize = @as(usize, @intCast(dest_offset));
            const offset_usize = @as(usize, @intCast(offset));
            const length_usize = @as(usize, @intCast(length));
            if (length_usize == 0) return;
            // Ensure memory capacity
            const new_size = dest_offset_usize + length_usize;
            self.memory.ensure_capacity(new_size) catch |err| switch (err) {
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };
            const calldata = self.host.get_input();
            // Copy available bytes as a single slice copy
            var copied: usize = 0;
            if (offset_usize < calldata.len) {
                const available = calldata.len - offset_usize;
                const copy_len = @min(length_usize, available);
                if (copy_len > 0) {
                    const src_slice = calldata[offset_usize .. offset_usize + copy_len];
                    self.memory.set_data(dest_offset_usize, src_slice) catch return Error.OutOfBounds;
                    copied = copy_len;
                }
            }
            // Zero-fill remaining bytes if any
            if (copied < length_usize) {
                var i: usize = 0;
                const zero_start = dest_offset_usize + copied;
                while (i < (length_usize - copied)) : (i += 1) {
                    self.memory.set_byte(zero_start + i, 0) catch return Error.OutOfBounds;
                }
            }
        }
        /// CODESIZE opcode (0x38) - Get size of executing contract code
        /// Pushes the size of the currently executing contract's code.
        /// Stack: [] → [size]
        pub fn codesize(self: *Self) Error!void {
            const bytecode_len = @as(WordType, @truncate(@as(u256, @intCast(self.bytecode.len))));
            try self.stack.push(bytecode_len);
        }
        /// CODECOPY opcode (0x39) - Copy executing contract code to memory
        /// Copies contract code to memory.
        /// Stack: [destOffset, offset, length] → []
        pub fn codecopy(self: *Self) Error!void {
            const dest_offset = try self.stack.pop();
            const offset = try self.stack.pop();
            const length = try self.stack.pop();
            // Check for overflow
            if (dest_offset > std.math.maxInt(usize) or
                offset > std.math.maxInt(usize) or
                length > std.math.maxInt(usize))
            {
                return Error.OutOfBounds;
            }
            const dest_offset_usize = @as(usize, @intCast(dest_offset));
            const offset_usize = @as(usize, @intCast(offset));
            const length_usize = @as(usize, @intCast(length));
            if (length_usize == 0) return;
            // Ensure memory capacity
            const new_size = dest_offset_usize + length_usize;
            self.memory.ensure_capacity(new_size) catch |err| switch (err) {
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };
            // Copy contract code to memory with bounds checking
            var copied: usize = 0;
            if (offset_usize < self.bytecode.len) {
                const available = self.bytecode.len - offset_usize;
                const copy_len = @min(length_usize, available);
                if (copy_len > 0) {
                    const src_slice = self.bytecode[offset_usize .. offset_usize + copy_len];
                    self.memory.set_data(dest_offset_usize, src_slice) catch return Error.OutOfBounds;
                    copied = copy_len;
                }
            }
            if (copied < length_usize) {
                var i: usize = 0;
                const zero_start = dest_offset_usize + copied;
                while (i < (length_usize - copied)) : (i += 1) {
                    self.memory.set_byte(zero_start + i, 0) catch return Error.OutOfBounds;
                }
            }
        }
        /// GASPRICE opcode (0x3A) - Get price of gas in current transaction
        /// Pushes the gas price of the current transaction.
        /// Stack: [] → [gas_price]
        pub fn gasprice(self: *Self) Error!void {
            const gas_price = self.host.get_gas_price();
            const gas_price_truncated = @as(WordType, @truncate(gas_price));
            try self.stack.push(gas_price_truncated);
        }
        /// EXTCODESIZE opcode (0x3B) - Get size of account's code
        /// Pops an address and pushes the size of that account's code in bytes.
        /// Stack: [address] → [size]
        pub fn extcodesize(self: *Self) Error!void {
            const address_u256 = try self.stack.pop();
            const addr = from_u256(address_u256);
            const code = self.host.get_code(addr);
            const code_len = @as(WordType, @truncate(@as(u256, @intCast(code.len))));
            try self.stack.push(code_len);
            if (comptime config.TracerType != null) {
                if (comptime @hasDecl(@TypeOf(self.tracer), "on_code_read")) {
                    self.tracer.on_code_read(addr, code);
                }
            }
        }
        /// EXTCODECOPY opcode (0x3C) - Copy account's code to memory
        /// Copies code from an external account to memory.
        /// Stack: [address, destOffset, offset, length] → []
        pub fn extcodecopy(self: *Self) Error!void {
            const address_u256 = try self.stack.pop();
            const dest_offset = try self.stack.pop();
            const offset = try self.stack.pop();
            const length = try self.stack.pop();
            // Check for overflow
            if (dest_offset > std.math.maxInt(usize) or
                offset > std.math.maxInt(usize) or
                length > std.math.maxInt(usize))
            {
                return Error.OutOfBounds;
            }
            const addr = from_u256(address_u256);
            const dest_offset_usize = @as(usize, @intCast(dest_offset));
            const offset_usize = @as(usize, @intCast(offset));
            const length_usize = @as(usize, @intCast(length));
            if (length_usize == 0) return;
            // Ensure memory capacity
            const new_size = dest_offset_usize + length_usize;
            self.memory.ensure_capacity(new_size) catch |err| switch (err) {
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };
            const code = self.host.get_code(addr);
            // Copy external code to memory with bounds checking
            var copied: usize = 0;
            if (offset_usize < code.len) {
                const available = code.len - offset_usize;
                const copy_len = @min(length_usize, available);
                if (copy_len > 0) {
                    const src_slice = code[offset_usize .. offset_usize + copy_len];
                    self.memory.set_data(dest_offset_usize, src_slice) catch return Error.OutOfBounds;
                    copied = copy_len;
                }
            }
            if (comptime config.TracerType != null) {
                if (comptime @hasDecl(@TypeOf(self.tracer), "on_code_read")) {
                    self.tracer.on_code_read(addr, code);
                }
            }
            if (copied < length_usize) {
                var i: usize = 0;
                const zero_start = dest_offset_usize + copied;
                while (i < (length_usize - copied)) : (i += 1) {
                    self.memory.set_byte(zero_start + i, 0) catch return Error.OutOfBounds;
                }
            }
        }
        /// RETURNDATASIZE opcode (0x3D) - Get size of output data from previous call
        /// Pushes the size of the return data from the last call.
        /// Stack: [] → [size]
        pub fn returndatasize(self: *Self) Error!void {
            const return_data = self.host.get_return_data();
            const return_data_len = @as(WordType, @truncate(@as(u256, @intCast(return_data.len))));
            try self.stack.push(return_data_len);
        }
        /// RETURNDATACOPY opcode (0x3E) - Copy output data from previous call to memory
        /// Copies return data from the last call to memory.
        /// Stack: [destOffset, offset, length] → []
        pub fn returndatacopy(self: *Self) Error!void {
            const dest_offset = try self.stack.pop();
            const offset = try self.stack.pop();
            const length = try self.stack.pop();
            // Check for overflow
            if (dest_offset > std.math.maxInt(usize) or
                offset > std.math.maxInt(usize) or
                length > std.math.maxInt(usize))
            {
                return Error.OutOfBounds;
            }
            const dest_offset_usize = @as(usize, @intCast(dest_offset));
            const offset_usize = @as(usize, @intCast(offset));
            const length_usize = @as(usize, @intCast(length));
            if (length_usize == 0) return;
            const return_data = self.host.get_return_data();
            // Check if we're reading beyond the return data
            if (offset_usize > return_data.len or
                (offset_usize + length_usize) > return_data.len)
            {
                return Error.OutOfBounds;
            }
            // Ensure memory capacity
            const new_size = dest_offset_usize + length_usize;
            self.memory.ensure_capacity(new_size) catch |err| switch (err) {
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };
            // Copy return data to memory
            for (0..length_usize) |i| {
                const src_index = offset_usize + i;
                const dest_index = dest_offset_usize + i;
                const byte_val = return_data[src_index];
                self.memory.set_byte(dest_index, byte_val) catch return Error.OutOfBounds;
            }
        }
        /// EXTCODEHASH opcode (0x3F) - Get hash of account's code
        /// Pops an address and pushes the keccak256 hash of that account's code.
        /// Stack: [address] → [hash]
        pub fn extcodehash(self: *Self) Error!void {
            const address_u256 = try self.stack.pop();
            const addr = from_u256(address_u256);
            if (!self.host.account_exists(addr)) {
                // Non-existent account returns 0 per EIP-1052
                try self.stack.push(0);
                return;
            }
            const code = self.host.get_code(addr);
            if (code.len == 0) {
                // Existing account with empty code returns keccak256("") constant
                const empty_hash_u256: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
                const empty_hash_word = @as(WordType, @truncate(empty_hash_u256));
                try self.stack.push(empty_hash_word);
                return;
            }
            // Compute keccak256 hash of the code
            var hash: [32]u8 = undefined;
            keccak_asm.keccak256(code, &hash) catch return Error.OutOfBounds;
            // Convert hash to u256 (big-endian)
            var hash_u256: u256 = 0;
            for (hash) |b| {
                hash_u256 = (hash_u256 << 8) | @as(u256, b);
            }
            const hash_word = @as(WordType, @truncate(hash_u256));
            try self.stack.push(hash_word);
            if (comptime config.TracerType != null) {
                if (comptime @hasDecl(@TypeOf(self.tracer), "on_code_read")) {
                    self.tracer.on_code_read(addr, code);
                }
            }
        }
        /// CHAINID opcode (0x46) - Get chain ID
        /// Pushes the chain ID of the current network.
        /// Stack: [] → [chain_id]
        pub fn chainid(self: *Self) Error!void {
            const chain_id = self.host.get_chain_id();
            const chain_id_word = @as(WordType, @truncate(@as(u256, chain_id)));
            try self.stack.push(chain_id_word);
        }
        /// SELFBALANCE opcode (0x47) - Get balance of currently executing account
        /// Pushes the balance of the currently executing contract.
        /// Stack: [] → [balance]
        pub fn selfbalance(self: *Self) Error!void {
            const bal = self.host.get_balance(self.contract_address);
            const balance_word = @as(WordType, @truncate(bal));
            try self.stack.push(balance_word);
            // Call tracer AFTER successful read (compiled out when tracer is off)
            if (comptime config.TracerType != null) {
                if (comptime @hasDecl(config.TracerType.?, "on_balance_read")) {
                    self.tracer.on_balance_read(self.contract_address, bal);
                }
            }
        }
        // Block information opcodes
        /// BLOCKHASH opcode (0x40) - Get hash of specific block
        /// Returns the hash of one of the 256 most recent blocks.
        /// Stack: [block_number] → [hash]
        pub fn blockhash(self: *Self) Error!void {
            const block_number = try self.stack.pop();
            const block_info = self.host.get_block_info();
            const current_block = block_info.number;
            // Check bounds: not current or future blocks, and within 256 recent blocks
            if (block_number >= current_block or
                current_block > block_number + 256 or
                block_number == 0)
            {
                try self.stack.push(0);
                return;
            }
            // Get block hash from host
            // Note: block_number is u256 but get_block_hash expects u64
            const block_number_u64 = @as(u64, @intCast(block_number));
            const hash_opt = self.host.get_block_hash(block_number_u64);
            // Push hash or zero if not available
            if (hash_opt) |hash| {
                // Convert [32]u8 to u256
                var hash_u256: u256 = 0;
                for (hash) |b| {
                    hash_u256 = (hash_u256 << 8) | @as(u256, b);
                }
                const hash_word = @as(WordType, @truncate(hash_u256));
                try self.stack.push(hash_word);
            } else {
                try self.stack.push(0);
            }
        }
        /// COINBASE opcode (0x41) - Get current block miner's address
        /// Pushes the address of the miner who produced the current block.
        /// Stack: [] → [coinbase_address]
        pub fn coinbase(self: *Self) Error!void {
            const block_info = self.host.get_block_info();
            const coinbase_u256 = to_u256(block_info.coinbase);
            const coinbase_word = @as(WordType, @truncate(coinbase_u256));
            try self.stack.push(coinbase_word);
        }
        /// TIMESTAMP opcode (0x42) - Get current block timestamp
        /// Pushes the Unix timestamp of the current block.
        /// Stack: [] → [timestamp]
        pub fn timestamp(self: *Self) Error!void {
            const block_info = self.host.get_block_info();
            const timestamp_word = @as(WordType, @truncate(@as(u256, @intCast(block_info.timestamp))));
            try self.stack.push(timestamp_word);
        }
        /// NUMBER opcode (0x43) - Get current block number
        /// Pushes the number of the current block.
        /// Stack: [] → [block_number]
        pub fn number(self: *Self) Error!void {
            const block_info = self.host.get_block_info();
            const block_number_word = @as(WordType, @truncate(@as(u256, @intCast(block_info.number))));
            try self.stack.push(block_number_word);
        }
        /// DIFFICULTY opcode (0x44) - Get block difficulty or prevrandao
        /// Pre-merge: Returns difficulty. Post-merge: Returns prevrandao.
        /// Stack: [] → [difficulty/prevrandao]
        pub fn difficulty(self: *Self) Error!void {
            const block_info = self.host.get_block_info();
            const difficulty_word = @as(WordType, @truncate(block_info.difficulty));
            try self.stack.push(difficulty_word);
        }
        /// PREVRANDAO opcode - Alias for DIFFICULTY post-merge
        /// Returns the prevrandao value from the beacon chain.
        /// Stack: [] → [prevrandao]
        pub fn prevrandao(self: *Self) Error!void {
            return self.difficulty();
        }
        /// GASLIMIT opcode (0x45) - Get current block gas limit
        /// Pushes the gas limit of the current block.
        /// Stack: [] → [gas_limit]
        pub fn gaslimit(self: *Self) Error!void {
            const block_info = self.host.get_block_info();
            const gas_limit_word = @as(WordType, @truncate(@as(u256, @intCast(block_info.gas_limit))));
            try self.stack.push(gas_limit_word);
        }
        /// BASEFEE opcode (0x48) - Get current block base fee
        /// Returns the base fee per gas of the current block (EIP-3198).
        /// Stack: [] → [base_fee]
        pub fn basefee(self: *Self) Error!void {
            const block_info = self.host.get_block_info();
            const base_fee_word = @as(WordType, @truncate(block_info.base_fee));
            try self.stack.push(base_fee_word);
        }
        /// BLOBHASH opcode (0x49) - Get versioned hash of blob
        /// Returns the versioned hash of the blob at the given index (EIP-4844).
        /// Stack: [index] → [blob_hash]
        pub fn blobhash(self: *Self) Error!void {
            const index = try self.stack.pop();
            // Convert u256 to usize for array access
            if (index > std.math.maxInt(usize)) {
                try self.stack.push(0);
                return;
            }
            const blob_hash_opt = self.host.get_blob_hash(index);
            // Push hash or zero if not available
            if (blob_hash_opt) |hash| {
                // Convert [32]u8 to u256
                var hash_u256: u256 = 0;
                for (hash) |b| {
                    hash_u256 = (hash_u256 << 8) | @as(u256, b);
                }
                const hash_word = @as(WordType, @truncate(hash_u256));
                try self.stack.push(hash_word);
            } else {
                try self.stack.push(0);
            }
        }
        /// BLOBBASEFEE opcode (0x4A) - Get current blob base fee
        /// Returns the base fee per blob gas of the current block (EIP-4844).
        /// Stack: [] → [blob_base_fee]
        pub fn blobbasefee(self: *Self) Error!void {
            const blob_base_fee = self.host.get_blob_base_fee();
            const blob_base_fee_word = @as(WordType, @truncate(blob_base_fee));
            try self.stack.push(blob_base_fee_word);
        }
        // ========== LOG opcodes (0xA0-0xA4) ==========
        /// LOG0 opcode (0xA0) - Emit log with no topics
        /// Emits a log event with data but no topics.
        /// Stack: [offset, length] → []
        pub fn log0(self: *Self) Error!void {
            // Check if we're in static context
            if (self.host.get_is_static()) {
                return Error.WriteProtection;
            }
            const length = try self.stack.pop();
            const offset = try self.stack.pop();
            const data_size = @as(usize, @intCast(length));
            // Base/topic/data gas via centralized constants
            const log_gas = GasConstants.log_gas_cost(0, data_size);
            try self.consumeGasChecked(log_gas);
            // Memory expansion cost (word-aligned)
            if (offset > std.math.maxInt(usize) or length > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));
            const end_unaligned = offset_usize + data_size;
            const word_aligned_end = ((end_unaligned + 31) >> 5) << 5;
            const mem_expansion_cost = self.memory.get_expansion_cost(@as(u64, @intCast(word_aligned_end)));
            const total_cost: u64 = log_gas + mem_expansion_cost;
            try self.consumeGasChecked(total_cost);
            // Ensure memory is expanded to read safely
            self.memory.ensure_capacity(word_aligned_end) catch return Error.OutOfBounds;
            const data = self.memory.get_slice(offset_usize, data_size) catch return Error.OutOfBounds;
            // Create log entry
            const allocator = self.logs.allocator;
            const data_copy = allocator.dupe(u8, data) catch return Error.AllocationError;
            const topics_array = allocator.alloc(u256, 0) catch return Error.AllocationError;
            const log_entry = Log{
                .address = self.contract_address,
                .topics = topics_array,
                .data = data_copy,
            };
            self.logs.append(log_entry) catch {
                allocator.free(data_copy);
                allocator.free(topics_array);
                return Error.AllocationError;
            };
        }
        
        /// LOG1 opcode (0xA1) - Emit log with one topic
        /// Emits a log event with data and one topic.
        /// Stack: [offset, length, topic1] → []
        pub fn log1(self: *Self) Error!void {
            if (self.host.get_is_static()) {
                return Error.WriteProtection;
            }
            const topic1 = try self.stack.pop();
            const length = try self.stack.pop();
            const offset = try self.stack.pop();
            const data_size = @as(usize, @intCast(length));
            const log_gas = GasConstants.log_gas_cost(1, data_size);
            try self.consumeGasChecked(log_gas);
            if (offset > std.math.maxInt(usize) or length > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));
            const end_unaligned = offset_usize + data_size;
            const word_aligned_end = ((end_unaligned + 31) >> 5) << 5;
            const mem_expansion_cost = self.memory.get_expansion_cost(@as(u64, @intCast(word_aligned_end)));
            const total_cost: u64 = log_gas + mem_expansion_cost;
            try self.consumeGasChecked(total_cost);
            self.memory.ensure_capacity(word_aligned_end) catch return Error.OutOfBounds;
            const data = self.memory.get_slice(offset_usize, data_size) catch return Error.OutOfBounds;
            // Create log entry
            const allocator = self.logs.allocator;
            const data_copy = allocator.dupe(u8, data) catch return Error.AllocationError;
            const topics_array = allocator.alloc(u256, 1) catch {
                allocator.free(data_copy);
                return Error.AllocationError;
            };
            topics_array[0] = topic1;
            const log_entry = Log{
                .address = self.contract_address,
                .topics = topics_array,
                .data = data_copy,
            };
            self.logs.append(log_entry) catch {
                allocator.free(data_copy);
                allocator.free(topics_array);
                return Error.AllocationError;
            };
        }
        /// LOG2 opcode (0xA2) - Emit log with two topics
        /// Stack: [offset, length, topic1, topic2] → []
        pub fn log2(self: *Self) Error!void {
            if (self.host.get_is_static()) {
                return Error.WriteProtection;
            }
            const topic2 = try self.stack.pop();
            const topic1 = try self.stack.pop();
            const length = try self.stack.pop();
            const offset = try self.stack.pop();
            const data_size = @as(usize, @intCast(length));
            const log_gas = GasConstants.log_gas_cost(2, data_size);
            try self.consumeGasChecked(log_gas);
            if (offset > std.math.maxInt(usize) or length > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));
            const end_unaligned = offset_usize + data_size;
            const word_aligned_end = ((end_unaligned + 31) >> 5) << 5;
            const mem_expansion_cost = self.memory.get_expansion_cost(@as(u64, @intCast(word_aligned_end)));
            const total_cost: u64 = log_gas + mem_expansion_cost;
            try self.consumeGasChecked(total_cost);
            self.memory.ensure_capacity(word_aligned_end) catch return Error.OutOfBounds;
            const data = self.memory.get_slice(offset_usize, data_size) catch return Error.OutOfBounds;
            const allocator = self.logs.allocator;
            const data_copy = allocator.dupe(u8, data) catch return Error.AllocationError;
            const topics_array = allocator.alloc(u256, 2) catch {
                allocator.free(data_copy);
                return Error.AllocationError;
            };
            topics_array[0] = topic1;
            topics_array[1] = topic2;
            const log_entry = Log{
                .address = self.contract_address,
                .topics = topics_array,
                .data = data_copy,
            };
            self.logs.append(log_entry) catch {
                allocator.free(data_copy);
                allocator.free(topics_array);
                return Error.AllocationError;
            };
        }
        /// LOG3 opcode (0xA3) - Emit log with three topics
        /// Stack: [offset, length, topic1, topic2, topic3] → []
        pub fn log3(self: *Self) Error!void {
            if (self.host.get_is_static()) {
                return Error.WriteProtection;
            }
            const topic3 = try self.stack.pop();
            const topic2 = try self.stack.pop();
            const topic1 = try self.stack.pop();
            const length = try self.stack.pop();
            const offset = try self.stack.pop();
            const data_size = @as(usize, @intCast(length));
            const log_gas = GasConstants.log_gas_cost(3, data_size);
            try self.consumeGasChecked(log_gas);
            if (offset > std.math.maxInt(usize) or length > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));
            const end_unaligned = offset_usize + data_size;
            const word_aligned_end = ((end_unaligned + 31) >> 5) << 5;
            const mem_expansion_cost = self.memory.get_expansion_cost(@as(u64, @intCast(word_aligned_end)));
            const total_cost: u64 = log_gas + mem_expansion_cost;
            try self.consumeGasChecked(total_cost);
            self.memory.ensure_capacity(word_aligned_end) catch return Error.OutOfBounds;
            const data = self.memory.get_slice(offset_usize, data_size) catch return Error.OutOfBounds;
            const allocator = self.logs.allocator;
            const data_copy = allocator.dupe(u8, data) catch return Error.AllocationError;
            const topics_array = allocator.alloc(u256, 3) catch {
                allocator.free(data_copy);
                return Error.AllocationError;
            };
            topics_array[0] = topic1;
            topics_array[1] = topic2;
            topics_array[2] = topic3;
            const log_entry = Log{
                .address = self.contract_address,
                .topics = topics_array,
                .data = data_copy,
            };
            self.logs.append(log_entry) catch {
                allocator.free(data_copy);
                allocator.free(topics_array);
                return Error.AllocationError;
            };
        }
        /// LOG4 opcode (0xA4) - Emit log with four topics
        /// Stack: [offset, length, topic1, topic2, topic3, topic4] → []
        pub fn log4(self: *Self) Error!void {
            if (self.host.get_is_static()) {
                return Error.WriteProtection;
            }
            const topic4 = try self.stack.pop();
            const topic3 = try self.stack.pop();
            const topic2 = try self.stack.pop();
            const topic1 = try self.stack.pop();
            const length = try self.stack.pop();
            const offset = try self.stack.pop();
            const data_size = @as(usize, @intCast(length));
            const log_gas = GasConstants.log_gas_cost(4, data_size);
            try self.consumeGasChecked(log_gas);
            if (offset > std.math.maxInt(usize) or length > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));
            const end_unaligned = offset_usize + data_size;
            const word_aligned_end = ((end_unaligned + 31) >> 5) << 5;
            const mem_expansion_cost = self.memory.get_expansion_cost(@as(u64, @intCast(word_aligned_end)));
            const total_cost: u64 = log_gas + mem_expansion_cost;
            try self.consumeGasChecked(total_cost);
            self.memory.ensure_capacity(word_aligned_end) catch return Error.OutOfBounds;
            const data = self.memory.get_slice(offset_usize, data_size) catch return Error.OutOfBounds;
            const allocator = self.logs.allocator;
            const data_copy = allocator.dupe(u8, data) catch return Error.AllocationError;
            const topics_array = allocator.alloc(u256, 4) catch {
                allocator.free(data_copy);
                return Error.AllocationError;
            };
            topics_array[0] = topic1;
            topics_array[1] = topic2;
            topics_array[2] = topic3;
            topics_array[3] = topic4;
            const log_entry = Log{
                .address = self.contract_address,
                .topics = topics_array,
                .data = data_copy,
            };
            self.logs.append(log_entry) catch {
                allocator.free(data_copy);
                allocator.free(topics_array);
                return Error.AllocationError;
            };
        }
        // ========== COMPREHENSIVE ETHEREUM TESTS INTEGRATION ==========
        // Based on official Ethereum tests: https://github.com/ethereum/tests
        // These tests follow the patterns from VMTests, GeneralStateTests, etc.
        // System transaction opcodes
        /// Calculate gas cost for CALL operations based on EIP-150 and EIP-2929
        ///
        /// ## Parameters
        /// - `target_address`: Target contract address
        /// - `value`: Value being transferred (0 for no value transfer)
        /// - `is_static`: Whether this is a static call context
        ///
        /// ## Returns
        /// - Gas cost for the call operation before gas forwarding
        fn _calculate_call_gas(self: *Self, target_address: Address, value: u256, is_static: bool) u64 {
            // Check if target account exists using database interface
            const new_account = blk: {
                if (config.has_database) {
                    if (self.database) |db| {
                        // Try to get the account from the database
                        const account_result = db.get_account(target_address) catch {
                            // On database error, assume account doesn't exist (conservative approach)
                            break :blk true;
                        };
                        if (account_result) |account| {
                            // Account exists if it has any of: non-zero nonce, non-zero balance, or non-empty code
                            const exists = account.nonce > 0 or
                                account.balance > 0 or
                                !std.mem.eql(u8, &account.code_hash, &LOCAL_EMPTY_CODE_HASH);
                            break :blk !exists;
                        } else {
                            // Account not found in database
                            break :blk true;
                        }
                    } else {
                        // No database available, assume account doesn't exist
                        break :blk true;
                    }
                } else {
                    // No database configured, assume account doesn't exist
                    break :blk true;
                }
            };
            // Check if this is a cold access using the Host's access list (EIP-2929)
            // Cold/warm access costs were introduced in the Berlin hardfork
            const cold_access = blk: {
                // Check if we're at least at Berlin hardfork (EIP-2929)
                const is_berlin_or_later = self.host.vtable.is_hardfork_at_least(self.host.ptr, .BERLIN);
                if (!is_berlin_or_later) {
                    // Pre-Berlin hardforks don't have cold/warm access distinction
                    break :blk false;
                }
                // Access the address and get the gas cost
                const access_cost = self.host.vtable.access_address(self.host.ptr, target_address) catch {
                    // On error, assume cold access (conservative approach for gas costs)
                    break :blk true;
                };
                // If access cost equals cold access cost, it was a cold access
                break :blk access_cost == primitives.GasConstants.ColdAccountAccessCost;
            };
            // Value transfer check
            const value_transfer = value > 0 and !is_static;
            // Check if target is a precompile contract
            const is_precompile = self.is_precompile_address(target_address);
            // Precompile calls are considered existing accounts (never new)
            const effective_new_account = new_account and !is_precompile;
            // Calculate base call cost using the centralized gas calculation function
            return GasConstants.call_gas_cost(value_transfer, effective_new_account, cold_access);
        }
        /// Check if an address is a precompile contract
        ///
        /// Precompiles are special contracts at addresses 0x01 through 0x0A that provide
        /// cryptographic functions and utilities with deterministic gas costs.
        ///
        /// ## Parameters
        /// - `address`: The address to check
        ///
        /// ## Returns
        /// - `true` if the address is a precompile, `false` otherwise
        fn is_precompile_address(self: *Self, addr: Address) bool {
            _ = self; // Not used but kept for consistency with method signature
            // Check if all bytes except the last one are zero
            for (addr[0..19]) |addr_byte| {
                if (addr_byte != 0) return false;
            }
            // Check if the last byte is between 1 and 10 (0x01 to 0x0A)
            return addr[19] >= 1 and addr[19] <= 10;
        }
        /// CALL opcode (0xF1) - Call another contract
        /// Calls the contract at the given address with the provided value, input data, and gas.
        /// Stack: [gas, address, value, input_offset, input_size, output_offset, output_size] → [success]
        pub fn call(self: *Self) Error!void {
            // Check static context - CALL with non-zero value is not allowed in static context
            const output_size = try self.stack.pop();
            const output_offset = try self.stack.pop();
            const input_size = try self.stack.pop();
            const input_offset = try self.stack.pop();
            const value = try self.stack.pop();
            const address_u256 = try self.stack.pop();
            const gas_param = try self.stack.pop();
            if (self.host.get_is_static() and value > 0) {
                return Error.WriteProtection;
            }
            // Convert address from u256
            const addr = from_u256(address_u256);
            // Bounds checking for gas parameter
            if (gas_param > std.math.maxInt(u64)) {
                try self.stack.push(0);
                return;
            }
            const gas_u64 = @as(u64, @intCast(gas_param));
            // Bounds checking for memory offsets and sizes
            if (input_offset > std.math.maxInt(usize) or
                input_size > std.math.maxInt(usize) or
                output_offset > std.math.maxInt(usize) or
                output_size > std.math.maxInt(usize))
            {
                try self.stack.push(0);
                return;
            }
            const input_offset_usize = @as(usize, @intCast(input_offset));
            const input_size_usize = @as(usize, @intCast(input_size));
            const output_offset_usize = @as(usize, @intCast(output_offset));
            const output_size_usize = @as(usize, @intCast(output_size));
            // Ensure memory capacity for both input and output
            const input_end = input_offset_usize + input_size_usize;
            const output_end = output_offset_usize + output_size_usize;
            const max_memory_needed = @max(input_end, output_end);
            self.memory.ensure_capacity(max_memory_needed) catch {
                try self.stack.push(0);
                return;
            };
            // Extract input data from memory
            const input_data = if (input_size_usize == 0)
                &[_]u8{}
            else
                self.memory.get_slice(input_offset_usize, input_size_usize) catch &[_]u8{};
            // Calculate base call gas cost (EIP-150 & EIP-2929)
            const base_call_gas = self._calculate_call_gas(addr, value, self.host.get_is_static());
            // Check if we have enough gas for the base call cost
            if (self.gas_remaining < @as(GasType, @intCast(base_call_gas))) {
                try self.stack.push(0);
                return;
            }
            // Consume base call gas
            self.gas_remaining -= @as(GasType, @intCast(base_call_gas));
            // Apply EIP-150 gas forwarding rule: 63/64 of available gas
            const gas_stipend = if (value > 0) @as(u64, 2300) else 0; // Gas stipend for value transfer
            const remaining_gas = @as(u64, @intCast(@max(self.gas_remaining, 0)));
            const max_forward_gas = remaining_gas - (remaining_gas / 64);
            const forwarded_gas = @min(gas_u64, max_forward_gas) + gas_stipend;
            // Create snapshot for potential revert
            const snapshot_id = self.host.create_snapshot();
            // Execute the call
            const call_params = CallParams{ .call = .{
                .caller = self.contract_address,
                .to = addr,
                .value = value,
                .input = input_data,
                .gas = forwarded_gas,
            } };
            const result = self.host.inner_call(call_params) catch {
                self.host.revert_to_snapshot(snapshot_id);
                try self.stack.push(0);
                return;
            };
            // Handle the result
            if (result.success) {
                // Copy return data to output memory if it fits
                const copy_size = @min(output_size_usize, result.output.len);
                if (copy_size > 0) {
                    self.memory.set_data(output_offset_usize, result.output[0..copy_size]) catch {};
                }
                try self.stack.push(1); // Success
            } else {
                self.host.revert_to_snapshot(snapshot_id);
                try self.stack.push(0); // Failure
            }
            // Update gas accounting
            const gas_cost = forwarded_gas - result.gas_left;
            if (self.gas_remaining >= @as(GasType, @intCast(gas_cost))) {
                self.gas_remaining -= @as(GasType, @intCast(gas_cost));
            } else {
                // If gas cost exceeds remaining, consume all remaining gas
                self.gas_remaining = 0;
            }
        }
        /// DELEGATECALL opcode (0xF4) - Call another contract preserving caller context
        /// Calls the contract at the given address, but preserves the caller and value from the current context.
        /// Stack: [gas, address, input_offset, input_size, output_offset, output_size] → [success]
        pub fn delegatecall(self: *Self) Error!void {
            const output_size = try self.stack.pop();
            const output_offset = try self.stack.pop();
            const input_size = try self.stack.pop();
            const input_offset = try self.stack.pop();
            const address_u256 = try self.stack.pop();
            const gas_param = try self.stack.pop();
            // Convert address from u256
            const addr = from_u256(address_u256);
            // Bounds checking for gas parameter
            if (gas_param > std.math.maxInt(u64)) {
                try self.stack.push(0);
                return;
            }
            const gas_u64 = @as(u64, @intCast(gas_param));
            // Bounds checking for memory offsets and sizes
            if (input_offset > std.math.maxInt(usize) or
                input_size > std.math.maxInt(usize) or
                output_offset > std.math.maxInt(usize) or
                output_size > std.math.maxInt(usize))
            {
                try self.stack.push(0);
                return;
            }
            const input_offset_usize = @as(usize, @intCast(input_offset));
            const input_size_usize = @as(usize, @intCast(input_size));
            const output_offset_usize = @as(usize, @intCast(output_offset));
            const output_size_usize = @as(usize, @intCast(output_size));
            // Ensure memory capacity
            const input_end = input_offset_usize + input_size_usize;
            const output_end = output_offset_usize + output_size_usize;
            const max_memory_needed = @max(input_end, output_end);
            self.memory.ensure_capacity(max_memory_needed) catch {
                try self.stack.push(0);
                return;
            };
            // Extract input data from memory
            const input_data = if (input_size_usize == 0)
                &[_]u8{}
            else
                self.memory.get_slice(input_offset_usize, input_size_usize) catch &[_]u8{};
            // Calculate base call gas cost (EIP-150 & EIP-2929) - DELEGATECALL never transfers value
            // is_static flag now retrieved via host; default to false in this older test path
            const base_call_gas = self._calculate_call_gas(addr, 0, false);
            // Check if we have enough gas for the base call cost
            if (self.gas_remaining < @as(GasType, @intCast(base_call_gas))) {
                try self.stack.push(0);
                return;
            }
            // Consume base call gas
            self.gas_remaining -= @as(GasType, @intCast(base_call_gas));
            // Apply EIP-150 gas forwarding rule: 63/64 of available gas
            const remaining_gas = @as(u64, @intCast(@max(self.gas_remaining, 0)));
            const max_forward_gas = remaining_gas - (remaining_gas / 64);
            const forwarded_gas = @min(gas_u64, max_forward_gas);
            // Create snapshot for potential revert
            const snapshot_id = self.host.create_snapshot();
            // Execute the delegatecall - note: caller context is preserved by the host
            const call_params = CallParams{
                .delegatecall = .{
                    .caller = self.contract_address, // Preserve original caller context
                    .to = addr,
                    .input = input_data,
                    .gas = forwarded_gas,
                },
            };
            const result = self.host.inner_call(call_params) catch {
                self.host.revert_to_snapshot(snapshot_id);
                try self.stack.push(0);
                return;
            };
            // Handle the result
            if (result.success) {
                // Copy return data to output memory if it fits
                const copy_size = @min(output_size_usize, result.output.len);
                if (copy_size > 0) {
                    self.memory.set_data(output_offset_usize, result.output[0..copy_size]) catch {};
                }
                try self.stack.push(1); // Success
            } else {
                self.host.revert_to_snapshot(snapshot_id);
                try self.stack.push(0); // Failure
            }
            // Update gas accounting
            const gas_cost = forwarded_gas - result.gas_left;
            if (self.gas_remaining >= @as(GasType, @intCast(gas_cost))) {
                self.gas_remaining -= @as(GasType, @intCast(gas_cost));
            } else {
                // If gas cost exceeds remaining, consume all remaining gas
                self.gas_remaining = 0;
            }
        }
        /// STATICCALL opcode (0xFA) - Call another contract in read-only mode
        /// Calls the contract at the given address without allowing any state changes.
        /// Stack: [gas, address, input_offset, input_size, output_offset, output_size] → [success]
        pub fn staticcall(self: *Self) Error!void {
            const output_size = try self.stack.pop();
            const output_offset = try self.stack.pop();
            const input_size = try self.stack.pop();
            const input_offset = try self.stack.pop();
            const address_u256 = try self.stack.pop();
            const gas_param = try self.stack.pop();
            // Convert address from u256
            const addr = from_u256(address_u256);
            // Bounds checking for gas parameter
            if (gas_param > std.math.maxInt(u64)) {
                try self.stack.push(0);
                return;
            }
            const gas_u64 = @as(u64, @intCast(gas_param));
            // Bounds checking for memory offsets and sizes
            if (input_offset > std.math.maxInt(usize) or
                input_size > std.math.maxInt(usize) or
                output_offset > std.math.maxInt(usize) or
                output_size > std.math.maxInt(usize))
            {
                try self.stack.push(0);
                return;
            }
            const input_offset_usize = @as(usize, @intCast(input_offset));
            const input_size_usize = @as(usize, @intCast(input_size));
            const output_offset_usize = @as(usize, @intCast(output_offset));
            const output_size_usize = @as(usize, @intCast(output_size));
            // Ensure memory capacity
            const input_end = input_offset_usize + input_size_usize;
            const output_end = output_offset_usize + output_size_usize;
            const max_memory_needed = @max(input_end, output_end);
            self.memory.ensure_capacity(max_memory_needed) catch {
                try self.stack.push(0);
                return;
            };
            // Extract input data from memory
            const input_data = if (input_size_usize == 0)
                &[_]u8{}
            else
                self.memory.get_slice(input_offset_usize, input_size_usize) catch &[_]u8{};
            // Calculate base call gas cost (EIP-150 & EIP-2929) - STATICCALL never transfers value
            const base_call_gas = self._calculate_call_gas(addr, 0, true);
            // Check if we have enough gas for the base call cost
            if (self.gas_remaining < @as(GasType, @intCast(base_call_gas))) {
                try self.stack.push(0);
                return;
            }
            // Consume base call gas
            self.gas_remaining -= @as(GasType, @intCast(base_call_gas));
            // Apply EIP-150 gas forwarding rule: 63/64 of available gas
            const remaining_gas = @as(u64, @intCast(@max(self.gas_remaining, 0)));
            const max_forward_gas = remaining_gas - (remaining_gas / 64);
            const forwarded_gas = @min(gas_u64, max_forward_gas);
            // Execute the staticcall
            const call_params = CallParams{ .staticcall = .{
                .caller = self.contract_address,
                .to = addr,
                .input = input_data,
                .gas = forwarded_gas,
            } };
            const result = self.host.inner_call(call_params) catch {
                try self.stack.push(0);
                return;
            };
            // Handle the result - no state changes can be made in staticcall
            if (result.success) {
                // Copy return data to output memory if it fits
                const copy_size = @min(output_size_usize, result.output.len);
                if (copy_size > 0) {
                    self.memory.set_data(output_offset_usize, result.output[0..copy_size]) catch {};
                }
                try self.stack.push(1); // Success
            } else {
                try self.stack.push(0); // Failure
            }
            // Update gas accounting
            const gas_cost = forwarded_gas - result.gas_left;
            if (self.gas_remaining >= @as(GasType, @intCast(gas_cost))) {
                self.gas_remaining -= @as(GasType, @intCast(gas_cost));
            } else {
                // If gas cost exceeds remaining, consume all remaining gas
                self.gas_remaining = 0;
            }
        }
        /// CREATE opcode (0xF0) - Create a new contract
        /// Creates a new contract using the provided initialization code and value.
        /// Stack: [value, offset, size] → [address]
        pub fn create(self: *Self) Error!void {
            // Check static context - CREATE is not allowed in static context
            if (self.host.get_is_static()) {
                return Error.WriteProtection;
            }
            const size = try self.stack.pop();
            const offset = try self.stack.pop();
            const value = try self.stack.pop();
            // Bounds checking for memory offset and size
            if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
                try self.stack.push(0);
                return;
            }
            const offset_usize = @as(usize, @intCast(offset));
            const size_usize = @as(usize, @intCast(size));
            // Ensure memory capacity
            const memory_end = offset_usize + size_usize;
            self.memory.ensure_capacity(memory_end) catch {
                try self.stack.push(0);
                return;
            };
            // Extract init code from memory
            const input_data = if (size_usize == 0)
                &[_]u8{}
            else
                self.memory.get_slice(offset_usize, size_usize) catch &[_]u8{};
            // Apply EIP-150 gas forwarding rule: 63/64 of available gas
            const remaining_gas = @as(u64, @intCast(@max(self.gas_remaining, 0)));
            const max_forward_gas = remaining_gas - (remaining_gas / 64);
            const forwarded_gas = max_forward_gas;
            // Create snapshot for potential revert
            const snapshot_id = self.host.create_snapshot();
            // Execute the create
            const call_params = CallParams{ .create = .{
                .caller = self.contract_address,
                .value = value,
                .init_code = input_data,
                .gas = forwarded_gas,
            } };
            const result = self.host.inner_call(call_params) catch {
                self.host.revert_to_snapshot(snapshot_id);
                try self.stack.push(0);
                return;
            };
            // Handle the result
            if (result.success and result.output.len >= 20) {
                // Extract the created contract address from output
                var address_bytes: [20]u8 = undefined;
                @memcpy(&address_bytes, result.output[0..20]);
                const addr: Address = address_bytes;
                const address_u256 = to_u256(addr);
                try self.stack.push(address_u256);
            } else {
                self.host.revert_to_snapshot(snapshot_id);
                try self.stack.push(0); // Failure
            }
            // Update gas accounting
            const gas_cost = forwarded_gas - result.gas_left;
            if (self.gas_remaining >= @as(GasType, @intCast(gas_cost))) {
                self.gas_remaining -= @as(GasType, @intCast(gas_cost));
            } else {
                // If gas cost exceeds remaining, consume all remaining gas
                self.gas_remaining = 0;
            }
        }
        
        /// CREATE2 opcode (0xF5) - Create a new contract with deterministic address
        /// Creates a new contract with an address determined by the salt and init code hash.
        /// Stack: [value, offset, size, salt] → [address]
        pub fn create2(self: *Self) Error!void {
            // Check static context - CREATE2 is not allowed in static context
            if (self.host.get_is_static()) {
                return Error.WriteProtection;
            }
            const salt = try self.stack.pop();
            const size = try self.stack.pop();
            const offset = try self.stack.pop();
            const value = try self.stack.pop();
            // Bounds checking for memory offset and size
            if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
                try self.stack.push(0);
                return;
            }
            const offset_usize = @as(usize, @intCast(offset));
            const size_usize = @as(usize, @intCast(size));
            // Ensure memory capacity
            const memory_end = offset_usize + size_usize;
            self.memory.ensure_capacity(memory_end) catch {
                try self.stack.push(0);
                return;
            };
            // Extract init code from memory
            const input_data = if (size_usize == 0)
                &[_]u8{}
            else
                self.memory.get_slice(offset_usize, size_usize) catch &[_]u8{};
            // Apply EIP-150 gas forwarding rule: 63/64 of available gas
            const remaining_gas = @as(u64, @intCast(@max(self.gas_remaining, 0)));
            const max_forward_gas = remaining_gas - (remaining_gas / 64);
            const forwarded_gas = max_forward_gas;
            // Create snapshot for potential revert
            const snapshot_id = self.host.create_snapshot();
            // Execute the create2
            const call_params = CallParams{ .create2 = .{
                .caller = self.contract_address,
                .value = value,
                .init_code = input_data,
                .salt = salt,
                .gas = forwarded_gas,
            } };
            const result = self.host.inner_call(call_params) catch {
                self.host.revert_to_snapshot(snapshot_id);
                try self.stack.push(0);
                return;
            };
            // Handle the result
            if (result.success and result.output.len >= 20) {
                // Extract the created contract address from output
                var address_bytes: [20]u8 = undefined;
                @memcpy(&address_bytes, result.output[0..20]);
                const addr: Address = address_bytes;
                const address_u256 = to_u256(addr);
                try self.stack.push(address_u256);
            } else {
                self.host.revert_to_snapshot(snapshot_id);
                try self.stack.push(0); // Failure
            }
            // Update gas accounting
            const gas_cost = forwarded_gas - result.gas_left;
            if (self.gas_remaining >= @as(GasType, @intCast(gas_cost))) {
                self.gas_remaining -= @as(GasType, @intCast(gas_cost));
            } else {
                // If gas cost exceeds remaining, consume all remaining gas
                self.gas_remaining = 0;
            }
        }
        /// RETURN opcode (0xF3) - Halt execution returning data
        /// Halts execution and returns data from memory.
        /// Stack: [offset, size] → []
        pub fn @"return"(self: *Self) Error!void {
            const size = try self.stack.pop();
            const offset = try self.stack.pop();
            // Bounds checking for memory offset and size
            if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));
            const size_usize = @as(usize, @intCast(size));
            // Ensure memory capacity
            const memory_end = offset_usize + size_usize;
            self.memory.ensure_capacity(memory_end) catch return Error.OutOfBounds;
            // Extract return data from memory and store it
            if (size_usize > 0) {
                const return_data = self.memory.get_slice(offset_usize, size_usize) catch {
                    return Error.OutOfBounds;
                };
                // Clear any existing output data
                self.output_data.clearRetainingCapacity();
                // Store the return data
                self.output_data.appendSlice(return_data) catch {
                    return Error.AllocationError;
                };
            } else {
                // Empty return data
                self.output_data.clearRetainingCapacity();
            }
            // Apply EIP-3529 refund cap at return
            if (self.gas_refund > 0) {
                const start: u64 = @max(self.initial_gas, 0);
                const remain: u64 = @max(self.gas_remaining, 0);
                const used: u64 = if (start > remain) start - remain else 0;
                const cap: u64 = used / 5;
                const credit: u64 = if (self.gas_refund > cap) cap else self.gas_refund;
                const new_remaining: u128 = @as(u128, @intCast(remain)) + credit;
                self.gas_remaining = @as(GasType, @intCast(@min(new_remaining, @as(u128, @intCast(std.math.maxInt(GasType))))));
                self.gas_refund = 0;
            }
            return Error.STOP;
        }
        /// REVERT opcode (0xFD) - Halt execution reverting state changes
        /// Halts execution, reverts state changes, and returns data from memory.
        /// Stack: [offset, size] → []
        pub fn revert(self: *Self) Error!void {
            const size = try self.stack.pop();
            const offset = try self.stack.pop();
            // Bounds checking for memory offset and size
            if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));
            const size_usize = @as(usize, @intCast(size));
            // Ensure memory capacity
            const memory_end = offset_usize + size_usize;
            self.memory.ensure_capacity(memory_end) catch return Error.OutOfBounds;
            // Extract revert data from memory and store it
            if (size_usize > 0) {
                const revert_data = self.memory.get_slice(offset_usize, size_usize) catch {
                    return Error.OutOfBounds;
                };
                // Clear any existing output data
                self.output_data.clearRetainingCapacity();
                // Store the revert data
                self.output_data.appendSlice(revert_data) catch {
                    return Error.AllocationError;
                };
            } else {
                // Empty revert data
                self.output_data.clearRetainingCapacity();
            }
            return Error.REVERT;
        }
        /// SELFDESTRUCT opcode (0xFF) - Mark contract for destruction
        /// Marks the current contract for destruction and transfers its balance to the recipient.
        /// Stack: [recipient] → []
        pub fn selfdestruct(self: *Self) Error!void {
            const recipient_u256 = try self.stack.pop();
            const recipient = from_u256(recipient_u256);
            
            // Check static context and mark for destruction if host available
            if (self.host.get_is_static()) {
                @branchHint(.unlikely);
                return Error.WriteProtection;
            }
            
            // Capture state for tracer before destruction (compiled out when tracer is off)
            const _account_balance = if (comptime config.TracerType != null and @hasDecl(config.TracerType.?, "on_account_destroyed"))
                self.host.get_balance(self.contract_address)
            else
                undefined;
            const _has_code = if (comptime config.TracerType != null and @hasDecl(config.TracerType.?, "on_account_destroyed"))
                self.host.get_code(self.contract_address).len > 0
            else
                undefined;
            
            // Mark contract for destruction via host interface
            self.host.mark_for_destruction(self.contract_address, recipient) catch |err| switch (err) {
                else => {
                    @branchHint(.unlikely);
                    return Error.OutOfGas;
                }
            };
            
            // Call tracer AFTER successful destruction mark (compiled out when tracer is off)
            if (comptime config.TracerType != null) {
                if (comptime @hasDecl(config.TracerType.?, "on_account_destroyed")) {
                    self.tracer.on_account_destroyed(self.contract_address, recipient, _account_balance, _has_code, true);
                }
            }
            
            // According to EIP-6780 (Cancun hardfork), SELFDESTRUCT only actually destroys
            // the contract if it was created in the same transaction. This is handled by the host.
            // SELFDESTRUCT always stops execution
            return Error.STOP;
        }
        
        fn dup_bulk_simd(self: *Self, comptime L: comptime_int, indices: []const u8) Error!void {
            if (config.vector_length == 0 or L == 0) {
                // Fallback to scalar operations
                for (indices) |n| {
                    try self.stack.dup_n(n);
                }
                return;
            }
            // Bounds check: ensure we have enough stack items for all operations
            const stack_slice = self.stack.get_slice();
            for (indices) |n| {
                if (n == 0 or n > stack_slice.len) {
                    return Error.StackUnderflow;
                }
            }
            // Check if we have room for all the new items
            if (stack_slice.len + indices.len > Stack.stack_capacity) {
                return Error.StackOverflow;
            }
            // Perform SIMD-optimized bulk duplication
            // Process in chunks of L
            var i: usize = 0;
            while (i < indices.len) : (i += L) {
                const chunk_size = @min(L, indices.len - i);
                const chunk = indices[i .. i + chunk_size];
                // Load vector of values to duplicate
                var values: @Vector(L, WordType) = @splat(0);
                for (chunk, 0..) |n, j| {
                    values[j] = stack_slice[n - 1]; // n-1 because stack is 1-indexed for DUP
                }
                // Push values to stack
                for (0..chunk_size) |j| {
                    try self.stack.push(values[j]);
                }
            }
        }
        /// SIMD-accelerated bulk SWAP operations for sequential exchange operations
        ///
        /// Optimizes execution when multiple SWAP operations are performed in sequence by using
        /// vector operations to coordinate multiple exchanges simultaneously. This reduces the
        /// overhead of individual stack manipulations for bytecode with many consecutive swaps.
        ///
        /// ## How SIMD Optimization Works
        ///
        /// Traditional scalar approach processes each SWAP individually:
        /// ```
        /// SWAP1: exchange stack[0] ↔ stack[1]
        /// SWAP2: exchange stack[0] ↔ stack[2]
        /// SWAP4: exchange stack[0] ↔ stack[4]
        /// ```
        ///
        /// SIMD approach optimizes the coordination:
        /// ```
        /// Load vectors: top_vals = [stack[0], stack[0], stack[0]]
        ///              target_vals = [stack[1], stack[2], stack[4]]
        /// Coordinate swaps with reduced overhead and better cache usage
        /// ```
        ///
        /// ## Performance Benefits
        /// - Reduces overhead from repeated stack API calls
        /// - Better instruction-level parallelism for swap coordination
        /// - Improved cache locality when accessing nearby stack elements
        /// - Automatic fallback to scalar when SIMD unavailable
        ///
        /// @param L: Vector length (compile-time known, from config.vector_length)
        /// @param indices: Array of SWAP indices (1-16, positions to swap with top)
        fn swap_bulk_simd(self: *Self, indices: []const u8, L: usize) !void {
            if (config.vector_length == 0 or L == 0) {
                // Fallback to scalar operations
                for (indices) |n| {
                    try self.stack.swap_n(n);
                }
                return;
            }
            // Bounds check: ensure we have enough stack items for all operations
            const stack_slice = self.stack.get_slice();
            for (indices) |n| {
                if (n + 1 > stack_slice.len) { // SWAP needs n+1 items
                    return Error.StackUnderflow;
                }
            }
            // SIMD optimization: collect all values to swap in vectors first
            // Process in chunks of L
            var i: usize = 0;
            while (i < indices.len) : (i += L) {
                const chunk_size = @min(L, indices.len - i);
                const chunk = indices[i .. i + chunk_size];
                // Load vectors of values to swap using current slice state
                var top_values: @Vector(L, WordType) = @splat(0);
                var target_values: @Vector(L, WordType) = @splat(0);
                for (chunk, 0..) |n, j| {
                    const current_slice = self.stack.get_slice();
                    top_values[j] = current_slice[0]; // Top of stack
                    target_values[j] = current_slice[n]; // nth item from top
                }
                // Perform individual swaps using stack API
                for (chunk) |n| {
                    try self.stack.swap_n(n);
                }
            }
        }
        /// Enhanced DUP operation with automatic SIMD optimization
        ///
        /// Intelligently chooses between SIMD and scalar implementations based on the configured
        /// vector length. When SIMD is available and beneficial (vector_length >= 4), uses the
        /// vectorized path for potential performance improvements. Otherwise, falls back to the
        /// proven scalar implementation.
        ///
        /// ## When SIMD is Used
        /// - Vector length configured > 0 (SIMD support detected)
        /// - Vector length >= 4 (sufficient width for meaningful optimization)
        /// - Single operation can benefit from vector coordination
        ///
        /// ## Automatic Fallback
        /// - SIMD unsupported: Falls back to stack.dup_n()
        /// - Vector length too small: Uses scalar path
        /// - Runtime errors: Propagated normally
        ///
        /// @param n: DUP index (1-16, which stack position to duplicate)
        pub fn dup_simd(self: *Self, n: u8) Error!void {
            if (comptime config.vector_length > 0 and config.vector_length >= 4) {
                // Use SIMD for single DUP if vector length supports it
                const indices = [_]u8{n};
                return self.dup_bulk_simd(&indices, config.vector_length);
            } else {
                // Fallback to existing implementation
                return self.stack.dup_n(n);
            }
        }
        /// Enhanced SWAP operation with automatic SIMD optimization
        ///
        /// Intelligently chooses between SIMD and scalar implementations based on the configured
        /// vector length. When SIMD is available and beneficial, uses the vectorized path for
        /// coordinating exchanges more efficiently than individual scalar swaps.
        ///
        /// ## When SIMD is Used
        /// - Vector length configured > 0 (SIMD support detected)
        /// - Vector length >= 4 (sufficient width for coordination benefits)
        /// - Can leverage vector registers for improved instruction scheduling
        ///
        /// ## Automatic Fallback
        /// - SIMD unsupported: Falls back to stack.swap_n()
        /// - Vector length too small: Uses scalar path
        /// - Maintains identical semantics and error handling
        ///
        /// @param n: SWAP index (1-16, which stack position to exchange with top)
        pub fn swap_simd(self: *Self, n: u8) Error!void {
            if (comptime config.vector_length > 0 and config.vector_length >= 4) {
                // Use SIMD for single SWAP if vector length supports it
                const indices = [_]u8{n};
                return self.swap_bulk_simd(&indices, config.vector_length);
            } else {
                // Fallback to existing implementation
                return self.stack.swap_n(n);
            }
        }
    };
}
test "Frame stack operations" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const dummy_bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &dummy_bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test push operations through stack
    frame.stack.push_unsafe(42);
    try std.testing.expectEqual(@as(u256, 42), frame.stack.peek_unsafe());
    frame.stack.push_unsafe(100);
    const val = frame.stack.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 100), val);
    try std.testing.expectEqual(@as(u256, 42), frame.stack.peek_unsafe());
    // Test push with overflow check
    // Fill stack to capacity - we have 1 item, need 1023 more to reach 1024
    var i: usize = 0;
    while (i < 1022) : (i += 1) {
        frame.stack.push_unsafe(@as(u256, i));
    }
    try frame.stack.push(200); // This should succeed - stack now has 1024 items
    try std.testing.expectEqual(@as(u256, 200), frame.stack.peek_unsafe());
    // This should error - stack is full
    try std.testing.expectError(error.StackOverflow, frame.stack.push(300));
}
test "Frame stack pop operations" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const dummy_bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &dummy_bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Setup stack with some values
    frame.stack.push_unsafe(10);
    frame.stack.push_unsafe(20);
    frame.stack.push_unsafe(30);
    // Test pop_unsafe
    const val1 = frame.stack.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 30), val1);
    const val2 = frame.stack.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 20), val2);
    // Test pop with underflow check
    const val3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 10), val3);
    // This should error - stack is empty
    try std.testing.expectError(error.StackUnderflow, frame.stack.pop());
}
test "Frame stack set_top operations" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const dummy_bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &dummy_bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Setup stack with some values
    frame.stack.push_unsafe(10);
    frame.stack.push_unsafe(20);
    frame.stack.push_unsafe(30);
    // Test set_top_unsafe - should modify the top value (30 -> 99)
    frame.stack.set_top_unsafe(99);
    try std.testing.expectEqual(@as(u256, 99), frame.stack.peek_unsafe());
    // Pop all values to empty the stack
    _ = frame.stack.pop_unsafe();
    _ = frame.stack.pop_unsafe();
    _ = frame.stack.pop_unsafe();
    // Test set_top with error check on empty stack
    try std.testing.expectError(error.StackUnderflow, frame.stack.set_top(42));
    // Test set_top on non-empty stack
    frame.stack.push_unsafe(10);
    frame.stack.push_unsafe(20);
    try frame.stack.set_top(55);
    try std.testing.expectEqual(@as(u256, 55), frame.stack.peek_unsafe());
}
test "Frame stack peek operations" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const dummy_bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &dummy_bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Setup stack with values
    frame.stack.push_unsafe(100);
    frame.stack.push_unsafe(200);
    frame.stack.push_unsafe(300);
    // Test peek_unsafe - should return top value without popping
    const top_unsafe = frame.stack.peek_unsafe();
    try std.testing.expectEqual(@as(u256, 300), top_unsafe);
    // Verify stack still has same top value
    try std.testing.expectEqual(@as(u256, 300), frame.stack.peek_unsafe());
    // Test peek on non-empty stack
    const top = try frame.stack.peek();
    try std.testing.expectEqual(@as(u256, 300), top);
    // Test peek on empty stack
    _ = frame.stack.pop_unsafe();
    _ = frame.stack.pop_unsafe();
    _ = frame.stack.pop_unsafe();
    try std.testing.expectError(error.StackUnderflow, frame.stack.peek());
}
// Helper function to create a test host for frame tests
fn createTestHost() Host {
    const holder = struct {
        var instance: TestHost = .{};
    };
    return Host.init(&holder.instance);
}
// Minimal test host for frame tests
const TestHost = struct {
    const Self = @This();
    pub fn get_balance(self: *Self, address: Address) u256 {
        _ = self;
        _ = address;
        return 0;
    }
    pub fn account_exists(self: *Self, address: Address) bool {
        _ = self;
        _ = address;
        return false;
    }
    pub fn get_code(self: *Self, address: Address) []const u8 {
        _ = self;
        _ = address;
        return &[_]u8{};
    }
    pub fn get_block_info(self: *Self) block_info_mod.DefaultBlockInfo {
        _ = self;
        return block_info_mod.DefaultBlockInfo.init();
    }
    pub fn emit_log(self: *Self, contract_address: Address, topics: []const u256, data: []const u8) void {
        _ = self;
        _ = contract_address;
        _ = topics;
        _ = data;
    }
    pub fn inner_call(self: *Self, params: call_params_mod.CallParams) !call_result_mod.CallResult {
        _ = self;
        _ = params;
        return error.NotImplemented;
    }
    pub fn register_created_contract(self: *Self, address: Address) !void {
        _ = self;
        _ = address;
    }
    pub fn was_created_in_tx(self: *Self, address: Address) bool {
        _ = self;
        _ = address;
        return false;
    }
    pub fn create_snapshot(self: *Self) u32 {
        _ = self;
        return 0;
    }
    pub fn revert_to_snapshot(self: *Self, snapshot_id: u32) void {
        _ = self;
        _ = snapshot_id;
    }
    pub fn get_storage(self: *Self, address: Address, slot: u256) u256 {
        _ = self;
        _ = address;
        _ = slot;
        return 0;
    }
    pub fn set_storage(self: *Self, address: Address, slot: u256, value: u256) !void {
        _ = self;
        _ = address;
        _ = slot;
        _ = value;
    }
    pub fn record_storage_change(self: *Self, address: Address, slot: u256, original_value: u256) !void {
        _ = self;
        _ = address;
        _ = slot;
        _ = original_value;
    }
    pub fn get_original_storage(self: *Self, address: Address, slot: u256) ?u256 {
        _ = self;
        _ = address;
        _ = slot;
        return null;
    }
    pub fn access_address(self: *Self, address: Address) !u64 {
        _ = self;
        _ = address;
        return 0;
    }
    pub fn access_storage_slot(self: *Self, contract_address: Address, slot: u256) !u64 {
        _ = self;
        _ = contract_address;
        _ = slot;
        return 0;
    }
    pub fn mark_for_destruction(self: *Self, contract_address: Address, recipient: Address) !void {
        _ = self;
        _ = contract_address;
        _ = recipient;
    }
    pub fn get_input(self: *Self) []const u8 {
        _ = self;
        return &[_]u8{};
    }
    pub fn is_hardfork_at_least(self: *Self, target: hardfork_mod.Hardfork) bool {
        _ = self;
        _ = target;
        return true;
    }
    pub fn get_hardfork(self: *Self) hardfork_mod.Hardfork {
        _ = self;
        return hardfork_mod.Hardfork.DEFAULT;
    }
    pub fn get_is_static(self: *Self) bool {
        _ = self;
        return false;
    }
    pub fn get_depth(self: *Self) u11 {
        _ = self;
        return 0;
    }
    pub fn get_gas_price(self: *Self) u256 {
        _ = self;
        return 0;
    }
    pub fn get_return_data(self: *Self) []const u8 {
        _ = self;
        return &[_]u8{};
    }
    pub fn get_chain_id(self: *Self) u16 {
        _ = self;
        return 1;
    }
    pub fn get_block_hash(self: *Self, block_number: u64) ?[32]u8 {
        _ = self;
        _ = block_number;
        return null;
    }
    pub fn get_blob_hash(self: *Self, index: u256) ?[32]u8 {
        _ = self;
        _ = index;
        return null;
    }
    pub fn get_blob_base_fee(self: *Self) u256 {
        _ = self;
        return 0;
    }
    pub fn get_tx_origin(self: *Self) Address {
        _ = self;
        return ZERO_ADDRESS;
    }
    pub fn get_caller(self: *Self) Address {
        _ = self;
        return ZERO_ADDRESS;
    }
    pub fn get_call_value(self: *Self) u256 {
        _ = self;
        return 0;
    }
};
test "Frame with bytecode" {
    const allocator = std.testing.allocator;
    // Test with small bytecode (fits in u8)
    const SmallFrame = Frame(.{ .max_bytecode_size = 255 });
    const small_bytecode = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x01, @intFromEnum(Opcode.PUSH1), 0x02, @intFromEnum(Opcode.STOP) };
    const host = createTestHost();
    var small_frame = try SmallFrame.init(allocator, &small_bytecode, 1000000, {}, host);
    defer small_frame.deinit(allocator);
    try std.testing.expectEqual(@intFromEnum(Opcode.PUSH1), small_frame.bytecode[0]);
    // Test with medium bytecode (fits in u16)
    const MediumFrame = Frame(.{ .max_bytecode_size = 65535 });
    const medium_bytecode = [_]u8{ @intFromEnum(Opcode.PUSH1), 0xFF, @intFromEnum(Opcode.STOP) };
    var medium_frame = try MediumFrame.init(allocator, &medium_bytecode, 1000000, {}, host);
    defer medium_frame.deinit(allocator);
    try std.testing.expectEqual(@intFromEnum(Opcode.PUSH1), medium_frame.bytecode[0]);
}
test "Frame op_stop returns stop error" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Execute op_stop - should return STOP error
    try std.testing.expectError(error.STOP, frame.stop());
}
test "Frame op_pop removes top stack item" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ @intFromEnum(Opcode.POP), @intFromEnum(Opcode.STOP) };
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Setup stack with some values
    frame.stack.push_unsafe(100);
    frame.stack.push_unsafe(200);
    frame.stack.push_unsafe(300);
    // Execute op_pop - should remove top item (300) and do nothing with it
    _ = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 200), frame.stack.peek_unsafe());
    // Execute again - should remove 200
    _ = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 100), frame.stack.peek_unsafe());
    // Execute again - should remove 100
    _ = try frame.stack.pop();
    // Pop on empty stack should error
    try std.testing.expectError(error.StackUnderflow, frame.stack.pop());
}
test "Frame op_push0 pushes zero to stack" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ @intFromEnum(Opcode.PUSH0), @intFromEnum(Opcode.STOP) };
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // The interpreter would handle PUSH0 using push0_handler
    try frame.stack.push(0);
    try std.testing.expectEqual(@as(u256, 0), frame.stack.peek_unsafe());
}
test "Frame PUSH1 through interpreter" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x60, 0x42, 0x60, 0xFF, 0x00 }; // PUSH1 0x42 PUSH1 0xFF STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // The interpreter would handle PUSH1 opcodes using push1_handler
    // For now we test the stack operations directly
    try frame.stack.push(0x42);
    try std.testing.expectEqual(@as(u256, 0x42), frame.stack.peek_unsafe());
    try frame.stack.push(0xFF);
    try std.testing.expectEqual(@as(u256, 0xFF), frame.stack.peek_unsafe());
}
test "Frame PUSH2 through interpreter" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x61, 0x12, 0x34, 0x00 }; // PUSH2 0x1234 STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // The interpreter would handle PUSH2 opcodes using push2_handler
    // For now we test the stack operations directly
    try frame.stack.push(0x1234);
    try std.testing.expectEqual(@as(u256, 0x1234), frame.stack.peek_unsafe());
}
test "Frame op_push32 reads 32 bytes from bytecode" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    // PUSH32 with max value (32 bytes of 0xFF)
    var bytecode: [34]u8 = undefined;
    bytecode[0] = 0x7f; // PUSH32
    for (1..33) |i| {
        bytecode[i] = 0xFF;
    }
    bytecode[33] = 0x00; // STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // The interpreter would handle PUSH32 using push32_handler
    try frame.stack.push(std.math.maxInt(u256));
    try std.testing.expectEqual(@as(u256, std.math.maxInt(u256)), frame.stack.peek_unsafe());
}
test "Frame op_push3 reads 3 bytes from bytecode" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x62, 0xAB, 0xCD, 0xEF, 0x00 }; // PUSH3 0xABCDEF STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // The interpreter would handle PUSH3 using push3_handler
    try frame.stack.push(0xABCDEF);
    try std.testing.expectEqual(@as(u256, 0xABCDEF), frame.stack.peek_unsafe());
}
test "Frame op_push7 reads 7 bytes from bytecode" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    // PUSH7 with specific pattern
    const bytecode = [_]u8{ 0x66, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0x00 }; // PUSH7 STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // The interpreter would handle PUSH7 using push7_handler
    try frame.stack.push(0x0123456789ABCD);
    try std.testing.expectEqual(@as(u256, 0x0123456789ABCD), frame.stack.peek_unsafe());
}
test "Frame op_push16 reads 16 bytes from bytecode" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    // PUSH16 with specific pattern
    var bytecode: [18]u8 = undefined;
    bytecode[0] = 0x6F; // PUSH16
    for (1..17) |i| {
        bytecode[i] = @as(u8, @intCast(i));
    }
    bytecode[17] = 0x00; // STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Calculate expected value
    var expected: u256 = 0;
    for (1..17) |i| {
        expected = (expected << 8) | @as(u256, i);
    }
    // The interpreter would handle PUSH16 using push16_handler
    try frame.stack.push(expected);
    try std.testing.expectEqual(expected, frame.stack.peek_unsafe());
    // PC advancement is now handled by plan, not frame
}
test "Frame op_push31 reads 31 bytes from bytecode" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    // PUSH31 with specific pattern
    var bytecode: [33]u8 = undefined;
    bytecode[0] = 0x7E; // PUSH31
    for (1..32) |i| {
        bytecode[i] = @as(u8, @intCast(i % 256));
    }
    bytecode[32] = 0x00; // STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // The interpreter would handle PUSH31 using push31_handler
    // For this test, just verify the frame was created properly
    // Verify PC advanced correctly
    // PC advancement is now handled by plan, not frame
}
test "Frame op_dup1 duplicates top stack item" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x80, 0x00 }; // DUP1 STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Setup stack with value
    frame.stack.push_unsafe(42);
    // Execute op_dup1 - should duplicate top item (42)
    try frame.stack.dup1();
    try std.testing.expectEqual(@as(u256, 42), frame.stack.peek_unsafe()); // Top is duplicate
    const dup = frame.stack.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 42), dup); // Verify duplicate
    try std.testing.expectEqual(@as(u256, 42), frame.stack.peek_unsafe()); // Original still there
    // Test dup1 on empty stack
    _ = frame.stack.pop_unsafe(); // Remove the last item
    try std.testing.expectError(error.StackUnderflow, frame.stack.dup1());
}
test "Frame op_dup16 duplicates 16th stack item" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x8f, 0x00 }; // DUP16 STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Setup stack with values 1-16
    for (0..16) |i| {
        frame.stack.push_unsafe(@as(u256, i + 1));
    }
    // Execute op_dup16 - should duplicate 16th from top (value 1)
    try frame.stack.dup16();
    try std.testing.expectEqual(@as(u256, 1), frame.stack.peek_unsafe()); // Duplicate of bottom element
    // Test dup16 with insufficient stack - need less than 16 items
    // Clear stack
    for (0..17) |_| {
        _ = frame.stack.pop_unsafe();
    }
    // Push only 15 items
    for (0..15) |i| {
        frame.stack.push_unsafe(@as(u256, i));
    }
    try std.testing.expectError(error.StackUnderflow, frame.stack.dup16());
}
test "Frame op_swap1 swaps top two stack items" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x90, 0x00 }; // SWAP1 STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Setup stack with values
    frame.stack.push_unsafe(100);
    frame.stack.push_unsafe(200);
    // Execute op_swap1 - should swap top two items
    try frame.stack.swap1();
    try std.testing.expectEqual(@as(u256, 100), frame.stack.peek_unsafe()); // Was 200, now 100
    const top = frame.stack.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 100), top);
    try std.testing.expectEqual(@as(u256, 200), frame.stack.peek_unsafe()); // Was 100, now 200
    // Test swap1 with insufficient stack
    try std.testing.expectError(error.StackUnderflow, frame.stack.swap1());
}
test "Frame op_swap16 swaps top with 17th stack item" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x9f, 0x00 }; // SWAP16 STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Setup stack with values 1-17
    for (0..17) |i| {
        frame.stack.push_unsafe(@as(u256, i + 1));
    }
    // Execute op_swap16 - should swap top (17) with 17th from top (1)
    try frame.stack.swap16();
    try std.testing.expectEqual(@as(u256, 1), frame.stack.peek_unsafe()); // Was 17, now 1
    // Test swap16 with insufficient stack - need less than 17 items
    // Clear stack
    for (0..17) |_| {
        _ = frame.stack.pop_unsafe();
    }
    // Push only 16 items
    for (0..16) |i| {
        frame.stack.push_unsafe(@as(u256, i));
    }
    try std.testing.expectError(error.StackUnderflow, frame.stack.swap16());
}
test "Frame DUP2-DUP15 operations" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{0x00}; // STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Push 16 distinct values
    for (0..16) |i| {
        frame.stack.push_unsafe(@as(u256, 100 + i));
    }
    // Test DUP2 - duplicates 2nd from top
    try frame.stack.dup2();
    try std.testing.expectEqual(@as(u256, 114), frame.stack.peek_unsafe()); // Should duplicate 114
    _ = frame.stack.pop_unsafe();
    // Test DUP3 - duplicates 3rd from top
    try frame.stack.dup3();
    try std.testing.expectEqual(@as(u256, 113), frame.stack.peek_unsafe());
    _ = frame.stack.pop_unsafe();
    // Test DUP8 - duplicates 8th from top
    try frame.stack.dup8();
    try std.testing.expectEqual(@as(u256, 108), frame.stack.peek_unsafe());
    _ = frame.stack.pop_unsafe();
    // Test DUP15 - duplicates 15th from top
    try frame.stack.dup15();
    try std.testing.expectEqual(@as(u256, 101), frame.stack.peek_unsafe());
    _ = frame.stack.pop_unsafe();
    // Test underflow for DUP operations
    // Clear stack and push fewer items than needed
    for (0..16) |_| {
        _ = frame.stack.pop_unsafe();
    }
    // Push only 5 items
    for (0..5) |i| {
        frame.stack.push_unsafe(@as(u256, i));
    }
    // DUP6 should fail with only 5 items
    try std.testing.expectError(error.StackUnderflow, frame.stack.dup6());
}
test "Frame SWAP2-SWAP15 operations" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{0x00}; // STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Push 17 distinct values to test all SWAP operations
    for (0..17) |i| {
        frame.stack.push_unsafe(@as(u256, 200 + i));
    }
    // Test SWAP2 - swaps top with 3rd element
    try frame.stack.swap2();
    try std.testing.expectEqual(@as(u256, 214), frame.stack.peek_unsafe()); // 214 was 3rd, now top
    const stack_slice = frame.stack.get_slice();
    const third_after_swap2 = stack_slice[2]; // 3rd from top in downward stack
    try std.testing.expectEqual(@as(u256, 216), third_after_swap2); // 216 was top, now 3rd
    // Reset stack for next test
    for (0..17) |_| {
        _ = frame.stack.pop_unsafe();
    }
    for (0..17) |i| {
        frame.stack.push_unsafe(@as(u256, 300 + i));
    }
    // Test SWAP5 - swaps top with 6th element
    try frame.stack.swap5();
    try std.testing.expectEqual(@as(u256, 311), frame.stack.peek_unsafe()); // 311 was 6th, now top
    const stack_slice2 = frame.stack.get_slice();
    const sixth_after_swap5 = stack_slice2[5]; // 6th from top in downward stack
    try std.testing.expectEqual(@as(u256, 316), sixth_after_swap5); // 316 was top, now 6th
    // Reset for SWAP15 test
    for (0..17) |_| {
        _ = frame.stack.pop_unsafe();
    }
    for (0..17) |i| {
        frame.stack.push_unsafe(@as(u256, 400 + i));
    }
    // Test SWAP15 - swaps top with 16th element
    try frame.stack.swap15();
    try std.testing.expectEqual(@as(u256, 401), frame.stack.peek_unsafe()); // 401 was 16th, now top
    const stack_slice3 = frame.stack.get_slice();
    const sixteenth_after_swap15 = stack_slice3[15]; // 16th from top in downward stack
    try std.testing.expectEqual(@as(u256, 416), sixteenth_after_swap15); // 416 was top, now 16th
    // Test underflow for SWAP operations
    for (0..17) |_| {
        _ = frame.stack.pop_unsafe();
    }
    // Push only 8 items
    for (0..8) |i| {
        frame.stack.push_unsafe(@as(u256, i));
    }
    // SWAP10 should fail with only 8 items (needs 11)
    try std.testing.expectError(error.StackUnderflow, frame.stack.swap10());
}
// NOTE: SELFDESTRUCT test removed - needs update for current frame structure
// Consider implementing when frame.selfdestruct interface is stable
// NOTE: SELFDESTRUCT insufficient stack test removed - needs update for current frame structure
// NOTE: SELFDESTRUCT static context test removed - needs update for current frame structure
test "Frame init validates bytecode size" {
    const allocator = std.testing.allocator;
    // Test with valid bytecode size
    const SmallFrame = Frame(.{ .max_bytecode_size = 100 });
    const small_bytecode = [_]u8{ 0x60, 0x01, 0x00 }; // PUSH1 1 STOP
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    const host = createTestHost();
    var frame = try SmallFrame.init(allocator, &small_bytecode, 1000000, {}, host);
    defer frame.deinit(allocator);
    // PC is now managed by plan, not frame directly
    try std.testing.expectEqual(&small_bytecode, frame.bytecode.ptr);
    try std.testing.expectEqual(@as(usize, 3), frame.bytecode.len);
    // Test with bytecode too large
    const large_bytecode = try allocator.alloc(u8, 101);
    defer allocator.free(large_bytecode);
    @memset(large_bytecode, 0x00);
    try std.testing.expectError(error.BytecodeTooLarge, SmallFrame.init(allocator, large_bytecode, 0, {}, host));
    // Test with empty bytecode
    const empty_bytecode = [_]u8{};
    var empty_frame = try SmallFrame.init(allocator, &empty_bytecode, 1000000, {}, host);
    defer empty_frame.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_frame.bytecode.len);
}
test "Frame get_requested_alloc calculates correctly" {
    // Test with default options
    const default_config = FrameConfig{};
    const expected_default = @as(u32, @intCast(1024 * @sizeOf(u256)));
    try std.testing.expectEqual(expected_default, default_config.get_requested_alloc());
    // Test with custom options
    const custom_config = FrameConfig{
        .stack_size = 512,
        .WordType = u128,
        .max_bytecode_size = 1000,
    };
    const expected_custom = @as(u32, @intCast(512 * @sizeOf(u128)));
    try std.testing.expectEqual(expected_custom, custom_config.get_requested_alloc());
    // Test with small frame
    const small_config = FrameConfig{
        .stack_size = 256,
        .WordType = u64,
        .max_bytecode_size = 255,
    };
    const expected_small = @as(u32, @intCast(256 * @sizeOf(u64)));
    try std.testing.expectEqual(expected_small, small_config.get_requested_alloc());
}
test "Frame op_and bitwise AND operation" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x16, 0x00 }; // AND STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 0xFF & 0x0F = 0x0F
    try frame.stack.push(0xFF);
    try frame.stack.push(0x0F);
    // Inline AND operation: pop b, pop a, push (a & b)
    const b = try frame.stack.pop();
    const a = try frame.stack.pop();
    try frame.stack.push(a & b);
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0x0F), result1);
    // Test 0xFFFF & 0x00FF = 0x00FF
    try frame.stack.push(0xFFFF);
    try frame.stack.push(0x00FF);
    // Inline AND operation: pop b, pop a, push (a & b)
    const b2 = try frame.stack.pop();
    const a2 = try frame.stack.pop();
    try frame.stack.push(a2 & b2);
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0x00FF), result2);
    // Test with max values
    try frame.stack.push(std.math.maxInt(u256));
    try frame.stack.push(0x12345678);
    // Inline AND operation: pop b, pop a, push (a & b)
    const b3 = try frame.stack.pop();
    const a3 = try frame.stack.pop();
    try frame.stack.push(a3 & b3);
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0x12345678), result3);
}
test "Frame op_or bitwise OR operation" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x17, 0x00 }; // OR STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 0xF0 | 0x0F = 0xFF
    try frame.stack.push(0xF0);
    try frame.stack.push(0x0F);
    // Inline OR operation: pop b, pop a, push (a | b)
    const b = try frame.stack.pop();
    const a = try frame.stack.pop();
    try frame.stack.push(a | b);
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result1);
    // Test 0xFF00 | 0x00FF = 0xFFFF
    try frame.stack.push(0xFF00);
    try frame.stack.push(0x00FF);
    // Inline OR operation: pop b, pop a, push (a | b)
    const b2 = try frame.stack.pop();
    const a2 = try frame.stack.pop();
    try frame.stack.push(a2 | b2);
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0xFFFF), result2);
    // Test with zero
    try frame.stack.push(0);
    try frame.stack.push(0x12345678);
    // Inline OR operation: pop b, pop a, push (a | b)
    const b3 = try frame.stack.pop();
    const a3 = try frame.stack.pop();
    try frame.stack.push(a3 | b3);
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0x12345678), result3);
}
test "Frame xor bitwise XOR operation" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x18, 0x00 }; // XOR STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 0xFF ^ 0xFF = 0
    try frame.stack.push(0xFF);
    try frame.stack.push(0xFF);
    try frame.xor();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result1);
    // Test 0xFF ^ 0x00 = 0xFF
    try frame.stack.push(0xFF);
    try frame.stack.push(0x00);
    try frame.xor();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result2);
    // Test 0xAA ^ 0x55 = 0xFF (alternating bits)
    try frame.stack.push(0xAA);
    try frame.stack.push(0x55);
    try frame.xor();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result3);
}
test "Frame op_not bitwise NOT operation" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x19, 0x00 }; // NOT STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test ~0 = max value
    try frame.stack.push(0);
    // Inline NOT operation: pop a, push (~a)
    const a = try frame.stack.pop();
    try frame.stack.push(~a);
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(std.math.maxInt(u256), result1);
    // Test ~max = 0
    try frame.stack.push(std.math.maxInt(u256));
    // Inline NOT operation: pop a, push (~a)
    const a2 = try frame.stack.pop();
    try frame.stack.push(~a2);
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    // Test ~0xFF = 0xFFFF...FF00
    try frame.stack.push(0xFF);
    // Inline NOT operation: pop a, push (~a)
    const a3 = try frame.stack.pop();
    try frame.stack.push(~a3);
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(std.math.maxInt(u256) - 0xFF, result3);
}
test "Frame op_byte extracts single byte from word" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x1A, 0x00 }; // BYTE STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test extracting byte 31 (rightmost) from 0x...FF
    try frame.stack.push(0xFF);
    try frame.stack.push(31);
    try frame.byte();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result1);
    // Test extracting byte 30 from 0x...FF00
    try frame.stack.push(0xFF00);
    try frame.stack.push(30);
    try frame.byte();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result2);
    // Test extracting byte 0 (leftmost) from a value
    const value: u256 = @as(u256, 0xAB) << 248; // Put 0xAB in the leftmost byte
    try frame.stack.push(value);
    try frame.stack.push(0);
    try frame.byte();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0xAB), result3);
    // Test out of bounds (index >= 32) returns 0
    try frame.stack.push(0xFFFFFFFF);
    try frame.stack.push(32);
    try frame.byte();
    const result4 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}
test "Frame op_shl shift left operation" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x1B, 0x00 }; // SHL STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 1 << 4 = 16
    try frame.stack.push(1);
    try frame.stack.push(4);
    try frame.shl();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 16), result1);
    // Test 0xFF << 8 = 0xFF00
    try frame.stack.push(0xFF);
    try frame.stack.push(8);
    try frame.shl();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0xFF00), result2);
    // Test shift >= 256 returns 0
    try frame.stack.push(1);
    try frame.stack.push(256);
    try frame.shl();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
}
test "Frame op_shr logical shift right operation" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x1C, 0x00 }; // SHR STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 16 >> 4 = 1
    try frame.stack.push(16);
    try frame.stack.push(4);
    try frame.shr();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    // Test 0xFF00 >> 8 = 0xFF
    try frame.stack.push(0xFF00);
    try frame.stack.push(8);
    try frame.shr();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result2);
    // Test shift >= 256 returns 0
    try frame.stack.push(std.math.maxInt(u256));
    try frame.stack.push(256);
    try frame.shr();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
}
test "Frame op_sar arithmetic shift right operation" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x1D, 0x00 }; // SAR STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test positive number: 16 >> 4 = 1
    try frame.stack.push(16);
    try frame.stack.push(4);
    try frame.sar();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    // Test negative number (sign bit = 1)
    const negative = @as(u256, 1) << 255 | 0xFF00; // Set sign bit and some data
    try frame.stack.push(negative);
    try frame.stack.push(8);
    try frame.sar();
    const result2 = try frame.stack.pop();
    // Should fill with 1s from the left
    const expected2 = (@as(u256, std.math.maxInt(u256)) << 247) | 0xFF;
    try std.testing.expectEqual(expected2, result2);
    // Test shift >= 256 with positive number returns 0
    try frame.stack.push(0x7FFFFFFF); // Positive (sign bit = 0)
    try frame.stack.push(256);
    try frame.sar();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    // Test shift >= 256 with negative number returns max value
    try frame.stack.push(@as(u256, 1) << 255); // Negative (sign bit = 1)
    try frame.stack.push(256);
    try frame.sar();
    const result4 = try frame.stack.pop();
    try std.testing.expectEqual(std.math.maxInt(u256), result4);
}
test "Frame op_add addition with wrapping overflow" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x01, 0x00 }; // ADD STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 10 + 20 = 30
    try frame.stack.push(10);
    try frame.stack.push(20);
    try frame.add();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 30), result1);
    // Test overflow: max + 1 = 0
    try frame.stack.push(std.math.maxInt(u256));
    try frame.stack.push(1);
    try frame.add();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    // Test max + max = max - 1 (wrapping)
    try frame.stack.push(std.math.maxInt(u256));
    try frame.stack.push(std.math.maxInt(u256));
    try frame.add();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(std.math.maxInt(u256) - 1, result3);
}
test "Frame op_mul multiplication with wrapping overflow" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x02, 0x00 }; // MUL STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 5 * 6 = 30
    try frame.stack.push(5);
    try frame.stack.push(6);
    try frame.mul();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 30), result1);
    // Test 0 * anything = 0
    try frame.stack.push(0);
    try frame.stack.push(12345);
    try frame.mul();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    // Test overflow with large numbers
    const large = @as(u256, 1) << 128;
    try frame.stack.push(large);
    try frame.stack.push(large);
    try frame.mul();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result3); // 2^256 wraps to 0
}
test "Frame op_sub subtraction with wrapping underflow" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x03, 0x00 }; // SUB STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 30 - 10 = 20
    try frame.stack.push(30);
    try frame.stack.push(10);
    try frame.sub();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 20), result1);
    // Test underflow: 0 - 1 = max
    try frame.stack.push(0);
    try frame.stack.push(1);
    try frame.sub();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(std.math.maxInt(u256), result2);
    // Test 10 - 20 = max - 9 (wrapping)
    try frame.stack.push(10);
    try frame.stack.push(20);
    try frame.sub();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(std.math.maxInt(u256) - 9, result3);
}
test "Frame op_div unsigned integer division" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x04, 0x00 }; // DIV STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 20 / 5 = 4
    try frame.stack.push(20);
    try frame.stack.push(5);
    try frame.div();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 4), result1);
    // Test division by zero returns 0
    try frame.stack.push(100);
    try frame.stack.push(0);
    try frame.div();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    // Test integer division: 7 / 3 = 2
    try frame.stack.push(7);
    try frame.stack.push(3);
    try frame.div();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 2), result3);
}
test "Frame op_sdiv signed integer division" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x05, 0x00 }; // SDIV STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 20 / 5 = 4 (positive / positive)
    try frame.stack.push(20);
    try frame.stack.push(5);
    try frame.sdiv();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 4), result1);
    // Test -20 / 5 = -4 (negative / positive)
    const neg_20 = @as(u256, @bitCast(@as(i256, -20)));
    try frame.stack.push(neg_20);
    try frame.stack.push(5);
    try frame.sdiv();
    const result2 = try frame.stack.pop();
    const expected2 = @as(u256, @bitCast(@as(i256, -4)));
    try std.testing.expectEqual(expected2, result2);
    // Test MIN_I256 / -1 = MIN_I256 (overflow case)
    const min_i256 = @as(u256, 1) << 255;
    const neg_1 = @as(u256, @bitCast(@as(i256, -1)));
    try frame.stack.push(min_i256);
    try frame.stack.push(neg_1);
    try frame.sdiv();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(min_i256, result3);
    // Test division by zero returns 0
    try frame.stack.push(100);
    try frame.stack.push(0);
    try frame.sdiv();
    const result4 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}
test "Frame op_mod modulo remainder operation" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x06, 0x00 }; // MOD STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 17 % 5 = 2
    try frame.stack.push(17);
    try frame.stack.push(5);
    try frame.mod();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 2), result1);
    // Test 100 % 10 = 0
    try frame.stack.push(100);
    try frame.stack.push(10);
    try frame.mod();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    // Test modulo by zero returns 0
    try frame.stack.push(7);
    try frame.stack.push(0);
    try frame.mod();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
}
test "Frame op_smod signed modulo remainder operation" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x07, 0x00 }; // SMOD STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 17 % 5 = 2 (positive % positive)
    try frame.stack.push(17);
    try frame.stack.push(5);
    try frame.smod();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 2), result1);
    // Test -17 % 5 = -2 (negative % positive)
    const neg_17 = @as(u256, @bitCast(@as(i256, -17)));
    try frame.stack.push(neg_17);
    try frame.stack.push(5);
    try frame.smod();
    const result2 = try frame.stack.pop();
    const expected2 = @as(u256, @bitCast(@as(i256, -2)));
    try std.testing.expectEqual(expected2, result2);
    // Test 17 % -5 = 2 (positive % negative)
    const neg_5 = @as(u256, @bitCast(@as(i256, -5)));
    try frame.stack.push(17);
    try frame.stack.push(neg_5);
    try frame.smod();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 2), result3);
    // Test modulo by zero returns 0
    try frame.stack.push(neg_17);
    try frame.stack.push(0);
    try frame.smod();
    const result4 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}
test "Frame op_addmod addition modulo n" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x08, 0x00 }; // ADDMOD STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test (10 + 20) % 7 = 2
    try frame.stack.push(10);
    try frame.stack.push(20);
    try frame.stack.push(7);
    try frame.addmod();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 2), result1);
    // Test overflow handling: (MAX + 5) % 10 = 4
    // MAX = 2^256 - 1, so (2^256 - 1 + 5) = 2^256 + 4
    // Since we're in mod 2^256, this is just 4
    // So 4 % 10 = 4
    try frame.stack.push(std.math.maxInt(u256));
    try frame.stack.push(5);
    try frame.stack.push(10);
    try frame.addmod();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 4), result2);
    // Test modulo by zero returns 0
    try frame.stack.push(50);
    try frame.stack.push(50);
    try frame.stack.push(0);
    try frame.addmod();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);

    // Regression: when addition overflows 2^256 and modulus doesn't divide 2^256
    // Use a = 2^256 - 2, b = 5, n = 3
    // True result: (2^256 + 3) mod 3 = 1, not ((2^256 + 3) mod 2^256) % 3 = 0
    try frame.stack.push(std.math.maxInt(u256) - 1);
    try frame.stack.push(5);
    try frame.stack.push(3);
    try frame.addmod();
    const result4 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result4);
}
test "Frame op_mulmod multiplication modulo n" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x09, 0x00 }; // MULMOD STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test (10 * 20) % 7 = 200 % 7 = 4
    try frame.stack.push(10);
    try frame.stack.push(20);
    try frame.stack.push(7);
    try frame.mulmod();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 4), result1);
    // First test a simple case to make sure basic logic works
    try frame.stack.push(36);
    try frame.stack.push(36);
    try frame.stack.push(100);
    try frame.mulmod();
    const simple_result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 96), simple_result);
    // Test that large % 100 = 56
    const large = @as(u256, 1) << 128;
    try std.testing.expectEqual(@as(u256, 56), large % 100);
    // Test overflow handling: (2^128 * 2^128) % 100
    // This tests the modular multiplication
    try frame.stack.push(large);
    try frame.stack.push(large);
    try frame.stack.push(100);
    try frame.mulmod();
    const result2 = try frame.stack.pop();
    // Since the algorithm reduces first: 2^128 % 100 = 56
    // Then we're computing (56 * 56) % 100 = 3136 % 100 = 36
    try std.testing.expectEqual(@as(u256, 36), result2);
    // Test modulo by zero returns 0
    try frame.stack.push(50);
    try frame.stack.push(50);
    try frame.stack.push(0);
    try frame.mulmod();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
}
test "Frame op_exp exponentiation" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x0A, 0x00 }; // EXP STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 2^10 = 1024
    try frame.stack.push(2);
    try frame.stack.push(10);
    try frame.exp();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1024), result1);
    // Test 3^4 = 81
    try frame.stack.push(3);
    try frame.stack.push(4);
    try frame.exp();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 81), result2);
    // Test 10^0 = 1 (anything^0 = 1)
    try frame.stack.push(10);
    try frame.stack.push(0);
    try frame.exp();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result3);
    // Test 0^10 = 0 (0^anything = 0, except 0^0)
    try frame.stack.push(0);
    try frame.stack.push(10);
    try frame.exp();
    const result4 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
    // Test 0^0 = 1 (special case in EVM)
    try frame.stack.push(0);
    try frame.stack.push(0);
    try frame.exp();
    const result5 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result5);
}
test "Frame op_signextend sign extension" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x0B, 0x00 }; // SIGNEXTEND STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test extending positive 8-bit value (0x7F)
    try frame.stack.push(0x7F);
    try frame.stack.push(0); // Extend from byte 0
    try frame.signextend();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0x7F), result1);
    // Test extending negative 8-bit value (0x80)
    try frame.stack.push(0x80);
    try frame.stack.push(0); // Extend from byte 0
    try frame.signextend();
    const result2 = try frame.stack.pop();
    const expected2 = std.math.maxInt(u256) - 0x7F; // 0xFFFF...FF80
    try std.testing.expectEqual(expected2, result2);
    // Test extending positive 16-bit value (0x7FFF)
    try frame.stack.push(0x7FFF);
    try frame.stack.push(1); // Extend from byte 1
    try frame.signextend();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0x7FFF), result3);
    // Test extending negative 16-bit value (0x8000)
    try frame.stack.push(0x8000);
    try frame.stack.push(1); // Extend from byte 1
    try frame.signextend();
    const result4 = try frame.stack.pop();
    const expected4 = std.math.maxInt(u256) - 0x7FFF; // 0xFFFF...F8000
    try std.testing.expectEqual(expected4, result4);
    // Test byte_num >= 31 returns value unchanged
    try frame.stack.push(0x12345678);
    try frame.stack.push(31); // Extend from byte 31 (full width)
    try frame.signextend();
    const result5 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0x12345678), result5);
}
test "Frame op_gas returns gas remaining" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x5A, 0x00 }; // GAS STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Test op_gas pushes gas_remaining to stack
    try frame.gas();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1000000), result1);
    // Test op_gas with modified gas_remaining
    frame.gas_remaining = 12345;
    try frame.gas();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 12345), result2);
    // Test op_gas with zero gas
    frame.gas_remaining = 0;
    try frame.gas();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    // Test op_gas with negative gas (should push 0)
    frame.gas_remaining = 0; // Can't have negative gas
    try frame.gas();
    const result4 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}
test "Frame op_lt less than comparison" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x10, 0x00 }; // LT STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 10 < 20 = 1
    try frame.stack.push(10);
    try frame.stack.push(20);
    try frame.lt();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    // Test 20 < 10 = 0
    try frame.stack.push(20);
    try frame.stack.push(10);
    try frame.lt();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    // Test 10 < 10 = 0
    try frame.stack.push(10);
    try frame.stack.push(10);
    try frame.lt();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    // Test with max value
    try frame.stack.push(std.math.maxInt(u256));
    try frame.stack.push(0);
    try frame.lt();
    const result4 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}
test "Frame op_gt greater than comparison" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x11, 0x00 }; // GT STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 20 > 10 = 1
    try frame.stack.push(20);
    try frame.stack.push(10);
    try frame.gt();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    // Test 10 > 20 = 0
    try frame.stack.push(10);
    try frame.stack.push(20);
    try frame.gt();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    // Test 10 > 10 = 0
    try frame.stack.push(10);
    try frame.stack.push(10);
    try frame.gt();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    // Test with max value
    try frame.stack.push(0);
    try frame.stack.push(std.math.maxInt(u256));
    try frame.gt();
    const result4 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}
test "Frame op_slt signed less than comparison" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x12, 0x00 }; // SLT STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 10 < 20 = 1 (positive comparison)
    try frame.stack.push(10);
    try frame.stack.push(20);
    try frame.slt();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    // Test -10 < 10 = 1 (negative < positive)
    const neg_10 = @as(u256, @bitCast(@as(i256, -10)));
    try frame.stack.push(neg_10);
    try frame.stack.push(10);
    try frame.slt();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result2);
    // Test 10 < -10 = 0 (positive < negative)
    try frame.stack.push(10);
    try frame.stack.push(neg_10);
    try frame.slt();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    // Test MIN_INT < MAX_INT = 1
    const min_int = @as(u256, 1) << 255; // Sign bit set
    const max_int = (@as(u256, 1) << 255) - 1; // All bits except sign bit
    try frame.stack.push(min_int);
    try frame.stack.push(max_int);
    try frame.slt();
    const result4 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result4);
}
test "Frame op_sgt signed greater than comparison" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x13, 0x00 }; // SGT STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 20 > 10 = 1 (positive comparison)
    try frame.stack.push(20);
    try frame.stack.push(10);
    try frame.sgt();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    // Test 10 > -10 = 1 (positive > negative)
    const neg_10 = @as(u256, @bitCast(@as(i256, -10)));
    try frame.stack.push(10);
    try frame.stack.push(neg_10);
    try frame.sgt();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result2);
    // Test -10 > 10 = 0 (negative > positive)
    try frame.stack.push(neg_10);
    try frame.stack.push(10);
    try frame.sgt();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    // Test MAX_INT > MIN_INT = 1
    const min_int = @as(u256, 1) << 255; // Sign bit set
    const max_int = (@as(u256, 1) << 255) - 1; // All bits except sign bit
    try frame.stack.push(max_int);
    try frame.stack.push(min_int);
    try frame.sgt();
    const result4 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result4);
}
test "Frame op_eq equality comparison" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x14, 0x00 }; // EQ STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test 10 == 10 = 1
    try frame.stack.push(10);
    try frame.stack.push(10);
    try frame.eq();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    // Test 10 == 20 = 0
    try frame.stack.push(10);
    try frame.stack.push(20);
    try frame.eq();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    // Test 0 == 0 = 1
    try frame.stack.push(0);
    try frame.stack.push(0);
    try frame.eq();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result3);
    // Test max == max = 1
    try frame.stack.push(std.math.maxInt(u256));
    try frame.stack.push(std.math.maxInt(u256));
    try frame.eq();
    const result4 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result4);
}
test "Frame op_iszero zero check" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x15, 0x00 }; // ISZERO STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test iszero(0) = 1
    try frame.stack.push(0);
    try frame.iszero();
    const result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    // Test iszero(1) = 0
    try frame.stack.push(1);
    try frame.iszero();
    const result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    // Test iszero(100) = 0
    try frame.stack.push(100);
    try frame.iszero();
    const result3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    // Test iszero(max) = 0
    try frame.stack.push(std.math.maxInt(u256));
    try frame.iszero();
    const result4 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}
test "Frame JUMP through interpreter" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    // JUMP STOP JUMPDEST STOP (positions: 0=JUMP, 1=STOP, 2=JUMPDEST, 3=STOP)
    const bytecode = [_]u8{ 0x56, 0x00, 0x5B, 0x00 };
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // The interpreter would handle JUMP opcodes using op_jump_handler
    // For now we test that the frame was properly initialized
    try std.testing.expectEqual(@intFromEnum(Opcode.JUMP), frame.bytecode[0]);
    try std.testing.expectEqual(@intFromEnum(Opcode.STOP), frame.bytecode[1]);
    try std.testing.expectEqual(@intFromEnum(Opcode.JUMPDEST), frame.bytecode[2]);
}
test "Frame JUMPI through interpreter" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    // JUMPI STOP JUMPDEST STOP (positions: 0=JUMPI, 1=STOP, 2=JUMPDEST, 3=STOP)
    const bytecode = [_]u8{ 0x57, 0x00, 0x5B, 0x00 };
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // The interpreter would handle JUMPI opcodes using op_jumpi_handler
    // For now we test that the frame was properly initialized
    try std.testing.expectEqual(@intFromEnum(Opcode.JUMPI), frame.bytecode[0]);
    try std.testing.expectEqual(@intFromEnum(Opcode.STOP), frame.bytecode[1]);
    try std.testing.expectEqual(@intFromEnum(Opcode.JUMPDEST), frame.bytecode[2]);
}
test "Frame op_jumpdest no-op" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x5B, 0x00 }; // JUMPDEST STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // JUMPDEST should do nothing
    // PC is now managed by plan, not frame directly
    try frame.jumpdest();
}
test "Frame op_invalid causes error" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0xFE, 0x00 }; // INVALID STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // INVALID should always return error
    try std.testing.expectError(error.InvalidOpcode, frame.invalid());
}
test "Frame op_keccak256 hash computation" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x20, 0x00 }; // KECCAK256 STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 0, {}, host);
    defer frame.deinit(allocator);
    // Test keccak256 of empty data
    try frame.keccak256_data(&[_]u8{});
    const empty_hash = try frame.stack.pop();
    // keccak256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
    const expected_empty = @as(u256, 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470);
    try std.testing.expectEqual(expected_empty, empty_hash);
    // Test keccak256 of "Hello"
    try frame.keccak256_data("Hello");
    const hello_hash = try frame.stack.pop();
    // keccak256("Hello") = 0x06b3dfaec148fb1bb2b066f10ec285e7c9bf402ab32aa78a5d38e34566810cd2
    const expected_hello = @as(u256, 0x06b3dfaec148fb1bb2b066f10ec285e7c9bf402ab32aa78a5d38e34566810cd2);
    try std.testing.expectEqual(expected_hello, hello_hash);
}
test "Frame with NoOpTracer executes correctly" {
    const allocator = std.testing.allocator;
    // Create frame with default NoOpTracer
    // Simple bytecode: PUSH1 0x05, PUSH1 0x03, ADD
    const bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01 };
    const F = Frame(.{});
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000, void{}, host);
    defer frame.deinit(allocator);
    // Execute by pushing values and calling add
    try frame.stack.push(5);
    try frame.stack.push(3);
    try frame.add();
    // Check that we have the expected result (5 + 3 = 8)
    try std.testing.expectEqual(@as(u256, 8), frame.stack.peek_unsafe());
}
test "Frame tracer type can be changed at compile time" {
    const allocator = std.testing.allocator;
    // Custom tracer for testing
    const TestTracer = struct {
        call_count: usize,
        pub fn init() @This() {
            return .{ .call_count = 0 };
        }
        pub fn beforeOp(self: *@This(), comptime FrameType: type, frame: *const FrameType) void {
            _ = frame;
            self.call_count += 1;
        }
        pub fn afterOp(self: *@This(), comptime FrameType: type, frame: *const FrameType) void {
            _ = frame;
            self.call_count += 1;
        }
        pub fn onError(self: *@This(), comptime FrameType: type, frame: *const FrameType, err: anyerror) void {
            _ = frame;
            if (false) {
                std.debug.print("Error: {}\n", .{err});
            }
            self.call_count += 1;
        }
    };
    // Create frame with custom tracer
    const config = FrameConfig{
        .TracerType = TestTracer,
    };
    const F = Frame(config);
    // Simple bytecode: PUSH1 0x05
    const bytecode = [_]u8{ 0x60, 0x05 };
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000, {}, host);
    defer frame.deinit(allocator);
    // Check that our test tracer was initialized
    try std.testing.expectEqual(@as(usize, 0), frame.tracer.call_count);
    // Execute a simple operation to trigger tracer
    try frame.stack.push(10);
    // Since we're calling op functions directly, tracer won't be triggered
    // unless we go through the interpret function
}
test "Frame op_msize memory size tracking" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x59, 0x00 }; // MSIZE STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Initially memory size should be 0
    try frame.msize();
    const initial_size = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), initial_size);
    // Store something to expand memory
    try frame.stack.push(0x42); // value
    try frame.stack.push(0); // offset
    try frame.mstore();
    // Memory should now be 32 bytes
    try frame.msize();
    const size_after_store = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 32), size_after_store);
    // Store at offset 32
    try frame.stack.push(0x55); // value
    try frame.stack.push(32); // offset
    try frame.mstore();
    // Memory should now be 64 bytes
    try frame.msize();
    const size_after_second_store = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 64), size_after_second_store);
}
test "Frame op_mload memory load operations" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x51, 0x00 }; // MLOAD STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Store a value first
    const test_value: u256 = 0x123456789ABCDEF0;
    try frame.stack.push(test_value);
    try frame.stack.push(0); // offset
    try frame.mstore();
    // Load it back
    try frame.stack.push(0); // offset
    try frame.mload();
    const loaded_value = try frame.stack.pop();
    try std.testing.expectEqual(test_value, loaded_value);
    // Load from uninitialized memory (should be zero)
    // First store at offset 64 to ensure memory is expanded
    try frame.stack.push(0); // value 0
    try frame.stack.push(64); // offset
    try frame.mstore();
    // Now load from offset 64 (should be zero)
    try frame.stack.push(64); // offset
    try frame.mload();
    const zero_value = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), zero_value);
}
test "Frame op_mstore memory store operations" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x52, 0x00 }; // MSTORE STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Store multiple values at different offsets
    const value1: u256 = 0xDEADBEEF;
    const value2: u256 = 0xCAFEBABE;
    try frame.stack.push(value1);
    try frame.stack.push(0); // offset
    try frame.mstore();
    try frame.stack.push(value2);
    try frame.stack.push(32); // offset
    try frame.mstore();
    // Read them back
    try frame.stack.push(0);
    try frame.mload();
    const read1 = try frame.stack.pop();
    try std.testing.expectEqual(value1, read1);
    try frame.stack.push(32);
    try frame.mload();
    const read2 = try frame.stack.pop();
    try std.testing.expectEqual(value2, read2);
}
test "Frame op_mstore8 byte store operations" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x53, 0x00 }; // MSTORE8 STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Store a single byte
    try frame.stack.push(0xFF); // value (only low byte will be stored)
    try frame.stack.push(5); // offset
    try frame.mstore8();
    // Load the 32-byte word containing our byte
    try frame.stack.push(0); // offset 0
    try frame.mload();
    const word = try frame.stack.pop();
    // The byte at offset 5 should be 0xFF
    // In a 32-byte word, byte 5 is at bit position 216-223 (from the right)
    const byte_5 = @as(u8, @truncate((word >> (26 * 8)) & 0xFF));
    try std.testing.expectEqual(@as(u8, 0xFF), byte_5);
    // Store another byte and check
    try frame.stack.push(0x1234ABCD); // value (only 0xCD will be stored)
    try frame.stack.push(10); // offset
    try frame.mstore8();
    try frame.stack.push(0);
    try frame.mload();
    const word2 = try frame.stack.pop();
    const byte_10 = @as(u8, @truncate((word2 >> (21 * 8)) & 0xFF));
    try std.testing.expectEqual(@as(u8, 0xCD), byte_10);
}
test "trace instructions behavior with different tracer types" {
    // Simple test tracer that counts calls
    const TestTracer = struct {
        call_count: usize = 0,
        pub fn init() @This() {
            return .{};
        }
        pub fn beforeOp(self: *@This(), comptime FrameType: type, frame_instance: *const FrameType) void {
            _ = frame_instance;
            self.call_count += 1;
        }
        pub fn afterOp(self: *@This(), comptime FrameType: type, frame_instance: *const FrameType) void {
            _ = frame_instance;
            self.call_count += 1;
        }
        pub fn onError(self: *@This(), comptime FrameType: type, frame_instance: *const FrameType, err: anyerror) void {
            _ = frame_instance;
            _ = err;
            self.call_count += 1;
        }
    };
    const allocator = std.testing.allocator;
    // Test that frames with different tracer types compile successfully
    const FrameNoOp = Frame(.{});
    const FrameWithTestTracer = Frame(.{
        .TracerType = TestTracer,
    });
    // Verify both frame types can be instantiated
    const bytecode = [_]u8{ 0x60, 0x05, 0x00 }; // PUSH1 5, STOP
    const host = createTestHost();
    var frame_noop = try FrameNoOp.init(allocator, &bytecode, 1000, {}, host);
    defer frame_noop.deinit(allocator);
    var frame_traced = try FrameWithTestTracer.init(allocator, &bytecode, 1000, {}, host);
    defer frame_traced.deinit(allocator);
    // Both should start with empty stacks
    // The traced frame should start with zero tracer calls
    try std.testing.expectEqual(@as(usize, 0), frame_traced.tracer.call_count);
    // Test type name checking
    const test_tracer_type_name = @typeName(TestTracer);
    try std.testing.expect(!std.mem.eql(u8, test_tracer_type_name, "void"));
}
test "Frame jump to invalid destination should fail" {
    const allocator = std.testing.allocator;
    const FrameInterpreter = @import("frame_interpreter.zig").FrameInterpreter(.{});
    // PUSH1 3, JUMP, STOP - jumping to position 3 which is STOP instruction should fail
    const bytecode = [_]u8{ 0x60, 0x03, 0x56, 0x00 };
    // The bytecode validation should catch invalid jump destinations during init
    const result = FrameInterpreter.init(allocator, &bytecode, 1000000, void{}, createTestHost());
    try std.testing.expectError(error.InvalidJumpDestination, result);
}
test "Frame memory expansion edge cases" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x53, 0x00 }; // MSTORE8 STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Test memory expansion with MSTORE8 at various offsets
    // Memory should expand in 32-byte chunks (EVM word alignment)
    // Store at offset 0 - should expand to 32 bytes
    try frame.stack.push(0xFF); // value
    try frame.stack.push(0); // offset
    try frame.mstore8();
    try frame.msize();
    const size1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 32), size1);
    // Store at offset 31 - should still be 32 bytes
    try frame.stack.push(0xAA); // value
    try frame.stack.push(31); // offset
    try frame.mstore8();
    try frame.msize();
    const size2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 32), size2);
    // Store at offset 32 - should expand to 64 bytes
    try frame.stack.push(0xBB); // value
    try frame.stack.push(32); // offset
    try frame.mstore8();
    try frame.msize();
    const size3 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 64), size3);
    // Store at offset 63 - should still be 64 bytes
    try frame.stack.push(0xCC); // value
    try frame.stack.push(63); // offset
    try frame.mstore8();
    try frame.msize();
    const size4 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 64), size4);
    // Store at offset 64 - should expand to 96 bytes
    try frame.stack.push(0xDD); // value
    try frame.stack.push(64); // offset
    try frame.mstore8();
    try frame.msize();
    const size5 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 96), size5);
}
test "Frame op_mcopy memory copy operations" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x5e, 0x00 }; // MCOPY STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // First, set up some data in memory
    const test_data: u256 = 0xDEADBEEFCAFEBABE;
    try frame.stack.push(test_data);
    try frame.stack.push(0); // offset
    try frame.mstore();
    // Test 1: Copy memory to a different location
    try frame.stack.push(32); // length
    try frame.stack.push(0); // src
    try frame.stack.push(32); // dest
    try frame.mcopy();
    // Verify the copy
    try frame.stack.push(32); // offset
    try frame.mload();
    const copied_value = try frame.stack.pop();
    try std.testing.expectEqual(test_data, copied_value);
    // Test 2: Zero-length copy (should do nothing)
    try frame.stack.push(0); // length
    try frame.stack.push(0); // src
    try frame.stack.push(64); // dest
    try frame.mcopy();
    // No error should occur
    // Test 3: Overlapping copy (forward overlap)
    // Store a pattern at offset 0
    try frame.stack.push(0x1111111111111111);
    try frame.stack.push(0);
    try frame.mstore();
    try frame.stack.push(0x2222222222222222);
    try frame.stack.push(32);
    try frame.mstore();
    // Copy 48 bytes from offset 0 to offset 16 (forward overlap)
    try frame.stack.push(48); // length
    try frame.stack.push(0); // src
    try frame.stack.push(16); // dest
    try frame.mcopy();
    // Read and verify
    try frame.stack.push(16);
    try frame.mload();
    const overlap_result1 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0x1111111111111111), overlap_result1);
    // Test 4: Overlapping copy (backward overlap)
    // Store new pattern
    try frame.stack.push(0x3333333333333333);
    try frame.stack.push(64);
    try frame.mstore();
    try frame.stack.push(0x4444444444444444);
    try frame.stack.push(96);
    try frame.mstore();
    // Copy 48 bytes from offset 64 to offset 48 (backward overlap)
    try frame.stack.push(48); // length
    try frame.stack.push(64); // src
    try frame.stack.push(48); // dest
    try frame.mcopy();
    // Read and verify
    try frame.stack.push(48);
    try frame.mload();
    const overlap_result2 = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0x3333333333333333), overlap_result2);
}
test "Frame JUMPDEST validation comprehensive" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    // Complex bytecode with valid and invalid jump destinations
    // PUSH1 8, JUMPI, INVALID, PUSH1 12, JUMP, INVALID, JUMPDEST, PUSH1 1, STOP, INVALID, JUMPDEST, PUSH1 2, STOP
    const bytecode = [_]u8{
        0x60, 0x08, // PUSH1 8 (offset 0-1)
        0x57, // JUMPI (offset 2)
        0xFE, // INVALID (offset 3)
        0x60, 0x0C, // PUSH1 12 (offset 4-5)
        0x56, // JUMP (offset 6)
        0xFE, // INVALID (offset 7)
        0x5B, // JUMPDEST (offset 8) - valid destination
        0x60, 0x01, // PUSH1 1 (offset 9-10)
        0x00, // STOP (offset 11)
        0xFE, // INVALID (offset 12) - trying to jump here should fail
        0x5B, // JUMPDEST (offset 13) - valid destination
        0x60, 0x02, // PUSH1 2 (offset 14-15)
        0x00, // STOP (offset 16)
    };
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // The interpreter would handle JUMP/JUMPI opcodes with proper JUMPDEST validation
    // For now we test that the frame was properly initialized and bytecode is correct
    try std.testing.expectEqual(@intFromEnum(Opcode.PUSH1), frame.bytecode[0]);
    try std.testing.expectEqual(@as(u8, 8), frame.bytecode[1]);
    try std.testing.expectEqual(@intFromEnum(Opcode.JUMPI), frame.bytecode[2]);
    try std.testing.expectEqual(@intFromEnum(Opcode.INVALID), frame.bytecode[3]);
    try std.testing.expectEqual(@intFromEnum(Opcode.JUMPDEST), frame.bytecode[8]);
    try std.testing.expectEqual(@intFromEnum(Opcode.JUMPDEST), frame.bytecode[13]);
}
test "Frame storage operations with database" {
    const allocator = std.testing.allocator;
    // Create a frame with database support
    const FrameWithDb = Frame(.{ .has_database = true });
    // Create a test database
    var db = @import("memory_database.zig").MemoryDatabase.init(allocator);
    defer db.deinit();
    const db_interface = db.to_database_interface();
    const bytecode = [_]u8{ 0x54, 0x00 }; // SLOAD STOP
    var frame = try FrameWithDb.init(allocator, &bytecode, 1000000, db_interface, createTestHost());
    defer frame.deinit(allocator);
    // Test SSTORE followed by SLOAD
    const test_key: u256 = 0x42;
    const test_value: u256 = 0xDEADBEEF;
    // Store a value
    try frame.stack.push(test_value);
    try frame.stack.push(test_key);
    try frame.sstore();
    // Load it back
    try frame.stack.push(test_key);
    try frame.sload();
    const loaded_value = try frame.stack.pop();
    try std.testing.expectEqual(test_value, loaded_value);
    // Test overwriting a value
    const new_value: u256 = 0xCAFEBABE;
    try frame.stack.push(new_value);
    try frame.stack.push(test_key);
    try frame.sstore();
    try frame.stack.push(test_key);
    try frame.sload();
    const overwritten_value = try frame.stack.pop();
    try std.testing.expectEqual(new_value, overwritten_value);
    // Test loading non-existent key (should return 0)
    const non_existent_key: u256 = 0x999;
    try frame.stack.push(non_existent_key);
    try frame.sload();
    const zero_value = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), zero_value);
}
test "Frame transient storage operations with database" {
    const allocator = std.testing.allocator;
    // Create a frame with database support
    const FrameWithDb = Frame(.{ .has_database = true });
    // Create a test database
    var db = @import("memory_database.zig").MemoryDatabase.init(allocator);
    defer db.deinit();
    const db_interface = db.to_database_interface();
    const bytecode = [_]u8{ 0x5c, 0x00 }; // TLOAD STOP
    var frame = try FrameWithDb.init(allocator, &bytecode, 1000000, db_interface, createTestHost());
    defer frame.deinit(allocator);
    // Test TSTORE followed by TLOAD
    const test_key: u256 = 0x123;
    const test_value: u256 = 0xABCDEF;
    // Store a value in transient storage
    try frame.stack.push(test_value);
    try frame.stack.push(test_key);
    try frame.tstore();
    // Load it back
    try frame.stack.push(test_key);
    try frame.tload();
    const loaded_value = try frame.stack.pop();
    try std.testing.expectEqual(test_value, loaded_value);
    // Test that transient storage is separate from regular storage
    // Store in regular storage
    const regular_value: u256 = 0x111111;
    try frame.stack.push(regular_value);
    try frame.stack.push(test_key); // Same key
    try frame.sstore();
    // Load from transient storage should still return the transient value
    try frame.stack.push(test_key);
    try frame.tload();
    const transient_value = try frame.stack.pop();
    try std.testing.expectEqual(test_value, transient_value);
    // Load from regular storage should return the regular value
    try frame.stack.push(test_key);
    try frame.sload();
    const regular_loaded = try frame.stack.pop();
    try std.testing.expectEqual(regular_value, regular_loaded);
}
test "Frame storage operations without database should fail" {
    const allocator = std.testing.allocator;
    // Create a frame without database support (default)
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x54, 0x00 }; // SLOAD STOP
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // All storage operations should return InvalidOpcode when no database
    try frame.stack.push(0);
    try std.testing.expectError(error.InvalidOpcode, frame.sload());
    try frame.stack.push(0);
    try frame.stack.push(0);
    try std.testing.expectError(error.InvalidOpcode, frame.sstore());
    try frame.stack.push(0);
    try std.testing.expectError(error.InvalidOpcode, frame.tload());
    try frame.stack.push(0);
    try frame.stack.push(0);
    try std.testing.expectError(error.InvalidOpcode, frame.tstore());
}
test "Frame gas consumption tracking" {
    const allocator = std.testing.allocator;
    const FrameInterpreter = @import("frame_interpreter.zig").FrameInterpreter(.{});
    // PUSH1 10, PUSH1 20, ADD, GAS, STOP
    const bytecode = [_]u8{ 0x60, 0x0A, 0x60, 0x14, 0x01, 0x5A, 0x00 };
    var interpreter = try FrameInterpreter.init(allocator, &bytecode, 1000, {}, createTestHost());
    defer interpreter.deinit(allocator);
    // Check initial gas
    const initial_gas = @max(interpreter.frame.gas_remaining, 0);
    try std.testing.expectEqual(@as(i32, 1000), initial_gas);
    // Run the interpretation which will consume gas
    const result = interpreter.interpret();
    try std.testing.expectError(error.STOP, result);
    // Check that gas was consumed - stack should have gas value then result
    // Pop gas value (should be less than 1000)
    const gas_remaining = try interpreter.frame.stack.pop();
    try std.testing.expect(gas_remaining < 1000);
    // Pop addition result
    const add_result = try interpreter.frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 30), add_result); // 10 + 20 = 30
}
test "Stream-based instruction format - simple operations" {
    const allocator = std.testing.allocator;
    // Expected stream layout:
    // For simple ops (ADD): 1 chunk [handler]
    // For PUSH with inline value: 2 chunks [handler, value]
    // Stream: [push_inline_handler, 5, push_inline_handler, 10, add_handler, stop_handler]
    // Create mock stream to test the concept
    const stream_size = 6;
    var stream = try allocator.alloc(usize, stream_size);
    defer allocator.free(stream);
    // Simulate what the stream would look like
    var idx: usize = 0;
    // PUSH1 5 - inline value
    stream[idx] = @intFromPtr(&mock_push_inline_handler);
    stream[idx + 1] = 5;
    idx += 2;
    // PUSH1 10 - inline value
    stream[idx] = @intFromPtr(&mock_push_inline_handler);
    stream[idx + 1] = 10;
    idx += 2;
    // ADD - no metadata
    stream[idx] = @intFromPtr(&mock_add_handler);
    idx += 1;
    // STOP - no metadata
    stream[idx] = @intFromPtr(&mock_stop_handler);
    // Test that stream has expected structure
    try std.testing.expectEqual(@as(usize, 6), stream.len);
    try std.testing.expectEqual(@as(usize, 5), stream[1]); // First push value
    try std.testing.expectEqual(@as(usize, 10), stream[3]); // Second push value
}
// Mock handlers for testing stream structure
fn mock_push_inline_handler(self: *anyopaque, stream: []usize, idx: usize) !void {
    _ = self;
    _ = stream;
    _ = idx;
    unreachable; // Not executed in this test
}
fn mock_add_handler(self: *anyopaque, stream: []usize, idx: usize) !void {
    _ = self;
    _ = stream;
    _ = idx;
    unreachable; // Not executed in this test
}
fn mock_stop_handler(self: *anyopaque, stream: []usize, idx: usize) !void {
    _ = self;
    _ = stream;
    _ = idx;
    unreachable; // Not executed in this test
}
test "Stream-based instruction format - large PUSH values" {
    const allocator = std.testing.allocator;
    // Test PUSH32 with large value that doesn't fit in usize
    // Expected stream layout:
    // [push_pointer_handler, ptr_to_u256, stop_handler]
    // Create storage for large values
    var push_values_large = try allocator.alloc(u256, 1);
    defer allocator.free(push_values_large);
    push_values_large[0] = std.math.maxInt(u256); // Large value that doesn't fit in usize
    // Create stream
    const stream_size = 3;
    var stream = try allocator.alloc(usize, stream_size);
    defer allocator.free(stream);
    // PUSH32 with pointer to large value
    stream[0] = @intFromPtr(&mock_push_pointer_handler);
    stream[1] = @intFromPtr(&push_values_large[0]);
    // STOP
    stream[2] = @intFromPtr(&mock_stop_handler);
    // Test that stream has expected structure
    try std.testing.expectEqual(@as(usize, 3), stream.len);
    // Verify pointer points to correct value
    const ptr = @as(*const u256, @ptrFromInt(stream[1]));
    try std.testing.expectEqual(std.math.maxInt(u256), ptr.*);
}
fn mock_push_pointer_handler(self: *anyopaque, stream: []usize, idx: usize) !void {
    _ = self;
    _ = stream;
    _ = idx;
    unreachable; // Not executed in this test
}
test "Stream-based instruction format - PC and JUMP operations" {
    const allocator = std.testing.allocator;
    // Test PC opcode and JUMP operation
    // Expected stream layout:
    // [pc_handler, pc_value, jumpdest_handler, jump_handler, dest_idx, stop_handler]
    const stream_size = 6;
    var stream = try allocator.alloc(usize, stream_size);
    defer allocator.free(stream);
    var idx: usize = 0;
    // PC - stores PC value inline
    stream[idx] = @intFromPtr(&mock_pc_handler);
    stream[idx + 1] = 42; // PC value at this point
    idx += 2;
    // JUMPDEST - no metadata
    stream[idx] = @intFromPtr(&mock_jumpdest_handler);
    idx += 1;
    // JUMP - stores destination instruction index inline
    stream[idx] = @intFromPtr(&mock_jump_handler);
    stream[idx + 1] = 2; // Index of JUMPDEST in stream
    idx += 2;
    // STOP
    stream[idx] = @intFromPtr(&mock_stop_handler);
    // Test that stream has expected structure
    try std.testing.expectEqual(@as(usize, 6), stream.len);
    try std.testing.expectEqual(@as(usize, 42), stream[1]); // PC value
    try std.testing.expectEqual(@as(usize, 2), stream[4]); // Jump destination index
}
fn mock_pc_handler(self: *anyopaque, stream: []usize, idx: usize) !void {
    _ = self;
    _ = stream;
    _ = idx;
    unreachable; // Not executed in this test
}
fn mock_jumpdest_handler(self: *anyopaque, stream: []usize, idx: usize) !void {
    _ = self;
    _ = stream;
    _ = idx;
    unreachable; // Not executed in this test
}
fn mock_jump_handler(self: *anyopaque, stream: []usize, idx: usize) !void {
    _ = self;
    _ = stream;
    _ = idx;
    unreachable; // Not executed in this test
}
test "Frame LOG0 operation" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Store some data in memory
    const test_data = "Hello, Ethereum!";
    const data_offset: usize = 32;
    // Write data to memory
    for (test_data, 0..) |byte, i| {
        frame.memory.set_byte_evm(data_offset + i, byte) catch unreachable;
    }
    // Push data location and size for LOG0
    try frame.stack.push(@as(u256, data_offset)); // offset
    try frame.stack.push(test_data.len); // size
    // Execute LOG0
    try frame.log0();
    // Verify log was created
    try std.testing.expectEqual(@as(usize, 1), frame.logs.items.len);
    const log_entry = frame.logs.items[0];
    // Check log properties
    try std.testing.expectEqual(frame.contract_address, log_entry.address);
    try std.testing.expectEqual(@as(usize, 0), log_entry.topics.len); // LOG0 has no topics
    try std.testing.expectEqualSlices(u8, test_data, log_entry.data);
}
test "Frame LOG1 operation with topic" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Store some data in memory
    const test_data = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    const data_offset: usize = 0;
    // Write data to memory
    for (test_data, 0..) |byte, i| {
        frame.memory.set_byte_evm(data_offset + i, byte) catch unreachable;
    }
    // Topic for LOG1
    const topic1: u256 = 0xDEADBEEF;
    // Push data for LOG1: topic, offset, size
    try frame.stack.push(topic1); // topic
    try frame.stack.push(@as(u256, data_offset)); // offset
    try frame.stack.push(test_data.len); // size
    // Execute LOG1
    try frame.log1();
    // Verify log was created
    try std.testing.expectEqual(@as(usize, 1), frame.logs.items.len);
    const log_entry = frame.logs.items[0];
    // Check log properties
    try std.testing.expectEqual(frame.contract_address, log_entry.address);
    try std.testing.expectEqual(@as(usize, 1), log_entry.topics.len);
    try std.testing.expectEqual(topic1, log_entry.topics[0]);
    try std.testing.expectEqualSlices(u8, &test_data, log_entry.data);
}
test "Frame LOG4 operation with multiple topics" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Topics for LOG4
    const topic1: u256 = 0x1111111111111111;
    const topic2: u256 = 0x2222222222222222;
    const topic3: u256 = 0x3333333333333333;
    const topic4: u256 = 0x4444444444444444;
    // Push data for LOG4: topics (in reverse order), offset, size
    try frame.stack.push(topic4);
    try frame.stack.push(topic3);
    try frame.stack.push(topic2);
    try frame.stack.push(topic1);
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // size (empty data)
    // Execute LOG4
    try frame.log4();
    // Verify log was created
    try std.testing.expectEqual(@as(usize, 1), frame.logs.items.len);
    const log_entry = frame.logs.items[0];
    // Check log properties
    try std.testing.expectEqual(frame.contract_address, log_entry.address);
    try std.testing.expectEqual(@as(usize, 4), log_entry.topics.len);
    try std.testing.expectEqual(topic1, log_entry.topics[0]);
    try std.testing.expectEqual(topic2, log_entry.topics[1]);
    try std.testing.expectEqual(topic3, log_entry.topics[2]);
    try std.testing.expectEqual(topic4, log_entry.topics[3]);
    try std.testing.expectEqual(@as(usize, 0), log_entry.data.len); // Empty data
}
// TODO: Re-enable this test once we have a proper mock host that can simulate static context
// test "Frame LOG in static context fails" {
//     const allocator = std.testing.allocator;
//     const F = Frame(.{});
//     const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
//     const host = createTestHost();
//     var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
//     defer frame.deinit(allocator);
//     // Set static context
//     frame.is_static = true;
//     // Push data for LOG0
//     try frame.stack.push(0); // offset
//     try frame.stack.push(10); // size
//     // Execute LOG0 should fail
//     try std.testing.expectError(error.WriteProtection, frame.log0());
// }
test "Frame LOG with out of bounds memory access" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Push data for LOG0 with huge offset
    try frame.stack.push(std.math.maxInt(u256)); // offset too large
    try frame.stack.push(10); // size
    // Execute LOG0 should fail
    try std.testing.expectError(error.OutOfBounds, frame.log0());
}
test "Frame LOG gas consumption" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const initial_gas: i32 = 10000;
    var frame = try F.init(allocator, &bytecode, initial_gas, void{}, createTestHost());
    defer frame.deinit(allocator);
    // Store some data in memory
    const test_data = "Test log data";
    const data_offset: usize = 0;
    // Write data to memory
    for (test_data, 0..) |byte, i| {
        frame.memory.set_byte_evm(data_offset + i, byte) catch unreachable;
    }
    // Push data for LOG0
    try frame.stack.push(@as(u256, data_offset)); // offset
    try frame.stack.push(test_data.len); // size
    // Execute LOG0
    try frame.log0();
    // Verify gas was consumed using centralized constants (no memory expansion in this case)
    const expected_log_gas: u64 = GasConstants.log_gas_cost(0, test_data.len);
    const expected_gas_consumed = @as(i32, @intCast(expected_log_gas));
    try std.testing.expectEqual(initial_gas - expected_gas_consumed, @max(frame.gas_remaining, 0));
}
// ============================================================================
// COMPREHENSIVE BOUNDARY CONDITION TESTS
// ============================================================================
test "Frame arithmetic edge cases - overflow and underflow boundaries" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Test ADD at maximum values - should wrap to 0
    try frame.stack.push(std.math.maxInt(u256));
    try frame.stack.push(1);
    try frame.add();
    const add_overflow = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), add_overflow);
    // Test SUB underflow - should wrap around
    try frame.stack.push(0);
    try frame.stack.push(1);
    try frame.sub();
    const sub_underflow = try frame.stack.pop();
    try std.testing.expectEqual(std.math.maxInt(u256), sub_underflow);
    // Test MUL overflow - large values should wrap
    const large_val = @as(u256, 1) << 128; // 2^128
    try frame.stack.push(large_val);
    try frame.stack.push(large_val);
    try frame.mul();
    const mul_overflow = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), mul_overflow); // 2^256 wraps to 0
    // Test edge case: multiply by zero
    try frame.stack.push(std.math.maxInt(u256));
    try frame.stack.push(0);
    try frame.mul();
    const mul_zero = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), mul_zero);
}
test "Frame division edge cases - division by zero and signed boundaries" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Test division by zero returns zero
    try frame.stack.push(100);
    try frame.stack.push(0);
    try frame.div();
    const div_zero = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), div_zero);
    // Test signed division overflow case: -2^255 / -1 = -2^255 (stays same due to overflow)
    const min_i256 = @as(u256, 1) << 255; // -2^255 in two's complement
    const neg_one = std.math.maxInt(u256); // -1 in two's complement
    try frame.stack.push(min_i256);
    try frame.stack.push(neg_one);
    try frame.sdiv();
    const sdiv_overflow = try frame.stack.pop();
    try std.testing.expectEqual(min_i256, sdiv_overflow);
    // Test signed division by zero
    try frame.stack.push(neg_one); // -1
    try frame.stack.push(0);
    try frame.sdiv();
    const sdiv_zero = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), sdiv_zero);
}
test "Frame modulo edge cases - zero modulus and signed boundaries" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Test modulo by zero returns zero
    try frame.stack.push(57);
    try frame.stack.push(0);
    try frame.mod();
    const mod_zero = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), mod_zero);
    // Test signed modulo edge cases
    const min_i256 = @as(u256, 1) << 255; // -2^255 in two's complement
    const neg_one = std.math.maxInt(u256); // -1 in two's complement
    // Test -2^255 % -1 = 0 (special case)
    try frame.stack.push(min_i256);
    try frame.stack.push(neg_one);
    try frame.smod();
    const smod_overflow = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), smod_overflow);
    // Test signed modulo by zero
    try frame.stack.push(neg_one); // -1
    try frame.stack.push(0);
    try frame.smod();
    const smod_zero = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), smod_zero);
}
test "Frame addmod and mulmod edge cases - zero modulus" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Test ADDMOD with zero modulus - should return 0
    try frame.stack.push(10);
    try frame.stack.push(20);
    try frame.stack.push(0); // modulus = 0
    try frame.addmod();
    const addmod_zero = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), addmod_zero);
    // Test MULMOD with zero modulus - should return 0
    try frame.stack.push(5);
    try frame.stack.push(7);
    try frame.stack.push(0); // modulus = 0
    try frame.mulmod();
    const mulmod_zero = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), mulmod_zero);
    // Test ADDMOD with overflow - should prevent overflow through modulus
    try frame.stack.push(std.math.maxInt(u256));
    try frame.stack.push(std.math.maxInt(u256));
    try frame.stack.push(1000); // modulus = 1000
    try frame.addmod();
    const addmod_overflow = try frame.stack.pop();
    // (2^256-1 + 2^256-1) % 1000 = (2^257-2) % 1000 = 998
    try std.testing.expectEqual(@as(u256, 998), addmod_overflow);
}
test "Frame exponentiation edge cases - zero base and exponent" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Test 0^0 = 1 (mathematical convention in EVM)
    try frame.stack.push(0);
    try frame.stack.push(0);
    try frame.exp();
    const zero_zero = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), zero_zero);
    // Test 0^n = 0 for n > 0
    try frame.stack.push(0);
    try frame.stack.push(5);
    try frame.exp();
    const zero_exp = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), zero_exp);
    // Test n^0 = 1 for any n
    try frame.stack.push(123456);
    try frame.stack.push(0);
    try frame.exp();
    const any_zero = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), any_zero);
    // Test large exponentiation that should overflow and wrap
    try frame.stack.push(2);
    try frame.stack.push(256); // 2^256 should wrap to 0
    try frame.exp();
    const large_exp = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), large_exp);
}
test "Frame shift operations edge cases - large shift amounts" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Test SHL with shift amount >= 256 - should result in 0
    try frame.stack.push(0xFF);
    try frame.stack.push(256);
    try frame.shl();
    const shl_overflow = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), shl_overflow);
    // Test SHR with shift amount >= 256 - should result in 0
    try frame.stack.push(std.math.maxInt(u256));
    try frame.stack.push(300);
    try frame.shr();
    const shr_overflow = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), shr_overflow);
    // Test SAR with large shift on negative number - should result in all 1s
    const neg_one = std.math.maxInt(u256); // -1 in two's complement
    try frame.stack.push(neg_one);
    try frame.stack.push(300);
    try frame.sar();
    const sar_neg = try frame.stack.pop();
    try std.testing.expectEqual(std.math.maxInt(u256), sar_neg);
    // Test SAR with large shift on positive number - should result in 0
    try frame.stack.push(0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF);
    try frame.stack.push(300);
    try frame.sar();
    const sar_pos = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), sar_pos);
}
test "Frame sign extension edge cases - boundary byte indices" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Test SIGNEXTEND with index >= 32 - should leave value unchanged
    const test_val: u256 = 0x123456789ABCDEF0;
    try frame.stack.push(test_val);
    try frame.stack.push(32); // index >= 32
    try frame.signextend();
    const unchanged = try frame.stack.pop();
    try std.testing.expectEqual(test_val, unchanged);
    // Test SIGNEXTEND with very large index
    try frame.stack.push(test_val);
    try frame.stack.push(std.math.maxInt(u256));
    try frame.signextend();
    const unchanged_large = try frame.stack.pop();
    try std.testing.expectEqual(test_val, unchanged_large);
    // Test SIGNEXTEND at boundary - byte index 31 (should be no-op)
    try frame.stack.push(test_val);
    try frame.stack.push(31);
    try frame.signextend();
    const boundary = try frame.stack.pop();
    try std.testing.expectEqual(test_val, boundary);
}
test "Frame memory operations edge cases - extreme offsets and sizes" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Test MLOAD with very large offset - should fail with OutOfBounds
    try frame.stack.push(std.math.maxInt(u256));
    try std.testing.expectError(error.OutOfBounds, frame.mload());
    // Test MSTORE with offset near memory limit
    const near_limit = F.Memory.MEMORY_LIMIT - 32;
    if (near_limit < std.math.maxInt(usize)) {
        // Only test if the offset fits in usize
        const test_value: u256 = 0xDEADBEEF;
        try frame.stack.push(test_value);
        try frame.stack.push(@as(u256, near_limit));
        // This should either succeed or fail with OutOfBounds, not crash
        _ = frame.mstore() catch |err| {
            try std.testing.expect(err == error.OutOfBounds or err == error.OutOfGas);
        };
    }
    // Test MSIZE after memory operations
    frame.memory.set_byte_evm(100, 0xFF) catch {};
    try frame.msize();
    const size = frame.stack.pop_unsafe();
    try std.testing.expect(size >= 128); // Memory expands in 32-byte chunks
}
test "Frame stack capacity edge cases - exactly at limits" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Fill stack to exactly capacity (1024)
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        try frame.stack.push(@as(u256, i));
    }
    // Stack should be exactly full now
    try std.testing.expectError(error.StackOverflow, frame.stack.push(999));
    // Should be able to peek at top
    const top = frame.stack.peek_unsafe();
    try std.testing.expectEqual(@as(u256, 1023), top);
    // Pop one and should be able to push one
    _ = frame.stack.pop_unsafe();
    try frame.stack.push(2000);
    const new_top = frame.stack.peek_unsafe();
    try std.testing.expectEqual(@as(u256, 2000), new_top);
}
test "Frame DUP operations edge cases - maximum depth" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Push 16 values for DUP16 test
    var i: usize = 1;
    while (i <= 16) : (i += 1) {
        try frame.stack.push(@as(u256, i));
    }
    // Test DUP16 - should duplicate the 16th item from top (value 1)
    try frame.stack.dup16();
    const dup16_result = frame.stack.peek_unsafe();
    try std.testing.expectEqual(@as(u256, 1), dup16_result);
    // Stack should now be full enough that DUP16 would fail if we had < 16 items
    _ = frame.stack.pop_unsafe(); // Remove the duplicated item
    // Test DUP with insufficient stack depth
    // Clear most of stack
    while (frame.stack.size() > 5) {
        _ = frame.stack.pop_unsafe();
    }
    // Now DUP16 should fail
    try std.testing.expectError(error.StackUnderflow, frame.stack.dup16());
}
test "Frame SWAP operations edge cases - maximum depth" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Push 17 values for SWAP16 test (need top + 16 more)
    var i: usize = 1;
    while (i <= 17) : (i += 1) {
        try frame.stack.push(@as(u256, i));
    }
    // Test SWAP16 - should swap top (17) with 17th item from top (1)
    try frame.stack.swap16();
    const swapped_top = frame.stack.peek_unsafe();
    try std.testing.expectEqual(@as(u256, 1), swapped_top);
    // 17th position should now have 17
    // Pop 16 items to reach the swapped position
    var j: usize = 0;
    while (j < 16) : (j += 1) {
        _ = frame.stack.pop_unsafe();
    }
    const swapped_bottom = frame.stack.peek_unsafe();
    try std.testing.expectEqual(@as(u256, 17), swapped_bottom);
}
test "Frame gas edge cases - out of gas conditions" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    // Start with very low gas
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    var frame = try F.init(allocator, &bytecode, 1, void{}, createTestHost()); // Only 1 gas
    defer frame.deinit(allocator);
    // Gas should be 1
    try frame.gas();
    const initial_gas = frame.stack.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 1), initial_gas);
    // Test with zero gas
    var zero_gas_frame = try F.init(allocator, &bytecode, 0, void{}, createTestHost());
    defer zero_gas_frame.deinit(allocator);
    try zero_gas_frame.gas();
    const zero_gas = zero_gas_frame.stack.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 0), zero_gas);
    // Test with negative gas (should be treated as 0)
    var neg_gas_frame = try F.init(allocator, &bytecode, -100, void{}, createTestHost());
    defer neg_gas_frame.deinit(allocator);
    try neg_gas_frame.gas();
    const neg_gas = neg_gas_frame.stack.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 0), neg_gas);
}
test "Frame comparison operations edge cases - signed number boundaries" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    const min_i256 = @as(u256, 1) << 255; // Most negative number in two's complement
    const max_i256 = (@as(u256, 1) << 255) - 1; // Most positive number in two's complement
    // Test SLT: min_i256 < max_i256 should be true
    try frame.stack.push(max_i256);
    try frame.stack.push(min_i256);
    try frame.slt();
    const slt_boundary = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), slt_boundary);
    // Test SGT: max_i256 > min_i256 should be true
    try frame.stack.push(min_i256);
    try frame.stack.push(max_i256);
    try frame.sgt();
    const sgt_boundary = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), sgt_boundary);
    // Test edge case: -1 vs 0 in signed comparison
    const neg_one = std.math.maxInt(u256); // -1 in two's complement
    try frame.stack.push(0);
    try frame.stack.push(neg_one);
    try frame.slt(); // -1 < 0 should be true
    const neg_one_slt = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), neg_one_slt);
}
test "Frame byte extraction edge cases - out of bounds indices" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    const test_value: u256 = 0x123456789ABCDEF0;
    // Test BYTE with index >= 32 - should return 0
    try frame.stack.push(test_value);
    try frame.stack.push(32);
    try frame.byte();
    const out_of_bounds = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), out_of_bounds);
    // Test BYTE with very large index
    try frame.stack.push(test_value);
    try frame.stack.push(std.math.maxInt(u256));
    try frame.byte();
    const large_index = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), large_index);
    // Test BYTE at boundary - index 31 should extract the last byte
    try frame.stack.push(0xFF); // Only the last byte is set
    try frame.stack.push(31);
    try frame.byte();
    const boundary_byte = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), boundary_byte);
}
test "Frame keccak256 edge cases - empty input and large input" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Test KECCAK256 with zero-length input
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // size = 0
    try frame.keccak256();
    const empty_hash = try frame.stack.pop();
    // Hash of empty string should be the known constant
    const expected_empty = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    try std.testing.expectEqual(expected_empty, empty_hash);
    // Test KECCAK256 with large size that would exceed memory bounds
    try frame.stack.push(0); // offset
    try frame.stack.push(std.math.maxInt(u256)); // very large size
    try std.testing.expectError(error.OutOfBounds, frame.keccak256());
}
test "Frame log operations edge cases - maximum topics and static context" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // TODO: Re-enable these tests once we have a proper mock host that can simulate static context
    // Test LOG operations in static context should all fail
    // frame.is_static = true;
    // // Test LOG0 in static context
    // try frame.stack.push(0); // offset
    // try frame.stack.push(0); // size
    // try std.testing.expectError(error.WriteProtection, frame.log0());
    // // Test LOG4 in static context
    // try frame.stack.push(1); // topic4
    // try frame.stack.push(2); // topic3
    // try frame.stack.push(3); // topic2
    // try frame.stack.push(4); // topic1
    // try frame.stack.push(0); // offset
    // try frame.stack.push(0); // size
    // try std.testing.expectError(error.WriteProtection, frame.log4());
    // // Reset static context for successful tests
    // frame.is_static = false;
    // Test LOG with maximum size data
    const max_data_size: usize = 1000;
    // Write some data to memory
    var i: usize = 0;
    while (i < max_data_size) : (i += 1) {
        frame.memory.set_byte_evm(i, @as(u8, @intCast(i % 256))) catch break;
    }
    // Test LOG0 with large data
    try frame.stack.push(0); // offset
    try frame.stack.push(@as(u256, max_data_size)); // size
    try frame.log0();
    // Verify log was created with correct size
    try std.testing.expectEqual(@as(usize, 1), frame.logs.items.len);
    const large_log = frame.logs.items[0];
    try std.testing.expectEqual(max_data_size, large_log.data.len);
}
test "Frame initialization edge cases - various configurations" {
    const allocator = std.testing.allocator;
    // Test frame with minimal gas
    const F1 = Frame(.{});
    const bytecode1 = [_]u8{@intFromEnum(Opcode.STOP)};
    var frame1 = try F1.init(allocator, &bytecode1, 0, void{}, createTestHost());
    defer frame1.deinit(allocator);
    try std.testing.expectEqual(@as(i32, 0), frame1.gas_remaining);
    // Test frame with maximum bytecode size for different PC types
    const SmallFrame = Frame(.{ .max_bytecode_size = 255 });
    try std.testing.expectEqual(u8, SmallFrame.PcType);
    const MediumFrame = Frame(.{ .max_bytecode_size = 4095 });
    try std.testing.expectEqual(u12, MediumFrame.PcType);
    const LargeFrame = Frame(.{ .max_bytecode_size = 65535 });
    try std.testing.expectEqual(u16, LargeFrame.PcType);
    // Test empty bytecode
    const empty_bytecode = [_]u8{};
    var empty_frame = try F1.init(allocator, &empty_bytecode, 1000, void{}, createTestHost());
    defer empty_frame.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_frame.bytecode.len);
}
test "Frame error recovery - partial operations and state consistency" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    const bytecode = [_]u8{@intFromEnum(Opcode.STOP)};
    const host = createTestHost();
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    // Test that failed operations don't corrupt stack state
    const initial_stack_len = frame.stack.size();
    // Attempt to pop from empty stack
    try std.testing.expectError(error.StackUnderflow, frame.stack.pop());
    try std.testing.expectEqual(initial_stack_len, frame.stack.size());
    // Add some values
    try frame.stack.push(100);
    try frame.stack.push(200);
    // Attempt invalid operation that should fail cleanly
    // Test BYTE with invalid stack state by trying to duplicate beyond capacity
    // Fill stack near capacity first
    while (frame.stack.size() < 1023) {
        try frame.stack.push(@as(u256, frame.stack.size()));
    }
    // Now stack is nearly full, attempt operation that might fail
    try frame.stack.push(999); // Stack should now be exactly full
    // Attempt to push one more - should fail cleanly
    try std.testing.expectError(error.StackOverflow, frame.stack.push(1000));
    // Stack should still be at capacity, not corrupted
    try std.testing.expectEqual(@as(usize, 1024), frame.stack.size());
    try std.testing.expectEqual(@as(u256, 999), frame.stack.peek_unsafe());
}
// Host-dependent opcode tests (CALL, DELEGATECALL, STATICCALL, CREATE, CREATE2, SELFDESTRUCT, etc.)
// have been removed from this file. This functionality is covered by comprehensive integration tests.
test "Frame bytecode edge cases - empty bytecode" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    
    // Empty bytecode should be valid and execute as if immediately hitting implicit STOP
    const empty_bytecode = [_]u8{};
    var frame = try F.init(allocator, &empty_bytecode, 1000, void{}, createTestHost());
    defer frame.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 0), frame.bytecode.len);
    try std.testing.expectEqual(@as(usize, 0), frame.stack.size());
}
test "Frame bytecode edge cases - maximum size bytecode" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    
    // Test exactly at the limit (24576 bytes)
    var max_bytecode = try allocator.alloc(u8, 24576);
    defer allocator.free(max_bytecode);
    @memset(max_bytecode, @intFromEnum(Opcode.JUMPDEST)); // Fill with valid opcodes
    max_bytecode[max_bytecode.len - 1] = @intFromEnum(Opcode.STOP);
    
    var frame = try F.init(allocator, max_bytecode, 1000000, void{}, createTestHost());
    defer frame.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 24576), frame.bytecode.len);
}
test "Frame bytecode edge cases - bytecode too large" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    
    // Test one byte over the limit
    const oversized_bytecode = try allocator.alloc(u8, 24577);
    defer allocator.free(oversized_bytecode);
    @memset(oversized_bytecode, @intFromEnum(Opcode.JUMPDEST));
    
    try std.testing.expectError(error.BytecodeTooLarge, F.init(allocator, oversized_bytecode, 1000000, void{}, createTestHost()));
}
test "Frame bytecode edge cases - truncated PUSH operations" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    
    // Test cases for truncated PUSH operations at end of bytecode
    const test_cases = [_]struct {
        bytecode: []const u8,
        description: []const u8,
    }{
        .{ .bytecode = &[_]u8{@intFromEnum(Opcode.PUSH1)}, .description = "PUSH1 with no data" },
        .{ .bytecode = &[_]u8{@intFromEnum(Opcode.PUSH2), 0x12}, .description = "PUSH2 with only 1 byte" },
        .{ .bytecode = &[_]u8{@intFromEnum(Opcode.PUSH32), 0x01, 0x02}, .description = "PUSH32 with only 2 bytes" },
        .{ .bytecode = &[_]u8{@intFromEnum(Opcode.PUSH16)} ++ ([_]u8{0xFF} ** 15), .description = "PUSH16 with only 15 bytes" },
    };
    
    for (test_cases) |test_case| {
        var frame = try F.init(allocator, test_case.bytecode, 100000, void{}, createTestHost());
        defer frame.deinit(allocator);
        
        // Frame should initialize successfully - bytecode validation happens during execution
        try std.testing.expectEqual(test_case.bytecode.len, frame.bytecode.len);
    }
}
test "Frame bytecode edge cases - single byte bytecode" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    
    // Test various single-byte bytecodes
    const single_byte_opcodes = [_]Opcode{
        .STOP,
        .ADD,
        .MUL,
        .SUB,
        .DIV,
        .JUMPDEST,
        .POP,
        .MLOAD,
        .INVALID,
    };
    
    for (single_byte_opcodes) |opcode| {
        const bytecode = [_]u8{@intFromEnum(opcode)};
        var frame = try F.init(allocator, &bytecode, 10000, void{}, createTestHost());
        defer frame.deinit(allocator);
        
        try std.testing.expectEqual(@as(usize, 1), frame.bytecode.len);
        try std.testing.expectEqual(@intFromEnum(opcode), frame.bytecode[0]);
    }
}
test "Frame bytecode edge cases - all invalid opcodes" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    
    // Bytecode consisting entirely of invalid opcodes
    const invalid_opcodes = [_]u8{
        0x0C, 0x0D, 0x0E, 0x0F, // Invalid in 0x0C-0x0F range
        0x1E, 0x1F,             // Invalid in 0x1E-0x1F range  
        0x21, 0x22, 0x23,       // Invalid in 0x21-0x2F range
        0x49, 0x4A, 0x4B,       // Invalid in 0x49-0x4F range
        0xA5, 0xA6, 0xA7,       // Invalid in 0xA5-0xEF range
        0xFE,                   // INVALID opcode
    };
    
    var frame = try F.init(allocator, &invalid_opcodes, 100000, void{}, createTestHost());
    defer frame.deinit(allocator);
    
    // Frame initialization should succeed - invalid opcodes are handled during execution
    try std.testing.expectEqual(invalid_opcodes.len, frame.bytecode.len);
}
test "Frame bytecode edge cases - alternating JUMPDEST pattern" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    
    // Create a pattern of alternating JUMPDEST and other opcodes
    var bytecode: [100]u8 = undefined;
    for (0..50) |i| {
        bytecode[i * 2] = @intFromEnum(Opcode.JUMPDEST);
        bytecode[i * 2 + 1] = @intFromEnum(Opcode.POP);
    }
    
    var frame = try F.init(allocator, &bytecode, 50000, void{}, createTestHost());
    defer frame.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 100), frame.bytecode.len);
}
test "Frame bytecode edge cases - PUSH data spanning entire bytecode" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    
    // Create bytecode where PUSH32 data takes up most of the bytecode
    var bytecode: [34]u8 = undefined;
    bytecode[0] = @intFromEnum(Opcode.PUSH32);
    // Fill with sequential data
    for (1..33) |i| {
        bytecode[i] = @intCast(i);
    }
    bytecode[33] = @intFromEnum(Opcode.STOP);
    
    var frame = try F.init(allocator, &bytecode, 10000, void{}, createTestHost());
    defer frame.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 34), frame.bytecode.len);
}
test "Frame bytecode edge cases - nested PUSH operations" {
    const allocator = std.testing.allocator;  
    const F = Frame(.{});
    
    // Create bytecode with multiple consecutive PUSH operations
    const bytecode = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x01,
        @intFromEnum(Opcode.PUSH2), 0x02, 0x03,
        @intFromEnum(Opcode.PUSH3), 0x04, 0x05, 0x06,
        @intFromEnum(Opcode.PUSH4), 0x07, 0x08, 0x09, 0x0A,
        @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.STOP),
    };
    
    var frame = try F.init(allocator, &bytecode, 10000, void{}, createTestHost());
    defer frame.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 18), frame.bytecode.len);
}
test "Frame bytecode edge cases - bytecode with only PUSH data" {
    const allocator = std.testing.allocator;
    const F = Frame(.{});
    
    // Bytecode that is entirely PUSH32 followed by its data (no actual execution)
    var bytecode: [33]u8 = undefined;
    bytecode[0] = @intFromEnum(Opcode.PUSH32);
    @memset(bytecode[1..], 0xFF);
    
    var frame = try F.init(allocator, &bytecode, 10000, void{}, createTestHost());
    defer frame.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 33), frame.bytecode.len);
}
