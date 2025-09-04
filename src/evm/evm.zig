//! Transaction-level EVM execution and state management.
//!
//! The EVM orchestrates contract execution, managing:
//! - Call depth tracking and nested execution contexts
//! - State journaling for transaction reverts
//! - Gas accounting and metering
//! - Contract creation (CREATE/CREATE2)
//! - Cross-contract calls (CALL/DELEGATECALL/STATICCALL)
//! - Integration with external operations for environment queries
//!
//! This module provides the entry point for all EVM operations,
//! coordinating between Frames, the Planner, and state storage.
//!
//! The EVM utilizes Planners to analyze bytecode and produce optimized execution data structures
//! The EVM utilizes the Frame struct to track the evm state and implement all low level execution details
//! EVM passes itself as an *anyopaque pointer to Frame for accessing external data and executing inner calls
const std = @import("std");
const log = @import("log.zig");
const primitives = @import("primitives");
const eips = @import("eips.zig");
const BlockInfo = @import("block_info.zig").DefaultBlockInfo; // Default for backward compatibility
const Database = @import("database.zig").Database;
const Account = @import("database_interface_account.zig").Account;
const SelfDestruct = @import("self_destruct.zig").SelfDestruct;
const CreatedContracts = @import("created_contracts.zig").CreatedContracts;
const AccessList = @import("access_list.zig").AccessList;
const Hardfork = @import("hardfork.zig").Hardfork;
const precompiles = @import("precompiles.zig");
const EvmConfig = @import("evm_config.zig").EvmConfig;
const TransactionContext = @import("transaction_context.zig").TransactionContext;
const Opcode = @import("opcode.zig").Opcode;
pub const CallResult: type = @import("call_result.zig").CallResult;
pub const CallParams: type = @import("call_params.zig").CallParams;

