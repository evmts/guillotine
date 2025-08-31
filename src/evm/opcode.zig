const std = @import("std");

/// EVM opcodes enumeration
pub const Opcode = enum(u8) {
    // 0x00s: Stop and Arithmetic Operations
    STOP = 0x00,
    ADD = 0x01,
    MUL = 0x02,
    SUB = 0x03,
    DIV = 0x04,
    SDIV = 0x05,
    MOD = 0x06,
    SMOD = 0x07,
    ADDMOD = 0x08,
    MULMOD = 0x09,
    EXP = 0x0a,
    SIGNEXTEND = 0x0b,
    // 0x10s: Comparison & Bitwise Logic Operations
    LT = 0x10,
    GT = 0x11,
    SLT = 0x12,
    SGT = 0x13,
    EQ = 0x14,
    ISZERO = 0x15,
    AND = 0x16,
    OR = 0x17,
    XOR = 0x18,
    NOT = 0x19,
    BYTE = 0x1a,
    SHL = 0x1b,
    SHR = 0x1c,
    SAR = 0x1d,
    // 0x20s: Crypto
    KECCAK256 = 0x20,
    // 0x30s: Environmental Information
    ADDRESS = 0x30,
    BALANCE = 0x31,
    ORIGIN = 0x32,
    CALLER = 0x33,
    CALLVALUE = 0x34,
    CALLDATALOAD = 0x35,
    CALLDATASIZE = 0x36,
    CALLDATACOPY = 0x37,
    CODESIZE = 0x38,
    CODECOPY = 0x39,
    GASPRICE = 0x3a,
    EXTCODESIZE = 0x3b,
    EXTCODECOPY = 0x3c,
    RETURNDATASIZE = 0x3d,
    RETURNDATACOPY = 0x3e,
    EXTCODEHASH = 0x3f,
    // 0x40s: Block Information
    BLOCKHASH = 0x40,
    COINBASE = 0x41,
    TIMESTAMP = 0x42,
    NUMBER = 0x43,
    DIFFICULTY = 0x44,
    GASLIMIT = 0x45,
    CHAINID = 0x46,
    SELFBALANCE = 0x47,
    BASEFEE = 0x48,
    BLOBHASH = 0x49,
    BLOBBASEFEE = 0x4a,
    // 0x50s: Stack, Memory, Storage and Flow Operations
    POP = 0x50,
    MLOAD = 0x51,
    MSTORE = 0x52,
    MSTORE8 = 0x53,
    SLOAD = 0x54,
    SSTORE = 0x55,
    JUMP = 0x56,
    JUMPI = 0x57,
    PC = 0x58,
    MSIZE = 0x59,
    GAS = 0x5a,
    JUMPDEST = 0x5b,
    TLOAD = 0x5c,
    TSTORE = 0x5d,
    MCOPY = 0x5e,
    PUSH0 = 0x5f,
    // 0x60-0x7f: PUSH1-PUSH32
    PUSH1 = 0x60,
    PUSH2 = 0x61,
    PUSH3 = 0x62,
    PUSH4 = 0x63,
    PUSH5 = 0x64,
    PUSH6 = 0x65,
    PUSH7 = 0x66,
    PUSH8 = 0x67,
    PUSH9 = 0x68,
    PUSH10 = 0x69,
    PUSH11 = 0x6a,
    PUSH12 = 0x6b,
    PUSH13 = 0x6c,
    PUSH14 = 0x6d,
    PUSH15 = 0x6e,
    PUSH16 = 0x6f,
    PUSH17 = 0x70,
    PUSH18 = 0x71,
    PUSH19 = 0x72,
    PUSH20 = 0x73,
    PUSH21 = 0x74,
    PUSH22 = 0x75,
    PUSH23 = 0x76,
    PUSH24 = 0x77,
    PUSH25 = 0x78,
    PUSH26 = 0x79,
    PUSH27 = 0x7a,
    PUSH28 = 0x7b,
    PUSH29 = 0x7c,
    PUSH30 = 0x7d,
    PUSH31 = 0x7e,
    PUSH32 = 0x7f,
    // 0x80s: DUP1-DUP16
    DUP1 = 0x80,
    DUP2 = 0x81,
    DUP3 = 0x82,
    DUP4 = 0x83,
    DUP5 = 0x84,
    DUP6 = 0x85,
    DUP7 = 0x86,
    DUP8 = 0x87,
    DUP9 = 0x88,
    DUP10 = 0x89,
    DUP11 = 0x8a,
    DUP12 = 0x8b,
    DUP13 = 0x8c,
    DUP14 = 0x8d,
    DUP15 = 0x8e,
    DUP16 = 0x8f,
    // 0x90s: SWAP1-SWAP16
    SWAP1 = 0x90,
    SWAP2 = 0x91,
    SWAP3 = 0x92,
    SWAP4 = 0x93,
    SWAP5 = 0x94,
    SWAP6 = 0x95,
    SWAP7 = 0x96,
    SWAP8 = 0x97,
    SWAP9 = 0x98,
    SWAP10 = 0x99,
    SWAP11 = 0x9a,
    SWAP12 = 0x9b,
    SWAP13 = 0x9c,
    SWAP14 = 0x9d,
    SWAP15 = 0x9e,
    SWAP16 = 0x9f,
    // 0xa0s: LOG0-LOG4
    LOG0 = 0xa0,
    LOG1 = 0xa1,
    LOG2 = 0xa2,
    LOG3 = 0xa3,
    LOG4 = 0xa4,
    // 0xf0s: System Operations
    CREATE = 0xf0,
    CALL = 0xf1,
    CALLCODE = 0xf2,
    RETURN = 0xf3,
    DELEGATECALL = 0xf4,
    CREATE2 = 0xf5,
    AUTH = 0xf6, // EIP-3074
    AUTHCALL = 0xf7, // EIP-3074
    STATICCALL = 0xfa,
    REVERT = 0xfd,
    INVALID = 0xfe,
    SELFDESTRUCT = 0xff,
    
    /// Check if opcode is a PUSH operation
    pub fn isPush(self: Opcode) bool {
        const value = @intFromEnum(self);
        return value >= 0x5f and value <= 0x7f; // PUSH0 through PUSH32
    }
    
    /// Get the number of bytes pushed for PUSH operations (0-32)
    pub fn pushSize(self: Opcode) u8 {
        if (!self.isPush()) return 0;
        
        const value = @intFromEnum(self);
        if (value == 0x5f) return 0; // PUSH0
        return value - 0x5f; // PUSH1=1, PUSH2=2, ..., PUSH32=32
    }
    
    /// Check if opcode is a DUP operation
    pub fn isDup(self: Opcode) bool {
        const value = @intFromEnum(self);
        return value >= 0x80 and value <= 0x8f; // DUP1 through DUP16
    }
    
    /// Get the DUP position (1-16)
    pub fn dupPosition(self: Opcode) u8 {
        if (!self.isDup()) return 0;
        const value = @intFromEnum(self);
        return value - 0x7f; // DUP1=1, DUP2=2, ..., DUP16=16
    }
    
    /// Check if opcode is a SWAP operation
    pub fn isSwap(self: Opcode) bool {
        const value = @intFromEnum(self);
        return value >= 0x90 and value <= 0x9f; // SWAP1 through SWAP16
    }
    
    /// Get the SWAP position (1-16)
    pub fn swapPosition(self: Opcode) u8 {
        if (!self.isSwap()) return 0;
        const value = @intFromEnum(self);
        return value - 0x8f; // SWAP1=1, SWAP2=2, ..., SWAP16=16
    }
    
    /// Check if opcode is a LOG operation
    pub fn isLog(self: Opcode) bool {
        const value = @intFromEnum(self);
        return value >= 0xa0 and value <= 0xa4; // LOG0 through LOG4
    }
    
    /// Get the number of topics for LOG operations (0-4)
    pub fn logTopics(self: Opcode) u8 {
        if (!self.isLog()) return 0;
        const value = @intFromEnum(self);
        return value - 0xa0; // LOG0=0, LOG1=1, ..., LOG4=4
    }
    
    /// Check if opcode terminates execution
    pub fn isTerminating(self: Opcode) bool {
        return switch (self) {
            .STOP, .RETURN, .REVERT, .INVALID, .SELFDESTRUCT => true,
            else => false,
        };
    }
    
    /// Check if opcode can modify state
    pub fn isStateModifying(self: Opcode) bool {
        return switch (self) {
            .SSTORE, .TSTORE, .LOG0, .LOG1, .LOG2, .LOG3, .LOG4,
            .CREATE, .CREATE2, .CALL, .CALLCODE, .DELEGATECALL,
            .AUTHCALL, .SELFDESTRUCT => true,
            else => false,
        };
    }
    
    /// Check if opcode is arithmetic
    pub fn isArithmetic(self: Opcode) bool {
        return switch (self) {
            .ADD, .MUL, .SUB, .DIV, .SDIV, .MOD, .SMOD,
            .ADDMOD, .MULMOD, .EXP, .SIGNEXTEND => true,
            else => false,
        };
    }
    
    /// Check if opcode is comparison
    pub fn isComparison(self: Opcode) bool {
        return switch (self) {
            .LT, .GT, .SLT, .SGT, .EQ, .ISZERO => true,
            else => false,
        };
    }
    
    /// Check if opcode is bitwise
    pub fn isBitwise(self: Opcode) bool {
        return switch (self) {
            .AND, .OR, .XOR, .NOT, .BYTE, .SHL, .SHR, .SAR => true,
            else => false,
        };
    }
    
    /// Get opcode name as string
    pub fn name(self: Opcode) []const u8 {
        return switch (self) {
            .STOP => "STOP",
            .ADD => "ADD",
            .MUL => "MUL",
            .SUB => "SUB",
            .DIV => "DIV",
            .SDIV => "SDIV",
            .MOD => "MOD",
            .SMOD => "SMOD",
            .ADDMOD => "ADDMOD",
            .MULMOD => "MULMOD",
            .EXP => "EXP",
            .SIGNEXTEND => "SIGNEXTEND",
            .LT => "LT",
            .GT => "GT",
            .SLT => "SLT",
            .SGT => "SGT",
            .EQ => "EQ",
            .ISZERO => "ISZERO",
            .AND => "AND",
            .OR => "OR",
            .XOR => "XOR",
            .NOT => "NOT",
            .BYTE => "BYTE",
            .SHL => "SHL",
            .SHR => "SHR",
            .SAR => "SAR",
            .KECCAK256 => "KECCAK256",
            .ADDRESS => "ADDRESS",
            .BALANCE => "BALANCE",
            .ORIGIN => "ORIGIN",
            .CALLER => "CALLER",
            .CALLVALUE => "CALLVALUE",
            .CALLDATALOAD => "CALLDATALOAD",
            .CALLDATASIZE => "CALLDATASIZE",
            .CALLDATACOPY => "CALLDATACOPY",
            .CODESIZE => "CODESIZE",
            .CODECOPY => "CODECOPY",
            .GASPRICE => "GASPRICE",
            .EXTCODESIZE => "EXTCODESIZE",
            .EXTCODECOPY => "EXTCODECOPY",
            .RETURNDATASIZE => "RETURNDATASIZE",
            .RETURNDATACOPY => "RETURNDATACOPY",
            .EXTCODEHASH => "EXTCODEHASH",
            .BLOCKHASH => "BLOCKHASH",
            .COINBASE => "COINBASE",
            .TIMESTAMP => "TIMESTAMP",
            .NUMBER => "NUMBER",
            .DIFFICULTY => "DIFFICULTY",
            .GASLIMIT => "GASLIMIT",
            .CHAINID => "CHAINID",
            .SELFBALANCE => "SELFBALANCE",
            .BASEFEE => "BASEFEE",
            .BLOBHASH => "BLOBHASH",
            .BLOBBASEFEE => "BLOBBASEFEE",
            .POP => "POP",
            .MLOAD => "MLOAD",
            .MSTORE => "MSTORE",
            .MSTORE8 => "MSTORE8",
            .SLOAD => "SLOAD",
            .SSTORE => "SSTORE",
            .JUMP => "JUMP",
            .JUMPI => "JUMPI",
            .PC => "PC",
            .MSIZE => "MSIZE",
            .GAS => "GAS",
            .JUMPDEST => "JUMPDEST",
            .TLOAD => "TLOAD",
            .TSTORE => "TSTORE",
            .MCOPY => "MCOPY",
            .PUSH0 => "PUSH0",
            .PUSH1 => "PUSH1",
            .PUSH2 => "PUSH2",
            .PUSH3 => "PUSH3",
            .PUSH4 => "PUSH4",
            .PUSH5 => "PUSH5",
            .PUSH6 => "PUSH6",
            .PUSH7 => "PUSH7",
            .PUSH8 => "PUSH8",
            .PUSH9 => "PUSH9",
            .PUSH10 => "PUSH10",
            .PUSH11 => "PUSH11",
            .PUSH12 => "PUSH12",
            .PUSH13 => "PUSH13",
            .PUSH14 => "PUSH14",
            .PUSH15 => "PUSH15",
            .PUSH16 => "PUSH16",
            .PUSH17 => "PUSH17",
            .PUSH18 => "PUSH18",
            .PUSH19 => "PUSH19",
            .PUSH20 => "PUSH20",
            .PUSH21 => "PUSH21",
            .PUSH22 => "PUSH22",
            .PUSH23 => "PUSH23",
            .PUSH24 => "PUSH24",
            .PUSH25 => "PUSH25",
            .PUSH26 => "PUSH26",
            .PUSH27 => "PUSH27",
            .PUSH28 => "PUSH28",
            .PUSH29 => "PUSH29",
            .PUSH30 => "PUSH30",
            .PUSH31 => "PUSH31",
            .PUSH32 => "PUSH32",
            .DUP1 => "DUP1",
            .DUP2 => "DUP2",
            .DUP3 => "DUP3",
            .DUP4 => "DUP4",
            .DUP5 => "DUP5",
            .DUP6 => "DUP6",
            .DUP7 => "DUP7",
            .DUP8 => "DUP8",
            .DUP9 => "DUP9",
            .DUP10 => "DUP10",
            .DUP11 => "DUP11",
            .DUP12 => "DUP12",
            .DUP13 => "DUP13",
            .DUP14 => "DUP14",
            .DUP15 => "DUP15",
            .DUP16 => "DUP16",
            .SWAP1 => "SWAP1",
            .SWAP2 => "SWAP2",
            .SWAP3 => "SWAP3",
            .SWAP4 => "SWAP4",
            .SWAP5 => "SWAP5",
            .SWAP6 => "SWAP6",
            .SWAP7 => "SWAP7",
            .SWAP8 => "SWAP8",
            .SWAP9 => "SWAP9",
            .SWAP10 => "SWAP10",
            .SWAP11 => "SWAP11",
            .SWAP12 => "SWAP12",
            .SWAP13 => "SWAP13",
            .SWAP14 => "SWAP14",
            .SWAP15 => "SWAP15",
            .SWAP16 => "SWAP16",
            .LOG0 => "LOG0",
            .LOG1 => "LOG1",
            .LOG2 => "LOG2",
            .LOG3 => "LOG3",
            .LOG4 => "LOG4",
            .CREATE => "CREATE",
            .CALL => "CALL",
            .CALLCODE => "CALLCODE",
            .RETURN => "RETURN",
            .DELEGATECALL => "DELEGATECALL",
            .CREATE2 => "CREATE2",
            .AUTH => "AUTH",
            .AUTHCALL => "AUTHCALL",
            .STATICCALL => "STATICCALL",
            .REVERT => "REVERT",
            .INVALID => "INVALID",
            .SELFDESTRUCT => "SELFDESTRUCT",
        };
    }
};

