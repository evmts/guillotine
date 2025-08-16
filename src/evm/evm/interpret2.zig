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
    // Grab the bytecode from analysis before disabling it
    const bytecode = frame.analysis.code;

    // Disable pre-computed analysis to force lazy approach
    frame.analysis = null;

    // Program counter for bytecode execution
    var pc: u16 = 0;

    // Instruction index for lazy-generated instructions
    var instruction_index: u16 = 0;

    // Dynamic arrays for lazy evaluation - start empty and grow as needed
    var instructions = std.ArrayList(Instruction2).init(self.allocator);
    defer instructions.deinit();

    var opcodes = std.ArrayList(Opcodes).init(self.allocator);
    defer opcodes.deinit();

    // Block validation state
    var current_gas_cost: u32 = 0;
    var exec_buffer: [4]u8 = undefined;
    var exec_count: u8 = 0;

    // Add initial validation blocks
    try instructions.append(Instruction2{ .STACK_VALIDATION_BLOCK = .{ .stack_req = 0, .stack_max_growth = 0 } });
    try instructions.append(Instruction2{ .AGGREGATED_GAS = 0 });

    // Lazy analysis loop
    while (pc < bytecode.len) {
        const opcode_byte = bytecode[pc];

        // Check for end instructions first
        switch (opcode_byte) {
            0x00, 0xF3, 0xFD, 0xFE, 0xFF => {
                // Flush any pending EXEC instructions
                if (exec_count > 0) {
                    try flushExecBuffer(&instructions, exec_buffer, exec_count);
                    exec_count = 0;
                }

                // Add END instruction
                const end_type: EndType = switch (opcode_byte) {
                    0x00 => .STOP,
                    0xF3 => .RETURN,
                    0xFD => .REVERT,
                    0xFE => .INVALID,
                    0xFF => .SELFDESTRUCT,
                    else => unreachable,
                };
                try instructions.append(Instruction2{ .END = .{ .end_type = end_type, ._padding1 = 0, ._padding2 = 0, ._padding3 = 0 } });
                try opcodes.append(@enumFromInt(opcode_byte));
                return ExecutionError.Error.STOP; // Stop analysis at end instruction
            },
            else => {},
        }

        // Handle PUSH instructions with lookahead
        if (opcode_byte >= 0x60 and opcode_byte <= 0x7F) {
            // Flush any pending EXEC instructions
            if (exec_count > 0) {
                try flushExecBuffer(&instructions, exec_buffer, exec_count);
                exec_count = 0;
            }

            try handlePushWithLookahead(&instructions, &opcodes, bytecode, &pc);
        } else {
            // Handle regular opcodes - pack into EXEC_N
            if (isStaticGasOpcode(opcode_byte)) {
                // Add to EXEC buffer
                exec_buffer[exec_count] = opcode_byte;
                exec_count += 1;

                // Flush if buffer is full
                if (exec_count == 4) {
                    try flushExecBuffer(&instructions, exec_buffer, exec_count);
                    exec_count = 0;
                }

                try opcodes.append(@enumFromInt(opcode_byte));
                pc += 1;
            } else {
                // Dynamic gas opcode - flush EXEC buffer and handle separately
                if (exec_count > 0) {
                    try flushExecBuffer(&instructions, exec_buffer, exec_count);
                    exec_count = 0;
                }

                // Add gas validation block after dynamic gas opcodes
                try instructions.append(Instruction2{ .AGGREGATED_GAS = current_gas_cost });
                current_gas_cost = 0;

                // Handle jump instructions
                if (opcode_byte == 0x56 or opcode_byte == 0x57) {
                    try instructions.append(Instruction2{ .UNKNOWN_JUMP = 0 });
                } else {
                    // Other dynamic gas opcodes go in EXEC_1
                    try instructions.append(Instruction2{ .EXEC_1 = .{ .opcode = opcode_byte, ._padding1 = 0, ._padding2 = 0, ._padding3 = 0 } });
                }

                try opcodes.append(@enumFromInt(opcode_byte));
                pc += 1;
            }
        }
    }

    // Flush any remaining EXEC instructions
    if (exec_count > 0) {
        try flushExecBuffer(&instructions, exec_buffer, exec_count);
    }

    return ExecutionError.Error.STOP;
}

