// File: src/evm/prestate_tracer.zig
// Complete prestate tracer implementation (data-format agnostic)
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

// Use builtin u256

pub const PrestateTracer = struct {
    allocator: std.mem.Allocator,
    enabled: bool = true,
    diff_mode: bool = false,
    disable_storage: bool = false,
    disable_code: bool = false,

    state_changes: std.ArrayList(StateChange),
    touched_accounts: std.AutoHashMap(Address, void),
    prestate: std.AutoHashMap(Address, AccountState),
    poststate: std.AutoHashMap(Address, AccountState),
    total_instructions: u64 = 0,

    const Self = @This();

    pub const StateChange = struct {
        step_number: u64,
        address: Address,
        change_type: ChangeType,

        pub const ChangeType = union(enum) {
            storage: StorageChange,
            balance: BalanceChange,
            nonce: NonceChange,
            code: CodeChange,
            account_created: AccountCreated,
            account_destroyed: AccountDestroyed,
        };

        pub const StorageChange = struct {
            slot: u256,
            old_value: u256,
            new_value: u256,
            is_warm: bool,
        };

        pub const BalanceChange = struct {
            old_balance: u256,
            new_balance: u256,
        };

        pub const NonceChange = struct {
            old_nonce: u64,
            new_nonce: u64,
        };

        pub const CodeChange = struct {
            old_code: []const u8,
            new_code: []const u8,
            old_code_hash: [32]u8,
            new_code_hash: [32]u8,
        };

        pub const AccountCreated = struct {
            initial_balance: u256,
            initial_nonce: u64,
            code: []const u8,
        };

        pub const AccountDestroyed = struct {
            beneficiary: Address,
            balance_transferred: u256,
            had_code: bool,
            storage_cleared: bool,
        };
    };

    pub const AccountState = struct {
        balance: u256,
        nonce: u64,
        code: []const u8,
        code_hash: [32]u8,
        storage: std.AutoHashMap(u256, u256),
        exists: bool,

        pub fn init(allocator: std.mem.Allocator) AccountState {
            return .{
                .balance = 0,
                .nonce = 0,
                .code = &[_]u8{},
                .code_hash = [_]u8{0} ** 32,
                .storage = std.AutoHashMap(u256, u256).init(allocator),
                .exists = false,
            };
        }

        pub fn deinit(self: *AccountState, allocator: std.mem.Allocator) void {
            if (self.code.len > 0) allocator.free(self.code);
            self.storage.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .state_changes = std.ArrayList(StateChange).init(allocator),
            .touched_accounts = std.AutoHashMap(Address, void).init(allocator),
            .prestate = std.AutoHashMap(Address, AccountState).init(allocator),
            .poststate = std.AutoHashMap(Address, AccountState).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.state_changes.deinit();
        self.touched_accounts.deinit();

        var it1 = self.prestate.iterator();
        while (it1.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.prestate.deinit();

        var it2 = self.poststate.iterator();
        while (it2.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.poststate.deinit();
    }

    pub fn configure(self: *Self, diff_mode: bool, disable_storage: bool, disable_code: bool) void {
        self.diff_mode = diff_mode;
        self.disable_storage = disable_storage;
        self.disable_code = disable_code;
    }

    // Tracer interface compatibility (Frame.traceBefore/After/OnError)
    pub fn beforeOp(self: *Self, pc: u32, opcode: u8, comptime FrameType: type, frame: *const FrameType) void {
        _ = pc; _ = opcode; _ = frame;
        if (self.enabled) self.total_instructions += 1;
    }

    pub fn afterOp(self: *Self, pc: u32, opcode: u8, comptime FrameType: type, frame: *const FrameType) void {
        _ = self; _ = pc; _ = opcode; _ = frame;
    }

    pub fn onError(self: *Self, pc: u32, err: anyerror, comptime FrameType: type, frame: *const FrameType) void {
        _ = pc; _ = err; _ = frame; _ = self;
    }

    // ===== Transaction lifecycle =====
    pub fn on_transaction_start(self: *Self) void {
        if (!self.enabled) return;
        self.touched_accounts.clearRetainingCapacity();

        var it1 = self.prestate.iterator();
        while (it1.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.prestate.clearRetainingCapacity();

        var it2 = self.poststate.iterator();
        while (it2.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.poststate.clearRetainingCapacity();

        self.state_changes.clearRetainingCapacity();
    }

    pub fn on_transaction_end(self: *Self) void {
        if (!self.enabled) return;
        self.build_poststate();
    }

    // ===== Storage operations =====
    pub fn on_storage_read(self: *Self, address: Address, slot: u256, value: u256, is_warm: bool) void {
        if (!self.enabled) return;
        const change = StateChange{
            .step_number = self.total_instructions,
            .address = address,
            .change_type = .{ .storage = .{ .slot = slot, .old_value = value, .new_value = value, .is_warm = is_warm } },
        };
        self.state_changes.append(change) catch {};

        if (!self.disable_storage) {
            self.touch_account(address);
            const account = self.ensure_prestate_account(address) catch return;
            if (!account.storage.contains(slot)) {
                account.storage.put(slot, value) catch {};
            }
        }
    }

    pub fn on_storage_write(self: *Self, address: Address, slot: u256, old_value: u256, new_value: u256, is_warm: bool) void {
        if (!self.enabled) return;
        const change = StateChange{
            .step_number = self.total_instructions,
            .address = address,
            .change_type = .{ .storage = .{ .slot = slot, .old_value = old_value, .new_value = new_value, .is_warm = is_warm } },
        };
        self.state_changes.append(change) catch {};

        if (!self.disable_storage) {
            self.touch_account(address);
            const account = self.ensure_prestate_account(address) catch return;
            if (!account.storage.contains(slot)) {
                account.storage.put(slot, old_value) catch {};
            }
        }
    }

    // ===== Balance operations =====
    pub fn on_balance_read(self: *Self, address: Address, balance: u256) void {
        if (!self.enabled) return;
        self.touch_account(address);
        const account = self.ensure_prestate_account(address) catch return;
        if (!account.exists) {
            account.balance = balance;
            account.exists = true;
        } else if (account.balance == 0 and balance != 0) {
            // Capture first known balance if not yet set
            account.balance = balance;
        }
    }

    pub fn on_balance_change(self: *Self, address: Address, old_balance: u256, new_balance: u256) void {
        if (!self.enabled) return;
        const change = StateChange{
            .step_number = self.total_instructions,
            .address = address,
            .change_type = .{ .balance = .{ .old_balance = old_balance, .new_balance = new_balance } },
        };
        self.state_changes.append(change) catch {};

        self.touch_account(address);
        const account = self.ensure_prestate_account(address) catch return;
        if (!account.exists) {
            account.balance = old_balance;
            account.exists = true;
        }
    }

    // ===== Nonce operations =====
    pub fn on_nonce_read(self: *Self, address: Address, nonce: u64) void {
        if (!self.enabled) return;
        self.touch_account(address);
        const account = self.ensure_prestate_account(address) catch return;
        if (!account.exists) {
            account.nonce = nonce;
            account.exists = true;
        } else if (account.nonce == 0 and nonce != 0) {
            account.nonce = nonce;
        }
    }

    pub fn on_nonce_change(self: *Self, address: Address, old_nonce: u64, new_nonce: u64) void {
        if (!self.enabled) return;
        const change = StateChange{
            .step_number = self.total_instructions,
            .address = address,
            .change_type = .{ .nonce = .{ .old_nonce = old_nonce, .new_nonce = new_nonce } },
        };
        self.state_changes.append(change) catch {};

        self.touch_account(address);
        const account = self.ensure_prestate_account(address) catch return;
        if (!account.exists) {
            account.nonce = old_nonce;
            account.exists = true;
        }
    }

    // ===== Code operations =====
    pub fn on_code_read(self: *Self, address: Address, code: []const u8) void {
        if (!self.enabled or self.disable_code) return;
        self.touch_account(address);
        const account = self.ensure_prestate_account(address) catch return;
        if (!account.exists or account.code.len == 0) {
            account.code = self.allocator.dupe(u8, code) catch &[_]u8{};
            account.code_hash = hash_code(code);
            account.exists = true;
        }
    }

    pub fn on_code_change(self: *Self, address: Address, old_code: []const u8, new_code: []const u8) void {
        if (!self.enabled) return;
        const change = StateChange{
            .step_number = self.total_instructions,
            .address = address,
            .change_type = .{ .code = .{ .old_code = old_code, .new_code = new_code, .old_code_hash = hash_code(old_code), .new_code_hash = hash_code(new_code) } },
        };
        self.state_changes.append(change) catch {};

        if (!self.disable_code) {
            self.touch_account(address);
            const account = self.ensure_prestate_account(address) catch return;
            if (!account.exists) {
                account.code = self.allocator.dupe(u8, old_code) catch &[_]u8{};
                account.code_hash = hash_code(old_code);
                account.exists = true;
            }
        }
    }

    // ===== Account lifecycle =====
    pub fn on_account_created(self: *Self, address: Address, initial_balance: u256, initial_nonce: u64, code: []const u8) void {
        if (!self.enabled) return;
        const change = StateChange{
            .step_number = self.total_instructions,
            .address = address,
            .change_type = .{ .account_created = .{ .initial_balance = initial_balance, .initial_nonce = initial_nonce, .code = code } },
        };
        self.state_changes.append(change) catch {};

        self.touch_account(address);
        const account = self.ensure_prestate_account(address) catch return;
        // Don't add to prestate - it didn't exist before
        _ = account;
    }

    pub fn on_account_destroyed(self: *Self, address: Address, beneficiary: Address, balance_transferred: u256, had_code: bool, storage_cleared: bool) void {
        if (!self.enabled) return;
        const change = StateChange{
            .step_number = self.total_instructions,
            .address = address,
            .change_type = .{ .account_destroyed = .{ .beneficiary = beneficiary, .balance_transferred = balance_transferred, .had_code = had_code, .storage_cleared = storage_cleared } },
        };
        self.state_changes.append(change) catch {};

        self.touch_account(address);
        // Prestate unchanged; poststate will mark exists=false
    }

    // ===== Helpers =====
    fn touch_account(self: *Self, address: Address) void {
        _ = self.touched_accounts.put(address, {}) catch {};
    }

    fn ensure_prestate_account(self: *Self, address: Address) !*AccountState {
        const result = try self.prestate.getOrPut(address);
        if (!result.found_existing) {
            result.value_ptr.* = AccountState.init(self.allocator);
        }
        return result.value_ptr;
    }

    fn build_poststate(self: *Self) void {
        // Start with prestate snapshot
        var it = self.prestate.iterator();
        while (it.next()) |entry| {
            const addr = entry.key_ptr.*;
            const pre = entry.value_ptr.*;
            var post = AccountState.init(self.allocator);
            post.balance = pre.balance;
            post.nonce = pre.nonce;
            post.code = if (pre.code.len > 0) self.allocator.dupe(u8, pre.code) catch &[_]u8{} else &[_]u8{};
            post.code_hash = pre.code_hash;
            post.exists = pre.exists;
            var sit = pre.storage.iterator();
            while (sit.next()) |se| {
                post.storage.put(se.key_ptr.*, se.value_ptr.*) catch {};
            }
            self.poststate.put(addr, post) catch {};
        }

        // Apply chronological changes
        for (self.state_changes.items) |change| {
            const got = self.poststate.getOrPut(change.address) catch continue;
            if (!got.found_existing) got.value_ptr.* = AccountState.init(self.allocator);
            switch (change.change_type) {
                .storage => |s| {
                    if (!self.disable_storage) {
                        got.value_ptr.storage.put(s.slot, s.new_value) catch {};
                    }
                },
                .balance => |b| got.value_ptr.balance = b.new_balance,
                .nonce => |n| got.value_ptr.nonce = n.new_nonce,
                .code => |c| {
                    if (!self.disable_code) {
                        if (got.value_ptr.code.len > 0) self.allocator.free(got.value_ptr.code);
                        got.value_ptr.code = self.allocator.dupe(u8, c.new_code) catch &[_]u8{};
                        got.value_ptr.code_hash = c.new_code_hash;
                    }
                },
                .account_created => |a| {
                    got.value_ptr.balance = a.initial_balance;
                    got.value_ptr.nonce = a.initial_nonce;
                    if (!self.disable_code and a.code.len > 0) {
                        got.value_ptr.code = self.allocator.dupe(u8, a.code) catch &[_]u8{};
                        got.value_ptr.code_hash = hash_code(a.code);
                    }
                    got.value_ptr.exists = true;
                },
                .account_destroyed => |_| {
                    got.value_ptr.exists = false;
                },
            }
        }
    }

    fn hash_code(code: []const u8) [32]u8 {
        if (code.len == 0) return [_]u8{0} ** 32;
        const crypto = @import("crypto");
        return crypto.Hash.keccak256(code);
    }

    // Accessors
    pub fn get_prestate(self: *const Self) *const std.AutoHashMap(Address, AccountState) { return &self.prestate; }
    pub fn get_poststate(self: *const Self) *const std.AutoHashMap(Address, AccountState) { return &self.poststate; }
    pub fn is_diff_mode(self: *const Self) bool { return self.diff_mode; }
    pub fn is_storage_disabled(self: *const Self) bool { return self.disable_storage; }
    pub fn is_code_disabled(self: *const Self) bool { return self.disable_code; }
};

// ===== JSON formatting (standalone) =====
pub fn write_prestate_json(writer: anytype, tracer: *const PrestateTracer) !void {
    if (tracer.is_diff_mode()) {
        try writer.writeAll("{\"pre\":{");
        try write_state_map_json(writer, tracer.get_prestate(), tracer.is_storage_disabled(), tracer.is_code_disabled());
        try writer.writeAll("},\"post\":{");
        try write_state_map_json(writer, tracer.get_poststate(), tracer.is_storage_disabled(), tracer.is_code_disabled());
        try writer.writeAll("}}");
    } else {
        try writer.writeByte('{');
        try write_state_map_json(writer, tracer.get_prestate(), tracer.is_storage_disabled(), tracer.is_code_disabled());
        try writer.writeByte('}');
    }
}

pub fn write_state_map_json(
    writer: anytype,
    state_map: *const std.AutoHashMap(Address, PrestateTracer.AccountState),
    disable_storage: bool,
    disable_code: bool,
) !void {
    var first = true;
    var iter = state_map.iterator();
    while (iter.next()) |entry| {
        if (!first) try writer.writeByte(',');
        first = false;

        const addr = entry.key_ptr.*;
        const account = entry.value_ptr.*;

        try writer.writeByte('"');
        try writer.print("0x{x:0>40}", .{addr});
        try writer.writeAll("\":{");

        try writer.print("\"balance\":\"0x{x}\",", .{account.balance});
        try writer.print("\"nonce\":{},", .{account.nonce});

        if (!disable_code and account.code.len > 0) {
            try writer.writeAll("\"code\":\"0x");
            for (account.code) |byte| try writer.print("{x:0>2}", .{byte});
            try writer.writeAll("\",");
        }

        if (!disable_storage and account.storage.count() > 0) {
            try writer.writeAll("\"storage\":{");
            var storage_first = true;
            var sit = account.storage.iterator();
            while (sit.next()) |se| {
                if (!storage_first) try writer.writeByte(',');
                storage_first = false;
                try writer.print("\"0x{x}\":\"0x{x}\"", .{ se.key_ptr.*, se.value_ptr.* });
            }
            try writer.writeByte('}');
        }

        try writer.writeByte('}');
    }
}

// ===== Tests =====
test "PrestateTracer captures all state changes" {
    const allocator = std.testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    tracer.configure(false, false, false);
    tracer.on_transaction_start();

    const addr1: Address = [_]u8{1} ** 20;
    const addr2: Address = [_]u8{2} ** 20;

    tracer.on_balance_read(addr1, 1000);
    tracer.on_nonce_read(addr1, 5);
    tracer.on_storage_read(addr1, 0x42, 100, false);

    tracer.on_balance_change(addr1, 1000, 900);
    tracer.on_balance_change(addr2, 0, 100);
    tracer.on_storage_write(addr1, 0x42, 100, 200, true);

    tracer.on_transaction_end();

    try std.testing.expect(tracer.prestate.contains(addr1));
    try std.testing.expect(tracer.prestate.contains(addr2));

    const account1_pre = tracer.prestate.get(addr1).?;
    try std.testing.expectEqual(@as(u256, 1000), account1_pre.balance);
    try std.testing.expectEqual(@as(u64, 5), account1_pre.nonce);
    try std.testing.expectEqual(@as(u256, 100), account1_pre.storage.get(0x42).?);

    const account1_post = tracer.poststate.get(addr1).?;
    try std.testing.expectEqual(@as(u256, 900), account1_post.balance);
    try std.testing.expectEqual(@as(u256, 200), account1_post.storage.get(0x42).?);
}

test "PrestateTracer memory management" {
    const allocator = std.testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    tracer.on_transaction_start();
    const addr: Address = [_]u8{3} ** 20;
    tracer.on_code_read(addr, "test code");
    tracer.on_transaction_end();
}

test "PrestateTracer handles empty transaction" {
    const allocator = std.testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    tracer.on_transaction_start();
    tracer.on_transaction_end();
    // Should not crash and pre/post should be empty
    try std.testing.expectEqual(@as(usize, 0), tracer.prestate.count());
    try std.testing.expectEqual(@as(usize, 0), tracer.poststate.count());
}

test "prestate tracer integrated with frame interpreter execution" {
    // This test follows the working pattern from "FrameInterpreter database integration - SLOAD/SSTORE operations"
    // It executes bytecode through the frame interpreter with PrestateTracer.
    // The frame automatically calls tracer hooks during opcode execution.
    
    const allocator = std.testing.allocator;
    const frame_interpreter = @import("frame_interpreter.zig");
    const memory_database = @import("memory_database.zig");
    const evm_mod = @import("evm.zig");
    const log = @import("log.zig");
    const FrameConfig = @import("frame_config.zig").FrameConfig;
    
    // Test addresses
    const CONTRACT_ADDRESS: Address = [_]u8{0x42} ** 20;
    
    // Create database
    var memory_db = memory_database.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    // Set up accounts for testing
    const CALLER_ADDRESS = Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{0x11});
    
    // Set up contract account with balance and code
    try memory_db.set_account(CONTRACT_ADDRESS, .{
        .nonce = 5,
        .balance = 50000,
        .code_hash = [_]u8{0xAA} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Set up caller account with balance
    try memory_db.set_account(CALLER_ADDRESS, .{
        .nonce = 10,
        .balance = 100000,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Set initial storage values for comprehensive testing
    try memory_db.set_storage(CONTRACT_ADDRESS, 0x01, 100); // slot 1 = 100
    try memory_db.set_storage(CONTRACT_ADDRESS, 0x02, 200); // slot 2 = 200
    // slot 3 will be new (0 -> 99)
    // slot 4 will be new with multiple writes
    
    // Create a tracer instance that will be used by the frame
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    // Start transaction tracking
    tracer.on_transaction_start();
    defer tracer.on_transaction_end();
    
    // Comprehensive bytecode testing ALL prestate tracer features
    // This tests everything the prestate tracer can capture:
    // - Storage reads (SLOAD)
    // - Storage writes (SSTORE) 
    // - Balance reads (BALANCE)
    // - Code reads (EXTCODESIZE, EXTCODECOPY, EXTCODEHASH)
    // - Multiple slots, including overwrites and new slots
    const bytecode = [_]u8{ 
        // 1. SLOAD from slot 1 (captures initial value 100)
        0x60, 0x01,  // PUSH1 0x01
        0x54,        // SLOAD
        0x50,        // POP
        
        // 2. SLOAD from slot 2 (captures initial value 200)
        0x60, 0x02,  // PUSH1 0x02
        0x54,        // SLOAD
        0x50,        // POP
        
        // 3. SSTORE to slot 1 (changes 100 -> 0x42)
        0x60, 0x42,  // PUSH1 0x42 (value)
        0x60, 0x01,  // PUSH1 0x01 (key)
        0x55,        // SSTORE
        
        // 4. SSTORE to slot 2 (changes 200 -> 0, deletion)
        0x60, 0x00,  // PUSH1 0x00 (value)
        0x60, 0x02,  // PUSH1 0x02 (key)
        0x55,        // SSTORE
        
        // 5. SSTORE to new slot 3 (creates new slot 0 -> 0x99)
        0x60, 0x99,  // PUSH1 0x99 (value)
        0x60, 0x03,  // PUSH1 0x03 (key)
        0x55,        // SSTORE
        
        // 6. Re-read slot 1 to verify it's warm and changed
        0x60, 0x01,  // PUSH1 0x01
        0x54,        // SLOAD (should read 0x42 now)
        0x50,        // POP
        
        // 7. BALANCE of contract address (captures balance)
        0x30,        // ADDRESS (pushes contract address)
        0x31,        // BALANCE
        0x50,        // POP
        
        // 8. BALANCE of caller address
        0x33,        // CALLER (pushes caller address)
        0x31,        // BALANCE  
        0x50,        // POP
        
        // 9. EXTCODESIZE of contract (captures code size)
        0x30,        // ADDRESS
        0x3B,        // EXTCODESIZE
        0x50,        // POP
        
        // 10. SELFBALANCE (another way to read balance)
        0x47,        // SELFBALANCE
        0x50,        // POP
        
        // 11. Multiple writes to same slot (for testing update tracking)
        0x60, 0xAA,  // PUSH1 0xAA (value)
        0x60, 0x04,  // PUSH1 0x04 (key)
        0x55,        // SSTORE (first write to slot 4)
        
        0x60, 0xBB,  // PUSH1 0xBB (value)
        0x60, 0x04,  // PUSH1 0x04 (key)
        0x55,        // SSTORE (overwrite slot 4)
        
        // 12. EXTCODEHASH to trigger more code reading
        0x30,        // ADDRESS
        0x3F,        // EXTCODEHASH
        0x50,        // POP
        
        // 13. SELFDESTRUCT (to test on_account_destroyed)
        // Note: This should be the last operation as it terminates execution
        // Push beneficiary address (using caller for simplicity)
        0x33,        // CALLER (beneficiary)
        0xFF,        // SELFDESTRUCT
        
        0x00         // STOP (won't be reached after SELFDESTRUCT)
    };
    
    // Create a simple test tracer that wraps PrestateTracer
    const TestTracerWrapper = struct {
        prestate_tracer: *PrestateTracer,
        
        pub fn init() @This() {
            // Can't initialize here since we need the external tracer
            return .{ .prestate_tracer = undefined };
        }
        
        pub fn on_storage_read(self: *@This(), address: Address, slot: u256, value: u256, is_warm: bool) void {
            self.prestate_tracer.on_storage_read(address, slot, value, is_warm);
        }
        
        pub fn on_storage_write(self: *@This(), address: Address, slot: u256, old_value: u256, new_value: u256, is_warm: bool) void {
            self.prestate_tracer.on_storage_write(address, slot, old_value, new_value, is_warm);
        }
        
        pub fn on_balance_read(self: *@This(), address: Address, balance: u256) void {
            self.prestate_tracer.on_balance_read(address, balance);
        }
        
        pub fn on_code_read(self: *@This(), address: Address, code: []const u8) void {
            self.prestate_tracer.on_code_read(address, code);
        }
        
        pub fn on_account_destroyed(self: *@This(), address: Address, beneficiary: Address, balance_transferred: u256, had_code: bool, storage_cleared: bool) void {
            self.prestate_tracer.on_account_destroyed(address, beneficiary, balance_transferred, had_code, storage_cleared);
        }
    };
    
    // Create frame interpreter with wrapper tracer
    const frame_config = FrameConfig{
        .TracerType = TestTracerWrapper,
        .has_database = true,
    };
    const FrameInterpreterType = frame_interpreter.FrameInterpreter(frame_config);
    
    // Initialize interpreter with bytecode, database, and host (like working test)
    var interpreter = try FrameInterpreterType.init(
        allocator, 
        &bytecode, 
        100000,  // Same gas as working test
        db_interface,
        evm_mod.DefaultHost.init()  // Use DefaultHost like the working test!
    );
    defer interpreter.deinit(allocator);
    
    // Now connect the actual tracer
    interpreter.frame.tracer.prestate_tracer = &tracer;
    
    // Set up execution context
    interpreter.frame.contract_address = CONTRACT_ADDRESS;
    interpreter.frame.caller = CALLER_ADDRESS;
    
    // EXECUTE THE BYTECODE - tracer hooks are called automatically by the frame!
    try interpreter.interpret();
    
    // Now check what the tracer captured - NO MANUAL HOOK CALLS WERE MADE!
    // The frame should have automatically called ALL tracer hooks during execution
    
    // ========== PRESTATE VERIFICATION ==========
    // Verify prestate captured initial values for CONTRACT_ADDRESS
    try std.testing.expect(tracer.prestate.contains(CONTRACT_ADDRESS));
    const contract_prestate = tracer.prestate.get(CONTRACT_ADDRESS).?;
    
    // Check initial balance was captured (from BALANCE/SELFBALANCE opcodes)
    try std.testing.expectEqual(@as(u256, 50000), contract_prestate.balance);
    
    // Check initial nonce was captured
    try std.testing.expectEqual(@as(u64, 5), contract_prestate.nonce);
    
    // Check storage prestate - slot 1 should have initial value 100
    try std.testing.expect(contract_prestate.storage.contains(0x01));
    try std.testing.expectEqual(@as(u256, 100), contract_prestate.storage.get(0x01).?);
    
    // Check storage prestate - slot 2 should have initial value 200
    try std.testing.expect(contract_prestate.storage.contains(0x02));
    try std.testing.expectEqual(@as(u256, 200), contract_prestate.storage.get(0x02).?);
    
    // Check storage prestate - slot 3 should be 0 (new slot that will be written)
    try std.testing.expect(contract_prestate.storage.contains(0x03));
    try std.testing.expectEqual(@as(u256, 0), contract_prestate.storage.get(0x03).?);
    
    // Check storage prestate - slot 4 should be 0 (new slot with multiple writes)
    try std.testing.expect(contract_prestate.storage.contains(0x04));
    try std.testing.expectEqual(@as(u256, 0), contract_prestate.storage.get(0x04).?);
    
    // ========== POSTSTATE VERIFICATION ==========
    // Verify poststate captured all changes
    try std.testing.expect(tracer.poststate.contains(CONTRACT_ADDRESS));
    const contract_poststate = tracer.poststate.get(CONTRACT_ADDRESS).?;
    
    // Balance shouldn't change (no value transfers in our bytecode)
    try std.testing.expectEqual(@as(u256, 50000), contract_poststate.balance);
    
    // Check storage poststate - slot 1 should now be 0x42 (changed from 100)
    try std.testing.expect(contract_poststate.storage.contains(0x01));
    try std.testing.expectEqual(@as(u256, 0x42), contract_poststate.storage.get(0x01).?);
    
    // Check storage poststate - slot 2 should now be 0 (deleted from 200)
    try std.testing.expect(contract_poststate.storage.contains(0x02));
    try std.testing.expectEqual(@as(u256, 0), contract_poststate.storage.get(0x02).?);
    
    // Check storage poststate - slot 3 should now be 0x99 (new slot)
    try std.testing.expect(contract_poststate.storage.contains(0x03));
    try std.testing.expectEqual(@as(u256, 0x99), contract_poststate.storage.get(0x03).?);
    
    // Check storage poststate - slot 4 should be 0xBB (final value after two writes)
    try std.testing.expect(contract_poststate.storage.contains(0x04));
    try std.testing.expectEqual(@as(u256, 0xBB), contract_poststate.storage.get(0x04).?);
    
    // ========== DATABASE VERIFICATION ==========
    // Verify the actual storage was modified in the database
    try std.testing.expectEqual(@as(u256, 0x42), memory_db.get_storage(CONTRACT_ADDRESS, 0x01));
    try std.testing.expectEqual(@as(u256, 0), memory_db.get_storage(CONTRACT_ADDRESS, 0x02));
    try std.testing.expectEqual(@as(u256, 0x99), memory_db.get_storage(CONTRACT_ADDRESS, 0x03));
    try std.testing.expectEqual(@as(u256, 0xBB), memory_db.get_storage(CONTRACT_ADDRESS, 0x04));
    
    // ========== STATE CHANGE LOG VERIFICATION ==========
    // Verify state changes were logged in order
    try std.testing.expect(tracer.state_changes.items.len > 0);
    
    // Look for specific state changes
    var found_storage_read_slot1 = false;
    var found_storage_read_slot2 = false;
    var found_storage_write_slot1 = false;
    var found_storage_write_slot2 = false;
    var found_storage_write_slot3 = false;
    var found_storage_write_slot4_first = false;
    var found_storage_write_slot4_second = false;
    var found_balance_read_contract = false;
    var found_balance_read_caller = false;
    var found_code_read = false;
    var found_account_destroyed = false;
    
    for (tracer.state_changes.items) |change| {
        switch (change) {
            .StorageRead => |read| {
                if (read.slot == 0x01 and read.value == 100) found_storage_read_slot1 = true;
                if (read.slot == 0x02 and read.value == 200) found_storage_read_slot2 = true;
            },
            .StorageWrite => |write| {
                if (write.slot == 0x01 and write.old_value == 100 and write.new_value == 0x42) {
                    found_storage_write_slot1 = true;
                }
                if (write.slot == 0x02 and write.old_value == 200 and write.new_value == 0) {
                    found_storage_write_slot2 = true;
                }
                if (write.slot == 0x03 and write.old_value == 0 and write.new_value == 0x99) {
                    found_storage_write_slot3 = true;
                }
                if (write.slot == 0x04 and write.old_value == 0 and write.new_value == 0xAA) {
                    found_storage_write_slot4_first = true;
                }
                if (write.slot == 0x04 and write.old_value == 0xAA and write.new_value == 0xBB) {
                    found_storage_write_slot4_second = true;
                }
            },
            .BalanceRead => |read| {
                if (read.address == CONTRACT_ADDRESS and read.balance == 50000) found_balance_read_contract = true;
                if (read.address == CALLER_ADDRESS and read.balance == 100000) found_balance_read_caller = true;
            },
            .CodeRead => |read| {
                if (std.mem.eql(u8, read.code, &bytecode)) found_code_read = true;
            },
            .AccountDestroyed => |destroyed| {
                if (destroyed.address == CONTRACT_ADDRESS and 
                    destroyed.balance_transferred == 50000 and
                    destroyed.storage_cleared) {
                    found_account_destroyed = true;
                }
            },
            else => {},
        }
    }
    
    // Verify all expected state changes were captured
    try std.testing.expect(found_storage_read_slot1);
    try std.testing.expect(found_storage_read_slot2);
    try std.testing.expect(found_storage_write_slot1);
    try std.testing.expect(found_storage_write_slot2);
    try std.testing.expect(found_storage_write_slot3);
    try std.testing.expect(found_storage_write_slot4_first);
    try std.testing.expect(found_storage_write_slot4_second);
    try std.testing.expect(found_balance_read_contract);
    try std.testing.expect(found_balance_read_caller);
    try std.testing.expect(found_code_read);
    try std.testing.expect(found_account_destroyed);
    
    log.debug("Frame interpreter with integrated PrestateTracer test completed successfully!", .{});
    log.debug("All state changes were captured automatically by the frame during bytecode execution.", .{});
}