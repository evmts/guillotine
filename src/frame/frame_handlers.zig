const std = @import("std");
const opcode_data = @import("../opcodes/opcode_data.zig");
const Opcode = opcode_data.Opcode;
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
    const invalid = struct {
        fn handler(frame: *FrameType, cursor: [*]const FrameType.Dispatch.Item) FrameType.Error!noreturn {
            _ = cursor;
            // Invalid opcodes consume all remaining gas and revert
            frame.gas_remaining = 0;
            return FrameType.Error.InvalidOpcode;
        }
    }.handler;

    var h: [256]FrameType.OpcodeHandler = undefined;
    @setEvalBranchQuota(10000);
    for (&h) |*handler| handler.* = &invalid;

    h[@intFromEnum(Opcode.STOP)] = &SystemHandlers.stop;
    h[@intFromEnum(Opcode.ADD)] = &ArithmeticHandlers.add;
    h[@intFromEnum(Opcode.MUL)] = &ArithmeticHandlers.mul;
    h[@intFromEnum(Opcode.SUB)] = &ArithmeticHandlers.sub;
    h[@intFromEnum(Opcode.DIV)] = &ArithmeticHandlers.div;
    h[@intFromEnum(Opcode.SDIV)] = &ArithmeticHandlers.sdiv;
    h[@intFromEnum(Opcode.MOD)] = &ArithmeticHandlers.mod;
    h[@intFromEnum(Opcode.SMOD)] = &ArithmeticHandlers.smod;
    h[@intFromEnum(Opcode.ADDMOD)] = &ArithmeticHandlers.addmod;
    h[@intFromEnum(Opcode.MULMOD)] = &ArithmeticHandlers.mulmod;
    h[@intFromEnum(Opcode.EXP)] = &ArithmeticHandlers.exp;
    h[@intFromEnum(Opcode.SIGNEXTEND)] = &ArithmeticHandlers.signextend;
    h[@intFromEnum(Opcode.LT)] = &ComparisonHandlers.lt;
    h[@intFromEnum(Opcode.GT)] = &ComparisonHandlers.gt;
    h[@intFromEnum(Opcode.SLT)] = &ComparisonHandlers.slt;
    h[@intFromEnum(Opcode.SGT)] = &ComparisonHandlers.sgt;
    h[@intFromEnum(Opcode.EQ)] = &ComparisonHandlers.eq;
    h[@intFromEnum(Opcode.ISZERO)] = &ComparisonHandlers.iszero;
    h[@intFromEnum(Opcode.AND)] = &BitwiseHandlers.@"and";
    h[@intFromEnum(Opcode.OR)] = &BitwiseHandlers.@"or";
    h[@intFromEnum(Opcode.XOR)] = &BitwiseHandlers.xor;
    h[@intFromEnum(Opcode.NOT)] = &BitwiseHandlers.not;
    h[@intFromEnum(Opcode.BYTE)] = &BitwiseHandlers.byte;
    h[@intFromEnum(Opcode.SHL)] = &BitwiseHandlers.shl;
    h[@intFromEnum(Opcode.SHR)] = &BitwiseHandlers.shr;
    h[@intFromEnum(Opcode.SAR)] = &BitwiseHandlers.sar;
    h[@intFromEnum(Opcode.KECCAK256)] = &KeccakHandlers.keccak;
    h[@intFromEnum(Opcode.ADDRESS)] = &ContextHandlers.address;
    h[@intFromEnum(Opcode.BALANCE)] = &ContextHandlers.balance;
    h[@intFromEnum(Opcode.ORIGIN)] = &ContextHandlers.origin;
    h[@intFromEnum(Opcode.CALLER)] = &ContextHandlers.caller;
    h[@intFromEnum(Opcode.CALLVALUE)] = &ContextHandlers.callvalue;
    h[@intFromEnum(Opcode.CALLDATALOAD)] = &ContextHandlers.calldataload;
    h[@intFromEnum(Opcode.CALLDATASIZE)] = &ContextHandlers.calldatasize;
    h[@intFromEnum(Opcode.CALLDATACOPY)] = &ContextHandlers.calldatacopy;
    h[@intFromEnum(Opcode.CODESIZE)] = &ContextHandlers.codesize;
    h[@intFromEnum(Opcode.CODECOPY)] = &ContextHandlers.codecopy;
    h[@intFromEnum(Opcode.GASPRICE)] = &ContextHandlers.gasprice;
    h[@intFromEnum(Opcode.EXTCODESIZE)] = &ContextHandlers.extcodesize;
    h[@intFromEnum(Opcode.EXTCODECOPY)] = &ContextHandlers.extcodecopy;
    h[@intFromEnum(Opcode.RETURNDATASIZE)] = &ContextHandlers.returndatasize;
    h[@intFromEnum(Opcode.RETURNDATACOPY)] = &ContextHandlers.returndatacopy;
    h[@intFromEnum(Opcode.EXTCODEHASH)] = &ContextHandlers.extcodehash;
    h[@intFromEnum(Opcode.BLOCKHASH)] = &ContextHandlers.blockhash;
    h[@intFromEnum(Opcode.COINBASE)] = &ContextHandlers.coinbase;
    h[@intFromEnum(Opcode.TIMESTAMP)] = &ContextHandlers.timestamp;
    h[@intFromEnum(Opcode.NUMBER)] = &ContextHandlers.number;
    h[@intFromEnum(Opcode.DIFFICULTY)] = &ContextHandlers.difficulty;
    h[@intFromEnum(Opcode.GASLIMIT)] = &ContextHandlers.gaslimit;
    h[@intFromEnum(Opcode.CHAINID)] = &ContextHandlers.chainid;
    h[@intFromEnum(Opcode.SELFBALANCE)] = &ContextHandlers.selfbalance;
    h[@intFromEnum(Opcode.BASEFEE)] = &ContextHandlers.basefee;
    h[@intFromEnum(Opcode.BLOBHASH)] = &ContextHandlers.blobhash;
    h[@intFromEnum(Opcode.BLOBBASEFEE)] = &ContextHandlers.blobbasefee;
    h[@intFromEnum(Opcode.POP)] = &StackHandlers.pop;
    h[@intFromEnum(Opcode.MLOAD)] = &MemoryHandlers.mload;
    h[@intFromEnum(Opcode.MSTORE)] = &MemoryHandlers.mstore;
    h[@intFromEnum(Opcode.MSTORE8)] = &MemoryHandlers.mstore8;
    h[@intFromEnum(Opcode.SLOAD)] = &StorageHandlers.sload;
    h[@intFromEnum(Opcode.SSTORE)] = &StorageHandlers.sstore;
    h[@intFromEnum(Opcode.JUMP)] = &JumpHandlers.jump;
    h[@intFromEnum(Opcode.JUMPI)] = &JumpHandlers.jumpi;
    h[@intFromEnum(Opcode.PC)] = &ContextHandlers.pc;
    h[@intFromEnum(Opcode.MSIZE)] = &MemoryHandlers.msize;
    h[@intFromEnum(Opcode.MCOPY)] = &MemoryHandlers.mcopy;
    h[@intFromEnum(Opcode.GAS)] = &ContextHandlers.gas;
    h[@intFromEnum(Opcode.JUMPDEST)] = &JumpHandlers.jumpdest;
    h[@intFromEnum(Opcode.TLOAD)] = &StorageHandlers.tload;
    h[@intFromEnum(Opcode.TSTORE)] = &StorageHandlers.tstore;
    // PUSH
    h[@intFromEnum(Opcode.PUSH0)] = &StackHandlers.push0;
    inline for (1..33) |i| {
        const push_n = @as(u8, @intCast(i));
        const opcode = @as(Opcode, @enumFromInt(@intFromEnum(Opcode.PUSH0) + push_n));
        h[@intFromEnum(opcode)] = StackHandlers.generatePushHandler(push_n);
    }
    // DUP
    inline for (1..17) |i| {
        const dup_n = @as(u8, @intCast(i));
        const opcode = @as(Opcode, @enumFromInt(@intFromEnum(Opcode.DUP1) + dup_n - 1));
        h[@intFromEnum(opcode)] = StackHandlers.generateDupHandler(dup_n);
    }
    // SWAP
    inline for (1..17) |i| {
        const swap_n = @as(u8, @intCast(i));
        const opcode = @as(Opcode, @enumFromInt(@intFromEnum(Opcode.SWAP1) + swap_n - 1));
        h[@intFromEnum(opcode)] = StackHandlers.generateSwapHandler(swap_n);
    }
    h[@intFromEnum(Opcode.LOG0)] = LogHandlers.log0;
    h[@intFromEnum(Opcode.LOG1)] = LogHandlers.log1;
    h[@intFromEnum(Opcode.LOG2)] = LogHandlers.log2;
    h[@intFromEnum(Opcode.LOG3)] = LogHandlers.log3;
    h[@intFromEnum(Opcode.LOG4)] = LogHandlers.log4;
    h[@intFromEnum(Opcode.CREATE)] = &SystemHandlers.create;
    h[@intFromEnum(Opcode.CALL)] = &SystemHandlers.call;
    h[@intFromEnum(Opcode.CREATE2)] = &SystemHandlers.create2;
    h[@intFromEnum(Opcode.CALLCODE)] = &SystemHandlers.callcode;
    h[@intFromEnum(Opcode.RETURN)] = &SystemHandlers.@"return";
    h[@intFromEnum(Opcode.DELEGATECALL)] = &SystemHandlers.delegatecall;
    h[@intFromEnum(Opcode.STATICCALL)] = &SystemHandlers.staticcall;
    h[@intFromEnum(Opcode.REVERT)] = &SystemHandlers.revert;
    h[@intFromEnum(Opcode.INVALID)] = &invalid;
    h[@intFromEnum(Opcode.SELFDESTRUCT)] = &SystemHandlers.selfdestruct;
    // AUTH and AUTHCALL (EIP-3074) are activated in Prague hardfork
    h[@intFromEnum(Opcode.AUTH)] = &SystemHandlers.auth;
    h[@intFromEnum(Opcode.AUTHCALL)] = &SystemHandlers.authcall;
    // Note: Synthetic opcodes (0xa5-0xbc) are NOT mapped here because they should only be used
    // internally by the dispatch system during optimization. Raw bytecode containing these values
    // should be treated as invalid opcodes and use the default invalid handler.

    // Apply custom overrides
    inline for (overrides) |override| {
        h[override.opcode] = override.handler;
    }

    return h;
}