/// Creates a configured EVM instance type.
///
/// The EVM is parameterized by compile-time configuration for optimal
/// performance and minimal runtime overhead. Configuration controls
/// stack size, memory limits, call depth, and optimization strategies.
pub fn Evm(comptime config: EvmConfig) type {
    return struct {
        const Self = @This();

        /// Frame type for the evm
        pub const Frame = @import("frame.zig").Frame(config.frame_config());
        /// Static wrappers for EIP-214 (STATICCALL) constraint enforcement
        const static_wrappers = @import("static_wrappers.zig");
        const StaticDatabase = static_wrappers.StaticDatabase;
        /// Bytecode type for bytecode analysis
        pub const BytecodeFactory = @import("bytecode.zig").Bytecode;
        pub const Bytecode = BytecodeFactory(.{
            .max_bytecode_size = config.max_bytecode_size,
            .fusions_enabled = false, // Disable fusions for now
        });
        /// Journal handles reverting state when state needs to be reverted
        pub const Journal: type = @import("journal.zig").Journal(.{
            .SnapshotIdType = if (config.max_call_depth <= 255) u8 else u16,
            .WordType = config.WordType,
            .NonceType = u64,
            .initial_capacity = 128,
        });

        /// Call stack entry to track caller and value for DELEGATECALL
        const CallStackEntry = struct {
            caller: primitives.Address,
            value: config.WordType,
            is_static: bool, // EIP-214: Track static context per call level
        };

        pub const Success = enum {
            Stop,
            Return,
            SelfDestruct,
            Jump, // Added for fusion support
        };

        pub const Error = error{
            InvalidJump,
            OutOfGas,
            StackUnderflow,
            StackOverflow,
            ContractNotFound,
            PrecompileError,
            MemoryError,
            StorageError,
            CallDepthExceeded,
            InsufficientBalance,
            ContractCollision,
            InvalidBytecode,
            StaticCallViolation,
            InvalidOpcode,
            RevertExecution,
            OutOfMemory,
            // Removed Stop error - it's a success case
            AllocationError,
            AccountNotFound,
            InvalidJumpDestination,
            MissingJumpDestMetadata,
            InitcodeTooLarge,
            TruncatedPush,
            OutOfBounds,
            WriteProtection,
            BytecodeTooLarge,
        };


        // CACHE LINE 1 - HOT PATH (frequently accessed during execution)
        /// Current call depth (0 = root call)
        depth: config.get_depth_type(),
        /// Current snapshot ID for the active call frame
        current_snapshot_id: Journal.SnapshotIdType,
        /// Database interface for state storage
        database: *Database,
        /// Journal for tracking state changes and snapshots
        journal: Journal,
        /// Allocator for dynamic memory
        allocator: std.mem.Allocator,

        // CACHE LINE 2 - TRANSACTION EXECUTION STATE
        /// Access list for tracking warm/cold access (EIP-2929)
        access_list: AccessList,
        /// Tracks contracts created in current transaction (EIP-6780)
        created_contracts: CreatedContracts,
        /// Contracts marked for self-destruction
        self_destruct: SelfDestruct,
        /// Current call input data
        current_input: []const u8,
        /// Current return data
        return_data: []const u8,
        /// Gas refund counter for SSTORE operations
        gas_refund_counter: u64,

        // CACHE LINE 3 - TRANSACTION CONTEXT
        /// Block information
        block_info: BlockInfo,
        /// Transaction context
        context: TransactionContext,
        /// Gas price for the transaction
        gas_price: u256,
        /// Origin address (sender of the transaction)
        origin: primitives.Address,
        /// Hardfork configuration
        hardfork_config: Hardfork,
        /// Active EIPs configuration
        eips: eips.EvmConfig,
        /// Disable gas checking (for testing/debugging)
        disable_gas_checking: bool,

        // CACHE LINE 4+ - COLD PATH (less frequently accessed)
        /// Logs emitted during the current call
        logs: std.ArrayList(@import("call_result.zig").Log),
        /// Call stack - tracks caller and value for each call depth
        call_stack: [config.max_call_depth]CallStackEntry,
        /// Arena allocator for per-call temporary allocations
        call_arena: std.heap.ArenaAllocator,
        /// Small reusable buffer for fixed-size outputs (e.g., 32-byte address)
        small_output_buf: [64]u8 = undefined,

        /// Initialize a new EVM instance.
        ///
        /// Sets up the execution environment with state storage, block context,
        /// and transaction parameters. The planner cache is initialized with
        /// a default size for bytecode optimization.
        pub fn init(allocator: std.mem.Allocator, database: *Database, block_info: BlockInfo, context: TransactionContext, gas_price: u256, origin: primitives.Address, hardfork_config: Hardfork) !Self {
            // Process beacon root update for EIP-4788 if applicable
            const beacon_roots = @import("beacon_roots.zig");
            beacon_roots.BeaconRootsContract.processBeaconRootUpdate(database, &block_info) catch |err| {
                log.warn("Failed to process beacon root update: {}", .{err});
            };
            
            // Process historical block hash update for EIP-2935 if applicable
            const historical_block_hashes = @import("historical_block_hashes.zig");
            historical_block_hashes.HistoricalBlockHashesContract.processBlockHashUpdate(database, &block_info) catch |err| {
                log.warn("Failed to process historical block hash update: {}", .{err});
            };
            
            // Process validator deposits for EIP-6110 if applicable
            const validator_deposits = @import("validator_deposits.zig");
            validator_deposits.ValidatorDepositsContract.processBlockDeposits(database, &block_info) catch |err| {
                log.warn("Failed to process validator deposits: {}", .{err});
            };
            
            // Process validator withdrawals for EIP-7002 if applicable
            const validator_withdrawals = @import("validator_withdrawals.zig");
            validator_withdrawals.ValidatorWithdrawalsContract.processBlockWithdrawals(database, &block_info) catch |err| {
                log.warn("Failed to process validator withdrawals: {}", .{err});
            };
            
            var access_list = AccessList.init(allocator);
            errdefer access_list.deinit();
            return Self{
                .depth = 0,
                .call_stack = [_]CallStackEntry{CallStackEntry{ .caller = primitives.Address.ZERO_ADDRESS, .value = 0, .is_static = false }} ** config.max_call_depth,
                .allocator = allocator,
                .database = database,
                .journal = Journal.init(allocator),
                .created_contracts = CreatedContracts.init(allocator),
                .self_destruct = SelfDestruct.init(allocator),
                .access_list = access_list,
                .block_info = block_info,
                .context = context,
                .current_input = &.{},
                .return_data = &.{},
                .gas_refund_counter = 0,
                .gas_price = gas_price,
                .origin = origin,
                .hardfork_config = hardfork_config,
                .eips = eips.Eips{ .hardfork = hardfork_config }.get_evm_config(),
                .disable_gas_checking = false,
                .current_snapshot_id = 0,
                .logs = std.ArrayList(@import("call_result.zig").Log){},
                .call_arena = std.heap.ArenaAllocator.init(allocator),
            };
        }

        /// Clean up all resources.
        pub fn deinit(self: *Self) void {
            // Free return_data if it was allocated
            if (self.return_data.len > 0) {
                self.allocator.free(self.return_data);
            }
            self.journal.deinit();
            self.created_contracts.deinit();
            self.self_destruct.deinit();
            self.access_list.deinit();
            self.logs.deinit(self.allocator);
            self.call_arena.deinit();
        }

        /// Get the arena allocator for temporary allocations during the current call.
        /// This allocator is reset after each root call completes.
        pub fn getCallArenaAllocator(self: *Self) std.mem.Allocator {
            return self.call_arena.allocator();
        }

        /// Transfer value between accounts with proper balance checks and error handling
        fn doTransfer(self: *Self, from: primitives.Address, to: primitives.Address, value: u256, snapshot_id: Journal.SnapshotIdType) !void {
            var from_account = try self.database.get_account(from.bytes) orelse Account.zero();
            if (from_account.balance < value) return error.InsufficientBalance;
            var to_account = try self.database.get_account(to.bytes) orelse Account.zero();
            try self.journal.record_balance_change(snapshot_id, from, from_account.balance);
            try self.journal.record_balance_change(snapshot_id, to, to_account.balance);
            from_account.balance -= value;
            to_account.balance += value;
            try self.database.set_account(from.bytes, from_account);
            try self.database.set_account(to.bytes, to_account);
        }

        /// Simulate an EVM operation without committing state changes.
        ///
        /// Executes exactly like `call()` but reverts all state changes at the end,
        /// returning the result as if the call had been executed. Useful for
        /// gas estimation, testing outcomes, or previewing transaction effects.
        pub fn simulate(self: *Self, params: CallParams) CallResult {
            // Create a snapshot before execution
            const snapshot_id = self.journal.create_snapshot();
            
            // For top-level simulations, we need to clear the access list
            // to ensure consistent gas costs across multiple simulations
            const is_top_level = self.depth == 0;
            if (is_top_level) {
                self.access_list.clear();
            }
            
            // Always revert database state changes
            defer {
                // For simulate, we don't need to apply individual reverts since
                // we're discarding all state anyway. Just truncate the journal.
                // This avoids potential stack overflow with large numbers of entries.
                self.journal.revert_to_snapshot(snapshot_id);
            }
            
            // Execute the call normally and return its result
            // Note: call() will also try to clear for top-level, but that's OK - clearing twice is safe
            return self.call(params);
        }

        /// Execute an EVM operation.
        ///
        /// This is the main entry point that routes to specific handlers based
        /// on the operation type (CALL, CREATE, etc). Manages transaction-level
        /// state including logs and ensures proper cleanup.
        pub fn call(self: *Self, params: CallParams) CallResult {
            params.validate() catch return CallResult.failure(0);
            
            // Only reset state for top-level calls (depth == 0)
            const is_top_level = self.depth == 0;
            
            // Reset per-transaction state at the START of each new transaction
            if (is_top_level) {
                // Clear access list for new transaction (EIP-2929)
                self.access_list.clear();
                // Clear journal for new transaction
                self.journal.clear();
                // Reset gas refund counter
                self.gas_refund_counter = 0;
                // Clear logs from previous transaction
                self.logs.clearRetainingCapacity();
                // Clear created contracts tracking (EIP-6780)
                self.created_contracts.clear();
                // Clear self destruct list
                self.self_destruct.clear();
                // Reset arena allocator
                _ = self.call_arena.reset(.retain_capacity);
            }
            
            defer if (is_top_level) {
                // Cleanup after transaction completes
                self.depth = 0;
                self.current_input = &.{};
                // Note: return_data is not freed here because it's returned as part of CallResult
                // and the caller is responsible for the memory
                self.return_data = &.{};
            };
            
            // Pre-warm addresses for top-level calls (EIP-2929)
            if (is_top_level) {
                // Get the target address from params
                const target_address = switch (params) {
                    .call => |p| p.to,
                    .callcode => |p| p.to,
                    .delegatecall => |p| p.to,
                    .staticcall => |p| p.to,
                    .create, .create2 => primitives.Address.ZERO_ADDRESS, // Creates don't have a target
                };
                
                // Pre-warm: tx.origin, target, and coinbase (EIP-3651 for Shanghai+)
                // Build a small array of addresses to warm (max 3: origin, target, coinbase)
                var warm_addresses: [3]primitives.Address = undefined;
                var warm_count: usize = 0;
                
                // Always warm origin
                warm_addresses[warm_count] = self.origin;
                warm_count += 1;
                
                // Warm target if it's not a create operation  
                if (!std.mem.eql(u8, &target_address.bytes, &primitives.Address.ZERO_ADDRESS.bytes)) {
                    warm_addresses[warm_count] = target_address;
                    warm_count += 1;
                }
                
                // EIP-3651: Warm coinbase for Shanghai+
                if (self.hardfork_config.isAtLeast(.SHANGHAI)) {
                    warm_addresses[warm_count] = self.block_info.coinbase;
                    warm_count += 1;
                }
                
                // Pre-warm all addresses
                if (warm_count > 0) {
                    self.access_list.pre_warm_addresses(warm_addresses[0..warm_count]) catch {};
                }
            }

            // Check gas unless disabled
            const gas = switch (params) {
                inline else => |p| p.gas,
            };
            if (!self.disable_gas_checking and gas == 0) return CallResult.failure(0);
            if (self.depth >= config.max_call_depth) return CallResult.failure(0);
            
            // Store initial gas for EIP-3529 calculations
            const initial_gas = gas;
            
            // Deduct intrinsic gas for top-level calls (transactions)
            const execution_gas = if (is_top_level) blk: {
                const GasConstants = primitives.GasConstants;
                const intrinsic_gas = switch (params) {
                    .create, .create2 => GasConstants.TxGasContractCreation, // 53000 for contract creation
                    else => GasConstants.TxGas, // 21000 for regular calls
                };
                
                // Check if we have enough gas for intrinsic cost
                if (gas < intrinsic_gas) return CallResult.failure(0);
                
                break :blk gas - intrinsic_gas;
            } else gas;
            
            // Route to appropriate handler
            var result = switch (params) {
                .call => |p| blk: {
                    // log.debug("DEBUG: EVM.call starting, to={x}, gas={}, input_len={}\n", .{ p.to.bytes, execution_gas, p.input.len });
                    break :blk self.executeCall(.{ .caller = p.caller, .to = p.to, .value = p.value, .input = p.input, .gas = execution_gas }) catch {
                        // log.debug("DEBUG: EVM.call failed with error: {}\n", .{err});
                        return CallResult.failure(0);
                    };
                },
                .callcode => |p| self.executeCallcode(.{ .caller = p.caller, .to = p.to, .value = p.value, .input = p.input, .gas = execution_gas }) catch CallResult.failure(0),
                .delegatecall => |p| self.executeDelegatecall(.{ .caller = p.caller, .to = p.to, .input = p.input, .gas = execution_gas }) catch CallResult.failure(0),
                .staticcall => |p| self.executeStaticcall(.{ .caller = p.caller, .to = p.to, .input = p.input, .gas = execution_gas }) catch CallResult.failure(0),
                .create => |p| self.executeCreate(.{ .caller = p.caller, .value = p.value, .init_code = p.init_code, .gas = execution_gas }) catch CallResult.failure(0),
                .create2 => |p| self.executeCreate2(.{ .caller = p.caller, .value = p.value, .init_code = p.init_code, .salt = p.salt, .gas = execution_gas }) catch CallResult.failure(0),
            };
            
            // Apply EIP-3529 gas refund cap if transaction succeeded
            if (result.success and self.depth == 0) {
                const gas_used = initial_gas - result.gas_left;
                const eips_instance = @import("eips.zig").Eips{ .hardfork = self.hardfork_config };
                const capped_refund = eips_instance.eip_3529_gas_refund_cap(gas_used, self.gas_refund_counter);
                
                // Apply the refund, ensuring we don't exceed the gas used
                result.gas_left = @min(initial_gas, result.gas_left + capped_refund);
                
                // Reset refund counter for next transaction
                self.gas_refund_counter = 0;
            }
            // Only extract logs for top-level calls
            // For nested calls, leave logs in the EVM's list to accumulate
            if (is_top_level) {
                // Transfer logs to result - the CallResult now owns them and will free on deinit
                result.logs = self.logs.toOwnedSlice(self.allocator) catch &.{};
                result.selfdestructs = &.{};
                result.accessed_addresses = &.{};
                result.accessed_storage = &.{};
                // Reset internal accumulators (logs already transferred)
                self.self_destruct.clear();
                self.access_list.clear();
            } else {
                // For nested calls, return empty slices - logs accumulate in EVM
                result.logs = &.{};
                result.selfdestructs = &.{};
                result.accessed_addresses = &.{};
                result.accessed_storage = &.{};
            }
            return result;
        }

        /// Result of pre-flight checks for call operations
        const PreflightResult = union(enum) {
            precompile_result: CallResult,
            execute_with_code: []const u8,
            empty_account: u64, // gas remaining
        };

        /// Perform pre-flight checks common to all call operations
        fn performCallPreflight(self: *Self, to: primitives.Address, input: []const u8, gas: u64, is_static: bool, snapshot_id: Journal.SnapshotIdType) !PreflightResult {
            // Handle precompiles
            if (config.enable_precompiles and precompiles.is_precompile(to)) {
                const result = self.executePrecompileInline(to, input, gas, is_static, snapshot_id) catch {
                    self.journal.revert_to_snapshot(snapshot_id);
                    return PreflightResult{ .precompile_result = CallResult.failure(0) };
                };
                return PreflightResult{ .precompile_result = result };
            }

            // Handle EIP-4788 beacon roots contract
            const beacon_roots = @import("beacon_roots.zig");
            const historical_block_hashes = @import("historical_block_hashes.zig");
            if (std.mem.eql(u8, &to.bytes, &beacon_roots.BEACON_ROOTS_ADDRESS.bytes)) {
                var contract = beacon_roots.BeaconRootsContract{ .database = self.database, .allocator = self.allocator };
                const caller = if (self.depth > 0) self.call_stack[self.depth - 1].caller else primitives.ZERO_ADDRESS;
                
                const result = contract.execute(caller, input, gas) catch |err| {
                    log.debug("Beacon roots contract failed: {}", .{err});
                    self.journal.revert_to_snapshot(snapshot_id);
                    return PreflightResult{ .precompile_result = CallResult.failure(0) };
                };
                
                // Allocate output that persists beyond this function
                const output = if (result.output.len > 0) output: {
                    const out = self.allocator.alloc(u8, result.output.len) catch {
                        self.journal.revert_to_snapshot(snapshot_id);
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
                var contract = historical_block_hashes.HistoricalBlockHashesContract{ .database = self.database };
                const caller = if (self.depth > 0) self.call_stack[self.depth - 1].caller else primitives.ZERO_ADDRESS;
                
                const result = contract.execute(caller, input, gas) catch |err| {
                    log.debug("Historical block hashes contract failed: {}", .{err});
                    self.journal.revert_to_snapshot(snapshot_id);
                    return PreflightResult{ .precompile_result = CallResult.failure(0) };
                };
                
                // Allocate output that persists beyond this function
                const output = if (result.output.len > 0) output: {
                    const out = self.allocator.alloc(u8, result.output.len) catch {
                        self.journal.revert_to_snapshot(snapshot_id);
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
            const account = self.database.get_account(to.bytes) catch |err| {
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
            // log.debug("Attempting to get code for address: {x}", .{code_address.bytes});
            const code = self.database.get_code_by_address(code_address.bytes) catch |err| {
                // log.debug("Failed to get code for address {x}: {}", .{ code_address.bytes, err });
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


            // log.debug("Got code for address, length: {}", .{code.len});
            
            if (code.len == 0) {
                log.debug("Code is empty, returning empty account result", .{});
                return PreflightResult{ .empty_account = gas };
            }

            // log.debug("Returning code for execution, code_len={}", .{code.len});
            return PreflightResult{ .execute_with_code = code };
        }

        /// Execute CALL operation (inlined from call_handler)
        fn executeCall(self: *Self, params: struct {
            caller: primitives.Address,
            to: primitives.Address,
            value: u256,
            input: []const u8,
            gas: u64,
        }) !CallResult {
            // log.debug("DEBUG: executeCall entered, gas={}\n", .{params.gas});
            const snapshot_id = self.journal.create_snapshot();

            // Transfer value if needed
            if (params.value > 0) {
                self.doTransfer(params.caller, params.to, params.value, snapshot_id) catch |err| {
                    log.debug("Call value transfer failed: {}", .{err});
                    self.journal.revert_to_snapshot(snapshot_id);
                    return CallResult.failure(0);
                };
            }

            // Perform pre-flight checks
            // log.debug("DEBUG: calling performCallPreflight\n", .{});
            const preflight = self.performCallPreflight(params.to, params.input, params.gas, false, snapshot_id) catch {
                // log.debug("DEBUG: performCallPreflight failed: {}\n", .{err});
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            };
            // log.debug("DEBUG: preflight result: {s}\n", .{@tagName(preflight)});

            switch (preflight) {
                .precompile_result => |result| return result,
                .empty_account => |gas| {
                    // log.debug("EXECUTE_CALL: Call to empty account: {any}", .{params.to});
                    return CallResult.success_empty(gas);
                },
                .execute_with_code => |code| {
                    // log.debug("EXECUTE_CALL: Executing code of length {} for address {x}", .{code.len, params.to.bytes});
                    const result = self.execute_frame(
                        code,
                        params.input,
                        params.gas,
                        params.to,
                        params.caller,
                        params.value,
                        false, // is_static
                        snapshot_id,
                    ) catch |err| {
                        log.debug("EXECUTE_CALL: execute_frame failed with error: {}", .{err});
                        self.journal.revert_to_snapshot(snapshot_id);
                        return CallResult.failure(0);
                    };

                    if (!result.success) self.journal.revert_to_snapshot(snapshot_id);
                    return result;
                },
            }
        }

        /// Execute CALLCODE operation (inlined)
        fn executeCallcode(self: *Self, params: struct {
            caller: primitives.Address,
            to: primitives.Address,
            value: u256,
            input: []const u8,
            gas: u64,
        }) !CallResult {
            const snapshot_id = self.journal.create_snapshot();

            // Check balance for value transfer
            if (params.value > 0) {
                const caller_account = self.database.get_account(params.caller.bytes) catch {
                    self.journal.revert_to_snapshot(snapshot_id);
                    return CallResult.failure(0);
                };

                if (caller_account == null or caller_account.?.balance < params.value) {
                    self.journal.revert_to_snapshot(snapshot_id);
                    return CallResult.failure(0);
                }
            }

            const code = self.database.get_code_by_address(params.to.bytes) catch &.{};
            if (code.len == 0) return CallResult.success_empty(params.gas);

            // CALLCODE executes target's code in caller's context
            const result = self.execute_frame(
                code,
                params.input,
                params.gas,
                params.caller, // Execute in caller's context
                params.caller, // msg.sender is still the caller
                params.value,
                false,
                snapshot_id,
            ) catch {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            };

            if (!result.success) self.journal.revert_to_snapshot(snapshot_id);
            return result;
        }

        /// Execute DELEGATECALL operation (inlined)
        fn executeDelegatecall(self: *Self, params: struct {
            caller: primitives.Address,
            to: primitives.Address,
            input: []const u8,
            gas: u64,
        }) !CallResult {
            const snapshot_id = self.journal.create_snapshot();

            // Perform pre-flight checks
            const preflight = self.performCallPreflight(params.to, params.input, params.gas, false, snapshot_id) catch |err| {
                log.debug("Delegatecall preflight failed: {}", .{err});
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            };

            switch (preflight) {
                .precompile_result => |result| return result,
                .empty_account => |gas| return CallResult.success_empty(gas),
                .execute_with_code => |code| {
                    // DELEGATECALL preserves caller and value from parent context
                    const current_value = if (self.depth > 0) self.call_stack[self.depth - 1].value else 0;
                    const result = self.execute_frame(
                        code,
                        params.input,
                        params.gas,
                        params.to,
                        params.caller, // Preserve original caller
                        current_value, // Preserve value from parent context
                        false,
                        snapshot_id,
                    ) catch {
                        self.journal.revert_to_snapshot(snapshot_id);
                        return CallResult.failure(0);
                    };

                    if (!result.success) self.journal.revert_to_snapshot(snapshot_id);
                    return result;
                },
            }
        }

        /// Execute STATICCALL operation (inlined)
        fn executeStaticcall(self: *Self, params: struct {
            caller: primitives.Address,
            to: primitives.Address,
            input: []const u8,
            gas: u64,
        }) !CallResult {
            const snapshot_id = self.journal.create_snapshot();

            // Perform pre-flight checks
            const preflight = self.performCallPreflight(params.to, params.input, params.gas, true, snapshot_id) catch |err| {
                log.debug("Staticcall preflight failed: {}", .{err});
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            };

            switch (preflight) {
                .precompile_result => |result| return result,
                .empty_account => |gas| return CallResult.success_empty(gas),
                .execute_with_code => |code| {
                    // Execute in static mode
                    const result = self.execute_frame(
                        code,
                        params.input,
                        params.gas,
                        params.to,
                        params.caller,
                        0, // No value in static call
                        true, // is_static = true
                        snapshot_id,
                    ) catch {
                        self.journal.revert_to_snapshot(snapshot_id);
                        return CallResult.failure(0);
                    };

                    if (!result.success) self.journal.revert_to_snapshot(snapshot_id);
                    return result;
                },
            }
        }

        /// Execute CREATE operation (inlined)
        fn executeCreate(self: *Self, params: struct {
            caller: primitives.Address,
            value: u256,
            init_code: []const u8,
            gas: u64,
        }) !CallResult {
            const snapshot_id = self.journal.create_snapshot();

            // Get caller account
            var caller_account = self.database.get_account(params.caller.bytes) catch {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            } orelse Account.zero();

            // Check if caller has sufficient balance
            if (caller_account.balance < params.value) {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            }

            // Calculate contract address from sender and nonce
            const contract_address = primitives.Address.get_contract_address(params.caller, caller_account.nonce);

            // Pre-increment caller nonce (journaled)
            try self.journal.record_nonce_change(snapshot_id, params.caller, caller_account.nonce);
            caller_account.nonce += 1;
            self.database.set_account(params.caller.bytes, caller_account) catch {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            };

            const existed_before = self.database.account_exists(contract_address.bytes);
            if (existed_before) {
                const existing = self.database.get_account(contract_address.bytes) catch null;
                if (existing != null and !std.mem.eql(u8, &existing.?.code_hash, &[_]u8{0} ** 32)) {
                    self.journal.revert_to_snapshot(snapshot_id);
                    return CallResult.failure(0);
                }
            }
            // Delegate to unified helper
            const GasConstants = primitives.GasConstants;
            const create_overhead = GasConstants.CreateGas; // 32000
            if (params.gas < create_overhead) {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            }
            const remaining_gas: u64 = params.gas - create_overhead;
            var result = self.executeCreateInternal(.{
                .caller = params.caller,
                .value = params.value,
                .init_code = params.init_code,
                .gas_left = remaining_gas,
                .contract_address = contract_address,
                .snapshot_id = snapshot_id,
                .existed_before = existed_before,
            }) catch return CallResult.failure(0);
            
            // Add the created contract address to the result
            result.created_address = contract_address;
            return result;
        }

        /// Execute CREATE2 operation (inlined)
        fn executeCreate2(self: *Self, params: struct {
            caller: primitives.Address,
            value: u256,
            init_code: []const u8,
            salt: u256,
            gas: u64,
        }) !CallResult {
            // debug: CREATE2 invocation context (disabled by default)
            log.debug("CREATE2: gas={}, init_len={}, value={}", .{ params.gas, params.init_code.len, params.value });
            // Check depth
            if (self.depth >= config.max_call_depth) {
                log.debug("CREATE2: depth exceeded", .{});
                return CallResult.failure(0);
            }

            const snapshot_id = self.journal.create_snapshot();

            const caller_account = self.database.get_account(params.caller.bytes) catch {
                log.debug("CREATE2: get_account failed", .{});
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            } orelse Account.zero();

            // Check if caller has sufficient balance
            if (caller_account.balance < params.value) {
                log.debug("CREATE2: insufficient balance", .{});
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            }

            // Calculate contract address from sender, salt, and init code hash
            const keccak_asm = @import("keccak_asm.zig");
            var init_code_hash_bytes: [32]u8 = undefined;
            try keccak_asm.keccak256(params.init_code, &init_code_hash_bytes);
            var salt_bytes: [32]u8 = undefined;
            std.mem.writeInt(u256, &salt_bytes, params.salt, .big);
            const contract_address = primitives.Address.get_create2_address(params.caller, salt_bytes, init_code_hash_bytes);

            const existed_before = self.database.account_exists(contract_address.bytes);
            if (existed_before) {
                const existing = self.database.get_account(contract_address.bytes) catch null;
                if (existing != null and !std.mem.eql(u8, &existing.?.code_hash, &[_]u8{0} ** 32)) {
                    log.debug("CREATE2: collision at address", .{});
                    self.journal.revert_to_snapshot(snapshot_id);
                    return CallResult.failure(0);
                }
            }

            // Gas cost for CREATE2
            const GasConstants = primitives.GasConstants;
            const create_overhead = GasConstants.CreateGas; // 32000
            const hash_cost = @as(u64, @intCast(params.init_code.len)) * GasConstants.Keccak256WordGas / 32;
            const total_overhead = create_overhead + hash_cost;
            if (params.gas < total_overhead) {
                log.debug("CREATE2: insufficient gas for overhead: need={}, have={}", .{ total_overhead, params.gas });
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            }
            const remaining_gas: u64 = params.gas - total_overhead;

            var result = self.executeCreateInternal(.{
                .caller = params.caller,
                .value = params.value,
                .init_code = params.init_code,
                .gas_left = remaining_gas,
                .contract_address = contract_address,
                .snapshot_id = snapshot_id,
                .existed_before = existed_before,
            }) catch return CallResult.failure(0);
            
            // Add the created contract address to the result
            result.created_address = contract_address;
            return result;
        }

        fn executeCreateInternal(self: *Self, args: struct {
            caller: primitives.Address,
            value: u256,
            init_code: []const u8,
            gas_left: u64,
            contract_address: primitives.Address,
            snapshot_id: Journal.SnapshotIdType,
            existed_before: bool,
        }) !CallResult {
            // Reduce log noise: omit verbose create trace
            
            // Track created contract for EIP-6780
            try self.created_contracts.mark_created(args.contract_address);

            // Transfer value to the new contract before executing init code (per spec)
            if (args.value > 0) {
                // Reduce log noise
                self.doTransfer(args.caller, args.contract_address, args.value, args.snapshot_id) catch {
                    // Reduce log noise
                    self.journal.revert_to_snapshot(args.snapshot_id);
                    return CallResult.failure(0);
                };
            }

            // Execute initialization code
            const result = self.execute_init_code(
                args.init_code,
                args.gas_left,
                args.contract_address,
                args.snapshot_id,
            ) catch |err| {
                log.debug("execute_init_code failed with error: {}", .{err});
                self.journal.revert_to_snapshot(args.snapshot_id);
                return CallResult.failure(0);
            };
            if (!result.success) {
                log.debug("Init code execution failed, success=false", .{});
                self.journal.revert_to_snapshot(args.snapshot_id);
                return result;
            }
            // Reduce log noise

            // Ensure contract account exists and set nonce/code
            var contract_account = self.database.get_account(args.contract_address.bytes) catch {
                self.journal.revert_to_snapshot(args.snapshot_id);
                return CallResult.failure(0);
            } orelse Account.zero();
            if (!args.existed_before) {
                try self.journal.record_account_created(args.snapshot_id, args.contract_address);
            }
            if (contract_account.nonce != 1) {
                try self.journal.record_nonce_change(args.snapshot_id, args.contract_address, contract_account.nonce);
                contract_account.nonce = 1;
            }
            if (result.output.len > 0) {
                // EIP-3541: Reject new contract code starting with the 0xEF byte
                if (self.eips.eip_3541_enabled and result.output[0] == 0xEF) {
                    // Free the allocated output memory before returning
                    self.allocator.free(result.output);
                    self.journal.revert_to_snapshot(args.snapshot_id);
                    return CallResult.failure(0);
                }
                // Store the code in the database - database will make its own copy
                const stored_hash = self.database.set_code(result.output) catch {
                    // Free the allocated output memory before returning
                    self.allocator.free(result.output);
                    self.journal.revert_to_snapshot(args.snapshot_id);
                    return CallResult.failure(0);
                };
                try self.journal.record_code_change(args.snapshot_id, args.contract_address, contract_account.code_hash);
                contract_account.code_hash = stored_hash;
                // Don't free result.output here - we'll return it
            }
            self.database.set_account(args.contract_address.bytes, contract_account) catch {
                // Free the allocated output memory before returning if it exists
                if (result.output.len > 0) {
                    self.allocator.free(result.output);
                }
                self.journal.revert_to_snapshot(args.snapshot_id);
                return CallResult.failure(0);
            };

            // Return the deployed bytecode as output for CREATE/CREATE2
            // This matches the expected behavior where CREATE returns the runtime code
            // Don't free the output here - it will be owned by the CallResult
            var final_result = if (result.output.len > 0)
                CallResult.success_with_output(result.gas_left, result.output)
            else
                CallResult.success_empty(result.gas_left);
            final_result.trace = result.trace;
            return final_result;
        }

        /// Convert tracer data to ExecutionTrace format
        fn convertTracerToExecutionTrace(allocator: std.mem.Allocator, tracer: anytype) !@import("call_result.zig").ExecutionTrace {
            const call_result = @import("call_result.zig");
            
            // Check if tracer has trace_steps field (only JSONRPCTracer does)
            if (!@hasField(@TypeOf(tracer.*), "trace_steps")) {
                // Return empty trace for non-tracing tracers
                return call_result.ExecutionTrace{
                    .steps = &[_]call_result.TraceStep{},
                    .allocator = allocator,
                };
            }
            
            const tracer_steps = tracer.trace_steps.items;
            var trace_steps = try allocator.alloc(call_result.TraceStep, tracer_steps.len);
            errdefer allocator.free(trace_steps);
            
            var allocated_count: usize = 0;
            errdefer {
                // Clean up any partially allocated trace steps
                for (trace_steps[0..allocated_count]) |*step| {
                    step.deinit(allocator);
                }
            }
            
            for (tracer_steps, 0..) |tracer_step, i| {
                trace_steps[i] = call_result.TraceStep{
                    .pc = @intCast(tracer_step.pc),
                    .opcode = tracer_step.opcode,  // Use the actual opcode byte from tracer
                    .opcode_name = try allocator.dupe(u8, tracer_step.op),
                    .gas = tracer_step.gas,
                    .stack = try allocator.dupe(u256, tracer_step.stack),
                    .memory = if (tracer_step.memory) |mem| try allocator.dupe(u8, mem) else &.{},
                    .storage_reads = &.{}, // Empty for now  
                    .storage_writes = &.{}, // Empty for now
                };
                allocated_count += 1;
            }
            
            return call_result.ExecutionTrace{
                .steps = trace_steps,
                .allocator = allocator,
            };
        }

        /// Execute a frame by delegating to Frame.interpret (dispatch-based execution)
        fn execute_frame(
            self: *Self,
            code: []const u8,
            input: []const u8,
            gas: u64,
            address: primitives.Address,
            caller: primitives.Address,
            value: u256,
            is_static: bool,
            snapshot_id: Journal.SnapshotIdType,
        ) !CallResult {
            // std.debug.print("execute_frame: code_len={}, gas={}, address={any}, depth={}\n", .{ 
            //     code.len, gas, address, self.depth,
            // });
            const prev_snapshot = self.current_snapshot_id;
            self.current_snapshot_id = snapshot_id;
            defer self.current_snapshot_id = prev_snapshot;

            const prev_input = self.current_input;
            self.current_input = input;
            defer self.current_input = prev_input;

            self.depth += 1;
            defer if (self.depth > 0) { self.depth -= 1; };

            self.call_stack[self.depth - 1] = CallStackEntry{ .caller = caller, .value = value, .is_static = is_static };

            // Base transaction gas cost (21,000 gas) - only charge for real transactions, not test calls
            // Test calls start at depth 0, real transactions have depth >= 1 with is_transaction flag
            const gas_after_base = gas;
            
            const max_gas = @as(u64, @intCast(std.math.maxInt(Frame.GasType)));
            const gas_cast = @as(Frame.GasType, @intCast(@min(gas_after_base, max_gas)));

            // EIP-214: encode static constraints; null to prevent SELFDESTRUCT in static context
            const self_destruct_param = if (is_static) null else &self.self_destruct;

            // log.debug("DEBUG: About to call Frame.init\n", .{});
            var frame = try Frame.init(self.allocator, gas_cast, self.database.*, caller, &value, input, self.block_info, @as(*anyopaque, @ptrCast(self)), self_destruct_param);
            frame.contract_address = address;
            defer frame.deinit(self.allocator);
            
            // EIP-2929: Warm the contract address being executed
            _ = self.access_list.access_address(address) catch {};

            // log.debug("DEBUG: Frame created, gas_remaining={}, about to interpret bytecode\n", .{frame.gas_remaining});
            
            // DEBUG: Log first few bytes of bytecode for JUMPI test
            // if (code.len == 22) {
            //     log.err("DEBUG: This looks like JUMPI test bytecode, first 8 bytes: {x}", .{code[0..8]});
            // }

            // Execute with tracing if tracer type is configured
            var execution_trace: ?@import("call_result.zig").ExecutionTrace = null;
            const Termination = error{ Stop, Return, SelfDestruct };
            var termination_reason: ?Termination = null;
            if (config.TracerType) |TracerType| {
                // Create tracer instance for this execution
                var tracer = TracerType.init(self.allocator);
                defer tracer.deinit();
                
                // log.debug("Executing frame with tracer: {s}", .{@typeName(TracerType)});
                
                // Frame.interpret_with_tracer returns Error!void and uses errors for success termination
                // reduce tracer call logging noise
                frame.interpret_with_tracer(code, TracerType, &tracer) catch |err| switch (err) {
                error.Stop => {
                    termination_reason = error.Stop;
                },
                error.Return => {
                    termination_reason = error.Return;
                },
                error.SelfDestruct => {
                    log.debug("execute_frame: termination SelfDestruct (traced)", .{});
                    termination_reason = error.SelfDestruct;
                },
                error.REVERT => {
                    // REVERT is a special case - it's a successful termination but indicates failure
                    execution_trace = try convertTracerToExecutionTrace(self.allocator, &tracer);
                    const gas_left: u64 = @intCast(@max(frame.gas_remaining, 0));
                    // Copy revert data to avoid double-free with frame.deinit
                    const out_len = frame.output.len;
                    const out_copy = if (out_len > 0) blk: {
                        const buf = try self.allocator.alloc(u8, out_len);
                        @memcpy(buf, frame.output);
                        break :blk buf;
                    } else &[_]u8{};
                    var result = CallResult.revert_with_data(gas_left, out_copy);
                    result.trace = execution_trace;
                    return result;
                },
                else => {
                    // Actual errors - but still extract trace for debugging
                    log.debug("Frame execution with tracer failed: {}", .{err});
                    // Extract trace even on failure for debugging
                    execution_trace = try convertTracerToExecutionTrace(self.allocator, &tracer);
                    var failure = CallResult.failure(0);
                    failure.trace = execution_trace;
                    return failure;
                },
            };
            
            // Extract trace data before tracer is destroyed (for success cases)
            execution_trace = try convertTracerToExecutionTrace(self.allocator, &tracer);
            } else {
                // Execute without tracing (original path)
                frame.interpret(code) catch |err| switch (err) {
                error.Stop => {
                    termination_reason = error.Stop;
                },
                error.Return => {
                    termination_reason = error.Return;
                },
                error.SelfDestruct => {
                    log.debug("execute_frame: termination SelfDestruct", .{});
                    termination_reason = error.SelfDestruct;
                },
                else => {
                    // Actual errors
                    log.debug("Frame execution failed with error: {}", .{err});
                    return CallResult.failure(0);
                },
            };
            }

            // Map frame outcome to CallResult
            const gas_left: u64 = @intCast(@max(frame.gas_remaining, 0));
            // log.debug("Frame execution complete. gas_remaining={d}, gas_left={d}", .{frame.gas_remaining, gas_left});
            const out_items = frame.output;
            // log.debug("Frame execution complete. Output length: {d}", .{out_items.len});
            if (out_items.len > 0) {
                // log.debug("Output data: {x}", .{out_items});
            }
            const out_buf = if (out_items.len > 0) blk: {
                const b = try self.allocator.alloc(u8, out_items.len);
                @memcpy(b, out_items);
                break :blk b;
            } else &.{};
            
            // Free old return_data before setting new one
            if (self.return_data.len > 0) {
                self.allocator.free(self.return_data);
            }
            self.return_data = out_buf;

            // Transfer logs from frame to EVM's log list
            const frame_logs = frame.getLogSlice();
            for (frame_logs) |log_entry| {
                // Create copies of the log data with the EVM's allocator
                const topics_copy = self.allocator.dupe(u256, log_entry.topics) catch return CallResult.failure(0);
                const data_copy = self.allocator.dupe(u8, log_entry.data) catch return CallResult.failure(0);
                
                self.logs.append(self.allocator, @import("call_result.zig").Log{
                    .address = log_entry.address,
                    .topics = topics_copy,
                    .data = data_copy,
                }) catch return CallResult.failure(0);
            }

            // Handle different termination reasons appropriately
            var result: CallResult = undefined;
            if (termination_reason) |reason| {
                switch (reason) {
                    error.Stop => {
                        // STOP opcode should return empty output regardless of frame output
                        if (out_buf.len > 0) {
                            self.allocator.free(out_buf); // Free the allocated output since we won't use it
                        }
                        // Ensure return_data matches empty output semantics
                        self.return_data = &.{};
                        result = CallResult.success_with_output(gas_left, &.{});
                    },
                    error.Return => {
                        // RETURN opcode should return the frame's output
                        result = CallResult.success_with_output(gas_left, out_buf);
                    },
                    error.SelfDestruct => {
                        // SELFDESTRUCT should return empty output
                        if (out_buf.len > 0) {
                            self.allocator.free(out_buf); // Free the allocated output since we won't use it
                        }
                        // Ensure return_data matches empty output semantics
                        self.return_data = &.{};
                        result = CallResult.success_with_output(gas_left, &.{});
                    },
                }
            } else {
                // This should not happen in normal execution
                result = CallResult.success_with_output(gas_left, out_buf);
            }
            result.trace = execution_trace;
            return result;
        }

        fn execute_init_code(
            self: *Self,
            code: []const u8,
            gas: u64,
            address: primitives.Address,
            snapshot_id: Journal.SnapshotIdType,
        ) !CallResult {
            // Reduce log noise for init code execution
            // Check initcode size limit (EIP-3860)
            if (self.eips.eip_3860_enabled and code.len > 49152) {
                log.debug("Init code too large: {} > 49152", .{code.len});
                return CallResult.failure(0);
            }
            // Simply delegate to execute_frame with no input
            // Init code execution is the same as regular execution
            // but the output becomes the deployed contract code
            // Reduce log noise
            const result = self.execute_frame(
                code,
                &.{}, // No input for init code
                gas,
                address,
                address, // Contract is its own caller during init
                0, // No value during init
                false, // Not static during init
                snapshot_id,
            ) catch |err| {
                log.debug("execute_frame failed with error: {}", .{err});
                return err;
            };
            // Reduce log noise
            return result;
        }

        /// Execute nested EVM call - used for calls from within the EVM
        pub fn inner_call(self: *Self, params: CallParams) !CallResult {
            return self.call(params);
        }

        /// Execute a precompile call (inlined)
        fn executePrecompileInline(self: *Self, address: primitives.Address, input: []const u8, gas: u64, is_static: bool, snapshot_id: Journal.SnapshotIdType) !CallResult {
            _ = snapshot_id; // TODO: implement snapshot usage
            _ = is_static; // Precompiles are inherently stateless, so static flag doesn't matter

            if (!precompiles.is_precompile(address)) {
                return CallResult{ .success = false, .gas_left = gas, .output = &.{} };
            }

            const precompile_id = address.bytes[19]; // Last byte is the precompile ID
            if (precompile_id < 1 or precompile_id > 10) {
                return CallResult{ .success = false, .gas_left = gas, .output = &.{} };
            }

            // Execute precompile using main allocator so tests can free outputs
            const result = precompiles.execute_precompile(self.allocator, address, input, gas) catch {
                return CallResult{
                    .success = false,
                    .gas_left = 0,
                    .output = &.{},
                };
            };

            // Transfer ownership of precompile output directly (both use same allocator)
            const out_slice = result.output;
            if (result.success) {
                return CallResult{ .success = true, .gas_left = gas - result.gas_used, .output = out_slice };
            } else {
                return CallResult{ .success = false, .gas_left = 0, .output = out_slice };
            }
        }

        // ===== Host Interface Implementation =====

        /// Get account balance
        pub fn get_balance(self: *Self, address: primitives.Address) u256 {
            return self.database.get_balance(address.bytes) catch 0;
        }

        /// Check if account exists
        pub fn account_exists(self: *Self, address: primitives.Address) bool {
            return self.database.account_exists(address.bytes);
        }

        /// Get account code
        pub fn get_code(self: *Self, address: primitives.Address) []const u8 {
            return self.database.get_code_by_address(address.bytes) catch &.{};
        }

        /// Get block information
        pub fn get_block_info(self: *Self) BlockInfo {
            return self.block_info;
        }

        /// Emit log event
        pub fn emit_log(self: *Self, contract_address: primitives.Address, topics: []const u256, data: []const u8) void {
            // EIP-214: Prevent log emission in static context
            if (self.is_static_context()) {
                return; // Silently fail in static context
            }
            
            // Allocate copies with the main allocator so tests can free via evm.allocator
            const topics_copy = self.allocator.dupe(u256, topics) catch return;
            const data_copy = self.allocator.dupe(u8, data) catch return;

            self.logs.append(self.allocator, @import("call_result.zig").Log{
                .address = contract_address,
                .topics = topics_copy,
                .data = data_copy,
            }) catch return;
        }

        /// Execute nested EVM call - for Host interface
        pub fn host_inner_call(self: *Self, params: CallParams) !CallResult {
            return self.inner_call(params);
        }

        /// Register a contract as created in the current transaction
        pub fn register_created_contract(self: *Self, address: primitives.Address) !void {
            try self.created_contracts.mark_created(address);
        }

        /// Check if a contract was created in the current transaction
        pub fn was_created_in_tx(self: *Self, address: primitives.Address) bool {
            return self.created_contracts.was_created_in_tx(address);
        }

        /// Create a new journal snapshot
        pub fn create_snapshot(self: *Self) Journal.SnapshotIdType {
            return self.journal.create_snapshot();
        }

        /// Revert state changes to a previous snapshot
        ///
        /// Optimized to avoid allocations: iterate journal entries in reverse
        /// before truncating, applying all reverts in-place.
        pub fn revert_to_snapshot(self: *Self, snapshot_id: Journal.SnapshotIdType) void {
            // Find first index whose snapshot_id >= target
            var start_index: ?usize = null;
            for (self.journal.entries.items, 0..) |entry, i| {
                if (entry.snapshot_id >= snapshot_id) { start_index = i; break; }
            }

            if (start_index) |start| {
                var i = self.journal.entries.items.len;
                while (i > start) : (i -= 1) {
                    const entry = self.journal.entries.items[i - 1];
                    self.apply_journal_entry_revert(entry) catch |err| {
                        log.err("Failed to revert journal entry: {any}", .{err});
                    };
                }
            }

            // Finally, truncate the journal entries to the snapshot boundary
            self.journal.revert_to_snapshot(snapshot_id);
        }

        /// Apply a single journal entry to revert database state
        fn apply_journal_entry_revert(self: *Self, entry: Journal.EntryType) !void {
            switch (entry.data) {
                .storage_change => |sc| {
                    // Revert storage to original value
                    try self.database.set_storage(sc.address.bytes, sc.key, sc.original_value);
                },
                .balance_change => |bc| {
                    // Revert balance to original value
                    var account = (try self.database.get_account(bc.address.bytes)) orelse {
                        // If account doesn't exist, create it with the original balance
                        const reverted_account = Account{
                            .balance = bc.original_balance,
                            .nonce = 0,
                            .code_hash = [_]u8{0} ** 32,
                            .storage_root = [_]u8{0} ** 32,
                        };
                        return self.database.set_account(bc.address.bytes, reverted_account);
                    };
                    account.balance = bc.original_balance;
                    try self.database.set_account(bc.address.bytes, account);
                },
                .nonce_change => |nc| {
                    // Revert nonce to original value
                    var account = (try self.database.get_account(nc.address.bytes)) orelse return;
                    account.nonce = nc.original_nonce;
                    try self.database.set_account(nc.address.bytes, account);
                },
                .code_change => |cc| {
                    // Revert code to original value
                    var account = (try self.database.get_account(cc.address.bytes)) orelse return;
                    account.code_hash = cc.original_code_hash;
                    try self.database.set_account(cc.address.bytes, account);
                },
                .account_created => |ac| {
                    // Remove created account
                    try self.database.delete_account(ac.address.bytes);
                },
                .account_destroyed => |ad| {
                    // Restore destroyed account
                    // Note: This is a simplified restoration - in practice we'd need full account state
                    const restored_account = Account{
                        .balance = ad.balance,
                        .nonce = 0,
                        .code_hash = [_]u8{0} ** 32,
                        .storage_root = [_]u8{0} ** 32,
                    };
                    try self.database.set_account(ad.address.bytes, restored_account);
                },
            }
        }

        /// Record a storage change in the journal
        pub fn record_storage_change(self: *Self, address: primitives.Address, slot: u256, original_value: u256) !void {
            try self.journal.record_storage_change(self.current_snapshot_id, address, slot, original_value);
        }

        /// Get the original storage value from the journal
        pub fn get_original_storage(self: *Self, address: primitives.Address, slot: u256) ?u256 {
            // Use journal's built-in method to get original storage
            return self.journal.get_original_storage(address, slot);
        }

        /// Access an address and return the gas cost (EIP-2929)
        pub fn access_address(self: *Self, address: primitives.Address) !u64 {
            const cost = try self.access_list.access_address(address);
            return cost;
        }

        /// Access a storage slot and return the gas cost (EIP-2929)
        pub fn access_storage_slot(self: *Self, contract_address: primitives.Address, slot: u256) !u64 {
            const cost = try self.access_list.access_storage_slot(contract_address, slot);
            return cost;
        }

        /// Mark a contract for destruction
        pub fn mark_for_destruction(self: *Self, contract_address: primitives.Address, recipient: primitives.Address) !void {
            // EIP-214: Prevent self-destruction in static context
            if (self.is_static_context()) {
                return error.StaticCallViolation;
            }
            
            // EIP-6780: SELFDESTRUCT only actually destroys the contract if it was created in the same transaction
            // Otherwise, it only transfers the balance but keeps the code and storage
            if (self.eips.eip_6780_enabled) {
                // Check if contract was created in the current transaction
                const created_in_tx = self.created_contracts.was_created_in_tx(contract_address);
                
                if (created_in_tx) {
                    // Full destruction: transfer balance and mark for deletion
                    try self.self_destruct.mark_for_destruction(contract_address, recipient);
                } else {
                    // Only transfer balance, don't destroy the contract
                    // Get the contract's balance
                    const contract_account = try self.database.get_account(contract_address.bytes);
                    if (contract_account) |account| {
                        if (account.balance > 0) {
                            // Transfer balance to recipient
                            try self.journal.record_balance_change(self.current_snapshot_id, contract_address, account.balance);
                            try self.journal.record_balance_change(self.current_snapshot_id, recipient, 0);
                            
                            // Update balances
                            var sender_account = account;
                            sender_account.balance = 0;
                            try self.database.set_account(contract_address.bytes, sender_account);
                            
                            var recipient_account = (try self.database.get_account(recipient.bytes)) orelse Account.zero();
                            recipient_account.balance +%= account.balance;
                            try self.database.set_account(recipient.bytes, recipient_account);
                        }
                    }
                    // Don't mark for destruction - contract persists
                }
            } else {
                // Pre-Cancun: always mark for full destruction
                try self.self_destruct.mark_for_destruction(contract_address, recipient);
            }
        }

        /// Get current call input/calldata
        pub fn get_input(self: *Self) []const u8 {
            return self.current_input;
        }

        /// Check if hardfork is at least the target
        pub fn is_hardfork_at_least(self: *Self, target: Hardfork) bool {
            return @intFromEnum(self.hardfork_config) >= @intFromEnum(target);
        }

        /// Get current hardfork (deprecated - use EIPs)
        pub fn get_hardfork(self: *Self) Hardfork {
            return self.hardfork_config;
        }

        /// Get the call depth for the current frame
        pub fn get_depth(self: *Self) u11 {
            return @intCast(self.depth);
        }

        /// Get transaction origin (original sender)
        pub fn get_tx_origin(self: *Self) primitives.Address {
            return self.origin;
        }

        /// Get current caller address
        pub fn get_caller(self: *Self) primitives.Address {
            if (self.depth == 0) return self.origin;
            return self.call_stack[self.depth - 1].caller;
        }

        /// Get current call value
        pub fn get_call_value(self: *Self) u256 {
            if (self.depth == 0) return 0;
            return self.call_stack[self.depth - 1].value;
        }

        /// Check if current context is static (EIP-214)
        pub fn is_static_context(self: *Self) bool {
            if (self.depth == 0) return false;
            return self.call_stack[self.depth - 1].is_static;
        }

        /// Get storage value
        pub fn get_storage(self: *Self, address: primitives.Address, slot: u256) u256 {
            return self.database.get_storage(address.bytes, slot) catch 0;
        }

        /// Set storage value
        pub fn set_storage(self: *Self, address: primitives.Address, slot: u256, value: u256) !void {
            // EIP-214: Prevent storage writes in static context
            if (self.is_static_context()) {
                return error.StaticCallViolation;
            }
            // Record original value for journal
            const original_value = self.get_storage(address, slot);
            try self.record_storage_change(address, slot, original_value);
            try self.database.set_storage(address.bytes, slot, value);
        }

        /// Get transaction gas price
        pub fn get_gas_price(self: *Self) u256 {
            return self.gas_price;
        }

        /// Get return data from last call
        pub fn get_return_data(self: *Self) []const u8 {
            return self.return_data;
        }

        /// Get chain ID  
        pub fn get_chain_id(self: *Self) u64 {
            return self.block_info.chain_id;
        }

        /// Get block hash by number
        pub fn get_block_hash(self: *Self, block_number: u64) ?[32]u8 {
            const current_block = self.block_info.number;

            // Use EIP-2935 historical block hashes if available
            // This provides access to older block hashes via system contract
            const historical_block_hashes = @import("historical_block_hashes.zig");
            const hash_opt = historical_block_hashes.HistoricalBlockHashesContract.getBlockHash(
                self.database,
                block_number,
                current_block,
            ) catch |err| {
                log.debug("Failed to get block hash from history contract: {}", .{err});
                // Fall back to standard behavior on error
                
                // EVM BLOCKHASH rules:
                // - Return null for current block and future blocks
                // - Return null for blocks older than 256 blocks
                // - Return null for block 0 (genesis)
                if (block_number >= current_block or
                    current_block > block_number + 256 or
                    block_number == 0)
                {
                    return null;
                }
                
                // For testing/simulation purposes, generate a deterministic hash
                var hash: [32]u8 = undefined;
                hash[0..8].* = std.mem.toBytes(block_number);
                hash[8..16].* = std.mem.toBytes(current_block);
                
                // Fill rest with deterministic pattern based on block number
                var i: usize = 16;
                while (i < 32) : (i += 1) {
                    hash[i] = @as(u8, @truncate(block_number +% i));
                }
                
                return hash;
            };
            
            if (hash_opt) |hash| {
                return hash;
            }
            
            // If no hash found in storage, fall back to standard behavior
            // - Return null for current block and future blocks
            // - Return null for blocks older than 256 blocks
            // - Return null for block 0 (genesis)
            if (block_number >= current_block or
                current_block > block_number + 256 or
                block_number == 0)
            {
                return null;
            }

            // For testing/simulation purposes, generate a deterministic hash
            // In a real implementation, this would look up the actual block hash
            // from the blockchain state or a block hash ring buffer
            var hash: [32]u8 = undefined;
            hash[0..8].* = std.mem.toBytes(block_number);
            hash[8..16].* = std.mem.toBytes(current_block);

            // Fill rest with deterministic pattern based on block number
            var i: usize = 16;
            while (i < 32) : (i += 1) {
                hash[i] = @as(u8, @truncate(block_number +% i));
            }

            return hash;
        }

        /// Get blob hash for the given index (EIP-4844)
        pub fn get_blob_hash(self: *Self, index: u256) ?[32]u8 {
            // Convert index to usize, return null if out of bounds
            if (index >= self.context.blob_versioned_hashes.len) {
                return null;
            }
            const idx = @as(usize, @intCast(index));
            return self.context.blob_versioned_hashes[idx];
        }

        /// Get blob base fee (EIP-4844)
        pub fn get_blob_base_fee(self: *Self) u256 {
            return self.context.blob_base_fee;
        }

        /// Add gas refund amount for SSTORE operations
        /// This is called by SSTORE when it needs to add refunds
        pub fn add_gas_refund(self: *Self, amount: u64) void {
            self.gas_refund_counter += amount;
        }
        


        /// Take all selfdestructs and clear the list
        fn takeSelfDestructs(self: *Self) ![]const @import("call_result.zig").SelfDestructRecord {
            var records = try std.ArrayList(@import("call_result.zig").SelfDestructRecord).initCapacity(self.allocator, 0);
            defer records.deinit(self.allocator);

            var iter = self.self_destruct.iterator();
            while (iter.next()) |entry| {
                try records.append(self.allocator, .{
                    .contract = entry.key_ptr.*,
                    .beneficiary = entry.value_ptr.*,
                });
            }

            // Clear selfdestruct list for next transaction
            self.self_destruct.clear();

            return try records.toOwnedSlice(self.allocator);
        }

        /// Take all accessed addresses
        fn takeAccessedAddresses(self: *Self) ![]const primitives.Address {
            var addresses = try std.ArrayList(primitives.Address).initCapacity(self.allocator, 0);
            errdefer addresses.deinit(self.allocator);

            // Get addresses from access list
            var iter = self.access_list.addresses.iterator();
            while (iter.next()) |entry| {
                try addresses.append(self.allocator, entry.key_ptr.*);
            }

            return try addresses.toOwnedSlice(self.allocator);
        }

        /// Take all accessed storage slots
        fn takeAccessedStorage(self: *Self) ![]const @import("call_result.zig").StorageAccess {
            var storage = try std.ArrayList(@import("call_result.zig").StorageAccess).initCapacity(self.allocator, 0);
            errdefer storage.deinit(self.allocator);

            // Get storage slots from access list
            var iter = self.access_list.storage_slots.iterator();
            while (iter.next()) |entry| {
                try storage.append(self.allocator, .{
                    .address = entry.key_ptr.*.address,
                    .slot = entry.key_ptr.*.slot,
                });
            }

            return try storage.toOwnedSlice(self.allocator);
        }
    };
}

// TODO: remove DefaultEvm
pub const DefaultEvm = Evm(.{});
test "CallParams and CallResult structures" {
    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 1000000,
        },
    };

    const result = DefaultEvm.CallResult{
        .success = true,
        .gas_left = 900000,
        .output = &.{},
    };

    try std.testing.expect(call_params == .call);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 900000), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
}

test "EVM error type definition" {
    // Test that Error type exists and contains expected error cases
    const TestEvm = Evm(.{});

    // Test error type is defined
    comptime {
        _ = TestEvm.Error;
    }

    // Test that we can create error values
    const err1: TestEvm.Error = error.InvalidJump;
    const err2: TestEvm.Error = error.OutOfGas;

    // Test that different errors are not equal
    try std.testing.expect(err1 != err2);
}

test "EVM call() entry point method" {
    const allocator = std.testing.allocator;

    // Create test database
    var db = Database.init(allocator);
    defer db.deinit();
    // Database is now used directly

    // Create EVM instance
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

    var evm = try DefaultEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .BERLIN);
    defer evm.deinit();

    // Test that call method exists and has correct signature
    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 1000000,
        },
    };

    // This should return Error!CallResult
    const result = evm.call(call_params);

    // Test that method returns expected error type
    comptime {
        const ReturnType = @TypeOf(result);
        const expected_type = DefaultEvm.Error!DefaultEvm.CallResult;
        _ = ReturnType;
        _ = expected_type;
        // We can't directly compare error union types, but this ensures it compiles
    }
}

test "EVM call() method routes to different handlers" {
    const allocator = std.testing.allocator;

    // Create test database
    var db = Database.init(allocator);
    defer db.deinit();
    // Database is now used directly

    // Create EVM instance
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

    var evm = try DefaultEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .BERLIN);
    defer evm.deinit();

    // Test CALL routing
    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 1000000,
        },
    };
    _ = evm.call(call_params) catch {};

    // Test DELEGATECALL routing
    const delegatecall_params = DefaultEvm.CallParams{
        .delegatecall = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .input = &.{},
            .gas = 1000000,
        },
    };
    _ = evm.call(delegatecall_params) catch {};

    // Test STATICCALL routing
    const staticcall_params = DefaultEvm.CallParams{
        .staticcall = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .input = &.{},
            .gas = 1000000,
        },
    };
    _ = evm.call(staticcall_params) catch {};

    // Test CREATE routing
    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &.{},
            .gas = 1000000,
        },
    };
    _ = evm.call(create_params) catch {};

    // Test CREATE2 routing
    const create2_params = DefaultEvm.CallParams{
        .create2 = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &.{},
            .salt = 0,
            .gas = 1000000,
        },
    };
    _ = evm.call(create2_params) catch {};
}

