const std = @import("std");
const clap = @import("clap");
const print = std.debug.print;

/// Benchmark orchestrator for running EVM implementation benchmarks.
///
/// The Orchestrator discovers test cases, runs them through hyperfine,
/// collects timing statistics, and exports results in various formats.
///
/// ## Usage
/// ```zig
/// var orchestrator = try Orchestrator.init(allocator, "zig", 10);
/// defer orchestrator.deinit();
/// 
/// try orchestrator.discoverTestCases();
/// try orchestrator.runBenchmarks();
/// orchestrator.printSummary();
/// try orchestrator.exportResults("markdown");
/// ```
const Orchestrator = @This();

// Fields
allocator: std.mem.Allocator,
evm_name: []const u8,
num_runs: u32,
internal_runs: u32,
js_runs: u32,
js_internal_runs: u32,
snailtracer_internal_runs: u32,
js_snailtracer_internal_runs: u32,
include_all_cases: bool,
use_next: bool,
  show_output: bool,
test_cases: []TestCase,
results: std.ArrayList(BenchmarkResult),

pub const TestCase = struct {
    name: []const u8,
    bytecode_path: []const u8,
    calldata_path: []const u8,
};

pub const BenchmarkResult = struct {
    test_case: []const u8,
    mean_ms: f64,
    min_ms: f64,
    max_ms: f64,
    std_dev_ms: f64,
    median_ms: f64,
    runs: u32,
    internal_runs: u32,
};

pub fn init(allocator: std.mem.Allocator, evm_name: []const u8, num_runs: u32, internal_runs: u32, js_runs: u32, js_internal_runs: u32, snailtracer_internal_runs: u32, js_snailtracer_internal_runs: u32, include_all_cases: bool, use_next: bool, show_output: bool) !Orchestrator {
    return Orchestrator{
        .allocator = allocator,
        .evm_name = evm_name,
        .num_runs = num_runs,
        .internal_runs = internal_runs,
        .js_runs = js_runs,
        .js_internal_runs = js_internal_runs,
        .snailtracer_internal_runs = snailtracer_internal_runs,
        .js_snailtracer_internal_runs = js_snailtracer_internal_runs,
        .include_all_cases = include_all_cases,
        .use_next = use_next,
        .show_output = show_output,
        .test_cases = &[_]TestCase{},
        .results = std.ArrayList(BenchmarkResult).init(allocator),
    };
}

pub fn deinit(self: *Orchestrator) void {
    for (self.test_cases) |tc| {
        self.allocator.free(tc.name);
        self.allocator.free(tc.bytecode_path);
        self.allocator.free(tc.calldata_path);
    }
    if (self.test_cases.len > 0) {
        self.allocator.free(self.test_cases);
    }
    for (self.results.items) |result| {
        self.allocator.free(result.test_case);
    }
    self.results.deinit();
}

pub fn discoverTestCases(self: *Orchestrator) !void {
    // Get the absolute path to cases directory
    // This works whether we're in zig-out/bin or running from project root
    const cases_path = "/Users/williamcory/Guillotine/bench/official/cases";
    
    const cases_dir = try std.fs.openDirAbsolute(cases_path, .{ .iterate = true });
    
    var test_cases = std.ArrayList(TestCase).init(self.allocator);
    defer test_cases.deinit();

    var it = cases_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;

        const bytecode_path = try std.fs.path.join(self.allocator, &[_][]const u8{ cases_path, entry.name, "bytecode.txt" });
        errdefer self.allocator.free(bytecode_path);
        
        const calldata_path = try std.fs.path.join(self.allocator, &[_][]const u8{ cases_path, entry.name, "calldata.txt" });
        errdefer self.allocator.free(calldata_path);

        // Verify files exist
        if (std.fs.cwd().openFile(bytecode_path, .{})) |file| {
            file.close();
        } else |err| {
            print("Warning: Missing bytecode file for {s}: {}\n", .{ entry.name, err });
            self.allocator.free(bytecode_path);
            self.allocator.free(calldata_path);
            continue;
        }
        
        if (std.fs.cwd().openFile(calldata_path, .{})) |file| {
            file.close();
        } else |err| {
            print("Warning: Missing calldata file for {s}: {}\n", .{ entry.name, err });
            self.allocator.free(bytecode_path);
            self.allocator.free(calldata_path);
            continue;
        }

        // Filter to only working benchmarks unless --all flag is used
        if (!self.include_all_cases) {
            const working_benchmarks = [_][]const u8{
                "erc20-approval-transfer",
                "erc20-mint", 
                "erc20-transfer",
                "ten-thousand-hashes",
                "snailtracer"
            };
            
            var is_working = false;
            for (working_benchmarks) |working_name| {
                if (std.mem.eql(u8, entry.name, working_name)) {
                    is_working = true;
                    break;
                }
            }
            
            if (!is_working) {
                self.allocator.free(bytecode_path);
                self.allocator.free(calldata_path);
                continue;
            }
        }

        try test_cases.append(.{
            .name = try self.allocator.dupe(u8, entry.name),
            .bytecode_path = bytecode_path,
            .calldata_path = calldata_path,
        });
    }

    self.test_cases = try test_cases.toOwnedSlice();
}

