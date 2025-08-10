const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const Address = @import("Address").Address;

test "trace ERC20 constructor execution step by step" {
    const allocator = testing.allocator;

    // Read the actual ERC20 bytecode
    const file_content = try std.fs.cwd().readFileAlloc(allocator, "test/evm/erc20_mint.hex", 1024 * 1024);
    defer allocator.free(file_content);

    const hex_str = std.mem.trim(u8, file_content, " \n\r\t");
    const bytecode = try allocator.alloc(u8, hex_str.len / 2);
    defer allocator.free(bytecode);
    _ = try std.fmt.hexToBytes(bytecode, hex_str);

    // Create a minimal VM just to analyze the contract
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    // Create a contract for analysis
    var contract = Evm.Contract.init_deployment(
        Address.ZERO, // deployer
        0, // value
        1_000_000, // gas
        bytecode, // init code
        null, // no salt
    );
    defer contract.deinit(allocator, null);

    std.log.debug("=== ERC20 Constructor Analysis ===", .{});
    std.log.debug("Total bytecode length: {}", .{bytecode.len});
    std.log.debug("First 40 bytes: {x}", .{bytecode[0..40]});

    // Analyze jump destinations

    // Find the REVERT at pc=134 mentioned in debug output
    if (bytecode.len > 134) {
        std.log.debug("Opcode at pc=134: 0x{x:0>2} ({})", .{ bytecode[134], getOpcodeName(bytecode[134]) });
        if (134 >= 10) {
            std.log.debug("Context before pc=134: {x}", .{bytecode[124..135]});
        }
    }

    // Look for array access patterns (often cause bounds errors)
    // Array access in Solidity typically involves:
    // - PUSH <index>
    // - DUP <array ref>
    // - PUSH 0x20 (32 bytes)
    // - MUL
    // - ADD
    // - MLOAD/SLOAD

    var i: usize = 0;
    while (i < @min(bytecode.len, 150)) : (i += 1) {
        const op = bytecode[i];

        // Look for MUL operations that might be array indexing
        if (op == 0x02) { // MUL
            std.log.debug("Found MUL at pc={}, context: {x}", .{ i, bytecode[@max(0, i - 5)..@min(bytecode.len, i + 5)] });
        }

        // Look for MLOAD/SLOAD that might trigger bounds check
        if (op == 0x51 or op == 0x54) { // MLOAD or SLOAD
            std.log.debug("Found {s} at pc={}, context: {x}", .{ if (op == 0x51) "MLOAD" else "SLOAD", i, bytecode[@max(0, i - 5)..@min(bytecode.len, i + 5)] });
        }
    }

    // Check if there's a pattern suggesting array initialization
    // Solidity often emits: PUSH <length>, PUSH 0x00, CODECOPY for string/bytes
    i = 0;
    while (i < @min(bytecode.len - 3, 150)) : (i += 1) {
        if (bytecode[i] == 0x39) { // CODECOPY
            std.log.debug("Found CODECOPY at pc={}", .{i});
            // Look back for the length and offset pushes
            if (i >= 4) {
                std.log.debug("  Pattern before CODECOPY: {x}", .{bytecode[i - 4 .. i + 1]});
            }
        }
    }
}

fn getOpcodeName(opcode: u8) []const u8 {
    return switch (opcode) {
        0x00 => "STOP",
        0x01 => "ADD",
        0x02 => "MUL",
        0x39 => "CODECOPY",
        0x51 => "MLOAD",
        0x54 => "SLOAD",
        0x55 => "SSTORE",
        0x60...0x7f => "PUSH",
        0x80...0x8f => "DUP",
        0x90...0x9f => "SWAP",
        0xf3 => "RETURN",
        0xfd => "REVERT",
        else => "UNKNOWN",
    };
}
