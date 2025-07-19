const std = @import("std");
const Allocator = std.mem.Allocator;
const primitives = @import("primitives");
const evm = @import("evm");

const GasConstants = primitives.GasConstants;
const constants = evm.constants;
const gas_constants = evm.gas_constants;
const memory_limits = evm.memory_limits;

// Test cases for different memory sizes
const MEMORY_TEST_SIZES = [_]u64{
    32,        // 1 word
    64,        // 2 words
    1024,      // 32 words (1KB)
    4096,      // 128 words (4KB)
    32768,     // 1024 words (32KB)
    262144,    // 8192 words (256KB)
    1048576,   // 32768 words (1MB)
};

// Test cases for different gas amounts
const GAS_TEST_VALUES = [_]u64{
    1000,
    10000,
    100000,
    1000000,
    10000000,
};

/// Benchmark memory expansion gas calculation - linear component
pub fn memory_linear_gas_benchmark(allocator: Allocator) void {
    _ = allocator;
    
    var sum: u64 = 0;
    const iterations = 10000;
    
    for (0..iterations) |_| {
        for (MEMORY_TEST_SIZES) |size| {
            const words = GasConstants.wordCount(size);
            const linear_cost = GasConstants.MemoryGas * words;
            sum += linear_cost;
        }
    }
    
    // Prevent optimization
    std.mem.doNotOptimizeAway(sum);
}

/// Benchmark memory expansion gas calculation - quadratic component
pub fn memory_quadratic_gas_benchmark(allocator: Allocator) void {
    _ = allocator;
    
    var sum: u64 = 0;
    const iterations = 10000;
    
    for (0..iterations) |_| {
        for (MEMORY_TEST_SIZES) |size| {
            const words = GasConstants.wordCount(size);
            const quadratic_cost = (words * words) / GasConstants.QuadCoeffDiv;
            sum += quadratic_cost;
        }
    }
    
    std.mem.doNotOptimizeAway(sum);
}

/// Benchmark full memory expansion gas calculation
pub fn memory_expansion_full_gas_benchmark(allocator: Allocator) void {
    _ = allocator;
    
    var sum: u64 = 0;
    const iterations = 10000;
    
    for (0..iterations) |_| {
        for (MEMORY_TEST_SIZES) |size| {
            const cost = GasConstants.memory_gas_cost(0, size);
            sum += cost;
        }
    }
    
    std.mem.doNotOptimizeAway(sum);
}

/// Benchmark memory expansion gas calculation with overflow protection
pub fn memory_expansion_safe_gas_benchmark(allocator: Allocator) void {
    _ = allocator;
    
    var sum: u64 = 0;
    const iterations = 10000;
    
    for (0..iterations) |_| {
        for (MEMORY_TEST_SIZES) |size| {
            const cost = memory_limits.calculate_memory_gas_cost(size);
            sum += cost;
        }
    }
    
    std.mem.doNotOptimizeAway(sum);
}

/// Benchmark CALL gas calculation with value transfer
pub fn call_gas_calculation_benchmark(allocator: Allocator) void {
    _ = allocator;
    
    var sum: u64 = 0;
    const iterations = 10000;
    
    for (0..iterations) |_| {
        for (GAS_TEST_VALUES) |available_gas| {
            // Base CALL cost
            var cost = gas_constants.CALL_BASE_COST;
            
            // Value transfer cost
            const value: u256 = 1000;
            if (value > 0) {
                cost += gas_constants.CALL_VALUE_TRANSFER_COST;
                cost += gas_constants.GAS_STIPEND_VALUE_TRANSFER;
            }
            
            // New account cost (simulated)
            const account_exists = false;
            if (!account_exists and value > 0) {
                cost += gas_constants.CALL_NEW_ACCOUNT_COST;
            }
            
            // Cold account access cost
            cost += gas_constants.CALL_COLD_ACCOUNT_COST;
            
            // Calculate gas to pass to child
            const gas_left = if (available_gas > cost) available_gas - cost else 0;
            const child_gas = gas_left - (gas_left / gas_constants.CALL_GAS_RETENTION_DIVISOR);
            
            sum += cost + child_gas;
        }
    }
    
    std.mem.doNotOptimizeAway(sum);
}

