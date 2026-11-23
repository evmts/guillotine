const std = @import("std");
const builtin = @import("builtin");
const stats = @import("stats.zig");

pub const Row = struct {
    name: []const u8,
    category: []const u8,
    mode: []const u8,
    enable_fusion: bool,
    disable_tailcall_dispatch: bool,
    operations_per_call: u32,
    status: []const u8 = "failed",
    stage: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    sample_index: ?usize = null,
    observed_gas_left: ?u64 = null,
    observed_output_bytes: ?usize = null,
    gas_used: ?u64 = null,
    ns_per_op: ?f64 = null,
    statistics: ?stats.Stats = null,
};

pub const Report = struct {
    schema_version: u32 = 1,
    timestamp_unix: i64,
    compiler: []const u8 = builtin.zig_version_string,
    architecture: []const u8 = @tagName(builtin.cpu.arch),
    os: []const u8 = @tagName(builtin.os.tag),
    cpu: []const u8 = builtin.cpu.model.name,
    optimize: []const u8 = @tagName(builtin.mode),
    hardfork: []const u8 = "OSAKA",
    gas_checks: bool = true,
    tracing: bool = false,
    log_level: []const u8 = "err",
    setup_enable_fusion: bool = false,
    instruction_limit: u32 = 300_000_000,
    gas_limit: u64 = 100_000_000,
    iterations: usize,
    warmup: usize,
    timing: []const u8 = "simulate including state overlay, dispatch analysis/construction and owned result copying; setup, validation and result cleanup excluded",
    gas_accounting: []const u8 = "gas_limit - CallResult.gas_left, including intrinsic gas charged by the public API and its applied refunds",
    rates: []const u8 = "ops/sec = operations_per_call * 1e9 / mean_ns; MGas/sec = gas_used * 1e3 / mean_ns; ns_per_op = median_ns / operations_per_call",
    results: []const Row,
};

/// Atomic replacement: preserve the previous report if writing is interrupted.
pub fn writeJson(path: []const u8, data: Report) !void {
    var buffer: [16384]u8 = undefined;
    var file = try std.fs.cwd().atomicFile(path, .{ .write_buffer = &buffer, .make_path = true });
    defer file.deinit();
    try std.json.Stringify.value(data, .{ .whitespace = .indent_2 }, &file.file_writer.interface);
    try file.file_writer.interface.writeByte('\n');
    try file.finish();
}

pub fn markdown(writer: *std.Io.Writer, rows: []const Row) !void {
    try writer.writeAll("| Benchmark | Dispatch | ns/op | Median ns/call | Mean ns/call | p95 ns/call | ops/sec | Gas/call | MGas/sec | Status |\n");
    try writer.writeAll("|:--|:--|--:|--:|--:|--:|--:|--:|--:|:--|\n");
    for (rows) |row| {
        if (row.statistics) |value| {
            try writer.print("| {s} | {s} | {d:.2} | {d:.2} | {d:.2} | {d} | {d:.2} | {d} | {d:.2} | {s} |\n", .{
                row.name,          row.mode,       row.ns_per_op.?,    value.median_ns, value.mean_ns, value.p95_ns,
                value.ops_per_sec, row.gas_used.?, value.mgas_per_sec, row.status,
            });
        } else {
            try writer.print("| {s} | {s} | — | — | — | — | — | — | — | {s}: {s} |\n", .{ row.name, row.mode, row.status, row.reason orelse "unknown failure" });
        }
    }
}

test "JSON keeps unavailable timings null and escapes names" {
    const allocator = std.testing.allocator;
    const rows = [_]Row{.{
        .name = "quoted\"name",
        .category = "opcode",
        .mode = "tailcall+fusions",
        .enable_fusion = true,
        .disable_tailcall_dispatch = false,
        .operations_per_call = 128,
        .status = "unavailable",
        .reason = "missing opcode",
    }};
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(Report{ .timestamp_unix = 0, .iterations = 2, .warmup = 0, .results = &rows }, .{}, &output.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, output.written(), .{});
    defer parsed.deinit();
    const row = parsed.value.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("quoted\"name", row.get("name").?.string);
    try std.testing.expect(row.get("statistics").? == .null);
    try std.testing.expect(row.get("gas_used").? == .null);
    try std.testing.expectEqualStrings("unavailable", row.get("status").?.string);
}

test "Markdown carries measured rates and explicit unavailable reasons" {
    var samples = [_]u64{ 10, 20 };
    const rows = [_]Row{
        .{ .name = "opcode/ADD", .category = "opcode", .mode = "tailcall+fusions", .enable_fusion = true, .disable_tailcall_dispatch = false, .operations_per_call = 128, .status = "ok", .gas_used = 100, .ns_per_op = 15.0 / 128.0, .statistics = try stats.summarize(&samples, 128, 100) },
        .{ .name = "opcode/CLZ", .category = "opcode", .mode = "tailcall+fusions", .enable_fusion = true, .disable_tailcall_dispatch = false, .operations_per_call = 128, .status = "unavailable", .reason = "handler absent" },
    };
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try markdown(&output.writer, &rows);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "p95 ns/call") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "| 100 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "unavailable: handler absent") != null);
}

test "atomic JSON report is readable and can be replaced" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(parent);
    const path = try std.fs.path.join(std.testing.allocator, &.{ parent, "nested", "report.json" });
    defer std.testing.allocator.free(path);
    try writeJson(path, .{ .timestamp_unix = 1, .iterations = 1, .warmup = 0, .results = &.{} });
    try writeJson(path, .{ .timestamp_unix = 2, .iterations = 2, .warmup = 0, .results = &.{} });
    const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 16384);
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("timestamp_unix").?.integer);
}
