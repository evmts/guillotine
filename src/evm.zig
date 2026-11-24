const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const primitives = @import("voltaire");
const eips = @import("eips_and_hardforks/eips.zig");
const BlockInfo = @import("block/block_info.zig").BlockInfo(.{});
const Database = @import("storage/database.zig").Database;
const Account = @import("storage/database_interface_account.zig").Account;
const SelfDestruct = @import("storage/self_destruct.zig").SelfDestruct;
const CreatedContracts = @import("storage/created_contracts.zig").CreatedContracts;
const AccessList = @import("storage/access_list.zig").AccessList;
const Hardfork = @import("eips_and_hardforks/eips.zig").Hardfork;
const precompiles = @import("precompiles");
const EvmConfig = @import("evm_config.zig").EvmConfig;
const TransactionContext = @import("block/transaction_context.zig").TransactionContext;
const GrowingArenaAllocator = @import("evm_arena_allocator.zig").GrowingArenaAllocator;
const call_result_module = @import("frame/call_result.zig");
const call_params_module = @import("frame/call_params.zig");

/// Creates a configured EVM instance type.
pub fn Evm(config: EvmConfig) type {
    return struct {
        const Self = @This();

        pub const Frame = @import("frame/frame.zig").Frame(config.frame_config(), Self);
        const NativeBridge = @import("jit_bridge.zig").Bridge(Self, Frame);
        pub const Bytecode = @import("bytecode/bytecode.zig").Bytecode(.{
            .max_bytecode_size = config.max_bytecode_size,
            .max_initcode_size = config.max_initcode_size,
            .fusions_enabled = config.enable_fusion,
        });

        pub const CallResult = call_result_module.CallResult(config);
        pub const CallParams = call_params_module.CallParams(config);

        pub const Journal: type = @import("storage/journal.zig").Journal(.{
            .SnapshotIdType = if (config.max_call_depth <= 255) u8 else u16,
            .WordType = config.WordType,
            .NonceType = u64,
            .initial_capacity = 128,
        });
        const CallStackEntry = struct {
            address: primitives.Address,
            caller: primitives.Address,
            value: config.WordType,
            is_static: bool, // EIP-214: Track static context per call level
        };
        const empty_call_stack_entry = CallStackEntry{
            .address = primitives.Address.ZERO_ADDRESS,
            .caller = primitives.Address.ZERO_ADDRESS,
            .value = 0,
            .is_static = false,
        };

        /// Dispatch schedule and jump table built once per deployed code hash and reused
        /// for the lifetime of the EVM. `code` is an owned copy compared byte-for-byte on
        /// every hit, so a database whose code hash does not match its code can never
        /// execute a schedule built for different bytecode.
        const CachedAnalysis = struct {
            schedule: Frame.Dispatch.DispatchSchedule,
            jump_table: Frame.Dispatch.JumpTable,
            code: []u8,
        };
        /// Maximum distinct contracts in the analysis cache. When full, new code runs
        /// uncached; entries are never evicted while frames may still reference them.
        const MAX_CACHED_CONTRACTS: usize = 256;
        /// Call depth at which execution hops once onto a large native stack.
        const LARGE_STACK_DEPTH: u11 = 16;
        /// Native stack size for the deep-call worker thread (covers the 1024 EVM depth limit).
        const LARGE_STACK_SIZE: usize = 64 * 1024 * 1024;
        const can_spawn_threads = !builtin.single_threaded and !builtin.cpu.arch.isWasm() and builtin.target.os.tag != .freestanding;
        /// BLOCKHASH serves the hashes of the 256 most recent complete blocks.
        const RECENT_BLOCK_HASHES: u64 = 256;
        /// One ring slot of `recent_block_hashes`; `number` confirms the slot's block.
        const RecentBlockHash = struct {
            number: u64 = 0,
            hash: [32]u8 = [_]u8{0} ** 32,
            known: bool = false,
        };
        /// Pooled memory buffers above this capacity are released at transaction end.
        const POOL_IDLE_MEMORY_CAP: usize = 64 * 1024;

        pub const Success = enum {
            Stop,
            Return,
            SelfDestruct,
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
            AllocationError,
            AccountNotFound,
            InvalidJumpDestination,
            MissingJumpDestMetadata,
            InitcodeTooLarge,
            TruncatedPush,
            OutOfBounds,
            WriteProtection,
            BytecodeTooLarge,
            DatabaseRequired,
            ReturnDataNotAvailable,
        };

        // Cache line 1 - EXECUTION CONTROL: Accessed frequently during execution
        /// Current call depth (0 = root call) - tracks active stack depth
        depth: u11, // Supports up to 2048 depth, more than EVM's 1024 limit
        /// Call stack - tracks caller and value for each call depth
        call_stack: [config.max_call_depth]CallStackEntry,
        /// Current return data from last call (empty if no return data available)
        return_data: std.ArrayList(u8),
        /// Allocator for dynamic memory
        allocator: std.mem.Allocator, // 16 bytes (vtable ptr + context ptr)

        // Cache line 2 - STORAGE OPERATIONS: All accessed together for SLOAD/SSTORE
        /// Database interface for state storage
        database: *Database, // 8 bytes
        /// Access list for tracking warm/cold access (EIP-2929)
        access_list: AccessList, // ~40 bytes (2 hashmaps)
        /// Current snapshot ID for the active call frame
        current_snapshot_id: Journal.SnapshotIdType, // 1-2 bytes (u8 or u16)
        /// Set by `call()` after it increments the transaction sender's nonce. A top-level
        /// CREATE transaction must derive its address from the nonce before that increment
        /// and must not increment it again; `beginCreate` consumes the flag.
        tx_sender_nonce_incremented: bool,
        /// Gas refund counter for SSTORE operations
        gas_refund_counter: u64, // 8 bytes

        // Cache line 3+ - STATE TRACKING: Transaction-level state changes
        /// Journal for tracking state changes and snapshots
        journal: Journal, // Variable size
        /// Logs emitted during the current call (accessed for LOG0-LOG4 opcodes)
        logs: std.ArrayList(@import("frame/call_result.zig").Log),
        /// Tracks contracts created in current transaction (EIP-6780)
        created_contracts: CreatedContracts,

        // Cache line 4+ - TRANSACTION CONTEXT: Set once per transaction, rarely accessed
        /// Block information
        block_info: BlockInfo,
        /// Transaction context
        context: TransactionContext,
        /// Gas price for the transaction
        gas_price: u256,
        /// Origin address (sender of the transaction)
        origin: primitives.Address,

        // Cache line 5+ - COLD PATH: Large data structures accessed infrequently
        /// Growing arena allocator for per-call temporary allocations with 50% growth strategy
        call_arena: GrowingArenaAllocator,
        /// Contracts marked for self-destruction (cold - only used in old hardforks)
        self_destruct: SelfDestruct,

        // State dump tracking - persists across calls
        /// Tracks all addresses that have been touched (for state dump)
        touched_addresses: std.AutoHashMap(primitives.Address, void),
        /// Tracks storage slots that have been modified (address -> list of storage keys)
        touched_storage: std.AutoHashMap(primitives.Address, std.ArrayList(u256)),

        // Tracer - at the very bottom of memory layout for minimal impact on cache performance
        /// Tracer for debugging and logging - can be accessed via evm.tracer or frame.evm_ptr.tracer
        tracer: @import("tracer/tracer.zig").Tracer,

        // Performance state (EVM lifetime, owned by `allocator`)
        /// True while executing on the large-stack worker thread (see execute_frame).
        on_large_stack: bool = false,
        /// Host-provided hashes of recent blocks for BLOCKHASH (see `setBlockHash`).
        recent_block_hashes: [RECENT_BLOCK_HASHES]RecentBlockHash = [_]RecentBlockHash{.{}} ** RECENT_BLOCK_HASHES,
        /// Highest call depth reached since the call stack was last reset.
        tx_max_depth: u16 = 0,
        /// Analysis cache keyed by deployed code hash.
        analysis_cache: std.AutoHashMapUnmanaged([32]u8, *CachedAnalysis) = .{},
        /// Native JIT tier (hot pure-compute code). Owned by `allocator`.
        jit_bridge: if (config.enable_native_jit) NativeBridge else void,
        /// Per-depth stack buffers; index d serves frames at depth d + 1.
        stack_pool: [config.max_call_depth + 1]?[*]align(64) Frame.WordType = .{null} ** (config.max_call_depth + 1),
        /// Per-depth memory buffers; index d serves frames at depth d + 1. A child never
        /// shares a parent's buffer, so calldata slices into parent memory stay valid.
        memory_pool: [config.max_call_depth + 1]?*std.ArrayList(u8) = .{null} ** (config.max_call_depth + 1),
        /// Number of pool slots that may be populated (stack_pool/memory_pool[0..pool_max_depth]).
        pool_max_depth: u16 = 0,

        /// Initialize a new EVM instance.
        ///
        /// Sets up the execution environment with state storage, block context,
        /// and transaction parameters. The planner cache is initialized with
        /// a default size for bytecode optimization.
        /// If `gas_price` is null, the effective EIP-1559 gas price is derived
        /// from the block base fee and transaction fee caps. Returns
        /// error.GasPriceRequired when neither a gas price nor a fee cap exists.
        pub fn init(allocator: std.mem.Allocator, database: ?*Database, block_info: BlockInfo, context: TransactionContext, gas_price: ?u256, origin: primitives.Address) !Self {
            const effective_gas_price = gas_price orelse config.eips.effective_gas_price(
                block_info.base_fee,
                context.max_fee_per_gas orelse return error.GasPriceRequired,
                context.max_priority_fee_per_gas,
            ).effective_gas_price;

            var access_list = AccessList.init(allocator);
            errdefer access_list.deinit();

            const arena = try GrowingArenaAllocator.initWithMaxCapacity(
                allocator,
                config.arena_capacity_limit,
                config.arena_capacity_limit,
                config.arena_growth_factor,
            );

            var self = Self{
                .depth = 0,
                .call_stack = [_]CallStackEntry{empty_call_stack_entry} ** config.max_call_depth,
                .return_data = .{},
                .allocator = allocator,
                .database = database orelse return error.DatabaseRequired,
                .access_list = access_list,
                .current_snapshot_id = 0,
                .tx_sender_nonce_incremented = false,
                .gas_refund_counter = 0,
                .journal = try Journal.init(allocator),
                .logs = std.ArrayList(@import("frame/call_result.zig").Log).empty,
                .created_contracts = CreatedContracts.init(allocator),
                .block_info = block_info,
                .context = context,
                .gas_price = effective_gas_price,
                .origin = origin,
                .call_arena = arena,
                .self_destruct = SelfDestruct.init(allocator),
                .touched_addresses = std.AutoHashMap(primitives.Address, void).init(allocator),
                .touched_storage = std.AutoHashMap(primitives.Address, std.ArrayList(u256)).init(allocator),
                .tracer = @import("tracer/tracer.zig").Tracer.init(allocator, config.tracer_config),
                .jit_bridge = if (config.enable_native_jit) NativeBridge.init(allocator) else {},
            };

            // Do NOT store `&self.tracer` in `self.call_arena.tracer` here: `self` is
            // returned by value, so a self-referential pointer would dangle after `init`
            // returns. `callImpl` binds the stable address when tracing is enabled.
            self.call_arena.tracer = null;
            self.tracer.onArenaInit(config.arena_capacity_limit, config.arena_capacity_limit, config.arena_growth_factor);
            self.tracer.onEvmInit(effective_gas_price, origin, @tagName(config.eips.hardfork));

            // Process system contract updates based on configuration
            if (config.enable_beacon_roots) {
                // Process beacon root update for EIP-4788 if applicable
                @import("eips_and_hardforks/beacon_roots.zig").BeaconRootsContract.processBeaconRootUpdate(database orelse return error.DatabaseRequired, &block_info) catch |err| {
                    self.tracer.onBeaconRootUpdate(false, err);
                };
            }

            if (config.enable_historical_block_hashes) {
                @import("eips_and_hardforks/historical_block_hashes.zig").HistoricalBlockHashesContract.processBlockHashUpdate(database orelse return error.DatabaseRequired, &block_info) catch |err| {
                    self.tracer.onHistoricalBlockHashUpdate(false, err);
                };
            }

            if (config.enable_validator_deposits) {
                @import("eips_and_hardforks/validator_deposits.zig").ValidatorDepositsContract.processBlockDeposits(database orelse return error.DatabaseRequired, &block_info) catch |err| {
                    self.tracer.onValidatorDeposits(false, err);
                };
            }

            if (config.enable_validator_withdrawals) {
                @import("eips_and_hardforks/validator_withdrawals.zig").ValidatorWithdrawalsContract.processBlockWithdrawals(database orelse return error.DatabaseRequired, &block_info) catch |err| {
                    self.tracer.onValidatorWithdrawals(false, err);
                };
            }
            return self;
        }

        /// Get the arena allocator for temporary allocations during the current call.
        /// This allocator is reset after each root call completes.
        pub fn getCallArenaAllocator(self: *Self) std.mem.Allocator {
            return self.call_arena.allocator();
        }

        /// Clean up all EVM resources and free allocated memory.
        ///
        /// Deallocates all memory owned by the EVM including:
        /// - Return data buffers
        /// - Journal entries
        /// - Created contracts tracking
        /// - Self-destruct list
        /// - Access lists (EIP-2929)
        /// - Log entries (topics and data)
        /// - Touched addresses and storage
        /// - Call arena allocator
        /// - Tracer state
        ///
        /// MUST be called to prevent memory leaks. The EVM instance
        /// is invalid after calling deinit and must not be used.
        pub fn deinit(self: *Self) void {
            self.tracer.deinit();
            // Free return_data buffer
            self.return_data.deinit(self.allocator);
            self.journal.deinit();
            self.created_contracts.deinit();
            self.self_destruct.deinit();
            self.access_list.deinit();
            // Log topics and data belong to the call arena (freed below); only the list
            // itself is owned by `allocator`.
            self.logs.deinit(self.allocator);
            self.touched_addresses.deinit();
            // Clean up touched_storage
            var storage_it = self.touched_storage.iterator();
            while (storage_it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.touched_storage.deinit();
            self.call_arena.deinit();
            // Free cached analyses
            var cache_it = self.analysis_cache.valueIterator();
            while (cache_it.next()) |entry_ptr| {
                const entry = entry_ptr.*;
                entry.jump_table.deinit(self.allocator);
                entry.schedule.deinit();
                self.allocator.free(entry.code);
                self.allocator.destroy(entry);
            }
            self.analysis_cache.deinit(self.allocator);
            if (comptime config.enable_native_jit) self.jit_bridge.deinit();
            // Free per-depth stack and memory pools
            for (self.stack_pool[0..self.pool_max_depth]) |maybe_buf| {
                if (maybe_buf) |buf| self.allocator.free(buf[0..Frame.Stack.stack_capacity]);
            }
            for (self.memory_pool[0..self.pool_max_depth]) |maybe_mem| {
                if (maybe_mem) |mem_buf| {
                    mem_buf.deinit(self.allocator);
                    self.allocator.destroy(mem_buf);
                }
            }
        }

        /// Transfer value between accounts with proper balance checks and error handling
        fn transferWithBalanceChecks(self: *Self, from: primitives.Address, to: primitives.Address, value: u256, snapshot_id: Journal.SnapshotIdType) !void {
            var from_account = try self.database.get_account(from.bytes) orelse Account.zero();
            if (!config.disable_balance_checks) {
                if (from_account.balance < value) return error.InsufficientBalance;
            }
            if (from.equals(to)) return;
            var to_account = try self.database.get_account(to.bytes) orelse Account.zero();
            try self.journal.record_balance_change(snapshot_id, from, from_account.balance);
            try self.journal.record_balance_change(snapshot_id, to, to_account.balance);

            // Track addresses for state dump
            try self.touched_addresses.put(from, {});
            try self.touched_addresses.put(to, {});

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
            // Use database ephemeral overlay to avoid mutating base state
            self.database.begin_ephemeral_view();
            defer self.database.discard_ephemeral_view();
            return self.call(params);
        }

        /// State dump structure for post-state validation
        pub const StateDump = struct {
            accounts: std.StringHashMap(AccountState),

            pub const AccountState = struct {
                balance: u256,
                nonce: u64,
                code: []const u8,
                storage: std.AutoHashMap(u256, u256),
            };

            pub fn deinit(self: *StateDump, allocator: std.mem.Allocator) void {
                var it = self.accounts.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.code);
                    entry.value_ptr.storage.deinit();
                }
                self.accounts.deinit();
            }
        };

        /// Dump the current state of all touched accounts in the database.
        ///
        /// Creates a snapshot of all accounts that have been accessed or modified
        /// during execution. Includes balance, nonce, code, and storage for each account.
        ///
        /// Returns:
        ///   StateDump containing all touched accounts and their state
        ///
        /// Errors:
        ///   OutOfMemory: Allocation failed
        ///   AccountNotFound: Referenced account doesn't exist
        ///   CodeNotFound: Code hash doesn't exist
        ///
        /// Usage:
        ///   Primarily used for post-state validation in tests to verify
        ///   expected state changes after transaction execution.
        ///
        /// Note: Caller owns returned StateDump and must call deinit() to free.
        pub fn dumpState(self: *Self, allocator: std.mem.Allocator) !StateDump {
            var state_dump = StateDump{
                .accounts = std.StringHashMap(StateDump.AccountState).init(allocator),
            };
            errdefer state_dump.deinit(allocator);

            // Use the persistent touched_addresses tracker
            log.debug("[DUMP] touched_addresses count = {d}", .{self.touched_addresses.count()});
            var addr_it = self.touched_addresses.iterator();
            while (addr_it.next()) |entry| {
                const addr = entry.key_ptr.*;
                log.debug("[DUMP] checking address {any}", .{addr.bytes});
                const account = (try self.database.get_account(addr.bytes)) orelse {
                    log.debug("[DUMP] account not found in database", .{});
                    continue;
                };
                log.debug("[DUMP] found account: balance={d}, nonce={d}", .{ account.balance, account.nonce });

                // Skip zero balance, zero nonce accounts with no code
                if (account.balance == 0 and account.nonce == 0 and std.mem.eql(u8, &account.code_hash, &([_]u8{0} ** 32))) {
                    continue;
                }

                // Convert address to hex string
                var addr_hex: [42]u8 = undefined;
                @memcpy(addr_hex[0..2], "0x");
                for (addr.bytes, 0..) |byte, i| {
                    const chars = "0123456789abcdef";
                    addr_hex[2 + i * 2] = chars[byte >> 4];
                    addr_hex[2 + i * 2 + 1] = chars[byte & 0x0F];
                }
                const addr_str = try allocator.dupe(u8, &addr_hex);

                // Get code if present
                var code: []u8 = &.{};
                if (!std.mem.eql(u8, &account.code_hash, &([_]u8{0} ** 32))) {
                    const db_code = try self.database.get_code(account.code_hash);
                    code = try allocator.dupe(u8, db_code);
                }

                // Get storage
                var storage = std.AutoHashMap(u256, u256).init(allocator);

                // Get tracked storage slots for this address
                if (self.touched_storage.get(addr)) |slots| {
                    for (slots.items) |slot| {
                        const value = try self.database.get_storage(addr.bytes, slot);
                        if (value != 0) {
                            try storage.put(slot, value);
                        }
                    }
                }

                try state_dump.accounts.put(addr_str, StateDump.AccountState{
                    .balance = account.balance,
                    .nonce = account.nonce,
                    .code = code,
                    .storage = storage,
                });
            }

            return state_dump;
        }

        /// Execute an EVM operation.
        ///
        /// This is the main entry point that routes to specific handlers based
        /// on the operation type (CALL, CREATE, etc). Manages transaction-level
        /// state including logs and ensures proper cleanup.
        /// Public entry point. Runs inline on the caller's thread. Deep call chains hop once
        /// onto a large native stack inside `execute_frame` (at LARGE_STACK_DEPTH), so shallow
        /// calls pay no thread-spawn cost and the 1024 EVM depth limit cannot overflow the
        /// native stack.
        pub fn call(self: *Self, params: CallParams) CallResult {
            return self.callImpl(params);
        }

        fn callImpl(self: *Self, params: CallParams) CallResult {
            self.tracer.assert(self.depth == 0, "call() should only be called at top level");
            self.call_arena.tracer = if (self.tracer.config.enabled) @as(*anyopaque, @ptrCast(&self.tracer)) else null;

            const to_address = params.get_to() orelse primitives.ZERO_ADDRESS;
            const value = switch (params) {
                .call => |p| p.value,
                .callcode => |p| p.value,
                .delegatecall => 0,
                .staticcall => 0,
                .create => |p| p.value,
                .create2 => |p| p.value,
            };
            self.tracer.onCallStart(@tagName(params), @as(i64, @intCast(params.getGas())), to_address, value);

            // Track origin and to addresses for state dump
            self.touched_addresses.put(self.origin, {}) catch |err| {
                log.err("Failed to track origin address: {s}", .{@errorName(err)});
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            };
            if (!to_address.equals(primitives.ZERO_ADDRESS)) {
                self.touched_addresses.put(to_address, {}) catch |err| {
                    log.err("Failed to track to address: {s}", .{@errorName(err)});
                    return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                };
            }

            params.validate() catch |err| {
                log.err("CallParams validation failed: {s}", .{@errorName(err)});
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            };

            defer {
                self.depth = 0;
                // Clear return_data so a previous transaction's return data never leaks
                self.clear_return_data();
                // Clear access list for new transaction (EIP-2929)
                self.access_list.clear();
                // Clear journal for new transaction
                self.journal.clear();
                // Reset gas refund counter
                self.gas_refund_counter = 0;
                // Clear logs from previous transaction
                // NOTE: Log topics and data are arena-allocated, so no need to free them individually.
                // They will be automatically freed when the arena is reset below.
                // Clear logs while maintaining allocator reference
                self.logs.clearRetainingCapacity();
                // Clear created contracts tracking (EIP-6780)
                self.created_contracts.clear();
                // Clear self destruct list
                self.self_destruct.clear();
                // Clear transient storage at transaction end (EIP-1153)
                // Transient storage MUST NOT persist between transactions
                self.database.clear_transient_storage();

                // Reset call stack entries written this transaction (critical when reusing
                // EVM instances). Entries above tx_max_depth were never written since the
                // last reset, so they already hold the initial value.
                for (self.call_stack[0..self.tx_max_depth]) |*entry| entry.* = empty_call_stack_entry;
                self.tx_max_depth = 0;
                // Release oversized pooled memory buffers (keep small ones warm)
                for (self.memory_pool[0..self.pool_max_depth]) |maybe_mem| {
                    if (maybe_mem) |mem_buf| {
                        if (mem_buf.capacity > POOL_IDLE_MEMORY_CAP) mem_buf.clearAndFree(self.allocator);
                    }
                }
                // Reset snapshot ID
                self.current_snapshot_id = 0;
                self.tx_sender_nonce_incremented = false;
                // Reset arena allocator but retain grown capacity
                // This prevents memory buildup while keeping the grown capacity for better performance
                // on subsequent transactions that need similar memory amounts
                self.call_arena.resetRetainCapacity() catch |err| {
                    log.warn("Arena reset failed: {s}", .{@errorName(err)});
                    // If reset fails, the allocator will still be usable but may not have optimal capacity
                    // This is acceptable in a defer context where we can't propagate errors
                };
                // Reset tracer state for next call
                self.tracer.instruction_safety.count = 0;
                self.tracer.instruction_count = 0;
                self.tracer.schedule_index = 0;
                self.tracer.simple_instruction_count = 0;
                self.tracer.fused_instruction_count = 0;
                // Free per-step heap allocations and clear step buffers while keeping capacity
                self.tracer.clearSteps();
            }

            // Pre-warm addresses for top-level calls (EIP-2929 & EIP-3651)
            config.eips.pre_warm_transaction_addresses(
                &self.access_list,
                self.origin,
                params.get_to(),
                self.block_info.coinbase,
            ) catch |err| {
                log.err("Failed to pre-warm addresses: {s}", .{@errorName(err)});
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            };

            // EIP-2929 (Berlin+): exactly the precompiles active in this fork start warm.
            // An address not yet active (e.g. 0x0A before Cancun, 0x100 before Osaka) stays
            // cold. Final EIP-2537 ends at 0x11; 0x100 is Osaka's P256VERIFY (EIP-7951).
            if (comptime config.eips.hardfork.isAtLeast(.BERLIN)) {
                const last = comptime precompiles.lastContiguousPrecompile(config.eips.hardfork);
                var precompile_index: u16 = 0x01;
                while (precompile_index <= last) : (precompile_index += 1) {
                    self.warmPrecompile(primitives.Address.fromU256(precompile_index)) catch |err| {
                        log.err("Failed to pre-warm precompile: {s}", .{@errorName(err)});
                        return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                    };
                }
                if (comptime config.eips.hardfork.isAtLeast(.OSAKA)) {
                    self.warmPrecompile(precompiles.P256VERIFY_ADDRESS) catch |err| {
                        log.err("Failed to pre-warm precompile: {s}", .{@errorName(err)});
                        return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                    };
                }
            }

            const gas_limit = params.getGas();
            if (comptime !config.disable_gas_checks) {
                if (gas_limit == 0) return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            }

            const input = params.getInput();
            const calldata_tokens = config.eips.tokens_in_calldata(input);
            const intrinsic_gas_cost = config.eips.intrinsic_gas_cost(params.isCreate());
            const calldata_gas_cost = config.eips.calldata_gas_cost(calldata_tokens, params.isCreate(), input.len);
            const floor_gas_cost = config.eips.floor_gas_cost(calldata_tokens);
            const initial_gas_cost = intrinsic_gas_cost + calldata_gas_cost;

            if (comptime !config.disable_gas_checks) {
                if (gas_limit < initial_gas_cost or gas_limit < floor_gas_cost) {
                    return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                }
                // EIP-7825: a transaction above TX_GAS_LIMIT_CAP is invalid; reject before nonce increment.
                config.eips.validate_transaction_gas_limit(gas_limit) catch |err| {
                    log.debug("Transaction rejected: {s}", .{@errorName(err)});
                    return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                };
            }
            const execution_gas_limit = gas_limit - initial_gas_cost;

            const blob_versioned_hashes = self.context.blob_versioned_hashes;
            const blob_count = if (self.context.is_blob_transaction) blob_versioned_hashes.len else 0;
            config.eips.validate_blob_gas(
                self.context.is_blob_transaction,
                blob_versioned_hashes,
                self.context.max_fee_per_blob_gas,
                self.block_info.blob_base_fee,
                params.get_to(),
            ) catch |err| {
                log.err("Blob transaction validation failed: {s}", .{@errorName(err)});
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            };

            const max_blob_gas_cost = config.eips.max_blob_gas_cost(
                self.context.max_fee_per_blob_gas,
                blob_count,
            );

            // Transaction validity is checked before nonce increment or execution.
            // EIP-1559 reserves the fee cap, not the lower effective gas price.
            if (!config.disable_balance_checks) {
                const origin_account = self.database.get_account(self.origin.bytes) catch |err| {
                    log.err("Failed to read origin account for upfront balance check: {s}", .{@errorName(err)});
                    return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                };
                const origin_balance = if (origin_account) |account| account.balance else 0;
                const gas_fee_cap = self.context.max_fee_per_gas orelse self.gas_price;
                const max_execution_cost = @mulWithOverflow(@as(u256, params.getGas()), gas_fee_cap);
                if (max_execution_cost[1] != 0) {
                    return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                }
                const execution_and_value = @addWithOverflow(max_execution_cost[0], params.getValue());
                if (execution_and_value[1] != 0) {
                    return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                }
                const required_balance = @addWithOverflow(execution_and_value[0], max_blob_gas_cost);
                if (required_balance[1] != 0 or origin_balance < required_balance[0]) {
                    return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                }
            }

            // Increment origin nonce for top-level transactions (EIP-2718)
            // This must happen after gas deduction but before inner_call execution
            {
                var origin_account = self.database.get_account(self.origin.bytes) catch {
                    return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                } orelse Account.zero();

                // Record the nonce change for potential revert
                // Using current_snapshot_id (0 at transaction level)
                self.journal.record_nonce_change(self.current_snapshot_id, self.origin, origin_account.nonce) catch {
                    return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                };

                // Increment and persist the nonce
                origin_account.nonce += 1;
                self.database.set_account(self.origin.bytes, origin_account) catch {
                    return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                };
                self.tx_sender_nonce_incremented = true;
            }

            var modified_params = params;
            modified_params.setGas(execution_gas_limit);

            const arena_result = self.inner_call(modified_params);
            // Clone result to main allocator since we're at depth 0 (top-level call)
            var result = arena_result.toOwnedResult(self.allocator) catch |err| {
                log.err("Failed to clone call result: {s}", .{@errorName(err)});
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            };

            self.tracer.onCallComplete(result.success, @as(i64, @intCast(result.gas_left)), result.output.len);

            // Apply EIP-3529 gas refund cap if transaction succeeded
            if (result.success) {
                result.gas_left = config.eips.eip_3529_apply_gas_refund(gas_limit, result.gas_left, self.gas_refund_counter);
                // Reset refund counter for next transaction
                self.gas_refund_counter = 0;
            }

            // EIP-7623: gas_used = max(execution gas after refunds, floor gas).
            // The floor applies to every included transaction: success, revert or exceptional halt.
            var gas_consumed = gas_limit - result.gas_left;
            if (gas_consumed < floor_gas_cost) {
                gas_consumed = floor_gas_cost;
                if (comptime !config.disable_gas_checks) {
                    result.gas_left = gas_limit - floor_gas_cost;
                }
            }

            // Blob fees are fully burned and are never credited to coinbase.
            const gas_consumed_u256: u256 = @intCast(gas_consumed);
            const execution_gas_fee = self.gas_price * gas_consumed_u256;
            const blob_gas_cost = config.eips.blob_gas_cost(
                self.block_info.blob_base_fee,
                blob_count,
            );
            const total_gas_fee = execution_gas_fee +| blob_gas_cost;
            if (total_gas_fee > 0) {

                // Get origin account
                var origin_account = self.database.get_account(self.origin.bytes) catch |err| {
                    log.debug("Failed to get origin account for gas fee deduction: {}", .{err});
                    return result;
                } orelse Account.zero();

                // Check if origin has sufficient balance for gas fees
                if (!config.disable_balance_checks) {
                    if (origin_account.balance < total_gas_fee) {
                        log.debug("Insufficient balance for gas fees: balance={d}, fee={d}", .{ origin_account.balance, total_gas_fee });
                        result.success = false;
                        result.gas_left = 0;
                        return result;
                    }
                }

                // Record balance change in journal for potential revert
                self.journal.record_balance_change(0, self.origin, origin_account.balance) catch |err| {
                    log.debug("Failed to record balance change for gas fees: {}", .{err});
                    return result;
                };

                // Deduct gas fees from origin
                origin_account.balance -= total_gas_fee;
                self.database.set_account(self.origin.bytes, origin_account) catch |err| {
                    log.debug("Failed to update origin balance for gas fees: {}", .{err});
                    return result;
                };

                // Handle coinbase rewards (miner/validator payment)
                if (config.eips.eip_1559_is_enabled() and execution_gas_fee > 0) {
                    // EIP-1559: Only priority fee goes to coinbase, base fee is burned
                    const base_fee = self.block_info.base_fee;
                    const priority_fee_per_gas = if (self.gas_price > base_fee)
                        self.gas_price - base_fee
                    else
                        0;
                    const coinbase_reward = priority_fee_per_gas * gas_consumed_u256;

                    if (coinbase_reward > 0) {
                        var coinbase_account = self.database.get_account(self.block_info.coinbase.bytes) catch {
                            // If we can't get coinbase, still continue (fees are burned)
                            return result;
                        } orelse Account.zero();

                        // Record coinbase balance change
                        self.journal.record_balance_change(0, self.block_info.coinbase, coinbase_account.balance) catch {
                            // Non-critical: coinbase reward failure doesn't invalidate transaction
                            return result;
                        };

                        coinbase_account.balance += coinbase_reward;
                        self.database.set_account(self.block_info.coinbase.bytes, coinbase_account) catch {
                            // Non-critical: continue even if coinbase update fails
                            return result;
                        };
                    }
                    // Base fee (total_gas_fee - coinbase_reward) is effectively burned
                } else if (execution_gas_fee > 0) {
                    // Pre-EIP-1559: All execution fees go to coinbase.
                    var coinbase_account = self.database.get_account(self.block_info.coinbase.bytes) catch {
                        return result;
                    } orelse Account.zero();

                    self.journal.record_balance_change(0, self.block_info.coinbase, coinbase_account.balance) catch {
                        return result;
                    };

                    coinbase_account.balance += execution_gas_fee;
                    self.database.set_account(self.block_info.coinbase.bytes, coinbase_account) catch {
                        return result;
                    };
                }
            }

            // Extract logs for top-level calls
            // Logs are already arena-allocated and will be cloned by toOwnedResult above
            // Transfer logs to result - they are already owned by result via toOwnedResult
            const logs_slice = self.logs.items;
            if (logs_slice.len > 0) {
                // Free the logs already in result (from toOwnedResult) since we need to replace them
                self.allocator.free(result.logs);

                // Allocate new array for logs
                const logs_copy = self.allocator.alloc(@import("frame/call_result.zig").Log, logs_slice.len) catch |err| {
                    log.err("Failed to allocate result logs: {s}", .{@errorName(err)});
                    result.success = false;
                    return result;
                };

                // Copy each log, duplicating arena-allocated data to main allocator
                for (logs_slice, 0..) |log_entry, i| {
                    const topics_copy = self.allocator.dupe(u256, log_entry.topics) catch |err| {
                        log.err("Failed to copy log topics: {s}", .{@errorName(err)});
                        // Free already allocated logs
                        for (logs_copy[0..i]) |prev_log| {
                            if (prev_log.topics.len > 0) self.allocator.free(prev_log.topics);
                            if (prev_log.data.len > 0) self.allocator.free(prev_log.data);
                        }
                        self.allocator.free(logs_copy);
                        result.success = false;
                        return result;
                    };
                    errdefer self.allocator.free(topics_copy);

                    const data_copy = self.allocator.dupe(u8, log_entry.data) catch |err| {
                        log.err("Failed to copy log data: {s}", .{@errorName(err)});
                        // Free topics we just allocated
                        self.allocator.free(topics_copy);
                        // Free already allocated logs
                        for (logs_copy[0..i]) |prev_log| {
                            if (prev_log.topics.len > 0) self.allocator.free(prev_log.topics);
                            if (prev_log.data.len > 0) self.allocator.free(prev_log.data);
                        }
                        self.allocator.free(logs_copy);
                        result.success = false;
                        return result;
                    };

                    logs_copy[i] = @import("frame/call_result.zig").Log{
                        .address = log_entry.address,
                        .topics = topics_copy,
                        .data = data_copy,
                    };
                }

                result.logs = logs_copy;
            }

            // Extract self-destruct records (handlers_system.selfdestruct already enforces EIP-6780 on Cancun+)
            result.selfdestructs = self.self_destruct.toOwnedSlice(self.allocator) catch |err| {
                log.err("Failed to transfer selfdestructs: {s}", .{@errorName(err)});
                result.success = false;
                return result;
            };

            // Extract access list data before clearing
            result.accessed_addresses = self.allocator.dupe(primitives.Address, self.access_list.addresses.keys()) catch {
                log.debug("Out of memory allocating accessed_addresses", .{});
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            };

            // Convert StorageKey to StorageAccess (same fields, different type)
            const storage_keys = self.access_list.storage_slots.keys();
            const storage_access = self.allocator.alloc(call_result_module.StorageAccess, storage_keys.len) catch {
                log.debug("Out of memory allocating storage_access", .{});
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            };
            for (storage_keys, 0..) |key, i| {
                storage_access[i] = .{ .address = key.address, .slot = key.slot };
            }
            result.accessed_storage = storage_access;

            return result;
        }

        /// Execute a nested EVM call - used for calls from within the EVM.
        /// This handles nested calls and manages depth tracking.
        pub fn inner_call(self: *Self, params: CallParams) CallResult {
            @branchHint(.likely);
            if ((@import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe)) {
                params.validate() catch {
                    self.clear_return_data();
                    return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                };
            }

            if (!config.disable_gas_checks) {
                if (params.getGas() == 0) {
                    self.clear_return_data();
                    return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                }
            }

            // depth is incremented solely by execute_frame (CALL variants) and the create paths;
            // inner_call must NOT increment it again or every nesting level would advance depth
            // by 2 (halving the 1024 limit) and leave a call_stack gap that corrupts parent
            // caller/value/is_static lookups. The check uses the parent depth: a frame already
            // at the limit cannot push another. (Deep recursion is safe: execute_frame hops
            // onto a large-stack worker thread at LARGE_STACK_DEPTH.)
            if (self.depth >= config.max_call_depth) {
                self.clear_return_data();
                // execution-specs `generic_call`: past the depth limit a message call returns
                // its whole sub-call gas. Creations keep their existing accounting.
                const refund: u64 = switch (params) {
                    .call, .callcode, .delegatecall, .staticcall => params.getGas(),
                    .create, .create2 => 0,
                };
                return CallResult.failure(self.getCallArenaAllocator(), refund) catch unreachable;
            }

            const execution_gas = params.getGas();

            var result = switch (params) {
                .call => |p| blk: {
                    @branchHint(.likely);
                    break :blk self.executeCall(.{ .caller = p.caller, .to = p.to, .value = p.value, .input = p.input, .gas = execution_gas }) catch {
                        self.clear_return_data();
                        return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                    };
                },
                .staticcall => |p| blk: {
                    @branchHint(.likely);
                    break :blk self.executeStaticcall(.{ .caller = p.caller, .to = p.to, .input = p.input, .gas = execution_gas }) catch (CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable);
                },
                .delegatecall => |p| self.executeDelegatecall(.{ .caller = p.caller, .to = p.to, .input = p.input, .gas = execution_gas }) catch (CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable),
                .create => |p| self.executeCreate(.{ .caller = p.caller, .value = p.value, .init_code = p.init_code, .gas = execution_gas }) catch (CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable),
                .create2 => |p| self.executeCreate2(.{ .caller = p.caller, .value = p.value, .init_code = p.init_code, .salt = p.salt, .gas = execution_gas }) catch (CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable),
                .callcode => |p| blk: {
                    @branchHint(.cold);
                    break :blk self.executeCallcode(.{ .caller = p.caller, .to = p.to, .value = p.value, .input = p.input, .gas = execution_gas }) catch (CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable);
                },
            };

            // EIP-211: CALL/CALLCODE/DELEGATECALL/STATICCALL always update the caller's
            // return_data buffer (including precompiles, empty accounts, and failures).
            switch (params) {
                .call, .staticcall, .delegatecall, .callcode => {
                    self.set_return_data(result.output) catch {
                        self.clear_return_data();
                    };
                },
                .create, .create2 => {},
            }

            result.logs = &.{};
            result.selfdestructs = &.{};
            result.accessed_addresses = &.{};
            result.accessed_storage = &.{};

            return result;
        }

        /// Code to run plus its analysis cache key (null = do not cache).
        const CodeToExecute = struct {
            code: []const u8,
            code_hash: ?[32]u8,
        };

        /// Analysis cache key for an account's own code. Null for missing accounts,
        /// EIP-7702 delegated accounts (their code comes from another address), and
        /// all-zero hashes.
        fn cacheableCodeHash(account: ?Account) ?[32]u8 {
            const acc = account orelse return null;
            if (acc.get_effective_code_address() != null) return null;
            if (std.mem.eql(u8, &acc.code_hash, &([_]u8{0} ** 32))) return null;
            return acc.code_hash;
        }

        /// Result of pre-flight checks for call operations
        const PreflightResult = union(enum) {
            precompile_result: CallResult,
            execute_with_code: CodeToExecute,
            empty_account: u64, // gas remaining
        };

        /// Perform pre-flight checks common to all call operations
        fn performCallPreflight(self: *Self, to: primitives.Address, input: []const u8, gas: u64, is_static: bool, snapshot_id: Journal.SnapshotIdType) !PreflightResult {
            if (config.enable_precompiles and precompiles.isPrecompile(to, config.eips.hardfork)) {
                const result = self.executePrecompileInline(to, input, gas, is_static, snapshot_id) catch {
                    self.journal.revert_to_snapshot(snapshot_id);
                    return PreflightResult{ .precompile_result = CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable };
                };
                return PreflightResult{ .precompile_result = result };
            }

            // Handle EIP-4788 beacon roots contract
            const beacon_roots = @import("eips_and_hardforks/beacon_roots.zig");
            if (config.eips.eip_4788_is_beacon_roots_address(to)) {
                var contract = beacon_roots.BeaconRootsContract{ .database = self.database, .allocator = self.allocator };
                const caller = if (self.depth > 0) self.call_stack[self.depth - 1].caller else primitives.ZERO_ADDRESS;

                const result = contract.execute(caller, input, gas) catch |err| {
                    log.debug("Beacon roots contract failed: {}", .{err});
                    self.journal.revert_to_snapshot(snapshot_id);
                    return PreflightResult{ .precompile_result = CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable };
                };

                // Allocate output that persists beyond this function
                const output = if (result.output.len > 0) output: {
                    // Handle allocation errors by reverting snapshot and returning failure
                    const out = self.getCallArenaAllocator().alloc(u8, result.output.len) catch {
                        self.journal.revert_to_snapshot(snapshot_id);
                        return PreflightResult{ .precompile_result = CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable };
                    };
                    @memcpy(out, result.output);
                    break :output out;
                } else &[_]u8{};

                return PreflightResult{ .precompile_result = CallResult{
                    .success = true,
                    .gas_left = gas - result.gas_used,
                    .output = output,
                } };
            }

            // Handle EIP-2935 historical block hashes contract
            const historical_block_hashes = @import("eips_and_hardforks/historical_block_hashes.zig");
            if (config.eips.eip_2935_is_historical_block_hashes_address(to)) {
                var contract = historical_block_hashes.HistoricalBlockHashesContract{ .database = self.database, .allocator = self.allocator };
                const caller = if (self.depth > 0) self.call_stack[self.depth - 1].caller else primitives.ZERO_ADDRESS;

                const result = contract.execute(caller, input, gas) catch |err| {
                    log.debug("Historical block hashes contract failed: {}", .{err});
                    self.journal.revert_to_snapshot(snapshot_id);
                    return PreflightResult{ .precompile_result = CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable };
                };

                // Allocate output that persists beyond this function
                const output = if (result.output.len > 0) output: {
                    // Handle allocation errors by reverting snapshot and returning failure
                    const out = self.getCallArenaAllocator().alloc(u8, result.output.len) catch {
                        self.journal.revert_to_snapshot(snapshot_id);
                        return PreflightResult{ .precompile_result = CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable };
                    };
                    @memcpy(out, result.output);
                    break :output out;
                } else &[_]u8{};

                return PreflightResult{ .precompile_result = CallResult{
                    .success = true,
                    .gas_left = gas - result.gas_used,
                    .output = output,
                } };
            }

            // Check for EIP-7702 delegation first
            const account = self.database.get_account(to.bytes) catch |err| {
                log.debug("Failed to get account for address {x}: {}", .{ to.bytes, err });
                return PreflightResult{ .precompile_result = (CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable) };
            };

            // Get the effective code address (handles delegation)
            const code_address = config.eips.eip_7702_get_effective_code_address(account, to);
            if (account) |acc| {
                if (acc.get_effective_code_address()) |delegated| {
                    log.debug("Account {x} has delegation to {x}", .{ to.bytes, delegated.bytes });
                }
            }

            // Get contract code (from delegated address if applicable)
            // log.debug("Attempting to get code for address: {x}", .{code_address.bytes});
            const code = self.codeAt(code_address) catch |err| {
                // log.debug("Failed to get code for address {x}: {}", .{ code_address.bytes, err });
                // Don't use error_info with string literals to avoid freeing them
                // Just log the error and return a failure without error_info
                log.debug("Database error: {}", .{err});
                return PreflightResult{ .precompile_result = (CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable) };
            };

            if (code.len == 0) {
                log.debug("Code is empty, returning empty account result", .{});
                return PreflightResult{ .empty_account = gas };
            }

            // Cache only the account's own code; delegated code resolves to another address.
            const code_hash: ?[32]u8 = if (code_address.equals(to)) cacheableCodeHash(account) else null;
            return PreflightResult{ .execute_with_code = .{ .code = code, .code_hash = code_hash } };
        }

        /// Transaction-scoped substate captured at call-frame entry (revm
        /// `JournalCheckpoint`). A frame that reverts or halts restores all of it; a
        /// frame that succeeds keeps everything it added. Account and storage state are
        /// covered separately by the journal and database snapshots.
        const FrameCheckpoint = struct {
            logs: usize,
            gas_refund: u64,
            access_list: AccessList.Checkpoint,
            self_destruct: SelfDestruct.Checkpoint,
            created_contracts: CreatedContracts.Checkpoint,
        };

        fn frameCheckpoint(self: *const Self) FrameCheckpoint {
            return .{
                .logs = self.logs.items.len,
                .gas_refund = self.gas_refund_counter,
                .access_list = self.access_list.checkpoint(),
                .self_destruct = self.self_destruct.checkpoint(),
                .created_contracts = self.created_contracts.checkpoint(),
            };
        }

        /// Undo a failed frame: account/storage state via the journal and database
        /// snapshots, then logs, refunds, EIP-2929 warm sets, SELFDESTRUCT marks and
        /// EIP-6780 created contracts via the frame checkpoint.
        fn revertFrame(self: *Self, snapshot_id: Journal.SnapshotIdType, db_snapshot_id: u64, checkpoint: FrameCheckpoint) !void {
            // Log topics and data live in the call arena, so dropping entries frees nothing.
            self.logs.shrinkRetainingCapacity(checkpoint.logs);
            self.gas_refund_counter = checkpoint.gas_refund;
            self.access_list.revertTo(checkpoint.access_list);
            self.self_destruct.revertTo(checkpoint.self_destruct);
            self.created_contracts.revertTo(checkpoint.created_contracts);
            self.journal.revert_to_snapshot(snapshot_id);
            try self.database.revert_to_snapshot(db_snapshot_id);
        }

        /// Execute CALL operation (inlined from call_handler)
        fn executeCall(self: *Self, params: struct {
            caller: primitives.Address,
            to: primitives.Address,
            value: u256,
            input: []const u8,
            gas: u64,
        }) !CallResult {
            @branchHint(.likely);
            const snapshot_id = try self.journal.create_snapshot();
            const db_snapshot_id = try self.database.create_snapshot();
            const checkpoint = self.frameCheckpoint();

            if (params.value > 0) {
                self.transferWithBalanceChecks(params.caller, params.to, params.value, snapshot_id) catch |err| {
                    log.debug("Call value transfer failed: {}", .{err});
                    try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                    // execution-specs `call`: a sender that cannot afford `value` gets the
                    // whole sub-call gas (forwarded gas plus stipend) back.
                    const refund = if (err == error.InsufficientBalance) params.gas else 0;
                    return CallResult.failure(self.getCallArenaAllocator(), refund) catch unreachable;
                };
            }

            const preflight = self.performCallPreflight(params.to, params.input, params.gas, self.is_static_context(), snapshot_id) catch |err| {
                self.tracer.onCallPreflight("CALL", @errorName(err));
                try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            };
            self.tracer.onCallPreflight("CALL", @tagName(preflight));

            switch (preflight) {
                .precompile_result => |result| {
                    // A failed precompile (or failed preflight) is an exceptional halt of
                    // the callee: undo its value transfer and everything else since entry.
                    if (!result.success) {
                        try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                        return result;
                    }
                    try self.database.commit_snapshot(db_snapshot_id);
                    return result;
                },
                .empty_account => |gas| {
                    self.tracer.onCodeRetrieval(params.to, 0, true);
                    // Empty account call succeeded, commit the snapshot
                    try self.database.commit_snapshot(db_snapshot_id);
                    return CallResult.success_empty(self.getCallArenaAllocator(), gas) catch unreachable;
                },
                .execute_with_code => |exec| {
                    self.tracer.onCodeRetrieval(params.to, exec.code.len, false);
                    const result = self.execute_frame(
                        exec.code,
                        params.input,
                        params.gas,
                        params.to,
                        params.caller,
                        params.value,
                        self.is_static_context(), // EIP-214: inherit parent static context
                        snapshot_id,
                        exec.code_hash,
                    ) catch |err| {
                        log.debug("EXECUTE_CALL: execute_frame failed with error: {}", .{err});
                        try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                        return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                    };

                    if (!result.success) {
                        try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                    } else {
                        // Call succeeded, commit the snapshot
                        try self.database.commit_snapshot(db_snapshot_id);
                    }
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
            const snapshot_id = try self.journal.create_snapshot();
            const db_snapshot_id = try self.database.create_snapshot();
            const checkpoint = self.frameCheckpoint();

            if (params.value > 0) {
                if (!config.disable_balance_checks) {
                    const caller_account = self.database.get_account(params.caller.bytes) catch {
                        @branchHint(.cold);
                        try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                        return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                    };
                    if (caller_account == null or caller_account.?.balance < params.value) {
                        @branchHint(.cold);
                        try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                        // execution-specs `callcode`: the whole sub-call gas comes back.
                        return CallResult.failure(self.getCallArenaAllocator(), params.gas) catch unreachable;
                    }
                }
            }

            // CALLCODE runs the code at `to` in the caller's context; when `to` is a
            // precompile, that code is the precompile. A failed precompile consumes all of
            // the gas it was given, exactly like CALL.
            if (config.enable_precompiles and precompiles.isPrecompile(params.to, config.eips.hardfork)) {
                const result = self.executePrecompileInline(params.to, params.input, params.gas, self.is_static_context(), snapshot_id) catch
                    (CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable);
                if (result.success) {
                    try self.database.commit_snapshot(db_snapshot_id);
                } else {
                    try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                }
                return result;
            }

            const code = try self.codeAt(params.to);
            if (code.len == 0) {
                @branchHint(.unlikely);
                // Empty code, commit snapshot
                try self.database.commit_snapshot(db_snapshot_id);
                return CallResult.success_empty(self.getCallArenaAllocator(), params.gas) catch unreachable;
            }
            const code_hash = cacheableCodeHash(try self.database.get_account(params.to.bytes));

            const result = self.execute_frame(
                code,
                params.input,
                params.gas,
                params.caller,
                params.caller,
                params.value,
                self.is_static_context(), // EIP-214: inherit parent static context (CALLCODE)
                snapshot_id,
                code_hash,
            ) catch {
                @branchHint(.unlikely);
                try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            };

            if (!result.success) {
                @branchHint(.unlikely);
                try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
            } else {
                // Call succeeded, commit snapshot
                try self.database.commit_snapshot(db_snapshot_id);
            }
            return result;
        }
        /// Execute DELEGATECALL operation (inlined)
        fn executeDelegatecall(self: *Self, params: struct {
            caller: primitives.Address,
            to: primitives.Address,
            input: []const u8,
            gas: u64,
        }) !CallResult {
            const snapshot_id = try self.journal.create_snapshot();
            const db_snapshot_id = try self.database.create_snapshot();
            const checkpoint = self.frameCheckpoint();

            const preflight = self.performCallPreflight(params.to, params.input, params.gas, self.is_static_context(), snapshot_id) catch |err| {
                @branchHint(.cold);
                log.debug("Delegatecall preflight failed: {}", .{err});
                try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            };

            switch (preflight) {
                .precompile_result => |result| {
                    if (!result.success) {
                        try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                        return result;
                    }
                    try self.database.commit_snapshot(db_snapshot_id);
                    return result;
                },
                .empty_account => |gas| {
                    try self.database.commit_snapshot(db_snapshot_id);
                    return CallResult.success_empty(self.getCallArenaAllocator(), gas) catch unreachable;
                },
                .execute_with_code => |exec| {
                    // EIP-7: DELEGATECALL executes `params.to`'s code in the current contract's
                    // storage/address context, preserving msg.sender (`params.caller`) and msg.value.
                    const current_address = if (self.depth > 0) self.call_stack[self.depth - 1].address else params.to;
                    const current_value = if (self.depth > 0) self.call_stack[self.depth - 1].value else 0;
                    const result = self.execute_frame(
                        exec.code,
                        params.input,
                        params.gas,
                        current_address,
                        params.caller,
                        current_value,
                        self.is_static_context(), // EIP-214: inherit parent static context (DELEGATECALL)
                        snapshot_id,
                        exec.code_hash,
                    ) catch {
                        @branchHint(.cold);
                        try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                        return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                    };

                    if (!result.success) {
                        @branchHint(.unlikely);
                        try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                    } else {
                        try self.database.commit_snapshot(db_snapshot_id);
                    }
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
            const snapshot_id = try self.journal.create_snapshot();
            const db_snapshot_id = try self.database.create_snapshot();
            const checkpoint = self.frameCheckpoint();

            const preflight = self.performCallPreflight(params.to, params.input, params.gas, true, snapshot_id) catch |err| {
                @branchHint(.cold);
                log.debug("Staticcall preflight failed: {}", .{err});
                try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            };

            switch (preflight) {
                .precompile_result => |result| {
                    if (!result.success) {
                        try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                        return result;
                    }
                    try self.database.commit_snapshot(db_snapshot_id);
                    return result;
                },
                .empty_account => |gas| {
                    try self.database.commit_snapshot(db_snapshot_id);
                    return CallResult.success_empty(self.getCallArenaAllocator(), gas) catch unreachable;
                },
                .execute_with_code => |exec| {
                    const result = self.execute_frame(
                        exec.code,
                        params.input,
                        params.gas,
                        params.to,
                        params.caller,
                        0,
                        true,
                        snapshot_id,
                        exec.code_hash,
                    ) catch {
                        @branchHint(.cold);
                        try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                        return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                    };

                    if (!result.success) {
                        try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                    } else {
                        try self.database.commit_snapshot(db_snapshot_id);
                    }
                    return result;
                },
            }
        }

        /// True for the transaction's own creation, whose sender nonce `call()` already
        /// incremented and whose intrinsic gas already covered CreateGas and initcode words.
        /// Consumes the flag, so only the first top-level creation qualifies.
        fn takeTransactionCreate(self: *Self, caller: primitives.Address) bool {
            const is_transaction = self.tx_sender_nonce_incremented and self.depth == 0 and
                std.mem.eql(u8, &caller.bytes, &self.origin.bytes);
            self.tx_sender_nonce_incremented = false;
            return is_transaction;
        }

        /// Sender-side steps that precede the creation snapshot (execution-specs
        /// `generic_create`). Returns the nonce that derives the CREATE address, and
        /// `admitted == false` when the creation fails before touching state
        /// (insufficient balance, or nonce at the EIP-2681 limit). The increment is recorded in the caller's snapshot, so
        /// it survives a failed or colliding creation and is undone only if the caller
        /// itself reverts. A creation transaction uses the nonce before `call()`'s
        /// increment and is not incremented again.
        fn beginCreate(self: *Self, caller: primitives.Address, value: u256, is_transaction: bool) !CreateBegin {
            var account = (try self.database.get_account(caller.bytes)) orelse Account.zero();
            if (is_transaction) {
                if (account.nonce == 0) return error.TransactionNonceNotIncremented;
                return .{ .nonce = account.nonce - 1, .admitted = true };
            }
            if (account.balance < value) return .{ .nonce = account.nonce, .admitted = false };
            if (account.nonce == std.math.maxInt(u64)) return .{ .nonce = account.nonce, .admitted = false };
            try self.journal.record_nonce_change(self.current_snapshot_id, caller, account.nonce);
            const creation_nonce = account.nonce;
            account.nonce += 1;
            try self.database.set_account(caller.bytes, account);
            return .{ .nonce = creation_nonce, .admitted = true };
        }

        /// Outcome of `beginCreate`. `nonce` derives the CREATE address even when the
        /// creation is refused (`admitted == false`), as in execution-specs.
        const CreateBegin = struct {
            nonce: u64,
            admitted: bool,
        };

        /// Gas an opcode CREATE or CREATE2 charges up front: CreateGas, EIP-3860 init code
        /// words (Shanghai+), and for CREATE2 the EIP-1014 init code hash words.
        /// The opcode handler halts out of gas when it cannot pay this.
        pub fn create_opcode_charge(init_code_len: usize, is_create2: bool) u64 {
            const GasConstants = primitives.GasConstants;
            const words: u64 = (@as(u64, @intCast(init_code_len)) + 31) / 32;
            const word_cost: u64 = if (config.eips.hardfork.isAtLeast(.SHANGHAI)) words * GasConstants.InitcodeWordGas else 0;
            const hash_cost: u64 = if (is_create2) words * GasConstants.Keccak256WordGas else 0;
            return GasConstants.CreateGas + word_cost + hash_cost;
        }

        /// Execute CREATE operation (inlined)
        fn executeCreate(self: *Self, params: struct {
            caller: primitives.Address,
            value: u256,
            init_code: []const u8,
            gas: u64,
        }) !CallResult {
            const is_transaction = self.takeTransactionCreate(params.caller);
            // A CREATE transaction already paid CreateGas and initcode words as intrinsic gas.
            // The CREATE opcode handler halts out of gas before calling here when it cannot pay them.
            const create_overhead = if (is_transaction) 0 else create_opcode_charge(params.init_code.len, false);
            if (params.gas < create_overhead) {
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            }
            const remaining_gas: u64 = params.gas - create_overhead;
            // EIP-150 (Tangerine Whistle+): an opcode creation forwards all but 1/64 of the
            // remaining gas; the caller keeps the rest whatever the creation's outcome.
            const retained: u64 = if (!is_transaction and config.eips.hardfork.isAtLeast(.TANGERINE_WHISTLE)) remaining_gas / 64 else 0;
            const forwarded: u64 = remaining_gas - retained;

            // execution-specs generic_create: a creation refused for balance or nonce limit
            // returns the gas it would have forwarded; the CREATE charge stays spent.
            const begin = try self.beginCreate(params.caller, params.value, is_transaction);
            const contract_address = try primitives.Address.getContractAddress(self.getCallArenaAllocator(), params.caller, begin.nonce);
            // execution-specs generic_create: the new address turns warm in the creating
            // frame before any check that can refuse the creation, so it stays warm
            // whatever the creation's outcome (it precedes the frame checkpoint).
            try config.eips.warm_contract_for_execution(&self.access_list, contract_address);
            if (!begin.admitted) return CallResult.failure(self.getCallArenaAllocator(), remaining_gas) catch unreachable;

            const snapshot_id = try self.journal.create_snapshot();
            const db_snapshot_id = try self.database.create_snapshot();
            const checkpoint = self.frameCheckpoint();

            const existed_before = self.database.account_exists(contract_address.bytes);
            if (existed_before) {
                const existing = try self.database.get_account(contract_address.bytes);
                // EIP-684 + EIP-7610: an address with code, a nonzero nonce, or nonempty
                // storage cannot be created again.
                if (existing != null and (existing.?.nonce != 0 or !std.mem.eql(u8, &existing.?.code_hash, &[_]u8{0} ** 32) or try self.database.has_storage(contract_address.bytes))) {
                    try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                    return CallResult.failure(self.getCallArenaAllocator(), retained) catch unreachable;
                }
            }
            var result = self.executeCreateInternal(.{
                .caller = params.caller,
                .value = params.value,
                .init_code = params.init_code,
                .gas_left = forwarded,
                .contract_address = contract_address,
                .snapshot_id = snapshot_id,
                .db_snapshot_id = db_snapshot_id,
                .checkpoint = checkpoint,
                .existed_before = existed_before,
            }) catch {
                try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                return CallResult.failure(self.getCallArenaAllocator(), retained) catch unreachable;
            };

            result.gas_left += retained;
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
            log.debug("CREATE2: gas={}, init_len={}, value={}", .{ params.gas, params.init_code.len, params.value });
            if (self.depth >= config.max_call_depth) {
                log.debug("CREATE2: depth exceeded", .{});
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            }

            const is_transaction = self.takeTransactionCreate(params.caller);
            const GasConstants = primitives.GasConstants;
            // EIP-3860 (Shanghai+): init code costs 2 gas per 32-byte word.
            const init_words_c2: u64 = (@as(u64, @intCast(params.init_code.len)) + 31) / 32;
            const initcode_word_cost_c2: u64 = if (config.eips.hardfork.isAtLeast(.SHANGHAI)) init_words_c2 * GasConstants.InitcodeWordGas else 0;
            // A creation transaction already paid CreateGas and initcode words as intrinsic gas.
            const create_overhead = if (is_transaction) 0 else GasConstants.CreateGas + initcode_word_cost_c2;
            // EIP-1014: CREATE2 hashes the init code at GAS_KECCAK256_WORD per 32-byte word,
            // rounded UP (ceil(len/32)), not len*word_gas/32 which rounds down.
            const hash_cost = init_words_c2 * GasConstants.Keccak256WordGas;
            const total_overhead = create_overhead + hash_cost;
            // An opcode CREATE2 that cannot pay its charge fails before the sender nonce moves.
            if (params.gas < total_overhead) {
                log.debug("CREATE2: insufficient gas for overhead: need={}, have={}", .{ total_overhead, params.gas });
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            }
            const remaining_gas: u64 = params.gas - total_overhead;
            // EIP-150 (Tangerine Whistle+): an opcode creation forwards all but 1/64 of the
            // remaining gas; the caller keeps the rest whatever the creation's outcome.
            const retained: u64 = if (!is_transaction and config.eips.hardfork.isAtLeast(.TANGERINE_WHISTLE)) remaining_gas / 64 else 0;
            const forwarded: u64 = remaining_gas - retained;

            // execution-specs generic_create: a creation refused for balance or nonce limit
            // returns the gas it would have forwarded; the CREATE2 charge stays spent.
            const keccak_asm = @import("crypto").keccak_asm;
            var init_code_hash_bytes: [32]u8 = undefined;
            try keccak_asm.keccak256(params.init_code, &init_code_hash_bytes);
            var salt_bytes: [32]u8 = undefined;
            std.mem.writeInt(u256, &salt_bytes, params.salt, .big);
            const contract_address = primitives.Address.getCreate2Address(params.caller, salt_bytes, init_code_hash_bytes);
            // execution-specs generic_create: warm in the creating frame, before any
            // check that can refuse the creation and before the frame checkpoint.
            try config.eips.warm_contract_for_execution(&self.access_list, contract_address);

            if (!(try self.beginCreate(params.caller, params.value, is_transaction)).admitted) {
                log.debug("CREATE2: insufficient balance or nonce at its limit", .{});
                return CallResult.failure(self.getCallArenaAllocator(), remaining_gas) catch unreachable;
            }

            const snapshot_id = try self.journal.create_snapshot();
            const db_snapshot_id = try self.database.create_snapshot();
            const checkpoint = self.frameCheckpoint();

            const existed_before = self.database.account_exists(contract_address.bytes);
            if (existed_before) {
                const existing = try self.database.get_account(contract_address.bytes);
                // EIP-684 + EIP-7610: an address with code, a nonzero nonce, or nonempty
                // storage cannot be created again.
                if (existing != null and (existing.?.nonce != 0 or !std.mem.eql(u8, &existing.?.code_hash, &[_]u8{0} ** 32) or try self.database.has_storage(contract_address.bytes))) {
                    log.debug("CREATE2: collision at address", .{});
                    try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                    return CallResult.failure(self.getCallArenaAllocator(), retained) catch unreachable;
                }
            }

            var result = self.executeCreateInternal(.{
                .caller = params.caller,
                .value = params.value,
                .init_code = params.init_code,
                .gas_left = forwarded,
                .contract_address = contract_address,
                .snapshot_id = snapshot_id,
                .db_snapshot_id = db_snapshot_id,
                .checkpoint = checkpoint,
                .existed_before = existed_before,
            }) catch {
                try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
                return CallResult.failure(self.getCallArenaAllocator(), retained) catch unreachable;
            };

            result.gas_left += retained;
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
            db_snapshot_id: u64,
            checkpoint: FrameCheckpoint,
            existed_before: bool,
        }) !CallResult {
            try self.created_contracts.mark_created(args.contract_address);
            if (args.value > 0) {
                self.transferWithBalanceChecks(args.caller, args.contract_address, args.value, args.snapshot_id) catch {
                    try self.revertFrame(args.snapshot_id, args.db_snapshot_id, args.checkpoint);
                    return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                };
            }
            var result = self.execute_init_code(
                args.init_code,
                args.gas_left,
                args.contract_address,
                args.snapshot_id,
            ) catch |err| {
                log.debug("execute_init_code failed with error: {}", .{err});
                try self.revertFrame(args.snapshot_id, args.db_snapshot_id, args.checkpoint);
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            };
            if (!result.success) {
                log.debug("Init code execution failed, success=false", .{});
                try self.revertFrame(args.snapshot_id, args.db_snapshot_id, args.checkpoint);
                return result;
            }
            var contract_account = self.database.get_account(args.contract_address.bytes) catch {
                try self.revertFrame(args.snapshot_id, args.db_snapshot_id, args.checkpoint);
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
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
                if (config.eips.eip_3541_should_reject_create_with_ef_bytecode(result.output)) {
                    try self.revertFrame(args.snapshot_id, args.db_snapshot_id, args.checkpoint);
                    return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                }
                // EIP-170: reject deployed code exceeding the max code size (Spurious Dragon+;
                // eip_170_max_code_size returns 0xFFFFFF on earlier forks => no limit).
                if (result.output.len > config.eips.eip_170_max_code_size()) {
                    try self.revertFrame(args.snapshot_id, args.db_snapshot_id, args.checkpoint);
                    return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                }
                // EIP-2: charge code-deposit gas (200 per byte of deployed code). When the
                // remaining gas cannot cover it, Homestead+ fails the creation; Frontier
                // instead deploys empty code (the account is still created) without charging.
                const deposit_cost: u64 = @as(u64, @intCast(result.output.len)) * primitives.GasConstants.CreateDataGas;
                if (result.gas_left >= deposit_cost) {
                    result.gas_left -= deposit_cost;
                    const stored_hash = self.database.set_code(result.output) catch {
                        try self.revertFrame(args.snapshot_id, args.db_snapshot_id, args.checkpoint);
                        return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                    };
                    try self.journal.record_code_change(args.snapshot_id, args.contract_address, contract_account.code_hash);
                    contract_account.code_hash = stored_hash;
                } else if (config.eips.hardfork.isAtLeast(.HOMESTEAD)) {
                    try self.revertFrame(args.snapshot_id, args.db_snapshot_id, args.checkpoint);
                    return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
                }
            }
            self.database.set_account(args.contract_address.bytes, contract_account) catch {
                try self.revertFrame(args.snapshot_id, args.db_snapshot_id, args.checkpoint);
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            };

            // CREATE succeeded, commit the snapshot
            try self.database.commit_snapshot(args.db_snapshot_id);

            var final_result = if (result.output.len > 0)
                CallResult.success_with_output(self.getCallArenaAllocator(), result.gas_left, result.output) catch unreachable
            else
                CallResult.success_empty(self.getCallArenaAllocator(), result.gas_left) catch unreachable;
            final_result.trace = result.trace;
            return final_result;
        }

        /// Convert tracer data to ExecutionTrace format
        fn convertTracerToExecutionTrace(allocator: std.mem.Allocator, tracer: anytype) !@import("frame/call_result.zig").ExecutionTrace {
            const call_result = @import("frame/call_result.zig");

            if (!@hasField(@TypeOf(tracer.*), "steps")) {
                log.debug("convertTracerToExecutionTrace: No steps field", .{});
                return call_result.ExecutionTrace{
                    .steps = &[_]call_result.TraceStep{},
                    .allocator = allocator,
                };
            }

            const tracer_steps = tracer.steps.items;
            log.debug("convertTracerToExecutionTrace: Converting {d} tracer steps", .{tracer_steps.len});
            var trace_steps = try allocator.alloc(call_result.TraceStep, tracer_steps.len);
            errdefer allocator.free(trace_steps);

            var allocated_count: usize = 0;
            errdefer {
                for (trace_steps[0..allocated_count]) |*step| step.deinit(allocator);
            }

            for (tracer_steps, 0..) |tracer_step, i| {
                trace_steps[i] = call_result.TraceStep{
                    .pc = @intCast(tracer_step.pc),
                    .opcode = tracer_step.opcode,
                    .opcode_name = try allocator.dupe(u8, tracer_step.opcode_name),
                    .gas = @intCast(tracer_step.gas_before),
                    .depth = tracer_step.depth,
                    .mem_size = @intCast(tracer_step.memory_size_before),
                    .gas_cost = tracer_step.gas_cost,
                    .stack = try allocator.dupe(u256, tracer_step.stack_before),
                    .memory = &.{}, // Memory capture omitted for performance - add if debugging requires it
                    .storage_reads = &.{},
                    .storage_writes = &.{},
                };
                allocated_count += 1;
            }

            return call_result.ExecutionTrace{
                .steps = trace_steps,
                .allocator = allocator,
            };
        }

        /// Owned dispatch analysis (schedule + jump table) built from one bytecode.
        const Analysis = struct {
            schedule: Frame.Dispatch.DispatchSchedule,
            jump_table: Frame.Dispatch.JumpTable,
        };

        /// Build the dispatch schedule and dense jump table in a single pass.
        /// The bytecode analysis is freed before returning; the schedule and jump table
        /// hold no references to it (handlers, inline metadata, and their own arena only).
        fn analyzeCode(self: *Self, allocator: std.mem.Allocator, code: []const u8, tracing: bool) Error!Analysis {
            const handlers = &Frame.opcode_handlers;
            // Bytecode indexes PCs with PcType; reject longer code with an error, never a crash.
            if (code.len > std.math.maxInt(Bytecode.PcType)) return error.BytecodeTooLarge;
            if (tracing) {
                const tracer_ptr = @as(?@TypeOf(&self.tracer), &self.tracer);
                var bytecode = Bytecode.initWithTracer(allocator, code, tracer_ptr) catch |e| return mapBytecodeError(e);
                defer bytecode.deinit();
                const built = Frame.Dispatch.DispatchSchedule.initWithJumpTable(allocator, bytecode, handlers, tracer_ptr) catch |err| {
                    log.err("DispatchSchedule.initWithJumpTable failed: {s} (code_len={}, fusion={})", .{ @errorName(err), code.len, config.enable_fusion });
                    return error.AllocationError;
                };
                return .{ .schedule = built.schedule, .jump_table = built.jump_table };
            }
            var bytecode = Bytecode.init(allocator, code) catch |e| return mapBytecodeError(e);
            defer bytecode.deinit();
            const built = Frame.Dispatch.DispatchSchedule.initWithJumpTable(allocator, bytecode, handlers, null) catch |err| {
                log.err("DispatchSchedule.initWithJumpTable failed: {s} (code_len={}, fusion={})", .{ @errorName(err), code.len, config.enable_fusion });
                return error.AllocationError;
            };
            return .{ .schedule = built.schedule, .jump_table = built.jump_table };
        }

        fn mapBytecodeError(e: anyerror) Error {
            return switch (e) {
                error.InvalidOpcode => error.InvalidOpcode,
                error.InvalidJumpDestination => error.InvalidJumpDestination,
                error.TruncatedPush => error.InvalidOpcode,
                error.OutOfMemory => error.AllocationError,
                else => error.AllocationError,
            };
        }

        /// Return the cached analysis for deployed code, building and caching it on a miss.
        /// Returns null when the code must run uncached: tracing is on, the code has no
        /// cacheable hash (initcode, delegated, all-zero), the cache is full, or the cached
        /// bytes differ from `code`.
        fn cachedAnalysis(self: *Self, code: []const u8, code_hash: ?[32]u8, tracing: bool) Error!?*CachedAnalysis {
            if (tracing) return null;
            const hash = code_hash orelse return null;
            if (std.mem.eql(u8, &hash, &([_]u8{0} ** 32))) return null;
            if (self.analysis_cache.get(hash)) |entry| {
                if (std.mem.eql(u8, entry.code, code)) return entry;
                log.debug("Analysis cache: code hash maps to different bytes; running uncached", .{});
                return null;
            }
            if (self.analysis_cache.count() >= MAX_CACHED_CONTRACTS) return null;

            const entry = try self.allocator.create(CachedAnalysis);
            errdefer self.allocator.destroy(entry);
            const code_copy = try self.allocator.dupe(u8, code);
            errdefer self.allocator.free(code_copy);
            const analysis = try self.analyzeCode(self.allocator, code, false);
            entry.* = .{ .schedule = analysis.schedule, .jump_table = analysis.jump_table, .code = code_copy };
            errdefer {
                entry.jump_table.deinit(self.allocator);
                entry.schedule.deinit();
            }
            try self.analysis_cache.put(self.allocator, hash, entry);
            return entry;
        }

        /// Execute a frame. When the call depth reaches LARGE_STACK_DEPTH, execution hops
        /// once onto a worker thread with a LARGE_STACK_SIZE native stack so a legitimately
        /// deep call chain (up to the 1024 EVM depth limit) cannot overflow the native stack.
        /// There is no concurrency: this thread blocks on join, so EVM state is accessed by
        /// one thread at a time. Shallower calls run inline with no thread overhead.
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
            code_hash: ?[32]u8,
        ) !CallResult {
            if (comptime can_spawn_threads) {
                if (!self.on_large_stack and self.depth >= LARGE_STACK_DEPTH) {
                    @branchHint(.cold);
                    const Result = @TypeOf(self.execute_frame_impl(code, input, gas, address, caller, value, is_static, snapshot_id, code_hash));
                    const Runner = struct {
                        evm: *Self,
                        code: []const u8,
                        input: []const u8,
                        gas: u64,
                        address: primitives.Address,
                        caller: primitives.Address,
                        value: u256,
                        is_static: bool,
                        snapshot_id: Journal.SnapshotIdType,
                        code_hash: ?[32]u8,
                        result: Result = undefined,
                        fn run(ctx: *@This()) void {
                            ctx.result = ctx.evm.execute_frame_impl(ctx.code, ctx.input, ctx.gas, ctx.address, ctx.caller, ctx.value, ctx.is_static, ctx.snapshot_id, ctx.code_hash);
                        }
                    };
                    var ctx = Runner{
                        .evm = self,
                        .code = code,
                        .input = input,
                        .gas = gas,
                        .address = address,
                        .caller = caller,
                        .value = value,
                        .is_static = is_static,
                        .snapshot_id = snapshot_id,
                        .code_hash = code_hash,
                    };
                    self.on_large_stack = true;
                    defer self.on_large_stack = false;
                    // Running inline instead could overflow the native stack and crash, so a
                    // spawn failure fails this call like any other resource exhaustion.
                    const thread = std.Thread.spawn(.{ .stack_size = LARGE_STACK_SIZE }, Runner.run, .{&ctx}) catch |err| {
                        log.err("Failed to spawn large-stack thread at depth {}: {s}", .{ self.depth, @errorName(err) });
                        return error.AllocationError;
                    };
                    thread.join();
                    return ctx.result;
                }
            }
            return self.execute_frame_impl(code, input, gas, address, caller, value, is_static, snapshot_id, code_hash);
        }

        /// Execute a frame by delegating to Frame.interpret (dispatch-based execution)
        fn execute_frame_impl(
            self: *Self,
            code: []const u8,
            input: []const u8,
            gas: u64,
            address: primitives.Address,
            caller: primitives.Address,
            value: u256,
            is_static: bool,
            snapshot_id: Journal.SnapshotIdType,
            code_hash: ?[32]u8,
        ) !CallResult {
            log.debug("EVM.execute_frame: Starting frame, code_len={}, gas={}, depth={}", .{ code.len, gas, self.depth });
            const prev_snapshot = self.current_snapshot_id;
            self.current_snapshot_id = snapshot_id;
            defer self.current_snapshot_id = prev_snapshot;

            // Input is now stored on the frame directly

            self.depth += 1;
            defer if (self.depth > 0) {
                self.depth -= 1;
            };

            self.call_stack[self.depth - 1] = CallStackEntry{ .address = address, .caller = caller, .value = value, .is_static = is_static };
            self.tx_max_depth = @max(self.tx_max_depth, @as(u16, self.depth));

            const gas_after_base = gas;

            const max_gas = @as(u64, @intCast(std.math.maxInt(Frame.GasType)));
            const gas_cast = @as(Frame.GasType, @intCast(@min(gas_after_base, max_gas)));

            const arena_allocator = self.call_arena.allocator();

            // Per-depth pooled stack and memory. Each depth owns its buffers, so a child
            // never reallocates the parent's memory that the child's calldata points into.
            // Buffers are owned by self.allocator (never the call arena) and freed in deinit.
            const pool_idx: usize = self.depth - 1;
            const stack_buf = self.stack_pool[pool_idx] orelse blk: {
                const buf = self.allocator.alignedAlloc(Frame.WordType, @enumFromInt(6), Frame.Stack.stack_capacity) catch return error.AllocationError;
                self.stack_pool[pool_idx] = buf.ptr;
                self.pool_max_depth = @max(self.pool_max_depth, @as(u16, @intCast(pool_idx + 1)));
                break :blk buf.ptr;
            };
            const mem_buf = self.memory_pool[pool_idx] orelse blk: {
                const buf = self.allocator.create(std.ArrayList(u8)) catch return error.AllocationError;
                buf.* = std.ArrayList(u8){};
                buf.ensureTotalCapacity(self.allocator, Frame.config.memory_initial_capacity) catch {
                    self.allocator.destroy(buf);
                    return error.AllocationError;
                };
                self.memory_pool[pool_idx] = buf;
                self.pool_max_depth = @max(self.pool_max_depth, @as(u16, @intCast(pool_idx + 1)));
                break :blk buf;
            };

            var frame = try Frame.initPooled(stack_buf, mem_buf, self.allocator, gas_cast, caller, value, input, @as(*anyopaque, @ptrCast(self)));
            frame.contract_address = address;
            // Output data is copied into the call arena by RETURN/REVERT, so resetting the
            // pooled memory here never invalidates it.
            defer frame.deinitPooled();

            // EIP-2929: Warm the contract address being executed
            try config.eips.warm_contract_for_execution(&self.access_list, address);

            // Note: Size validation is done by caller (execute_init_code checks init code size,
            // execute_call checks runtime code size via bytecode analysis)
            const tracing = self.tracer.config.enabled;

            // Resolve the dispatch analysis: cached for deployed code, otherwise built
            // in the call arena and freed when this frame finishes.
            var owned: Analysis = undefined;
            var owns_analysis = false;
            defer if (owns_analysis) {
                owned.jump_table.deinit(arena_allocator);
                owned.schedule.deinit();
            };
            var schedule_ptr: *const Frame.Dispatch.DispatchSchedule = undefined;
            var jump_table_ptr: *const Frame.Dispatch.JumpTable = undefined;
            if (try self.cachedAnalysis(code, code_hash, tracing)) |entry| {
                schedule_ptr = &entry.schedule;
                jump_table_ptr = &entry.jump_table;
            } else {
                owned = try self.analyzeCode(arena_allocator, code, tracing);
                owns_analysis = true;
                schedule_ptr = &owned.schedule;
                jump_table_ptr = &owned.jump_table;
            }

            var execution_trace: ?@import("frame/call_result.zig").ExecutionTrace = null;
            const Termination = error{ Stop, Return, SelfDestruct };
            var termination_reason: ?Termination = null;

            // Native tier: hot eligible deployed code runs as ARM64 machine code with
            // bit-exact gas/stack/memory/output; null means run the interpreter.
            const native: ?@import("jit_bridge.zig").Outcome = if (comptime config.enable_native_jit)
                (if (!tracing and code_hash != null) self.jit_bridge.tryRun(self, &frame, code, code_hash.?) else null)
            else
                null;
            const execution: Frame.Error!void = if (native) |outcome| switch (outcome) {
                .stop => error.Stop,
                .return_ok => error.Return,
                .revert => error.REVERT,
                .out_of_gas => error.OutOfGas,
                .stack_underflow => error.StackUnderflow,
                .stack_overflow => error.StackOverflow,
                .invalid_jump => error.InvalidJump,
                .invalid_opcode => error.InvalidOpcode,
                .out_of_bounds => error.OutOfBounds,
            } else frame.interpret(schedule_ptr, jump_table_ptr, code);
            execution catch |err| switch (err) {
                error.Stop => termination_reason = error.Stop,
                error.Return => termination_reason = error.Return,
                error.SelfDestruct => termination_reason = error.SelfDestruct,
                error.REVERT => {
                    if (tracing) execution_trace = try convertTracerToExecutionTrace(self.getCallArenaAllocator(), &self.tracer);
                    const gas_left: u64 = @intCast(@max(frame.gas_remaining, 0));
                    // Get output from frame
                    const output_data = frame.output_data;
                    const out_copy = if (output_data.len > 0) blk: {
                        const buf = try self.getCallArenaAllocator().alloc(u8, output_data.len);
                        @memcpy(buf, output_data);
                        break :blk buf;
                    } else &[_]u8{};
                    var result = CallResult.revert_with_data(self.getCallArenaAllocator(), gas_left, out_copy) catch unreachable;
                    result.trace = execution_trace;
                    return result;
                },
                else => {
                    // Invalid bytecode, static-context writes (EIP-214), and exhausted execution budgets are normal
                    // transaction outcomes, not failures of the client itself.
                    switch (err) {
                        error.InvalidOpcode, error.InvalidJump, error.OutOfGas, error.OutOfBounds, error.StackUnderflow, error.StackOverflow, error.ReturnDataNotAvailable, error.WriteProtection =>
                            log.debug("Frame execution halted: {s} (code_len={}, gas={}, depth={})", .{ @errorName(err), code.len, gas, self.depth }),
                        else => log.err("Frame execution failed with error: {s} (code_len={}, gas={}, depth={})", .{ @errorName(err), code.len, gas, self.depth }),
                    }
                    // Try to get partial trace even on error
                    if (tracing) {
                        execution_trace = convertTracerToExecutionTrace(self.getCallArenaAllocator(), &self.tracer) catch blk: {
                            break :blk @import("frame/call_result.zig").ExecutionTrace{
                                .steps = &[_]@import("frame/call_result.zig").TraceStep{},
                                .allocator = self.getCallArenaAllocator(),
                            };
                        };
                    }
                    var failure = (CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable);
                    failure.trace = execution_trace;
                    return failure;
                },
            };

            if (tracing) execution_trace = try convertTracerToExecutionTrace(self.getCallArenaAllocator(), &self.tracer);

            const gas_left: u64 = @intCast(@max(frame.gas_remaining, 0));
            // Get output from frame (set by RETURN/REVERT handlers)
            const output_data = frame.output_data;

            // Set return data using the encapsulated method
            try self.set_return_data(output_data);

            var result: CallResult = undefined;
            if (termination_reason) |reason| {
                switch (reason) {
                    error.Stop => {
                        result = CallResult.success_with_output(self.getCallArenaAllocator(), gas_left, &.{}) catch unreachable;
                    },
                    error.Return => {
                        result = CallResult.success_with_output(self.getCallArenaAllocator(), gas_left, output_data) catch unreachable;
                    },
                    error.SelfDestruct => {
                        result = CallResult.success_with_output(self.getCallArenaAllocator(), gas_left, &.{}) catch unreachable;
                    },
                }
            } else {
                result = CallResult.success_with_output(self.getCallArenaAllocator(), gas_left, output_data) catch unreachable;
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
            if (code.len > config.eips.size_limit()) {
                log.debug("Init code too large: {} > 49152", .{code.len});
                return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;
            }
            const result = self.execute_frame(
                code,
                &.{},
                gas,
                address,
                address,
                0,
                false,
                snapshot_id,
                null, // initcode is never cached
            ) catch |err| {
                log.debug("execute_frame failed with error: {}", .{err});
                return err;
            };
            return result;
        }

        /// Execute a precompile call (inlined)
        fn executePrecompileInline(self: *Self, address: primitives.Address, input: []const u8, gas: u64, is_static: bool, snapshot_id: Journal.SnapshotIdType) !CallResult {
            _ = snapshot_id;
            _ = is_static;
            if (!precompiles.isPrecompile(address, config.eips.hardfork)) return CallResult.failure(self.getCallArenaAllocator(), 0) catch unreachable;

            const result = precompiles.execute(self.getCallArenaAllocator(), address, input, gas, config.eips.hardfork) catch {
                return CallResult{
                    .success = false,
                    .gas_left = 0,
                    .output = &.{},
                };
            };

            // Convert PrecompileResult to CallResult
            // Success is indicated by execute() not returning an error
            return CallResult{
                .success = true,
                .gas_left = gas - result.gas_used,
                .output = result.output,
            };
        }

        /// Get account balance
        pub fn get_balance(self: *Self, address: primitives.Address) Database.Error!u256 {
            if (config.disable_balance_checks) return 0;
            return self.database.get_balance(address.bytes);
        }

        /// Check if account exists
        pub fn account_exists(self: *Self, address: primitives.Address) bool {
            return self.database.account_exists(address.bytes);
        }

        /// Get account code
        pub fn get_code(self: *Self, address: primitives.Address) ![]const u8 {
            return self.codeAt(address);
        }

        /// Code executed at `address` (following EIP-7702 delegation). An account that
        /// does not exist has empty code: calling it succeeds and EXTCODE* see nothing.
        fn codeAt(self: *Self, address: primitives.Address) ![]const u8 {
            return self.database.get_code_by_address(address.bytes) catch |err| switch (err) {
                error.AccountNotFound => &.{},
                else => return err,
            };
        }

        /// Get block information
        pub fn get_block_info(self: *Self) BlockInfo {
            return self.block_info;
        }

        /// Emit log event
        pub fn emit_log(self: *Self, contract_address: primitives.Address, topics: []const u256, data: []const u8) !void {
            // EIP-214: log emission in a static context is a write violation
            if (!eips.Eips.is_log_emission_allowed(self.is_static_context())) return error.StaticCallViolation;

            // Topics and data live in the call arena, like LOG opcode output.
            const topics_copy = try self.getCallArenaAllocator().dupe(u256, topics);
            const data_copy = try self.getCallArenaAllocator().dupe(u8, data);

            try self.logs.append(self.allocator, @import("frame/call_result.zig").Log{
                .address = contract_address,
                .topics = topics_copy,
                .data = data_copy,
            });
        }

        /// Take ownership of the accumulated logs and clear internal storage
        pub fn takeLogs(self: *Self) ![]@import("frame/call_result.zig").Log {
            return try self.logs.toOwnedSlice(self.allocator);
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
        pub fn create_snapshot(self: *Self) Journal.Error!Journal.SnapshotIdType {
            return self.journal.create_snapshot();
        }

        /// Revert state changes to a previous snapshot
        ///
        /// Optimized to avoid allocations: iterate journal entries in reverse
        /// before truncating, applying all reverts in-place.
        pub fn revert_to_snapshot(self: *Self, snapshot_id: Journal.SnapshotIdType) void {
            var start_index: ?usize = null;
            for (self.journal.entries.items, 0..) |entry, i| {
                if (entry.snapshot_id >= snapshot_id) {
                    start_index = i;
                    break;
                }
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
            self.journal.revert_to_snapshot(snapshot_id);
        }

        /// Apply a single journal entry to revert database state
        fn apply_journal_entry_revert(self: *Self, entry: Journal.EntryType) !void {
            switch (entry.data) {
                .storage_change => |sc| {
                    try self.database.set_storage(sc.address.bytes, sc.key, sc.original_value);
                },
                .balance_change => |bc| {
                    var account = (try self.database.get_account(bc.address.bytes)) orelse {
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
                    var account = (try self.database.get_account(nc.address.bytes)) orelse return;
                    account.nonce = nc.original_nonce;
                    try self.database.set_account(nc.address.bytes, account);
                },
                .code_change => |cc| {
                    var account = (try self.database.get_account(cc.address.bytes)) orelse return;
                    account.code_hash = cc.original_code_hash;
                    try self.database.set_account(cc.address.bytes, account);
                },
                .account_created => |ac| {
                    try self.database.delete_account(ac.address.bytes);
                },
                .account_destroyed => |ad| {
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
            // Track address for state dump
            try self.touched_addresses.put(address, {});
            // Track storage slot for state dump in place (never copy ArrayList by value).
            const gop = try self.touched_storage.getOrPut(address);
            if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u256).empty;
            for (gop.value_ptr.items) |existing_slot| {
                if (existing_slot == slot) return;
            }
            try gop.value_ptr.append(self.allocator, slot);
        }

        /// Get the original storage value from the journal
        pub fn get_original_storage(self: *Self, address: primitives.Address, slot: u256) ?u256 {
            return self.journal.get_original_storage(address, slot);
        }

        /// Access an address and return the gas cost (EIP-2929)
        /// Mark `address` warm if it is a precompile in the configured fork.
        fn warmPrecompile(self: *Self, address: primitives.Address) !void {
            if (!precompiles.isPrecompile(address, config.eips.hardfork)) return;
            try self.access_list.pre_warm_addresses(&[_]primitives.Address{address});
        }

        pub fn access_address(self: *Self, address: primitives.Address) !u64 {
            const cost = try self.access_list.access_address(address);
            // Track address for state dump
            try self.touched_addresses.put(address, {});
            return cost;
        }

        /// Access a storage slot and return the gas cost (EIP-2929)
        pub fn access_storage_slot(self: *Self, contract_address: primitives.Address, slot: u256) !u64 {
            const cost = try self.access_list.access_storage_slot(contract_address, slot);
            // Track address for state dump
            try self.touched_addresses.put(contract_address, {});
            // Track storage slot for state dump. Mutate the stored list in place: appending
            // to a by-value copy would lose the slot and leak the reallocated buffer.
            const gop = try self.touched_storage.getOrPut(contract_address);
            if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u256).empty;
            for (gop.value_ptr.items) |existing_slot| {
                if (existing_slot == slot) return cost;
            }
            try gop.value_ptr.append(self.allocator, slot);
            return cost;
        }

        /// Mark a contract for destruction
        pub fn mark_for_destruction(self: *Self, contract_address: primitives.Address, recipient: primitives.Address) !void {
            // EIP-214: Prevent self-destruction in static context
            if (self.is_static_context()) return error.StaticCallViolation;

            // EIP-6780: Handle SELFDESTRUCT based on creation in same transaction
            const created_in_tx = self.created_contracts.was_created_in_tx(contract_address);
            try config.eips.handle_selfdestruct(
                created_in_tx,
                contract_address,
                recipient,
                &self.self_destruct,
                self.database,
                &self.journal,
                self.current_snapshot_id,
            );
        }

        /// Get current call input/calldata
        pub fn get_input(_: *Self) []const u8 {
            // Input is now stored on the frame directly
            return &.{};
        }

        /// Check if hardfork is at least the target
        pub fn is_hardfork_at_least(_: *Self, target: Hardfork) bool {
            return @intFromEnum(config.eips.hardfork) >= @intFromEnum(target);
        }

        /// Get current hardfork (deprecated - use EIPs)
        pub fn get_hardfork(_: *Self) Hardfork {
            return config.eips.hardfork;
        }

        /// Get the call depth for the current frame
        pub fn get_depth(self: *Self) u11 {
            return self.depth;
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
        pub fn get_storage(self: *Self, address: primitives.Address, slot: u256) Database.Error!u256 {
            return self.database.get_storage(address.bytes, slot);
        }

        /// Set storage value
        pub fn set_storage(self: *Self, address: primitives.Address, slot: u256, value: u256) !void {
            // In static context, storage writes are not allowed per EIP-214
            // This check is critical for security and cannot be removed
            if (self.is_static_context()) return error.StaticCallViolation;
            const original_value = try self.get_storage(address, slot);
            try self.record_storage_change(address, slot, original_value);
            try self.database.set_storage(address.bytes, slot, value);
        }

        /// Get transaction gas price
        pub fn get_gas_price(self: *Self) u256 {
            return self.gas_price;
        }

        /// Get return data from last call (returns null if no return data available)
        pub fn get_return_data(self: *const Self) ?[]const u8 {
            return if (self.return_data.items.len > 0) self.return_data.items else null;
        }

        /// Set return data from a call, reusing the backing buffer safely without slice-len shrink bugs.
        pub fn set_return_data(self: *Self, data: []const u8) !void {
            self.return_data.clearRetainingCapacity();
            if (data.len == 0) return;
            self.return_data.appendSlice(self.allocator, data) catch return error.AllocationError;
        }

        /// Clear return data buffer (for CREATE/CREATE2 per EIP-211)
        pub fn clear_return_data(self: *Self) void {
            self.return_data.clearRetainingCapacity();
        }

        /// Check if returndata should be cleared after CREATE/CREATE2 (EIP-211)
        pub fn should_clear_returndata_on_create(_: *Self) bool {
            return config.eips.eip_211_should_clear_returndata_on_create();
        }

        /// Get chain ID
        pub fn get_chain_id(self: *Self) u64 {
            return self.block_info.chain_id;
        }
        /// Record the hash of a recent block so BLOCKHASH can return it. The host must
        /// supply the hashes of the up to 256 blocks before `block_info.number`; the EVM
        /// never invents one. Stored in an O(1) ring indexed by `number % 256`, so a
        /// later number with the same index replaces an earlier one.
        pub fn setBlockHash(self: *Self, number: u64, hash: [32]u8) void {
            self.recent_block_hashes[number % RECENT_BLOCK_HASHES] = .{ .number = number, .hash = hash, .known = true };
        }

        /// Hash of block `block_number` for BLOCKHASH, or null when it is outside
        /// `current - 256 <= n < current` or unknown. Lookup order: the host-provided
        /// ring (`setBlockHash`), then the EIP-2935 history contract when it is active.
        /// Block 0 is in range while the current block is at most 256.
        pub fn get_block_hash(self: *Self, block_number: u64) Database.Error!?[32]u8 {
            const current_block = self.block_info.number;
            if (block_number >= current_block) return null;
            if (current_block - block_number > RECENT_BLOCK_HASHES) return null;

            const entry = self.recent_block_hashes[block_number % RECENT_BLOCK_HASHES];
            if (entry.known and entry.number == block_number) return entry.hash;

            if (config.enable_historical_block_hashes and config.eips.eip_2935_historical_block_hashes_enabled()) {
                const historical_block_hashes = @import("eips_and_hardforks/historical_block_hashes.zig");
                if (try historical_block_hashes.HistoricalBlockHashesContract.getBlockHash(self.database, block_number, current_block)) |hash| {
                    return hash;
                }
            }

            log.debug("BLOCKHASH: no hash known for block {} (current {})", .{ block_number, current_block });
            return null;
        }

        /// Get blob hash for the given index (EIP-4844)
        pub fn get_blob_hash(self: *Self, index: u256) ?[32]u8 {
            if (index >= self.context.blob_versioned_hashes.len) return null;
            const idx = @as(usize, @intCast(index));
            return self.context.blob_versioned_hashes[idx];
        }

        /// Get blob base fee (EIP-4844)
        pub fn get_blob_base_fee(self: *Self) u256 {
            return self.block_info.blob_base_fee;
        }

        /// Add gas refund amount for SSTORE operations
        /// This is called by SSTORE when it needs to add refunds
        pub fn add_gas_refund(self: *Self, amount: u64) void {
            self.gas_refund_counter += amount;
        }
    };
}

// Run the colocated tests of the per-frame checkpointed state with this file's tests.
test {
    _ = @import("storage/access_list.zig");
    _ = @import("storage/self_destruct.zig");
    _ = @import("storage/created_contracts.zig");
    _ = @import("eips_and_hardforks/historical_block_hashes.zig");
}

// All tests should use explicit Evm(.{}) for clarity
test "CallParams and CallResult structures" {
    const TestEvm = Evm(.{});
    const call_params = TestEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 1000000,
        },
    };

    const result = TestEvm.CallResult{
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

    // Test that we can create error values
    const err1: TestEvm.Error = error.InvalidJump;
    const err2: TestEvm.Error = error.OutOfGas;

    // Test that different errors are not equal
    try std.testing.expect(err1 != err2);
}

test "EVM call() entry point method" {
    const TestEvm = Evm(.{});
    const allocator = std.testing.allocator;

    // Create test database
    var db = Database.init(allocator);
    defer db.deinit();
    // Database is now used directly

    // Create EVM instance
    const block_info = BlockInfo{
        .chain_id = 1,
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

    const BerlinEvm = Evm(.{ .eips = eips.Eips{ .hardfork = .BERLIN } });
    var evm = try BerlinEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test that call method exists and has correct signature
    const call_params = TestEvm.CallParams{
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
        const expected_type = TestEvm.Error!TestEvm.CallResult;
        _ = ReturnType;
        _ = expected_type;
        // We can't directly compare error union types, but this ensures it compiles
    }
}

test "EVM call() method routes to different handlers" {
    const TestEvm = Evm(.{});
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

    const BerlinEvm = Evm(.{ .eips = eips.Eips{ .hardfork = .BERLIN } });
    var evm = try BerlinEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test CALL routing
    const call_params = TestEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 1000000,
        },
    };
    _ = evm.call(call_params);

    // Test DELEGATECALL routing
    const delegatecall_params = TestEvm.CallParams{
        .delegatecall = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .input = &.{},
            .gas = 1000000,
        },
    };
    _ = evm.call(delegatecall_params);

    // Test STATICCALL routing
    const staticcall_params = TestEvm.CallParams{
        .staticcall = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .input = &.{},
            .gas = 1000000,
        },
    };
    _ = evm.call(staticcall_params);

    // Test CREATE routing
    const create_params = TestEvm.CallParams{
        .create = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &.{},
            .gas = 1000000,
        },
    };
    _ = evm.call(create_params);

    // Test CREATE2 routing
    const create2_params = TestEvm.CallParams{
        .create2 = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &.{},
            .salt = 0,
            .gas = 1000000,
        },
    };
    _ = evm.call(create2_params);
}

