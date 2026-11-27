const std = @import("std");
const opcode_data = @import("../opcodes/opcode_data.zig");
const fork_gas = @import("fork_gas.zig");
const Opcode = opcode_data.Opcode;
const handler_abi = @import("../preprocessor/handler_abi.zig");
const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;
const stack_frame_arithmetic = @import("../instructions/handlers_arithmetic.zig");
const stack_frame_comparison = @import("../instructions/handlers_comparison.zig");
const stack_frame_bitwise = @import("../instructions/handlers_bitwise.zig");
const stack_frame_stack = @import("../instructions/handlers_stack.zig");
const stack_frame_memory = @import("../instructions/handlers_memory.zig");
const stack_frame_storage = @import("../instructions/handlers_storage.zig");
const stack_frame_jump = @import("../instructions/handlers_jump.zig");
const stack_frame_system = @import("../instructions/handlers_system.zig");
const stack_frame_context = @import("../instructions/handlers_context.zig");
const stack_frame_keccak = @import("../instructions/handlers_keccak.zig");
const stack_frame_log = @import("../instructions/handlers_log.zig");
// Synthetic handler modules
const stack_frame_arithmetic_synthetic = @import("../instructions/handlers_arithmetic_synthetic.zig");
const stack_frame_bitwise_synthetic = @import("../instructions/handlers_bitwise_synthetic.zig");
const stack_frame_memory_synthetic = @import("../instructions/handlers_memory_synthetic.zig");
const stack_frame_jump_synthetic = @import("../instructions/handlers_jump_synthetic.zig");
const stack_frame_advanced_synthetic = @import("../instructions/handlers_advanced_synthetic.zig");

/// Type for handler overrides that depends on FrameType
pub fn HandlerOverride(FrameType: type) type {
    return struct {
        opcode: u8,
        handler: FrameType.OpcodeHandler,
    };
}

