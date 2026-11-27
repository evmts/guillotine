//! AArch64 (A64) instruction encoder.
//!
//! Every function appends one 32-bit little-endian instruction word unless
//! documented otherwise. Register 31 means XZR in data-processing register
//! forms and SP in add/sub immediate and load/store base forms, as in the
//! architecture manual. Encodings are checked against clang's assembler in
//! the tests below.

const std = @import("std");

pub const Reg = u5;
pub const xzr: Reg = 31;
pub const sp: Reg = 31;
pub const ip0: Reg = 16;
pub const ip1: Reg = 17;
pub const fp: Reg = 29;
pub const lr: Reg = 30;

pub const Cond = enum(u4) {
    eq = 0,
    ne = 1,
    hs = 2,
    lo = 3,
    mi = 4,
    pl = 5,
    vs = 6,
    vc = 7,
    hi = 8,
    ls = 9,
    ge = 10,
    lt = 11,
    gt = 12,
    le = 13,
    al = 14,

    pub fn invert(self: Cond) Cond {
        return @fromBackingInt(@intCast(@backingInt(self) ^ 1));
    }
};

pub const Error = error{ OutOfMemory, ImmediateOutOfRange, BranchOutOfRange };

/// Kinds of PC-relative instructions that can be patched after labels bind.
pub const FixupKind = enum { b26, imm19, adrp };

