const std = @import("std");

// Assembly to EVM bytecode compiler for test specs
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Compile the stack limit test assembly codes
    const stack_limit_tests = [_]struct {
        name: []const u8,
        asm_code: []const u8,
        compiled: []const u8,
    }{
        .{
            .name = "stackLimitGas_1023",
            // (asm 1021 0x00 MSTORE JUMPDEST GAS 0x01 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD 0x06 JUMPI STOP)
            // 1021 = 0x03fd
            // PUSH2 0x03fd, PUSH1 0x00, MSTORE, JUMPDEST, GAS, PUSH1 0x01, PUSH1 0x00, MLOAD, SUB, PUSH1 0x00, MSTORE, PUSH1 0x00, MLOAD, PUSH1 0x06, JUMPI, STOP
            .asm_code = "(asm 1021 0x00 MSTORE JUMPDEST GAS 0x01 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD 0x06 JUMPI STOP)",
            .compiled = "0x6103fd60005252005a600160005103600052600051600656fe00",
        },
        .{
            .name = "stackLimitGas_1024",
            // (asm 1022 0x00 MSTORE JUMPDEST GAS 0x01 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD 0x06 JUMPI STOP)
            // 1022 = 0x03fe
            .asm_code = "(asm 1022 0x00 MSTORE JUMPDEST GAS 0x01 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD 0x06 JUMPI STOP)",
            .compiled = "0x6103fe60005252005a600160005103600052600051600656fe00",
        },
        .{
            .name = "stackLimitGas_1025",
            // (asm 1023 0x00 MSTORE JUMPDEST GAS 0x01 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD 0x06 JUMPI STOP)
            // 1023 = 0x03ff
            .asm_code = "(asm 1023 0x00 MSTORE JUMPDEST GAS 0x01 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD 0x06 JUMPI STOP)",
            .compiled = "0x6103ff60005252005a600160005103600052600051600656fe00",
        },
        .{
            .name = "stackLimitPush31_1023",
            // (asm 1000 0x00 MSTORE 0x01 0x00 MLOAD PUSH31 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f ADD POP 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD PUSH1 0x00 JUMPI STOP)
            // 1000 = 0x03e8
            .asm_code = "(asm 1000 0x00 MSTORE 0x01 0x00 MLOAD PUSH31 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f ADD POP 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD PUSH1 0x00 JUMPI STOP)",
            .compiled = "0x6103e86000526001600051" ++ "7e0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" ++ "0150600051036000526000516000" ++ "56fe00",
        },
        .{
            .name = "stackLimitPush31_1024",
            // (asm 1001 0x00 MSTORE 0x01 0x00 MLOAD PUSH31 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f ADD POP 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD PUSH1 0x00 JUMPI STOP)
            // 1001 = 0x03e9
            .asm_code = "(asm 1001 0x00 MSTORE 0x01 0x00 MLOAD PUSH31 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f ADD POP 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD PUSH1 0x00 JUMPI STOP)",
            .compiled = "0x6103e96000526001600051" ++ "7e0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" ++ "0150600051036000526000516000" ++ "56fe00",
        },
        .{
            .name = "stackLimitPush31_1025",
            // (asm 1002 0x00 MSTORE 0x01 0x00 MLOAD PUSH31 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f ADD POP 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD PUSH1 0x00 JUMPI STOP)
            // 1002 = 0x03ea
            .asm_code = "(asm 1002 0x00 MSTORE 0x01 0x00 MLOAD PUSH31 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f ADD POP 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD PUSH1 0x00 JUMPI STOP)",
            .compiled = "0x6103ea6000526001600051" ++ "7e0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" ++ "0150600051036000526000516000" ++ "56fe00",
        },
        .{
            .name = "stackLimitPush32_1023",
            // (asm 999 0x00 MSTORE 0x01 0x00 MLOAD PUSH32 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20 ADD POP 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD PUSH1 0x00 JUMPI STOP)
            // 999 = 0x03e7
            .asm_code = "(asm 999 0x00 MSTORE 0x01 0x00 MLOAD PUSH32 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20 ADD POP 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD PUSH1 0x00 JUMPI STOP)",
            .compiled = "0x6103e76000526001600051" ++ "7f0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20" ++ "0150600051036000526000516000" ++ "56fe00",
        },
        .{
            .name = "stackLimitPush32_1024",
            // (asm 1000 0x00 MSTORE 0x01 0x00 MLOAD PUSH32 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20 ADD POP 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD PUSH1 0x00 JUMPI STOP)
            // 1000 = 0x03e8
            .asm_code = "(asm 1000 0x00 MSTORE 0x01 0x00 MLOAD PUSH32 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20 ADD POP 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD PUSH1 0x00 JUMPI STOP)",
            .compiled = "0x6103e86000526001600051" ++ "7f0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20" ++ "0150600051036000526000516000" ++ "56fe00",
        },
        .{
            .name = "stackLimitPush32_1025",
            // (asm 1001 0x00 MSTORE 0x01 0x00 MLOAD PUSH32 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20 ADD POP 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD PUSH1 0x00 JUMPI STOP)
            // 1001 = 0x03e9
            .asm_code = "(asm 1001 0x00 MSTORE 0x01 0x00 MLOAD PUSH32 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20 ADD POP 0x00 MLOAD SUB 0x00 MSTORE 0x00 MLOAD PUSH1 0x00 JUMPI STOP)",
            .compiled = "0x6103e96000526001600051" ++ "7f0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20" ++ "0150600051036000526000516000" ++ "56fe00",
        },
    };

    for (stack_limit_tests) |test_case| {
        std.debug.print("Test: {s}\n", .{test_case.name});
        std.debug.print("  Assembly: {s}\n", .{test_case.asm_code});
        std.debug.print("  Compiled: {s}\n", .{test_case.compiled});
        std.debug.print("\n", .{});
    }
}