const std = @import("std");
const primitives = @import("primitives");
const evm = @import("evm");
const log = std.log.scoped(.push32_test);

test "PUSH32 dispatch investigation" {
    const allocator = std.testing.allocator;
    
    // Just PUSH32, PUSH1, SDIV bytecode
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xf8, // -8
        0x60, 0x03, // PUSH1 3
        0x05,       // SDIV
        0x00,       // STOP
    };
    
    const Bytecode = evm.Bytecode(.{});
    var bc = try Bytecode.init(allocator, &bytecode);
    defer bc.deinit();
    
    log.warn("\n=== Analyzing PUSH32 bytecode ===", .{});
    log.warn("Bytecode length: {}", .{bc.runtime_code.len});
    
    // Iterate through parsed bytecode
    var iter = bc.createIterator();
    var op_index: usize = 0;
    log.warn("\nParsed opcodes:", .{});
    while (iter.next()) |op_data| {
        switch (op_data) {
            .push => |data| {
                log.warn("  [{}] PC={}: PUSH{} value=0x{x}", .{ op_index, iter.pc - data.size - 1, data.size, data.value });
            },
            .regular => |data| {
                log.warn("  [{}] PC={}: opcode=0x{x:0>2}", .{ op_index, iter.pc - 1, data.opcode });
            },
            .stop => {
                log.warn("  [{}] PC={}: STOP", .{ op_index, iter.pc - 1 });
            },
            else => {
                log.warn("  [{}] PC={}: {}", .{ op_index, iter.pc - 1, @tagName(op_data) });
            },
        }
        op_index += 1;
    }
    
    // Build dispatch schedule
    const Frame = evm.StackFrame(.{});
    const handlers = &Frame.opcode_handlers;
    const Dispatch = evm.Dispatch(Frame);
    
    const schedule = try Dispatch.init(allocator, &bc, handlers);
    defer Dispatch.deinitSchedule(allocator, schedule);
    
    log.warn("\nDispatch schedule (length={}):", .{schedule.len});
    
    for (schedule, 0..) |item, i| {
        switch (item) {
            .first_block_gas => |meta| {
                log.warn("  [{}] first_block_gas: gas={}", .{ i, meta.gas });
            },
            .opcode_handler => |h| {
                log.warn("  [{}] opcode_handler: {*}", .{ i, h });
            },
            .push_pointer => |meta| {
                log.warn("  [{}] push_pointer: value=0x{x}", .{ i, meta.value.* });
            },
            .push_inline => |meta| {
                log.warn("  [{}] push_inline: value=0x{x}", .{ i, meta.value });
            },
            else => {
                log.warn("  [{}] {}", .{ i, @tagName(item) });
            },
        }
    }
}