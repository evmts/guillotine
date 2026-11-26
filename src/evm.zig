const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const primitives = @import("voltaire");
const eips = @import("eips_and_hardforks/eips.zig");
const block_info_mod = @import("block/block_info.zig");
const BlockInfo = block_info_mod.BlockInfo(.{});
const Database = @import("storage/database.zig").Database;
const Account = @import("storage/database_interface_account.zig").Account;
const SelfDestruct = @import("storage/self_destruct.zig").SelfDestruct;
const CreatedContracts = @import("storage/created_contracts.zig").CreatedContracts;
const AccessList = @import("storage/access_list.zig").AccessList;
const Hardfork = @import("eips_and_hardforks/eips.zig").Hardfork;
const precompiles = @import("precompiles");
const kzg_setup = @import("crypto").kzg_setup;
const EvmConfig = @import("evm_config.zig").EvmConfig;
const TransactionContext = @import("block/transaction_context.zig").TransactionContext;
const GrowingArenaAllocator = @import("evm_arena_allocator.zig").GrowingArenaAllocator;
const native_stack = @import("native_stack.zig");
const call_result_module = @import("frame/call_result.zig");
const call_params_module = @import("frame/call_params.zig");

/// Creates a configured EVM instance type.
pub fn Evm(config: EvmConfig) type {
    return struct {
        const Self = @This();

        comptime {
            if (config.max_call_depth >= std.math.maxInt(u11)) {
                @compileError("max_call_depth must be below 2047 so that depth (max_call_depth + 1 active frames) fits u11");
            }
        }

        pub const tracing_enabled = config.tracer_config.enabled;

        /// Pool of frame memory buffers. See `memory/frame_memory_pool.zig`.
        pub const FrameMemory = @import("memory/frame_memory_pool.zig").FrameMemoryPool(config.memory_limit);

        pub const Frame = @import("frame/frame.zig").Frame(config.frame_config(), Self);
        pub const Bytecode = @import("bytecode/bytecode.zig").Bytecode(.{
            .max_bytecode_size = config.max_bytecode_size,
            .max_initcode_size = config.max_initcode_size,
            .fusions_enabled = config.enable_fusion,
            .hardfork = config.eips.hardfork,
        });

        pub const CallResult = call_result_module.CallResult(config);
        pub const CallParams = call_params_module.CallParams(config);

        pub const Journal: type = @import("storage/journal.zig").Journal(.{
            // One ID per call frame, never reused within a transaction. A 64-bit ID
            // cannot be exhausted: at one frame per nanosecond it lasts centuries.
            .SnapshotIdType = u64,
            .WordType = config.WordType,
            .NonceType = u64,
            .initial_capacity = 128,
        });
        /// Set of storage slots, in first-touch order.
        const TouchedSlots = std.array_hash_map.Auto(u256, void);
        const CallStackEntry = struct {
            caller: primitives.Address,
            value: config.WordType,
            is_static: bool, // EIP-214: Track static context per call level
        };

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
        /// Number of active frames, 0..max_call_depth + 1.
        depth: u11, // Supports up to 2047 active frames, more than the EVM's 1025

        /// Call stack - tracks caller and value for each call depth
        /// One entry per active frame. Frames run at 0-based depths 0..max_call_depth
        /// inclusive (execution-specs STACK_DEPTH_LIMIT), hence the extra slot.
        call_stack: [config.max_call_depth + 1]CallStackEntry,
        /// Current return data from last call (null if no return data available)
        return_data: ?[]const u8, // 24 bytes (optional adds 8 bytes for tag)
        /// Allocator for dynamic memory
        allocator: std.mem.Allocator, // 16 bytes (vtable ptr + context ptr)

        // Cache line 2 - STORAGE OPERATIONS: All accessed together for SLOAD/SSTORE
        /// Database interface for state storage
        database: *Database, // 8 bytes
        /// Access list for tracking warm/cold access (EIP-2929)
        access_list: AccessList, // ~40 bytes (2 hashmaps)
        /// Current snapshot ID for the active call frame
        current_snapshot_id: Journal.SnapshotIdType, // 8 bytes
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
        /// Reusable backing buffers for frame memory, one per active call depth.
        frame_memory: FrameMemory,
        /// Reusable frame stacks, one per active call depth. See `FrameStackPool`.
        frame_stacks: FrameStackPool,
        /// Set when the host, not the transaction, failed during the current call:
        /// an allocation, the database, a thread or a missing KZG trusted setup. The
        /// first failure is kept. Every call still running then fails, and `call`
        /// undoes the whole transaction and returns a failed result whose
        /// `error_info` starts with "host failure". The result is not a transaction
        /// outcome: the host must not include the transaction on the strength of it.
        /// The field keeps its value until the next `call` starts.
        host_failure: ?anyerror = null,
        /// While a call runs on the caller's stack: the address below which a nested
        /// call must move to a large stack. Zero when no check applies.
        native_stack_limit: usize = 0,
        /// Thread with a large native stack for call chains too deep for the caller's
        /// stack. Created on first use and kept until `deinit`, so a deep call does not
        /// pay for a thread spawn every time.
        large_stack_worker: ?*native_stack.Worker = null,
        /// Analyzed deployed code by code hash. See `DispatchCache`.
        dispatch_cache: DispatchCache,
        /// Contracts marked for self-destruction (cold - only used in old hardforks)
        self_destruct: SelfDestruct,

        // State dump tracking. The sets accumulate over every call made on this
        // EVM, so `dumpState` reports all the state the instance has touched. They
        // grow until the host calls `resetTouched`.
        /// Tracks all addresses that have been touched (for state dump)
        touched_addresses: std.AutoHashMap(primitives.Address, void),
        /// Tracks storage slots that have been modified (address -> list of storage keys)
        touched_storage: std.AutoHashMap(primitives.Address, TouchedSlots),
        /// Addresses that calls, not the host, added to `touched_addresses`.
        /// `resetTouched` removes exactly these.
        transaction_touched: std.ArrayList(primitives.Address) = .empty,

        // Tracer - at the very bottom of memory layout for minimal impact on cache performance
        /// Tracer for debugging and logging - can be accessed via evm.tracer or frame.evm_ptr.tracer
        tracer: @import("tracer/tracer.zig").Tracer,

        /// Initialize a new EVM instance.
        ///
        /// Sets up the execution environment with state storage, block context,
        /// and transaction parameters. The planner cache is initialized with
        /// a default size for bytecode optimization.
        /// If `gas_price` is null, the effective EIP-1559 gas price is derived
        /// from the block base fee and transaction fee caps. Returns
        /// error.GasPriceRequired when neither a gas price nor a fee cap exists.
        ///
        /// From Cancun on, with precompiles enabled, `init` loads the process-wide KZG
        /// trusted setup that the point evaluation precompile (0x0A) needs. The load
        /// runs once per process and is thread-safe; a failure is returned.
        pub fn init(allocator: std.mem.Allocator, database: ?*Database, block_info: BlockInfo, context: TransactionContext, gas_price: ?u256, origin: primitives.Address) !Self {
            const db = database orelse return error.DatabaseRequired;
            if (comptime kzg_required) try kzg_setup.init();
            const effective_gas_price = gas_price orelse config.eips.effective_gas_price(
                block_info.base_fee,
                context.max_fee_per_gas orelse return error.GasPriceRequired,
                context.max_priority_fee_per_gas,
            ).effective_gas_price;

            var access_list = AccessList.init(allocator);
            errdefer access_list.deinit();

            // The arena starts small and grows on demand up to the configured limit.
            // Reserving the whole limit here would cost every EVM instance 64 MiB.
            const initial_arena_capacity = @min(initial_call_arena_capacity, config.arena_capacity_limit);
            var arena = try GrowingArenaAllocator.initWithMaxCapacity(
                allocator,
                initial_arena_capacity,
                config.arena_capacity_limit,
                config.arena_growth_factor,
            );
            errdefer arena.deinit();

            var journal = try Journal.init(allocator);
            errdefer journal.deinit();

            var self = Self{
                .depth = 0,
                .call_stack = @as([config.max_call_depth + 1]CallStackEntry, @splat(CallStackEntry{ .caller = primitives.Address.ZERO_ADDRESS, .value = 0, .is_static = false })),
                .return_data = null,
                .allocator = allocator,
                .database = db,
                .access_list = access_list,
                .current_snapshot_id = 0,
                .tx_sender_nonce_incremented = false,
                .gas_refund_counter = 0,
                .journal = journal,
                .logs = std.ArrayList(@import("frame/call_result.zig").Log).empty,
                .created_contracts = CreatedContracts.init(allocator),
                .block_info = block_info,
                .context = context,
                .gas_price = effective_gas_price,
                .origin = origin,
                .call_arena = arena,
                .frame_memory = FrameMemory.init(allocator),
                .frame_stacks = FrameStackPool.init(allocator),
                .self_destruct = SelfDestruct.init(allocator),
                .dispatch_cache = DispatchCache.init(allocator),
                .touched_addresses = std.AutoHashMap(primitives.Address, void).init(allocator),
                .touched_storage = std.AutoHashMap(primitives.Address, TouchedSlots).init(allocator),
                .tracer = @import("tracer/tracer.zig").Tracer.init(allocator, config.tracer_config),
            };

            // `self` moves when it is returned, so the arena's tracer pointer is set at
            // the start of each call (`callImpl`), when the address is final.
            self.tracer.onArenaInit(initial_arena_capacity, config.arena_capacity_limit, config.arena_growth_factor);
            self.tracer.onEvmInit(effective_gas_price, origin, @tagName(config.eips.hardfork));
            return self;
        }

        /// Arena capacity reserved by `init`. Calls that need more grow the arena, and
        /// the grown capacity is kept for later calls.
        const initial_call_arena_capacity = 64 * 1024;

        /// True when this EVM has the point evaluation precompile (EIP-4844) and the
        /// target can load its trusted setup. The KZG library is not built for
        /// wasm32; there a call to 0x0A is reported as a host failure.
        const kzg_required = config.enable_precompiles and
            config.eips.hardfork.isAtLeast(.CANCUN) and
            builtin.target.cpu.arch != .wasm32;

        /// Frame stacks that outlive their frames.
        ///
        /// A frame's stack is 32 KiB. Allocated from the call arena it could not be
        /// freed when the frame ended, because the frame's result is allocated after
        /// it, so every returning call kept 32 KiB until the transaction ended:
        /// gigabytes for a transaction that makes a hundred thousand calls. The pool
        /// hands the same buffers to one frame after another instead. Frames end in
        /// the reverse order they start, so `stacks[0..in_use]` are the live ones.
        const FrameStackPool = struct {
            const Buffer = []align(alignment.toByteUnits()) u8;
            const size = @as(usize, Frame.Stack.stack_capacity) * @sizeOf(Frame.WordType);
            const alignment: std.mem.Alignment = .@"64";
            /// Free stacks kept after a transaction (512 KiB). A deeper call chain
            /// frees the rest when its transaction ends.
            const max_retained = 16;

            allocator: std.mem.Allocator,
            stacks: std.ArrayList(Buffer) = .empty,
            in_use: usize = 0,

            fn init(allocator: std.mem.Allocator) FrameStackPool {
                return .{ .allocator = allocator };
            }

            fn deinit(self: *FrameStackPool) void {
                for (self.stacks.items) |buffer| self.allocator.free(buffer);
                self.stacks.deinit(self.allocator);
                self.in_use = 0;
            }

            /// True for the one allocation shape the pool serves: a frame stack.
            fn serves(len: usize, requested: std.mem.Alignment) bool {
                return len == size and requested == alignment;
            }

            fn acquire(self: *FrameStackPool) ?[*]u8 {
                if (self.in_use == self.stacks.items.len) {
                    self.stacks.ensureUnusedCapacity(self.allocator, 1) catch return null;
                    const buffer = self.allocator.alignedAlloc(u8, alignment, size) catch return null;
                    self.stacks.appendAssumeCapacity(buffer);
                }
                const buffer = self.stacks.items[self.in_use];
                self.in_use += 1;
                return buffer.ptr;
            }

            /// Return a stack to the pool. False when `pointer` is not a live stack
            /// of this pool.
            fn release(self: *FrameStackPool, pointer: [*]u8) bool {
                var index = self.in_use;
                while (index > 0) {
                    index -= 1;
                    if (self.stacks.items[index].ptr != pointer) continue;
                    self.in_use -= 1;
                    std.mem.swap(Buffer, &self.stacks.items[index], &self.stacks.items[self.in_use]);
                    return true;
                }
                return false;
            }

            /// Free the stacks beyond `max_retained` that no frame uses.
            fn trim(self: *FrameStackPool) void {
                while (self.stacks.items.len > @max(self.in_use, max_retained)) {
                    const buffer = self.stacks.items[self.stacks.items.len - 1];
                    self.stacks.items.len -= 1;
                    self.allocator.free(buffer);
                }
            }
        };

        /// Allocator for `Frame.init` and `Frame.deinit`: the frame's stack comes
        /// from `frame_stacks`, anything else from the call arena.
        fn frameAllocator(self: *Self) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &frame_allocator_vtable };
        }

        const frame_allocator_vtable = std.mem.Allocator.VTable{
            .alloc = frameAlloc,
            .resize = frameResize,
            .remap = frameRemap,
            .free = frameFree,
        };

        fn frameAlloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(context));
            if (FrameStackPool.serves(len, alignment)) {
                return self.frame_stacks.acquire() orelse {
                    self.failHost(error.OutOfMemory);
                    return null;
                };
            }
            return callAlloc(context, len, alignment, return_address);
        }

        fn frameResize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            // A stack has one size. Refusing also keeps every other block from
            // growing into the shape that `frameFree` hands to the pool.
            if (FrameStackPool.serves(memory.len, alignment) or FrameStackPool.serves(new_len, alignment)) return false;
            return self.call_arena.allocator().rawResize(memory, alignment, new_len, return_address);
        }

        fn frameRemap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(context));
            if (FrameStackPool.serves(memory.len, alignment) or FrameStackPool.serves(new_len, alignment)) return null;
            return self.call_arena.allocator().rawRemap(memory, alignment, new_len, return_address);
        }

        fn frameFree(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (FrameStackPool.serves(memory.len, alignment)) {
                if (self.frame_stacks.release(memory.ptr)) return;
                log.err("Frame stack {*} is not a live stack of the pool", .{memory.ptr});
                return;
            }
            self.call_arena.allocator().rawFree(memory, alignment, return_address);
        }

        /// Run the block-start system updates enabled in the configuration: the
        /// EIP-4788 beacon root and the EIP-2935 parent block hash. Call it once per
        /// block, before the block's first transaction. `init` does not run it:
        /// creating an EVM must not write state, and a failed update is an error the
        /// host has to see.
        ///
        /// EIP-6110 deposits and EIP-7002 withdrawals have no block-start step and
        /// are not processed here. Both are collected at the end of a block, by the
        /// host: deposits from the receipts' logs (`validator_deposits.zig` parses
        /// them) and withdrawal requests by a system call to the predeploy
        /// (`validator_withdrawals.zig` has the constants).
        pub fn beginBlock(self: *Self) !void {
            // Each update applies only from its fork on. The system contracts can be
            // in state earlier (on mainnet both were deployed before activation), and
            // a pre-fork block must not write to them.
            if (config.enable_beacon_roots and comptime config.eips.is_eip_active(4788)) {
                @import("eips_and_hardforks/beacon_roots.zig").BeaconRootsContract.processBeaconRootUpdate(self.database, &self.block_info) catch |err| {
                    self.tracer.onBeaconRootUpdate(false, err);
                    return err;
                };
                self.tracer.onBeaconRootUpdate(true, null);
            }

            if (config.enable_historical_block_hashes and comptime config.eips.is_eip_active(2935)) {
                @import("eips_and_hardforks/historical_block_hashes.zig").HistoricalBlockHashesContract.processBlockHashUpdate(self.database, &self.block_info) catch |err| {
                    self.tracer.onHistoricalBlockHashUpdate(false, err);
                    return err;
                };
                self.tracer.onHistoricalBlockHashUpdate(true, null);
            }
        }

        /// Get the arena allocator for temporary allocations during the current call.
        /// This allocator is reset after each root call completes. A failed
        /// allocation is recorded as a host failure, so code that turns it into a
        /// frame halt (an opcode handler) cannot hide it from `call`.
        pub fn getCallArenaAllocator(self: *Self) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &call_allocator_vtable };
        }

        const call_allocator_vtable = std.mem.Allocator.VTable{
            .alloc = callAlloc,
            .resize = callResize,
            .remap = callRemap,
            .free = callFree,
        };

        fn callAlloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.call_arena.allocator().rawAlloc(len, alignment, return_address) orelse {
                self.failHost(error.OutOfMemory);
                return null;
            };
        }

        // A refused resize or remap is not a failure: the caller allocates instead.
        fn callResize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.call_arena.allocator().rawResize(memory, alignment, new_len, return_address);
        }

        fn callRemap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.call_arena.allocator().rawRemap(memory, alignment, new_len, return_address);
        }

        fn callFree(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.call_arena.allocator().rawFree(memory, alignment, return_address);
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
            if (self.large_stack_worker) |worker| {
                worker.destroy();
                self.large_stack_worker = null;
            }
            self.dispatch_cache.deinit();
            self.tracer.deinit();
            // Free return_data if it exists
            if (self.return_data) |data| {
                self.allocator.free(data);
            }
            self.journal.deinit();
            self.created_contracts.deinit();
            self.self_destruct.deinit();
            self.access_list.deinit();
            // Log topics and data live in the call arena (LOGn and emit_log allocate them
            // there); call_arena.deinit below frees them. Only the list itself is owned.
            self.logs.deinit(self.allocator);
            self.touched_addresses.deinit();
            self.transaction_touched.deinit(self.allocator);
            self.clearTouchedStorage();
            self.touched_storage.deinit();
            self.frame_memory.deinit();
            self.frame_stacks.deinit();
            self.call_arena.deinit();
        }

        /// Transfer value between accounts with proper balance checks and error handling
        fn transferWithBalanceChecks(self: *Self, from: primitives.Address, to: primitives.Address, value: u256, snapshot_id: Journal.SnapshotIdType) !void {
            var from_account = try self.database.get_account(from.bytes) orelse Account.zero();
            if (!config.disable_balance_checks) {
                if (from_account.balance < value) return error.InsufficientBalance;
            }
            if (from.equals(to)) return;
            var to_account = try self.database.get_account(to.bytes) orelse Account.zero();
            // A balance above 2^256 - 1 cannot exist. The transfer fails before it
            // changes anything, and its call fails with it.
            const credited = std.math.add(u256, to_account.balance, value) catch return error.BalanceOverflow;
            try self.journal.record_balance_change(snapshot_id, from, from_account.balance);
            try self.journal.record_balance_change(snapshot_id, to, to_account.balance);

            // Track addresses for state dump
            try self.touchAddress(from);
            try self.touchAddress(to);

            from_account.balance -= value;
            to_account.balance = credited;
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
                if (account.balance == 0 and account.nonce == 0 and std.mem.eql(u8, &account.code_hash, &(@as([32]u8, @splat(0))))) {
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
                if (!std.mem.eql(u8, &account.code_hash, &(@as([32]u8, @splat(0))))) {
                    const db_code = try self.database.get_code(account.code_hash);
                    code = try allocator.dupe(u8, db_code);
                }

                // Get storage
                var storage = std.AutoHashMap(u256, u256).init(allocator);

                // Get tracked storage slots for this address
                if (self.touched_storage.get(addr)) |slots| {
                    for (slots.keys()) |slot| {
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
        ///
        /// The interpreter recurses once per EVM call depth. When the calling thread's
        /// stack bounds are known and it has room, the call runs on it directly; a nested
        /// call that would come within `native_stack_reserve` of the end of the stack
        /// moves to the large-stack worker. When the bounds are unknown or too small, the
        /// whole call runs on the worker. There is no concurrency: the calling thread
        /// blocks until the worker finishes, so one thread at a time uses the EVM.
        ///
        /// A failed result with `error_info` set did not run to a transaction
        /// outcome: the transaction was invalid, or the host failed (`host_failure`
        /// is then set and `error_info` starts with "host failure"). State is
        /// unchanged in both cases.
        pub fn call(self: *Self, params: CallParams) CallResult {
            self.host_failure = null;
            self.database.failure = null;
            if (comptime native_stack.supported) {
                if (native_stack.lowAddress()) |low| {
                    const here = @frameAddress();
                    if (here > low and here - low >= inline_stack_minimum) {
                        self.native_stack_limit = low + native_stack_reserve;
                        defer self.native_stack_limit = 0;
                        return self.callImpl(params);
                    }
                }
            }

            // A target without threads has no other stack to move to.
            if (comptime !threads_available) return self.callImpl(params);

            const Job = struct {
                evm: *Self,
                params: CallParams,
                result: CallResult,
                fn run(context: *anyopaque) void {
                    const job: *@This() = @ptrCast(@alignCast(context));
                    job.result = job.evm.callImpl(job.params);
                }
            };
            var job = Job{ .evm = self, .params = params, .result = CallResult.failed(0) };
            self.runOnLargeStack(&job, Job.run) catch |err| {
                // Running a call of unknown depth on a stack of unknown size could
                // overflow it. Report the failure to the host instead. Nothing ran,
                // so there is no state to undo.
                log.warn("Cannot run the call on a large stack: {s}", .{@errorName(err)});
                return self.hostFailureResult(err);
            };
            return job.result;
        }

        /// True when the target can run a job on another thread's stack.
        const threads_available = !builtin.single_threaded and !builtin.target.cpu.arch.isWasm();
        /// Native stack size for call chains too deep for the caller's stack.
        const large_stack_size = 64 * 1024 * 1024;
        /// Stack kept free below a nested call for one frame's own work, including the
        /// deepest host calls it can make (precompiles, hashing, database access).
        const native_stack_reserve = 512 * 1024;
        /// Minimum free stack at `call` for running on the caller's stack at all.
        const inline_stack_minimum = 2 * native_stack_reserve;

        /// Run `func(context)` on the large-stack worker and wait for it. The worker
        /// thread is created on first use and reused by every later call.
        fn runOnLargeStack(self: *Self, context: *anyopaque, func: *const fn (*anyopaque) void) !void {
            const worker = self.large_stack_worker orelse created: {
                const worker = try native_stack.Worker.create(self.allocator, large_stack_size);
                self.large_stack_worker = worker;
                break :created worker;
            };
            try worker.run(context, func);
        }

        /// Run a nested call on the large-stack worker. The calling thread blocks until
        /// it finishes, so the EVM is still used by one thread at a time.
        fn innerCallOnLargeStack(self: *Self, params: CallParams) CallResult {
            // Without threads there is no larger stack; the nested call continues here.
            if (comptime !threads_available) {
                const saved_limit = self.native_stack_limit;
                self.native_stack_limit = 0;
                defer self.native_stack_limit = saved_limit;
                return self.inner_call(params);
            }

            const Job = struct {
                evm: *Self,
                params: CallParams,
                result: CallResult,
                fn run(context: *anyopaque) void {
                    const job: *@This() = @ptrCast(@alignCast(context));
                    job.result = job.evm.inner_call(job.params);
                }
            };
            // The large stack fits the deepest possible call chain, so nothing below
            // this call needs to be checked or moved again.
            const saved_limit = self.native_stack_limit;
            self.native_stack_limit = 0;
            defer self.native_stack_limit = saved_limit;

            var job = Job{ .evm = self, .params = params, .result = CallResult.failed(0) };
            self.runOnLargeStack(&job, Job.run) catch |err| {
                // Continuing on the nearly exhausted stack could overflow it. Whether
                // a thread can be created is not a property of the transaction, so
                // the whole transaction is aborted, not just this call.
                log.warn("Cannot run a deep call on a large stack: {s}", .{@errorName(err)});
                self.failHost(err);
                return CallResult.failed(0);
            };
            return job.result;
        }

        /// Largest gas budget a frame can hold: `Frame.GasType` is signed and sized
        /// from `config.block_gas_limit`, and the tracer reports gas as `i64`.
        const max_frame_gas: u64 = @min(std.math.maxInt(Frame.GasType), std.math.maxInt(i64));

        /// Undo every state change of the current transaction after a host failure
        /// (allocation or database error) and report the failure. A host failure is
        /// not a transaction outcome, so no partial state may remain. Logs, refunds
        /// and destruction records are dropped when `callImpl` returns.
        fn abortTransaction(self: *Self, tx_snapshot_depth: usize, err: anyerror) CallResult {
            self.database.revert_to_depth(tx_snapshot_depth);
            return self.hostFailureResult(err);
        }

        /// Record that the host failed. The first failure of a call is kept.
        fn failHost(self: *Self, err: anyerror) void {
            if (self.host_failure == null) self.host_failure = err;
        }

        /// Record a host failure when `err` is one. Errors a transaction can cause
        /// (a failed precompile, an invalid jump, a missing balance) are not.
        fn noteHostFailure(self: *Self, err: anyerror) void {
            if (isHostFailure(err)) self.failHost(err);
        }

        /// Pass `result` through and record its error when it is a host failure.
        /// The functions opcode handlers call go through this: a handler turns any
        /// error into a frame halt, which would otherwise hide a host failure.
        inline fn noting(self: *Self, result: anytype) @TypeOf(result) {
            if (result) |_| {} else |err| self.noteHostFailure(err);
            return result;
        }

        /// True for errors that come from the host's resources or state store. A
        /// transaction cannot cause them, so they must not decide its outcome.
        fn isHostFailure(err: anyerror) bool {
            return switch (err) {
                // Memory. `AllocationError` here is never a frame's own memory limit:
                // errors raised while a frame interprets code end that frame as a
                // normal halt and do not reach this function.
                error.OutOfMemory,
                error.AllocationError,
                // The point evaluation precompile cannot run without its setup.
                error.TrustedSetupNotLoaded,
                // A precompile's backend failed without judging its input.
                error.PrecompileBackendFailure,
                // The database lost or refused data it must have.
                error.CodeNotFound,
                error.StorageNotFound,
                error.SnapshotNotFound,
                error.InvalidSnapshot,
                error.DatabaseCorrupted,
                error.NetworkError,
                error.PermissionDenied,
                // Broken invariants of the call machinery.
                error.GasExceedsFrameCapacity,
                error.TransactionNonceNotIncremented,
                => true,
                else => false,
            };
        }

        /// The failed result of a call the host could not run: records `err` and
        /// describes the first host failure in `error_info`. A host failure reaches
        /// the caller through the result and `host_failure`, so the code that
        /// detects one logs a warning, not an error.
        fn hostFailureResult(self: *Self, err: anyerror) CallResult {
            self.failHost(err);
            var result = CallResult.failed(0);
            result.error_info = std.fmt.allocPrint(self.allocator, "host failure: {s}", .{@errorName(self.host_failure.?)}) catch |format_err| {
                // `host_failure` already reports the failure; only the text is lost.
                log.warn("Cannot describe the host failure: {s}", .{@errorName(format_err)});
                return result;
            };
            return result;
        }

        /// The failed result of a transaction that is invalid and changed no state.
        fn rejectTransaction(self: *Self, comptime reason: []const u8) CallResult {
            log.debug("Transaction rejected: " ++ reason, .{});
            var result = CallResult.failed(0);
            result.error_info = self.allocator.dupe(u8, "invalid transaction: " ++ reason) catch |err| {
                self.failHost(err);
                return result;
            };
            return result;
        }

        /// Copy the transaction's logs out of the call arena into `self.allocator`.
        fn copyLogs(self: *Self) ![]const call_result_module.Log {
            const Log = call_result_module.Log;
            const copies = try self.allocator.alloc(Log, self.logs.items.len);
            var copied: usize = 0;
            errdefer {
                for (copies[0..copied]) |entry| {
                    self.allocator.free(entry.topics);
                    self.allocator.free(entry.data);
                }
                self.allocator.free(copies);
            }
            for (self.logs.items) |entry| {
                const topics = try self.allocator.dupe(u256, entry.topics);
                errdefer self.allocator.free(topics);
                const data = try self.allocator.dupe(u8, entry.data);
                copies[copied] = .{ .address = entry.address, .topics = topics, .data = data };
                copied += 1;
            }
            return copies;
        }

        fn callImpl(self: *Self, params: CallParams) CallResult {
            self.tracer.assert(self.depth == 0, "call() should only be called at top level");
            // The arena reports growth to the tracer; `self` is at its final address here.
            // Clear the pointer on return so a moved or copied Evm never holds a
            // pointer into its old location between calls.
            self.call_arena.tracer = @as(*anyopaque, @ptrCast(&self.tracer));
            defer self.call_arena.tracer = null;

            // Validate the gas budget before anything narrows it. Frame gas is a
            // `Frame.GasType` and the tracer takes an `i64`; a budget neither can hold
            // would be truncated, so refuse the call instead.
            const gas_limit = params.getGas();
            if (gas_limit > max_frame_gas) {
                log.warn("Call gas {d} exceeds the configured frame gas capacity {d} (raise EvmConfig.block_gas_limit)", .{ gas_limit, max_frame_gas });
                return self.rejectTransaction("gas limit exceeds the configured frame gas capacity");
            }

            const to_address = params.get_to() orelse primitives.ZERO_ADDRESS;
            const value = switch (params) {
                .call => |p| p.value,
                .callcode => |p| p.value,
                .delegatecall => 0,
                .staticcall => 0,
                .create => |p| p.value,
                .create2 => |p| p.value,
            };
            self.tracer.onCallStart(@tagName(params), @as(i64, @intCast(gas_limit)), to_address, value);

            // Track origin and to addresses for state dump. The touched sets are
            // cumulative: they are cleared only by `resetTouched`.
            self.touchAddress(self.origin) catch |err| {
                log.warn("Failed to track origin address: {s}", .{@errorName(err)});
                return self.hostFailureResult(err);
            };
            if (!to_address.equals(primitives.ZERO_ADDRESS)) {
                self.touchAddress(to_address) catch |err| {
                    log.warn("Failed to track to address: {s}", .{@errorName(err)});
                    return self.hostFailureResult(err);
                };
            }

            params.validateFor(config.eips.hardfork, config.max_initcode_size) catch |err| {
                log.debug("CallParams validation failed: {s}", .{@errorName(err)});
                return switch (err) {
                    error.GasZeroError => self.rejectTransaction("gas limit is zero"),
                    error.InvalidInitCodeSize => self.rejectTransaction("init code exceeds the EIP-3860 size limit"),
                    error.InvalidCreateValue => self.rejectTransaction("creation value is invalid"),
                    error.InvalidStaticCallValue => self.rejectTransaction("a static call cannot carry value"),
                };
            };

            defer {
                self.depth = 0;
                // Clear return_data for next transaction (it persists until next call overwrites it)
                // Don't free here - it's freed in deinit or when set_return_data overwrites it
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

                // Reset call stack to initial state
                // This is critical when reusing EVM instances across multiple transactions
                self.call_stack = @as([config.max_call_depth + 1]CallStackEntry, @splat(CallStackEntry{ .caller = primitives.Address.ZERO_ADDRESS, .value = 0, .is_static = false }));
                // Reset snapshot ID
                self.current_snapshot_id = 0;
                self.tx_sender_nonce_incremented = false;
                // Return frame memory that only an unusually large transaction needed.
                self.frame_memory.trim();
                self.frame_stacks.trim();
                // Reset arena allocator but retain grown capacity
                // This prevents memory buildup while keeping the grown capacity for better performance
                // on subsequent transactions that need similar memory amounts
                self.call_arena.resetRetainCapacity() catch |err| {
                    // The arena stays usable after a failed reset; it only keeps less
                    // capacity for the next transaction, which then grows it again.
                    log.warn("Arena reset failed: {s}", .{@errorName(err)});
                };
                // Reset tracer state for next call
                self.tracer.instruction_safety.count = 0;
                self.tracer.instruction_count = 0;
                self.tracer.schedule_index = 0;
                self.tracer.simple_instruction_count = 0;
                self.tracer.fused_instruction_count = 0;
                // Clear steps arrays but keep capacity
                self.tracer.clearSteps();
            }

            // Pre-warm addresses for top-level calls (EIP-2929 & EIP-3651)
            config.eips.pre_warm_transaction_addresses(
                &self.access_list,
                self.origin,
                params.get_to(),
                self.block_info.coinbase,
            ) catch |err| {
                log.warn("Failed to pre-warm addresses: {s}", .{@errorName(err)});
                return self.hostFailureResult(err);
            };
            // EIP-7702: the delegate of a delegated transaction target starts warm.
            self.warmDelegatedTarget(params.get_to()) catch |err| {
                log.warn("Failed to pre-warm the delegate of the target: {s}", .{@errorName(err)});
                return self.hostFailureResult(err);
            };

            // EIP-2929 (Berlin+): exactly the precompiles active in this fork start warm.
            // An address not yet active (e.g. 0x0A before Cancun, 0x100 before Osaka) stays
            // cold. Final EIP-2537 ends at 0x11; 0x100 is Osaka's P256VERIFY (EIP-7951).
            if (comptime config.eips.hardfork.isAtLeast(.BERLIN)) {
                const last = comptime precompiles.lastContiguousPrecompile(config.eips.hardfork);
                var precompile_index: u16 = 0x01;
                while (precompile_index <= last) : (precompile_index += 1) {
                    self.warmPrecompile(primitives.Address.fromU256(precompile_index)) catch |err| {
                        log.warn("Failed to pre-warm precompile: {s}", .{@errorName(err)});
                        return self.hostFailureResult(err);
                    };
                }
                if (comptime config.eips.hardfork.isAtLeast(.OSAKA)) {
                    self.warmPrecompile(precompiles.P256VERIFY_ADDRESS) catch |err| {
                        log.warn("Failed to pre-warm precompile: {s}", .{@errorName(err)});
                        return self.hostFailureResult(err);
                    };
                }
                // Configured precompiles (e.g. an L2's) are precompiles of this chain.
                if (comptime config.enable_precompiles) {
                    inline for (config.precompile_overrides) |override| {
                        self.access_list.pre_warm_addresses(&[_]primitives.Address{override.address}) catch |err| {
                            log.warn("Failed to pre-warm precompile: {s}", .{@errorName(err)});
                            return self.hostFailureResult(err);
                        };
                    }
                }
            }

            const input = params.getInput();
            const calldata_tokens = config.eips.tokens_in_calldata(input);
            const intrinsic_gas_cost = config.eips.intrinsic_gas_cost(params.isCreate());
            const calldata_gas_cost = config.eips.calldata_gas_cost(calldata_tokens, params.isCreate(), input.len);
            const floor_gas_cost = config.eips.floor_gas_cost(calldata_tokens);
            const initial_gas_cost = intrinsic_gas_cost + calldata_gas_cost;

            // A budget below the intrinsic cost leaves no execution gas to compute,
            // so this check applies even when gas checks are disabled.
            if (gas_limit < initial_gas_cost) {
                return self.rejectTransaction("gas limit is below the intrinsic gas cost");
            }
            if (comptime !config.disable_gas_checks) {
                if (gas_limit < floor_gas_cost) {
                    return self.rejectTransaction("gas limit is below the EIP-7623 calldata floor");
                }
                // EIP-7825: a transaction above TX_GAS_LIMIT_CAP is invalid; reject before nonce increment.
                config.eips.validate_transaction_gas_limit(gas_limit) catch |err| {
                    log.debug("Transaction gas limit refused: {s}", .{@errorName(err)});
                    return self.rejectTransaction("gas limit exceeds the EIP-7825 transaction gas cap");
                };
            }
            const execution_gas_limit = gas_limit - initial_gas_cost;

            // EIP-1559: a transaction that states its fee caps must be able to pay the
            // base fee, and cannot tip more than its cap. A context without
            // `max_fee_per_gas` carries no caps to check.
            if (comptime !config.disable_gas_checks) {
                if (self.context.max_fee_per_gas) |max_fee_per_gas| {
                    config.eips.validate_fee_caps(self.block_info.base_fee, max_fee_per_gas, self.context.max_priority_fee_per_gas) catch |err| switch (err) {
                        error.MaxFeeBelowBaseFee => return self.rejectTransaction("max fee per gas is below the block base fee (EIP-1559)"),
                        error.PriorityFeeAboveMaxFee => return self.rejectTransaction("max priority fee per gas exceeds max fee per gas (EIP-1559)"),
                    };
                }
            }

            const blob_versioned_hashes = self.context.blob_versioned_hashes;
            const blob_count = if (self.context.is_blob_transaction) blob_versioned_hashes.len else 0;
            config.eips.validate_blob_gas(
                self.context.is_blob_transaction,
                blob_versioned_hashes,
                self.context.max_fee_per_blob_gas,
                self.block_info.blob_base_fee,
                params.get_to(),
            ) catch |err| {
                log.debug("Blob transaction validation failed: {s}", .{@errorName(err)});
                return self.rejectTransaction("blob transaction fields are invalid (EIP-4844)");
            };

            const max_blob_gas_cost = config.eips.max_blob_gas_cost(
                self.context.max_fee_per_blob_gas,
                blob_count,
            );

            // The sender buys all of the gas up front at the effective gas price and
            // pays the blob fee, which is burned. Unused gas is bought back after
            // execution. Checked arithmetic: an overflowing cost is unpayable.
            const blob_gas_cost: u256 = config.eips.blob_gas_cost(
                self.block_info.blob_base_fee,
                blob_count,
            );
            const gas_cost = @mulWithOverflow(@as(u256, gas_limit), self.gas_price);
            const upfront_cost = @addWithOverflow(gas_cost[0], blob_gas_cost);
            if (gas_cost[1] != 0 or upfront_cost[1] != 0) {
                return self.rejectTransaction("gas limit times gas price overflows");
            }

            const origin_before = self.database.get_account(self.origin.bytes) catch |err| {
                log.warn("Failed to read origin account for upfront balance check: {s}", .{@errorName(err)});
                return self.hostFailureResult(err);
            } orelse Account.zero();

            // Transaction validity is checked before nonce increment or execution.
            // EIP-1559 reserves the fee cap, not the lower effective gas price.
            if (!config.disable_balance_checks) {
                const gas_fee_cap = self.context.max_fee_per_gas orelse self.gas_price;
                const max_execution_cost = @mulWithOverflow(@as(u256, gas_limit), gas_fee_cap);
                if (max_execution_cost[1] != 0) {
                    return self.rejectTransaction("gas limit times max fee per gas overflows");
                }
                const execution_and_value = @addWithOverflow(max_execution_cost[0], params.getValue());
                if (execution_and_value[1] != 0) {
                    return self.rejectTransaction("gas cost plus value overflows");
                }
                const required_balance = @addWithOverflow(execution_and_value[0], max_blob_gas_cost);
                if (required_balance[1] != 0 or origin_before.balance < required_balance[0]) {
                    return self.rejectTransaction("sender balance is below gas limit times max fee per gas plus value");
                }
                if (origin_before.balance < upfront_cost[0]) {
                    return self.rejectTransaction("sender balance is below the up-front gas cost");
                }
            }
            // EIP-2681: a sender whose nonce is at the limit cannot send a transaction.
            if (origin_before.nonce == std.math.maxInt(u64)) {
                return self.rejectTransaction("sender nonce is at the EIP-2681 limit");
            }

            // From here on the transaction changes state. The snapshot lets a host
            // failure undo all of it, including the gas purchase and nonce increment.
            const tx_snapshot_depth = self.database.snapshot_depth();
            const tx_snapshot = self.database.create_snapshot() catch |err| {
                log.warn("Failed to open the transaction snapshot: {s}", .{@errorName(err)});
                return self.hostFailureResult(err);
            };

            // Buy gas and increment the origin nonce (EIP-2718) in one account write,
            // before execution, so the code never sees or spends the gas money.
            // With balance checks disabled the sender pays what it has.
            const charged: u256 = if (config.disable_balance_checks) @min(origin_before.balance, upfront_cost[0]) else upfront_cost[0];
            {
                var origin_account = origin_before;
                self.journal.record_nonce_change(self.current_snapshot_id, self.origin, origin_account.nonce) catch |err| {
                    log.warn("Failed to journal the origin nonce: {s}", .{@errorName(err)});
                    return self.abortTransaction(tx_snapshot_depth, err);
                };
                self.journal.record_balance_change(self.current_snapshot_id, self.origin, origin_account.balance) catch |err| {
                    log.warn("Failed to journal the gas purchase: {s}", .{@errorName(err)});
                    return self.abortTransaction(tx_snapshot_depth, err);
                };
                origin_account.nonce += 1;
                origin_account.balance -= charged;
                self.database.set_account(self.origin.bytes, origin_account) catch |err| {
                    log.warn("Failed to buy gas for the transaction: {s}", .{@errorName(err)});
                    return self.abortTransaction(tx_snapshot_depth, err);
                };
                self.tx_sender_nonce_incremented = true;
            }

            var modified_params = params;
            modified_params.setGas(execution_gas_limit);

            var arena_result = self.inner_call(modified_params);
            // The trace is allocated with `self.allocator`, not the call arena, so
            // it moves into the owned result as it is. Until then it is freed here.
            var trace = arena_result.trace;
            arena_result.trace = null;
            defer if (trace) |*unclaimed| unclaimed.deinit();
            if (self.host_failure) |err| {
                // The host failed somewhere in the call tree. Whatever the frames
                // made of it is not the transaction's outcome.
                log.warn("Transaction aborted by a host failure: {s}", .{@errorName(err)});
                return self.abortTransaction(tx_snapshot_depth, err);
            }
            // Clone result to main allocator since we're at depth 0 (top-level call)
            var result = arena_result.toOwnedResult(self.allocator) catch |err| {
                log.warn("Failed to clone call result: {s}", .{@errorName(err)});
                return self.abortTransaction(tx_snapshot_depth, err);
            };
            result.trace = trace;
            trace = null;

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

            // Buy back the unused gas. `gas_consumed <= gas_limit`, so neither product
            // can exceed the checked up-front cost. The blob fee stays burned.
            const gas_consumed_u256: u256 = gas_consumed;
            const unused_gas: u256 = gas_limit -| gas_consumed;
            const refund: u256 = @min(unused_gas * self.gas_price, charged);
            if (refund > 0) {
                var origin_account = self.database.get_account(self.origin.bytes) catch |err| {
                    log.warn("Failed to read the origin account for the gas refund: {s}", .{@errorName(err)});
                    result.deinit(self.allocator);
                    return self.abortTransaction(tx_snapshot_depth, err);
                } orelse Account.zero();
                const refunded_balance = @addWithOverflow(origin_account.balance, refund);
                if (refunded_balance[1] != 0) {
                    log.warn("Origin balance overflows on the gas refund", .{});
                    result.deinit(self.allocator);
                    return self.abortTransaction(tx_snapshot_depth, error.BalanceOverflow);
                }
                origin_account.balance = refunded_balance[0];
                self.database.set_account(self.origin.bytes, origin_account) catch |err| {
                    log.warn("Failed to refund unused gas: {s}", .{@errorName(err)});
                    result.deinit(self.allocator);
                    return self.abortTransaction(tx_snapshot_depth, err);
                };
            }

            // Pay the block producer. From EIP-1559 the base fee is burned and only the
            // priority fee is paid; before it the whole gas price is.
            const reward_per_gas: u256 = if (config.eips.eip_1559_is_enabled())
                self.gas_price -| self.block_info.base_fee
            else
                self.gas_price;
            const coinbase_reward = reward_per_gas * gas_consumed_u256;
            if (coinbase_reward > 0) {
                var coinbase_account = self.database.get_account(self.block_info.coinbase.bytes) catch |err| {
                    log.warn("Failed to read the coinbase account: {s}", .{@errorName(err)});
                    result.deinit(self.allocator);
                    return self.abortTransaction(tx_snapshot_depth, err);
                } orelse Account.zero();
                const rewarded_balance = @addWithOverflow(coinbase_account.balance, coinbase_reward);
                if (rewarded_balance[1] != 0) {
                    log.warn("Coinbase balance overflows on the block reward", .{});
                    result.deinit(self.allocator);
                    return self.abortTransaction(tx_snapshot_depth, error.BalanceOverflow);
                }
                self.journal.record_balance_change(0, self.block_info.coinbase, coinbase_account.balance) catch |err| {
                    log.warn("Failed to journal the coinbase reward: {s}", .{@errorName(err)});
                    result.deinit(self.allocator);
                    return self.abortTransaction(tx_snapshot_depth, err);
                };
                coinbase_account.balance = rewarded_balance[0];
                self.database.set_account(self.block_info.coinbase.bytes, coinbase_account) catch |err| {
                    log.warn("Failed to pay the coinbase reward: {s}", .{@errorName(err)});
                    result.deinit(self.allocator);
                    return self.abortTransaction(tx_snapshot_depth, err);
                };
            }

            // Delete the destroyed accounts last, after the gas refund and the fee
            // payment (execution-specs `process_transaction`): a coinbase that
            // destroyed itself in this transaction is deleted with the fee it earned.
            if (result.success) {
                self.finalizeDestructions() catch |err| {
                    log.warn("Failed to finalize selfdestructions: {s}", .{@errorName(err)});
                    result.deinit(self.allocator);
                    return self.abortTransaction(tx_snapshot_depth, err);
                };
            }

            // Logs live in the call arena. Build the owned copy completely before the
            // result's (empty) list is replaced, so a failure never leaves `result.logs`
            // pointing at freed memory.
            if (self.logs.items.len > 0) {
                const owned_logs = self.copyLogs() catch |err| {
                    log.warn("Failed to copy result logs: {s}", .{@errorName(err)});
                    result.deinit(self.allocator);
                    return self.abortTransaction(tx_snapshot_depth, err);
                };
                self.allocator.free(result.logs);
                result.logs = owned_logs;
            }

            // Report the accounts the transaction destroyed, on every fork. From
            // Cancun (EIP-6780) these are only contracts created in the transaction.
            {
                const records = self.self_destruct.toOwnedSlice(self.allocator) catch |err| {
                    log.warn("Failed to transfer selfdestructs: {s}", .{@errorName(err)});
                    result.deinit(self.allocator);
                    return self.abortTransaction(tx_snapshot_depth, err);
                };
                self.allocator.free(result.selfdestructs);
                result.selfdestructs = records;
            }

            // Extract access list data before clearing
            const accessed_addresses = self.allocator.dupe(primitives.Address, self.access_list.addresses.keys()) catch |err| {
                log.warn("Failed to copy accessed addresses: {s}", .{@errorName(err)});
                result.deinit(self.allocator);
                return self.abortTransaction(tx_snapshot_depth, err);
            };
            self.allocator.free(result.accessed_addresses);
            result.accessed_addresses = accessed_addresses;

            // Convert StorageKey to StorageAccess (same fields, different type)
            const storage_keys = self.access_list.storage_slots.keys();
            const storage_access = self.allocator.alloc(call_result_module.StorageAccess, storage_keys.len) catch |err| {
                log.warn("Failed to copy accessed storage: {s}", .{@errorName(err)});
                result.deinit(self.allocator);
                return self.abortTransaction(tx_snapshot_depth, err);
            };
            for (storage_keys, 0..) |key, i| {
                storage_access[i] = .{ .address = key.address, .slot = key.slot };
            }
            self.allocator.free(result.accessed_storage);
            result.accessed_storage = storage_access;

            self.database.commit_snapshot(tx_snapshot) catch |err| {
                log.warn("Failed to close the transaction snapshot: {s}", .{@errorName(err)});
                result.deinit(self.allocator);
                return self.abortTransaction(tx_snapshot_depth, err);
            };

            return result;
        }

        /// Execute a nested EVM call - used for calls from within the EVM.
        /// This handles nested calls and manages depth tracking.
        pub fn inner_call(self: *Self, params: CallParams) CallResult {
            @branchHint(.likely);
            if (self.native_stack_limit != 0 and @frameAddress() < self.native_stack_limit) {
                @branchHint(.cold);
                return self.innerCallOnLargeStack(params);
            }
            const execution_gas = params.getGas();

            // After a host failure the transaction is aborted. Nothing a frame does
            // from here on is kept, so no further call runs.
            if (self.host_failure != null) {
                @branchHint(.cold);
                return CallResult.failed(0);
            }

            // depth is incremented solely by execute_frame (CALL variants) and the create paths;
            // inner_call must NOT increment it again or every nesting level would advance depth
            // by 2 (halving the limit) and leave a call_stack gap that corrupts parent
            // caller/value/is_static lookups. (Deep recursion is safe: call() runs on a
            // large-stack worker thread.)
            //
            // Depth limit, execution-specs `evm.message.depth + 1 > STACK_DEPTH_LIMIT`: `depth`
            // counts active frames, so the frame at 0-based depth d runs with depth == d + 1
            // and may call only while d < max_call_depth. A refused call hands back all the
            // gas it was given. Creations apply the limit themselves, after deducting their
            // own charge.
            if (!params.isCreate() and self.depth > config.max_call_depth) return CallResult.failed(execution_gas);

            // A call that carries no gas is still a call: it succeeds against an account
            // without code and runs code whose first block is free. Nothing is rejected
            // here on gas alone.

            const refund_before = self.gas_refund_counter;
            const logs_before = self.logs.items.len;
            const access_mark = self.access_list.checkpoint();
            const destructions_mark = self.self_destruct.checkpoint();
            // Every call opens one journal snapshot and one database snapshot. A call
            // that fails reverts its own; a call that succeeds leaves the database
            // snapshot open, and it is committed below only once the caller's copy of
            // the return data exists. These marks let any other ending be rolled back.
            const journal_mark = self.journal.next_snapshot_id;
            const database_depth = self.database.snapshot_depth();

            var result = switch (params) {
                .call => |p| blk: {
                    @branchHint(.likely);
                    break :blk self.executeCall(.{ .caller = p.caller, .to = p.to, .value = p.value, .input = p.input, .gas = execution_gas }) catch |err| {
                        log.debug("inner_call: CALL failed: {s}", .{@errorName(err)});
                        self.noteHostFailure(err);
                        break :blk CallResult.failed(0);
                    };
                },
                .staticcall => |p| blk: {
                    @branchHint(.likely);
                    break :blk self.executeStaticcall(.{ .caller = p.caller, .to = p.to, .input = p.input, .gas = execution_gas }) catch |err| {
                        log.debug("inner_call: STATICCALL failed: {s}", .{@errorName(err)});
                        self.noteHostFailure(err);
                        break :blk CallResult.failed(0);
                    };
                },
                .delegatecall => |p| blk: {
                    break :blk self.executeDelegatecall(.{ .caller = p.caller, .context_address = p.context_address orelse p.caller, .to = p.to, .input = p.input, .gas = execution_gas }) catch |err| {
                        log.debug("inner_call: DELEGATECALL failed: {s}", .{@errorName(err)});
                        self.noteHostFailure(err);
                        break :blk CallResult.failed(0);
                    };
                },
                .create => |p| blk: {
                    break :blk self.executeCreate(.{ .caller = p.caller, .value = p.value, .init_code = p.init_code, .gas = execution_gas }) catch |err| {
                        log.debug("inner_call: CREATE failed: {s}", .{@errorName(err)});
                        self.noteHostFailure(err);
                        break :blk CallResult.failed(0);
                    };
                },
                .create2 => |p| blk: {
                    break :blk self.executeCreate2(.{ .caller = p.caller, .value = p.value, .init_code = p.init_code, .salt = p.salt, .gas = execution_gas }) catch |err| {
                        log.debug("inner_call: CREATE2 failed: {s}", .{@errorName(err)});
                        self.noteHostFailure(err);
                        break :blk CallResult.failed(0);
                    };
                },
                .callcode => |p| blk: {
                    @branchHint(.cold);
                    break :blk self.executeCallcode(.{ .caller = p.caller, .to = p.to, .value = p.value, .input = p.input, .gas = execution_gas }) catch |err| {
                        log.debug("inner_call: CALLCODE failed: {s}", .{@errorName(err)});
                        self.noteHostFailure(err);
                        break :blk CallResult.failed(0);
                    };
                },
            };

            // A database write that ran out of memory inside the frame halted the
            // frame like any failed opcode. The database remembers it.
            if (self.database.failure) |err| self.failHost(err);

            // EIP-211: the caller's return data buffer holds the output of the frame that
            // just ended: its RETURN or REVERT data for a call, only REVERT data for a
            // creation, and nothing after an exceptional halt. The copy is made while
            // the call's snapshot is still open, so a failure here undoes the call.
            const return_data: []const u8 = if (params.isCreate() and result.success) &.{} else result.output;
            self.set_return_data(return_data) catch |err| {
                log.warn("inner_call: failed to store return data: {s}", .{@errorName(err)});
                self.failHost(err);
                self.clear_return_data();
            };
            if (self.host_failure != null) {
                // The call's outcome is void. Its trace stays with the result: the
                // top-level caller owns and frees it.
                const trace = result.trace;
                result = CallResult.failed(0);
                result.trace = trace;
            }

            if (result.success) {
                self.database.commit_to_depth(database_depth);
            } else {
                // A call that fails changes nothing. This also closes the snapshots of
                // a call that returned an error with them still open.
                self.journal.revert_to_snapshot(journal_mark);
                self.database.revert_to_depth(database_depth);
                // Refunds earned inside a frame that did not succeed are discarded
                // together with its state changes (execution-specs: refund_counter is
                // merged into the parent only by incorporate_child_on_success).
                self.gas_refund_counter = refund_before;
                self.logs.shrinkRetainingCapacity(logs_before);
                self.self_destruct.revert(destructions_mark);
                // The failed frame's warm addresses and slots are discarded too. A
                // creation keeps its new address warm (generic_create warms it in the
                // parent), so executeCreate and executeCreate2 roll back themselves.
                if (!params.isCreate()) self.access_list.revert(access_mark);
            }

            result.logs = &.{};
            result.selfdestructs = &.{};
            result.accessed_addresses = &.{};
            result.accessed_storage = &.{};

            return result;
        }

        /// Result of pre-flight checks for call operations
        const PreflightResult = union(enum) {
            precompile_result: CallResult,
            execute_with_code: Code,
            empty_account: u64, // gas remaining
        };

        /// Code to execute, with the hash it is stored under when it has one.
        const Code = struct {
            bytes: []const u8,
            /// Code hash of deployed code. Null for code that is not stored under a
            /// hash (an EIP-7702 delegation designator), which is never cached.
            hash: ?[32]u8,
        };

        /// Run a precompile configured in `EvmConfig.precompile_overrides` when `address`
        /// names one. These take precedence over the fork's standard precompiles, so a
        /// chain can replace one or add its own (e.g. an L2's P256VERIFY at 0x100).
        fn executePrecompileOverride(self: *Self, address: primitives.Address, input: []const u8, gas: u64) ?CallResult {
            if (comptime !config.enable_precompiles) return null;
            inline for (config.precompile_overrides) |override| {
                if (address.equals(override.address)) {
                    const output = override.execute(self.getCallArenaAllocator(), input, gas) catch |err| {
                        log.debug("Precompile override at {x} failed: {s}", .{ address.bytes, @errorName(err) });
                        self.noteHostFailure(err);
                        return CallResult.failed(0);
                    };
                    // A failed precompile, or one that reports using more gas than it
                    // was given, consumes all of the gas.
                    if (!output.success or output.gas_used > gas) return CallResult.failed(0);
                    return CallResult{
                        .success = true,
                        .gas_left = gas - output.gas_used,
                        .output = output.output,
                    };
                }
            }
            return null;
        }

        /// The precompile result of a call whose code is at `code_address`, or null when
        /// that address runs ordinary code. `delegated` is true when `code_address` came
        /// from an EIP-7702 delegation: a delegation to a precompile address runs that
        /// account's code (normally empty), never the precompile.
        fn executePrecompileAt(self: *Self, code_address: primitives.Address, delegated: bool, input: []const u8, gas: u64, is_static: bool, snapshot_id: Journal.SnapshotIdType) ?CallResult {
            if (comptime !config.enable_precompiles) return null;
            if (delegated) return null;
            if (self.executePrecompileOverride(code_address, input, gas)) |result| return result;
            if (!precompiles.isPrecompile(code_address, config.eips.hardfork)) return null;
            return self.executePrecompileInline(code_address, input, gas, is_static, snapshot_id) catch |err| {
                log.debug("Precompile at {x} failed: {s}", .{ code_address.bytes, @errorName(err) });
                self.noteHostFailure(err);
                return CallResult.failed(0);
            };
        }

        /// Perform pre-flight checks common to all call operations.
        ///
        /// The EIP-7702 delegation of `to` is resolved first; the precompile checks then
        /// apply to the resolved code address. System contracts (EIP-4788 beacon roots,
        /// EIP-2935 block hashes) are ordinary accounts: their deployed bytecode runs
        /// from state like any other contract's.
        fn performCallPreflight(self: *Self, to: primitives.Address, input: []const u8, gas: u64, is_static: bool, snapshot_id: Journal.SnapshotIdType) !PreflightResult {
            const account = try self.database.get_account(to.bytes);

            // Get the effective code address (handles delegation)
            const code_address = config.eips.eip_7702_get_effective_code_address(account, to);
            const delegated = !code_address.equals(to);

            if (self.executePrecompileAt(code_address, delegated, input, gas, is_static, snapshot_id)) |result| {
                return PreflightResult{ .precompile_result = result };
            }

            // Get contract code (from delegated address if applicable)
            const code = try self.codeAt(code_address);
            if (code.bytes.len == 0) {
                return PreflightResult{ .empty_account = gas };
            }

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
            @branchHint(.likely);
            const snapshot_id = try self.journal.create_snapshot();
            const db_snapshot_id = try self.database.create_snapshot();

            if (params.value > 0) {
                self.transferWithBalanceChecks(params.caller, params.to, params.value, snapshot_id) catch |err| {
                    log.debug("Call value transfer failed: {}", .{err});
                    self.noteHostFailure(err);
                    self.journal.revert_to_snapshot(snapshot_id);
                    try self.database.revert_to_snapshot(db_snapshot_id);
                    // execution-specs: a call the sender cannot fund never starts, so the
                    // gas it was given returns to the caller.
                    return CallResult.failed(if (err == error.InsufficientBalance) params.gas else 0);
                };
            }

            // Before EIP-161 (Spurious Dragon) every message call creates its target
            // account if missing (execution-specs frontier `process_message` ->
            // `touch_account`), precompiles included. The database snapshot reverts the
            // creation when the call fails.
            if (comptime !config.eips.hardfork.isAtLeast(.SPURIOUS_DRAGON)) {
                if ((try self.database.get_account(params.to.bytes)) == null) {
                    try self.database.set_account(params.to.bytes, Account.zero());
                    try self.touchAddress(params.to);
                }
            }

            const preflight = self.performCallPreflight(params.to, params.input, params.gas, self.is_static_context(), snapshot_id) catch |err| {
                self.tracer.onCallPreflight("CALL", @errorName(err));
                self.noteHostFailure(err);
                self.journal.revert_to_snapshot(snapshot_id);
                try self.database.revert_to_snapshot(db_snapshot_id);
                return CallResult.failed(0);
            };
            self.tracer.onCallPreflight("CALL", @tagName(preflight));

            switch (preflight) {
                .precompile_result => |result| {
                    // A failed precompile call undoes its value transfer, like any failed call.
                    if (!result.success) {
                        self.journal.revert_to_snapshot(snapshot_id);
                        try self.database.revert_to_snapshot(db_snapshot_id);
                    }
                    return result;
                },
                .empty_account => |gas| {
                    self.tracer.onCodeRetrieval(params.to, 0, true);
                    return CallResult.succeeded_empty(gas);
                },
                .execute_with_code => |code| {
                    self.tracer.onCodeRetrieval(params.to, code.bytes.len, false);
                    const result = self.execute_frame(
                        code,
                        params.input,
                        params.gas,
                        params.to,
                        params.caller,
                        params.value,
                        self.is_static_context(), // EIP-214: inherit parent static context
                        snapshot_id,
                    ) catch |err| {
                        log.debug("EXECUTE_CALL: execute_frame failed with error: {}", .{err});
                        self.noteHostFailure(err);
                        self.journal.revert_to_snapshot(snapshot_id);
                        try self.database.revert_to_snapshot(db_snapshot_id);
                        return CallResult.failed(0);
                    };

                    if (!result.success) {
                        self.journal.revert_to_snapshot(snapshot_id);
                        try self.database.revert_to_snapshot(db_snapshot_id);
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

            if (params.value > 0) {
                if (!config.disable_balance_checks) {
                    const caller_account = self.database.get_account(params.caller.bytes) catch |err| {
                        @branchHint(.cold);
                        self.noteHostFailure(err);
                        self.journal.revert_to_snapshot(snapshot_id);
                        try self.database.revert_to_snapshot(db_snapshot_id);
                        return CallResult.failed(0);
                    };
                    if (caller_account == null or caller_account.?.balance < params.value) {
                        @branchHint(.cold);
                        self.journal.revert_to_snapshot(snapshot_id);
                        try self.database.revert_to_snapshot(db_snapshot_id);
                        // A CALLCODE the sender cannot fund never starts: its gas returns.
                        return CallResult.failed(params.gas);
                    }
                }
            }

            // CALLCODE runs the code at `to` in the caller's context. The EIP-7702
            // delegation of `to` is resolved first; when the resolved address is a
            // precompile, that code is the precompile. A failed precompile consumes all
            // of the gas it was given, exactly like CALL.
            const target = try self.database.get_account(params.to.bytes);
            const code_address = config.eips.eip_7702_get_effective_code_address(target, params.to);
            const delegated = !code_address.equals(params.to);
            if (self.executePrecompileAt(code_address, delegated, params.input, params.gas, self.is_static_context(), snapshot_id)) |result| {
                if (!result.success) {
                    self.journal.revert_to_snapshot(snapshot_id);
                    try self.database.revert_to_snapshot(db_snapshot_id);
                }
                return result;
            }

            const code = try self.codeAt(code_address);
            if (code.bytes.len == 0) {
                @branchHint(.unlikely);
                return CallResult.succeeded_empty(params.gas);
            }

            const result = self.execute_frame(
                code,
                params.input,
                params.gas,
                params.caller,
                params.caller,
                params.value,
                self.is_static_context(), // EIP-214: inherit parent static context (CALLCODE)
                snapshot_id,
            ) catch |err| {
                @branchHint(.unlikely);
                self.noteHostFailure(err);
                self.journal.revert_to_snapshot(snapshot_id);
                try self.database.revert_to_snapshot(db_snapshot_id);
                return CallResult.failed(0);
            };

            if (!result.success) {
                @branchHint(.unlikely);
                self.journal.revert_to_snapshot(snapshot_id);
                try self.database.revert_to_snapshot(db_snapshot_id);
            }
            return result;
        }
        /// Execute DELEGATECALL operation (inlined)
        fn executeDelegatecall(self: *Self, params: struct {
            caller: primitives.Address,
            /// The delegating contract, whose address and storage the code runs with.
            context_address: primitives.Address,
            to: primitives.Address,
            input: []const u8,
            gas: u64,
        }) !CallResult {
            const snapshot_id = try self.journal.create_snapshot();
            const db_snapshot_id = try self.database.create_snapshot();

            const preflight = self.performCallPreflight(params.to, params.input, params.gas, self.is_static_context(), snapshot_id) catch |err| {
                @branchHint(.cold);
                log.debug("Delegatecall preflight failed: {}", .{err});
                self.noteHostFailure(err);
                self.journal.revert_to_snapshot(snapshot_id);
                try self.database.revert_to_snapshot(db_snapshot_id);
                return CallResult.failed(0);
            };

            switch (preflight) {
                .precompile_result => |result| {
                    // A failed precompile call is a failed call: its snapshots revert.
                    if (!result.success) {
                        self.journal.revert_to_snapshot(snapshot_id);
                        try self.database.revert_to_snapshot(db_snapshot_id);
                    }
                    return result;
                },
                .empty_account => |gas| {
                    return CallResult.succeeded_empty(gas);
                },
                .execute_with_code => |code| {
                    const current_value = if (self.depth > 0) self.call_stack[self.depth - 1].value else 0;
                    const result = self.execute_frame(
                        code,
                        params.input,
                        params.gas,
                        params.context_address,
                        params.caller,
                        current_value,
                        self.is_static_context(), // EIP-214: inherit parent static context (DELEGATECALL)
                        snapshot_id,
                    ) catch |err| {
                        @branchHint(.cold);
                        self.noteHostFailure(err);
                        self.journal.revert_to_snapshot(snapshot_id);
                        try self.database.revert_to_snapshot(db_snapshot_id);
                        return CallResult.failed(0);
                    };

                    if (!result.success) {
                        @branchHint(.unlikely);
                        self.journal.revert_to_snapshot(snapshot_id);
                        try self.database.revert_to_snapshot(db_snapshot_id);
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

            const preflight = self.performCallPreflight(params.to, params.input, params.gas, true, snapshot_id) catch |err| {
                @branchHint(.cold);
                log.debug("Staticcall preflight failed: {}", .{err});
                self.noteHostFailure(err);
                self.journal.revert_to_snapshot(snapshot_id);
                try self.database.revert_to_snapshot(db_snapshot_id);
                return CallResult.failed(0);
            };

            switch (preflight) {
                .precompile_result => |result| {
                    // A failed precompile call is a failed call: its snapshots revert.
                    if (!result.success) {
                        self.journal.revert_to_snapshot(snapshot_id);
                        try self.database.revert_to_snapshot(db_snapshot_id);
                    }
                    return result;
                },
                .empty_account => |gas| {
                    return CallResult.succeeded_empty(gas);
                },
                .execute_with_code => |code| {
                    const result = self.execute_frame(
                        code,
                        params.input,
                        params.gas,
                        params.to,
                        params.caller,
                        0,
                        true,
                        snapshot_id,
                    ) catch |err| {
                        @branchHint(.cold);
                        self.noteHostFailure(err);
                        self.journal.revert_to_snapshot(snapshot_id);
                        try self.database.revert_to_snapshot(db_snapshot_id);
                        return CallResult.failed(0);
                    };

                    if (!result.success) {
                        self.journal.revert_to_snapshot(snapshot_id);
                        try self.database.revert_to_snapshot(db_snapshot_id);
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
        /// `generic_create`). Returns the nonce that derives the CREATE address, or null
        /// when the creation fails before touching state (insufficient balance, or nonce
        /// at the EIP-2681 limit). The increment is recorded in the caller's snapshot, so
        /// it survives a failed or colliding creation and is undone only if the caller
        /// itself reverts. A creation transaction uses the nonce before `call()`'s
        /// increment and is not incremented again.
        fn beginCreate(self: *Self, caller: primitives.Address, value: u256, is_transaction: bool) !?u64 {
            var account = (try self.database.get_account(caller.bytes)) orelse Account.zero();
            if (is_transaction) {
                if (account.nonce == 0) return error.TransactionNonceNotIncremented;
                return account.nonce - 1;
            }
            if (account.balance < value) return null;
            if (account.nonce == std.math.maxInt(u64)) return null;
            try self.journal.record_nonce_change(self.current_snapshot_id, caller, account.nonce);
            const creation_nonce = account.nonce;
            account.nonce += 1;
            try self.database.set_account(caller.bytes, account);
            return creation_nonce;
        }

        /// True when a contract cannot be created at `address`: the account there has a
        /// nonzero nonce or code (EIP-684), or holds storage (EIP-7610).
        fn createCollides(self: *Self, address: primitives.Address) !bool {
            if (try self.database.get_account(address.bytes)) |existing| {
                if (existing.nonce != 0 or existing.has_code()) return true;
            }
            return try self.database.has_storage(address.bytes);
        }

        /// Execute CREATE operation (inlined)
        fn executeCreate(self: *Self, params: struct {
            caller: primitives.Address,
            value: u256,
            init_code: []const u8,
            gas: u64,
        }) !CallResult {
            const is_transaction = self.takeTransactionCreate(params.caller);
            const GasConstants = primitives.GasConstants;
            // EIP-3860 (Shanghai+): init code costs 2 gas per 32-byte word, on top of CreateGas.
            const init_words_c: u64 = (@as(u64, @intCast(params.init_code.len)) + 31) / 32;
            const initcode_word_cost_c: u64 = if (config.eips.hardfork.isAtLeast(.SHANGHAI)) init_words_c * GasConstants.InitcodeWordGas else 0;
            // A CREATE transaction already paid CreateGas and initcode words as intrinsic gas.
            // An opcode CREATE that cannot pay them fails before the sender nonce moves.
            const create_overhead = if (is_transaction) 0 else GasConstants.CreateGas + initcode_word_cost_c;
            if (params.gas < create_overhead) {
                return CallResult.failed(0);
            }
            const remaining_gas: u64 = params.gas - create_overhead;
            // EIP-150 (Tangerine Whistle+): an opcode creation forwards all but 1/64 of the
            // remaining gas; the caller keeps the rest whatever the creation's outcome.
            const retained: u64 = if (!is_transaction and config.eips.hardfork.isAtLeast(.TANGERINE_WHISTLE)) remaining_gas / 64 else 0;
            const forwarded: u64 = remaining_gas - retained;

            // The address derives from the creator's current nonce; a creation transaction's
            // nonce was already incremented.
            const creator = (try self.database.get_account(params.caller.bytes)) orelse Account.zero();
            if (is_transaction and creator.nonce == 0) return error.TransactionNonceNotIncremented;
            const creation_nonce = if (is_transaction) creator.nonce - 1 else creator.nonce;
            const contract_address = try primitives.Address.getContractAddress(self.getCallArenaAllocator(), params.caller, creation_nonce);
            // execution-specs generic_create: a creation refused for the depth limit, balance
            // or nonce limit returns the gas it would have forwarded; the CREATE charge
            // stays spent.
            if (!is_transaction and self.depth > config.max_call_depth) {
                return CallResult.failed(remaining_gas);
            }
            if ((try self.beginCreate(params.caller, params.value, is_transaction)) == null) {
                return CallResult.failed(remaining_gas);
            }
            // A creation that passes those checks warms its address in the creating frame
            // before the collision check, so it stays warm whatever the outcome.
            try self.access_list.pre_warm_addresses(&.{contract_address});
            const access_mark = self.access_list.checkpoint();

            const snapshot_id = try self.journal.create_snapshot();
            const db_snapshot_id = try self.database.create_snapshot();

            const existed_before = self.database.account_exists(contract_address.bytes);
            if (try self.createCollides(contract_address)) {
                self.journal.revert_to_snapshot(snapshot_id);
                try self.database.revert_to_snapshot(db_snapshot_id);
                return CallResult.failed(retained);
            }
            var result = self.executeCreateInternal(.{
                .caller = params.caller,
                .value = params.value,
                .init_code = params.init_code,
                .gas_left = forwarded,
                .contract_address = contract_address,
                .snapshot_id = snapshot_id,
                .db_snapshot_id = db_snapshot_id,
                .existed_before = existed_before,
            }) catch |err| {
                self.noteHostFailure(err);
                self.journal.revert_to_snapshot(snapshot_id);
                try self.database.revert_to_snapshot(db_snapshot_id);
                self.access_list.revert(access_mark);
                return CallResult.failed(retained);
            };
            if (!result.success) self.access_list.revert(access_mark);

            result.gas_left += retained;
            result.created_address = if (result.success) contract_address else null;
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
                return CallResult.failed(0);
            }
            const remaining_gas: u64 = params.gas - total_overhead;
            // EIP-150 (Tangerine Whistle+): an opcode creation forwards all but 1/64 of the
            // remaining gas; the caller keeps the rest whatever the creation's outcome.
            const retained: u64 = if (!is_transaction and config.eips.hardfork.isAtLeast(.TANGERINE_WHISTLE)) remaining_gas / 64 else 0;
            const forwarded: u64 = remaining_gas - retained;

            const keccak_asm = @import("crypto").keccak_asm;
            var init_code_hash_bytes: [32]u8 = undefined;
            try keccak_asm.keccak256(params.init_code, &init_code_hash_bytes);
            var salt_bytes: [32]u8 = undefined;
            std.mem.writeInt(u256, &salt_bytes, params.salt, .big);
            const contract_address = primitives.Address.getCreate2Address(params.caller, salt_bytes, init_code_hash_bytes);
            // execution-specs generic_create: a creation refused for the depth limit, balance
            // or nonce limit returns the gas it would have forwarded; the CREATE2 charge
            // stays spent.
            if (!is_transaction and self.depth > config.max_call_depth) {
                log.debug("CREATE2: depth exceeded", .{});
                return CallResult.failed(remaining_gas);
            }
            if ((try self.beginCreate(params.caller, params.value, is_transaction)) == null) {
                log.debug("CREATE2: insufficient balance or nonce at its limit", .{});
                return CallResult.failed(remaining_gas);
            }
            // A creation that passes those checks warms its address in the creating frame
            // before the collision check, so it stays warm whatever the outcome.
            try self.access_list.pre_warm_addresses(&.{contract_address});
            const access_mark = self.access_list.checkpoint();

            const snapshot_id = try self.journal.create_snapshot();
            const db_snapshot_id = try self.database.create_snapshot();

            const existed_before = self.database.account_exists(contract_address.bytes);
            if (try self.createCollides(contract_address)) {
                self.journal.revert_to_snapshot(snapshot_id);
                try self.database.revert_to_snapshot(db_snapshot_id);
                return CallResult.failed(retained);
            }

            var result = self.executeCreateInternal(.{
                .caller = params.caller,
                .value = params.value,
                .init_code = params.init_code,
                .gas_left = forwarded,
                .contract_address = contract_address,
                .snapshot_id = snapshot_id,
                .db_snapshot_id = db_snapshot_id,
                .existed_before = existed_before,
            }) catch |err| {
                self.noteHostFailure(err);
                self.journal.revert_to_snapshot(snapshot_id);
                try self.database.revert_to_snapshot(db_snapshot_id);
                self.access_list.revert(access_mark);
                return CallResult.failed(retained);
            };
            if (!result.success) self.access_list.revert(access_mark);

            result.gas_left += retained;
            result.created_address = if (result.success) contract_address else null;
            return result;
        }

        /// A failed result that hands `trace` on to the caller.
        fn failedWithTrace(trace: ?call_result_module.ExecutionTrace) CallResult {
            var failure = CallResult.failed(0);
            failure.trace = trace;
            return failure;
        }

        fn executeCreateInternal(self: *Self, args: struct {
            caller: primitives.Address,
            value: u256,
            init_code: []const u8,
            gas_left: u64,
            contract_address: primitives.Address,
            snapshot_id: Journal.SnapshotIdType,
            db_snapshot_id: u64,
            existed_before: bool,
        }) !CallResult {
            try self.created_contracts.mark_created(args.contract_address);
            // execution-specs process_create_message: from Spurious Dragon (EIP-161) the new
            // account's nonce becomes 1 before the value transfer and init code run, so a
            // CREATE inside the init code derives its address from nonce 1 and leaves 2.
            if (comptime config.eips.hardfork.isAtLeast(.SPURIOUS_DRAGON)) {
                var created = (try self.database.get_account(args.contract_address.bytes)) orelse Account.zero();
                try self.journal.record_nonce_change(args.snapshot_id, args.contract_address, created.nonce);
                created.nonce += 1;
                try self.database.set_account(args.contract_address.bytes, created);
            }
            if (args.value > 0) {
                self.transferWithBalanceChecks(args.caller, args.contract_address, args.value, args.snapshot_id) catch |err| {
                    self.noteHostFailure(err);
                    self.journal.revert_to_snapshot(args.snapshot_id);
                    try self.database.revert_to_snapshot(args.db_snapshot_id);
                    return CallResult.failed(0);
                };
            }
            var result = self.execute_init_code(
                args.init_code,
                args.gas_left,
                args.contract_address,
                args.caller,
                args.value,
                args.snapshot_id,
            ) catch |err| {
                log.debug("execute_init_code failed with error: {}", .{err});
                self.noteHostFailure(err);
                self.journal.revert_to_snapshot(args.snapshot_id);
                try self.database.revert_to_snapshot(args.db_snapshot_id);
                return CallResult.failed(0);
            };
            // The trace of the init code is allocated with `self.allocator`. Every
            // result returned below carries it; an error frees it.
            errdefer if (result.trace) |*trace| trace.deinit();
            if (!result.success) {
                log.debug("Init code execution failed, success=false", .{});
                self.journal.revert_to_snapshot(args.snapshot_id);
                try self.database.revert_to_snapshot(args.db_snapshot_id);
                return result;
            }
            var contract_account = self.database.get_account(args.contract_address.bytes) catch |err| {
                self.noteHostFailure(err);
                self.journal.revert_to_snapshot(args.snapshot_id);
                try self.database.revert_to_snapshot(args.db_snapshot_id);
                return failedWithTrace(result.trace);
            } orelse Account.zero();
            if (!args.existed_before) {
                try self.journal.record_account_created(args.snapshot_id, args.contract_address);
            }
            if (result.output.len > 0) {
                // EIP-3541: Reject new contract code starting with the 0xEF byte
                if (config.eips.eip_3541_should_reject_create_with_ef_bytecode(result.output)) {
                    self.journal.revert_to_snapshot(args.snapshot_id);
                    try self.database.revert_to_snapshot(args.db_snapshot_id);
                    return failedWithTrace(result.trace);
                }
                // EIP-170: reject deployed code exceeding the max code size (Spurious Dragon+;
                // eip_170_max_code_size returns 0xFFFFFF on earlier forks => no limit).
                if (result.output.len > config.eips.eip_170_max_code_size()) {
                    self.journal.revert_to_snapshot(args.snapshot_id);
                    try self.database.revert_to_snapshot(args.db_snapshot_id);
                    return failedWithTrace(result.trace);
                }
                // EIP-2: charge code-deposit gas (200 per byte of deployed code). When the
                // remaining gas cannot cover it, Homestead+ fails the creation; Frontier
                // instead deploys empty code (the account is still created) without charging.
                const deposit_cost: u64 = @as(u64, @intCast(result.output.len)) * primitives.GasConstants.CreateDataGas;
                if (result.gas_left >= deposit_cost) {
                    result.gas_left -= deposit_cost;
                    const stored_hash = self.database.set_code(result.output) catch |err| {
                        self.noteHostFailure(err);
                        self.journal.revert_to_snapshot(args.snapshot_id);
                        try self.database.revert_to_snapshot(args.db_snapshot_id);
                        return failedWithTrace(result.trace);
                    };
                    try self.journal.record_code_change(args.snapshot_id, args.contract_address, contract_account.code_hash);
                    contract_account.code_hash = stored_hash;
                } else if (config.eips.hardfork.isAtLeast(.HOMESTEAD)) {
                    self.journal.revert_to_snapshot(args.snapshot_id);
                    try self.database.revert_to_snapshot(args.db_snapshot_id);
                    return failedWithTrace(result.trace);
                }
            }
            self.database.set_account(args.contract_address.bytes, contract_account) catch |err| {
                self.noteHostFailure(err);
                self.journal.revert_to_snapshot(args.snapshot_id);
                try self.database.revert_to_snapshot(args.db_snapshot_id);
                return failedWithTrace(result.trace);
            };

            // The creation's snapshot stays open: `inner_call` commits it once the
            // result below exists and the caller's return data is stored, so a
            // failure after this point still undoes the deployment.
            var final_result = if (result.output.len > 0)
                try CallResult.success_with_output(self.getCallArenaAllocator(), result.gas_left, result.output)
            else
                CallResult.succeeded_empty(result.gas_left);
            final_result.trace = result.trace;
            return final_result;
        }

        /// The trace of the whole transaction, built when the top-level frame ends. The
        /// tracer accumulates nested frames' steps, so nested frames build none (their
        /// results are consumed by the calling handler and would leak a copy).
        fn topLevelTrace(self: *Self) !?@import("frame/call_result.zig").ExecutionTrace {
            if (self.depth != 1) return null;
            return try convertTracerToExecutionTrace(self.allocator, &self.tracer);
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
                // A step is counted, and freed by the cleanup above, only once it is
                // complete. Until then its parts are freed here.
                const opcode_name = try allocator.dupe(u8, tracer_step.opcode_name);
                errdefer allocator.free(opcode_name);
                const stack = try allocator.dupe(u256, tracer_step.stack_before);
                trace_steps[i] = call_result.TraceStep{
                    .pc = @intCast(tracer_step.pc),
                    .opcode = tracer_step.opcode,
                    .opcode_name = opcode_name,
                    .gas = @intCast(tracer_step.gas_before),
                    .depth = tracer_step.depth,
                    .mem_size = @intCast(tracer_step.memory_size_before),
                    .gas_cost = tracer_step.gas_cost,
                    .stack = stack,
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

        /// Result of analyzing code once: validated bytecode, its dispatch schedule and
        /// the jump table into that schedule. Built in the call arena for one frame, or
        /// owned by the `DispatchCache` and shared by every frame that runs the code.
        const AnalysisError = error{ InvalidOpcode, InvalidJumpDestination, CodeTooLarge, AllocationError };

        const Analysis = struct {
            bytecode: Bytecode,
            schedule: Frame.Dispatch.DispatchSchedule,
            jump_table: Frame.Dispatch.JumpTable,
            allocator: std.mem.Allocator,

            /// Analyze `code`. The result keeps pointing at `code`, which must outlive it.
            fn init(allocator: std.mem.Allocator, code: []const u8, tracer: anytype) AnalysisError!Analysis {
                var bytecode = Bytecode.initWithTracer(allocator, code, tracer) catch |e| {
                    return switch (e) {
                        error.InvalidOpcode => error.InvalidOpcode,
                        error.InvalidJumpDestination => error.InvalidJumpDestination,
                        error.TruncatedPush => error.InvalidOpcode,
                        // Code too long for the configured program counter fails
                        // its call; it is not a failure of the host.
                        error.InitcodeTooLarge => error.CodeTooLarge,
                        error.OutOfMemory => error.AllocationError,
                    };
                };
                errdefer bytecode.deinit();

                var schedule = Frame.Dispatch.DispatchSchedule.init(allocator, bytecode, &Frame.opcode_handlers, tracer) catch |err| {
                    log.warn("DispatchSchedule.init failed: {s} (code_len={}, fusion={})", .{ @errorName(err), code.len, config.enable_fusion });
                    return error.AllocationError;
                };
                errdefer schedule.deinit();

                const jump_table = Frame.Dispatch.createJumpTable(allocator, &schedule) catch |err| {
                    log.warn("createJumpTable failed: {s} (code_len={}, fusion={})", .{ @errorName(err), code.len, config.enable_fusion });
                    return error.AllocationError;
                };

                return .{ .bytecode = bytecode, .schedule = schedule, .jump_table = jump_table, .allocator = allocator };
            }

            fn deinit(self: *Analysis) void {
                if (self.jump_table.entries.len > 0) self.allocator.free(self.jump_table.entries);
                self.schedule.deinit();
                self.bytecode.deinit();
            }
        };

        /// Analyses of deployed code, keyed by code hash.
        ///
        /// A call to a contract whose code hash is cached skips bytecode validation,
        /// schedule construction and jump table construction entirely. Entries are
        /// allocated from the EVM's general allocator, not the call arena, so they
        /// survive across calls and transactions, and each entry owns a copy of its
        /// code so that it stays valid when the database drops the code (a reverted
        /// deployment, a discarded simulation).
        ///
        /// Init code and code without a stored hash (an EIP-7702 designator) are never
        /// cached.
        ///
        /// The cache holds at most `max_entries` analyses and `max_bytes` bytes of
        /// them. A new analysis that does not fit evicts one entry at a time, never
        /// the whole cache, so code that is called again and again stays cached
        /// while other code passes through:
        /// - A hit marks its entry as referenced.
        /// - Eviction probes random slots. A referenced entry loses its mark and is
        ///   spared by that eviction (second chance); an unreferenced entry that no
        ///   frame runs is the victim. When the probes find none, one sweep takes
        ///   the first evictable entry, sparing referenced entries while it can.
        /// - An entry that a running frame uses (`pins != 0`) is never evicted. When
        ///   every entry is in use, the new code is analyzed in the call arena for
        ///   its one frame.
        ///
        /// Random victims matter for code that is called in a cycle longer than the
        /// cache. Evicting in insertion or least-recently-used order then removes
        /// each entry just before its next call, and every call misses. With random
        /// victims most of the cycle stays cached. The generator has a fixed seed:
        /// the cache changes how fast a call runs, never its result.
        pub const DispatchCache = struct {
            pub const max_entries = config.dispatch_cache_entries;
            /// Most bytes of code and analysis the cache keeps.
            pub const max_bytes = config.dispatch_cache_bytes;
            /// Random slots probed for a victim before the sweep.
            const eviction_probes = 16;

            pub const Entry = struct {
                /// Copy of the code the analysis points into.
                code: []const u8,
                analysis: Analysis,
                /// Number of running frames that execute this entry.
                pins: u32,
                /// Hash the entry is stored under.
                hash: [32]u8,
                /// Bytes of code and analysis the entry holds.
                bytes: usize,
                /// Index in `slots`. Null for an analysis that was too large to
                /// cache: `release` destroys it when its last frame ends.
                slot: ?usize,
                /// Set by a hit, cleared when eviction passes the entry over.
                referenced: bool,
                /// Number of the eviction that last cleared `referenced`. That
                /// eviction does not take the entry, however often it probes it.
                spared_by: u64,
            };

            entries: std.AutoHashMapUnmanaged([32]u8, *Entry),
            /// Every cached entry, at the index its `slot` names.
            slots: [max_entries]?*Entry,
            /// Sum of `bytes` over the cached entries.
            bytes: usize,
            /// State of the xorshift64 generator that picks eviction probes.
            random_state: u64,
            allocator: std.mem.Allocator,
            /// Calls served from the cache.
            hits: u64,
            /// Calls that had to analyze their code.
            misses: u64,
            /// Entries removed to make room for another.
            evictions: u64,
            /// Calls of `evictOne`; numbers the evictions for `Entry.spared_by`.
            eviction_attempts: u64,

            pub fn init(allocator: std.mem.Allocator) DispatchCache {
                return .{
                    .entries = .empty,
                    .slots = @splat(null),
                    .bytes = 0,
                    .random_state = 0x9E3779B97F4A7C15,
                    .allocator = allocator,
                    .hits = 0,
                    .misses = 0,
                    .evictions = 0,
                    .eviction_attempts = 0,
                };
            }

            pub fn deinit(self: *DispatchCache) void {
                var it = self.entries.valueIterator();
                while (it.next()) |entry| self.destroyEntry(entry.*);
                self.entries.deinit(self.allocator);
            }

            fn destroyEntry(self: *DispatchCache, entry: *Entry) void {
                entry.analysis.deinit();
                self.allocator.free(entry.code);
                self.allocator.destroy(entry);
            }

            /// Number of cached analyses.
            pub fn count(self: *const DispatchCache) usize {
                return self.entries.count();
            }

            /// True when an analysis is cached under `hash`.
            pub fn contains(self: *const DispatchCache, hash: [32]u8) bool {
                return self.entries.contains(hash);
            }

            fn nextRandom(self: *DispatchCache) u64 {
                var state = self.random_state;
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                self.random_state = state;
                return state;
            }

            /// Remove the cached entry in `index` from the cache and free it.
            fn evictSlot(self: *DispatchCache, index: usize) void {
                const entry = self.slots[index].?;
                self.slots[index] = null;
                self.bytes -= entry.bytes;
                self.evictions += 1;
                const removed = self.entries.remove(entry.hash);
                // Every slot's entry is in the map under its own hash.
                if (!removed) log.warn("Dispatch cache: slot {d} held an entry the map did not", .{index});
                self.destroyEntry(entry);
            }

            /// Evict one entry that no running frame uses. Returns false when every
            /// entry is in use.
            fn evictOne(self: *DispatchCache) bool {
                self.eviction_attempts += 1;
                const attempt = self.eviction_attempts;
                var probe: usize = 0;
                while (probe < eviction_probes) : (probe += 1) {
                    const index: usize = @intCast(self.nextRandom() % max_entries);
                    const entry = self.slots[index] orelse continue;
                    if (entry.pins != 0) continue;
                    if (entry.referenced) {
                        entry.referenced = false;
                        entry.spared_by = attempt;
                        continue;
                    }
                    if (entry.spared_by == attempt) continue;
                    self.evictSlot(index);
                    return true;
                }
                // The probes met only empty, pinned or spared slots. Sweep once for
                // an entry this eviction has not spared, then for any entry that is
                // not in use.
                const first: usize = @intCast(self.nextRandom() % max_entries);
                for ([_]bool{ false, true }) |take_spared| {
                    var offset: usize = 0;
                    while (offset < max_entries) : (offset += 1) {
                        const index = (first + offset) % max_entries;
                        const entry = self.slots[index] orelse continue;
                        if (entry.pins != 0) continue;
                        if (!take_spared and (entry.referenced or entry.spared_by == attempt)) continue;
                        self.evictSlot(index);
                        return true;
                    }
                }
                return false;
            }

            fn freeSlot(self: *const DispatchCache) ?usize {
                for (self.slots, 0..) |slot, index| {
                    if (slot == null) return index;
                }
                return null;
            }

            /// Bytes `analysis` and its copy of the code hold.
            fn analysisBytes(code: []const u8, analysis: *const Analysis) usize {
                return @sizeOf(Entry) + code.len +
                    std.mem.sliceAsBytes(analysis.bytecode.packed_bitmap).len +
                    std.mem.sliceAsBytes(analysis.schedule.items).len +
                    std.mem.sliceAsBytes(analysis.schedule.jumpdests).len +
                    analysis.schedule.push_values_arena.queryCapacity() +
                    std.mem.sliceAsBytes(analysis.jump_table.entries).len;
            }

            /// The pinned analysis of `code`, stored under `hash`: the cached one, or a
            /// new one that is cached now. Null when the code cannot be cached at the
            /// moment (the cache is full of entries in use), in which case the caller
            /// analyzes the code itself. Every non-null result needs one `release`.
            fn acquire(self: *DispatchCache, hash: [32]u8, code: []const u8, tracer: anytype) AnalysisError!?*Entry {
                if (self.entries.get(hash)) |entry| {
                    // The database stores code under its keccak256, so equal hashes mean
                    // equal code. A length mismatch means the hash was not derived from
                    // this code; such code is not served from, or added to, the cache.
                    if (entry.code.len != code.len) return null;
                    entry.pins += 1;
                    entry.referenced = true;
                    self.hits += 1;
                    return entry;
                }
                self.misses += 1;

                // One entry makes room for one entry. Evict before analyzing, so that
                // a cache full of entries in use costs no analysis here.
                if (self.entries.count() >= max_entries and !self.evictOne()) return null;
                const slot = self.freeSlot() orelse return null;

                const entry = self.allocator.create(Entry) catch return error.AllocationError;
                errdefer self.allocator.destroy(entry);
                const owned_code = self.allocator.dupe(u8, code) catch return error.AllocationError;
                errdefer self.allocator.free(owned_code);
                var analysis = try Analysis.init(self.allocator, owned_code, tracer);
                errdefer analysis.deinit();

                const bytes = analysisBytes(owned_code, &analysis);
                entry.* = .{ .code = owned_code, .analysis = analysis, .pins = 1, .hash = hash, .bytes = bytes, .slot = null, .referenced = false, .spared_by = 0 };

                // Keep the cache within its byte budget. An analysis that still does
                // not fit runs its frame uncached and is freed by `release`.
                while (self.bytes + bytes > max_bytes) {
                    if (bytes > max_bytes or !self.evictOne()) return entry;
                }

                self.entries.put(self.allocator, hash, entry) catch return error.AllocationError;
                entry.slot = slot;
                self.slots[slot] = entry;
                self.bytes += bytes;
                return entry;
            }

            /// Unpin an entry returned by `acquire`.
            fn release(self: *DispatchCache, entry: *Entry) void {
                entry.pins -= 1;
                if (entry.pins == 0 and entry.slot == null) self.destroyEntry(entry);
            }
        };

        /// Execute a frame by delegating to Frame.interpret (dispatch-based execution)
        fn execute_frame(
            self: *Self,
            code: Code,
            input: []const u8,
            gas: u64,
            address: primitives.Address,
            caller: primitives.Address,
            value: u256,
            is_static: bool,
            snapshot_id: Journal.SnapshotIdType,
        ) !CallResult {
            log.debug("EVM.execute_frame: Starting frame, code_len={}, gas={}, depth={}", .{ code.bytes.len, gas, self.depth });
            const prev_snapshot = self.current_snapshot_id;
            self.current_snapshot_id = snapshot_id;
            defer self.current_snapshot_id = prev_snapshot;

            // Input is now stored on the frame directly

            self.depth += 1;
            defer if (self.depth > 0) {
                self.depth -= 1;
            };

            self.call_stack[self.depth - 1] = CallStackEntry{ .caller = caller, .value = value, .is_static = is_static };

            // EIP-211: a frame starts with an empty return data buffer.
            self.clear_return_data();

            // Top-level calls are checked in `callImpl`, and a nested frame never gets
            // more gas than its parent holds, so this cast only fails on a broken invariant.
            const gas_cast = std.math.cast(Frame.GasType, gas) orelse return error.GasExceedsFrameCapacity;

            const arena_allocator = self.getCallArenaAllocator();
            // The frame's stack comes from the stack pool, not the arena: see
            // `FrameStackPool`.
            const frame_allocator = self.frameAllocator();
            var frame = try Frame.init(frame_allocator, gas_cast, caller, value, input, @as(*anyopaque, @ptrCast(self)));
            frame.contract_address = address;
            defer frame.deinit(frame_allocator);

            // EIP-2929: Warm the contract address being executed
            try config.eips.warm_contract_for_execution(&self.access_list, address);

            // Note: Size validation is done by caller (execute_init_code checks init code size,
            // execute_call checks runtime code size via bytecode analysis)

            // Deployed code is analyzed once and served from the dispatch cache. A traced
            // run analyzes every frame itself: the tracer follows the analysis as it is
            // built. Init code and code without a stored hash are analyzed per frame too.
            const tracer_ptr = @as(?@TypeOf(&self.tracer), &self.tracer);
            const cached: ?*DispatchCache.Entry = cached: {
                if (comptime tracing_enabled) break :cached null;
                const hash = code.hash orelse break :cached null;
                break :cached try self.dispatch_cache.acquire(hash, code.bytes, tracer_ptr);
            };
            defer if (cached) |entry| self.dispatch_cache.release(entry);

            var frame_analysis: ?Analysis = null;
            defer if (frame_analysis) |*owned| owned.deinit();
            const analysis: *const Analysis = if (cached) |entry| &entry.analysis else uncached: {
                frame_analysis = try Analysis.init(arena_allocator, code.bytes, tracer_ptr);
                break :uncached &frame_analysis.?;
            };
            const code_bytes: []const u8 = if (cached) |entry| entry.code else code.bytes;

            // The trace is allocated with `self.allocator`. Until it is returned inside
            // a result it belongs to this function.
            var execution_trace: ?@import("frame/call_result.zig").ExecutionTrace = null;
            errdefer if (execution_trace) |*trace| trace.deinit();
            const Termination = error{ Stop, Return, SelfDestruct };
            var termination_reason: ?Termination = null;

            frame.interpret(&analysis.schedule, &analysis.jump_table, code_bytes) catch |err| switch (err) {
                error.Stop => termination_reason = error.Stop,
                error.Return => termination_reason = error.Return,
                error.SelfDestruct => termination_reason = error.SelfDestruct,
                error.REVERT => {
                    execution_trace = try self.topLevelTrace();
                    const gas_left: u64 = @intCast(@max(frame.gas_remaining, 0));
                    // Get output from frame
                    const output_data = frame.output_data;
                    const out_copy = if (output_data.len > 0) blk: {
                        const buf = try self.getCallArenaAllocator().alloc(u8, output_data.len);
                        @memcpy(buf, output_data);
                        break :blk buf;
                    } else &[_]u8{};
                    var result = try CallResult.revert_with_data(self.getCallArenaAllocator(), gas_left, out_copy);
                    result.trace = execution_trace;
                    return result;
                },
                else => {
                    // Invalid bytecode and exhausted execution budgets are normal
                    // transaction outcomes, not failures of the client itself.
                    switch (err) {
                        error.InvalidOpcode, error.InvalidJump, error.OutOfGas, error.OutOfBounds, error.StackUnderflow, error.StackOverflow, error.ReturnDataNotAvailable, error.WriteProtection =>
                            log.debug("Frame execution halted: {s} (code_len={}, gas={}, depth={})", .{ @errorName(err), code_bytes.len, gas, self.depth }),
                        else => log.warn("Frame execution failed with error: {s} (code_len={}, gas={}, depth={})", .{ @errorName(err), code_bytes.len, gas, self.depth }),
                    }
                    // A halted frame still reports the trace up to the halt.
                    execution_trace = try self.topLevelTrace();
                    var failure = CallResult.failed(0);
                    failure.trace = execution_trace;
                    return failure;
                },
            };

            execution_trace = try self.topLevelTrace();

            const gas_left: u64 = @intCast(@max(frame.gas_remaining, 0));
            // Get output from frame (set by RETURN/REVERT handlers)
            const output_data = frame.output_data;

            var result: CallResult = undefined;
            if (termination_reason) |reason| {
                switch (reason) {
                    error.Stop => {
                        result = try CallResult.success_with_output(self.getCallArenaAllocator(), gas_left, &.{});
                    },
                    error.Return => {
                        result = try CallResult.success_with_output(self.getCallArenaAllocator(), gas_left, output_data);
                    },
                    error.SelfDestruct => {
                        result = try CallResult.success_with_output(self.getCallArenaAllocator(), gas_left, &.{});
                    },
                }
            } else {
                result = try CallResult.success_with_output(self.getCallArenaAllocator(), gas_left, output_data);
            }
            result.trace = execution_trace;
            return result;
        }

        fn execute_init_code(
            self: *Self,
            code: []const u8,
            gas: u64,
            address: primitives.Address,
            caller: primitives.Address,
            value: u256,
            snapshot_id: Journal.SnapshotIdType,
        ) !CallResult {
            // EIP-3860 (Shanghai+) caps init code at 49152 bytes. An opcode creation over
            // the cap halts its caller before reaching this point and an oversized
            // creation transaction is invalid, so this is the last line of defense.
            // Earlier forks have no init code limit.
            if (comptime config.eips.hardfork.isAtLeast(.SHANGHAI)) {
                if (code.len > primitives.GasConstants.MaxInitcodeSize) {
                    log.debug("Init code too large: {} > {}", .{ code.len, primitives.GasConstants.MaxInitcodeSize });
                    return CallResult.failed(0);
                }
            }
            const result = self.execute_frame(
                .{ .bytes = code, .hash = null },
                &.{},
                gas,
                address,
                caller,
                value,
                false,
                snapshot_id,
            ) catch |err| {
                log.debug("execute_frame failed with error: {}", .{err});
                return err;
            };
            return result;
        }

        /// The host failure behind a standard precompile's error, or null when the
        /// precompile rejected its input or its gas.
        ///
        /// - `OutOfMemory`: the host ran out of memory.
        /// - `TrustedSetupNotLoaded`: the host unloaded the KZG setup after
        ///   `executePrecompileInline` checked it, while the precompile ran.
        /// - `ExecutionError`: the BLS12-381 backend failed (a caught panic or a
        ///   failed allocation, FFI code 4). No standard precompile reports a
        ///   rejected input with this error.
        pub fn precompileHostFailure(err: anyerror) ?anyerror {
            return switch (err) {
                error.OutOfMemory, error.TrustedSetupNotLoaded => err,
                error.ExecutionError => error.PrecompileBackendFailure,
                else => null,
            };
        }

        /// Execute a precompile call (inlined)
        fn executePrecompileInline(self: *Self, address: primitives.Address, input: []const u8, gas: u64, is_static: bool, snapshot_id: Journal.SnapshotIdType) !CallResult {
            _ = snapshot_id;
            _ = is_static;
            if (!precompiles.isPrecompile(address, config.eips.hardfork)) return CallResult.failed(0);

            // Without the trusted setup the point evaluation precompile cannot tell a
            // valid proof from an invalid one. That is the host's failure, never an
            // invalid input: `init` loads the setup, so it is missing only when the
            // host unloaded it or the target cannot load it.
            if (comptime config.eips.hardfork.isAtLeast(.CANCUN)) {
                if (address.equals(precompiles.POINT_EVALUATION_ADDRESS) and !kzg_setup.isInitialized()) {
                    return error.TrustedSetupNotLoaded;
                }
            }

            const result = precompiles.execute(self.getCallArenaAllocator(), address, input, gas, config.eips.hardfork) catch |err| {
                if (precompileHostFailure(err)) |failure| return failure;
                // Every other error is the precompile rejecting its input or its
                // gas: the call fails and consumes all of its gas.
                return CallResult.failed(0);
            };

            // A precompile that reports using more gas than it was given has failed.
            if (result.gas_used > gas) return CallResult.failed(0);

            // Convert PrecompileResult to CallResult
            // Success is indicated by execute() not returning an error
            return CallResult{
                .success = true,
                .gas_left = gas - result.gas_used,
                .output = result.output,
            };
        }

        /// Get account balance
        pub fn get_balance(self: *Self, address: primitives.Address) u256 {
            if (config.disable_balance_checks) return 0;
            const account = self.database.find_account(address.bytes) orelse return 0;
            return account.balance;
        }

        /// Check if account exists
        pub fn account_exists(self: *Self, address: primitives.Address) bool {
            return self.database.account_exists(address.bytes);
        }

        /// Get account code as EXTCODESIZE, EXTCODECOPY and EXTCODEHASH see it. A
        /// delegated EOA (EIP-7702) reports its 23-byte delegation designator.
        pub fn get_code(self: *Self, address: primitives.Address) ![]const u8 {
            return (try self.codeAt(address)).bytes;
        }

        /// The code stored at `address`, without following delegation. A delegated EOA
        /// (EIP-7702) has the designator `0xef0100 || delegate` as its code. An account
        /// that does not exist has empty code: calling it succeeds and EXTCODE* see nothing.
        fn codeAt(self: *Self, address: primitives.Address) !Code {
            const account = (try self.database.get_account(address.bytes)) orelse return .{ .bytes = &.{}, .hash = null };
            if (account.get_effective_code_address()) |delegate| {
                const designator = try self.getCallArenaAllocator().alloc(u8, eips.DELEGATION_DESIGNATOR_LENGTH);
                @memcpy(designator[0..3], &eips.DELEGATION_PREFIX);
                @memcpy(designator[3..], &delegate.bytes);
                return .{ .bytes = designator, .hash = null };
            }
            if (!Account.is_code_hash_present(account.code_hash)) {
                return .{ .bytes = &.{}, .hash = null };
            }
            return .{ .bytes = try self.database.get_code(account.code_hash), .hash = account.code_hash };
        }

        /// Get block information
        pub fn get_block_info(self: *Self) BlockInfo {
            return self.block_info;
        }

        /// Emit log event
        pub fn emit_log(self: *Self, contract_address: primitives.Address, topics: []const u256, data: []const u8) error{OutOfMemory}!void {
            return self.noting(self.emitLogUnnoted(contract_address, topics, data));
        }

        fn emitLogUnnoted(self: *Self, contract_address: primitives.Address, topics: []const u256, data: []const u8) error{OutOfMemory}!void {
            // EIP-214: Prevent log emission in static context
            if (!eips.Eips.is_log_emission_allowed(self.is_static_context())) return;

            // Topics and data live in the call arena, like the logs of LOG0-LOG4.
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
            return self.noting(self.registerCreatedContractUnnoted(address));
        }

        fn registerCreatedContractUnnoted(self: *Self, address: primitives.Address) !void {
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

        /// Record `address` as touched by a call, for the state dump.
        fn touchAddress(self: *Self, address: primitives.Address) !void {
            const entry = try self.touched_addresses.getOrPut(address);
            if (entry.found_existing) return;
            self.transaction_touched.append(self.allocator, address) catch |err| {
                _ = self.touched_addresses.remove(address);
                return err;
            };
        }

        /// Record `slot` of `address` as touched by a call.
        fn touchStorageSlot(self: *Self, address: primitives.Address, slot: u256) !void {
            const entry = try self.touched_storage.getOrPut(address);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.put(self.allocator, slot, {});
        }

        /// Forget every address and storage slot that calls have touched so far.
        /// Addresses a host added to `touched_addresses` itself (the C API does, for
        /// state it sets up) are kept. No call does this on its own: the touched sets
        /// accumulate so that `dumpState` covers everything run on this EVM.
        pub fn resetTouched(self: *Self) void {
            for (self.transaction_touched.items) |address| _ = self.touched_addresses.remove(address);
            self.transaction_touched.clearRetainingCapacity();
            self.clearTouchedStorage();
        }

        /// Free every touched-slot set and empty the map.
        fn clearTouchedStorage(self: *Self) void {
            var it = self.touched_storage.valueIterator();
            while (it.next()) |slots| slots.deinit(self.allocator);
            self.touched_storage.clearRetainingCapacity();
        }

        /// Record a storage change in the journal
        pub fn record_storage_change(self: *Self, address: primitives.Address, slot: u256, original_value: u256) !void {
            return self.noting(self.recordStorageChangeUnnoted(address, slot, original_value));
        }

        fn recordStorageChangeUnnoted(self: *Self, address: primitives.Address, slot: u256, original_value: u256) !void {
            try self.journal.record_storage_change(self.current_snapshot_id, address, slot, original_value);
            // Track address and slot for state dump
            try self.touchAddress(address);
            try self.touchStorageSlot(address, slot);
        }

        /// Get the original storage value from the journal
        pub fn get_original_storage(self: *Self, address: primitives.Address, slot: u256) ?u256 {
            return self.journal.get_original_storage(address, slot);
        }

        /// Mark `address` warm if it is a precompile in the configured fork.
        fn warmPrecompile(self: *Self, address: primitives.Address) !void {
            if (!precompiles.isPrecompile(address, config.eips.hardfork)) return;
            try self.access_list.pre_warm_addresses(&[_]primitives.Address{address});
        }

        /// EIP-7702 (Prague+): when the transaction's target is a delegated EOA, its
        /// delegate starts the transaction warm. `call` does this itself. A host
        /// that drives `inner_call` directly calls it after applying the
        /// transaction's authorization list, which can change the delegation.
        pub fn warmDelegatedTarget(self: *Self, target: ?primitives.Address) !void {
            if (comptime !config.eips.hardfork.isAtLeast(.PRAGUE)) return;
            const address = target orelse return;
            const account = (try self.database.get_account(address.bytes)) orelse return;
            const delegate = account.get_effective_code_address() orelse return;
            try self.access_list.pre_warm_addresses(&[_]primitives.Address{delegate});
        }

        /// Access an address and return the gas cost (EIP-2929)
        pub fn access_address(self: *Self, address: primitives.Address) !u64 {
            return self.noting(self.accessAddressUnnoted(address));
        }

        fn accessAddressUnnoted(self: *Self, address: primitives.Address) !u64 {
            const cost = try self.access_list.access_address(address);
            // Track address for state dump
            try self.touchAddress(address);
            // Before Berlin (EIP-2929) there is no cold surcharge: every access costs the
            // opcode's flat static price. Reporting the warm cost makes callers charge
            // no surcharge.
            if (comptime !config.eips.hardfork.isAtLeast(.BERLIN)) return primitives.GasConstants.WarmStorageReadCost;
            return cost;
        }

        /// Access a storage slot and return the gas cost (EIP-2929)
        pub fn access_storage_slot(self: *Self, contract_address: primitives.Address, slot: u256) !u64 {
            return self.noting(self.accessStorageSlotUnnoted(contract_address, slot));
        }

        fn accessStorageSlotUnnoted(self: *Self, contract_address: primitives.Address, slot: u256) !u64 {
            const cost = try self.access_list.access_storage_slot(contract_address, slot);
            // Track address and slot for state dump
            try self.touchAddress(contract_address);
            try self.touchStorageSlot(contract_address, slot);
            // Before Berlin (EIP-2929) there is no cold surcharge.
            if (comptime !config.eips.hardfork.isAtLeast(.BERLIN)) return primitives.GasConstants.WarmStorageReadCost;
            return cost;
        }

        /// Delete every account the transaction destroyed, with its storage. The
        /// cost is the number of slots those accounts hold, not the size of the state.
        fn finalizeDestructions(self: *Self) !void {
            var destructions = self.self_destruct.iterator();
            while (destructions.next()) |entry| try self.database.delete_account(entry.key_ptr.bytes);
        }

        /// Mark a contract for destruction
        pub fn mark_for_destruction(self: *Self, contract_address: primitives.Address, recipient: primitives.Address) !void {
            return self.noting(self.markForDestructionUnnoted(contract_address, recipient));
        }

        fn markForDestructionUnnoted(self: *Self, contract_address: primitives.Address, recipient: primitives.Address) !void {
            // EIP-214: Prevent self-destruction in static context
            if (self.is_static_context()) return error.StaticCallViolation;

            // EIP-6780: Handle SELFDESTRUCT based on creation in same transaction
            const created_in_tx = self.created_contracts.was_created_in_tx(contract_address);
            // Before EIP-161 (Spurious Dragon) crediting the beneficiary creates its account,
            // even when there is nothing to credit; the empty account then persists.
            if (comptime !config.eips.hardfork.isAtLeast(.SPURIOUS_DRAGON)) {
                if ((try self.database.get_account(recipient.bytes)) == null) {
                    try self.database.set_account(recipient.bytes, Account.zero());
                }
            }
            if (created_in_tx or !config.eips.hardfork.isAtLeast(.CANCUN)) {
                const balance = try self.database.get_balance(contract_address.bytes);
                if (contract_address.equals(recipient)) {
                    try self.journal.record_balance_change(self.current_snapshot_id, contract_address, balance);
                    try self.database.set_balance(contract_address.bytes, 0);
                } else if (balance > 0) {
                    try self.transferWithBalanceChecks(contract_address, recipient, balance, self.current_snapshot_id);
                }
                try self.self_destruct.mark_for_destruction(contract_address, recipient);
                return;
            }
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
        pub fn get_storage(self: *Self, address: primitives.Address, slot: u256) u256 {
            return self.database.read_storage(address.bytes, slot);
        }

        /// Set storage value
        pub fn set_storage(self: *Self, address: primitives.Address, slot: u256, value: u256) !void {
            return self.noting(self.setStorageUnnoted(address, slot, value));
        }

        fn setStorageUnnoted(self: *Self, address: primitives.Address, slot: u256, value: u256) !void {
            // In static context, storage writes are not allowed per EIP-214
            // This check is critical for security and cannot be removed
            if (self.is_static_context()) return error.StaticCallViolation;
            const original_value = self.get_storage(address, slot);
            try self.record_storage_change(address, slot, original_value);
            try self.database.set_storage(address.bytes, slot, value);
        }

        /// Get transaction gas price
        pub fn get_gas_price(self: *Self) u256 {
            return self.gas_price;
        }

        /// Get return data from last call (returns null if no return data available)
        pub fn get_return_data(self: *const Self) ?[]const u8 {
            return self.return_data;
        }

        /// Set return data from a call, reusing buffer when possible
        /// This takes ownership of the data and will free any existing return_data
        pub fn set_return_data(self: *Self, data: []const u8) !void {
            return self.noting(self.setReturnDataUnnoted(data));
        }

        fn setReturnDataUnnoted(self: *Self, data: []const u8) !void {
            if (data.len == 0) {
                // For empty data, just clear
                self.clear_return_data();
                return;
            }

            if (self.return_data) |existing| {
                if (existing.ptr == data.ptr and existing.len == data.len) return;
                if (existing.len == data.len) {
                    // Same size: reuse the buffer. `data` may alias it, so move, not copy.
                    std.mem.copyForwards(u8, @constCast(existing), data);
                    return;
                }
            }

            // Copy first: `data` may point into the buffer being replaced.
            const new_buf = self.allocator.alloc(u8, data.len) catch return error.AllocationError;
            @memcpy(new_buf, data);
            if (self.return_data) |existing| self.allocator.free(existing);
            self.return_data = new_buf;
        }

        /// Clear return data buffer (for CREATE/CREATE2 per EIP-211)
        pub fn clear_return_data(self: *Self) void {
            if (self.return_data) |data| {
                self.allocator.free(data);
            }
            self.return_data = null;
        }

        /// Check if returndata should be cleared after CREATE/CREATE2 (EIP-211)
        pub fn should_clear_returndata_on_create(_: *Self) bool {
            return config.eips.eip_211_should_clear_returndata_on_create();
        }

        /// Get chain ID
        pub fn get_chain_id(self: *Self) u64 {
            return self.block_info.chain_id;
        }
        /// BLOCKHASH: the hash of one of the 256 blocks before the current block, read
        /// from `block_info.block_hashes`. EIP-2935 leaves the opcode unchanged, so it
        /// never reads the history contract.
        pub fn get_block_hash(self: *Self, block_number: u64) ?[32]u8 {
            return block_info_mod.recentBlockHash(self.block_info.block_hashes, self.block_info.number, block_number);
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
        .prev_randao = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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
    const sender = primitives.Address{ .bytes = [_]u8{0x02} ++ @as([19]u8, @splat(0x00)) };
    const target = primitives.Address{ .bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0x00)) };
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = @as([32]u8, @splat(0)),
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
    const sender = primitives.Address{ .bytes = [_]u8{0x02} ++ @as([19]u8, @splat(0x00)) };
    const target = primitives.Address{ .bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0x00)) };
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 0,
        .gas_limit = 60_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = @as([32]u8, @splat(0)),
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
    const sender = primitives.Address{ .bytes = [_]u8{0x02} ++ @as([19]u8, @splat(0x00)) };
    const target = primitives.Address{ .bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0x00)) };
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 0,
        .gas_limit = 60_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = @as([32]u8, @splat(0)),
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
    const sender = primitives.Address{ .bytes = [_]u8{0x02} ++ @as([19]u8, @splat(0x00)) };
    const target = primitives.Address{ .bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0x00)) };
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 0,
        .gas_limit = 60_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // `depth` counts active frames. With 1025 active frames the caller runs at
    // 0-based depth 1024, the deepest allowed, and cannot call further.
    evm.depth = 1025;

    const result = evm.inner_call(Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 1000000,
        },
    });

    // A call refused for depth hands back all the gas it was given.
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 1000000), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);

    // One level shallower the call is allowed (here: to an account without code).
    evm.depth = 1024;
    const allowed = evm.inner_call(Evm(.{}).CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 1000000,
        },
    });
    try std.testing.expect(allowed.success);
    try std.testing.expectEqual(@as(u64, 1000000), allowed.gas_left);
    evm.depth = 0;
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
        .prev_randao = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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
    const code_hash = @as([32]u8, @splat(0xAB));

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
        .prev_randao = @as([32]u8, @splat(0)),
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
    try std.testing.expectEqual(@as(u64, 137), context.chain_id);
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
        .prev_randao = @as([32]u8, @splat(0xAB)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    };
    try db.set_account(address.bytes, account);

    const retrieved_balance = evm.get_balance(address);
    try std.testing.expectEqual(balance, retrieved_balance);

    const zero_address: primitives.Address = .{ .bytes = [_]u8{1} ++ @as([19]u8, @splat(0)) };
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
        .prev_randao = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    };
    try db.set_account(address.bytes, account);

    const exists = evm.account_exists(address);
    try std.testing.expect(exists);

    const non_existing: primitives.Address = .{ .bytes = [_]u8{1} ++ @as([19]u8, @splat(0)) };
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
        .prev_randao = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Set up caller with balance
    const caller_address: primitives.Address = .{ .bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0)) };
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Set up caller with balance
    const caller_address: primitives.Address = .{ .bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0)) };
    const initial_balance: u256 = 1000000;
    const transfer_value: u256 = 12345;
    const caller_account = Account{
        .balance = initial_balance,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const caller_address: primitives.Address = .{ .bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0)) };
    const caller_account = Account{
        .balance = 100,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const caller_address: primitives.Address = .{ .bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0)) };
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
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
    const expected_address = primitives.Address.getCreate2Address(caller_address, salt_bytes, init_code_hash);

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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const caller_address: primitives.Address = .{ .bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0)) };
    const init_code = [_]u8{ 0x00, 0x00, 0xF3 }; // STOP STOP RETURN
    const salt: u256 = 0xDEADBEEF;

    // Calculate expected address
    const keccak_asm = @import("crypto").keccak_asm;
    var init_code_hash: [32]u8 = undefined;
    try keccak_asm.keccak256(&init_code, &init_code_hash);
    const salt_bytes = @as([32]u8, @bitCast(salt));
    const expected_address = primitives.Address.getCreate2Address(caller_address, salt_bytes, init_code_hash);

    // Create caller account
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const caller_address: primitives.Address = .{ .bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0)) };

    // Calculate what the contract address will be
    const expected_address = try primitives.Address.getContractAddress(std.testing.allocator, caller_address, 0);

    // Pre-create an account at that address with code
    const existing_code = [_]u8{ 0x60, 0x00 }; // PUSH1 0
    const code_hash = try db.set_code(&existing_code);
    const existing_account = Account{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    };
    try db.set_account(expected_address.bytes, existing_account);

    // Create caller account
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const caller_address: primitives.Address = .{ .bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0)) };
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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

    const factory_address: primitives.Address = .{ .bytes = [_]u8{0x02} ++ @as([19]u8, @splat(0)) };
    const code_hash = try db.set_code(&factory_bytecode);
    try db.set_account(factory_address.bytes, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    });

    const caller_address: primitives.Address = .{ .bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0)) };
    try db.set_account(caller_address.bytes, Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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
    const taken_logs = try evm.takeLogs();
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
        .prev_randao = @as([32]u8, @splat(0)),
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

    const contract_address: primitives.Address = .{ .bytes = [_]u8{0x12} ++ @as([19]u8, @splat(0)) };
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
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
        .prev_randao = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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

    // `depth` counts active frames: a frame at 0-based depth d runs with depth d + 1
    // and may call while d < max_call_depth. With max_call_depth = 3, callers at
    // depth 1, 2 and 3 may call.
    evm.depth = 3;
    const result1 = evm.inner_call(call_params);
    try std.testing.expect(result1.success);
    try std.testing.expectEqual(@as(u11, 3), evm.depth); // Should restore depth

    // A caller already at 0-based depth 3 (4 active frames) may not, and gets the
    // call's gas back.
    evm.depth = 4;
    const result2 = evm.inner_call(call_params);
    try std.testing.expect(!result2.success);
    try std.testing.expectEqual(@as(u64, 100000), result2.gas_left);
    evm.depth = 0;
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test calling ECRECOVER precompile (address 0x01)
    const ecrecover_address = @as([19]u8, @splat(0)) ++ [_]u8{1}; // 0x0000...0001
    const input_data = @as([128]u8, @splat(0)); // Invalid ECRECOVER input (all zeros)

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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .chain_id = 1,
    };

    // Test non-tracing mode first (this is where the critical bug is)
    {
        var vm = try Evm(.{}).init(allocator, &db, block_info, tx_context, 0, primitives.Address.ZERO_ADDRESS);
        defer vm.deinit();

        const contract_addr = primitives.Address{ .bytes = @as([20]u8, @splat(0x12)) };

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
            .storage_root = @as([32]u8, @splat(0)),
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
        const TracingEvm = Evm(.{});
        var vm = try TracingEvm.init(allocator, &db, block_info, tx_context, 0, primitives.Address.ZERO_ADDRESS);
        defer vm.deinit();

        const contract_addr = primitives.Address{ .bytes = @as([20]u8, @splat(0x13)) };

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
            .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var vm = try Evm(.{}).init(allocator, &db, block_info, tx_context, 0, primitives.Address.ZERO_ADDRESS);
    defer vm.deinit();

    const contract_addr = primitives.Address{ .bytes = @as([20]u8, @splat(0x14)) };

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
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test IDENTITY precompile - should return input data unchanged
    const identity_address = @as([19]u8, @splat(0)) ++ [_]u8{4}; // 0x0000...0004
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test SHA256 precompile
    const sha256_address = @as([19]u8, @splat(0)) ++ [_]u8{2}; // 0x0000...0002
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try NoPrecompileEvm.init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Try to call IDENTITY precompile - should be treated as regular call
    const identity_address = @as([19]u8, @splat(0)) ++ [_]u8{4}; // 0x0000...0004
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test invalid precompile address (0x0B - beyond supported range)
    const invalid_address = @as([19]u8, @splat(0)) ++ [_]u8{11}; // 0x0000...000B

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
        .prev_randao = @as([32]u8, @splat(0)),
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
    const deploy_address: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{1} };
    const code_hash = try db.set_code(&loop_bytecode);
    try db.set_account(deploy_address.bytes, Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    });

    // Test 1: Very low gas limit - should fail quickly
    {
        const result = evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = deploy_address,
                .value = 0,
                .input = &.{},
                .gas = 100, // Very low gas
            },
        });

        try std.testing.expect(!result.success); // Should fail
        try std.testing.expectEqual(@as(u64, 0), result.gas_left); // All gas consumed
    }

    // Test 2: Medium gas limit
    {
        const result = evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = deploy_address,
                .value = 0,
                .input = &.{},
                .gas = 10000,
            },
        });

        try std.testing.expect(!result.success); // Should still fail (infinite loop)
        try std.testing.expectEqual(@as(u64, 0), result.gas_left);
    }

    // Test 3: High gas limit
    {
        const result = evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = deploy_address,
                .value = 0,
                .input = &.{},
                .gas = 1000000,
            },
        });

        try std.testing.expect(!result.success); // Should fail after consuming all gas
        try std.testing.expectEqual(@as(u64, 0), result.gas_left);
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
        .prev_randao = @as([32]u8, @splat(0)),
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
        const empty_address: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{99} };
        const result = evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = empty_address,
                .value = 0,
                .input = &.{},
                .gas = 100000,
            },
        });

        try std.testing.expect(result.success); // Empty contract succeeds immediately
        try std.testing.expectEqual(@as(u64, 100000), result.gas_left); // No gas consumed
    }

    // Test 2: Simple contract that returns immediately (STOP opcode)
    {
        const stop_bytecode = [_]u8{0x00}; // STOP
        const stop_address: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{2} };
        const code_hash = try db.set_code(&stop_bytecode);
        try db.set_account(stop_address.bytes, Account{
            .nonce = 0,
            .balance = 0,
            .code_hash = code_hash,
            .storage_root = @as([32]u8, @splat(0)),
        });

        const result = evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = stop_address,
                .value = 0,
                .input = &.{},
                .gas = 100000,
            },
        });

        try std.testing.expect(result.success);
        // STOP should consume minimal gas
        const gas_used = 100000 - result.gas_left;
        try std.testing.expect(gas_used < 100); // Should use very little gas
    }

    // Test 3: Contract with some computation
    {
        // PUSH1 0x05, PUSH1 0x03, ADD, PUSH1 0x00, MSTORE, STOP
        // Adds 3 + 5 and stores in memory
        const add_bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01, 0x60, 0x00, 0x52, 0x00 };
        const add_address: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{3} };
        const code_hash = try db.set_code(&add_bytecode);
        try db.set_account(add_address.bytes, Account{
            .nonce = 0,
            .balance = 0,
            .code_hash = code_hash,
            .storage_root = @as([32]u8, @splat(0)),
        });

        const result = evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = add_address,
                .value = 0,
                .input = &.{},
                .gas = 100000,
            },
        });

        try std.testing.expect(result.success);
        const gas_used = 100000 - result.gas_left;
        try std.testing.expect(gas_used > 0); // Should use some gas
        try std.testing.expect(gas_used < 1000); // But not too much
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 21000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Create a large contract that does simple operations
    var large_bytecode = std.ArrayList(u8).empty;
    defer large_bytecode.deinit(std.testing.allocator);

    // Add many PUSH1/POP pairs (each costs gas but doesn't loop)
    for (0..1000) |_| {
        try large_bytecode.append(std.testing.allocator, 0x60); // PUSH1
        try large_bytecode.append(std.testing.allocator, 0x42); // value
        try large_bytecode.append(std.testing.allocator, 0x50); // POP
    }
    try large_bytecode.append(std.testing.allocator, 0x00); // STOP

    const large_address: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{4} };
    const code_hash = try db.set_code(large_bytecode.items);
    try db.set_account(large_address.bytes, Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    });

    // Test with different gas limits
    const gas_limits = [_]u64{ 10000, 50000, 100000, 500000 };

    for (gas_limits) |gas_limit| {
        const result = evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = large_address,
                .value = 0,
                .input = &.{},
                .gas = gas_limit,
            },
        });

        _ = gas_limit - result.gas_left; // gas_used

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
        .prev_randao = @as([32]u8, @splat(0)),
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
    const invalid_address: primitives.Address = .{ .bytes = @as([20]u8, @splat(0xFF)) };
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
        .prev_randao = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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
    const deploy_address: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{1} }; // Address 0x000...001

    // Store contract code in database
    const code_hash = try db.set_code(&test_bytecode);
    try db.set_account(deploy_address.bytes, Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 21000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test calling IDENTITY precompile (0x04) - should return input as-is
    const precompile_address: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{4} }; // Address 0x000...004
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 21000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test calling SHA256 precompile (0x02)
    const precompile_address: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{2} }; // Address 0x000...002
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 21_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test ECRECOVER with invalid signature (all zeros)
    const precompile_address: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{1} };
    const input_data = @as([128]u8, @splat(0)); // Invalid signature

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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 21_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const precompile_address: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{3} };
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 21_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const precompile_address: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{5} };

    // 3^4 mod 5 = 81 mod 5 = 1
    var input: [99]u8 = @as([99]u8, @splat(0));
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 21_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Test ECADD (0x06)
    const ecadd_address: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{6} };
    const ecadd_input = @as([128]u8, @splat(0)); // Two zero points

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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 21_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const precompile_address: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{9} };
    const input = @as([213]u8, @splat(0)); // Valid BLAKE2F input length

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
    const deploy_address: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{1} };
    const code_hash = try db.set_code(&stop_bytecode);
    try db.set_account(deploy_address.bytes, Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    });

    // Create EVM instance
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = @as([32]u8, @splat(0)),
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
            .prev_randao = @as([32]u8, @splat(0)),
        },
        TransactionContext{
            .gas_limit = 10_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .chain_id = 1,
        },
        20_000_000_000,
        .{ .bytes = @as([20]u8, @splat(0x01)) },
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
            .caller = .{ .bytes = @as([20]u8, @splat(0x01)) },
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
            .caller = .{ .bytes = @as([20]u8, @splat(0x01)) },
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
            .prev_randao = @as([32]u8, @splat(0)),
        },
        TransactionContext{
            .gas_limit = 10_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .chain_id = 1,
        },
        20_000_000_000,
        .{ .bytes = @as([20]u8, @splat(0x01)) },
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
    const init_value = @as([31]u8, @splat(0)) ++ [_]u8{123}; // 123 as uint256
    try deploy_data.appendSlice(&init_value);

    const factory_result = evm_instance.call(.{
        .create = .{
            .caller = .{ .bytes = @as([20]u8, @splat(0x01)) },
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
            .caller = .{ .bytes = @as([20]u8, @splat(0x01)) },
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
            .prev_randao = @as([32]u8, @splat(0)),
        },
        TransactionContext{
            .gas_limit = 20_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .chain_id = 1,
        },
        20_000_000_000,
        .{ .bytes = @as([20]u8, @splat(0x01)) },
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
            .caller = .{ .bytes = @as([20]u8, @splat(0x01)) },
            .value = 0,
            .init_code = level1_code.items,
            .gas = 10_000_000,
        },
    });
    defer if (result1.output.len > 0) allocator.free(result1.output);

    try std.testing.expect(result1.success);

    // Get level 2 address from storage
    const level2_addr_u256 = evm_instance.get_storage(.{ .bytes = @as([20]u8, @splat(0x01)) }, 0);
    var level2_addr: primitives.Address = undefined;
    const bytes = std.mem.toBytes(level2_addr_u256);
    @memcpy(&level2_addr.bytes, bytes[12..32]);

    // Call level 2 to get level 3 address
    const result2 = evm_instance.call(.{
        .call = .{
            .caller = .{ .bytes = @as([20]u8, @splat(0x01)) },
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
            .caller = .{ .bytes = @as([20]u8, @splat(0x01)) },
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
            .prev_randao = @as([32]u8, @splat(0)),
        },
        TransactionContext{
            .gas_limit = 10_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .chain_id = 1,
        },
        20_000_000_000,
        primitives.Address{ .bytes = @as([20]u8, @splat(0x01)) },
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
            .caller = .{ .bytes = @as([20]u8, @splat(0x01)) },
            .value = 0,
            .init_code = parent_code.items,
            .gas = 5_000_000,
        },
    });
    defer if (deploy_result.output.len > 0) allocator.free(deploy_result.output);

    try std.testing.expect(deploy_result.success);

    // Get parent address (deterministic based on sender nonce)
    const parent_addr: primitives.Address = .{ .bytes = @as([20]u8, @splat(0x01)) }; // Simplified for test

    // Get child address from parent's storage
    const child_addr_u256 = evm_instance.get_storage(parent_addr, 1);
    var child_addr: primitives.Address = undefined;
    const bytes = std.mem.toBytes(child_addr_u256);
    @memcpy(&child_addr.bytes, bytes[12..32]);

    // Verify parent's value storage is initially 0
    const initial_value = evm_instance.get_storage(parent_addr, 0);
    try std.testing.expectEqual(@as(u256, 0), initial_value);

    // Call child contract, which should call back to parent
    const call_result = evm_instance.call(.{
        .call = .{
            .caller = .{ .bytes = @as([20]u8, @splat(0x02)) },
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
        .prev_randao = @as([32]u8, @splat(0)),
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
    const contract_addr: primitives.Address = .{ .bytes = @as([20]u8, @splat(0x01)) };
    const code_hash = try db.set_code(&bytecode);
    try db.set_account(contract_addr.bytes, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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

    const contract_addr: primitives.Address = .{ .bytes = @as([20]u8, @splat(0x02)) };
    const code_hash = try db.set_code(&bytecode);
    try db.set_account(contract_addr.bytes, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Call SHA256 precompile (address 0x02)
    const precompile_addr = primitives.Address.fromU256(2);
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
        .prev_randao = @as([32]u8, @splat(0)),
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
    const child_addr = @as([20]u8, @splat(0x03));
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

    const parent_addr = @as([20]u8, @splat(0x04));
    const parent_address: primitives.Address = .{ .bytes = parent_addr };
    const parent_code_hash = try db.set_code(parent_bytecode[0..idx]);
    try db.set_account(parent_addr, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = parent_code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    });

    // Child contract that also emits log
    const child_bytecode = [_]u8{ 0x60, 0x10, 0x60, 0x00, 0xA0, 0x00 }; // PUSH1 0x10 PUSH1 0x00 LOG0 STOP
    const child_code_hash = try db.set_code(&child_bytecode);
    try db.set_account(child_addr, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = child_code_hash,
        .storage_root = @as([32]u8, @splat(0)),
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

    const origin_addr = try primitives.Address.fromHex("0x1111111111111111111111111111111111111111");
    const contract_a = try primitives.Address.fromHex("0x2222222222222222222222222222222222222222");

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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(allocator, &db, block_info, tx_context, 20_000_000_000, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Give creator account some balance
    const creator_address: primitives.Address = .{ .bytes = [_]u8{0x11} ++ @as([19]u8, @splat(0)) };
    try db.set_account(creator_address.bytes, Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
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
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(allocator, &db, block_info, tx_context, 20_000_000_000, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    // Give creator account some balance
    const creator_address: primitives.Address = .{ .bytes = [_]u8{0x22} ++ @as([19]u8, @splat(0)) };
    try db.set_account(creator_address.bytes, Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
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
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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
    const contract_address: primitives.Address = .{ .bytes = [_]u8{0x42} ++ @as([19]u8, @splat(0)) };
    const code_hash = try db.set_code(&stop_bytecode);
    try db.set_account(contract_address.bytes, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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
    const contract_address: primitives.Address = .{ .bytes = [_]u8{0x43} ++ @as([19]u8, @splat(0)) };
    const code_hash = try db.set_code(&return_bytecode);
    try db.set_account(contract_address.bytes, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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
    const contract_address: primitives.Address = .{ .bytes = [_]u8{0x44} ++ @as([19]u8, @splat(0)) };
    const code_hash = try db.set_code(&jump_bytecode);
    try db.set_account(contract_address.bytes, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
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
        .prev_randao = @as([32]u8, @splat(0)),
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
    const caller_address = primitives.Address{ .bytes = [_]u8{0x10} ++ @as([18]u8, @splat(0)) ++ [_]u8{0x01} };
    try db.set_account(caller_address.bytes, Account{
        .balance = std.math.maxInt(u256),
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    });

    // Read the actual ERC20 bytecode from file
    const bytecode_hex = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/evm/fixtures/erc20-transfer/bytecode.txt", std.testing.allocator, .limited(16 * 1024 * 1024));
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

test "SSTORE gas - cold 0->1 via PUSH1 PUSH0 SSTORE costs exactly 22105" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = @as([32]u8, @splat(0)),
    };
    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(std.testing.allocator, &db, block_info, context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();

    const code = [_]u8{ 0x60, 0x01, 0x5f, 0x55 };
    const contract_address: primitives.Address = .{ .bytes = [_]u8{0x43} ++ @as([19]u8, @splat(0)) };
    const code_hash = try db.set_code(&code);
    try db.set_account(contract_address.bytes, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    });

    const result = evm.inner_call(.{ .call = .{
        .caller = primitives.ZERO_ADDRESS,
        .to = contract_address,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    } });

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 22105), 100000 - result.gas_left);
    try std.testing.expectEqual(@as(u64, 0), evm.gas_refund_counter);
}

// ============================================================================
// Gas-schedule, call-semantics and analysis regression tests.
//
// Each test runs real bytecode through the Frame interpreter with
// `Evm.inner_call` (the entry point the EEST state-test runner uses), so the
// basic-block gas batching, the dispatch schedule and the handlers are all
// exercised together.
// ============================================================================

const regression_block_info = BlockInfo{
    .number = 1,
    .timestamp = 1000,
    .difficulty = 100,
    .gas_limit = 30000000,
    .coinbase = primitives.ZERO_ADDRESS,
    .base_fee = 0,
    .prev_randao = @as([32]u8, @splat(0)),
};
const regression_context = TransactionContext{
    .gas_limit = 1000000,
    .coinbase = primitives.ZERO_ADDRESS,
    .chain_id = 1,
};
const regression_contract: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{0x43} };
const regression_callee: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{0x44} };
const regression_sender: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{0x10} };

test "SSTORE gas and refund - every transition on every metering scheme" {
    // One case: the slot's value at transaction start, the values written in order,
    // and the expected execution gas and refund counter. Each write is
    // PUSH1 value, PUSH1 0, SSTORE (3 + 3 + SSTORE cost).
    const Case = struct { original: u8, writes: []const u8, gas: u64, refund: u64 };
    const Fork = struct { hardfork: Hardfork, cases: []const Case };
    const forks = [_]Fork{
        .{ .hardfork = .CANCUN, .cases = &.{
            .{ .original = 0, .writes = &.{0}, .gas = 6 + 2200, .refund = 0 }, // 0 -> 0 cold
            .{ .original = 0, .writes = &.{1}, .gas = 6 + 22100, .refund = 0 }, // 0 -> 1 cold
            .{ .original = 1, .writes = &.{1}, .gas = 6 + 2200, .refund = 0 }, // 1 -> 1 cold
            .{ .original = 1, .writes = &.{2}, .gas = 6 + 5000, .refund = 0 }, // 1 -> 2 cold
            .{ .original = 1, .writes = &.{0}, .gas = 6 + 5000, .refund = 4800 }, // 1 -> 0 cold
            .{ .original = 1, .writes = &.{ 1, 2 }, .gas = 6 + 2200 + 6 + 2900, .refund = 0 }, // warm reset
            .{ .original = 1, .writes = &.{ 1, 0 }, .gas = 6 + 2200 + 6 + 2900, .refund = 4800 }, // warm clear
            .{ .original = 0, .writes = &.{ 0, 1 }, .gas = 6 + 2200 + 6 + 20000, .refund = 0 }, // warm set
            .{ .original = 0, .writes = &.{ 1, 2 }, .gas = 6 + 22100 + 6 + 100, .refund = 0 }, // dirty
            .{ .original = 0, .writes = &.{ 1, 0 }, .gas = 6 + 22100 + 6 + 100, .refund = 19900 }, // dirty, restore 0
            .{ .original = 1, .writes = &.{ 2, 1 }, .gas = 6 + 5000 + 6 + 100, .refund = 2800 }, // dirty, restore 1
            .{ .original = 1, .writes = &.{ 2, 0 }, .gas = 6 + 5000 + 6 + 100, .refund = 4800 }, // dirty, clear
            .{ .original = 1, .writes = &.{ 0, 2 }, .gas = 6 + 5000 + 6 + 100, .refund = 0 }, // clear undone
            .{ .original = 1, .writes = &.{ 0, 1 }, .gas = 6 + 5000 + 6 + 100, .refund = 2800 }, // clear undone, restored
            .{ .original = 1, .writes = &.{ 0, 2, 0 }, .gas = 6 + 5000 + 2 * (6 + 100), .refund = 4800 },
        } },
        .{ .hardfork = .LONDON, .cases = &.{
            .{ .original = 0, .writes = &.{1}, .gas = 6 + 22100, .refund = 0 },
            .{ .original = 1, .writes = &.{2}, .gas = 6 + 5000, .refund = 0 },
            .{ .original = 1, .writes = &.{0}, .gas = 6 + 5000, .refund = 4800 },
            .{ .original = 0, .writes = &.{ 1, 0 }, .gas = 6 + 22100 + 6 + 100, .refund = 19900 },
            .{ .original = 1, .writes = &.{ 0, 1 }, .gas = 6 + 5000 + 6 + 100, .refund = 2800 },
        } },
        .{ .hardfork = .BERLIN, .cases = &.{
            .{ .original = 0, .writes = &.{0}, .gas = 6 + 2200, .refund = 0 },
            .{ .original = 0, .writes = &.{1}, .gas = 6 + 22100, .refund = 0 },
            .{ .original = 1, .writes = &.{2}, .gas = 6 + 5000, .refund = 0 },
            .{ .original = 1, .writes = &.{0}, .gas = 6 + 5000, .refund = 15000 },
            .{ .original = 0, .writes = &.{ 1, 0 }, .gas = 6 + 22100 + 6 + 100, .refund = 19900 },
            .{ .original = 1, .writes = &.{ 2, 1 }, .gas = 6 + 5000 + 6 + 100, .refund = 2800 },
            .{ .original = 1, .writes = &.{ 2, 0 }, .gas = 6 + 5000 + 6 + 100, .refund = 15000 },
            .{ .original = 1, .writes = &.{ 0, 2 }, .gas = 6 + 5000 + 6 + 100, .refund = 0 },
            .{ .original = 1, .writes = &.{ 0, 1 }, .gas = 6 + 5000 + 6 + 100, .refund = 2800 },
        } },
        .{ .hardfork = .ISTANBUL, .cases = &.{
            .{ .original = 0, .writes = &.{0}, .gas = 6 + 800, .refund = 0 },
            .{ .original = 0, .writes = &.{1}, .gas = 6 + 20000, .refund = 0 },
            .{ .original = 1, .writes = &.{1}, .gas = 6 + 800, .refund = 0 },
            .{ .original = 1, .writes = &.{2}, .gas = 6 + 5000, .refund = 0 },
            .{ .original = 1, .writes = &.{0}, .gas = 6 + 5000, .refund = 15000 },
            .{ .original = 0, .writes = &.{ 1, 0 }, .gas = 6 + 20000 + 6 + 800, .refund = 19200 },
            .{ .original = 1, .writes = &.{ 2, 1 }, .gas = 6 + 5000 + 6 + 800, .refund = 4200 },
            .{ .original = 1, .writes = &.{ 0, 2 }, .gas = 6 + 5000 + 6 + 800, .refund = 0 },
            .{ .original = 1, .writes = &.{ 0, 1 }, .gas = 6 + 5000 + 6 + 800, .refund = 4200 },
        } },
        .{ .hardfork = .PETERSBURG, .cases = &.{
            .{ .original = 0, .writes = &.{0}, .gas = 6 + 5000, .refund = 0 },
            .{ .original = 0, .writes = &.{1}, .gas = 6 + 20000, .refund = 0 },
            .{ .original = 1, .writes = &.{1}, .gas = 6 + 5000, .refund = 0 },
            .{ .original = 1, .writes = &.{2}, .gas = 6 + 5000, .refund = 0 },
            .{ .original = 1, .writes = &.{0}, .gas = 6 + 5000, .refund = 15000 },
            .{ .original = 0, .writes = &.{ 1, 0 }, .gas = 6 + 20000 + 6 + 5000, .refund = 15000 },
            .{ .original = 1, .writes = &.{ 0, 1 }, .gas = 6 + 5000 + 6 + 20000, .refund = 15000 },
        } },
        .{ .hardfork = .FRONTIER, .cases = &.{
            .{ .original = 0, .writes = &.{0}, .gas = 6 + 5000, .refund = 0 },
            .{ .original = 0, .writes = &.{1}, .gas = 6 + 20000, .refund = 0 },
            .{ .original = 1, .writes = &.{2}, .gas = 6 + 5000, .refund = 0 },
            .{ .original = 1, .writes = &.{0}, .gas = 6 + 5000, .refund = 15000 },
            .{ .original = 1, .writes = &.{ 2, 1 }, .gas = 2 * (6 + 5000), .refund = 0 },
        } },
    };

    inline for (forks) |fork| {
        const E = Evm(.{ .eips = .{ .hardfork = fork.hardfork } });
        for (fork.cases) |case| {
            var db = Database.init(std.testing.allocator);
            defer db.deinit();
            var evm = try E.init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
            defer evm.deinit();

            var code: [5 * 4]u8 = undefined;
            var code_len: usize = 0;
            for (case.writes) |written| {
                const write = [_]u8{ 0x60, written, 0x60, 0x00, 0x55 };
                @memcpy(code[code_len .. code_len + write.len], &write);
                code_len += write.len;
            }
            const code_hash = try db.set_code(code[0..code_len]);
            try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });
            if (case.original != 0) try db.set_storage(regression_contract.bytes, 0, case.original);

            const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 100000 } });
            try std.testing.expect(result.success);
            try std.testing.expectEqual(case.gas, 100000 - result.gas_left);
            try std.testing.expectEqual(case.refund, evm.gas_refund_counter);
            try std.testing.expectEqual(@as(u256, case.writes[case.writes.len - 1]), try db.get_storage(regression_contract.bytes, 0));
        }
    }
}