/// Get a synthetic opcode handler by its opcode value.
/// This is separate from the main handlers array to ensure synthetic opcodes are only used internally.
pub fn getSyntheticHandler(FrameType: type, synthetic_opcode: u8) FrameType.OpcodeHandler {
    // Import synthetic handler modules
    const ArithmeticSyntheticHandlers = stack_frame_arithmetic_synthetic.Handlers(FrameType);
    const BitwiseSyntheticHandlers = stack_frame_bitwise_synthetic.Handlers(FrameType);
    const MemorySyntheticHandlers = stack_frame_memory_synthetic.Handlers(FrameType);
    const JumpSyntheticHandlers = stack_frame_jump_synthetic.Handlers(FrameType);
    const AdvancedSyntheticHandlers = stack_frame_advanced_synthetic.Handlers(FrameType);

    return switch (synthetic_opcode) {
        @intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE) => &ArithmeticSyntheticHandlers.push_add_inline,
        @intFromEnum(OpcodeSynthetic.PUSH_ADD_POINTER) => &ArithmeticSyntheticHandlers.push_add_pointer,
        @intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE) => &ArithmeticSyntheticHandlers.push_mul_inline,
        @intFromEnum(OpcodeSynthetic.PUSH_MUL_POINTER) => &ArithmeticSyntheticHandlers.push_mul_pointer,
        @intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE) => &ArithmeticSyntheticHandlers.push_div_inline,
        @intFromEnum(OpcodeSynthetic.PUSH_DIV_POINTER) => &ArithmeticSyntheticHandlers.push_div_pointer,
        @intFromEnum(OpcodeSynthetic.PUSH_SUB_INLINE) => &ArithmeticSyntheticHandlers.push_sub_inline,
        @intFromEnum(OpcodeSynthetic.PUSH_SUB_POINTER) => &ArithmeticSyntheticHandlers.push_sub_pointer,
        @intFromEnum(OpcodeSynthetic.JUMP_TO_STATIC_LOCATION) => &JumpSyntheticHandlers.jump_to_static_location,
        @intFromEnum(OpcodeSynthetic.JUMPI_TO_STATIC_LOCATION) => &JumpSyntheticHandlers.jumpi_to_static_location,
        @intFromEnum(OpcodeSynthetic.PUSH_MLOAD_INLINE) => &MemorySyntheticHandlers.push_mload_inline,
        @intFromEnum(OpcodeSynthetic.PUSH_MLOAD_POINTER) => &MemorySyntheticHandlers.push_mload_pointer,
        @intFromEnum(OpcodeSynthetic.PUSH_MSTORE_INLINE) => &MemorySyntheticHandlers.push_mstore_inline,
        @intFromEnum(OpcodeSynthetic.PUSH_MSTORE_POINTER) => &MemorySyntheticHandlers.push_mstore_pointer,
        @intFromEnum(OpcodeSynthetic.PUSH_AND_INLINE) => &BitwiseSyntheticHandlers.push_and_inline,
        @intFromEnum(OpcodeSynthetic.PUSH_AND_POINTER) => &BitwiseSyntheticHandlers.push_and_pointer,
        @intFromEnum(OpcodeSynthetic.PUSH_OR_INLINE) => &BitwiseSyntheticHandlers.push_or_inline,
        @intFromEnum(OpcodeSynthetic.PUSH_OR_POINTER) => &BitwiseSyntheticHandlers.push_or_pointer,
        @intFromEnum(OpcodeSynthetic.PUSH_XOR_INLINE) => &BitwiseSyntheticHandlers.push_xor_inline,
        @intFromEnum(OpcodeSynthetic.PUSH_XOR_POINTER) => &BitwiseSyntheticHandlers.push_xor_pointer,
        @intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_INLINE) => &MemorySyntheticHandlers.push_mstore8_inline,
        @intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_POINTER) => &MemorySyntheticHandlers.push_mstore8_pointer,
        @intFromEnum(OpcodeSynthetic.MULTI_PUSH_2) => &AdvancedSyntheticHandlers.multi_push_2,
        @intFromEnum(OpcodeSynthetic.MULTI_PUSH_3) => &AdvancedSyntheticHandlers.multi_push_3,
        @intFromEnum(OpcodeSynthetic.MULTI_POP_2) => &AdvancedSyntheticHandlers.multi_pop_2,
        @intFromEnum(OpcodeSynthetic.MULTI_POP_3) => &AdvancedSyntheticHandlers.multi_pop_3,
        @intFromEnum(OpcodeSynthetic.ISZERO_JUMPI) => &AdvancedSyntheticHandlers.iszero_jumpi,
        @intFromEnum(OpcodeSynthetic.DUP2_MSTORE_PUSH) => &AdvancedSyntheticHandlers.dup2_mstore_push,
        @intFromEnum(OpcodeSynthetic.DUP3_ADD_MSTORE) => &AdvancedSyntheticHandlers.dup3_add_mstore,
        @intFromEnum(OpcodeSynthetic.SWAP1_DUP2_ADD) => &AdvancedSyntheticHandlers.swap1_dup2_add,
        @intFromEnum(OpcodeSynthetic.PUSH_DUP3_ADD) => &AdvancedSyntheticHandlers.push_dup3_add,
        @intFromEnum(OpcodeSynthetic.FUNCTION_DISPATCH) => &AdvancedSyntheticHandlers.function_dispatch,
        @intFromEnum(OpcodeSynthetic.CALLVALUE_CHECK) => &AdvancedSyntheticHandlers.callvalue_check,
        @intFromEnum(OpcodeSynthetic.PUSH0_REVERT) => &AdvancedSyntheticHandlers.push0_revert,
        @intFromEnum(OpcodeSynthetic.PUSH_ADD_DUP1) => &AdvancedSyntheticHandlers.push_add_dup1,
        @intFromEnum(OpcodeSynthetic.MLOAD_SWAP1_DUP2) => &AdvancedSyntheticHandlers.mload_swap1_dup2,
        @intFromEnum(OpcodeSynthetic.BACKWARD_LOOP_JUMPI) => &JumpSyntheticHandlers.backward_loop_jumpi,
        else => unreachable, // Invalid synthetic opcode
    };
}
