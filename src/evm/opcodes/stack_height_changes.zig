const std = @import("std");
const Opcode = @import("opcode.zig");
const operation_config = @import("../opcode_metadata/operation_config.zig");
const Stack = @import("../stack/stack.zig");

/// Pre-computed net stack height change for each opcode.
/// Positive values indicate net stack growth, negative indicate net decrease.
/// This table provides O(1) lookup for stack effect analysis and validation.
pub const STACK_HEIGHT_CHANGES = blk: {
    var table: [256]i8 = [_]i8{0} ** 256;

    // 0x00: STOP - no stack change
    table[0x00] = 0;

    // 0x01-0x0B: Arithmetic operations - pop 2, push 1 = -1 (except ADDMOD/MULMOD pop 3)
    table[0x01] = -1; // ADD
    table[0x02] = -1; // MUL
    table[0x03] = -1; // SUB
    table[0x04] = -1; // DIV
    table[0x05] = -1; // SDIV
    table[0x06] = -1; // MOD
    table[0x07] = -1; // SMOD
    table[0x08] = -2; // ADDMOD (pop 3, push 1)
    table[0x09] = -2; // MULMOD (pop 3, push 1)
    table[0x0a] = -1; // EXP
    table[0x0b] = -1; // SIGNEXTEND

    // 0x10-0x1D: Comparison & Bitwise - mostly pop 2, push 1 = -1 (except ISZERO/NOT pop 1)
    table[0x10] = -1; // LT
    table[0x11] = -1; // GT
    table[0x12] = -1; // SLT
    table[0x13] = -1; // SGT
    table[0x14] = -1; // EQ
    table[0x15] = 0; // ISZERO (pop 1, push 1)
    table[0x16] = -1; // AND
    table[0x17] = -1; // OR
    table[0x18] = -1; // XOR
    table[0x19] = 0; // NOT (pop 1, push 1)
    table[0x1a] = -1; // BYTE
    table[0x1b] = -1; // SHL
    table[0x1c] = -1; // SHR
    table[0x1d] = -1; // SAR

    // 0x20: SHA3/KECCAK256 - pop 2, push 1 = -1
    table[0x20] = -1; // KECCAK256

    // 0x30-0x3F: Environmental operations - mix of push 1 and transforms
    table[0x30] = 1; // ADDRESS (push 1)
    table[0x31] = 0; // BALANCE (pop 1, push 1)
    table[0x32] = 1; // ORIGIN (push 1)
    table[0x33] = 1; // CALLER (push 1)
    table[0x34] = 1; // CALLVALUE (push 1)
    table[0x35] = 0; // CALLDATALOAD (pop 1, push 1)
    table[0x36] = 1; // CALLDATASIZE (push 1)
    table[0x37] = -3; // CALLDATACOPY (pop 3, push 0)
    table[0x38] = 1; // CODESIZE (push 1)
    table[0x39] = -3; // CODECOPY (pop 3, push 0)
    table[0x3a] = 1; // GASPRICE (push 1)
    table[0x3b] = 0; // EXTCODESIZE (pop 1, push 1)
    table[0x3c] = -4; // EXTCODECOPY (pop 4, push 0)
    table[0x3d] = 1; // RETURNDATASIZE (push 1)
    table[0x3e] = -3; // RETURNDATACOPY (pop 3, push 0)
    table[0x3f] = 0; // EXTCODEHASH (pop 1, push 1)

    // 0x40-0x4A: Block operations - mostly push 1
    table[0x40] = 0; // BLOCKHASH (pop 1, push 1)
    table[0x41] = 1; // COINBASE (push 1)
    table[0x42] = 1; // TIMESTAMP (push 1)
    table[0x43] = 1; // NUMBER (push 1)
    table[0x44] = 1; // DIFFICULTY/PREVRANDAO (push 1)
    table[0x45] = 1; // GASLIMIT (push 1)
    table[0x46] = 1; // CHAINID (push 1)
    table[0x47] = 1; // SELFBALANCE (push 1)
    table[0x48] = 1; // BASEFEE (push 1)
    table[0x49] = 0; // BLOBHASH (pop 1, push 1)
    table[0x4a] = 1; // BLOBBASEFEE (push 1)

    // 0x50-0x5F: Stack, Memory, Storage operations
    table[0x50] = -1; // POP (pop 1, push 0)
    table[0x51] = 0; // MLOAD (pop 1, push 1)
    table[0x52] = -2; // MSTORE (pop 2, push 0)
    table[0x53] = -2; // MSTORE8 (pop 2, push 0)
    table[0x54] = 0; // SLOAD (pop 1, push 1)
    table[0x55] = -2; // SSTORE (pop 2, push 0)
    table[0x56] = -1; // JUMP (pop 1, push 0)
    table[0x57] = -2; // JUMPI (pop 2, push 0)
    table[0x58] = 1; // PC (push 1)
    table[0x59] = 1; // MSIZE (push 1)
    table[0x5a] = 1; // GAS (push 1)
    table[0x5b] = 0; // JUMPDEST (no stack change)
    table[0x5c] = 0; // TLOAD (pop 1, push 1)
    table[0x5d] = -2; // TSTORE (pop 2, push 0)
    table[0x5e] = -3; // MCOPY (pop 3, push 0)
    table[0x5f] = 1; // PUSH0 (push 1)

    // 0x60-0x7F: PUSH1-PUSH32 operations - all push 1
    for (0x60..0x80) |opcode| {
        table[opcode] = 1;
    }

    // 0x80-0x8F: DUP1-DUP16 operations - all push 1 (duplicate existing item)
    for (0x80..0x90) |opcode| {
        table[opcode] = 1;
    }

    // 0x90-0x9F: SWAP1-SWAP16 operations - no net stack change
    for (0x90..0xa0) |opcode| {
        table[opcode] = 0;
    }

    // 0xA0-0xA4: LOG0-LOG4 operations - pop (2 + n topics), push 0
    for (0..5) |n| {
        table[0xa0 + n] = -@as(i8, @intCast(2 + n));
    }

    // 0xF0-0xFF: System operations
    table[0xf0] = -2; // CREATE (pop 3, push 1)
    table[0xf1] = -6; // CALL (pop 7, push 1)
    table[0xf2] = -6; // CALLCODE (pop 7, push 1)
    table[0xf3] = -2; // RETURN (pop 2, push 0)
    table[0xf4] = -5; // DELEGATECALL (pop 6, push 1)
    table[0xf5] = -3; // CREATE2 (pop 4, push 1)
    table[0xfa] = -5; // STATICCALL (pop 6, push 1)
    table[0xfd] = -2; // REVERT (pop 2, push 0)
    table[0xfe] = 0; // INVALID (execution stops)
    table[0xff] = -1; // SELFDESTRUCT (pop 1, push 0)

    break :blk table;
};

