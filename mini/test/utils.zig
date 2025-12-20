const std = @import("std");
const builtin = @import("builtin");

// ANSI color codes and styles
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const italic = "\x1b[3m";
    pub const underline = "\x1b[4m";

    pub const black = "\x1b[30m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const white = "\x1b[37m";
    pub const gray = "\x1b[90m";
    pub const bright_red = "\x1b[91m";
    pub const bright_green = "\x1b[92m";
    pub const bright_yellow = "\x1b[93m";
    pub const bright_blue = "\x1b[94m";
    pub const bright_magenta = "\x1b[95m";
    pub const bright_cyan = "\x1b[96m";

    // Background colors
    pub const bg_red = "\x1b[41m";
    pub const bg_green = "\x1b[42m";
    pub const bg_yellow = "\x1b[43m";
    pub const bg_blue = "\x1b[44m";
    pub const bg_magenta = "\x1b[45m";
    pub const bg_cyan = "\x1b[46m";
    pub const bg_white = "\x1b[47m";
    pub const bg_gray = "\x1b[100m";
    pub const bg_bright_red = "\x1b[101m";
    pub const bg_bright_green = "\x1b[102m";
};

pub const Icons = struct {
    pub const check = "✓";
    pub const cross = "✖";
    pub const dot = "·";
    pub const arrow = "›";
    pub const pointer = "❯";
    pub const info = "ℹ";
    pub const warning = "⚠";
    pub const error_icon = "⨯";
    pub const clock = "⏱";
    pub const filter_icon = "🔍";
};

pub const TestResult = struct {
    name: []const u8,
    suite: []const u8,
    test_name: []const u8,
    passed: bool,
    todo: bool = false,
    error_msg: ?[]const u8,
    duration_ns: u64,
    file_path: ?[]const u8 = null,
    line_number: ?u32 = null,
};

pub fn extractSuiteName(full_name: []const u8) []const u8 {
    // Find the last occurrence of ".test."
    var last_test_pos: ?usize = null;
    var i: usize = 0;
    while (i < full_name.len - 5) : (i += 1) {
        if (std.mem.eql(u8, full_name[i..@min(i + 6, full_name.len)], ".test.")) {
            last_test_pos = i;
        }
    }

    if (last_test_pos) |pos| {
        return full_name[0..pos];
    }

    // Fallback: find last dot
    if (std.mem.lastIndexOf(u8, full_name, ".")) |pos| {
        return full_name[0..pos];
    }

    return full_name;
}

pub fn extractTestName(full_name: []const u8) []const u8 {
    // Find the last occurrence of ".test."
    var last_test_pos: ?usize = null;
    var i: usize = 0;
    while (i < full_name.len - 5) : (i += 1) {
        if (std.mem.eql(u8, full_name[i..@min(i + 6, full_name.len)], ".test.")) {
            last_test_pos = i + 6;
        }
    }

    if (last_test_pos) |pos| {
        return full_name[pos..];
    }

    // Fallback: find last dot
    if (std.mem.lastIndexOf(u8, full_name, ".")) |pos| {
        return full_name[pos + 1 ..];
    }

    return full_name;
}

pub fn formatDuration(writer: anytype, ns: u64) !void {
    if (ns < 1_000) {
        try std.fmt.format(writer, "{s}{d} ns{s}", .{ Color.gray, ns, Color.reset });
    } else if (ns < 1_000_000) {
        try std.fmt.format(writer, "{s}{d:.2} μs{s}", .{ Color.gray, @as(f64, @floatFromInt(ns)) / 1_000.0, Color.reset });
    } else if (ns < 1_000_000_000) {
        try std.fmt.format(writer, "{s}{d:.2} ms{s}", .{ Color.gray, @as(f64, @floatFromInt(ns)) / 1_000_000.0, Color.reset });
    } else {
        try std.fmt.format(writer, "{s}{d:.2} s{s}", .{ Color.yellow, @as(f64, @floatFromInt(ns)) / 1_000_000_000.0, Color.reset });
    }
}

