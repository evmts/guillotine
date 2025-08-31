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
use_call2: bool,
show_output: bool,
js_runtime: []const u8,
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

pub fn init(allocator: std.mem.Allocator, evm_name: []const u8, num_runs: u32, internal_runs: u32, js_runs: u32, js_internal_runs: u32, snailtracer_internal_runs: u32, js_snailtracer_internal_runs: u32, include_all_cases: bool, use_next: bool, use_call2: bool, show_output: bool, js_runtime: []const u8) !Orchestrator {
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
        .use_call2 = use_call2,
        .show_output = show_output,
        .js_runtime = js_runtime,
        .test_cases = &[_]TestCase{},
        .results = std.ArrayList(BenchmarkResult).empty,
    };
}

fn getProjectRoot(allocator: std.mem.Allocator) ![]const u8 {
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = try std.fs.selfExeDirPath(&exe_dir_buf);

    // Helper to get parent directory slice without allocating
    const parentOf = struct {
        fn get(path: []const u8) []const u8 {
            if (std.mem.lastIndexOfScalar(u8, path, std.fs.path.sep)) |idx| {
                if (idx == 0) return path[0..1];
                return path[0..idx];
            }
            return path;
        }
    };

    // Try candidates: exe_dir, parent, grandparent, cwd, cwd parent
    var candidates: [5][]const u8 = .{ exe_dir, parentOf.get(exe_dir), parentOf.get(parentOf.get(exe_dir)), "", "" };

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.cwd().realpathZ(".", &cwd_buf)) |cwd_path| {
        candidates[3] = cwd_path;
        candidates[4] = parentOf.get(cwd_path);
    } else |_| {}

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (candidates) |cand| {
        if (cand.len == 0) continue;
        const build_path = std.fmt.bufPrint(&path_buf, "{s}{c}build.zig", .{ cand, std.fs.path.sep }) catch continue;
        if (std.fs.openFileAbsolute(build_path, .{})) |f| {
            f.close();
            // Return owned copy of the candidate path
            return try allocator.dupe(u8, cand);
        } else |_| {}
    }

    // Fallback: assume two levels up from exe_dir
    const fallback = parentOf.get(parentOf.get(exe_dir));
    return try allocator.dupe(u8, fallback);
}

pub fn runDifferentialTrace(self: *Orchestrator, test_case: TestCase, output_dir: []const u8) !void {
    print("\n=== Running differential trace for {s} ===\n", .{test_case.name});

    // Create output directory
    try std.fs.cwd().makePath(output_dir);

    // Read calldata
    const calldata_file = try std.fs.cwd().openFile(test_case.calldata_path, .{});
    defer calldata_file.close();

    const calldata_hex = try calldata_file.readToEndAlloc(self.allocator, 1024 * 1024);
    defer self.allocator.free(calldata_hex);

    const trimmed_calldata = std.mem.trim(u8, calldata_hex, " \t\n\r");

    // Run REVM with tracing
    const revm_trace_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}_revm_trace.json", .{ output_dir, test_case.name });
    defer self.allocator.free(revm_trace_path);

    const project_root = try getProjectRoot(self.allocator);
    defer self.allocator.free(project_root);

    const revm_runner_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "bench", "official", "evms", "revm", "target", "release", "revm-runner" });
    defer self.allocator.free(revm_runner_path);

    var revm_argv = std.ArrayList([]const u8).empty;
    defer revm_argv.deinit(self.allocator);
    try revm_argv.appendSlice(self.allocator, &[_][]const u8{
        revm_runner_path,
        "--contract-code-path",
        test_case.bytecode_path,
        "--calldata",
        trimmed_calldata,
        "--num-runs",
        "1",
        "--trace",
        revm_trace_path,
    });

    const revm_result = try std.process.Child.run(.{
        .allocator = self.allocator,
        .argv = revm_argv.items,
    });
    defer self.allocator.free(revm_result.stdout);
    defer self.allocator.free(revm_result.stderr);

    if (revm_result.term.Exited != 0) {
        print("REVM execution failed:\n{s}", .{revm_result.stderr});
        return error.RevmExecutionFailed;
    }

    // Run Zig with tracing
    const zig_trace_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}_zig_trace.json", .{ output_dir, test_case.name });
    defer self.allocator.free(zig_trace_path);

    const zig_runner_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "zig-out", "bin", "evm-runner" });
    defer self.allocator.free(zig_runner_path);

    var zig_argv = std.ArrayList([]const u8).empty;
    defer zig_argv.deinit(self.allocator);
    try zig_argv.appendSlice(self.allocator, &[_][]const u8{
        zig_runner_path,
        "--contract-code-path",
        test_case.bytecode_path,
        "--calldata",
        trimmed_calldata,
        "--num-runs",
        "1",
        "--trace",
        zig_trace_path,
    });
    if (self.use_next) try zig_argv.append(self.allocator, "--next");
    // No need for --call2 flag as we're using the call2 runner binary directly

    print("Running Zig command: ", .{});
    for (zig_argv.items) |arg| {
        print("{s} ", .{arg});
    }
    print("\n", .{});

    const zig_result = try std.process.Child.run(.{
        .allocator = self.allocator,
        .argv = zig_argv.items,
    });
    defer self.allocator.free(zig_result.stdout);
    defer self.allocator.free(zig_result.stderr);

    if (zig_result.term.Exited != 0) {
        print("Zig execution failed:\n{s}", .{zig_result.stderr});
        return error.ZigExecutionFailed;
    }

    if (zig_result.stdout.len > 0) {
        print("Zig stdout: {s}\n", .{zig_result.stdout});
    }

    // Check if trace files exist
    const zig_trace_stat = std.fs.cwd().statFile(zig_trace_path) catch |err| {
        print("Failed to stat Zig trace file: {}\n", .{err});
        return err;
    };
    print("Zig trace file size: {} bytes\n", .{zig_trace_stat.size});

    // Compare traces
    print("\nTraces saved to:\n", .{});
    print("  REVM: {s}\n", .{revm_trace_path});
    print("  Zig:  {s}\n", .{zig_trace_path});

    // Parse and compare traces to find divergence
    const divergence = try self.findTraceDivergence(revm_trace_path, zig_trace_path);
    if (divergence) |div| {
        print("\n🔍 Divergence found at step {d}:\n", .{div.step});
        print("  REVM: PC={d}, Op=0x{X:0>2} ({s})\n", .{ div.revm_pc, div.revm_op, self.getOpcodeName(div.revm_op) });
        print("  Zig:  PC={d}, Op=0x{X:0>2} ({s})\n", .{ div.zig_pc, div.zig_op, self.getOpcodeName(div.zig_op) });

        // Show context around divergence
        try self.showDivergenceContext(revm_trace_path, zig_trace_path, div.step);

        const divergence_file = try std.fmt.allocPrint(self.allocator, "{s}/{s}_divergence.txt", .{ output_dir, test_case.name });
        defer self.allocator.free(divergence_file);

        const file = try std.fs.cwd().createFile(divergence_file, .{});
        defer file.close();

        // Write detailed divergence report with context
        var writer_buffer: [1024]u8 = undefined;
        var file_writer = file.writer(&writer_buffer);
        try self.writeDivergenceReport(&file_writer.interface, revm_trace_path, zig_trace_path, div);

        print("  Divergence details saved to: {s}\n", .{divergence_file});
    } else {
        print("\n✅ Traces match - no divergence found\n", .{});
    }
}

const TraceDivergence = struct {
    step: usize,
    revm_pc: usize,
    revm_op: u8,
    zig_pc: usize,
    zig_op: u8,
};

const TraceEntry = struct {
    pc: usize,
    op: u8,
    gas: []const u8,
    stack_size: usize,
};