test "Evm creation with custom config" {
    const CustomEvm = Evm(.{
        .max_call_depth = 512,
        .max_input_size = 65536, // 64KB
        .stack_size = 512,
        .max_bytecode_size = 16384,
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

    var evm = try CustomEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    try std.testing.expectEqual(@as(u9, 0), evm.depth);
}

test "Evm init derives effective gas price only when requested" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 100,
        .prev_randao = [_]u8{0} ** 32,
    };
    const context = TransactionContext{
        .gas_limit = 100_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
        .max_fee_per_gas = 150,
        .max_priority_fee_per_gas = 75,
    };
    const LondonEvm = Evm(.{ .eips = eips.Eips{ .hardfork = .LONDON } });

    {
        var derived = try LondonEvm.init(std.testing.allocator, &db, block_info, context, null, primitives.ZERO_ADDRESS);
        defer derived.deinit();
        try std.testing.expectEqual(@as(u256, 150), derived.gas_price);
    }

    {
        var explicit_zero = try LondonEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
        defer explicit_zero.deinit();
        try std.testing.expectEqual(@as(u256, 0), explicit_zero.gas_price);
    }

    {
        var legacy_context = context;
        legacy_context.max_fee_per_gas = null;
        try std.testing.expectError(error.GasPriceRequired, LondonEvm.init(std.testing.allocator, &db, block_info, legacy_context, null, primitives.ZERO_ADDRESS));
    }
}

