const std = @import("std");
const primitives = @import("primitives");
const opcode = @import("../opcodes/opcode.zig");
const JumpTable = @import("../jump_table/jump_table.zig");
const ThreadedInstruction = @import("threaded_instruction.zig").ThreadedInstruction;
pub const ThreadedAnalysis = @import("threaded_instruction.zig").ThreadedAnalysis;
const InstructionArg = @import("threaded_instruction.zig").InstructionArg;
const InstructionMeta = @import("threaded_instruction.zig").InstructionMeta;
const BlockInfo = @import("threaded_instruction.zig").BlockInfo;
const threaded_ops = @import("../execution/threaded_ops.zig");
const Log = @import("../log.zig");

/// Block analyzer for tracking gas and stack requirements
const BlockAnalyzer = struct {
    gas_used: u32 = 0,
    stack_req: i32 = 0,
    stack_change: i32 = 0,
    stack_max_growth: i32 = 0,
    instruction_count: u32 = 0,
    
    fn addInstruction(self: *BlockAnalyzer, op: u8, operation: *const @import("../opcodes/operation.zig").Operation) void {
        const gas_cost: u32 = @intCast(operation.constant_gas);
        self.gas_used += gas_cost;
        
        // Update stack requirements
        const min_stack: i32 = @intCast(operation.min_stack);
        self.stack_req = @max(self.stack_req, min_stack - self.stack_change);
        
        // Calculate stack effect using proper opcode-specific logic
        const stack_effect = getStackChange(op);
        self.stack_change += stack_effect;
        self.stack_max_growth = @max(self.stack_max_growth, self.stack_change);
        self.instruction_count += 1;
        
        // Log.debug("Added instruction {x:0>2}: gas_cost={}, total_gas={}, min_stack={}, stack_effect={}", 
        //     .{op, gas_cost, self.gas_used, operation.min_stack, stack_effect});
    }
    
    fn finalize(self: *BlockAnalyzer) BlockInfo {
        // Log.debug("Finalizing block: gas_used={}, stack_req={}, stack_max_growth={}, instruction_count={}", 
        //     .{self.gas_used, self.stack_req, self.stack_max_growth, self.instruction_count});
        return BlockInfo{
            .gas_cost = self.gas_used,
            .stack_req = @intCast(@max(0, self.stack_req)),
            .stack_max_growth = @intCast(@max(0, self.stack_max_growth)),
        };
    }
    
    fn reset(self: *BlockAnalyzer) void {
        self.* = BlockAnalyzer{};
    }
    
    fn shouldSplit(self: *BlockAnalyzer) bool {
        // Split blocks at reasonable sizes for cache efficiency
        return self.instruction_count >= 32 or self.gas_used >= 10000;
    }
};

