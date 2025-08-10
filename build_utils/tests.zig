const std = @import("std");

// Test configuration structures
pub const TestInfo = struct {
    name: []const u8,
    source_file: []const u8,
    step_name: ?[]const u8 = null,
    step_desc: ?[]const u8 = null,
};

// Fuzz test configurations
pub const fuzz_tests = [_]TestInfo{
    .{
        .name = "fuzz-stack-test",
        .source_file = "test/fuzz/stack_fuzz_test.zig",
        .step_name = "fuzz-stack",
        .step_desc = "Run stack fuzz tests",
    },
    .{
        .name = "fuzz-memory-test",
        .source_file = "test/fuzz/memory_fuzz_test.zig",
        .step_name = "fuzz-memory",
        .step_desc = "Run memory fuzz tests",
    },
    .{
        .name = "fuzz-arithmetic-test",
        .source_file = "test/fuzz/arithmetic_fuzz_test.zig",
        .step_name = "fuzz-arithmetic",
        .step_desc = "Run arithmetic fuzz tests",
    },
    .{
        .name = "fuzz-bitwise-test",
        .source_file = "test/fuzz/bitwise_fuzz_test.zig",
        .step_name = "fuzz-bitwise",
        .step_desc = "Run bitwise fuzz tests",
    },
    .{
        .name = "fuzz-comparison-test",
        .source_file = "test/fuzz/comparison_fuzz_test.zig",
        .step_name = "fuzz-comparison",
        .step_desc = "Run comparison fuzz tests",
    },
    .{
        .name = "fuzz-control-test",
        .source_file = "test/fuzz/control_fuzz_test.zig",
        .step_name = "fuzz-control",
        .step_desc = "Run control fuzz tests",
    },
    .{
        .name = "fuzz-crypto-test",
        .source_file = "test/fuzz/crypto_fuzz_test.zig",
        .step_name = "fuzz-crypto",
        .step_desc = "Run crypto fuzz tests",
    },
    .{
        .name = "fuzz-environment-test",
        .source_file = "test/fuzz/environment_fuzz_test.zig",
        .step_name = "fuzz-environment",
        .step_desc = "Run environment fuzz tests",
    },
    .{
        .name = "fuzz-storage-test",
        .source_file = "test/fuzz/storage_fuzz_test.zig",
        .step_name = "fuzz-storage",
        .step_desc = "Run storage fuzz tests",
    },
    .{
        .name = "fuzz-state-test",
        .source_file = "test/fuzz/state_fuzz_test.zig",
        .step_name = "fuzz-state",
        .step_desc = "Run state fuzz tests",
    },
};
