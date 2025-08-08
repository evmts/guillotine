const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const AutoHashMap = std.AutoHashMap;
const Address = @import("primitives").Address.Address;
const primitives = @import("../primitives/primitives.zig");
const Host = @import("root.zig").Host;

const Frame = @import("frame.zig").Frame;
const Memory = @import("memory/memory.zig").Memory;
const ExecutionError = @import("execution/execution_error.zig").ExecutionError;
const CodeAnalysis = @import("analysis.zig").CodeAnalysis;

/// Maximum call depth per EVM specification
pub const MAX_CALL_DEPTH = 1024;

/// Call types for different EVM operations
pub const CallType = enum {
    CALL,
    DELEGATECALL,
    STATICCALL,
    CALLCODE,
    CREATE,
    CREATE2,
};

/// Parameters for initializing a call frame
pub const CallParams = struct {
    target: Address,
    gas_limit: u64,
    input: []const u8,
    value: u256 = 0,
    salt: ?u256 = null, // For CREATE2
    init_code: ?[]const u8 = null, // For CREATE/CREATE2
};

/// Access list for EIP-2929 warm/cold address and storage tracking
pub const AccessList = struct {
    /// Gas costs for EIP-2929
    pub const WARM_ACCOUNT_ACCESS_COST = 100;
    pub const COLD_ACCOUNT_ACCESS_COST = 2600;
    pub const WARM_STORAGE_ACCESS_COST = 100;
    pub const COLD_STORAGE_ACCESS_COST = 2100;
    /// Warm addresses accessed this transaction
    warm_addresses: AutoHashMap(Address, void),
    /// Warm storage slots accessed this transaction
    warm_storage: AutoHashMap(Address, AutoHashMap(u256, void)),
    
    allocator: Allocator,
    
    pub fn init(allocator: Allocator) !AccessList {
        return AccessList{
            .warm_addresses = AutoHashMap(Address, void).init(allocator),
            .warm_storage = AutoHashMap(Address, AutoHashMap(u256, void)).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *AccessList) void {
        self.warm_addresses.deinit();
        
        var storage_iter = self.warm_storage.iterator();
        while (storage_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.warm_storage.deinit();
    }
    
    /// Mark address as accessed, return gas cost
    pub fn access_address(self: *AccessList, addr: Address) !u64 {
        if (self.warm_addresses.contains(addr)) {
            return WARM_ACCOUNT_ACCESS_COST;
        } else {
            try self.warm_addresses.put(addr, {});
            return COLD_ACCOUNT_ACCESS_COST;
        }
    }
    
    /// Mark storage slot as accessed, return gas cost
    pub fn access_storage(self: *AccessList, addr: Address, key: u256) u64 {
        const storage = self.warm_storage.getOrPut(addr) catch {
            return COLD_STORAGE_ACCESS_COST;
        };
        
        if (!storage.found_existing) {
            storage.value_ptr.* = AutoHashMap(u256, void).init(self.allocator);
        }
        
        if (storage.value_ptr.contains(key)) {
            return WARM_STORAGE_ACCESS_COST;
        } else {
            storage.value_ptr.put(key, {}) catch {};
            return COLD_STORAGE_ACCESS_COST;
        }
    }
    
    /// Mark storage slot as accessed, return whether it was cold (true) or warm (false)
    pub fn access_storage_key(self: *AccessList, addr: Address, key: u256) !bool {
        const storage = try self.warm_storage.getOrPut(addr);
        
        if (!storage.found_existing) {
            storage.value_ptr.* = AutoHashMap(u256, void).init(self.allocator);
        }
        
        const was_cold = !storage.value_ptr.contains(key);
        if (was_cold) {
            try storage.value_ptr.put(key, {});
        }
        
        return was_cold;
    }
};

/// Journal entry types for revertible operations
pub const JournalEntry = union(enum) {
    selfdestruct: struct {
        snapshot_id: u32,
        contract: Address,
        recipient: Address,
    },
    storage_change: struct {
        snapshot_id: u32,
        address: Address,
        key: u256,
        original_value: u256,
    },
    balance_change: struct {
        snapshot_id: u32,
        address: Address,
        original_balance: u256,
    },
    nonce_change: struct {
        snapshot_id: u32,
        address: Address,
        original_nonce: u64,
    },
    log_entry: struct {
        snapshot_id: u32,
        // Log entries are just marked for removal on revert
    },
};

/// Journaling system for revertible operations
pub const CallJournal = struct {
    /// Journal entries for revertible operations
    entries: ArrayList(JournalEntry),
    /// Current snapshot ID counter
    next_snapshot_id: u32,
    
    pub fn init(allocator: Allocator) CallJournal {
        return CallJournal{
            .entries = ArrayList(JournalEntry).init(allocator),
            .next_snapshot_id = 0,
        };
    }
    
    pub fn deinit(self: *CallJournal) void {
        self.entries.deinit();
    }
    
    /// Create a snapshot point for revertible operations
    pub fn create_snapshot(self: *CallJournal) u32 {
        const id = self.next_snapshot_id;
        self.next_snapshot_id += 1;
        return id;
    }
    
    /// Revert all changes back to snapshot
    pub fn revert_to_snapshot(self: *CallJournal, snapshot_id: u32) void {
        // Remove all entries with snapshot_id >= snapshot_id
        // This effectively reverts all changes made since the snapshot
        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.entries.items[i];
            
            const entry_snapshot = switch (entry) {
                .selfdestruct => |sd| sd.snapshot_id,
                .storage_change => |sc| sc.snapshot_id,
                .balance_change => |bc| bc.snapshot_id,
                .nonce_change => |nc| nc.snapshot_id,
                .log_entry => |le| le.snapshot_id,
            };
            
            if (entry_snapshot >= snapshot_id) {
                _ = self.entries.swapRemove(i);
            }
        }
    }
    
    /// Record a self-destruct operation
    pub fn record_selfdestruct(self: *CallJournal, snapshot_id: u32, contract: Address, recipient: Address) !void {
        try self.entries.append(.{
            .selfdestruct = .{
                .snapshot_id = snapshot_id,
                .contract = contract,
                .recipient = recipient,
            },
        });
    }
    
    /// Record a storage change
    pub fn record_storage_change(self: *CallJournal, snapshot_id: u32, address: Address, key: u256, original_value: u256) !void {
        try self.entries.append(.{
            .storage_change = .{
                .snapshot_id = snapshot_id,
                .address = address,
                .key = key,
                .original_value = original_value,
            },
        });
    }
    
    /// Record a balance change
    pub fn record_balance_change(self: *CallJournal, snapshot_id: u32, address: Address, original_balance: u256) !void {
        try self.entries.append(.{
            .balance_change = .{
                .snapshot_id = snapshot_id,
                .address = address,
                .original_balance = original_balance,
            },
        });
    }
    
    /// Record a nonce change
    pub fn record_nonce_change(self: *CallJournal, snapshot_id: u32, address: Address, original_nonce: u64) !void {
        try self.entries.append(.{
            .nonce_change = .{
                .snapshot_id = snapshot_id,
                .address = address,
                .original_nonce = original_nonce,
            },
        });
    }
    
    /// Record a log entry (for revert purposes)
    pub fn record_log_entry(self: *CallJournal, snapshot_id: u32) !void {
        try self.entries.append(.{
            .log_entry = .{
                .snapshot_id = snapshot_id,
            },
        });
    }
};

/// Pre-allocated call frame stack with memory pooling and journaling
pub const CallFrameStack = struct {
    /// Pre-allocated frames for maximum call depth
    frames: [MAX_CALL_DEPTH]Frame,
    
    /// Pre-allocated memory pool - each frame gets a Memory object
    memory_pool: [MAX_CALL_DEPTH]Memory,
    
    /// Shared access list for EIP-2929 warm/cold tracking
    /// Shared across ALL frames - never reverted
    access_list: AccessList,
    
    /// Journaling system for revertible operations
    journal: CallJournal,
    
    /// Host interface for external operations (shared across all frames)
    host: Host,
    
    /// Current execution depth (0 = root frame)
    current_depth: u32,
    
    /// Allocator for memory pool growth
    allocator: Allocator,
    
    /// Initialize the entire call stack upfront
    pub fn init(allocator: Allocator, host: Host) !CallFrameStack {
        var stack = CallFrameStack{
            .frames = undefined,
            .memory_pool = undefined,
            .access_list = try AccessList.init(allocator),
            .journal = CallJournal.init(allocator),
            .host = host,
            .current_depth = 0,
            .allocator = allocator,
        };
        
        // Initialize all memory objects in the pool
        for (&stack.memory_pool) |*memory| {
            memory.* = try Memory.init(allocator);
        }
        
        // Initialize frames to default state
        for (&stack.frames) |*frame| {
            frame.* = Frame{
                .stack = undefined, // Will be properly initialized when frame is used
                .gas_remaining = 0,
                .memory = undefined, // Will be set when frame is activated
                .analysis = undefined, // Will be set when frame is activated
                .access_list = &stack.access_list,
                .journal = &stack.journal,
                .host = &stack.host,
                .contract_address = Address.ZERO,
                .caller = Address.ZERO,
                .input = &.{},
                .output = &.{},
                .value = 0,
                .is_static = false,
                .depth = 0,
                .snapshot_id = 0,
                .next_frame = null,
            };
        }
        
        return stack;
    }
    
    pub fn deinit(self: *CallFrameStack) void {
        // Deinit all memory objects
        for (&self.memory_pool) |*memory| {
            memory.deinit();
        }
        
        self.access_list.deinit();
        self.journal.deinit();
    }
    
    /// Get current active frame
    pub fn current_frame(self: *CallFrameStack) *Frame {
        return &self.frames[self.current_depth];
    }
    
    /// Initialize a new frame for different call types
    pub fn init_call_frame(
        self: *CallFrameStack,
        call_type: CallType,
        caller_frame: *Frame,
        params: CallParams,
        analysis: *const CodeAnalysis,
    ) !*Frame {
        const depth = self.current_depth + 1;
        if (depth >= MAX_CALL_DEPTH) return ExecutionError.Error.CallDepthExceeded;
        
        const new_frame = &self.frames[depth];
        
        // Create snapshot for revertible operations
        const snapshot_id = self.journal.create_snapshot();
        
        // Set up memory based on call type
        new_frame.memory = switch (call_type) {
            .CALL, .STATICCALL, .CREATE, .CREATE2 => &self.memory_pool[depth],
            .DELEGATECALL, .CALLCODE => caller_frame.memory, // Share memory
        };
        
        // Clear memory for new frames (not for shared memory)
        switch (call_type) {
            .CALL, .STATICCALL, .CREATE, .CREATE2 => {
                new_frame.memory.clear();
            },
            else => {}, // Shared memory, don't clear
        }
        
        // Initialize stack
        new_frame.stack = try new_frame.stack.init(self.allocator);
        
        // Shared components (same for all call types)
        new_frame.access_list = &self.access_list;
        new_frame.journal = &self.journal;
        new_frame.host = &self.host;
        new_frame.snapshot_id = snapshot_id;
        new_frame.depth = depth;
        new_frame.analysis = analysis;
        new_frame.input = params.input;
        new_frame.output = &.{};
        new_frame.gas_remaining = params.gas_limit;
        
        // Call-specific setup
        switch (call_type) {
            .DELEGATECALL => {
                new_frame.caller = caller_frame.caller; // Preserve original caller
                new_frame.value = caller_frame.value; // Preserve original value
                new_frame.is_static = caller_frame.is_static; // Preserve static flag
                new_frame.contract_address = params.target;
            },
            .STATICCALL => {
                new_frame.is_static = true; // Force static
                new_frame.value = 0; // No value transfer
                new_frame.caller = caller_frame.contract_address;
                new_frame.contract_address = params.target;
            },
            .CALLCODE => {
                // CALLCODE executes target's code in caller's context
                new_frame.caller = caller_frame.caller;
                new_frame.value = params.value;
                new_frame.is_static = caller_frame.is_static;
                new_frame.contract_address = caller_frame.contract_address; // Keep caller's address
            },
            .CREATE, .CREATE2 => {
                // Calculate new contract address
                const new_address = if (call_type == .CREATE2) blk: {
                    const salt = params.salt orelse return ExecutionError.Error.InvalidParameters;
                    const init_code = params.init_code orelse return ExecutionError.Error.InvalidParameters;
                    break :blk try primitives.Address.calculate_create2_address(
                        self.allocator,
                        caller_frame.contract_address,
                        salt,
                        init_code,
                    );
                } else blk: {
                    // CREATE uses nonce-based address calculation
                    // This would require getting the nonce from the state
                    // For now, placeholder - actual implementation needs state access
                    break :blk try primitives.Address.calculate_create_address(
                        caller_frame.contract_address,
                        0, // TODO: Get actual nonce from state
                    );
                };
                
                new_frame.caller = caller_frame.contract_address;
                new_frame.value = params.value;
                new_frame.is_static = false; // CREATE operations are never static
                new_frame.contract_address = new_address;
            },
            .CALL => {
                new_frame.caller = caller_frame.contract_address;
                new_frame.value = params.value;
                new_frame.is_static = caller_frame.is_static;
                new_frame.contract_address = params.target;
            },
        }
        
        // Link frames for traversal
        new_frame.next_frame = if (depth + 1 < MAX_CALL_DEPTH) &self.frames[depth + 1] else null;
        
        self.current_depth = depth;
        return new_frame;
    }
    
    /// Handle revert back to calling frame
    pub fn revert_frame(self: *CallFrameStack, failed_frame: *Frame) void {
        // Revert all journaled operations back to frame's snapshot
        self.journal.revert_to_snapshot(failed_frame.snapshot_id);
        
        // Return to caller frame
        self.current_depth = failed_frame.depth - 1;
        
        // Note: Memory changes in DELEGATECALL/CALLCODE are NOT reverted
        // This is correct EVM behavior - memory sharing persists
    }
    
    /// Successfully complete a frame and return to caller
    pub fn complete_frame(self: *CallFrameStack, completed_frame: *Frame) void {
        // No need to revert journal entries - they become permanent
        
        // Return to caller frame
        self.current_depth = completed_frame.depth - 1;
    }
};

test "CallFrameStack initialization" {
    const allocator = std.testing.allocator;
    
    var stack = try CallFrameStack.init(allocator);
    defer stack.deinit();
    
    // Verify initialization
    try std.testing.expectEqual(@as(u32, 0), stack.current_depth);
    try std.testing.expectEqual(@as(u32, 0), stack.journal.next_snapshot_id);
    
    // Verify memory pool is initialized
    for (stack.memory_pool) |memory| {
        try std.testing.expectEqual(@as(usize, 0), memory.size);
        try std.testing.expect(memory.capacity >= Memory.INITIAL_SIZE);
    }
}

test "AccessList warm/cold tracking" {
    const allocator = std.testing.allocator;
    
    var access_list = try AccessList.init(allocator);
    defer access_list.deinit();
    
    const addr = Address.ZERO;
    
    // First access should be cold
    const cold_cost = access_list.access_address(addr);
    try std.testing.expectEqual(@as(u64, 2600), cold_cost);
    
    // Second access should be warm
    const warm_cost = access_list.access_address(addr);
    try std.testing.expectEqual(@as(u64, 100), warm_cost);
}

test "CallJournal snapshot and revert" {
    const allocator = std.testing.allocator;
    
    var journal = CallJournal.init(allocator);
    defer journal.deinit();
    
    // Create snapshots
    const snapshot1 = journal.create_snapshot();
    const snapshot2 = journal.create_snapshot();
    
    try std.testing.expectEqual(@as(u32, 0), snapshot1);
    try std.testing.expectEqual(@as(u32, 1), snapshot2);
    
    // Add some entries
    try journal.record_selfdestruct(snapshot1, Address.ZERO, Address.ZERO);
    try journal.record_selfdestruct(snapshot2, Address.ZERO, Address.ZERO);
    
    try std.testing.expectEqual(@as(usize, 2), journal.entries.items.len);
    
    // Revert to snapshot1 should remove snapshot2 entries
    journal.revert_to_snapshot(snapshot2);
    try std.testing.expectEqual(@as(usize, 1), journal.entries.items.len);
    
    // Revert to snapshot1 should remove all entries
    journal.revert_to_snapshot(snapshot1);
    try std.testing.expectEqual(@as(usize, 0), journal.entries.items.len);
}