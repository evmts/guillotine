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
const primitives = @import("root");
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
        info[0xa0 + i] = .{ .gas_cost = GasConstants.LogGas + i * GasConstants.LogTopicGas, .stack_inputs = 2 + i, .stack_outputs = 0 };
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

/// Hardfork-specific opcode availability
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

    // EIP-1153: Transient storage opcodes (Cancun)
    // EIP-4844: Shard Blob Transactions
    // EIP-5656: MCOPY - Memory copying instruction
    // EIP-7516: BLOBBASEFEE opcode
    pub const CANCUN_OPCODES = [_]u8{ 0x5c, 0x5d, 0x49, 0x5e, 0x4a };
};

/// Helper functions for calculating min/max stack requirements
pub fn getMinStackRequired(opcode: u8) u16 {
    const info_entry = OPCODE_INFO[opcode];

    // For DUP operations, need at least N items on stack
    if (opcode >= 0x80 and opcode <= 0x8f) {
        return (opcode - 0x80) + 1;
    }

    // For SWAP operations, need at least N+1 items on stack
    if (opcode >= 0x90 and opcode <= 0x9f) {
        return (opcode - 0x90) + 2;
    }

    // For all other operations, minimum is the number of inputs
    return info_entry.stack_inputs;
}

pub fn getMaxStackAfter(opcode: u8) u16 {
    const info_entry = OPCODE_INFO[opcode];

    // Operations that produce output need room on stack
    if (info_entry.stack_outputs > 0) {
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
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), add_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), add_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), add_info.stack_outputs);

    // Test PUSH1
    const push1_info = OPCODE_INFO[@intFromEnum(Opcode.PUSH1)];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), push1_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), push1_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), push1_info.stack_outputs);
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

test "arithmetic opcodes metadata" {
    // ADD - fastest step
    const add_info = OPCODE_INFO[@intFromEnum(Opcode.ADD)];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), add_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), add_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), add_info.stack_outputs);

    // MUL - fast step
    const mul_info = OPCODE_INFO[@intFromEnum(Opcode.MUL)];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastStep), mul_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), mul_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), mul_info.stack_outputs);

    // SUB - fastest step
    const sub_info = OPCODE_INFO[@intFromEnum(Opcode.SUB)];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), sub_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), sub_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), sub_info.stack_outputs);

    // DIV - fast step
    const div_info = OPCODE_INFO[0x04];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastStep), div_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), div_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), div_info.stack_outputs);

    // ADDMOD - mid step with 3 inputs
    const addmod_info = OPCODE_INFO[0x08];
    try std.testing.expectEqual(@as(u16, GasConstants.GasMidStep), addmod_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 3), addmod_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), addmod_info.stack_outputs);

    // MULMOD - mid step with 3 inputs
    const mulmod_info = OPCODE_INFO[0x09];
    try std.testing.expectEqual(@as(u16, GasConstants.GasMidStep), mulmod_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 3), mulmod_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), mulmod_info.stack_outputs);

    // EXP - dynamic cost (base 10)
    const exp_info = OPCODE_INFO[0x0a];
    try std.testing.expectEqual(@as(u16, 10), exp_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), exp_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), exp_info.stack_outputs);
}

test "comparison and bitwise opcodes metadata" {
    // LT, GT, EQ - all fastest step, 2 inputs, 1 output
    const lt_info = OPCODE_INFO[0x10];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), lt_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), lt_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), lt_info.stack_outputs);

    const eq_info = OPCODE_INFO[0x14];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), eq_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), eq_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), eq_info.stack_outputs);

    // ISZERO - fastest step, 1 input, 1 output
    const iszero_info = OPCODE_INFO[0x15];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), iszero_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 1), iszero_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), iszero_info.stack_outputs);

    // AND, OR, XOR - all fastest step, 2 inputs, 1 output
    const and_info = OPCODE_INFO[0x16];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), and_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), and_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), and_info.stack_outputs);

    // NOT - fastest step, 1 input, 1 output
    const not_info = OPCODE_INFO[0x19];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), not_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 1), not_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), not_info.stack_outputs);

    // SHL, SHR, SAR - fastest step, 2 inputs, 1 output
    const shl_info = OPCODE_INFO[0x1b];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), shl_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), shl_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), shl_info.stack_outputs);
}

