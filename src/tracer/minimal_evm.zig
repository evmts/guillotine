/// Minimal EVM implementation for tracing and validation
/// This is a simplified, unoptimized EVM that orchestrates execution.
/// Architecture mirrors evm.zig - MinimalEvm orchestrates, MinimalFrame executes
const std = @import("std");
const primitives = @import("voltaire");
const GasConstants = primitives.GasConstants;
const MinimalFrame = @import("minimal_frame.zig").MinimalFrame;
const Hardfork = @import("../eips_and_hardforks/eips.zig").Hardfork;
const minimal_host = @import("minimal_host.zig");
const precompiles = @import("precompiles");
const log = @import("../log.zig");
const native_stack = @import("../native_stack.zig");

const Address = primitives.Address.Address;

/// Native stack kept free below a nested call. MinimalEvm recurses on the native stack
/// once per EVM call depth, and one level (a MinimalFrame's interpreter loop plus the
/// deepest precompile or hash it can reach) must fit in this much.
const native_stack_reserve = 512 * 1024;

/// True when the calling thread's stack bounds are known and less than
/// `native_stack_reserve` of it is left. A nested call must not start then: 1024 EVM
/// call depths do not fit on a small thread stack (a 2 MiB pthread overflows long
/// before the depth limit).
fn nativeStackExhausted() bool {
    if (comptime !native_stack.supported) return false;
    const low = native_stack.lowAddress() orelse return false;
    return @frameAddress() < low +| native_stack_reserve;
}

// Re-export host types for compatibility
pub const HostInterface = minimal_host.HostInterface;
pub const CallResult = minimal_host.CallResult;
pub const Host = minimal_host.Host;
pub const StateReader = minimal_host.StateReader;

/// Storage slot key for tracking
pub const StorageSlotKey = struct {
    address: Address,
    slot: u256,

    pub fn hash(key: StorageSlotKey) u32 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(&key.address.bytes);
        hasher.update(std.mem.asBytes(&key.slot));
        return @truncate(hasher.final());
    }

    pub fn eql(a: StorageSlotKey, b: StorageSlotKey) bool {
        return a.address.equals(b.address) and a.slot == b.slot;
    }
};

// Context for Address ArrayHashMap
const AddressContext = std.array_hash_map.AutoContext(Address);

// Context for hashing/equality of StorageSlotKey for ArrayHashMap
const StorageSlotKeyContext = struct {
    pub fn hash(self: @This(), key: StorageSlotKey) u32 {
        _ = self;
        return StorageSlotKey.hash(key);
    }

    pub fn eql(self: @This(), a: StorageSlotKey, b: StorageSlotKey, b_index: usize) bool {
        _ = self;
        _ = b_index;
        return StorageSlotKey.eql(a, b);
    }
};