/// Flush accumulated EXEC opcodes to instructions array
fn flushExecBuffer(instructions: *std.ArrayList(Instruction2), exec_buffer: [4]u8, count: u8) !void {
    switch (count) {
        1 => try instructions.append(Instruction2{ .EXEC_1 = .{ .opcode = exec_buffer[0], ._padding1 = 0, ._padding2 = 0, ._padding3 = 0 } }),
        2 => try instructions.append(Instruction2{ .EXEC_2 = .{ .opcode1 = exec_buffer[0], .opcode2 = exec_buffer[1], ._padding = 0 } }),
        3 => try instructions.append(Instruction2{ .EXEC_3 = .{ .opcode1 = exec_buffer[0], .opcode2 = exec_buffer[1], .opcode3 = exec_buffer[2], ._padding = 0 } }),
        4 => try instructions.append(Instruction2{ .EXEC_4 = .{ .opcode1 = exec_buffer[0], .opcode2 = exec_buffer[1], .opcode3 = exec_buffer[2], .opcode4 = exec_buffer[3] } }),
        else => unreachable,
    }
}

/// Check if opcode has static gas cost (can be batched in EXEC_N)
fn isStaticGasOpcode(opcode: u8) bool {
    return switch (opcode) {
        // Dynamic gas opcodes
        0x20, // KECCAK256
        0x31, // BALANCE
        0x3C, // EXTCODESIZE
        0x3D, // EXTCODECOPY
        0x3F, // EXTCODEHASH
        0x40, // BLOCKHASH
        0x51, // MLOAD
        0x52, // MSTORE
        0x53, // MSTORE8
        0x54, // SLOAD
        0x55, // SSTORE
        0x56, // JUMP
        0x57, // JUMPI
        0x5C, // TLOAD
        0x5D, // TSTORE
        0x5E, // MCOPY
        0xF0, // CREATE
        0xF1, // CALL
        0xF2, // CALLCODE
        0xF4, // DELEGATECALL
        0xF5, // CREATE2
        0xFA, // STATICCALL
        => false,
        else => true,
    };
}

/// Handle PUSH instruction with lookahead for optimization
fn handlePushWithLookahead(instructions: *std.ArrayList(Instruction2), opcodes: *std.ArrayList(Opcodes), bytecode: []const u8, pc: *u16) !void {
    const opcode_byte = bytecode[pc.*];
    const push_size = opcode_byte - 0x5F; // PUSH1=1 byte, PUSH32=32 bytes
    const data_start = pc.* + 1;
    const data_end = @min(data_start + push_size, bytecode.len);
    const push_data = bytecode[data_start..data_end];

    // Look ahead to see what comes after the PUSH
    const next_pc = pc.* + 1 + push_size;
    if (next_pc < bytecode.len) {
        const next_opcode = bytecode[next_pc];

        // Check for JUMP/JUMPI patterns (highest priority)
        if (next_opcode == 0x56 or next_opcode == 0x57) {
            // Look for PUSH+JUMP pattern - try to resolve jump target
            if (push_size <= 2) { // Jump targets are typically small
                var target: u16 = 0;
                for (push_data, 0..) |byte, i| {
                    target |= (@as(u16, byte) << @intCast((push_data.len - 1 - i) * 8));
                }

                // For now, treat as UNKNOWN_JUMP since we don't have full analysis
                if (next_opcode == 0x56) {
                    try instructions.append(Instruction2{ .UNKNOWN_JUMP = 0 });
                } else {
                    try instructions.append(Instruction2{ .UNKNOWN_JUMPI = 0 });
                }
                try opcodes.append(@enumFromInt(opcode_byte));
                try opcodes.append(@enumFromInt(next_opcode));
                pc.* = next_pc + 1;
                return;
            }
        }

        // Check for PUSH_VALUE_FUSED pattern (second priority)
        if (push_size <= 2) { // Small values that fit in u16
            var value: u16 = 0;
            for (push_data, 0..) |byte, i| {
                value |= (@as(u16, byte) << @intCast((push_data.len - 1 - i) * 8));
            }
            try instructions.append(Instruction2{ .PUSH_VALUE_FUSED = .{ .push_value = value, .next_opcode = next_opcode, ._padding = 0 } });
            try opcodes.append(@enumFromInt(opcode_byte));
            try opcodes.append(@enumFromInt(next_opcode));
            pc.* = next_pc + 1;
            return;
        }
    }

    // Fall back to regular PUSH handling
    if (push_size <= 4) {
        // PUSH_VALUE for small values
        var value: u32 = 0;
        for (push_data, 0..) |byte, i| {
            value |= (@as(u32, byte) << @intCast((push_data.len - 1 - i) * 8));
        }
        try instructions.append(Instruction2{ .PUSH_VALUE = value });
    } else {
        // PUSH_PC for large values
        try instructions.append(Instruction2{ .PUSH_PC = pc.* });
    }

    try opcodes.append(@enumFromInt(opcode_byte));
    pc.* = @intCast(next_pc);
}
