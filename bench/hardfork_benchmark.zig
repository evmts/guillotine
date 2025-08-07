const std = @import("std");
const Allocator = std.mem.Allocator;
const timing = @import("timing.zig");
const BenchmarkConfig = timing.BenchmarkConfig;
const BenchmarkResult = timing.BenchmarkResult;

// Import hardfork types
const Hardfork = @import("evm").Hardfork.Hardfork;
const ChainRules = @import("evm").chain_rules;
const Frame = @import("../src/evm/execution_context.zig").Frame;

/// Comprehensive benchmarks for hardfork logic and chain rules.
/// These benchmarks measure the overhead of hardfork checks that are
/// performed frequently during EVM execution.

/// Benchmark hardfork flag checks (is_byzantium, is_berlin, etc.)
/// Tests the performance of individual boolean flag checks across all hardforks
pub fn hardfork_flag_checks_benchmark(allocator: Allocator) !BenchmarkResult {
    const TestFunc = struct {
        fn run() void {
            const rules_frontier = Frame.chainRulesForHardfork(.FRONTIER);
            const rules_byzantium = Frame.chainRulesForHardfork(.BYZANTIUM);
            const rules_berlin = Frame.chainRulesForHardfork(.BERLIN);
            const rules_london = Frame.chainRulesForHardfork(.LONDON);
            const rules_shanghai = Frame.chainRulesForHardfork(.SHANGHAI);
            const rules_cancun = Frame.chainRulesForHardfork(.CANCUN);
            // Test common hardfork checks that happen frequently
            var counter: u32 = 0;
            
            // Simulate checking multiple hardfork flags
            if (rules_byzantium.is_byzantium) counter += 1;
            if (rules_berlin.is_berlin) counter += 2;
            if (rules_london.is_london) counter += 3;
            if (rules_shanghai.is_shanghai) counter += 4;
            if (rules_cancun.is_cancun) counter += 5;
            
            // EIP-specific checks
            if (rules_berlin.is_eip2930) counter += 1;
            if (rules_london.is_eip1559) counter += 2;
            if (rules_london.is_eip3198) counter += 3;
            if (rules_shanghai.is_eip3855) counter += 4;
            if (rules_cancun.is_eip4844) counter += 5;
            
            // Include frontier checks for comparison
            if (rules_frontier.is_homestead) counter += 1;
            
            // Prevent optimization
            std.mem.doNotOptimizeAway(counter);
        }
    };
    
    return timing.benchmark_with_args(allocator, BenchmarkConfig{
        .name = "Hardfork Flag Checks",
        .iterations = 10000,
        .warmup_iterations = 100,
    }, TestFunc.run, .{});
}

/// Benchmark chain rules initialization performance
/// Tests the cost of creating ChainRules for different hardforks
pub fn chain_rules_initialization_benchmark(allocator: Allocator) !BenchmarkResult {
    const TestFunc = struct {
        fn run() void {
            // Test initialization for various hardforks
            const rules1 = Frame.chainRulesForHardfork(.FRONTIER);
            const rules2 = Frame.chainRulesForHardfork(.BYZANTIUM);
            const rules3 = Frame.chainRulesForHardfork(.BERLIN);
            const rules4 = Frame.chainRulesForHardfork(.LONDON);
            const rules5 = Frame.chainRulesForHardfork(.SHANGHAI);
            const rules6 = Frame.chainRulesForHardfork(.CANCUN);
            
            // Prevent optimization
            std.mem.doNotOptimizeAway(rules1);
            std.mem.doNotOptimizeAway(rules2);
            std.mem.doNotOptimizeAway(rules3);
            std.mem.doNotOptimizeAway(rules4);
            std.mem.doNotOptimizeAway(rules5);
            std.mem.doNotOptimizeAway(rules6);
        }
    };
    
    return timing.benchmark_with_args(allocator, BenchmarkConfig{
        .name = "Chain Rules Initialization",
        .iterations = 10000,
        .warmup_iterations = 100,
    }, TestFunc.run, .{});
}

