const std = @import("std");
const builtin = @import("builtin");
const Opcode = @import("opcode.zig").Opcode;

/// Single-pass bytecode analyzer extracted from bytecode.zig
/// Renamed to bytecodeAnalyze but otherwise identical behavior/signature.
pub fn bytecodeAnalyze(
    comptime PcType: type,
    comptime BasicBlock: type,
    comptime FusionInfo: type,
    allocator: std.mem.Allocator,
    code: []const u8,
) !struct {
    push_pcs: []PcType,
    jumpdests: []PcType,
    basic_blocks: []const BasicBlock,
    jump_fusions: std.AutoHashMap(PcType, PcType),
    advanced_fusions: std.AutoHashMap(PcType, FusionInfo),
} {
    const checkConstantFoldingPatternWithFusion = struct {
        fn check(bytecode: []const u8, position: PcType) ?FusionInfo {
            if (position + 4 >= bytecode.len) return null;

            if (bytecode[position] != @intFromEnum(Opcode.PUSH1)) return null;
            const value1 = bytecode[position + 1];

            if (bytecode[position + 2] != @intFromEnum(Opcode.PUSH1)) return null;
            const value2 = bytecode[position + 3];

            const arith_op = bytecode[position + 4];
            var folded_value: u256 = undefined;
            var sequence_length: PcType = 5;

            switch (arith_op) {
                @intFromEnum(Opcode.ADD) => {
                    folded_value = @as(u256, value1) +% @as(u256, value2);
                },
                @intFromEnum(Opcode.SUB) => {
                    folded_value = @as(u256, value1) -% @as(u256, value2);
                },
                @intFromEnum(Opcode.MUL) => {
                    folded_value = @as(u256, value1) *% @as(u256, value2);
                },
                @intFromEnum(Opcode.SHL) => {
                    if (position + 7 < bytecode.len and 
                        bytecode[position + 4] == @intFromEnum(Opcode.PUSH1) and
                        bytecode[position + 6] == @intFromEnum(Opcode.SHL) and
                        bytecode[position + 7] == @intFromEnum(Opcode.SUB)) {
                        const shift_amount = bytecode[position + 5];
                        const shifted: u256 = if (shift_amount < 256)
                            @as(u256, value2) << @as(u8, @intCast(shift_amount))
                        else
                            0;
                        folded_value = @as(u256, value1) -% shifted;
                        sequence_length = 8;
                    } else {
                        return null;
                    }
                },
                else => return null,
            }

            return FusionInfo{
                .fusion_type = .constant_fold,
                .original_length = sequence_length,
                .folded_value = folded_value,
            };
        }
    }.check;

    const checkNPushPattern = struct {
        fn check(bytecode: []const u8, position: PcType, n: u8) ?FusionInfo {
            if (position + n > bytecode.len) return null;

            var current_pc = position;
            var total_length: PcType = 0;

            var i: u8 = 0;
            while (i < n) : (i += 1) {
                if (current_pc >= bytecode.len) return null;
                const op = bytecode[current_pc];
                if (op < @intFromEnum(Opcode.PUSH1) or op > @intFromEnum(Opcode.PUSH32)) {
                    return null;
                }
                const push_size = op - @intFromEnum(Opcode.PUSH1) + 1;
                current_pc += 1 + push_size;
                total_length += 1 + push_size;
            }

            return FusionInfo{
                .fusion_type = .multi_push,
                .original_length = total_length,
                .count = n,
            };
        }
    }.check;

    const checkNPopPattern = struct {
        fn check(bytecode: []const u8, position: PcType, n: u8) ?FusionInfo {
            if (position + n > bytecode.len) return null;

            var i: u8 = 0;
            while (i < n) : (i += 1) {
                if (bytecode[position + i] != @intFromEnum(Opcode.POP)) {
                    return null;
                }
            }

            return FusionInfo{
                .fusion_type = .multi_pop,
                .original_length = n,
                .count = n,
            };
        }
    }.check;

    const checkIszeroJumpiFusion = struct {
        fn check(bytecode: []const u8, position: PcType) ?FusionInfo {
            if (position + 2 >= bytecode.len) return null;
            if (bytecode[position] != @intFromEnum(Opcode.ISZERO)) return null;

            const push_pc = position + 1;
            const push_op = bytecode[push_pc];
            if (push_op < @intFromEnum(Opcode.PUSH1) or push_op > @intFromEnum(Opcode.PUSH32)) {
                return null;
            }

            const push_size = push_op - @intFromEnum(Opcode.PUSH1) + 1;
            const jumpi_pc = push_pc + 1 + push_size;

            if (jumpi_pc >= bytecode.len or bytecode[jumpi_pc] != @intFromEnum(Opcode.JUMPI)) {
                return null;
            }

            return FusionInfo{
                .fusion_type = .iszero_jumpi,
                .original_length = jumpi_pc + 1 - position,
            };
        }
    }.check;

    const checkDup2MstorePushFusion = struct {
        fn check(bytecode: []const u8, position: PcType) ?FusionInfo {
            if (position + 3 >= bytecode.len) return null;
            if (bytecode[position] != @intFromEnum(Opcode.DUP2)) return null;
            if (bytecode[position + 1] != @intFromEnum(Opcode.MSTORE)) return null;

            const push_pc = position + 2;
            const push_op = bytecode[push_pc];
            if (push_op < @intFromEnum(Opcode.PUSH1) or push_op > @intFromEnum(Opcode.PUSH32)) {
                return null;
            }

            const push_size = push_op - @intFromEnum(Opcode.PUSH1) + 1;

            return FusionInfo{
                .fusion_type = .dup2_mstore_push,
                .original_length = 3 + push_size,
            };
        }
    }.check;

    var push_list = std.ArrayList(PcType){};
    defer push_list.deinit(allocator);

    var jumpdest_list = std.ArrayList(PcType){};
    defer jumpdest_list.deinit(allocator);

    var jump_fusions = std.AutoHashMap(PcType, PcType).init(allocator);
    errdefer jump_fusions.deinit();

    var advanced_fusions = std.AutoHashMap(PcType, FusionInfo).init(allocator);
    errdefer advanced_fusions.deinit();

    var pc: PcType = 0;
    while (pc < code.len) {
        const opcode = code[pc];

        if (checkConstantFoldingPatternWithFusion(code, pc)) |fusion_info| {
            try advanced_fusions.put(pc, fusion_info);
            pc += fusion_info.original_length;
            continue;
        }
        if (checkNPushPattern(code, pc, 3)) |fusion_info| {
            try advanced_fusions.put(pc, fusion_info);
            pc += fusion_info.original_length;
            continue;
        }
        if (checkNPopPattern(code, pc, 3)) |fusion_info| {
            try advanced_fusions.put(pc, fusion_info);
            pc += fusion_info.original_length;
            continue;
        }
        if (checkIszeroJumpiFusion(code, pc)) |fusion_info| {
            try advanced_fusions.put(pc, fusion_info);
            pc += fusion_info.original_length;
            continue;
        }
        if (checkDup2MstorePushFusion(code, pc)) |fusion_info| {
            try advanced_fusions.put(pc, fusion_info);
            pc += fusion_info.original_length;
            continue;
        }
        if (checkNPushPattern(code, pc, 2)) |fusion_info| {
            try advanced_fusions.put(pc, fusion_info);
            pc += fusion_info.original_length;
            continue;
        }
        if (checkNPopPattern(code, pc, 2)) |fusion_info| {
            try advanced_fusions.put(pc, fusion_info);
            pc += fusion_info.original_length;
            continue;
        }

        if (opcode >= @intFromEnum(Opcode.PUSH1) and opcode <= @intFromEnum(Opcode.PUSH32)) {
            try push_list.append(allocator, pc);
            const push_size = opcode - @intFromEnum(Opcode.PUSH1) + 1;
            pc += 1 + push_size;
        } else if (opcode == @intFromEnum(Opcode.JUMPDEST)) {
            try jumpdest_list.append(allocator, pc);

            if (pc + 1 < code.len) {
                const next_opcode = code[pc + 1];
                if (next_opcode >= @intFromEnum(Opcode.PUSH1) and next_opcode <= @intFromEnum(Opcode.PUSH32)) {
                    const push_size = next_opcode - @intFromEnum(Opcode.PUSH1) + 1;
                    const jump_pc = pc + 2 + push_size;

                    if (jump_pc < code.len and code[jump_pc] == @intFromEnum(Opcode.JUMP)) {
                        if (pc + 2 + push_size <= code.len) {
                            var target: PcType = 0;
                            for (code[pc + 2..pc + 2 + push_size]) |byte| {
                                target = (target << 8) | byte;
                            }
                            if (target <= std.math.maxInt(PcType)) {
                                try jump_fusions.put(pc, @intCast(target));
                            }
                        }
                    } else if (jump_pc + 1 < code.len) {
                        const next_next_opcode = code[jump_pc];
                        if (next_next_opcode >= @intFromEnum(Opcode.PUSH1) and next_next_opcode <= @intFromEnum(Opcode.PUSH32)) {
                            const push2_size = next_next_opcode - @intFromEnum(Opcode.PUSH1) + 1;
                            const jumpi_pc = jump_pc + 1 + push2_size;

                            if (jumpi_pc < code.len and code[jumpi_pc] == @intFromEnum(Opcode.JUMPI)) {
                                if (pc + 2 + push_size <= code.len) {
                                    var target: PcType = 0;
                                    for (code[pc + 2..pc + 2 + push_size]) |byte| {
                                        target = (target << 8) | byte;
                                    }
                                    if (target <= std.math.maxInt(PcType)) {
                                        try jump_fusions.put(pc, @intCast(target));
                                    }
                                }
                            }
                        }
                    }
                }
            }
            pc += 1;
        } else {
            pc += 1;
        }
    }

    const push_pcs = try push_list.toOwnedSlice(allocator);
    errdefer allocator.free(push_pcs);

    const jumpdests = try jumpdest_list.toOwnedSlice(allocator);
    errdefer allocator.free(jumpdests);

    var iter = jump_fusions.iterator();
    var to_remove = std.ArrayList(PcType){};
    defer to_remove.deinit(allocator);
    while (iter.next()) |entry| {
        const target = entry.value_ptr.*;
        var valid = false;
        for (jumpdests) |jd| {
            if (jd == target) { valid = true; break; }
        }
        if (!valid) try to_remove.append(allocator, entry.key_ptr.*);
    }
    for (to_remove.items) |key| { _ = jump_fusions.remove(key); }

    var blocks = std.ArrayList(BasicBlock){};
    defer blocks.deinit(allocator);
    var block_start: PcType = 0;
    for (jumpdests) |jd| {
        if (jd > block_start) {
            try blocks.append(allocator, .{ .start = block_start, .end = jd });
            block_start = jd;
        }
    }
    if (block_start < code.len) {
        try blocks.append(allocator, .{ .start = block_start, .end = @intCast(code.len) });
    }
    const basic_blocks = try blocks.toOwnedSlice(allocator);

    return .{
        .push_pcs = push_pcs,
        .jumpdests = jumpdests,
        .basic_blocks = basic_blocks,
        .jump_fusions = jump_fusions,
        .advanced_fusions = advanced_fusions,
    };
}

