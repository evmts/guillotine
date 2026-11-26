//! Zig-vs-Lean differential fuzz suite.
//!
//! Streams deterministic, seeded fuzz vectors through Guillotine (Zig) and through the
//! executable Lean 4 reference specification (`verify/lean/GuillotineSpec`, served by
//! `lake exe guillotine-lean-ref` as one persistent child process) and requires
//! byte-identical answers.
//!
//! Subsystems:
//!   1. 256-bit word operations: EVM opcode execution (fusion on and off) and
//!      `src/core/verified_ops.zig` reference/fast pairs.
//!   2. Fork-aware gas and refunds on all 15 hardforks: per-fork static gas, transaction
//!      intrinsic/floor gas, refund cap, blob fee, MODEXP pricing, memory expansion, and
//!      SSTORE/SLOAD/CALL/BALANCE/SELFDESTRUCT metering measured by executing on each fork.
//!   3. Bytecode analysis: JUMPDEST bitmap, PUSH immediates (zero-padded when truncated),
//!      basic-block gas and stack bounds, straight-line fusion equivalence.
//!   4. Full EVM execution, fusion on and off, against the Lean interpreter.
//!   5. Base / OP Stack: FastLZ, L1 data fee, operator fee, settlement, deposits,
//!      schedules, BN254 pairing input limits.
//!   6. RLP encoding and decoding.
//!
//! Usage:
//!   zig build test-lean-diff -j4
//!   FUZZ_SEED=42 FUZZ_ITERS=10000 zig build test-lean-diff -j4
//!
//! Every Guillotine call runs in a forked child, so a crash is reported as a mismatch
//! (`CRASH signal <n>`); set `LEAN_DIFF_SHOW_CRASH=1` to keep its panic trace.
//!
//! `FUZZ_ITERS` (default 2000) scales every subsystem; the default meets the minimum
//! vector counts of every subsystem. Any mismatch is printed with a minimized
//! reproducer (the exact oracle request line) and the process exits non-zero.

const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

pub const std_options: std.Options = .{ .log_level = .err };

