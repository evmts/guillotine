const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const bytecode_mod = @import("../src/bytecode/bytecode.zig");
const dispatch_mod = @import("../src/preprocessor/dispatch.zig");

test "dispatch building observability for CALL bytecode" {
    std.testing.log_level = .debug;
    const allocator = std.testing.allocator;

    // The exact bytecode from failing CALL test
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

    std.debug.print("\n=== Testing dispatch building for CALL bytecode ===\n", .{});

    // Create bytecode with fusions enabled
    const BytecodeType = bytecode_mod.Bytecode(.{
        .max_bytecode_size = 24576,
        .pc_type = u16,
        .fusions_enabled = true,
    });

    var bytecode = try BytecodeType.init(allocator, test_bytecode);
    defer bytecode.deinit();

    // Create frame to get dispatch
    const FrameType = evm.frame.Frame(.{
        .pc_type = u16,
        .call_stack_size = 1024,
        .disable_gas = false,
        .depth_limit = 1024,
        .enable_stack_depth_validation = true,
        .enable_invariant_checks = false,
        .loop_quota = 300_000_000,
    });

    // Build dispatch schedule
    std.debug.print("\n=== Building dispatch schedule ===\n", .{});
    const dispatch_schedule = try dispatch_mod.Dispatch(FrameType).buildFrom(
        allocator,
        bytecode,
        &FrameType.opcode_handlers,
        null, // No tracer
    );
    defer dispatch_schedule.deinit();

    std.debug.print("\n=== Dispatch schedule built with {} items ===\n", .{dispatch_schedule.items.len});

    // Print first few dispatch items
    for (dispatch_schedule.items[0..@min(20, dispatch_schedule.items.len)], 0..) |item, i| {
        std.debug.print("Schedule[{}]: {s}\n", .{i, @tagName(item)});
    }
}