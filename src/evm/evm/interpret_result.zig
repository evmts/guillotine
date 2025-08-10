/// Result of EVM interpret execution including state tracking components
const std = @import("std");
const RunResult = @import("run_result.zig").RunResult;
const AccessList = @import("../access_list.zig").AccessList;
const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
const ExecutionError = @import("../execution/execution_error.zig");

/// Comprehensive result from EVM interpret function
/// Contains the basic execution result plus state tracking components
pub const InterpretResult = struct {
    /// Basic execution result (status, gas, output)
    run_result: RunResult,

    /// Access list tracking warm/cold address and storage access (EIP-2929)
    /// Always present - manages gas cost optimization
    access_list: AccessList,

    /// Self destruct tracking for contracts marked for destruction
    /// Optional - only present if hardfork supports SELFDESTRUCT
    self_destruct: ?SelfDestruct,

    /// Allocator used for all components (for recursive cleanup)
    allocator: std.mem.Allocator,

    /// Initialize InterpretResult from execution parameters
    pub fn init(
        allocator: std.mem.Allocator,
        initial_gas: u64,
        gas_left: u64,
        status: RunResult.Status,
        err: ?ExecutionError.Error,
        output: ?[]const u8,
        access_list: AccessList,
        self_destruct: ?SelfDestruct,
    ) InterpretResult {
        const run_result = RunResult.init(initial_gas, gas_left, status, err, output);
        return InterpretResult{
            .run_result = run_result,
            .access_list = access_list,
            .self_destruct = self_destruct,
            .allocator = allocator,
        };
    }

    /// Recursively clean up all resources
    pub fn deinit(self: *InterpretResult) void {
        // Clean up access list
        self.access_list.deinit();

        // Clean up self destruct if present
        if (self.self_destruct) |*sd| {
            sd.deinit();
        }

        // Note: run_result.output is cleaned up by caller if needed
        // since it's allocated with the main allocator
    }

    /// Apply pending contract destructions to the state
    /// This is called at the end of transaction execution
    pub fn apply_destructions(self: *InterpretResult, state: anytype) !void {
        if (self.self_destruct) |*sd| {
            try sd.apply_destructions(state);
        }
        // If self_destruct is null, there are no destructions to apply
    }

    /// Check if any contracts are marked for destruction
    pub fn has_destructions(self: *InterpretResult) bool {
        if (self.self_destruct) |*sd| {
            return sd.count() > 0;
        }
        return false;
    }

    /// Get count of contracts marked for destruction
    pub fn destruction_count(self: *InterpretResult) u32 {
        if (self.self_destruct) |*sd| {
            return sd.count();
        }
        return 0;
    }

    /// Check if SELFDESTRUCT is available in this execution context
    pub fn has_selfdestruct_support(self: *InterpretResult) bool {
        return self.self_destruct != null;
    }
};

test "InterpretResult - initialization and cleanup" {
    const allocator = std.testing.allocator;

    // Create components
    const access_list = AccessList.init(allocator);
    const self_destruct = SelfDestruct.init(allocator);

    // Initialize result
    var result = InterpretResult.init(allocator, 1000, 500, .Success, null, null, access_list, self_destruct);
    defer result.deinit();

    // Verify initialization
    try std.testing.expectEqual(@as(u64, 500), result.run_result.gas_left);
    try std.testing.expectEqual(@as(u64, 500), result.run_result.gas_used);
    try std.testing.expect(result.has_selfdestruct_support());
    try std.testing.expectEqual(@as(u32, 0), result.destruction_count());
}

test "InterpretResult - without selfdestruct support" {
    const allocator = std.testing.allocator;

    // Create components without self destruct
    const access_list = AccessList.init(allocator);

    // Initialize result
    var result = InterpretResult.init(allocator, 1000, 500, .Success, null, null, access_list, null);
    defer result.deinit();

    // Verify no selfdestruct support
    try std.testing.expect(!result.has_selfdestruct_support());
    try std.testing.expect(!result.has_destructions());
    try std.testing.expectEqual(@as(u32, 0), result.destruction_count());
}

test "InterpretResult - destruction tracking" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    // Create components
    const access_list = AccessList.init(allocator);
    const self_destruct = SelfDestruct.init(allocator);

    // Initialize result
    var result = InterpretResult.init(allocator, 1000, 500, .Success, null, null, access_list, self_destruct);
    defer result.deinit();

    // Initially no destructions
    try std.testing.expect(!result.has_destructions());
    try std.testing.expectEqual(@as(u32, 0), result.destruction_count());

    // Mark a contract for destruction
    const contract_addr = primitives.Address.ZERO_ADDRESS;
    const recipient_addr = [_]u8{0x01} ++ [_]u8{0} ** 19;
    try result.self_destruct.?.mark_for_destruction(contract_addr, recipient_addr);

    // Should now have destructions
    try std.testing.expect(result.has_destructions());
    try std.testing.expectEqual(@as(u32, 1), result.destruction_count());
}
