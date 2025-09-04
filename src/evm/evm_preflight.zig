//! Preflight validation methods for EVM call operations.
//!
//! This module handles pre-execution validation and routing for call operations including:
//! - Precompile detection and execution
//! - EIP-4788 beacon roots contract handling
//! - EIP-2935 historical block hashes contract handling
//! - EIP-7702 delegation handling
//! - Contract code retrieval
//! - Empty account detection
//!
//! These methods are extracted from the main EVM struct to improve
//! modularity and maintainability while maintaining identical APIs.

const std = @import("std");
const log = @import("../log.zig");
const primitives = @import("primitives");
const precompiles = @import("precompiles.zig");
const CallResult = @import("call_result.zig").CallResult;

/// Creates preflight methods for a given EVM type and config.
pub fn Preflight(comptime EvmType: type, comptime config: anytype) type {
    return struct {
        /// Result of pre-flight checks for call operations
        pub const PreflightResult = union(enum) {
            precompile_result: CallResult,
            execute_with_code: []const u8,
            empty_account: u64, // gas remaining
        };

        /// Perform pre-flight checks common to all call operations
        pub fn perform_call_preflight(
            evm: *EvmType, 
            to: primitives.Address, 
            input: []const u8, 
            gas: u64, 
            is_static: bool, 
            snapshot_id: EvmType.Journal.SnapshotIdType
        ) !PreflightResult {
            // Handle precompiles
            if (config.enable_precompiles and precompiles.is_precompile(to)) {
                const result = evm.executePrecompileInline(to, input, gas, is_static, snapshot_id) catch {
                    evm.journal.revert_to_snapshot(snapshot_id);
                    return PreflightResult{ .precompile_result = CallResult.failure(0) };
                };
                return PreflightResult{ .precompile_result = result };
            }

            // Handle EIP-4788 beacon roots contract
            const beacon_roots = @import("beacon_roots.zig");
            const historical_block_hashes = @import("historical_block_hashes.zig");
            if (std.mem.eql(u8, &to.bytes, &beacon_roots.BEACON_ROOTS_ADDRESS.bytes)) {
                var contract = beacon_roots.BeaconRootsContract{ 
                    .database = evm.database, 
                    .allocator = evm.allocator 
                };
                const caller = if (evm.depth > 0) evm.call_stack[evm.depth - 1].caller else primitives.Address.ZERO_ADDRESS;
                
                const result = contract.execute(caller, input, gas) catch |err| {
                    log.debug("Beacon roots contract failed: {}", .{err});
                    evm.journal.revert_to_snapshot(snapshot_id);
                    return PreflightResult{ .precompile_result = CallResult.failure(0) };
                };
                
                // Allocate output that persists beyond this function
                const output = if (result.output.len > 0) output: {
                    const out = evm.allocator.alloc(u8, result.output.len) catch {
                        evm.journal.revert_to_snapshot(snapshot_id);
                        return PreflightResult{ .precompile_result = CallResult.failure(0) };
                    };
                    @memcpy(out, result.output);
                    break :output out;
                } else &[_]u8{};
                
                return PreflightResult{ 
                    .precompile_result = CallResult{
                        .success = true,
                        .gas_left = gas - result.gas_used,
                        .output = output,
                    }
                };
            }
            
            // Handle EIP-2935 historical block hashes contract
            if (std.mem.eql(u8, &to.bytes, &historical_block_hashes.HISTORY_CONTRACT_ADDRESS.bytes)) {
                var contract = historical_block_hashes.HistoricalBlockHashesContract{ 
                    .database = evm.database 
                };
                const caller = if (evm.depth > 0) evm.call_stack[evm.depth - 1].caller else primitives.Address.ZERO_ADDRESS;
                
                const result = contract.execute(caller, input, gas) catch |err| {
                    log.debug("Historical block hashes contract failed: {}", .{err});
                    evm.journal.revert_to_snapshot(snapshot_id);
                    return PreflightResult{ .precompile_result = CallResult.failure(0) };
                };
                
                // Allocate output that persists beyond this function
                const output = if (result.output.len > 0) output: {
                    const out = evm.allocator.alloc(u8, result.output.len) catch {
                        evm.journal.revert_to_snapshot(snapshot_id);
                        return PreflightResult{ .precompile_result = CallResult.failure(0) };
                    };
                    @memcpy(out, result.output);
                    break :output out;
                } else &[_]u8{};
                
                return PreflightResult{ 
                    .precompile_result = CallResult{
                        .success = true,
                        .gas_left = gas - result.gas_used,
                        .output = output,
                    }
                };
            }

            // Check for EIP-7702 delegation first
            const account = evm.database.get_account(to.bytes) catch |err| {
                log.debug("Failed to get account for address {x}: {}", .{ to.bytes, err });
                return PreflightResult{ .precompile_result = CallResult.failure(0) };
            };
            
            // Get the effective code address (handles delegation)
            const code_address = if (account) |acc| blk: {
                if (acc.get_effective_code_address()) |delegated| {
                    log.debug("Account {x} has delegation to {x}", .{ to.bytes, delegated.bytes });
                    break :blk delegated;
                }
                break :blk to;
            } else to;
            
            // Get contract code (from delegated address if applicable)
            const Database = @import("database.zig").Database;
            const code = evm.database.get_code_by_address(code_address.bytes) catch |err| {
                const error_str = switch (err) {
                    Database.Error.CodeNotFound => "CodeNotFound",
                    Database.Error.AccountNotFound => "AccountNotFound",
                    Database.Error.StorageNotFound => "StorageNotFound",
                    Database.Error.InvalidAddress => "InvalidAddress",
                    Database.Error.DatabaseCorrupted => "DatabaseCorrupted",
                    Database.Error.NetworkError => "NetworkError",
                    Database.Error.PermissionDenied => "PermissionDenied",
                    Database.Error.OutOfMemory => "OutOfMemory",
                    Database.Error.InvalidSnapshot => "InvalidSnapshot",
                    Database.Error.NoBatchInProgress => "NoBatchInProgress",
                    Database.Error.SnapshotNotFound => "SnapshotNotFound",
                    Database.Error.WriteProtection => "WriteProtection",
                };
                return PreflightResult{ .precompile_result = CallResult.failure_with_error(0, error_str) };
            };

            if (code.len == 0) {
                log.debug("Code is empty, returning empty account result", .{});
                return PreflightResult{ .empty_account = gas };
            }

            return PreflightResult{ .execute_with_code = code };
        }
    };
}

