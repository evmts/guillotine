/// Test host implementation for execution-specs tests
/// This maintains multi-account state (balances, code, storage) for testing
const std = @import("std");
const primitives = @import("primitives");
const evm_mod = @import("evm");
const Address = primitives.Address.Address;
const HostInterface = evm_mod.HostInterface;
const CallResult = evm_mod.CallResult;

/// Storage slot key for tracking
pub const StorageSlotKey = struct {
    address: Address,
    slot: u256,

    pub fn hash(self: @This(), key: StorageSlotKey) u32 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(&key.address.bytes);
        hasher.update(std.mem.asBytes(&key.slot));
        return @truncate(hasher.final());
    }

    pub fn eql(self: @This(), a: StorageSlotKey, b: StorageSlotKey, b_index: usize) bool {
        _ = self;
        _ = b_index;
        return a.address.equals(b.address) and a.slot == b.slot;
    }
};

const AddressContext = std.array_hash_map.AutoContext(Address);
const StorageContext = std.hash_map.AutoContext(StorageSlotKey);

pub const TestHost = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    balances: std.AutoHashMap(Address, u256),
    code: std.AutoHashMap(Address, []const u8),
    storage: std.AutoHashMap(StorageSlotKey, u256),
    nonces: std.AutoHashMap(Address, u64),

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .allocator = allocator,
            .balances = std.AutoHashMap(Address, u256).init(allocator),
            .code = std.AutoHashMap(Address, []const u8).init(allocator),
            .storage = std.AutoHashMap(StorageSlotKey, u256).init(allocator),
            .nonces = std.AutoHashMap(Address, u64).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Free all allocated code
        var it = self.code.valueIterator();
        while (it.next()) |code_ptr| {
            self.allocator.free(code_ptr.*);
        }
        self.balances.deinit();
        self.code.deinit();
        self.storage.deinit();
        self.nonces.deinit();
    }

    pub fn hostInterface(self: *Self) HostInterface {
        return .{
            .ptr = self,
            .vtable = &.{
                .getBalance = getBalance,
                .setBalance = setBalanceVTable,
                .getCode = getCode,
                .setCode = setCodeVTable,
                .getStorage = getStorage,
                .setStorage = setStorage,
                .getNonce = getNonceVTable,
                .setNonce = setNonceVTable,
            },
        };
    }

    // Pre-state setup methods
    pub fn setBalance(self: *Self, address: Address, balance: u256) !void {
        try self.balances.put(address, balance);
    }

    pub fn setCode(self: *Self, address: Address, code: []const u8) !void {
        const owned_code = try self.allocator.dupe(u8, code);
        try self.code.put(address, owned_code);
    }

    pub fn setStorageSlot(self: *Self, address: Address, slot: u256, value: u256) !void {
        const key = StorageSlotKey{ .address = address, .slot = slot };
        // EVM spec: storage slots with value 0 should be deleted, not stored
        if (value == 0) {
            _ = self.storage.remove(key);
        } else {
            try self.storage.put(key, value);
        }
    }

    pub fn setNonce(self: *Self, address: Address, nonce: u64) !void {
        if (nonce == 0) {
            // Remove entry when nonce is 0 to properly handle account deletion/revert
            // This matches Ethereum semantics where an account with nonce=0, balance=0, and no code doesn't exist
            _ = self.nonces.remove(address);
        } else {
            try self.nonces.put(address, nonce);
        }
    }

    // Post-state validation methods
    pub fn getNonce(self: *Self, address: Address) u64 {
        return self.nonces.get(address) orelse 0;
    }

    // HostInterface vtable implementations
    fn getBalance(ptr: *anyopaque, address: Address) u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.balances.get(address) orelse 0;
    }

    fn setBalanceVTable(ptr: *anyopaque, address: Address, balance: u256) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.balances.put(address, balance) catch {
            return;
        };
    }

    fn getCode(ptr: *anyopaque, address: Address) []const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.code.get(address) orelse &[_]u8{};
    }

    fn setCodeVTable(ptr: *anyopaque, address: Address, code: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // Note: We need to duplicate code to own it, as the passed slice may be temporary
        // For empty code, just clear the entry
        if (code.len == 0) {
            if (self.code.fetchRemove(address)) |kv| {
                self.allocator.free(kv.value);
            }
            return;
        }
        // Free existing code if present
        if (self.code.fetchRemove(address)) |kv| {
            self.allocator.free(kv.value);
        }
        // Store new code (duplicate to own the memory - the caller may free their copy)
        const owned_code = self.allocator.dupe(u8, code) catch {
            return; // In a test context, we should not fail silently, but the interface doesn't allow errors
        };
        self.code.put(address, owned_code) catch {
            self.allocator.free(owned_code);
            return;
        };
    }

    fn getStorage(ptr: *anyopaque, address: Address, slot: u256) u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const key = StorageSlotKey{ .address = address, .slot = slot };
        return self.storage.get(key) orelse 0;
    }

    fn setStorage(ptr: *anyopaque, address: Address, slot: u256, value: u256) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const key = StorageSlotKey{ .address = address, .slot = slot };
        // std.debug.print("DEBUG HOST: setStorage called, addr={any} slot={} value={}\n", .{address.bytes, slot, value});
        // EVM spec: storage slots with value 0 should be deleted, not stored
        if (value == 0) {
            _ = self.storage.remove(key);
        } else {
            self.storage.put(key, value) catch {
                // In a test context, we should not fail silently
                // But the interface doesn't allow errors
                // std.debug.print("DEBUG HOST: setStorage FAILED to put!\n", .{});
                return;
            };
        }
    }

    fn getNonceVTable(ptr: *anyopaque, address: Address) u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.getNonce(address);
    }

    fn setNonceVTable(ptr: *anyopaque, address: Address, nonce: u64) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.setNonce(address, nonce) catch {
            // In a test context, we should not fail silently
            // But the interface doesn't allow errors
            return;
        };
    }
};
