const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const ExecutionContext = @import("../frame.zig").ExecutionContext;
const primitives = @import("primitives");

// Imports for tests
const Vm = @import("../evm.zig");
const Operation = @import("../opcodes/operation.zig");
const MemoryDatabase = @import("../state/memory_database.zig");
const Stack = @import("../stack/stack.zig");

/// Comparison operations for the Ethereum Virtual Machine
///
/// This module implements all comparison opcodes for the EVM, including
/// unsigned comparisons (LT, GT), signed comparisons (SLT, SGT),
/// equality checking (EQ), and zero testing (ISZERO).

pub fn op_lt(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);

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
}

pub fn op_gt(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);

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
}

pub fn op_slt(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);

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
}

pub fn op_sgt(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);

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
}

pub fn op_eq(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);

    // Pop the top operand (b) unsafely
    const b = frame.stack.pop_unsafe();
    // Peek the new top operand (a) unsafely
    const a = frame.stack.peek_unsafe().*;

    const result: u256 = if (a == b) 1 else 0;

    // Modify the current top of the stack in-place with the result
    frame.stack.set_top_unsafe(result);
}

pub fn op_iszero(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 1);

    // Peek the operand unsafely
    const value = frame.stack.peek_unsafe().*;

    // Optimized: Use @intFromBool for direct bool to int conversion
    // This should compile to more efficient assembly than if/else
    const result: u256 = @intFromBool(value == 0);

    // Modify the current top of the stack in-place with the result
    frame.stack.set_top_unsafe(result);
}

// Fuzz testing functions for comparison operations
pub fn fuzz_comparison_operations(allocator: std.mem.Allocator, operations: []const FuzzComparisonOperation) !void {
    const JumpTable = @import("../jump_table/jump_table.zig");
    const CodeAnalysis = @import("../analysis.zig");
    const AccessList = @import("../access_list.zig").AccessList;
    const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
    const ChainRules = @import("../frame.zig").ChainRules;

    for (operations) |op| {
        var memory_db = MemoryDatabase.init(allocator);
        defer memory_db.deinit();

        // Create a simple code analysis for testing
        const code = &[_]u8{0x00}; // STOP
        const table = JumpTable.DEFAULT;
        var analysis = try CodeAnalysis.from_code(allocator, code, &table);
        defer analysis.deinit();

        // Create mock components
        var access_list = try AccessList.init(allocator);
        defer access_list.deinit();
        var self_destruct = try SelfDestruct.init(allocator);
        defer self_destruct.deinit();
        const chain_rules = ChainRules.DEFAULT;

        var context = try ExecutionContext.init(
            allocator,
            1000000, // gas
            false, // not static
            0, // depth
            primitives.Address.ZERO_ADDRESS,
            &analysis,
            &access_list,
            memory_db.to_database_interface(),
            &chain_rules,
            &self_destruct,
        );
        defer context.deinit();

        // Setup stack with test values
        switch (op.op_type) {
            .lt, .gt, .slt, .sgt, .eq => {
                try context.stack.append(op.a);
                try context.stack.append(op.b);
            },
            .iszero => {
                try context.stack.append(op.a);
            },
        }

        // Execute the operation
        switch (op.op_type) {
            .lt => try op_lt(&context),
            .gt => try op_gt(&context),
            .slt => try op_slt(&context),
            .sgt => try op_sgt(&context),
            .eq => try op_eq(&context),
            .iszero => try op_iszero(&context),
        }

        // Verify the result makes sense
        try validate_comparison_result(&context.stack, op);
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
    try testing.expectEqual(@as(usize, 1), stack.size);

    const result = stack.data[0];

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
