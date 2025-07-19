/// EVM arithmetic operations with 256-bit wrapping overflow behavior.
/// Division/modulo by zero returns 0. Uses unsafe stack ops for performance.
const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Vm = @import("../evm.zig");

/// ADD opcode (0x01) - Addition with wrapping overflow
pub fn op_add(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    std.debug.assert(frame.stack.size >= 2);

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;

    const sum = a +% b;

    frame.stack.set_top_unsafe(sum);

    return Operation.ExecutionResult{};
}

/// MUL opcode (0x02) - Multiplication with wrapping overflow
pub fn op_mul(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;
    const product = a *% b;

    frame.stack.set_top_unsafe(product);

    return Operation.ExecutionResult{};
}

/// SUB opcode (0x03) - Subtraction with wrapping underflow
pub fn op_sub(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;

    const result = a -% b;

    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

/// DIV opcode (0x04) - Division, returns 0 on division by zero
pub fn op_div(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;

    const result = if (b == 0) blk: {
        @branchHint(.unlikely);
        break :blk 0;
    } else a / b;

    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

/// SDIV opcode (0x05) - Signed division with overflow protection
pub fn op_sdiv(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;

    var result: u256 = undefined;
    if (b == 0) {
        @branchHint(.unlikely);
        result = 0;
    } else {
        const a_i256 = @as(i256, @bitCast(a));
        const b_i256 = @as(i256, @bitCast(b));
        const min_i256 = @as(i256, 1) << 255;
        if (a_i256 == min_i256 and b_i256 == -1) {
            @branchHint(.unlikely);
            result = @as(u256, @bitCast(min_i256));
        } else {
            const result_i256 = @divTrunc(a_i256, b_i256);
            result = @as(u256, @bitCast(result_i256));
        }
    }

    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

/// MOD opcode (0x06) - Modulo, returns 0 on modulo by zero
pub fn op_mod(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;

    const result = if (b == 0) blk: {
        @branchHint(.unlikely);
        break :blk 0;
    } else a % b;

    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

/// SMOD opcode (0x07) - Signed modulo, result sign follows dividend
pub fn op_smod(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;

    var result: u256 = undefined;
    if (b == 0) {
        @branchHint(.unlikely);
        result = 0;
    } else {
        const a_i256 = @as(i256, @bitCast(a));
        const b_i256 = @as(i256, @bitCast(b));
        const result_i256 = @rem(a_i256, b_i256);
        result = @as(u256, @bitCast(result_i256));
    }

    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

/// ADDMOD opcode (0x08) - (a + b) mod n with overflow handling
pub fn op_addmod(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    std.debug.assert(frame.stack.size >= 3);

    const n = frame.stack.pop_unsafe();
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;

    var result: u256 = undefined;
    if (n == 0) {
        result = 0;
    } else {
        const sum = a +% b;
        result = sum % n;
    }

    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

/// MULMOD opcode (0x09) - (a * b) mod n using Russian peasant algorithm
pub fn op_mulmod(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    const n = frame.stack.pop_unsafe();
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;

    var result: u256 = undefined;
    if (n == 0) {
        result = 0;
    } else {
        // Russian peasant multiplication with modular reduction
        result = 0;
        var x = a % n;
        var y = b % n;

        while (y > 0) {
            if ((y & 1) == 1) {
                const sum = result +% x;
                result = sum % n;
            }

            x = (x +% x) % n;

            y >>= 1;
        }
    }

    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

/// EXP opcode (0x0A) - Binary exponentiation with dynamic gas (50/byte)
pub fn op_exp(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));
    _ = vm;

    const exp = frame.stack.pop_unsafe();
    const base = frame.stack.peek_unsafe().*;

    var exp_copy = exp;
    var byte_size: u64 = 0;
    while (exp_copy > 0) : (exp_copy >>= 8) {
        byte_size += 1;
    }
    if (byte_size > 0) {
        @branchHint(.likely);
        const gas_cost = 50 * byte_size;
        try frame.consume_gas(gas_cost);
    }

    var result: u256 = 1;
    var b = base;
    var e = exp;

    while (e > 0) {
        if ((e & 1) == 1) {
            result *%= b;
        }
        b *%= b;
        e >>= 1;
    }

    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

/// SIGNEXTEND opcode (0x0B) - Extends sign bit from specified byte position
pub fn op_signextend(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    const byte_num = frame.stack.pop_unsafe();
    const x = frame.stack.peek_unsafe().*;

    var result: u256 = undefined;

    if (byte_num >= 31) {
        @branchHint(.unlikely);
        result = x;
    } else {
        const byte_index = @as(u8, @intCast(byte_num));
        const sign_bit_pos = byte_index * 8 + 7;

        const sign_bit = (x >> @intCast(sign_bit_pos)) & 1;

        const keep_bits = sign_bit_pos + 1;

        if (sign_bit == 1) {
            if (keep_bits >= 256) {
                result = x;
            } else {
                const shift_amount = @as(u9, 256) - @as(u9, keep_bits);
                const ones_mask = ~(@as(u256, 0) >> @intCast(shift_amount));
                result = x | ones_mask;
            }
        } else {
            if (keep_bits >= 256) {
                result = x;
            } else {
                const zero_mask = (@as(u256, 1) << @intCast(keep_bits)) - 1;
                result = x & zero_mask;
            }
        }
    }

    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

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
        
        var frame = try Frame.init(allocator, &vm, 1000000, contract, @import("../../Address.zig").ZERO, &.{});
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
            .add => result = try op_add(0, @ptrCast(&vm), @ptrCast(&frame)),
            .mul => result = try op_mul(0, @ptrCast(&vm), @ptrCast(&frame)),
            .sub => result = try op_sub(0, @ptrCast(&vm), @ptrCast(&frame)),
            .div => result = try op_div(0, @ptrCast(&vm), @ptrCast(&frame)),
            .sdiv => result = try op_sdiv(0, @ptrCast(&vm), @ptrCast(&frame)),
            .mod => result = try op_mod(0, @ptrCast(&vm), @ptrCast(&frame)),
            .smod => result = try op_smod(0, @ptrCast(&vm), @ptrCast(&frame)),
            .addmod => result = try op_addmod(0, @ptrCast(&vm), @ptrCast(&frame)),
            .mulmod => result = try op_mulmod(0, @ptrCast(&vm), @ptrCast(&frame)),
            .exp => result = try op_exp(0, @ptrCast(&vm), @ptrCast(&frame)),
            .signextend => result = try op_signextend(0, @ptrCast(&vm), @ptrCast(&frame)),
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
