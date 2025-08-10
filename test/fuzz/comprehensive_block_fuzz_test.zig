const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const testing = std.testing;

// Helper function to create EVM execution context with custom bytecode
fn create_evm_context_with_code(allocator: std.mem.Allocator, code: []const u8) !struct {
    db: evm.MemoryDatabase,
    vm: evm.Evm,
    contract: evm.Contract,
    frame: evm.Frame,
} {
    var db = evm.MemoryDatabase.init(allocator);
    const config = evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.Evm(config);
    var vm = try EvmType.init(allocator, db.to_database_interface(), null, 0, false, null);

    var contract = evm.Contract.init(primitives.Address.ZERO, primitives.Address.ZERO, 0, 1000000, code, [_]u8{0} ** 32, &.{}, false);

    var builder = evm.Frame.builder(allocator);
    const frame = try builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000000)
        .withCaller(primitives.Address.ZERO)
        .build();

    return .{
        .db = db,
        .vm = vm,
        .contract = contract,
        .frame = frame,
    };
}

fn deinit_evm_context(ctx: anytype, allocator: std.mem.Allocator) void {
    ctx.frame.deinit();
    ctx.contract.deinit(allocator, null);
    ctx.vm.deinit();
    ctx.db.deinit();
}

// Comprehensive BLOCKHASH operation fuzz testing
test "fuzz_blockhash_operation_edge_cases" {
    const allocator = testing.allocator;

    const blockhash_tests = [_]struct {
        current_block: u64,
        query_block: u256,
        expected_result: enum { zero, nonzero },
        description: []const u8,
    }{
        // Current block queries (should return zero)
        .{
            .current_block = 1000,
            .query_block = 1000,
            .expected_result = .zero,
            .description = "Current block returns zero",
        },
        .{
            .current_block = 0,
            .query_block = 0,
            .expected_result = .zero,
            .description = "Genesis block current query",
        },

        // Future block queries (should return zero)
        .{
            .current_block = 1000,
            .query_block = 1001,
            .expected_result = .zero,
            .description = "Future block returns zero",
        },
        .{
            .current_block = 1000,
            .query_block = 2000,
            .expected_result = .zero,
            .description = "Far future block returns zero",
        },
        .{
            .current_block = 1000,
            .query_block = std.math.maxInt(u256),
            .expected_result = .zero,
            .description = "Maximum future block returns zero",
        },

        // Genesis block queries (should return zero)
        .{
            .current_block = 1000,
            .query_block = 0,
            .expected_result = .zero,
            .description = "Genesis block query returns zero",
        },

        // Beyond 256 block limit (should return zero)
        .{
            .current_block = 1000,
            .query_block = 743, // 1000 - 743 = 257 (beyond limit)
            .expected_result = .zero,
            .description = "Block beyond 256 limit returns zero",
        },
        .{
            .current_block = 1000,
            .query_block = 500, // 500 blocks ago (beyond limit)
            .expected_result = .zero,
            .description = "Far past block returns zero",
        },
        .{
            .current_block = 500,
            .query_block = 1, // 499 blocks ago (beyond limit)
            .expected_result = .zero,
            .description = "Very old block returns zero",
        },

        // Valid recent blocks (should return non-zero hash)
        .{
            .current_block = 1000,
            .query_block = 999,
            .expected_result = .nonzero,
            .description = "Previous block returns hash",
        },
        .{
            .current_block = 1000,
            .query_block = 900,
            .expected_result = .nonzero,
            .description = "100 blocks ago returns hash",
        },
        .{
            .current_block = 1000,
            .query_block = 744, // 256 blocks ago (at limit)
            .expected_result = .nonzero,
            .description = "256 blocks ago at limit returns hash",
        },
        .{
            .current_block = 256,
            .query_block = 1, // 255 blocks ago (within limit)
            .expected_result = .nonzero,
            .description = "At boundary of valid range returns hash",
        },

        // Edge cases at boundaries
        .{
            .current_block = 256,
            .query_block = 255,
            .expected_result = .nonzero,
            .description = "Just within range returns hash",
        },
        .{
            .current_block = 1,
            .query_block = 0,
            .expected_result = .zero,
            .description = "Genesis from block 1 returns zero",
        },

        // Large block numbers
        .{
            .current_block = std.math.maxInt(u64),
            .query_block = std.math.maxInt(u64) - 1,
            .expected_result = .nonzero,
            .description = "Maximum block minus 1 returns hash",
        },
        .{
            .current_block = std.math.maxInt(u64),
            .query_block = std.math.maxInt(u64) - 256,
            .expected_result = .nonzero,
            .description = "Maximum block minus 256 returns hash",
        },
        .{
            .current_block = std.math.maxInt(u64),
            .query_block = std.math.maxInt(u64) - 257,
            .expected_result = .zero,
            .description = "Maximum block minus 257 returns zero",
        },
    };

    for (blockhash_tests) |test_case| {
        const blockhash_code = [_]u8{0x40}; // BLOCKHASH
        var ctx = try create_evm_context_with_code(allocator, &blockhash_code);
        defer deinit_evm_context(ctx, allocator);

        // Set block context
        ctx.vm.context.block_number = test_case.current_block;

        // Setup stack for BLOCKHASH (block number)
        try ctx.frame.stack.append(test_case.query_block);

        const interpreter: *evm.Operation.Interpreter = @ptrCast(&ctx.vm);
        const state: *evm.Operation.State = @ptrCast(&ctx.frame);

        const result = try ctx.vm.table.execute(0, interpreter, state, 0x40);
        _ = result;

        const block_hash = try ctx.frame.stack.pop();

        switch (test_case.expected_result) {
            .zero => {
                try testing.expectEqual(@as(u256, 0), block_hash);
            },
            .nonzero => {
                try testing.expect(block_hash != 0);
            },
        }
    }
}

