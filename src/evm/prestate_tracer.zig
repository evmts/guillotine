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
        // Track which fields have been captured (for prestate)
        balance_captured: bool,
        nonce_captured: bool,
        code_captured: bool,

        pub fn init(allocator: std.mem.Allocator) AccountState {
            return .{
                .balance = 0,
                .nonce = 0,
                .code = &[_]u8{},
                .code_hash = [_]u8{0} ** 32,
                .storage = std.AutoHashMap(u256, u256).init(allocator),
                .exists = false,
                .is_empty = true,
                .balance_captured = false,
                .nonce_captured = false,
                .code_captured = false,
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
            new_state.balance_captured = self.balance_captured;
            new_state.nonce_captured = self.nonce_captured;
            new_state.code_captured = self.code_captured;

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

    /// Reset tracer state efficiently while preserving configuration.
    /// Clears tracked accounts, states, and modifications, and resets counters.
    pub fn reset(self: *Self) void {
        // Clear interaction sets
        self.created_accounts.clearRetainingCapacity();
        self.deleted_accounts.clearRetainingCapacity();
        self.modified_accounts.clearRetainingCapacity();
        self.accessed_accounts.clearRetainingCapacity();

        // Free account state allocations and clear maps
        var it1 = self.prestate.iterator();
        while (it1.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.prestate.clearRetainingCapacity();

        var it2 = self.poststate.iterator();
        while (it2.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.poststate.clearRetainingCapacity();

        // Deinit inner storage modification maps, then clear
        var storage_iter = self.storage_modifications.iterator();
        while (storage_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.storage_modifications.clearRetainingCapacity();

        // Counters
        self.total_instructions = 0;
    }

    // ===== Storage operations =====
    pub fn onStorageRead(self: *Self, address: Address, host: anytype, slot: u256, value: u256, is_warm: bool) void {
        _ = is_warm;
        if (!self.enabled) return;

        // Capture complete account state first
        self.onAccountTouched(address, host, .pre, null, null, null);

        if (self.disable_storage) return;

        // Handle storage-specific logic
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

        // Update prestate storage
        const account = self.ensurePrestateAccount(address) catch return;
        if (!account.storage.contains(slot)) {
            account.storage.put(slot, value) catch {};
        }
    }

    pub fn onStorageWrite(self: *Self, address: Address, host: anytype, slot: u256, old_value: u256, new_value: u256, is_warm: bool) void {
        _ = is_warm;
        if (!self.enabled) return;
        
        // Capture complete account state first
        self.onAccountTouched(address, host, .pre, null, null, null);

        if (self.disable_storage) return;
        
        if (old_value != new_value) {
            self.markAccountModified(address);
        }

        // Track storage modifications
        const storage_map = self.ensureStorageModifications(address) catch return;
        const result = storage_map.getOrPut(slot) catch return;
        if (!result.found_existing) {
            // First time seeing this slot - record original value
            result.value_ptr.* = .{
                .original_value = old_value,
                .current_value = new_value,
                .was_read = false,
                .was_modified = true,
            };
        } else {
            // Subsequent update - keep original, update current
            result.value_ptr.current_value = new_value; // Always update current
            result.value_ptr.was_modified = true;
            // DON'T update original_value - keep the first one
        }

        // Ensure prestate storage has ORIGINAL value (only if not set)
        const account = self.ensurePrestateAccount(address) catch return;
        if (!account.storage.contains(slot)) {
            account.storage.put(slot, old_value) catch {}; // Use old_value (original)
        }

        // If diff_mode, update poststate with LATEST value
        if (self.diff_mode) {
            self.onAccountTouched(address, host, .post, null, null, null);
            const post_account = self.ensurePoststateAccount(address) catch return;
            post_account.storage.put(slot, new_value) catch {}; // Always update with new value
        }
    }

    // ===== Balance operations =====
    pub fn onBalanceRead(self: *Self, address: Address, host: anytype, balance: u256) void {
        if (!self.enabled) return;

        // onAccountTouched handles balance, so minimal additional logic needed
        self.onAccountTouched(address, host, .pre, balance, null, null);
    }

    pub fn onBalanceChange(self: *Self, address: Address, host: anytype, old_balance: u256, new_balance: u256) void {
        if (!self.enabled) return;

        // Capture prestate with old balance
        self.onAccountTouched(address, host, .pre, old_balance, null, null);

        if (old_balance != new_balance) {
            self.markAccountModified(address);

            // In diff mode, capture poststate with new balance
            if (self.diff_mode) {
                self.onAccountTouched(address, host, .post, new_balance, null, null);
            }
        }
    }

    // ===== Nonce operations =====
    pub fn onNonceRead(self: *Self, address: Address, host: anytype, nonce: u64) void {
        if (!self.enabled) return;

        // onAccountTouched handles nonce, so minimal additional logic needed
        self.onAccountTouched(address, host, .pre, null, nonce, null);
    }

    pub fn onNonceChange(self: *Self, address: Address, host: anytype, old_nonce: u64, new_nonce: u64) void {
        if (!self.enabled) return;

        // Capture prestate with old nonce
        self.onAccountTouched(address, host, .pre, null, old_nonce, null);

        if (old_nonce != new_nonce) {
            self.markAccountModified(address);

            // In diff mode, capture poststate with new nonce
            if (self.diff_mode) {
                self.onAccountTouched(address, host, .post, null, new_nonce, null);
            }
        }
    }

    // ===== Code operations =====
    pub fn onCodeRead(self: *Self, address: Address, host: anytype, code: []const u8) void {
        if (!self.enabled or self.disable_code) return;

        // onAccountTouched handles code, so minimal additional logic needed
        self.onAccountTouched(address, host, .pre, null, null, code);
    }

    pub fn onCodeChange(self: *Self, address: Address, host: anytype, old_code: []const u8, new_code: []const u8) void {
        if (!self.enabled or self.disable_code) return;

        // Capture prestate with old code
        self.onAccountTouched(address, host, .pre, null, null, old_code);

        const old_hash = hashCode(old_code);
        const new_hash = hashCode(new_code);
        if (!std.mem.eql(u8, &old_hash, &new_hash)) {
            self.markAccountModified(address);

            // In diff mode, capture poststate with new code
            if (self.diff_mode) {
                self.onAccountTouched(address, host, .post, null, null, new_code);
            }
        }
    }

    // ===== Account lifecycle =====
    pub fn onAccountCreated(self: *Self, address: Address, host: anytype, initial_balance: u256, initial_nonce: u64, code: []const u8) void {
        if (!self.enabled) return;

        self.created_accounts.put(address, {}) catch {};
        self.markAccountModified(address);

        // Created accounts only exist in poststate, never in prestate
        if (self.diff_mode) {
            self.onAccountTouched(address, host, .post, initial_balance, initial_nonce, code);
        }
        // In non-diff mode, we don't track created accounts since we only capture prestate
    }

    pub fn onAccountDestroyed(self: *Self, address: Address, host: anytype, beneficiary: Address, balance_transferred: u256, had_code: bool, storage_cleared: bool) void {
        _ = beneficiary;
        _ = balance_transferred;
        _ = had_code;
        _ = storage_cleared;
        if (!self.enabled) return;

        self.deleted_accounts.put(address, {}) catch {};
        self.markAccountModified(address);

        // Destroyed accounts existed in prestate
        self.onAccountTouched(address, host, .pre, null, null, null);
        
        // In diff mode, mark account as destroyed in poststate (empty account)
        if (self.diff_mode) {
            // Use zeros to indicate destroyed state
            self.onAccountTouched(address, host, .post, 0, 0, &[_]u8{});
        }
    }

    // ===== Core Hook: onAccountTouched =====
    pub fn onAccountTouched(
        self: *Self,
        address: Address,
        host: anytype,
        phase: enum { pre, post },
        known_balance: ?u256,
        known_nonce: ?u64,
        known_code: ?[]const u8
    ) void {
        if (!self.enabled) return;
        
        // Mark as accessed
        self.markAccountAccessed(address);
        
        if (phase == .pre) {
            // PRESTATE: Capture the FIRST observation of each field
            const result = self.prestate.getOrPut(address) catch return;
            if (!result.found_existing) {
                result.value_ptr.* = AccountState.init(self.allocator);
            }
            
            // Capture balance if this is the first time we see it
            if (!result.value_ptr.balance_captured) {
                if (known_balance) |balance| {
                    result.value_ptr.balance = balance;
                    result.value_ptr.balance_captured = true;
                } else {
                    result.value_ptr.balance = host.get_balance(address);
                    result.value_ptr.balance_captured = true;
                }
            }
            
            // Capture nonce if this is the first time we see it  
            if (!result.value_ptr.nonce_captured) {
                if (known_nonce) |nonce| {
                    result.value_ptr.nonce = nonce;
                    result.value_ptr.nonce_captured = true;
                } else {
                    result.value_ptr.nonce = host.get_nonce(address);
                    result.value_ptr.nonce_captured = true;
                }
            }
            
            // Capture code if this is the first time we see it
            if (!result.value_ptr.code_captured and !self.disable_code) {
                if (known_code) |code| {
                    if (code.len > 0) {
                        result.value_ptr.code = self.allocator.dupe(u8, code) catch &[_]u8{};
                        result.value_ptr.code_hash = hashCode(code);
                    }
                    result.value_ptr.code_captured = true;
                } else {
                    const code = host.get_code(address);
                    if (code.len > 0) {
                        result.value_ptr.code = self.allocator.dupe(u8, code) catch &[_]u8{};
                        result.value_ptr.code_hash = hashCode(code);
                    }
                    result.value_ptr.code_captured = true;
                }
            }
            
            // Update flags after capturing
            result.value_ptr.exists = result.value_ptr.balance > 0 or result.value_ptr.nonce > 0 or result.value_ptr.code.len > 0;
            result.value_ptr.is_empty = result.value_ptr.isEmpty();
        } else {
            // POSTSTATE: Always update with latest values (if in diff_mode)
            if (self.diff_mode) {
                const result = self.poststate.getOrPut(address) catch return;
                if (!result.found_existing) {
                    result.value_ptr.* = AccountState.init(self.allocator);
                }
                
                // Always update with the latest known values
                if (known_balance) |balance| {
                    result.value_ptr.balance = balance;
                } else {
                    result.value_ptr.balance = host.get_balance(address);
                }
                
                if (known_nonce) |nonce| {
                    result.value_ptr.nonce = nonce;
                } else {
                    result.value_ptr.nonce = host.get_nonce(address);
                }
                
                // Update code if provided or fetch if needed
                if (!self.disable_code) {
                    if (known_code) |code| {
                        if (result.value_ptr.code.len > 0) {
                            self.allocator.free(result.value_ptr.code);
                        }
                        if (code.len > 0) {
                            result.value_ptr.code = self.allocator.dupe(u8, code) catch &[_]u8{};
                            result.value_ptr.code_hash = hashCode(code);
                        } else {
                            result.value_ptr.code = &[_]u8{};
                            result.value_ptr.code_hash = [_]u8{0} ** 32;
                        }
                    } else {
                        const code = host.get_code(address);
                        if (result.value_ptr.code.len > 0) {
                            self.allocator.free(result.value_ptr.code);
                        }
                        if (code.len > 0) {
                            result.value_ptr.code = self.allocator.dupe(u8, code) catch &[_]u8{};
                            result.value_ptr.code_hash = hashCode(code);
                        } else {
                            result.value_ptr.code = &[_]u8{};
                            result.value_ptr.code_hash = [_]u8{0} ** 32;
                        }
                    }
                }
                
                result.value_ptr.exists = result.value_ptr.balance > 0 or result.value_ptr.nonce > 0 or result.value_ptr.code.len > 0;
                result.value_ptr.is_empty = result.value_ptr.isEmpty();
            }
        }
    }

    // ===== Helper Methods for State Management =====
    fn ensureAccountInState(self: *Self, state_map: anytype, address: Address) !*AccountState {
        const result = try state_map.getOrPut(address);
        if (!result.found_existing) {
            result.value_ptr.* = AccountState.init(self.allocator);
        }
        return result.value_ptr;
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
                        // Remove deleted slots from prestate and poststate
                        _ = post_account.storage.remove(slot);
                        if (self.prestate.getEntry(address)) |pre_entry| {
                            _ = pre_entry.value_ptr.storage.remove(slot);
                        }
                    } else {
                        // If pre value is zero, remove it from prestate
                        if (mod.original_value == 0) {
                            if (self.prestate.getEntry(address)) |pre_entry| {
                                _ = pre_entry.value_ptr.storage.remove(slot);
                            }
                        }
                        
                        // If post value is non-zero, add it to poststate
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
            try self.removeEmptyAccounts();
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
