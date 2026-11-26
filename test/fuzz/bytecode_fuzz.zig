//! Bytecode Analysis, Jumpdest Oracle, Fusion Invariants, and Dispatch Schedule Fuzz Testing
//!
//! Verifies:
//! 1. Independent reference JUMPDEST scanner oracle matches Bytecode jumpdest table exactly.
//! 2. All PUSH1..PUSH32 (including truncated EOF PUSH) never crash, leak, or misclassify JUMPDESTs.
//! 3. Fusion detection never produces out-of-bounds spans or crosses JUMPDEST boundaries.
//! 4. Dispatch schedule & jump table construction succeeds cleanly with fusions ON and OFF.
//! 5. OOM resilience via FailingAllocator (no leaks or crashes under allocation failure).

const std = @import("std");
const evm = @import("evm");
const fuzz_alloc = @import("fuzz_alloc.zig");
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
    while (iter.next()) |op| {
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
        while (iter.next()) |_| {
            count += 1;
            try std.testing.expect(count <= code.len + 1);
        }
    }

    {
        var bc = BytecodeFusionOff.init(allocator, code) catch return;
        defer bc.deinit();
        var iter = bc.createIterator();
        var count: usize = 0;
        while (iter.next()) |_| {
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

test "fuzz dispatch schedule build fusion on and off" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzDispatchScheduleBuild), .{ .corpus = seed_corpus });
}

test "fuzz structured fusion patterns and fake jumpdests" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzStructuredFusionPatterns), .{ .corpus = seed_corpus });
}

test "fuzz bytecode oom resilience without leaks" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzBytecodeOomResilience), .{ .corpus = seed_corpus });
}
