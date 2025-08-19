const Memory = @import("./memory.zig").Memory;
const context = @import("context.zig");

/// Get a mutable slice to the entire memory buffer (context-relative)
pub fn slice(self: *const Memory) []u8 {
    const ctx_size = self.context_size();
    const abs_start = self.my_checkpoint;
    const abs_end = @min(abs_start + ctx_size, self.shared_buffer_ref.items.len);
    return self.shared_buffer_ref.items[abs_start..abs_end];
}
