/// Conditional Opcode Handlers that adapt based on EIP configuration
/// This demonstrates eliminating unsupported opcodes at compile time
const std = @import("std");
const opcode_data = @import("opcode_data.zig");
const Opcode = opcode_data.Opcode;
const EvmConfig = @import("evm_config.zig").EvmConfig;

// Import all handler modules
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

/// Generic function that creates different opcode handler arrays based on hardfork configuration
/// This is the core innovation: handler availability becomes conditional on EIP features
pub fn getConditionalOpcodeHandlers(comptime FrameType: type, comptime config: EvmConfig) [256]FrameType.OpcodeHandler {
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

    // The default invalid opcode handler
    const invalid = struct {
        fn handler(frame: *FrameType, cursor: [*]const FrameType.Dispatch.Item) FrameType.Error!noreturn {
            _ = cursor;
            // Invalid opcodes consume all remaining gas and revert
            frame.gas_remaining = 0;
            return FrameType.Error.OutOfGas;
        }
    }.handler;

    @setEvalBranchQuota(10000);
    var h: [256]FrameType.OpcodeHandler = undefined;
    const invalid_handler: FrameType.OpcodeHandler = &invalid;
    
    // Initialize all handlers to invalid first
    for (&h) |*handler| handler.* = invalid_handler;

    // Always available opcodes (present since Frontier)
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
    
    // Conditionally add opcodes based on hardfork
    
    // Byzantium+ opcodes (EIP-145: Bitwise shifting)
    if (config.eips.hardfork.isAtLeast(.BYZANTIUM)) {
        h[@intFromEnum(Opcode.SHL)] = &BitwiseHandlers.shl;
        h[@intFromEnum(Opcode.SHR)] = &BitwiseHandlers.shr;
        h[@intFromEnum(Opcode.SAR)] = &BitwiseHandlers.sar;
    }
    
    // Constantinople+ opcodes (EIP-1014: CREATE2)
    if (config.eips.has_create2()) {
        h[@intFromEnum(Opcode.CREATE2)] = &SystemHandlers.create2;
    }
    
    // Shanghai+ opcodes (EIP-3855: PUSH0)
    if (config.eips.has_push0()) {
        h[@intFromEnum(Opcode.PUSH0)] = &StackHandlers.push0;
    }
    
    // London+ opcodes (EIP-3198: BASEFEE)
    if (config.eips.has_basefee()) {
        h[@intFromEnum(Opcode.BASEFEE)] = &ContextHandlers.basefee;
    }
    
    // Cancun+ opcodes (EIP-1153: Transient storage)
    if (config.eips.has_transient_storage()) {
        h[@intFromEnum(Opcode.TLOAD)] = &StorageHandlers.tload;
        h[@intFromEnum(Opcode.TSTORE)] = &StorageHandlers.tstore;
    }
    
    // Cancun+ opcodes (EIP-5656: MCOPY)
    if (config.eips.has_mcopy()) {
        h[@intFromEnum(Opcode.MCOPY)] = &MemoryHandlers.mcopy;
    }
    
    // Cancun+ opcodes (EIP-4844: Blob transactions)
    if (config.eips.has_blobhash()) {
        h[@intFromEnum(Opcode.BLOBHASH)] = &ContextHandlers.blobhash;
        h[@intFromEnum(Opcode.BLOBBASEFEE)] = &ContextHandlers.blobbasefee;
    }
    
    // Always available context opcodes
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
    
    // Memory opcodes (always available)
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
    h[@intFromEnum(Opcode.GAS)] = &ContextHandlers.gas;
    h[@intFromEnum(Opcode.JUMPDEST)] = &JumpHandlers.jumpdest;
    
    // PUSH opcodes (always available)
    h[@intFromEnum(Opcode.PUSH1)] = &StackHandlers.push1;
    h[@intFromEnum(Opcode.PUSH2)] = &StackHandlers.push2;
    h[@intFromEnum(Opcode.PUSH3)] = &StackHandlers.push3;
    h[@intFromEnum(Opcode.PUSH4)] = &StackHandlers.push4;
    h[@intFromEnum(Opcode.PUSH5)] = &StackHandlers.push5;
    h[@intFromEnum(Opcode.PUSH6)] = &StackHandlers.push6;
    h[@intFromEnum(Opcode.PUSH7)] = &StackHandlers.push7;
    h[@intFromEnum(Opcode.PUSH8)] = &StackHandlers.push8;
    h[@intFromEnum(Opcode.PUSH9)] = &StackHandlers.push9;
    h[@intFromEnum(Opcode.PUSH10)] = &StackHandlers.push10;
    h[@intFromEnum(Opcode.PUSH11)] = &StackHandlers.push11;
    h[@intFromEnum(Opcode.PUSH12)] = &StackHandlers.push12;
    h[@intFromEnum(Opcode.PUSH13)] = &StackHandlers.push13;
    h[@intFromEnum(Opcode.PUSH14)] = &StackHandlers.push14;
    h[@intFromEnum(Opcode.PUSH15)] = &StackHandlers.push15;
    h[@intFromEnum(Opcode.PUSH16)] = &StackHandlers.push16;
    h[@intFromEnum(Opcode.PUSH17)] = &StackHandlers.push17;
    h[@intFromEnum(Opcode.PUSH18)] = &StackHandlers.push18;
    h[@intFromEnum(Opcode.PUSH19)] = &StackHandlers.push19;
    h[@intFromEnum(Opcode.PUSH20)] = &StackHandlers.push20;
    h[@intFromEnum(Opcode.PUSH21)] = &StackHandlers.push21;
    h[@intFromEnum(Opcode.PUSH22)] = &StackHandlers.push22;
    h[@intFromEnum(Opcode.PUSH23)] = &StackHandlers.push23;
    h[@intFromEnum(Opcode.PUSH24)] = &StackHandlers.push24;
    h[@intFromEnum(Opcode.PUSH25)] = &StackHandlers.push25;
    h[@intFromEnum(Opcode.PUSH26)] = &StackHandlers.push26;
    h[@intFromEnum(Opcode.PUSH27)] = &StackHandlers.push27;
    h[@intFromEnum(Opcode.PUSH28)] = &StackHandlers.push28;
    h[@intFromEnum(Opcode.PUSH29)] = &StackHandlers.push29;
    h[@intFromEnum(Opcode.PUSH30)] = &StackHandlers.push30;
    h[@intFromEnum(Opcode.PUSH31)] = &StackHandlers.push31;
    h[@intFromEnum(Opcode.PUSH32)] = &StackHandlers.push32;
    
    // DUP and SWAP opcodes (always available)
    h[@intFromEnum(Opcode.DUP1)] = &StackHandlers.dup1;
    h[@intFromEnum(Opcode.DUP2)] = &StackHandlers.dup2;
    h[@intFromEnum(Opcode.DUP3)] = &StackHandlers.dup3;
    h[@intFromEnum(Opcode.DUP4)] = &StackHandlers.dup4;
    h[@intFromEnum(Opcode.DUP5)] = &StackHandlers.dup5;
    h[@intFromEnum(Opcode.DUP6)] = &StackHandlers.dup6;
    h[@intFromEnum(Opcode.DUP7)] = &StackHandlers.dup7;
    h[@intFromEnum(Opcode.DUP8)] = &StackHandlers.dup8;
    h[@intFromEnum(Opcode.DUP9)] = &StackHandlers.dup9;
    h[@intFromEnum(Opcode.DUP10)] = &StackHandlers.dup10;
    h[@intFromEnum(Opcode.DUP11)] = &StackHandlers.dup11;
    h[@intFromEnum(Opcode.DUP12)] = &StackHandlers.dup12;
    h[@intFromEnum(Opcode.DUP13)] = &StackHandlers.dup13;
    h[@intFromEnum(Opcode.DUP14)] = &StackHandlers.dup14;
    h[@intFromEnum(Opcode.DUP15)] = &StackHandlers.dup15;
    h[@intFromEnum(Opcode.DUP16)] = &StackHandlers.dup16;
    h[@intFromEnum(Opcode.SWAP1)] = &StackHandlers.swap1;
    h[@intFromEnum(Opcode.SWAP2)] = &StackHandlers.swap2;
    h[@intFromEnum(Opcode.SWAP3)] = &StackHandlers.swap3;
    h[@intFromEnum(Opcode.SWAP4)] = &StackHandlers.swap4;
    h[@intFromEnum(Opcode.SWAP5)] = &StackHandlers.swap5;
    h[@intFromEnum(Opcode.SWAP6)] = &StackHandlers.swap6;
    h[@intFromEnum(Opcode.SWAP7)] = &StackHandlers.swap7;
    h[@intFromEnum(Opcode.SWAP8)] = &StackHandlers.swap8;
    h[@intFromEnum(Opcode.SWAP9)] = &StackHandlers.swap9;
    h[@intFromEnum(Opcode.SWAP10)] = &StackHandlers.swap10;
    h[@intFromEnum(Opcode.SWAP11)] = &StackHandlers.swap11;
    h[@intFromEnum(Opcode.SWAP12)] = &StackHandlers.swap12;
    h[@intFromEnum(Opcode.SWAP13)] = &StackHandlers.swap13;
    h[@intFromEnum(Opcode.SWAP14)] = &StackHandlers.swap14;
    h[@intFromEnum(Opcode.SWAP15)] = &StackHandlers.swap15;
    h[@intFromEnum(Opcode.SWAP16)] = &StackHandlers.swap16;

    // Keccak (always available)
    h[@intFromEnum(Opcode.KECCAK256)] = &KeccakHandlers.keccak;

    // Logging opcodes (conditional based on has_logs)
    if (config.eips.has_logs()) {
        h[@intFromEnum(Opcode.LOG0)] = &LogHandlers.log0;
        h[@intFromEnum(Opcode.LOG1)] = &LogHandlers.log1;
        h[@intFromEnum(Opcode.LOG2)] = &LogHandlers.log2;
        h[@intFromEnum(Opcode.LOG3)] = &LogHandlers.log3;
        h[@intFromEnum(Opcode.LOG4)] = &LogHandlers.log4;
    }

    // System opcodes
    h[@intFromEnum(Opcode.CREATE)] = &SystemHandlers.create;
    h[@intFromEnum(Opcode.CALL)] = &SystemHandlers.call;
    h[@intFromEnum(Opcode.CALLCODE)] = &SystemHandlers.callcode;
    h[@intFromEnum(Opcode.RETURN)] = &SystemHandlers.@"return";
    h[@intFromEnum(Opcode.DELEGATECALL)] = &SystemHandlers.delegatecall;
    h[@intFromEnum(Opcode.STATICCALL)] = &SystemHandlers.staticcall;
    h[@intFromEnum(Opcode.REVERT)] = &SystemHandlers.revert;
    h[@intFromEnum(Opcode.INVALID)] = &SystemHandlers.invalid;
    
    // SELFDESTRUCT (always available but behavior changes)
    if (config.eips.has_selfdestruct()) {
        h[@intFromEnum(Opcode.SELFDESTRUCT)] = &SystemHandlers.selfdestruct;
    }

    return h;
}

