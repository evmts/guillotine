const std = @import("std");
const clap = @import("clap");
const Orchestrator = @import("Orchestrator.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                 Display this help and exit.
        \\-e, --evm <NAME>           EVM implementation to benchmark (default: zig)
        \\-n, --num-runs <NUM>       Number of runs per test case (default: 10)
        \\--js-runs <NUM>            Number of runs for JavaScript/EthereumJS (defaults to --num-runs value)
        \\--internal-runs <NUM>      Number of internal runs per hyperfine execution (default: 50)
        \\--js-internal-runs <NUM>   Number of internal runs for JavaScript (defaults to --internal-runs value)
        \\--snailtracer-internal-runs <NUM>   Number of internal runs for snailtracer (defaults to --internal-runs value)
        \\--js-snailtracer-internal-runs <NUM>   Number of internal runs for JavaScript snailtracer (defaults to --js-internal-runs value)
        \\--export <FORMAT>          Export results (json, markdown)
        \\--compare                  Compare all available EVM implementations
        \\--all                      Include all test cases (by default only working benchmarks are included)
        \\--next                     Use block-based execution for Zig EVM (new optimized interpreter)
        \\
    );

    const parsers = comptime .{
        .NAME = clap.parsers.string,
        .NUM = clap.parsers.int(u32, 10),
        .FORMAT = clap.parsers.string,
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

    const evm_name = res.args.evm orelse "zig";
    const num_runs = res.args.@"num-runs" orelse 50;
    const js_runs = res.args.@"js-runs" orelse num_runs;
    const internal_runs = res.args.@"internal-runs" orelse 100;
    const js_internal_runs = res.args.@"js-internal-runs" orelse internal_runs;
    const snailtracer_internal_runs = res.args.@"snailtracer-internal-runs" orelse internal_runs;
    const js_snailtracer_internal_runs = res.args.@"js-snailtracer-internal-runs" orelse js_internal_runs;
    const export_format = res.args.@"export";
    const compare_mode = res.args.compare != 0;
    const include_all_cases = res.args.all != 0;
    const use_next = res.args.next != 0;

    if (compare_mode) {
        // Compare mode: run benchmarks for all available EVMs
        const evms = [_][]const u8{ "zig", "revm", "ethereumjs", "geth", "evmone" };

        var all_results = std.ArrayList(Orchestrator.BenchmarkResult).init(allocator);
        defer all_results.deinit();

        for (evms) |evm| {
            std.debug.print("\n=== Running benchmarks for {s} ===\n", .{evm});

            var orchestrator = try Orchestrator.init(allocator, evm, num_runs, internal_runs, js_runs, js_internal_runs, snailtracer_internal_runs, js_snailtracer_internal_runs, include_all_cases, use_next);
            defer orchestrator.deinit();

            try orchestrator.discoverTestCases();
            try orchestrator.runBenchmarks();

            // Collect results
            for (orchestrator.results.items) |result| {
                try all_results.append(.{
                    .test_case = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ result.test_case, evm }),
                    .mean_ms = result.mean_ms,
                    .min_ms = result.min_ms,
                    .max_ms = result.max_ms,
                    .std_dev_ms = result.std_dev_ms,
                    .median_ms = result.median_ms,
                    .runs = result.runs,
                    .internal_runs = result.internal_runs,
                });
            }
        }

        // Export comparison results
        if (export_format) |format| {
            if (std.mem.eql(u8, format, "markdown")) {
                try exportComparisonMarkdown(allocator, all_results.items, num_runs, js_runs, include_all_cases);
            }
        }

        // Free allocated memory
        for (all_results.items) |result| {
            allocator.free(result.test_case);
        }
    } else {
        // Single EVM mode
        var orchestrator = try Orchestrator.init(allocator, evm_name, num_runs, internal_runs, js_runs, js_internal_runs, snailtracer_internal_runs, js_snailtracer_internal_runs, include_all_cases, use_next);
        defer orchestrator.deinit();

        // Discover test cases
        try orchestrator.discoverTestCases();

        std.debug.print("Discovered {} test cases\n", .{orchestrator.test_cases.len});

        // Run benchmarks
        try orchestrator.runBenchmarks();

        // Print summary
        orchestrator.printSummary();

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

fn exportComparisonMarkdown(allocator: std.mem.Allocator, results: []const Orchestrator.BenchmarkResult, num_runs: u32, js_runs: u32, include_all_cases: bool) !void {
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
    if (js_runs != num_runs) {
        try file.writer().print("**Test Runs per Case**: {} (EthereumJS: {})\n", .{ num_runs, js_runs });
    } else {
        try file.writer().print("**Test Runs per Case**: {}\n", .{num_runs});
    }
    try file.writer().print("**EVMs Compared**: Guillotine (Zig), REVM (Rust), EthereumJS (JavaScript), Geth (Go), evmone (C++)\n", .{});
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

    // Add summary statistics first
    try file.writer().print("## Overall Performance Summary (Per Run)\n\n", .{});
    try file.writeAll("| Test Case | Guillotine | REVM | EthereumJS | Geth | evmone |\n");
    try file.writeAll("|-----------|------------|------|------------|------|--------|\n");

    for (test_cases) |test_case| {
        var zig_mean: f64 = 0;
        var revm_mean: f64 = 0;
        var ethereumjs_mean: f64 = 0;
        var geth_mean: f64 = 0;
        var evmone_mean: f64 = 0;

        for (results) |result| {
            // Check if result starts with test_case followed by " (" (exact match)
            if (std.mem.startsWith(u8, result.test_case, test_case) and
                result.test_case.len > test_case.len and
                std.mem.eql(u8, result.test_case[test_case.len .. test_case.len + 2], " ("))
            {
                if (std.mem.indexOf(u8, result.test_case, "(zig)") != null) {
                    zig_mean = result.mean_ms;
                } else if (std.mem.indexOf(u8, result.test_case, "(revm)") != null) {
                    revm_mean = result.mean_ms;
                } else if (std.mem.indexOf(u8, result.test_case, "(ethereumjs)") != null) {
                    ethereumjs_mean = result.mean_ms;
                } else if (std.mem.indexOf(u8, result.test_case, "(geth)") != null) {
                    geth_mean = result.mean_ms;
                } else if (std.mem.indexOf(u8, result.test_case, "(evmone)") != null) {
                    evmone_mean = result.mean_ms;
                }
            }
        }

        const zig_formatted = formatTimeWithUnit(zig_mean);
        const revm_formatted = formatTimeWithUnit(revm_mean);
        const ethereumjs_formatted = formatTimeWithUnit(ethereumjs_mean);
        const geth_formatted = formatTimeWithUnit(geth_mean);
        const evmone_formatted = formatTimeWithUnit(evmone_mean);

        try file.writer().print("| {s:<25} | {s:>10} | {s:>4} | {s:>10} | {s:>4} | {s:>6} |\n", .{
            test_case,
            zig_formatted,
            revm_formatted,
            ethereumjs_formatted,
            geth_formatted,
            evmone_formatted,
        });
    }

    // Group results by test case
    try file.writer().print("\n## Detailed Performance Comparison\n\n", .{});

    // Write comparison tables for each test case

    for (test_cases) |test_case| {
        try file.writer().print("### {s}\n\n", .{test_case});
        try file.writeAll("| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |\n");
        try file.writeAll("|-----|----------------|------------------|---------------|---------------|-------------------|---------------|\n");

        // Find results for this test case (exact match to avoid duplicates)
        for (results) |result| {
            // Check if result starts with test_case followed by " ("
            if (std.mem.startsWith(u8, result.test_case, test_case) and
                result.test_case.len > test_case.len and
                std.mem.eql(u8, result.test_case[test_case.len .. test_case.len + 2], " ("))
            {
                const evm_name = if (std.mem.indexOf(u8, result.test_case, "(zig)") != null)
                    "Guillotine"
                else if (std.mem.indexOf(u8, result.test_case, "(revm)") != null)
                    "REVM"
                else if (std.mem.indexOf(u8, result.test_case, "(ethereumjs)") != null)
                    "EthereumJS"
                else if (std.mem.indexOf(u8, result.test_case, "(geth)") != null)
                    "Geth"
                else
                    "evmone";

                const mean_formatted = formatTimeWithUnit(result.mean_ms);
                const median_formatted = formatTimeWithUnit(result.median_ms);
                const min_formatted = formatTimeWithUnit(result.min_ms);
                const max_formatted = formatTimeWithUnit(result.max_ms);
                const stddev_formatted = formatTimeWithUnit(result.std_dev_ms);

                try file.writer().print("| {s:<11} | {s:>14} | {s:>16} | {s:>13} | {s:>13} | {s:>17} | {d:>13} |\n", .{
                    evm_name,
                    mean_formatted,
                    median_formatted,
                    min_formatted,
                    max_formatted,
                    stddev_formatted,
                    result.internal_runs,
                });
            }
        }

        try file.writer().print("\n", .{});
    }

    // Add notes
    try file.writeAll("\n## Notes\n\n");
    try file.writeAll("- **All times are normalized per individual execution run**\n");
    try file.writeAll("- Times are displayed in the most appropriate unit (μs, ms, or s)\n");
    try file.writeAll("- All implementations use optimized builds:\n");
    try file.writeAll("  - Zig: ReleaseFast\n");
    try file.writeAll("  - Rust (REVM): --release\n");
    try file.writeAll("  - JavaScript (EthereumJS): Bun runtime\n");
    try file.writeAll("  - Go (geth): -O3 optimizations\n");
    try file.writeAll("  - C++ (evmone): -O3 -march=native\n");
    try file.writeAll("- Lower values indicate better performance\n");
    try file.writeAll("- Each hyperfine run executes the contract multiple times internally (see Internal Runs column)\n");
    try file.writeAll("- These benchmarks measure the full execution time including contract deployment\n\n");

    try file.writeAll("---\n\n");
    try file.writeAll("*Generated by Guillotine Benchmark Orchestrator*\n");

    std.debug.print("Comparison results exported to bench/official/results.md\n", .{});
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\EVM Benchmark Orchestrator
        \\
        \\This tool orchestrates benchmarks across various EVM implementations using hyperfine.
        \\
        \\Usage: orchestrator [OPTIONS]
        \\
        \\Options:
        \\  -h, --help                 Display this help and exit
        \\  -e, --evm <NAME>           EVM implementation to benchmark (default: zig)
        \\  -n, --num-runs <NUM>       Number of runs per test case (default: 50)
        \\  --js-runs <NUM>            Number of runs for JavaScript/EthereumJS (defaults to --num-runs)
        \\  --internal-runs <NUM>      Number of internal runs per hyperfine execution (default: 100)
        \\  --js-internal-runs <NUM>   Number of internal runs for JavaScript (defaults to --internal-runs)
        \\  --snailtracer-internal-runs <NUM>   Number of internal runs for snailtracer (defaults to --internal-runs)
        \\  --js-snailtracer-internal-runs <NUM>   Number of internal runs for JavaScript snailtracer (defaults to --js-internal-runs)
        \\  --export <FORMAT>          Export results (json, markdown)
        \\  --next                     Use block-based execution for Zig EVM (new optimized interpreter)
        \\
        \\Examples:
        \\  orchestrator                    Run benchmarks with Zig EVM
        \\  orchestrator -e zig -n 50       Run 50 iterations per test case
        \\  orchestrator --export json      Export results to JSON
        \\  orchestrator --export markdown  Export results to Markdown
        \\  orchestrator --compare --export markdown  Compare all EVMs and export
        \\  orchestrator --compare --js-runs 1  Compare EVMs with only 1 run for JavaScript
        \\
    , .{});
}