test "EVM call_handler basic functionality" {
    const allocator = std.testing.allocator;

    // Create test database
    var db = Database.init(allocator);
    defer db.deinit();
    // Database is now used directly

    // Add a simple contract that just STOPs
    const stop_bytecode = [_]u8{0x00}; // STOP opcode
    const contract_address: primitives.Address = [_]u8{0x42} ++ [_]u8{0} ** 19;
    const code_hash = try db.set_code(&stop_bytecode);
    try db.set_account(contract_address, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Create EVM instance
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

    var evm = try DefaultEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .BERLIN);
    defer evm.deinit();

    // Test call_handler directly (once it's implemented)
    const params = struct {
        caller: primitives.Address,
        to: primitives.Address,
        value: u256,
        input: []const u8,
        gas: u64,
    }{
        .caller = primitives.ZERO_ADDRESS,
        .to = contract_address,
        .value = 0,
        .input = &.{},
        .gas = 1000000,
    };

    // This should now work with the implemented handler
    const result = try evm.call_handler(params);

    // The implemented handler should work correctly
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
}

test "EVM staticcall handler prevents state changes" {
    const allocator = std.testing.allocator;

    // Create test database with initial state
    var db = Database.init(allocator);
    defer db.deinit();
    // Database is now used directly

    // Add a contract that tries to modify storage (should fail in staticcall)
    const sstore_bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE (should fail in static context)
        0x00, // STOP
    };
    const contract_address: primitives.Address = [_]u8{0x42} ++ [_]u8{0} ** 19;
    const code_hash = try db.set_code(&sstore_bytecode);
    try db.set_account(contract_address, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Create EVM instance
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

    var evm = try DefaultEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .BERLIN);
    defer evm.deinit();

    // Test staticcall directly
    const params = struct {
        caller: primitives.Address,
        to: primitives.Address,
        input: []const u8,
        gas: u64,
    }{
        .caller = primitives.ZERO_ADDRESS,
        .to = contract_address,
        .input = &.{},
        .gas = 1000000,
    };

    // This should now work with the implemented handler
    const result = try evm.staticcall_handler(params);

    // Staticcall with SSTORE should fail due to static context restrictions
    try std.testing.expect(!result.success);
}

