/// Host interface and implementations for MinimalEvm
const std = @import("std");
const primitives = @import("primitives");
const call_params_mod = @import("../frame/call_params.zig");
const Address = primitives.Address.Address;

const CallParams = call_params_mod.CallParams(.{});

/// Host interface for system operations
pub const HostInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        inner_call: *const fn (ptr: *anyopaque, params: CallParams) CallResult,
        get_balance: *const fn (ptr: *anyopaque, address: Address) u256,
        set_balance: *const fn (ptr: *anyopaque, address: Address, balance: u256) void,
        get_nonce: *const fn (ptr: *anyopaque, address: Address) u64,
        set_nonce: *const fn (ptr: *anyopaque, address: Address, nonce: u64) void,
        get_code: *const fn (ptr: *anyopaque, address: Address) []const u8,
        set_code: *const fn (ptr: *anyopaque, address: Address, code: []const u8) void,
        get_storage: *const fn (ptr: *anyopaque, address: Address, slot: u256) u256,
        set_storage: *const fn (ptr: *anyopaque, address: Address, slot: u256, value: u256) void,
    };

    pub fn innerCall(self: HostInterface, params: CallParams) CallResult {
        return self.vtable.inner_call(self.ptr, params);
    }

    pub fn getBalance(self: HostInterface, address: Address) u256 {
        return self.vtable.get_balance(self.ptr, address);
    }

    pub fn setBalance(self: HostInterface, address: Address, balance: u256) void {
        self.vtable.set_balance(self.ptr, address, balance);
    }

    pub fn getNonce(self: HostInterface, address: Address) u64 {
        return self.vtable.get_nonce(self.ptr, address);
    }

    pub fn setNonce(self: HostInterface, address: Address, nonce: u64) void {
        self.vtable.set_nonce(self.ptr, address, nonce);
    }

    pub fn getCode(self: HostInterface, address: Address) []const u8 {
        return self.vtable.get_code(self.ptr, address);
    }

    pub fn setCode(self: HostInterface, address: Address, code: []const u8) void {
        self.vtable.set_code(self.ptr, address, code);
    }

    pub fn getStorage(self: HostInterface, address: Address, slot: u256) u256 {
        return self.vtable.get_storage(self.ptr, address, slot);
    }

    pub fn setStorage(self: HostInterface, address: Address, slot: u256, value: u256) void {
        self.vtable.set_storage(self.ptr, address, slot, value);
    }
};

/// Call result type
pub const CallResult = struct {
    success: bool,
    gas_left: u64,
    output: []const u8,
};

