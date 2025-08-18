//! EVM execution frame and chain configuration
//!
//! This module defines the execution context (Frame) for running EVM bytecode
//! and the chain rules configuration for different hardforks and EIPs.
//!
//! ## Key Components
//!
//! - **Frame**: The execution context containing stack, memory, gas, and state
//! - **ChainRules**: Configuration for hardforks and EIPs
//! - **Flags**: Optimized packed struct for runtime execution flags
//!
//! ## Design Principles
//!
//! - Data-oriented design for cache efficiency
//! - Hot fields grouped together for better locality
//! - Minimal allocations during execution
//! - Clear separation between pre-execution setup and runtime checks

const std = @import("std");
const builtin = @import("builtin");
const primitives = @import("primitives");
const Stack = @import("stack/stack.zig");
const Memory = @import("memory/memory.zig");
const ExecutionError = @import("execution/execution_error.zig");
const CodeAnalysis = @import("analysis.zig").CodeAnalysis;
const Host = @import("root.zig").Host;
const DatabaseInterface = @import("state/database_interface.zig").DatabaseInterface;

// Safety check constants - only enabled in Debug and ReleaseSafe modes
// These checks are redundant after analysis.zig validates blocks
const SAFE_GAS_CHECK = builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall;
const SAFE_JUMP_VALIDATION = builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall;

/// Error types for Frame operations
pub const AccessError = error{OutOfMemory};
pub const StateError = error{OutOfMemory};

