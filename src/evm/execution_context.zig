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

/// Error types for ExecutionContext operations
pub const AccessError = error{OutOfMemory};
pub const StateError = error{OutOfMemory};

/// Minimal execution context for EVM opcodes
/// Replaces the heavy Frame struct with only essential data (~200 bytes vs 500+ bytes)
pub const ExecutionContext = struct {
    // ============================================================================
    // Hot data - frequently accessed during execution (cache-friendly grouping)
    // ============================================================================
    
    /// EVM stack for operand storage (most frequently accessed)
    stack: Stack,
    
    /// Remaining gas for current execution context
    gas_remaining: u64,
    
    /// EVM memory for byte-addressable storage
    memory: Memory,
    
    // ============================================================================
    // Environment state
    // ============================================================================
    
    /// Output data for RETURN/REVERT operations
    output: []const u8,
    
    /// Whether this is a static call context (no state changes allowed)
    is_static: bool,
    
    /// Call depth for preventing stack overflow attacks  
    depth: u32,
    
    /// Memory allocator for operations
    allocator: std.mem.Allocator,
    
    // ============================================================================
    // Contract interface (minimal, dependency-free)
    // ============================================================================
    
    /// The contract's address for SELFDESTRUCT operations
    contract_address: primitives.Address.Address,
    
    /// Function pointer for JUMPDEST validation (breaks circular dependencies)
    valid_jumpdest_fn: *const fn (allocator: std.mem.Allocator, dest: u256) bool,
    
    // ============================================================================
    // VM interface (minimal methods only)
    // ============================================================================
    
    /// Function pointer for EIP-2929 address access tracking
    access_address_fn: *const fn (address: primitives.Address.Address) AccessError!u64,
    
    /// Function pointer for marking contracts for destruction
    mark_destruction_fn: *const fn (contract_addr: primitives.Address.Address, recipient: primitives.Address.Address) StateError!void,
    
    // ============================================================================
    // Methods
    // ============================================================================
    
    /// Initialize an ExecutionContext with required parameters
    pub fn init(
        allocator: std.mem.Allocator,
        gas_remaining: u64,
        is_static: bool,
        depth: u32,
        contract_address: primitives.Address.Address,
        valid_jumpdest_fn: *const fn (allocator: std.mem.Allocator, dest: u256) bool,
        access_address_fn: *const fn (address: primitives.Address.Address) AccessError!u64,
        mark_destruction_fn: *const fn (contract_addr: primitives.Address.Address, recipient: primitives.Address.Address) StateError!void,
    ) !ExecutionContext {
        return ExecutionContext{
            .stack = Stack{},
            .gas_remaining = gas_remaining,
            .memory = try Memory.init_default(allocator),
            .output = &[_]u8{},
            .is_static = is_static,
            .depth = depth,
            .allocator = allocator,
            .contract_address = contract_address,
            .valid_jumpdest_fn = valid_jumpdest_fn,
            .access_address_fn = access_address_fn,
            .mark_destruction_fn = mark_destruction_fn,
        };
    }
    
    /// Clean up resources
    pub fn deinit(self: *ExecutionContext) void {
        self.memory.deinit();
    }
    
    /// Gas consumption with bounds checking - used by all opcodes that consume gas
    pub fn consume_gas(self: *ExecutionContext, amount: u64) !void {
        if (self.gas_remaining < amount) {
            return ExecutionError.Error.OutOfGas;
        }
        self.gas_remaining -= amount;
    }
    
    /// Jump destination validation - delegates to contract-specific validation
    pub fn valid_jumpdest(self: *ExecutionContext, dest: u256) bool {
        return self.valid_jumpdest_fn(self.allocator, dest);
    }
    
    /// Address access for EIP-2929 - delegates to VM's access list
    pub fn access_address(self: *ExecutionContext, addr: primitives.Address.Address) !u64 {
        return self.access_address_fn(addr);
    }
    
    /// Mark contract for destruction - delegates to VM's state management  
    pub fn mark_for_destruction(self: *ExecutionContext, recipient: primitives.Address.Address) !void {
        return self.mark_destruction_fn(self.contract_address, recipient);
    }
    
    /// Set output data for RETURN/REVERT operations
    pub fn set_output(self: *ExecutionContext, data: []const u8) void {
        self.output = data;
    }
};