pub fn runBenchmarks(self: *Orchestrator) !void {
    for (self.test_cases) |test_case| {
        print("\n=== Benchmarking {s} ===\n", .{test_case.name});
        try self.runSingleBenchmark(test_case);
    }
}

fn runSingleBenchmark(self: *Orchestrator, test_case: TestCase) !void {
    // Determine runs and internal runs based on EVM type and test case
    const is_js = std.mem.eql(u8, self.evm_name, "ethereumjs");
    const is_snailtracer = std.mem.eql(u8, test_case.name, "snailtracer");
    const is_js_snailtracer = is_js and is_snailtracer;
    
    const runs_to_use = if (is_js_snailtracer) self.js_runs else self.num_runs;
    
    // Apply internal runs logic:
    // 1. If JS snailtracer -> use js_snailtracer_internal_runs
    // 2. If snailtracer (any EVM) -> use snailtracer_internal_runs  
    // 3. If JS (any test) -> use js_internal_runs
    // 4. Otherwise -> use internal_runs
    const internal_runs_to_use = if (is_js_snailtracer) 
        self.js_snailtracer_internal_runs
    else if (is_snailtracer)
        self.snailtracer_internal_runs
    else if (is_js)
        self.js_internal_runs
    else
        self.internal_runs;
    // Read calldata
    const calldata_file = try std.fs.cwd().openFile(test_case.calldata_path, .{});
    defer calldata_file.close();
    
    const calldata = try calldata_file.readToEndAlloc(self.allocator, 1024 * 1024); // 1MB max
    defer self.allocator.free(calldata);
    
    // Trim whitespace
    const trimmed_calldata = std.mem.trim(u8, calldata, " \t\n\r");
    
    // Build the runner path
    const runner_path = if (std.mem.eql(u8, self.evm_name, "zig")) 
        "/Users/williamcory/Guillotine/zig-out/bin/evm-runner"
    else if (std.mem.eql(u8, self.evm_name, "ethereumjs"))
        "/Users/williamcory/Guillotine/bench/official/evms/ethereumjs/runner.js"
    else if (std.mem.eql(u8, self.evm_name, "geth"))
        "/Users/williamcory/Guillotine/bench/official/evms/geth/runner"
    else if (std.mem.eql(u8, self.evm_name, "evmone"))
        "/Users/williamcory/Guillotine/bench/official/evms/evmone/build/evmone-runner"
    else blk: {
        const runner_name = try std.fmt.allocPrint(self.allocator, "{s}-runner", .{self.evm_name});
        defer self.allocator.free(runner_name);
        const path = try std.fmt.allocPrint(self.allocator, "/Users/williamcory/Guillotine/bench/official/evms/{s}/target/release/{s}", .{self.evm_name, runner_name});
        break :blk path;
    };
    defer if (!std.mem.eql(u8, self.evm_name, "zig") and !std.mem.eql(u8, self.evm_name, "ethereumjs") and !std.mem.eql(u8, self.evm_name, "geth") and !std.mem.eql(u8, self.evm_name, "evmone")) self.allocator.free(runner_path);
    
    const num_runs_str = try std.fmt.allocPrint(self.allocator, "{}", .{runs_to_use});
    defer self.allocator.free(num_runs_str);
    
    // Build hyperfine command
    const next_flag = if (self.use_next and std.mem.eql(u8, self.evm_name, "zig")) " --next" else "";
    const hyperfine_cmd = try std.fmt.allocPrint(
        self.allocator,
        "{s} --contract-code-path {s} --calldata {s} --num-runs {}{s}",
        .{ runner_path, test_case.bytecode_path, trimmed_calldata, internal_runs_to_use, next_flag }
    );
    defer self.allocator.free(hyperfine_cmd);

    var argv = std.ArrayList([]const u8).init(self.allocator);
    defer argv.deinit();
    try argv.append("hyperfine");
    try argv.appendSlice(&[_][]const u8{ "--runs", num_runs_str, "--warmup", "3", "--shell=none" });
    if (self.show_output) try argv.append("--show-output");
    try argv.appendSlice(&[_][]const u8{ "--export-json", "-", hyperfine_cmd });

    const result = try std.process.Child.run(.{
        .allocator = self.allocator,
        .argv = argv.items,
    });
    defer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);

    if (result.stderr.len > 0) {
        print("Errors:\n{s}", .{result.stderr});
    }

    // Parse JSON results
    if (result.stdout.len > 0) {
        try self.parseHyperfineJson(test_case.name, result.stdout, runs_to_use, internal_runs_to_use);
    }
}