/// Returns opcode handlers array with optional custom overrides
pub fn getOpcodeHandlers(
    comptime FrameType: type,
    comptime overrides: []const HandlerOverride(FrameType),
) [256]FrameType.OpcodeHandler {
    // Import handler modules with FrameType
    const ArithmeticHandlers = stack_frame_arithmetic.Handlers(FrameType);
    const ComparisonHandlers = stack_frame_comparison.Handlers(FrameType);
    const BitwiseHandlers = stack_frame_bitwise.Handlers(FrameType);
    const StackHandlers = stack_frame_stack.Handlers(FrameType);
    const MemoryHandlers = stack_frame_memory.Handlers(FrameType);
    const StorageHandlers = stack_frame_storage.Handlers(FrameType);
    const JumpHandlers = stack_frame_jump.Handlers(FrameType);
    const SystemHandlers = stack_frame_system.Handlers(FrameType);
    const ContextHandlers = stack_frame_context.Handlers(FrameType);
    const KeccakHandlers = stack_frame_keccak.Handlers(FrameType);
    const LogHandlers = stack_frame_log.Handlers(FrameType);

    // The default opcode handler used for any opcode that is not supported by the EVM
    const invalid = handler_abi.wrap(FrameType, struct {
        fn handler(
            frame: *FrameType,
            cursor: [*]const FrameType.Dispatch.Item,
        ) FrameType.Error![*]const FrameType.Dispatch.Item {
            _ = cursor;
            // Invalid opcodes consume all remaining gas and revert
            frame.gas_remaining = 0;
            return FrameType.Error.InvalidOpcode;
        }
    }.handler);

    var h: [256]FrameType.OpcodeHandler = undefined;
    @setEvalBranchQuota(10000);
    for (&h) |*handler| handler.* = invalid;

    h[@backingInt(Opcode.STOP)] = handler_abi.wrap(FrameType, SystemHandlers.stop);
    h[@backingInt(Opcode.ADD)] = &ArithmeticHandlers.add;
    h[@backingInt(Opcode.MUL)] = &ArithmeticHandlers.mul;
    h[@backingInt(Opcode.SUB)] = &ArithmeticHandlers.sub;
    h[@backingInt(Opcode.DIV)] = &ArithmeticHandlers.div;
    h[@backingInt(Opcode.SDIV)] = &ArithmeticHandlers.sdiv;
    h[@backingInt(Opcode.MOD)] = &ArithmeticHandlers.mod;
    h[@backingInt(Opcode.SMOD)] = &ArithmeticHandlers.smod;
    h[@backingInt(Opcode.ADDMOD)] = &ArithmeticHandlers.addmod;
    h[@backingInt(Opcode.MULMOD)] = &ArithmeticHandlers.mulmod;
    h[@backingInt(Opcode.EXP)] = handler_abi.wrap(FrameType, ArithmeticHandlers.exp);
    h[@backingInt(Opcode.SIGNEXTEND)] = &ArithmeticHandlers.signextend;
    h[@backingInt(Opcode.LT)] = &ComparisonHandlers.lt;
    h[@backingInt(Opcode.GT)] = &ComparisonHandlers.gt;
    h[@backingInt(Opcode.SLT)] = &ComparisonHandlers.slt;
    h[@backingInt(Opcode.SGT)] = &ComparisonHandlers.sgt;
    h[@backingInt(Opcode.EQ)] = &ComparisonHandlers.eq;
    h[@backingInt(Opcode.ISZERO)] = &ComparisonHandlers.iszero;
    h[@backingInt(Opcode.AND)] = &BitwiseHandlers.@"and";
    h[@backingInt(Opcode.OR)] = &BitwiseHandlers.@"or";
    h[@backingInt(Opcode.XOR)] = &BitwiseHandlers.xor;
    h[@backingInt(Opcode.NOT)] = &BitwiseHandlers.not;
    h[@backingInt(Opcode.BYTE)] = &BitwiseHandlers.byte;
    h[@backingInt(Opcode.SHL)] = &BitwiseHandlers.shl;
    h[@backingInt(Opcode.SHR)] = &BitwiseHandlers.shr;
    h[@backingInt(Opcode.SAR)] = &BitwiseHandlers.sar;
    h[@backingInt(Opcode.CLZ)] = &BitwiseHandlers.clz;
    h[@backingInt(Opcode.KECCAK256)] = handler_abi.wrap(FrameType, KeccakHandlers.keccak);
    h[@backingInt(Opcode.ADDRESS)] = &ContextHandlers.address;
    h[@backingInt(Opcode.BALANCE)] = handler_abi.wrap(FrameType, ContextHandlers.balance);
    h[@backingInt(Opcode.ORIGIN)] = &ContextHandlers.origin;
    h[@backingInt(Opcode.CALLER)] = &ContextHandlers.caller;
    h[@backingInt(Opcode.CALLVALUE)] = &ContextHandlers.callvalue;
    h[@backingInt(Opcode.CALLDATALOAD)] = &ContextHandlers.calldataload;
    h[@backingInt(Opcode.CALLDATASIZE)] = &ContextHandlers.calldatasize;
    h[@backingInt(Opcode.CALLDATACOPY)] = handler_abi.wrap(FrameType, ContextHandlers.calldatacopy);
    h[@backingInt(Opcode.CODESIZE)] = &ContextHandlers.codesize;
    h[@backingInt(Opcode.CODECOPY)] = handler_abi.wrap(FrameType, ContextHandlers.codecopy);
    h[@backingInt(Opcode.GASPRICE)] = &ContextHandlers.gasprice;
    h[@backingInt(Opcode.EXTCODESIZE)] = handler_abi.wrap(FrameType, ContextHandlers.extcodesize);
    h[@backingInt(Opcode.EXTCODECOPY)] = handler_abi.wrap(FrameType, ContextHandlers.extcodecopy);
    h[@backingInt(Opcode.RETURNDATASIZE)] = &ContextHandlers.returndatasize;
    h[@backingInt(Opcode.RETURNDATACOPY)] = handler_abi.wrap(FrameType, ContextHandlers.returndatacopy);
    h[@backingInt(Opcode.EXTCODEHASH)] = handler_abi.wrap(FrameType, ContextHandlers.extcodehash);
    h[@backingInt(Opcode.BLOCKHASH)] = handler_abi.wrap(FrameType, ContextHandlers.blockhash);
    h[@backingInt(Opcode.COINBASE)] = &ContextHandlers.coinbase;
    h[@backingInt(Opcode.TIMESTAMP)] = &ContextHandlers.timestamp;
    h[@backingInt(Opcode.NUMBER)] = &ContextHandlers.number;
    h[@backingInt(Opcode.DIFFICULTY)] = &ContextHandlers.difficulty;
    h[@backingInt(Opcode.GASLIMIT)] = &ContextHandlers.gaslimit;
    h[@backingInt(Opcode.CHAINID)] = &ContextHandlers.chainid;
    h[@backingInt(Opcode.SELFBALANCE)] = handler_abi.wrap(FrameType, ContextHandlers.selfbalance);
    h[@backingInt(Opcode.BASEFEE)] = &ContextHandlers.basefee;
    h[@backingInt(Opcode.BLOBHASH)] = handler_abi.wrap(FrameType, ContextHandlers.blobhash);
    h[@backingInt(Opcode.BLOBBASEFEE)] = &ContextHandlers.blobbasefee;
    h[@backingInt(Opcode.POP)] = &StackHandlers.pop;
    h[@backingInt(Opcode.MLOAD)] = &MemoryHandlers.mload;
    h[@backingInt(Opcode.MSTORE)] = &MemoryHandlers.mstore;
    h[@backingInt(Opcode.MSTORE8)] = &MemoryHandlers.mstore8;
    h[@backingInt(Opcode.SLOAD)] = handler_abi.wrap(FrameType, StorageHandlers.sload);
    h[@backingInt(Opcode.SSTORE)] = handler_abi.wrap(FrameType, StorageHandlers.sstore);
    h[@backingInt(Opcode.JUMP)] = &JumpHandlers.jump;
    h[@backingInt(Opcode.JUMPI)] = &JumpHandlers.jumpi;
    h[@backingInt(Opcode.PC)] = &ContextHandlers.pc;
    h[@backingInt(Opcode.MSIZE)] = &MemoryHandlers.msize;
    h[@backingInt(Opcode.MCOPY)] = handler_abi.wrap(FrameType, MemoryHandlers.mcopy);
    h[@backingInt(Opcode.GAS)] = &ContextHandlers.gas;
    h[@backingInt(Opcode.JUMPDEST)] = &JumpHandlers.jumpdest;
    h[@backingInt(Opcode.TLOAD)] = handler_abi.wrap(FrameType, StorageHandlers.tload);
    h[@backingInt(Opcode.TSTORE)] = handler_abi.wrap(FrameType, StorageHandlers.tstore);
    // PUSH
    h[@backingInt(Opcode.PUSH0)] = &StackHandlers.push0;
    inline for (1..33) |i| {
        const push_n = @as(u8, @intCast(i));
        const opcode = @as(Opcode, @fromBackingInt(@intCast(@backingInt(Opcode.PUSH0) + push_n)));
        h[@backingInt(opcode)] = StackHandlers.generatePushHandler(push_n);
    }
    // DUP
    inline for (1..17) |i| {
        const dup_n = @as(u8, @intCast(i));
        const opcode = @as(Opcode, @fromBackingInt(@intCast(@backingInt(Opcode.DUP1) + dup_n - 1)));
        h[@backingInt(opcode)] = StackHandlers.generateDupHandler(dup_n);
    }
    // SWAP
    inline for (1..17) |i| {
        const swap_n = @as(u8, @intCast(i));
        const opcode = @as(Opcode, @fromBackingInt(@intCast(@backingInt(Opcode.SWAP1) + swap_n - 1)));
        h[@backingInt(opcode)] = StackHandlers.generateSwapHandler(swap_n);
    }
    h[@backingInt(Opcode.LOG0)] = LogHandlers.log0;
    h[@backingInt(Opcode.LOG1)] = LogHandlers.log1;
    h[@backingInt(Opcode.LOG2)] = LogHandlers.log2;
    h[@backingInt(Opcode.LOG3)] = LogHandlers.log3;
    h[@backingInt(Opcode.LOG4)] = LogHandlers.log4;
    h[@backingInt(Opcode.CREATE)] = handler_abi.wrap(FrameType, SystemHandlers.create);
    h[@backingInt(Opcode.CALL)] = handler_abi.wrap(FrameType, SystemHandlers.call);
    h[@backingInt(Opcode.CREATE2)] = handler_abi.wrap(FrameType, SystemHandlers.create2);
    h[@backingInt(Opcode.CALLCODE)] = handler_abi.wrap(FrameType, SystemHandlers.callcode);
    h[@backingInt(Opcode.RETURN)] = handler_abi.wrap(FrameType, SystemHandlers.@"return");
    h[@backingInt(Opcode.DELEGATECALL)] = handler_abi.wrap(FrameType, SystemHandlers.delegatecall);
    h[@backingInt(Opcode.STATICCALL)] = handler_abi.wrap(FrameType, SystemHandlers.staticcall);
    h[@backingInt(Opcode.REVERT)] = handler_abi.wrap(FrameType, SystemHandlers.revert);
    h[@backingInt(Opcode.INVALID)] = invalid;
    h[@backingInt(Opcode.SELFDESTRUCT)] = handler_abi.wrap(FrameType, SystemHandlers.selfdestruct);
    // 0xF6 and 0xF7 (AUTH/AUTHCALL) belonged to EIP-3074, which was withdrawn and never
    // activated: EIP-7702 replaced it in Prague. Both are undefined on every mainnet fork.
    h[@backingInt(Opcode.AUTH)] = invalid;
    h[@backingInt(Opcode.AUTHCALL)] = invalid;
    // Note: Synthetic opcodes (0xa5-0xbc) are NOT mapped here because they should only be used
    // internally by the dispatch system during optimization. Raw bytecode containing these values
    // should be treated as invalid opcodes and use the default invalid handler.

    // Opcodes a later fork introduces are undefined on this one.
    for (&h, 0..) |*handler, opcode| {
        if (!fork_gas.isOpcodeDefined(FrameType.config.hardfork, @intCast(opcode))) handler.* = invalid;
    }

    // Apply custom overrides
    inline for (overrides) |override| {
        h[override.opcode] = override.handler;
    }

    return h;
}