test "opcode enum values" {
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(Opcode.STOP));
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(Opcode.ADD));
    try std.testing.expectEqual(@as(u8, 0x5f), @intFromEnum(Opcode.PUSH0));
    try std.testing.expectEqual(@as(u8, 0x60), @intFromEnum(Opcode.PUSH1));
    try std.testing.expectEqual(@as(u8, 0x7f), @intFromEnum(Opcode.PUSH32));
    try std.testing.expectEqual(@as(u8, 0xff), @intFromEnum(Opcode.SELFDESTRUCT));
}

test "opcode push detection" {
    try std.testing.expect(Opcode.PUSH0.isPush());
    try std.testing.expect(Opcode.PUSH1.isPush());
    try std.testing.expect(Opcode.PUSH16.isPush());
    try std.testing.expect(Opcode.PUSH32.isPush());
    
    try std.testing.expect(!Opcode.ADD.isPush());
    try std.testing.expect(!Opcode.DUP1.isPush());
    try std.testing.expect(!Opcode.STOP.isPush());
}

test "opcode push size calculation" {
    try std.testing.expectEqual(@as(u8, 0), Opcode.PUSH0.pushSize());
    try std.testing.expectEqual(@as(u8, 1), Opcode.PUSH1.pushSize());
    try std.testing.expectEqual(@as(u8, 16), Opcode.PUSH16.pushSize());
    try std.testing.expectEqual(@as(u8, 32), Opcode.PUSH32.pushSize());
    
    // Non-push opcodes return 0
    try std.testing.expectEqual(@as(u8, 0), Opcode.ADD.pushSize());
    try std.testing.expectEqual(@as(u8, 0), Opcode.DUP1.pushSize());
}