const TimeUnit = enum {
    microseconds,
    milliseconds,
    seconds,
};

const FormattedTime = struct {
    value: f64,
    unit: TimeUnit,
    
    pub fn format(self: FormattedTime, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        const unit_str = switch (self.unit) {
            .microseconds => "μs",
            .milliseconds => "ms", 
            .seconds => "s",
        };
        try writer.print("{d:.2} {s}", .{ self.value, unit_str });
    }
};

fn selectOptimalUnit(time_ms: f64) FormattedTime {
    if (time_ms >= 1000.0) {
        return FormattedTime{ .value = time_ms / 1000.0, .unit = .seconds };
    } else if (time_ms >= 1.0) {
        return FormattedTime{ .value = time_ms, .unit = .milliseconds };
    } else {
        return FormattedTime{ .value = time_ms * 1000.0, .unit = .microseconds };
    }
}

fn formatTimeWithUnit(time_ms: f64) FormattedTime {
    return selectOptimalUnit(time_ms);
}

fn parseHyperfineJson(self: *Orchestrator, test_name: []const u8, json_data: []const u8, runs: u32, internal_runs: u32) !void {
    // Simple JSON parsing - look for the key values we need
    // This is a basic parser that extracts the values we need
    
    var mean: f64 = 0;
    var min: f64 = 0;
    var max: f64 = 0;
    var median: f64 = 0;
    var stddev: f64 = 0;
    
    // Find "mean": value
    if (std.mem.indexOf(u8, json_data, "\"mean\":")) |mean_pos| {
        const start = mean_pos + 8;
        if (std.mem.indexOfPos(u8, json_data, start, ",")) |end| {
            const mean_str = std.mem.trim(u8, json_data[start..end], " ");
            mean = try std.fmt.parseFloat(f64, mean_str);
        }
    }
    
    // Find "min": value
    if (std.mem.indexOf(u8, json_data, "\"min\":")) |min_pos| {
        const start = min_pos + 7;
        if (std.mem.indexOfPos(u8, json_data, start, ",")) |end| {
            const min_str = std.mem.trim(u8, json_data[start..end], " ");
            min = try std.fmt.parseFloat(f64, min_str);
        }
    }
    
    // Find "max": value
    if (std.mem.indexOf(u8, json_data, "\"max\":")) |max_pos| {
        const start = max_pos + 7;
        if (std.mem.indexOfPos(u8, json_data, start, ",")) |end| {
            const max_str = std.mem.trim(u8, json_data[start..end], " ");
            max = try std.fmt.parseFloat(f64, max_str);
        }
    }
    
    // Find "median": value
    if (std.mem.indexOf(u8, json_data, "\"median\":")) |median_pos| {
        const start = median_pos + 10;
        if (std.mem.indexOfPos(u8, json_data, start, ",")) |end| {
            const median_str = std.mem.trim(u8, json_data[start..end], " ");
            median = try std.fmt.parseFloat(f64, median_str);
        }
    }
    
    // Find "stddev": value
    if (std.mem.indexOf(u8, json_data, "\"stddev\":")) |stddev_pos| {
        const start = stddev_pos + 10;
        if (std.mem.indexOfPos(u8, json_data, start, ",")) |end| {
            const stddev_str = std.mem.trim(u8, json_data[start..end], " ");
            if (!std.mem.eql(u8, stddev_str, "null")) {
                stddev = try std.fmt.parseFloat(f64, stddev_str);
            }
        } else if (std.mem.indexOfPos(u8, json_data, start, "}")) |end| {
            const stddev_str = std.mem.trim(u8, json_data[start..end], " ");
            if (!std.mem.eql(u8, stddev_str, "null")) {
                stddev = try std.fmt.parseFloat(f64, stddev_str);
            }
        }
    }
    
    // Convert to milliseconds and normalize per internal run
    const result = BenchmarkResult{
        .test_case = try self.allocator.dupe(u8, test_name),
        .mean_ms = (mean * 1000.0) / @as(f64, @floatFromInt(internal_runs)),
        .min_ms = (min * 1000.0) / @as(f64, @floatFromInt(internal_runs)),
        .max_ms = (max * 1000.0) / @as(f64, @floatFromInt(internal_runs)),
        .std_dev_ms = (stddev * 1000.0) / @as(f64, @floatFromInt(internal_runs)),
        .median_ms = (median * 1000.0) / @as(f64, @floatFromInt(internal_runs)),
        .runs = runs,
        .internal_runs = internal_runs,
    };
    
    try self.results.append(result);
    
    const mean_formatted = formatTimeWithUnit(result.mean_ms);
    const min_formatted = formatTimeWithUnit(result.min_ms);
    const max_formatted = formatTimeWithUnit(result.max_ms);
    print("  Mean: {s}, Min: {s}, Max: {s} (per run, {} internal runs)\n", .{ mean_formatted, min_formatted, max_formatted, result.internal_runs });
}

