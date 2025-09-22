/// Minimal EVM implementation for tracing and validation
/// This is a simplified, unoptimized EVM that orchestrates execution.
/// Architecture mirrors evm.zig - MinimalEvm orchestrates, MinimalFrame executes
const std = @import("std");
const primitives = @import("primitives");
const crypto = @import("crypto");
const log = @import("../log.zig");
const GasConstants = primitives.GasConstants;
const MinimalFrame = @import("minimal_frame.zig").MinimalFrame;
const minimal_host = @import("minimal_host.zig");
const call_params_mod = @import("../frame/call_params.zig");
const call_result_mod = @import("../frame/call_result.zig");
const Hardfork = @import("../eips_and_hardforks/eips.zig").Hardfork;

const Address = primitives.Address.Address;

// Re-export host types for compatibility
pub const HostInterface = minimal_host.HostInterface;
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

    // Expose call input/output interfaces
    pub const CallParams = call_params_mod.CallParams(.{});
    pub const CallResult = call_result_mod.CallResult(.{});

    const Self = @This();

    frames: std.ArrayList(*MinimalFrame),
    storage: std.AutoHashMap(StorageSlotKey, u256),
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
        // TODO: Pre-warm precompiles
    }

    /// Execute an EVM operation, which will route to specific handlers based on the operation type
    ///
    /// We never handle errors in inner_call and specific execute functions so we can propagate raw errors back to this handler,
    /// and handle them with logs and typed error results here in a consistent way.
    pub fn call(
        self: *Self,
        params: CallParams,
    ) CallResult {        
        const to = params.get_to() orelse Address.ZERO_ADDRESS;
        const gas = params.getGas();

        defer {
            // Reset transaction-scoped caches
            self.gas_refund = 0;
            self.warm_addresses.clearRetainingCapacity();
            self.warm_storage_slots.clearRetainingCapacity();
        }

        // Pre-warm transaction, including precompiles depending on hardfork
        self.pre_warm_transaction(to) catch |err| {
            switch (err) {
                error.StorageError => {
                    log.err("Pre-warm transaction failed: {s}", .{@errorName(err)});
                    return CallResult.failure_with_error(0, @errorName(err));
                },
                else => unreachable, // nothing else should happen so far
            }
        };

        // Validate base gas
        if (gas == 0) {
            log.err("Gas provided to transaction is 0");
            return CallResult.failure_with_error(0, @errorName(error.GasZeroError));
        }

        // Calculate floor gas for EIP-7623 (Prague), which we will enforce post-execution
        const floor_gas = self.get_floor_gas(params);

        // Calculate gas for input data (zero vs non-zero bytes)
        const data_gas = self.get_calldata_gas(params);

        // Base transaction + calldata gas
        const intrinsic_gas = blk: {
            const base_gas: u64 = if (params.isCreate())
                GasConstants.TxGasContractCreation
            else
                GasConstants.TxGas;

            break :blk base_gas + data_gas;
        };

        if (gas < intrinsic_gas) {
            @branchHint(.cold);
            log.err("Gas provided to transaction is no enough to pay for intrinsic gas: {d} < {d}", .{ gas, intrinsic_gas });
            return CallResult.failure_with_error(0, @errorName(error.OutOfGas));
        }

        const execution_gas = gas - intrinsic_gas;

        var modified_params = params;
        modified_params.setGas(execution_gas);

        var result = self.inner_call(modified_params) catch |err| {
            log.err("Inner call failed: {s}", .{@errorName(err)});
            // Any other error than revert is caught here
            return CallResult.failure_with_error(0, @errorName(err));
        };

        if (result.success) {
            // Apply gas refund if the call was successful
            const execution_gas_used = gas - result.gas_left;

            // Pre-London: refund up to half of gas used; post-London: refund up to one fifth of gas used
            const capped_refund = if (self.hardfork.isBefore(.LONDON)) blk: {
                @branchHint(.cold);
                break :blk @min(self.gas_refund, execution_gas_used / 2);
            } else blk: {
                @branchHint(.likely);
                break :blk @min(self.gas_refund, execution_gas_used / 5);
            };

            // Apply the refund
            result.gas_left += capped_refund;
        }

        // EIP-7623 (Prague): Ensure at least floor_gas is consumed
        if (self.hardfork.isAtLeast(.PRAGUE) and floor_gas > 0) {
            const gas_spent = gas - result.gas_left;
            if (gas_spent < floor_gas) {
                // Force consumption of at least floor_gas
                result.gas_left = gas - floor_gas;
            }
        }

        return result;
    }


    /// Unified inner call handler for all call types
    /// TODO: add journaling to be able to revert to snapshot in case of failure
    pub fn inner_call(self: *Self, params: CallParams) Error!CallResult {
        // Validate gas parameter
        const execution_gas = params.getGas();
        if (execution_gas == 0) return error.OutOfGas;

        // Check depth limit (EVM allows max 1024 depth)
        if (self.frames.items.len >= 1024) return error.CallDepthExceeded;

        // Route to appropriate handler based on call type
        // We don't catch here so we can propagate the error back to the top-level call handler
        return switch (params) {
            .call => |p| blk: {
                @branchHint(.likely);
                break :blk try self.execute_call(.{ .caller = p.caller, .to = p.to, .value = p.value, .input = p.input, .gas = execution_gas });
            },
            .staticcall => |p| blk: {
                @branchHint(.likely);
                break :blk try self.execute_staticcall(.{ .caller = p.caller, .to = p.to, .input = p.input, .gas = execution_gas });
            },
            .delegatecall => |p| try self.execute_delegatecall(.{ .caller = p.caller, .to = p.to, .input = p.input, .gas = execution_gas }),
            .create => |p| try self.execute_create(.{ .caller = p.caller, .value = p.value, .init_code = p.init_code, .gas = execution_gas }),
            .create2 => |p| try self.execute_create2(.{ .caller = p.caller, .value = p.value, .init_code = p.init_code, .salt = p.salt, .gas = execution_gas }),
            .callcode => |p| blk: {
                @branchHint(.cold);
                break :blk try self.execute_callcode(.{ .caller = p.caller, .to = p.to, .value = p.value, .input = p.input, .gas = execution_gas });
            },
        };
    }

    /// Execute a regular CALL
    fn execute_call(self: *Self, params: struct {
        caller: Address,
        to: Address,
        value: u256,
        input: []const u8,
        gas: u64,
    }) Error!CallResult {
        // Get the static context at the current frame and error if trying to transfer value
        const is_static = self.is_static_context();
        if (is_static and params.value > 0) return error.StaticCallViolation;

        // Handle value transfer if needed
        if (params.value > 0) {
            const caller_balance = self.get_balance(params.caller);
            if (caller_balance < params.value) return error.InsufficientBalance;

            if (!params.caller.equals(params.to)) {
                const to_balance = self.get_balance(params.to);
                try self.set_balance(params.caller, caller_balance - params.value);
                try self.set_balance(params.to, to_balance + params.value);
            }
        }

        // TODO: call preflight (precompiles, delegation, etc, see evm.zig)

        // Get target contract code
        const code = self.get_code(params.to);
        // Empty account - just return success
        if (code.len == 0) return CallResult.success_empty(params.gas);

        // Execute the call in a new frame
        return self.execute_frame(
            code,
            params.input,
            params.gas,
            params.caller,
            params.to,
            params.value,
            is_static,
        );
    }

    /// Execute CALLCODE
    fn execute_callcode(self: *Self, params: struct {
        caller: Address,
        to: Address,
        value: u256,
        input: []const u8,
        gas: u64,
    }) Error!CallResult {
        // Error if trying to transfer value in static context
        const is_static = self.is_static_context();
        if (is_static and params.value > 0) return error.StaticCallViolation;

        // Check balance but don't transfer
        if (params.value > 0) {
            const caller_balance = self.get_balance(params.caller);
            if (caller_balance < params.value) return error.InsufficientBalance;
        }

        // Get code from target address
        const code = self.get_code(params.to);
        if (code.len == 0) return CallResult.success_empty(params.gas);

        // Execute in current context
        return self.execute_frame(
            code,
            params.input,
            params.gas,
            params.caller,
            params.caller,
            params.value,
            is_static,
        );
    }

    /// Execute DELEGATECALL
    fn execute_delegatecall(self: *Self, params: struct {
        caller: Address,
        to: Address,
        input: []const u8,
        gas: u64,
    }) Error!CallResult {
        // TODO: call preflight (precompiles, delegation, etc, see evm.zig)

        const code = self.get_code(params.to);
        if (code.len == 0) return CallResult.success_empty(params.gas);

        // Get current call value from parent call (current frame)
        const current_frame = self.getCurrentFrame();
        const current_value = if (current_frame) |frame| frame.value else 0;

        // Execute in current context with preserved caller and value
        return self.execute_frame(
            code,
            params.input,
            params.gas,
            params.caller,
            params.caller,
            current_value,
            self.is_static_context(),
        );
    }

    /// Execute STATICCALL
    fn execute_staticcall(self: *Self, params: struct {
        caller: Address,
        to: Address,
        input: []const u8,
        gas: u64,
    }) Error!CallResult {
        // TODO: staticcall preflight (precompiles, delegation, etc, see evm.zig)

        const code = self.get_code(params.to);
        if (code.len == 0) return CallResult.success_empty(params.gas);

        // Execute in static context (read-only)
        return self.execute_frame(
            code,
            params.input,
            params.gas,
            params.caller,
            params.to,
            0,
            true,
        );
    }

    /// Execute CREATE operation
    fn execute_create(self: *Self, params: struct {
        caller: Address,
        value: u256,
        init_code: []const u8,
        gas: u64,
    }) Error!CallResult {
        // Error if trying to create a contract in static context
        if (self.is_static_context()) return error.StaticCallViolation;

        // TODO: we need to increment nonces correctly
        const nonce = self.get_nonce(params.caller);
        // Calculate contract address
        const contract_address = primitives.Address.get_contract_address(params.caller, nonce);

        // Execute creation with common logic
        return self.execute_create_internal(.{
            .caller = params.caller,
            .contract_address = contract_address,
            .value = params.value,
            .init_code = params.init_code,
            .gas = params.gas,
        });
    }

    /// Execute CREATE2 operation
    fn execute_create2(self: *Self, params: struct {
        caller: Address,
        value: u256,
        init_code: []const u8,
        salt: u256,
        gas: u64,
    }) Error!CallResult {
        // Error if trying to create a contract in static context
        if (self.is_static_context()) return error.StaticCallViolation;

        // Calculate CREATE2 address
        var init_code_hash_bytes: [32]u8 = undefined;
        try crypto.keccak_asm.keccak256(params.init_code, &init_code_hash_bytes);
        var salt_bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &salt_bytes, params.salt, .big);
        const contract_address = primitives.Address.get_create2_address(params.caller, salt_bytes, init_code_hash_bytes);

        // Execute creation with common logic
        return self.execute_create_internal(.{
            .caller = params.caller,
            .contract_address = contract_address,
            .value = params.value,
            .init_code = params.init_code,
            .gas = params.gas,
        });
    }

    /// Common contract creation logic for CREATE and CREATE2
    fn execute_create_internal(
        self: *Self,
        params: struct {
            caller: Address,
            contract_address: Address,
            value: u256,
            init_code: []const u8,
            gas: u64,
        },
    ) Error!CallResult {
        // Check for address collision
        if (self.get_code(params.contract_address).len > 0) return error.ContractCollision;

        // Transfer value if needed
        if (params.value > 0) {
            const caller_balance = self.get_balance(params.caller);
            if (caller_balance < params.value) return error.InsufficientBalance;
            
            if (!params.caller.equals(params.contract_address)) {
                const contract_balance = self.get_balance(params.contract_address);
                try self.set_balance(params.caller, caller_balance - params.value);
                try self.set_balance(params.contract_address, contract_balance + params.value);
            }
        }

        // Validate init code size
        if (params.init_code.len > self.get_init_code_size()) return error.CreateInitCodeSizeLimit;

        // Execute init code
        const result = try self.execute_frame(
            params.init_code,
            &[_]u8{},
            params.gas,
            params.caller,
            params.contract_address,
            params.value,
            false,
        );

        // Validate deployed code
        if (result.output.len > 0) {
            // EIP-170: Contract code size limit (24KB after Spurious Dragon)
            if (result.output.len > self.get_code_size()) return error.CreateContractSizeLimit;
            // EIP-3541: Reject contracts starting with 0xEF
            if (self.hardfork.isAtLeast(.LONDON) and result.output[0] == 0xEF) return error.InvalidBytecode;

            // Store the deployed code
            try self.set_code(params.contract_address, result.output);
        }

        // Set contract nonce to 1 (per EIP-161)
        try self.set_nonce(params.contract_address, 1);

        // Return success with created address as output
        const address_bytes = try self.allocator.alloc(u8, 20);
        @memcpy(address_bytes, &params.contract_address.bytes);

        var full_result = CallResult.success_with_output(result.gas_left, address_bytes);
        full_result.created_address = params.contract_address;
        return full_result;
    }

    /// Get init code size limit based on hardfork (EIP-3860)
    /// Pre-Shanghai: Use contract code size limit (24KB)
    /// Shanghai-Prague: 49,152 bytes (2 × contract code limit)
    /// TODO: Osaka+: 73,728 bytes - update when OSAKA hardfork is added but also discussions still ongoing on this size
    /// TODO: Both size limits below should use constants
    fn get_init_code_size(self: *Self) u64 {
        // 0xC000 - 2 × contract code limit
        if (self.hardfork.isAtLeast(.SHANGHAI)) return 49152;
        // Pre-Shanghai: Use the contract code size limit
        return self.get_code_size();
    }

    /// Get contract code size limit based on hardfork (EIP-170)
    /// Pre-Spurious Dragon: No limit (returns large value)
    /// Spurious Dragon-Prague: 24,576 bytes (0x6000)
    /// TODO: Osaka+: 49,152 bytes - update when OSAKA hardfork is added (same as above no consensus yet)
    fn get_code_size(self: *const Self) u64 {
        // No limit before Spurious Dragon
        if (self.hardfork.isBefore(.SPURIOUS_DRAGON)) return std.math.maxInt(u64);
        return 24576; // 0x6000 - 24KB limit
    }

    /// Execute code in a new frame
    fn execute_frame(
        self: *Self,
        code: []const u8,
        input: []const u8,
        gas: u64,
        caller: Address,
        address: Address,
        value: u256,
        is_static: bool,
    ) Error!CallResult {
        // Create and initialize frame
        const frame = try self.allocator.create(MinimalFrame);
        frame.* = try MinimalFrame.init(
            self.allocator,
            code,
            @intCast(gas),
            caller,
            address,
            value,
            input,
            is_static,
            @as(*anyopaque, @ptrCast(self)),
            self.hardfork,
        );

        // Push frame onto stack
        try self.frames.append(self.allocator, frame);
        defer _ = self.frames.pop();

        // Pre-warm contract address
        try self.pre_warm_addresses(&[1]Address{ address });

        // Execute the frame
        // We want to propagate any error except revert which we need to copy the output for
        frame.execute() catch |err| switch (err) {
            error.RevertExecution => {
                const gas_left: u64 = @intCast(@max(frame.gas_remaining, 0));
                const output = if (frame.output.len > 0) blk: {
                    const out = try self.allocator.alloc(u8, frame.output.len);
                    @memcpy(out, frame.output);
                    break :blk out;
                } else &[_]u8{};

                return CallResult.revert_with_data(gas_left, output);
            },
            else => return err,
        };

        // Copy output to persistent memory
        const output = if (frame.output.len > 0) blk: {
            const out = try self.allocator.alloc(u8, frame.output.len);
            @memcpy(out, frame.output);
            break :blk out;
        } else &[_]u8{};

        // Calculate gas left
        const gas_left: u64 = @intCast(@max(frame.gas_remaining, 0));

        // TODO: This should be caught in the execute function so might need some cleanup (remove reverted)
        // But "reverted" is probably useful for executing MinimalFrame step-by-step
        if (frame.reverted) return CallResult.revert_with_data(gas_left, output);
        return CallResult.success_with_output(gas_left, output);
    }

    /// TODO: Function called in LOG handlers to emit logs for the current tx
    pub fn emit_log(self: *Self, topics: []const u256, data: []const u8) Error!void {
        if (self.is_static_context()) return error.StaticCallViolation;

        _ = topics;
        _ = data;
    }

    /// TODO: Function called in SELFDESTRUCT handler
    /// See pre/post cancun logic
    pub fn handle_selfdestruct(self: *Self, contract_address: Address, recipient: Address) Error!void {
        if (self.is_static_context()) return error.StaticCallViolation;

        _ = contract_address;
        _ = recipient;
    }

    /// Get the static context at the current frame
    fn is_static_context(self: *const Self) bool {
        if (self.getCurrentFrame()) |frame| return frame.is_static;
        return false;
    }

    /// Calculate gas cost for calldata/init code (zero vs non-zero bytes)
    /// Implements EIP-2028 (Istanbul) and EIP-3860 (Shanghai) gas metering
    ///
    /// Gas calculation follows Ethereum's model:
    /// - Zero bytes: 4 gas each (all hardforks)
    /// - Non-zero bytes: 68 gas pre-Istanbul, 16 gas post-Istanbul (EIP-2028)
    /// - Init code words: 2 gas per 32-byte word for CREATE in Shanghai+ (EIP-3860)
    fn get_calldata_gas(self: *const Self, params: CallParams) u64 {
        const calldata = params.getInput();
        const count = count_bytes(calldata);

        // Calculate base data gas using the "token" model from REVM
        // Each token costs 4 gas (STANDARD_TOKEN_COST)
        // Zero bytes = 1 token each, non-zero bytes = multiple tokens
        const non_zero_multiplier: u64 = if (self.hardfork.isAtLeast(.ISTANBUL))
            4  // Post-Istanbul: 16 gas / 4 = 4 tokens per non-zero byte
        else
            17; // Pre-Istanbul: 68 gas / 4 = 17 tokens per non-zero byte

        const total_tokens = count.zero_bytes + (count.non_zero_bytes * non_zero_multiplier);
        var total_gas = total_tokens * GasConstants.TxDataZeroGas; // 4 gas per token

        // EIP-3860: Additional gas for init code words in CREATE transactions
        if (params.isCreate() and self.hardfork.isAtLeast(.SHANGHAI)) {
            const word_count = (calldata.len + 31) / 32; // Round up to next 32-byte word
            total_gas += word_count * GasConstants.InitcodeWordGas;
        }

        return total_gas;
    }

    /// Calculate floor gas for EIP-7623 (Prague)
    fn get_floor_gas(self: *const Self, params: CallParams) u64 {
        if (self.hardfork.isBefore(.PRAGUE)) return 0;
        const calldata = params.getInput();
        const count = count_bytes(calldata);

        const non_zero_multiplier: u64 = 4; // Prague always uses Istanbul+ pricing
        const total_tokens = count.zero_bytes + (count.non_zero_bytes * non_zero_multiplier);

        // Floor gas formula: tokens * 10 + 21000
        return total_tokens * 10 + 21000;
    }

    /// count zero and non-zero bytes
    fn count_bytes(data: []const u8) struct { zero_bytes: u64, non_zero_bytes: u64 } {
        var zero_bytes: u64 = 0;
        var non_zero_bytes: u64 = 0;
        for (data) |byte| {
            if (byte == 0) {
                zero_bytes += 1;
            } else {
                non_zero_bytes += 1;
            }
        }
        
        return .{ .zero_bytes = zero_bytes, .non_zero_bytes = non_zero_bytes };
    }

    /// Get balance of an address (called by frame)
    pub fn get_balance(self: *Self, address: Address) u256 {
        if (self.host) |host| {
            return host.getBalance(address);
        }
        return self.balances.get(address) orelse 0;
    }

    // Set balance of an address
    pub fn set_balance(self: *Self, address: Address, balance: u256) !void {
        if (self.host) |host| {
            host.setBalance(address, balance);
        }
        try self.balances.put(address, balance);
    }

    /// Get nonce for an address
    pub fn get_nonce(self: *Self, address: Address) u64 {
        if (self.host) |host| {
            return host.getNonce(address);
        }
        return self.nonces.get(address) orelse 0;
    }

    /// Set nonce for an address
    pub fn set_nonce(self: *Self, address: Address, nonce: u64) !void {
        if (self.host) |host| {
            host.setNonce(address, nonce);
        }
        try self.nonces.put(address, nonce);
    }

    /// Get code for an address
    pub fn get_code(self: *Self, address: Address) []const u8 {
        if (self.host) |host| {
            return host.getCode(address);
        }
        return self.code.get(address) orelse &[_]u8{};
    }

    // Set code for an address
    pub fn set_code(self: *Self, address: Address, code: []const u8) !void {
        if (self.host) |host| {
            host.setCode(address, code);
        }
        const code_copy = try self.allocator.alloc(u8, code.len);
        @memcpy(code_copy, code);
        try self.code.put(address, code_copy);
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
        if (self.is_static_context()) return error.StaticCallViolation;

        if (self.host) |host| {
            host.setStorage(address, slot, value);
            return;
        }
        const key = StorageSlotKey{ .address = address, .slot = slot };

        // Track original value on first write in transaction
        if (!self.original_storage.contains(key)) {
            const current = self.storage.get(key) orelse 0;
            try self.original_storage.put(key, current);
        }

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
        return self.storage.get(key) orelse 0;
    }

    /// Add gas refund
    pub fn add_refund(self: *Self, amount: u64) void {
        self.gas_refund +%= amount;
    }

    /// Check if an address is a precompile
    /// TODO: implement this
    pub fn is_precompile(self: *const Self, address: Address) bool {
        _ = self;
        _ = address;
        return false;
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
