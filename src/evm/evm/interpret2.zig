const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const Evm = @import("../evm.zig");

/// EVM opcodes enumeration for lazy analysis interpreter
const Opcodes = enum(u8) {
    /// Halts execution (0x00)
    STOP = 0x00,
    /// Addition operation: a + b (0x01)
    ADD = 0x01,
    /// Multiplication operation: a * b (0x02)
    MUL = 0x02,
    /// Subtraction operation: a - b (0x03)
    SUB = 0x03,
    /// Integer division operation: a / b (0x04)
    DIV = 0x04,
    /// Signed integer division operation (0x05)
    SDIV = 0x05,
    /// Modulo operation: a % b (0x06)
    MOD = 0x06,
    /// Signed modulo operation (0x07)
    SMOD = 0x07,
    /// Addition modulo: (a + b) % N (0x08)
    ADDMOD = 0x08,
    /// Multiplication modulo: (a * b) % N (0x09)
    MULMOD = 0x09,
    /// Exponential operation: a ** b (0x0A)
    EXP = 0x0A,
    /// Sign extend operation (0x0B)
    SIGNEXTEND = 0x0B,
    /// Less-than comparison: a < b (0x10)
    LT = 0x10,
    /// Greater-than comparison: a > b (0x11)
    GT = 0x11,
    /// Signed less-than comparison (0x12)
    SLT = 0x12,
    /// Signed greater-than comparison (0x13)
    SGT = 0x13,
    /// Equality comparison: a == b (0x14)
    EQ = 0x14,
    /// Check if value is zero (0x15)
    ISZERO = 0x15,
    /// Bitwise AND operation (0x16)
    AND = 0x16,
    /// Bitwise OR operation (0x17)
    OR = 0x17,
    /// Bitwise XOR operation (0x18)
    XOR = 0x18,
    /// Bitwise NOT operation (0x19)
    NOT = 0x19,
    /// Retrieve single byte from word (0x1A)
    BYTE = 0x1A,
    /// Logical shift left (0x1B)
    SHL = 0x1B,
    /// Logical shift right (0x1C)
    SHR = 0x1C,
    /// Arithmetic shift right (0x1D)
    SAR = 0x1D,
    /// Compute Keccak-256 hash (0x20)
    KECCAK256 = 0x20,
    /// Get address of currently executing account (0x30)
    ADDRESS = 0x30,
    /// Get balance of the given account (0x31)
    BALANCE = 0x31,
    /// Get execution origination address (0x32)
    ORIGIN,
    /// Get caller address (0x33)
    CALLER,
    /// Get deposited value by the caller (0x34)
    CALLVALUE,
    /// Load input data of current call (0x35)
    CALLDATALOAD,
    /// Get size of input data in current call (0x36)
    CALLDATASIZE,
    /// Copy input data to memory (0x37)
    CALLDATACOPY,
    /// Get size of code running in current environment (0x38)
    CODESIZE,
    /// Copy code to memory (0x39)
    CODECOPY,
    /// Get price of gas in current environment (0x3A)
    GASPRICE,
    EXTCODESIZE,
    EXTCODECOPY,
    RETURNDATASIZE,
    RETURNDATACOPY,
    EXTCODEHASH,
    BLOCKHASH,
    COINBASE,
    TIMESTAMP,
    NUMBER,
    PREVRANDAO,
    GASLIMIT,
    CHAINID,
    SELFBALANCE,
    BASEFEE,
    BLOBHASH,
    BLOBBASEFEE,
    POP,
    MLOAD,
    MSTORE,
    MSTORE8,
    /// Load word from storage (0x54)
    SLOAD,
    /// Store word to storage (0x55)
    SSTORE,
    /// Unconditional jump (0x56)
    JUMP = 0x56,
    /// Conditional jump (0x57)
    JUMPI = 0x57,
    /// Get current program counter (0x58)
    PC = 0x58,
    /// Get size of active memory in bytes (0x59)
    MSIZE,
    /// Get amount of available gas (0x5A)
    GAS,
    /// Mark valid jump destination (0x5B)
    JUMPDEST,
    /// Load word from transient storage (0x5C)
    TLOAD,
    /// Store word to transient storage (0x5D)
    TSTORE,
    /// Copy memory areas (0x5E)
    MCOPY,
    /// Push zero onto stack (0x5F)
    PUSH0 = 0x5F,
    /// Push 1 byte onto stack (0x60)
    PUSH1 = 0x60,
    /// Push 2 bytes onto stack (0x61)
    PUSH2 = 0x61,
    /// Push 3 bytes onto stack (0x62)
    PUSH3 = 0x62,
    /// Push 4 bytes onto stack (0x63)
    PUSH4 = 0x63,
    /// Push 5 bytes onto stack (0x64)
    PUSH5 = 0x64,
    /// Push 6 bytes onto stack (0x65)
    PUSH6 = 0x65,
    /// Push 7 bytes onto stack (0x66)
    PUSH7 = 0x66,
    /// Push 8 bytes onto stack (0x67)
    PUSH8 = 0x67,
    /// Push 9 bytes onto stack (0x68)
    PUSH9 = 0x68,
    /// Push 10 bytes onto stack (0x69)
    PUSH10 = 0x69,
    /// Push 11 bytes onto stack (0x6A)
    PUSH11 = 0x6A,
    /// Push 12 bytes onto stack (0x6B)
    PUSH12 = 0x6B,
    /// Push 13 bytes onto stack (0x6C)
    PUSH13 = 0x6C,
    /// Push 14 bytes onto stack (0x6D)
    PUSH14 = 0x6D,
    /// Push 15 bytes onto stack (0x6E)
    PUSH15 = 0x6E,
    /// Push 16 bytes onto stack (0x6F)
    PUSH16 = 0x6F,
    /// Push 17 bytes onto stack (0x70)
    PUSH17 = 0x70,
    /// Push 18 bytes onto stack (0x71)
    PUSH18 = 0x71,
    /// Push 19 bytes onto stack (0x72)
    PUSH19 = 0x72,
    /// Push 20 bytes onto stack (0x73)
    PUSH20 = 0x73,
    /// Push 21 bytes onto stack (0x74)
    PUSH21 = 0x74,
    /// Push 22 bytes onto stack (0x75)
    PUSH22 = 0x75,
    /// Push 23 bytes onto stack (0x76)
    PUSH23 = 0x76,
    /// Push 24 bytes onto stack (0x77)
    PUSH24 = 0x77,
    /// Push 25 bytes onto stack (0x78)
    PUSH25 = 0x78,
    /// Push 26 bytes onto stack (0x79)
    PUSH26 = 0x79,
    /// Push 27 bytes onto stack (0x7A)
    PUSH27 = 0x7A,
    /// Push 28 bytes onto stack (0x7B)
    PUSH28 = 0x7B,
    /// Push 29 bytes onto stack (0x7C)
    PUSH29 = 0x7C,
    /// Push 30 bytes onto stack (0x7D)
    PUSH30 = 0x7D,
    /// Push 31 bytes onto stack (0x7E)
    PUSH31 = 0x7E,
    /// Push 32 bytes onto stack (0x7F)
    PUSH32 = 0x7F,
    DUP1,
    DUP2,
    DUP3,
    DUP4,
    DUP5,
    DUP6,
    DUP7,
    DUP8,
    DUP9,
    DUP10,
    DUP11,
    DUP12,
    DUP13,
    DUP14,
    DUP15,
    DUP16,
    SWAP1,
    SWAP2,
    SWAP3,
    SWAP4,
    SWAP5,
    SWAP6,
    SWAP7,
    SWAP8,
    SWAP9,
    SWAP10,
    SWAP11,
    SWAP12,
    SWAP13,
    SWAP14,
    SWAP15,
    SWAP16,
    LOG0,
    LOG1,
    LOG2,
    LOG3,
    LOG4,
    /// Create new contract (0xF0)
    CREATE,
    /// Message-call into account (0xF1)
    CALL,
    /// Message-call with current code (0xF2)
    CALLCODE,
    /// Halt execution returning output data (0xF3)
    RETURN,
    /// Call with current sender and value (0xF4)
    DELEGATECALL,
    /// Create with deterministic address (0xF5)
    CREATE2,
    /// Load return data (0xF7)
    RETURNDATALOAD,
    /// Extended call (EOF) (0xF8)
    EXTCALL,
    /// Extended delegate call (EOF) (0xF9)
    EXTDELEGATECALL,
    /// Static message-call (0xFA)
    STATICCALL,
    /// Extended static call (EOF) (0xFB)
    EXTSTATICCALL,
    /// Halt execution reverting state changes (0xFD)
    REVERT,
    /// Invalid instruction (0xFE)
    INVALID,
    /// Destroy current contract (0xFF)
    SELFDESTRUCT = 0xFF,
};

