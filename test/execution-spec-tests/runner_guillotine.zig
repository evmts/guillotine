const std = @import("std");
const primitives = @import("primitives");
const evm_mod = @import("evm");
const MainEvm = evm_mod.MainnetEvm;
const Database = evm_mod.Database;
const Account = evm_mod.Account;
const BlockInfo = evm_mod.BlockInfo;
const TransactionContext = evm_mod.TransactionContext;
const types = @import("types.zig");
const parser = @import("parser.zig");
const comparison = @import("comparison.zig");

const Address = primitives.Address;
const Allocator = std.mem.Allocator;
const CallParams = evm_mod.CallParams;
const CallResult = evm_mod.CallResult;
const Hardfork = evm_mod.Hardfork;

/// Result of running a single test
pub const TestResult = struct {
    name: []const u8,
    hardfork: []const u8,
    success: bool,
    error_message: ?[]const u8 = null,
    mismatches: ?[]const comparison.Mismatch = null,

    pub fn deinit(self: *TestResult, allocator: Allocator) void {
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
        if (self.mismatches) |m| {
            for (m) |mismatch| {
                allocator.free(@constCast(mismatch.expected));
                allocator.free(@constCast(mismatch.actual));
            }
            allocator.free(m);
        }
    }
};

/// Run a single test case
pub fn runTest(
    allocator: Allocator,
    test_name: []const u8,
    test_case: types.TestCase,
    hardfork_str: []const u8,
) !TestResult {
    var result = TestResult{
        .name = test_name,
        .hardfork = hardfork_str,
        .success = false,
    };

    // Parse hardfork and context data
    _ = parser.parseHardfork(hardfork_str); // hardfork is now configured at compile time
    const chain_id = try primitives.Hex.hex_to_u64(test_case.config.chainid);
    const block_number = try primitives.Hex.hex_to_u64(test_case.env.currentNumber);
    const block_timestamp = try primitives.Hex.hex_to_u64(test_case.env.currentTimestamp);
    const block_difficulty = if (test_case.env.currentDifficulty) |d| try primitives.Hex.hex_to_u256(d) else 0;
    const block_prevrandao = if (test_case.env.currentRandom) |r| try primitives.Hex.hex_to_u256(r) else block_difficulty;
    const block_coinbase = try primitives.Address.from_hex(test_case.env.currentCoinbase);
    const block_gas_limit = try primitives.Hex.hex_to_u64(test_case.env.currentGasLimit);
    const block_base_fee = if (test_case.env.currentBaseFee) |b| try primitives.Hex.hex_to_u64(b) else 0;
    const block_blob_base_fee = if (test_case.env.currentBlobBaseFee) |b| try primitives.Hex.hex_to_u64(b) else 1;
    const origin = try primitives.Address.from_hex(test_case.transaction.sender);

    // Handle both legacy and EIP-1559 transactions
    const gas_price = if (test_case.transaction.gasPrice) |gp|
        try primitives.Hex.hex_to_u256(gp)
    else if (test_case.transaction.maxFeePerGas) |mfpg|
        try primitives.Hex.hex_to_u256(mfpg) // Use maxFeePerGas as effective gas price for now
    else
        unreachable;

    // Create database
    const db = try allocator.create(Database);
    defer allocator.destroy(db);
    db.* = Database.init(allocator);
    defer db.deinit();

    // Create block info
    const block_info = BlockInfo{
        .number = block_number,
        .timestamp = block_timestamp,
        .gas_limit = block_gas_limit,
        .coinbase = block_coinbase,
        .base_fee = block_base_fee,
        .difficulty = block_difficulty,
        .prev_randao = @bitCast(@byteSwap(block_prevrandao)), // Convert u256 to [32]u8 big-endian
        .chain_id = @intCast(chain_id),
        .blob_base_fee = @intCast(block_blob_base_fee),
    };

    // Create transaction context
    const tx_context = TransactionContext{
        .gas_limit = block_gas_limit, // Use block gas limit as default
        .coinbase = block_coinbase,
        .chain_id = @intCast(chain_id),
        .blob_base_fee = @intCast(block_blob_base_fee),
    };

    // Initialize MainEvm
    const evm = try allocator.create(MainEvm);
    defer allocator.destroy(evm);
    evm.* = MainEvm.init(
        allocator,
        db,
        block_info,
        tx_context,
        @intCast(gas_price),
        origin,
    ) catch |err| {
        result.error_message = try std.fmt.allocPrint(allocator, "Failed to init EVM: {s}", .{@errorName(err)});
        result.success = false;
        return result;
    };
    defer evm.deinit();

    // Setup pre-state
    setupPreState(evm, test_case.pre) catch |err| {
        result.error_message = try std.fmt.allocPrint(allocator, "Failed to setup pre-state: {s}", .{@errorName(err)});
        result.success = false;
        return result;
    };

    // Get transaction parameters (using first variant for now)
    const gas_limit = primitives.Hex.hex_to_u64(test_case.transaction.gasLimit[0]) catch |err| {
        result.error_message = try std.fmt.allocPrint(allocator, "Failed to parse gas limit: {s}", .{@errorName(err)});
        result.success = false;
        return result;
    };
    const value = primitives.Hex.hex_to_u256(test_case.transaction.value[0]) catch |err| {
        result.error_message = try std.fmt.allocPrint(allocator, "Failed to parse value: {s}", .{@errorName(err)});
        result.success = false;
        return result;
    };
    const data = primitives.Hex.from_hex(allocator, test_case.transaction.data[0]) catch |err| {
        result.error_message = try std.fmt.allocPrint(allocator, "Failed to parse data: {s}", .{@errorName(err)});
        result.success = false;
        return result;
    };
    defer allocator.free(data);

    // Execute transaction
    const to_address = blk: {
        if (test_case.transaction.to) |to| {
            if (to.len == 0) break :blk null;
            break :blk try primitives.Address.from_hex(to);
        }
        break :blk null;
    };

    const call_params = if (to_address) |to| CallParams{
        .call = .{
            .caller = origin,
            .to = to,
            .value = value,
            .input = data,
            .gas = gas_limit,
        },
    } else CallParams{
        .create = .{
            .caller = origin,
            .value = value,
            .init_code = data,
            .gas = gas_limit,
        },
    };

    // Debug logging for transaction execution
    std.debug.print("\n========================================\n", .{});
    std.debug.print("TEST: {s}\n", .{test_name});
    std.debug.print("HARDFORK: {s}\n", .{hardfork_str});
    std.debug.print("========================================\n", .{});

    // Log blockchain context
    std.debug.print("\n--- BLOCKCHAIN CONTEXT ---\n", .{});
    std.debug.print("Block Number:     {}\n", .{block_number});
    std.debug.print("Block Timestamp:  {}\n", .{block_timestamp});
    std.debug.print("Block Gas Limit:  {}\n", .{block_gas_limit});
    std.debug.print("Block Base Fee:   {}\n", .{block_base_fee});
    std.debug.print("Block Coinbase:   {s}\n", .{block_coinbase.address_to_hex()});
    std.debug.print("Chain ID:         {}\n", .{chain_id});
    std.debug.print("Gas Price:        {}\n", .{gas_price});

    // Log transaction parameters
    std.debug.print("\n--- TRANSACTION PARAMETERS ---\n", .{});
    std.debug.print("Type:             {s}\n", .{if (to_address == null) "CREATE" else "CALL"});
    std.debug.print("From (Origin):    {s}\n", .{origin.address_to_hex()});
    if (to_address) |to| {
        std.debug.print("To:               {s}\n", .{to.address_to_hex()});
    } else {
        std.debug.print("To:               (contract creation)\n", .{});
    }
    std.debug.print("Value:            0x{s}\n", .{try primitives.Hex.u256_to_hex(allocator, value)});
    std.debug.print("Gas Limit:        {}\n", .{gas_limit});
    std.debug.print("Data Length:      {} bytes\n", .{data.len});
    if (data.len > 0 and data.len <= 64) {
        std.debug.print("Data:             0x{s}\n", .{try primitives.Hex.bytes_to_hex(allocator, data)});
    } else if (data.len > 64) {
        std.debug.print("Data (first 64):  0x{s}...\n", .{try primitives.Hex.bytes_to_hex(allocator, data[0..@min(64, data.len)])});
    }

    // Log call parameters details
    std.debug.print("\n--- CALL PARAMS STRUCT ---\n", .{});
    switch (call_params) {
        .call => |params| {
            std.debug.print("Type:             CALL\n", .{});
            std.debug.print("  Caller:         {s}\n", .{params.caller.address_to_hex()});
            std.debug.print("  To:             {s}\n", .{params.to.address_to_hex()});
            std.debug.print("  Value:          0x{s}\n", .{try primitives.Hex.u256_to_hex(allocator, params.value)});
            std.debug.print("  Gas:            {}\n", .{params.gas});
            std.debug.print("  Input Length:   {} bytes\n", .{params.input.len});
        },
        .create => |params| {
            std.debug.print("Type:             CREATE\n", .{});
            std.debug.print("  Caller:         {s}\n", .{params.caller.address_to_hex()});
            std.debug.print("  Value:          0x{s}\n", .{try primitives.Hex.u256_to_hex(allocator, params.value)});
            std.debug.print("  Gas:            {}\n", .{params.gas});
            std.debug.print("  Init Code Len:  {} bytes\n", .{params.init_code.len});
        },
        else => unreachable,
    }

    // Log pre-state of origin account
    std.debug.print("\n--- ORIGIN ACCOUNT STATE ---\n", .{});
    const origin_account = evm.database.get_account(origin.bytes) catch null orelse Account.zero();
    std.debug.print("Balance:          0x{s}\n", .{try primitives.Hex.u256_to_hex(allocator, origin_account.balance)});
    std.debug.print("Nonce:            {}\n", .{origin_account.nonce});

    // Log pre-state of to account if it's a call
    if (to_address) |to| {
        std.debug.print("\n--- TO ACCOUNT PRE-STATE ---\n", .{});
        const to_account = evm.database.get_account(to.bytes) catch null orelse Account.zero();
        std.debug.print("Address:          {s}\n", .{to.address_to_hex()});
        std.debug.print("Balance:          0x{s}\n", .{try primitives.Hex.u256_to_hex(allocator, to_account.balance)});
        std.debug.print("Nonce:            {}\n", .{to_account.nonce});
        std.debug.print("Code Hash:        0x{s}\n", .{try primitives.Hex.bytes_to_hex(allocator, &to_account.code_hash)});
        std.debug.print("Storage Root:     0x{s}\n", .{try primitives.Hex.bytes_to_hex(allocator, &to_account.storage_root)});

        // Check if account has code
        const code = evm.database.get_code(to_account.code_hash) catch null;
        if (code) |c| {
            // Note: 'c' is owned by the database, do NOT free it
            std.debug.print("Code Length:      {} bytes\n", .{c.len});
            if (c.len > 0 and c.len <= 64) {
                const hex_str = try primitives.Hex.bytes_to_hex(allocator, c);
                defer allocator.free(hex_str);
                std.debug.print("Code:             0x{s}\n", .{hex_str});
            } else if (c.len > 64) {
                const hex_str = try primitives.Hex.bytes_to_hex(allocator, c[0..@min(64, c.len)]);
                defer allocator.free(hex_str);
                std.debug.print("Code (first 64):  0x{s}...\n", .{hex_str});
            }
        } else {
            std.debug.print("Code:             (none)\n", .{});
        }

        // Log some storage slots if they exist
        std.debug.print("\n--- TO ACCOUNT STORAGE (sample) ---\n", .{});
        const slot_0 = evm.database.get_storage(to.bytes, 0) catch null orelse 0;
        const slot_1 = evm.database.get_storage(to.bytes, 1) catch null orelse 0;
        if (slot_0 != 0) {
            std.debug.print("Slot[0]:          0x{s}\n", .{try primitives.Hex.u256_to_hex(allocator, slot_0)});
        }
        if (slot_1 != 0) {
            std.debug.print("Slot[1]:          0x{s}\n", .{try primitives.Hex.u256_to_hex(allocator, slot_1)});
        }
        if (slot_0 == 0 and slot_1 == 0) {
            std.debug.print("(empty or zero storage)\n", .{});
        }
    }

    std.debug.print("\n========================================\n", .{});

    // Execute the transaction
    std.debug.print("debug: Entering evm.call\n", .{});
    const call_result = evm.call(call_params);
    std.debug.print("debug: Exited evm.call\n", .{});

    // Check if execution was successful
    if (!call_result.success) {
        const error_msg = if (call_result.error_info) |info| info else "Unknown error";
        result.error_message = try std.fmt.allocPrint(allocator, "Execution failed: {s}", .{error_msg});
        result.success = false;
        return result;
    }

    // Get expected post state for this hardfork
    const post_entries = parser.getPostStateEntries(allocator, test_case.post, hardfork_str) catch |err| {
        result.error_message = try std.fmt.allocPrint(allocator, "Failed to get post state: {s}", .{@errorName(err)});
        result.success = false;
        return result;
    };
    defer allocator.free(post_entries);

    if (post_entries.len == 0) {
        result.error_message = try std.fmt.allocPrint(allocator, "No post state for hardfork: {s}", .{hardfork_str});
        result.success = false;
        return result;
    }

    // Compare with expected state (using first entry)
    const expected_state = post_entries[0].state;
    const comp_result = comparison.compareState(allocator, evm, expected_state) catch |err| {
        result.error_message = try std.fmt.allocPrint(allocator, "Failed to compare state: {s}", .{@errorName(err)});
        result.success = false;
        return result;
    };

    if (comp_result.success) {
        result.success = true;
    } else {
        result.mismatches = comp_result.mismatches;
        result.success = false;
    }

    return result;
}