test "crypto opcodes metadata" {
    // KECCAK256 - base cost 30, dynamic
    const keccak_info = OPCODE_INFO[0x20];
    try std.testing.expectEqual(@as(u16, 30), keccak_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), keccak_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), keccak_info.stack_outputs);
}

test "environmental information opcodes metadata" {
    // ADDRESS - quick step, no inputs, 1 output
    const address_info = OPCODE_INFO[0x30];
    try std.testing.expectEqual(@as(u16, GasConstants.GasQuickStep), address_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), address_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), address_info.stack_outputs);

    // BALANCE - warm access cost 100
    const balance_info = OPCODE_INFO[0x31];
    try std.testing.expectEqual(@as(u16, 100), balance_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 1), balance_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), balance_info.stack_outputs);

    // CALLER - quick step, no inputs, 1 output
    const caller_info = OPCODE_INFO[0x33];
    try std.testing.expectEqual(@as(u16, GasConstants.GasQuickStep), caller_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), caller_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), caller_info.stack_outputs);

    // CALLDATALOAD - fastest step, 1 input, 1 output
    const calldataload_info = OPCODE_INFO[0x35];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), calldataload_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 1), calldataload_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), calldataload_info.stack_outputs);

    // CALLDATACOPY - fastest step base, 3 inputs, no outputs
    const calldatacopy_info = OPCODE_INFO[0x37];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), calldatacopy_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 3), calldatacopy_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), calldatacopy_info.stack_outputs);

    // EXTCODESIZE - warm access cost 100
    const extcodesize_info = OPCODE_INFO[0x3b];
    try std.testing.expectEqual(@as(u16, 100), extcodesize_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 1), extcodesize_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), extcodesize_info.stack_outputs);

    // EXTCODEHASH - warm access cost 100
    const extcodehash_info = OPCODE_INFO[0x3f];
    try std.testing.expectEqual(@as(u16, 100), extcodehash_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 1), extcodehash_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), extcodehash_info.stack_outputs);
}

test "block information opcodes metadata" {
    // BLOCKHASH - cost 20
    const blockhash_info = OPCODE_INFO[0x40];
    try std.testing.expectEqual(@as(u16, 20), blockhash_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 1), blockhash_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), blockhash_info.stack_outputs);

    // COINBASE - quick step
    const coinbase_info = OPCODE_INFO[0x41];
    try std.testing.expectEqual(@as(u16, GasConstants.GasQuickStep), coinbase_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), coinbase_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), coinbase_info.stack_outputs);

    // TIMESTAMP - quick step
    const timestamp_info = OPCODE_INFO[0x42];
    try std.testing.expectEqual(@as(u16, GasConstants.GasQuickStep), timestamp_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), timestamp_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), timestamp_info.stack_outputs);

    // CHAINID - quick step
    const chainid_info = OPCODE_INFO[0x46];
    try std.testing.expectEqual(@as(u16, GasConstants.GasQuickStep), chainid_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), chainid_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), chainid_info.stack_outputs);

    // SELFBALANCE - fast step
    const selfbalance_info = OPCODE_INFO[0x47];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastStep), selfbalance_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), selfbalance_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), selfbalance_info.stack_outputs);

    // BASEFEE - quick step
    const basefee_info = OPCODE_INFO[0x48];
    try std.testing.expectEqual(@as(u16, GasConstants.GasQuickStep), basefee_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), basefee_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), basefee_info.stack_outputs);

    // BLOBHASH - fastest step
    const blobhash_info = OPCODE_INFO[0x49];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), blobhash_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 1), blobhash_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), blobhash_info.stack_outputs);

    // BLOBBASEFEE - quick step
    const blobbasefee_info = OPCODE_INFO[0x4a];
    try std.testing.expectEqual(@as(u16, GasConstants.GasQuickStep), blobbasefee_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), blobbasefee_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), blobbasefee_info.stack_outputs);
}