/// Analyze bytecode and create threaded instruction stream
pub fn analyzeThreaded(
    allocator: std.mem.Allocator,
    code: []const u8,
    code_hash: [32]u8,
    jump_table: *const JumpTable.JumpTable,
) !ThreadedAnalysis {
    _ = code_hash;
    
    var instructions = std.ArrayList(ThreadedInstruction).init(allocator);
    errdefer instructions.deinit();
    
    var push_values = std.ArrayList(u256).init(allocator);
    errdefer push_values.deinit();
    
    var jumpdest_map = std.AutoHashMap(u32, u32).init(allocator);
    errdefer jumpdest_map.deinit();
    
    var blocks = std.ArrayList(BlockInfo).init(allocator);
    errdefer blocks.deinit();
    
    var block_analyzer = BlockAnalyzer{};
    var i: usize = 0;
    var current_block_start: usize = 0;
    
    while (i < code.len) {
        const op = code[i];
        const operation = jump_table.table[op];
        
        // Check if we need to start a new block
        const needs_new_block = (op == @intFromEnum(opcode.Enum.JUMPDEST) or 
                                block_analyzer.shouldSplit()) and 
                                block_analyzer.instruction_count > 0;
        
        if (needs_new_block) {
            // Finalize current block
            const block_info = block_analyzer.finalize();
            try blocks.append(block_info);
            
            // Insert block begin instruction at the start of this block's instructions
            try instructions.insert(current_block_start, .{
                .exec_fn = threaded_ops.opx_beginblock_threaded,
                .arg = .{ .block_info = block_info },
                .meta = .{ .size = 0, .is_block_start = true },
            });
            
            block_analyzer.reset();
            current_block_start = instructions.items.len + 1; // +1 for the block begin we just inserted
        }
        
        // Record jump destination before processing the JUMPDEST
        if (op == @intFromEnum(opcode.Enum.JUMPDEST)) {
            try jumpdest_map.put(@intCast(i), @intCast(instructions.items.len));
        }
        
        // Build instruction based on opcode
        var instr = ThreadedInstruction{
            .exec_fn = threaded_ops.getThreadedFunction(op),
            .arg = .{ .none = {} },
            .meta = .{ .size = 1, .is_block_start = false },
        };
        
        // Extract arguments for specific opcodes
        switch (op) {
            @intFromEnum(opcode.Enum.PUSH1)...@intFromEnum(opcode.Enum.PUSH32) => {
                const push_size = op - @intFromEnum(opcode.Enum.PUSH1) + 1;
                instr.meta.size = @intCast(1 + push_size);
                
                if (i + push_size < code.len) {
                    if (push_size <= 8) {
                        // Small push - embed directly
                        var value: u64 = 0;
                        for (0..push_size) |j| {
                            if (i + 1 + j < code.len) {
                                value = (value << 8) | code[i + 1 + j];
                            }
                        }
                        instr.arg = .{ .small_push = value };
                        instr.exec_fn = threaded_ops.op_push_small_threaded;
                    } else {
                        // Large push - store separately
                        var value: u256 = 0;
                        for (0..push_size) |j| {
                            if (i + 1 + j < code.len) {
                                value = (value << 8) | code[i + 1 + j];
                            }
                        }
                        instr.arg = .{ .large_push_idx = @intCast(push_values.items.len) };
                        try push_values.append(value);
                        instr.exec_fn = threaded_ops.op_push_large_threaded;
                    }
                }
            },
            
            @intFromEnum(opcode.Enum.PC) => {
                instr.arg = .{ .pc_value = @intCast(i) };
                instr.exec_fn = threaded_ops.op_pc_threaded;
            },
            
            @intFromEnum(opcode.Enum.GAS) => {
                instr.arg = .{ .gas_correction = @intCast(block_analyzer.gas_used) };
                instr.exec_fn = threaded_ops.op_gas_threaded;
            },
            
            else => {},
        }
        
        // Update block analysis
        block_analyzer.addInstruction(op, operation);
        
        try instructions.append(instr);
        i += instr.meta.size;
    }
    
    // For empty code, don't add any instructions - just return empty analysis
    if (code.len == 0) {
        return ThreadedAnalysis{
            .instructions = try instructions.toOwnedSlice(),
            .push_values = try push_values.toOwnedSlice(),
            .jumpdest_map = jumpdest_map,
            .blocks = try blocks.toOwnedSlice(),
        };
    }
    
    // Finalize the last block if we have processed any instructions
    if (block_analyzer.instruction_count > 0) {
        const block_info = block_analyzer.finalize();
        try blocks.append(block_info);
        
        // Insert block begin instruction at the start of the last block
        try instructions.insert(current_block_start, .{
            .exec_fn = threaded_ops.opx_beginblock_threaded,
            .arg = .{ .block_info = block_info },
            .meta = .{ .size = 0, .is_block_start = true },
        });
    } else if (code.len == 0) {
        // For empty code, don't add any blocks
        return ThreadedAnalysis{
            .instructions = try instructions.toOwnedSlice(),
            .push_values = try push_values.toOwnedSlice(),
            .jumpdest_map = jumpdest_map,
            .blocks = try blocks.toOwnedSlice(),
        };
    }
    
    return ThreadedAnalysis{
        .instructions = try instructions.toOwnedSlice(),
        .push_values = try push_values.toOwnedSlice(),
        .jumpdest_map = jumpdest_map,
        .blocks = try blocks.toOwnedSlice(),
    };
}

