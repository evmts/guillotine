const std = @import("std");
const opcode_mod = @import("../opcodes/opcode.zig");
const UnifiedOpcode = opcode_mod.UnifiedOpcode;

/// Generic functions for handling opcode data retrieval from the dispatch instruction stream.
/// These functions map opcodes to their expected metadata types and provide efficient
/// access patterns for the dispatch system.
/// A generic type that casts the 64 byte value to the correct type depending on the opcode.
/// NOTE: The metadata is not tagged (to save cacheline space) so this working safely depends on us always
/// constructing the instruction stream correctly with the expected metadata consistently in the expected spots based on opcode!
/// We also assume every opcode will correctly pass in the correct enum type for their opcode.
pub fn GetOpDataReturnType(
    comptime opcode: UnifiedOpcode,
    comptime OpcodeHandler: type,
    comptime Self: type,
    comptime Item: type,
    comptime PcMetadata: type,
    comptime PushInlineMetadata: type,
    comptime PushPointerMetadata: type,
    comptime JumpDestMetadata: type,
    comptime JumpStaticMetadata: type,
) type {
    return switch (opcode) {
        .PC => struct { metadata: PcMetadata, next_handler: OpcodeHandler, next_cursor: Self },
        .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8 => struct { metadata: PushInlineMetadata, next_handler: OpcodeHandler, next_cursor: Self },
        .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => struct { metadata: PushPointerMetadata, next_handler: OpcodeHandler, next_cursor: Self },
        .JUMPDEST => struct { metadata: JumpDestMetadata, next_handler: OpcodeHandler, next_cursor: Self },
        .PUSH_ADD_INLINE, .PUSH_MUL_INLINE, .PUSH_DIV_INLINE, .PUSH_SUB_INLINE, .PUSH_AND_INLINE, .PUSH_OR_INLINE, .PUSH_XOR_INLINE, .PUSH_MLOAD_INLINE, .PUSH_MSTORE_INLINE, .PUSH_MSTORE8_INLINE => struct { metadata: PushInlineMetadata, next_handler: OpcodeHandler, next_cursor: Self },
        .JUMP_TO_STATIC_LOCATION, .JUMPI_TO_STATIC_LOCATION => struct { metadata: JumpStaticMetadata, next_handler: OpcodeHandler, next_cursor: Self },
        .PUSH_ADD_POINTER, .PUSH_MUL_POINTER, .PUSH_DIV_POINTER, .PUSH_SUB_POINTER, .PUSH_AND_POINTER, .PUSH_OR_POINTER, .PUSH_XOR_POINTER, .PUSH_MLOAD_POINTER, .PUSH_MSTORE_POINTER, .PUSH_MSTORE8_POINTER => struct { metadata: PushPointerMetadata, next_handler: OpcodeHandler, next_cursor: Self },
        // Advanced synthetic opcodes with special metadata requirements
        .MULTI_PUSH_2 => struct { items: [*]const Item, next_handler: OpcodeHandler, next_cursor: Self }, // Points to 2 push items
        .MULTI_PUSH_3 => struct { items: [*]const Item, next_handler: OpcodeHandler, next_cursor: Self }, // Points to 3 push items
        .MULTI_POP_2, .MULTI_POP_3 => struct { next_handler: OpcodeHandler, next_cursor: Self }, // No metadata
        .ISZERO_JUMPI => struct { items: [*]const Item, next_handler: OpcodeHandler, next_cursor: Self }, // Jump target item
        .DUP2_MSTORE_PUSH => struct { items: [*]const Item, next_handler: OpcodeHandler, next_cursor: Self }, // Push value item
        // New high-impact fusions
        .DUP3_ADD_MSTORE => struct { next_handler: OpcodeHandler, next_cursor: Self }, // No metadata
        .SWAP1_DUP2_ADD => struct { next_handler: OpcodeHandler, next_cursor: Self }, // No metadata
        .PUSH_DUP3_ADD => struct { items: [*]const Item, next_handler: OpcodeHandler, next_cursor: Self }, // Push value item
        .FUNCTION_DISPATCH => struct { items: [*]const Item, next_handler: OpcodeHandler, next_cursor: Self }, // Selector + target items
        .CALLVALUE_CHECK => struct { next_handler: OpcodeHandler, next_cursor: Self }, // No metadata
        .PUSH0_REVERT => struct { next_handler: OpcodeHandler, next_cursor: Self }, // No metadata
        .PUSH_ADD_DUP1 => struct { items: [*]const Item, next_handler: OpcodeHandler, next_cursor: Self }, // Push value item
        .MLOAD_SWAP1_DUP2 => struct { next_handler: OpcodeHandler, next_cursor: Self }, // No metadata
        // All standard opcodes without metadata
        .STOP, .ADD, .MUL, .SUB, .DIV, .SDIV, .MOD, .SMOD, .ADDMOD, .MULMOD, .EXP, .SIGNEXTEND, .LT, .GT, .SLT, .SGT, .EQ, .ISZERO, .AND, .OR, .XOR, .NOT, .BYTE, .SHL, .SHR, .SAR, .KECCAK256, .ADDRESS, .BALANCE, .ORIGIN, .CALLER, .CALLVALUE, .CALLDATALOAD, .CALLDATASIZE, .CALLDATACOPY, .CODESIZE, .CODECOPY, .GASPRICE, .EXTCODESIZE, .EXTCODECOPY, .RETURNDATASIZE, .RETURNDATACOPY, .EXTCODEHASH, .BLOCKHASH, .COINBASE, .TIMESTAMP, .NUMBER, .PREVRANDAO, .GASLIMIT, .CHAINID, .SELFBALANCE, .BASEFEE, .BLOBHASH, .BLOBBASEFEE, .POP, .MLOAD, .MSTORE, .MSTORE8, .SLOAD, .SSTORE, .JUMP, .JUMPI, .MSIZE, .GAS, .TLOAD, .TSTORE, .MCOPY, .PUSH0, .DUP1, .DUP2, .DUP3, .DUP4, .DUP5, .DUP6, .DUP7, .DUP8, .DUP9, .DUP10, .DUP11, .DUP12, .DUP13, .DUP14, .DUP15, .DUP16, .SWAP1, .SWAP2, .SWAP3, .SWAP4, .SWAP5, .SWAP6, .SWAP7, .SWAP8, .SWAP9, .SWAP10, .SWAP11, .SWAP12, .SWAP13, .SWAP14, .SWAP15, .SWAP16, .LOG0, .LOG1, .LOG2, .LOG3, .LOG4, .CREATE, .CALL, .CALLCODE, .RETURN, .DELEGATECALL, .CREATE2, .AUTH, .AUTHCALL, .STATICCALL, .REVERT, .INVALID, .SELFDESTRUCT => struct { next_handler: OpcodeHandler, next_cursor: Self },
    };
}

