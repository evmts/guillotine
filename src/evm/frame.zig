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
const frame_handlers = @import("frame_handlers.zig");
const SelfDestruct = @import("self_destruct.zig").SelfDestruct;
const DefaultEvm = @import("evm.zig").DefaultEvm;
const CallParams = @import("call_params.zig").CallParams;
const CallResult = @import("call_result.zig").CallResult;
const logs = @import("logs.zig");
const Log = logs.Log;
const block_info_mod = @import("block_info.zig");
const block_info_config_mod = @import("block_info_config.zig");
// LogList functionality is inlined into Frame for optimal packing
const dispatch_mod = @import("dispatch.zig");

/// Creates a configured Frame type for EVM execution.
///
/// The Frame is parameterized by compile-time configuration to enable
/// optimal code generation and platform-specific optimizations.
pub fn Frame(comptime config: FrameConfig) type {
    comptime config.validate();

    return struct {
        /// Error code type returned by Frame.interpret - includes both error and success termination cases
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
            // Success termination cases (not actually errors)
            Stop,
            Return,
            SelfDestruct,
        };
        const Self = @This();
        /// The type all opcode handlers return.
        /// Opcode handlers are expected to recursively dispatch the next opcode if they themselves don't error or return
        /// Takes cursor pointer with jump table available through dispatch metadata when needed
        pub const OpcodeHandler = *const fn (frame: *Self, cursor: [*]const Dispatch.Item) Error!noreturn;
        /// The struct in charge of efficiently dispatching opcode handlers and providing them metadata
        pub const Dispatch = dispatch_mod.Dispatch(Self);
        /// The config passed into Frame(config)
        pub const frame_config = config;

        /// Returns the appropriate tail call modifier based on the target architecture.
        /// WebAssembly doesn't support tail calls by default, so we use .auto for wasm targets.
        pub inline fn getTailCallModifier() std.builtin.CallModifier {
            return if (builtin.target.cpu.arch == .wasm32 or builtin.target.cpu.arch == .wasm64)
                .auto
            else
                .always_tail; // Must use always_tail for performance
        }
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
            .fusions_enabled = false,
        });
        /// The BlockInfo type configured for this frame
        pub const BlockInfo = block_info_mod.BlockInfo(config.block_info_config);

        /// A fixed size array of opcode handlers indexed by opcode number
        pub const opcode_handlers: [256]OpcodeHandler = if (config.TracerType) |TracerType|
            frame_handlers.getTracedOpcodeHandlers(Self, TracerType)
        else
            frame_handlers.getOpcodeHandlers(Self);

        // Individual handler groups for testing and direct access
        pub const ArithmeticHandlers = @import("handlers_arithmetic.zig").Handlers(Self);
        pub const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(Self);
        pub const ComparisonHandlers = @import("handlers_comparison.zig").Handlers(Self);
        pub const ContextHandlers = @import("handlers_context.zig").Handlers(Self);
        pub const JumpHandlers = @import("handlers_jump.zig").Handlers(Self);
        pub const KeccakHandlers = @import("handlers_keccak.zig").Handlers(Self);
        pub const LogHandlers = @import("handlers_log.zig").Handlers(Self);
        pub const MemoryHandlers = @import("handlers_memory.zig").Handlers(Self);
        pub const StackHandlers = @import("handlers_stack.zig").Handlers(Self);
        pub const StorageHandlers = @import("handlers_storage.zig").Handlers(Self);
        pub const SystemHandlers = @import("handlers_system.zig").Handlers(Self);

        // CACHE LINE 1 (0-63 bytes) - ULTRA HOT PATH
        stack: Stack, // 16B - Stack operations
        gas_remaining: GasType, // 8B - Gas tracking (i64)
        memory: Memory, // 16B - Memory operations
        database: config.DatabaseType, // 8B - Storage access
        calldata: []const u8, // 16B - Input data slice
        // = 64B exactly!

        // CACHE LINE 2 (64-127 bytes) - WARM PATH
        value: *const WordType, // 8B - Call value (pointer)
        contract_address: Address = Address.ZERO_ADDRESS, // 20B - Current contract
        caller: Address, // 20B - Calling address
        logs: std.ArrayListUnmanaged(Log), // 16B - Log array list (unmanaged)
        evm_ptr: *anyopaque, // 8B - EVM instance pointer

        // CACHE LINE 3+ (128+ bytes) - COLD PATH
        output: []u8, // 16B - Output data slice (only for RETURN/REVERT)
        jump_table: Dispatch.JumpTable, // 24B - Jump table for JUMP/JUMPI validation (entries slice)
        allocator: std.mem.Allocator, // 16B - Memory allocator
        self_destruct: ?*SelfDestruct = null, // 8B - Self destruct list
        block_info: BlockInfo, // ~188B - Block context (spans multiple cache lines)
        authorized_address: ?Address = null, // 20B - EIP-3074 authorized address
        bytecode: ?Bytecode = null, // Bytecode object (for CODESIZE/CODECOPY/analysis)

        //
        /// Initialize a new execution frame.
        ///
        /// Creates stack, memory, and other execution components. Allocates
        /// resources with proper cleanup on failure. Bytecode validation
        /// and analysis is now handled separately by dispatch initialization.
        ///
        /// EIP-214: For static calls, self_destruct should be null to prevent
        /// SELFDESTRUCT operations which modify blockchain state.
        pub fn init(allocator: std.mem.Allocator, gas_remaining: GasType, database: config.DatabaseType, caller: Address, value: *const WordType, calldata: []const u8, block_info: BlockInfo, evm_ptr: *anyopaque, self_destruct: ?*SelfDestruct) Error!Self {
            // log.debug("Frame.init: gas={}, caller={any}, value={}, calldata_len={}, self_destruct={}", .{ gas_remaining, caller, value.*, calldata.len, self_destruct != null });
            var stack = Stack.init(allocator) catch {
                @branchHint(.cold);
                log.err("Frame.init: Failed to initialize stack", .{});
                return Error.AllocationError;
            };
            errdefer stack.deinit(allocator);
            var memory = Memory.init(allocator) catch {
                @branchHint(.cold);
                log.err("Frame.init: Failed to initialize memory", .{});
                return Error.AllocationError;
            };
            errdefer memory.deinit(allocator);

            // log.debug("Frame.init: Successfully initialized frame components", .{});
            return Self{
                // Cache line 1
                .stack = stack,
                .gas_remaining = std.math.cast(GasType, @max(gas_remaining, 0)) orelse return Error.InvalidAmount,
                .memory = memory,
                .database = database,
                .calldata = calldata,
                // Cache line 2
                .value = value,
                .contract_address = Address.ZERO_ADDRESS,
                .caller = caller,
                .logs = .{},
                .evm_ptr = evm_ptr,
                // Cache line 3+
                .output = &[_]u8{}, // Start with empty output
                .jump_table = .{ .entries = &[_]Dispatch.JumpTable.JumpTableEntry{} }, // Empty jump table
                .allocator = allocator,
                .self_destruct = self_destruct,
                .block_info = block_info,
                .authorized_address = null,
            };
        }
        /// Clean up all frame resources.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            log.debug("Frame.deinit: Starting cleanup, logs_count={}, output_len={}", .{ self.logs.items.len, self.output.len });
            self.stack.deinit(allocator);
            self.memory.deinit(allocator);
            // Free log data
            for (self.logs.items) |log_entry| {
                allocator.free(log_entry.topics);
                allocator.free(log_entry.data);
            }
            self.logs.deinit(allocator);
            if (self.output.len > 0) {
                allocator.free(self.output);
            }
            log.debug("Frame.deinit: Cleanup complete", .{});
        }

        /// Execute this frame without tracing (backward compatibility method).
        /// Simply delegates to interpret_with_tracer with no tracer.
        /// @param bytecode_raw: Raw bytecode to execute
        pub fn interpret(self: *Self, bytecode_raw: []const u8) Error!void {
            return self.interpret_with_tracer(bytecode_raw, null, {});
        }

        /// Execute this frame by building a dispatch schedule and jumping to the first handler.
        /// Performs a one-time static gas charge for the first basic block before execution.
        ///
        /// @param bytecode_raw: Raw bytecode to execute
        /// @param TracerType: Optional comptime tracer type for zero-cost tracing abstraction
        /// @param tracer_instance: Instance of the tracer (ignored if TracerType is null)
        pub fn interpret_with_tracer(self: *Self, bytecode_raw: []const u8, comptime TracerType: ?type, tracer_instance: if (TracerType) |T| *T else void) Error!void {
            // Measure dispatch schedule + jump table creation vs. opcode execution
            var analysis_ns: u64 = 0;
            var dispatch_build_ns: u64 = 0;
            // log.debug("Frame.interpret_with_tracer: Starting execution, bytecode_len={}, gas={}", .{ bytecode_raw.len, self.gas_remaining });

            if (bytecode_raw.len > config.max_bytecode_size) {
                @branchHint(.unlikely);
                log.err("Frame.interpret_with_tracer: Bytecode too large: {} > max {}", .{ bytecode_raw.len, config.max_bytecode_size });
                return Error.BytecodeTooLarge;
            }

            // log.debug("DEBUG: About to init bytecode, raw_len={}\n", .{bytecode_raw.len});
            const t_analysis_start = std.time.Instant.now() catch unreachable;
            self.bytecode = Bytecode.init(self.allocator, bytecode_raw) catch |e| {
                @branchHint(.unlikely);
                // log.debug("DEBUG: Bytecode init FAILED with error: {}\n", .{e});
                log.err("Frame.interpret_with_tracer: Bytecode init failed: {}", .{e});
                return switch (e) {
                    error.BytecodeTooLarge => Error.BytecodeTooLarge,
                    error.InvalidOpcode => Error.InvalidOpcode,
                    error.InvalidJumpDestination => Error.InvalidJump,
                    error.TruncatedPush => Error.InvalidOpcode,
                    error.OutOfMemory => Error.AllocationError,
                    else => Error.AllocationError,
                };
            };
            const t_analysis_end = std.time.Instant.now() catch unreachable;
            analysis_ns = t_analysis_end.since(t_analysis_start);
            defer if (self.bytecode) |*bc| bc.deinit();
            // log.debug("DEBUG: Bytecode init SUCCESS, runtime_code_len={}\n", .{self.bytecode.?.runtime_code.len});

            // Use the handlers (traced or non-traced based on TracerType)
            const handlers = &Self.opcode_handlers;

            // Debug: Check if we're using traced handlers
            if (TracerType) |_| {
                // log.debug("Using TRACED handlers for type: {s}", .{@typeName(T)});
                frame_handlers.setTracerInstance(tracer_instance);
            } else {
                // log.debug("Using NON-TRACED handlers", .{});
            }
            
            // Clear tracer at end of function, not at end of if block
            defer {
                if (TracerType != null) {
                    frame_handlers.clearTracerInstance();
                }
            }

            // Create dispatch schedule with ownership to ensure all allocations are freed
            const t_dispatch_start = std.time.Instant.now() catch unreachable;
            var schedule_raii = Dispatch.DispatchSchedule.init(self.allocator, &self.bytecode.?, handlers) catch |e| {
                log.err("Frame.interpret_with_tracer: Failed to create dispatch schedule: {}", .{e});
                return Error.AllocationError;
            };
            defer schedule_raii.deinit();
            const schedule = schedule_raii.items;

            // Create jump table
            const jump_table = Dispatch.createJumpTable(self.allocator, schedule, &self.bytecode.?) catch return Error.AllocationError;
            defer self.allocator.free(jump_table.entries);
            const t_dispatch_end = std.time.Instant.now() catch unreachable;
            dispatch_build_ns = t_dispatch_end.since(t_dispatch_start);

            // Store jump table in frame for JUMP/JUMPI handlers
            self.jump_table = jump_table;

            // Handle first_block_gas
            var start_index: usize = 0;
            const first_block_gas = Dispatch.calculateFirstBlockGas(self.bytecode.?);
            if (first_block_gas > 0 and schedule.len > 0) {
                const temp_dispatch = Dispatch{ .cursor = schedule.ptr };
                const meta = temp_dispatch.getFirstBlockGas();
                if (meta.gas > 0) {
                    // log.debug("Frame.interpret_with_tracer: Consuming first_block_gas={}", .{meta.gas});
                    try self.consumeGasChecked(@intCast(meta.gas));
                }
                start_index = 1;
            }

            const cursor = Dispatch{ .cursor = schedule.ptr + start_index };

            // Verify bytecode stream ends with 2 stop handlers (debug builds only)
            if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
                if (schedule.len >= 2) {
                    const last_item = schedule[schedule.len - 1];
                    const second_last_item = schedule[schedule.len - 2];

                    // With traced handlers we can't directly compare, so skip this check when tracing
                    if (TracerType == null) {
                        const stop_handler = Self.opcode_handlers[@intFromEnum(Opcode.STOP)];
                        if (last_item.opcode_handler != stop_handler or second_last_item.opcode_handler != stop_handler) {
                            log.err("Frame.interpret_with_tracer: Bytecode stream does not end with 2 stop handlers", .{});
                            return Error.InvalidOpcode;
                        }
                    }
                } else {
                    log.err("Frame.interpret_with_tracer: Bytecode stream too short", .{});
                    return Error.InvalidOpcode;
                }
            }

            // log.debug("Frame.interpret_with_tracer: Starting execution, gas={}", .{self.gas_remaining});

            // Measure opcode handler execution time; errdefer ensures it logs when unwinding with Stop/Return/etc.
            const t_exec_start = std.time.Instant.now() catch unreachable;
            errdefer {
                const t_exec_end = std.time.Instant.now() catch unreachable;
                const exec_ns = t_exec_end.since(t_exec_start);
                // Debug-level timing to avoid failing tests that treat errors as failures
                log.debug("timing: analysis_ns={} dispatch_ns={} handlers_ns={}", .{ analysis_ns, dispatch_build_ns, exec_ns });
            }

            try cursor.cursor[0].opcode_handler(self, cursor.cursor);
            unreachable; // Handlers never return normally
        }

        /// Create a deep copy of the frame.
        /// This is used by DebugPlan to create a sidecar frame for validation.
        pub fn copy(self: *const Self, allocator: std.mem.Allocator) Error!Self {
            log.debug("Frame.copy: Creating deep copy, stack_size={}, memory_size={}, logs_count={}", .{ self.stack.get_slice().len, self.memory.size(), self.logs.items.len });
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

            var new_logs = std.ArrayListUnmanaged(Log){};
            errdefer new_logs.deinit(allocator);

            for (self.logs.items) |log_entry| {
                const topics_copy = allocator.dupe(u256, log_entry.topics) catch return Error.AllocationError;
                errdefer allocator.free(topics_copy);

                const data_copy = allocator.dupe(u8, log_entry.data) catch return Error.AllocationError;
                errdefer allocator.free(data_copy);

                try new_logs.append(allocator, Log{
                    .address = log_entry.address,
                    .topics = topics_copy,
                    .data = data_copy,
                });
            }

            const new_output = if (self.output.len > 0) blk: {
                const output_copy = allocator.alloc(u8, self.output.len) catch return Error.AllocationError;
                @memcpy(output_copy, self.output);
                break :blk output_copy;
            } else &[_]u8{};

            log.debug("Frame.copy: Deep copy complete", .{});
            return Self{
                .stack = new_stack,
                .gas_remaining = self.gas_remaining,
                .memory = new_memory,
                .database = self.database,
                .logs = new_logs,
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
        ///
        /// Safety: This function clamps the amount to fit in GasType, but in practice
        /// this should never happen because:
        /// 1. Block gas limits are typically 30M (well below i32 max of ~2.1B)
        /// 2. You would run out of gas (gas_remaining < 0) long before hitting the clamp
        /// 3. Gas costs are designed to fit in u32, making clamping unnecessary
        pub fn consumeGasUnchecked(self: *Self, amount: u32) void {
            // Compile-time verification that clamping is practically unnecessary
            comptime {
                // With typical block gas limit of 30M and i32, we have plenty of headroom
                if (frame_config.block_gas_limit <= std.math.maxInt(i32)) {
                    // Ensure no single gas cost exceeds what i32 can hold
                    // This is a sanity check - all EVM gas costs are well below this
                    std.debug.assert(std.math.maxInt(u32) < std.math.maxInt(i32));
                }
            }

            // In practice, amount should always fit in GasType since we use u32
            // The clamp is defensive programming for edge cases
            const clamped_amount = @min(amount, std.math.maxInt(GasType));
            self.gas_remaining -= @as(GasType, @intCast(clamped_amount));
        }

        /// Consume gas with bounds checking and safe casting
        /// Returns GasOverflow if amount doesn't fit in GasType (extremely rare)
        /// Returns OutOfGas if insufficient gas remaining
        pub fn consumeGasChecked(self: *Self, amount: u32) Error!void {
            // Cast to GasType - should always succeed with u32 input
            // Only fails if GasType is smaller than u32 (impossible with current config)
            const amt = std.math.cast(GasType, amount) orelse {
                log.err("Frame.consumeGasChecked: Gas overflow, amount={} doesn't fit in GasType", .{amount});
                return Error.GasOverflow;
            };

            // Check if we have enough gas
            if (amt > self.gas_remaining) {
                log.debug("Frame.consumeGasChecked: Out of gas, required={}, remaining={}", .{ amt, self.gas_remaining });
                return Error.OutOfGas;
            }

            self.gas_remaining -= amt;
        }

        /// Get the EVM instance from the opaque pointer
        pub inline fn getEvm(self: *const Self) *DefaultEvm {
            return @as(*DefaultEvm, @ptrCast(@alignCast(self.evm_ptr)));
        }






        /// Pretty print the frame state for debugging and visualization.
        /// Shows stack, memory, gas, and other key state information with ANSI colors.
        pub fn pretty_print(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
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
            };

            var output = std.ArrayList(u8).initCapacity(allocator, 4096) catch return Error.AllocationError;
            const writer = output.writer(allocator);

            // Header
            try writer.print("{s}{s}╔══════════════════════════════════════════════════════════════╗{s}\n", .{ Colors.bold, Colors.cyan, Colors.reset });
            try writer.print("{s}{s}║                       FRAME STATE                               ║{s}\n", .{ Colors.bold, Colors.cyan, Colors.reset });
            try writer.print("{s}{s}╚══════════════════════════════════════════════════════════════╝{s}\n", .{ Colors.bold, Colors.cyan, Colors.reset });

            // Gas information
            try writer.print("\n{s}⛽ Gas:{s} ", .{ Colors.yellow, Colors.reset });
            if (self.gas_remaining > 1_000_000) {
                try writer.print("{s}{d:.2}M{s}", .{ Colors.green, @as(f64, @floatFromInt(self.gas_remaining)) / 1_000_000.0, Colors.reset });
            } else if (self.gas_remaining > 1_000) {
                try writer.print("{s}{d:.2}K{s}", .{ Colors.green, @as(f64, @floatFromInt(self.gas_remaining)) / 1_000.0, Colors.reset });
            } else if (self.gas_remaining > 100) {
                try writer.print("{s}{d}{s}", .{ Colors.green, self.gas_remaining, Colors.reset });
            } else {
                try writer.print("{s}{d}{s}", .{ Colors.red, self.gas_remaining, Colors.reset });
            }
            try writer.print("\n", .{});

            // Contract and caller addresses
            try writer.print("\n{s}📍 Contract:{s} {s}0x{s}{s}\n", .{ Colors.blue, Colors.reset, Colors.dim, std.fmt.bytesToHex(&self.contract_address.bytes, .lower), Colors.reset });
            try writer.print("{s}📞 Caller:{s}   {s}0x{s}{s}\n", .{ Colors.blue, Colors.reset, Colors.dim, std.fmt.bytesToHex(&self.caller.bytes, .lower), Colors.reset });

            // Value (if non-zero)
            if (self.value.* != 0) {
                try writer.print("{s}💰 Value:{s}    {s}{d}{s}\n", .{ Colors.magenta, Colors.reset, Colors.bold, self.value.*, Colors.reset });
            }

            // Stack visualization (simplified for now)
            try writer.print("\n{s}📚 Stack: (details available in debug mode){s}\n", .{ Colors.cyan, Colors.reset });

            // Memory visualization
            const mem_size = self.memory.size();
            try writer.print("\n{s}💾 Memory [{d} bytes]:{s}\n", .{ Colors.magenta, mem_size, Colors.reset });

            if (mem_size > 0) {
                const bytes_to_show = @min(mem_size, 64);
                const mem_slice = self.memory.get_slice(0, @intCast(bytes_to_show)) catch &[_]u8{};

                // Show memory in hex with ASCII representation
                var offset: usize = 0;
                while (offset < bytes_to_show) : (offset += 16) {
                    const end = @min(offset + 16, bytes_to_show);
                    const line = mem_slice[offset..end];

                    try writer.print("  {s}0x{x:0>4}:{s} ", .{ Colors.dim, offset, Colors.reset });

                    // Hex bytes
                    for (line) |byte| {
                        if (byte == 0) {
                            try writer.print("{s}00{s} ", .{ Colors.dim, Colors.reset });
                        } else {
                            try writer.print("{s}{x:0>2}{s} ", .{ Colors.white, byte, Colors.reset });
                        }
                    }

                    // Padding if line is short
                    var padding_needed = 16 - line.len;
                    while (padding_needed > 0) : (padding_needed -= 1) {
                        try writer.print("   ");
                    }

                    // ASCII representation
                    try writer.print(" {s}│{s}", .{ Colors.dim, Colors.reset });
                    for (line) |byte| {
                        if (byte >= 32 and byte < 127) {
                            try writer.print("{s}{c}{s}", .{ Colors.green, byte, Colors.reset });
                        } else if (byte == 0) {
                            try writer.print("{s}.{s}", .{ Colors.dim, Colors.reset });
                        } else {
                            try writer.print("{s}·{s}", .{ Colors.yellow, Colors.reset });
                        }
                    }
                    try writer.print("\n", .{});
                }

                if (mem_size > bytes_to_show) {
                    try writer.print("  {s}... {d} more bytes{s}\n", .{ Colors.dim, mem_size - bytes_to_show, Colors.reset });
                }
            } else {
                try writer.print("  {s}(empty){s}\n", .{ Colors.dim, Colors.reset });
            }

            // Calldata preview (if present)
            if (self.calldata.len > 0) {
                try writer.print("\n{s}📥 Calldata [{d} bytes]:{s} ", .{ Colors.yellow, self.calldata.len, Colors.reset });

                const calldata_preview_len = @min(self.calldata.len, 32);
                for (self.calldata[0..calldata_preview_len]) |byte| {
                    try writer.print("{x:0>2}", .{byte});
                }
                if (self.calldata.len > 32) {
                    try writer.print("...");
                }
                try writer.print("\n", .{});
            }

            // Logs count
            if (self.logs.items.len > 0) {
                try writer.print("\n{s}📝 Logs:{s} {d} events\n", .{ Colors.cyan, Colors.reset, self.logs.items.len });
            }

            // Output data (if any)
            if (self.output.len > 0) {
                try writer.print("\n{s}📤 Output [{d} bytes]:{s} ", .{ Colors.green, self.output.len, Colors.reset });

                const output_preview_len = @min(self.output.len, 32);
                for (self.output[0..output_preview_len]) |byte| {
                    try writer.print("{x:0>2}", .{byte});
                }
                if (self.output.len > 32) {
                    try writer.print("...");
                }
                try writer.print("\n", .{});
            }

            // Footer
            try writer.print("\n{s}{s}════════════════════════════════════════════════════════════════{s}\n", .{ Colors.dim, Colors.cyan, Colors.reset });

            return try output.toOwnedSlice(allocator);
        }
    };
}
