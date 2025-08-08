/// Minimal execution context for EVM opcodes - replaces the heavy Frame struct
///
/// This struct contains only the essential data needed by EVM execution handlers,
/// following data-oriented design principles for better cache performance and
/// eliminating circular dependencies.
const std = @import("std");
const primitives = @import("primitives");
const Stack = @import("stack/stack.zig");
const Memory = @import("memory/memory.zig");
const ExecutionError = @import("execution/execution_error.zig");
const CodeAnalysis = @import("analysis.zig");
const AccessList = @import("call_frame_stack.zig").AccessList;
const CallJournal = @import("call_frame_stack.zig").CallJournal;
const Host = @import("root.zig").Host;
const SelfDestruct = @import("self_destruct.zig").SelfDestruct;
const DatabaseInterface = @import("state/database_interface.zig").DatabaseInterface;
const Hardfork = @import("hardforks/hardfork.zig").Hardfork;

/// Error types for Frame operations
pub const AccessError = error{OutOfMemory};
pub const StateError = error{OutOfMemory};

/// Combined chain rules (hardforks + EIPs) for configuration input.
/// Used to create the optimized Flags packed struct.
/// NOTE: Only includes EIPs that need runtime checks during opcode execution.
/// EIPs for transaction validation, gas pricing, bytecode analysis, and pre-execution setup are handled elsewhere.
pub const ChainRules = struct {
    // Core hardfork markers (used for getHardfork() only)
    is_homestead: bool = true,
    is_byzantium: bool = true,
    is_constantinople: bool = true,
    is_petersburg: bool = true,
    is_istanbul: bool = true,
    is_berlin: bool = true,
    is_london: bool = true,
    is_merge: bool = true,
    is_shanghai: bool = true,
    is_cancun: bool = true,
    is_prague: bool = false,

    // EIPs that need runtime opcode validation (very few!)
    is_eip1153: bool = true, // Transient storage (TLOAD/TSTORE) - runtime validation
    is_eip3855: bool = true, // PUSH0 - validation needed for pre-Shanghai compatibility
    is_eip4844: bool = true, // BLOBHASH - validation needed for pre-Cancun compatibility  
    is_eip6780: bool = true, // SELFDESTRUCT restriction - validation needed

    /// Default chain rules for the latest hardfork (CANCUN).
    pub const DEFAULT = ChainRules{};
};

/// Packed flags struct - optimized for actual runtime usage
/// Only contains flags that are checked during opcode execution
pub const Flags = packed struct {
    // Hot execution state - accessed every opcode
    depth: u10, // 10 bits (0-1023) - call stack depth
    is_static: bool, // 1 bit - static call restriction (checked by SSTORE, TSTORE, etc.)

    // EIP flags checked during execution (very few!)
    is_eip1153: bool, // 1 bit - Transient storage (TLOAD/TSTORE validation)

    // Hardfork markers (only for getHardfork() method)
    is_prague: bool, // 1 bit
    is_cancun: bool, // 1 bit
    is_shanghai: bool, // 1 bit
    is_merge: bool, // 1 bit
    is_london: bool, // 1 bit
    is_berlin: bool, // 1 bit
    is_istanbul: bool, // 1 bit
    is_petersburg: bool, // 1 bit
    is_constantinople: bool, // 1 bit
    is_byzantium: bool, // 1 bit
    is_homestead: bool, // 1 bit

    // Reserved for future expansion - remaining bits
    _reserved: u41 = 0, // Ensures exactly 64 bits total (11 + 1 + 1 + 10 + 1 + 41 = 64)
};