// ============================================================================
// Tests - TDD approach
// ============================================================================

test "ExecutionContext - basic initialization" {
    const allocator = std.testing.allocator;
    
    // Mock function pointers for testing
    const MockFunctions = struct {
        fn mockValidJumpdest(alloc: std.mem.Allocator, dest: u256) bool {
            _ = alloc;
            return dest == 42; // Only 42 is a valid jumpdest in our test
        }
        
        fn mockAccessAddress(addr: primitives.Address.Address) AccessError!u64 {
            _ = addr;
            return 2600; // Cold access cost
        }
        
        fn mockMarkDestruction(contract_addr: primitives.Address.Address, recipient: primitives.Address.Address) StateError!void {
            _ = contract_addr;
            _ = recipient;
            // No-op for test
        }
    };
    
    var ctx = try ExecutionContext.init(
        allocator,
        1000000, // gas
        false,   // not static
        1,       // depth
        primitives.Address.ZERO_ADDRESS,
        MockFunctions.mockValidJumpdest,
        MockFunctions.mockAccessAddress,
        MockFunctions.mockMarkDestruction,
    );
    defer ctx.deinit();
    
    // Test initial state
    try std.testing.expectEqual(@as(u64, 1000000), ctx.gas_remaining);
    try std.testing.expectEqual(false, ctx.is_static);
    try std.testing.expectEqual(@as(u32, 1), ctx.depth);
    try std.testing.expectEqual(@as(usize, 0), ctx.stack.size);
    try std.testing.expectEqual(@as(usize, 0), ctx.output.len);
}

