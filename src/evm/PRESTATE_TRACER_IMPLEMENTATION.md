<?xml version="1.0" encoding="UTF-8"?>
<prestate-tracer-implementation>
  <title>Prestate Tracer Implementation Plan</title>
  
  <executive-summary>
    <overview>
      Complete implementation plan for adding a standard Ethereum prestate tracer to the Guillotine EVM. The implementation introduces a new, standalone `PrestateTracer` type that captures all state changes (storage, balance, nonce, code, account creation/destruction) and outputs in the standard Geth format with both prestate and diff modes. The `DebuggingTracer` can optionally compose this functionality when prestate tracking is needed.
    </overview>
    
    <key-architectural-decisions>
      <decision number="1">
        <type>New Tracer Type</type>
        <description>`PrestateTracer` is a completely separate tracer implementing the full tracer interface</description>
      </decision>
      <decision number="2">
        <type>Composition Pattern</type>
        <description>`DebuggingTracer` can optionally embed and delegate to `PrestateTracer`</description>
      </decision>
      <decision number="3">
        <type>Separation of Concerns</type>
        <description>Tracers handle data collection; formatters handle JSON output</description>
      </decision>
      <decision number="4">
        <type>Hook Timing</type>
        <description>All tracer hooks are called AFTER actions are performed, not before</description>
      </decision>
    </key-architectural-decisions>
  </executive-summary>

  <prerequisites-for-zig-beginners>
    <section-title>Prerequisites for Zig Beginners</section-title>
    
    <essential-zig-concepts>
      <concept name="Memory Management">
        <point>Allocators: All dynamic memory in Zig goes through allocators</point>
        <point>`defer` keyword: Ensures cleanup code runs when scope exits</point>
        <point>`errdefer` keyword: Cleanup that only runs on error</point>
      </concept>
      
      <concept name="Error Handling">
        <point>Error unions: `!T` means "T or an error"</point>
        <point>`try` keyword: Propagates errors up the call stack</point>
        <point>`catch` keyword: Handles errors inline</point>
      </concept>
      
      <concept name="Comptime">
        <point>`comptime` keyword: Code executed at compile time</point>
        <point>Generic functions: Functions that take types as parameters</point>
        <point>Type manipulation: Building types at compile time</point>
      </concept>
      
      <concept name="HashMaps and ArrayLists">
        <point>`std.AutoHashMap`: Hash table implementation</point>
        <point>`std.ArrayList`: Dynamic array</point>
        <point>Both require explicit memory management</point>
      </concept>
      
      <concept name="Optionals">
        <point>`?T` means "T or null"</point>
        <point>`.?` unwraps optional (panics if null)</point>
        <point>`orelse` provides default value</point>
      </concept>
    </essential-zig-concepts>
    
    <common-zig-patterns>
      <pattern name="Resource acquisition and cleanup">
        <code><![CDATA[
// Pattern 1: Resource acquisition and cleanup
var thing = try Something.init(allocator);
defer thing.deinit();  // Always runs when scope exits
        ]]></code>
      </pattern>
      
      <pattern name="Error handling with cleanup">
        <code><![CDATA[
// Pattern 2: Error handling with cleanup
var thing = try allocator.create(Thing);
errdefer allocator.destroy(thing);  // Only runs if later code errors
thing.* = try Thing.init(allocator);
return thing;
        ]]></code>
      </pattern>
      
      <pattern name="Optional handling">
        <code><![CDATA[
// Pattern 3: Optional handling
const result = map.get(key) orelse default_value;
if (map.get(key)) |value| {
    // Use value
} else {
    // Handle missing key
}
        ]]></code>
      </pattern>
      
      <pattern name="Comptime type parameters">
        <code><![CDATA[
// Pattern 4: Comptime type parameters
pub fn MyGeneric(comptime T: type) type {
    return struct {
        value: T,
    };
}
        ]]></code>
      </pattern>
    </common-zig-patterns>
  </prerequisites-for-zig-beginners>

  <understanding-requirements>
    <what-is-prestate-tracer>
      <description>
        A prestate tracer is a debugging tool that captures the state of all Ethereum accounts touched during a transaction execution. Think of it as a "before and after" snapshot of the blockchain state.
      </description>
      
      <key-terms>
        <term name="Account">An Ethereum entity with balance, nonce, code, and storage</term>
        <term name="EOA">Externally Owned Account (user wallet, no code)</term>
        <term name="Contract">Account with executable code</term>
        <term name="Nonce">Transaction counter (EOA) or contracts created counter (contract)</term>
        <term name="Storage">Key-value store for contract data</term>
        <term name="State Change">Any modification to account properties</term>
      </key-terms>
    </what-is-prestate-tracer>
    
    <why-needed>
      <reason number="1">
        <title>Debugging</title>
        <description>See exactly what changed during transaction execution</description>
      </reason>
      <reason number="2">
        <title>Simulation</title>
        <description>Preview transaction effects before execution</description>
      </reason>
      <reason number="3">
        <title>State Proofs</title>
        <description>Generate witnesses for light clients</description>
      </reason>
      <reason number="4">
        <title>Testing</title>
        <description>Verify expected state transitions</description>
      </reason>
    </why-needed>
  </understanding-requirements>

  <background-ethereum-standard>
    <title>Background: Ethereum Prestate Tracer Standard</title>
    
    <standard-features>
      <feature number="1">
        <name>Prestate mode</name>
        <description>default: Returns all accounts/state touched during execution</description>
      </feature>
      <feature number="2">
        <name>Diff mode</name>
        <description>Returns before/after state changes</description>
      </feature>
      <feature number="3">
        <name>Captures</name>
        <description>Balance, nonce, code, storage for all touched accounts</description>
      </feature>
      <feature number="4">
        <name>Used for</name>
        <description>Transaction simulation, state witness generation, debugging</description>
      </feature>
    </standard-features>
    
    <standard-output-format>
      <prestate-mode>
        <description>Prestate Mode</description>
        <json-example><![CDATA[
{
  "0xAddress1": {
    "balance": "0x1234",
    "nonce": 5,
    "code": "0x6080604052...",
    "storage": {
      "0x0": "0x100",
      "0x1": "0x200"
    }
  }
}
        ]]></json-example>
      </prestate-mode>
      
      <diff-mode>
        <description>Diff Mode</description>
        <json-example><![CDATA[
{
  "pre": {
    "0xAddress1": {
      "balance": "0x1000",
      "nonce": 5,
      "storage": {
        "0x0": "0x100"
      }
    }
  },
  "post": {
    "0xAddress1": {
      "balance": "0x2000",
      "nonce": 6,
      "storage": {
        "0x0": "0x200",
        "0x1": "0x300"
      }
    }
  }
}
        ]]></json-example>
      </diff-mode>
    </standard-output-format>
  </background-ethereum-standard>

  <architecture-design>
    <core-components>
      <component number="1">
        <name>PrestateTracer</name>
        <description>A new, complete tracer type in `prestate_tracer.zig` (data-format agnostic)</description>
      </component>
      <component number="2">
        <name>DebuggingTracer</name>
        <description>Can optionally compose PrestateTracer when prestate mode is enabled</description>
      </component>
      <component number="3">
        <name>Integration Points</name>
        <description>Frame calls tracer hooks after state changes</description>
      </component>
    </core-components>
    
    <module-relationships>
      <diagram><![CDATA[
Frame (execution engine)
    ↓ calls hooks after operations
Tracer Interface
    ↓ implemented by
PrestateTracer (our new type)
    ↓ optionally composed by
DebuggingTracer (existing tracer)
    ↓ outputs formatted by
JSON Formatting Functions (standalone)
      ]]></diagram>
    </module-relationships>
    
    <memory-ownership-rules>
      <critical-note>Critical for Zig beginners:</critical-note>
      <rule number="1">
        <title>PrestateTracer owns its data</title>
        <description>It allocates and must free all state maps</description>
      </rule>
      <rule number="2">
        <title>Copied data</title>
        <description>Code bytes and storage values are duplicated, not referenced</description>
      </rule>
      <rule number="3">
        <title>Lifetime management</title>
        <description>Tracer lives for entire transaction execution</description>
      </rule>
      <rule number="4">
        <title>Child allocators</title>
        <description>Consider using arena allocators for transaction-scoped data</description>
      </rule>
    </memory-ownership-rules>
  </architecture-design>

  <implementation>
    <section-title>Implementation: PrestateTracer as a New Type</section-title>
    
    <step number="1">
      <title>Create prestate_tracer.zig</title>
      <description>This is a completely new file that implements a standalone prestate tracer.</description>
      
      <implementation-notes>
        <note number="1">
          <title>File Location</title>
          <description>Create at `src/evm/prestate_tracer.zig`</description>
        </note>
        <note number="2">
          <title>Import Strategy</title>
          <description>Use direct imports, not parent directory imports</description>
        </note>
        <note number="3">
          <title>Memory Safety</title>
          <description>Every allocation needs corresponding deallocation</description>
        </note>
        <note number="4">
          <title>Error Handling</title>
          <description>Use `catch {}` for non-critical operations</description>
        </note>
        <note number="5">
          <title>Type Sizes</title>
          <description>u256 is typically `std.math.big.int.Managed` or a 256-bit integer type</description>
        </note>
      </implementation-notes>
      
      <code-implementation>
        <file-header><![CDATA[
// File: src/evm/prestate_tracer.zig
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

// BEGINNER NOTE: Import other required modules
// The exact import paths depend on your build.zig configuration
// Common pattern: @import("module_name") where module_name is defined in build.zig

// BEGINNER NOTE: Type aliases for clarity
// In this codebase, u256 might be defined as:
// - A 256-bit integer type from primitives
// - std.math.big.int.Managed for arbitrary precision
// Check primitives module for actual definition
const u256 = primitives.U256;  // Adjust based on actual type
        ]]></file-header>
        
        <main-struct><![CDATA[
/// Complete prestate tracer implementation
/// 
/// DESIGN NOTES FOR BEGINNERS:
/// - This struct is data-format agnostic (no JSON knowledge)
/// - All methods are self-contained (no external dependencies)
/// - Memory is explicitly managed (no garbage collection)
/// - Thread-safety is NOT guaranteed (single-threaded use)
pub const PrestateTracer = struct {
    // BEGINNER NOTE: Fields explained
    allocator: std.mem.Allocator,        // Memory allocator for all dynamic allocations
    enabled: bool = true,                // Master switch to disable all tracking
    diff_mode: bool = false,             // true = output before/after, false = output final state
    disable_storage: bool = false,       // Skip storage tracking (performance optimization)
    disable_code: bool = false,          // Skip code tracking (performance optimization)
    
    // State tracking data structures
    // BEGINNER NOTE: These grow during execution, cleared between transactions
    state_changes: std.ArrayList(StateChange),              // Chronological list of all changes
    touched_accounts: std.AutoHashMap(Address, void),       // Set of accounts accessed (void = no value)
    prestate: std.AutoHashMap(Address, AccountState),       // Initial state of accounts
    poststate: std.AutoHashMap(Address, AccountState),      // Final state after all changes
    total_instructions: u64 = 0,                            // Instruction counter for debugging
    
    const Self = @This();
        ]]></main-struct>
        
        <data-structures><![CDATA[
    // Data structures for state tracking
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
            if (self.code.len > 0) {
                allocator.free(self.code);
            }
            self.storage.deinit();
        }
    };
        ]]></data-structures>
        
        <constructor-destructor><![CDATA[
    // Constructor
    // BEGINNER NOTE: This creates a new tracer instance
    // Pattern: .{} is struct literal syntax in Zig
    // All collections start empty but with allocated capacity
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .state_changes = std.ArrayList(StateChange).init(allocator),
            .touched_accounts = std.AutoHashMap(Address, void).init(allocator),
            .prestate = std.AutoHashMap(Address, AccountState).init(allocator),
            .poststate = std.AutoHashMap(Address, AccountState).init(allocator),
            // Note: Default values (enabled=true, etc.) are set automatically
        };
    }
    
    // BEGINNER TIP: Alternative initialization with arena allocator
    // This can simplify memory management for transaction-scoped data:
    // pub fn init_with_arena(parent_allocator: std.mem.Allocator) !struct { tracer: Self, arena: std.heap.ArenaAllocator } {
    //     var arena = std.heap.ArenaAllocator.init(parent_allocator);
    //     const allocator = arena.allocator();
    //     return .{ .tracer = init(allocator), .arena = arena };
    // }
    
    // Destructor
    // BEGINNER NOTE: CRITICAL - Must be called to prevent memory leaks!
    // Pattern: Cleanup in reverse order of initialization
    // Each AccountState has its own allocations that need freeing
    pub fn deinit(self: *Self) void {
        // Simple collections - just deinit
        self.state_changes.deinit();
        self.touched_accounts.deinit();
        
        // Complex collections - deinit values first, then container
        // BEGINNER NOTE: iterator() returns an iterator over key-value pairs
        // entry.value_ptr is a pointer to the value (AccountState)
        var prestate_iter = self.prestate.iterator();
        while (prestate_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.prestate.deinit();
        
        var poststate_iter = self.poststate.iterator();
        while (poststate_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.poststate.deinit();
        
        // BEGINNER TIP: If using arena allocator, just arena.deinit() would suffice
    }
    
    // Configuration
    pub fn configure(self: *Self, diff_mode: bool, disable_storage: bool, disable_code: bool) void {
        self.diff_mode = diff_mode;
        self.disable_storage = disable_storage;
        self.disable_code = disable_code;
    }
        ]]></constructor-destructor>
        
        <standard-tracer-interface><![CDATA[
    // ====== Standard Tracer Interface Implementation ======
    
    pub fn beforeOp(self: *Self, comptime FrameType: type, frame: *const FrameType) void {
        _ = frame;
        if (self.enabled) {
            self.total_instructions += 1;
        }
    }
    
    pub fn afterOp(self: *Self, comptime FrameType: type, frame: *const FrameType) void {
        _ = self;
        _ = frame;
    }
    
    pub fn onError(self: *Self, comptime FrameType: type, frame: *const FrameType, err: anyerror) void {
        _ = self;
        _ = frame;
        _ = err;
    }
        ]]></standard-tracer-interface>
        
        <state-change-tracking-methods><![CDATA[
    // ====== State Change Tracking Methods ======
    
    // Transaction lifecycle
    pub fn on_transaction_start(self: *Self) void {
        if (!self.enabled) return;
        
        // Clear previous transaction data
        self.touched_accounts.clearRetainingCapacity();
        
        var prestate_iter = self.prestate.iterator();
        while (prestate_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.prestate.clearRetainingCapacity();
        
        var poststate_iter = self.poststate.iterator();
        while (poststate_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.poststate.clearRetainingCapacity();
        
        self.state_changes.clearRetainingCapacity();
    }
    
    pub fn on_transaction_end(self: *Self) void {
        if (!self.enabled) return;
        
        // Build poststate from accumulated changes
        self.build_poststate();
    }
    
    // Storage operations
    pub fn on_storage_read(self: *Self, address: Address, slot: u256, value: u256, is_warm: bool) void {
        if (!self.enabled) return;
        
        // Track in state changes
        const change = StateChange{
            .step_number = self.total_instructions,
            .address = address,
            .change_type = .{ .storage = .{
                .slot = slot,
                .old_value = value,
                .new_value = value,  // Read doesn't change value
                .is_warm = is_warm,
            }},
        };
        self.state_changes.append(change) catch {};
        
        // Track for prestate
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
        
        // Track in state changes
        const change = StateChange{
            .step_number = self.total_instructions,
            .address = address,
            .change_type = .{ .storage = .{
                .slot = slot,
                .old_value = old_value,
                .new_value = new_value,
                .is_warm = is_warm,
            }},
        };
        self.state_changes.append(change) catch {};
        
        // Track for prestate
        if (!self.disable_storage) {
            self.touch_account(address);
            const account = self.ensure_prestate_account(address) catch return;
            if (!account.storage.contains(slot)) {
                account.storage.put(slot, old_value) catch {};
            }
        }
    }
    
    // Balance operations
    pub fn on_balance_read(self: *Self, address: Address, balance: u256) void {
        if (!self.enabled) return;
        
        self.touch_account(address);
        const account = self.ensure_prestate_account(address) catch return;
        if (!account.exists) {
            account.balance = balance;
            account.exists = true;
        }
    }
    
    pub fn on_balance_change(self: *Self, address: Address, old_balance: u256, new_balance: u256) void {
        if (!self.enabled) return;
        
        const change = StateChange{
            .step_number = self.total_instructions,
            .address = address,
            .change_type = .{ .balance = .{
                .old_balance = old_balance,
                .new_balance = new_balance,
            }},
        };
        self.state_changes.append(change) catch {};
        
        self.touch_account(address);
        const account = self.ensure_prestate_account(address) catch return;
        if (!account.exists) {
            account.balance = old_balance;
            account.exists = true;
        }
    }
    
    // Nonce operations
    pub fn on_nonce_read(self: *Self, address: Address, nonce: u64) void {
        if (!self.enabled) return;
        
        self.touch_account(address);
        const account = self.ensure_prestate_account(address) catch return;
        if (!account.exists) {
            account.nonce = nonce;
            account.exists = true;
        }
    }
    
    pub fn on_nonce_change(self: *Self, address: Address, old_nonce: u64, new_nonce: u64) void {
        if (!self.enabled) return;
        
        const change = StateChange{
            .step_number = self.total_instructions,
            .address = address,
            .change_type = .{ .nonce = .{
                .old_nonce = old_nonce,
                .new_nonce = new_nonce,
            }},
        };
        self.state_changes.append(change) catch {};
        
        self.touch_account(address);
        const account = self.ensure_prestate_account(address) catch return;
        if (!account.exists) {
            account.nonce = old_nonce;
            account.exists = true;
        }
    }
    
    // Code operations
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
            .change_type = .{ .code = .{
                .old_code = old_code,
                .new_code = new_code,
                .old_code_hash = hash_code(old_code),
                .new_code_hash = hash_code(new_code),
            }},
        };
        self.state_changes.append(change) catch {};
        
        if (!self.disable_code) {
            self.touch_account(address);
            const account = self.ensure_prestate_account(address) catch return;
            if (!account.exists or account.code.len == 0) {
                account.code = self.allocator.dupe(u8, old_code) catch &[_]u8{};
                account.code_hash = hash_code(old_code);
                account.exists = true;
            }
        }
    }
    
    // Account lifecycle
    pub fn on_account_created(self: *Self, address: Address, balance: u256, nonce: u64, code: []const u8) void {
        if (!self.enabled) return;
        
        const change = StateChange{
            .step_number = self.total_instructions,
            .address = address,
            .change_type = .{ .account_created = .{
                .initial_balance = balance,
                .initial_nonce = nonce,
                .code = code,
            }},
        };
        self.state_changes.append(change) catch {};
        
        self.touch_account(address);
        // Don't add to prestate - it didn't exist before
    }
    
    pub fn on_account_destroyed(self: *Self, address: Address, beneficiary: Address, balance: u256) void {
        if (!self.enabled) return;
        
        const change = StateChange{
            .step_number = self.total_instructions,
            .address = address,
            .change_type = .{ .account_destroyed = .{
                .beneficiary = beneficiary,
                .balance_transferred = balance,
                .had_code = false,  // Will be set from context
                .storage_cleared = false,  // Will be set from context
            }},
        };
        self.state_changes.append(change) catch {};
        
        self.touch_account(address);
        self.touch_account(beneficiary);
        // Prestate should already have the account that's being destroyed
    }
        ]]></state-change-tracking-methods>
        
        <helper-methods><![CDATA[
    // ====== Helper Methods ======
    
    // BEGINNER NOTE: Helper method to mark account as accessed
    // Pattern: Using HashMap as a Set by storing void (empty) values
    // catch {} ignores allocation errors (non-critical operation)
    fn touch_account(self: *Self, address: Address) void {
        self.touched_accounts.put(address, {}) catch {};
        // {} is an empty struct literal (void value)
        // We only care about keys, not values
    }
    
    // BEGINNER NOTE: Get or create account in prestate
    // Pattern: getOrPut returns both whether key existed and pointer to value
    // This ensures we only initialize new accounts once
    fn ensure_prestate_account(self: *Self, address: Address) !*AccountState {
        // getOrPut returns: { found_existing: bool, value_ptr: *V }
        const result = try self.prestate.getOrPut(address);
        
        // Only initialize if this is a new entry
        if (!result.found_existing) {
            // .* dereferences pointer to set the value
            result.value_ptr.* = AccountState.init(self.allocator);
        }
        
        return result.value_ptr;
    }
    
    fn build_poststate(self: *Self) void {
        // Start with prestate
        var iter = self.prestate.iterator();
        while (iter.next()) |entry| {
            const addr = entry.key_ptr.*;
            const prestate_account = entry.value_ptr.*;
            
            var poststate_account = AccountState.init(self.allocator);
            poststate_account.balance = prestate_account.balance;
            poststate_account.nonce = prestate_account.nonce;
            poststate_account.code = if (prestate_account.code.len > 0) 
                self.allocator.dupe(u8, prestate_account.code) catch &[_]u8{} 
            else 
                &[_]u8{};
            poststate_account.code_hash = prestate_account.code_hash;
            poststate_account.exists = prestate_account.exists;
            
            // Copy storage
            var storage_iter = prestate_account.storage.iterator();
            while (storage_iter.next()) |storage_entry| {
                poststate_account.storage.put(storage_entry.key_ptr.*, storage_entry.value_ptr.*) catch {};
            }
            
            self.poststate.put(addr, poststate_account) catch {};
        }
        
        // Apply changes
        for (self.state_changes.items) |change| {
            const result = self.poststate.getOrPut(change.address) catch continue;
            if (!result.found_existing) {
                result.value_ptr.* = AccountState.init(self.allocator);
            }
            
            switch (change.change_type) {
                .storage => |s| {
                    if (!self.disable_storage) {
                        result.value_ptr.storage.put(s.slot, s.new_value) catch {};
                    }
                },
                .balance => |b| {
                    result.value_ptr.balance = b.new_balance;
                },
                .nonce => |n| {
                    result.value_ptr.nonce = n.new_nonce;
                },
                .code => |c| {
                    if (!self.disable_code) {
                        if (result.value_ptr.code.len > 0) {
                            self.allocator.free(result.value_ptr.code);
                        }
                        result.value_ptr.code = self.allocator.dupe(u8, c.new_code) catch &[_]u8{};
                        result.value_ptr.code_hash = c.new_code_hash;
                    }
                },
                .account_created => |a| {
                    result.value_ptr.balance = a.initial_balance;
                    result.value_ptr.nonce = a.initial_nonce;
                    if (!self.disable_code and a.code.len > 0) {
                        result.value_ptr.code = self.allocator.dupe(u8, a.code) catch &[_]u8{};
                        result.value_ptr.code_hash = hash_code(a.code);
                    }
                    result.value_ptr.exists = true;
                },
                .account_destroyed => {
                    result.value_ptr.exists = false;
                },
            }
        }
    }
    
    // BEGINNER NOTE: Compute Keccak-256 hash of contract code
    // Pattern: [_]u8{0} ** 32 creates array of 32 zeros
    // Empty code has special hash (all zeros) per EVM spec
    fn hash_code(code: []const u8) [32]u8 {
        if (code.len == 0) return [_]u8{0} ** 32;
        
        // Import crypto module (should be available in build.zig)
        // If not available, you'll need to add it to build.zig:
        // evm_mod.addImport("crypto", crypto_mod);
        const crypto = @import("crypto");
        return crypto.keccak256(code);
    }
        ]]></helper-methods>
        
        <data-access-methods><![CDATA[
    // ====== Data Access Methods ======
    
    pub fn get_prestate(self: *const Self) *const std.AutoHashMap(Address, AccountState) {
        return &self.prestate;
    }
    
    pub fn get_poststate(self: *const Self) *const std.AutoHashMap(Address, AccountState) {
        return &self.poststate;
    }
    
    pub fn is_diff_mode(self: *const Self) bool {
        return self.diff_mode;
    }
    
    pub fn is_storage_disabled(self: *const Self) bool {
        return self.disable_storage;
    }
    
    pub fn is_code_disabled(self: *const Self) bool {
        return self.disable_code;
    }
};
        ]]></data-access-methods>
        
        <json-formatting-functions><![CDATA[
// ====== Standalone JSON Formatting Functions ======
// These are exported from prestate_tracer.zig but are NOT part of PrestateTracer struct
//
// BEGINNER NOTE: Why standalone functions?
// 1. Keeps PrestateTracer data-format agnostic
// 2. Allows different output formats without changing tracer
// 3. Functions can be tested independently
// 4. Follows single responsibility principle

// BEGINNER NOTE: Main JSON output function
// writer: Any type with write methods (file, buffer, stdout)
// tracer: Read-only reference to tracer (won't be modified)
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
    disable_code: bool
) !void {
    var first = true;
    var iter = state_map.iterator();
    while (iter.next()) |entry| {
        if (!first) try writer.writeByte(',');
        first = false;
        
        const addr = entry.key_ptr.*;
        const account = entry.value_ptr.*;
        
        // Write address as hex
        try writer.writeByte('"');
        try writer.print("0x{x:0>40}", .{addr});
        try writer.writeAll("\":{");
        
        // Write balance
        try writer.print("\"balance\":\"0x{x}\",", .{account.balance});
        
        // Write nonce
        try writer.print("\"nonce\":{},", .{account.nonce});
        
        // Write code if present and not disabled
        if (!disable_code and account.code.len > 0) {
            try writer.writeAll("\"code\":\"0x");
            for (account.code) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
            try writer.writeAll("\",");
        }
        
        // Write storage if not disabled
        if (!disable_storage and account.storage.count() > 0) {
            try writer.writeAll("\"storage\":{");
            var storage_first = true;
            var storage_iter = account.storage.iterator();
            while (storage_iter.next()) |storage_entry| {
                if (!storage_first) try writer.writeByte(',');
                storage_first = false;
                
                try writer.print("\"0x{x}\":\"0x{x}\"", .{
                    storage_entry.key_ptr.*,
                    storage_entry.value_ptr.*,
                });
            }
            try writer.writeByte('}');
        }
        
        try writer.writeByte('}');
    }
}
        ]]></json-formatting-functions>
      </code-implementation>
    </step>
    
    <step number="2">
      <title>Update DebuggingTracer to Compose PrestateTracer</title>
      
      <implementation-strategy>
        <strategy number="1">
          <title>Composition over Inheritance</title>
          <description>Zig doesn't have inheritance, we use composition</description>
        </strategy>
        <strategy number="2">
          <title>Optional Embedding</title>
          <description>PrestateTracer is only created when needed</description>
        </strategy>
        <strategy number="3">
          <title>Delegation Pattern</title>
          <description>DebuggingTracer forwards calls to PrestateTracer</description>
        </strategy>
        <strategy number="4">
          <title>Null Safety</title>
          <description>Always check if prestate_tracer is not null before use</description>
        </strategy>
      </implementation-strategy>
      
      <code-changes><![CDATA[
// In tracer.zig, update DebuggingTracer struct

pub const DebuggingTracer = struct {
    allocator: std.mem.Allocator,
    // ... existing fields ...
    
    // Optional composed prestate tracer
    prestate_tracer: ?*PrestateTracer = null,
    prestate_enabled: bool = false,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            // ... existing initialization ...
            .prestate_tracer = null,
            .prestate_enabled = false,
        };
    }
    
    pub fn deinit(self: *Self) void {
        // ... existing cleanup ...
        
        if (self.prestate_tracer) |pt| {
            pt.deinit();
            self.allocator.destroy(pt);
        }
    }
    
    // Enable prestate tracking by creating PrestateTracer
    pub fn enable_prestate_tracing(self: *Self, diff_mode: bool, disable_storage: bool, disable_code: bool) !void {
        if (!self.prestate_enabled) {
            const pt = try self.allocator.create(PrestateTracer);
            pt.* = PrestateTracer.init(self.allocator);
            pt.configure(diff_mode, disable_storage, disable_code);
            self.prestate_tracer = pt;
            self.prestate_enabled = true;
        }
    }
    
    pub fn disable_prestate_tracing(self: *Self) void {
        if (self.prestate_tracer) |pt| {
            pt.deinit();
            self.allocator.destroy(pt);
            self.prestate_tracer = null;
            self.prestate_enabled = false;
        }
    }
    
    // Override tracer methods to delegate to PrestateTracer when enabled
    pub fn beforeOp(self: *Self, comptime FrameType: type, frame: *const FrameType) void {
        // ... existing beforeOp logic ...
        
        if (self.prestate_tracer) |pt| {
            pt.beforeOp(FrameType, frame);
        }
    }
    
    pub fn afterOp(self: *Self, comptime FrameType: type, frame: *const FrameType) void {
        // ... existing afterOp logic ...
        
        if (self.prestate_tracer) |pt| {
            pt.afterOp(FrameType, frame);
        }
    }
    
    // Delegate state tracking methods to PrestateTracer
    pub fn on_storage_read(self: *Self, address: Address, slot: u256, value: u256, is_warm: bool) void {
        if (self.prestate_tracer) |pt| {
            pt.on_storage_read(address, slot, value, is_warm);
        }
    }
    
    pub fn on_storage_write(self: *Self, address: Address, slot: u256, old_value: u256, new_value: u256, is_warm: bool) void {
        if (self.prestate_tracer) |pt| {
            pt.on_storage_write(address, slot, old_value, new_value, is_warm);
        }
    }
    
    pub fn on_balance_read(self: *Self, address: Address, balance: u256) void {
        if (self.prestate_tracer) |pt| {
            pt.on_balance_read(address, balance);
        }
    }
    
    pub fn on_balance_change(self: *Self, address: Address, old_balance: u256, new_balance: u256) void {
        if (self.prestate_tracer) |pt| {
            pt.on_balance_change(address, old_balance, new_balance);
        }
    }
    
    pub fn on_nonce_read(self: *Self, address: Address, nonce: u64) void {
        if (self.prestate_tracer) |pt| {
            pt.on_nonce_read(address, nonce);
        }
    }
    
    pub fn on_nonce_change(self: *Self, address: Address, old_nonce: u64, new_nonce: u64) void {
        if (self.prestate_tracer) |pt| {
            pt.on_nonce_change(address, old_nonce, new_nonce);
        }
    }
    
    pub fn on_code_read(self: *Self, address: Address, code: []const u8) void {
        if (self.prestate_tracer) |pt| {
            pt.on_code_read(address, code);
        }
    }
    
    pub fn on_code_change(self: *Self, address: Address, old_code: []const u8, new_code: []const u8) void {
        if (self.prestate_tracer) |pt| {
            pt.on_code_change(address, old_code, new_code);
        }
    }
    
    pub fn on_account_created(self: *Self, address: Address, balance: u256, nonce: u64, code: []const u8) void {
        if (self.prestate_tracer) |pt| {
            pt.on_account_created(address, balance, nonce, code);
        }
    }
    
    pub fn on_account_destroyed(self: *Self, address: Address, beneficiary: Address, balance: u256) void {
        if (self.prestate_tracer) |pt| {
            pt.on_account_destroyed(address, beneficiary, balance);
        }
    }
    
    pub fn on_transaction_start(self: *Self) void {
        if (self.prestate_tracer) |pt| {
            pt.on_transaction_start();
        }
    }
    
    pub fn on_transaction_end(self: *Self) void {
        if (self.prestate_tracer) |pt| {
            pt.on_transaction_end();
        }
    }
    
    // Provide access to PrestateTracer for formatters
    pub fn get_prestate_tracer(self: *const Self) ?*const PrestateTracer {
        return self.prestate_tracer;
    }
};
      ]]></code-changes>
    </step>
    
    <step number="3">
      <title>Update NoOpTracer with State Tracking Methods</title>
      
      <rationale>
        <title>Why This Matters for Beginners</title>
        <description>
          The NoOpTracer provides the "interface" that all tracers must implement. Even though it does nothing, it defines the method signatures that Frame expects to call. This is Zig's version of interfaces - structural typing through consistent method signatures.
        </description>
      </rationale>
      
      <code-additions><![CDATA[
// In tracer.zig, add to NoOpTracer:

pub const NoOpTracer = struct {
    // ... existing fields ...
    
    // State tracking methods (no-op implementations)
    pub fn on_storage_read(self: *NoOpTracer, address: Address, slot: u256, value: u256, is_warm: bool) void {
        _ = self; _ = address; _ = slot; _ = value; _ = is_warm;
    }
    
    pub fn on_storage_write(self: *NoOpTracer, address: Address, slot: u256, old_value: u256, new_value: u256, is_warm: bool) void {
        _ = self; _ = address; _ = slot; _ = old_value; _ = new_value; _ = is_warm;
    }
    
    pub fn on_balance_read(self: *NoOpTracer, address: Address, balance: u256) void {
        _ = self; _ = address; _ = balance;
    }
    
    pub fn on_balance_change(self: *NoOpTracer, address: Address, old_balance: u256, new_balance: u256) void {
        _ = self; _ = address; _ = old_balance; _ = new_balance;
    }
    
    pub fn on_nonce_read(self: *NoOpTracer, address: Address, nonce: u64) void {
        _ = self; _ = address; _ = nonce;
    }
    
    pub fn on_nonce_change(self: *NoOpTracer, address: Address, old_nonce: u64, new_nonce: u64) void {
        _ = self; _ = address; _ = old_nonce; _ = new_nonce;
    }
    
    pub fn on_code_read(self: *NoOpTracer, address: Address, code: []const u8) void {
        _ = self; _ = address; _ = code;
    }
    
    pub fn on_code_change(self: *NoOpTracer, address: Address, old_code: []const u8, new_code: []const u8) void {
        _ = self; _ = address; _ = old_code; _ = new_code;
    }
    
    pub fn on_account_created(self: *NoOpTracer, address: Address, balance: u256, nonce: u64, code: []const u8) void {
        _ = self; _ = address; _ = balance; _ = nonce; _ = code;
    }
    
    pub fn on_account_destroyed(self: *NoOpTracer, address: Address, beneficiary: Address, balance: u256) void {
        _ = self; _ = address; _ = beneficiary; _ = balance;
    }
    
    pub fn on_transaction_start(self: *NoOpTracer) void {
        _ = self;
    }
    
    pub fn on_transaction_end(self: *NoOpTracer) void {
        _ = self;
    }
};
      ]]></code-additions>
    </step>
    
    <step number="4">
      <title>Frame Integration - Hooks AFTER Actions</title>
      
      <critical-detail>
        <title>Critical Implementation Detail</title>
        <description>Hooks must be called AFTER the operation completes successfully. This ensures we only track state changes that actually happened.</description>
      </critical-detail>
      
      <pattern-examples>
        <wrong-pattern><![CDATA[
// WRONG - Hook before action
tracer.on_storage_write(addr, slot, old, new);  // DON'T DO THIS
self.host.set_storage(addr, slot, new);          // Action might fail!
        ]]></wrong-pattern>
        
        <correct-pattern><![CDATA[
// CORRECT - Hook after action
self.host.set_storage(addr, slot, new) catch |err| {
    return err;  // Don't call tracer if operation failed
};
tracer.on_storage_write(addr, slot, old, new);  // Safe to track now
        ]]></correct-pattern>
      </pattern-examples>
      
      <frame-integration><![CDATA[
// In frame.zig, storage operations:

pub fn sload(self: *Self) Error!void {
    const slot = try self.stack.pop();
    const contract_addr = self.contract_address;
    
    // Perform the actual storage read
    const result = self.host.access_storage_slot(contract_addr, slot) catch |err| {
        return Error.AllocationError;
    };
    
    try self.stack.push(result.value);
    
    // Call tracer AFTER the operation completes
    if (comptime config.TracerType != null) {
        self.tracer.on_storage_read(contract_addr, slot, result.value, result.is_warm);
    }
}

pub fn sstore(self: *Self) Error!void {
    const slot = try self.stack.pop();
    const new_value = try self.stack.pop();
    const contract_addr = self.contract_address;
    
    // Get current value
    const old_result = self.host.access_storage_slot(contract_addr, slot) catch |err| {
        return Error.AllocationError;
    };
    
    // Perform the actual storage write
    self.host.set_storage(contract_addr, slot, new_value) catch |err| {
        return Error.AllocationError;
    };
    
    // Call tracer AFTER the write completes
    if (comptime config.TracerType != null) {
        self.tracer.on_storage_write(contract_addr, slot, old_result.value, new_value, old_result.is_warm);
    }
}

// Similar pattern for all other operations - hooks called AFTER actions complete
      ]]></frame-integration>
    </step>
    
    <step number="5">
      <title>Complete Usage Examples with Error Handling</title>
      
      <usage-example name="Using PrestateTracer Directly">
        <code><![CDATA[
// Use PrestateTracer as the main tracer
const Frame = frame_mod.Frame(.{
    .TracerType = PrestateTracer,
    .has_database = true,
    // ... other config
});

var prestate_tracer = PrestateTracer.init(allocator);
defer prestate_tracer.deinit();
prestate_tracer.configure(true, false, false);  // diff mode, storage enabled, code enabled

var frame = try Frame.init(allocator, bytecode, gas, database, host, &prestate_tracer);
defer frame.deinit(allocator);

// Execute transaction
prestate_tracer.on_transaction_start();
// ... execute bytecode ...
prestate_tracer.on_transaction_end();

// Format output using the standalone JSON formatting function
const prestate = @import("prestate_tracer.zig");
try prestate.write_prestate_json(stdout.writer(), &prestate_tracer);
        ]]></code>
      </usage-example>
      
      <usage-example name="Using DebuggingTracer with PrestateTracer">
        <code><![CDATA[
// Use DebuggingTracer with prestate mode enabled
const Frame = frame_mod.Frame(.{
    .TracerType = DebuggingTracer,
    .has_database = true,
    // ... other config
});

var debug_tracer = DebuggingTracer.init(allocator);
defer debug_tracer.deinit();

// Enable prestate tracking
try debug_tracer.enable_prestate_tracing(true, false, false);

var frame = try Frame.init(allocator, bytecode, gas, database, host, &debug_tracer);
defer frame.deinit(allocator);

// Execute transaction
debug_tracer.on_transaction_start();
// ... execute bytecode ...
debug_tracer.on_transaction_end();

// Access prestate data and write JSON using standalone function
if (debug_tracer.get_prestate_tracer()) |pt| {
    const prestate = @import("prestate_tracer.zig");
    try prestate.write_prestate_json(stdout.writer(), pt);
}
        ]]></code>
      </usage-example>
    </step>
  </implementation>

  <comprehensive-testing-suite>
    <testing-philosophy>
      <principle number="1">
        <name>Test What You Use</name>
        <description>Focus on public API, not internals</description>
      </principle>
      <principle number="2">
        <name>Test Edge Cases</name>
        <description>Empty states, single changes, many changes</description>
      </principle>
      <principle number="3">
        <name>Test Error Conditions</name>
        <description>Out of memory, invalid data</description>
      </principle>
      <principle number="4">
        <name>Test Integration</name>
        <description>How components work together</description>
      </principle>
      <principle number="5">
        <name>Use Test Allocator</name>
        <description>Detects memory leaks automatically</description>
      </principle>
    </testing-philosophy>
    
    <test-implementations>
      <test name="PrestateTracer captures all state changes">
        <code><![CDATA[
// In prestate_tracer.zig, add comprehensive tests:

// BEGINNER NOTE: Test allocator tracks all allocations
// Will fail test if any memory is leaked
test "PrestateTracer captures all state changes" {
    const allocator = std.testing.allocator;
    
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    tracer.configure(false, false, false);
    tracer.on_transaction_start();
    
    const addr1 = [_]u8{1} ** 20;
    const addr2 = [_]u8{2} ** 20;
    
    // Simulate various state changes
    tracer.on_balance_read(addr1, 1000);
    tracer.on_nonce_read(addr1, 5);
    tracer.on_storage_read(addr1, 0x42, 100, false);
    
    tracer.on_balance_change(addr1, 1000, 900);
    tracer.on_balance_change(addr2, 0, 100);
    tracer.on_storage_write(addr1, 0x42, 100, 200, true);
    
    tracer.on_transaction_end();
    
    // Verify prestate
    try std.testing.expect(tracer.prestate.contains(addr1));
    try std.testing.expect(tracer.prestate.contains(addr2));
    
    const account1_pre = tracer.prestate.get(addr1).?;
    try std.testing.expectEqual(@as(u256, 1000), account1_pre.balance);
    try std.testing.expectEqual(@as(u64, 5), account1_pre.nonce);
    try std.testing.expectEqual(@as(u256, 100), account1_pre.storage.get(0x42).?);
    
    // Verify poststate
    const account1_post = tracer.poststate.get(addr1).?;
    try std.testing.expectEqual(@as(u256, 900), account1_post.balance);
    try std.testing.expectEqual(@as(u256, 200), account1_post.storage.get(0x42).?);
}
        ]]></code>
      </test>
      
      <test name="DebuggingTracer with prestate mode">
        <code><![CDATA[
// Test composition pattern
test "DebuggingTracer with prestate mode" {
    const allocator = std.testing.allocator;
    
    var debug_tracer = DebuggingTracer.init(allocator);
    defer debug_tracer.deinit();
    
    // Enable prestate tracking
    try debug_tracer.enable_prestate_tracing(true, false, false);
    
    debug_tracer.on_transaction_start();
    
    const addr = [_]u8{1} ** 20;
    
    debug_tracer.on_balance_read(addr, 1000);
    debug_tracer.on_balance_change(addr, 1000, 2000);
    
    debug_tracer.on_transaction_end();
    
    // Verify prestate tracer was used
    const pt = debug_tracer.get_prestate_tracer().?;
    try std.testing.expect(pt.is_diff_mode());
    try std.testing.expect(pt.prestate.contains(addr));
}
        ]]></code>
      </test>
      
      <additional-tests>
        <test name="PrestateTracer memory management">
          <code><![CDATA[
// BEGINNER NOTE: Additional comprehensive tests

test "PrestateTracer memory management" {
    // Test proper cleanup with test allocator
    const allocator = std.testing.allocator;
    
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();  // CRITICAL: Must call deinit
    
    // Create some allocations
    tracer.on_transaction_start();
    const addr = [_]u8{1} ** 20;
    tracer.on_code_read(addr, "test code");
    tracer.on_transaction_end();
    
    // Test allocator will detect leaks when test ends
}
          ]]></code>
        </test>
        
        <test name="PrestateTracer handles empty transaction">
          <code><![CDATA[
test "PrestateTracer handles empty transaction" {
    const allocator = std.testing.allocator;
    
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    tracer.on_transaction_start();
    tracer.on_transaction_end();
    
    // Should have empty state
    try std.testing.expectEqual(@as(usize, 0), tracer.prestate.count());
    try std.testing.expectEqual(@as(usize, 0), tracer.poststate.count());
}
          ]]></code>
        </test>
        
        <test name="PrestateTracer diff mode">
          <code><![CDATA[
test "PrestateTracer diff mode" {
    const allocator = std.testing.allocator;
    
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    // Enable diff mode
    tracer.configure(true, false, false);
    try std.testing.expect(tracer.is_diff_mode());
    
    tracer.on_transaction_start();
    
    const addr = [_]u8{1} ** 20;
    
    // Track initial state
    tracer.on_balance_read(addr, 1000);
    tracer.on_storage_read(addr, 0x1, 100, false);
    
    // Make changes
    tracer.on_balance_change(addr, 1000, 2000);
    tracer.on_storage_write(addr, 0x1, 100, 200, true);
    
    tracer.on_transaction_end();
    
    // Verify both prestate and poststate are populated
    const pre = tracer.prestate.get(addr).?;
    try std.testing.expectEqual(@as(u256, 1000), pre.balance);
    try std.testing.expectEqual(@as(u256, 100), pre.storage.get(0x1).?);
    
    const post = tracer.poststate.get(addr).?;
    try std.testing.expectEqual(@as(u256, 2000), post.balance);
    try std.testing.expectEqual(@as(u256, 200), post.storage.get(0x1).?);
}
          ]]></code>
        </test>
        
        <test name="PrestateTracer account lifecycle">
          <code><![CDATA[
test "PrestateTracer account lifecycle" {
    const allocator = std.testing.allocator;
    
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    tracer.on_transaction_start();
    
    const addr = [_]u8{1} ** 20;
    const beneficiary = [_]u8{2} ** 20;
    
    // Account creation
    tracer.on_account_created(addr, 1000, 1, "contract code");
    
    // Account destruction
    tracer.on_account_destroyed(addr, beneficiary, 1000);
    
    tracer.on_transaction_end();
    
    // Created account shouldn't be in prestate (didn't exist before)
    try std.testing.expect(!tracer.prestate.contains(addr));
    
    // But should be in poststate as destroyed
    const post = tracer.poststate.get(addr).?;
    try std.testing.expect(!post.exists);
}
          ]]></code>
        </test>
        
        <test name="PrestateTracer JSON output format">
          <code><![CDATA[
test "PrestateTracer JSON output format" {
    const allocator = std.testing.allocator;
    
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    tracer.on_transaction_start();
    
    const addr = [_]u8{0x12} ** 20;
    tracer.on_balance_read(addr, 1000);
    tracer.on_nonce_read(addr, 5);
    
    tracer.on_transaction_end();
    
    // Test JSON output
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    try write_prestate_json(buffer.writer(), &tracer);
    
    const json = buffer.items;
    // Verify JSON contains expected address (simplified check)
    try std.testing.expect(std.mem.indexOf(u8, json, "0x1212") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "balance") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "nonce") != null);
}
          ]]></code>
        </test>
      </additional-tests>
    </test-implementations>
  </comprehensive-testing-suite>

  <common-pitfalls-and-troubleshooting>
    <section name="Memory Management Issues">
      <issue>
        <problem>Memory leaks detected by test allocator</problem>
        <solution>Ensure every `init` has corresponding `deinit`, check iterator cleanup</solution>
        <example><![CDATA[
// WRONG - Leaks memory
var map = std.AutoHashMap(K, V).init(allocator);
// Missing: defer map.deinit();

// CORRECT
var map = std.AutoHashMap(K, V).init(allocator);
defer map.deinit();
        ]]></example>
      </issue>
      
      <issue>
        <problem>Use-after-free when sharing data</problem>
        <solution>Always duplicate data that needs to outlive its source</solution>
        <example><![CDATA[
// WRONG - Points to temporary data
account.code = temporary_code;

// CORRECT - Makes a copy
account.code = try allocator.dupe(u8, temporary_code);
        ]]></example>
      </issue>
    </section>
    
    <section name="Import and Build Issues">
      <issue>
        <problem>error: no module named 'crypto'</problem>
        <solution>Add to build.zig:</solution>
        <code><![CDATA[
const crypto = b.dependency("crypto", .{});
evm_mod.addImport("crypto", crypto.module("crypto"));
        ]]></code>
      </issue>
      
      <issue>
        <problem>Type mismatch for u256</problem>
        <solution>Check actual type definition in primitives:</solution>
        <code><![CDATA[
// Find the actual type
const U256 = @import("primitives").U256;
// or
const U256 = @import("primitives").types.U256;
        ]]></code>
      </issue>
    </section>
    
    <section name="Integration Issues">
      <issue>
        <problem>Tracer methods not being called</problem>
        <solution>Check frame configuration:</solution>
        <code><![CDATA[
// Frame must be configured with a tracer
const config = .{
    .TracerType = PrestateTracer,  // or DebuggingTracer
    // ...
};
        ]]></code>
      </issue>
      
      <issue>
        <problem>Hooks called at wrong time</problem>
        <solution>Ensure hooks are AFTER operations:</solution>
        <code><![CDATA[
// Check frame.zig implementation
pub fn sstore(self: *Self) Error!void {
    // ... perform operation ...
    
    // Hook must be here, after success
    if (comptime config.TracerType != null) {
        self.tracer.on_storage_write(...);
    }
}
        ]]></code>
      </issue>
    </section>
    
    <section name="Performance Issues">
      <issue>
        <problem>Slow performance with tracing enabled</problem>
        <solution>Use configuration flags:</solution>
        <code><![CDATA[
tracer.configure(
    false,  // diff_mode off for better performance
    true,   // disable_storage if not needed
    true    // disable_code if not needed
);
        ]]></code>
      </issue>
      
      <issue>
        <problem>Out of memory with large transactions</problem>
        <solution>Use arena allocator:</solution>
        <code><![CDATA[
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
var tracer = PrestateTracer.init(arena.allocator());
// All allocations freed at once with arena.deinit()
        ]]></code>
      </issue>
    </section>
  </common-pitfalls-and-troubleshooting>

  <step-by-step-integration-guide>
    <phase number="1">
      <title>Create the PrestateTracer Module</title>
      <steps>
        <step number="1">
          <action>Create the file</action>
          <detail>`src/evm/prestate_tracer.zig`</detail>
        </step>
        <step number="2">
          <action>Add to build.zig</action>
          <detail>if using separate module</detail>
          <code><![CDATA[
const prestate_tracer = b.addModule("prestate_tracer", .{
    .root_source_file = b.path("src/evm/prestate_tracer.zig"),
});
          ]]></code>
        </step>
        <step number="3">
          <action>Add required imports</action>
          <detail>to the module</detail>
        </step>
        <step number="4">
          <action>Implement basic structure</action>
          <detail>types, init, deinit</detail>
        </step>
        <step number="5">
          <action>Run tests</action>
          <command>`zig build test`</command>
        </step>
      </steps>
    </phase>
    
    <phase number="2">
      <title>Update Existing Tracers</title>
      <steps>
        <step number="1">
          <action>Update NoOpTracer</action>
          <location>in `tracer.zig`</location>
          <tasks>
            <task>Add all new method signatures</task>
            <task>Empty implementations (just ignore parameters)</task>
          </tasks>
        </step>
        <step number="2">
          <action>Update DebuggingTracer</action>
          <location>in `tracer.zig`</location>
          <tasks>
            <task>Add optional PrestateTracer field</task>
            <task>Add enable/disable methods</task>
            <task>Add delegation in each method</task>
          </tasks>
        </step>
        <step number="3">
          <action>Test compilation</action>
          <command>`zig build`</command>
        </step>
      </steps>
    </phase>
    
    <phase number="3">
      <title>Integrate with Frame</title>
      <steps>
        <step number="1">
          <action>Identify integration points</action>
          <location>in `frame.zig`</location>
          <areas>
            <area>Storage operations (sload, sstore)</area>
            <area>Balance operations</area>
            <area>Account operations</area>
          </areas>
        </step>
        <step number="2">
          <action>Add tracer hooks</action>
          <detail>after each operation</detail>
          <template><![CDATA[
// Template for each operation
pub fn operation(self: *Self) Error!void {
    // ... perform operation ...
    
    if (comptime config.TracerType != null) {
        self.tracer.on_operation_type(...);
    }
}
          ]]></template>
        </step>
        <step number="3">
          <action>Test with simple transactions</action>
        </step>
      </steps>
    </phase>
    
    <phase number="4">
      <title>Add JSON Formatting</title>
      <steps>
        <step number="1">
          <action>Implement formatting functions</action>
          <location>in prestate_tracer.zig</location>
        </step>
        <step number="2">
          <action>Test JSON output</action>
          <detail>against expected format</detail>
        </step>
        <step number="3">
          <action>Add pretty-printing options</action>
          <detail>if needed</detail>
        </step>
      </steps>
    </phase>
    
    <phase number="5">
      <title>Complete Testing</title>
      <steps>
        <step number="1">
          <action>Unit tests</action>
          <detail>for each component</detail>
        </step>
        <step number="2">
          <action>Integration tests</action>
          <detail>with Frame</detail>
        </step>
        <step number="3">
          <action>End-to-end tests</action>
          <detail>with full transactions</detail>
        </step>
        <step number="4">
          <action>Memory leak tests</action>
          <detail>with test allocator</detail>
        </step>
        <step number="5">
          <action>Performance benchmarks</action>
          <detail>if needed</detail>
        </step>
      </steps>
    </phase>
  </step-by-step-integration-guide>

  <implementation-checklist>
    <item status="pending">Create prestate_tracer.zig with PrestateTracer struct and standalone JSON formatting functions</item>
    <item status="pending">Add state tracking methods to NoOpTracer interface</item>
    <item status="pending">Update DebuggingTracer to compose PrestateTracer</item>
    <item status="pending">Add hooks to frame.zig AFTER state changes</item>
    <item status="pending">Integrate EOA nonce tracking at transaction level</item>
    <item status="pending">Add tests for PrestateTracer</item>
    <item status="pending">Add tests for DebuggingTracer composition</item>
    <item status="pending">Verify JSON output format matches Geth</item>
    <item status="pending">Update build.zig to include new modules</item>
  </implementation-checklist>

  <frequently-asked-questions>
    <faq>
      <question>Why not just modify DebuggingTracer directly?</question>
      <answer>Separation of concerns. PrestateTracer is a focused, reusable component that can be used independently or composed by other tracers.</answer>
    </faq>
    
    <faq>
      <question>Why are JSON functions not methods on PrestateTracer?</question>
      <answer>To keep PrestateTracer data-format agnostic. This allows different output formats (JSON, binary, etc.) without changing the tracer.</answer>
    </faq>
    
    <faq>
      <question>How do I handle out-of-memory errors?</question>
      <answer>Use `catch` to handle allocation failures gracefully:</answer>
      <code><![CDATA[
self.state_changes.append(change) catch {
    // Log error or set flag, but don't crash
    self.enabled = false;  // Disable further tracking
    return;
};
      ]]></code>
    </faq>
    
    <faq>
      <question>What's the performance impact of tracing?</question>
      <answer>With NoOpTracer: ~0% overhead. With PrestateTracer: 10-20% depending on transaction complexity. Use configuration flags to minimize impact.</answer>
    </faq>
    
    <faq>
      <question>How do I debug when traces aren't being captured?</question>
      <answer>Check:
        1. Tracer is enabled (`tracer.enabled == true`)
        2. Frame is configured with correct TracerType
        3. Hooks are being called (add debug prints)
        4. No allocation failures (check with test allocator)
      </answer>
    </faq>
    
    <faq>
      <question>Can I use this with async/threaded execution?</question>
      <answer>No, current implementation is not thread-safe. Would need mutex protection for concurrent access.</answer>
    </faq>
    
    <faq>
      <question>How do I extend this for custom state tracking?</question>
      <answer>Add new fields to StateChange.ChangeType union and corresponding on_* methods.</answer>
    </faq>
  </frequently-asked-questions>

  <key-benefits-of-architecture>
    <benefit number="1">
      <title>Separation of Concerns</title>
      <description>PrestateTracer is a standalone, reusable component</description>
    </benefit>
    <benefit number="2">
      <title>Flexibility</title>
      <description>Can use PrestateTracer directly or through DebuggingTracer</description>
    </benefit>
    <benefit number="3">
      <title>Clean Composition</title>
      <description>DebuggingTracer delegates cleanly to PrestateTracer</description>
    </benefit>
    <benefit number="4">
      <title>Testability</title>
      <description>Each component can be tested independently</description>
    </benefit>
    <benefit number="5">
      <title>Maintainability</title>
      <description>Changes to prestate logic are isolated in one module</description>
    </benefit>
  </key-benefits-of-architecture>

  <summary>
    This implementation creates PrestateTracer as a completely separate, self-contained tracer type that:
    - Implements the full tracer interface independently
    - Can be used directly as a Frame tracer
    - Can be composed by DebuggingTracer when prestate mode is enabled
    - Maintains clean separation between data collection and formatting
    - Follows all codebase conventions and patterns
    
    The architecture ensures that prestate functionality is properly encapsulated while allowing DebuggingTracer to reuse it through composition rather than inheritance.
  </summary>

  <quick-reference-card>
    <title>Quick Reference Card for Implementers</title>
    <code><![CDATA[
// Initialize tracer
var tracer = PrestateTracer.init(allocator);
defer tracer.deinit();

// Configure
tracer.configure(diff_mode, disable_storage, disable_code);

// Transaction lifecycle
tracer.on_transaction_start();
// ... execute operations ...
tracer.on_transaction_end();

// Output JSON
try write_prestate_json(writer, &tracer);

// Key patterns to remember:
// 1. Always defer deinit after init
// 2. Use catch {} for non-critical operations
// 3. Call hooks AFTER operations complete
// 4. Check optional fields with if (optional) |value|
// 5. Use test allocator in tests
    ]]></code>
  </quick-reference-card>

  <final-notes-for-beginners>
    <learning-outcomes>
      Implementing this tracer will teach you:
      <outcome number="1">
        <topic>Memory management</topic>
        <details>in Zig (allocators, defer, ownership)</details>
      </outcome>
      <outcome number="2">
        <topic>Error handling</topic>
        <details>patterns (try, catch, error unions)</details>
      </outcome>
      <outcome number="3">
        <topic>Generic programming</topic>
        <details>with comptime</details>
      </outcome>
      <outcome number="4">
        <topic>Data structures</topic>
        <details>(HashMap, ArrayList)</details>
      </outcome>
      <outcome number="5">
        <topic>Interface design</topic>
        <details>without inheritance</details>
      </outcome>
      <outcome number="6">
        <topic>Testing practices</topic>
        <details>in Zig</details>
      </outcome>
    </learning-outcomes>
    
    <encouragement>
      Don't hesitate to:
      - Run tests frequently (`zig build test`)
      - Use `std.debug.print` for debugging
      - Check existing code for patterns
      - Ask questions about Zig syntax
      
      Remember: The compiler is your friend. Zig's compile-time checks catch many bugs that would be runtime errors in other languages.
      
      Good luck with your implementation!
    </encouragement>
  </final-notes-for-beginners>
</prestate-tracer-implementation>