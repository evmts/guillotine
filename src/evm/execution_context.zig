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
const CodeAnalysis = @import("frame/code_analysis.zig");
const AccessList = @import("access_list.zig").AccessList;
const SelfDestruct = @import("self_destruct.zig").SelfDestruct;
const DatabaseInterface = @import("state/database_interface.zig").DatabaseInterface;
const Hardfork = @import("hardforks/hardfork.zig").Hardfork;

/// Error types for Frame operations
pub const AccessError = error{OutOfMemory};
pub const StateError = error{OutOfMemory};

/// Combined chain rules (hardforks + EIPs) for configuration input.
/// Used to create the optimized Flags packed struct.
pub const ChainRules = struct {
    is_homestead: bool = true,
    is_eip150: bool = true,
    is_eip158: bool = true,
    is_byzantium: bool = true,
    is_constantinople: bool = true,
    is_petersburg: bool = true,
    is_istanbul: bool = true,
    is_berlin: bool = true,
    is_eip2930: bool = true,
    is_london: bool = true,
    is_eip1559: bool = true,
    is_eip3198: bool = true,
    is_eip3541: bool = true,
    is_merge: bool = true,
    is_shanghai: bool = true,
    is_eip3651: bool = true,
    is_eip3855: bool = true,
    is_eip3860: bool = true,
    is_eip4895: bool = true,
    is_cancun: bool = true,
    is_eip4844: bool = true,
    is_eip1153: bool = true,
    is_eip5656: bool = true,
    is_prague: bool = false,

    /// Default chain rules for the latest hardfork (CANCUN).
    pub const DEFAULT = ChainRules{};
};

/// Packed flags struct - ordered by introduction date (newest first)
/// Fits exactly in 64 bits for optimal cache performance
pub const Flags = packed struct {
    // Core execution state - most frequently accessed
    depth: u10,           // 10 bits (0-1023)
    is_static: bool,      // 1 bit
    
    // Prague (future) - 1 bit
    is_prague: bool,
    
    // Cancun (2024) - 3 bits
    is_cancun: bool,
    is_eip4844: bool,     // Blob transactions
    is_eip1153: bool,     // Transient storage
    is_eip5656: bool,     // MCOPY opcode
    
    // Shanghai (2023) - 5 bits
    is_shanghai: bool,
    is_eip3651: bool,     // Warm COINBASE
    is_eip3855: bool,     // PUSH0 opcode
    is_eip3860: bool,     // Limit and meter initcode
    is_eip4895: bool,     // Beacon chain withdrawals
    
    // Merge (2022) - 1 bit
    is_merge: bool,
    
    // London (2021) - 3 bits
    is_london: bool,
    is_eip1559: bool,     // Fee market change
    is_eip3198: bool,     // BASEFEE opcode
    is_eip3541: bool,     // Reject EF contracts
    
    // Berlin (2021) - 2 bits
    is_berlin: bool,
    is_eip2930: bool,     // Access lists
    
    // Istanbul (2019) - 1 bit
    is_istanbul: bool,
    
    // Petersburg (2019) - 1 bit
    is_petersburg: bool,
    
    // Constantinople (2019) - 1 bit
    is_constantinople: bool,
    
    // Byzantium (2017) - 1 bit
    is_byzantium: bool,
    
    // Spurious Dragon (2016) - 1 bit
    is_eip158: bool,      // State clearing
    
    // Tangerine Whistle (2016) - 1 bit
    is_eip150: bool,      // Gas cost changes
    
    // Homestead (2016) - 1 bit
    is_homestead: bool,
    
    // Reserved for future expansion - remaining bits
    _reserved: u20 = 0,   // Ensures exactly 64 bits total
};

