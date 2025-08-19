const std = @import("std");
const builtin = @import("builtin");
const Opcode = @import("../opcodes/opcode.zig");
const operation_module = @import("../opcodes/operation.zig");
const Operation = operation_module.Operation;
const ExecutionFunc = @import("../execution_func.zig").ExecutionFunc;
const Hardfork = @import("../hardforks/hardfork.zig").Hardfork;
const ExecutionError = @import("../execution/execution_error.zig");
const Stack = @import("../stack/stack.zig");
const ExecutionContext = @import("../stack_frame.zig").StackFrame;
const primitives = @import("primitives");
const Log = @import("../log.zig");
const GasConstants = primitives.GasConstants;

// Export inline hot ops optimization
pub const execute_with_inline_hot_ops = @import("inline_hot_ops.zig").execute_with_inline_hot_ops;

const execution = @import("../execution/package.zig");
const stack_ops = execution.stack;
const log = execution.log;
const operation_config = @import("operation_config.zig");
const adapter = @import("../execution/adapter.zig");

// Local wrapper for opcodes that take Frame*
fn wrap_ctx(comptime OpFn: *const fn (*@import("../stack_frame.zig").StackFrame) ExecutionError.Error!void) ExecutionFunc {
    return struct {
        pub fn f(ctx: *anyopaque) ExecutionError.Error!void {
            return adapter.call_ctx(OpFn, ctx);
        }
    }.f;
}

/// EVM opcode metadata for efficient opcode dispatch.
///
/// The opcode metadata is a critical performance optimization that maps opcodes
/// to their execution handlers. Instead of using a switch statement with
/// 256 cases, the opcode metadata provides O(1) dispatch by indexing directly
/// into arrays of function pointers and jt.
///
/// ## Design Rationale
/// - Parallel arrays provide better cache locality than array-of-structs
/// - Hot data (execute functions, gas costs) are in contiguous memory
/// - Cache-line alignment improves memory access patterns
/// - Direct indexing eliminates branch prediction overhead
///
/// ## Memory Layout (Struct-of-Arrays)
/// - execute_funcs: 256 * 8 bytes = 2KB (hot path)
/// - constant_gas: 256 * 8 bytes = 2KB (hot path)
/// - min_stack: 256 * 4 bytes = 1KB (validation)
/// - max_stack: 256 * 4 bytes = 1KB (validation)
/// - dynamic_gas: 256 * 8 bytes = 2KB (cold path)
/// - memory_size: 256 * 8 bytes = 2KB (cold path)
/// - undefined_flags: 256 * 1 byte = 256 bytes (cold path)
/// Total: ~10.25KB with better cache utilization
///
/// Example:
/// ```zig
/// const table = OpcodeMetadata.init_from_hardfork(.CANCUN);
/// const opcode = bytecode[pc];
/// const operation = table.get_operation(opcode);
/// // Old execute method removed - see ExecutionContext pattern
/// ```
pub const OpcodeMetadata = @This();

/// CPU cache line size for optimal memory alignment.
/// Most modern x86/ARM processors use 64-byte cache lines.
const CACHE_LINE_SIZE = 64;

/// Stack consumption data for an opcode
const StackConsumption = struct {
    inputs: u32,  // How many items popped from stack
    outputs: u32, // How many items pushed to stack
};

