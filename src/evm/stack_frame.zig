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
const stack_frame_arithmetic = @import("handlers_arithmetic.zig");
const stack_frame_comparison = @import("handlers_comparison.zig");
const stack_frame_bitwise = @import("handlers_bitwise.zig");
const stack_frame_stack = @import("handlers_stack.zig");
const stack_frame_memory = @import("handlers_memory.zig");
const stack_frame_storage = @import("handlers_storage.zig");
const stack_frame_jump = @import("handlers_jump.zig");
const stack_frame_system = @import("handlers_system.zig");
const stack_frame_context = @import("handlers_context.zig");
const stack_frame_keccak = @import("handlers_keccak.zig");
const stack_frame_log = @import("handlers_log.zig");
// Synthetic handler modules
const stack_frame_arithmetic_synthetic = @import("handlers_arithmetic_synthetic.zig");
const stack_frame_bitwise_synthetic = @import("handlers_bitwise_synthetic.zig");
const stack_frame_memory_synthetic = @import("handlers_memory_synthetic.zig");
const stack_frame_jump_synthetic = @import("handlers_jump_synthetic.zig");
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
        pub const Success = enum {
            Stop,
            Return,
            SelfDestruct,
        };
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
        pub const OpcodeHandler = *const fn (frame: *Self, dispatch: Dispatch) Error!Success;
        pub const Dispatch = dispatch_mod.Dispatch(Self);

        pub const frame_config = config;
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
        pub const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig{
            .max_bytecode_size = config.max_bytecode_size,
            .max_initcode_size = config.max_initcode_size,
            .vector_length = config.vector_length,
            .fusions_enabled = false,
        };
        pub const Bytecode = bytecode_mod.Bytecode(Self.BytecodeConfig);

        pub fn invalid(frame: *Self, dispatch: Dispatch) Error!Success {
            _ = frame;
            _ = dispatch;
            return Error.InvalidOpcode;
        }

        pub const opcode_handlers = blk: {
            @setEvalBranchQuota(10000);
            var h: [256]OpcodeHandler = undefined;
            const invalid_handler: OpcodeHandler = &invalid;
            for (&h) |*handler| handler.* = invalid_handler;
            h[@intFromEnum(Opcode.STOP)] = &SystemHandlers.stop;
            h[@intFromEnum(Opcode.ADD)] = &ArithmeticHandlers.add;
            h[@intFromEnum(Opcode.MUL)] = &ArithmeticHandlers.mul;
            h[@intFromEnum(Opcode.SUB)] = &ArithmeticHandlers.sub;
            h[@intFromEnum(Opcode.DIV)] = &ArithmeticHandlers.div;
            h[@intFromEnum(Opcode.SDIV)] = &ArithmeticHandlers.sdiv;
            h[@intFromEnum(Opcode.MOD)] = &ArithmeticHandlers.mod;
            h[@intFromEnum(Opcode.SMOD)] = &ArithmeticHandlers.smod;
            h[@intFromEnum(Opcode.ADDMOD)] = &ArithmeticHandlers.addmod;
            h[@intFromEnum(Opcode.MULMOD)] = &ArithmeticHandlers.mulmod;
            h[@intFromEnum(Opcode.EXP)] = &ArithmeticHandlers.exp;
            h[@intFromEnum(Opcode.SIGNEXTEND)] = &ArithmeticHandlers.signextend;
            h[@intFromEnum(Opcode.LT)] = &ComparisonHandlers.lt;
            h[@intFromEnum(Opcode.GT)] = &ComparisonHandlers.gt;
            h[@intFromEnum(Opcode.SLT)] = &ComparisonHandlers.slt;
            h[@intFromEnum(Opcode.SGT)] = &ComparisonHandlers.sgt;
            h[@intFromEnum(Opcode.EQ)] = &ComparisonHandlers.eq;
            h[@intFromEnum(Opcode.ISZERO)] = &ComparisonHandlers.iszero;
            h[@intFromEnum(Opcode.AND)] = &BitwiseHandlers.@"and";
            h[@intFromEnum(Opcode.OR)] = &BitwiseHandlers.@"or";
            h[@intFromEnum(Opcode.XOR)] = &BitwiseHandlers.xor;
            h[@intFromEnum(Opcode.NOT)] = &BitwiseHandlers.not;
            h[@intFromEnum(Opcode.BYTE)] = &BitwiseHandlers.byte;
            h[@intFromEnum(Opcode.SHL)] = &BitwiseHandlers.shl;
            h[@intFromEnum(Opcode.SHR)] = &BitwiseHandlers.shr;
            h[@intFromEnum(Opcode.SAR)] = &BitwiseHandlers.sar;
            h[@intFromEnum(Opcode.KECCAK256)] = &KeccakHandlers.keccak;
            h[@intFromEnum(Opcode.ADDRESS)] = &ContextHandlers.address;
            h[@intFromEnum(Opcode.BALANCE)] = &ContextHandlers.balance;
            h[@intFromEnum(Opcode.ORIGIN)] = &ContextHandlers.origin;
            h[@intFromEnum(Opcode.CALLER)] = &ContextHandlers.caller;
            h[@intFromEnum(Opcode.CALLVALUE)] = &ContextHandlers.callvalue;
            h[@intFromEnum(Opcode.CALLDATALOAD)] = &ContextHandlers.calldataload;
            h[@intFromEnum(Opcode.CALLDATASIZE)] = &ContextHandlers.calldatasize;
            h[@intFromEnum(Opcode.CALLDATACOPY)] = &ContextHandlers.calldatacopy;
            h[@intFromEnum(Opcode.CODESIZE)] = &ContextHandlers.codesize;
            h[@intFromEnum(Opcode.CODECOPY)] = &ContextHandlers.codecopy;
            h[@intFromEnum(Opcode.GASPRICE)] = &ContextHandlers.gasprice;
            h[@intFromEnum(Opcode.EXTCODESIZE)] = &ContextHandlers.extcodesize;
            h[@intFromEnum(Opcode.EXTCODECOPY)] = &ContextHandlers.extcodecopy;
            h[@intFromEnum(Opcode.RETURNDATASIZE)] = &ContextHandlers.returndatasize;
            h[@intFromEnum(Opcode.RETURNDATACOPY)] = &ContextHandlers.returndatacopy;
            h[@intFromEnum(Opcode.EXTCODEHASH)] = &ContextHandlers.extcodehash;
            h[@intFromEnum(Opcode.BLOCKHASH)] = &ContextHandlers.blockhash;
            h[@intFromEnum(Opcode.COINBASE)] = &ContextHandlers.coinbase;
            h[@intFromEnum(Opcode.TIMESTAMP)] = &ContextHandlers.timestamp;
            h[@intFromEnum(Opcode.NUMBER)] = &ContextHandlers.number;
            h[@intFromEnum(Opcode.DIFFICULTY)] = &ContextHandlers.difficulty;
            h[@intFromEnum(Opcode.GASLIMIT)] = &ContextHandlers.gaslimit;
            h[@intFromEnum(Opcode.CHAINID)] = &ContextHandlers.chainid;
            h[@intFromEnum(Opcode.SELFBALANCE)] = &ContextHandlers.selfbalance;
            h[@intFromEnum(Opcode.BASEFEE)] = &ContextHandlers.basefee;
            h[@intFromEnum(Opcode.BLOBHASH)] = &ContextHandlers.blobhash;
            h[@intFromEnum(Opcode.BLOBBASEFEE)] = &ContextHandlers.blobbasefee;
            h[@intFromEnum(Opcode.POP)] = &StackHandlers.pop;
            h[@intFromEnum(Opcode.MLOAD)] = &MemoryHandlers.mload;
            h[@intFromEnum(Opcode.MSTORE)] = &MemoryHandlers.mstore;
            h[@intFromEnum(Opcode.MSTORE8)] = &MemoryHandlers.mstore8;
            h[@intFromEnum(Opcode.SLOAD)] = &StorageHandlers.sload;
            h[@intFromEnum(Opcode.SSTORE)] = &StorageHandlers.sstore;
            h[@intFromEnum(Opcode.JUMP)] = &JumpHandlers.jump;
            h[@intFromEnum(Opcode.JUMPI)] = &JumpHandlers.jumpi;
            h[@intFromEnum(Opcode.PC)] = &JumpHandlers.pc;
            h[@intFromEnum(Opcode.MSIZE)] = &MemoryHandlers.msize;
            h[@intFromEnum(Opcode.GAS)] = &ContextHandlers.gas;
            h[@intFromEnum(Opcode.JUMPDEST)] = &JumpHandlers.jumpdest;
            // TODO: Enable when EVM implementation has transient storage support
            // h[@intFromEnum(Opcode.TLOAD)] = &StorageHandlers.tload;
            // h[@intFromEnum(Opcode.TSTORE)] = &StorageHandlers.tstore;
            h[@intFromEnum(Opcode.MCOPY)] = &MemoryHandlers.mcopy;
            // PUSH
            h[@intFromEnum(Opcode.PUSH0)] = &StackHandlers.push0;
            for (1..33) |i| {
                const push_n = @as(u8, @intCast(i));
                const opcode = @as(Opcode, @enumFromInt(@intFromEnum(Opcode.PUSH0) + push_n));
                h[@intFromEnum(opcode)] = StackHandlers.generatePushHandler(push_n);
            }
            // DUP
            for (1..17) |i| {
                const dup_n = @as(u8, @intCast(i));
                const opcode = @as(Opcode, @enumFromInt(@intFromEnum(Opcode.DUP1) + dup_n - 1));
                h[@intFromEnum(opcode)] = StackHandlers.generateDupHandler(dup_n);
            }
            // SWAP
            for (1..17) |i| {
                const swap_n = @as(u8, @intCast(i));
                const opcode = @as(Opcode, @enumFromInt(@intFromEnum(Opcode.SWAP1) + swap_n - 1));
                h[@intFromEnum(opcode)] = StackHandlers.generateSwapHandler(swap_n);
            }
            h[@intFromEnum(Opcode.LOG0)] = LogHandlers.log0;
            h[@intFromEnum(Opcode.LOG1)] = LogHandlers.log1;
            h[@intFromEnum(Opcode.LOG2)] = LogHandlers.log2;
            h[@intFromEnum(Opcode.LOG3)] = LogHandlers.log3;
            h[@intFromEnum(Opcode.LOG4)] = LogHandlers.log4;
            h[@intFromEnum(Opcode.CREATE)] = &SystemHandlers.create;
            h[@intFromEnum(Opcode.CALL)] = &SystemHandlers.call;
            h[@intFromEnum(Opcode.CREATE2)] = &SystemHandlers.create2;
            h[@intFromEnum(Opcode.CALLCODE)] = &invalid; // Deprecated (kept as invalid)
            h[@intFromEnum(Opcode.RETURN)] = &SystemHandlers.@"return";
            h[@intFromEnum(Opcode.DELEGATECALL)] = &SystemHandlers.delegatecall;
            h[@intFromEnum(Opcode.STATICCALL)] = &SystemHandlers.staticcall;
            h[@intFromEnum(Opcode.REVERT)] = &SystemHandlers.revert;
            h[@intFromEnum(Opcode.INVALID)] = &invalid;
            h[@intFromEnum(Opcode.SELFDESTRUCT)] = &SystemHandlers.selfdestruct;
            h[@intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE)] = &ArithmeticSyntheticHandlers.push_add_inline;
            h[@intFromEnum(OpcodeSynthetic.PUSH_ADD_POINTER)] = &ArithmeticSyntheticHandlers.push_add_pointer;
            h[@intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE)] = &ArithmeticSyntheticHandlers.push_mul_inline;
            h[@intFromEnum(OpcodeSynthetic.PUSH_MUL_POINTER)] = &ArithmeticSyntheticHandlers.push_mul_pointer;
            h[@intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE)] = &ArithmeticSyntheticHandlers.push_div_inline;
            h[@intFromEnum(OpcodeSynthetic.PUSH_DIV_POINTER)] = &ArithmeticSyntheticHandlers.push_div_pointer;
            h[@intFromEnum(OpcodeSynthetic.PUSH_SUB_INLINE)] = &ArithmeticSyntheticHandlers.push_sub_inline;
            h[@intFromEnum(OpcodeSynthetic.PUSH_SUB_POINTER)] = &ArithmeticSyntheticHandlers.push_sub_pointer;
            h[@intFromEnum(OpcodeSynthetic.PUSH_JUMP_INLINE)] = &JumpSyntheticHandlers.push_jump_inline;
            h[@intFromEnum(OpcodeSynthetic.PUSH_JUMP_POINTER)] = &JumpSyntheticHandlers.push_jump_pointer;
            h[@intFromEnum(OpcodeSynthetic.PUSH_JUMPI_INLINE)] = &JumpSyntheticHandlers.push_jumpi_inline;
            h[@intFromEnum(OpcodeSynthetic.PUSH_JUMPI_POINTER)] = &JumpSyntheticHandlers.push_jumpi_pointer;
            h[@intFromEnum(OpcodeSynthetic.PUSH_MLOAD_INLINE)] = &MemorySyntheticHandlers.push_mload_inline;
            h[@intFromEnum(OpcodeSynthetic.PUSH_MLOAD_POINTER)] = &MemorySyntheticHandlers.push_mload_pointer;
            h[@intFromEnum(OpcodeSynthetic.PUSH_MSTORE_INLINE)] = &MemorySyntheticHandlers.push_mstore_inline;
            h[@intFromEnum(OpcodeSynthetic.PUSH_MSTORE_POINTER)] = &MemorySyntheticHandlers.push_mstore_pointer;
            h[@intFromEnum(OpcodeSynthetic.PUSH_AND_INLINE)] = &BitwiseSyntheticHandlers.push_and_inline;
            h[@intFromEnum(OpcodeSynthetic.PUSH_AND_POINTER)] = &BitwiseSyntheticHandlers.push_and_pointer;
            h[@intFromEnum(OpcodeSynthetic.PUSH_OR_INLINE)] = &BitwiseSyntheticHandlers.push_or_inline;
            h[@intFromEnum(OpcodeSynthetic.PUSH_OR_POINTER)] = &BitwiseSyntheticHandlers.push_or_pointer;
            h[@intFromEnum(OpcodeSynthetic.PUSH_XOR_INLINE)] = &BitwiseSyntheticHandlers.push_xor_inline;
            h[@intFromEnum(OpcodeSynthetic.PUSH_XOR_POINTER)] = &BitwiseSyntheticHandlers.push_xor_pointer;
            h[@intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_INLINE)] = &MemorySyntheticHandlers.push_mstore8_inline;
            h[@intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_POINTER)] = &MemorySyntheticHandlers.push_mstore8_pointer;
            break :blk h;
        };
        pub const max_bytecode_size = config.max_bytecode_size;

        const Self = @This();
        
        // Import handler modules
        const ArithmeticHandlers = stack_frame_arithmetic.Handlers(Self);
        const ComparisonHandlers = stack_frame_comparison.Handlers(Self);
        const BitwiseHandlers = stack_frame_bitwise.Handlers(Self);
        const StackHandlers = stack_frame_stack.Handlers(Self);
        const MemoryHandlers = stack_frame_memory.Handlers(Self);
        const StorageHandlers = stack_frame_storage.Handlers(Self);
        const JumpHandlers = stack_frame_jump.Handlers(Self);
        const SystemHandlers = stack_frame_system.Handlers(Self);
        const ContextHandlers = stack_frame_context.Handlers(Self);
        const KeccakHandlers = stack_frame_keccak.Handlers(Self);
        const LogHandlers = stack_frame_log.Handlers(Self);
        // Import synthetic handler modules
        const ArithmeticSyntheticHandlers = stack_frame_arithmetic_synthetic.Handlers(Self);
        const BitwiseSyntheticHandlers = stack_frame_bitwise_synthetic.Handlers(Self);
        const MemorySyntheticHandlers = stack_frame_memory_synthetic.Handlers(Self);
        const JumpSyntheticHandlers = stack_frame_jump_synthetic.Handlers(Self);

        //           StackFrame Structure Layout Analysis
        //   Primary Components (Cacheline 1 - Hot Path)
        //
        //   Offset 0-63: Primary cacheline (64 bytes)
        //   ├── stack: Stack                    // ~24 bytes (buf ptr + 2 raw ptrs)
        //   ├── bytecode: Bytecode              // ~40 bytes (slices + metadata)
        //   ├── gas_remaining: GasType          // 4-8 bytes (i32/i64 based on config)
        //   └── initial_gas: GasType            // 4-8 bytes
        // 
        //   Secondary Components (Cacheline 2)
        // 
        //   Offset 64-127: Execution context
        //   ├── tracer: TracerType              // 0 or configurable size
        //   ├── memory: Memory                  // ~32 bytes (checkpoint + ptr + flags + cache)
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
        //  Stack (stack.zig)
        //
        //  - Buffer: 64-byte aligned via alignedAlloc (line 51)
        //  - Pointers: 8-byte aligned raw pointers
        //  - Cache optimization: Downward growth for locality
        //
        //  Memory (memory.zig)
        //
        //  - Packed cache struct: 12 bytes total for expansion cache
        //  - Buffer: Standard ArrayList alignment
        //  - Fast path: Optimized for ≤32 byte expansions (common EVM word size)
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
        // Cache Line 1 (0-63):    [Stack Buf*][Stack Ptrs][Bytecode][Gas][InitGas]
        // Cache Line 2 (64-127):  [Tracer][Memory][Database][Address]
        // Cache Line 3 (128-191): [SelfDest*][Host][Logs][Output][Alloc]
        stack: Stack,
        bytecode: Bytecode, 
        gas_remaining: GasType, 
        initial_gas: GasType = 0,
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
        /// Creates stack, memory, and other execution components. Validates
        /// bytecode size and allocates resources with proper cleanup on failure.
        /// 
        /// EIP-214: For static calls, self_destruct should be null to prevent 
        /// SELFDESTRUCT operations which modify blockchain state.
        pub fn init(allocator: std.mem.Allocator, bytecode_raw: []const u8, gas_remaining: GasType, database: if (config.has_database) ?DatabaseInterface else void, host: Host, self_destruct: ?*SelfDestruct) Error!Self {
            if (bytecode_raw.len > max_bytecode_size) {
                @branchHint(.unlikely);
                return Error.BytecodeTooLarge;
            }

            var bytecode = Bytecode.init(allocator, bytecode_raw) catch |e| {
                @branchHint(.unlikely);
                return switch (e) {
                    error.BytecodeTooLarge => Error.BytecodeTooLarge,
                    error.InvalidOpcode => Error.InvalidOpcode,
                    error.OutOfMemory => Error.AllocationError,
                    else => Error.AllocationError,
                };
            };
            errdefer bytecode.deinit();

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
                .bytecode = bytecode,
                .gas_remaining = @as(GasType, @intCast(@max(gas_remaining, 0))),
                .initial_gas = @as(GasType, @intCast(@max(gas_remaining, 0))),
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
            self.bytecode.deinit();
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
        pub fn interpret(self: *Self) Error!Success {
            return self.interpret_with_tracer(null, {});
        }
        
        /// Execute this frame by building a dispatch schedule and jumping to the first handler.
        /// Performs a one-time static gas charge for the first basic block before execution.
        /// 
        /// @param TracerType: Optional comptime tracer type for zero-cost tracing abstraction
        /// @param tracer_instance: Instance of the tracer (ignored if TracerType is null)
        pub fn interpret_with_tracer(self: *Self, comptime TracerType: ?type, tracer_instance: if (TracerType) |T| *T else void) Error!Success {
            // Call beforeExecute hook if tracer is configured
            if (TracerType) |T| {
                if (@hasDecl(T, "beforeExecute")) {
                    tracer_instance.beforeExecute(Self, self);
                }
            }
            
            const handlers = &Self.opcode_handlers;

            // Build dispatch schedule - with tracing injection if tracer provided
            const schedule = if (TracerType != null) 
                Dispatch.initWithTracing(self.allocator, &self.bytecode, handlers, TracerType.?, tracer_instance) catch return Error.AllocationError
            else 
                Dispatch.init(self.allocator, &self.bytecode, handlers) catch return Error.AllocationError;
            defer Dispatch.deinitSchedule(self.allocator, schedule);
            std.debug.assert(schedule.len > 3);

            var jump_table = Dispatch.createJumpTable(self.allocator, schedule, &self.bytecode) catch return Error.AllocationError;
            defer self.allocator.free(jump_table.entries);

            // Process first block which just charges static gas for the first set of opcodes that could be statically analyzed
            // This will be from start of bytecode up to the first jump
            var start_index: usize = 0;
                switch (schedule[0]) {
                    .first_block_gas => |meta| {
                        if (meta.gas > 0) try self.consumeGasChecked(meta.gas);
                        start_index = 1;
                    },
                    else => unreachable,
                }
            const cursor = Self.Dispatch{ .cursor = schedule.ptr + 1, .jump_table = &jump_table };
            
            // Execute the bytecode
            const result = cursor.cursor[0].opcode_handler(self, cursor);
            
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
                .bytecode = self.bytecode, // Note: Bytecode is shared, not copied
                .gas_remaining = self.gas_remaining,
                .initial_gas = self.initial_gas,
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