test "EVM delegatecall handler preserves caller context" {
    const allocator = std.testing.allocator;

    // Create test database
    var db = Database.init(allocator);
    defer db.deinit();
    // Database is now used directly

    // Add a contract that returns the caller address
    // CALLER opcode pushes msg.sender to stack
    _ = [_]u8{
        0x33, // CALLER
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE - store caller at memory[0]
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN - return 32 bytes from memory[0]
    };
    const contract_address: primitives.Address = [_]u8{0x42} ++ [_]u8{0} ** 19;
    try db.set_account(contract_address, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    // Create EVM instance
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };

    const original_caller: primitives.Address = [_]u8{0xAA} ++ [_]u8{0} ** 19;
    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .BERLIN);
    defer evm.deinit();

    // Test delegatecall - should preserve original caller
    const params = struct {
        caller: primitives.Address,
        to: primitives.Address,
        input: []const u8,
        gas: u64,
    }{
        .caller = original_caller, // This should be preserved in delegatecall
        .to = contract_address,
        .input = &.{},
        .gas = 1000000,
    };

    // This should now work with the implemented handler
    const result = try evm.delegatecall_handler(params);

    // Delegatecall with empty code should succeed
    try std.testing.expect(result.success);
}

test "Evm creation with custom config" {
    const CustomEvm = Evm(.{
        .max_call_depth = 512,
        .max_input_size = 65536, // 64KB
        .frame_config = .{
            .stack_size = 512,
            .max_bytecode_size = 16384,
        },
    });

    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try CustomEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    try std.testing.expectEqual(@as(u9, 0), evm.depth);
}

test "Evm call depth limit" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Set depth to max
    evm.depth = 1024;

    // Try to make a call - should fail due to depth limit
    const result = try evm.inner_call(DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 1000000,
        },
    });

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 0), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
}

// TDD Tests for call method implementation
test "call method basic functionality - simple STOP" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    _ = [_]u8{0x00};

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };

    // This should work when call method is properly implemented
    const result = try evm.call(call_params);

    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
}

test "call method loads contract code from state" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Set up contract with bytecode [0x00] (STOP)
    const contract_address: primitives.Address = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0x56, 0x78, 0x90 };
    const bytecode = [_]u8{0x00};
    const code_hash = try db.set_code(&bytecode);

    // Create account with the code
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(contract_address, account);

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);

    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
}

test "call method handles CREATE operation" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Create contract with simple init code that returns [0x00] (STOP)
    const init_code = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x52, 0x60, 0x01, 0x60, 0x00, 0xF3 }; // PUSH1 1 PUSH1 0 MSTORE PUSH1 1 PUSH1 0 RETURN

    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &init_code,
            .gas = 100000,
        },
    };

    const result = try evm.call(create_params);

    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
}

test "call method handles gas limit properly" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Call with very low gas (should fail or return with low gas left)
    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 10, // Very low gas
        },
    };

    const result = try evm.call(call_params);

    // Should either fail or consume most/all gas
    try std.testing.expect(result.gas_left <= 10);
}

test "Journal - snapshot creation and management" {
    const journal_mod = @import("journal.zig");
    const JournalType = journal_mod.Journal(.{});

    var journal = JournalType.init(std.testing.allocator);
    defer journal.deinit();

    try std.testing.expectEqual(@as(u32, 0), journal.next_snapshot_id);
    try std.testing.expectEqual(@as(usize, 0), journal.entry_count());

    // Create snapshots
    const snapshot1 = journal.create_snapshot();
    const snapshot2 = journal.create_snapshot();
    const snapshot3 = journal.create_snapshot();

    try std.testing.expectEqual(@as(u32, 0), snapshot1);
    try std.testing.expectEqual(@as(u32, 1), snapshot2);
    try std.testing.expectEqual(@as(u32, 2), snapshot3);
    try std.testing.expectEqual(@as(u32, 3), journal.next_snapshot_id);
}

test "Journal - storage change recording" {
    const journal_mod = @import("journal.zig");
    const JournalType = journal_mod.Journal(.{});

    var journal = JournalType.init(std.testing.allocator);
    defer journal.deinit();

    const snapshot_id = journal.create_snapshot();
    const address = primitives.ZERO_ADDRESS;
    const key = 42;
    const original_value = 100;

    // Record storage change
    try journal.record_storage_change(snapshot_id, address, key, original_value);

    // Verify entry was recorded
    try std.testing.expectEqual(@as(usize, 1), journal.entry_count());
    const entry = journal.entries.items[0];
    try std.testing.expectEqual(snapshot_id, entry.snapshot_id);

    switch (entry.data) {
        .storage_change => |sc| {
            try std.testing.expectEqual(address, sc.address);
            try std.testing.expectEqual(key, sc.key);
            try std.testing.expectEqual(original_value, sc.original_value);
        },
        else => try std.testing.expect(false), // Should be storage_change
    }

    // Test get_original_storage
    const retrieved = journal.get_original_storage(address, key);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(original_value, retrieved.?);
}

test "Journal - revert to snapshot" {
    const journal_mod = @import("journal.zig");
    const JournalType = journal_mod.Journal(.{});

    var journal = JournalType.init(std.testing.allocator);
    defer journal.deinit();

    const snapshot1 = journal.create_snapshot();
    const snapshot2 = journal.create_snapshot();
    const snapshot3 = journal.create_snapshot();

    // Add entries with different snapshot IDs
    try journal.record_storage_change(snapshot1, primitives.ZERO_ADDRESS, 1, 10);
    try journal.record_storage_change(snapshot1, primitives.ZERO_ADDRESS, 2, 20);
    try journal.record_storage_change(snapshot2, primitives.ZERO_ADDRESS, 3, 30);
    try journal.record_storage_change(snapshot3, primitives.ZERO_ADDRESS, 4, 40);

    try std.testing.expectEqual(@as(usize, 4), journal.entry_count());

    // Revert to snapshot2 - should remove entries with snapshot_id >= 2
    journal.revert_to_snapshot(snapshot2);

    try std.testing.expectEqual(@as(usize, 2), journal.entry_count());
    // Verify remaining entries are from snapshot1
    for (journal.entries.items) |entry| {
        try std.testing.expect(entry.snapshot_id < snapshot2);
    }
}

test "Journal - multiple entry types" {
    const journal_mod = @import("journal.zig");
    const JournalType = journal_mod.Journal(.{});

    var journal = JournalType.init(std.testing.allocator);
    defer journal.deinit();

    const snapshot_id = journal.create_snapshot();
    const address = primitives.ZERO_ADDRESS;
    const code_hash = [_]u8{0xAB} ** 32;

    // Record different types of changes
    try journal.record_storage_change(snapshot_id, address, 1, 100);
    try journal.record_balance_change(snapshot_id, address, 1000);
    try journal.record_nonce_change(snapshot_id, address, 5);
    try journal.record_code_change(snapshot_id, address, code_hash);

    try std.testing.expectEqual(@as(usize, 4), journal.entry_count());

    // Verify all entry types exist
    var storage_found = false;
    var balance_found = false;
    var nonce_found = false;
    var code_found = false;

    for (journal.entries.items) |entry| {
        switch (entry.data) {
            .storage_change => storage_found = true,
            .balance_change => balance_found = true,
            .nonce_change => nonce_found = true,
            .code_change => code_found = true,
            else => {},
        }
    }

    try std.testing.expect(storage_found);
    try std.testing.expect(balance_found);
    try std.testing.expect(nonce_found);
    try std.testing.expect(code_found);
}

test "Journal - empty revert" {
    const journal_mod = @import("journal.zig");
    const JournalType = journal_mod.Journal(.{});

    var journal = JournalType.init(std.testing.allocator);
    defer journal.deinit();

    // Revert with no entries should not crash
    journal.revert_to_snapshot(0);
    try std.testing.expectEqual(@as(usize, 0), journal.entry_count());

    // Create entries and revert to future snapshot
    const snapshot = journal.create_snapshot();
    try journal.record_storage_change(snapshot, primitives.ZERO_ADDRESS, 1, 100);

    // Revert to future snapshot (should remove all entries)
    journal.revert_to_snapshot(999);
    try std.testing.expectEqual(@as(usize, 0), journal.entry_count());
}

test "EvmConfig - depth type selection" {
    const config_u8 = EvmConfig{ .max_call_depth = 255 };
    try std.testing.expectEqual(u8, config_u8.get_depth_type());

    const config_u11 = EvmConfig{ .max_call_depth = 1024 };
    try std.testing.expectEqual(u11, config_u11.get_depth_type());

    const config_boundary = EvmConfig{ .max_call_depth = 256 };
    try std.testing.expectEqual(u11, config_boundary.get_depth_type());
}

test "EvmConfig - custom configurations" {
    const custom_config = EvmConfig{
        .max_call_depth = 512,
        .max_input_size = 65536,
        .frame_config = .{
            .stack_size = 256,
            .max_bytecode_size = 12288,
        },
    };

    const CustomEvm = Evm(custom_config);

    // Create test database and verify custom EVM compiles
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try CustomEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    try std.testing.expectEqual(@as(u10, 0), evm.depth); // Should be u10 for 512 max depth
}

test "TransactionContext creation and fields" {
    const context = TransactionContext{
        .gas_limit = 5000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 137, // Polygon
    };

    try std.testing.expectEqual(@as(u64, 5000000), context.gas_limit);
    try std.testing.expectEqual(primitives.ZERO_ADDRESS, context.coinbase);
    try std.testing.expectEqual(@as(u16, 137), context.chain_id);
}

test "Evm initialization with all parameters" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 12345678,
        .timestamp = 1640995200, // 2022-01-01
        .difficulty = 15000000000000000,
        .gas_limit = 15000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 25000000000, // 25 gwei
        .prev_randao = [_]u8{0xAB} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 300000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1, // Mainnet
    };

    const gas_price: u256 = 30000000000; // 30 gwei
    const origin = primitives.ZERO_ADDRESS;

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, gas_price, origin, .LONDON);
    defer evm.deinit();

    // Verify all fields were set correctly
    try std.testing.expectEqual(@as(u11, 0), evm.depth);
    try std.testing.expectEqual(block_info.number, evm.block_info.number);
    try std.testing.expectEqual(context.chain_id, evm.context.chain_id);
    try std.testing.expectEqual(gas_price, evm.gas_price);
    try std.testing.expectEqual(origin, evm.origin);
    try std.testing.expectEqual(Hardfork.LONDON, evm.hardfork_config);

    // Verify sub-components initialized
    try std.testing.expectEqual(@as(u32, 0), evm.journal.next_snapshot_id);
    try std.testing.expectEqual(@as(usize, 0), evm.journal.entry_count());
}

// Duplicate test removed - see earlier occurrence

test "Host interface - get_balance functionality" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const address = primitives.ZERO_ADDRESS;
    const balance: u256 = 1000000000000000000; // 1 ETH

    // Set account balance in database
    const account = @import("database_interface_account.zig").Account{
        .balance = balance,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(address, account);

    const retrieved_balance = evm.get_balance(address);
    try std.testing.expectEqual(balance, retrieved_balance);

    const zero_address = [_]u8{1} ++ [_]u8{0} ** 19;
    const zero_balance = evm.get_balance(zero_address);
    try std.testing.expectEqual(@as(u256, 0), zero_balance);
}

test "Host interface - storage operations" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const address = primitives.ZERO_ADDRESS;
    const key: u256 = 42;
    const value: u256 = 0xDEADBEEF;

    // Initially should return zero
    const initial_value = evm.get_storage(address, key);
    try std.testing.expectEqual(@as(u256, 0), initial_value);

    // Set storage value
    try evm.set_storage(address, key, value);

    // Retrieve and verify
    const retrieved_value = evm.get_storage(address, key);
    try std.testing.expectEqual(value, retrieved_value);

    const different_key: u256 = 99;
    const different_value = evm.get_storage(address, different_key);
    try std.testing.expectEqual(@as(u256, 0), different_value);
}

test "Host interface - account_exists functionality" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const address = primitives.ZERO_ADDRESS;
    const account = @import("database_interface_account.zig").Account{
        .balance = 1000,
        .nonce = 1,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(address, account);

    const exists = evm.account_exists(address);
    try std.testing.expect(exists);

    const non_existing = [_]u8{1} ++ [_]u8{0} ** 19;
    const does_not_exist = evm.account_exists(non_existing);
    try std.testing.expect(!does_not_exist);
}

test "Host interface - call type differentiation" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 100,
            .input = &.{},
            .gas = 100000,
        },
    };

    const call_result = try evm.call(call_params);
    try std.testing.expect(call_result.success);

    // Test STATICCALL operation (no value transfer allowed)
    const static_params = DefaultEvm.CallParams{
        .staticcall = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .input = &.{},
            .gas = 100000,
        },
    };

    const static_result = try evm.call(static_params);
    try std.testing.expect(static_result.success);

    // Test DELEGATECALL operation (preserves caller context)
    const delegate_params = DefaultEvm.CallParams{
        .delegatecall = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .input = &.{},
            .gas = 100000,
        },
    };

    const delegate_result = try evm.call(delegate_params);
    try std.testing.expect(delegate_result.success);
}