// =============================================================================
// Tests demonstrating conditional opcode handler compilation
// =============================================================================

const testing = std.testing;
const Eips = @import("eips.zig").Eips;
const Hardfork = @import("hardfork.zig").Hardfork;

// Mock FrameType for testing
const MockFrame = struct {
    const Self = @This();
    
    pub const Error = error{
        OutOfGas,
        StackUnderflow,
        StackOverflow,
        InvalidJumpDestination,
        InvalidOpcode,
        InvalidMemoryAccess,
    };
    
    pub const OpcodeHandler = *const fn (frame: *Self, cursor: [*]const MockDispatchItem) Error!noreturn;
    
    pub const Dispatch = struct {
        pub const Item = MockDispatchItem;
    };
    
    gas_remaining: u64 = 21000,
};

const MockDispatchItem = union(enum) {
    handler: MockFrame.OpcodeHandler,
    metadata: u64,
};

test "conditional opcode handlers - basic compilation for different hardforks" {
    // Test different hardfork configurations
    const FrontierConfig = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const ByzantiumConfig = EvmConfig{ .eips = Eips{ .hardfork = .BYZANTIUM } };
    const ShanghaiConfig = EvmConfig{ .eips = Eips{ .hardfork = .SHANGHAI } };
    const CancunConfig = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    // Each creates a different handler array with different opcodes enabled
    const frontier_handlers = getConditionalOpcodeHandlers(MockFrame, FrontierConfig);
    const byzantium_handlers = getConditionalOpcodeHandlers(MockFrame, ByzantiumConfig);
    const shanghai_handlers = getConditionalOpcodeHandlers(MockFrame, ShanghaiConfig);
    const cancun_handlers = getConditionalOpcodeHandlers(MockFrame, CancunConfig);
    
    // Basic arithmetic should be available in all hardforks
    try testing.expect(frontier_handlers[@intFromEnum(Opcode.ADD)] != frontier_handlers[@intFromEnum(Opcode.INVALID)]);
    try testing.expect(byzantium_handlers[@intFromEnum(Opcode.ADD)] != byzantium_handlers[@intFromEnum(Opcode.INVALID)]);
    try testing.expect(shanghai_handlers[@intFromEnum(Opcode.ADD)] != shanghai_handlers[@intFromEnum(Opcode.INVALID)]);
    try testing.expect(cancun_handlers[@intFromEnum(Opcode.ADD)] != cancun_handlers[@intFromEnum(Opcode.INVALID)]);
    
    // All handlers should be valid (non-null) function pointers
    try testing.expect(@intFromPtr(frontier_handlers[@intFromEnum(Opcode.ADD)]) != 0);
    try testing.expect(@intFromPtr(byzantium_handlers[@intFromEnum(Opcode.ADD)]) != 0);
    try testing.expect(@intFromPtr(shanghai_handlers[@intFromEnum(Opcode.ADD)]) != 0);
    try testing.expect(@intFromPtr(cancun_handlers[@intFromEnum(Opcode.ADD)]) != 0);
}