pub fn clearLine(writer: anytype) !void {
    try std.fmt.format(writer, "\r\x1b[K", .{});
}

pub fn clearScreen(writer: anytype) !void {
    try std.fmt.format(writer, "\x1b[2J\x1b[H", .{});
}

pub fn moveCursorUp(writer: anytype, lines: usize) !void {
    try std.fmt.format(writer, "\x1b[{d}A", .{lines});
}

pub fn printProgress(writer: anytype, current: usize, total: usize, suite_name: []const u8) !void {
    try clearLine(writer);
    const percent = (current * 100) / total;

    // Progress bar
    const bar_width = 20;
    const filled = (current * bar_width) / total;

    try std.fmt.format(writer, " {s}⠙{s} ", .{ Color.cyan, Color.reset });

    // Progress bar
    try std.fmt.format(writer, "{s}[{s}", .{ Color.dim, Color.reset });
    for (0..bar_width) |i| {
        if (i < filled) {
            try std.fmt.format(writer, "{s}━{s}", .{ Color.bright_cyan, Color.reset });
        } else {
            try std.fmt.format(writer, "{s}━{s}", .{ Color.gray, Color.reset });
        }
    }
    try std.fmt.format(writer, "{s}]{s} ", .{ Color.dim, Color.reset });

    try std.fmt.format(writer, "{s}{d}%{s} ", .{ Color.bright_cyan, percent, Color.reset });
    try std.fmt.format(writer, "{s}|{s} ", .{ Color.dim, Color.reset });
    try std.fmt.format(writer, "{s}{s}{s}", .{ Color.gray, suite_name, Color.reset });
    try std.fmt.format(writer, " {s}[{d}/{d}]{s}", .{ Color.dim, current, total, Color.reset });
}

pub fn runTestInProcess(allocator: std.mem.Allocator, test_index: usize) !TestResult {
    const t = builtin.test_functions[test_index];
    const suite_name = extractSuiteName(t.name);
    const test_name = extractTestName(t.name);

    var test_result = TestResult{
        .name = t.name,
        .suite = suite_name,
        .test_name = test_name,
        .passed = true,
        .error_msg = null,
        .duration_ns = 0,
    };

    const test_start = std.time.nanoTimestamp();

    // Allow disabling fork to get full panic traces when debugging
    const nofork = std.posix.getenv("TEST_NOFORK") != null;
    // Fork to isolate test execution (unless TEST_NOFORK is set)
    const pid = if (!nofork) try std.posix.fork() else 0;

    if (pid == 0) {
        // Child process - run the test
        std.testing.allocator_instance = .{};
        t.func() catch {
            std.posix.exit(1);
        };

        if (std.testing.allocator_instance.deinit() == .leak) {
            std.posix.exit(2); // Exit code 2 for memory leak
        }

        std.posix.exit(0); // Success
    } else {
        if (nofork) {
            // No fork mode: we already executed in current process.
            const test_end = std.time.nanoTimestamp();
            test_result.duration_ns = @intCast(test_end - test_start);
            return test_result;
        }
        // Parent process - wait for child with 60 second timeout
        const timeout_ns: i128 = 60 * std.time.ns_per_s;
        const deadline = std.time.nanoTimestamp() + timeout_ns;

        var timed_out = false;
        var wait_result: std.posix.WaitPidResult = undefined;

        while (true) {
            // Try non-blocking wait
            wait_result = std.posix.waitpid(pid, std.posix.W.NOHANG);

            // Check if child has exited
            if (wait_result.pid == pid) {
                break;
            }

            // Check timeout
            const now = std.time.nanoTimestamp();
            if (now >= deadline) {
                // Timeout - kill the child process
                std.posix.kill(pid, std.posix.SIG.KILL) catch |err| {
                    // If we can't kill the process, report it but continue cleanup
                    std.debug.print("Warning: Failed to kill timed-out test process {d}: {}\n", .{ pid, err });
                };
                _ = std.posix.waitpid(pid, 0); // Clean up zombie
                timed_out = true;
                break;
            }

            // Sleep a bit before checking again
            std.Thread.sleep(3 * std.time.ns_per_ms);
        }

        const test_end = std.time.nanoTimestamp();
        test_result.duration_ns = @intCast(test_end - test_start);

        if (timed_out) {
            test_result.passed = false;
            test_result.error_msg = try allocator.dupe(u8, "test timeout (60s)");
        } else if (std.posix.W.IFEXITED(wait_result.status)) {
            const exit_code = std.posix.W.EXITSTATUS(wait_result.status);
            if (exit_code == 0) {
                test_result.passed = true;
            } else if (exit_code == 1) {
                test_result.passed = false;
                test_result.error_msg = try allocator.dupe(u8, "test failed");
            } else if (exit_code == 2) {
                test_result.passed = false;
                test_result.error_msg = try allocator.dupe(u8, "memory leak detected");
            } else {
                test_result.passed = false;
                test_result.error_msg = try std.fmt.allocPrint(allocator, "exited with code {d}", .{exit_code});
            }
        } else if (std.posix.W.IFSIGNALED(wait_result.status)) {
            const signal = std.posix.W.TERMSIG(wait_result.status);
            test_result.passed = false;
            test_result.error_msg = try std.fmt.allocPrint(allocator, "crashed with signal {d}", .{signal});
        } else {
            test_result.passed = false;
            test_result.error_msg = try allocator.dupe(u8, "abnormal termination");
        }
    }

    return test_result;
}