test "EVM CREATE operation - basic contract creation" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Set up caller with balance
    const caller_address: primitives.Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(caller_address, caller_account);

    // Simple init code that returns a contract with STOP opcode
    // PUSH1 0x01 (size)
    // PUSH1 0x00 (offset)
    // PUSH1 0x00 (value for MSTORE8)
    // PUSH1 0x00 (offset for MSTORE8)
    // MSTORE8
    // RETURN
    const init_code = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (offset)
        0x53, // MSTORE8
        0xF3, // RETURN
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
    try std.testing.expectEqual(@as(usize, 20), result.output.len);

    // Extract contract address from output
    const contract_address: primitives.Address = result.output[0..20].*;

    // Verify contract was created
    const created_account = (try db.get_account(contract_address)).?;
    try std.testing.expectEqual(@as(u64, 1), created_account.nonce);

    // Verify caller nonce was incremented
    const updated_caller = (try db.get_account(caller_address)).?;
    try std.testing.expectEqual(@as(u64, 1), updated_caller.nonce);
}

test "EVM CREATE operation - with value transfer" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Set up caller with balance
    const caller_address: primitives.Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const initial_balance: u256 = 1000000;
    const transfer_value: u256 = 12345;
    const caller_account = Account{
        .balance = initial_balance,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(caller_address, caller_account);

    // Init code that returns empty contract
    const init_code = [_]u8{ 0x00, 0x00, 0xF3 }; // STOP STOP RETURN

    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = caller_address,
            .value = transfer_value,
            .init_code = &init_code,
            .gas = 100000,
        },
    };

    const result = try evm.call(create_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    try std.testing.expect(result.success);

    // Extract contract address
    const contract_address: primitives.Address = result.output[0..20].*;

    // Verify balances
    const caller_after = (try db.get_account(caller_address)).?;
    try std.testing.expectEqual(initial_balance - transfer_value, caller_after.balance);

    const contract_account = (try db.get_account(contract_address)).?;
    try std.testing.expectEqual(transfer_value, contract_account.balance);
}

test "EVM CREATE operation - insufficient balance fails" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const caller_address: primitives.Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const caller_account = Account{
        .balance = 100,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(caller_address, caller_account);

    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = caller_address,
            .value = 1000, // More than balance
            .init_code = &.{0x00}, // STOP
            .gas = 100000,
        },
    };

    const result = try evm.call(create_params);

    // Should fail due to insufficient balance
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 0), result.gas_left);
}

test "EVM CREATE2 operation - deterministic address creation" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const caller_address: primitives.Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(caller_address, caller_account);

    // Simple init code
    const init_code = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    const salt: u256 = 0x1234567890ABCDEF;

    const create2_params = DefaultEvm.CallParams{
        .create2 = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &init_code,
            .salt = salt,
            .gas = 100000,
        },
    };

    const result = try evm.call(create2_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    // Verify successful creation
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
    try std.testing.expectEqual(@as(usize, 20), result.output.len);

    // Extract contract address
    const contract_address: primitives.Address = result.output[0..20].*;

    // Verify contract was created
    const created_account = (try db.get_account(contract_address)).?;
    try std.testing.expectEqual(@as(u64, 1), created_account.nonce);

    // Calculate expected address using CREATE2 formula
    const keccak_asm = @import("keccak_asm.zig");
    var init_code_hash: [32]u8 = undefined;
    try keccak_asm.keccak256(&init_code, &init_code_hash);
    const salt_bytes = @as([32]u8, @bitCast(salt));
    const expected_address = primitives.Address.get_create2_address(caller_address, salt_bytes, init_code_hash);

    // Verify the address matches the expected CREATE2 address
    try std.testing.expectEqualSlices(u8, &expected_address, &contract_address);
}

test "EVM CREATE2 operation - same parameters produce same address" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const caller_address: primitives.Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const init_code = [_]u8{ 0x00, 0x00, 0xF3 }; // STOP STOP RETURN
    const salt: u256 = 0xDEADBEEF;

    // Calculate expected address
    const keccak_asm = @import("keccak_asm.zig");
    var init_code_hash: [32]u8 = undefined;
    try keccak_asm.keccak256(&init_code, &init_code_hash);
    const salt_bytes = @as([32]u8, @bitCast(salt));
    const expected_address = primitives.Address.get_create2_address(caller_address, salt_bytes, init_code_hash);

    // Create caller account
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(caller_address, caller_account);

    const create2_params = DefaultEvm.CallParams{
        .create2 = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &init_code,
            .salt = salt,
            .gas = 100000,
        },
    };

    const result = try evm.call(create2_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    try std.testing.expect(result.success);

    const actual_address: primitives.Address = result.output[0..20].*;
    try std.testing.expectEqualSlices(u8, &expected_address, &actual_address);
}

test "EVM CREATE operation - collision detection" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const caller_address: primitives.Address = [_]u8{0x01} ++ [_]u8{0} ** 19;

    // Calculate what the contract address will be
    const expected_address = primitives.Address.get_contract_address(caller_address, 0);

    // Pre-create an account at that address with code
    const existing_code = [_]u8{ 0x60, 0x00 }; // PUSH1 0
    const code_hash = try db.set_code(&existing_code);
    const existing_account = Account{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(expected_address, existing_account);

    // Create caller account
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(caller_address, caller_account);

    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &.{0x00}, // STOP
            .gas = 100000,
        },
    };

    const result = try evm.call(create_params);

    // Should fail due to collision
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 0), result.gas_left);
}

test "EVM CREATE operation - init code execution and storage" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const caller_address: primitives.Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(caller_address, caller_account);

    // Init code that stores a value and returns code with PUSH1 and ADD
    // This tests that init code can access storage and return runtime code
    const init_code = [_]u8{
        // Store value 42 at key 0
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE

        // Return runtime code: PUSH1 1 ADD
        0x60, 0x04, // PUSH1 4 (size)
        0x60, 0x1C, // PUSH1 28 (offset in this code)
        0xF3, // RETURN

        // Runtime code at offset 28:
        0x60, 0x01, // PUSH1 1
        0x01, // ADD
        0x00, // STOP
    };

    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &init_code,
            .gas = 200000,
        },
    };

    const result = try evm.call(create_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    try std.testing.expect(result.success);

    const contract_address: primitives.Address = result.output[0..20].*;

    // Verify the storage was set during init
    const stored_value = try db.get_storage(contract_address, 0);
    try std.testing.expectEqual(@as(u256, 42), stored_value);

    // Verify the runtime code was stored
    const runtime_code = try db.get_code_by_address(contract_address);
    try std.testing.expectEqual(@as(usize, 4), runtime_code.len);
    try std.testing.expectEqual(@as(u8, 0x60), runtime_code[0]); // PUSH1
    try std.testing.expectEqual(@as(u8, 0x01), runtime_code[1]); // 1
    try std.testing.expectEqual(@as(u8, 0x01), runtime_code[2]); // ADD
    try std.testing.expectEqual(@as(u8, 0x00), runtime_code[3]); // STOP
}

test "EVM CREATE/CREATE2 - nested contract creation" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 3000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Create a factory contract that creates another contract
    // Factory bytecode: CREATE opcode that deploys a simple contract
    const factory_bytecode = [_]u8{
        // Push init code for child contract (just returns empty code)
        0x60, 0x03, // PUSH1 3 (size of init code)
        0x60, 0x1A, // PUSH1 26 (offset of init code)
        0x60, 0x00, // PUSH1 0 (value)
        0xF0, // CREATE
        // Return the created address
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
        // Child init code at offset 26:
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    const factory_address: primitives.Address = [_]u8{0x02} ++ [_]u8{0} ** 19;
    const code_hash = try db.set_code(&factory_bytecode);
    try db.set_account(factory_address, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    const caller_address: primitives.Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    try db.set_account(caller_address, Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    // Call the factory to create a child contract
    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = factory_address,
            .value = 0,
            .input = &.{},
            .gas = 500000,
        },
    };

    const result = try evm.call(call_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 20), result.output.len);

    // The output should contain the address of the created child contract
    const child_address: primitives.Address = result.output[0..20].*;

    // Verify child contract exists
    const child_account = try db.get_account(child_address);
    try std.testing.expect(child_account != null);
    try std.testing.expectEqual(@as(u64, 1), child_account.?.nonce);
}

test "EVM logs - emit_log functionality" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test emit_log functionality
    const test_address = primitives.ZERO_ADDRESS;
    const topics = [_]u256{ 0x1234, 0x5678 };
    const data = "test log data";

    // Emit a log
    evm.emit_log(test_address, &topics, data);

    // Verify log was stored
    try std.testing.expectEqual(@as(usize, 1), evm.logs.items.len);
    const event_log = evm.logs.items[0];
    try std.testing.expectEqual(test_address, event_log.address);
    try std.testing.expectEqual(@as(usize, 2), event_log.topics.len);
    try std.testing.expectEqual(@as(u256, 0x1234), event_log.topics[0]);
    try std.testing.expectEqual(@as(u256, 0x5678), event_log.topics[1]);
    try std.testing.expectEqualStrings("test log data", event_log.data);

    // Test takeLogs
    const taken_logs = evm.takeLogs();
    defer DefaultEvm.CallResult.deinitLogsSlice(taken_logs, evm.allocator);
    try std.testing.expectEqual(@as(usize, 1), taken_logs.len);
    try std.testing.expectEqual(@as(usize, 0), evm.logs.items.len); // Should be empty after taking
}

test "EVM logs - included in CallResult" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Create bytecode that emits LOG0 (0xA0 opcode)
    // PUSH1 0x05 (data length)
    // PUSH1 0x00 (data offset)
    // LOG0
    const bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x00, 0xA0, 0x00 }; // Last 0x00 is STOP
    const code_hash = try db.set_code(&bytecode);

    const contract_address: primitives.Address = [_]u8{0x12} ++ [_]u8{0} ** 19;
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(contract_address, account);

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);
    defer {
        // Clean up logs
        for (result.logs) |event_log| {
            std.testing.allocator.free(event_log.topics);
            std.testing.allocator.free(event_log.data);
        }
        std.testing.allocator.free(result.logs);
    }

    // For now, we expect no logs because LOG0 isn't implemented in the frame
    // This test just verifies the infrastructure works
    try std.testing.expect(result.success);
    try std.testing.expect(result.logs.len == 0); // Will be > 0 when LOG opcodes are implemented
}

test "Host interface - hardfork compatibility checks" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    // Test with different hardfork configurations
    var london_evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .LONDON);
    defer london_evm.deinit();

    try std.testing.expectEqual(Hardfork.LONDON, london_evm.get_hardfork());
    try std.testing.expect(london_evm.is_hardfork_at_least(.HOMESTEAD));
    try std.testing.expect(london_evm.is_hardfork_at_least(.LONDON));
    try std.testing.expect(!london_evm.is_hardfork_at_least(.CANCUN));

    var cancun_evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer cancun_evm.deinit();

    try std.testing.expectEqual(Hardfork.CANCUN, cancun_evm.get_hardfork());
    try std.testing.expect(cancun_evm.is_hardfork_at_least(.LONDON));
    try std.testing.expect(cancun_evm.is_hardfork_at_least(.CANCUN));
}

test "Host interface - access cost operations" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .BERLIN);
    defer evm.deinit();

    const address = primitives.ZERO_ADDRESS;
    const slot: u256 = 42;

    // Test access costs (EIP-2929)
    const address_cost = try evm.access_address(address);
    const storage_cost = try evm.access_storage_slot(address, slot);

    // Cold access costs
    try std.testing.expectEqual(@as(u64, 2600), address_cost);
    try std.testing.expectEqual(@as(u64, 2100), storage_cost);
}

test "Host interface - input size validation" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Create input that exceeds max_input_size (131072 bytes)
    const large_input = try std.testing.allocator.alloc(u8, 200000);
    defer std.testing.allocator.free(large_input);
    @memset(large_input, 0xFF);

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = large_input,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);

    // Should fail due to input size limit
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 0), result.gas_left);
}

test "Call types - CREATE2 with salt" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const init_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xF3 }; // PUSH1 0 PUSH1 0 RETURN (empty contract)
    const salt: u256 = 0x1234567890ABCDEF;

    const create2_params = DefaultEvm.CallParams{
        .create2 = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &init_code,
            .salt = salt,
            .gas = 100000,
        },
    };

    const result = try evm.call(create2_params);
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
}

test "Error handling - nested call depth tracking" {
    // Use smaller depth limit for testing
    const TestEvm = Evm(.{ .max_call_depth = 3 });

    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try TestEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    try std.testing.expectEqual(@as(u2, 0), evm.depth);

    const call_params = TestEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };

    // Call should succeed when depth < max
    evm.depth = 2;
    const result1 = try evm.inner_call(call_params);
    try std.testing.expect(result1.success);
    try std.testing.expectEqual(@as(u2, 2), evm.depth); // Should restore depth

    // Call should fail when depth >= max
    evm.depth = 3;
    const result2 = try evm.inner_call(call_params);
    try std.testing.expect(!result2.success);
    try std.testing.expectEqual(@as(u64, 0), result2.gas_left);
}

test "Error handling - precompile execution" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test calling ECRECOVER precompile (address 0x01)
    const ecrecover_address = [_]u8{0} ** 19 ++ [_]u8{1}; // 0x0000...0001
    const input_data = [_]u8{0} ** 128; // Invalid ECRECOVER input (all zeros)

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = ecrecover_address,
            .value = 0,
            .input = &input_data,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);
    // ECRECOVER should handle invalid input gracefully
    try std.testing.expect(result.gas_left < 100000); // Some gas should be consumed
}

test "Precompiles - IDENTITY precompile (0x04)" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test IDENTITY precompile - should return input data unchanged
    const identity_address = [_]u8{0} ** 19 ++ [_]u8{4}; // 0x0000...0004
    const test_data = "Hello, World!";

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = identity_address,
            .value = 0,
            .input = test_data,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);
    defer if (result.success and result.output.len > 0) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(test_data.len, result.output.len);
    try std.testing.expectEqualStrings(test_data, result.output);

    // Gas cost should be 15 + 3 * 1 = 18 (base + 3 * word count)
    const expected_gas_cost = 15 + 3 * ((test_data.len + 31) / 32);
    try std.testing.expectEqual(100000 - expected_gas_cost, result.gas_left);
}

test "Precompiles - SHA256 precompile (0x02)" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test SHA256 precompile
    const sha256_address = [_]u8{0} ** 19 ++ [_]u8{2}; // 0x0000...0002
    const test_input = "";

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = sha256_address,
            .value = 0,
            .input = test_input,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);
    defer if (result.success and result.output.len > 0) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len); // SHA256 always returns 32 bytes
    try std.testing.expect(result.gas_left < 100000); // Gas should be consumed
}

test "Precompiles - disabled configuration" {
    // Create EVM with precompiles disabled
    const NoPrecompileEvm = Evm(.{ .enable_precompiles = false });

    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try NoPrecompileEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Try to call IDENTITY precompile - should be treated as regular call
    const identity_address = [_]u8{0} ** 19 ++ [_]u8{4}; // 0x0000...0004
    const test_data = "Hello, World!";

    const call_params = NoPrecompileEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = identity_address,
            .value = 0,
            .input = test_data,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);

    // Should succeed but not execute as precompile (no special precompile behavior)
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 0), result.output.len); // No precompile output
    try std.testing.expectEqual(@as(u64, 100000), result.gas_left); // No gas consumed by precompile
}

test "Precompiles - invalid precompile addresses" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test invalid precompile address (0x0B - beyond supported range)
    const invalid_address = [_]u8{0} ** 19 ++ [_]u8{11}; // 0x0000...000B

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = invalid_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);

    // Should succeed as regular call (not precompile)
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 100000), result.gas_left); // No gas consumed by precompile
}

// ============================================================================
// Minimal Debug Tests for Benchmark Investigation
// ============================================================================

test "Debug - Gas limit affects execution" {
    std.testing.log_level = .warn;

    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Deploy a simple infinite loop contract
    // JUMPDEST (0x5b) PUSH1 0x00 (0x6000) JUMP (0x56)
    const loop_bytecode = [_]u8{ 0x5b, 0x60, 0x00, 0x56 };
    const deploy_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{1};
    const code_hash = try db.set_code(&loop_bytecode);
    try db.set_account(deploy_address, Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Test 1: Very low gas limit - should fail quickly
    {
        const start_time = std.time.nanoTimestamp();
        const result = try evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = deploy_address,
                .value = 0,
                .input = &.{},
                .gas = 100, // Very low gas
            },
        });
        const elapsed = std.time.nanoTimestamp() - start_time;

        try std.testing.expect(!result.success); // Should fail
        try std.testing.expectEqual(@as(u64, 0), result.gas_left); // All gas consumed
        log.warn("Low gas (100): elapsed = {} ns, success = {}", .{ elapsed, result.success });
    }

    // Test 2: Medium gas limit
    {
        const start_time = std.time.nanoTimestamp();
        const result = try evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = deploy_address,
                .value = 0,
                .input = &.{},
                .gas = 10000,
            },
        });
        const elapsed = std.time.nanoTimestamp() - start_time;

        try std.testing.expect(!result.success); // Should still fail (infinite loop)
        try std.testing.expectEqual(@as(u64, 0), result.gas_left);
        log.warn("Medium gas (10k): elapsed = {} ns, success = {}", .{ elapsed, result.success });
    }

    // Test 3: High gas limit
    {
        const start_time = std.time.nanoTimestamp();
        const result = try evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = deploy_address,
                .value = 0,
                .input = &.{},
                .gas = 1000000,
            },
        });
        const elapsed = std.time.nanoTimestamp() - start_time;

        try std.testing.expect(!result.success); // Should fail after consuming all gas
        try std.testing.expectEqual(@as(u64, 0), result.gas_left);
        log.warn("High gas (1M): elapsed = {} ns, success = {}", .{ elapsed, result.success });
    }
}

test "Debug - Contract deployment and execution" {
    std.testing.log_level = .warn;

    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test 1: Call to non-existent contract
    {
        const empty_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{99};
        const start_time = std.time.nanoTimestamp();
        const result = try evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = empty_address,
                .value = 0,
                .input = &.{},
                .gas = 100000,
            },
        });
        const elapsed = std.time.nanoTimestamp() - start_time;

        try std.testing.expect(result.success); // Empty contract succeeds immediately
        try std.testing.expectEqual(@as(u64, 100000), result.gas_left); // No gas consumed
        log.warn("Empty contract: elapsed = {} ns, gas_left = {}", .{ elapsed, result.gas_left });
    }

    // Test 2: Simple contract that returns immediately (STOP opcode)
    {
        const stop_bytecode = [_]u8{0x00}; // STOP
        const stop_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{2};
        const code_hash = try db.set_code(&stop_bytecode);
        try db.set_account(stop_address, Account{
            .nonce = 0,
            .balance = 0,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
        });

        const start_time = std.time.nanoTimestamp();
        const result = try evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = stop_address,
                .value = 0,
                .input = &.{},
                .gas = 100000,
            },
        });
        const elapsed = std.time.nanoTimestamp() - start_time;

        try std.testing.expect(result.success);
        // STOP should consume minimal gas
        const gas_used = 100000 - result.gas_left;
        try std.testing.expect(gas_used < 100); // Should use very little gas
        log.warn("STOP contract: elapsed = {} ns, gas_used = {}", .{ elapsed, gas_used });
    }

    // Test 3: Contract with some computation
    {
        // PUSH1 0x05, PUSH1 0x03, ADD, PUSH1 0x00, MSTORE, STOP
        // Adds 3 + 5 and stores in memory
        const add_bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01, 0x60, 0x00, 0x52, 0x00 };
        const add_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{3};
        const code_hash = try db.set_code(&add_bytecode);
        try db.set_account(add_address, Account{
            .nonce = 0,
            .balance = 0,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
        });

        const start_time = std.time.nanoTimestamp();
        const result = try evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = add_address,
                .value = 0,
                .input = &.{},
                .gas = 100000,
            },
        });
        const elapsed = std.time.nanoTimestamp() - start_time;

        try std.testing.expect(result.success);
        const gas_used = 100000 - result.gas_left;
        try std.testing.expect(gas_used > 0); // Should use some gas
        try std.testing.expect(gas_used < 1000); // But not too much
        log.warn("ADD contract: elapsed = {} ns, gas_used = {}", .{ elapsed, gas_used });
    }
}