test "stack memory and storage opcodes metadata" {
    // POP - quick step, 1 input, no outputs
    const pop_info = OPCODE_INFO[@intFromEnum(Opcode.POP)];
    try std.testing.expectEqual(@as(u16, GasConstants.GasQuickStep), pop_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 1), pop_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), pop_info.stack_outputs);

    // MLOAD - fastest step base, 1 input, 1 output
    const mload_info = OPCODE_INFO[0x51];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), mload_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 1), mload_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), mload_info.stack_outputs);

    // MSTORE - fastest step base, 2 inputs, no outputs
    const mstore_info = OPCODE_INFO[0x52];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), mstore_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), mstore_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), mstore_info.stack_outputs);

    // SLOAD - warm access cost 100
    const sload_info = OPCODE_INFO[0x54];
    try std.testing.expectEqual(@as(u16, 100), sload_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 1), sload_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), sload_info.stack_outputs);

    // SSTORE - warm access cost 100 base
    const sstore_info = OPCODE_INFO[0x55];
    try std.testing.expectEqual(@as(u16, 100), sstore_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), sstore_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), sstore_info.stack_outputs);

    // JUMP - mid step
    const jump_info = OPCODE_INFO[0x56];
    try std.testing.expectEqual(@as(u16, GasConstants.GasMidStep), jump_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 1), jump_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), jump_info.stack_outputs);

    // JUMPI - cost 10
    const jumpi_info = OPCODE_INFO[0x57];
    try std.testing.expectEqual(@as(u16, 10), jumpi_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), jumpi_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), jumpi_info.stack_outputs);

    // JUMPDEST - cost 1
    const jumpdest_info = OPCODE_INFO[0x5b];
    try std.testing.expectEqual(@as(u16, 1), jumpdest_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), jumpdest_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), jumpdest_info.stack_outputs);

    // TLOAD - warm access cost 100 (Cancun transient storage)
    const tload_info = OPCODE_INFO[0x5c];
    try std.testing.expectEqual(@as(u16, 100), tload_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 1), tload_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), tload_info.stack_outputs);

    // TSTORE - warm access cost 100 (Cancun transient storage)
    const tstore_info = OPCODE_INFO[0x5d];
    try std.testing.expectEqual(@as(u16, 100), tstore_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), tstore_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), tstore_info.stack_outputs);

    // MCOPY - fastest step base (Cancun memory copy)
    const mcopy_info = OPCODE_INFO[0x5e];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), mcopy_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 3), mcopy_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), mcopy_info.stack_outputs);

    // PUSH0 - quick step (Shanghai)
    const push0_info = OPCODE_INFO[@intFromEnum(Opcode.PUSH0)];
    try std.testing.expectEqual(@as(u16, GasConstants.GasQuickStep), push0_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), push0_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), push0_info.stack_outputs);
}

test "push opcodes metadata" {
    // Test all PUSH1 through PUSH32
    var i: u8 = 0;
    while (i < 32) : (i += 1) {
        const push_info = OPCODE_INFO[0x60 + i];
        try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), push_info.gas_cost);
        try std.testing.expectEqual(@as(u4, 0), push_info.stack_inputs);
        try std.testing.expectEqual(@as(u4, 1), push_info.stack_outputs);
    }

    // Verify specific PUSH opcodes
    const push1_info = OPCODE_INFO[@intFromEnum(Opcode.PUSH1)];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), push1_info.gas_cost);

    const push32_info = OPCODE_INFO[@intFromEnum(Opcode.PUSH32)];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), push32_info.gas_cost);
}

test "dup opcodes metadata" {
    // Test all DUP1 through DUP16
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        const dup_info = OPCODE_INFO[0x80 + i];
        try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), dup_info.gas_cost);
        try std.testing.expectEqual(@as(u4, 0), dup_info.stack_inputs);
        try std.testing.expectEqual(@as(u4, 1), dup_info.stack_outputs);
    }

    // Verify specific DUP opcodes
    const dup1_info = OPCODE_INFO[@intFromEnum(Opcode.DUP1)];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), dup1_info.gas_cost);

    const dup16_info = OPCODE_INFO[@intFromEnum(Opcode.DUP16)];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), dup16_info.gas_cost);
}

