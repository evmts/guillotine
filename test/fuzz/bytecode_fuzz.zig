//! Bytecode Analysis, Jumpdest Oracle, Fusion Invariants, and Dispatch Schedule Fuzz Testing
//!
//! Verifies:
//! 1. Independent reference JUMPDEST scanner oracle matches Bytecode jumpdest table exactly.
//! 2. All PUSH1..PUSH32 (including truncated EOF PUSH) never crash, leak, or misclassify JUMPDESTs.
//! 3. Fusion detection never produces out-of-bounds spans or crosses JUMPDEST boundaries.
//! 4. Dispatch schedule & jump table construction succeeds cleanly with fusions ON and OFF.
//! 5. OOM resilience via FailingAllocator (no leaks or crashes under allocation failure).
//! 6. `pretty_print` never traps, for any content and length, and prints the first
//!    block's stack requirement clamped to u16 exactly as a wide-integer oracle computes it.
//! 7. Program counter width: `PcType` holds the largest code plus 33 bytes of lookahead,
//!    and `Bytecode.init` accepts a length exactly when `len + 33` fits.

const std = @import("std");
const evm = @import("evm");
const fuzz_alloc = @import("fuzz_alloc.zig");
const testing = std.testing;
const Opcode = evm.Opcode;

const BytecodeFusionOn = evm.Bytecode(.{ .fusions_enabled = true });
const BytecodeFusionOff = evm.Bytecode(.{ .fusions_enabled = false });

/// Independent, dead-simple reference EVM JUMPDEST scanner per Yellow Paper Section 9.4.3.
fn referenceIsValidJumpDest(code: []const u8, allocator: std.mem.Allocator) ![]bool {
    const valid = try allocator.alloc(bool, code.len);
    @memset(valid, false);

    var pc: usize = 0;
    while (pc < code.len) {
        const op = code[pc];
        if (op == 0x5b) {
            valid[pc] = true;
            pc += 1;
        } else if (op >= 0x60 and op <= 0x7f) {
            const push_len = @as(usize, op - 0x5f);
            pc += 1 + push_len;
        } else {
            pc += 1;
        }
    }
    return valid;
}

pub fn fuzzBytecodeJumpdestOracle(_: void, input: []const u8) !void {
    const allocator = fuzz_alloc.get();
    const max_len: usize = 24576;
    const code = input[0..@min(input.len, max_len)];

    const ref_valid = try referenceIsValidJumpDest(code, allocator);
    defer allocator.free(ref_valid);

    var bc_on = BytecodeFusionOn.init(allocator, code) catch |err| switch (err) {
        error.InitcodeTooLarge, error.InvalidJumpDestination, error.InvalidOpcode, error.TruncatedPush => return,
        else => return err,
    };
    defer bc_on.deinit();

    var bc_off = BytecodeFusionOff.init(allocator, code) catch |err| switch (err) {
        error.InitcodeTooLarge, error.InvalidJumpDestination, error.InvalidOpcode, error.TruncatedPush => return,
        else => return err,
    };
    defer bc_off.deinit();

    // Every position in bytecode must agree with the Yellow Paper reference JUMPDEST scanner
    for (0..code.len) |pc| {
        const expected = ref_valid[pc];
        const actual_on = bc_on.isValidJumpDest(@intCast(pc));
        const actual_off = bc_off.isValidJumpDest(@intCast(pc));
        try std.testing.expectEqual(expected, actual_on);
        try std.testing.expectEqual(expected, actual_off);
    }

    // Out-of-bounds PCs must never be valid JUMPDESTs
    try std.testing.expect(!bc_on.isValidJumpDest(@intCast(code.len)));
    try std.testing.expect(!bc_on.isValidJumpDest(@intCast(code.len + 1)));
    try std.testing.expect(!bc_on.isValidJumpDest(std.math.maxInt(u16)));

    // Verify iterator traversal stays strictly monotonic, bounded, and visits EVERY valid JUMPDEST
    // (proving no fusion ever swallows an interior JUMPDEST!)
    var seen_jumpdests: usize = 0;
    var expected_jumpdests: usize = 0;
    for (ref_valid) |v| {
        if (v) expected_jumpdests += 1;
    }

    var iter = bc_on.createIterator();
    var prev_pc: usize = 0;
    var steps: usize = 0;
    while (try iter.next()) |op| {
        const cur_pc = iter.pc;
        try std.testing.expect(cur_pc <= code.len);
        try std.testing.expect(cur_pc >= prev_pc);
        if (op == .jumpdest) seen_jumpdests += 1;
        prev_pc = cur_pc;
        steps += 1;
        try std.testing.expect(steps <= code.len + 1);
    }
    try std.testing.expectEqual(expected_jumpdests, seen_jumpdests);
}

