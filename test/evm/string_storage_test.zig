const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const Address = @import("Address").Address;

test {
    // std.testing.log_level = .warn;
}

test "minimal string storage in constructor" {
    const allocator = testing.allocator;

    // Minimal contract that stores a string in constructor
    // contract Test {
    //     string private name;
    //     constructor() {
    //         name = "test";
    //     }
    // }
    // This compiles to bytecode that:
    // 1. PUSHes the string length (4)
    // 2. PUSHes string data location
    // 3. Uses CODECOPY to copy string to memory
    // 4. SSTOREs the string (length + data)

    // Simplified bytecode that reproduces the string storage pattern
    const bytecode = [_]u8{
        // Constructor code
        0x60, 0x04, // PUSH1 0x04 (string length "test")
        0x60, 0x00, // PUSH1 0x00 (memory position)
        0x52, // MSTORE (store length at mem[0])

        // Copy string data to memory
        0x60, 0x04, // PUSH1 0x04 (length to copy)
        0x60, 0x1c, // PUSH1 0x1c (source position in code)
        0x60, 0x20, // PUSH1 0x20 (dest position in memory)
        0x39, // CODECOPY

        // Store to storage slot 0
        0x60, 0x24, // PUSH1 0x24 (total size: 4 + 32)
        0x60, 0x00, // PUSH1 0x00 (memory offset)
        0x60, 0x00, // PUSH1 0x00 (storage slot)
        0x55, // SSTORE

        // Return empty runtime code
        0x60, 0x00, // PUSH1 0x00
        0x60, 0x00, // PUSH1 0x00
        0xf3, // RETURN

        // String data "test" at position 0x1c
        0x74,
        0x65,
        0x73,
        0x74,
    };

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    var vm = try builder.build();
    defer vm.deinit();

    const caller = Address.from_u256(0x1234567890123456789012345678901234567890);

    std.log.debug("Creating contract with string storage...", .{});
    const create_result = try vm.create_contract(caller, 0, &bytecode, 1_000_000_000);

    try testing.expect(create_result.success);
    std.log.debug("Contract created successfully at: {any}", .{create_result.address});
}

test "complex string storage like ERC20" {
    const allocator = testing.allocator;

    // More complex test that mimics ERC20 constructor storing two strings
    // This will use dynamic memory allocation similar to Solidity
    const bytecode = [_]u8{
        // Allocate memory for first string "ERC20Mint" (9 chars)
        0x60, 0x40, // PUSH1 0x40 (free memory pointer)
        0x51, // MLOAD (load current free memory pointer)
        0x80, // DUP1

        // Store string length
        0x60, 0x09, // PUSH1 0x09 (length of "ERC20Mint")
        0x81, // DUP2
        0x52, // MSTORE

        // Calculate new free memory pointer
        0x60, 0x20, // PUSH1 0x20
        0x01, // ADD

        // Copy string data
        0x60, 0x09, // PUSH1 0x09 (bytes to copy)
        0x60, 0x60, // PUSH1 0x60 (source offset in bytecode)
        0x82, // DUP3
        0x39, // CODECOPY

        // Update free memory pointer
        0x60, 0x20, // PUSH1 0x20
        0x01, // ADD
        0x60, 0x40, // PUSH1 0x40
        0x52, // MSTORE

        // Store to storage slot 0
        0x80, // DUP1 (memory location)
        0x60, 0x00, // PUSH1 0x00 (storage slot)
        0x55, // SSTORE

        // Return empty runtime code
        0x60, 0x00, // PUSH1 0x00
        0x60, 0x00, // PUSH1 0x00
        0xf3, // RETURN

        // Padding to reach offset 0x60
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,

        // String data "ERC20Mint" at offset 0x60
        0x45,
        0x52,
        0x43,
        0x32,
        0x30,
        0x4D,
        0x69,
        0x6E,
        0x74,
    };

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    var vm = try builder.build();
    defer vm.deinit();

    const caller = Address.from_u256(0x1234567890123456789012345678901234567890);

    std.log.debug("Creating contract with dynamic string storage...", .{});
    const create_result = try vm.create_contract(caller, 0, &bytecode, 1_000_000_000);

    try testing.expect(create_result.success);
    std.log.debug("Contract created successfully at: {any}", .{create_result.address});
}

test "reproduce array bounds panic 0x41" {
    const allocator = testing.allocator;

    // Test that specifically tries to trigger array bounds error
    // This happens when accessing memory beyond allocated bounds
    const bytecode = [_]u8{
        // Try to access uninitialized memory
        0x60, 0x80, // PUSH1 0x80 (memory offset beyond free memory pointer)
        0x51, // MLOAD (this might trigger bounds check)

        // Try array-style access that could trigger panic
        0x60, 0x05, // PUSH1 0x05 (array index)
        0x60, 0x20, // PUSH1 0x20 (element size)
        0x02, // MUL
        0x60, 0x00, // PUSH1 0x00 (array base)
        0x01, // ADD
        0x51, // MLOAD

        // If we get here, no panic occurred
        0x60, 0x00, // PUSH1 0x00
        0x60, 0x00, // PUSH1 0x00
        0xf3, // RETURN
    };

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    var vm = try builder.build();
    defer vm.deinit();

    const caller = Address.from_u256(0x1234567890123456789012345678901234567890);

    std.log.debug("Testing array bounds access...", .{});
    const create_result = try vm.create_contract(caller, 0, &bytecode, 1_000_000_000);

    // This might fail with array bounds if our EVM has such checks
    std.log.debug("Create result: success={}, gas_left={}", .{ create_result.success, create_result.gas_left });
    if (!create_result.success) {
        if (create_result.output) |output| {
            if (output.len >= 4) {
                const panic_code = std.mem.readInt(u32, output[0..4], .big);
                std.log.debug("Panic code: 0x{x}", .{panic_code});
            }
        }
    }
}
