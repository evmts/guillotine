//! EVM bytecode to AArch64 compiler.
//!
//! Pipeline: decode -> split live code into basic blocks -> per-block stack
//! bounds and gas segments -> emit native code -> patch branches -> map into
//! executable memory.
//!
//! Gas: each block is cut into segments that end at GAS or at an opcode with
//! dynamic gas (EXP, MLOAD, MSTORE, MSTORE8, MCOPY, KECCAK256, RETURN,
//! REVERT). A segment's static gas is charged once at its start, so the gas
//! register is exact whenever GAS reads it or a helper charges dynamic gas.
//! Stack bounds are checked once per block. A failed check halts earlier in
//! the block than an interpreter would, but every such halt is exceptional:
//! it consumes all gas and produces no output, so results are identical.
//!
//! Native register map inside a compiled function:
//!   x19 ctx  x20 stack top  x21 gas  x22 stack base  x23 stack limit
//!   x24 helpers table.  x0-x17 and v0-v3 are scratch.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const a64 = @import("arm64_emitter.zig");
const jit_mem = @import("jit_mem.zig");

const JitContext = root.JitContext;
const ExitCode = root.ExitCode;
const Emitter = a64.Emitter;

pub const max_code_size = 24576;

/// True when `compile` can produce native code on this target.
pub const native_supported = builtin.cpu.arch == .aarch64 and jit_mem.supported;

pub const Options = struct {
    /// PUSH0 (Shanghai). When false, 0x5F is an undefined opcode.
    push0: bool = true,
    /// MCOPY (Cancun). When false, 0x5E is an undefined opcode.
    mcopy: bool = true,
    /// CLZ (Osaka). When false, 0x1E is an undefined opcode.
    clz: bool = false,
    shifts: bool = true,
    revert: bool = true,
    /// Set false when the host has no KECCAK256 helper; KECCAK256 then makes
    /// the code ineligible.
    keccak256: bool = true,
    /// Let the host reproduce interpreter-specific partial state on a fault.
    replay_exceptional_halts: bool = false,
};

pub const EntryFn = *const fn (ctx: *JitContext) callconv(.c) u32;

pub const RunError = error{ InvalidContext, InvalidExitCode };

pub const Program = struct {
    mem: jit_mem.ExecMemory,
    entry: EntryFn,
    uses_keccak: bool,
    /// Bytes of native code, excluding the jump table.
    native_len: usize,
    replay_exceptional_halts: bool = false,

    pub fn deinit(self: *Program) void {
        self.mem.deinit();
    }

    /// Runs the program. The context must describe a 1024-slot stack, gas,
    /// memory, and calldata. Output bounds are valid for RETURN and REVERT.
    pub fn run(self: *const Program, ctx: *JitContext) RunError!ExitCode {
        const limit = @intFromPtr(ctx.stack_limit);
        const base = @intFromPtr(ctx.stack_base);
        const top = @intFromPtr(ctx.stack_ptr);
        if (base < limit or base - limit != root.stack_capacity * 32) return error.InvalidContext;
        if (top < limit or top > base or (top - limit) % 32 != 0) return error.InvalidContext;
        if (ctx.memory_len % 32 != 0 or ctx.memory_len > ctx.memory_cap or ctx.memory_len > ctx.memory_limit) return error.InvalidContext;
        if (ctx.memory_cost != root.helpers.memoryCost(ctx.memory_len / 32)) return error.InvalidContext;
        if (ctx.memory_cap > 0 and ctx.memory_ptr == null) return error.InvalidContext;
        ctx.output_offset = 0;
        ctx.output_len = 0;
        if (ctx.gas_remaining < 0) {
            ctx.gas_remaining = 0;
            const exit: ExitCode = if (self.replay_exceptional_halts) .fallback else .out_of_gas;
            ctx.exit_code = @intFromEnum(exit);
            return exit;
        }
        if (self.uses_keccak and ctx.helpers.keccak256 == null) {
            ctx.exit_code = @intFromEnum(ExitCode.fallback);
            return .fallback;
        }
        const rc = self.entry(ctx);
        const exit = std.enums.fromInt(ExitCode, rc) orelse return error.InvalidExitCode;
        if (self.replay_exceptional_halts and exit.isExceptional()) {
            ctx.exit_code = @intFromEnum(ExitCode.fallback);
            return .fallback;
        }
        return exit;
    }
};

pub const CompileError = error{ OutOfMemory, ImmediateOutOfRange } || jit_mem.Error;

// ------------------------------------------------------------------ opcodes

const Kind = enum {
    stop,
    add,
    mul,
    sub,
    lt,
    gt,
    slt,
    sgt,
    eq,
    iszero,
    and_,
    or_,
    xor,
    not,
    binary_helper,
    ternary_helper,
    unary_helper,
    exp,
    keccak,
    calldataload,
    calldatasize,
    pop,
    mload,
    mstore,
    mstore8,
    mcopy,
    jump,
    jumpi,
    pc,
    msize,
    gas,
    jumpdest,
    push,
    dup,
    swap,
    ret,
    revert,
    invalid,

    fn terminates(self: Kind) bool {
        return switch (self) {
            .stop, .jump, .ret, .revert, .invalid => true,
            else => false,
        };
    }

    /// Ends a gas segment: the gas register must be exact at this opcode.
    fn endsSegment(self: Kind) bool {
        return switch (self) {
            .gas, .exp, .keccak, .mload, .mstore, .mstore8, .mcopy, .ret, .revert => true,
            else => false,
        };
    }
};

