const ExecutionError = @import("../execution/execution_error.zig");

/// Result of an EVM execution run.
///
/// RunResult encapsulates the outcome of executing EVM bytecode, including
/// success/failure status, gas consumption, and any output data. This is
/// the primary return type for VM execution functions.
///
/// ## Design Rationale
/// The result combines multiple pieces of information needed after execution:
/// - Status indicates how execution ended (success, revert, error)
/// - Gas tracking for accounting and refunds
/// - Output data for return values or revert messages
/// - Optional error details for debugging
///
/// ## Status Types
/// - Success: Execution completed normally
/// - Revert: Explicit revert (REVERT opcode or require failure)
/// - Invalid: Invalid operation (bad opcode, stack error, etc.)
/// - OutOfGas: Execution ran out of gas
///
/// ## Usage
/// ```zig
/// const result = vm.run(bytecode, gas_limit);
/// switch (result.status) {
///     .Success => {
///         // Process output data
///         const return_data = result.output orelse &[_]u8{};
///     },
///     .Revert => {
///         // Handle revert with reason
///         const revert_reason = result.output orelse &[_]u8{};
///     },
///     .Invalid => {
///         // Handle error
///         std.log.err("Execution failed: {?}", .{result.err});
///     },
///     .OutOfGas => {
///         // Handle out of gas
///     },
/// }
/// ```
pub const RunResult = @This();

/// Execution completion status.
///
/// Indicates how the execution ended. This maps to EVM execution outcomes:
/// - Success: Normal completion (STOP, RETURN, or end of code)
/// - Revert: Explicit revert (REVERT opcode)
/// - Invalid: Execution error (invalid opcode, stack error, etc.)
/// - OutOfGas: Gas exhausted during execution
pub const Status = enum {
    /// Execution completed successfully
    Success,
    /// Execution was explicitly reverted
    Revert,
    /// Execution failed due to invalid operation
    Invalid,
    /// Execution ran out of gas
    OutOfGas,
};
status: Status,

/// Optional execution error details.
///
/// Present when status is Invalid, providing specific error information
/// for debugging and error reporting.
err: ?ExecutionError.Error,

/// Remaining gas after execution.
///
/// For successful execution, this is refunded to the caller.
/// For failed execution, this may be zero or partially consumed.
gas_left: u64,

/// Total gas consumed during execution.
///
/// Calculated as: initial_gas - gas_left
/// Used for:
/// - Transaction receipts
/// - Gas accounting
/// - Performance monitoring
gas_used: u64,

/// Output data from execution.
///
/// Contents depend on execution status:
/// - Success: Return data from RETURN opcode
/// - Revert: Revert reason from REVERT opcode
/// - Invalid/OutOfGas: Usually null
///
/// Note: Empty output is different from null output.
/// Empty means explicit empty return, null means no return.
output: ?[]const u8,

pub fn init(
    initial_gas: u64,
    gas_left: u64,
    status: Status,
    err: ?ExecutionError.Error,
    output: ?[]const u8,
) RunResult {
    return RunResult{
        .status = status,
        .err = err,
        .gas_left = gas_left,
        .gas_used = initial_gas - gas_left,
        .output = output,
    };
}

// Tests

const std = @import("std");
const testing = std.testing;

test "init creates RunResult with Success status" {
    const result = init(1000, 300, Status.Success, null, null);
    try testing.expectEqual(Status.Success, result.status);
    try testing.expectEqual(@as(?ExecutionError.Error, null), result.err);
    try testing.expectEqual(@as(u64, 300), result.gas_left);
    try testing.expectEqual(@as(u64, 700), result.gas_used);
    try testing.expectEqual(@as(?[]const u8, null), result.output);
}

test "init creates RunResult with Revert status and output data" {
    const revert_reason = "require failed";
    const result = init(2000, 500, Status.Revert, null, revert_reason);
    try testing.expectEqual(Status.Revert, result.status);
    try testing.expectEqual(@as(?ExecutionError.Error, null), result.err);
    try testing.expectEqual(@as(u64, 500), result.gas_left);
    try testing.expectEqual(@as(u64, 1500), result.gas_used);
    try testing.expectEqualStrings(revert_reason, result.output.?);
}