// Comprehensive block info operations fuzz testing
test "fuzz_block_info_operations" {
    const allocator = testing.allocator;

    const block_info_tests = [_]struct {
        opcode: u8,
        opcode_name: []const u8,
        block_number: u64,
        block_timestamp: u64,
        block_coinbase: primitives.Address.Address,
        block_difficulty: u256,
        block_gas_limit: u64,
        block_base_fee: u256,
        blob_base_fee: u256,
        expected_value: u256,
        description: []const u8,
    }{
        // COINBASE tests
        .{
            .opcode = 0x41,
            .opcode_name = "COINBASE",
            .block_number = 1000,
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 30000000,
            .block_base_fee = 1000000000,
            .blob_base_fee = 1,
            .expected_value = 0,
            .description = "COINBASE zero address",
        },
        .{
            .opcode = 0x41,
            .opcode_name = "COINBASE",
            .block_number = 1000,
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.from_u256(std.math.maxInt(u160)),
            .block_difficulty = 0,
            .block_gas_limit = 30000000,
            .block_base_fee = 1000000000,
            .blob_base_fee = 1,
            .expected_value = std.math.maxInt(u160),
            .description = "COINBASE maximum address",
        },
        .{
            .opcode = 0x41,
            .opcode_name = "COINBASE",
            .block_number = 1000,
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.from_u256(0xDEADBEEF),
            .block_difficulty = 0,
            .block_gas_limit = 30000000,
            .block_base_fee = 1000000000,
            .blob_base_fee = 1,
            .expected_value = 0xDEADBEEF,
            .description = "COINBASE custom address",
        },

        // TIMESTAMP tests
        .{
            .opcode = 0x42,
            .opcode_name = "TIMESTAMP",
            .block_number = 1000,
            .block_timestamp = 0,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 30000000,
            .block_base_fee = 1000000000,
            .blob_base_fee = 1,
            .expected_value = 0,
            .description = "TIMESTAMP zero",
        },
        .{
            .opcode = 0x42,
            .opcode_name = "TIMESTAMP",
            .block_number = 1000,
            .block_timestamp = std.math.maxInt(u64),
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 30000000,
            .block_base_fee = 1000000000,
            .blob_base_fee = 1,
            .expected_value = std.math.maxInt(u64),
            .description = "TIMESTAMP maximum",
        },
        .{
            .opcode = 0x42,
            .opcode_name = "TIMESTAMP",
            .block_number = 1000,
            .block_timestamp = 1609459200, // 2021-01-01 00:00:00 UTC
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 30000000,
            .block_base_fee = 1000000000,
            .blob_base_fee = 1,
            .expected_value = 1609459200,
            .description = "TIMESTAMP realistic value",
        },

        // NUMBER tests
        .{
            .opcode = 0x43,
            .opcode_name = "NUMBER",
            .block_number = 0,
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 30000000,
            .block_base_fee = 1000000000,
            .blob_base_fee = 1,
            .expected_value = 0,
            .description = "NUMBER genesis block",
        },
        .{
            .opcode = 0x43,
            .opcode_name = "NUMBER",
            .block_number = std.math.maxInt(u64),
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 30000000,
            .block_base_fee = 1000000000,
            .blob_base_fee = 1,
            .expected_value = std.math.maxInt(u64),
            .description = "NUMBER maximum block",
        },
        .{
            .opcode = 0x43,
            .opcode_name = "NUMBER",
            .block_number = 18000000, // Realistic mainnet block
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 30000000,
            .block_base_fee = 1000000000,
            .blob_base_fee = 1,
            .expected_value = 18000000,
            .description = "NUMBER realistic mainnet block",
        },

        // DIFFICULTY/PREVRANDAO tests
        .{
            .opcode = 0x44,
            .opcode_name = "DIFFICULTY",
            .block_number = 1000,
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 30000000,
            .block_base_fee = 1000000000,
            .blob_base_fee = 1,
            .expected_value = 0,
            .description = "DIFFICULTY zero (post-merge)",
        },
        .{
            .opcode = 0x44,
            .opcode_name = "DIFFICULTY",
            .block_number = 1000,
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = std.math.maxInt(u256),
            .block_gas_limit = 30000000,
            .block_base_fee = 1000000000,
            .blob_base_fee = 1,
            .expected_value = std.math.maxInt(u256),
            .description = "DIFFICULTY maximum value",
        },
        .{
            .opcode = 0x44,
            .opcode_name = "DIFFICULTY",
            .block_number = 1000,
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0x1234567890ABCDEF,
            .block_gas_limit = 30000000,
            .block_base_fee = 1000000000,
            .blob_base_fee = 1,
            .expected_value = 0x1234567890ABCDEF,
            .description = "DIFFICULTY custom value",
        },

        // GASLIMIT tests
        .{
            .opcode = 0x45,
            .opcode_name = "GASLIMIT",
            .block_number = 1000,
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 0,
            .block_base_fee = 1000000000,
            .blob_base_fee = 1,
            .expected_value = 0,
            .description = "GASLIMIT zero (edge case)",
        },
        .{
            .opcode = 0x45,
            .opcode_name = "GASLIMIT",
            .block_number = 1000,
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = std.math.maxInt(u64),
            .block_base_fee = 1000000000,
            .blob_base_fee = 1,
            .expected_value = std.math.maxInt(u64),
            .description = "GASLIMIT maximum",
        },
        .{
            .opcode = 0x45,
            .opcode_name = "GASLIMIT",
            .block_number = 1000,
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 30000000,
            .block_base_fee = 1000000000,
            .blob_base_fee = 1,
            .expected_value = 30000000,
            .description = "GASLIMIT mainnet typical",
        },

        // BASEFEE tests (EIP-1559)
        .{
            .opcode = 0x48,
            .opcode_name = "BASEFEE",
            .block_number = 1000,
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 30000000,
            .block_base_fee = 0,
            .blob_base_fee = 1,
            .expected_value = 0,
            .description = "BASEFEE zero (pre-EIP-1559 or edge case)",
        },
        .{
            .opcode = 0x48,
            .opcode_name = "BASEFEE",
            .block_number = 1000,
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 30000000,
            .block_base_fee = std.math.maxInt(u256),
            .blob_base_fee = 1,
            .expected_value = std.math.maxInt(u256),
            .description = "BASEFEE maximum",
        },
        .{
            .opcode = 0x48,
            .opcode_name = "BASEFEE",
            .block_number = 1000,
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 30000000,
            .block_base_fee = 15000000000, // 15 gwei
            .blob_base_fee = 1,
            .expected_value = 15000000000,
            .description = "BASEFEE typical value",
        },

        // BLOBBASEFEE tests (EIP-4844)
        .{
            .opcode = 0x4A,
            .opcode_name = "BLOBBASEFEE",
            .block_number = 1000,
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 30000000,
            .block_base_fee = 1000000000,
            .blob_base_fee = 0,
            .expected_value = 0,
            .description = "BLOBBASEFEE zero",
        },
        .{
            .opcode = 0x4A,
            .opcode_name = "BLOBBASEFEE",
            .block_number = 1000,
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 30000000,
            .block_base_fee = 1000000000,
            .blob_base_fee = std.math.maxInt(u256),
            .expected_value = std.math.maxInt(u256),
            .description = "BLOBBASEFEE maximum",
        },
        .{
            .opcode = 0x4A,
            .opcode_name = "BLOBBASEFEE",
            .block_number = 1000,
            .block_timestamp = 1234567890,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 30000000,
            .block_base_fee = 1000000000,
            .blob_base_fee = 1000000000, // 1 gwei
            .expected_value = 1000000000,
            .description = "BLOBBASEFEE typical value",
        },
    };

    for (block_info_tests) |test_case| {
        const opcode_bytes = [_]u8{test_case.opcode};
        var ctx = try create_evm_context_with_code(allocator, &opcode_bytes);
        defer deinit_evm_context(ctx, allocator);

        // Set block context
        ctx.vm.context.block_number = test_case.block_number;
        ctx.vm.context.block_timestamp = test_case.block_timestamp;
        ctx.vm.context.block_coinbase = test_case.block_coinbase;
        ctx.vm.context.block_difficulty = test_case.block_difficulty;
        ctx.vm.context.block_gas_limit = test_case.block_gas_limit;
        ctx.vm.context.block_base_fee = test_case.block_base_fee;
        ctx.vm.context.blob_base_fee = test_case.blob_base_fee;

        const interpreter: *evm.Operation.Interpreter = @ptrCast(&ctx.vm);
        const state: *evm.Operation.State = @ptrCast(&ctx.frame);

        const result = try ctx.vm.table.execute(0, interpreter, state, test_case.opcode);
        _ = result;

        const returned_value = try ctx.frame.stack.pop();
        try testing.expectEqual(test_case.expected_value, returned_value);
    }
}

