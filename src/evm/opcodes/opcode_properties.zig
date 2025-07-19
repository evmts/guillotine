/// Static lookup tables for opcode properties to enable O(1) property queries.
///
/// This module provides compile-time generated lookup tables that replace
/// runtime conditional checks for opcode properties. All tables are designed
/// to fit in L1 cache and use direct array indexing for maximum performance.
///
/// ## Performance Benefits
/// - Eliminates branch prediction overhead
/// - Removes conditional logic from hot paths
/// - Enables compiler optimizations (loop unrolling, vectorization)
/// - Predictable memory access patterns
///
/// ## Memory Layout
/// Each table is exactly 256 bytes (one entry per possible opcode value).
/// Total memory footprint: ~3KB for all tables combined.
const std = @import("std");

/// Size of immediate data for PUSH operations (in bytes).
///
/// Maps each opcode to the number of bytes it reads from the bytecode
/// after the opcode itself. Only PUSH1-PUSH32 have non-zero values.
///
/// Example:
/// - PUSH1 (0x60): 1 byte of immediate data
/// - PUSH32 (0x7F): 32 bytes of immediate data
/// - All other opcodes: 0 bytes
pub const IMMEDIATE_SIZE = blk: {
    var table = [_]u8{0} ** 256;
    
    // PUSH1 through PUSH32 have immediate data
    var i: u8 = 0x60; // PUSH1
    while (i <= 0x7F) : (i += 1) {
        table[i] = i - 0x5F; // PUSH1 = 1 byte, PUSH2 = 2 bytes, etc.
    }
    
    break :blk table;
};

/// Opcodes that terminate execution.
///
/// These opcodes end the current execution context and return control
/// to the caller (or halt the transaction).
///
/// Terminating opcodes:
/// - STOP (0x00): Halt execution
/// - RETURN (0xF3): Return data and halt
/// - REVERT (0xFD): Revert state and halt
/// - INVALID (0xFE): Invalid operation
/// - SELFDESTRUCT (0xFF): Destroy contract
pub const IS_TERMINATING = blk: {
    var table = [_]bool{false} ** 256;
    
    table[0x00] = true; // STOP
    table[0xF3] = true; // RETURN
    table[0xFD] = true; // REVERT
    table[0xFE] = true; // INVALID
    table[0xFF] = true; // SELFDESTRUCT
    
    break :blk table;
};

/// Opcodes that modify memory.
///
/// These operations write to the EVM memory, which may trigger
/// memory expansion and associated gas costs.
///
/// Memory-modifying opcodes:
/// - MSTORE (0x52): Store 32 bytes
/// - MSTORE8 (0x53): Store 1 byte
/// - CALLDATACOPY (0x37): Copy calldata to memory
/// - CODECOPY (0x39): Copy code to memory
/// - EXTCODECOPY (0x3C): Copy external code to memory
/// - RETURNDATACOPY (0x3E): Copy return data to memory
/// - MCOPY (0x5E): Copy memory to memory
/// - CALL family: May write return data to memory
pub const MODIFIES_MEMORY = blk: {
    var table = [_]bool{false} ** 256;
    
    table[0x52] = true; // MSTORE
    table[0x53] = true; // MSTORE8
    table[0x37] = true; // CALLDATACOPY
    table[0x39] = true; // CODECOPY
    table[0x3C] = true; // EXTCODECOPY
    table[0x3E] = true; // RETURNDATACOPY
    table[0x5E] = true; // MCOPY
    table[0xF1] = true; // CALL
    table[0xF2] = true; // CALLCODE
    table[0xF4] = true; // DELEGATECALL
    table[0xFA] = true; // STATICCALL
    
    break :blk table;
};

/// Opcodes that modify blockchain state.
///
/// These operations change persistent state and are forbidden
/// in static call contexts.
///
/// State-modifying opcodes:
/// - SSTORE (0x55): Modify storage
/// - CREATE (0xF0): Deploy new contract
/// - CREATE2 (0xF5): Deploy with deterministic address
/// - CALL (0xF1): When transferring value
/// - SELFDESTRUCT (0xFF): Destroy contract
/// - LOG0-LOG4 (0xA0-0xA4): Emit events
/// - TSTORE (0x5D): Modify transient storage
pub const MODIFIES_STATE = blk: {
    var table = [_]bool{false} ** 256;
    
    table[0x55] = true; // SSTORE
    table[0xF0] = true; // CREATE
    table[0xF5] = true; // CREATE2
    table[0xF1] = true; // CALL (when value > 0)
    table[0xFF] = true; // SELFDESTRUCT
    table[0xA0] = true; // LOG0
    table[0xA1] = true; // LOG1
    table[0xA2] = true; // LOG2
    table[0xA3] = true; // LOG3
    table[0xA4] = true; // LOG4
    table[0x5D] = true; // TSTORE
    
    break :blk table;
};

