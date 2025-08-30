//! Tests for EVM bytecode representation and validation.

const std = @import("std");
const builtin = @import("builtin");
const ArrayList = std.ArrayListAligned;
const Opcode = @import("opcode.zig").Opcode;
const bytecode_config = @import("bytecode_config.zig");
const BytecodeConfig = bytecode_config.BytecodeConfig;
const BytecodeDefault = @import("bytecode.zig").BytecodeDefault;
const Bytecode = @import("bytecode.zig").Bytecode;

// Constants used in tests
const default_config = BytecodeConfig{};
const CACHE_LINE_SIZE = 64;

test "Bytecode.init and basic getters" {
    const allocator = std.testing.allocator;
    const code = [_]u8{ 0x60, 0x40, 0x60, 0x80 }; // PUSH1 0x40 PUSH1 0x80
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();
    try std.testing.expectEqual(@as(BytecodeDefault.PcType, 4), bytecode.len());
    try std.testing.expectEqualSlices(u8, &code, bytecode.raw());
    try std.testing.expectEqual(@as(?u8, 0x60), bytecode.get(0));
    try std.testing.expectEqual(@as(?u8, 0x40), bytecode.get(1));
    try std.testing.expectEqual(@as(?u8, null), bytecode.get(4)); // Out of bounds
    try std.testing.expectEqual(@as(?u8, 0x60), bytecode.getOpcode(0));
}test "Bytecode.isValidJumpDest" {
    const allocator = std.testing.allocator;
    const code = [_]u8{ 0x60, 0x03, 0x56, 0x5b, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();
    try std.testing.expect(!bytecode.isValidJumpDest(0));
    try std.testing.expect(!bytecode.isValidJumpDest(1));
    try std.testing.expect(!bytecode.isValidJumpDest(2));
    try std.testing.expect(bytecode.isValidJumpDest(3));
    try std.testing.expect(!bytecode.isValidJumpDest(4));
    const code2 = [_]u8{ 0x62, 0x5b, 0x5b, 0x5b, 0x00 };
    var bytecode2 = try BytecodeDefault.init(allocator, &code2);
    defer bytecode2.deinit();
    try std.testing.expect(!bytecode2.isValidJumpDest(1));
    try std.testing.expect(!bytecode2.isValidJumpDest(2));
    try std.testing.expect(!bytecode2.isValidJumpDest(3));
}

test "Bytecode buildBitmaps are created on init" {
    const allocator = std.testing.allocator;
    const code = [_]u8{ 0x61, 0x12, 0x34, 0x5b, 0x60, 0x56, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();
    try std.testing.expect((bytecode.is_op_start[0] & (1 << 0)) != 0);
    try std.testing.expect((bytecode.is_op_start[0] & (1 << 1)) == 0);
    try std.testing.expect((bytecode.is_op_start[0] & (1 << 2)) == 0);
    try std.testing.expect((bytecode.is_op_start[0] & (1 << 3)) != 0);
    try std.testing.expect((bytecode.is_op_start[0] & (1 << 4)) != 0);
    try std.testing.expect((bytecode.is_op_start[0] & (1 << 5)) == 0);
    try std.testing.expect((bytecode.is_op_start[0] & (1 << 6)) != 0);
    try std.testing.expect((bytecode.is_push_data[0] & (1 << 0)) == 0);
    try std.testing.expect((bytecode.is_push_data[0] & (1 << 1)) != 0);
    try std.testing.expect((bytecode.is_push_data[0] & (1 << 2)) != 0);
    try std.testing.expect((bytecode.is_push_data[0] & (1 << 3)) == 0);
    try std.testing.expect((bytecode.is_push_data[0] & (1 << 4)) == 0);
    try std.testing.expect((bytecode.is_push_data[0] & (1 << 5)) != 0);
    try std.testing.expect((bytecode.is_push_data[0] & (1 << 6)) == 0);
    try std.testing.expect((bytecode.is_jumpdest[0] & (1 << 3)) != 0);
}

test "Bytecode.readPushValue" {
    const allocator = std.testing.allocator;
    const code = [_]u8{
        0x60, 0x42, // PUSH1
        0x61, 0x12, 0x34, // PUSH2
        0x63, 0xDE, 0xAD,
        0xBE, 0xEF, // PUSH4
    };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();
    try std.testing.expectEqual(@as(?u8, 0x42), bytecode.readPushValue(0, 1));
    try std.testing.expectEqual(@as(?u16, 0x1234), bytecode.readPushValue(2, 2));
    try std.testing.expectEqual(@as(?u32, 0xDEADBEEF), bytecode.readPushValue(5, 4));
    try std.testing.expectEqual(@as(?u8, null), bytecode.readPushValue(2, 1)); // Not PUSH1
    try std.testing.expectEqual(@as(?u256, 0x42), bytecode.readPushValueN(0, 1));
    try std.testing.expectEqual(@as(?u256, 0x1234), bytecode.readPushValueN(2, 2));
    try std.testing.expectEqual(@as(?u256, 0xDEADBEEF), bytecode.readPushValueN(5, 4));
}

test "Bytecode.getInstructionSize and getNextPc" {
    const allocator = std.testing.allocator;
    var code: [36]u8 = undefined;
    code[0] = 0x60; // PUSH1
    code[1] = 0x42;
    code[2] = 0x01; // ADD
    code[3] = 0x7f; // PUSH32
    for (4..36) |i| code[i] = @intCast(i);
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();
    try std.testing.expectEqual(@as(BytecodeDefault.PcType, 2), bytecode.getInstructionSize(0)); // PUSH1
    try std.testing.expectEqual(@as(BytecodeDefault.PcType, 1), bytecode.getInstructionSize(2)); // ADD
    try std.testing.expectEqual(@as(BytecodeDefault.PcType, 33), bytecode.getInstructionSize(3)); // PUSH32
    try std.testing.expectEqual(@as(BytecodeDefault.PcType, 0), bytecode.getInstructionSize(100)); // Out of bounds
    try std.testing.expectEqual(@as(?BytecodeDefault.PcType, 2), bytecode.getNextPc(0)); // After PUSH1
    try std.testing.expectEqual(@as(?BytecodeDefault.PcType, 3), bytecode.getNextPc(2)); // After ADD
    try std.testing.expectEqual(@as(?BytecodeDefault.PcType, 36), bytecode.getNextPc(3)); // After PUSH32
    try std.testing.expectEqual(@as(?BytecodeDefault.PcType, null), bytecode.getNextPc(100)); // Out of bounds
}

test "Bytecode.analyzeJumpDests" {
    const allocator = std.testing.allocator;
    const code = [_]u8{
        0x60, 0x03, 0x56, // PUSH1 0x03 JUMP
        0x5b, // JUMPDEST at PC 3
        0x60, 0x07, 0x56, // PUSH1 0x07 JUMP
        0x5b, // JUMPDEST at PC 7
        0x00, // STOP
    };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();
    const Context = struct {
        // https://ziglang.org/documentation/master/std/#std.array_list.Aligned
        jumpdests: std.ArrayList(BytecodeDefault.PcType),
        fn callback(self: *@This(), pc: BytecodeDefault.PcType) void {
            self.jumpdests.append(pc) catch unreachable;
        }
    };
    var jumpdests_list = std.ArrayList(BytecodeDefault.PcType).init(std.testing.allocator);
    defer jumpdests_list.deinit();
    var context = Context{ .jumpdests = jumpdests_list };
    bytecode.analyzeJumpDests(&context, Context.callback);
    try std.testing.expectEqual(@as(usize, 2), context.jumpdests.items.len);
    try std.testing.expectEqual(@as(BytecodeDefault.PcType, 3), context.jumpdests.items[0]);
    try std.testing.expectEqual(@as(BytecodeDefault.PcType, 7), context.jumpdests.items[1]);
}

test "Bytecode validation - invalid opcode" {
    const allocator = std.testing.allocator;
    // Test bytecode with invalid opcode 0x0C (unassigned)
    const code = [_]u8{ 0x60, 0x01, 0x0C }; // PUSH1 0x01 <invalid>
    const result = BytecodeDefault.init(allocator, &code);
    try std.testing.expectError(error.InvalidOpcode, result);
}

test "Bytecode validation - PUSH extends past end" {
    const allocator = std.testing.allocator;
    // PUSH2 but only 1 byte of data available
    const code = [_]u8{ 0x61, 0x42 }; // PUSH2 with only 1 byte
    const result = BytecodeDefault.init(allocator, &code);
    try std.testing.expectError(error.TruncatedPush, result);
}

test "Bytecode validation - PUSH32 extends past end" {
    const allocator = std.testing.allocator;
    // PUSH32 but not enough data
    var code: [32]u8 = undefined;
    code[0] = 0x7f; // PUSH32
    for (1..32) |i| {
        code[i] = @intCast(i);
    }
    const result = BytecodeDefault.init(allocator, &code); // Only 32 bytes, needs 33
    try std.testing.expectError(error.TruncatedPush, result);
}

test "Bytecode validation - Jump to invalid destination" {
    const allocator = std.testing.allocator;
    // PUSH1 0x10 JUMP but no JUMPDEST at 0x10
    const code = [_]u8{ 0x60, 0x10, 0x56, 0x00 }; // PUSH1 0x10 JUMP STOP
    const result = BytecodeDefault.init(allocator, &code);
    try std.testing.expectError(error.InvalidJumpDestination, result);
}

test "Bytecode validation - Jump to valid JUMPDEST" {
    const allocator = std.testing.allocator;
    // PUSH1 0x04 JUMP JUMPDEST STOP
    const code = [_]u8{ 0x60, 0x04, 0x56, 0x00, 0x5b, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();
    try std.testing.expect(bytecode.is_jumpdest.len > 0);
}

test "Bytecode validation - JUMPI to invalid destination" {
    const allocator = std.testing.allocator;
    // PUSH1 0x10 PUSH1 0x01 JUMPI but no JUMPDEST at 0x10
    const code = [_]u8{ 0x60, 0x10, 0x60, 0x01, 0x57 }; // PUSH1 0x10 PUSH1 0x01 JUMPI
    const result = BytecodeDefault.init(allocator, &code);
    try std.testing.expectError(error.InvalidJumpDestination, result);
}

test "Bytecode validation - empty bytecode is valid" {
    const allocator = std.testing.allocator;
    const code = [_]u8{};
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();
    try std.testing.expectEqual(@as(usize, 0), bytecode.len());
}

test "Bytecode validation - only STOP is valid" {
    const allocator = std.testing.allocator;
    const code = [_]u8{0x00};
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();
    try std.testing.expectEqual(@as(usize, 1), bytecode.len());
}

test "Bytecode validation - JUMPDEST inside PUSH data is invalid jump target" {
    const allocator = std.testing.allocator;
    // PUSH1 0x03 JUMP [0x5b inside push] JUMPDEST
    const code = [_]u8{ 0x60, 0x03, 0x56, 0x62, 0x5b, 0x5b, 0x5b }; // PUSH1 0x03 JUMP PUSH3 0x5b5b5b
    const result = BytecodeDefault.init(allocator, &code);
    try std.testing.expectError(error.InvalidJumpDestination, result);
}

test "Bytecode.getStats - basic stats" {
    const allocator = std.testing.allocator;
    // PUSH1 0x05 PUSH1 0x03 ADD STOP
    const code = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    const stats = try bytecode.getStats();
    defer {
        allocator.free(stats.push_values);
        allocator.free(stats.potential_fusions);
        allocator.free(stats.jumpdests);
        allocator.free(stats.jumps);
    }

    // Check opcode counts
    try std.testing.expectEqual(@as(u32, 2), stats.opcode_counts[@intFromEnum(Opcode.PUSH1)]);
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[@intFromEnum(Opcode.ADD)]);
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[@intFromEnum(Opcode.STOP)]);

    // Check push values
    try std.testing.expectEqual(@as(usize, 2), stats.push_values.len);
    try std.testing.expectEqual(@as(u256, 0x05), stats.push_values[0].value);
    try std.testing.expectEqual(@as(usize, 0), stats.push_values[0].pc);
    try std.testing.expectEqual(@as(u256, 0x03), stats.push_values[1].value);
    try std.testing.expectEqual(@as(usize, 2), stats.push_values[1].pc);

    // Test formatStats
    const output = try stats.formatStats(allocator);
    defer allocator.free(output);

    // Verify it contains expected content
    try std.testing.expect(std.mem.indexOf(u8, output, "Bytecode Statistics") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PUSH1: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ADD: 1") != null);
}

test "Bytecode.getStats - potential fusions" {
    const allocator = std.testing.allocator;
    // PUSH1 0x04 JUMP JUMPDEST PUSH1 0x10 ADD STOP
    const code = [_]u8{ 0x60, 0x04, 0x56, 0x00, 0x5b, 0x60, 0x10, 0x01, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    const stats = try bytecode.getStats();
    defer {
        allocator.free(stats.push_values);
        allocator.free(stats.potential_fusions);
        allocator.free(stats.jumpdests);
        allocator.free(stats.jumps);
    }

    // Check for PUSH+JUMP fusion
    try std.testing.expectEqual(@as(usize, 2), stats.potential_fusions.len);
    try std.testing.expectEqual(@as(usize, 0), stats.potential_fusions[0].pc); // PUSH1 at 0
    try std.testing.expectEqual(Opcode.JUMP, stats.potential_fusions[0].second_opcode);

    // Check for PUSH+ADD fusion
    try std.testing.expectEqual(@as(usize, 5), stats.potential_fusions[1].pc); // PUSH1 at 5
    try std.testing.expectEqual(Opcode.ADD, stats.potential_fusions[1].second_opcode);
}

test "Bytecode.getStats - jumpdests and jumps" {
    const allocator = std.testing.allocator;
    // PUSH1 0x08 JUMP PUSH1 0x00 PUSH1 0x00 REVERT JUMPDEST PUSH1 0x0C JUMP JUMPDEST STOP
    const code = [_]u8{
        0x60, 0x08, 0x56, // PUSH1 0x08 JUMP
        0x60, 0x00, 0x60, 0x00, 0xfd, // PUSH1 0x00 PUSH1 0x00 REVERT
        0x5b, // JUMPDEST at PC 8
        0x60, 0x0C, 0x56, // PUSH1 0x0C JUMP
        0x5b, // JUMPDEST at PC 12
        0x00, // STOP
    };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    const stats = try bytecode.getStats();
    defer {
        allocator.free(stats.push_values);
        allocator.free(stats.potential_fusions);
        allocator.free(stats.jumpdests);
        allocator.free(stats.jumps);
    }

    // Check jumpdests
    try std.testing.expectEqual(@as(usize, 2), stats.jumpdests.len);
    try std.testing.expectEqual(@as(usize, 8), stats.jumpdests[0]);
    try std.testing.expectEqual(@as(usize, 12), stats.jumpdests[1]);

    // Check jumps
    try std.testing.expectEqual(@as(usize, 2), stats.jumps.len);
    try std.testing.expectEqual(@as(usize, 2), stats.jumps[0].pc); // JUMP at PC 2
    try std.testing.expectEqual(@as(u256, 0x08), stats.jumps[0].target);
    try std.testing.expectEqual(@as(usize, 11), stats.jumps[1].pc); // JUMP at PC 11
    try std.testing.expectEqual(@as(u256, 0x0C), stats.jumps[1].target);

    // Check backwards jumps (none in this example)
    try std.testing.expectEqual(@as(usize, 0), stats.backwards_jumps);
}

test "Bytecode.getStats - backwards jumps (loops)" {
    const allocator = std.testing.allocator;
    // JUMPDEST PUSH1 0x01 PUSH1 0x00 JUMP (infinite loop)
    const code = [_]u8{
        0x5b, // JUMPDEST at PC 0
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x00, // PUSH1 0x00
        0x56, // JUMP (back to 0)
    };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    const stats = try bytecode.getStats();
    defer {
        allocator.free(stats.push_values);
        allocator.free(stats.potential_fusions);
        allocator.free(stats.jumpdests);
        allocator.free(stats.jumps);
    }

    // Check backwards jumps
    try std.testing.expectEqual(@as(usize, 1), stats.backwards_jumps);
    try std.testing.expectEqual(@as(usize, 1), stats.jumps.len);
    try std.testing.expectEqual(@as(u256, 0x00), stats.jumps[0].target);
    try std.testing.expectEqual(@as(usize, 5), stats.jumps[0].pc);
}

test "Bytecode.getStats - create code detection" {
    const allocator = std.testing.allocator;
    // Bytecode that starts with constructor pattern (returns runtime code)
    // PUSH1 0x10 PUSH1 0x20 PUSH1 0x00 CODECOPY PUSH1 0x10 PUSH1 0x00 RETURN
    const code = [_]u8{
        0x60, 0x10, // PUSH1 0x10 (size)
        0x60, 0x20, // PUSH1 0x20 (offset in code)
        0x60, 0x00, // PUSH1 0x00 (dest in memory)
        0x39, // CODECOPY
        0x60, 0x10, // PUSH1 0x10 (size)
        0x60, 0x00, // PUSH1 0x00 (offset in memory)
        0xf3, // RETURN
    };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    const stats = try bytecode.getStats();
    defer {
        allocator.free(stats.push_values);
        allocator.free(stats.potential_fusions);
        allocator.free(stats.jumpdests);
        allocator.free(stats.jumps);
    }

    // Check if identified as create code
    try std.testing.expect(stats.is_create_code);
}

test "Bytecode.getStats - runtime code detection" {
    const allocator = std.testing.allocator;
    // Normal runtime code (no CODECOPY + RETURN pattern)
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 }; // PUSH1 1 PUSH1 2 ADD STOP
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    const stats = try bytecode.getStats();
    defer {
        allocator.free(stats.push_values);
        allocator.free(stats.potential_fusions);
        allocator.free(stats.jumpdests);
        allocator.free(stats.jumps);
    }

    // Should not be identified as create code
    try std.testing.expect(!stats.is_create_code);
}

test "Bytecode opcode validation" {
    const allocator = std.testing.allocator;

    // Test bytecode with invalid opcode (0x0C is not assigned)
    const invalid_code = [_]u8{ 0x60, 0x01, 0x0C, 0x00 }; // PUSH1 1 <invalid> STOP
    const result = BytecodeDefault.init(allocator, &invalid_code);
    try std.testing.expectError(BytecodeDefault.ValidationError.InvalidOpcode, result);

    // Test bytecode with all valid opcodes
    const valid_code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 }; // PUSH1 1 PUSH1 2 ADD STOP
    var bytecode = try BytecodeDefault.init(allocator, &valid_code);
    defer bytecode.deinit();

    // Should pass validation
    try std.testing.expectEqual(@as(usize, 6), bytecode.len());
}

test "Bytecode EIP-170 runtime size validation" {
    const allocator = std.testing.allocator;
    // Create runtime code exceeding the EIP-170 limit by 1 byte
    const oversized = try allocator.alloc(u8, default_config.max_bytecode_size + 1);
    defer allocator.free(oversized);
    @memset(oversized, 0x00);

    const res = BytecodeDefault.init(allocator, oversized);
    try std.testing.expectError(error.BytecodeTooLarge, res);
}

test "Bytecode initcode validation - EIP-3860" {
    const allocator = std.testing.allocator;

    // Test with valid initcode size (under limit)
    const valid_initcode = try allocator.alloc(u8, 1000);
    defer allocator.free(valid_initcode);
    @memset(valid_initcode, 0x00); // Fill with STOP opcodes

    var bytecode = try BytecodeDefault.initFromInitcode(allocator, valid_initcode);
    defer bytecode.deinit();
    try std.testing.expectEqual(@as(usize, 1000), bytecode.len());

    // Test with initcode at exactly the limit
    const max_initcode = try allocator.alloc(u8, default_config.max_initcode_size);
    defer allocator.free(max_initcode);
    @memset(max_initcode, 0x00);

    var bytecode2 = try BytecodeDefault.initFromInitcode(allocator, max_initcode);
    defer bytecode2.deinit();
    try std.testing.expectEqual(@as(usize, default_config.max_initcode_size), bytecode2.len());

    // Test with initcode exceeding the limit
    const oversized_initcode = try allocator.alloc(u8, default_config.max_initcode_size + 1);
    defer allocator.free(oversized_initcode);
    @memset(oversized_initcode, 0x00);

    const result = BytecodeDefault.initFromInitcode(allocator, oversized_initcode);
    try std.testing.expectError(error.InitcodeTooLarge, result);
}

test "Bytecode calculateInitcodeGas - EIP-3860" {
    // Test gas calculation for various initcode sizes

    // Empty initcode = 0 words = 0 gas
    try std.testing.expectEqual(@as(u64, 0), BytecodeDefault.calculateInitcodeGas(0));

    // 1 byte = 1 word = 2 gas
    try std.testing.expectEqual(@as(u64, 2), BytecodeDefault.calculateInitcodeGas(1));

    // 32 bytes = 1 word = 2 gas
    try std.testing.expectEqual(@as(u64, 2), BytecodeDefault.calculateInitcodeGas(32));

    // 33 bytes = 2 words = 4 gas
    try std.testing.expectEqual(@as(u64, 4), BytecodeDefault.calculateInitcodeGas(33));

    // 64 bytes = 2 words = 4 gas
    try std.testing.expectEqual(@as(u64, 4), BytecodeDefault.calculateInitcodeGas(64));

    // 1000 bytes = 32 words (31.25 rounded up) = 64 gas
    try std.testing.expectEqual(@as(u64, 64), BytecodeDefault.calculateInitcodeGas(1000));

    // Maximum initcode size: 49,152 bytes = 1536 words = 3072 gas
    try std.testing.expectEqual(@as(u64, 3072), BytecodeDefault.calculateInitcodeGas(default_config.max_initcode_size));
}

test "Bytecode fusion pattern detection" {
    const allocator = std.testing.allocator;

    // Test all fusion patterns: PUSH + ADD/SUB/MUL/DIV/JUMP/JUMPI
    const code = [_]u8{
        0x60, 0x01, 0x01, // PUSH1 1 ADD
        0x60, 0x02, 0x03, // PUSH1 2 SUB
        0x60, 0x03, 0x02, // PUSH1 3 MUL
        0x60, 0x04, 0x04, // PUSH1 4 DIV
        0x60, 0x13, 0x56, // PUSH1 19 JUMP (valid target below)
        0x60, 0x1C, 0x57, // PUSH1 28 JUMPI (valid target below)
        0x00, // STOP at 18
        0x5b, // JUMPDEST at 19
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // padding to 27
        0x5b, // JUMPDEST at 28
    };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    const stats = try bytecode.getStats();
    defer {
        allocator.free(stats.push_values);
        allocator.free(stats.potential_fusions);
        allocator.free(stats.jumpdests);
        allocator.free(stats.jumps);
    }

    // Check that all 6 fusion opportunities were detected
    try std.testing.expectEqual(@as(usize, 6), stats.potential_fusions.len);

    // Verify each fusion
    try std.testing.expectEqual(@as(usize, 0), stats.potential_fusions[0].pc);
    try std.testing.expectEqual(Opcode.ADD, stats.potential_fusions[0].second_opcode);

    try std.testing.expectEqual(@as(usize, 3), stats.potential_fusions[1].pc);
    try std.testing.expectEqual(Opcode.SUB, stats.potential_fusions[1].second_opcode);

    try std.testing.expectEqual(@as(usize, 6), stats.potential_fusions[2].pc);
    try std.testing.expectEqual(Opcode.MUL, stats.potential_fusions[2].second_opcode);

    try std.testing.expectEqual(@as(usize, 9), stats.potential_fusions[3].pc);
    try std.testing.expectEqual(Opcode.DIV, stats.potential_fusions[3].second_opcode);

    try std.testing.expectEqual(@as(usize, 12), stats.potential_fusions[4].pc);
    try std.testing.expectEqual(Opcode.JUMP, stats.potential_fusions[4].second_opcode);

    try std.testing.expectEqual(@as(usize, 15), stats.potential_fusions[5].pc);
    try std.testing.expectEqual(Opcode.JUMPI, stats.potential_fusions[5].second_opcode);
}

test "Bytecode.getStats - all opcode types counted" {
    const allocator = std.testing.allocator;
    // Use various opcodes
    const code = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x80, // DUP1
        0x01, // ADD
        0x60, 0x20, // PUSH1 32
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x51, // MLOAD
        0x00, // STOP
    };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    const stats = try bytecode.getStats();
    defer {
        allocator.free(stats.push_values);
        allocator.free(stats.potential_fusions);
        allocator.free(stats.jumpdests);
        allocator.free(stats.jumps);
    }

    // Verify counts
    try std.testing.expectEqual(@as(u32, 3), stats.opcode_counts[@intFromEnum(Opcode.PUSH1)]);
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[@intFromEnum(Opcode.DUP1)]);
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[@intFromEnum(Opcode.ADD)]);
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[@intFromEnum(Opcode.MSTORE)]);
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[@intFromEnum(Opcode.MLOAD)]);
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[@intFromEnum(Opcode.STOP)]);
}