// Comprehensive BLOBHASH operation fuzz testing
test "fuzz_blobhash_operation_edge_cases" {
    const allocator = testing.allocator;

    const blobhash_tests = [_]struct {
        blob_hashes: []const u256,
        query_index: u256,
        expected_result: enum { zero, hash },
        expected_hash: u256,
        description: []const u8,
    }{
        // Empty blob hashes
        .{
            .blob_hashes = &[_]u256{},
            .query_index = 0,
            .expected_result = .zero,
            .expected_hash = 0,
            .description = "Empty blob hashes array returns zero",
        },
        .{
            .blob_hashes = &[_]u256{},
            .query_index = 1,
            .expected_result = .zero,
            .expected_hash = 0,
            .description = "Empty blob hashes out of bounds returns zero",
        },
        .{
            .blob_hashes = &[_]u256{},
            .query_index = std.math.maxInt(u256),
            .expected_result = .zero,
            .expected_hash = 0,
            .description = "Empty blob hashes max index returns zero",
        },

        // Single blob hash
        .{
            .blob_hashes = &[_]u256{0x1111111111111111111111111111111111111111111111111111111111111111},
            .query_index = 0,
            .expected_result = .hash,
            .expected_hash = 0x1111111111111111111111111111111111111111111111111111111111111111,
            .description = "Single blob hash valid index",
        },
        .{
            .blob_hashes = &[_]u256{0x1111111111111111111111111111111111111111111111111111111111111111},
            .query_index = 1,
            .expected_result = .zero,
            .expected_hash = 0,
            .description = "Single blob hash out of bounds",
        },

        // Multiple blob hashes
        .{
            .blob_hashes = &[_]u256{
                0x1111111111111111111111111111111111111111111111111111111111111111,
                0x2222222222222222222222222222222222222222222222222222222222222222,
                0x3333333333333333333333333333333333333333333333333333333333333333,
            },
            .query_index = 0,
            .expected_result = .hash,
            .expected_hash = 0x1111111111111111111111111111111111111111111111111111111111111111,
            .description = "Multiple blob hashes first index",
        },
        .{
            .blob_hashes = &[_]u256{
                0x1111111111111111111111111111111111111111111111111111111111111111,
                0x2222222222222222222222222222222222222222222222222222222222222222,
                0x3333333333333333333333333333333333333333333333333333333333333333,
            },
            .query_index = 1,
            .expected_result = .hash,
            .expected_hash = 0x2222222222222222222222222222222222222222222222222222222222222222,
            .description = "Multiple blob hashes middle index",
        },
        .{
            .blob_hashes = &[_]u256{
                0x1111111111111111111111111111111111111111111111111111111111111111,
                0x2222222222222222222222222222222222222222222222222222222222222222,
                0x3333333333333333333333333333333333333333333333333333333333333333,
            },
            .query_index = 2,
            .expected_result = .hash,
            .expected_hash = 0x3333333333333333333333333333333333333333333333333333333333333333,
            .description = "Multiple blob hashes last index",
        },
        .{
            .blob_hashes = &[_]u256{
                0x1111111111111111111111111111111111111111111111111111111111111111,
                0x2222222222222222222222222222222222222222222222222222222222222222,
                0x3333333333333333333333333333333333333333333333333333333333333333,
            },
            .query_index = 3,
            .expected_result = .zero,
            .expected_hash = 0,
            .description = "Multiple blob hashes out of bounds",
        },

        // Maximum blob hashes (6 per EIP-4844)
        .{
            .blob_hashes = &[_]u256{
                0x1111111111111111111111111111111111111111111111111111111111111111,
                0x2222222222222222222222222222222222222222222222222222222222222222,
                0x3333333333333333333333333333333333333333333333333333333333333333,
                0x4444444444444444444444444444444444444444444444444444444444444444,
                0x5555555555555555555555555555555555555555555555555555555555555555,
                0x6666666666666666666666666666666666666666666666666666666666666666,
            },
            .query_index = 5,
            .expected_result = .hash,
            .expected_hash = 0x6666666666666666666666666666666666666666666666666666666666666666,
            .description = "Maximum blob hashes last valid index",
        },
        .{
            .blob_hashes = &[_]u256{
                0x1111111111111111111111111111111111111111111111111111111111111111,
                0x2222222222222222222222222222222222222222222222222222222222222222,
                0x3333333333333333333333333333333333333333333333333333333333333333,
                0x4444444444444444444444444444444444444444444444444444444444444444,
                0x5555555555555555555555555555555555555555555555555555555555555555,
                0x6666666666666666666666666666666666666666666666666666666666666666,
            },
            .query_index = 6,
            .expected_result = .zero,
            .expected_hash = 0,
            .description = "Maximum blob hashes out of bounds",
        },

        // Edge cases with special values
        .{
            .blob_hashes = &[_]u256{0x0000000000000000000000000000000000000000000000000000000000000000},
            .query_index = 0,
            .expected_result = .hash,
            .expected_hash = 0x0000000000000000000000000000000000000000000000000000000000000000,
            .description = "Zero blob hash",
        },
        .{
            .blob_hashes = &[_]u256{std.math.maxInt(u256)},
            .query_index = 0,
            .expected_result = .hash,
            .expected_hash = std.math.maxInt(u256),
            .description = "Maximum blob hash",
        },

        // Large index edge cases
        .{
            .blob_hashes = &[_]u256{0x1111111111111111111111111111111111111111111111111111111111111111},
            .query_index = 1000,
            .expected_result = .zero,
            .expected_hash = 0,
            .description = "Large index out of bounds",
        },
        .{
            .blob_hashes = &[_]u256{0x1111111111111111111111111111111111111111111111111111111111111111},
            .query_index = std.math.maxInt(u256),
            .expected_result = .zero,
            .expected_hash = 0,
            .description = "Maximum index out of bounds",
        },
    };

    for (blobhash_tests) |test_case| {
        const blobhash_code = [_]u8{0x49}; // BLOBHASH
        var ctx = try create_evm_context_with_code(allocator, &blobhash_code);
        defer deinit_evm_context(ctx, allocator);

        // Set blob hashes in context
        ctx.vm.context.blob_hashes = test_case.blob_hashes;

        // Setup stack for BLOBHASH (index)
        try ctx.frame.stack.append(test_case.query_index);

        const interpreter: *evm.Operation.Interpreter = @ptrCast(&ctx.vm);
        const state: *evm.Operation.State = @ptrCast(&ctx.frame);

        const result = try ctx.vm.table.execute(0, interpreter, state, 0x49);
        _ = result;

        const returned_hash = try ctx.frame.stack.pop();

        switch (test_case.expected_result) {
            .zero => {
                try testing.expectEqual(@as(u256, 0), returned_hash);
            },
            .hash => {
                try testing.expectEqual(test_case.expected_hash, returned_hash);
            },
        }
    }
}