/// Get stack consumption for a given opcode
fn get_stack_consumption(opcode: u8) StackConsumption {
    return switch (opcode) {
        // 0x00s: Stop and Arithmetic Operations
        0x00 => .{ .inputs = 0, .outputs = 0 }, // STOP
        0x01 => .{ .inputs = 2, .outputs = 1 }, // ADD
        0x02 => .{ .inputs = 2, .outputs = 1 }, // MUL
        0x03 => .{ .inputs = 2, .outputs = 1 }, // SUB
        0x04 => .{ .inputs = 2, .outputs = 1 }, // DIV
        0x05 => .{ .inputs = 2, .outputs = 1 }, // SDIV
        0x06 => .{ .inputs = 2, .outputs = 1 }, // MOD
        0x07 => .{ .inputs = 2, .outputs = 1 }, // SMOD
        0x08 => .{ .inputs = 3, .outputs = 1 }, // ADDMOD
        0x09 => .{ .inputs = 3, .outputs = 1 }, // MULMOD
        0x0a => .{ .inputs = 2, .outputs = 1 }, // EXP
        0x0b => .{ .inputs = 2, .outputs = 1 }, // SIGNEXTEND

        // 0x10s: Comparison & Bitwise Logic Operations
        0x10 => .{ .inputs = 2, .outputs = 1 }, // LT
        0x11 => .{ .inputs = 2, .outputs = 1 }, // GT
        0x12 => .{ .inputs = 2, .outputs = 1 }, // SLT
        0x13 => .{ .inputs = 2, .outputs = 1 }, // SGT
        0x14 => .{ .inputs = 2, .outputs = 1 }, // EQ
        0x15 => .{ .inputs = 1, .outputs = 1 }, // ISZERO
        0x16 => .{ .inputs = 2, .outputs = 1 }, // AND
        0x17 => .{ .inputs = 2, .outputs = 1 }, // OR
        0x18 => .{ .inputs = 2, .outputs = 1 }, // XOR
        0x19 => .{ .inputs = 1, .outputs = 1 }, // NOT
        0x1a => .{ .inputs = 2, .outputs = 1 }, // BYTE
        0x1b => .{ .inputs = 2, .outputs = 1 }, // SHL
        0x1c => .{ .inputs = 2, .outputs = 1 }, // SHR
        0x1d => .{ .inputs = 2, .outputs = 1 }, // SAR

        // 0x20s: Crypto
        0x20 => .{ .inputs = 2, .outputs = 1 }, // SHA3

        // 0x30s: Environmental Information
        0x30 => .{ .inputs = 0, .outputs = 1 }, // ADDRESS
        0x31 => .{ .inputs = 1, .outputs = 1 }, // BALANCE
        0x32 => .{ .inputs = 0, .outputs = 1 }, // ORIGIN
        0x33 => .{ .inputs = 0, .outputs = 1 }, // CALLER
        0x34 => .{ .inputs = 0, .outputs = 1 }, // CALLVALUE
        0x35 => .{ .inputs = 1, .outputs = 1 }, // CALLDATALOAD
        0x36 => .{ .inputs = 0, .outputs = 1 }, // CALLDATASIZE
        0x37 => .{ .inputs = 3, .outputs = 0 }, // CALLDATACOPY
        0x38 => .{ .inputs = 0, .outputs = 1 }, // CODESIZE
        0x39 => .{ .inputs = 3, .outputs = 0 }, // CODECOPY
        0x3a => .{ .inputs = 0, .outputs = 1 }, // GASPRICE
        0x3b => .{ .inputs = 1, .outputs = 1 }, // EXTCODESIZE
        0x3c => .{ .inputs = 4, .outputs = 0 }, // EXTCODECOPY
        0x3d => .{ .inputs = 0, .outputs = 1 }, // RETURNDATASIZE
        0x3e => .{ .inputs = 3, .outputs = 0 }, // RETURNDATACOPY
        0x3f => .{ .inputs = 1, .outputs = 1 }, // EXTCODEHASH

        // 0x40s: Block Information
        0x40 => .{ .inputs = 1, .outputs = 1 }, // BLOCKHASH
        0x41 => .{ .inputs = 0, .outputs = 1 }, // COINBASE
        0x42 => .{ .inputs = 0, .outputs = 1 }, // TIMESTAMP
        0x43 => .{ .inputs = 0, .outputs = 1 }, // NUMBER
        0x44 => .{ .inputs = 0, .outputs = 1 }, // DIFFICULTY
        0x45 => .{ .inputs = 0, .outputs = 1 }, // GASLIMIT
        0x46 => .{ .inputs = 0, .outputs = 1 }, // CHAINID
        0x47 => .{ .inputs = 0, .outputs = 1 }, // SELFBALANCE
        0x48 => .{ .inputs = 0, .outputs = 1 }, // BASEFEE
        0x49 => .{ .inputs = 1, .outputs = 1 }, // BLOBHASH
        0x4a => .{ .inputs = 0, .outputs = 1 }, // BLOBBASEFEE

        // 0x50s: Stack, Memory, Storage and Flow Operations
        0x50 => .{ .inputs = 1, .outputs = 0 }, // POP
        0x51 => .{ .inputs = 1, .outputs = 1 }, // MLOAD
        0x52 => .{ .inputs = 2, .outputs = 0 }, // MSTORE
        0x53 => .{ .inputs = 2, .outputs = 0 }, // MSTORE8
        0x54 => .{ .inputs = 1, .outputs = 1 }, // SLOAD
        0x55 => .{ .inputs = 2, .outputs = 0 }, // SSTORE
        0x56 => .{ .inputs = 1, .outputs = 0 }, // JUMP
        0x57 => .{ .inputs = 2, .outputs = 0 }, // JUMPI
        0x58 => .{ .inputs = 0, .outputs = 1 }, // PC
        0x59 => .{ .inputs = 0, .outputs = 1 }, // MSIZE
        0x5a => .{ .inputs = 0, .outputs = 1 }, // GAS
        0x5b => .{ .inputs = 0, .outputs = 0 }, // JUMPDEST
        0x5c => .{ .inputs = 1, .outputs = 1 }, // TLOAD
        0x5d => .{ .inputs = 2, .outputs = 0 }, // TSTORE
        0x5e => .{ .inputs = 3, .outputs = 0 }, // MCOPY
        0x5f => .{ .inputs = 0, .outputs = 1 }, // PUSH0

        // 0x60-0x7f: PUSH1-PUSH32
        0x60...0x7f => .{ .inputs = 0, .outputs = 1 },

        // 0x80-0x8f: DUP1-DUP16
        0x80...0x8f => .{ .inputs = 0, .outputs = 1 },

        // 0x90-0x9f: SWAP1-SWAP16
        0x90...0x9f => .{ .inputs = 0, .outputs = 0 },

        // 0xa0-0xa4: LOG0-LOG4
        0xa0 => .{ .inputs = 2, .outputs = 0 }, // LOG0
        0xa1 => .{ .inputs = 3, .outputs = 0 }, // LOG1
        0xa2 => .{ .inputs = 4, .outputs = 0 }, // LOG2
        0xa3 => .{ .inputs = 5, .outputs = 0 }, // LOG3
        0xa4 => .{ .inputs = 6, .outputs = 0 }, // LOG4

        // 0xf0s: System operations
        0xf0 => .{ .inputs = 3, .outputs = 1 }, // CREATE
        0xf1 => .{ .inputs = 7, .outputs = 1 }, // CALL
        0xf2 => .{ .inputs = 7, .outputs = 1 }, // CALLCODE
        0xf3 => .{ .inputs = 2, .outputs = 0 }, // RETURN
        0xf4 => .{ .inputs = 6, .outputs = 1 }, // DELEGATECALL
        0xf5 => .{ .inputs = 4, .outputs = 1 }, // CREATE2
        0xfa => .{ .inputs = 6, .outputs = 1 }, // STATICCALL
        0xfd => .{ .inputs = 2, .outputs = 0 }, // REVERT
        0xfe => .{ .inputs = 0, .outputs = 0 }, // INVALID
        0xff => .{ .inputs = 1, .outputs = 0 }, // SELFDESTRUCT

        // All other opcodes (undefined)
        else => .{ .inputs = 0, .outputs = 0 },
    };
}