test "conditional opcode handlers - feature-specific opcodes" {
    const FrontierConfig = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const ByzantiumConfig = EvmConfig{ .eips = Eips{ .hardfork = .BYZANTIUM } };
    const ShanghaiConfig = EvmConfig{ .eips = Eips{ .hardfork = .SHANGHAI } };
    const CancunConfig = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    const frontier_handlers = getConditionalOpcodeHandlers(MockFrame, FrontierConfig);
    const byzantium_handlers = getConditionalOpcodeHandlers(MockFrame, ByzantiumConfig);
    const shanghai_handlers = getConditionalOpcodeHandlers(MockFrame, ShanghaiConfig);
    const cancun_handlers = getConditionalOpcodeHandlers(MockFrame, CancunConfig);
    
    const invalid_handler = frontier_handlers[@intFromEnum(Opcode.INVALID)];
    
    // SHL should be invalid in Frontier but valid in Byzantium+
    try testing.expect(frontier_handlers[@intFromEnum(Opcode.SHL)] == invalid_handler);
    try testing.expect(byzantium_handlers[@intFromEnum(Opcode.SHL)] != invalid_handler);
    try testing.expect(shanghai_handlers[@intFromEnum(Opcode.SHL)] != invalid_handler);
    try testing.expect(cancun_handlers[@intFromEnum(Opcode.SHL)] != invalid_handler);
    
    // PUSH0 should be invalid before Shanghai
    try testing.expect(frontier_handlers[@intFromEnum(Opcode.PUSH0)] == invalid_handler);
    try testing.expect(byzantium_handlers[@intFromEnum(Opcode.PUSH0)] == invalid_handler);
    try testing.expect(shanghai_handlers[@intFromEnum(Opcode.PUSH0)] != invalid_handler);
    try testing.expect(cancun_handlers[@intFromEnum(Opcode.PUSH0)] != invalid_handler);
    
    // TLOAD should be invalid before Cancun
    try testing.expect(frontier_handlers[@intFromEnum(Opcode.TLOAD)] == invalid_handler);
    try testing.expect(byzantium_handlers[@intFromEnum(Opcode.TLOAD)] == invalid_handler);
    try testing.expect(shanghai_handlers[@intFromEnum(Opcode.TLOAD)] == invalid_handler);
    try testing.expect(cancun_handlers[@intFromEnum(Opcode.TLOAD)] != invalid_handler);
    
    // TSTORE should be invalid before Cancun
    try testing.expect(frontier_handlers[@intFromEnum(Opcode.TSTORE)] == invalid_handler);
    try testing.expect(byzantium_handlers[@intFromEnum(Opcode.TSTORE)] == invalid_handler);
    try testing.expect(shanghai_handlers[@intFromEnum(Opcode.TSTORE)] == invalid_handler);
    try testing.expect(cancun_handlers[@intFromEnum(Opcode.TSTORE)] != invalid_handler);
}

