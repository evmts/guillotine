/// Centralized opcode dispatcher for EVM instruction execution
///
/// This module provides a type-safe dispatcher that maps opcodes (0x00-0xFF) to their
/// corresponding handler functions. It serves as the single source of truth for opcode routing.
///
/// Architecture:
/// - Each opcode category has a dedicated handler module (arithmetic, bitwise, etc.)
/// - Handlers are instantiated with a Frame type for type safety
/// - Unknown opcodes return InvalidOpcode error
/// - Custom opcode overrides (JS/config-based) are handled by the caller (Frame)
///
/// Usage:
///   const dispatcher = Dispatcher(MyFrameType);
///   try dispatcher.execute(frame, opcode);
///
const std = @import("std");

// Import all handler modules
const handlers_arithmetic = @import("handlers_arithmetic.zig");
const handlers_comparison = @import("handlers_comparison.zig");
const handlers_bitwise = @import("handlers_bitwise.zig");
const handlers_keccak = @import("handlers_keccak.zig");
const handlers_context = @import("handlers_context.zig");
const handlers_block = @import("handlers_block.zig");
const handlers_stack = @import("handlers_stack.zig");
const handlers_memory = @import("handlers_memory.zig");
const handlers_storage = @import("handlers_storage.zig");
const handlers_control_flow = @import("handlers_control_flow.zig");
const handlers_log = @import("handlers_log.zig");
const handlers_system = @import("handlers_system.zig");

