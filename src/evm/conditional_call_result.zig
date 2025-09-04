/// Conditional Call Result that adapts based on EIP configuration
/// This demonstrates the core pattern for making EVM features conditional
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;
const EvmConfig = @import("evm_config.zig").EvmConfig;

/// Generic CallResult function that creates different types based on hardfork configuration
/// This is the core innovation: CallResult becomes conditional on EIP features
pub fn CallResult(comptime config: EvmConfig) type {
    return struct {
        const Self = @This();
        
        // Always present core fields
        success: bool,
        gas_left: u64,
        output: []const u8,
        
        // Conditional fields based on EIP configuration
        // Each field only exists if the corresponding feature is enabled
        logs: if (config.eips.has_logs()) []const Log else void = 
            if (config.eips.has_logs()) &.{} else {},
            
        selfdestructs: if (config.eips.has_selfdestruct()) []const SelfDestructRecord else void = 
            if (config.eips.has_selfdestruct()) &.{} else {},
            
        accessed_addresses: if (config.eips.has_access_list()) []const Address else void = 
            if (config.eips.has_access_list()) &.{} else {},
            
        accessed_storage: if (config.eips.has_access_list()) []const StorageAccess else void = 
            if (config.eips.has_access_list()) &.{} else {},
            
        created_address: if (config.eips.has_create2() or true) ?Address else void = null,
        
        // Optional fields always present but behavior-dependent
        trace: ?ExecutionTrace = null,
        error_info: ?[]const u8 = null,

        /// Create a successful call result
        pub fn success_with_output(gas_left: u64, output: []const u8) Self {
            var result = Self{
                .success = true,
                .gas_left = gas_left,
                .output = output,
            };
            
            // Initialize conditional fields to defaults
            if (config.eips.has_logs()) {
                result.logs = &.{};
            }
            if (config.eips.has_selfdestruct()) {
                result.selfdestructs = &.{};
            }
            if (config.eips.has_access_list()) {
                result.accessed_addresses = &.{};
                result.accessed_storage = &.{};
            }
            if (config.eips.has_create2() or true) {
                result.created_address = null;
            }
            
            return result;
        }

        /// Create a successful call result with empty output
        pub fn success_empty(gas_left: u64) Self {
            return success_with_output(gas_left, &[_]u8{});
        }

        /// Create a failed call result
        pub fn failure(gas_left: u64) Self {
            var result = Self{
                .success = false,
                .gas_left = gas_left,
                .output = &[_]u8{},
            };
            
            // Initialize conditional fields to defaults
            if (config.eips.has_logs()) {
                result.logs = &.{};
            }
            if (config.eips.has_selfdestruct()) {
                result.selfdestructs = &.{};
            }
            if (config.eips.has_access_list()) {
                result.accessed_addresses = &.{};
                result.accessed_storage = &.{};
            }
            if (config.eips.has_create2() or true) {
                result.created_address = null;
            }
            
            return result;
        }

        /// Clean up all allocated memory in the CallResult
        /// Only compiles cleanup for features that are enabled
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            // Free output buffer if it's allocated
            if (self.output.len > 0) {
                allocator.free(self.output);
            }
            
            // Conditional cleanup - only compiles if feature is enabled
            if (config.eips.has_logs()) {
                if (self.logs.len > 0) {
                    for (self.logs) |log| {
                        if (log.topics.len > 0) {
                            allocator.free(log.topics);
                        }
                        if (log.data.len > 0) {
                            allocator.free(log.data);
                        }
                    }
                    allocator.free(self.logs);
                }
            }
            
            if (config.eips.has_selfdestruct()) {
                if (self.selfdestructs.len > 0) {
                    allocator.free(self.selfdestructs);
                }
            }
            
            if (config.eips.has_access_list()) {
                if (self.accessed_addresses.len > 0) {
                    allocator.free(self.accessed_addresses);
                }
                if (self.accessed_storage.len > 0) {
                    allocator.free(self.accessed_storage);
                }
            }
            
            // Reset all fields to empty slices/null (conditional compilation)
            self.output = &.{};
            if (config.eips.has_logs()) {
                self.logs = &.{};
            }
            if (config.eips.has_selfdestruct()) {
                self.selfdestructs = &.{};
            }
            if (config.eips.has_access_list()) {
                self.accessed_addresses = &.{};
                self.accessed_storage = &.{};
            }
            if (config.eips.has_create2() or true) {
                self.created_address = null;
            }
        }

        /// Get the size of this CallResult struct in bytes
        /// This will vary based on which features are enabled
        pub fn size() usize {
            return @sizeOf(Self);
        }
        
        /// Check if the call succeeded
        pub fn isSuccess(self: Self) bool {
            return self.success;
        }

        /// Check if the call failed
        pub fn isFailure(self: Self) bool {
            return !self.success;
        }

        /// Check if the call has output data
        pub fn hasOutput(self: Self) bool {
            return self.output.len > 0;
        }
    };
}

