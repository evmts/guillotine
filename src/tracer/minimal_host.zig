/// Host interface and implementations for MinimalEvm
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

/// Host interface for system operations
pub const HostInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        inner_call: *const fn (ptr: *anyopaque, gas: u64, address: Address, value: u256, input: []const u8, call_type: CallType) CallResult,
        get_balance: *const fn (ptr: *anyopaque, address: Address) u256,
        get_code: *const fn (ptr: *anyopaque, address: Address) []const u8,
        get_storage: *const fn (ptr: *anyopaque, address: Address, slot: u256) u256,
        set_storage: *const fn (ptr: *anyopaque, address: Address, slot: u256, value: u256) anyerror!void,
    };

    pub const CallType = enum {
        Call,
        CallCode,
        DelegateCall,
        StaticCall,
        Create,
        Create2,
    };

    pub fn innerCall(self: HostInterface, gas: u64, address: Address, value: u256, input: []const u8, call_type: CallType) CallResult {
        return self.vtable.inner_call(self.ptr, gas, address, value, input, call_type);
    }

    pub fn getBalance(self: HostInterface, address: Address) u256 {
        return self.vtable.get_balance(self.ptr, address);
    }

    pub fn getCode(self: HostInterface, address: Address) []const u8 {
        return self.vtable.get_code(self.ptr, address);
    }

    pub fn getStorage(self: HostInterface, address: Address, slot: u256) u256 {
        return self.vtable.get_storage(self.ptr, address, slot);
    }

    pub fn setStorage(self: HostInterface, address: Address, slot: u256, value: u256) !void {
        try self.vtable.set_storage(self.ptr, address, slot, value);
    }
};

/// Call result type
pub const CallResult = struct {
    success: bool,
    gas_left: u64,
    output: []const u8,
};

/// Storage slot key for tracking
const StorageSlotKey = struct {
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

/// Context for hashing/equality of StorageSlotKey for AutoHashMap
const StorageSlotKeyContext = struct {
    pub fn hash(self: @This(), key: StorageSlotKey) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(&key.address.bytes);
        hasher.update(std.mem.asBytes(&key.slot));
        return hasher.final();
    }

    pub fn eql(self: @This(), a: StorageSlotKey, b: StorageSlotKey) bool {
        _ = self;
        return StorageSlotKey.eql(a, b);
    }
};

/// Host implementation with internal state management
pub const Host = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    balances: std.AutoHashMap(Address, u256),
    code: std.AutoHashMap(Address, []const u8),
    storage: std.HashMap(StorageSlotKey, u256, StorageSlotKeyContext, std.hash_map.default_max_load_percentage),

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .allocator = allocator,
            .balances = std.AutoHashMap(Address, u256).init(allocator),
            .code = std.AutoHashMap(Address, []const u8).init(allocator),
            .storage = std.HashMap(StorageSlotKey, u256, StorageSlotKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var code_iter = self.code.iterator();
        while (code_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.balances.deinit();
        self.code.deinit();
        self.storage.deinit();
    }

    pub fn setBalance(self: *Self, address: Address, balance: u256) !void {
        try self.balances.put(address, balance);
    }

    pub fn setCode(self: *Self, address: Address, code: []const u8) !void {
        const code_copy = try self.allocator.alloc(u8, code.len);
        errdefer self.allocator.free(code_copy);
        @memcpy(code_copy, code);
        try self.code.put(address, code_copy);
    }

    pub fn hostInterface(self: *Self) HostInterface {
        return .{
            .ptr = self,
            .vtable = &.{
                .inner_call = innerCall,
                .get_balance = getBalance,
                .get_code = getCode,
                .get_storage = getStorage,
                .set_storage = setStorage,
            },
        };
    }

    fn innerCall(ptr: *anyopaque, gas: u64, address: Address, value: u256, input: []const u8, call_type: HostInterface.CallType) CallResult {
        _ = address;
        _ = value;
        _ = input;
        _ = call_type;
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;
        // Inner calls not supported in minimal host - return success with empty output
        // This is minimal implementation for tracer purposes
        return .{
            .success = true,
            .gas_left = gas,
            .output = &[_]u8{},
        };
    }

    fn getBalance(ptr: *anyopaque, address: Address) u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.balances.get(address) orelse 0;
    }

    fn getCode(ptr: *anyopaque, address: Address) []const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.code.get(address) orelse &[_]u8{};
    }

    fn getStorage(ptr: *anyopaque, address: Address, slot: u256) u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const key = StorageSlotKey{ .address = address, .slot = slot };
        return self.storage.get(key) orelse 0;
    }

    fn setStorage(ptr: *anyopaque, address: Address, slot: u256, value: u256) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const key = StorageSlotKey{ .address = address, .slot = slot };
        try self.storage.put(key, value);
    }
};

