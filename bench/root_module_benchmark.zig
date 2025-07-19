//! Root Module (root.zig) Benchmarks
//! 
//! This file implements specific benchmarks for the root.zig module 
//! as the main entry point for EVM components (Issue #49).
//!
//! Focuses on:
//! 1. Module import performance
//! 2. C API function call overhead
//! 3. Global state management performance
//! 4. Error code conversion costs
//! 5. Memory management in C API context

const std = @import("std");
const Allocator = std.mem.Allocator;
const print = std.debug.print;
const Timer = std.time.Timer;

// Import the root module (our main entry point)
const root = @import("../src/root.zig");
const timing = @import("timing.zig");

// Test constants
const BENCHMARK_ITERATIONS = 10000;
const WARMUP_ITERATIONS = 100;

/// Benchmark the cost of importing the entire root module
/// This measures compile-time vs runtime module loading costs
fn benchmark_module_import_cost() !void {
    // The cost of importing happens at compile time, but we can measure
    // the runtime cost of accessing the imported symbols
    
    const start = try Timer.start();
    
    // Access all major components to ensure they're loaded
    _ = root.Evm;
    _ = root.Primitives;
    _ = root.Provider;
    
    const elapsed = start.read();
    print("Module access cost: {}ns\n", .{elapsed});
}

/// Benchmark C API initialization performance
fn benchmark_c_api_init() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var times = std.ArrayList(u64).init(gpa.allocator());
    defer times.deinit();
    
    // Warmup
    var i: u32 = 0;
    while (i < WARMUP_ITERATIONS) : (i += 1) {
        _ = root.guillotine_init();
        root.guillotine_deinit();
    }
    
    // Actual benchmark
    i = 0;
    while (i < BENCHMARK_ITERATIONS) : (i += 1) {
        const start = try Timer.start();
        const result = root.guillotine_init();
        const init_time = start.read();
        
        if (result == 0) { // Success
            const deinit_start = try Timer.start();
            root.guillotine_deinit();
            const deinit_time = deinit_start.read();
            
            try times.append(init_time + deinit_time);
        }
    }
    
    if (times.items.len > 0) {
        std.sort.heap(u64, times.items, {}, std.sort.asc(u64));
        const total: u64 = blk: {
            var sum: u64 = 0;
            for (times.items) |time| sum += time;
            break :blk sum;
        };
        
        print("C API Init/Deinit - Avg: {}ns, Min: {}ns, Max: {}ns\n", .{
            total / times.items.len,
            times.items[0],
            times.items[times.items.len - 1],
        });
    }
}

/// Benchmark C API execution performance
fn benchmark_c_api_execution() !void {
    // Initialize the VM
    const init_result = root.guillotine_init();
    if (init_result != 0) {
        print("Failed to initialize VM for C API execution benchmark\n");
        return;
    }
    defer root.guillotine_deinit();
    
    // Simple contract bytecode for testing
    const simple_bytecode = [_]u8{
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0  
        0xF3,       // RETURN
    };
    
    const caller_addr = [_]u8{0x01} ** 20;
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var times = std.ArrayList(u64).init(gpa.allocator());
    defer times.deinit();
    
    // Warmup
    var i: u32 = 0;
    while (i < WARMUP_ITERATIONS) : (i += 1) {
        var result: root.CExecutionResult = undefined;
        _ = root.guillotine_execute(
            simple_bytecode.ptr,
            simple_bytecode.len,
            caller_addr.ptr,
            0, // value
            1000000, // gas_limit
            &result,
        );
    }
    
    // Actual benchmark
    i = 0;
    while (i < BENCHMARK_ITERATIONS) : (i += 1) {
        var result: root.CExecutionResult = undefined;
        
        const start = try Timer.start();
        const exec_result = root.guillotine_execute(
            simple_bytecode.ptr,
            simple_bytecode.len,
            caller_addr.ptr,
            0, // value
            1000000, // gas_limit
            &result,
        );
        const elapsed = start.read();
        
        if (exec_result == 0) { // Success
            try times.append(elapsed);
        }
    }
    
    if (times.items.len > 0) {
        std.sort.heap(u64, times.items, {}, std.sort.asc(u64));
        const total: u64 = blk: {
            var sum: u64 = 0;
            for (times.items) |time| sum += time;
            break :blk sum;
        };
        
        print("C API Execution - Avg: {}ns, Min: {}ns, Max: {}ns\n", .{
            total / times.items.len,
            times.items[0],
            times.items[times.items.len - 1],
        });
    }
}

/// Benchmark error code conversion overhead
fn benchmark_error_code_conversion() !void {
    var timer = try Timer.start();
    
    // Simulate error code conversions that happen in C API
    var i: u32 = 0;
    while (i < BENCHMARK_ITERATIONS) : (i += 1) {
        // Simulate the enum to int conversions that happen in root.zig
        const error_codes = [_]root.GuillotineError{
            root.GuillotineError.GUILLOTINE_OK,
            root.GuillotineError.GUILLOTINE_ERROR_MEMORY,
            root.GuillotineError.GUILLOTINE_ERROR_INVALID_PARAM,
            root.GuillotineError.GUILLOTINE_ERROR_VM_NOT_INITIALIZED,
            root.GuillotineError.GUILLOTINE_ERROR_EXECUTION_FAILED,
            root.GuillotineError.GUILLOTINE_ERROR_INVALID_ADDRESS,
            root.GuillotineError.GUILLOTINE_ERROR_INVALID_BYTECODE,
        };
        
        for (error_codes) |err_code| {
            _ = @intFromEnum(err_code);
        }
    }
    
    const elapsed = timer.read();
    const avg_per_conversion = elapsed / (BENCHMARK_ITERATIONS * 7); // 7 error codes per iteration
    print("Error Code Conversion - Total: {}ns, Avg per conversion: {}ns\n", .{ elapsed, avg_per_conversion });
}

