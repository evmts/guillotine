const std = @import("std");
const builtin = @import("builtin");

/// Professional isomorphic logger for the EVM2 that works across all target architectures
/// including native platforms, WASI, and WASM environments. Uses the std_options.logFn
/// system for automatic platform adaptation.
///
/// Provides debug, error, and warning logging with EVM2-specific prefixing.
/// Debug logs are optimized away in release builds for performance.
/// Debug log for development and troubleshooting
/// Compile-time no-op in ReleaseFast/ReleaseSmall for performance
pub fn debug(comptime format: []const u8, args: anytype) void {
    if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
        if (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding) {
            std.log.debug("[EVM2] " ++ format, args);
        }
    }
}

/// Error log for critical issues that require attention
pub fn err(comptime format: []const u8, args: anytype) void {
    if (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding) {
        std.log.err("[EVM2] " ++ format, args);
    }
}

/// Warning log for non-critical issues and unexpected conditions
pub fn warn(comptime format: []const u8, args: anytype) void {
    if (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding) {
        std.log.warn("[EVM2] " ++ format, args);
    }
}

/// Info log for general information (use sparingly for performance)
pub fn info(comptime format: []const u8, args: anytype) void {
    if (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding) {
        std.log.info("[EVM2] " ++ format, args);
    }
}

