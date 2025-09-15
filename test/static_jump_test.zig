const std = @import("std");
const testing = std.testing;
const Frame = @import("../src/frame/frame.zig").Frame;
const FrameConfig = @import("../src/frame/frame_config.zig").FrameConfig;
const dispatch_mod = @import("../src/preprocessor/dispatch.zig");
const bytecode_mod = @import("../src/bytecode/bytecode.zig");
const bytecode_builder = @import("../src/bytecode/bytecode_builder.zig");
const opcode_data = @import("../src/opcodes/opcode_data.zig");
const DefaultTracer = @import("../src/tracer/tracer.zig").DefaultTracer;
const MemoryDatabase = @import("../src/storage/memory_database.zig").MemoryDatabase;
const Address = @import("primitives").Address;
const frame_handlers = @import("../src/frame/frame_handlers.zig");

// Test configuration
const test_config = FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 1024,
    .block_gas_limit = 30_000_000,
    .DatabaseType = MemoryDatabase,
    .TracerType = DefaultTracer,
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF,
};

const TestFrame = Frame(test_config);
const Dispatch = dispatch_mod.Dispatch(TestFrame);

test "static jump optimization - valid jump to JUMPDEST" {
    const allocator = testing.allocator;

    // Build bytecode with PUSH+JUMP fusion to a valid JUMPDEST
    var builder = bytecode_builder.BytecodeBuilder.init(allocator);
    defer builder.deinit();

    // Add a PUSH 5 + JUMP fusion (should jump to PC 5)
    try builder.appendPush(5);
    try builder.appendOpcode(@intFromEnum(opcode_data.Opcode.JUMP));
    // Add some padding
    try builder.appendOpcode(@intFromEnum(opcode_data.Opcode.INVALID));
    try builder.appendOpcode(@intFromEnum(opcode_data.Opcode.INVALID));
    // Add JUMPDEST at PC 5
    try builder.appendOpcode(@intFromEnum(opcode_data.Opcode.JUMPDEST));
    // Add STOP after JUMPDEST
    try builder.appendOpcode(@intFromEnum(opcode_data.Opcode.STOP));

    const raw_bytes = try builder.toOwnedSlice();
    defer allocator.free(raw_bytes);

    // Create analyzed bytecode
    const analyzed = try bytecode_mod.AnalyzedBytecode.init(allocator, raw_bytes);
    defer analyzed.deinit(allocator);

    // Create dispatch schedule
    const opcode_handlers = frame_handlers.getOpcodeHandlers(TestFrame);
    const schedule = try Dispatch.init(allocator, analyzed, &opcode_handlers);
    defer allocator.free(schedule);

    // Verify the schedule contains a static jump handler
    var found_static_jump = false;
    const JumpSyntheticHandlers = @import("../src/instructions/handlers_jump_synthetic.zig").Handlers(TestFrame);

    for (schedule) |item| {
        switch (item) {
            .opcode_handler => |handler| {
                if (handler == &JumpSyntheticHandlers.jump_to_static_location) {
                    found_static_jump = true;
                    break;
                }
            },
            else => {},
        }
    }

    try testing.expect(found_static_jump);
}

test "static jump optimization - invalid jump falls back to inline" {
    const allocator = testing.allocator;

    // Build bytecode with PUSH+JUMP fusion to an invalid destination (not a JUMPDEST)
    var builder = bytecode_builder.BytecodeBuilder.init(allocator);
    defer builder.deinit();

    // Add a PUSH 3 + JUMP fusion (jumps to PC 3, which is not a JUMPDEST)
    try builder.appendPush(3);
    try builder.appendOpcode(@intFromEnum(opcode_data.Opcode.JUMP));
    // Add INVALID at PC 3 (not a JUMPDEST)
    try builder.appendOpcode(@intFromEnum(opcode_data.Opcode.INVALID));
    try builder.appendOpcode(@intFromEnum(opcode_data.Opcode.STOP));

    const raw_bytes = try builder.toOwnedSlice();
    defer allocator.free(raw_bytes);

    // Create analyzed bytecode
    const analyzed = try bytecode_mod.AnalyzedBytecode.init(allocator, raw_bytes);
    defer analyzed.deinit(allocator);

    // Create dispatch schedule
    const opcode_handlers = frame_handlers.getOpcodeHandlers(TestFrame);
    const schedule = try Dispatch.init(allocator, analyzed, &opcode_handlers);
    defer allocator.free(schedule);

    // Verify the schedule contains an inline jump handler (not static)
    var found_inline_jump = false;
    const JumpSyntheticHandlers = @import("../src/instructions/handlers_jump_synthetic.zig").Handlers(TestFrame);

    for (schedule) |item| {
        switch (item) {
            .opcode_handler => |handler| {
                if (handler == &JumpSyntheticHandlers.push_jump_inline) {
                    found_inline_jump = true;
                    break;
                }
            },
            else => {},
        }
    }

    try testing.expect(found_inline_jump);
}

test "static jumpi optimization - conditional jump to valid JUMPDEST" {
    const allocator = testing.allocator;

    // Build bytecode with PUSH+JUMPI fusion to a valid JUMPDEST
    var builder = bytecode_builder.BytecodeBuilder.init(allocator);
    defer builder.deinit();

    // Push condition value (1 = true)
    try builder.appendPush(1);
    // Add a PUSH 6 + JUMPI fusion (should jump to PC 6)
    try builder.appendPush(6);
    try builder.appendOpcode(@intFromEnum(opcode_data.Opcode.JUMPI));
    // Add some padding
    try builder.appendOpcode(@intFromEnum(opcode_data.Opcode.INVALID));
    // Add JUMPDEST at PC 6
    try builder.appendOpcode(@intFromEnum(opcode_data.Opcode.JUMPDEST));
    // Add STOP after JUMPDEST
    try builder.appendOpcode(@intFromEnum(opcode_data.Opcode.STOP));

    const raw_bytes = try builder.toOwnedSlice();
    defer allocator.free(raw_bytes);

    // Create analyzed bytecode
    const analyzed = try bytecode_mod.AnalyzedBytecode.init(allocator, raw_bytes);
    defer analyzed.deinit(allocator);

    // Create dispatch schedule
    const opcode_handlers = frame_handlers.getOpcodeHandlers(TestFrame);
    const schedule = try Dispatch.init(allocator, analyzed, &opcode_handlers);
    defer allocator.free(schedule);

    // Verify the schedule contains a static jumpi handler
    var found_static_jumpi = false;
    const JumpSyntheticHandlers = @import("../src/instructions/handlers_jump_synthetic.zig").Handlers(TestFrame);

    for (schedule) |item| {
        switch (item) {
            .opcode_handler => |handler| {
                if (handler == &JumpSyntheticHandlers.jumpi_to_static_location) {
                    found_static_jumpi = true;
                    break;
                }
            },
            else => {},
        }
    }

    try testing.expect(found_static_jumpi);
}