test "init creates RunResult with Invalid status and error" {
    const result = init(5000, 1000, Status.Invalid, ExecutionError.Error.StackUnderflow, null);
    try testing.expectEqual(Status.Invalid, result.status);
    try testing.expectEqual(ExecutionError.Error.StackUnderflow, result.err.?);
    try testing.expectEqual(@as(u64, 1000), result.gas_left);
    try testing.expectEqual(@as(u64, 4000), result.gas_used);
    try testing.expectEqual(@as(?[]const u8, null), result.output);
}

test "init creates RunResult with OutOfGas status" {
    const result = init(10000, 0, Status.OutOfGas, ExecutionError.Error.OutOfGas, null);
    try testing.expectEqual(Status.OutOfGas, result.status);
    try testing.expectEqual(ExecutionError.Error.OutOfGas, result.err.?);
    try testing.expectEqual(@as(u64, 0), result.gas_left);
    try testing.expectEqual(@as(u64, 10000), result.gas_used);
    try testing.expectEqual(@as(?[]const u8, null), result.output);
}

test "init calculates gas_used correctly when all gas consumed" {
    const result = init(1000, 0, Status.Success, null, null);
    try testing.expectEqual(@as(u64, 0), result.gas_left);
    try testing.expectEqual(@as(u64, 1000), result.gas_used);
}

test "init calculates gas_used correctly when no gas consumed" {
    const result = init(1000, 1000, Status.Success, null, null);
    try testing.expectEqual(@as(u64, 1000), result.gas_left);
    try testing.expectEqual(@as(u64, 0), result.gas_used);
}

test "init handles empty output data correctly" {
    const empty_data = "";
    const result = init(1500, 750, Status.Success, null, empty_data);
    try testing.expectEqual(Status.Success, result.status);
    try testing.expectEqual(@as(u64, 750), result.gas_left);
    try testing.expectEqual(@as(u64, 750), result.gas_used);
    try testing.expectEqualStrings("", result.output.?);
}

test "init handles maximum gas values" {
    const max_gas = std.math.maxInt(u64);
    const result = init(max_gas, max_gas / 2, Status.Success, null, null);
    try testing.expectEqual(@as(u64, max_gas / 2), result.gas_left);
    try testing.expectEqual(@as(u64, max_gas / 2), result.gas_used);
}

test "init handles zero gas scenario" {
    const result = init(0, 0, Status.OutOfGas, ExecutionError.Error.OutOfGas, null);
    try testing.expectEqual(Status.OutOfGas, result.status);
    try testing.expectEqual(@as(u64, 0), result.gas_left);
    try testing.expectEqual(@as(u64, 0), result.gas_used);
}

test "init preserves all provided parameters" {
    const output_data = "return data";
    const result = init(3000, 800, Status.Success, null, output_data);

    try testing.expectEqual(Status.Success, result.status);
    try testing.expectEqual(@as(?ExecutionError.Error, null), result.err);
    try testing.expectEqual(@as(u64, 800), result.gas_left);
    try testing.expectEqual(@as(u64, 2200), result.gas_used);
    try testing.expectEqualStrings(output_data, result.output.?);
}

test "init handles all Status variants correctly" {
    const statuses = [_]Status{ Status.Success, Status.Revert, Status.Invalid, Status.OutOfGas };

    for (statuses) |status| {
        const result = init(1000, 500, status, null, null);
        try testing.expectEqual(status, result.status);
        try testing.expectEqual(@as(u64, 500), result.gas_left);
        try testing.expectEqual(@as(u64, 500), result.gas_used);
    }
}