/// Get a synthetic opcode handler by its enum tag (exhaustive at compile time).
/// This is separate from the main handlers array to ensure synthetic opcodes are only used internally.
pub fn getSyntheticHandler(FrameType: type, synthetic_opcode: OpcodeSynthetic) FrameType.OpcodeHandler {
    // Import synthetic handler modules
    const ArithmeticSyntheticHandlers = stack_frame_arithmetic_synthetic.Handlers(FrameType);
    const BitwiseSyntheticHandlers = stack_frame_bitwise_synthetic.Handlers(FrameType);
    const MemorySyntheticHandlers = stack_frame_memory_synthetic.Handlers(FrameType);
    const JumpSyntheticHandlers = stack_frame_jump_synthetic.Handlers(FrameType);
    const AdvancedSyntheticHandlers = stack_frame_advanced_synthetic.Handlers(FrameType);

    return switch (synthetic_opcode) {
        .PUSH_ADD_INLINE => &ArithmeticSyntheticHandlers.push_add_inline,
        .PUSH_ADD_POINTER => &ArithmeticSyntheticHandlers.push_add_pointer,
        .PUSH_MUL_INLINE => &ArithmeticSyntheticHandlers.push_mul_inline,
        .PUSH_MUL_POINTER => &ArithmeticSyntheticHandlers.push_mul_pointer,
        .PUSH_DIV_INLINE => &ArithmeticSyntheticHandlers.push_div_inline,
        .PUSH_DIV_POINTER => &ArithmeticSyntheticHandlers.push_div_pointer,
        .PUSH_SUB_INLINE => &ArithmeticSyntheticHandlers.push_sub_inline,
        .PUSH_SUB_POINTER => &ArithmeticSyntheticHandlers.push_sub_pointer,
        .JUMP_TO_STATIC_LOCATION => &JumpSyntheticHandlers.jump_to_static_location,
        .JUMPI_TO_STATIC_LOCATION => &JumpSyntheticHandlers.jumpi_to_static_location,
        .PUSH_MLOAD_INLINE => &MemorySyntheticHandlers.push_mload_inline,
        .PUSH_MLOAD_POINTER => &MemorySyntheticHandlers.push_mload_pointer,
        .PUSH_MSTORE_INLINE => &MemorySyntheticHandlers.push_mstore_inline,
        .PUSH_MSTORE_POINTER => &MemorySyntheticHandlers.push_mstore_pointer,
        .PUSH_AND_INLINE => &BitwiseSyntheticHandlers.push_and_inline,
        .PUSH_AND_POINTER => &BitwiseSyntheticHandlers.push_and_pointer,
        .PUSH_OR_INLINE => &BitwiseSyntheticHandlers.push_or_inline,
        .PUSH_OR_POINTER => &BitwiseSyntheticHandlers.push_or_pointer,
        .PUSH_XOR_INLINE => &BitwiseSyntheticHandlers.push_xor_inline,
        .PUSH_XOR_POINTER => &BitwiseSyntheticHandlers.push_xor_pointer,
        .PUSH_MSTORE8_INLINE => &MemorySyntheticHandlers.push_mstore8_inline,
        .PUSH_MSTORE8_POINTER => &MemorySyntheticHandlers.push_mstore8_pointer,
        .ISZERO_JUMPI => &AdvancedSyntheticHandlers.iszero_jumpi,
        .PUSH_ADD_DUP1_INLINE => &AdvancedSyntheticHandlers.push_add_dup1_inline,
        .PUSH_ADD_DUP1_POINTER => &AdvancedSyntheticHandlers.push_add_dup1_pointer,
        .BLOCK_BEGIN => &JumpSyntheticHandlers.block_begin,
        .INVALID_JUMP_TARGET => &JumpSyntheticHandlers.invalid_jump_target,
    };
}

test "frame_handlers exports handler lookup function" {
    try std.testing.expect(@typeInfo(@TypeOf(getOpcodeHandlers)) == .@"fn");
}
