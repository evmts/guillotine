//! Guillotine native JIT: compiles hot, side-effect-free EVM bytecode into
//! AArch64 machine code.
//!
//! Scope: the supported opcode set is pure computation, memory, calldata
//! reads, control flow, and RETURN/REVERT. No storage, logs, calls, or
//! creates. A JIT run therefore has no external side effects, so a host that
//! receives `ExitCode.fallback` (or a `null` program) re-executes the whole
//! call in the interpreter with identical results.
//!
//! This directory depends only on `std` and `builtin`.

const std = @import("std");
const builtin = @import("builtin");

pub const jit_mem = @import("jit_mem.zig");
pub const arm64 = @import("arm64_emitter.zig");
pub const x86_64 = @import("x86_64_emitter.zig");
pub const compiler = @import("compiler.zig");
pub const jit_cache = @import("jit_cache.zig");

pub const Program = compiler.Program;
pub const Options = compiler.Options;
pub const compile = compiler.compile;
pub const JitCache = jit_cache.JitCache;

pub const stack_capacity = 1024;
pub const instruction_limit = 300_000_000;

pub const ExitCode = enum(u32) {
    stop = 0,
    return_ok = 1,
    revert = 2,
    out_of_gas = 3,
    stack_underflow = 4,
    stack_overflow = 5,
    invalid_jump = 6,
    invalid_opcode = 7,
    out_of_bounds = 8,
    /// The JIT cannot finish this call (for example the host refused to grow
    /// memory). The run had no side effects; re-run it in the interpreter.
    fallback = 9,

    /// True for halts that consume all gas and discard output.
    pub fn isExceptional(self: ExitCode) bool {
        return switch (self) {
            .stop, .return_ok, .revert => false,
            else => true,
        };
    }
};

pub const JitContext = extern struct {
    /// Top of the downward-growing stack. Equals `stack_base` when empty.
    stack_ptr: [*]align(32) u256,
    /// One past the deepest slot: `buf + 1024`.
    stack_base: [*]align(32) u256,
    /// Lowest slot: `buf`.
    stack_limit: [*]align(32) u256,
    gas_remaining: i64,
    memory_ptr: ?[*]u8,
    /// Active EVM memory size in bytes, always a multiple of 32.
    memory_len: usize,
    /// Allocated bytes at `memory_ptr`.
    memory_cap: usize,
    /// Total memory expansion gas already paid for `memory_len`.
    memory_cost: u64,
    calldata_ptr: [*]const u8,
    calldata_len: usize,
    output_offset: usize,
    output_len: usize,
    exit_code: u32,
    _pad: u32 = 0,
    helpers: *const RuntimeHelpers,
    host_ctx: ?*anyopaque,
    /// Maximum active memory in bytes, independent of allocated capacity.
    memory_limit: usize = std.math.maxInt(usize),
    /// Safety counter budget per run. Native code decrements it at block entry.
    instruction_budget: u64 = instruction_limit,
};

/// `out = op(a, b)` where `a` is the top of stack. `out` may alias `b`.
pub const BinaryFn = *const fn (a: *const u256, b: *const u256, out: *u256) callconv(.c) void;
/// `out = op(a, b, n)` where `a` is the top of stack. `out` may alias `n`.
pub const TernaryFn = *const fn (a: *const u256, b: *const u256, n: *const u256, out: *u256) callconv(.c) void;
/// `out = op(a)`. `out` may alias `a`.
pub const UnaryFn = *const fn (a: *const u256, out: *u256) callconv(.c) void;
/// Reads and writes the stack through `ctx`; returns 0 or an `ExitCode`.
pub const CtxFn = *const fn (ctx: *JitContext) callconv(.c) u32;
pub const CtxVoidFn = *const fn (ctx: *JitContext) callconv(.c) void;
pub const RetFn = *const fn (ctx: *JitContext, is_revert: u32) callconv(.c) u32;
/// Makes `memory_cap >= new_len`, preserving the first `memory_len` bytes.
/// Returns 0 or an exceptional exit or fallback code.
pub const GrowFn = *const fn (ctx: *JitContext, new_len: usize) callconv(.c) u32;

pub const RuntimeHelpers = extern struct {
    div: BinaryFn,
    sdiv: BinaryFn,
    mod: BinaryFn,
    smod: BinaryFn,
    addmod: TernaryFn,
    mulmod: TernaryFn,
    exp: CtxFn,
    signextend: BinaryFn,
    byte: BinaryFn,
    shl: BinaryFn,
    shr: BinaryFn,
    sar: BinaryFn,
    clz: UnaryFn,
    mload: CtxFn,
    mstore: CtxFn,
    mstore8: CtxFn,
    mcopy: CtxFn,
    calldataload: CtxVoidFn,
    ret: RetFn,
    /// Null makes KECCAK256 ineligible for compilation.
    keccak256: ?CtxFn,
    memory_grow: GrowFn,
    memory_free: CtxVoidFn,
    /// Optional host-owned resize, called for every expansion. Must update
    /// memory_ptr, memory_cap and memory_len, and zero the newly active bytes.
    memory_resize: ?GrowFn = null,
};

pub const default_helpers = RuntimeHelpers{
    .div = &helpers.div,
    .sdiv = &helpers.sdiv,
    .mod = &helpers.mod,
    .smod = &helpers.smod,
    .addmod = &helpers.addmod,
    .mulmod = &helpers.mulmod,
    .exp = &helpers.exp,
    .signextend = &helpers.signextend,
    .byte = &helpers.byte,
    .shl = &helpers.shl,
    .shr = &helpers.shr,
    .sar = &helpers.sar,
    .clz = &helpers.clz,
    .mload = &helpers.mload,
    .mstore = &helpers.mstore,
    .mstore8 = &helpers.mstore8,
    .mcopy = &helpers.mcopy,
    .calldataload = &helpers.calldataload,
    .ret = &helpers.ret,
    .keccak256 = &helpers.keccak256,
    .memory_grow = &helpers.memoryGrow,
    .memory_free = &helpers.memoryFree,
};