const OpInfo = struct {
    kind: Kind,
    pops: u8,
    pushes: u8,
    gas: u32,
    /// Byte offset of the helper in `RuntimeHelpers`, for helper kinds.
    helper: u32 = 0,
};

fn helperOffset(comptime name: []const u8) u32 {
    return @offsetOf(root.RuntimeHelpers, name);
}

fn ctxOffset(comptime name: []const u8) u32 {
    return @offsetOf(JitContext, name);
}

/// Returns null for opcodes this compiler does not support (the code is then
/// ineligible). Opcodes disabled by `options` decode as `.invalid`.
fn opInfo(op: u8, options: Options) ?OpInfo {
    const undefined_op = OpInfo{ .kind = .invalid, .pops = 0, .pushes = 0, .gas = 0 };
    return switch (op) {
        0x00 => .{ .kind = .stop, .pops = 0, .pushes = 0, .gas = 0 },
        0x01 => .{ .kind = .add, .pops = 2, .pushes = 1, .gas = 3 },
        0x02 => .{ .kind = .mul, .pops = 2, .pushes = 1, .gas = 5 },
        0x03 => .{ .kind = .sub, .pops = 2, .pushes = 1, .gas = 3 },
        0x04 => .{ .kind = .binary_helper, .pops = 2, .pushes = 1, .gas = 5, .helper = helperOffset("div") },
        0x05 => .{ .kind = .binary_helper, .pops = 2, .pushes = 1, .gas = 5, .helper = helperOffset("sdiv") },
        0x06 => .{ .kind = .binary_helper, .pops = 2, .pushes = 1, .gas = 5, .helper = helperOffset("mod") },
        0x07 => .{ .kind = .binary_helper, .pops = 2, .pushes = 1, .gas = 5, .helper = helperOffset("smod") },
        0x08 => .{ .kind = .ternary_helper, .pops = 3, .pushes = 1, .gas = 8, .helper = helperOffset("addmod") },
        0x09 => .{ .kind = .ternary_helper, .pops = 3, .pushes = 1, .gas = 8, .helper = helperOffset("mulmod") },
        0x0A => .{ .kind = .exp, .pops = 2, .pushes = 1, .gas = 10, .helper = helperOffset("exp") },
        0x0B => .{ .kind = .binary_helper, .pops = 2, .pushes = 1, .gas = 5, .helper = helperOffset("signextend") },
        0x10 => .{ .kind = .lt, .pops = 2, .pushes = 1, .gas = 3 },
        0x11 => .{ .kind = .gt, .pops = 2, .pushes = 1, .gas = 3 },
        0x12 => .{ .kind = .slt, .pops = 2, .pushes = 1, .gas = 3 },
        0x13 => .{ .kind = .sgt, .pops = 2, .pushes = 1, .gas = 3 },
        0x14 => .{ .kind = .eq, .pops = 2, .pushes = 1, .gas = 3 },
        0x15 => .{ .kind = .iszero, .pops = 1, .pushes = 1, .gas = 3 },
        0x16 => .{ .kind = .and_, .pops = 2, .pushes = 1, .gas = 3 },
        0x17 => .{ .kind = .or_, .pops = 2, .pushes = 1, .gas = 3 },
        0x18 => .{ .kind = .xor, .pops = 2, .pushes = 1, .gas = 3 },
        0x19 => .{ .kind = .not, .pops = 1, .pushes = 1, .gas = 3 },
        0x1A => .{ .kind = .binary_helper, .pops = 2, .pushes = 1, .gas = 3, .helper = helperOffset("byte") },
        0x1B => if (options.shifts) .{ .kind = .binary_helper, .pops = 2, .pushes = 1, .gas = 3, .helper = helperOffset("shl") } else undefined_op,
        0x1C => if (options.shifts) .{ .kind = .binary_helper, .pops = 2, .pushes = 1, .gas = 3, .helper = helperOffset("shr") } else undefined_op,
        0x1D => if (options.shifts) .{ .kind = .binary_helper, .pops = 2, .pushes = 1, .gas = 3, .helper = helperOffset("sar") } else undefined_op,
        0x1E => if (options.clz) .{ .kind = .unary_helper, .pops = 1, .pushes = 1, .gas = 5, .helper = helperOffset("clz") } else undefined_op,
        0x20 => if (options.keccak256) .{ .kind = .keccak, .pops = 2, .pushes = 1, .gas = 30, .helper = helperOffset("keccak256") } else null,
        0x35 => .{ .kind = .calldataload, .pops = 1, .pushes = 1, .gas = 3, .helper = helperOffset("calldataload") },
        0x36 => .{ .kind = .calldatasize, .pops = 0, .pushes = 1, .gas = 2 },
        0x50 => .{ .kind = .pop, .pops = 1, .pushes = 0, .gas = 2 },
        0x51 => .{ .kind = .mload, .pops = 1, .pushes = 1, .gas = 3, .helper = helperOffset("mload") },
        0x52 => .{ .kind = .mstore, .pops = 2, .pushes = 0, .gas = 3, .helper = helperOffset("mstore") },
        0x53 => .{ .kind = .mstore8, .pops = 2, .pushes = 0, .gas = 3, .helper = helperOffset("mstore8") },
        0x56 => .{ .kind = .jump, .pops = 1, .pushes = 0, .gas = 8 },
        0x57 => .{ .kind = .jumpi, .pops = 2, .pushes = 0, .gas = 10 },
        0x58 => .{ .kind = .pc, .pops = 0, .pushes = 1, .gas = 2 },
        0x59 => .{ .kind = .msize, .pops = 0, .pushes = 1, .gas = 2 },
        0x5A => .{ .kind = .gas, .pops = 0, .pushes = 1, .gas = 2 },
        0x5B => .{ .kind = .jumpdest, .pops = 0, .pushes = 0, .gas = 1 },
        0x5E => if (options.mcopy) .{ .kind = .mcopy, .pops = 3, .pushes = 0, .gas = 3, .helper = helperOffset("mcopy") } else undefined_op,
        0x5F => if (options.push0) .{ .kind = .push, .pops = 0, .pushes = 1, .gas = 2 } else undefined_op,
        0x60...0x7F => .{ .kind = .push, .pops = 0, .pushes = 1, .gas = 3 },
        0x80...0x8F => .{ .kind = .dup, .pops = op - 0x7F, .pushes = op - 0x7F + 1, .gas = 3 },
        0x90...0x9F => .{ .kind = .swap, .pops = op - 0x8F + 1, .pushes = op - 0x8F + 1, .gas = 3 },
        0xF3 => .{ .kind = .ret, .pops = 2, .pushes = 0, .gas = 0 },
        0xFD => if (options.revert) .{ .kind = .revert, .pops = 2, .pushes = 0, .gas = 0 } else undefined_op,
        0xFE => undefined_op,
        else => null,
    };
}