/// Benchmark feature availability lookups
/// Tests the performance of determining which features are available for specific hardforks
pub fn feature_availability_lookup_benchmark(allocator: Allocator) !BenchmarkResult {
    const TestFunc = struct {
        fn run() void {
            const rules_cancun = Frame.chainRulesForHardfork(.CANCUN);
            const rules_london = Frame.chainRulesForHardfork(.LONDON);
            const rules_berlin = Frame.chainRulesForHardfork(.BERLIN);
            const rules_byzantium = Frame.chainRulesForHardfork(.BYZANTIUM);
            var feature_count: u32 = 0;
            
            // Check for various features across different hardforks
            if (rules_byzantium.is_byzantium) feature_count += 1;
            if (rules_berlin.is_berlin and rules_berlin.is_eip2930) feature_count += 1;
            if (rules_london.is_london and rules_london.is_eip1559) feature_count += 1;
            if (rules_cancun.is_cancun and rules_cancun.is_eip4844) feature_count += 1;
            if (rules_cancun.is_eip1153) feature_count += 1; // Transient storage
            
            // Simulate common feature combinations
            const has_access_lists = rules_berlin.is_berlin;
            const has_basefee = rules_london.is_eip3198;
            const has_push0 = rules_cancun.is_eip3855;
            
            if (has_access_lists) feature_count += 1;
            if (has_basefee) feature_count += 1;
            if (has_push0) feature_count += 1;
            
            // Prevent optimization
            std.mem.doNotOptimizeAway(feature_count);
        }
    };
    
    return timing.benchmark_with_args(allocator, BenchmarkConfig{
        .name = "Feature Availability Lookup",
        .iterations = 10000,
        .warmup_iterations = 100,
    }, TestFunc.run, .{});
}

/// Benchmark opcode availability by hardfork
/// Tests the performance of checking which opcodes are available for specific hardforks
pub fn opcode_availability_by_hardfork_benchmark(allocator: Allocator) !BenchmarkResult {
    const TestFunc = struct {
        fn run() void {
            var available_opcodes: u32 = 0;
            
            // Test opcode availability for different hardforks
            const rules_byzantium = Frame.chainRulesForHardfork(.BYZANTIUM);
            const rules_constantinople = Frame.chainRulesForHardfork(.CONSTANTINOPLE);
            const rules_istanbul = Frame.chainRulesForHardfork(.ISTANBUL);
            const rules_shanghai = Frame.chainRulesForHardfork(.SHANGHAI);
            const rules_cancun = Frame.chainRulesForHardfork(.CANCUN);
            
            // Byzantium opcodes: REVERT, RETURNDATASIZE, RETURNDATACOPY, STATICCALL
            if (rules_byzantium.is_byzantium) available_opcodes += 4;
            
            // Constantinople opcodes: SHL, SHR, SAR, EXTCODEHASH, CREATE2
            if (rules_constantinople.is_constantinople) available_opcodes += 5;
            
            // Istanbul opcodes: CHAINID, SELFBALANCE
            if (rules_istanbul.is_istanbul) available_opcodes += 2;
            
            // Shanghai opcodes: PUSH0
            if (rules_shanghai.is_eip3855) available_opcodes += 1;
            
            // Cancun opcodes: TLOAD, TSTORE, MCOPY, BLOBHASH, BLOBBASEFEE
            if (rules_cancun.is_eip1153) available_opcodes += 2; // TLOAD, TSTORE
            if (rules_cancun.is_eip5656) available_opcodes += 1; // MCOPY
            if (rules_cancun.is_eip4844) available_opcodes += 1; // BLOBHASH
            
            // Prevent optimization
            std.mem.doNotOptimizeAway(available_opcodes);
        }
    };
    
    return timing.benchmark_with_args(allocator, BenchmarkConfig{
        .name = "Opcode Availability by Hardfork",
        .iterations = 10000,
        .warmup_iterations = 100,
    }, TestFunc.run, .{});
}