test "SSTORE sentry - EIP-2200 sees the exact gas left, not gas minus later instructions" {
    // PUSH1 0, PUSH1 0, SSTORE (0 -> 0 on a cold slot: 2200 gas), then ten
    // PUSH1/POP pairs (50 gas). The trailing 50 gas must not be charged before the
    // SSTORE, or the sentry would see less gas than is really left.
    const code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x55 } ++ @as([30]u8, @bitCast(@as([10][3]u8, @splat(.{ 0x60, 0x00, 0x50 }))));
    const Outcome = struct { gas: u64, success: bool, gas_used: u64 };
    const outcomes = [_]Outcome{
        // 2301 gas left at SSTORE: above the sentry.
        .{ .gas = 6 + 2301, .success = true, .gas_used = 6 + 2200 + 50 },
        // 2300 gas left at SSTORE: at the sentry, fails although 2200 would be enough.
        .{ .gas = 6 + 2300, .success = false, .gas_used = 6 + 2300 },
    };
    for (outcomes) |outcome| {
        var db = Database.init(std.testing.allocator);
        defer db.deinit();
        var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
        defer evm.deinit();
        const code_hash = try db.set_code(&code);
        try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

        const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = outcome.gas } });
        try std.testing.expectEqual(outcome.success, result.success);
        try std.testing.expectEqual(outcome.gas_used, outcome.gas - result.gas_left);
    }
}