/// Creates a type-safe opcode dispatcher for a given Frame type
///
/// Type Parameters:
///   FrameType: Must provide:
///     - EvmError error union type
///     - consumeGas, popStack, pushStack methods
///     - pc (program counter) field
///     - All methods required by individual handlers
///
/// Returns: Struct with execute() method for opcode dispatch
pub fn Dispatcher(comptime FrameType: type) type {
    return struct {
        const Self = @This();
        const EvmError = FrameType.EvmError;

        // Instantiate all handler modules with the Frame type
        const ArithmeticHandlers = handlers_arithmetic.Handlers(FrameType);
        const ComparisonHandlers = handlers_comparison.Handlers(FrameType);
        const BitwiseHandlers = handlers_bitwise.Handlers(FrameType);
        const KeccakHandlers = handlers_keccak.Handlers(FrameType);
        const ContextHandlers = handlers_context.Handlers(FrameType);
        const BlockHandlers = handlers_block.Handlers(FrameType);
        const StackHandlers = handlers_stack.Handlers(FrameType);
        const MemoryHandlers = handlers_memory.Handlers(FrameType);
        const StorageHandlers = handlers_storage.Handlers(FrameType);
        const ControlFlowHandlers = handlers_control_flow.Handlers(FrameType);
        const LogHandlers = handlers_log.Handlers(FrameType);
        const SystemHandlers = handlers_system.Handlers(FrameType);

        /// Execute an opcode by dispatching to the appropriate handler
        ///
        /// This is the main entry point for standard EVM opcode execution.
        /// Custom opcode overrides (JavaScript or config-based) should be
        /// handled by the caller before invoking this function.
        ///
        /// Parameters:
        ///   - frame: Pointer to the execution frame
        ///   - opcode: The opcode byte to execute (0x00-0xFF)
        ///
        /// Returns: void
        ///
        /// Errors:
        ///   - OutOfGas: If insufficient gas for operation
        ///   - StackUnderflow: If stack has insufficient items
        ///   - StackOverflow: If stack exceeds 1024 items
        ///   - InvalidJumpDestination: If JUMP/JUMPI targets invalid location
        ///   - StaticCallViolation: If state-modifying op in static context
        ///   - InvalidOpcode: If opcode is not recognized (0x0c-0x0f, 0x1e-0x1f, etc.)
        ///   - Other errors: Depending on specific opcode requirements
        pub fn execute(frame: *FrameType, opcode: u8) EvmError!void {
            switch (opcode) {
                // 0x00-0x0f: Arithmetic & control flow
                0x00 => try ControlFlowHandlers.stop(frame),
                0x01 => try ArithmeticHandlers.add(frame),
                0x02 => try ArithmeticHandlers.mul(frame),
                0x03 => try ArithmeticHandlers.sub(frame),
                0x04 => try ArithmeticHandlers.div(frame),
                0x05 => try ArithmeticHandlers.sdiv(frame),
                0x06 => try ArithmeticHandlers.mod(frame),
                0x07 => try ArithmeticHandlers.smod(frame),
                0x08 => try ArithmeticHandlers.addmod(frame),
                0x09 => try ArithmeticHandlers.mulmod(frame),
                0x0a => try ArithmeticHandlers.exp(frame),
                0x0b => try ArithmeticHandlers.signextend(frame),
                // 0x0c-0x0f: Invalid opcodes

                // 0x10-0x1f: Comparison & bitwise operations
                0x10 => try ComparisonHandlers.lt(frame),
                0x11 => try ComparisonHandlers.gt(frame),
                0x12 => try ComparisonHandlers.slt(frame),
                0x13 => try ComparisonHandlers.sgt(frame),
                0x14 => try ComparisonHandlers.eq(frame),
                0x15 => try ComparisonHandlers.iszero(frame),
                0x16 => try BitwiseHandlers.op_and(frame),
                0x17 => try BitwiseHandlers.op_or(frame),
                0x18 => try BitwiseHandlers.op_xor(frame),
                0x19 => try BitwiseHandlers.op_not(frame),
                0x1a => try BitwiseHandlers.byte(frame),
                0x1b => try BitwiseHandlers.shl(frame),
                0x1c => try BitwiseHandlers.shr(frame),
                0x1d => try BitwiseHandlers.sar(frame),
                // 0x1e-0x1f: Invalid opcodes

                // 0x20: Keccak256
                0x20 => try KeccakHandlers.sha3(frame),
                // 0x21-0x2f: Invalid opcodes

                // 0x30-0x3f: Environmental information
                0x30 => try ContextHandlers.address(frame),
                0x31 => try ContextHandlers.balance(frame),
                0x32 => try ContextHandlers.origin(frame),
                0x33 => try ContextHandlers.caller(frame),
                0x34 => try ContextHandlers.callvalue(frame),
                0x35 => try ContextHandlers.calldataload(frame),
                0x36 => try ContextHandlers.calldatasize(frame),
                0x37 => try ContextHandlers.calldatacopy(frame),
                0x38 => try ContextHandlers.codesize(frame),
                0x39 => try ContextHandlers.codecopy(frame),
                0x3a => try ContextHandlers.gasprice(frame),
                0x3b => try ContextHandlers.extcodesize(frame),
                0x3c => try ContextHandlers.extcodecopy(frame),
                0x3d => try ContextHandlers.returndatasize(frame),
                0x3e => try ContextHandlers.returndatacopy(frame),
                0x3f => try ContextHandlers.extcodehash(frame),

                // 0x40-0x4f: Block information
                0x40 => try BlockHandlers.blockhash(frame),
                0x41 => try BlockHandlers.coinbase(frame),
                0x42 => try BlockHandlers.timestamp(frame),
                0x43 => try BlockHandlers.number(frame),
                0x44 => try BlockHandlers.difficulty(frame),
                0x45 => try BlockHandlers.gaslimit(frame),
                0x46 => try BlockHandlers.chainid(frame),
                0x47 => try BlockHandlers.selfbalance(frame),
                0x48 => try BlockHandlers.basefee(frame),
                0x49 => try BlockHandlers.blobhash(frame),
                0x4a => try BlockHandlers.blobbasefee(frame),
                // 0x4b-0x4f: Invalid opcodes

                // 0x50-0x5f: Stack, memory, storage operations
                0x50 => try StackHandlers.pop(frame),
                0x51 => try MemoryHandlers.mload(frame),
                0x52 => try MemoryHandlers.mstore(frame),
                0x53 => try MemoryHandlers.mstore8(frame),
                0x54 => try StorageHandlers.sload(frame),
                0x55 => try StorageHandlers.sstore(frame),
                0x56 => try ControlFlowHandlers.jump(frame),
                0x57 => try ControlFlowHandlers.jumpi(frame),
                0x58 => try ControlFlowHandlers.pc(frame),
                0x59 => try MemoryHandlers.msize(frame),
                0x5a => try ContextHandlers.gas(frame),
                0x5b => try ControlFlowHandlers.jumpdest(frame),
                0x5c => try StorageHandlers.tload(frame),
                0x5d => try StorageHandlers.tstore(frame),
                0x5e => try MemoryHandlers.mcopy(frame),

                // 0x5f-0x7f: PUSH operations (including PUSH0)
                0x5f...0x7f => try StackHandlers.push(frame, opcode),

                // 0x80-0x8f: DUP operations
                0x80...0x8f => try StackHandlers.dup(frame, opcode),

                // 0x90-0x9f: SWAP operations
                0x90...0x9f => try StackHandlers.swap(frame, opcode),

                // 0xa0-0xa4: LOG operations
                0xa0...0xa4 => try LogHandlers.log(frame, opcode),
                // 0xa5-0xef: Invalid opcodes

                // 0xf0-0xff: System operations
                0xf0 => try SystemHandlers.create(frame),
                0xf1 => try SystemHandlers.call(frame),
                0xf2 => try SystemHandlers.callcode(frame),
                0xf3 => try ControlFlowHandlers.ret(frame),
                0xf4 => try SystemHandlers.delegatecall(frame),
                0xf5 => try SystemHandlers.create2(frame),
                // 0xf6-0xf9: Invalid opcodes
                0xfa => try SystemHandlers.staticcall(frame),
                // 0xfb-0xfc: Invalid opcodes
                0xfd => try ControlFlowHandlers.revert(frame),
                // 0xfe: Invalid (INVALID opcode)
                0xff => try SystemHandlers.selfdestruct(frame),

                // All other opcodes are invalid
                else => return error.InvalidOpcode,
            }
        }

        /// Get the handler module name for an opcode (for debugging/introspection)
        ///
        /// Returns the name of the handler module responsible for this opcode,
        /// or null if the opcode is invalid.
        pub fn getHandlerModuleName(opcode: u8) ?[]const u8 {
            return switch (opcode) {
                0x01...0x0b => "arithmetic",
                0x10...0x15 => "comparison",
                0x16...0x1d => "bitwise",
                0x20 => "keccak",
                0x30...0x3f => "context",
                0x40...0x4a => "block",
                0x50, 0x5f...0x9f => "stack", // POP, PUSH, DUP, SWAP
                0x51...0x53, 0x59, 0x5e => "memory",
                0x54...0x55, 0x5c...0x5d => "storage",
                0x00, 0x56...0x58, 0x5b, 0xf3, 0xfd => "control_flow",
                0xa0...0xa4 => "log",
                0xf0...0xf2, 0xf4...0xf5, 0xfa, 0xff => "system",
                else => null,
            };
        }

        /// Check if an opcode is valid (i.e., has a handler)
        pub fn isValidOpcode(opcode: u8) bool {
            return getHandlerModuleName(opcode) != null;
        }
    };
}

