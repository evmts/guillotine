//! Shared zero-dependency microbenchmark runner for Guillotine subsystem suites.
//!
//! Every subsystem benchmark compiles as a standalone ReleaseFast executable
//! that links ONLY its own Zig dependency closure so Smithers PACKAGE.ts
//! targets build and run incrementally when that subsystem changes.
const std = @import("std");
const builtin = @import("builtin");

pub const std_options: std.Options = .{ .log_level = .err };

pub const Stats = struct {
    median_ns: f64,
    mean_ns: f64,
    min_ns: u64,
    p95_ns: u64,
    ops_per_sec: f64,
    mb_per_sec: ?f64 = null,
};

pub const Row = struct {
    name: []const u8,
    suite: []const u8,
    operations_per_iter: u64,
    bytes_per_iter: u64 = 0,
    status: []const u8 = "failed",
    reason: ?[]const u8 = null,
    ns_per_op: ?f64 = null,
    statistics: ?Stats = null,
    checksum: ?u64 = null,
};

pub const Report = struct {
    schema_version: u32 = 1,
    kind: []const u8 = "micro",
    suite: []const u8,
    timestamp_unix: i64,
    compiler: []const u8 = builtin.zig_version_string,
    architecture: []const u8 = @tagName(builtin.cpu.arch),
    os: []const u8 = @tagName(builtin.os.tag),
    cpu: []const u8 = builtin.cpu.model.name,
    optimize: []const u8 = @tagName(builtin.mode),
    iterations: usize,
    warmup: usize,
    results: []const Row,
};

pub const CaseFn = *const fn (allocator: std.mem.Allocator) anyerror!u64;

pub const Case = struct {
    name: []const u8,
    operations: u64 = 1,
    bytes: u64 = 0,
    run: CaseFn,
};

pub const CliOptions = struct {
    json: ?[]const u8 = null,
    filter: []const u8 = "",
    iterations: usize = 60,
    warmup: usize = 10,
    help: bool = false,
};

pub fn parseCli(args: []const []const u8) !CliOptions {
    var opts = CliOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            continue;
        }
        const is_json = std.mem.eql(u8, arg, "--json");
        const is_filter = std.mem.eql(u8, arg, "--filter");
        const is_iters = std.mem.eql(u8, arg, "--iterations");
        const is_warmup = std.mem.eql(u8, arg, "--warmup");
        if (!is_json and !is_filter and !is_iters and !is_warmup) return error.UnknownArgument;
        i += 1;
        if (i == args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingArgument;
        const val = args[i];
        if (is_json) {
            if (val.len == 0) return error.EmptyPath;
            opts.json = val;
        } else if (is_filter) {
            opts.filter = val;
        } else {
            const count = std.fmt.parseUnsigned(usize, val, 10) catch return error.InvalidCount;
            if (count > 1_000_000 or (is_iters and count == 0)) return error.InvalidCount;
            if (is_iters) opts.iterations = count;
            if (is_warmup) opts.warmup = count;
        }
    }
    return opts;
}

pub fn matches(name: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return true;
    if (pattern.len > name.len) return false;
    for (0..name.len - pattern.len + 1) |idx| {
        if (std.ascii.eqlIgnoreCase(name[idx..][0..pattern.len], pattern)) return true;
    }
    return false;
}

pub fn summarize(samples: []u64, operations: u64, bytes: u64) !Stats {
    if (samples.len == 0 or operations == 0) return error.EmptySamples;
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(samples.len));
    if (mean == 0) return error.TimerResolution;
    const mid = samples.len / 2;
    const median = if (samples.len % 2 == 0)
        (@as(f64, @floatFromInt(samples[mid - 1])) + @as(f64, @floatFromInt(samples[mid]))) / 2.0
    else
        @as(f64, @floatFromInt(samples[mid]));
    const p95 = samples[(samples.len * 95 + 99) / 100 - 1];
    const ops_per_sec = @as(f64, @floatFromInt(operations)) * 1e9 / mean;
    const mb_per_sec: ?f64 = if (bytes > 0)
        (@as(f64, @floatFromInt(bytes)) * 1e9 / mean) / (1024.0 * 1024.0)
    else
        null;
    return .{
        .median_ns = median,
        .mean_ns = mean,
        .min_ns = samples[0],
        .p95_ns = p95,
        .ops_per_sec = ops_per_sec,
        .mb_per_sec = mb_per_sec,
    };
}

pub fn runSuite(suite_name: []const u8, cases: []const Case) void {
    runSuiteInner(suite_name, cases) catch |err| {
        var buf: [4096]u8 = undefined;
        var stderr = std.fs.File.stderr().writer(&buf);
        stderr.interface.print("bench-{s}: {s}\n", .{ suite_name, @errorName(err) }) catch std.process.exit(2);
        stderr.interface.flush() catch std.process.exit(2);
        std.process.exit(1);
    };
}

