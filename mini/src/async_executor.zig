/// Async execution orchestrator for the EVM
/// Handles yielding for async data requests (storage, balance, code, nonce)
/// and resuming execution when data is provided
const std = @import("std");
const primitives = @import("primitives");
const log = @import("logger.zig");
const errors = @import("errors.zig");
const storage_mod = @import("storage.zig");

pub const StorageKey = primitives.State.StorageKey;

/// Async data request - written when cache miss occurs
pub const AsyncDataRequest = union(enum) {
    none: void,
    storage: struct {
        address: primitives.Address,
        slot: u256,
    },
    balance: struct {
        address: primitives.Address,
    },
    code: struct {
        address: primitives.Address,
    },
    nonce: struct {
        address: primitives.Address,
    },
};

/// AsyncExecutor - manages async execution state and control flow
pub fn AsyncExecutor(comptime EvmType: type, comptime CallParams: type, comptime CallResult: type) type {
    return struct {
        const Self = @This();

        /// Input to callOrContinue - tagged union for starting or continuing execution
        pub const CallOrContinueInput = union(enum) {
            call: CallParams,
            continue_with_storage: struct {
                address: primitives.Address,
                slot: u256,
                value: u256,
            },
            continue_with_balance: struct {
                address: primitives.Address,
                balance: u256,
            },
            continue_with_code: struct {
                address: primitives.Address,
                code: []const u8,
            },
            continue_with_nonce: struct {
                address: primitives.Address,
                nonce: u64,
            },
            continue_after_commit: void,
        };

        /// Output from callOrContinue - tagged union for result or async request
        pub const CallOrContinueOutput = union(enum) {
            result: CallResult,
            need_storage: struct {
                address: primitives.Address,
                slot: u256,
            },
            need_balance: struct {
                address: primitives.Address,
            },
            need_code: struct {
                address: primitives.Address,
            },
            need_nonce: struct {
                address: primitives.Address,
            },
            ready_to_commit: struct {
                changes_json: []const u8,
            },
        };

        /// Reference to parent EVM instance
        evm: *EvmType,

        /// Current async data request
        async_data_request: AsyncDataRequest,

        /// Initialize async executor
        pub fn init(evm: *EvmType) Self {
            return Self{
                .evm = evm,
                .async_data_request = .none,
            };
        }

        /// Main async execution method - supports yielding for async requests
        /// CRITICAL: NO defer statements that clean up state!
        pub fn callOrContinue(
            self: *Self,
            input: CallOrContinueInput,
        ) !CallOrContinueOutput {
            switch (input) {
                .call => |params| {
                    // Start new call - delegate to EVM's call setup
                    return try self.startNewCall(params);
                },

                .continue_with_storage => |data| {
                    const key = StorageKey{
                        .address = data.address.bytes,
                        .slot = data.slot,
                    };

                    // Store value in both cache and storage
                    if (self.evm.storage.storage_injector) |injector| {
                        _ = try injector.storage_cache.put(key, data.value);
                    }

                    // Also put in self.storage so get_storage can find it
                    try self.evm.storage.putInCache(data.address, data.slot, data.value);

                    // Clear the request
                    self.async_data_request = .none;

                    // Continue execution
                    return try self.executeUntilYieldOrComplete();
                },

                .continue_with_balance => |data| {
                    if (self.evm.storage.storage_injector) |injector| {
                        _ = try injector.balance_cache.put(data.address, data.balance);
                    }

                    // Clear the request
                    self.async_data_request = .none;

                    return try self.executeUntilYieldOrComplete();
                },

                .continue_with_code => |data| {
                    if (self.evm.storage.storage_injector) |injector| {
                        // Duplicate code slice so cache owns it
                        const code_copy = try self.evm.arena.allocator().dupe(u8, data.code);
                        _ = try injector.code_cache.put(data.address, code_copy);
                    }

                    // Also store in EVM's code map
                    const code_copy2 = try self.evm.arena.allocator().dupe(u8, data.code);
                    try self.evm.code.put(data.address, code_copy2);

                    // Clear the request
                    self.async_data_request = .none;

                    return try self.executeUntilYieldOrComplete();
                },

                .continue_with_nonce => |data| {
                    if (self.evm.storage.storage_injector) |injector| {
                        _ = try injector.nonce_cache.put(data.address, data.nonce);
                    }

                    // Also store in EVM's nonce map
                    try self.evm.nonces.put(data.address, data.nonce);

                    // Clear the request
                    self.async_data_request = .none;

                    return try self.executeUntilYieldOrComplete();
                },

                .continue_after_commit => {
                    // Commit done - finalize and return result
                    return try self.finalizeAndReturnResult();
                },
            }
        }

        /// Start a new call and begin execution
        pub fn startNewCall(self: *Self, params: CallParams) !CallOrContinueOutput {
            // Initialize transaction state in EVM
            try self.evm.initTransactionState(null);

            if (self.evm.storage.storage_injector) |injector| {
                log.debug("callOrContinue: Storage injector enabled, clearing cache", .{});
                injector.clearCache();
            } else {
                log.debug("callOrContinue: No storage injector", .{});
            }

            // Extract common parameters (same as call() method)
            const caller = params.getCaller();
            const gas = @as(i64, @intCast(params.getGas()));
            const is_create = params.isCreate();

            // Determine target address and value
            const address: primitives.Address = if (is_create) blk: {
                if (params == .create2) {
                    const init_code = params.getInput();
                    const salt = params.create2.salt;
                    break :blk try self.evm.computeCreate2Address(caller, salt, init_code);
                } else {
                    const nonce = self.evm.getNonce(caller);
                    break :blk try self.evm.computeCreateAddress(caller, nonce);
                }
            } else params.get_to().?;

            const value = switch (params) {
                .call => |p| p.value,
                .callcode => |p| p.value,
                .create => |p| p.value,
                .create2 => |p| p.value,
                .delegatecall, .staticcall => 0,
            };

            const calldata = params.getInput();
            const bytecode = self.evm.pending_bytecode;

            try self.evm.preWarmTransaction(address);

            // Pre-warm access list if present (EIP-2929/EIP-2930)
            if (self.evm.pending_access_list) |list| {
                try self.evm.access_list_manager.preWarmFromAccessList(list);
            }

            // Transfer value if needed
            if (value > 0 and self.evm.host != null) {
                const sender_balance = if (self.evm.host) |h| h.getBalance(caller) else 0;
                if (sender_balance < value) {
                    return error.InsufficientBalance;
                }
                if (self.evm.host) |h| {
                    h.setBalance(caller, sender_balance - value);
                    const recipient_balance = h.getBalance(address);
                    h.setBalance(address, recipient_balance + value);
                }
            }

            // Create frame WITHOUT defer (critical!)
            log.debug("callOrContinue: Creating frame with address={any}", .{address.bytes});
            const FrameType = @TypeOf(self.evm.frames.items[0]);
            try self.evm.frames.append(self.evm.arena.allocator(), try FrameType.init(
                self.evm.arena.allocator(),
                bytecode,
                gas,
                caller,
                address,
                value,
                calldata,
                @as(*anyopaque, @ptrCast(self.evm)),
                self.evm.hardfork,
                false, // Top-level is never static
            ));

            // Execute (may yield)
            return try self.executeUntilYieldOrComplete();
        }

        /// Execute until we hit a yield point or complete
        /// NO defer statements!
        fn executeUntilYieldOrComplete(self: *Self) !CallOrContinueOutput {
            // Delegate to EVM's internal helper method
            return try self.evm.executeUntilYieldOrComplete();
        }

        /// Finalize execution and return result
        /// Called only when we're truly done (after commit if needed)
        fn finalizeAndReturnResult(self: *Self) !CallOrContinueOutput {
            // Delegate to EVM's internal helper method
            return try self.evm.finalizeAndReturnResult();
        }
    };
}