const testing = std.testing;

test "bytecode analyze - single-pass analyzer" {
    const allocator = testing.allocator;
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x01,
        @intFromEnum(Opcode.PUSH2), 0x02, 0x03,
        @intFromEnum(Opcode.ADD),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 2), analysis.push_pcs.len);
    try testing.expectEqual(@as(BytecodeType.PcType, 0), analysis.push_pcs[0]);
    try testing.expectEqual(@as(BytecodeType.PcType, 2), analysis.push_pcs[1]);
}

test "bytecode analyze - empty bytecode" {
    const allocator = testing.allocator;
    const code: []const u8 = &.{};

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 0), analysis.push_pcs.len);
    try testing.expectEqual(@as(usize, 0), analysis.jumpdests.len);
    try testing.expectEqual(@as(usize, 0), analysis.basic_blocks.len);
    try testing.expectEqual(@as(usize, 0), analysis.jump_fusions.count());
    try testing.expectEqual(@as(usize, 0), analysis.advanced_fusions.count());
}

test "bytecode analyze - jumpdest detection" {
    const allocator = testing.allocator;
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x05,
        @intFromEnum(Opcode.JUMP),
        @intFromEnum(Opcode.JUMPDEST), // pc = 4
        @intFromEnum(Opcode.PUSH1), 0x08,
        @intFromEnum(Opcode.JUMPDEST), // pc = 7
        @intFromEnum(Opcode.STOP),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 2), analysis.jumpdests.len);
    try testing.expectEqual(@as(BytecodeType.PcType, 3), analysis.jumpdests[0]);
    try testing.expectEqual(@as(BytecodeType.PcType, 6), analysis.jumpdests[1]);
}