/// Benchmark gas cost variations by hardfork
/// Tests the performance of determining gas costs that vary by hardfork
pub fn gas_cost_variations_benchmark(allocator: Allocator) !BenchmarkResult {
    const TestFunc = struct {
        fn run() void {
            var total_gas: u64 = 0;
            
            // Simulate gas cost calculations for different hardforks
            const rules_tangerine = Frame.chainRulesForHardfork(.TANGERINE_WHISTLE);
            const rules_istanbul = Frame.chainRulesForHardfork(.ISTANBUL);
            const rules_berlin = Frame.chainRulesForHardfork(.BERLIN);
            
            // EIP-150 (Tangerine Whistle) - increased SLOAD cost
            if (rules_tangerine.is_eip150) {
                total_gas += 200; // New SLOAD cost
            } else {
                total_gas += 50; // Old SLOAD cost
            }
            
            // EIP-2929 (Berlin) - cold/warm storage access
            if (rules_berlin.is_berlin) {
                total_gas += 2100; // Cold SLOAD
                total_gas += 100; // Warm SLOAD
                total_gas += 2600; // Cold account access
                total_gas += 100; // Warm account access
            }
            
            // Istanbul - various gas cost changes
            if (rules_istanbul.is_istanbul) {
                total_gas += 700; // SSTORE with discount
                total_gas += 16; // Calldata non-zero byte
                total_gas += 4; // Calldata zero byte
            }
            
            // Prevent optimization
            std.mem.doNotOptimizeAway(total_gas);
        }
    };
    
    return timing.benchmark_with_args(allocator, BenchmarkConfig{
        .name = "Gas Cost Variations by Hardfork",
        .iterations = 10000,
        .warmup_iterations = 100,
    }, TestFunc.run, .{});
}

/// Benchmark hardfork rule application
/// Tests the performance of applying different rules based on hardfork
pub fn hardfork_rule_application_benchmark(allocator: Allocator) !BenchmarkResult {
    const TestFunc = struct {
        fn run() void {
            var validation_passed: u32 = 0;
            
            const rules_london = Frame.chainRulesForHardfork(.LONDON);
            const rules_berlin = Frame.chainRulesForHardfork(.BERLIN);
            const rules_istanbul = Frame.chainRulesForHardfork(.ISTANBUL);
            
            // Simulate various validation rules
            // EIP-3541 - reject contracts starting with 0xEF
            if (rules_london.is_eip3541) {
                const contract_code = [_]u8{0xEF, 0x00};
                if (contract_code[0] == 0xEF) {
                    // Contract rejected
                } else {
                    validation_passed += 1;
                }
            }
            
            // Berlin - access list validation
            if (rules_berlin.is_eip2930) {
                // Simulate access list processing
                const access_list_size: u32 = 10;
                validation_passed += access_list_size;
            }
            
            // Istanbul - transaction type validation
            if (rules_istanbul.is_istanbul) {
                // Various validation checks
                validation_passed += 1;
            }
            
            // Prevent optimization
            std.mem.doNotOptimizeAway(validation_passed);
        }
    };
    
    return timing.benchmark_with_args(allocator, BenchmarkConfig{
        .name = "Hardfork Rule Application",
        .iterations = 10000,
        .warmup_iterations = 100,
    }, TestFunc.run, .{});
}

/// Benchmark validation rule differences
/// Tests the performance of different validation logic across hardforks
pub fn validation_rule_differences_benchmark(allocator: Allocator) !BenchmarkResult {
    const TestFunc = struct {
        fn run() void {
            var validation_count: u32 = 0;
            
            // Test different validation patterns per hardfork
            const rules = [_]ChainRules{
                Frame.chainRulesForHardfork(.FRONTIER),
                Frame.chainRulesForHardfork(.BYZANTIUM),
                Frame.chainRulesForHardfork(.LONDON),
                Frame.chainRulesForHardfork(.CANCUN),
            };
            
            for (rules) |rule| {
                // Homestead validation rules
                if (rule.is_homestead) {
                    validation_count += 1;
                }
                
                // Byzantium validation rules
                if (rule.is_byzantium) {
                    validation_count += 2;
                }
                
                // London validation rules
                if (rule.is_london and rule.is_eip1559) {
                    validation_count += 3;
                }
                
                // Cancun validation rules
                if (rule.is_cancun and rule.is_eip4844) {
                    validation_count += 4;
                }
            }
            
            // Prevent optimization
            std.mem.doNotOptimizeAway(validation_count);
        }
    };
    
    return timing.benchmark_with_args(allocator, BenchmarkConfig{
        .name = "Validation Rule Differences",
        .iterations = 10000,
        .warmup_iterations = 100,
    }, TestFunc.run, .{});
}