// Random block context operations stress testing
test "fuzz_block_operations_random_stress" {
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xB10C);
    const random = prng.random();

    // Test many random combinations of block operations
    for (0..100) |_| {
        const operations = [_]u8{ 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x48, 0x49, 0x4A };
        const op_index = random.intRangeAtMost(usize, 0, operations.len - 1);
        const opcode = operations[op_index];

        const opcode_bytes = [_]u8{opcode};
        var ctx = try create_evm_context_with_code(allocator, &opcode_bytes);
        defer deinit_evm_context(ctx, allocator);

        // Set random block context values
        ctx.vm.context.block_number = random.int(u64);
        ctx.vm.context.block_timestamp = random.int(u64);
        ctx.vm.context.block_coinbase = primitives.Address.from_u256(random.int(u160));
        ctx.vm.context.block_difficulty = random.int(u256);
        ctx.vm.context.block_gas_limit = random.int(u64);
        ctx.vm.context.block_base_fee = random.int(u256);
        ctx.vm.context.blob_base_fee = random.int(u256);

        // Generate random blob hashes
        const num_blob_hashes = random.intRangeAtMost(usize, 0, 6);
        const blob_hashes = try allocator.alloc(u256, num_blob_hashes);
        defer allocator.free(blob_hashes);
        for (blob_hashes) |*hash| {
            hash.* = random.int(u256);
        }
        ctx.vm.context.blob_hashes = blob_hashes;

        // For BLOCKHASH and BLOBHASH, we need to push an argument
        if (opcode == 0x40) { // BLOCKHASH
            const query_block = random.int(u256);
            try ctx.frame.stack.append(query_block);
        } else if (opcode == 0x49) { // BLOBHASH
            const query_index = random.intRangeAtMost(u256, 0, 10);
            try ctx.frame.stack.append(query_index);
        }

        const interpreter: *evm.Operation.Interpreter = @ptrCast(&ctx.vm);
        const state: *evm.Operation.State = @ptrCast(&ctx.frame);

        const result = try ctx.vm.table.execute(0, interpreter, state, opcode);
        _ = result;

        // All operations should return a valid u256 value
        const returned_value = try ctx.frame.stack.pop();
        try testing.expect(@TypeOf(returned_value) == u256);

        // Validate operation-specific invariants
        switch (opcode) {
            0x40 => { // BLOCKHASH
                // Covered by specific tests
            },
            0x41 => { // COINBASE
                const expected = primitives.Address.to_u256(ctx.vm.context.block_coinbase);
                try testing.expectEqual(expected, returned_value);
            },
            0x42 => { // TIMESTAMP
                try testing.expectEqual(@as(u256, ctx.vm.context.block_timestamp), returned_value);
            },
            0x43 => { // NUMBER
                try testing.expectEqual(@as(u256, ctx.vm.context.block_number), returned_value);
            },
            0x44 => { // DIFFICULTY/PREVRANDAO
                try testing.expectEqual(ctx.vm.context.block_difficulty, returned_value);
            },
            0x45 => { // GASLIMIT
                try testing.expectEqual(@as(u256, ctx.vm.context.block_gas_limit), returned_value);
            },
            0x48 => { // BASEFEE
                try testing.expectEqual(ctx.vm.context.block_base_fee, returned_value);
            },
            0x49 => { // BLOBHASH
                // Validated by logic within the operation
            },
            0x4A => { // BLOBBASEFEE
                try testing.expectEqual(ctx.vm.context.blob_base_fee, returned_value);
            },
            else => unreachable,
        }
    }
}

