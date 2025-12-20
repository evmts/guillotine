/// Testing utilities for instruction handler validation
///
/// This module provides reusable test fixtures, builders, and assertion helpers
/// for testing EVM instruction handlers in isolation or integration.
///
/// Usage example:
/// ```zig
/// test "ADD instruction" {
///     var helper = try TestHelper.init(testing.allocator);
///     defer helper.deinit();
///
///     // Setup: push two values onto stack
///     try helper.pushStack(10);
///     try helper.pushStack(20);
///
///     // Execute: run ADD handler
///     try helper.frame.handlers.arithmetic.add(&helper.frame);
///
///     // Assert: verify result
///     try helper.assertStackTop(30);
///     try helper.assertGasConsumed(GasConstants.GasFastestStep);
/// }
/// ```
const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const evm_mod = @import("../evm.zig");
const frame_mod = @import("../frame.zig");
const EvmConfig = @import("../evm_config.zig").EvmConfig;
const GasConstants = primitives.GasConstants;
const Address = primitives.Address.Address;
const Hardfork = primitives.Hardfork;

/// Default EVM configuration for testing
pub const DefaultTestConfig = EvmConfig{
    .hardfork = .CANCUN,
    .stack_size = 1024,
    .max_bytecode_size = 24576,
    .max_call_depth = 1024,
};

/// Creates a configured Frame type for testing
pub const TestFrameType = frame_mod.Frame(DefaultTestConfig);
/// Creates a configured EVM type for testing
pub const TestEvmType = evm_mod.Evm(DefaultTestConfig);

/// Block context for testing - provides sensible defaults
pub const TestBlockContext = evm_mod.BlockContext{
    .chain_id = 1, // Ethereum mainnet
    .block_number = 1000000,
    .block_timestamp = 1234567890,
    .block_difficulty = 0,
    .block_prevrandao = 0x1234567890abcdef,
    .block_coinbase = Address.fromU256(0xC014BA5E), // "COINBASE"
    .block_gas_limit = 30_000_000,
    .block_base_fee = 1_000_000_000, // 1 gwei
    .blob_base_fee = 1, // EIP-4844
    .block_hashes = &[_][32]u8{},
};

