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

/// Duplicate stack item at position n
/// DUP1 (n=1) duplicates top, DUP2 (n=2) duplicates second, etc.
/// Returns StackUnderflow if stack has fewer than n items
/// Returns StackOverflow if stack is at capacity
pub fn dup_n(self: *Self, n: usize) Error!void {
    if (n == 0 or n > 16) {
        return Error.StackUnderflow; // Invalid n
    }
    if (self.items.items.len < n) {
        return Error.StackUnderflow;
    }
    if (self.items.items.len >= MAX_STACK_SIZE) {
        return Error.StackOverflow;
    }
    // Duplicate item at depth n (1-indexed from top)
    const value = self.items.items[self.items.items.len - n];
    self.items.append(self.allocator, value) catch return Error.AllocationError;
}

/// Swap top stack item with item at position n+1
/// SWAP1 (n=1) swaps top with second, SWAP2 (n=2) swaps top with third, etc.
/// Returns StackUnderflow if stack has n+1 or fewer items
pub fn swap_n(self: *Self, n: usize) Error!void {
    if (n == 0 or n > 16) {
        return Error.StackUnderflow; // Invalid n
    }
    if (self.items.items.len <= n) {
        return Error.StackUnderflow;
    }
    const top_idx = self.items.items.len - 1;
    const swap_idx = self.items.items.len - 1 - n;
    const temp = self.items.items[top_idx];
    self.items.items[top_idx] = self.items.items[swap_idx];
    self.items.items[swap_idx] = temp;
}
