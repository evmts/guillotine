const std = @import("std");
const Instruction = @import("instruction.zig").Instruction;
const Operation = @import("opcodes/operation.zig");
const ExecutionError = @import("execution/execution_error.zig");
const Opcode = @import("opcodes/opcode.zig");
const CodeAnalysis = @import("frame/code_analysis.zig");
const JumpTable = @import("jump_table/jump_table.zig").JumpTable;
const execution = @import("execution/package.zig");

/// Translates EVM bytecode into an instruction stream for block-based execution.
/// This is the core of the block-based execution model, converting traditional
/// bytecode into a stream of instructions that can be executed sequentially
/// without opcode dispatch overhead.
pub const InstructionTranslator = struct {
    allocator: std.mem.Allocator,
    code: []const u8,
    analysis: *const CodeAnalysis,
    instructions: []Instruction,
    instruction_count: usize,
    jump_table: *const JumpTable,
    
    const MAX_INSTRUCTIONS = @import("constants/instruction_limits.zig").MAX_INSTRUCTIONS;
    
    /// Initialize a new instruction translator.
    pub fn init(
        allocator: std.mem.Allocator,
        code: []const u8,
        analysis: *const CodeAnalysis,
        instructions: []Instruction,
        jump_table: *const JumpTable,
    ) InstructionTranslator {
        return .{
            .allocator = allocator,
            .code = code,
            .analysis = analysis,
            .instructions = instructions,
            .instruction_count = 0,
            .jump_table = jump_table,
        };
    }
    
    /// Translate bytecode into instruction stream.
    /// Returns the number of instructions created.
    pub fn translate_bytecode(self: *InstructionTranslator) !usize {
        var pc: usize = 0;
        
        while (pc < self.code.len) {
            if (self.instruction_count >= self.instructions.len) {
                return error.InstructionLimitExceeded;
            }
            
            const opcode_byte = self.code[pc];
            const opcode = @as(Opcode.Enum, @enumFromInt(opcode_byte));
            
            switch (opcode) {
                .STOP => {
                    self.instructions[self.instruction_count] = .{
                        .opcode_fn = self.jump_table.execute_funcs[opcode_byte],
                        .arg = .none,
                    };
                    self.instruction_count += 1;
                    pc += 1;
                },
                .PUSH0 => {
                    self.instructions[self.instruction_count] = .{
                        .opcode_fn = self.jump_table.execute_funcs[opcode_byte],
                        .arg = .{ .push_value = 0 },
                    };
                    self.instruction_count += 1;
                    pc += 1;
                },
                .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8,
                .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16,
                .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24,
                .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                    // Calculate how many bytes to read
                    const push_size = Opcode.get_push_size(opcode_byte);
                    
                    // Make sure we have enough bytes
                    if (pc + 1 + push_size > self.code.len) {
                        // If not enough bytes, pad with zeros (EVM behavior)
                        var value: u256 = 0;
                        const available = self.code.len - (pc + 1);
                        if (available > 0) {
                            // Read what we can
                            const bytes_to_read = @min(push_size, available);
                            var i: usize = 0;
                            while (i < bytes_to_read) : (i += 1) {
                                value = (value << 8) | self.code[pc + 1 + i];
                            }
                            // Shift left for any missing bytes
                            const missing_bytes = push_size - bytes_to_read;
                            if (missing_bytes > 0) {
                                value = value << (8 * missing_bytes);
                            }
                        }
                        self.instructions[self.instruction_count] = .{
                            .opcode_fn = self.jump_table.execute_funcs[opcode_byte],
                            .arg = .{ .push_value = value },
                        };
                        self.instruction_count += 1;
                        pc = self.code.len; // End of code
                    } else {
                        // Read the push value from bytecode
                        var value: u256 = 0;
                        var i: usize = 0;
                        while (i < push_size) : (i += 1) {
                            value = (value << 8) | self.code[pc + 1 + i];
                        }
                        
                        self.instructions[self.instruction_count] = .{
                            .opcode_fn = self.jump_table.execute_funcs[opcode_byte],
                            .arg = .{ .push_value = value },
                        };
                        self.instruction_count += 1;
                        pc += 1 + push_size;
                    }
                },
                // Arithmetic and comparison operations
                .ADD, .MUL, .SUB, .DIV, .SDIV, .MOD, .SMOD, 
                .ADDMOD, .MULMOD, .EXP, .SIGNEXTEND,
                .LT, .GT, .SLT, .SGT, .EQ, .ISZERO,
                .AND, .OR, .XOR, .NOT, .BYTE, .SHL, .SHR, .SAR,
                // Stack operations
                .POP, .DUP1, .DUP2, .DUP3, .DUP4, .DUP5, .DUP6, .DUP7, .DUP8,
                .DUP9, .DUP10, .DUP11, .DUP12, .DUP13, .DUP14, .DUP15, .DUP16,
                .SWAP1, .SWAP2, .SWAP3, .SWAP4, .SWAP5, .SWAP6, .SWAP7, .SWAP8,
                .SWAP9, .SWAP10, .SWAP11, .SWAP12, .SWAP13, .SWAP14, .SWAP15, .SWAP16,
                // Memory operations
                .MLOAD, .MSTORE, .MSTORE8, .MSIZE,
                // Storage operations
                .SLOAD, .SSTORE,
                // Environmental operations
                .ADDRESS, .BALANCE, .ORIGIN, .CALLER, .CALLVALUE,
                .CALLDATALOAD, .CALLDATASIZE, .CALLDATACOPY,
                .CODESIZE, .CODECOPY, .GASPRICE, .EXTCODESIZE, .EXTCODECOPY,
                .RETURNDATASIZE, .RETURNDATACOPY, .EXTCODEHASH,
                // Block operations
                .BLOCKHASH, .COINBASE, .TIMESTAMP, .NUMBER, .PREVRANDAO, .GASLIMIT,
                .CHAINID, .SELFBALANCE, .BASEFEE, .BLOBHASH, .BLOBBASEFEE,
                // Crypto operations
                .KECCAK256,
                // Log operations
                .LOG0, .LOG1, .LOG2, .LOG3, .LOG4,
                // System operations (except JUMP/JUMPI/CALL variants which need special handling)
                .RETURN, .REVERT, .INVALID, .PC, .GAS, .JUMPDEST,
                // Create operations (simple - no special args)
                .CREATE, .CREATE2, .SELFDESTRUCT,
                // Call operations (simple - no special args) 
                .CALL, .CALLCODE, .DELEGATECALL, .STATICCALL,
                // Other EIPs
                .MCOPY, .TLOAD, .TSTORE => {
                    self.instructions[self.instruction_count] = .{
                        .opcode_fn = self.jump_table.execute_funcs[opcode_byte],
                        .arg = .none,
                    };
                    self.instruction_count += 1;
                    pc += 1;
                },
                // Jump operations - for now just translate them without resolving targets
                // Jump target resolution will be done in a second pass
                .JUMP, .JUMPI => {
                    self.instructions[self.instruction_count] = .{
                        .opcode_fn = self.jump_table.execute_funcs[opcode_byte],
                        .arg = .none, // Will be updated with .jump_target in second pass
                    };
                    self.instruction_count += 1;
                    pc += 1;
                },
                else => {
                    // Check if it's an undefined opcode
                    if (self.jump_table.undefined_flags[opcode_byte]) {
                        // Treat undefined opcodes as INVALID
                        self.instructions[self.instruction_count] = .{
                            .opcode_fn = self.jump_table.execute_funcs[@intFromEnum(Opcode.Enum.INVALID)],
                            .arg = .none,
                        };
                        self.instruction_count += 1;
                        pc += 1;
                    } else {
                        // This should not happen if we've covered all opcodes
                        return error.OpcodeNotImplemented;
                    }
                },
            }
        }
        
        return self.instruction_count;
    }
    
};

// Tests moved to test/evm/instruction_test.zig to avoid circular dependencies