test "EIP-7623 clamps successful Prague transaction gas to calldata floor" {
    const gas_limit: u64 = 21_011;
    const input = [_]u8{0x00};
    const sender = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0x00} ** 19 };
    const target = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0x00} ** 19 };
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    const context = TransactionContext{
        .gas_limit = gas_limit,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    {
        var db = Database.init(std.testing.allocator);
        defer db.deinit();
        var sender_account = Account.zero();
        sender_account.balance = 1_000_000_000;
        try db.set_account(sender.bytes, sender_account);
        const PragueEvm = Evm(.{ .eips = eips.Eips{ .hardfork = .PRAGUE } });
        var evm = try PragueEvm.init(std.testing.allocator, &db, block_info, context, 10, sender);
        defer evm.deinit();

        var result = evm.call(.{ .call = .{
            .caller = sender,
            .to = target,
            .value = 0,
            .input = &input,
            .gas = gas_limit,
        } });
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(u64, 21_010), gas_limit - result.gas_left);
        try std.testing.expectEqual(@as(u256, 999_789_900), (try db.get_account(sender.bytes)).?.balance);
    }

    {
        var db = Database.init(std.testing.allocator);
        defer db.deinit();
        const CancunEvm = Evm(.{ .eips = eips.Eips{ .hardfork = .CANCUN } });
        var evm = try CancunEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
        defer evm.deinit();

        var result = evm.call(.{ .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = target,
            .value = 0,
            .input = &input,
            .gas = gas_limit,
        } });
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(u64, 21_004), gas_limit - result.gas_left);
    }
}

