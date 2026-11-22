//! In-repository EVM benchmarks. No network, Solidity compiler, zbench, or
//! external evm-benchmarks checkout is used at runtime.
const std = @import("std");
const builtin = @import("builtin");
const evm = @import("guillotine");
const loop_evm = @import("guillotine_loop");
const build = @import("bench_options");
const cli = @import("cli.zig");
const workloads = @import("workloads.zig");
const engine = @import("engine.zig");
const report = @import("report.zig");

// Suppress routine core warnings during measurements; execution errors remain visible.
pub const std_options: std.Options = .{ .log_level = .err };

pub fn main() void {
    run() catch |err| {
        var buffer: [4096]u8 = undefined;
        var stderr = std.fs.File.stderr().writer(&buffer);
        stderr.interface.print("guillotine-bench: {s} (use --help for usage)\n", .{@errorName(err)}) catch std.process.exit(2);
        stderr.interface.flush() catch std.process.exit(2);
        std.process.exit(1);
    };
}

fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const options = try cli.parse(args[1..]);
    var buffer: [16384]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buffer);
    const writer = &stdout.interface;
    if (options.help) {
        try writer.writeAll(cli.usage);
        try writer.flush();
        return;
    }
    if (builtin.mode != .ReleaseFast) return error.ReleaseFastRequired;
    const suite = try workloads.build(allocator);
    var rows: std.ArrayList(report.Row) = .empty;
    defer rows.deinit(allocator);
    var matched: usize = 0;
    for (suite) |workload| {
        if (!cli.matches(workload.name, options.filter)) continue;
        matched += 1;
        try rows.append(allocator, execute(evm, true, false, workload, options));
        if (options.compare) {
            try rows.append(allocator, execute(evm, false, false, workload, options));
            if (comptime build.loop_available) {
                try rows.append(allocator, execute(loop_evm, false, true, workload, options));
            } else {
                var row = base(workload, false, true);
                row.status = "unavailable";
                row.reason = "a module with verified disable_tailcall_dispatch support was not supplied";
                try rows.append(allocator, row);
            }
        }
    }
    if (matched == 0) return error.NoMatchingBenchmarks;
    try report.markdown(writer, rows.items);
    try writer.flush();
    try report.writeJson(options.json, .{ .timestamp_unix = std.time.timestamp(), .hardfork = build.hardfork, .gas_limit = engine.gas_limit, .iterations = options.iterations, .warmup = options.warmup, .results = rows.items });
    var failed = false;
    var unavailable = false;
    for (rows.items) |row| {
        failed = failed or std.mem.eql(u8, row.status, "failed");
        unavailable = unavailable or std.mem.eql(u8, row.status, "unavailable");
    }
    if (failed) return error.BenchmarkFailed;
    if (unavailable) return error.BenchmarkUnavailable;
}

fn base(workload: workloads.Workload, fusion: bool, loop: bool) report.Row {
    return .{
        .name = workload.name,
        .category = workload.category,
        .mode = if (loop) "loop" else if (fusion) "tailcall+fusions" else "tailcall-no-fusions",
        .enable_fusion = fusion,
        .disable_tailcall_dispatch = loop,
        .operations_per_call = workload.operations,
    };
}

fn execute(comptime implementation: type, comptime fusion: bool, comptime loop: bool, workload: workloads.Workload, options: cli.Options) report.Row {
    var row = base(workload, fusion, loop);
    const Runner = engine.Runner(implementation, fusion);
    if (Runner.available(workload)) |reason| {
        row.status = "unavailable";
        row.reason = reason;
        return row;
    }
    // Use a reclaiming allocator: large iteration counts must not retain
    // every owned call result as an arena would.
    var runner = Runner.init(std.heap.smp_allocator, workload, &row) catch |err| {
        if (row.stage == null) row.stage = "setup";
        row.reason = @errorName(err);
        return row;
    };
    defer runner.deinit(workload);
    runner.measure(workload, options, &row) catch |err| {
        row.stage = runner.stage;
        row.reason = @errorName(err);
    };
    return row;
}