test "SSTORE and TSTORE in a static context halt the callee" {
    // Callee writes storage. Caller STATICCALLs it with 50000 gas and stores the
    // success flag in slot 1.
    const callees = [_][]const u8{
        &.{ 0x60, 0x07, 0x60, 0x00, 0x55 }, // SSTORE
        &.{ 0x60, 0x07, 0x60, 0x00, 0x5d }, // TSTORE
    };
    const caller_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x44, 0x61, 0xc3, 0x50, 0xfa, 0x60, 0x01, 0x55 };
    for (callees) |callee_code| {
        var db = Database.init(std.testing.allocator);
        defer db.deinit();
        var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
        defer evm.deinit();
        const caller_hash = try db.set_code(&caller_code);
        try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = caller_hash, .storage_root = @as([32]u8, @splat(0)) });
        try db.set_storage(regression_contract.bytes, 1, 5);
        const callee_hash = try db.set_code(callee_code);
        try db.set_account(regression_callee.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = callee_hash, .storage_root = @as([32]u8, @splat(0)) });

        const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 200000 } });
        try std.testing.expect(result.success);
        // The static call failed, so the flag written to slot 1 is 0.
        try std.testing.expectEqual(@as(u256, 0), try db.get_storage(regression_contract.bytes, 1));
        try std.testing.expectEqual(@as(u256, 0), try db.get_storage(regression_callee.bytes, 0));
    }
}