pub const Emitter = struct {
    words: std.ArrayList(u32) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Emitter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Emitter) void {
        self.words.deinit(self.allocator);
    }

    /// Current offset in bytes.
    pub fn offset(self: *const Emitter) u32 {
        return @intCast(self.words.items.len * 4);
    }

    pub fn emit(self: *Emitter, word: u32) Error!void {
        try self.words.append(self.allocator, word);
    }

    pub fn bytes(self: *const Emitter) []const u8 {
        return std.mem.sliceAsBytes(self.words.items);
    }

    // ---------------------------------------------------------------- moves

    pub fn movz(self: *Emitter, rd: Reg, imm: u16, hw: u2) Error!void {
        try self.emit(0xD2800000 | @as(u32, hw) << 21 | @as(u32, imm) << 5 | rd);
    }

    pub fn movk(self: *Emitter, rd: Reg, imm: u16, hw: u2) Error!void {
        try self.emit(0xF2800000 | @as(u32, hw) << 21 | @as(u32, imm) << 5 | rd);
    }

    pub fn movn(self: *Emitter, rd: Reg, imm: u16, hw: u2) Error!void {
        try self.emit(0x92800000 | @as(u32, hw) << 21 | @as(u32, imm) << 5 | rd);
    }

    /// 32-bit MOVZ (writes Wd, zeroes the upper half).
    pub fn movzW(self: *Emitter, rd: Reg, imm: u16) Error!void {
        try self.emit(0x52800000 | @as(u32, imm) << 5 | rd);
    }

    /// Loads any 64-bit constant in 1 to 4 instructions.
    pub fn movImm64(self: *Emitter, rd: Reg, value: u64) Error!void {
        var zeros: u32 = 0;
        var ones: u32 = 0;
        for (0..4) |i| {
            const half: u16 = @truncate(value >> @intCast(i * 16));
            if (half == 0) zeros += 1;
            if (half == 0xFFFF) ones += 1;
        }
        if (ones > zeros) {
            var first = true;
            for (0..4) |i| {
                const half: u16 = @truncate(value >> @intCast(i * 16));
                if (half == 0xFFFF) continue;
                if (first) {
                    try self.movn(rd, ~half, @intCast(i));
                    first = false;
                    continue;
                }
                try self.movk(rd, half, @intCast(i));
            }
            if (first) try self.movn(rd, 0, 0);
            return;
        }
        var first = true;
        for (0..4) |i| {
            const half: u16 = @truncate(value >> @intCast(i * 16));
            if (half == 0) continue;
            if (first) {
                try self.movz(rd, half, @intCast(i));
                first = false;
                continue;
            }
            try self.movk(rd, half, @intCast(i));
        }
        if (first) try self.movz(rd, 0, 0);
    }

    /// MOV Xd, Xm (ORR Xd, XZR, Xm). Not valid for SP.
    pub fn mov(self: *Emitter, rd: Reg, rm: Reg) Error!void {
        try self.orr(rd, xzr, rm);
    }

    /// MOV Xd|SP, Xn|SP (ADD #0).
    pub fn movSp(self: *Emitter, rd: Reg, rn: Reg) Error!void {
        try self.addImm(rd, rn, 0);
    }

    // ------------------------------------------------------------ arithmetic

    fn addSubImm(self: *Emitter, base: u32, rd: Reg, rn: Reg, imm: u32) Error!void {
        if (imm < 4096) {
            try self.emit(base | imm << 10 | @as(u32, rn) << 5 | rd);
            return;
        }
        if (imm & 0xFFF == 0 and imm >> 12 < 4096) {
            try self.emit(base | 1 << 22 | (imm >> 12) << 10 | @as(u32, rn) << 5 | rd);
            return;
        }
        return error.ImmediateOutOfRange;
    }

    pub fn addImm(self: *Emitter, rd: Reg, rn: Reg, imm: u32) Error!void {
        try self.addSubImm(0x91000000, rd, rn, imm);
    }
    pub fn subImm(self: *Emitter, rd: Reg, rn: Reg, imm: u32) Error!void {
        try self.addSubImm(0xD1000000, rd, rn, imm);
    }
    pub fn addsImm(self: *Emitter, rd: Reg, rn: Reg, imm: u32) Error!void {
        try self.addSubImm(0xB1000000, rd, rn, imm);
    }
    pub fn subsImm(self: *Emitter, rd: Reg, rn: Reg, imm: u32) Error!void {
        try self.addSubImm(0xF1000000, rd, rn, imm);
    }
    pub fn cmpImm(self: *Emitter, rn: Reg, imm: u32) Error!void {
        try self.subsImm(xzr, rn, imm);
    }

    fn rrr(self: *Emitter, base: u32, rd: Reg, rn: Reg, rm: Reg) Error!void {
        try self.emit(base | @as(u32, rm) << 16 | @as(u32, rn) << 5 | rd);
    }

    pub fn add(self: *Emitter, rd: Reg, rn: Reg, rm: Reg) Error!void {
        try self.rrr(0x8B000000, rd, rn, rm);
    }
    pub fn sub(self: *Emitter, rd: Reg, rn: Reg, rm: Reg) Error!void {
        try self.rrr(0xCB000000, rd, rn, rm);
    }
    pub fn adds(self: *Emitter, rd: Reg, rn: Reg, rm: Reg) Error!void {
        try self.rrr(0xAB000000, rd, rn, rm);
    }
    pub fn subs(self: *Emitter, rd: Reg, rn: Reg, rm: Reg) Error!void {
        try self.rrr(0xEB000000, rd, rn, rm);
    }
    pub fn cmp(self: *Emitter, rn: Reg, rm: Reg) Error!void {
        try self.subs(xzr, rn, rm);
    }
    pub fn adc(self: *Emitter, rd: Reg, rn: Reg, rm: Reg) Error!void {
        try self.rrr(0x9A000000, rd, rn, rm);
    }
    pub fn adcs(self: *Emitter, rd: Reg, rn: Reg, rm: Reg) Error!void {
        try self.rrr(0xBA000000, rd, rn, rm);
    }
    pub fn sbc(self: *Emitter, rd: Reg, rn: Reg, rm: Reg) Error!void {
        try self.rrr(0xDA000000, rd, rn, rm);
    }
    pub fn sbcs(self: *Emitter, rd: Reg, rn: Reg, rm: Reg) Error!void {
        try self.rrr(0xFA000000, rd, rn, rm);
    }
    /// MADD Xd, Xn, Xm, Xa: Xd = Xa + Xn * Xm.
    pub fn madd(self: *Emitter, rd: Reg, rn: Reg, rm: Reg, ra: Reg) Error!void {
        try self.emit(0x9B000000 | @as(u32, rm) << 16 | @as(u32, ra) << 10 | @as(u32, rn) << 5 | rd);
    }
    pub fn mul(self: *Emitter, rd: Reg, rn: Reg, rm: Reg) Error!void {
        try self.madd(rd, rn, rm, xzr);
    }
    pub fn umulh(self: *Emitter, rd: Reg, rn: Reg, rm: Reg) Error!void {
        try self.rrr(0x9BC07C00, rd, rn, rm);
    }

    // --------------------------------------------------------------- logical

    pub fn andReg(self: *Emitter, rd: Reg, rn: Reg, rm: Reg) Error!void {
        try self.rrr(0x8A000000, rd, rn, rm);
    }
    pub fn orr(self: *Emitter, rd: Reg, rn: Reg, rm: Reg) Error!void {
        try self.rrr(0xAA000000, rd, rn, rm);
    }
    pub fn eor(self: *Emitter, rd: Reg, rn: Reg, rm: Reg) Error!void {
        try self.rrr(0xCA000000, rd, rn, rm);
    }
    pub fn orn(self: *Emitter, rd: Reg, rn: Reg, rm: Reg) Error!void {
        try self.rrr(0xAA200000, rd, rn, rm);
    }
    pub fn tst(self: *Emitter, rn: Reg, rm: Reg) Error!void {
        try self.rrr(0xEA000000, xzr, rn, rm);
    }
    pub fn lslv(self: *Emitter, rd: Reg, rn: Reg, rm: Reg) Error!void {
        try self.rrr(0x9AC02000, rd, rn, rm);
    }
    pub fn lsrv(self: *Emitter, rd: Reg, rn: Reg, rm: Reg) Error!void {
        try self.rrr(0x9AC02400, rd, rn, rm);
    }
    /// LSL Xd, Xn, #shift (UBFM alias).
    pub fn lslImm(self: *Emitter, rd: Reg, rn: Reg, shift: u6) Error!void {
        const immr: u32 = (64 - @as(u32, shift)) & 63;
        const imms: u32 = 63 - @as(u32, shift);
        try self.emit(0xD3400000 | immr << 16 | imms << 10 | @as(u32, rn) << 5 | rd);
    }
    /// LSR Xd, Xn, #shift (UBFM alias).
    pub fn lsrImm(self: *Emitter, rd: Reg, rn: Reg, shift: u6) Error!void {
        try self.emit(0xD3400000 | @as(u32, shift) << 16 | 63 << 10 | @as(u32, rn) << 5 | rd);
    }
    pub fn csel(self: *Emitter, rd: Reg, rn: Reg, rm: Reg, cond: Cond) Error!void {
        try self.emit(0x9A800000 | @as(u32, rm) << 16 | @as(u32, @backingInt(cond)) << 12 | @as(u32, rn) << 5 | rd);
    }
    /// CSET Xd, cond (CSINC Xd, XZR, XZR, !cond).
    pub fn cset(self: *Emitter, rd: Reg, cond: Cond) Error!void {
        try self.emit(0x9A800400 | @as(u32, xzr) << 16 | @as(u32, @backingInt(cond.invert())) << 12 | @as(u32, xzr) << 5 | rd);
    }

    // ---------------------------------------------------------- load / store

    fn ldst64(self: *Emitter, base: u32, rt: Reg, rn: Reg, off: u32) Error!void {
        if (off % 8 != 0 or off / 8 >= 4096) return error.ImmediateOutOfRange;
        try self.emit(base | (off / 8) << 10 | @as(u32, rn) << 5 | rt);
    }
    pub fn ldr(self: *Emitter, rt: Reg, rn: Reg, off: u32) Error!void {
        try self.ldst64(0xF9400000, rt, rn, off);
    }
    pub fn str(self: *Emitter, rt: Reg, rn: Reg, off: u32) Error!void {
        try self.ldst64(0xF9000000, rt, rn, off);
    }
    pub fn strW(self: *Emitter, rt: Reg, rn: Reg, off: u32) Error!void {
        if (off % 4 != 0 or off / 4 >= 4096) return error.ImmediateOutOfRange;
        try self.emit(0xB9000000 | (off / 4) << 10 | @as(u32, rn) << 5 | rt);
    }
    pub fn ldrW(self: *Emitter, rt: Reg, rn: Reg, off: u32) Error!void {
        if (off % 4 != 0 or off / 4 >= 4096) return error.ImmediateOutOfRange;
        try self.emit(0xB9400000 | (off / 4) << 10 | @as(u32, rn) << 5 | rt);
    }
    /// LDRSW Xt, [Xn, Xm, LSL #2]
    pub fn ldrswIndexed(self: *Emitter, rt: Reg, rn: Reg, rm: Reg) Error!void {
        try self.emit(0xB8A07800 | @as(u32, rm) << 16 | @as(u32, rn) << 5 | rt);
    }

    pub const Index = enum { offset, pre, post };

    fn pair(self: *Emitter, opc: u32, rt: Reg, rt2: Reg, rn: Reg, off: i32, scale: i32, index: Index) Error!void {
        if (@rem(off, scale) != 0) return error.ImmediateOutOfRange;
        const scaled = @divExact(off, scale);
        if (scaled < -64 or scaled > 63) return error.ImmediateOutOfRange;
        const mode: u32 = switch (index) {
            .post => 0x00800000,
            .offset => 0x01000000,
            .pre => 0x01800000,
        };
        const imm7: u32 = @as(u32, @bitCast(scaled)) & 0x7F;
        try self.emit(opc | mode | imm7 << 15 | @as(u32, rt2) << 10 | @as(u32, rn) << 5 | rt);
    }
    pub fn stp(self: *Emitter, rt: Reg, rt2: Reg, rn: Reg, off: i32, index: Index) Error!void {
        try self.pair(0xA8000000, rt, rt2, rn, off, 8, index);
    }
    pub fn ldp(self: *Emitter, rt: Reg, rt2: Reg, rn: Reg, off: i32, index: Index) Error!void {
        try self.pair(0xA8400000, rt, rt2, rn, off, 8, index);
    }
    /// STP Qt, Qt2 (128-bit SIMD registers).
    pub fn stpQ(self: *Emitter, rt: Reg, rt2: Reg, rn: Reg, off: i32, index: Index) Error!void {
        try self.pair(0xAC000000, rt, rt2, rn, off, 16, index);
    }
    pub fn ldpQ(self: *Emitter, rt: Reg, rt2: Reg, rn: Reg, off: i32, index: Index) Error!void {
        try self.pair(0xAC400000, rt, rt2, rn, off, 16, index);
    }
    pub fn ldrQ(self: *Emitter, rt: Reg, rn: Reg, off: u32) Error!void {
        if (off % 16 != 0 or off / 16 >= 4096) return error.ImmediateOutOfRange;
        try self.emit(0x3DC00000 | (off / 16) << 10 | @as(u32, rn) << 5 | rt);
    }
    pub fn strQ(self: *Emitter, rt: Reg, rn: Reg, off: u32) Error!void {
        if (off % 16 != 0 or off / 16 >= 4096) return error.ImmediateOutOfRange;
        try self.emit(0x3D800000 | (off / 16) << 10 | @as(u32, rn) << 5 | rt);
    }

    // ------------------------------------------------------------------ NEON

    pub fn and16b(self: *Emitter, vd: Reg, vn: Reg, vm: Reg) Error!void {
        try self.rrr(0x4E201C00, vd, vn, vm);
    }
    pub fn orr16b(self: *Emitter, vd: Reg, vn: Reg, vm: Reg) Error!void {
        try self.rrr(0x4EA01C00, vd, vn, vm);
    }
    pub fn eor16b(self: *Emitter, vd: Reg, vn: Reg, vm: Reg) Error!void {
        try self.rrr(0x6E201C00, vd, vn, vm);
    }
    pub fn mvn16b(self: *Emitter, vd: Reg, vn: Reg) Error!void {
        try self.emit(0x6E205800 | @as(u32, vn) << 5 | vd);
    }
    pub fn cmeq16b(self: *Emitter, vd: Reg, vn: Reg, vm: Reg) Error!void {
        try self.rrr(0x6E208C00, vd, vn, vm);
    }

    // -------------------------------------------------------------- branches

    pub fn br(self: *Emitter, rn: Reg) Error!void {
        try self.emit(0xD61F0000 | @as(u32, rn) << 5);
    }
    pub fn blr(self: *Emitter, rn: Reg) Error!void {
        try self.emit(0xD63F0000 | @as(u32, rn) << 5);
    }
    pub fn ret(self: *Emitter) Error!void {
        try self.emit(0xD65F03C0);
    }
    /// Unpatched branch words; `patch` fills in the displacement.
    pub fn bPlaceholder(self: *Emitter) Error!void {
        try self.emit(0x14000000);
    }
    pub fn blPlaceholder(self: *Emitter) Error!void {
        try self.emit(0x94000000);
    }
    pub fn bcondPlaceholder(self: *Emitter, cond: Cond) Error!void {
        try self.emit(0x54000000 | @as(u32, @backingInt(cond)));
    }
    pub fn cbzPlaceholder(self: *Emitter, rt: Reg) Error!void {
        try self.emit(0xB4000000 | @as(u32, rt));
    }
    pub fn cbnzPlaceholder(self: *Emitter, rt: Reg) Error!void {
        try self.emit(0xB5000000 | @as(u32, rt));
    }
    /// 32-bit CBNZ Wt.
    pub fn cbnzWPlaceholder(self: *Emitter, rt: Reg) Error!void {
        try self.emit(0x35000000 | @as(u32, rt));
    }
    pub fn adrpPlaceholder(self: *Emitter, rd: Reg) Error!void {
        try self.emit(0x90000000 | @as(u32, rd));
    }

    /// Patches the PC-relative field of the instruction at byte offset `at`
    /// so that it refers to byte offset `target`. For `.adrp`, the following
    /// instruction must be an ADD (immediate) that receives the low 12 bits.
    /// Offsets are relative to a 4 KiB aligned base.
    pub fn patch(self: *Emitter, at: u32, target: u32, kind: FixupKind) Error!void {
        const index = at / 4;
        const delta: i64 = @as(i64, target) - @as(i64, at);
        switch (kind) {
            .b26 => {
                const disp = @divExact(delta, 4);
                if (disp < -(1 << 25) or disp >= (1 << 25)) return error.BranchOutOfRange;
                const field: u32 = @as(u32, @truncate(@as(u64, @bitCast(disp)))) & 0x03FFFFFF;
                self.words.items[index] |= field;
            },
            .imm19 => {
                const disp = @divExact(delta, 4);
                if (disp < -(1 << 18) or disp >= (1 << 18)) return error.BranchOutOfRange;
                const field: u32 = @as(u32, @truncate(@as(u64, @bitCast(disp)))) & 0x7FFFF;
                self.words.items[index] |= field << 5;
            },
            .adrp => {
                const pages: i64 = @as(i64, target >> 12) - @as(i64, at >> 12);
                if (pages < -(1 << 20) or pages >= (1 << 20)) return error.BranchOutOfRange;
                const p: u32 = @as(u32, @truncate(@as(u64, @bitCast(pages)))) & 0x1FFFFF;
                self.words.items[index] |= (p & 3) << 29 | (p >> 2) << 5;
                self.words.items[index + 1] |= (target & 0xFFF) << 10;
            },
        }
    }
};

