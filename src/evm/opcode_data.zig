/// Opcode metadata and gas cost information for EVM operations
/// 
/// Provides structured data about each EVM opcode including:
/// - Gas costs (base costs, some opcodes have dynamic costs calculated at runtime)
/// - Stack requirements (inputs consumed and outputs produced)
/// - Opcode categories and properties
/// - Hard fork compatibility information
/// 
/// This data drives the jump table dispatch system and bytecode validation.
const std = @import("std");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
pub const Opcode = @import("opcode.zig").Opcode;

/// Combined opcode metadata for better cache efficiency
pub const OpcodeInfo = struct {
    gas_cost: u16,
    stack_inputs: u4,
    stack_outputs: u4,
};

/// Static opcode information for all 256 opcodes
pub const OPCODE_INFO = blk: {
    var info: [256]OpcodeInfo = [_]OpcodeInfo{.{ .gas_cost = 0, .stack_inputs = 0, .stack_outputs = 0 }} ** 256;

    // 0x00s: Stop and Arithmetic Operations
    info[@intFromEnum(Opcode.STOP)] = .{ .gas_cost = 0, .stack_inputs = 0, .stack_outputs = 0 };
    info[@intFromEnum(Opcode.ADD)] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1 };
    info[@intFromEnum(Opcode.MUL)] = .{ .gas_cost = GasConstants.GasFastStep, .stack_inputs = 2, .stack_outputs = 1 };
    info[@intFromEnum(Opcode.SUB)] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1 };
    info[0x04] = .{ .gas_cost = GasConstants.GasFastStep, .stack_inputs = 2, .stack_outputs = 1 }; // DIV
    info[0x05] = .{ .gas_cost = GasConstants.GasFastStep, .stack_inputs = 2, .stack_outputs = 1 }; // SDIV
    info[0x06] = .{ .gas_cost = GasConstants.GasFastStep, .stack_inputs = 2, .stack_outputs = 1 }; // MOD
    info[0x07] = .{ .gas_cost = GasConstants.GasFastStep, .stack_inputs = 2, .stack_outputs = 1 }; // SMOD
    info[0x08] = .{ .gas_cost = GasConstants.GasMidStep, .stack_inputs = 3, .stack_outputs = 1 }; // ADDMOD
    info[0x09] = .{ .gas_cost = GasConstants.GasMidStep, .stack_inputs = 3, .stack_outputs = 1 }; // MULMOD
    info[0x0a] = .{ .gas_cost = 10, .stack_inputs = 2, .stack_outputs = 1 }; // EXP (dynamic, base cost)
    info[0x0b] = .{ .gas_cost = GasConstants.GasFastStep, .stack_inputs = 2, .stack_outputs = 1 }; // SIGNEXTEND

    // 0x10s: Comparison & Bitwise Logic Operations
    info[0x10] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1 }; // LT
    info[0x11] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1 }; // GT
    info[0x12] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1 }; // SLT
    info[0x13] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1 }; // SGT
    info[0x14] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1 }; // EQ
    info[0x15] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 1, .stack_outputs = 1 }; // ISZERO
    info[0x16] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1 }; // AND
    info[0x17] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1 }; // OR
    info[0x18] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1 }; // XOR
    info[0x19] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 1, .stack_outputs = 1 }; // NOT
    info[0x1a] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1 }; // BYTE
    info[0x1b] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1 }; // SHL
    info[0x1c] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1 }; // SHR
    info[0x1d] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1 }; // SAR

    // 0x20s: Crypto
    info[0x20] = .{ .gas_cost = 30, .stack_inputs = 2, .stack_outputs = 1 }; // SHA3/KECCAK256 (dynamic, base cost)

    // 0x30s: Environmental Information
    info[0x30] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // ADDRESS
    info[0x31] = .{ .gas_cost = 100, .stack_inputs = 1, .stack_outputs = 1 }; // BALANCE (warm access)
    info[0x32] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // ORIGIN
    info[0x33] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // CALLER
    info[0x34] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // CALLVALUE
    info[0x35] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 1, .stack_outputs = 1 }; // CALLDATALOAD
    info[0x36] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // CALLDATASIZE
    info[0x37] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 3, .stack_outputs = 0 }; // CALLDATACOPY (dynamic, base cost)
    info[0x38] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // CODESIZE
    info[0x39] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 3, .stack_outputs = 0 }; // CODECOPY (dynamic, base cost)
    info[0x3a] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // GASPRICE
    info[0x3b] = .{ .gas_cost = 100, .stack_inputs = 1, .stack_outputs = 1 }; // EXTCODESIZE (warm access)
    info[0x3c] = .{ .gas_cost = 100, .stack_inputs = 4, .stack_outputs = 0 }; // EXTCODECOPY (warm access, dynamic)
    info[0x3d] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // RETURNDATASIZE
    info[0x3e] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 3, .stack_outputs = 0 }; // RETURNDATACOPY (dynamic, base cost)
    info[0x3f] = .{ .gas_cost = 100, .stack_inputs = 1, .stack_outputs = 1 }; // EXTCODEHASH (warm access)

    // 0x40s: Block Information
    info[0x40] = .{ .gas_cost = 20, .stack_inputs = 1, .stack_outputs = 1 }; // BLOCKHASH
    info[0x41] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // COINBASE
    info[0x42] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // TIMESTAMP
    info[0x43] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // NUMBER
    info[0x44] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // DIFFICULTY/PREVRANDAO
    info[0x45] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // GASLIMIT
    info[0x46] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // CHAINID
    info[0x47] = .{ .gas_cost = GasConstants.GasFastStep, .stack_inputs = 0, .stack_outputs = 1 }; // SELFBALANCE
    info[0x48] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // BASEFEE
    info[0x49] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 1, .stack_outputs = 1 }; // BLOBHASH
    info[0x4a] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // BLOBBASEFEE

    // 0x50s: Stack, Memory, Storage and Flow Operations
    info[@intFromEnum(Opcode.POP)] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 1, .stack_outputs = 0 };
    info[0x51] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 1, .stack_outputs = 1 }; // MLOAD (dynamic)
    info[0x52] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 0 }; // MSTORE (dynamic)
    info[0x53] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 0 }; // MSTORE8 (dynamic)
    info[0x54] = .{ .gas_cost = 100, .stack_inputs = 1, .stack_outputs = 1 }; // SLOAD (warm access)
    info[0x55] = .{ .gas_cost = 100, .stack_inputs = 2, .stack_outputs = 0 }; // SSTORE (warm access, dynamic)
    info[0x56] = .{ .gas_cost = GasConstants.GasMidStep, .stack_inputs = 1, .stack_outputs = 0 }; // JUMP
    info[0x57] = .{ .gas_cost = 10, .stack_inputs = 2, .stack_outputs = 0 }; // JUMPI
    info[0x58] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // PC
    info[0x59] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // MSIZE
    info[0x5a] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 }; // GAS
    info[0x5b] = .{ .gas_cost = 1, .stack_inputs = 0, .stack_outputs = 0 }; // JUMPDEST
    info[0x5c] = .{ .gas_cost = 100, .stack_inputs = 1, .stack_outputs = 1 }; // TLOAD (warm access)
    info[0x5d] = .{ .gas_cost = 100, .stack_inputs = 2, .stack_outputs = 0 }; // TSTORE (warm access)
    info[0x5e] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 3, .stack_outputs = 0 }; // MCOPY (dynamic, base cost)
    info[@intFromEnum(Opcode.PUSH0)] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1 };

    // 0x60-0x7f: PUSH1-PUSH32
    var i: u8 = 0;
    while (i < 32) : (i += 1) {
        info[0x60 + i] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 0, .stack_outputs = 1 };
    }

    // 0x80-0x8f: DUP1-DUP16
    i = 0;
    while (i < 16) : (i += 1) {
        info[0x80 + i] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 0, .stack_outputs = 1 };
    }

    // 0x90-0x9f: SWAP1-SWAP16
    i = 0;
    while (i < 16) : (i += 1) {
        info[0x90 + i] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 0, .stack_outputs = 0 };
    }

    // 0xa0-0xa4: LOG0-LOG4
    i = 0;
    while (i <= 4) : (i += 1) {
        info[0xa0 + i] = .{ .gas_cost = GasConstants.LogGas + i * GasConstants.LogTopicGas, .stack_inputs = @as(u8, 2 + i), .stack_outputs = 0 };
    }

    // 0xf0s: System operations
    info[0xf0] = .{ .gas_cost = 32000, .stack_inputs = 3, .stack_outputs = 1 }; // CREATE
    info[0xf1] = .{ .gas_cost = 100, .stack_inputs = 7, .stack_outputs = 1 }; // CALL (warm access, dynamic)
    info[0xf2] = .{ .gas_cost = 100, .stack_inputs = 7, .stack_outputs = 1 }; // CALLCODE (warm access, dynamic)
    info[0xf3] = .{ .gas_cost = 0, .stack_inputs = 2, .stack_outputs = 0 }; // RETURN (dynamic)
    info[0xf4] = .{ .gas_cost = 100, .stack_inputs = 6, .stack_outputs = 1 }; // DELEGATECALL (warm access, dynamic)
    info[0xf5] = .{ .gas_cost = 32000, .stack_inputs = 4, .stack_outputs = 1 }; // CREATE2
    info[0xf6] = .{ .gas_cost = 3100, .stack_inputs = 3, .stack_outputs = 1 }; // AUTH (EIP-3074)
    info[0xf7] = .{ .gas_cost = 100, .stack_inputs = 8, .stack_outputs = 1 }; // AUTHCALL (EIP-3074)
    info[0xfa] = .{ .gas_cost = 100, .stack_inputs = 6, .stack_outputs = 1 }; // STATICCALL (warm access, dynamic)
    info[0xfd] = .{ .gas_cost = 0, .stack_inputs = 2, .stack_outputs = 0 }; // REVERT (dynamic)
    info[0xfe] = .{ .gas_cost = 0, .stack_inputs = 0, .stack_outputs = 0 }; // INVALID
    info[0xff] = .{ .gas_cost = 5000, .stack_inputs = 1, .stack_outputs = 0 }; // SELFDESTRUCT (dynamic)

    break :blk info;
};