/// Main test helper providing frame and EVM setup with builder pattern
pub const TestHelper = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    evm: *TestEvmType,
    frame: *TestFrameType,
    initial_gas: i64,
    owned_bytecode: []u8,

    /// Initialize a test helper with default configuration
    ///
    /// Creates a minimal execution environment with:
    /// - Empty bytecode (can be overridden with `withBytecode`)
    /// - 1,000,000 gas
    /// - Zero-value call from 0x0 to 0x0
    /// - Cancun hardfork
    ///
    /// Returns: Initialized TestHelper
    /// Errors: OutOfMemory if allocation fails
    pub fn init(allocator: std.mem.Allocator) !Self {
        return initWithConfig(allocator, DefaultTestConfig);
    }

    /// Initialize with custom EVM configuration
    pub fn initWithConfig(allocator: std.mem.Allocator, config: EvmConfig) !Self {
        // Create EVM instance
        var evm = try allocator.create(TestEvmType);
        errdefer allocator.destroy(evm);

        evm.* = try TestEvmType.init(
            allocator,
            null, // no host interface (self-contained)
            config.hardfork,
            TestBlockContext,
            null, // no custom log level
        );
        errdefer evm.deinit();

        // Initialize transaction state (required for storage operations)
        try evm.initTransactionState(null);

        // Create frame with empty bytecode
        const initial_gas: i64 = 1_000_000;
        const empty_bytecode = try allocator.alloc(u8, 0);
        errdefer allocator.free(empty_bytecode);

        const frame = try allocator.create(TestFrameType);
        errdefer allocator.destroy(frame);

        frame.* = try TestFrameType.init(
            allocator,
            empty_bytecode,
            initial_gas,
            Address.fromU256(0), // caller
            Address.fromU256(0), // address
            0, // value
            &[_]u8{}, // calldata
            @ptrCast(evm),
            config.hardfork,
            false, // not static call
        );

        return Self{
            .allocator = allocator,
            .evm = evm,
            .frame = frame,
            .initial_gas = initial_gas,
            .owned_bytecode = empty_bytecode,
        };
    }

    /// Clean up all resources
    pub fn deinit(self: *Self) void {
        self.frame.deinit();
        self.allocator.destroy(self.frame);
        self.evm.deinit();
        self.allocator.destroy(self.evm);
        self.allocator.free(self.owned_bytecode);
    }

    // =============================================================================
    // Builder Methods - Chainable Configuration
    // =============================================================================

    /// Replace frame bytecode (useful for testing jump destinations, push operations)
    ///
    /// Example:
    /// ```zig
    /// try helper.withBytecode(&[_]u8{ 0x60, 0x42 }); // PUSH1 0x42
    /// ```
    pub fn withBytecode(self: *Self, bytecode: []const u8) !void {
        // Free old bytecode
        self.allocator.free(self.owned_bytecode);

        // Allocate new bytecode
        self.owned_bytecode = try self.allocator.dupe(u8, bytecode);

        // Recreate frame with new bytecode
        const old_frame = self.frame;
        const gas = old_frame.gas_remaining;
        const caller = old_frame.caller;
        const address = old_frame.address;
        const value = old_frame.value;
        const calldata = old_frame.calldata;
        const hardfork = old_frame.hardfork;
        const is_static = old_frame.is_static;

        old_frame.deinit();

        self.frame.* = try TestFrameType.init(
            self.allocator,
            self.owned_bytecode,
            gas,
            caller,
            address,
            value,
            calldata,
            @ptrCast(self.evm),
            hardfork,
            is_static,
        );
    }

    /// Set hardfork for testing fork-specific behavior
    pub fn withHardfork(self: *Self, hardfork: Hardfork) void {
        self.frame.hardfork = hardfork;
        self.evm.hardfork = hardfork;
    }

    /// Set caller address
    pub fn withCaller(self: *Self, caller: Address) void {
        self.frame.caller = caller;
    }

    /// Set execution address
    pub fn withAddress(self: *Self, address: Address) void {
        self.frame.address = address;
    }

    /// Set call value
    pub fn withValue(self: *Self, value: u256) void {
        self.frame.value = value;
    }

    /// Set calldata
    pub fn withCalldata(self: *Self, calldata: []const u8) void {
        self.frame.calldata = calldata;
    }

    /// Set static call mode
    pub fn withStaticCall(self: *Self, is_static: bool) void {
        self.frame.is_static = is_static;
    }

    /// Set initial gas
    pub fn withGas(self: *Self, gas: i64) void {
        self.frame.gas_remaining = gas;
        self.initial_gas = gas;
    }

    // =============================================================================
    // Stack Manipulation
    // =============================================================================

    /// Push value onto stack
    pub fn pushStack(self: *Self, value: u256) !void {
        try self.frame.pushStack(value);
    }

    /// Push multiple values onto stack (left to right, left = bottom)
    ///
    /// Example:
    /// ```zig
    /// try helper.pushStackSlice(&[_]u256{ 10, 20, 30 });
    /// // Stack: [10, 20, 30] where 30 is top
    /// ```
    pub fn pushStackSlice(self: *Self, values: []const u256) !void {
        for (values) |value| {
            try self.frame.pushStack(value);
        }
    }

    /// Pop value from stack
    pub fn popStack(self: *Self) !u256 {
        return try self.frame.popStack();
    }

    /// Clear all stack items
    pub fn clearStack(self: *Self) void {
        self.frame.stack.clearRetainingCapacity();
    }

    /// Get stack size
    pub fn stackSize(self: *Self) usize {
        return self.frame.stack.items.len;
    }

    /// Peek at stack top without removing
    pub fn peekStack(self: *Self, depth: usize) !u256 {
        if (self.frame.stack.items.len <= depth) {
            return error.StackUnderflow;
        }
        return self.frame.stack.items[self.frame.stack.items.len - 1 - depth];
    }

    // =============================================================================
    // Memory Manipulation
    // =============================================================================

    /// Write bytes to memory at offset
    pub fn writeMemory(self: *Self, offset: u32, data: []const u8) !void {
        for (data, 0..) |byte, i| {
            try self.frame.memory.put(@intCast(offset + i), byte);
        }
        // Update memory size if needed
        const new_size = offset + @as(u32, @intCast(data.len));
        if (new_size > self.frame.memory_size) {
            self.frame.memory_size = new_size;
        }
    }

    /// Read bytes from memory at offset
    pub fn readMemory(self: *Self, offset: u32, length: u32) ![]u8 {
        const result = try self.allocator.alloc(u8, length);
        for (0..length) |i| {
            result[i] = self.frame.memory.get(@intCast(offset + i)) orelse 0;
        }
        return result;
    }

    /// Clear all memory
    pub fn clearMemory(self: *Self) void {
        self.frame.memory.clearRetainingCapacity();
        self.frame.memory_size = 0;
    }

    // =============================================================================
    // Storage Manipulation (EVM-level)
    // =============================================================================

    /// Set storage value for current address
    pub fn setStorage(self: *Self, slot: u256, value: u256) !void {
        try self.evm.storage.set(self.frame.address, slot, value);
    }

    /// Get storage value for current address
    pub fn getStorage(self: *Self, slot: u256) !u256 {
        return try self.evm.storage.get(self.frame.address, slot);
    }

    /// Set transient storage (EIP-1153, Cancun+)
    pub fn setTransientStorage(self: *Self, slot: u256, value: u256) !void {
        try self.evm.storage.setTransient(self.frame.address, slot, value);
    }

    /// Get transient storage
    pub fn getTransientStorage(self: *Self, slot: u256) u256 {
        return self.evm.storage.getTransient(self.frame.address, slot);
    }

    // =============================================================================
    // State Manipulation
    // =============================================================================

    /// Set balance for an address
    pub fn setBalance(self: *Self, address: Address, balance: u256) !void {
        try self.evm.balances.put(address, balance);
    }

    /// Get balance for an address
    pub fn getBalance(self: *Self, address: Address) u256 {
        return self.evm.balances.get(address) orelse 0;
    }

    /// Set nonce for an address
    pub fn setNonce(self: *Self, address: Address, nonce: u64) !void {
        try self.evm.nonces.put(address, nonce);
    }

    /// Get nonce for an address
    pub fn getNonce(self: *Self, address: Address) u64 {
        return self.evm.nonces.get(address) orelse 0;
    }

    /// Set code for an address
    pub fn setCode(self: *Self, address: Address, code: []const u8) !void {
        const owned_code = try self.allocator.dupe(u8, code);
        try self.evm.code.put(address, owned_code);
    }

    // =============================================================================
    // Assertions - Stack
    // =============================================================================

    /// Assert stack top equals expected value
    pub fn assertStackTop(self: *Self, expected: u256) !void {
        const actual = try self.peekStack(0);
        try testing.expectEqual(expected, actual);
    }

    /// Assert stack at depth equals expected value (0 = top)
    pub fn assertStackAt(self: *Self, depth: usize, expected: u256) !void {
        const actual = try self.peekStack(depth);
        try testing.expectEqual(expected, actual);
    }

    /// Assert stack size
    pub fn assertStackSize(self: *Self, expected: usize) !void {
        try testing.expectEqual(expected, self.stackSize());
    }

    /// Assert stack contains values in order (top to bottom)
    ///
    /// Example:
    /// ```zig
    /// // Stack: [10, 20, 30] (30 is top)
    /// try helper.assertStackEquals(&[_]u256{ 30, 20, 10 });
    /// ```
    pub fn assertStackEquals(self: *Self, expected: []const u256) !void {
        try testing.expectEqual(expected.len, self.frame.stack.items.len);
        for (expected, 0..) |exp_val, i| {
            const actual_val = try self.peekStack(i);
            try testing.expectEqual(exp_val, actual_val);
        }
    }

    /// Assert stack is empty
    pub fn assertStackEmpty(self: *Self) !void {
        try testing.expectEqual(@as(usize, 0), self.stackSize());
    }

    // =============================================================================
    // Assertions - Memory
    // =============================================================================

    /// Assert memory at offset equals expected bytes
    pub fn assertMemoryEquals(self: *Self, offset: u32, expected: []const u8) !void {
        const actual = try self.readMemory(offset, @intCast(expected.len));
        defer self.allocator.free(actual);
        try testing.expectEqualSlices(u8, expected, actual);
    }

    /// Assert memory byte at offset
    pub fn assertMemoryByte(self: *Self, offset: u32, expected: u8) !void {
        const actual = self.frame.memory.get(offset) orelse 0;
        try testing.expectEqual(expected, actual);
    }

    /// Assert memory size
    pub fn assertMemorySize(self: *Self, expected: u32) !void {
        try testing.expectEqual(expected, self.frame.memory_size);
    }

    // =============================================================================
    // Assertions - Gas
    // =============================================================================

    /// Assert exact gas consumed since initialization
    pub fn assertGasConsumed(self: *Self, expected: i64) !void {
        const actual = self.initial_gas - self.frame.gas_remaining;
        try testing.expectEqual(expected, actual);
    }

    /// Assert gas remaining
    pub fn assertGasRemaining(self: *Self, expected: i64) !void {
        try testing.expectEqual(expected, self.frame.gas_remaining);
    }

    /// Assert gas consumed is at least the given amount
    pub fn assertGasConsumedAtLeast(self: *Self, minimum: i64) !void {
        const actual = self.initial_gas - self.frame.gas_remaining;
        try testing.expect(actual >= minimum);
    }

    // =============================================================================
    // Assertions - Storage
    // =============================================================================

    /// Assert storage value at slot for current address
    pub fn assertStorage(self: *Self, slot: u256, expected: u256) !void {
        const actual = try self.getStorage(slot);
        try testing.expectEqual(expected, actual);
    }

    /// Assert transient storage value at slot
    pub fn assertTransientStorage(self: *Self, slot: u256, expected: u256) !void {
        const actual = self.getTransientStorage(slot);
        try testing.expectEqual(expected, actual);
    }

    // =============================================================================
    // Assertions - State
    // =============================================================================

    /// Assert frame stopped flag
    pub fn assertStopped(self: *Self, expected: bool) !void {
        try testing.expectEqual(expected, self.frame.stopped);
    }

    /// Assert frame reverted flag
    pub fn assertReverted(self: *Self, expected: bool) !void {
        try testing.expectEqual(expected, self.frame.reverted);
    }

    /// Assert program counter
    pub fn assertPC(self: *Self, expected: u32) !void {
        try testing.expectEqual(expected, self.frame.pc);
    }

    /// Assert return data
    pub fn assertReturnData(self: *Self, expected: []const u8) !void {
        try testing.expectEqualSlices(u8, expected, self.frame.return_data);
    }

    // =============================================================================
    // Error Assertion Helpers
    // =============================================================================

    /// Expect a specific error when executing a function
    ///
    /// Example:
    /// ```zig
    /// try helper.expectError(error.StackUnderflow, helper.frame.popStack());
    /// ```
    pub fn expectError(self: *Self, expected_error: anyerror, result: anytype) !void {
        _ = self;
        try testing.expectError(expected_error, result);
    }
};

