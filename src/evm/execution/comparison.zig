//! Comparison operations for the Ethereum Virtual Machine
//!
//! This module implements all comparison opcodes for the EVM, including
//! unsigned comparisons (LT, GT), signed comparisons (SLT, SGT),
//! equality checking (EQ), and zero testing (ISZERO).
//!
//! ## Gas Costs
//! All comparison operations cost 3 gas.
//!
//! ## Stack Effects
//! - Binary comparisons (LT, GT, SLT, SGT, EQ): pop 2, push 1
//! - Unary comparison (ISZERO): pop 1, push 1
//!
//! ## Return Values
//! All comparison opcodes return 1 for true and 0 for false.

const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const Frame = @import("../stack_frame.zig").StackFrame;
const primitives = @import("primitives");
const Log = @import("../log.zig");

// Imports for tests
const Vm = @import("../evm.zig");
const Operation = @import("../opcodes/operation.zig");
const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
const Stack = @import("../stack/stack.zig");

/// LT opcode (0x10) - Less than comparison
///
/// Pops two values and pushes 1 if the first is less than the second, 0 otherwise.
/// Stack: [a, b] → [a < b]
pub fn op_lt(frame: *Frame) ExecutionError.Error!void {
    std.debug.assert(frame.stack.size() >= 2);

    // Pop the top operand
    const top = frame.stack.pop_unsafe();
    // Peek the second from top operand
    const second_from_top = frame.stack.peek_unsafe();

    // EVM semantics: compare top (b) with second-from-top (a), push b < a
    // REVM computes: top < second_from_top
    const result: u256 = switch (std.math.order(top, second_from_top)) {
        .lt => 1,
        .eq, .gt => 0,
    };

    // Modify the current top of the stack in-place with the result
    frame.stack.set_top_unsafe(result);
    Log.debug("LT: top(b)={} second(a)={} -> {} (b < a)", .{ top, second_from_top, result });
}

/// GT opcode (0x11) - Greater than comparison
///
/// Pops two values and pushes 1 if the first is greater than the second, 0 otherwise.
/// Stack: [a, b] → [a > b]
pub fn op_gt(frame: *Frame) ExecutionError.Error!void {
    std.debug.assert(frame.stack.size() >= 2);

    // Pop the top operand
    const top = frame.stack.pop_unsafe();
    // Peek the second from top operand
    const second_from_top = frame.stack.peek_unsafe();

    // EVM semantics: compare top (b) with second-from-top (a), push b > a
    // REVM computes: top > second_from_top
    const result: u256 = switch (std.math.order(top, second_from_top)) {
        .gt => 1,
        .eq, .lt => 0,
    };
    Log.debug("GT: top(b)={} second(a)={} -> {} (b > a)", .{ top, second_from_top, result });

    // Modify the current top of the stack in-place with the result
    frame.stack.set_top_unsafe(result);
}

/// SLT opcode (0x12) - Signed less than comparison
///
/// Pops two values, interprets them as signed integers, and pushes 1 if the
/// first is less than the second, 0 otherwise.
/// Stack: [a, b] → [a < b] (signed)
pub fn op_slt(frame: *Frame) ExecutionError.Error!void {
    std.debug.assert(frame.stack.size() >= 2);

    // Pop the top operand
    const top = frame.stack.pop_unsafe();
    // Peek the second from top operand
    const second_from_top = frame.stack.peek_unsafe();

    // EVM semantics: compare top (b) with second-from-top (a), push b < a (signed)
    // REVM computes: top < second_from_top
    const top_i256 = @as(i256, @bitCast(top));
    const second_from_top_i256 = @as(i256, @bitCast(second_from_top));

    const result: u256 = switch (std.math.order(top_i256, second_from_top_i256)) {
        .lt => 1,
        .eq, .gt => 0,
    };

    // Modify the current top of the stack in-place with the result
    frame.stack.set_top_unsafe(result);
    Log.debug("SLT: top(b)={} second(a)={} -> {} (b < a signed)", .{ top_i256, second_from_top_i256, result });
}

