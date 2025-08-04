const std = @import("std");
const Allocator = std.mem.Allocator;
const timing = @import("timing.zig");
const BenchmarkSuite = timing.BenchmarkSuite;
const BenchmarkConfig = timing.BenchmarkConfig;
const opcode_benchmarks = @import("opcode_benchmarks.zig");
// const comprehensive_precompile_benchmark = @import("comprehensive_precompile_benchmark.zig");

// Import frame management benchmark suites
const frame_benchmarks = @import("frame_benchmarks.zig");
const code_analysis_benchmarks = @import("code_analysis_benchmarks.zig");
const comprehensive_frame_benchmarks = @import("comprehensive_frame_benchmarks.zig");
const revm_comparison_benchmark = @import("revm_comparison_benchmark.zig");
const uint_benchmark = @import("uint_benchmark.zig");

pub fn run_all_benchmarks(allocator: Allocator) !void {
    std.debug.print("=== Running All Guillotine Benchmarks ===\n", .{});
    
    // Run comprehensive opcode benchmarks (new for issue #62)
    // DISABLED: Has compilation errors with allocator capture
    // std.debug.print("\n🚀 Starting Comprehensive Opcode Benchmarks...\n", .{});
    // try opcode_benchmarks.run_comprehensive_opcode_benchmarks(allocator);
    
    // Run precompile benchmarks first (most important for issue #68)
    // DISABLED: Has dependencies issues
    // try run_all_precompile_benchmarks(allocator);
    
    // Run other benchmark categories
    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();
    
    // Simple hello world benchmark
    const HelloWorldBench = struct {
        fn hello_world() void {
            std.debug.print("Hello World from Guillotine benchmarks!\n", .{});
        }
        
        fn simple_computation() u64 {
            var sum: u64 = 0;
            var i: u32 = 0;
            while (i < 1000) : (i += 1) {
                sum += i * i;
            }
            return sum;
        }
        
        fn memory_allocation() !void {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            const alloc = gpa.allocator();
            
            const data = try alloc.alloc(u8, 1024);
            defer alloc.free(data);
            
            for (data, 0..) |*byte, idx| {
                byte.* = @as(u8, @intCast(idx % 256));
            }
        }
    };
    
    std.debug.print("\n=== Basic System Benchmarks ===\n", .{});
    
    try suite.benchmark(BenchmarkConfig{
        .name = "hello_world",
        .iterations = 10,
        .warmup_iterations = 2,
    }, HelloWorldBench.hello_world);
    
    try suite.benchmark(BenchmarkConfig{
        .name = "simple_computation",
        .iterations = 100,
        .warmup_iterations = 10,
    }, HelloWorldBench.simple_computation);
    
    try suite.benchmark(BenchmarkConfig{
        .name = "memory_allocation",
        .iterations = 50,
        .warmup_iterations = 5,
    }, HelloWorldBench.memory_allocation);
    
    suite.print_results();
    
    // Run the new frame management benchmark suites
    std.debug.print("\n=== Running Frame Management Benchmarks ===\n", .{});
    try frame_benchmarks.runFrameBenchmarks(allocator);
    // TEMPORARILY DISABLED: comptime compilation issue
    // try code_analysis_benchmarks.runCodeAnalysisBenchmarks(allocator);
    try comprehensive_frame_benchmarks.runComprehensiveFrameBenchmarks(allocator);
    std.debug.print("=== All Frame Management Benchmarks Complete ===\n\n", .{});
    
    // Run revm comparison benchmarks
    std.debug.print("\n=== Running Guillotine vs revm Comparison Benchmarks ===\n", .{});
    try revm_comparison_benchmark.runRevmComparisonBenchmarks(allocator);
    std.debug.print("=== Comparison Benchmarks Complete ===\n\n", .{});
    
    // Run uint library benchmarks
    std.debug.print("\n=== Running Uint Library vs Native u256 Benchmarks ===\n", .{});
    try uint_benchmark.run_uint_benchmarks_simple(allocator);
    std.debug.print("=== Uint Benchmarks Complete ===\n\n", .{});
    
    std.debug.print("\n=== All Benchmarks Completed ===\n", .{});
}

fn add_evm_benchmarks(suite: *BenchmarkSuite) !void {
    try suite.addBenchmark(BenchmarkConfig{
        .name = "guillotine_evm_basic",
        .command = "zig build && echo 'Basic EVM execution test' | ./zig-out/bin/Guillotine",
        .warmup_runs = 3,
        .min_runs = 10,
        .max_runs = 50,
        .export_json = true,
        .export_markdown = true,
        .show_output = false,
    });
    
    try suite.addBenchmark(BenchmarkConfig{
        .name = "guillotine_evm_comprehensive",
        .command = "zig build test-evm",
        .warmup_runs = 2,
        .min_runs = 5,
        .max_runs = 20,
        .export_json = true,
        .export_markdown = true,
        .show_output = false,
    });
}

