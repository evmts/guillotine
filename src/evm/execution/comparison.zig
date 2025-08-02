const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const tracy = @import("../tracy_support.zig");

// Helper to convert Stack errors to ExecutionError
// These are redundant and can be removed.
// The op_* functions below use unsafe stack operations,
// so these helpers are unused anyway.

pub fn op_lt(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_lt\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    // Pop the top operand (b) unsafely
    const b = frame.stack.pop_unsafe();
    // Peek the new top operand (a) unsafely
    const a = frame.stack.peek_unsafe().*;

    // EVM LT computes: b < a (where b was top, a was second from top)
    const result: u256 = switch (std.math.order(b, a)) {
        .lt => 1,
        .eq, .gt => 0,
    };

    // Modify the current top of the stack in-place with the result
    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

pub fn op_gt(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_gt\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    // Pop the top operand (b) unsafely
    const b = frame.stack.pop_unsafe();
    // Peek the new top operand (a) unsafely
    const a = frame.stack.peek_unsafe().*;

    // EVM GT computes: b > a (where b was top, a was second from top)
    const result: u256 = switch (std.math.order(b, a)) {
        .gt => 1,
        .eq, .lt => 0,
    };

    // Modify the current top of the stack in-place with the result
    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

pub fn op_slt(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_slt\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    // Pop the top operand (b) unsafely
    const b = frame.stack.pop_unsafe();
    // Peek the new top operand (a) unsafely
    const a = frame.stack.peek_unsafe().*;

    // Signed less than: b < a (where b was popped first, a is remaining top)
    const a_i256 = @as(i256, @bitCast(a));
    const b_i256 = @as(i256, @bitCast(b));

    const result: u256 = switch (std.math.order(b_i256, a_i256)) {
        .lt => 1,
        .eq, .gt => 0,
    };

    // Modify the current top of the stack in-place with the result
    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

pub fn op_sgt(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_sgt\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    // Pop the top operand (b) unsafely
    const b = frame.stack.pop_unsafe();
    // Peek the new top operand (a) unsafely
    const a = frame.stack.peek_unsafe().*;

    // Signed greater than: b > a (where b was popped first, a is remaining top)
    const a_i256 = @as(i256, @bitCast(a));
    const b_i256 = @as(i256, @bitCast(b));

    const result: u256 = if (b_i256 > a_i256) 1 else 0;

    // Modify the current top of the stack in-place with the result
    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

pub fn op_eq(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_eq\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    // Pop the top operand (b) unsafely
    const b = frame.stack.pop_unsafe();
    // Peek the new top operand (a) unsafely
    const a = frame.stack.peek_unsafe().*;

    const result: u256 = if (a == b) 1 else 0;

    // Modify the current top of the stack in-place with the result
    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

pub fn op_iszero(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_iszero\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    // Peek the operand unsafely
    const value = frame.stack.peek_unsafe().*;

    // Optimized: Use @intFromBool for direct bool to int conversion
    // This should compile to more efficient assembly than if/else
    const result: u256 = @intFromBool(value == 0);

    // Modify the current top of the stack in-place with the result
    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

// Fuzz testing functions for comparison operations
pub fn fuzz_comparison_operations(allocator: std.mem.Allocator, operations: []const FuzzComparisonOperation) !void {
    const Vm = @import("../evm.zig");

    for (operations) |op| {
        var memory = try @import("../memory/memory.zig").init_default(allocator);
        defer memory.deinit();

        var db = @import("../state/memory_database.zig").init(allocator);
        defer db.deinit();

        var vm = try Vm.init(allocator, db.to_database_interface(), null, null);
        defer vm.deinit();

        var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x01}, .{});
        defer contract.deinit(allocator, null);

        const primitives = @import("primitives");
        var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
        defer frame.deinit();

        // Setup stack with test values
        switch (op.op_type) {
            .lt, .gt, .slt, .sgt, .eq => {
                try frame.stack.append(op.a);
                try frame.stack.append(op.b);
            },
            .iszero => {
                try frame.stack.append(op.a);
            },
        }

        // Execute the operation
        var result: Operation.ExecutionResult = undefined;
        switch (op.op_type) {
            .lt => result = try op_lt(0, @ptrCast(&vm), @ptrCast(&frame)),
            .gt => result = try op_gt(0, @ptrCast(&vm), @ptrCast(&frame)),
            .slt => result = try op_slt(0, @ptrCast(&vm), @ptrCast(&frame)),
            .sgt => result = try op_sgt(0, @ptrCast(&vm), @ptrCast(&frame)),
            .eq => result = try op_eq(0, @ptrCast(&vm), @ptrCast(&frame)),
            .iszero => result = try op_iszero(0, @ptrCast(&vm), @ptrCast(&frame)),
        }

        // Verify the result makes sense
        try validate_comparison_result(&frame.stack, op);
    }
}

const FuzzComparisonOperation = struct {
    op_type: ComparisonOpType,
    a: u256,
    b: u256 = 0,
};

const ComparisonOpType = enum {
    lt,
    gt,
    slt,
    sgt,
    eq,
    iszero,
};

fn validate_comparison_result(stack: *const Stack, op: FuzzComparisonOperation) !void {
    const testing = std.testing;

    // Stack should have exactly one result
    try testing.expectEqual(@as(usize, 1), stack.size());

    const result = try stack.peek();

    // All comparison operations return 0 or 1
    try testing.expect(result == 0 or result == 1);

    // Verify specific comparison properties
    switch (op.op_type) {
        .lt => {
            const expected: u256 = if (op.a < op.b) 1 else 0;
            try testing.expectEqual(expected, result);
        },
        .gt => {
            const expected: u256 = if (op.a > op.b) 1 else 0;
            try testing.expectEqual(expected, result);
        },
        .slt => {
            const a_i256 = @as(i256, @bitCast(op.a));
            const b_i256 = @as(i256, @bitCast(op.b));
            const expected: u256 = if (a_i256 < b_i256) 1 else 0;
            try testing.expectEqual(expected, result);
        },
        .sgt => {
            const a_i256 = @as(i256, @bitCast(op.a));
            const b_i256 = @as(i256, @bitCast(op.b));
            const expected: u256 = if (a_i256 > b_i256) 1 else 0;
            try testing.expectEqual(expected, result);
        },
        .eq => {
            const expected: u256 = if (op.a == op.b) 1 else 0;
            try testing.expectEqual(expected, result);
        },
        .iszero => {
            const expected: u256 = if (op.a == 0) 1 else 0;
            try testing.expectEqual(expected, result);
        },
    }
}

test "fuzz_comparison_basic_operations" {
    const allocator = std.testing.allocator;

    const operations = [_]FuzzComparisonOperation{
        .{ .op_type = .lt, .a = 5, .b = 10 },
        .{ .op_type = .gt, .a = 10, .b = 5 },
        .{ .op_type = .slt, .a = 5, .b = 10 },
        .{ .op_type = .sgt, .a = 10, .b = 5 },
        .{ .op_type = .eq, .a = 5, .b = 5 },
        .{ .op_type = .iszero, .a = 0 },
    };

    try fuzz_comparison_operations(allocator, &operations);
}

test "fuzz_comparison_edge_cases" {
    const allocator = std.testing.allocator;

    const operations = [_]FuzzComparisonOperation{
        .{ .op_type = .lt, .a = 0, .b = 0 },
        .{ .op_type = .gt, .a = 0, .b = 0 },
        .{ .op_type = .lt, .a = std.math.maxInt(u256), .b = 0 },
        .{ .op_type = .gt, .a = 0, .b = std.math.maxInt(u256) },
        .{ .op_type = .slt, .a = 1 << 255, .b = 0 }, // Negative vs positive
        .{ .op_type = .sgt, .a = 0, .b = 1 << 255 }, // Positive vs negative
        .{ .op_type = .slt, .a = 1 << 255, .b = (1 << 255) + 1 }, // Two negatives
        .{ .op_type = .sgt, .a = (1 << 255) + 1, .b = 1 << 255 }, // Two negatives
        .{ .op_type = .eq, .a = std.math.maxInt(u256), .b = std.math.maxInt(u256) },
        .{ .op_type = .iszero, .a = std.math.maxInt(u256) },
    };

    try fuzz_comparison_operations(allocator, &operations);
}

test "fuzz_comparison_random_operations" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var operations = std.ArrayList(FuzzComparisonOperation).init(allocator);
    defer operations.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const op_type_idx = random.intRangeAtMost(usize, 0, 5);
        const op_types = [_]ComparisonOpType{ .lt, .gt, .slt, .sgt, .eq, .iszero };
        const op_type = op_types[op_type_idx];

        const a = random.int(u256);
        const b = random.int(u256);

        try operations.append(.{ .op_type = op_type, .a = a, .b = b });
    }

    try fuzz_comparison_operations(allocator, operations.items);
}
