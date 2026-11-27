//! In-process cross-EVM comparison runner for Guillotine.
//! Reads a canonical workload JSON file and emits standardized JSON timing
//! and verification results to stdout.
const std = @import("std");
const builtin = @import("builtin");
const evm = @import("guillotine");

pub const std_options: std.Options = .{ .log_level = .err };

const instruction_limit: u32 = 300_000_000;

const JsonBlock = struct {
    number: []const u8,
    timestamp: []const u8,
    coinbase: []const u8,
    basefee: []const u8,
    prevrandao: []const u8,
    gas_limit: []const u8,
    chain_id: []const u8,
};

const JsonAccount = struct {
    address: []const u8,
    balance: []const u8,
    nonce: u64,
    code: []const u8,
    storage: [][]const []const u8,
};

const JsonAccessListEntry = struct {
    address: []const u8,
    storage_keys: [][]const u8,
};

const JsonTx = struct {
    caller: []const u8,
    to: []const u8,
    value: []const u8,
    input: []const u8,
    gas_limit: []const u8,
    gas_price: []const u8,
    nonce: u64,
    access_list: []JsonAccessListEntry = &.{},
};

const JsonWorkload = struct {
    name: []const u8,
    category: []const u8,
    hardfork: []const u8,
    block: JsonBlock,
    accounts: []JsonAccount,
    tx: JsonTx,
};

const CliOptions = struct {
    workload_path: []const u8 = "",
    engine: []const u8 = "guillotine",
    mode: []const u8 = "warm",
    warmup: usize = 20,
    min_samples: usize = 15,
    max_samples: usize = 200,
    target_ms: u64 = 1500,
};

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        var buf: [4096]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &buf);
        stderr.interface.print("guillotine-compare: {s}\n", .{@errorName(err)}) catch std.process.exit(2);
        stderr.interface.flush() catch std.process.exit(2);
        std.process.exit(1);
    };
}

fn parseArgs(init: std.process.Init, allocator: std.mem.Allocator) !CliOptions {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var opts = CliOptions{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--workload")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.workload_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--engine")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.engine = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.mode = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.warmup = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--min-samples")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.min_samples = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--max-samples")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.max_samples = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--target-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.target_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else {
            return error.UnknownArgument;
        }
    }
    if (opts.workload_path.len == 0) return error.MissingWorkload;
    return opts;
}

fn trimHex(s: []const u8) []const u8 {
    var t = std.mem.trim(u8, s, " \t\n\r");
    if (std.mem.startsWith(u8, t, "0x") or std.mem.startsWith(u8, t, "0X")) t = t[2..];
    return t;
}

fn parseHexU64(s: []const u8) !u64 {
    const h = trimHex(s);
    if (h.len == 0) return 0;
    return std.fmt.parseInt(u64, h, 16);
}

fn parseHexU256(s: []const u8) !u256 {
    const h = trimHex(s);
    if (h.len == 0) return 0;
    return std.fmt.parseInt(u256, h, 16);
}

fn parseHexBytes(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const h = trimHex(s);
    if (h.len == 0) return allocator.alloc(u8, 0);
    if (h.len % 2 != 0) return error.OddHexLength;
    const out = try allocator.alloc(u8, h.len / 2);
    errdefer allocator.free(out);
    _ = try std.fmt.hexToBytes(out, h);
    return out;
}

fn parseAddress(s: []const u8) ![20]u8 {
    const h = trimHex(s);
    var out = @as([20]u8, @splat(0));
    if (h.len == 0) return out;
    if (h.len > 40) return error.InvalidAddress;
    var padded = @as([40]u8, @splat('0'));
    @memcpy(padded[40 - h.len ..], h);
    _ = try std.fmt.hexToBytes(&out, &padded);
    return out;
}

fn parseBytes32(s: []const u8) ![32]u8 {
    const h = trimHex(s);
    var out = @as([32]u8, @splat(0));
    if (h.len == 0) return out;
    if (h.len > 64) return error.InvalidBytes32;
    var padded = @as([64]u8, @splat('0'));
    @memcpy(padded[64 - h.len ..], h);
    _ = try std.fmt.hexToBytes(&out, &padded);
    return out;
}