/// Default helper implementations. The memory helpers grow memory through
/// `ctx.helpers.memory_grow`; the defaults use `std.heap.page_allocator`.
pub const helpers = struct {
    const ok: u32 = 0;
    const oog: u32 = @backingInt(ExitCode.out_of_gas);
    const bounds: u32 = @backingInt(ExitCode.out_of_bounds);
    const sign_bit: u256 = 1 << 255;
    const minus_one: u256 = std.math.maxInt(u256);

    pub fn div(a: *const u256, b: *const u256, out: *u256) callconv(.c) void {
        const x = a.*;
        const y = b.*;
        out.* = if (y == 0) 0 else x / y;
    }

    pub fn sdiv(a: *const u256, b: *const u256, out: *u256) callconv(.c) void {
        const x = a.*;
        const y = b.*;
        if (y == 0) {
            out.* = 0;
            return;
        }
        if (x == sign_bit and y == minus_one) {
            out.* = sign_bit;
            return;
        }
        const q = @divTrunc(@as(i256, @bitCast(x)), @as(i256, @bitCast(y)));
        out.* = @bitCast(q);
    }

    pub fn mod(a: *const u256, b: *const u256, out: *u256) callconv(.c) void {
        const x = a.*;
        const y = b.*;
        out.* = if (y == 0) 0 else x % y;
    }

    pub fn smod(a: *const u256, b: *const u256, out: *u256) callconv(.c) void {
        const x = a.*;
        const y = b.*;
        if (y == 0 or y == minus_one) {
            out.* = 0;
            return;
        }
        const r = @rem(@as(i256, @bitCast(x)), @as(i256, @bitCast(y)));
        out.* = @bitCast(r);
    }

    pub fn addmod(a: *const u256, b: *const u256, n: *const u256, out: *u256) callconv(.c) void {
        const x = a.*;
        const y = b.*;
        const m = n.*;
        if (m == 0) {
            out.* = 0;
            return;
        }
        out.* = @intCast((@as(u257, x) + y) % m);
    }

    pub fn mulmod(a: *const u256, b: *const u256, n: *const u256, out: *u256) callconv(.c) void {
        const x = a.*;
        const y = b.*;
        const m = n.*;
        if (m == 0) {
            out.* = 0;
            return;
        }
        out.* = @intCast((@as(u512, x) * y) % m);
    }

    pub fn signextend(a: *const u256, b: *const u256, out: *u256) callconv(.c) void {
        const index = a.*;
        const x = b.*;
        if (index >= 31) {
            out.* = x;
            return;
        }
        const bit: u8 = @intCast(index * 8 + 7);
        const mask: u256 = (@as(u256, 1) << bit) - 1;
        if ((x >> bit) & 1 == 1) {
            out.* = x | ~mask;
            return;
        }
        out.* = x & mask;
    }

    pub fn byte(a: *const u256, b: *const u256, out: *u256) callconv(.c) void {
        const index = a.*;
        const x = b.*;
        if (index >= 32) {
            out.* = 0;
            return;
        }
        const shift: u8 = @intCast((31 - index) * 8);
        out.* = (x >> shift) & 0xFF;
    }

    pub fn shl(a: *const u256, b: *const u256, out: *u256) callconv(.c) void {
        const shift = a.*;
        const value = b.*;
        out.* = if (shift >= 256) 0 else value << @intCast(shift);
    }

    pub fn shr(a: *const u256, b: *const u256, out: *u256) callconv(.c) void {
        const shift = a.*;
        const value = b.*;
        out.* = if (shift >= 256) 0 else value >> @intCast(shift);
    }

    pub fn sar(a: *const u256, b: *const u256, out: *u256) callconv(.c) void {
        const shift = a.*;
        const value: i256 = @bitCast(b.*);
        if (shift >= 256) {
            out.* = if (value < 0) minus_one else 0;
            return;
        }
        out.* = @bitCast(value >> @intCast(shift));
    }

    pub fn clz(a: *const u256, out: *u256) callconv(.c) void {
        out.* = @clz(a.*);
    }

    fn chargeGas(ctx: *JitContext, cost: u128) bool {
        if (ctx.gas_remaining < 0) return false;
        if (cost > @as(u128, @intCast(ctx.gas_remaining))) return false;
        ctx.gas_remaining -= @intCast(cost);
        return true;
    }

    fn words(size: u128) u128 {
        return (size + 31) / 32;
    }

    pub fn memoryCost(word_count: usize) u128 {
        const count: u128 = word_count;
        return 3 * count + count * count / 512;
    }

    /// Charges expansion gas and grows memory to cover `[offset, offset+size)`.
    /// A zero `size` never expands, whatever the offset.
    pub fn expand(ctx: *JitContext, offset: u256, size: u256) u32 {
        if (size == 0) return ok;
        if (offset > ctx.memory_limit or size > ctx.memory_limit) return bounds;
        const end = @as(u128, @intCast(offset)) + @as(u128, @intCast(size));
        const new_len = std.math.cast(usize, words(end) * 32) orelse return bounds;
        if (new_len > ctx.memory_limit) return bounds;
        if (new_len <= ctx.memory_len) return ok;
        const cost = std.math.cast(u64, memoryCost(new_len / 32)) orelse return oog;
        if (!chargeGas(ctx, cost - ctx.memory_cost)) return oog;
        if (ctx.helpers.memory_resize) |resize| {
            const rc = resize(ctx, new_len);
            if (rc != ok) return rc;
        } else {
            if (new_len > ctx.memory_cap) {
                const rc = ctx.helpers.memory_grow(ctx, new_len);
                if (rc != ok) return rc;
            }
            const ptr = ctx.memory_ptr orelse return @backingInt(ExitCode.fallback);
            @memset(ptr[ctx.memory_len..new_len], 0);
            ctx.memory_len = new_len;
        }
        ctx.memory_cost = cost;
        return ok;
    }

    fn mem(ctx: *JitContext) [*]u8 {
        return ctx.memory_ptr.?;
    }

    pub fn exp(ctx: *JitContext) callconv(.c) u32 {
        const base = ctx.stack_ptr[0];
        const exponent = ctx.stack_ptr[1];
        const bytes: u128 = (256 - @as(u128, @clz(exponent)) + 7) / 8;
        if (!chargeGas(ctx, 50 * bytes)) return oog;
        var result: u256 = 1;
        var b = base;
        var e = exponent;
        while (e != 0) : (e >>= 1) {
            if (e & 1 == 1) result *%= b;
            b *%= b;
        }
        ctx.stack_ptr += 1;
        ctx.stack_ptr[0] = result;
        return ok;
    }

    pub fn calldataload(ctx: *JitContext) callconv(.c) void {
        const offset = ctx.stack_ptr[0];
        var buf = @as([32]u8, @splat(0));
        if (offset < ctx.calldata_len) {
            const start: usize = @intCast(offset);
            const n = @min(32, ctx.calldata_len - start);
            @memcpy(buf[0..n], ctx.calldata_ptr[start .. start + n]);
        }
        ctx.stack_ptr[0] = std.mem.readInt(u256, &buf, .big);
    }

    pub fn mload(ctx: *JitContext) callconv(.c) u32 {
        const offset = ctx.stack_ptr[0];
        const rc = expand(ctx, offset, 32);
        if (rc != ok) return rc;
        const start: usize = @intCast(offset);
        ctx.stack_ptr[0] = std.mem.readInt(u256, mem(ctx)[start..][0..32], .big);
        return ok;
    }

    pub fn mstore(ctx: *JitContext) callconv(.c) u32 {
        const offset = ctx.stack_ptr[0];
        const value = ctx.stack_ptr[1];
        ctx.stack_ptr += 2;
        const rc = expand(ctx, offset, 32);
        if (rc != ok) return rc;
        const start: usize = @intCast(offset);
        std.mem.writeInt(u256, mem(ctx)[start..][0..32], value, .big);
        return ok;
    }

    pub fn mstore8(ctx: *JitContext) callconv(.c) u32 {
        const offset = ctx.stack_ptr[0];
        const value = ctx.stack_ptr[1];
        ctx.stack_ptr += 2;
        const rc = expand(ctx, offset, 1);
        if (rc != ok) return rc;
        const start: usize = @intCast(offset);
        mem(ctx)[start] = @truncate(value);
        return ok;
    }

    pub fn mcopy(ctx: *JitContext) callconv(.c) u32 {
        const dest = ctx.stack_ptr[0];
        const src = ctx.stack_ptr[1];
        const size = ctx.stack_ptr[2];
        ctx.stack_ptr += 3;
        if (size == 0) return ok;
        if (size > std.math.maxInt(u64)) return oog;
        if (!chargeGas(ctx, 3 * words(@intCast(size)))) return oog;
        const rc = expand(ctx, @max(dest, src), size);
        if (rc != ok) return rc;
        const d: usize = @intCast(dest);
        const s: usize = @intCast(src);
        const n: usize = @intCast(size);
        const m = mem(ctx);
        @memmove(m[d .. d + n], m[s .. s + n]);
        return ok;
    }

    pub fn ret(ctx: *JitContext, is_revert: u32) callconv(.c) u32 {
        _ = is_revert;
        const offset = ctx.stack_ptr[0];
        const size = ctx.stack_ptr[1];
        ctx.stack_ptr += 2;
        const rc = expand(ctx, offset, size);
        if (rc != ok) return rc;
        if (size == 0) {
            ctx.output_offset = 0;
            ctx.output_len = 0;
            return ok;
        }
        ctx.output_offset = @intCast(offset);
        ctx.output_len = @intCast(size);
        return ok;
    }

    pub fn keccak256(ctx: *JitContext) callconv(.c) u32 {
        const offset = ctx.stack_ptr[0];
        const size = ctx.stack_ptr[1];
        ctx.stack_ptr += 1;
        if (size > std.math.maxInt(u64)) return oog;
        if (!chargeGas(ctx, 6 * words(@intCast(size)))) return oog;
        const rc = expand(ctx, offset, size);
        if (rc != ok) return rc;
        var digest: [32]u8 = undefined;
        if (size == 0) {
            std.crypto.hash.sha3.Keccak256.hash(&.{}, &digest, .{});
        } else {
            const start: usize = @intCast(offset);
            const n: usize = @intCast(size);
            std.crypto.hash.sha3.Keccak256.hash(mem(ctx)[start .. start + n], &digest, .{});
        }
        ctx.stack_ptr[0] = std.mem.readInt(u256, &digest, .big);
        return ok;
    }

    pub fn memoryGrow(ctx: *JitContext, new_len: usize) callconv(.c) u32 {
        const allocator = std.heap.page_allocator;
        const cap = @max(new_len, ctx.memory_cap *| 2, 4096);
        const fresh = allocator.alloc(u8, cap) catch return @backingInt(ExitCode.fallback);
        if (ctx.memory_ptr) |old| {
            @memcpy(fresh[0..ctx.memory_len], old[0..ctx.memory_len]);
            allocator.free(old[0..ctx.memory_cap]);
        }
        ctx.memory_ptr = fresh.ptr;
        ctx.memory_cap = cap;
        return ok;
    }

    pub fn memoryFree(ctx: *JitContext) callconv(.c) void {
        if (ctx.memory_ptr) |old| std.heap.page_allocator.free(old[0..ctx.memory_cap]);
        ctx.memory_ptr = null;
        ctx.memory_cap = 0;
        ctx.memory_len = 0;
        ctx.memory_cost = 0;
    }
};