test "init handles various ExecutionError types" {
    const errors = [_]ExecutionError.Error{
        ExecutionError.Error.STOP,
        ExecutionError.Error.REVERT,
        ExecutionError.Error.InvalidOpcode,
        ExecutionError.Error.StackOverflow,
        ExecutionError.Error.OutOfGas,
        ExecutionError.Error.InvalidJump,
    };

    for (errors) |error_type| {
        const result = init(1000, 400, Status.Invalid, error_type, null);
        try testing.expectEqual(Status.Invalid, result.status);
        try testing.expectEqual(error_type, result.err.?);
        try testing.expectEqual(@as(u64, 400), result.gas_left);
        try testing.expectEqual(@as(u64, 600), result.gas_used);
    }
}

// ============================================================================
// Fuzz Tests for Gas Calculation Edge Cases and Overflow Scenarios (Issue #234)
// Using proper Zig built-in fuzz testing with std.testing.fuzz()
// ============================================================================

const status_variants = [_]Status{ Status.Success, Status.Revert, Status.Invalid, Status.OutOfGas };

// test "fuzz_gas_calculation_boundary_conditions" {
//     const global = struct {
//         fn testGasBoundaryConditions(input: []const u8) anyerror!void {
//             if (input.len < 10) return;
//
//             // Use fuzz input to generate gas values
//             const initial_gas = std.mem.readInt(u64, input[0..8], .little);
//             const gas_left = if (initial_gas > 0)
//                 (std.mem.readInt(u64, input[2..10], .little) % initial_gas)
//             else
//                 0;
//             const gas_consumed = initial_gas - gas_left;
//
//             const status = status_variants[input[1] % status_variants.len];
//
//             const result = init(initial_gas, gas_left, status, null, null);
//
//             try testing.expectEqual(initial_gas, result.gas_left + result.gas_used);
//             try testing.expectEqual(gas_left, result.gas_left);
//             try testing.expectEqual(gas_consumed, result.gas_used);
//             try testing.expectEqual(status, result.status);
//         }
//     };
//     try std.testing.fuzz(global.testGasBoundaryConditions, .{});
// }

// test "fuzz_gas_limit_boundary_testing" {
//     const global = struct {
//         const boundary_values = [_]u64{
//             0, 1, 255, 256, 65535, 65536, 21000, 100000, 1000000, 10000000,
//             std.math.maxInt(u32), std.math.maxInt(u32) + 1,
//             std.math.maxInt(u64) - 1, std.math.maxInt(u64),
//         };
//
//         fn testGasLimitBoundary(input: []const u8) anyerror!void {
//             if (input.len < 3) return;
//
//             const boundary_idx = input[0] % boundary_values.len;
//             const initial_gas = boundary_values[boundary_idx];
//
//             const gas_consumption_percent = input[1] % 101; // 0-100
//             const gas_consumed = if (initial_gas > 0) (initial_gas * gas_consumption_percent) / 100 else 0;
//             const gas_left = initial_gas - gas_consumed;
//
//             const status = if (gas_consumed >= initial_gas) Status.OutOfGas else Status.Success;
//
//             const result = init(initial_gas, gas_left, status, null, null);
//
//             try testing.expect(result.gas_left <= initial_gas);
//             try testing.expect(result.gas_used <= initial_gas);
//             try testing.expect(result.gas_left + result.gas_used == initial_gas);
//
//             if (status == Status.OutOfGas) {
//                 try testing.expect(result.gas_left == 0 or result.gas_used == initial_gas);
//             }
//         }
//     };
//     try std.testing.fuzz(global.testGasLimitBoundary, .{});
// }