pub fn displayResults(writer: anytype, allocator: std.mem.Allocator, results: []TestResult) !void {
    // Group results by suite
    var suite_map = std.StringHashMap(std.ArrayList(TestResult)).init(allocator);
    defer {
        var it = suite_map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        suite_map.deinit();
    }

    for (results) |result| {
        const entry = try suite_map.getOrPut(result.suite);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{};
        }
        try entry.value_ptr.append(allocator, result);
    }

    // Sort suites
    var suites: std.ArrayList([]const u8) = .{};
    defer suites.deinit(allocator);
    var suite_iter = suite_map.iterator();
    while (suite_iter.next()) |entry| {
        try suites.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, suites.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var passed_count: u32 = 0;
    var failed_count: u32 = 0;
    var todo_count: u32 = 0;
    var failed_tests = std.ArrayListUnmanaged(TestResult){};
    defer failed_tests.deinit(allocator);

    try std.fmt.format(writer, "\n{s}─────────────────────────────────────────{s}\n", .{ Color.dim, Color.reset });
    try std.fmt.format(writer, " {s}Test Results{s}\n", .{ Color.bold, Color.reset });
    try std.fmt.format(writer, "{s}─────────────────────────────────────────{s}\n\n", .{ Color.dim, Color.reset });

    for (suites.items) |suite| {
        const tests = suite_map.get(suite).?;

        var suite_passed: u32 = 0;
        var suite_failed: u32 = 0;
        var suite_todo: u32 = 0;
        var suite_duration: u64 = 0;

        for (tests.items) |t| {
            suite_duration += t.duration_ns;
            if (t.todo) {
                suite_todo += 1;
                todo_count += 1;
            } else if (t.passed) {
                suite_passed += 1;
                passed_count += 1;
            } else {
                suite_failed += 1;
                failed_count += 1;
                try failed_tests.append(allocator, t);
            }
        }

        // Print suite header
        if (suite_failed > 0) {
            try std.fmt.format(writer, " {s}{s} FAIL {s} {s}{s}{s} ", .{
                Color.bg_red,
                Color.white,
                Color.reset,
                Color.white,
                suite,
                Color.reset,
            });
        } else if (suite_todo > 0 and suite_passed == 0) {
            try std.fmt.format(writer, " {s}{s} TODO {s} {s}{s}{s} ", .{
                Color.bg_yellow,
                Color.black,
                Color.reset,
                Color.yellow,
                suite,
                Color.reset,
            });
        } else {
            try std.fmt.format(writer, " {s}{s}{s} {s}{s}{s} ", .{
                Color.green,
                Icons.check,
                Color.reset,
                Color.dim,
                suite,
                Color.reset,
            });
        }

        // Print test counts
        if (suite_failed > 0) {
            try std.fmt.format(writer, "{s}{d} failed{s}", .{
                Color.red,
                suite_failed,
                Color.reset,
            });
            if (suite_passed > 0) {
                try std.fmt.format(writer, " {s}|{s} {s}{d} passed{s}", .{
                    Color.dim,
                    Color.reset,
                    Color.green,
                    suite_passed,
                    Color.reset,
                });
            }
            if (suite_todo > 0) {
                try std.fmt.format(writer, " {s}|{s} {s}{d} todo{s}", .{
                    Color.dim,
                    Color.reset,
                    Color.yellow,
                    suite_todo,
                    Color.reset,
                });
            }
        } else if (suite_todo > 0) {
            try std.fmt.format(writer, "{s}{d} todo{s}", .{
                Color.yellow,
                suite_todo,
                Color.reset,
            });
            if (suite_passed > 0) {
                try std.fmt.format(writer, " {s}|{s} {s}{d} passed{s}", .{
                    Color.dim,
                    Color.reset,
                    Color.green,
                    suite_passed,
                    Color.reset,
                });
            }
        } else {
            try std.fmt.format(writer, "{s}({d}){s}", .{
                Color.green,
                suite_passed,
                Color.reset,
            });
        }

        try std.fmt.format(writer, " ", .{});
        try formatDuration(writer, suite_duration);
        try std.fmt.format(writer, "\n", .{});

        // Print all test names with pass/fail status on same line
        for (tests.items) |t| {
            if (t.todo) {
                try std.fmt.format(writer, "   {s}{s} {s}(TODO){s}\n", .{
                    Color.yellow,
                    t.test_name,
                    Color.yellow,
                    Color.reset,
                });
            } else if (t.passed) {
                try std.fmt.format(writer, "   {s}{s}{s} {s}\n", .{
                    Color.green,
                    Icons.check,
                    Color.reset,
                    t.test_name,
                });
            } else {
                try std.fmt.format(writer, "   {s}{s}{s} {s}\n", .{
                    Color.red,
                    Icons.cross,
                    Color.reset,
                    t.test_name,
                });
            }
        }
    }

    // Print detailed failure information
    if (failed_tests.items.len > 0) {
        try std.fmt.format(writer, "\n{s}⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯{s}\n", .{
            Color.red,
            Color.reset,
        });
        try std.fmt.format(writer, " {s}Failed Tests {d}{s}\n", .{
            Color.red,
            failed_tests.items.len,
            Color.reset,
        });
        try std.fmt.format(writer, "{s}⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯{s}\n\n", .{
            Color.red,
            Color.reset,
        });

        for (failed_tests.items, 0..) |fail, idx| {
            try std.fmt.format(writer, " {s}FAIL{s} {s}{s} {s}{s}{s}{s}\n", .{
                Color.bg_bright_red,
                Color.reset,
                Color.white,
                Icons.arrow,
                Color.reset,
                Color.bright_yellow,
                fail.name,
                Color.reset,
            });

            if (fail.error_msg) |msg| {
                try std.fmt.format(writer, "\n", .{});
                var lines = std.mem.tokenizeScalar(u8, msg, '\n');
                while (lines.next()) |line| {
                    try std.fmt.format(writer, "      {s}{s} {s}{s}{s}\n", .{
                        Color.red,
                        Icons.cross,
                        Color.reset,
                        line,
                        Color.reset,
                    });
                }
            }

            if (idx < failed_tests.items.len - 1) {
                try std.fmt.format(writer, "\n", .{});
            }
        }
    }

    // Print summary
    try std.fmt.format(writer, "\n{s}─────────────────────────────────────────{s}\n", .{ Color.dim, Color.reset });
    try std.fmt.format(writer, " {s}Summary{s}\n", .{ Color.bold, Color.reset });

    if (failed_count > 0) {
        try std.fmt.format(writer, "   {s}Tests:{s}  {s}{d} failed{s}", .{
            Color.bold,
            Color.reset,
            Color.red,
            failed_count,
            Color.reset,
        });
        if (passed_count > 0) {
            try std.fmt.format(writer, " {s}|{s} {s}{d} passed{s}", .{
                Color.dim,
                Color.reset,
                Color.green,
                passed_count,
                Color.reset,
            });
        }
        if (todo_count > 0) {
            try std.fmt.format(writer, " {s}|{s} {s}{d} todo{s}", .{
                Color.dim,
                Color.reset,
                Color.yellow,
                todo_count,
                Color.reset,
            });
        }
    } else {
        try std.fmt.format(writer, "   {s}Tests:{s}  {s}{d} passed{s}", .{
            Color.bold,
            Color.reset,
            Color.green,
            passed_count,
            Color.reset,
        });
        if (todo_count > 0) {
            try std.fmt.format(writer, " {s}|{s} {s}{d} todo{s}", .{
                Color.dim,
                Color.reset,
                Color.yellow,
                todo_count,
                Color.reset,
            });
        }
    }
    try std.fmt.format(writer, " {s}({d}){s}\n", .{
        Color.dim,
        results.len,
        Color.reset,
    });
    try std.fmt.format(writer, "{s}─────────────────────────────────────────{s}\n", .{ Color.dim, Color.reset });
}