/// Frame represents the entire execution state of the EVM as it executes opcodes
/// Layout optimized for actual opcode access patterns and cache performance
pub const Frame = struct {
    // === FIRST CACHE LINE (64 bytes) - ULTRA HOT ===
    // Every single instruction accesses these fields
    gas_remaining: u64, // 8 bytes - checked/consumed by every opcode
    stack: Stack, // 32 bytes - accessed by every opcode (4 pointers)
    analysis: *const CodeAnalysis, // 8 bytes - control flow (JUMP/JUMPI validation)
    host: Host, // 16 bytes - needed for hardfork checks, gas costs
    // === SECOND CACHE LINE - MEMORY OPERATIONS ===
    memory: Memory, // 72 bytes - MLOAD/MSTORE/MCOPY/LOG*/KECCAK256
    // === THIRD CACHE LINE - STORAGE OPERATIONS ===
    // SLOAD/SSTORE access these together
    state: DatabaseInterface, // 16 bytes
    contract_address: primitives.Address.Address, // 20 bytes
    depth: u16, // 2 bytes - for reentrancy checks
    is_static: bool, // 1 byte - for SSTORE restrictions
    // 3 bytes padding
    // === FOURTH CACHE LINE - CALL CONTEXT ===
    // Primarily used during CALL/CREATE operations
    caller: primitives.Address.Address, // 20 bytes
    value: u256, // 32 bytes
    // Per-frame I/O buffers exposed via Host
    input_buffer: []const u8 = &.{},
    output_buffer: []const u8 = &.{},

    /// Initialize a Frame with required parameters
    pub fn init(
        gas_remaining: u64,
        static_call: bool,
        call_depth: u16,
        contract_address: primitives.Address.Address,
        caller: primitives.Address.Address,
        value: u256,
        analysis: *const CodeAnalysis,
        host: Host,
        state: DatabaseInterface,
        allocator: std.mem.Allocator,
    ) !Frame {
        return Frame{
            .gas_remaining = gas_remaining,
            // MEMORY ALLOCATION: Stack for EVM execution
            // Expected size: 32KB (1024 * 32 bytes)
            // Lifetime: Per frame (freed on frame.deinit)
            // Frequency: Once per call frame
            .stack = blk: {
                const stack_val = try Stack.init(allocator);
                if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
                    // Stack should allocate exactly 32KB for data
                    std.debug.assert(stack_val.data.len == Stack.CAPACITY);
                    std.debug.assert(Stack.CAPACITY == 1024); // EVM spec
                    const stack_size = stack_val.data.len * @sizeOf(u256);
                    std.debug.assert(stack_size == 32 * 1024); // Exactly 32KB
                }
                break :blk stack_val;
            },

            // MEMORY ALLOCATION: EVM memory for MLOAD/MSTORE
            // Expected initial size: 4KB (INITIAL_CAPACITY)
            // Lifetime: Per frame (freed on frame.deinit)
            // Frequency: Once per call frame
            // Growth: Doubles on demand, gas limited
            .memory = blk: {
                const memory_val = try Memory.init_default(allocator);
                if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
                    // Memory should start with reasonable initial capacity
                    std.debug.assert(memory_val.memory_limit > 0);
                    std.debug.assert(memory_val.memory_limit == Memory.DEFAULT_MEMORY_LIMIT);
                    // Initial capacity should be 4KB
                    std.debug.assert(Memory.INITIAL_CAPACITY == 4 * 1024);
                }
                break :blk memory_val;
            },
            .analysis = analysis,
            .depth = call_depth,
            .is_static = static_call,

            // Call frame stack integration
            .host = host,
            .caller = caller,
            .value = value,
            .input_buffer = &.{},
            .output_buffer = &.{},

            // Storage cluster
            .contract_address = contract_address,
            .state = state,
        };
    }

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        self.stack.deinit(allocator);
        self.memory.deinit();
    }

    /// Gas consumption with bounds checking - used by all opcodes that consume gas
    /// In ReleaseFast/ReleaseSmall modes, the check is skipped since BEGINBLOCK already validated gas
    pub fn consume_gas(self: *Frame, amount: u64) ExecutionError.Error!void {
        if (SAFE_GAS_CHECK) {
            if (self.gas_remaining < amount) {
                @branchHint(.cold);
                return ExecutionError.Error.OutOfGas;
            }
        }
        self.gas_remaining -= amount;
    }

    /// Jump destination validation - uses cache-efficient packed array
    /// This is significantly faster than bitmap access due to better cache locality
    /// In ReleaseFast/ReleaseSmall modes, debug logging is skipped for performance
    pub fn valid_jumpdest(self: *Frame, dest: u256) bool {
        if (SAFE_JUMP_VALIDATION) {
            std.debug.assert(dest <= std.math.maxInt(u32));
        }
        const dest_usize = @as(usize, @intCast(dest));
        const is_valid = self.analysis.jumpdest_array.is_valid_jumpdest(dest_usize);
        // Add debug logging to trace jump dest validation during failures
        if (SAFE_JUMP_VALIDATION and !is_valid) {
            const in_bounds = dest_usize < self.analysis.code_len;
            const opcode: u8 = if (in_bounds) self.analysis.code[dest_usize] else 0xff;
            var nearest: isize = -1;
            if (in_bounds) {
                var offset: isize = -3;
                while (offset <= 3) : (offset += 1) {
                    if (offset == 0) continue;
                    const idx_isize: isize = @as(isize, @intCast(dest_usize)) + offset;
                    if (idx_isize >= 0 and @as(usize, @intCast(idx_isize)) < self.analysis.code_len) {
                        if (self.analysis.jumpdest_array.is_valid_jumpdest(@as(usize, @intCast(idx_isize)))) {
                            nearest = offset;
                            break;
                        }
                    }
                }
            }
            // Dump a small code window for visibility
            const window_start: usize = if (dest_usize >= 5) dest_usize - 5 else 0;
            const window_end: usize = @min(self.analysis.code_len, dest_usize + 6);
            std.debug.print("[frame.valid_jumpdest] window [{}..{}): ", .{ window_start, window_end });
            var i: usize = window_start;
            while (i < window_end) : (i += 1) {
                const b: u8 = self.analysis.code[i];
                if (i == dest_usize) {
                    std.debug.print("[>>0x{x}<<]", .{b});
                } else {
                    std.debug.print(" 0x{x}", .{b});
                }
            }
            std.debug.print("\n", .{});
            std.debug.print("[frame.valid_jumpdest] Invalid jumpdest: dest={} in_bounds={} code_len={} opcode_at_dest=0x{x} nearest_jumpdest_offset={}\n", .{ dest_usize, in_bounds, self.analysis.code_len, opcode, nearest });
        }
        return is_valid;
    }

    /// Address access for EIP-2929 - uses host interface
    pub fn access_address(self: *Frame, addr: primitives.Address.Address) ExecutionError.Error!u64 {
        return self.host.access_address(addr) catch return ExecutionError.Error.OutOfMemory;
    }

    /// Set output data for RETURN/REVERT operations - delegates to Host
    pub fn set_output(self: *Frame, data: []const u8) ExecutionError.Error!void {
        const Log = @import("log.zig");
        Log.debug("[Frame.set_output] Called with {} bytes at depth={}", .{ data.len, self.depth });
        self.host.set_output(data) catch |err| {
            Log.debug("[Frame.set_output] host.set_output failed: {}", .{err});
            return ExecutionError.Error.OutOfMemory;
        };
        Log.debug("[Frame.set_output] Successfully set output", .{});
    }

    /// Storage access operations for EVM opcodes
    pub fn get_storage(self: *const Frame, slot: u256) u256 {
        return self.state.get_storage(self.contract_address, slot) catch 0; // Return 0 on error (EVM behavior)
    }

    pub fn set_storage(self: *Frame, slot: u256, value: u256) !void {
        // Record the original value in journal before changing
        const original_value = self.state.get_storage(self.contract_address, slot) catch 0;
        if (original_value != value) {
            try self.host.record_storage_change(self.contract_address, slot, original_value);
        }
        try self.state.set_storage(self.contract_address, slot, value);
    }

    /// Get the original storage value for this slot at transaction start if recorded
    pub fn get_original_storage(self: *const Frame, slot: u256) u256 {
        if (self.host.get_original_storage(self.contract_address, slot)) |val| return val;
        return self.state.get_storage(self.contract_address, slot) catch 0;
    }

    pub fn get_transient_storage(self: *const Frame, slot: u256) u256 {
        return self.state.get_transient_storage(self.contract_address, slot) catch 0; // Return 0 on error (EVM behavior)
    }

    pub fn set_transient_storage(self: *Frame, slot: u256, value: u256) !void {
        try self.state.set_transient_storage(self.contract_address, slot, value);
    }

    /// Mark storage slot as warm (EIP-2929) and return true if it was cold
    pub fn mark_storage_slot_warm(self: *Frame, slot: u256) !bool {
        const gas_cost = try self.host.access_storage_slot(self.contract_address, slot);
        // Return true if it was cold (high gas cost)
        return gas_cost > 100;
    }

    /// Adjust gas refund for storage operations (e.g., SSTORE refunds).
    /// Forwards the refund delta (can be negative) to the EVM accumulator.
    /// The refunds will be applied at transaction end with EIP-3529 cap.
    pub fn adjust_gas_refund(self: *Frame, delta: i64) void {
        const Evm = @import("evm.zig");
        const evm = @as(*Evm, @ptrCast(@alignCast(self.host.ptr)));
        evm.adjust_gas_refund(delta);
    }

    /// Backward-compatible helper for positive refunds
    pub fn add_gas_refund(self: *Frame, amount: u64) void {
        self.adjust_gas_refund(@as(i64, @intCast(amount)));
    }

    pub fn set_depth(self: *Frame, d: u32) void {
        self.depth = d;
    }

    pub fn set_is_static(self: *Frame, static: bool) void {
        self.is_static = static;
    }
};