/// Benchmark CREATE gas calculation
pub fn create_gas_calculation_benchmark(allocator: Allocator) void {
    _ = allocator;
    
    var sum: u64 = 0;
    const iterations = 10000;
    
    for (0..iterations) |_| {
        for ([_]u64{ 100, 1000, 5000, 24576 }) |code_size| {
            // Base CREATE cost
            var cost = gas_constants.CreateGas;
            
            // Initcode gas cost (EIP-3860)
            const initcode_words = (code_size + 31) / 32;
            cost += initcode_words * gas_constants.InitcodeWordGas;
            
            // Deployment cost (per byte of deployed code)
            const deployment_cost = code_size * constants.DEPLOY_CODE_GAS_PER_BYTE;
            cost += deployment_cost;
            
            sum += cost;
        }
    }
    
    std.mem.doNotOptimizeAway(sum);
}

/// Benchmark SSTORE gas calculation for different state transitions
pub fn sstore_gas_calculation_benchmark(allocator: Allocator) void {
    _ = allocator;
    
    var sum: u64 = 0;
    const iterations = 10000;
    
    const TestCase = struct {
        original: u256,
        current: u256,
        new: u256,
    };
    
    const test_cases = [_]TestCase{
        .{ .original = 0, .current = 0, .new = 0 },     // No-op
        .{ .original = 0, .current = 0, .new = 1 },     // Set from zero
        .{ .original = 1, .current = 1, .new = 0 },     // Clear to zero
        .{ .original = 1, .current = 1, .new = 2 },     // Modify non-zero
        .{ .original = 0, .current = 1, .new = 0 },     // Reset to original zero
        .{ .original = 1, .current = 0, .new = 1 },     // Reset to original non-zero
    };
    
    for (0..iterations) |_| {
        for (test_cases) |case| {
            var cost = gas_constants.SstoreSentryGas;
            
            if (case.current == case.new) {
                // No-op: just sentry gas
                cost = gas_constants.SstoreSentryGas;
            } else if (case.original == case.current) {
                if (case.original == 0) {
                    // Setting storage from zero
                    cost += gas_constants.SstoreSetGas;
                } else {
                    // Modifying existing storage
                    cost += gas_constants.SstoreResetGas;
                }
            } else {
                // Already modified in this transaction
                cost += gas_constants.WarmStorageReadCost;
            }
            
            sum += cost;
        }
    }
    
    std.mem.doNotOptimizeAway(sum);
}

/// Benchmark LOG gas calculation with varying topic counts
pub fn log_gas_calculation_benchmark(allocator: Allocator) void {
    _ = allocator;
    
    var sum: u64 = 0;
    const iterations = 10000;
    
    for (0..iterations) |_| {
        for (0..5) |topic_count| { // LOG0 through LOG4
            for ([_]u64{ 0, 32, 256, 1024 }) |data_size| {
                var cost = gas_constants.LogGas;
                cost += @as(u64, @intCast(topic_count)) * gas_constants.LogTopicGas;
                cost += data_size * gas_constants.LogDataGas;
                
                // Add memory expansion cost for data
                cost += GasConstants.memory_gas_cost(0, data_size);
                
                sum += cost;
            }
        }
    }
    
    std.mem.doNotOptimizeAway(sum);
}