fn findTraceDivergence(self: *Orchestrator, revm_trace_path: []const u8, zig_trace_path: []const u8) !?TraceDivergence {
    const revm_file = try std.fs.cwd().openFile(revm_trace_path, .{});
    defer revm_file.close();

    const zig_file = try std.fs.cwd().openFile(zig_trace_path, .{});
    defer zig_file.close();

    // TODO: Readers disabled - fix API for Zig 0.15.1
    // Files are still used by defer close() calls

    var step: usize = 0;

    while (true) : (step += 1) {
        // TODO: Fix reader API for Zig 0.15.1 - temporarily disabled
        const revm_line: ?[]u8 = null;
        const zig_line: ?[]u8 = null;

        if (revm_line == null and zig_line == null) break;

        if (revm_line == null or zig_line == null) {
            // One trace ended before the other
            return TraceDivergence{
                .step = step,
                .revm_pc = 0,
                .revm_op = 0,
                .zig_pc = 0,
                .zig_op = 0,
            };
        }

        // Parse PC and opcode from JSON lines
        const revm_pc = self.extractPc(revm_line.?) orelse {
            // REVM might have summary lines, check if Zig line is valid
            if (self.extractPc(zig_line.?) != null) {
                // REVM trace ended but Zig continues
                return TraceDivergence{
                    .step = step,
                    .revm_pc = 0,
                    .revm_op = 0,
                    .zig_pc = self.extractPc(zig_line.?) orelse 0,
                    .zig_op = self.extractOp(zig_line.?) orelse 0,
                };
            }
            continue;
        };
        const revm_op = self.extractOp(revm_line.?) orelse continue;
        const zig_pc = self.extractPc(zig_line.?) orelse {
            // Zig trace ended but REVM continues
            return TraceDivergence{
                .step = step,
                .revm_pc = revm_pc,
                .revm_op = revm_op,
                .zig_pc = 0,
                .zig_op = 0,
            };
        };
        const zig_op = self.extractOp(zig_line.?) orelse continue;

        if (revm_pc != zig_pc or revm_op != zig_op) {
            return TraceDivergence{
                .step = step,
                .revm_pc = revm_pc,
                .revm_op = revm_op,
                .zig_pc = zig_pc,
                .zig_op = zig_op,
            };
        }
    }

    return null;
}

fn extractPc(self: *Orchestrator, json_line: []const u8) ?usize {
    _ = self;
    if (std.mem.indexOf(u8, json_line, "\"pc\":")) |pc_pos| {
        const start = pc_pos + 5;
        if (std.mem.indexOfPos(u8, json_line, start, ",")) |end| {
            const pc_str = std.mem.trim(u8, json_line[start..end], " ");
            return std.fmt.parseInt(usize, pc_str, 10) catch null;
        }
    }
    return null;
}

fn extractOp(self: *Orchestrator, json_line: []const u8) ?u8 {
    _ = self;
    if (std.mem.indexOf(u8, json_line, "\"op\":")) |op_pos| {
        const start = op_pos + 5;
        if (std.mem.indexOfPos(u8, json_line, start, ",")) |end| {
            const op_str = std.mem.trim(u8, json_line[start..end], " ");
            return std.fmt.parseInt(u8, op_str, 10) catch null;
        }
    }
    return null;
}

fn parseTraceEntry(self: *Orchestrator, json_line: []const u8) ?TraceEntry {
    // Skip non-trace lines (like summary lines)
    if (std.mem.indexOf(u8, json_line, "\"pc\":") == null) return null;

    const pc = self.extractPc(json_line) orelse return null;
    const op = self.extractOp(json_line) orelse return null;

    // Extract gas (as string for display)
    var gas: []const u8 = "0x0";
    if (std.mem.indexOf(u8, json_line, "\"gas\":\"")) |gas_pos| {
        const start = gas_pos + 7;
        if (std.mem.indexOfPos(u8, json_line, start, "\"")) |end| {
            gas = json_line[start..end];
        }
    }

    // Extract stack size
    var stack_size: usize = 0;
    if (std.mem.indexOf(u8, json_line, "\"stack\":[")) |stack_pos| {
        var count: usize = 0;
        var pos = stack_pos + 9;
        if (json_line[pos] != ']') {
            count = 1;
            while (pos < json_line.len) : (pos += 1) {
                if (json_line[pos] == ',') count += 1;
                if (json_line[pos] == ']') break;
            }
        }
        stack_size = count;
    }

    return TraceEntry{
        .pc = pc,
        .op = op,
        .gas = gas,
        .stack_size = stack_size,
    };
}

fn showDivergenceContext(self: *Orchestrator, revm_trace_path: []const u8, zig_trace_path: []const u8, divergence_step: usize) !void {
    const context_size = 10;
    const start_step = if (divergence_step > context_size) divergence_step - context_size else 0;
    const end_step = divergence_step + context_size;

    print("\n=== Execution Context (10 steps before and after divergence) ===\n\n", .{});

    // Read REVM context
    print("REVM Trace:\n", .{});
    print("Step    PC    Op        Opcode         Gas           Stack\n", .{});
    print("----  -----  ----  --------------  -------------  -------\n", .{});

    const revm_entries = try self.readTraceContext(revm_trace_path, start_step, end_step, divergence_step);
    defer self.allocator.free(revm_entries);

    for (revm_entries, start_step..) |entry_opt, step| {
        if (entry_opt) |entry| {
            const marker = if (step == divergence_step) " <--" else "";
            print("{d:4}  {d:5}  0x{X:0>2}  {s:<14}  {s:<13}  [{d}]{s}\n", .{
                step,
                entry.pc,
                entry.op,
                self.getOpcodeName(entry.op),
                entry.gas,
                entry.stack_size,
                marker,
            });
        } else if (step == divergence_step) {
            print("{d:4}  [REVM trace ended]{s}\n", .{ step, " <--" });
        }
    }

    print("\nZig Trace:\n", .{});
    print("Step    PC    Op        Opcode         Gas           Stack\n", .{});
    print("----  -----  ----  --------------  -------------  -------\n", .{});

    const zig_entries = try self.readTraceContext(zig_trace_path, start_step, end_step, divergence_step);
    defer self.allocator.free(zig_entries);

    for (zig_entries, start_step..) |entry_opt, step| {
        if (entry_opt) |entry| {
            const marker = if (step == divergence_step) " <--" else "";
            print("{d:4}  {d:5}  0x{X:0>2}  {s:<14}  {s:<13}  [{d}]{s}\n", .{
                step,
                entry.pc,
                entry.op,
                self.getOpcodeName(entry.op),
                entry.gas,
                entry.stack_size,
                marker,
            });
        } else if (step == divergence_step) {
            print("{d:4}  [Zig trace ended]{s}\n", .{ step, " <--" });
        }
    }

    print("\n================================================================\n", .{});
}

fn readTraceContext(self: *Orchestrator, trace_path: []const u8, start_step: usize, end_step: usize, divergence_step: usize) ![]?TraceEntry {
    _ = divergence_step;

    const file = try std.fs.cwd().openFile(trace_path, .{});
    defer file.close();

    var buffer: [1024]u8 = undefined;
    const reader = file.reader(&buffer);
    const line_buf: [16384]u8 = undefined;

    const num_entries = end_step - start_step + 1;
    var entries = try self.allocator.alloc(?TraceEntry, num_entries);
    for (entries) |*e| e.* = null;

    var current_step: usize = 0;
    // TODO: Fix reader API for Zig 0.15.1 - temporarily return no results
    _ = reader;
    _ = line_buf;
    if (false) {
        // This code is disabled until reader API is fixed
        const line: []u8 = undefined;

        if (current_step >= start_step and current_step <= end_step) {
            if (self.parseTraceEntry(line)) |entry| {
                entries[current_step - start_step] = entry;
            }
        }

        // Only count lines that are actual trace entries
        if (std.mem.indexOf(u8, line, "\"pc\":") != null) {
            current_step += 1;
        }
    }

    return entries;
}

