/// Frame implementation for tracing
/// This mirrors the architecture of frame/frame.zig but simplified for validation
const std = @import("std");
const log = @import("logger.zig");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
const Address = primitives.Address.Address;
const Hardfork = @import("primitives").Hardfork;
const opcode_utils = @import("opcode.zig");
const precompiles = @import("precompiles");
const evm_mod = @import("evm.zig");
const EvmConfig = @import("evm_config.zig").EvmConfig;
const Bytecode = @import("bytecode.zig").Bytecode;

// Handler modules
const handlers_arithmetic = @import("instructions/handlers_arithmetic.zig");
const handlers_comparison = @import("instructions/handlers_comparison.zig");
const handlers_bitwise = @import("instructions/handlers_bitwise.zig");
const handlers_keccak = @import("instructions/handlers_keccak.zig");
const handlers_context = @import("instructions/handlers_context.zig");
const handlers_block = @import("instructions/handlers_block.zig");
const handlers_stack = @import("instructions/handlers_stack.zig");
const handlers_memory = @import("instructions/handlers_memory.zig");
const handlers_storage = @import("instructions/handlers_storage.zig");
const handlers_control_flow = @import("instructions/handlers_control_flow.zig");
const handlers_log = @import("instructions/handlers_log.zig");
const handlers_system = @import("instructions/handlers_system.zig");

