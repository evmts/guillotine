const std = @import("std");

pub fn main() !void {
    const test_codes = [_][]const u8{
        "(asm 1021 0x00 MSTORE JUMPDEST GAS 0x01 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD 0x06 JUMPI STOP )",
        "0x60ff60ff",
        "{code}",
        ":asm PUSH1 0x01",
        ":yul { add(1, 2) }",
        "",
        "0x",
    };

    for (test_codes) |code| {
        std.debug.print("Code: {s}\n", .{code});
        std.debug.print("Is Assembly: {}\n\n", .{isAssemblyCode(code)});
    }
}

fn isAssemblyCode(code: []const u8) bool {
    // Assembly code starts with (asm, {, :asm, or :yul
    return std.mem.startsWith(u8, code, "(asm ") or
           std.mem.startsWith(u8, code, "{") or
           std.mem.startsWith(u8, code, ":asm ") or
           std.mem.startsWith(u8, code, ":yul ");
}