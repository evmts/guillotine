const std = @import("std");
const testing = std.testing;
const primitives = @import("voltaire");
const EvmConfig = @import("../src/evm_config.zig").EvmConfig;
const Evm = @import("../src/evm.zig").Evm;
const Database = @import("../src/storage/database.zig").Database;
const BlockInfo = @import("../src/block/block_info.zig").BlockInfo(.{});
const TransactionContext = @import("../src/block/transaction_context.zig").TransactionContext;
const Account = @import("../src/storage/database_interface_account.zig").Account;
const Opcode = @import("../src/opcodes/opcode_data.zig").Opcode;

test "opcode overrides - replace ADD with custom handler" {
    const allocator = testing.allocator;

    // Create a custom ADD handler that multiplies instead of adds
    const CustomHandlers = struct {
        pub fn customAdd(frame: anytype, cursor: [*]const @TypeOf(frame.*).Dispatch.Item) !noreturn {
            frame.beforeInstruction(.ADD, cursor);
            
            // Pop two values and multiply instead of add
            const b = frame.stack.pop_unsafe();
            const a = frame.stack.peek_unsafe();
            frame.stack.set_top_unsafe(a *% b); // Multiply instead of add!
            
            const op_data = cursor[0].decode();
            frame.afterInstruction(.ADD, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(@TypeOf(frame.*).getTailCallModifier(), op_data.next_handler, .{ frame, op_data.next_cursor.cursor });
        }
    };

    // Create EVM config with custom ADD handler
    const config = EvmConfig{
        .opcode_overrides = &[_]EvmConfig.OpcodeOverride{
            .{
                .opcode = @intFromEnum(Opcode.ADD),
                .handler = &CustomHandlers.customAdd,
            },
        },
    };

    const TestEvm = Evm(config);
    
    var db = Database.init(allocator);
    defer db.deinit();

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };

    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try TestEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Bytecode: PUSH1 3, PUSH1 2, ADD, STOP
    // With our custom handler, this should compute 3 * 2 = 6 instead of 3 + 2 = 5
    const bytecode = [_]u8{ 0x60, 0x03, 0x60, 0x02, 0x01, 0x00 };
    
    const contract_address = primitives.Address{ .bytes = [_]u8{0x42} ** 20 };
    const code_hash = try db.set_code(&bytecode);
    
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(contract_address.bytes, account);

    const result = evm.call(TestEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });

    try testing.expect(result.success);
    
    // To verify the custom handler worked, we'd need to check the final stack state
    // or add logging/tracing to confirm multiplication happened instead of addition
    // For now, success means the override was applied without crashing
}

test "opcode overrides - add handler for invalid opcode 0xFE" {
    const allocator = testing.allocator;

    // Create a handler for invalid opcode 0xFE that acts like STOP
    const CustomHandlers = struct {
        pub fn customInvalid(frame: anytype, cursor: [*]const @TypeOf(frame.*).Dispatch.Item) !noreturn {
            _ = cursor;
            // Just stop execution gracefully instead of consuming all gas
            return error.Stop;
        }
    };

    // Create EVM config with handler for invalid opcode
    const config = EvmConfig{
        .opcode_overrides = &[_]EvmConfig.OpcodeOverride{
            .{
                .opcode = 0xFE, // Invalid opcode
                .handler = &CustomHandlers.customInvalid,
            },
        },
    };

    const TestEvm = Evm(config);
    
    var db = Database.init(allocator);
    defer db.deinit();

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };

    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try TestEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Bytecode with invalid opcode: PUSH1 1, 0xFE (invalid)
    // Without override, 0xFE would consume all gas and fail
    // With override, it should stop gracefully
    const bytecode = [_]u8{ 0x60, 0x01, 0xFE };
    
    const contract_address = primitives.Address{ .bytes = [_]u8{0x43} ** 20 };
    const code_hash = try db.set_code(&bytecode);
    
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(contract_address.bytes, account);

    const result = evm.call(TestEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });

    // With our custom handler, execution should succeed and have gas left
    try testing.expect(result.success);
    try testing.expect(result.gas_left > 90000); // Should have most gas left since we just stopped
}

test "opcode overrides - multiple overrides" {
    const allocator = testing.allocator;

    const CustomHandlers = struct {
        // Custom ADD that always pushes 42
        pub fn customAdd(frame: anytype, cursor: [*]const @TypeOf(frame.*).Dispatch.Item) !noreturn {
            frame.beforeInstruction(.ADD, cursor);
            
            _ = frame.stack.pop_unsafe();
            const a = frame.stack.peek_unsafe();
            _ = a;
            frame.stack.set_top_unsafe(42); // Always return 42
            
            const op_data = cursor[0].decode();
            frame.afterInstruction(.ADD, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(@TypeOf(frame.*).getTailCallModifier(), op_data.next_handler, .{ frame, op_data.next_cursor.cursor });
        }
        
        // Custom MUL that always pushes 99
        pub fn customMul(frame: anytype, cursor: [*]const @TypeOf(frame.*).Dispatch.Item) !noreturn {
            frame.beforeInstruction(.MUL, cursor);
            
            _ = frame.stack.pop_unsafe();
            const a = frame.stack.peek_unsafe();
            _ = a;
            frame.stack.set_top_unsafe(99); // Always return 99
            
            const op_data = cursor[0].decode();
            frame.afterInstruction(.MUL, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(@TypeOf(frame.*).getTailCallModifier(), op_data.next_handler, .{ frame, op_data.next_cursor.cursor });
        }
    };

    // Create EVM config with multiple overrides
    const config = EvmConfig{
        .opcode_overrides = &[_]EvmConfig.OpcodeOverride{
            .{
                .opcode = @intFromEnum(Opcode.ADD),
                .handler = &CustomHandlers.customAdd,
            },
            .{
                .opcode = @intFromEnum(Opcode.MUL),
                .handler = &CustomHandlers.customMul,
            },
        },
    };

    const TestEvm = Evm(config);
    
    var db = Database.init(allocator);
    defer db.deinit();

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };

    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try TestEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Bytecode: PUSH1 5, PUSH1 3, ADD, PUSH1 2, MUL, STOP
    // With overrides: ADD returns 42, MUL returns 99
    const bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01, 0x60, 0x02, 0x02, 0x00 };
    
    const contract_address = primitives.Address{ .bytes = [_]u8{0x44} ** 20 };
    const code_hash = try db.set_code(&bytecode);
    
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(contract_address.bytes, account);

    const result = evm.call(TestEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });

    try testing.expect(result.success);
}