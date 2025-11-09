/// Shared Stack implementation for EVM frames
/// Provides a minimal interface that works with both guillotine-mini (ArrayList-based)
/// and guillotine (pointer-based downward stack)
const std = @import("std");

const Self = @This();

/// Error set for stack operations
pub const Error = error{
    StackOverflow,
    StackUnderflow,
    AllocationError,
};

/// Maximum stack depth per EVM spec
pub const MAX_STACK_SIZE: usize = 1024;

/// Internal storage using ArrayList (Zig 0.15.1 unmanaged API)
items: std.ArrayList(u256),
allocator: std.mem.Allocator,

/// Initialize an empty stack
pub fn init(allocator: std.mem.Allocator) Error!Self {
    var list = std.ArrayList(u256){};
    list.ensureTotalCapacity(allocator, MAX_STACK_SIZE) catch return Error.AllocationError;
    return Self{
        .items = list,
        .allocator = allocator,
    };
}

/// Clean up stack resources
pub fn deinit(self: *Self, _: std.mem.Allocator) void {
    self.items.deinit(self.allocator);
}

/// Get current stack size
pub fn len(self: *const Self) usize {
    return self.items.items.len;
}

/// Push a value onto the stack
/// Returns StackOverflow if stack is at capacity
pub fn push(self: *Self, value: u256) Error!void {
    if (self.items.items.len >= MAX_STACK_SIZE) {
        return Error.StackOverflow;
    }
    self.items.append(self.allocator, value) catch return Error.AllocationError;
}

/// Pop a value from the stack
/// Returns StackUnderflow if stack is empty
pub fn pop(self: *Self) Error!u256 {
    if (self.items.items.len == 0) {
        return Error.StackUnderflow;
    }
    const value = self.items.items[self.items.items.len - 1];
    self.items.items.len -= 1;
    return value;
}

/// Peek at the top of the stack without removing it
/// Returns StackUnderflow if stack is empty
pub fn peek(self: *const Self) Error!u256 {
    if (self.items.items.len == 0) {
        return Error.StackUnderflow;
    }
    return self.items.items[self.items.items.len - 1];
}

/// Set the value at the top of the stack
/// Returns StackUnderflow if stack is empty
pub fn set_top(self: *Self, value: u256) Error!void {
    if (self.items.items.len == 0) {
        return Error.StackUnderflow;
    }
    self.items.items[self.items.items.len - 1] = value;
}