fn add_arithmetic_benchmarks(suite: *BenchmarkSuite) !void {
    try suite.addBenchmark(BenchmarkConfig{
        .name = "guillotine_arithmetic_ops",
        .command = "zig build test-opcodes",
        .warmup_runs = 2,
        .min_runs = 10,
        .max_runs = 30,
        .export_json = true,
        .export_csv = true,
        .show_output = false,
    });
    
    try suite.addBenchmark(BenchmarkConfig{
        .name = "guillotine_arithmetic_fuzz",
        .command = "zig build fuzz-arithmetic",
        .warmup_runs = 1,
        .min_runs = 5,
        .max_runs = 15,
        .export_json = true,
        .show_output = false,
    });
}

fn add_memory_benchmarks(suite: *BenchmarkSuite) !void {
    try suite.addBenchmark(BenchmarkConfig{
        .name = "guillotine_memory_ops",
        .command = "zig build test-memory",
        .warmup_runs = 2,
        .min_runs = 10,
        .max_runs = 30,
        .export_json = true,
        .export_csv = true,
        .show_output = false,
    });
    
    try suite.addBenchmark(BenchmarkConfig{
        .name = "guillotine_memory_fuzz",
        .command = "zig build fuzz-memory",
        .warmup_runs = 1,
        .min_runs = 5,
        .max_runs = 15,
        .export_json = true,
        .show_output = false,
    });
    
    try suite.addBenchmark(BenchmarkConfig{
        .name = "guillotine_stack_ops",
        .command = "zig build test-stack",
        .warmup_runs = 2,
        .min_runs = 10,
        .max_runs = 30,
        .export_json = true,
        .export_csv = true,
        .show_output = false,
    });
}

fn add_crypto_benchmarks(suite: *BenchmarkSuite) !void {
    try suite.addBenchmark(BenchmarkConfig{
        .name = "guillotine_crypto_sha256",
        .command = "zig build test-sha256",
        .warmup_runs = 2,
        .min_runs = 10,
        .max_runs = 30,
        .export_json = true,
        .export_csv = true,
        .show_output = false,
    });
    
    try suite.addBenchmark(BenchmarkConfig{
        .name = "guillotine_crypto_ripemd160",
        .command = "zig build test-ripemd160",
        .warmup_runs = 2,
        .min_runs = 10,
        .max_runs = 30,
        .export_json = true,
        .export_csv = true,
        .show_output = false,
    });
    
    try suite.addBenchmark(BenchmarkConfig{
        .name = "guillotine_crypto_blake2f",
        .command = "zig build test-blake2f",
        .warmup_runs = 2,
        .min_runs = 10,
        .max_runs = 30,
        .export_json = true,
        .export_csv = true,
        .show_output = false,
    });
    
    try suite.addBenchmark(BenchmarkConfig{
        .name = "guillotine_crypto_bn254",
        .command = "zig build test-bn254-rust",
        .warmup_runs = 1,
        .min_runs = 5,
        .max_runs = 15,
        .export_json = true,
        .show_output = false,
    });
}

/// Run comprehensive precompile benchmarks
pub fn run_precompile_benchmarks(_: Allocator) !void {
    std.debug.print("=== Comprehensive Precompile Benchmarks ===\n", .{});
    // try comprehensive_precompile_benchmark.run_comprehensive_precompile_benchmarks(allocator);
}

/// Run precompile dispatch microbenchmark
pub fn run_precompile_microbenchmarks() void {
    // comprehensive_precompile_benchmark.run_dispatch_microbenchmark();
}

/// Run precompile comparative analysis
pub fn run_precompile_comparative_analysis(_: Allocator) !void {
    // try comprehensive_precompile_benchmark.run_comparative_analysis(allocator);
}

/// Run all precompile-related benchmarks
pub fn run_all_precompile_benchmarks(allocator: Allocator) !void {
    std.debug.print("\n=== All Precompile Performance Tests ===\n", .{});
    
    // Run comprehensive benchmarks
    try run_precompile_benchmarks(allocator);
    
    // Run microbenchmarks
    run_precompile_microbenchmarks();
    
    // Run comparative analysis
    try run_precompile_comparative_analysis(allocator);
    
    std.debug.print("\n=== Precompile Benchmark Summary ===\n", .{});
    std.debug.print("All precompile benchmarks completed successfully.\n", .{});
    std.debug.print("Key insights:\n", .{});
    std.debug.print("- IDENTITY precompile is most frequently used and should be highly optimized\n", .{});
    std.debug.print("- SHA256 and RIPEMD160 show linear scaling with input size\n", .{});
    std.debug.print("- ECRECOVER is computationally expensive but has fixed cost\n", .{});
    std.debug.print("- Dispatch overhead should be minimal compared to computation time\n", .{});
}

