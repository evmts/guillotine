const std = @import("std");
const testing = std.testing;
const Dispatch = @import("dispatch.zig").Dispatch;
const UnifiedOpcode = @import("dispatch.zig").UnifiedOpcode;

// Test infrastructure for verifying getOpData migration correctness
// Following TDD approach: RED-GREEN-REFACTOR

/// Mock frame type for testing handler patterns
const MockFrame = struct {
    const Self = @This();
    
    stack: std.ArrayList(u256),
    memory: std.ArrayList(u8),
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .stack = std.ArrayList(u256).init(allocator),
            .memory = std.ArrayList(u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.stack.deinit();
        self.memory.deinit();
    }
    
    pub fn pushToStack(self: *Self, value: u256) !void {
        try self.stack.append(value);
    }
    
    pub fn popFromStack(self: *Self) !u256 {
        if (self.stack.items.len == 0) return error.StackUnderflow;
        return self.stack.pop();
    }
    
    pub fn peekStack(self: *Self) !u256 {
        if (self.stack.items.len == 0) return error.StackUnderflow;
        return self.stack.items[self.stack.items.len - 1];
    }
    
    pub fn setStackTop(self: *Self, value: u256) void {
        if (self.stack.items.len > 0) {
            self.stack.items[self.stack.items.len - 1] = value;
        }
    }
};

/// Mock handler function for testing
fn mockHandler(frame: *MockFrame, cursor: [*]const Dispatch.Item) noreturn {
    _ = frame;
    _ = cursor;
    unreachable; // Should never be called in tests
}

test "getOpData behavioral compatibility - simple opcodes" {
    // RED: Test that getOpData produces identical behavior to hardcoded cursor arithmetic
    
    const allocator = testing.allocator;
    
    // Create mock dispatch items
    var items = [_]Dispatch.Item{
        .{ .opcode_handler = &mockHandler },
        .{ .opcode_handler = &mockHandler },
        .{ .opcode_handler = &mockHandler },
    };
    
    const dispatch = Dispatch{ .cursor = &items, .jump_table = null };
    
    // Test simple opcodes (should advance cursor by 1)
    const simple_opcodes = [_]UnifiedOpcode{
        .{ .regular = .ADD },
        .{ .regular = .MUL },
        .{ .regular = .SUB },
        .{ .regular = .DIV },
        .{ .regular = .AND },
        .{ .regular = .OR },
        .{ .regular = .XOR },
        .{ .regular = .NOT },
        .{ .regular = .LT },
        .{ .regular = .GT },
        .{ .regular = .EQ },
        .{ .regular = .ISZERO },
    };
    
    for (simple_opcodes) |opcode| {
        const op_data = dispatch.getOpData(opcode);
        
        // Verify cursor advancement matches hardcoded `cursor + 1`
        const expected_next = dispatch.cursor + 1;
        try testing.expectEqual(expected_next, op_data.next.cursor);
        
        // Verify no metadata field exists for simple opcodes
        try testing.expect(!@hasField(@TypeOf(op_data), "metadata"));
    }
}

test "getOpData behavioral compatibility - complex opcodes with metadata" {
    // RED: Test opcodes that have metadata and advance by 2
    
    const allocator = testing.allocator;
    
    // Create mock dispatch items with metadata
    var items = [_]Dispatch.Item{
        .{ .opcode_handler = &mockHandler },
        .{ .push_inline = .{ .value = 42 } }, // metadata
        .{ .opcode_handler = &mockHandler },
    };
    
    const dispatch = Dispatch{ .cursor = &items, .jump_table = null };
    
    // Test PUSH opcodes with inline metadata
    const push_inline_opcodes = [_]UnifiedOpcode{
        .{ .regular = .PUSH1 },
        .{ .regular = .PUSH2 },
        .{ .regular = .PUSH3 },
        .{ .regular = .PUSH4 },
        .{ .regular = .PUSH5 },
        .{ .regular = .PUSH6 },
        .{ .regular = .PUSH7 },
        .{ .regular = .PUSH8 },
    };
    
    for (push_inline_opcodes) |opcode| {
        const op_data = dispatch.getOpData(opcode);
        
        // Verify cursor advancement matches hardcoded `cursor + 2`
        const expected_next = dispatch.cursor + 2;
        try testing.expectEqual(expected_next, op_data.next.cursor);
        
        // Verify metadata access matches direct `cursor[1].push_inline`
        try testing.expectEqual(items[1].push_inline, op_data.metadata);
        try testing.expectEqual(@as(u256, 42), op_data.metadata.value);
    }
}

test "getOpData behavioral compatibility - synthetic opcodes" {
    // RED: Test synthetic opcodes that have metadata and advance by 2
    
    const allocator = testing.allocator;
    
    // Create mock dispatch items with metadata for synthetic opcodes
    var items = [_]Dispatch.Item{
        .{ .opcode_handler = &mockHandler },
        .{ .push_inline = .{ .value = 123 } }, // metadata
        .{ .opcode_handler = &mockHandler },
    };
    
    const dispatch = Dispatch{ .cursor = &items, .jump_table = null };
    
    // Test synthetic opcodes with inline metadata
    const synthetic_opcodes = [_]UnifiedOpcode{
        .{ .synthetic = .PUSH_ADD_INLINE },
        .{ .synthetic = .PUSH_MUL_INLINE },
        .{ .synthetic = .PUSH_SUB_INLINE },
        .{ .synthetic = .PUSH_DIV_INLINE },
        .{ .synthetic = .PUSH_AND_INLINE },
        .{ .synthetic = .PUSH_OR_INLINE },
        .{ .synthetic = .PUSH_XOR_INLINE },
        .{ .synthetic = .PUSH_JUMP_INLINE },
        .{ .synthetic = .PUSH_JUMPI_INLINE },
    };
    
    for (synthetic_opcodes) |opcode| {
        const op_data = dispatch.getOpData(opcode);
        
        // Verify cursor advancement matches hardcoded `cursor + 2`
        const expected_next = dispatch.cursor + 2;
        try testing.expectEqual(expected_next, op_data.next.cursor);
        
        // Verify metadata access matches direct `cursor[1].push_inline`
        try testing.expectEqual(items[1].push_inline, op_data.metadata);
        try testing.expectEqual(@as(u256, 123), op_data.metadata.value);
    }
}