// =============================================================================
// Convenience Functions
// =============================================================================

/// Create a test address from a u256 value
pub fn testAddress(value: u256) Address {
    return Address.fromU256(value);
}

/// Create test addresses for common scenarios
pub const TestAddresses = struct {
    pub const zero = testAddress(0);
    pub const caller = testAddress(0xCA11E4);
    pub const contract = testAddress(0xC047AC7);
    pub const other = testAddress(0x07BE4);
    pub const precompile_ecrecover = testAddress(1);
    pub const precompile_sha256 = testAddress(2);
    pub const precompile_ripemd160 = testAddress(3);
    pub const precompile_identity = testAddress(4);
};

/// Helper to create bytecode from hex string
///
/// Example:
/// ```zig
/// const code = try bytecodeFromHex(allocator, "60426000526001601ff3");
/// defer allocator.free(code);
/// ```
pub fn bytecodeFromHex(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHexLength;

    var result = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(result);

    for (0..result.len) |i| {
        const hi = try std.fmt.charToDigit(hex[i * 2], 16);
        const lo = try std.fmt.charToDigit(hex[i * 2 + 1], 16);
        result[i] = (hi << 4) | lo;
    }

    return result;
}

// =============================================================================
// Tests for Test Helpers
// =============================================================================

test "TestHelper - initialization and cleanup" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try testing.expect(helper.frame.gas_remaining > 0);
    try testing.expectEqual(@as(usize, 0), helper.stackSize());
}