test "Host init and deinit" {
    const testing = std.testing;
    var host = try Host.init(testing.allocator);
    defer host.deinit();
}

test "Host setBalance and getBalance" {
    const testing = std.testing;
    var host = try Host.init(testing.allocator);
    defer host.deinit();

    const addr = try Address.fromBytes(&[_]u8{1} ** 20);
    try host.setBalance(addr, 12345);

    const iface = host.hostInterface();
    const balance = iface.getBalance(addr);
    try testing.expectEqual(@as(u256, 12345), balance);
}

test "Host getBalance returns zero for unknown address" {
    const testing = std.testing;
    var host = try Host.init(testing.allocator);
    defer host.deinit();

    const addr = try Address.fromBytes(&[_]u8{1} ** 20);
    const iface = host.hostInterface();
    const balance = iface.getBalance(addr);
    try testing.expectEqual(@as(u256, 0), balance);
}

test "Host setCode and getCode" {
    const testing = std.testing;
    var host = try Host.init(testing.allocator);
    defer host.deinit();

    const addr = try Address.fromBytes(&[_]u8{2} ** 20);
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01 };
    try host.setCode(addr, &code);

    const iface = host.hostInterface();
    const retrieved_code = iface.getCode(addr);
    try testing.expectEqualSlices(u8, &code, retrieved_code);
}

test "Host getCode returns empty for unknown address" {
    const testing = std.testing;
    var host = try Host.init(testing.allocator);
    defer host.deinit();

    const addr = try Address.fromBytes(&[_]u8{2} ** 20);
    const iface = host.hostInterface();
    const code = iface.getCode(addr);
    try testing.expectEqualSlices(u8, &[_]u8{}, code);
}

test "Host setStorage and getStorage" {
    const testing = std.testing;
    var host = try Host.init(testing.allocator);
    defer host.deinit();

    const addr = try Address.fromBytes(&[_]u8{3} ** 20);
    const slot: u256 = 42;
    const value: u256 = 9876543210;

    const iface = host.hostInterface();
    try iface.setStorage(addr, slot, value);
    const retrieved = iface.getStorage(addr, slot);
    try testing.expectEqual(value, retrieved);
}

test "Host getStorage returns zero for unknown slot" {
    const testing = std.testing;
    var host = try Host.init(testing.allocator);
    defer host.deinit();

    const addr = try Address.fromBytes(&[_]u8{3} ** 20);
    const slot: u256 = 42;
    const iface = host.hostInterface();
    const value = iface.getStorage(addr, slot);
    try testing.expectEqual(@as(u256, 0), value);
}

test "Host storage isolation between addresses" {
    const testing = std.testing;
    var host = try Host.init(testing.allocator);
    defer host.deinit();

    const addr1 = try Address.fromBytes(&[_]u8{4} ** 20);
    const addr2 = try Address.fromBytes(&[_]u8{5} ** 20);
    const slot: u256 = 1;

    const iface = host.hostInterface();
    try iface.setStorage(addr1, slot, 100);
    try iface.setStorage(addr2, slot, 200);

    const value1 = iface.getStorage(addr1, slot);
    const value2 = iface.getStorage(addr2, slot);
    try testing.expectEqual(@as(u256, 100), value1);
    try testing.expectEqual(@as(u256, 200), value2);
}

test "Host storage isolation between slots" {
    const testing = std.testing;
    var host = try Host.init(testing.allocator);
    defer host.deinit();

    const addr = try Address.fromBytes(&[_]u8{6} ** 20);
    const slot1: u256 = 1;
    const slot2: u256 = 2;

    const iface = host.hostInterface();
    try iface.setStorage(addr, slot1, 111);
    try iface.setStorage(addr, slot2, 222);

    const value1 = iface.getStorage(addr, slot1);
    const value2 = iface.getStorage(addr, slot2);
    try testing.expectEqual(@as(u256, 111), value1);
    try testing.expectEqual(@as(u256, 222), value2);
}

