const std = @import("std");
const clap = @import("clap");
const Orchestrator = @import("Orchestrator.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                 Display this help and exit.
        \\-n, --num-runs <NUM>       Number of runs per test case (default: 10)
        \\--internal-runs <NUM>      Number of internal runs per hyperfine execution (default: 50)
        \\--snailtracer-internal-runs <NUM>   Number of internal runs for snailtracer (defaults to --internal-runs value)
        \\--export <FORMAT>          Export results (json, markdown, detailed)
        \\--all                      Include all test cases (by default only working benchmarks are included)
        \\--show-output              Show output from hyperfine
        \\--diff <TEST>              Run differential trace comparison between REVM and Zig for a specific test case
        \\--diff-output <DIR>        Output directory for differential traces (default: differential_traces)
        \\--detailed                 Run detailed performance analysis with additional metrics
        \\--perf-output <DIR>        Output directory for performance reports (default: perf-reports)
        \\
    );

    const parsers = comptime .{
        .NUM = clap.parsers.int(u32, 10),
        .FORMAT = clap.parsers.string,
        .TEST = clap.parsers.string,
        .DIR = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try printHelp();
        return;
    }

    const num_runs = res.args.@"num-runs" orelse 50;
    const internal_runs = res.args.@"internal-runs" orelse 100;
    const snailtracer_internal_runs = res.args.@"snailtracer-internal-runs" orelse internal_runs;
    const export_format = res.args.@"export";
    const include_all_cases = res.args.all != 0;
    const show_output = res.args.@"show-output" != 0;
    const diff_test = res.args.diff;
    const diff_output_dir = res.args.@"diff-output" orelse "differential_traces";
    const detailed = res.args.detailed != 0;
    const perf_output_dir = res.args.@"perf-output" orelse "perf-reports";

    if (diff_test) |test_name| {
        // Differential trace mode
        var orchestrator = try Orchestrator.init(allocator, num_runs, internal_runs, snailtracer_internal_runs, include_all_cases, show_output);
        defer orchestrator.deinit();

        try orchestrator.discoverTestCases();

        // Find the specific test case
        var found_test: ?Orchestrator.TestCase = null;
        for (orchestrator.test_cases) |tc| {
            if (std.mem.eql(u8, tc.name, test_name)) {
                found_test = tc;
                break;
            }
        }

        if (found_test) |test_case| {
            try orchestrator.runDifferentialTrace(test_case, diff_output_dir);
        } else {
            std.debug.print("Error: Test case '{s}' not found\n", .{test_name});
            std.debug.print("Available test cases:\n", .{});
            for (orchestrator.test_cases) |tc| {
                std.debug.print("  - {s}\n", .{tc.name});
            }
            std.process.exit(1);
        }
    } else {
        // Run benchmarks with call2 EVM
        var orchestrator = try Orchestrator.init(allocator, num_runs, internal_runs, snailtracer_internal_runs, include_all_cases, show_output);
        defer orchestrator.deinit();

        // Discover test cases
        try orchestrator.discoverTestCases();

        std.debug.print("Discovered {} test cases\n", .{orchestrator.test_cases.len});

        if (detailed) {
            // Run detailed performance analysis
            try orchestrator.runDetailedBenchmarks(perf_output_dir);
        } else {
            // Run normal benchmarks
            try orchestrator.runBenchmarks();

            // Print summary
            orchestrator.printSummary();
        }

        // Export results if requested
        if (export_format) |format| {
            try orchestrator.exportResults(format);
        }
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

fn exportComparisonMarkdown(allocator: std.mem.Allocator, results: []const Orchestrator.BenchmarkResult, num_runs: u32, include_all_cases: bool) !void {
    // Create the file in bench/official/results.md
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = try std.fs.selfExeDirPath(&exe_dir_buf);

    const project_root = try std.fs.path.resolve(allocator, &[_][]const u8{ exe_path, "..", ".." });
    defer allocator.free(project_root);

    const results_path = try std.fs.path.join(allocator, &[_][]const u8{ project_root, "bench", "official", "results.md" });
    defer allocator.free(results_path);

    const file = try std.fs.createFileAbsolute(results_path, .{});
    defer file.close();

    // Get current timestamp
    const timestamp = std.time.timestamp();
    const seconds = @as(u64, @intCast(timestamp));

    // Write header
    try file.writer().print("# EVM Benchmark Comparison Results\n\n", .{});
    try file.writer().print("## Summary\n\n", .{});
    try file.writer().print("**Test Runs per Case**: {}\n", .{num_runs});
    try file.writer().print("**EVM Implementation**: Guillotine Call2 (Zig with tailcall dispatch)\n", .{});
    try file.writer().print("**Timestamp**: {} (Unix epoch)\n\n", .{seconds});

    // Determine which test cases to include
    const working_test_cases = [_][]const u8{ "erc20-approval-transfer", "erc20-mint", "erc20-transfer", "ten-thousand-hashes", "snailtracer" };

    const all_test_cases = [_][]const u8{
        "erc20-approval-transfer",
        "erc20-mint",
        "erc20-transfer",
        "ten-thousand-hashes",
        "snailtracer",
        "opcodes-arithmetic",
        "opcodes-arithmetic-advanced",
        "opcodes-bitwise",
        "opcodes-block-1",
        "opcodes-block-2",
        "opcodes-comparison",
        "opcodes-control",
        "opcodes-crypto",
        "opcodes-data",
        "opcodes-dup",
        "opcodes-environmental-1",
        "opcodes-environmental-2",
        "opcodes-jump-basic",
        "opcodes-memory",
        "opcodes-push-pop",
        "opcodes-storage-cold",
        "opcodes-storage-warm",
        "opcodes-swap",
        "precompile-blake2f",
        "precompile-bn256add",
        "precompile-bn256mul",
        "precompile-bn256pairing",
        "precompile-ecrecover",
        "precompile-identity",
        "precompile-modexp",
        "precompile-ripemd160",
        "precompile-sha256",
    };

    const test_cases = if (include_all_cases) all_test_cases[0..] else working_test_cases[0..];

    // Add summary statistics
    try file.writer().print("## Performance Summary (Per Run)\n\n", .{});
    try file.writeAll("| Test Case | Mean | Median | Min | Max | Std Dev |\n");
    try file.writeAll("|-----------|------|--------|-----|-----|---------|\n");

    for (test_cases) |test_case| {
        for (results) |result| {
            if (std.mem.eql(u8, result.test_case, test_case)) {
                const mean_formatted = formatTimeWithUnit(result.mean_ms);
                const median_formatted = formatTimeWithUnit(result.median_ms);
                const min_formatted = formatTimeWithUnit(result.min_ms);
                const max_formatted = formatTimeWithUnit(result.max_ms);
                const stddev_formatted = formatTimeWithUnit(result.std_dev_ms);

                try file.writer().print("| {s:<25} | {s:>10} | {s:>10} | {s:>9} | {s:>9} | {s:>11} |\n", .{
                    test_case,
                    mean_formatted,
                    median_formatted,
                    min_formatted,
                    max_formatted,
                    stddev_formatted,
                });
                break;
            }
        }
    }


    // Add notes
    try file.writeAll("\n## Notes\n\n");
    try file.writeAll("- **All times are normalized per individual execution run**\n");
    try file.writeAll("- Times are displayed in the most appropriate unit (μs, ms, or s)\n");
    try file.writeAll("- Build: Zig ReleaseFast with tailcall-based interpreter (call2)\n");
    try file.writeAll("- Lower values indicate better performance\n");
    try file.writeAll("- Each hyperfine run executes the contract multiple times internally\n");
    try file.writeAll("- These benchmarks measure the full execution time including contract deployment\n\n");

    try file.writeAll("---\n\n");
    try file.writeAll("*Generated by Guillotine Benchmark Orchestrator*\n");

    std.debug.print("Comparison results exported to bench/official/results.md\n", .{});
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\Guillotine Call2 EVM Benchmark Orchestrator
        \\
        \\This tool orchestrates benchmarks for the Guillotine Call2 EVM using hyperfine.
        \\
        \\Usage: orchestrator [OPTIONS]
        \\
        \\Options:
        \\  -h, --help                 Display this help and exit
        \\  -n, --num-runs <NUM>       Number of runs per test case (default: 50)
        \\  --internal-runs <NUM>      Number of internal runs per hyperfine execution (default: 100)
        \\  --snailtracer-internal-runs <NUM>   Number of internal runs for snailtracer (defaults to --internal-runs)
        \\  --export <FORMAT>          Export results (json, markdown, detailed)
        \\  --all                      Include all test cases (by default only working benchmarks are included)
        \\  --show-output              Show output from hyperfine
        \\  --diff <TEST>              Run differential trace comparison for a specific test case
        \\  --diff-output <DIR>        Output directory for differential traces (default: differential_traces)
        \\  --detailed                 Run detailed performance analysis with additional metrics
        \\  --perf-output <DIR>        Output directory for performance reports (default: perf-reports)
        \\
        \\Examples:
        \\  orchestrator                    Run benchmarks with default settings
        \\  orchestrator -n 50              Run 50 iterations per test case
        \\  orchestrator --export json      Export results to JSON
        \\  orchestrator --export markdown  Export results to Markdown
        \\  orchestrator --all              Include all test cases
        \\  orchestrator --diff erc20-transfer  Run differential trace comparison
        \\  orchestrator --diff snailtracer --diff-output traces  Custom output directory
        \\  orchestrator --detailed        Run detailed performance analysis with metrics
        \\  orchestrator --detailed --perf-output results  Custom output directory for perf reports
        \\
    , .{});
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

test "selectOptimalUnit returns correct unit and value" {
    // Test edge cases
    const edge_micro = selectOptimalUnit(0.999);
    try std.testing.expectEqual(TimeUnit.microseconds, edge_micro.unit);
    try std.testing.expectApproxEqRel(@as(f64, 999.0), edge_micro.value, 0.001);

    const edge_milli = selectOptimalUnit(999.999);
    try std.testing.expectEqual(TimeUnit.milliseconds, edge_milli.unit);
    try std.testing.expectApproxEqRel(@as(f64, 999.999), edge_milli.value, 0.001);

    const edge_seconds = selectOptimalUnit(1000.0);
    try std.testing.expectEqual(TimeUnit.seconds, edge_seconds.unit);
    try std.testing.expectApproxEqRel(@as(f64, 1.0), edge_seconds.value, 0.001);
}

test "FormattedTime.format outputs correct string" {
    const allocator = std.testing.allocator;

    // Test microseconds formatting
    const micro_time = FormattedTime{ .value = 123.45, .unit = .microseconds };
    var micro_buf = std.ArrayList(u8).init(allocator);
    defer micro_buf.deinit();
    try micro_time.format("", .{}, micro_buf.writer());
    try std.testing.expectEqualStrings("123.45 μs", micro_buf.items);

    // Test milliseconds formatting
    const milli_time = FormattedTime{ .value = 87.50, .unit = .milliseconds };
    var milli_buf = std.ArrayList(u8).init(allocator);
    defer milli_buf.deinit();
    try milli_time.format("", .{}, milli_buf.writer());
    try std.testing.expectEqualStrings("87.50 ms", milli_buf.items);

    // Test seconds formatting
    const seconds_time = FormattedTime{ .value = 3.14, .unit = .seconds };
    var seconds_buf = std.ArrayList(u8).init(allocator);
    defer seconds_buf.deinit();
    try seconds_time.format("", .{}, seconds_buf.writer());
    try std.testing.expectEqualStrings("3.14 s", seconds_buf.items);
}

test "TimeUnit enum has correct values" {
    const micro = TimeUnit.microseconds;
    const milli = TimeUnit.milliseconds;
    const secs = TimeUnit.seconds;

    // Test enum values exist and are distinct
    try std.testing.expect(micro != milli);
    try std.testing.expect(milli != secs);
    try std.testing.expect(micro != secs);
}
