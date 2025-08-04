const std = @import("std");
const Allocator = std.mem.Allocator;
const primitives = @import("primitives");
const Uint = primitives.Uint;
const zbench = @import("zbench");

// Type aliases for our tests
const U256_Custom = Uint(256, 4);
const U256_Native = u256;

// Helper function to generate test data (native u256 only)
fn generateTestData(allocator: Allocator, count: usize) !struct {
    native: []U256_Native,

    fn deinit(self: @This(), alloc: Allocator) void {
        alloc.free(self.native);
    }
} {
    var native_numbers = try allocator.alloc(U256_Native, count);

    // Generate test data with various number patterns
    var rng = std.Random.DefaultPrng.init(12345);
    const random = rng.random();

    for (0..count) |i| {
        // Mix of small, medium, and large numbers
        const value = switch (i % 4) {
            0 => random.int(u64), // Small numbers
            1 => @as(u256, random.int(u64)) << 64, // Medium numbers
            2 => @as(u256, random.int(u64)) << 128, // Large numbers
            3 => (@as(u256, random.int(u64)) << 192) | random.int(u64), // Very large numbers
            else => unreachable,
        };

        native_numbers[i] = value;
    }

    return .{
        .native = native_numbers,
    };
}

// Addition benchmarks
pub fn zbench_custom_addition(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    var sum = U256_Custom.ZERO;
    for (data.native) |native_num| {
        const custom_num = U256_Custom.from_u256(native_num);
        sum = sum.wrapping_add(custom_num);
    }
    std.mem.doNotOptimizeAway(sum);
}

pub fn zbench_native_addition(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    var sum: U256_Native = 0;
    for (data.native) |num| {
        sum +%= num;
    }
    std.mem.doNotOptimizeAway(sum);
}

// Subtraction benchmarks
pub fn zbench_custom_subtraction(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    var diff = U256_Custom.from_u256(data.native[0]);
    for (data.native[1..]) |native_num| {
        const custom_num = U256_Custom.from_u256(native_num);
        diff = diff.wrapping_sub(custom_num);
    }
    std.mem.doNotOptimizeAway(diff);
}

pub fn zbench_native_subtraction(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    var diff = data.native[0];
    for (data.native[1..]) |num| {
        diff -%= num;
    }
    std.mem.doNotOptimizeAway(diff);
}

// Multiplication benchmarks
pub fn zbench_custom_multiplication(allocator: Allocator) void {
    const data = generateTestData(allocator, 500) catch return; // Fewer iterations for multiplication
    defer data.deinit(allocator);

    for (0..data.native.len - 1) |i| {
        const custom_a = U256_Custom.from_u256(data.native[i]);
        const custom_b = U256_Custom.from_u256(data.native[i + 1]);
        const product = custom_a.wrapping_mul(custom_b);
        std.mem.doNotOptimizeAway(product);
    }
}

pub fn zbench_native_multiplication(allocator: Allocator) void {
    const data = generateTestData(allocator, 500) catch return;
    defer data.deinit(allocator);

    for (0..data.native.len - 1) |i| {
        const product = data.native[i] *% data.native[i + 1];
        std.mem.doNotOptimizeAway(product);
    }
}

// Division benchmarks
pub fn zbench_custom_division(allocator: Allocator) void {
    const data = generateTestData(allocator, 200) catch return; // Even fewer for division
    defer data.deinit(allocator);

    for (0..data.native.len - 1) |i| {
        var native_divisor = data.native[i + 1];
        if (native_divisor == 0) native_divisor = 1;

        const custom_dividend = U256_Custom.from_u256(data.native[i]);
        const custom_divisor = U256_Custom.from_u256(native_divisor);
        const quotient = custom_dividend.wrapping_div(custom_divisor);
        std.mem.doNotOptimizeAway(quotient);
    }
}

pub fn zbench_native_division(allocator: Allocator) void {
    const data = generateTestData(allocator, 200) catch return;
    defer data.deinit(allocator);

    for (0..data.native.len - 1) |i| {
        var divisor = data.native[i + 1];
        if (divisor == 0) divisor = 1;

        const quotient = data.native[i] / divisor;
        std.mem.doNotOptimizeAway(quotient);
    }
}