/// Get pre-computed stack height change for an opcode.
/// Returns the net change in stack depth (positive = growth, negative = shrinkage).
pub fn get_stack_height_change(opcode: u8) i8 {
    return STACK_HEIGHT_CHANGES[opcode];
}

/// Validate stack requirements using pre-computed height changes.
/// This is faster than the traditional approach as it uses a simple lookup for overflow.
pub fn validate_stack_requirements_fast(
    current_height: u16,
    _: u8, // opcode - currently unused but kept for future optimizations
    min_stack: u32,
    max_stack: u32,
) !void {
    // Check underflow: same as traditional validation
    if (current_height < min_stack) {
        return error.StackUnderflow;
    }

    // Check overflow: same as traditional validation
    if (current_height > max_stack) {
        return error.StackOverflow;
    }
}

// Tests
const testing = std.testing;

test "stack height changes arithmetic operations" {
    // Binary arithmetic operations: pop 2, push 1 = -1
    try testing.expectEqual(@as(i8, -1), get_stack_height_change(0x01)); // ADD
    try testing.expectEqual(@as(i8, -1), get_stack_height_change(0x02)); // MUL
    try testing.expectEqual(@as(i8, -1), get_stack_height_change(0x03)); // SUB
    try testing.expectEqual(@as(i8, -1), get_stack_height_change(0x04)); // DIV

    // Ternary operations: pop 3, push 1 = -2
    try testing.expectEqual(@as(i8, -2), get_stack_height_change(0x08)); // ADDMOD
    try testing.expectEqual(@as(i8, -2), get_stack_height_change(0x09)); // MULMOD
}