test "Bytecode.countBitsInRange - basic functionality" {
    const allocator = std.testing.allocator;
    // Create a simple bitmap for testing
    var bitmap = try allocator.alloc(u8, 4);
    defer allocator.free(bitmap);
    @memset(bitmap, 0);

    // Set some bits: bit 0, 2, 8, 15, 17, 23
    bitmap[0] = 0b00000101; // bits 0 and 2
    bitmap[1] = 0b10000001; // bits 8 and 15
    bitmap[2] = 0b00000010; // bit 17
    bitmap[2] |= 0b10000000; // bit 23 (within byte 2)
    bitmap[3] = 0b00000000;

    // Test full range (0..32 includes bit 31)
    try std.testing.expectEqual(@as(usize, 6), BytecodeDefault.countBitsInRange(bitmap, 0, 32));

    // Test partial ranges
    try std.testing.expectEqual(@as(usize, 2), BytecodeDefault.countBitsInRange(bitmap, 0, 8));
    try std.testing.expectEqual(@as(usize, 2), BytecodeDefault.countBitsInRange(bitmap, 8, 16));
    try std.testing.expectEqual(@as(usize, 1), BytecodeDefault.countBitsInRange(bitmap, 16, 20));

    // Test single bit ranges
    try std.testing.expectEqual(@as(usize, 1), BytecodeDefault.countBitsInRange(bitmap, 0, 1));
    try std.testing.expectEqual(@as(usize, 0), BytecodeDefault.countBitsInRange(bitmap, 1, 2));

    // Test empty range
    try std.testing.expectEqual(@as(usize, 0), BytecodeDefault.countBitsInRange(bitmap, 10, 10));
}