/// A panic inside an isolated Guillotine call reports its message to the parent and
/// exits at once; every other panic takes the default path with a stack trace.
pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (child_result_fd >= 0 and !show_crashes) {
        _ = libc.write(child_result_fd, msg.ptr, msg.len);
        libc._exit(panic_exit_code);
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

const Allocator = std.mem.Allocator;
const Address = primitives.Address.Address;
const Database = evm.Database;
const Hardfork = evm.Hardfork;
const verified_ops = evm.verified_ops;
const Rlp = primitives.Rlp;
const layer2 = evm.layer2;

const max_u256: u256 = std.math.maxInt(u256);

// ---------------------------------------------------------------------------------------
// Shared world (mirrors `GuillotineSpec/Main.lean`)
// ---------------------------------------------------------------------------------------

const FORKS = [_]Hardfork{
    .FRONTIER, .HOMESTEAD,      .TANGERINE_WHISTLE, .SPURIOUS_DRAGON, .BYZANTIUM,
    .CONSTANTINOPLE, .PETERSBURG, .ISTANBUL,        .BERLIN,          .LONDON,
    .MERGE,    .SHANGHAI,       .CANCUN,            .PRAGUE,          .OSAKA,
};
const FORK_CANCUN: usize = 12;
const FORK_OSAKA: usize = 14;

/// Forks that also run with bytecode fusion disabled.
fn hasFusionOff(comptime fork: Hardfork) bool {
    return fork == .CANCUN or fork == .OSAKA;
}

fn forkHasFusionOff(index: usize) bool {
    return index == FORK_CANCUN or index == FORK_OSAKA;
}

/// Fork that introduced an opcode (null: present since Frontier). Mirrors
/// `GuillotineSpec.Bytecode.introducedIn` for the opcodes the generators emit.
fn introducedIn(opcode: u8) ?Hardfork {
    return switch (opcode) {
        0xf4 => .HOMESTEAD,
        0x3d, 0x3e, 0xfa, 0xfd => .BYZANTIUM,
        0x1b, 0x1c, 0x1d, 0x3f, 0xf5 => .CONSTANTINOPLE,
        0x46, 0x47 => .ISTANBUL,
        0x48 => .LONDON,
        0x5f => .SHANGHAI,
        0x49, 0x4a, 0x5c, 0x5d, 0x5e => .CANCUN,
        0x1e => .OSAKA,
        else => null,
    };
}

fn available(fork_index: usize, opcode: u8) bool {
    const since = introducedIn(opcode) orelse return true;
    return FORKS[fork_index].isAtLeast(since);
}

fn EvmFor(comptime fork: Hardfork, comptime fusion: bool) type {
    return evm.Evm(.{ .enable_fusion = fusion, .eips = .{ .hardfork = fork } });
}

fn addr(comptime value: u24) Address {
    var bytes: [20]u8 = @splat(0);
    bytes[17] = @truncate(value >> 16);
    bytes[18] = @truncate(value >> 8);
    bytes[19] = @truncate(value);
    return .{ .bytes = bytes };
}

const ORIGIN = addr(0xaaaa01);
const CONTRACT_A = addr(0xc0de0a);
const CONTRACT_B = addr(0xc0de0b);
const EOA = addr(0xe0a001);
const DEAD = addr(0xdead01);
const COINBASE = addr(0xc01b01);
const REPORT_ADDRS = [_]Address{ ORIGIN, CONTRACT_A, CONTRACT_B, EOA, DEAD, COINBASE };
const ORIGIN_BALANCE: u256 = 1_000_000_000_000_000_000_000_000;
const EOA_BALANCE: u256 = 12345;
const PREV_RANDAO: u256 = 0x1122334455667788990011223344556677889900112233445566778899001122;
const PROBE_SLOTS = [_]u256{ 0, 1, 2, 3, 4, 5, 6, 7, max_u256, 1 << 255, 0xdeadbeef, 1 << 160 };
const ZERO32: [32]u8 = @splat(0);

// ---------------------------------------------------------------------------------------
// Request / answer lines
// ---------------------------------------------------------------------------------------

/// Space-separated token line in the oracle's wire format.
const Line = struct {
    buf: std.ArrayList(u8) = .empty,
    a: Allocator,

    fn init(a: Allocator) Line {
        return .{ .a = a };
    }

    fn sep(self: *Line) !void {
        if (self.buf.items.len > 0) try self.buf.append(self.a, ' ');
    }

    fn tok(self: *Line, s: []const u8) !void {
        try self.sep();
        try self.buf.appendSlice(self.a, s);
    }

    fn num(self: *Line, value: u256) !void {
        try self.sep();
        const rendered = try std.fmt.allocPrint(self.a, "{x}", .{value});
        try self.buf.appendSlice(self.a, rendered);
    }

    fn opt(self: *Line, value: ?u256) !void {
        if (value) |v| return self.num(v);
        try self.tok("n");
    }

    fn flag(self: *Line, value: bool) !void {
        try self.tok(if (value) "1" else "0");
    }

    fn signed(self: *Line, value: i128) !void {
        try self.sep();
        const rendered = try std.fmt.allocPrint(self.a, "{d}", .{value});
        try self.buf.appendSlice(self.a, rendered);
    }

    fn bytes(self: *Line, data: []const u8) !void {
        try self.sep();
        try appendHex(&self.buf, self.a, data);
    }

    /// `s<hex>`: an RLP string token.
    fn rlpStr(self: *Line, data: []const u8) !void {
        try self.sep();
        try self.buf.append(self.a, 's');
        try appendHex(&self.buf, self.a, data);
    }

    fn str(self: *const Line) []const u8 {
        return self.buf.items;
    }
};

fn appendHex(buf: *std.ArrayList(u8), a: Allocator, data: []const u8) !void {
    if (data.len == 0) return buf.append(a, '-');
    const digits = "0123456789abcdef";
    try buf.ensureUnusedCapacity(a, data.len * 2);
    for (data) |byte| {
        buf.appendAssumeCapacity(digits[byte >> 4]);
        buf.appendAssumeCapacity(digits[byte & 0x0f]);
    }
}

fn parseHexBytes(a: Allocator, hex: []const u8) ![]u8 {
    if (std.mem.eql(u8, hex, "-")) return a.alloc(u8, 0);
    if (hex.len % 2 != 0) return error.BadHex;
    const out = try a.alloc(u8, hex.len / 2);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

// ---------------------------------------------------------------------------------------
// Crash isolation
// ---------------------------------------------------------------------------------------

const libc = struct {
    extern "c" fn fork() c_int;
    extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
    extern "c" fn _exit(code: c_int) noreturn;
    extern "c" fn pipe(fds: *[2]c_int) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn dup2(old: c_int, new: c_int) c_int;
    extern "c" fn alarm(seconds: c_uint) c_uint;
    extern "c" fn clock_gettime(clock: c_int, ts: *Timespec) c_int;
    const Timespec = extern struct { sec: i64, nsec: i64 };
};

fn monotonicMillis() u64 {
    var ts: libc.Timespec = .{ .sec = 0, .nsec = 0 };
    // CLOCK_MONOTONIC: 1 on Linux, 6 on macOS.
    _ = libc.clock_gettime(if (@import("builtin").os.tag == .linux) 1 else 6, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// Wall-clock time of the slowest isolated Guillotine call so far, for the summary.
var slowest_call_ms: u64 = 0;
var slow_calls: u64 = 0;
const slow_call_threshold_ms: u64 = 1000;

/// Seconds one isolated Guillotine call may run before it is reported as hung (`CRASH signal 14`).
const call_timeout_seconds: c_uint = 60;

/// Set by `LEAN_DIFF_SHOW_CRASH=1`: keep the panic trace of a crashing Guillotine call.
var show_crashes: bool = false;

/// Write end of the result pipe inside an isolated child; -1 in the parent.
var child_result_fd: c_int = -1;
const panic_exit_code: c_int = 86;

/// Run `work` in a forked child and return the text it produced. A crash (panic, abort,
/// segfault) in Guillotine becomes the answer `CRASH signal <n>` instead of ending the
/// campaign, so it is reported and minimized like any other mismatch (a Zig panic as
/// `CRASH panic: <message>`). A call that runs
/// longer than `call_timeout_seconds` is killed by SIGALRM and reported the same way.
fn isolated(a: Allocator, context: anytype, comptime work: fn (@TypeOf(context), Allocator) anyerror![]const u8) ![]const u8 {
    const started = monotonicMillis();
    defer {
        const elapsed = monotonicMillis() - started;
        if (elapsed > slowest_call_ms) slowest_call_ms = elapsed;
        if (elapsed >= slow_call_threshold_ms) slow_calls += 1;
    }
    var fds: [2]c_int = undefined;
    if (libc.pipe(&fds) != 0) return error.PipeFailed;
    const pid = libc.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = libc.close(fds[0]);
        child_result_fd = fds[1];
        _ = libc.alarm(call_timeout_seconds);
        if (!show_crashes) {
            const sink = libc.open("/dev/null", 1);
            if (sink >= 0) _ = libc.dup2(sink, 2);
        }
        const produced = work(context, a) catch |err| @errorName(err);
        child_result_fd = -1;
        var sent: usize = 0;
        while (sent < produced.len) {
            const n = libc.write(fds[1], produced.ptr + sent, produced.len - sent);
            if (n <= 0) libc._exit(3);
            sent += @intCast(n);
        }
        libc._exit(0);
    }
    _ = libc.close(fds[1]);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = libc.read(fds[0], &chunk, chunk.len);
        if (n <= 0) break;
        try out.appendSlice(a, chunk[0..@intCast(n)]);
    }
    _ = libc.close(fds[0]);
    var status: c_int = 0;
    if (libc.waitpid(pid, &status, 0) < 0) return error.WaitFailed;
    const signal = status & 0x7f;
    if (signal != 0) return std.fmt.allocPrint(a, "CRASH signal {d}", .{signal});
    const code = (status >> 8) & 0xff;
    if (code == panic_exit_code) return std.fmt.allocPrint(a, "CRASH panic: {s}", .{out.items});
    if (code != 0) return std.fmt.allocPrint(a, "CRASH exit code {d}", .{code});
    return out.items;
}

// ---------------------------------------------------------------------------------------
// Lean oracle (persistent child process)
// ---------------------------------------------------------------------------------------

const Oracle = struct {
    io: std.Io,
    child: std.process.Child,
    writer: std.Io.File.Writer,
    reader: std.Io.File.Reader,
    requests: u64 = 0,

    fn start(self: *Oracle, io: std.Io, gpa: Allocator, exe_path: []const u8) !void {
        self.io = io;
        self.requests = 0;
        self.child = try std.process.spawn(io, .{
            .argv = &.{exe_path},
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        const write_buffer = try gpa.alloc(u8, 1 << 16);
        const read_buffer = try gpa.alloc(u8, 1 << 24);
        self.writer = self.child.stdin.?.writerStreaming(io, write_buffer);
        self.reader = self.child.stdout.?.readerStreaming(io, read_buffer);
        const pong = try self.ask("PING");
        if (!std.mem.eql(u8, pong, "PONG")) return error.OracleHandshakeFailed;
    }

    /// Send one request line, return the answer line (valid until the next `ask`).
    fn ask(self: *Oracle, request: []const u8) ![]const u8 {
        self.requests += 1;
        const w = &self.writer.interface;
        try w.writeAll(request);
        try w.writeAll("\n");
        try w.flush();
        const line = try self.reader.interface.takeDelimiterInclusive('\n');
        return line[0 .. line.len - 1];
    }

    fn stop(self: *Oracle) void {
        self.child.stdin.?.close(self.io);
        self.child.stdin = null;
        _ = self.child.wait(self.io) catch {};
    }
};

// ---------------------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------------------

const Subsystem = enum {
    word256,
    gas,
    bytecode,
    evm_exec,
    layer2_base,
    rlp,

    fn title(self: Subsystem) []const u8 {
        return switch (self) {
            .word256 => "1. 256-bit word ops",
            .gas => "2. Fork-aware gas/refunds",
            .bytecode => "3. Bytecode analysis",
            .evm_exec => "4. EVM execution",
            .layer2_base => "5. Base / OP Stack L2",
            .rlp => "6. RLP",
        };
    }

    fn minimum(self: Subsystem) u64 {
        return switch (self) {
            .word256 => 20_000,
            .gas => 10_000,
            .bytecode => 5_000,
            .evm_exec => 2_000,
            .layer2_base => 5_000,
            .rlp => 5_000,
        };
    }
};

const SUBSYSTEMS = [_]Subsystem{ .word256, .gas, .bytecode, .evm_exec, .layer2_base, .rlp };
const subsystem_count = SUBSYSTEMS.len;
const max_reports_per_class = 2;

const ClassInfo = struct { count: u64 = 0, forks: u16 = 0 };

const Suite = struct {
    gpa: Allocator,
    oracle: *Oracle,
    vectors: [subsystem_count]u64 = @splat(0),
    mismatches: [subsystem_count]u64 = @splat(0),
    /// Mismatch classes already printed, with their counts and the forks they hit.
    classes: std.StringArrayHashMapUnmanaged(ClassInfo) = .empty,
    seed: u64,
    iters: u64,

    fn count(self: *Suite, subsystem: Subsystem, n: u64) void {
        self.vectors[@intFromEnum(subsystem)] += n;
    }

    /// Record a mismatch. `class` groups mismatches with the same cause so that only the
    /// first few of each are printed in full.
    fn mismatch(self: *Suite, subsystem: Subsystem, class: []const u8, request: []const u8, lean: []const u8, zig: []const u8) !void {
        return self.mismatchOn(subsystem, class, null, request, lean, zig);
    }

    /// As `mismatch`, also recording the hardfork the vector ran on.
    fn mismatchOn(self: *Suite, subsystem: Subsystem, class: []const u8, fork_index: ?usize, request: []const u8, lean: []const u8, zig: []const u8) !void {
        self.mismatches[@intFromEnum(subsystem)] += 1;
        const gop = try self.classes.getOrPut(self.gpa, class);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, class);
            gop.value_ptr.* = .{};
        }
        gop.value_ptr.count += 1;
        if (fork_index) |index| gop.value_ptr.forks |= @as(u16, 1) << @intCast(index);
        if (gop.value_ptr.count > max_reports_per_class) return;
        std.debug.print(
            \\
            \\MISMATCH [{s}] {s}
            \\  reproduce: echo '{s}' | verify/lean/.lake/build/bin/guillotine-lean-ref
            \\  lean: {s}
            \\  zig:  {s}
            \\
        , .{ subsystem.title(), class, request, lean, zig });
    }

    /// Number of mismatches already recorded for a class.
    fn classCount(self: *const Suite, class: []const u8) u64 {
        const info = self.classes.get(class) orelse return 0;
        return info.count;
    }

    /// Ask the oracle and compare with Guillotine's answer.
    fn check(self: *Suite, subsystem: Subsystem, class: []const u8, request: []const u8, zig: []const u8) !void {
        self.count(subsystem, 1);
        const lean = try self.oracle.ask(request);
        if (!std.mem.eql(u8, lean, zig)) try self.mismatch(subsystem, class, request, lean, zig);
    }

    fn total(values: [subsystem_count]u64) u64 {
        var sum: u64 = 0;
        for (values) |v| sum += v;
        return sum;
    }
};

// ---------------------------------------------------------------------------------------
// Random values
// ---------------------------------------------------------------------------------------

const EDGE_WORDS = [_]u256{
    0,                1,                  2,                    3,                  7,
    8,                15,                 16,                   31,                 32,
    33,               0x7f,               0x80,                 0xff,               0x100,
    255,              256,                257,                  0xffff,             1 << 32,
    (1 << 64) - 1,    1 << 64,            (1 << 127) - 1,       1 << 127,           (1 << 128) - 1,
    1 << 128,         (1 << 128) + 1,     (1 << 160) - 1,       1 << 160,           (1 << 255) - 1,
    1 << 255,         (1 << 255) + 1,     max_u256 - 1,         max_u256,           max_u256 - 0xff,
    0x8000,           0x7fff,             0x800000,             0x7fffff,           (1 << 248) - 1,
    1 << 248,         0xff << 248,        0x80 << 248,          0x7f << 248,        (1 << 256 - 8) + 1,
};

fn randomWord(r: std.Random) u256 {
    return switch (r.uintLessThan(u8, 10)) {
        0, 1, 2 => EDGE_WORDS[r.uintLessThan(usize, EDGE_WORDS.len)],
        3, 4 => r.int(u256),
        5 => r.int(u256) >> r.int(u8),
        6 => @as(u256, 1) << r.int(u8),
        7 => (@as(u256, 1) << r.int(u8)) -% 1,
        8 => r.uintLessThan(u256, 300),
        else => max_u256 - r.uintLessThan(u256, 300),
    };
}

fn randomBytes(r: std.Random, a: Allocator, len: usize) ![]u8 {
    const out = try a.alloc(u8, len);
    r.bytes(out);
    return out;
}

// ---------------------------------------------------------------------------------------
// Assembler
// ---------------------------------------------------------------------------------------

const Asm = struct {
    code: std.ArrayList(u8) = .empty,
    a: Allocator,
    /// PUSH0 is available (Shanghai and later).
    push0: bool = true,

    fn op(self: *Asm, opcode: u8) !void {
        try self.code.append(self.a, opcode);
    }

    fn raw(self: *Asm, data: []const u8) !void {
        try self.code.appendSlice(self.a, data);
    }

    /// PUSH with the smallest immediate that holds `value`.
    fn push(self: *Asm, value: u256) !void {
        if (value == 0 and self.push0) return self.op(0x5f);
        var n: u8 = 1;
        while (n < 32 and (value >> (n * 8)) != 0) n += 1;
        try self.pushN(n, value);
    }

    /// PUSHn with exactly `n` immediate bytes.
    fn pushN(self: *Asm, n: u8, value: u256) !void {
        try self.op(0x5f + n);
        var i: u8 = n;
        while (i > 0) : (i -= 1) {
            const shift: u8 = (i - 1) * 8;
            try self.op(@truncate(value >> shift));
        }
    }

    fn pushAddr(self: *Asm, address: Address) !void {
        try self.op(0x73);
        try self.raw(&address.bytes);
    }

    fn pc(self: *const Asm) usize {
        return self.code.items.len;
    }

    fn out(self: *const Asm) []const u8 {
        return self.code.items;
    }
};

// ---------------------------------------------------------------------------------------
// EVM execution against the fixed world
// ---------------------------------------------------------------------------------------

const Slot = struct { who: u8, slot: u256, value: u256 };

const ExecReq = struct {
    fork: usize,
    static: bool = false,
    gas: u64,
    value: u256 = 0,
    calldata: []const u8 = &.{},
    code_a: []const u8,
    code_b: []const u8 = &.{},
    bal_a: u256 = 0,
    bal_b: u256 = 0,
    slots: []const Slot = &.{},

    fn request(self: *const ExecReq, a: Allocator) ![]const u8 {
        var line = Line.init(a);
        try line.tok("E");
        try line.tok(@tagName(FORKS[self.fork]));
        try line.flag(self.static);
        try line.num(self.gas);
        try line.num(self.value);
        try line.bytes(self.calldata);
        try line.bytes(self.code_a);
        try line.bytes(self.code_b);
        try line.num(self.bal_a);
        try line.num(self.bal_b);
        try line.num(self.slots.len);
        for (self.slots) |s| {
            try line.tok(if (s.who == 'a') "a" else "b");
            try line.num(s.slot);
            try line.num(s.value);
        }
        return line.str();
    }
};

fn addressWord(address: Address) u256 {
    var value: u256 = 0;
    for (address.bytes) |byte| value = (value << 8) | byte;
    return value;
}

/// Execute on one Guillotine configuration and render the result in the oracle's format.
/// Revert and exceptional halt are both `N` here (see `normalizeLeanExec`).
fn execOn(comptime E: type, gpa: Allocator, a: Allocator, req: *const ExecReq) ![]const u8 {
    var db = Database.init(gpa);
    defer db.deinit();

    try db.set_account(ORIGIN.bytes, .{ .balance = ORIGIN_BALANCE, .nonce = 1, .code_hash = ZERO32, .storage_root = ZERO32 });
    const hash_a = if (req.code_a.len > 0) try db.set_code(req.code_a) else ZERO32;
    try db.set_account(CONTRACT_A.bytes, .{ .balance = req.bal_a, .nonce = 1, .code_hash = hash_a, .storage_root = ZERO32 });
    const hash_b = if (req.code_b.len > 0) try db.set_code(req.code_b) else ZERO32;
    try db.set_account(CONTRACT_B.bytes, .{ .balance = req.bal_b, .nonce = 1, .code_hash = hash_b, .storage_root = ZERO32 });
    try db.set_account(EOA.bytes, .{ .balance = EOA_BALANCE, .nonce = 0, .code_hash = ZERO32, .storage_root = ZERO32 });
    for (req.slots) |s| {
        const target = if (s.who == 'a') CONTRACT_A else CONTRACT_B;
        try db.set_storage(target.bytes, s.slot, s.value);
    }

    var randao: [32]u8 = undefined;
    std.mem.writeInt(u256, &randao, PREV_RANDAO, .big);
    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 20_000_000,
        .timestamp = 1_700_000_000,
        .difficulty = 0x20000,
        .prev_randao = randao,
        .gas_limit = 30_000_000,
        .coinbase = COINBASE,
        .base_fee = 7,
        .blob_base_fee = 3,
        .blob_versioned_hashes = &.{},
    };
    const tx_ctx = evm.TransactionContext{ .gas_limit = req.gas, .coinbase = COINBASE, .chain_id = 1, .blob_base_fee = 3 };

    var vm = try E.init(gpa, &db, block_info, tx_ctx, 0, ORIGIN);
    defer vm.deinit();

    const params: E.CallParams = if (req.static)
        .{ .staticcall = .{ .caller = ORIGIN, .to = CONTRACT_A, .input = req.calldata, .gas = req.gas } }
    else
        .{ .call = .{ .caller = ORIGIN, .to = CONTRACT_A, .value = req.value, .input = req.calldata, .gas = req.gas } };

    var res = vm.call(params);
    defer res.deinit(gpa);

    var line = Line.init(a);
    try line.tok(if (res.success) "S" else "N");
    try line.num(res.gas_left);
    try line.bytes(res.output);
    try line.num(res.logs.len);
    for (res.logs) |entry| {
        try line.num(addressWord(entry.address));
        try line.num(entry.topics.len);
        for (entry.topics) |topic| try line.num(topic);
        try line.bytes(entry.data);
    }
    try line.tok("B");
    for (REPORT_ADDRS) |account| try line.num(try db.get_balance(account.bytes));
    try line.tok("SA");
    for (PROBE_SLOTS) |slot| try line.num(try db.get_storage(CONTRACT_A.bytes, slot));
    try line.tok("SB");
    for (PROBE_SLOTS) |slot| try line.num(try db.get_storage(CONTRACT_B.bytes, slot));
    return line.str();
}

fn execZigDirect(gpa: Allocator, a: Allocator, req: *const ExecReq, fusion: bool) ![]const u8 {
    inline for (FORKS, 0..) |fork, index| {
        if (index == req.fork) {
            // `evm.DefaultEvm` is the build-configured EVM: Osaka with fusion on.
            if (fusion and comptime fork == .OSAKA) return execOn(evm.DefaultEvm, gpa, a, req);
            if (fusion) return execOn(EvmFor(fork, true), gpa, a, req);
            if (comptime hasFusionOff(fork)) return execOn(EvmFor(fork, false), gpa, a, req);
            return error.NoFusionOffBuildForFork;
        }
    }
    return error.UnknownFork;
}

const ExecJob = struct { gpa: Allocator, req: *const ExecReq, fusion: bool };

fn execJob(job: ExecJob, a: Allocator) anyerror![]const u8 {
    return execZigDirect(job.gpa, a, job.req, job.fusion);
}

fn execZig(gpa: Allocator, a: Allocator, req: *const ExecReq, fusion: bool) ![]const u8 {
    return isolated(a, ExecJob{ .gpa = gpa, .req = req, .fusion = fusion }, execJob);
}

/// The oracle distinguishes revert (`R`) from exceptional halt (`F`); Guillotine's
/// `CallResult` only has `success`. Both become `N`; gas, output and state still differ.
fn normalizeLeanExec(a: Allocator, lean: []const u8) ![]const u8 {
    if (lean.len > 0 and (lean[0] == 'R' or lean[0] == 'F')) {
        const out = try a.dupe(u8, lean);
        out[0] = 'N';
        return out;
    }
    return lean;
}

const ExecVerdict = struct { equal: bool, lean: []const u8, zig: []const u8 };

fn compareExec(suite: *Suite, a: Allocator, req: *const ExecReq, fusion: bool) !ExecVerdict {
    const request = try req.request(a);
    const lean = try normalizeLeanExec(a, try a.dupe(u8, try suite.oracle.ask(request)));
    const zig = try execZig(suite.gpa, a, req, fusion);
    return .{ .equal = std.mem.eql(u8, lean, zig), .lean = lean, .zig = zig };
}

/// Remove `len` bytes at `start`.
fn without(a: Allocator, data: []const u8, start: usize, len: usize) ![]u8 {
    const out = try a.alloc(u8, data.len - len);
    @memcpy(out[0..start], data[0..start]);
    @memcpy(out[start..], data[start + len ..]);
    return out;
}

/// Shrink the contract code of a failing vector while it keeps failing (bounded ddmin).
fn minimizeExec(suite: *Suite, a: Allocator, original: ExecReq, fusion: bool) !ExecReq {
    var best = original;
    var budget: usize = 150;
    inline for (.{ "code_a", "code_b", "calldata" }) |field| {
        var chunk: usize = @max(@field(best, field).len / 2, 1);
        while (budget > 0) {
            var start: usize = 0;
            var progressed = false;
            while (start + chunk <= @field(best, field).len and budget > 0) {
                var candidate = best;
                @field(candidate, field) = try without(a, @field(best, field), start, chunk);
                budget -= 1;
                const verdict = try compareExec(suite, a, &candidate, fusion);
                if (!verdict.equal and verdict.lean.len > 0 and verdict.lean[0] != 'U' and verdict.lean[0] != 'E') {
                    best = candidate;
                    progressed = true;
                } else {
                    start += chunk;
                }
            }
            if (chunk == 1) {
                if (!progressed) break;
            } else chunk /= 2;
        }
    }
    return best;
}

const ExecCheck = struct {
    /// Shrink the contract code of a failing vector before reporting it.
    minimize: bool = true,
    /// Put the hardfork in the mismatch class (one class per fork).
    class_per_fork: bool = true,
};

/// Run one execution vector on fusion-on and (where built) fusion-off Guillotine.
fn checkExec(suite: *Suite, a: Allocator, subsystem: Subsystem, class: []const u8, req: *const ExecReq) !void {
    return checkExecWith(suite, a, subsystem, class, req, .{});
}

fn checkExecWith(suite: *Suite, a: Allocator, subsystem: Subsystem, class: []const u8, req: *const ExecReq, options: ExecCheck) !void {
    for ([_]bool{ true, false }) |fusion| {
        if (!fusion and !forkHasFusionOff(req.fork)) continue;
        suite.count(subsystem, 1);
        const verdict = try compareExec(suite, a, req, fusion);
        if (verdict.equal) continue;
        if (verdict.lean.len > 0 and (verdict.lean[0] == 'U' or verdict.lean[0] == 'X' or verdict.lean[0] == 'E')) {
            // The generator produced something outside the reference model. That is a
            // harness defect, never a silent skip.
            try suite.mismatchOn(subsystem, "oracle could not evaluate the vector (generator defect)", req.fork, try req.request(a), verdict.lean, verdict.zig);
            continue;
        }
        const mode = if (fusion) "on" else "off";
        const label = if (options.class_per_fork)
            try std.fmt.allocPrint(a, "{s} [{s}, fusion {s}]", .{ class, @tagName(FORKS[req.fork]), mode })
        else
            try std.fmt.allocPrint(a, "{s} [fusion {s}]", .{ class, mode });
        // Minimizing costs up to 150 executions; only do it for a mismatch that will be printed.
        if (!options.minimize or suite.classCount(label) >= max_reports_per_class) {
            try suite.mismatchOn(subsystem, label, req.fork, try req.request(a), verdict.lean, verdict.zig);
            continue;
        }
        const minimal = try minimizeExec(suite, a, req.*, fusion);
        const final = try compareExec(suite, a, &minimal, fusion);
        try suite.mismatchOn(subsystem, label, req.fork, try minimal.request(a), final.lean, final.zig);
    }
}

// ---------------------------------------------------------------------------------------
// 1. 256-bit word operations
// ---------------------------------------------------------------------------------------

const WORD_OPS = [_]struct { opcode: u8, arity: u8, name: []const u8 }{
    .{ .opcode = 0x01, .arity = 2, .name = "ADD" },        .{ .opcode = 0x02, .arity = 2, .name = "MUL" },
    .{ .opcode = 0x03, .arity = 2, .name = "SUB" },        .{ .opcode = 0x04, .arity = 2, .name = "DIV" },
    .{ .opcode = 0x05, .arity = 2, .name = "SDIV" },       .{ .opcode = 0x06, .arity = 2, .name = "MOD" },
    .{ .opcode = 0x07, .arity = 2, .name = "SMOD" },       .{ .opcode = 0x08, .arity = 3, .name = "ADDMOD" },
    .{ .opcode = 0x09, .arity = 3, .name = "MULMOD" },     .{ .opcode = 0x0a, .arity = 2, .name = "EXP" },
    .{ .opcode = 0x0b, .arity = 2, .name = "SIGNEXTEND" }, .{ .opcode = 0x10, .arity = 2, .name = "LT" },
    .{ .opcode = 0x11, .arity = 2, .name = "GT" },         .{ .opcode = 0x12, .arity = 2, .name = "SLT" },
    .{ .opcode = 0x13, .arity = 2, .name = "SGT" },        .{ .opcode = 0x14, .arity = 2, .name = "EQ" },
    .{ .opcode = 0x15, .arity = 1, .name = "ISZERO" },     .{ .opcode = 0x16, .arity = 2, .name = "AND" },
    .{ .opcode = 0x17, .arity = 2, .name = "OR" },         .{ .opcode = 0x18, .arity = 2, .name = "XOR" },
    .{ .opcode = 0x19, .arity = 1, .name = "NOT" },        .{ .opcode = 0x1a, .arity = 2, .name = "BYTE" },
    .{ .opcode = 0x1b, .arity = 2, .name = "SHL" },        .{ .opcode = 0x1c, .arity = 2, .name = "SHR" },
    .{ .opcode = 0x1d, .arity = 2, .name = "SAR" },        .{ .opcode = 0x1e, .arity = 1, .name = "CLZ" },
};

/// Program that evaluates every word opcode on (a, b, c) and returns the 26 results.
fn wordProgram(a: Allocator, x: u256, y: u256, z: u256, wide: bool) ![]const u8 {
    var prog = Asm{ .a = a };
    for (WORD_OPS, 0..) |entry, index| {
        const operands = [_]u256{ z, y, x };
        for (operands[3 - entry.arity ..]) |operand| {
            if (wide) try prog.pushN(32, operand) else try prog.push(operand);
        }
        try prog.op(entry.opcode);
        try prog.push(index * 32);
        try prog.op(0x52);
    }
    try prog.push(WORD_OPS.len * 32);
    try prog.push(0);
    try prog.op(0xf3);
    return prog.out();
}

fn absWord(x: u256) u256 {
    return if (x >> 255 == 1) 0 -% x else x;
}

fn fuzzWords(suite: *Suite, r: std.Random, arena: *std.heap.ArenaAllocator) anyerror!void {
    const triples = @max(suite.iters / 2, 1);
    for (0..triples) |iteration| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const x = randomWord(r);
        const y = randomWord(r);
        const z = randomWord(r);

        var line = Line.init(a);
        try line.tok("W");
        try line.num(x);
        try line.num(y);
        try line.num(z);
        const request = line.str();
        const lean = try a.dupe(u8, try suite.oracle.ask(request));
        var expected: [WORD_OPS.len + 1]u256 = undefined;
        var tokens = std.mem.tokenizeScalar(u8, lean, ' ');
        for (&expected) |*slot| {
            const token = tokens.next() orelse return error.OracleShortAnswer;
            slot.* = try std.fmt.parseInt(u256, token, 16);
        }

        // (a) Every opcode through the interpreter, fusion on (DefaultEvm) and off.
        const program = try wordProgram(a, x, y, z, iteration % 2 == 0);
        inline for (.{ true, false }, .{ "DefaultEvm (fusion on)", "fusion off" }) |fusion, flavor| {
            const req = ExecReq{ .fork = FORK_OSAKA, .gas = 10_000_000, .code_a = program };
            const rendered = try execZig(suite.gpa, a, &req, fusion);
            var fields = std.mem.tokenizeScalar(u8, rendered, ' ');
            const status = fields.next() orelse "";
            _ = fields.next();
            const output = if (std.mem.eql(u8, status, "S")) try parseHexBytes(a, fields.next() orelse "-") else try a.alloc(u8, 0);
            suite.count(.word256, WORD_OPS.len);
            if (!std.mem.eql(u8, status, "S") or output.len != WORD_OPS.len * 32) {
                try suite.mismatch(.word256, "word-op program did not return 26 words (" ++ flavor ++ ")", request, lean, rendered);
            } else {
                for (WORD_OPS, 0..) |entry, index| {
                    const got = std.mem.readInt(u256, output[index * 32 ..][0..32], .big);
                    if (got == expected[index]) continue;
                    const class = try std.fmt.allocPrint(a, "{s} opcode ({s})", .{ entry.name, flavor });
                    const detail = try std.fmt.allocPrint(a, "{s} = {x}", .{ entry.name, got });
                    const want = try std.fmt.allocPrint(a, "{s} = {x}", .{ entry.name, expected[index] });
                    try suite.mismatch(.word256, class, request, want, detail);
                }
            }
        }

        // (b) verified_ops reference and fast forms.
        const sdiv_expected = expected[4];
        const smod_expected = expected[6];
        const Check = struct { name: []const u8, got: u256, want: u256 };
        var checks: std.ArrayList(Check) = .empty;
        try checks.appendSlice(a, &.{
            .{ .name = "verified_ops.signextendRef", .got = verified_ops.signextendRef(x, y), .want = expected[10] },
            .{ .name = "verified_ops.signextendFast", .got = verified_ops.signextendFast(x, y), .want = expected[10] },
            .{ .name = "verified_ops.byteRef", .got = verified_ops.byteRef(x, y), .want = expected[21] },
            .{ .name = "verified_ops.byteFast", .got = verified_ops.byteFast(x, y), .want = expected[21] },
            .{ .name = "verified_ops.sarRef", .got = verified_ops.sarRef(x, y), .want = expected[24] },
            .{ .name = "verified_ops.sarFast", .got = verified_ops.sarFast(x, y), .want = expected[24] },
            .{ .name = "verified_ops.clzRef", .got = verified_ops.clzRef(x), .want = expected[25] },
            .{ .name = "verified_ops.clzFast", .got = verified_ops.clzFast(x), .want = expected[25] },
            .{ .name = "verified_ops.expGasByteLenRef", .got = verified_ops.expGasByteLenRef(x), .want = expected[26] },
            .{ .name = "verified_ops.expGasByteLenFast", .got = verified_ops.expGasByteLenFast(x), .want = expected[26] },
        });
        if (y != 0) {
            try checks.appendSlice(a, &.{
                .{ .name = "verified_ops.sdivFromUnsignedQuotient", .got = verified_ops.sdivFromUnsignedQuotient(x, y, verified_ops.absTwoComp(x) / verified_ops.absTwoComp(y)), .want = sdiv_expected },
                .{ .name = "verified_ops.smodFromUnsignedRem", .got = verified_ops.smodFromUnsignedRem(x, verified_ops.absTwoComp(x) % verified_ops.absTwoComp(y)), .want = smod_expected },
                .{ .name = "verified_ops.absTwoComp", .got = verified_ops.absTwoComp(x), .want = absWord(x) },
            });
        }
        suite.count(.word256, checks.items.len);
        for (checks.items) |entry| {
            if (entry.got == entry.want) continue;
            const detail = try std.fmt.allocPrint(a, "{s} = {x}", .{ entry.name, entry.got });
            const want = try std.fmt.allocPrint(a, "{s} = {x}", .{ entry.name, entry.want });
            try suite.mismatch(.word256, entry.name, request, want, detail);
        }
    }
}