/// Types of end execution instructions
const EndType = enum(u8) {
    STOP = 0x00, // Halts execution
    RETURN = 0xF3, // Halts execution and returns data
    REVERT = 0xFD, // Halts execution and reverts state
    INVALID = 0xFE, // Invalid instruction
    SELFDESTRUCT = 0xFF, // Destroys contract
};

/// Instruction types for lazy analysis interpreter with parameters (4 bytes exactly)
const Instruction2 = union {
    /// Push small values - stores the actual value directly (4 bytes)
    PUSH_VALUE: u32,
    /// Push large values - stores PC to the PUSH instruction in bytecode (4 bytes)
    PUSH_PC: u32,
    /// PUSH followed by another opcode - stores PC and next opcode (4 bytes)
    PUSH_VALUE_FUSED: packed struct {
        push_value: u16, // PC of the PUSH instruction
        next_opcode: u8, // The opcode that follows the PUSH
        _padding: u8, // Padding to maintain 4-byte alignment
    },
    /// Unconditional jump to known target - stores both PC and instruction index (4 bytes)
    JUMP: packed struct {
        pc: u16, // PC of the jump target in bytecode
        instruction_index: u16, // Index in the instructions array
    },
    /// Conditional jump to known target - stores both PC and instruction index (4 bytes)
    JUMPI: packed struct {
        pc: u16, // PC of the jump target in bytecode
        instruction_index: u16, // Index in the instructions array
    },
    /// Stack validation data - stack requirements for block (4 bytes)
    STACK_VALIDATION_BLOCK: packed struct {
        stack_req: u16, // 16 bits - minimum stack items required (max 65,535)
        stack_max_growth: u16, // 16 bits - maximum stack growth in block (max 65,535)
    },
    /// Aggregated gas cost for block (4 bytes)
    AGGREGATED_GAS: u32,
    /// Dynamic jump - destination determined at runtime from stack (4 bytes)
    UNKNOWN_JUMP: u32, // Placeholder value for 4-byte alignment
    /// Dynamic conditional jump - destination determined at runtime from stack (4 bytes)
    UNKNOWN_JUMPI: u32, // Placeholder value for 4-byte alignment
    /// Execute 4 opcodes in sequence (4 bytes)
    EXEC_4: packed struct {
        opcode1: u8, // First opcode to execute
        opcode2: u8, // Second opcode to execute
        opcode3: u8, // Third opcode to execute
        opcode4: u8, // Fourth opcode to execute
    },
    /// Execute 3 opcodes in sequence (4 bytes)
    EXEC_3: packed struct {
        opcode1: u8, // First opcode to execute
        opcode2: u8, // Second opcode to execute
        opcode3: u8, // Third opcode to execute
        _padding: u8, // Padding to maintain 4-byte alignment
    },
    /// Execute 2 opcodes in sequence (4 bytes)
    EXEC_2: packed struct {
        opcode1: u8, // First opcode to execute
        opcode2: u8, // Second opcode to execute
        _padding: u16, // Padding to maintain 4-byte alignment
    },
    /// Execute 1 opcode (4 bytes)
    EXEC_1: packed struct {
        opcode: u8, // Opcode to execute
        _padding1: u8, // Padding byte 1
        _padding2: u8, // Padding byte 2
        _padding3: u8, // Padding byte 3
    },
    /// End execution instructions (4 bytes)
    END: packed struct {
        end_type: EndType, // Type of end instruction
        _padding1: u8, // Padding byte 1
        _padding2: u8, // Padding byte 2
        _padding3: u8, // Padding byte 3
    },
};