pub fn printSummary(self: *Orchestrator) void {
    print("\n=== Benchmark Summary ===\n", .{});
    print("EVM Implementation: {s}\n", .{self.evm_name});
    print("Runs per test: {}\n", .{self.num_runs});
    print("Test cases: {}\n\n", .{self.test_cases.len});

    print("{s:<30} {s:>15} {s:>15} {s:>15}\n", .{ "Test Case", "Mean (per run)", "Min (per run)", "Max (per run)" });
    print("{s:-<80}\n", .{""});
    
    for (self.results.items) |result| {
        const mean_formatted = formatTimeWithUnit(result.mean_ms);
        const min_formatted = formatTimeWithUnit(result.min_ms);
        const max_formatted = formatTimeWithUnit(result.max_ms);
        print("{s:<30} {s:>15} {s:>15} {s:>15}\n", .{ result.test_case, mean_formatted, min_formatted, max_formatted });
    }
}

pub fn exportResults(self: *Orchestrator, format: []const u8) !void {
    if (std.mem.eql(u8, format, "json")) {
        try self.exportJSON();
    } else if (std.mem.eql(u8, format, "markdown")) {
        try self.exportMarkdown();
    }
}

fn exportJSON(self: *Orchestrator) !void {
    const file = try std.fs.cwd().createFile("results.json", .{});
    defer file.close();
    
    try file.writeAll("{\n");
    try file.writeAll("  \"benchmarks\": [\n");
    
    for (self.test_cases, 0..) |tc, i| {
        try file.writer().print("    {{\n", .{});
        try file.writer().print("      \"name\": \"{s}\",\n", .{tc.name});
        try file.writer().print("      \"evm\": \"{s}\",\n", .{self.evm_name});
        try file.writer().print("      \"runs\": {}\n", .{self.num_runs});
        try file.writer().print("    }}{s}\n", .{if (i < self.test_cases.len - 1) "," else ""});
    }
    
    try file.writeAll("  ]\n");
    try file.writeAll("}\n");
    
    print("Results exported to results.json\n", .{});
}