// Each expected word below was produced by `clang -c -target arm64-apple-macos`
// from the instruction text in the comment.
test "arm64 encodings match clang" {
    const allocator = std.testing.allocator;
    var e = Emitter.init(allocator);
    defer e.deinit();
    const Case = struct { word: u32, text: []const u8 };
    var expected: std.ArrayList(Case) = .empty;
    defer expected.deinit(allocator);

    try e.movz(0, 0x1234, 1);
    try expected.append(allocator, .{ .word = 0xD2A24680, .text = "movz x0, #0x1234, lsl #16" });
    try e.movk(3, 0xBEEF, 3);
    try expected.append(allocator, .{ .word = 0xF2F7DDE3, .text = "movk x3, #0xbeef, lsl #48" });
    try e.movn(5, 0, 0);
    try expected.append(allocator, .{ .word = 0x92800005, .text = "movn x5, #0" });
    try e.movzW(0, 3);
    try expected.append(allocator, .{ .word = 0x52800060, .text = "movz w0, #3" });
    try e.addImm(20, 20, 32);
    try expected.append(allocator, .{ .word = 0x91008294, .text = "add x20, x20, #32" });
    try e.subImm(20, 20, 64);
    try expected.append(allocator, .{ .word = 0xD1010294, .text = "sub x20, x20, #64" });
    try e.subsImm(21, 21, 4095);
    try expected.append(allocator, .{ .word = 0xF13FFEB5, .text = "subs x21, x21, #4095" });
    try e.subsImm(21, 21, 0x5000);
    try expected.append(allocator, .{ .word = 0xF14016B5, .text = "subs x21, x21, #5, lsl #12" });
    try e.cmpImm(9, 96);
    try expected.append(allocator, .{ .word = 0xF101813F, .text = "cmp x9, #96" });
    try e.movSp(fp, sp);
    try expected.append(allocator, .{ .word = 0x910003FD, .text = "mov x29, sp" });
    try e.add(9, 9, 10);
    try expected.append(allocator, .{ .word = 0x8B0A0129, .text = "add x9, x9, x10" });
    try e.sub(9, 22, 20);
    try expected.append(allocator, .{ .word = 0xCB1402C9, .text = "sub x9, x22, x20" });
    try e.adds(0, 0, 4);
    try expected.append(allocator, .{ .word = 0xAB040000, .text = "adds x0, x0, x4" });
    try e.adcs(1, 1, 5);
    try expected.append(allocator, .{ .word = 0xBA050021, .text = "adcs x1, x1, x5" });
    try e.adc(3, 3, 7);
    try expected.append(allocator, .{ .word = 0x9A070063, .text = "adc x3, x3, x7" });
    try e.subs(0, 0, 4);
    try expected.append(allocator, .{ .word = 0xEB040000, .text = "subs x0, x0, x4" });
    try e.sbcs(xzr, 1, 5);
    try expected.append(allocator, .{ .word = 0xFA05003F, .text = "sbcs xzr, x1, x5" });
    try e.sbc(3, 3, 7);
    try expected.append(allocator, .{ .word = 0xDA070063, .text = "sbc x3, x3, x7" });
    try e.cmp(0, 4);
    try expected.append(allocator, .{ .word = 0xEB04001F, .text = "cmp x0, x4" });
    try e.mul(8, 0, 4);
    try expected.append(allocator, .{ .word = 0x9B047C08, .text = "mul x8, x0, x4" });
    try e.umulh(9, 0, 4);
    try expected.append(allocator, .{ .word = 0x9BC47C09, .text = "umulh x9, x0, x4" });
    try e.madd(11, 3, 4, 11);
    try expected.append(allocator, .{ .word = 0x9B042C6B, .text = "madd x11, x3, x4, x11" });
    try e.andReg(0, 1, 2);
    try expected.append(allocator, .{ .word = 0x8A020020, .text = "and x0, x1, x2" });
    try e.orr(0, 0, 1);
    try expected.append(allocator, .{ .word = 0xAA010000, .text = "orr x0, x0, x1" });
    try e.eor(0, 0, 4);
    try expected.append(allocator, .{ .word = 0xCA040000, .text = "eor x0, x0, x4" });
    try e.orn(0, 1, 2);
    try expected.append(allocator, .{ .word = 0xAA220020, .text = "orn x0, x1, x2" });
    try e.tst(0, 1);
    try expected.append(allocator, .{ .word = 0xEA01001F, .text = "tst x0, x1" });
    try e.mov(0, 20);
    try expected.append(allocator, .{ .word = 0xAA1403E0, .text = "mov x0, x20" });
    try e.lslv(0, 1, 2);
    try expected.append(allocator, .{ .word = 0x9AC22020, .text = "lsl x0, x1, x2" });
    try e.lsrv(0, 1, 2);
    try expected.append(allocator, .{ .word = 0x9AC22420, .text = "lsr x0, x1, x2" });
    try e.lslImm(0, 1, 5);
    try expected.append(allocator, .{ .word = 0xD37BE820, .text = "lsl x0, x1, #5" });
    try e.lsrImm(0, 1, 5);
    try expected.append(allocator, .{ .word = 0xD345FC20, .text = "lsr x0, x1, #5" });
    try e.csel(0, 1, 2, .ne);
    try expected.append(allocator, .{ .word = 0x9A821020, .text = "csel x0, x1, x2, ne" });
    try e.cset(0, .eq);
    try expected.append(allocator, .{ .word = 0x9A9F17E0, .text = "cset x0, eq" });
    try e.cset(0, .lo);
    try expected.append(allocator, .{ .word = 0x9A9F27E0, .text = "cset x0, lo" });
    try e.ldr(20, 19, 0);
    try expected.append(allocator, .{ .word = 0xF9400274, .text = "ldr x20, [x19]" });
    try e.str(21, 19, 24);
    try expected.append(allocator, .{ .word = 0xF9000E75, .text = "str x21, [x19, #24]" });
    try e.strW(0, 19, 96);
    try expected.append(allocator, .{ .word = 0xB9006260, .text = "str w0, [x19, #96]" });
    try e.ldrW(0, 19, 96);
    try expected.append(allocator, .{ .word = 0xB9406260, .text = "ldr w0, [x19, #96]" });
    try e.ldrswIndexed(10, 9, 0);
    try expected.append(allocator, .{ .word = 0xB8A0792A, .text = "ldrsw x10, [x9, x0, lsl #2]" });
    try e.stp(fp, lr, sp, -64, .pre);
    try expected.append(allocator, .{ .word = 0xA9BC7BFD, .text = "stp x29, x30, [sp, #-64]!" });
    try e.ldp(fp, lr, sp, 64, .post);
    try expected.append(allocator, .{ .word = 0xA8C47BFD, .text = "ldp x29, x30, [sp], #64" });
    try e.stp(19, 20, sp, 16, .offset);
    try expected.append(allocator, .{ .word = 0xA90153F3, .text = "stp x19, x20, [sp, #16]" });
    try e.ldp(2, 3, 20, 16, .offset);
    try expected.append(allocator, .{ .word = 0xA9410E82, .text = "ldp x2, x3, [x20, #16]" });
    try e.stp(0, xzr, 20, -32, .pre);
    try expected.append(allocator, .{ .word = 0xA9BE7E80, .text = "stp x0, xzr, [x20, #-32]!" });
    try e.ldpQ(0, 1, 20, 480, .offset);
    try expected.append(allocator, .{ .word = 0xAD4F0680, .text = "ldp q0, q1, [x20, #480]" });
    try e.stpQ(0, 1, 20, -32, .pre);
    try expected.append(allocator, .{ .word = 0xADBF0680, .text = "stp q0, q1, [x20, #-32]!" });
    try e.stpQ(2, 3, 20, 512, .offset);
    try expected.append(allocator, .{ .word = 0xAD100E82, .text = "stp q2, q3, [x20, #512]" });
    try e.ldrQ(0, 20, 32);
    try expected.append(allocator, .{ .word = 0x3DC00A80, .text = "ldr q0, [x20, #32]" });
    try e.strQ(0, 20, 32);
    try expected.append(allocator, .{ .word = 0x3D800A80, .text = "str q0, [x20, #32]" });
    try e.and16b(0, 0, 2);
    try expected.append(allocator, .{ .word = 0x4E221C00, .text = "and v0.16b, v0.16b, v2.16b" });
    try e.orr16b(1, 1, 3);
    try expected.append(allocator, .{ .word = 0x4EA31C21, .text = "orr v1.16b, v1.16b, v3.16b" });
    try e.eor16b(0, 0, 2);
    try expected.append(allocator, .{ .word = 0x6E221C00, .text = "eor v0.16b, v0.16b, v2.16b" });
    try e.mvn16b(0, 0);
    try expected.append(allocator, .{ .word = 0x6E205800, .text = "mvn v0.16b, v0.16b" });
    try e.cmeq16b(0, 0, 2);
    try expected.append(allocator, .{ .word = 0x6E228C00, .text = "cmeq v0.16b, v0.16b, v2.16b" });
    try e.br(9);
    try expected.append(allocator, .{ .word = 0xD61F0120, .text = "br x9" });
    try e.blr(16);
    try expected.append(allocator, .{ .word = 0xD63F0200, .text = "blr x16" });
    try e.ret();
    try expected.append(allocator, .{ .word = 0xD65F03C0, .text = "ret" });

    try std.testing.expectEqual(expected.items.len, e.words.items.len);
    for (expected.items, e.words.items) |want, got| {
        if (want.word != got) {
            std.log.err("{s}: want 0x{X:0>8} got 0x{X:0>8}", .{ want.text, want.word, got });
            return error.TestUnexpectedResult;
        }
    }
}