test "conditional opcode handlers - always available opcodes" {
    const FrontierConfig = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const CancunConfig = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    const frontier_handlers = getConditionalOpcodeHandlers(MockFrame, FrontierConfig);
    const cancun_handlers = getConditionalOpcodeHandlers(MockFrame, CancunConfig);
    
    const invalid_handler = frontier_handlers[@intFromEnum(Opcode.INVALID)];
    
    // Core opcodes should always be available
    const always_available = [_]Opcode{
        .STOP, .ADD, .MUL, .SUB, .DIV, .SDIV, .MOD, .SMOD, 
        .ADDMOD, .MULMOD, .EXP, .SIGNEXTEND,
        .LT, .GT, .SLT, .SGT, .EQ, .ISZERO,
        .AND, .OR, .XOR, .NOT, .BYTE,
        .KECCAK256, .ADDRESS, .BALANCE, .ORIGIN, .CALLER,
        .POP, .MLOAD, .MSTORE, .MSTORE8, .SLOAD, .SSTORE,
        .JUMP, .JUMPI, .PC, .MSIZE, .GAS, .JUMPDEST,
        .PUSH1, .PUSH2, .PUSH32, .DUP1, .DUP16, .SWAP1, .SWAP16,
        .CREATE, .CALL, .RETURN, .SELFDESTRUCT,
    };
    
    for (always_available) |opcode| {
        try testing.expect(frontier_handlers[@intFromEnum(opcode)] != invalid_handler);
        try testing.expect(cancun_handlers[@intFromEnum(opcode)] != invalid_handler);
        
        // Should be the same handler in both configurations for always-available opcodes
        // (except for SELFDESTRUCT which might have different behavior)
        if (opcode != .SELFDESTRUCT) {
            try testing.expect(frontier_handlers[@intFromEnum(opcode)] == cancun_handlers[@intFromEnum(opcode)]);
        }
    }
}

