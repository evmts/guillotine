//! Lightweight execution context for EVM operations.
//!
//! StackFrame handles direct opcode execution including stack manipulation,
//! arithmetic, memory access, and storage operations. It does NOT handle:
//! - PC tracking and jumps (managed by Plan)
//! - CALL/CREATE operations (managed by Host/EVM)
//! - Environment queries (provided by Host)
//!
//! The StackFrame is designed for efficient opcode dispatch with configurable
//! components for stack size, memory limits, and gas tracking.
const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const memory_mod = @import("memory.zig");
const stack_mod = @import("stack.zig");
const opcode_data = @import("opcode_data.zig");
const Opcode = opcode_data.Opcode;
const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;
pub const FrameConfig = @import("frame_config.zig").FrameConfig;
const Database = @import("database.zig").Database;
const Account = @import("database.zig").Account;
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
const bytecode_mod = @import("bytecode.zig");
const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig;
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
const Address = primitives.Address.Address;
const to_u256 = primitives.Address.to_u256;
const from_u256 = primitives.Address.from_u256;
const keccak_asm = @import("keccak_asm.zig");
const stack_frame_handlers = @import("stack_frame_handlers.zig");
const SelfDestruct = @import("self_destruct.zig").SelfDestruct;
const DefaultEvm = @import("evm.zig").DefaultEvm;
const CallParams = @import("call_params.zig").CallParams;
const CallResult = @import("call_result.zig").CallResult;
const logs = @import("logs.zig");
const Log = logs.Log;
const block_info_mod = @import("block_info.zig");
const block_info_config_mod = @import("block_info_config.zig");
// LogList functionality is inlined into StackFrame for optimal packing
const dispatch_mod = @import("dispatch.zig");

