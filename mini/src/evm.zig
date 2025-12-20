/// EVM implementation for tracing and validation
/// This is a simplified, unoptimized EVM that orchestrates execution.
/// Architecture mirrors evm.zig - Evm orchestrates, Frame executes
const std = @import("std");
const log = @import("logger.zig");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
const Address = primitives.Address;
const Frame = @import("frame.zig").Frame;
const Hardfork = primitives.Hardfork;
const host = @import("host.zig");
const errors = @import("errors.zig");
const trace = @import("trace.zig");
const precompiles = @import("precompiles");
const evm_config = @import("evm_config.zig");
const EvmConfig = evm_config.EvmConfig;
const storage_injector = @import("storage_injector.zig");
const StorageInjector = storage_injector.StorageInjector;
const storage_mod = @import("storage.zig");
const async_executor_mod = @import("async_executor.zig");
const access_list_manager_mod = @import("access_list_manager.zig");
const AccessListManager = access_list_manager_mod.AccessListManager;
const AccessListSnapshot = access_list_manager_mod.AccessListSnapshot;

// Re-export StorageKey from primitives
pub const StorageKey = primitives.StorageKey;
pub const StorageSlotKey = StorageKey; // Backwards compatibility alias

// Re-export from storage module
pub const Storage = storage_mod.Storage;
pub const AsyncDataRequest = storage_mod.AsyncDataRequest;

// For creating snapshots we need access to the snapshot API
// The manager provides snapshot() and restore() methods

pub const BlockContext = struct {
    chain_id: u256,
    block_number: u64,
    block_timestamp: u64,
    block_difficulty: u256,
    block_prevrandao: u256,
    block_coinbase: primitives.Address,
    block_gas_limit: u64,
    block_base_fee: u256,
    blob_base_fee: u256,
    /// Array of recent block hashes (last 256 blocks)
    /// Per Python reference (cancun/vm/__init__.py:42): block_hashes: List[Hash32]
    /// Python access pattern: block_hashes[-(current_block - target_block)]
    /// Empty slice if no block hashes available
    block_hashes: []const [32]u8 = &[_][32]u8{},
};