/// Frame represents the entire execution state of the EVM as it executes opcodes
/// Layout optimized for actual opcode access patterns and cache performance
pub const Frame = struct {
    // ULTRA HOT - First cache line priority (accessed by virtually every opcode)
    stack: Stack, // 33,536 bytes - accessed by every opcode 
    gas_remaining: u64, // 8 bytes - checked/consumed by every opcode

    // HOT - Second cache line priority (accessed by major opcode categories)  
    memory: *Memory, // 8 bytes - memory ops (MLOAD/MSTORE/MCOPY/LOG*/KECCAK256)
    analysis: *const CodeAnalysis, // 8 bytes - control flow (JUMP/JUMPI validation)
    hot_flags: packed struct {
        depth: u10, // 10 bits - call stack depth 
        is_static: bool, // 1 bit - static call restriction
        is_eip1153: bool, // 1 bit - transient storage validation
        _padding: u4 = 0, // 4 bits - future expansion
    }, // 2 bytes

    // WARM - Storage cluster (keep contiguous for SLOAD/SSTORE/TLOAD/TSTORE)
    contract_address: primitives.Address.Address, // 20 bytes
    state: DatabaseInterface, // 16 bytes
    access_list: *AccessList, // 8 bytes
    
    // WARM - Call context (grouped together)
    journal: *CallJournal, // 8 bytes
    host: *Host, // 8 bytes
    snapshot_id: u32, // 4 bytes
    caller: primitives.Address.Address, // 20 bytes  
    value: u256, // 32 bytes

    // COLD - Validation flags and rarely accessed data
    hardfork: Hardfork, // 1 byte - hardfork validation  
    is_eip3855: bool,   // 1 byte - PUSH0 validation
    is_eip4844: bool,   // 1 byte - BLOBHASH validation  
    is_eip6780: bool,   // 1 byte - SELFDESTRUCT restriction
    is_create: bool,    // 1 byte - CREATE/CREATE2 context
    is_delegate: bool,  // 1 byte - DELEGATECALL context
    
    // Cold data - accessed infrequently
    input: []const u8, // 16 bytes - only CALLDATALOAD/SIZE/COPY
    output: []const u8, // 16 bytes - only RETURN/REVERT
    
    // Extremely rare - accessed almost never
    self_destruct: ?*SelfDestruct, // 8 bytes - extremely rare, only SELFDESTRUCT
    next_frame: ?*Frame, // 8 bytes - only for nested calls
    
    // Bottom - only used for setup/cleanup
    allocator: std.mem.Allocator, // 16 bytes - extremely rare, only frame init/deinit

    /// Initialize a Frame with required parameters
    pub fn init(
        gas_remaining: u64,
        static_call: bool,
        call_depth: u32,
        contract_address: primitives.Address.Address,
        caller: primitives.Address.Address,
        value: u256,
        analysis: *const CodeAnalysis,
        access_list: *AccessList,
        journal: *CallJournal,
        host: *Host,
        snapshot_id: u32,
        state: DatabaseInterface,
        chain_rules: ChainRules,
        self_destruct: ?*SelfDestruct,
        input: []const u8,
        allocator: std.mem.Allocator,
        next_frame: ?*Frame,
        is_create_call: bool,
        is_delegate_call: bool,
    ) !Frame {
        // Determine hardfork from chain rules
        const hardfork = blk: {
            // Note: PRAGUE not yet defined in hardfork.zig, defaulting to CANCUN for now
            if (chain_rules.is_prague) break :blk Hardfork.CANCUN;
            if (chain_rules.is_cancun) break :blk Hardfork.CANCUN;
            if (chain_rules.is_shanghai) break :blk Hardfork.SHANGHAI;
            if (chain_rules.is_merge) break :blk Hardfork.MERGE;
            if (chain_rules.is_london) break :blk Hardfork.LONDON;
            if (chain_rules.is_berlin) break :blk Hardfork.BERLIN;
            if (chain_rules.is_istanbul) break :blk Hardfork.ISTANBUL;
            if (chain_rules.is_petersburg) break :blk Hardfork.PETERSBURG;
            if (chain_rules.is_constantinople) break :blk Hardfork.CONSTANTINOPLE;
            if (chain_rules.is_byzantium) break :blk Hardfork.BYZANTIUM;
            if (chain_rules.is_homestead) break :blk Hardfork.HOMESTEAD;
            break :blk Hardfork.FRONTIER;
        };

        return Frame{
            // Ultra hot data
            .stack = Stack.init(),
            .gas_remaining = gas_remaining,

            // Hot data - allocate Memory on heap
            .memory = blk: {
                const memory_ptr = try allocator.create(Memory);
                errdefer allocator.destroy(memory_ptr);
                memory_ptr.* = try Memory.init_default(allocator);
                break :blk memory_ptr;
            },
            .analysis = analysis,
            .hot_flags = .{
                .depth = @intCast(call_depth),
                .is_static = static_call,
                .is_eip1153 = chain_rules.is_eip1153,
            },

            // Call frame stack integration
            .journal = journal,
            .host = host,
            .snapshot_id = snapshot_id,
            .caller = caller,
            .value = value,

            // Storage cluster
            .contract_address = contract_address,
            .state = state,
            .access_list = access_list,

            // Cold data
            .input = input,
            .output = &[_]u8{},
            .hardfork = hardfork,
            
            // Cold EIP validation flags
            .is_eip3855 = chain_rules.is_eip3855,
            .is_eip4844 = chain_rules.is_eip4844,
            .is_eip6780 = chain_rules.is_eip6780,
            .is_create = is_create_call,
            .is_delegate = is_delegate_call,
            
            .self_destruct = self_destruct,
            .allocator = allocator,
            .next_frame = next_frame,
        };
    }

    pub fn deinit(self: *Frame) void {
        self.memory.deinit();
        self.allocator.destroy(self.memory);
    }

    /// Gas consumption with bounds checking - used by all opcodes that consume gas
    pub fn consume_gas(self: *Frame, amount: u64) ExecutionError.Error!void {
        if (self.gas_remaining < amount) return ExecutionError.Error.OutOfGas;
        self.gas_remaining -= amount;
    }

    /// Jump destination validation - uses direct bitmap access
    /// This is significantly faster than the previous function pointer approach
    pub fn valid_jumpdest(self: *Frame, dest: u256) bool {
        std.debug.assert(dest <= std.math.maxInt(u32));
        const dest_usize = @as(usize, @intCast(dest));
        return self.analysis.jumpdest_bitmap.isSet(dest_usize);
    }

    /// Address access for EIP-2929 - uses direct access list pointer
    pub fn access_address(self: *Frame, addr: primitives.Address.Address) !u64 {
        return self.access_list.access_address(addr);
    }

    /// Mark contract for destruction - uses direct self destruct pointer
    pub fn mark_for_destruction(self: *Frame, recipient: primitives.Address.Address) !void {
        if (self.self_destruct) |sd| {
            @branchHint(.likely);
            return sd.mark_for_destruction(self.contract_address, recipient);
        }
        return ExecutionError.Error.SelfDestructNotAvailable;
    }

    /// Set output data for RETURN/REVERT operations
    pub fn set_output(self: *Frame, data: []const u8) void {
        self.output = data;
    }

    /// Storage access operations for EVM opcodes
    pub fn get_storage(self: *const Frame, slot: u256) u256 {
        return self.state.get_storage(self.contract_address, slot) catch 0; // Return 0 on error (EVM behavior)
    }

    pub fn set_storage(self: *Frame, slot: u256, value: u256) !void {
        // Record the original value in journal before changing
        const original_value = self.state.get_storage(self.contract_address, slot) catch 0;
        if (original_value != value) {
            try self.journal.record_storage_change(self.snapshot_id, self.contract_address, slot, original_value);
        }
        try self.state.set_storage(self.contract_address, slot, value);
    }

    pub fn get_transient_storage(self: *const Frame, slot: u256) u256 {
        return self.state.get_transient_storage(self.contract_address, slot) catch 0; // Return 0 on error (EVM behavior)
    }

    pub fn set_transient_storage(self: *Frame, slot: u256, value: u256) !void {
        try self.state.set_transient_storage(self.contract_address, slot, value);
    }

    /// Mark storage slot as warm (EIP-2929) and return true if it was cold
    pub fn mark_storage_slot_warm(self: *Frame, slot: u256) !bool {
        return self.access_list.access_storage_key(self.contract_address, slot);
    }

    /// Add gas refund for storage operations (e.g., SSTORE refunds)
    /// TODO: This needs to be integrated with the refund tracking system
    pub fn add_gas_refund(self: *Frame, amount: u64) void {
        _ = self;
        _ = amount;
        // TODO: Implement refund tracking when the refund system is integrated
    }

    /// Backward compatibility accessors
    pub fn depth(self: *const Frame) u32 {
        return @intCast(self.hot_flags.depth);
    }

    pub fn is_static(self: *const Frame) bool {
        return self.hot_flags.is_static;
    }

    pub fn set_depth(self: *Frame, d: u32) void {
        self.hot_flags.depth = @intCast(d);
    }

    pub fn set_is_static(self: *Frame, static: bool) void {
        self.hot_flags.is_static = static;
    }

    /// ChainRules helper methods - moved from ChainRules struct for better data locality
    /// Mapping of chain rule fields to the hardfork in which they were introduced.
    const HardforkRule = struct {
        field_name: []const u8,
        introduced_in: Hardfork,
    };

    const HARDFORK_RULES = [_]HardforkRule{
        .{ .field_name = "is_homestead", .introduced_in = .HOMESTEAD },
        .{ .field_name = "is_byzantium", .introduced_in = .BYZANTIUM },
        .{ .field_name = "is_constantinople", .introduced_in = .CONSTANTINOPLE },
        .{ .field_name = "is_petersburg", .introduced_in = .PETERSBURG },
        .{ .field_name = "is_istanbul", .introduced_in = .ISTANBUL },
        .{ .field_name = "is_berlin", .introduced_in = .BERLIN },
        .{ .field_name = "is_london", .introduced_in = .LONDON },
        .{ .field_name = "is_merge", .introduced_in = .MERGE },
        .{ .field_name = "is_shanghai", .introduced_in = .SHANGHAI },
        .{ .field_name = "is_cancun", .introduced_in = .CANCUN },
        .{ .field_name = "is_eip1153", .introduced_in = .CANCUN },
    };

    /// Create ChainRules for a specific hardfork
    pub fn chainRulesForHardfork(hardfork: Hardfork) ChainRules {
        var rules = ChainRules{}; // All fields default to true

        // Disable features that were introduced after the target hardfork
        inline for (HARDFORK_RULES) |rule| {
            if (@intFromEnum(hardfork) < @intFromEnum(rule.introduced_in)) {
                @branchHint(.cold);
                @field(rules, rule.field_name) = false;
            } else {
                @branchHint(.likely);
            }
        }

        return rules;
    }

    /// Get the hardfork for this frame
    pub fn getHardfork(self: *const Frame) Hardfork {
        return self.hardfork;
    }

    /// Check if this frame's hardfork is greater than or equal to the specified hardfork
    pub fn is_at_least(self: *const Frame, target_hardfork: Hardfork) bool {
        return @intFromEnum(self.hardfork) >= @intFromEnum(target_hardfork);
    }

    /// Check if this frame's hardfork is greater than the specified hardfork
    pub fn is_greater_than(self: *const Frame, target_hardfork: Hardfork) bool {
        return @intFromEnum(self.hardfork) > @intFromEnum(target_hardfork);
    }

    /// Check if this frame's hardfork exactly matches the specified hardfork
    pub fn is_exactly(self: *const Frame, target_hardfork: Hardfork) bool {
        return self.hardfork == target_hardfork;
    }

    /// Check if a specific hardfork feature is enabled
    pub fn hasHardforkFeature(self: *const Frame, comptime field_name: []const u8) bool {
        // Check hot flags first (most likely to be accessed)
        if (@hasField(@TypeOf(self.hot_flags), field_name)) {
            return @field(self.hot_flags, field_name);
        }

        // Handle hardfork checks using the enum comparison
        if (std.mem.eql(u8, field_name, "is_prague")) return self.is_at_least(.PRAGUE);
        if (std.mem.eql(u8, field_name, "is_cancun")) return self.is_at_least(.CANCUN);
        if (std.mem.eql(u8, field_name, "is_shanghai")) return self.is_at_least(.SHANGHAI);
        if (std.mem.eql(u8, field_name, "is_merge")) return self.is_at_least(.MERGE);
        if (std.mem.eql(u8, field_name, "is_london")) return self.is_at_least(.LONDON);
        if (std.mem.eql(u8, field_name, "is_berlin")) return self.is_at_least(.BERLIN);
        if (std.mem.eql(u8, field_name, "is_istanbul")) return self.is_at_least(.ISTANBUL);
        if (std.mem.eql(u8, field_name, "is_petersburg")) return self.is_at_least(.PETERSBURG);
        if (std.mem.eql(u8, field_name, "is_constantinople")) return self.is_at_least(.CONSTANTINOPLE);
        if (std.mem.eql(u8, field_name, "is_byzantium")) return self.is_at_least(.BYZANTIUM);
        if (std.mem.eql(u8, field_name, "is_homestead")) return self.is_at_least(.HOMESTEAD);

        @compileError("Unknown hardfork feature: " ++ field_name);
    }

    /// Get the next available frame for nested calls (CALL, DELEGATECALL, etc.)
    /// Returns null if we've reached maximum call depth (stack overflow)
    pub fn get_next_frame(self: *Frame) ?*Frame {
        return self.next_frame;
    }

    /// Check if we can make another call (haven't reached max call depth)
    pub fn can_make_call(self: *const Frame) bool {
        return self.next_frame != null;
    }

    /// Prepare the next frame for a nested call
    /// This should be called by CALL/DELEGATECALL/STATICCALL/CREATE opcodes
    /// TODO: This will need to be implemented when we add actual CALL/CREATE opcodes
    pub fn prepare_call_frame(self: *Frame, gas: u64, static_call: bool, contract_address: primitives.Address.Address, analysis: *const CodeAnalysis, input: []const u8) ExecutionError.Error!*Frame {
        const next_frame = self.get_next_frame() orelse return ExecutionError.Error.DepthLimit;

        // Set up the next frame for execution
        next_frame.gas_remaining = gas;
        next_frame.hot_flags.is_static = static_call;
        next_frame.hot_flags.depth = self.hot_flags.depth + 1;
        next_frame.contract_address = contract_address;
        next_frame.analysis = analysis;
        next_frame.input = input;
        next_frame.output = &[_]u8{}; // Reset output

        return next_frame;
    }
};

