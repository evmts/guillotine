//! Standalone single-pass bytecode analyzer for tooling (the C API's
//! `evm_bytecode_analyze`). The interpreter does not use it: `Bytecode` and the
//! dispatch builder own the analysis that execution depends on.
//!
//! Program counters are tracked in `usize` and converted to `PcType` only after a
//! range check, so no code length or PUSH immediate can wrap or truncate one.

const std = @import("std");
const Opcode = @import("../opcodes/opcode.zig").Opcode;

const op_push1: u8 = @backingInt(Opcode.PUSH1);
const op_push32: u8 = @backingInt(Opcode.PUSH32);
const op_add: u8 = @backingInt(Opcode.ADD);
const op_mul: u8 = @backingInt(Opcode.MUL);
const op_sub: u8 = @backingInt(Opcode.SUB);
const op_shl: u8 = @backingInt(Opcode.SHL);
const op_iszero: u8 = @backingInt(Opcode.ISZERO);
const op_jump: u8 = @backingInt(Opcode.JUMP);
const op_jumpi: u8 = @backingInt(Opcode.JUMPI);
const op_jumpdest: u8 = @backingInt(Opcode.JUMPDEST);

pub const AnalyzeError = std.mem.Allocator.Error || error{
    /// The code is longer than `PcType` can index.
    CodeTooLarge,
};

/// Result of `bytecodeAnalyze`. Owns every slice and map; release with `deinit`.
pub fn Analysis(comptime PcType: type, comptime BasicBlock: type, comptime FusionInfo: type) type {
    return struct {
        /// PCs of the PUSH1..PUSH32 instructions that are not part of a fusion.
        push_pcs: []PcType,
        /// PCs of the JUMPDEST instructions, ascending.
        jumpdests: []PcType,
        /// `[start, end)` ranges delimited by the JUMPDESTs.
        basic_blocks: []const BasicBlock,
        /// JUMPDEST PC -> static destination of the `PUSH dest JUMP` or
        /// `PUSH cond PUSH dest JUMPI` that directly follows it. Only destinations
        /// that are JUMPDESTs are kept.
        jump_fusions: std.AutoHashMap(PcType, PcType),
        /// PC -> constant-fold or ISZERO/JUMPI fusion starting there.
        advanced_fusions: std.AutoHashMap(PcType, FusionInfo),

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.push_pcs);
            allocator.free(self.jumpdests);
            allocator.free(self.basic_blocks);
            self.jump_fusions.deinit();
            self.advanced_fusions.deinit();
        }
    };
}

fn isPush(opcode: u8) bool {
    return opcode >= op_push1 and opcode <= op_push32;
}

/// Number of immediate bytes of a PUSH1..PUSH32 opcode.
fn pushSize(opcode: u8) usize {
    return @as(usize, opcode - op_push1) + 1;
}

/// Immediate of the PUSH at `push_pc` as a program counter. The immediate is decoded
/// at its full 256-bit width and then range-checked, so a value above
/// `maxInt(PcType)` is rejected instead of losing its high bits. Null as well when
/// the end of the code truncates the immediate.
fn pushTarget(comptime PcType: type, code: []const u8, push_pc: usize) ?PcType {
    const end = push_pc + 1 + pushSize(code[push_pc]);
    if (end > code.len) return null;
    var value: u256 = 0;
    for (code[push_pc + 1 .. end]) |byte| value = (value << 8) | byte;
    return std.math.cast(PcType, value);
}

/// Static destination of the jump that directly follows the JUMPDEST at `jumpdest_pc`:
/// `JUMPDEST PUSH dest JUMP`, or `JUMPDEST PUSH cond PUSH dest JUMPI`. JUMPI pops the
/// destination first, so it is the second PUSH (the top of the stack), not the first.
fn staticJumpTarget(comptime PcType: type, code: []const u8, jumpdest_pc: usize) ?PcType {
    const first_push = jumpdest_pc + 1;
    if (first_push >= code.len or !isPush(code[first_push])) return null;
    const after_first = first_push + 1 + pushSize(code[first_push]);
    if (after_first >= code.len) return null;
    if (code[after_first] == op_jump) return pushTarget(PcType, code, first_push);

    if (!isPush(code[after_first])) return null;
    const jumpi_pc = after_first + 1 + pushSize(code[after_first]);
    if (jumpi_pc >= code.len or code[jumpi_pc] != op_jumpi) return null;
    return pushTarget(PcType, code, after_first);
}

