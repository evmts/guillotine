const std = @import("std");

/// Get the name of an opcode
pub fn getOpName(opcode: u8) []const u8 {
    return switch (opcode) {
        0x00 => "STOP",
        0x01 => "ADD",
        0x02 => "MUL",
        0x03 => "SUB",
        0x04 => "DIV",
        0x05 => "SDIV",
        0x06 => "MOD",
        0x07 => "SMOD",
        0x08 => "ADDMOD",
        0x09 => "MULMOD",
        0x0a => "EXP",
        0x0b => "SIGNEXTEND",
        0x10 => "LT",
        0x11 => "GT",
        0x12 => "SLT",
        0x13 => "SGT",
        0x14 => "EQ",
        0x15 => "ISZERO",
        0x16 => "AND",
        0x17 => "OR",
        0x18 => "XOR",
        0x19 => "NOT",
        0x1a => "BYTE",
        0x1b => "SHL",
        0x1c => "SHR",
        0x1d => "SAR",
        0x20 => "KECCAK256",
        0x30 => "ADDRESS",
        0x31 => "BALANCE",
        0x32 => "ORIGIN",
        0x33 => "CALLER",
        0x34 => "CALLVALUE",
        0x35 => "CALLDATALOAD",
        0x36 => "CALLDATASIZE",
        0x37 => "CALLDATACOPY",
        0x38 => "CODESIZE",
        0x39 => "CODECOPY",
        0x3a => "GASPRICE",
        0x3b => "EXTCODESIZE",
        0x3c => "EXTCODECOPY",
        0x3d => "RETURNDATASIZE",
        0x3e => "RETURNDATACOPY",
        0x3f => "EXTCODEHASH",
        0x40 => "BLOCKHASH",
        0x41 => "COINBASE",
        0x42 => "TIMESTAMP",
        0x43 => "NUMBER",
        0x44 => "DIFFICULTY",
        0x45 => "GASLIMIT",
        0x46 => "CHAINID",
        0x47 => "SELFBALANCE",
        0x48 => "BASEFEE",
        0x49 => "BLOBHASH",
        0x4a => "BLOBBASEFEE",
        0x50 => "POP",
        0x51 => "MLOAD",
        0x52 => "MSTORE",
        0x53 => "MSTORE8",
        0x54 => "SLOAD",
        0x55 => "SSTORE",
        0x56 => "JUMP",
        0x57 => "JUMPI",
        0x58 => "PC",
        0x59 => "MSIZE",
        0x5a => "GAS",
        0x5b => "JUMPDEST",
        0x5c => "TLOAD",
        0x5d => "TSTORE",
        0x5e => "MCOPY",
        0x5f => "PUSH0",
        0x60 => "PUSH1",
        0x61 => "PUSH2",
        0x62 => "PUSH3",
        0x63 => "PUSH4",
        0x64 => "PUSH5",
        0x65 => "PUSH6",
        0x66 => "PUSH7",
        0x67 => "PUSH8",
        0x68 => "PUSH9",
        0x69 => "PUSH10",
        0x6a => "PUSH11",
        0x6b => "PUSH12",
        0x6c => "PUSH13",
        0x6d => "PUSH14",
        0x6e => "PUSH15",
        0x6f => "PUSH16",
        0x70 => "PUSH17",
        0x71 => "PUSH18",
        0x72 => "PUSH19",
        0x73 => "PUSH20",
        0x74 => "PUSH21",
        0x75 => "PUSH22",
        0x76 => "PUSH23",
        0x77 => "PUSH24",
        0x78 => "PUSH25",
        0x79 => "PUSH26",
        0x7a => "PUSH27",
        0x7b => "PUSH28",
        0x7c => "PUSH29",
        0x7d => "PUSH30",
        0x7e => "PUSH31",
        0x7f => "PUSH32",
        0x80 => "DUP1",
        0x81 => "DUP2",
        0x82 => "DUP3",
        0x83 => "DUP4",
        0x84 => "DUP5",
        0x85 => "DUP6",
        0x86 => "DUP7",
        0x87 => "DUP8",
        0x88 => "DUP9",
        0x89 => "DUP10",
        0x8a => "DUP11",
        0x8b => "DUP12",
        0x8c => "DUP13",
        0x8d => "DUP14",
        0x8e => "DUP15",
        0x8f => "DUP16",
        0x90 => "SWAP1",
        0x91 => "SWAP2",
        0x92 => "SWAP3",
        0x93 => "SWAP4",
        0x94 => "SWAP5",
        0x95 => "SWAP6",
        0x96 => "SWAP7",
        0x97 => "SWAP8",
        0x98 => "SWAP9",
        0x99 => "SWAP10",
        0x9a => "SWAP11",
        0x9b => "SWAP12",
        0x9c => "SWAP13",
        0x9d => "SWAP14",
        0x9e => "SWAP15",
        0x9f => "SWAP16",
        0xa0 => "LOG0",
        0xa1 => "LOG1",
        0xa2 => "LOG2",
        0xa3 => "LOG3",
        0xa4 => "LOG4",
        0xf0 => "CREATE",
        0xf1 => "CALL",
        0xf2 => "CALLCODE",
        0xf3 => "RETURN",
        0xf4 => "DELEGATECALL",
        0xf5 => "CREATE2",
        0xfa => "STATICCALL",
        0xfd => "REVERT",
        0xfe => "INVALID",
        0xff => "SELFDESTRUCT",
        else => "UNKNOWN",
    };
}