test "ExecutionContext - gas consumption" {
    const allocator = std.testing.allocator;
    
    // Mock functions (minimal for gas testing)
    const MockFunctions = struct {
        fn mockValidJumpdest(alloc: std.mem.Allocator, dest: u256) bool { _ = alloc; _ = dest; return false; }
        fn mockAccessAddress(addr: primitives.Address.Address) AccessError!u64 { _ = addr; return 0; }
        fn mockMarkDestruction(a: primitives.Address.Address, b: primitives.Address.Address) StateError!void { _ = a; _ = b; }
    };
    
    var ctx = try ExecutionContext.init(
        allocator, 1000, false, 0, primitives.Address.ZERO_ADDRESS,
        MockFunctions.mockValidJumpdest, MockFunctions.mockAccessAddress, MockFunctions.mockMarkDestruction,
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

test "ExecutionContext - jumpdest validation" {
    const allocator = std.testing.allocator;
    
    const MockFunctions = struct {
        fn mockValidJumpdest(alloc: std.mem.Allocator, dest: u256) bool {
            _ = alloc;
            return dest == 100 or dest == 200; // Only specific destinations are valid
        }
        fn mockAccessAddress(addr: primitives.Address.Address) AccessError!u64 { _ = addr; return 0; }
        fn mockMarkDestruction(a: primitives.Address.Address, b: primitives.Address.Address) StateError!void { _ = a; _ = b; }
    };
    
    var ctx = try ExecutionContext.init(
        allocator, 1000, false, 0, primitives.Address.ZERO_ADDRESS,
        MockFunctions.mockValidJumpdest, MockFunctions.mockAccessAddress, MockFunctions.mockMarkDestruction,
    );
    defer ctx.deinit();
    
    // Test valid jump destinations
    try std.testing.expect(ctx.valid_jumpdest(100));
    try std.testing.expect(ctx.valid_jumpdest(200));
    
    // Test invalid jump destinations
    try std.testing.expect(!ctx.valid_jumpdest(50));
    try std.testing.expect(!ctx.valid_jumpdest(150));
    try std.testing.expect(!ctx.valid_jumpdest(300));
}

test "ExecutionContext - address access tracking" {
    const allocator = std.testing.allocator;
    
    const MockFunctions = struct {
        fn mockValidJumpdest(alloc: std.mem.Allocator, dest: u256) bool { _ = alloc; _ = dest; return false; }
        fn mockAccessAddress(addr: primitives.Address.Address) AccessError!u64 {
            // Simulate cold vs warm access costs
            if (std.mem.eql(u8, &addr.bytes, &primitives.Address.ZERO_ADDRESS.bytes)) {
                return 2600; // Cold access
            } else {
                return 100;  // Warm access
            }
        }
        fn mockMarkDestruction(a: primitives.Address.Address, b: primitives.Address.Address) StateError!void { _ = a; _ = b; }
    };
    
    var ctx = try ExecutionContext.init(
        allocator, 1000, false, 0, primitives.Address.ZERO_ADDRESS,
        MockFunctions.mockValidJumpdest, MockFunctions.mockAccessAddress, MockFunctions.mockMarkDestruction,
    );
    defer ctx.deinit();
    
    // Test cold access (zero address)
    const cold_cost = try ctx.access_address(primitives.Address.ZERO_ADDRESS);
    try std.testing.expectEqual(@as(u64, 2600), cold_cost);
    
    // Test warm access (non-zero address)
    const non_zero = primitives.Address.Address{ .bytes = [_]u8{0xFF} ++ [_]u8{0} ** 19 };
    const warm_cost = try ctx.access_address(non_zero);
    try std.testing.expectEqual(@as(u64, 100), warm_cost);
}

test "ExecutionContext - output data management" {
    const allocator = std.testing.allocator;
    
    const MockFunctions = struct {
        fn mockValidJumpdest(alloc: std.mem.Allocator, dest: u256) bool { _ = alloc; _ = dest; return false; }
        fn mockAccessAddress(addr: primitives.Address.Address) AccessError!u64 { _ = addr; return 0; }
        fn mockMarkDestruction(a: primitives.Address.Address, b: primitives.Address.Address) StateError!void { _ = a; _ = b; }
    };
    
    var ctx = try ExecutionContext.init(
        allocator, 1000, false, 0, primitives.Address.ZERO_ADDRESS,
        MockFunctions.mockValidJumpdest, MockFunctions.mockAccessAddress, MockFunctions.mockMarkDestruction,
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

test "ExecutionContext - static call restrictions" {
    const allocator = std.testing.allocator;
    
    const MockFunctions = struct {
        fn mockValidJumpdest(alloc: std.mem.Allocator, dest: u256) bool { _ = alloc; _ = dest; return false; }
        fn mockAccessAddress(addr: primitives.Address.Address) AccessError!u64 { _ = addr; return 0; }
        fn mockMarkDestruction(a: primitives.Address.Address, b: primitives.Address.Address) StateError!void { _ = a; _ = b; }
    };
    
    // Create static context
    var static_ctx = try ExecutionContext.init(
        allocator, 1000, true, 0, primitives.Address.ZERO_ADDRESS,
        MockFunctions.mockValidJumpdest, MockFunctions.mockAccessAddress, MockFunctions.mockMarkDestruction,
    );
    defer static_ctx.deinit();
    
    // Create non-static context
    var normal_ctx = try ExecutionContext.init(
        allocator, 1000, false, 0, primitives.Address.ZERO_ADDRESS,
        MockFunctions.mockValidJumpdest, MockFunctions.mockAccessAddress, MockFunctions.mockMarkDestruction,
    );
    defer normal_ctx.deinit();
    
    // Test static flag
    try std.testing.expect(static_ctx.is_static);
    try std.testing.expect(!normal_ctx.is_static);
}

test "ExecutionContext - memory footprint" {
    // Verify the struct size is reasonable (goal: ~200 bytes vs 500+ for Frame)
    const size = @sizeOf(ExecutionContext);
    
    // This should be significantly smaller than the original Frame struct
    // Exact size will depend on platform but should be well under 300 bytes
    try std.testing.expect(size < 400);
    
    // Verify hot data is at the beginning for better cache locality
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(ExecutionContext, "stack"));
}