test "State-access opcodes use each fork's flat price before Berlin" {
    // PUSH1 0, SLOAD and PUSH1 7, BALANCE against cold state.
    const Expected = struct { hardfork: Hardfork, sload: u64, balance: u64 };
    const expectations = [_]Expected{
        .{ .hardfork = .FRONTIER, .sload = 3 + 50, .balance = 3 + 20 },
        .{ .hardfork = .HOMESTEAD, .sload = 3 + 50, .balance = 3 + 20 },
        .{ .hardfork = .TANGERINE_WHISTLE, .sload = 3 + 200, .balance = 3 + 400 },
        .{ .hardfork = .BYZANTIUM, .sload = 3 + 200, .balance = 3 + 400 },
        .{ .hardfork = .PETERSBURG, .sload = 3 + 200, .balance = 3 + 400 },
        .{ .hardfork = .ISTANBUL, .sload = 3 + 800, .balance = 3 + 700 },
        .{ .hardfork = .BERLIN, .sload = 3 + 2100, .balance = 3 + 2600 },
        .{ .hardfork = .CANCUN, .sload = 3 + 2100, .balance = 3 + 2600 },
    };
    inline for (expectations) |expected| {
        const E = Evm(.{ .eips = .{ .hardfork = expected.hardfork } });
        const programs = [_]struct { code: []const u8, gas: u64 }{
            .{ .code = &.{ 0x60, 0x00, 0x54 }, .gas = expected.sload },
            .{ .code = &.{ 0x60, 0x07, 0x31 }, .gas = expected.balance },
        };
        for (programs) |program| {
            var db = Database.init(std.testing.allocator);
            defer db.deinit();
            var evm = try E.init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
            defer evm.deinit();
            const code_hash = try db.set_code(program.code);
            try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

            const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 100000 } });
            try std.testing.expect(result.success);
            try std.testing.expectEqual(program.gas, 100000 - result.gas_left);
        }
    }
}

