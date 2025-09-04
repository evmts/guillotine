//! Transaction-level entry points for EVM execution.
//!
//! This module provides the main entry points for EVM transaction execution:
//! - call() - Execute an EVM operation with state commitment
//! - simulate() - Execute an EVM operation without state commitment
//!
//! These methods coordinate between all other EVM modules.

const std = @import("std");
const log = @import("../log.zig");
const CallParams = @import("call_params.zig").CallParams;
const CallResult = @import("call_result.zig").CallResult;

/// Creates transaction methods for a given EVM type.
pub fn Transaction(comptime EvmType: type) type {
    return struct {
        /// Top-level transaction entry point
        pub fn call(evm: *EvmType, params: CallParams) CallResult {
            params.validate() catch return CallResult.failure(0);
            
            // Only reset state for top-level calls (depth == 0)
            if (evm.depth == 0) {
                // Clear access list for new transaction
                evm.access_list.clear();
                // Clear logs for new transaction
                evm.logs.clearRetainingCapacity();
            }

            // Clear call arena for reuse
            evm.call_arena.deinit();
            evm.call_arena = std.heap.ArenaAllocator.init(evm.allocator);

            const result = switch (params.kind) {
                .call => evm.inner_call(params) catch CallResult.failure(0),
                .delegate_call => evm.inner_call(params) catch CallResult.failure(0),
                .static_call => evm.inner_call(params) catch CallResult.failure(0),
                .create => evm.inner_call(params) catch CallResult.failure(0),
                .create2 => evm.inner_call(params) catch CallResult.failure(0),
            };

            return result;
        }

        /// Simulate a transaction without committing state changes
        pub fn simulate(evm: *EvmType, params: CallParams) CallResult {
            // Create a snapshot before execution
            const snapshot_id = evm.journal.create_snapshot();
            
            // For top-level simulations, we need to clear the access list
            // to ensure consistent gas costs across multiple simulations
            const is_top_level = evm.depth == 0;
            if (is_top_level) {
                evm.access_list.clear();
            }
            
            // Always revert database state changes
            defer {
                // For simulate, we don't need to apply individual reverts since
                // we're discarding all state anyway. Just truncate the journal.
                // This avoids potential stack overflow with large numbers of entries.
                evm.journal.revert_to_snapshot(snapshot_id);
            }
            
            // Execute the call normally and return its result
            // Note: call() will also try to clear for top-level, but that's OK - clearing twice is safe
            return call(evm, params);
        }
    };
}

// Basic tests
test "Transaction - basic functionality" {
    const std_test = std.testing;
    const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
    const TransactionContext = @import("transaction_context.zig").TransactionContext;
    const EvmConfig = @import("evm_config.zig").EvmConfig;
    const BlockInfo = @import("block_info.zig").DefaultBlockInfo;
    const primitives = @import("primitives");

    // Create test EVM instance
    var db = MemoryDatabase.init(std_test.allocator);
    defer db.deinit();

    const test_block_info = BlockInfo{
        .number = 1000,
        .timestamp = 1600000000,
        .chain_id = 1,
        .difficulty = 1000000,
        .gas_limit = 30000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .basefee = 1000000000,
        .prevrandao = [32]u8{0} ** 32,
        .blob_excess_gas_and_price = .{ .excess_blob_gas = 0, .blob_gasprice = 1 },
    };

    const test_context = TransactionContext{
        .gas_limit = 30000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .chain_id = 1,
    };

    const TestEvm = @import("evm.zig").Evm(EvmConfig{});
    var evm = try TestEvm.init(
        std_test.allocator,
        &db.database,
        test_block_info,
        test_context,
        1000000000,
        primitives.Address.ZERO_ADDRESS,
        .shanghai,
    );
    defer evm.deinit();

    const Transaction = @This().Transaction(TestEvm);

    // Test basic call parameter validation
    var invalid_params = CallParams{
        .kind = .call,
        .to = primitives.Address.ZERO_ADDRESS,
        .caller = primitives.Address.ZERO_ADDRESS,
        .value = 0,
        .input = &[_]u8{},
        .gas = 0, // Invalid - zero gas
    };

    const result = Transaction.call(&evm, invalid_params);
    try std_test.expect(!result.success); // Should fail validation
}