fn writeDivergenceReport(self: *Orchestrator, writer: anytype, revm_trace_path: []const u8, zig_trace_path: []const u8, div: TraceDivergence) !void {
    try writer.print("Divergence Analysis Report\n", .{});
    try writer.print("=========================\n\n", .{});

    try writer.print("Divergence at step {d}:\n", .{div.step});
    try writer.print("REVM: PC={d}, Op=0x{X:0>2} ({s})\n", .{ div.revm_pc, div.revm_op, self.getOpcodeName(div.revm_op) });
    try writer.print("Zig:  PC={d}, Op=0x{X:0>2} ({s})\n\n", .{ div.zig_pc, div.zig_op, self.getOpcodeName(div.zig_op) });

    const context_size = 10;
    const start_step = if (div.step > context_size) div.step - context_size else 0;
    const end_step = div.step + context_size;

    try writer.print("Execution Context (10 steps before and after divergence):\n", .{});
    try writer.print("========================================================\n\n", .{});

    // Write REVM context
    try writer.print("REVM Trace:\n", .{});
    try writer.print("Step    PC    Op        Opcode         Gas           Stack\n", .{});
    try writer.print("----  -----  ----  --------------  -------------  -------\n", .{});

    const revm_entries = try self.readTraceContext(revm_trace_path, start_step, end_step, div.step);
    defer self.allocator.free(revm_entries);

    for (revm_entries, start_step..) |entry_opt, step| {
        if (entry_opt) |entry| {
            const marker = if (step == div.step) " <-- DIVERGENCE" else "";
            try writer.print("{d:4}  {d:5}  0x{X:0>2}  {s:<14}  {s:<13}  [{d}]{s}\n", .{
                step,
                entry.pc,
                entry.op,
                self.getOpcodeName(entry.op),
                entry.gas,
                entry.stack_size,
                marker,
            });
        } else if (step == div.step) {
            try writer.print("{d:4}  [REVM trace ended]{s}\n", .{ step, " <-- DIVERGENCE" });
        }
    }

    try writer.print("\nZig Trace:\n", .{});
    try writer.print("Step    PC    Op        Opcode         Gas           Stack\n", .{});
    try writer.print("----  -----  ----  --------------  -------------  -------\n", .{});

    const zig_entries = try self.readTraceContext(zig_trace_path, start_step, end_step, div.step);
    defer self.allocator.free(zig_entries);

    for (zig_entries, start_step..) |entry_opt, step| {
        if (entry_opt) |entry| {
            const marker = if (step == div.step) " <-- DIVERGENCE" else "";
            try writer.print("{d:4}  {d:5}  0x{X:0>2}  {s:<14}  {s:<13}  [{d}]{s}\n", .{
                step,
                entry.pc,
                entry.op,
                self.getOpcodeName(entry.op),
                entry.gas,
                entry.stack_size,
                marker,
            });
        } else if (step == div.step) {
            try writer.print("{d:4}  [Zig trace ended]{s}\n", .{ step, " <-- DIVERGENCE" });
        }
    }
}