/// Minimal EVM - Orchestrates execution like evm.zig
pub const MinimalEvm = struct {
    /// Error set for MinimalEvm operations
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
        InitcodeTooLarge, // this one is never used anywhere
        TruncatedPush,
        OutOfBounds,
        WriteProtection,
        BytecodeTooLarge, // we use CreateInitCodeSizeLimit instead for conventions
        InvalidPush,
        // EIP-3860: Init code exceeds size limit
        CreateInitCodeSizeLimit,
        // EIP-170: Deployed contract code exceeds size limit
        CreateContractSizeLimit,
    };

    const Self = @This();

    /// The four message-call instructions. They differ in whose storage, address,
    /// caller and value the callee sees.
    pub const CallKind = enum { call, callcode, delegatecall, staticcall };

    /// A message call requested by the frame on top of the frame stack.
    pub const CallRequest = struct {
        kind: CallKind,
        /// Account whose code runs.
        target: Address,
        /// Value argument of CALL and CALLCODE; ignored for the other kinds.
        value: u256 = 0,
        input: []const u8,
        /// Gas given to the callee, including the stipend of a value call.
        gas: u64,
    };

    /// A contract creation requested by the frame on top of the frame stack.
    pub const CreateRequest = struct {
        value: u256,
        init_code: []const u8,
        gas: u64,
        /// CREATE2 salt; null for CREATE.
        salt: ?u256 = null,
    };

    pub const CreateResult = struct {
        /// The new contract, or null when the creation failed.
        address: ?Address,
        gas_left: u64,
        /// Revert data of the init code; empty otherwise.
        output: []const u8,
    };

    /// Position in the state journal. `revertTo` undoes everything recorded after it.
    pub const Checkpoint = struct {
        journal_len: usize,
        warm_addresses: usize,
        warm_storage_slots: usize,
        gas_refund: u64,
    };

    /// One undoable state change. `previous == null` means the local map had no entry.
    const JournalEntry = union(enum) {
        storage: struct { key: StorageSlotKey, previous: ?u256 },
        transient: struct { key: StorageSlotKey, previous: ?u256 },
        balance: struct { address: Address, previous: ?u256 },
        nonce: struct { address: Address, previous: ?u64 },
        code: struct { address: Address, previous: ?[]const u8 },
        created: Address,
        selfdestructed: Address,
    };

    const WarmAddresses = std.array_hash_map.Custom(Address, void, AddressContext, false);
    const WarmStorageSlots = std.array_hash_map.Custom(StorageSlotKey, void, StorageSlotKeyContext, false);

    /// EIP-170 (Spurious Dragon): largest runtime code a creation may deposit.
    const max_code_size = 24576;
    /// Depth of the frame stack at which a further call or creation fails.
    const max_call_depth = 1024;

    frames: std.ArrayList(*MinimalFrame),
    storage: std.AutoHashMap(StorageSlotKey, u256),
    transient_storage: std.AutoHashMap(StorageSlotKey, u256),
    original_storage: std.AutoHashMap(StorageSlotKey, u256),
    balances: std.AutoHashMap(Address, u256),
    /// Account nonces. An account without an entry has the nonce its backing state reports.
    nonces: std.AutoHashMap(Address, u64),
    code: std.AutoHashMap(Address, []const u8),
    /// Accounts created during the current transaction. EIP-6780 (Cancun) lets
    /// SELFDESTRUCT delete an account only when it is in this set.
    created_accounts: std.AutoHashMap(Address, void),
    /// Contracts that already ran SELFDESTRUCT in the current transaction. The
    /// pre-London refund is granted once per contract.
    selfdestructed_accounts: std.AutoHashMap(Address, void),
    // EIP-2929 warm/cold tracking. Insertion ordered, so a checkpoint is a length.
    warm_addresses: WarmAddresses,
    warm_storage_slots: WarmStorageSlots,
    /// Undo log of state changes, replayed backwards when a frame reverts or halts.
    journal: std.ArrayList(JournalEntry),

    // Transaction-scoped gas refund counter
    gas_refund: u64,

    // Active hardfork configuration for gas rules
    hardfork: Hardfork,

    // Blockchain context
    chain_id: u64,
    block_number: u64,
    /// Recent ancestor hashes, newest first (see `BlockInfo.block_hashes`).
    block_hashes: []const [32]u8 = &.{},
    block_timestamp: u64,
    block_difficulty: u256,
    block_prevrandao: u256,
    block_coinbase: Address,
    block_gas_limit: u64,
    block_base_fee: u256,
    blob_base_fee: u256,
    /// Borrowed from the transaction that owns this validation frame.
    blob_versioned_hashes: []const [32]u8 = &.{},
    origin: Address,
    gas_price: u256,
    /// Legacy read-through source, consulted after `state_reader`. Never written.
    host: ?HostInterface,
    /// Read-only pre-existing state, consulted when the local maps have no entry.
    state_reader: ?StateReader = null,
    /// Heap allocated so that its address, which every map and list captures through
    /// `allocator`, stays valid when the MinimalEvm value is copied or moved.
    arena: *std.heap.ArenaAllocator,
    /// Allocator that owns `arena`.
    backing_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,

    /// Create a MinimalEvm. The value may be returned, copied and moved freely: all
    /// of its allocations go through a heap-allocated arena that `deinit` releases.
    /// Only one copy may be used and deinitialized.
    pub fn init(allocator: std.mem.Allocator) !Self {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        var frames_list = std.ArrayList(*MinimalFrame).empty;
        try frames_list.ensureTotalCapacity(arena_allocator, 16);

        return Self{
            .frames = frames_list,
            .storage = std.AutoHashMap(StorageSlotKey, u256).init(arena_allocator),
            .transient_storage = std.AutoHashMap(StorageSlotKey, u256).init(arena_allocator),
            .original_storage = std.AutoHashMap(StorageSlotKey, u256).init(arena_allocator),
            .balances = std.AutoHashMap(Address, u256).init(arena_allocator),
            .nonces = std.AutoHashMap(Address, u64).init(arena_allocator),
            .code = std.AutoHashMap(Address, []const u8).init(arena_allocator),
            .created_accounts = std.AutoHashMap(Address, void).init(arena_allocator),
            .selfdestructed_accounts = std.AutoHashMap(Address, void).init(arena_allocator),
            .warm_addresses = .empty,
            .warm_storage_slots = .empty,
            .journal = .empty,
            .gas_refund = 0,
            .hardfork = Hardfork.DEFAULT,
            .chain_id = 1,
            .block_number = 0,
            .block_timestamp = 0,
            .block_difficulty = 0,
            .block_prevrandao = 0,
            .block_coinbase = primitives.ZERO_ADDRESS,
            .block_gas_limit = 30_000_000,
            .block_base_fee = 0,
            .blob_base_fee = 0,
            .origin = primitives.ZERO_ADDRESS,
            .gas_price = 0,
            .host = null,
            .arena = arena,
            .backing_allocator = allocator,
            .allocator = arena_allocator,
        };
    }

    /// Create a heap-allocated MinimalEvm. Release it with `deinitPtr`.
    pub fn initPtr(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = try init(allocator);
        return self;
    }

    /// Create a MinimalEvm that reads through to `host` for state it has no entry for.
    pub fn initWithHost(allocator: std.mem.Allocator, host: HostInterface) !Self {
        var self = try init(allocator);
        self.host = host;
        return self;
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        const arena = self.arena;
        const backing_allocator = self.backing_allocator;
        arena.deinit();
        backing_allocator.destroy(arena);
    }

    /// Clean up pointer-allocated MinimalEvm
    pub fn deinitPtr(self: *Self, allocator: std.mem.Allocator) void {
        self.deinit();
        allocator.destroy(self);
    }

    /// Attach read-only pre-existing state. Balance, nonce, code, storage and
    /// existence reads that miss the local maps are answered by `reader`. Writes
    /// stay local and never reach it.
    pub fn setStateReader(self: *Self, reader: StateReader) void {
        self.state_reader = reader;
    }

    /// Set blockchain context
    pub fn setBlockchainContext(
        self: *Self,
        chain_id: u64,
        block_number: u64,
        block_timestamp: u64,
        block_difficulty: u256,
        block_prevrandao: u256,
        block_coinbase: Address,
        block_gas_limit: u64,
        block_base_fee: u256,
        blob_base_fee: u256,
    ) void {
        self.chain_id = chain_id;
        self.block_number = block_number;
        self.block_timestamp = block_timestamp;
        self.block_difficulty = block_difficulty;
        self.block_prevrandao = block_prevrandao;
        self.block_coinbase = block_coinbase;
        self.block_gas_limit = block_gas_limit;
        self.block_base_fee = block_base_fee;
        self.blob_base_fee = blob_base_fee;
    }

    /// Set the recent ancestor hashes BLOCKHASH serves, newest first. The slice is
    /// borrowed and must outlive execution.
    pub fn setBlockHashes(self: *Self, block_hashes: []const [32]u8) void {
        self.block_hashes = block_hashes;
    }

    pub fn setTransactionContext(self: *Self, origin: Address, gas_price: u256) void {
        self.origin = origin;
        self.gas_price = gas_price;
    }

    /// Set the EIP-4844 blob versioned hashes for BLOBHASH. Borrowed from the transaction.
    pub fn setBlobVersionedHashes(self: *Self, hashes: []const [32]u8) void {
        self.blob_versioned_hashes = hashes;
    }

    /// Configure hardfork for gas and access list rules
    pub fn setHardfork(self: *Self, hardfork: Hardfork) void {
        self.hardfork = hardfork;
    }

    /// Set account code. The bytes are copied.
    pub fn setCode(self: *Self, address: Address, code: []const u8) !void {
        const code_copy = try self.allocator.dupe(u8, code);
        try self.journal.append(self.allocator, .{ .code = .{
            .address = address,
            .previous = self.code.get(address),
        } });
        try self.code.put(address, code_copy);
    }

    pub fn setBalance(self: *Self, address: Address, balance: u256) !void {
        try self.journal.append(self.allocator, .{ .balance = .{
            .address = address,
            .previous = self.balances.get(address),
        } });
        try self.balances.put(address, balance);
    }

    /// Set an account's nonce.
    pub fn setNonce(self: *Self, address: Address, nonce: u64) !void {
        try self.journal.append(self.allocator, .{ .nonce = .{
            .address = address,
            .previous = self.nonces.get(address),
        } });
        try self.nonces.put(address, nonce);
    }

    /// Set a storage slot without recording it as a write of the current
    /// transaction: the value becomes the slot's original value (EIP-2200).
    pub fn setStorage(self: *Self, address: Address, slot: u256, value: u256) !void {
        const key = StorageSlotKey{ .address = address, .slot = slot };
        try self.journal.append(self.allocator, .{ .storage = .{
            .key = key,
            .previous = self.storage.get(key),
        } });
        try self.storage.put(key, value);
    }

    /// Nonce of an account; 0 when neither the local maps nor the reader know one.
    pub fn get_nonce(self: *Self, address: Address) u64 {
        if (self.nonces.get(address)) |nonce| return nonce;
        if (self.state_reader) |reader| return reader.getNonce(address);
        return 0;
    }

    /// Record that `address` was created in the current transaction (EIP-6780).
    pub fn markCreated(self: *Self, address: Address) !void {
        try self.journal.ensureUnusedCapacity(self.allocator, 1);
        const entry = try self.created_accounts.getOrPut(address);
        if (!entry.found_existing) self.journal.appendAssumeCapacity(.{ .created = address });
    }

    /// True when `address` was created in the current transaction.
    pub fn wasCreatedInTransaction(self: *Self, address: Address) bool {
        return self.created_accounts.contains(address);
    }

    /// Record that `address` ran SELFDESTRUCT in the current transaction. Returns true
    /// the first time, false when it had already done so.
    pub fn markSelfdestructed(self: *Self, address: Address) !bool {
        try self.journal.ensureUnusedCapacity(self.allocator, 1);
        const entry = try self.selfdestructed_accounts.getOrPut(address);
        if (!entry.found_existing) self.journal.appendAssumeCapacity(.{ .selfdestructed = address });
        return !entry.found_existing;
    }

    pub fn access_address(self: *Self, address: Address) !u64 {
        if (self.hardfork.isBefore(.BERLIN)) {
            @branchHint(.cold);
            return GasConstants.CallCodeCost;
        }

        const entry = try self.warm_addresses.getOrPut(self.allocator, address);
        return if (entry.found_existing)
            GasConstants.WarmStorageReadCost
        else
            GasConstants.ColdAccountAccessCost;
    }

    /// Access a storage slot and return the gas cost (EIP-2929 warm/cold)
    pub fn access_storage_slot(self: *Self, contract_address: Address, slot: u256) !u64 {
        if (self.hardfork.isBefore(.BERLIN)) {
            @branchHint(.cold);
            return GasConstants.SloadGas;
        }

        const key = StorageSlotKey{ .address = contract_address, .slot = slot };
        const entry = try self.warm_storage_slots.getOrPut(self.allocator, key);
        return if (entry.found_existing)
            GasConstants.WarmStorageReadCost
        else
            GasConstants.ColdSloadCost;
    }

    /// Current position of the state journal.
    pub fn checkpoint(self: *const Self) Checkpoint {
        return .{
            .journal_len = self.journal.items.len,
            .warm_addresses = self.warm_addresses.count(),
            .warm_storage_slots = self.warm_storage_slots.count(),
            .gas_refund = self.gas_refund,
        };
    }

    /// Undo every state change, warm-set addition and refund made after `mark`.
    /// It allocates nothing and cannot fail.
    pub fn revertTo(self: *Self, mark: Checkpoint) void {
        while (self.journal.items.len > mark.journal_len) {
            const entry = self.journal.items[self.journal.items.len - 1];
            self.journal.items.len -= 1;
            switch (entry) {
                .storage => |change| restoreEntry(&self.storage, change.key, change.previous),
                .transient => |change| restoreEntry(&self.transient_storage, change.key, change.previous),
                .balance => |change| restoreEntry(&self.balances, change.address, change.previous),
                .nonce => |change| restoreEntry(&self.nonces, change.address, change.previous),
                .code => |change| restoreEntry(&self.code, change.address, change.previous),
                .created => |address| _ = self.created_accounts.remove(address),
                .selfdestructed => |address| _ = self.selfdestructed_accounts.remove(address),
            }
        }
        if (self.warm_addresses.count() > mark.warm_addresses) {
            self.warm_addresses.shrinkRetainingCapacity(mark.warm_addresses);
        }
        if (self.warm_storage_slots.count() > mark.warm_storage_slots) {
            self.warm_storage_slots.shrinkRetainingCapacity(mark.warm_storage_slots);
        }
        self.gas_refund = mark.gas_refund;
    }

    /// Put `previous` back into `map`, or drop the entry when there was none.
    fn restoreEntry(map: anytype, key: anytype, previous: anytype) void {
        if (previous) |value| {
            if (map.getPtr(key)) |slot| slot.* = value;
            return;
        }
        _ = map.remove(key);
    }

    /// Forget everything scoped to one transaction. Runs on every exit of `execute`,
    /// failures included, so a reused instance starts the next transaction clean.
    fn endTransaction(self: *Self) void {
        self.warm_addresses.clearRetainingCapacity();
        self.warm_storage_slots.clearRetainingCapacity();
        self.transient_storage.clearRetainingCapacity();
        self.created_accounts.clearRetainingCapacity();
        self.selfdestructed_accounts.clearRetainingCapacity();
        self.original_storage.clearRetainingCapacity();
        self.journal.clearRetainingCapacity();
        self.gas_refund = 0;
    }

    /// Pre-warm addresses for transaction initialization
    fn pre_warm_addresses(self: *Self, addresses: []const Address) !void {
        for (addresses) |address| {
            _ = try self.warm_addresses.getOrPut(self.allocator, address);
        }
    }

    /// Warm what EIP-2929 and EIP-3651 start a transaction with: origin, target,
    /// coinbase (Shanghai+) and every precompile of the active fork, including the
    /// Prague BLS12-381 range and Osaka's P256VERIFY at 0x100.
    fn pre_warm_transaction(self: *Self, target: Address) Error!void {
        var warm: [3]Address = undefined;
        var count: usize = 0;

        warm[count] = self.origin;
        count += 1;

        if (!target.equals(primitives.ZERO_ADDRESS)) {
            warm[count] = target;
            count += 1;
        }

        if (self.hardfork.isAtLeast(.SHANGHAI)) {
            @branchHint(.likely);
            warm[count] = self.block_coinbase;
            count += 1;
        }

        try self.pre_warm_addresses(warm[0..count]);

        if (!self.hardfork.isAtLeast(.BERLIN)) return;

        const last = precompiles.lastContiguousPrecompile(self.hardfork);
        var index: u16 = 0x01;
        while (index <= last) : (index += 1) {
            const address = primitives.Address.fromU256(index);
            if (self.is_precompile(address)) try self.pre_warm_addresses(&.{address});
        }
        if (self.is_precompile(precompiles.P256VERIFY_ADDRESS)) {
            try self.pre_warm_addresses(&.{precompiles.P256VERIFY_ADDRESS});
        }
    }

    /// Execute bytecode (main entry point like evm.execute)
    pub fn execute(
        self: *Self,
        bytecode: []const u8,
        gas: i64,
        caller: Address,
        address: Address,
        value: u256,
        calldata: []const u8,
    ) Error!CallResult {
        defer self.endTransaction();
        const failure = CallResult{ .success = false, .gas_left = 0, .output = &[_]u8{} };

        // Pre-warm transaction, including precompiles depending on hardfork
        try self.pre_warm_transaction(address);

        const intrinsic_gas: i64 = @intCast(GasConstants.TxGas);
        if (gas < intrinsic_gas) {
            @branchHint(.cold);
            return failure;
        }
        const execution_gas = gas - intrinsic_gas;
        const execution_gas_limit: u64 = @as(u64, @intCast(execution_gas));

        const mark = self.checkpoint();
        errdefer self.revertTo(mark);

        const frame = try self.allocator.create(MinimalFrame);
        frame.* = try MinimalFrame.init(
            self.allocator,
            bytecode,
            execution_gas,
            caller,
            address,
            value,
            calldata,
            @as(*anyopaque, @ptrCast(self)),
            self.hardfork,
        );

        try self.frames.append(self.allocator, frame);
        defer _ = self.frames.pop();

        frame.execute() catch |err| {
            if (err == error.OutOfMemory) return err;
            // An exceptional halt consumes all gas and undoes the transaction's changes.
            log.debug("MinimalEvm frame execution failed: {}", .{err});
            self.revertTo(mark);
            return failure;
        };

        const output = try self.allocator.dupe(u8, frame.output);
        var gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
        if (frame.reverted) {
            self.revertTo(mark);
            return CallResult{ .success = false, .gas_left = gas_left, .output = output };
        }

        // The refund cap is based on total gas used, intrinsic gas included.
        const execution_gas_used = if (execution_gas_limit > gas_left) execution_gas_limit - gas_left else 0;
        const total_gas_used = GasConstants.TxGas + execution_gas_used;
        // Pre-London: refund up to half of gas used; post-London: up to one fifth.
        const refund_quotient: u64 = if (self.hardfork.isBefore(.LONDON)) 2 else 5;
        gas_left += @min(self.gas_refund, total_gas_used / refund_quotient);

        return CallResult{ .success = true, .gas_left = gas_left, .output = output };
    }

    /// Execute a precompile call
    fn execute_precompile(
        self: *Self,
        address: Address,
        input: []const u8,
        gas: u64,
    ) Error!CallResult {
        const result = precompiles.execute(self.allocator, address, input, gas, self.hardfork) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            // A failed precompile consumes all the gas it was given.
            log.debug("MinimalEvm precompile execution failed: {}", .{err});
            return CallResult{
                .success = false,
                .gas_left = 0,
                .output = &[_]u8{},
            };
        };

        // Calculate gas left after precompile execution
        const gas_left = if (result.gas_used <= gas) gas - result.gas_used else 0;

        // Output is already allocated by precompile, just use it
        // (arena allocator will clean it up)
        return CallResult{
            .success = true,
            .gas_left = gas_left,
            .output = result.output,
        };
    }

    /// Handle a CALL from a frame (like evm.inner_call). The callee runs in a static
    /// context when the calling frame does.
    pub fn inner_call(
        self: *Self,
        address: Address,
        value: u256,
        input: []const u8,
        gas: u64,
    ) Error!CallResult {
        return self.call(.{ .kind = .call, .target = address, .value = value, .input = input, .gas = gas });
    }

    /// Handle a STATICCALL from a frame: the callee, and every frame below it, runs in a
    /// static context (EIP-214) where state-changing instructions fail.
    pub fn inner_static_call(
        self: *Self,
        address: Address,
        input: []const u8,
        gas: u64,
    ) Error!CallResult {
        return self.call(.{ .kind = .staticcall, .target = address, .input = input, .gas = gas });
    }

    /// True when a further frame may not start: the call depth limit is reached or
    /// the native stack is nearly used up.
    fn nestingExhausted(self: *const Self) bool {
        if (self.frames.items.len >= max_call_depth) return true;
        if (nativeStackExhausted()) {
            @branchHint(.cold);
            const depth = self.frames.items.len;
            log.debug("MinimalEvm: nested frame at depth {d} refused, native stack exhausted", .{depth});
            return true;
        }
        return false;
    }

    /// Run a message call for the frame on top of the frame stack.
    ///
    /// A call that cannot start (depth limit, insufficient balance) fails and hands
    /// its gas back. A callee that halts exceptionally consumes its gas. Either way,
    /// and on REVERT, every state change of the callee is undone.
    pub fn call(self: *Self, request: CallRequest) Error!CallResult {
        const not_started = CallResult{ .success = false, .gas_left = request.gas, .output = &[_]u8{} };
        if (self.nestingExhausted()) return not_started;

        // CALLCODE and DELEGATECALL run the target's code in the current account.
        // DELEGATECALL also keeps the current frame's caller and value.
        const parent = self.getCurrentFrame();
        const current = if (parent) |frame| frame.address else self.origin;
        const inherited_caller = if (parent) |frame| frame.caller else self.origin;
        const inherited_value: u256 = if (parent) |frame| frame.value else 0;
        const inherited_static = if (parent) |frame| frame.is_static else false;
        const value: u256 = switch (request.kind) {
            .call, .callcode => request.value,
            .delegatecall => inherited_value,
            .staticcall => 0,
        };
        const transfers = request.kind == .call or request.kind == .callcode;
        if (transfers and self.get_balance(current) < value) return not_started;

        const mark = self.checkpoint();
        errdefer self.revertTo(mark);
        if (request.kind == .call) try self.transfer(current, request.target, value);

        if (self.is_precompile(request.target)) {
            const result = try self.execute_precompile(request.target, request.input, request.gas);
            if (!result.success) self.revertTo(mark);
            return result;
        }

        const code = self.get_code(request.target);
        if (code.len == 0) return CallResult{ .success = true, .gas_left = request.gas, .output = &[_]u8{} };

        const frame = try self.allocator.create(MinimalFrame);
        frame.* = try MinimalFrame.init(
            self.allocator,
            code,
            std.math.cast(i64, request.gas) orelse std.math.maxInt(i64),
            if (request.kind == .delegatecall) inherited_caller else current,
            if (request.kind == .call or request.kind == .staticcall) request.target else current,
            value,
            request.input,
            @as(*anyopaque, @ptrCast(self)),
            self.hardfork,
        );
        frame.is_static = request.kind == .staticcall or inherited_static;

        return self.runCallFrame(frame, mark);
    }

    /// Run `frame` to completion as the callee of the current frame. The callee is on
    /// the frame stack exactly while it runs and while its output is copied, so no
    /// exit path, an allocation failure included, can pop the caller's frame.
    fn runCallFrame(self: *Self, frame: *MinimalFrame, mark: Checkpoint) Error!CallResult {
        try self.frames.append(self.allocator, frame);
        defer _ = self.frames.pop();

        frame.execute() catch |err| {
            if (err == error.OutOfMemory) return err;
            log.debug("MinimalEvm nested frame halted: {}", .{err});
            self.revertTo(mark);
            return CallResult{ .success = false, .gas_left = 0, .output = &[_]u8{} };
        };

        const output: []const u8 = if (frame.output.len > 0)
            try self.allocator.dupe(u8, frame.output)
        else
            &[_]u8{};
        if (frame.reverted) self.revertTo(mark);

        return CallResult{
            .success = !frame.reverted,
            .gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0))),
            .output = output,
        };
    }

    /// Address of a contract created by CREATE: keccak256(rlp([sender, nonce]))[12..].
    fn createAddress(sender: Address, nonce: u64) Address {
        // 0x94 ++ 20-byte address, then the nonce as an RLP scalar (at most 9 bytes).
        var payload: [30]u8 = undefined;
        payload[0] = 0x94;
        @memcpy(payload[1..21], &sender.bytes);
        var len: usize = 21;
        if (nonce == 0) {
            payload[len] = 0x80;
            len += 1;
        } else if (nonce < 0x80) {
            payload[len] = @intCast(nonce);
            len += 1;
        } else {
            const nonce_bytes: usize = (64 - @as(usize, @clz(nonce)) + 7) / 8;
            payload[len] = 0x80 + @as(u8, @intCast(nonce_bytes));
            len += 1;
            var index: usize = 0;
            while (index < nonce_bytes) : (index += 1) {
                const shift: u6 = @intCast(8 * (nonce_bytes - 1 - index));
                payload[len] = @truncate(nonce >> shift);
                len += 1;
            }
        }
        var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
        hasher.update(&[_]u8{0xc0 + @as(u8, @intCast(len))});
        hasher.update(payload[0..len]);
        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        return Address{ .bytes = hash[12..32].* };
    }

    /// Address of a contract created by CREATE2 (EIP-1014).
    fn create2Address(sender: Address, salt: u256, init_code: []const u8) Address {
        var code_hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(init_code, &code_hash, .{});
        var salt_bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &salt_bytes, salt, .big);
        return primitives.Address.getCreate2Address(sender, salt_bytes, code_hash);
    }

    /// Run a CREATE or CREATE2 for the frame on top of the frame stack.
    ///
    /// A creation that cannot start (depth limit, insufficient balance, nonce at its
    /// maximum) fails and hands its gas back. An address collision or an init code
    /// that halts exceptionally consumes the gas. The sender's nonce increment
    /// survives a failed creation; every other change is undone.
    pub fn create(self: *Self, request: CreateRequest) Error!CreateResult {
        const not_started = CreateResult{ .address = null, .gas_left = request.gas, .output = &[_]u8{} };
        const consumed = CreateResult{ .address = null, .gas_left = 0, .output = &[_]u8{} };
        if (self.nestingExhausted()) return not_started;

        const sender = if (self.getCurrentFrame()) |frame| frame.address else self.origin;
        const nonce = self.get_nonce(sender);
        if (self.get_balance(sender) < request.value) return not_started;
        if (nonce == std.math.maxInt(u64)) return not_started;
        try self.setNonce(sender, nonce + 1);

        const address = if (request.salt) |salt|
            create2Address(sender, salt, request.init_code)
        else
            createAddress(sender, nonce);
        if (self.hardfork.isAtLeast(.BERLIN)) try self.pre_warm_addresses(&.{address});
        if (self.get_nonce(address) != 0 or self.get_code(address).len != 0) return consumed;

        const mark = self.checkpoint();
        errdefer self.revertTo(mark);
        try self.markCreated(address);
        if (self.hardfork.isAtLeast(.SPURIOUS_DRAGON)) try self.setNonce(address, 1);
        try self.transfer(sender, address, request.value);

        const frame = try self.allocator.create(MinimalFrame);
        frame.* = try MinimalFrame.init(
            self.allocator,
            request.init_code,
            std.math.cast(i64, request.gas) orelse std.math.maxInt(i64),
            sender,
            address,
            request.value,
            &[_]u8{},
            @as(*anyopaque, @ptrCast(self)),
            self.hardfork,
        );

        const result = try self.runCallFrame(frame, mark);
        if (!result.success) {
            return CreateResult{ .address = null, .gas_left = result.gas_left, .output = result.output };
        }

        const deposit = self.codeDeposit(result.output, result.gas_left) orelse {
            self.revertTo(mark);
            return consumed;
        };
        try self.setCode(address, deposit.code);
        return CreateResult{ .address = address, .gas_left = deposit.gas_left, .output = &[_]u8{} };
    }

    const CodeDeposit = struct { code: []const u8, gas_left: u64 };

    /// The code a successful init code deploys and the gas left after paying its
    /// deposit, or null when the creation fails: oversized code (EIP-170), a leading
    /// 0xEF byte (EIP-3541), or a deposit the init code cannot pay from Homestead on.
    /// On Frontier an unaffordable deposit keeps the gas and deploys no code.
    fn codeDeposit(self: *const Self, code: []const u8, gas_left: u64) ?CodeDeposit {
        if (self.hardfork.isAtLeast(.SPURIOUS_DRAGON) and code.len > max_code_size) return null;
        if (self.hardfork.isAtLeast(.LONDON) and code.len > 0 and code[0] == 0xEF) return null;
        const cost = std.math.mul(u64, GasConstants.CreateDataGas, code.len) catch return null;
        if (gas_left >= cost) return .{ .code = code, .gas_left = gas_left - cost };
        if (self.hardfork.isAtLeast(.HOMESTEAD)) return null;
        return .{ .code = &[_]u8{}, .gas_left = gas_left };
    }

    /// Move `value` from `from` to `to`. Fails without changing anything when `from`
    /// cannot pay.
    fn transfer(self: *Self, from: Address, to: Address, value: u256) Error!void {
        if (value == 0 or from.equals(to)) return;
        const from_balance = self.get_balance(from);
        if (from_balance < value) return Error.InsufficientBalance;
        try self.setBalance(from, from_balance - value);
        try self.setBalance(to, self.get_balance(to) +% value);
    }

    /// Get balance of an address (called by frame)
    pub fn get_balance(self: *Self, address: Address) u256 {
        if (self.balances.get(address)) |balance| return balance;
        if (self.state_reader) |reader| return reader.getBalance(address);
        if (self.host) |host| return host.getBalance(address);
        return 0;
    }

    /// Get code for an address
    pub fn get_code(self: *Self, address: Address) []const u8 {
        if (self.code.get(address)) |code| return code;
        if (self.state_reader) |reader| return reader.getCode(address);
        if (self.host) |host| return host.getCode(address);
        return &[_]u8{};
    }

    /// True when the account exists: it has a balance, a nonce or code, was created
    /// in this transaction, or the reader reports it.
    pub fn account_exists(self: *Self, address: Address) bool {
        if (self.created_accounts.contains(address)) return true;
        if (!self.is_empty(address)) return true;
        if (self.state_reader) |reader| return reader.accountExists(address);
        return false;
    }

    /// True when the account is empty in the EIP-161 sense: no nonce, no balance, no code.
    pub fn is_empty(self: *Self, address: Address) bool {
        return self.get_nonce(address) == 0 and
            self.get_balance(address) == 0 and
            self.get_code(address).len == 0;
    }

    /// Storage value the state behind MinimalEvm holds for a slot with no local entry.
    fn backingStorage(self: *Self, address: Address, slot: u256) u256 {
        if (self.state_reader) |reader| return reader.getStorage(address, slot);
        if (self.host) |host| return host.getStorage(address, slot);
        return 0;
    }

    /// Get storage value (called by frame)
    pub fn get_storage(self: *Self, address: Address, slot: u256) u256 {
        const key = StorageSlotKey{ .address = address, .slot = slot };
        if (self.storage.get(key)) |value| return value;
        return self.backingStorage(address, slot);
    }

    /// Get EIP-1153 transient storage value (separate from persistent storage)
    pub fn get_transient_storage(self: *Self, address: Address, slot: u256) u256 {
        const key = StorageSlotKey{ .address = address, .slot = slot };
        return self.transient_storage.get(key) orelse 0;
    }

    /// Set EIP-1153 transient storage value (separate from persistent storage)
    pub fn set_transient_storage(self: *Self, address: Address, slot: u256, value: u256) Error!void {
        const key = StorageSlotKey{ .address = address, .slot = slot };
        try self.journal.append(self.allocator, .{ .transient = .{
            .key = key,
            .previous = self.transient_storage.get(key),
        } });
        try self.transient_storage.put(key, value);
    }

    /// Set storage value (called by frame). The write stays local; the value the
    /// slot had before the transaction's first write is kept for EIP-2200.
    pub fn set_storage(self: *Self, address: Address, slot: u256, value: u256) Error!void {
        const key = StorageSlotKey{ .address = address, .slot = slot };
        const previous = self.storage.get(key);

        if (!self.original_storage.contains(key)) {
            try self.original_storage.put(key, previous orelse self.backingStorage(address, slot));
        }

        try self.journal.append(self.allocator, .{ .storage = .{ .key = key, .previous = previous } });
        try self.storage.put(key, value);
    }

    /// Get original storage value (before transaction modifications)
    pub fn get_original_storage(self: *Self, address: Address, slot: u256) u256 {
        const key = StorageSlotKey{ .address = address, .slot = slot };
        // If we have tracked the original, return it
        if (self.original_storage.get(key)) |original| {
            return original;
        }
        // Otherwise return current value (unchanged in this transaction)
        return self.get_storage(address, slot);
    }

    /// Add gas refund
    pub fn add_refund(self: *Self, amount: u64) void {
        self.gas_refund +%= amount;
    }

    /// Check if an address is a precompile
    pub fn is_precompile(self: *const Self, address: Address) bool {
        return precompiles.isPrecompile(address, self.hardfork);
    }

    /// Get current frame (top of the frame stack)
    pub fn getCurrentFrame(self: *const Self) ?*MinimalFrame {
        if (self.frames.items.len > 0) {
            return self.frames.items[self.frames.items.len - 1];
        }
        return null;
    }

    /// Get current frame's PC (for tracer)
    pub fn getPC(self: *const Self) u32 {
        if (self.getCurrentFrame()) |frame| {
            return frame.pc;
        }
        return 0;
    }

    /// Get current frame's bytecode (for tracer)
    pub fn getBytecode(self: *const Self) []const u8 {
        if (self.getCurrentFrame()) |frame| {
            return frame.bytecode;
        }
        return &[_]u8{};
    }

    /// Execute a single step (for tracer). An error is the exceptional halt of the
    /// current frame; the caller decides how to report it.
    pub fn step(self: *Self) !void {
        if (self.getCurrentFrame()) |frame| {
            try frame.step();
        }
    }
};