/// A stack buffer plus context. Pointers in `ctx` refer into `self`, so a
/// Frame must not move after `init`.
pub const Frame = struct {
    stack: [stack_capacity]u256 align(32),
    ctx: JitContext,

    pub fn init(self: *Frame, gas: i64, calldata: []const u8, runtime: *const RuntimeHelpers) void {
        const buf: [*]align(32) u256 = &self.stack;
        self.ctx = .{
            .stack_ptr = buf + stack_capacity,
            .stack_base = buf + stack_capacity,
            .stack_limit = buf,
            .gas_remaining = gas,
            .memory_ptr = null,
            .memory_len = 0,
            .memory_cap = 0,
            .memory_cost = 0,
            .calldata_ptr = calldata.ptr,
            .calldata_len = calldata.len,
            .output_offset = 0,
            .output_len = 0,
            .exit_code = 0,
            .helpers = runtime,
            .host_ctx = null,
        };
    }

    pub fn deinit(self: *Frame) void {
        self.ctx.helpers.memory_free(&self.ctx);
    }

    /// Stack items, top first.
    pub fn stackItems(self: *const Frame) []const u256 {
        const n = (@intFromPtr(self.ctx.stack_base) - @intFromPtr(self.ctx.stack_ptr)) / 32;
        return self.ctx.stack_ptr[0..n];
    }

    pub fn push(self: *Frame, value: u256) error{StackOverflow}!void {
        if (self.ctx.stack_ptr == self.ctx.stack_limit) return error.StackOverflow;
        self.ctx.stack_ptr -= 1;
        self.ctx.stack_ptr[0] = value;
    }

    pub fn memory(self: *const Frame) []const u8 {
        const ptr = self.ctx.memory_ptr orelse return &.{};
        return ptr[0..self.ctx.memory_len];
    }

    pub fn output(self: *const Frame) []const u8 {
        if (self.ctx.output_len == 0) return &.{};
        const ptr = self.ctx.memory_ptr orelse return &.{};
        return ptr[self.ctx.output_offset .. self.ctx.output_offset + self.ctx.output_len];
    }
};

test {
    _ = jit_mem;
    _ = arm64;
    _ = x86_64;
    _ = compiler;
    _ = jit_cache;
}

// ===================================================================== tests
//
// The oracle is `reference`, a plain per-instruction interpreter with its own
// gas and stack tables. Native ops are also checked against Zig u256 math.

const testing = std.testing;

const reference = struct {
    const Shape = struct { pops: u8, pushes: u8, gas: u32 };

    fn shape(op: u8) ?Shape {
        return switch (op) {
            0x00 => .{ .pops = 0, .pushes = 0, .gas = 0 },
            0x01, 0x03 => .{ .pops = 2, .pushes = 1, .gas = 3 },
            0x02, 0x04, 0x05, 0x06, 0x07, 0x0B => .{ .pops = 2, .pushes = 1, .gas = 5 },
            0x08, 0x09 => .{ .pops = 3, .pushes = 1, .gas = 8 },
            0x0A => .{ .pops = 2, .pushes = 1, .gas = 10 },
            0x10...0x14, 0x16...0x18, 0x1A...0x1D => .{ .pops = 2, .pushes = 1, .gas = 3 },
            0x15, 0x19 => .{ .pops = 1, .pushes = 1, .gas = 3 },
            0x1E => .{ .pops = 1, .pushes = 1, .gas = 5 },
            0x20 => .{ .pops = 2, .pushes = 1, .gas = 30 },
            0x35 => .{ .pops = 1, .pushes = 1, .gas = 3 },
            0x36, 0x58, 0x59, 0x5A, 0x5F => .{ .pops = 0, .pushes = 1, .gas = 2 },
            0x50 => .{ .pops = 1, .pushes = 0, .gas = 2 },
            0x51 => .{ .pops = 1, .pushes = 1, .gas = 3 },
            0x52, 0x53 => .{ .pops = 2, .pushes = 0, .gas = 3 },
            0x56 => .{ .pops = 1, .pushes = 0, .gas = 8 },
            0x57 => .{ .pops = 2, .pushes = 0, .gas = 10 },
            0x5B => .{ .pops = 0, .pushes = 0, .gas = 1 },
            0x5E => .{ .pops = 3, .pushes = 0, .gas = 3 },
            0x60...0x7F => .{ .pops = 0, .pushes = 1, .gas = 3 },
            0x80...0x8F => .{ .pops = op - 0x7F, .pushes = op - 0x7E, .gas = 3 },
            0x90...0x9F => .{ .pops = op - 0x8E, .pushes = op - 0x8E, .gas = 3 },
            0xF3, 0xFD => .{ .pops = 2, .pushes = 0, .gas = 0 },
            0xFE => .{ .pops = 0, .pushes = 0, .gas = 0 },
            else => null,
        };
    }

    fn halt(ctx: *JitContext, code: ExitCode) ExitCode {
        ctx.gas_remaining = 0;
        ctx.exit_code = @backingInt(code);
        return code;
    }

    fn pop(ctx: *JitContext) u256 {
        const v = ctx.stack_ptr[0];
        ctx.stack_ptr += 1;
        return v;
    }

    fn push(ctx: *JitContext, v: u256) void {
        ctx.stack_ptr -= 1;
        ctx.stack_ptr[0] = v;
    }

    fn run(allocator: std.mem.Allocator, frame: *Frame, code: []const u8) !ExitCode {
        const ctx = &frame.ctx;
        const dests = try allocator.alloc(bool, code.len);
        defer allocator.free(dests);
        @memset(dests, false);
        var scan: usize = 0;
        while (scan < code.len) {
            const op = code[scan];
            if (op == 0x5B) dests[scan] = true;
            scan += 1 + (if (op >= 0x60 and op <= 0x7F) @as(usize, op - 0x5F) else 0);
        }

        var pc: usize = 0;
        while (pc < code.len) {
            const op = code[pc];
            const s = shape(op) orelse return error.UnsupportedInReference;
            const depth = (@intFromPtr(ctx.stack_base) - @intFromPtr(ctx.stack_ptr)) / 32;
            if (op == 0xFE) return halt(ctx, .invalid_opcode);
            if (depth < s.pops) return halt(ctx, .stack_underflow);
            if (depth - s.pops + s.pushes > stack_capacity) return halt(ctx, .stack_overflow);
            if (ctx.gas_remaining < s.gas) return halt(ctx, .out_of_gas);
            ctx.gas_remaining -= s.gas;
            var next = pc + 1;
            const h = ctx.helpers;
            switch (op) {
                0x00 => return .stop,
                0x01 => push(ctx, pop(ctx) +% pop(ctx)),
                0x02 => push(ctx, pop(ctx) *% pop(ctx)),
                0x03 => {
                    const a = pop(ctx);
                    push(ctx, a -% pop(ctx));
                },
                0x04...0x07, 0x0B, 0x1A...0x1D => {
                    const f = switch (op) {
                        0x04 => h.div,
                        0x05 => h.sdiv,
                        0x06 => h.mod,
                        0x07 => h.smod,
                        0x0B => h.signextend,
                        0x1A => h.byte,
                        0x1B => h.shl,
                        0x1C => h.shr,
                        else => h.sar,
                    };
                    const a = pop(ctx);
                    const b = pop(ctx);
                    var out: u256 = 0;
                    f(&a, &b, &out);
                    push(ctx, out);
                },
                0x08, 0x09 => {
                    const a = pop(ctx);
                    const b = pop(ctx);
                    const n = pop(ctx);
                    var out: u256 = 0;
                    (if (op == 0x08) h.addmod else h.mulmod)(&a, &b, &n, &out);
                    push(ctx, out);
                },
                0x10 => push(ctx, @intFromBool(pop(ctx) < pop(ctx))),
                0x11 => push(ctx, @intFromBool(pop(ctx) > pop(ctx))),
                0x12 => push(ctx, @intFromBool(@as(i256, @bitCast(pop(ctx))) < @as(i256, @bitCast(pop(ctx))))),
                0x13 => push(ctx, @intFromBool(@as(i256, @bitCast(pop(ctx))) > @as(i256, @bitCast(pop(ctx))))),
                0x14 => push(ctx, @intFromBool(pop(ctx) == pop(ctx))),
                0x15 => push(ctx, @intFromBool(pop(ctx) == 0)),
                0x16 => push(ctx, pop(ctx) & pop(ctx)),
                0x17 => push(ctx, pop(ctx) | pop(ctx)),
                0x18 => push(ctx, pop(ctx) ^ pop(ctx)),
                0x19 => push(ctx, ~pop(ctx)),
                0x1E => {
                    const a = pop(ctx);
                    var out: u256 = 0;
                    h.clz(&a, &out);
                    push(ctx, out);
                },
                0x0A, 0x20, 0x51, 0x52, 0x53, 0x5E => {
                    const f = switch (op) {
                        0x0A => h.exp,
                        0x20 => h.keccak256.?,
                        0x51 => h.mload,
                        0x52 => h.mstore,
                        0x53 => h.mstore8,
                        else => h.mcopy,
                    };
                    const rc = f(ctx);
                    if (rc != 0) return halt(ctx, @fromBackingInt(@intCast(rc)));
                },
                0x35 => h.calldataload(ctx),
                0x36 => push(ctx, ctx.calldata_len),
                0x50 => _ = pop(ctx),
                0x56, 0x57 => {
                    const dest = pop(ctx);
                    const cond: u256 = if (op == 0x57) pop(ctx) else 1;
                    if (cond != 0) {
                        if (dest >= code.len or !dests[@intCast(dest)]) return halt(ctx, .invalid_jump);
                        next = @intCast(dest);
                    }
                },
                0x58 => push(ctx, pc),
                0x59 => push(ctx, ctx.memory_len),
                0x5A => push(ctx, @intCast(ctx.gas_remaining)),
                0x5B => {},
                0x5F => push(ctx, 0),
                0x60...0x7F => {
                    const n: usize = op - 0x5F;
                    var v: u256 = 0;
                    for (0..n) |k| v = (v << 8) | (if (pc + 1 + k < code.len) code[pc + 1 + k] else 0);
                    push(ctx, v);
                    next = pc + 1 + n;
                },
                0x80...0x8F => push(ctx, ctx.stack_ptr[op - 0x80]),
                0x90...0x9F => {
                    const n = op - 0x8F;
                    std.mem.swap(u256, &ctx.stack_ptr[0], &ctx.stack_ptr[n]);
                },
                0xF3, 0xFD => {
                    const rc = h.ret(ctx, @intFromBool(op == 0xFD));
                    if (rc != 0) return halt(ctx, @fromBackingInt(@intCast(rc)));
                    return if (op == 0xF3) .return_ok else .revert;
                },
                else => return error.UnsupportedInReference,
            }
            pc = next;
        }
        return .stop;
    }
};