test "EIP-7825 rejects Osaka transaction above the gas limit cap before nonce increment" {
    const sender = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0x00} ** 19 };
    const target = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0x00} ** 19 };
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 0,
        .gas_limit = 60_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    const context = TransactionContext{
        .gas_limit = eips.TX_GAS_LIMIT_CAP + 1,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    var sender_account = Account.zero();
    sender_account.balance = 1_000_000_000_000;
    try db.set_account(sender.bytes, sender_account);
    const OsakaEvm = Evm(.{ .eips = eips.Eips{ .hardfork = .OSAKA } });
    var evm = try OsakaEvm.init(std.testing.allocator, &db, block_info, context, 1, sender);
    defer evm.deinit();

    var result = evm.call(.{ .call = .{
        .caller = sender,
        .to = target,
        .value = 0,
        .input = &.{},
        .gas = eips.TX_GAS_LIMIT_CAP + 1,
    } });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 0), result.gas_left);
    const after = (try db.get_account(sender.bytes)).?;
    try std.testing.expectEqual(@as(u64, 0), after.nonce);
    try std.testing.expectEqual(@as(u256, 1_000_000_000_000), after.balance);
}

test "EIP-7825 accepts Osaka transaction at exactly the gas limit cap" {
    const sender = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0x00} ** 19 };
    const target = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0x00} ** 19 };
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 0,
        .gas_limit = 60_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    const context = TransactionContext{
        .gas_limit = eips.TX_GAS_LIMIT_CAP,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    var sender_account = Account.zero();
    sender_account.balance = 1_000_000_000_000;
    try db.set_account(sender.bytes, sender_account);
    const OsakaEvm = Evm(.{ .eips = eips.Eips{ .hardfork = .OSAKA } });
    var evm = try OsakaEvm.init(std.testing.allocator, &db, block_info, context, 1, sender);
    defer evm.deinit();

    var result = evm.call(.{ .call = .{
        .caller = sender,
        .to = target,
        .value = 0,
        .input = &.{},
        .gas = eips.TX_GAS_LIMIT_CAP,
    } });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, eips.TX_GAS_LIMIT_CAP - 21_000), result.gas_left);
    try std.testing.expectEqual(@as(u64, 1), (try db.get_account(sender.bytes)).?.nonce);
}