// ================================ Tests ================================

test "Dispatcher - opcode routing" {
    const testing = std.testing;

    // Mock Frame type for testing
    const MockFrame = struct {
        const Self = @This();
        pub const EvmError = error{
            OutOfGas,
            StackUnderflow,
            StackOverflow,
            InvalidJumpDestination,
            StaticCallViolation,
            InvalidOpcode,
        };

        last_handler: []const u8 = "",
        last_opcode: u8 = 0,

        pub fn consumeGas(_: *Self, _: u64) EvmError!void {}
        pub fn popStack(_: *Self) EvmError!u256 {
            return 0;
        }
        pub fn pushStack(_: *Self, _: u256) EvmError!void {}
    };

    const dispatcher = Dispatcher(MockFrame);

    // Test valid opcode identification
    try testing.expect(dispatcher.isValidOpcode(0x01)); // ADD
    try testing.expect(dispatcher.isValidOpcode(0x20)); // KECCAK256
    try testing.expect(dispatcher.isValidOpcode(0x31)); // BALANCE
    try testing.expect(dispatcher.isValidOpcode(0x54)); // SLOAD
    try testing.expect(dispatcher.isValidOpcode(0xf1)); // CALL
    try testing.expect(dispatcher.isValidOpcode(0xff)); // SELFDESTRUCT

    // Test invalid opcodes
    try testing.expect(!dispatcher.isValidOpcode(0x0c));
    try testing.expect(!dispatcher.isValidOpcode(0x1e));
    try testing.expect(!dispatcher.isValidOpcode(0x21));
    try testing.expect(!dispatcher.isValidOpcode(0xa5));
}