fn run(init: std.process.Init) !void {
    if (builtin.mode != .fast) return error.ReleaseFastRequired;
    const allocator = std.heap.smp_allocator;
    const opts = try parseArgs(init, allocator);

    const file_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, opts.workload_path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(file_bytes);

    const parsed = try std.json.parseFromSlice(JsonWorkload, allocator, file_bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const w = parsed.value;

    const is_jit = std.mem.eql(u8, opts.engine, "guillotine-jit");
    const is_nofusion = std.mem.eql(u8, opts.engine, "guillotine-nofusion");
    const is_default = std.mem.eql(u8, opts.engine, "guillotine");
    if (!is_jit and !is_nofusion and !is_default) return error.UnknownEngine;

    if (std.mem.eql(u8, w.hardfork, "OSAKA")) {
        if (is_jit) {
            try executeWith(init.io, .OSAKA, true, true, w, opts);
        } else if (is_nofusion) {
            try executeWith(init.io, .OSAKA, false, false, w, opts);
        } else {
            try executeWith(init.io, .OSAKA, true, false, w, opts);
        }
    } else if (std.mem.eql(u8, w.hardfork, "PRAGUE")) {
        if (is_jit) {
            try executeWith(init.io, .PRAGUE, true, true, w, opts);
        } else if (is_nofusion) {
            try executeWith(init.io, .PRAGUE, false, false, w, opts);
        } else {
            try executeWith(init.io, .PRAGUE, true, false, w, opts);
        }
    } else if (std.mem.eql(u8, w.hardfork, "CANCUN")) {
        if (is_jit) {
            try executeWith(init.io, .CANCUN, true, true, w, opts);
        } else if (is_nofusion) {
            try executeWith(init.io, .CANCUN, false, false, w, opts);
        } else {
            try executeWith(init.io, .CANCUN, true, false, w, opts);
        }
    } else {
        return error.UnsupportedHardfork;
    }
}

fn executeWith(
    io: std.Io,
    comptime hardfork: evm.Hardfork,
    comptime enable_fusion: bool,
    comptime enable_native_jit: bool,
    w: JsonWorkload,
    opts: CliOptions,
) !void {
    const allocator = std.heap.smp_allocator;
    const EvmType = evm.Evm(.{
        .eips = .{ .hardfork = hardfork },
        .enable_fusion = enable_fusion,
        .loop_quota = instruction_limit,
        .tracer_config = .disabled,
    });
    const Address = evm.Primitives.Address;

    const database = try allocator.create(evm.Database);
    defer allocator.destroy(database);
    database.* = evm.Database.init(allocator);
    defer database.deinit();

    var target_code_bytes: []u8 = &.{};
    defer if (target_code_bytes.len > 0) allocator.free(target_code_bytes);
    const to_bytes = try parseAddress(w.tx.to);

    for (w.accounts) |acc| {
        const addr_bytes = try parseAddress(acc.address);
        const balance = try parseHexU256(acc.balance);
        const code = try parseHexBytes(allocator, acc.code);
        defer allocator.free(code);

        var code_hash = @as([32]u8, @splat(0));
        if (code.len > 0) {
            code_hash = try database.set_code(code);
            if (std.mem.eql(u8, &addr_bytes, &to_bytes)) {
                target_code_bytes = try allocator.dupe(u8, code);
            }
        }
        try database.set_account(addr_bytes, .{
            .balance = balance,
            .nonce = acc.nonce,
            .code_hash = code_hash,
            .storage_root = @as([32]u8, @splat(0)),
        });
        for (acc.storage) |kv| {
            if (kv.len != 2) return error.InvalidStorageEntry;
            const slot = try parseHexU256(kv[0]);
            const val = try parseHexU256(kv[1]);
            try database.set_storage(addr_bytes, slot, val);
        }
    }

    const caller = Address{ .bytes = try parseAddress(w.tx.caller) };
    const to_addr = Address{ .bytes = to_bytes };
    const coinbase = Address{ .bytes = try parseAddress(w.block.coinbase) };
    const value = try parseHexU256(w.tx.value);
    const input = try parseHexBytes(allocator, w.tx.input);
    defer allocator.free(input);
    const tx_gas_limit = try parseHexU64(w.tx.gas_limit);
    const tx_gas_price = try parseHexU256(w.tx.gas_price);

    var block = evm.BlockInfo.init();
    block.number = try parseHexU64(w.block.number);
    block.timestamp = try parseHexU64(w.block.timestamp);
    block.coinbase = coinbase;
    block.base_fee = try parseHexU64(w.block.basefee);
    block.prev_randao = try parseBytes32(w.block.prevrandao);
    block.gas_limit = try parseHexU64(w.block.gas_limit);
    block.chain_id = try parseHexU64(w.block.chain_id);

    const tx_ctx = evm.TransactionContext{
        .gas_limit = tx_gas_limit,
        .coinbase = block.coinbase,
        .chain_id = @intCast(block.chain_id),
        .allow_gas_price_below_base_fee = true,
    };

    const call_params = EvmType.CallParams{ .call = .{
        .caller = caller,
        .to = to_addr,
        .value = value,
        .input = input,
        .gas = tx_gas_limit,
    } };

    const is_cold = std.mem.eql(u8, opts.mode, "cold");
    const is_jit_mode = std.mem.eql(u8, opts.mode, "jit");

    const machine = try allocator.create(EvmType);
    defer allocator.destroy(machine);
    machine.* = try EvmType.init(allocator, database, block, tx_ctx, tx_gas_price, caller);
    defer machine.deinit();

    // Preflight verification
    const preflight_start = std.Io.Clock.awake.now(io);
    var preflight = machine.simulate(call_params);
    const preflight_ns: u64 = @intCast(@max(0, preflight_start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds()));
    defer preflight.deinit(allocator);

    if (!preflight.success) {
        try emitFailure(io, opts, w, preflight.gas_left, tx_gas_limit, preflight.output, "preflight execution reverted or failed");
        return;
    }
    const ref_gas_used = tx_gas_limit - preflight.gas_left;
    const ref_output = try allocator.dupe(u8, preflight.output);
    defer allocator.free(ref_output);

    var compile_ns_opt: ?u64 = null;
    var jit_compiled: bool = false;

    if (comptime enable_native_jit and @hasField(EvmType, "jit_bridge")) {
        if (is_jit_mode) {
            // Trigger hot_threshold=2 compilation and measure compile+run vs steady-state
            const second_start = std.Io.Clock.awake.now(io);
            var second = machine.simulate(call_params);
            const second_ns: u64 = @intCast(@max(0, second_start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds()));
            defer second.deinit(allocator);
            if (!second.success or (tx_gas_limit - second.gas_left) != ref_gas_used or !std.mem.eql(u8, second.output, ref_output)) {
                try emitFailure(io, opts, w, second.gas_left, tx_gas_limit, second.output, "jit warmup mismatch");
                return;
            }
            // Check whether JitCache actually compiled a native program
            for (machine.jit_bridge.cache.entries.items) |entry| {
                if (entry.program != null) {
                    jit_compiled = true;
                    compile_ns_opt = second_ns;
                    break;
                }
            }
        }
    }

    // Adaptive warmup capped so slow workloads don't hang
    const budget_warmup: usize = if (preflight_ns > 0)
        @max(@as(usize, 2), @min(opts.warmup, @as(usize, @intCast(500_000_000 / @max(preflight_ns, 1)))))
    else
        opts.warmup;

    for (0..budget_warmup) |_| {
        if (is_cold) {
            const cold_m = try allocator.create(EvmType);
            defer allocator.destroy(cold_m);
            cold_m.* = try EvmType.init(allocator, database, block, tx_ctx, tx_gas_price, caller);
            defer cold_m.deinit();
            var res = cold_m.simulate(call_params);
            defer res.deinit(allocator);
            if (!res.success or (tx_gas_limit - res.gas_left) != ref_gas_used or !std.mem.eql(u8, res.output, ref_output)) {
                try emitFailure(io, opts, w, res.gas_left, tx_gas_limit, res.output, "cold warmup non-determinism");
                return;
            }
        } else {
            var res = machine.simulate(call_params);
            defer res.deinit(allocator);
            if (!res.success or (tx_gas_limit - res.gas_left) != ref_gas_used or !std.mem.eql(u8, res.output, ref_output)) {
                try emitFailure(io, opts, w, res.gas_left, tx_gas_limit, res.output, "warm warmup non-determinism");
                return;
            }
        }
    }

    // Adaptive timed sampling
    var samples: std.ArrayList(u64) = .empty;
    defer samples.deinit(allocator);
    try samples.ensureTotalCapacity(allocator, opts.max_samples);

    const target_ns: u64 = opts.target_ms * 1_000_000;
    var elapsed_ns: u64 = 0;

    while (samples.items.len < opts.max_samples) {
        if (samples.items.len >= opts.min_samples and elapsed_ns >= target_ns) break;

        var sample_ns: u64 = 0;
        if (is_cold) {
            const cold_m = try allocator.create(EvmType);
            defer allocator.destroy(cold_m);
            const t0 = std.Io.Clock.awake.now(io);
            cold_m.* = try EvmType.init(allocator, database, block, tx_ctx, tx_gas_price, caller);
            var res = cold_m.simulate(call_params);
            sample_ns = @intCast(@max(0, t0.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds()));
            defer cold_m.deinit();
            defer res.deinit(allocator);
            if (!res.success or (tx_gas_limit - res.gas_left) != ref_gas_used or !std.mem.eql(u8, res.output, ref_output)) {
                try emitFailure(io, opts, w, res.gas_left, tx_gas_limit, res.output, "cold measurement non-determinism");
                return;
            }
        } else {
            const t0 = std.Io.Clock.awake.now(io);
            var res = machine.simulate(call_params);
            sample_ns = @intCast(@max(0, t0.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds()));
            defer res.deinit(allocator);
            if (!res.success or (tx_gas_limit - res.gas_left) != ref_gas_used or !std.mem.eql(u8, res.output, ref_output)) {
                try emitFailure(io, opts, w, res.gas_left, tx_gas_limit, res.output, "warm measurement non-determinism");
                return;
            }
        }
        try samples.append(allocator, sample_ns);
        elapsed_ns += sample_ns;
    }

    // Refine Guillotine JIT compile_ns estimate by subtracting steady-state median
    if (compile_ns_opt) |cns| {
        const sorted_tmp = try allocator.dupe(u64, samples.items);
        defer allocator.free(sorted_tmp);
        std.mem.sort(u64, sorted_tmp, {}, std.sort.asc(u64));
        const med = sorted_tmp[sorted_tmp.len / 2];
        compile_ns_opt = if (cns > med) cns - med else 0;
    }

    try emitSuccess(io, allocator, opts, w, ref_gas_used, ref_output, budget_warmup, samples.items, compile_ns_opt, jit_compiled);
}

fn emitFailure(io: std.Io, opts: CliOptions, w: JsonWorkload, gas_left: u64, gas_limit: u64, output: []const u8, reason: []const u8) !void {
    var buf: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;
    try out.print(
        "{{\"engine\":\"{s}\",\"workload\":\"{s}\",\"mode\":\"{s}\",\"status\":\"failed\",\"hardfork\":\"{s}\",\"success\":false,\"gas_used\":{d},\"output_bytes\":{d},\"reason\":\"{s}\"}}\n",
        .{ opts.engine, w.name, opts.mode, w.hardfork, gas_limit - gas_left, output.len, reason },
    );
    try out.flush();
}

fn emitSuccess(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: CliOptions,
    w: JsonWorkload,
    gas_used: u64,
    output: []const u8,
    warmup_runs: usize,
    samples: []const u64,
    compile_ns: ?u64,
    jit_compiled: bool,
) !void {
    const sorted = try allocator.dupe(u64, samples);
    defer allocator.free(sorted);
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));

    const n = sorted.len;
    const median_ns: f64 = if (n % 2 == 1)
        @floatFromInt(sorted[n / 2])
    else
        (@as(f64, @floatFromInt(sorted[n / 2 - 1])) + @as(f64, @floatFromInt(sorted[n / 2]))) / 2.0;
    var sum: u128 = 0;
    for (sorted) |s| sum += s;
    const mean_ns: f64 = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(n));
    const min_ns: f64 = @floatFromInt(sorted[0]);
    const max_ns: f64 = @floatFromInt(sorted[n - 1]);
    const p25_ns: f64 = @floatFromInt(sorted[n / 4]);
    const p75_ns: f64 = @floatFromInt(sorted[(n * 3) / 4]);
    const iqr_ns: f64 = p75_ns - p25_ns;
    const p95_idx = @min(n - 1, (n * 95 + 99) / 100 - 1);
    const p95_ns: f64 = @floatFromInt(sorted[p95_idx]);
    const mgas_per_sec: f64 = if (median_ns > 0) (@as(f64, @floatFromInt(gas_used)) * 1_000.0) / median_ns else 0.0;

    const hex_chars = "0123456789abcdef";
    const out_hex = try allocator.alloc(u8, 2 + output.len * 2);
    defer allocator.free(out_hex);
    out_hex[0] = '0';
    out_hex[1] = 'x';
    for (output, 0..) |b, idx| {
        out_hex[2 + idx * 2] = hex_chars[b >> 4];
        out_hex[2 + idx * 2 + 1] = hex_chars[b & 0x0f];
    }

    var buf: [65536]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;
    try out.print(
        "{{\"engine\":\"{s}\",\"workload\":\"{s}\",\"mode\":\"{s}\",\"status\":\"ok\",\"hardfork\":\"{s}\",\"success\":true,\"gas_used\":{d},\"output_hex\":\"{s}\",\"jit_compiled\":{},\"compile_ns\":",
        .{ opts.engine, w.name, opts.mode, w.hardfork, gas_used, out_hex, jit_compiled },
    );
    if (compile_ns) |cns| {
        try out.print("{d}", .{cns});
    } else {
        try out.writeAll("null");
    }
    try out.print(
        ",\"warmup_runs\":{d},\"sample_count\":{d},\"median_ns\":{d:.2},\"mean_ns\":{d:.2},\"min_ns\":{d:.2},\"max_ns\":{d:.2},\"p25_ns\":{d:.2},\"p75_ns\":{d:.2},\"iqr_ns\":{d:.2},\"p95_ns\":{d:.2},\"mgas_per_sec\":{d:.2},\"samples_ns\":[",
        .{ warmup_runs, n, median_ns, mean_ns, min_ns, max_ns, p25_ns, p75_ns, iqr_ns, p95_ns, mgas_per_sec },
    );
    for (samples, 0..) |s, idx| {
        if (idx > 0) try out.writeByte(',');
        try out.print("{d}", .{s});
    }
    try out.writeAll("]}\n");
    try out.flush();
}