test "Warm access is not charged on top of cold access" {
    // SLOAD twice and BALANCE twice on the same key: cold then warm, no double charge.
    const programs = [_]struct { code: []const u8, gas: u64 }{
        .{ .code = &.{ 0x60, 0x00, 0x54, 0x60, 0x00, 0x54 }, .gas = 3 + 2100 + 3 + 100 },
        .{ .code = &.{ 0x60, 0x07, 0x31, 0x60, 0x07, 0x31 }, .gas = 3 + 2600 + 3 + 100 },
        .{ .code = &.{ 0x60, 0x07, 0x3b, 0x60, 0x07, 0x3b }, .gas = 3 + 2600 + 3 + 100 }, // EXTCODESIZE
        .{ .code = &.{ 0x60, 0x07, 0x3f, 0x60, 0x07, 0x3f }, .gas = 3 + 2600 + 3 + 100 }, // EXTCODEHASH
        // SLOAD then SSTORE 0 -> 1 on the now-warm slot: no cold surcharge on the SSTORE.
        .{ .code = &.{ 0x60, 0x00, 0x54, 0x60, 0x01, 0x60, 0x00, 0x55 }, .gas = 3 + 2100 + 6 + 20000 },
        // SELFDESTRUCT to a cold, empty beneficiary with zero balance: 5000 + 2600.
        .{ .code = &.{ 0x60, 0x99, 0xff }, .gas = 3 + 5000 + 2600 },
        // SELFDESTRUCT to self (warm): 5000.
        .{ .code = &.{ 0x30, 0xff }, .gas = 2 + 5000 },
    };
    for (programs) |program| {
        var db = Database.init(std.testing.allocator);
        defer db.deinit();
        var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
        defer evm.deinit();
        const code_hash = try db.set_code(program.code);
        try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

        const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 100000 } });
        try std.testing.expect(result.success);
        try std.testing.expectEqual(program.gas, 100000 - result.gas_left);
    }
}