test "EIP-7825 does not cap Prague transaction gas" {
    const sender = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0x00} ** 19 };
    const target = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0x00} ** 19 };
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 0,
        .gas_limit = 60_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    const context = TransactionContext{
        .gas_limit = eips.TX_GAS_LIMIT_CAP + 1,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    var sender_account = Account.zero();
    sender_account.balance = 1_000_000_000_000;
    try db.set_account(sender.bytes, sender_account);
    const PragueEvm = Evm(.{ .eips = eips.Eips{ .hardfork = .PRAGUE } });
    var evm = try PragueEvm.init(std.testing.allocator, &db, block_info, context, 1, sender);
    defer evm.deinit();

    var result = evm.call(.{ .call = .{
        .caller = sender,
        .to = target,
        .value = 0,
        .input = &.{},
        .gas = eips.TX_GAS_LIMIT_CAP + 1,
    } });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, eips.TX_GAS_LIMIT_CAP + 1 - 21_000), result.gas_left);
    try std.testing.expectEqual(@as(u64, 1), (try db.get_account(sender.bytes)).?.nonce);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Set depth to max
    evm.depth = 1024;

    // Try to make a call - should fail due to depth limit
    const result = evm.inner_call(Evm(.{}).CallParams{
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    _ = [_]u8{0x00};

    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };

    // This should work when call method is properly implemented
    const result = evm.call(call_params);

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Set up contract with bytecode [0x00] (STOP)
    const contract_address: primitives.Address = .{ .bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0x56, 0x78, 0x90 } };
    const bytecode = [_]u8{0x00};
    const code_hash = try db.set_code(&bytecode);

    // Create account with the code
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(contract_address.bytes, account);

    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };

    const result = evm.call(call_params);

    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
}

test "access_storage_slot tracks every slot for the same address" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const contract_address: primitives.Address = .{ .bytes = [_]u8{0x42} ** 20 };
    // Enough distinct slots to force the tracked list to reallocate several times.
    var slot: u256 = 0;
    while (slot < 40) : (slot += 1) {
        _ = try evm.access_storage_slot(contract_address, slot);
    }
    // Re-accessing a tracked slot must not duplicate it.
    _ = try evm.access_storage_slot(contract_address, 7);

    const slots = evm.touched_storage.get(contract_address) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 40), slots.items.len);
    for (slots.items, 0..) |tracked, i| {
        try std.testing.expectEqual(@as(u256, i), tracked);
    }
}

test "analysis cache reuses one schedule across calls and pooled frames are recycled" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // JUMP over an INVALID to a JUMPDEST, then MSTORE 0x2a and RETURN 32 bytes.
    // Exercises the cached jump table on every call.
    const contract_address: primitives.Address = .{ .bytes = [_]u8{0x51} ** 20 };
    const bytecode = [_]u8{
        0x60, 0x04, // PUSH1 4
        0x56, // JUMP
        0xfe, // INVALID
        0x5b, // JUMPDEST
        0x60, 0x2a, // PUSH1 0x2a
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };
    const code_hash = try db.set_code(&bytecode);
    try db.set_account(contract_address.bytes, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };

    var first = evm.call(call_params);
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.success);
    try std.testing.expectEqual(@as(usize, 32), first.output.len);
    try std.testing.expectEqual(@as(u8, 0x2a), first.output[31]);
    try std.testing.expectEqual(@as(u32, 1), evm.analysis_cache.count());
    const entry = evm.analysis_cache.get(code_hash) orelse return error.TestUnexpectedResult;
    // Pools and call stack bookkeeping after the transaction
    try std.testing.expectEqual(@as(u16, 1), evm.pool_max_depth);
    try std.testing.expectEqual(@as(u16, 0), evm.tx_max_depth);
    try std.testing.expect(evm.call_stack[0].caller.equals(primitives.Address.ZERO_ADDRESS));
    try std.testing.expectEqual(@as(usize, 0), evm.memory_pool[0].?.items.len);

    var second = evm.call(call_params);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(second.success);
    try std.testing.expectEqualSlices(u8, first.output, second.output);
    try std.testing.expectEqual(first.gas_left, second.gas_left);
    // Same cache entry, no new analysis
    try std.testing.expectEqual(@as(u32, 1), evm.analysis_cache.count());
    try std.testing.expectEqual(entry, evm.analysis_cache.get(code_hash).?);
    try std.testing.expectEqual(@as(u16, 1), evm.pool_max_depth);
}

test "deep self-recursion crosses the large-stack hop without crashing" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

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
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // CALL(gas=GAS, to=ADDRESS, value=0, in=0/0, out=0/0) then STOP: recurses until gas runs out.
    const contract_address: primitives.Address = .{ .bytes = [_]u8{0x77} ** 20 };
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (retLen)
        0x60, 0x00, // PUSH1 0 (retOffset)
        0x60, 0x00, // PUSH1 0 (argsLen)
        0x60, 0x00, // PUSH1 0 (argsOffset)
        0x60, 0x00, // PUSH1 0 (value)
        0x30, // ADDRESS
        0x5a, // GAS
        0xf1, // CALL
        0x00, // STOP
    };
    const code_hash = try db.set_code(&bytecode);
    try db.set_account(contract_address.bytes, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // inner_call skips the transaction-end reset so the reached depth stays observable.
    const result = evm.inner_call(Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 30000000,
        },
    });
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u11, 0), evm.depth);
    try std.testing.expect(!evm.on_large_stack);
    try std.testing.expect(evm.tx_max_depth > Evm(.{}).LARGE_STACK_DEPTH);
    try std.testing.expect(evm.tx_max_depth <= 1024);
    try std.testing.expectEqual(evm.tx_max_depth, evm.pool_max_depth);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Create contract with simple init code that returns [0x00] (STOP)
    const init_code = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x52, 0x60, 0x01, 0x60, 0x00, 0xF3 }; // PUSH1 1 PUSH1 0 MSTORE PUSH1 1 PUSH1 0 RETURN

    const create_params = Evm(.{}).CallParams{
        .create = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &init_code,
            .gas = 100000,
        },
    };

    const result = evm.call(create_params);

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Call with very low gas (should fail or return with low gas left)
    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 10, // Very low gas
        },
    };

    const result = evm.call(call_params);

    // Should either fail or consume most/all gas
    try std.testing.expect(result.gas_left <= 10);
}

test "Journal - snapshot creation and management" {
    const journal_mod = @import("storage/journal.zig");
    const JournalType = journal_mod.Journal(.{});

    var journal = try JournalType.init(std.testing.allocator);
    defer journal.deinit();

    try std.testing.expectEqual(@as(u32, 0), journal.next_snapshot_id);
    try std.testing.expectEqual(@as(usize, 0), journal.entry_count());

    // Create snapshots
    const snapshot1 = try journal.create_snapshot();
    const snapshot2 = try journal.create_snapshot();
    const snapshot3 = try journal.create_snapshot();

    try std.testing.expectEqual(@as(u32, 0), snapshot1);
    try std.testing.expectEqual(@as(u32, 1), snapshot2);
    try std.testing.expectEqual(@as(u32, 2), snapshot3);
    try std.testing.expectEqual(@as(u32, 3), journal.next_snapshot_id);
}

