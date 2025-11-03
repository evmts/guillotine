/// Minimal Frame implementation for shared instruction implementations
/// Phase 1.1 - Foundation for instruction merge
/// This Frame provides a minimal interface that instruction implementations can use
const std = @import("std");
const Stack = @import("Stack.zig");

const Self = @This();

/// Error set that includes all possible instruction errors
pub const Error = error{
    // Stack errors
    StackOverflow,
    StackUnderflow,
    AllocationError,
    // Will be extended in future phases
};

/// The EVM stack
stack: Stack,

/// Initialize a minimal frame with an empty stack
pub fn init(allocator: std.mem.Allocator) Error!Self {
    const stack = try Stack.init(allocator);
    return Self{
        .stack = stack,
    };
}

/// Clean up frame resources
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.stack.deinit(allocator);
}