test "Dispatcher - handler module names" {
    const testing = std.testing;
    const MockFrame = struct {
        pub const EvmError = error{InvalidOpcode};
    };
    const dispatcher = Dispatcher(MockFrame);

    // Test arithmetic opcodes
    try testing.expectEqualStrings("arithmetic", dispatcher.getHandlerModuleName(0x01).?);
    try testing.expectEqualStrings("arithmetic", dispatcher.getHandlerModuleName(0x0a).?);

    // Test comparison opcodes
    try testing.expectEqualStrings("comparison", dispatcher.getHandlerModuleName(0x10).?);
    try testing.expectEqualStrings("comparison", dispatcher.getHandlerModuleName(0x14).?);

    // Test bitwise opcodes
    try testing.expectEqualStrings("bitwise", dispatcher.getHandlerModuleName(0x16).?);
    try testing.expectEqualStrings("bitwise", dispatcher.getHandlerModuleName(0x1d).?);

    // Test keccak opcode
    try testing.expectEqualStrings("keccak", dispatcher.getHandlerModuleName(0x20).?);

    // Test context opcodes
    try testing.expectEqualStrings("context", dispatcher.getHandlerModuleName(0x30).?);
    try testing.expectEqualStrings("context", dispatcher.getHandlerModuleName(0x3f).?);

    // Test block opcodes
    try testing.expectEqualStrings("block", dispatcher.getHandlerModuleName(0x40).?);
    try testing.expectEqualStrings("block", dispatcher.getHandlerModuleName(0x4a).?);

    // Test stack opcodes
    try testing.expectEqualStrings("stack", dispatcher.getHandlerModuleName(0x50).?);
    try testing.expectEqualStrings("stack", dispatcher.getHandlerModuleName(0x5f).?);
    try testing.expectEqualStrings("stack", dispatcher.getHandlerModuleName(0x60).?);
    try testing.expectEqualStrings("stack", dispatcher.getHandlerModuleName(0x80).?);

    // Test memory opcodes
    try testing.expectEqualStrings("memory", dispatcher.getHandlerModuleName(0x51).?);
    try testing.expectEqualStrings("memory", dispatcher.getHandlerModuleName(0x59).?);
    try testing.expectEqualStrings("memory", dispatcher.getHandlerModuleName(0x5e).?);

    // Test storage opcodes
    try testing.expectEqualStrings("storage", dispatcher.getHandlerModuleName(0x54).?);
    try testing.expectEqualStrings("storage", dispatcher.getHandlerModuleName(0x5c).?);

    // Test control flow opcodes
    try testing.expectEqualStrings("control_flow", dispatcher.getHandlerModuleName(0x00).?);
    try testing.expectEqualStrings("control_flow", dispatcher.getHandlerModuleName(0x56).?);
    try testing.expectEqualStrings("control_flow", dispatcher.getHandlerModuleName(0xf3).?);

    // Test log opcodes
    try testing.expectEqualStrings("log", dispatcher.getHandlerModuleName(0xa0).?);
    try testing.expectEqualStrings("log", dispatcher.getHandlerModuleName(0xa4).?);

    // Test system opcodes
    try testing.expectEqualStrings("system", dispatcher.getHandlerModuleName(0xf0).?);
    try testing.expectEqualStrings("system", dispatcher.getHandlerModuleName(0xff).?);

    // Test invalid opcodes return null
    try testing.expect(dispatcher.getHandlerModuleName(0x0c) == null);
    try testing.expect(dispatcher.getHandlerModuleName(0xa5) == null);
}

test "Dispatcher - opcode ranges" {
    const testing = std.testing;
    const MockFrame = struct {
        pub const EvmError = error{InvalidOpcode};
    };
    const dispatcher = Dispatcher(MockFrame);

    // Test PUSH range (0x5f-0x7f)
    var i: u8 = 0x5f;
    while (i <= 0x7f) : (i += 1) {
        try testing.expectEqualStrings("stack", dispatcher.getHandlerModuleName(i).?);
    }

    // Test DUP range (0x80-0x8f)
    i = 0x80;
    while (i <= 0x8f) : (i += 1) {
        try testing.expectEqualStrings("stack", dispatcher.getHandlerModuleName(i).?);
    }

    // Test SWAP range (0x90-0x9f)
    i = 0x90;
    while (i <= 0x9f) : (i += 1) {
        try testing.expectEqualStrings("stack", dispatcher.getHandlerModuleName(i).?);
    }

    // Test LOG range (0xa0-0xa4)
    i = 0xa0;
    while (i <= 0xa4) : (i += 1) {
        try testing.expectEqualStrings("log", dispatcher.getHandlerModuleName(i).?);
    }

    // Test invalid range after LOG (0xa5-0xef)
    try testing.expect(dispatcher.getHandlerModuleName(0xa5) == null);
    try testing.expect(dispatcher.getHandlerModuleName(0xef) == null);
}