test "MinimalEvm: unbounded recursion on a 2 MiB thread fails the call instead of overflowing the stack" {
    const Job = struct {
        success: bool = false,
        failure: ?anyerror = null,

        fn run(job: *@This()) void {
            job.execute() catch |err| {
                job.failure = err;
            };
        }

        fn execute(job: *@This()) !void {
            var evm = try MinimalEvm.init(std.testing.allocator);
            defer evm.deinit();
            // PUSH1 0 x5, ADDRESS, GAS, CALL, STOP: the contract calls itself until gas
            // or the call depth runs out.
            const code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x30, 0x5a, 0xf1, 0x00 };
            var contract = Address{ .bytes = @splat(0) };
            contract.bytes[19] = 0xc3;
            var caller = Address{ .bytes = @splat(0) };
            caller.bytes[19] = 0xa1;
            try evm.setCode(contract, &code);
            const result = try evm.execute(&code, 16_000_000, caller, contract, 0, &.{});
            job.success = result.success;
        }
    };
    var job = Job{};
    const thread = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, Job.run, .{&job});
    thread.join();
    if (job.failure) |err| return err;
    // The outermost frame completes: a refused nested call only pushes 0.
    try std.testing.expect(job.success);
}

test "W3-2: MinimalEvm returned by value through stack frames keeps a valid arena" {
    const testing = std.testing;
    const account = Address{ .bytes = @as([20]u8, @splat(0xA2)) };

    const Factory = struct {
        fn inner(allocator: std.mem.Allocator, owner: Address) !MinimalEvm {
            var evm = try MinimalEvm.init(allocator);
            errdefer evm.deinit();
            try evm.setStorage(owner, 0, 7);
            return evm;
        }

        fn outer(allocator: std.mem.Allocator, owner: Address) !MinimalEvm {
            // A frame of a different size, so the value moves between stack addresses.
            var scratch: [4096]u8 = undefined;
            @memset(&scratch, 0xA5);
            const evm = try inner(allocator, owner);
            if (scratch[17] != 0xA5) return error.TestUnexpectedResult;
            return evm;
        }

        /// Overwrite the stack region the factory frames used.
        fn clobber(seed: u8) u64 {
            var junk: [16384]u8 = undefined;
            @memset(&junk, seed);
            var sum: u64 = 0;
            for (junk) |byte| sum += byte;
            return sum;
        }
    };

    const first = try Factory.outer(testing.allocator, account);
    try testing.expectEqual(@as(u64, 16384 * 0x5A), Factory.clobber(0x5A));
    // Move the value once more; only `evm` is used and released from here on.
    var evm = first;
    defer evm.deinit();
    evm.setHardfork(.CANCUN);

    // Grow every map well past its first allocation, long after `init` returned.
    for (0..512) |index| {
        try evm.setStorage(account, index, index + 1);
        var holder = Address{ .bytes = @as([20]u8, @splat(0)) };
        std.mem.writeInt(u16, holder.bytes[18..20], @intCast(index + 1), .big);
        try evm.setBalance(holder, index);
        try evm.setNonce(holder, index);
    }
    try testing.expectEqual(@as(u64, 16384 * 0x33), Factory.clobber(0x33));
    for (0..512) |index| {
        try testing.expectEqual(@as(u256, index + 1), evm.get_storage(account, index));
    }

    // PUSH1 0x2a, PUSH2 0x0300, SSTORE: a storage write made by executing code.
    const code = [_]u8{ 0x60, 0x2a, 0x61, 0x03, 0x00, 0x55 };
    try evm.setCode(account, &code);
    const result = try evm.execute(&code, 100_000, primitives.ZERO_ADDRESS, account, 0, &.{});
    try testing.expect(result.success);
    try testing.expectEqual(@as(u256, 0x2a), evm.get_storage(account, 0x0300));
    try testing.expectEqual(@as(u256, 512), evm.get_storage(account, 511));
}