test "CALL gas - cold and warm target, value transfer, stipend and refused calls" {
    // Caller: PUSH1 0 x4 (ranges), PUSH1 value, PUSH1 0x44, PUSH2 0xc350 (50000 gas), CALL.
    // 21 gas of pushes. Callee 0x44 is an existing account with code STOP.
    const Case = struct { value: u8, caller_balance: u256, second_call: bool, gas: u64 };
    const cases = [_]Case{
        // Cold target, no value: 100 + 2500.
        .{ .value = 0, .caller_balance = 0, .second_call = false, .gas = 21 + 2600 },
        // Second call to the same target is warm: 100.
        .{ .value = 0, .caller_balance = 0, .second_call = true, .gas = 21 + 2600 + 21 + 100 },
        // Value transfer to an existing account: 9000, and the unused 2300 stipend returns.
        .{ .value = 1, .caller_balance = 10, .second_call = false, .gas = 21 + 2600 + 9000 - 2300 },
        // Caller cannot fund the value: the call is refused, all its gas (and stipend) returns.
        .{ .value = 1, .caller_balance = 0, .second_call = false, .gas = 21 + 2600 + 9000 - 2300 },
    };
    for (cases) |case| {
        var db = Database.init(std.testing.allocator);
        defer db.deinit();
        var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
        defer evm.deinit();

        const one_call = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, case.value, 0x60, 0x44, 0x61, 0xc3, 0x50, 0xf1 };
        const code = one_call ++ one_call;
        const code_slice: []const u8 = if (case.second_call) &code else &one_call;
        const caller_hash = try db.set_code(code_slice);
        try db.set_account(regression_contract.bytes, Account{ .balance = case.caller_balance, .nonce = 1, .code_hash = caller_hash, .storage_root = @as([32]u8, @splat(0)) });
        const callee_hash = try db.set_code(&[_]u8{0x00});
        try db.set_account(regression_callee.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = callee_hash, .storage_root = @as([32]u8, @splat(0)) });

        const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 200000 } });
        try std.testing.expect(result.success);
        try std.testing.expectEqual(case.gas, 200000 - result.gas_left);
    }
}