fn exportMarkdown(self: *Orchestrator) !void {
    // Create the file in bench/official/results.md
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = try std.fs.selfExeDirPath(&exe_dir_buf);
    
    const project_root = try std.fs.path.resolve(self.allocator, &[_][]const u8{ exe_path, "..", ".." });
    defer self.allocator.free(project_root);
    
    const results_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "bench", "official", "results.md" });
    defer self.allocator.free(results_path);
    
    const file = try std.fs.createFileAbsolute(results_path, .{});
    defer file.close();
    
    // Get current timestamp
    const timestamp = std.time.timestamp();
    const seconds = @as(u64, @intCast(timestamp));
    
    // Write header
    try file.writer().print("# Guillotine EVM Benchmark Results\n\n", .{});
    try file.writer().print("## Summary\n\n", .{});
    try file.writer().print("**EVM Implementation**: {s}\n", .{self.evm_name});
    try file.writer().print("**Test Runs per Case**: {}\n", .{self.num_runs});
    try file.writer().print("**Total Test Cases**: {}\n", .{self.results.items.len});
    try file.writer().print("**Timestamp**: {} (Unix epoch)\n\n", .{seconds});
    
    // Write performance table
    try file.writer().print("## Performance Results (Per Run)\n\n", .{});
    try file.writeAll("| Test Case | Mean | Median | Min | Max | Std Dev | Internal Runs |\n");
    try file.writeAll("|-----------|------|--------|-----|-----|---------|---------------|\n");
    
    for (self.results.items) |result| {
        const mean_formatted = formatTimeWithUnit(result.mean_ms);
        const median_formatted = formatTimeWithUnit(result.median_ms);  
        const min_formatted = formatTimeWithUnit(result.min_ms);
        const max_formatted = formatTimeWithUnit(result.max_ms);
        const stddev_formatted = formatTimeWithUnit(result.std_dev_ms);
        
        try file.writer().print("| {s:<25} | {s:>10} | {s:>10} | {s:>9} | {s:>9} | {s:>11} | {d:>13} |\n", .{
            result.test_case,
            mean_formatted,
            median_formatted,
            min_formatted,
            max_formatted,
            stddev_formatted,
            result.internal_runs,
        });
    }
    
    // Add test case descriptions
    try file.writer().print("\n## Test Case Descriptions\n\n", .{});
    try file.writeAll("### ERC20 Operations\n\n");
    try file.writeAll("- **erc20-transfer**: Standard ERC20 token transfer operation\n");
    try file.writeAll("- **erc20-mint**: ERC20 token minting operation\n");
    try file.writeAll("- **erc20-approval-transfer**: ERC20 approval followed by transferFrom\n\n");
    
    try file.writeAll("### Computational Benchmarks\n\n");
    try file.writeAll("- **ten-thousand-hashes**: Performs 10,000 keccak256 hash operations\n");
    try file.writeAll("- **snailtracer**: Complex computational benchmark with intensive operations\n\n");
    
    // Add environment information
    try file.writer().print("## Environment\n\n", .{});
    try file.writer().print("- **Benchmark Tool**: hyperfine\n", .{});
    try file.writer().print("- **Warmup Runs**: 3\n", .{});
    try file.writer().print("- **Statistical Confidence**: Based on {} runs per test case\n\n", .{self.num_runs});
    
    // Add notes
    try file.writeAll("## Notes\n\n");
    try file.writeAll("- **All times are normalized per individual execution run**\n");
    try file.writeAll("- Times are displayed in the most appropriate unit (μs, ms, or s)\n");
    try file.writeAll("- Lower values indicate better performance\n");
    try file.writeAll("- Standard deviation indicates consistency (lower is more consistent)\n");
    try file.writeAll("- Each hyperfine run executes the contract multiple times internally (see Internal Runs column)\n");
    try file.writeAll("- These benchmarks measure the full execution time including contract deployment\n\n");
    
    try file.writeAll("---\n\n");
    try file.writeAll("*Generated by Guillotine Benchmark Orchestrator*\n");
    
    print("Results exported to bench/official/results.md\n", .{});
}

