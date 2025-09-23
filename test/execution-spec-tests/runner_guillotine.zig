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
const CallParams = MainEvm.CallParams;
const CallResult = MainEvm.CallResult;
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
    const hardfork = parser.parseHardfork(hardfork_str);
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
        0; // Shouldn't happen, but handle gracefully

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
        hardfork,
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
    const to_address = if (test_case.transaction.to) |to| try primitives.Address.from_hex(to) else null;

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

    const call_result = evm.call(call_params);

    // Check if execution was successful
    if (!call_result.success) {
        const error_msg = call_result.error_info orelse "Unknown error";
        result.error_message = try std.fmt.allocPrint(allocator, "Execution failed: {s}", .{error_msg});
        // Mark as success=false but return normally (not an error)
        result.success = false;
        return result;
    }

    // Get expected post state for this hardfork
    const post_entries = try parser.getPostStateEntries(allocator, test_case.post, hardfork_str);
    if (post_entries.len == 0) {
        result.error_message = try std.fmt.allocPrint(allocator, "No post state for hardfork: {s}", .{hardfork_str});
        return result;
    }

    // Compare with expected state (using first entry)
    const expected_state = post_entries[0].state;
    const comp_result = try comparison.compareState(allocator, evm, expected_state);

    if (comp_result.success) {
        result.success = true;
    } else {
        result.mismatches = comp_result.mismatches;
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
