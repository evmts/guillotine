const std = @import("std");
const execution = @import("../execution/package.zig");
const adapter = @import("../execution/adapter.zig");
const ExecutionError = @import("../execution/execution_error.zig");
const Frame = @import("../stack_frame.zig").StackFrame;

// Anyopaque thunk wrappers for adapter.call_op
fn wrap_ctx(comptime OpFn: *const fn (*Frame) ExecutionError.Error!void) operation_module.ExecutionFunc {
    return struct {
        pub fn f(ctx: *anyopaque) ExecutionError.Error!void {
            return adapter.call_ctx(OpFn, ctx);
        }
    }.f;
}

fn wrap_any(comptime OpFn: *const fn (*anyopaque) ExecutionError.Error!void) operation_module.ExecutionFunc {
    return struct {
        pub fn f(ctx: *anyopaque) ExecutionError.Error!void {
            return adapter.call_any(OpFn, ctx);
        }
    }.f;
}
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
const Stack = @import("../stack/stack.zig");
const operation_module = @import("../opcodes/operation.zig");
const Operation = operation_module.Operation;
const Hardfork = @import("../hardforks/hardfork.zig").Hardfork;

/// Specification for an EVM operation.
/// This data structure allows us to define all operations in a single place
/// and generate the Operation structs at compile time.
pub const OpSpec = struct {
    /// Operation name (e.g., "ADD", "MUL")
    name: []const u8,
    /// Opcode byte value (0x00-0xFF)
    opcode: u8,
    /// Execution function
    execute: operation_module.ExecutionFunc,
    /// Base gas cost
    gas: u64,
    /// Minimum stack items required
    min_stack: u32,
    /// Maximum stack size allowed (usually Stack.CAPACITY or Stack.CAPACITY - 1)
    max_stack: u32,
    /// Optional: for hardfork variants, specify which variant this is
    variant: ?Hardfork = null,
};