test "Orchestrator.init creates proper instance" {
    const allocator = std.testing.allocator;
    
    var orchestrator = try Orchestrator.init(allocator, "test-evm", 10, 5, 3, 2, 1, 1, false, false, false);
    defer orchestrator.deinit();
    
    try std.testing.expectEqualStrings("test-evm", orchestrator.evm_name);
    try std.testing.expectEqual(@as(u32, 10), orchestrator.num_runs);
    try std.testing.expectEqual(@as(u32, 5), orchestrator.internal_runs);
    try std.testing.expectEqual(@as(u32, 3), orchestrator.js_runs);
    try std.testing.expectEqual(@as(u32, 2), orchestrator.js_internal_runs);
    try std.testing.expectEqual(@as(u32, 1), orchestrator.snailtracer_internal_runs);
    try std.testing.expectEqual(@as(u32, 1), orchestrator.js_snailtracer_internal_runs);
    try std.testing.expectEqual(false, orchestrator.include_all_cases);
    try std.testing.expectEqual(false, orchestrator.use_next);
    try std.testing.expectEqual(false, orchestrator.show_output);
    try std.testing.expectEqual(@as(usize, 0), orchestrator.test_cases.len);
    try std.testing.expectEqual(@as(usize, 0), orchestrator.results.items.len);
}

test "Orchestrator.deinit properly cleans up memory" {
    const allocator = std.testing.allocator;
    
    var orchestrator = try Orchestrator.init(allocator, "test-evm", 10, 5, 3, 2, 1, 1, false, false, false);
    
    // Manually add test cases to verify cleanup
    var test_cases = try allocator.alloc(TestCase, 2);
    test_cases[0] = .{
        .name = try allocator.dupe(u8, "test-case-1"),
        .bytecode_path = try allocator.dupe(u8, "/path/to/bytecode1.txt"),
        .calldata_path = try allocator.dupe(u8, "/path/to/calldata1.txt"),
    };
    test_cases[1] = .{
        .name = try allocator.dupe(u8, "test-case-2"),
        .bytecode_path = try allocator.dupe(u8, "/path/to/bytecode2.txt"),
        .calldata_path = try allocator.dupe(u8, "/path/to/calldata2.txt"),
    };
    orchestrator.test_cases = test_cases;
    
    // Add results
    try orchestrator.results.append(.{
        .test_case = try allocator.dupe(u8, "test-result-1"),
        .mean_ms = 10.5,
        .min_ms = 9.0,
        .max_ms = 12.0,
        .std_dev_ms = 1.5,
        .median_ms = 10.0,
        .runs = 10,
        .internal_runs = 5,
    });
    
    // Deinit should clean up everything without leaks
    orchestrator.deinit();
}

test "formatTimeWithUnit selects appropriate unit" {
    // Test microseconds
    const micro_time = formatTimeWithUnit(0.5);
    try std.testing.expectEqual(TimeUnit.microseconds, micro_time.unit);
    try std.testing.expectApproxEqRel(@as(f64, 500.0), micro_time.value, 0.001);
    
    // Test milliseconds
    const milli_time = formatTimeWithUnit(50.0);
    try std.testing.expectEqual(TimeUnit.milliseconds, milli_time.unit);
    try std.testing.expectApproxEqRel(@as(f64, 50.0), milli_time.value, 0.001);
    
    // Test seconds
    const seconds_time = formatTimeWithUnit(2500.0);
    try std.testing.expectEqual(TimeUnit.seconds, seconds_time.unit);
    try std.testing.expectApproxEqRel(@as(f64, 2.5), seconds_time.value, 0.001);
}

test "parseHyperfineJson extracts values correctly" {
    const allocator = std.testing.allocator;
    
    var orchestrator = try Orchestrator.init(allocator, "test-evm", 10, 5, 3, 2, 1, 1, false, false, false);
    defer orchestrator.deinit();
    
    const json_data =
        \\{
        \\  "results": [
        \\    {
        \\      "command": "test command",
        \\      "mean": 0.0525,
        \\      "stddev": 0.0012,
        \\      "median": 0.0520,
        \\      "min": 0.0500,
        \\      "max": 0.0600
        \\    }
        \\  ]
        \\}
    ;
    
    try orchestrator.parseHyperfineJson("test-benchmark", json_data, 10, 5);
    
    try std.testing.expectEqual(@as(usize, 1), orchestrator.results.items.len);
    
    const result = orchestrator.results.items[0];
    try std.testing.expectEqualStrings("test-benchmark", result.test_case);
    
    // Values are converted to ms and divided by internal_runs
    try std.testing.expectApproxEqRel(@as(f64, 10.5), result.mean_ms, 0.001); // 0.0525 * 1000 / 5
    try std.testing.expectApproxEqRel(@as(f64, 10.0), result.min_ms, 0.001);  // 0.0500 * 1000 / 5
    try std.testing.expectApproxEqRel(@as(f64, 12.0), result.max_ms, 0.001);  // 0.0600 * 1000 / 5
    try std.testing.expectApproxEqRel(@as(f64, 0.24), result.std_dev_ms, 0.001); // 0.0012 * 1000 / 5
    try std.testing.expectApproxEqRel(@as(f64, 10.4), result.median_ms, 0.001); // 0.0520 * 1000 / 5
    try std.testing.expectEqual(@as(u32, 10), result.runs);
    try std.testing.expectEqual(@as(u32, 5), result.internal_runs);
}