// ---------------------------------------------------------------------------------------
// 2. Fork-aware gas
// ---------------------------------------------------------------------------------------

fn BytecodeFor(comptime fork: Hardfork) type {
    return evm.Bytecode(.{ .hardfork = fork, .fusions_enabled = false });
}

/// Static gas of a single opcode on a fork, as Guillotine's block analysis prices it.
fn staticGasZig(gpa: Allocator, fork_index: usize, opcode: u8) !u32 {
    inline for (FORKS, 0..) |fork, index| {
        if (index == fork_index) {
            const Bc = BytecodeFor(fork);
            const code = [_]u8{opcode};
            var bc = try Bc.init(gpa, &code);
            defer bc.deinit();
            return Bc.Iterator.calculateBlockInfo(&bc, 0, 0).gas;
        }
    }
    return error.UnknownFork;
}

fn fuzzGasPure(suite: *Suite, r: std.Random, arena: *std.heap.ArenaAllocator) anyerror!void {
    const scale = @max(suite.iters / 2000, 1);

    for (FORKS, 0..) |fork, fork_index| {
        const name = @tagName(fork);
        const eips = evm.Eips{ .hardfork = fork };

        // Static gas of every opcode byte on every fork.
        for (0..256) |opcode| {
            // PUSH data and JUMPDEST are handled by the block walker itself; a lone
            // JUMPDEST at pc 0 is a block head, so price it through its own block.
            if (opcode == 0x5b) continue;
            _ = arena.reset(.retain_capacity);
            const a = arena.allocator();
            var line = Line.init(a);
            try line.tok("G");
            try line.tok("STATIC");
            try line.tok(name);
            try line.num(opcode);
            var answer = Line.init(a);
            if (staticGasZig(suite.gpa, fork_index, @intCast(opcode))) |gas| try answer.num(gas) else |err| try answer.tok(@errorName(err));
            try suite.check(.gas, "static opcode gas (fork_gas.staticGas + OPCODE_INFO)", line.str(), answer.str());
        }

        for (0..100 * scale) |_| {
            _ = arena.reset(.retain_capacity);
            const a = arena.allocator();

            // Refund cap and application (EIP-3529).
            {
                const limit = r.uintLessThan(u64, 30_000_000) + 1;
                const left = r.uintAtMost(u64, limit);
                const counter = switch (r.uintLessThan(u8, 4)) {
                    0 => 0,
                    1 => r.uintLessThan(u64, 100_000),
                    2 => r.uintLessThan(u64, 60_000_000),
                    else => (limit - left) / 5 + r.uintLessThan(u64, 3),
                };
                var line = Line.init(a);
                try line.tok("G");
                try line.tok("REFUND");
                try line.tok(name);
                try line.num(limit);
                try line.num(left);
                try line.num(counter);
                var answer = Line.init(a);
                try answer.num(eips.eip_3529_gas_refund_cap(limit - left, counter));
                try answer.num(eips.eip_3529_apply_gas_refund(limit, left, counter));
                try suite.check(.gas, "refund cap (EIP-3529)", line.str(), answer.str());
            }

            // Calldata tokens, intrinsic gas, EIP-7623 floor.
            {
                const data = try randomBytes(r, a, r.uintLessThan(usize, 200));
                if (r.boolean()) for (data) |*byte| {
                    if (r.uintLessThan(u8, 3) == 0) byte.* = 0;
                };
                var line = Line.init(a);
                try line.tok("G");
                try line.tok("TX");
                try line.tok(name);
                try line.bytes(data);
                const tokens = eips.tokens_in_calldata(data);
                var answer = Line.init(a);
                try answer.num(tokens);
                try answer.num(eips.intrinsic_gas_cost(false) + eips.calldata_gas_cost(tokens, false, data.len));
                try answer.num(eips.intrinsic_gas_cost(true) + eips.calldata_gas_cost(tokens, true, data.len));
                try answer.num(eips.floor_gas_cost(tokens));
                try suite.check(.gas, "intrinsic gas and calldata floor (EIP-2028/3860/7623)", line.str(), answer.str());
            }

            // Blob base fee (EIP-4844 fake_exponential) and next-block excess (EIP-7918).
            {
                const excess: u64 = switch (r.uintLessThan(u8, 6)) {
                    0 => 0,
                    1 => r.uintLessThan(u64, 393_216 * 4),
                    2 => r.uintLessThan(u64, 200_000_000),
                    3 => r.uintLessThan(u64, 2_000_000_000),
                    4 => r.int(u64),
                    else => 393_216 * r.uintLessThan(u64, 40),
                };
                var line = Line.init(a);
                try line.tok("G");
                try line.tok("BLOB");
                try line.tok(name);
                try line.num(excess);
                var answer = Line.init(a);
                try answer.num(eips.blob_gas_price(excess));
                try suite.check(.gas, "blob base fee (EIP-4844 fake_exponential)", line.str(), answer.str());

                const used: u64 = 131_072 * r.uintLessThan(u64, 22);
                const base_fee: u256 = switch (r.uintLessThan(u8, 4)) {
                    0 => r.uintLessThan(u256, 100),
                    1 => r.uintLessThan(u256, 1_000_000_000_000),
                    2 => r.int(u64),
                    else => 7,
                };
                var line2 = Line.init(a);
                try line2.tok("G");
                try line2.tok("EXCESS");
                try line2.tok(name);
                try line2.num(excess);
                try line2.num(used);
                try line2.num(base_fee);
                var answer2 = Line.init(a);
                try answer2.num(eips.excess_blob_gas(excess, used, base_fee));
                try suite.check(.gas, "excess blob gas (EIP-4844/7918)", line2.str(), answer2.str());
            }
        }

        for (0..40 * scale) |_| {
            _ = arena.reset(.retain_capacity);
            const a = arena.allocator();

            // CREATE gas (EIP-3860 initcode word cost and size limit).
            {
                const len: usize = switch (r.uintLessThan(u8, 4)) {
                    0 => r.uintLessThan(usize, 70),
                    1 => 32 * r.uintLessThan(usize, 100),
                    2 => r.uintLessThan(usize, 49_153),
                    else => 49_152,
                };
                var line = Line.init(a);
                try line.tok("G");
                try line.tok("CREATE");
                try line.tok(name);
                try line.num(len);
                var answer = Line.init(a);
                try answer.num(eips.create_gas_cost() + eips.eip_3860_initcode_word_cost(len));
                try answer.num(eips.eip_3860_initcode_word_cost(len));
                try answer.num(eips.size_limit());
                try suite.check(.gas, "CREATE gas (EIP-3860)", line.str(), answer.str());
            }

            // EXP dynamic gas (EIP-160).
            {
                const exponent = randomWord(r);
                var line = Line.init(a);
                try line.tok("G");
                try line.tok("EXP");
                try line.tok(name);
                try line.num(exponent);
                var answer = Line.init(a);
                try answer.num(10 + eips.eip_160_exp_byte_gas_cost() * verified_ops.expGasByteLenRef(exponent));
                try suite.check(.gas, "EXP gas (EIP-160)", line.str(), answer.str());
            }
        }

        // MODEXP pricing (EIP-198, EIP-2565, EIP-7883), Byzantium and later.
        if (fork.isAtLeast(.BYZANTIUM)) {
            for (0..120 * scale) |_| {
                _ = arena.reset(.retain_capacity);
                const a = arena.allocator();
                const pick = r.uintLessThan(u8, 10);
                const base_len: usize = if (pick == 0) 1025 else if (pick == 1) 0 else r.uintLessThan(usize, 70);
                const exp_len: usize = if (pick == 2) 1025 else if (pick == 3) 0 else r.uintLessThan(usize, 48);
                const mod_len: usize = if (pick == 4) 1025 else if (pick == 5) 0 else r.uintLessThan(usize, 70);
                const body = try randomBytes(r, a, base_len + exp_len + mod_len);
                if (exp_len > 0 and r.boolean()) @memset(body[base_len..][0..@min(exp_len, 1 + r.uintLessThan(usize, 33))], 0);
                var input: std.ArrayList(u8) = .empty;
                inline for (.{ base_len, exp_len, mod_len }) |len| {
                    var word: [32]u8 = undefined;
                    std.mem.writeInt(u256, &word, len, .big);
                    try input.appendSlice(a, &word);
                }
                try input.appendSlice(a, body);
                var head: u256 = 0;
                for (body[base_len..][0..@min(exp_len, 32)]) |byte| head = (head << 8) | byte;

                var line = Line.init(a);
                try line.tok("G");
                try line.tok("MODEXP");
                try line.tok(name);
                try line.num(base_len);
                try line.num(exp_len);
                try line.num(mod_len);
                try line.num(head);
                var answer = Line.init(a);
                if (evm.precompiles.modexp.execute(a, input.items, std.math.maxInt(u64), fork)) |result| {
                    try answer.num(result.gas_used);
                } else |err| switch (err) {
                    error.InvalidInput => try answer.tok("INVALID"),
                    else => try answer.tok(@errorName(err)),
                }
                try suite.check(.gas, "MODEXP gas (EIP-198/2565/7883)", line.str(), answer.str());
            }
        }
    }

    // Memory expansion (fork independent).
    for (0..600 * scale) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const words: u64 = switch (r.uintLessThan(u8, 4)) {
            0 => r.uintLessThan(u64, 40),
            1 => r.uintLessThan(u64, 2000),
            2 => r.uintLessThan(u64, 600_000),
            else => 22 + r.uintLessThan(u64, 4),
        };
        var line = Line.init(a);
        try line.tok("G");
        try line.tok("MEMW");
        try line.num(words);
        var answer = Line.init(a);
        try answer.num(verified_ops.memoryGasCost(words));
        try suite.check(.gas, "memory cost (verified_ops.memoryGasCost)", line.str(), answer.str());

        const current: u64 = r.uintLessThan(u64, 100_000);
        const new: u64 = r.uintLessThan(u64, 200_000);
        var line2 = Line.init(a);
        try line2.tok("G");
        try line2.tok("MEM");
        try line2.num(current);
        try line2.num(new);
        var answer2 = Line.init(a);
        try answer2.num(primitives.GasConstants.memoryGasCost(current, new));
        try suite.check(.gas, "memory expansion gas (GasConstants.memoryGasCost)", line2.str(), answer2.str());
    }
}

/// `Eips.sstore_gas_cost` is a second, standalone SSTORE pricing helper in
/// `src/eips_and_hardforks/eips.zig`. The interpreter uses `fork_gas.sstoreCost`
/// (covered by `fuzzGasExec`); this checks the helper against the same specification.
fn fuzzSstoreHelper(suite: *Suite, _: std.Random, arena: *std.heap.ArenaAllocator) anyerror!void {
    const values = [_]u256{ 0, 1, 2 };
    for (FORKS) |fork| {
        const eips = evm.Eips{ .hardfork = fork };
        for (values) |original| for (values) |current| for (values) |new| for ([_]bool{ false, true }) |cold| {
            _ = arena.reset(.retain_capacity);
            const a = arena.allocator();
            var line = Line.init(a);
            try line.tok("G");
            try line.tok("SSTORE");
            try line.tok(@tagName(fork));
            try line.num(original);
            try line.num(current);
            try line.num(new);
            try line.flag(cold);
            const lean = try a.dupe(u8, try suite.oracle.ask(line.str()));
            var tokens = std.mem.tokenizeScalar(u8, lean, ' ');
            const want_gas = tokens.next() orelse return error.OracleShortAnswer;
            const want_refund = tokens.next() orelse return error.OracleShortAnswer;
            const zig = try isolated(a, SstoreHelperJob{ .eips = eips, .original = original, .current = current, .new = new, .cold = cold }, sstoreHelperJob);
            const want = try std.fmt.allocPrint(a, "{s} {s}", .{ want_gas, want_refund });
            suite.count(.gas, 1);
            if (!std.mem.eql(u8, want, zig)) {
                const class = if (std.mem.startsWith(u8, zig, "CRASH"))
                    "Eips.sstore_gas_cost helper panics (integer overflow)"
                else
                    "Eips.sstore_gas_cost helper differs from fork_gas.sstoreCost and the spec";
                try suite.mismatch(.gas, class, line.str(), want, zig);
            }
        };
    }
}

const SstoreHelperJob = struct { eips: evm.Eips, original: u256, current: u256, new: u256, cold: bool };

fn sstoreHelperJob(job: SstoreHelperJob, a: Allocator) anyerror![]const u8 {
    const cost = job.eips.sstore_gas_cost(job.current, job.new, job.original, job.cold);
    var answer = Line.init(a);
    try answer.num(cost.gas);
    try answer.signed(cost.refund);
    return answer.str();
}

fn forkAtLeast(fork_index: usize, comptime target: Hardfork) bool {
    return FORKS[fork_index].isAtLeast(target);
}

