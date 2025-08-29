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

        //           StackFrame Structure Layout Analysis
        //
        //   Total Size: ~104-120 bytes (optimized from ~120-136 bytes, varies by config.has_database)
        //   Alignment: 8 bytes (pointer alignment)
        //
        //   OPTIMIZED: Cache Line 1 (0-63) - Hot Path - Call data prioritized
        //
        //   All frequently accessed components during opcode execution:
        //   ├── stack: Stack                    // 16 bytes (optimized: buf_ptr + stack_ptr)
        //   ├── gas_remaining: GasType          // 8 bytes (i64 for performance)
        //   ├── memory: Memory                  // 16 bytes
        //   ├── database: DatabaseInterface     // 8 bytes (optimized from 16 bytes)
        //   ├── caller: Address                 // 20 bytes (call context)
        //   ├── value: WordType                 // 32 bytes (call value)
        //   ├── calldata: []const u8            // 16 bytes (slice)
        //   ├── block_info: BlockInfo           // ~variable bytes (cold data)
        //   Total: Hot path optimized with context prioritized over host access
        // 
        //   Cache Line 2+ - Execution State & Memory Management
        // 
        //   ├── contract_address: Address       // 20 bytes (complete, atomic access)
        //   ├── log_items: [*]Log               // 8 bytes (many-item pointer)
        //   ├── log_len: u16                    // 2 bytes (optimized log count)
        //   ├── allocator: Allocator            // 16 bytes (memory management)
        //   ├── output_data: ArrayList(u8)      // 24 bytes
        // 
        //   Cold Data - Rarely accessed during normal execution
        // 
        //   ├── evm_ptr: *anyopaque             // 8 bytes (only for system calls/destruction)
        //   ├── self_destruct: ?*SelfDestruct   // 8 bytes (cold data for selfdestruct)
        //   └── [other cold fields]             // varies
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
        //   OPTIMIZED Memory Layout Visualization
        // 
        // Cache Line 1 (0-63):   [Stack(16)][Gas(8)][Memory(16)][Database(8)][Allocator(16)] = 64 bytes
        // Cache Line 2 (64-127): [EVM*(8)][Caller(20)][Value(32)][LogItems(8)][LogLen(2)] = 70 bytes (6B padding)
        // Cache Line 3 (128-191):[Contract(20)][Calldata(16)][Output(24)] = 60 bytes (4B padding)
        // Cache Line 4+ (192+):  [BlockInfo(~188)][SelfDest*(8)] = Cold data
        // Note: Tracer is not stored in the struct - it's a compile-time parameter
        //
        // PERFORMANCE IMPACT: This optimization achieves:
        // - Single cache line access for 99% of opcode execution (hot path)
        // - Log operations (LOG0-LOG4) access log_items and log_len atomically in cache line 2
        // - Perfect cache alignment eliminates cache line splits
        // - Stack/Gas/Memory/Database/Allocator share optimal locality in cache line 1
        // - Call context (caller/value) and log data co-located for CALL/LOG operations
        // - BlockInfo moved to cold storage as it's rarely accessed during execution
        // - Inlined log storage saves 14 bytes vs LogList struct ([]Log+u16 = 24 -> [*]Log+u16 = 10)
        // - 6 bytes padding available in cache line 2 for future optimizations
        // - 4 bytes padding available in cache line 3 for future optimizations
        
        // HOT PATH - Cache Line 1 (Most frequently accessed)
        stack: Stack,
        gas_remaining: GasType, 
        memory: Memory,
        database: config.DatabaseType,
        allocator: std.mem.Allocator,
        
        // CALL CONTEXT & LOGS - Cache Line 2 
        evm_ptr: *anyopaque,
        caller: Address,
        value: WordType,
        log_items: [*]Log,
        log_len: u16,
        
        // EXECUTION STATE - Cache Line 3
        contract_address: Address = Address.ZERO_ADDRESS,
        calldata: []const u8,
        output_data: std.ArrayList(u8),
        
        // COLD DATA - Cache Line 4+
        block_info: BlockInfo,
        self_destruct: ?*SelfDestruct = null,
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
            errdefer memory.deinit();
            // Initialize empty log storage
            const empty_logs = [_]Log{};
            const frame_log_items: [*]Log = @as([*]Log, @ptrFromInt(@intFromPtr(&empty_logs)));
            const frame_log_len: u16 = 0;
            var output_data = std.ArrayList(u8){};
            errdefer output_data.deinit();
            return Self{
                .stack = stack,
                .gas_remaining = @as(GasType, @intCast(@max(gas_remaining, 0))),
                .memory = memory,
                .database = database,
                .allocator = allocator,
                .evm_ptr = evm_ptr,
                .caller = caller,
                .value = value,
                .log_items = frame_log_items,
                .log_len = frame_log_len,
                .calldata = calldata,
                .output_data = output_data,
                .block_info = block_info,
                .self_destruct = self_destruct,
            };
        }
        /// Clean up all frame resources.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.stack.deinit(allocator);
            self.memory.deinit(allocator);
            self.deinitLogs(allocator);
            self.output_data.deinit(allocator);
        }

        /// Execute this frame without tracing (backward compatibility method).
        /// Simply delegates to interpret_with_tracer with no tracer.
        /// @param bytecode_raw: Raw bytecode to execute
        pub fn interpret(self: *Self, bytecode_raw: []const u8) Error!Success {
            log.debug("StackFrame.interpret called, bytecode len: {}", .{bytecode_raw.len});
            return self.interpret_with_tracer(bytecode_raw, null, {});
        }
        
        /// Execute this frame by building a dispatch schedule and jumping to the first handler.
        /// Performs a one-time static gas charge for the first basic block before execution.
        /// 
        /// @param bytecode_raw: Raw bytecode to execute
        /// @param TracerType: Optional comptime tracer type for zero-cost tracing abstraction
        /// @param tracer_instance: Instance of the tracer (ignored if TracerType is null)
        pub fn interpret_with_tracer(self: *Self, bytecode_raw: []const u8, comptime TracerType: ?type, tracer_instance: if (TracerType) |T| *T else void) Error!Success {
            // Validate bytecode size
            if (bytecode_raw.len > config.max_bytecode_size) {
                @branchHint(.unlikely);
                return Error.BytecodeTooLarge;
            }

            log.debug("Initializing bytecode with len: {}", .{bytecode_raw.len});
            var bytecode = Bytecode.init(self.allocator, bytecode_raw) catch |e| {
                @branchHint(.unlikely);
                log.err("Bytecode init failed: {}", .{e});
                return switch (e) {
                    error.BytecodeTooLarge => Error.BytecodeTooLarge,
                    error.InvalidOpcode => Error.InvalidOpcode,
                    error.OutOfMemory => Error.AllocationError,
                    else => Error.AllocationError,
                };
            };
            defer bytecode.deinit();
            
            const handlers = &Self.opcode_handlers;
            log.debug("interpret_with_tracer called, bytecode len: {}, gas: {}", .{bytecode.runtime_code.len, self.gas_remaining});

            // Call beforeExecute hook if tracer is configured
            if (TracerType) |T| {
                if (@hasDecl(T, "beforeExecute")) {
                    tracer_instance.beforeExecute(Self, self);
                }
            }

            // Execute the bytecode
            const result = if (TracerType) |T| blk: {
                // When tracing is enabled, use the traced dispatch schedule
                const traced_schedule = Dispatch.initWithTracing(self.allocator, &bytecode, handlers, T, tracer_instance) catch return Error.AllocationError;
                defer Dispatch.deinitSchedule(self.allocator, traced_schedule);
                
                // Create jump table for traced schedule
                var traced_jump_table = Dispatch.createJumpTable(self.allocator, traced_schedule, &bytecode) catch return Error.AllocationError;
                defer self.allocator.free(traced_jump_table.entries);
                
                // Process first block gas if needed
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
                // Normal execution without tracing
                log.debug("Creating dispatch schedule...", .{});
                const schedule = Dispatch.init(self.allocator, &bytecode, handlers) catch |e| {
                    log.err("Failed to create dispatch schedule: {}", .{e});
                    return Error.AllocationError;
                };
                defer Dispatch.deinitSchedule(self.allocator, schedule);
                log.debug("Dispatch schedule created, len: {}", .{schedule.len});
                if (schedule.len < 3) {
                    log.err("Dispatch schedule is too short! len={}", .{schedule.len});
                    log.err("  Bytecode len: {}", .{bytecode.runtime_code.len});
                    if (bytecode.runtime_code.len > 0) {
                        log.err("  First few bytes: {x}", .{bytecode.runtime_code[0..@min(bytecode.runtime_code.len, 16)]});
                    }
                    return Error.InvalidOpcode;
                }

                var jump_table = Dispatch.createJumpTable(self.allocator, schedule, &bytecode) catch return Error.AllocationError;
                defer self.allocator.free(jump_table.entries);

                // Process first block gas
                var start_index: usize = 0;
                switch (schedule[0]) {
                    .first_block_gas => |meta| {
                        log.debug("First block gas: {}", .{meta.gas});
                        if (meta.gas > 0) try self.consumeGasChecked(meta.gas);
                        start_index = 1;
                    },
                    else => {},
                }
                
                const cursor = Self.Dispatch{ .cursor = schedule.ptr + start_index, .jump_table = &jump_table };
                log.debug("Executing first opcode handler...", .{});
                break :blk cursor.cursor[0].opcode_handler(self, cursor);
            };
            
            log.debug("Execution result: {any}, output size: {}", .{result, self.output_data.items.len});
            
            // Call afterExecute hook if tracer is configured
            if (TracerType) |T| {
                if (@hasDecl(T, "afterExecute")) {
                    tracer_instance.afterExecute(Self, self);
                }
            }
            
            return result;
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
            const new_log_items: [*]Log = if (self.log_len > 0) blk: {
                // Compute capacity for allocation
                const capacity = blk2: {
                    var cap: usize = 8;
                    while (cap < self.log_len) cap *= 2;
                    break :blk2 @min(cap, MAX_LOGS);
                };
                const items = allocator.alloc(Log, capacity) catch return Error.AllocationError;
                for (self.log_items[0..self.log_len], 0..) |log_entry, i| {
                    const topics_copy = allocator.alloc(u256, log_entry.topics.len) catch return Error.AllocationError;
                    @memcpy(topics_copy, log_entry.topics);
                    const data_copy = allocator.alloc(u8, log_entry.data.len) catch {
                        allocator.free(topics_copy);
                        return Error.AllocationError;
                    };
                    @memcpy(data_copy, log_entry.data);
                    items[i] = Log{
                        .address = log_entry.address,
                        .topics = topics_copy,
                        .data = data_copy,
                    };
                }
                break :blk items.ptr;
            } else blk: {
                const empty_logs = [_]Log{};
                break :blk @as([*]Log, @ptrFromInt(@intFromPtr(&empty_logs)));
            };

            var new_output_data = std.ArrayList(u8){};
            errdefer new_output_data.deinit(allocator);
            new_output_data.appendSlice(allocator, self.output_data.items) catch return Error.AllocationError;

            return Self{
                .stack = new_stack,
                .gas_remaining = self.gas_remaining,
                .memory = new_memory,
                .database = self.database,
                .allocator = allocator,
                .evm_ptr = self.evm_ptr,
                .caller = self.caller,
                .value = self.value,
                .log_items = new_log_items,
                .log_len = self.log_len,
                .contract_address = self.contract_address,
                .calldata = self.calldata,
                .output_data = new_output_data,
                .block_info = self.block_info,
                .self_destruct = self.self_destruct,
            };
        }

        /// Consume gas without checking (for use after static analysis)
        pub fn consumeGasUnchecked(self: *Self, amount: u64) void {
            self.gas_remaining -= @as(GasType, @intCast(amount));
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

        // === Inlined LogList Methods ===

        /// Maximum number of logs that can be stored (u16 limit)
        pub const MAX_LOGS: u16 = std.math.maxInt(u16);

        /// Clean up log memory
        pub fn deinitLogs(self: *Self, allocator: std.mem.Allocator) void {
            // Free individual log data
            for (self.log_items[0..self.log_len]) |log_entry| {
                allocator.free(log_entry.topics);
                allocator.free(log_entry.data);
            }
            // Free items array if we allocated it
            if (self.log_len > 0) {
                // We need to know the capacity to free, but we don't store it
                // For now, we'll track it via the actual allocation size
                const capacity = if (self.log_len <= 8) @as(usize, 8) else blk: {
                    var cap: usize = 8;
                    while (cap < self.log_len) cap *= 2;
                    break :blk @min(cap, MAX_LOGS);
                };
                const slice_to_free = self.log_items[0..capacity];
                allocator.free(slice_to_free);
            }
        }

        /// Add a log entry to the list
        pub fn appendLog(self: *Self, allocator: std.mem.Allocator, log_entry: Log) error{OutOfMemory}!void {
            if (self.log_len >= MAX_LOGS) {
                @branchHint(.cold);
                return error.OutOfMemory; // Too many logs
            }

            // Check if we need to grow (compute current capacity)
            const current_capacity = if (self.log_len == 0) @as(usize, 0) else blk: {
                var cap: usize = 8;
                while (cap < self.log_len) cap *= 2;
                break :blk @min(cap, MAX_LOGS);
            };

            if (self.log_len >= current_capacity) {
                try self.growLogs(allocator);
            }

            self.log_items[self.log_len] = log_entry;
            self.log_len += 1;
        }

        /// Get slice of current log entries
        pub fn getLogSlice(self: *const Self) []const Log {
            if (self.log_len == 0) return &[_]Log{};
            return self.log_items[0..self.log_len];
        }

        /// Get number of logs
        pub fn getLogCount(self: *const Self) u16 {
            return self.log_len;
        }

        /// Grow the capacity of the log list
        fn growLogs(self: *Self, allocator: std.mem.Allocator) error{OutOfMemory}!void {
            const current_capacity = if (self.log_len == 0) @as(usize, 0) else blk: {
                var cap: usize = 8;
                while (cap < self.log_len) cap *= 2;
                break :blk @min(cap, MAX_LOGS);
            };
            
            const new_capacity: u16 = if (current_capacity == 0) 
                8 // Start with 8 logs
            else 
                @min(@as(u16, @intCast(current_capacity)) * 2, MAX_LOGS); // Double capacity up to max

            if (new_capacity <= current_capacity) {
                @branchHint(.cold);
                return error.OutOfMemory; // Can't grow anymore
            }

            const new_items = allocator.alloc(Log, new_capacity) catch {
                @branchHint(.cold);
                return error.OutOfMemory;
            };

            // Copy existing items
            if (self.log_len > 0) {
                @memcpy(new_items[0..self.log_len], self.log_items[0..self.log_len]);
                // Free old items
                const old_slice = self.log_items[0..current_capacity];
                allocator.free(old_slice);
            }

            self.log_items = new_items.ptr;
        }
    };
}