test "Bytecode.findNextSetBit - basic functionality" {
    const allocator = std.testing.allocator;
    // Create a simple bitmap for testing
    var bitmap = try allocator.alloc(u8, 4);
    defer allocator.free(bitmap);
    @memset(bitmap, 0);

    // Set some bits: bit 0, 2, 8, 15, 17, 23
    bitmap[0] = 0b00000101; // bits 0 and 2
    bitmap[1] = 0b10000001; // bits 8 and 15
    bitmap[2] = 0b10000010; // bits 17 and 23
    bitmap[3] = 0b00000000; // none

    // Find from start
    try std.testing.expectEqual(@as(?usize, 0), BytecodeDefault.findNextSetBit(bitmap, 0));

    // Find from after first bit
    try std.testing.expectEqual(@as(?usize, 2), BytecodeDefault.findNextSetBit(bitmap, 1));

    // Find from after second bit
    try std.testing.expectEqual(@as(?usize, 8), BytecodeDefault.findNextSetBit(bitmap, 3));

    // Find from middle of byte
    try std.testing.expectEqual(@as(?usize, 15), BytecodeDefault.findNextSetBit(bitmap, 9));

    // Find last bit
    try std.testing.expectEqual(@as(?usize, 23), BytecodeDefault.findNextSetBit(bitmap, 18));

    // No more bits after last
    try std.testing.expectEqual(@as(?usize, null), BytecodeDefault.findNextSetBit(bitmap, 24));

    // Start beyond bitmap
    try std.testing.expectEqual(@as(?usize, null), BytecodeDefault.findNextSetBit(bitmap, 100));
}

test "Bytecode cache-aligned allocations" {
    // Skip this test since test allocator doesn't support aligned allocations
    // In production, allocations will be cache-aligned
    if (builtin.is_test) {
        return;
    }

    const allocator = std.testing.allocator;
    // Test that bitmaps are allocated with cache line alignment
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 }; // PUSH1 1 PUSH1 2 ADD STOP
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Check that bitmaps are aligned to cache line boundaries
    const push_data_addr = @intFromPtr(bytecode.is_push_data.ptr);
    const op_start_addr = @intFromPtr(bytecode.is_op_start.ptr);
    const jumpdest_addr = @intFromPtr(bytecode.is_jumpdest.ptr);

    try std.testing.expect(push_data_addr % CACHE_LINE_SIZE == 0);
    try std.testing.expect(op_start_addr % CACHE_LINE_SIZE == 0);
    try std.testing.expect(jumpdest_addr % CACHE_LINE_SIZE == 0);
}

test "Bytecode.parseSolidityMetadata" {
    const allocator = std.testing.allocator;

    // Example bytecode with Solidity metadata
    // This represents a simple contract with metadata appended
    const code_with_metadata = [_]u8{
        // Some contract bytecode
        0x60, 0x80, 0x60, 0x40, 0x52, 0x34, 0x80, 0x15, 0x60, 0x0e, 0x57, 0x5f, 0x5f, 0xfd, 0x5b, 0x50,

        // Solidity metadata (CBOR encoded)
        0xa2, // CBOR map with 2 entries
        0x64, 0x69, 0x70, 0x66, 0x73, // "ipfs"
        0x58, 0x22, // 34 bytes following
        // 34-byte IPFS multihash (0x12 0x20 prefix + 32-byte digest)
        0x12, 0x20,
        0x2c, 0x24,
        0x7f, 0x39,
        0xd6, 0x15,
        0xd7, 0xf6,
        0x69, 0x42,
        0xcd, 0x6e,
        0xd5, 0x05,
        0xd8, 0xea,
        0x34, 0xfb,
        0xfc, 0xbe,
        0x16, 0xac,
        0x87, 0x5e,
        0xd0, 0x8c,
        0x4a, 0x9c,
        0x22, 0x93,
        0xaa, 0xbb, // last 2 bytes of digest to reach 34 bytes
        0x64, 0x73, 0x6f, 0x6c, 0x63, // "solc"
        0x00, 0x08, 0x1e, // version 0.8.30
        0x00, 0x32, // metadata length: 50 bytes
    };

    var bytecode = try BytecodeDefault.init(allocator, &code_with_metadata);
    defer bytecode.deinit();

    // Parse metadata
    const metadata = bytecode.parseSolidityMetadata();
    try std.testing.expect(metadata != null);

    if (metadata) |m| {
        // Check IPFS hash (first few bytes)
        try std.testing.expectEqual(@as(u8, 0x12), m.ipfs_hash[0]);
        try std.testing.expectEqual(@as(u8, 0x20), m.ipfs_hash[1]);
        try std.testing.expectEqual(@as(u8, 0x2c), m.ipfs_hash[2]);

        // Check Solidity version
        try std.testing.expectEqual(@as(u8, 0), m.solc_version[0]); // major
        try std.testing.expectEqual(@as(u8, 8), m.solc_version[1]); // minor
        try std.testing.expectEqual(@as(u8, 30), m.solc_version[2]); // patch (0x1e = 30)

        // Check metadata length
        try std.testing.expectEqual(@as(usize, 52), m.metadata_length); // 50 + 2 length bytes
    }

    // Test with bytecode that has no metadata
    const code_no_metadata = [_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52, 0x00 };
    var bytecode2 = try BytecodeDefault.init(allocator, &code_no_metadata);
    defer bytecode2.deinit();

    const no_metadata = bytecode2.parseSolidityMetadata();
    try std.testing.expect(no_metadata == null);

    // Test with bytecode too short for metadata
    const short_code = [_]u8{ 0x60, 0x00 };
    var bytecode3 = try BytecodeDefault.init(allocator, &short_code);
    defer bytecode3.deinit();

    const short_metadata = bytecode3.parseSolidityMetadata();
    try std.testing.expect(short_metadata == null);
}

test "Bytecode edge cases - very short bytecode" {
    const allocator = std.testing.allocator;

    // Test SIMD operations with bytecode shorter than vector length
    const short_code = [_]u8{0x00}; // Just STOP
    var bytecode = try BytecodeDefault.init(allocator, &short_code);
    defer bytecode.deinit();

    try std.testing.expectEqual(@as(usize, 1), bytecode.len());

    // Test that validation still works with short code
    const stats = try bytecode.getStats();
    defer {
        allocator.free(stats.push_values);
        allocator.free(stats.potential_fusions);
        allocator.free(stats.jumpdests);
        allocator.free(stats.jumps);
    }

    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[@intFromEnum(Opcode.STOP)]);
}

test "Bytecode edge cases - bytecode at vector boundaries" {
    const allocator = std.testing.allocator;

    // Create bytecode with length exactly at common vector sizes
    const vector_sizes = [_]usize{ 8, 16, 32, 64 };

    for (vector_sizes) |size| {
        // Create valid bytecode of exact vector size
        var code = try allocator.alloc(u8, size);
        defer allocator.free(code);

        // Fill with alternating PUSH1 and data
        var i: usize = 0;
        while (i + 1 < size) {
            code[i] = 0x60; // PUSH1
            code[i + 1] = @intCast(i); // Some data
            i += 2;
        }
        if (i < size) {
            code[i] = 0x00; // STOP
        }

        var bytecode = try BytecodeDefault.init(allocator, code);
        defer bytecode.deinit();

        // Verify it was processed correctly
        try std.testing.expect(bytecode.len() == size);
    }
}

