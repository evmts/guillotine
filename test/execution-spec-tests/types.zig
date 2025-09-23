const std = @import("std");
const primitives = @import("primitives");

const Address = primitives.Address;
const Allocator = std.mem.Allocator;

/// Environment configuration for a test
pub const Env = struct {
    currentCoinbase: []const u8,
    currentGasLimit: []const u8,
    currentNumber: []const u8,
    currentTimestamp: []const u8,
    currentDifficulty: ?[]const u8 = null,
    currentRandom: ?[]const u8 = null,
    currentBaseFee: ?[]const u8 = null,
    currentBlobBaseFee: ?[]const u8 = null,
};

/// Account state
pub const AccountState = struct {
    nonce: []const u8,
    balance: []const u8,
    code: []const u8,
    storage: std.json.Value,
};

/// Transaction data
pub const Transaction = struct {
    nonce: []const u8,
    gasPrice: ?[]const u8 = null,  // Legacy transactions
    maxFeePerGas: ?[]const u8 = null,  // EIP-1559 transactions
    maxPriorityFeePerGas: ?[]const u8 = null,  // EIP-1559 transactions
    gasLimit: [][]const u8,
    to: ?[]const u8,
    value: [][]const u8,
    data: [][]const u8,
    sender: []const u8,
    secretKey: []const u8
};

/// Post state entry
pub const PostStateEntry = struct {
    hash: []const u8,
    logs: []const u8,
    txbytes: []const u8,
    indexes: struct {
        data: usize,
        gas: usize,
        value: usize,
    },
    state: std.json.Value,
};

/// Complete test case
pub const TestCase = struct {
    env: Env,
    pre: std.json.Value,
    transaction: Transaction,
    post: std.json.Value,
    config: struct {
        chainid: []const u8,
    },
    _info: ?std.json.Value = null,

    pub fn deinit(self: *TestCase, allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }
};