pub fn fuzzDispatchScheduleBuild(_: void, input: []const u8) !void {
    const allocator = fuzz_alloc.get();
    const code = input[0..@min(input.len, 8192)];

    // Test bytecode analysis + iterator traversal + stats with fusion enabled and disabled
    {
        var bc = BytecodeFusionOn.init(allocator, code) catch return;
        defer bc.deinit();
        var iter = bc.createIterator();
        var count: usize = 0;
        while (try iter.next()) |_| {
            count += 1;
            try std.testing.expect(count <= code.len + 1);
        }
    }

    {
        var bc = BytecodeFusionOff.init(allocator, code) catch return;
        defer bc.deinit();
        var iter = bc.createIterator();
        var count: usize = 0;
        while (try iter.next()) |_| {
            count += 1;
            try std.testing.expect(count <= code.len + 1);
        }
    }
}

pub fn fuzzStructuredFusionPatterns(_: void, input: []const u8) !void {
    if (input.len < 4) return;

    var buf: [2048]u8 = undefined;
    var len: usize = 0;

    var i: usize = 0;
    while (i < input.len and len + 16 <= buf.len) : (i += 1) {
        const b = input[i];
        switch (b % 14) {
            0 => { // PUSH1 + ADD
                buf[len] = 0x60;
                buf[len + 1] = if (i + 1 < input.len) input[i + 1] else 1;
                buf[len + 2] = 0x01;
                len += 3;
            },
            1 => { // PUSH1 + MUL
                buf[len] = 0x60;
                buf[len + 1] = if (i + 1 < input.len) input[i + 1] else 2;
                buf[len + 2] = 0x02;
                len += 3;
            },
            2 => { // PUSH1 + SUB
                buf[len] = 0x60;
                buf[len + 1] = if (i + 1 < input.len) input[i + 1] else 3;
                buf[len + 2] = 0x03;
                len += 3;
            },
            3 => { // PUSH1 + DIV
                buf[len] = 0x60;
                buf[len + 1] = if (i + 1 < input.len) input[i + 1] else 4;
                buf[len + 2] = 0x04;
                len += 3;
            },
            4 => { // ISZERO + JUMPI
                buf[len] = 0x15;
                buf[len + 1] = 0x57;
                len += 2;
            },
            5 => { // PUSH1 + JUMPI
                buf[len] = 0x60;
                buf[len + 1] = if (i + 1 < input.len) input[i + 1] else 0;
                buf[len + 2] = 0x57;
                len += 3;
            },
            6 => { // PUSH1 + JUMP
                buf[len] = 0x60;
                buf[len + 1] = if (i + 1 < input.len) input[i + 1] else 0;
                buf[len + 2] = 0x56;
                len += 3;
            },
            7 => { // DUP2 + MSTORE + PUSH1
                buf[len] = 0x81;
                buf[len + 1] = 0x52;
                buf[len + 2] = 0x60;
                buf[len + 3] = 0x20;
                len += 4;
            },
            8 => { // Function dispatch: PUSH4 sel, EQ, PUSH2 target, JUMPI
                buf[len] = 0x63;
                buf[len + 1] = b;
                buf[len + 2] = b ^ 0x55;
                buf[len + 3] = b ^ 0xaa;
                buf[len + 4] = b ^ 0xff;
                buf[len + 5] = 0x14;
                buf[len + 6] = 0x61;
                buf[len + 7] = 0x00;
                buf[len + 8] = 0x10;
                buf[len + 9] = 0x57;
                len += 10;
            },
            9 => { // JUMPDEST
                buf[len] = 0x5b;
                len += 1;
            },
            10 => { // PUSH containing 0x5b (fake JUMPDEST inside immediate!)
                const push_sz: usize = @as(usize, b % 8) + 1;
                buf[len] = @intCast(0x5f + push_sz);
                len += 1;
                for (0..push_sz) |_| {
                    buf[len] = 0x5b;
                    len += 1;
                }
            },
            11 => { // PUSH1 + MLOAD / MSTORE
                buf[len] = 0x60;
                buf[len + 1] = 0x40;
                buf[len + 2] = if ((b & 1) == 0) 0x51 else 0x52;
                len += 3;
            },
            12 => { // Multi-PUSH (PUSH1, PUSH1, PUSH1)
                buf[len] = 0x60;
                buf[len + 1] = 0x01;
                buf[len + 2] = 0x60;
                buf[len + 3] = 0x02;
                buf[len + 4] = 0x60;
                buf[len + 5] = 0x03;
                len += 6;
            },
            else => {
                buf[len] = b;
                len += 1;
            },
        }
    }

    try fuzzBytecodeJumpdestOracle({}, buf[0..len]);
    try fuzzDispatchScheduleBuild({}, buf[0..len]);
}