fn getOpcodeName(self: *Orchestrator, opcode: u8) []const u8 {
    _ = self;
    return switch (opcode) {
        0x00 => "STOP",
        0x01 => "ADD",
        0x02 => "MUL",
        0x03 => "SUB",
        0x04 => "DIV",
        0x05 => "SDIV",
        0x06 => "MOD",
        0x07 => "SMOD",
        0x08 => "ADDMOD",
        0x09 => "MULMOD",
        0x0a => "EXP",
        0x0b => "SIGNEXTEND",
        0x10 => "LT",
        0x11 => "GT",
        0x12 => "SLT",
        0x13 => "SGT",
        0x14 => "EQ",
        0x15 => "ISZERO",
        0x16 => "AND",
        0x17 => "OR",
        0x18 => "XOR",
        0x19 => "NOT",
        0x1a => "BYTE",
        0x1b => "SHL",
        0x1c => "SHR",
        0x1d => "SAR",
        0x20 => "KECCAK256",
        0x30 => "ADDRESS",
        0x31 => "BALANCE",
        0x32 => "ORIGIN",
        0x33 => "CALLER",
        0x34 => "CALLVALUE",
        0x35 => "CALLDATALOAD",
        0x36 => "CALLDATASIZE",
        0x37 => "CALLDATACOPY",
        0x38 => "CODESIZE",
        0x39 => "CODECOPY",
        0x3a => "GASPRICE",
        0x3b => "EXTCODESIZE",
        0x3c => "EXTCODECOPY",
        0x3d => "RETURNDATASIZE",
        0x3e => "RETURNDATACOPY",
        0x3f => "EXTCODEHASH",
        0x40 => "BLOCKHASH",
        0x41 => "COINBASE",
        0x42 => "TIMESTAMP",
        0x43 => "NUMBER",
        0x44 => "DIFFICULTY",
        0x45 => "GASLIMIT",
        0x46 => "CHAINID",
        0x47 => "SELFBALANCE",
        0x48 => "BASEFEE",
        0x50 => "POP",
        0x51 => "MLOAD",
        0x52 => "MSTORE",
        0x53 => "MSTORE8",
        0x54 => "SLOAD",
        0x55 => "SSTORE",
        0x56 => "JUMP",
        0x57 => "JUMPI",
        0x58 => "PC",
        0x59 => "MSIZE",
        0x5a => "GAS",
        0x5b => "JUMPDEST",
        0x5f => "PUSH0",
        0x60 => "PUSH1",
        0x61 => "PUSH2",
        0x62 => "PUSH3",
        0x63 => "PUSH4",
        0x64 => "PUSH5",
        0x65 => "PUSH6",
        0x66 => "PUSH7",
        0x67 => "PUSH8",
        0x68 => "PUSH9",
        0x69 => "PUSH10",
        0x6a => "PUSH11",
        0x6b => "PUSH12",
        0x6c => "PUSH13",
        0x6d => "PUSH14",
        0x6e => "PUSH15",
        0x6f => "PUSH16",
        0x70 => "PUSH17",
        0x71 => "PUSH18",
        0x72 => "PUSH19",
        0x73 => "PUSH20",
        0x74 => "PUSH21",
        0x75 => "PUSH22",
        0x76 => "PUSH23",
        0x77 => "PUSH24",
        0x78 => "PUSH25",
        0x79 => "PUSH26",
        0x7a => "PUSH27",
        0x7b => "PUSH28",
        0x7c => "PUSH29",
        0x7d => "PUSH30",
        0x7e => "PUSH31",
        0x7f => "PUSH32",
        0x80 => "DUP1",
        0x81 => "DUP2",
        0x82 => "DUP3",
        0x83 => "DUP4",
        0x84 => "DUP5",
        0x85 => "DUP6",
        0x86 => "DUP7",
        0x87 => "DUP8",
        0x88 => "DUP9",
        0x89 => "DUP10",
        0x8a => "DUP11",
        0x8b => "DUP12",
        0x8c => "DUP13",
        0x8d => "DUP14",
        0x8e => "DUP15",
        0x8f => "DUP16",
        0x90 => "SWAP1",
        0x91 => "SWAP2",
        0x92 => "SWAP3",
        0x93 => "SWAP4",
        0x94 => "SWAP5",
        0x95 => "SWAP6",
        0x96 => "SWAP7",
        0x97 => "SWAP8",
        0x98 => "SWAP9",
        0x99 => "SWAP10",
        0x9a => "SWAP11",
        0x9b => "SWAP12",
        0x9c => "SWAP13",
        0x9d => "SWAP14",
        0x9e => "SWAP15",
        0x9f => "SWAP16",
        0xa0 => "LOG0",
        0xa1 => "LOG1",
        0xa2 => "LOG2",
        0xa3 => "LOG3",
        0xa4 => "LOG4",
        0xf0 => "CREATE",
        0xf1 => "CALL",
        0xf2 => "CALLCODE",
        0xf3 => "RETURN",
        0xf4 => "DELEGATECALL",
        0xf5 => "CREATE2",
        0xfa => "STATICCALL",
        0xfd => "REVERT",
        0xfe => "INVALID",
        0xff => "SELFDESTRUCT",
        else => "UNKNOWN",
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
    self.results.deinit(self.allocator);
}

pub fn discoverTestCases(self: *Orchestrator) !void {
    // Resolve cases directory relative to the installed executable
    const project_root = try getProjectRoot(self.allocator);
    defer self.allocator.free(project_root);
    // Test cases live under bench/cases (not bench/official/cases)
    const cases_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "bench", "cases" });
    defer self.allocator.free(cases_path);

    const cases_dir = try std.fs.openDirAbsolute(cases_path, .{ .iterate = true });

    var test_cases = std.ArrayList(TestCase).empty;
    defer test_cases.deinit(self.allocator);

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
            const working_benchmarks = [_][]const u8{ "erc20-approval-transfer", "erc20-mint", "erc20-transfer", "ten-thousand-hashes", "snailtracer" };

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

        try test_cases.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, entry.name),
            .bytecode_path = bytecode_path,
            .calldata_path = calldata_path,
        });
    }

    self.test_cases = try test_cases.toOwnedSlice(self.allocator);
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

    // Resolve project root and build the runner path relative to it
    const project_root = try getProjectRoot(self.allocator);
    defer self.allocator.free(project_root);

    var runner_path: []const u8 = undefined;
    if (std.mem.eql(u8, self.evm_name, "zig")) {
        // Default zig to use call2 runner
        runner_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "zig-out", "bin", "evm-runner" });
    } else if (std.mem.eql(u8, self.evm_name, "zig-call2")) {
        runner_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "zig-out", "bin", "evm-runner" });
    } else if (std.mem.eql(u8, self.evm_name, "ethereumjs")) {
        runner_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "bench", "evms", "ethereumjs", "runner.js" });
    } else if (std.mem.eql(u8, self.evm_name, "geth")) {
        runner_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "bench", "evms", "geth", "geth-runner" });
    } else if (std.mem.eql(u8, self.evm_name, "evmone")) {
        runner_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "bench", "official", "evms", "evmone", "build", "evmone-runner" });
    } else {
        const runner_name = try std.fmt.allocPrint(self.allocator, "{s}-runner", .{self.evm_name});
        defer self.allocator.free(runner_name);
        runner_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "bench", "official", "evms", self.evm_name, "target", "release", runner_name });
    }
    defer self.allocator.free(runner_path);

    const num_runs_str = try std.fmt.allocPrint(self.allocator, "{}", .{runs_to_use});
    defer self.allocator.free(num_runs_str);

    // Build hyperfine command (zig now defaults to call2, so no need for --call2 flag)
    const next_flag = if (self.use_next and std.mem.eql(u8, self.evm_name, "zig")) " --next" else "";
    const call2_flag = "";
    // For EthereumJS, invoke via bun explicitly to avoid shebang/exec issues
    const js_prefix = if (std.mem.eql(u8, self.evm_name, "ethereumjs")) (if (std.mem.eql(u8, self.js_runtime, "node")) "node " else "bun ") else "";
    const hyperfine_cmd = try std.fmt.allocPrint(self.allocator, "{s}{s} --contract-code-path {s} --calldata {s} --num-runs {}{s}{s}", .{ js_prefix, runner_path, test_case.bytecode_path, trimmed_calldata, internal_runs_to_use, next_flag, call2_flag });
    defer self.allocator.free(hyperfine_cmd);

    // Prepare export file path to avoid mixing JSON with other output
    const project_root2 = try getProjectRoot(self.allocator);
    defer self.allocator.free(project_root2);
    const tmp_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root2, "bench", "official", ".orchestrator_tmp" });
    defer self.allocator.free(tmp_dir);
    std.fs.cwd().makePath(tmp_dir) catch {};
    const export_file = try std.fmt.allocPrint(self.allocator, "{s}/{s}_{s}.json", .{ tmp_dir, test_case.name, self.evm_name });
    defer self.allocator.free(export_file);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(self.allocator);
    try argv.append(self.allocator, "hyperfine");
    try argv.appendSlice(self.allocator, &[_][]const u8{ "--runs", num_runs_str, "--warmup", "3" });
    if (self.show_output) {
        try argv.append(self.allocator, "--show-output");
    } else {
        try argv.appendSlice(self.allocator, &[_][]const u8{ "--style", "basic" });
    }
    try argv.appendSlice(self.allocator, &[_][]const u8{ "--export-json", export_file, hyperfine_cmd });

    const result = try std.process.Child.run(.{ .allocator = self.allocator, .argv = argv.items });
    defer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);

    // If hyperfine (or the benchmarked command) failed, do not report timings
    if (result.term.Exited != 0) {
        if (result.stderr.len > 0) {
            print("Errors:\n{s}", .{result.stderr});
        }
        print("Skipping results for {s} due to non-zero exit code.\n", .{test_case.name});
        return;
    }

    // Read and parse export JSON
    const json_bytes = std.fs.cwd().readFileAlloc(self.allocator, export_file, 1024 * 1024) catch |err| {
        print("Failed to read hyperfine JSON for {s}: {}\n", .{ test_case.name, err });
        return;
    };
    defer self.allocator.free(json_bytes);

    self.parseHyperfineJson(test_case.name, json_bytes, runs_to_use, internal_runs_to_use) catch |err| {
        print("Failed to parse hyperfine output for {s}: {}\n", .{ test_case.name, err });
        return;
    };
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

fn formatTimeString(allocator: std.mem.Allocator, time_ms: f64) ![]const u8 {
    const formatted = formatTimeWithUnit(time_ms);
    const unit_str = switch (formatted.unit) {
        .microseconds => "μs",
        .milliseconds => "ms",
        .seconds => "s",
    };
    return std.fmt.allocPrint(allocator, "{d:.2} {s}", .{ formatted.value, unit_str });
}

const HyperfineSummary = struct {
    mean: f64,
    min: f64,
    max: f64,
    median: f64,
    stddev: f64,
};

fn parseHyperfineSummary(self: *Orchestrator, json_data: []const u8) ?HyperfineSummary {
    // Robust JSON parsing using std.json
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_data, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    const results_val = root.object.get("results") orelse return null;
    if (results_val.array.items.len == 0) return null;
    const first = results_val.array.items[0];

    var mean: f64 = 0;
    var min: f64 = 0;
    var max: f64 = 0;
    var median: f64 = 0;
    var stddev: f64 = 0;

    if (first.object.get("mean")) |v| mean = switch (v) {
        .float => v.float,
        .number_string => std.fmt.parseFloat(f64, v.number_string) catch 0,
        else => 0,
    };
    if (first.object.get("min")) |v| min = switch (v) {
        .float => v.float,
        .number_string => std.fmt.parseFloat(f64, v.number_string) catch 0,
        else => 0,
    };
    if (first.object.get("max")) |v| max = switch (v) {
        .float => v.float,
        .number_string => std.fmt.parseFloat(f64, v.number_string) catch 0,
        else => 0,
    };
    if (first.object.get("median")) |v| median = switch (v) {
        .float => v.float,
        .number_string => std.fmt.parseFloat(f64, v.number_string) catch 0,
        else => 0,
    };
    if (first.object.get("stddev")) |v| stddev = switch (v) {
        .float => v.float,
        .number_string => std.fmt.parseFloat(f64, v.number_string) catch 0,
        .null => 0,
        else => 0,
    };

    return HyperfineSummary{
        .mean = mean,
        .min = min,
        .max = max,
        .median = median,
        .stddev = stddev,
    };
}

