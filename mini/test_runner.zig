const std = @import("std");
const builtin = @import("builtin");
const utils = @import("test/utils.zig");

const Color = utils.Color;
const Icons = utils.Icons;
const TestResult = utils.TestResult;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout_file = std.fs.File.stdout();
    var stdout_buffer = try std.ArrayList(u8).initCapacity(allocator, 8192);
    defer stdout_buffer.deinit(allocator);
    const stdout = stdout_buffer.writer(allocator);

    var results = std.ArrayListUnmanaged(TestResult){};
    defer {
        for (results.items) |*result| {
            if (result.error_msg) |msg| {
                allocator.free(msg);
            }
        }
        results.deinit(allocator);
    }

    // Check for test filter from environment variable
    const test_filter = std.posix.getenv("TEST_FILTER");

    // Check for output format
    const output_format: utils.OutputFormat = blk: {
        if (std.posix.getenv("TEST_FORMAT")) |fmt| {
            if (std.mem.eql(u8, fmt, "json")) break :blk .json;
            if (std.mem.eql(u8, fmt, "junit")) break :blk .junit;
        }
        break :blk .pretty;
    };

    // Check for parallel execution (default ON, disable with TEST_SEQUENTIAL=1)
    const parallel = std.posix.getenv("TEST_SEQUENTIAL") == null;
    const max_workers = blk: {
        if (std.posix.getenv("TEST_WORKERS")) |workers_str| {
            const workers = std.fmt.parseInt(usize, workers_str, 10) catch 4;
            break :blk workers;
        }
        // Default to CPU count - each test runs an isolated EVM instance
        const cpu_count = std.Thread.getCpuCount() catch 4;
        break :blk cpu_count;
    };

    const total_tests = builtin.test_functions.len;
    const start_time = std.time.nanoTimestamp();

    // Check if output is a TTY
    const has_tty = stdout_file.isTty();

    // Only print header for pretty format
    if (output_format == .pretty) {
        try std.fmt.format(stdout, "\n", .{});
        try std.fmt.format(stdout, " {s}{s} RUN {s} {s}v0.15.1{s}\n", .{
            Color.bg_blue,
            Color.white,
            Color.reset,
            Color.gray,
            Color.reset,
        });
        try std.fmt.format(stdout, " {s}{s}~/guillotine{s}\n\n", .{
            Color.cyan,
            Icons.arrow,
            Color.reset,
        });
        try stdout_file.writeAll(stdout_buffer.items);
        stdout_buffer.clearRetainingCapacity();
    }

    // Collect test indices to run
    var test_indices = std.ArrayListUnmanaged(usize){};
    defer test_indices.deinit(allocator);

    for (builtin.test_functions, 0..) |t, i| {
        // Skip test if filter is set and test name doesn't match
        if (test_filter) |filter| {
            if (!utils.matchesFilter(t.name, filter)) {
                continue;
            }
        }
        try test_indices.append(allocator, i);
    }

    // Run tests (parallel or sequential)
    if (parallel and test_indices.items.len > 1) {
        // Parallel execution
        if (output_format == .pretty) {
            try stdout.print(" {s}Running {d} tests in parallel with {d} workers...{s}\n\n", .{
                Color.cyan,
                test_indices.items.len,
                max_workers,
                Color.reset,
            });
            try stdout_file.writeAll(stdout_buffer.items);
            stdout_buffer.clearRetainingCapacity();
        }

        const parallel_results = try utils.runTestsParallel(allocator, test_indices.items, max_workers);
        defer allocator.free(parallel_results);

        for (parallel_results) |result| {
            try results.append(allocator, result);
        }
    } else {
        // Sequential execution
        for (test_indices.items, 0..) |test_idx, i| {
            const t = builtin.test_functions[test_idx];
            const suite_name = utils.extractSuiteName(t.name);

            if (has_tty and output_format == .pretty) {
                try utils.printProgress(stdout, i + 1, test_indices.items.len, suite_name);
                try stdout_file.writeAll(stdout_buffer.items);
                stdout_buffer.clearRetainingCapacity();
            }

            const test_result = try utils.runTestInProcess(allocator, test_idx);
            try results.append(allocator, test_result);
        }

        if (has_tty and output_format == .pretty) {
            try utils.clearLine(stdout);
            try stdout_file.writeAll(stdout_buffer.items);
            stdout_buffer.clearRetainingCapacity();
        }
    }

    // Display results based on format
    const end_time = std.time.nanoTimestamp();
    const total_duration = @as(u64, @intCast(end_time - start_time));

    switch (output_format) {
        .json => {
            try utils.outputJSON(stdout, results.items, total_duration);
        },
        .junit => {
            try utils.outputJUnit(stdout, allocator, results.items, total_duration);
        },
        .pretty => {
            try utils.displayResults(stdout, allocator, results.items);
            try utils.printSlowestTests(stdout, allocator, results.items, 10);
            try printPrettySummary(stdout, results.items, total_duration, total_tests);
        },
    }

    try stdout_file.writeAll(stdout_buffer.items);
    stdout_buffer.clearRetainingCapacity();

    // Count results to determine exit code
    var failed_count: u32 = 0;
    for (results.items) |result| {
        if (!result.passed and !result.todo) {
            failed_count += 1;
        }
    }

    if (failed_count > 0) {
        return error.TestsFailed;
    }
}