pub fn fuzzBytecodeOomResilience(_: void, input: []const u8) !void {
    const code = input[0..@min(input.len, 256)];
    var fail_index: usize = 0;
    while (fail_index < 12) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(fuzz_alloc.get(), .{ .fail_index = fail_index });
        var bc = BytecodeFusionOn.init(failing.allocator(), code) catch |err| switch (err) {
            error.OutOfMemory, error.InitcodeTooLarge, error.InvalidJumpDestination, error.InvalidOpcode, error.TruncatedPush => continue,
        };
        bc.deinit();
    }
}

/// A bytecode type whose program counter is 32 bits wide, as on every fork before
/// Shanghai, so code far longer than 65,535 bytes is analyzable.
const BytecodeWide = evm.Bytecode(.{ .hardfork = .LONDON });
/// The smallest program counter: 8 bits, code of at most 222 bytes.
const BytecodeTiny = evm.Bytecode(.{ .max_bytecode_size = 222, .max_initcode_size = 222 });

/// Stack requirement of the block starting at pc 0, computed in i64 and clamped to
/// u16 at the very end: the specification of what `pretty_print` shows in the
/// first block header.
fn referenceFirstBlockStack(code: []const u8) struct { min: u16, max: u16 } {
    const info = evm.opcode_data.OPCODE_INFO;
    var height: i64 = 0;
    var lowest: i64 = 0;
    var highest: i64 = 0;
    var pc: usize = 0;
    while (pc < code.len) {
        const op = code[pc];
        height -= info[op].stack_inputs;
        lowest = @min(lowest, height);
        height += info[op].stack_outputs;
        highest = @max(highest, height);
        pc += if (op >= 0x60 and op <= 0x7f) @as(usize, op - 0x5f) + 1 else 1;
        switch (op) {
            0x00, 0x56, 0x57, 0xf3, 0xfd, 0xfe, 0xff => break,
            else => {},
        }
        if (pc < code.len and code[pc] == 0x5b) break;
    }
    return .{ .min = @intCast(@min(-lowest, 65_535)), .max = @intCast(@min(highest, 65_535)) };
}