fn runSuiteInner(suite_name: []const u8, cases: []const Case) !void {
    const allocator = std.heap.smp_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const opts = try parseCli(args[1..]);

    var out_buf: [16384]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&out_buf);
    const w = &stdout.interface;

    if (opts.help) {
        try w.print(
            "Usage: bench-{s} [--json <path>] [--filter <substring>] [--iterations <N>] [--warmup <N>] [--help]\n",
            .{suite_name},
        );
        try w.flush();
        return;
    }

    if (builtin.mode != .ReleaseFast) return error.ReleaseFastRequired;

    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(allocator);

    const samples = try allocator.alloc(u64, opts.iterations);
    defer allocator.free(samples);

    var matched: usize = 0;
    var failed = false;

    for (cases) |c| {
        if (!matches(c.name, opts.filter)) continue;
        matched += 1;
        var row = Row{
            .name = c.name,
            .suite = suite_name,
            .operations_per_iter = c.operations,
            .bytes_per_iter = c.bytes,
        };
        measureCase(allocator, c, opts, samples, &row) catch |err| {
            row.status = "failed";
            row.reason = @errorName(err);
            failed = true;
        };
        try rows.append(allocator, row);
    }

    if (matched == 0) return error.NoMatchingBenchmarks;

    try writeMarkdown(w, suite_name, rows.items);
    try w.flush();

    if (opts.json) |json_path| {
        try writeJson(json_path, .{
            .suite = suite_name,
            .timestamp_unix = std.time.timestamp(),
            .iterations = opts.iterations,
            .warmup = opts.warmup,
            .results = rows.items,
        });
    }

    if (failed) return error.BenchmarkFailed;
}

fn measureCase(
    allocator: std.mem.Allocator,
    c: Case,
    opts: CliOptions,
    samples: []u64,
    row: *Row,
) !void {
    // Preflight correctness verification
    const expected = try c.run(allocator);
    std.mem.doNotOptimizeAway(expected);

    for (0..opts.warmup) |_| {
        const res = try c.run(allocator);
        std.mem.doNotOptimizeAway(res);
        if (res != expected) return error.NonDeterministicResult;
    }

    var timer = try std.time.Timer.start();
    for (samples) |*sample| {
        timer.reset();
        const res = try c.run(allocator);
        const elapsed = timer.read();
        std.mem.doNotOptimizeAway(res);
        if (res != expected) return error.NonDeterministicResult;
        sample.* = elapsed;
    }

    const s = try summarize(samples, c.operations, c.bytes);
    row.statistics = s;
    row.ns_per_op = s.median_ns / @as(f64, @floatFromInt(c.operations));
    row.checksum = expected;
    row.status = "ok";
}

fn writeMarkdown(w: *std.Io.Writer, suite_name: []const u8, rows: []const Row) !void {
    try w.print("### Suite: `{s}`\n\n", .{suite_name});
    try w.writeAll("| Benchmark | ns/op | Median ns | Mean ns | p95 ns | ops/sec | Status |\n");
    try w.writeAll("|:--|:--|--:|--:|--:|--:|:--|\n");
    for (rows) |row| {
        if (row.statistics) |s| {
            try w.print("| {s} | {d:.2} | {d:.1} | {d:.1} | {d} | {d:.0} | {s} |\n", .{
                row.name,
                row.ns_per_op.?,
                s.median_ns,
                s.mean_ns,
                s.p95_ns,
                s.ops_per_sec,
                row.status,
            });
        } else {
            try w.print("| {s} | — | — | — | — | — | {s}: {s} |\n", .{
                row.name,
                row.status,
                row.reason orelse "unknown",
            });
        }
    }
}

pub fn writeJson(path: []const u8, data: Report) !void {
    var buffer: [16384]u8 = undefined;
    var file = try std.fs.cwd().atomicFile(path, .{ .write_buffer = &buffer, .make_path = true });
    defer file.deinit();
    try std.json.Stringify.value(data, .{ .whitespace = .indent_2 }, &file.file_writer.interface);
    try file.file_writer.interface.writeByte('\n');
    try file.finish();
}

test "micro summarize and cli parsing" {
    var samples = [_]u64{ 40, 10, 30, 20 };
    const s = try summarize(&samples, 10, 1024);
    try std.testing.expectEqual(@as(f64, 25.0), s.median_ns);
    try std.testing.expectEqual(@as(u64, 10), s.min_ns);
    try std.testing.expectEqual(@as(u64, 40), s.p95_ns);
    try std.testing.expect(s.mb_per_sec != null);

    const opts = try parseCli(&.{ "--iterations", "5", "--warmup", "2", "--filter", "push", "--json", "out.json" });
    try std.testing.expectEqual(@as(usize, 5), opts.iterations);
    try std.testing.expectEqual(@as(usize, 2), opts.warmup);
    try std.testing.expectEqualStrings("push", opts.filter);
    try std.testing.expectEqualStrings("out.json", opts.json.?);
    try std.testing.expect(matches("stack/PUSH_unsafe", opts.filter));
}
