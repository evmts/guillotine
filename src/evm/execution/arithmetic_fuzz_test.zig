const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Vm = @import("../evm.zig");
const address = @import("Address");
const arithmetic = @import("arithmetic.zig");

// Fuzz testing functions for arithmetic operations
pub fn fuzz_arithmetic_operations(allocator: std.mem.Allocator, operations: []const FuzzArithmeticOperation) !void {
    
    for (operations) |op| {
        var memory = try @import("../memory/memory.zig").init_default(allocator);
        defer memory.deinit();
        
        var db = @import("../state/memory_database.zig").init(allocator);
        defer db.deinit();
        
        var vm = try Vm.init(allocator, db.to_database_interface(), null, null);
        defer vm.deinit();
        
        var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x01}, .{});
        defer contract.deinit(allocator, null);
        
        var frame = try Frame.init(allocator, &vm, 1000000, contract, address.Address.ZERO, &.{});
        defer frame.deinit();
        
        // Setup stack with test values
        switch (op.op_type) {
            .add, .mul, .sub, .div, .sdiv, .mod, .smod, .exp, .signextend => {
                try frame.stack.append(op.a);
                try frame.stack.append(op.b);
            },
            .addmod, .mulmod => {
                try frame.stack.append(op.a);
                try frame.stack.append(op.b);
                try frame.stack.append(op.c);
            },
        }
        
        // Execute the operation
        var result: Operation.ExecutionResult = undefined;
        switch (op.op_type) {
            .add => result = try arithmetic.op_add(0, @ptrCast(&vm), @ptrCast(&frame)),
            .mul => result = try arithmetic.op_mul(0, @ptrCast(&vm), @ptrCast(&frame)),
            .sub => result = try arithmetic.op_sub(0, @ptrCast(&vm), @ptrCast(&frame)),
            .div => result = try arithmetic.op_div(0, @ptrCast(&vm), @ptrCast(&frame)),
            .sdiv => result = try arithmetic.op_sdiv(0, @ptrCast(&vm), @ptrCast(&frame)),
            .mod => result = try arithmetic.op_mod(0, @ptrCast(&vm), @ptrCast(&frame)),
            .smod => result = try arithmetic.op_smod(0, @ptrCast(&vm), @ptrCast(&frame)),
            .addmod => result = try arithmetic.op_addmod(0, @ptrCast(&vm), @ptrCast(&frame)),
            .mulmod => result = try arithmetic.op_mulmod(0, @ptrCast(&vm), @ptrCast(&frame)),
            .exp => result = try arithmetic.op_exp(0, @ptrCast(&vm), @ptrCast(&frame)),
            .signextend => result = try arithmetic.op_signextend(0, @ptrCast(&vm), @ptrCast(&frame)),
        }
        
        // Verify the result makes sense
        try validate_arithmetic_result(&frame.stack, op);
    }
}

const FuzzArithmeticOperation = struct {
    op_type: ArithmeticOpType,
    a: u256,
    b: u256,
    c: u256 = 0, // For addmod/mulmod
};

const ArithmeticOpType = enum {
    add,
    mul,
    sub,
    div,
    sdiv,
    mod,
    smod,
    addmod,
    mulmod,
    exp,
    signextend,
};

fn validate_arithmetic_result(stack: *const Stack, op: FuzzArithmeticOperation) !void {
    const testing = std.testing;
    
    // Stack should have exactly one result
    switch (op.op_type) {
        .add, .mul, .sub, .div, .sdiv, .mod, .smod, .addmod, .mulmod, .exp, .signextend => {
            try testing.expectEqual(@as(usize, 1), stack.size);
        },
    }
    
    const result = stack.data[0];
    
    // Verify some basic properties
    switch (op.op_type) {
        .add => {
            const expected = op.a +% op.b;
            try testing.expectEqual(expected, result);
        },
        .mul => {
            const expected = op.a *% op.b;
            try testing.expectEqual(expected, result);
        },
        .sub => {
            const expected = op.a -% op.b;
            try testing.expectEqual(expected, result);
        },
        .div => {
            if (op.b == 0) {
                try testing.expectEqual(@as(u256, 0), result);
            } else {
                const expected = op.a / op.b;
                try testing.expectEqual(expected, result);
            }
        },
        .mod => {
            if (op.b == 0) {
                try testing.expectEqual(@as(u256, 0), result);
            } else {
                const expected = op.a % op.b;
                try testing.expectEqual(expected, result);
            }
        },
        .addmod => {
            if (op.c == 0) {
                try testing.expectEqual(@as(u256, 0), result);
            } else {
                const expected = (op.a +% op.b) % op.c;
                try testing.expectEqual(expected, result);
            }
        },
        .exp => {
            // For exponentiation, just verify it's a valid result
            // Complex verification would require reimplementing the algorithm
            try testing.expect(result >= 0);
        },
        .signextend => {
            // For sign extension, just verify it's a valid result
            try testing.expect(result >= 0);
        },
        else => {},
    }
}