test "swap opcodes metadata" {
    // Test all SWAP1 through SWAP16
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        const swap_info = OPCODE_INFO[0x90 + i];
        try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), swap_info.gas_cost);
        try std.testing.expectEqual(@as(u4, 0), swap_info.stack_inputs);
        try std.testing.expectEqual(@as(u4, 0), swap_info.stack_outputs);
    }

    // Verify specific SWAP opcodes
    const swap1_info = OPCODE_INFO[@intFromEnum(Opcode.SWAP1)];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), swap1_info.gas_cost);

    const swap16_info = OPCODE_INFO[@intFromEnum(Opcode.SWAP16)];
    try std.testing.expectEqual(@as(u16, GasConstants.GasFastestStep), swap16_info.gas_cost);
}

test "log opcodes metadata" {
    // LOG0 - no topics
    const log0_info = OPCODE_INFO[0xa0];
    try std.testing.expectEqual(@as(u16, GasConstants.LogGas), log0_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), log0_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), log0_info.stack_outputs);

    // LOG1 - 1 topic
    const log1_info = OPCODE_INFO[0xa1];
    try std.testing.expectEqual(@as(u16, GasConstants.LogGas + 1 * GasConstants.LogTopicGas), log1_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 3), log1_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), log1_info.stack_outputs);

    // LOG2 - 2 topics
    const log2_info = OPCODE_INFO[0xa2];
    try std.testing.expectEqual(@as(u16, GasConstants.LogGas + 2 * GasConstants.LogTopicGas), log2_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 4), log2_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), log2_info.stack_outputs);

    // LOG3 - 3 topics
    const log3_info = OPCODE_INFO[0xa3];
    try std.testing.expectEqual(@as(u16, GasConstants.LogGas + 3 * GasConstants.LogTopicGas), log3_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 5), log3_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), log3_info.stack_outputs);

    // LOG4 - 4 topics
    const log4_info = OPCODE_INFO[0xa4];
    try std.testing.expectEqual(@as(u16, GasConstants.LogGas + 4 * GasConstants.LogTopicGas), log4_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 6), log4_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), log4_info.stack_outputs);
}

test "system operation opcodes metadata" {
    // CREATE - cost 32000
    const create_info = OPCODE_INFO[0xf0];
    try std.testing.expectEqual(@as(u16, 32000), create_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 3), create_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), create_info.stack_outputs);

    // CALL - warm access cost 100 base
    const call_info = OPCODE_INFO[0xf1];
    try std.testing.expectEqual(@as(u16, 100), call_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 7), call_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), call_info.stack_outputs);

    // CALLCODE - warm access cost 100 base
    const callcode_info = OPCODE_INFO[0xf2];
    try std.testing.expectEqual(@as(u16, 100), callcode_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 7), callcode_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), callcode_info.stack_outputs);

    // RETURN - cost 0 base
    const return_info = OPCODE_INFO[0xf3];
    try std.testing.expectEqual(@as(u16, 0), return_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), return_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), return_info.stack_outputs);

    // DELEGATECALL - warm access cost 100 base
    const delegatecall_info = OPCODE_INFO[0xf4];
    try std.testing.expectEqual(@as(u16, 100), delegatecall_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 6), delegatecall_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), delegatecall_info.stack_outputs);

    // CREATE2 - cost 32000
    const create2_info = OPCODE_INFO[0xf5];
    try std.testing.expectEqual(@as(u16, 32000), create2_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 4), create2_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), create2_info.stack_outputs);

    // AUTH - cost 3100 (EIP-3074)
    const auth_info = OPCODE_INFO[0xf6];
    try std.testing.expectEqual(@as(u16, 3100), auth_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 3), auth_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), auth_info.stack_outputs);

    // AUTHCALL - warm access cost 100 base (EIP-3074)
    const authcall_info = OPCODE_INFO[0xf7];
    try std.testing.expectEqual(@as(u16, 100), authcall_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 8), authcall_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), authcall_info.stack_outputs);

    // STATICCALL - warm access cost 100 base
    const staticcall_info = OPCODE_INFO[0xfa];
    try std.testing.expectEqual(@as(u16, 100), staticcall_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 6), staticcall_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), staticcall_info.stack_outputs);

    // REVERT - cost 0 base
    const revert_info = OPCODE_INFO[0xfd];
    try std.testing.expectEqual(@as(u16, 0), revert_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 2), revert_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), revert_info.stack_outputs);

    // INVALID - cost 0
    const invalid_info = OPCODE_INFO[0xfe];
    try std.testing.expectEqual(@as(u16, 0), invalid_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), invalid_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), invalid_info.stack_outputs);

    // SELFDESTRUCT - cost 5000 base
    const selfdestruct_info = OPCODE_INFO[0xff];
    try std.testing.expectEqual(@as(u16, 5000), selfdestruct_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 1), selfdestruct_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), selfdestruct_info.stack_outputs);
}