/// Get the stack change for a given opcode
fn getStackChange(op: u8) i32 {
    return switch (op) {
        // Stack operations
        @intFromEnum(opcode.Enum.POP) => -1,
        @intFromEnum(opcode.Enum.PUSH0)...@intFromEnum(opcode.Enum.PUSH32) => 1,
        @intFromEnum(opcode.Enum.DUP1)...@intFromEnum(opcode.Enum.DUP16) => 1,
        @intFromEnum(opcode.Enum.SWAP1)...@intFromEnum(opcode.Enum.SWAP16) => 0,
        
        // Arithmetic operations
        @intFromEnum(opcode.Enum.ADD),
        @intFromEnum(opcode.Enum.MUL),
        @intFromEnum(opcode.Enum.SUB),
        @intFromEnum(opcode.Enum.DIV),
        @intFromEnum(opcode.Enum.SDIV),
        @intFromEnum(opcode.Enum.MOD),
        @intFromEnum(opcode.Enum.SMOD),
        @intFromEnum(opcode.Enum.EXP),
        @intFromEnum(opcode.Enum.SIGNEXTEND),
        => -1,
        
        @intFromEnum(opcode.Enum.ADDMOD),
        @intFromEnum(opcode.Enum.MULMOD),
        => -2,
        
        // Comparison operations
        @intFromEnum(opcode.Enum.LT),
        @intFromEnum(opcode.Enum.GT),
        @intFromEnum(opcode.Enum.SLT),
        @intFromEnum(opcode.Enum.SGT),
        @intFromEnum(opcode.Enum.EQ),
        => -1,
        
        @intFromEnum(opcode.Enum.ISZERO),
        @intFromEnum(opcode.Enum.NOT),
        => 0,
        
        // Bitwise operations
        @intFromEnum(opcode.Enum.AND),
        @intFromEnum(opcode.Enum.OR),
        @intFromEnum(opcode.Enum.XOR),
        @intFromEnum(opcode.Enum.BYTE),
        @intFromEnum(opcode.Enum.SHL),
        @intFromEnum(opcode.Enum.SHR),
        @intFromEnum(opcode.Enum.SAR),
        => -1,
        
        // Environmental operations
        @intFromEnum(opcode.Enum.ADDRESS),
        @intFromEnum(opcode.Enum.BALANCE),
        @intFromEnum(opcode.Enum.ORIGIN),
        @intFromEnum(opcode.Enum.CALLER),
        @intFromEnum(opcode.Enum.CALLVALUE),
        @intFromEnum(opcode.Enum.CALLDATASIZE),
        @intFromEnum(opcode.Enum.CODESIZE),
        @intFromEnum(opcode.Enum.GASPRICE),
        @intFromEnum(opcode.Enum.RETURNDATASIZE),
        @intFromEnum(opcode.Enum.COINBASE),
        @intFromEnum(opcode.Enum.TIMESTAMP),
        @intFromEnum(opcode.Enum.NUMBER),
        @intFromEnum(opcode.Enum.PREVRANDAO),
        @intFromEnum(opcode.Enum.GASLIMIT),
        @intFromEnum(opcode.Enum.CHAINID),
        @intFromEnum(opcode.Enum.SELFBALANCE),
        @intFromEnum(opcode.Enum.BASEFEE),
        @intFromEnum(opcode.Enum.BLOBBASEFEE),
        @intFromEnum(opcode.Enum.PC),
        @intFromEnum(opcode.Enum.MSIZE),
        @intFromEnum(opcode.Enum.GAS),
        => 1,
        
        @intFromEnum(opcode.Enum.BLOCKHASH),
        @intFromEnum(opcode.Enum.BLOBHASH),
        @intFromEnum(opcode.Enum.CALLDATALOAD),
        @intFromEnum(opcode.Enum.EXTCODESIZE),
        @intFromEnum(opcode.Enum.EXTCODEHASH),
        @intFromEnum(opcode.Enum.MLOAD),
        @intFromEnum(opcode.Enum.SLOAD),
        => 0,
        
        // Copy operations
        @intFromEnum(opcode.Enum.CALLDATACOPY),
        @intFromEnum(opcode.Enum.CODECOPY),
        @intFromEnum(opcode.Enum.RETURNDATACOPY),
        @intFromEnum(opcode.Enum.MCOPY),
        => -3,
        
        @intFromEnum(opcode.Enum.EXTCODECOPY) => -4,
        
        // Storage operations
        @intFromEnum(opcode.Enum.MSTORE),
        @intFromEnum(opcode.Enum.MSTORE8),
        @intFromEnum(opcode.Enum.SSTORE),
        => -2,
        
        // Flow control
        @intFromEnum(opcode.Enum.JUMP) => -1,
        @intFromEnum(opcode.Enum.JUMPI) => -2,
        @intFromEnum(opcode.Enum.JUMPDEST) => 0,
        
        // System operations
        @intFromEnum(opcode.Enum.CREATE) => -2,  // value, offset, size -> address
        @intFromEnum(opcode.Enum.CREATE2) => -3, // value, offset, size, salt -> address
        @intFromEnum(opcode.Enum.CALL),
        @intFromEnum(opcode.Enum.CALLCODE),
        => -6,  // gas, to, value, in_offset, in_size, out_offset, out_size -> success
        @intFromEnum(opcode.Enum.DELEGATECALL),
        @intFromEnum(opcode.Enum.STATICCALL),
        => -5,  // gas, to, in_offset, in_size, out_offset, out_size -> success
        
        // Terminating operations
        @intFromEnum(opcode.Enum.RETURN),
        @intFromEnum(opcode.Enum.REVERT),
        => -2,
        @intFromEnum(opcode.Enum.SELFDESTRUCT) => -1,
        @intFromEnum(opcode.Enum.STOP) => 0,
        
        // KECCAK256
        @intFromEnum(opcode.Enum.KECCAK256) => -1,
        
        // LOG operations
        @intFromEnum(opcode.Enum.LOG0) => -2,
        @intFromEnum(opcode.Enum.LOG1) => -3,
        @intFromEnum(opcode.Enum.LOG2) => -4,
        @intFromEnum(opcode.Enum.LOG3) => -5,
        @intFromEnum(opcode.Enum.LOG4) => -6,
        
        // Invalid or unknown opcodes
        else => 0,
    };
}