const Outcome = struct {
    code: ExitCode,
    gas: i64,
    stack: []u256,
    memory: []u8,
    output: []u8,

    fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        allocator.free(self.stack);
        allocator.free(self.memory);
        allocator.free(self.output);
    }

    fn capture(allocator: std.mem.Allocator, frame: *const Frame, code: ExitCode) !Outcome {
        return .{
            .code = code,
            .gas = frame.ctx.gas_remaining,
            .stack = try allocator.dupe(u256, frame.stackItems()),
            .memory = try allocator.dupe(u8, frame.memory()),
            .output = try allocator.dupe(u8, frame.output()),
        };
    }
};

fn runJit(allocator: std.mem.Allocator, code: []const u8, gas: i64, calldata: []const u8, options: Options) !Outcome {
    var program = (try compile(allocator, code, options)) orelse return error.NotCompiled;
    defer program.deinit();
    const frame = try allocator.create(Frame);
    defer allocator.destroy(frame);
    frame.init(gas, calldata, &default_helpers);
    defer frame.deinit();
    const exit = try program.run(&frame.ctx);
    try testing.expectEqual(@backingInt(exit), frame.ctx.exit_code);
    return Outcome.capture(allocator, frame, exit);
}

fn runReference(allocator: std.mem.Allocator, code: []const u8, gas: i64, calldata: []const u8) !Outcome {
    const frame = try allocator.create(Frame);
    defer allocator.destroy(frame);
    frame.init(gas, calldata, &default_helpers);
    defer frame.deinit();
    const exit = try reference.run(allocator, frame, code);
    return Outcome.capture(allocator, frame, exit);
}

/// Runs both engines and requires identical results. Exceptional halts must
/// agree in class (both exceptional, all gas consumed); the specific reason
/// may differ because the JIT checks stack bounds per block.
fn expectSame(allocator: std.mem.Allocator, code: []const u8, gas: i64, calldata: []const u8, options: Options) !Outcome {
    var jit = try runJit(allocator, code, gas, calldata, options);
    errdefer jit.deinit(allocator);
    var ref = try runReference(allocator, code, gas, calldata);
    defer ref.deinit(allocator);
    try testing.expectEqual(ref.code.isExceptional(), jit.code.isExceptional());
    try testing.expectEqual(ref.gas, jit.gas);
    if (ref.code.isExceptional()) {
        try testing.expectEqual(@as(i64, 0), jit.gas);
        return jit;
    }
    try testing.expectEqual(ref.code, jit.code);
    try testing.expectEqualSlices(u256, ref.stack, jit.stack);
    try testing.expectEqualSlices(u8, ref.memory, jit.memory);
    try testing.expectEqualSlices(u8, ref.output, jit.output);
    return jit;
}

/// Tiny assembler with labels for test programs.
const Asm = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    labels: [16]?u16 = @as([16]?u16, @splat(null)),
    refs: std.ArrayList(struct { at: usize, label: u8 }) = .empty,

    fn deinit(self: *Asm) void {
        self.bytes.deinit(self.allocator);
        self.refs.deinit(self.allocator);
    }

    fn op(self: *Asm, ops: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, ops);
    }

    fn push(self: *Asm, value: u256) !void {
        const n: u8 = if (value == 0) 1 else @intCast((256 - @as(u16, @clz(value)) + 7) / 8);
        try self.bytes.append(self.allocator, 0x5F + n);
        var k = n;
        while (k > 0) : (k -= 1) try self.bytes.append(self.allocator, @truncate(value >> @intCast((k - 1) * 8)));
    }

    /// PUSH2 <label>
    fn pushLabel(self: *Asm, label: u8) !void {
        try self.bytes.append(self.allocator, 0x61);
        try self.refs.append(self.allocator, .{ .at = self.bytes.items.len, .label = label });
        try self.bytes.appendSlice(self.allocator, &.{ 0, 0 });
    }

    /// JUMPDEST bound to `label`.
    fn mark(self: *Asm, label: u8) !void {
        self.labels[label] = @intCast(self.bytes.items.len);
        try self.bytes.append(self.allocator, 0x5B);
    }

    fn finish(self: *Asm) ![]const u8 {
        for (self.refs.items) |r| {
            const target = self.labels[r.label] orelse return error.UnboundLabel;
            std.mem.writeInt(u16, self.bytes.items[r.at..][0..2], target, .big);
        }
        return self.bytes.items;
    }
};