/// Get opcode data including metadata and next dispatch position.
/// This is a comptime-optimized method for specific opcodes.
///
/// The cursor parameter is expected to point to the NEXT slot after the current opcode handler.
/// For opcodes with metadata, the metadata is at cursor[0].
/// Returns the next handler to call and the cursor to pass to it.
pub inline fn getOpData(
    comptime opcode: UnifiedOpcode,
    comptime Self: type,
    comptime Item: type,
    cursor: [*]const Item,
) GetOpDataReturnType(
    opcode,
    @TypeOf(@as(Item, undefined).opcode_handler),
    Self,
    Item,
    @TypeOf(@as(Item, undefined).pc),
    @TypeOf(@as(Item, undefined).push_inline),
    @TypeOf(@as(Item, undefined).push_pointer),
    @TypeOf(@as(Item, undefined).jump_dest),
    @TypeOf(@as(Item, undefined).jump_static),
) {
    return switch (opcode) {
        .PC => .{
            .metadata = cursor[1].pc,
            .next_handler = cursor[2].opcode_handler,
            .next_cursor = Self{ .cursor = cursor + 2 },
        },
        .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8 => .{
            .metadata = cursor[1].push_inline,
            .next_handler = cursor[2].opcode_handler,
            .next_cursor = Self{ .cursor = cursor + 2 },
        },
        .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => .{
            .metadata = cursor[1].push_pointer,
            .next_handler = cursor[2].opcode_handler,
            .next_cursor = Self{ .cursor = cursor + 2 },
        },
        .JUMPDEST => .{
            .metadata = cursor[1].jump_dest,
            .next_handler = cursor[2].opcode_handler,
            .next_cursor = Self{ .cursor = cursor + 2 },
        },
        .PUSH_ADD_INLINE, .PUSH_MUL_INLINE, .PUSH_DIV_INLINE, .PUSH_SUB_INLINE, .PUSH_AND_INLINE, .PUSH_OR_INLINE, .PUSH_XOR_INLINE, .PUSH_MLOAD_INLINE, .PUSH_MSTORE_INLINE, .PUSH_MSTORE8_INLINE => .{
            .metadata = cursor[1].push_inline,
            .next_handler = cursor[2].opcode_handler,
            .next_cursor = Self{ .cursor = cursor + 2 },
        },
        .JUMP_TO_STATIC_LOCATION, .JUMPI_TO_STATIC_LOCATION => .{
            .metadata = cursor[1].jump_static,
            .next_handler = cursor[2].opcode_handler,
            .next_cursor = Self{ .cursor = cursor + 2 },
        },
        .PUSH_ADD_POINTER, .PUSH_MUL_POINTER, .PUSH_DIV_POINTER, .PUSH_SUB_POINTER, .PUSH_AND_POINTER, .PUSH_OR_POINTER, .PUSH_XOR_POINTER, .PUSH_MLOAD_POINTER, .PUSH_MSTORE_POINTER, .PUSH_MSTORE8_POINTER => .{
            .metadata = cursor[1].push_pointer,
            .next_handler = cursor[2].opcode_handler,
            .next_cursor = Self{ .cursor = cursor + 2 },
        },
        // Advanced synthetic opcodes
        .MULTI_PUSH_2 => .{
            .items = cursor + 1, // Points to the 2 push items starting at cursor[1]
            .next_handler = cursor[3].opcode_handler,
            .next_cursor = Self{ .cursor = cursor + 3 },
        },
        .MULTI_PUSH_3 => .{
            .items = cursor + 1, // Points to the 3 push items starting at cursor[1]
            .next_handler = cursor[4].opcode_handler,
            .next_cursor = Self{ .cursor = cursor + 4 },
        },
        .MULTI_POP_2, .MULTI_POP_3 => .{
            .next_handler = cursor[1].opcode_handler,
            .next_cursor = Self{ .cursor = cursor + 1 },
        },
        .ISZERO_JUMPI => .{
            .items = cursor + 1, // Points to jump target item at cursor[1]
            .next_handler = cursor[2].opcode_handler,
            .next_cursor = Self{ .cursor = cursor + 2 },
        },
        .DUP2_MSTORE_PUSH => .{
            .items = cursor + 1, // Points to push value item at cursor[1]
            .next_handler = cursor[2].opcode_handler,
            .next_cursor = Self{ .cursor = cursor + 2 },
        },
        // New high-impact fusions
        .DUP3_ADD_MSTORE, .SWAP1_DUP2_ADD, .CALLVALUE_CHECK, .PUSH0_REVERT, .MLOAD_SWAP1_DUP2 => .{
            .next_handler = cursor[1].opcode_handler,
            .next_cursor = Self{ .cursor = cursor + 1 },
        },
        .PUSH_DUP3_ADD, .PUSH_ADD_DUP1 => .{
            .items = cursor + 1, // Points to push value item at cursor[1]
            .next_handler = cursor[2].opcode_handler,
            .next_cursor = Self{ .cursor = cursor + 2 },
        },
        .FUNCTION_DISPATCH => .{
            .items = cursor + 1, // Points to selector and target items starting at cursor[1]
            .next_handler = cursor[3].opcode_handler,
            .next_cursor = Self{ .cursor = cursor + 3 },
        },
        // All standard opcodes without metadata
        .STOP, .ADD, .MUL, .SUB, .DIV, .SDIV, .MOD, .SMOD, .ADDMOD, .MULMOD, .EXP, .SIGNEXTEND, .LT, .GT, .SLT, .SGT, .EQ, .ISZERO, .AND, .OR, .XOR, .NOT, .BYTE, .SHL, .SHR, .SAR, .KECCAK256, .ADDRESS, .BALANCE, .ORIGIN, .CALLER, .CALLVALUE, .CALLDATALOAD, .CALLDATASIZE, .CALLDATACOPY, .CODESIZE, .CODECOPY, .GASPRICE, .EXTCODESIZE, .EXTCODECOPY, .RETURNDATASIZE, .RETURNDATACOPY, .EXTCODEHASH, .BLOCKHASH, .COINBASE, .TIMESTAMP, .NUMBER, .PREVRANDAO, .GASLIMIT, .CHAINID, .SELFBALANCE, .BASEFEE, .BLOBHASH, .BLOBBASEFEE, .POP, .MLOAD, .MSTORE, .MSTORE8, .SLOAD, .SSTORE, .JUMP, .JUMPI, .MSIZE, .GAS, .TLOAD, .TSTORE, .MCOPY, .PUSH0, .DUP1, .DUP2, .DUP3, .DUP4, .DUP5, .DUP6, .DUP7, .DUP8, .DUP9, .DUP10, .DUP11, .DUP12, .DUP13, .DUP14, .DUP15, .DUP16, .SWAP1, .SWAP2, .SWAP3, .SWAP4, .SWAP5, .SWAP6, .SWAP7, .SWAP8, .SWAP9, .SWAP10, .SWAP11, .SWAP12, .SWAP13, .SWAP14, .SWAP15, .SWAP16, .LOG0, .LOG1, .LOG2, .LOG3, .LOG4, .CREATE, .CALL, .CALLCODE, .RETURN, .DELEGATECALL, .CREATE2, .AUTH, .AUTHCALL, .STATICCALL, .REVERT, .INVALID, .SELFDESTRUCT => .{
            .next_handler = cursor[1].opcode_handler,
            .next_cursor = Self{ .cursor = cursor + 1 },
        },
    };
}