test "Host storage can be updated" {
    const testing = std.testing;
    var host = try Host.init(testing.allocator);
    defer host.deinit();

    const addr = try Address.fromBytes(&[_]u8{7} ** 20);
    const slot: u256 = 10;

    const iface = host.hostInterface();
    try iface.setStorage(addr, slot, 500);
    try iface.setStorage(addr, slot, 600);

    const value = iface.getStorage(addr, slot);
    try testing.expectEqual(@as(u256, 600), value);
}

test "Host balance can be updated" {
    const testing = std.testing;
    var host = try Host.init(testing.allocator);
    defer host.deinit();

    const addr = try Address.fromBytes(&[_]u8{8} ** 20);
    try host.setBalance(addr, 1000);
    try host.setBalance(addr, 2000);

    const iface = host.hostInterface();
    const balance = iface.getBalance(addr);
    try testing.expectEqual(@as(u256, 2000), balance);
}

test "Host code can be updated" {
    const testing = std.testing;
    var host = try Host.init(testing.allocator);
    defer host.deinit();

    const addr = try Address.fromBytes(&[_]u8{9} ** 20);
    const code1 = [_]u8{ 0x60, 0x01 };
    const code2 = [_]u8{ 0x60, 0x02, 0x60, 0x03 };

    try host.setCode(addr, &code1);
    try host.setCode(addr, &code2);

    const iface = host.hostInterface();
    const retrieved = iface.getCode(addr);
    try testing.expectEqualSlices(u8, &code2, retrieved);
}

test "Host multiple addresses with different balances" {
    const testing = std.testing;
    var host = try Host.init(testing.allocator);
    defer host.deinit();

    const addr1 = try Address.fromBytes(&[_]u8{10} ** 20);
    const addr2 = try Address.fromBytes(&[_]u8{11} ** 20);
    const addr3 = try Address.fromBytes(&[_]u8{12} ** 20);

    try host.setBalance(addr1, 100);
    try host.setBalance(addr2, 200);
    try host.setBalance(addr3, 300);

    const iface = host.hostInterface();
    try testing.expectEqual(@as(u256, 100), iface.getBalance(addr1));
    try testing.expectEqual(@as(u256, 200), iface.getBalance(addr2));
    try testing.expectEqual(@as(u256, 300), iface.getBalance(addr3));
}

test "Host multiple addresses with different code" {
    const testing = std.testing;
    var host = try Host.init(testing.allocator);
    defer host.deinit();

    const addr1 = try Address.fromBytes(&[_]u8{13} ** 20);
    const addr2 = try Address.fromBytes(&[_]u8{14} ** 20);
    const code1 = [_]u8{ 0x60, 0x01 };
    const code2 = [_]u8{ 0x60, 0x02 };

    try host.setCode(addr1, &code1);
    try host.setCode(addr2, &code2);

    const iface = host.hostInterface();
    const retrieved1 = iface.getCode(addr1);
    const retrieved2 = iface.getCode(addr2);
    try testing.expectEqualSlices(u8, &code1, retrieved1);
    try testing.expectEqualSlices(u8, &code2, retrieved2);
}

test "Host innerCall returns success with empty output" {
    const testing = std.testing;
    var host = try Host.init(testing.allocator);
    defer host.deinit();

    const addr = try Address.fromBytes(&[_]u8{15} ** 20);
    const input = [_]u8{ 0x01, 0x02, 0x03 };
    const gas: u64 = 1000;

    const iface = host.hostInterface();
    const result = iface.innerCall(gas, addr, 0, &input, .Call);
    try testing.expectEqual(true, result.success);
    try testing.expectEqual(gas, result.gas_left);
    try testing.expectEqualSlices(u8, &[_]u8{}, result.output);
}

test "Host large storage values" {
    const testing = std.testing;
    var host = try Host.init(testing.allocator);
    defer host.deinit();

    const addr = try Address.fromBytes(&[_]u8{16} ** 20);
    const slot: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    const value: u256 = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA;

    const iface = host.hostInterface();
    try iface.setStorage(addr, slot, value);
    const retrieved = iface.getStorage(addr, slot);
    try testing.expectEqual(value, retrieved);
}

test "Host empty code storage" {
    const testing = std.testing;
    var host = try Host.init(testing.allocator);
    defer host.deinit();

    const addr = try Address.fromBytes(&[_]u8{17} ** 20);
    const empty_code = [_]u8{};
    try host.setCode(addr, &empty_code);

    const iface = host.hostInterface();
    const retrieved = iface.getCode(addr);
    try testing.expectEqualSlices(u8, &empty_code, retrieved);
}
