const std = @import("std");
const builtin = @import("builtin");
const primitives = @import("primitives");
const parser = @import("parser.zig");
const comparison = @import("comparison.zig");
const subprocess_runner = @import("subprocess_runner.zig");
const os = std.os;

const build_options = @import("build_options");
const runner_type = build_options.runner_type;

const runner = if (std.mem.eql(u8, runner_type, "minimal_evm"))
    @import("runner_minimal_evm.zig")
else if (std.mem.eql(u8, runner_type, "guillotine"))
    @import("runner_guillotine.zig")
else
    @compileError("Unknown runner_type: " ++ runner_type);

const runner_name = if (std.mem.eql(u8, runner_type, "minimal_evm"))
    "MinimalEvm"
else if (std.mem.eql(u8, runner_type, "guillotine"))
    "Guillotine EVM"
else
    @compileError("Unknown runner_type: " ++ runner_type);

const Allocator = std.mem.Allocator;

const TestStats = struct {
    total: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    crashed: usize = 0,
    timed_out: usize = 0,
    files_processed: usize = 0,
};

const TestFileResult = struct {
    success: bool,
    tests_run: usize = 0,
    tests_passed: usize = 0,
    tests_failed: usize = 0,
    tests_crashed: usize = 0,
    tests_timed_out: usize = 0,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *TestFileResult, allocator: Allocator) void {
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
    }
};

fn printProgress(stats: *const TestStats) void {
    const success_rate = if (stats.total > 0)
        @as(f64, @floatFromInt(stats.passed)) * 100.0 / @as(f64, @floatFromInt(stats.total))
    else
        0.0;

    std.debug.print("\n--- PROGRESS ---\n", .{});
    std.debug.print("Files: {d} | Tests: {d} | Pass: {d} | Fail: {d} | Crash: {d} | Timeout: {d} | Rate: {d:.1}%\n", .{
        stats.files_processed,
        stats.total,
        stats.passed,
        stats.failed,
        stats.crashed,
        stats.timed_out,
        success_rate
    });
    std.debug.print("----------------\n", .{});
}

fn printFinalSummary(stats: *const TestStats) void {
    const success_rate = if (stats.total > 0)
        @as(f64, @floatFromInt(stats.passed)) * 100.0 / @as(f64, @floatFromInt(stats.total))
    else
        0.0;

    std.debug.print("\n" ++ "=" ** 80 ++ "\n", .{});
    std.debug.print("FINAL TEST SUMMARY\n", .{});
    std.debug.print("=" ** 80 ++ "\n", .{});
    std.debug.print("Files Processed: {d}\n", .{stats.files_processed});
    std.debug.print("Total Tests:     {d}\n", .{stats.total});
    std.debug.print("Passed:          {d}\n", .{stats.passed});
    std.debug.print("Failed:          {d}\n", .{stats.failed});
    std.debug.print("Crashed:         {d}\n", .{stats.crashed});
    std.debug.print("Timed Out:       {d}\n", .{stats.timed_out});
    std.debug.print("Success Rate:    {d:.2}%\n", .{success_rate});
    std.debug.print("=" ** 80 ++ "\n\n", .{});
}

// Run a single test in child process mode
fn runSingleTest(allocator: Allocator, file_path: []const u8, test_name: []const u8, hardfork: []const u8) !void {
    // Parse the test file
    var parsed_file = try parser.parseTestFile(allocator, file_path);
    defer parsed_file.deinit();

    // Find the specific test
    const test_case = parsed_file.test_cases.get(test_name) orelse {
        std.debug.print("Test '{s}' not found in file\n", .{test_name});
        std.process.exit(1);
    };

    // Run the test
    var test_result = try runner.runTest(allocator, test_name, test_case, hardfork);
    defer test_result.deinit(allocator);

    // Output failure details if test failed (using std.debug.print which goes to stderr)
    if (!test_result.success) {
        if (test_result.error_message) |msg| {
            std.debug.print("ERROR: {s}\n", .{msg});
        }

        if (test_result.mismatches) |mismatches| {
            std.debug.print("\nSTATE MISMATCHES ({d} differences):\n", .{mismatches.len});
            for (mismatches) |mismatch| {
                const field_name = switch (mismatch.field) {
                    .balance => "balance",
                    .nonce => "nonce",
                    .code => "code",
                    .storage_slot => "storage",
                };
                const hex = std.fmt.bytesToHex(mismatch.address.bytes, .lower);
                std.debug.print("  Address: 0x{s}\n", .{&hex});
                std.debug.print("    Field: {s}\n", .{field_name});
                std.debug.print("    Expected: {s}\n", .{mismatch.expected});
                std.debug.print("    Actual:   {s}\n", .{mismatch.actual});
            }
        }
    }

    // Exit with appropriate code
    std.process.exit(if (test_result.success) 0 else 1);
}