// Tests
test "getOpName: arithmetic opcodes" {
    const testing = std.testing;
    try testing.expectEqualStrings("STOP", getOpName(0x00));
    try testing.expectEqualStrings("ADD", getOpName(0x01));
    try testing.expectEqualStrings("MUL", getOpName(0x02));
    try testing.expectEqualStrings("SUB", getOpName(0x03));
    try testing.expectEqualStrings("DIV", getOpName(0x04));
    try testing.expectEqualStrings("SDIV", getOpName(0x05));
    try testing.expectEqualStrings("MOD", getOpName(0x06));
    try testing.expectEqualStrings("SMOD", getOpName(0x07));
    try testing.expectEqualStrings("ADDMOD", getOpName(0x08));
    try testing.expectEqualStrings("MULMOD", getOpName(0x09));
    try testing.expectEqualStrings("EXP", getOpName(0x0a));
    try testing.expectEqualStrings("SIGNEXTEND", getOpName(0x0b));
}

test "getOpName: comparison opcodes" {
    const testing = std.testing;
    try testing.expectEqualStrings("LT", getOpName(0x10));
    try testing.expectEqualStrings("GT", getOpName(0x11));
    try testing.expectEqualStrings("SLT", getOpName(0x12));
    try testing.expectEqualStrings("SGT", getOpName(0x13));
    try testing.expectEqualStrings("EQ", getOpName(0x14));
    try testing.expectEqualStrings("ISZERO", getOpName(0x15));
}

test "getOpName: bitwise opcodes" {
    const testing = std.testing;
    try testing.expectEqualStrings("AND", getOpName(0x16));
    try testing.expectEqualStrings("OR", getOpName(0x17));
    try testing.expectEqualStrings("XOR", getOpName(0x18));
    try testing.expectEqualStrings("NOT", getOpName(0x19));
    try testing.expectEqualStrings("BYTE", getOpName(0x1a));
    try testing.expectEqualStrings("SHL", getOpName(0x1b));
    try testing.expectEqualStrings("SHR", getOpName(0x1c));
    try testing.expectEqualStrings("SAR", getOpName(0x1d));
}

test "getOpName: hash opcodes" {
    const testing = std.testing;
    try testing.expectEqualStrings("KECCAK256", getOpName(0x20));
}

test "getOpName: context opcodes" {
    const testing = std.testing;
    try testing.expectEqualStrings("ADDRESS", getOpName(0x30));
    try testing.expectEqualStrings("BALANCE", getOpName(0x31));
    try testing.expectEqualStrings("ORIGIN", getOpName(0x32));
    try testing.expectEqualStrings("CALLER", getOpName(0x33));
    try testing.expectEqualStrings("CALLVALUE", getOpName(0x34));
    try testing.expectEqualStrings("CALLDATALOAD", getOpName(0x35));
    try testing.expectEqualStrings("CALLDATASIZE", getOpName(0x36));
    try testing.expectEqualStrings("CALLDATACOPY", getOpName(0x37));
    try testing.expectEqualStrings("CODESIZE", getOpName(0x38));
    try testing.expectEqualStrings("CODECOPY", getOpName(0x39));
    try testing.expectEqualStrings("GASPRICE", getOpName(0x3a));
    try testing.expectEqualStrings("EXTCODESIZE", getOpName(0x3b));
    try testing.expectEqualStrings("EXTCODECOPY", getOpName(0x3c));
    try testing.expectEqualStrings("RETURNDATASIZE", getOpName(0x3d));
    try testing.expectEqualStrings("RETURNDATACOPY", getOpName(0x3e));
    try testing.expectEqualStrings("EXTCODEHASH", getOpName(0x3f));
}