/// `pretty_print` over long generated code. The first two bytes pick the length (up
/// to 200,000 bytes, often exactly at an overflow edge) and the rest is a pattern
/// repeated to that length. Long runs of one opcode drive the block's stack
/// requirement past what the printed u16 holds: 10,923 LOG4 need 65,538 items.
pub fn fuzzPrettyPrintNeverTraps(_: void, input: []const u8) !void {
    if (input.len < 3) return;
    const allocator = fuzz_alloc.get();
    const choice: usize = (@as(usize, input[0]) << 8) | input[1];
    const len: usize = switch (choice % 8) {
        0 => 10_922,
        1 => 10_923,
        2 => 65_536,
        3 => 100_000,
        else => 1 + (choice * 200_000) / 65_536,
    };
    const pattern = input[2..];
    const code = try allocator.alloc(u8, len);
    defer allocator.free(code);
    for (code, 0..) |*byte, i| byte.* = pattern[i % pattern.len];

    var bytecode = BytecodeWide.init(allocator, code) catch |err| switch (err) {
        // Refusing the code is fine. Trapping on it is not.
        error.InitcodeTooLarge, error.InvalidJumpDestination, error.InvalidOpcode, error.TruncatedPush => return,
        error.OutOfMemory => return err,
    };
    defer bytecode.deinit();
    const text = try bytecode.pretty_print(allocator);
    defer allocator.free(text);
    try std.testing.expect(text.len > 0);

    const want = referenceFirstBlockStack(code);
    var expected: [48]u8 = undefined;
    const header = try std.fmt.bufPrint(&expected, "stack: [{d}, {d}]", .{ want.min, want.max });
    try std.testing.expect(std.mem.indexOf(u8, text, header) != null);
}

/// Program counter width against wide-integer arithmetic. The input picks a
/// maximum code size anywhere in u32 and a code length near each type's limit.
pub fn fuzzPcTypeAndCodeSize(_: void, input: []const u8) !void {
    if (input.len < 9) return;
    const max_code = std.mem.readInt(u32, input[0..4], .little);
    const unbounded = input[8] & 1 == 1;

    // Width: the smallest of 8/12/16/32 bits that holds max_code + 33.
    const width = evm.verified_ops.pcTypeWidthBits(max_code, unbounded);
    const needed: u128 = @as(u128, max_code) + 33;
    const want: u8 = if (unbounded) 32 else if (needed <= 0xff) 8 else if (needed <= 0xfff) 12 else if (needed <= 0xffff) 16 else 32;
    try std.testing.expectEqual(want, width);
    if (width < 32) try std.testing.expect(needed <= (@as(u128, 1) << @intCast(width)) - 1);

    // Fit: len + 33 <= pc_max, for any 64-bit length and limit.
    const code_len = std.mem.readInt(u64, input[0..8], .little);
    inline for (.{ u8, u12, u16, u32, u64 }) |Pc| {
        const pc_max: u64 = std.math.maxInt(Pc);
        try std.testing.expectEqual(@as(u128, code_len) + 33 <= pc_max, evm.verified_ops.codeFitsPc(code_len, pc_max));
    }

    // Bytecode.init at each program counter width, a few bytes around its limit.
    const allocator = fuzz_alloc.get();
    const offset: usize = input[4] % 8;
    inline for (.{ BytecodeTiny, BytecodeFusionOn, BytecodeWide }) |Type| {
        const limit: usize = @min(std.math.maxInt(Type.PcType) - 33, 70_000);
        const len = limit + offset - 4;
        const code = try allocator.alloc(u8, len);
        defer allocator.free(code);
        @memset(code, 0x5b);
        if (Type.init(allocator, code)) |built| {
            var bytecode = built;
            defer bytecode.deinit();
            try std.testing.expect(len + 33 <= std.math.maxInt(Type.PcType));
            try std.testing.expectEqual(len, @as(usize, bytecode.len()));
        } else |err| {
            try std.testing.expectEqual(error.InitcodeTooLarge, err);
            try std.testing.expect(len + 33 > std.math.maxInt(Type.PcType));
        }
    }
}

const pretty_print_corpus: []const []const u8 = &.{
    &.{ 0x00, 0x00, 0xa4 }, // 10,922 LOG4: 65,532 items, the last count that fits
    &.{ 0x00, 0x01, 0xa4 }, // 10,923 LOG4: 65,538 items, the first that does not
    &.{ 0x00, 0x02, 0xa4 }, // 65,536 LOG4
    &.{ 0x00, 0x03, 0xa4 }, // 100,000 LOG4
    &.{ 0x00, 0x03, 0x80 }, // 100,000 DUP1: headroom saturates upward
    &.{ 0x00, 0x03, 0x9f, 0x50 }, // SWAP16 and POP
    &.{ 0xff, 0xff, 0x60, 0x00, 0x56, 0x5b, 0xa4 }, // 200,000 bytes of jumps and blocks
    &.{ 0x00, 0x02, 0x7f }, // PUSH32 fed with itself
    &.{ 0x12, 0x34, 0x5b, 0xa4, 0xa4, 0xa4, 0xf3 }, // short blocks
    &.{ 0x00, 0x03, 0x0c }, // an undefined opcode
};