test "conditional opcode handlers - logs availability" {
    const FrontierConfig = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    
    const handlers = getConditionalOpcodeHandlers(MockFrame, FrontierConfig);
    const invalid_handler = handlers[@intFromEnum(Opcode.INVALID)];
    
    // Logs should be available since Frontier (has_logs() returns true)
    try testing.expect(FrontierConfig.eips.has_logs());
    try testing.expect(handlers[@intFromEnum(Opcode.LOG0)] != invalid_handler);
    try testing.expect(handlers[@intFromEnum(Opcode.LOG1)] != invalid_handler);
    try testing.expect(handlers[@intFromEnum(Opcode.LOG2)] != invalid_handler);
    try testing.expect(handlers[@intFromEnum(Opcode.LOG3)] != invalid_handler);
    try testing.expect(handlers[@intFromEnum(Opcode.LOG4)] != invalid_handler);
}

test "conditional opcode handlers - comprehensive hardfork progression" {
    const hardforks = [_]struct { config: EvmConfig, name: []const u8 }{
        .{ .config = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } }, .name = "FRONTIER" },
        .{ .config = EvmConfig{ .eips = Eips{ .hardfork = .BYZANTIUM } }, .name = "BYZANTIUM" },
        .{ .config = EvmConfig{ .eips = Eips{ .hardfork = .CONSTANTINOPLE } }, .name = "CONSTANTINOPLE" },
        .{ .config = EvmConfig{ .eips = Eips{ .hardfork = .SHANGHAI } }, .name = "SHANGHAI" },
        .{ .config = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } }, .name = "CANCUN" },
    };
    
    for (hardforks) |hf| {
        const handlers = getConditionalOpcodeHandlers(MockFrame, hf.config);
        const invalid_handler = handlers[@intFromEnum(Opcode.INVALID)];
        
        // Test that feature availability matches hardfork progression
        
        // Byzantium features (bitwise shifting)
        if (hf.config.eips.hardfork.isAtLeast(.BYZANTIUM)) {
            try testing.expect(handlers[@intFromEnum(Opcode.SHL)] != invalid_handler);
            try testing.expect(handlers[@intFromEnum(Opcode.SHR)] != invalid_handler);
            try testing.expect(handlers[@intFromEnum(Opcode.SAR)] != invalid_handler);
        } else {
            try testing.expect(handlers[@intFromEnum(Opcode.SHL)] == invalid_handler);
            try testing.expect(handlers[@intFromEnum(Opcode.SHR)] == invalid_handler);
            try testing.expect(handlers[@intFromEnum(Opcode.SAR)] == invalid_handler);
        }
        
        // Constantinople features (CREATE2)
        if (hf.config.eips.has_create2()) {
            try testing.expect(handlers[@intFromEnum(Opcode.CREATE2)] != invalid_handler);
        } else {
            try testing.expect(handlers[@intFromEnum(Opcode.CREATE2)] == invalid_handler);
        }
        
        // Shanghai features (PUSH0)
        if (hf.config.eips.has_push0()) {
            try testing.expect(handlers[@intFromEnum(Opcode.PUSH0)] != invalid_handler);
        } else {
            try testing.expect(handlers[@intFromEnum(Opcode.PUSH0)] == invalid_handler);
        }
        
        // Cancun features (transient storage, MCOPY)
        if (hf.config.eips.has_transient_storage()) {
            try testing.expect(handlers[@intFromEnum(Opcode.TLOAD)] != invalid_handler);
            try testing.expect(handlers[@intFromEnum(Opcode.TSTORE)] != invalid_handler);
        } else {
            try testing.expect(handlers[@intFromEnum(Opcode.TLOAD)] == invalid_handler);
            try testing.expect(handlers[@intFromEnum(Opcode.TSTORE)] == invalid_handler);
        }
        
        if (hf.config.eips.has_mcopy()) {
            try testing.expect(handlers[@intFromEnum(Opcode.MCOPY)] != invalid_handler);
        } else {
            try testing.expect(handlers[@intFromEnum(Opcode.MCOPY)] == invalid_handler);
        }
    }
}