/// `PUSH1 a PUSH1 b ADD|SUB|MUL` and `PUSH1 a PUSH1 b PUSH1 s SHL SUB`, folded to one
/// constant. The EVM computes `top OP second` and `b` is on top, so SUB yields `b - a`.
fn constantFold(comptime FusionInfo: type, code: []const u8, position: usize) ?FusionInfo {
    if (code.len - position < 5) return null;
    if (code[position] != op_push1 or code[position + 2] != op_push1) return null;
    const first: u256 = code[position + 1];
    const second: u256 = code[position + 3];

    var length: usize = 5;
    const folded: u256 = switch (code[position + 4]) {
        op_add => first +% second,
        op_sub => second -% first,
        op_mul => first *% second,
        op_push1 => shifted: {
            // Stack before SHL: [first, second, shift (top)], so SHL yields second << shift.
            // Stack before SUB: [first, shifted (top)], so SUB yields shifted - first.
            if (code.len - position < 8) return null;
            if (code[position + 6] != op_shl or code[position + 7] != op_sub) return null;
            length = 8;
            break :shifted (second << code[position + 5]) -% first;
        },
        else => return null,
    };
    return .{ .fusion_type = .constant_fold, .original_length = @intCast(length), .folded_value = folded };
}

/// `ISZERO PUSHn dest JUMPI`.
fn iszeroJumpi(comptime FusionInfo: type, code: []const u8, position: usize) ?FusionInfo {
    if (code.len - position < 3) return null;
    if (code[position] != op_iszero or !isPush(code[position + 1])) return null;
    const jumpi_pc = position + 2 + pushSize(code[position + 1]);
    if (jumpi_pc >= code.len or code[jumpi_pc] != op_jumpi) return null;
    return .{ .fusion_type = .iszero_jumpi, .original_length = @intCast(jumpi_pc + 1 - position) };
}

/// Drop every jump fusion whose destination is not a JUMPDEST.
fn retainValidJumpFusions(
    comptime PcType: type,
    allocator: std.mem.Allocator,
    jump_fusions: *std.AutoHashMap(PcType, PcType),
    jumpdests: []const PcType,
) std.mem.Allocator.Error!void {
    var invalid = std.ArrayList(PcType).empty;
    defer invalid.deinit(allocator);
    var entries = jump_fusions.iterator();
    while (entries.next()) |entry| {
        if (std.mem.indexOfScalar(PcType, jumpdests, entry.value_ptr.*) == null) {
            try invalid.append(allocator, entry.key_ptr.*);
        }
    }
    for (invalid.items) |source_pc| _ = jump_fusions.remove(source_pc);
}

/// One `[start, end)` block per JUMPDEST-delimited range of the code.
fn splitBasicBlocks(
    comptime PcType: type,
    comptime BasicBlock: type,
    allocator: std.mem.Allocator,
    jumpdests: []const PcType,
    code_len: PcType,
) std.mem.Allocator.Error![]BasicBlock {
    var blocks = std.ArrayList(BasicBlock).empty;
    errdefer blocks.deinit(allocator);
    var block_start: PcType = 0;
    for (jumpdests) |jumpdest| {
        if (jumpdest > block_start) {
            try blocks.append(allocator, .{ .start = block_start, .end = jumpdest });
            block_start = jumpdest;
        }
    }
    if (block_start < code_len) try blocks.append(allocator, .{ .start = block_start, .end = code_len });
    return blocks.toOwnedSlice(allocator);
}