test "W3-2: MinimalEvm.init releases everything when an allocation fails" {
    const testing = std.testing;
    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var evm = MinimalEvm.init(failing.allocator()) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        evm.deinit();
        try testing.expect(!failing.has_induced_failure);
        break;
    }
    try testing.expect(fail_index > 0);

    fail_index = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const evm = MinimalEvm.initPtr(failing.allocator()) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        evm.deinitPtr(failing.allocator());
        break;
    }
    try testing.expect(fail_index > 0);
}

test "W3-13: a nested call that reverts or halts restores MinimalEvm storage and balances" {
    const testing = std.testing;
    const origin = Address{ .bytes = @as([20]u8, @splat(0x01)) };
    const parent = Address{ .bytes = @as([20]u8, @splat(0xAA)) };
    const child = Address{ .bytes = @as([20]u8, @splat(0xBB)) };

    // SSTORE(1, 5); CALL(gas, child, value 5, no data); SSTORE(2, call result); STOP
    const parent_code = [_]u8{ 0x60, 0x05, 0x60, 0x01, 0x55 } ++
        [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x05, 0x73 } ++
        @as([20]u8, @splat(0xBB)) ++ [_]u8{ 0x5a, 0xf1, 0x60, 0x02, 0x55, 0x00 };
    // SSTORE(0, 0x2a), then REVERT, INVALID or STOP.
    const child_reverts = [_]u8{ 0x60, 0x2a, 0x60, 0x00, 0x55, 0x60, 0x00, 0x60, 0x00, 0xfd };
    const child_halts = [_]u8{ 0x60, 0x2a, 0x60, 0x00, 0x55, 0xfe };
    const child_succeeds = [_]u8{ 0x60, 0x2a, 0x60, 0x00, 0x55, 0x00 };

    const Case = struct { code: []const u8, kept: bool };
    const cases = [_]Case{
        .{ .code = &child_reverts, .kept = false },
        .{ .code = &child_halts, .kept = false },
        .{ .code = &child_succeeds, .kept = true },
    };
    for (cases) |case| {
        var evm = try MinimalEvm.init(testing.allocator);
        defer evm.deinit();
        evm.setHardfork(.CANCUN);
        evm.setTransactionContext(origin, 0);
        try evm.setCode(parent, &parent_code);
        try evm.setCode(child, case.code);
        try evm.setBalance(parent, 100);
        try evm.setStorage(child, 0, 9);

        const result = try evm.execute(&parent_code, 1_000_000, origin, parent, 0, &.{});
        try testing.expect(result.success);
        // The parent's own write survives whatever the child did.
        try testing.expectEqual(@as(u256, 5), evm.get_storage(parent, 1));
        try testing.expectEqual(@as(u256, @intFromBool(case.kept)), evm.get_storage(parent, 2));
        try testing.expectEqual(@as(u256, if (case.kept) 0x2a else 9), evm.get_storage(child, 0));
        try testing.expectEqual(@as(u256, if (case.kept) 95 else 100), evm.get_balance(parent));
        try testing.expectEqual(@as(u256, if (case.kept) 5 else 0), evm.get_balance(child));
    }
}