test "CALL with zero gas to an account without code succeeds" {
    // CALL(gas=0, to=0x77) then store the success flag in slot 1.
    const code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x77, 0x60, 0x00, 0xf1, 0x60, 0x01, 0x55 };
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
    defer evm.deinit();
    const code_hash = try db.set_code(&code);
    try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

    const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 200000 } });
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u256, 1), try db.get_storage(regression_contract.bytes, 1));

    // The same holds for a zero-gas call made directly.
    const direct = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{0x78} }, .value = 0, .input = &.{}, .gas = 0 } });
    try std.testing.expect(direct.success);
}

test "CALL copies revert data to memory and to the return data buffer" {
    // Callee: MSTORE(0, 0x2a); REVERT(0, 32).
    const callee_code = [_]u8{ 0x60, 0x2a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xfd };
    // Caller: CALL(out = [0, 32)); POP; RETURNDATASIZE; PUSH1 0x20; MSTORE; RETURN(0, 64).
    const caller_code = [_]u8{ 0x60, 0x20, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x44, 0x5a, 0xf1, 0x50, 0x3d, 0x60, 0x20, 0x52, 0x60, 0x40, 0x60, 0x00, 0xf3 };
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
    defer evm.deinit();
    const caller_hash = try db.set_code(&caller_code);
    try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = caller_hash, .storage_root = @as([32]u8, @splat(0)) });
    const callee_hash = try db.set_code(&callee_code);
    try db.set_account(regression_callee.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = callee_hash, .storage_root = @as([32]u8, @splat(0)) });

    const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 200000 } });
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 64), result.output.len);
    try std.testing.expectEqual(@as(u8, 0x2a), result.output[31]); // revert data in memory
    try std.testing.expectEqual(@as(u8, 0x20), result.output[63]); // RETURNDATASIZE == 32
}