test "bytecode analyze - constant folding fusion ADD" {
    const allocator = testing.allocator;
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x05,  // Push 5
        @intFromEnum(Opcode.PUSH1), 0x03,  // Push 3
        @intFromEnum(Opcode.ADD),          // Should fold to 8
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 1), analysis.advanced_fusions.count());
    const fusion = analysis.advanced_fusions.get(0).?;
    try testing.expectEqual(BytecodeType.FusionInfo.FusionType.constant_fold, fusion.fusion_type);
    try testing.expectEqual(@as(u256, 8), fusion.folded_value);
    try testing.expectEqual(@as(BytecodeType.PcType, 5), fusion.original_length);
}

test "bytecode analyze - constant folding fusion SUB" {
    const allocator = testing.allocator;
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x0A,  // Push 10
        @intFromEnum(Opcode.PUSH1), 0x03,  // Push 3
        @intFromEnum(Opcode.SUB),          // Should fold to 7
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 1), analysis.advanced_fusions.count());
    const fusion = analysis.advanced_fusions.get(0).?;
    try testing.expectEqual(BytecodeType.FusionInfo.FusionType.constant_fold, fusion.fusion_type);
    try testing.expectEqual(@as(u256, 7), fusion.folded_value);
}

test "bytecode analyze - constant folding fusion MUL" {
    const allocator = testing.allocator;
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x04,  // Push 4
        @intFromEnum(Opcode.PUSH1), 0x06,  // Push 6
        @intFromEnum(Opcode.MUL),          // Should fold to 24
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 1), analysis.advanced_fusions.count());
    const fusion = analysis.advanced_fusions.get(0).?;
    try testing.expectEqual(BytecodeType.FusionInfo.FusionType.constant_fold, fusion.fusion_type);
    try testing.expectEqual(@as(u256, 24), fusion.folded_value);
}