test "Journal - storage change recording" {
    const journal_mod = @import("storage/journal.zig");
    const JournalType = journal_mod.Journal(.{});

    var journal = try JournalType.init(std.testing.allocator);
    defer journal.deinit();

    const snapshot_id = try journal.create_snapshot();
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
    const journal_mod = @import("storage/journal.zig");
    const JournalType = journal_mod.Journal(.{});

    var journal = try JournalType.init(std.testing.allocator);
    defer journal.deinit();

    const snapshot1 = try journal.create_snapshot();
    const snapshot2 = try journal.create_snapshot();
    const snapshot3 = try journal.create_snapshot();

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
    const journal_mod = @import("storage/journal.zig");
    const JournalType = journal_mod.Journal(.{});

    var journal = try JournalType.init(std.testing.allocator);
    defer journal.deinit();

    const snapshot_id = try journal.create_snapshot();
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
    const journal_mod = @import("storage/journal.zig");
    const JournalType = journal_mod.Journal(.{});

    var journal = try JournalType.init(std.testing.allocator);
    defer journal.deinit();

    // Revert with no entries should not crash
    journal.revert_to_snapshot(0);
    try std.testing.expectEqual(@as(usize, 0), journal.entry_count());

    // Create entries and revert to future snapshot
    const snapshot = try journal.create_snapshot();
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
        .stack_size = 256,
        .max_bytecode_size = 12288,
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

    var evm = try CustomEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
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

    const LondonEvm = Evm(.{ .eips = eips.Eips{ .hardfork = .LONDON } });
    var evm = try LondonEvm.init(std.testing.allocator, &db, block_info, context, gas_price, origin);
    defer evm.deinit();

    // Verify all fields were set correctly
    try std.testing.expectEqual(@as(u11, 0), evm.depth);
    try std.testing.expectEqual(block_info.number, evm.block_info.number);
    try std.testing.expectEqual(context.chain_id, evm.context.chain_id);
    try std.testing.expectEqual(gas_price, evm.gas_price);
    try std.testing.expectEqual(origin, evm.origin);
    try std.testing.expectEqual(Hardfork.LONDON, evm.get_hardfork());

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const address = primitives.ZERO_ADDRESS;
    const balance: u256 = 1000000000000000000; // 1 ETH

    // Set account balance in database
    const account = @import("storage/database_interface_account.zig").Account{
        .balance = balance,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(address.bytes, account);

    const retrieved_balance = try evm.get_balance(address);
    try std.testing.expectEqual(balance, retrieved_balance);

    const zero_address: primitives.Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };
    const zero_balance = try evm.get_balance(zero_address);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const address = primitives.ZERO_ADDRESS;
    const key: u256 = 42;
    const value: u256 = 0xDEADBEEF;

    // Initially should return zero
    const initial_value = try evm.get_storage(address, key);
    try std.testing.expectEqual(@as(u256, 0), initial_value);

    // Set storage value
    try evm.set_storage(address, key, value);

    // Retrieve and verify
    const retrieved_value = try evm.get_storage(address, key);
    try std.testing.expectEqual(value, retrieved_value);

    const different_key: u256 = 99;
    const different_value = try evm.get_storage(address, different_key);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const address = primitives.ZERO_ADDRESS;
    const account = @import("storage/database_interface_account.zig").Account{
        .balance = 1000,
        .nonce = 1,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(address.bytes, account);

    const exists = evm.account_exists(address);
    try std.testing.expect(exists);

    const non_existing: primitives.Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 100,
            .input = &.{},
            .gas = 100000,
        },
    };

    const call_result = evm.call(call_params);
    try std.testing.expect(call_result.success);

    // Test STATICCALL operation (no value transfer allowed)
    const static_params = Evm(.{}).CallParams{
        .staticcall = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .input = &.{},
            .gas = 100000,
        },
    };

    const static_result = evm.call(static_params);
    try std.testing.expect(static_result.success);

    // Test DELEGATECALL operation (preserves caller context)
    const delegate_params = Evm(.{}).CallParams{
        .delegatecall = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .input = &.{},
            .gas = 100000,
        },
    };

    const delegate_result = evm.call(delegate_params);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Set up caller with balance
    const caller_address: primitives.Address = .{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(caller_address.bytes, caller_account);

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

    const create_params = Evm(.{}).CallParams{
        .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &init_code,
            .gas = 100000,
        },
    };

    const result = evm.call(create_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    // Verify successful creation
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
    try std.testing.expectEqual(@as(usize, 20), result.output.len);

    // Extract contract address from output
    const contract_address: primitives.Address = .{ .bytes = result.output[0..20].* };

    // Verify contract was created
    const created_account = (try db.get_account(contract_address.bytes)).?;
    try std.testing.expectEqual(@as(u64, 1), created_account.nonce);

    // Verify caller nonce was incremented
    const updated_caller = (try db.get_account(caller_address.bytes)).?;
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Set up caller with balance
    const caller_address: primitives.Address = .{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const initial_balance: u256 = 1000000;
    const transfer_value: u256 = 12345;
    const caller_account = Account{
        .balance = initial_balance,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(caller_address.bytes, caller_account);

    // Init code that returns empty contract
    const init_code = [_]u8{ 0x00, 0x00, 0xF3 }; // STOP STOP RETURN

    const create_params = Evm(.{}).CallParams{
        .create = .{
            .caller = caller_address,
            .value = transfer_value,
            .init_code = &init_code,
            .gas = 100000,
        },
    };

    const result = evm.call(create_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    try std.testing.expect(result.success);

    // Extract contract address
    const contract_address: primitives.Address = .{ .bytes = result.output[0..20].* };

    // Verify balances
    const caller_after = (try db.get_account(caller_address.bytes)).?;
    try std.testing.expectEqual(initial_balance - transfer_value, caller_after.balance);

    const contract_account = (try db.get_account(contract_address.bytes)).?;
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const caller_address: primitives.Address = .{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const caller_account = Account{
        .balance = 100,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(caller_address.bytes, caller_account);

    const create_params = Evm(.{}).CallParams{
        .create = .{
            .caller = caller_address,
            .value = 1000, // More than balance
            .init_code = &.{0x00}, // STOP
            .gas = 100000,
        },
    };

    const result = evm.call(create_params);

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const caller_address: primitives.Address = .{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(caller_address.bytes, caller_account);

    // Simple init code
    const init_code = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    const salt: u256 = 0x1234567890ABCDEF;

    const create2_params = Evm(.{}).CallParams{
        .create2 = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &init_code,
            .salt = salt,
            .gas = 100000,
        },
    };

    const result = evm.call(create2_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    // Verify successful creation
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
    try std.testing.expectEqual(@as(usize, 20), result.output.len);

    // Extract contract address
    const contract_address: primitives.Address = .{ .bytes = result.output[0..20].* };

    // Verify contract was created
    const created_account = (try db.get_account(contract_address.bytes)).?;
    try std.testing.expectEqual(@as(u64, 1), created_account.nonce);

    // Calculate expected address using CREATE2 formula
    const keccak_asm = @import("crypto").keccak_asm;
    var init_code_hash: [32]u8 = undefined;
    try keccak_asm.keccak256(&init_code, &init_code_hash);
    const salt_bytes = @as([32]u8, @bitCast(salt));
    const expected_address = primitives.Address.get_create2_address(caller_address, salt_bytes, init_code_hash);

    // Verify the address matches the expected CREATE2 address
    try std.testing.expectEqual(expected_address, contract_address);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const caller_address: primitives.Address = .{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const init_code = [_]u8{ 0x00, 0x00, 0xF3 }; // STOP STOP RETURN
    const salt: u256 = 0xDEADBEEF;

    // Calculate expected address
    const keccak_asm = @import("crypto").keccak_asm;
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
    try db.set_account(caller_address.bytes, caller_account);

    const create2_params = Evm(.{}).CallParams{
        .create2 = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &init_code,
            .salt = salt,
            .gas = 100000,
        },
    };

    const result = evm.call(create2_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    try std.testing.expect(result.success);

    const actual_address: primitives.Address = .{ .bytes = result.output[0..20].* };
    try std.testing.expectEqual(expected_address, actual_address);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const caller_address: primitives.Address = .{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };

    // Calculate what the contract address will be
    const expected_address = primitives.Address.getContractAddress(caller_address, 0);

    // Pre-create an account at that address with code
    const existing_code = [_]u8{ 0x60, 0x00 }; // PUSH1 0
    const code_hash = try db.set_code(&existing_code);
    const existing_account = Account{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(expected_address.bytes, existing_account);

    // Create caller account
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(caller_address.bytes, caller_account);

    const create_params = Evm(.{}).CallParams{
        .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &.{0x00}, // STOP
            .gas = 100000,
        },
    };

    const result = evm.call(create_params);

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const caller_address: primitives.Address = .{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(caller_address.bytes, caller_account);

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

    const create_params = Evm(.{}).CallParams{
        .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &init_code,
            .gas = 200000,
        },
    };

    const result = evm.call(create_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    try std.testing.expect(result.success);

    const contract_address: primitives.Address = .{ .bytes = result.output[0..20].* };

    // Verify the storage was set during init
    const stored_value = try db.get_storage(contract_address.bytes, 0);
    try std.testing.expectEqual(@as(u256, 42), stored_value);

    // Verify the runtime code was stored
    const runtime_code = try db.get_code_by_address(contract_address.bytes);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
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

    const factory_address: primitives.Address = .{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };
    const code_hash = try db.set_code(&factory_bytecode);
    try db.set_account(factory_address.bytes, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    const caller_address: primitives.Address = .{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    try db.set_account(caller_address.bytes, Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    // Call the factory to create a child contract
    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = caller_address,
            .to = factory_address,
            .value = 0,
            .input = &.{},
            .gas = 500000,
        },
    };

    const result = evm.call(call_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 20), result.output.len);

    // The output should contain the address of the created child contract
    const child_address: primitives.Address = .{ .bytes = result.output[0..20].* };

    // Verify child contract exists
    const child_account = try db.get_account(child_address.bytes);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test emit_log functionality
    const test_address = primitives.ZERO_ADDRESS;
    const topics = [_]u256{ 0x1234, 0x5678 };
    const data = "test log data";

    // Emit a log
    try evm.emit_log(test_address, &topics, data);

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
    defer Evm(.{}).CallResult.deinitLogsSlice(taken_logs, evm.allocator);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Create bytecode that emits LOG0 (0xA0 opcode)
    // PUSH1 0x05 (data length)
    // PUSH1 0x00 (data offset)
    // LOG0
    const bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x00, 0xA0, 0x00 }; // Last 0x00 is STOP
    const code_hash = try db.set_code(&bytecode);

    const contract_address: primitives.Address = .{ .bytes = [_]u8{0x12} ++ [_]u8{0} ** 19 };
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(contract_address.bytes, account);

    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };

    const result = evm.call(call_params);
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
    const LondonEvm = Evm(.{ .eips = eips.Eips{ .hardfork = .LONDON } });
    var london_evm = try LondonEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer london_evm.deinit();

    try std.testing.expectEqual(Hardfork.LONDON, london_evm.get_hardfork());
    try std.testing.expect(london_evm.is_hardfork_at_least(.HOMESTEAD));
    try std.testing.expect(london_evm.is_hardfork_at_least(.LONDON));
    try std.testing.expect(!london_evm.is_hardfork_at_least(.CANCUN));

    const CancunEvm = Evm(.{ .eips = eips.Eips{ .hardfork = .CANCUN } });
    var cancun_evm = try CancunEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS, .BERLIN);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Create input that exceeds max_input_size (131072 bytes)
    const large_input = try std.testing.allocator.alloc(u8, 200000);
    defer std.testing.allocator.free(large_input);
    @memset(large_input, 0xFF);

    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = large_input,
            .gas = 100000,
        },
    };

    const result = evm.call(call_params);

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const init_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xF3 }; // PUSH1 0 PUSH1 0 RETURN (empty contract)
    const salt: u256 = 0x1234567890ABCDEF;

    const create2_params = Evm(.{}).CallParams{
        .create2 = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &init_code,
            .salt = salt,
            .gas = 100000,
        },
    };

    const result = evm.call(create2_params);
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

    var evm = try TestEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test calling ECRECOVER precompile (address 0x01)
    const ecrecover_address = [_]u8{0} ** 19 ++ [_]u8{1}; // 0x0000...0001
    const input_data = [_]u8{0} ** 128; // Invalid ECRECOVER input (all zeros)

    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = .{ .bytes = ecrecover_address },
            .value = 0,
            .input = &input_data,
            .gas = 100000,
        },
    };

    const result = evm.call(call_params);
    // ECRECOVER should handle invalid input gracefully
    try std.testing.expect(result.gas_left < 100000); // Some gas should be consumed
}

test "Error handling - REVERT should preserve data and error message in both tracing and non-tracing modes" {
    const allocator = std.testing.allocator;

    // Initialize database and EVM
    var db = Database.init(allocator);
    defer db.deinit();

    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };

    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .chain_id = 1,
    };

    // Test non-tracing mode first (this is where the critical bug is)
    {
        var vm = try Evm(.{}).init(allocator, &db, block_info, tx_context, 0, primitives.Address.ZERO_ADDRESS, .BERLIN);
        defer vm.deinit();

        const contract_addr = primitives.Address{ .bytes = [_]u8{0x12} ** 20 };

        // Bytecode: Store "FAIL" (0x4641494c) in memory and revert with it
        // PUSH4 0x4641494c (FAIL), PUSH1 0, MSTORE
        // PUSH1 4 (size), PUSH1 28 (offset), REVERT
        const bytecode = [_]u8{
            0x63, 0x46, 0x41, 0x49, 0x4c, // PUSH4 "FAIL"
            0x60, 0x00, // PUSH1 0
            0x52, // MSTORE
            0x60, 0x04, // PUSH1 4 (size)
            0x60, 0x1c, // PUSH1 28 (offset)
            0xfd, // REVERT
        };

        const code_hash = try db.set_code(&bytecode);
        const account = Account{
            .balance = 0,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
            .nonce = 0,
            .delegated_address = null,
        };
        try db.set_account(contract_addr.bytes, account);

        // Execute call that should revert (non-tracing mode)
        const params = Evm(.{}).CallParams{ .call = .{
            .caller = primitives.Address.ZERO_ADDRESS,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = 100_000,
        } };

        const result = vm.call(params);

        // Verify revert was handled correctly
        try std.testing.expect(!result.success);

        // After fix: Output should contain "FAIL" in non-tracing mode
        log.debug("Non-tracing mode - Output length: {d}", .{result.output.len});
        if (result.output.len > 0) {
            log.debug("Non-tracing mode - Output data: {s}", .{result.output});
        }

        // After fix: This should work because non-tracing mode now preserves revert data
        try std.testing.expect(result.output.len == 4);
        try std.testing.expect(std.mem.eql(u8, result.output, "FAIL"));

        // After fix: Error message should not be empty
        log.debug("Non-tracing mode - Error info: {any}", .{result.error_info});
        try std.testing.expect(result.error_info != null);
        if (result.error_info) |info| {
            try std.testing.expect(std.mem.eql(u8, info, "execution reverted"));
        }

        // Gas should be partially consumed, not zero
        log.debug("Non-tracing mode - Gas left: {d}", .{result.gas_left});
        try std.testing.expect(result.gas_left < 100_000); // Some gas should be consumed

        // Clean up result
        var mutable_result = result;
        mutable_result.deinit(allocator);
    }

    // Test tracing mode (this should work better but still has error_info issue)
    {
        const TracingEvm = Evm(.{ .TracerType = @import("tracer/tracer.zig").JSONRPCTracer });
        var vm = try TracingEvm.init(allocator, &db, block_info, tx_context, 0, primitives.Address.ZERO_ADDRESS, .BERLIN);
        defer vm.deinit();

        const contract_addr = primitives.Address{ .bytes = [_]u8{0x13} ** 20 };

        // Same bytecode as above
        const bytecode = [_]u8{
            0x63, 0x46, 0x41, 0x49, 0x4c, // PUSH4 "FAIL"
            0x60, 0x00, // PUSH1 0
            0x52, // MSTORE
            0x60, 0x04, // PUSH1 4 (size)
            0x60, 0x1c, // PUSH1 28 (offset)
            0xfd, // REVERT
        };

        const code_hash = try db.set_code(&bytecode);
        const account = Account{
            .balance = 0,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
            .nonce = 0,
            .delegated_address = null,
        };
        try db.set_account(contract_addr.bytes, account);

        // Execute call that should revert (tracing mode)
        const params = TracingEvm.CallParams{ .call = .{
            .caller = primitives.Address.ZERO_ADDRESS,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = 100_000,
        } };

        const result = vm.call(params);

        // Verify revert was handled correctly
        try std.testing.expect(!result.success);

        // In tracing mode, output should be preserved
        log.debug("Tracing mode - Output length: {d}", .{result.output.len});
        if (result.output.len > 0) {
            log.debug("Tracing mode - Output data: {s}", .{result.output});
        }

        // This should work in tracing mode
        try std.testing.expect(result.output.len == 4);
        try std.testing.expect(std.mem.eql(u8, result.output, "FAIL"));

        // After fix: Error message should not be empty even in tracing mode
        log.debug("Tracing mode - Error info: {any}", .{result.error_info});
        try std.testing.expect(result.error_info != null);
        if (result.error_info) |info| {
            try std.testing.expect(std.mem.eql(u8, info, "execution reverted"));
        }

        // Gas should be partially consumed
        log.debug("Tracing mode - Gas left: {d}", .{result.gas_left});
        try std.testing.expect(result.gas_left > 0);
        try std.testing.expect(result.gas_left < 100_000);

        // Verify trace is present
        try std.testing.expect(result.trace != null);

        // Clean up result
        var mutable_result = result;
        mutable_result.deinit(allocator);
    }
}