/// Hot path arrays - accessed every opcode execution
execute_funcs: [256]ExecutionFunc align(CACHE_LINE_SIZE),
constant_gas: [256]u64 align(CACHE_LINE_SIZE),

/// Validation arrays - accessed for stack checks
min_stack: [256]u32 align(CACHE_LINE_SIZE),
max_stack: [256]u32 align(CACHE_LINE_SIZE),

/// Stack consumption arrays - how many items each opcode consumes/produces
stack_inputs: [256]u32 align(CACHE_LINE_SIZE),
stack_outputs: [256]u32 align(CACHE_LINE_SIZE),

/// Cold path arrays - rarely accessed
undefined_flags: [256]bool align(CACHE_LINE_SIZE),

/// CANCUN opcode metadata, pre-generated at compile time.
/// This is the latest hardfork configuration.
pub const CANCUN = init_from_hardfork(.CANCUN);

/// Default opcode metadata for the latest hardfork.
/// References CANCUN to avoid generating the same table twice.
/// This is what gets used when no opcode metadata is specified.
pub const DEFAULT = CANCUN;

/// Compile-time hardfork configuration
/// This allows generating specialized jump tables for specific hardforks
/// at compile time, eliminating runtime branching for feature detection.
pub fn ComptimeJumpTable(comptime hardfork: Hardfork) type {
    return struct {
        /// Pre-generated jump table for this hardfork
        pub const table = init_from_hardfork(hardfork);

        /// Check if a specific EIP is enabled in this hardfork
        pub fn hasEIP(comptime eip: u32) bool {
            return switch (eip) {
                3855 => @intFromEnum(hardfork) >= @intFromEnum(Hardfork.SHANGHAI), // PUSH0
                4844 => @intFromEnum(hardfork) >= @intFromEnum(Hardfork.CANCUN), // BLOBHASH
                1153 => @intFromEnum(hardfork) >= @intFromEnum(Hardfork.CANCUN), // Transient storage
                6780 => @intFromEnum(hardfork) >= @intFromEnum(Hardfork.CANCUN), // SELFDESTRUCT restriction
                5656 => @intFromEnum(hardfork) >= @intFromEnum(Hardfork.CANCUN), // MCOPY
                else => @compileError("Unknown EIP"),
            };
        }
    };
}

/// Pre-generated jump tables for common hardforks
pub const FRONTIER_TABLE = ComptimeJumpTable(.FRONTIER).table;
pub const HOMESTEAD_TABLE = ComptimeJumpTable(.HOMESTEAD).table;
pub const BYZANTIUM_TABLE = ComptimeJumpTable(.BYZANTIUM).table;
pub const CONSTANTINOPLE_TABLE = ComptimeJumpTable(.CONSTANTINOPLE).table;
pub const ISTANBUL_TABLE = ComptimeJumpTable(.ISTANBUL).table;
pub const BERLIN_TABLE = ComptimeJumpTable(.BERLIN).table;
pub const LONDON_TABLE = ComptimeJumpTable(.LONDON).table;
pub const SHANGHAI_TABLE = ComptimeJumpTable(.SHANGHAI).table;
pub const CANCUN_TABLE = ComptimeJumpTable(.CANCUN).table;

/// Create an empty opcode metadata with all entries set to defaults.
///
/// This creates a blank opcode metadata that must be populated with
/// operations before use. Typically, you'll want to use
/// init_from_hardfork() instead to get a pre-configured table.
///
/// @return An empty opcode metadata table
pub fn init() OpcodeMetadata {
    const undefined_execute = operation_module.NULL_OPERATION.execute;
    return OpcodeMetadata{
        .execute_funcs = [_]ExecutionFunc{undefined_execute} ** 256,
        .constant_gas = [_]u64{0} ** 256,
        .min_stack = [_]u32{0} ** 256,
        .max_stack = [_]u32{Stack.CAPACITY} ** 256,
        .stack_inputs = [_]u32{0} ** 256,
        .stack_outputs = [_]u32{0} ** 256,
        .undefined_flags = [_]bool{true} ** 256,
    };
}

/// Temporary struct returned by get_operation for API compatibility
pub const OperationView = struct {
    execute: ExecutionFunc,
    constant_gas: u64,
    min_stack: u32,
    max_stack: u32,
    stack_inputs: u32,
    stack_outputs: u32,
    undefined: bool,
};

/// Get the operation handler for a given opcode.
///
/// Returns a view of the operation data for the opcode.
/// This maintains API compatibility while using parallel arrays internally.
///
/// @param self The opcode metadata
/// @param opcode The opcode byte value (0x00-0xFF)
/// @return Operation view struct
///
/// Example:
/// ```zig
/// const op = table.get_operation(0x01); // Get ADD operation
/// ```
pub fn get_operation(self: *const OpcodeMetadata, opcode: u8) OperationView {
    return OperationView{
        .execute = self.execute_funcs[opcode],
        .constant_gas = self.constant_gas[opcode],
        .min_stack = self.min_stack[opcode],
        .max_stack = self.max_stack[opcode],
        .stack_inputs = self.stack_inputs[opcode],
        .stack_outputs = self.stack_outputs[opcode],
        .undefined = self.undefined_flags[opcode],
    };
}

// Note: JUMP/JUMPI and PUSH opcodes are executed inline by the interpreter
// using information produced by analysis. The execute functions for those
// entries are intentionally unreachable (invalid) and serve only as metadata
// carriers for gas/stack validation.

/// Validate and fix the opcode jt.
///
/// Ensures all entries are valid:
/// - Operations with memory_size must have dynamic_gas
/// - Invalid operations are logged and marked as undefined
///
/// This should be called after manually constructing a opcode metadata
/// to ensure it's safe for execution.
///
/// @param self The opcode metadata to validate
pub fn validate(self: *OpcodeMetadata) void {
    _ = self; // No-op validation for now (dynamic gas/memory removed from metadata)
}

