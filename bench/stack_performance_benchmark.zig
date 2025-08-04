const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const Stack = Evm.Stack;
const PointerStack = Evm.PointerStack;
const Allocator = std.mem.Allocator;

/// Run benchmark and return average time per operation
fn runBenchmark(iterations: usize, setup_fn: *const fn(*Stack) void, bench_fn: *const fn(*Stack) void) u64 {
    // Warm up
    var warmup_stack = Stack{};
    setup_fn(&warmup_stack);
    bench_fn(&warmup_stack);
    
    // Actual benchmark
    const runs = 5;
    var total_time: u64 = 0;
    
    var r: usize = 0;
    while (r < runs) : (r += 1) {
        var stack = Stack{};
        
        setup_fn(&stack);
        
        var timer = std.time.Timer.start() catch unreachable;
        
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            bench_fn(&stack);
        }
        
        total_time += timer.read();
    }
    
    return total_time / runs / iterations;
}

// Benchmark functions
fn setup_empty(stack: *Stack) void {
    _ = stack;
}

fn bench_push_pop(stack: *Stack) void {
    stack.append_unsafe(42);
    _ = stack.pop_unsafe();
}

fn setup_with_items(stack: *Stack) void {
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }
}

fn bench_dup1(stack: *Stack) void {
    stack.dup_unsafe(1);
    _ = stack.pop_unsafe();
}

fn bench_swap1(stack: *Stack) void {
    stack.swap_unsafe(1);
}

fn setup_for_pop2(stack: *Stack) void {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }
}

fn bench_pop2(stack: *Stack) void {
    _ = stack.pop2_unsafe();
    stack.append_unsafe(1);
    stack.append_unsafe(2);
}

fn bench_clear(stack: *Stack) void {
    stack.clear();
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }
}

pub fn run_stack_performance_benchmarks(allocator: Allocator) !void {
    _ = allocator;
    
    std.debug.print("\n=== Stack Performance Benchmark Results ===\n\n", .{});
    
    const iterations = 1_000_000;
    
    // Push/Pop benchmark
    {
        const ns_per_op = runBenchmark(iterations, setup_empty, bench_push_pop);
        const ops_per_sec = @as(f64, 1_000_000_000.0) / @as(f64, @floatFromInt(ns_per_op));
        
        std.debug.print("Push/Pop Cycles:\n", .{});
        std.debug.print("  Time: {} ns/op\n", .{ns_per_op});
        std.debug.print("  Throughput: {d:.2} million ops/sec\n\n", .{ops_per_sec / 1_000_000.0});
    }
    
    // DUP1 benchmark
    {
        const ns_per_op = runBenchmark(iterations, setup_with_items, bench_dup1);
        const ops_per_sec = @as(f64, 1_000_000_000.0) / @as(f64, @floatFromInt(ns_per_op));
        
        std.debug.print("DUP1 Operations:\n", .{});
        std.debug.print("  Time: {} ns/op\n", .{ns_per_op});
        std.debug.print("  Throughput: {d:.2} million ops/sec\n\n", .{ops_per_sec / 1_000_000.0});
    }
    
    // SWAP1 benchmark
    {
        const ns_per_op = runBenchmark(iterations, setup_with_items, bench_swap1);
        const ops_per_sec = @as(f64, 1_000_000_000.0) / @as(f64, @floatFromInt(ns_per_op));
        
        std.debug.print("SWAP1 Operations:\n", .{});
        std.debug.print("  Time: {} ns/op\n", .{ns_per_op});
        std.debug.print("  Throughput: {d:.2} million ops/sec\n\n", .{ops_per_sec / 1_000_000.0});
    }
    
    // POP2 benchmark
    {
        const ns_per_op = runBenchmark(iterations / 10, setup_for_pop2, bench_pop2);
        const ops_per_sec = @as(f64, 1_000_000_000.0) / @as(f64, @floatFromInt(ns_per_op));
        
        std.debug.print("POP2 Operations:\n", .{});
        std.debug.print("  Time: {} ns/op\n", .{ns_per_op});
        std.debug.print("  Throughput: {d:.2} million ops/sec\n\n", .{ops_per_sec / 1_000_000.0});
    }
    
    // Clear benchmark
    {
        const ns_per_op = runBenchmark(iterations / 100, setup_with_items, bench_clear);
        const ops_per_sec = @as(f64, 1_000_000_000.0) / @as(f64, @floatFromInt(ns_per_op));
        
        std.debug.print("Clear Operations:\n", .{});
        std.debug.print("  Time: {} ns/op\n", .{ns_per_op});
        std.debug.print("  Throughput: {d:.2} million ops/sec\n\n", .{ops_per_sec / 1_000_000.0});
    }
    
    std.debug.print("=== Summary ===\n", .{});
    std.debug.print("Stack operations optimized with:\n", .{});
    std.debug.print("1. Direct stack allocation (no heap indirection)\n", .{});
    std.debug.print("2. 32-byte alignment for SIMD-friendly access\n", .{});
    std.debug.print("3. Hot path annotations (@branchHint) for better branch prediction\n", .{});
    std.debug.print("4. Optimized pop2/pop3 with single size update\n", .{});
    
    // Run pointer-based stack comparison
    std.debug.print("\n=== Pointer-based Stack Comparison ===\n", .{});
    try run_pointer_stack_comparison();
}