/// Debug instruction execution for development and troubleshooting
/// Logs opcode execution with frame context information
/// @param frame The execution frame containing stack, memory, and gas information
/// @param opcode The UnifiedOpcode being executed (comptime known for optimization)
pub fn before_instruction(frame: anytype, comptime opcode: @import("opcodes/opcode.zig").UnifiedOpcode) void {
    if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
        if (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding) {
            // Get opcode name at compile time
            const opcode_name = comptime switch (opcode) {
                // Regular opcodes
                .STOP => "STOP",
                .ADD => "ADD",
                .MUL => "MUL",
                .SUB => "SUB",
                .DIV => "DIV",
                .SDIV => "SDIV",
                .MOD => "MOD",
                .SMOD => "SMOD",
                .ADDMOD => "ADDMOD",
                .MULMOD => "MULMOD",
                .EXP => "EXP",
                .SIGNEXTEND => "SIGNEXTEND",
                .LT => "LT",
                .GT => "GT",
                .SLT => "SLT",
                .SGT => "SGT",
                .EQ => "EQ",
                .ISZERO => "ISZERO",
                .AND => "AND",
                .OR => "OR",
                .XOR => "XOR",
                .NOT => "NOT",
                .BYTE => "BYTE",
                .SHL => "SHL",
                .SHR => "SHR",
                .SAR => "SAR",
                .KECCAK256 => "KECCAK256",
                .ADDRESS => "ADDRESS",
                .BALANCE => "BALANCE",
                .ORIGIN => "ORIGIN",
                .CALLER => "CALLER",
                .CALLVALUE => "CALLVALUE",
                .CALLDATALOAD => "CALLDATALOAD",
                .CALLDATASIZE => "CALLDATASIZE",
                .CALLDATACOPY => "CALLDATACOPY",
                .CODESIZE => "CODESIZE",
                .CODECOPY => "CODECOPY",
                .GASPRICE => "GASPRICE",
                .EXTCODESIZE => "EXTCODESIZE",
                .EXTCODECOPY => "EXTCODECOPY",
                .RETURNDATASIZE => "RETURNDATASIZE",
                .RETURNDATACOPY => "RETURNDATACOPY",
                .EXTCODEHASH => "EXTCODEHASH",
                .BLOCKHASH => "BLOCKHASH",
                .COINBASE => "COINBASE",
                .TIMESTAMP => "TIMESTAMP",
                .NUMBER => "NUMBER",
                .PREVRANDAO => "PREVRANDAO",
                .GASLIMIT => "GASLIMIT",
                .CHAINID => "CHAINID",
                .SELFBALANCE => "SELFBALANCE",
                .BASEFEE => "BASEFEE",
                .BLOBHASH => "BLOBHASH",
                .BLOBBASEFEE => "BLOBBASEFEE",
                .POP => "POP",
                .MLOAD => "MLOAD",
                .MSTORE => "MSTORE",
                .MSTORE8 => "MSTORE8",
                .SLOAD => "SLOAD",
                .SSTORE => "SSTORE",
                .JUMP => "JUMP",
                .JUMPI => "JUMPI",
                .PC => "PC",
                .MSIZE => "MSIZE",
                .GAS => "GAS",
                .JUMPDEST => "JUMPDEST",
                .TLOAD => "TLOAD",
                .TSTORE => "TSTORE",
                .MCOPY => "MCOPY",
                .PUSH0 => "PUSH0",
                .PUSH1 => "PUSH1",
                .PUSH2 => "PUSH2",
                .PUSH3 => "PUSH3",
                .PUSH4 => "PUSH4",
                .PUSH5 => "PUSH5",
                .PUSH6 => "PUSH6",
                .PUSH7 => "PUSH7",
                .PUSH8 => "PUSH8",
                .PUSH9 => "PUSH9",
                .PUSH10 => "PUSH10",
                .PUSH11 => "PUSH11",
                .PUSH12 => "PUSH12",
                .PUSH13 => "PUSH13",
                .PUSH14 => "PUSH14",
                .PUSH15 => "PUSH15",
                .PUSH16 => "PUSH16",
                .PUSH17 => "PUSH17",
                .PUSH18 => "PUSH18",
                .PUSH19 => "PUSH19",
                .PUSH20 => "PUSH20",
                .PUSH21 => "PUSH21",
                .PUSH22 => "PUSH22",
                .PUSH23 => "PUSH23",
                .PUSH24 => "PUSH24",
                .PUSH25 => "PUSH25",
                .PUSH26 => "PUSH26",
                .PUSH27 => "PUSH27",
                .PUSH28 => "PUSH28",
                .PUSH29 => "PUSH29",
                .PUSH30 => "PUSH30",
                .PUSH31 => "PUSH31",
                .PUSH32 => "PUSH32",
                .DUP1 => "DUP1",
                .DUP2 => "DUP2",
                .DUP3 => "DUP3",
                .DUP4 => "DUP4",
                .DUP5 => "DUP5",
                .DUP6 => "DUP6",
                .DUP7 => "DUP7",
                .DUP8 => "DUP8",
                .DUP9 => "DUP9",
                .DUP10 => "DUP10",
                .DUP11 => "DUP11",
                .DUP12 => "DUP12",
                .DUP13 => "DUP13",
                .DUP14 => "DUP14",
                .DUP15 => "DUP15",
                .DUP16 => "DUP16",
                .SWAP1 => "SWAP1",
                .SWAP2 => "SWAP2",
                .SWAP3 => "SWAP3",
                .SWAP4 => "SWAP4",
                .SWAP5 => "SWAP5",
                .SWAP6 => "SWAP6",
                .SWAP7 => "SWAP7",
                .SWAP8 => "SWAP8",
                .SWAP9 => "SWAP9",
                .SWAP10 => "SWAP10",
                .SWAP11 => "SWAP11",
                .SWAP12 => "SWAP12",
                .SWAP13 => "SWAP13",
                .SWAP14 => "SWAP14",
                .SWAP15 => "SWAP15",
                .SWAP16 => "SWAP16",
                .LOG0 => "LOG0",
                .LOG1 => "LOG1",
                .LOG2 => "LOG2",
                .LOG3 => "LOG3",
                .LOG4 => "LOG4",
                .CREATE => "CREATE",
                .CALL => "CALL",
                .CALLCODE => "CALLCODE",
                .RETURN => "RETURN",
                .DELEGATECALL => "DELEGATECALL",
                .CREATE2 => "CREATE2",
                .AUTH => "AUTH",
                .AUTHCALL => "AUTHCALL",
                .STATICCALL => "STATICCALL",
                .REVERT => "REVERT",
                .INVALID => "INVALID",
                .SELFDESTRUCT => "SELFDESTRUCT",
                // Synthetic opcodes
                .PUSH_ADD_INLINE => "PUSH_ADD_INLINE",
                .PUSH_ADD_POINTER => "PUSH_ADD_POINTER",
                .PUSH_MUL_INLINE => "PUSH_MUL_INLINE",
                .PUSH_MUL_POINTER => "PUSH_MUL_POINTER",
                .PUSH_DIV_INLINE => "PUSH_DIV_INLINE",
                .PUSH_DIV_POINTER => "PUSH_DIV_POINTER",
                .PUSH_SUB_INLINE => "PUSH_SUB_INLINE",
                .PUSH_SUB_POINTER => "PUSH_SUB_POINTER",
                .PUSH_MLOAD_INLINE => "PUSH_MLOAD_INLINE",
                .PUSH_MLOAD_POINTER => "PUSH_MLOAD_POINTER",
                .PUSH_MSTORE_INLINE => "PUSH_MSTORE_INLINE",
                .PUSH_MSTORE_POINTER => "PUSH_MSTORE_POINTER",
                .PUSH_AND_INLINE => "PUSH_AND_INLINE",
                .PUSH_AND_POINTER => "PUSH_AND_POINTER",
                .PUSH_OR_INLINE => "PUSH_OR_INLINE",
                .PUSH_OR_POINTER => "PUSH_OR_POINTER",
                .PUSH_XOR_INLINE => "PUSH_XOR_INLINE",
                .PUSH_XOR_POINTER => "PUSH_XOR_POINTER",
                .PUSH_MSTORE8_INLINE => "PUSH_MSTORE8_INLINE",
                .PUSH_MSTORE8_POINTER => "PUSH_MSTORE8_POINTER",
                .JUMP_TO_STATIC_LOCATION => "JUMP_TO_STATIC_LOCATION",
                .JUMPI_TO_STATIC_LOCATION => "JUMPI_TO_STATIC_LOCATION",
                .MULTI_PUSH_2 => "MULTI_PUSH_2",
                .MULTI_PUSH_3 => "MULTI_PUSH_3",
                .MULTI_POP_2 => "MULTI_POP_2",
                .MULTI_POP_3 => "MULTI_POP_3",
                .ISZERO_JUMPI => "ISZERO_JUMPI",
                .DUP2_MSTORE_PUSH => "DUP2_MSTORE_PUSH",
                .DUP3_ADD_MSTORE => "DUP3_ADD_MSTORE",
                .SWAP1_DUP2_ADD => "SWAP1_DUP2_ADD",
                .PUSH_DUP3_ADD => "PUSH_DUP3_ADD",
                .FUNCTION_DISPATCH => "FUNCTION_DISPATCH",
                .CALLVALUE_CHECK => "CALLVALUE_CHECK",
                .PUSH0_REVERT => "PUSH0_REVERT",
                .PUSH_ADD_DUP1 => "PUSH_ADD_DUP1",
                .MLOAD_SWAP1_DUP2 => "MLOAD_SWAP1_DUP2",
            };

            // For operations that need stack values, we'll log them
            // The stack uses stack_ptr to access elements, with stack_ptr[0] being the top
            const stack_size = frame.stack.size();
            const stack_ptr = frame.stack.stack_ptr;

            // Log with appropriate details based on opcode type
            switch (opcode) {
                // Binary arithmetic operations - log top 2 stack items
                .ADD, .MUL, .SUB, .DIV, .MOD, .SDIV, .SMOD, .LT, .GT, .SLT, .SGT, .EQ, .AND, .OR, .XOR, .EXP, .SIGNEXTEND, .BYTE, .SHL, .SHR, .SAR => {
                    if (stack_size >= 2) {
                        // Stack items accessed via stack_ptr: [0] is top, [1] is second
                        const top = stack_ptr[0];
                        const second = stack_ptr[1];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | operands=[{x}, {x}]", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            top,
                            second,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },

                // Ternary operations - log top 3 stack items
                .ADDMOD, .MULMOD => {
                    if (stack_size >= 3) {
                        const top = stack_ptr[0];
                        const second = stack_ptr[1];
                        const third = stack_ptr[2];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | operands=[{x}, {x}, {x}]", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            top,
                            second,
                            third,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },

                // Unary operations - log top stack item
                .ISZERO, .NOT, .POP => {
                    if (stack_size >= 1) {
                        const top = stack_ptr[0];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | value={x}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            top,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },

                // DUP operations - show which item is being duplicated
                .DUP1, .DUP2, .DUP3, .DUP4, .DUP5, .DUP6, .DUP7, .DUP8, .DUP9, .DUP10, .DUP11, .DUP12, .DUP13, .DUP14, .DUP15, .DUP16 => {
                    const dup_pos = comptime switch (opcode) {
                        .DUP1 => 1,
                        .DUP2 => 2,
                        .DUP3 => 3,
                        .DUP4 => 4,
                        .DUP5 => 5,
                        .DUP6 => 6,
                        .DUP7 => 7,
                        .DUP8 => 8,
                        .DUP9 => 9,
                        .DUP10 => 10,
                        .DUP11 => 11,
                        .DUP12 => 12,
                        .DUP13 => 13,
                        .DUP14 => 14,
                        .DUP15 => 15,
                        .DUP16 => 16,
                        else => unreachable,
                    };
                    if (stack_size >= dup_pos) {
                        const value = stack_ptr[dup_pos - 1];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | duplicating_pos={d} value={x}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            dup_pos,
                            value,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },

                // SWAP operations - show the two positions being swapped
                .SWAP1, .SWAP2, .SWAP3, .SWAP4, .SWAP5, .SWAP6, .SWAP7, .SWAP8, .SWAP9, .SWAP10, .SWAP11, .SWAP12, .SWAP13, .SWAP14, .SWAP15, .SWAP16 => {
                    const swap_pos = comptime switch (opcode) {
                        .SWAP1 => 1,
                        .SWAP2 => 2,
                        .SWAP3 => 3,
                        .SWAP4 => 4,
                        .SWAP5 => 5,
                        .SWAP6 => 6,
                        .SWAP7 => 7,
                        .SWAP8 => 8,
                        .SWAP9 => 9,
                        .SWAP10 => 10,
                        .SWAP11 => 11,
                        .SWAP12 => 12,
                        .SWAP13 => 13,
                        .SWAP14 => 14,
                        .SWAP15 => 15,
                        .SWAP16 => 16,
                        else => unreachable,
                    };
                    if (stack_size > swap_pos) {
                        const top = stack_ptr[0];
                        const other = stack_ptr[swap_pos];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | swapping=[{x}, {x}] pos={d}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            top,
                            other,
                            swap_pos,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },

                // Memory operations - show offset and value
                .MLOAD => {
                    if (stack_size >= 1) {
                        const offset = stack_ptr[0];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} mem={d} | offset={x}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            frame.memory.size(),
                            offset,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },
                .MSTORE, .MSTORE8 => {
                    if (stack_size >= 2) {
                        const offset = stack_ptr[0];
                        const value = stack_ptr[1];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} mem={d} | offset={x} value={x}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            frame.memory.size(),
                            offset,
                            value,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },
                .MSIZE => {
                    std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | mem_size={d}", .{
                        opcode_name,
                        stack_size,
                        frame.gas_remaining,
                        frame.memory.size(),
                    });
                },

                // Storage operations - show key and value
                .SLOAD, .TLOAD => {
                    if (stack_size >= 1) {
                        const key = stack_ptr[0];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | key={x}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            key,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },
                .SSTORE, .TSTORE => {
                    if (stack_size >= 2) {
                        const key = stack_ptr[0];
                        const value = stack_ptr[1];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | key={x} value={x}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            key,
                            value,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },

                // Jump operations
                .JUMP => {
                    if (stack_size >= 1) {
                        const destination = stack_ptr[0];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | destination={x}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            destination,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },
                .JUMPI => {
                    if (stack_size >= 2) {
                        const destination = stack_ptr[0];
                        const condition = stack_ptr[1];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | dest={x} cond={x}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            destination,
                            condition,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },

                // PUSH operations - just log that we're pushing
                .PUSH0, .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8, .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                    std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d}", .{
                        opcode_name,
                        stack_size,
                        frame.gas_remaining,
                    });
                },

                // Simple context operations
                .PC, .GAS, .JUMPDEST, .ADDRESS, .ORIGIN, .CALLER, .COINBASE, .BALANCE, .SELFBALANCE, .CALLVALUE, .GASPRICE, .BASEFEE, .BLOBBASEFEE, .CALLDATASIZE, .CODESIZE, .RETURNDATASIZE, .TIMESTAMP, .NUMBER, .PREVRANDAO, .GASLIMIT, .CHAINID, .STOP, .INVALID => {
                    std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d}", .{
                        opcode_name,
                        stack_size,
                        frame.gas_remaining,
                    });
                },

                // Operations that read offset from stack
                .CALLDATALOAD, .EXTCODESIZE, .EXTCODEHASH, .BLOCKHASH, .BLOBHASH => {
                    if (stack_size >= 1) {
                        const arg = stack_ptr[0];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | arg={x}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            arg,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },

                // Copy operations
                .CALLDATACOPY, .CODECOPY, .RETURNDATACOPY, .MCOPY => {
                    if (stack_size >= 3) {
                        const dest = stack_ptr[0];
                        const src = stack_ptr[1];
                        const length = stack_ptr[2];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | dest={x} src={x} len={d}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            dest,
                            src,
                            length,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },

                // Hash and log operations
                .KECCAK256, .LOG0, .LOG1, .LOG2, .LOG3, .LOG4 => {
                    if (stack_size >= 2) {
                        const offset = stack_ptr[0];
                        const length = stack_ptr[1];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | offset={x} len={d}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            offset,
                            length,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },

                // Return/revert operations
                .RETURN, .REVERT => {
                    if (stack_size >= 2) {
                        const offset = stack_ptr[0];
                        const length = stack_ptr[1];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | offset={x} len={d}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            offset,
                            length,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },

                // System calls - log gas and address
                .CALL, .CALLCODE, .DELEGATECALL, .STATICCALL => {
                    if (stack_size >= 2) {
                        const gas = stack_ptr[0];
                        const address = stack_ptr[1];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | call_gas={d} addr={x}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            gas,
                            address,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },

                // CREATE operations
                .CREATE => {
                    if (stack_size >= 3) {
                        const value = stack_ptr[0];
                        const offset = stack_ptr[1];
                        const length = stack_ptr[2];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | value={x} offset={x} len={d}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            value,
                            offset,
                            length,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },
                .CREATE2 => {
                    if (stack_size >= 4) {
                        const value = stack_ptr[0];
                        const offset = stack_ptr[1];
                        const length = stack_ptr[2];
                        const salt = stack_ptr[3];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | value={x} offset={x} len={d} salt={x}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            value,
                            offset,
                            length,
                            salt,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },

                // Other operations
                .SELFDESTRUCT => {
                    if (stack_size >= 1) {
                        const beneficiary = stack_ptr[0];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | beneficiary={x}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            beneficiary,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },
                .AUTH => {
                    if (stack_size >= 1) {
                        const authority = stack_ptr[0];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | authority={x}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            authority,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },
                .AUTHCALL => {
                    if (stack_size >= 3) {
                        const gas = stack_ptr[0];
                        const address = stack_ptr[1];
                        const auth = stack_ptr[2];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | call_gas={d} addr={x} auth={x}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            gas,
                            address,
                            auth,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },
                .EXTCODECOPY => {
                    if (stack_size >= 4) {
                        const address = stack_ptr[0];
                        const dest = stack_ptr[1];
                        const src = stack_ptr[2];
                        const length = stack_ptr[3];
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | addr={x} dest={x} src={x} len={d}", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                            address,
                            dest,
                            src,
                            length,
                        });
                    } else {
                        std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | STACK_UNDERFLOW", .{
                            opcode_name,
                            stack_size,
                            frame.gas_remaining,
                        });
                    }
                },

                // Synthetic operations - just basic logging
                .PUSH_ADD_INLINE, .PUSH_ADD_POINTER, .PUSH_MUL_INLINE, .PUSH_MUL_POINTER, .PUSH_DIV_INLINE, .PUSH_DIV_POINTER, .PUSH_SUB_INLINE, .PUSH_SUB_POINTER, .PUSH_AND_INLINE, .PUSH_AND_POINTER, .PUSH_OR_INLINE, .PUSH_OR_POINTER, .PUSH_XOR_INLINE, .PUSH_XOR_POINTER, .PUSH_MLOAD_INLINE, .PUSH_MLOAD_POINTER, .PUSH_MSTORE_INLINE, .PUSH_MSTORE_POINTER, .PUSH_MSTORE8_INLINE, .PUSH_MSTORE8_POINTER, .JUMP_TO_STATIC_LOCATION, .JUMPI_TO_STATIC_LOCATION, .MULTI_PUSH_2, .MULTI_PUSH_3, .MULTI_POP_2, .MULTI_POP_3, .ISZERO_JUMPI, .DUP2_MSTORE_PUSH, .DUP3_ADD_MSTORE, .SWAP1_DUP2_ADD, .PUSH_DUP3_ADD, .FUNCTION_DISPATCH, .CALLVALUE_CHECK, .PUSH0_REVERT, .PUSH_ADD_DUP1, .MLOAD_SWAP1_DUP2 => {
                    std.log.debug("[EVM2] EXEC: {s} | stack={d} gas={d} | synthetic_op", .{
                        opcode_name,
                        stack_size,
                        frame.gas_remaining,
                    });
                },
            }
        }
    }
}

test "log functions compile and execute without error" {
    debug("test debug message: {}", .{42});
    err("test error message: {s}", .{"error"});
    warn("test warning message: {d:.2}", .{3.14});
    info("test info message: {any}", .{true});
}

test "log functions handle different argument types" {
    debug("string: {s}, number: {d}, hex: {x}", .{ "test", 123, 0xABC });
    err("boolean: {}, float: {d:.3}", .{ false, 2.718 });
    warn("array: {any}", .{[_]u32{ 1, 2, 3 }});
    info("no args: {s}", .{""});
}