// Process a single test file using subprocess isolation
fn processTestFile(allocator: Allocator, file_path: []const u8, exe_path: []const u8) TestFileResult {
    var result = TestFileResult{ .success = false };

    // Parse the test file to get test cases
    var file_arena = std.heap.ArenaAllocator.init(allocator);
    defer file_arena.deinit();
    const file_allocator = file_arena.allocator();

    var parsed_file = parser.parseTestFile(file_allocator, file_path) catch |err| {
        result.error_message = std.fmt.allocPrint(allocator, "Parse failed: {s}", .{@errorName(err)}) catch null;
        return result;
    };
    defer parsed_file.deinit();

    // Process each test case
    var it = parsed_file.test_cases.iterator();
    while (it.next()) |entry| {
        const test_name = entry.key_ptr.*;
        const test_case = entry.value_ptr.*;

        // Get hardforks for this test
        const hardforks = parser.getHardforks(file_allocator, test_case.post) catch |err| {
            std.debug.print("  [WARN] [{s}] Failed to get hardforks: {s}\n", .{ test_name, @errorName(err) });
            continue;
        };
        defer {
            for (hardforks) |hf| {
                file_allocator.free(hf);
            }
            file_allocator.free(hardforks);
        }

        // Run test for each hardfork in subprocess
        for (hardforks) |hardfork| {
            result.tests_run += 1;

            // Run test in subprocess with 30 second timeout
            const subprocess_result = subprocess_runner.runWithTimeout(
                allocator,
                &.{ exe_path, "--run-single-test", file_path, test_name, hardfork },
                30000, // 30 seconds
            ) catch |err| {
                std.debug.print("  [ERROR] [{s}:{s}] Subprocess error: {s}\n", .{ test_name, hardfork, @errorName(err) });
                result.tests_failed += 1;
                continue;
            };
            defer subprocess_result.deinit(allocator);

            if (subprocess_result.timed_out) {
                std.debug.print("  [TIMEOUT] [{s}:{s}] Test exceeded 30 seconds\n", .{ test_name, hardfork });
                result.tests_timed_out += 1;
            } else if (subprocess_result.exit_code >= 128) {
                // Exit codes >= 128 typically indicate signal termination (crash)
                std.debug.print("  [CRASH] [{s}:{s}] Test crashed with signal {}\n", .{ test_name, hardfork, subprocess_result.exit_code - 128 });
                result.tests_crashed += 1;
            } else if (subprocess_result.success) {
                std.debug.print("  [PASS] [{s}:{s}]\n", .{ test_name, hardfork });
                result.tests_passed += 1;
            } else {
                std.debug.print("  [FAIL] [{s}:{s}]\n", .{ test_name, hardfork });
                result.tests_failed += 1;

                // Print failure details from subprocess output (which contains stderr)
                if (subprocess_result.output.len > 0) {
                    // Indent the output for better readability
                    var line_it = std.mem.tokenizeScalar(u8, subprocess_result.output, '\n');
                    while (line_it.next()) |line| {
                        std.debug.print("    {s}\n", .{line});
                    }
                }
            }
        }
    }

    result.success = true;
    return result;
}

fn runTestsInDirectory(allocator: Allocator, dir_path: []const u8, exe_path: []const u8, stats: *TestStats) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".json")) {
            const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
            defer allocator.free(full_path);

            stats.files_processed += 1;
            std.debug.print("\n[File {d}] {s}\n", .{ stats.files_processed, entry.path });

            // Process file using subprocess isolation
            var file_result = processTestFile(allocator, full_path, exe_path);
            defer file_result.deinit(allocator);

            // Update stats
            stats.total += file_result.tests_run;
            stats.passed += file_result.tests_passed;
            stats.failed += file_result.tests_failed;
            stats.crashed += file_result.tests_crashed;
            stats.timed_out += file_result.tests_timed_out;

            if (!file_result.success) {
                if (file_result.error_message) |msg| {
                    std.debug.print("  [ERROR] {s}\n", .{msg});
                }
            }

            // Progress update every 25 files
            if (stats.files_processed % 25 == 0) {
                printProgress(stats);
            }
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check if running in single-test mode (child process)
    if (args.len == 5 and std.mem.eql(u8, args[1], "--run-single-test")) {
        const file_path = args[2];
        const test_name = args[3];
        const hardfork = args[4];
        try runSingleTest(allocator, file_path, test_name, hardfork);
        return;
    }

    // Normal mode - orchestrate tests
    const exe_path = args[0];
    const path = if (args.len > 1) args[1] else "test/execution-spec-tests/fixtures/fixtures_stable/state_tests";

    std.debug.print("Ethereum Execution Spec Test Runner ({s})\n", .{runner_name});
    std.debug.print("Target: {s}\n", .{path});
    std.debug.print("=" ** 80 ++ "\n", .{});

    var stats = TestStats{};

    // Ensure summary is always printed
    defer printFinalSummary(&stats);

    // Check if path is file or directory
    const stat = std.fs.cwd().statFile(path) catch |err| {
        std.debug.print("ERROR: Cannot access path '{s}': {s}\n\n", .{ path, @errorName(err) });
        std.debug.print("Please run the following command to install test fixtures:\n", .{});
        std.debug.print("./scripts/fetch-test-fixtures.sh\n", .{});
        return;
    };

    if (stat.kind == .directory) {
        runTestsInDirectory(allocator, path, exe_path, &stats) catch |err| {
            std.debug.print("\nERROR: Directory processing failed: {s}\n", .{@errorName(err)});
        };
    } else if (stat.kind == .file) {
        stats.files_processed = 1;
        std.debug.print("\n[File 1] {s}\n", .{std.fs.path.basename(path)});

        var file_result = processTestFile(allocator, path, exe_path);
        defer file_result.deinit(allocator);

        stats.total = file_result.tests_run;
        stats.passed = file_result.tests_passed;
        stats.failed = file_result.tests_failed;
        stats.crashed = file_result.tests_crashed;
        stats.timed_out = file_result.tests_timed_out;

        if (!file_result.success and file_result.error_message != null) {
            std.debug.print("  [ERROR] {s}\n", .{file_result.error_message.?});
        }
    } else {
        std.debug.print("ERROR: Path '{s}' is neither file nor directory\n", .{path});
        return;
    }

    std.debug.print("\nProcessing complete.\n", .{});
}