test "TestHelper - stack manipulation" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // Push values
    try helper.pushStack(10);
    try helper.pushStack(20);
    try helper.pushStack(30);

    // Assert stack state
    try helper.assertStackSize(3);
    try helper.assertStackTop(30);
    try helper.assertStackAt(1, 20);
    try helper.assertStackAt(2, 10);

    // Pop value
    const val = try helper.popStack();
    try testing.expectEqual(@as(u256, 30), val);
    try helper.assertStackSize(2);
}

test "TestHelper - stack slice operations" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try helper.pushStackSlice(&[_]u256{ 100, 200, 300 });
    try helper.assertStackEquals(&[_]u256{ 300, 200, 100 });
}

test "TestHelper - memory operations" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    try helper.writeMemory(0, &data);

    try helper.assertMemoryByte(0, 0xDE);
    try helper.assertMemoryByte(1, 0xAD);
    try helper.assertMemoryEquals(0, &data);
    try helper.assertMemorySize(4);
}

test "TestHelper - storage operations" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try helper.setStorage(0x42, 0x1234);
    try helper.assertStorage(0x42, 0x1234);

    const val = try helper.getStorage(0x42);
    try testing.expectEqual(@as(u256, 0x1234), val);
}

test "TestHelper - transient storage" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    helper.withHardfork(.CANCUN);

    try helper.setTransientStorage(0x100, 0xABCD);
    try helper.assertTransientStorage(0x100, 0xABCD);
}

