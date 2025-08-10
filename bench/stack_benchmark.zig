const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const Stack = Evm.Stack;
const Allocator = std.mem.Allocator;

/// Basic stack operations - append vs append_unsafe
pub fn bench_append_safe(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        stack.append(@as(u256, i)) catch unreachable;
        _ = stack.pop() catch unreachable;
    }
}

pub fn bench_append_unsafe(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
        _ = stack.pop_unsafe();
    }
}

/// Pop operations - safe vs unsafe
pub fn bench_pop_safe(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Pre-fill stack
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Benchmark pop operations
    i = 0;
    while (i < 100) : (i += 1) {
        _ = stack.pop() catch unreachable;
        stack.append_unsafe(@as(u256, i)); // Refill to maintain consistent depth
    }
}

pub fn bench_pop_unsafe(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Pre-fill stack
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Benchmark pop operations
    i = 0;
    while (i < 100) : (i += 1) {
        _ = stack.pop_unsafe();
        stack.append_unsafe(@as(u256, i)); // Refill to maintain consistent depth
    }
}

/// Peek operations at various depths
pub fn bench_peek_shallow(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Fill stack to moderate depth
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Peek at top repeatedly
    i = 0;
    while (i < 10000) : (i += 1) {
        _ = stack.peek_unsafe();
    }
}

pub fn bench_peek_deep(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Fill stack to significant depth
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Peek at top repeatedly (still just top, but with deep stack)
    i = 0;
    while (i < 10000) : (i += 1) {
        _ = stack.peek_unsafe();
    }
}

/// DUP operations at different depths
pub fn bench_dup1(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Setup stack
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Benchmark DUP1
    i = 0;
    while (i < 1000) : (i += 1) {
        stack.dup_unsafe(1);
        _ = stack.pop_unsafe(); // Keep stack size stable
    }
}

pub fn bench_dup16(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Setup stack
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Benchmark DUP16
    i = 0;
    while (i < 1000) : (i += 1) {
        stack.dup_unsafe(16);
        _ = stack.pop_unsafe(); // Keep stack size stable
    }
}

/// SWAP operations at different positions
pub fn bench_swap1(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Setup stack
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Benchmark SWAP1
    i = 0;
    while (i < 1000) : (i += 1) {
        stack.swap_unsafe(1);
    }
}

pub fn bench_swap16(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Setup stack
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Benchmark SWAP16
    i = 0;
    while (i < 1000) : (i += 1) {
        stack.swap_unsafe(16);
    }
}

/// Stack growth patterns
pub fn bench_stack_growth_linear(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Linear growth from 0 to 1024
    var i: usize = 0;
    while (i < Stack.CAPACITY) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Clear for next iteration
    stack.clear();
}

pub fn bench_stack_growth_burst(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Burst pattern - rapid push/pop cycles
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        // Push burst
        var j: usize = 0;
        while (j < 10) : (j += 1) {
            stack.append_unsafe(@as(u256, j));
        }
        // Pop burst
        j = 0;
        while (j < 10) : (j += 1) {
            _ = stack.pop_unsafe();
        }
    }
}

/// Memory access patterns
pub fn bench_sequential_access(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Fill stack
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Sequential access pattern
    i = 0;
    while (i < 1000) : (i += 1) {
        _ = stack.pop_unsafe();
        stack.append_unsafe(@as(u256, i));
    }
}

pub fn bench_random_access(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Fill stack
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Random DUP/SWAP operations
    i = 0;
    while (i < 1000) : (i += 1) {
        if (random.boolean()) {
            const depth = random.intRangeAtMost(usize, 1, 16);
            if (stack.size > depth) {
                stack.dup_unsafe(depth);
                _ = stack.pop_unsafe(); // Keep size stable
            }
        } else {
            const pos = random.intRangeAtMost(usize, 1, 16);
            if (stack.size > pos) {
                stack.swap_unsafe(pos);
            }
        }
    }
}

/// Edge cases
pub fn bench_near_full_stack(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Fill to near capacity
    var i: usize = 0;
    while (i < 1020) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Operations near full capacity
    i = 0;
    while (i < 100) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
        _ = stack.pop_unsafe();
    }
}

pub fn bench_empty_stack_checks(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Repeated operations on empty/near-empty stack
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        _ = stack.append(0) catch {};
        _ = stack.pop() catch {};
    }
}

/// Multi-pop operations
pub fn bench_pop2(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Fill stack
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Benchmark pop2
    i = 0;
    while (i < 40) : (i += 1) {
        _ = stack.pop2_unsafe();
        // Refill
        stack.append_unsafe(@as(u256, i * 2));
        stack.append_unsafe(@as(u256, i * 2 + 1));
    }
}

pub fn bench_pop3(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Fill stack
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Benchmark pop3
    i = 0;
    while (i < 30) : (i += 1) {
        _ = stack.pop3_unsafe();
        // Refill
        stack.append_unsafe(@as(u256, i * 3));
        stack.append_unsafe(@as(u256, i * 3 + 1));
        stack.append_unsafe(@as(u256, i * 3 + 2));
    }
}