test "boundary opcodes STOP and SELFDESTRUCT" {
    // STOP - opcode 0x00
    const stop_info = OPCODE_INFO[@intFromEnum(Opcode.STOP)];
    try std.testing.expectEqual(@as(u16, 0), stop_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), stop_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), stop_info.stack_outputs);

    // SELFDESTRUCT - opcode 0xff
    const selfdestruct_info = OPCODE_INFO[@intFromEnum(Opcode.SELFDESTRUCT)];
    try std.testing.expectEqual(@as(u16, 5000), selfdestruct_info.gas_cost);
    try std.testing.expectEqual(@as(u4, 1), selfdestruct_info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), selfdestruct_info.stack_outputs);
}

test "unimplemented opcodes have zero metadata" {
    // Test several unimplemented opcode ranges
    // 0x0c-0x0f (between SIGNEXTEND and LT)
    const opcode_0c = OPCODE_INFO[0x0c];
    try std.testing.expectEqual(@as(u16, 0), opcode_0c.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), opcode_0c.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), opcode_0c.stack_outputs);

    // 0x1e-0x1f (between SAR and KECCAK256)
    const opcode_1e = OPCODE_INFO[0x1e];
    try std.testing.expectEqual(@as(u16, 0), opcode_1e.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), opcode_1e.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), opcode_1e.stack_outputs);

    // 0x21-0x2f (between KECCAK256 and ADDRESS)
    const opcode_21 = OPCODE_INFO[0x21];
    try std.testing.expectEqual(@as(u16, 0), opcode_21.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), opcode_21.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), opcode_21.stack_outputs);

    // 0x4b-0x4f (after BLOBBASEFEE, before POP)
    const opcode_4b = OPCODE_INFO[0x4b];
    try std.testing.expectEqual(@as(u16, 0), opcode_4b.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), opcode_4b.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), opcode_4b.stack_outputs);

    // 0xa5-0xef (between LOG4 and CREATE)
    const opcode_a5 = OPCODE_INFO[0xa5];
    try std.testing.expectEqual(@as(u16, 0), opcode_a5.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), opcode_a5.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), opcode_a5.stack_outputs);

    const opcode_ef = OPCODE_INFO[0xef];
    try std.testing.expectEqual(@as(u16, 0), opcode_ef.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), opcode_ef.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), opcode_ef.stack_outputs);

    // 0xf8-0xf9 (between AUTHCALL and STATICCALL)
    const opcode_f8 = OPCODE_INFO[0xf8];
    try std.testing.expectEqual(@as(u16, 0), opcode_f8.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), opcode_f8.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), opcode_f8.stack_outputs);

    // 0xfb-0xfc (between STATICCALL and REVERT)
    const opcode_fb = OPCODE_INFO[0xfb];
    try std.testing.expectEqual(@as(u16, 0), opcode_fb.gas_cost);
    try std.testing.expectEqual(@as(u4, 0), opcode_fb.stack_inputs);
    try std.testing.expectEqual(@as(u4, 0), opcode_fb.stack_outputs);
}

test "stack input output validation for all opcode categories" {
    // Verify no opcode has more than 8 inputs (EVM stack limit for calls)
    for (OPCODE_INFO, 0..) |info, opcode| {
        try std.testing.expect(info.stack_inputs <= 8);
        try std.testing.expect(info.stack_outputs <= 1);

        // Verify AUTHCALL has maximum inputs
        if (opcode == 0xf7) {
            try std.testing.expectEqual(@as(u4, 8), info.stack_inputs);
        }
    }
}