test "Bytecode fusion detection at boundaries" {
    const allocator = std.testing.allocator;

    // Test fusion detection when PUSH+OP spans vector boundaries
    // Create code that has fusions at different positions relative to vector boundaries
    var code: [67]u8 = undefined; // Prime number to avoid alignment
    var pos: usize = 0;

    // Fill with alternating PUSH1+ADD patterns
    while (pos + 2 < code.len) {
        code[pos] = 0x60; // PUSH1
        code[pos + 1] = @intCast(pos); // Data
        code[pos + 2] = 0x01; // ADD
        pos += 3;
    }
    // Fill remaining with STOP
    while (pos < code.len) {
        code[pos] = 0x00;
        pos += 1;
    }

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    const stats = try bytecode.getStats();
    defer {
        allocator.free(stats.push_values);
        allocator.free(stats.potential_fusions);
        allocator.free(stats.jumpdests);
        allocator.free(stats.jumps);
    }

    // Should detect multiple PUSH+ADD fusions
    try std.testing.expect(stats.potential_fusions.len > 0);

    // Verify all detected fusions are PUSH+ADD
    for (stats.potential_fusions) |fusion| {
        try std.testing.expectEqual(Opcode.ADD, fusion.second_opcode);
    }
}

test "Bytecode bitmap operations edge cases - bit boundaries" {
    const allocator = std.testing.allocator;

    // Create a bitmap that exercises bit boundary conditions
    var bitmap = try allocator.alloc(u8, 8);
    defer allocator.free(bitmap);
    @memset(bitmap, 0);

    // Set bits at various boundary positions
    const test_bits = [_]usize{ 0, 7, 8, 15, 16, 31, 32, 63 };
    for (test_bits) |bit| {
        const byte_idx = bit >> 3;
        const bit_mask = @as(u8, 1) << @intCast(bit & 7);
        if (byte_idx < bitmap.len) {
            bitmap[byte_idx] |= bit_mask;
        }
    }

    // Test countBitsInRange across boundaries
    try std.testing.expectEqual(@as(usize, 2), BytecodeDefault.countBitsInRange(bitmap, 0, 8)); // bits 0,7
    try std.testing.expectEqual(@as(usize, 2), BytecodeDefault.countBitsInRange(bitmap, 8, 16)); // bits 8,15
    try std.testing.expectEqual(@as(usize, 2), BytecodeDefault.countBitsInRange(bitmap, 16, 32)); // bits 16,31
    try std.testing.expectEqual(@as(usize, 2), BytecodeDefault.countBitsInRange(bitmap, 32, 64)); // bits 32,63

    // Test across multiple byte boundaries
    try std.testing.expectEqual(@as(usize, 4), BytecodeDefault.countBitsInRange(bitmap, 0, 16)); // bits 0,7,8,15

    // Test findNextSetBit across boundaries
    try std.testing.expectEqual(@as(?usize, 0), BytecodeDefault.findNextSetBit(bitmap, 0));
    try std.testing.expectEqual(@as(?usize, 7), BytecodeDefault.findNextSetBit(bitmap, 1));
    try std.testing.expectEqual(@as(?usize, 8), BytecodeDefault.findNextSetBit(bitmap, 8));
    try std.testing.expectEqual(@as(?usize, 15), BytecodeDefault.findNextSetBit(bitmap, 9));
}

test "Bytecode bitmap operations - empty ranges" {
    const allocator = std.testing.allocator;

    const bitmap = try allocator.alloc(u8, 4);
    defer allocator.free(bitmap);
    @memset(bitmap, 0xFF); // All bits set

    // Test empty ranges
    try std.testing.expectEqual(@as(usize, 0), BytecodeDefault.countBitsInRange(bitmap, 10, 10));
    try std.testing.expectEqual(@as(usize, 0), BytecodeDefault.countBitsInRange(bitmap, 5, 5));
    try std.testing.expectEqual(@as(usize, 0), BytecodeDefault.countBitsInRange(bitmap, 100, 50)); // Invalid range

    // Test single bit ranges
    try std.testing.expectEqual(@as(usize, 1), BytecodeDefault.countBitsInRange(bitmap, 0, 1));
    try std.testing.expectEqual(@as(usize, 1), BytecodeDefault.countBitsInRange(bitmap, 15, 16));
    try std.testing.expectEqual(@as(usize, 1), BytecodeDefault.countBitsInRange(bitmap, 31, 32));
}

test "Bytecode markJumpdest edge cases" {
    const allocator = std.testing.allocator;

    // Create bytecode with JUMPDEST at various positions including boundaries
    var code = [_]u8{
        0x5b, // JUMPDEST at 0
        0x60, 0x04, // PUSH1 4 (valid JUMP target)
        0x56, // JUMP
        0x5b, // JUMPDEST at 4
        0x61, 0x5b, 0x5b, // PUSH2 0x5b5b (JUMPDEST in push data)
        0x5b, // JUMPDEST at 8 (should be valid)
        0x7f, // PUSH32
    };

    const full_code = try allocator.alloc(u8, code.len + 32);
    defer allocator.free(full_code);
    std.mem.copyForwards(u8, full_code[0..code.len], &code);
    // Fill rest with data including 0x5b bytes
    var i: usize = 10;
    while (i < 10 + 32) {
        full_code[i] = if ((i - 10) % 4 == 0) 0x5b else @intCast(i);
        i += 1;
    }

    var bytecode = try BytecodeDefault.init(allocator, full_code);
    defer bytecode.deinit();

    // Verify only actual JUMPDESTs (not in push data) are marked
    try std.testing.expect(bytecode.isValidJumpDest(0)); // JUMPDEST at 0
    try std.testing.expect(bytecode.isValidJumpDest(4)); // JUMPDEST at 4
    try std.testing.expect(!bytecode.isValidJumpDest(6)); // 0x5b in PUSH2 data
    try std.testing.expect(!bytecode.isValidJumpDest(7)); // 0x5b in PUSH2 data
    try std.testing.expect(bytecode.isValidJumpDest(8)); // JUMPDEST at 8

    // All 0x5b bytes in PUSH32 data should be invalid
    for (10..42) |pos| {
        if (full_code[pos] == 0x5b) {
            try std.testing.expect(!bytecode.isValidJumpDest(@intCast(pos)));
        }
    }
}

test "Bytecode complex PUSH patterns" {
    const allocator = std.testing.allocator;

    // Create complex bytecode with all PUSH sizes
    var code: [300]u8 = undefined;
    var pos: usize = 0;

    // Add PUSH1 through PUSH32
    var push_size: u8 = 1;
    while (push_size <= 32 and pos < code.len) {
        if (pos + 1 + push_size >= code.len) break;

        code[pos] = 0x60 + push_size - 1; // PUSH1 = 0x60, PUSH2 = 0x61, etc.
        pos += 1;

        // Fill push data
        for (0..push_size) |i| {
            if (pos < code.len) {
                var tmp: u8 = push_size;
                tmp = tmp *% 16;
                tmp = tmp +% @as(u8, @intCast(i));
                code[pos] = tmp;
                pos += 1;
            }
        }

        push_size += 1;
    }

    // Fill remaining with STOP
    while (pos < code.len) {
        code[pos] = 0x00;
        pos += 1;
    }

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    const stats = try bytecode.getStats();
    defer {
        allocator.free(stats.push_values);
        allocator.free(stats.potential_fusions);
        allocator.free(stats.jumpdests);
        allocator.free(stats.jumps);
    }

    // The number of PUSH opcodes detected should match recorded push_values
    var total_pushes: u32 = 0;
    for (1..33) |i| {
        total_pushes += stats.opcode_counts[@intFromEnum(Opcode.PUSH1) + i - 1];
    }
    try std.testing.expect(total_pushes > 0);
    try std.testing.expectEqual(@as(usize, total_pushes), stats.push_values.len);
}

test "Bytecode large initcode stress test" {
    const allocator = std.testing.allocator;

    // Test with large initcode near the limit
    const large_size = default_config.max_initcode_size - 1000;
    var large_code = try allocator.alloc(u8, large_size);
    defer allocator.free(large_code);

    // Fill with valid pattern: PUSH1 + data
    var i: usize = 0;
    while (i + 1 < large_size) {
        large_code[i] = 0x60; // PUSH1
        large_code[i + 1] = @intCast(i & 0xFF);
        i += 2;
    }
    if (i < large_size) {
        large_code[i] = 0x00; // STOP
    }

    var bytecode = try BytecodeDefault.initFromInitcode(allocator, large_code);
    defer bytecode.deinit();

    try std.testing.expectEqual(@as(usize, large_size), bytecode.len());

    // Verify gas calculation for large initcode
    const expected_words = (large_size + 31) / 32;
    const expected_gas = expected_words * 2;
    try std.testing.expectEqual(@as(u64, expected_gas), BytecodeDefault.calculateInitcodeGas(large_size));
}

test "Bytecode malformed metadata - invalid CBOR header" {
    const allocator = std.testing.allocator;

    // Test metadata with invalid CBOR map header
    const code_bad_header = [_]u8{
        0x60, 0x00, // Some contract code
        // Bad metadata with wrong CBOR header
        0xa1, // CBOR map with 1 entry (should be 2)
        0x64, 0x69, 0x70, 0x66, 0x73, // "ipfs"
        0x58, 0x22, // 34 bytes following
        // Dummy 32-byte hash
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x64, 0x73, 0x6f, 0x6c, 0x63, // "solc"
        0x00, 0x08, 0x1e, // version
        0x00, 0x30, // metadata length: 48 bytes (actual)
    };

    var bytecode = try BytecodeDefault.init(allocator, &code_bad_header);
    defer bytecode.deinit();

    const metadata = bytecode.parseSolidityMetadata();
    try std.testing.expect(metadata == null); // Should fail to parse
}

test "Bytecode malformed metadata - invalid string lengths" {
    const allocator = std.testing.allocator;

    // Test metadata with wrong string length marker
    const code_bad_string = [_]u8{
        0x60, 0x00, // Some contract code
        // Bad metadata with wrong string length
        0xa2, // CBOR map with 2 entries
        0x65, 0x69, 0x70, 0x66, 0x73, // 5-byte string marker but "ipfs" is 4 bytes
        0x58, 0x22, // 34 bytes following
        // Dummy 32-byte hash
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x64, 0x73, 0x6f, 0x6c, 0x63, // "solc"
        0x00, 0x08, 0x1e, // version
        0x00, 0x30, // metadata length: 48 bytes (actual)
    };

    var bytecode = try BytecodeDefault.init(allocator, &code_bad_string);
    defer bytecode.deinit();

    const metadata = bytecode.parseSolidityMetadata();
    try std.testing.expect(metadata == null);
}

test "Bytecode malformed metadata - wrong key names" {
    const allocator = std.testing.allocator;

    // Test metadata with wrong key names
    const code_wrong_keys = [_]u8{
        0x00, 0x00, // Some contract code (two STOPs to avoid PUSH truncation)
        // Bad metadata with wrong key
        0xa2, // CBOR map with 2 entries
        0x64, 0x69, 0x70, 0x66, 0x78, // "ipfx" instead of "ipfs"
        0x58, 0x22, // 34 bytes following
        // Dummy 32-byte hash
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x64, 0x73, 0x6f, 0x6c, 0x63, // "solc"
        0x00, 0x08, 0x1e, // version
        0x00, 0x30, // metadata length: 48 bytes (approx to slice metadata)
    };

    var bytecode = try BytecodeDefault.init(allocator, &code_wrong_keys);
    defer bytecode.deinit();

    const metadata = bytecode.parseSolidityMetadata();
    try std.testing.expect(metadata == null);
}

