const std = @import("std");
const Opcode = @import("../opcodes/opcode.zig").Enum;

/// Simple analysis result for tailcall dispatch with precomputed mappings
pub const SimpleAnalysis = struct {
    /// Mapping from instruction index to PC value
    inst_to_pc: []u16,
    /// Mapping from PC to instruction index (MAX_USIZE if not an instruction start)
    pc_to_inst: []u16,
    /// Reference to the original bytecode for reading push values
    bytecode: []const u8,
    /// Total number of instructions
    inst_count: u16,

    pub const MAX_USIZE: u16 = std.math.maxInt(u16);

    pub fn deinit(self: *SimpleAnalysis, allocator: std.mem.Allocator) void {
        allocator.free(self.inst_to_pc);
        allocator.free(self.pc_to_inst);
    }

    /// Get the PC value for a given instruction index
    pub fn getPc(self: *const SimpleAnalysis, inst_idx: u16) u16 {
        return self.inst_to_pc[inst_idx];
    }

    /// Get the instruction index for a given PC
    pub fn getInstIdx(self: *const SimpleAnalysis, pc: u16) u16 {
        return self.pc_to_inst[pc];
    }

    /// Build analysis from bytecode and return metadata separately
    pub fn analyze(allocator: std.mem.Allocator, code: []const u8) !struct { analysis: SimpleAnalysis, metadata: []u32 } {
        if (code.len > std.math.maxInt(u16)) return error.OutOfMemory; // enforce u16 bounds
        var inst_to_pc_list = std.ArrayList(u16).init(allocator);
        defer inst_to_pc_list.deinit();

        var metadata_list = std.ArrayList(u32).init(allocator);
        defer metadata_list.deinit();

        var pc_to_inst = try allocator.alloc(u16, code.len);
        @memset(pc_to_inst, MAX_USIZE);

        var pc: u16 = 0;
        var inst_idx: u16 = 0;

        while (pc < code.len) {
            const byte = code[pc];

            // Record instruction start
            try inst_to_pc_list.append(pc);
            pc_to_inst[pc] = inst_idx;

            // Build metadata for this instruction
            if (byte >= 0x60 and byte <= 0x7F) {
                // PUSH1-PUSH32
                const push_size = byte - 0x5F;

                // Metadata usage pattern:
                // - Small pushes (PUSH1-4): store the immediate value directly when fully available
                //   This avoids an extra bytecode read at runtime for the hot path
                // - Larger pushes (PUSH5-32): store the PC to read the value on demand
                // - Truncated small pushes: store PC so runtime can fall back to generic path
                if (push_size <= 4 and @as(usize, pc) + 1 + push_size <= code.len) {
                    var value: u32 = 0;
                    var i: usize = 0;
                    while (i < push_size) : (i += 1) {
                        value = (value << 8) | code[@as(usize, pc) + 1 + i];
                    }
                    try metadata_list.append(value);
                } else {
                    try metadata_list.append(@intCast(pc));
                }

                pc += 1 + push_size;
            } else if (byte == 0x5F) {
                // PUSH0 - store 0 directly
                try metadata_list.append(0);
                pc += 1;
            } else if (byte == 0x58) {
                // PC opcode - store the PC value
                try metadata_list.append(@intCast(pc));
                pc += 1;
            } else {
                // Other opcodes - no metadata needed
                try metadata_list.append(0);
                pc += 1;
            }

            inst_idx += 1;
        }

        return .{
            .analysis = SimpleAnalysis{
                .inst_to_pc = try inst_to_pc_list.toOwnedSlice(),
                .pc_to_inst = pc_to_inst,
                .bytecode = code,
                .inst_count = inst_idx,
            },
            .metadata = try metadata_list.toOwnedSlice(),
        };
    }
};

test "analysis2: PUSH small value bounds check and metadata" {
    const allocator = std.testing.allocator;
    // PUSH1 0xAA; STOP
    const code = &[_]u8{ 0x60, 0xAA, 0x00 };
    var result = try SimpleAnalysis.analyze(allocator, code);
    defer result.analysis.deinit(allocator);
    defer allocator.free(result.metadata);
    try std.testing.expectEqual(@as(u16, 0), result.analysis.getInstIdx(0));
    try std.testing.expectEqual(@as(u16, 1), result.analysis.getInstIdx(1));
    try std.testing.expectEqual(@as(u16, 2), result.analysis.getInstIdx(2));
    // First instruction is PUSH1: metadata should store value 0xAA
    try std.testing.expectEqual(@as(u32, 0xAA), result.metadata[0]);
}

test "analysis2: PUSH0 metadata and length" {
    const allocator = std.testing.allocator;
    // PUSH0; STOP
    const code = &[_]u8{ 0x5F, 0x00 };
    var result = try SimpleAnalysis.analyze(allocator, code);
    defer result.analysis.deinit(allocator);
    defer allocator.free(result.metadata);
    // Two instructions
    try std.testing.expectEqual(@as(u16, 2), result.analysis.inst_count);
    // First is PUSH0 -> metadata 0
    try std.testing.expectEqual(@as(u32, 0), result.metadata[0]);
}