// Block context consistency testing
test "fuzz_block_context_consistency" {
    const allocator = testing.allocator;

    // Test that multiple calls to the same operation return consistent results
    const consistency_tests = [_]struct {
        opcode: u8,
        requires_argument: bool,
        description: []const u8,
    }{
        .{ .opcode = 0x41, .requires_argument = false, .description = "COINBASE consistency" },
        .{ .opcode = 0x42, .requires_argument = false, .description = "TIMESTAMP consistency" },
        .{ .opcode = 0x43, .requires_argument = false, .description = "NUMBER consistency" },
        .{ .opcode = 0x44, .requires_argument = false, .description = "DIFFICULTY consistency" },
        .{ .opcode = 0x45, .requires_argument = false, .description = "GASLIMIT consistency" },
        .{ .opcode = 0x48, .requires_argument = false, .description = "BASEFEE consistency" },
        .{ .opcode = 0x4A, .requires_argument = false, .description = "BLOBBASEFEE consistency" },
    };

    for (consistency_tests) |test_case| {
        const opcode_bytes = [_]u8{test_case.opcode};
        var ctx = try create_evm_context_with_code(allocator, &opcode_bytes);
        defer deinit_evm_context(ctx, allocator);

        // Set consistent block context
        ctx.vm.context.block_number = 12345678;
        ctx.vm.context.block_timestamp = 1700000000;
        ctx.vm.context.block_coinbase = primitives.Address.from_u256(0xDEADBEEF);
        ctx.vm.context.block_difficulty = 0x123456789ABCDEF;
        ctx.vm.context.block_gas_limit = 30000000;
        ctx.vm.context.block_base_fee = 15000000000;
        ctx.vm.context.blob_base_fee = 1000000000;

        const interpreter: *evm.Operation.Interpreter = @ptrCast(&ctx.vm);
        const state: *evm.Operation.State = @ptrCast(&ctx.frame);

        // First call
        const result1 = try ctx.vm.table.execute(0, interpreter, state, test_case.opcode);
        _ = result1;
        const value1 = try ctx.frame.stack.pop();

        // Second call
        const result2 = try ctx.vm.table.execute(0, interpreter, state, test_case.opcode);
        _ = result2;
        const value2 = try ctx.frame.stack.pop();

        // Values should be consistent
        try testing.expectEqual(value1, value2);
    }
}