fn parseHyperfineJson(self: *Orchestrator, test_name: []const u8, json_data: []const u8, runs: u32, internal_runs: u32) !void {
    // Robust JSON parsing using std.json
    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = parsed.value;
    const results_val = root.object.get("results") orelse return error.InvalidFormat;
    if (results_val.array.items.len == 0) return error.InvalidFormat;
    const first = results_val.array.items[0];

    var mean: f64 = 0;
    var min: f64 = 0;
    var max: f64 = 0;
    var median: f64 = 0;
    var stddev: f64 = 0;

    if (first.object.get("mean")) |v| mean = switch (v) {
        .float => v.float,
        .number_string => std.fmt.parseFloat(f64, v.number_string) catch 0,
        else => 0,
    };
    if (first.object.get("min")) |v| min = switch (v) {
        .float => v.float,
        .number_string => std.fmt.parseFloat(f64, v.number_string) catch 0,
        else => 0,
    };
    if (first.object.get("max")) |v| max = switch (v) {
        .float => v.float,
        .number_string => std.fmt.parseFloat(f64, v.number_string) catch 0,
        else => 0,
    };
    if (first.object.get("median")) |v| median = switch (v) {
        .float => v.float,
        .number_string => std.fmt.parseFloat(f64, v.number_string) catch 0,
        else => 0,
    };
    if (first.object.get("stddev")) |v| stddev = switch (v) {
        .float => v.float,
        .number_string => std.fmt.parseFloat(f64, v.number_string) catch 0,
        .null => 0,
        else => 0,
    };

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

    try self.results.append(self.allocator, result);

    const mean_str = try formatTimeString(self.allocator, result.mean_ms);
    defer self.allocator.free(mean_str);
    const min_str = try formatTimeString(self.allocator, result.min_ms);
    defer self.allocator.free(min_str);
    const max_str = try formatTimeString(self.allocator, result.max_ms);
    defer self.allocator.free(max_str);
    print("  Mean: {s}, Min: {s}, Max: {s} (per run, {} internal runs)\n", .{ mean_str, min_str, max_str, result.internal_runs });
}

pub fn printSummary(self: *Orchestrator) void {
    print("\n=== Benchmark Summary ===\n", .{});
    print("EVM Implementation: {s}\n", .{self.evm_name});
    print("Runs per test: {}\n", .{self.num_runs});
    print("Test cases: {}\n\n", .{self.test_cases.len});

    print("{s:<30} {s:>15} {s:>15} {s:>15}\n", .{ "Test Case", "Mean (per run)", "Min (per run)", "Max (per run)" });
    print("{s:-<80}\n", .{""});

    for (self.results.items) |result| {
        const mean_str = formatTimeString(self.allocator, result.mean_ms) catch "N/A";
        defer if (!std.mem.eql(u8, mean_str, "N/A")) self.allocator.free(mean_str);
        const min_str = formatTimeString(self.allocator, result.min_ms) catch "N/A";
        defer if (!std.mem.eql(u8, min_str, "N/A")) self.allocator.free(min_str);
        const max_str = formatTimeString(self.allocator, result.max_ms) catch "N/A";
        defer if (!std.mem.eql(u8, max_str, "N/A")) self.allocator.free(max_str);
        print("{s:<30} {s:>15} {s:>15} {s:>15}\n", .{ result.test_case, mean_str, min_str, max_str });
    }
}

pub fn exportResults(self: *Orchestrator, format: []const u8) !void {
    if (std.mem.eql(u8, format, "json")) {
        try self.exportJSON();
    } else if (std.mem.eql(u8, format, "markdown")) {
        try self.exportMarkdown();
    } else if (std.mem.eql(u8, format, "detailed")) {
        try self.exportDetailed();
    }
}

pub fn runDetailedBenchmarks(self: *Orchestrator, perf_output_dir: []const u8) !void {
    // TODO: Fix detailed benchmarks for Zig 0.15.1 API changes
    _ = perf_output_dir;
    std.debug.print("Detailed benchmarks temporarily disabled - running standard benchmarks instead\n", .{});
    return self.runBenchmarks();
}

// Original implementation disabled due to API changes
// // fn runDetailedBenchmarks_disabled_DO_NOT_COMPILE(self: *Orchestrator, perf_output_dir: []const u8) !void {
// //     _ = self;
// //     _ = perf_output_dir;
// //     if (false) { // Never executed
//     // Create output directory if it doesn't exist
//     std.fs.cwd().makePath(perf_output_dir) catch |err| {
//         if (err != error.PathAlreadyExists) return err;
//     };
//     
//     // Create timestamp-based subdirectory
//     const timestamp = std.time.timestamp();
//     const timestamp_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}_{d}", .{ 
//         perf_output_dir, 
//         self.evm_name, 
//         timestamp 
//     });
//     defer self.allocator.free(timestamp_dir);
//     
//     try std.fs.cwd().makePath(timestamp_dir);
//     
//     // Run benchmarks with additional metrics
//     for (self.test_cases) |test_case| {
//         print("Collecting detailed metrics for {s}...\n", .{test_case.name});
//         
//         // Run with hyperfine and capture additional metrics
//         try self.runDetailedBenchmark(test_case, timestamp_dir);
//     }
//     
//     // Generate detailed report
//     try self.generateDetailedReport(timestamp_dir);
//     } // end of if (false)
// }

// fn runDetailedBenchmark(self: *Orchestrator, test_case: TestCase, output_dir: []const u8) !void {
//     // Build runner command
//     const runner_cmd = try self.buildRunnerCommand(test_case);
//     defer self.allocator.free(runner_cmd);
//     
//     // Base hyperfine command with extended statistics
//     const hyperfine_cmd = try std.fmt.allocPrint(self.allocator,
//         \\hyperfine --runs {d} --warmup 3 --export-json "{s}/{s}.json" --export-csv "{s}/{s}.csv" "{s}"
//     , .{
//         self.num_runs,
//         output_dir,
//         test_case.name,
//         output_dir,
//         test_case.name,
//         runner_cmd,
//     });
//     defer self.allocator.free(hyperfine_cmd);
//     
//     // Run hyperfine
//     const result = try std.process.Child.run(.{
//         .allocator = self.allocator,
//         .argv = &[_][]const u8{ "sh", "-c", hyperfine_cmd },
//     });
//     defer self.allocator.free(result.stdout);
//     defer self.allocator.free(result.stderr);
//     
//     if (result.term != .Exited or result.term.Exited != 0) {
//         print("Warning: Detailed benchmark failed for {s}\n", .{test_case.name});
//         if (result.stderr.len > 0) {
//             print("Error: {s}\n", .{result.stderr});
//         }
//         return;
//     }
//     
//     // Platform-specific performance counters
//     const platform = @import("builtin").os.tag;
//     if (platform == .linux) {
//         // Run with perf stat for cache and branch statistics
//         try self.runPerfStat(test_case, output_dir, runner_cmd);
//     } else if (platform == .macos) {
//         // Run with dtrace or instruments if available
//         try self.runMacOSPerformanceAnalysis(test_case, output_dir, runner_cmd);
//     }
// }