// test "fuzz_gas_cost_accumulation_overflow_scenarios" {
//     const global = struct {
//         fn testGasOverflow(input: []const u8) anyerror!void {
//             if (input.len < 16) return;
//
//             const max_safe_gas = std.math.maxInt(u64) - 10000;
//             const base_gas = std.mem.readInt(u64, input[0..8], .little);
//             const initial_gas = max_safe_gas + (base_gas % 10000);
//
//             const gas_left_raw = std.mem.readInt(u64, input[8..16], .little);
//             const gas_left = gas_left_raw % (initial_gas + 1);
//             const expected_gas_used = initial_gas - gas_left;
//
//             const result = init(initial_gas, gas_left, Status.Success, null, null);
//
//             try testing.expectEqual(gas_left, result.gas_left);
//             try testing.expectEqual(expected_gas_used, result.gas_used);
//
//             const overflow_test = result.gas_left +| result.gas_used;
//             try testing.expectEqual(initial_gas, overflow_test);
//
//             try testing.expect(result.gas_left <= initial_gas);
//             try testing.expect(result.gas_used <= initial_gas);
//         }
//     };
//     try std.testing.fuzz(global.testGasOverflow, .{});
// }

// test "fuzz_status_error_consistency_validation" {
//     const global = struct {
//         const test_cases = [_]struct {
//             status: Status,
//             should_have_error: bool,
//             valid_errors: []const ExecutionError.Error,
//         }{
//             .{ .status = Status.Success, .should_have_error = false, .valid_errors = &[_]ExecutionError.Error{} },
//             .{ .status = Status.Revert, .should_have_error = false, .valid_errors = &[_]ExecutionError.Error{ExecutionError.Error.REVERT} },
//             .{ .status = Status.Invalid, .should_have_error = true, .valid_errors = &[_]ExecutionError.Error{
//                 ExecutionError.Error.InvalidOpcode, ExecutionError.Error.StackOverflow,
//                 ExecutionError.Error.StackUnderflow, ExecutionError.Error.InvalidJump,
//                 ExecutionError.Error.StaticStateChange, ExecutionError.Error.WriteProtection,
//             }},
//             .{ .status = Status.OutOfGas, .should_have_error = true, .valid_errors = &[_]ExecutionError.Error{ExecutionError.Error.OutOfGas} },
//         };
//
//         fn testStatusConsistency(input: []const u8) anyerror!void {
//             if (input.len < 16) return;
//
//             const test_case = test_cases[input[0] % test_cases.len];
//
//             const initial_gas = 1000 + (std.mem.readInt(u32, input[4..8], .little) % 999000);
//             const gas_left = std.mem.readInt(u32, input[8..12], .little) % (initial_gas + 1);
//
//             const error_to_use = if (test_case.valid_errors.len > 0)
//                 test_case.valid_errors[input[1] % test_case.valid_errors.len]
//             else
//                 null;
//
//             const result = init(initial_gas, gas_left, test_case.status, error_to_use, null);
//
//             try testing.expectEqual(test_case.status, result.status);
//             try testing.expectEqual(gas_left, result.gas_left);
//             try testing.expectEqual(initial_gas - gas_left, result.gas_used);
//
//             if (test_case.should_have_error and error_to_use != null) {
//                 try testing.expect(result.err != null);
//                 try testing.expectEqual(error_to_use.?, result.err.?);
//             } else if (!test_case.should_have_error and error_to_use == null) {
//                 try testing.expect(result.err == null);
//             }
//         }
//     };
//     try std.testing.fuzz(global.testStatusConsistency, .{});
// }

// test "fuzz_output_data_variations_with_gas_tracking" {
//     const global = struct {
//         const output_scenarios = [_]?[]const u8{
//             null, "", "0x", "revert reason", "Error: insufficient funds",
//             "very long error message that exceeds typical buffer sizes and includes special characters !@#$%^&*()",
//             "ABI encoded data with multiple parameters", "Short", "0x1234567890abcdef",
//         };
//
//         fn testOutputVariations(input: []const u8) anyerror!void {
//             if (input.len < 12) return;
//
//             const initial_gas = 21000 + (std.mem.readInt(u32, input[0..4], .little) % 9979000);
//             const gas_consumed = std.mem.readInt(u32, input[4..8], .little) % (initial_gas + 1);
//             const gas_left = initial_gas - gas_consumed;
//
//             const status = status_variants[input[8] % status_variants.len];
//             const output = output_scenarios[input[9] % output_scenarios.len];
//
//             const result = init(initial_gas, gas_left, status, null, output);
//
//             try testing.expectEqual(status, result.status);
//             try testing.expectEqual(gas_left, result.gas_left);
//             try testing.expectEqual(gas_consumed, result.gas_used);
//
//             if (output) |expected_output| {
//                 if (result.output) |actual_output| {
//                     try testing.expectEqualStrings(expected_output, actual_output);
//                 } else {
//                     return testing.expect(false);
//                 }
//             } else {
//                 try testing.expect(result.output == null);
//             }
//
//             try testing.expect(result.gas_left <= initial_gas);
//             try testing.expect(result.gas_used <= initial_gas);
//         }
//     };
//     try std.testing.fuzz(global.testOutputVariations, .{});
// }