test "min stack required for DUP operations" {
    // DUP1 requires 1 item on stack
    try std.testing.expectEqual(@as(u16, 1), getMinStackRequired(0x80));

    // DUP2 requires 2 items on stack
    try std.testing.expectEqual(@as(u16, 2), getMinStackRequired(0x81));

    // DUP5 requires 5 items on stack
    try std.testing.expectEqual(@as(u16, 5), getMinStackRequired(0x84));

    // DUP16 requires 16 items on stack
    try std.testing.expectEqual(@as(u16, 16), getMinStackRequired(0x8f));
}

test "min stack required for SWAP operations" {
    // SWAP1 requires 2 items on stack (swap top 2)
    try std.testing.expectEqual(@as(u16, 2), getMinStackRequired(0x90));

    // SWAP2 requires 3 items on stack (swap 1st and 3rd)
    try std.testing.expectEqual(@as(u16, 3), getMinStackRequired(0x91));

    // SWAP3 requires 4 items on stack
    try std.testing.expectEqual(@as(u16, 4), getMinStackRequired(0x92));

    // SWAP16 requires 17 items on stack
    try std.testing.expectEqual(@as(u16, 17), getMinStackRequired(0x9f));
}

test "min stack required for regular operations" {
    // Operations with no inputs
    try std.testing.expectEqual(@as(u16, 0), getMinStackRequired(0x30)); // ADDRESS
    try std.testing.expectEqual(@as(u16, 0), getMinStackRequired(0x5f)); // PUSH0

    // Operations with 1 input
    try std.testing.expectEqual(@as(u16, 1), getMinStackRequired(0x15)); // ISZERO
    try std.testing.expectEqual(@as(u16, 1), getMinStackRequired(0x50)); // POP

    // Operations with 2 inputs
    try std.testing.expectEqual(@as(u16, 2), getMinStackRequired(0x01)); // ADD
    try std.testing.expectEqual(@as(u16, 2), getMinStackRequired(0x10)); // LT

    // Operations with 3 inputs
    try std.testing.expectEqual(@as(u16, 3), getMinStackRequired(0x08)); // ADDMOD
    try std.testing.expectEqual(@as(u16, 3), getMinStackRequired(0x37)); // CALLDATACOPY

    // Operations with 7 inputs
    try std.testing.expectEqual(@as(u16, 7), getMinStackRequired(0xf1)); // CALL
}

test "max stack after operations with outputs" {
    // Operations that produce output need room on stack (1023 items already)
    try std.testing.expectEqual(@as(u16, 1023), getMaxStackAfter(0x01)); // ADD produces output
    try std.testing.expectEqual(@as(u16, 1023), getMaxStackAfter(0x60)); // PUSH1 produces output
    try std.testing.expectEqual(@as(u16, 1023), getMaxStackAfter(0x80)); // DUP1 produces output
}

test "max stack after operations without outputs" {
    // Operations that don't produce output can have full stack
    try std.testing.expectEqual(@as(u16, 1024), getMaxStackAfter(0x50)); // POP
    try std.testing.expectEqual(@as(u16, 1024), getMaxStackAfter(0x55)); // SSTORE
    try std.testing.expectEqual(@as(u16, 1024), getMaxStackAfter(0x90)); // SWAP1
    try std.testing.expectEqual(@as(u16, 1024), getMaxStackAfter(0xf3)); // RETURN
}

