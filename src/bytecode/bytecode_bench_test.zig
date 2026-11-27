const std = @import("std");
const log = @import("../log.zig");
const Bytecode = @import("bytecode.zig").Bytecode;
const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig;
const Opcode = @import("../opcodes/opcode.zig").Opcode;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test 1: Simple bytecode
    {
        const code = [_]u8{
            @backingInt(Opcode.PUSH1), 0x60,
            @backingInt(Opcode.ADD),
        };

        const start = std.time.nanoTimestamp();
        var bytecode = try Bytecode(BytecodeConfig{}).init(allocator, &code);
        defer bytecode.deinit();
        const end = std.time.nanoTimestamp();

        const elapsed = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
        log.debug("Simple bytecode init: {d:.3}ms\n", .{elapsed});
    }

    // Test 2: Fusion bytecode
    {
        var code: [300]u8 = undefined;
        var i: usize = 0;
        while (i + 3 <= code.len) : (i += 3) {
            code[i] = @backingInt(Opcode.PUSH1);
            code[i + 1] = @truncate(i);
            code[i + 2] = @backingInt(Opcode.ADD);
        }

        const start = std.time.nanoTimestamp();
        var bytecode = try Bytecode(BytecodeConfig{}).init(allocator, &code);
        defer bytecode.deinit();
        const end = std.time.nanoTimestamp();

        const elapsed = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
        log.debug("Fusion bytecode (300 bytes) init: {d:.3}ms\n", .{elapsed});
    }

    // Test 3: Large bytecode
    {
        const code = try allocator.alloc(u8, 1000);
        defer allocator.free(code);

        // Fill with various opcodes
        for (code, 0..) |*byte, idx| {
            byte.* = switch (idx % 10) {
                0 => @backingInt(Opcode.ADD),
                1 => @backingInt(Opcode.MUL),
                2 => @backingInt(Opcode.SUB),
                3 => @backingInt(Opcode.DIV),
                4 => @backingInt(Opcode.LT),
                5 => @backingInt(Opcode.GT),
                6 => @backingInt(Opcode.EQ),
                7 => @backingInt(Opcode.DUP1),
                8 => @backingInt(Opcode.SWAP1),
                else => @backingInt(Opcode.POP),
            };
        }

        const start = std.time.nanoTimestamp();
        var bytecode = try Bytecode(BytecodeConfig{}).init(allocator, code);
        defer bytecode.deinit();
        const end = std.time.nanoTimestamp();

        const elapsed = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
        log.debug("Large bytecode (1000 bytes) init: {d:.3}ms\n", .{elapsed});
    }

    // Test 4: Try loading ERC20
    {
        const file = std.fs.cwd().openFile("bench/cases/erc20-transfer/bytecode.txt", .{}) catch |err| {
            log.debug("Could not open ERC20 file: {}\n", .{err});
            return;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        log.debug("ERC20 file content length: {} bytes\n", .{content.len});
        log.debug("First 100 chars: {s}\n", .{content[0..@min(100, content.len)]});
    }
}