/// Benchmark compile-time vs runtime hardfork checks
/// Compares the performance of compile-time known vs runtime determined hardfork rules
pub fn compile_time_vs_runtime_benchmark(allocator: Allocator) !BenchmarkResult {
    const TestFunc = struct {
        fn run() void {
            var result1: u32 = 0;
            var result2: u32 = 0;
            
            // Compile-time known hardfork (should be optimized away)
            const ct_rules = comptime Frame.chainRulesForHardfork(.CANCUN);
            if (ct_rules.is_cancun) {
                result1 += 1;
            }
            
            // Runtime determined hardfork
            const hardforks = [_]Hardfork{ .BYZANTIUM, .LONDON, .CANCUN };
            for (hardforks) |hf| {
                const rt_rules = ChainRules.for_hardfork(hf);
                if (rt_rules.is_cancun) {
                    result2 += 1;
                }
            }
            
            // Prevent optimization
            std.mem.doNotOptimizeAway(result1);
            std.mem.doNotOptimizeAway(result2);
        }
    };
    
    return timing.benchmark_with_args(allocator, BenchmarkConfig{
        .name = "Compile-time vs Runtime Checks",
        .iterations = 10000,
        .warmup_iterations = 100,
    }, TestFunc.run, .{});
}

/// Benchmark hardfork detection from chain rules
/// Tests the performance of reverse lookup: determining which hardfork from rules
pub fn hardfork_detection_benchmark(allocator: Allocator) !BenchmarkResult {
    const TestFunc = struct {
        fn run() void {
            var detected_forks: u32 = 0;
            
            // Create rules for different hardforks
            const rules = [_]ChainRules{
                Frame.chainRulesForHardfork(.FRONTIER),
                Frame.chainRulesForHardfork(.HOMESTEAD),
                Frame.chainRulesForHardfork(.BYZANTIUM),
                Frame.chainRulesForHardfork(.CONSTANTINOPLE),
                Frame.chainRulesForHardfork(.ISTANBUL),
                Frame.chainRulesForHardfork(.BERLIN),
                Frame.chainRulesForHardfork(.LONDON),
                Frame.chainRulesForHardfork(.SHANGHAI),
                Frame.chainRulesForHardfork(.CANCUN),
            };
            
            // Detect hardfork for each rule set
            for (rules) |rule| {
                const detected = ChainRules.getHardfork(rule);
                detected_forks += @intFromEnum(detected);
            }
            
            // Prevent optimization
            std.mem.doNotOptimizeAway(detected_forks);
        }
    };
    
    return timing.benchmark_with_args(allocator, BenchmarkConfig{
        .name = "Hardfork Detection from Rules",
        .iterations = 10000,
        .warmup_iterations = 100,
    }, TestFunc.run, .{});
}

/// Run all hardfork benchmarks and print comparative results
pub fn run_all_hardfork_benchmarks(allocator: Allocator) !void {
    std.log.info("=== Hardfork Logic and Chain Rules Benchmarks (Issue #71) ===", .{});
    
    var suite = timing.BenchmarkSuite.init(allocator);
    defer suite.deinit();
    
    // Run all benchmarks
    const results = [_]anyerror!BenchmarkResult{
        hardfork_flag_checks_benchmark(allocator),
        chain_rules_initialization_benchmark(allocator),
        feature_availability_lookup_benchmark(allocator),
        opcode_availability_by_hardfork_benchmark(allocator),
        gas_cost_variations_benchmark(allocator),
        hardfork_rule_application_benchmark(allocator),
        validation_rule_differences_benchmark(allocator),
        compile_time_vs_runtime_benchmark(allocator),
        hardfork_detection_benchmark(allocator),
    };
    
    // Add results to suite
    for (results) |result_or_err| {
        if (result_or_err) |result| {
            try suite.results.append(result);
        } else |err| {
            std.log.err("Benchmark failed: {}", .{err});
        }
    }
    
    // Print results
    suite.print_results();
    
    // Compare some key benchmarks
    std.log.info("=== Performance Analysis ===", .{});
    try suite.compare("Chain Rules Initialization", "Hardfork Flag Checks");
    try suite.compare("Compile-time vs Runtime Checks", "Feature Availability Lookup");
}

