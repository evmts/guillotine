const std = @import("std");
const evm_mod = @import("evm.zig");
const DefaultEvm = evm_mod.DefaultEvm;
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
const DatabaseInterface = @import("database_interface.zig").DatabaseInterface;
const BlockInfo = @import("block_info.zig").DefaultBlockInfo;
const TransactionContext = @import("transaction_context.zig").TransactionContext;
const Account = @import("database_interface_account.zig").Account;
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;
const IR = @import("ir.zig");
const ir_builder = @import("ir_builder.zig");
const ir_interpreter = @import("ir_interpreter.zig");
const frame_mod = @import("frame.zig");
const frame_interpreter_mod = @import("frame_interpreter.zig");

/// Test helper to run bytecode with both interpreters and compare results
fn runBothInterpreters(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    gas: u64,
    database: DatabaseInterface,
) !struct {
    frame_result: DefaultEvm.CallResult,
    ir_result: DefaultEvm.CallResult,
} {
    // Create EVM instances
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(allocator, database, block_info, context, 0, ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const test_address: Address = [_]u8{0x42} ++ [_]u8{0} ** 19;

    // Run with frame interpreter
    const frame_result = try evm.execute_frame(
        bytecode,
        &.{},
        gas,
        test_address,
        ZERO_ADDRESS,
        0,
        false,
        0,
    );

    // Run with IR interpreter
    const host = evm.to_host();
    const config = evm_mod.EvmConfig{};
    var frame = try frame_mod.Frame(config.frame_config).init(
        allocator,
        bytecode,
        @as(i32, @intCast(@min(gas, std.math.maxInt(i32)))),
        database,
        host,
    );
    defer frame.deinit(allocator);
    frame.contract_address = test_address;

    // Build and execute IR
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var program = try ir_builder.build(arena.allocator(), bytecode);
    
    ir_interpreter.interpret(config.frame_config, &program, &frame) catch |err| {
        const gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
        var out_slice: []const u8 = &.{};
        if (frame.output_data.items.len > 0) {
            const buf = try allocator.alloc(u8, frame.output_data.items.len);
            @memcpy(buf, frame.output_data.items);
            out_slice = buf;
        }
        return .{
            .frame_result = frame_result,
            .ir_result = switch (err) {
                error.STOP => DefaultEvm.CallResult.success_with_output(gas_left, out_slice),
                error.REVERT => DefaultEvm.CallResult.revert_with_data(gas_left, out_slice),
                else => DefaultEvm.CallResult.failure(0),
            },
        };
    };

    const gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
    var out_slice: []const u8 = &.{};
    if (frame.output_data.items.len > 0) {
        const buf = try allocator.alloc(u8, frame.output_data.items.len);
        @memcpy(buf, frame.output_data.items);
        out_slice = buf;
    }
    const ir_result = DefaultEvm.CallResult.success_with_output(gas_left, out_slice);

    return .{
        .frame_result = frame_result,
        .ir_result = ir_result,
    };
}

test "IR interpreter - basic STOP" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);

    const bytecode = [_]u8{0x00}; // STOP
    const results = try runBothInterpreters(std.testing.allocator, &bytecode, 100000, db_interface);
    
    // Both should succeed
    try std.testing.expect(results.frame_result.success);
    try std.testing.expect(results.ir_result.success);
    
    // Gas consumption should be similar
    try std.testing.expectApproxEqAbs(
        @as(f64, @floatFromInt(results.frame_result.gas_left)),
        @as(f64, @floatFromInt(results.ir_result.gas_left)),
        1000, // Allow 1000 gas difference
    );
}

test "IR interpreter - PUSH and RETURN" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);

    // PUSH1 0x42, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xF3,       // RETURN
    };
    
    const results = try runBothInterpreters(std.testing.allocator, &bytecode, 100000, db_interface);
    defer {
        if (results.frame_result.output.len > 0) std.testing.allocator.free(results.frame_result.output);
        if (results.ir_result.output.len > 0) std.testing.allocator.free(results.ir_result.output);
    }
    
    // Both should succeed
    try std.testing.expect(results.frame_result.success);
    try std.testing.expect(results.ir_result.success);
    
    // Output should be the same
    try std.testing.expectEqualSlices(u8, results.frame_result.output, results.ir_result.output);
    try std.testing.expectEqual(@as(usize, 32), results.ir_result.output.len);
    
    // First byte should be 0x42 (after 31 zeros due to word alignment)
    if (results.ir_result.output.len >= 32) {
        try std.testing.expectEqual(@as(u8, 0x42), results.ir_result.output[31]);
    }
}

