const std = @import("std");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;

/// Combined opcode metadata for better cache efficiency
pub const OpcodeInfo = struct {
    gas_cost: u64,
    stack_inputs: u8,
    stack_outputs: u8,
    is_undefined: bool,
};

/// Static opcode information for all 256 opcodes
pub const OPCODE_INFO = blk: {
    var info: [256]OpcodeInfo = [_]OpcodeInfo{.{ 
        .gas_cost = 0, 
        .stack_inputs = 0, 
        .stack_outputs = 0, 
        .is_undefined = true 
    }} ** 256;
    
    // 0x00s: Stop and Arithmetic Operations
    info[0x00] = .{ .gas_cost = 0, .stack_inputs = 0, .stack_outputs = 0, .is_undefined = false }; // STOP
    info[0x01] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // ADD
    info[0x02] = .{ .gas_cost = GasConstants.GasFastStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // MUL
    info[0x03] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // SUB
    info[0x04] = .{ .gas_cost = GasConstants.GasFastStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // DIV
    info[0x05] = .{ .gas_cost = GasConstants.GasFastStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // SDIV
    info[0x06] = .{ .gas_cost = GasConstants.GasFastStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // MOD
    info[0x07] = .{ .gas_cost = GasConstants.GasFastStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // SMOD
    info[0x08] = .{ .gas_cost = GasConstants.GasMidStep, .stack_inputs = 3, .stack_outputs = 1, .is_undefined = false }; // ADDMOD
    info[0x09] = .{ .gas_cost = GasConstants.GasMidStep, .stack_inputs = 3, .stack_outputs = 1, .is_undefined = false }; // MULMOD
    info[0x0a] = .{ .gas_cost = 10, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // EXP (dynamic, base cost)
    info[0x0b] = .{ .gas_cost = GasConstants.GasFastStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // SIGNEXTEND
    
    // 0x10s: Comparison & Bitwise Logic Operations
    info[0x10] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // LT
    info[0x11] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // GT
    info[0x12] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // SLT
    info[0x13] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // SGT
    info[0x14] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // EQ
    info[0x15] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 1, .stack_outputs = 1, .is_undefined = false }; // ISZERO
    info[0x16] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // AND
    info[0x17] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // OR
    info[0x18] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // XOR
    info[0x19] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 1, .stack_outputs = 1, .is_undefined = false }; // NOT
    info[0x1a] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // BYTE
    info[0x1b] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // SHL
    info[0x1c] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // SHR
    info[0x1d] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // SAR
    
    // 0x20s: Crypto
    info[0x20] = .{ .gas_cost = 30, .stack_inputs = 2, .stack_outputs = 1, .is_undefined = false }; // SHA3/KECCAK256 (dynamic, base cost)
    
    // 0x30s: Environmental Information
    info[0x30] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // ADDRESS
    info[0x31] = .{ .gas_cost = 100, .stack_inputs = 1, .stack_outputs = 1, .is_undefined = false }; // BALANCE (warm access)
    info[0x32] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // ORIGIN
    info[0x33] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // CALLER
    info[0x34] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // CALLVALUE
    info[0x35] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 1, .stack_outputs = 1, .is_undefined = false }; // CALLDATALOAD
    info[0x36] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // CALLDATASIZE
    info[0x37] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 3, .stack_outputs = 0, .is_undefined = false }; // CALLDATACOPY (dynamic, base cost)
    info[0x38] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // CODESIZE
    info[0x39] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 3, .stack_outputs = 0, .is_undefined = false }; // CODECOPY (dynamic, base cost)
    info[0x3a] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // GASPRICE
    info[0x3b] = .{ .gas_cost = 100, .stack_inputs = 1, .stack_outputs = 1, .is_undefined = false }; // EXTCODESIZE (warm access)
    info[0x3c] = .{ .gas_cost = 100, .stack_inputs = 4, .stack_outputs = 0, .is_undefined = false }; // EXTCODECOPY (warm access, dynamic)
    info[0x3d] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // RETURNDATASIZE
    info[0x3e] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 3, .stack_outputs = 0, .is_undefined = false }; // RETURNDATACOPY (dynamic, base cost)
    info[0x3f] = .{ .gas_cost = 100, .stack_inputs = 1, .stack_outputs = 1, .is_undefined = false }; // EXTCODEHASH (warm access)
    
    // 0x40s: Block Information
    info[0x40] = .{ .gas_cost = 20, .stack_inputs = 1, .stack_outputs = 1, .is_undefined = false }; // BLOCKHASH
    info[0x41] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // COINBASE
    info[0x42] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // TIMESTAMP
    info[0x43] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // NUMBER
    info[0x44] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // DIFFICULTY/PREVRANDAO
    info[0x45] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // GASLIMIT
    info[0x46] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // CHAINID
    info[0x47] = .{ .gas_cost = GasConstants.GasFastStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // SELFBALANCE
    info[0x48] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // BASEFEE
    info[0x49] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 1, .stack_outputs = 1, .is_undefined = false }; // BLOBHASH
    info[0x4a] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // BLOBBASEFEE
    
    // 0x50s: Stack, Memory, Storage and Flow Operations
    info[0x50] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 1, .stack_outputs = 0, .is_undefined = false }; // POP
    info[0x51] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 1, .stack_outputs = 1, .is_undefined = false }; // MLOAD (dynamic)
    info[0x52] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 0, .is_undefined = false }; // MSTORE (dynamic)
    info[0x53] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 2, .stack_outputs = 0, .is_undefined = false }; // MSTORE8 (dynamic)
    info[0x54] = .{ .gas_cost = 100, .stack_inputs = 1, .stack_outputs = 1, .is_undefined = false }; // SLOAD (warm access)
    info[0x55] = .{ .gas_cost = 100, .stack_inputs = 2, .stack_outputs = 0, .is_undefined = false }; // SSTORE (warm access, dynamic)
    info[0x56] = .{ .gas_cost = GasConstants.GasMidStep, .stack_inputs = 1, .stack_outputs = 0, .is_undefined = false }; // JUMP
    info[0x57] = .{ .gas_cost = 10, .stack_inputs = 2, .stack_outputs = 0, .is_undefined = false }; // JUMPI
    info[0x58] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // PC
    info[0x59] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // MSIZE
    info[0x5a] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // GAS
    info[0x5b] = .{ .gas_cost = 1, .stack_inputs = 0, .stack_outputs = 0, .is_undefined = false }; // JUMPDEST
    info[0x5c] = .{ .gas_cost = 100, .stack_inputs = 1, .stack_outputs = 1, .is_undefined = false }; // TLOAD (warm access)
    info[0x5d] = .{ .gas_cost = 100, .stack_inputs = 2, .stack_outputs = 0, .is_undefined = false }; // TSTORE (warm access)
    info[0x5e] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 3, .stack_outputs = 0, .is_undefined = false }; // MCOPY (dynamic, base cost)
    info[0x5f] = .{ .gas_cost = GasConstants.GasQuickStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false }; // PUSH0
    
    // 0x60-0x7f: PUSH1-PUSH32
    var i: u8 = 0;
    while (i < 32) : (i += 1) {
        info[0x60 + i] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false };
    }
    
    // 0x80-0x8f: DUP1-DUP16
    i = 0;
    while (i < 16) : (i += 1) {
        info[0x80 + i] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 0, .stack_outputs = 1, .is_undefined = false };
    }
    
    // 0x90-0x9f: SWAP1-SWAP16
    i = 0;
    while (i < 16) : (i += 1) {
        info[0x90 + i] = .{ .gas_cost = GasConstants.GasFastestStep, .stack_inputs = 0, .stack_outputs = 0, .is_undefined = false };
    }
    
    // 0xa0-0xa4: LOG0-LOG4
    i = 0;
    while (i <= 4) : (i += 1) {
        info[0xa0 + i] = .{ .gas_cost = GasConstants.LogGas + i * GasConstants.LogTopicGas, .stack_inputs = @as(u8, 2 + i), .stack_outputs = 0, .is_undefined = false };
    }
    
    // 0xf0s: System operations
    info[0xf0] = .{ .gas_cost = 32000, .stack_inputs = 3, .stack_outputs = 1, .is_undefined = false }; // CREATE
    info[0xf1] = .{ .gas_cost = 100, .stack_inputs = 7, .stack_outputs = 1, .is_undefined = false }; // CALL (warm access, dynamic)
    info[0xf2] = .{ .gas_cost = 100, .stack_inputs = 7, .stack_outputs = 1, .is_undefined = false }; // CALLCODE (warm access, dynamic)
    info[0xf3] = .{ .gas_cost = 0, .stack_inputs = 2, .stack_outputs = 0, .is_undefined = false }; // RETURN (dynamic)
    info[0xf4] = .{ .gas_cost = 100, .stack_inputs = 6, .stack_outputs = 1, .is_undefined = false }; // DELEGATECALL (warm access, dynamic)
    info[0xf5] = .{ .gas_cost = 32000, .stack_inputs = 4, .stack_outputs = 1, .is_undefined = false }; // CREATE2
    info[0xfa] = .{ .gas_cost = 100, .stack_inputs = 6, .stack_outputs = 1, .is_undefined = false }; // STATICCALL (warm access, dynamic)
    info[0xfd] = .{ .gas_cost = 0, .stack_inputs = 2, .stack_outputs = 0, .is_undefined = false }; // REVERT (dynamic)
    info[0xfe] = .{ .gas_cost = 0, .stack_inputs = 0, .stack_outputs = 0, .is_undefined = false }; // INVALID
    info[0xff] = .{ .gas_cost = 5000, .stack_inputs = 1, .stack_outputs = 0, .is_undefined = false }; // SELFDESTRUCT (dynamic)
    
    break :blk info;
};

