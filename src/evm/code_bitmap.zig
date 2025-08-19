const std = @import("std");
const DynamicBitSet = std.DynamicBitSet;
const Opcode = @import("opcodes/opcode.zig");
const limits = @import("constants/code_analysis_limits.zig");

/// Creates a code bitmap that marks which bytes are opcodes vs data.
pub fn createCodeBitmap(allocator: std.mem.Allocator, code: []const u8) !DynamicBitSet {
    std.debug.assert(code.len <= limits.MAX_CONTRACT_SIZE);

    // MEMORY ALLOCATION: Temporary code bitmap
    // Expected size: code_len bits
    // Lifetime: During analysis only (freed by caller)
    // Frequency: Once per analysis
    var bitmap = try DynamicBitSet.initFull(allocator, code.len);
    errdefer bitmap.deinit();

    var i: usize = 0;
    while (i < code.len) {
        const op = code[i];

        // If the opcode is a PUSH, mark pushed bytes as data (not code)
        if (Opcode.is_push(op)) {
            const push_bytes = Opcode.get_push_size(op);
            var j: usize = 1;
            while (j <= push_bytes and i + j < code.len) : (j += 1) {
                bitmap.unset(i + j);
            }
            i += 1 + push_bytes;
        } else {
            i += 1;
        }
    }

    return bitmap;
}