/// Gas metering measured in situ: small programs executed on every fork.
fn fuzzGasExec(suite: *Suite, r: std.Random, arena: *std.heap.ArenaAllocator) anyerror!void {
    const per_fork = @max(suite.iters / 8, 1);
    for (0..FORKS.len) |fork_index| {
        for (0..per_fork) |_| {
            _ = arena.reset(.retain_capacity);
            const a = arena.allocator();
            var prog = Asm{ .a = a, .push0 = forkAtLeast(fork_index, .SHANGHAI) };
            var slots: std.ArrayList(Slot) = .empty;
            var req = ExecReq{ .fork = fork_index, .gas = 200_000 + r.uintLessThan(u64, 300_000), .code_a = &.{} };
            var class: []const u8 = undefined;

            switch (r.uintLessThan(u8, 6)) {
                0, 1 => {
                    // SSTORE sequences on one slot: every (original, current, new) transition.
                    class = "SSTORE gas/refund sequence";
                    const slot: u256 = r.uintLessThan(u256, 4);
                    const original: u256 = r.uintLessThan(u256, 3);
                    if (original != 0) try slots.append(a, .{ .who = 'a', .slot = slot, .value = original });
                    if (r.uintLessThan(u8, 4) == 0) {
                        try prog.push(slot);
                        try prog.op(0x54);
                        try prog.op(0x50);
                    }
                    for (0..1 + r.uintLessThan(usize, 4)) |_| {
                        try prog.push(r.uintLessThan(u256, 3));
                        try prog.push(slot);
                        try prog.op(0x55);
                    }
                    try prog.op(0x00);
                    // Occasionally run near the EIP-2200 sentry and the out-of-gas boundary.
                    if (r.uintLessThan(u8, 4) == 0) req.gas = 21_000 + r.uintLessThan(u64, 30_000);
                },
                2 => {
                    // SLOAD cold/warm, BALANCE and EXTCODESIZE on warm and cold accounts.
                    class = "SLOAD/BALANCE/EXTCODESIZE access gas";
                    const targets = [_]Address{ CONTRACT_A, CONTRACT_B, EOA, DEAD, ORIGIN, COINBASE };
                    for (0..1 + r.uintLessThan(usize, 5)) |_| {
                        switch (r.uintLessThan(u8, 3)) {
                            0 => {
                                try prog.push(r.uintLessThan(u256, 3));
                                try prog.op(0x54);
                            },
                            1 => {
                                try prog.pushAddr(targets[r.uintLessThan(usize, targets.len)]);
                                try prog.op(0x31);
                            },
                            else => {
                                try prog.pushAddr(targets[r.uintLessThan(usize, targets.len)]);
                                try prog.op(0x3b);
                            },
                        }
                        try prog.op(0x50);
                    }
                    try prog.op(0x00);
                    try slots.append(a, .{ .who = 'a', .slot = 1, .value = 77 });
                },
                3 => {
                    // CALL: 63/64 rule, stipend, value transfer, new-account surcharge.
                    class = "CALL gas (63/64, stipend, value, new account)";
                    const targets = [_]Address{ CONTRACT_B, EOA, DEAD };
                    const target = targets[r.uintLessThan(usize, targets.len)];
                    const value: u256 = if (r.boolean()) 0 else 1 + r.uintLessThan(u256, 5);
                    const gas_param: u256 = switch (r.uintLessThan(u8, 4)) {
                        0 => 0,
                        1 => r.uintLessThan(u256, 5000),
                        2 => r.uintLessThan(u256, 100_000),
                        else => max_u256,
                    };
                    for (0..1 + r.uintLessThan(usize, 2)) |_| {
                        try prog.push(0);
                        try prog.push(0);
                        try prog.push(0);
                        try prog.push(0);
                        try prog.push(value);
                        try prog.pushAddr(target);
                        try prog.push(gas_param);
                        try prog.op(0xf1);
                        try prog.op(0x50);
                    }
                    try prog.op(0x00);
                    req.bal_a = r.uintLessThan(u256, 8);
                    // Callee: burn a little gas, optionally write storage.
                    var callee = Asm{ .a = a, .push0 = prog.push0 };
                    if (r.boolean()) {
                        try callee.push(1);
                        try callee.push(0);
                        try callee.op(0x55);
                    }
                    try callee.op(0x00);
                    req.code_b = callee.out();
                },
                4 => {
                    // Memory expansion through MSTORE/MLOAD/MSTORE8 at growing offsets.
                    class = "memory expansion gas";
                    for (0..1 + r.uintLessThan(usize, 4)) |_| {
                        const offset = r.uintLessThan(u256, if (r.boolean()) 512 else 40_000);
                        switch (r.uintLessThan(u8, 3)) {
                            0 => {
                                try prog.push(1);
                                try prog.push(offset);
                                try prog.op(0x52);
                            },
                            1 => {
                                try prog.push(offset);
                                try prog.op(0x51);
                                try prog.op(0x50);
                            },
                            else => {
                                try prog.push(1);
                                try prog.push(offset);
                                try prog.op(0x53);
                            },
                        }
                    }
                    try prog.op(0x00);
                },
                else => {
                    // SELFDESTRUCT: base gas, new-account surcharge, cold beneficiary, refund.
                    class = "SELFDESTRUCT gas/refund";
                    const targets = [_]Address{ EOA, DEAD, CONTRACT_B, CONTRACT_A };
                    try prog.pushAddr(targets[r.uintLessThan(usize, targets.len)]);
                    try prog.op(0xff);
                    req.bal_a = r.uintLessThan(u256, 3);
                },
            }
            req.code_a = prog.out();
            req.slots = slots.items;
            try checkExec(suite, a, .gas, class, &req);
        }
    }
}

// ---------------------------------------------------------------------------------------
// 3. Bytecode analysis
// ---------------------------------------------------------------------------------------

fn randomCode(r: std.Random, a: Allocator) ![]u8 {
    const len: usize = switch (r.uintLessThan(u8, 8)) {
        0 => r.uintLessThan(usize, 4),
        1, 2, 3 => r.uintLessThan(usize, 64),
        4, 5 => r.uintLessThan(usize, 300),
        6 => r.uintLessThan(usize, 1200),
        else => 33 + r.uintLessThan(usize, 5),
    };
    const code = try randomBytes(r, a, len);
    switch (r.uintLessThan(u8, 6)) {
        0 => {}, // uniform bytes
        1 => for (code) |*byte| {
            // JUMPDEST- and PUSH-heavy: 0x5b inside PUSH data, truncated trailing PUSH.
            byte.* = switch (r.uintLessThan(u8, 4)) {
                0 => 0x5b,
                1 => 0x60 + r.uintLessThan(u8, 32),
                2 => byte.*,
                else => 0x5b,
            };
        },
        2 => for (code) |*byte| {
            // Mostly real instructions.
            const table = [_]u8{ 0x01, 0x02, 0x03, 0x10, 0x14, 0x15, 0x16, 0x50, 0x51, 0x52, 0x54, 0x55, 0x56, 0x57, 0x58, 0x5a, 0x5b, 0x5f, 0x60, 0x61, 0x7f, 0x80, 0x8f, 0x90, 0x9f, 0xa0, 0xa4, 0xf1, 0xf3, 0xfa, 0xfd, 0xfe, 0xff, 0x00 };
            byte.* = table[r.uintLessThan(usize, table.len)];
        },
        3 => if (code.len > 0) {
            // Truncated PUSH at the very end.
            code[code.len - 1] = 0x60 + r.uintLessThan(u8, 32);
            if (code.len > 2) code[code.len - 2] = 0x7f;
        },
        4 => @memset(code, 0x5b),
        else => for (code, 0..) |*byte, index| {
            // PUSHn immediately followed by 0x5b runs.
            byte.* = if (index % 5 == 0) 0x60 + r.uintLessThan(u8, 32) else 0x5b;
        },
    }
    return code;
}

fn analyzeZig(comptime Bc: type, gpa: Allocator, a: Allocator, code: []const u8, lean: []const u8) ![]const u8 {
    var bc = Bc.init(gpa, code) catch |err| return std.fmt.allocPrint(a, "Bytecode.init failed: {s}", .{@errorName(err)});
    defer bc.deinit();

    var line = Line.init(a);

    // JUMPDEST bitmap, least significant bit first.
    const bitmap = try a.alloc(u8, (code.len + 7) / 8);
    @memset(bitmap, 0);
    for (0..code.len) |index| {
        if (bc.isValidJumpDest(@intCast(index))) bitmap[index / 8] |= @as(u8, 1) << @intCast(index % 8);
    }
    try line.bytes(bitmap);

    // Instruction count.
    var instructions: usize = 0;
    var cursor: usize = 0;
    while (cursor < code.len) : (instructions += 1) cursor += bc.getInstructionSize(@intCast(cursor));
    try line.num(instructions);

    // Blocks and pushes at the positions the specification reports.
    var tokens = std.mem.tokenizeScalar(u8, lean, ' ');
    _ = tokens.next();
    _ = tokens.next();
    const block_count = try std.fmt.parseInt(usize, tokens.next() orelse return error.OracleShortAnswer, 16);
    try line.num(block_count);
    for (0..block_count) |_| {
        const start = try std.fmt.parseInt(usize, tokens.next() orelse return error.OracleShortAnswer, 16);
        _ = tokens.next();
        _ = tokens.next();
        _ = tokens.next();
        const info = if (bc.isValidJumpDest(@intCast(start)))
            Bc.Iterator.calculateBlockInfo(&bc, @intCast(start + 1), 1)
        else
            Bc.Iterator.calculateBlockInfo(&bc, @intCast(start), 0);
        try line.num(start);
        try line.num(info.gas);
        try line.num(@intCast(info.min_stack));
        try line.num(@intCast(info.max_stack));
    }
    const push_count = try std.fmt.parseInt(usize, tokens.next() orelse return error.OracleShortAnswer, 16);
    try line.num(push_count);
    for (0..push_count) |_| {
        const position = try std.fmt.parseInt(usize, tokens.next() orelse return error.OracleShortAnswer, 16);
        _ = tokens.next();
        try line.num(position);
        if (position >= code.len or code[position] < 0x60 or code[position] > 0x7f) {
            try line.tok("not-a-push");
        } else {
            try line.num(bc.pushValuePadded(position, code[position] - 0x5f));
        }
    }
    return line.str();
}

const AnalyzeJob = struct { gpa: Allocator, fork_index: usize, code: []const u8, lean: []const u8 };

fn analyzeJob(job: AnalyzeJob, a: Allocator) anyerror![]const u8 {
    inline for (FORKS, 0..) |fork, index| {
        if (index == job.fork_index) return analyzeZig(BytecodeFor(fork), job.gpa, a, job.code, job.lean);
    }
    return error.UnknownFork;
}

fn analyzeZigDyn(gpa: Allocator, a: Allocator, fork_index: usize, code: []const u8, lean: []const u8) ![]const u8 {
    return isolated(a, AnalyzeJob{ .gpa = gpa, .fork_index = fork_index, .code = code, .lean = lean }, analyzeJob);
}

fn bytecodeRequest(a: Allocator, fork_index: usize, code: []const u8) ![]const u8 {
    var line = Line.init(a);
    try line.tok("B");
    try line.tok(@tagName(FORKS[fork_index]));
    try line.bytes(code);
    return line.str();
}

fn fuzzBytecode(suite: *Suite, r: std.Random, arena: *std.heap.ArenaAllocator) anyerror!void {
    const count = suite.iters * 5 / 2;
    for (0..count) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const fork_index = if (r.boolean()) FORK_CANCUN else r.uintLessThan(usize, FORKS.len);
        var code: []const u8 = try randomCode(r, a);
        var request = try bytecodeRequest(a, fork_index, code);
        var lean = try a.dupe(u8, try suite.oracle.ask(request));
        var zig = try analyzeZigDyn(suite.gpa, a, fork_index, code, lean);
        suite.count(.bytecode, 1);
        if (std.mem.eql(u8, lean, zig)) continue;

        // Minimize: drop chunks while the analyses still disagree.
        var chunk: usize = @max(code.len / 2, 1);
        var budget: usize = 200;
        while (budget > 0) {
            var start: usize = 0;
            var progressed = false;
            while (start + chunk <= code.len and budget > 0) {
                budget -= 1;
                const candidate = try without(a, code, start, chunk);
                const candidate_request = try bytecodeRequest(a, fork_index, candidate);
                const candidate_lean = try a.dupe(u8, try suite.oracle.ask(candidate_request));
                const candidate_zig = try analyzeZigDyn(suite.gpa, a, fork_index, candidate, candidate_lean);
                if (!std.mem.eql(u8, candidate_lean, candidate_zig)) {
                    code = candidate;
                    request = candidate_request;
                    lean = candidate_lean;
                    zig = candidate_zig;
                    progressed = true;
                } else start += chunk;
            }
            if (chunk == 1 and !progressed) break;
            chunk = @max(chunk / 2, 1);
        }
        try suite.mismatch(.bytecode, "bytecode analysis (jumpdests / blocks / push immediates)", request, lean, zig);
    }

    // Straight-line fusion equivalence: constant-foldable sequences must leave the stack
    // the specification computes, with fusion on and off.
    const pure_ops = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0a, 0x0b, 0x10, 0x11, 0x12, 0x13, 0x14, 0x16, 0x17, 0x18, 0x1a, 0x1b, 0x1c, 0x1d };
    for (0..suite.iters / 2) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        var prog = Asm{ .a = a };
        var depth: usize = 0;
        for (0..2 + r.uintLessThan(usize, 24)) |_| {
            const pick = r.uintLessThan(u8, 12);
            if (depth < 2 or pick < 4) {
                if (r.boolean()) try prog.push(randomWord(r)) else try prog.pushN(1 + r.uintLessThan(u8, 32), randomWord(r) & 0xffff);
                depth += 1;
            } else if (pick < 8) {
                try prog.op(pure_ops[r.uintLessThan(usize, pure_ops.len)]);
                depth -= 1;
            } else if (pick == 8) {
                try prog.op(if (r.boolean()) 0x15 else 0x19);
            } else if (pick == 9) {
                try prog.op(0x80 + @as(u8, @intCast(r.uintLessThan(usize, @min(depth, 16)))));
                depth += 1;
            } else if (pick == 10) {
                try prog.op(0x90 + @as(u8, @intCast(r.uintLessThan(usize, @min(depth - 1, 16)))));
            } else if (depth >= 3) {
                try prog.op(if (r.boolean()) 0x08 else 0x09);
                depth -= 2;
            }
        }
        if (r.uintLessThan(u8, 12) == 0) try prog.op(0x01); // possible underflow
        const body = try a.dupe(u8, prog.out());

        var line = Line.init(a);
        try line.tok("BF");
        try line.tok("CANCUN");
        try line.bytes(body);
        const lean = try a.dupe(u8, try suite.oracle.ask(line.str()));

        // Return the top of the stack.
        try prog.push(0);
        try prog.op(0x52);
        try prog.push(32);
        try prog.push(0);
        try prog.op(0xf3);
        const req = ExecReq{ .fork = FORK_CANCUN, .gas = 5_000_000, .code_a = prog.out() };
        for ([_]bool{ true, false }) |fusion| {
            const rendered = try execZig(suite.gpa, a, &req, fusion);
            var fields = std.mem.tokenizeScalar(u8, rendered, ' ');
            const status = fields.next() orelse "";
            _ = fields.next();
            const is_success = std.mem.eql(u8, status, "S");
            const output = if (is_success) try parseHexBytes(a, fields.next() orelse "-") else try a.alloc(u8, 0);
            var answer = Line.init(a);
            if (std.mem.startsWith(u8, rendered, "CRASH")) {
                try answer.tok(rendered);
            } else if (is_success and output.len == 32) {
                try answer.tok("OK");
                try answer.num(std.mem.readInt(u256, output[0..32], .big));
            } else try answer.tok("FAULT");

            // Specification: `OK <stack size> <top>` or `FAULT`. An empty final stack
            // faults in the returning epilogue.
            var want = Line.init(a);
            var lean_tokens = std.mem.tokenizeScalar(u8, lean, ' ');
            const verdict = lean_tokens.next() orelse return error.OracleShortAnswer;
            if (std.mem.eql(u8, verdict, "OK")) {
                const size = try std.fmt.parseInt(usize, lean_tokens.next().?, 16);
                if (size == 0) try want.tok("FAULT") else {
                    try want.tok("OK");
                    try want.tok(lean_tokens.next().?);
                }
            } else try want.tok("FAULT");

            suite.count(.bytecode, 1);
            if (!std.mem.eql(u8, want.str(), answer.str())) {
                try suite.mismatch(.bytecode, if (fusion) "straight-line fusion equivalence (fusion on)" else "straight-line evaluation (fusion off)", line.str(), want.str(), answer.str());
            }
        }
    }
}

// ---------------------------------------------------------------------------------------
// 4. Full EVM execution
// ---------------------------------------------------------------------------------------