// Hardfork-specific opcode availability
pub const HARDFORK_OPCODES = struct {
    // EIP-3855: PUSH0 opcode (Shanghai)
    pub const SHANGHAI_OPCODES = [_]u8{0x5f};

    // EIP-3198: BASEFEE opcode (London)
    pub const LONDON_OPCODES = [_]u8{0x48};

    // EIP-1344: ChainID opcode (Istanbul)
    pub const ISTANBUL_OPCODES = [_]u8{ 0x46, 0x47 }; // CHAINID, SELFBALANCE

    // EIP-1014: Skinny CREATE2 (Constantinople)
    // EIP-145: Bitwise shifting instructions
    // EIP-1052: EXTCODEHASH
    pub const CONSTANTINOPLE_OPCODES = [_]u8{ 0xf5, 0x1b, 0x1c, 0x1d, 0x3f };

    // EIP-140: REVERT instruction
    // EIP-211: New opcodes RETURNDATASIZE and RETURNDATACOPY
    // EIP-214: New opcode STATICCALL
    pub const BYZANTIUM_OPCODES = [_]u8{ 0xfd, 0x3d, 0x3e, 0xfa };

    // EIP-2200: Structured Definitions for Net Gas Metering (Istanbul)
    // Changes SSTORE pricing

    // EIP-1153: Transient storage opcodes (Cancun)
    // EIP-4844: Shard Blob Transactions
    // EIP-5656: MCOPY - Memory copying instruction
    // EIP-7516: BLOBBASEFEE opcode
    pub const CANCUN_OPCODES = [_]u8{ 0x5c, 0x5d, 0x49, 0x5e, 0x4a };
};