/// Setup pre-state in EVM
fn setupPreState(evm: *MainEvm, pre: std.json.Value) !void {
    const pre_obj = pre.object;
    var it = pre_obj.iterator();
    while (it.next()) |entry| {
        const address_str = entry.key_ptr.*;
        const address = try primitives.Address.from_hex(address_str);
        const account_data = entry.value_ptr.*.object;

        // Get existing account or create new one
        var account = (try evm.database.get_account(address.bytes)) orelse Account.zero();

        // Set balance
        if (account_data.get("balance")) |balance_val| {
            const balance = try primitives.Hex.hex_to_u256(balance_val.string);
            account.balance = balance;
        }

        // Set nonce
        if (account_data.get("nonce")) |nonce_val| {
            const nonce = try primitives.Hex.hex_to_u64(nonce_val.string);
            account.nonce = nonce;
        }

        // Set code
        if (account_data.get("code")) |code_val| {
            const code = try primitives.Hex.from_hex(evm.allocator, code_val.string);
            defer evm.allocator.free(code);
            const code_hash = try evm.database.set_code(code);
            account.code_hash = code_hash;
        }

        // Save the account
        try evm.database.set_account(address.bytes, account);

        // Set storage
        if (account_data.get("storage")) |storage_val| {
            const storage_obj = storage_val.object;
            var storage_it = storage_obj.iterator();
            while (storage_it.next()) |storage_entry| {
                const slot_str = storage_entry.key_ptr.*;
                const value_str = storage_entry.value_ptr.*.string;

                const slot = try primitives.Hex.hex_to_u256(slot_str);
                const value = try primitives.Hex.hex_to_u256(value_str);
                try evm.database.set_storage(address.bytes, slot, value);
            }
        }
    }
}