/// Analyze `code` in one pass: PUSH and JUMPDEST positions, JUMPDEST-delimited blocks,
/// static jumps that directly follow a JUMPDEST, and constant-fold / ISZERO-JUMPI fusions.
///
/// `BasicBlock` needs `start` and `end` fields of `PcType`. `FusionInfo` needs
/// `fusion_type` (an enum with `constant_fold` and `iszero_jumpi`), `original_length`
/// (an integer of at least 8 bits) and a defaulted-or-assignable `folded_value: u256`.
pub fn bytecodeAnalyze(
    comptime PcType: type,
    comptime BasicBlock: type,
    comptime FusionInfo: type,
    allocator: std.mem.Allocator,
    code: []const u8,
) AnalyzeError!Analysis(PcType, BasicBlock, FusionInfo) {
    const code_len = std.math.cast(PcType, code.len) orelse return error.CodeTooLarge;

    var push_list = std.ArrayList(PcType).empty;
    defer push_list.deinit(allocator);
    var jumpdest_list = std.ArrayList(PcType).empty;
    defer jumpdest_list.deinit(allocator);
    var jump_fusions = std.AutoHashMap(PcType, PcType).init(allocator);
    errdefer jump_fusions.deinit();
    var advanced_fusions = std.AutoHashMap(PcType, FusionInfo).init(allocator);
    errdefer advanced_fusions.deinit();

    // `pc < code.len <= maxInt(PcType)` inside the loop, so every `@intCast(pc)` fits.
    // Each step advances by at most 33 bytes in `usize` and is clamped to the end of
    // the code: a PUSH truncated by the end cannot carry `pc` past it.
    var pc: usize = 0;
    while (pc < code.len) {
        const opcode = code[pc];
        var step: usize = 1;
        if (constantFold(FusionInfo, code, pc) orelse iszeroJumpi(FusionInfo, code, pc)) |fusion| {
            try advanced_fusions.put(@intCast(pc), fusion);
            step = fusion.original_length;
        } else if (isPush(opcode)) {
            try push_list.append(allocator, @intCast(pc));
            step = 1 + pushSize(opcode);
        } else if (opcode == op_jumpdest) {
            try jumpdest_list.append(allocator, @intCast(pc));
            if (staticJumpTarget(PcType, code, pc)) |target| try jump_fusions.put(@intCast(pc), target);
        }
        pc = @min(pc + step, code.len);
    }

    try retainValidJumpFusions(PcType, allocator, &jump_fusions, jumpdest_list.items);
    const basic_blocks = try splitBasicBlocks(PcType, BasicBlock, allocator, jumpdest_list.items, code_len);
    errdefer allocator.free(basic_blocks);
    const push_pcs = try push_list.toOwnedSlice(allocator);
    errdefer allocator.free(push_pcs);
    const jumpdests = try jumpdest_list.toOwnedSlice(allocator);

    return .{
        .push_pcs = push_pcs,
        .jumpdests = jumpdests,
        .basic_blocks = basic_blocks,
        .jump_fusions = jump_fusions,
        .advanced_fusions = advanced_fusions,
    };
}

const testing = std.testing;

const TestBlock = struct { start: u16, end: u16 };
const TestFusion = struct {
    fusion_type: enum { constant_fold, iszero_jumpi },
    original_length: u16,
    folded_value: u256 = 0,
};

test "bytecodeAnalyze records pushes, jumpdests and blocks" {
    // PUSH1 5; JUMP; JUMPDEST; PUSH2 0x0102; JUMPDEST; STOP
    const code = [_]u8{ 0x60, 0x05, 0x56, 0x5b, 0x61, 0x01, 0x02, 0x5b, 0x00 };
    var analysis = try bytecodeAnalyze(u16, TestBlock, TestFusion, testing.allocator, &code);
    defer analysis.deinit(testing.allocator);

    try testing.expectEqualSlices(u16, &.{ 0, 4 }, analysis.push_pcs);
    try testing.expectEqualSlices(u16, &.{ 3, 7 }, analysis.jumpdests);
    try testing.expectEqual(@as(usize, 3), analysis.basic_blocks.len);
    try testing.expectEqual(TestBlock{ .start = 0, .end = 3 }, analysis.basic_blocks[0]);
    try testing.expectEqual(TestBlock{ .start = 3, .end = 7 }, analysis.basic_blocks[1]);
    try testing.expectEqual(TestBlock{ .start = 7, .end = 9 }, analysis.basic_blocks[2]);
    try testing.expectEqual(@as(usize, 0), analysis.jump_fusions.count());
    try testing.expectEqual(@as(usize, 0), analysis.advanced_fusions.count());
}

test "bytecodeAnalyze accepts empty code" {
    var analysis = try bytecodeAnalyze(u16, TestBlock, TestFusion, testing.allocator, &.{});
    defer analysis.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), analysis.push_pcs.len);
    try testing.expectEqual(@as(usize, 0), analysis.jumpdests.len);
    try testing.expectEqual(@as(usize, 0), analysis.basic_blocks.len);
}