test "bytecode analyze - multi push fusion (3 pushes)" {
    const allocator = testing.allocator;
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x01,
        @intFromEnum(Opcode.PUSH1), 0x02,
        @intFromEnum(Opcode.PUSH1), 0x03,
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 1), analysis.advanced_fusions.count());
    const fusion = analysis.advanced_fusions.get(0).?;
    try testing.expectEqual(BytecodeType.FusionInfo.FusionType.multi_push, fusion.fusion_type);
    try testing.expectEqual(@as(u8, 3), fusion.count);
    try testing.expectEqual(@as(BytecodeType.PcType, 6), fusion.original_length);
}

test "bytecode analyze - multi push fusion (2 pushes)" {
    const allocator = testing.allocator;
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH2), 0x01, 0x23,  // 3 bytes
        @intFromEnum(Opcode.PUSH1), 0x04,        // 2 bytes
        @intFromEnum(Opcode.ADD), // This prevents 3-push fusion, so should get 2-push fusion
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 1), analysis.advanced_fusions.count());
    const fusion = analysis.advanced_fusions.get(0).?;
    try testing.expectEqual(BytecodeType.FusionInfo.FusionType.multi_push, fusion.fusion_type);
    try testing.expectEqual(@as(u8, 2), fusion.count);
    try testing.expectEqual(@as(BytecodeType.PcType, 5), fusion.original_length);
}

test "bytecode analyze - multi pop fusion (3 pops)" {
    const allocator = testing.allocator;
    const code = [_]u8{
        @intFromEnum(Opcode.POP),
        @intFromEnum(Opcode.POP),
        @intFromEnum(Opcode.POP),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 1), analysis.advanced_fusions.count());
    const fusion = analysis.advanced_fusions.get(0).?;
    try testing.expectEqual(BytecodeType.FusionInfo.FusionType.multi_pop, fusion.fusion_type);
    try testing.expectEqual(@as(u8, 3), fusion.count);
    try testing.expectEqual(@as(BytecodeType.PcType, 3), fusion.original_length);
}

test "bytecode analyze - multi pop fusion (2 pops)" {
    const allocator = testing.allocator;
    const code = [_]u8{
        @intFromEnum(Opcode.POP),
        @intFromEnum(Opcode.POP),
        @intFromEnum(Opcode.ADD), // This prevents 3-pop fusion
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 1), analysis.advanced_fusions.count());
    const fusion = analysis.advanced_fusions.get(0).?;
    try testing.expectEqual(BytecodeType.FusionInfo.FusionType.multi_pop, fusion.fusion_type);
    try testing.expectEqual(@as(u8, 2), fusion.count);
    try testing.expectEqual(@as(BytecodeType.PcType, 2), fusion.original_length);
}

