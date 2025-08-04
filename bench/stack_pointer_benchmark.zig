const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();
    
    if (builtin.mode != .ReleaseFast) {
        try stdout.print("Warning: Run with -O ReleaseFast for accurate benchmarks\n", .{});
    }
    
    try benchmark_stack_implementations(allocator);
}

fn benchmark_stack_implementations(_: std.mem.Allocator) !void {
    const Evm = @import("evm");
    const Stack = Evm.Stack;
    const PointerStack = Evm.PointerStack;
    const stdout = std.io.getStdOut().writer();
    
    const warmup_iterations = 10_000;
    const benchmark_iterations = 1_000_000;
    
    try stdout.print("\n=== Stack Implementation Benchmark ===\n", .{});
    try stdout.print("Comparing index-based vs pointer-based stack\n", .{});
    try stdout.print("Iterations: {}\n\n", .{benchmark_iterations});
    
    // Warmup
    try stdout.print("Warming up...\n", .{});
    for (0..warmup_iterations) |_| {
        var index_stack = Stack{};
        var pointer_stack = PointerStack.init();
        pointer_stack.setup();
        
        for (0..10) |i| {
            index_stack.append_unsafe(@intCast(i));
            pointer_stack.append_unsafe(@intCast(i));
        }
        
        _ = index_stack.pop_unsafe();
        _ = pointer_stack.pop_unsafe();
    }
    
    // Benchmark 1: Push/Pop operations
    try stdout.print("\n1. Push/Pop Operations (1M iterations):\n", .{});
    
    // Index-based stack
    {
        var stack = Stack{};
        var timer = try std.time.Timer.start();
        
        for (0..benchmark_iterations) |i| {
            stack.append_unsafe(@intCast(i & 0xFF));
            _ = stack.pop_unsafe();
        }
        
        const elapsed_ns = timer.read();
        const ops_per_sec = (benchmark_iterations * 2 * 1_000_000_000) / elapsed_ns;
        
        try stdout.print("  Index-based: {} ns total, {} ops/sec\n", .{elapsed_ns, ops_per_sec});
    }
    
    // Pointer-based stack
    {
        var stack = PointerStack.init();
        stack.setup();
        var timer = try std.time.Timer.start();
        
        for (0..benchmark_iterations) |i| {
            stack.append_unsafe(@intCast(i & 0xFF));
            _ = stack.pop_unsafe();
        }
        
        const elapsed_ns = timer.read();
        const ops_per_sec = (benchmark_iterations * 2 * 1_000_000_000) / elapsed_ns;
        
        try stdout.print("  Pointer-based: {} ns total, {} ops/sec\n", .{elapsed_ns, ops_per_sec});
    }
    
    // Benchmark 2: Realistic EVM operation pattern
    try stdout.print("\n2. Realistic EVM Pattern (ADD operations):\n", .{});
    
    // Index-based stack
    {
        var stack = Stack{};
        var timer = try std.time.Timer.start();
        
        for (0..benchmark_iterations / 10) |i| {
            // Simulate ADD operation pattern
            stack.append_unsafe(@intCast(i & 0xFF));
            stack.append_unsafe(@intCast((i + 1) & 0xFF));
            const b = stack.pop_unsafe();
            const a = stack.pop_unsafe();
            stack.append_unsafe(a +% b);
        }
        
        const elapsed_ns = timer.read();
        const adds_per_sec = ((benchmark_iterations / 10) * 1_000_000_000) / elapsed_ns;
        
        try stdout.print("  Index-based: {} ns total, {} ADD ops/sec\n", .{elapsed_ns, adds_per_sec});
    }
    
    // Pointer-based stack
    {
        var stack = PointerStack.init();
        stack.setup();
        var timer = try std.time.Timer.start();
        
        for (0..benchmark_iterations / 10) |i| {
            // Simulate ADD operation pattern
            stack.append_unsafe(@intCast(i & 0xFF));
            stack.append_unsafe(@intCast((i + 1) & 0xFF));
            const b = stack.pop_unsafe();
            const a = stack.pop_unsafe();
            stack.append_unsafe(a +% b);
        }
        
        const elapsed_ns = timer.read();
        const adds_per_sec = ((benchmark_iterations / 10) * 1_000_000_000) / elapsed_ns;
        
        try stdout.print("  Pointer-based: {} ns total, {} ADD ops/sec\n", .{elapsed_ns, adds_per_sec});
    }
    
    // Benchmark 3: DUP and SWAP operations
    try stdout.print("\n3. DUP and SWAP Operations:\n", .{});
    
    // Index-based stack
    {
        var stack = Stack{};
        // Pre-fill stack
        for (0..16) |i| {
            stack.append_unsafe(@intCast(i));
        }
        
        var timer = try std.time.Timer.start();
        
        for (0..benchmark_iterations / 10) |_| {
            stack.dup_unsafe(8);
            _ = stack.pop_unsafe();
            stack.swap_unsafe(4);
        }
        
        const elapsed_ns = timer.read();
        const ops_per_sec = ((benchmark_iterations / 10) * 3 * 1_000_000_000) / elapsed_ns;
        
        try stdout.print("  Index-based: {} ns total, {} ops/sec\n", .{elapsed_ns, ops_per_sec});
    }
    
    // Pointer-based stack
    {
        var stack = PointerStack.init();
        stack.setup();
        // Pre-fill stack
        for (0..16) |i| {
            stack.append_unsafe(@intCast(i));
        }
        
        var timer = try std.time.Timer.start();
        
        for (0..benchmark_iterations / 10) |_| {
            stack.dup_unsafe(8);
            _ = stack.pop_unsafe();
            stack.swap_unsafe(4);
        }
        
        const elapsed_ns = timer.read();
        const ops_per_sec = ((benchmark_iterations / 10) * 3 * 1_000_000_000) / elapsed_ns;
        
        try stdout.print("  Pointer-based: {} ns total, {} ops/sec\n", .{elapsed_ns, ops_per_sec});
    }
    
    // Benchmark 4: Multi-pop operations
    try stdout.print("\n4. Multi-Pop Operations (pop2/pop3):\n", .{});
    
    // Index-based stack
    {
        var stack = Stack{};
        var timer = try std.time.Timer.start();
        
        for (0..benchmark_iterations / 10) |i| {
            stack.append_unsafe(@intCast(i & 0xFF));
            stack.append_unsafe(@intCast((i + 1) & 0xFF));
            stack.append_unsafe(@intCast((i + 2) & 0xFF));
            _ = stack.pop2_unsafe();
            stack.append_unsafe(@intCast((i + 3) & 0xFF));
        }
        
        const elapsed_ns = timer.read();
        const ops_per_sec = ((benchmark_iterations / 10) * 5 * 1_000_000_000) / elapsed_ns;
        
        try stdout.print("  Index-based: {} ns total, {} ops/sec\n", .{elapsed_ns, ops_per_sec});
    }
    
    // Pointer-based stack
    {
        var stack = PointerStack.init();
        stack.setup();
        var timer = try std.time.Timer.start();
        
        for (0..benchmark_iterations / 10) |i| {
            stack.append_unsafe(@intCast(i & 0xFF));
            stack.append_unsafe(@intCast((i + 1) & 0xFF));
            stack.append_unsafe(@intCast((i + 2) & 0xFF));
            _ = stack.pop2_unsafe();
            stack.append_unsafe(@intCast((i + 3) & 0xFF));
        }
        
        const elapsed_ns = timer.read();
        const ops_per_sec = ((benchmark_iterations / 10) * 5 * 1_000_000_000) / elapsed_ns;
        
        try stdout.print("  Pointer-based: {} ns total, {} ops/sec\n", .{elapsed_ns, ops_per_sec});
    }
    
    // Memory usage analysis
    try stdout.print("\n5. Memory Layout Analysis:\n", .{});
    try stdout.print("  Index-based: {} bytes (data + size field)\n", .{@sizeOf(Stack)});
    try stdout.print("  Pointer-based: {} bytes (data + 2 pointers)\n", .{@sizeOf(PointerStack)});
    
    const index_overhead = @sizeOf(usize);
    const pointer_overhead = @sizeOf([*]u256) * 2;
    
    try stdout.print("  Overhead difference: {} bytes\n", .{
        @as(isize, @intCast(pointer_overhead)) - @as(isize, @intCast(index_overhead))
    });
    
    try stdout.print("\n6. Expected Benefits:\n", .{});
    try stdout.print("  - Fewer instructions per operation\n", .{});
    try stdout.print("  - Better CPU pipeline utilization\n", .{});
    try stdout.print("  - Reduced memory dependencies\n", .{});
    try stdout.print("  - Improved cache locality for hot operations\n", .{});
}