test "opcode dup detection" {
    try std.testing.expect(Opcode.DUP1.isDup());
    try std.testing.expect(Opcode.DUP8.isDup());
    try std.testing.expect(Opcode.DUP16.isDup());
    
    try std.testing.expect(!Opcode.PUSH1.isDup());
    try std.testing.expect(!Opcode.SWAP1.isDup());
    try std.testing.expect(!Opcode.ADD.isDup());
}

test "opcode dup position calculation" {
    try std.testing.expectEqual(@as(u8, 1), Opcode.DUP1.dupPosition());
    try std.testing.expectEqual(@as(u8, 8), Opcode.DUP8.dupPosition());
    try std.testing.expectEqual(@as(u8, 16), Opcode.DUP16.dupPosition());
    
    // Non-dup opcodes return 0
    try std.testing.expectEqual(@as(u8, 0), Opcode.PUSH1.dupPosition());
    try std.testing.expectEqual(@as(u8, 0), Opcode.ADD.dupPosition());
}

test "opcode swap detection" {
    try std.testing.expect(Opcode.SWAP1.isSwap());
    try std.testing.expect(Opcode.SWAP8.isSwap());
    try std.testing.expect(Opcode.SWAP16.isSwap());
    
    try std.testing.expect(!Opcode.DUP1.isSwap());
    try std.testing.expect(!Opcode.PUSH1.isSwap());
    try std.testing.expect(!Opcode.ADD.isSwap());
}