// Modulo benchmarks
pub fn zbench_custom_modulo(allocator: Allocator) void {
    const data = generateTestData(allocator, 200) catch return;
    defer data.deinit(allocator);

    for (0..data.native.len - 1) |i| {
        var native_divisor = data.native[i + 1];
        if (native_divisor == 0) native_divisor = 1;

        const custom_dividend = U256_Custom.from_u256(data.native[i]);
        const custom_divisor = U256_Custom.from_u256(native_divisor);
        const remainder = custom_dividend.wrapping_rem(custom_divisor);
        std.mem.doNotOptimizeAway(remainder);
    }
}

pub fn zbench_native_modulo(allocator: Allocator) void {
    const data = generateTestData(allocator, 200) catch return;
    defer data.deinit(allocator);

    for (0..data.native.len - 1) |i| {
        var divisor = data.native[i + 1];
        if (divisor == 0) divisor = 1;

        const remainder = data.native[i] % divisor;
        std.mem.doNotOptimizeAway(remainder);
    }
}

// Shift left benchmarks
pub fn zbench_custom_shift_left(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    for (data.native) |native_num| {
        const custom_num = U256_Custom.from_u256(native_num);
        const shifted = custom_num.wrapping_shl(7);
        std.mem.doNotOptimizeAway(shifted);
    }
}

pub fn zbench_native_shift_left(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    for (data.native) |num| {
        const shifted = num << 7;
        std.mem.doNotOptimizeAway(shifted);
    }
}

// Shift right benchmarks
pub fn zbench_custom_shift_right(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    for (data.native) |native_num| {
        const custom_num = U256_Custom.from_u256(native_num);
        const shifted = custom_num.wrapping_shr(7);
        std.mem.doNotOptimizeAway(shifted);
    }
}

pub fn zbench_native_shift_right(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    for (data.native) |num| {
        const shifted = num >> 7;
        std.mem.doNotOptimizeAway(shifted);
    }
}

// Bitwise AND benchmarks
pub fn zbench_custom_bitwise_and(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    for (0..data.native.len - 1) |i| {
        const custom_a = U256_Custom.from_u256(data.native[i]);
        const custom_b = U256_Custom.from_u256(data.native[i + 1]);
        const result = custom_a.bit_and(custom_b);
        std.mem.doNotOptimizeAway(result);
    }
}

pub fn zbench_native_bitwise_and(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    for (0..data.native.len - 1) |i| {
        const result = data.native[i] & data.native[i + 1];
        std.mem.doNotOptimizeAway(result);
    }
}

// Bitwise OR benchmarks
pub fn zbench_custom_bitwise_or(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    for (0..data.native.len - 1) |i| {
        const custom_a = U256_Custom.from_u256(data.native[i]);
        const custom_b = U256_Custom.from_u256(data.native[i + 1]);
        const result = custom_a.bit_or(custom_b);
        std.mem.doNotOptimizeAway(result);
    }
}

pub fn zbench_native_bitwise_or(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    for (0..data.native.len - 1) |i| {
        const result = data.native[i] | data.native[i + 1];
        std.mem.doNotOptimizeAway(result);
    }
}

// Bitwise XOR benchmarks
pub fn zbench_custom_bitwise_xor(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    for (0..data.native.len - 1) |i| {
        const custom_a = U256_Custom.from_u256(data.native[i]);
        const custom_b = U256_Custom.from_u256(data.native[i + 1]);
        const result = custom_a.bit_xor(custom_b);
        std.mem.doNotOptimizeAway(result);
    }
}

pub fn zbench_native_bitwise_xor(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    for (0..data.native.len - 1) |i| {
        const result = data.native[i] ^ data.native[i + 1];
        std.mem.doNotOptimizeAway(result);
    }
}