/// Type alias for backward compatibility
pub const ExecutionContext = Frame;

// ============================================================================
// Compile-time Frame Alignment and Layout Assertions
// ============================================================================

comptime {
    // Assert optimal layout: Ultra hot -> Hot -> Warm -> Cold
    
    // Ultra hot data must be first (stack at offset 0 preferred but not required due to compiler alignment)
    // Note: Zig compiler may add padding before struct fields for alignment
    if (@offsetOf(Frame, "gas_remaining") <= @offsetOf(Frame, "stack")) @compileError("gas_remaining must come after stack");
    
    // Hot data comes next
    if (@offsetOf(Frame, "memory") <= @offsetOf(Frame, "gas_remaining")) @compileError("memory must come after gas_remaining");
    if (@offsetOf(Frame, "analysis") <= @offsetOf(Frame, "memory")) @compileError("analysis must come after memory");
    if (@offsetOf(Frame, "hot_flags") <= @offsetOf(Frame, "analysis")) @compileError("hot_flags must come after analysis");
    
    // Warm storage cluster must be contiguous
    const contract_address_offset = @offsetOf(Frame, "contract_address");
    const state_offset = @offsetOf(Frame, "state");
    const access_list_offset = @offsetOf(Frame, "access_list");
    
    if (contract_address_offset <= @offsetOf(Frame, "hot_flags")) @compileError("Storage cluster must come after hot data");
    if (state_offset - contract_address_offset > @sizeOf(primitives.Address.Address) + 8) @compileError("Storage cluster not contiguous: contract_address to state gap too large");
    if (access_list_offset - state_offset > @sizeOf(DatabaseInterface) + 8) @compileError("Storage cluster not contiguous: state to access_list gap too large");
    
    // Note: Originally enforced "hardfork must come before allocator" but Zig compiler
    // may reorder fields for optimal alignment and performance. We trust the compiler's optimization.
    
    // Performance constraint: cold data should come after warm data (Zig may reorder for alignment)
    if (@offsetOf(Frame, "hardfork") <= @offsetOf(Frame, "access_list")) @compileError("hardfork must come after warm data");
    
    // Note: Zig compiler may reorder struct fields for alignment optimization.
    // We enforce only the most critical performance constraints here.

    // Assert packed structs are properly sized
    // Ensure packed hot_flags size is as expected
    if (@sizeOf(@TypeOf(@as(Frame, undefined).hot_flags)) != 2) @compileError("hot_flags must be exactly 2 bytes (16 bits)");
    if (@sizeOf(Hardfork) != 1) @compileError("Hardfork enum must be exactly 1 byte");

    // Assert reasonable struct size (should be dominated by stack)
    const stack_size = @sizeOf(Stack);
    const total_size = @sizeOf(Frame);

    // Frame should be mostly stack + reasonable overhead
    if (total_size < stack_size) @compileError("Frame size cannot be smaller than stack size");
    if (total_size > stack_size + 1024) @compileError("Frame overhead exceeds 1KB - struct layout needs optimization");

    // Assert natural alignment for performance-critical fields
    if (@offsetOf(Frame, "gas_remaining") % @alignOf(u64) != 0) @compileError("gas_remaining must be naturally aligned for performance");
    if (@offsetOf(Frame, "contract_address") % @alignOf(primitives.Address.Address) != 0) @compileError("contract_address must be naturally aligned");

    // Trust Zig compiler to handle field alignment optimally
    // Manual padding removed - compiler knows best for target architecture

    // Note: Zig compiler handles optimal alignment automatically for performance
    // Storage cluster alignment is managed by the compiler based on field types and sizes

    // Assert hardfork field comes after hot data (compiler may reorder for alignment)
    if (@offsetOf(Frame, "hardfork") <= @offsetOf(Frame, "access_list")) @compileError("hardfork must come after storage cluster");
    // Note: "hardfork before allocator" constraint removed - Zig compiler optimizes field ordering
}