test "W3-13: a reused MinimalEvm meters SSTORE like a fresh one after every kind of exit" {
    const testing = std.testing;
    const origin = Address{ .bytes = @as([20]u8, @splat(0x01)) };
    const contract = Address{ .bytes = @as([20]u8, @splat(0xC3)) };

    const write_then_halt = [_]u8{ 0x60, 0x07, 0x60, 0x00, 0x55, 0xfe };
    const set_one = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55 };
    const set_two = [_]u8{ 0x60, 0x02, 0x60, 0x00, 0x55 };
    const clear = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x55 };

    var reused = try MinimalEvm.init(testing.allocator);
    defer reused.deinit();
    reused.setHardfork(.CANCUN);
    reused.setTransactionContext(origin, 0);

    // An exceptional halt: the write is undone and nothing of the transaction is kept.
    const halted = try reused.execute(&write_then_halt, 100_000, origin, contract, 0, &.{});
    try testing.expect(!halted.success);
    try testing.expectEqual(@as(u256, 0), reused.get_storage(contract, 0));
    try testing.expectEqual(@as(usize, 0), reused.original_storage.count());
    try testing.expectEqual(@as(u64, 0), reused.gas_refund);

    // Each step runs on the reused instance and on a fresh one that starts from the
    // same committed value of slot 0.
    const Step = struct { code: []const u8, slot_before: u256, gas_left: ?u64 };
    const steps = [_]Step{
        // 0 -> 1: 20000 + 2100 cold.
        .{ .code = &set_one, .slot_before = 0, .gas_left = 100_000 - 21_000 - 6 - 22_100 },
        // 1 -> 2 with original 1: 2900 + 2100 cold. A stale original of 0 would cost 2200.
        .{ .code = &set_two, .slot_before = 1, .gas_left = 100_000 - 21_000 - 6 - 5_000 },
        // 2 -> 0 earns a refund; the counter must not leak into the next transaction.
        .{ .code = &clear, .slot_before = 2, .gas_left = null },
        .{ .code = &set_one, .slot_before = 0, .gas_left = 100_000 - 21_000 - 6 - 22_100 },
    };
    for (steps) |step| {
        try testing.expectEqual(step.slot_before, reused.get_storage(contract, 0));
        const again = try reused.execute(step.code, 100_000, origin, contract, 0, &.{});

        var fresh = try MinimalEvm.init(testing.allocator);
        defer fresh.deinit();
        fresh.setHardfork(.CANCUN);
        fresh.setTransactionContext(origin, 0);
        if (step.slot_before != 0) try fresh.setStorage(contract, 0, step.slot_before);
        const once = try fresh.execute(step.code, 100_000, origin, contract, 0, &.{});

        try testing.expect(again.success);
        try testing.expect(once.success);
        try testing.expectEqual(once.gas_left, again.gas_left);
        if (step.gas_left) |expected| try testing.expectEqual(expected, again.gas_left);
        try testing.expectEqual(@as(usize, 0), reused.original_storage.count());
        try testing.expectEqual(@as(u64, 0), reused.gas_refund);
        try testing.expectEqual(@as(usize, 0), reused.journal.items.len);
    }
}