// Gas consumption testing for block operations
test "fuzz_block_operations_gas_consumption" {
    const allocator = testing.allocator;

    const gas_tests = [_]struct {
        opcode: u8,
        initial_gas: u64,
        description: []const u8,
    }{
        .{ .opcode = 0x40, .initial_gas = 1000000, .description = "BLOCKHASH with high gas" },
        .{ .opcode = 0x40, .initial_gas = 100, .description = "BLOCKHASH with low gas" },
        .{ .opcode = 0x41, .initial_gas = 1000000, .description = "COINBASE with high gas" },
        .{ .opcode = 0x41, .initial_gas = 10, .description = "COINBASE with very low gas" },
        .{ .opcode = 0x42, .initial_gas = 1000000, .description = "TIMESTAMP with high gas" },
        .{ .opcode = 0x43, .initial_gas = 1000000, .description = "NUMBER with high gas" },
        .{ .opcode = 0x44, .initial_gas = 1000000, .description = "DIFFICULTY with high gas" },
        .{ .opcode = 0x45, .initial_gas = 1000000, .description = "GASLIMIT with high gas" },
        .{ .opcode = 0x48, .initial_gas = 1000000, .description = "BASEFEE with high gas" },
        .{ .opcode = 0x49, .initial_gas = 1000000, .description = "BLOBHASH with high gas" },
        .{ .opcode = 0x49, .initial_gas = 50, .description = "BLOBHASH with low gas" },
        .{ .opcode = 0x4A, .initial_gas = 1000000, .description = "BLOBBASEFEE with high gas" },
    };

    for (gas_tests) |test_case| {
        const opcode_bytes = [_]u8{test_case.opcode};
        var ctx = try create_evm_context_with_code(allocator, &opcode_bytes);
        defer deinit_evm_context(ctx, allocator);

        ctx.frame.gas_remaining = test_case.initial_gas;

        // Set reasonable block context
        ctx.vm.context.block_number = 1000;
        ctx.vm.context.block_timestamp = 1234567890;
        ctx.vm.context.block_coinbase = primitives.Address.ZERO;
        ctx.vm.context.block_difficulty = 0;
        ctx.vm.context.block_gas_limit = 30000000;
        ctx.vm.context.block_base_fee = 1000000000;
        ctx.vm.context.blob_base_fee = 1;
        ctx.vm.context.blob_hashes = &[_]u256{0x1111111111111111111111111111111111111111111111111111111111111111};

        // Setup stack arguments for operations that need them
        if (test_case.opcode == 0x40) { // BLOCKHASH
            try ctx.frame.stack.append(999); // Valid block number
        } else if (test_case.opcode == 0x49) { // BLOBHASH
            try ctx.frame.stack.append(0); // Valid index
        }

        const gas_before = ctx.frame.gas_remaining;

        const interpreter: *evm.Operation.Interpreter = @ptrCast(&ctx.vm);
        const state: *evm.Operation.State = @ptrCast(&ctx.frame);

        const result = ctx.vm.table.execute(0, interpreter, state, test_case.opcode);

        if (result) |_| {
            // Success - verify gas consumption
            const gas_used = gas_before - ctx.frame.gas_remaining;
            try testing.expect(gas_used > 0); // All operations should consume some gas
            try testing.expect(gas_used <= gas_before); // Can't use more than available

            // Verify operation completed successfully
            const returned_value = try ctx.frame.stack.pop();
            try testing.expect(@TypeOf(returned_value) == u256);
        } else |err| {
            // Handle expected failures for low gas scenarios
            switch (err) {
                error.OutOfGas => {
                    try testing.expect(test_case.initial_gas < 100); // Should only fail with very low gas
                },
                else => return err,
            }
        }
    }
}
