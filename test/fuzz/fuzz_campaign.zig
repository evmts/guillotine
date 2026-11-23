//! Multi-Threaded, Corpus-Backed, Havoc-Mutating Cross-Platform Fuzz Campaign Runner
//!
//! Complements Zig's Linux-only `--fuzz` coverage-guided engine by running continuous,
//! parallel, structure-aware + havoc-mutating fuzzing campaigns across ALL Guillotine
//! targets on BOTH macOS and Linux (including 48-core bare-metal Latitude servers).
//!
//! Features:
//! - Runs all 10 fuzz target suites with weighted scheduling
//! - Havoc byte mutator (bit flips, byte flips, arithmetic +/-1..35, interesting EVM opcodes/constants,
//!   block splice, insertion, deletion, duplication) over an evolving in-memory corpus
//! - Multi-threaded execution (`--threads=N`)
//! - Time-bounded (`--seconds=N`) or iteration-bounded (`--iters=N`)
//! - Reproducible seeds (`--seed=S`)
//! - Saves reproducing input bytes to `.fuzz-crashes/<target>_seed<S>.bin` on any failure
//!
//! Example:
//!   zig build fuzz-campaign -- --seconds=60 --threads=8
//!   zig build fuzz-campaign -- --iters=20000 --target=differential --seed=42

const std = @import("std");

pub const std_options: std.Options = .{
    .log_level = .err,
};

const bytecode_fuzz = @import("bytecode_fuzz.zig");
const stack_fuzz = @import("stack_fuzz.zig");
const memory_fuzz = @import("memory_fuzz.zig");
const storage_journal_fuzz = @import("storage_journal_fuzz.zig");
const arithmetic_u256_fuzz = @import("arithmetic_u256_fuzz.zig");
const differential_evm_fuzz = @import("differential_evm_fuzz.zig");
const precompiles_fuzz = @import("precompiles_fuzz.zig");
const trie_fuzz = @import("trie_fuzz.zig");
const eip_hardfork_fuzz = @import("eip_hardfork_fuzz.zig");
const c_api_fuzz = @import("c_api_fuzz.zig");

const TargetFn = *const fn (void, []const u8) anyerror!void;

const TargetSpec = struct {
    name: []const u8,
    weight: u32,
    max_len: usize,
    func: TargetFn,
};

const TARGETS = [_]TargetSpec{
    .{ .name = "differential_evm", .weight = 25, .max_len = 256, .func = differential_evm_fuzz.fuzzDifferentialFusionAndSimulate },
    .{ .name = "differential_hardforks", .weight = 10, .max_len = 160, .func = differential_evm_fuzz.fuzzMultiHardforkDifferential },
    .{ .name = "differential_create", .weight = 8, .max_len = 160, .func = differential_evm_fuzz.fuzzCreateAndCreate2Parity },
    .{ .name = "arithmetic_u256", .weight = 14, .max_len = 128, .func = arithmetic_u256_fuzz.fuzzBinaryAndTernaryArithmetic },
    .{ .name = "bytecode_oracle", .weight = 8, .max_len = 512, .func = bytecode_fuzz.fuzzBytecodeJumpdestOracle },
    .{ .name = "bytecode_fusions", .weight = 8, .max_len = 256, .func = bytecode_fuzz.fuzzStructuredFusionPatterns },
    .{ .name = "stack_model", .weight = 6, .max_len = 256, .func = stack_fuzz.fuzzDefaultStack },
    .{ .name = "stack_overflow", .weight = 5, .max_len = 192, .func = stack_fuzz.fuzzSmallStackOverflow },
    .{ .name = "memory_model", .weight = 8, .max_len = 192, .func = memory_fuzz.fuzzMemoryModel },
    .{ .name = "storage_db", .weight = 8, .max_len = 192, .func = storage_journal_fuzz.fuzzDatabaseSnapshotsAndViews },
    .{ .name = "storage_journal", .weight = 6, .max_len = 192, .func = storage_journal_fuzz.fuzzJournalOriginalStorageIndex },
    .{ .name = "access_list", .weight = 4, .max_len = 128, .func = storage_journal_fuzz.fuzzAccessListWarmCold },
    .{ .name = "precompiles_hash", .weight = 5, .max_len = 256, .func = precompiles_fuzz.fuzzSha256AndIdentityAndRipemd },
    .{ .name = "precompiles_modexp", .weight = 6, .max_len = 128, .func = precompiles_fuzz.fuzzModExpOracle },
    .{ .name = "precompiles_bn254", .weight = 4, .max_len = 256, .func = precompiles_fuzz.fuzzBn254GroupAxiomsAndAdversarial },
    .{ .name = "precompiles_blake2_bls", .weight = 5, .max_len = 256, .func = precompiles_fuzz.fuzzBlake2fAndEcrecoverAndBls },
    .{ .name = "trie_mpt", .weight = 6, .max_len = 192, .func = trie_fuzz.fuzzMerkleTrieModelAndOrderIndependence },
    .{ .name = "eip_blob_1559", .weight = 4, .max_len = 64, .func = eip_hardfork_fuzz.fuzzBlobGasAndEip1559Invariants },
    .{ .name = "eip_sstore_refunds", .weight = 4, .max_len = 64, .func = eip_hardfork_fuzz.fuzzSstoreGasAndRefundAcrossHardforks },
    .{ .name = "eip_7702", .weight = 4, .max_len = 64, .func = eip_hardfork_fuzz.fuzzEip7702AuthorizationProcessor },
    .{ .name = "c_api_ffi", .weight = 6, .max_len = 160, .func = c_api_fuzz.fuzzCApiLifecycleAndExecution },
};

