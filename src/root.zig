const std = @import("std");

pub const Evm = @import("evm.zig").Evm;
pub const EvmConfig = @import("evm_config.zig").EvmConfig;

test {
    // Test EVM modules
    _ = @import("evm_tests.zig");
    _ = @import("evm_config.zig");
    _ = @import("preprocessor/dispatch.zig");
    _ = @import("preprocessor/dispatch_test.zig");

    // Instruction handler tests
    _ = @import("instructions/handlers_arithmetic.zig");
    _ = @import("instructions/handlers_arithmetic_synthetic.zig");
    _ = @import("instructions/handlers_bitwise.zig");
    _ = @import("instructions/handlers_bitwise_synthetic.zig");
    _ = @import("instructions/handlers_comparison.zig");
    _ = @import("instructions/handlers_context.zig");
    _ = @import("instructions/handlers_jump.zig");
    _ = @import("instructions/handlers_jump_synthetic.zig");
    _ = @import("instructions/handlers_keccak.zig");
    _ = @import("instructions/handlers_log.zig");
    _ = @import("instructions/handlers_memory.zig");
    _ = @import("instructions/handlers_memory_synthetic.zig");
    _ = @import("instructions/handlers_stack.zig");
    _ = @import("instructions/handlers_storage.zig");
    _ = @import("instructions/handlers_system.zig");
    _ = @import("instructions/handlers_advanced_synthetic.zig");

    // Test bytecode modules
    _ = @import("bytecode/bytecode_tests.zig");
    _ = @import("bytecode/bytecode_jump_validation_test.zig");
    _ = @import("bytecode/bytecode_jump_validation_tests.zig");
    _ = @import("bytecode/bytecode_bench_test.zig");

    // Test internal modules
    _ = @import("internal/safety_counter.zig");

    // Tracer modules with tests
    _ = @import("tracer/pc_tracker.zig");
    _ = @import("tracer/events/events.zig");
    _ = @import("tracer/events/lifecycle.zig");
    _ = @import("tracer/minimal_frame.zig");

    // Crypto modules with tests are handled by crypto module
    // These are already imported through the crypto module to avoid conflicts

    // Trie tests
    _ = @import("trie/trie_test.zig");
    _ = @import("trie/test_simple_update.zig");
    _ = @import("trie/known_roots_test.zig");

    // Provider tests - removed to avoid module conflict
    // Provider module handles its own tests

    // C API modules are not compiled in tests in this configuration
    // _ = @import("root_c.zig");
}