// ============================================================================
// Compile-time layout assertions for Frame hot/cold organization
comptime {
    // Ensure hot field ordering remains as designed for cache locality
    if (@offsetOf(Frame, "stack") <= @offsetOf(Frame, "gas_remaining")) @compileError("stack must come after gas_remaining");

    // Basic size expectations: Frame should be reasonably small (< 1024 bytes)
    if (@sizeOf(Frame) >= 1024) @compileError("Frame grew beyond expected 1KB budget");

    // Alignment sanity (should be pointer-aligned at least)
    if (@alignOf(Frame) < @alignOf(*anyopaque)) @compileError("Frame alignment must be at least pointer alignment");
}

// ============================================================================
// Tests - TDD approach
// ============================================================================

// Helper functions for tests
const TestHelpers = struct {
    const OpcodeMetadata = @import("opcode_metadata/opcode_metadata.zig");
    const MemoryDatabase = @import("state/memory_database.zig").MemoryDatabase;

    fn createEmptyAnalysis(allocator: std.mem.Allocator) !CodeAnalysis {
        const code = &[_]u8{0x00}; // STOP
        const table = OpcodeMetadata.DEFAULT;
        return CodeAnalysis.from_code(allocator, code, &table);
    }

    fn createMockDatabase(allocator: std.mem.Allocator) !MemoryDatabase {
        return MemoryDatabase.init(allocator);
    }
};

test "Frame - basic initialization" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("opcode_metadata/opcode_metadata.zig");

    // Create a simple code analysis for testing
    const code = &[_]u8{ 0x5B, 0x60, 0x01, 0x00 }; // JUMPDEST, PUSH1 0x01, STOP
    const table = OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Create mock components
    var mock_host = @import("host.zig").MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();

    var db = try TestHelpers.createMockDatabase(allocator);
    defer db.deinit();

    var ctx = try Frame.init(
        1000000, // gas
        false, // not static
        1, // depth
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS, // caller
        0, // value
        &analysis,
        host,
        db.to_database_interface(),
        allocator,
    );
    defer ctx.deinit(allocator);

    // Test initial state
    try std.testing.expectEqual(@as(u64, 1000000), ctx.gas_remaining);
    try std.testing.expectEqual(false, ctx.is_static);
    try std.testing.expectEqual(@as(u32, 1), ctx.depth);
    try std.testing.expectEqual(@as(usize, 0), ctx.stack.size());

    // Test that analysis is correctly referenced
    try std.testing.expect(ctx.analysis == &analysis);
}

