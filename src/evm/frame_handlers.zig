const std = @import("std");
const opcode_data = @import("opcode_data.zig");
const Opcode = opcode_data.Opcode;
const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;
const stack_frame_arithmetic = @import("handlers_arithmetic.zig");
const stack_frame_comparison = @import("handlers_comparison.zig");
const stack_frame_bitwise = @import("handlers_bitwise.zig");
const stack_frame_stack = @import("handlers_stack.zig");
const stack_frame_memory = @import("handlers_memory.zig");
const stack_frame_storage = @import("handlers_storage.zig");
const stack_frame_jump = @import("handlers_jump.zig");
const stack_frame_system = @import("handlers_system.zig");
const stack_frame_context = @import("handlers_context.zig");
const stack_frame_keccak = @import("handlers_keccak.zig");
const stack_frame_log = @import("handlers_log.zig");
// Synthetic handler modules
const stack_frame_arithmetic_synthetic = @import("handlers_arithmetic_synthetic.zig");
const stack_frame_bitwise_synthetic = @import("handlers_bitwise_synthetic.zig");
const stack_frame_memory_synthetic = @import("handlers_memory_synthetic.zig");
const stack_frame_jump_synthetic = @import("handlers_jump_synthetic.zig");

/// Returns the opcode handlers array for a given Frame type
pub fn getOpcodeHandlers(comptime FrameType: type) [256]FrameType.OpcodeHandler {
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
    // Import synthetic handler modules
    const ArithmeticSyntheticHandlers = stack_frame_arithmetic_synthetic.Handlers(FrameType);
    const BitwiseSyntheticHandlers = stack_frame_bitwise_synthetic.Handlers(FrameType);
    const MemorySyntheticHandlers = stack_frame_memory_synthetic.Handlers(FrameType);
    const JumpSyntheticHandlers = stack_frame_jump_synthetic.Handlers(FrameType);

    // The default opcode handler used for any opcode that is not supported by the EVM
    const invalid = struct {
        fn handler(frame: *FrameType, cursor: [*]const FrameType.Dispatch.Item) FrameType.Error!noreturn {
            _ = frame;
            _ = cursor;
            return FrameType.Error.InvalidOpcode;
        }
    }.handler;

    @setEvalBranchQuota(10000);
    var h: [256]FrameType.OpcodeHandler = undefined;
    const invalid_handler: FrameType.OpcodeHandler = &invalid;
    for (&h) |*handler| handler.* = invalid_handler;
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
    h[@intFromEnum(Opcode.PC)] = &JumpHandlers.pc;
    h[@intFromEnum(Opcode.MSIZE)] = &MemoryHandlers.msize;
    h[@intFromEnum(Opcode.GAS)] = &ContextHandlers.gas;
    h[@intFromEnum(Opcode.JUMPDEST)] = &JumpHandlers.jumpdest;
    // TODO: Enable when EVM implementation has transient storage support
    // h[@intFromEnum(Opcode.TLOAD)] = &StorageHandlers.tload;
    // h[@intFromEnum(Opcode.TSTORE)] = &StorageHandlers.tstore;
    h[@intFromEnum(Opcode.MCOPY)] = &MemoryHandlers.mcopy;
    // PUSH
    h[@intFromEnum(Opcode.PUSH0)] = &StackHandlers.push0;
    for (1..33) |i| {
        const push_n = @as(u8, @intCast(i));
        const opcode = @as(Opcode, @enumFromInt(@intFromEnum(Opcode.PUSH0) + push_n));
        h[@intFromEnum(opcode)] = StackHandlers.generatePushHandler(push_n);
    }
    // DUP
    for (1..17) |i| {
        const dup_n = @as(u8, @intCast(i));
        const opcode = @as(Opcode, @enumFromInt(@intFromEnum(Opcode.DUP1) + dup_n - 1));
        h[@intFromEnum(opcode)] = StackHandlers.generateDupHandler(dup_n);
    }
    // SWAP
    for (1..17) |i| {
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
    h[@intFromEnum(Opcode.CALLCODE)] = &invalid; // Deprecated (kept as invalid)
    h[@intFromEnum(Opcode.RETURN)] = &SystemHandlers.@"return";
    h[@intFromEnum(Opcode.DELEGATECALL)] = &SystemHandlers.delegatecall;
    h[@intFromEnum(Opcode.STATICCALL)] = &SystemHandlers.staticcall;
    h[@intFromEnum(Opcode.REVERT)] = &SystemHandlers.revert;
    h[@intFromEnum(Opcode.INVALID)] = &invalid;
    h[@intFromEnum(Opcode.SELFDESTRUCT)] = &SystemHandlers.selfdestruct;
    h[@intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE)] = &ArithmeticSyntheticHandlers.push_add_inline;
    h[@intFromEnum(OpcodeSynthetic.PUSH_ADD_POINTER)] = &ArithmeticSyntheticHandlers.push_add_pointer;
    h[@intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE)] = &ArithmeticSyntheticHandlers.push_mul_inline;
    h[@intFromEnum(OpcodeSynthetic.PUSH_MUL_POINTER)] = &ArithmeticSyntheticHandlers.push_mul_pointer;
    h[@intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE)] = &ArithmeticSyntheticHandlers.push_div_inline;
    h[@intFromEnum(OpcodeSynthetic.PUSH_DIV_POINTER)] = &ArithmeticSyntheticHandlers.push_div_pointer;
    h[@intFromEnum(OpcodeSynthetic.PUSH_SUB_INLINE)] = &ArithmeticSyntheticHandlers.push_sub_inline;
    h[@intFromEnum(OpcodeSynthetic.PUSH_SUB_POINTER)] = &ArithmeticSyntheticHandlers.push_sub_pointer;
    h[@intFromEnum(OpcodeSynthetic.PUSH_JUMP_INLINE)] = &JumpSyntheticHandlers.push_jump_inline;
    h[@intFromEnum(OpcodeSynthetic.PUSH_JUMP_POINTER)] = &JumpSyntheticHandlers.push_jump_pointer;
    h[@intFromEnum(OpcodeSynthetic.PUSH_JUMPI_INLINE)] = &JumpSyntheticHandlers.push_jumpi_inline;
    h[@intFromEnum(OpcodeSynthetic.PUSH_JUMPI_POINTER)] = &JumpSyntheticHandlers.push_jumpi_pointer;
    h[@intFromEnum(OpcodeSynthetic.PUSH_MLOAD_INLINE)] = &MemorySyntheticHandlers.push_mload_inline;
    h[@intFromEnum(OpcodeSynthetic.PUSH_MLOAD_POINTER)] = &MemorySyntheticHandlers.push_mload_pointer;
    h[@intFromEnum(OpcodeSynthetic.PUSH_MSTORE_INLINE)] = &MemorySyntheticHandlers.push_mstore_inline;
    h[@intFromEnum(OpcodeSynthetic.PUSH_MSTORE_POINTER)] = &MemorySyntheticHandlers.push_mstore_pointer;
    h[@intFromEnum(OpcodeSynthetic.PUSH_AND_INLINE)] = &BitwiseSyntheticHandlers.push_and_inline;
    h[@intFromEnum(OpcodeSynthetic.PUSH_AND_POINTER)] = &BitwiseSyntheticHandlers.push_and_pointer;
    h[@intFromEnum(OpcodeSynthetic.PUSH_OR_INLINE)] = &BitwiseSyntheticHandlers.push_or_inline;
    h[@intFromEnum(OpcodeSynthetic.PUSH_OR_POINTER)] = &BitwiseSyntheticHandlers.push_or_pointer;
    h[@intFromEnum(OpcodeSynthetic.PUSH_XOR_INLINE)] = &BitwiseSyntheticHandlers.push_xor_inline;
    h[@intFromEnum(OpcodeSynthetic.PUSH_XOR_POINTER)] = &BitwiseSyntheticHandlers.push_xor_pointer;
    h[@intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_INLINE)] = &MemorySyntheticHandlers.push_mstore8_inline;
    h[@intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_POINTER)] = &MemorySyntheticHandlers.push_mstore8_pointer;
    return h;
}