const Gen = struct {
    r: std.Random,
    a: Allocator,
    fork: usize,

    fn has(self: *const Gen, comptime target: Hardfork) bool {
        return forkAtLeast(self.fork, target);
    }

    /// Random opcode from `list` that exists on the fork (every list has Frontier opcodes).
    fn choose(self: *const Gen, list: []const u8) u8 {
        for (0..64) |_| {
            const opcode = list[self.r.uintLessThan(usize, list.len)];
            if (available(self.fork, opcode)) return opcode;
        }
        return 0x01;
    }

    /// REVERT where it exists, otherwise RETURN.
    fn revertOr(self: *const Gen, otherwise: u8) u8 {
        return if (self.has(.BYZANTIUM)) 0xfd else otherwise;
    }

    fn newAsm(self: *const Gen) Asm {
        return .{ .a = self.a, .push0 = self.has(.SHANGHAI) };
    }

    fn smallOffset(self: *const Gen) u256 {
        return switch (self.r.uintLessThan(u8, 8)) {
            0 => 0,
            1, 2, 3 => self.r.uintLessThan(u256, 96),
            4, 5 => self.r.uintLessThan(u256, 1024),
            6 => 31 + self.r.uintLessThan(u256, 3),
            else => self.r.uintLessThan(u256, 5000),
        };
    }

    fn smallSize(self: *const Gen) u256 {
        return switch (self.r.uintLessThan(u8, 6)) {
            0 => 0,
            1 => 1,
            2 => 32,
            3 => self.r.uintLessThan(u256, 100),
            4 => 31 + self.r.uintLessThan(u256, 3),
            else => self.r.uintLessThan(u256, 700),
        };
    }

    /// Arithmetic, bitwise, comparison, KECCAK256 and environment reads.
    fn arithmetic(self: *const Gen, prog: *Asm, steps: usize) !void {
        const r = self.r;
        const binary = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0a, 0x0b, 0x10, 0x11, 0x12, 0x13, 0x14, 0x16, 0x17, 0x18, 0x1a, 0x1b, 0x1c, 0x1d };
        const env = [_]u8{ 0x30, 0x32, 0x33, 0x34, 0x36, 0x38, 0x3a, 0x3d, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x4a, 0x58, 0x59, 0x5a };
        for (0..4) |_| try prog.push(randomWord(r));
        for (0..steps) |_| {
            switch (r.uintLessThan(u8, 12)) {
                0, 1, 2 => {
                    try prog.push(randomWord(r));
                    try prog.op(self.choose(&binary));
                },
                3 => {
                    try prog.push(randomWord(r));
                    try prog.push(randomWord(r));
                    try prog.op(if (r.boolean()) 0x08 else 0x09);
                },
                4 => try prog.op(if (r.boolean()) 0x15 else 0x19),
                5 => {
                    try prog.op(0x80 + r.uintLessThan(u8, 4));
                    try prog.op(self.choose(&binary));
                },
                6 => try prog.op(0x90 + r.uintLessThan(u8, 3)),
                7 => {
                    try prog.op(self.choose(&env));
                    try prog.op(self.choose(&binary));
                },
                8 => {
                    // KECCAK256 of a freshly written word.
                    const offset = self.smallOffset();
                    try prog.op(0x80);
                    try prog.push(offset);
                    try prog.op(0x52);
                    try prog.push(self.smallSize());
                    try prog.push(offset);
                    try prog.op(0x20);
                    try prog.op(0x18);
                },
                9 => {
                    try prog.push(self.smallOffset());
                    try prog.op(0x35);
                    try prog.op(0x01);
                },
                10 => if (self.has(.OSAKA)) try prog.op(0x1e) else try prog.op(0x19),
                else => if (self.has(.CANCUN)) {
                    try prog.push(randomWord(r) & 0xff);
                    try prog.op(0x49);
                    try prog.op(0x01);
                } else try prog.op(0x15),
            }
        }
    }

    /// Return (or revert with) the top of the stack.
    fn finishWithTop(self: *const Gen, prog: *Asm) !void {
        try prog.push(0);
        try prog.op(0x52);
        try prog.push(32);
        try prog.push(0);
        try prog.op(if (self.r.uintLessThan(u8, 8) == 0) self.revertOr(0xf3) else 0xf3);
    }

    /// Memory: MLOAD, MSTORE, MSTORE8, MSIZE, MCOPY, CALLDATACOPY, CODECOPY, RETURNDATACOPY.
    fn memory(self: *const Gen, prog: *Asm, steps: usize) !void {
        const r = self.r;
        for (0..steps) |_| {
            switch (r.uintLessThan(u8, 10)) {
                0, 1 => {
                    try prog.push(randomWord(r));
                    try prog.push(self.smallOffset());
                    try prog.op(0x52);
                },
                2 => {
                    try prog.push(randomWord(r));
                    try prog.push(self.smallOffset());
                    try prog.op(0x53);
                },
                3 => {
                    try prog.push(self.smallOffset());
                    try prog.op(0x51);
                    try prog.op(0x50);
                },
                4, 5 => if (self.has(.CANCUN)) {
                    // MCOPY, overlapping ranges included.
                    try prog.push(self.smallSize());
                    try prog.push(self.smallOffset());
                    try prog.push(self.smallOffset());
                    try prog.op(0x5e);
                } else {
                    try prog.push(self.smallOffset());
                    try prog.op(0x51);
                    try prog.push(self.smallOffset());
                    try prog.op(0x52);
                },
                6 => {
                    try prog.push(self.smallSize());
                    try prog.push(self.smallOffset());
                    try prog.push(self.smallOffset());
                    try prog.op(if (r.boolean()) 0x37 else 0x39);
                },
                7 => {
                    try prog.op(0x59);
                    try prog.push(self.smallOffset());
                    try prog.op(0x52);
                },
                8 => if (self.has(.BYZANTIUM)) {
                    // RETURNDATACOPY with no return data: only (anything, 0, 0) succeeds.
                    try prog.push(if (r.uintLessThan(u8, 6) == 0) 1 else 0);
                    try prog.push(0);
                    try prog.push(self.smallOffset());
                    try prog.op(0x3e);
                } else {
                    try prog.op(0x59);
                    try prog.op(0x50);
                },
                else => {
                    try prog.push(self.smallSize());
                    try prog.push(self.smallOffset());
                    try prog.op(0x20);
                    try prog.push(self.smallOffset());
                    try prog.op(0x52);
                },
            }
        }
        try prog.push(self.smallSize());
        try prog.push(self.smallOffset());
        try prog.op(if (r.uintLessThan(u8, 6) == 0) self.revertOr(0xf3) else 0xf3);
    }

    fn slotKey(self: *const Gen) u256 {
        return if (self.r.uintLessThan(u8, 10) == 0) PROBE_SLOTS[8 + self.r.uintLessThan(usize, 4)] else self.r.uintLessThan(u256, 8);
    }

    /// Storage, transient storage and logs, ending in RETURN, REVERT or STOP.
    fn storage(self: *const Gen, prog: *Asm, steps: usize, terminate: bool) !void {
        const r = self.r;
        for (0..steps) |_| {
            switch (r.uintLessThan(u8, 10)) {
                0, 1, 2 => {
                    try prog.push(if (r.uintLessThan(u8, 3) == 0) 0 else r.uintLessThan(u256, 4));
                    try prog.push(self.slotKey());
                    try prog.op(0x55);
                },
                3, 4 => {
                    try prog.push(self.slotKey());
                    try prog.op(0x54);
                    try prog.push(r.uintLessThan(u256, 3) * 32);
                    try prog.op(0x52);
                },
                5 => {
                    try prog.push(randomWord(r));
                    try prog.push(self.slotKey());
                    try prog.op(if (self.has(.CANCUN)) 0x5d else 0x55);
                },
                6 => {
                    try prog.push(self.slotKey());
                    try prog.op(if (self.has(.CANCUN)) 0x5c else 0x54);
                    try prog.push(32);
                    try prog.op(0x52);
                },
                7, 8 => {
                    const topics = r.uintLessThan(u8, 5);
                    for (0..topics) |_| try prog.push(randomWord(r));
                    try prog.push(self.smallSize() % 80);
                    try prog.push(self.smallOffset() % 200);
                    try prog.op(0xa0 + topics);
                },
                else => {
                    // SLOAD then SSTORE of the same slot (warm write).
                    const key = self.slotKey();
                    try prog.push(key);
                    try prog.op(0x54);
                    try prog.push(1);
                    try prog.op(0x01);
                    try prog.push(key);
                    try prog.op(0x55);
                },
            }
        }
        if (!terminate) return;
        switch (r.uintLessThan(u8, 6)) {
            0 => try prog.op(0x00),
            1 => {
                try prog.push(64);
                try prog.push(0);
                try prog.op(self.revertOr(0xfe));
            },
            2 => try prog.op(0xfe),
            else => {
                try prog.push(64);
                try prog.push(0);
                try prog.op(0xf3);
            },
        }
    }

    /// Control flow: forward and backward jumps, a bounded loop, PC and GAS.
    fn control(self: *const Gen, prog: *Asm) !void {
        const r = self.r;
        // Counted loop: counter on the stack, body is a little arithmetic.
        try prog.push(1 + r.uintLessThan(u256, 12));
        const loop_head = prog.pc();
        try prog.op(0x5b);
        switch (r.uintLessThan(u8, 4)) {
            0 => {
                try prog.op(0x58);
                try prog.op(0x50);
            },
            1 => {
                try prog.op(0x5a);
                try prog.push(0x20);
                try prog.op(0x52);
            },
            2 => {
                try prog.op(0x80);
                try prog.push(0);
                try prog.op(0x55);
            },
            else => {
                try prog.op(0x80);
                try prog.op(0x80);
                try prog.op(0x02);
                try prog.op(0x50);
            },
        }
        try prog.push(1);
        try prog.op(0x90);
        try prog.op(0x03);
        try prog.op(0x80);
        try prog.pushN(2, loop_head);
        try prog.op(0x57);
        try prog.op(0x50);

        // Conditional forward jump over an INVALID, sometimes to a bad destination.
        try prog.push(r.uintLessThan(u256, 2));
        const patch = prog.pc() + 1;
        try prog.pushN(2, 0);
        try prog.op(0x57);
        try prog.op(if (r.boolean()) 0xfe else 0x00);
        const landing = prog.pc();
        try prog.op(0x5b);
        const destination: usize = switch (r.uintLessThan(u8, 10)) {
            0 => landing + 1, // not a JUMPDEST
            1 => patch, // inside PUSH data
            2 => 0xffff, // past the end
            else => landing,
        };
        prog.code.items[patch] = @truncate(destination >> 8);
        prog.code.items[patch + 1] = @truncate(destination);

        // Unconditional jump to a JUMPDEST that sits inside PUSH data or to a real one.
        if (r.boolean()) {
            const jump_patch = prog.pc() + 1;
            try prog.pushN(2, 0);
            try prog.op(0x56);
            try prog.pushN(2, 0x5b5b);
            const real = prog.pc();
            try prog.op(0x5b);
            const target: usize = if (r.uintLessThan(u8, 5) == 0) real - 1 else real;
            prog.code.items[jump_patch] = @truncate(target >> 8);
            prog.code.items[jump_patch + 1] = @truncate(target);
        }
        try prog.op(0x58);
        try prog.op(0x5a);
        try prog.op(0x01);
    }

    /// A message call whose arguments are explicit.
    fn call(self: *const Gen, prog: *Asm) !void {
        const r = self.r;
        const targets = [_]Address{ CONTRACT_B, CONTRACT_B, CONTRACT_B, CONTRACT_A, EOA, DEAD };
        const target = targets[r.uintLessThan(usize, targets.len)];
        const kind: u8 = blk: {
            const pick = r.uintLessThan(u8, 8);
            if (pick < 3) break :blk 0xf1;
            if (pick < 5 and self.has(.BYZANTIUM)) break :blk 0xfa;
            if (pick < 7 and self.has(.HOMESTEAD)) break :blk 0xf4;
            break :blk 0xf2;
        };
        try prog.push(self.smallSize() % 96); // out size
        try prog.push(self.smallOffset() % 256); // out offset
        try prog.push(self.smallSize() % 96); // in size
        try prog.push(self.smallOffset() % 256); // in offset
        if (kind == 0xf1 or kind == 0xf2) try prog.push(if (r.uintLessThan(u8, 3) == 0) 1 + r.uintLessThan(u256, 4) else 0);
        try prog.pushAddr(target);
        try prog.push(switch (r.uintLessThan(u8, 5)) {
            0 => 0,
            1 => r.uintLessThan(u256, 3000),
            2 => r.uintLessThan(u256, 60_000),
            3 => max_u256,
            else => 200_000,
        });
        try prog.op(kind);
        // Record the success flag and, where available, the return data size.
        try prog.push(0x40);
        try prog.op(0x52);
        if (self.has(.BYZANTIUM)) {
            try prog.op(0x3d);
            try prog.push(0x60);
            try prog.op(0x52);
            if (r.boolean()) {
                // Copy up to the whole return data; a size past the end must fail.
                try prog.op(0x3d);
                if (r.uintLessThan(u8, 8) == 0) {
                    try prog.push(1);
                    try prog.op(0x01);
                }
                try prog.push(0);
                try prog.push(0x80);
                try prog.op(0x3e);
            }
        }
    }

    /// Faults: stack underflow and overflow, undefined opcodes, absurd memory ranges.
    fn adversarial(self: *const Gen, prog: *Asm) !void {
        const r = self.r;
        switch (r.uintLessThan(u8, 9)) {
            0 => {
                // Stack overflow: 1025 pushes via a loop-free DUP chain.
                try prog.push(1);
                for (0..1024) |_| try prog.op(0x80);
            },
            1 => {
                // Exactly 1024 items, then succeed.
                try prog.push(1);
                for (0..1023) |_| try prog.op(0x80);
                try prog.op(0x00);
            },
            2 => try prog.op(([_]u8{ 0x01, 0x50, 0x52, 0x55, 0x56, 0x57, 0x80, 0x90, 0xa1, 0xf3, 0x9f, 0x8f })[r.uintLessThan(usize, 12)]),
            3 => try prog.op(([_]u8{ 0x0c, 0x0f, 0x1f, 0x21, 0x2f, 0x4b, 0x4f, 0xa5, 0xb0, 0xc0, 0xd0, 0xe0, 0xef, 0xf6, 0xf7, 0xf8, 0xfb, 0xfc, 0xfe })[r.uintLessThan(usize, 19)]),
            4 => {
                // Huge memory offset with a non-zero size: out of gas.
                try prog.push(1);
                try prog.push(randomWord(r) | (1 << 40));
                try prog.op(self.choose(&.{ 0x52, 0x53, 0x51, 0x20, 0xf3, 0xfd, 0xa0 }));
            },
            5 => {
                // Zero-size range at a huge offset: no expansion, no charge.
                const big = randomWord(r) | (1 << 40);
                switch (r.uintLessThan(u8, 7)) {
                    0 => {
                        try prog.push(0);
                        try prog.push(big);
                        try prog.op(0xf3);
                    },
                    1 => {
                        try prog.push(0);
                        try prog.push(big);
                        try prog.op(self.revertOr(0xf3));
                    },
                    2 => {
                        try prog.push(0);
                        try prog.push(big);
                        try prog.op(0x20);
                        try prog.op(0x50);
                    },
                    3 => {
                        try prog.push(0);
                        try prog.push(big);
                        try prog.op(0xa0);
                    },
                    4 => {
                        try prog.push(0);
                        try prog.push(big);
                        try prog.push(big);
                        try prog.op(if (self.has(.CANCUN)) 0x5e else 0x39);
                    },
                    5 => {
                        try prog.push(0);
                        try prog.push(big);
                        try prog.push(big);
                        try prog.op(0x37);
                    },
                    else => {
                        try prog.push(0);
                        try prog.push(big);
                        try prog.push(big);
                        try prog.op(0x39);
                    },
                }
                try prog.op(0x00);
            },
            6 => {
                // Truncated trailing PUSH.
                try prog.push(7);
                try prog.op(0x60 + r.uintLessThan(u8, 32));
                for (0..r.uintLessThan(usize, 4)) |_| try prog.op(r.int(u8));
            },
            7 => {
                // Jump to an arbitrary word.
                try prog.push(randomWord(r));
                try prog.op(0x56);
            },
            else => {
                // CALLDATALOAD / CALLDATACOPY far past the calldata.
                try prog.push(randomWord(r));
                try prog.op(0x35);
                try prog.push(32);
                try prog.push(randomWord(r));
                try prog.push(0);
                try prog.op(0x37);
                try prog.push(32);
                try prog.push(0);
                try prog.op(0xf3);
            },
        }
    }

    /// Opcode soup over the instructions the reference models, with a rough stack model
    /// so that most instructions have their operands.
    fn soup(self: *const Gen, prog: *Asm, steps: usize) !void {
        const r = self.r;
        const table = [_]struct { opcode: u8, pops: u8, pushes: u8 }{
            .{ .opcode = 0x01, .pops = 2, .pushes = 1 }, .{ .opcode = 0x02, .pops = 2, .pushes = 1 },
            .{ .opcode = 0x03, .pops = 2, .pushes = 1 }, .{ .opcode = 0x04, .pops = 2, .pushes = 1 },
            .{ .opcode = 0x05, .pops = 2, .pushes = 1 }, .{ .opcode = 0x06, .pops = 2, .pushes = 1 },
            .{ .opcode = 0x07, .pops = 2, .pushes = 1 }, .{ .opcode = 0x08, .pops = 3, .pushes = 1 },
            .{ .opcode = 0x09, .pops = 3, .pushes = 1 }, .{ .opcode = 0x0b, .pops = 2, .pushes = 1 },
            .{ .opcode = 0x10, .pops = 2, .pushes = 1 }, .{ .opcode = 0x12, .pops = 2, .pushes = 1 },
            .{ .opcode = 0x14, .pops = 2, .pushes = 1 }, .{ .opcode = 0x15, .pops = 1, .pushes = 1 },
            .{ .opcode = 0x16, .pops = 2, .pushes = 1 }, .{ .opcode = 0x17, .pops = 2, .pushes = 1 },
            .{ .opcode = 0x18, .pops = 2, .pushes = 1 }, .{ .opcode = 0x19, .pops = 1, .pushes = 1 },
            .{ .opcode = 0x1a, .pops = 2, .pushes = 1 }, .{ .opcode = 0x1b, .pops = 2, .pushes = 1 },
            .{ .opcode = 0x1c, .pops = 2, .pushes = 1 }, .{ .opcode = 0x1d, .pops = 2, .pushes = 1 },
            .{ .opcode = 0x30, .pops = 0, .pushes = 1 }, .{ .opcode = 0x31, .pops = 1, .pushes = 1 },
            .{ .opcode = 0x33, .pops = 0, .pushes = 1 }, .{ .opcode = 0x34, .pops = 0, .pushes = 1 },
            .{ .opcode = 0x36, .pops = 0, .pushes = 1 }, .{ .opcode = 0x38, .pops = 0, .pushes = 1 },
            .{ .opcode = 0x3b, .pops = 1, .pushes = 1 }, .{ .opcode = 0x3f, .pops = 1, .pushes = 1 },
            .{ .opcode = 0x47, .pops = 0, .pushes = 1 }, .{ .opcode = 0x50, .pops = 1, .pushes = 0 },
            .{ .opcode = 0x54, .pops = 1, .pushes = 1 }, .{ .opcode = 0x58, .pops = 0, .pushes = 1 },
            .{ .opcode = 0x59, .pops = 0, .pushes = 1 }, .{ .opcode = 0x5a, .pops = 0, .pushes = 1 },
            .{ .opcode = 0x5b, .pops = 0, .pushes = 0 }, .{ .opcode = 0x5c, .pops = 1, .pushes = 1 },
            .{ .opcode = 0x80, .pops = 0, .pushes = 1 }, .{ .opcode = 0x81, .pops = 0, .pushes = 1 },
            .{ .opcode = 0x90, .pops = 0, .pushes = 0 }, .{ .opcode = 0x91, .pops = 0, .pushes = 0 },
        };
        var depth: usize = 0;
        for (0..steps) |_| {
            const entry = table[r.uintLessThan(usize, table.len)];
            if (!available(self.fork, entry.opcode)) continue;
            const needed: usize = if (entry.opcode >= 0x80) (entry.opcode & 0x0f) + 2 else entry.pops;
            while (depth < needed and r.uintLessThan(u8, 12) != 0) {
                try prog.push(if (r.boolean()) randomWord(r) else r.uintLessThan(u256, 64));
                depth += 1;
            }
            try prog.op(entry.opcode);
            depth = depth -| entry.pops;
            depth += entry.pushes;
        }
    }
};

