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
    // Bytecode errors
    InvalidPush,
    // Will be extended in future phases
};

/// The EVM stack
stack: Stack,

/// Bytecode (for PUSH operations)
/// Can be empty slice for frames that don't need bytecode access
bytecode: []const u8,

/// Program counter (for PUSH operations)
/// Instructions should NOT modify this - only used for reading immediate values
pc: u32,

/// Initialize a minimal frame with an empty stack
pub fn init(allocator: std.mem.Allocator) Error!Self {
    const stack = try Stack.init(allocator);
    return Self{
        .stack = stack,
        .bytecode = &[_]u8{},
        .pc = 0,
    };
}

/// Initialize a frame with bytecode (for PUSH operations)
pub fn initWithBytecode(allocator: std.mem.Allocator, bytecode: []const u8, pc: u32) Error!Self {
    const stack = try Stack.init(allocator);
    return Self{
        .stack = stack,
        .bytecode = bytecode,
        .pc = pc,
    };
}

/// Clean up frame resources
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.stack.deinit(allocator);
}

/// Read immediate data for PUSH operations
/// Returns null if not enough bytes available
pub fn readImmediate(self: *const Self, size: u8) ?u256 {
    if (size == 0) return 0; // PUSH0
    const start = self.pc + 1; // Skip opcode byte
    const end = start + size;
    if (end > self.bytecode.len) return null; // Not enough bytes

    var value: u256 = 0;
    var i: usize = 0;
    while (i < size) : (i += 1) {
        value = (value << 8) | @as(u256, self.bytecode[start + i]);
    }
    return value;
}