/// Host implementation that reads from real EVM
/// This is a stub implementation that demonstrates the interface.
/// For actual Frame integration, the Host would need to hold a reference
/// to the EVM instance and access its database through the evm_ptr field.
pub const Host = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    // To properly integrate with Frame:
    // evm_ptr: *anyopaque,  // Pointer to the EVM instance that contains the database

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn hostInterface(self: *Self) HostInterface {
        return .{
            .ptr = self,
            .vtable = &.{
                .inner_call = innerCall,
                .get_balance = getBalance,
                .set_balance = setBalance,
                .get_nonce = getNonce,
                .set_nonce = setNonce,
                .get_code = getCode,
                .set_code = setCode,
                .get_storage = getStorage,
                .set_storage = setStorage,
            },
        };
    }

    fn innerCall(ptr: *anyopaque, params: CallParams) CallResult {
        _ = ptr;
        // For now, just return success (this would normally delegate to the real EVM)
        return .{
            .success = true,
            .gas_left = params.getGas(),
            .output = &[_]u8{},
        };
    }

    fn getBalance(ptr: *anyopaque, address: Address) u256 {
        const self = @as(*Self, @ptrCast(@alignCast(ptr)));
        _ = self;
        // Note: For proper Frame integration, this would access the EVM's database
        // through the evm_ptr field to retrieve the account balance.
        // Current implementation returns 0 as a stub.
        _ = address;
        return 0;
    }

    fn setBalance(ptr: *anyopaque, address: Address, balance: u256) void {
        const self = @as(*Self, @ptrCast(@alignCast(ptr)));
        _ = self;
        // Note: For proper Frame integration, we would need to access the EVM's database
        // through the evm_ptr field. Since Host is currently a simple stub implementation
        // without a direct connection to the Frame/EVM, this remains unimplemented.
        // To properly implement this:
        // 1. Host would need to hold a reference to the EVM instance
        // 2. Access the database through: evm.database
        // 3. Get or create account: account = evm.database.get_account(address.bytes)
        // 4. Update balance: account.balance = balance
        // 5. Save account: evm.database.set_account(address.bytes, account)
        _ = address;
        _ = balance;
    }

    fn getNonce(ptr: *anyopaque, address: Address) u64 {
        const self = @as(*Self, @ptrCast(@alignCast(ptr)));
        _ = self;
        // Note: For proper Frame integration, this would access the EVM's database
        // through the evm_ptr field to retrieve the account nonce.
        // Current implementation returns 0 as a stub.
        _ = address;
        return 0;
    }

    fn setNonce(ptr: *anyopaque, address: Address, nonce: u64) void {
        const self = @as(*Self, @ptrCast(@alignCast(ptr)));
        _ = self;
        // Note: For proper Frame integration, we would need to access the EVM's database
        // through the evm_ptr field. Since Host is currently a simple stub implementation
        // without a direct connection to the Frame/EVM, this remains unimplemented.
        // To properly implement this:
        // 1. Host would need to hold a reference to the EVM instance
        // 2. Access the database through: evm.database
        // 3. Get or create account: account = evm.database.get_account(address.bytes)
        // 4. Update nonce: account.nonce = nonce
        // 5. Save account: evm.database.set_account(address.bytes, account)
        _ = address;
        _ = nonce;
    }

    fn getCode(ptr: *anyopaque, address: Address) []const u8 {
        const self = @as(*Self, @ptrCast(@alignCast(ptr)));
        _ = self;
        // Note: For proper Frame integration, this would access the EVM's database
        // through the evm_ptr field to retrieve the contract code.
        // Current implementation returns empty slice as a stub.
        _ = address;
        return &[_]u8{};
    }

    fn setCode(ptr: *anyopaque, address: Address, code: []const u8) void {
        const self = @as(*Self, @ptrCast(@alignCast(ptr)));
        _ = self;
        // Note: For proper Frame integration, we would need to access the EVM's database
        // through the evm_ptr field. Since Host is currently a simple stub implementation
        // without a direct connection to the Frame/EVM, this remains unimplemented.
        // To properly implement this:
        // 1. Host would need to hold a reference to the EVM instance
        // 2. Calculate code hash: code_hash = keccak256(code)
        // 3. Store code: evm.database.code_storage.put(code_hash, code)
        // 4. Get or create account: account = evm.database.get_account(address.bytes)
        // 5. Update code hash: account.code_hash = code_hash
        // 6. Save account: evm.database.set_account(address.bytes, account)
        _ = address;
        _ = code;
    }

    fn getStorage(ptr: *anyopaque, address: Address, slot: u256) u256 {
        const self = @as(*Self, @ptrCast(@alignCast(ptr)));
        _ = self;
        // Note: For proper Frame integration, this would access the EVM's database
        // through the evm_ptr field to retrieve storage values.
        // Current implementation returns 0 as a stub.
        _ = address;
        _ = slot;
        return 0;
    }

    fn setStorage(ptr: *anyopaque, address: Address, slot: u256, value: u256) void {
        const self = @as(*Self, @ptrCast(@alignCast(ptr)));
        _ = self;
        // Note: For proper Frame integration, we would need to access the EVM's database
        // through the evm_ptr field. Since Host is currently a simple stub implementation
        // without a direct connection to the Frame/EVM, this remains unimplemented.
        // To properly implement this:
        // 1. Host would need to hold a reference to the EVM instance
        // 2. Access the database through: evm.database
        // 3. Store value: evm.database.storage.put(StorageKey{address.bytes, slot}, value)
        _ = address;
        _ = slot;
        _ = value;
    }
};
