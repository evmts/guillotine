const std = @import("std");
const builtin = @import("builtin");
const memory_mod = @import("../memory/memory.zig");
const stack_mod = @import("../stack/stack.zig");
const opcode_data = @import("../opcodes/opcode_data.zig");
const Opcode = opcode_data.Opcode;
const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;
pub const FrameConfig = @import("frame_config.zig").FrameConfig;
const Database = @import("../storage/database.zig").Database;
const Account = @import("../storage/database.zig").Account;
const MemoryDatabase = @import("../storage/memory_database.zig").MemoryDatabase;
const bytecode_mod = @import("../bytecode/bytecode.zig");
const BytecodeConfig = @import("../bytecode/bytecode_config.zig").BytecodeConfig;
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
const Address = primitives.Address.Address;
const to_u256 = primitives.Address.to_u256;
const from_u256 = primitives.Address.from_u256;
const frame_handlers = @import("frame_handlers.zig");
const SelfDestruct = @import("../storage/self_destruct.zig").SelfDestruct;
const DefaultEvm = @import("../evm.zig").Evm(.{});
const call_params_mod = @import("call_params.zig");
const call_result_mod = @import("call_result.zig");
const dispatch_mod = @import("../preprocessor/dispatch.zig");

/// The core most important datastructure of the entire EVM
/// Holds the StackFrame state along with an `interpret` method for executing a stack frame
pub fn Frame(_config: FrameConfig) type {
    _config.validate();

    return struct {
        const Self = @This();

        /// The config passed into Frame(_config)
        pub const config = _config;

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
            ReturnDataNotAvailable,
            // Success termination cases (not actually errors)
            // We treat every exit as errors in the low level interpreter while evm.zig catches them and returns them as success
            // This is a perf optimization
            Stop,
            Return,
            SelfDestruct,
        };


        /// Opcode handlers are expected to recursively dispatch the next opcode if they themselves don't error or return
        /// Takes cursor pointer with jump table available through dispatch metadata when needed
        pub const OpcodeHandler = *const fn (frame: *Self, cursor: [*]const Dispatch.Item) Error!noreturn;

        /// The struct in charge of efficiently dispatching opcode handlers and providing them metadata
        pub const Dispatch = dispatch_mod.Preprocessor(Self);

        /// The "word" type used by the evm. Defaults to u256. "Word" is the type used by Stack and throughout the Evm
        /// If set to something else the EVM will update to that new word size. e.g. run kekkak128 instead of kekkak256
        /// Lowering the word size can improve perf and bundle size
        pub const WordType = config.WordType;
        /// Generic Uint type based on WordType for optimized arithmetic operations
        /// Automatically determines the bit width and limb count from WordType
        pub const UintN = blk: {
            const Uint = @import("primitives").Uint;
            const bits = @bitSizeOf(WordType);
            const limbs = if (bits <= 64) 1 else (bits + 63) / 64;
            break :blk Uint(bits, limbs);
        };
        /// The type used to measure gas. Unsigned integer for perf reasons
        pub const GasType = config.GasType();
        /// The type used to index into bytecode or instructions. Determined by config.max_bytecode_size
        pub const PcType = config.PcType();

        // Compile-time check: PcType must be at least u8 for dispatch cache optimization
        comptime {
            if (@bitSizeOf(PcType) < 8) @compileError("PcType must be at least u8 (8 bits). Current max_bytecode_size is too small.");
        }

        /// The struct in charge of managing Evm memory
        pub const Memory = memory_mod.Memory(.{
            .initial_capacity = config.memory_initial_capacity,
            .memory_limit = config.memory_limit,
            .owned = true,
            .vector_length = config.vector_length,
        });
        /// The struct in charge of managing Evm Word stack
        pub const Stack = stack_mod.Stack(.{
            .stack_size = config.stack_size,
            .WordType = config.WordType,
        });
        /// The type used to validate and analyze bytecode
        /// Bytecode in a single pass validates the bytecode and produces an iterator
        /// Dispatch can use to produce the Dispatch stream
        /// Note: Now used internally in interpret_with_tracer, not stored on frame
        const Bytecode = bytecode_mod.Bytecode(.{
            .max_bytecode_size = config.max_bytecode_size,
            .max_initcode_size = config.max_initcode_size,
            .fusions_enabled = true,
        });

        /// A fixed size array of opcode handlers indexed by opcode number
        /// Note: Tracer is now part of EVM struct, not config - always use non-traced handlers
        pub const opcode_handlers: [256]OpcodeHandler = frame_handlers.getOpcodeHandlers(Self, &.{});

        // Individual handler groups for testing and direct access
        pub const ArithmeticHandlers = @import("../instructions/handlers_arithmetic.zig").Handlers(Self);
        pub const BitwiseHandlers = @import("../instructions/handlers_bitwise.zig").Handlers(Self);
        pub const ComparisonHandlers = @import("../instructions/handlers_comparison.zig").Handlers(Self);
        pub const ContextHandlers = @import("../instructions/handlers_context.zig").Handlers(Self);
        pub const JumpHandlers = @import("../instructions/handlers_jump.zig").Handlers(Self);
        pub const KeccakHandlers = @import("../instructions/handlers_keccak.zig").Handlers(Self);
        pub const LogHandlers = @import("../instructions/handlers_log.zig").Handlers(Self);
        pub const MemoryHandlers = @import("../instructions/handlers_memory.zig").Handlers(Self);
        pub const StackHandlers = @import("../instructions/handlers_stack.zig").Handlers(Self);
        pub const StorageHandlers = @import("../instructions/handlers_storage.zig").Handlers(Self);
        pub const SystemHandlers = @import("../instructions/handlers_system.zig").Handlers(Self);

        // Synthetic handler groups for optimized opcode fusion
        pub const ArithmeticSyntheticHandlers = @import("../instructions/handlers_arithmetic_synthetic.zig").Handlers(Self);
        pub const BitwiseSyntheticHandlers = @import("../instructions/handlers_bitwise_synthetic.zig").Handlers(Self);
        pub const MemorySyntheticHandlers = @import("../instructions/handlers_memory_synthetic.zig").Handlers(Self);
        pub const JumpSyntheticHandlers = @import("../instructions/handlers_jump_synthetic.zig").Handlers(Self);

        // CACHE LINE 1
        stack: Stack, // 16B
        gas_remaining: GasType, // 8B
        evm_ptr: *anyopaque, // 8B
        database: *anyopaque, // 8B - Direct database pointer for hot path (storage ops)
        memory: Memory, // 16B -
        contract_address: Address, // 20B
        caller: Address, // 20B

        // These fields are rarely accessed (specific opcodes only)
        // Note: database moved to EVM struct - access via evm_ptr for better cache locality
        value: WordType, // 32B - Only for CALLVALUE opcode (per-call, cannot cache)
        calldata_slice: []const u8, // 16B - Only for CALLDATALOAD/COPY (per-call, cannot cache)
        // TODO: We should be able to remove this in favor of storing pointer as metadata
        code: []const u8 = &[_]u8{}, // 16B - Only for CODESIZE/CODECOPY
        authorized_address: ?Address = null, // 21B - EIP-3074 (per-call auth, cannot cache)
        // TODO: We should be able to remove this in favor of storing pointer as metadata
        jump_table: *const Dispatch.JumpTable, // 8B - Jump table for JUMP/JUMPI
        dispatch: Dispatch, // 16B
        // When enabled (by default only in Debug and Safe mode) we track how many instructions we executed and limit it
        instruction_counter: config.createLoopSafetyCounter(),
        // Output data for RETURN and REVERT operations
        output_data: []const u8 = &[_]u8{},

        /// Initialize a new frame for EVM bytecode execution.
        ///
        /// Creates a frame with its own isolated stack and memory for executing
        /// contract code. The frame receives gas, caller context, call value,
        /// and input data.
        ///
        /// Parameters:
        ///   allocator: Memory allocator for stack and memory
        ///   gas_remaining: Gas available for this frame's execution
        ///   caller: Address of the account making the call
        ///   value: Amount of wei transferred with the call
        ///   calldata_input: Input data for the call (calldata)
        ///   evm_ptr: Opaque pointer to parent EVM instance
        ///
        /// Returns:
        ///   Initialized frame ready for interpret() call
        ///
        /// Errors:
        ///   AllocationError: Failed to allocate stack or memory
        ///   InvalidAmount: Gas value out of range
        pub fn init(allocator: std.mem.Allocator, gas_remaining: GasType, caller: Address, value: WordType, calldata_input: []const u8, evm_ptr: *anyopaque) Error!Self {
            var stack = Stack.init(allocator, null) catch return Error.AllocationError;
            errdefer stack.deinit(allocator);
            var memory = Memory.init(allocator) catch return Error.AllocationError;
            errdefer memory.deinit(allocator);
            // Resolve the database pointer immediately from the provided EVM pointer
            const evm = @as(*DefaultEvm, @ptrCast(@alignCast(evm_ptr)));

            return Self{
                .stack = stack,
                .gas_remaining = std.math.cast(GasType, @max(gas_remaining, 0)) orelse return Error.InvalidAmount,
                .dispatch = Dispatch{ .cursor = undefined }, // Will be set during interpret
                .memory = memory,
                .evm_ptr = evm_ptr,
                .database = @as(*anyopaque, @ptrCast(evm.database)),
                .contract_address = Address.ZERO_ADDRESS,
                .jump_table = &Dispatch.JumpTable{ .entries = &[_]Dispatch.JumpTable.JumpTableEntry{} }, // Pointer to empty jump table
                .caller = caller,
                .value = value,
                .calldata_slice = calldata_input,
                .code = &[_]u8{}, // Will be set during interpret
                .authorized_address = null,
                .instruction_counter = config.createLoopSafetyCounter().init(config.loop_quota orelse 0),
                .output_data = &[_]u8{},
            };
        }

        /// Clean up all frame resources.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            (&self.getEvm().tracer).debug("Frame.deinit: Starting cleanup", .{});
            self.stack.deinit(allocator);
            self.memory.deinit(allocator);
            (&self.getEvm().tracer).debug("Frame.deinit: Cleanup complete", .{});
        }

        /// Execute bytecode using the preprocessed dispatch schedule.
        ///
        /// This is the main execution entry point for the frame. It uses the
        /// dispatch-based execution model (NOT a traditional interpreter):
        ///
        /// - Takes a preprocessed dispatch schedule (not raw bytecode)
        /// - Schedule contains metadata and function pointers
        /// - Uses tail-call optimization for performance
        /// - Validates gas and stack requirements per basic block
        ///
        /// CRITICAL: This is NOT a PC-based interpreter! The schedule cursor
        /// is an index into the dispatch schedule, not a bytecode PC.
        ///
        /// Parameters:
        ///   dispatch_schedule: Preprocessed execution schedule with metadata
        ///   jump_table: Precomputed jump destinations for JUMP/JUMPI
        ///   bytecode_raw: Original bytecode (for tracer/debugging only)
        ///
        /// Errors:
        ///   OutOfGas: Insufficient gas for basic block
        ///   StackUnderflow: Stack has fewer items than required
        ///   StackOverflow: Stack would exceed capacity
        ///   All other execution errors from handlers
        pub fn interpret(self: *Self, dispatch_schedule: *const Dispatch.DispatchSchedule, jump_table: *const Dispatch.JumpTable, bytecode_raw: []const u8) Error!void {
            @branchHint(.likely);
            const evm = self.getEvm();
            // Set the database pointer now that we have proper EVM context
            self.database = @as(*anyopaque, @ptrCast(evm.database));
            (&evm.tracer).onInterpret(self, bytecode_raw, @as(i64, @intCast(self.gas_remaining)));

            (&evm.tracer).onFrameBytecodeInit(bytecode_raw.len, true, null);
            self.code = bytecode_raw;

            (&evm.tracer).initPcTracker(bytecode_raw);

            self.jump_table = jump_table;
            const schedule = dispatch_schedule.items;

            var start_index: usize = 0;
            var first_block_gas_amount: u32 = 0;

            (&self.getEvm().tracer).assert(schedule.len > 0, "Fatal unexpected error: the opcode execution schedule is length 0 which should be impossible");
            const stop_handler = Self.opcode_handlers[@intFromEnum(Opcode.STOP)];
            (&self.getEvm().tracer).assert(schedule.len >= 2 or schedule[schedule.len - 1].opcode_handler != stop_handler or schedule[schedule.len - 2].opcode_handler != stop_handler, "Frame.interpret: Bytecode stream does not end with 2 stop handlers");

            // Validate the schedule structure (for better error reporting)
            (&self.getEvm().tracer).assert(dispatch_schedule.validate(), "Frame.interpret: Invalid dispatch schedule structure");

            // Check if schedule starts with first_block_gas (it may not if gas is 0)
            if (schedule.len > 0 and schedule[0] == .first_block_gas) {
                const meta = schedule[0].first_block_gas;
                if (meta.gas > 0) {
                    first_block_gas_amount = meta.gas;
                    try self.consumeGasChecked(@intCast(meta.gas));
                }
                
                // Validate stack requirements for the first block
                const current_stack_size = self.stack.size();
                const stack_capacity = @TypeOf(self.stack).stack_capacity;
                
                // Check minimum stack requirement (similar to JUMPDEST handler)
                if (meta.min_stack > 0 and current_stack_size < @as(usize, @intCast(meta.min_stack))) {
                    (&self.getEvm().tracer).debug("First block: Stack underflow - required min={}, current={}", .{ meta.min_stack, current_stack_size });
                    return Error.StackUnderflow;
                }
                
                // Check maximum stack requirement (stack overflow prevention)
                if (meta.max_stack > 0) {
                    // max_stack represents the net stack change during the block
                    const max_final_size = @as(isize, @intCast(current_stack_size)) + @as(isize, meta.max_stack);
                    if (max_final_size > @as(isize, @intCast(stack_capacity))) {
                        (&self.getEvm().tracer).debug("First block: Stack overflow - current={}, max_change={}, capacity={}", .{ current_stack_size, meta.max_stack, stack_capacity });
                        return Error.StackOverflow;
                    }
                }
                
                start_index = 1;
            }

            self.dispatch = Dispatch{
                .cursor = schedule.ptr + start_index,
            };

            try self.dispatch.cursor[0].opcode_handler(self, self.dispatch.cursor);

            (&self.getEvm().tracer).assert(false, "Handlers should never return normally");
        }

        /// Create a deep copy of the frame.
        /// This is used by DebugPlan to create a sidecar frame for validation.
        pub fn copy(self: *const Self, allocator: std.mem.Allocator) Error!Self {
            (&self.getEvm().tracer).debug("Frame.copy: Creating deep copy, stack_size={}, memory_size={}", .{ self.stack.get_slice().len, self.memory.size() });
            var new_stack = Stack.init(allocator, @as(?*anyopaque, @ptrCast(&self.getEvm().tracer))) catch return Error.AllocationError;
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

            (&self.getEvm().tracer).debug("Frame.copy: Deep copy complete", .{});
            return Self{
                .stack = new_stack,
                .gas_remaining = self.gas_remaining,
                .dispatch = self.dispatch,
                .memory = new_memory,
                .evm_ptr = self.evm_ptr,
                .database = self.database,
                .contract_address = self.contract_address,
                .jump_table = self.jump_table,
                .caller = self.caller,
                .value = self.value,
                .calldata_slice = self.calldata_slice,
                .code = self.code,
                .authorized_address = self.authorized_address,
                .instruction_counter = self.instruction_counter,
                .output_data = self.output_data,
            };
        }

        /// Consume gas with bounds checking and safe casting
        /// Returns GasOverflow if amount doesn't fit in GasType (extremely rare)
        /// Returns OutOfGas if insufficient gas remaining
        pub fn consumeGasChecked(self: *Self, amount: u32) Error!void {
            // Skip gas checks if disabled in config
            if (comptime config.disable_gas_checks) return;

            const amt = std.math.cast(GasType, amount) orelse {
                (&self.getEvm().tracer).panic("Frame.consumeGasChecked: Gas overflow, amount={} doesn't fit in GasType", .{amount});
                return Error.GasOverflow;
            };

            // Check if we have enough gas
            if (amt > self.gas_remaining) {
                (&self.getEvm().tracer).debug("Frame.consumeGasChecked: Out of gas, required={}, remaining={}", .{ amt, self.gas_remaining });
                return Error.OutOfGas;
            }

            self.gas_remaining -= amt;
        }

        /// Get the EVM instance from the opaque pointer
        /// FIXME: This currently assumes DefaultEvm type which is incorrect for non-default configurations.
        /// The proper fix requires either:
        /// 1. Adding EvmType to FrameConfig (circular dependency issue)
        /// 2. Using comptime type resolution (complex)
        /// 3. Keeping as anyopaque and having callers cast (requires refactoring all handlers)
        /// For now, this works because all handlers only use common EVM methods that exist regardless of config.
        pub inline fn getEvm(self: *const Self) *DefaultEvm {
            return @as(*DefaultEvm, @ptrCast(@alignCast(self.evm_ptr)));
        }

        /// Get the database directly (for hot path storage operations)
        /// This avoids double pointer dereference: self -> evm -> database
        /// Instead we go directly: self -> database
        pub inline fn getDatabase(self: *const Self) *Database {
            return @as(*Database, @ptrCast(@alignCast(self.database)));
        }

        /// Validate that the current dispatch cursor points to the expected handler and metadata.
        /// This provides extra validation that cursor logic is working as expected.
        /// Only runs in Debug and ReleaseSafe modes, no-op in ReleaseSmall/ReleaseFast.
        pub inline fn validateOpcodeHandler(
            self: *Self,
            comptime opcode: Dispatch.UnifiedOpcode,
            cursor: [*]const Dispatch.Item,
        ) void {
            if (comptime (builtin.mode != .Debug and builtin.mode != .ReleaseSafe)) return;
            const dispatch = Dispatch{ .cursor = cursor };
            dispatch.validateOpcodeHandler(opcode, self);
        }

        /// Unified method to handle pre-instruction operations
        /// Combines tracer's before_instruction and opcode validation
        pub inline fn beforeInstruction(
            self: *Self,
            comptime opcode: Dispatch.UnifiedOpcode,
            cursor: [*]const Dispatch.Item,
        ) void {
            if (comptime (builtin.mode != .Debug and builtin.mode != .ReleaseSafe)) return;
            (&self.getEvm().tracer).before_instruction(self, opcode, cursor);
            self.validateOpcodeHandler(opcode, cursor);
        }

        /// Unified method to handle post-instruction operations
        /// Called right before the tail call to the next instruction (normal flow)
        pub inline fn afterInstruction(
            self: *Self,
            comptime opcode: Dispatch.UnifiedOpcode,
            next_handler: OpcodeHandler,
            next_cursor: [*]const Dispatch.Item,
        ) void {
            if (comptime (builtin.mode != .Debug and builtin.mode != .ReleaseSafe)) return;
            (&self.getEvm().tracer).after_instruction(self, opcode, next_handler, next_cursor);
        }

        /// Called when an instruction completes with a terminal state
        /// (Error, Return, Stop, etc.) rather than continuing to next instruction
        pub inline fn afterComplete(
            self: *Self,
            comptime opcode: Dispatch.UnifiedOpcode,
        ) void {
            if (comptime (builtin.mode != .Debug and builtin.mode != .ReleaseSafe)) return;
            (&self.getEvm().tracer).after_complete(self, opcode);
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
            if (self.value != 0) {
                try writer.print("{s}💰 Value:{s}    {s}{d}{s}\n", .{ Colors.magenta, Colors.reset, Colors.bold, self.value, Colors.reset });
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

            const calldata_slice = self.calldata_slice;
            if (calldata_slice.len > 0) {
                try writer.print("\n{s}📥 Calldata [{d} bytes]:{s} ", .{ Colors.yellow, calldata_slice.len, Colors.reset });

                const calldata_preview_len = @min(calldata_slice.len, 32);
                for (calldata_slice[0..calldata_preview_len]) |byte| {
                    try writer.print("{x:0>2}", .{byte});
                }
                if (calldata_slice.len > 32) {
                    try writer.print("...");
                }
                try writer.print("\n", .{});
            }

            try writer.print("\n{s}{s}════════════════════════════════════════════════════════════════{s}\n", .{ Colors.dim, Colors.cyan, Colors.reset });

            return try output.toOwnedSlice(allocator);
        }
    };
}