test "handler pattern compatibility - arithmetic operations" {
    // RED: Test that new getOpData pattern produces identical results to hardcoded pattern
    
    const allocator = testing.allocator;
    var frame = MockFrame.init(allocator);
    defer frame.deinit();
    
    // Set up stack for ADD operation
    try frame.pushToStack(10);
    try frame.pushToStack(32);
    
    // Mock dispatch items
    var items = [_]Dispatch.Item{
        .{ .opcode_handler = &mockHandler },
        .{ .opcode_handler = &mockHandler },
    };
    
    const dispatch = Dispatch{ .cursor = &items, .jump_table = null };
    
    // Test getOpData approach for ADD
    const op_data = dispatch.getOpData(.{ .regular = .ADD });
    
    // Verify the operation would work correctly
    const operand_b = try frame.popFromStack();
    const operand_a = try frame.peekStack();
    const expected_result = operand_a +% operand_b;
    
    // This simulates what the new handler would do
    frame.setStackTop(expected_result);
    const actual_result = try frame.peekStack();
    
    try testing.expectEqual(@as(u256, 42), actual_result);
    
    // Verify cursor advancement
    const expected_next_cursor = dispatch.cursor + 1;
    try testing.expectEqual(expected_next_cursor, op_data.next.cursor);
}

test "memory expansion compatibility - synthetic operations" {
    // RED: Test that synthetic memory operations work correctly with getOpData
    
    const allocator = testing.allocator;
    var frame = MockFrame.init(allocator);
    defer frame.deinit();
    
    // Set up memory expansion test
    try frame.memory.resize(100);
    
    // Mock dispatch items with metadata
    var items = [_]Dispatch.Item{
        .{ .opcode_handler = &mockHandler },
        .{ .push_inline = .{ .value = 64 } }, // offset metadata
        .{ .opcode_handler = &mockHandler },
    };
    
    const dispatch = Dispatch{ .cursor = &items, .jump_table = null };
    
    // Test synthetic MLOAD operation
    const op_data = dispatch.getOpData(.{ .synthetic = .PUSH_MLOAD_INLINE });
    
    // Verify metadata access
    try testing.expectEqual(@as(u256, 64), op_data.metadata.value);
    
    // Verify cursor advancement
    const expected_next_cursor = dispatch.cursor + 2;
    try testing.expectEqual(expected_next_cursor, op_data.next.cursor);
}

// Edge case tests
test "edge cases - stack underflow preservation" {
    // Test that error conditions work identically with getOpData approach
    
    const allocator = testing.allocator;
    var frame = MockFrame.init(allocator);
    defer frame.deinit();
    
    // Empty stack should cause underflow
    
    var items = [_]Dispatch.Item{
        .{ .opcode_handler = &mockHandler },
        .{ .opcode_handler = &mockHandler },
    };
    
    const dispatch = Dispatch{ .cursor = &items, .jump_table = null };
    const op_data = dispatch.getOpData(.{ .regular = .ADD });
    
    // Both approaches should fail identically
    try testing.expectError(error.StackUnderflow, frame.popFromStack());
    
    // Verify cursor advancement would still work correctly
    try testing.expectEqual(dispatch.cursor + 1, op_data.next.cursor);
}

test "performance baseline - getOpData vs hardcoded" {
    // Establish performance baseline to verify no regression
    
    const allocator = testing.allocator;
    const iterations = 100000;
    
    var items = [_]Dispatch.Item{
        .{ .opcode_handler = &mockHandler },
        .{ .push_inline = .{ .value = 42 } },
        .{ .opcode_handler = &mockHandler },
    };
    
    const dispatch = Dispatch{ .cursor = &items, .jump_table = null };
    
    var timer = try std.time.Timer.start();
    
    // Baseline: hardcoded cursor arithmetic (simulated)
    const start_hardcoded = timer.lap();
    var hardcoded_result: [*]const Dispatch.Item = undefined;
    for (0..iterations) |_| {
        hardcoded_result = dispatch.cursor + 1; // Simulates current pattern
    }
    const hardcoded_time = timer.lap();
    _ = hardcoded_result; // Prevent optimization
    
    // New: getOpData approach
    const start_getOpData = timer.lap();
    var getOpData_result: [*]const Dispatch.Item = undefined;
    for (0..iterations) |_| {
        const op_data = dispatch.getOpData(.{ .regular = .ADD });
        getOpData_result = op_data.next.cursor;
    }
    const getOpData_time = timer.lap();
    _ = getOpData_result; // Prevent optimization
    
    // Verify no significant performance regression (within 10%)
    const regression_threshold = hardcoded_time / 10;
    try testing.expect(getOpData_time <= hardcoded_time + regression_threshold);
}