pub fn copy(self: *const OpcodeMetadata, allocator: std.mem.Allocator) !OpcodeMetadata {
    _ = allocator;
    return OpcodeMetadata{
        .execute_funcs = self.execute_funcs,
        .constant_gas = self.constant_gas,
        .min_stack = self.min_stack,
        .max_stack = self.max_stack,
        .stack_inputs = self.stack_inputs,
        .stack_outputs = self.stack_outputs,
        .undefined_flags = self.undefined_flags,
    };
}

/// Create a opcode metadata configured for a specific hardfork.
///
/// This is the primary way to create a opcode jt. It starts with
/// the Frontier base configuration and applies all changes up to
/// the specified hardfork.
///
/// @param hardfork The target hardfork configuration
/// @return A fully configured opcode metadata
///
/// Hardfork progression:
/// - FRONTIER: Base EVM opcodes
/// - HOMESTEAD: DELEGATECALL
/// - TANGERINE_WHISTLE: Gas repricing (EIP-150)
/// - BYZANTIUM: REVERT, RETURNDATASIZE, STATICCALL
/// - CONSTANTINOPLE: CREATE2, SHL/SHR/SAR, EXTCODEHASH
/// - ISTANBUL: CHAINID, SELFBALANCE, more gas changes
/// - BERLIN: Access lists, cold/warm storage
/// - LONDON: BASEFEE
/// - SHANGHAI: PUSH0
/// - CANCUN: BLOBHASH, MCOPY, transient storage
///
/// Example:
/// ```zig
/// const table = OpcodeMetadata.init_from_hardfork(.CANCUN);
/// // Table includes all opcodes through Cancun
/// ```
pub fn init_from_hardfork(hardfork: Hardfork) OpcodeMetadata {
    @setEvalBranchQuota(10000);
    var jt = OpcodeMetadata.init();

    // With ALL_OPERATIONS sorted by hardfork, we can iterate once.
    // Each opcode will be set to the latest active version for the target hardfork.
    inline for (operation_config.ALL_OPERATIONS) |spec| {
        const op_hardfork = spec.variant orelse Hardfork.FRONTIER;
        // Most operations are included in hardforks (likely path)
        if (@intFromEnum(op_hardfork) <= @intFromEnum(hardfork)) {
            const op = operation_config.generate_operation(spec);
            const idx = spec.opcode;
            jt.execute_funcs[idx] = op.execute;
            jt.constant_gas[idx] = op.constant_gas;
            jt.min_stack[idx] = op.min_stack;
            jt.max_stack[idx] = op.max_stack;
            jt.undefined_flags[idx] = false;
            
            // Set stack consumption based on opcode
            const stack_consumption = get_stack_consumption(idx);
            jt.stack_inputs[idx] = stack_consumption.inputs;
            jt.stack_outputs[idx] = stack_consumption.outputs;
        }
    }

    // 0x60s & 0x70s: Push operations
    if (comptime builtin.mode == .ReleaseSmall) {
        // PUSH0 - EIP-3855 (available from Shanghai)
        if (@intFromEnum(hardfork) >= @intFromEnum(Hardfork.SHANGHAI)) {
            jt.execute_funcs[0x5f] = wrap_ctx(execution.null_opcode.op_invalid);
            jt.constant_gas[0x5f] = execution.GasConstants.GasQuickStep;
            jt.min_stack[0x5f] = 0;
            jt.max_stack[0x5f] = Stack.CAPACITY - 1;
            jt.stack_inputs[0x5f] = 0;
            jt.stack_outputs[0x5f] = 1;
            jt.undefined_flags[0x5f] = false;
        } else {
            // Before Shanghai, PUSH0 is undefined
            jt.undefined_flags[0x5f] = true;
        }

        // PUSH1 - most common
        jt.execute_funcs[0x60] = wrap_ctx(execution.null_opcode.op_invalid);
        jt.constant_gas[0x60] = execution.GasConstants.GasFastestStep;
        jt.min_stack[0x60] = 0;
        jt.max_stack[0x60] = Stack.CAPACITY - 1;
        jt.stack_inputs[0x60] = 0;
        jt.stack_outputs[0x60] = 1;
        jt.undefined_flags[0x60] = false;

        // PUSH2-PUSH32
        // Note: PUSH operations are executed inline by the interpreter using
        // pre-decoded push_value from analysis. We still set metadata here
        // so stack validation and block gas accounting have correct values.
        for (1..32) |i| {
            const idx = 0x60 + i;
            jt.execute_funcs[idx] = wrap_ctx(execution.null_opcode.op_invalid); // unreachable at runtime
            jt.constant_gas[idx] = execution.GasConstants.GasFastestStep;
            jt.min_stack[idx] = 0;
            jt.max_stack[idx] = Stack.CAPACITY - 1;
            jt.stack_inputs[idx] = 0;
            jt.stack_outputs[idx] = 1;
            jt.undefined_flags[idx] = false;
        }
    } else {
        // PUSH0 - EIP-3855 (available from Shanghai)
        if (@intFromEnum(hardfork) >= @intFromEnum(Hardfork.SHANGHAI)) {
            jt.execute_funcs[0x5f] = wrap_ctx(execution.null_opcode.op_invalid);
            jt.constant_gas[0x5f] = execution.GasConstants.GasQuickStep;
            jt.min_stack[0x5f] = 0;
            jt.max_stack[0x5f] = Stack.CAPACITY - 1;
            jt.stack_inputs[0x5f] = 0;
            jt.stack_outputs[0x5f] = 1;
            jt.undefined_flags[0x5f] = false;
        } else {
            // Before Shanghai, PUSH0 is undefined
            jt.undefined_flags[0x5f] = true;
        }

        // PUSH1 - most common, optimized with direct byte access
        jt.execute_funcs[0x60] = wrap_ctx(execution.null_opcode.op_invalid);
        jt.constant_gas[0x60] = execution.GasConstants.GasFastestStep;
        jt.min_stack[0x60] = 0;
        jt.max_stack[0x60] = Stack.CAPACITY - 1;
        jt.stack_inputs[0x60] = 0;
        jt.stack_outputs[0x60] = 1;
        jt.undefined_flags[0x60] = false;

        // PUSH2-PUSH32 inline execution; provide metadata only
        inline for (1..32) |i| {
            const opcode_idx = 0x60 + i;
            jt.execute_funcs[opcode_idx] = wrap_ctx(execution.null_opcode.op_invalid); // unreachable
            jt.constant_gas[opcode_idx] = execution.GasConstants.GasFastestStep;
            jt.min_stack[opcode_idx] = 0;
            jt.max_stack[opcode_idx] = Stack.CAPACITY - 1;
            jt.stack_inputs[opcode_idx] = 0;
            jt.stack_outputs[opcode_idx] = 1;
            jt.undefined_flags[opcode_idx] = false;
        }
    }

    // 0x80s: Duplication Operations
    if (comptime builtin.mode == .ReleaseSmall) {
        // Use specific functions for each DUP operation to avoid opcode detection issues
        const dup_functions = [_]ExecutionFunc{
            wrap_ctx(stack_ops.op_dup1),  wrap_ctx(stack_ops.op_dup2),  wrap_ctx(stack_ops.op_dup3),  wrap_ctx(stack_ops.op_dup4),
            wrap_ctx(stack_ops.op_dup5),  wrap_ctx(stack_ops.op_dup6),  wrap_ctx(stack_ops.op_dup7),  wrap_ctx(stack_ops.op_dup8),
            wrap_ctx(stack_ops.op_dup9),  wrap_ctx(stack_ops.op_dup10), wrap_ctx(stack_ops.op_dup11), wrap_ctx(stack_ops.op_dup12),
            wrap_ctx(stack_ops.op_dup13), wrap_ctx(stack_ops.op_dup14), wrap_ctx(stack_ops.op_dup15), wrap_ctx(stack_ops.op_dup16),
        };

        inline for (1..17) |n| {
            const idx = 0x80 + n - 1;
            jt.execute_funcs[idx] = dup_functions[n - 1];
            jt.constant_gas[idx] = execution.GasConstants.GasFastestStep;
            jt.min_stack[idx] = @intCast(n);
            jt.max_stack[idx] = Stack.CAPACITY - 1;
            jt.stack_inputs[idx] = 0;
            jt.stack_outputs[idx] = 1;
            jt.undefined_flags[idx] = false;
        }
    } else {
        // Use the same new-style functions for optimized mode
        const dup_functions = [_]ExecutionFunc{
            wrap_ctx(stack_ops.op_dup1),  wrap_ctx(stack_ops.op_dup2),  wrap_ctx(stack_ops.op_dup3),  wrap_ctx(stack_ops.op_dup4),
            wrap_ctx(stack_ops.op_dup5),  wrap_ctx(stack_ops.op_dup6),  wrap_ctx(stack_ops.op_dup7),  wrap_ctx(stack_ops.op_dup8),
            wrap_ctx(stack_ops.op_dup9),  wrap_ctx(stack_ops.op_dup10), wrap_ctx(stack_ops.op_dup11), wrap_ctx(stack_ops.op_dup12),
            wrap_ctx(stack_ops.op_dup13), wrap_ctx(stack_ops.op_dup14), wrap_ctx(stack_ops.op_dup15), wrap_ctx(stack_ops.op_dup16),
        };

        inline for (1..17) |n| {
            const idx = 0x80 + n - 1;
            jt.execute_funcs[idx] = dup_functions[n - 1];
            jt.constant_gas[idx] = execution.GasConstants.GasFastestStep;
            jt.min_stack[idx] = @intCast(n);
            jt.max_stack[idx] = Stack.CAPACITY - 1;
            jt.stack_inputs[idx] = 0;
            jt.stack_outputs[idx] = 1;
            jt.undefined_flags[idx] = false;
        }
    }

    // 0x90s: Exchange Operations
    if (comptime builtin.mode == .ReleaseSmall) {
        // Use specific functions for each SWAP operation to avoid opcode detection issues
        const swap_functions = [_]ExecutionFunc{
            wrap_ctx(stack_ops.op_swap1),  wrap_ctx(stack_ops.op_swap2),  wrap_ctx(stack_ops.op_swap3),  wrap_ctx(stack_ops.op_swap4),
            wrap_ctx(stack_ops.op_swap5),  wrap_ctx(stack_ops.op_swap6),  wrap_ctx(stack_ops.op_swap7),  wrap_ctx(stack_ops.op_swap8),
            wrap_ctx(stack_ops.op_swap9),  wrap_ctx(stack_ops.op_swap10), wrap_ctx(stack_ops.op_swap11), wrap_ctx(stack_ops.op_swap12),
            wrap_ctx(stack_ops.op_swap13), wrap_ctx(stack_ops.op_swap14), wrap_ctx(stack_ops.op_swap15), wrap_ctx(stack_ops.op_swap16),
        };

        inline for (1..17) |n| {
            const idx = 0x90 + n - 1;
            jt.execute_funcs[idx] = swap_functions[n - 1];
            jt.constant_gas[idx] = execution.GasConstants.GasFastestStep;
            jt.min_stack[idx] = @intCast(n + 1);
            jt.max_stack[idx] = Stack.CAPACITY;
            jt.stack_inputs[idx] = 0;
            jt.stack_outputs[idx] = 0;
            jt.undefined_flags[idx] = false;
        }
    } else {
        // Use the same new-style functions for optimized mode
        const swap_functions = [_]ExecutionFunc{
            wrap_ctx(stack_ops.op_swap1),  wrap_ctx(stack_ops.op_swap2),  wrap_ctx(stack_ops.op_swap3),  wrap_ctx(stack_ops.op_swap4),
            wrap_ctx(stack_ops.op_swap5),  wrap_ctx(stack_ops.op_swap6),  wrap_ctx(stack_ops.op_swap7),  wrap_ctx(stack_ops.op_swap8),
            wrap_ctx(stack_ops.op_swap9),  wrap_ctx(stack_ops.op_swap10), wrap_ctx(stack_ops.op_swap11), wrap_ctx(stack_ops.op_swap12),
            wrap_ctx(stack_ops.op_swap13), wrap_ctx(stack_ops.op_swap14), wrap_ctx(stack_ops.op_swap15), wrap_ctx(stack_ops.op_swap16),
        };

        inline for (1..17) |n| {
            const idx = 0x90 + n - 1;
            jt.execute_funcs[idx] = swap_functions[n - 1];
            jt.constant_gas[idx] = execution.GasConstants.GasFastestStep;
            jt.min_stack[idx] = @intCast(n + 1);
            jt.max_stack[idx] = Stack.CAPACITY;
            jt.stack_inputs[idx] = 0;
            jt.stack_outputs[idx] = 0;
            jt.undefined_flags[idx] = false;
        }
    }

    // 0xa0s: Logging Operations
    if (comptime builtin.mode == .ReleaseSmall) {
        // Use specific functions for each LOG operation to avoid opcode detection issues
        const log_functions = [_]ExecutionFunc{
            wrap_ctx(log.log_0), wrap_ctx(log.log_1), wrap_ctx(log.log_2), wrap_ctx(log.log_3), wrap_ctx(log.log_4),
        };

        inline for (0..5) |n| {
            const idx = 0xa0 + n;
            jt.execute_funcs[idx] = log_functions[n];
            jt.constant_gas[idx] = execution.GasConstants.LogGas + execution.GasConstants.LogTopicGas * n;
            jt.min_stack[idx] = @intCast(n + 2);
            jt.max_stack[idx] = Stack.CAPACITY;
            jt.stack_inputs[idx] = @intCast(n + 2);
            jt.stack_outputs[idx] = 0;
            jt.undefined_flags[idx] = false;
        }
    } else {
        // Use the same static functions for optimized mode
        const log_functions = [_]ExecutionFunc{
            wrap_ctx(log.log_0), wrap_ctx(log.log_1), wrap_ctx(log.log_2), wrap_ctx(log.log_3), wrap_ctx(log.log_4),
        };

        inline for (0..5) |n| {
            const idx = 0xa0 + n;
            jt.execute_funcs[idx] = log_functions[n];
            jt.constant_gas[idx] = execution.GasConstants.LogGas + execution.GasConstants.LogTopicGas * n;
            jt.min_stack[idx] = @intCast(n + 2);
            jt.max_stack[idx] = Stack.CAPACITY;
            jt.stack_inputs[idx] = @intCast(n + 2);
            jt.stack_outputs[idx] = 0;
            jt.undefined_flags[idx] = false;
        }
    }

    jt.validate();
    return jt;
}