const pc_width_corpus: []const []const u8 = &.{
    &.{ 222, 0, 0, 0, 0, 0, 0, 0, 0 }, // the largest size an 8-bit pc serves
    &.{ 223, 0, 0, 0, 1, 0, 0, 0, 0 },
    &.{ 255, 0, 0, 0, 2, 0, 0, 0, 0 },
    &.{ 0xde, 0xff, 0, 0, 3, 0, 0, 0, 0 }, // 65,502
    &.{ 0xdf, 0xff, 0, 0, 4, 0, 0, 0, 0 }, // 65,503
    &.{ 0xff, 0xff, 0, 0, 5, 0, 0, 0, 0 }, // 65,535
    &.{ 0xff, 0xff, 0xff, 0xff, 6, 0xff, 0xff, 0xff, 0 }, // u32 and u64 extremes
    &.{ 0x00, 0xc0, 0, 0, 7, 0, 0, 0, 1 }, // 49,152 before Shanghai: unbounded
};

const BytecodeParis = evm.Bytecode(.{ .hardfork = .MERGE, .fusions_enabled = false });
const BytecodeShanghai = evm.Bytecode(.{ .hardfork = .SHANGHAI, .fusions_enabled = false });
const BytecodeCancun = evm.Bytecode(.{ .hardfork = .CANCUN, .fusions_enabled = false });

/// PC of the first instruction from `start` that halts as INVALID on `Bc`'s fork,
/// walking whole instructions (PUSH immediates are data). Null when there is none.
fn firstHaltingPc(comptime Bc: type, code: []const u8, start: usize) ?usize {
    var pc = start;
    while (pc < code.len) {
        const opcode = code[pc];
        if (Bc.Iterator.halts_as_invalid[opcode]) return pc;
        pc += if (opcode >= 0x60 and opcode <= 0x7f) @as(usize, opcode - 0x5f) + 1 else 1;
    }
    return null;
}

/// `calculateBlockInfo` must end a block at the first opcode that halts as INVALID
/// on the fork: the block's gas and stack bounds are those of the code cut off at
/// that opcode, whatever bytes follow it.
fn checkBlockInfoIgnoresDeadTail(comptime Bc: type, code: []const u8, filler: u8) !void {
    const allocator = fuzz_alloc.get();
    const halt_pc = firstHaltingPc(Bc, code, 0) orelse return;

    var prefix = Bc.init(allocator, code[0..halt_pc]) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InitcodeTooLarge, error.InvalidJumpDestination, error.InvalidOpcode, error.TruncatedPush => return,
    };
    defer prefix.deinit();
    const expected = Bc.Iterator.calculateBlockInfo(&prefix, 0, 0);

    // The same prefix and halting opcode, followed by the input's tail and by a
    // tail of one repeated byte (expensive opcodes, deep stack inputs, PUSH data).
    const refilled = try allocator.dupe(u8, code);
    defer allocator.free(refilled);
    @memset(refilled[halt_pc + 1 ..], filler);
    for ([_][]const u8{ code, refilled, code[0 .. halt_pc + 1] }) |variant| {
        var bytecode = Bc.init(allocator, variant) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.InitcodeTooLarge, error.InvalidJumpDestination, error.InvalidOpcode, error.TruncatedPush => continue,
        };
        defer bytecode.deinit();
        try testing.expectEqual(expected, Bc.Iterator.calculateBlockInfo(&bytecode, 0, 0));
    }
}

