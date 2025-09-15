// Test Guillotine arithmetic operations in isolation
const std = @import("std");
const testing = std.testing;
const Evm = @import("evm").Evm;
const Database = @import("evm").Database;
const primitives = @import("primitives");

test "guillotine standalone: basic arithmetic operations" {
    const allocator = testing.allocator;

    // Setup database and EVM
    var db = Database.init(allocator);
    defer db.deinit();

    const caller = primitives.Address.ZERO_ADDRESS;
    const contract = try primitives.Address.from_hex("0xc0de000000000000000000000000000000000000");

    try db.set_account(caller.bytes, .{
        .balance = 10000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    const block_info = @import("evm").BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 0,
        .gas_limit = 100000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .difficulty = 0,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };

    const tx_context = @import("evm").TransactionContext{
        .chain_id = 1,
        .gas_limit = 100000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .blob_versioned_hashes = &.{},
        .blob_base_fee = 0,
    };

    // Use EVM without tracing for cleaner output
    const NoTraceEVM = Evm(.{
        .TracerType = @import("evm").tracer.DefaultTracer,
        .DatabaseType = Database,
    });

    var evm = try NoTraceEVM.init(
        allocator,
        &db,
        block_info,
        tx_context,
        0,
        caller,
        .CANCUN,
    );
    defer evm.deinit();

    // Same bytecode as the failing test
    const bytecode = [_]u8{
        // 1. ADD: 5 + 3
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x01, // ADD (result: 8)

        // 2. SUB: 10 - 4
        0x60, 0x0a, // PUSH1 10
        0x60, 0x04, // PUSH1 4
        0x03, // SUB (result: 6)

        // 3. MUL: 8 * 6
        0x02, // MUL (result: 48)

        // 4. DIV: 48 / 2
        0x60, 0x02, // PUSH1 2
        0x04, // DIV (result: 24)

        // 5. MOD: 24 % 7
        0x60, 0x07, // PUSH1 7
        0x06, // MOD (result: 3)

        // 6. ADDMOD: (3 + 5) % 5
        0x60, 0x05, // PUSH1 5
        0x60, 0x05, // PUSH1 5
        0x08, // ADDMOD (result: 3)

        // 7. MULMOD: (3 * 4) % 5
        0x60, 0x04, // PUSH1 4
        0x60, 0x05, // PUSH1 5
        0x09, // MULMOD (result: 2)

        // 8. EXP: 2 ^ 3
        0x60, 0x03, // PUSH1 3
        0x0a, // EXP (result: 8)

        // 9. Final ADD: 8 + 1
        0x60, 0x01, // PUSH1 1
        0x01, // ADD (result: 9)

        // Store result in memory and return
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (return size)
        0x60, 0x00, // PUSH1 0 (return offset)
        0xf3, // RETURN
    };

    // Set the bytecode at the contract address
    const code_hash = try db.set_code(&bytecode);
    try db.set_account(contract.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    std.debug.print("Testing Guillotine arithmetic chain in isolation...\n", .{});
    std.debug.print("Expected result: 9 (0x09 in hex)\n", .{});

    // Execute the bytecode
    const result = evm.call(.{
        .call = .{
            .caller = caller,
            .to = contract,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });

    std.debug.print("Execution success: {}\n", .{result.success});
    std.debug.print("Gas used: {}\n", .{100000 - result.gas_left});
    std.debug.print("Output length: {}\n", .{result.output.len});

    if (result.output.len >= 32) {
        // Print the last 32 bytes as hex
        const last_32 = result.output[result.output.len - 32 ..];
        std.debug.print("Output (last 32 bytes): ", .{});
        for (last_32) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n", .{});

        // Convert the last byte to decimal to see the actual result
        const last_byte = last_32[31];
        std.debug.print("Result as decimal: {}\n", .{last_byte});

        // Check if it matches expected result
        if (last_byte == 9) {
            std.debug.print("✅ Guillotine produces CORRECT result: 9\n", .{});
        } else {
            std.debug.print("❌ Guillotine produces WRONG result: {} (expected 9)\n", .{last_byte});
        }
    }

    // Cleanup
    var result_copy = result;
    result_copy.deinit(allocator);
}