/// Benchmark global state management
fn benchmark_global_state_access() !void {
    var timer = try Timer.start();
    
    // Benchmark accessing global VM instance (as done in C API)
    var i: u32 = 0;
    while (i < BENCHMARK_ITERATIONS) : (i += 1) {
        // This simulates the global state checks that happen in the C API
        const is_init = root.guillotine_is_initialized();
        _ = is_init;
    }
    
    const elapsed = timer.read();
    const avg_per_access = elapsed / BENCHMARK_ITERATIONS;
    print("Global State Access - Total: {}ns, Avg per access: {}ns\n", .{ elapsed, avg_per_access });
}

/// Benchmark version string access (simple but commonly called)
fn benchmark_version_access() !void {
    var timer = try Timer.start();
    
    var i: u32 = 0;
    while (i < BENCHMARK_ITERATIONS) : (i += 1) {
        _ = root.guillotine_version();
    }
    
    const elapsed = timer.read();
    const avg_per_access = elapsed / BENCHMARK_ITERATIONS;
    print("Version Access - Total: {}ns, Avg per access: {}ns\n", .{ elapsed, avg_per_access });
}

/// Benchmark memory allocation patterns in C API context  
fn benchmark_c_api_memory_patterns() !void {
    // This tests the global allocator usage patterns used in root.zig
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var times = std.ArrayList(u64).init(gpa.allocator());
    defer times.deinit();
    
    var i: u32 = 0;
    while (i < 100) : (i += 1) { // Smaller number due to allocation costs
        const start = try Timer.start();
        
        // Simulate the memory allocation pattern used in guillotine_init
        const init_result = root.guillotine_init();
        if (init_result == 0) {
            root.guillotine_deinit();
        }
        
        const elapsed = start.read();
        try times.append(elapsed);
    }
    
    if (times.items.len > 0) {
        std.sort.heap(u64, times.items, {}, std.sort.asc(u64));
        const total: u64 = blk: {
            var sum: u64 = 0;
            for (times.items) |time| sum += time;
            break :blk sum;
        };
        
        print("Memory Allocation Pattern - Avg: {}ns, Min: {}ns, Max: {}ns\n", .{
            total / times.items.len,
            times.items[0],
            times.items[times.items.len - 1],
        });
    }
}

/// Comprehensive root module performance test
fn benchmark_comprehensive_root_usage() !void {
    print("Comprehensive Root Module Usage Benchmark...\n");
    
    var overall_timer = try Timer.start();
    
    // Simulate a typical usage pattern of the root module
    const iterations = 1000;
    var successful_runs: u32 = 0;
    
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        // Initialize
        if (root.guillotine_init() == 0) {
            // Check if initialized
            if (root.guillotine_is_initialized() == 1) {
                // Execute some bytecode
                const bytecode = [_]u8{ 0x60, 0x01, 0x60, 0x01, 0x01, 0x00 }; // PUSH1 1, PUSH1 1, ADD, STOP
                const caller = [_]u8{0x01} ** 20;
                var result: root.CExecutionResult = undefined;
                
                const exec_result = root.guillotine_execute(
                    bytecode.ptr,
                    bytecode.len,
                    caller.ptr,
                    0,
                    100000,
                    &result,
                );
                
                if (exec_result == 0) {
                    successful_runs += 1;
                }
            }
            
            // Clean up
            root.guillotine_deinit();
        }
    }
    
    const total_time = overall_timer.read();
    const avg_per_cycle = if (successful_runs > 0) total_time / successful_runs else 0;
    
    print("Comprehensive Usage - {} successful cycles, Avg per cycle: {}ns\n", .{ successful_runs, avg_per_cycle });
}

/// Main entry point for root module benchmarks
pub fn run_root_module_benchmarks(allocator: Allocator) !void {
    _ = allocator;
    print("\n=== Root Module (root.zig) Performance Benchmarks ===\n\n");
    
    print("1. Module Import Cost...\n");
    try benchmark_module_import_cost();
    
    print("\n2. C API Initialization...\n");
    try benchmark_c_api_init();
    
    print("\n3. C API Execution...\n");
    try benchmark_c_api_execution();
    
    print("\n4. Error Code Conversion...\n");
    try benchmark_error_code_conversion();
    
    print("\n5. Global State Access...\n");
    try benchmark_global_state_access();
    
    print("\n6. Version Access...\n");
    try benchmark_version_access();
    
    print("\n7. Memory Allocation Patterns...\n");
    try benchmark_c_api_memory_patterns();
    
    print("\n8. Comprehensive Usage...\n");
    try benchmark_comprehensive_root_usage();
    
    print("\n=== Root Module Benchmarks Complete ===\n\n");
}

// Test to ensure compilation
test "Root module benchmarks compile" {
    try benchmark_module_import_cost();
    try benchmark_error_code_conversion();
    try benchmark_global_state_access();
    try benchmark_version_access();
}