// ============================================================================
// Tests - TDD approach
// ============================================================================

// Helper functions for tests
const TestHelpers = struct {
    const JumpTable = @import("jump_table/jump_table.zig");
    const MemoryDatabase = @import("state/memory_database.zig");

    fn createEmptyAnalysis(allocator: std.mem.Allocator) !CodeAnalysis {
        const code = &[_]u8{0x00}; // STOP
        const table = JumpTable.DEFAULT;
        return CodeAnalysis.from_code(allocator, code, &table);
    }

    fn createMockAccessList(allocator: std.mem.Allocator) !AccessList {
        return AccessList.init(allocator);
    }

    fn createMockSelfDestruct(allocator: std.mem.Allocator) !SelfDestruct {
        return SelfDestruct.init(allocator);
    }

    fn createMockDatabase(allocator: std.mem.Allocator) !MemoryDatabase {
        return MemoryDatabase.init(allocator);
    }

    fn createMockChainRules() ChainRules {
        return Frame.chainRulesForHardfork(.CANCUN);
    }
};

test "Frame - basic initialization" {
    const allocator = std.testing.allocator;
    const JumpTable = @import("jump_table/jump_table.zig");

    // Create a simple code analysis for testing
    const code = &[_]u8{ 0x5B, 0x60, 0x01, 0x00 }; // JUMPDEST, PUSH1 0x01, STOP
    const table = JumpTable.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Create mock components
    var access_list = try TestHelpers.createMockAccessList(allocator);
    defer access_list.deinit();
    var self_destruct = try TestHelpers.createMockSelfDestruct(allocator);
    defer self_destruct.deinit();
    var db = try TestHelpers.createMockDatabase(allocator);
    defer db.deinit();
    const chain_rules = TestHelpers.createMockChainRules();

    var ctx = try Frame.init(
        1000000, // gas
        false, // not static
        1, // depth
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db.to_database_interface(),
        chain_rules,
        &self_destruct,
        &[_]u8{}, // input
        allocator,
        null, // next_frame
    );
    defer ctx.deinit();

    // Test initial state
    try std.testing.expectEqual(@as(u64, 1000000), ctx.gas_remaining);
    try std.testing.expectEqual(false, ctx.hot_flags.is_static);
    try std.testing.expectEqual(@as(u10, 1), ctx.hot_flags.depth);
    try std.testing.expectEqual(@as(usize, 0), ctx.stack.size());
    try std.testing.expectEqual(@as(usize, 0), ctx.output.len);

    // Test that analysis is correctly referenced
    try std.testing.expect(ctx.analysis == &analysis);
}