test "W3-13: the precompiles of the active fork start warm, Prague BLS and Osaka P256VERIFY included" {
    const testing = std.testing;
    const origin = Address{ .bytes = @as([20]u8, @splat(0x01)) };
    const contract = Address{ .bytes = @as([20]u8, @splat(0xC3)) };

    const Case = struct { hardfork: Hardfork, address: u16, warm: bool };
    const cases = [_]Case{
        .{ .hardfork = .BERLIN, .address = 0x09, .warm = true },
        .{ .hardfork = .BERLIN, .address = 0x0a, .warm = false },
        .{ .hardfork = .CANCUN, .address = 0x0a, .warm = true },
        .{ .hardfork = .CANCUN, .address = 0x0b, .warm = false },
        .{ .hardfork = .PRAGUE, .address = 0x0b, .warm = true },
        .{ .hardfork = .PRAGUE, .address = 0x11, .warm = true },
        .{ .hardfork = .PRAGUE, .address = 0x12, .warm = false },
        .{ .hardfork = .PRAGUE, .address = 0x100, .warm = false },
        .{ .hardfork = .OSAKA, .address = 0x11, .warm = true },
        .{ .hardfork = .OSAKA, .address = 0x100, .warm = true },
        .{ .hardfork = .OSAKA, .address = 0x101, .warm = false },
    };
    for (cases) |case| {
        var evm = try MinimalEvm.init(testing.allocator);
        defer evm.deinit();
        evm.setHardfork(case.hardfork);
        evm.setTransactionContext(origin, 0);

        // PUSH20 address, BALANCE: 3 gas plus the warm (100) or cold (2600) access.
        var code: [22]u8 = undefined;
        code[0] = 0x73;
        const queried = primitives.Address.fromU256(case.address);
        @memcpy(code[1..21], &queried.bytes);
        code[21] = 0x31;
        const result = try evm.execute(&code, 100_000, origin, contract, 0, &.{});
        try testing.expect(result.success);
        const access: u64 = if (case.warm) 100 else 2600;
        try testing.expectEqual(@as(u64, 100_000 - 21_000 - 3) - access, result.gas_left);
    }
}

