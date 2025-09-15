/// Minimal EVM implementation for tracing and validation
/// This is a simplified, unoptimized EVM that orchestrates execution.
/// Architecture mirrors evm.zig - MinimalEvm orchestrates, MinimalFrame executes
const std = @import("std");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
const MinimalFrame = @import("minimal_frame.zig").MinimalFrame;
const minimal_host = @import("minimal_host.zig");

const Address = primitives.Address.Address;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;
const to_u256 = primitives.Address.to_u256;

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
        return std.mem.eql(u8, &a.address.bytes, &b.address.bytes) and a.slot == b.slot;
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

/// Error set for MinimalEvm operations
pub const MinimalEvmError = error{
    OutOfMemory,
    StackOverflow,
    StackUnderflow,
    OutOfGas,
    InvalidOpcode,
    InvalidJump,
    InvalidPush,
    // Memory
    OutOfBounds,
    // Access list
    AddressPreWarmError,
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
        InitcodeTooLarge,
        TruncatedPush,
        OutOfBounds,
        WriteProtection,
        BytecodeTooLarge,
        InvalidPush,
    };

    const Self = @This();

    // Frame stack - manages nested calls
    frames: std.ArrayList(*MinimalFrame),

    // Storage for all accounts
    storage: std.AutoHashMap(StorageSlotKey, u256),

    // Account balances
    balances: std.AutoHashMap(Address, u256),

    // Account code
    code: std.AutoHashMap(Address, []const u8),

    // EIP-2929 warm/cold tracking (minimal)
    warm_addresses: std.array_hash_map.ArrayHashMap(Address, void, AddressContext, false),
    warm_storage_slots: std.array_hash_map.ArrayHashMap(StorageSlotKey, void, StorageSlotKeyContext, false),

    // Blockchain context
    chain_id: u64,
    block_number: u64,
    block_timestamp: u64,
    block_difficulty: u256,
    block_coinbase: Address,
    block_gas_limit: u64,
    block_base_fee: u256,
    blob_base_fee: u256,

    // Transaction context
    origin: Address,
    gas_price: u256,

    // Host interface (if provided)
    host: ?HostInterface,

    // Arena allocator for simplified memory management
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    /// Initialize a new MinimalEvm (orchestrator)
    pub fn init(allocator: std.mem.Allocator) !Self {
        // Create arena allocator for simplified memory management
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        // Ensure the arena is properly initialized with a valid allocator
        const arena_allocator = arena.allocator();

        const storage_map = std.AutoHashMap(StorageSlotKey, u256).init(arena_allocator);
        const balances_map = std.AutoHashMap(Address, u256).init(arena_allocator);
        const code_map = std.AutoHashMap(Address, []const u8).init(arena_allocator);
        // Initialize warm/cold tracking maps
        const warm_addresses = std.array_hash_map.ArrayHashMap(Address, void, AddressContext, false).init(arena_allocator);
        const warm_storage_slots = std.array_hash_map.ArrayHashMap(StorageSlotKey, void, StorageSlotKeyContext, false).init(arena_allocator);
        // In Zig 0.15.1, std.ArrayList is unmanaged
        var frames_list = std.ArrayList(*MinimalFrame){};
        try frames_list.ensureTotalCapacity(arena_allocator, 16);

        return Self{
            .frames = frames_list,
            .storage = storage_map,
            .balances = balances_map,
            .code = code_map,
            .warm_addresses = warm_addresses,
            .warm_storage_slots = warm_storage_slots,
            .chain_id = 1,
            .block_number = 0,
            .block_timestamp = 0,
            .block_difficulty = 0,
            .block_coinbase = ZERO_ADDRESS,
            .block_gas_limit = 30_000_000,
            .block_base_fee = 0,
            .blob_base_fee = 0,
            .origin = ZERO_ADDRESS,
            .gas_price = 0,
            .host = null,
            .arena = arena,
            .allocator = arena_allocator,
        };
    }

    /// Initialize as a pointer to avoid arena corruption from struct copies
    pub fn initPtr(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Initialize arena in place
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();

        const arena_allocator = self.arena.allocator();

        self.frames = std.ArrayList(*MinimalFrame).empty;
        self.storage = std.AutoHashMap(StorageSlotKey, u256).init(arena_allocator);
        self.balances = std.AutoHashMap(Address, u256).init(arena_allocator);
        self.code = std.AutoHashMap(Address, []const u8).init(arena_allocator);
        self.warm_addresses = std.array_hash_map.ArrayHashMap(Address, void, AddressContext, false).init(arena_allocator);
        self.warm_storage_slots = std.array_hash_map.ArrayHashMap(StorageSlotKey, void, StorageSlotKeyContext, false).init(arena_allocator);
        self.chain_id = 1;
        self.block_number = 0;
        self.block_timestamp = 0;
        self.block_difficulty = 0;
        self.block_coinbase = ZERO_ADDRESS;
        self.block_gas_limit = 30_000_000;
        self.block_base_fee = 0;
        self.blob_base_fee = 0;
        self.origin = ZERO_ADDRESS;
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
        // Arena allocator cleans up everything at once
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
        block_coinbase: Address,
        block_gas_limit: u64,
        block_base_fee: u256,
        blob_base_fee: u256,
    ) void {
        self.chain_id = chain_id;
        self.block_number = block_number;
        self.block_timestamp = block_timestamp;
        self.block_difficulty = block_difficulty;
        self.block_coinbase = block_coinbase;
        self.block_gas_limit = block_gas_limit;
        self.block_base_fee = block_base_fee;
        self.blob_base_fee = blob_base_fee;
    }

    /// Set transaction context
    pub fn setTransactionContext(self: *Self, origin: Address, gas_price: u256) void {
        self.origin = origin;
        self.gas_price = gas_price;
    }

    /// Set account code
    pub fn setCode(self: *Self, address: Address, code: []const u8) !void {
        const code_copy = try self.allocator.alloc(u8, code.len);
        @memcpy(code_copy, code);
        try self.code.put(address, code_copy);
    }

    /// Set account balance
    pub fn setBalance(self: *Self, address: Address, balance: u256) !void {
        try self.balances.put(address, balance);
    }

    /// Access an address and return the gas cost (EIP-2929 warm/cold)
    pub fn access_address(self: *Self, address: Address) !u64 {
        const entry = try self.warm_addresses.getOrPut(address);
        return if (entry.found_existing)
            GasConstants.WarmStorageReadCost
        else
            GasConstants.ColdAccountAccessCost;
    }

    /// Access a storage slot and return the gas cost (EIP-2929 warm/cold)
    pub fn access_storage_slot(self: *Self, contract_address: Address, slot: u256) !u64 {
        const key = StorageSlotKey{ .address = contract_address, .slot = slot };
        const entry = try self.warm_storage_slots.getOrPut(key);
        return if (entry.found_existing)
            GasConstants.WarmStorageReadCost
        else
            GasConstants.ColdSloadCost;
    }

    /// Pre-warm addresses for transaction initialization
    pub fn pre_warm_addresses(self: *Self, addresses: []const Address) !void {
        for (addresses) |address| {
            _ = self.warm_addresses.getOrPut(address) catch {
                return Error.StorageError;
            };
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
        // Clear and pre-warm warm trackers
        self.warm_addresses.clearRetainingCapacity();
        self.warm_storage_slots.clearRetainingCapacity();
        // TODO: Gate pre-warming by hardfork (Berlin enables access list rules, Shanghai warms coinbase)
        // and include precompiles as warm from the start.
        // TODO: pre-warm EIP-2930 tx access list entries when wiring tx params into the tracer.
        try self.pre_warm_addresses(&[_]Address{ self.origin, address, self.block_coinbase });

        // Currently we only use this function for regular calls
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

        // Create a new frame for execution
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
        );

        // Push frame onto stack
        try self.frames.append(self.allocator, frame);
        defer _ = self.frames.pop();

        // Execute the frame
        frame.execute() catch {
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

        const result = CallResult{
            .success = !frame.reverted,
            .gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0))),
            .output = output,
        };

        return result;
    }

    /// Handle inner call from frame (like evm.inner_call)
    pub fn inner_call(
        self: *Self,
        address: Address,
        value: u256,
        input: []const u8,
        gas: u64,
    ) Error!CallResult {
        if (self.frames.items.len >= 1024) {
            return CallResult{
                .success = false,
                .gas_left = 0,
                .output = &[_]u8{},
            };
        }

        // Get code for the target address
        const code = self.get_code(address);
        if (code.len == 0) {
            // Empty account - just return success
            return CallResult{
                .success = true,
                .gas_left = gas,
                .output = &[_]u8{},
            };
        }

        // Get caller from current frame
        const caller = if (self.getCurrentFrame()) |frame| frame.address else self.origin;

        // Create a new frame for the inner call
        const frame = try self.allocator.create(MinimalFrame);
        frame.* = try MinimalFrame.init(
            self.allocator,
            code,
            @intCast(gas),
            caller,
            address,
            value,
            input,
            @as(*anyopaque, @ptrCast(self)),
        );

        try self.frames.append(self.allocator, frame);
        errdefer _ = self.frames.pop();

        frame.execute() catch {
            _ = self.frames.pop();
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

        // Return result
        const result = CallResult{
            .success = !frame.reverted,
            .gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0))),
            .output = output,
        };

        // No cleanup needed - arena handles it
        return result;
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

    /// Set storage value (called by frame)
    pub fn set_storage(self: *Self, address: Address, slot: u256, value: u256) !void {
        if (self.host) |host| {
            host.setStorage(address, slot, value);
            return;
        }
        const key = StorageSlotKey{ .address = address, .slot = slot };
        try self.storage.put(key, value);
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