fn randomFork(r: std.Random) usize {
    return switch (r.uintLessThan(u8, 10)) {
        0, 1, 2, 3 => FORK_CANCUN,
        4, 5 => FORK_OSAKA,
        6 => 13, // PRAGUE
        7 => 8 + r.uintLessThan(usize, 4), // BERLIN..SHANGHAI
        else => r.uintLessThan(usize, FORKS.len),
    };
}

fn fuzzEvm(suite: *Suite, r: std.Random, arena: *std.heap.ArenaAllocator) anyerror!void {
    for (0..suite.iters) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const gen = Gen{ .r = r, .a = a, .fork = randomFork(r) };
        var prog = gen.newAsm();
        var callee = gen.newAsm();
        var slots: std.ArrayList(Slot) = .empty;
        var req = ExecReq{ .fork = gen.fork, .gas = 0, .code_a = &.{} };
        var class: []const u8 = undefined;

        for (0..r.uintLessThan(usize, 5)) |_| {
            try slots.append(a, .{ .who = if (r.boolean()) 'a' else 'b', .slot = gen.slotKey(), .value = 1 + r.uintLessThan(u256, 3) });
        }
        req.calldata = try randomBytes(r, a, r.uintLessThan(usize, 80));
        req.bal_a = r.uintLessThan(u256, 10);
        req.bal_b = r.uintLessThan(u256, 10);

        switch (r.uintLessThan(u8, 16)) {
            0, 1 => {
                class = "arithmetic/bitwise/environment program";
                try gen.arithmetic(&prog, 4 + r.uintLessThan(usize, 30));
                try gen.finishWithTop(&prog);
            },
            2, 3 => {
                class = "memory/MCOPY/copy program";
                try gen.memory(&prog, 2 + r.uintLessThan(usize, 16));
            },
            4, 5 => {
                class = "storage/transient/log program";
                try gen.storage(&prog, 2 + r.uintLessThan(usize, 14), true);
            },
            6, 7 => {
                class = "control-flow program";
                try gen.control(&prog);
                try gen.finishWithTop(&prog);
            },
            8, 9, 10 => {
                class = "message-call program";
                try gen.storage(&prog, r.uintLessThan(usize, 4), false);
                for (0..1 + r.uintLessThan(usize, 3)) |_| try gen.call(&prog);
                try gen.storage(&prog, r.uintLessThan(usize, 3), false);
                try prog.push(0xa0);
                try prog.push(0);
                try prog.op(if (r.uintLessThan(u8, 5) == 0) gen.revertOr(0xf3) else 0xf3);
                // Callee: state changes, then return, revert, fault or run out of gas.
                switch (r.uintLessThan(u8, 4)) {
                    0 => try gen.memory(&callee, 1 + r.uintLessThan(usize, 5)),
                    1 => {
                        try gen.arithmetic(&callee, 3 + r.uintLessThan(usize, 8));
                        try gen.finishWithTop(&callee);
                    },
                    else => try gen.storage(&callee, 1 + r.uintLessThan(usize, 8), true),
                }
            },
            11 => {
                class = "adversarial program";
                if (r.boolean()) try gen.storage(&prog, r.uintLessThan(usize, 3), false);
                try gen.adversarial(&prog);
            },
            12 => {
                class = "static-context program";
                req.static = true;
                switch (r.uintLessThan(u8, 3)) {
                    0 => try gen.storage(&prog, 1 + r.uintLessThan(usize, 5), true),
                    1 => try gen.memory(&prog, 1 + r.uintLessThan(usize, 8)),
                    else => {
                        try gen.call(&prog);
                        try prog.push(0xa0);
                        try prog.push(0);
                        try prog.op(0xf3);
                        try gen.storage(&callee, 1 + r.uintLessThan(usize, 4), true);
                    },
                }
            },
            13 => {
                class = "opcode soup";
                try gen.soup(&prog, 5 + r.uintLessThan(usize, 60));
                if (r.boolean()) try gen.finishWithTop(&prog);
            },
            14 => {
                class = "fusion-pattern program";
                // PUSH+op, PUSH+JUMP(I), DUP/SWAP runs, PUSH+MSTORE/MLOAD, multi-PUSH.
                try prog.push(randomWord(r));
                for (0..3 + r.uintLessThan(usize, 20)) |_| {
                    switch (r.uintLessThan(u8, 9)) {
                        0 => {
                            try prog.pushN(1 + r.uintLessThan(u8, 32), randomWord(r) & 0xffffff);
                            try prog.op(gen.choose(&.{ 0x01, 0x02, 0x03, 0x04, 0x16, 0x17, 0x18, 0x1b, 0x1c, 0x10, 0x11, 0x14 }));
                        },
                        1 => {
                            try prog.op(0x80);
                            try prog.push(gen.smallOffset() % 128);
                            try prog.op(0x52);
                        },
                        2 => {
                            try prog.push(gen.smallOffset() % 128);
                            try prog.op(0x51);
                            try prog.op(0x01);
                        },
                        3 => {
                            const patch = prog.pc() + 1;
                            try prog.pushN(1, 0);
                            try prog.op(0x56);
                            try prog.op(0xfe);
                            if (prog.pc() < 256) prog.code.items[patch] = @intCast(prog.pc());
                            try prog.op(0x5b);
                        },
                        4 => {
                            try prog.op(0x80);
                            try prog.op(0x15);
                            const patch = prog.pc() + 1;
                            try prog.pushN(1, 0);
                            try prog.op(0x57);
                            try prog.push(1);
                            try prog.op(0x01);
                            if (prog.pc() < 256) prog.code.items[patch] = @intCast(prog.pc());
                            try prog.op(0x5b);
                        },
                        5 => {
                            try prog.op(0x80);
                            try prog.op(0x81);
                            try prog.op(0x01);
                            try prog.op(0x90);
                            try prog.op(0x50);
                        },
                        6 => {
                            try prog.push(randomWord(r));
                            try prog.push(randomWord(r));
                            try prog.push(randomWord(r));
                            try prog.op(0x01);
                            try prog.op(0x02);
                            try prog.op(0x18);
                        },
                        7 => {
                            try prog.op(0x80);
                            try prog.push(r.uintLessThan(u256, 4));
                            try prog.op(0x55);
                        },
                        else => {
                            try prog.op(0x15);
                            try prog.op(0x15);
                            try prog.push(2);
                            try prog.op(0x02);
                        },
                    }
                }
                try gen.finishWithTop(&prog);
            },
            else => {
                class = "self-destruct program";
                try gen.storage(&prog, r.uintLessThan(usize, 3), false);
                const targets = [_]Address{ EOA, DEAD, CONTRACT_B, CONTRACT_A, ORIGIN };
                try prog.pushAddr(targets[r.uintLessThan(usize, targets.len)]);
                try prog.op(0xff);
            },
        }

        req.code_a = prog.out();
        req.code_b = callee.out();
        req.slots = slots.items;
        if (!req.static and r.uintLessThan(u8, 5) == 0) req.value = r.uintLessThan(u256, 1000);
        // Gas: generous, tight (out-of-gas mid-program) or below intrinsic.
        req.gas = switch (r.uintLessThan(u8, 12)) {
            0 => r.uintLessThan(u64, 21_000),
            1, 2, 3 => 21_000 + r.uintLessThan(u64, 30_000),
            4, 5 => 50_000 + r.uintLessThan(u64, 200_000),
            else => 1_000_000 + r.uintLessThan(u64, 4_000_000),
        };
        try checkExec(suite, a, .evm_exec, class, &req);
    }
}

/// Deterministic probe matrices for boundary behaviour that random programs rarely reach.
fn fuzzProbes(suite: *Suite, _: std.Random, arena: *std.heap.ArenaAllocator) anyerror!void {
    const probe = ExecCheck{ .minimize = false, .class_per_fork = false };

    // (1) Opcode availability: an opcode is invalid before the fork that introduced it.
    const gated = [_]struct { opcode: u8, name: []const u8 }{
        .{ .opcode = 0x1b, .name = "SHL" },            .{ .opcode = 0x1c, .name = "SHR" },
        .{ .opcode = 0x1d, .name = "SAR" },            .{ .opcode = 0x1e, .name = "CLZ" },
        .{ .opcode = 0x3d, .name = "RETURNDATASIZE" }, .{ .opcode = 0x3e, .name = "RETURNDATACOPY" },
        .{ .opcode = 0x3f, .name = "EXTCODEHASH" },    .{ .opcode = 0x46, .name = "CHAINID" },
        .{ .opcode = 0x47, .name = "SELFBALANCE" },    .{ .opcode = 0x48, .name = "BASEFEE" },
        .{ .opcode = 0x49, .name = "BLOBHASH" },       .{ .opcode = 0x4a, .name = "BLOBBASEFEE" },
        .{ .opcode = 0x5c, .name = "TLOAD" },          .{ .opcode = 0x5d, .name = "TSTORE" },
        .{ .opcode = 0x5e, .name = "MCOPY" },          .{ .opcode = 0x5f, .name = "PUSH0" },
        .{ .opcode = 0xf4, .name = "DELEGATECALL" },   .{ .opcode = 0xf5, .name = "CREATE2" },
        .{ .opcode = 0xfa, .name = "STATICCALL" },     .{ .opcode = 0xfd, .name = "REVERT" },
    };
    for (0..FORKS.len) |fork_index| {
        for (gated) |entry| {
            // The reference does not model CREATE2 itself; it is probed only where it must be invalid.
            if (entry.opcode == 0xf5 and available(fork_index, 0xf5)) continue;
            _ = arena.reset(.retain_capacity);
            const a = arena.allocator();
            var prog = Asm{ .a = a, .push0 = false };
            for (0..7) |_| try prog.pushN(1, 0);
            try prog.op(entry.opcode);
            try prog.op(0x00);
            const req = ExecReq{ .fork = fork_index, .gas = 200_000, .code_a = prog.out() };
            const class = try std.fmt.allocPrint(a, "opcode availability: 0x{x:0>2} {s} (introduced in {s})", .{ entry.opcode, entry.name, @tagName(introducedIn(entry.opcode).?) });
            try checkExecWith(suite, a, .evm_exec, class, &req, probe);
        }
    }

    // (2) Zero-length memory ranges never expand memory and never fail, whatever the offset.
    // (3) Non-zero ranges that cannot be paid for run out of gas; they never crash.
    const RangeOp = enum { ret, revert, keccak, log0, mcopy_src, mcopy_dst, calldatacopy, codecopy, returndatacopy, extcodecopy, call_in, call_out };
    const offsets = [_]u256{ 0x40, (1 << 24) - 1, 1 << 24, 1 << 32, (1 << 64) - 1, 1 << 64, max_u256 };
    const sizes = [_]u256{ 0, 1, 1 << 24, (1 << 64) - 1, max_u256 };
    for ([_]usize{ FORK_CANCUN, 9 }) |fork_index| {
        for ([_]RangeOp{ .ret, .revert, .keccak, .log0, .mcopy_src, .mcopy_dst, .calldatacopy, .codecopy, .returndatacopy, .extcodecopy, .call_in, .call_out }) |range_op| {
            for (offsets) |offset| for (sizes) |size| {
                // Small ranges are ordinary execution, covered by the random programs.
                if (size == 1 and offset < (1 << 24) - 1) continue;
                if (range_op == .mcopy_src or range_op == .mcopy_dst) if (!available(fork_index, 0x5e)) continue;
                _ = arena.reset(.retain_capacity);
                const a = arena.allocator();
                var prog = Asm{ .a = a, .push0 = false };
                switch (range_op) {
                    .ret, .revert => {
                        try prog.push(size);
                        try prog.push(offset);
                        try prog.op(if (range_op == .ret) 0xf3 else 0xfd);
                    },
                    .keccak => {
                        try prog.push(size);
                        try prog.push(offset);
                        try prog.op(0x20);
                        try prog.op(0x50);
                    },
                    .log0 => {
                        try prog.push(size);
                        try prog.push(offset);
                        try prog.op(0xa0);
                    },
                    .mcopy_src, .mcopy_dst => {
                        try prog.push(size);
                        try prog.push(if (range_op == .mcopy_src) offset else 0);
                        try prog.push(if (range_op == .mcopy_dst) offset else 0);
                        try prog.op(0x5e);
                    },
                    .calldatacopy, .codecopy, .returndatacopy => {
                        // RETURNDATACOPY of a non-empty range with no return data fails by rule.
                        try prog.push(size);
                        try prog.push(0);
                        try prog.push(offset);
                        try prog.op(switch (range_op) {
                            .calldatacopy => 0x37,
                            .codecopy => 0x39,
                            else => 0x3e,
                        });
                    },
                    .extcodecopy => {
                        try prog.push(size);
                        try prog.push(0);
                        try prog.push(offset);
                        try prog.pushAddr(CONTRACT_B);
                        try prog.op(0x3c);
                    },
                    .call_in, .call_out => {
                        try prog.push(if (range_op == .call_out) size else 0);
                        try prog.push(if (range_op == .call_out) offset else 0);
                        try prog.push(if (range_op == .call_in) size else 0);
                        try prog.push(if (range_op == .call_in) offset else 0);
                        try prog.push(0);
                        try prog.pushAddr(EOA);
                        try prog.push(0);
                        try prog.op(0xf1);
                        try prog.op(0x50);
                    },
                }
                try prog.op(0x00);
                const req = ExecReq{ .fork = fork_index, .gas = 1_000_000, .code_a = prog.out() };
                const kind: []const u8 = if (size != 0)
                    "unpayable non-zero range"
                else if (offset < (1 << 24))
                    "zero-length range, offset below 2^24"
                else
                    "zero-length range, offset 2^24 or above";
                const class = try std.fmt.allocPrint(a, "memory range ({s}): {s}", .{ kind, @tagName(range_op) });
                try checkExecWith(suite, a, .evm_exec, class, &req, probe);
            };
        }
    }

    // (4) EXP dynamic gas per exponent byte on every fork (EIP-160).
    for (0..FORKS.len) |fork_index| {
        for ([_]u256{ 0, 1, 0xff, 0x100, 1 << 64, 1 << 128, 1 << 255, max_u256 }) |exponent| {
            _ = arena.reset(.retain_capacity);
            const a = arena.allocator();
            var prog = Asm{ .a = a, .push0 = false };
            try prog.push(exponent);
            try prog.push(3);
            try prog.op(0x0a);
            try prog.op(0x50);
            try prog.op(0x00);
            const req = ExecReq{ .fork = fork_index, .gas = 100_000, .code_a = prog.out() };
            try checkExecWith(suite, a, .evm_exec, "EXP dynamic gas (EIP-160)", &req, probe);
        }
    }

    // (5) SSTORE at the EIP-2200 sentry and at the exact out-of-gas boundary.
    for (0..FORKS.len) |fork_index| {
        for ([_]u256{ 0, 1 }) |original| for ([_]u256{ 0, 1, 2 }) |new| {
            for ([_]u64{ 0, 99, 100, 199, 200, 799, 800, 2199, 2200, 2299, 2300, 2301, 2899, 2900, 4999, 5000, 5001, 19_999, 20_000, 22_099, 22_100, 22_101 }) |budget| {
                _ = arena.reset(.retain_capacity);
                const a = arena.allocator();
                var prog = Asm{ .a = a, .push0 = false };
                try prog.push(new);
                try prog.pushN(1, 0);
                try prog.op(0x55);
                try prog.op(0x00);
                const slots = [_]Slot{.{ .who = 'a', .slot = 0, .value = original }};
                // 21000 intrinsic + two PUSH1 (6 gas) + the budget left for SSTORE itself.
                const preset: []const Slot = if (original != 0) &slots else &.{};
                const req = ExecReq{ .fork = fork_index, .gas = 21_006 + budget, .code_a = prog.out(), .slots = preset };
                try checkExecWith(suite, a, .evm_exec, "SSTORE sentry / out-of-gas boundary", &req, probe);
            }
        };
    }

    // (6) Self-recursive CALL: the all-but-one-64th rule at every depth until gas runs out.
    for (0..FORKS.len) |fork_index| {
        for ([_]u64{ 30_000, 100_000, 1_000_000, 5_000_000 }) |gas| {
            _ = arena.reset(.retain_capacity);
            const a = arena.allocator();
            var prog = Asm{ .a = a, .push0 = false };
            // Count the depth reached in storage slot 0, then recurse into this contract.
            try prog.pushN(1, 0);
            try prog.op(0x54);
            try prog.pushN(1, 1);
            try prog.op(0x01);
            try prog.pushN(1, 0);
            try prog.op(0x55);
            for (0..5) |_| try prog.pushN(1, 0);
            try prog.op(0x30);
            try prog.op(0x5a);
            try prog.op(0xf1);
            try prog.op(0x50);
            try prog.op(0x00);
            const req = ExecReq{ .fork = fork_index, .gas = gas, .code_a = prog.out() };
            try checkExecWith(suite, a, .evm_exec, "self-recursive CALL (63/64 rule, call depth)", &req, probe);
        }
    }
    // (7) DIFFICULTY (0x44) before the Merge, PREVRANDAO (EIP-4399) from the Merge on.
    for (0..FORKS.len) |fork_index| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        var prog = Asm{ .a = a, .push0 = false };
        try prog.op(0x44);
        try prog.pushN(1, 0);
        try prog.op(0x52);
        try prog.pushN(1, 32);
        try prog.pushN(1, 0);
        try prog.op(0xf3);
        const req = ExecReq{ .fork = fork_index, .gas = 100_000, .code_a = prog.out() };
        try checkExecWith(suite, a, .evm_exec, "opcode 0x44: DIFFICULTY before the Merge, PREVRANDAO after (EIP-4399)", &req, probe);
    }

    // (8) EIP-2929: addresses and slots warmed inside a call frame that fails are cold again.
    for (0..FORKS.len) |fork_index| {
        if (!forkAtLeast(fork_index, .BERLIN)) continue;
        for ([_]bool{ false, true }) |slot_variant| for ([_]u8{ 0xfd, 0xfe }) |ending| {
            _ = arena.reset(.retain_capacity);
            const a = arena.allocator();
            var callee = Asm{ .a = a, .push0 = false };
            var prog = Asm{ .a = a, .push0 = false };
            // Callee: touch the account or slot, then revert (0xfd) or fault (0xfe).
            if (slot_variant) {
                try callee.pushN(1, 5);
                try callee.op(0x54);
            } else {
                try callee.pushAddr(EOA);
                try callee.op(0x31);
            }
            try callee.op(0x50);
            try callee.pushN(1, 0);
            try callee.pushN(1, 0);
            try callee.op(ending);
            // Caller: run the callee (DELEGATECALL keeps this contract's storage), then touch the same thing.
            for (0..4) |_| try prog.pushN(1, 0);
            if (!slot_variant) try prog.pushN(1, 0);
            try prog.pushAddr(CONTRACT_B);
            try prog.pushN(3, 200_000);
            try prog.op(if (slot_variant) 0xf4 else 0xf1);
            try prog.op(0x50);
            if (slot_variant) {
                try prog.pushN(1, 5);
                try prog.op(0x54);
            } else {
                try prog.pushAddr(EOA);
                try prog.op(0x31);
            }
            try prog.op(0x50);
            try prog.op(0x00);
            const req = ExecReq{ .fork = fork_index, .gas = 1_000_000, .code_a = prog.out(), .code_b = callee.out() };
            const class: []const u8 = if (slot_variant)
                "EIP-2929: storage slot warmed in a failed call frame must be cold again"
            else
                "EIP-2929: address warmed in a failed call frame must be cold again";
            try checkExecWith(suite, a, .evm_exec, class, &req, probe);
        };
    }

    // (9) Before EIP-161 a zero-value CALL creates a missing account, so only the first
    //     such CALL pays the new-account surcharge.
    for (0..FORKS.len) |fork_index| {
        for ([_]usize{ 1, 2, 3 }) |calls| {
            _ = arena.reset(.retain_capacity);
            const a = arena.allocator();
            var prog = Asm{ .a = a, .push0 = false };
            for (0..calls) |_| {
                for (0..5) |_| try prog.pushN(1, 0);
                try prog.pushAddr(DEAD);
                try prog.pushN(2, 5000);
                try prog.op(0xf1);
                try prog.op(0x50);
            }
            try prog.op(0x00);
            const req = ExecReq{ .fork = fork_index, .gas = 500_000, .code_a = prog.out() };
            try checkExecWith(suite, a, .evm_exec, "zero-value CALL to a non-existent account (new-account surcharge, EIP-161)", &req, probe);
        }
    }
}