test "bytecodeAnalyze resolves JUMPDEST PUSH JUMP to a JUMPDEST only" {
    // JUMPDEST; PUSH1 4; JUMP; JUMPDEST; STOP
    const valid = [_]u8{ 0x5b, 0x60, 0x04, 0x56, 0x5b, 0x00 };
    var analysis = try bytecodeAnalyze(u16, TestBlock, TestFusion, testing.allocator, &valid);
    defer analysis.deinit(testing.allocator);
    try testing.expectEqual(@as(?u16, 4), analysis.jump_fusions.get(0));

    // The destination 5 is STOP, not a JUMPDEST.
    const invalid = [_]u8{ 0x5b, 0x60, 0x05, 0x56, 0x5b, 0x00 };
    var rejected = try bytecodeAnalyze(u16, TestBlock, TestFusion, testing.allocator, &invalid);
    defer rejected.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), rejected.jump_fusions.count());
}

test "W3-12: bytecodeAnalyze takes the JUMPI destination from the second PUSH" {
    // JUMPDEST; PUSH1 1 (condition); PUSH1 8 (destination); JUMPI; STOP; STOP; JUMPDEST; STOP
    // PC 1 is a PUSH1 operand position, never a JUMPDEST, so decoding the condition
    // as the destination would drop the fusion.
    const code = [_]u8{ 0x5b, 0x60, 0x01, 0x60, 0x08, 0x57, 0x00, 0x00, 0x5b, 0x00 };
    var analysis = try bytecodeAnalyze(u16, TestBlock, TestFusion, testing.allocator, &code);
    defer analysis.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), analysis.jump_fusions.count());
    try testing.expectEqual(@as(?u16, 8), analysis.jump_fusions.get(0));

    // Condition 8 names a JUMPDEST and destination 7 does not: nothing may be recorded.
    const swapped = [_]u8{ 0x5b, 0x60, 0x08, 0x60, 0x07, 0x57, 0x00, 0x00, 0x5b, 0x00 };
    var rejected = try bytecodeAnalyze(u16, TestBlock, TestFusion, testing.allocator, &swapped);
    defer rejected.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), rejected.jump_fusions.count());
}

test "W3-12: bytecodeAnalyze rejects a PUSH3 destination above the PC range" {
    // JUMPDEST; PUSH3 0x010006; JUMP; JUMPDEST (pc 6); STOP. Truncated to 16 bits the
    // destination reads 6, which is a JUMPDEST; at full width it is out of range.
    const code = [_]u8{ 0x5b, 0x62, 0x01, 0x00, 0x06, 0x56, 0x5b, 0x00 };
    var analysis = try bytecodeAnalyze(u16, TestBlock, TestFusion, testing.allocator, &code);
    defer analysis.deinit(testing.allocator);
    try testing.expectEqualSlices(u16, &.{ 0, 6 }, analysis.jumpdests);
    try testing.expectEqual(@as(usize, 0), analysis.jump_fusions.count());

    // The same destination through JUMPI: JUMPDEST; PUSH1 1; PUSH3 0x010008; JUMPI; JUMPDEST
    const conditional = [_]u8{ 0x5b, 0x60, 0x01, 0x62, 0x01, 0x00, 0x08, 0x57, 0x5b, 0x00 };
    var conditional_analysis = try bytecodeAnalyze(u16, TestBlock, TestFusion, testing.allocator, &conditional);
    defer conditional_analysis.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), conditional_analysis.jump_fusions.count());

    // In range, the three-byte immediate is accepted: PUSH3 0x000006.
    const in_range = [_]u8{ 0x5b, 0x62, 0x00, 0x00, 0x06, 0x56, 0x5b, 0x00 };
    var accepted = try bytecodeAnalyze(u16, TestBlock, TestFusion, testing.allocator, &in_range);
    defer accepted.deinit(testing.allocator);
    try testing.expectEqual(@as(?u16, 6), accepted.jump_fusions.get(0));
}