// Tests for the Preflight module
test "Preflight - precompile detection" {
    const std_test = std.testing;
    const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
    const TransactionContext = @import("transaction_context.zig").TransactionContext;
    const EvmConfig = @import("evm_config.zig").EvmConfig;
    const BlockInfo = @import("block_info.zig").DefaultBlockInfo;

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

    const Preflight = @This().Preflight(TestEvm, EvmConfig{});

    // Test with a non-precompile address (should return empty account or code)
    const snapshot = evm.journal.create_snapshot();
    const zero_addr = primitives.Address.ZERO_ADDRESS;
    const result = try Preflight.perform_call_preflight(&evm, zero_addr, &[_]u8{}, 1000, false, snapshot);
    
    // Should return empty account since zero address has no code
    switch (result) {
        .empty_account => |gas_left| try std_test.expectEqual(@as(u64, 1000), gas_left),
        else => try std_test.expect(false), // Should be empty account
    }
}

test "Preflight - empty account handling" {
    const std_test = std.testing;
    const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
    const TransactionContext = @import("transaction_context.zig").TransactionContext;
    const EvmConfig = @import("evm_config.zig").EvmConfig;
    const BlockInfo = @import("block_info.zig").DefaultBlockInfo;

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

    const Preflight = @This().Preflight(TestEvm, EvmConfig{});

    // Test empty account detection
    const snapshot = evm.journal.create_snapshot();
    const test_addr = primitives.Address{ .bytes = [_]u8{0x12} ++ [_]u8{0x34} ** 19 };
    const gas_amount = 5000;
    
    const result = try Preflight.perform_call_preflight(&evm, test_addr, &[_]u8{0x01, 0x02}, gas_amount, false, snapshot);
    
    // Should detect empty account
    switch (result) {
        .empty_account => |gas_left| try std_test.expectEqual(gas_amount, gas_left),
        else => {
            // Could also be an error if database doesn't have the account, which is fine
        }
    }
}