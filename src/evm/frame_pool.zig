const std = @import("std");
const Frame = @import("stack_frame.zig").StackFrame;

/// Simple frame pool scaffold to enable future slab/mmap-backed allocation.
///
/// Current behavior: acquire() creates a fresh Frame pointer, release() deinitializes
/// and destroys it. This preserves existing allocation behavior while providing
/// a central place to introduce pooling/mmap without touching call sites.
pub const FramePool = struct {
    allocator: std.mem.Allocator,
    // Freelist reserved for future pooling; unused for now
    free_list: std.ArrayList(*Frame),

    pub fn init(allocator: std.mem.Allocator, max_frames: usize) !FramePool {
        _ = max_frames; // reserved for future pre-sizing
        return FramePool{
            .allocator = allocator,
            .free_list = std.ArrayList(*Frame).init(allocator),
        };
    }

    pub fn deinit(self: *FramePool) void {
        // Drain freelist (frames are expected to be deinitialized before being pooled)
        for (self.free_list.items) |f| {
            // Best-effort destroy
            self.allocator.destroy(f);
        }
        self.free_list.deinit();
    }

    /// Acquire a new Frame pointer. The returned frame is uninitialized memory; callers
    /// should assign with a fully-initialized Frame value (e.g., from Frame.init(...)).
    pub fn acquire(self: *FramePool) !*Frame {
        // In a future iteration, pop from free_list if available
        return self.allocator.create(Frame);
    }

    /// Release a Frame pointer back to the pool. This function assumes the caller has
    /// already called frame.deinit(allocator) to release owned resources.
    pub fn release(self: *FramePool, frame_ptr: *Frame) void {
        // In a future iteration, push to free_list for reuse rather than destroy
        self.allocator.destroy(frame_ptr);
    }
};