test "opcode swap position calculation" {
    try std.testing.expectEqual(@as(u8, 1), Opcode.SWAP1.swapPosition());
    try std.testing.expectEqual(@as(u8, 8), Opcode.SWAP8.swapPosition());
    try std.testing.expectEqual(@as(u8, 16), Opcode.SWAP16.swapPosition());
    
    // Non-swap opcodes return 0
    try std.testing.expectEqual(@as(u8, 0), Opcode.DUP1.swapPosition());
    try std.testing.expectEqual(@as(u8, 0), Opcode.ADD.swapPosition());
}

test "opcode log detection" {
    try std.testing.expect(Opcode.LOG0.isLog());
    try std.testing.expect(Opcode.LOG1.isLog());
    try std.testing.expect(Opcode.LOG4.isLog());
    
    try std.testing.expect(!Opcode.ADD.isLog());
    try std.testing.expect(!Opcode.SSTORE.isLog());
    try std.testing.expect(!Opcode.CALL.isLog());
}

test "opcode log topics calculation" {
    try std.testing.expectEqual(@as(u8, 0), Opcode.LOG0.logTopics());
    try std.testing.expectEqual(@as(u8, 1), Opcode.LOG1.logTopics());
    try std.testing.expectEqual(@as(u8, 4), Opcode.LOG4.logTopics());
    
    // Non-log opcodes return 0
    try std.testing.expectEqual(@as(u8, 0), Opcode.ADD.logTopics());
    try std.testing.expectEqual(@as(u8, 0), Opcode.SSTORE.logTopics());
}

