//! x86-64 instruction encoder.
//!
//! Covers the instruction subset a 256-bit limb backend needs: 64-bit moves,
//! loads and stores with base+disp32 addressing, add/adc/sub/sbb/and/or/xor/
//! cmp, mul, setcc, push/pop, jumps, calls, and 128-bit SSE loads/stores.
//! The compiler does not yet generate x86-64 code: `compiler.compile`
//! returns null on x86-64 so the host falls back to the interpreter.
//! Encodings are checked against clang's assembler in the tests below.

const std = @import("std");

pub const Reg = enum(u4) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,

    fn low(self: Reg) u8 {
        return @backingInt(self) & 7;
    }

    fn ext(self: Reg) u8 {
        return @backingInt(self) >> 3;
    }
};

/// XMM registers 0-15.
pub const Xmm = u4;

pub const Cond = enum(u4) {
    o = 0,
    no = 1,
    b = 2,
    ae = 3,
    e = 4,
    ne = 5,
    be = 6,
    a = 7,
    s = 8,
    ns = 9,
    l = 12,
    ge = 13,
    le = 14,
    g = 15,
};

/// Two-operand ALU operations: the /digit for the 0x81 group and the opcode
/// for the `reg, r/m` form.
pub const Alu = enum(u8) {
    add = 0,
    @"or" = 1,
    adc = 2,
    sbb = 3,
    @"and" = 4,
    sub = 5,
    xor = 6,
    cmp = 7,

    fn rmFromReg(self: Alu) u8 {
        return @backingInt(self) * 8 + 1;
    }
};

pub const Error = error{ OutOfMemory, BranchOutOfRange };