// Helper functions for calculating min/max stack requirements
pub fn getMinStackRequired(opcode: u8) u16 {
    const info = OPCODE_INFO[opcode];

    // For DUP operations, need at least N items on stack
    if (opcode >= 0x80 and opcode <= 0x8f) {
        return (opcode - 0x80) + 1;
    }

    // For SWAP operations, need at least N+1 items on stack
    if (opcode >= 0x90 and opcode <= 0x9f) {
        return (opcode - 0x90) + 2;
    }

    // For all other operations, minimum is the number of inputs
    return info.stack_inputs;
}

pub fn getMaxStackAfter(opcode: u8) u16 {
    const info = OPCODE_INFO[opcode];

    // Operations that produce output need room on stack
    if (info.stack_outputs > 0) {
        return 1023; // Stack size - 1
    }

    return 1024; // Full stack size
}


test "opcode info array has correct size" {
    try std.testing.expectEqual(@as(usize, 256), OPCODE_INFO.len);
}

test "common opcodes have expected values" {
    // Test ADD
    const add_info = OPCODE_INFO[@intFromEnum(Opcode.ADD)];
    try std.testing.expectEqual(@as(u64, GasConstants.GasFastestStep), add_info.gas_cost);
    try std.testing.expectEqual(@as(u8, 2), add_info.stack_inputs);
    try std.testing.expectEqual(@as(u8, 1), add_info.stack_outputs);

    // Test PUSH1
    const push1_info = OPCODE_INFO[@intFromEnum(Opcode.PUSH1)];
    try std.testing.expectEqual(@as(u64, GasConstants.GasFastestStep), push1_info.gas_cost);
    try std.testing.expectEqual(@as(u8, 0), push1_info.stack_inputs);
    try std.testing.expectEqual(@as(u8, 1), push1_info.stack_outputs);
}

test "min stack calculation" {
    // Test DUP5
    try std.testing.expectEqual(@as(u16, 5), getMinStackRequired(0x84));

    // Test SWAP3
    try std.testing.expectEqual(@as(u16, 4), getMinStackRequired(0x92));

    // Test ADD
    try std.testing.expectEqual(@as(u16, 2), getMinStackRequired(0x01));
}


test "opcode enum values" {
    // Test some key opcodes have correct hex values
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(Opcode.STOP));
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(Opcode.ADD));
    try std.testing.expectEqual(@as(u8, 0x20), @intFromEnum(Opcode.KECCAK256));
    try std.testing.expectEqual(@as(u8, 0x60), @intFromEnum(Opcode.PUSH1));
    try std.testing.expectEqual(@as(u8, 0x7f), @intFromEnum(Opcode.PUSH32));
    try std.testing.expectEqual(@as(u8, 0x80), @intFromEnum(Opcode.DUP1));
    try std.testing.expectEqual(@as(u8, 0x8f), @intFromEnum(Opcode.DUP16));
    try std.testing.expectEqual(@as(u8, 0x90), @intFromEnum(Opcode.SWAP1));
    try std.testing.expectEqual(@as(u8, 0x9f), @intFromEnum(Opcode.SWAP16));
    try std.testing.expectEqual(@as(u8, 0xff), @intFromEnum(Opcode.SELFDESTRUCT));
}
