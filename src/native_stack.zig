//! Bounds of the calling thread's native stack.
//!
//! The EVM interpreter recurses once per call depth. Knowing where the native stack
//! ends lets the EVM run a transaction on the caller's stack and move to a dedicated
//! large stack only when a call chain is deep enough to need it.
const std = @import("std");
const builtin = @import("builtin");

/// True when `lowAddress` can report the stack bounds on this target.
pub const supported = builtin.link_libc and (builtin.os.tag == .linux or builtin.os.tag.isDarwin());

extern "c" fn pthread_getattr_np(thread: std.c.pthread_t, attr: *std.c.pthread_attr_t) c_int;
extern "c" fn pthread_attr_getstack(attr: *const std.c.pthread_attr_t, stack_address: *?*anyopaque, stack_size: *usize) c_int;
extern "c" fn pthread_get_stackaddr_np(thread: std.c.pthread_t) ?*anyopaque;
extern "c" fn pthread_get_stacksize_np(thread: std.c.pthread_t) usize;

/// The main thread's bounds never change, and glibc computes them by parsing
/// /proc/self/maps, so they are queried once. Zero means not yet known.
var main_thread_low: std.atomic.Value(usize) = .init(0);

/// Lowest address of the calling thread's stack, or null when it cannot be determined.
pub fn lowAddress() ?usize {
    if (comptime !supported) return null;
    if (comptime builtin.os.tag.isDarwin()) {
        const thread = std.c.pthread_self();
        const top = @intFromPtr(pthread_get_stackaddr_np(thread) orelse return null);
        const size = pthread_get_stacksize_np(thread);
        if (size == 0 or size > top) return null;
        return top - size;
    }

    const is_main_thread = std.os.linux.gettid() == std.os.linux.getpid();
    if (is_main_thread) {
        const cached = main_thread_low.load(.monotonic);
        if (cached != 0) return cached;
    }
    const low = queryLinux() orelse return null;
    if (is_main_thread) main_thread_low.store(low, .monotonic);
    return low;
}

fn queryLinux() ?usize {
    var attr: std.c.pthread_attr_t = undefined;
    if (pthread_getattr_np(std.c.pthread_self(), &attr) != 0) return null;
    defer _ = std.c.pthread_attr_destroy(&attr);
    var stack_address: ?*anyopaque = null;
    var stack_size: usize = 0;
    if (pthread_attr_getstack(&attr, &stack_address, &stack_size) != 0) return null;
    const low = @intFromPtr(stack_address orelse return null);
    if (stack_size == 0) return null;
    return low;
}

test "the current frame lies above the reported stack low address" {
    if (!supported) return;
    const low = lowAddress() orelse return error.TestUnexpectedResult;
    const here = @frameAddress();
    try std.testing.expect(here > low);
    // No thread stack in practice is larger than 1 GiB.
    try std.testing.expect(here - low < 1024 * 1024 * 1024);
    try std.testing.expectEqual(low, lowAddress().?);
}