pub fn matchesFilter(test_name: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    return std.mem.indexOf(u8, test_name, filter) != null;
}

pub const OutputFormat = enum {
    pretty,
    json,
    junit,
};

pub fn outputJSON(writer: anytype, results: []TestResult, duration_ns: u64) !void {
    var passed: usize = 0;
    var failed: usize = 0;
    var todo: usize = 0;

    for (results) |r| {
        if (r.todo) {
            todo += 1;
        } else if (r.passed) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    try std.fmt.format(writer, "{{", .{});
    try std.fmt.format(writer, "\"success\":{s},", .{if (failed == 0) "true" else "false"});
    try std.fmt.format(writer, "\"total\":{d},", .{results.len});
    try std.fmt.format(writer, "\"passed\":{d},", .{passed});
    try std.fmt.format(writer, "\"failed\":{d},", .{failed});
    try std.fmt.format(writer, "\"todo\":{d},", .{todo});
    try std.fmt.format(writer, "\"duration_ms\":{d:.2},", .{@as(f64, @floatFromInt(duration_ns)) / 1_000_000.0});
    try std.fmt.format(writer, "\"tests\":[", .{});

    for (results, 0..) |r, i| {
        try std.fmt.format(writer, "{{", .{});
        try std.fmt.format(writer, "\"name\":\"{s}\",", .{escapeJSON(r.name)});
        try std.fmt.format(writer, "\"suite\":\"{s}\",", .{escapeJSON(r.suite)});
        try std.fmt.format(writer, "\"test_name\":\"{s}\",", .{escapeJSON(r.test_name)});
        try std.fmt.format(writer, "\"status\":\"{s}\",", .{if (r.todo) "todo" else if (r.passed) "passed" else "failed"});
        try std.fmt.format(writer, "\"duration_ms\":{d:.2}", .{@as(f64, @floatFromInt(r.duration_ns)) / 1_000_000.0});

        if (r.error_msg) |msg| {
            try std.fmt.format(writer, ",\"error\":\"{s}\"", .{escapeJSON(msg)});
        }

        try std.fmt.format(writer, "}}", .{});
        if (i < results.len - 1) {
            try std.fmt.format(writer, ",", .{});
        }
    }

    try std.fmt.format(writer, "]}}\n", .{});
}

pub fn outputJUnit(writer: anytype, allocator: std.mem.Allocator, results: []TestResult, duration_ns: u64) !void {
    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;

    for (results) |r| {
        if (r.todo) {
            skipped += 1;
        } else if (r.passed) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    const duration_s = @as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0;

    try std.fmt.format(writer, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n", .{});
    try std.fmt.format(writer, "<testsuites tests=\"{d}\" failures=\"{d}\" skipped=\"{d}\" time=\"{d:.3}\">\n", .{
        results.len,
        failed,
        skipped,
        duration_s,
    });

    // Group by suite
    var suite_map = std.StringHashMap(std.ArrayList(TestResult)).init(allocator);
    defer {
        var it = suite_map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        suite_map.deinit();
    }

    for (results) |result| {
        const entry = try suite_map.getOrPut(result.suite);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{};
        }
        try entry.value_ptr.append(allocator, result);
    }

    var suite_iter = suite_map.iterator();
    while (suite_iter.next()) |entry| {
        const suite_name = entry.key_ptr.*;
        const tests = entry.value_ptr.*;

        var suite_duration: u64 = 0;
        var suite_failed: usize = 0;
        var suite_skipped: usize = 0;

        for (tests.items) |t| {
            suite_duration += t.duration_ns;
            if (t.todo) {
                suite_skipped += 1;
            } else if (!t.passed) {
                suite_failed += 1;
            }
        }

        const suite_duration_s = @as(f64, @floatFromInt(suite_duration)) / 1_000_000_000.0;

        try std.fmt.format(writer, "  <testsuite name=\"{s}\" tests=\"{d}\" failures=\"{d}\" skipped=\"{d}\" time=\"{d:.3}\">\n", .{
            escapeXML(suite_name),
            tests.items.len,
            suite_failed,
            suite_skipped,
            suite_duration_s,
        });

        for (tests.items) |t| {
            const test_duration_s = @as(f64, @floatFromInt(t.duration_ns)) / 1_000_000_000.0;
            try std.fmt.format(writer, "    <testcase name=\"{s}\" classname=\"{s}\" time=\"{d:.3}\"", .{
                escapeXML(t.test_name),
                escapeXML(t.suite),
                test_duration_s,
            });

            if (t.todo) {
                try std.fmt.format(writer, ">\n      <skipped message=\"TODO\"/>\n    </testcase>\n", .{});
            } else if (!t.passed) {
                try std.fmt.format(writer, ">\n      <failure message=\"{s}\"/>\n    </testcase>\n", .{
                    if (t.error_msg) |msg| escapeXML(msg) else "Test failed",
                });
            } else {
                try std.fmt.format(writer, "/>\n", .{});
            }
        }

        try std.fmt.format(writer, "  </testsuite>\n", .{});
    }

    try std.fmt.format(writer, "</testsuites>\n", .{});
}

fn escapeJSON(s: []const u8) []const u8 {
    // Check if string needs escaping
    var needs_escape = false;
    for (s) |c| {
        if (c == '"' or c == '\\' or c == '\n' or c == '\r' or c == '\t' or c < 0x20) {
            needs_escape = true;
            break;
        }
    }

    if (!needs_escape) return s;

    // Allocate and escape
    // Note: This uses page_allocator for JSON output lifetime
    // The escaped strings need to live for the duration of the output
    const allocator = std.heap.page_allocator;
    var result: std.ArrayList(u8) = .{};
    result.ensureTotalCapacity(allocator, s.len) catch return s;
    for (s) |c| {
        switch (c) {
            '"' => result.appendSlice(allocator, "\\\"") catch return s,
            '\\' => result.appendSlice(allocator, "\\\\") catch return s,
            '\n' => result.appendSlice(allocator, "\\n") catch return s,
            '\r' => result.appendSlice(allocator, "\\r") catch return s,
            '\t' => result.appendSlice(allocator, "\\t") catch return s,
            else => {
                if (c < 0x20) {
                    // Control characters: use \uXXXX format
                    std.fmt.format(result.writer(allocator), "\\u{x:0>4}", .{c}) catch return s;
                } else {
                    result.append(allocator, c) catch return s;
                }
            },
        }
    }
    return result.toOwnedSlice(allocator) catch return s;
}

fn escapeXML(s: []const u8) []const u8 {
    // Check if string needs escaping
    var needs_escape = false;
    for (s) |c| {
        if (c == '<' or c == '>' or c == '&' or c == '"' or c == '\'') {
            needs_escape = true;
            break;
        }
    }

    if (!needs_escape) return s;

    // Allocate and escape
    // Note: This uses page_allocator for XML output lifetime
    // The escaped strings need to live for the duration of the output
    const allocator = std.heap.page_allocator;
    var result: std.ArrayList(u8) = .{};
    result.ensureTotalCapacity(allocator, s.len) catch return s;
    for (s) |c| {
        switch (c) {
            '<' => result.appendSlice(allocator, "&lt;") catch return s,
            '>' => result.appendSlice(allocator, "&gt;") catch return s,
            '&' => result.appendSlice(allocator, "&amp;") catch return s,
            '"' => result.appendSlice(allocator, "&quot;") catch return s,
            '\'' => result.appendSlice(allocator, "&apos;") catch return s,
            else => result.append(allocator, c) catch return s,
        }
    }
    return result.toOwnedSlice(allocator) catch return s;
}

pub const TestTask = struct {
    index: usize,
    result: ?TestResult = null,
    mutex: std.Thread.Mutex = .{},
};

pub fn runTestsParallel(allocator: std.mem.Allocator, test_indices: []const usize, max_workers: usize) ![]TestResult {
    if (test_indices.len == 0) return &[_]TestResult{};

    // Create task list
    const tasks = try allocator.alloc(TestTask, test_indices.len);
    defer allocator.free(tasks);

    for (tasks, 0..) |*task, i| {
        task.* = .{ .index = test_indices[i] };
    }

    // Create worker threads
    const worker_count = @min(max_workers, test_indices.len);
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    var next_task_idx: usize = 0;
    var completed_count: usize = 0;
    var task_mutex = std.Thread.Mutex{};

    const WorkerContext = struct {
        tasks_ptr: [*]TestTask,
        tasks_len: usize,
        next_idx: *usize,
        completed: *usize,
        mutex: *std.Thread.Mutex,
        allocator: std.mem.Allocator,
    };

    const workerFn = struct {
        fn run(ctx: WorkerContext) void {
            while (true) {
                // Get next task
                ctx.mutex.lock();
                const task_idx = ctx.next_idx.*;
                if (task_idx >= ctx.tasks_len) {
                    ctx.mutex.unlock();
                    break;
                }
                ctx.next_idx.* += 1;
                ctx.mutex.unlock();

                // Run the test
                const task = &ctx.tasks_ptr[task_idx];
                const result = runTestInProcess(ctx.allocator, task.index) catch |err| {
                    std.debug.print("Error running test {d}: {}\n", .{ task.index, err });
                    continue;
                };

                task.mutex.lock();
                task.result = result;
                task.mutex.unlock();

                // Update completed count
                ctx.mutex.lock();
                ctx.completed.* += 1;
                ctx.mutex.unlock();
            }
        }
    }.run;

    // Launch workers
    for (threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, workerFn, .{WorkerContext{
            .tasks_ptr = tasks.ptr,
            .tasks_len = tasks.len,
            .next_idx = &next_task_idx,
            .completed = &completed_count,
            .mutex = &task_mutex,
            .allocator = allocator,
        }});
        _ = i;
    }

    // Show progress while tests run
    const stdout = std.fs.File.stdout();
    const writer = stdout.deprecatedWriter();
    const start_time = std.time.milliTimestamp();
    var check_count: usize = 0;
    var last_check_count: usize = 0;

    // Print initial newline for test result markers
    try writer.print("\n", .{});

    while (true) {
        task_mutex.lock();
        const current = completed_count;
        task_mutex.unlock();

        if (current >= test_indices.len) break;

        // Count passed/failed for displaying markers
        var passed: usize = 0;
        var failed: usize = 0;
        for (0..tasks.len) |i| {
            tasks[i].mutex.lock();
            if (tasks[i].result) |r| {
                if (r.passed) {
                    passed += 1;
                } else {
                    failed += 1;
                }
            }
            tasks[i].mutex.unlock();
        }

        // Print new check/cross marks
        const total_checks = passed + failed;
        while (check_count < total_checks) {
            // Determine if this check is pass or fail
            const is_pass = check_count < passed;
            if (is_pass) {
                try writer.print("{s}{s}{s}", .{ Color.green, Icons.check, Color.reset });
            } else {
                try writer.print("{s}{s}{s}", .{ Color.red, Icons.cross, Color.reset });
            }
            check_count += 1;

            // Add newline every 100 marks to keep output manageable
            if (check_count % 100 == 0) {
                try writer.print("\n", .{});
            }
        }

        // Only update progress line if we printed new marks
        if (check_count != last_check_count) {
            const elapsed_ms = std.time.milliTimestamp() - start_time;
            const elapsed_sec = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
            const rate = if (elapsed_sec > 0) @as(f64, @floatFromInt(current)) / elapsed_sec else 0;

            try writer.print("  {s}[{d}/{d} - {d:.0} tests/sec]{s}", .{
                Color.dim,
                current,
                test_indices.len,
                rate,
                Color.reset,
            });
            last_check_count = check_count;
        }

        std.Thread.sleep(50 * std.time.ns_per_ms); // Update every 50ms for smoother output
    }

    try writer.print("\n", .{});

    // Wait for all workers
    for (threads) |thread| {
        thread.join();
    }

    // Collect results
    var results: std.ArrayList(TestResult) = .{};
    for (tasks) |task| {
        if (task.result) |result| {
            try results.append(allocator, result);
        }
    }

    return try results.toOwnedSlice(allocator);
}

pub fn printSlowestTests(writer: anytype, allocator: std.mem.Allocator, results: []TestResult, count: usize) !void {
    if (results.len == 0) return;

    // Create a copy for sorting
    var sorted: std.ArrayList(TestResult) = .{};
    defer sorted.deinit(allocator);

    for (results) |r| {
        try sorted.append(allocator, r);
    }

    // Sort by duration (descending)
    std.mem.sort(TestResult, sorted.items, {}, struct {
        fn lessThan(_: void, a: TestResult, b: TestResult) bool {
            return a.duration_ns > b.duration_ns;
        }
    }.lessThan);

    const display_count = @min(count, sorted.items.len);
    if (display_count == 0) return;

    try std.fmt.format(writer, "\n{s}─────────────────────────────────────────{s}\n", .{ Color.dim, Color.reset });
    try std.fmt.format(writer, " {s}Slowest Tests ({d}){s}\n", .{ Color.bold, display_count, Color.reset });
    try std.fmt.format(writer, "{s}─────────────────────────────────────────{s}\n\n", .{ Color.dim, Color.reset });

    for (sorted.items[0..display_count]) |t| {
        const icon = if (t.passed) Icons.check else Icons.cross;
        const color = if (t.passed) Color.green else Color.red;

        try std.fmt.format(writer, " {s}{s}{s} {s}{s}.{s}{s} ", .{
            color,
            icon,
            Color.reset,
            Color.dim,
            t.suite,
            t.test_name,
            Color.reset,
        });
        try formatDuration(writer, t.duration_ns);
        try std.fmt.format(writer, "\n", .{});
    }
}