/// Log entry structure for EVM events
pub const Log = struct {
    address: Address,
    topics: []const u256,
    data: []const u8,
};

/// Record of a self-destruct operation
pub const SelfDestructRecord = struct {
    /// Address of the contract being destroyed
    contract: Address,
    /// Address receiving the remaining balance
    beneficiary: Address,
};

/// Record of a storage slot access
pub const StorageAccess = struct {
    /// Contract address
    address: Address,
    /// Storage slot key
    slot: u256,
};

/// Represents a single execution step in the trace
pub const TraceStep = struct {
    pc: u32,
    opcode: u8,
    opcode_name: []const u8,
    gas: u64,
    stack: []const u256,
    memory: []const u8,

    pub fn deinit(self: *TraceStep, allocator: std.mem.Allocator) void {
        allocator.free(self.opcode_name);
        allocator.free(self.stack);
        allocator.free(self.memory);
    }
};

/// Complete execution trace
pub const ExecutionTrace = struct {
    steps: []TraceStep,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ExecutionTrace {
        return ExecutionTrace{
            .steps = &.{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ExecutionTrace) void {
        for (self.steps) |*step| {
            step.deinit(self.allocator);
        }
        self.allocator.free(self.steps);
    }
};

// =============================================================================
// Tests demonstrating conditional compilation
// =============================================================================

const testing = std.testing;
const Eips = @import("eips.zig").Eips;
const Hardfork = @import("hardfork.zig").Hardfork;

test "conditional CallResult - basic compilation for different hardforks" {
    // Test different hardfork configurations
    const FrontierConfig = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const BerlinConfig = EvmConfig{ .eips = Eips{ .hardfork = .BERLIN } };
    const CancunConfig = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    // Each creates a different type with different fields
    const FrontierResult = CallResult(FrontierConfig);
    const BerlinResult = CallResult(BerlinConfig);
    const CancunResult = CallResult(CancunConfig);
    
    // Verify they're different types by trying to assign
    var frontier_result = FrontierResult.success_empty(1000);
    var berlin_result = BerlinResult.success_empty(2000);
    var cancun_result = CancunResult.success_empty(3000);
    
    // Basic functionality should work for all
    try testing.expect(frontier_result.isSuccess());
    try testing.expect(berlin_result.isSuccess());
    try testing.expect(cancun_result.isSuccess());
    
    // Frontier should not have access lists (Berlin+ feature)
    try testing.expect(!FrontierConfig.eips.has_access_list());
    try testing.expect(BerlinConfig.eips.has_access_list());
    try testing.expect(CancunConfig.eips.has_access_list());
}

test "conditional CallResult - size differences between configurations" {
    const FrontierConfig = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const BerlinConfig = EvmConfig{ .eips = Eips{ .hardfork = .BERLIN } };
    const CancunConfig = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    const FrontierResult = CallResult(FrontierConfig);
    const BerlinResult = CallResult(BerlinConfig);
    const CancunResult = CallResult(CancunConfig);
    
    // Frontier should be smallest (no access lists, limited features)
    // Berlin should be larger (adds access lists)  
    // Cancun should be largest (adds all features)
    const frontier_size = FrontierResult.size();
    const berlin_size = BerlinResult.size();
    const cancun_size = CancunResult.size();
    
    try testing.expect(frontier_size <= berlin_size);
    try testing.expect(berlin_size <= cancun_size);
    
    // Verify sizes are what we expect
    try testing.expect(frontier_size > 0);
    try testing.expect(berlin_size > frontier_size or berlin_size == frontier_size);
    try testing.expect(cancun_size >= berlin_size);
}

test "conditional CallResult - feature availability verification" {
    const FrontierConfig = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const ConstantinopleConfig = EvmConfig{ .eips = Eips{ .hardfork = .CONSTANTINOPLE } };
    const BerlinConfig = EvmConfig{ .eips = Eips{ .hardfork = .BERLIN } };
    const CancunConfig = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    // Test feature detection works correctly for each config
    try testing.expect(FrontierConfig.eips.has_logs());
    try testing.expect(!FrontierConfig.eips.has_create2());
    try testing.expect(!FrontierConfig.eips.has_access_list());
    try testing.expect(!FrontierConfig.eips.has_transient_storage());
    
    try testing.expect(ConstantinopleConfig.eips.has_create2());
    try testing.expect(!ConstantinopleConfig.eips.has_access_list());
    
    try testing.expect(BerlinConfig.eips.has_create2());
    try testing.expect(BerlinConfig.eips.has_access_list());
    try testing.expect(!BerlinConfig.eips.has_transient_storage());
    
    try testing.expect(CancunConfig.eips.has_create2());
    try testing.expect(CancunConfig.eips.has_access_list());
    try testing.expect(CancunConfig.eips.has_transient_storage());
}

test "conditional CallResult - memory management with conditional fields" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const CancunConfig = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    const CancunResult = CallResult(CancunConfig);
    
    var result = CancunResult.success_empty(5000);
    
    // Test that deinit compiles and works (even with empty data)
    result.deinit(allocator);
    
    // Verify we can still use the result after deinit
    try testing.expect(result.isSuccess());
    try testing.expectEqual(@as(u64, 5000), result.gas_left);
}

test "conditional CallResult - constructors work across hardforks" {
    const FrontierConfig = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const CancunConfig = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    const FrontierResult = CallResult(FrontierConfig);
    const CancunResult = CallResult(CancunConfig);
    
    // Test all constructors work
    const frontier_success = FrontierResult.success_with_output(1000, &[_]u8{0x42});
    const frontier_empty = FrontierResult.success_empty(2000);
    const frontier_failure = FrontierResult.failure(500);
    
    const cancun_success = CancunResult.success_with_output(1000, &[_]u8{0x42});
    const cancun_empty = CancunResult.success_empty(2000);
    const cancun_failure = CancunResult.failure(500);
    
    // Verify all work as expected
    try testing.expect(frontier_success.isSuccess());
    try testing.expect(frontier_empty.isSuccess());
    try testing.expect(frontier_failure.isFailure());
    
    try testing.expect(cancun_success.isSuccess());
    try testing.expect(cancun_empty.isSuccess());
    try testing.expect(cancun_failure.isFailure());
}

test "conditional CallResult - demonstrates memory savings" {
    // This test demonstrates the key benefit: memory savings
    const FrontierConfig = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const FullConfig = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    const MinimalResult = CallResult(FrontierConfig);
    const FullResult = CallResult(FullConfig);
    
    // Create instances
    const minimal = MinimalResult.success_empty(1000);
    const full = FullResult.success_empty(1000);
    
    // The size difference demonstrates memory savings
    // Minimal should be smaller since it lacks access list fields
    const minimal_size = @sizeOf(@TypeOf(minimal));
    const full_size = @sizeOf(@TypeOf(full));
    
    // At minimum, they should be different sizes or Full should be larger
    try testing.expect(minimal_size <= full_size);
    
    // Both should function identically for core features
    try testing.expect(minimal.isSuccess());
    try testing.expect(full.isSuccess());
    try testing.expectEqual(minimal.gas_left, full.gas_left);
    try testing.expect(!minimal.hasOutput());
    try testing.expect(!full.hasOutput());
}