/// Alias for backward compatibility with camelCase naming
pub const initFromHardfork = init_from_hardfork;
pub const initFromEipFlags = init_from_eip_flags;

// -----------------------------------------------------------------------------
// EIP flags integration: build metadata from feature flags
// -----------------------------------------------------------------------------
const eip_flags_mod = @import("../config/eip_flags.zig");
const EipFlags = eip_flags_mod.EipFlags;

/// Build opcode metadata from EIP flags
pub fn init_from_eip_flags(comptime flags: EipFlags) OpcodeMetadata {
    @setEvalBranchQuota(10000);
    var metadata = OpcodeMetadata.init();

    // Use existing ALL_OPERATIONS from operation_config.zig
    // use file-scope operation_config import
    inline for (operation_config.ALL_OPERATIONS) |spec| {
        const op_hardfork = spec.variant orelse Hardfork.FRONTIER;

        // Check if operation should be included based on EIP flags
        const include_op = switch (spec.opcode) {
            0x3d => flags.eip211_returndatasize, // RETURNDATASIZE
            0x3e => flags.eip211_returndatacopy, // RETURNDATACOPY
            0xfa => flags.eip214_staticcall, // STATICCALL
            0xf5 => flags.eip1014_create2, // CREATE2
            0x3f => flags.eip1052_extcodehash, // EXTCODEHASH
            0x46 => flags.eip1344_chainid, // CHAINID
            0x48 => flags.eip3198_basefee, // BASEFEE
            0x5c => flags.eip1153_transient_storage, // TLOAD
            0x5d => flags.eip1153_transient_storage, // TSTORE
            0x5e => flags.eip5656_mcopy, // MCOPY
            0x49 => flags.eip4844_blob_tx, // BLOBHASH
            0x4a => flags.eip7516_blobbasefee, // BLOBBASEFEE
            0x5f => flags.eip3855_push0, // PUSH0
            else => true,
        };

        if (include_op and @intFromEnum(op_hardfork) <= @intFromEnum(Hardfork.CANCUN)) {
            const op = operation_config.generate_operation(spec);
            metadata.execute_funcs[spec.opcode] = op.execute;
            metadata.constant_gas[spec.opcode] = op.constant_gas;
            metadata.min_stack[spec.opcode] = op.min_stack;
            metadata.max_stack[spec.opcode] = op.max_stack;
            
            // Set stack consumption based on opcode
            const stack_consumption = get_stack_consumption(spec.opcode);
            metadata.stack_inputs[spec.opcode] = stack_consumption.inputs;
            metadata.stack_outputs[spec.opcode] = stack_consumption.outputs;
            
            metadata.undefined_flags[spec.opcode] = false;
        }
    }

    // PUSH0
    if (flags.eip3855_push0) {
        metadata.execute_funcs[0x5f] = wrap_ctx(execution.null_opcode.op_invalid);
        metadata.constant_gas[0x5f] = GasConstants.GasQuickStep;
        metadata.min_stack[0x5f] = 0;
        metadata.max_stack[0x5f] = Stack.CAPACITY - 1;
        metadata.stack_inputs[0x5f] = 0;
        metadata.stack_outputs[0x5f] = 1;
        metadata.undefined_flags[0x5f] = false;
    }

    // PUSH1..PUSH32 metadata entries
    comptime var i: u8 = 0;
    i = 0;
    while (i < 32) : (i += 1) {
        const opcode = 0x60 + i;
        metadata.execute_funcs[opcode] = wrap_ctx(execution.null_opcode.op_invalid);
        metadata.constant_gas[opcode] = GasConstants.GasFastestStep;
        metadata.min_stack[opcode] = 0;
        metadata.max_stack[opcode] = Stack.CAPACITY - 1;
        metadata.stack_inputs[opcode] = 0;
        metadata.stack_outputs[opcode] = 1;
        metadata.undefined_flags[opcode] = false;
    }

    // DUP1..DUP16
    const dup_functions = [_]ExecutionFunc{
        wrap_ctx(execution.stack.op_dup1),  wrap_ctx(execution.stack.op_dup2),  wrap_ctx(execution.stack.op_dup3),  wrap_ctx(execution.stack.op_dup4),
        wrap_ctx(execution.stack.op_dup5),  wrap_ctx(execution.stack.op_dup6),  wrap_ctx(execution.stack.op_dup7),  wrap_ctx(execution.stack.op_dup8),
        wrap_ctx(execution.stack.op_dup9),  wrap_ctx(execution.stack.op_dup10), wrap_ctx(execution.stack.op_dup11), wrap_ctx(execution.stack.op_dup12),
        wrap_ctx(execution.stack.op_dup13), wrap_ctx(execution.stack.op_dup14), wrap_ctx(execution.stack.op_dup15), wrap_ctx(execution.stack.op_dup16),
    };
    i = 0;
    while (i < 16) : (i += 1) {
        const opcode = 0x80 + i;
        metadata.execute_funcs[opcode] = dup_functions[i];
        metadata.constant_gas[opcode] = GasConstants.GasFastestStep;
        metadata.min_stack[opcode] = @intCast(i + 1);
        metadata.max_stack[opcode] = Stack.CAPACITY - 1;
        metadata.stack_inputs[opcode] = 0;
        metadata.stack_outputs[opcode] = 1;
        metadata.undefined_flags[opcode] = false;
    }

    // SWAP1..SWAP16
    const swap_functions = [_]ExecutionFunc{
        wrap_ctx(execution.stack.op_swap1),  wrap_ctx(execution.stack.op_swap2),  wrap_ctx(execution.stack.op_swap3),  wrap_ctx(execution.stack.op_swap4),
        wrap_ctx(execution.stack.op_swap5),  wrap_ctx(execution.stack.op_swap6),  wrap_ctx(execution.stack.op_swap7),  wrap_ctx(execution.stack.op_swap8),
        wrap_ctx(execution.stack.op_swap9),  wrap_ctx(execution.stack.op_swap10), wrap_ctx(execution.stack.op_swap11), wrap_ctx(execution.stack.op_swap12),
        wrap_ctx(execution.stack.op_swap13), wrap_ctx(execution.stack.op_swap14), wrap_ctx(execution.stack.op_swap15), wrap_ctx(execution.stack.op_swap16),
    };
    i = 0;
    while (i < 16) : (i += 1) {
        const opcode = 0x90 + i;
        metadata.execute_funcs[opcode] = swap_functions[i];
        metadata.constant_gas[opcode] = GasConstants.GasFastestStep;
        metadata.min_stack[opcode] = @intCast(i + 2);
        metadata.max_stack[opcode] = Stack.CAPACITY;
        metadata.stack_inputs[opcode] = 0;
        metadata.stack_outputs[opcode] = 0;
        metadata.undefined_flags[opcode] = false;
    }

    // LOG0..LOG4
    const log_functions = [_]ExecutionFunc{
        wrap_ctx(execution.log.log_0), wrap_ctx(execution.log.log_1), wrap_ctx(execution.log.log_2), wrap_ctx(execution.log.log_3), wrap_ctx(execution.log.log_4),
    };
    i = 0;
    while (i <= 4) : (i += 1) {
        const opcode = 0xa0 + i;
        metadata.execute_funcs[opcode] = log_functions[i];
        metadata.constant_gas[opcode] = GasConstants.LogGas + i * GasConstants.LogTopicGas;
        metadata.min_stack[opcode] = @intCast(2 + i);
        metadata.max_stack[opcode] = Stack.CAPACITY;
        metadata.stack_inputs[opcode] = @intCast(2 + i);
        metadata.stack_outputs[opcode] = 0;
        metadata.undefined_flags[opcode] = false;
    }

    return metadata;
}