// Comparison benchmarks
pub fn zbench_custom_comparison(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    for (0..data.native.len - 1) |i| {
        const custom_a = U256_Custom.from_u256(data.native[i]);
        const custom_b = U256_Custom.from_u256(data.native[i + 1]);
        const lt = custom_a.lt(custom_b);
        const eq = custom_a.eq(custom_b);
        const gt = custom_a.gt(custom_b);
        std.mem.doNotOptimizeAway(lt);
        std.mem.doNotOptimizeAway(eq);
        std.mem.doNotOptimizeAway(gt);
    }
}

pub fn zbench_native_comparison(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    for (0..data.native.len - 1) |i| {
        const lt = data.native[i] < data.native[i + 1];
        const eq = data.native[i] == data.native[i + 1];
        const gt = data.native[i] > data.native[i + 1];
        std.mem.doNotOptimizeAway(lt);
        std.mem.doNotOptimizeAway(eq);
        std.mem.doNotOptimizeAway(gt);
    }
}

// Leading zeros benchmarks
pub fn zbench_custom_leading_zeros(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    for (data.native) |native_num| {
        const custom_num = U256_Custom.from_u256(native_num);
        const lz = custom_num.leading_zeros();
        std.mem.doNotOptimizeAway(lz);
    }
}

pub fn zbench_native_leading_zeros(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    for (data.native) |num| {
        const lz = @clz(num);
        std.mem.doNotOptimizeAway(lz);
    }
}

// Trailing zeros benchmarks
pub fn zbench_custom_trailing_zeros(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    for (data.native) |native_num| {
        const custom_num = U256_Custom.from_u256(native_num);
        const tz = custom_num.trailing_zeros();
        std.mem.doNotOptimizeAway(tz);
    }
}

pub fn zbench_native_trailing_zeros(allocator: Allocator) void {
    const data = generateTestData(allocator, 1000) catch return;
    defer data.deinit(allocator);

    for (data.native) |num| {
        const tz = @ctz(num);
        std.mem.doNotOptimizeAway(tz);
    }
}

// Runner function for zbench integration
pub fn run_uint_benchmarks(_: Allocator, benchmark: anytype) !void {
    // Arithmetic operations
    try benchmark.add("Custom Addition", zbench_custom_addition, .{});
    try benchmark.add("Native Addition", zbench_native_addition, .{});
    try benchmark.add("Custom Subtraction", zbench_custom_subtraction, .{});
    try benchmark.add("Native Subtraction", zbench_native_subtraction, .{});
    try benchmark.add("Custom Multiplication", zbench_custom_multiplication, .{});
    try benchmark.add("Native Multiplication", zbench_native_multiplication, .{});
    try benchmark.add("Custom Division", zbench_custom_division, .{});
    try benchmark.add("Native Division", zbench_native_division, .{});
    try benchmark.add("Custom Modulo", zbench_custom_modulo, .{});
    try benchmark.add("Native Modulo", zbench_native_modulo, .{});

    // Bit operations
    try benchmark.add("Custom Shift Left", zbench_custom_shift_left, .{});
    try benchmark.add("Native Shift Left", zbench_native_shift_left, .{});
    try benchmark.add("Custom Shift Right", zbench_custom_shift_right, .{});
    try benchmark.add("Native Shift Right", zbench_native_shift_right, .{});
    try benchmark.add("Custom Bitwise AND", zbench_custom_bitwise_and, .{});
    try benchmark.add("Native Bitwise AND", zbench_native_bitwise_and, .{});
    try benchmark.add("Custom Bitwise OR", zbench_custom_bitwise_or, .{});
    try benchmark.add("Native Bitwise OR", zbench_native_bitwise_or, .{});
    try benchmark.add("Custom Bitwise XOR", zbench_custom_bitwise_xor, .{});
    try benchmark.add("Native Bitwise XOR", zbench_native_bitwise_xor, .{});

    // Comparison and bit counting
    try benchmark.add("Custom Comparison", zbench_custom_comparison, .{});
    try benchmark.add("Native Comparison", zbench_native_comparison, .{});
    try benchmark.add("Custom Leading Zeros", zbench_custom_leading_zeros, .{});
    try benchmark.add("Native Leading Zeros", zbench_native_leading_zeros, .{});
    try benchmark.add("Custom Trailing Zeros", zbench_custom_trailing_zeros, .{});
    try benchmark.add("Native Trailing Zeros", zbench_native_trailing_zeros, .{});

    // Run all benchmarks
    const stdout = std.io.getStdOut().writer();
    try benchmark.run(stdout);
}