test "conditional opcode handlers - dead code elimination verification" {
    // This test verifies that disabled opcodes truly become dead code
    const FrontierConfig = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const CancunConfig = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    const frontier_handlers = getConditionalOpcodeHandlers(MockFrame, FrontierConfig);
    const cancun_handlers = getConditionalOpcodeHandlers(MockFrame, CancunConfig);
    
    const invalid_handler = frontier_handlers[@intFromEnum(Opcode.INVALID)];
    
    // Disabled opcodes should point to invalid handler
    try testing.expect(frontier_handlers[@intFromEnum(Opcode.PUSH0)] == invalid_handler);
    try testing.expect(frontier_handlers[@intFromEnum(Opcode.TLOAD)] == invalid_handler);
    try testing.expect(frontier_handlers[@intFromEnum(Opcode.TSTORE)] == invalid_handler);
    try testing.expect(frontier_handlers[@intFromEnum(Opcode.MCOPY)] == invalid_handler);
    
    // Enabled opcodes should point to actual handlers  
    try testing.expect(cancun_handlers[@intFromEnum(Opcode.PUSH0)] != invalid_handler);
    try testing.expect(cancun_handlers[@intFromEnum(Opcode.TLOAD)] != invalid_handler);
    try testing.expect(cancun_handlers[@intFromEnum(Opcode.TSTORE)] != invalid_handler);
    try testing.expect(cancun_handlers[@intFromEnum(Opcode.MCOPY)] != invalid_handler);
    
    // All handlers should have valid addresses (not null)
    for (frontier_handlers) |handler| {
        try testing.expect(@intFromPtr(handler) != 0);
    }
    
    for (cancun_handlers) |handler| {
        try testing.expect(@intFromPtr(handler) != 0);
    }
}