fn push32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u256) !void {
    try buf.append(allocator, 0x7F);
    var raw: [32]u8 = undefined;
    std.mem.writeInt(u256, &raw, value, .big);
    try buf.appendSlice(allocator, &raw);
}

/// Runs `PUSH32 c? PUSH32 b? PUSH32 a OP STOP` through the JIT and returns
/// the single resulting stack item, also checking it against the reference.
fn evalOp(op: u8, args: []const u256, options: Options) !u256 {
    const allocator = testing.allocator;
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(allocator);
    var k = args.len;
    while (k > 0) : (k -= 1) try push32(&code, allocator, args[k - 1]);
    try code.appendSlice(allocator, &.{ op, 0x00 });
    var out = try expectSame(allocator, code.items, 1_000_000, &.{}, options);
    defer out.deinit(allocator);
    try testing.expectEqual(ExitCode.stop, out.code);
    try testing.expectEqual(@as(usize, 1), out.stack.len);
    return out.stack[0];
}

const native_only = !compiler.native_supported;
const min_i256: u256 = 1 << 255;
const max_u256: u256 = std.math.maxInt(u256);

fn neg(x: u256) u256 {
    return 0 -% x;
}

test "native arithmetic, comparison, and bitwise ops match u256 math" {
    if (native_only) return error.SkipZigTest;
    var prng = std.Random.DefaultPrng.init(0x6A17);
    const random = prng.random();
    const edges = [_]u256{ 0, 1, 2, max_u256, max_u256 - 1, min_i256, min_i256 - 1, 1 << 64, (1 << 64) - 1, 1 << 128, (1 << 192) - 1 };
    for (0..400) |round| {
        var a = random.int(u256);
        var b = random.int(u256);
        if (round < edges.len * edges.len) {
            a = edges[round % edges.len];
            b = edges[round / edges.len];
        } else if (round % 3 == 0) {
            a >>= random.int(u8);
            b >>= random.int(u8);
        }
        const sa: i256 = @bitCast(a);
        const sb: i256 = @bitCast(b);
        try testing.expectEqual(a +% b, try evalOp(0x01, &.{ a, b }, .{}));
        try testing.expectEqual(a *% b, try evalOp(0x02, &.{ a, b }, .{}));
        try testing.expectEqual(a -% b, try evalOp(0x03, &.{ a, b }, .{}));
        try testing.expectEqual(@as(u256, @intFromBool(a < b)), try evalOp(0x10, &.{ a, b }, .{}));
        try testing.expectEqual(@as(u256, @intFromBool(a > b)), try evalOp(0x11, &.{ a, b }, .{}));
        try testing.expectEqual(@as(u256, @intFromBool(sa < sb)), try evalOp(0x12, &.{ a, b }, .{}));
        try testing.expectEqual(@as(u256, @intFromBool(sa > sb)), try evalOp(0x13, &.{ a, b }, .{}));
        try testing.expectEqual(@as(u256, @intFromBool(a == b)), try evalOp(0x14, &.{ a, b }, .{}));
        try testing.expectEqual(@as(u256, @intFromBool(a == a)), try evalOp(0x14, &.{ a, a }, .{}));
        try testing.expectEqual(@as(u256, @intFromBool(a == 0)), try evalOp(0x15, &.{a}, .{}));
        try testing.expectEqual(a & b, try evalOp(0x16, &.{ a, b }, .{}));
        try testing.expectEqual(a | b, try evalOp(0x17, &.{ a, b }, .{}));
        try testing.expectEqual(a ^ b, try evalOp(0x18, &.{ a, b }, .{}));
        try testing.expectEqual(~a, try evalOp(0x19, &.{a}, .{}));
    }
}

test "helper-backed ops produce spec values" {
    if (native_only) return error.SkipZigTest;
    const clz_on = Options{ .clz = true };
    try testing.expectEqual(@as(u256, 3), try evalOp(0x04, &.{ 10, 3 }, .{}));
    try testing.expectEqual(@as(u256, 0), try evalOp(0x04, &.{ 10, 0 }, .{}));
    try testing.expectEqual(neg(3), try evalOp(0x05, &.{ neg(10), 3 }, .{}));
    try testing.expectEqual(min_i256, try evalOp(0x05, &.{ min_i256, max_u256 }, .{}));
    try testing.expectEqual(@as(u256, 0), try evalOp(0x05, &.{ 7, 0 }, .{}));
    try testing.expectEqual(@as(u256, 1), try evalOp(0x06, &.{ 10, 3 }, .{}));
    try testing.expectEqual(@as(u256, 0), try evalOp(0x06, &.{ 10, 0 }, .{}));
    try testing.expectEqual(neg(1), try evalOp(0x07, &.{ neg(10), 3 }, .{}));
    try testing.expectEqual(@as(u256, 1), try evalOp(0x07, &.{ 10, neg(3) }, .{}));
    try testing.expectEqual(@as(u256, 0), try evalOp(0x07, &.{ min_i256, max_u256 }, .{}));
    try testing.expectEqual(@as(u256, 7), try evalOp(0x08, &.{ max_u256, 2, 10 }, .{}));
    try testing.expectEqual(@as(u256, 0), try evalOp(0x08, &.{ 5, 6, 0 }, .{}));
    try testing.expectEqual(@as(u256, 9), try evalOp(0x09, &.{ max_u256, max_u256, 12 }, .{}));
    try testing.expectEqual(@as(u256, 1) << 255, try evalOp(0x0A, &.{ 2, 255 }, .{}));
    try testing.expectEqual(@as(u256, 1), try evalOp(0x0A, &.{ 3, 0 }, .{}));
    try testing.expectEqual(@as(u256, 0), try evalOp(0x0A, &.{ 2, 256 }, .{}));
    try testing.expectEqual(max_u256, try evalOp(0x0B, &.{ 0, 0xFF }, .{}));
    try testing.expectEqual(@as(u256, 0x7F), try evalOp(0x0B, &.{ 0, 0x7F }, .{}));
    try testing.expectEqual(@as(u256, 0x12FF), try evalOp(0x0B, &.{ 31, 0x12FF }, .{}));
    try testing.expectEqual(@as(u256, 0x34), try evalOp(0x1A, &.{ 31, 0x1234 }, .{}));
    try testing.expectEqual(@as(u256, 0x12), try evalOp(0x1A, &.{ 30, 0x1234 }, .{}));
    try testing.expectEqual(@as(u256, 0), try evalOp(0x1A, &.{ 32, max_u256 }, .{}));
    try testing.expectEqual(@as(u256, 16), try evalOp(0x1B, &.{ 4, 1 }, .{}));
    try testing.expectEqual(@as(u256, 0), try evalOp(0x1B, &.{ 256, 1 }, .{}));
    try testing.expectEqual(@as(u256, 16), try evalOp(0x1C, &.{ 4, 256 }, .{}));
    try testing.expectEqual(max_u256, try evalOp(0x1D, &.{ 4, neg(16) }, .{}));
    try testing.expectEqual(max_u256, try evalOp(0x1D, &.{ 300, min_i256 }, .{}));
    try testing.expectEqual(@as(u256, 0), try evalOp(0x1D, &.{ 300, 5 }, .{}));
    try testing.expectEqual(@as(u256, 255), try evalOp(0x1E, &.{1}, clz_on));
    try testing.expectEqual(@as(u256, 256), try evalOp(0x1E, &.{0}, clz_on));
    try testing.expectEqual(@as(u256, 0), try evalOp(0x1E, &.{max_u256}, clz_on));
    const empty_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    try testing.expectEqual(empty_hash, try evalOp(0x20, &.{ 0, 0 }, .{}));
}