test "arm64 branch patching" {
    var e = Emitter.init(std.testing.allocator);
    defer e.deinit();
    try e.bPlaceholder(); // 0
    try e.bcondPlaceholder(.lt); // 4
    try e.cbnzPlaceholder(1); // 8
    try e.cbnzWPlaceholder(0); // 12
    try e.adrpPlaceholder(9); // 16
    try e.addImm(9, 9, 0); // 20
    try e.patch(0, 16, .b26);
    try e.patch(4, 0, .imm19);
    try e.patch(8, 24, .imm19);
    try e.patch(12, 4, .imm19);
    try e.patch(16, 0x1234 + 0x3000, .adrp);
    // b #16 ; b.lt #-4 ; cbnz x1, #16 ; cbnz w0, #-8 ; adrp x9, 4 pages ; add x9, x9, #0x234
    try std.testing.expectEqual(@as(u32, 0x14000004), e.words.items[0]);
    try std.testing.expectEqual(@as(u32, 0x54FFFFEB), e.words.items[1]);
    try std.testing.expectEqual(@as(u32, 0xB5000081), e.words.items[2]);
    try std.testing.expectEqual(@as(u32, 0x35FFFFC0), e.words.items[3]);
    try std.testing.expectEqual(@as(u32, 0x90000029), e.words.items[4]);
    try std.testing.expectEqual(@as(u32, 0x9108D129), e.words.items[5]);
}

test "arm64 movImm64 picks short sequences" {
    var e = Emitter.init(std.testing.allocator);
    defer e.deinit();
    try e.movImm64(0, 0);
    try std.testing.expectEqual(@as(usize, 1), e.words.items.len);
    try e.movImm64(0, 0xFFFF_FFFF_FFFF_FFFE);
    try std.testing.expectEqual(@as(usize, 2), e.words.items.len);
    try std.testing.expectEqual(@as(u32, 0x92800020), e.words.items[1]); // movn x0, #1
    try e.movImm64(0, 0x1234_0000_5678_9ABC);
    try std.testing.expectEqual(@as(usize, 5), e.words.items.len);
}

test "arm64 rejects out-of-range immediates" {
    var e = Emitter.init(std.testing.allocator);
    defer e.deinit();
    try std.testing.expectError(error.ImmediateOutOfRange, e.addImm(0, 0, 4097));
    try std.testing.expectError(error.ImmediateOutOfRange, e.ldpQ(0, 1, 20, 1024, .offset));
    try std.testing.expectError(error.ImmediateOutOfRange, e.ldr(0, 19, 3));
}