test "getOpName: block opcodes" {
    const testing = std.testing;
    try testing.expectEqualStrings("BLOCKHASH", getOpName(0x40));
    try testing.expectEqualStrings("COINBASE", getOpName(0x41));
    try testing.expectEqualStrings("TIMESTAMP", getOpName(0x42));
    try testing.expectEqualStrings("NUMBER", getOpName(0x43));
    try testing.expectEqualStrings("DIFFICULTY", getOpName(0x44));
    try testing.expectEqualStrings("GASLIMIT", getOpName(0x45));
    try testing.expectEqualStrings("CHAINID", getOpName(0x46));
    try testing.expectEqualStrings("SELFBALANCE", getOpName(0x47));
    try testing.expectEqualStrings("BASEFEE", getOpName(0x48));
    try testing.expectEqualStrings("BLOBHASH", getOpName(0x49));
    try testing.expectEqualStrings("BLOBBASEFEE", getOpName(0x4a));
}

test "getOpName: stack and memory opcodes" {
    const testing = std.testing;
    try testing.expectEqualStrings("POP", getOpName(0x50));
    try testing.expectEqualStrings("MLOAD", getOpName(0x51));
    try testing.expectEqualStrings("MSTORE", getOpName(0x52));
    try testing.expectEqualStrings("MSTORE8", getOpName(0x53));
    try testing.expectEqualStrings("SLOAD", getOpName(0x54));
    try testing.expectEqualStrings("SSTORE", getOpName(0x55));
    try testing.expectEqualStrings("JUMP", getOpName(0x56));
    try testing.expectEqualStrings("JUMPI", getOpName(0x57));
    try testing.expectEqualStrings("PC", getOpName(0x58));
    try testing.expectEqualStrings("MSIZE", getOpName(0x59));
    try testing.expectEqualStrings("GAS", getOpName(0x5a));
    try testing.expectEqualStrings("JUMPDEST", getOpName(0x5b));
    try testing.expectEqualStrings("TLOAD", getOpName(0x5c));
    try testing.expectEqualStrings("TSTORE", getOpName(0x5d));
    try testing.expectEqualStrings("MCOPY", getOpName(0x5e));
}

test "getOpName: PUSH opcodes" {
    const testing = std.testing;
    try testing.expectEqualStrings("PUSH0", getOpName(0x5f));
    try testing.expectEqualStrings("PUSH1", getOpName(0x60));
    try testing.expectEqualStrings("PUSH2", getOpName(0x61));
    try testing.expectEqualStrings("PUSH16", getOpName(0x6f));
    try testing.expectEqualStrings("PUSH32", getOpName(0x7f));
}

test "getOpName: DUP opcodes" {
    const testing = std.testing;
    try testing.expectEqualStrings("DUP1", getOpName(0x80));
    try testing.expectEqualStrings("DUP2", getOpName(0x81));
    try testing.expectEqualStrings("DUP8", getOpName(0x87));
    try testing.expectEqualStrings("DUP16", getOpName(0x8f));
}

test "getOpName: SWAP opcodes" {
    const testing = std.testing;
    try testing.expectEqualStrings("SWAP1", getOpName(0x90));
    try testing.expectEqualStrings("SWAP2", getOpName(0x91));
    try testing.expectEqualStrings("SWAP8", getOpName(0x97));
    try testing.expectEqualStrings("SWAP16", getOpName(0x9f));
}

test "getOpName: LOG opcodes" {
    const testing = std.testing;
    try testing.expectEqualStrings("LOG0", getOpName(0xa0));
    try testing.expectEqualStrings("LOG1", getOpName(0xa1));
    try testing.expectEqualStrings("LOG2", getOpName(0xa2));
    try testing.expectEqualStrings("LOG3", getOpName(0xa3));
    try testing.expectEqualStrings("LOG4", getOpName(0xa4));
}

test "getOpName: system opcodes" {
    const testing = std.testing;
    try testing.expectEqualStrings("CREATE", getOpName(0xf0));
    try testing.expectEqualStrings("CALL", getOpName(0xf1));
    try testing.expectEqualStrings("CALLCODE", getOpName(0xf2));
    try testing.expectEqualStrings("RETURN", getOpName(0xf3));
    try testing.expectEqualStrings("DELEGATECALL", getOpName(0xf4));
    try testing.expectEqualStrings("CREATE2", getOpName(0xf5));
    try testing.expectEqualStrings("STATICCALL", getOpName(0xfa));
    try testing.expectEqualStrings("REVERT", getOpName(0xfd));
    try testing.expectEqualStrings("INVALID", getOpName(0xfe));
    try testing.expectEqualStrings("SELFDESTRUCT", getOpName(0xff));
}

test "getOpName: invalid opcodes return UNKNOWN" {
    const testing = std.testing;
    try testing.expectEqualStrings("UNKNOWN", getOpName(0x0c));
    try testing.expectEqualStrings("UNKNOWN", getOpName(0x21));
    try testing.expectEqualStrings("UNKNOWN", getOpName(0xa5));
    try testing.expectEqualStrings("UNKNOWN", getOpName(0xf6));
    try testing.expectEqualStrings("UNKNOWN", getOpName(0xfb));
    try testing.expectEqualStrings("UNKNOWN", getOpName(0xfc));
}