// ----------------------------------------------------------------- analysis

const Instr = struct {
    pc: u32,
    op: u8,
    info: OpInfo,
    /// PUSH immediate (zero for other opcodes).
    imm: u256,
};

const Block = struct {
    first: u32,
    /// Exclusive.
    last: u32,
    entry_pc: u32,
    is_dest: bool,
    /// Control may continue to the instruction after `last - 1`.
    falls_through: bool,
    min_stack: u32,
    max_growth: u32,
};

const Analysis = struct {
    instrs: std.ArrayList(Instr) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    /// For each pc: index of the block starting at that JUMPDEST, or `none`.
    dest_block: []u32 = &.{},
    uses_keccak: bool = false,

    const none = std.math.maxInt(u32);

    fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        self.instrs.deinit(allocator);
        self.blocks.deinit(allocator);
        allocator.free(self.dest_block);
    }
};

fn readPush(code: []const u8, pc: usize, n: usize) u256 {
    var value: u256 = 0;
    for (0..n) |k| {
        const at = pc + 1 + k;
        const b: u8 = if (at < code.len) code[at] else 0;
        value = (value << 8) | b;
    }
    return value;
}

/// Returns false when live code contains an unsupported opcode.
fn analyze(allocator: std.mem.Allocator, code: []const u8, options: Options, out: *Analysis) error{OutOfMemory}!bool {
    out.dest_block = try allocator.alloc(u32, code.len);
    @memset(out.dest_block, Analysis.none);

    var live = true;
    var open: ?u32 = null;
    var pc: usize = 0;
    while (pc < code.len) {
        const op = code[pc];
        const push_len: usize = if (op >= 0x60 and op <= 0x7F) op - 0x5F else 0;
        const this_pc = pc;
        pc += 1 + push_len;

        if (op == 0x5B) {
            if (open) |first| try closeBlock(allocator, out, first, true);
            open = null;
            live = true;
        }
        if (!live) continue;
        const info = opInfo(op, options) orelse return false;
        if (info.kind == .keccak) out.uses_keccak = true;
        const index: u32 = @intCast(out.instrs.items.len);
        try out.instrs.append(allocator, .{
            .pc = @intCast(this_pc),
            .op = op,
            .info = info,
            .imm = if (info.kind == .push) readPush(code, this_pc, push_len) else 0,
        });
        if (open == null) open = index;
        if (info.kind.terminates()) {
            try closeBlock(allocator, out, open.?, false);
            open = null;
            live = false;
            continue;
        }
        if (info.kind == .jumpi) {
            try closeBlock(allocator, out, open.?, true);
            open = null;
        }
    }
    if (open) |first| try closeBlock(allocator, out, first, true);

    for (out.blocks.items, 0..) |block, b| {
        if (block.is_dest) out.dest_block[block.entry_pc] = @intCast(b);
    }
    return true;
}

fn closeBlock(allocator: std.mem.Allocator, out: *Analysis, first: u32, falls_through: bool) error{OutOfMemory}!void {
    const last: u32 = @intCast(out.instrs.items.len);
    var height: i32 = 0;
    var lowest: i32 = 0;
    var highest: i32 = 0;
    for (out.instrs.items[first..last]) |instr| {
        height -= instr.info.pops;
        lowest = @min(lowest, height);
        height += instr.info.pushes;
        highest = @max(highest, height);
    }
    const head = out.instrs.items[first];
    try out.blocks.append(allocator, .{
        .first = first,
        .last = last,
        .entry_pc = head.pc,
        .is_dest = head.op == 0x5B,
        .falls_through = falls_through,
        .min_stack = @intCast(-lowest),
        .max_growth = @intCast(highest),
    });
}