// Simple non-zbench runner for integration with existing benchmark suite
pub fn run_uint_benchmarks_simple(allocator: Allocator) !void {
    std.debug.print("=== Uint Library vs Native u256 Benchmarks (Simple) ===\n", .{});

    // Run a subset of benchmarks for demonstration
    std.debug.print("Running Custom Addition...\n", .{});
    zbench_custom_addition(allocator);

    std.debug.print("Running Native Addition...\n", .{});
    zbench_native_addition(allocator);

    std.debug.print("Running Custom Multiplication...\n", .{});
    zbench_custom_multiplication(allocator);

    std.debug.print("Running Native Multiplication...\n", .{});
    zbench_native_multiplication(allocator);

    std.debug.print("Running Custom Division...\n", .{});
    zbench_custom_division(allocator);

    std.debug.print("Running Native Division...\n", .{});
    zbench_native_division(allocator);

    std.debug.print("=== Uint Benchmarks Complete ===\n", .{});
}

// Standalone test for correctness
test "uint library correctness vs native" {
    const allocator = std.testing.allocator;

    // Test basic operations for correctness
    const a_native: u256 = 12345678901234567890;
    const b_native: u256 = 98765432109876543210;

    const a_custom = U256_Custom.from_u256(a_native);
    const b_custom = U256_Custom.from_u256(b_native);

    // Test addition
    const sum_native = a_native +% b_native;
    const sum_custom = a_custom.wrapping_add(b_custom);
    try std.testing.expectEqual(sum_native, sum_custom.to_u256().?);

    // Test subtraction
    const diff_native = a_native -% b_native;
    const diff_custom = a_custom.wrapping_sub(b_custom);
    try std.testing.expectEqual(diff_native, diff_custom.to_u256().?);

    // Test multiplication (with smaller numbers to avoid overflow)
    const small_a: u256 = 12345;
    const small_b: u256 = 67890;
    const mul_native = small_a *% small_b;
    const mul_custom = U256_Custom.from_u256(small_a).wrapping_mul(U256_Custom.from_u256(small_b));
    try std.testing.expectEqual(mul_native, mul_custom.to_u256().?);

    // Test division
    if (b_native != 0) {
        const div_native = a_native / b_native;
        const div_custom = a_custom.wrapping_div(b_custom);
        try std.testing.expectEqual(div_native, div_custom.to_u256().?);
    }

    // Test bitwise operations
    const and_native = a_native & b_native;
    const and_custom = a_custom.bit_and(b_custom);
    try std.testing.expectEqual(and_native, and_custom.to_u256().?);

    const or_native = a_native | b_native;
    const or_custom = a_custom.bit_or(b_custom);
    try std.testing.expectEqual(or_native, or_custom.to_u256().?);

    const xor_native = a_native ^ b_native;
    const xor_custom = a_custom.bit_xor(b_custom);
    try std.testing.expectEqual(xor_native, xor_custom.to_u256().?);

    // Test shifts
    const shl_native = a_native << 7;
    const shl_custom = a_custom.wrapping_shl(7);
    try std.testing.expectEqual(shl_native, shl_custom.to_u256().?);

    const shr_native = a_native >> 7;
    const shr_custom = a_custom.wrapping_shr(7);
    try std.testing.expectEqual(shr_native, shr_custom.to_u256().?);

    // Test comparisons
    try std.testing.expectEqual(a_native < b_native, a_custom.lt(b_custom));
    try std.testing.expectEqual(a_native == b_native, a_custom.eq(b_custom));
    try std.testing.expectEqual(a_native > b_native, a_custom.gt(b_custom));

    // Test bit counting
    try std.testing.expectEqual(@clz(a_native), a_custom.leading_zeros());
    try std.testing.expectEqual(@ctz(a_native), a_custom.trailing_zeros());

    _ = allocator; // Suppress unused variable warning
}