// ---------------------------------------------------------------------------------------
// 5. Base / OP Stack
// ---------------------------------------------------------------------------------------

const opstack = layer2.optimism;
const basel2 = layer2.base;
const OpSpecId = layer2.OpSpecId;

fn randomSpec(r: std.Random) OpSpecId {
    return OpSpecId.ALL[r.uintLessThan(usize, OpSpecId.ALL.len)];
}

fn randomEnvelope(r: std.Random, a: Allocator) ![]u8 {
    const len: usize = switch (r.uintLessThan(u8, 8)) {
        0 => 0,
        1 => r.uintLessThan(usize, 13),
        2 => 13 + r.uintLessThan(usize, 4),
        3, 4 => r.uintLessThan(usize, 300),
        5 => r.uintLessThan(usize, 2500),
        else => r.uintLessThan(usize, 120),
    };
    const out = try randomBytes(r, a, len);
    switch (r.uintLessThan(u8, 5)) {
        0 => {},
        1 => for (out) |*byte| {
            if (r.boolean()) byte.* = 0;
        },
        2 => for (out, 0..) |*byte, index| {
            // Compressible: short repeating period.
            byte.* = @truncate(index % (1 + r.uintLessThan(usize, 7)));
        },
        3 => @memset(out, r.int(u8)),
        else => for (out, 0..) |*byte, index| {
            if (index >= 24) byte.* = out[index - 24 + r.uintLessThan(usize, 3)];
        },
    }
    if (out.len > 0) {
        out[0] = switch (r.uintLessThan(u8, 8)) {
            0 => 0x7e,
            1 => 0x02,
            2 => 0x00,
            else => out[0],
        };
    }
    return out;
}

fn randomFeeWord(r: std.Random) u256 {
    return switch (r.uintLessThan(u8, 8)) {
        0 => 0,
        1 => r.uintLessThan(u256, 1000),
        2, 3 => r.uintLessThan(u256, 100_000_000_000),
        4 => r.int(u64),
        5 => max_u256,
        6 => r.int(u256),
        else => r.uintLessThan(u256, 5_000_000),
    };
}

fn randomInfo(r: std.Random) opstack.L1BlockInfo {
    var info = opstack.L1BlockInfo.empty();
    info.l1_base_fee = randomFeeWord(r);
    info.l1_fee_overhead = if (r.uintLessThan(u8, 4) == 0) null else randomFeeWord(r);
    info.l1_base_fee_scalar = randomFeeWord(r);
    info.l1_blob_base_fee = if (r.uintLessThan(u8, 4) == 0) null else randomFeeWord(r);
    info.l1_blob_base_fee_scalar = if (r.uintLessThan(u8, 4) == 0) null else randomFeeWord(r);
    info.operator_fee_scalar = if (r.uintLessThan(u8, 5) == 0) null else randomFeeWord(r);
    info.operator_fee_constant = if (r.uintLessThan(u8, 5) == 0) null else randomFeeWord(r);
    info.empty_ecotone_scalars = r.uintLessThan(u8, 5) == 0;
    return info;
}

fn appendInfo(line: *Line, info: opstack.L1BlockInfo) !void {
    try line.num(info.l1_base_fee);
    try line.opt(info.l1_fee_overhead);
    try line.num(info.l1_base_fee_scalar);
    try line.opt(info.l1_blob_base_fee);
    try line.opt(info.l1_blob_base_fee_scalar);
    try line.opt(info.operator_fee_scalar);
    try line.opt(info.operator_fee_constant);
    try line.flag(info.empty_ecotone_scalars);
}

fn feeAnswer(a: Allocator, result: anyerror!u256) ![]const u8 {
    if (result) |value| {
        return std.fmt.allocPrint(a, "{x}", .{value});
    } else |err| {
        return std.fmt.allocPrint(a, "ERR {s}", .{@errorName(err)});
    }
}

fn widen(value: ?usize) ?u256 {
    return if (value) |v| v else null;
}

fn randomGas(r: std.Random) u64 {
    return switch (r.uintLessThan(u8, 5)) {
        0 => 0,
        1 => 21_000,
        2 => r.uintLessThan(u64, 30_000_000),
        3 => r.int(u64),
        else => r.uintLessThan(u64, 200_000),
    };
}

var zero_input: [140_000]u8 = @splat(0);

fn fuzzLayer2(suite: *Suite, r: std.Random, arena: *std.heap.ArenaAllocator) anyerror!void {
    const rounds = suite.iters / 4;
    for (0..rounds) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const spec = randomSpec(r);
        const tx = try randomEnvelope(r, a);
        var info = randomInfo(r);
        const gas_limit = randomGas(r);
        const gas_used = if (r.uintLessThan(u8, 8) == 0) randomGas(r) else r.uintAtMost(u64, gas_limit);

        // FastLZ size and the Fjord size estimate.
        {
            var line = Line.init(a);
            try line.tok("L");
            try line.tok("FLZ");
            try line.bytes(tx);
            var answer = Line.init(a);
            try answer.num(opstack.fast_lz.flzCompressLen(tx));
            try answer.num(opstack.l1_block_info.estimatedSizeFjord(tx));
            try suite.check(.layer2_base, "FastLZ length / Fjord estimated size", line.str(), answer.str());
        }
        // Data gas.
        {
            var line = Line.init(a);
            try line.tok("L");
            try line.tok("DATAGAS");
            try line.tok(spec.name());
            try line.bytes(tx);
            var answer = Line.init(a);
            try answer.num(opstack.l1_block_info.dataGas(tx, spec));
            try suite.check(.layer2_base, "L1 data gas", line.str(), answer.str());
        }
        // L1 data fee.
        {
            var line = Line.init(a);
            try line.tok("L");
            try line.tok("L1COST");
            try line.tok(spec.name());
            try line.bytes(tx);
            try appendInfo(&line, info);
            info.clearTxL1Cost();
            var answer = Line.init(a);
            try answer.num(info.calculateTxL1Cost(tx, spec));
            info.clearTxL1Cost();
            try suite.check(.layer2_base, "L1 data fee (Bedrock/Ecotone/Fjord)", line.str(), answer.str());
        }
        // Operator fee and its refund.
        {
            var line = Line.init(a);
            try line.tok("L");
            try line.tok("OPFEE");
            try line.tok(spec.name());
            try line.bytes(tx);
            try line.num(gas_limit);
            try appendInfo(&line, info);
            try suite.check(.layer2_base, "operator fee (Isthmus/Jovian)", line.str(), try feeAnswer(a, info.operatorFee(tx, gas_limit, spec)));

            var line2 = Line.init(a);
            try line2.tok("L");
            try line2.tok("OPREFUND");
            try line2.tok(spec.name());
            try line2.num(gas_limit);
            try line2.num(gas_used);
            try appendInfo(&line2, info);
            try suite.check(.layer2_base, "operator fee refund", line2.str(), try feeAnswer(a, info.operatorFeeRefund(gas_limit, gas_used, spec)));
        }
        // Upfront cost and settlement.
        {
            const gas_price = randomFeeWord(r);
            const base_fee = if (r.uintLessThan(u8, 6) == 0) randomFeeWord(r) else gas_price / (1 + r.uintLessThan(u256, 4));
            const value = randomFeeWord(r);
            var line = Line.init(a);
            try line.tok("L");
            try line.tok("UPFRONT");
            try line.tok(spec.name());
            try line.bytes(tx);
            try line.num(gas_limit);
            try line.num(gas_price);
            try line.num(value);
            try appendInfo(&line, info);
            info.clearTxL1Cost();
            const upfront = basel2.fees.upfrontCost(&info, spec, tx, gas_limit, gas_price, value);
            info.clearTxL1Cost();
            try suite.check(.layer2_base, "upfront cost", line.str(), try feeAnswer(a, upfront));

            var line2 = Line.init(a);
            try line2.tok("L");
            try line2.tok("SETTLE");
            try line2.tok(spec.name());
            try line2.bytes(tx);
            try line2.num(gas_limit);
            try line2.num(gas_used);
            try line2.num(base_fee);
            try line2.num(gas_price);
            try appendInfo(&line2, info);
            var answer = Line.init(a);
            if (basel2.fees.settle(&info, spec, tx, gas_limit, gas_used, base_fee, gas_price)) |s| {
                try answer.num(s.sequencer_fee_vault);
                try answer.num(s.base_fee_vault);
                try answer.num(s.l1_fee_vault);
                try answer.num(s.operator_fee_vault);
                try answer.num(s.caller_refund);
            } else |err| {
                try answer.tok("ERR");
                try answer.tok(@errorName(err));
            }
            info.clearTxL1Cost();
            try suite.check(.layer2_base, "fee settlement", line2.str(), answer.str());
        }
        // DA footprint.
        {
            const scalar = if (r.boolean()) @as(u16, 400) else r.int(u16);
            var line = Line.init(a);
            try line.tok("L");
            try line.tok("DA");
            try line.bytes(tx);
            try line.num(scalar);
            var answer = Line.init(a);
            try answer.num(opstack.da_footprint.txDaFootprint(tx, scalar));
            try suite.check(.layer2_base, "Jovian DA footprint", line.str(), answer.str());
        }
        // Deposit transaction rules.
        {
            const mint: ?u128 = switch (r.uintLessThan(u8, 4)) {
                0 => null,
                1 => 0,
                2 => std.math.maxInt(u128),
                else => r.int(u64),
            };
            const parts = opstack.DepositTransactionParts.deposit(@splat(1), mint, r.uintLessThan(u8, 3) == 0);
            const caller = opstack.deposit.CallerState{
                .balance = if (r.uintLessThan(u8, 6) == 0) max_u256 - r.uintLessThan(u256, 5) else randomFeeWord(r),
                .nonce = if (r.uintLessThan(u8, 6) == 0) std.math.maxInt(u64) else r.uintLessThan(u64, 1000),
            };
            const outcome: opstack.deposit.Outcome = switch (r.uintLessThan(u8, 3)) {
                0 => .success,
                1 => .revert,
                else => .halt,
            };
            const is_call = r.boolean();
            var line = Line.init(a);
            try line.tok("L");
            try line.tok("DEPOSIT");
            try line.tok(spec.name());
            try line.opt(if (mint) |m| @as(u256, m) else null);
            try line.flag(parts.is_system_transaction);
            try line.tok(@tagName(outcome));
            try line.num(gas_limit);
            try line.num(gas_used);
            try line.num(caller.balance);
            try line.num(caller.nonce);
            try line.flag(is_call);

            const pre = opstack.deposit.preExecution(caller, parts, is_call);
            const failed = opstack.deposit.failedDeposit(caller, parts);
            const final = opstack.deposit.finalize(spec, parts, outcome, gas_limit, gas_used);
            var answer = Line.init(a);
            if (opstack.deposit.validate(spec, parts)) |_| try answer.flag(true) else |_| try answer.flag(false);
            try answer.num(pre.balance);
            try answer.num(pre.nonce);
            try answer.num(failed.balance);
            try answer.num(failed.nonce);
            try answer.num(opstack.deposit.failedDepositGasUsed(spec, parts, gas_limit));
            try answer.flag(opstack.deposit.refundsEnabled(spec));
            try answer.num(final.gas_used);
            try answer.flag(final.failed);
            try suite.check(.layer2_base, "deposit transaction (0x7E) rules", line.str(), answer.str());
        }
        // Hardfork schedule: spec at a timestamp, P256VERIFY and BN254 limit there.
        {
            const chain: basel2.BaseChain = if (r.boolean()) .mainnet else .sepolia;
            const schedule = chain.schedule();
            const anchors = [_]u64{
                schedule.genesis_time, schedule.regolith, schedule.canyon,  schedule.delta,   schedule.ecotone, schedule.fjord,
                schedule.granite,      schedule.holocene, schedule.isthmus, schedule.jovian,  schedule.azul.?,  0,
            };
            const anchor = anchors[r.uintLessThan(usize, anchors.len)];
            const timestamp: u64 = switch (r.uintLessThan(u8, 5)) {
                0 => anchor,
                1 => anchor -| 1,
                2 => anchor +| 1,
                3 => anchor +| r.uintLessThan(u64, 10_000_000),
                else => r.uintLessThan(u64, 2_000_000_000),
            };
            var line = Line.init(a);
            try line.tok("L");
            try line.tok("SPECAT");
            try line.tok(@tagName(chain));
            try line.num(timestamp);
            var answer = Line.init(a);
            if (schedule.specAt(timestamp)) |active| {
                try answer.tok(active.name());
                const limit = try basel2.precompiles.bn254PairingMaxInput(chain, timestamp);
                try answer.opt(widen(limit));
                try answer.flag(try basel2.precompiles.hasP256Verify(chain, timestamp));
                try answer.tok(@tagName(active.toEthHardfork()));
            } else |err| {
                try answer.tok("ERR");
                try answer.tok(@errorName(err));
            }
            try suite.check(.layer2_base, "Base hardfork schedule", line.str(), answer.str());
        }
        // BN254 pairing input-size limit, enforced by the precompile wrappers themselves.
        {
            const limit_spec = OpSpecId.ALL[4 + r.uintLessThan(usize, 5)]; // fjord..jovian
            // Always a whole number of 192-byte pairs of zero bytes (points at infinity), so
            // the call succeeds exactly when the size is within the spec's limit.
            const len: usize = switch (r.uintLessThan(u8, 40)) {
                0 => 112_512, // 586 pairs: largest size accepted from Granite (limit 112,687)
                1 => 81_984, // 427 pairs: largest size accepted from Jovian (limit 81,984)
                2, 3, 4 => 112_704, // 587 pairs
                5, 6, 7 => 82_176, // 428 pairs
                8, 9 => 192 * (587 + r.uintLessThan(usize, 100)),
                10, 11 => 192 * (428 + r.uintLessThan(usize, 150)),
                else => 192 * r.uintLessThan(usize, 4),
            };
            var line = Line.init(a);
            try line.tok("L");
            try line.tok("BN254");
            try line.tok(limit_spec.name());
            try line.num(len);
            const input = zero_input[0..len];
            const gas: u64 = std.math.maxInt(u64);
            const result = if (limit_spec.isAtLeast(.JOVIAN))
                opstack.precompiles.bn254PairingJovian(a, input, gas)
            else if (limit_spec.isAtLeast(.GRANITE))
                opstack.precompiles.bn254PairingGranite(a, input, gas)
            else
                evm.precompiles.bn254_pairing.execute(a, input, gas);
            var answer = Line.init(a);
            if (result) |_| {
                try answer.flag(true);
            } else |err| switch (err) {
                error.InvalidInput => try answer.flag(false),
                else => try answer.tok(@errorName(err)),
            }
            try suite.check(.layer2_base, "BN254 pairing input-size limit (Granite/Jovian)", line.str(), answer.str());
        }
    }

    // Constants: per-spec precompile limits and per-chain parameters.
    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();
    for (OpSpecId.ALL) |spec| {
        var line = Line.init(a);
        try line.tok("L");
        try line.tok("LIMITS");
        try line.tok(spec.name());
        const p = opstack.precompiles;
        var answer = Line.init(a);
        try answer.opt(widen(if (spec.isAtLeast(.JOVIAN)) p.BN254_PAIRING_MAX_INPUT_JOVIAN else if (spec.isAtLeast(.GRANITE)) p.BN254_PAIRING_MAX_INPUT_GRANITE else null));
        try answer.opt(widen(if (spec.isAtLeast(.JOVIAN)) p.BLS12_G1_MSM_MAX_INPUT_JOVIAN else if (spec.isAtLeast(.ISTHMUS)) p.BLS12_G1_MSM_MAX_INPUT_ISTHMUS else null));
        try answer.opt(widen(if (spec.isAtLeast(.JOVIAN)) p.BLS12_G2_MSM_MAX_INPUT_JOVIAN else if (spec.isAtLeast(.ISTHMUS)) p.BLS12_G2_MSM_MAX_INPUT_ISTHMUS else null));
        try answer.opt(widen(if (spec.isAtLeast(.JOVIAN)) p.BLS12_PAIRING_MAX_INPUT_JOVIAN else if (spec.isAtLeast(.ISTHMUS)) p.BLS12_PAIRING_MAX_INPUT_ISTHMUS else null));
        try answer.flag(p.isOpPrecompile(p.P256_VERIFY_ADDRESS, spec));
        try answer.tok(@tagName(spec.toEthHardfork()));
        try suite.check(.layer2_base, "per-spec precompile limits", line.str(), answer.str());
    }
    for ([_]basel2.BaseChain{ .mainnet, .sepolia }) |chain| {
        const schedule = chain.schedule();
        var line = Line.init(a);
        try line.tok("L");
        try line.tok("CHAIN");
        try line.tok(@tagName(chain));
        var answer = Line.init(a);
        try answer.num(chain.chainId());
        try answer.num(chain.l1ChainId());
        try answer.num(chain.eip1559Elasticity());
        try answer.num(chain.eip1559Denominator());
        try answer.num(chain.eip1559DenominatorCanyon());
        try answer.num(schedule.delta);
        try answer.num(schedule.azul.?);
        for (OpSpecId.ALL) |spec| try answer.num(schedule.activation(spec));
        try suite.check(.layer2_base, "Base chain parameters and schedule", line.str(), answer.str());
    }
}