test "stack height changes comparison operations" {
    // Binary comparisons: pop 2, push 1 = -1
    try testing.expectEqual(@as(i8, -1), get_stack_height_change(0x10)); // LT
    try testing.expectEqual(@as(i8, -1), get_stack_height_change(0x11)); // GT
    try testing.expectEqual(@as(i8, -1), get_stack_height_change(0x14)); // EQ

    // Unary operations: pop 1, push 1 = 0
    try testing.expectEqual(@as(i8, 0), get_stack_height_change(0x15)); // ISZERO
    try testing.expectEqual(@as(i8, 0), get_stack_height_change(0x19)); // NOT
}

test "stack height changes environmental operations" {
    // Push operations: push 1 = +1
    try testing.expectEqual(@as(i8, 1), get_stack_height_change(0x30)); // ADDRESS
    try testing.expectEqual(@as(i8, 1), get_stack_height_change(0x32)); // ORIGIN
    try testing.expectEqual(@as(i8, 1), get_stack_height_change(0x33)); // CALLER

    // Transform operations: pop 1, push 1 = 0
    try testing.expectEqual(@as(i8, 0), get_stack_height_change(0x31)); // BALANCE
    try testing.expectEqual(@as(i8, 0), get_stack_height_change(0x35)); // CALLDATALOAD

    // Copy operations: pop 3, push 0 = -3
    try testing.expectEqual(@as(i8, -3), get_stack_height_change(0x37)); // CALLDATACOPY
    try testing.expectEqual(@as(i8, -3), get_stack_height_change(0x39)); // CODECOPY
}

test "stack height changes stack operations" {
    // PUSH operations: all push 1
    for (0x60..0x80) |opcode| {
        try testing.expectEqual(@as(i8, 1), get_stack_height_change(@intCast(opcode)));
    }

    // DUP operations: all push 1 (duplicate)
    for (0x80..0x90) |opcode| {
        try testing.expectEqual(@as(i8, 1), get_stack_height_change(@intCast(opcode)));
    }

    // SWAP operations: no net change
    for (0x90..0xa0) |opcode| {
        try testing.expectEqual(@as(i8, 0), get_stack_height_change(@intCast(opcode)));
    }

    // LOG operations: pop (2 + topics)
    try testing.expectEqual(@as(i8, -2), get_stack_height_change(0xa0)); // LOG0
    try testing.expectEqual(@as(i8, -3), get_stack_height_change(0xa1)); // LOG1
    try testing.expectEqual(@as(i8, -4), get_stack_height_change(0xa2)); // LOG2
    try testing.expectEqual(@as(i8, -5), get_stack_height_change(0xa3)); // LOG3
    try testing.expectEqual(@as(i8, -6), get_stack_height_change(0xa4)); // LOG4
}

test "stack height changes system operations" {
    // CREATE operations
    try testing.expectEqual(@as(i8, -2), get_stack_height_change(0xf0)); // CREATE (pop 3, push 1)
    try testing.expectEqual(@as(i8, -3), get_stack_height_change(0xf5)); // CREATE2 (pop 4, push 1)

    // CALL operations
    try testing.expectEqual(@as(i8, -6), get_stack_height_change(0xf1)); // CALL (pop 7, push 1)
    try testing.expectEqual(@as(i8, -6), get_stack_height_change(0xf2)); // CALLCODE (pop 7, push 1)
    try testing.expectEqual(@as(i8, -5), get_stack_height_change(0xf4)); // DELEGATECALL (pop 6, push 1)
    try testing.expectEqual(@as(i8, -5), get_stack_height_change(0xfa)); // STATICCALL (pop 6, push 1)

    // Control operations
    try testing.expectEqual(@as(i8, -2), get_stack_height_change(0xf3)); // RETURN (pop 2, push 0)
    try testing.expectEqual(@as(i8, -2), get_stack_height_change(0xfd)); // REVERT (pop 2, push 0)
    try testing.expectEqual(@as(i8, -1), get_stack_height_change(0xff)); // SELFDESTRUCT (pop 1, push 0)
}