/// Jump operations.
///
/// These opcodes alter the program counter (PC) for control flow.
///
/// Jump opcodes:
/// - JUMP (0x56): Unconditional jump
/// - JUMPI (0x57): Conditional jump
pub const IS_JUMP = blk: {
    var table = [_]bool{false} ** 256;
    
    table[0x56] = true; // JUMP
    table[0x57] = true; // JUMPI
    
    break :blk table;
};

/// Operations that can fail/throw exceptions.
///
/// These opcodes may fail during execution due to various conditions
/// like insufficient gas, stack underflow, invalid jumps, etc.
///
/// Most opcodes can fail except:
/// - JUMPDEST (0x5B): No-op marker
/// - PC (0x58): Always succeeds
/// - GAS (0x5A): Always succeeds
/// - Simple stack operations without bounds checks
pub const CAN_FAIL = blk: {
    var table = [_]bool{true} ** 256;
    
    // These opcodes never fail
    table[0x5B] = false; // JUMPDEST
    table[0x58] = false; // PC
    table[0x5A] = false; // GAS
    
    break :blk table;
};

/// Stack position for DUP operations.
///
/// Maps DUP opcodes to the stack position they duplicate from.
/// DUP1 duplicates from position 1, DUP2 from position 2, etc.
///
/// Non-DUP opcodes have a value of 0.
pub const DUP_POSITION = blk: {
    var table = [_]u8{0} ** 256;
    
    // DUP1 (0x80) through DUP16 (0x8F)
    var i: u8 = 0x80;
    while (i <= 0x8F) : (i += 1) {
        table[i] = i - 0x7F; // DUP1 = position 1, DUP2 = position 2, etc.
    }
    
    break :blk table;
};

/// Stack position for SWAP operations.
///
/// Maps SWAP opcodes to the stack position they swap with the top.
/// SWAP1 swaps with position 1, SWAP2 with position 2, etc.
///
/// Non-SWAP opcodes have a value of 0.
pub const SWAP_POSITION = blk: {
    var table = [_]u8{0} ** 256;
    
    // SWAP1 (0x90) through SWAP16 (0x9F)
    var i: u8 = 0x90;
    while (i <= 0x9F) : (i += 1) {
        table[i] = i - 0x8F; // SWAP1 = position 1, SWAP2 = position 2, etc.
    }
    
    break :blk table;
};

/// Number of topics for LOG operations.
///
/// Maps LOG opcodes to the number of topics they emit.
/// LOG0 has 0 topics, LOG1 has 1 topic, etc.
///
/// Non-LOG opcodes have a value of 0.
pub const LOG_TOPIC_COUNT = blk: {
    var table = [_]u8{0} ** 256;
    
    table[0xA0] = 0; // LOG0
    table[0xA1] = 1; // LOG1
    table[0xA2] = 2; // LOG2
    table[0xA3] = 3; // LOG3
    table[0xA4] = 4; // LOG4
    
    break :blk table;
};

/// Call operations.
///
/// These opcodes initiate calls to other contracts or addresses.
///
/// Call opcodes:
/// - CALL (0xF1)
/// - CALLCODE (0xF2)
/// - DELEGATECALL (0xF4)
/// - STATICCALL (0xFA)
pub const IS_CALL = blk: {
    var table = [_]bool{false} ** 256;
    
    table[0xF1] = true; // CALL
    table[0xF2] = true; // CALLCODE
    table[0xF4] = true; // DELEGATECALL
    table[0xFA] = true; // STATICCALL
    
    break :blk table;
};

/// Create operations.
///
/// These opcodes deploy new contracts.
///
/// Create opcodes:
/// - CREATE (0xF0)
/// - CREATE2 (0xF5)
pub const IS_CREATE = blk: {
    var table = [_]bool{false} ** 256;
    
    table[0xF0] = true; // CREATE
    table[0xF5] = true; // CREATE2
    
    break :blk table;
};

