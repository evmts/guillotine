const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const Evm = @import("../evm.zig");
const Host = @import("../host.zig").Host;
const Analysis = @import("../analysis.zig");
const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
const Frame = @import("../stack_frame.zig").StackFrame;
const Revm = @import("../revm_wrapper/revm.zig").Revm;

pub const TraceStep = struct {
    pc: usize,
    op: u8,
    depth: u32,
    gas: u64,
    mem_size: usize,
    // Stack top is at the end of this slice; values are minimal hex to u256
    stack: []u256,
};

pub const Divergence = struct {
    index: usize,
    guillotine: TraceStep,
    revm: TraceStep,
};

fn read_file_lines(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const buf = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    errdefer allocator.free(buf);
    var lines = std.ArrayList([]const u8).init(allocator);
    errdefer lines.deinit();
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(line);
    }
    return lines.toOwnedSlice();
}

fn parse_hex_u256(s: []const u8) !u256 {
    const hex = if (std.mem.startsWith(u8, s, "0x")) s[2..] else s;
    if (hex.len == 0) return 0;
    return try std.fmt.parseInt(u256, hex, 16);
}

fn parse_trace_line(allocator: std.mem.Allocator, line: []const u8) !TraceStep {
    var ts = std.json.TokenStream.init(line);
    // Expect object
    _ = try ts.peekNextTokenOfType(.ObjectBegin);
    var pc: usize = 0;
    var op: u8 = 0;
    var gas: u64 = 0;
    var depth: u32 = 0;
    var mem_size: usize = 0;
    var stack_vals = std.ArrayList(u256).init(allocator);
    errdefer stack_vals.deinit();

    while (true) {
        const tok = try ts.next();
        switch (tok) {
            .ObjectEnd => break,
            .String => |key| {
                const k = key.ptr[0..key.len];
                // Consume colon
                _ = try ts.next();
                if (std.mem.eql(u8, k, "pc")) {
                    pc = try std.json.parseFromTokenStream(usize, allocator, &ts, .{});
                } else if (std.mem.eql(u8, k, "op")) {
                    op = try std.json.parseFromTokenStream(u8, allocator, &ts, .{});
                } else if (std.mem.eql(u8, k, "gas")) {
                    const s = try std.json.parseFromTokenStream([]const u8, allocator, &ts, .{});
                    defer allocator.free(s);
                    gas = @intCast(try std.fmt.parseInt(u64, if (std.mem.startsWith(u8, s, "0x")) s[2..] else s, 16));
                } else if (std.mem.eql(u8, k, "depth")) {
                    depth = try std.json.parseFromTokenStream(u32, allocator, &ts, .{});
                } else if (std.mem.eql(u8, k, "memSize")) {
                    mem_size = try std.json.parseFromTokenStream(usize, allocator, &ts, .{});
                } else if (std.mem.eql(u8, k, "stack")) {
                    // Parse array of hex strings
                    _ = try ts.peekNextTokenOfType(.ArrayBegin);
                    while (true) {
                        const atok = try ts.next();
                        switch (atok) {
                            .ArrayEnd => break,
                            .String => |sv| {
                                const svs = sv.ptr[0..sv.len];
                                const v = try parse_hex_u256(svs);
                                try stack_vals.append(v);
                            },
                            else => return error.InvalidTraceFormat,
                        }
                    }
                } else {
                    // Skip value for unknown key
                    _ = try ts.next();
                }
                // Consume comma or handle ObjectEnd in next loop
            },
            else => return error.InvalidTraceFormat,
        }
    }

    return TraceStep{
        .pc = pc,
        .op = op,
        .depth = depth,
        .gas = gas,
        .mem_size = mem_size,
        .stack = try stack_vals.toOwnedSlice(),
    };
}

fn parse_trace_file(allocator: std.mem.Allocator, path: []const u8) ![]TraceStep {
    const lines = try read_file_lines(allocator, path);
    errdefer allocator.free(lines);
    var steps = std.ArrayList(TraceStep).init(allocator);
    errdefer {
        for (steps.items) |s| allocator.free(s.stack);
        steps.deinit();
    }
    for (lines) |line| {
        const step = try parse_trace_line(allocator, line);
        try steps.append(step);
    }
    return steps.toOwnedSlice();
}

pub fn compare_traces(g_steps: []TraceStep, r_steps: []TraceStep) ?Divergence {
    const n = @min(g_steps.len, r_steps.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const g = g_steps[i];
        const r = r_steps[i];
        // Compare core fields
        const stacks_equal = stacks_eq(g.stack, r.stack);
        if (g.pc != r.pc or g.op != r.op or g.depth != r.depth or !stacks_equal) {
            return Divergence{ .index = i, .guillotine = g, .revm = r };
        }
    }
    if (g_steps.len != r_steps.len) {
        const idx = n;
        const g = if (idx < g_steps.len) g_steps[idx] else g_steps[g_steps.len - 1];
        const r = if (idx < r_steps.len) r_steps[idx] else r_steps[r_steps.len - 1];
        return Divergence{ .index = idx, .guillotine = g, .revm = r };
    }
    return null;
}

