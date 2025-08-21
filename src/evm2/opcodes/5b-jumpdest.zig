const std = @import("std");
const opcode_data = @import("../opcode_data.zig");

pub const Op5B = struct {
    /// Performs static analysis starting from JUMPDEST
    /// Returns total static gas cost and validates stack requirements
    pub fn analyzeBasicBlock(bytecode: []const u8, start_pc: usize) !struct { gas_cost: i64, max_stack_height: u16 } {
        const opcode_info = opcode_data.OPCODE_INFO;
        var pc = start_pc;
        var total_gas: i64 = 0;
        var stack_height: i32 = 0;
        var max_stack_height: u16 = 0;
        
        // If starting at JUMPDEST, consume its gas and skip it
        if (pc < bytecode.len and bytecode[pc] == 0x5B) {
            total_gas -= 1; // JUMPDEST costs 1 gas
            pc += 1;
        }
        
        while (pc < bytecode.len) {
            const opcode = bytecode[pc];
            const info = opcode_info[opcode];
            
            // Check if opcode is undefined
            if (@as(std.builtin.BranchHint, .cold) == .cold and info.is_undefined) {
                return error.InvalidOpcode;
            }
            
            // Update gas cost
            total_gas -= @intCast(info.gas_cost);
            
            // Update stack height
            const min_required = opcode_data.getMinStackRequired(opcode);
            if (@as(std.builtin.BranchHint, .cold) == .cold and stack_height < min_required) {
                return error.StackUnderflow;
            }
            
            // Apply stack changes
            stack_height -= info.stack_inputs;
            stack_height += info.stack_outputs;
            
            // Check stack overflow
            if (@as(std.builtin.BranchHint, .cold) == .cold and stack_height > 1024) {
                return error.StackOverflow;
            }
            
            // Track max stack height
            if (stack_height > max_stack_height) {
                max_stack_height = @intCast(stack_height);
            }
            
            // Handle special cases
            switch (opcode) {
                // STOP, RETURN, REVERT, INVALID, SELFDESTRUCT - block terminators
                0x00, 0xf3, 0xfd, 0xfe, 0xff => break,
                
                // JUMP - unconditional jump, end of basic block
                0x56 => {
                    pc += 1;
                    break;
                },
                
                // JUMPI - conditional jump, end of basic block
                0x57 => {
                    pc += 1;
                    break;
                },
                
                // PUSH operations - skip immediate data
                0x60...0x7f => {
                    const push_size = opcode - 0x5f;
                    pc += push_size;
                },
                
                else => {},
            }
            
            pc += 1;
        }
        
        return .{
            .gas_cost = total_gas,
            .max_stack_height = max_stack_height,
        };
    }
    
    test "analyzeBasicBlock simple arithmetic" {
        // JUMPDEST, PUSH1 5, PUSH1 10, ADD, POP, STOP
        const bytecode = [_]u8{ 0x5b, 0x60, 0x05, 0x60, 0x0a, 0x01, 0x50, 0x00 };
        
        const result = try analyzeBasicBlock(&bytecode, 0);
        
        // Gas costs: JUMPDEST(1) + PUSH1(3) + PUSH1(3) + ADD(3) + POP(2) + STOP(0) = 12
        try std.testing.expectEqual(@as(i64, -12), result.gas_cost);
        try std.testing.expectEqual(@as(u16, 2), result.max_stack_height);
    }
    
    test "analyzeBasicBlock stack underflow" {
        // JUMPDEST, ADD (requires 2 items but stack is empty)
        const bytecode = [_]u8{ 0x5b, 0x01 };
        
        try std.testing.expectError(error.StackUnderflow, analyzeBasicBlock(&bytecode, 0));
    }
    
    test "analyzeBasicBlock ends at jump" {
        // JUMPDEST, PUSH1 4, JUMP, PUSH1 99 (should not be analyzed)
        const bytecode = [_]u8{ 0x5b, 0x60, 0x04, 0x56, 0x60, 0x63 };
        
        const result = try analyzeBasicBlock(&bytecode, 0);
        
        // Gas costs: JUMPDEST(1) + PUSH1(3) + JUMP(8) = 12
        try std.testing.expectEqual(@as(i64, -12), result.gas_cost);
        try std.testing.expectEqual(@as(u16, 1), result.max_stack_height);
    }
    
    test "analyzeBasicBlock invalid opcode" {
        // JUMPDEST, 0x0c (invalid opcode)
        const bytecode = [_]u8{ 0x5b, 0x0c };
        
        try std.testing.expectError(error.InvalidOpcode, analyzeBasicBlock(&bytecode, 0));
    }
};