// Hardfork-specific opcode availability
pub const HARDFORK_OPCODES = struct {
    // EIP-3855: PUSH0 opcode (Shanghai)
    pub const SHANGHAI_OPCODES = [_]u8{0x5f};
    
    // EIP-3198: BASEFEE opcode (London)
    pub const LONDON_OPCODES = [_]u8{0x48};
    
    // EIP-1344: ChainID opcode (Istanbul)
    pub const ISTANBUL_OPCODES = [_]u8{0x46, 0x47}; // CHAINID, SELFBALANCE
    
    // EIP-1014: Skinny CREATE2 (Constantinople)
    // EIP-145: Bitwise shifting instructions
    // EIP-1052: EXTCODEHASH
    pub const CONSTANTINOPLE_OPCODES = [_]u8{0xf5, 0x1b, 0x1c, 0x1d, 0x3f};
    
    // EIP-140: REVERT instruction
    // EIP-211: New opcodes RETURNDATASIZE and RETURNDATACOPY
    // EIP-214: New opcode STATICCALL
    pub const BYZANTIUM_OPCODES = [_]u8{0xfd, 0x3d, 0x3e, 0xfa};
    
    // EIP-2200: Structured Definitions for Net Gas Metering (Istanbul)
    // Changes SSTORE pricing
    
    // EIP-1153: Transient storage opcodes (Cancun)
    // EIP-4844: Shard Blob Transactions
    // EIP-5656: MCOPY - Memory copying instruction
    // EIP-7516: BLOBBASEFEE opcode
    pub const CANCUN_OPCODES = [_]u8{0x5c, 0x5d, 0x49, 0x5e, 0x4a};
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
    const add_info = OPCODE_INFO[0x01];
    try std.testing.expectEqual(@as(u64, GasConstants.GasFastestStep), add_info.gas_cost);
    try std.testing.expectEqual(@as(u8, 2), add_info.stack_inputs);
    try std.testing.expectEqual(@as(u8, 1), add_info.stack_outputs);
    try std.testing.expectEqual(false, add_info.is_undefined);
    
    // Test PUSH1
    const push1_info = OPCODE_INFO[0x60];
    try std.testing.expectEqual(@as(u64, GasConstants.GasFastestStep), push1_info.gas_cost);
    try std.testing.expectEqual(@as(u8, 0), push1_info.stack_inputs);
    try std.testing.expectEqual(@as(u8, 1), push1_info.stack_outputs);
    
    // Test undefined opcode
    const undefined_info = OPCODE_INFO[0x0c];
    try std.testing.expectEqual(true, undefined_info.is_undefined);
}

test "min stack calculation" {
    // Test DUP5
    try std.testing.expectEqual(@as(u16, 5), getMinStackRequired(0x84));
    
    // Test SWAP3
    try std.testing.expectEqual(@as(u16, 4), getMinStackRequired(0x92));
    
    // Test ADD
    try std.testing.expectEqual(@as(u16, 2), getMinStackRequired(0x01));
}