test "opcode terminating detection" {
    try std.testing.expect(Opcode.STOP.isTerminating());
    try std.testing.expect(Opcode.RETURN.isTerminating());
    try std.testing.expect(Opcode.REVERT.isTerminating());
    try std.testing.expect(Opcode.INVALID.isTerminating());
    try std.testing.expect(Opcode.SELFDESTRUCT.isTerminating());
    
    try std.testing.expect(!Opcode.ADD.isTerminating());
    try std.testing.expect(!Opcode.JUMP.isTerminating());
    try std.testing.expect(!Opcode.CALL.isTerminating());
}

test "opcode state modifying detection" {
    try std.testing.expect(Opcode.SSTORE.isStateModifying());
    try std.testing.expect(Opcode.TSTORE.isStateModifying());
    try std.testing.expect(Opcode.LOG0.isStateModifying());
    try std.testing.expect(Opcode.LOG4.isStateModifying());
    try std.testing.expect(Opcode.CREATE.isStateModifying());
    try std.testing.expect(Opcode.CALL.isStateModifying());
    try std.testing.expect(Opcode.SELFDESTRUCT.isStateModifying());
    
    try std.testing.expect(!Opcode.ADD.isStateModifying());
    try std.testing.expect(!Opcode.SLOAD.isStateModifying());
    try std.testing.expect(!Opcode.STATICCALL.isStateModifying());
}