test "static gas is exact" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    // PUSH1 1 PUSH1 2 ADD STOP: 3 + 3 + 3
    var out = try expectSame(allocator, &.{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 }, 100, &.{}, .{});
    defer out.deinit(allocator);
    try testing.expectEqual(@as(i64, 91), out.gas);
    try testing.expectEqualSlices(u256, &.{3}, out.stack);
}

test "GAS reads exact remaining gas mid-block" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    // PUSH1 1 POP GAS PUSH1 1 ADD STOP: GAS sees 100 - 3 - 2 - 2 = 93
    var out = try expectSame(allocator, &.{ 0x60, 0x01, 0x50, 0x5A, 0x60, 0x01, 0x01, 0x00 }, 100, &.{}, .{});
    defer out.deinit(allocator);
    try testing.expectEqualSlices(u256, &.{94}, out.stack);
    try testing.expectEqual(@as(i64, 87), out.gas);
}

test "EXP charges dynamic gas" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    // PUSH2 0x0100 PUSH1 2 EXP STOP: 3 + 3 + 10 + 50*2
    var out = try expectSame(allocator, &.{ 0x61, 0x01, 0x00, 0x60, 0x02, 0x0A, 0x00 }, 1000, &.{}, .{});
    defer out.deinit(allocator);
    try testing.expectEqualSlices(u256, &.{0}, out.stack);
    try testing.expectEqual(@as(i64, 1000 - 116), out.gas);
}

test "PUSH0, PUSH sizes, truncated PUSH, PC, DUP16, SWAP16" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(allocator);
    for (1..17) |v| try code.appendSlice(allocator, &.{ 0x60, @intCast(v) }); // 16 items, top = 16
    try code.appendSlice(allocator, &.{ 0x60, 0x63, 0x9F, 0x8F, 0x5F, 0x58 }); // PUSH1 99 SWAP16 DUP16 PUSH0 PC
    try code.appendSlice(allocator, &.{ 0x67, 1, 2, 3, 4, 5, 6, 7, 8 }); // PUSH8
    try code.appendSlice(allocator, &.{ 0x6B, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }); // PUSH12
    try code.appendSlice(allocator, &.{ 0x7F, 0xAB, 0xCD }); // truncated PUSH32
    var out = try expectSame(allocator, code.items, 10_000, &.{}, .{});
    defer out.deinit(allocator);
    try testing.expectEqual(ExitCode.stop, out.code);
    try testing.expectEqual(@as(u256, 0xABCD) << 240, out.stack[0]);
    try testing.expectEqual(@as(u256, 0x0102030405060708090A0B0C), out.stack[1]);
    try testing.expectEqual(@as(u256, 0x0102030405060708), out.stack[2]);
    try testing.expectEqual(@as(u256, 37), out.stack[3]); // PC
    try testing.expectEqual(@as(u256, 0), out.stack[4]); // PUSH0
    try testing.expectEqual(@as(u256, 2), out.stack[5]); // DUP16 copy of the 16th item
    try testing.expectEqual(@as(u256, 1), out.stack[6]); // SWAP16 moved the bottom 1 up
    try testing.expectEqual(@as(u256, 16), out.stack[7]);
    try testing.expectEqual(@as(u256, 99), out.stack[22]); // SWAP16 moved 99 down
    try testing.expectEqual(@as(usize, 23), out.stack.len);
}

test "memory ops, MSIZE, MCOPY, MSTORE8, RETURN and REVERT output" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    var a = Asm{ .allocator = allocator };
    defer a.deinit();
    try a.push(0x1122334455);
    try a.push(0);
    try a.op(&.{0x52}); // MSTORE at 0
    try a.push(0xEE);
    try a.push(40);
    try a.op(&.{0x53}); // MSTORE8 at 40
    try a.push(64);
    try a.push(0);
    try a.push(64);
    try a.op(&.{0x5E}); // MCOPY dest 64 src 0 size 64
    try a.push(64);
    try a.op(&.{ 0x51, 0x59 }); // MLOAD 64, MSIZE
    try a.push(128);
    try a.push(0);
    try a.op(&.{0xF3}); // RETURN 0..128
    var out = try expectSame(allocator, try a.finish(), 100_000, &.{}, .{});
    defer out.deinit(allocator);
    try testing.expectEqual(ExitCode.return_ok, out.code);
    try testing.expectEqualSlices(u256, &.{ 128, 0x1122334455 }, out.stack);
    try testing.expectEqual(@as(usize, 128), out.output.len);
    try testing.expectEqual(@as(u8, 0xEE), out.output[104]);
    try testing.expectEqual(@as(u8, 0x55), out.output[95]);

    // PUSH1 7 PUSH1 0 MSTORE PUSH1 32 PUSH1 0 REVERT
    var rev = try expectSame(allocator, &.{ 0x60, 0x07, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xFD }, 1000, &.{}, .{});
    defer rev.deinit(allocator);
    try testing.expectEqual(ExitCode.revert, rev.code);
    try testing.expectEqual(@as(u8, 7), rev.output[31]);
    // 3+3+3 static, 3 memory, 3+3 static, 0 return
    try testing.expectEqual(@as(i64, 1000 - 18), rev.gas);
}

test "CALLDATALOAD and CALLDATASIZE" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    const calldata = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01 };
    // A large offset, including all high limbs set, reads a zero word.
    var out = try expectSame(allocator, &.{ 0x36, 0x60, 0x01, 0x35, 0x60, 0xC8, 0x35, 0x5f, 0x19, 0x35, 0x00 }, 1000, &calldata, .{});
    defer out.deinit(allocator);
    try testing.expectEqual(@as(u256, 0), out.stack[0]);
    try testing.expectEqual(@as(u256, 0), out.stack[1]);
    try testing.expectEqual(@as(u256, 0xADBEEF01) << 224, out.stack[2]);
    try testing.expectEqual(@as(u256, 5), out.stack[3]);
}

test "Fibonacci(32) with static jumps" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    const code = [_]u8{
        0x60, 0x00, 0x60, 0x01, 0x60, 0x20, // a=0 b=1 n=32
        0x5B, 0x80, 0x15, 0x60, 0x18, 0x57, // loop: DUP1 ISZERO PUSH1 end JUMPI
        0x60, 0x01, 0x90, 0x03, // n - 1
        0x91, 0x81, 0x01, 0x90, 0x91, // (a, b) = (b, a + b)
        0x60, 0x06, 0x56, // PUSH1 loop JUMP
        0x5B, 0x50, 0x50, // end: POP POP
        0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xF3, // return a
    };
    var out = try expectSame(allocator, &code, 1_000_000, &.{}, .{});
    defer out.deinit(allocator);
    try testing.expectEqual(ExitCode.return_ok, out.code);
    try testing.expectEqual(@as(u256, 2178309), std.mem.readInt(u256, out.output[0..32], .big));
    // setup 9, 32 loop iterations of 55, exit check 20, POPs 5, MSTORE+RETURN 15
    try testing.expectEqual(@as(i64, 1_000_000 - (9 + 32 * 55 + 20 + 5 + 15)), out.gas);
}

test "Factorial(20) and Factorial(60) mod 2^256" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    for ([_]u8{ 20, 60 }) |n| {
        const code = [_]u8{
            0x60, 0x01, 0x60, n, // acc=1, n
            0x5B, 0x80, 0x15, 0x60, 0x15, 0x57, // loop: DUP1 ISZERO PUSH1 end JUMPI
            0x80, 0x91, 0x02, 0x90, // acc *= n
            0x60, 0x01, 0x90, 0x03, // n - 1
            0x60, 0x04, 0x56, // PUSH1 loop JUMP
            0x5B, 0x50, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xF3, // Discard n and return the accumulator.
        };
        var out = try expectSame(allocator, &code, 1_000_000, &.{}, .{});
        defer out.deinit(allocator);
        var want: u256 = 1;
        for (1..@as(usize, n) + 1) |k| want *%= k;
        try testing.expectEqual(want, std.mem.readInt(u256, out.output[0..32], .big));
    }
}

