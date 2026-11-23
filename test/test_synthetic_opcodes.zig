const std = @import("std");
const evm = @import("evm");
const OpcodeSynthetic = evm.OpcodeSynthetic.OpcodeSynthetic;

test "every synthetic opcode has an internal handler" {
    const Frame = evm.DefaultEvm.Frame;
    inline for (std.meta.tags(OpcodeSynthetic)) |opcode| {
        const value = @intFromEnum(opcode);
        const handler = evm.frame_handlers.getSyntheticHandler(Frame, value);
        try std.testing.expect(handler != Frame.opcode_handlers[value]);
    }
}

test "synthetic opcodes occupy their reserved range" {
    for (std.meta.tags(OpcodeSynthetic)) |opcode| {
        const value = @intFromEnum(opcode);
        try std.testing.expect(value >= 0xA5 and value <= 0xCF);
    }
}

test "synthetic opcode count" {
    try std.testing.expectEqual(@as(usize, 39), std.meta.tags(OpcodeSynthetic).len);
}
