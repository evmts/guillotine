const std = @import("std");
const Opcode = @import("../opcodes/opcode.zig").Enum;

/// Simple analysis result for tailcall dispatch with precomputed mappings
pub const SimpleAnalysis = struct {
    /// Mapping from instruction index to PC value
    inst_to_pc: []usize,
    /// Mapping from PC to instruction index (MAX_USIZE if not an instruction start)
    pc_to_inst: []usize,
    /// Reference to the original bytecode for reading push values
    bytecode: []const u8,
    /// Total number of instructions
    inst_count: usize,
    
    pub const MAX_USIZE: usize = std.math.maxInt(usize);
    
    pub fn deinit(self: *SimpleAnalysis, allocator: std.mem.Allocator) void {
        allocator.free(self.inst_to_pc);
        allocator.free(self.pc_to_inst);
    }
    
    /// Get the PC value for a given instruction index
    pub fn getPc(self: *const SimpleAnalysis, inst_idx: usize) usize {
        if (inst_idx >= self.inst_count) return MAX_USIZE;
        return self.inst_to_pc[inst_idx];
    }
    
    /// Get the instruction index for a given PC
    pub fn getInstIdx(self: *const SimpleAnalysis, pc: usize) usize {
        if (pc >= self.pc_to_inst.len) return MAX_USIZE;
        return self.pc_to_inst[pc];
    }
    
    /// Build analysis from bytecode
    pub fn analyze(allocator: std.mem.Allocator, code: []const u8) !SimpleAnalysis {
        var inst_to_pc_list = std.ArrayList(usize).init(allocator);
        defer inst_to_pc_list.deinit();
        
        var pc_to_inst = try allocator.alloc(usize, code.len);
        @memset(pc_to_inst, MAX_USIZE);
        
        var pc: usize = 0;
        var inst_idx: usize = 0;
        
        while (pc < code.len) {
            const byte = code[pc];
            
            // Record instruction start
            try inst_to_pc_list.append(pc);
            pc_to_inst[pc] = inst_idx;
            
            // Handle PUSH instructions
            if (byte >= 0x60 and byte <= 0x7F) {
                const push_size = byte - 0x5F;
                pc += 1 + push_size;
            } else if (byte == 0x5F) {
                // PUSH0
                pc += 1;
            } else {
                pc += 1;
            }
            
            inst_idx += 1;
        }
        
        return SimpleAnalysis{
            .inst_to_pc = try inst_to_pc_list.toOwnedSlice(),
            .pc_to_inst = pc_to_inst,
            .bytecode = code,
            .inst_count = inst_idx,
        };
    }
};