/// SGT opcode (0x13) - Signed greater than comparison
///
/// Pops two values, interprets them as signed integers, and pushes 1 if the
/// first is greater than the second, 0 otherwise.
/// Stack: [a, b] → [a > b] (signed)
pub fn op_sgt(frame: *Frame) ExecutionError.Error!void {
    std.debug.assert(frame.stack.size() >= 2);

    // Pop the top operand
    const top = frame.stack.pop_unsafe();
    // Peek the second from top operand
    const second_from_top = frame.stack.peek_unsafe();

    // EVM semantics: compare top (b) with second-from-top (a), push b > a (signed)
    // REVM computes: top > second_from_top
    const top_i256 = @as(i256, @bitCast(top));
    const second_from_top_i256 = @as(i256, @bitCast(second_from_top));

    const result: u256 = if (top_i256 > second_from_top_i256) 1 else 0;
    Log.debug("SGT: top(b)={} second(a)={} -> {} (b > a signed)", .{ top_i256, second_from_top_i256, result });

    // Modify the current top of the stack in-place with the result
    frame.stack.set_top_unsafe(result);
}

/// EQ opcode (0x14) - Equality comparison
///
/// Pops two values and pushes 1 if they are equal, 0 otherwise.
/// Stack: [a, b] → [a == b]
pub fn op_eq(frame: *Frame) ExecutionError.Error!void {
    std.debug.assert(frame.stack.size() >= 2);

    // Pop the top operand (b)
    const b = frame.stack.pop_unsafe();
    // Peek the new top operand (a)
    const a = frame.stack.peek_unsafe();

    const result: u256 = if (a == b) 1 else 0;

    // Modify the current top of the stack in-place with the result
    frame.stack.set_top_unsafe(result);
}

/// ISZERO opcode (0x15) - Check if zero
///
/// Pops one value and pushes 1 if it is zero, 0 otherwise.
/// Stack: [a] → [a == 0]
pub fn op_iszero(frame: *Frame) ExecutionError.Error!void {
    std.debug.assert(frame.stack.size() >= 1);

    // Peek the operand
    const value = frame.stack.peek_unsafe();

    // Optimized: Use @intFromBool for direct bool to int conversion
    // This should compile to more efficient assembly than if/else
    const result: u256 = @intFromBool(value == 0);

    // Modify the current top of the stack in-place with the result
    frame.stack.set_top_unsafe(result);
}

// Fuzz testing functions for comparison operations
pub fn fuzz_comparison_operations(allocator: std.mem.Allocator, operations: []const FuzzComparisonOperation) !void {
    const MockHost = @import("../host.zig").MockHost;

    for (operations) |op| {
        var memory_db = MemoryDatabase.init(allocator);
        defer memory_db.deinit();

        // Create a simple code analysis for testing
        const code = &[_]u8{0x00}; // STOP

        // Create empty analysis for StackFrame
        const SimpleAnalysis = @import("../evm/analysis2.zig").SimpleAnalysis;
        const empty_analysis = SimpleAnalysis{
            .inst_to_pc = &.{},
            .pc_to_inst = &.{},
            .bytecode = code,
            .inst_count = 0,
            .block_boundaries = std.DynamicBitSet.initEmpty(allocator, 0),
        };
        const empty_metadata: []u32 = &.{};
        const empty_ops: []*const anyopaque = &.{};

        // Create mock host
        var mock_host = MockHost.init(allocator);
        defer mock_host.deinit();
        const host = mock_host.to_host();

        const db_interface = memory_db.to_database_interface();

        var context = try Frame.init(
            1000000, // gas_remaining
            false, // static_call
            primitives.Address.ZERO_ADDRESS, // contract_address
            primitives.Address.ZERO_ADDRESS, // caller
            0, // value
            empty_analysis,
            empty_metadata,
            empty_ops,
            host,
            db_interface,
            allocator,
        );
        defer context.deinit(allocator);

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
    try testing.expectEqual(@as(usize, 1), stack.size());

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