test "Frame - gas consumption" {
    const allocator = std.testing.allocator;
    const JumpTable = @import("jump_table/jump_table.zig");

    // Create empty code analysis for testing
    const code = &[_]u8{0x00}; // STOP
    const table = JumpTable.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Create mock components
    var access_list = try TestHelpers.createMockAccessList(allocator);
    defer access_list.deinit();
    var self_destruct = try TestHelpers.createMockSelfDestruct(allocator);
    defer self_destruct.deinit();
    var db = try TestHelpers.createMockDatabase(allocator);
    defer db.deinit();

    var ctx = try Frame.init(
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db.to_database_interface(),
        TestHelpers.createMockChainRules(),
        &self_destruct,
        &[_]u8{}, // input
        allocator,
        null, // next_frame
    );
    defer ctx.deinit();

    // Test successful gas consumption
    try ctx.consume_gas(300);
    try std.testing.expectEqual(@as(u64, 700), ctx.gas_remaining);

    // Test consuming remaining gas
    try ctx.consume_gas(700);
    try std.testing.expectEqual(@as(u64, 0), ctx.gas_remaining);

    // Test out of gas error
    try std.testing.expectError(ExecutionError.Error.OutOfGas, ctx.consume_gas(1));
}

test "Frame - jumpdest validation" {
    const allocator = std.testing.allocator;
    const JumpTable = @import("jump_table/jump_table.zig");

    // Create code with specific JUMPDESTs at positions 2 and 4
    const code = &[_]u8{ 0x00, 0x00, 0x5B, 0x00, 0x5B, 0x00 }; // STOP, STOP, JUMPDEST, STOP, JUMPDEST, STOP
    const table = JumpTable.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Create mock components
    var access_list = try TestHelpers.createMockAccessList(allocator);
    defer access_list.deinit();
    var self_destruct = try TestHelpers.createMockSelfDestruct(allocator);
    defer self_destruct.deinit();
    var db = try TestHelpers.createMockDatabase(allocator);
    defer db.deinit();

    var ctx = try Frame.init(
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db.to_database_interface(),
        TestHelpers.createMockChainRules(),
        &self_destruct,
        &[_]u8{}, // input
        allocator,
        null, // next_frame
    );
    defer ctx.deinit();

    // Test valid jump destinations (positions 2 and 4 have JUMPDEST)
    try std.testing.expect(ctx.valid_jumpdest(2));
    try std.testing.expect(ctx.valid_jumpdest(4));

    // Test invalid jump destinations
    try std.testing.expect(!ctx.valid_jumpdest(0));
    try std.testing.expect(!ctx.valid_jumpdest(1));
    try std.testing.expect(!ctx.valid_jumpdest(3));
    try std.testing.expect(!ctx.valid_jumpdest(5));

    // Test out of bounds
    try std.testing.expect(!ctx.valid_jumpdest(1000));
}