test "IR interpreter - CREATE operation" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Set up caller with balance
    const caller_address: Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try memory_db.set_account(caller_address, caller_account);

    // Simple init code that returns a single STOP opcode
    const init_code = [_]u8{
        0x60, 0x01, // PUSH1 1 (size)
        0x60, 0x0A, // PUSH1 10 (offset of STOP in this code)
        0xF3,       // RETURN
        0x00, 0x00, 0x00, 0x00, 0x00, // Padding
        0x00,       // STOP (at offset 10)
    };

    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &init_code,
            .gas = 100000,
        },
    };

    const result = try evm.call(create_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    // Verify successful creation
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);

    // Extract contract address
    const contract_address: Address = result.output[12..32].*;

    // Verify contract was created with correct code
    const deployed_code = try memory_db.get_code_by_address(contract_address);
    try std.testing.expectEqual(@as(usize, 1), deployed_code.len);
    try std.testing.expectEqual(@as(u8, 0x00), deployed_code[0]); // STOP
}

test "IR interpreter - CREATE2 operation" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const caller_address: Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try memory_db.set_account(caller_address, caller_account);

    // Init code that stores a value and returns runtime code
    const init_code = [_]u8{
        // Store value 99 at key 0
        0x60, 0x63, // PUSH1 99
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE
        
        // Return runtime code: PUSH1 5 ADD
        0x60, 0x04, // PUSH1 4 (size)
        0x60, 0x0C, // PUSH1 12 (offset)
        0xF3,       // RETURN
        
        // Runtime code at offset 12:
        0x60, 0x05, // PUSH1 5
        0x01,       // ADD
        0x00,       // STOP
    };

    const salt: u256 = 0xCAFEBABE;

    const create2_params = DefaultEvm.CallParams{
        .create2 = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &init_code,
            .salt = salt,
            .gas = 200000,
        },
    };

    const result = try evm.call(create2_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    // Verify successful creation
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
    
    const contract_address: Address = result.output[12..32].*;
    
    // Verify storage was set during init
    const stored_value = try memory_db.get_storage(contract_address, 0);
    try std.testing.expectEqual(@as(u256, 99), stored_value);
    
    // Verify runtime code
    const runtime_code = try memory_db.get_code_by_address(contract_address);
    try std.testing.expectEqual(@as(usize, 4), runtime_code.len);
    try std.testing.expectEqual(@as(u8, 0x60), runtime_code[0]); // PUSH1
    try std.testing.expectEqual(@as(u8, 0x05), runtime_code[1]); // 5
    try std.testing.expectEqual(@as(u8, 0x01), runtime_code[2]); // ADD
    try std.testing.expectEqual(@as(u8, 0x00), runtime_code[3]); // STOP
}

test "IR interpreter - JUMP and JUMPI" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);

    // Test JUMP: Push destination, JUMP, invalid op, JUMPDEST, STOP
    const jump_bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x56,       // JUMP
        0xFE,       // Invalid (should be skipped)
        0x5B,       // JUMPDEST (at PC 5)
        0x00,       // STOP
    };
    
    const jump_results = try runBothInterpreters(std.testing.allocator, &jump_bytecode, 100000, db_interface);
    try std.testing.expect(jump_results.frame_result.success);
    try std.testing.expect(jump_results.ir_result.success);

    // Test JUMPI with true condition
    const jumpi_true_bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1 (true condition)
        0x60, 0x06, // PUSH1 6 (destination)
        0x57,       // JUMPI
        0xFE,       // Invalid (should be skipped)
        0x5B,       // JUMPDEST (at PC 6)
        0x00,       // STOP
    };
    
    const jumpi_true_results = try runBothInterpreters(std.testing.allocator, &jumpi_true_bytecode, 100000, db_interface);
    try std.testing.expect(jumpi_true_results.frame_result.success);
    try std.testing.expect(jumpi_true_results.ir_result.success);

    // Test JUMPI with false condition
    const jumpi_false_bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (false condition)
        0x60, 0x08, // PUSH1 8 (destination)
        0x57,       // JUMPI
        0x00,       // STOP (should execute this)
        0xFE,       // Invalid
        0x5B,       // JUMPDEST (at PC 8)
        0xFE,       // Invalid
    };
    
    const jumpi_false_results = try runBothInterpreters(std.testing.allocator, &jumpi_false_bytecode, 100000, db_interface);
    try std.testing.expect(jumpi_false_results.frame_result.success);
    try std.testing.expect(jumpi_false_results.ir_result.success);
}