test "bubble sort in memory" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    const n = 16;
    var values: [n]u256 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    for (&values) |*v| v.* = prng.random().int(u256) >> prng.random().int(u8);

    const outer = 0;
    const inner = 1;
    const inner_done = 2;
    const noswap = 3;
    const next = 4;
    const done = 5;
    var a = Asm{ .allocator = allocator };
    defer a.deinit();
    for (values, 0..) |v, i| {
        try a.push(v);
        try a.push(i * 32);
        try a.op(&.{0x52});
    }
    try a.push(n - 1);
    try a.mark(outer); // [i]
    try a.op(&.{ 0x80, 0x15 });
    try a.pushLabel(done);
    try a.op(&.{0x57});
    try a.push(0);
    try a.mark(inner); // [j, i]
    try a.op(&.{ 0x81, 0x81, 0x10, 0x15 }); // !(j < i)
    try a.pushLabel(inner_done);
    try a.op(&.{0x57});
    try a.op(&.{0x80});
    try a.push(32);
    try a.op(&.{ 0x02, 0x80, 0x51, 0x81 }); // off=j*32, x=m[off]
    try a.push(32);
    try a.op(&.{ 0x01, 0x51, 0x81, 0x81, 0x10, 0x15 }); // y=m[off+32], !(y < x)
    try a.pushLabel(noswap);
    try a.op(&.{0x57});
    try a.op(&.{ 0x82, 0x52, 0x81 }); // m[off] = y
    try a.push(32);
    try a.op(&.{ 0x01, 0x52, 0x50 }); // m[off+32] = x, POP off
    try a.pushLabel(next);
    try a.op(&.{0x56});
    try a.mark(noswap);
    try a.op(&.{ 0x50, 0x50, 0x50 });
    try a.mark(next);
    try a.push(1);
    try a.op(&.{0x01});
    try a.pushLabel(inner);
    try a.op(&.{0x56});
    try a.mark(inner_done);
    try a.op(&.{0x50});
    try a.push(1);
    try a.op(&.{ 0x90, 0x03 });
    try a.pushLabel(outer);
    try a.op(&.{0x56});
    try a.mark(done);
    try a.op(&.{0x50});
    try a.push(n * 32);
    try a.push(0);
    try a.op(&.{0xF3});

    var out = try expectSame(allocator, try a.finish(), 10_000_000, &.{}, .{});
    defer out.deinit(allocator);
    try testing.expectEqual(ExitCode.return_ok, out.code);
    std.mem.sort(u256, &values, {}, std.sort.asc(u256));
    for (values, 0..) |v, i| {
        try testing.expectEqual(v, std.mem.readInt(u256, out.output[i * 32 ..][0..32], .big));
    }
}

test "dynamic JUMP and JUMPI" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    // 0: PUSH1 3 PUSH1 5 ADD JUMP(8) INVALID INVALID
    // 8: JUMPDEST PUSH1 1 PUSH1 17 DUP1 POP JUMPI(taken) INVALID
    // 17: JUMPDEST PUSH1 0 PUSH1 28 DUP1 POP JUMPI(not taken) PUSH1 42 STOP
    // 28: JUMPDEST
    const code = [_]u8{ 0x60, 0x03, 0x60, 0x05, 0x01, 0x56, 0xFE, 0xFE, 0x5B, 0x60, 0x01, 0x60, 0x11, 0x80, 0x50, 0x57, 0xFE, 0x5B, 0x60, 0x00, 0x60, 0x1C, 0x80, 0x50, 0x57, 0x60, 0x2A, 0x00, 0x5B };
    var out = try expectSame(allocator, &code, 1000, &.{}, .{});
    defer out.deinit(allocator);
    try testing.expectEqual(ExitCode.stop, out.code);
    try testing.expectEqualSlices(u256, &.{42}, out.stack);
}

test "invalid jumps: non-JUMPDEST, push data, out of range, huge" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    const cases = [_][]const u8{
        &.{ 0x60, 0x02, 0x56, 0x00 }, // static to STOP
        &.{ 0x60, 0x02, 0x80, 0x50, 0x56, 0x00 }, // dynamic to PUSH1 operand
        &.{ 0x60, 0x5B, 0x60, 0x01, 0x80, 0x50, 0x56 }, // into push data that reads 0x5B
        &.{ 0x61, 0x10, 0x00, 0x80, 0x50, 0x56, 0x5B }, // past the end
        &.{ 0x7F, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x26, 0x80, 0x50, 0x56, 0x5B }, // high limbs set
        &.{ 0x60, 0x01, 0x60, 0x09, 0x80, 0x50, 0x57, 0x00, 0x00, 0x00 }, // JUMPI taken to STOP
        &.{ 0x60, 0x01, 0x60, 0x06, 0x57, 0x00, 0x00 }, // static JUMPI taken, invalid target
    };
    for (cases) |code| {
        var out = try expectSame(allocator, code, 1000, &.{}, .{});
        defer out.deinit(allocator);
        try testing.expectEqual(ExitCode.invalid_jump, out.code);
        try testing.expectEqual(@as(i64, 0), out.gas);
    }
    // JUMPI with a zero condition ignores an invalid target.
    var ok = try expectSame(allocator, &.{ 0x60, 0x00, 0x60, 0x63, 0x57, 0x60, 0x09, 0x00 }, 1000, &.{}, .{});
    defer ok.deinit(allocator);
    try testing.expectEqual(ExitCode.stop, ok.code);
    try testing.expectEqualSlices(u256, &.{9}, ok.stack);

    // The dynamic path must also ignore all 256 destination bits.
    var dynamic = try expectSame(allocator, &.{ 0x5f, 0x5f, 0x19, 0x57, 0x60, 9, 0 }, 1000, &.{}, .{});
    defer dynamic.deinit(allocator);
    try testing.expectEqual(ExitCode.stop, dynamic.code);
    try testing.expectEqualSlices(u256, &.{9}, dynamic.stack);
}

test "out of gas, stack underflow, stack overflow, invalid opcode" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    const fib = [_]u8{ 0x60, 0x00, 0x60, 0x01, 0x60, 0x20, 0x5B, 0x80, 0x15, 0x60, 0x18, 0x57, 0x60, 0x01, 0x90, 0x03, 0x91, 0x81, 0x01, 0x90, 0x91, 0x60, 0x06, 0x56, 0x5B, 0x50, 0x50, 0x00 };
    var oog = try expectSame(allocator, &fib, 500, &.{}, .{});
    defer oog.deinit(allocator);
    try testing.expectEqual(ExitCode.out_of_gas, oog.code);
    try testing.expectEqual(@as(i64, 0), oog.gas);

    // Exactly enough gas succeeds; one less fails.
    var exact = try expectSame(allocator, &.{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 }, 9, &.{}, .{});
    defer exact.deinit(allocator);
    try testing.expectEqual(ExitCode.stop, exact.code);
    var short = try expectSame(allocator, &.{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 }, 8, &.{}, .{});
    defer short.deinit(allocator);
    try testing.expectEqual(ExitCode.out_of_gas, short.code);

    var under = try expectSame(allocator, &.{ 0x60, 0x01, 0x01, 0x00 }, 1000, &.{}, .{});
    defer under.deinit(allocator);
    try testing.expectEqual(ExitCode.stack_underflow, under.code);

    // JUMPDEST PUSH1 1 PUSH1 0 JUMP: grows until the 1025th push.
    var over = try expectSame(allocator, &.{ 0x5B, 0x60, 0x01, 0x60, 0x00, 0x56 }, 1_000_000, &.{}, .{});
    defer over.deinit(allocator);
    try testing.expectEqual(ExitCode.stack_overflow, over.code);

    var invalid = try expectSame(allocator, &.{ 0x60, 0x01, 0xFE }, 1000, &.{}, .{});
    defer invalid.deinit(allocator);
    try testing.expectEqual(ExitCode.invalid_opcode, invalid.code);

    // Memory expansion out of gas inside a helper.
    var mem_oog = try expectSame(allocator, &.{ 0x60, 0x01, 0x63, 0x10, 0, 0, 0, 0x52, 0x00 }, 100_000, &.{}, .{});
    defer mem_oog.deinit(allocator);
    try testing.expectEqual(ExitCode.out_of_gas, mem_oog.code);

    // Disabled PUSH0 is an undefined opcode.
    var no_push0 = try expectSame(allocator, &.{ 0x60, 0x01, 0x00 }, 1000, &.{}, .{ .push0 = false });
    defer no_push0.deinit(allocator);
    var p0 = try runJit(allocator, &.{0x5F}, 1000, &.{}, .{ .push0 = false });
    defer p0.deinit(allocator);
    try testing.expectEqual(ExitCode.invalid_opcode, p0.code);
}