test "hardfork specific opcodes are documented" {
    // Shanghai - PUSH0
    try std.testing.expectEqual(@as(usize, 1), HARDFORK_OPCODES.SHANGHAI_OPCODES.len);
    try std.testing.expectEqual(@as(u8, 0x5f), HARDFORK_OPCODES.SHANGHAI_OPCODES[0]);

    // London - BASEFEE
    try std.testing.expectEqual(@as(usize, 1), HARDFORK_OPCODES.LONDON_OPCODES.len);
    try std.testing.expectEqual(@as(u8, 0x48), HARDFORK_OPCODES.LONDON_OPCODES[0]);

    // Istanbul - CHAINID, SELFBALANCE
    try std.testing.expectEqual(@as(usize, 2), HARDFORK_OPCODES.ISTANBUL_OPCODES.len);
    try std.testing.expectEqual(@as(u8, 0x46), HARDFORK_OPCODES.ISTANBUL_OPCODES[0]);
    try std.testing.expectEqual(@as(u8, 0x47), HARDFORK_OPCODES.ISTANBUL_OPCODES[1]);

    // Constantinople - CREATE2, SHL, SHR, SAR, EXTCODEHASH
    try std.testing.expectEqual(@as(usize, 5), HARDFORK_OPCODES.CONSTANTINOPLE_OPCODES.len);
    try std.testing.expectEqual(@as(u8, 0xf5), HARDFORK_OPCODES.CONSTANTINOPLE_OPCODES[0]);
    try std.testing.expectEqual(@as(u8, 0x1b), HARDFORK_OPCODES.CONSTANTINOPLE_OPCODES[1]);
    try std.testing.expectEqual(@as(u8, 0x1c), HARDFORK_OPCODES.CONSTANTINOPLE_OPCODES[2]);
    try std.testing.expectEqual(@as(u8, 0x1d), HARDFORK_OPCODES.CONSTANTINOPLE_OPCODES[3]);
    try std.testing.expectEqual(@as(u8, 0x3f), HARDFORK_OPCODES.CONSTANTINOPLE_OPCODES[4]);

    // Byzantium - REVERT, RETURNDATASIZE, RETURNDATACOPY, STATICCALL
    try std.testing.expectEqual(@as(usize, 4), HARDFORK_OPCODES.BYZANTIUM_OPCODES.len);
    try std.testing.expectEqual(@as(u8, 0xfd), HARDFORK_OPCODES.BYZANTIUM_OPCODES[0]);
    try std.testing.expectEqual(@as(u8, 0x3d), HARDFORK_OPCODES.BYZANTIUM_OPCODES[1]);
    try std.testing.expectEqual(@as(u8, 0x3e), HARDFORK_OPCODES.BYZANTIUM_OPCODES[2]);
    try std.testing.expectEqual(@as(u8, 0xfa), HARDFORK_OPCODES.BYZANTIUM_OPCODES[3]);

    // Cancun - TLOAD, TSTORE, BLOBHASH, MCOPY, BLOBBASEFEE
    try std.testing.expectEqual(@as(usize, 5), HARDFORK_OPCODES.CANCUN_OPCODES.len);
    try std.testing.expectEqual(@as(u8, 0x5c), HARDFORK_OPCODES.CANCUN_OPCODES[0]);
    try std.testing.expectEqual(@as(u8, 0x5d), HARDFORK_OPCODES.CANCUN_OPCODES[1]);
    try std.testing.expectEqual(@as(u8, 0x49), HARDFORK_OPCODES.CANCUN_OPCODES[2]);
    try std.testing.expectEqual(@as(u8, 0x5e), HARDFORK_OPCODES.CANCUN_OPCODES[3]);
    try std.testing.expectEqual(@as(u8, 0x4a), HARDFORK_OPCODES.CANCUN_OPCODES[4]);
}

test "gas costs for dynamic opcodes have base costs" {
    // These opcodes have dynamic costs but still define base costs
    // EXP - dynamic based on exponent byte length
    const exp_info = OPCODE_INFO[0x0a];
    try std.testing.expectEqual(@as(u16, 10), exp_info.gas_cost);

    // KECCAK256 - dynamic based on data size
    const keccak_info = OPCODE_INFO[0x20];
    try std.testing.expectEqual(@as(u16, 30), keccak_info.gas_cost);

    // Storage and memory operations have dynamic costs
    // SLOAD - warm access
    const sload_info = OPCODE_INFO[0x54];
    try std.testing.expectEqual(@as(u16, 100), sload_info.gas_cost);

    // SSTORE - warm access, actual cost depends on storage state
    const sstore_info = OPCODE_INFO[0x55];
    try std.testing.expectEqual(@as(u16, 100), sstore_info.gas_cost);

    // CREATE - base cost
    const create_info = OPCODE_INFO[0xf0];
    try std.testing.expectEqual(@as(u16, 32000), create_info.gas_cost);

    // CALL - warm access base cost
    const call_info = OPCODE_INFO[0xf1];
    try std.testing.expectEqual(@as(u16, 100), call_info.gas_cost);
}