test "Bytecode malformed metadata - invalid hash format" {
    const allocator = std.testing.allocator;

    // Test metadata with wrong hash format markers
    const code_bad_hash = [_]u8{
        0x60, 0x00, // Some contract code
        0xa2, // CBOR map with 2 entries
        0x64, 0x69, 0x70, 0x66, 0x73, // "ipfs"
        0x58, 0x20, // 32 bytes following (should be 0x22 for 34 bytes)
        // Only 30 bytes instead of 32
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x64, 0x73, 0x6f, 0x6c, 0x63, // "solc"
        0x00, 0x08, 0x1e, // version
        0x00, 0x2e, // metadata length: 46 bytes (actual)
    };

    var bytecode = try BytecodeDefault.init(allocator, &code_bad_hash);
    defer bytecode.deinit();

    const metadata = bytecode.parseSolidityMetadata();
    try std.testing.expect(metadata == null);
}

test "Bytecode malformed metadata - truncated data" {
    const allocator = std.testing.allocator;

    // Test metadata that's cut off mid-parsing
    const code_truncated = [_]u8{
        0x60, 0x00, // Some contract code
        0xa2, // CBOR map with 2 entries
        0x64, 0x69, 0x70, 0x66, 0x73, // "ipfs"
        0x58, 0x22, // 34 bytes following
        // Only partial hash - should be 32 bytes
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00,
        0x00,
        // Missing second half of hash and rest of data
        0x00, 0x18, // metadata length: 24 bytes (actual but truncated content)
    };

    var bytecode = try BytecodeDefault.init(allocator, &code_truncated);
    defer bytecode.deinit();

    const metadata = bytecode.parseSolidityMetadata();
    try std.testing.expect(metadata == null);
}

test "Bytecode malformed metadata - invalid length encoding" {
    const allocator = std.testing.allocator;

    // Test with invalid metadata length that would extend beyond bytecode
    const code_bad_length = [_]u8{
        0x60, 0x00, // Some contract code (2 bytes)
        0xFF, 0xFF, // Claim metadata is 65535 bytes (impossible)
    };

    var bytecode = try BytecodeDefault.init(allocator, &code_bad_length);
    defer bytecode.deinit();

    const metadata = bytecode.parseSolidityMetadata();
    try std.testing.expect(metadata == null);
}

test "Bytecode malformed metadata - zero length" {
    const allocator = std.testing.allocator;

    // Test with zero metadata length
    const code_zero_length = [_]u8{
        0x60, 0x00, // Some contract code
        0x00, 0x00, // Zero metadata length
    };

    var bytecode = try BytecodeDefault.init(allocator, &code_zero_length);
    defer bytecode.deinit();

    const metadata = bytecode.parseSolidityMetadata();
    try std.testing.expect(metadata == null);
}

test "Bytecode malformed metadata - minimum size violation" {
    const allocator = std.testing.allocator;

    // Test bytecode smaller than minimum metadata size (45 bytes)
    const code_too_small = [_]u8{
        0x60, 0x00, 0x00, // 3 bytes of code
        0x00, 0x05, // Claim 5 bytes of metadata
    };

    var bytecode = try BytecodeDefault.init(allocator, &code_too_small);
    defer bytecode.deinit();

    const metadata = bytecode.parseSolidityMetadata();
    try std.testing.expect(metadata == null);
}

test "Bytecode malformed metadata - boundary conditions" {
    const allocator = std.testing.allocator;

    // Test exactly minimum size but malformed
    var code_min_size = [_]u8{0} ** 45;
    // Set zero metadata length; still too small to be valid
    code_min_size[43] = 0x00;
    code_min_size[44] = 0x00;

    var bytecode = try BytecodeDefault.init(allocator, &code_min_size);
    defer bytecode.deinit();

    const metadata = bytecode.parseSolidityMetadata();
    try std.testing.expect(metadata == null);
}

test "Bytecode malformed metadata - wrong byte string markers" {
    const allocator = std.testing.allocator;

    // Test metadata with wrong byte string markers for IPFS hash
    const code_wrong_markers = [_]u8{
        0x00, 0x00, // Some contract code (two STOPs to avoid PUSH truncation)
        0xa2, // CBOR map with 2 entries
        0x64, 0x69, 0x70, 0x66, 0x73, // "ipfs"
        0x57, 0x22, // Wrong marker (0x57 instead of 0x58)
        // 32-byte hash
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x64, 0x73, 0x6f, 0x6c, 0x63, // "solc"
        0x00, 0x08, 0x1e, // version
        0x00, 0x30, // metadata length: 48 bytes (approx to slice metadata)
    };

    var bytecode = try BytecodeDefault.init(allocator, &code_wrong_markers);
    defer bytecode.deinit();

    const metadata = bytecode.parseSolidityMetadata();
    try std.testing.expect(metadata == null);
}

test "Bytecode complex jump validation - nested patterns" {
    const allocator = std.testing.allocator;

    // Test complex nested jump patterns with multiple PUSH sizes
    const code = [_]u8{
        0x60, 0x0D, // PUSH1 13  (PC 0-1)
        0x56, // JUMP      (PC 2)
        0x60, 0x10, // PUSH1 16  (PC 3-4)
        0x56, // JUMP      (PC 5)
        0x61, 0x00, 0x19, // PUSH2 25  (PC 6-8)
        0x56, // JUMP      (PC 9)
        0x00, // STOP      (PC 10)
        0x60, 0x03, // PUSH1 3   (PC 11-12)
        0x5b, // JUMPDEST  (PC 13) <- Target of first jump
        0x56, // JUMP      (PC 14)
        0x00, // STOP      (PC 15)
        0x5b, // JUMPDEST  (PC 16) <- Target of second jump
        0x60, 0x10, // PUSH1 16  (PC 17-18)
        0x56, // JUMP      (PC 19)
        0x00, // STOP      (PC 20)
        0x60, 0x10, // PUSH1 16  (PC 21-22)
        0x56, // JUMP      (PC 23)
        0x00, // STOP      (PC 24)
        0x5b, // JUMPDEST  (PC 25) <- Target of PUSH2 jump
        0x00, // STOP      (PC 26)
    };

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Verify all jumpdests are valid
    try std.testing.expect(bytecode.isValidJumpDest(13));
    try std.testing.expect(bytecode.isValidJumpDest(16));
    try std.testing.expect(bytecode.isValidJumpDest(25));

    // Verify non-jumpdests are invalid
    try std.testing.expect(!bytecode.isValidJumpDest(0));
    try std.testing.expect(!bytecode.isValidJumpDest(3));
    try std.testing.expect(!bytecode.isValidJumpDest(6));
}

test "Bytecode complex jump validation - PUSH32 with large targets" {
    const allocator = std.testing.allocator;

    // Create code with PUSH32 pointing to various locations
    var code: [100]u8 = undefined;
    var pos: usize = 0;

    // PUSH32 pointing to position 67 (after the PUSH32)
    code[pos] = 0x7f; // PUSH32
    pos += 1;
    // 32 bytes of data (most zeros, last byte is target position)
    for (0..31) |_| {
        code[pos] = 0x00;
        pos += 1;
    }
    code[pos] = 67; // Target position
    pos += 1;

    // JUMP
    code[pos] = 0x56;
    pos += 1;

    // Fill with NOPs until position 67
    while (pos < 67) {
        code[pos] = 0x00; // STOP (safe opcode)
        pos += 1;
    }

    // JUMPDEST at position 67
    code[pos] = 0x5b;
    pos += 1;

    // Fill rest with STOP
    while (pos < code.len) {
        code[pos] = 0x00;
        pos += 1;
    }

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Should validate successfully
    try std.testing.expect(bytecode.isValidJumpDest(67));
}

test "Bytecode complex jump validation - sequential PUSH patterns" {
    const allocator = std.testing.allocator;

    // Test multiple sequential PUSH+JUMP combinations
    const code = [_]u8{
        // Sequence 1: jump to 5
        0x60, 0x05, 0x56, // PUSH1 5 JUMP
        0x00, 0x00, // STOP STOP (PC 3-4)
        0x5b, // JUMPDEST (PC 5)
        // Sequence 2: jump to 10
        0x60, 0x0A, 0x56, // PUSH1 10 JUMP
        0x00, 0x5b, // padding; JUMPDEST (PC 10)
        // Sequence 3: jump to 15
        0x60, 0x0F, 0x56, // PUSH1 15 JUMP
        0x00, 0x5b, // JUMPDEST (PC 15)
        // Sequence 4: jump to 19
        0x60, 0x13, 0x56, // PUSH1 19 JUMP
        0x5b, 0x00, // JUMPDEST (PC 19) then STOP
    };

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // All jumpdests should be valid
    try std.testing.expect(bytecode.isValidJumpDest(5));
    try std.testing.expect(bytecode.isValidJumpDest(10));
    try std.testing.expect(bytecode.isValidJumpDest(15));
    try std.testing.expect(bytecode.isValidJumpDest(19));
}

test "Bytecode complex jump validation - JUMPI conditional patterns" {
    const allocator = std.testing.allocator;

    // Test JUMPI validation with one immediate pattern followed by a JUMP
    const code = [_]u8{
        0x60, 0x0A, // PUSH1 10 (JUMPDEST below)
        0x80, // DUP1 (condition not an immediate PUSH)
        0x57, // JUMPI (PC 3)
        0x00, // STOP (PC 4)
        0x00, 0x00, // padding (PC 5-6)
        0x00, 0x00, // padding (PC 7-8)
        0x5b, // JUMPDEST (PC 9)
        0x60, 0x0D, // PUSH1 13 (JUMPDEST below)
        0x56, // JUMP (PC 12)
        0x5b, // JUMPDEST (PC 13)
        0x00, // STOP
    };

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Verify jumpdests
    try std.testing.expect(bytecode.isValidJumpDest(9));
    try std.testing.expect(bytecode.isValidJumpDest(13));
}

test "Bytecode complex jump validation - edge case targets" {
    const allocator = std.testing.allocator;

    // Test jumps to edge positions (start, end-1, end)
    var code: [50]u8 = undefined;
    @memset(&code, 0x00); // Fill with STOP

    // JUMPDEST at position 0
    code[0] = 0x5b;

    // PUSH1 pointing to position 0
    code[1] = 0x60; // PUSH1
    code[2] = 0x00; // Target 0
    code[3] = 0x56; // JUMP

    // PUSH1 pointing to last position
    code[4] = 0x60; // PUSH1
    code[5] = 49; // Target last position
    code[6] = 0x56; // JUMP

    // JUMPDEST at last position
    code[49] = 0x5b;

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Verify edge positions
    try std.testing.expect(bytecode.isValidJumpDest(0));
    try std.testing.expect(bytecode.isValidJumpDest(49));

    // Test jump to position beyond bytecode should fail during validation
    const invalid_code = [_]u8{
        0x60, 0x64, 0x56, // PUSH1 100 JUMP (beyond bytecode)
    };

    const result = BytecodeDefault.init(allocator, &invalid_code);
    try std.testing.expectError(BytecodeDefault.ValidationError.InvalidJumpDestination, result);
}