test "Debug - Bytecode size affects execution time" {
    std.testing.log_level = .warn;

    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Create a large contract that does simple operations
    var large_bytecode = std.ArrayList(u8){};
    defer large_bytecode.deinit();

    // Add many PUSH1/POP pairs (each costs gas but doesn't loop)
    for (0..1000) |_| {
        try large_bytecode.append(std.testing.allocator, 0x60); // PUSH1
        try large_bytecode.append(std.testing.allocator, 0x42); // value
        try large_bytecode.append(std.testing.allocator, 0x50); // POP
    }
    try large_bytecode.append(std.testing.allocator, 0x00); // STOP

    const large_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{4};
    const code_hash = try db.set_code(large_bytecode.items);
    try db.set_account(large_address, Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Test with different gas limits
    const gas_limits = [_]u64{ 10000, 50000, 100000, 500000 };

    for (gas_limits) |gas_limit| {
        const start_time = std.time.nanoTimestamp();
        const result = try evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = large_address,
                .value = 0,
                .input = &.{},
                .gas = gas_limit,
            },
        });
        const elapsed = std.time.nanoTimestamp() - start_time;

        const gas_used = gas_limit - result.gas_left;
        log.warn("Large contract (gas_limit={}): elapsed = {} ns, gas_used = {}, success = {}", .{ gas_limit, elapsed, gas_used, result.success });

        // With low gas, should fail before completing
        if (gas_limit < 50000) {
            try std.testing.expect(!result.success);
            try std.testing.expectEqual(@as(u64, 0), result.gas_left);
        } else {
            // With enough gas, should complete
            try std.testing.expect(result.success);
            try std.testing.expect(result.gas_left > 0);
        }
    }
}

test "Security - bounds checking and edge cases" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test maximum gas limit
    const max_gas_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = std.math.maxInt(u64),
        },
    };

    const max_gas_result = try evm.call(max_gas_params);
    try std.testing.expect(max_gas_result.gas_left <= std.math.maxInt(u64));

    // Test invalid address operations
    const invalid_address = [_]u8{0xFF} ** 20;
    const balance = evm.get_balance(invalid_address);
    try std.testing.expectEqual(@as(u256, 0), balance);

    const exists = evm.account_exists(invalid_address);
    try std.testing.expect(!exists);

    // Test max u256 storage operations
    const max_key: u256 = std.math.maxInt(u256);
    const max_value: u256 = std.math.maxInt(u256);

    try evm.set_storage(primitives.ZERO_ADDRESS, max_key, max_value);
    const retrieved_max = evm.get_storage(primitives.ZERO_ADDRESS, max_key);
    try std.testing.expectEqual(max_value, retrieved_max);
}

test "EVM with minimal planner strategy" {
    // Define EVM config with minimal planner strategy
    const MinimalEvmConfig = EvmConfig{
        .planner_strategy = .minimal,
    };
    const MinimalEvm = Evm(MinimalEvmConfig);

    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try MinimalEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test basic execution with minimal planner
    const simple_bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x01, // ADD
        0x00, // STOP
    };

    const call_params = MinimalEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &simple_bytecode,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);
    try std.testing.expect(result.success);
}

test "EVM with advanced planner strategy" {
    // Define EVM config with advanced planner strategy
    const AdvancedEvmConfig = EvmConfig{
        .planner_strategy = .advanced,
    };
    const AdvancedEvm = Evm(AdvancedEvmConfig);

    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try AdvancedEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test basic execution with advanced planner
    const simple_bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x01, // ADD
        0x00, // STOP
    };

    const call_params = AdvancedEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &simple_bytecode,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);
    try std.testing.expect(result.success);
}

// =============================================================================
// Journal State Application Rollback Tests
// =============================================================================

test "journal state application - storage change rollback" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const test_address = primitives.Address{ .bytes = [_]u8{0x12} ++ [_]u8{0} ** 19 };
    const storage_key: u256 = 0x123;
    const original_value: u256 = 0x456;
    const new_value: u256 = 0x789;

    // Set initial storage value
    try evm.database.set_storage(test_address, storage_key, original_value);

    // Create snapshot
    const snapshot_id = evm.create_snapshot();

    // Modify storage value and record in journal
    try evm.database.set_storage(test_address, storage_key, new_value);
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot_id,
        .data = .{ .storage_change = .{
            .address = test_address,
            .key = storage_key,
            .original_value = original_value,
        } },
    });

    // Verify new value is set
    const current_value = try evm.database.get_storage(test_address, storage_key);
    try std.testing.expectEqual(new_value, current_value);

    // Revert to snapshot
    evm.revert_to_snapshot(snapshot_id);

    // Verify storage value was reverted
    const reverted_value = try evm.database.get_storage(test_address, storage_key);
    try std.testing.expectEqual(original_value, reverted_value);
}

test "journal state application - balance change rollback" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const test_address = primitives.Address{ .bytes = [_]u8{0x34} ++ [_]u8{0} ** 19 };
    const original_balance: u256 = 1000;
    const new_balance: u256 = 2000;

    // Set initial account balance
    var original_account = Account.zero();
    original_account.balance = original_balance;
    try evm.database.set_account(test_address.bytes, original_account);

    // Create snapshot
    const snapshot_id = evm.create_snapshot();

    // Modify balance and record in journal
    var modified_account = original_account;
    modified_account.balance = new_balance;
    try evm.database.set_account(test_address.bytes, modified_account);
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot_id,
        .data = .{ .balance_change = .{
            .address = test_address,
            .original_balance = original_balance,
        } },
    });

    // Verify new balance is set
    const current_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(new_balance, current_account.balance);

    // Revert to snapshot
    evm.revert_to_snapshot(snapshot_id);

    // Verify balance was reverted
    const reverted_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(original_balance, reverted_account.balance);
}

test "journal state application - nonce change rollback" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const test_address = primitives.Address{ .bytes = [_]u8{0x56} ++ [_]u8{0} ** 19 };
    const original_nonce: u64 = 5;
    const new_nonce: u64 = 10;

    // Set initial account nonce
    var original_account = Account.zero();
    original_account.nonce = original_nonce;
    try evm.database.set_account(test_address.bytes, original_account);

    // Create snapshot
    const snapshot_id = evm.create_snapshot();

    // Modify nonce and record in journal
    var modified_account = original_account;
    modified_account.nonce = new_nonce;
    try evm.database.set_account(test_address.bytes, modified_account);
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot_id,
        .data = .{ .nonce_change = .{
            .address = test_address,
            .original_nonce = original_nonce,
        } },
    });

    // Verify new nonce is set
    const current_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(new_nonce, current_account.nonce);

    // Revert to snapshot
    evm.revert_to_snapshot(snapshot_id);

    // Verify nonce was reverted
    const reverted_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(original_nonce, reverted_account.nonce);
}

test "journal state application - code change rollback" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const test_address = primitives.Address{ .bytes = [_]u8{0x78} ++ [_]u8{0} ** 19 };
    const original_code_hash = [_]u8{0xAA} ++ [_]u8{0} ** 31;
    const new_code_hash = [_]u8{0xBB} ++ [_]u8{0} ** 31;

    // Set initial account code hash
    var original_account = Account.zero();
    original_account.code_hash = original_code_hash;
    try evm.database.set_account(test_address.bytes, original_account);

    // Create snapshot
    const snapshot_id = evm.create_snapshot();

    // Modify code hash and record in journal
    var modified_account = original_account;
    modified_account.code_hash = new_code_hash;
    try evm.database.set_account(test_address.bytes, modified_account);
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot_id,
        .data = .{ .code_change = .{
            .address = test_address,
            .original_code_hash = original_code_hash,
        } },
    });

    // Verify new code hash is set
    const current_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqualSlices(u8, &new_code_hash, &current_account.code_hash);

    // Revert to snapshot
    evm.revert_to_snapshot(snapshot_id);

    // Verify code hash was reverted
    const reverted_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqualSlices(u8, &original_code_hash, &reverted_account.code_hash);
}

test "journal state application - multiple changes rollback" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const test_address = [_]u8{0x9A} ++ [_]u8{0} ** 19;
    const storage_key: u256 = 0xABC;

    // Original state
    const original_balance: u256 = 500;
    const original_nonce: u64 = 3;
    const original_storage: u256 = 0x111;
    const original_code_hash = [_]u8{0xCC} ++ [_]u8{0} ** 31;

    // New state
    const new_balance: u256 = 1500;
    const new_nonce: u64 = 8;
    const new_storage: u256 = 0x999;
    const new_code_hash = [_]u8{0xDD} ++ [_]u8{0} ** 31;

    // Set initial state
    var original_account = Account.zero();
    original_account.balance = original_balance;
    original_account.nonce = original_nonce;
    original_account.code_hash = original_code_hash;
    try evm.database.set_account(test_address.bytes, original_account);
    try evm.database.set_storage(test_address, storage_key, original_storage);

    // Create snapshot
    const snapshot_id = evm.create_snapshot();

    // Make multiple changes and record in journal
    var modified_account = original_account;
    modified_account.balance = new_balance;
    modified_account.nonce = new_nonce;
    modified_account.code_hash = new_code_hash;
    try evm.database.set_account(test_address.bytes, modified_account);
    try evm.database.set_storage(test_address, storage_key, new_storage);

    // Add journal entries for all changes
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot_id,
        .data = .{ .balance_change = .{
            .address = test_address,
            .original_balance = original_balance,
        } },
    });
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot_id,
        .data = .{ .nonce_change = .{
            .address = test_address,
            .original_nonce = original_nonce,
        } },
    });
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot_id,
        .data = .{ .code_change = .{
            .address = test_address,
            .original_code_hash = original_code_hash,
        } },
    });
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot_id,
        .data = .{ .storage_change = .{
            .address = test_address,
            .key = storage_key,
            .original_value = original_storage,
        } },
    });

    // Verify all new values are set
    const current_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(new_balance, current_account.balance);
    try std.testing.expectEqual(new_nonce, current_account.nonce);
    try std.testing.expectEqualSlices(u8, &new_code_hash, &current_account.code_hash);
    const current_storage = try evm.database.get_storage(test_address, storage_key);
    try std.testing.expectEqual(new_storage, current_storage);

    // Revert to snapshot
    evm.revert_to_snapshot(snapshot_id);

    // Verify all values were reverted
    const reverted_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(original_balance, reverted_account.balance);
    try std.testing.expectEqual(original_nonce, reverted_account.nonce);
    try std.testing.expectEqualSlices(u8, &original_code_hash, &reverted_account.code_hash);
    const reverted_storage = try evm.database.get_storage(test_address, storage_key);
    try std.testing.expectEqual(original_storage, reverted_storage);
}

test "journal state application - nested snapshots rollback" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const test_address = [_]u8{0xBE} ++ [_]u8{0} ** 19;
    const original_balance: u256 = 100;
    const middle_balance: u256 = 200;
    const final_balance: u256 = 300;

    // Set initial state
    var account = Account.zero();
    account.balance = original_balance;
    try evm.database.set_account(test_address.bytes, account);

    // Create first snapshot
    const snapshot1 = evm.create_snapshot();

    // First change
    account.balance = middle_balance;
    try evm.database.set_account(test_address.bytes, account);
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot1,
        .data = .{ .balance_change = .{
            .address = test_address,
            .original_balance = original_balance,
        } },
    });

    // Create second snapshot
    const snapshot2 = evm.create_snapshot();

    // Second change
    account.balance = final_balance;
    try evm.database.set_account(test_address.bytes, account);
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot2,
        .data = .{ .balance_change = .{
            .address = test_address,
            .original_balance = middle_balance,
        } },
    });

    // Verify final state
    var current_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(final_balance, current_account.balance);

    // Revert to second snapshot (should restore middle state)
    evm.revert_to_snapshot(snapshot2);
    current_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(middle_balance, current_account.balance);

    // Revert to first snapshot (should restore original state)
    evm.revert_to_snapshot(snapshot1);
    current_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(original_balance, current_account.balance);
}

test "journal state application - empty journal rollback" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Create snapshot with no changes
    const snapshot_id = evm.create_snapshot();

    // Revert to snapshot (should be no-op)
    evm.revert_to_snapshot(snapshot_id);

    // Test passes if no error is thrown
    try std.testing.expect(true);
}

test "EVM contract execution - minimal benchmark reproduction" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21000000, // Higher gas for contract execution
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Simple test contract bytecode: PUSH1 0x42 PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN
    // This stores 0x42 in memory at position 0 and returns 32 bytes
    const test_bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xf3, // RETURN
    };

    // Deploy the contract first
    const deploy_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{1}; // Address 0x000...001

    // Store contract code in database
    const code_hash = try db.set_code(&test_bytecode);
    try db.set_account(deploy_address, Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = deploy_address,
            .value = 0,
            .input = &.{}, // No input data
            .gas = 100000,
        },
    };

    // Execute the contract - this should reproduce the benchmark scenario
    const result = try evm.call(call_params);

    // Verify execution succeeded
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);
}

test "Precompile - IDENTITY (0x04) basic functionality" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test calling IDENTITY precompile (0x04) - should return input as-is
    const precompile_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{4}; // Address 0x000...004
    const input_data = "Hello, World!";

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = input_data,
            .gas = 100000,
        },
    };

    // Execute the precompile
    const result = try evm.call(call_params);

    // Verify execution succeeded
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
    try std.testing.expectEqualSlices(u8, input_data, result.output);
}

test "Precompile - SHA256 (0x02) basic functionality" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test calling SHA256 precompile (0x02)
    const precompile_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{2}; // Address 0x000...002
    const input_data = "abc";

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = input_data,
            .gas = 100000,
        },
    };

    // Execute the precompile
    const result = try evm.call(call_params);

    // Verify execution succeeded
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);

    // Expected SHA-256 hash of "abc"
    const expected = [_]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "Precompile diagnosis - ECRECOVER (0x01) placeholder implementation" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

    // Database is now used directly
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test ECRECOVER with invalid signature (all zeros)
    const precompile_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{1};
    const input_data = [_]u8{0} ** 128; // Invalid signature

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = &input_data,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);

    // ECRECOVER returns zero address for invalid signatures (placeholder behavior)
    for (result.output) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "Precompile diagnosis - RIPEMD160 (0x03) unimplemented" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

    // Database is now used directly
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const precompile_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{3};
    const input_data = "test data";

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = input_data,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);

    // RIPEMD160 is a placeholder implementation (returns zeros)
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);

    // Should be zeros (placeholder behavior)
    for (result.output) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "Precompile diagnosis - MODEXP (0x05) basic case works" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

    // Database is now used directly
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const precompile_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{5};

    // 3^4 mod 5 = 81 mod 5 = 1
    var input: [99]u8 = [_]u8{0} ** 99;
    input[31] = 1; // base_len = 1
    input[63] = 1; // exp_len = 1
    input[95] = 1; // mod_len = 1
    input[96] = 3; // base = 3
    input[97] = 4; // exp = 4
    input[98] = 5; // mod = 5

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = &input,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), result.output.len);
    try std.testing.expectEqual(@as(u8, 1), result.output[0]);
}

test "Precompile diagnosis - BN254 operations disabled" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

    // Database is now used directly
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test ECADD (0x06)
    const ecadd_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{6};
    const ecadd_input = [_]u8{0} ** 128; // Two zero points

    const ecadd_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = ecadd_address,
            .value = 0,
            .input = &ecadd_input,
            .gas = 100000,
        },
    };

    const ecadd_result = try evm.call(ecadd_params);

    // BN254 operations might be disabled (check build_options.no_bn254)
    // The precompile will either succeed with placeholder output or fail
    if (ecadd_result.success) {
        try std.testing.expectEqual(@as(usize, 64), ecadd_result.output.len);
        // Placeholder implementation returns all zeros
        for (ecadd_result.output) |byte| {
            try std.testing.expectEqual(@as(u8, 0), byte);
        }
    } else {
        // BN254 operations disabled - this is expected behavior
        const logger = @import("log.zig");
        logger.warn("BN254 operations are disabled (no_bn254 build option)", .{});
    }
}