// ------------------------------------------------------------------ codegen

const R = struct {
    const ctx: a64.Reg = 19;
    const sp: a64.Reg = 20;
    const gas: a64.Reg = 21;
    const base: a64.Reg = 22;
    const limit: a64.Reg = 23;
    const helpers: a64.Reg = 24;
    const budget: a64.Reg = 25;
    const call: a64.Reg = a64.ip0;
};

const Label = u32;

const Fixup = struct { at: u32, label: Label, kind: a64.FixupKind };

const Codegen = struct {
    allocator: std.mem.Allocator,
    e: Emitter,
    labels: std.ArrayList(?u32) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    code_len: u32,

    // Fixed labels, allocated first in this order.
    const epilogue: Label = 0;
    const exit_oog: Label = 1;
    const exit_underflow: Label = 2;
    const exit_overflow: Label = 3;
    const exit_invalid_jump: Label = 4;
    const exit_invalid_opcode: Label = 5;
    const exit_helper_err: Label = 6;
    const jump_table: Label = 7;
    const exit_budget: Label = 8;
    const fixed_labels = 9;

    fn deinit(self: *Codegen) void {
        self.e.deinit();
        self.labels.deinit(self.allocator);
        self.fixups.deinit(self.allocator);
    }

    fn newLabel(self: *Codegen) error{OutOfMemory}!Label {
        try self.labels.append(self.allocator, null);
        return @intCast(self.labels.items.len - 1);
    }

    fn bind(self: *Codegen, label: Label) void {
        self.labels.items[label] = self.e.offset();
    }

    fn fixup(self: *Codegen, label: Label, kind: a64.FixupKind) a64.Error!void {
        try self.fixups.append(self.allocator, .{ .at = self.e.offset(), .label = label, .kind = kind });
    }

    fn b(self: *Codegen, label: Label) a64.Error!void {
        try self.fixup(label, .b26);
        try self.e.bPlaceholder();
    }

    fn bcond(self: *Codegen, cond: a64.Cond, label: Label) a64.Error!void {
        try self.fixup(label, .imm19);
        try self.e.bcondPlaceholder(cond);
    }

    fn cbz(self: *Codegen, reg: a64.Reg, label: Label) a64.Error!void {
        try self.fixup(label, .imm19);
        try self.e.cbzPlaceholder(reg);
    }

    fn cbnz(self: *Codegen, reg: a64.Reg, label: Label) a64.Error!void {
        try self.fixup(label, .imm19);
        try self.e.cbnzPlaceholder(reg);
    }

    fn cbnzW(self: *Codegen, reg: a64.Reg, label: Label) a64.Error!void {
        try self.fixup(label, .imm19);
        try self.e.cbnzWPlaceholder(reg);
    }

    /// Compares `reg` with an unsigned constant.
    fn cmpConst(self: *Codegen, reg: a64.Reg, value: u64) a64.Error!void {
        if (value < 4096) return self.e.cmpImm(reg, @intCast(value));
        try self.e.movImm64(10, value);
        try self.e.cmp(reg, 10);
    }

    fn chargeGas(self: *Codegen, amount: u64) a64.Error!void {
        if (amount == 0) return;
        if (amount < 4096) {
            try self.e.subsImm(R.gas, R.gas, @intCast(amount));
        } else {
            try self.e.movImm64(9, amount);
            try self.e.subs(R.gas, R.gas, 9);
        }
        try self.bcond(.lt, exit_oog);
    }

    fn prologue(self: *Codegen) a64.Error!void {
        const e = &self.e;
        try e.stp(a64.fp, a64.lr, a64.sp, -80, .pre);
        try e.movSp(a64.fp, a64.sp);
        try e.stp(19, 20, a64.sp, 16, .offset);
        try e.stp(21, 22, a64.sp, 32, .offset);
        try e.stp(23, 24, a64.sp, 48, .offset);
        try e.stp(R.budget, a64.xzr, a64.sp, 64, .offset);
        try e.mov(R.ctx, 0);
        try e.ldr(R.sp, R.ctx, ctxOffset("stack_ptr"));
        try e.ldr(R.base, R.ctx, ctxOffset("stack_base"));
        try e.ldr(R.limit, R.ctx, ctxOffset("stack_limit"));
        try e.ldr(R.gas, R.ctx, ctxOffset("gas_remaining"));
        try e.ldr(R.helpers, R.ctx, ctxOffset("helpers"));
        try e.ldr(R.budget, R.ctx, ctxOffset("instruction_budget"));
    }

    fn exits(self: *Codegen) a64.Error!void {
        const e = &self.e;
        const stubs = [_]struct { label: Label, code: ExitCode }{
            .{ .label = exit_oog, .code = .out_of_gas },
            .{ .label = exit_underflow, .code = .stack_underflow },
            .{ .label = exit_overflow, .code = .stack_overflow },
            .{ .label = exit_invalid_jump, .code = .invalid_jump },
            .{ .label = exit_invalid_opcode, .code = .invalid_opcode },
            .{ .label = exit_budget, .code = .fallback },
        };
        for (stubs) |stub| {
            self.bind(stub.label);
            try e.movzW(0, @intCast(@intFromEnum(stub.code)));
            try e.movz(R.gas, 0, 0);
            try self.b(epilogue);
        }
        // Helper failures keep the helper's code in w0; all are exceptional.
        self.bind(exit_helper_err);
        try e.movz(R.gas, 0, 0);

        self.bind(epilogue);
        try e.str(R.sp, R.ctx, ctxOffset("stack_ptr"));
        try e.str(R.gas, R.ctx, ctxOffset("gas_remaining"));
        try e.strW(0, R.ctx, ctxOffset("exit_code"));
        try e.ldp(R.budget, a64.xzr, a64.sp, 64, .offset);
        try e.ldp(23, 24, a64.sp, 48, .offset);
        try e.ldp(21, 22, a64.sp, 32, .offset);
        try e.ldp(19, 20, a64.sp, 16, .offset);
        try e.ldp(a64.fp, a64.lr, a64.sp, 80, .post);
        try e.ret();
    }

    fn exitWith(self: *Codegen, code: ExitCode) a64.Error!void {
        try self.e.movzW(0, @intCast(@intFromEnum(code)));
        try self.b(epilogue);
    }

    fn pushReg(self: *Codegen, reg: a64.Reg) a64.Error!void {
        try self.e.stp(reg, a64.xzr, R.sp, -32, .pre);
        try self.e.stp(a64.xzr, a64.xzr, R.sp, 16, .offset);
    }

    fn pushConst(self: *Codegen, value: u256) a64.Error!void {
        var regs: [4]a64.Reg = undefined;
        for (0..4) |k| {
            const limb: u64 = @truncate(value >> @intCast(k * 64));
            if (limb == 0) {
                regs[k] = a64.xzr;
                continue;
            }
            regs[k] = @intCast(k);
            try self.e.movImm64(@intCast(k), limb);
        }
        try self.e.stp(regs[0], regs[1], R.sp, -32, .pre);
        try self.e.stp(regs[2], regs[3], R.sp, 16, .offset);
    }

    /// x0..x3 = top (a), x4..x7 = second (b).
    fn loadTwo(self: *Codegen) a64.Error!void {
        try self.e.ldp(0, 1, R.sp, 0, .offset);
        try self.e.ldp(2, 3, R.sp, 16, .offset);
        try self.e.ldp(4, 5, R.sp, 32, .offset);
        try self.e.ldp(6, 7, R.sp, 48, .offset);
    }

    /// Pops one slot and overwrites the new top with r0..r3.
    fn storeBinary(self: *Codegen, r0: a64.Reg, r1: a64.Reg, r2: a64.Reg, r3: a64.Reg) a64.Error!void {
        try self.e.stp(r0, r1, R.sp, 32, .pre);
        try self.e.stp(r2, r3, R.sp, 16, .offset);
    }

    /// Unsigned or signed less-than of (x, y) as 256-bit values in register
    /// quads; leaves the flags of x - y.
    fn compare(self: *Codegen, x: a64.Reg, y: a64.Reg) a64.Error!void {
        try self.e.cmp(x, y);
        try self.e.sbcs(a64.xzr, x + 1, y + 1);
        try self.e.sbcs(a64.xzr, x + 2, y + 2);
        try self.e.sbcs(a64.xzr, x + 3, y + 3);
    }

    fn compareOp(self: *Codegen, x: a64.Reg, y: a64.Reg, cond: a64.Cond) a64.Error!void {
        try self.loadTwo();
        try self.compare(x, y);
        try self.e.cset(0, cond);
        try self.storeBinary(0, a64.xzr, a64.xzr, a64.xzr);
    }

    const VectorKind = enum { and_, or_, xor };

    fn vectorOp(self: *Codegen, kind: VectorKind) a64.Error!void {
        const e = &self.e;
        try e.ldpQ(0, 1, R.sp, 0, .offset);
        try e.ldpQ(2, 3, R.sp, 32, .offset);
        switch (kind) {
            .and_ => {
                try e.and16b(0, 0, 2);
                try e.and16b(1, 1, 3);
            },
            .or_ => {
                try e.orr16b(0, 0, 2);
                try e.orr16b(1, 1, 3);
            },
            .xor => {
                try e.eor16b(0, 0, 2);
                try e.eor16b(1, 1, 3);
            },
        }
        try e.stpQ(0, 1, R.sp, 32, .pre);
    }

    /// Low 256 bits of a * b. a = x0..x3, b = x4..x7.
    fn mul256(self: *Codegen) a64.Error!void {
        const e = &self.e;
        const zr = a64.xzr;
        try self.loadTwo();
        // column 0
        try e.mul(8, 0, 4);
        try e.umulh(9, 0, 4);
        // column 1: x9 += lo(a1 b0) + lo(a0 b1); carries counted in x10
        try e.mul(12, 1, 4);
        try e.adds(9, 9, 12);
        try e.adc(10, zr, zr);
        try e.mul(12, 0, 5);
        try e.adds(9, 9, 12);
        try e.adc(10, 10, zr);
        // column 2: x10 += hi(a1 b0) + hi(a0 b1) + lo(a2 b0) + lo(a1 b1) + lo(a0 b2)
        const col2 = [_][3]a64.Reg{ .{ 1, 4, 1 }, .{ 0, 5, 1 }, .{ 2, 4, 0 }, .{ 1, 5, 0 }, .{ 0, 6, 0 } };
        for (col2, 0..) |term, k| {
            if (term[2] == 1) try e.umulh(12, term[0], term[1]) else try e.mul(12, term[0], term[1]);
            try e.adds(10, 10, 12);
            if (k == 0) try e.adc(11, zr, zr) else try e.adc(11, 11, zr);
        }
        // column 3 (mod 2^64): x11 += hi(a2 b0) + hi(a1 b1) + hi(a0 b2) + sum lo(ai bj), i+j=3
        const hi3 = [_][2]a64.Reg{ .{ 2, 4 }, .{ 1, 5 }, .{ 0, 6 } };
        for (hi3) |term| {
            try e.umulh(12, term[0], term[1]);
            try e.add(11, 11, 12);
        }
        const lo3 = [_][2]a64.Reg{ .{ 3, 4 }, .{ 2, 5 }, .{ 1, 6 }, .{ 0, 7 } };
        for (lo3) |term| try e.madd(11, term[0], term[1], 11);
        try self.storeBinary(8, 9, 10, 11);
    }

    fn callHelper(self: *Codegen, offset: u32) a64.Error!void {
        try self.e.ldr(R.call, R.helpers, offset);
        try self.e.blr(R.call);
    }

    /// Flushes stack pointer and gas, calls `helper(ctx[, arg])`, reloads,
    /// and exits on a nonzero return code.
    fn ctxHelper(self: *Codegen, offset: u32, arg: ?u16) a64.Error!void {
        const e = &self.e;
        try e.str(R.sp, R.ctx, ctxOffset("stack_ptr"));
        try e.str(R.gas, R.ctx, ctxOffset("gas_remaining"));
        try e.mov(0, R.ctx);
        if (arg) |value| try e.movzW(1, value);
        try self.callHelper(offset);
        try e.ldr(R.sp, R.ctx, ctxOffset("stack_ptr"));
        try e.ldr(R.gas, R.ctx, ctxOffset("gas_remaining"));
        try self.cbnzW(0, exit_helper_err);
    }

    /// Jumps to the 256-bit destination in x0..x3 through the jump table.
    fn dynamicJump(self: *Codegen) a64.Error!void {
        const e = &self.e;
        try e.orr(1, 1, 2);
        try e.orr(1, 1, 3);
        try self.cbnz(1, exit_invalid_jump);
        try self.cmpConst(0, self.code_len);
        try self.bcond(.hs, exit_invalid_jump);
        try self.fixup(jump_table, .adrp);
        try e.adrpPlaceholder(9);
        try e.addImm(9, 9, 0);
        try e.ldrswIndexed(10, 9, 0);
        try self.cbz(10, exit_invalid_jump);
        try e.add(9, 9, 10);
        try e.br(9);
    }

    /// x0 = OR of the four limbs at the top of stack; pops it.
    fn popTruth(self: *Codegen) a64.Error!void {
        const e = &self.e;
        try e.ldp(0, 1, R.sp, 0, .offset);
        try e.ldp(2, 3, R.sp, 16, .offset);
        try e.addImm(R.sp, R.sp, 32);
        try e.orr(0, 0, 1);
        try e.orr(2, 2, 3);
        try e.orr(0, 0, 2);
    }

    fn staticTarget(self: *Codegen, an: *const Analysis, block_labels: []const Label, target: u256) Label {
        if (target >= self.code_len) return exit_invalid_jump;
        const index = an.dest_block[@intCast(target)];
        if (index == Analysis.none) return exit_invalid_jump;
        return block_labels[index];
    }

    fn segmentGas(instrs: []const Instr, start: usize, last: usize) u64 {
        var total: u64 = 0;
        var i = start;
        while (i < last) : (i += 1) {
            total += instrs[i].info.gas;
            if (instrs[i].info.kind.endsSegment()) break;
        }
        return total;
    }

    fn emitBlock(self: *Codegen, an: *const Analysis, block_labels: []const Label, index: usize) a64.Error!void {
        const e = &self.e;
        const block = an.blocks.items[index];
        const instrs = an.instrs.items;
        self.bind(block_labels[index]);

        const count = block.last - block.first;
        if (count < 4096) {
            try e.subsImm(R.budget, R.budget, @intCast(count));
        } else {
            try e.movImm64(9, count);
            try e.subs(R.budget, R.budget, 9);
        }
        try self.bcond(.lo, exit_budget);

        try self.chargeGas(segmentGas(instrs, block.first, block.last));
        if (block.min_stack > 0) {
            try e.sub(9, R.base, R.sp);
            try self.cmpConst(9, @as(u64, block.min_stack) * 32);
            try self.bcond(.lo, exit_underflow);
        }
        if (block.max_growth > 0) {
            try e.sub(9, R.sp, R.limit);
            try self.cmpConst(9, @as(u64, block.max_growth) * 32);
            try self.bcond(.lo, exit_overflow);
        }

        var i: usize = block.first;
        while (i < block.last) : (i += 1) {
            if (i != block.first and instrs[i - 1].info.kind.endsSegment()) {
                try self.chargeGas(segmentGas(instrs, i, block.last));
            }
            const instr = instrs[i];
            switch (instr.info.kind) {
                .stop => try self.exitWith(.stop),
                .invalid => try self.b(exit_invalid_opcode),
                .jumpdest => {},
                .push => {
                    const next_kind = if (i + 1 < block.last) instrs[i + 1].info.kind else .stop;
                    if (next_kind == .jump) {
                        try self.b(self.staticTarget(an, block_labels, instr.imm));
                        i += 1;
                        continue;
                    }
                    if (next_kind == .jumpi) {
                        try self.popTruth();
                        try self.cbnz(0, self.staticTarget(an, block_labels, instr.imm));
                        i += 1;
                        continue;
                    }
                    try self.pushConst(instr.imm);
                },
                .pop => try e.addImm(R.sp, R.sp, 32),
                .dup => {
                    const n: i32 = instr.op - 0x7F;
                    try e.ldpQ(0, 1, R.sp, (n - 1) * 32, .offset);
                    try e.stpQ(0, 1, R.sp, -32, .pre);
                },
                .swap => {
                    const n: i32 = instr.op - 0x8F;
                    try e.ldpQ(0, 1, R.sp, 0, .offset);
                    try e.ldpQ(2, 3, R.sp, n * 32, .offset);
                    try e.stpQ(2, 3, R.sp, 0, .offset);
                    try e.stpQ(0, 1, R.sp, n * 32, .offset);
                },
                .add => {
                    try self.loadTwo();
                    try e.adds(0, 0, 4);
                    try e.adcs(1, 1, 5);
                    try e.adcs(2, 2, 6);
                    try e.adc(3, 3, 7);
                    try self.storeBinary(0, 1, 2, 3);
                },
                .sub => {
                    try self.loadTwo();
                    try e.subs(0, 0, 4);
                    try e.sbcs(1, 1, 5);
                    try e.sbcs(2, 2, 6);
                    try e.sbc(3, 3, 7);
                    try self.storeBinary(0, 1, 2, 3);
                },
                .mul => try self.mul256(),
                .lt => try self.compareOp(0, 4, .lo),
                .gt => try self.compareOp(4, 0, .lo),
                .slt => try self.compareOp(0, 4, .lt),
                .sgt => try self.compareOp(4, 0, .lt),
                .eq => {
                    try self.loadTwo();
                    try e.eor(0, 0, 4);
                    try e.eor(1, 1, 5);
                    try e.eor(2, 2, 6);
                    try e.eor(3, 3, 7);
                    try e.orr(0, 0, 1);
                    try e.orr(2, 2, 3);
                    try e.orr(0, 0, 2);
                    try e.cmpImm(0, 0);
                    try e.cset(0, .eq);
                    try self.storeBinary(0, a64.xzr, a64.xzr, a64.xzr);
                },
                .iszero => {
                    try e.ldp(0, 1, R.sp, 0, .offset);
                    try e.ldp(2, 3, R.sp, 16, .offset);
                    try e.orr(0, 0, 1);
                    try e.orr(2, 2, 3);
                    try e.orr(0, 0, 2);
                    try e.cmpImm(0, 0);
                    try e.cset(0, .eq);
                    try e.stp(0, a64.xzr, R.sp, 0, .offset);
                    try e.stp(a64.xzr, a64.xzr, R.sp, 16, .offset);
                },
                .and_ => try self.vectorOp(.and_),
                .or_ => try self.vectorOp(.or_),
                .xor => try self.vectorOp(.xor),
                .not => {
                    try e.ldpQ(0, 1, R.sp, 0, .offset);
                    try e.mvn16b(0, 0);
                    try e.mvn16b(1, 1);
                    try e.stpQ(0, 1, R.sp, 0, .offset);
                },
                .binary_helper => {
                    try e.mov(0, R.sp);
                    try e.addImm(1, R.sp, 32);
                    try e.mov(2, 1);
                    try self.callHelper(instr.info.helper);
                    try e.addImm(R.sp, R.sp, 32);
                },
                .ternary_helper => {
                    try e.mov(0, R.sp);
                    try e.addImm(1, R.sp, 32);
                    try e.addImm(2, R.sp, 64);
                    try e.mov(3, 2);
                    try self.callHelper(instr.info.helper);
                    try e.addImm(R.sp, R.sp, 64);
                },
                .unary_helper => {
                    try e.mov(0, R.sp);
                    try e.mov(1, R.sp);
                    try self.callHelper(instr.info.helper);
                },
                .exp, .keccak, .mload, .mstore, .mstore8, .mcopy => try self.ctxHelper(instr.info.helper, null),
                .calldataload => {
                    try e.str(R.sp, R.ctx, ctxOffset("stack_ptr"));
                    try e.mov(0, R.ctx);
                    try self.callHelper(instr.info.helper);
                },
                .calldatasize => {
                    try e.ldr(0, R.ctx, ctxOffset("calldata_len"));
                    try self.pushReg(0);
                },
                .msize => {
                    try e.ldr(0, R.ctx, ctxOffset("memory_len"));
                    try self.pushReg(0);
                },
                .gas => try self.pushReg(R.gas),
                .pc => try self.pushConst(instr.pc),
                .ret, .revert => {
                    const revert = instr.info.kind == .revert;
                    try self.ctxHelper(helperOffset("ret"), @intFromBool(revert));
                    try self.exitWith(if (revert) .revert else .return_ok);
                },
                .jump => {
                    try e.ldp(0, 1, R.sp, 0, .offset);
                    try e.ldp(2, 3, R.sp, 16, .offset);
                    try e.addImm(R.sp, R.sp, 32);
                    try self.dynamicJump();
                },
                .jumpi => {
                    const skip = try self.newLabel();
                    try self.loadTwo();
                    try e.addImm(R.sp, R.sp, 64);
                    try e.orr(4, 4, 5);
                    try e.orr(6, 6, 7);
                    try e.orr(4, 4, 6);
                    try self.cbz(4, skip);
                    try self.dynamicJump();
                    self.bind(skip);
                },
            }
        }
        if (block.falls_through and block.last == an.instrs.items.len) try self.exitWith(.stop);
    }
};

