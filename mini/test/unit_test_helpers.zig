/// Test helper utilities for instruction handler unit tests
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const Hardfork = primitives.Hardfork;
const evm_mod = @import("evm");
const Evm = evm_mod.Evm;
const Frame = evm_mod.Frame;

/// Mock EVM for testing instruction handlers in isolation
pub const MockEvm = struct {
    allocator: std.mem.Allocator,
    evm: *Evm,

    pub fn init(allocator: std.mem.Allocator, hardfork: Hardfork) !MockEvm {
        var evm = try allocator.create(Evm);
        evm.* = try Evm.init(
            allocator,
            .{
                .gas_limit = 10_000_000,
                .base_fee_per_gas = 1,
                .chain_id = 1,
                .block_number = 1,
                .timestamp = 1000,
                .coinbase = try Address.fromHex("0x0000000000000000000000000000000000000000"),
                .prevrandao = 0,
                .blob_base_fee = 1,
            },
            hardfork,
        );
        return .{ .allocator = allocator, .evm = evm };
    }

    pub fn deinit(self: *MockEvm) void {
        self.evm.deinit();
        self.allocator.destroy(self.evm);
    }
};

/// Test frame builder for instruction handler testing
pub const TestFrameBuilder = struct {
    allocator: std.mem.Allocator,
    bytecode: []const u8 = &.{},
    gas: i64 = 1_000_000,
    caller: Address = undefined,
    address: Address = undefined,
    value: u256 = 0,
    calldata: []const u8 = &.{},
    hardfork: Hardfork = .CANCUN,
    is_static: bool = false,
    initial_stack: []const u256 = &.{},

    pub fn init(allocator: std.mem.Allocator) !TestFrameBuilder {
        return .{
            .allocator = allocator,
            .caller = try Address.fromHex("0x1111111111111111111111111111111111111111"),
            .address = try Address.fromHex("0x2222222222222222222222222222222222222222"),
        };
    }

    pub fn withBytecode(self: TestFrameBuilder, bytecode: []const u8) TestFrameBuilder {
        var copy = self;
        copy.bytecode = bytecode;
        return copy;
    }

    pub fn withGas(self: TestFrameBuilder, gas: i64) TestFrameBuilder {
        var copy = self;
        copy.gas = gas;
        return copy;
    }

    pub fn withHardfork(self: TestFrameBuilder, hardfork: Hardfork) TestFrameBuilder {
        var copy = self;
        copy.hardfork = hardfork;
        return copy;
    }

    pub fn withStatic(self: TestFrameBuilder, is_static: bool) TestFrameBuilder {
        var copy = self;
        copy.is_static = is_static;
        return copy;
    }

    pub fn withValue(self: TestFrameBuilder, value: u256) TestFrameBuilder {
        var copy = self;
        copy.value = value;
        return copy;
    }

    pub fn withCalldata(self: TestFrameBuilder, calldata: []const u8) TestFrameBuilder {
        var copy = self;
        copy.calldata = calldata;
        return copy;
    }

    pub fn withStack(self: TestFrameBuilder, stack: []const u256) TestFrameBuilder {
        var copy = self;
        copy.initial_stack = stack;
        return copy;
    }

    pub fn build(self: TestFrameBuilder, evm: *Evm) !Frame {
        var frame = try Frame.init(
            self.allocator,
            self.bytecode,
            self.gas,
            self.caller,
            self.address,
            self.value,
            self.calldata,
            evm,
            self.hardfork,
            self.is_static,
        );

        // Push initial stack values
        for (self.initial_stack) |val| {
            try frame.pushStack(val);
        }

        return frame;
    }
};

/// Helper to create simple bytecode for testing
pub fn bytecode(opcodes: []const u8) []const u8 {
    return opcodes;
}

/// Helper to create PUSH1 instruction
pub fn push1(value: u8) [2]u8 {
    return .{ 0x60, value };
}

/// Helper to create PUSH32 instruction with u256 value
pub fn push32(value: u256) [33]u8 {
    var result: [33]u8 = undefined;
    result[0] = 0x7f; // PUSH32 opcode
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        result[1 + i] = @truncate(value >> @intCast((31 - i) * 8));
    }
    return result;
}

/// Helper to concatenate bytecode
pub fn concat(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var total_len: usize = 0;
    for (parts) |part| total_len += part.len;

    var result = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    for (parts) |part| {
        @memcpy(result[offset..][0..part.len], part);
        offset += part.len;
    }
    return result;
}

/// Test assertions for frame state
pub const FrameAssertions = struct {
    frame: *Frame,
    testing: @TypeOf(std.testing),

    pub fn init(frame: *Frame) FrameAssertions {
        return .{ .frame = frame, .testing = std.testing };
    }

    pub fn expectStackTop(self: FrameAssertions, expected: u256) !void {
        try self.testing.expectEqual(expected, try self.frame.peekStack());
    }

    pub fn expectStackDepth(self: FrameAssertions, expected: usize) !void {
        try self.testing.expectEqual(expected, self.frame.stack.items.len);
    }

    pub fn expectGasRemaining(self: FrameAssertions, expected: i64) !void {
        try self.testing.expectEqual(expected, self.frame.gas_remaining);
    }

    pub fn expectGasConsumed(self: FrameAssertions, initial_gas: i64, expected_consumed: i64) !void {
        try self.testing.expectEqual(expected_consumed, initial_gas - self.frame.gas_remaining);
    }

    pub fn expectPc(self: FrameAssertions, expected: u32) !void {
        try self.testing.expectEqual(expected, self.frame.pc);
    }

    pub fn expectStopped(self: FrameAssertions, expected: bool) !void {
        try self.testing.expectEqual(expected, self.frame.stopped);
    }

    pub fn expectReverted(self: FrameAssertions, expected: bool) !void {
        try self.testing.expectEqual(expected, self.frame.reverted);
    }

    pub fn expectMemorySize(self: FrameAssertions, expected: u32) !void {
        try self.testing.expectEqual(expected, self.frame.memory_size);
    }
};