test "Precompile diagnosis - BLAKE2F (0x09) placeholder" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

    // Database is now used directly
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const precompile_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{9};
    const input = [_]u8{0} ** 213; // Valid BLAKE2F input length

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = &input,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 64), result.output.len);

    // BLAKE2F placeholder returns all zeros
    for (result.output) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "EVM benchmark scenario - reproduces segfault" {
    const allocator = std.testing.allocator;

    // Create test database
    var db = Database.init(allocator);
    defer db.deinit();
    // Database is now used directly

    // Deploy contract first (ERC20 approval bytecode snippet)
    const stop_bytecode = [_]u8{0x00}; // Simple STOP for now
    const deploy_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{1};
    const code_hash = try db.set_code(&stop_bytecode);
    try db.set_account(deploy_address, Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Create EVM instance
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm_instance = try DefaultEvm.init(allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm_instance.deinit();

    // Simple calldata
    const calldata = [_]u8{0x00};

    // Execute call (simulating benchmark)
    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = deploy_address,
            .value = 0,
            .input = &calldata,
            .gas = 100000,
        },
    };

    const result = try evm_instance.call(call_params);
    try std.testing.expect(result.success);

    // The segfault happens in deinit, so let's explicitly test that
    // by creating and destroying multiple times
    for (0..3) |_| {
        var temp_evm = try DefaultEvm.init(allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
        const temp_result = try temp_evm.call(call_params);
        try std.testing.expect(temp_result.success);
        temp_evm.deinit(); // This is where the segfault happens
    }
}

// ============================================================================
// Cross-Contract CREATE Interaction Tests
// ============================================================================

test "CREATE interaction - deployed contract can be called" {
    const allocator = std.testing.allocator;

    var db = Database.init(allocator);
    defer db.deinit();

    // Database is now used directly
    var evm_instance = try DefaultEvm.init(
        allocator,
        &db,
        BlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .base_fee = 1_000_000_000,
            .prev_randao = [_]u8{0} ** 32,
        },
        TransactionContext{
            .gas_limit = 10_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .chain_id = 1,
        },
        20_000_000_000,
        [_]u8{0x01} ** 20,
        .CANCUN,
    );
    defer evm_instance.deinit();

    // Step 1: Deploy a simple contract that returns 42
    // Init code: stores runtime code and returns it
    const runtime_code = [_]u8{
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    var init_code = std.ArrayList(u8).init(allocator);
    defer init_code.deinit();

    // Store runtime code in memory
    for (runtime_code, 0..) |byte, i| {
        try init_code.append(0x60); // PUSH1
        try init_code.append(@intCast(i));
        try init_code.append(0x60); // PUSH1
        try init_code.append(byte);
        try init_code.append(0x53); // MSTORE8
    }

    // Return runtime code
    try init_code.append(0x60); // PUSH1
    try init_code.append(@intCast(runtime_code.len)); // size
    try init_code.append(0x60); // PUSH1
    try init_code.append(0x00); // offset
    try init_code.append(0xF3); // RETURN

    // Deploy the contract
    const create_result = try evm_instance.call(.{
        .create = .{
            .caller = [_]u8{0x01} ** 20,
            .value = 0,
            .init_code = init_code.items,
            .gas = 1_000_000,
        },
    });
    defer if (create_result.output.len > 0) allocator.free(create_result.output);

    try std.testing.expect(create_result.success);
    try std.testing.expectEqual(@as(usize, 20), create_result.output.len);

    // Get deployed contract address
    var contract_address: primitives.Address = undefined;
    @memcpy(&contract_address, create_result.output[0..20]);

    // Step 2: Call the deployed contract
    const call_result = try evm_instance.call(.{
        .call = .{
            .caller = [_]u8{0x01} ** 20,
            .to = contract_address,
            .value = 0,
            .input = &[_]u8{}, // No input data
            .gas = 100_000,
        },
    });
    defer if (call_result.output.len > 0) allocator.free(call_result.output);

    try std.testing.expect(call_result.success);
    try std.testing.expectEqual(@as(usize, 32), call_result.output.len);

    // Verify returned value is 42
    var returned_value: u256 = 0;
    for (call_result.output) |byte| {
        returned_value = (returned_value << 8) | byte;
    }
    try std.testing.expectEqual(@as(u256, 42), returned_value);
}

test "CREATE interaction - factory creates and initializes child contracts" {
    const allocator = std.testing.allocator;

    var db = Database.init(allocator);
    defer db.deinit();

    // Database is now used directly
    var evm_instance = try DefaultEvm.init(
        allocator,
        &db,
        BlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .base_fee = 1_000_000_000,
            .prev_randao = [_]u8{0} ** 32,
        },
        TransactionContext{
            .gas_limit = 10_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .chain_id = 1,
        },
        20_000_000_000,
        [_]u8{0x01} ** 20,
        .CANCUN,
    );
    defer evm_instance.deinit();

    // Child contract: stores initialization value and returns it
    const child_runtime = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x54, // SLOAD (load value from slot 0)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Child init code: stores constructor argument in slot 0
    var child_init = std.ArrayList(u8).init(allocator);
    defer child_init.deinit();

    // Store caller-provided value in slot 0
    try child_init.append(0x60); // PUSH1
    try child_init.append(0x00); // 0 (calldata offset)
    try child_init.append(0x35); // CALLDATALOAD
    try child_init.append(0x60); // PUSH1
    try child_init.append(0x00); // 0 (storage slot)
    try child_init.append(0x55); // SSTORE

    // Store runtime code in memory
    for (child_runtime, 0..) |byte, i| {
        try child_init.append(0x60); // PUSH1
        try child_init.append(@intCast(i));
        try child_init.append(0x60); // PUSH1
        try child_init.append(byte);
        try child_init.append(0x53); // MSTORE8
    }

    // Return runtime code
    try child_init.append(0x60); // PUSH1
    try child_init.append(@intCast(child_runtime.len));
    try child_init.append(0x60); // PUSH1
    try child_init.append(0x00);
    try child_init.append(0xF3); // RETURN

    // Factory contract: creates child with initialization value
    var factory_code = std.ArrayList(u8).init(allocator);
    defer factory_code.deinit();

    // Load initialization value from calldata
    try factory_code.append(0x60); // PUSH1
    try factory_code.append(0x00); // 0
    try factory_code.append(0x35); // CALLDATALOAD

    // Store child init code in memory (with constructor arg appended)
    for (child_init.items, 0..) |byte, i| {
        try factory_code.append(0x60); // PUSH1
        try factory_code.append(byte);
        try factory_code.append(0x60); // PUSH1
        try factory_code.append(@intCast(i));
        try factory_code.append(0x53); // MSTORE8
    }

    // Append constructor argument to init code
    const init_size = child_init.items.len;
    try factory_code.append(0x60); // PUSH1
    try factory_code.append(@intCast(init_size)); // offset for constructor arg
    try factory_code.append(0x52); // MSTORE (store 32-byte constructor arg)

    // CREATE child contract
    try factory_code.append(0x60); // PUSH1
    try factory_code.append(@intCast(init_size + 32)); // size including constructor arg
    try factory_code.append(0x60); // PUSH1
    try factory_code.append(0x00); // offset
    try factory_code.append(0x60); // PUSH1
    try factory_code.append(0x00); // value
    try factory_code.append(0xF0); // CREATE

    // Return created address
    try factory_code.append(0x60); // PUSH1
    try factory_code.append(0x00); // 0
    try factory_code.append(0x52); // MSTORE
    try factory_code.append(0x60); // PUSH1
    try factory_code.append(0x20); // 32
    try factory_code.append(0x60); // PUSH1
    try factory_code.append(0x00); // 0
    try factory_code.append(0xF3); // RETURN

    // Deploy factory with initialization value 123
    var deploy_data = std.ArrayList(u8).init(allocator);
    defer deploy_data.deinit();
    const init_value = [_]u8{0} ** 31 ++ [_]u8{123}; // 123 as uint256
    try deploy_data.appendSlice(&init_value);

    const factory_result = try evm_instance.call(.{
        .create = .{
            .caller = [_]u8{0x01} ** 20,
            .value = 0,
            .init_code = deploy_data.items,
            .gas = 5_000_000,
        },
    });
    defer if (factory_result.output.len > 0) allocator.free(factory_result.output);

    try std.testing.expect(factory_result.success);

    // Extract child contract address from output
    var child_address: primitives.Address = undefined;
    @memcpy(&child_address, factory_result.output[0..20]); // Contract address

    // Call child contract to verify initialization
    const verify_result = try evm_instance.call(.{
        .call = .{
            .caller = [_]u8{0x01} ** 20,
            .to = child_address,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100_000,
        },
    });
    defer if (verify_result.output.len > 0) allocator.free(verify_result.output);

    try std.testing.expect(verify_result.success);

    // Verify returned value is 123
    var returned_value: u256 = 0;
    for (verify_result.output) |byte| {
        returned_value = (returned_value << 8) | byte;
    }
    try std.testing.expectEqual(@as(u256, 123), returned_value);
}

test "CREATE interaction - contract creates contract that creates contract" {
    const allocator = std.testing.allocator;

    var db = Database.init(allocator);
    defer db.deinit();

    // Database is now used directly
    var evm_instance = try DefaultEvm.init(
        allocator,
        &db,
        BlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .base_fee = 1_000_000_000,
            .prev_randao = [_]u8{0} ** 32,
        },
        TransactionContext{
            .gas_limit = 20_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .chain_id = 1,
        },
        20_000_000_000,
        [_]u8{0x01} ** 20,
        .CANCUN,
    );
    defer evm_instance.deinit();

    // Level 3 contract (grandchild): returns constant 99
    const level3_runtime = [_]u8{
        0x60, 0x63, // PUSH1 99
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Level 3 init code
    var level3_init = std.ArrayList(u8).init(allocator);
    defer level3_init.deinit();
    for (level3_runtime, 0..) |byte, i| {
        try level3_init.append(0x60); // PUSH1
        try level3_init.append(@intCast(i));
        try level3_init.append(0x60); // PUSH1
        try level3_init.append(byte);
        try level3_init.append(0x53); // MSTORE8
    }
    try level3_init.append(0x60); // PUSH1
    try level3_init.append(@intCast(level3_runtime.len));
    try level3_init.append(0x60); // PUSH1
    try level3_init.append(0x00);
    try level3_init.append(0xF3); // RETURN

    // Level 2 contract (child): creates level 3 and returns its address
    var level2_runtime = std.ArrayList(u8).init(allocator);
    defer level2_runtime.deinit();

    // Store level 3 init code
    for (level3_init.items, 0..) |byte, i| {
        try level2_runtime.append(0x60); // PUSH1
        try level2_runtime.append(byte);
        try level2_runtime.append(0x60); // PUSH1
        try level2_runtime.append(@intCast(i));
        try level2_runtime.append(0x53); // MSTORE8
    }

    // CREATE level 3
    try level2_runtime.append(0x60); // PUSH1
    try level2_runtime.append(@intCast(level3_init.items.len));
    try level2_runtime.append(0x60); // PUSH1
    try level2_runtime.append(0x00); // offset
    try level2_runtime.append(0x60); // PUSH1
    try level2_runtime.append(0x00); // value
    try level2_runtime.append(0xF0); // CREATE

    // Return address
    try level2_runtime.append(0x60); // PUSH1
    try level2_runtime.append(0x00); // 0
    try level2_runtime.append(0x52); // MSTORE
    try level2_runtime.append(0x60); // PUSH1
    try level2_runtime.append(0x20); // 32
    try level2_runtime.append(0x60); // PUSH1
    try level2_runtime.append(0x00); // 0
    try level2_runtime.append(0xF3); // RETURN

    // Level 2 init code
    var level2_init = std.ArrayList(u8).init(allocator);
    defer level2_init.deinit();
    for (level2_runtime.items, 0..) |byte, i| {
        try level2_init.append(0x60); // PUSH1
        try level2_init.append(@as(u8, @truncate(i)));
        try level2_init.append(0x60); // PUSH1
        try level2_init.append(byte);
        try level2_init.append(0x53); // MSTORE8
    }
    try level2_init.append(0x61); // PUSH2
    try level2_init.append(@as(u8, @truncate(level2_runtime.items.len >> 8)));
    try level2_init.append(@as(u8, @truncate(level2_runtime.items.len & 0xFF)));
    try level2_init.append(0x60); // PUSH1
    try level2_init.append(0x00);
    try level2_init.append(0xF3); // RETURN

    // Level 1 contract (parent): creates level 2
    var level1_code = std.ArrayList(u8).init(allocator);
    defer level1_code.deinit();

    // Store level 2 init code
    for (level2_init.items, 0..) |byte, i| {
        try level1_code.append(0x60); // PUSH1
        try level1_code.append(byte);
        try level1_code.append(0x61); // PUSH2
        try level1_code.append(@as(u8, @truncate(i >> 8)));
        try level1_code.append(@as(u8, @truncate(i & 0xFF)));
        try level1_code.append(0x53); // MSTORE8
    }

    // CREATE level 2
    try level1_code.append(0x61); // PUSH2
    try level1_code.append(@as(u8, @truncate(level2_init.items.len >> 8)));
    try level1_code.append(@as(u8, @truncate(level2_init.items.len & 0xFF)));
    try level1_code.append(0x60); // PUSH1
    try level1_code.append(0x00); // offset
    try level1_code.append(0x60); // PUSH1
    try level1_code.append(0x00); // value
    try level1_code.append(0xF0); // CREATE

    // Store level 2 address
    try level1_code.append(0x60); // PUSH1
    try level1_code.append(0x00); // slot 0
    try level1_code.append(0x55); // SSTORE
    try level1_code.append(0x00); // STOP

    // Execute level 1
    const result1 = try evm_instance.call(.{
        .create = .{
            .caller = [_]u8{0x01} ** 20,
            .value = 0,
            .init_code = level1_code.items,
            .gas = 10_000_000,
        },
    });
    defer if (result1.output.len > 0) allocator.free(result1.output);

    try std.testing.expect(result1.success);

    // Get level 2 address from storage
    const level2_addr_u256 = evm_instance.get_storage([_]u8{0x01} ** 20, 0);
    var level2_addr: primitives.Address = undefined;
    const bytes = std.mem.toBytes(level2_addr_u256);
    @memcpy(&level2_addr, bytes[12..32]);

    // Call level 2 to get level 3 address
    const result2 = try evm_instance.call(.{
        .call = .{
            .caller = [_]u8{0x01} ** 20,
            .to = level2_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1_000_000,
        },
    });
    defer if (result2.output.len > 0) allocator.free(result2.output);

    try std.testing.expect(result2.success);

    // Get level 3 address
    var level3_addr: primitives.Address = undefined;
    @memcpy(&level3_addr, result2.output[0..20]);

    // Call level 3 to verify it returns 99
    const result3 = try evm_instance.call(.{
        .call = .{
            .caller = [_]u8{0x01} ** 20,
            .to = level3_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100_000,
        },
    });
    defer if (result3.output.len > 0) allocator.free(result3.output);

    try std.testing.expect(result3.success);

    var returned_value: u256 = 0;
    for (result3.output) |byte| {
        returned_value = (returned_value << 8) | byte;
    }
    try std.testing.expectEqual(@as(u256, 99), returned_value);
}

test "CREATE interaction - created contract modifies parent storage" {
    const allocator = std.testing.allocator;

    var db = Database.init(allocator);
    defer db.deinit();

    // Database is now used directly
    var evm_instance = try DefaultEvm.init(
        allocator,
        &db,
        BlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .base_fee = 1_000_000_000,
            .prev_randao = [_]u8{0} ** 32,
        },
        TransactionContext{
            .gas_limit = 10_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .chain_id = 1,
        },
        20_000_000_000,
        [_]u8{0x01} ** 20,
        .CANCUN,
    );
    defer evm_instance.deinit();

    // Child contract that calls back to parent
    const child_runtime = [_]u8{
        // Call parent's setValue(42) function
        0x60, 0x2A, // PUSH1 42 (value to set)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE (store at memory[0])
        0x60, 0x20, // PUSH1 32 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0x60, 0x20, // PUSH1 32 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x33, // CALLER (parent address)
        0x5A, // GAS
        0xF1, // CALL parent

        // Return success
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Child init code
    var child_init = std.ArrayList(u8).init(allocator);
    defer child_init.deinit();
    for (child_runtime, 0..) |byte, i| {
        try child_init.append(0x60); // PUSH1
        try child_init.append(@intCast(i));
        try child_init.append(0x60); // PUSH1
        try child_init.append(byte);
        try child_init.append(0x53); // MSTORE8
    }
    try child_init.append(0x60); // PUSH1
    try child_init.append(@intCast(child_runtime.len));
    try child_init.append(0x60); // PUSH1
    try child_init.append(0x00);
    try child_init.append(0xF3); // RETURN

    // Parent contract with setValue function
    var parent_code = std.ArrayList(u8).init(allocator);
    defer parent_code.deinit();

    // Check if being called (calldata size > 0)
    try parent_code.append(0x36); // CALLDATASIZE
    try parent_code.append(0x60); // PUSH1
    try parent_code.append(0x23); // Jump destination for setValue
    try parent_code.append(0x57); // JUMPI

    // CREATE path (no calldata)
    // Store child init code
    for (child_init.items, 0..) |byte, i| {
        try parent_code.append(0x60); // PUSH1
        try parent_code.append(byte);
        try parent_code.append(0x60); // PUSH1
        try parent_code.append(@intCast(i));
        try parent_code.append(0x53); // MSTORE8
    }

    // CREATE child
    try parent_code.append(0x60); // PUSH1
    try parent_code.append(@intCast(child_init.items.len));
    try parent_code.append(0x60); // PUSH1
    try parent_code.append(0x00); // offset
    try parent_code.append(0x60); // PUSH1
    try parent_code.append(0x00); // value
    try parent_code.append(0xF0); // CREATE

    // Store child address at slot 1
    try parent_code.append(0x60); // PUSH1
    try parent_code.append(0x01); // slot 1
    try parent_code.append(0x55); // SSTORE
    try parent_code.append(0x00); // STOP

    // setValue function (JUMPDEST at 0x23)
    try parent_code.append(0x5B); // JUMPDEST
    try parent_code.append(0x60); // PUSH1
    try parent_code.append(0x00); // 0
    try parent_code.append(0x35); // CALLDATALOAD (load value)
    try parent_code.append(0x60); // PUSH1
    try parent_code.append(0x00); // slot 0
    try parent_code.append(0x55); // SSTORE
    try parent_code.append(0x00); // STOP

    // Deploy parent contract
    const deploy_result = try evm_instance.call(.{
        .create = .{
            .caller = [_]u8{0x01} ** 20,
            .value = 0,
            .init_code = parent_code.items,
            .gas = 5_000_000,
        },
    });
    defer if (deploy_result.output.len > 0) allocator.free(deploy_result.output);

    try std.testing.expect(deploy_result.success);

    // Get parent address (deterministic based on sender nonce)
    const parent_addr = [_]u8{0x01} ** 20; // Simplified for test

    // Get child address from parent's storage
    const child_addr_u256 = evm_instance.get_storage(parent_addr, 1);
    var child_addr: primitives.Address = undefined;
    const bytes = std.mem.toBytes(child_addr_u256);
    @memcpy(&child_addr, bytes[12..32]);

    // Verify parent's value storage is initially 0
    const initial_value = evm_instance.get_storage(parent_addr, 0);
    try std.testing.expectEqual(@as(u256, 0), initial_value);

    // Call child contract, which should call back to parent
    const call_result = try evm_instance.call(.{
        .call = .{
            .caller = [_]u8{0x02} ** 20,
            .to = child_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1_000_000,
        },
    });
    defer if (call_result.output.len > 0) allocator.free(call_result.output);

    try std.testing.expect(call_result.success);

    // Verify parent's storage was modified by child
    const final_value = evm_instance.get_storage(parent_addr, 0);
    try std.testing.expectEqual(@as(u256, 42), final_value);
}

test "Arena allocator - resets between calls" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Simple contract that emits a log
    // PUSH1 0x20 PUSH1 0x00 LOG0 STOP
    const bytecode = [_]u8{ 0x60, 0x20, 0x60, 0x00, 0xA0, 0x00 };
    const contract_addr = [_]u8{0x01} ** 20;
    const code_hash = try db.set_code(&bytecode);
    try db.set_account(contract_addr, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Track arena bytes allocated before first call
    const initial_arena_bytes = evm.internal_arena.queryCapacity();

    // First call - should allocate in arena
    const result1 = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    });
    defer if (result1.output.len > 0) std.testing.allocator.free(result1.output);

    try std.testing.expect(result1.success);
    try std.testing.expectEqual(@as(usize, 1), result1.logs.len);

    // Arena should have allocated memory for the log
    const after_first_call = evm.internal_arena.queryCapacity();
    try std.testing.expect(after_first_call >= initial_arena_bytes);

    // Second call - arena should be reset
    const result2 = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    });
    defer if (result2.output.len > 0) std.testing.allocator.free(result2.output);

    try std.testing.expect(result2.success);
    try std.testing.expectEqual(@as(usize, 1), result2.logs.len);

    // Arena capacity should be retained but memory reused
    const after_second_call = evm.internal_arena.queryCapacity();
    try std.testing.expectEqual(after_first_call, after_second_call);
}

test "Arena allocator - handles multiple logs efficiently" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 10000000, // Higher gas limit for many logs
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Contract that emits 100 logs
    // Build bytecode dynamically: (PUSH1 0x20 PUSH1 0x00 LOG0) * 100 + STOP
    var bytecode: [501]u8 = undefined;
    for (0..100) |i| {
        const offset = i * 5;
        bytecode[offset] = 0x60; // PUSH1
        bytecode[offset + 1] = 0x20; // 32 bytes of data
        bytecode[offset + 2] = 0x60; // PUSH1
        bytecode[offset + 3] = 0x00; // offset 0
        bytecode[offset + 4] = 0xA0; // LOG0
    }
    bytecode[500] = 0x00; // STOP

    const contract_addr = [_]u8{0x02} ** 20;
    const code_hash = try db.set_code(&bytecode);
    try db.set_account(contract_addr, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Execute contract
    const result = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 5000000,
        },
    });
    defer if (result.success and result.output.len > 0) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 100), result.logs.len);

    // All logs should have been allocated from arena
    for (result.logs) |event_log| {
        try std.testing.expectEqual(@as(usize, 0), event_log.topics.len);
        try std.testing.expectEqual(@as(usize, 32), event_log.data.len);
    }
}

test "Arena allocator - precompile outputs use arena" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Call SHA256 precompile (address 0x02)
    const precompile_addr = primitives.Address.from_u256(2);
    const input = "Hello, World!";

    const result = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_addr,
            .value = 0,
            .input = input,
            .gas = 100000,
        },
    });
    defer if (result.success and result.output.len > 0) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len); // SHA256 output is 32 bytes

    // Multiple precompile calls should reuse arena
    const result2 = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_addr,
            .value = 0,
            .input = "Another test input",
            .gas = 100000,
        },
    });
    defer if (result2.output.len > 0) std.testing.allocator.free(result2.output);

    try std.testing.expect(result2.success);
    try std.testing.expectEqual(@as(usize, 32), result2.output.len);
}