const INTERESTING_BYTES = [_]u8{
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b,
    0x10, 0x11, 0x14, 0x15, 0x16, 0x19, 0x1b, 0x1c, 0x1d, 0x20, 0x35, 0x37,
    0x39, 0x3d, 0x3e, 0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
    0x59, 0x5a, 0x5b, 0x5c, 0x5d, 0x5e, 0x5f, 0x60, 0x61, 0x63, 0x7f, 0x80,
    0x81, 0x90, 0xa1, 0xef, 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xfa, 0xfd,
    0xfe, 0xff,
};

fn mutateHavoc(rng: std.Random, buf: []u8, cur_len: usize, max_len: usize) usize {
    var len = cur_len;
    if (len == 0) {
        len = @min(max_len, rng.uintLessThan(usize, 32) + 1);
        rng.bytes(buf[0..len]);
        return len;
    }

    const mutations = rng.uintLessThan(usize, 6) + 1;
    for (0..mutations) |_| {
        switch (rng.uintLessThan(u8, 8)) {
            0 => { // Bit flip
                const idx = rng.uintLessThan(usize, len);
                buf[idx] ^= @as(u8, 1) << rng.uintLessThan(u3, 8);
            },
            1 => { // Interesting EVM byte overwrite
                const idx = rng.uintLessThan(usize, len);
                buf[idx] = INTERESTING_BYTES[rng.uintLessThan(usize, INTERESTING_BYTES.len)];
            },
            2 => { // Arithmetic add/sub
                const idx = rng.uintLessThan(usize, len);
                const delta: u8 = rng.uintLessThan(u8, 35) + 1;
                buf[idx] = if (rng.boolean()) buf[idx] +% delta else buf[idx] -% delta;
            },
            3 => { // Random byte overwrite
                const idx = rng.uintLessThan(usize, len);
                buf[idx] = rng.int(u8);
            },
            4 => { // Insert random bytes
                if (len < max_len) {
                    const add = @min(max_len - len, rng.uintLessThan(usize, 12) + 1);
                    const pos = rng.uintLessThan(usize, len + 1);
                    std.mem.copyBackwards(u8, buf[pos + add .. len + add], buf[pos..len]);
                    rng.bytes(buf[pos .. pos + add]);
                    len += add;
                }
            },
            5 => { // Delete slice
                if (len > 4) {
                    const del = @min(len - 1, rng.uintLessThan(usize, 12) + 1);
                    const pos = rng.uintLessThan(usize, len - del);
                    std.mem.copyForwards(u8, buf[pos .. len - del], buf[pos + del .. len]);
                    len -= del;
                }
            },
            6 => { // Duplicate internal chunk (creates loops/repeated opcodes)
                if (len >= 2 and len < max_len) {
                    const chunk = @min(@min(len, max_len - len), rng.uintLessThan(usize, 16) + 1);
                    const src = rng.uintLessThan(usize, len - chunk + 1);
                    @memcpy(buf[len .. len + chunk], buf[src .. src + chunk]);
                    len += chunk;
                }
            },
            else => { // Fresh random reset (keeps exploration from getting trapped)
                if (rng.uintLessThan(u8, 8) == 0) {
                    len = @min(max_len, rng.uintLessThan(usize, max_len) + 1);
                    rng.bytes(buf[0..len]);
                }
            },
        }
    }
    return len;
}

