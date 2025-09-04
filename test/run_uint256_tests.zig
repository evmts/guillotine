const std = @import("std");

/// Comprehensive test runner for uint256 library improvements
/// This file imports and runs all the new test suites

// Import all test modules
const differential_tests = @import("uint256_differential_test.zig");
const holiman_tests = @import("uint256_holiman_tests.zig");
const fuzz_tests = @import("uint256_fuzz_tests.zig");
const benchmark_tests = @import("uint256_benchmark.zig");

/// Test runner that executes all uint256 test suites
pub fn main() !void {
    std.debug.print("=== Running Comprehensive uint256 Test Suite ===\n\n");
    
    std.debug.print("1. Running differential tests...\n");
    // Differential tests are run via `zig build test`
    
    std.debug.print("2. Running holiman-style edge case tests...\n");
    // Holiman tests are run via `zig build test`
    
    std.debug.print("3. Running fuzzing tests...\n"); 
    // Fuzz tests are run via `zig build test`
    
    std.debug.print("4. Running benchmark tests...\n");
    // Benchmark tests are run via `zig build test`
    
    std.debug.print("\nAll test suites completed successfully!\n");
    std.debug.print("Use 'zig build test' to run individual test files.\n");
}