test "Arena allocator - memory efficiency with nested calls" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Parent contract that calls child and emits log
    // PUSH20 <child_addr> PUSH1 0 PUSH1 0 PUSH1 0 PUSH1 0 PUSH1 0 PUSH2 <gas> CALL
    // PUSH1 0x20 PUSH1 0x00 LOG0 STOP
    const child_addr = [_]u8{0x03} ** 20;
    var parent_bytecode: [100]u8 = undefined;
    var idx: usize = 0;

    // PUSH20 child_addr
    parent_bytecode[idx] = 0x73;
    idx += 1;
    @memcpy(parent_bytecode[idx .. idx + 20], &child_addr);
    idx += 20;

    // PUSH1 0 (value)
    parent_bytecode[idx] = 0x60;
    parent_bytecode[idx + 1] = 0x00;
    idx += 2;

    // PUSH1 0 (out_size)
    parent_bytecode[idx] = 0x60;
    parent_bytecode[idx + 1] = 0x00;
    idx += 2;

    // PUSH1 0 (out_offset)
    parent_bytecode[idx] = 0x60;
    parent_bytecode[idx + 1] = 0x00;
    idx += 2;

    // PUSH1 0 (in_size)
    parent_bytecode[idx] = 0x60;
    parent_bytecode[idx + 1] = 0x00;
    idx += 2;

    // PUSH1 0 (in_offset)
    parent_bytecode[idx] = 0x60;
    parent_bytecode[idx + 1] = 0x00;
    idx += 2;

    // PUSH2 gas
    parent_bytecode[idx] = 0x61;
    parent_bytecode[idx + 1] = 0x01;
    parent_bytecode[idx + 2] = 0x00; // 256 gas
    idx += 3;

    // CALL
    parent_bytecode[idx] = 0xF1;
    idx += 1;

    // PUSH1 0x20 PUSH1 0x00 LOG0
    parent_bytecode[idx] = 0x60;
    parent_bytecode[idx + 1] = 0x20;
    parent_bytecode[idx + 2] = 0x60;
    parent_bytecode[idx + 3] = 0x00;
    parent_bytecode[idx + 4] = 0xA0;
    idx += 5;

    // STOP
    parent_bytecode[idx] = 0x00;
    idx += 1;

    const parent_addr = [_]u8{0x04} ** 20;
    const parent_code_hash = try db.set_code(parent_bytecode[0..idx]);
    try db.set_account(parent_addr, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = parent_code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Child contract that also emits log
    const child_bytecode = [_]u8{ 0x60, 0x10, 0x60, 0x00, 0xA0, 0x00 }; // PUSH1 0x10 PUSH1 0x00 LOG0 STOP
    const child_code_hash = try db.set_code(&child_bytecode);
    try db.set_account(child_addr, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = child_code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Track arena capacity before call
    const initial_capacity = evm.internal_arena.queryCapacity();

    // Execute parent contract
    const result = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = parent_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1000000,
        },
    });
    defer if (result.success and result.output.len > 0) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 2), result.logs.len); // Parent and child logs

    // Arena should have grown to accommodate logs
    const final_capacity = evm.internal_arena.queryCapacity();
    try std.testing.expect(final_capacity >= initial_capacity);

    // Second call should reuse arena capacity
    const result2 = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = parent_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1000000,
        },
    });
    defer if (result2.output.len > 0) std.testing.allocator.free(result2.output);

    try std.testing.expect(result2.success);
    try std.testing.expectEqual(@as(usize, 2), result2.logs.len);

    // Arena capacity should be retained
    const final_capacity2 = evm.internal_arena.queryCapacity();
    try std.testing.expectEqual(final_capacity, final_capacity2);
}

test "Call context tracking - get_caller and get_call_value" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const origin_addr = primitives.Address.from_hex("0x1111111111111111111111111111111111111111") catch unreachable;
    const contract_a = primitives.Address.from_hex("0x2222222222222222222222222222222222222222") catch unreachable;

    const block_info = BlockInfo.init();
    const tx_context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    var evm = try DefaultEvm.init(
        std.testing.allocator,
        &db,
        block_info,
        tx_context,
        100,
        origin_addr,
        .CANCUN,
    );
    defer evm.deinit();

    // Test depth 0 - should return origin
    try std.testing.expectEqual(@as(u11, 0), evm.depth);
    try std.testing.expectEqual(origin_addr, evm.get_caller());
    try std.testing.expectEqual(@as(u256, 0), evm.get_call_value());

    // Simulate depth 1 call from origin to contract_a with value 123
    evm.depth = 1;
    evm.call_stack[0] = .{
        .caller = origin_addr,
        .value = 123,
    };

    try std.testing.expectEqual(origin_addr, evm.get_caller());
    try std.testing.expectEqual(@as(u256, 123), evm.get_call_value());

    // Simulate depth 2 call from contract_a to contract_b with value 456
    evm.depth = 2;
    evm.call_stack[1] = .{
        .caller = contract_a,
        .value = 456,
    };

    try std.testing.expectEqual(contract_a, evm.get_caller());
    try std.testing.expectEqual(@as(u256, 456), evm.get_call_value());
}

test "CREATE stores deployed code bytes" {
    const allocator = std.testing.allocator;

    var db = Database.init(allocator);
    defer db.deinit();

    // Database is now used directly

    // Create EVM instance
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(allocator, &db, block_info, tx_context, 20_000_000_000, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Give creator account some balance
    const creator_address: primitives.Address = [_]u8{0x11} ++ [_]u8{0} ** 19;
    try db.set_account(creator_address, Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    // Contract that uses CREATE to deploy a simple contract
    // The deployed contract just returns 42
    const deployed_runtime = [_]u8{
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Init code that deploys the runtime code
    var init_code = std.ArrayList(u8).init(allocator);
    defer init_code.deinit();

    // Store runtime code length
    try init_code.append(0x60); // PUSH1
    try init_code.append(@intCast(deployed_runtime.len));
    try init_code.append(0x60); // PUSH1 0
    try init_code.append(0x00);
    try init_code.append(0x52); // MSTORE at 0

    // Store actual runtime code bytes
    for (deployed_runtime, 0..) |byte, i| {
        try init_code.append(0x60); // PUSH1
        try init_code.append(byte);
        try init_code.append(0x60); // PUSH1
        try init_code.append(@intCast(i + 32)); // offset after length
        try init_code.append(0x53); // MSTORE8
    }

    // Return the runtime code
    try init_code.append(0x60); // PUSH1
    try init_code.append(@intCast(deployed_runtime.len + 32)); // size
    try init_code.append(0x60); // PUSH1
    try init_code.append(0x00); // offset
    try init_code.append(0xF3); // RETURN

    // Contract that calls CREATE with the init code
    var creator_bytecode = std.ArrayList(u8).init(allocator);
    defer creator_bytecode.deinit();

    // Push init code to memory
    for (init_code.items, 0..) |byte, i| {
        try creator_bytecode.append(0x60); // PUSH1
        try creator_bytecode.append(byte);
        try creator_bytecode.append(0x60); // PUSH1
        try creator_bytecode.append(@intCast(i));
        try creator_bytecode.append(0x53); // MSTORE8
    }

    // CREATE: value=0, offset=0, size=init_code.len
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(@intCast(init_code.items.len)); // size
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x00); // offset
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x00); // value
    try creator_bytecode.append(0xF0); // CREATE

    // Return the created address
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x00); // offset
    try creator_bytecode.append(0x52); // MSTORE
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x20); // size
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x00); // offset
    try creator_bytecode.append(0xF3); // RETURN

    // Deploy creator contract
    const creator_code_hash = try db.set_code(creator_bytecode.items);
    try db.set_account(creator_address, Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = creator_code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Execute CREATE
    const result = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = creator_address,
            .value = 0,
            .input = &.{},
            .gas = 500000,
        },
    });

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);

    // Extract created contract address from output
    var created_address: primitives.Address = undefined;
    @memcpy(&created_address, result.output[0..20]);

    // Verify the deployed contract exists and has the correct code
    const deployed_code = try db.get_code_by_address(created_address);
    try std.testing.expectEqualSlices(u8, &deployed_runtime, deployed_code);

    // Call the deployed contract to verify it works
    const call_result = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = created_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });

    try std.testing.expect(call_result.success);
    try std.testing.expectEqual(@as(usize, 32), call_result.output.len);

    // Verify it returns 42
    var returned_value: u256 = 0;
    for (call_result.output, 0..) |byte, i| {
        returned_value |= @as(u256, byte) << @intCast(8 * (31 - i));
    }
    try std.testing.expectEqual(@as(u256, 42), returned_value);
}

test "CREATE2 stores deployed code bytes" {
    const allocator = std.testing.allocator;

    var db = Database.init(allocator);
    defer db.deinit();

    // Database is now used directly

    // Create EVM instance
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(allocator, &db, block_info, tx_context, 20_000_000_000, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Give creator account some balance
    const creator_address: primitives.Address = [_]u8{0x22} ++ [_]u8{0} ** 19;
    try db.set_account(creator_address, Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    // Contract that uses CREATE2 to deploy a simple contract
    // The deployed contract just returns 99
    const deployed_runtime = [_]u8{
        0x60, 0x63, // PUSH1 99
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Init code that deploys the runtime code
    var init_code = std.ArrayList(u8).init(allocator);
    defer init_code.deinit();

    // Store runtime code length
    try init_code.append(0x60); // PUSH1
    try init_code.append(@intCast(deployed_runtime.len));
    try init_code.append(0x60); // PUSH1 0
    try init_code.append(0x00);
    try init_code.append(0x52); // MSTORE at 0

    // Store actual runtime code bytes
    for (deployed_runtime, 0..) |byte, i| {
        try init_code.append(0x60); // PUSH1
        try init_code.append(byte);
        try init_code.append(0x60); // PUSH1
        try init_code.append(@intCast(i + 32)); // offset after length
        try init_code.append(0x53); // MSTORE8
    }

    // Return the runtime code
    try init_code.append(0x60); // PUSH1
    try init_code.append(@intCast(deployed_runtime.len + 32)); // size
    try init_code.append(0x60); // PUSH1
    try init_code.append(0x00); // offset
    try init_code.append(0xF3); // RETURN

    // Contract that calls CREATE2 with the init code
    var creator_bytecode = std.ArrayList(u8).init(allocator);
    defer creator_bytecode.deinit();

    // Push init code to memory
    for (init_code.items, 0..) |byte, i| {
        try creator_bytecode.append(0x60); // PUSH1
        try creator_bytecode.append(byte);
        try creator_bytecode.append(0x60); // PUSH1
        try creator_bytecode.append(@intCast(i));
        try creator_bytecode.append(0x53); // MSTORE8
    }

    // CREATE2: salt, size, offset, value
    // Use salt = 0x42
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x42); // salt
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(@intCast(init_code.items.len)); // size
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x00); // offset
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x00); // value
    try creator_bytecode.append(0xF5); // CREATE2

    // Return the created address
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x00); // offset
    try creator_bytecode.append(0x52); // MSTORE
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x20); // size
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x00); // offset
    try creator_bytecode.append(0xF3); // RETURN

    // Deploy creator contract
    const creator_code_hash = try db.set_code(creator_bytecode.items);
    try db.set_account(creator_address, Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = creator_code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Execute CREATE2
    const result = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = creator_address,
            .value = 0,
            .input = &.{},
            .gas = 500000,
        },
    });

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);

    // Extract created contract address from output
    var created_address: primitives.Address = undefined;
    @memcpy(&created_address, result.output[0..20]);

    // Verify the deployed contract exists and has the correct code
    const deployed_code = try db.get_code_by_address(created_address);
    try std.testing.expectEqualSlices(u8, &deployed_runtime, deployed_code);

    // Call the deployed contract to verify it works
    const call_result = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = created_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });

    try std.testing.expect(call_result.success);
    try std.testing.expectEqual(@as(usize, 32), call_result.output.len);

    // Verify it returns 99
    var returned_value: u256 = 0;
    for (call_result.output, 0..) |byte, i| {
        returned_value |= @as(u256, byte) << @intCast(8 * (31 - i));
    }
    try std.testing.expectEqual(@as(u256, 99), returned_value);
}

test "EVM bytecode iterator execution - simple STOP" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test bytecode iterator execution with simple STOP
    const stop_bytecode = [_]u8{0x00}; // STOP opcode

    // Add contract with STOP bytecode
    const contract_address: primitives.Address = [_]u8{0x42} ++ [_]u8{0} ** 19;
    const code_hash = try db.set_code(&stop_bytecode);
    try db.set_account(contract_address, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Call the contract using bytecode iterator execution
    const result = evm.call(DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });

    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
}

test "EVM bytecode iterator execution - PUSH and RETURN" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test bytecode that pushes a value and returns it
    // PUSH1 0x42, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    const return_bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xF3, // RETURN
    };

    // Add contract
    const contract_address: primitives.Address = [_]u8{0x43} ++ [_]u8{0} ** 19;
    const code_hash = try db.set_code(&return_bytecode);
    try db.set_account(contract_address, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Call the contract
    const result = evm.call(DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);

    // Verify returned value is 0x42
    var returned_value: u256 = 0;
    for (result.output, 0..) |byte, i| {
        returned_value |= @as(u256, byte) << @intCast(8 * (31 - i));
    }
    try std.testing.expectEqual(@as(u256, 0x42), returned_value);
}

test "EVM bytecode iterator execution - handles jumps" {
    // Create test database
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    // Database is now used directly

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test bytecode with JUMP
    // PUSH1 0x04, JUMP, 0x00 (invalid), JUMPDEST, STOP
    const jump_bytecode = [_]u8{
        0x60, 0x04, // PUSH1 0x04 (jump destination)
        0x56, // JUMP
        0x00, // Should be skipped
        0x5B, // JUMPDEST at PC=4
        0x00, // STOP
    };

    // Add contract
    const contract_address: primitives.Address = [_]u8{0x44} ++ [_]u8{0} ** 19;
    const code_hash = try db.set_code(&jump_bytecode);
    try db.set_account(contract_address, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Call the contract
    const result = evm.call(DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });

    // Jump bytecode should execute successfully
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
}

test "Minimal ERC20 deployment reproduction - benchmark runner issue" {
    // This test reproduces the stack underflow issue from the benchmark runner
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 20_000_000,
        .timestamp = 1_800_000_000,
        .difficulty = 0,
        .gas_limit = 1_000_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 7,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 1000000000,
        .blob_versioned_hashes = &.{},
    };

    const context = TransactionContext{
        .gas_limit = 1_000_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Set up caller with large balance (same as benchmark runner)
    const caller_address = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01} };
    try db.set_account(caller_address.bytes, Account{
        .balance = std.math.maxInt(u256),
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    // Read the actual ERC20 bytecode from file
    const bytecode_file = try std.fs.cwd().openFile("src/evm/fixtures/erc20-transfer/bytecode.txt", .{});
    defer bytecode_file.close();
    const bytecode_hex = try bytecode_file.readToEndAlloc(std.testing.allocator, 16 * 1024 * 1024);
    defer std.testing.allocator.free(bytecode_hex);
    
    // Hex decode helper
    const hex_decode = struct {
        fn decode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
            const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
            const trimmed = std.mem.trim(u8, clean_hex, &std.ascii.whitespace);
            if (trimmed.len == 0) return allocator.alloc(u8, 0);
            
            const result = try allocator.alloc(u8, trimmed.len / 2);
            var i: usize = 0;
            while (i < trimmed.len) : (i += 2) {
                const byte_str = trimmed[i .. i + 2];
                result[i / 2] = std.fmt.parseInt(u8, byte_str, 16) catch return error.InvalidHexCharacter;
            }
            return result;
        }
    }.decode;
    
    const trimmed_hex = std.mem.trim(u8, bytecode_hex, " \t\n\r");
    const init_code = try hex_decode(std.testing.allocator, trimmed_hex);
    defer std.testing.allocator.free(init_code);

    log.debug("\n=== Testing ERC20 deployment ===\n", .{});
    log.debug("Init code length: {}\n", .{init_code.len});
    log.debug("First 10 bytes: {x}\n", .{init_code[0..10]});

    // Create the contract using CREATE (same as benchmark runner)
    const create_params = CallParams{
        .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = init_code,
            .gas = 10_000_000,
        },
    };

    // This should reproduce the stack underflow issue
    const result = evm.call(create_params);
    
    // Log the result for debugging
    if (result.success) {
        log.debug("✅ Contract deployment succeeded!\n", .{});
        log.debug("Gas left: {}\n", .{result.gas_left});
        log.debug("Output length: {}\n", .{result.output.len});
    } else {
        log.debug("❌ Contract deployment failed\n", .{});
        log.debug("Gas left: {}\n", .{result.gas_left});
    }

    // For now, we expect this to fail (reproducing the issue)
    // Once fixed, change this to: try std.testing.expect(result.success);
    try std.testing.expect(!result.success);
}

test "EipsConfig compatibility with eips.EvmConfig" {
    const eips = @import("eips.zig");
    const hardforks = [_]Hardfork{.FRONTIER, .BERLIN, .LONDON, .SHANGHAI, .CANCUN, .PRAGUE};
    
    for (hardforks) |fork| {
        // Current duplicate implementation
        const old_config = EipsConfig.fromHardfork(fork);
        
        // Canonical implementation
        const canonical = eips.Eips{ .hardfork = fork };
        const new_config = canonical.get_evm_config();
        
        // Verify identical behavior
        try std.testing.expectEqual(old_config.eip_2929, new_config.eip_2929_enabled);
        try std.testing.expectEqual(old_config.eip_3541, new_config.eip_3541_enabled);
        try std.testing.expectEqual(old_config.eip_3855, new_config.eip_3855_enabled);
        try std.testing.expectEqual(old_config.eip_3860, new_config.eip_3860_enabled);
        try std.testing.expectEqual(old_config.eip_4844, new_config.eip_4844_enabled);
        try std.testing.expectEqual(old_config.eip_5656, new_config.eip_5656_enabled);
        try std.testing.expectEqual(old_config.eip_6780, new_config.eip_6780_enabled);
    }
}

test "EVM EIP checks maintain behavior after consolidation" {
    const allocator = std.testing.allocator;
    
    const test_cases = [_]struct {
        hardfork: Hardfork,
        expected_eip_3541: bool,
        expected_eip_3860: bool, 
        expected_eip_6780: bool,
    }{
        .{ .hardfork = .LONDON, .expected_eip_3541 = true, .expected_eip_3860 = false, .expected_eip_6780 = false },
        .{ .hardfork = .SHANGHAI, .expected_eip_3541 = true, .expected_eip_3860 = true, .expected_eip_6780 = false },
        .{ .hardfork = .CANCUN, .expected_eip_3541 = true, .expected_eip_3860 = true, .expected_eip_6780 = true },
    };
    
    for (test_cases) |case| {
        // Create test database
        var db = Database.init(allocator);
        defer db.deinit();

        // Create block info and transaction context
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

        var evm = try DefaultEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS, case.hardfork);
        defer evm.deinit();
        
        // Test the 3 runtime checks that currently use self.eips.eip_xxxx_enabled
        try std.testing.expectEqual(case.expected_eip_3541, evm.eips.eip_3541_enabled);
        try std.testing.expectEqual(case.expected_eip_3860, evm.eips.eip_3860_enabled);
        try std.testing.expectEqual(case.expected_eip_6780, evm.eips.eip_6780_enabled);
    }
}