/// Clear operations
pub fn bench_clear_empty(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        stack.clear();
    }
}

pub fn bench_clear_full(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        // Fill stack
        var j: usize = 0;
        while (j < Stack.CAPACITY) : (j += 1) {
            stack.append_unsafe(@as(u256, j));
        }
        // Clear it
        stack.clear();
    }
}

/// Realistic EVM patterns
pub fn bench_fibonacci_pattern(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Fibonacci calculation pattern
    stack.append_unsafe(0); // F(0)
    stack.append_unsafe(1); // F(1)

    var i: usize = 2;
    while (i < 100) : (i += 1) {
        // DUP2, DUP2 (duplicate last two values)
        stack.dup_unsafe(2);
        stack.dup_unsafe(2);

        // ADD
        const a = stack.pop_unsafe();
        const b = stack.pop_unsafe();
        stack.append_unsafe(a +% b);

        // SWAP1 to maintain order
        stack.swap_unsafe(1);

        // Remove old value
        if (stack.size > 10) {
            // Simulate keeping only recent values
            _ = stack.data[stack.size - 11];
            std.mem.copyForwards(u256, stack.data[0 .. stack.size - 11], stack.data[1 .. stack.size - 10]);
            stack.size -= 1;
        }
    }
}

pub fn bench_defi_calculation_pattern(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Simulate DeFi swap calculation pattern
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        // Push input amount
        stack.append_unsafe(1000000);

        // Push reserves
        stack.append_unsafe(50000000000);
        stack.append_unsafe(25000000000);

        // Calculation pattern: (input * reserve2) / (reserve1 + input)
        // DUP3, DUP2, MUL
        stack.dup_unsafe(3);
        stack.dup_unsafe(2);
        const a1 = stack.pop_unsafe();
        const b1 = stack.pop_unsafe();
        stack.append_unsafe(a1 *% b1);

        // DUP4, DUP4, ADD
        stack.dup_unsafe(4);
        stack.dup_unsafe(4);
        const a2 = stack.pop_unsafe();
        const b2 = stack.pop_unsafe();
        stack.append_unsafe(a2 +% b2);

        // DIV (simulated)
        const numerator = stack.pop_unsafe();
        const denominator = stack.pop_unsafe();
        if (denominator != 0) {
            stack.append_unsafe(numerator / denominator);
        } else {
            stack.append_unsafe(0);
        }

        // Clean up stack
        _ = stack.pop_unsafe();
        _ = stack.pop_unsafe();
        _ = stack.pop_unsafe();
        _ = stack.pop_unsafe();
    }
}

pub fn bench_cryptographic_pattern(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Simulate cryptographic operation pattern (e.g., signature verification prep)
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        // Push signature components (r, s, v)
        stack.append_unsafe(0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef);
        stack.append_unsafe(0xfedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321);
        stack.append_unsafe(27);

        // Push message hash
        stack.append_unsafe(0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef);

        // Simulate some preprocessing
        var j: usize = 0;
        while (j < 10) : (j += 1) {
            // DUP operations to prepare for precompile call
            stack.dup_unsafe(4);
            stack.dup_unsafe(4);
            stack.dup_unsafe(4);
            stack.dup_unsafe(4);

            // Some arithmetic operations
            const x = stack.pop_unsafe();
            const y = stack.pop_unsafe();
            stack.append_unsafe(x ^ y);

            _ = stack.pop_unsafe();
            _ = stack.pop_unsafe();
        }

        // Clean up
        _ = stack.pop_unsafe();
        _ = stack.pop_unsafe();
        _ = stack.pop_unsafe();
        _ = stack.pop_unsafe();
    }
}

/// Set top operation benchmark
pub fn bench_set_top(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Setup stack with some depth
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Benchmark set_top_unsafe
    i = 0;
    while (i < 10000) : (i += 1) {
        stack.set_top_unsafe(@as(u256, i));
    }
}

/// Branch prediction impact benchmark
pub fn bench_predictable_pattern(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};

    // Predictable push/pop pattern
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        // Always push 5, pop 5
        var j: usize = 0;
        while (j < 5) : (j += 1) {
            stack.append_unsafe(@as(u256, j));
        }
        j = 0;
        while (j < 5) : (j += 1) {
            _ = stack.pop_unsafe();
        }
    }
}

pub fn bench_unpredictable_pattern(allocator: Allocator) void {
    _ = allocator;
    var stack = Stack{};
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Unpredictable push/pop pattern
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const push_count = random.intRangeAtMost(usize, 1, 10);
        const pop_count = random.intRangeAtMost(usize, 0, @min(push_count, stack.size));

        var j: usize = 0;
        while (j < push_count) : (j += 1) {
            if (stack.size < Stack.CAPACITY) {
                stack.append_unsafe(@as(u256, j));
            }
        }
        j = 0;
        while (j < pop_count) : (j += 1) {
            if (stack.size > 0) {
                _ = stack.pop_unsafe();
            }
        }
    }
}
