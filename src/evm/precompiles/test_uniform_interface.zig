const std = @import("std");
const testing = std.testing;
const PrecompileOutput = @import("precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("precompile_result.zig").PrecompileError;
const ChainRules = @import("../hardforks/chain_rules.zig");

// Test the uniform interface pattern
test "uniform precompile interface" {
    const TestPrecompile = struct {
        // Uniform interface - all precompiles use the same signature
        pub fn execute(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
            _ = chain_rules; // Unused for simple precompiles
            
            if (gas_limit < 100) {
                return PrecompileOutput.failure_result(PrecompileError.OutOfGas);
            }
            
            if (output.len < input.len) {
                return PrecompileOutput.failure_result(PrecompileError.BufferTooSmall);
            }
            
            std.mem.copyForwards(u8, output, input);
            return PrecompileOutput.success_result(100, input.len);
        }
    };
    
    var output_buffer: [32]u8 = undefined;
    const input = "test";
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);
    
    const result = TestPrecompile.execute(input, &output_buffer, 1000, chain_rules);
    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 100), result.get_gas_used());
    try testing.expectEqualSlices(u8, input, output_buffer[0..4]);
}

test "uniform interface allows chain rules to be ignored" {
    const SimplePrecompile = struct {
        pub fn execute(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
            _ = chain_rules; // Explicitly unused
            _ = input;
            _ = output;
            return PrecompileOutput.success_result(gas_limit, 0);
        }
    };
    
    const ECPrecompile = struct {
        pub fn execute(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
            _ = input;
            _ = output;
            // EC precompiles actually use chain rules
            const gas_cost = if (chain_rules.is_istanbul) 45000 else 100000;
            return PrecompileOutput.success_result(gas_cost, 0);
        }
    };
    
    var output: [32]u8 = undefined;
    const byzantium_rules = ChainRules.for_hardfork(.BYZANTIUM);
    const istanbul_rules = ChainRules.for_hardfork(.ISTANBUL);
    
    // Simple precompile ignores chain rules
    const simple_result = SimplePrecompile.execute(&.{}, &output, 1000, byzantium_rules);
    try testing.expectEqual(@as(u64, 1000), simple_result.get_gas_used());
    
    // EC precompile uses chain rules
    const ec_result1 = ECPrecompile.execute(&.{}, &output, 200000, byzantium_rules);
    const ec_result2 = ECPrecompile.execute(&.{}, &output, 200000, istanbul_rules);
    try testing.expectEqual(@as(u64, 100000), ec_result1.get_gas_used());
    try testing.expectEqual(@as(u64, 45000), ec_result2.get_gas_used());
}