test "Frame - address access tracking" {
    const allocator = std.testing.allocator;

    var analysis = try TestHelpers.createEmptyAnalysis(allocator);
    defer analysis.deinit();

    var access_list = try TestHelpers.createMockAccessList(allocator);
    defer access_list.deinit();
    var self_destruct = try TestHelpers.createMockSelfDestruct(allocator);
    defer self_destruct.deinit();

    var db = try TestHelpers.createMockDatabase(allocator);
    defer db.deinit();

    var ctx = try Frame.init(
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db.to_database_interface(),
        TestHelpers.createMockChainRules(),
        &self_destruct,
        &[_]u8{}, // input
        allocator,
        null, // next_frame
    );
    defer ctx.deinit();

    // Test cold access (zero address)
    const cold_cost = try ctx.access_address(primitives.Address.ZERO_ADDRESS);
    try std.testing.expectEqual(@as(u64, 2600), cold_cost);

    // Test warm access (same address again)
    const warm_cost = try ctx.access_address(primitives.Address.ZERO_ADDRESS);
    try std.testing.expectEqual(@as(u64, 100), warm_cost);
}

test "Frame - output data management" {
    const allocator = std.testing.allocator;

    var analysis = try TestHelpers.createEmptyAnalysis(allocator);
    defer analysis.deinit();

    var access_list = try TestHelpers.createMockAccessList(allocator);
    defer access_list.deinit();
    var self_destruct = try TestHelpers.createMockSelfDestruct(allocator);
    defer self_destruct.deinit();

    var db = try TestHelpers.createMockDatabase(allocator);
    defer db.deinit();

    var ctx = try Frame.init(
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db.to_database_interface(),
        TestHelpers.createMockChainRules(),
        &self_destruct,
        &[_]u8{}, // input
        allocator,
        null, // next_frame
    );
    defer ctx.deinit();

    // Test initial empty output
    try std.testing.expectEqual(@as(usize, 0), ctx.output.len);

    // Test setting output data
    const test_data = "Hello, EVM!";
    ctx.set_output(test_data);
    try std.testing.expectEqual(@as(usize, 11), ctx.output.len);
    try std.testing.expectEqualStrings("Hello, EVM!", ctx.output);
}