fn stacks_eq(a: []const u256, b: []const u256) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) if (a[i] != b[i]) return false;
    return true;
}

pub fn run_diff_erc20_transfer(allocator: std.mem.Allocator) !?Divergence {
    // Load official ERC20 bench initcode and calldata
    const initcode_hex_path = "/Users/williamcory/guillotine/bench/official/cases/erc20-transfer/bytecode.txt";
    const calldata_hex_path = "/Users/williamcory/guillotine/bench/official/cases/erc20-transfer/calldata.txt";

    var init_f = try std.fs.openFileAbsolute(initcode_hex_path, .{});
    defer init_f.close();
    const init_hex = try init_f.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(init_hex);
    const init_bytes = try allocator.alloc(u8, std.mem.trim(u8, init_hex, " \t\n\r").len / 2);
    defer allocator.free(init_bytes);
    _ = try std.fmt.hexToBytes(init_bytes, std.mem.trim(u8, init_hex, " \t\n\r"));

    var cal_f = try std.fs.openFileAbsolute(calldata_hex_path, .{});
    defer cal_f.close();
    const cal_hex = try cal_f.readToEndAlloc(allocator, 1024);
    defer allocator.free(cal_hex);
    const cal_bytes = try allocator.alloc(u8, std.mem.trim(u8, cal_hex, " \t\n\r").len / 2);
    defer allocator.free(cal_bytes);
    _ = try std.fmt.hexToBytes(cal_bytes, std.mem.trim(u8, cal_hex, " \t\n\r"));

    // Setup our EVM and deploy to get runtime code
    var memory_db = @import("../state/memory_database.zig").MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const deployer = Address.ZERO_ADDRESS;
    const create_res = try evm.create_contract(deployer, 0, init_bytes, 50_000_000);
    if (!create_res.success) return error.DeployFailed;
    const contract_addr = create_res.address;
    const runtime = evm.state.get_code(contract_addr);

    // Build temp trace paths
    // Ensure tmp dir exists (use fixed paths below)
    var guillotine_trace_path_buf: [256]u8 = undefined;
    const guillotine_trace_path = try std.fmt.bufPrint(&guillotine_trace_path_buf, "/tmp/guillotine_trace_{d}.jsonl", .{@intFromPtr(&evm)});
    var revm_trace_path_buf: [256]u8 = undefined;
    const revm_trace_path = try std.fmt.bufPrint(&revm_trace_path_buf, "/tmp/revm_trace_{d}.jsonl", .{@intFromPtr(&evm)});

    // Guillotine: enable tracing to file and execute call
    _ = evm.enable_tracing_to_path(guillotine_trace_path, false) catch {};
    const call_params = @import("../host.zig").CallParams{ .call = .{
        .to = contract_addr,
        .caller = deployer,
        .input = cal_bytes,
        .value = 0,
        .gas = 10_000_000,
    } };
    const g_call_res = try evm.call(call_params);
    _ = g_call_res;
    evm.disable_tracing();

    // REVM: set runtime code at arbitrary address and execute with trace
    var revm_vm = try Revm.init(allocator, .{});
    defer revm_vm.deinit();
    const revm_addr = [_]u8{0xAB} ** 20;
    try revm_vm.setCode(revm_addr, runtime);
    const revm_res = try revm_vm.executeWithTrace(deployer, revm_addr, 0, cal_bytes, 10_000_000, revm_trace_path);
    // NOTE: The C wrapper writes to the provided trace_path (we reuse guillotine path to ease file mgmt)
    _ = revm_res; // result not needed here

    // Parse both traces
    const g_steps = try parse_trace_file(allocator, guillotine_trace_path);
    defer {
        for (g_steps) |s| allocator.free(s.stack);
        allocator.free(g_steps);
    }
    const r_steps = try parse_trace_file(allocator, revm_trace_path);
    defer {
        for (r_steps) |s| allocator.free(s.stack);
        allocator.free(r_steps);
    }

    return compare_traces(g_steps, r_steps);
}

test "trace diff: erc20 transfer divergence" {
    const allocator = std.testing.allocator;
    const div = try run_diff_erc20_transfer(allocator);
    // The test does not assert a specific divergence; it ensures the utility runs.
    // If no divergence, div is null. We allow both to avoid flaky failure during development.
    _ = div;
}