fn printPrettySummary(writer: anytype, results: []TestResult, duration_ns: u64, total_tests: usize) !void {
    var passed_count: u32 = 0;
    var failed_count: u32 = 0;
    var todo_count: u32 = 0;

    for (results) |result| {
        if (result.todo) {
            todo_count += 1;
        } else if (result.passed) {
            passed_count += 1;
        } else {
            failed_count += 1;
        }
    }

    try writer.print("{s}⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯{s}\n", .{
        Color.dim,
        Color.reset,
    });

    // Test summary with icons
    if (failed_count > 0) {
        try writer.print(" {s}Test Files  {s}", .{
            Color.bold,
            Color.reset,
        });
        try writer.print("{s}1 failed{s} {s}({d}){s}\n", .{
            Color.red,
            Color.reset,
            Color.dim,
            total_tests,
            Color.reset,
        });

        try writer.print("      {s}Tests  {s}", .{
            Color.bold,
            Color.reset,
        });
        try writer.print("{s}{d} failed{s}", .{
            Color.red,
            failed_count,
            Color.reset,
        });
        if (passed_count > 0) {
            try writer.print(" {s}|{s} {s}{d} passed{s}", .{
                Color.dim,
                Color.reset,
                Color.green,
                passed_count,
                Color.reset,
            });
        }
        if (todo_count > 0) {
            try writer.print(" {s}|{s} {s}{d} todo{s}", .{
                Color.dim,
                Color.reset,
                Color.yellow,
                todo_count,
                Color.reset,
            });
        }
        try writer.print(" {s}({d}){s}\n", .{
            Color.dim,
            total_tests,
            Color.reset,
        });
    } else {
        try writer.print(" {s}Test Files  {s}", .{
            Color.bold,
            Color.reset,
        });
        try writer.print("{s}1 passed{s} {s}({d}){s}\n", .{
            Color.green,
            Color.reset,
            Color.dim,
            total_tests,
            Color.reset,
        });

        try writer.print("      {s}Tests  {s}", .{
            Color.bold,
            Color.reset,
        });
        if (todo_count > 0) {
            try writer.print("{s}{d} passed{s}", .{
                Color.green,
                passed_count,
                Color.reset,
            });
            try writer.print(" {s}|{s} {s}{d} todo{s}", .{
                Color.dim,
                Color.reset,
                Color.yellow,
                todo_count,
                Color.reset,
            });
            try writer.print(" {s}({d}){s}\n", .{
                Color.dim,
                total_tests,
                Color.reset,
            });
        } else {
            try writer.print("{s}{d} passed{s} {s}({d}){s}\n", .{
                Color.green,
                passed_count,
                Color.reset,
                Color.dim,
                total_tests,
                Color.reset,
            });
        }
    }

    // Duration with icon
    try writer.print("  {s}Start at  {s}", .{
        Color.bold,
        Color.reset,
    });
    const now_ms = std.time.milliTimestamp();
    const now_s = @divTrunc(now_ms, 1000);
    const hours: u32 = @intCast(@mod(@divTrunc(now_s, 3600) - 8, 24)); // PST
    const minutes: u32 = @intCast(@mod(@divTrunc(now_s, 60), 60));
    const seconds: u32 = @intCast(@mod(now_s, 60));
    try writer.print("{s}{d:0>2}:{d:0>2}:{d:0>2}{s}\n", .{
        Color.gray,
        hours,
        minutes,
        seconds,
        Color.reset,
    });

    try writer.print("   {s}Duration  {s}", .{
        Color.bold,
        Color.reset,
    });
    try utils.formatDuration(writer, duration_ns);
    try writer.print("\n\n", .{});
}