test "TestHelper - gas tracking" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    const initial = helper.frame.gas_remaining;
    try helper.frame.consumeGas(GasConstants.GasFastestStep);

    try helper.assertGasConsumed(GasConstants.GasFastestStep);
    try helper.assertGasRemaining(initial - GasConstants.GasFastestStep);
}

test "TestHelper - builder pattern" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    helper.withHardfork(.BERLIN);
    helper.withCaller(TestAddresses.caller);
    helper.withAddress(TestAddresses.contract);
    helper.withValue(1000);
    helper.withGas(50000);

    try testing.expectEqual(Hardfork.BERLIN, helper.frame.hardfork);
    try testing.expect(TestAddresses.caller.equals(helper.frame.caller));
    try testing.expect(TestAddresses.contract.equals(helper.frame.address));
    try testing.expectEqual(@as(u256, 1000), helper.frame.value);
    try testing.expectEqual(@as(i64, 50000), helper.frame.gas_remaining);
}

test "TestHelper - bytecode operations" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // Set bytecode: PUSH1 0x42
    try helper.withBytecode(&[_]u8{ 0x60, 0x42 });
    try testing.expectEqual(@as(usize, 2), helper.frame.bytecode.code.len);
}

test "TestHelper - state operations" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    const addr = testAddress(0x1234);
    try helper.setBalance(addr, 5000);
    try helper.setNonce(addr, 10);

    try testing.expectEqual(@as(u256, 5000), helper.getBalance(addr));
    try testing.expectEqual(@as(u64, 10), helper.getNonce(addr));
}

test "bytecodeFromHex - valid hex" {
    const code = try bytecodeFromHex(testing.allocator, "60426000526001601ff3");
    defer testing.allocator.free(code);

    try testing.expectEqual(@as(usize, 10), code.len);
    try testing.expectEqual(@as(u8, 0x60), code[0]);
    try testing.expectEqual(@as(u8, 0x42), code[1]);
}

test "bytecodeFromHex - invalid hex length" {
    try testing.expectError(error.InvalidHexLength, bytecodeFromHex(testing.allocator, "6042600"));
}

test "TestAddresses - constants" {
    try testing.expect(TestAddresses.zero.equals(testAddress(0)));
    try testing.expect(TestAddresses.precompile_ecrecover.equals(testAddress(1)));
}