/// Complete specification of all EVM operations.
/// This replaces the scattered Operation definitions across multiple files.
/// Operations are ordered by opcode for clarity and maintainability.
pub const ALL_OPERATIONS = [_]OpSpec{
    // 0x00s: Stop and Arithmetic Operations
    .{ .name = "STOP", .opcode = 0x00, .execute = wrap_ctx(execution.control.op_stop), .gas = 0, .min_stack = 0, .max_stack = Stack.CAPACITY },
    .{ .name = "ADD", .opcode = 0x01, .execute = wrap_ctx(execution.arithmetic.op_add), .gas = GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "MUL", .opcode = 0x02, .execute = wrap_ctx(execution.arithmetic.op_mul), .gas = GasConstants.GasFastStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "SUB", .opcode = 0x03, .execute = wrap_ctx(execution.arithmetic.op_sub), .gas = GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "DIV", .opcode = 0x04, .execute = wrap_ctx(execution.arithmetic.op_div), .gas = GasConstants.GasFastStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "SDIV", .opcode = 0x05, .execute = wrap_ctx(execution.arithmetic.op_sdiv), .gas = GasConstants.GasFastStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "MOD", .opcode = 0x06, .execute = wrap_ctx(execution.arithmetic.op_mod), .gas = GasConstants.GasFastStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "SMOD", .opcode = 0x07, .execute = wrap_ctx(execution.arithmetic.op_smod), .gas = GasConstants.GasFastStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "ADDMOD", .opcode = 0x08, .execute = wrap_ctx(execution.arithmetic.op_addmod), .gas = GasConstants.GasMidStep, .min_stack = 3, .max_stack = Stack.CAPACITY },
    .{ .name = "MULMOD", .opcode = 0x09, .execute = wrap_ctx(execution.arithmetic.op_mulmod), .gas = GasConstants.GasMidStep, .min_stack = 3, .max_stack = Stack.CAPACITY },
    .{ .name = "EXP", .opcode = 0x0a, .execute = wrap_ctx(execution.arithmetic.op_exp), .gas = 10, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "SIGNEXTEND", .opcode = 0x0b, .execute = wrap_ctx(execution.arithmetic.op_signextend), .gas = GasConstants.GasFastStep, .min_stack = 2, .max_stack = Stack.CAPACITY },

    // 0x10s: Comparison & Bitwise Logic Operations
    .{ .name = "LT", .opcode = 0x10, .execute = wrap_ctx(execution.comparison.op_lt), .gas = GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "GT", .opcode = 0x11, .execute = wrap_ctx(execution.comparison.op_gt), .gas = GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "SLT", .opcode = 0x12, .execute = wrap_ctx(execution.comparison.op_slt), .gas = GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "SGT", .opcode = 0x13, .execute = wrap_ctx(execution.comparison.op_sgt), .gas = GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "EQ", .opcode = 0x14, .execute = wrap_ctx(execution.comparison.op_eq), .gas = GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "ISZERO", .opcode = 0x15, .execute = wrap_ctx(execution.comparison.op_iszero), .gas = GasConstants.GasFastestStep, .min_stack = 1, .max_stack = Stack.CAPACITY },
    .{ .name = "AND", .opcode = 0x16, .execute = wrap_ctx(execution.bitwise.op_and), .gas = GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "OR", .opcode = 0x17, .execute = wrap_ctx(execution.bitwise.op_or), .gas = GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "XOR", .opcode = 0x18, .execute = wrap_ctx(execution.bitwise.op_xor), .gas = GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "NOT", .opcode = 0x19, .execute = wrap_ctx(execution.bitwise.op_not), .gas = GasConstants.GasFastestStep, .min_stack = 1, .max_stack = Stack.CAPACITY },
    .{ .name = "BYTE", .opcode = 0x1a, .execute = wrap_ctx(execution.bitwise.op_byte), .gas = GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "SHL", .opcode = 0x1b, .execute = wrap_ctx(execution.bitwise.op_shl), .gas = GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY, .variant = .CONSTANTINOPLE },
    .{ .name = "SHR", .opcode = 0x1c, .execute = wrap_ctx(execution.bitwise.op_shr), .gas = GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY, .variant = .CONSTANTINOPLE },
    .{ .name = "SAR", .opcode = 0x1d, .execute = wrap_ctx(execution.bitwise.op_sar), .gas = GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY, .variant = .CONSTANTINOPLE },

    // 0x20s: Crypto
    .{ .name = "SHA3", .opcode = 0x20, .execute = wrap_ctx(execution.crypto.op_sha3), .gas = GasConstants.Keccak256Gas, .min_stack = 2, .max_stack = Stack.CAPACITY },

    // 0x30s: Environmental Information
    .{ .name = "ADDRESS", .opcode = 0x30, .execute = wrap_ctx(execution.environment.op_address), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
    .{ .name = "BALANCE_FRONTIER", .opcode = 0x31, .execute = wrap_ctx(execution.environment.op_balance), .gas = 20, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .FRONTIER },
    .{ .name = "BALANCE_TANGERINE", .opcode = 0x31, .execute = wrap_ctx(execution.environment.op_balance), .gas = 400, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .TANGERINE_WHISTLE },
    .{ .name = "BALANCE_ISTANBUL", .opcode = 0x31, .execute = wrap_ctx(execution.environment.op_balance), .gas = 700, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .ISTANBUL },
    .{ .name = "BALANCE_BERLIN", .opcode = 0x31, .execute = wrap_ctx(execution.environment.op_balance), .gas = 0, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .BERLIN },
    .{ .name = "ORIGIN", .opcode = 0x32, .execute = wrap_ctx(execution.environment.op_origin), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
    .{ .name = "CALLER", .opcode = 0x33, .execute = wrap_ctx(execution.environment.op_caller), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
    .{ .name = "CALLVALUE", .opcode = 0x34, .execute = wrap_ctx(execution.environment.op_callvalue), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
    .{ .name = "CALLDATALOAD", .opcode = 0x35, .execute = wrap_ctx(execution.environment.op_calldataload), .gas = GasConstants.GasFastestStep, .min_stack = 1, .max_stack = Stack.CAPACITY },
    .{ .name = "CALLDATASIZE", .opcode = 0x36, .execute = wrap_ctx(execution.environment.op_calldatasize), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
    .{ .name = "CODESIZE", .opcode = 0x38, .execute = wrap_ctx(execution.environment.op_codesize), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
    .{ .name = "CODECOPY", .opcode = 0x39, .execute = wrap_ctx(execution.environment.op_codecopy), .gas = GasConstants.GasFastestStep, .min_stack = 3, .max_stack = Stack.CAPACITY },
    .{ .name = "GASPRICE", .opcode = 0x3a, .execute = wrap_ctx(execution.environment.op_gasprice), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
    .{ .name = "EXTCODESIZE_FRONTIER", .opcode = 0x3b, .execute = wrap_ctx(execution.environment.op_extcodesize), .gas = 20, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .FRONTIER },
    .{ .name = "EXTCODESIZE_TANGERINE", .opcode = 0x3b, .execute = wrap_ctx(execution.environment.op_extcodesize), .gas = 700, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .TANGERINE_WHISTLE },
    .{ .name = "EXTCODESIZE_ISTANBUL", .opcode = 0x3b, .execute = wrap_ctx(execution.environment.op_extcodesize), .gas = 700, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .ISTANBUL },
    .{ .name = "EXTCODESIZE", .opcode = 0x3b, .execute = wrap_ctx(execution.environment.op_extcodesize), .gas = 0, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .BERLIN },
    .{ .name = "EXTCODECOPY_FRONTIER", .opcode = 0x3c, .execute = wrap_ctx(execution.environment.op_extcodecopy), .gas = 20, .min_stack = 4, .max_stack = Stack.CAPACITY, .variant = .FRONTIER },
    .{ .name = "EXTCODECOPY_TANGERINE", .opcode = 0x3c, .execute = wrap_ctx(execution.environment.op_extcodecopy), .gas = 700, .min_stack = 4, .max_stack = Stack.CAPACITY, .variant = .TANGERINE_WHISTLE },
    .{ .name = "EXTCODECOPY_ISTANBUL", .opcode = 0x3c, .execute = wrap_ctx(execution.environment.op_extcodecopy), .gas = 700, .min_stack = 4, .max_stack = Stack.CAPACITY, .variant = .ISTANBUL },
    .{ .name = "EXTCODECOPY", .opcode = 0x3c, .execute = wrap_ctx(execution.environment.op_extcodecopy), .gas = 0, .min_stack = 4, .max_stack = Stack.CAPACITY, .variant = .BERLIN },
    .{ .name = "RETURNDATASIZE", .opcode = 0x3d, .execute = wrap_ctx(adapter.op_returndatasize_adapter), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1, .variant = .BYZANTIUM },
    .{ .name = "RETURNDATACOPY", .opcode = 0x3e, .execute = wrap_ctx(adapter.op_returndatacopy_adapter), .gas = GasConstants.GasFastestStep, .min_stack = 3, .max_stack = Stack.CAPACITY, .variant = .BYZANTIUM },
    .{ .name = "EXTCODEHASH", .opcode = 0x3f, .execute = wrap_ctx(execution.environment.op_extcodehash), .gas = 0, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .CONSTANTINOPLE },

    // 0x40s: Block Information
    .{ .name = "BLOCKHASH", .opcode = 0x40, .execute = wrap_ctx(execution.block.op_blockhash), .gas = 20, .min_stack = 1, .max_stack = Stack.CAPACITY },
    .{ .name = "COINBASE", .opcode = 0x41, .execute = wrap_ctx(execution.block.op_coinbase), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
    .{ .name = "TIMESTAMP", .opcode = 0x42, .execute = wrap_ctx(execution.block.op_timestamp), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
    .{ .name = "NUMBER", .opcode = 0x43, .execute = wrap_ctx(execution.block.op_number), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
    .{ .name = "DIFFICULTY", .opcode = 0x44, .execute = wrap_ctx(execution.block.op_difficulty), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
    .{ .name = "GASLIMIT", .opcode = 0x45, .execute = wrap_ctx(execution.block.op_gaslimit), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
    .{ .name = "CHAINID", .opcode = 0x46, .execute = wrap_ctx(execution.environment.op_chainid), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1, .variant = .ISTANBUL },
    .{ .name = "SELFBALANCE", .opcode = 0x47, .execute = wrap_ctx(execution.environment.op_selfbalance), .gas = GasConstants.GasFastStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1, .variant = .ISTANBUL },
    .{ .name = "BASEFEE", .opcode = 0x48, .execute = wrap_ctx(execution.block.op_basefee), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1, .variant = .LONDON },
    .{ .name = "BLOBHASH", .opcode = 0x49, .execute = wrap_ctx(execution.block.op_blobhash), .gas = GasConstants.BlobHashGas, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .CANCUN },
    .{ .name = "BLOBBASEFEE", .opcode = 0x4a, .execute = wrap_ctx(execution.block.op_blobbasefee), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1, .variant = .CANCUN },

    // 0x50s: Stack, Memory, Storage and Flow Operations
    .{ .name = "POP", .opcode = 0x50, .execute = wrap_ctx(execution.stack.op_pop), .gas = GasConstants.GasQuickStep, .min_stack = 1, .max_stack = Stack.CAPACITY },
    .{ .name = "MLOAD", .opcode = 0x51, .execute = wrap_ctx(execution.memory.op_mload), .gas = GasConstants.GasFastestStep, .min_stack = 1, .max_stack = Stack.CAPACITY },
    .{ .name = "MSTORE", .opcode = 0x52, .execute = wrap_ctx(execution.memory.op_mstore), .gas = GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "MSTORE8", .opcode = 0x53, .execute = wrap_ctx(execution.memory.op_mstore8), .gas = GasConstants.GasFastestStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "SLOAD_FRONTIER", .opcode = 0x54, .execute = wrap_ctx(execution.storage.op_sload), .gas = 50, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .FRONTIER },
    .{ .name = "SLOAD_TANGERINE", .opcode = 0x54, .execute = wrap_ctx(execution.storage.op_sload), .gas = 200, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .TANGERINE_WHISTLE },
    .{ .name = "SLOAD_ISTANBUL", .opcode = 0x54, .execute = wrap_ctx(execution.storage.op_sload), .gas = 800, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .ISTANBUL },
    .{ .name = "SLOAD", .opcode = 0x54, .execute = wrap_ctx(execution.storage.op_sload), .gas = 0, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .BERLIN },
    .{ .name = "SSTORE", .opcode = 0x55, .execute = wrap_ctx(execution.storage.op_sstore), .gas = 0, .min_stack = 2, .max_stack = Stack.CAPACITY },
    // JUMP and JUMPI execute functions are not used; interpreter handles them inline.
    // Use a Noop to carry metadata; gas and stack requirements remain for block validation.
    .{ .name = "JUMP", .opcode = 0x56, .execute = wrap_ctx(execution.null_opcode.op_invalid), .gas = GasConstants.GasMidStep, .min_stack = 1, .max_stack = Stack.CAPACITY },
    .{ .name = "JUMPI", .opcode = 0x57, .execute = wrap_ctx(execution.null_opcode.op_invalid), .gas = GasConstants.GasSlowStep, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "PC", .opcode = 0x58, .execute = wrap_ctx(execution.control.op_pc), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
    .{ .name = "MSIZE", .opcode = 0x59, .execute = wrap_ctx(execution.memory.op_msize), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
    .{ .name = "GAS", .opcode = 0x5a, .execute = wrap_ctx(execution.system.gas_op), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1 },
    .{ .name = "JUMPDEST", .opcode = 0x5b, .execute = wrap_ctx(execution.control.op_jumpdest), .gas = GasConstants.JumpdestGas, .min_stack = 0, .max_stack = Stack.CAPACITY },
    .{ .name = "TLOAD", .opcode = 0x5c, .execute = wrap_ctx(execution.storage.op_tload), .gas = GasConstants.WarmStorageReadCost, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .CANCUN },
    .{ .name = "TSTORE", .opcode = 0x5d, .execute = wrap_ctx(execution.storage.op_tstore), .gas = GasConstants.WarmStorageReadCost, .min_stack = 2, .max_stack = Stack.CAPACITY, .variant = .CANCUN },
    .{ .name = "MCOPY", .opcode = 0x5e, .execute = wrap_ctx(execution.memory.op_mcopy), .gas = GasConstants.GasFastestStep, .min_stack = 3, .max_stack = Stack.CAPACITY, .variant = .CANCUN },
    .{ .name = "PUSH0", .opcode = 0x5f, .execute = wrap_ctx(execution.null_opcode.op_invalid), .gas = GasConstants.GasQuickStep, .min_stack = 0, .max_stack = Stack.CAPACITY - 1, .variant = .SHANGHAI },

    // 0x60s & 0x70s: Push operations (generated dynamically in jump table)
    // 0x80s: Duplication operations (generated dynamically in jump table)
    // 0x90s: Exchange operations (generated dynamically in jump table)
    // 0xa0s: Logging operations (generated dynamically in jump table)

    // 0xf0s: System operations
    .{ .name = "CREATE", .opcode = 0xf0, .execute = wrap_ctx(execution.system.op_create), .gas = GasConstants.CreateGas, .min_stack = 3, .max_stack = Stack.CAPACITY - 1 },
    .{ .name = "CALL_FRONTIER", .opcode = 0xf1, .execute = wrap_ctx(execution.system.op_call), .gas = 40, .min_stack = 7, .max_stack = Stack.CAPACITY - 1, .variant = .FRONTIER },
    .{ .name = "CALL", .opcode = 0xf1, .execute = wrap_ctx(execution.system.op_call), .gas = 700, .min_stack = 7, .max_stack = Stack.CAPACITY - 1, .variant = .TANGERINE_WHISTLE },
    .{ .name = "CALLCODE_FRONTIER", .opcode = 0xf2, .execute = wrap_ctx(execution.system.op_callcode), .gas = 40, .min_stack = 7, .max_stack = Stack.CAPACITY - 1, .variant = .FRONTIER },
    .{ .name = "CALLCODE", .opcode = 0xf2, .execute = wrap_ctx(execution.system.op_callcode), .gas = 700, .min_stack = 7, .max_stack = Stack.CAPACITY - 1, .variant = .TANGERINE_WHISTLE },
    .{ .name = "RETURN", .opcode = 0xf3, .execute = wrap_ctx(execution.control.op_return), .gas = 0, .min_stack = 2, .max_stack = Stack.CAPACITY },
    .{ .name = "DELEGATECALL", .opcode = 0xf4, .execute = wrap_ctx(execution.system.op_delegatecall), .gas = 40, .min_stack = 6, .max_stack = Stack.CAPACITY - 1, .variant = .HOMESTEAD },
    .{ .name = "DELEGATECALL_TANGERINE", .opcode = 0xf4, .execute = wrap_ctx(execution.system.op_delegatecall), .gas = 700, .min_stack = 6, .max_stack = Stack.CAPACITY - 1, .variant = .TANGERINE_WHISTLE },
    .{ .name = "CREATE2", .opcode = 0xf5, .execute = wrap_ctx(execution.system.op_create2), .gas = GasConstants.CreateGas, .min_stack = 4, .max_stack = Stack.CAPACITY - 1, .variant = .CONSTANTINOPLE },
    .{ .name = "STATICCALL", .opcode = 0xfa, .execute = wrap_ctx(execution.system.op_staticcall), .gas = 700, .min_stack = 6, .max_stack = Stack.CAPACITY - 1, .variant = .BYZANTIUM },
    .{ .name = "REVERT", .opcode = 0xfd, .execute = wrap_ctx(execution.control.op_revert), .gas = 0, .min_stack = 2, .max_stack = Stack.CAPACITY, .variant = .BYZANTIUM },
    .{ .name = "INVALID", .opcode = 0xfe, .execute = wrap_ctx(execution.control.op_invalid), .gas = 0, .min_stack = 0, .max_stack = Stack.CAPACITY },
    .{ .name = "SELFDESTRUCT_FRONTIER", .opcode = 0xff, .execute = wrap_ctx(execution.control.op_selfdestruct_legacy), .gas = 0, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .FRONTIER },
    .{ .name = "SELFDESTRUCT_TANGERINE", .opcode = 0xff, .execute = wrap_ctx(execution.control.op_selfdestruct_legacy), .gas = 5000, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .TANGERINE_WHISTLE },
    .{ .name = "SELFDESTRUCT", .opcode = 0xff, .execute = wrap_ctx(execution.control.op_selfdestruct), .gas = 5000, .min_stack = 1, .max_stack = Stack.CAPACITY, .variant = .CANCUN },
};

/// Generate an Operation struct from an OpSpec.
pub fn generate_operation(spec: OpSpec) Operation {
    return Operation{
        .execute = spec.execute,
        .constant_gas = spec.gas,
        .min_stack = spec.min_stack,
        .max_stack = spec.max_stack,
    };
}