test "Frame - gas consumption" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("opcode_metadata/opcode_metadata.zig");

    // Create empty code analysis for testing
    const code = &[_]u8{0x00}; // STOP
    const table = OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Create mock components
    var db = try TestHelpers.createMockDatabase(allocator);
    defer db.deinit();
    var mock_host = @import("host.zig").MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();

    var ctx = try Frame.init(
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db.to_database_interface(),
        allocator,
    );
    defer ctx.deinit(allocator);

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
    const OpcodeMetadata = @import("opcode_metadata/opcode_metadata.zig");

    // Create code with specific JUMPDESTs at positions 2 and 4
    const code = &[_]u8{ 0x00, 0x00, 0x5B, 0x00, 0x5B, 0x00 }; // STOP, STOP, JUMPDEST, STOP, JUMPDEST, STOP
    const table = OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Create mock components
    var db = try TestHelpers.createMockDatabase(allocator);
    defer db.deinit();
    var mock_host2 = @import("host.zig").MockHost.init(allocator);
    defer mock_host2.deinit();
    const host2 = mock_host2.to_host();

    var ctx = try Frame.init(
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host2,
        db.to_database_interface(),
        allocator,
    );
    defer ctx.deinit(allocator);

    // Test valid jump destinations (positions 2 and 4 have JUMPDEST)
    try std.testing.expect(ctx.valid_jumpdest(2));
    try std.testing.expect(ctx.valid_jumpdest(4));

    // Test invalid jump destinations
    try std.testing.expect(!ctx.valid_jumpdest(0));
    try std.testing.expect(!ctx.valid_jumpdest(1));
    try std.testing.expect(!ctx.valid_jumpdest(3));
    try std.testing.expect(!ctx.valid_jumpdest(5));

    // Test out of bounds - these should return false without panicking
    try std.testing.expect(!ctx.valid_jumpdest(1000));
    try std.testing.expect(!ctx.valid_jumpdest(code.len)); // Exactly at boundary
    try std.testing.expect(!ctx.valid_jumpdest(code.len + 1)); // Just past boundary
    try std.testing.expect(!ctx.valid_jumpdest(std.math.maxInt(u32))); // Maximum u32 value
}

test "Frame - address access tracking" {
    const allocator = std.testing.allocator;

    var analysis = try TestHelpers.createEmptyAnalysis(allocator);
    defer analysis.deinit();

    // Create mock host
    var mock_host = @import("host.zig").MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();

    var db = try TestHelpers.createMockDatabase(allocator);
    defer db.deinit();

    var ctx = try Frame.init(
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS, // caller
        0, // value
        &analysis,
        host,
        db.to_database_interface(),
        allocator,
    );
    defer ctx.deinit(allocator);

    // Test address access (MockHost always returns cold cost)
    const cost1 = try ctx.access_address(primitives.Address.ZERO_ADDRESS);
    try std.testing.expectEqual(@as(u64, 2600), cost1);

    // Test another access (MockHost doesn't track state, always returns cold cost)
    const cost2 = try ctx.access_address(primitives.Address.ZERO_ADDRESS);
    try std.testing.expectEqual(@as(u64, 2600), cost2);
}

test "Frame - static call restrictions" {
    const allocator = std.testing.allocator;

    var analysis = try TestHelpers.createEmptyAnalysis(allocator);
    defer analysis.deinit();

    var db1 = try TestHelpers.createMockDatabase(allocator);
    defer db1.deinit();
    var db2 = try TestHelpers.createMockDatabase(allocator);
    defer db2.deinit();
    var mock_host3 = @import("host.zig").MockHost.init(allocator);
    defer mock_host3.deinit();
    const host3 = mock_host3.to_host();

    // Create static context
    var static_ctx = try Frame.init(
        1000,
        true,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host3,
        db1.to_database_interface(),
        allocator,
    );
    defer static_ctx.deinit(allocator);

    // Create non-static context
    var normal_ctx = try Frame.init(
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host3,
        db2.to_database_interface(),
        allocator,
    );
    defer normal_ctx.deinit(allocator);

    // Test static flag
    try std.testing.expect(static_ctx.is_static);
    try std.testing.expect(!normal_ctx.is_static);
}

// Removed selfdestruct availability test since selfdestruct is now provided via Host

test "Frame - memory footprint" {
    // Debug: Print component sizes
    std.debug.print("Component sizes:\n", .{});
    std.debug.print("  Stack pointer: {} bytes\n", .{@sizeOf(*Stack)});
    std.debug.print("  Memory pointer: {} bytes\n", .{@sizeOf(*Memory)});
    std.debug.print("  Frame total: {} bytes\n", .{@sizeOf(Frame)});

    // Verify hot data is at the beginning for better cache locality
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Frame, "gas_remaining"));

    // Frame should be much smaller now with heap-allocated Stack
    try std.testing.expect(@sizeOf(Frame) < 1024);
}
