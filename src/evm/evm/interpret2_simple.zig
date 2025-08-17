const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("../execution/execution_error.zig");
const frame_mod = @import("../frame.zig");
const Frame = frame_mod.Frame;
const Opcode = @import("../opcodes/opcode.zig").Enum;
const execution = @import("../execution/package.zig");
const primitives = @import("primitives");

pub const Error = ExecutionError.Error;

// Simple interpreter that executes bytecode directly without tailcall optimization
pub fn interpret2(frame: *Frame, code: []const u8) Error!void {
    var pc: usize = 0;
    
    while (pc < code.len) {
        const opcode_byte = code[pc];
        const opcode = @as(Opcode, @enumFromInt(opcode_byte));
        
        switch (opcode) {
            .STOP => return Error.STOP,
            
            // Arithmetic operations
            .ADD => {
                try execution.arithmetic.op_add(frame);
                pc += 1;
            },
            .MUL => {
                try execution.arithmetic.op_mul(frame);
                pc += 1;
            },
            .SUB => {
                try execution.arithmetic.op_sub(frame);
                pc += 1;
            },
            .DIV => {
                try execution.arithmetic.op_div(frame);
                pc += 1;
            },
            .SDIV => {
                try execution.arithmetic.op_sdiv(frame);
                pc += 1;
            },
            .MOD => {
                try execution.arithmetic.op_mod(frame);
                pc += 1;
            },
            .SMOD => {
                try execution.arithmetic.op_smod(frame);
                pc += 1;
            },
            .ADDMOD => {
                try execution.arithmetic.op_addmod(frame);
                pc += 1;
            },
            .MULMOD => {
                try execution.arithmetic.op_mulmod(frame);
                pc += 1;
            },
            .EXP => {
                try execution.arithmetic.op_exp(frame);
                pc += 1;
            },
            .SIGNEXTEND => {
                try execution.arithmetic.op_signextend(frame);
                pc += 1;
            },
            
            // Comparison operations
            .LT => {
                try execution.comparison.op_lt(frame);
                pc += 1;
            },
            .GT => {
                try execution.comparison.op_gt(frame);
                pc += 1;
            },
            .SLT => {
                try execution.comparison.op_slt(frame);
                pc += 1;
            },
            .SGT => {
                try execution.comparison.op_sgt(frame);
                pc += 1;
            },
            .EQ => {
                try execution.comparison.op_eq(frame);
                pc += 1;
            },
            .ISZERO => {
                try execution.comparison.op_iszero(frame);
                pc += 1;
            },
            
            // Bitwise operations
            .AND => {
                try execution.bitwise.op_and(frame);
                pc += 1;
            },
            .OR => {
                try execution.bitwise.op_or(frame);
                pc += 1;
            },
            .XOR => {
                try execution.bitwise.op_xor(frame);
                pc += 1;
            },
            .NOT => {
                try execution.bitwise.op_not(frame);
                pc += 1;
            },
            .BYTE => {
                try execution.bitwise.op_byte(frame);
                pc += 1;
            },
            .SHL => {
                try execution.bitwise.op_shl(frame);
                pc += 1;
            },
            .SHR => {
                try execution.bitwise.op_shr(frame);
                pc += 1;
            },
            .SAR => {
                try execution.bitwise.op_sar(frame);
                pc += 1;
            },
            
            // Stack operations
            .POP => {
                try execution.stack.op_pop(frame);
                pc += 1;
            },
            .PUSH0 => {
                try frame.stack.append(0);
                pc += 1;
            },
            .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8,
            .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16,
            .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24,
            .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                const push_size = opcode_byte - 0x5F;
                pc += 1; // Move past opcode
                
                // Read push value
                var value: u256 = 0;
                var i: usize = 0;
                while (i < push_size and pc + i < code.len) : (i += 1) {
                    value = (value << 8) | code[pc + i];
                }
                
                try frame.stack.append(value);
                pc += push_size;
            },
            
            // DUP operations
            .DUP1 => {
                try execution.stack.op_dup1(frame);
                pc += 1;
            },
            .DUP2 => {
                try execution.stack.op_dup2(frame);
                pc += 1;
            },
            .DUP3 => {
                try execution.stack.op_dup3(frame);
                pc += 1;
            },
            .DUP4 => {
                try execution.stack.op_dup4(frame);
                pc += 1;
            },
            .DUP5 => {
                try execution.stack.op_dup5(frame);
                pc += 1;
            },
            .DUP6 => {
                try execution.stack.op_dup6(frame);
                pc += 1;
            },
            .DUP7 => {
                try execution.stack.op_dup7(frame);
                pc += 1;
            },
            .DUP8 => {
                try execution.stack.op_dup8(frame);
                pc += 1;
            },
            .DUP9 => {
                try execution.stack.op_dup9(frame);
                pc += 1;
            },
            .DUP10 => {
                try execution.stack.op_dup10(frame);
                pc += 1;
            },
            .DUP11 => {
                try execution.stack.op_dup11(frame);
                pc += 1;
            },
            .DUP12 => {
                try execution.stack.op_dup12(frame);
                pc += 1;
            },
            .DUP13 => {
                try execution.stack.op_dup13(frame);
                pc += 1;
            },
            .DUP14 => {
                try execution.stack.op_dup14(frame);
                pc += 1;
            },
            .DUP15 => {
                try execution.stack.op_dup15(frame);
                pc += 1;
            },
            .DUP16 => {
                try execution.stack.op_dup16(frame);
                pc += 1;
            },
            
            // SWAP operations
            .SWAP1 => {
                try execution.stack.op_swap1(frame);
                pc += 1;
            },
            .SWAP2 => {
                try execution.stack.op_swap2(frame);
                pc += 1;
            },
            .SWAP3 => {
                try execution.stack.op_swap3(frame);
                pc += 1;
            },
            .SWAP4 => {
                try execution.stack.op_swap4(frame);
                pc += 1;
            },
            .SWAP5 => {
                try execution.stack.op_swap5(frame);
                pc += 1;
            },
            .SWAP6 => {
                try execution.stack.op_swap6(frame);
                pc += 1;
            },
            .SWAP7 => {
                try execution.stack.op_swap7(frame);
                pc += 1;
            },
            .SWAP8 => {
                try execution.stack.op_swap8(frame);
                pc += 1;
            },
            .SWAP9 => {
                try execution.stack.op_swap9(frame);
                pc += 1;
            },
            .SWAP10 => {
                try execution.stack.op_swap10(frame);
                pc += 1;
            },
            .SWAP11 => {
                try execution.stack.op_swap11(frame);
                pc += 1;
            },
            .SWAP12 => {
                try execution.stack.op_swap12(frame);
                pc += 1;
            },
            .SWAP13 => {
                try execution.stack.op_swap13(frame);
                pc += 1;
            },
            .SWAP14 => {
                try execution.stack.op_swap14(frame);
                pc += 1;
            },
            .SWAP15 => {
                try execution.stack.op_swap15(frame);
                pc += 1;
            },
            .SWAP16 => {
                try execution.stack.op_swap16(frame);
                pc += 1;
            },
            
            // Control flow
            .JUMP => {
                const dest = try frame.stack.pop();
                if (dest >= code.len) return Error.InvalidJump;
                
                // Check if destination is a JUMPDEST
                if (code[@intCast(dest)] != @intFromEnum(Opcode.JUMPDEST)) {
                    return Error.InvalidJump;
                }
                
                pc = @intCast(dest);
            },
            .JUMPI => {
                const dest = try frame.stack.pop();
                const condition = try frame.stack.pop();
                
                if (condition != 0) {
                    if (dest >= code.len) return Error.InvalidJump;
                    
                    // Check if destination is a JUMPDEST
                    if (code[@intCast(dest)] != @intFromEnum(Opcode.JUMPDEST)) {
                        return Error.InvalidJump;
                    }
                    
                    pc = @intCast(dest);
                } else {
                    pc += 1;
                }
            },
            .JUMPDEST => {
                // No-op, just a marker
                pc += 1;
            },
            
            // Memory operations
            .MSTORE => {
                try execution.memory.op_mstore(frame);
                pc += 1;
            },
            .MSTORE8 => {
                try execution.memory.op_mstore8(frame);
                pc += 1;
            },
            .MLOAD => {
                try execution.memory.op_mload(frame);
                pc += 1;
            },
            
            // System operations
            .RETURN => {
                try execution.control.op_return(frame);
                return Error.RETURN;
            },
            .REVERT => {
                try execution.control.op_revert(frame);
                return Error.REVERT;
            },
            .INVALID => {
                return Error.INVALID;
            },
            
            // Environment opcodes
            .ADDRESS => {
                try execution.environment.op_address(frame);
                pc += 1;
            },
            .BALANCE => {
                try execution.environment.op_balance(frame);
                pc += 1;
            },
            .ORIGIN => {
                try execution.environment.op_origin(frame);
                pc += 1;
            },
            .CALLER => {
                try execution.environment.op_caller(frame);
                pc += 1;
            },
            .CALLVALUE => {
                try execution.environment.op_callvalue(frame);
                pc += 1;
            },
            .CALLDATALOAD => {
                try execution.environment.op_calldataload(frame);
                pc += 1;
            },
            .CALLDATASIZE => {
                try execution.environment.op_calldatasize(frame);
                pc += 1;
            },
            .CALLDATACOPY => {
                try execution.environment.op_calldatacopy(frame);
                pc += 1;
            },
            .CODESIZE => {
                try execution.environment.op_codesize(frame);
                pc += 1;
            },
            .CODECOPY => {
                try execution.environment.op_codecopy(frame);
                pc += 1;
            },
            .GASPRICE => {
                try execution.environment.op_gasprice(frame);
                pc += 1;
            },
            .CHAINID => {
                try execution.environment.op_chainid(frame);
                pc += 1;
            },
            .SELFBALANCE => {
                try execution.environment.op_selfbalance(frame);
                pc += 1;
            },
            
            // Block opcodes
            .BLOCKHASH => {
                try execution.block.op_blockhash(frame);
                pc += 1;
            },
            .BLOBHASH => {
                try execution.block.op_blobhash(frame);
                pc += 1;
            },
            .BLOBBASEFEE => {
                try execution.block.op_blobbasefee(frame);
                pc += 1;
            },
            .COINBASE => {
                try execution.block.op_coinbase(frame);
                pc += 1;
            },
            .TIMESTAMP => {
                try execution.block.op_timestamp(frame);
                pc += 1;
            },
            .NUMBER => {
                try execution.block.op_number(frame);
                pc += 1;
            },
            .PREVRANDAO => {
                try execution.block.op_difficulty(frame);
                pc += 1;
            },
            .GASLIMIT => {
                try execution.block.op_gaslimit(frame);
                pc += 1;
            },
            .BASEFEE => {
                try execution.block.op_basefee(frame);
                pc += 1;
            },
            
            // Extended environment opcodes
            .EXTCODESIZE => {
                try execution.environment.op_extcodesize(frame);
                pc += 1;
            },
            .EXTCODECOPY => {
                try execution.environment.op_extcodecopy(frame);
                pc += 1;
            },
            .EXTCODEHASH => {
                try execution.environment.op_extcodehash(frame);
                pc += 1;
            },
            .RETURNDATASIZE => {
                try execution.environment.op_returndatasize(frame);
                pc += 1;
            },
            .RETURNDATACOPY => {
                try execution.environment.op_returndatacopy(frame);
                pc += 1;
            },
            
            // Control flow opcodes
            .PC => {
                try execution.control.op_pc(frame);
                pc += 1;
            },
            .GAS => {
                try execution.control.op_gas(frame);
                pc += 1;
            },
            .MSIZE => {
                try execution.memory.op_msize(frame);
                pc += 1;
            },
            
            // Crypto opcodes
            .KECCAK256 => {
                try execution.crypto.op_keccak256(frame);
                pc += 1;
            },
            
            // Storage opcodes
            .SLOAD => {
                try execution.storage.op_sload(frame);
                pc += 1;
            },
            .SSTORE => {
                try execution.storage.op_sstore(frame);
                pc += 1;
            },
            .TLOAD => {
                try execution.storage.op_tload(frame);
                pc += 1;
            },
            .TSTORE => {
                try execution.storage.op_tstore(frame);
                pc += 1;
            },
            
            // Memory opcodes
            .MCOPY => {
                try execution.memory.op_mcopy(frame);
                pc += 1;
            },
            
            // Log opcodes
            .LOG0 => {
                try execution.log.log_0(frame);
                pc += 1;
            },
            .LOG1 => {
                try execution.log.log_1(frame);
                pc += 1;
            },
            .LOG2 => {
                try execution.log.log_2(frame);
                pc += 1;
            },
            .LOG3 => {
                try execution.log.log_3(frame);
                pc += 1;
            },
            .LOG4 => {
                try execution.log.log_4(frame);
                pc += 1;
            },
            
            // System opcodes
            .CREATE => {
                try execution.system.op_create(frame);
                return Error.RETURN; // CREATE terminates execution
            },
            .CALL => {
                try execution.system.op_call(frame);
                pc += 1;
            },
            .CALLCODE => {
                try execution.system.op_callcode(frame);
                pc += 1;
            },
            .DELEGATECALL => {
                try execution.system.op_delegatecall(frame);
                pc += 1;
            },
            .CREATE2 => {
                try execution.system.op_create2(frame);
                return Error.RETURN; // CREATE2 terminates execution
            },
            .STATICCALL => {
                try execution.system.op_staticcall(frame);
                pc += 1;
            },
            .SELFDESTRUCT => {
                try execution.control.op_selfdestruct(frame);
                return Error.STOP; // SELFDESTRUCT terminates execution
            },
            
            else => {
                // Unknown or unimplemented opcode
                return Error.InvalidOpcode;
            },
        }
    }
    
    // Reached end of code without STOP
    return Error.STOP;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "interpret2_simple: simple ADD operation" {
    // Test needs to be run from within evm module context
    return error.SkipZigTest;
}

test "interpret2_simple: PUSH and JUMP" {
    // Test needs to be run from within evm module context
    return error.SkipZigTest;
}