/// Operations that read from memory.
///
/// These opcodes read data from EVM memory, which may trigger
/// memory expansion if accessing uninitialized regions.
///
/// Memory-reading opcodes:
/// - MLOAD (0x51): Load 32 bytes
/// - KECCAK256 (0x20): Hash memory range
/// - CREATE/CREATE2: Read init code from memory
/// - CALL family: Read input data from memory
/// - RETURN/REVERT: Read output data from memory
/// - LOG0-LOG4: Read log data from memory
pub const READS_MEMORY = blk: {
    var table = [_]bool{false} ** 256;
    
    table[0x51] = true; // MLOAD
    table[0x20] = true; // KECCAK256
    table[0xF0] = true; // CREATE
    table[0xF5] = true; // CREATE2
    table[0xF1] = true; // CALL
    table[0xF2] = true; // CALLCODE
    table[0xF4] = true; // DELEGATECALL
    table[0xFA] = true; // STATICCALL
    table[0xF3] = true; // RETURN
    table[0xFD] = true; // REVERT
    table[0xA0] = true; // LOG0
    table[0xA1] = true; // LOG1
    table[0xA2] = true; // LOG2
    table[0xA3] = true; // LOG3
    table[0xA4] = true; // LOG4
    
    break :blk table;
};

// Compile-time validation
comptime {
    // Ensure tables are properly sized
    if (IMMEDIATE_SIZE.len != 256) @compileError("IMMEDIATE_SIZE must have 256 entries");
    if (IS_TERMINATING.len != 256) @compileError("IS_TERMINATING must have 256 entries");
    if (MODIFIES_MEMORY.len != 256) @compileError("MODIFIES_MEMORY must have 256 entries");
    if (MODIFIES_STATE.len != 256) @compileError("MODIFIES_STATE must have 256 entries");
    if (IS_JUMP.len != 256) @compileError("IS_JUMP must have 256 entries");
    if (CAN_FAIL.len != 256) @compileError("CAN_FAIL must have 256 entries");
    if (DUP_POSITION.len != 256) @compileError("DUP_POSITION must have 256 entries");
    if (SWAP_POSITION.len != 256) @compileError("SWAP_POSITION must have 256 entries");
    if (LOG_TOPIC_COUNT.len != 256) @compileError("LOG_TOPIC_COUNT must have 256 entries");
    if (IS_CALL.len != 256) @compileError("IS_CALL must have 256 entries");
    if (IS_CREATE.len != 256) @compileError("IS_CREATE must have 256 entries");
    if (READS_MEMORY.len != 256) @compileError("READS_MEMORY must have 256 entries");
    
    // Validate PUSH immediate sizes
    var i: usize = 0x60;
    while (i <= 0x7F) : (i += 1) {
        const expected = i - 0x5F;
        if (IMMEDIATE_SIZE[i] != expected) {
            @compileError("IMMEDIATE_SIZE validation failed");
        }
    }
    
    // Validate DUP positions
    i = 0x80;
    while (i <= 0x8F) : (i += 1) {
        const expected = i - 0x7F;
        if (DUP_POSITION[i] != expected) {
            @compileError("DUP_POSITION validation failed");
        }
    }
    
    // Validate SWAP positions
    i = 0x90;
    while (i <= 0x9F) : (i += 1) {
        const expected = i - 0x8F;
        if (SWAP_POSITION[i] != expected) {
            @compileError("SWAP_POSITION validation failed");
        }
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Check if an opcode is a PUSH operation
pub inline fn is_push(op: u8) bool {
    return op >= 0x60 and op <= 0x7F;
}

/// Get the size of immediate data for an opcode
pub inline fn get_push_size(op: u8) u8 {
    return IMMEDIATE_SIZE[op];
}

/// Check if an opcode is a DUP operation
pub inline fn is_dup(op: u8) bool {
    return op >= 0x80 and op <= 0x8F;
}

/// Get the stack position for a DUP opcode
pub inline fn get_dup_position(op: u8) u8 {
    return DUP_POSITION[op];
}

/// Check if an opcode is a SWAP operation
pub inline fn is_swap(op: u8) bool {
    return op >= 0x90 and op <= 0x9F;
}

/// Get the stack position for a SWAP opcode
pub inline fn get_swap_position(op: u8) u8 {
    return SWAP_POSITION[op];
}

/// Check if an opcode is a LOG operation
pub inline fn is_log(op: u8) bool {
    return op >= 0xA0 and op <= 0xA4;
}

/// Get the number of topics for a LOG opcode
pub inline fn get_log_topic_count(op: u8) u8 {
    return LOG_TOPIC_COUNT[op];
}

/// Check if an opcode terminates execution
pub inline fn is_terminating(op: u8) bool {
    return IS_TERMINATING[op];
}

/// Check if an opcode is a call operation
pub inline fn is_call(op: u8) bool {
    return IS_CALL[op];
}

/// Check if an opcode is a create operation
pub inline fn is_create(op: u8) bool {
    return IS_CREATE[op];
}

/// Check if an opcode modifies state
pub inline fn modifies_state(op: u8) bool {
    return MODIFIES_STATE[op];
}

// Runtime tests
test "IMMEDIATE_SIZE correctness" {
    const testing = std.testing;
    
    // Test PUSH opcodes
    try testing.expectEqual(@as(u8, 1), IMMEDIATE_SIZE[0x60]); // PUSH1
    try testing.expectEqual(@as(u8, 2), IMMEDIATE_SIZE[0x61]); // PUSH2
    try testing.expectEqual(@as(u8, 16), IMMEDIATE_SIZE[0x6F]); // PUSH16
    try testing.expectEqual(@as(u8, 32), IMMEDIATE_SIZE[0x7F]); // PUSH32
    
    // Test non-PUSH opcodes
    try testing.expectEqual(@as(u8, 0), IMMEDIATE_SIZE[0x00]); // STOP
    try testing.expectEqual(@as(u8, 0), IMMEDIATE_SIZE[0x01]); // ADD
    try testing.expectEqual(@as(u8, 0), IMMEDIATE_SIZE[0x5F]); // PUSH0
    try testing.expectEqual(@as(u8, 0), IMMEDIATE_SIZE[0x80]); // DUP1
}

test "IS_TERMINATING correctness" {
    const testing = std.testing;
    
    // Test terminating opcodes
    try testing.expect(IS_TERMINATING[0x00]); // STOP
    try testing.expect(IS_TERMINATING[0xF3]); // RETURN
    try testing.expect(IS_TERMINATING[0xFD]); // REVERT
    try testing.expect(IS_TERMINATING[0xFE]); // INVALID
    try testing.expect(IS_TERMINATING[0xFF]); // SELFDESTRUCT
    
    // Test non-terminating opcodes
    try testing.expect(!IS_TERMINATING[0x01]); // ADD
    try testing.expect(!IS_TERMINATING[0x56]); // JUMP
    try testing.expect(!IS_TERMINATING[0xF1]); // CALL
}

test "DUP_POSITION correctness" {
    const testing = std.testing;
    
    // Test DUP opcodes
    try testing.expectEqual(@as(u8, 1), DUP_POSITION[0x80]); // DUP1
    try testing.expectEqual(@as(u8, 2), DUP_POSITION[0x81]); // DUP2
    try testing.expectEqual(@as(u8, 16), DUP_POSITION[0x8F]); // DUP16
    
    // Test non-DUP opcodes
    try testing.expectEqual(@as(u8, 0), DUP_POSITION[0x7F]); // PUSH32
    try testing.expectEqual(@as(u8, 0), DUP_POSITION[0x90]); // SWAP1
}

test "SWAP_POSITION correctness" {
    const testing = std.testing;
    
    // Test SWAP opcodes
    try testing.expectEqual(@as(u8, 1), SWAP_POSITION[0x90]); // SWAP1
    try testing.expectEqual(@as(u8, 2), SWAP_POSITION[0x91]); // SWAP2
    try testing.expectEqual(@as(u8, 16), SWAP_POSITION[0x9F]); // SWAP16
    
    // Test non-SWAP opcodes
    try testing.expectEqual(@as(u8, 0), SWAP_POSITION[0x8F]); // DUP16
    try testing.expectEqual(@as(u8, 0), SWAP_POSITION[0xA0]); // LOG0
}

test "LOG_TOPIC_COUNT correctness" {
    const testing = std.testing;
    
    // Test LOG opcodes
    try testing.expectEqual(@as(u8, 0), LOG_TOPIC_COUNT[0xA0]); // LOG0
    try testing.expectEqual(@as(u8, 1), LOG_TOPIC_COUNT[0xA1]); // LOG1
    try testing.expectEqual(@as(u8, 2), LOG_TOPIC_COUNT[0xA2]); // LOG2
    try testing.expectEqual(@as(u8, 3), LOG_TOPIC_COUNT[0xA3]); // LOG3
    try testing.expectEqual(@as(u8, 4), LOG_TOPIC_COUNT[0xA4]); // LOG4
    
    // Test non-LOG opcodes
    try testing.expectEqual(@as(u8, 0), LOG_TOPIC_COUNT[0x9F]); // SWAP16
    try testing.expectEqual(@as(u8, 0), LOG_TOPIC_COUNT[0xA5]); // Invalid
}