test "MCOPY leaves memory unchanged when combined expansion exceeds gas" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    // After static and copy gas, exactly one word of expansion is affordable.
    // The source range needs two words, so neither range may expand memory.
    var out = try runJit(allocator, &.{ 0x60, 1, 0x60, 32, 0x5f, 0x5e }, 17, &.{}, .{});
    defer out.deinit(allocator);
    try testing.expectEqual(ExitCode.out_of_gas, out.code);
    try testing.expectEqual(@as(usize, 0), out.memory.len);
}

test "the instruction budget interrupts a loop with gas remaining" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    var program = (try compile(allocator, &.{ 0x5b, 0x5f, 0x56 }, .{})).?;
    defer program.deinit();
    var frame: Frame = undefined;
    frame.init(1000, &.{}, &default_helpers);
    defer frame.deinit();
    frame.ctx.instruction_budget = 3;
    try testing.expectEqual(ExitCode.fallback, try program.run(&frame.ctx));
    try testing.expectEqual(@as(usize, 0), frame.stackItems().len);
}

test "ineligible code compiles to null" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    try testing.expect((try compile(allocator, &.{}, .{})) == null);
    try testing.expect((try compile(allocator, &.{ 0x60, 0x00, 0x54, 0x00 }, .{})) == null); // SLOAD
    try testing.expect((try compile(allocator, &.{ 0x60, 0x00, 0xF1 }, .{})) == null); // CALL
    try testing.expect((try compile(allocator, &.{0x0C}, .{})) == null); // undefined byte
    try testing.expect((try compile(allocator, &.{ 0x20, 0x00 }, .{ .keccak256 = false })) == null);
    const big = try allocator.alloc(u8, compiler.max_code_size + 1);
    defer allocator.free(big);
    @memset(big, 0x5B);
    try testing.expect((try compile(allocator, big, .{})) == null);

    // Dead code after a terminator may hold anything (e.g. metadata).
    var program = (try compile(allocator, &.{ 0x00, 0x54, 0xF1, 0xFF }, .{})).?;
    program.deinit();
}

test "run validates the context and handles negative gas" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    var program = (try compile(allocator, &.{ 0x60, 0x01, 0x00 }, .{})).?;
    defer program.deinit();
    const frame = try allocator.create(Frame);
    defer allocator.destroy(frame);
    frame.init(-5, &.{}, &default_helpers);
    defer frame.deinit();
    try testing.expectEqual(ExitCode.out_of_gas, try program.run(&frame.ctx));
    try testing.expectEqual(@as(i64, 0), frame.ctx.gas_remaining);
    frame.ctx.stack_ptr = frame.ctx.stack_base + 1;
    try testing.expectError(error.InvalidContext, program.run(&frame.ctx));
}

test "max-size straight-line code compiles and runs" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    // 24575 bytes: PUSH1 0, then MUL-free pairs of PUSH1 1 ADD, then STOP.
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(allocator);
    try code.appendSlice(allocator, &.{ 0x60, 0x00 });
    while (code.items.len + 3 < compiler.max_code_size) try code.appendSlice(allocator, &.{ 0x60, 0x01, 0x01 });
    try code.append(allocator, 0x00);
    var out = try expectSame(allocator, code.items, 10_000_000, &.{}, .{});
    defer out.deinit(allocator);
    try testing.expectEqual(@as(u256, (code.items.len - 3) / 3), out.stack[0]);
}

test "random programs match the reference interpreter" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const random = prng.random();
    const pool = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x10, 0x11, 0x12, 0x13, 0x14,
        0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x35, 0x36, 0x50, 0x58, 0x59, 0x5A,
        0x5F, 0x80, 0x81, 0x83, 0x87, 0x8F, 0x90, 0x91, 0x94, 0x9F, 0x51, 0x52, 0x53, 0x5E, 0x20,
    };
    const calldata = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35 };
    var successes: usize = 0;
    for (0..1500) |_| {
        var code: std.ArrayList(u8) = .empty;
        defer code.deinit(allocator);
        for (0..16 + random.uintLessThan(usize, 16)) |_| {
            const value = switch (random.uintLessThan(u8, 5)) {
                0 => random.int(u256),
                1 => random.uintLessThan(u256, 300),
                2 => max_u256 - random.uintLessThan(u256, 3),
                3 => random.int(u256) >> random.int(u8),
                else => random.uintLessThan(u256, 64),
            };
            try push32(&code, allocator, value);
        }
        for (0..random.uintLessThan(usize, 40)) |_| {
            const op = pool[random.uintLessThan(usize, pool.len)];
            if (op == 0x51 or op == 0x52 or op == 0x53 or op == 0x5E or op == 0x20 or op == 0x35) {
                // Keep most offsets small so memory paths run.
                if (random.uintLessThan(u8, 8) != 0) try code.appendSlice(allocator, &.{ 0x61, random.int(u8) & 3, random.int(u8) });
                if (op == 0x5E or op == 0x20) try code.appendSlice(allocator, &.{ 0x60, random.int(u8) });
            }
            try code.append(allocator, op);
        }
        try code.append(allocator, if (random.boolean()) 0x00 else 0xF3);
        const gas: i64 = if (random.uintLessThan(u8, 4) == 0) @intCast(random.uintLessThan(u64, 400)) else 10_000_000;
        var out = try expectSame(allocator, code.items, gas, &calldata, .{ .clz = true });
        defer out.deinit(allocator);
        if (!out.code.isExceptional()) successes += 1;
    }
    try testing.expect(successes > 500);
}

test "stack bounds are exact at 1024 items and at block boundaries" {
    if (native_only) return error.SkipZigTest;
    const allocator = testing.allocator;
    const Case = struct { first: usize, second: usize, want: ExitCode };
    const cases = [_]Case{
        .{ .first = 1024, .second = 0, .want = .stop },
        .{ .first = 1025, .second = 0, .want = .stack_overflow },
        .{ .first = 1023, .second = 1, .want = .stop },
        .{ .first = 1024, .second = 1, .want = .stack_overflow },
        .{ .first = 1000, .second = 24, .want = .stop },
        .{ .first = 1000, .second = 25, .want = .stack_overflow },
    };
    for (cases) |case| {
        var code: std.ArrayList(u8) = .empty;
        defer code.deinit(allocator);
        for (0..case.first) |_| try code.appendSlice(allocator, &.{ 0x60, 0x01 });
        try code.append(allocator, 0x5B);
        for (0..case.second) |_| try code.appendSlice(allocator, &.{ 0x60, 0x02 });
        try code.append(allocator, 0x00);
        var out = try expectSame(allocator, code.items, 1_000_000, &.{}, .{});
        defer out.deinit(allocator);
        try testing.expectEqual(case.want, out.code);
    }
    // Underflow: a block that pops exactly as many items as exist, then one more.
    for ([_]usize{ 3, 4 }) |pops| {
        var code: std.ArrayList(u8) = .empty;
        defer code.deinit(allocator);
        try code.appendSlice(allocator, &.{ 0x60, 0x01, 0x60, 0x01, 0x60, 0x01, 0x5B });
        for (0..pops) |_| try code.append(allocator, 0x50);
        try code.append(allocator, 0x00);
        var out = try expectSame(allocator, code.items, 1000, &.{}, .{});
        defer out.deinit(allocator);
        try testing.expectEqual(if (pops == 3) ExitCode.stop else ExitCode.stack_underflow, out.code);
    }
}