test "parseHyperfineJson handles null stddev" {
    const allocator = std.testing.allocator;
    
    var orchestrator = try Orchestrator.init(allocator, "test-evm", 10, 5, 3, 2, 1, 1, false, false, false);
    defer orchestrator.deinit();
    
    const json_data =
        \\{
        \\  "results": [
        \\    {
        \\      "mean": 0.100,
        \\      "stddev": null,
        \\      "median": 0.100,
        \\      "min": 0.100,
        \\      "max": 0.100
        \\    }
        \\  ]
        \\}
    ;
    
    try orchestrator.parseHyperfineJson("single-run", json_data, 1, 1);
    
    try std.testing.expectEqual(@as(usize, 1), orchestrator.results.items.len);
    
    const result = orchestrator.results.items[0];
    try std.testing.expectEqual(@as(f64, 0.0), result.std_dev_ms);
}

test "BenchmarkResult stores correct data" {
    const result = BenchmarkResult{
        .test_case = "test-case",
        .mean_ms = 25.5,
        .min_ms = 20.0,
        .max_ms = 30.0,
        .std_dev_ms = 2.5,
        .median_ms = 25.0,
        .runs = 50,
        .internal_runs = 10,
    };
    
    try std.testing.expectEqualStrings("test-case", result.test_case);
    try std.testing.expectEqual(@as(f64, 25.5), result.mean_ms);
    try std.testing.expectEqual(@as(f64, 20.0), result.min_ms);
    try std.testing.expectEqual(@as(f64, 30.0), result.max_ms);
    try std.testing.expectEqual(@as(f64, 2.5), result.std_dev_ms);
    try std.testing.expectEqual(@as(f64, 25.0), result.median_ms);
    try std.testing.expectEqual(@as(u32, 50), result.runs);
    try std.testing.expectEqual(@as(u32, 10), result.internal_runs);
}

test "TestCase structure holds paths correctly" {
    const test_case = TestCase{
        .name = "erc20-transfer",
        .bytecode_path = "/path/to/bytecode.txt",
        .calldata_path = "/path/to/calldata.txt",
    };
    
    try std.testing.expectEqualStrings("erc20-transfer", test_case.name);
    try std.testing.expectEqualStrings("/path/to/bytecode.txt", test_case.bytecode_path);
    try std.testing.expectEqualStrings("/path/to/calldata.txt", test_case.calldata_path);
}

test "FormattedTime.format outputs correct string" {
    const allocator = std.testing.allocator;
    
    // Test microseconds formatting
    const micro_time = FormattedTime{ .value = 250.5, .unit = .microseconds };
    var micro_buf = std.ArrayList(u8).init(allocator);
    defer micro_buf.deinit();
    try micro_time.format("", .{}, micro_buf.writer());
    try std.testing.expectEqualStrings("250.50 μs", micro_buf.items);
    
    // Test milliseconds formatting
    const milli_time = FormattedTime{ .value = 15.75, .unit = .milliseconds };
    var milli_buf = std.ArrayList(u8).init(allocator);
    defer milli_buf.deinit();
    try milli_time.format("", .{}, milli_buf.writer());
    try std.testing.expectEqualStrings("15.75 ms", milli_buf.items);
    
    // Test seconds formatting
    const seconds_time = FormattedTime{ .value = 1.25, .unit = .seconds };
    var seconds_buf = std.ArrayList(u8).init(allocator);
    defer seconds_buf.deinit();
    try seconds_time.format("", .{}, seconds_buf.writer());
    try std.testing.expectEqualStrings("1.25 s", seconds_buf.items);
}