/// Creates a configured EVM instance type.
pub fn Evm(comptime config: EvmConfig) type {
    // Import Frame with matching config
    const frame_mod = @import("frame.zig");
    const FrameType = frame_mod.Frame(config);

    // Import new API types with config
    const call_params = @import("call_params.zig");
    const call_result = @import("call_result.zig");

    return struct {
        const Self = @This();

        pub const CallParams = call_params.CallParams(config);
        pub const CallResult = call_result.CallResult(config);

        // Create AsyncExecutor type for this EVM
        pub const AsyncExecutorType = async_executor_mod.AsyncExecutor(Self, CallParams, CallResult);

        // Re-export async types from executor
        pub const CallOrContinueInput = AsyncExecutorType.CallOrContinueInput;
        pub const CallOrContinueOutput = AsyncExecutorType.CallOrContinueOutput;

        frames: std.ArrayList(FrameType),
        storage: Storage,
        created_accounts: std.AutoHashMap(primitives.Address, void),
        selfdestructed_accounts: std.AutoHashMap(primitives.Address, void), // EIP-6780: Track accounts marked for deletion
        touched_accounts: std.AutoHashMap(primitives.Address, void), // Pre-Paris: Track touched accounts for deletion if empty
        balances: std.AutoHashMap(primitives.Address, u256),
        nonces: std.AutoHashMap(primitives.Address, u64),
        code: std.AutoHashMap(primitives.Address, []const u8),
        access_list_manager: AccessListManager,
        gas_refund: u64,
        // Stack of balance snapshots for nested calls (for SELFDESTRUCT revert handling)
        // Each call pushes a snapshot, and on revert we restore from that snapshot
        balance_snapshot_stack: std.ArrayList(*std.AutoHashMap(primitives.Address, u256)),
        hardfork: Hardfork = Hardfork.DEFAULT,
        fork_transition: ?primitives.ForkTransition = null,
        origin: primitives.Address,
        gas_price: u256,
        host: ?host.HostInterface,
        arena: std.heap.ArenaAllocator,
        allocator: std.mem.Allocator,
        tracer: ?*trace.Tracer = null,
        block_context: BlockContext,
        blob_versioned_hashes: []const [32]u8 = &[_][32]u8{},
        // Stored state for call() - set via setter methods
        pending_bytecode: []const u8 = &[_]u8{},
        pending_access_list: ?primitives.AccessList.AccessList = null,
        pending_storage_injector: ?*storage_injector.StorageInjector = null,

        // Config-provided overrides (comptime known)
        opcode_overrides: []const evm_config.OpcodeOverride,
        precompile_overrides: []const evm_config.PrecompileOverride,

        // Buffer for state changes JSON (persists across yields)
        pending_state_changes_buffer: [16384]u8 = undefined,
        pending_state_changes_len: usize = 0,

        // Async executor (initialized after Self is fully constructed)
        async_executor: ?AsyncExecutorType = null,

        // Accumulated logs for current transaction
        logs: std.ArrayList(call_result.Log),

        /// Initialize a new EVM instance
        /// Config provides defaults, but hardfork can be overridden at runtime
        pub fn init(allocator: std.mem.Allocator, h: ?host.HostInterface, hardfork: ?Hardfork, block_context: ?BlockContext, log_level: ?log.LogLevel) !Self {
            // Set log level if provided
            if (log_level) |level| {
                log.setLogLevel(level);
            }

            // Create arena and get allocator for state HashMaps
            var arena = std.heap.ArenaAllocator.init(allocator);
            const arena_alloc = arena.allocator();

            return Self{
                .frames = undefined,
                .storage = undefined,
                .created_accounts = undefined,
                .selfdestructed_accounts = undefined,
                .touched_accounts = undefined,
                .balances = std.AutoHashMap(primitives.Address, u256).init(arena_alloc),
                .nonces = std.AutoHashMap(primitives.Address, u64).init(arena_alloc),
                .code = std.AutoHashMap(primitives.Address, []const u8).init(arena_alloc),
                .access_list_manager = undefined,
                .gas_refund = 0,
                .balance_snapshot_stack = undefined,
                .hardfork = hardfork orelse Hardfork.DEFAULT,
                .block_context = block_context orelse .{
                    .chain_id = 1,
                    .block_number = 0,
                    .block_timestamp = 0,
                    .block_difficulty = 0,
                    .block_prevrandao = 0,
                    .block_coinbase = primitives.ZERO_ADDRESS,
                    .block_gas_limit = config.block_gas_limit,
                    .block_base_fee = 0,
                    .blob_base_fee = 0,
                },
                .origin = primitives.ZERO_ADDRESS,
                .gas_price = 0,
                .host = h,
                .arena = arena,
                .allocator = allocator,
                .tracer = null,
                .opcode_overrides = config.opcode_overrides,
                .precompile_overrides = config.precompile_overrides,
                .async_executor = null, // Initialized when needed
                .logs = undefined,
            };
        }

        /// Look up custom opcode handler override
        /// Returns null if no override exists for this opcode
        pub fn getOpcodeOverride(self: *const Self, opcode: u8) ?*const anyopaque {
            for (self.opcode_overrides) |override| {
                if (override.opcode == opcode) {
                    return override.handler;
                }
            }
            return null;
        }

        /// Look up custom precompile override
        /// Returns null if no override exists for this address
        pub fn getPrecompileOverride(self: *const Self, address: primitives.Address) ?*const evm_config.PrecompileOverride {
            for (self.precompile_overrides) |*override| {
                if (override.address.equals(address)) {
                    return override;
                }
            }
            return null;
        }

        /// Clean up resources
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        /// Get the active fork based on block context (handles fork transitions)
        pub fn getActiveFork(self: *const Self) Hardfork {
            if (self.fork_transition) |transition| {
                return transition.getActiveFork(self.block_context.block_number, self.block_context.block_timestamp);
            }
            return self.hardfork;
        }

        /// Initialize internal state (hash maps, lists, etc.) for transaction execution
        /// Must be called before any transaction execution (call or inner_create)
        pub fn initTransactionState(self: *Self, blob_versioned_hashes: ?[]const [32]u8) !void {
            const arena_allocator = self.arena.allocator();
            self.storage = Storage.init(arena_allocator, self.host, self.pending_storage_injector);
            // Clear existing HashMaps instead of creating new ones (allows pre-state setup)
            self.balances.clearRetainingCapacity();
            self.nonces.clearRetainingCapacity();
            self.code.clearRetainingCapacity();
            self.access_list_manager = AccessListManager.init(arena_allocator);
            self.frames = std.ArrayList(FrameType){};
            try self.frames.ensureTotalCapacity(arena_allocator, 16);
            self.logs = std.ArrayList(call_result.Log){};
            self.created_accounts = std.AutoHashMap(primitives.Address, void).init(arena_allocator);
            self.selfdestructed_accounts = std.AutoHashMap(primitives.Address, void).init(arena_allocator);
            self.touched_accounts = std.AutoHashMap(primitives.Address, void).init(arena_allocator);
            self.balance_snapshot_stack = std.ArrayList(*std.AutoHashMap(primitives.Address, u256)){};

            // Set blob versioned hashes for EIP-4844
            // CRITICAL: Must copy blob hashes into arena to ensure correct lifetime
            // The caller may free the hashes after passing them to us, so we need our own copy
            if (blob_versioned_hashes) |hashes| {
                // Allocate space in arena for blob hashes
                const hashes_copy = try arena_allocator.alloc([32]u8, hashes.len);
                // Copy each hash
                for (hashes, 0..) |hash, i| {
                    hashes_copy[i] = hash;
                }
                self.blob_versioned_hashes = hashes_copy;
            } else {
                self.blob_versioned_hashes = &[_][32]u8{};
            }
        }

        /// Set tracer for EIP-3155 trace capture
        pub fn setTracer(self: *Self, tracer: *trace.Tracer) void {
            self.tracer = tracer;
        }

        pub fn accessAddress(self: *Self, address: primitives.Address) !u64 {
            if (self.hardfork.isBefore(.BERLIN)) {
                @branchHint(.cold);
                // Pre-Berlin: No warm/cold access costs (EIP-2929 introduced in Berlin)
                // The base call cost is already charged in the CALL opcode
                return 0;
            }

            return try self.access_list_manager.accessAddress(address);
        }

        /// Access a storage slot and return the gas cost (EIP-2929 warm/cold)
        pub fn accessStorageSlot(self: *Self, contract_address: primitives.Address, slot: u256) !u64 {
            if (self.hardfork.isBefore(.BERLIN)) {
                @branchHint(.cold);
                // EIP-1884 (Istanbul): SLOAD increased from 200 to 800 gas
                if (self.hardfork.isAtLeast(.ISTANBUL)) {
                    return 800;
                } else {
                    return 200;
                }
            }

            return try self.access_list_manager.accessStorageSlot(contract_address, slot);
        }

        /// Set balance with copy-on-write snapshot for revert handling
        ///
        /// This should be called instead of direct host.setBalance() when inside a frame.
        /// Uses copy-on-write semantics to track balance changes for proper revert handling.
        ///
        /// IMPORTANT: Snapshots the balance in ALL active snapshots on the stack, not just the current one.
        /// This ensures that parent frames can restore state when they revert, even if the balance
        /// was modified in a nested call.
        ///
        /// Parameters:
        ///   - addr: The address whose balance to modify
        ///   - new_balance: The new balance value to set
        ///
        /// Returns: void
        ///
        /// Errors:
        ///   - OutOfMemory: If snapshot allocation fails
        pub fn setBalanceWithSnapshot(self: *Self, addr: primitives.Address, new_balance: u256) !void {
            // Snapshot in ALL active snapshots (from outermost to innermost)
            // This ensures parent frames can restore state even if modified in nested calls
            for (self.balance_snapshot_stack.items) |snapshot| {
                if (!snapshot.contains(addr)) {
                    // Snapshot the current balance before modifying
                    const current_balance = if (self.host) |h|
                        h.getBalance(addr)
                    else
                        self.balances.get(addr) orelse 0;
                    try snapshot.put(addr, current_balance);
                }
            }

            // Now set the new balance
            if (self.host) |h| {
                h.setBalance(addr, new_balance);
            } else {
                try self.balances.put(addr, new_balance);
            }
        }

        /// Pre-warm addresses for transaction initialization
        fn preWarmAddresses(self: *Self, addresses: []const primitives.Address) !void {
            self.access_list_manager.preWarmAddresses(addresses) catch {
                return errors.CallError.StorageError;
            };
        }

        /// Get nonce for an address
        pub fn getNonce(self: *Self, address: primitives.Address) u64 {
            if (self.host) |h| {
                return h.getNonce(address);
            }
            return self.nonces.get(address) orelse 0;
        }

        /// Compute CREATE address: keccak256(rlp([sender, nonce]))[12:]
        ///
        /// Calculates the address for a new contract created via CREATE opcode or
        /// contract creation transaction. Uses RLP encoding of [sender_address, nonce]
        /// and takes the last 20 bytes of the keccak256 hash.
        ///
        /// Parameters:
        ///   - sender: Address of the account creating the contract
        ///   - nonce: Nonce value of the sender at creation time
        ///
        /// Returns: The computed contract address
        ///
        /// Errors:
        ///   - OutOfMemory: If RLP buffer allocation fails
        pub fn computeCreateAddress(self: *Self, sender: primitives.Address, nonce: u64) !primitives.Address {
            _ = self;
            // RLP encoding of [sender (20 bytes), nonce]
            // For simplicity, use a fixed buffer (max size for nonce encoding is small)
            var buffer: [64]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buffer);
            const writer = fbs.writer();

            // Calculate nonce encoding length
            const nonce_len: usize = blk: {
                if (nonce == 0) break :blk 1;
                if (nonce < 128) break :blk 1;
                var n = nonce;
                var len: usize = 0;
                while (n > 0) : (n >>= 8) {
                    len += 1;
                }
                break :blk len + 1; // +1 for length prefix
            };

            // RLP list prefix
            const list_len = 21 + nonce_len;
            try writer.writeByte(0xc0 + @as(u8, @intCast(list_len)));

            // RLP encode sender address (20 bytes, so 0x80 + 20 = 0x94)
            try writer.writeByte(0x94);
            try writer.writeAll(&sender.bytes);

            // RLP encode nonce
            if (nonce == 0) {
                try writer.writeByte(0x80);
            } else if (nonce < 128) {
                try writer.writeByte(@intCast(nonce));
            } else {
                var nonce_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &nonce_bytes, nonce, .big);
                var start: usize = 0;
                while (start < 8 and nonce_bytes[start] == 0) : (start += 1) {}
                const nonce_byte_len = 8 - start;
                try writer.writeByte(0x80 + @as(u8, @intCast(nonce_byte_len)));
                try writer.writeAll(nonce_bytes[start..]);
            }

            const rlp_data = fbs.getWritten();

            // Compute keccak256 hash
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha3.Keccak256.hash(rlp_data, &hash, .{});

            // Take last 20 bytes as address
            var addr: primitives.Address = undefined;
            @memcpy(&addr.bytes, hash[12..32]);
            return addr;
        }

        /// Compute CREATE2 address: keccak256(0xff ++ sender ++ salt ++ keccak256(init_code))[12:]
        pub fn computeCreate2Address(self: *Self, sender: primitives.Address, salt: u256, init_code: []const u8) !primitives.Address {
            _ = self;
            // Compute keccak256(init_code)
            var init_code_hash: [32]u8 = undefined;
            std.crypto.hash.sha3.Keccak256.hash(init_code, &init_code_hash, .{});

            // Compute keccak256(0xff ++ sender ++ salt ++ init_code_hash)
            var buffer: [85]u8 = undefined; // 1 + 20 + 32 + 32
            buffer[0] = 0xff;
            @memcpy(buffer[1..21], &sender.bytes);

            // Convert salt to bytes (big-endian)
            var salt_bytes: [32]u8 = undefined;
            std.mem.writeInt(u256, &salt_bytes, salt, .big);
            @memcpy(buffer[21..53], &salt_bytes);

            @memcpy(buffer[53..85], &init_code_hash);

            var hash: [32]u8 = undefined;
            std.crypto.hash.sha3.Keccak256.hash(&buffer, &hash, .{});

            // Take last 20 bytes as address
            var addr: primitives.Address = undefined;
            @memcpy(&addr.bytes, hash[12..32]);
            return addr;
        }

        /// Pre-warm addresses at transaction start (EIP-2929, EIP-3651)
        ///
        /// Marks specific addresses as "warm" before transaction execution begins.
        /// This affects gas costs for subsequent accesses to these addresses.
        ///
        /// Pre-warmed addresses (Berlin+):
        ///   - Transaction origin (sender)
        ///   - Transaction target (if not zero address)
        ///   - Coinbase address (Shanghai+, EIP-3651)
        ///   - All precompile addresses (0x01-0x09 Berlin-Istanbul, 0x01-0x0A Cancun+, 0x01-0x12 Prague+)
        ///
        /// Pre-Berlin: No-op (no warm/cold distinction)
        ///
        /// Parameters:
        ///   - target: The transaction target address
        ///
        /// Returns: void
        ///
        /// Errors:
        ///   - StorageError: If warming addresses fails
        pub fn preWarmTransaction(self: *Self, target: primitives.Address) errors.CallError!void {
            // EIP-2929 (Berlin+): Pre-warm addresses at transaction start
            // Pre-Berlin: no warm/cold distinction, so skip this entirely
            if (!self.hardfork.isAtLeast(.BERLIN)) return;

            var warm: [3]primitives.Address = undefined;
            var count: usize = 0;

            warm[count] = self.origin;
            count += 1;

            if (!target.equals(primitives.ZERO_ADDRESS)) {
                warm[count] = target;
                count += 1;
            }

            // EIP-3651 (Shanghai+): Coinbase address is pre-warmed at transaction start
            if (self.hardfork.isAtLeast(.SHANGHAI)) {
                @branchHint(.likely);
                warm[count] = self.block_context.block_coinbase;
                count += 1;
            }

            // Pre-warm origin, target, and coinbase
            try self.preWarmAddresses(warm[0..count]);

            // Pre-warm precompiles
            // EIP-2929: Precompiles are always warm at transaction start
            // Determine number of precompiles based on hardfork
            // Berlin-Istanbul: 0x01-0x09 (9 precompiles: ECRECOVER through BLAKE2F)
            // Cancun+: 0x01-0x0A (10 precompiles, added KZG point evaluation at 0x0A via EIP-4844)
            // Prague+: 0x01-0x12 (19 precompiles, added BLS12-381 operations at 0x0B-0x12 via EIP-2537)
            const precompile_count: usize = if (self.hardfork.isAtLeast(.PRAGUE))
                0x12 // Prague: All precompiles including BLS12-381
            else if (self.hardfork.isAtLeast(.CANCUN))
                0x0A // Cancun: Includes KZG point evaluation
            else
                0x09; // Berlin-Istanbul: Up to BLAKE2F

            var precompile_addrs: [0x12]primitives.Address = undefined;
            var i: usize = 0;
            while (i < precompile_count) : (i += 1) {
                precompile_addrs[i] = primitives.Address.fromU256(i + 1);
            }
            try self.preWarmAddresses(precompile_addrs[0..precompile_count]);
        }

        /// Set bytecode for the next call() invocation
        pub fn setBytecode(self: *Self, bytecode: []const u8) void {
            self.pending_bytecode = bytecode;
        }

        /// Set access list for the next call() invocation
        pub fn setAccessList(self: *Self, access_list: ?primitives.AccessList.AccessList) void {
            self.pending_access_list = access_list;
        }

        /// Set blob versioned hashes for the next call() invocation
        pub fn setBlobVersionedHashes(self: *Self, hashes: []const [32]u8) void {
            self.blob_versioned_hashes = hashes;
        }

        /// Execute bytecode (main entry point like evm.execute)
        pub fn call(
            self: *Self,
            params: CallParams,
        ) CallResult {
            // Helper to return failure - if allocation fails, return static failure
            const makeFailure = struct {
                fn call(allocator: std.mem.Allocator, gas_left: u64) CallResult {
                    return CallResult.failure(allocator, gas_left) catch CallResult{
                        .success = false,
                        .gas_left = gas_left,
                        .output = &.{},
                    };
                }
            }.call;

            // Validate parameters
            params.validate() catch {
                return makeFailure(self.arena.allocator(), 0);
            };

            // Extract common parameters
            const caller = params.getCaller();
            const gas = @as(i64, @intCast(params.getGas()));
            const is_create = params.isCreate();

            // Determine target address and value
            const address: primitives.Address = if (is_create) blk: {
                // For CREATE operations, compute the new contract address
                if (params == .create2) {
                    // CREATE2: address = keccak256(0xff ++ caller ++ salt ++ keccak256(init_code))[12:]
                    const init_code = params.getInput();
                    const salt = params.create2.salt;
                    break :blk self.computeCreate2Address(caller, salt, init_code) catch {
                        return makeFailure(self.arena.allocator(), 0);
                    };
                } else {
                    // CREATE: address = keccak256(rlp([caller, nonce]))[12:]
                    const nonce = self.getNonce(caller);
                    break :blk self.computeCreateAddress(caller, nonce) catch {
                        return makeFailure(self.arena.allocator(), 0);
                    };
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
            const bytecode = self.pending_bytecode;
            const blob_versioned_hashes = if (self.blob_versioned_hashes.len > 0) self.blob_versioned_hashes else null;
            const access_list = self.pending_access_list;

            // Initialize transaction state
            self.initTransactionState(blob_versioned_hashes) catch {
                return makeFailure(self.arena.allocator(), 0);
            };

            self.preWarmTransaction(address) catch {
                return makeFailure(self.arena.allocator(), 0);
            };

            // Pre-warm access list (EIP-2929/EIP-2930)
            if (access_list) |list| {
                self.access_list_manager.preWarmFromAccessList(list) catch {
                    return makeFailure(self.arena.allocator(), 0);
                };
            }

            // Transfer value from caller to recipient (if value > 0)
            if (value > 0 and self.host != null) {
                const sender_balance = if (self.host) |h| h.getBalance(caller) else 0;
                if (sender_balance < value) {
                    return makeFailure(self.arena.allocator(), 0);
                }
                if (self.host) |h| {
                    h.setBalance(caller, sender_balance - value);
                    const recipient_balance = h.getBalance(address);
                    h.setBalance(address, recipient_balance + value);
                }
            }

            // Note: intrinsic gas should be deducted by the caller (e.g., test runner)
            // before calling this function. This function receives gas that's already
            // net of intrinsic costs, similar to inner_call().

            // Check if this is a precompile address with empty bytecode (like inner_call)
            if (bytecode.len == 0) {
                // Check if this is a precompile address (hardfork-aware)
                if (precompiles.isPrecompile(address, self.hardfork)) {
                    // Use the precompiles module to handle all precompile execution
                    const result = precompiles.execute(
                        self.arena.allocator(),
                        address,
                        calldata,
                        @intCast(gas),
                        self.hardfork,
                    ) catch |err| {
                        // On error, return failure
                        std.debug.print("Precompile execution error: {}\n", .{err});
                        // Reverse value transfer on error
                        if (value > 0 and self.host != null) {
                            if (self.host) |h| {
                                const sender_balance = h.getBalance(caller);
                                const recipient_balance = h.getBalance(address);
                                h.setBalance(caller, sender_balance + value);
                                h.setBalance(address, recipient_balance - value);
                            }
                        }
                        return CallResult{
                            .success = false,
                            .gas_left = 0,
                            .output = &[_]u8{},
                            .refund_counter = self.gas_refund,
                        };
                    };

                    // Reset transaction-scoped caches
                    self.access_list_manager.clear();

                    // Clear transient storage at end of transaction (EIP-1153)
                    self.storage.clearTransient();

                    // Delete selfdestructed accounts at end of transaction (EIP-6780)
                    var selfdestruct_it = self.selfdestructed_accounts.iterator();
                    while (selfdestruct_it.next()) |entry| {
                        const addr = entry.key_ptr.*;
                        if (self.host) |h| {
                            // Clear all account state: balance (should already be 0), code, nonce, and storage
                            h.setBalance(addr, 0);
                            h.setCode(addr, &[_]u8{});
                            h.setNonce(addr, 0);

                            // Clear permanent storage for self-destructed account
                            var storage_it = self.storage.storage.iterator();
                            while (storage_it.next()) |storage_entry| {
                                const key = storage_entry.key_ptr.*;
                                if (std.mem.eql(u8, &key.address, &addr.bytes)) {
                                    h.setStorage(addr, key.slot, 0);
                                }
                            }
                        } else {
                            // Clear all account state in EVM storage
                            // These put operations should never fail in normal circumstances since we're
                            // using an arena allocator for transaction-scoped data. If OOM occurs during
                            // cleanup, it indicates a critical system issue that should be handled explicitly.
                            self.balances.put(addr, 0) catch |err| {
                                std.debug.print("CRITICAL: Failed to clear balance for selfdestructed account {any}: {any}\n", .{ addr, err });
                                // Continue cleanup of other accounts even if this one fails
                            };
                            self.code.put(addr, &[_]u8{}) catch |err| {
                                std.debug.print("CRITICAL: Failed to clear code for selfdestructed account {any}: {any}\n", .{ addr, err });
                            };
                            self.nonces.put(addr, 0) catch |err| {
                                std.debug.print("CRITICAL: Failed to clear nonce for selfdestructed account {any}: {any}\n", .{ addr, err });
                            };

                            // Clear storage
                            var storage_it = self.storage.storage.iterator();
                            while (storage_it.next()) |storage_entry| {
                                const key = storage_entry.key_ptr.*;
                                if (std.mem.eql(u8, &key.address, &addr.bytes)) {
                                    _ = self.storage.storage.remove(key);
                                }
                            }
                        }
                    }
                    self.selfdestructed_accounts.clearRetainingCapacity();

                    return CallResult{
                        .success = true,
                        .gas_left = @as(u64, @intCast(gas)) - result.gas_used,
                        .output = result.output,
                        .refund_counter = self.gas_refund,
                    };
                }

                // For non-precompile empty accounts, return success with no output
                // Reset transaction-scoped caches
                self.access_list_manager.clear();
                self.storage.clearTransient();
                self.selfdestructed_accounts.clearRetainingCapacity();

                return CallResult{
                    .success = true,
                    .gas_left = @intCast(gas),
                    .output = &[_]u8{},
                    .refund_counter = self.gas_refund,
                };
            }

            // Create and push frame onto stack
            self.frames.append(self.arena.allocator(), FrameType.init(
                self.arena.allocator(),
                bytecode,
                gas,
                caller,
                address,
                value,
                calldata,
                @as(*anyopaque, @ptrCast(self)),
                self.hardfork,
                false, // Top-level transaction is never static
            ) catch {
                return makeFailure(self.arena.allocator(), 0);
            }) catch {
                return makeFailure(self.arena.allocator(), 0);
            };
            defer _ = self.frames.pop();

            // Execute the frame (don't cache pointer - it may become invalid during nested calls)
            self.frames.items[self.frames.items.len - 1].execute() catch {
                // Error case - reverse value transfer if needed
                if (value > 0 and self.host != null) {
                    if (self.host) |h| {
                        const sender_balance = h.getBalance(caller);
                        const recipient_balance = h.getBalance(address);
                        h.setBalance(caller, sender_balance + value);
                        h.setBalance(address, recipient_balance - value);
                    }
                }
                // Return failure (arena will clean up)
                return makeFailure(self.arena.allocator(), 0);
            };

            // Get frame results (refetch pointer after execution)
            const frame = &self.frames.items[self.frames.items.len - 1];
            const output = self.arena.allocator().alloc(u8, frame.output.len) catch {
                return makeFailure(self.arena.allocator(), 0);
            };
            @memcpy(output, frame.output);

            const gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
            // Note: Gas refunds are NOT applied here. They should be applied by the caller
            // (test runner) after calculating coinbase payment based on gas actually consumed.
            // The refund counter is NOT reset here - caller needs access to it.

            // Reverse value transfer if transaction reverted
            if (frame.reverted and value > 0 and self.host != null) {
                if (self.host) |h| {
                    const sender_balance = h.getBalance(caller);
                    const recipient_balance = h.getBalance(address);
                    h.setBalance(caller, sender_balance + value);
                    h.setBalance(address, recipient_balance - value);
                }
            }

            // Return result (execution gas left; intrinsic gas handled by caller)
            var result = if (frame.reverted)
                CallResult.revert_with_data(self.arena.allocator(), gas_left, output) catch unreachable
            else
                CallResult.success_with_logs(self.arena.allocator(), gas_left, output, self.logs.items) catch unreachable;

            // Set created address for CREATE operations
            if (is_create and !frame.reverted) {
                result.created_address = address;
            }

            // Reset transaction-scoped caches
            self.access_list_manager.clear();

            // Clear transient storage at end of transaction (EIP-1153)
            self.storage.clearTransient();

            // Clear logs buffer for next transaction
            self.logs.clearRetainingCapacity();

            // Delete selfdestructed accounts at end of transaction (EIP-6780)
            // This must happen AFTER transient storage is cleared since transient storage
            // should be accessible during the transaction even after SELFDESTRUCT
            var selfdestruct_it = self.selfdestructed_accounts.iterator();
            while (selfdestruct_it.next()) |entry| {
                const addr = entry.key_ptr.*;
                if (self.host) |h| {
                    // Clear all account state: balance (should already be 0), code, nonce, and storage
                    h.setBalance(addr, 0);
                    h.setCode(addr, &[_]u8{});
                    h.setNonce(addr, 0);

                    // Clear permanent storage for self-destructed account
                    // Per Python reference: destroy_account calls destroy_storage
                    // We need to iterate and clear all storage slots for this address
                    var storage_it = self.storage.storage.iterator();
                    while (storage_it.next()) |storage_entry| {
                        const key = storage_entry.key_ptr.*;
                        if (std.mem.eql(u8, &key.address, &addr.bytes)) {
                            h.setStorage(addr, key.slot, 0);
                        }
                    }
                } else {
                    // Clear all account state in EVM storage
                    // Note: In non-host mode, we use arena allocation so memory will be reclaimed
                    // when the arena is freed. We simply remove storage entries rather than trying to update them.
                    // Clear permanent storage for self-destructed account
                    // Per Python reference: destroy_account calls destroy_storage
                    var storage_it = self.storage.storage.iterator();
                    while (storage_it.next()) |storage_entry| {
                        const key = storage_entry.key_ptr.*;
                        if (std.mem.eql(u8, &key.address, &addr.bytes)) {
                            _ = self.storage.storage.fetchRemove(key);
                        }
                    }
                    // Also clear from original_storage
                    var original_storage_it = self.storage.original_storage.iterator();
                    while (original_storage_it.next()) |storage_entry| {
                        const key = storage_entry.key_ptr.*;
                        if (std.mem.eql(u8, &key.address, &addr.bytes)) {
                            _ = self.storage.original_storage.fetchRemove(key);
                        }
                    }
                    // Clear account state by removing from maps
                    _ = self.balances.fetchRemove(addr);
                    _ = self.code.fetchRemove(addr);
                    _ = self.nonces.fetchRemove(addr);
                }
            }

            // Clear transaction-scoped sets at end of transaction
            // These must be cleared to avoid incorrectly treating accounts as created/selfdestructed
            // in subsequent transactions within the same block
            self.created_accounts.clearRetainingCapacity();
            self.selfdestructed_accounts.clearRetainingCapacity();

            // No cleanup needed - arena handles it
            return result;
        }

        /// Main async execution method - supports yielding for async requests
        /// CRITICAL: NO defer statements that clean up state!
        /// This wraps call() but supports yielding for async data requests
        pub fn callOrContinue(
            self: *Self,
            input: CallOrContinueInput,
        ) !CallOrContinueOutput {
            // Initialize async executor on first use
            if (self.async_executor == null) {
                self.async_executor = AsyncExecutorType.init(self);
            }

            // Delegate to async executor
            return try self.async_executor.?.callOrContinue(input);
        }

        /// Execute until we hit a yield point or complete
        /// NO defer statements!
        pub fn executeUntilYieldOrComplete(self: *Self) !CallOrContinueOutput {
            while (self.frames.items.len > 0) {
                const frame = &self.frames.items[self.frames.items.len - 1];

                // Execute frame - may return error.NeedAsyncData
                frame.execute() catch |err| {
                    if (err == error.NeedAsyncData) {
                        // Read the request from evm.async_data_request
                        return switch (self.storage.async_data_request) {
                            .storage => |req| .{ .need_storage = .{
                                .address = req.address,
                                .slot = req.slot,
                            } },
                            .balance => |req| .{ .need_balance = .{ .address = req.address } },
                            .code => |req| .{ .need_code = .{ .address = req.address } },
                            .nonce => |req| .{ .need_nonce = .{ .address = req.address } },
                            .none => error.InvalidAsyncState,
                        };
                    }

                    // Real error - return it (state preserved for debugging)
                    return err;
                };

                // Frame completed successfully
                // Check if this is the last frame AND we have storage injector
                if (self.frames.items.len == 1 and self.storage.storage_injector != null) {
                    log.debug("executeUntilYieldOrComplete: Last frame, dumping changes", .{});
                    // Don't pop yet - need to dump changes first
                    const changes_json = try self.dumpStateChanges();
                    log.debug("executeUntilYieldOrComplete: changes_json.len = {}", .{changes_json.len});
                    return .{ .ready_to_commit = .{ .changes_json = changes_json } };
                }

                // Pop frame (safe - not returning early)
                _ = self.frames.pop();
            }

            // All frames complete, no storage injector
            return try self.finalizeAndReturnResult();
        }

        /// Finalize execution and return result
        /// Called only when we're truly done (after commit if needed)
        pub fn finalizeAndReturnResult(self: *Self) !CallOrContinueOutput {
            // At this point frames should be empty OR we have one frame to finalize
            if (self.frames.items.len > 0) {
                const frame = self.frames.items[self.frames.items.len - 1];
                const output = try self.arena.allocator().dupe(u8, frame.output);
                const gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
                const success = !frame.reverted;

                // NOW we can pop (we're returning the final result)
                _ = self.frames.pop();

                // Clean up transaction state (safe now)
                self.access_list_manager.clear();
                self.storage.clearTransient();

                return .{ .result = CallResult{
                    .success = success,
                    .gas_left = gas_left,
                    .output = output,
                    .refund_counter = self.gas_refund,
                } };
            }

            return .{ .result = CallResult{
                .success = true,
                .gas_left = 0,
                .output = &.{},
                .refund_counter = self.gas_refund,
            } };
        }

        /// Dump state changes to JSON
        pub fn dumpStateChanges(self: *Self) ![]const u8 {
            if (self.storage.storage_injector) |injector| {
                const result = try injector.dumpChanges(self);
                log.debug("dumpStateChanges: Got {} bytes from injector", .{result.len});
                // Copy to persistent buffer in Evm struct
                const copy_len = @min(result.len, self.pending_state_changes_buffer.len);
                if (copy_len > 0) {
                    @memcpy(self.pending_state_changes_buffer[0..copy_len], result[0..copy_len]);
                }
                self.pending_state_changes_len = copy_len;
                return self.pending_state_changes_buffer[0..copy_len];
            }
            log.debug("dumpStateChanges: No injector, returning empty", .{});
            self.pending_state_changes_len = 0;
            return &.{};
        }

        /// Handle inner call from frame (like evm.inner_call)
        /// Execute a nested EVM call - used for calls from within the EVM (e.g., CALL, DELEGATECALL opcodes).
        /// This handles nested calls and manages depth tracking.
        /// Follows the same API pattern as guillotine performance EVM.
        pub fn inner_call(
            self: *Self,
            params: CallParams,
        ) CallResult {
            // Helper to return failure - if allocation fails, return static failure
            const makeFailure = struct {
                fn call(allocator: std.mem.Allocator, gas_left: u64) CallResult {
                    return CallResult.failure(allocator, gas_left) catch CallResult{
                        .success = false,
                        .gas_left = gas_left,
                        .output = &.{},
                    };
                }
            }.call;
            // Extract parameters from CallParams union
            const address: primitives.Address = switch (params) {
                .call => |p| p.to,
                .callcode => |p| p.to,
                .delegatecall => |p| p.to,
                .staticcall => |p| p.to,
                .create => unreachable, // CREATE should use inner_create
                .create2 => unreachable, // CREATE2 should use inner_create
            };

            const value: u256 = if (params.hasValue()) switch (params) {
                .call => |p| p.value,
                .callcode => |p| p.value,
                else => 0,
            } else 0;

            const input: []const u8 = params.getInput();
            const gas: u64 = params.getGas();

            // Determine call type
            const call_type: enum { Call, CallCode, DelegateCall, StaticCall } = switch (params) {
                .call => .Call,
                .callcode => .CallCode,
                .delegatecall => .DelegateCall,
                .staticcall => .StaticCall,
                else => unreachable,
            };
            // Check call depth (STACK_DEPTH_LIMIT = 1024)
            // Per Python reference (system.py:297-300), depth exceeded refunds gas
            if (self.frames.items.len >= 1024) {
                return makeFailure(self.arena.allocator(), gas);
            }

            // Get caller and execution context address based on call type
            // For CALL: caller = current frame's address, execution address = target address
            // For DELEGATECALL: caller = current frame's caller, execution address = current frame's address (code from target)
            // For CALLCODE: caller = current frame's address, execution address = current frame's address (code from target)
            // For STATICCALL: same as CALL but with static mode
            const current_frame = self.getCurrentFrame();
            const frame_caller = if (current_frame) |frame| frame.address else self.origin;
            const frame_caller_caller = if (current_frame) |frame| frame.caller else self.origin;

            // Snapshot gas refunds before the call
            // Per Python reference (vm/__init__.py:incorporate_child_on_error), failed calls do not
            // propagate refunds to parent. Only incorporate_child_on_success adds child refunds.
            const refund_snapshot = self.gas_refund;

            // Snapshot transient storage before the call (EIP-1153)
            // Transient storage must be reverted on call failure
            var transient_snapshot = std.AutoHashMap(StorageKey, u256).init(self.arena.allocator());
            var it = self.storage.transient.iterator();
            while (it.next()) |entry| {
                transient_snapshot.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                    // Memory allocation failed during snapshot - fail the call
                    return makeFailure(self.arena.allocator(), gas);
                };
            }

            // Snapshot selfdestructed_accounts before the call (EIP-6780 revert handling)
            // On revert, accounts marked for deletion during the reverted call must be removed
            var selfdestruct_snapshot = std.AutoHashMap(primitives.Address, void).init(self.arena.allocator());
            var selfdestruct_it = self.selfdestructed_accounts.iterator();
            while (selfdestruct_it.next()) |entry| {
                selfdestruct_snapshot.put(entry.key_ptr.*, {}) catch {
                    // Memory allocation failed during snapshot - fail the call
                    return makeFailure(self.arena.allocator(), gas);
                };
            }

            // Snapshot warm addresses and storage slots before the call (EIP-2929)
            // Per Python reference (incorporate_child_on_error), accessed_addresses
            // and accessed_storage_keys are only propagated on success, not on failure
            var access_list_snapshot = self.access_list_manager.snapshot() catch {
                return makeFailure(self.arena.allocator(), gas);
            };
            defer access_list_snapshot.deinit();

            // Snapshot original_storage before the call
            // This is critical for correct SSTORE gas calculation after reverts
            // When a call reverts, any entries added to original_storage during that call
            // must be removed, otherwise subsequent SSTOREs will use stale original values
            // and incorrectly calculate gas costs and refunds
            var original_storage_snapshot = std.AutoHashMap(StorageKey, u256).init(self.arena.allocator());
            var original_storage_it = self.storage.original_storage.iterator();
            while (original_storage_it.next()) |entry| {
                original_storage_snapshot.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                    return makeFailure(self.arena.allocator(), gas);
                };
            }

            // Snapshot storage before the call
            // We need to track which slots existed and their values
            // On revert, we restore to this exact state (remove new slots, restore modified slots)
            var storage_snapshot = std.AutoHashMap(StorageKey, u256).init(self.arena.allocator());
            if (self.host) |h| {
                // In host mode, we need to ask the host for current storage values
                // But we don't have a way to enumerate all slots, so we track what we've seen
                // For now, we'll snapshot original_storage keys since those are the accessed slots
                var orig_it = self.storage.original_storage.iterator();
                while (orig_it.next()) |entry| {
                    const addr = primitives.Address.Address{ .bytes = entry.key_ptr.*.address };
                    const current_val = h.getStorage(addr, entry.key_ptr.*.slot);
                    storage_snapshot.put(entry.key_ptr.*, current_val) catch {
                        return makeFailure(self.arena.allocator(), gas);
                    };
                }
            } else {
                var storage_it = self.storage.storage.iterator();
                while (storage_it.next()) |entry| {
                    storage_snapshot.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                        return makeFailure(self.arena.allocator(), gas);
                    };
                }
            }

            // Snapshot balances before the call (for SELFDESTRUCT revert handling)
            // We use copy-on-write: addresses are snapshotted when first modified via setBalanceWithSnapshot
            var balance_snapshot = std.AutoHashMap(primitives.Address, u256).init(self.arena.allocator());

            // Push the snapshot onto the stack so nested calls can snapshot in parent snapshots
            self.balance_snapshot_stack.append(self.arena.allocator(), &balance_snapshot) catch {
                return makeFailure(self.arena.allocator(), gas);
            };
            defer _ = self.balance_snapshot_stack.pop();

            const execution_caller: primitives.Address = switch (call_type) {
                .Call, .StaticCall => frame_caller,
                .DelegateCall => frame_caller_caller,
                .CallCode => frame_caller,
            };

            const execution_address: primitives.Address = switch (call_type) {
                .Call, .StaticCall => address,
                .DelegateCall, .CallCode => frame_caller,
            };

            // Handle balance transfer if value > 0 (only for regular CALL)
            if (value > 0 and call_type == .Call) {
                const caller_balance = if (self.host) |h| h.getBalance(frame_caller) else self.balances.get(frame_caller) orelse 0;
                if (caller_balance < value) {
                    // Insufficient balance - call fails
                    return makeFailure(self.arena.allocator(), gas);
                }

                // Transfer balance using snapshot mechanism for proper revert handling
                self.setBalanceWithSnapshot(frame_caller, caller_balance - value) catch {
                    return makeFailure(self.arena.allocator(), gas);
                };
                const callee_balance = if (self.host) |h| h.getBalance(address) else self.balances.get(address) orelse 0;
                self.setBalanceWithSnapshot(address, callee_balance + value) catch {
                    return makeFailure(self.arena.allocator(), gas);
                };
            }

            // Get code for the target address
            const code = self.get_code(address);
            if (code.len == 0) {
                // Check for JavaScript custom precompile handler first
                const root_c = @import("root_c.zig");
                var output_len: usize = 0;
                var output_ptr: [*]u8 = undefined;
                var gas_used: u64 = 0;

                if (root_c.tryCallJsPrecompileHandler(
                    &address.bytes,
                    input.ptr,
                    input.len,
                    gas,
                    &output_len,
                    &output_ptr,
                    &gas_used,
                )) {
                    // JavaScript precompile handler executed successfully
                    const output = if (output_len > 0) output_ptr[0..output_len] else &[_]u8{};
                    return CallResult{
                        .success = true,
                        .gas_left = gas - gas_used,
                        .output = output,
                    };
                }

                // Check for config-based precompile override (native Zig handlers)
                if (self.getPrecompileOverride(address)) |override| {
                    const result = override.execute(
                        override.context,
                        self.arena.allocator(),
                        input,
                        gas,
                    ) catch |err| {
                        std.debug.print("Custom precompile execution error: {}\n", .{err});
                        return makeFailure(self.arena.allocator(), 0);
                    };

                    return CallResult{
                        .success = true,
                        .gas_left = gas - result.gas_used,
                        .output = result.output,
                    };
                }

                // Check if this is a standard precompile address (hardfork-aware)
                if (precompiles.isPrecompile(address, self.hardfork)) {
                    // Use the precompiles module to handle all precompile execution
                    const result = precompiles.execute(
                        self.arena.allocator(),
                        address,
                        input,
                        gas,
                        self.hardfork,
                    ) catch |err| {
                        // On error, return failure
                        std.debug.print("Precompile execution error: {}\n", .{err});
                        return makeFailure(self.arena.allocator(), 0);
                    };

                    return CallResult{
                        .success = true,
                        .gas_left = gas - result.gas_used,
                        .output = result.output,
                    };
                }

                // For non-precompile empty accounts, return success with no output
                return CallResult.success_empty(self.arena.allocator(), gas) catch CallResult{
                    .success = true,
                    .gas_left = gas,
                    .output = &.{},
                };
            }

            // Create and push frame onto stack
            // Use execution_caller and execution_address which are determined by call_type

            // Determine if this call should be static
            // STATICCALL creates a static context, and static context propagates to all nested calls
            const parent_is_static = if (self.getCurrentFrame()) |frame| frame.is_static else false;
            const is_static = parent_is_static or call_type == .StaticCall;

            // Safely cast gas to i64 - if it exceeds i64::MAX, cap it (shouldn't happen in practice)
            const frame_gas = std.math.cast(i64, gas) orelse std.math.maxInt(i64);
            self.frames.append(self.arena.allocator(), FrameType.init(
                self.arena.allocator(),
                code,
                frame_gas,
                execution_caller,
                execution_address,
                value,
                input,
                @as(*anyopaque, @ptrCast(self)),
                self.hardfork,
                is_static,
            ) catch {
                return makeFailure(self.arena.allocator(), 0);
            }) catch {
                return makeFailure(self.arena.allocator(), 0);
            };
            errdefer _ = self.frames.pop();

            // Execute frame (don't cache pointer - it may become invalid during nested calls)
            self.frames.items[self.frames.items.len - 1].execute() catch {
                _ = self.frames.pop();

                // Restore gas refunds on failure
                // Per Python: incorporate_child_on_error does NOT add child's refund_counter
                self.gas_refund = refund_snapshot;

                // Restore warm addresses and storage slots on failure (EIP-2929)
                self.access_list_manager.restore(access_list_snapshot) catch {
                    return makeFailure(self.arena.allocator(), 0);
                };

                // Restore storage on failure
                // IMPORTANT: Identify slots to delete BEFORE restoring original_storage
                // First, identify slots that were added during the call (exist in original_storage but not in snapshot)
                var added_slots = std.ArrayList(StorageKey){};
                added_slots.ensureTotalCapacity(self.arena.allocator(), 10) catch {
                    return makeFailure(self.arena.allocator(), 0);
                };
                var orig_check_it = self.storage.original_storage.iterator();
                while (orig_check_it.next()) |entry| {
                    if (!original_storage_snapshot.contains(entry.key_ptr.*)) {
                        added_slots.append(self.arena.allocator(), entry.key_ptr.*) catch {
                            return makeFailure(self.arena.allocator(), 0);
                        };
                    }
                }

                // Second, restore original_storage to remove entries added during the call
                self.storage.original_storage.clearRetainingCapacity();
                var original_storage_restore_it = original_storage_snapshot.iterator();
                while (original_storage_restore_it.next()) |entry| {
                    self.storage.original_storage.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                        return makeFailure(self.arena.allocator(), 0);
                    };
                }

                // Third, restore storage values from snapshot
                var storage_restore_it = storage_snapshot.iterator();
                while (storage_restore_it.next()) |entry| {
                    if (self.host) |h| {
                        const addr = primitives.Address{ .bytes = entry.key_ptr.*.address };
                        h.setStorage(addr, entry.key_ptr.*.slot, entry.value_ptr.*);
                    } else {
                        self.storage.storage.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                            return makeFailure(self.arena.allocator(), 0);
                        };
                    }
                }

                // Fourth, delete slots that were added during the call
                for (added_slots.items) |slot_key| {
                    if (self.host) |h| {
                        h.setStorage(Address{ .bytes = slot_key.address }, slot_key.slot, 0);
                    } else {
                        _ = self.storage.storage.remove(slot_key);
                    }
                }

                // Restore balances on failure (handles SELFDESTRUCT balance transfers)
                var balance_restore_it = balance_snapshot.iterator();
                while (balance_restore_it.next()) |entry| {
                    if (self.host) |h| {
                        h.setBalance(entry.key_ptr.*, entry.value_ptr.*);
                    } else {
                        self.balances.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                            return makeFailure(self.arena.allocator(), 0);
                        };
                    }
                }

                // Restore transient storage on failure (EIP-1153)
                self.storage.clearTransient();
                var restore_it = transient_snapshot.iterator();
                while (restore_it.next()) |entry| {
                    self.storage.transient.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                        // Critical: cannot restore transient storage - return failure with remaining gas
                        return makeFailure(self.arena.allocator(), 0);
                    };
                }

                return makeFailure(self.arena.allocator(), 0);
            };

            // Get frame results (refetch pointer after execution)
            const frame = &self.frames.items[self.frames.items.len - 1];

            // Store return data
            const output = if (frame.output.len > 0) blk: {
                const output_copy = self.arena.allocator().alloc(u8, frame.output.len) catch {
                    // Allocation failed - return empty output
                    break :blk &[_]u8{};
                };
                @memcpy(output_copy, frame.output);
                break :blk output_copy;
            } else &[_]u8{};

            // Return result
            const result = CallResult{
                .success = !frame.reverted,
                .gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0))),
                .output = output,
            };
            // std.debug.print("DEBUG inner_call result: address={any} success={} reverted={} frames={}\n", .{address.bytes, result.success, frame.reverted, self.frames.items.len});

            // Restore gas refunds on revert
            // Per Python: incorporate_child_on_error does NOT add child's refund_counter
            // This applies to both reverts and exceptional halts
            if (frame.reverted) {
                self.gas_refund = refund_snapshot;
            }

            // Restore warm addresses and storage slots on revert (EIP-2929)
            if (frame.reverted) {
                self.access_list_manager.restore(access_list_snapshot) catch {
                    return makeFailure(self.arena.allocator(), 0);
                };
            }

            // Restore storage on revert
            if (frame.reverted) {
                // IMPORTANT: Identify slots to delete BEFORE restoring original_storage
                // First, identify slots that were added during the call (exist in original_storage but not in snapshot)
                var added_slots = std.ArrayList(StorageKey){};
                added_slots.ensureTotalCapacity(self.arena.allocator(), 10) catch {
                    return makeFailure(self.arena.allocator(), 0);
                };
                var orig_check_it = self.storage.original_storage.iterator();
                while (orig_check_it.next()) |entry| {
                    if (!original_storage_snapshot.contains(entry.key_ptr.*)) {
                        added_slots.append(self.arena.allocator(), entry.key_ptr.*) catch {
                            return makeFailure(self.arena.allocator(), 0);
                        };
                    }
                }

                // Second, restore original_storage to remove entries added during the call
                self.storage.original_storage.clearRetainingCapacity();
                var original_storage_restore_it = original_storage_snapshot.iterator();
                while (original_storage_restore_it.next()) |entry| {
                    self.storage.original_storage.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                        return makeFailure(self.arena.allocator(), 0);
                    };
                }

                // Third, restore storage values from snapshot
                var storage_restore_it = storage_snapshot.iterator();
                while (storage_restore_it.next()) |entry| {
                    if (self.host) |h| {
                        const addr = primitives.Address{ .bytes = entry.key_ptr.*.address };
                        h.setStorage(addr, entry.key_ptr.*.slot, entry.value_ptr.*);
                    } else {
                        self.storage.storage.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                            return makeFailure(self.arena.allocator(), 0);
                        };
                    }
                }

                // Fourth, delete slots that were added during the call
                for (added_slots.items) |slot_key| {
                    if (self.host) |h| {
                        h.setStorage(Address{ .bytes = slot_key.address }, slot_key.slot, 0);
                    } else {
                        _ = self.storage.storage.remove(slot_key);
                    }
                }
            }

            // Restore transient storage on revert (EIP-1153)
            if (frame.reverted) {
                self.storage.clearTransient();
                var restore_it = transient_snapshot.iterator();
                while (restore_it.next()) |entry| {
                    self.storage.transient.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                        return makeFailure(self.arena.allocator(), 0);
                    };
                }
            }

            // Restore selfdestructed_accounts on revert (EIP-6780)
            // This ensures that SELFDESTRUCT operations in reverted calls don't affect the final state
            if (frame.reverted) {
                self.selfdestructed_accounts.clearRetainingCapacity();
                var restore_selfdestruct_it = selfdestruct_snapshot.iterator();
                while (restore_selfdestruct_it.next()) |entry| {
                    self.selfdestructed_accounts.put(entry.key_ptr.*, {}) catch {
                        return makeFailure(self.arena.allocator(), 0);
                    };
                }
            }

            // Restore balances on revert (handles SELFDESTRUCT balance transfers and value transfers)
            if (frame.reverted) {
                var balance_restore_it = balance_snapshot.iterator();
                while (balance_restore_it.next()) |entry| {
                    if (self.host) |h| {
                        h.setBalance(entry.key_ptr.*, entry.value_ptr.*);
                    } else {
                        self.balances.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                            return makeFailure(self.arena.allocator(), 0);
                        };
                    }
                }
            }

            // Pop frame from stack
            _ = self.frames.pop();

            // No cleanup needed - arena handles it
            return result;
        }

        /// Handle CREATE operation (contract creation)
        pub fn inner_create(
            self: *Self,
            value: u256,
            init_code: []const u8,
            gas: u64,
            salt: ?u256,
        ) errors.CallError!struct { address: primitives.Address, success: bool, gas_left: u64, output: []const u8 } {
            // Track if this is a top-level create (contract-creation transaction)
            // We detect this when there is no active frame yet.
            // Used to avoid double-incrementing the sender's nonce (runner already increments it)
            const is_top_level_create = self.frames.items.len == 0;
            // Check call depth (STACK_DEPTH_LIMIT = 1024)
            // Per Python reference (system.py:97-99), depth exceeded refunds gas
            if (self.frames.items.len >= 1024) {
                return .{
                    .address = primitives.ZERO_ADDRESS,
                    .success = false,
                    .gas_left = gas,
                    .output = &[_]u8{},
                };
            }

            // Get caller from current frame
            const caller = if (self.getCurrentFrame()) |frame| frame.address else self.origin;

            // Check sender's nonce for overflow (max nonce is 2^64 - 1)
            const sender_nonce = if (self.host) |h|
                h.getNonce(caller)
            else
                self.nonces.get(caller) orelse 0;

            if (sender_nonce == std.math.maxInt(u64)) {
                // Nonce overflow - CREATE fails, return gas
                return .{
                    .address = primitives.ZERO_ADDRESS,
                    .success = false,
                    .gas_left = gas,
                    .output = &[_]u8{},
                };
            }

            // Handle balance transfer if value > 0
            if (value > 0) {
                const caller_balance = if (self.host) |h| h.getBalance(caller) else self.balances.get(caller) orelse 0;
                if (caller_balance < value) {
                    // Insufficient balance - CREATE fails
                    return .{
                        .address = primitives.ZERO_ADDRESS,
                        .success = false,
                        .gas_left = gas,
                        .output = &[_]u8{},
                    };
                }
                // Note: balance transfer happens after we know the new address
            }

            // Calculate new contract address
            const new_address = if (salt) |s| blk: {
                // CREATE2: keccak256(0xff ++ caller ++ salt ++ keccak256(init_code))[12:]
                var hash_input = std.ArrayList(u8){};
                defer hash_input.deinit(self.arena.allocator());

                try hash_input.append(self.arena.allocator(), 0xff);
                try hash_input.appendSlice(self.arena.allocator(), &caller.bytes);

                // Add salt (32 bytes, big-endian)
                var salt_bytes: [32]u8 = undefined;
                var i: usize = 0;
                while (i < 32) : (i += 1) {
                    salt_bytes[31 - i] = @as(u8, @truncate(s >> @intCast(i * 8)));
                }
                try hash_input.appendSlice(self.arena.allocator(), &salt_bytes);

                // Add keccak256(init_code)
                var code_hash: [32]u8 = undefined;
                std.crypto.hash.sha3.Keccak256.hash(init_code, &code_hash, .{});
                try hash_input.appendSlice(self.arena.allocator(), &code_hash);

                // Hash and take last 20 bytes
                var addr_hash: [32]u8 = undefined;
                std.crypto.hash.sha3.Keccak256.hash(hash_input.items, &addr_hash, .{});

                var addr_bytes: [20]u8 = undefined;
                @memcpy(&addr_bytes, addr_hash[12..32]);
                break :blk primitives.Address{ .bytes = addr_bytes };
            } else blk: {
                // CREATE: keccak256(rlp([sender, nonce]))[12:]
                // For top-level creates: nonce was already incremented by runner, so subtract 1
                // For opcode creates: use current nonce (will be incremented after collision check)
                // Per Python reference (message.py:57): uses "nonce - 1" for transactions
                var nonce = if (self.host) |h|
                    h.getNonce(caller)
                else
                    self.nonces.get(caller) orelse 0;

                if (is_top_level_create) {
                    nonce -= 1; // Undo the increment that runner already did
                }

                // Manually construct RLP encoding of [address_bytes, nonce]
                // Address is 20 bytes, nonce is variable length
                var rlp_data = std.ArrayList(u8){};
                defer rlp_data.deinit(self.arena.allocator());

                // Encode address (20 bytes, 0x80 + 20 = 0x94)
                try rlp_data.append(self.arena.allocator(), 0x94);
                try rlp_data.appendSlice(self.arena.allocator(), &caller.bytes);

                // Encode nonce (RLP encoding for integers)
                if (nonce == 0) {
                    try rlp_data.append(self.arena.allocator(), 0x80); // Empty byte string
                } else if (nonce < 0x80) {
                    try rlp_data.append(self.arena.allocator(), @as(u8, @intCast(nonce)));
                } else {
                    // Multi-byte nonce - encode as big-endian bytes with length prefix
                    // First, determine the minimum number of bytes needed
                    var nonce_bytes: [8]u8 = undefined;
                    var nonce_len: usize = 0;
                    var temp_nonce = nonce;

                    // Convert to big-endian bytes, skipping leading zeros
                    var i: usize = 8;
                    while (i > 0) : (i -= 1) {
                        const byte = @as(u8, @truncate(temp_nonce & 0xFF));
                        nonce_bytes[i - 1] = byte;
                        temp_nonce >>= 8;
                        if (temp_nonce == 0 and nonce_len == 0) {
                            nonce_len = i;
                        }
                    }

                    const start_idx = nonce_len;
                    const byte_count = 8 - start_idx;

                    // RLP: 0x80 + length, then the bytes
                    try rlp_data.append(self.arena.allocator(), @as(u8, @intCast(0x80 + byte_count)));
                    try rlp_data.appendSlice(self.arena.allocator(), nonce_bytes[start_idx..]);
                }

                // Wrap in list prefix
                const total_len = rlp_data.items.len;
                var final_rlp = std.ArrayList(u8){};
                defer final_rlp.deinit(self.arena.allocator());
                try final_rlp.append(self.arena.allocator(), @as(u8, @intCast(0xc0 + total_len))); // List with length
                try final_rlp.appendSlice(self.arena.allocator(), rlp_data.items);

                // Hash and take last 20 bytes
                var addr_hash: [32]u8 = undefined;
                std.crypto.hash.sha3.Keccak256.hash(final_rlp.items, &addr_hash, .{});

                var addr_bytes: [20]u8 = undefined;
                @memcpy(&addr_bytes, addr_hash[12..32]);
                break :blk primitives.Address{ .bytes = addr_bytes };
            };

            // EIP-3860: Check init code size limit (Shanghai and later)
            // Per Python reference (system.py:81-82): This check happens IMMEDIATELY after reading call_data
            // and BEFORE any nonce increments or child call gas calculation
            // When this check fails, it raises OutOfGasError in the PARENT frame (the frame executing CREATE)
            // This halts the entire parent frame, not just the CREATE operation
            if (self.hardfork.isAtLeast(.SHANGHAI)) {
                // Check must use >= to match reference implementation exactly
                // MAX_INITCODE_SIZE is the maximum ALLOWED, so > is correct
                if (init_code.len > primitives.GasConstants.MaxInitcodeSize) {
                    // Per Python reference: OutOfGasError is raised, halting the parent frame
                    // The initcode gas was already charged in frame.zig
                    return error.OutOfGas;
                }
            }

            // EIP-3860 initcode cost is charged in two different places depending on context:
            // 1. For top-level creates (contract creation transactions): charged in transaction intrinsic gas
            // 2. For CREATE/CREATE2 opcodes: charged in frame.zig before calling inner_create
            // Therefore, DO NOT charge it again here for top-level creates
            const child_gas: u64 = gas;

            // EIP-2929 (Berlin): Mark created address as warm
            // Per Python reference: accessed_addresses.add(contract_address) happens
            // BEFORE collision check and nonce increment
            if (self.hardfork.isAtLeast(.BERLIN)) {
                try self.access_list_manager.preWarmAddresses(&[_]primitives.Address{new_address});
            }

            // Check for address collision (code, nonce, or storage already exists)
            // Per EIP-684: If account has code or nonce, CREATE fails
            const has_collision = blk: {
                if (self.host) |h| {
                    const has_code = h.getCode(new_address).len > 0;
                    const has_nonce = h.getNonce(new_address) > 0;
                    break :blk has_code or has_nonce;
                } else {
                    const has_code = (self.code.get(new_address) orelse &[_]u8{}).len > 0;
                    const has_nonce = (self.nonces.get(new_address) orelse 0) > 0;
                    break :blk has_code or has_nonce;
                }
            };

            if (has_collision) {
                // Collision detected - increment caller's nonce and return failure
                // Per Python reference (system.py:107-110): nonce is incremented even on collision
                // But only for CREATE/CREATE2 opcodes, not for top-level creates (already incremented by runner)
                if (!is_top_level_create) {
                    const caller_nonce = if (self.host) |h|
                        h.getNonce(caller)
                    else
                        self.nonces.get(caller) orelse 0;

                    if (self.host) |h| {
                        h.setNonce(caller, caller_nonce + 1);
                    } else {
                        try self.nonces.put(caller, caller_nonce + 1);
                    }
                }

                // Per Python reference (system.py:105-112): On collision, the gas is NOT refunded.
                // Line 86 deducts create_message_gas, and line 111-112 returns without refunding.
                // Therefore, we return gas_left = 0 to indicate all gas was consumed.
                return .{
                    .address = primitives.ZERO_ADDRESS,
                    .success = false,
                    .gas_left = 0,
                    .output = &[_]u8{},
                };
            }

            // Increment caller's nonce for CREATE/CREATE2 opcodes (but not top-level creates)
            // Per Python reference:
            // - fork.py:546 increments sender nonce for transactions (done by runner before calling this)
            // - system.py:113 increments caller nonce for CREATE/CREATE2 opcodes
            // For top-level creates: nonce already incremented in transaction processing (runner.zig:988-990)
            // For opcode creates: nonce must be incremented here
            if (!is_top_level_create) {
                const caller_nonce = if (self.host) |h|
                    h.getNonce(caller)
                else
                    self.nonces.get(caller) orelse 0;

                if (self.host) |h| {
                    h.setNonce(caller, caller_nonce + 1);
                } else {
                    try self.nonces.put(caller, caller_nonce + 1);
                }
            }

            // Set nonce of new contract to 1 (EVM spec: contracts start with nonce 1)
            if (self.host) |h| {
                h.setNonce(new_address, 1);
            } else {
                try self.nonces.put(new_address, 1);
            }

            // EIP-6780 (Cancun): Mark account as created BEFORE execution
            // Per Python reference (interpreter.py:174): mark_account_created happens BEFORE process_message
            // "The marker is not removed even if the account creation reverts"
            // This is required for SELFDESTRUCT to correctly identify same-tx creations
            try self.created_accounts.put(new_address, {});

            // Snapshot gas refunds before executing init code
            // Per Python reference (vm/__init__.py:incorporate_child_on_error), failed creates do not
            // propagate refunds to parent. Only incorporate_child_on_success adds child refunds.
            const refund_snapshot = self.gas_refund;

            // Snapshot warm addresses and storage slots before executing init code (EIP-2929)
            // Per Python reference (incorporate_child_on_error), accessed_addresses
            // and accessed_storage_keys are only propagated on success, not on failure
            var access_list_snapshot = try self.access_list_manager.snapshot();
            defer access_list_snapshot.deinit();

            // Snapshot balances before execution (for SELFDESTRUCT revert handling)
            // We use copy-on-write: addresses are snapshotted when first modified via setBalanceWithSnapshot
            var balance_snapshot = std.AutoHashMap(primitives.Address, u256).init(self.arena.allocator());

            // Push the snapshot onto the stack so nested calls can snapshot in parent snapshots
            try self.balance_snapshot_stack.append(self.arena.allocator(), &balance_snapshot);
            defer _ = self.balance_snapshot_stack.pop();

            // Transfer balance if value > 0 using snapshot mechanism for proper revert handling
            if (value > 0) {
                const caller_balance = if (self.host) |h| h.getBalance(caller) else self.balances.get(caller) orelse 0;
                try self.setBalanceWithSnapshot(caller, caller_balance - value);
                const new_addr_balance = if (self.host) |h| h.getBalance(new_address) else self.balances.get(new_address) orelse 0;
                try self.setBalanceWithSnapshot(new_address, new_addr_balance + value);
            }

            // Snapshot selfdestructed_accounts before executing init code (EIP-6780 revert handling)
            // If CREATE fails, any SELFDESTRUCTs in the init code must be reverted
            var create_selfdestruct_snapshot = std.AutoHashMap(primitives.Address, void).init(self.arena.allocator());
            var create_selfdestruct_it = self.selfdestructed_accounts.iterator();
            while (create_selfdestruct_it.next()) |entry| {
                try create_selfdestruct_snapshot.put(entry.key_ptr.*, {});
            }

            // Execute initialization code
            try self.frames.append(self.arena.allocator(), try FrameType.init(
                self.arena.allocator(),
                init_code,
                @intCast(child_gas),
                caller,
                new_address,
                value,
                &[_]u8{}, // no calldata for CREATE
                @as(*anyopaque, @ptrCast(self)),
                self.hardfork,
                false, // CREATE/CREATE2 are never static (can't create contracts in static context)
            ));
            errdefer _ = self.frames.pop();

            // Execute frame
            self.frames.items[self.frames.items.len - 1].execute() catch {
                const failed_frame = &self.frames.items[self.frames.items.len - 1];
                const error_output = failed_frame.output; // Capture output before popping
                _ = self.frames.pop();

                // Revert nonce on execution error
                if (self.host) |h| {
                    h.setNonce(new_address, 0);
                } else {
                    _ = self.nonces.remove(new_address);
                }

                // Restore gas refunds on failure
                // Per Python: incorporate_child_on_error does NOT add child's refund_counter
                self.gas_refund = refund_snapshot;

                // Restore warm addresses and storage slots on failure (EIP-2929)
                try self.access_list_manager.restore(access_list_snapshot);

                // Restore balances on error (handles SELFDESTRUCT balance transfers and value transfers)
                var balance_restore_it = balance_snapshot.iterator();
                while (balance_restore_it.next()) |entry| {
                    if (self.host) |h| {
                        h.setBalance(entry.key_ptr.*, entry.value_ptr.*);
                    } else {
                        try self.balances.put(entry.key_ptr.*, entry.value_ptr.*);
                    }
                }

                return .{
                    .address = primitives.ZERO_ADDRESS,
                    .success = false,
                    .gas_left = 0,
                    .output = error_output,
                };
            };

            // Get frame results
            const frame = &self.frames.items[self.frames.items.len - 1];
            var gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
            var success = !frame.reverted;
            const frame_output = frame.output; // Capture output

            // If successful, check deposit cost and code size, then deploy
            if (success) {
                // Charge code deposit cost (200 gas per byte) if there's output
                if (frame_output.len > 0) {
                    const deposit_cost = @as(u64, @intCast(frame_output.len)) * GasConstants.CreateDataGas;
                    if (gas_left < deposit_cost) {
                        // Out of gas during code deposit -> creation fails
                        success = false;
                        gas_left = 0;
                    }
                }

                if (success and frame_output.len > 0) {
                    // Check code size limit (EIP-170: 24576 bytes)
                    const max_code_size = 24576;
                    if (frame_output.len > max_code_size) {
                        _ = self.frames.pop();

                        // Revert nonce on failure
                        if (self.host) |h| {
                            h.setNonce(new_address, 0);
                        } else {
                            _ = self.nonces.remove(new_address);
                        }

                        // Restore gas refunds on failure
                        // Per Python: incorporate_child_on_error does NOT add child's refund_counter
                        self.gas_refund = refund_snapshot;

                        // Restore warm addresses and storage slots on failure (EIP-2929)
                        try self.access_list_manager.restore(access_list_snapshot);

                        // Restore balances on failure (handles SELFDESTRUCT balance transfers and value transfers)
                        var balance_restore_it = balance_snapshot.iterator();
                        while (balance_restore_it.next()) |entry| {
                            if (self.host) |h| {
                                h.setBalance(entry.key_ptr.*, entry.value_ptr.*);
                            } else {
                                try self.balances.put(entry.key_ptr.*, entry.value_ptr.*);
                            }
                        }

                        // Restore selfdestructed_accounts on failure (EIP-6780)
                        self.selfdestructed_accounts.clearRetainingCapacity();
                        var restore_create_selfdestruct_it = create_selfdestruct_snapshot.iterator();
                        while (restore_create_selfdestruct_it.next()) |entry| {
                            try self.selfdestructed_accounts.put(entry.key_ptr.*, {});
                        }

                        // Per Python reference: code size violation raises OutOfGasError, consuming all gas
                        // execution-specs/src/ethereum/forks/constantinople/vm/interpreter.py
                        return .{
                            .address = primitives.ZERO_ADDRESS,
                            .success = false,
                            .gas_left = 0, // Consume all remaining gas on code size violation
                            .output = frame_output,
                        };
                    }

                    // Deploy code and deduct deposit gas
                    if (self.host) |h| {
                        // When using a host, update host's code directly
                        h.setCode(new_address, frame_output);
                    } else {
                        // When not using a host, store in EVM's code map
                        const code_copy = try self.arena.allocator().alloc(u8, frame_output.len);
                        @memcpy(code_copy, frame_output);
                        try self.code.put(new_address, code_copy);
                    }
                    const deposit_cost = @as(u64, @intCast(frame_output.len)) * GasConstants.CreateDataGas;
                    gas_left -= deposit_cost;
                } else if (success) {
                    // Deploy empty code (output.len == 0)
                    if (self.host) |h| {
                        h.setCode(new_address, &[_]u8{});
                    } else {
                        try self.code.put(new_address, &[_]u8{});
                    }
                }
            } else {
                // Reverse state changes on revert
                // Revert nonce to 0
                if (self.host) |h| {
                    h.setNonce(new_address, 0);
                } else {
                    _ = self.nonces.remove(new_address);
                }

                // Restore balances on revert (handles SELFDESTRUCT balance transfers and value transfers)
                var balance_restore_it = balance_snapshot.iterator();
                while (balance_restore_it.next()) |entry| {
                    if (self.host) |h| {
                        h.setBalance(entry.key_ptr.*, entry.value_ptr.*);
                    } else {
                        try self.balances.put(entry.key_ptr.*, entry.value_ptr.*);
                    }
                }

                // Restore selfdestructed_accounts on failure (EIP-6780)
                self.selfdestructed_accounts.clearRetainingCapacity();
                var restore_create_selfdestruct_it = create_selfdestruct_snapshot.iterator();
                while (restore_create_selfdestruct_it.next()) |entry| {
                    try self.selfdestructed_accounts.put(entry.key_ptr.*, {});
                }
            }

            // Pop frame
            _ = self.frames.pop();

            // According to EIP-1014 and CREATE semantics:
            // - On success: return_data should be empty
            // - On failure/revert: return_data should contain the child's output
            return .{
                .address = if (success) new_address else primitives.ZERO_ADDRESS,
                .success = success,
                .gas_left = gas_left,
                .output = if (success) &[_]u8{} else frame_output,
            };
        }

        /// Add gas refund (called by frame)
        pub fn add_refund(self: *Self, amount: u64) void {
            self.gas_refund += amount;
        }

        pub fn sub_refund(self: *Self, amount: u64) void {
            self.gas_refund -= amount;
        }

        /// Get balance of an address (called by frame)
        pub fn get_balance(self: *Self, address: primitives.Address) u256 {
            if (self.host) |h| return h.getBalance(address);
            return self.balances.get(address) orelse 0;
        }

        /// Get code for an address
        /// EIP-7702: Handle delegation designation (0xef0100 + address)
        pub fn get_code(self: *Self, address: primitives.Address) []const u8 {
            const raw_code = if (self.host) |h|
                h.getCode(address)
            else
                self.code.get(address) orelse &[_]u8{};

            // EIP-7702: Check for delegation designation (Prague+)
            if (self.hardfork.isAtLeast(.PRAGUE) and raw_code.len == 23 and
                raw_code[0] == 0xef and raw_code[1] == 0x01 and raw_code[2] == 0x00)
            {
                // Extract delegated address (bytes 3-22, 20 bytes)
                var delegated_addr: primitives.Address = undefined;
                @memcpy(&delegated_addr.bytes, raw_code[3..23]);

                // Recursively get code from delegated address
                // Note: We don't recurse infinitely - if delegated address also has
                // delegation designation, we return its delegation code as-is
                const delegated_code = if (self.host) |h|
                    h.getCode(delegated_addr)
                else
                    self.code.get(delegated_addr) orelse &[_]u8{};

                return delegated_code;
            }

            return raw_code;
        }

        /// Get current frame (top of the frame stack)
        pub fn getCurrentFrame(self: *Self) ?*FrameType {
            if (self.frames.items.len > 0) return &self.frames.items[self.frames.items.len - 1];
            return null;
        }

        /// Get current frame's PC (for tracer)
        pub fn getPC(self: *const Self) u32 {
            if (self.frames.items.len > 0) {
                return self.frames.items[self.frames.items.len - 1].pc;
            }
            return 0;
        }

        /// Get current frame's bytecode (for tracer)
        pub fn getBytecode(self: *const Self) []const u8 {
            if (self.frames.items.len > 0) {
                return self.frames.items[self.frames.items.len - 1].bytecode;
            }
            return &[_]u8{};
        }

        /// Execute a single step (for tracer)
        pub fn step(self: *Self) !void {
            if (self.getCurrentFrame()) |frame| {
                try frame.step();
            }
        }
    };
}