// fn runPerfStat(self: *Orchestrator, test_case: TestCase, output_dir: []const u8, runner_cmd: []const u8) !void {
//     // Cache statistics
//     const cache_cmd = try std.fmt.allocPrint(self.allocator,
//         \\perf stat -e cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses {s} 2> "{s}/{s}_cache.txt"
//     , .{ runner_cmd, output_dir, test_case.name });
//     defer self.allocator.free(cache_cmd);
//     
//     _ = try std.process.Child.run(.{
//         .allocator = self.allocator,
//         .argv = &[_][]const u8{ "sh", "-c", cache_cmd },
//     });
//     
//     // Branch prediction statistics
//     const branch_cmd = try std.fmt.allocPrint(self.allocator,
//         \\perf stat -e branches,branch-misses {s} 2> "{s}/{s}_branches.txt"
//     , .{ runner_cmd, output_dir, test_case.name });
//     defer self.allocator.free(branch_cmd);
//     
//     _ = try std.process.Child.run(.{
//         .allocator = self.allocator,
//         .argv = &[_][]const u8{ "sh", "-c", branch_cmd },
//     });
//     
//     // Instruction statistics
//     const instr_cmd = try std.fmt.allocPrint(self.allocator,
//         \\perf stat -e instructions,cycles,task-clock {s} 2> "{s}/{s}_instructions.txt"
//     , .{ runner_cmd, output_dir, test_case.name });
//     defer self.allocator.free(instr_cmd);
//     
//     _ = try std.process.Child.run(.{
//         .allocator = self.allocator,
//         .argv = &[_][]const u8{ "sh", "-c", instr_cmd },
//     });
// }

// fn runMacOSPerformanceAnalysis(self: *Orchestrator, test_case: TestCase, output_dir: []const u8, runner_cmd: []const u8) !void {
//     // Check if we can use Instruments
//     const check_instruments = try std.process.Child.run(.{
//         .allocator = self.allocator,
//         .argv = &[_][]const u8{ "which", "instruments" },
//     });
//     defer self.allocator.free(check_instruments.stdout);
//     defer self.allocator.free(check_instruments.stderr);
//     
//     if (check_instruments.term == .Exited and check_instruments.term.Exited == 0) {
//         // Use Instruments for detailed profiling
//         const instruments_cmd = try std.fmt.allocPrint(self.allocator,
//             \\instruments -t "Time Profiler" -D "{s}/{s}_profile.trace" {s}
//         , .{ output_dir, test_case.name, runner_cmd });
//         defer self.allocator.free(instruments_cmd);
//         
//         _ = try std.process.Child.run(.{
//             .allocator = self.allocator,
//             .argv = &[_][]const u8{ "sh", "-c", instruments_cmd },
//         });
//     }
// }

fn buildRunnerCommand(self: *Orchestrator, test_case: TestCase) ![]const u8 {
    // Read calldata
    const calldata_file = try std.fs.cwd().openFile(test_case.calldata_path, .{});
    defer calldata_file.close();
    const calldata = try calldata_file.readToEndAlloc(self.allocator, 1024 * 1024);
    defer self.allocator.free(calldata);
    const trimmed_calldata = std.mem.trim(u8, calldata, " \n\r\t");
    
    // Get project root and runner path
    const project_root = try getProjectRoot(self.allocator);
    defer self.allocator.free(project_root);
    
    var runner_path: []const u8 = undefined;
    if (std.mem.eql(u8, self.evm_name, "zig")) {
        // Default zig to use call2 runner
        runner_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "zig-out", "bin", "evm-runner" });
    } else if (std.mem.eql(u8, self.evm_name, "zig-call2")) {
        runner_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "zig-out", "bin", "evm-runner" });
    } else if (std.mem.eql(u8, self.evm_name, "ethereumjs")) {
        runner_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "bench", "evms", "ethereumjs", "runner.js" });
    } else if (std.mem.eql(u8, self.evm_name, "geth")) {
        runner_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "bench", "evms", "geth", "geth-runner" });
    } else if (std.mem.eql(u8, self.evm_name, "evmone")) {
        runner_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "bench", "official", "evms", "evmone", "build", "evmone-runner" });
    } else {
        const runner_name = try std.fmt.allocPrint(self.allocator, "{s}-runner", .{self.evm_name});
        defer self.allocator.free(runner_name);
        runner_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "bench", "official", "evms", self.evm_name, "target", "release", runner_name });
    }
    defer self.allocator.free(runner_path);
    
    // Determine internal runs
    const internal_runs = if (std.mem.eql(u8, test_case.name, "snailtracer"))
        self.snailtracer_internal_runs
    else
        self.internal_runs;
    
    const num_runs_str = try std.fmt.allocPrint(self.allocator, "{}", .{internal_runs});
    defer self.allocator.free(num_runs_str);
    
    const next_flag = if (self.use_next) " --next" else "";
    const call2_flag = "";
    
    // For EthereumJS, invoke via bun explicitly
    const js_prefix = if (std.mem.eql(u8, self.evm_name, "ethereumjs")) (if (std.mem.eql(u8, self.js_runtime, "node")) "node " else "bun ") else "";
    
    return try std.fmt.allocPrint(self.allocator, "{s}{s} --contract-code-path {s} --calldata {s} --num-runs {s}{s}{s}", .{ 
        js_prefix, 
        runner_path, 
        test_case.bytecode_path, 
        trimmed_calldata, 
        num_runs_str, 
        next_flag,
        call2_flag 
    });
}

// fn generateDetailedReport(self: *Orchestrator, output_dir: []const u8) !void {
//     const report_path = try std.fmt.allocPrint(self.allocator, "{s}/detailed_report.md", .{output_dir});
//     defer self.allocator.free(report_path);
//     
//     const file = try std.fs.cwd().createFile(report_path, .{});
//     defer file.close();
//     
//     try file.writer().print("# Detailed Performance Analysis Report\n\n", .{});
//     try file.writer().print("## EVM Implementation: {s}\n\n", .{self.evm_name});
//     
//     const timestamp = std.time.timestamp();
//     try file.writer().print("Generated: {d}\n\n", .{timestamp});
//     
//     try file.writer().print("## Test Environment\n\n", .{});
//     
//     // Platform information
//     const platform = @import("builtin").os.tag;
//     try file.writer().print("- Platform: {s}\n", .{@tagName(platform)});
//     try file.writer().print("- Architecture: {s}\n", .{@tagName(@import("builtin").cpu.arch)});
//     
//     try file.writer().print("\n## Benchmark Results\n\n", .{});
//     
//     // Process each test case's detailed results
//     for (self.test_cases) |test_case| {
//         try file.writer().print("### {s}\n\n", .{test_case.name});
//         
//         // Read and include JSON results
//         const json_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ output_dir, test_case.name });
//         defer self.allocator.free(json_path);
//         
//         if (std.fs.cwd().openFile(json_path, .{})) |json_file| {
//             defer json_file.close();
//             const json_content = try json_file.readToEndAlloc(self.allocator, 1024 * 1024);
//             defer self.allocator.free(json_content);
//             
//             // Parse basic metrics from JSON
//             if (self.parseHyperfineSummary(json_content)) |summary| {
//                 const internal_runs = if (std.mem.eql(u8, test_case.name, "snailtracer"))
//                     self.snailtracer_internal_runs
//                 else
//                     self.internal_runs;
//                 
//                 const runs_float = @as(f64, @floatFromInt(internal_runs));
//                 try file.writer().print("- Mean: {d:.6} ms\n", .{(summary.mean * 1000) / runs_float});
//                 try file.writer().print("- Median: {d:.6} ms\n", .{(summary.median * 1000) / runs_float});
//                 try file.writer().print("- Min: {d:.6} ms\n", .{(summary.min * 1000) / runs_float});
//                 try file.writer().print("- Max: {d:.6} ms\n", .{(summary.max * 1000) / runs_float});
//                 try file.writer().print("- Std Dev: {d:.6} ms\n\n", .{(summary.stddev * 1000) / runs_float});
//             }
//         } else |_| {}
//         
//         // Include platform-specific metrics if available
//         if (platform == .linux) {
//             // Include cache statistics
//             const cache_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}_cache.txt", .{ output_dir, test_case.name });
//             defer self.allocator.free(cache_path);
//             
//             if (std.fs.cwd().openFile(cache_path, .{})) |cache_file| {
//                 defer cache_file.close();
//                 try file.writer().print("#### Cache Statistics\n```\n", .{});
//                 const cache_content = try cache_file.readToEndAlloc(self.allocator, 1024 * 1024);
//                 defer self.allocator.free(cache_content);
//                 try file.writeAll(cache_content);
//                 try file.writer().print("```\n\n", .{});
//             } else |_| {}
//             
//             // Include branch statistics
//             const branch_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}_branches.txt", .{ output_dir, test_case.name });
//             defer self.allocator.free(branch_path);
//             
//             if (std.fs.cwd().openFile(branch_path, .{})) |branch_file| {
//                 defer branch_file.close();
//                 try file.writer().print("#### Branch Prediction\n```\n", .{});
//                 const branch_content = try branch_file.readToEndAlloc(self.allocator, 1024 * 1024);
//                 defer self.allocator.free(branch_content);
//                 try file.writeAll(branch_content);
//                 try file.writer().print("```\n\n", .{});
//             } else |_| {}
//         }
//     }
//     
//     print("Detailed report generated: {s}\n", .{report_path});
// }