/// Emits all code, the jump table, and patches branches. Returns the size of
/// the native code in bytes (the jump table follows it).
fn generate(cg: *Codegen, an: *const Analysis, block_labels: []const Label, code_len: usize) a64.Error!usize {
    try cg.prologue();
    for (0..an.blocks.items.len) |index| try cg.emitBlock(an, block_labels, index);
    try cg.exits();
    const native_len = cg.e.offset();

    // Dense jump table: entry = block offset - table offset, 0 = not a JUMPDEST.
    cg.bind(Codegen.jump_table);
    const table_offset: i64 = cg.e.offset();
    const table_start = cg.e.words.items.len;
    try cg.e.words.appendNTimes(cg.allocator, 0, code_len);
    for (an.blocks.items, 0..) |block, index| {
        if (!block.is_dest) continue;
        const target: i64 = cg.labels.items[block_labels[index]].?;
        const rel: i32 = @intCast(target - table_offset);
        cg.e.words.items[table_start + block.entry_pc] = @bitCast(rel);
    }

    for (cg.fixups.items) |f| try cg.e.patch(f.at, cg.labels.items[f.label].?, f.kind);
    return native_len;
}

/// Compiles `code` to native code. Returns null when the target has no
/// native backend, the code is empty or larger than `max_code_size`, live
/// code uses an unsupported opcode, or native code exceeds branch ranges.
pub fn compile(allocator: std.mem.Allocator, code: []const u8, options: Options) CompileError!?Program {
    if (comptime !native_supported) return null;
    if (code.len == 0 or code.len > max_code_size) return null;

    var an: Analysis = .{};
    defer an.deinit(allocator);
    if (!try analyze(allocator, code, options, &an)) return null;

    var cg = Codegen{ .allocator = allocator, .e = Emitter.init(allocator), .code_len = @intCast(code.len) };
    defer cg.deinit();
    for (0..Codegen.fixed_labels) |_| _ = try cg.newLabel();
    const block_labels = try allocator.alloc(Label, an.blocks.items.len);
    defer allocator.free(block_labels);
    for (block_labels) |*label| label.* = try cg.newLabel();

    const native_len = generate(&cg, &an, block_labels, code.len) catch |err| switch (err) {
        error.BranchOutOfRange => return null,
        error.ImmediateOutOfRange => return error.ImmediateOutOfRange,
        error.OutOfMemory => return error.OutOfMemory,
    };

    var mem = try jit_mem.ExecMemory.create(cg.e.bytes());
    errdefer mem.deinit();
    return .{
        .mem = mem,
        .entry = @ptrFromInt(@intFromPtr(mem.ptr())),
        .uses_keccak = an.uses_keccak,
        .native_len = native_len,
        .replay_exceptional_halts = options.replay_exceptional_halts,
    };
}