test "DELEGATECALL runs the callee's code against the caller's storage" {
    // Callee: SSTORE(0, 7). Caller: DELEGATECALL(0x44).
    const callee_code = [_]u8{ 0x60, 0x07, 0x60, 0x00, 0x55 };
    const caller_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x44, 0x5a, 0xf4 };
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
    defer evm.deinit();
    const caller_hash = try db.set_code(&caller_code);
    try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = caller_hash, .storage_root = @as([32]u8, @splat(0)) });
    const callee_hash = try db.set_code(&callee_code);
    try db.set_account(regression_callee.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = callee_hash, .storage_root = @as([32]u8, @splat(0)) });

    const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 200000 } });
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u256, 7), try db.get_storage(regression_contract.bytes, 0));
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(regression_callee.bytes, 0));
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(regression_sender.bytes, 0));
}

test "Refunds earned by a reverted callee are discarded" {
    // Callee slot 0 holds 1. Callee: SSTORE(0, 0) (4800 refund), then REVERT or STOP.
    const callees = [_]struct { code: []const u8, refund: u64, slot: u256 }{
        .{ .code = &.{ 0x60, 0x00, 0x60, 0x00, 0x55, 0x60, 0x00, 0x60, 0x00, 0xfd }, .refund = 0, .slot = 1 },
        .{ .code = &.{ 0x60, 0x00, 0x60, 0x00, 0x55, 0x00 }, .refund = 4800, .slot = 0 },
    };
    const caller_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x44, 0x5a, 0xf1 };
    for (callees) |callee| {
        var db = Database.init(std.testing.allocator);
        defer db.deinit();
        var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
        defer evm.deinit();
        const caller_hash = try db.set_code(&caller_code);
        try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = caller_hash, .storage_root = @as([32]u8, @splat(0)) });
        const callee_hash = try db.set_code(callee.code);
        try db.set_account(regression_callee.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = callee_hash, .storage_root = @as([32]u8, @splat(0)) });
        try db.set_storage(regression_callee.bytes, 0, 1);

        const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 200000 } });
        try std.testing.expect(result.success);
        try std.testing.expectEqual(callee.refund, evm.gas_refund_counter);
        try std.testing.expectEqual(callee.slot, try db.get_storage(regression_callee.bytes, 0));
    }
}

test "Call depth limit - frames run at depths 0 through max_call_depth" {
    // SSTORE(0, SLOAD(0) + 1); CALL(self). Slot 0 counts the frames that ran.
    const code = [_]u8{ 0x60, 0x00, 0x54, 0x60, 0x01, 0x01, 0x60, 0x00, 0x55, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x30, 0x5a, 0xf1 };
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    var evm = try Evm(.{ .max_call_depth = 3, .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
    defer evm.deinit();
    const code_hash = try db.set_code(&code);
    try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

    const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 1000000 } });
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u256, 4), try db.get_storage(regression_contract.bytes, 0));
}

test "Truncated PUSH at the end of code executes as a zero-padded push" {
    const programs = [_]struct { code: []const u8, gas: u64 }{
        .{ .code = &.{0x60}, .gas = 3 }, // PUSH1 with no data
        .{ .code = &.{ 0x7f, 0xab, 0xcd }, .gas = 3 }, // PUSH32 with 2 of 32 bytes
        .{ .code = &.{ 0x60, 0x01, 0x61, 0xff }, .gas = 6 }, // PUSH1 1, PUSH2 with 1 of 2 bytes
        .{ .code = &.{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x7f }, .gas = 12 }, // after a fused PUSH+ADD
    };
    for (programs) |program| {
        var db = Database.init(std.testing.allocator);
        defer db.deinit();
        var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
        defer evm.deinit();
        const code_hash = try db.set_code(program.code);
        try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

        const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 100000 } });
        try std.testing.expect(result.success);
        try std.testing.expectEqual(program.gas, 100000 - result.gas_left);
    }
}

test "Code that looks like trailing compiler metadata is executable" {
    // PUSH1 0x0b, JUMP, then bytes shaped like Solidity CBOR metadata (a2 64 "ipfs" ...)
    // that contain JUMPDEST, SSTORE(0, 1), STOP, then the 2-byte metadata length.
    const code = [_]u8{ 0x60, 0x0b, 0x56, 0xa2, 0x64, 0x69, 0x70, 0x66, 0x73, 0x00, 0x00, 0x5b, 0x60, 0x01, 0x60, 0x00, 0x55, 0x00, 0x00, 0x0f };
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
    defer evm.deinit();
    const code_hash = try db.set_code(&code);
    try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

    const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 100000 } });
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u256, 1), try db.get_storage(regression_contract.bytes, 0));
}

test "EIP-3860 - CREATE and CREATE2 with oversized init code halt the creating frame" {
    // PUSH3 size, PUSH1 0 (offset), PUSH1 0 (value), CREATE; then SSTORE(0, 1).
    // CREATE2 pushes a salt first. A halted frame never reaches the SSTORE.
    const Case = struct { hardfork: Hardfork, create2: bool, size: u24, success: bool };
    const cases = [_]Case{
        .{ .hardfork = .SHANGHAI, .create2 = false, .size = 49152, .success = true },
        .{ .hardfork = .SHANGHAI, .create2 = false, .size = 49153, .success = false },
        .{ .hardfork = .CANCUN, .create2 = true, .size = 49152, .success = true },
        .{ .hardfork = .CANCUN, .create2 = true, .size = 49153, .success = false },
        .{ .hardfork = .OSAKA, .create2 = false, .size = 49153, .success = false },
        // Before Shanghai there is no init code limit.
        .{ .hardfork = .LONDON, .create2 = false, .size = 49153, .success = true },
        .{ .hardfork = .LONDON, .create2 = true, .size = 49153, .success = true },
    };
    inline for (cases) |case| {
        const E = Evm(.{ .eips = .{ .hardfork = case.hardfork } });
        var db = Database.init(std.testing.allocator);
        defer db.deinit();
        var evm = try E.init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
        defer evm.deinit();

        const size_bytes = [_]u8{ @intCast(case.size >> 16), @intCast((case.size >> 8) & 0xff), @intCast(case.size & 0xff) };
        const create_code = [_]u8{0x62} ++ size_bytes ++ [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xf0, 0x60, 0x01, 0x60, 0x00, 0x55 };
        const create2_code = [_]u8{ 0x60, 0x00, 0x62 } ++ size_bytes ++ [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xf5, 0x60, 0x01, 0x60, 0x00, 0x55 };
        const code: []const u8 = if (case.create2) &create2_code else &create_code;
        const code_hash = try db.set_code(code);
        try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

        const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 1000000 } });
        try std.testing.expectEqual(case.success, result.success);
        const creator = (try db.get_account(regression_contract.bytes)).?;
        if (case.success) {
            try std.testing.expectEqual(@as(u256, 1), try db.get_storage(regression_contract.bytes, 0));
            try std.testing.expectEqual(@as(u64, 2), creator.nonce);
        } else {
            // Exceptional halt: all gas consumed, no state change, nonce untouched.
            try std.testing.expectEqual(@as(u64, 0), result.gas_left);
            try std.testing.expectEqual(@as(u256, 0), try db.get_storage(regression_contract.bytes, 0));
            try std.testing.expectEqual(@as(u64, 1), creator.nonce);
        }
    }
}

test "CREATE that cannot pay its charge halts instead of pushing zero" {
    // PUSH1 0 x3, CREATE, STOP with 9 + 31999 gas: CREATE needs 32000.
    const code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0xf0, 0x00 };
    const outcomes = [_]struct { gas: u64, success: bool }{
        .{ .gas = 9 + 31999, .success = false },
        .{ .gas = 9 + 32000, .success = true },
    };
    for (outcomes) |outcome| {
        var db = Database.init(std.testing.allocator);
        defer db.deinit();
        var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
        defer evm.deinit();
        const code_hash = try db.set_code(&code);
        try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

        const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = outcome.gas } });
        try std.testing.expectEqual(outcome.success, result.success);
        if (!outcome.success) try std.testing.expectEqual(@as(u64, 0), result.gas_left);
    }
}

test "CREATE in a static context halts the callee" {
    // Callee: CREATE with empty init code. Caller: STATICCALL it, store the flag in slot 1.
    const callee_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0xf0, 0x00 };
    const caller_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x44, 0x61, 0xc3, 0x50, 0xfa, 0x60, 0x01, 0x55 };
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
    defer evm.deinit();
    const caller_hash = try db.set_code(&caller_code);
    try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = caller_hash, .storage_root = @as([32]u8, @splat(0)) });
    try db.set_storage(regression_contract.bytes, 1, 5);
    const callee_hash = try db.set_code(&callee_code);
    try db.set_account(regression_callee.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = callee_hash, .storage_root = @as([32]u8, @splat(0)) });

    const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 500000 } });
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(regression_contract.bytes, 1));
    try std.testing.expectEqual(@as(u64, 1), (try db.get_account(regression_callee.bytes)).?.nonce);
}

test "Gas segments - GAS observes exactly the gas left after its own cost" {
    // PUSH1 1 (3), GAS (2), then MSTORE and RETURN. The instructions after GAS must
    // not be charged before GAS runs.
    const code = [_]u8{ 0x60, 0x01, 0x5a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
    defer evm.deinit();
    const code_hash = try db.set_code(&code);
    try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

    const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 100000 } });
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);
    var observed: u256 = 0;
    for (result.output) |byte| observed = (observed << 8) | byte;
    try std.testing.expectEqual(@as(u256, 100000 - 5), observed);
}

test "Gas segments - a JUMPI charges only the branch that runs" {
    // CALLDATASIZE, PUSH1 8, JUMPI | PUSH1 1, POP, STOP | JUMPDEST, PUSH1 1, PUSH1 2, ADD, POP, STOP
    const code = [_]u8{ 0x36, 0x60, 0x08, 0x57, 0x60, 0x01, 0x50, 0x00, 0x5b, 0x60, 0x01, 0x60, 0x02, 0x01, 0x50, 0x00 };
    const branches = [_]struct { input: []const u8, gas: u64 }{
        .{ .input = &.{}, .gas = 15 + 5 }, // not taken
        .{ .input = &.{0x01}, .gas = 15 + 1 + 11 }, // taken
    };
    for (branches) |branch| {
        var db = Database.init(std.testing.allocator);
        defer db.deinit();
        var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
        defer evm.deinit();
        const code_hash = try db.set_code(&code);
        try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

        const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = branch.input, .gas = 100000 } });
        try std.testing.expect(result.success);
        try std.testing.expectEqual(branch.gas, 100000 - result.gas_left);

        // With exactly the gas of the branch that runs, execution succeeds: the other
        // branch's gas is never required.
        var db_exact = Database.init(std.testing.allocator);
        defer db_exact.deinit();
        var evm_exact = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db_exact, regression_block_info, regression_context, 0, regression_sender);
        defer evm_exact.deinit();
        const exact_hash = try db_exact.set_code(&code);
        try db_exact.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = exact_hash, .storage_root = @as([32]u8, @splat(0)) });
        const exact = evm_exact.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = branch.input, .gas = branch.gas } });
        try std.testing.expect(exact.success);
        try std.testing.expectEqual(@as(u64, 0), exact.gas_left);
        const short = evm_exact.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = branch.input, .gas = branch.gas - 1 } });
        try std.testing.expect(!short.success);
    }
}

test "Gas segments - entry block and JUMPDEST block charge the same gas for the same code" {
    // The same instruction sequence costs the same whether it is the entry block or
    // a block headed by a JUMPDEST (which adds only the JUMPDEST's 1 gas).
    const body = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x80, 0x02, 0x50, 0x5f, 0x54, 0x50 }; // 3+3+3+3+5+2+2+2100+2
    const body_gas: u64 = 3 + 3 + 3 + 3 + 5 + 2 + 2 + 2100 + 2;
    const entry_code = body;
    const jumpdest_code = [_]u8{ 0x60, 0x03, 0x56, 0x5b } ++ body; // PUSH1 3, JUMP, JUMPDEST, body
    const programs = [_]struct { code: []const u8, gas: u64 }{
        .{ .code = &entry_code, .gas = body_gas },
        .{ .code = &jumpdest_code, .gas = 3 + 8 + 1 + body_gas },
    };
    for (programs) |program| {
        var db = Database.init(std.testing.allocator);
        defer db.deinit();
        var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
        defer evm.deinit();
        const code_hash = try db.set_code(program.code);
        try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

        const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 100000 } });
        try std.testing.expect(result.success);
        try std.testing.expectEqual(program.gas, 100000 - result.gas_left);
    }
}

test "Fused PUSH+MSTORE with an unpayable offset halts instead of being skipped" {
    // PUSH1 1, PUSH32 0xff..ff, MSTORE, then SSTORE(0, 1) that must never run.
    const code = [_]u8{ 0x60, 0x01, 0x7f } ++ @as([32]u8, @splat(0xff)) ++ [_]u8{ 0x52, 0x60, 0x01, 0x60, 0x00, 0x55 };
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
    defer evm.deinit();
    const code_hash = try db.set_code(&code);
    try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

    const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 1000000 } });
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 0), result.gas_left);
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(regression_contract.bytes, 0));
}

test "Fused PUSH+ADD keeps the unfused stack-overflow check" {
    // n x PUSH1 0, then PUSH1 1, PUSH1 2, ADD. Unfused, the second PUSH needs n + 2
    // stack slots even though the fused PUSH+ADD would not grow the stack.
    const tail = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01 };
    const fits = @as([2044]u8, @bitCast(@as([1022][2]u8, @splat(.{ 0x60, 0x00 })))) ++ tail;
    const overflows = @as([2046]u8, @bitCast(@as([1023][2]u8, @splat(.{ 0x60, 0x00 })))) ++ tail;
    const programs = [_]struct { code: []const u8, success: bool }{
        .{ .code = &fits, .success = true },
        .{ .code = &overflows, .success = false },
    };
    for (programs) |program| {
        var db = Database.init(std.testing.allocator);
        defer db.deinit();
        var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
        defer evm.deinit();
        const code_hash = try db.set_code(program.code);
        try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

        const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 1000000 } });
        try std.testing.expectEqual(program.success, result.success);
        if (!program.success) try std.testing.expectEqual(@as(u64, 0), result.gas_left);
    }
}

test "EIP-7702 - EXTCODESIZE sees the designator and a self-delegating EOA halts instead of recursing" {
    // EXTCODESIZE(0x44) -> slot 0; CALL(gas 10000, 0x44) success flag -> slot 1. 0x44
    // delegates to itself. The failing call burns only the 10000 it was given.
    const code = [_]u8{ 0x60, 0x44, 0x3b, 0x60, 0x00, 0x55, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x44, 0x61, 0x27, 0x10, 0xf1, 0x60, 0x01, 0x55, 0x00 };
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    var evm = try Evm(.{ .eips = .{ .hardfork = .PRAGUE } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
    defer evm.deinit();
    const code_hash = try db.set_code(&code);
    try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });
    try db.set_account(regression_callee.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)), .delegated_address = regression_callee });
    try db.set_storage(regression_contract.bytes, 1, 7);

    const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 200000 } });
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u256, 23), try db.get_storage(regression_contract.bytes, 0));
    // The designator's 0xEF byte is an invalid opcode, so the inner CALL fails.
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(regression_contract.bytes, 1));
}

test "Created contract nonce starts at 1 before init code runs from Spurious Dragon" {
    // Init code: CREATE(value 0, offset 0, size 0), STOP. The deployed account keeps the
    // nonce its init code left: 1 (initial) + 1 (inner CREATE) from Spurious Dragon,
    // 0 + 1 before it.
    const init_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0xf0, 0x00 };
    const cases = [_]struct { fork: primitives.Hardfork, nonce: u64 }{
        .{ .fork = .HOMESTEAD, .nonce = 1 },
        .{ .fork = .SPURIOUS_DRAGON, .nonce = 2 },
        .{ .fork = .CANCUN, .nonce = 2 },
    };
    inline for (cases) |case| {
        var db = Database.init(std.testing.allocator);
        defer db.deinit();
        var evm = try Evm(.{ .eips = .{ .hardfork = case.fork } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
        defer evm.deinit();
        try db.set_account(regression_sender.bytes, Account{ .balance = 1000000, .nonce = 0, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) });

        const result = evm.inner_call(.{ .create = .{ .caller = regression_sender, .value = 0, .init_code = &init_code, .gas = 500000 } });
        try std.testing.expect(result.success);
        const created = result.created_address orelse return error.TestExpectedCreatedAddress;
        const account = (try db.get_account(created.bytes)) orelse return error.TestExpectedCreatedAccount;
        try std.testing.expectEqual(case.nonce, account.nonce);
    }
}

test "Transaction creation does not pay CreateGas or EIP-3860 initcode words again" {
    // 33 bytes of STOP: 2 initcode words. Intrinsic gas already covered CreateGas and the
    // words, so a transaction-level creation hands all of its gas back.
    const init_code = @as([33]u8, @splat(0x00));
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    var evm = try Evm(.{ .eips = .{ .hardfork = .SHANGHAI } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
    defer evm.deinit();
    // The transaction already incremented the sender nonce from 0 to 1.
    try db.set_account(regression_sender.bytes, Account{ .balance = 1000000, .nonce = 1, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) });
    evm.tx_sender_nonce_incremented = true;

    const result = evm.inner_call(.{ .create = .{ .caller = regression_sender, .value = 0, .init_code = &init_code, .gas = 100000 } });
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 100000), result.gas_left);
    try std.testing.expectEqual(@as(u64, 1), (try db.get_account(regression_sender.bytes)).?.nonce);
}

test "Logs left by inner_call are arena-owned and freed once by deinit" {
    // MSTORE(0, 0xff); LOG1(offset 0, size 32, topic 7); STOP. inner_call keeps the logs
    // for the caller to read; deinit must not free their arena-owned topics and data.
    const code = [_]u8{ 0x60, 0xff, 0x60, 0x00, 0x52, 0x60, 0x07, 0x60, 0x20, 0x60, 0x00, 0xa1, 0x00 };
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    var evm = try Evm(.{ .eips = .{ .hardfork = .CANCUN } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
    defer evm.deinit();
    const code_hash = try db.set_code(&code);
    try db.set_account(regression_contract.bytes, Account{ .balance = 0, .nonce = 1, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

    const result = evm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 100000 } });
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), evm.logs.items.len);
    try std.testing.expectEqualSlices(u256, &.{7}, evm.logs.items[0].topics);
    try std.testing.expectEqual(@as(usize, 32), evm.logs.items[0].data.len);
}
