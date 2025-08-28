// File: src/evm/prestate_tracer.zig
// Complete prestate tracer implementation for Ethereum state tracing
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

pub const PrestateTracer = struct {
    allocator: std.mem.Allocator,
    enabled: bool = true,
    diff_mode: bool = false,
    disable_storage: bool = false,
    disable_code: bool = false,
    include_empty: bool = false,

    // Track accounts by their interaction type
    created_accounts: std.AutoHashMap(Address, void),
    deleted_accounts: std.AutoHashMap(Address, void),
    modified_accounts: std.AutoHashMap(Address, void),
    accessed_accounts: std.AutoHashMap(Address, void),

    // State snapshots
    prestate: std.AutoHashMap(Address, AccountState),
    poststate: std.AutoHashMap(Address, AccountState),

    // Track modifications for diff mode
    storage_modifications: std.AutoHashMap(Address, std.AutoHashMap(u256, StorageModification)),

    total_instructions: u64 = 0,

    const Self = @This();

    pub const StorageModification = struct {
        original_value: u256,
        current_value: u256,
        was_read: bool,
        was_modified: bool,
    };

    pub const AccountState = struct {
        balance: u256,
        nonce: u64,
        code: []const u8,
        code_hash: [32]u8,
        storage: std.AutoHashMap(u256, u256),
        exists: bool,
        is_empty: bool,

        pub fn init(allocator: std.mem.Allocator) AccountState {
            return .{
                .balance = 0,
                .nonce = 0,
                .code = &[_]u8{},
                .code_hash = [_]u8{0} ** 32,
                .storage = std.AutoHashMap(u256, u256).init(allocator),
                .exists = false,
                .is_empty = true,
            };
        }

        pub fn deinit(self: *AccountState, allocator: std.mem.Allocator) void {
            if (self.code.len > 0) allocator.free(self.code);
            self.storage.deinit();
        }

        pub fn isEmpty(self: *const AccountState) bool {
            return self.balance == 0 and self.nonce == 0 and self.code.len == 0;
        }

        pub fn clone(self: *const AccountState, allocator: std.mem.Allocator) !AccountState {
            var new_state = AccountState.init(allocator);
            new_state.balance = self.balance;
            new_state.nonce = self.nonce;
            if (self.code.len > 0) {
                new_state.code = try allocator.dupe(u8, self.code);
            }
            new_state.code_hash = self.code_hash;
            new_state.exists = self.exists;
            new_state.is_empty = self.is_empty;

            var iter = self.storage.iterator();
            while (iter.next()) |entry| {
                try new_state.storage.put(entry.key_ptr.*, entry.value_ptr.*);
            }

            return new_state;
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .created_accounts = std.AutoHashMap(Address, void).init(allocator),
            .deleted_accounts = std.AutoHashMap(Address, void).init(allocator),
            .modified_accounts = std.AutoHashMap(Address, void).init(allocator),
            .accessed_accounts = std.AutoHashMap(Address, void).init(allocator),
            .prestate = std.AutoHashMap(Address, AccountState).init(allocator),
            .poststate = std.AutoHashMap(Address, AccountState).init(allocator),
            .storage_modifications = std.AutoHashMap(Address, std.AutoHashMap(u256, StorageModification)).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.created_accounts.deinit();
        self.deleted_accounts.deinit();
        self.modified_accounts.deinit();
        self.accessed_accounts.deinit();

        var it1 = self.prestate.iterator();
        while (it1.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.prestate.deinit();

        var it2 = self.poststate.iterator();
        while (it2.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.poststate.deinit();

        var storage_iter = self.storage_modifications.iterator();
        while (storage_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.storage_modifications.deinit();
    }

    pub const Config = struct {
        diff_mode: bool = false,
        disable_storage: bool = false,
        disable_code: bool = false,
        include_empty: bool = false,
    };

    pub fn configure(self: *Self, cfg: Config) void {
        self.diff_mode = cfg.diff_mode;
        self.disable_storage = cfg.disable_storage;
        self.disable_code = cfg.disable_code;
        self.include_empty = cfg.include_empty;
    }

    // Tracer interface compatibility (Frame.traceBefore/After/OnError)
    pub fn beforeOp(self: *Self, pc: u32, opcode: u8, comptime FrameType: type, frame: *const FrameType) void {
        _ = pc;
        _ = opcode;
        _ = frame;
        if (self.enabled) self.total_instructions += 1;
    }

    pub fn afterOp(self: *Self, pc: u32, opcode: u8, comptime FrameType: type, frame: *const FrameType) void {
        _ = self;
        _ = pc;
        _ = opcode;
        _ = frame;
    }

    // ===== Transaction lifecycle =====
    pub fn onTransactionStart(self: *Self) void {
        if (!self.enabled) return;

        self.created_accounts.clearRetainingCapacity();
        self.deleted_accounts.clearRetainingCapacity();
        self.modified_accounts.clearRetainingCapacity();
        self.accessed_accounts.clearRetainingCapacity();

        var it1 = self.prestate.iterator();
        while (it1.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.prestate.clearRetainingCapacity();

        var it2 = self.poststate.iterator();
        while (it2.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.poststate.clearRetainingCapacity();

        var storage_iter = self.storage_modifications.iterator();
        while (storage_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.storage_modifications.clearRetainingCapacity();

        self.total_instructions = 0;
    }

    pub fn onTransactionEnd(self: *Self) void {
        if (!self.enabled) return;
        self.buildFinalStates() catch {};
    }

    // ===== Storage operations =====
    pub fn onStorageRead(self: *Self, address: Address, slot: u256, value: u256, is_warm: bool) void {
        _ = is_warm;
        if (!self.enabled or self.disable_storage) return;

        self.markAccountAccessed(address);

        // Record the original value if this is the first access
        const storage_map = self.ensureStorageModifications(address) catch return;
        const result = storage_map.getOrPut(slot) catch return;
        if (!result.found_existing) {
            result.value_ptr.* = .{
                .original_value = value,
                .current_value = value,
                .was_read = true,
                .was_modified = false,
            };
        } else {
            result.value_ptr.was_read = true;
        }

        // Ensure prestate has this value
        const account = self.ensurePrestateAccount(address) catch return;
        if (!account.storage.contains(slot)) {
            account.storage.put(slot, value) catch {};
        }
    }

    pub fn onStorageWrite(self: *Self, address: Address, slot: u256, old_value: u256, new_value: u256, is_warm: bool) void {
        _ = is_warm;
        if (!self.enabled or self.disable_storage) return;

        self.markAccountAccessed(address);
        if (old_value != new_value) {
            self.markAccountModified(address);
        }

        // Track storage modifications
        const storage_map = self.ensureStorageModifications(address) catch return;
        const result = storage_map.getOrPut(slot) catch return;
        if (!result.found_existing) {
            result.value_ptr.* = .{
                .original_value = old_value,
                .current_value = new_value,
                .was_read = false,
                .was_modified = true,
            };
        } else {
            result.value_ptr.current_value = new_value;
            result.value_ptr.was_modified = true;
        }

        // Ensure prestate has the original value
        const account = self.ensurePrestateAccount(address) catch return;
        if (!account.storage.contains(slot)) {
            account.storage.put(slot, old_value) catch {};
        }
    }

    // ===== Balance operations =====
    pub fn onBalanceRead(self: *Self, address: Address, balance: u256) void {
        if (!self.enabled) return;
        self.markAccountAccessed(address);
        const account = self.ensurePrestateAccount(address) catch return;
        // Always update balance when read (it's the current value)
        account.balance = balance;
        if (!account.exists) {
            account.nonce = 0; // Default nonce for new account
            account.exists = true;
        }
        account.is_empty = account.isEmpty();
    }

    pub fn onBalanceChange(self: *Self, address: Address, old_balance: u256, new_balance: u256) void {
        if (!self.enabled) return;
        self.markAccountAccessed(address);
        if (old_balance != new_balance) {
            self.markAccountModified(address);
        }

        // Track original value in prestate
        const account = self.ensurePrestateAccount(address) catch return;
        // Always update balance with the original value
        account.balance = old_balance;
        if (!account.exists) {
            account.nonce = 0; // Default nonce for new account
            account.exists = true;
        }
        account.is_empty = account.isEmpty();

        // In diff mode, also track the new value in poststate
        if (self.diff_mode and old_balance != new_balance) {
            const post_account = self.ensurePoststateAccount(address) catch return;
            post_account.balance = new_balance;
            if (!post_account.exists) {
                post_account.nonce = 0; // Default nonce for new account
            }
            post_account.exists = true;
            post_account.is_empty = post_account.isEmpty();
        }
    }

    // ===== Nonce operations =====
    pub fn onNonceRead(self: *Self, address: Address, nonce: u64) void {
        if (!self.enabled) return;
        self.markAccountAccessed(address);
        const account = self.ensurePrestateAccount(address) catch return;
        // Always update nonce when read (it's the current value)
        account.nonce = nonce;
        if (!account.exists) {
            account.balance = 0; // Default balance for new account
            account.exists = true;
        }
        account.is_empty = account.isEmpty();

        // In diff mode, if account is modified, ensure poststate has the value too
        if (self.diff_mode and self.modified_accounts.contains(address)) {
            const post_account = self.ensurePoststateAccount(address) catch return;
            if (!post_account.exists) {
                post_account.nonce = nonce;
                post_account.balance = 0; // Default balance
                post_account.exists = true;
                post_account.is_empty = post_account.isEmpty();
            }
        }
    }

    pub fn onNonceChange(self: *Self, address: Address, old_nonce: u64, new_nonce: u64) void {
        if (!self.enabled) return;
        self.markAccountAccessed(address);
        if (old_nonce != new_nonce) {
            self.markAccountModified(address);
        }

        // Track original value in prestate
        const account = self.ensurePrestateAccount(address) catch return;
        // Always update nonce with the original value
        account.nonce = old_nonce;
        if (!account.exists) {
            account.balance = 0; // Default balance for new account
            account.exists = true;
        }
        account.is_empty = account.isEmpty();

        // In diff mode, also track the new value in poststate
        if (self.diff_mode and old_nonce != new_nonce) {
            const post_account = self.ensurePoststateAccount(address) catch return;
            post_account.nonce = new_nonce;
            post_account.exists = true;
            post_account.is_empty = post_account.isEmpty();
        }
    }

    // ===== Code operations =====
    pub fn onCodeRead(self: *Self, address: Address, code: []const u8) void {
        if (!self.enabled or self.disable_code) return;
        self.markAccountAccessed(address);
        const account = self.ensurePrestateAccount(address) catch return;
        if (!account.exists or account.code.len == 0) {
            account.code = self.allocator.dupe(u8, code) catch &[_]u8{};
            account.code_hash = hashCode(code);
            account.exists = true;
            account.is_empty = account.isEmpty();
        }
    }

    pub fn onCodeChange(self: *Self, address: Address, old_code: []const u8, new_code: []const u8) void {
        if (!self.enabled or self.disable_code) return;
        self.markAccountAccessed(address);

        const old_hash = hashCode(old_code);
        const new_hash = hashCode(new_code);
        if (!std.mem.eql(u8, &old_hash, &new_hash)) {
            self.markAccountModified(address);
        }

        const account = self.ensurePrestateAccount(address) catch return;
        if (!account.exists or account.code.len == 0) {
            account.code = self.allocator.dupe(u8, old_code) catch &[_]u8{};
            account.code_hash = old_hash;
            account.exists = true;
            account.is_empty = account.isEmpty();
        }
    }

    // ===== Account lifecycle =====
    pub fn onAccountCreated(self: *Self, address: Address, initial_balance: u256, initial_nonce: u64, code: []const u8) void {
        if (!self.enabled) return;

        self.created_accounts.put(address, {}) catch {};
        self.markAccountAccessed(address);
        self.markAccountModified(address);

        // In diff mode, created accounts only go in poststate
        if (self.diff_mode) {
            const post_account = self.ensurePoststateAccount(address) catch return;
            post_account.balance = initial_balance;
            post_account.nonce = initial_nonce;
            if (!self.disable_code and code.len > 0) {
                post_account.code = self.allocator.dupe(u8, code) catch &[_]u8{};
                post_account.code_hash = hashCode(code);
            }
            post_account.exists = true;
            post_account.is_empty = post_account.isEmpty();
        } else {
            // In non-diff mode, track in prestate for now (will be cleaned up later)
            const account = self.ensurePrestateAccount(address) catch return;
            account.balance = initial_balance;
            account.nonce = initial_nonce;
            if (!self.disable_code and code.len > 0) {
                account.code = self.allocator.dupe(u8, code) catch &[_]u8{};
                account.code_hash = hashCode(code);
            }
            account.exists = true;
            account.is_empty = account.isEmpty();
        }
    }

    pub fn onAccountDestroyed(self: *Self, address: Address, beneficiary: Address, balance_transferred: u256, had_code: bool, storage_cleared: bool) void {
        _ = beneficiary;
        _ = balance_transferred;
        _ = had_code;
        _ = storage_cleared;
        if (!self.enabled) return;

        self.deleted_accounts.put(address, {}) catch {};
        self.markAccountAccessed(address);
        self.markAccountModified(address);

        // Ensure account exists in prestate
        _ = self.ensurePrestateAccount(address) catch {};
    }

    // ===== Helpers =====
    fn markAccountAccessed(self: *Self, address: Address) void {
        self.accessed_accounts.put(address, {}) catch {};
    }

    fn markAccountModified(self: *Self, address: Address) void {
        self.modified_accounts.put(address, {}) catch {};
    }

    fn ensurePrestateAccount(self: *Self, address: Address) !*AccountState {
        const result = try self.prestate.getOrPut(address);
        if (!result.found_existing) {
            result.value_ptr.* = AccountState.init(self.allocator);
        }
        return result.value_ptr;
    }

    fn ensurePoststateAccount(self: *Self, address: Address) !*AccountState {
        const result = try self.poststate.getOrPut(address);
        if (!result.found_existing) {
            // Initialize from prestate if exists, otherwise create new
            if (self.prestate.get(address)) |pre_account| {
                result.value_ptr.* = try pre_account.clone(self.allocator);
            } else {
                result.value_ptr.* = AccountState.init(self.allocator);
            }
        }
        return result.value_ptr;
    }

    fn ensureStorageModifications(self: *Self, address: Address) !*std.AutoHashMap(u256, StorageModification) {
        const result = try self.storage_modifications.getOrPut(address);
        if (!result.found_existing) {
            result.value_ptr.* = std.AutoHashMap(u256, StorageModification).init(self.allocator);
        }
        return result.value_ptr;
    }

    fn buildFinalStates(self: *Self) !void {
        // Build poststate based on current database state
        // This would typically query the actual database for final values
        // For now, we'll simulate by applying modifications

        if (self.diff_mode) {
            // In diff mode, process differently
            try self.buildDiffModeStates();
        } else {
            // In non-diff mode, keep only prestate
            try self.buildNonDiffModeStates();
        }
    }

    fn buildDiffModeStates(self: *Self) !void {
        // Apply storage modifications to poststate accounts
        var storage_iter = self.storage_modifications.iterator();
        while (storage_iter.next()) |entry| {
            const address = entry.key_ptr.*;
            const storage_mods = entry.value_ptr.*;

            // Get or create poststate account
            const post_account = self.ensurePoststateAccount(address) catch continue;

            // Apply storage modifications
            var mod_iter = storage_mods.iterator();
            while (mod_iter.next()) |mod_entry| {
                const slot = mod_entry.key_ptr.*;
                const mod = mod_entry.value_ptr.*;
                if (mod.was_modified) {
                    if (mod.current_value == 0) {
                        _ = post_account.storage.remove(slot);
                    } else {
                        post_account.storage.put(slot, mod.current_value) catch {};
                    }
                }
            }
        }

        // Clean up: Remove created accounts from prestate
        var created_iter = self.created_accounts.iterator();
        while (created_iter.next()) |entry| {
            const address = entry.key_ptr.*;
            if (self.prestate.getEntry(address)) |prestate_entry| {
                prestate_entry.value_ptr.deinit(self.allocator);
                _ = self.prestate.remove(address);
            }
        }

        // Clean up: Remove deleted accounts from poststate
        var deleted_iter = self.deleted_accounts.iterator();
        while (deleted_iter.next()) |entry| {
            const address = entry.key_ptr.*;
            if (self.poststate.getEntry(address)) |poststate_entry| {
                poststate_entry.value_ptr.deinit(self.allocator);
                _ = self.poststate.remove(address);
            }
        }

        // Clean up: Remove read-only accounts from both pre and post
        var accessed_iter = self.accessed_accounts.iterator();
        while (accessed_iter.next()) |entry| {
            const address = entry.key_ptr.*;
            // If not modified, created, or deleted, it's read-only
            if (!self.modified_accounts.contains(address) and
                !self.created_accounts.contains(address) and
                !self.deleted_accounts.contains(address))
            {
                // Remove from both pre and post
                if (self.prestate.getEntry(address)) |prestate_entry| {
                    prestate_entry.value_ptr.deinit(self.allocator);
                    _ = self.prestate.remove(address);
                }
                if (self.poststate.getEntry(address)) |poststate_entry| {
                    poststate_entry.value_ptr.deinit(self.allocator);
                    _ = self.poststate.remove(address);
                }
            }
        }

        // Clean up empty accounts if include_empty is false
        if (!self.include_empty) {
            try self.removeEmptyAccounts();
        }
    }

    fn buildNonDiffModeStates(self: *Self) !void {
        // In non-diff mode, only prestate is populated
        // All accessed accounts should be in prestate with their original values

        // Clean up empty accounts if include_empty is false
        if (!self.include_empty) {
            var to_remove = std.ArrayList(Address){};
            defer to_remove.deinit(self.allocator);

            var iter = self.prestate.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.is_empty and !self.include_empty) {
                    try to_remove.append(self.allocator, entry.key_ptr.*);
                }
            }

            for (to_remove.items) |address| {
                if (self.prestate.getEntry(address)) |prestate_entry| {
                    prestate_entry.value_ptr.deinit(self.allocator);
                    _ = self.prestate.remove(address);
                }
            }
        }
    }

    fn removeEmptyAccounts(self: *Self) !void {
        var to_remove = std.ArrayList(Address){};
        defer to_remove.deinit(self.allocator);

        // Remove empty accounts from prestate
        var pre_iter = self.prestate.iterator();
        while (pre_iter.next()) |entry| {
            const address = entry.key_ptr.*;
            if (entry.value_ptr.is_empty) {
                // In diff mode, only remove if account is still empty in poststate or not in poststate
                if (self.diff_mode) {
                    if (self.poststate.get(address)) |post_account| {
                        // Only remove from prestate if also empty in poststate
                        if (post_account.is_empty) {
                            try to_remove.append(self.allocator, address);
                        }
                    } else {
                        // Not in poststate (read-only), safe to remove
                        try to_remove.append(self.allocator, address);
                    }
                } else {
                    // Non-diff mode: remove all empty accounts
                    try to_remove.append(self.allocator, address);
                }
            }
        }

        for (to_remove.items) |address| {
            if (self.prestate.getEntry(address)) |prestate_entry| {
                prestate_entry.value_ptr.deinit(self.allocator);
                _ = self.prestate.remove(address);
            }
        }

        // Clear for reuse
        to_remove.clearRetainingCapacity();

        // Remove empty accounts from poststate
        var post_iter = self.poststate.iterator();
        while (post_iter.next()) |entry| {
            if (entry.value_ptr.is_empty) {
                try to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }

        for (to_remove.items) |address| {
            if (self.poststate.getEntry(address)) |poststate_entry| {
                poststate_entry.value_ptr.deinit(self.allocator);
                _ = self.poststate.remove(address);
            }
        }
    }

    fn hashCode(code: []const u8) [32]u8 {
        if (code.len == 0) return [_]u8{0} ** 32;
        const crypto = @import("crypto");
        return crypto.Hash.keccak256(code);
    }

    // Accessors
    pub fn getPrestate(self: *const Self) *const std.AutoHashMap(Address, AccountState) {
        return &self.prestate;
    }
    pub fn getPoststate(self: *const Self) *const std.AutoHashMap(Address, AccountState) {
        return &self.poststate;
    }
    pub fn isDiffMode(self: *const Self) bool {
        return self.diff_mode;
    }
    pub fn isStorageDisabled(self: *const Self) bool {
        return self.disable_storage;
    }
    pub fn isCodeDisabled(self: *const Self) bool {
        return self.disable_code;
    }
};

// ===== JSON formatting =====
pub fn writePrestateJson(writer: anytype, tracer: *const PrestateTracer) !void {
    if (tracer.isDiffMode()) {
        try writer.writeAll("{\"pre\":{");
        try writeStateMapJson(writer, tracer.getPrestate(), tracer.isStorageDisabled(), tracer.isCodeDisabled(), false);
        try writer.writeAll("},\"post\":{");
        try writeStateMapJson(writer, tracer.getPoststate(), tracer.isStorageDisabled(), tracer.isCodeDisabled(), true);
        try writer.writeAll("}}");
    } else {
        try writer.writeByte('{');
        try writeStateMapJson(writer, tracer.getPrestate(), tracer.isStorageDisabled(), tracer.isCodeDisabled(), false);
        try writer.writeByte('}');
    }
}

pub fn writeStateMapJson(
    writer: anytype,
    state_map: *const std.AutoHashMap(Address, PrestateTracer.AccountState),
    disable_storage: bool,
    disable_code: bool,
    is_post: bool,
) !void {
    var first = true;
    var iter = state_map.iterator();
    while (iter.next()) |entry| {
        const account = entry.value_ptr.*;

        // Skip non-existent accounts
        if (!account.exists and is_post) continue;

        if (!first) try writer.writeByte(',');
        first = false;

        const addr = entry.key_ptr.*;

        try writer.writeByte('"');
        try writer.print("{x:0>40}", .{addr});
        try writer.writeAll("\":{");

        var field_count: u32 = 0;

        // Always include balance
        try writer.print("\"balance\":\"0x{x}\"", .{account.balance});
        field_count += 1;

        // Always include nonce
        try writer.print(",\"nonce\":{}", .{account.nonce});
        field_count += 1;

        // Include code if not disabled and present
        if (!disable_code and account.code.len > 0) {
            try writer.writeAll(",\"code\":\"0x");
            for (account.code) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
            try writer.writeByte('"');
            field_count += 1;
        }

        // Include storage if not disabled and has entries
        if (!disable_storage and account.storage.count() > 0) {
            try writer.writeAll(",\"storage\":{");
            var storage_first = true;
            var sit = account.storage.iterator();
            while (sit.next()) |se| {
                const slot = se.key_ptr.*;
                const value = se.value_ptr.*;

                // Skip zero values in poststate
                if (is_post and value == 0) continue;

                if (!storage_first) try writer.writeByte(',');
                storage_first = false;
                try writer.print("\"0x{x}\":\"0x{x}\"", .{ slot, value });
            }
            try writer.writeByte('}');
            field_count += 1;
        }

        try writer.writeByte('}');
    }
}

// ===== Tests =====
test "PrestateTracer diff mode correctly handles modifications" {
    const allocator = std.testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    tracer.configure(.{ .diff_mode = true }); // diff_mode = true
    tracer.onTransactionStart();

    const addr1 = Address{ .bytes = [_]u8{1} ** 20 };
    const addr2 = Address{ .bytes = [_]u8{2} ** 20 };

    // Account 1: read and modified
    tracer.onBalanceRead(addr1, 1000);
    tracer.onNonceRead(addr1, 5);
    tracer.onStorageRead(addr1, 0x42, 100, false);
    tracer.onBalanceChange(addr1, 1000, 900);
    tracer.onStorageWrite(addr1, 0x42, 100, 200, true);

    // Account 2: modified from non-existent
    tracer.onBalanceChange(addr2, 0, 100);

    tracer.onTransactionEnd();

    // In diff mode, modified accounts appear in both pre and post
    try std.testing.expect(tracer.prestate.contains(addr1));
    try std.testing.expect(tracer.poststate.contains(addr1));

    // Account 2 was modified, should be in both
    try std.testing.expect(tracer.prestate.contains(addr2));
    try std.testing.expect(tracer.poststate.contains(addr2));

    const account1_pre = tracer.prestate.get(addr1).?;
    try std.testing.expectEqual(@as(u256, 1000), account1_pre.balance);
    try std.testing.expectEqual(@as(u64, 5), account1_pre.nonce);
    try std.testing.expectEqual(@as(u256, 100), account1_pre.storage.get(0x42).?);

    const account1_post = tracer.poststate.get(addr1).?;
    try std.testing.expectEqual(@as(u256, 900), account1_post.balance);
    try std.testing.expectEqual(@as(u256, 200), account1_post.storage.get(0x42).?);
}

test "PrestateTracer non-diff mode only shows prestate" {
    const allocator = std.testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    tracer.configure(.{}); // diff_mode = false
    tracer.onTransactionStart();

    const addr = Address{ .bytes = [_]u8{3} ** 20 };

    // Access and modify account
    tracer.onBalanceRead(addr, 500);
    tracer.onBalanceChange(addr, 500, 600);
    tracer.onStorageRead(addr, 0x01, 50, false);
    tracer.onStorageWrite(addr, 0x01, 50, 75, true);

    tracer.onTransactionEnd();

    // In non-diff mode, only prestate is populated
    try std.testing.expect(tracer.prestate.contains(addr));
    try std.testing.expectEqual(@as(usize, 0), tracer.poststate.count());

    // Prestate should have original values
    const account_pre = tracer.prestate.get(addr).?;
    try std.testing.expectEqual(@as(u256, 500), account_pre.balance);
    try std.testing.expectEqual(@as(u256, 50), account_pre.storage.get(0x01).?);
}

test "PrestateTracer handles account creation and deletion" {
    const allocator = std.testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    tracer.configure(.{ .diff_mode = true }); // diff_mode = true
    tracer.onTransactionStart();

    const created_addr = Address{ .bytes = [_]u8{4} ** 20 };
    const deleted_addr = Address{ .bytes = [_]u8{5} ** 20 };

    // Set up account to be deleted
    tracer.onBalanceRead(deleted_addr, 1000);
    tracer.onAccountDestroyed(deleted_addr, created_addr, 1000, false, false);

    // Create new account
    tracer.onAccountCreated(created_addr, 1000, 1, &[_]u8{});

    tracer.onTransactionEnd();

    // Created account should only be in poststate
    try std.testing.expect(!tracer.prestate.contains(created_addr));
    try std.testing.expect(tracer.poststate.contains(created_addr));

    // Deleted account should only be in prestate
    try std.testing.expect(tracer.prestate.contains(deleted_addr));
    try std.testing.expect(!tracer.poststate.contains(deleted_addr));
}

test "prestate tracer handles empty accounts correctly" {
    const allocator = std.testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    // Test with include_empty = false (default)
    tracer.configure(.{});
    tracer.onTransactionStart();

    const empty_addr = Address{ .bytes = [_]u8{6} ** 20 };
    const non_empty_addr = Address{ .bytes = [_]u8{7} ** 20 };

    // Access empty account
    tracer.onBalanceRead(empty_addr, 0);
    tracer.onNonceRead(empty_addr, 0);

    // Access non-empty account
    tracer.onBalanceRead(non_empty_addr, 1000);

    tracer.onTransactionEnd();

    // Empty account should be excluded
    try std.testing.expect(!tracer.prestate.contains(empty_addr));
    // Non-empty account should be included
    try std.testing.expect(tracer.prestate.contains(non_empty_addr));
}

test "prestate tracer with include_empty shows all accounts" {
    const allocator = std.testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    // Test with include_empty = true
    tracer.configure(.{ .include_empty = true });
    tracer.onTransactionStart();

    const empty_addr = Address{ .bytes = [_]u8{8} ** 20 };

    // Access empty account
    tracer.onBalanceRead(empty_addr, 0);
    tracer.onNonceRead(empty_addr, 0);

    tracer.onTransactionEnd();

    // Empty account should be included when include_empty = true
    try std.testing.expect(tracer.prestate.contains(empty_addr));
}

test "prestate tracer diff mode read-only accounts excluded" {
    const allocator = std.testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    tracer.configure(.{ .diff_mode = true }); // diff_mode = true
    tracer.onTransactionStart();

    const read_only_addr = Address{ .bytes = [_]u8{9} ** 20 };
    const modified_addr = Address{ .bytes = [_]u8{10} ** 20 };

    // Read-only access
    tracer.onBalanceRead(read_only_addr, 500);
    tracer.onStorageRead(read_only_addr, 0x01, 100, false);

    // Modified account
    tracer.onBalanceRead(modified_addr, 1000);
    tracer.onBalanceChange(modified_addr, 1000, 2000);

    tracer.onTransactionEnd();

    // In diff mode, read-only accounts should be excluded
    try std.testing.expect(!tracer.prestate.contains(read_only_addr));
    try std.testing.expect(!tracer.poststate.contains(read_only_addr));

    // Modified accounts should be in both
    try std.testing.expect(tracer.prestate.contains(modified_addr));
    try std.testing.expect(tracer.poststate.contains(modified_addr));
}

// Include comprehensive format tests
test {
    _ = @import("prestate_tracer_test.zig");
}