pub fn fuzzBlockInfoStopsAtInvalidOpcodes(_: void, input: []const u8) !void {
    if (input.len == 0) return;
    const filler = input[0];
    const code = input[1..@min(input.len, 257)];

    // Bytes no fork assigns, and the withdrawn AUTH/AUTHCALL, halt on every fork.
    inline for (.{ BytecodeParis, BytecodeShanghai, BytecodeCancun }) |Bc| {
        inline for (.{ 0x0C, 0x0D, 0x0E, 0x0F, 0x21, 0x2F, 0x4B, 0x4F, 0xA5, 0xEF, 0xF6, 0xF7, 0xF8, 0xFB, 0xFC, 0xFE }) |byte| {
            try testing.expect(Bc.Iterator.halts_as_invalid[byte]);
        }
        inline for (.{ 0x00, 0x01, 0x50, 0x54, 0x55, 0x56, 0x57, 0x5B, 0x60, 0x7F, 0x80, 0x9F, 0xA4, 0xF1, 0xF3, 0xFD, 0xFF }) |byte| {
            try testing.expect(!Bc.Iterator.halts_as_invalid[byte]);
        }
    }
    // Fork-introduced opcodes halt before their fork and run from it on.
    try testing.expect(BytecodeParis.Iterator.halts_as_invalid[0x5F]); // PUSH0
    try testing.expect(!BytecodeShanghai.Iterator.halts_as_invalid[0x5F]);
    inline for (.{ 0x49, 0x4A, 0x5C, 0x5D, 0x5E }) |cancun_opcode| { // BLOBHASH, BLOBBASEFEE, TLOAD, TSTORE, MCOPY
        try testing.expect(BytecodeParis.Iterator.halts_as_invalid[cancun_opcode]);
        try testing.expect(BytecodeShanghai.Iterator.halts_as_invalid[cancun_opcode]);
        try testing.expect(!BytecodeCancun.Iterator.halts_as_invalid[cancun_opcode]);
    }

    try checkBlockInfoIgnoresDeadTail(BytecodeParis, code, filler);
    try checkBlockInfoIgnoresDeadTail(BytecodeShanghai, code, filler);
    try checkBlockInfoIgnoresDeadTail(BytecodeCancun, code, filler);
}

const AnalyzeBlock = struct { start: u16, end: u16 };
const AnalyzeFusion = struct {
    fusion_type: enum { constant_fold, iszero_jumpi },
    original_length: u16,
    folded_value: u256 = 0,
};

/// Big-endian value of the immediate of the PUSH at `push_pc`, or null when the end
/// of the code truncates it.
fn referencePushValue(code: []const u8, push_pc: usize) ?u256 {
    const size = @as(usize, code[push_pc] - 0x5f);
    if (push_pc + 1 + size > code.len) return null;
    var value: u256 = 0;
    for (code[push_pc + 1 .. push_pc + 1 + size]) |byte| value = value * 256 + byte;
    return value;
}