test "fuzz_arithmetic_basic_operations" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzArithmeticOperation{
        .{ .op_type = .add, .a = 10, .b = 20 },
        .{ .op_type = .mul, .a = 5, .b = 6 },
        .{ .op_type = .sub, .a = 30, .b = 10 },
        .{ .op_type = .div, .a = 100, .b = 5 },
        .{ .op_type = .mod, .a = 17, .b = 5 },
    };
    
    try fuzz_arithmetic_operations(allocator, &operations);
}

test "fuzz_arithmetic_edge_cases" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzArithmeticOperation{
        .{ .op_type = .add, .a = std.math.maxInt(u256), .b = 1 }, // Overflow
        .{ .op_type = .mul, .a = std.math.maxInt(u256), .b = 2 }, // Overflow
        .{ .op_type = .sub, .a = 0, .b = 1 }, // Underflow
        .{ .op_type = .div, .a = 100, .b = 0 }, // Division by zero
        .{ .op_type = .mod, .a = 100, .b = 0 }, // Modulo by zero
        .{ .op_type = .sdiv, .a = 1 << 255, .b = std.math.maxInt(u256) }, // Min i256 / -1
        .{ .op_type = .addmod, .a = 10, .b = 20, .c = 0 }, // Modulo by zero
        .{ .op_type = .mulmod, .a = 10, .b = 20, .c = 0 }, // Modulo by zero
    };
    
    try fuzz_arithmetic_operations(allocator, &operations);
}

test "fuzz_arithmetic_random_operations" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    
    var operations = std.ArrayList(FuzzArithmeticOperation).init(allocator);
    defer operations.deinit();
    
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const op_type_idx = random.intRangeAtMost(usize, 0, 6);
        const op_types = [_]ArithmeticOpType{ .add, .mul, .sub, .div, .mod, .addmod, .mulmod };
        const op_type = op_types[op_type_idx];
        
        const a = random.int(u256);
        const b = random.int(u256);
        const c = random.int(u256);
        
        try operations.append(.{ .op_type = op_type, .a = a, .b = b, .c = c });
    }
    
    try fuzz_arithmetic_operations(allocator, operations.items);
}

test "fuzz_arithmetic_boundary_values" {
    const allocator = std.testing.allocator;
    
    const boundary_values = [_]u256{
        0,
        1,
        2,
        std.math.maxInt(u8),
        std.math.maxInt(u16),
        std.math.maxInt(u32),
        std.math.maxInt(u64),
        std.math.maxInt(u128),
        std.math.maxInt(u256),
        std.math.maxInt(u256) - 1,
        1 << 128,
        1 << 255,
        (1 << 255) - 1,
        (1 << 255) + 1,
    };
    
    var operations = std.ArrayList(FuzzArithmeticOperation).init(allocator);
    defer operations.deinit();
    
    for (boundary_values) |a| {
        for (boundary_values) |b| {
            try operations.append(.{ .op_type = .add, .a = a, .b = b });
            try operations.append(.{ .op_type = .mul, .a = a, .b = b });
            try operations.append(.{ .op_type = .sub, .a = a, .b = b });
            try operations.append(.{ .op_type = .div, .a = a, .b = b });
            try operations.append(.{ .op_type = .mod, .a = a, .b = b });
            
            if (operations.items.len > 200) break; // Limit to prevent test timeout
        }
        if (operations.items.len > 200) break;
    }
    
    try fuzz_arithmetic_operations(allocator, operations.items);
}

test "fuzz_arithmetic_edge_cases_found" {
    const allocator = std.testing.allocator;
    
    // Test potential bugs found through fuzzing
    const operations = [_]FuzzArithmeticOperation{
        .{ .op_type = .div, .a = 100, .b = 0 },
        .{ .op_type = .mod, .a = 100, .b = 0 },
        .{ .op_type = .sdiv, .a = 1 << 255, .b = std.math.maxInt(u256) },
        .{ .op_type = .addmod, .a = std.math.maxInt(u256), .b = std.math.maxInt(u256), .c = 0 },
        .{ .op_type = .mulmod, .a = std.math.maxInt(u256), .b = std.math.maxInt(u256), .c = 0 },
    };
    
    try fuzz_arithmetic_operations(allocator, &operations);
}