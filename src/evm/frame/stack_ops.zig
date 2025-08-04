const std = @import("std");
const Frame = @import("frame_fat.zig");

/// Stack error types
pub const StackError = error{
    StackOverflow,
    StackUnderflow,
};

/// Maximum stack capacity as defined by the EVM specification.
pub const STACK_CAPACITY: usize = 1024;

// ============================================================================
// SAFE STACK OPERATIONS (with bounds checking)
// ============================================================================

/// Push a value onto the stack (safe version).
///
/// @param self The frame containing the stack
/// @param value The 256-bit value to push
/// @throws StackOverflow if stack is at capacity
pub fn stack_push(self: *Frame, value: u256) StackError!void {
    if (self.stack_size >= STACK_CAPACITY) {
        @branchHint(.cold);
        return StackError.StackOverflow;
    }
    self.stack_data[self.stack_size] = value;
    self.stack_size += 1;
}

/// Pop a value from the stack (safe version).
///
/// Removes and returns the top element. Clears the popped
/// slot to prevent information leakage.
///
/// @param self The frame containing the stack
/// @return The popped value
/// @throws StackUnderflow if stack is empty
pub fn stack_pop(self: *Frame) StackError!u256 {
    if (self.stack_size == 0) {
        @branchHint(.cold);
        return StackError.StackUnderflow;
    }
    self.stack_size -= 1;
    const value = self.stack_data[self.stack_size];
    self.stack_data[self.stack_size] = 0;
    return value;
}

/// Peek at the top value without removing it.
///
/// @param self The frame containing the stack
/// @return The top value
/// @throws StackUnderflow if stack is empty
pub fn stack_peek(self: *const Frame) StackError!u256 {
    if (self.stack_size == 0) {
        @branchHint(.cold);
        return StackError.StackUnderflow;
    }
    return self.stack_data[self.stack_size - 1];
}

/// Peek at the nth element from the top.
///
/// @param self The frame containing the stack
/// @param n Position from top (0 = top element)
/// @return The value at position n from top
/// @throws StackUnderflow if n >= stack size
pub fn stack_peek_n(self: *const Frame, n: usize) StackError!u256 {
    if (n >= self.stack_size) {
        @branchHint(.cold);
        return StackError.StackUnderflow;
    }
    return self.stack_data[self.stack_size - 1 - n];
}

/// Clear the stack.
///
/// Zeros out all data for security and resets size to 0.
///
/// @param self The frame containing the stack
pub fn stack_clear(self: *Frame) void {
    self.stack_size = 0;
    @memset(self.stack_data[0..STACK_CAPACITY], 0);
}

// ============================================================================
// UNSAFE STACK OPERATIONS (no bounds checking, for hot paths)
// ============================================================================

/// Push a value onto the stack (unsafe version).
///
/// Caller must ensure stack has capacity. Used in hot paths
/// after validation has already been performed.
///
/// @param self The frame containing the stack
/// @param value The 256-bit value to push
pub fn stack_push_unsafe(self: *Frame, value: u256) void {
    @branchHint(.likely);
    self.stack_data[self.stack_size] = value;
    self.stack_size += 1;
}

/// Pop a value from the stack (unsafe version).
///
/// Caller must ensure stack is not empty. Used in hot paths
/// after validation.
///
/// @param self The frame containing the stack
/// @return The popped value
pub fn stack_pop_unsafe(self: *Frame) u256 {
    @branchHint(.likely);
    self.stack_size -= 1;
    const value = self.stack_data[self.stack_size];
    self.stack_data[self.stack_size] = 0;
    return value;
}

/// Peek at the top value without removing it (unsafe version).
///
/// Caller must ensure stack is not empty.
///
/// @param self The frame containing the stack
/// @return Pointer to the top value
pub fn stack_peek_unsafe(self: *const Frame) *const u256 {
    @branchHint(.likely);
    return &self.stack_data[self.stack_size - 1];
}

/// Set the top stack value (unsafe version).
///
/// Caller must ensure stack is not empty.
///
/// @param self The frame containing the stack
/// @param value The value to set at the top
pub fn stack_set_top_unsafe(self: *Frame, value: u256) void {
    @branchHint(.likely);
    self.stack_data[self.stack_size - 1] = value;
}

/// Duplicate the nth element onto the top of stack (unsafe version).
///
/// Caller must ensure:
/// - Stack has at least n elements
/// - Stack has capacity for one more element
///
/// @param self The frame containing the stack
/// @param n Position to duplicate from (1-16)
pub fn stack_dup_unsafe(self: *Frame, n: usize) void {
    @branchHint(.likely);
    @setRuntimeSafety(false);
    self.stack_push_unsafe(self.stack_data[self.stack_size - n]);
}

/// Swap the top element with the nth element below it (unsafe version).
///
/// Swaps the top stack element with the element n positions below it.
/// For SWAP1, n=1 swaps top with second element.
/// For SWAP2, n=2 swaps top with third element, etc.
///
/// Caller must ensure stack has at least n+1 elements.
///
/// @param self The frame containing the stack
/// @param n Position below top to swap with (1-16)
pub fn stack_swap_unsafe(self: *Frame, n: usize) void {
    @branchHint(.likely);
    std.mem.swap(u256, &self.stack_data[self.stack_size - 1], &self.stack_data[self.stack_size - 1 - n]);
}

/// Pop 2 values without pushing (unsafe version).
///
/// Caller must ensure stack has at least 2 elements.
///
/// @param self The frame containing the stack
/// @return Struct with .a (bottom) and .b (top) values
pub fn stack_pop2_unsafe(self: *Frame) struct { a: u256, b: u256 } {
    @branchHint(.likely);
    @setRuntimeSafety(false);
    const new_size = self.stack_size - 2;
    const a = self.stack_data[new_size];
    const b = self.stack_data[new_size + 1];
    self.stack_size = new_size;
    return .{ .a = a, .b = b };
}

/// Pop 3 values without pushing (unsafe version).
///
/// Caller must ensure stack has at least 3 elements.
///
/// @param self The frame containing the stack
/// @return Struct with .a (bottom), .b (middle), and .c (top) values
pub fn stack_pop3_unsafe(self: *Frame) struct { a: u256, b: u256, c: u256 } {
    @branchHint(.likely);
    @setRuntimeSafety(false);
    self.stack_size -= 3;
    return .{
        .a = self.stack_data[self.stack_size],
        .b = self.stack_data[self.stack_size + 1],
        .c = self.stack_data[self.stack_size + 2],
    };
}