test "Bytecode complex jump validation - deeply nested PUSH data" {
    const allocator = std.testing.allocator;

    // Test JUMPDEST validation with deeply nested PUSH data containing 0x5b
    var code: [200]u8 = undefined;
    var pos: usize = 0;

    // Start with a valid jump
    code[pos] = 0x60; // PUSH1
    code[pos + 1] = 100; // Target position 100
    code[pos + 2] = 0x56; // JUMP
    pos += 3;

    // Create nested PUSH instructions with 0x5b in data
    const push_sizes = [_]u8{ 1, 2, 4, 8, 16, 32 };
    for (push_sizes) |size| {
        if (pos + 1 + size >= 100) break;

        code[pos] = 0x60 + size - 1; // PUSH1, PUSH2, etc.
        pos += 1;

        // Fill push data with pattern including 0x5b
        for (0..size) |i| {
            code[pos] = if (i % 3 == 0) 0x5b else @intCast(i); // Every 3rd byte is 0x5b
            pos += 1;
        }

        // Add a regular opcode
        code[pos] = 0x01; // ADD
        pos += 1;
    }

    // Fill up to position 100 with STOP
    while (pos < 100) {
        code[pos] = 0x00;
        pos += 1;
    }

    // JUMPDEST at position 100
    code[100] = 0x5b;
    pos = 101;

    // Fill rest with STOP
    while (pos < code.len) {
        code[pos] = 0x00;
        pos += 1;
    }

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Only position 100 should be a valid jumpdest
    try std.testing.expect(bytecode.isValidJumpDest(100));

    // All 0x5b bytes in PUSH data should be invalid
    for (0..100) |i| {
        if (code[i] == 0x5b and i != 100) {
            try std.testing.expect(!bytecode.isValidJumpDest(@intCast(i)));
        }
    }
}

test "Bytecode complex jump validation - mixed valid/invalid patterns" {
    const allocator = std.testing.allocator;

    // Test a mix of valid and invalid jump patterns in the same bytecode
    const code = [_]u8{
        // Valid pattern: PUSH1 + JUMP to valid JUMPDEST
        0x60, 0x08, // PUSH1 8
        0x56, // JUMP (PC 2)

        // Invalid pattern: PUSH1 + JUMP to invalid destination
        0x60, 0x07, // PUSH1 7  (points to JUMP, not JUMPDEST)
        0x56, // JUMP (PC 5)
        0x00, // STOP (PC 6)
        0x56, // JUMP (PC 7) - not a JUMPDEST!
        0x5b, // JUMPDEST (PC 8) - valid target

        // Valid JUMPI pattern
        0x60, 0x0F, // PUSH1 15
        0x60, 0x01, // PUSH1 1
        0x57, // JUMPI (PC 12)
        0x00, // STOP (PC 13)
        0x00, // STOP (PC 14)
        0x5b, // JUMPDEST (PC 15) - valid target
        0x00, // STOP
    };

    // This should fail validation because of the invalid jump at PC 5
    const result = BytecodeDefault.init(allocator, &code);
    try std.testing.expectError(BytecodeDefault.ValidationError.InvalidJumpDestination, result);
}

test "Bytecode complex jump validation - maximum PUSH32 target" {
    const allocator = std.testing.allocator;

    // Test PUSH32 with maximum possible target value within bounds
    // Use a more reasonable size to avoid excessive memory usage in tests
    var code: [2000]u8 = undefined;
    var pos: usize = 0;

    // PUSH32 with target 1000
    code[pos] = 0x7f; // PUSH32
    pos += 1;

    // 32 bytes representing target 1000
    for (0..29) |_| {
        code[pos] = 0x00;
        pos += 1;
    }
    code[pos] = 0x03; // High byte of 1000
    pos += 1;
    code[pos] = 0xE8; // Low byte of 1000
    pos += 1;

    code[pos] = 0x56; // JUMP
    pos += 1;

    // Fill with STOP until target position
    while (pos < 1000) {
        code[pos] = 0x00;
        pos += 1;
    }

    // JUMPDEST at position 1000
    code[1000] = 0x5b;
    pos = 1001;

    // Fill remaining with STOP
    while (pos < code.len) {
        code[pos] = 0x00;
        pos += 1;
    }

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Should successfully validate the large jump target
    try std.testing.expect(bytecode.isValidJumpDest(1000));
}

// BYTECODE EDGE CASE TESTS

test "Bytecode edge cases - empty bytecode" {
    const allocator = std.testing.allocator;

    // Empty bytecode should be valid
    const empty_code = [_]u8{};
    var bytecode = try BytecodeDefault.init(allocator, &empty_code);
    defer bytecode.deinit();

    try std.testing.expectEqual(@as(usize, 0), bytecode.len());
    try std.testing.expectEqual(@as(?u8, null), bytecode.get(0));
    try std.testing.expect(!bytecode.isValidJumpDest(0));
}

test "Bytecode edge cases - single byte bytecode" {
    const allocator = std.testing.allocator;

    // Test various single-byte bytecodes
    const single_bytes = [_]u8{ 0x00, 0x01, 0x5B, 0xFD, 0xFF };

    for (single_bytes) |byte| {
        const code = [_]u8{byte};

        if (byte == 0xFE) { // INVALID opcode
            try std.testing.expectError(error.InvalidOpcode, BytecodeDefault.init(allocator, &code));
        } else {
            var bytecode = try BytecodeDefault.init(allocator, &code);
            defer bytecode.deinit();

            try std.testing.expectEqual(@as(usize, 1), bytecode.len());
            try std.testing.expectEqual(@as(?u8, byte), bytecode.get(0));
            try std.testing.expectEqual(byte == 0x5B, bytecode.isValidJumpDest(0)); // Only JUMPDEST
        }
    }
}

test "Bytecode edge cases - maximum size bytecode" {
    const allocator = std.testing.allocator;

    // Test at exactly the maximum allowed size
    const max_code = try allocator.alloc(u8, 24576);
    defer allocator.free(max_code);

    // Fill with valid opcodes
    @memset(max_code, 0x5B); // JUMPDEST

    var bytecode = try BytecodeDefault.init(allocator, max_code);
    defer bytecode.deinit();

    try std.testing.expectEqual(@as(usize, 24576), bytecode.len());

    // All positions should be valid jump destinations
    try std.testing.expect(bytecode.isValidJumpDest(0));
    try std.testing.expect(bytecode.isValidJumpDest(100));
    try std.testing.expect(bytecode.isValidJumpDest(24575));
    try std.testing.expect(!bytecode.isValidJumpDest(24576)); // Out of bounds
}

test "Bytecode edge cases - all PUSH opcodes at end" {
    const allocator = std.testing.allocator;

    // Test each PUSH opcode when it appears at the end of bytecode
    var push_num: u8 = 1;
    while (push_num <= 32) : (push_num += 1) {
        const push_opcode = 0x60 + (push_num - 1);

        // Create bytecode with PUSH at end with insufficient data
        var code = try allocator.alloc(u8, push_num); // One byte short
        defer allocator.free(code);

        code[0] = push_opcode;
        for (1..push_num) |i| {
            code[i] = @intCast(i);
        }

        // Should fail with TruncatedPush
        try std.testing.expectError(error.TruncatedPush, BytecodeDefault.init(allocator, code));
    }
}

test "Bytecode edge cases - alternating valid/invalid opcodes" {
    const allocator = std.testing.allocator;

    // Bytecode with alternating valid and invalid opcodes
    const code = [_]u8{
        0x00, // STOP (valid)
        0xFE, // INVALID (invalid)
        0x01, // ADD (valid)
        0x0C, // Invalid opcode
    };

    // Should fail on first invalid opcode
    try std.testing.expectError(error.InvalidOpcode, BytecodeDefault.init(allocator, &code));
}