test "W3-13: an allocation failure while a nested call returns leaves the caller's frame on top" {
    const testing = std.testing;
    const caller = Address{ .bytes = @as([20]u8, @splat(0x01)) };
    const parent_address = Address{ .bytes = @as([20]u8, @splat(0xAA)) };
    const child = Address{ .bytes = @as([20]u8, @splat(0xBB)) };
    // PUSH3 0x040000, PUSH1 0, RETURN: 256 KiB of output, so the child's output and
    // its copy for the caller each need fresh memory from the backing allocator.
    const child_code = [_]u8{ 0x62, 0x04, 0x00, 0x00, 0x60, 0x00, 0xf3 };
    const parent_code = [_]u8{0x00};

    const Setup = struct {
        fn pushParent(evm: *MinimalEvm, code: []const u8, from: Address, at: Address) !*MinimalFrame {
            const frame = try evm.allocator.create(MinimalFrame);
            frame.* = try MinimalFrame.init(evm.allocator, code, 1_000_000, from, at, 0, &.{}, evm, .CANCUN);
            try evm.frames.append(evm.allocator, frame);
            return frame;
        }
    };

    var failed_calls: usize = 0;
    var completed = false;
    var fail_index: usize = 0;
    while (fail_index < 256 and !completed) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const evm = MinimalEvm.initPtr(failing.allocator()) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        defer evm.deinitPtr(failing.allocator());
        evm.setHardfork(.CANCUN);
        evm.setCode(child, &child_code) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        const parent = Setup.pushParent(evm, &parent_code, caller, parent_address) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };

        const result = evm.call(.{ .kind = .call, .target = child, .input = &.{}, .gas = 1_000_000 }) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            // The child is gone and the caller is still the current frame.
            try testing.expectEqual(@as(usize, 1), evm.frames.items.len);
            try testing.expect(evm.getCurrentFrame().? == parent);
            failed_calls += 1;
            continue;
        };
        try testing.expect(result.success);
        try testing.expectEqual(@as(usize, 0x040000), result.output.len);
        try testing.expectEqual(@as(usize, 1), evm.frames.items.len);
        try testing.expect(evm.getCurrentFrame().? == parent);
        completed = !failing.has_induced_failure;
    }
    try testing.expect(completed);
    try testing.expect(failed_calls > 0);
}