test "bytecode analyze - iszero jumpi fusion" {
    const allocator = testing.allocator;
    const code = [_]u8{
        @intFromEnum(Opcode.ISZERO),
        @intFromEnum(Opcode.PUSH1), 0x06,
        @intFromEnum(Opcode.JUMPI),
        @intFromEnum(Opcode.JUMPDEST),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 1), analysis.advanced_fusions.count());
    const fusion = analysis.advanced_fusions.get(0).?;
    try testing.expectEqual(BytecodeType.FusionInfo.FusionType.iszero_jumpi, fusion.fusion_type);
    try testing.expectEqual(@as(BytecodeType.PcType, 4), fusion.original_length);
}

test "bytecode analyze - dup2 mstore push fusion" {
    const allocator = testing.allocator;
    const code = [_]u8{
        @intFromEnum(Opcode.DUP2),
        @intFromEnum(Opcode.MSTORE),
        @intFromEnum(Opcode.PUSH2), 0x12, 0x34,
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 1), analysis.advanced_fusions.count());
    const fusion = analysis.advanced_fusions.get(0).?;
    try testing.expectEqual(BytecodeType.FusionInfo.FusionType.dup2_mstore_push, fusion.fusion_type);
    try testing.expectEqual(@as(BytecodeType.PcType, 5), fusion.original_length);
}

test "bytecode analyze - jump fusion detection" {
    const allocator = testing.allocator;
    const code = [_]u8{
        @intFromEnum(Opcode.JUMPDEST), // pc = 0
        @intFromEnum(Opcode.PUSH1), 0x06,
        @intFromEnum(Opcode.JUMP),
        @intFromEnum(Opcode.JUMPDEST), // pc = 4
        @intFromEnum(Opcode.STOP),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 1), analysis.jump_fusions.count());
    const target = analysis.jump_fusions.get(0).?;
    try testing.expectEqual(@as(BytecodeType.PcType, 4), target);
}

test "bytecode analyze - invalid jump fusion (target not jumpdest)" {
    const allocator = testing.allocator;
    const code = [_]u8{
        @intFromEnum(Opcode.JUMPDEST), // pc = 0
        @intFromEnum(Opcode.PUSH1), 0x04, // Target is 4, but pc=4 is STOP, not JUMPDEST
        @intFromEnum(Opcode.JUMP),
        @intFromEnum(Opcode.STOP), // pc = 4
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    // Invalid jump should be removed
    try testing.expectEqual(@as(usize, 0), analysis.jump_fusions.count());
}

test "bytecode analyze - basic blocks creation" {
    const allocator = testing.allocator;
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x05, // Block 1: 0-3
        @intFromEnum(Opcode.JUMP),
        @intFromEnum(Opcode.JUMPDEST), // Block 2: 3-6 
        @intFromEnum(Opcode.PUSH1), 0x08,
        @intFromEnum(Opcode.JUMPDEST), // Block 3: 6-8
        @intFromEnum(Opcode.STOP),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 3), analysis.basic_blocks.len);
    try testing.expectEqual(@as(BytecodeType.PcType, 0), analysis.basic_blocks[0].start);
    try testing.expectEqual(@as(BytecodeType.PcType, 3), analysis.basic_blocks[0].end);
    try testing.expectEqual(@as(BytecodeType.PcType, 3), analysis.basic_blocks[1].start);
    try testing.expectEqual(@as(BytecodeType.PcType, 6), analysis.basic_blocks[1].end);
    try testing.expectEqual(@as(BytecodeType.PcType, 6), analysis.basic_blocks[2].start);
    try testing.expectEqual(@as(BytecodeType.PcType, 8), analysis.basic_blocks[2].end);
}

test "bytecode analyze - push sizes edge cases" {
    const allocator = testing.allocator;
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0xFF,  // PUSH1 - smallest
        @intFromEnum(Opcode.PUSH4), 0x12, 0x34, 0x56, 0x78,  // PUSH4 - medium
        @intFromEnum(Opcode.PUSH32), // PUSH32 - largest, followed by 32 bytes
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 3), analysis.push_pcs.len);
    try testing.expectEqual(@as(BytecodeType.PcType, 0), analysis.push_pcs[0]); // PUSH1
    try testing.expectEqual(@as(BytecodeType.PcType, 2), analysis.push_pcs[1]); // PUSH4
    try testing.expectEqual(@as(BytecodeType.PcType, 7), analysis.push_pcs[2]); // PUSH32
}