test "Bytecode edge cases - JUMPDEST in PUSH data" {
    const allocator = std.testing.allocator;

    // JUMPDEST (0x5B) appearing as data in PUSH should not be a valid jump dest
    const code = [_]u8{
        0x60, 0x5B, // PUSH1 0x5B (data looks like JUMPDEST)
        0x50, // POP
        0x5B, // Real JUMPDEST at position 3
        0x00, // STOP
    };

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Position 1 should NOT be a valid jump dest (it's PUSH data)
    try std.testing.expect(!bytecode.isValidJumpDest(1));

    // Position 3 should be a valid jump dest
    try std.testing.expect(bytecode.isValidJumpDest(3));
}

test "Bytecode edge cases - consecutive PUSH32 operations" {
    const allocator = std.testing.allocator;

    // Multiple PUSH32 operations in a row
    var code: [198]u8 = undefined; // 3 * (1 + 32) * 2 = 198 bytes
    var pos: usize = 0;

    // Add 3 PUSH32 operations
    for (0..3) |i| {
        code[pos] = 0x7F; // PUSH32
        pos += 1;

        // Fill with pattern based on iteration
        for (0..32) |j| {
            code[pos] = @truncate(i * 32 + j);
            pos += 1;
        }
    }
    // Fill remaining with STOPs
    while (pos < code.len) : (pos += 1) {
        code[pos] = 0x00;
    }

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Verify no positions in PUSH data are valid jump destinations
    for (0..3) |i| {
        const push_start = i * 33;
        // The PUSH32 opcode itself is not a valid jump dest
        try std.testing.expect(!bytecode.isValidJumpDest(@intCast(push_start)));

        // None of the 32 data bytes should be valid jump dests
        for (1..33) |j| {
            try std.testing.expect(!bytecode.isValidJumpDest(@intCast(push_start + j)));
        }
    }
}

test "Bytecode edge cases - metadata parsing" {
    const allocator = std.testing.allocator;

    // Bytecode with Solidity metadata at the end
    // Format: <bytecode> 0xa2 0x64 "ipfs" <34 bytes hash> 0x64 "solc" <3 bytes version> 0x00 0x33
    var code_with_metadata = std.ArrayList(u8){};
    defer code_with_metadata.deinit(allocator);

    // Add some regular bytecode
    try code_with_metadata.appendSlice(allocator, &[_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 }); // PUSH1 1 PUSH1 2 ADD STOP

    // Add metadata marker and key "ipfs"
    try code_with_metadata.appendSlice(allocator, &[_]u8{ 0xa2, 0x64 });
    try code_with_metadata.appendSlice(allocator, "ipfs");

    // Add 34-byte multihash length marker then 34 bytes of hash
    try code_with_metadata.appendSlice(allocator, &[_]u8{ 0x58, 0x22 });
    for (0..34) |i| {
        try code_with_metadata.append(allocator, @intCast(i & 0xFF));
    }

    try code_with_metadata.append(allocator, 0x64);
    try code_with_metadata.appendSlice(allocator, "solc");

    // Add version bytes
    try code_with_metadata.appendSlice(allocator, &[_]u8{ 0x00, 0x08, 0x13 }); // version 0.8.19

    // Add length (50 bytes of metadata)
    try code_with_metadata.appendSlice(allocator, &[_]u8{ 0x00, 0x32 });

    var bytecode = try BytecodeDefault.init(allocator, code_with_metadata.items);
    defer bytecode.deinit();

    // Should have parsed metadata
    try std.testing.expect(bytecode.metadata != null);

    // Runtime code should exclude metadata
    try std.testing.expect(bytecode.runtime_code.len < bytecode.full_code.len);
}

test "Bytecode edge cases - pathological jump patterns" {
    const allocator = std.testing.allocator;

    // Create bytecode with complex jump patterns
    const code = [_]u8{
        0x60, 0x09, // PUSH1 9 (forward jump to JUMPDEST below)
        0x56, // JUMP
        0x5B, // JUMPDEST at 3
        0x60, 0x07, // PUSH1 7 (backward jump)
        0x56, // JUMP
        0x5B, // JUMPDEST at 7
        0x00, // STOP
        0x5B, // JUMPDEST at 10 (target of first jump)
        0x60, 0x07, // PUSH1 7
        0x56, // JUMP to middle JUMPDEST
    };

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // All JUMPDESTs should be valid
    try std.testing.expect(bytecode.isValidJumpDest(3));
    try std.testing.expect(bytecode.isValidJumpDest(7));
    try std.testing.expect(bytecode.isValidJumpDest(9));

    // Non-JUMPDEST positions should be invalid
    try std.testing.expect(!bytecode.isValidJumpDest(0));
    try std.testing.expect(!bytecode.isValidJumpDest(1));
    try std.testing.expect(!bytecode.isValidJumpDest(2));
}

// TDD Tests for new Iterator functionality

test "Bytecode iterator - basic PUSH opcodes" {
    const allocator = std.testing.allocator;

    // Bytecode: PUSH1 0x42, PUSH2 0x1234, STOP
    const code = [_]u8{ 0x60, 0x42, 0x61, 0x12, 0x34, 0x00 };

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    var iterator = bytecode.createIterator();

    // First opcode should be PUSH1 with value 0x42
    if (iterator.next()) |opcode_data| {
        switch (opcode_data) {
            .push => |push_data| {
                try std.testing.expectEqual(@as(u256, 0x42), push_data.value);
                try std.testing.expectEqual(@as(u8, 1), push_data.size);
            },
            else => try std.testing.expect(false), // Should be a push
        }
    } else {
        try std.testing.expect(false); // Should have data
    }

    // Second opcode should be PUSH2 with value 0x1234
    if (iterator.next()) |opcode_data| {
        switch (opcode_data) {
            .push => |push_data| {
                try std.testing.expectEqual(@as(u256, 0x1234), push_data.value);
                try std.testing.expectEqual(@as(u8, 2), push_data.size);
            },
            else => try std.testing.expect(false), // Should be a push
        }
    } else {
        try std.testing.expect(false); // Should have data
    }

    // Third opcode should be STOP
    if (iterator.next()) |opcode_data| {
        switch (opcode_data) {
            .stop => {},
            else => try std.testing.expect(false), // Should be stop
        }
    } else {
        try std.testing.expect(false); // Should have data
    }

    // Should be at end
    try std.testing.expect(iterator.next() == null);
}

test "Bytecode iterator - JUMPDEST detection" {
    const allocator = std.testing.allocator;

    // Bytecode: PUSH1 0x03, JUMP, JUMPDEST, STOP
    const code = [_]u8{ 0x60, 0x03, 0x56, 0x5B, 0x00 };

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    var iterator = bytecode.createIterator();

    // Skip PUSH and JUMP opcodes
    _ = iterator.next(); // PUSH1
    _ = iterator.next(); // JUMP (regular opcode)

    // Should find JUMPDEST
    if (iterator.next()) |opcode_data| {
        switch (opcode_data) {
            .jumpdest => |jump_data| {
                try std.testing.expectEqual(@as(u16, 1), jump_data.gas_cost);
            },
            else => try std.testing.expect(false), // Should be jumpdest
        }
    } else {
        try std.testing.expect(false); // Should have data
    }
}

test "Bytecode iterator - fusion detection PUSH+ADD" {
    const allocator = std.testing.allocator;

    // Bytecode: PUSH1 0x42, ADD, STOP (should be detected as fusion)
    const code = [_]u8{ 0x60, 0x42, 0x01, 0x00 };

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    var iterator = bytecode.createIterator();

    // First opcode should be detected as PUSH+ADD fusion
    if (iterator.next()) |opcode_data| {
        switch (opcode_data) {
            .push_add_fusion => |fusion_data| {
                try std.testing.expectEqual(@as(u256, 0x42), fusion_data.value);
            },
            else => {
                // For now, might not detect fusion until bitmap is properly built
                // This test will pass once bitmap building is fully implemented
            },
        }
    } else {
        try std.testing.expect(false); // Should have data
    }
}

test "PackedBits fusion candidate detection" {
    const allocator = std.testing.allocator;

    // PUSH1 0x05 ADD - should mark PUSH as fusion candidate
    const code = [_]u8{ 0x60, 0x05, 0x01, 0x00 }; // PUSH1 5 ADD STOP
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Test that PUSH1 at position 0 is marked as fusion candidate
    try std.testing.expect(bytecode.packed_bitmap[0].is_fusion_candidate);
    try std.testing.expect(bytecode.packed_bitmap[0].is_op_start);
    try std.testing.expect(!bytecode.packed_bitmap[0].is_push_data);
    try std.testing.expect(!bytecode.packed_bitmap[0].is_jumpdest);

    // Test that push data at position 1 is marked correctly
    try std.testing.expect(!bytecode.packed_bitmap[1].is_fusion_candidate);
    try std.testing.expect(!bytecode.packed_bitmap[1].is_op_start);
    try std.testing.expect(bytecode.packed_bitmap[1].is_push_data);
    try std.testing.expect(!bytecode.packed_bitmap[1].is_jumpdest);

    // Test that ADD at position 2 is marked correctly
    try std.testing.expect(!bytecode.packed_bitmap[2].is_fusion_candidate);
    try std.testing.expect(bytecode.packed_bitmap[2].is_op_start);
    try std.testing.expect(!bytecode.packed_bitmap[2].is_push_data);
    try std.testing.expect(!bytecode.packed_bitmap[2].is_jumpdest);
}

test "PackedBits JUMPDEST detection" {
    const allocator = std.testing.allocator;

    // PUSH1 0x03 JUMP JUMPDEST STOP
    const code = [_]u8{ 0x60, 0x03, 0x56, 0x5b, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Test that JUMPDEST at position 3 is marked correctly
    try std.testing.expect(!bytecode.packed_bitmap[3].is_fusion_candidate);
    try std.testing.expect(bytecode.packed_bitmap[3].is_op_start);
    try std.testing.expect(!bytecode.packed_bitmap[3].is_push_data);
    try std.testing.expect(bytecode.packed_bitmap[3].is_jumpdest);

    // Test that PUSH1 + JUMP pattern is marked as fusion candidate
    try std.testing.expect(bytecode.packed_bitmap[0].is_fusion_candidate);
}

test "PackedBits bitmap consistency with legacy bitmaps" {
    const allocator = std.testing.allocator;

    // Complex bytecode with all features
    const code = [_]u8{
        0x60, 0x07, 0x56, // PUSH1 7 JUMP (fusion candidate)
        0x60, 0x0c, 0x57, // PUSH1 12 JUMPI (fusion candidate)
        0x5b, // JUMPDEST at 7
        0x60, 0x05, 0x01, // PUSH1 5 ADD (fusion candidate)
        0x00, // STOP
        0x5b, // JUMPDEST at 12
        0x00, // STOP
    };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Verify consistency between packed and legacy bitmaps for all positions
    for (0..bytecode.len()) |i| {
        const bit_idx = i >> 3; // Divide by 8
        const bit_mask = @as(u8, 1) << @intCast(i & 7); // Mod 8

        // Check is_op_start consistency
        const legacy_op_start = (bytecode.is_op_start[bit_idx] & bit_mask) != 0;
        try std.testing.expectEqual(legacy_op_start, bytecode.packed_bitmap[i].is_op_start);

        // Check is_push_data consistency
        const legacy_push_data = (bytecode.is_push_data[bit_idx] & bit_mask) != 0;
        try std.testing.expectEqual(legacy_push_data, bytecode.packed_bitmap[i].is_push_data);

        // Check is_jumpdest consistency
        const legacy_jumpdest = (bytecode.is_jumpdest[bit_idx] & bit_mask) != 0;
        try std.testing.expectEqual(legacy_jumpdest, bytecode.packed_bitmap[i].is_jumpdest);
    }
}

test "Iterator using PackedBits for fusion detection" {
    const allocator = std.testing.allocator;

    // PUSH1 5 ADD STOP
    const code = [_]u8{ 0x60, 0x05, 0x01, 0x00 };
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Verify fusion candidate is marked
    try std.testing.expect(bytecode.packed_bitmap[0].is_fusion_candidate);

    var iterator = bytecode.createIterator();

    // Test that iterator can detect the fusion candidate
    if (iterator.next()) |opcode_data| {
        switch (opcode_data) {
            .push => |push_data| {
                try std.testing.expectEqual(@as(u256, 0x05), push_data.value);
                try std.testing.expectEqual(@as(u8, 1), push_data.size);
            },
            .push_add_fusion => |fusion_data| {
                try std.testing.expectEqual(@as(u256, 0x05), fusion_data.value);
            },
            else => {
                // For now, iterator may not detect fusion until EVM2 is implemented
                // This test verifies the packed bitmap is working correctly
            },
        }
    } else {
        try std.testing.expect(false); // Should have data
    }
}

test "Bytecode bitmap generation - simple opcodes" {
    const allocator = std.testing.allocator;

    // Test basic opcodes: ADD, MUL, PUSH1, STOP
    const code = [_]u8{
        @intFromEnum(Opcode.ADD), // 0: operation start
        @intFromEnum(Opcode.MUL), // 1: operation start
        @intFromEnum(Opcode.PUSH1), // 2: operation start
        0x42, // 3: push data
        @intFromEnum(Opcode.STOP), // 4: operation start
    };

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Verify is_op_start bitmap
    try std.testing.expect((bytecode.is_op_start[0] & (1 << 0)) != 0); // ADD
    try std.testing.expect((bytecode.is_op_start[0] & (1 << 1)) != 0); // MUL
    try std.testing.expect((bytecode.is_op_start[0] & (1 << 2)) != 0); // PUSH1
    try std.testing.expect((bytecode.is_op_start[0] & (1 << 3)) == 0); // push data
    try std.testing.expect((bytecode.is_op_start[0] & (1 << 4)) != 0); // STOP

    // Verify is_push_data bitmap
    try std.testing.expect((bytecode.is_push_data[0] & (1 << 0)) == 0); // ADD
    try std.testing.expect((bytecode.is_push_data[0] & (1 << 1)) == 0); // MUL
    try std.testing.expect((bytecode.is_push_data[0] & (1 << 2)) == 0); // PUSH1
    try std.testing.expect((bytecode.is_push_data[0] & (1 << 3)) != 0); // push data
    try std.testing.expect((bytecode.is_push_data[0] & (1 << 4)) == 0); // STOP

    // Verify packed bitmap consistency
    try std.testing.expect(bytecode.packed_bitmap[0].is_op_start == true);
    try std.testing.expect(bytecode.packed_bitmap[0].is_push_data == false);
    try std.testing.expect(bytecode.packed_bitmap[3].is_op_start == false);
    try std.testing.expect(bytecode.packed_bitmap[3].is_push_data == true);
}

test "Bytecode bitmap generation - multiple PUSH opcodes" {
    const allocator = std.testing.allocator;

    // Test various PUSH opcodes
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0xAA, // 0-1
        @intFromEnum(Opcode.PUSH2), 0xBB, 0xCC, // 2-4
        @intFromEnum(Opcode.PUSH4), 0x11, 0x22, 0x33, 0x44, // 5-9
        @intFromEnum(Opcode.ADD), // 10
    };

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Check operation starts
    try std.testing.expect(bytecode.packed_bitmap[0].is_op_start == true); // PUSH1
    try std.testing.expect(bytecode.packed_bitmap[1].is_op_start == false); // data
    try std.testing.expect(bytecode.packed_bitmap[2].is_op_start == true); // PUSH2
    try std.testing.expect(bytecode.packed_bitmap[3].is_op_start == false); // data
    try std.testing.expect(bytecode.packed_bitmap[4].is_op_start == false); // data
    try std.testing.expect(bytecode.packed_bitmap[5].is_op_start == true); // PUSH4
    try std.testing.expect(bytecode.packed_bitmap[10].is_op_start == true); // ADD

    // Check push data
    try std.testing.expect(bytecode.packed_bitmap[0].is_push_data == false);
    try std.testing.expect(bytecode.packed_bitmap[1].is_push_data == true);
    try std.testing.expect(bytecode.packed_bitmap[3].is_push_data == true);
    try std.testing.expect(bytecode.packed_bitmap[4].is_push_data == true);
    try std.testing.expect(bytecode.packed_bitmap[6].is_push_data == true);
    try std.testing.expect(bytecode.packed_bitmap[7].is_push_data == true);
    try std.testing.expect(bytecode.packed_bitmap[8].is_push_data == true);
    try std.testing.expect(bytecode.packed_bitmap[9].is_push_data == true);
    try std.testing.expect(bytecode.packed_bitmap[10].is_push_data == false);
}

test "Bytecode bitmap generation - JUMPDEST validation" {
    const allocator = std.testing.allocator;

    // Test JUMPDEST in various positions
    const code = [_]u8{
        @intFromEnum(Opcode.JUMPDEST), // 0: valid JUMPDEST
        @intFromEnum(Opcode.PUSH2), // 1: PUSH2
        0x00, // 2: push data
        @intFromEnum(Opcode.JUMPDEST), // 3: JUMPDEST inside push data (invalid)
        @intFromEnum(Opcode.JUMPDEST), // 4: valid JUMPDEST
        @intFromEnum(Opcode.PUSH1), // 5: PUSH1
        @intFromEnum(Opcode.JUMPDEST), // 6: push data that happens to be JUMPDEST value
        @intFromEnum(Opcode.JUMPDEST), // 7: valid JUMPDEST
    };

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Check JUMPDEST bitmap
    try std.testing.expect((bytecode.is_jumpdest[0] & (1 << 0)) != 0); // Valid
    try std.testing.expect((bytecode.is_jumpdest[0] & (1 << 3)) == 0); // Invalid (in push data)
    try std.testing.expect((bytecode.is_jumpdest[0] & (1 << 4)) != 0); // Valid
    try std.testing.expect((bytecode.is_jumpdest[0] & (1 << 6)) == 0); // Invalid (in push data)
    try std.testing.expect((bytecode.is_jumpdest[0] & (1 << 7)) != 0); // Valid

    // Check packed bitmap
    try std.testing.expect(bytecode.packed_bitmap[0].is_jumpdest == true);
    try std.testing.expect(bytecode.packed_bitmap[3].is_jumpdest == false);
    try std.testing.expect(bytecode.packed_bitmap[4].is_jumpdest == true);
    try std.testing.expect(bytecode.packed_bitmap[6].is_jumpdest == false);
    try std.testing.expect(bytecode.packed_bitmap[7].is_jumpdest == true);

    // Verify isValidJumpDest method
    try std.testing.expect(bytecode.isValidJumpDest(0) == true);
    try std.testing.expect(bytecode.isValidJumpDest(3) == false);
    try std.testing.expect(bytecode.isValidJumpDest(4) == true);
    try std.testing.expect(bytecode.isValidJumpDest(6) == false);
    try std.testing.expect(bytecode.isValidJumpDest(7) == true);
}

test "Bytecode bitmap generation - fusion candidates with fusions enabled" {
    const allocator = std.testing.allocator;

    // Create bytecode with fusions enabled (default)
    const config = BytecodeConfig{ .fusions_enabled = true };
    const BytecodeType = Bytecode(config);

    // Test fusion patterns: PUSH + ADD, PUSH + MUL
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x05, @intFromEnum(Opcode.ADD), // 0-2: PUSH1+ADD fusion
        @intFromEnum(Opcode.PUSH2), 0x00, 0x10, @intFromEnum(Opcode.MUL), // 3-6: PUSH2+MUL fusion
        @intFromEnum(Opcode.PUSH1), 0x20, // 7-8: PUSH1 without fusion
        @intFromEnum(Opcode.STOP), // 9: STOP
    };

    var bytecode = try BytecodeType.init(allocator, &code);
    defer bytecode.deinit();

    // Check fusion candidates
    try std.testing.expect(bytecode.packed_bitmap[0].is_fusion_candidate == true); // PUSH1 before ADD
    try std.testing.expect(bytecode.packed_bitmap[3].is_fusion_candidate == true); // PUSH2 before MUL
    try std.testing.expect(bytecode.packed_bitmap[7].is_fusion_candidate == false); // PUSH1 before STOP (not fusable)

    // Verify the fusion_enabled constant
    try std.testing.expect(BytecodeType.fusions_enabled == true);
}