// ---------------------------------------------------------------------------------------
// 6. RLP
// ---------------------------------------------------------------------------------------

fn rlpLen(r: std.Random) usize {
    return switch (r.uintLessThan(u8, 12)) {
        0 => 0,
        1 => 1,
        2 => 55,
        3 => 56,
        4 => 57,
        5 => 255,
        6 => 256,
        7 => r.uintLessThan(usize, 2000),
        8 => 65_535 + r.uintLessThan(usize, 3),
        else => r.uintLessThan(usize, 70),
    };
}

fn rlpString(r: std.Random, a: Allocator) ![]u8 {
    const out = try randomBytes(r, a, rlpLen(r));
    if (out.len == 1 and r.boolean()) out[0] &= 0x7f;
    return out;
}

/// Random RLP tree as oracle tokens (`s<hex>` / `l<n> ...`).
fn randomTree(r: std.Random, line: *Line, a: Allocator, depth: usize) !void {
    if (depth == 0 or r.uintLessThan(u8, 3) == 0) {
        const len: usize = if (r.uintLessThan(u8, 8) == 0) 56 + r.uintLessThan(usize, 300) else r.uintLessThan(usize, 12);
        const data = try randomBytes(r, a, len);
        if (data.len == 1 and r.boolean()) data[0] &= 0x7f;
        return line.rlpStr(data);
    }
    const children = r.uintLessThan(usize, 5);
    try line.tok(try std.fmt.allocPrint(a, "l{d}", .{children}));
    for (0..children) |_| try randomTree(r, line, a, depth - 1);
}

fn renderRlp(line: *Line, a: Allocator, data: Rlp.Data) !void {
    switch (data) {
        .String => |text| try line.rlpStr(text),
        .List => |items| {
            try line.tok(try std.fmt.allocPrint(a, "l{d}", .{items.len}));
            for (items) |item| try renderRlp(line, a, item);
        },
    }
}

const DecodeJob = struct { input: []const u8, stream: bool };

fn decodeJob(job: DecodeJob, a: Allocator) anyerror![]const u8 {
    return decodeDirect(a, job.input, job.stream);
}

fn decodeAnswer(a: Allocator, input: []const u8, stream: bool) ![]const u8 {
    return isolated(a, DecodeJob{ .input = input, .stream = stream }, decodeJob);
}

fn decodeDirect(a: Allocator, input: []const u8, stream: bool) ![]const u8 {
    var answer = Line.init(a);
    if (Rlp.decode(a, input, stream)) |decoded| {
        try answer.tok("OK");
        try renderRlp(&answer, a, decoded.data);
        try answer.bytes(decoded.remainder);
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try answer.tok("ERR");
            try answer.tok(@errorName(err));
        },
    }
    return answer.str();
}

fn checkDecode(suite: *Suite, a: Allocator, class: []const u8, input: []const u8, stream: bool) !void {
    var line = Line.init(a);
    try line.tok("R");
    try line.tok("DEC");
    try line.bytes(input);
    try line.flag(stream);
    try suite.check(.rlp, class, line.str(), try decodeAnswer(a, input, stream));
}

fn fuzzRlp(suite: *Suite, r: std.Random, arena: *std.heap.ArenaAllocator) anyerror!void {
    const rounds = suite.iters / 2;
    for (0..rounds) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();

        // Byte strings.
        {
            const data = try rlpString(r, a);
            var line = Line.init(a);
            try line.tok("R");
            try line.tok("ENC");
            try line.rlpStr(data);
            var answer = Line.init(a);
            try answer.bytes(try Rlp.encodeBytes(a, data));
            try suite.check(.rlp, "encode byte string (encodeBytes)", line.str(), answer.str());
            var answer2 = Line.init(a);
            try answer2.bytes(try Rlp.encode(a, @as([]const u8, data)));
            try suite.check(.rlp, "encode byte string (encode)", line.str(), answer2.str());
        }
        // Integers of every width.
        {
            const value = randomWord(r);
            inline for (.{ u8, u16, u32, u64, u128, u256 }) |T| {
                const narrowed: T = @truncate(value);
                var line = Line.init(a);
                try line.tok("R");
                try line.tok("NAT");
                try line.num(narrowed);
                var answer = Line.init(a);
                try answer.bytes(try Rlp.encode(a, narrowed));
                try suite.check(.rlp, "encode integer (" ++ @typeName(T) ++ ")", line.str(), answer.str());
            }
        }
        // Lists of strings, lists of lists, three levels.
        {
            var line = Line.init(a);
            try line.tok("R");
            try line.tok("ENC");
            const count = if (r.uintLessThan(u8, 6) == 0) 0 else r.uintLessThan(usize, 8);
            const flat = try a.alloc([]const u8, count);
            try line.tok(try std.fmt.allocPrint(a, "l{d}", .{count}));
            for (flat) |*item| {
                const data = try rlpString(r, a);
                item.* = data[0..@min(data.len, 300)];
                try line.rlpStr(item.*);
            }
            var answer = Line.init(a);
            try answer.bytes(try Rlp.encode(a, @as([]const []const u8, flat)));
            try suite.check(.rlp, "encode list of strings", line.str(), answer.str());
        }
        {
            var line = Line.init(a);
            try line.tok("R");
            try line.tok("ENC");
            const outer = try a.alloc([]const []const []const u8, r.uintLessThan(usize, 4));
            try line.tok(try std.fmt.allocPrint(a, "l{d}", .{outer.len}));
            for (outer) |*middle_slot| {
                const middle = try a.alloc([]const []const u8, r.uintLessThan(usize, 4));
                try line.tok(try std.fmt.allocPrint(a, "l{d}", .{middle.len}));
                for (middle) |*inner_slot| {
                    const inner = try a.alloc([]const u8, r.uintLessThan(usize, 4));
                    try line.tok(try std.fmt.allocPrint(a, "l{d}", .{inner.len}));
                    for (inner) |*item| {
                        const data = try rlpString(r, a);
                        item.* = data[0..@min(data.len, 40)];
                        try line.rlpStr(item.*);
                    }
                    inner_slot.* = inner;
                }
                middle_slot.* = middle;
            }
            var answer = Line.init(a);
            try answer.bytes(try Rlp.encode(a, @as([]const []const []const []const u8, outer)));
            try suite.check(.rlp, "encode nested lists (3 levels)", line.str(), answer.str());
        }
        // Decode: valid encodings of arbitrary trees (encoded by the specification).
        {
            var tree = Line.init(a);
            try tree.tok("R");
            try tree.tok("ENC");
            try randomTree(r, &tree, a, 1 + r.uintLessThan(usize, 6));
            const encoded_hex = try a.dupe(u8, try suite.oracle.ask(tree.str()));
            const encoded = try parseHexBytes(a, encoded_hex);
            try checkDecode(suite, a, "decode valid encoding", encoded, false);

            // Mutations: truncation, trailing bytes, byte flips, prefix rewrites.
            const mutated = try a.dupe(u8, encoded);
            var input: []const u8 = mutated;
            switch (r.uintLessThan(u8, 6)) {
                0 => input = mutated[0..r.uintAtMost(usize, mutated.len)],
                1 => input = try std.mem.concat(a, u8, &.{ mutated, try randomBytes(r, a, 1 + r.uintLessThan(usize, 4)) }),
                2 => if (mutated.len > 0) {
                    mutated[r.uintLessThan(usize, mutated.len)] = r.int(u8);
                },
                3 => if (mutated.len > 0) {
                    mutated[0] = ([_]u8{ 0x80, 0x81, 0xb7, 0xb8, 0xb9, 0xbf, 0xc0, 0xc1, 0xf7, 0xf8, 0xf9, 0xff })[r.uintLessThan(usize, 12)];
                },
                4 => if (mutated.len > 1) {
                    mutated[1] = if (r.boolean()) 0 else r.uintLessThan(u8, 56);
                },
                else => if (mutated.len > 2) {
                    mutated[r.uintLessThan(usize, mutated.len)] ^= @as(u8, 1) << r.int(u3);
                    mutated[r.uintLessThan(usize, mutated.len)] ^= @as(u8, 1) << r.int(u3);
                },
            }
            try checkDecode(suite, a, "decode mutated encoding", input, r.boolean());
        }
        // Decode: arbitrary bytes.
        {
            const garbage = try randomBytes(r, a, r.uintLessThan(usize, 40));
            if (garbage.len > 0 and r.boolean()) garbage[0] = 0xc0 + r.uintLessThan(u8, 0x40);
            try checkDecode(suite, a, "decode arbitrary bytes", garbage, r.boolean());
        }
    }

    // Decode: nesting depth around the recursion limit (32).
    for ([_]usize{ 1, 2, 30, 31, 32, 33, 34, 40, 64 }) |depth| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const nested = try a.alloc(u8, depth);
        for (nested, 0..) |*byte, index| byte.* = 0xc0 + @as(u8, @intCast(@min(depth - 1 - index, 55)));
        try checkDecode(suite, a, "decode nesting depth limit", nested, false);
    }
}

// ---------------------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------------------

fn envU64(init: std.process.Init, name: []const u8, default: u64) !u64 {
    const text = init.environ_map.get(name) orelse return default;
    return std.fmt.parseInt(u64, text, 0) catch {
        std.debug.print("{s}={s} is not an unsigned integer\n", .{ name, text });
        return error.InvalidEnvironment;
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const seed = try envU64(init, "FUZZ_SEED", 0xC0FFEE);
    const iters = try envU64(init, "FUZZ_ITERS", 2000);

    show_crashes = init.environ_map.get("LEAN_DIFF_SHOW_CRASH") != null;
    const oracle_path = init.environ_map.get("GUILLOTINE_LEAN_REF") orelse "verify/lean/.lake/build/bin/guillotine-lean-ref";

    var oracle: Oracle = undefined;
    oracle.start(init.io, gpa, oracle_path) catch |err| {
        std.debug.print(
            \\cannot start the Lean reference oracle at '{s}': {s}
            \\build it with: (cd verify/lean && lake build guillotine-lean-ref)
            \\
        , .{ oracle_path, @errorName(err) });
        return err;
    };

    var suite = Suite{ .gpa = gpa, .oracle = &oracle, .seed = seed, .iters = iters };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    std.debug.print("Zig-vs-Lean differential fuzz: FUZZ_SEED={d} FUZZ_ITERS={d}\n", .{ seed, iters });

    const Stage = struct { name: []const u8, run: *const fn (*Suite, std.Random, *std.heap.ArenaAllocator) anyerror!void };
    const stages = [_]Stage{
        .{ .name = "word ops", .run = fuzzWords },
        .{ .name = "gas (pure functions)", .run = fuzzGasPure },
        .{ .name = "gas (Eips.sstore_gas_cost helper)", .run = fuzzSstoreHelper },
        .{ .name = "gas (measured by execution on every fork)", .run = fuzzGasExec },
        .{ .name = "bytecode analysis", .run = fuzzBytecode },
        .{ .name = "EVM execution", .run = fuzzEvm },
        .{ .name = "EVM boundary probes", .run = fuzzProbes },
        .{ .name = "Base / OP Stack", .run = fuzzLayer2 },
        .{ .name = "RLP", .run = fuzzRlp },
    };
    for (stages, 0..) |stage, index| {
        var prng = std.Random.DefaultPrng.init(seed +% (index *% 0x9E3779B97F4A7C15));
        std.debug.print("  running: {s}\n", .{stage.name});
        try stage.run(&suite, prng.random(), &arena);
    }
    oracle.stop();

    std.debug.print(
        \\
        \\+---------------------------+-----------+-----------+------------+
        \\| subsystem                 |   vectors |   minimum | mismatches |
        \\+---------------------------+-----------+-----------+------------+
        \\
    , .{});
    var below_minimum = false;
    for (SUBSYSTEMS) |subsystem| {
        const vectors = suite.vectors[@intFromEnum(subsystem)];
        std.debug.print("| {s: <25} | {d: >9} | {d: >9} | {d: >10} |\n", .{ subsystem.title(), vectors, subsystem.minimum(), suite.mismatches[@intFromEnum(subsystem)] });
        if (iters >= 2000 and vectors < subsystem.minimum()) below_minimum = true;
    }
    const total_vectors = Suite.total(suite.vectors);
    const total_mismatches = Suite.total(suite.mismatches);
    std.debug.print(
        \\+---------------------------+-----------+-----------+------------+
        \\| total                     | {d: >9} |           | {d: >10} |
        \\+---------------------------+-----------+-----------+------------+
        \\oracle requests: {d}
        \\slowest Guillotine call: {d} ms; calls of {d} ms or more: {d}
        \\
    , .{ total_vectors, total_mismatches, oracle.requests, slowest_call_ms, slow_call_threshold_ms, slow_calls });

    if (suite.classes.count() > 0) {
        std.debug.print("\nmismatch classes (count, class, forks affected):\n", .{});
        var it = suite.classes.iterator();
        while (it.next()) |entry| {
            std.debug.print("  {d: >7}  {s}", .{ entry.value_ptr.count, entry.key_ptr.* });
            if (entry.value_ptr.forks != 0) {
                std.debug.print("  {{", .{});
                for (FORKS, 0..) |fork, index| {
                    if (entry.value_ptr.forks & (@as(u16, 1) << @intCast(index)) != 0) std.debug.print(" {s}", .{@tagName(fork)});
                }
                std.debug.print(" }}", .{});
            }
            std.debug.print("\n", .{});
        }
    }
    if (below_minimum) {
        std.debug.print("\nFAIL: a subsystem ran fewer vectors than its minimum\n", .{});
        std.process.exit(1);
    }
    if (total_mismatches > 0) {
        std.debug.print("\nFAIL: {d} mismatches between Guillotine and the Lean reference specification\n", .{total_mismatches});
        std.process.exit(1);
    }
    std.debug.print("\nPASS: Guillotine matches the Lean reference specification on every vector\n", .{});
}
