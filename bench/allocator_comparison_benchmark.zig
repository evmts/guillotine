const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const primitives = root.primitives;
const Allocator = std.mem.Allocator;
const EvmMemoryAllocator = @import("../src/evm/memory/evm_allocator.zig").EvmMemoryAllocator;

/// Benchmark results structure
const BenchmarkResult = struct {
    name: []const u8,
    standard_allocator_ns: u64,
    evm_allocator_ns: u64,
    improvement_percent: f64,
};

var results: [10]BenchmarkResult = undefined;
var results_count: usize = 0;

/// Helper to measure execution time
fn measureTime(comptime func: anytype, args: anytype) u64 {
    const start = std.time.nanoTimestamp();
    @call(.auto, func, args);
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

/// Benchmark 1: EVM initialization and basic operation
pub fn benchmark_evm_init(allocator: Allocator) void {
    const iterations = 100;
    
    // Standard allocator
    const standard_time = measureTime(struct {
        fn run(alloc: Allocator, iter: usize) void {
            var i: usize = 0;
            while (i < iter) : (i += 1) {
                var memory_db = Evm.MemoryDatabase.init(alloc);
                defer memory_db.deinit();
                
                const db_interface = memory_db.to_database_interface();
                var evm_instance = Evm.Evm.init(alloc, db_interface) catch unreachable;
                defer evm_instance.deinit();
            }
        }
    }.run, .{ allocator, iterations });
    
    // EVM allocator
    const evm_time = measureTime(struct {
        fn run(alloc: Allocator, iter: usize) void {
            var evm_allocator = EvmMemoryAllocator.init(alloc) catch unreachable;
            defer evm_allocator.deinit();
            const evm_alloc = evm_allocator.allocator();
            
            var i: usize = 0;
            while (i < iter) : (i += 1) {
                var memory_db = Evm.MemoryDatabase.init(evm_alloc);
                defer memory_db.deinit();
                
                const db_interface = memory_db.to_database_interface();
                var evm_instance = Evm.Evm.init(evm_alloc, db_interface) catch unreachable;
                defer evm_instance.deinit();
                
                // Reset allocator for reuse
                evm_allocator.reset();
            }
        }
    }.run, .{ allocator, iterations });
    
    const improvement = @as(f64, @floatFromInt(standard_time - evm_time)) / @as(f64, @floatFromInt(standard_time)) * 100.0;
    results[results_count] = .{
        .name = "EVM Initialization",
        .standard_allocator_ns = standard_time / iterations,
        .evm_allocator_ns = evm_time / iterations,
        .improvement_percent = improvement,
    };
    results_count += 1;
}

/// Benchmark 2: Contract execution with memory-intensive operations
pub fn benchmark_memory_intensive_contract(allocator: Allocator) void {
    const iterations = 50;
    
    // Memory-intensive bytecode (lots of MSTORE/MLOAD operations)
    const bytecode = [_]u8{
        // Initialize memory with pattern
        0x60, 0x00, // PUSH1 0 (offset)
        0x5b,       // JUMPDEST (loop start)
        0x80,       // DUP1
        0x60, 0xff, // PUSH1 255
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x01,       // ADD
        0x80,       // DUP1
        0x61, 0x10, 0x00, // PUSH2 4096
        0x10,       // LT
        0x60, 0x03, // PUSH1 3
        0x57,       // JUMPI (back to loop start)
        0x00,       // STOP
    };
    
    // Standard allocator
    const standard_time = measureTime(struct {
        fn run(alloc: Allocator, code: []const u8, iter: usize) void {
            var i: usize = 0;
            while (i < iter) : (i += 1) {
                var memory_db = Evm.MemoryDatabase.init(alloc);
                defer memory_db.deinit();
                
                const db_interface = memory_db.to_database_interface();
                var evm = Evm.Evm.init(alloc, db_interface) catch unreachable;
                defer evm.deinit();
                
                const address = primitives.Address.from_u256(0x1000);
                evm.state.set_balance(address, 1000000) catch unreachable;
                
                var contract = Evm.Contract.init(alloc, code, .{ .address = address }) catch unreachable;
                defer contract.deinit(alloc, null);
                
                _ = evm.interpret(&contract, &[_]u8{}) catch unreachable;
            }
        }
    }.run, .{ allocator, &bytecode, iterations });
    
    // EVM allocator
    const evm_time = measureTime(struct {
        fn run(alloc: Allocator, code: []const u8, iter: usize) void {
            var evm_allocator = EvmMemoryAllocator.init(alloc) catch unreachable;
            defer evm_allocator.deinit();
            const evm_alloc = evm_allocator.allocator();
            
            var i: usize = 0;
            while (i < iter) : (i += 1) {
                var memory_db = Evm.MemoryDatabase.init(evm_alloc);
                defer memory_db.deinit();
                
                const db_interface = memory_db.to_database_interface();
                var evm = Evm.Evm.init(evm_alloc, db_interface) catch unreachable;
                defer evm.deinit();
                
                const address = primitives.Address.from_u256(0x1000);
                evm.state.set_balance(address, 1000000) catch unreachable;
                
                var contract = Evm.Contract.init(evm_alloc, code, .{ .address = address }) catch unreachable;
                defer contract.deinit(evm_alloc, null);
                
                _ = evm.interpret(&contract, &[_]u8{}) catch unreachable;
                
                // Reset for next iteration
                evm_allocator.reset();
            }
        }
    }.run, .{ allocator, &bytecode, iterations });
    
    const improvement = @as(f64, @floatFromInt(standard_time - evm_time)) / @as(f64, @floatFromInt(standard_time)) * 100.0;
    results[results_count] = .{
        .name = "Memory-Intensive Contract",
        .standard_allocator_ns = standard_time / iterations,
        .evm_allocator_ns = evm_time / iterations,
        .improvement_percent = improvement,
    };
    results_count += 1;
}

/// Benchmark 3: Many small allocations (simulating complex contract state)
pub fn benchmark_many_small_allocations(allocator: Allocator) void {
    const iterations = 100;
    const allocations_per_iteration = 1000;
    
    // Standard allocator
    const standard_time = measureTime(struct {
        fn run(alloc: Allocator, iter: usize, allocs: usize) void {
            var i: usize = 0;
            while (i < iter) : (i += 1) {
                var ptrs = std.ArrayList(*u256).init(alloc);
                defer {
                    for (ptrs.items) |ptr| {
                        alloc.destroy(ptr);
                    }
                    ptrs.deinit();
                }
                
                var j: usize = 0;
                while (j < allocs) : (j += 1) {
                    const ptr = alloc.create(u256) catch unreachable;
                    ptr.* = j;
                    ptrs.append(ptr) catch unreachable;
                }
            }
        }
    }.run, .{ allocator, iterations, allocations_per_iteration });
    
    // EVM allocator
    const evm_time = measureTime(struct {
        fn run(alloc: Allocator, iter: usize, allocs: usize) void {
            var evm_allocator = EvmMemoryAllocator.init(alloc) catch unreachable;
            defer evm_allocator.deinit();
            const evm_alloc = evm_allocator.allocator();
            
            var i: usize = 0;
            while (i < iter) : (i += 1) {
                var ptrs = std.ArrayList(*u256).init(evm_alloc);
                defer ptrs.deinit();
                
                var j: usize = 0;
                while (j < allocs) : (j += 1) {
                    const ptr = evm_alloc.create(u256) catch unreachable;
                    ptr.* = j;
                    ptrs.append(ptr) catch unreachable;
                }
                
                // Reset allocator (no individual frees needed)
                evm_allocator.reset();
            }
        }
    }.run, .{ allocator, iterations, allocations_per_iteration });
    
    const improvement = @as(f64, @floatFromInt(standard_time - evm_time)) / @as(f64, @floatFromInt(standard_time)) * 100.0;
    results[results_count] = .{
        .name = "Many Small Allocations",
        .standard_allocator_ns = standard_time / iterations,
        .evm_allocator_ns = evm_time / iterations,
        .improvement_percent = improvement,
    };
    results_count += 1;
}

/// Benchmark 4: Large memory growth patterns
pub fn benchmark_memory_growth(allocator: Allocator) void {
    const iterations = 50;
    
    // Standard allocator
    const standard_time = measureTime(struct {
        fn run(alloc: Allocator, iter: usize) void {
            var i: usize = 0;
            while (i < iter) : (i += 1) {
                var list = std.ArrayList(u8).init(alloc);
                defer list.deinit();
                
                // Simulate growing memory usage
                var size: usize = 1024;
                while (size <= 1024 * 1024) : (size *= 2) {
                    list.ensureTotalCapacity(size) catch unreachable;
                    list.items.len = size;
                    @memset(list.items, 0xFF);
                }
            }
        }
    }.run, .{ allocator, iterations });
    
    // EVM allocator
    const evm_time = measureTime(struct {
        fn run(alloc: Allocator, iter: usize) void {
            var evm_allocator = EvmMemoryAllocator.init(alloc) catch unreachable;
            defer evm_allocator.deinit();
            const evm_alloc = evm_allocator.allocator();
            
            var i: usize = 0;
            while (i < iter) : (i += 1) {
                var list = std.ArrayList(u8).init(evm_alloc);
                defer list.deinit();
                
                // Simulate growing memory usage
                var size: usize = 1024;
                while (size <= 1024 * 1024) : (size *= 2) {
                    list.ensureTotalCapacity(size) catch unreachable;
                    list.items.len = size;
                    @memset(list.items, 0xFF);
                }
                
                evm_allocator.reset();
            }
        }
    }.run, .{ allocator, iterations });
    
    const improvement = @as(f64, @floatFromInt(standard_time - evm_time)) / @as(f64, @floatFromInt(standard_time)) * 100.0;
    results[results_count] = .{
        .name = "Memory Growth Pattern",
        .standard_allocator_ns = standard_time / iterations,
        .evm_allocator_ns = evm_time / iterations,
        .improvement_percent = improvement,
    };
    results_count += 1;
}

/// Run all benchmarks and print results
pub fn run_all_benchmarks(allocator: Allocator) void {
    std.log.info("=== EVM Allocator vs Standard Allocator Benchmarks ===\n", .{});
    
    results_count = 0;
    
    // Run benchmarks
    benchmark_evm_init(allocator);
    benchmark_memory_intensive_contract(allocator);
    benchmark_many_small_allocations(allocator);
    benchmark_memory_growth(allocator);
    
    // Print results
    std.log.info("{s:<30} | {s:>20} | {s:>20} | {s:>15}", .{
        "Benchmark",
        "Standard (ns)",
        "EVM Allocator (ns)",
        "Improvement %"
    });
    std.log.info("{s:-<90}", .{""});
    
    var i: usize = 0;
    while (i < results_count) : (i += 1) {
        const result = results[i];
        std.log.info("{s:<30} | {d:>20} | {d:>20} | {d:>14.1}%", .{
            result.name,
            result.standard_allocator_ns,
            result.evm_allocator_ns,
            result.improvement_percent,
        });
    }
    
    // Calculate average improvement
    var total_improvement: f64 = 0;
    i = 0;
    while (i < results_count) : (i += 1) {
        total_improvement += results[i].improvement_percent;
    }
    const avg_improvement = total_improvement / @as(f64, @floatFromInt(results_count));
    
    std.log.info("{s:-<90}", .{""});
    std.log.info("Average improvement: {d:.1}%\n", .{avg_improvement});
}

/// Entry point for standalone benchmark execution
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    run_all_benchmarks(allocator);
}