const WorkerConfig = struct {
    worker_id: usize,
    base_seed: u64,
    max_iters: u64,
    end_ns: ?i128,
    filter: ?[]const u8,
    total_execs: *std.atomic.Value(u64),
    failures: *std.atomic.Value(u64),
    stop_flag: *std.atomic.Value(bool),
};

fn saveCrash(target_name: []const u8, seed: u64, iter: u64, input: []const u8, err: anyerror) void {
    std.fs.cwd().makeDir(".fuzz-crashes") catch {};
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, ".fuzz-crashes/{s}_seed{d}_iter{d}.bin", .{ target_name, seed, iter }) catch return;
    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();
    file.writeAll(input) catch {};

    std.debug.print(
        "\n[FUZZ FAILURE] target={s} err={s} seed={d} iter={d} len={d} saved={s}\n  hex=",
        .{ target_name, @errorName(err), seed, iter, input.len, path },
    );
    for (input[0..@min(input.len, 128)]) |b| {
        std.debug.print("{x:0>2}", .{b});
    }
    std.debug.print("\n", .{});
}

fn workerMain(cfg: WorkerConfig) void {
    var prng = std.Random.DefaultPrng.init(cfg.base_seed ^ (@as(u64, cfg.worker_id) *% 0x9e3779b97f4a7c15));
    const rng = prng.random();

    // Build active target list respecting --target filter
    var active_indices: [TARGETS.len]usize = undefined;
    var active_count: usize = 0;
    var total_weight: u32 = 0;

    for (TARGETS, 0..) |t, idx| {
        if (cfg.filter) |flt| {
            if (std.mem.indexOf(u8, t.name, flt) == null) continue;
        }
        // C FFI global pool uses shared mutex; run on worker 0 to avoid pool contention spikes
        if (std.mem.eql(u8, t.name, "c_api_ffi") and cfg.worker_id != 0) continue;
        active_indices[active_count] = idx;
        active_count += 1;
        total_weight += t.weight;
    }
    if (active_count == 0) return;

    // Small per-worker evolving corpus ring (16 slots x 512 bytes)
    var corpus: [16][512]u8 = undefined;
    var corpus_lens = [_]usize{0} ** 16;
    for (0..16) |s| {
        const l = rng.uintLessThan(usize, 64) + 4;
        rng.bytes(corpus[s][0..l]);
        corpus_lens[s] = l;
    }

    var work_buf: [512]u8 = undefined;
    var iter: u64 = 0;

    while (!cfg.stop_flag.load(.acquire)) {
        if (cfg.max_iters > 0 and iter >= cfg.max_iters) break;
        if (cfg.end_ns) |deadline| {
            if ((iter & 0x3f) == 0 and std.time.nanoTimestamp() >= deadline) break;
        }

        // Weighted target selection
        var pick = rng.uintLessThan(u32, total_weight);
        var chosen_idx = active_indices[0];
        for (active_indices[0..active_count]) |t_idx| {
            if (pick < TARGETS[t_idx].weight) {
                chosen_idx = t_idx;
                break;
            }
            pick -= TARGETS[t_idx].weight;
        }
        const target = TARGETS[chosen_idx];

        // Pick corpus entry & mutate
        const slot = rng.uintLessThan(usize, corpus.len);
        const seed_len = @min(corpus_lens[slot], target.max_len);
        @memcpy(work_buf[0..seed_len], corpus[slot][0..seed_len]);
        const mutated_len = mutateHavoc(rng, &work_buf, seed_len, target.max_len);

        // Execute target!
        target.func({}, work_buf[0..mutated_len]) catch |err| {
            saveCrash(target.name, cfg.base_seed, iter, work_buf[0..mutated_len], err);
            _ = cfg.failures.fetchAdd(1, .acq_rel);
            cfg.stop_flag.store(true, .release);
            return;
        };

        // Periodically retain mutated input in corpus ring for multi-generation evolution
        if ((iter & 0x1f) == 0) {
            const dst_slot = rng.uintLessThan(usize, corpus.len);
            @memcpy(corpus[dst_slot][0..mutated_len], work_buf[0..mutated_len]);
            corpus_lens[dst_slot] = mutated_len;
        }

        iter += 1;
        _ = cfg.total_execs.fetchAdd(1, .monotonic);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var seconds: u64 = 10;
    var max_iters: u64 = 0;
    var threads: usize = 1;
    var seed: u64 = @intCast(@as(u128, @bitCast(std.time.nanoTimestamp())) & 0xffff_ffff_ffff_ffff);
    var filter: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--seconds=")) {
            seconds = try std.fmt.parseInt(u64, arg["--seconds=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--iters=")) {
            max_iters = try std.fmt.parseInt(u64, arg["--iters=".len..], 10);
            seconds = 0;
        } else if (std.mem.startsWith(u8, arg, "--threads=")) {
            threads = @max(1, try std.fmt.parseInt(usize, arg["--threads=".len..], 10));
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--target=")) {
            filter = arg["--target=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Guillotine Cross-Platform Multi-Threaded Fuzz Campaign Runner
                \\
                \\Options:
                \\  --seconds=N   Run for N seconds (default: 10)
                \\  --iters=N     Run N iterations per thread (overrides --seconds)
                \\  --threads=N   Number of worker threads (default: 1)
                \\  --seed=S      Deterministic PRNG seed
                \\  --target=STR  Substring filter on target name
                \\
                \\Targets ({d}):
                \\
            , .{TARGETS.len});
            for (TARGETS) |t| {
                std.debug.print("  - {s} (weight={d})\n", .{ t.name, t.weight });
            }
            return;
        }
    }

    const start_ns = std.time.nanoTimestamp();
    const end_ns: ?i128 = if (seconds > 0) start_ns + @as(i128, seconds) * std.time.ns_per_s else null;

    var total_execs = std.atomic.Value(u64).init(0);
    var failures = std.atomic.Value(u64).init(0);
    var stop_flag = std.atomic.Value(bool).init(false);

    std.debug.print(
        "[guillotine-fuzz] starting campaign: targets={d} threads={d} seconds={d} iters={d} seed={d} filter={s}\n",
        .{ TARGETS.len, threads, seconds, max_iters, seed, filter orelse "*" },
    );

    const handles = try allocator.alloc(std.Thread, threads);
    defer allocator.free(handles);

    var spawned: usize = 0;
    for (0..threads) |tid| {
        const cfg = WorkerConfig{
            .worker_id = tid,
            .base_seed = seed,
            .max_iters = max_iters,
            .end_ns = end_ns,
            .filter = filter,
            .total_execs = &total_execs,
            .failures = &failures,
            .stop_flag = &stop_flag,
        };
        handles[tid] = try std.Thread.spawn(.{}, workerMain, .{cfg});
        spawned += 1;
    }

    for (handles[0..spawned]) |h| {
        h.join();
    }

    const elapsed_ms: f64 = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_ns)) / 1_000_000.0;
    const execs = total_execs.load(.acquire);
    const exec_per_sec: f64 = if (elapsed_ms > 0) (@as(f64, @floatFromInt(execs)) * 1000.0 / elapsed_ms) else 0;
    const fail_count = failures.load(.acquire);

    std.debug.print(
        "[guillotine-fuzz] finished: execs={d} elapsed={d:.1}ms rate={d:.0} exec/s failures={d}\n",
        .{ execs, elapsed_ms, exec_per_sec, fail_count },
    );

    if (fail_count > 0) {
        std.process.exit(1);
    }
}