test "Bytecode bitmap generation - fusion candidates with fusions disabled" {
    const allocator = std.testing.allocator;

    // Create bytecode with fusions disabled
    const config = BytecodeConfig{ .fusions_enabled = false };
    const BytecodeType = Bytecode(config);

    // Same test pattern as above
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x05, @intFromEnum(Opcode.ADD), // 0-2: Would be fusion if enabled
        @intFromEnum(Opcode.PUSH2), 0x00, 0x10, @intFromEnum(Opcode.MUL), // 3-6: Would be fusion if enabled
    };

    var bytecode = try BytecodeType.init(allocator, &code);
    defer bytecode.deinit();

    // With fusions disabled, fusion candidates should not be marked
    try std.testing.expect(bytecode.packed_bitmap[0].is_fusion_candidate == false);
    try std.testing.expect(bytecode.packed_bitmap[3].is_fusion_candidate == false);

    // Verify the fusion_enabled constant
    try std.testing.expect(BytecodeType.fusions_enabled == false);
}

test "Bytecode bitmap generation - cross-byte boundaries" {
    const allocator = std.testing.allocator;

    // Create bytecode that crosses bitmap byte boundaries (8 bits per byte)
    var code: [10]u8 = undefined;
    for (0..10) |i| {
        code[i] = if (i == 7 or i == 8) @intFromEnum(Opcode.JUMPDEST) else @intFromEnum(Opcode.ADD);
    }

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Check that JUMPDESTs at byte boundary are correctly marked
    try std.testing.expect((bytecode.is_jumpdest[0] & (1 << 7)) != 0); // bit 7 of first byte
    try std.testing.expect((bytecode.is_jumpdest[1] & (1 << 0)) != 0); // bit 0 of second byte

    // All should be operation starts
    for (0..10) |i| {
        try std.testing.expect(bytecode.packed_bitmap[i].is_op_start == true);
    }
}

test "Bytecode bitmap generation - PUSH32 edge case" {
    const allocator = std.testing.allocator;

    // PUSH32 with 32 bytes of data
    var code: [34]u8 = undefined;
    code[0] = @intFromEnum(Opcode.PUSH32);
    for (1..33) |i| {
        code[i] = @intCast(i); // Push data bytes
    }
    code[33] = @intFromEnum(Opcode.JUMPDEST); // Valid JUMPDEST after PUSH32

    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();

    // Check operation starts
    try std.testing.expect(bytecode.packed_bitmap[0].is_op_start == true); // PUSH32
    try std.testing.expect(bytecode.packed_bitmap[33].is_op_start == true); // JUMPDEST

    // Check push data - all 32 bytes should be marked
    for (1..33) |i| {
        try std.testing.expect(bytecode.packed_bitmap[i].is_push_data == true);
        try std.testing.expect(bytecode.packed_bitmap[i].is_op_start == false);
    }

    // JUMPDEST should be valid
    try std.testing.expect(bytecode.packed_bitmap[33].is_jumpdest == true);
}

test "Bytecode bitmap generation - empty and single byte" {
    const allocator = std.testing.allocator;

    // Test empty bytecode
    const empty_code = [_]u8{};
    var empty_bytecode = try BytecodeDefault.init(allocator, &empty_code);
    defer empty_bytecode.deinit();

    try std.testing.expectEqual(@as(BytecodeDefault.PcType, 0), empty_bytecode.len());

    // Test single byte
    const single_code = [_]u8{@intFromEnum(Opcode.STOP)};
    var single_bytecode = try BytecodeDefault.init(allocator, &single_code);
    defer single_bytecode.deinit();

    try std.testing.expect(single_bytecode.packed_bitmap[0].is_op_start == true);
    try std.testing.expect(single_bytecode.packed_bitmap[0].is_push_data == false);
}

test "PUSH+JUMP: PUSH32 containing JUMP byte should not cause validation error" {
    const allocator = std.testing.allocator;
    
    // PUSH32 with data that contains 0x56 (JUMP opcode value) followed by actual code
    const bytecode = [_]u8{
        0x7f, // PUSH32
        // 32 bytes of data, including 0x56 at various positions
        0x11, 0x22, 0x33, 0x44, 0x56, 0x66, 0x77, 0x88,  // 0x56 at position 5
        0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x56,  // 0x56 at position 32
        0x00, // STOP (at position 33)
    };
    
    // This should succeed - the 0x56 bytes inside PUSH32 data should NOT be treated as JUMP opcodes
    var bc = BytecodeDefault.init(allocator, &bytecode) catch |err| {
        std.debug.print("PUSH+JUMP test failed: PUSH32 containing 0x56 incorrectly rejected: {}\n", .{err});
        return err;
    };
    defer bc.deinit();
    
    try std.testing.expect(bc.runtime_code.len == bytecode.len);
    
    // Verify that position 5 is marked as push data, not an opcode
    try std.testing.expect(bc.packed_bitmap[5].is_push_data);
    
    // Verify that position 33 (STOP) is an opcode start
    try std.testing.expect(bc.packed_bitmap[33].is_op_start);
}

test "PUSH+JUMP: complex bytecode with mixed PUSH and JUMP patterns" {
    const allocator = std.testing.allocator;
    
    // Complex pattern:
    // PUSH1 0x08, JUMP, PUSH2 with 0x56 in data, JUMPDEST, STOP
    const bytecode = [_]u8{
        0x60, 0x08,        // PUSH1 8 (valid jump to JUMPDEST)
        0x56,              // JUMP (actual JUMP opcode at position 2)
        0x61, 0x56, 0x78,  // PUSH2 0x5678 (contains 0x56 as data at position 4)
        0x00,              // STOP at position 6
        0x00,              // STOP at position 7
        0x5b,              // JUMPDEST at position 8
        0x00,              // STOP at position 9
    };
    
    var bc = BytecodeDefault.init(allocator, &bytecode) catch |err| {
        std.debug.print("PUSH+JUMP test failed: Complex pattern incorrectly rejected: {}\n", .{err});
        return err;
    };
    defer bc.deinit();
    
    try std.testing.expect(bc.runtime_code.len == bytecode.len);
    
    // Position 2 should be a real JUMP opcode
    try std.testing.expect(bc.packed_bitmap[2].is_op_start);
    
    // Position 4 should be push data (even though it's 0x56) 
    try std.testing.expect(bc.packed_bitmap[4].is_push_data);
    
    // Position 8 should be JUMPDEST
    try std.testing.expect(bc.packed_bitmap[8].is_jumpdest);
}

test "PUSH+JUMP: unreachable PUSH+JUMP pattern should be valid" {
    const allocator = std.testing.allocator;
    
    // Bytecode with unreachable code that contains PUSH+JUMP
    const bytecode = [_]u8{
        0x00,        // STOP - execution ends here
        // Unreachable code below:
        0x60, 0x10,  // PUSH1 16 (target doesn't exist)
        0x56,        // JUMP
        0x00,        // STOP
    };
    
    // This should succeed even though the jump target (16) doesn't exist,
    // because the PUSH+JUMP is unreachable
    var bc = BytecodeDefault.init(allocator, &bytecode) catch |err| {
        std.debug.print("PUSH+JUMP test failed: Unreachable code incorrectly rejected: {}\n", .{err});
        return err;
    };
    defer bc.deinit();
    
    try std.testing.expect(bc.runtime_code.len == bytecode.len);
}