// zbench-compatible wrapper functions for integration with benchmark runner
pub fn zbench_hardfork_flag_checks(allocator: Allocator) void {
    _ = hardfork_flag_checks_benchmark(allocator) catch |err| {
        std.log.err("Hardfork flag checks benchmark failed: {}", .{err});
    };
}

pub fn zbench_chain_rules_initialization(allocator: Allocator) void {
    _ = chain_rules_initialization_benchmark(allocator) catch |err| {
        std.log.err("Chain rules initialization benchmark failed: {}", .{err});
    };
}

pub fn zbench_feature_availability_lookup(allocator: Allocator) void {
    _ = feature_availability_lookup_benchmark(allocator) catch |err| {
        std.log.err("Feature availability lookup benchmark failed: {}", .{err});
    };
}

pub fn zbench_opcode_availability(allocator: Allocator) void {
    _ = opcode_availability_by_hardfork_benchmark(allocator) catch |err| {
        std.log.err("Opcode availability benchmark failed: {}", .{err});
    };
}

pub fn zbench_gas_cost_variations(allocator: Allocator) void {
    _ = gas_cost_variations_benchmark(allocator) catch |err| {
        std.log.err("Gas cost variations benchmark failed: {}", .{err});
    };
}

pub fn zbench_rule_application(allocator: Allocator) void {
    _ = hardfork_rule_application_benchmark(allocator) catch |err| {
        std.log.err("Rule application benchmark failed: {}", .{err});
    };
}

pub fn zbench_validation_differences(allocator: Allocator) void {
    _ = validation_rule_differences_benchmark(allocator) catch |err| {
        std.log.err("Validation differences benchmark failed: {}", .{err});
    };
}

pub fn zbench_compile_vs_runtime(allocator: Allocator) void {
    _ = compile_time_vs_runtime_benchmark(allocator) catch |err| {
        std.log.err("Compile vs runtime benchmark failed: {}", .{err});
    };
}

pub fn zbench_hardfork_detection(allocator: Allocator) void {
    _ = hardfork_detection_benchmark(allocator) catch |err| {
        std.log.err("Hardfork detection benchmark failed: {}", .{err});
    };
}

// Tests for hardfork benchmarks
test "hardfork flag checks benchmark" {
    const allocator = std.testing.allocator;
    const result = try hardfork_flag_checks_benchmark(allocator);
    try std.testing.expect(result.mean_time_ns > 0);
    try std.testing.expectEqual(@as(u32, 10000), result.iterations);
}

test "chain rules initialization benchmark" {
    const allocator = std.testing.allocator;
    const result = try chain_rules_initialization_benchmark(allocator);
    try std.testing.expect(result.mean_time_ns > 0);
    try std.testing.expectEqual(@as(u32, 10000), result.iterations);
}

test "feature availability lookup benchmark" {
    const allocator = std.testing.allocator;
    const result = try feature_availability_lookup_benchmark(allocator);
    try std.testing.expect(result.mean_time_ns > 0);
    try std.testing.expectEqual(@as(u32, 10000), result.iterations);
}

test "hardfork benchmarks integration" {
    const allocator = std.testing.allocator;
    
    // Test that all benchmark functions can be called without error
    zbench_hardfork_flag_checks(allocator);
    zbench_chain_rules_initialization(allocator);
    zbench_feature_availability_lookup(allocator);
    zbench_opcode_availability(allocator);
    zbench_gas_cost_variations(allocator);
    zbench_rule_application(allocator);
    zbench_validation_differences(allocator);
    zbench_compile_vs_runtime(allocator);
    zbench_hardfork_detection(allocator);
}

test "hardfork detection" {
    // Test the reverse lookup functionality
    const rules_cancun = Frame.chainRulesForHardfork(.CANCUN);
    const rules_london = Frame.chainRulesForHardfork(.LONDON);
    const rules_byzantium = Frame.chainRulesForHardfork(.BYZANTIUM);
    
    try std.testing.expectEqual(Hardfork.CANCUN, ChainRules.getHardfork(rules_cancun));
    try std.testing.expectEqual(Hardfork.LONDON, ChainRules.getHardfork(rules_london));
    try std.testing.expectEqual(Hardfork.BYZANTIUM, ChainRules.getHardfork(rules_byzantium));
}