test "bytecode analyze - complex fusion patterns mixed" {
    const allocator = testing.allocator;
    const code = [_]u8{
        // Constant folding ADD
        @intFromEnum(Opcode.PUSH1), 0x05,
        @intFromEnum(Opcode.PUSH1), 0x03,
        @intFromEnum(Opcode.ADD), // Fusion 1: pc=0, length=5
        
        // Multi-pop
        @intFromEnum(Opcode.POP),  // pc=5
        @intFromEnum(Opcode.POP),
        @intFromEnum(Opcode.POP), // Fusion 2: pc=5, length=3
        
        // Regular instruction
        @intFromEnum(Opcode.STOP), // pc=8
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 2), analysis.advanced_fusions.count());
    
    // Check constant folding fusion
    const fusion1 = analysis.advanced_fusions.get(0).?;
    try testing.expectEqual(BytecodeType.FusionInfo.FusionType.constant_fold, fusion1.fusion_type);
    
    // Check multi-pop fusion
    const fusion2 = analysis.advanced_fusions.get(5).?;
    try testing.expectEqual(BytecodeType.FusionInfo.FusionType.multi_pop, fusion2.fusion_type);
}

test "bytecode analyze - boundary conditions insufficient bytes" {
    const allocator = testing.allocator;
    
    // Test truncated PUSH1 (missing data byte)
    const code1 = [_]u8{@intFromEnum(Opcode.PUSH1)};
    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis1 = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code1);
    defer {
        allocator.free(analysis1.push_pcs);
        allocator.free(analysis1.jumpdests);
        allocator.free(analysis1.basic_blocks);
        analysis1.jump_fusions.deinit();
        analysis1.advanced_fusions.deinit();
    }
    
    // Should still detect the PUSH1 at pc=0, even though it's incomplete
    try testing.expectEqual(@as(usize, 1), analysis1.push_pcs.len);
    try testing.expectEqual(@as(BytecodeType.PcType, 0), analysis1.push_pcs[0]);
    
    // Test truncated constant folding pattern
    const code2 = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x05,
        @intFromEnum(Opcode.PUSH1), // Missing data byte and arithmetic op
    };
    const analysis2 = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code2);
    defer {
        allocator.free(analysis2.push_pcs);
        allocator.free(analysis2.jumpdests);
        allocator.free(analysis2.basic_blocks);
        analysis2.jump_fusions.deinit();
        analysis2.advanced_fusions.deinit();
    }
    
    // Should not detect any constant folding fusion
    try testing.expectEqual(@as(usize, 0), analysis2.advanced_fusions.count());
}

test "bytecode analyze - wrapping arithmetic in constant folding" {
    const allocator = testing.allocator;
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0xFF,  // 255
        @intFromEnum(Opcode.PUSH1), 0x02,  // 2
        @intFromEnum(Opcode.ADD),          // Should wrap to 1
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 1), analysis.advanced_fusions.count());
    const fusion = analysis.advanced_fusions.get(0).?;
    try testing.expectEqual(BytecodeType.FusionInfo.FusionType.constant_fold, fusion.fusion_type);
    try testing.expectEqual(@as(u256, 1), fusion.folded_value); // 255 + 2 = 1 (wrapping)
}

test "bytecode analyze - no fusion patterns present" {
    const allocator = testing.allocator;
    const code = [_]u8{
        @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.MUL),
        @intFromEnum(Opcode.DUP1),
        @intFromEnum(Opcode.SWAP1),
        @intFromEnum(Opcode.STOP),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const analysis = try bytecodeAnalyze(BytecodeType.PcType, BytecodeType.BasicBlock, BytecodeType.FusionInfo, allocator, &code);
    defer {
        allocator.free(analysis.push_pcs);
        allocator.free(analysis.jumpdests);
        allocator.free(analysis.basic_blocks);
        analysis.jump_fusions.deinit();
        analysis.advanced_fusions.deinit();
    }

    try testing.expectEqual(@as(usize, 0), analysis.push_pcs.len);
    try testing.expectEqual(@as(usize, 0), analysis.jumpdests.len);
    try testing.expectEqual(@as(usize, 1), analysis.basic_blocks.len); // One block covering entire bytecode
    try testing.expectEqual(@as(usize, 0), analysis.jump_fusions.count());
    try testing.expectEqual(@as(usize, 0), analysis.advanced_fusions.count());
}