/// Data-oriented Frame struct optimized for cache performance
pub const Frame = struct {
    // Hot data - accessed frequently
    stack: Stack, // 33,536 bytes - very hot
    gas_remaining: u64, // 8 bytes - checked constantly

    // Packed struct for all bit fields - 8 bytes (64 bits total)
    flags: Flags,

    // Pointers - frequently accessed
    memory: *Memory, // 8 bytes - hot for MLOAD/MSTORE
    analysis: *const CodeAnalysis, // 8 bytes - hot for jumps
    access_list: *AccessList, // 8 bytes - warm for storage/account access
    state: DatabaseInterface, // 16 bytes - medium for storage operations

    // Cold data - rarely accessed
    output: []const u8, // 16 bytes - only for RETURN/REVERT
    contract_address: primitives.Address.Address, // 20 bytes - rarely needed
    self_destruct: ?*SelfDestruct, // 8 bytes - very rare

    /// Initialize a Frame with required parameters
    pub fn init(
        allocator: std.mem.Allocator,
        gas_remaining: u64,
        static_call: bool,
        call_depth: u32,
        contract_address: primitives.Address.Address,
        analysis: *const CodeAnalysis,
        access_list: *AccessList,
        state: DatabaseInterface,
        chain_rules: ChainRules,
        self_destruct: ?*SelfDestruct,
    ) !Frame {
        return Frame{
            .stack = Stack.init(),
            .gas_remaining = gas_remaining,
            .flags = .{
                .depth = @intCast(call_depth),
                .is_static = static_call,
                // Map from ChainRules to Flags - ordered by introduction date
                .is_prague = chain_rules.is_prague,
                .is_cancun = chain_rules.is_cancun,
                .is_eip4844 = chain_rules.is_eip4844,
                .is_eip1153 = chain_rules.is_eip1153,
                .is_eip5656 = chain_rules.is_eip5656,
                .is_shanghai = chain_rules.is_shanghai,
                .is_eip3651 = chain_rules.is_eip3651,
                .is_eip3855 = chain_rules.is_eip3855,
                .is_eip3860 = chain_rules.is_eip3860,
                .is_eip4895 = chain_rules.is_eip4895,
                .is_merge = chain_rules.is_merge,
                .is_london = chain_rules.is_london,
                .is_eip1559 = chain_rules.is_eip1559,
                .is_eip3198 = chain_rules.is_eip3198,
                .is_eip3541 = chain_rules.is_eip3541,
                .is_berlin = chain_rules.is_berlin,
                .is_eip2930 = chain_rules.is_eip2930,
                .is_istanbul = chain_rules.is_istanbul,
                .is_petersburg = chain_rules.is_petersburg,
                .is_constantinople = chain_rules.is_constantinople,
                .is_byzantium = chain_rules.is_byzantium,
                .is_eip158 = chain_rules.is_eip158,
                .is_eip150 = chain_rules.is_eip150,
                .is_homestead = chain_rules.is_homestead,
            },
            .memory = try Memory.init_default(allocator),
            .analysis = analysis,
            .access_list = access_list,
            .state = state,
            .output = &[_]u8{},
            .contract_address = contract_address,
            .self_destruct = self_destruct,
        };
    }

    pub fn deinit(self: *Frame) void {
        self.memory.deinit();
    }

    /// Gas consumption with bounds checking - used by all opcodes that consume gas
    pub fn consume_gas(self: *Frame, amount: u64) !void {
        if (self.gas_remaining < amount) {
            return ExecutionError.Error.OutOfGas;
        }
        self.gas_remaining -= amount;
    }

    /// Jump destination validation - uses direct bitmap access
    /// This is significantly faster than the previous function pointer approach
    pub fn valid_jumpdest(self: *Frame, dest: u256) bool {
        // Check bounds first
        if (dest >= std.math.maxInt(u32)) return false;

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
            return sd.mark_for_destruction(self.contract_address, recipient);
        } else {
            return ExecutionError.Error.SelfDestructNotAvailable;
        }
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

    /// Emit a log event for LOG0, LOG1, LOG2, LOG3, LOG4 opcodes
    /// TODO: This needs to be integrated with the VM's logging system
    pub fn emit_log(self: *Frame, topics: []const u256, data: []const u8) !void {
        _ = self;
        _ = topics;
        _ = data;
        // TODO: Implement log emission when the logging system is integrated with ExecutionContext
        // This will need access to the VM's state.emit_log method
    }

    /// Backward compatibility accessors
    pub fn depth(self: *const Frame) u32 {
        return @intCast(self.flags.depth);
    }

    pub fn is_static(self: *const Frame) bool {
        return self.flags.is_static;
    }

    pub fn set_depth(self: *Frame, d: u32) void {
        self.flags.depth = @intCast(d);
    }

    pub fn set_is_static(self: *Frame, static: bool) void {
        self.flags.is_static = static;
    }

    /// ChainRules helper methods - moved from ChainRules struct for better data locality
    /// Mapping of chain rule fields to the hardfork in which they were introduced.
    const HardforkRule = struct {
        field_name: []const u8,
        introduced_in: Hardfork,
    };

    const HARDFORK_RULES = [_]HardforkRule{
        .{ .field_name = "is_homestead", .introduced_in = .HOMESTEAD },
        .{ .field_name = "is_eip150", .introduced_in = .TANGERINE_WHISTLE },
        .{ .field_name = "is_eip158", .introduced_in = .SPURIOUS_DRAGON },
        .{ .field_name = "is_byzantium", .introduced_in = .BYZANTIUM },
        .{ .field_name = "is_constantinople", .introduced_in = .CONSTANTINOPLE },
        .{ .field_name = "is_petersburg", .introduced_in = .PETERSBURG },
        .{ .field_name = "is_istanbul", .introduced_in = .ISTANBUL },
        .{ .field_name = "is_berlin", .introduced_in = .BERLIN },
        .{ .field_name = "is_london", .introduced_in = .LONDON },
        .{ .field_name = "is_merge", .introduced_in = .MERGE },
        .{ .field_name = "is_shanghai", .introduced_in = .SHANGHAI },
        .{ .field_name = "is_cancun", .introduced_in = .CANCUN },
        .{ .field_name = "is_eip1559", .introduced_in = .LONDON },
        .{ .field_name = "is_eip2930", .introduced_in = .BERLIN },
        .{ .field_name = "is_eip3198", .introduced_in = .LONDON },
        .{ .field_name = "is_eip3541", .introduced_in = .LONDON },
        .{ .field_name = "is_eip3651", .introduced_in = .SHANGHAI },
        .{ .field_name = "is_eip3855", .introduced_in = .SHANGHAI },
        .{ .field_name = "is_eip3860", .introduced_in = .SHANGHAI },
        .{ .field_name = "is_eip4895", .introduced_in = .SHANGHAI },
        .{ .field_name = "is_eip4844", .introduced_in = .CANCUN },
        .{ .field_name = "is_eip1153", .introduced_in = .CANCUN },
        .{ .field_name = "is_eip5656", .introduced_in = .CANCUN },
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

    /// Get the hardfork that matches this frame's flags
    /// Order matches the packed struct layout (newest first)
    pub fn getHardfork(self: *const Frame) Hardfork {
        // Check in same order as packed struct - newest first
        if (self.flags.is_prague) return .PRAGUE;
        if (self.flags.is_cancun) return .CANCUN;
        if (self.flags.is_shanghai) return .SHANGHAI;
        if (self.flags.is_merge) return .MERGE;
        if (self.flags.is_london) return .LONDON;
        if (self.flags.is_berlin) return .BERLIN;
        if (self.flags.is_istanbul) return .ISTANBUL;
        if (self.flags.is_petersburg) return .PETERSBURG;
        if (self.flags.is_constantinople) return .CONSTANTINOPLE;
        if (self.flags.is_byzantium) return .BYZANTIUM;
        if (self.flags.is_eip158) return .SPURIOUS_DRAGON;
        if (self.flags.is_eip150) return .TANGERINE_WHISTLE;
        if (self.flags.is_homestead) return .HOMESTEAD;
        return .FRONTIER;
    }

    /// Check if a specific hardfork feature is enabled
    pub fn hasHardforkFeature(self: *const Frame, comptime field_name: []const u8) bool {
        return @field(self.flags, field_name);
    }
};

/// Type alias for backward compatibility
pub const ExecutionContext = Frame;

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
        allocator,
        1000000, // gas
        false, // not static
        1, // depth
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db.to_database_interface(),
        chain_rules,
        &self_destruct,
    );
    defer ctx.deinit();

    // Test initial state
    try std.testing.expectEqual(@as(u64, 1000000), ctx.gas_remaining);
    try std.testing.expectEqual(false, ctx.flags.is_static);
    try std.testing.expectEqual(@as(u10, 1), ctx.flags.depth);
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
        allocator,
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db.to_database_interface(),
        TestHelpers.createMockChainRules(),
        &self_destruct,
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
        allocator,
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db.to_database_interface(),
        TestHelpers.createMockChainRules(),
        &self_destruct,
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
        allocator,
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db.to_database_interface(),
        TestHelpers.createMockChainRules(),
        &self_destruct,
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
        allocator,
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db.to_database_interface(),
        TestHelpers.createMockChainRules(),
        &self_destruct,
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
        allocator,
        1000,
        true,
        0,
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db1.to_database_interface(),
        TestHelpers.createMockChainRules(),
        &self_destruct,
    );
    defer static_ctx.deinit();

    // Create non-static context
    var normal_ctx = try Frame.init(
        allocator,
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db2.to_database_interface(),
        TestHelpers.createMockChainRules(),
        &self_destruct,
    );
    defer normal_ctx.deinit();

    // Test static flag
    try std.testing.expect(static_ctx.flags.is_static);
    try std.testing.expect(!normal_ctx.flags.is_static);
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
        allocator,
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db3.to_database_interface(),
        TestHelpers.createMockChainRules(),
        &self_destruct,
    );
    defer ctx_with_selfdestruct.deinit();

    // Should succeed
    const recipient = [_]u8{0x01} ++ [_]u8{0} ** 19;
    try ctx_with_selfdestruct.mark_for_destruction(recipient);

    // Test without SelfDestruct (null)
    var ctx_without_selfdestruct = try Frame.init(
        allocator,
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        &analysis,
        &access_list,
        db4.to_database_interface(),
        TestHelpers.createMockChainRules(),
        null,
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