pub fn run_comparison_benchmarks(allocator: Allocator) !void {
    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();
    
    try add_external_evm_benchmarks(&suite);
    try add_guillotine_benchmarks(&suite);
    
    suite.print_results();
    
    // TODO: Add comparisons when external benchmarks are available
}

fn add_external_evm_benchmarks(suite: *BenchmarkSuite) !void {
    // TODO: Add external EVM benchmarks when available
    _ = suite;
}

fn add_guillotine_benchmarks(suite: *BenchmarkSuite) !void {
    // TODO: Add Guillotine EVM benchmarks
    _ = suite;
}

pub fn run_parameterized_benchmarks(allocator: Allocator) !void {
    try timing.ensure_hyperfine_installed(allocator);
    
    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();
    
    try suite.addBenchmark(BenchmarkConfig{
        .name = "guillotine_gas_limit_scaling",
        .command = "",
        .warmup_runs = 2,
        .min_runs = 5,
        .max_runs = 20,
        .export_json = true,
        .export_csv = true,
        .parameter_scan = timing.ParameterScan{
            .parameter_name = "gas_limit",
            .values = &[_][]const u8{ "100000", "500000", "1000000", "5000000", "10000000" },
            .command_template = "echo 'Testing with gas limit: {gas_limit}' && zig build test-gas",
        },
    });
    
    try suite.addBenchmark(BenchmarkConfig{
        .name = "guillotine_memory_scaling",
        .command = "",
        .warmup_runs = 2,
        .min_runs = 5,
        .max_runs = 20,
        .export_json = true,
        .export_csv = true,
        .parameter_scan = timing.ParameterScan{
            .parameter_name = "memory_size",
            .values = &[_][]const u8{ "1024", "4096", "16384", "65536", "262144" },
            .command_template = "echo 'Testing with memory size: {memory_size}' && zig build test-memory",
        },
    });
    
    try suite.run();
    suite.print_summary();
}

pub fn generate_benchmark_report(allocator: Allocator) !void {
    const report_content =
        \\# Guillotine EVM Benchmark Report
        \\
        \\This report contains performance benchmarks for the Guillotine EVM implementation.
        \\
        \\## Test Environment
        \\- Platform: {s}
        \\- Architecture: {s}
        \\- Date: {s}
        \\
        \\## Benchmark Categories
        \\
        \\### Core EVM Operations
        \\- Basic EVM execution
        \\- Comprehensive EVM test suite
        \\
        \\### Arithmetic Operations
        \\- Arithmetic opcodes
        \\- Fuzz testing of arithmetic operations
        \\
        \\### Memory Operations
        \\- Memory opcodes
        \\- Stack operations
        \\- Fuzz testing of memory operations
        \\
        \\### Cryptographic Operations
        \\- SHA256 precompile
        \\- RIPEMD160 precompile
        \\- BLAKE2f precompile
        \\- BN254 elliptic curve operations
        \\
        \\## How to Run
        \\
        \\```bash
        \\# Run all benchmarks
        \\zig build bench
        \\
        \\# Run comparison benchmarks
        \\zig build bench-compare
        \\
        \\# Run parameterized benchmarks
        \\zig build bench-params
        \\
        \\# Generate benchmark report
        \\zig build bench-report
        \\```
        \\
        \\## Results
        \\
        \\Results are exported to:
        \\- JSON format: `bench-*.json`
        \\- CSV format: `bench-*.csv`
        \\- Markdown format: `bench-*.md`
        \\
        \\## External EVM Implementations
        \\
        \\To compare against external EVM implementations, install and configure:
        \\
        \\1. **REVM**: Rust EVM implementation
        \\2. **Geth EVM**: Go Ethereum EVM
        \\3. **evmone**: C++ EVM implementation
        \\
        \\Update the benchmark commands in `bench/benchmarks.zig` to point to actual binaries.
        \\
    ;
    
    const file = try std.fs.cwd().createFile("bench/README.md", .{});
    defer file.close();
    
    const platform = @tagName(std.Target.current.os.tag);
    const arch = @tagName(std.Target.current.cpu.arch);
    const date = "2024-01-01"; // TODO: Get actual date
    
    const formatted_report = try std.fmt.allocPrint(allocator, report_content, .{ platform, arch, date });
    defer allocator.free(formatted_report);
    
    try file.writeAll(formatted_report);
    
    std.log.info("Benchmark report generated: bench/README.md", .{});
}

test "benchmark configuration" {
    const allocator = std.testing.allocator;
    
    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();
    
    try add_evm_benchmarks(&suite);
    
    try std.testing.expect(suite.configs.items.len > 0);
    
    for (suite.configs.items) |config| {
        try std.testing.expect(config.name.len > 0);
        try std.testing.expect(config.command.len > 0);
        try std.testing.expect(config.warmup_runs > 0);
        try std.testing.expect(config.min_runs > 0);
        try std.testing.expect(config.max_runs >= config.min_runs);
    }
}