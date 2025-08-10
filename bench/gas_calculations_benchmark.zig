const std = @import("std");
const Allocator = std.mem.Allocator;
const primitives = @import("primitives");
const evm = @import("evm");
const timing = @import("timing.zig");

const GasConstants = primitives.GasConstants;
const constants = evm.constants;
const gas_constants = evm.gas_constants;
const memory_limits = evm.memory_limits;
const Hardfork = evm.hardforks.Hardfork;

// Helper function to calculate word count
fn wordCount(size: u64) u64 {
    return (size + 31) / 32;
}

// Test cases for different memory sizes
const MEMORY_TEST_SIZES = [_]u64{
    32, // 1 word
    64, // 2 words
    1024, // 32 words (1KB)
    4096, // 128 words (4KB)
    32768, // 1024 words (32KB)
    262144, // 8192 words (256KB)
    1048576, // 32768 words (1MB)
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
            const words = wordCount(size);
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
            const words = wordCount(size);
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
            const deployment_cost = code_size * constants.constants.DEPLOY_CODE_GAS_PER_BYTE;
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
        .{ .original = 0, .current = 0, .new = 0 }, // No-op
        .{ .original = 0, .current = 0, .new = 1 }, // Set from zero
        .{ .original = 1, .current = 1, .new = 0 }, // Clear to zero
        .{ .original = 1, .current = 1, .new = 2 }, // Modify non-zero
        .{ .original = 0, .current = 1, .new = 0 }, // Reset to original zero
        .{ .original = 1, .current = 0, .new = 1 }, // Reset to original non-zero
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

/// Benchmark LOG gas calculation with varying topic counts (original)
pub fn log_gas_calculation_basic_benchmark(allocator: Allocator) void {
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

/// Benchmark dynamic calculation vs direct constant access
pub fn dynamic_vs_constant_gas_benchmark(allocator: Allocator) void {
    _ = allocator;

    var sum_dynamic: u64 = 0;
    var sum_constant: u64 = 0;
    const iterations = 10000;

    // Test different opcode categories
    const opcodes = [_]u8{ constants.constants.ADD, constants.constants.MUL, constants.constants.SLOAD, constants.constants.CALL };

    for (0..iterations) |_| {
        // Dynamic gas lookup (simulation)
        for (opcodes) |opcode| {
            const gas_cost = switch (opcode) {
                constants.constants.ADD => GasConstants.GasFastestStep,
                constants.constants.MUL => GasConstants.GasFastStep,
                constants.constants.SLOAD => GasConstants.SloadGas,
                constants.constants.CALL => GasConstants.CallGas,
                else => GasConstants.GasQuickStep,
            };
            sum_dynamic += gas_cost;
        }

        // Direct constant access
        for (opcodes) |_| {
            sum_constant += GasConstants.GasFastestStep; // Simulated constant access
            sum_constant += GasConstants.GasFastStep;
            sum_constant += GasConstants.SloadGas;
            sum_constant += GasConstants.CallGas;
        }
    }

    std.mem.doNotOptimizeAway(sum_dynamic);
    std.mem.doNotOptimizeAway(sum_constant);
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

// ============================================================================
// Comprehensive Gas Constants and Calculation Benchmarks
// ============================================================================

/// Benchmark gas constants across different hardforks
pub fn hardfork_gas_constants_benchmark(allocator: Allocator) void {
    _ = allocator;

    var sum: u64 = 0;
    const iterations = 50000;

    // Simulate different hardfork scenarios
    const hardforks = [_]Hardfork{ .FRONTIER, .HOMESTEAD, .BYZANTIUM, .CONSTANTINOPLE, .ISTANBUL, .BERLIN, .LONDON, .SHANGHAI, .CANCUN };

    for (0..iterations) |_| {
        for (hardforks) |hardfork| {
            // Simulate hardfork-specific gas calculations
            if (@intFromEnum(hardfork) >= @intFromEnum(Hardfork.BERLIN)) {
                // EIP-2929: Cold/warm access costs
                sum += GasConstants.ColdSloadCost;
                sum += GasConstants.WarmStorageReadCost;
                sum += GasConstants.ColdAccountAccessCost;
            } else {
                // Pre-Berlin costs
                sum += GasConstants.SloadGas;
            }

            if (@intFromEnum(hardfork) >= @intFromEnum(Hardfork.ISTANBUL)) {
                // EIP-1108: Reduced precompile costs
                sum += GasConstants.ECADD_GAS_COST;
                sum += GasConstants.ECMUL_GAS_COST;
            } else {
                // Pre-Istanbul costs
                sum += GasConstants.ECADD_GAS_COST_BYZANTIUM;
                sum += GasConstants.ECMUL_GAS_COST_BYZANTIUM;
            }

            if (@intFromEnum(hardfork) >= @intFromEnum(Hardfork.CANCUN)) {
                // EIP-1153: Transient storage
                sum += GasConstants.TLoadGas;
                sum += GasConstants.TStoreGas;
                // EIP-4844: Blob operations
                sum += GasConstants.BlobHashGas;
                sum += GasConstants.BlobBaseFeeGas;
            }
        }
    }

    std.mem.doNotOptimizeAway(sum);
}

/// Benchmark opcode categorization and gas lookup
pub fn opcode_category_gas_benchmark(allocator: Allocator) void {
    _ = allocator;

    var sum: u64 = 0;
    const iterations = 100000;

    // Different opcode categories with their gas costs
    const OpcodeCost = struct {
        opcode: u8,
        category: []const u8,
        gas: u64,
    };

    const opcode_costs = [_]OpcodeCost{
        // Arithmetic operations
        .{ .opcode = constants.constants.ADD, .category = "arithmetic", .gas = GasConstants.GasFastestStep },
        .{ .opcode = constants.constants.MUL, .category = "arithmetic", .gas = GasConstants.GasFastStep },
        .{ .opcode = constants.constants.DIV, .category = "arithmetic", .gas = GasConstants.GasFastStep },
        .{ .opcode = constants.constants.ADDMOD, .category = "arithmetic", .gas = GasConstants.GasMidStep },
        .{ .opcode = constants.constants.EXP, .category = "arithmetic", .gas = GasConstants.GasSlowStep },

        // Memory operations
        .{ .opcode = constants.constants.MLOAD, .category = "memory", .gas = GasConstants.GasFastestStep },
        .{ .opcode = constants.constants.MSTORE, .category = "memory", .gas = GasConstants.GasFastestStep },
        .{ .opcode = constants.constants.MSTORE8, .category = "memory", .gas = GasConstants.GasFastestStep },

        // Storage operations
        .{ .opcode = constants.constants.SLOAD, .category = "storage", .gas = GasConstants.SloadGas },
        .{ .opcode = constants.constants.SSTORE, .category = "storage", .gas = GasConstants.SstoreSentryGas },

        // System operations
        .{ .opcode = constants.constants.CALL, .category = "system", .gas = GasConstants.CallGas },
        .{ .opcode = constants.constants.CREATE, .category = "system", .gas = GasConstants.CreateGas },
        .{ .opcode = constants.constants.SELFDESTRUCT, .category = "system", .gas = GasConstants.SelfdestructGas },

        // Environmental operations
        .{ .opcode = constants.constants.BALANCE, .category = "environment", .gas = GasConstants.GasExtStep },
        .{ .opcode = constants.constants.EXTCODESIZE, .category = "environment", .gas = GasConstants.GasExtStep },

        // Crypto operations
        .{ .opcode = constants.constants.KECCAK256, .category = "crypto", .gas = GasConstants.Keccak256Gas },
    };

    for (0..iterations) |_| {
        for (opcode_costs) |cost_info| {
            sum += cost_info.gas;
        }
    }

    std.mem.doNotOptimizeAway(sum);
}

/// Benchmark memory expansion gas calculation performance across different sizes
pub fn memory_expansion_performance_benchmark(allocator: Allocator) void {
    _ = allocator;

    var sum: u64 = 0;
    const iterations = 25000;

    // Test various memory expansion scenarios
    const expansion_scenarios = [_]struct {
        current_size: u64,
        new_size: u64,
    }{
        .{ .current_size = 0, .new_size = 32 }, // Initial allocation
        .{ .current_size = 32, .new_size = 64 }, // Small expansion
        .{ .current_size = 1024, .new_size = 2048 }, // Medium expansion
        .{ .current_size = 32768, .new_size = 65536 }, // Large expansion
        .{ .current_size = 0, .new_size = 1024 }, // Large initial allocation
        .{ .current_size = 0, .new_size = 32768 }, // Very large initial allocation
        .{ .current_size = 65536, .new_size = 131072 }, // Very large expansion
    };

    for (0..iterations) |_| {
        for (expansion_scenarios) |scenario| {
            const cost = GasConstants.memory_gas_cost(scenario.current_size, scenario.new_size);
            sum += cost;
        }
    }

    std.mem.doNotOptimizeAway(sum);
}

/// Benchmark complex gas calculations involving multiple components
pub fn complex_gas_calculation_benchmark(allocator: Allocator) void {
    _ = allocator;

    var sum: u64 = 0;
    const iterations = 10000;

    for (0..iterations) |_| {
        // Simulate a complex CALL operation with memory expansion
        var call_cost: u64 = 0;

        // Base CALL cost
        call_cost += GasConstants.CallGas;

        // Cold account access (EIP-2929)
        call_cost += GasConstants.ColdAccountAccessCost;

        // Value transfer
        const has_value = true;
        if (has_value) {
            call_cost += GasConstants.CallValueTransferGas;
            call_cost += GasConstants.CallStipend;
        }

        // New account creation
        const account_exists = false;
        if (!account_exists and has_value) {
            call_cost += GasConstants.CallNewAccountGas;
        }

        // Memory expansion for input/output data
        const input_size: u64 = 1024;
        const output_size: u64 = 512;
        const current_memory: u64 = 0;

        const input_memory_cost = GasConstants.memory_gas_cost(current_memory, input_size);
        const total_memory_needed = @max(input_size, output_size);
        const output_memory_cost = GasConstants.memory_gas_cost(current_memory, total_memory_needed);

        call_cost += @max(input_memory_cost, output_memory_cost);

        // Gas forwarding calculation (63/64 rule)
        const available_gas: u64 = 1000000;
        const gas_left = if (available_gas > call_cost) available_gas - call_cost else 0;
        const forwarded_gas = gas_left - (gas_left / GasConstants.CALL_GAS_RETENTION_DIVISOR);

        sum += call_cost + forwarded_gas;

        // Simulate a CREATE2 operation
        var create_cost: u64 = 0;

        // Base CREATE cost
        create_cost += GasConstants.CreateGas;

        // Initcode word cost (EIP-3860)
        const initcode_size: u64 = 8192;
        const initcode_words = wordCount(initcode_size);
        create_cost += initcode_words * GasConstants.InitcodeWordGas;

        // Hash computation cost for CREATE2 (salt + bytecode)
        const hash_data_size = 32 + initcode_size; // salt + code
        const hash_words = wordCount(hash_data_size);
        create_cost += GasConstants.Keccak256Gas + (hash_words * GasConstants.Keccak256WordGas);

        // Memory cost for initcode
        create_cost += GasConstants.memory_gas_cost(0, initcode_size);

        // Deployment cost
        const deployed_code_size: u64 = 4096;
        create_cost += deployed_code_size * constants.constants.DEPLOY_CODE_GAS_PER_BYTE;

        sum += create_cost;
    }

    std.mem.doNotOptimizeAway(sum);
}

/// Benchmark precompile gas cost calculations
pub fn precompile_gas_benchmark(allocator: Allocator) void {
    _ = allocator;

    var sum: u64 = 0;
    const iterations = 50000;

    for (0..iterations) |_| {
        // ECRECOVER - fixed cost
        sum += GasConstants.ECRECOVER_COST;

        // SHA256 - variable cost based on input size
        for ([_]u64{ 32, 64, 128, 256, 512, 1024 }) |input_size| {
            const words = wordCount(input_size);
            sum += GasConstants.SHA256_BASE_COST + (words * GasConstants.SHA256_WORD_COST);
        }

        // RIPEMD160 - variable cost based on input size
        for ([_]u64{ 32, 64, 128, 256 }) |input_size| {
            const words = wordCount(input_size);
            sum += GasConstants.RIPEMD160_BASE_COST + (words * GasConstants.RIPEMD160_WORD_COST);
        }

        // IDENTITY - variable cost based on input size
        for ([_]u64{ 32, 64, 128, 256, 512 }) |input_size| {
            const words = wordCount(input_size);
            sum += GasConstants.IDENTITY_BASE_COST + (words * GasConstants.IDENTITY_WORD_COST);
        }

        // MODEXP - complex cost calculation (simplified)
        const base_len: u64 = 32;
        const mod_len: u64 = 32;
        const complexity = base_len * mod_len;
        var modexp_cost = @max(complexity / 100, GasConstants.MODEXP_MIN_GAS);
        modexp_cost = @max(modexp_cost, GasConstants.MODEXP_MIN_GAS);
        sum += modexp_cost;

        // BN254 operations - hardfork dependent costs
        sum += GasConstants.ECADD_GAS_COST;
        sum += GasConstants.ECMUL_GAS_COST;
        sum += GasConstants.ECPAIRING_BASE_GAS_COST;

        // Compare with Byzantium costs
        sum += GasConstants.ECADD_GAS_COST_BYZANTIUM;
        sum += GasConstants.ECMUL_GAS_COST_BYZANTIUM;
        sum += GasConstants.ECPAIRING_BASE_GAS_COST_BYZANTIUM;
    }

    std.mem.doNotOptimizeAway(sum);
}

/// Benchmark SSTORE gas calculation across different state transitions
pub fn sstore_state_transition_benchmark(allocator: Allocator) void {
    _ = allocator;

    var sum: u64 = 0;
    const iterations = 25000;

    const StateTransition = struct {
        original: u256,
        current: u256,
        new: u256,
        description: []const u8,
    };

    const transitions = [_]StateTransition{
        // EIP-2200 SSTORE gas cost scenarios
        .{ .original = 0, .current = 0, .new = 0, .description = "no-op" },
        .{ .original = 0, .current = 0, .new = 1, .description = "set_from_zero" },
        .{ .original = 1, .current = 1, .new = 0, .description = "clear_to_zero" },
        .{ .original = 1, .current = 1, .new = 2, .description = "modify_existing" },
        .{ .original = 0, .current = 1, .new = 0, .description = "reset_to_original_zero" },
        .{ .original = 1, .current = 0, .new = 1, .description = "reset_to_original_nonzero" },
        .{ .original = 1, .current = 2, .new = 3, .description = "dirty_modify" },
        .{ .original = 0, .current = 1, .new = 2, .description = "dirty_modify_from_zero_original" },
    };

    for (0..iterations) |_| {
        for (transitions) |transition| {
            var cost: u64 = GasConstants.SstoreSentryGas;

            // EIP-2200 gas calculation logic
            if (transition.current == transition.new) {
                // No-op
                cost = GasConstants.SstoreSentryGas;
            } else if (transition.original == transition.current) {
                // First write to this slot in transaction
                if (transition.original == 0) {
                    // Setting storage from zero
                    cost += GasConstants.SstoreSetGas;
                } else {
                    // Modifying existing storage
                    cost += GasConstants.SstoreResetGas;
                }
            } else {
                // Subsequent write to this slot in transaction
                cost += GasConstants.WarmStorageReadCost;
            }

            sum += cost;

            // Calculate refunds
            var refund: i64 = 0;
            if (transition.original != 0 and transition.current != 0 and transition.new == 0) {
                refund += @as(i64, @intCast(GasConstants.SstoreRefundGas));
            } else if (transition.original != 0 and transition.current == 0 and transition.new != 0) {
                refund -= @as(i64, @intCast(GasConstants.SstoreRefundGas));
            }

            sum += @abs(refund);
        }
    }

    std.mem.doNotOptimizeAway(sum);
}

/// Benchmark LOG gas calculations with different topic counts and data sizes
pub fn log_gas_calculation_benchmark(allocator: Allocator) void {
    _ = allocator;

    var sum: u64 = 0;
    const iterations = 50000;

    for (0..iterations) |_| {
        // Test LOG0 through LOG4 with various data sizes
        for (0..5) |topic_count| {
            for ([_]u64{ 0, 32, 64, 128, 256, 512, 1024, 4096 }) |data_size| {
                var log_cost: u64 = GasConstants.LogGas;

                // Add topic costs
                log_cost += @as(u64, @intCast(topic_count)) * GasConstants.LogTopicGas;

                // Add data costs
                log_cost += data_size * GasConstants.LogDataGas;

                // Add memory expansion costs
                log_cost += GasConstants.memory_gas_cost(0, data_size);

                sum += log_cost;
            }
        }
    }

    std.mem.doNotOptimizeAway(sum);
}

/// Comprehensive benchmark function that runs all gas calculation benchmarks
pub fn run_all_gas_benchmarks(allocator: Allocator) !void {
    std.log.info("=== Comprehensive Gas Calculation and Constants Benchmarks ===", .{});

    var suite = timing.BenchmarkSuite.init(allocator);
    defer suite.deinit();

    // Original benchmarks (fixed)
    try suite.benchmark(timing.BenchmarkConfig{
        .name = "memory_linear_gas",
        .iterations = 1000,
        .warmup_iterations = 10,
    }, struct {
        fn run() void {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            memory_linear_gas_benchmark(gpa.allocator());
        }
    }.run);

    try suite.benchmark(timing.BenchmarkConfig{
        .name = "memory_quadratic_gas",
        .iterations = 1000,
        .warmup_iterations = 10,
    }, struct {
        fn run() void {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            memory_quadratic_gas_benchmark(gpa.allocator());
        }
    }.run);

    try suite.benchmark(timing.BenchmarkConfig{
        .name = "memory_expansion_full_gas",
        .iterations = 1000,
        .warmup_iterations = 10,
    }, struct {
        fn run() void {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            memory_expansion_full_gas_benchmark(gpa.allocator());
        }
    }.run);

    // New comprehensive benchmarks
    try suite.benchmark(timing.BenchmarkConfig{
        .name = "hardfork_gas_constants",
        .iterations = 500,
        .warmup_iterations = 10,
    }, struct {
        fn run() void {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            hardfork_gas_constants_benchmark(gpa.allocator());
        }
    }.run);

    try suite.benchmark(timing.BenchmarkConfig{
        .name = "opcode_category_gas",
        .iterations = 500,
        .warmup_iterations = 10,
    }, struct {
        fn run() void {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            opcode_category_gas_benchmark(gpa.allocator());
        }
    }.run);

    try suite.benchmark(timing.BenchmarkConfig{
        .name = "memory_expansion_performance",
        .iterations = 1000,
        .warmup_iterations = 10,
    }, struct {
        fn run() void {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            memory_expansion_performance_benchmark(gpa.allocator());
        }
    }.run);

    try suite.benchmark(timing.BenchmarkConfig{
        .name = "complex_gas_calculation",
        .iterations = 500,
        .warmup_iterations = 10,
    }, struct {
        fn run() void {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            complex_gas_calculation_benchmark(gpa.allocator());
        }
    }.run);

    try suite.benchmark(timing.BenchmarkConfig{
        .name = "precompile_gas",
        .iterations = 1000,
        .warmup_iterations = 10,
    }, struct {
        fn run() void {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            precompile_gas_benchmark(gpa.allocator());
        }
    }.run);

    try suite.benchmark(timing.BenchmarkConfig{
        .name = "sstore_state_transition",
        .iterations = 1000,
        .warmup_iterations = 10,
    }, struct {
        fn run() void {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            sstore_state_transition_benchmark(gpa.allocator());
        }
    }.run);

    try suite.benchmark(timing.BenchmarkConfig{
        .name = "log_gas_calculation",
        .iterations = 1000,
        .warmup_iterations = 10,
    }, struct {
        fn run() void {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            log_gas_calculation_benchmark(gpa.allocator());
        }
    }.run);

    try suite.benchmark(timing.BenchmarkConfig{
        .name = "dynamic_vs_constant_gas",
        .iterations = 1000,
        .warmup_iterations = 10,
    }, struct {
        fn run() void {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            dynamic_vs_constant_gas_benchmark(gpa.allocator());
        }
    }.run);

    suite.print_results();

    // Perform some comparisons
    try suite.compare("memory_linear_gas", "memory_quadratic_gas");
    try suite.compare("dynamic_vs_constant_gas", "opcode_category_gas");
}

// ============================================================================
// Tests
// ============================================================================

test "hardfork gas constants benchmark" {
    hardfork_gas_constants_benchmark(std.testing.allocator);
}

test "opcode category gas benchmark" {
    opcode_category_gas_benchmark(std.testing.allocator);
}

test "memory expansion performance benchmark" {
    memory_expansion_performance_benchmark(std.testing.allocator);
}

test "complex gas calculation benchmark" {
    complex_gas_calculation_benchmark(std.testing.allocator);
}

test "precompile gas benchmark" {
    precompile_gas_benchmark(std.testing.allocator);
}

test "sstore state transition benchmark" {
    sstore_state_transition_benchmark(std.testing.allocator);
}

test "log gas calculation benchmark" {
    log_gas_calculation_benchmark(std.testing.allocator);
}