// test "fuzz_random_gas_boundary_property_validation" {
//     const global = struct {
//         fn testGasBoundaryProperties(input: []const u8) anyerror!void {
//             if (input.len < 16) return;
//
//             const initial_gas = std.mem.readInt(u64, input[0..8], .little);
//             const gas_left = if (initial_gas > 0)
//                 std.mem.readInt(u64, input[8..16], .little) % (initial_gas + 1)
//             else
//                 0;
//
//             const status = status_variants[input[1] % status_variants.len];
//
//             const result = init(initial_gas, gas_left, status, null, null);
//
//             const gas_calculation_valid = result.gas_left + result.gas_used == initial_gas;
//             const gas_left_valid = result.gas_left <= initial_gas;
//             const gas_used_valid = result.gas_used <= initial_gas;
//
//             try testing.expect(gas_calculation_valid);
//             try testing.expect(gas_left_valid);
//             try testing.expect(gas_used_valid);
//
//             try testing.expectEqual(gas_left, result.gas_left);
//             try testing.expectEqual(initial_gas - gas_left, result.gas_used);
//             try testing.expectEqual(status, result.status);
//         }
//     };
//     try std.testing.fuzz(global.testGasBoundaryProperties, .{});
// }

// test "fuzz_extreme_gas_scenarios_stress_testing" {
//     const global = struct {
//         const extreme_scenarios = [_]struct {
//             name: []const u8,
//             initial_gas: u64,
//         }{
//             .{ .name = "maximum gas values", .initial_gas = std.math.maxInt(u64) },
//             .{ .name = "minimum gas values", .initial_gas = 1 },
//             .{ .name = "block gas limit scenarios", .initial_gas = 30000000 },
//             .{ .name = "transaction gas limit scenarios", .initial_gas = 21000 },
//         };
//
//         fn testExtremeScenarios(input: []const u8) anyerror!void {
//             if (input.len < 16) return;
//
//             const scenario = extreme_scenarios[input[0] % extreme_scenarios.len];
//             const initial_gas = scenario.initial_gas;
//
//             const gas_left = if (initial_gas > 0) {
//                 const base_left = std.mem.readInt(u64, input[8..16], .little);
//                 switch (input[0] % extreme_scenarios.len) {
//                     0 => base_left % (initial_gas / 2 + 1) + (initial_gas / 2), // max values: use upper half
//                     1 => if (initial_gas > 0) 0 else 0, // min values: use 0
//                     else => base_left % (initial_gas + 1), // others: any valid value
//                 }
//             } else 0;
//
//             const status = status_variants[input[1] % status_variants.len];
//
//             const result = init(initial_gas, gas_left, status, null, null);
//
//             try testing.expectEqual(initial_gas, result.gas_left + result.gas_used);
//             try testing.expectEqual(gas_left, result.gas_left);
//             try testing.expectEqual(initial_gas - gas_left, result.gas_used);
//             try testing.expectEqual(status, result.status);
//
//             try testing.expect(result.gas_left <= initial_gas);
//             try testing.expect(result.gas_used <= initial_gas);
//
//             if (status == Status.OutOfGas and initial_gas > 10) {
//                 try testing.expect(gas_left <= initial_gas / 10);
//             }
//         }
//     };
//     try std.testing.fuzz(global.testExtremeScenarios, .{});
// }
