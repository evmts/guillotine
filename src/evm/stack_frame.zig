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
const DatabaseInterface = @import("database_interface.zig").DatabaseInterface;
const Account = @import("database_interface.zig").Account;
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
const Host = @import("host.zig").Host;
const CallParams = @import("call_params.zig").CallParams;
const CallResult = @import("call_result.zig").CallResult;
const logs = @import("logs.zig");
const Log = logs.Log;
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

        /// A fixed size array of opcode handlers indexed by opcode number
        pub const opcode_handlers: [256]OpcodeHandler = stack_frame_handlers.getOpcodeHandlers(Self);

        pub const max_bytecode_size = config.max_bytecode_size;

        const Self = @This();

        //           StackFrame Structure Layout Analysis
        //   Primary Components (Cacheline 1 - Hot Path)
        //
        //   Offset 0-63: Primary cacheline (64 bytes)
        //   ├── stack: Stack                    // 24 bytes (slice: ptr + len = 16 bytes, stack_ptr = 8 bytes)
        //   ├── gas_remaining: GasType          // 4-8 bytes (i32/i64 based on config)
        //   └── memory: Memory (partial)        // ~32 bytes of 44 total
        // 
        //   Secondary Components (Cacheline 2)
        // 
        //   Offset 64-127: Execution context
        //   ├── memory: Memory (continued)      // remaining 12 bytes of 44 total
        //   ├── database: DatabaseInterface     // 0 or 16 bytes (ptr + vtable)
        //   └── contract_address: Address       // 20 bytes
        // 
        //   Tertiary Components (Cacheline 3+)
        // 
        //   Offset 128+: Cold data
        //   ├── host: Host                      // size varies
        //   ├── logs: ArrayList(Log)            // 24 bytes
        //   ├── output_data: ArrayList(u8)      // 24 bytes
        //   ├── self_destruct: ?*SelfDestruct   // 8 bytes
        //   └── allocator: Allocator            // 16 bytes
        // 
        //  Component-Level Alignment Details
        //
        //  Stack (stack.zig) - OPTIMIZED
        //
        //  - Structure: 24 bytes total (previously 32 bytes)
        //    - buf: []align(64) WordType      // 16 bytes (ptr + len)
        //    - stack_ptr: [*]WordType          // 8 bytes
        //    - stack_limit computed from buf.ptr (saves 8 bytes)
        //  - Buffer: 64-byte aligned via alignedAlloc
        //  - Cache optimization: Downward growth for locality
        //  - Optimization: Removed explicit stack_limit field, computed via inline function
        //
        //  Memory (memory.zig) - 44 bytes total
        //
        //  - Structure:
        //    - checkpoint: usize              // 8 bytes - tracks parent memory boundary
        //    - buffer_ptr: *ArrayList(u8)     // 8 bytes - pointer to actual memory buffer
        //    - allocator: std.mem.Allocator   // 16 bytes - allocator for memory operations
        //    - cached_expansion: packed struct // 12 bytes - gas cost cache
        //      - last_size: u32   (4 bytes)
        //      - last_words: u32  (4 bytes)  
        //      - last_cost: u64   (8 bytes)
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
        // Database Interface (database_interface.zig)
        //
        //  - VTable: Function pointer alignment (8 bytes)
        //  - Implementation ptr: 8-byte aligned void pointer
        //
        //   Memory Layout Visualization
        // 
        // Cache Line 1 (0-63):    [Stack(24)][Gas][Memory(start)]
        // Cache Line 2 (64-127):  [Memory(cont)][Database][Address]
        // Cache Line 3 (128-191): [Host][Logs][Output][SelfDest*][Alloc]
        // Note: Tracer is not stored in the struct - it's a compile-time parameter
        stack: Stack,
        gas_remaining: GasType, 
        memory: Memory,
        database: if (config.has_database) ?DatabaseInterface else void,
        contract_address: Address = Address.ZERO_ADDRESS,
        host: Host,
        logs: std.ArrayList(Log),
        output_data: std.ArrayList(u8),
        self_destruct: ?*SelfDestruct = null,
        allocator: std.mem.Allocator,
        /// Initialize a new execution frame.
        ///
        /// Creates stack, memory, and other execution components. Allocates 
        /// resources with proper cleanup on failure. Bytecode validation
        /// and analysis is now handled separately by dispatch initialization.
        /// 
        /// EIP-214: For static calls, self_destruct should be null to prevent 
        /// SELFDESTRUCT operations which modify blockchain state.
        pub fn init(allocator: std.mem.Allocator, gas_remaining: GasType, database: if (config.has_database) ?DatabaseInterface else void, host: Host, self_destruct: ?*SelfDestruct) Error!Self {

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
            var frame_logs = std.ArrayList(Log){};
            errdefer frame_logs.deinit(allocator);
            var output_data = std.ArrayList(u8){};
            errdefer output_data.deinit();
            return Self{
                .stack = stack,
                .gas_remaining = @as(GasType, @intCast(@max(gas_remaining, 0))),
                .memory = memory,
                .database = database,
                .logs = frame_logs,
                .output_data = output_data,
                .host = host,
                .self_destruct = self_destruct,
                .allocator = allocator,
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
            self.logs.deinit(allocator);
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
            if (bytecode_raw.len > max_bytecode_size) {
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

            var new_logs = std.ArrayList(Log){};
            errdefer new_logs.deinit(allocator);
            for (self.logs.items) |log_entry| {
                const topics_copy = allocator.alloc(u256, log_entry.topics.len) catch return Error.AllocationError;
                @memcpy(topics_copy, log_entry.topics);
                const data_copy = allocator.alloc(u8, log_entry.data.len) catch {
                    allocator.free(topics_copy);
                    return Error.AllocationError;
                };
                @memcpy(data_copy, log_entry.data);
                new_logs.append(allocator, Log{
                    .address = log_entry.address,
                    .topics = topics_copy,
                    .data = data_copy,
                }) catch {
                    allocator.free(topics_copy);
                    allocator.free(data_copy);
                    return Error.AllocationError;
                };
            }

            var new_output_data = std.ArrayList(u8){};
            errdefer new_output_data.deinit(allocator);
            new_output_data.appendSlice(allocator, self.output_data.items) catch return Error.AllocationError;

            return Self{
                .stack = new_stack,
                .gas_remaining = self.gas_remaining,
                .memory = new_memory,
                .database = self.database,
                .contract_address = self.contract_address,
                .self_destruct = self.self_destruct,
                .logs = new_logs,
                .output_data = new_output_data,
                .host = self.host,
                .allocator = allocator,
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
    };
}