test "IR interpreter - REVERT with data" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);

    // Store "REVERTED" in memory and revert with it
    const revert_bytecode = [_]u8{
        0x60, 0x08, // PUSH1 8 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        // Store "REVERTED" at memory[0]
        0x7F,       // PUSH32
        0x52, 0x45, 0x56, 0x45, 0x52, 0x54, 0x45, 0x44, // "REVERTED"
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0xFD,       // REVERT
    };
    
    const results = try runBothInterpreters(std.testing.allocator, &revert_bytecode, 100000, db_interface);
    defer {
        if (results.frame_result.output.len > 0) std.testing.allocator.free(results.frame_result.output);
        if (results.ir_result.output.len > 0) std.testing.allocator.free(results.ir_result.output);
    }
    
    // Both should fail (revert)
    try std.testing.expect(!results.frame_result.success);
    try std.testing.expect(!results.ir_result.success);
    
    // Output should contain "REVERTED"
    try std.testing.expect(results.ir_result.output.len >= 8);
    const expected = "REVERTED";
    try std.testing.expectEqualSlices(u8, expected, results.ir_result.output[0..8]);
}

test "IR interpreter - Complex init code with loops" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const caller_address: Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try memory_db.set_account(caller_address, caller_account);

    // Init code with a loop that counts from 0 to 5
    const init_code = [_]u8{
        // Initialize counter at storage[0] = 0
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE
        
        // Loop start (PC 5)
        0x5B,       // JUMPDEST
        0x60, 0x00, // PUSH1 0
        0x54,       // SLOAD (load counter)
        0x60, 0x01, // PUSH1 1
        0x01,       // ADD (increment)
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE (store back)
        
        // Check if counter < 5
        0x60, 0x00, // PUSH1 0
        0x54,       // SLOAD
        0x60, 0x05, // PUSH1 5
        0x10,       // LT
        0x60, 0x05, // PUSH1 5 (jump dest)
        0x57,       // JUMPI (jump if less than 5)
        
        // Return empty code
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };

    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &init_code,
            .gas = 300000,
        },
    };

    const result = try evm.call(create_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    try std.testing.expect(result.success);
    
    const contract_address: Address = result.output[12..32].*;
    
    // Verify the counter reached 5
    const counter_value = try memory_db.get_storage(contract_address, 0);
    try std.testing.expectEqual(@as(u256, 5), counter_value);
}

// Test that all standard operations work with IR interpreter
test "IR interpreter - Arithmetic operations" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);

    // Test ADD, MUL, SUB, DIV
    const arithmetic_bytecode = [_]u8{
        0x60, 0x0A, // PUSH1 10
        0x60, 0x05, // PUSH1 5
        0x01,       // ADD (15)
        0x60, 0x03, // PUSH1 3
        0x02,       // MUL (45)
        0x60, 0x05, // PUSH1 5
        0x03,       // SUB (40)
        0x60, 0x08, // PUSH1 8
        0x04,       // DIV (5)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const results = try runBothInterpreters(std.testing.allocator, &arithmetic_bytecode, 100000, db_interface);
    defer {
        if (results.frame_result.output.len > 0) std.testing.allocator.free(results.frame_result.output);
        if (results.ir_result.output.len > 0) std.testing.allocator.free(results.ir_result.output);
    }
    
    try std.testing.expect(results.frame_result.success);
    try std.testing.expect(results.ir_result.success);
    
    // Both should return 5
    try std.testing.expectEqual(@as(usize, 32), results.ir_result.output.len);
    try std.testing.expectEqual(@as(u8, 5), results.ir_result.output[31]);
}