pub const Emitter = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Emitter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Emitter) void {
        self.buf.deinit(self.allocator);
    }

    pub fn offset(self: *const Emitter) u32 {
        return @intCast(self.buf.items.len);
    }

    pub fn bytes(self: *const Emitter) []const u8 {
        return self.buf.items;
    }

    fn byte(self: *Emitter, b: u8) Error!void {
        try self.buf.append(self.allocator, b);
    }

    fn imm32(self: *Emitter, value: i32) Error!void {
        var raw: [4]u8 = undefined;
        std.mem.writeInt(i32, &raw, value, .little);
        try self.buf.appendSlice(self.allocator, &raw);
    }

    fn rex(self: *Emitter, w: bool, reg: u8, index: u8, base: u8) Error!void {
        try self.byte(0x40 | @as(u8, @intFromBool(w)) << 3 | (reg & 1) << 2 | (index & 1) << 1 | (base & 1));
    }

    fn modrmReg(self: *Emitter, reg: u8, rm: u8) Error!void {
        try self.byte(0xC0 | (reg & 7) << 3 | (rm & 7));
    }

    /// ModRM (+SIB) (+disp) for [base + disp]. `reg` is the 3-bit field.
    fn modrmMem(self: *Emitter, reg: u8, base: Reg, disp: i32) Error!void {
        const r = (reg & 7) << 3;
        const needs_sib = base.low() == 4;
        const fits8 = disp >= -128 and disp <= 127;
        const mode: u8 = if (disp == 0 and base.low() != 5) 0x00 else if (fits8) 0x40 else 0x80;
        try self.byte(mode | r | (if (needs_sib) @as(u8, 4) else base.low()));
        if (needs_sib) try self.byte(0x24);
        switch (mode) {
            0x40 => try self.byte(@bitCast(@as(i8, @intCast(disp)))),
            0x80 => try self.imm32(disp),
            else => {},
        }
    }

    /// MOV dst, src (64-bit).
    pub fn movRR(self: *Emitter, dst: Reg, src: Reg) Error!void {
        try self.rex(true, src.ext(), 0, dst.ext());
        try self.byte(0x89);
        try self.modrmReg(src.low(), dst.low());
    }

    /// MOV dst, imm64 (shortest form: mov r32, imm32 / mov r64, simm32 / movabs).
    pub fn movImm(self: *Emitter, dst: Reg, value: u64) Error!void {
        if (value <= std.math.maxInt(u32)) {
            if (dst.ext() != 0) try self.rex(false, 0, 0, 1);
            try self.byte(0xB8 + dst.low());
            try self.imm32(@bitCast(@as(u32, @intCast(value))));
            return;
        }
        const signed: i64 = @bitCast(value);
        if (signed >= std.math.minInt(i32) and signed <= std.math.maxInt(i32)) {
            try self.rex(true, 0, 0, dst.ext());
            try self.byte(0xC7);
            try self.modrmReg(0, dst.low());
            try self.imm32(@intCast(signed));
            return;
        }
        try self.rex(true, 0, 0, dst.ext());
        try self.byte(0xB8 + dst.low());
        var raw: [8]u8 = undefined;
        std.mem.writeInt(u64, &raw, value, .little);
        try self.buf.appendSlice(self.allocator, &raw);
    }

    /// MOV dst, [base + disp].
    pub fn load(self: *Emitter, dst: Reg, base: Reg, disp: i32) Error!void {
        try self.rex(true, dst.ext(), 0, base.ext());
        try self.byte(0x8B);
        try self.modrmMem(dst.low(), base, disp);
    }

    /// MOV [base + disp], src.
    pub fn store(self: *Emitter, base: Reg, disp: i32, src: Reg) Error!void {
        try self.rex(true, src.ext(), 0, base.ext());
        try self.byte(0x89);
        try self.modrmMem(src.low(), base, disp);
    }

    /// LEA dst, [base + disp].
    pub fn lea(self: *Emitter, dst: Reg, base: Reg, disp: i32) Error!void {
        try self.rex(true, dst.ext(), 0, base.ext());
        try self.byte(0x8D);
        try self.modrmMem(dst.low(), base, disp);
    }

    /// op dst, src (64-bit register form).
    pub fn aluRR(self: *Emitter, op: Alu, dst: Reg, src: Reg) Error!void {
        try self.rex(true, src.ext(), 0, dst.ext());
        try self.byte(op.rmFromReg());
        try self.modrmReg(src.low(), dst.low());
    }

    /// op dst, [base + disp].
    pub fn aluRM(self: *Emitter, op: Alu, dst: Reg, base: Reg, disp: i32) Error!void {
        try self.rex(true, dst.ext(), 0, base.ext());
        try self.byte(op.rmFromReg() + 2);
        try self.modrmMem(dst.low(), base, disp);
    }

    /// op dst, simm32.
    pub fn aluRI(self: *Emitter, op: Alu, dst: Reg, value: i32) Error!void {
        try self.rex(true, 0, 0, dst.ext());
        if (value >= -128 and value <= 127) {
            try self.byte(0x83);
            try self.modrmReg(@backingInt(op), dst.low());
            try self.byte(@bitCast(@as(i8, @intCast(value))));
            return;
        }
        try self.byte(0x81);
        try self.modrmReg(@backingInt(op), dst.low());
        try self.imm32(value);
    }

    /// MUL src: rdx:rax = rax * src (unsigned).
    pub fn mul(self: *Emitter, src: Reg) Error!void {
        try self.rex(true, 0, 0, src.ext());
        try self.byte(0xF7);
        try self.modrmReg(4, src.low());
    }

    /// IMUL dst, src (low 64 bits).
    pub fn imulRR(self: *Emitter, dst: Reg, src: Reg) Error!void {
        try self.rex(true, dst.ext(), 0, src.ext());
        try self.byte(0x0F);
        try self.byte(0xAF);
        try self.modrmReg(dst.low(), src.low());
    }

    /// NOT dst.
    pub fn not(self: *Emitter, dst: Reg) Error!void {
        try self.rex(true, 0, 0, dst.ext());
        try self.byte(0xF7);
        try self.modrmReg(2, dst.low());
    }

    /// SETcc dst8 (always emits REX so low bytes of rsi/rdi/r8+ are addressable).
    pub fn setcc(self: *Emitter, cond: Cond, dst: Reg) Error!void {
        try self.rex(false, 0, 0, dst.ext());
        try self.byte(0x0F);
        try self.byte(0x90 | @as(u8, @backingInt(cond)));
        try self.modrmReg(0, dst.low());
    }

    /// MOVZX dst, dst8.
    pub fn movzxByte(self: *Emitter, dst: Reg, src: Reg) Error!void {
        try self.rex(true, dst.ext(), 0, src.ext());
        try self.byte(0x0F);
        try self.byte(0xB6);
        try self.modrmReg(dst.low(), src.low());
    }

    pub fn push(self: *Emitter, reg: Reg) Error!void {
        if (reg.ext() != 0) try self.rex(false, 0, 0, 1);
        try self.byte(0x50 + reg.low());
    }

    pub fn pop(self: *Emitter, reg: Reg) Error!void {
        if (reg.ext() != 0) try self.rex(false, 0, 0, 1);
        try self.byte(0x58 + reg.low());
    }

    pub fn ret(self: *Emitter) Error!void {
        try self.byte(0xC3);
    }

    /// CALL [base + disp].
    pub fn callMem(self: *Emitter, base: Reg, disp: i32) Error!void {
        if (base.ext() != 0) try self.rex(false, 0, 0, 1);
        try self.byte(0xFF);
        try self.modrmMem(2, base, disp);
    }

    /// JMP reg.
    pub fn jmpReg(self: *Emitter, reg: Reg) Error!void {
        if (reg.ext() != 0) try self.rex(false, 0, 0, 1);
        try self.byte(0xFF);
        try self.modrmReg(4, reg.low());
    }

    /// JMP rel32 placeholder; returns the offset of the rel32 field.
    pub fn jmpPlaceholder(self: *Emitter) Error!u32 {
        try self.byte(0xE9);
        const at = self.offset();
        try self.imm32(0);
        return at;
    }

    /// Jcc rel32 placeholder; returns the offset of the rel32 field.
    pub fn jccPlaceholder(self: *Emitter, cond: Cond) Error!u32 {
        try self.byte(0x0F);
        try self.byte(0x80 | @as(u8, @backingInt(cond)));
        const at = self.offset();
        try self.imm32(0);
        return at;
    }

    /// Points the rel32 field at `at` to byte offset `target`.
    pub fn patchRel32(self: *Emitter, at: u32, target: u32) Error!void {
        const delta: i64 = @as(i64, target) - (@as(i64, at) + 4);
        if (delta < std.math.minInt(i32) or delta > std.math.maxInt(i32)) return error.BranchOutOfRange;
        std.mem.writeInt(i32, self.buf.items[at..][0..4], @intCast(delta), .little);
    }

    /// MOVDQU xmm, [base + disp].
    pub fn movdquLoad(self: *Emitter, dst: Xmm, base: Reg, disp: i32) Error!void {
        try self.byte(0xF3);
        if (dst >> 3 != 0 or base.ext() != 0) try self.rex(false, dst >> 3, 0, base.ext());
        try self.byte(0x0F);
        try self.byte(0x6F);
        try self.modrmMem(dst & 7, base, disp);
    }

    /// MOVDQU [base + disp], xmm.
    pub fn movdquStore(self: *Emitter, base: Reg, disp: i32, src: Xmm) Error!void {
        try self.byte(0xF3);
        if (src >> 3 != 0 or base.ext() != 0) try self.rex(false, src >> 3, 0, base.ext());
        try self.byte(0x0F);
        try self.byte(0x7F);
        try self.modrmMem(src & 7, base, disp);
    }

    fn sse(self: *Emitter, op: u8, dst: Xmm, src: Xmm) Error!void {
        try self.byte(0x66);
        if (dst >> 3 != 0 or src >> 3 != 0) try self.rex(false, dst >> 3, 0, src >> 3);
        try self.byte(0x0F);
        try self.byte(op);
        try self.modrmReg(dst & 7, src & 7);
    }

    pub fn pand(self: *Emitter, dst: Xmm, src: Xmm) Error!void {
        try self.sse(0xDB, dst, src);
    }
    pub fn por(self: *Emitter, dst: Xmm, src: Xmm) Error!void {
        try self.sse(0xEB, dst, src);
    }
    pub fn pxor(self: *Emitter, dst: Xmm, src: Xmm) Error!void {
        try self.sse(0xEF, dst, src);
    }
};