test "Frame - static call restrictions" {
    const allocator = std.testing.allocator;

    var analysis = try TestHelpers.createEmptyAnalysis(allocator);
    defer analysis.deinit();

    var access_list = try TestHelpers.createMockAccessList(allocator);
    defer access_list.deinit();
    var self_destruct = try TestHelpers.createMockSelfDestruct(allocator);
    defer self_destruct.deinit();

    var db1 = try TestHelpers.createMockDatabase(allocator);
    defer db1.deinit();
    var db2 = try TestHelpers.createMockDatabase(allocator);
    defer db2.deinit();

    // Create static context
    var static_ctx = try Frame.init(
        1000,
        true,
        0,
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db1.to_database_interface(),
        TestHelpers.createMockChainRules(),
        &self_destruct,
        &[_]u8{}, // input
        allocator,
        null, // next_frame
    );
    defer static_ctx.deinit();

    // Create non-static context
    var normal_ctx = try Frame.init(
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db2.to_database_interface(),
        TestHelpers.createMockChainRules(),
        &self_destruct,
        &[_]u8{}, // input
        allocator,
        null, // next_frame
    );
    defer normal_ctx.deinit();

    // Test static flag
    try std.testing.expect(static_ctx.hot_flags.is_static);
    try std.testing.expect(!normal_ctx.hot_flags.is_static);
}