fn exportDetailed(self: *Orchestrator) !void {
    // TODO: Fix detailed export for Zig 0.15.1 API changes
    _ = self;
    std.debug.print("Detailed export temporarily disabled\n", .{});
    return;
}

fn exportJSON(self: *Orchestrator) !void {
    const file = try std.fs.cwd().createFile("results.json", .{});
    defer file.close();
    
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(&buffer);
    
    try writer.interface.writeAll("{\n");
    try writer.interface.print("  \"evm\": \"{s}\",\n", .{self.evm_name});
    try writer.interface.print("  \"runs\": {},\n", .{self.num_runs});
    try writer.interface.print("  \"timestamp\": {},\n", .{std.time.timestamp()});
    try writer.interface.writeAll("  \"benchmarks\": [\n");
    
    for (self.results.items, 0..) |result, i| {
        try writer.interface.print("    {{\n", .{});
        try writer.interface.print("      \"name\": \"{s}\",\n", .{result.test_case});
        try writer.interface.print("      \"mean_ms\": {d:.6},\n", .{result.mean_ms});
        try writer.interface.print("      \"median_ms\": {d:.6},\n", .{result.median_ms});
        try writer.interface.print("      \"min_ms\": {d:.6},\n", .{result.min_ms});
        try writer.interface.print("      \"max_ms\": {d:.6},\n", .{result.max_ms});
        try writer.interface.print("      \"std_dev_ms\": {d:.6},\n", .{result.std_dev_ms});
        try writer.interface.print("      \"internal_runs\": {}\n", .{result.internal_runs});
        try writer.interface.print("    }}{s}\n", .{if (i < self.results.items.len - 1) "," else ""});
    }
    
    try writer.interface.writeAll("  ]\n");
    try writer.interface.writeAll("}\n");
    
    // Flush the buffer before closing
    try writer.interface.flush();
    
    print("Results exported to results.json\n", .{});
}

// fn exportJSON_disabled_DO_NOT_COMPILE(self: *Orchestrator) !void {
//     const file = try std.fs.cwd().createFile("results.json", .{});
//     defer file.close();
// 
//     try file.writeAll("{\n");
//     try file.writer().print("  \"evm\": \"{s}\",\n", .{self.evm_name});
//     try file.writer().print("  \"runs\": {},\n", .{self.num_runs});
//     try file.writer().print("  \"timestamp\": {},\n", .{std.time.timestamp()});
//     try file.writeAll("  \"benchmarks\": [\n");
// 
//     for (self.results.items, 0..) |result, i| {
//         try file.writer().print("    {{\n", .{});
//         try file.writer().print("      \"name\": \"{s}\",\n", .{result.test_case});
//         try file.writer().print("      \"mean_ms\": {d:.6},\n", .{result.mean_ms});
//         try file.writer().print("      \"median_ms\": {d:.6},\n", .{result.median_ms});
//         try file.writer().print("      \"min_ms\": {d:.6},\n", .{result.min_ms});
//         try file.writer().print("      \"max_ms\": {d:.6},\n", .{result.max_ms});
//         try file.writer().print("      \"std_dev_ms\": {d:.6},\n", .{result.std_dev_ms});
//         try file.writer().print("      \"internal_runs\": {}\n", .{result.internal_runs});
//         try file.writer().print("    }}{s}\n", .{if (i < self.results.items.len - 1) "," else ""});
//     }
// 
//     try file.writeAll("  ]\n");
//     try file.writeAll("}\n");
// 
//     print("Results exported to results.json\n", .{});
// }

fn exportMarkdown(self: *Orchestrator) !void {
    // Create the file in bench/results.md
    const project_root = try getProjectRoot(self.allocator);
    defer self.allocator.free(project_root);
    
    const results_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "bench", "official", "results.md" });
    defer self.allocator.free(results_path);
    
    const file = try std.fs.createFileAbsolute(results_path, .{});
    defer file.close();
    
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(&buffer);
    
    // Get current timestamp
    const timestamp = std.time.timestamp();
    const seconds = @as(u64, @intCast(timestamp));
    
    // Write header
    try writer.interface.print("# Guillotine EVM Benchmark Results\n\n", .{});
    try writer.interface.print("## Summary\n\n", .{});
    try writer.interface.print("**EVM Implementation**: {s}\n", .{self.evm_name});
    try writer.interface.print("**Test Runs per Case**: {}\n", .{self.num_runs});
    try writer.interface.print("**Total Test Cases**: {}\n", .{self.results.items.len});
    try writer.interface.print("**Timestamp**: {} (Unix epoch)\n\n", .{seconds});
    
    // Write performance table
    try writer.interface.print("## Performance Results (Per Run)\n\n", .{});
    try writer.interface.writeAll("| Test Case | Mean | Median | Min | Max | Std Dev | Internal Runs |\n");
    try writer.interface.writeAll("|-----------|------|--------|-----|-----|---------|---------------|\n");
    
    for (self.results.items) |result| {
        const mean_str = try formatTimeString(self.allocator, result.mean_ms);
        defer self.allocator.free(mean_str);
        const median_str = try formatTimeString(self.allocator, result.median_ms);
        defer self.allocator.free(median_str);
        const min_str = try formatTimeString(self.allocator, result.min_ms);
        defer self.allocator.free(min_str);
        const max_str = try formatTimeString(self.allocator, result.max_ms);
        defer self.allocator.free(max_str);
        const stddev_str = try formatTimeString(self.allocator, result.std_dev_ms);
        defer self.allocator.free(stddev_str);
        
        try writer.interface.print("| {s:<25} | {s:>10} | {s:>10} | {s:>9} | {s:>9} | {s:>11} | {d:>13} |\n", .{
            result.test_case,
            mean_str,
            median_str,
            min_str,
            max_str,
            stddev_str,
            result.internal_runs,
        });
    }
    
    // Add test case descriptions
    try writer.interface.print("\n## Test Case Descriptions\n\n", .{});
    try writer.interface.writeAll("### ERC20 Operations\n\n");
    try writer.interface.writeAll("- **erc20-transfer**: Standard ERC20 token transfer operation\n");
    try writer.interface.writeAll("- **erc20-mint**: ERC20 token minting operation\n");
    try writer.interface.writeAll("- **erc20-approval-transfer**: ERC20 approval followed by transferFrom\n\n");
    
    try writer.interface.writeAll("### Computational Benchmarks\n\n");
    try writer.interface.writeAll("- **ten-thousand-hashes**: Performs 10,000 keccak256 hash operations\n");
    try writer.interface.writeAll("- **snailtracer**: Complex computational benchmark with intensive operations\n\n");
    
    // Add environment information
    try writer.interface.print("## Environment\n\n", .{});
    try writer.interface.print("- **Benchmark Tool**: hyperfine\n", .{});
    try writer.interface.print("- **Warmup Runs**: 3\n", .{});
    try writer.interface.print("- **Statistical Confidence**: Based on {} runs per test case\n\n", .{self.num_runs});
    
    // Add notes
    try writer.interface.writeAll("## Notes\n\n");
    try writer.interface.writeAll("- **All times are normalized per individual execution run**\n");
    try writer.interface.writeAll("- Times are displayed in the most appropriate unit (μs, ms, or s)\n");
    try writer.interface.writeAll("- Lower values indicate better performance\n");
    try writer.interface.writeAll("- Standard deviation indicates consistency (lower is more consistent)\n");
    try writer.interface.writeAll("- Each hyperfine run executes the contract multiple times internally (see Internal Runs column)\n");
    try writer.interface.writeAll("- These benchmarks measure the full execution time including contract deployment\n\n");
    
    try writer.interface.writeAll("---\n\n");
    try writer.interface.writeAll("*Generated by Guillotine Benchmark Orchestrator*\n");
    
    // Flush the buffer before closing
    try writer.interface.flush();
    
    print("Results exported to bench/official/results.md\n", .{});
}