/// Run benchmark comparing index-based vs pointer-based stack implementations
fn run_pointer_stack_comparison() !void {
    const iterations = 1_000_000;
    
    std.debug.print("\nComparing index-based vs pointer-based stack implementations:\n", .{});
    std.debug.print("Iterations: {}\n\n", .{iterations});
    
    // Push/Pop comparison
    {
        // Index-based stack
        var index_time: u64 = 0;
        {
            var stack = Stack{};
            var timer = try std.time.Timer.start();
            
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                stack.append_unsafe(@intCast(i & 0xFF));
                _ = stack.pop_unsafe();
            }
            
            index_time = timer.read();
        }
        
        // Pointer-based stack
        var pointer_time: u64 = 0;
        {
            var stack = PointerStack.init();
            stack.setup();
            var timer = try std.time.Timer.start();
            
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                stack.append_unsafe(@intCast(i & 0xFF));
                _ = stack.pop_unsafe();
            }
            
            pointer_time = timer.read();
        }
        
        const index_ns_per_op = index_time / iterations / 2;
        const pointer_ns_per_op = pointer_time / iterations / 2;
        const improvement = @as(f64, @floatFromInt(index_time)) / @as(f64, @floatFromInt(pointer_time));
        
        std.debug.print("Push/Pop Operations:\n", .{});
        std.debug.print("  Index-based:   {} ns/op\n", .{index_ns_per_op});
        std.debug.print("  Pointer-based: {} ns/op\n", .{pointer_ns_per_op});
        std.debug.print("  Improvement:   {d:.2}x\n\n", .{improvement});
    }
    
    // DUP operation comparison
    {
        // Index-based stack
        var index_time: u64 = 0;
        {
            var stack = Stack{};
            // Pre-fill
            var j: usize = 0;
            while (j < 16) : (j += 1) {
                stack.append_unsafe(@intCast(j));
            }
            
            var timer = try std.time.Timer.start();
            
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                stack.dup_unsafe(8);
                _ = stack.pop_unsafe();
            }
            
            index_time = timer.read();
        }
        
        // Pointer-based stack
        var pointer_time: u64 = 0;
        {
            var stack = PointerStack.init();
            stack.setup();
            // Pre-fill
            var j: usize = 0;
            while (j < 16) : (j += 1) {
                stack.append_unsafe(@intCast(j));
            }
            
            var timer = try std.time.Timer.start();
            
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                stack.dup_unsafe(8);
                _ = stack.pop_unsafe();
            }
            
            pointer_time = timer.read();
        }
        
        const index_ns_per_op = index_time / iterations / 2;
        const pointer_ns_per_op = pointer_time / iterations / 2;
        const improvement = @as(f64, @floatFromInt(index_time)) / @as(f64, @floatFromInt(pointer_time));
        
        std.debug.print("DUP Operations:\n", .{});
        std.debug.print("  Index-based:   {} ns/op\n", .{index_ns_per_op});
        std.debug.print("  Pointer-based: {} ns/op\n", .{pointer_ns_per_op});
        std.debug.print("  Improvement:   {d:.2}x\n\n", .{improvement});
    }
    
    // SWAP operation comparison
    {
        // Index-based stack
        var index_time: u64 = 0;
        {
            var stack = Stack{};
            // Pre-fill
            var j: usize = 0;
            while (j < 16) : (j += 1) {
                stack.append_unsafe(@intCast(j));
            }
            
            var timer = try std.time.Timer.start();
            
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                stack.swap_unsafe(4);
            }
            
            index_time = timer.read();
        }
        
        // Pointer-based stack
        var pointer_time: u64 = 0;
        {
            var stack = PointerStack.init();
            stack.setup();
            // Pre-fill
            var j: usize = 0;
            while (j < 16) : (j += 1) {
                stack.append_unsafe(@intCast(j));
            }
            
            var timer = try std.time.Timer.start();
            
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                stack.swap_unsafe(4);
            }
            
            pointer_time = timer.read();
        }
        
        const index_ns_per_op = index_time / iterations;
        const pointer_ns_per_op = pointer_time / iterations;
        const improvement = @as(f64, @floatFromInt(index_time)) / @as(f64, @floatFromInt(pointer_time));
        
        std.debug.print("SWAP Operations:\n", .{});
        std.debug.print("  Index-based:   {} ns/op\n", .{index_ns_per_op});
        std.debug.print("  Pointer-based: {} ns/op\n", .{pointer_ns_per_op});
        std.debug.print("  Improvement:   {d:.2}x\n\n", .{improvement});
    }
    
    std.debug.print("=== Pointer Stack Benefits ===\n", .{});
    std.debug.print("1. Fewer instructions per operation (no index arithmetic)\n", .{});
    std.debug.print("2. Better CPU pipeline utilization\n", .{});
    std.debug.print("3. Direct pointer manipulation\n", .{});
    std.debug.print("4. Reduced memory dependencies\n", .{});
}