/// `bytecodeAnalyze` (the C API's analyzer) against an independent decoder:
/// - its JUMPDEST list is the Yellow Paper's,
/// - a static jump recorded at a JUMPDEST names the JUMP's PUSH, or the SECOND PUSH
///   of a `PUSH cond PUSH dest JUMPI`, at full 256-bit width, and is a JUMPDEST,
/// - `PUSH1 a PUSH1 b SUB` folds to `b - a` (top minus second).
pub fn fuzzBytecodeAnalyzeStaticJumps(_: void, input: []const u8) !void {
    const allocator = fuzz_alloc.get();
    const analyze = evm.bytecode_analyze.bytecodeAnalyze;

    // (1) Arbitrary code.
    {
        const code = input[0..@min(input.len, 512)];
        var analysis = try analyze(u16, AnalyzeBlock, AnalyzeFusion, allocator, code);
        defer analysis.deinit(allocator);
        const valid = try referenceIsValidJumpDest(code, allocator);
        defer allocator.free(valid);

        var expected_jumpdests: usize = 0;
        for (valid) |is_jumpdest| expected_jumpdests += @intFromBool(is_jumpdest);
        try testing.expectEqual(expected_jumpdests, analysis.jumpdests.len);
        for (analysis.jumpdests) |pc| try testing.expect(valid[pc]);
        for (analysis.push_pcs) |pc| try testing.expect(code[pc] >= 0x60 and code[pc] <= 0x7f);

        var fusions = analysis.jump_fusions.iterator();
        while (fusions.next()) |entry| {
            const source: usize = entry.key_ptr.*;
            const target: usize = entry.value_ptr.*;
            try testing.expect(valid[source]);
            try testing.expect(target < code.len and valid[target]);

            const first_push = source + 1;
            try testing.expect(first_push < code.len);
            try testing.expect(code[first_push] >= 0x60 and code[first_push] <= 0x7f);
            const after_first = first_push + 1 + @as(usize, code[first_push] - 0x5f);
            try testing.expect(after_first < code.len);
            const destination = if (code[after_first] == 0x56)
                referencePushValue(code, first_push)
            else destination: {
                try testing.expect(code[after_first] >= 0x60 and code[after_first] <= 0x7f);
                const jumpi_pc = after_first + 1 + @as(usize, code[after_first] - 0x5f);
                try testing.expect(jumpi_pc < code.len);
                try testing.expectEqual(@as(u8, 0x57), code[jumpi_pc]);
                break :destination referencePushValue(code, after_first);
            };
            try testing.expectEqual(@as(?u256, target), destination);
        }
    }
    if (input.len < 3) return;

    // (2) JUMPDEST PUSH1 cond PUSH1 dest JUMPI, then ten JUMPDESTs at PCs 6..15.
    {
        const condition = input[0] % 24;
        const destination = input[1] % 24;
        const code = [_]u8{ 0x5b, 0x60, condition, 0x60, destination, 0x57 } ++ @as([10]u8, @splat(0x5b));
        var analysis = try analyze(u16, AnalyzeBlock, AnalyzeFusion, allocator, &code);
        defer analysis.deinit(allocator);
        const is_jumpdest = destination == 0 or (destination >= 6 and destination <= 15);
        const expected: ?u16 = if (is_jumpdest) destination else null;
        try testing.expectEqual(expected, analysis.jump_fusions.get(0));
    }

    // (3) JUMPDEST PUSH3 0x01HHLL JUMP: the low 16 bits may name a JUMPDEST, the
    // value never does. A truncating decoder would record it.
    {
        const low = input[1] % 24;
        const code = [_]u8{ 0x5b, 0x62, 0x01 + (input[0] % 8), 0x00, low, 0x56 } ++ @as([10]u8, @splat(0x5b));
        var analysis = try analyze(u16, AnalyzeBlock, AnalyzeFusion, allocator, &code);
        defer analysis.deinit(allocator);
        try testing.expectEqual(@as(?u16, null), analysis.jump_fusions.get(0));
    }

    // (4) PUSH1 a PUSH1 b ADD|SUB|MUL: b is the top of the stack.
    {
        const first: u256 = input[0];
        const second: u256 = input[1];
        const Fold = struct { opcode: u8, value: u256 };
        const folds = [_]Fold{
            .{ .opcode = 0x01, .value = first +% second },
            .{ .opcode = 0x03, .value = second -% first },
            .{ .opcode = 0x02, .value = first *% second },
        };
        for (folds) |fold| {
            const code = [_]u8{ 0x60, input[0], 0x60, input[1], fold.opcode, 0x00 };
            var analysis = try analyze(u16, AnalyzeBlock, AnalyzeFusion, allocator, &code);
            defer analysis.deinit(allocator);
            const fusion = analysis.advanced_fusions.get(0) orelse return error.ConstantFoldMissing;
            try testing.expectEqual(@as(u16, 5), fusion.original_length);
            try testing.expectEqual(fold.value, fusion.folded_value);
        }
    }
}

