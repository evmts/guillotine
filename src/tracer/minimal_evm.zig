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

const Address = primitives.Address.Address;

// Re-export host types for compatibility
pub const HostInterface = minimal_host.HostInterface;
pub const CallResult = minimal_host.CallResult;
pub const Host = minimal_host.Host;

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

    frames: std.ArrayList(*MinimalFrame),
    storage: std.AutoHashMap(StorageSlotKey, u256),
    transient_storage: std.AutoHashMap(StorageSlotKey, u256),
    original_storage: std.AutoHashMap(StorageSlotKey, u256),
    balances: std.AutoHashMap(Address, u256),
    code: std.AutoHashMap(Address, []const u8),
    nonces: std.AutoHashMap(Address, u64),
    // EIP-2929 warm/cold tracking (minimal)
    warm_addresses: std.array_hash_map.ArrayHashMap(Address, void, AddressContext, false),
    warm_storage_slots: std.array_hash_map.ArrayHashMap(StorageSlotKey, void, StorageSlotKeyContext, false),

    // Transaction-scoped gas refund counter
    gas_refund: u64,

    // Active hardfork configuration for gas rules
    hardfork: Hardfork,

    // Blockchain context
    chain_id: u64,
    block_number: u64,
    block_timestamp: u64,
    block_difficulty: u256,
    block_prevrandao: u256,
    block_coinbase: Address,
    block_gas_limit: u64,
    block_base_fee: u256,
    blob_base_fee: u256,
    origin: Address,
    gas_price: u256,
    host: ?HostInterface,
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Self {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        const storage_map = std.AutoHashMap(StorageSlotKey, u256).init(arena_allocator);
        const transient_storage_map = std.AutoHashMap(StorageSlotKey, u256).init(arena_allocator);
        const balances_map = std.AutoHashMap(Address, u256).init(arena_allocator);
        const code_map = std.AutoHashMap(Address, []const u8).init(arena_allocator);
        const nonces_map = std.AutoHashMap(Address, u64).init(arena_allocator);
        const warm_addresses = std.array_hash_map.ArrayHashMap(Address, void, AddressContext, false).init(arena_allocator);
        const warm_storage_slots = std.array_hash_map.ArrayHashMap(StorageSlotKey, void, StorageSlotKeyContext, false).init(arena_allocator);
        var frames_list = std.ArrayList(*MinimalFrame){};
        try frames_list.ensureTotalCapacity(arena_allocator, 16);

        const original_storage_map = std.AutoHashMap(StorageSlotKey, u256).init(arena_allocator);

        return Self{
            .frames = frames_list,
            .storage = storage_map,
            .transient_storage = transient_storage_map,
            .original_storage = original_storage_map,
            .balances = balances_map,
            .code = code_map,
            .nonces = nonces_map,
            .warm_addresses = warm_addresses,
            .warm_storage_slots = warm_storage_slots,
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
            .allocator = arena_allocator,
        };
    }

    /// Initialize as a pointer to avoid arena corruption from struct copies
    /// @deprecated Use init() with proper lifetime management instead
    pub fn initPtr(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();

        const arena_allocator = self.arena.allocator();

        self.frames = std.ArrayList(*MinimalFrame){}; // Unmanaged ArrayList, default init
        self.storage = std.AutoHashMap(StorageSlotKey, u256).init(arena_allocator);
        self.transient_storage = std.AutoHashMap(StorageSlotKey, u256).init(arena_allocator);
        self.original_storage = std.AutoHashMap(StorageSlotKey, u256).init(arena_allocator);
        self.balances = std.AutoHashMap(Address, u256).init(arena_allocator);
        self.code = std.AutoHashMap(Address, []const u8).init(arena_allocator);
        self.nonces = std.AutoHashMap(Address, u64).init(arena_allocator);
        self.warm_addresses = std.array_hash_map.ArrayHashMap(Address, void, AddressContext, false).init(arena_allocator);
        self.warm_storage_slots = std.array_hash_map.ArrayHashMap(StorageSlotKey, void, StorageSlotKeyContext, false).init(arena_allocator);
        self.gas_refund = 0;
        self.hardfork = Hardfork.DEFAULT;
        self.chain_id = 1;
        self.block_number = 0;
        self.block_timestamp = 0;
        self.block_difficulty = 0;
        self.block_prevrandao = 0;
        self.block_coinbase = primitives.ZERO_ADDRESS;
        self.block_gas_limit = 30_000_000;
        self.block_base_fee = 0;
        self.blob_base_fee = 0;
        self.origin = primitives.ZERO_ADDRESS;
        self.gas_price = 0;
        self.host = null;
        self.allocator = arena_allocator;

        return self;
    }

    /// Initialize with a host interface
    pub fn initWithHost(allocator: std.mem.Allocator, host: HostInterface) !Self {
        var self = try init(allocator);
        self.host = host;
        return self;
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Clean up pointer-allocated MinimalEvm
    pub fn deinitPtr(self: *Self, allocator: std.mem.Allocator) void {
        self.deinit();
        allocator.destroy(self);
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

    pub fn setTransactionContext(self: *Self, origin: Address, gas_price: u256) void {
        self.origin = origin;
        self.gas_price = gas_price;
    }

    /// Configure hardfork for gas and access list rules
    pub fn setHardfork(self: *Self, hardfork: Hardfork) void {
        self.hardfork = hardfork;
    }

    /// Set account code
    pub fn setCode(self: *Self, address: Address, code: []const u8) !void {
        const code_copy = try self.allocator.alloc(u8, code.len);
        @memcpy(code_copy, code);
        try self.code.put(address, code_copy);
    }

    pub fn setBalance(self: *Self, address: Address, balance: u256) !void {
        try self.balances.put(address, balance);
    }

    pub fn setNonce(self: *Self, address: Address, nonce: u64) !void {
        try self.nonces.put(address, nonce);
    }

    pub fn get_nonce(self: *const Self, address: Address) u64 {
        return self.nonces.get(address) orelse 0;
    }

    pub fn account_exists(self: *const Self, address: Address) bool {
        if (self.balances.get(address)) |b| {
            if (b > 0) return true;
        }
        if (self.code.get(address)) |c| {
            if (c.len > 0) return true;
        }
        if (self.nonces.get(address)) |n| {
            if (n > 0) return true;
        }
        return false;
    }

    pub fn access_address(self: *Self, address: Address) !u64 {
        if (self.hardfork.isBefore(.BERLIN)) {
            @branchHint(.cold);
            return GasConstants.CallCodeCost;
        }

        const entry = try self.warm_addresses.getOrPut(address);
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
        const entry = try self.warm_storage_slots.getOrPut(key);
        return if (entry.found_existing)
            GasConstants.WarmStorageReadCost
        else
            GasConstants.ColdSloadCost;
    }

    /// Pre-warm addresses for transaction initialization
    fn pre_warm_addresses(self: *Self, addresses: []const Address) !void {
        for (addresses) |address| {
            _ = self.warm_addresses.getOrPut(address) catch {
                return Error.StorageError;
            };
        }
    }

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

        // Pre-warm origin, target, and coinbase
        try self.pre_warm_addresses(warm[0..count]);

        // Pre-warm precompiles if Berlin+
        if (!self.hardfork.isAtLeast(.BERLIN)) return;

        // Pre-warm precompile addresses (0x01 - 0x0a)
        // The range depends on hardfork - newer hardforks have more precompiles
        var precompile_addresses: [10]Address = undefined;
        var precompile_count: usize = 0;

        // Check each potential precompile address and pre-warm if active
        var i: u8 = 1;
        while (i <= 10) : (i += 1) {
            var addr_bytes: [20]u8 = [_]u8{0} ** 20;
            addr_bytes[19] = i;
            const addr = Address{ .bytes = addr_bytes };
            if (self.is_precompile(addr)) {
                precompile_addresses[precompile_count] = addr;
                precompile_count += 1;
            }
        }

        if (precompile_count > 0) {
            try self.pre_warm_addresses(precompile_addresses[0..precompile_count]);
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
        // Any storage populated before execute() is pre-transaction original state.
        self.original_storage.clearRetainingCapacity();
        // Pre-warm transaction, including precompiles depending on hardfork
        try self.pre_warm_transaction(address);

        const intrinsic_gas: i64 = @intCast(GasConstants.TxGas);
        if (gas < intrinsic_gas) {
            @branchHint(.cold);
            return CallResult{
                .success = false,
                .gas_left = 0,
                .output = &[_]u8{},
            };
        }
        const execution_gas = gas - intrinsic_gas;
        const execution_gas_limit: u64 = @as(u64, @intCast(execution_gas));

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

        // Push frame onto stack
        try self.frames.append(self.allocator, frame);
        defer _ = self.frames.pop();

        // Execute the frame
        frame.execute() catch |err| {
            // Log the error for debugging - do not swallow silently
            log.debug("MinimalEvm frame execution failed: {}", .{err});
            // Error case - return failure (arena will clean up)
            return CallResult{
                .success = false,
                .gas_left = 0,
                .output = &[_]u8{},
            };
        };

        // Frame was popped, current frame is automatically updated via getCurrentFrame()

        const output = try self.allocator.alloc(u8, frame.output.len);
        @memcpy(output, frame.output);

        var gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
        // Apply gas refund if the call was successful
        if (!frame.reverted) {
            // Calculate total gas used including intrinsic gas (TxGas)
            // The refund cap should be based on total gas used, not just execution gas
            const execution_gas_used = if (execution_gas_limit > gas_left) execution_gas_limit - gas_left else 0;
            const total_gas_used = GasConstants.TxGas + execution_gas_used;
            
            // Pre-London: refund up to half of gas used; post-London: refund up to one fifth of gas used
            const capped_refund = if (self.hardfork.isBefore(.LONDON)) blk: {
                @branchHint(.cold);
                break :blk @min(self.gas_refund, total_gas_used / 2);
            } else blk: {
                @branchHint(.likely);
                break :blk @min(self.gas_refund, total_gas_used / 5);
            };
            
            // Apply the refund
            gas_left = gas_left + capped_refund;
            self.gas_refund = 0;
        }

        // Return result
        const result = CallResult{
            .success = !frame.reverted,
            .gas_left = gas_left,
            .output = output,
        };

        // Reset transaction-scoped caches
        self.warm_addresses.clearRetainingCapacity();
        self.warm_storage_slots.clearRetainingCapacity();
        self.transient_storage.clearRetainingCapacity();
        self.original_storage.clearRetainingCapacity();

        // No cleanup needed - arena handles it
        return result;
    }

    /// Execute a precompile call
    fn execute_precompile(
        self: *Self,
        address: Address,
        input: []const u8,
        gas: u64,
    ) Error!CallResult {
        const result = precompiles.execute(self.allocator, address, input, gas, self.hardfork) catch |err| {
            // Log the error for debugging - do not swallow silently
            log.debug("MinimalEvm precompile execution failed: {}", .{err});
            // Precompile execution failed - return failure with no gas refund
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

    pub const CallKind = enum {
        call,
        callcode,
        delegatecall,
        staticcall,
    };

    pub const CreateResult = struct {
        success: bool,
        gas_left: u64,
        output: []const u8,
        created_address: ?Address,
    };

    const StateSnapshot = struct {
        storage: std.AutoHashMap(StorageSlotKey, u256),
        transient_storage: std.AutoHashMap(StorageSlotKey, u256),
        balances: std.AutoHashMap(Address, u256),
        code: std.AutoHashMap(Address, []const u8),
        nonces: std.AutoHashMap(Address, u64),
        warm_addresses: std.array_hash_map.ArrayHashMap(Address, void, AddressContext, false),
        warm_storage_slots: std.array_hash_map.ArrayHashMap(StorageSlotKey, void, StorageSlotKeyContext, false),
        gas_refund: u64,
    };

    fn takeSnapshot(self: *Self) Error!StateSnapshot {
        return StateSnapshot{
            .storage = self.storage.clone() catch return Error.AllocationError,
            .transient_storage = self.transient_storage.clone() catch return Error.AllocationError,
            .balances = self.balances.clone() catch return Error.AllocationError,
            .code = self.code.clone() catch return Error.AllocationError,
            .nonces = self.nonces.clone() catch return Error.AllocationError,
            .warm_addresses = self.warm_addresses.clone() catch return Error.AllocationError,
            .warm_storage_slots = self.warm_storage_slots.clone() catch return Error.AllocationError,
            .gas_refund = self.gas_refund,
        };
    }

    fn revertSnapshot(self: *Self, snap: StateSnapshot) void {
        self.storage = snap.storage;
        self.transient_storage = snap.transient_storage;
        self.balances = snap.balances;
        self.code = snap.code;
        self.nonces = snap.nonces;
        self.warm_addresses = snap.warm_addresses;
        self.warm_storage_slots = snap.warm_storage_slots;
        self.gas_refund = snap.gas_refund;
    }

    /// Handle inner call from frame (like evm.inner_call)
    pub fn inner_call(
        self: *Self,
        address: Address,
        value: u256,
        input: []const u8,
        gas: u64,
    ) Error!CallResult {
        const caller = if (self.getCurrentFrame()) |f| f.address else self.origin;
        const is_static = if (self.getCurrentFrame()) |f| f.is_static else false;
        return self.inner_call_ex(.call, address, address, caller, value, input, gas, is_static);
    }

    /// Handle CALL/CALLCODE/DELEGATECALL/STATICCALL with full context, static-mode,
    /// value transfer, and state rollback semantics.
    pub fn inner_call_ex(
        self: *Self,
        kind: CallKind,
        code_address: Address,
        exec_address: Address,
        caller: Address,
        value: u256,
        input: []const u8,
        gas: u64,
        is_static: bool,
    ) Error!CallResult {
        if (self.frames.items.len >= 1024) {
            return CallResult{
                .success = false,
                .gas_left = gas,
                .output = &[_]u8{},
            };
        }

        const snap = try self.takeSnapshot();

        // Value balance check and transfer
        if (value > 0) {
            switch (kind) {
                .call => {
                    const sender_balance = self.get_balance(caller);
                    if (sender_balance < value) {
                        self.revertSnapshot(snap);
                        return CallResult{
                            .success = false,
                            .gas_left = gas,
                            .output = &[_]u8{},
                        };
                    }
                    const target_balance = self.get_balance(exec_address);
                    self.setBalance(caller, sender_balance - value) catch return Error.StorageError;
                    self.setBalance(exec_address, target_balance +% value) catch return Error.StorageError;
                },
                .callcode => {
                    const sender_balance = self.get_balance(caller);
                    if (sender_balance < value) {
                        self.revertSnapshot(snap);
                        return CallResult{
                            .success = false,
                            .gas_left = gas,
                            .output = &[_]u8{},
                        };
                    }
                },
                .delegatecall, .staticcall => {},
            }
        }

        // Check if this is a precompile call
        if (self.is_precompile(code_address)) {
            const precompile_res = try self.execute_precompile(code_address, input, gas);
            if (!precompile_res.success) {
                self.revertSnapshot(snap);
            }
            return precompile_res;
        }

        // Get code for the target address
        const code = self.get_code(code_address);
        if (code.len == 0) {
            // Empty account - just return success
            return CallResult{
                .success = true,
                .gas_left = gas,
                .output = &[_]u8{},
            };
        }

        // Create a new frame for the inner call
        const frame = try self.allocator.create(MinimalFrame);
        frame.* = try MinimalFrame.init(
            self.allocator,
            code,
            @intCast(gas),
            caller,
            exec_address,
            value,
            input,
            @as(*anyopaque, @ptrCast(self)),
            self.hardfork,
        );
        frame.is_static = is_static;

        try self.frames.append(self.allocator, frame);
        errdefer _ = self.frames.pop();

        frame.execute() catch {
            _ = self.frames.pop();
            self.revertSnapshot(snap);
            return CallResult{
                .success = false,
                .gas_left = 0,
                .output = &[_]u8{},
            };
        };

        // Pop frame from stack
        _ = self.frames.pop();

        // Store return data
        const output = if (frame.output.len > 0) blk: {
            const output_copy = try self.allocator.alloc(u8, frame.output.len);
            @memcpy(output_copy, frame.output);
            break :blk output_copy;
        } else &[_]u8{};

        if (frame.reverted) {
            self.revertSnapshot(snap);
        }

        return CallResult{
            .success = !frame.reverted,
            .gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0))),
            .output = output,
        };
    }

    /// Execute CREATE / CREATE2 initcode with full EIP-150/170/684/3541/3860 semantics.
    pub fn inner_create(
        self: *Self,
        caller: Address,
        value: u256,
        init_code: []const u8,
        salt_opt: ?u256,
        available_gas: u64,
    ) Error!CreateResult {
        if (self.frames.items.len >= 1024) {
            return CreateResult{
                .success = false,
                .gas_left = available_gas,
                .output = &[_]u8{},
                .created_address = null,
            };
        }

        const caller_balance = self.get_balance(caller);
        const caller_nonce = self.get_nonce(caller);
        if (caller_balance < value or caller_nonce == std.math.maxInt(u64)) {
            return CreateResult{
                .success = false,
                .gas_left = available_gas,
                .output = &[_]u8{},
                .created_address = null,
            };
        }

        // Compute contract address before bumping nonce
        const contract_address = if (salt_opt) |salt| blk: {
            var salt_bytes: [32]u8 = undefined;
            std.mem.writeInt(u256, &salt_bytes, salt, .big);
            var init_hash: [32]u8 = undefined;
            std.crypto.hash.sha3.Keccak256.hash(init_code, &init_hash, .{});
            break :blk primitives.Address.getCreate2Address(caller, salt_bytes, init_hash);
        } else primitives.Address.getContractAddress(self.allocator, caller, caller_nonce) catch return Error.AllocationError;

        // EIP-2929: warm created address before snapshot so it stays warm even on revert
        if (self.hardfork.isAtLeast(.BERLIN)) {
            _ = self.warm_addresses.getOrPut(contract_address) catch return Error.StorageError;
        }

        // Increment caller nonce (persists even if initcode reverts)
        self.setNonce(caller, caller_nonce + 1) catch return Error.StorageError;

        const snap = try self.takeSnapshot();

        // EIP-684: collision if target already has code or non-zero nonce
        if (self.get_code(contract_address).len > 0 or self.get_nonce(contract_address) > 0) {
            self.revertSnapshot(snap);
            return CreateResult{
                .success = false,
                .gas_left = 0,
                .output = &[_]u8{},
                .created_address = null,
            };
        }

        // Transfer endowment and initialize nonce = 1 (EIP-161 Spurious Dragon+)
        if (value > 0) {
            const target_balance = self.get_balance(contract_address);
            self.setBalance(caller, caller_balance - value) catch return Error.StorageError;
            self.setBalance(contract_address, target_balance +% value) catch return Error.StorageError;
        }
        if (self.hardfork.isAtLeast(.SPURIOUS_DRAGON)) {
            self.setNonce(contract_address, 1) catch return Error.StorageError;
        }

        // Empty init code deploys an empty contract immediately
        if (init_code.len == 0) {
            return CreateResult{
                .success = true,
                .gas_left = available_gas,
                .output = &[_]u8{},
                .created_address = contract_address,
            };
        }

        // Execute init code in a new frame
        const frame = try self.allocator.create(MinimalFrame);
        frame.* = try MinimalFrame.init(
            self.allocator,
            init_code,
            @intCast(available_gas),
            caller,
            contract_address,
            value,
            &[_]u8{},
            @as(*anyopaque, @ptrCast(self)),
            self.hardfork,
        );
        frame.is_static = false;

        try self.frames.append(self.allocator, frame);
        errdefer _ = self.frames.pop();

        frame.execute() catch {
            _ = self.frames.pop();
            self.revertSnapshot(snap);
            return CreateResult{
                .success = false,
                .gas_left = 0,
                .output = &[_]u8{},
                .created_address = null,
            };
        };
        _ = self.frames.pop();

        const frame_gas_left: u64 = @intCast(@max(frame.gas_remaining, 0));
        if (frame.reverted) {
            self.revertSnapshot(snap);
            const revert_out = if (frame.output.len > 0) blk: {
                const copy = try self.allocator.alloc(u8, frame.output.len);
                @memcpy(copy, frame.output);
                break :blk copy;
            } else &[_]u8{};
            return CreateResult{
                .success = false,
                .gas_left = frame_gas_left,
                .output = revert_out,
                .created_address = null,
            };
        }

        const deployed_code = frame.output;
        // EIP-3541 (London+): reject bytecode starting with 0xEF
        if (self.hardfork.isAtLeast(.LONDON) and deployed_code.len > 0 and deployed_code[0] == 0xef) {
            self.revertSnapshot(snap);
            return CreateResult{
                .success = false,
                .gas_left = 0,
                .output = &[_]u8{},
                .created_address = null,
            };
        }
        // EIP-170 (Spurious Dragon+): max deployed contract code size = 24576 bytes
        if (self.hardfork.isAtLeast(.SPURIOUS_DRAGON) and deployed_code.len > 24576) {
            self.revertSnapshot(snap);
            return CreateResult{
                .success = false,
                .gas_left = 0,
                .output = &[_]u8{},
                .created_address = null,
            };
        }

        // Charge code deposit gas (200 gas per byte)
        const deposit_cost: u64 = @as(u64, deployed_code.len) * GasConstants.CreateDataGas;
        if (frame_gas_left < deposit_cost) {
            self.revertSnapshot(snap);
            return CreateResult{
                .success = false,
                .gas_left = 0,
                .output = &[_]u8{},
                .created_address = null,
            };
        }

        if (deployed_code.len > 0) {
            self.setCode(contract_address, deployed_code) catch return Error.StorageError;
        }

        return CreateResult{
            .success = true,
            .gas_left = frame_gas_left - deposit_cost,
            .output = &[_]u8{},
            .created_address = contract_address,
        };
    }

    /// Get balance of an address (called by frame)
    pub fn get_balance(self: *Self, address: Address) u256 {
        if (self.host) |host| {
            return host.getBalance(address);
        }
        return self.balances.get(address) orelse 0;
    }

    /// Get code for an address
    pub fn get_code(self: *Self, address: Address) []const u8 {
        if (self.host) |host| {
            return host.getCode(address);
        }
        return self.code.get(address) orelse &[_]u8{};
    }

    /// Get storage value (called by frame)
    pub fn get_storage(self: *Self, address: Address, slot: u256) u256 {
        if (self.host) |host| {
            return host.getStorage(address, slot);
        }
        const key = StorageSlotKey{ .address = address, .slot = slot };
        return self.storage.get(key) orelse 0;
    }

    /// Get EIP-1153 transient storage value (separate from persistent storage)
    pub fn get_transient_storage(self: *Self, address: Address, slot: u256) u256 {
        const key = StorageSlotKey{ .address = address, .slot = slot };
        return self.transient_storage.get(key) orelse 0;
    }

    /// Set EIP-1153 transient storage value (separate from persistent storage)
    pub fn set_transient_storage(self: *Self, address: Address, slot: u256, value: u256) Error!void {
        const key = StorageSlotKey{ .address = address, .slot = slot };
        self.transient_storage.put(key, value) catch {
            return Error.StorageError;
        };
    }

    /// Set storage value (called by frame)
    pub fn set_storage(self: *Self, address: Address, slot: u256, value: u256) Error!void {
        if (self.host) |host| {
            host.setStorage(address, slot, value) catch {
                return Error.StorageError;
            };
            return;
        }
        const key = StorageSlotKey{ .address = address, .slot = slot };

        // Track original value on first write in transaction
        if (!self.original_storage.contains(key)) {
            const current = self.storage.get(key) orelse 0;
            self.original_storage.put(key, current) catch {
                return Error.StorageError;
            };
        }

        self.storage.put(key, value) catch {
            return Error.StorageError;
        };
    }

    /// Get original storage value (before transaction modifications)
    pub fn get_original_storage(self: *Self, address: Address, slot: u256) u256 {
        const key = StorageSlotKey{ .address = address, .slot = slot };
        // If we have tracked the original, return it
        if (self.original_storage.get(key)) |original| {
            return original;
        }
        // Otherwise return current value (unchanged in this transaction)
        return self.storage.get(key) orelse 0;
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

    /// Execute a single step (for tracer)
    pub fn step(self: *Self) !void {
        if (self.getCurrentFrame()) |frame| {
            try frame.step();
        }
    }
};