/// Creates a configured Frame type that matches the given Evm config.
pub fn Frame(comptime config: EvmConfig) type {
    return struct {
        const Self = @This();
        pub const EvmType = evm_mod.Evm(config);
        pub const EvmError = @import("errors.zig").CallError;

        // Instantiate handler modules
        const ArithmeticHandlers = handlers_arithmetic.Handlers(Self);
        const ComparisonHandlers = handlers_comparison.Handlers(Self);
        const BitwiseHandlers = handlers_bitwise.Handlers(Self);
        const KeccakHandlers = handlers_keccak.Handlers(Self);
        const ContextHandlers = handlers_context.Handlers(Self);
        const BlockHandlers = handlers_block.Handlers(Self);
        const StackHandlers = handlers_stack.Handlers(Self);
        const MemoryHandlers = handlers_memory.Handlers(Self);
        const StorageHandlers = handlers_storage.Handlers(Self);
        const ControlFlowHandlers = handlers_control_flow.Handlers(Self);
        const LogHandlers = handlers_log.Handlers(Self);
        const SystemHandlers = handlers_system.Handlers(Self);

        stack: std.ArrayList(u256),
        memory: std.AutoHashMap(u32, u8),
        memory_size: u32,
        pc: u32,
        gas_remaining: i64,
        bytecode: Bytecode,
        caller: Address,
        address: Address,
        value: u256,
        calldata: []const u8,
        output: []u8,
        return_data: []const u8,
        stopped: bool,
        reverted: bool,
        evm_ptr: *anyopaque,
        allocator: std.mem.Allocator,
        authorized: ?u256,
        call_depth: u32,
        hardfork: Hardfork,
        is_static: bool,

        /// Initialize a new frame for bytecode execution
        ///
        /// Creates a new execution frame with the given parameters. Performs bytecode analysis
        /// to identify valid jump destinations (JUMPDEST opcodes).
        ///
        /// Parameters:
        ///   - allocator: Memory allocator for frame resources
        ///   - bytecode_raw: Raw bytecode to execute
        ///   - gas: Initial gas available for execution (signed for gas refunds)
        ///   - caller: Address that initiated this call
        ///   - address: Address being executed (contract address)
        ///   - value: Wei value transferred with this call
        ///   - calldata: Input data for the call
        ///   - evm_ptr: Opaque pointer to parent Evm instance
        ///   - hardfork: Active hardfork for gas metering and feature flags
        ///   - is_static: Whether this is a static call (no state modifications allowed)
        ///
        /// Returns: Initialized Frame instance
        ///
        /// Errors:
        ///   - OutOfMemory: If allocation fails for stack, memory, or bytecode analysis
        pub fn init(
            allocator: std.mem.Allocator,
            bytecode_raw: []const u8,
            gas: i64,
            caller: Address,
            address: Address,
            value: u256,
            calldata: []const u8,
            evm_ptr: *anyopaque,
            hardfork: Hardfork,
            is_static: bool,
        ) !Self {
            var stack = std.ArrayList(u256){};
            try stack.ensureTotalCapacity(allocator, 1024);
            errdefer stack.deinit(allocator);

            var memory_map = std.AutoHashMap(u32, u8).init(allocator);
            errdefer memory_map.deinit();

            // Analyze bytecode to identify valid jump destinations
            var bytecode = try Bytecode.init(allocator, bytecode_raw);
            errdefer bytecode.deinit();

            return Self{
                .stack = stack,
                .memory = memory_map,
                .memory_size = 0,
                .pc = 0,
                .gas_remaining = gas,
                .bytecode = bytecode,
                .caller = caller,
                .address = address,
                .value = value,
                .calldata = calldata,
                .output = &[_]u8{},
                .return_data = &[_]u8{},
                .stopped = false,
                .reverted = false,
                .evm_ptr = evm_ptr,
                .allocator = allocator,
                .authorized = null,
                .call_depth = 0,
                .hardfork = hardfork,
                .is_static = is_static,
            };
        }

        /// Clean up resources
        pub fn deinit(self: *Self) void {
            // Note: When using arena allocator from Evm, this becomes a no-op
            // The arena will clean up all memory at once when Evm is destroyed
            self.stack.deinit(self.allocator);
            self.memory.deinit();
            self.bytecode.deinit();
            // No need to free output or return_data when using arena
        }

        /// Get the Evm instance matching this Frame's config
        ///
        /// Retrieves a typed pointer to the parent EVM instance from the opaque pointer.
        /// This is a helper for instruction handlers that need to access EVM state
        /// (storage, balances, nested calls, etc.).
        ///
        /// Returns: Typed pointer to parent Evm instance with matching config
        pub fn getEvm(self: *Self) *evm_mod.Evm(config) {
            return @ptrCast(@alignCast(self.evm_ptr));
        }

        /// Push value onto stack
        pub fn pushStack(self: *Self, value: u256) EvmError!void {
            if (self.stack.items.len >= 1024) {
                return error.StackOverflow;
            }
            try self.stack.append(self.allocator, value);
        }

        /// Pop value from stack
        pub fn popStack(self: *Self) EvmError!u256 {
            if (self.stack.items.len == 0) {
                return error.StackUnderflow;
            }
            const value = self.stack.items[self.stack.items.len - 1];
            self.stack.items.len -= 1;
            return value;
        }

        /// Peek at top of stack
        pub fn peekStack(self: *const Self, index: usize) EvmError!u256 {
            if (index >= self.stack.items.len) {
                return error.StackUnderflow;
            }
            return self.stack.items[self.stack.items.len - 1 - index];
        }

        inline fn wordCount(bytes: u64) u64 {
            return (bytes + 31) / 32;
        }

        /// Calculate word-aligned memory size for EVM compliance
        pub inline fn wordAlignedSize(bytes: u64) u32 {
            const words = wordCount(bytes);
            return @intCast(words * 32);
        }

        /// Read byte from memory
        pub fn readMemory(self: *Self, offset: u32) u8 {
            return self.memory.get(offset) orelse 0;
        }

        /// Safe add helper for u32 indices
        inline fn add_u32(a: u32, b: u32) EvmError!u32 {
            return std.math.add(u32, a, b) catch return error.OutOfBounds;
        }

        /// Write byte to memory
        pub fn writeMemory(self: *Self, offset: u32, value: u8) EvmError!void {
            try self.memory.put(offset, value);
            // EVM memory expands to word-aligned (32-byte) boundaries
            const end_offset: u64 = @as(u64, offset) + 1;
            const word_aligned_size = wordAlignedSize(end_offset);
            if (word_aligned_size > self.memory_size) self.memory_size = word_aligned_size;
        }

        /// Get current opcode
        pub fn getCurrentOpcode(self: *const Self) ?u8 {
            return self.bytecode.getOpcode(self.pc);
        }

        /// Read immediate data for PUSH operations
        pub fn readImmediate(self: *const Self, size: u8) ?u256 {
            return self.bytecode.readImmediate(self.pc, size);
        }

        /// ----------------------------------- GAS ---------------------------------- ///
        /// Consume gas
        pub fn consumeGas(self: *Self, amount: u64) EvmError!void {
            // Check if amount is too large to fit in i64 or exceeds remaining gas
            if (amount > std.math.maxInt(i64) or self.gas_remaining < @as(i64, @intCast(amount))) {
                self.gas_remaining = 0;
                return error.OutOfGas;
            }
            self.gas_remaining -= @intCast(amount);
        }

        /// Calculate memory expansion cost
        /// The total memory cost for n words is: 3n + n²/512, where a word is 32 bytes.
        pub fn memoryExpansionCost(self: *const Self, end_bytes: u64) u64 {
            const current_size = @as(u64, self.memory_size);

            if (end_bytes <= current_size) return 0;

            // Cap memory size to prevent gas calculation overflow
            // Max reasonable memory is 16MB (0x1000000 bytes) which is ~500k words
            // At that size, gas cost would be ~125 billion, far exceeding any reasonable gas limit
            const max_memory: u64 = 0x1000000;
            // Return a large value that won't overflow when added to other gas costs
            // but will still trigger OutOfGas
            if (end_bytes > max_memory) return std.math.maxInt(u64);

            const current_words = wordCount(current_size);
            const new_words = wordCount(end_bytes);

            // Check for overflow in word * word calculation using saturating multiplication
            // If overflow would occur, return max gas to trigger OutOfGas
            const current_words_squared = std.math.mul(u64, current_words, current_words) catch return std.math.maxInt(u64);
            const new_words_squared = std.math.mul(u64, new_words, new_words) catch return std.math.maxInt(u64);

            // Calculate cost for each size with overflow protection
            const current_linear = std.math.mul(u64, GasConstants.MemoryGas, current_words) catch return std.math.maxInt(u64);
            const current_quadratic = current_words_squared / GasConstants.QuadCoeffDiv;
            const current_cost = std.math.add(u64, current_linear, current_quadratic) catch return std.math.maxInt(u64);

            const new_linear = std.math.mul(u64, GasConstants.MemoryGas, new_words) catch return std.math.maxInt(u64);
            const new_quadratic = new_words_squared / GasConstants.QuadCoeffDiv;
            const new_cost = std.math.add(u64, new_linear, new_quadratic) catch return std.math.maxInt(u64);

            return std.math.sub(u64, new_cost, current_cost) catch return std.math.maxInt(u64);
        }

        /// Calculate gas cost for external account operations (EIP-150, EIP-1884, EIP-2929 aware)
        /// Note: This returns 700 for Tangerine Whistle+ (EXTCODESIZE/EXTCODECOPY use this)
        /// BALANCE and EXTCODEHASH have their own gas cost calculations
        pub fn externalAccountGasCost(self: *Self, address: Address) !u64 {
            const evm = self.getEvm();

            if (self.hardfork.isAtLeast(.BERLIN)) {
                // Post-Berlin: Cold/warm access pattern (EIP-2929)
                @branchHint(.likely);
                return try evm.accessAddress(address);
            } else if (self.hardfork.isAtLeast(.TANGERINE_WHISTLE)) {
                // EIP-150 (Tangerine Whistle): EXTCODESIZE/EXTCODECOPY cost 700 gas
                return 700;
            } else {
                // Pre-EIP-150: Lower cost (20 gas)
                return 20;
            }
        }

        /// Calculate SELFDESTRUCT gas cost (EIP-150 aware)
        pub fn selfdestructGasCost(self: *const Self) u64 {
            if (self.hardfork.isBefore(.TANGERINE_WHISTLE)) {
                @branchHint(.cold);
                return 0; // Pre-EIP-150: Free operation
            }
            return GasConstants.SelfdestructGas; // Post-EIP-150: 5000 gas
        }

        /// Calculate SELFDESTRUCT refund (EIP-3529 aware)
        pub fn selfdestructRefund(self: *const Self) u64 {
            if (self.hardfork.isAtLeast(.LONDON)) {
                @branchHint(.likely);
                return 0; // EIP-3529: No refund in London+
            }
            return GasConstants.SelfdestructRefundGas; // Pre-London: 24,000 refund
        }

        /// Calculate CREATE gas cost (EIP-3860 aware)
        pub fn createGasCost(self: *const Self, init_code_size: u32) u64 {
            var gas_cost: u64 = GasConstants.CreateGas; // Base 32,000 gas

            if (self.hardfork.isAtLeast(.SHANGHAI)) {
                @branchHint(.likely);
                const word_count = wordCount(@as(u64, init_code_size));
                gas_cost += word_count * GasConstants.InitcodeWordGas;
            }

            return gas_cost;
        }

        /// Calculate CREATE2 gas cost (EIP-3860 aware)
        pub fn create2GasCost(self: *const Self, init_code_size: u32) u64 {
            var gas_cost: u64 = GasConstants.CreateGas; // Base 32,000 gas

            // Keccak256 hash cost for hashing init_code (per-word only, no base cost)
            // According to the reference implementation, CREATE2 only charges per-word cost
            const init_code_word_count = wordCount(@as(u64, init_code_size));
            gas_cost += init_code_word_count * GasConstants.Keccak256WordGas;

            if (self.hardfork.isAtLeast(.SHANGHAI)) {
                // Additional init code word cost (EIP-3860)
                @branchHint(.likely);
                gas_cost += init_code_word_count * GasConstants.InitcodeWordGas;
            }

            return gas_cost;
        }

        /// Calculate KECCAK256 gas cost (replaces manual calculation)
        fn keccak256GasCost(data_size: u32) u64 {
            const words = wordCount(@as(u64, data_size));
            return GasConstants.Keccak256Gas + words * GasConstants.Keccak256WordGas;
        }

        /// Calculate copy operation gas cost (replaces manual calculations)
        fn copyGasCost(size: u32) u64 {
            const words = wordCount(@as(u64, size));
            return GasConstants.CopyGas * words;
        }

        /// Calculate LOG operation gas cost (replaces manual calculation)
        fn logGasCost(topic_count: u8, data_size: u32) u64 {
            const base_cost = GasConstants.LogGas;
            const topic_cost = @as(u64, topic_count) * GasConstants.LogTopicGas;
            const data_cost = @as(u64, data_size) * GasConstants.LogDataGas;
            return base_cost + topic_cost + data_cost;
        }

        /// ----------------------------------- OPCODES ---------------------------------- ///
        /// Execute a single opcode - delegates to Evm for external ops
        ///
        /// Executes one EVM opcode instruction. Handles all standard EVM opcodes as well as
        /// custom opcode overrides (JavaScript handlers or native Zig handlers configured via EvmConfig).
        ///
        /// Handler priority:
        ///   1. JavaScript custom handlers (if registered via root_c.zig)
        ///   2. Native Zig custom handlers (configured via EvmConfig.opcode_overrides)
        ///   3. Default EVM opcode implementations
        ///
        /// Parameters:
        ///   - opcode: The opcode byte to execute (0x00-0xFF)
        ///
        /// Returns: void
        ///
        /// Errors:
        ///   - OutOfGas: If insufficient gas for operation
        ///   - StackUnderflow: If stack has insufficient items
        ///   - StackOverflow: If stack exceeds 1024 items
        ///   - InvalidJumpDestination: If JUMP/JUMPI targets invalid location
        ///   - StaticCallViolation: If state-modifying op in static context
        ///   - InvalidOpcode: If opcode is not recognized
        ///   - Other errors: Depending on specific opcode requirements
        pub fn executeOpcode(self: *Self, opcode: u8) EvmError!void {
            // Check for JavaScript custom opcode handler first
            const root_c = @import("root_c.zig");
            if (root_c.tryCallJsOpcodeHandler(opcode, @intFromPtr(self))) {
                // JavaScript handler executed successfully
                return;
            }

            // Check for config-based opcode override (native Zig handlers)
            const evm = self.getEvm();
            if (evm.getOpcodeOverride(opcode)) |handler_ptr| {
                // Cast the handler to the correct function type
                // Handler signature: fn(*Frame) FrameError!void
                const handler: *const fn (*Self) EvmError!void = @ptrCast(@alignCast(handler_ptr));
                return handler(self);
            }

            // Default opcode handling
            switch (opcode) {
                0x00 => try ControlFlowHandlers.stop(self),
                0x01 => try ArithmeticHandlers.add(self),
                0x02 => try ArithmeticHandlers.mul(self),
                0x03 => try ArithmeticHandlers.sub(self),
                0x04 => try ArithmeticHandlers.div(self),
                0x05 => try ArithmeticHandlers.sdiv(self),
                0x06 => try ArithmeticHandlers.mod(self),
                0x07 => try ArithmeticHandlers.smod(self),
                0x08 => try ArithmeticHandlers.addmod(self),
                0x09 => try ArithmeticHandlers.mulmod(self),
                0x0a => try ArithmeticHandlers.exp(self),
                0x0b => try ArithmeticHandlers.signextend(self),
                0x10 => try ComparisonHandlers.lt(self),
                0x11 => try ComparisonHandlers.gt(self),
                0x12 => try ComparisonHandlers.slt(self),
                0x13 => try ComparisonHandlers.sgt(self),
                0x14 => try ComparisonHandlers.eq(self),
                0x15 => try ComparisonHandlers.iszero(self),
                0x16 => try BitwiseHandlers.op_and(self),
                0x17 => try BitwiseHandlers.op_or(self),
                0x18 => try BitwiseHandlers.op_xor(self),
                0x19 => try BitwiseHandlers.op_not(self),
                0x1a => try BitwiseHandlers.byte(self),
                0x1b => try BitwiseHandlers.shl(self),
                0x1c => try BitwiseHandlers.shr(self),
                0x1d => try BitwiseHandlers.sar(self),
                0x20 => try KeccakHandlers.sha3(self),
                0x30 => try ContextHandlers.address(self),
                0x31 => try ContextHandlers.balance(self),
                0x32 => try ContextHandlers.origin(self),
                0x33 => try ContextHandlers.caller(self),
                0x34 => try ContextHandlers.callvalue(self),
                0x35 => try ContextHandlers.calldataload(self),
                0x36 => try ContextHandlers.calldatasize(self),
                0x37 => try ContextHandlers.calldatacopy(self),
                0x38 => try ContextHandlers.codesize(self),
                0x39 => try ContextHandlers.codecopy(self),
                0x3a => try ContextHandlers.gasprice(self),
                0x3b => try ContextHandlers.extcodesize(self),
                0x3c => try ContextHandlers.extcodecopy(self),
                0x3d => try ContextHandlers.returndatasize(self),
                0x3e => try ContextHandlers.returndatacopy(self),
                0x3f => try ContextHandlers.extcodehash(self),
                0x40 => try BlockHandlers.blockhash(self),
                0x41 => try BlockHandlers.coinbase(self),
                0x42 => try BlockHandlers.timestamp(self),
                0x43 => try BlockHandlers.number(self),
                0x44 => try BlockHandlers.difficulty(self),
                0x45 => try BlockHandlers.gaslimit(self),
                0x46 => try BlockHandlers.chainid(self),
                0x47 => try BlockHandlers.selfbalance(self),
                0x48 => try BlockHandlers.basefee(self),
                0x49 => try BlockHandlers.blobhash(self),
                0x4a => try BlockHandlers.blobbasefee(self),
                0x50 => try StackHandlers.pop(self),
                0x51 => try MemoryHandlers.mload(self),
                0x52 => try MemoryHandlers.mstore(self),
                0x53 => try MemoryHandlers.mstore8(self),
                0x54 => try StorageHandlers.sload(self),
                0x55 => try StorageHandlers.sstore(self),
                0x56 => try ControlFlowHandlers.jump(self),
                0x57 => try ControlFlowHandlers.jumpi(self),
                0x58 => try ControlFlowHandlers.pc(self),
                0x59 => try MemoryHandlers.msize(self),
                0x5a => try ContextHandlers.gas(self),
                0x5b => try ControlFlowHandlers.jumpdest(self),
                0x5c => try StorageHandlers.tload(self),
                0x5d => try StorageHandlers.tstore(self),
                0x5e => try MemoryHandlers.mcopy(self),
                0x5f...0x7f => try StackHandlers.push(self, opcode),
                0x80...0x8f => try StackHandlers.dup(self, opcode),
                0x90...0x9f => try StackHandlers.swap(self, opcode),
                0xa0...0xa4 => try LogHandlers.log(self, opcode),
                0xf0 => try SystemHandlers.create(self),
                0xf1 => try SystemHandlers.call(self),
                0xf2 => try SystemHandlers.callcode(self),
                0xf3 => try ControlFlowHandlers.ret(self),
                0xf4 => try SystemHandlers.delegatecall(self),
                0xf5 => try SystemHandlers.create2(self),
                0xfa => try SystemHandlers.staticcall(self),
                0xfd => try ControlFlowHandlers.revert(self),
                0xff => try SystemHandlers.selfdestruct(self),
                else => return error.InvalidOpcode,
            }
        }

        /// Get memory contents as a slice (for tracing)
        fn getMemorySlice(self: *Self, allocator: std.mem.Allocator) ![]u8 {
            if (self.memory_size == 0) return &[_]u8{};

            const mem_slice = try allocator.alloc(u8, self.memory_size);
            var i: u32 = 0;
            while (i < self.memory_size) : (i += 1) {
                mem_slice[i] = self.readMemory(i);
            }
            return mem_slice;
        }

        /// Execute a single step
        pub fn step(self: *Self) EvmError!void {
            if (self.stopped or self.reverted or self.pc >= self.bytecode.len()) {
                return;
            }
            const opcode = self.getCurrentOpcode() orelse return;

            // Capture trace before executing opcode
            const evm = self.getEvm();
            if (evm.tracer) |tracer| {
                const gas_before = @as(u64, @intCast(@max(self.gas_remaining, 0)));

                // Get memory slice for tracing
                const mem_slice = try self.getMemorySlice(self.allocator);

                // Execute opcode first to measure actual gas cost
                const pc_before = self.pc;
                try self.executeOpcode(opcode);
                const gas_after = @as(u64, @intCast(@max(self.gas_remaining, 0)));
                const actual_gas_cost = gas_before - gas_after;

                // Capture trace entry with actual gas cost
                try tracer.captureState(
                    @as(u64, pc_before),
                    opcode,
                    gas_before,
                    actual_gas_cost,
                    mem_slice,
                    self.stack.items,
                    self.return_data,
                    evm.frames.items.len,
                    @as(i64, @intCast(evm.gas_refund)),
                    opcode_utils.getOpName(opcode),
                );
                return;
            }

            try self.executeOpcode(opcode);
        }

        /// Main execution loop
        pub fn execute(self: *Self) EvmError!void {
            var iteration_count: u64 = 0;
            const max_iterations: u64 = 10_000_000; // Prevent infinite loops (reasonable limit ~10M ops)
            while (!self.stopped and !self.reverted and self.pc < self.bytecode.len()) {
                iteration_count += 1;
                if (iteration_count > max_iterations) {
                    return error.ExecutionTimeout;
                }
                try self.step();
            }
        }
    };
}