test "analysis splits blocks and drops dead code" {
    const allocator = std.testing.allocator;
    // PUSH1 4 JUMP INVALID(dead SLOAD) JUMPDEST STOP
    const code = [_]u8{ 0x60, 0x04, 0x56, 0x54, 0x5B, 0x00 };
    var an: Analysis = .{};
    defer an.deinit(allocator);
    try std.testing.expect(try analyze(allocator, &code, .{}, &an));
    try std.testing.expectEqual(@as(usize, 2), an.blocks.items.len);
    try std.testing.expectEqual(@as(u32, 1), an.dest_block[4]);
    try std.testing.expectEqual(@as(u32, 1), an.blocks.items[0].max_growth);
}

test "analysis rejects live unsupported opcodes" {
    const allocator = std.testing.allocator;
    const code = [_]u8{ 0x60, 0x00, 0x54, 0x00 }; // PUSH1 0 SLOAD STOP
    var an: Analysis = .{};
    defer an.deinit(allocator);
    try std.testing.expect(!try analyze(allocator, &code, .{}, &an));
}

test "analysis stack bounds" {
    const allocator = std.testing.allocator;
    // DUP2 ADD POP PUSH1 1 PUSH1 2 STOP: needs 2, peaks +1
    const code = [_]u8{ 0x81, 0x01, 0x50, 0x60, 0x01, 0x60, 0x02, 0x00 };
    var an: Analysis = .{};
    defer an.deinit(allocator);
    try std.testing.expect(try analyze(allocator, &code, .{}, &an));
    try std.testing.expectEqual(@as(u32, 2), an.blocks.items[0].min_stack);
    try std.testing.expectEqual(@as(u32, 1), an.blocks.items[0].max_growth);
}
