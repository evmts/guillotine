const std = @import("std");
const Opcode = @import("opcode_data.zig").Opcode;

/// Pretty print the dispatch instruction stream in a human-readable format
/// Shows both the original bytecode and the optimized instruction stream
/// Returns an allocated string that must be freed by the caller
pub fn pretty_print(comptime FrameType: type, allocator: std.mem.Allocator, schedule: anytype, bytecode: anytype) ![]u8 {
    var output = std.ArrayListAligned(u8, null){
        .items = &.{},
        .capacity = 0,
    };
    defer output.deinit(allocator);

    // ANSI color codes for formatting
    const Colors = struct {
        const reset = "\x1b[0m";
        const bold = "\x1b[1m";
        const dim = "\x1b[2m";
        const red = "\x1b[31m";
        const green = "\x1b[32m";
        const yellow = "\x1b[33m";
        const blue = "\x1b[34m";
        const magenta = "\x1b[35m";
        const cyan = "\x1b[36m";
        const white = "\x1b[37m";
        const bright_red = "\x1b[91m";
        const bright_green = "\x1b[92m";
        const bright_yellow = "\x1b[93m";
        const bright_blue = "\x1b[94m";
        const bright_magenta = "\x1b[95m";
        const bright_cyan = "\x1b[96m";
    };

    // Header
    try output.writer(allocator).print("{s}=== EVM Dispatch Instruction Stream ==={s}\n", .{ Colors.bold, Colors.reset });
    try output.writer(allocator).print("{s}Original bytecode: {} bytes, Dispatch items: {}{s}\n\n", .{ Colors.dim, bytecode.runtime_code.len, schedule.len, Colors.reset });

    // Section showing original bytecode
    try output.writer(allocator).print("{s}--- Original Bytecode ---{s}\n", .{ Colors.bold, Colors.reset });
    if (bytecode.runtime_code.len > 0) {
        const runtime_code = bytecode.runtime_code;
        var bytecode_pc: FrameType.PcType = 0;
        while (bytecode_pc < runtime_code.len) {
            const opcode_byte = runtime_code[bytecode_pc];

            // Show PC and hex
            try output.writer(allocator).print("{s}0x{x:0>4}:{s} {s}{x:0>2}{s}", .{ Colors.cyan, bytecode_pc, Colors.reset, Colors.dim, opcode_byte, Colors.reset });

            // Try to interpret the opcode
            if (std.meta.intToEnum(Opcode, opcode_byte)) |opcode| {
                try output.writer(allocator).print("  {s}{s}{s}", .{ Colors.white, @tagName(opcode), Colors.reset });

                // Handle PUSH instructions specially
                switch (opcode) {
                    .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8, .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                        const push_size = @intFromEnum(opcode) - @intFromEnum(Opcode.PUSH1) + 1;
                        var value: u256 = 0;
                        const end_pc = @min(bytecode_pc + 1 + push_size, @as(FrameType.PcType, @intCast(runtime_code.len)));

                        // Collect push data
                        try output.writer(allocator).print(" {s}", .{Colors.bright_magenta});
                        for (bytecode_pc + 1..end_pc) |i| {
                            value = (value << 8) | runtime_code[i];
                            try output.writer(allocator).print("{x:0>2}", .{runtime_code[i]});
                        }
                        try output.writer(allocator).print("{s} {s}(0x{x}){s}", .{ Colors.reset, Colors.dim, value, Colors.reset });

                        bytecode_pc = end_pc;
                        continue;
                    },
                    else => {},
                }
            } else |_| {
                try output.writer(allocator).print("  {s}INVALID{s}", .{ Colors.bright_red, Colors.reset });
            }

            try output.writer(allocator).print("\n", .{});
            bytecode_pc += 1;
        }
    } else {
        try output.writer(allocator).print("{s}(empty){s}\n", .{ Colors.dim, Colors.reset });
    }

    // Section showing dispatch instruction stream
    try output.writer(allocator).print("\n{s}--- Dispatch Instruction Stream ---{s}\n", .{ Colors.bold, Colors.reset });

    var i: usize = 0;
    while (i < schedule.len) {
        // Item index and address
        try output.writer(allocator).print("{s}[{d:3}]:{s} {s}@{*}{s} ", .{ Colors.dim, i, Colors.reset, Colors.cyan, &schedule[i], Colors.reset });

        // For now, just show as handler or metadata based on index patterns
        // (handlers are typically followed by metadata)
        try output.writer(allocator).print("{s}ITEM{s}", .{ Colors.blue, Colors.reset });

        try output.writer(allocator).print("\n", .{});
        i += 1;
    }

    // Summary section
    try output.writer(allocator).print("\n{s}--- Summary ---{s}\n", .{ Colors.bold, Colors.reset });

    const total_items = schedule.len;

    try output.writer(allocator).print("{s}Total dispatch items: {}{s}\n", .{ Colors.dim, total_items, Colors.reset });
    try output.writer(allocator).print("{s}Compression ratio: {d:.2}x (bytecode:{} -> dispatch:{}){s}\n", .{ Colors.dim, if (schedule.len > 0) @as(f64, @floatFromInt(bytecode.runtime_code.len)) / @as(f64, @floatFromInt(schedule.len)) else 0.0, bytecode.runtime_code.len, schedule.len, Colors.reset });

    return output.toOwnedSlice(allocator);
}