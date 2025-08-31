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
        pub const opcode_handlers: [256]OpcodeHandler = frame_handlers.getOpcodeHandlers(Self);
        
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
            log.debug("Frame.init: gas={}, caller={any}, value={}, calldata_len={}, self_destruct={}", .{ 
                gas_remaining, 
                caller, 
                value.*, 
                calldata.len, 
                self_destruct != null 
            });
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

            log.debug("Frame.init: Successfully initialized frame components", .{});
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
                .jump_table = .{ .entries = &[_]Dispatch.JumpTableEntry{} }, // Empty jump table
                .allocator = allocator,
                .self_destruct = self_destruct,
                .block_info = block_info,
                .authorized_address = null,
            };
        }
        /// Clean up all frame resources.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            log.debug("Frame.deinit: Starting cleanup, logs_count={}, output_len={}", .{ 
                self.logs.items.len, 
                self.output.len 
            });
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
            log.debug("Frame.interpret_with_tracer: Starting execution, bytecode_len={}, gas={}", .{ 
                bytecode_raw.len, 
                self.gas_remaining 
            });
            
            if (bytecode_raw.len > config.max_bytecode_size) {
                @branchHint(.unlikely);
                log.err("Frame.interpret_with_tracer: Bytecode too large: {} > max {}", .{ 
                    bytecode_raw.len, 
                    config.max_bytecode_size 
                });
                return Error.BytecodeTooLarge;
            }

            var bytecode = Bytecode.init(self.allocator, bytecode_raw) catch |e| {
                @branchHint(.unlikely);
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
            defer bytecode.deinit();

            const handlers = &Self.opcode_handlers;

            if (TracerType) |T| {
                if (@hasDecl(T, "beforeExecute")) {
                    tracer_instance.beforeExecute(Self, self);
                }
            }

            if (TracerType) |T| {
                log.debug("Frame.interpret_with_tracer: Creating traced schedule with bytecode len={}", .{bytecode.runtime_code.len});
                const traced_schedule = Dispatch.initWithTracing(self.allocator, &bytecode, handlers, T, tracer_instance) catch |e| {
                    log.err("Frame.interpret_with_tracer: Failed to create traced schedule: {}", .{e});
                    return Error.AllocationError;
                };
                log.debug("Frame.interpret_with_tracer: Traced schedule created, len={}", .{traced_schedule.len});
                defer Dispatch.deinitSchedule(self.allocator, traced_schedule);

                const traced_jump_table = Dispatch.createJumpTable(self.allocator, traced_schedule, &bytecode) catch return Error.AllocationError;
                defer self.allocator.free(traced_jump_table.entries);
                
                // Store jump table in frame for JUMP/JUMPI handlers
                self.jump_table = traced_jump_table;

                var start_index: usize = 0;
                // Check if first item is first_block_gas and consume gas if so
                const first_block_gas = Self.Dispatch.calculateFirstBlockGas(bytecode);
                if (first_block_gas > 0 and traced_schedule.len > 0) {
                    const temp_dispatch = Self.Dispatch{ .cursor = traced_schedule.ptr };
                    const meta = temp_dispatch.getFirstBlockGas();
                    if (meta.gas > 0) try self.consumeGasChecked(@intCast(meta.gas));
                    start_index = 1;
                }

                const cursor = Self.Dispatch{ .cursor = traced_schedule.ptr + start_index };
                log.debug("Frame.interpret_with_tracer: Starting traced execution at cursor index {}, gas={}", .{start_index, self.gas_remaining});
                cursor.cursor[0].opcode_handler(self, cursor.cursor) catch |err| {
                    log.debug("Frame.interpret_with_tracer: Handler failed with error: {}", .{err});
                    return err;
                };
                unreachable; // Handlers never return normally
            } else {
                log.debug("Frame.interpret_with_tracer: Dispatch init: bytecode len={d}", .{bytecode.runtime_code.len});
                const schedule = Dispatch.init(self.allocator, &bytecode, handlers) catch |e| {
                    log.err("Frame.interpret_with_tracer: Failed to create dispatch schedule: {any}", .{e});
                    log.err("Frame.interpret_with_tracer:   Bytecode runtime_code len: {d}", .{bytecode.runtime_code.len});
                    return Error.AllocationError;
                };
                log.debug("Frame.interpret_with_tracer: DISPATCH INIT COMPLETE: schedule len={d}, opcode_count={d}", .{ schedule.len, bytecode.runtime_code.len });
                defer Dispatch.deinitSchedule(self.allocator, schedule);
                
                if (schedule.len < 3) {
                    log.err("Frame.interpret_with_tracer: Dispatch schedule is too short! len={d}", .{schedule.len});
                    log.err("Frame.interpret_with_tracer:   Bytecode len: {d}", .{bytecode.runtime_code.len});
                    if (bytecode.runtime_code.len > 0) {
                        log.err("Frame.interpret_with_tracer:   First few bytes: {x}", .{bytecode.runtime_code[0..@min(bytecode.runtime_code.len, 16)]});
                    }
                    return Error.InvalidOpcode;
                }

                const jump_table = Dispatch.createJumpTable(self.allocator, schedule, &bytecode) catch return Error.AllocationError;
                defer self.allocator.free(jump_table.entries);
                
                // Store jump table in frame for JUMP/JUMPI handlers
                self.jump_table = jump_table;

                var start_index: usize = 0;
                // Check if first item is first_block_gas and consume gas if so
                const first_block_gas = Self.Dispatch.calculateFirstBlockGas(bytecode);
                if (first_block_gas > 0 and schedule.len > 0) {
                    const temp_dispatch = Self.Dispatch{ .cursor = schedule.ptr };
                    const meta = temp_dispatch.getFirstBlockGas();
                    log.debug("Frame.interpret_with_tracer: First block gas charge: {d} (current gas: {d})", .{ meta.gas, self.gas_remaining });
                    if (meta.gas > 0) try self.consumeGasChecked(@intCast(meta.gas));
                    log.debug("Frame.interpret_with_tracer: Gas after first block charge: {d}", .{self.gas_remaining});
                    start_index = 1;
                }

                const cursor = Self.Dispatch{ .cursor = schedule.ptr + start_index };
                
                // Debug: First item should be an opcode_handler after skipping first_block_gas
                // Since the union is untagged, we can't verify this at runtime
                log.debug("Frame.interpret_with_tracer: Starting execution at dispatch index {} (schedule length: {})", .{ start_index, schedule.len });
                // Pass cursor pointer and jump_table separately - no Dispatch struct needed
                cursor.cursor[0].opcode_handler(self, cursor.cursor) catch |err| return err;
                unreachable; // Handlers never return normally
            }

            if (TracerType) |T| if (@hasDecl(T, "afterExecute")) tracer_instance.afterExecute(Self, self);
        }

        /// Create a deep copy of the frame.
        /// This is used by DebugPlan to create a sidecar frame for validation.
        pub fn copy(self: *const Self, allocator: std.mem.Allocator) Error!Self {
            log.debug("Frame.copy: Creating deep copy, stack_size={}, memory_size={}, logs_count={}", .{ 
                self.stack.get_slice().len, 
                self.memory.size(), 
                self.logs.items.len 
            });
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

        /// Set output data (allocates on heap)
        pub fn setOutput(self: *Self, data: []const u8) Error!void {
            log.debug("Frame.setOutput: Setting output data, new_size={}, old_size={}", .{ 
                data.len, 
                self.output.len 
            });
            if (self.output.len > 0) {
                self.allocator.free(self.output);
            }
            if (data.len == 0) {
                self.output = &[_]u8{};
                return;
            }
            const new_output = self.allocator.alloc(u8, data.len) catch {
                log.err("Frame.setOutput: Failed to allocate {} bytes for output", .{data.len});
                return Error.AllocationError;
            };
            @memcpy(new_output, data);
            self.output = new_output;
        }

        /// Get current output data as slice
        pub fn getOutput(self: *const Self) []const u8 {
            return self.output;
        }

        /// Add a log entry to the list
        pub fn appendLog(self: *Self, log_entry: Log) error{OutOfMemory}!void {
            log.debug("Frame.appendLog: Adding log entry from address={any}, topics_count={}, data_len={}", .{ 
                log_entry.address, 
                log_entry.topics.len, 
                log_entry.data.len 
            });
            try self.logs.append(self.allocator, log_entry);
        }

        /// Get slice of current log entries
        pub fn getLogSlice(self: *const Self) []const Log {
            return self.logs.items;
        }

        /// Get number of logs
        pub fn getLogCount(self: *const Self) usize {
            return self.logs.items.len;
        }
    };
}