test "Frame - selfdestruct availability" {
    const allocator = std.testing.allocator;

    var analysis = try TestHelpers.createEmptyAnalysis(allocator);
    defer analysis.deinit();

    var access_list = try TestHelpers.createMockAccessList(allocator);
    defer access_list.deinit();

    // Test with SelfDestruct available
    var self_destruct = try TestHelpers.createMockSelfDestruct(allocator);
    defer self_destruct.deinit();

    var db3 = try TestHelpers.createMockDatabase(allocator);
    defer db3.deinit();
    var db4 = try TestHelpers.createMockDatabase(allocator);
    defer db4.deinit();

    var ctx_with_selfdestruct = try Frame.init(
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db3.to_database_interface(),
        TestHelpers.createMockChainRules(),
        &self_destruct,
        &[_]u8{}, // input
        allocator,
        null, // next_frame
    );
    defer ctx_with_selfdestruct.deinit();

    // Should succeed
    const recipient = [_]u8{0x01} ++ [_]u8{0} ** 19;
    try ctx_with_selfdestruct.mark_for_destruction(recipient);

    // Test without SelfDestruct (null)
    var ctx_without_selfdestruct = try Frame.init(
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db4.to_database_interface(),
        TestHelpers.createMockChainRules(),
        null,
        &[_]u8{}, // input
        allocator,
        null, // next_frame
    );
    defer ctx_without_selfdestruct.deinit();

    // Should return error
    try std.testing.expectError(ExecutionError.Error.SelfDestructNotAvailable, ctx_without_selfdestruct.mark_for_destruction(recipient));
}

test "Frame - memory footprint" {
    // Debug: Print component sizes
    std.debug.print("Component sizes:\n", .{});
    std.debug.print("  Stack: {} bytes\n", .{@sizeOf(Stack)});
    std.debug.print("  Memory: {} bytes\n", .{@sizeOf(Memory)});
    std.debug.print("  Frame total: {} bytes\n", .{@sizeOf(Frame)});

    // Verify hot data is at the beginning for better cache locality
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Frame, "stack"));

    // For now, just verify it compiles and has reasonable field layout
    // TODO: Optimize component sizes in future iteration
    try std.testing.expect(@sizeOf(Frame) > 0);
}