test "jump_table_benchmarks" {
    const Timer = std.time.Timer;
    var timer = try Timer.start();
    const allocator = std.testing.allocator;

    // Setup test environment
    var memory_db = @import("../state/memory_database.zig").MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    var vm = try @import("../evm.zig").init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const iterations = 100000;

    // Benchmark 1: Opcode dispatch performance comparison
    const cancun_table = OpcodeMetadata.init_from_hardfork(.CANCUN);
    const shanghai_table = OpcodeMetadata.init_from_hardfork(.SHANGHAI);
    const berlin_table = OpcodeMetadata.init_from_hardfork(.BERLIN);

    timer.reset();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Test common opcodes across different hardforks
        const opcode: u8 = @intCast(i % 256);
        _ = cancun_table.get_operation(opcode);
    }
    const cancun_dispatch_ns = timer.read();

    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        const opcode: u8 = @intCast(i % 256);
        _ = shanghai_table.get_operation(opcode);
    }
    const shanghai_dispatch_ns = timer.read();

    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        const opcode: u8 = @intCast(i % 256);
        _ = berlin_table.get_operation(opcode);
    }
    const berlin_dispatch_ns = timer.read();

    // Benchmark 2: Hot path opcode execution (common operations)
    const hot_opcodes = [_]u8{ 0x60, 0x80, 0x01, 0x50, 0x90 }; // PUSH1, DUP1, ADD, POP, SWAP1

    timer.reset();
    for (hot_opcodes) |opcode| {
        i = 0;
        while (i < iterations / hot_opcodes.len) : (i += 1) {
            const operation = cancun_table.get_operation(opcode);
            // Simulate getting operation metadata
            _ = operation.constant_gas;
            _ = operation.min_stack;
            _ = operation.max_stack;
        }
    }
    const hot_path_ns = timer.read();

    // Benchmark 3: Cold path opcode handling (undefined/invalid opcodes)
    timer.reset();
    const invalid_opcodes = [_]u8{ 0x0c, 0x0d, 0x0e, 0x0f, 0x1e, 0x1f }; // Invalid opcodes

    for (invalid_opcodes) |opcode| {
        i = 0;
        while (i < 1000) : (i += 1) { // Fewer iterations for cold path
            const operation = cancun_table.get_operation(opcode);
            // These should return null or undefined operation
            _ = operation;
        }
    }
    const cold_path_ns = timer.read();

    // Benchmark 4: Hardfork-specific opcode availability
    timer.reset();
    const hardfork_specific_opcodes = [_]struct { opcode: u8, hardfork: Hardfork }{
        .{ .opcode = 0x5f, .hardfork = .SHANGHAI }, // PUSH0 - only available from Shanghai
        .{ .opcode = 0x46, .hardfork = .BERLIN }, // CHAINID - available from Istanbul
        .{ .opcode = 0x48, .hardfork = .LONDON }, // BASEFEE - available from London
    };

    for (hardfork_specific_opcodes) |test_case| {
        const table = OpcodeMetadata.init_from_hardfork(test_case.hardfork);
        i = 0;
        while (i < 10000) : (i += 1) {
            const operation = table.get_operation(test_case.opcode);
            _ = operation;
        }
    }
    const hardfork_specific_ns = timer.read();

    // Benchmark 5: Branch prediction impact (predictable vs unpredictable patterns)
    var rng = std.Random.DefaultPrng.init(12345);
    const random = rng.random();

    // Predictable pattern - sequential opcodes
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        const opcode: u8 = @intCast(i % 50); // Sequential pattern
        _ = cancun_table.get_operation(opcode);
    }
    const predictable_ns = timer.read();

    // Unpredictable pattern - random opcodes
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        const opcode: u8 = random.int(u8); // Random pattern
        _ = cancun_table.get_operation(opcode);
    }
    const unpredictable_ns = timer.read();

    // Benchmark 6: Cache locality test with table scanning
    timer.reset();
    i = 0;
    while (i < 1000) : (i += 1) { // Fewer iterations due to full scan cost
        // Scan entire opcode metadata (tests cache locality)
        for (0..256) |opcode_idx| {
            _ = cancun_table.get_operation(@intCast(opcode_idx));
        }
    }
    const table_scan_ns = timer.read();

    // Print benchmark results
    std.log.debug("OpcodeMetadata Benchmarks:", .{});
    std.log.debug("  Cancun dispatch ({} ops): {} ns", .{ iterations, cancun_dispatch_ns });
    std.log.debug("  Shanghai dispatch ({} ops): {} ns", .{ iterations, shanghai_dispatch_ns });
    std.log.debug("  Berlin dispatch ({} ops): {} ns", .{ iterations, berlin_dispatch_ns });
    std.log.debug("  Hot path operations: {} ns", .{hot_path_ns});
    std.log.debug("  Cold path operations: {} ns", .{cold_path_ns});
    std.log.debug("  Hardfork-specific ops: {} ns", .{hardfork_specific_ns});
    std.log.debug("  Predictable pattern ({} ops): {} ns", .{ iterations, predictable_ns });
    std.log.debug("  Unpredictable pattern ({} ops): {} ns", .{ iterations, unpredictable_ns });
    std.log.debug("  Full table scan (1000x): {} ns", .{table_scan_ns});

    // Performance analysis
    const avg_dispatch_ns = cancun_dispatch_ns / iterations;
    const avg_predictable_ns = predictable_ns / iterations;
    const avg_unpredictable_ns = unpredictable_ns / iterations;

    std.log.debug("  Average dispatch time: {} ns/op", .{avg_dispatch_ns});
    std.log.debug("  Average predictable: {} ns/op", .{avg_predictable_ns});
    std.log.debug("  Average unpredictable: {} ns/op", .{avg_unpredictable_ns});

    // Branch prediction analysis
    if (avg_predictable_ns < avg_unpredictable_ns) {
        std.log.debug("✓ Branch prediction benefit observed", .{});
    }

    // Hardfork dispatch performance comparison
    const cancun_avg = cancun_dispatch_ns / iterations;
    const shanghai_avg = shanghai_dispatch_ns / iterations;
    const berlin_avg = berlin_dispatch_ns / iterations;

    std.log.debug("  Hardfork dispatch comparison:", .{});
    std.log.debug("    Berlin avg: {} ns/op", .{berlin_avg});
    std.log.debug("    Shanghai avg: {} ns/op", .{shanghai_avg});
    std.log.debug("    Cancun avg: {} ns/op", .{cancun_avg});

    // Expect very fast dispatch (should be just array indexing)
    if (avg_dispatch_ns < 10) {
        std.log.debug("✓ OpcodeMetadata showing expected O(1) performance", .{});
    }
}