test "Error handling - REVERT with empty data should still have error message" {
    const allocator = std.testing.allocator;

    // Initialize database and EVM
    var db = Database.init(allocator);
    defer db.deinit();

    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };

    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var vm = try Evm(.{}).init(allocator, &db, block_info, tx_context, 0, primitives.Address.ZERO_ADDRESS, .BERLIN);
    defer vm.deinit();

    const contract_addr = primitives.Address{ .bytes = [_]u8{0x14} ** 20 };

    // Bytecode: Simple REVERT with no data
    // PUSH1 0 (size), PUSH1 0 (offset), REVERT
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xfd, // REVERT
    };

    const code_hash = try db.set_code(&bytecode);
    const account = Account{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
        .delegated_address = null,
    };
    try db.set_account(contract_addr.bytes, account);

    // Execute call that should revert
    const params = Evm(.{}).CallParams{ .call = .{
        .caller = primitives.Address.ZERO_ADDRESS,
        .to = contract_addr,
        .value = 0,
        .input = &.{},
        .gas = 100_000,
    } };

    const result = vm.call(params);

    // Verify revert was handled correctly
    try std.testing.expect(!result.success);

    // Output should be empty
    try std.testing.expect(result.output.len == 0);

    // After fix: Error message should indicate revert even with empty data
    log.debug("Empty revert - Error info: {any}", .{result.error_info});
    try std.testing.expect(result.error_info != null);
    if (result.error_info) |info| {
        try std.testing.expect(std.mem.eql(u8, info, "execution reverted"));
    }

    // Gas should be partially consumed
    try std.testing.expect(result.gas_left < 100_000);

    // Clean up result
    var mutable_result = result;
    mutable_result.deinit(allocator);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test IDENTITY precompile - should return input data unchanged
    const identity_address = [_]u8{0} ** 19 ++ [_]u8{4}; // 0x0000...0004
    const test_data = "Hello, World!";

    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = .{ .bytes = identity_address },
            .value = 0,
            .input = test_data,
            .gas = 100000,
        },
    };

    const result = evm.call(call_params);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test SHA256 precompile
    const sha256_address = [_]u8{0} ** 19 ++ [_]u8{2}; // 0x0000...0002
    const test_input = "";

    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = .{ .bytes = sha256_address },
            .value = 0,
            .input = test_input,
            .gas = 100000,
        },
    };

    const result = evm.call(call_params);
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

    var evm = try NoPrecompileEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Try to call IDENTITY precompile - should be treated as regular call
    const identity_address = [_]u8{0} ** 19 ++ [_]u8{4}; // 0x0000...0004
    const test_data = "Hello, World!";

    const call_params = NoPrecompileEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = .{ .bytes = identity_address },
            .value = 0,
            .input = test_data,
            .gas = 100000,
        },
    };

    const result = evm.call(call_params);

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test invalid precompile address (0x0B - beyond supported range)
    const invalid_address = [_]u8{0} ** 19 ++ [_]u8{11}; // 0x0000...000B

    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = .{ .bytes = invalid_address },
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };

    const result = evm.call(call_params);

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Deploy a simple infinite loop contract
    // JUMPDEST (0x5b) PUSH1 0x00 (0x6000) JUMP (0x56)
    const loop_bytecode = [_]u8{ 0x5b, 0x60, 0x00, 0x56 };
    const deploy_address: primitives.Address = .{ .bytes = [_]u8{0} ** 19 ++ [_]u8{1} };
    const code_hash = try db.set_code(&loop_bytecode);
    try db.set_account(deploy_address.bytes, Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Test 1: Very low gas limit - should fail quickly
    {
        const start_time = std.time.nanoTimestamp();
        const result = evm.call(.{
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
        evm.tracer.onPerformanceWarning("Low gas (100)", elapsed, 1_000_000);
    }

    // Test 2: Medium gas limit
    {
        const start_time = std.time.nanoTimestamp();
        const result = evm.call(.{
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
        evm.tracer.onPerformanceWarning("Medium gas (10k)", elapsed, 10_000_000);
    }

    // Test 3: High gas limit
    {
        const start_time = std.time.nanoTimestamp();
        const result = evm.call(.{
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
        evm.tracer.onPerformanceWarning("High gas (1M)", elapsed, 100_000_000);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test 1: Call to non-existent contract
    {
        const empty_address: primitives.Address = .{ .bytes = [_]u8{0} ** 19 ++ [_]u8{99} };
        const start_time = std.time.nanoTimestamp();
        const result = evm.call(.{
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
        evm.tracer.onPerformanceWarning("Empty contract", elapsed, 1_000_000);
    }

    // Test 2: Simple contract that returns immediately (STOP opcode)
    {
        const stop_bytecode = [_]u8{0x00}; // STOP
        const stop_address: primitives.Address = .{ .bytes = [_]u8{0} ** 19 ++ [_]u8{2} };
        const code_hash = try db.set_code(&stop_bytecode);
        try db.set_account(stop_address.bytes, Account{
            .nonce = 0,
            .balance = 0,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
        });

        const start_time = std.time.nanoTimestamp();
        const result = evm.call(.{
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
        evm.tracer.onPerformanceWarning("STOP contract", elapsed, 1_000_000);
    }

    // Test 3: Contract with some computation
    {
        // PUSH1 0x05, PUSH1 0x03, ADD, PUSH1 0x00, MSTORE, STOP
        // Adds 3 + 5 and stores in memory
        const add_bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01, 0x60, 0x00, 0x52, 0x00 };
        const add_address: primitives.Address = .{ .bytes = [_]u8{0} ** 19 ++ [_]u8{3} };
        const code_hash = try db.set_code(&add_bytecode);
        try db.set_account(add_address.bytes, Account{
            .nonce = 0,
            .balance = 0,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
        });

        const start_time = std.time.nanoTimestamp();
        const result = evm.call(.{
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
        evm.tracer.onPerformanceWarning("ADD contract", elapsed, 1_000_000);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Create a large contract that does simple operations
    var large_bytecode = std.ArrayList(u8){};
    defer large_bytecode.deinit(std.testing.allocator);

    // Add many PUSH1/POP pairs (each costs gas but doesn't loop)
    for (0..1000) |_| {
        try large_bytecode.append(std.testing.allocator, 0x60); // PUSH1
        try large_bytecode.append(std.testing.allocator, 0x42); // value
        try large_bytecode.append(std.testing.allocator, 0x50); // POP
    }
    try large_bytecode.append(std.testing.allocator, 0x00); // STOP

    const large_address: primitives.Address = .{ .bytes = [_]u8{0} ** 19 ++ [_]u8{4} };
    const code_hash = try db.set_code(large_bytecode.items);
    try db.set_account(large_address.bytes, Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Test with different gas limits
    const gas_limits = [_]u64{ 10000, 50000, 100000, 500000 };

    for (gas_limits) |gas_limit| {
        const start_time = std.time.nanoTimestamp();
        const result = evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = large_address,
                .value = 0,
                .input = &.{},
                .gas = gas_limit,
            },
        });
        const elapsed = std.time.nanoTimestamp() - start_time;

        _ = gas_limit - result.gas_left; // gas_used
        evm.tracer.onPerformanceWarning("Large contract", elapsed, 1_000_000_000);

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test maximum gas limit
    const max_gas_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = std.math.maxInt(u64),
        },
    };

    const max_gas_result = evm.call(max_gas_params);
    try std.testing.expect(max_gas_result.gas_left <= std.math.maxInt(u64));

    // Test invalid address operations
    const invalid_address: primitives.Address = .{ .bytes = [_]u8{0xFF} ** 20 };
    const balance = try evm.get_balance(invalid_address);
    try std.testing.expectEqual(@as(u256, 0), balance);

    const exists = evm.account_exists(invalid_address);
    try std.testing.expect(!exists);

    // Test max u256 storage operations
    const max_key: u256 = std.math.maxInt(u256);
    const max_value: u256 = std.math.maxInt(u256);

    try evm.set_storage(primitives.ZERO_ADDRESS, max_key, max_value);
    const retrieved_max = try evm.get_storage(primitives.ZERO_ADDRESS, max_key);
    try std.testing.expectEqual(max_value, retrieved_max);
}

test "EVM with minimal planner strategy" {
    // Define EVM config with minimal planner strategy
    const MinimalEvmConfig = EvmConfig{};
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

    var evm = try MinimalEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
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

    const result = evm.call(call_params);
    try std.testing.expect(result.success);
}

test "EVM with advanced planner strategy" {
    // Define EVM config with advanced planner strategy
    const AdvancedEvmConfig = EvmConfig{};
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

    var evm = try AdvancedEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
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

    const result = evm.call(call_params);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const test_address = primitives.Address{ .bytes = [_]u8{0x12} ++ [_]u8{0} ** 19 };
    const storage_key: u256 = 0x123;
    const original_value: u256 = 0x456;
    const new_value: u256 = 0x789;

    // Set initial storage value
    try evm.database.set_storage(test_address.bytes, storage_key, original_value);

    // Create snapshot
    const snapshot_id = try evm.create_snapshot();

    // Modify storage value and record in journal
    try evm.database.set_storage(test_address.bytes, storage_key, new_value);
    try evm.journal.entries.append(evm.allocator, .{
        .snapshot_id = snapshot_id,
        .data = .{ .storage_change = .{
            .address = test_address,
            .key = storage_key,
            .original_value = original_value,
        } },
    });

    // Verify new value is set
    const current_value = try evm.database.get_storage(test_address.bytes, storage_key);
    try std.testing.expectEqual(new_value, current_value);

    // Revert to snapshot
    evm.revert_to_snapshot(snapshot_id);

    // Verify storage value was reverted
    const reverted_value = try evm.database.get_storage(test_address.bytes, storage_key);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const test_address = primitives.Address{ .bytes = [_]u8{0x34} ++ [_]u8{0} ** 19 };
    const original_balance: u256 = 1000;
    const new_balance: u256 = 2000;

    // Set initial account balance
    var original_account = Account.zero();
    original_account.balance = original_balance;
    try evm.database.set_account(test_address.bytes, original_account);

    // Create snapshot
    const snapshot_id = try evm.create_snapshot();

    // Modify balance and record in journal
    var modified_account = original_account;
    modified_account.balance = new_balance;
    try evm.database.set_account(test_address.bytes, modified_account);
    try evm.journal.entries.append(evm.allocator, .{
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
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
    try evm.journal.entries.append(evm.allocator, .{
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
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
    try evm.journal.record_code_change(snapshot_id, test_address, original_code_hash);

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const test_address: primitives.Address = .{ .bytes = [_]u8{0x9A} ++ [_]u8{0} ** 19 };
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
    try evm.database.set_storage(test_address.bytes, storage_key, original_storage);

    // Create snapshot
    const snapshot_id = evm.create_snapshot();

    // Make multiple changes and record in journal
    var modified_account = original_account;
    modified_account.balance = new_balance;
    modified_account.nonce = new_nonce;
    modified_account.code_hash = new_code_hash;
    try evm.database.set_account(test_address.bytes, modified_account);
    try evm.database.set_storage(test_address.bytes, storage_key, new_storage);

    // Add journal entries for all changes
    try evm.journal.record_balance_change(snapshot_id, test_address, original_balance);
    try evm.journal.record_nonce_change(snapshot_id, test_address, original_nonce);
    try evm.journal.record_code_change(snapshot_id, test_address, original_code_hash);
    try evm.journal.record_storage_change(snapshot_id, test_address, storage_key, original_storage);

    // Verify all new values are set
    const current_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(new_balance, current_account.balance);
    try std.testing.expectEqual(new_nonce, current_account.nonce);
    try std.testing.expectEqualSlices(u8, &new_code_hash, &current_account.code_hash);
    const current_storage = try evm.database.get_storage(test_address.bytes, storage_key);
    try std.testing.expectEqual(new_storage, current_storage);

    // Revert to snapshot
    evm.revert_to_snapshot(snapshot_id);

    // Verify all values were reverted
    const reverted_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(original_balance, reverted_account.balance);
    try std.testing.expectEqual(original_nonce, reverted_account.nonce);
    try std.testing.expectEqualSlices(u8, &original_code_hash, &reverted_account.code_hash);
    const reverted_storage = try evm.database.get_storage(test_address.bytes, storage_key);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const test_address: primitives.Address = .{ .bytes = [_]u8{0xBE} ++ [_]u8{0} ** 19 };
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
    try evm.journal.record_balance_change(snapshot1, test_address, original_balance);

    // Create second snapshot
    const snapshot2 = evm.create_snapshot();

    // Second change
    account.balance = final_balance;
    try evm.database.set_account(test_address.bytes, account);
    try evm.journal.record_balance_change(snapshot2, test_address, middle_balance);

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
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
    const deploy_address: primitives.Address = .{ .bytes = [_]u8{0} ** 19 ++ [_]u8{1} }; // Address 0x000...001

    // Store contract code in database
    const code_hash = try db.set_code(&test_bytecode);
    try db.set_account(deploy_address.bytes, Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = deploy_address,
            .value = 0,
            .input = &.{}, // No input data
            .gas = 100000,
        },
    };

    // Execute the contract - this should reproduce the benchmark scenario
    const result = evm.call(call_params);

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test calling IDENTITY precompile (0x04) - should return input as-is
    const precompile_address: primitives.Address = .{ .bytes = [_]u8{0} ** 19 ++ [_]u8{4} }; // Address 0x000...004
    const input_data = "Hello, World!";

    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = input_data,
            .gas = 100000,
        },
    };

    // Execute the precompile
    const result = evm.call(call_params);

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test calling SHA256 precompile (0x02)
    const precompile_address: primitives.Address = .{ .bytes = [_]u8{0} ** 19 ++ [_]u8{2} }; // Address 0x000...002
    const input_data = "abc";

    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = input_data,
            .gas = 100000,
        },
    };

    // Execute the precompile
    const result = evm.call(call_params);

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test ECRECOVER with invalid signature (all zeros)
    const precompile_address: primitives.Address = .{ .bytes = [_]u8{0} ** 19 ++ [_]u8{1} };
    const input_data = [_]u8{0} ** 128; // Invalid signature

    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = &input_data,
            .gas = 100000,
        },
    };

    const result = evm.call(call_params);

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const precompile_address: primitives.Address = .{ .bytes = [_]u8{0} ** 19 ++ [_]u8{3} };
    const input_data = "test data";

    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = input_data,
            .gas = 100000,
        },
    };

    const result = evm.call(call_params);

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const precompile_address: primitives.Address = .{ .bytes = [_]u8{0} ** 19 ++ [_]u8{5} };

    // 3^4 mod 5 = 81 mod 5 = 1
    var input: [99]u8 = [_]u8{0} ** 99;
    input[31] = 1; // base_len = 1
    input[63] = 1; // exp_len = 1
    input[95] = 1; // mod_len = 1
    input[96] = 3; // base = 3
    input[97] = 4; // exp = 4
    input[98] = 5; // mod = 5

    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = &input,
            .gas = 100000,
        },
    };

    const result = evm.call(call_params);

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test ECADD (0x06)
    const ecadd_address: primitives.Address = .{ .bytes = [_]u8{0} ** 19 ++ [_]u8{6} };
    const ecadd_input = [_]u8{0} ** 128; // Two zero points

    const ecadd_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = ecadd_address,
            .value = 0,
            .input = &ecadd_input,
            .gas = 100000,
        },
    };

    const ecadd_result = evm.call(ecadd_params);

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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const precompile_address: primitives.Address = .{ .bytes = [_]u8{0} ** 19 ++ [_]u8{9} };
    const input = [_]u8{0} ** 213; // Valid BLAKE2F input length

    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = &input,
            .gas = 100000,
        },
    };

    const result = evm.call(call_params);

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
    const deploy_address: primitives.Address = .{ .bytes = [_]u8{0} ** 19 ++ [_]u8{1} };
    const code_hash = try db.set_code(&stop_bytecode);
    try db.set_account(deploy_address.bytes, Account{
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

    var evm_instance = try Evm(.{}).init(allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm_instance.deinit();

    // Simple calldata
    const calldata = [_]u8{0x00};

    // Execute call (simulating benchmark)
    const call_params = Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = deploy_address,
            .value = 0,
            .input = &calldata,
            .gas = 100000,
        },
    };

    const result = evm_instance.call(call_params);
    try std.testing.expect(result.success);

    // The segfault happens in deinit, so let's explicitly test that
    // by creating and destroying multiple times
    for (0..3) |_| {
        var temp_evm = try Evm(.{}).init(allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
        const temp_result = temp_evm.call(call_params);
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
    var evm_instance = try Evm(.{}).init(
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
        .{ .bytes = [_]u8{0x01} ** 20 },
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

    var init_code = std.array_list.AlignedManaged(u8, null).init(allocator);
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
    const create_result = evm_instance.call(.{
        .create = .{
            .caller = .{ .bytes = [_]u8{0x01} ** 20 },
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
    @memcpy(&contract_address.bytes, create_result.output[0..20]);

    // Step 2: Call the deployed contract
    const call_result = evm_instance.call(.{
        .call = .{
            .caller = .{ .bytes = [_]u8{0x01} ** 20 },
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
        returned_value = std.math.shl(u256, returned_value, 8) | byte;
    }
    try std.testing.expectEqual(@as(u256, 42), returned_value);
}
test "CREATE interaction - factory creates and initializes child contracts" {
    const allocator = std.testing.allocator;

    var db = Database.init(allocator);
    defer db.deinit();

    // Database is now used directly
    var evm_instance = try Evm(.{}).init(
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
        .{ .bytes = [_]u8{0x01} ** 20 },
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
    var child_init = std.array_list.AlignedManaged(u8, null).init(allocator);
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
    var factory_code = std.array_list.AlignedManaged(u8, null).init(allocator);
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
    var deploy_data = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer deploy_data.deinit();
    const init_value = [_]u8{0} ** 31 ++ [_]u8{123}; // 123 as uint256
    try deploy_data.appendSlice(&init_value);

    const factory_result = evm_instance.call(.{
        .create = .{
            .caller = .{ .bytes = [_]u8{0x01} ** 20 },
            .value = 0,
            .init_code = deploy_data.items,
            .gas = 5_000_000,
        },
    });
    defer if (factory_result.output.len > 0) allocator.free(factory_result.output);

    try std.testing.expect(factory_result.success);

    // Extract child contract address from output
    var child_address: primitives.Address = undefined;
    @memcpy(&child_address.bytes, factory_result.output[0..20]); // Contract address

    // Call child contract to verify initialization
    const verify_result = evm_instance.call(.{
        .call = .{
            .caller = .{ .bytes = [_]u8{0x01} ** 20 },
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
        returned_value = std.math.shl(u256, returned_value, 8) | byte;
    }
    try std.testing.expectEqual(@as(u256, 123), returned_value);
}

test "CREATE interaction - contract creates contract that creates contract" {
    const allocator = std.testing.allocator;

    var db = Database.init(allocator);
    defer db.deinit();

    // Database is now used directly
    var evm_instance = try Evm(.{}).init(
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
        .{ .bytes = [_]u8{0x01} ** 20 },
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
    var level3_init = std.array_list.AlignedManaged(u8, null).init(allocator);
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
    var level2_runtime = std.array_list.AlignedManaged(u8, null).init(allocator);
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
    var level2_init = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer level2_init.deinit();
    for (level2_runtime.items, 0..) |byte, i| {
        try level2_init.append(0x60); // PUSH1
        try level2_init.append(@as(u8, @truncate(i)));
        try level2_init.append(0x60); // PUSH1
        try level2_init.append(byte);
        try level2_init.append(0x53); // MSTORE8
    }
    try level2_init.append(0x61); // PUSH2
    try level2_init.append(@as(u8, @truncate(std.math.shr(usize, level2_runtime.items.len, 8))));
    try level2_init.append(@as(u8, @truncate(level2_runtime.items.len & 0xFF)));
    try level2_init.append(0x60); // PUSH1
    try level2_init.append(0x00);
    try level2_init.append(0xF3); // RETURN

    // Level 1 contract (parent): creates level 2
    var level1_code = std.array_list.AlignedManaged(u8, null).init(allocator);
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
    try level1_code.append(@as(u8, @truncate(std.math.shr(usize, level2_init.items.len, 8))));
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
    const result1 = evm_instance.call(.{
        .create = .{
            .caller = .{ .bytes = [_]u8{0x01} ** 20 },
            .value = 0,
            .init_code = level1_code.items,
            .gas = 10_000_000,
        },
    });
    defer if (result1.output.len > 0) allocator.free(result1.output);

    try std.testing.expect(result1.success);

    // Get level 2 address from storage
    const level2_addr_u256 = try evm_instance.get_storage(.{ .bytes = [_]u8{0x01} ** 20 }, 0);
    var level2_addr: primitives.Address = undefined;
    const bytes = std.mem.toBytes(level2_addr_u256);
    @memcpy(&level2_addr.bytes, bytes[12..32]);

    // Call level 2 to get level 3 address
    const result2 = evm_instance.call(.{
        .call = .{
            .caller = .{ .bytes = [_]u8{0x01} ** 20 },
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
    @memcpy(&level3_addr.bytes, result2.output[0..20]);

    // Call level 3 to verify it returns 99
    const result3 = evm_instance.call(.{
        .call = .{
            .caller = .{ .bytes = [_]u8{0x01} ** 20 },
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
        returned_value = std.math.shl(u256, returned_value, 8) | byte;
    }
    try std.testing.expectEqual(@as(u256, 99), returned_value);
}

test "CREATE interaction - created contract modifies parent storage" {
    const allocator = std.testing.allocator;

    var db = Database.init(allocator);
    defer db.deinit();

    // Database is now used directly
    var evm_instance = try Evm(.{}).init(
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
        primitives.Address{ .bytes = [_]u8{0x01} ** 20 },
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
    var child_init = std.array_list.AlignedManaged(u8, null).init(allocator);
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
    var parent_code = std.array_list.AlignedManaged(u8, null).init(allocator);
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
    const deploy_result = evm_instance.call(.{
        .create = .{
            .caller = .{ .bytes = [_]u8{0x01} ** 20 },
            .value = 0,
            .init_code = parent_code.items,
            .gas = 5_000_000,
        },
    });
    defer if (deploy_result.output.len > 0) allocator.free(deploy_result.output);

    try std.testing.expect(deploy_result.success);

    // Get parent address (deterministic based on sender nonce)
    const parent_addr: primitives.Address = .{ .bytes = [_]u8{0x01} ** 20 }; // Simplified for test

    // Get child address from parent's storage
    const child_addr_u256 = try evm_instance.get_storage(parent_addr, 1);
    var child_addr: primitives.Address = undefined;
    const bytes = std.mem.toBytes(child_addr_u256);
    @memcpy(&child_addr.bytes, bytes[12..32]);

    // Verify parent's value storage is initially 0
    const initial_value = try evm_instance.get_storage(parent_addr, 0);
    try std.testing.expectEqual(@as(u256, 0), initial_value);

    // Call child contract, which should call back to parent
    const call_result = evm_instance.call(.{
        .call = .{
            .caller = .{ .bytes = [_]u8{0x02} ** 20 },
            .to = child_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1_000_000,
        },
    });
    defer if (call_result.output.len > 0) allocator.free(call_result.output);

    try std.testing.expect(call_result.success);

    // Verify parent's storage was modified by child
    const final_value = try evm_instance.get_storage(parent_addr, 0);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Simple contract that emits a log
    // PUSH1 0x20 PUSH1 0x00 LOG0 STOP
    const bytecode = [_]u8{ 0x60, 0x20, 0x60, 0x00, 0xA0, 0x00 };
    const contract_addr: primitives.Address = .{ .bytes = [_]u8{0x01} ** 20 };
    const code_hash = try db.set_code(&bytecode);
    try db.set_account(contract_addr.bytes, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Track arena bytes allocated before first call
    const initial_arena_bytes = evm.call_arena.queryCapacity();

    // First call - should allocate in arena
    const result1 = evm.call(.{
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
    const after_first_call = evm.call_arena.queryCapacity();
    try std.testing.expect(after_first_call >= initial_arena_bytes);

    // Second call - arena should be reset
    const result2 = evm.call(.{
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
    const after_second_call = evm.call_arena.queryCapacity();
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
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

    const contract_addr: primitives.Address = .{ .bytes = [_]u8{0x02} ** 20 };
    const code_hash = try db.set_code(&bytecode);
    try db.set_account(contract_addr.bytes, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Execute contract
    const result = evm.call(.{
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Call SHA256 precompile (address 0x02)
    const precompile_addr = primitives.Address.from_u256(2);
    const input = "Hello, World!";

    const result = evm.call(.{
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
    const result2 = evm.call(.{
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
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
    const parent_address: primitives.Address = .{ .bytes = parent_addr };
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
    const initial_capacity = evm.call_arena.queryCapacity();

    // Execute parent contract
    const result = evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = parent_address,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1000000,
        },
    });
    defer if (result.success and result.output.len > 0) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 2), result.logs.len); // Parent and child logs

    // Arena should have grown to accommodate logs
    const final_capacity = evm.call_arena.queryCapacity();
    try std.testing.expect(final_capacity >= initial_capacity);

    // Second call should reuse arena capacity
    const result2 = evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = parent_address,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1000000,
        },
    });
    defer if (result2.output.len > 0) std.testing.allocator.free(result2.output);

    try std.testing.expect(result2.success);
    try std.testing.expectEqual(@as(usize, 2), result2.logs.len);

    // Arena capacity should be retained
    const final_capacity2 = evm.call_arena.queryCapacity();
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
    var evm = try Evm(.{}).init(
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
        .is_static = false,
    };

    try std.testing.expectEqual(origin_addr, evm.get_caller());
    try std.testing.expectEqual(@as(u256, 123), evm.get_call_value());

    // Simulate depth 2 call from contract_a to contract_b with value 456
    evm.depth = 2;
    evm.call_stack[1] = .{
        .caller = contract_a,
        .value = 456,
        .is_static = false,
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

    var evm = try Evm(.{}).init(allocator, &db, block_info, tx_context, 20_000_000_000, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Give creator account some balance
    const creator_address: primitives.Address = .{ .bytes = [_]u8{0x11} ++ [_]u8{0} ** 19 };
    try db.set_account(creator_address.bytes, Account{
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
    var init_code = std.array_list.AlignedManaged(u8, null).init(allocator);
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
    var creator_bytecode = std.array_list.AlignedManaged(u8, null).init(allocator);
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
    try db.set_account(creator_address.bytes, Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = creator_code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Execute CREATE
    const result = evm.call(.{
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
    @memcpy(&created_address.bytes, result.output[0..20]);

    // Verify the deployed contract exists and has the correct code
    const deployed_code = try db.get_code_by_address(created_address.bytes);
    try std.testing.expectEqualSlices(u8, &deployed_runtime, deployed_code);

    // Call the deployed contract to verify it works
    const call_result = evm.call(.{
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
    for (call_result.output) |b| {
        returned_value = (returned_value << 8) | @as(u256, b);
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

    var evm = try Evm(.{}).init(allocator, &db, block_info, tx_context, 20_000_000_000, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Give creator account some balance
    const creator_address: primitives.Address = .{ .bytes = [_]u8{0x22} ++ [_]u8{0} ** 19 };
    try db.set_account(creator_address.bytes, Account{
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
    var init_code = std.array_list.AlignedManaged(u8, null).init(allocator);
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
    var creator_bytecode = std.array_list.AlignedManaged(u8, null).init(allocator);
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
    try db.set_account(creator_address.bytes, Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = creator_code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Execute CREATE2
    const result = evm.call(.{
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
    @memcpy(&created_address.bytes, result.output[0..20]);

    // Verify the deployed contract exists and has the correct code
    const deployed_code = try db.get_code_by_address(created_address.bytes);
    try std.testing.expectEqualSlices(u8, &deployed_runtime, deployed_code);

    // Call the deployed contract to verify it works
    const call_result = evm.call(.{
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
    for (call_result.output) |b| {
        returned_value = (returned_value << 8) | @as(u256, b);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test bytecode iterator execution with simple STOP
    const stop_bytecode = [_]u8{0x00}; // STOP opcode

    // Add contract with STOP bytecode
    const contract_address: primitives.Address = .{ .bytes = [_]u8{0x42} ++ [_]u8{0} ** 19 };
    const code_hash = try db.set_code(&stop_bytecode);
    try db.set_account(contract_address.bytes, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Call the contract using bytecode iterator execution
    const result = evm.call(Evm(.{}).CallParams{
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
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
    const contract_address: primitives.Address = .{ .bytes = [_]u8{0x43} ++ [_]u8{0} ** 19 };
    const code_hash = try db.set_code(&return_bytecode);
    try db.set_account(contract_address.bytes, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Call the contract
    const result = evm.call(Evm(.{}).CallParams{
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
    for (result.output) |b| {
        returned_value = (returned_value << 8) | @as(u256, b);
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
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
    const contract_address: primitives.Address = .{ .bytes = [_]u8{0x44} ++ [_]u8{0} ** 19 };
    const code_hash = try db.set_code(&jump_bytecode);
    try db.set_account(contract_address.bytes, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Call the contract
    const result = evm.call(Evm(.{}).CallParams{
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

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
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
    const create_params = call_params_module.CallParams(.{}){
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

test "frame checkpoint: logs emitted by a reverted call frame are discarded" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    const block_info = BlockInfo{ .number = 1, .timestamp = 1000, .difficulty = 0, .gas_limit = 30000000, .coinbase = primitives.ZERO_ADDRESS, .base_fee = 0, .prev_randao = [_]u8{0} ** 32 };
    const context = TransactionContext{ .gas_limit = 1000000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 };
    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const parent: primitives.Address = .{ .bytes = [_]u8{0x10} ** 20 };
    const reverter: primitives.Address = .{ .bytes = [_]u8{0x11} ** 20 };
    const logger: primitives.Address = .{ .bytes = [_]u8{0x12} ** 20 };
    const parent_ok: primitives.Address = .{ .bytes = [_]u8{0x13} ** 20 };

    // logger: LOG0(0, 0) STOP
    const logger_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xa0, 0x00 };
    // reverter: LOG0(0, 0); CALL(gas, logger, 0, 0, 0, 0, 0); POP; REVERT(0, 0)
    const reverter_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xa0 } ++
        [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x73 } ++ logger.bytes ++ [_]u8{ 0x5a, 0xf1, 0x50 } ++
        [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xfd };
    // parent: CALL(gas, reverter, 0, 0, 0, 0, 0); POP; LOG0(0, 0); STOP
    const parent_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x73 } ++ reverter.bytes ++ [_]u8{ 0x5a, 0xf1, 0x50 } ++
        [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xa0, 0x00 };
    // parent_ok: CALL(gas, logger, 0, 0, 0, 0, 0); POP; LOG0(0, 0); STOP
    const parent_ok_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x73 } ++ logger.bytes ++ [_]u8{ 0x5a, 0xf1, 0x50 } ++
        [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xa0, 0x00 };

    try db.set_account(logger.bytes, Account{ .balance = 0, .nonce = 0, .code_hash = try db.set_code(&logger_code), .storage_root = [_]u8{0} ** 32 });
    try db.set_account(reverter.bytes, Account{ .balance = 0, .nonce = 0, .code_hash = try db.set_code(&reverter_code), .storage_root = [_]u8{0} ** 32 });
    try db.set_account(parent.bytes, Account{ .balance = 0, .nonce = 0, .code_hash = try db.set_code(&parent_code), .storage_root = [_]u8{0} ** 32 });
    try db.set_account(parent_ok.bytes, Account{ .balance = 0, .nonce = 0, .code_hash = try db.set_code(&parent_ok_code), .storage_root = [_]u8{0} ** 32 });

    var reverted = evm.call(.{ .call = .{ .caller = primitives.ZERO_ADDRESS, .to = parent, .value = 0, .input = &.{}, .gas = 500000 } });
    defer reverted.deinit(std.testing.allocator);
    try std.testing.expect(reverted.success);
    // The reverter's own log and its successful grandchild's log both disappear.
    try std.testing.expectEqual(@as(usize, 1), reverted.logs.len);
    try std.testing.expectEqual(parent, reverted.logs[0].address);

    var kept = evm.call(.{ .call = .{ .caller = primitives.ZERO_ADDRESS, .to = parent_ok, .value = 0, .input = &.{}, .gas = 500000 } });
    defer kept.deinit(std.testing.allocator);
    try std.testing.expect(kept.success);
    try std.testing.expectEqual(@as(usize, 2), kept.logs.len);
    try std.testing.expectEqual(logger, kept.logs[0].address);
    try std.testing.expectEqual(parent_ok, kept.logs[1].address);
}

test "frame checkpoint: addresses and slots first warmed by a reverted call frame become cold" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    const block_info = BlockInfo{ .number = 1, .timestamp = 1000, .difficulty = 0, .gas_limit = 30000000, .coinbase = primitives.ZERO_ADDRESS, .base_fee = 0, .prev_randao = [_]u8{0} ** 32 };
    const context = TransactionContext{ .gas_limit = 1000000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 };
    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const parent: primitives.Address = .{ .bytes = [_]u8{0x20} ** 20 };
    const child: primitives.Address = .{ .bytes = [_]u8{0x21} ** 20 };
    const parent_ok: primitives.Address = .{ .bytes = [_]u8{0x22} ** 20 };
    const child_ok: primitives.Address = .{ .bytes = [_]u8{0x23} ** 20 };
    const probed: primitives.Address = .{ .bytes = [_]u8{0x2F} ** 20 };

    // child: SLOAD(0x77); POP; BALANCE(probed); POP; REVERT(0, 0)
    const child_code = [_]u8{ 0x60, 0x77, 0x54, 0x50, 0x73 } ++ probed.bytes ++ [_]u8{ 0x31, 0x50, 0x60, 0x00, 0x60, 0x00, 0xfd };
    // child_ok: SLOAD(0x77); POP; BALANCE(probed); POP; STOP
    const child_ok_code = [_]u8{ 0x60, 0x77, 0x54, 0x50, 0x73 } ++ probed.bytes ++ [_]u8{ 0x31, 0x50, 0x00 };
    // parent / parent_ok: CALL(gas, child, 0, 0, 0, 0, 0); POP; STOP
    const parent_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x73 } ++ child.bytes ++ [_]u8{ 0x5a, 0xf1, 0x50, 0x00 };
    const parent_ok_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x73 } ++ child_ok.bytes ++ [_]u8{ 0x5a, 0xf1, 0x50, 0x00 };

    try db.set_account(child.bytes, Account{ .balance = 0, .nonce = 0, .code_hash = try db.set_code(&child_code), .storage_root = [_]u8{0} ** 32 });
    try db.set_account(child_ok.bytes, Account{ .balance = 0, .nonce = 0, .code_hash = try db.set_code(&child_ok_code), .storage_root = [_]u8{0} ** 32 });
    try db.set_account(parent.bytes, Account{ .balance = 0, .nonce = 0, .code_hash = try db.set_code(&parent_code), .storage_root = [_]u8{0} ** 32 });
    try db.set_account(parent_ok.bytes, Account{ .balance = 0, .nonce = 0, .code_hash = try db.set_code(&parent_ok_code), .storage_root = [_]u8{0} ** 32 });

    var reverted = evm.call(.{ .call = .{ .caller = primitives.ZERO_ADDRESS, .to = parent, .value = 0, .input = &.{}, .gas = 500000 } });
    defer reverted.deinit(std.testing.allocator);
    try std.testing.expect(reverted.success);
    var child_warm = false;
    for (reverted.accessed_addresses) |addr| {
        try std.testing.expect(!addr.equals(probed));
        if (addr.equals(child)) child_warm = true;
    }
    // The parent's CALL warmed the child before the child frame began, so it stays warm.
    try std.testing.expect(child_warm);
    for (reverted.accessed_storage) |access| {
        try std.testing.expect(!(access.address.equals(child) and access.slot == 0x77));
    }

    var kept = evm.call(.{ .call = .{ .caller = primitives.ZERO_ADDRESS, .to = parent_ok, .value = 0, .input = &.{}, .gas = 500000 } });
    defer kept.deinit(std.testing.allocator);
    try std.testing.expect(kept.success);
    var probed_warm = false;
    for (kept.accessed_addresses) |addr| {
        if (addr.equals(probed)) probed_warm = true;
    }
    try std.testing.expect(probed_warm);
    var slot_warm = false;
    for (kept.accessed_storage) |access| {
        if (access.address.equals(child_ok) and access.slot == 0x77) slot_warm = true;
    }
    try std.testing.expect(slot_warm);
}

test "frame checkpoint: gas refunds earned in a reverted call frame are discarded" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    const block_info = BlockInfo{ .number = 1, .timestamp = 1000, .difficulty = 0, .gas_limit = 30000000, .coinbase = primitives.ZERO_ADDRESS, .base_fee = 0, .prev_randao = [_]u8{0} ** 32 };
    const context = TransactionContext{ .gas_limit = 1000000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 };
    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const clearer: primitives.Address = .{ .bytes = [_]u8{0x30} ** 20 };
    const clearer_ok: primitives.Address = .{ .bytes = [_]u8{0x31} ** 20 };
    // clearer: SSTORE(0, 0) on a nonzero slot earns a refund; then REVERT(0, 0)
    const clearer_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x55, 0x60, 0x00, 0x60, 0x00, 0xfd };
    // clearer_ok: SSTORE(0, 0); STOP
    const clearer_ok_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x55, 0x00 };
    try db.set_account(clearer.bytes, Account{ .balance = 0, .nonce = 0, .code_hash = try db.set_code(&clearer_code), .storage_root = [_]u8{0} ** 32 });
    try db.set_account(clearer_ok.bytes, Account{ .balance = 0, .nonce = 0, .code_hash = try db.set_code(&clearer_ok_code), .storage_root = [_]u8{0} ** 32 });
    try db.set_storage(clearer.bytes, 0, 1);
    try db.set_storage(clearer_ok.bytes, 0, 1);

    // A refund earned before the frame began must survive the frame's revert.
    evm.gas_refund_counter = 1234;
    const reverted = evm.inner_call(.{ .call = .{ .caller = primitives.ZERO_ADDRESS, .to = clearer, .value = 0, .input = &.{}, .gas = 100000 } });
    try std.testing.expect(!reverted.success);
    try std.testing.expectEqual(@as(u64, 1234), evm.gas_refund_counter);

    const kept = evm.inner_call(.{ .call = .{ .caller = primitives.ZERO_ADDRESS, .to = clearer_ok, .value = 0, .input = &.{}, .gas = 100000 } });
    try std.testing.expect(kept.success);
    try std.testing.expect(evm.gas_refund_counter > 1234);
}

test "frame checkpoint: SELFDESTRUCT marks made under a reverted frame are removed" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    const block_info = BlockInfo{ .number = 1, .timestamp = 1000, .difficulty = 0, .gas_limit = 30000000, .coinbase = primitives.ZERO_ADDRESS, .base_fee = 0, .prev_randao = [_]u8{0} ** 32 };
    const context = TransactionContext{ .gas_limit = 1000000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 };
    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const parent: primitives.Address = .{ .bytes = [_]u8{0x40} ** 20 };
    const parent_ok: primitives.Address = .{ .bytes = [_]u8{0x41} ** 20 };
    const doomed: primitives.Address = .{ .bytes = [_]u8{0x42} ** 20 };
    const beneficiary: primitives.Address = .{ .bytes = [_]u8{0x4F} ** 20 };
    const earlier: primitives.Address = .{ .bytes = [_]u8{0x4E} ** 20 };

    // doomed: SELFDESTRUCT(beneficiary)
    const doomed_code = [_]u8{0x73} ++ beneficiary.bytes ++ [_]u8{0xff};
    // parent: CALL(gas, doomed, 0, 0, 0, 0, 0); POP; REVERT(0, 0)
    const parent_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x73 } ++ doomed.bytes ++ [_]u8{ 0x5a, 0xf1, 0x50, 0x60, 0x00, 0x60, 0x00, 0xfd };
    // parent_ok: CALL(gas, doomed, 0, 0, 0, 0, 0); POP; STOP
    const parent_ok_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x73 } ++ doomed.bytes ++ [_]u8{ 0x5a, 0xf1, 0x50, 0x00 };
    try db.set_account(doomed.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&doomed_code), .storage_root = [_]u8{0} ** 32 });
    try db.set_account(parent.bytes, Account{ .balance = 0, .nonce = 0, .code_hash = try db.set_code(&parent_code), .storage_root = [_]u8{0} ** 32 });
    try db.set_account(parent_ok.bytes, Account{ .balance = 0, .nonce = 0, .code_hash = try db.set_code(&parent_ok_code), .storage_root = [_]u8{0} ** 32 });

    // EIP-6780: only a contract created in this transaction is marked for deletion.
    try evm.register_created_contract(doomed);
    try evm.self_destruct.mark_for_destruction(earlier, beneficiary);

    const reverted = evm.inner_call(.{ .call = .{ .caller = primitives.ZERO_ADDRESS, .to = parent, .value = 0, .input = &.{}, .gas = 200000 } });
    try std.testing.expect(!reverted.success);
    try std.testing.expect(!evm.self_destruct.is_marked_for_destruction(doomed));
    try std.testing.expect(evm.self_destruct.is_marked_for_destruction(earlier));
    try std.testing.expectEqual(@as(u32, 1), evm.self_destruct.count());

    const kept = evm.inner_call(.{ .call = .{ .caller = primitives.ZERO_ADDRESS, .to = parent_ok, .value = 0, .input = &.{}, .gas = 200000 } });
    try std.testing.expect(kept.success);
    try std.testing.expect(evm.self_destruct.is_marked_for_destruction(doomed));
}

test "frame checkpoint: CREATE under a reverted frame is forgotten and a failed CREATE address stays warm" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    const block_info = BlockInfo{ .number = 1, .timestamp = 1000, .difficulty = 0, .gas_limit = 30000000, .coinbase = primitives.ZERO_ADDRESS, .base_fee = 0, .prev_randao = [_]u8{0} ** 32 };
    const context = TransactionContext{ .gas_limit = 1000000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 };
    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const creator_reverts: primitives.Address = .{ .bytes = [_]u8{0x50} ** 20 };
    const creator_child_fails: primitives.Address = .{ .bytes = [_]u8{0x51} ** 20 };
    const creator_ok: primitives.Address = .{ .bytes = [_]u8{0x52} ** 20 };

    // CREATE(0, 0, 1) runs the one-byte init code 0x00 (STOP) from zeroed memory; POP; REVERT(0, 0)
    const reverts_code = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x60, 0x00, 0xf0, 0x50, 0x60, 0x00, 0x60, 0x00, 0xfd };
    // MSTORE(0, 0x60006000fd); CREATE(0, 27, 5) runs init code REVERT(0, 0); POP; STOP
    const child_fails_code = [_]u8{ 0x64, 0x60, 0x00, 0x60, 0x00, 0xfd, 0x60, 0x00, 0x52, 0x60, 0x05, 0x60, 0x1b, 0x60, 0x00, 0xf0, 0x50, 0x00 };
    // CREATE(0, 0, 1); POP; STOP
    const ok_code = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x60, 0x00, 0xf0, 0x50, 0x00 };
    try db.set_account(creator_reverts.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&reverts_code), .storage_root = [_]u8{0} ** 32 });
    try db.set_account(creator_child_fails.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&child_fails_code), .storage_root = [_]u8{0} ** 32 });
    try db.set_account(creator_ok.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&ok_code), .storage_root = [_]u8{0} ** 32 });

    const reverts_child = try primitives.Address.getContractAddress(std.testing.allocator, creator_reverts, 1);
    const failed_child = try primitives.Address.getContractAddress(std.testing.allocator, creator_child_fails, 1);
    const ok_child = try primitives.Address.getContractAddress(std.testing.allocator, creator_ok, 1);

    const reverted = evm.inner_call(.{ .call = .{ .caller = primitives.ZERO_ADDRESS, .to = creator_reverts, .value = 0, .input = &.{}, .gas = 300000 } });
    try std.testing.expect(!reverted.success);
    try std.testing.expect(!evm.created_contracts.was_created_in_tx(reverts_child));
    try std.testing.expect(!evm.access_list.is_address_warm(reverts_child));

    // execution-specs generic_create warms the new address in the creating frame, before
    // the child runs, so the child's failure does not cool it.
    const child_failed = evm.inner_call(.{ .call = .{ .caller = primitives.ZERO_ADDRESS, .to = creator_child_fails, .value = 0, .input = &.{}, .gas = 300000 } });
    try std.testing.expect(child_failed.success);
    try std.testing.expect(!evm.created_contracts.was_created_in_tx(failed_child));
    try std.testing.expect(evm.access_list.is_address_warm(failed_child));

    const kept = evm.inner_call(.{ .call = .{ .caller = primitives.ZERO_ADDRESS, .to = creator_ok, .value = 0, .input = &.{}, .gas = 300000 } });
    try std.testing.expect(kept.success);
    try std.testing.expect(evm.created_contracts.was_created_in_tx(ok_child));
}

test "frame checkpoint: a failed precompile call returns its value transfer" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    const block_info = BlockInfo{ .number = 1, .timestamp = 1000, .difficulty = 0, .gas_limit = 30000000, .coinbase = primitives.ZERO_ADDRESS, .base_fee = 0, .prev_randao = [_]u8{0} ** 32 };
    const context = TransactionContext{ .gas_limit = 1000000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 };
    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const sender: primitives.Address = .{ .bytes = [_]u8{0x60} ** 20 };
    const pairing = primitives.Address.fromU256(0x08);
    try db.set_account(sender.bytes, Account{ .balance = 10, .nonce = 0, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 });

    // A BN254 pairing input that is not a multiple of 192 bytes is an exceptional halt.
    const malformed = [_]u8{0x01};
    const result = evm.inner_call(.{ .call = .{ .caller = sender, .to = pairing, .value = 5, .input = &malformed, .gas = 100000 } });
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u256, 10), try db.get_balance(sender.bytes));
    try std.testing.expectEqual(@as(u256, 0), try db.get_balance(pairing.bytes));
}

test "BLOCKHASH ring: returns host hashes only inside the 256-block window" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    const block_info = BlockInfo{ .number = 300, .timestamp = 1000, .difficulty = 0, .gas_limit = 30000000, .coinbase = primitives.ZERO_ADDRESS, .base_fee = 0, .prev_randao = [_]u8{0} ** 32 };
    const context = TransactionContext{ .gas_limit = 1000000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 };
    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const reader: primitives.Address = .{ .bytes = [_]u8{0x70} ** 20 };
    // BLOCKHASH(CALLDATALOAD(0)) returned as 32 bytes
    const reader_code = [_]u8{ 0x60, 0x00, 0x35, 0x40, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    try db.set_account(reader.bytes, Account{ .balance = 0, .nonce = 0, .code_hash = try db.set_code(&reader_code), .storage_root = [_]u8{0} ** 32 });

    const hash_299 = [_]u8{0x99} ** 32;
    const hash_44 = [_]u8{0x44} ** 32;
    evm.setBlockHash(299, hash_299);
    evm.setBlockHash(44, hash_44);
    const zero = [_]u8{0} ** 32;

    const cases = [_]struct { number: u256, expected: [32]u8 }{
        .{ .number = 299, .expected = hash_299 }, // newest complete block
        .{ .number = 44, .expected = hash_44 }, // current - 256, oldest in window
        .{ .number = 250, .expected = zero }, // in window, unknown: never fabricated
        .{ .number = 300, .expected = zero }, // current block
        .{ .number = 301, .expected = zero }, // future block
        .{ .number = (@as(u256, 1) << 64) + 299, .expected = zero }, // must not alias block 299
        .{ .number = std.math.maxInt(u256), .expected = zero },
    };
    for (cases) |case| {
        var input: [32]u8 = undefined;
        std.mem.writeInt(u256, &input, case.number, .big);
        var result = evm.call(.{ .call = .{ .caller = primitives.ZERO_ADDRESS, .to = reader, .value = 0, .input = &input, .gas = 100000 } });
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.success);
        try std.testing.expectEqualSlices(u8, &case.expected, result.output);
    }

    // Block 43 is outside the window even when the host knows its hash. It shares ring
    // slot 43 with block 299, so storing it also evicts 299.
    evm.setBlockHash(43, [_]u8{0x43} ** 32);
    for ([_]u256{ 43, 299 }) |number| {
        var input: [32]u8 = undefined;
        std.mem.writeInt(u256, &input, number, .big);
        var result = evm.call(.{ .call = .{ .caller = primitives.ZERO_ADDRESS, .to = reader, .value = 0, .input = &input, .gas = 100000 } });
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.success);
        try std.testing.expectEqualSlices(u8, &zero, result.output);
    }
}

test "BLOCKHASH ring: block 0 is readable while the current block is at most 256" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    const context = TransactionContext{ .gas_limit = 1000000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 };
    const reader: primitives.Address = .{ .bytes = [_]u8{0x71} ** 20 };
    const reader_code = [_]u8{ 0x60, 0x00, 0x35, 0x40, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    try db.set_account(reader.bytes, Account{ .balance = 0, .nonce = 0, .code_hash = try db.set_code(&reader_code), .storage_root = [_]u8{0} ** 32 });
    const genesis_hash = [_]u8{0xD4} ** 32;
    const zero_input = [_]u8{0} ** 32;

    const cases = [_]struct { current: u64, expected: [32]u8 }{
        .{ .current = 1, .expected = genesis_hash },
        .{ .current = 256, .expected = genesis_hash },
        .{ .current = 257, .expected = [_]u8{0} ** 32 },
    };
    for (cases) |case| {
        const block_info = BlockInfo{ .number = case.current, .timestamp = 1000, .difficulty = 0, .gas_limit = 30000000, .coinbase = primitives.ZERO_ADDRESS, .base_fee = 0, .prev_randao = [_]u8{0} ** 32 };
        var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
        defer evm.deinit();
        evm.setBlockHash(0, genesis_hash);
        var result = evm.call(.{ .call = .{ .caller = primitives.ZERO_ADDRESS, .to = reader, .value = 0, .input = &zero_input, .gas = 100000 } });
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.success);
        try std.testing.expectEqualSlices(u8, &case.expected, result.output);
    }
}

test "BLOCKHASH ring: BLOCKHASH and COINBASE charge their static gas exactly once" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    const block_info = BlockInfo{ .number = 300, .timestamp = 1000, .difficulty = 0, .gas_limit = 30000000, .coinbase = primitives.ZERO_ADDRESS, .base_fee = 0, .prev_randao = [_]u8{0} ** 32 };
    const context = TransactionContext{ .gas_limit = 1000000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 };
    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const blockhash_user: primitives.Address = .{ .bytes = [_]u8{0x72} ** 20 };
    const coinbase_user: primitives.Address = .{ .bytes = [_]u8{0x73} ** 20 };
    // PUSH1 0 (3) BLOCKHASH (20) POP (2) STOP (0)
    const blockhash_code = [_]u8{ 0x60, 0x00, 0x40, 0x50, 0x00 };
    // COINBASE (2) POP (2) STOP (0)
    const coinbase_code = [_]u8{ 0x41, 0x50, 0x00 };
    try db.set_account(blockhash_user.bytes, Account{ .balance = 0, .nonce = 0, .code_hash = try db.set_code(&blockhash_code), .storage_root = [_]u8{0} ** 32 });
    try db.set_account(coinbase_user.bytes, Account{ .balance = 0, .nonce = 0, .code_hash = try db.set_code(&coinbase_code), .storage_root = [_]u8{0} ** 32 });

    var blockhash_result = evm.call(.{ .call = .{ .caller = primitives.ZERO_ADDRESS, .to = blockhash_user, .value = 0, .input = &.{}, .gas = 100000 } });
    defer blockhash_result.deinit(std.testing.allocator);
    try std.testing.expect(blockhash_result.success);
    try std.testing.expectEqual(@as(u64, 100000 - (21000 + 3 + 20 + 2)), blockhash_result.gas_left);

    var coinbase_result = evm.call(.{ .call = .{ .caller = primitives.ZERO_ADDRESS, .to = coinbase_user, .value = 0, .input = &.{}, .gas = 100000 } });
    defer coinbase_result.deinit(std.testing.allocator);
    try std.testing.expect(coinbase_result.success);
    try std.testing.expectEqual(@as(u64, 100000 - (21000 + 2 + 2)), coinbase_result.gas_left);
}