// Compile-time checks for Instruction2 union properties
comptime {
    std.debug.assert(@sizeOf(Instruction2) == 4);
    std.debug.assert(@alignOf(Instruction2) == 4);
}

/// Experimental lazy analysis interpreter (under development).
/// This will eventually execute bytecode with lazy analysis generation during execution.
///
/// TODO: Implement lazy analysis approach instead of pre-computed instruction stream.
pub fn interpret2(self: *Evm, frame: *Frame) ExecutionError.Error!void {
    // For debugging
    var opcodes = std.ArrayList(u8).init(self.allocator);
    defer opcodes.deinit();
    var pcs = std.ArrayList(u16).init(self.allocator);
    defer pcs.deinit();

    // Create null-terminated instruction array
    var instructions = std.ArrayList(Instruction2).init(self.allocator);
    defer instructions.deinit();

    var pc: u16 = 0;
    const bytecode = frame.contract.code;

    var i: usize = 0;
    while (i < instructions.items.len) : (i += 1) {
        const opcode = bytecode[pc];

        // Track opcode and pc
        try opcodes.append(opcode);
        try pcs.append(pc);

        switch (opcode) {
            // Arithmetic operations
            0x00 => return, // STOP
            0x01 => {
                pc += 1;
                continue :dispatch;
            }, // ADD
            0x02 => {
                pc += 1;
                continue :dispatch;
            }, // MUL
            0x03 => {
                pc += 1;
                continue :dispatch;
            }, // SUB
            0x04 => {
                pc += 1;
                continue :dispatch;
            }, // DIV
            0x05 => {
                pc += 1;
                continue :dispatch;
            }, // SDIV
            0x06 => {
                pc += 1;
                continue :dispatch;
            }, // MOD
            0x07 => {
                pc += 1;
                continue :dispatch;
            }, // SMOD
            0x08 => {
                pc += 1;
                continue :dispatch;
            }, // ADDMOD
            0x09 => {
                pc += 1;
                continue :dispatch;
            }, // MULMOD
            0x0A => {
                pc += 1;
                continue :dispatch;
            }, // EXP
            0x0B => {
                pc += 1;
                continue :dispatch;
            }, // SIGNEXTEND

            // Comparison operations
            0x10 => {
                pc += 1;
                continue :dispatch;
            }, // LT
            0x11 => {
                pc += 1;
                continue :dispatch;
            }, // GT
            0x12 => {
                pc += 1;
                continue :dispatch;
            }, // SLT
            0x13 => {
                pc += 1;
                continue :dispatch;
            }, // SGT
            0x14 => {
                pc += 1;
                continue :dispatch;
            }, // EQ
            0x15 => {
                pc += 1;
                continue :dispatch;
            }, // ISZERO

            // Bitwise operations
            0x16 => {
                pc += 1;
                continue :dispatch;
            }, // AND
            0x17 => {
                pc += 1;
                continue :dispatch;
            }, // OR
            0x18 => {
                pc += 1;
                continue :dispatch;
            }, // XOR
            0x19 => {
                pc += 1;
                continue :dispatch;
            }, // NOT
            0x1A => {
                pc += 1;
                continue :dispatch;
            }, // BYTE
            0x1B => {
                pc += 1;
                continue :dispatch;
            }, // SHL
            0x1C => {
                pc += 1;
                continue :dispatch;
            }, // SHR
            0x1D => {
                pc += 1;
                continue :dispatch;
            }, // SAR

            // Crypto operations
            0x20 => {
                pc += 1;
                continue :dispatch;
            }, // KECCAK256

            // Environmental operations
            0x30 => {
                pc += 1;
                continue :dispatch;
            }, // ADDRESS
            0x31 => {
                pc += 1;
                continue :dispatch;
            }, // BALANCE
            0x32 => {
                pc += 1;
                continue :dispatch;
            }, // ORIGIN
            0x33 => {
                pc += 1;
                continue :dispatch;
            }, // CALLER
            0x34 => {
                pc += 1;
                continue :dispatch;
            }, // CALLVALUE
            0x35 => {
                pc += 1;
                continue :dispatch;
            }, // CALLDATALOAD
            0x36 => {
                pc += 1;
                continue :dispatch;
            }, // CALLDATASIZE
            0x37 => {
                pc += 1;
                continue :dispatch;
            }, // CALLDATACOPY
            0x38 => {
                pc += 1;
                continue :dispatch;
            }, // CODESIZE
            0x39 => {
                pc += 1;
                continue :dispatch;
            }, // CODECOPY
            0x3A => {
                pc += 1;
                continue :dispatch;
            }, // GASPRICE
            0x3B => {
                pc += 1;
                continue :dispatch;
            }, // EXTCODESIZE
            0x3C => {
                pc += 1;
                continue :dispatch;
            }, // EXTCODECOPY
            0x3D => {
                pc += 1;
                continue :dispatch;
            }, // RETURNDATASIZE
            0x3E => {
                pc += 1;
                continue :dispatch;
            }, // RETURNDATACOPY
            0x3F => {
                pc += 1;
                continue :dispatch;
            }, // EXTCODEHASH

            // Block operations
            0x40 => {
                pc += 1;
                continue :dispatch;
            }, // BLOCKHASH
            0x41 => {
                pc += 1;
                continue :dispatch;
            }, // COINBASE
            0x42 => {
                pc += 1;
                continue :dispatch;
            }, // TIMESTAMP
            0x43 => {
                pc += 1;
                continue :dispatch;
            }, // NUMBER
            0x44 => {
                pc += 1;
                continue :dispatch;
            }, // PREVRANDAO
            0x45 => {
                pc += 1;
                continue :dispatch;
            }, // GASLIMIT
            0x46 => {
                pc += 1;
                continue :dispatch;
            }, // CHAINID
            0x47 => {
                pc += 1;
                continue :dispatch;
            }, // SELFBALANCE
            0x48 => {
                pc += 1;
                continue :dispatch;
            }, // BASEFEE
            0x49 => {
                pc += 1;
                continue :dispatch;
            }, // BLOBHASH
            0x4A => {
                pc += 1;
                continue :dispatch;
            }, // BLOBBASEFEE

            // Stack operations
            0x50 => {
                pc += 1;
                continue :dispatch;
            }, // POP

            // Memory operations
            0x51 => {
                pc += 1;
                continue :dispatch;
            }, // MLOAD
            0x52 => {
                pc += 1;
                continue :dispatch;
            }, // MSTORE
            0x53 => {
                pc += 1;
                continue :dispatch;
            }, // MSTORE8

            // Storage operations
            0x54 => {
                pc += 1;
                continue :dispatch;
            }, // SLOAD
            0x55 => {
                pc += 1;
                continue :dispatch;
            }, // SSTORE

            // Control flow operations
            0x56 => {
                pc += 1;
                continue :dispatch;
            }, // JUMP
            0x57 => {
                pc += 1;
                continue :dispatch;
            }, // JUMPI
            0x58 => {
                pc += 1;
                continue :dispatch;
            }, // PC
            0x59 => {
                pc += 1;
                continue :dispatch;
            }, // MSIZE
            0x5A => {
                pc += 1;
                continue :dispatch;
            }, // GAS
            0x5B => {
                pc += 1;
                continue :dispatch;
            }, // JUMPDEST
            0x5C => {
                pc += 1;
                continue :dispatch;
            }, // TLOAD
            0x5D => {
                pc += 1;
                continue :dispatch;
            }, // TSTORE
            0x5E => {
                pc += 1;
                continue :dispatch;
            }, // MCOPY

            // Push operations
            0x5F => {
                pc += 1;
                continue :dispatch;
            }, // PUSH0
            0x60...0x7F => |push_op| {
                const push_size = push_op - 0x5F; // PUSH1=1, PUSH32=32
                pc += 1 + push_size;
                continue :dispatch;
            },

            // Duplicate operations
            0x80...0x8F => {
                pc += 1;
                continue :dispatch;
            }, // DUP1-DUP16

            // Swap operations
            0x90...0x9F => {
                pc += 1;
                continue :dispatch;
            }, // SWAP1-SWAP16

            // Log operations
            0xA0...0xA4 => {
                pc += 1;
                continue :dispatch;
            }, // LOG0-LOG4

            // System operations
            0xF0 => {
                pc += 1;
                continue :dispatch;
            }, // CREATE
            0xF1 => {
                pc += 1;
                continue :dispatch;
            }, // CALL
            0xF2 => {
                pc += 1;
                continue :dispatch;
            }, // CALLCODE
            0xF3 => return, // RETURN
            0xF4 => {
                pc += 1;
                continue :dispatch;
            }, // DELEGATECALL
            0xF5 => {
                pc += 1;
                continue :dispatch;
            }, // CREATE2
            0xF7 => {
                pc += 1;
                continue :dispatch;
            }, // RETURNDATALOAD
            0xF8 => {
                pc += 1;
                continue :dispatch;
            }, // EXTCALL
            0xF9 => {
                pc += 1;
                continue :dispatch;
            }, // EXTDELEGATECALL
            0xFA => {
                pc += 1;
                continue :dispatch;
            }, // STATICCALL
            0xFB => {
                pc += 1;
                continue :dispatch;
            }, // EXTSTATICCALL
            0xFD => return, // REVERT
            0xFE => return, // INVALID
            0xFF => return, // SELFDESTRUCT

            // Invalid opcode
            else => return,
        }
    }

    // Add null terminator to instructions array before returning
    try instructions.append(Instruction2{ .END = .{ .end_type = .INVALID, ._padding1 = 0, ._padding2 = 0, ._padding3 = 0 } });
}