// Each expected byte string was produced by `clang -c -target x86_64-apple-macos`
// from the instruction text in the comment.
test "x86_64 encodings match clang" {
    const allocator = std.testing.allocator;
    const Case = struct { text: []const u8, want: []const u8 };
    var e = Emitter.init(allocator);
    defer e.deinit();
    var cases: std.ArrayList(Case) = .empty;
    defer cases.deinit(allocator);
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(allocator);

    const Step = struct {
        fn mark(list: *std.ArrayList(usize), alloc: std.mem.Allocator, em: *const Emitter) !void {
            try list.append(alloc, em.buf.items.len);
        }
    };

    try e.movRR(.rax, .rbx);
    try cases.append(allocator, .{ .text = "movq %rbx, %rax", .want = &.{ 0x48, 0x89, 0xD8 } });
    try Step.mark(&ends, allocator, &e);
    try e.movRR(.r12, .rdi);
    try cases.append(allocator, .{ .text = "movq %rdi, %r12", .want = &.{ 0x49, 0x89, 0xFC } });
    try Step.mark(&ends, allocator, &e);
    try e.movImm(.rax, 42);
    try cases.append(allocator, .{ .text = "movl $42, %eax", .want = &.{ 0xB8, 0x2A, 0x00, 0x00, 0x00 } });
    try Step.mark(&ends, allocator, &e);
    try e.movImm(.r9, 7);
    try cases.append(allocator, .{ .text = "movl $7, %r9d", .want = &.{ 0x41, 0xB9, 0x07, 0x00, 0x00, 0x00 } });
    try Step.mark(&ends, allocator, &e);
    try e.movImm(.rcx, 0xFFFF_FFFF_FFFF_FFFF);
    try cases.append(allocator, .{ .text = "movq $-1, %rcx", .want = &.{ 0x48, 0xC7, 0xC1, 0xFF, 0xFF, 0xFF, 0xFF } });
    try Step.mark(&ends, allocator, &e);
    try e.movImm(.rdx, 0x1122334455667788);
    try cases.append(allocator, .{ .text = "movabsq $0x1122334455667788, %rdx", .want = &.{ 0x48, 0xBA, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 } });
    try Step.mark(&ends, allocator, &e);
    try e.load(.rax, .rdi, 0);
    try cases.append(allocator, .{ .text = "movq (%rdi), %rax", .want = &.{ 0x48, 0x8B, 0x07 } });
    try Step.mark(&ends, allocator, &e);
    try e.load(.r8, .r13, 8);
    try cases.append(allocator, .{ .text = "movq 8(%r13), %r8", .want = &.{ 0x4D, 0x8B, 0x45, 0x08 } });
    try Step.mark(&ends, allocator, &e);
    try e.load(.rax, .rsp, 16);
    try cases.append(allocator, .{ .text = "movq 16(%rsp), %rax", .want = &.{ 0x48, 0x8B, 0x44, 0x24, 0x10 } });
    try Step.mark(&ends, allocator, &e);
    try e.store(.r12, 512, .rcx);
    try cases.append(allocator, .{ .text = "movq %rcx, 512(%r12)", .want = &.{ 0x49, 0x89, 0x8C, 0x24, 0x00, 0x02, 0x00, 0x00 } });
    try Step.mark(&ends, allocator, &e);
    try e.lea(.rsi, .rbx, -32);
    try cases.append(allocator, .{ .text = "leaq -32(%rbx), %rsi", .want = &.{ 0x48, 0x8D, 0x73, 0xE0 } });
    try Step.mark(&ends, allocator, &e);
    try e.aluRR(.add, .rax, .rcx);
    try cases.append(allocator, .{ .text = "addq %rcx, %rax", .want = &.{ 0x48, 0x01, 0xC8 } });
    try Step.mark(&ends, allocator, &e);
    try e.aluRR(.adc, .r10, .r11);
    try cases.append(allocator, .{ .text = "adcq %r11, %r10", .want = &.{ 0x4D, 0x11, 0xDA } });
    try Step.mark(&ends, allocator, &e);
    try e.aluRM(.sbb, .rdx, .rbx, 24);
    try cases.append(allocator, .{ .text = "sbbq 24(%rbx), %rdx", .want = &.{ 0x48, 0x1B, 0x53, 0x18 } });
    try Step.mark(&ends, allocator, &e);
    try e.aluRI(.sub, .rbx, 32);
    try cases.append(allocator, .{ .text = "subq $32, %rbx", .want = &.{ 0x48, 0x83, 0xEB, 0x20 } });
    try Step.mark(&ends, allocator, &e);
    try e.aluRI(.cmp, .r14, 4096);
    try cases.append(allocator, .{ .text = "cmpq $4096, %r14", .want = &.{ 0x49, 0x81, 0xFE, 0x00, 0x10, 0x00, 0x00 } });
    try Step.mark(&ends, allocator, &e);
    try e.aluRR(.xor, .rax, .rax);
    try cases.append(allocator, .{ .text = "xorq %rax, %rax", .want = &.{ 0x48, 0x31, 0xC0 } });
    try Step.mark(&ends, allocator, &e);
    try e.mul(.r9);
    try cases.append(allocator, .{ .text = "mulq %r9", .want = &.{ 0x49, 0xF7, 0xE1 } });
    try Step.mark(&ends, allocator, &e);
    try e.imulRR(.rax, .r8);
    try cases.append(allocator, .{ .text = "imulq %r8, %rax", .want = &.{ 0x49, 0x0F, 0xAF, 0xC0 } });
    try Step.mark(&ends, allocator, &e);
    try e.not(.rdx);
    try cases.append(allocator, .{ .text = "notq %rdx", .want = &.{ 0x48, 0xF7, 0xD2 } });
    try Step.mark(&ends, allocator, &e);
    try e.setcc(.b, .rax);
    try cases.append(allocator, .{ .text = "rex setb %al", .want = &.{ 0x40, 0x0F, 0x92, 0xC0 } });
    try Step.mark(&ends, allocator, &e);
    try e.movzxByte(.rax, .rax);
    try cases.append(allocator, .{ .text = "movzbq %al, %rax", .want = &.{ 0x48, 0x0F, 0xB6, 0xC0 } });
    try Step.mark(&ends, allocator, &e);
    try e.push(.r15);
    try cases.append(allocator, .{ .text = "pushq %r15", .want = &.{ 0x41, 0x57 } });
    try Step.mark(&ends, allocator, &e);
    try e.pop(.rbx);
    try cases.append(allocator, .{ .text = "popq %rbx", .want = &.{0x5B} });
    try Step.mark(&ends, allocator, &e);
    try e.callMem(.r14, 48);
    try cases.append(allocator, .{ .text = "callq *48(%r14)", .want = &.{ 0x41, 0xFF, 0x56, 0x30 } });
    try Step.mark(&ends, allocator, &e);
    try e.jmpReg(.rcx);
    try cases.append(allocator, .{ .text = "jmpq *%rcx", .want = &.{ 0xFF, 0xE1 } });
    try Step.mark(&ends, allocator, &e);
    try e.movdquLoad(0, .rbx, 16);
    try cases.append(allocator, .{ .text = "movdqu 16(%rbx), %xmm0", .want = &.{ 0xF3, 0x0F, 0x6F, 0x43, 0x10 } });
    try Step.mark(&ends, allocator, &e);
    try e.movdquStore(.r12, 0, 9);
    try cases.append(allocator, .{ .text = "movdqu %xmm9, (%r12)", .want = &.{ 0xF3, 0x45, 0x0F, 0x7F, 0x0C, 0x24 } });
    try Step.mark(&ends, allocator, &e);
    try e.pand(0, 2);
    try cases.append(allocator, .{ .text = "pand %xmm2, %xmm0", .want = &.{ 0x66, 0x0F, 0xDB, 0xC2 } });
    try Step.mark(&ends, allocator, &e);
    try e.pxor(1, 3);
    try cases.append(allocator, .{ .text = "pxor %xmm3, %xmm1", .want = &.{ 0x66, 0x0F, 0xEF, 0xCB } });
    try Step.mark(&ends, allocator, &e);
    try e.por(8, 1);
    try cases.append(allocator, .{ .text = "por %xmm1, %xmm8", .want = &.{ 0x66, 0x44, 0x0F, 0xEB, 0xC1 } });
    try Step.mark(&ends, allocator, &e);
    try e.ret();
    try cases.append(allocator, .{ .text = "retq", .want = &.{0xC3} });
    try Step.mark(&ends, allocator, &e);

    var start: usize = 0;
    for (cases.items, ends.items) |case, end| {
        const got = e.buf.items[start..end];
        if (!std.mem.eql(u8, case.want, got)) {
            std.log.err("{s}: want {x} got {x}", .{ case.text, case.want, got });
            return error.TestUnexpectedResult;
        }
        start = end;
    }
}

test "x86_64 jump patching" {
    var e = Emitter.init(std.testing.allocator);
    defer e.deinit();
    const j = try e.jmpPlaceholder(); // E9 rel32 at 1
    const c = try e.jccPlaceholder(.ne); // 0F 85 rel32 at 7
    try e.ret(); // at 11
    try e.patchRel32(j, 11);
    try e.patchRel32(c, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0xE9, 0x06, 0x00, 0x00, 0x00 }, e.buf.items[0..5]);
    try std.testing.expectEqualSlices(u8, &.{ 0x0F, 0x85, 0xF5, 0xFF, 0xFF, 0xFF }, e.buf.items[5..11]);
}
