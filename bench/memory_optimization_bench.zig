/// Benchmark to compare memory operations with and without pre-calculated expansion costs
const std = @import("std");
const zbench = @import("zbench");

// Simulate memory expansion cost calculation
fn calculate_expansion_cost(current_size: u64, new_size: u64) u64 {
    if (new_size <= current_size) return 0;
    
    const current_words = (current_size + 31) / 32;
    const new_words = (new_size + 31) / 32;
    
    const current_cost = 3 * current_words + (current_words * current_words) / 512;
    const new_cost = 3 * new_words + (new_words * new_words) / 512;
    
    return new_cost - current_cost;
}

// Benchmark runtime memory expansion calculation
fn benchmark_runtime_expansion(allocator: std.mem.Allocator) void {
    _ = allocator;
    var current_size: u64 = 0;
    
    // Simulate 100 memory operations with expansion
    for (0..100) |i| {
        const offset = i * 32;
        const size: u64 = 32;
        const required_size = offset + size;
        
        const expansion_cost = calculate_expansion_cost(current_size, required_size);
        current_size = @max(current_size, required_size);
        
        // Simulate gas deduction
        var gas_left: i64 = 100000;
        gas_left -= @as(i64, @intCast(expansion_cost));
        std.mem.doNotOptimizeAway(gas_left);
    }
}

// Benchmark pre-calculated memory expansion
fn benchmark_precalculated_expansion(allocator: std.mem.Allocator) void {
    _ = allocator;
    
    // Pre-calculated costs for each operation
    const pre_calculated_costs = [_]u64{
        3,   // 0->32 bytes (1 word)
        3,   // 32->64 bytes (1 more word)
        3,   // 64->96 bytes (1 more word)
        3,   // 96->128 bytes (1 more word)
        // ... pattern continues
    } ** 25;
    
    // Simulate 100 memory operations with pre-calculated costs
    for (0..100) |i| {
        const expansion_cost = if (i < pre_calculated_costs.len) 
            pre_calculated_costs[i] 
        else 
            3; // Default cost
        
        // Direct gas deduction - no calculation needed
        var gas_left: i64 = 100000;
        gas_left -= @as(i64, @intCast(expansion_cost));
        std.mem.doNotOptimizeAway(gas_left);
    }
}

// Benchmark memory operation with inline expansion check
fn benchmark_inline_memory_check(allocator: std.mem.Allocator) void {
    _ = allocator;
    var memory_size: u64 = 0;
    var gas_left: i64 = 100000;
    
    // Simulate memory store operations
    for (0..100) |i| {
        const offset = i * 32;
        const value: u64 = 0x42;
        
        // Inline memory expansion check
        const required_size = offset + 32;
        if (required_size > memory_size) {
            const expansion_cost = calculate_expansion_cost(memory_size, required_size);
            gas_left -= @as(i64, @intCast(expansion_cost));
            memory_size = required_size;
        }
        
        // Simulate memory write
        std.mem.doNotOptimizeAway(value);
        std.mem.doNotOptimizeAway(offset);
    }
    
    std.mem.doNotOptimizeAway(gas_left);
}

// Benchmark optimized memory operation with no expansion check
fn benchmark_optimized_memory_no_check(allocator: std.mem.Allocator) void {
    _ = allocator;
    var gas_left: i64 = 100000;
    
    // Pre-deduct all expansion costs
    gas_left -= 300; // Pre-calculated total
    
    // Simulate memory store operations without checks
    for (0..100) |i| {
        const offset = i * 32;
        const value: u64 = 0x42;
        
        // Direct memory write - no expansion check needed
        std.mem.doNotOptimizeAway(value);
        std.mem.doNotOptimizeAway(offset);
    }
    
    std.mem.doNotOptimizeAway(gas_left);
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    
    var bench = zbench.Benchmark.init(std.heap.page_allocator, .{});
    defer bench.deinit();
    
    try bench.add("Runtime Memory Expansion Calculation", benchmark_runtime_expansion, .{});
    try bench.add("Pre-calculated Memory Expansion", benchmark_precalculated_expansion, .{});
    try bench.add("Inline Memory Expansion Check", benchmark_inline_memory_check, .{});
    try bench.add("Optimized No Expansion Check", benchmark_optimized_memory_no_check, .{});
    
    try stdout.print("\n=== Memory Expansion Optimization Benchmark ===\n\n", .{});
    try bench.run(stdout);
}