// fn exportMarkdown_disabled_DO_NOT_COMPILE(self: *Orchestrator) !void {
//     // Create the file in bench/results.md
//     var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
//     const exe_path = try std.fs.selfExeDirPath(&exe_dir_buf);
// 
//     const project_root = try std.fs.path.resolve(self.allocator, &[_][]const u8{ exe_path, "..", ".." });
//     defer self.allocator.free(project_root);
// 
//     const results_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_root, "bench", "official", "results.md" });
//     defer self.allocator.free(results_path);
// 
//     const file = try std.fs.createFileAbsolute(results_path, .{});
//     defer file.close();
// 
//     // Get current timestamp
//     const timestamp = std.time.timestamp();
//     const seconds = @as(u64, @intCast(timestamp));
// 
//     // Write header
//     try file.writer().print("# Guillotine EVM Benchmark Results\n\n", .{});
//     try file.writer().print("## Summary\n\n", .{});
//     try file.writer().print("**EVM Implementation**: {s}\n", .{self.evm_name});
//     try file.writer().print("**Test Runs per Case**: {}\n", .{self.num_runs});
//     try file.writer().print("**Total Test Cases**: {}\n", .{self.results.items.len});
//     try file.writer().print("**Timestamp**: {} (Unix epoch)\n\n", .{seconds});
// 
//     // Write performance table
//     try file.writer().print("## Performance Results (Per Run)\n\n", .{});
//     try file.writeAll("| Test Case | Mean | Median | Min | Max | Std Dev | Internal Runs |\n");
//     try file.writeAll("|-----------|------|--------|-----|-----|---------|---------------|\n");
// 
//     for (self.results.items) |result| {
//         const mean_formatted = formatTimeWithUnit(result.mean_ms);
//         const median_formatted = formatTimeWithUnit(result.median_ms);
//         const min_formatted = formatTimeWithUnit(result.min_ms);
//         const max_formatted = formatTimeWithUnit(result.max_ms);
//         const stddev_formatted = formatTimeWithUnit(result.std_dev_ms);
// 
//         try file.writer().print("| {s:<25} | {s:>10} | {s:>10} | {s:>9} | {s:>9} | {s:>11} | {d:>13} |\n", .{
//             result.test_case,
//             mean_formatted,
//             median_formatted,
//             min_formatted,
//             max_formatted,
//             stddev_formatted,
//             result.internal_runs,
//         });
//     }
// 
//     // Add test case descriptions
//     try file.writer().print("\n## Test Case Descriptions\n\n", .{});
//     try file.writeAll("### ERC20 Operations\n\n");
//     try file.writeAll("- **erc20-transfer**: Standard ERC20 token transfer operation\n");
//     try file.writeAll("- **erc20-mint**: ERC20 token minting operation\n");
//     try file.writeAll("- **erc20-approval-transfer**: ERC20 approval followed by transferFrom\n\n");
// 
//     try file.writeAll("### Computational Benchmarks\n\n");
//     try file.writeAll("- **ten-thousand-hashes**: Performs 10,000 keccak256 hash operations\n");
//     try file.writeAll("- **snailtracer**: Complex computational benchmark with intensive operations\n\n");
// 
//     // Add environment information
//     try file.writer().print("## Environment\n\n", .{});
//     try file.writer().print("- **Benchmark Tool**: hyperfine\n", .{});
//     try file.writer().print("- **Warmup Runs**: 3\n", .{});
//     try file.writer().print("- **Statistical Confidence**: Based on {} runs per test case\n\n", .{self.num_runs});
// 
//     // Add notes
//     try file.writeAll("## Notes\n\n");
//     try file.writeAll("- **All times are normalized per individual execution run**\n");
//     try file.writeAll("- Times are displayed in the most appropriate unit (μs, ms, or s)\n");
//     try file.writeAll("- Lower values indicate better performance\n");
//     try file.writeAll("- Standard deviation indicates consistency (lower is more consistent)\n");
//     try file.writeAll("- Each hyperfine run executes the contract multiple times internally (see Internal Runs column)\n");
//     try file.writeAll("- These benchmarks measure the full execution time including contract deployment\n\n");
// 
//     try file.writeAll("---\n\n");
//     try file.writeAll("*Generated by Guillotine Benchmark Orchestrator*\n");
// 
//     print("Results exported to bench/results.md\n", .{});
// }

test "Orchestrator.init creates proper instance" {
    const allocator = std.testing.allocator;

    var orchestrator = try Orchestrator.init(allocator, "test-evm", 10, 5, 3, 2, 1, 1, false, false, false, false, "bun");
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

    var orchestrator = try Orchestrator.init(allocator, "test-evm", 10, 5, 3, 2, 1, 1, false, false, false, false, "bun");

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
    try orchestrator.results.append(allocator, .{
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

    var orchestrator = try Orchestrator.init(allocator, "test-evm", 10, 5, 3, 2, 1, 1, false, false, false, false, "bun");
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
    try std.testing.expectApproxEqRel(@as(f64, 10.0), result.min_ms, 0.001); // 0.0500 * 1000 / 5
    try std.testing.expectApproxEqRel(@as(f64, 12.0), result.max_ms, 0.001); // 0.0600 * 1000 / 5
    try std.testing.expectApproxEqRel(@as(f64, 0.24), result.std_dev_ms, 0.001); // 0.0012 * 1000 / 5
    try std.testing.expectApproxEqRel(@as(f64, 10.4), result.median_ms, 0.001); // 0.0520 * 1000 / 5
    try std.testing.expectEqual(@as(u32, 10), result.runs);
    try std.testing.expectEqual(@as(u32, 5), result.internal_runs);
}

test "parseHyperfineJson handles null stddev" {
    const allocator = std.testing.allocator;

    var orchestrator = try Orchestrator.init(allocator, "test-evm", 10, 5, 3, 2, 1, 1, false, false, false, false, "bun");
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
    var micro_buf = std.ArrayList(u8).empty;
    defer micro_buf.deinit(allocator);
    try micro_time.format("", .{}, micro_buf.writer());
    try std.testing.expectEqualStrings("250.50 μs", micro_buf.items);

    // Test milliseconds formatting
    const milli_time = FormattedTime{ .value = 15.75, .unit = .milliseconds };
    var milli_buf = std.ArrayList(u8).empty;
    defer milli_buf.deinit(allocator);
    try milli_time.format("", .{}, milli_buf.writer());
    try std.testing.expectEqualStrings("15.75 ms", milli_buf.items);

    // Test seconds formatting
    const seconds_time = FormattedTime{ .value = 1.25, .unit = .seconds };
    var seconds_buf = std.ArrayList(u8).empty;
    defer seconds_buf.deinit(allocator);
    try seconds_time.format("", .{}, seconds_buf.writer());
    try std.testing.expectEqualStrings("1.25 s", seconds_buf.items);
}
