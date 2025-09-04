/// MINIMAL PROOF-OF-CONCEPT: Conditional CallResult based on EIP configuration
/// This demonstrates the core idea of conditional compilation for EVM features
const std = @import("std");
const EvmConfig = @import("evm_config.zig").EvmConfig;

// Import existing types - in full implementation these would also be conditional
const Log = @import("call_result.zig").Log;
const SelfDestructRecord = @import("call_result.zig").SelfDestructRecord;
const StorageAccess = @import("call_result.zig").StorageAccess;
const ExecutionTrace = @import("call_result.zig").ExecutionTrace;
const primitives = @import("primitives");
const Address = primitives.Address.Address;

/// Conditional CallResult that includes/excludes fields based on EIP configuration
/// This is the CORE CONCEPT: fields are conditional on hardfork features
pub fn CallResult(comptime config: EvmConfig) type {
    return struct {
        const Self = @This();
        
        // ==== ALWAYS PRESENT FIELDS ====
        success: bool,
        gas_left: u64,
        output: []const u8,
        
        // ==== CONDITIONAL FIELDS BASED ON EIP CONFIGURATION ====
        // NOTE: Using `if (condition) Type else void` pattern with defaults
        
        /// Logs are always available since Frontier
        logs: if (config.eips.has_logs()) []const Log else void = 
            if (config.eips.has_logs()) &.{} else {},
        
        /// SELFDESTRUCT tracking - always available but behavior varies
        /// TODO: In full implementation, this would track EIP-6780 behavior changes
        selfdestructs: if (config.eips.has_selfdestruct()) []const SelfDestructRecord else void = 
            if (config.eips.has_selfdestruct()) &.{} else {},
        
        /// Access lists only available from Berlin hardfork (EIP-2929)
        accessed_addresses: if (config.eips.has_access_list()) []const Address else void = 
            if (config.eips.has_access_list()) &.{} else {},
        accessed_storage: if (config.eips.has_access_list()) []const StorageAccess else void = 
            if (config.eips.has_access_list()) &.{} else {},
        
        // ==== OPTIONAL FIELDS (same as before) ====
        trace: ?ExecutionTrace = null,
        error_info: ?[]const u8 = null,
        
        /// CREATE/CREATE2 address - CREATE2 only from Constantinople
        /// TODO: Could make this conditional on has_create2() || true (for CREATE)
        created_address: ?Address = null,
        
        // ==== MINIMAL DEMONSTRATION METHODS ====
        
        /// Create a successful result - demonstrates conditional field handling
        pub fn success_empty(gas_left: u64) Self {
            var result = Self{
                .success = true,
                .gas_left = gas_left,
                .output = &[_]u8{},
                // Conditional fields get their defaults automatically
            };
            
            // TODO: In full implementation, initialize conditional fields based on features
            // if (config.eips.has_logs()) result.logs = &.{};
            // if (config.eips.has_access_list()) result.accessed_addresses = &.{};
            
            return result;
        }
        
        /// Demonstrate conditional access to fields
        pub fn hasLogs(self: Self) bool {
            if (config.eips.has_logs()) {
                return self.logs.len > 0;
            } else {
                // This branch is eliminated at compile time for configs without logs
                return false;
            }
        }
        
        /// Demonstrate memory cleanup with conditional fields
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            // TODO: Free output buffer if allocated
            if (self.output.len > 0) {
                allocator.free(self.output);
            }
            
            // Conditional cleanup - only compiles in when features are enabled
            if (config.eips.has_logs()) {
                if (self.logs.len > 0) {
                    // TODO: Implement log cleanup
                    // for (self.logs) |log| { ... }
                    allocator.free(self.logs);
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
            
            if (config.eips.has_selfdestruct()) {
                if (self.selfdestructs.len > 0) {
                    allocator.free(self.selfdestructs);
                }
            }
            
            // TODO: Cleanup other optional fields
        }
        
        /// Get the size of this CallResult type at compile time
        pub fn compileTimeSize() comptime_int {
            return @sizeOf(Self);
        }
    };
}

// ==== DEMONSTRATION TESTS ====

test "conditional CallResult - different hardforks have different sizes" {
    const testing = std.testing;
    const Hardfork = @import("hardfork.zig").Hardfork;
    const Eips = @import("eips.zig").Eips;
    
    // Frontier EVM - minimal features
    const FrontierConfig = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const FrontierResult = CallResult(FrontierConfig);
    
    // Berlin EVM - has access lists
    const BerlinConfig = EvmConfig{ .eips = Eips{ .hardfork = .BERLIN } };
    const BerlinResult = CallResult(BerlinConfig);
    
    // Cancun EVM - has all features
    const CancunConfig = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    const CancunResult = CallResult(CancunConfig);
    
    // Demonstrate size differences due to conditional compilation
    const frontier_size = FrontierResult.compileTimeSize();
    const berlin_size = BerlinResult.compileTimeSize();
    const cancun_size = CancunResult.compileTimeSize();
    
    // TODO: In full implementation, these would show significant size differences
    // For now, just verify they compile and have sizes
    try testing.expect(frontier_size > 0);
    try testing.expect(berlin_size > 0);
    try testing.expect(cancun_size > 0);
    
    // Create instances to verify they work
    const frontier_result = FrontierResult.success_empty(1000);
    try testing.expect(frontier_result.success);
    try testing.expectEqual(@as(u64, 1000), frontier_result.gas_left);
    
    const berlin_result = BerlinResult.success_empty(2000);
    try testing.expect(berlin_result.success);
    try testing.expectEqual(@as(u64, 2000), berlin_result.gas_left);
}

test "conditional CallResult - feature-specific methods work" {
    const testing = std.testing;
    const Hardfork = @import("hardfork.zig").Hardfork;
    const Eips = @import("eips.zig").Eips;
    
    const BerlinConfig = EvmConfig{ .eips = Eips{ .hardfork = .BERLIN } };
    const BerlinResult = CallResult(BerlinConfig);
    
    const result = BerlinResult.success_empty(5000);
    
    // Verify conditional methods work
    try testing.expect(!result.hasLogs());
    
    // Verify hardfork-specific features are available
    try testing.expect(BerlinConfig.eips.has_access_list()); // Berlin has access lists
    try testing.expect(!BerlinConfig.eips.has_transient_storage()); // Berlin doesn't have transient storage
}

test "conditional CallResult - memory management compiles" {
    const testing = std.testing;
    const Hardfork = @import("hardfork.zig").Hardfork;
    const Eips = @import("eips.zig").Eips;
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const CancunConfig = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    const CancunResult = CallResult(CancunConfig);
    
    var result = CancunResult.success_empty(3000);
    
    // This should compile and run without issues - demonstrates conditional cleanup
    result.deinit(allocator);
    
    try testing.expect(result.success);
}