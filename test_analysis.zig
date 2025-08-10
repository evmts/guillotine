const std = @import("std");
const CodeAnalysis = @import("src/evm/frame/code_analysis.zig");

pub fn main() !void {
    const code = &[_]u8{0x00}; // Simple STOP opcode
    const analysis = try CodeAnalysis.analyze_bytecode_blocks(code);
    _ = analysis;
    std.debug.print("Analysis completed successfully\n", .{});
}