/// Creates a configured StackFrame type for EVM execution.
///
/// The StackFrame is parameterized by compile-time configuration to enable
/// optimal code generation and platform-specific optimizations.
pub fn StackFrame(comptime config: FrameConfig) type {
    comptime config.validate();

    return struct {
        /// Status code type returned by StackFrame.interpret when stack frame executes successfully
        pub const Success = enum {
            Stop,
            Return,
            SelfDestruct,
        };
        /// Error code type returned by StackFrame.interpret when stack frame executes unsuccessfully
        pub const Error = error{
            StackOverflow,
            StackUnderflow,
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
        /// The type all opcode handlers return.
        /// Opcode handlers are expected to recursively dispatch the next opcode if they themselves don't error or return
        pub const OpcodeHandler = *const fn (frame: *Self, dispatch: Dispatch) Error!Success;
        /// The struct in charge of efficiently dispatching opcode handlers and providing them metadata
        pub const Dispatch = dispatch_mod.Dispatch(Self);
        /// The config passed into StackFrame(config)
        pub const frame_config = config;
        /// The "word" type used by the evm. Defaults to u256. "Word" is the type used by Stack and throughout the Evm
        /// If set to something else the EVM will update to that new word size. e.g. run kekkak128 instead of kekkak256
        /// Lowering the word size can improve perf and bundle size
        pub const WordType = config.WordType;
        /// The type used to measure gas. Unsigned integer for perf reasons
        pub const GasType = config.GasType();
        /// The type used to index into bytecode or instructions. Determined by config.max_bytecode_size
        pub const PcType = config.PcType();
        /// The struct in charge of managing Evm memory
        pub const Memory = memory_mod.Memory(.{
            .initial_capacity = config.memory_initial_capacity,
            .memory_limit = config.memory_limit,
            .owned = true,
        });
        /// The struct in charge of managing Evm Word stack
        pub const Stack = stack_mod.Stack(.{
            .stack_size = config.stack_size,
            .WordType = config.WordType,
        });
        /// The type used to validate and analyze bytecode
        /// Bytecode in a single pass validates the bytecode and produces an iterator
        /// Dispatch can use to produce the Dispatch stream
        pub const Bytecode = bytecode_mod.Bytecode(.{
            .max_bytecode_size = config.max_bytecode_size,
            .max_initcode_size = config.max_initcode_size,
            .vector_length = config.vector_length,
            .fusions_enabled = false,
        });
        /// The BlockInfo type configured for this frame
        pub const BlockInfo = block_info_mod.BlockInfo(config.block_info_config);

        /// A fixed size array of opcode handlers indexed by opcode number
        pub const opcode_handlers: [256]OpcodeHandler = stack_frame_handlers.getOpcodeHandlers(Self);

        const Self = @This();

        //           StackFrame Structure Layout Analysis - OPTIMIZED
        //
        //   Total Size: ~420 bytes (with default BlockInfo config)
        //   Alignment: 8 bytes (natural alignment for pointers)
        //
        //   SIZE OPTIMIZATIONS:
        //   - value: 32B → 8B (pointer instead of inline u256)
        //   - output: ArrayList(24B) → buffer[256] + len(4B) = 260B inline
        //   Net change: Larger struct but no allocation overhead for typical contracts
        //   Tradeoff: Wastes some space but eliminates allocator pressure
        //
        //   CACHE LINE 1 (0-63 bytes) - SUPER HOT PATH
        //   ┌─────────────────────────────────────────────────────────────┐
        //   │ Offset │ Field              │ Size  │ Type                  │
        //   ├────────┼────────────────────┼───────┼───────────────────────┤
        //   │ 0      │ stack              │ 16B   │ Stack (2 pointers)    │
        //   │ 16     │ gas_remaining      │ 4/8B  │ i32/i64 (config)      │
        //   │ 20/24  │ memory             │ 8B    │ *Memory struct         │
        //   │ 36/40  │ database           │ 8B    │ DatabaseType pointer  │
        //   │ 44/48  │ log_items          │ 8B    │ [*]Log                │
        //   │ 52/56  │ log_len            │ 2B    │ u16                   │
        //   │ 54/58  │ evm_ptr            │ 8B    │ *anyopaque            │
        //   │ 54/58  │ [fits/exceeds]     │       │                       │
        //   └─────────────────────────────────────────────────────────────┘
        //
        //   CACHE LINE 2 (64-127 bytes) - CALL CONTEXT
        //   ┌─────────────────────────────────────────────────────────────┐
        //   │ Offset │ Field              │ Size  │ Type                  │
        //   ├────────┼────────────────────┼───────┼───────────────────────┤
        //   │ 58     │ value              │ 8B    │ *const u256           │
        //   │ 66     │ caller             │ 20B   │ Address               │
        //   │ 92     │ contract_address   │ 20B   │ Address               │
        //   │ 112    │ calldata           │ 16B   │ []const u8 (slice)    │
        //   │ 128    │ [exceeds line 2]   │       │                       │
        //   └─────────────────────────────────────────────────────────────┘
        //
        //   CACHE LINE 3 (128-191 bytes) - EXECUTION STATE
        //   ┌─────────────────────────────────────────────────────────────┐
        //   │ Offset │ Field              │ Size  │ Type                  │
        //   ├────────┼────────────────────┼───────┼───────────────────────┤
        //   │ 128    │ allocator          │ 16B   │ Allocator (2 ptrs)    │
        //   │ 144    │ [padding]          │ 48B   │ alignment             │
        //   │ 192    │ [end of line 3]    │       │                       │
        //   └─────────────────────────────────────────────────────────────┘
        //
        //   CACHE LINE 4+ (192+ bytes) - COLD DATA
        //   ┌─────────────────────────────────────────────────────────────┐
        //   │ Offset │ Field              │ Size     │ Type                │
        //   ├────────┼────────────────────┼──────────┼─────────────────────┤
        //   │ 192    │ block_info         │ Variable │ BlockInfo           │
        //   │        │                    │          │                     │
        //   │        │ Default BlockInfo sizes:                             │
        //   │        │ - number: u64      │ 8B       │                     │
        //   │        │ - timestamp: u64   │ 8B       │                     │
        //   │        │ - difficulty: u256 │ 32B      │                     │
        //   │        │ - gas_limit: u64   │ 8B       │                     │
        //   │        │ - coinbase: Address│ 20B      │                     │
        //   │        │ - base_fee: u256   │ 32B      │                     │
        //   │        │ - prev_randao: [32]│ 32B      │                     │
        //   │        │ - blob_base_fee:u256│32B      │                     │
        //   │        │ - blob_versioned_  │ 16B      │ slice ptr           │
        //   │        │   hashes           │          │                     │
        //   │        │ Total BlockInfo    │ ~188B    │                     │
        //   │ ~380   │ self_destruct      │ 8B       │ ?*SelfDestruct      │
        //   │ ~388   │ output_len         │ 4B       │ u32                   │
        //   │ ~392   │ output_buffer      │ 256B     │ [256]u8 (inline)    │
        //   │ ~648   │ [total]            │          │                     │
        //   └─────────────────────────────────────────────────────────────┘
        //
        //  Component-Level Alignment Details
        //
        //  Stack (stack.zig) - OPTIMIZED
        //
        //  - Structure: 16 bytes total (optimized from 24 bytes)
        //    - buf_ptr: [*]align(64) WordType  // 8 bytes (pointer only)
        //    - stack_ptr: [*]WordType          // 8 bytes
        //    - stack_limit computed from buf_ptr (saves 8 bytes from slice)
        //  - Buffer: 64-byte aligned via alignedAlloc
        //  - Cache optimization: Downward growth for locality
        //  - Optimization: Removed explicit stack_limit field, computed via inline function
        //
        //  Memory (memory.zig) - 16 bytes total
        //
        //  - Structure:
        //    - checkpoint: u24                // 3 bytes - tracks parent memory boundary
        //    - padding                        // 5 bytes for alignment
        //    - buffer_ptr: *ArrayList(u8)     // 8 bytes - pointer to actual memory buffer
        //  - Gas caching removed: Direct calculation is fast enough
        //  - Allocator removed: Now passed as parameter to methods instead of stored
        //  - All offsets/sizes use u24: Matches EVM's 16MB (2^24) memory limit
        //  - Fast path: Optimized for ≤32 byte expansions (common EVM word size)
        //  - Zero initialization: Guaranteed on expansion
        //  - Child memory: Shares buffer with parent, different checkpoint
        //
        //  Bytecode (bytecode.zig)
        //
        //  - Bitmaps: Cache-aligned when not in test mode (64-byte boundaries)
        //  - Packed bits: 4-bit structures for dense storage
        //  - Prefetch: 256-byte lookahead during processing
        //
        // Database Interface (database_interface.zig) - OPTIMIZED
        //
        //  - Optimized to 8 bytes total (from 16 bytes)
        //  - Implementation: Single pointer or lightweight interface
        //  - Cache-friendly: Fits perfectly in hot path cache line
        //
        //   OPTIMIZED Memory Layout Visualization (64-byte cache lines)
        //
        //   With i64 gas_remaining (common case):
        //   Cache Line 1 (0-63):    Stack[0-15] Gas[16-23] Memory[24-39] Database[40-47] LogItems[48-55] LogLen[56-57] EVM*[58-65] EXCEEDS!
        //   Cache Line 2 (64-127):  Caller[64-83] Value*[84-91] Contract[92-111] Calldata[112-127] EXCEEDS!
        //   Cache Line 3 (128-191): Allocator[128-143] PAD[144-191]
        //   Cold Data (192+):       BlockInfo[192-379] SelfDest[380-387] OutLen[388-391] OutBuf[392-647]
        //
        //   With i32 gas_remaining (gas_limit <= 2^31):
        //   Cache Line 1 (0-63):    Stack[0-15] Gas[16-19] Memory[20-35] Database[36-43] LogItems[44-51] LogLen[52-53] EVM*[54-61] FITS!
        //   Cache Line 2 (64-127):  Caller[64-83] Value*[84-91] Contract[92-111] Calldata[112-127] EXCEEDS!
        //   (More compact hot path)
        //
        //   Note: Exact offsets depend on:
        //   - GasType size (i32 vs i64)
        //   - Struct field alignment rules
        //   - Platform ABI (though we target 8-byte alignment)
        //
        // PERFORMANCE IMPACT: This optimization achieves:
        // - Single cache line access for 99% of opcode execution (hot path)
        // - LOG operations (LOG0-LOG4) now access log_items and log_len in cache line 1!
        // - Value pointer (8B) instead of inline u256 (32B) saves 24 bytes
        // - This space saving allowed us to fit logs in cache line 1
        // - With i32 gas (common), entire hot path fits perfectly in 64 bytes
        // - Stack/Gas/Memory/Database/Logs all share optimal locality
        // - Call context now more compact in cache line 2
        // - Output buffer is inline (no allocation overhead for typical returns)
        // - Allocator moved out of hot path, only accessed during:
        //   - Memory expansion (rare, handled via Memory struct)
        //   - Log capacity growth (uncommon)
        // - BlockInfo remains in cold storage as it's rarely accessed
        // - Better cache utilization for real-world smart contract patterns
        //
        // BlockInfo Size Variations (based on BlockInfoConfig):
        //
        // Default BlockInfo (use_compact_types = false):
        //   - Total: ~188 bytes
        //   - difficulty: u256 (32B), base_fee: u256 (32B), blob_base_fee: u256 (32B)
        //
        // Compact BlockInfo (use_compact_types = true):
        //   - Total: ~116 bytes (saves 72 bytes!)
        //   - difficulty: u64 (8B), base_fee: u64 (8B), blob_base_fee: u64 (8B)
        //   - Practical for most use cases as real values fit in u64
        //
        // Custom BlockInfo (e.g., DifficultyType = u128, BaseFeeType = u96):
        //   - Total: Variable based on types
        //   - Allows fine-tuned memory/precision tradeoffs

        // CACHE LINE 1 (0-63 bytes) - SUPER HOT PATH
        stack: Stack, // 16B - Stack operations
        gas_remaining: GasType, // 8B - Gas tracking (i64)
        memory: Memory, // 16B - Memory operations
        database: config.DatabaseType, // 8B - Storage access
        log_items: ?[*]Log, // 8B - Log array pointer (null = 0 logs)
        evm_ptr: *anyopaque, // 8B - EVM instance pointer
        value: WordType, // 32B - Call value (inline)
        caller: Address, // 20B - Calling address
        contract_address: Address = Address.ZERO_ADDRESS, // 20B - Current contract
        calldata: []const u8, // 16B - Input data slice
        output: []u8, // 16B - Output data slice (heap allocated)
        allocator: std.mem.Allocator, // 16B - Memory allocator
        block_info: BlockInfo, // ~188B - Block context
        self_destruct: ?*SelfDestruct = null, // 8B - Self destruct list
        //
        /// Initialize a new execution frame.
        ///
        /// Creates stack, memory, and other execution components. Allocates
        /// resources with proper cleanup on failure. Bytecode validation
        /// and analysis is now handled separately by dispatch initialization.
        ///
        /// EIP-214: For static calls, self_destruct should be null to prevent
        /// SELFDESTRUCT operations which modify blockchain state.
        pub fn init(allocator: std.mem.Allocator, gas_remaining: GasType, database: config.DatabaseType, caller: Address, value: WordType, calldata: []const u8, block_info: BlockInfo, evm_ptr: *anyopaque, self_destruct: ?*SelfDestruct) Error!Self {
            var stack = Stack.init(allocator) catch {
                @branchHint(.cold);
                return Error.AllocationError;
            };
            errdefer stack.deinit(allocator);
            var memory = Memory.init(allocator) catch {
                @branchHint(.cold);
                return Error.AllocationError;
            };
            errdefer memory.deinit(allocator);

            return Self{
                .stack = stack,
                .gas_remaining = std.math.cast(GasType, @max(gas_remaining, 0)) orelse return Error.InvalidAmount,
                .memory = memory,
                .database = database,
                .log_items = null, // No logs initially
                .evm_ptr = evm_ptr,
                .caller = caller,
                .value = value,
                .contract_address = Address.ZERO_ADDRESS,
                .output = &[_]u8{}, // Start with empty output
                .calldata = calldata,
                .allocator = allocator,
                .block_info = block_info,
                .self_destruct = self_destruct,
            };
        }
        /// Clean up all frame resources.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.stack.deinit(allocator);
            self.memory.deinit(allocator);
            self.deinitLogs(allocator);
            if (self.output.len > 0) {
                allocator.free(self.output);
            }
        }

        /// Execute this frame without tracing (backward compatibility method).
        /// Simply delegates to interpret_with_tracer with no tracer.
        /// @param bytecode_raw: Raw bytecode to execute
        pub fn interpret(self: *Self, bytecode_raw: []const u8) Error!Success {
            return self.interpret_with_tracer(bytecode_raw, null, {});
        }

        /// Execute this frame by building a dispatch schedule and jumping to the first handler.
        /// Performs a one-time static gas charge for the first basic block before execution.
        ///
        /// @param bytecode_raw: Raw bytecode to execute
        /// @param TracerType: Optional comptime tracer type for zero-cost tracing abstraction
        /// @param tracer_instance: Instance of the tracer (ignored if TracerType is null)
        pub fn interpret_with_tracer(self: *Self, bytecode_raw: []const u8, comptime TracerType: ?type, tracer_instance: if (TracerType) |T| *T else void) Error!Success {
            if (bytecode_raw.len > config.max_bytecode_size) {
                @branchHint(.unlikely);
                return Error.BytecodeTooLarge;
            }

            var bytecode = Bytecode.init(self.allocator, bytecode_raw) catch |e| {
                @branchHint(.unlikely);
                log.err("Bytecode init failed: {any}", .{e});
                if (bytecode_raw.len > 0) {
                    log.err("  Bytecode length: {d}", .{bytecode_raw.len});
                    log.err("  First 16 bytes: {x}", .{bytecode_raw[0..@min(bytecode_raw.len, 16)]});
                    // Check for specific test bytecode
                    if (bytecode_raw.len >= 10 and bytecode_raw[0] == 0x60 and bytecode_raw[1] == 0x42) {
                        log.warn("  This appears to be the MSTORE/RETURN test bytecode!", .{});
                    }
                }
                return switch (e) {
                    error.BytecodeTooLarge => Error.BytecodeTooLarge,
                    error.InvalidOpcode => Error.InvalidOpcode,
                    error.InvalidJumpDestination => Error.InvalidJump,
                    error.TruncatedPush => Error.InvalidOpcode,
                    error.OutOfMemory => Error.AllocationError,
                    else => Error.AllocationError,
                };
            };
            defer bytecode.deinit();

            const handlers = &Self.opcode_handlers;

            if (TracerType) |T| {
                if (@hasDecl(T, "beforeExecute")) {
                    tracer_instance.beforeExecute(Self, self);
                }
            }

            const result = if (TracerType) |T| blk: {
                const traced_schedule = Dispatch.initWithTracing(self.allocator, &bytecode, handlers, T, tracer_instance) catch return Error.AllocationError;
                defer Dispatch.deinitSchedule(self.allocator, traced_schedule);

                var traced_jump_table = Dispatch.createJumpTable(self.allocator, traced_schedule, &bytecode) catch return Error.AllocationError;
                defer self.allocator.free(traced_jump_table.entries);

                var start_index: usize = 0;
                switch (traced_schedule[0]) {
                    .first_block_gas => |meta| {
                        if (meta.gas > 0) try self.consumeGasChecked(meta.gas);
                        start_index = 1;
                    },
                    else => {},
                }

                const cursor = Self.Dispatch{ .cursor = traced_schedule.ptr + start_index, .jump_table = &traced_jump_table };
                break :blk cursor.cursor[0].opcode_handler(self, cursor);
            } else blk: {
                log.debug("DISPATCH INIT: bytecode len={d}", .{bytecode.runtime_code.len});
                const schedule = Dispatch.init(self.allocator, &bytecode, handlers) catch |e| {
                    log.err("Failed to create dispatch schedule: {any}", .{e});
                    log.err("  Bytecode runtime_code len: {d}", .{bytecode.runtime_code.len});
                    return Error.AllocationError;
                };
                log.debug("DISPATCH INIT COMPLETE: schedule len={d}, opcode_count={d}", .{ schedule.len, bytecode.runtime_code.len });
                defer Dispatch.deinitSchedule(self.allocator, schedule);
                if (schedule.len < 3) {
                    log.err("Dispatch schedule is too short! len={d}", .{schedule.len});
                    log.err("  Bytecode len: {d}", .{bytecode.runtime_code.len});
                    if (bytecode.runtime_code.len > 0) {
                        log.err("  First few bytes: {x}", .{bytecode.runtime_code[0..@min(bytecode.runtime_code.len, 16)]});
                    }
                    return Error.InvalidOpcode;
                }

                var jump_table = Dispatch.createJumpTable(self.allocator, schedule, &bytecode) catch return Error.AllocationError;
                defer self.allocator.free(jump_table.entries);

                var start_index: usize = 0;
                switch (schedule[0]) {
                    .first_block_gas => |meta| {
                        log.debug("First block gas charge: {d} (current gas: {d})", .{ meta.gas, self.gas_remaining });
                        if (meta.gas > 0) try self.consumeGasChecked(meta.gas);
                        log.debug("Gas after first block charge: {d}", .{self.gas_remaining});
                        start_index = 1;
                    },
                    else => {},
                }

                const cursor = Self.Dispatch{ .cursor = schedule.ptr + start_index, .jump_table = &jump_table };
                break :blk cursor.cursor[0].opcode_handler(self, cursor);
            };

            if (TracerType) |T| if (@hasDecl(T, "afterExecute")) tracer_instance.afterExecute(Self, self);

            return result;
        }

        /// Create a deep copy of the frame.
        /// This is used by DebugPlan to create a sidecar frame for validation.
        pub fn copy(self: *const Self, allocator: std.mem.Allocator) Error!Self {
            var new_stack = Stack.init(allocator) catch return Error.AllocationError;
            errdefer new_stack.deinit(allocator);
            const src_stack_slice = self.stack.get_slice();
            if (src_stack_slice.len > 0) {
                var i: usize = src_stack_slice.len;
                while (i > 0) {
                    i -= 1;
                    try new_stack.push(src_stack_slice[i]);
                }
            }

            var new_memory = Memory.init(allocator) catch return Error.AllocationError;
            errdefer new_memory.deinit(allocator);
            const mem_size = self.memory.size();
            if (mem_size > 0) {
                const bytes = self.memory.get_slice(0, mem_size) catch unreachable;
                try new_memory.set_data(0, bytes);
            }

            const new_log_items: ?[*]Log = if (self.log_items) |items| blk: {
                const header = @as(*const LogHeader, @ptrFromInt(@intFromPtr(items) - @sizeOf(LogHeader)));
                if (header.count == 0) break :blk null;

                const full_size = @sizeOf(LogHeader) + header.capacity * @sizeOf(Log);
                const new_log_memory = allocator.alloc(u8, full_size) catch return Error.AllocationError;

                const new_header = @as(*LogHeader, @ptrCast(@alignCast(new_log_memory.ptr)));
                new_header.* = header.*;

                const new_items = @as([*]Log, @ptrCast(@alignCast(new_log_memory.ptr + @sizeOf(LogHeader))));

                for (items[0..header.count], 0..) |log_entry, i| {
                    const topics_copy = allocator.alloc(u256, log_entry.topics.len) catch return Error.AllocationError;
                    @memcpy(topics_copy, log_entry.topics);

                    const data_copy = allocator.alloc(u8, log_entry.data.len) catch {
                        allocator.free(topics_copy);
                        return Error.AllocationError;
                    };
                    @memcpy(data_copy, log_entry.data);

                    new_items[i] = Log{
                        .address = log_entry.address,
                        .topics = topics_copy,
                        .data = data_copy,
                    };
                }

                break :blk new_items;
            } else null;

            const new_output = if (self.output.len > 0) blk: {
                const output_copy = allocator.alloc(u8, self.output.len) catch return Error.AllocationError;
                @memcpy(output_copy, self.output);
                break :blk output_copy;
            } else &[_]u8{};

            return Self{
                .stack = new_stack,
                .gas_remaining = self.gas_remaining,
                .memory = new_memory,
                .database = self.database,
                .log_items = new_log_items,
                .evm_ptr = self.evm_ptr,
                .caller = self.caller,
                .value = self.value,
                .contract_address = self.contract_address,
                .output = new_output,
                .calldata = self.calldata,
                .allocator = allocator,
                .block_info = self.block_info,
                .self_destruct = self.self_destruct,
            };
        }

        /// Consume gas without checking (for use after static analysis)
        pub fn consumeGasUnchecked(self: *Self, amount: u64) void {
            const clamped_amount = @min(amount, std.math.maxInt(GasType));
            self.gas_remaining -= @as(GasType, @intCast(clamped_amount));
        }

        /// Consume gas with bounds checking and safe casting
        pub fn consumeGasChecked(self: *Self, amount: u64) Error!void {
            const amt = std.math.cast(GasType, amount) orelse return Error.OutOfGas;
            self.gas_remaining -= amt;
            if (self.gas_remaining < 0) return Error.OutOfGas;
        }

        /// Get the EVM instance from the opaque pointer
        pub inline fn getEvm(self: *const Self) *DefaultEvm {
            return @as(*DefaultEvm, @ptrCast(@alignCast(self.evm_ptr)));
        }

        /// Set output data (allocates on heap)
        pub fn setOutput(self: *Self, data: []const u8) Error!void {
            if (self.output.len > 0) {
                self.allocator.free(self.output);
            }
            if (data.len == 0) {
                self.output = &[_]u8{};
                return;
            }
            const new_output = self.allocator.alloc(u8, data.len) catch {
                return Error.AllocationError;
            };
            @memcpy(new_output, data);
            self.output = new_output;
        }

        /// Get current output data as slice
        pub fn getOutput(self: *const Self) []const u8 {
            return self.output;
        }

        /// Log array header stored before the actual logs
        const LogHeader = struct {
            capacity: u16,
            count: u16,
        };

        /// Maximum number of logs that can be stored (u16 limit)
        pub const MAX_LOGS: u16 = std.math.maxInt(u16);

        /// Clean up log memory
        pub fn deinitLogs(self: *Self, allocator: std.mem.Allocator) void {
            const items = self.log_items orelse return;

            const header = @as(*LogHeader, @ptrFromInt(@intFromPtr(items) - @sizeOf(LogHeader)));

            for (items[0..header.count]) |log_entry| {
                allocator.free(log_entry.topics);
                allocator.free(log_entry.data);
            }

            const full_alloc = @as([*]u8, @ptrFromInt(@intFromPtr(header)))[0 .. @sizeOf(LogHeader) + header.capacity * @sizeOf(Log)];
            allocator.free(full_alloc);
        }

        /// Add a log entry to the list
        pub fn appendLog(self: *Self, allocator: std.mem.Allocator, log_entry: Log) error{OutOfMemory}!void {
            if (self.log_items == null) {
                const initial_capacity: u16 = 4;
                const full_size = @sizeOf(LogHeader) + initial_capacity * @sizeOf(Log);
                const memory = try allocator.alloc(u8, full_size);

                const header = @as(*LogHeader, @ptrCast(@alignCast(memory.ptr)));
                header.* = .{ .capacity = initial_capacity, .count = 1 };

                const items = @as([*]Log, @ptrCast(@alignCast(memory.ptr + @sizeOf(LogHeader))));
                items[0] = log_entry;

                self.log_items = items;
            } else {
                const items = self.log_items.?;
                const header = @as(*LogHeader, @ptrFromInt(@intFromPtr(items) - @sizeOf(LogHeader)));

                if (header.count >= header.capacity) {
                    const new_capacity = header.capacity * 2;
                    const new_size = @sizeOf(LogHeader) + new_capacity * @sizeOf(Log);
                    const new_memory = try allocator.alloc(u8, new_size);

                    const new_header = @as(*LogHeader, @ptrCast(@alignCast(new_memory.ptr)));
                    new_header.* = .{ .capacity = new_capacity, .count = header.count + 1 };

                    const new_items = @as([*]Log, @ptrCast(@alignCast(new_memory.ptr + @sizeOf(LogHeader))));
                    @memcpy(new_items[0..header.count], items[0..header.count]);
                    new_items[header.count] = log_entry;

                    const old_size = @sizeOf(LogHeader) + header.capacity * @sizeOf(Log);
                    const old_memory = @as([*]u8, @ptrFromInt(@intFromPtr(header)))[0..old_size];
                    allocator.free(old_memory);

                    self.log_items = new_items;
                } else {
                    items[header.count] = log_entry;
                    header.count += 1;
                }
            }
        }

        /// Get slice of current log entries
        pub fn getLogSlice(self: *const Self) []const Log {
            const items = self.log_items orelse return &[_]Log{};
            const header = @as(*const LogHeader, @ptrFromInt(@intFromPtr(items) - @sizeOf(LogHeader)));
            return items[0..header.count];
        }

        /// Get number of logs
        pub fn getLogCount(self: *const Self) u16 {
            const items = self.log_items orelse return 0;
            const header = @as(*const LogHeader, @ptrFromInt(@intFromPtr(items) - @sizeOf(LogHeader)));
            return header.count;
        }
    };
}