/// Benchmark gas constants lookup performance
pub fn gas_constants_access_benchmark(allocator: Allocator) void {
    _ = allocator;
    
    var sum: u64 = 0;
    const iterations = 10000;
    
    for (0..iterations) |_| {
        // Test accessing various gas constants
        sum += gas_constants.GasFastestStep;
        sum += gas_constants.GasQuickStep;
        sum += gas_constants.GasFastStep;
        sum += gas_constants.GasMidStep;
        sum += gas_constants.GasSlowStep;
        sum += gas_constants.GasExtStep;
        
        sum += gas_constants.SloadGas;
        sum += gas_constants.SstoreSetGas;
        sum += gas_constants.CreateGas;
        sum += gas_constants.CallGas;
        
        sum += gas_constants.LogGas;
        sum += gas_constants.LogTopicGas;
        sum += gas_constants.Keccak256Gas;
        
        sum += gas_constants.MemoryGas;
        sum += gas_constants.QuadCoeffDiv;
    }
    
    std.mem.doNotOptimizeAway(sum);
}

/// Benchmark precompiled lookup table vs calculation
pub fn memory_expansion_lut_vs_calculation_benchmark(allocator: Allocator) void {
    _ = allocator;
    
    var sum_lut: u64 = 0;
    var sum_calc: u64 = 0;
    const iterations = 10000;
    
    for (0..iterations) |_| {
        // Test LUT access for small memory sizes
        for (0..gas_constants.MEMORY_EXPANSION_LUT.len) |words| {
            sum_lut += gas_constants.MEMORY_EXPANSION_LUT[words];
        }
        
        // Test calculation for same sizes
        for (0..gas_constants.MEMORY_EXPANSION_LUT.len) |words| {
            const cost = gas_constants.MemoryGas * words + (words * words) / gas_constants.QuadCoeffDiv;
            sum_calc += cost;
        }
    }
    
    std.mem.doNotOptimizeAway(sum_lut);
    std.mem.doNotOptimizeAway(sum_calc);
}

/// Benchmark SSTORE gas refund calculations
pub fn sstore_refund_calculation_benchmark(allocator: Allocator) void {
    _ = allocator;
    
    var sum: u64 = 0;
    const iterations = 10000;
    
    const RefundCase = struct {
        original: u256,
        current: u256,
        new: u256,
        expected_refund: i64,
    };
    
    const refund_cases = [_]RefundCase{
        .{ .original = 1, .current = 1, .new = 0, .expected_refund = @as(i64, @intCast(gas_constants.SstoreRefundGas)) },
        .{ .original = 0, .current = 1, .new = 0, .expected_refund = 0 },
        .{ .original = 1, .current = 0, .new = 1, .expected_refund = -@as(i64, @intCast(gas_constants.SstoreRefundGas)) },
    };
    
    for (0..iterations) |_| {
        for (refund_cases) |case| {
            var refund: i64 = 0;
            
            if (case.original != 0 and case.current != 0 and case.new == 0) {
                refund = @as(i64, @intCast(gas_constants.SstoreRefundGas));
            } else if (case.original != 0 and case.current == 0 and case.new != 0) {
                refund = -@as(i64, @intCast(gas_constants.SstoreRefundGas));
            }
            
            sum += @abs(refund);
        }
    }
    
    std.mem.doNotOptimizeAway(sum);
}

/// Benchmark SELFDESTRUCT refund calculation
pub fn selfdestruct_refund_calculation_benchmark(allocator: Allocator) void {
    _ = allocator;
    
    var sum: u64 = 0;
    const iterations = 10000;
    
    for (0..iterations) |_| {
        // Base SELFDESTRUCT cost
        var cost = gas_constants.SelfdestructGas;
        
        // Cold account access cost
        const account_cold = true;
        if (account_cold) {
            cost += gas_constants.ColdAccountAccessCost;
        }
        
        // Value transfer cost
        const has_balance = true;
        const account_exists = false;
        if (has_balance and !account_exists) {
            cost += gas_constants.CallNewAccountGas;
        }
        
        // Refund calculation (EIP-3529 limits)
        var refund = gas_constants.SelfdestructRefundGas;
        const max_refund = cost / gas_constants.MaxRefundQuotient;
        refund = @min(refund, max_refund);
        
        sum += cost + refund;
    }
    
    std.mem.doNotOptimizeAway(sum);
}