test "opcode arithmetic detection" {
    try std.testing.expect(Opcode.ADD.isArithmetic());
    try std.testing.expect(Opcode.MUL.isArithmetic());
    try std.testing.expect(Opcode.DIV.isArithmetic());
    try std.testing.expect(Opcode.MOD.isArithmetic());
    try std.testing.expect(Opcode.EXP.isArithmetic());
    try std.testing.expect(Opcode.SIGNEXTEND.isArithmetic());
    
    try std.testing.expect(!Opcode.LT.isArithmetic());
    try std.testing.expect(!Opcode.AND.isArithmetic());
    try std.testing.expect(!Opcode.PUSH1.isArithmetic());
}

test "opcode comparison detection" {
    try std.testing.expect(Opcode.LT.isComparison());
    try std.testing.expect(Opcode.GT.isComparison());
    try std.testing.expect(Opcode.EQ.isComparison());
    try std.testing.expect(Opcode.ISZERO.isComparison());
    
    try std.testing.expect(!Opcode.ADD.isComparison());
    try std.testing.expect(!Opcode.AND.isComparison());
    try std.testing.expect(!Opcode.PUSH1.isComparison());
}

test "opcode bitwise detection" {
    try std.testing.expect(Opcode.AND.isBitwise());
    try std.testing.expect(Opcode.OR.isBitwise());
    try std.testing.expect(Opcode.XOR.isBitwise());
    try std.testing.expect(Opcode.NOT.isBitwise());
    try std.testing.expect(Opcode.SHL.isBitwise());
    try std.testing.expect(Opcode.SHR.isBitwise());
    
    try std.testing.expect(!Opcode.ADD.isBitwise());
    try std.testing.expect(!Opcode.LT.isBitwise());
    try std.testing.expect(!Opcode.PUSH1.isBitwise());
}

test "opcode names" {
    try std.testing.expectEqualStrings("ADD", Opcode.ADD.name());
    try std.testing.expectEqualStrings("PUSH1", Opcode.PUSH1.name());
    try std.testing.expectEqualStrings("DUP1", Opcode.DUP1.name());
    try std.testing.expectEqualStrings("SWAP16", Opcode.SWAP16.name());
    try std.testing.expectEqualStrings("LOG4", Opcode.LOG4.name());
    try std.testing.expectEqualStrings("SELFDESTRUCT", Opcode.SELFDESTRUCT.name());
}

test "opcode edge cases" {
    // Test boundary values
    const push0_value = @intFromEnum(Opcode.PUSH0);
    const push32_value = @intFromEnum(Opcode.PUSH32);
    try std.testing.expect(push0_value == 0x5f);
    try std.testing.expect(push32_value == 0x7f);
    
    // Test DUP/SWAP boundaries
    const dup1_value = @intFromEnum(Opcode.DUP1);
    const dup16_value = @intFromEnum(Opcode.DUP16);
    try std.testing.expect(dup1_value == 0x80);
    try std.testing.expect(dup16_value == 0x8f);
    
    const swap1_value = @intFromEnum(Opcode.SWAP1);
    const swap16_value = @intFromEnum(Opcode.SWAP16);
    try std.testing.expect(swap1_value == 0x90);
    try std.testing.expect(swap16_value == 0x9f);
    
    // Test LOG boundaries
    const log0_value = @intFromEnum(Opcode.LOG0);
    const log4_value = @intFromEnum(Opcode.LOG4);
    try std.testing.expect(log0_value == 0xa0);
    try std.testing.expect(log4_value == 0xa4);
}

test "opcode categorization completeness" {
    // Verify that all opcodes in each category are properly detected
    const push_opcodes = [_]Opcode{
        .PUSH0, .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7,
        .PUSH8, .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15,
        .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23,
        .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31,
        .PUSH32
    };
    
    for (push_opcodes) |opcode| {
        try std.testing.expect(opcode.isPush());
    }
    
    const dup_opcodes = [_]Opcode{
        .DUP1, .DUP2, .DUP3, .DUP4, .DUP5, .DUP6, .DUP7, .DUP8,
        .DUP9, .DUP10, .DUP11, .DUP12, .DUP13, .DUP14, .DUP15, .DUP16
    };
    
    for (dup_opcodes) |opcode| {
        try std.testing.expect(opcode.isDup());
    }
    
    const swap_opcodes = [_]Opcode{
        .SWAP1, .SWAP2, .SWAP3, .SWAP4, .SWAP5, .SWAP6, .SWAP7, .SWAP8,
        .SWAP9, .SWAP10, .SWAP11, .SWAP12, .SWAP13, .SWAP14, .SWAP15, .SWAP16
    };
    
    for (swap_opcodes) |opcode| {
        try std.testing.expect(opcode.isSwap());
    }
}