test "W3-12: bytecodeAnalyze never advances the PC past the end of the code" {
    const Block8 = struct { start: u8, end: u8 };
    const Fusion8 = struct {
        fusion_type: enum { constant_fold, iszero_jumpi },
        original_length: u8,
        folded_value: u256 = 0,
    };
    // 255 bytes ending in PUSH32 with no immediate: 254 + 33 does not fit `u8`.
    var code: [255]u8 = @splat(0x00);
    code[254] = 0x7f;
    var analysis = try bytecodeAnalyze(u8, Block8, Fusion8, testing.allocator, &code);
    defer analysis.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{254}, analysis.push_pcs);
    try testing.expectEqual(Block8{ .start = 0, .end = 255 }, analysis.basic_blocks[0]);

    // A JUMPDEST followed by a PUSH truncated by the end of the code.
    const truncated = [_]u8{ 0x5b, 0x61, 0x00 };
    var truncated_analysis = try bytecodeAnalyze(u8, Block8, Fusion8, testing.allocator, &truncated);
    defer truncated_analysis.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), truncated_analysis.jump_fusions.count());

    // Code that `PcType` cannot index is an error, not a wrapped counter.
    const too_long: [256]u8 = @splat(0x5b);
    try testing.expectError(
        error.CodeTooLarge,
        bytecodeAnalyze(u8, Block8, Fusion8, testing.allocator, &too_long),
    );
}

test "W3-12: bytecodeAnalyze folds SUB as top minus second" {
    // PUSH1 3; PUSH1 10; SUB leaves 10 - 3 = 7 (10 is on top).
    const code = [_]u8{ 0x60, 0x03, 0x60, 0x0a, 0x03 };
    var analysis = try bytecodeAnalyze(u16, TestBlock, TestFusion, testing.allocator, &code);
    defer analysis.deinit(testing.allocator);
    const fusion = analysis.advanced_fusions.get(0).?;
    try testing.expectEqual(.constant_fold, fusion.fusion_type);
    try testing.expectEqual(@as(u16, 5), fusion.original_length);
    try testing.expectEqual(@as(u256, 7), fusion.folded_value);

    // PUSH1 10; PUSH1 3; SUB wraps: 3 - 10 = 2^256 - 7.
    const wrapping = [_]u8{ 0x60, 0x0a, 0x60, 0x03, 0x03 };
    var wrapped = try bytecodeAnalyze(u16, TestBlock, TestFusion, testing.allocator, &wrapping);
    defer wrapped.deinit(testing.allocator);
    try testing.expectEqual(@as(u256, 0) -% 7, wrapped.advanced_fusions.get(0).?.folded_value);

    // PUSH1 1; PUSH1 1; PUSH1 4; SHL; SUB: (1 << 4) - 1 = 15.
    const shifted = [_]u8{ 0x60, 0x01, 0x60, 0x01, 0x60, 0x04, 0x1b, 0x03 };
    var shift_analysis = try bytecodeAnalyze(u16, TestBlock, TestFusion, testing.allocator, &shifted);
    defer shift_analysis.deinit(testing.allocator);
    const shift_fusion = shift_analysis.advanced_fusions.get(0).?;
    try testing.expectEqual(@as(u16, 8), shift_fusion.original_length);
    try testing.expectEqual(@as(u256, 15), shift_fusion.folded_value);
}

test "bytecodeAnalyze folds ADD and MUL and fuses ISZERO JUMPI" {
    // PUSH1 5; PUSH1 3; ADD; PUSH1 5; PUSH1 3; MUL; ISZERO; PUSH1 0; JUMPI
    const code = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01, 0x60, 0x05, 0x60, 0x03, 0x02, 0x15, 0x60, 0x00, 0x57 };
    var analysis = try bytecodeAnalyze(u16, TestBlock, TestFusion, testing.allocator, &code);
    defer analysis.deinit(testing.allocator);
    try testing.expectEqual(@as(u256, 8), analysis.advanced_fusions.get(0).?.folded_value);
    try testing.expectEqual(@as(u256, 15), analysis.advanced_fusions.get(5).?.folded_value);
    const iszero = analysis.advanced_fusions.get(10).?;
    try testing.expectEqual(.iszero_jumpi, iszero.fusion_type);
    try testing.expectEqual(@as(u16, 4), iszero.original_length);
    try testing.expectEqual(@as(usize, 0), analysis.push_pcs.len);
}

test "bytecodeAnalyze frees everything when an allocation fails" {
    const code = [_]u8{ 0x5b, 0x60, 0x01, 0x60, 0x08, 0x57, 0x60, 0x03, 0x5b, 0x60, 0x03, 0x60, 0x0a, 0x03 };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var analysis = bytecodeAnalyze(u16, TestBlock, TestFusion, failing.allocator(), &code) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        analysis.deinit(failing.allocator());
        break;
    }
    try testing.expect(fail_index > 0);
}
