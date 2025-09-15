const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const bytecode_mod = @import("../src/bytecode/bytecode.zig");
const dispatch_mod = @import("../src/preprocessor/dispatch.zig");

// Test to debug dispatch building
test "debug dispatch building for CALL bytecode" {
    const allocator = std.testing.allocator;

    // The exact bytecode that's failing (0xf1 CALL test)
    const test_bytecode = &[_]u8{
        0x5f, // PC=0: PUSH0
        0x5f, // PC=1: PUSH0
        0x5f, // PC=2: PUSH0
        0x5f, // PC=3: PUSH0
        0x5f, // PC=4: PUSH0
        0x30, // PC=5: ADDRESS
        0x61, // PC=6: PUSH2
        0x27, // PC=7: value byte 1
        0x10, // PC=8: value byte 2
        0xf1, // PC=9: CALL
        0x60, // PC=10: PUSH1
        0x00, // PC=11: value 0
        0x52, // PC=12: MSTORE
        0x60, // PC=13: PUSH1
        0x20, // PC=14: value 32
        0x60, // PC=15: PUSH1
        0x00, // PC=16: value 0
        0xf3, // PC=17: RETURN
    };

    std.debug.print("\n=== Analyzing bytecode ===\n", .{});
    for (test_bytecode, 0..) |byte, i| {
        std.debug.print("PC={d:2}: 0x{x:0>2}", .{i, byte});
        switch (byte) {
            0x5f => std.debug.print(" PUSH0", .{}),
            0x30 => std.debug.print(" ADDRESS", .{}),
            0x60 => std.debug.print(" PUSH1", .{}),
            0x61 => std.debug.print(" PUSH2", .{}),
            0x52 => std.debug.print(" MSTORE", .{}),
            0xf1 => std.debug.print(" CALL", .{}),
            0xf3 => std.debug.print(" RETURN", .{}),
            else => {},
        }
        std.debug.print("\n", .{});
    }

    // Create bytecode object with the test config
    const BytecodeType = bytecode_mod.Bytecode(.{
        .max_bytecode_size = 24576,
        .pc_type = u16,
        .fusions_enabled = true,
    });

    var bytecode = try BytecodeType.init(allocator, test_bytecode);
    defer bytecode.deinit();

    // Create iterator and examine what it produces
    std.debug.print("\n=== Bytecode iterator output ===\n", .{});
    var iter = bytecode.createIterator();
    var op_index: usize = 0;

    while (iter.next()) |op_data| {
        std.debug.print("Op {d}: PC={d}, ", .{op_index, iter.pc});

        switch (op_data) {
            .regular => |data| {
                std.debug.print("regular opcode=0x{x:0>2}\n", .{data.opcode});
            },
            .push => |data| {
                std.debug.print("push size={d} value={d}\n", .{data.size, data.value});
            },
            .push_mstore_fusion => |data| {
                std.debug.print("PUSH_MSTORE_FUSION value={d}\n", .{data.value});
            },
            .jumpdest => |data| {
                std.debug.print("jumpdest gas={d}\n", .{data.gas_cost});
            },
            .stop => {
                std.debug.print("stop\n", .{});
            },
            .invalid => {
                std.debug.print("invalid\n", .{});
            },
            else => {
                std.debug.print("other fusion: {s}\n", .{@tagName(op_data)});
            }
        }

        op_index += 1;
    }

    std.debug.print("\n=== Analysis complete ===\n", .{});
}

// Simple test for PUSH0 followed by STOP
test "debug simple PUSH0 dispatch" {
    const allocator = std.testing.allocator;

    const simple_bytecode = &[_]u8{
        0x5f, // PUSH0
        0x00, // STOP
    };

    std.debug.print("\n=== Simple bytecode test ===\n", .{});

    const BytecodeType = bytecode_mod.Bytecode(.{
        .max_bytecode_size = 24576,
        .pc_type = u16,
        .fusions_enabled = true,
    });

    var bytecode = try BytecodeType.init(allocator, simple_bytecode);
    defer bytecode.deinit();

    var iter = bytecode.createIterator();
    while (iter.next()) |op_data| {
        std.debug.print("PC={d}: {s}\n", .{iter.pc, @tagName(op_data)});
    }
}

// Test PUSH1+MSTORE fusion detection
test "debug PUSH1 MSTORE fusion" {
    const allocator = std.testing.allocator;

    const fusion_bytecode = &[_]u8{
        0x60, // PUSH1
        0x00, // value 0
        0x52, // MSTORE
        0x00, // STOP
    };

    std.debug.print("\n=== PUSH1+MSTORE fusion test ===\n", .{});

    const BytecodeType = bytecode_mod.Bytecode(.{
        .max_bytecode_size = 24576,
        .pc_type = u16,
        .fusions_enabled = true,
    });

    var bytecode = try BytecodeType.init(allocator, fusion_bytecode);
    defer bytecode.deinit();

    var iter = bytecode.createIterator();
    while (iter.next()) |op_data| {
        std.debug.print("PC={d}: ", .{iter.pc});
        switch (op_data) {
            .push_mstore_fusion => |data| {
                std.debug.print("PUSH_MSTORE_FUSION detected! value={d}\n", .{data.value});
            },
            else => {
                std.debug.print("{s}\n", .{@tagName(op_data)});
            }
        }
    }
}