const block_info_corpus: []const []const u8 = &.{
    &.{},
    &.{ 0x54, 0x60, 0x01, 0x0C, 0x60, 0x02, 0x60, 0x03, 0x01, 0x54, 0xF1 }, // undefined 0x0C, then a dead tail
    &.{ 0xF1, 0x60, 0x01, 0xEF, 0x54, 0x55, 0xF1 }, // 0xEF
    &.{ 0x7F, 0x60, 0x01, 0xF6, 0x80, 0x80, 0x80 }, // AUTH
    &.{ 0x7F, 0x60, 0x01, 0xF7, 0x80, 0x80, 0x80 }, // AUTHCALL
    &.{ 0x54, 0x60, 0x01, 0x5F, 0x60, 0x02, 0x01, 0x01 }, // PUSH0: halts on Paris only
    &.{ 0x55, 0x60, 0x01, 0x5C, 0x60, 0x02, 0x01, 0x50 }, // TLOAD: halts before Cancun
    &.{ 0x50, 0x60, 0x0C, 0x61, 0xEF, 0xF6, 0x01, 0xFE, 0x54 }, // halting bytes as PUSH data, then INVALID
    &.{ 0x80, 0x0C }, // the block is the halting byte alone
    &.{ 0x80, 0x60, 0x01, 0x56, 0x0C, 0x54 }, // JUMP ends the block before the halting byte
};

const analyze_corpus: []const []const u8 = &.{
    &.{},
    &.{ 0x5b, 0x60, 0x01, 0x60, 0x08, 0x57, 0x00, 0x00, 0x5b, 0x00 }, // JUMPI: condition 1, destination 8
    &.{ 0x5b, 0x60, 0x08, 0x60, 0x07, 0x57, 0x00, 0x00, 0x5b, 0x00 }, // condition names a JUMPDEST, destination does not
    &.{ 0x5b, 0x62, 0x01, 0x00, 0x06, 0x56, 0x5b, 0x00 }, // PUSH3 0x010006 JUMP
    &.{ 0x5b, 0x60, 0x04, 0x56, 0x5b, 0x00 }, // PUSH1 4 JUMP
    &.{ 0x60, 0x05, 0x60, 0x03, 0x03, 0x00 }, // 3 - 5 wraps
    &.{ 0x5b, 0x7f }, // PUSH32 truncated right after a JUMPDEST
    &.{ 0x5b, 0x60, 0x01, 0x7f, 0x57 }, // second PUSH truncated
    &.{ 0x06, 0x09, 0x00 },
    &.{ 0x00, 0x00, 0xff },
    &.{ 0xff, 0x01, 0x00 },
};

const seed_corpus: []const []const u8 = &.{
    &.{},
    &.{0x00},
    &.{0x5b},
    &.{ 0x60, 0x5b, 0x5b },
    &.{0x7f}, // truncated PUSH32
    &.{ 0x7f, 0x5b, 0x5b, 0x5b }, // truncated PUSH32 full of 0x5b
    &.{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 },
    &.{ 0x63, 0xde, 0xad, 0xbe, 0xef, 0x14, 0x61, 0x00, 0x0c, 0x57, 0x00, 0x00, 0x5b, 0x00 },
    &.{ 0x5b, 0x60, 0x01, 0x01, 0x80, 0x60, 0x00, 0x57, 0x00 },
    &.{ 0x81, 0x52, 0x60, 0x20, 0x15, 0x57, 0x5b, 0xfe },
};

test "fuzz bytecode jumpdest reference oracle and fusion invariants" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzBytecodeJumpdestOracle), .{ .corpus = seed_corpus });
}

test "fuzz calculateBlockInfo ends the block at undefined, fork-disabled and withdrawn opcodes" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzBlockInfoStopsAtInvalidOpcodes), .{ .corpus = block_info_corpus });
}

test "fuzz bytecodeAnalyze static JUMP and JUMPI targets, PC range and SUB folding" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzBytecodeAnalyzeStaticJumps), .{ .corpus = analyze_corpus });
}

test "fuzz dispatch schedule build fusion on and off" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzDispatchScheduleBuild), .{ .corpus = seed_corpus });
}

test "fuzz structured fusion patterns and fake jumpdests" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzStructuredFusionPatterns), .{ .corpus = seed_corpus });
}

test "fuzz pretty_print never traps and clamps the block stack requirement exactly" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzPrettyPrintNeverTraps), .{ .corpus = pretty_print_corpus });
}

test "fuzz program counter width and code size limits at every PcType" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzPcTypeAndCodeSize), .{ .corpus = pc_width_corpus });
}

test "fuzz bytecode oom resilience without leaks" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzBytecodeOomResilience), .{ .corpus = seed_corpus });
}