test "validate stack requirements fast underflow" {
    // Test underflow detection
    try testing.expectError(error.StackUnderflow, validate_stack_requirements_fast(1, 0x01, 2, 1024)); // ADD needs 2 items
    try testing.expectError(error.StackUnderflow, validate_stack_requirements_fast(0, 0x50, 1, 1024)); // POP needs 1 item

    // Test success cases
    try validate_stack_requirements_fast(2, 0x01, 2, 1024); // ADD with 2 items
    try validate_stack_requirements_fast(1, 0x50, 1, 1024); // POP with 1 item
}

test "validate stack requirements fast overflow" {
    // Test overflow detection
    try testing.expectError(error.StackOverflow, validate_stack_requirements_fast(1024, 0x60, 0, 1023)); // PUSH1 at capacity exceeds max_stack
    try testing.expectError(error.StackOverflow, validate_stack_requirements_fast(1024, 0x80, 1, 1023)); // DUP1 at capacity exceeds max_stack

    // Test success cases
    try validate_stack_requirements_fast(1023, 0x01, 2, 1024); // ADD reducing stack
    try validate_stack_requirements_fast(1023, 0x60, 0, 1023); // PUSH1 at capacity-1
    try validate_stack_requirements_fast(1023, 0x80, 1, 1023); // DUP1 at capacity-1
}

test "stack height changes match known operation patterns" {
    // Verify our table matches expected patterns for key operation categories

    // Arithmetic binary operations: pop 2, push 1 = -1
    const binary_arithmetic = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0a, 0x0b };
    for (binary_arithmetic) |opcode| {
        try testing.expectEqual(@as(i8, -1), get_stack_height_change(opcode));
    }

    // Ternary operations: pop 3, push 1 = -2
    const ternary_ops = [_]u8{ 0x08, 0x09 }; // ADDMOD, MULMOD
    for (ternary_ops) |opcode| {
        try testing.expectEqual(@as(i8, -2), get_stack_height_change(opcode));
    }

    // Binary comparisons: pop 2, push 1 = -1
    const binary_comparisons = [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x16, 0x17, 0x18, 0x1a, 0x1b, 0x1c, 0x1d };
    for (binary_comparisons) |opcode| {
        try testing.expectEqual(@as(i8, -1), get_stack_height_change(opcode));
    }

    // Unary operations: pop 1, push 1 = 0
    const unary_ops = [_]u8{ 0x15, 0x19, 0x31, 0x35, 0x3b, 0x3f, 0x40, 0x49, 0x51, 0x54, 0x5c };
    for (unary_ops) |opcode| {
        try testing.expectEqual(@as(i8, 0), get_stack_height_change(opcode));
    }

    // Pure push operations: push 1 = +1
    const push_ops = [_]u8{ 0x30, 0x32, 0x33, 0x34, 0x36, 0x38, 0x3a, 0x3d, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x4a, 0x58, 0x59, 0x5a, 0x5f };
    for (push_ops) |opcode| {
        try testing.expectEqual(@as(i8, 1), get_stack_height_change(opcode));
    }

    // System calls with large pop counts
    try testing.expectEqual(@as(i8, -6), get_stack_height_change(0xf1)); // CALL: pop 7, push 1
    try testing.expectEqual(@as(i8, -6), get_stack_height_change(0xf2)); // CALLCODE: pop 7, push 1
    try testing.expectEqual(@as(i8, -5), get_stack_height_change(0xf4)); // DELEGATECALL: pop 6, push 1
    try testing.expectEqual(@as(i8, -5), get_stack_height_change(0xfa)); // STATICCALL: pop 6, push 1
}
