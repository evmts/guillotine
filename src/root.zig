//! Guillotine - High-Performance Ethereum Virtual Machine in Zig
//!
//! This is the main entry point for the Guillotine implementation.
//! It re-exports all the modules from their new organized structure.

const std = @import("std");

// Re-export everything from evm/root.zig
pub const Frame = @import("frame/frame.zig").Frame;
pub const FrameConfig = @import("frame/frame_config.zig").FrameConfig;
pub const FrameDispatch = @import("preprocessor/dispatch.zig").Dispatch;
pub const frame_mod = @import("frame/frame.zig");
pub const frame = @import("frame/frame.zig");
pub const frame_handlers = @import("frame/frame_handlers.zig");

// Stack and memory modules
pub const StackConfig = @import("stack/stack_config.zig").StackConfig;
pub const Stack = @import("stack/stack.zig").Stack;
pub const MemoryConfig = @import("memory/memory_config.zig").MemoryConfig;
pub const Memory = @import("memory/memory.zig").Memory;
pub const MemoryError = @import("memory/memory.zig").MemoryError;

// EVM main module and configuration
pub const Evm = @import("evm.zig").Evm;
pub const EvmConfig = @import("evm_config.zig").EvmConfig;

// Build-configured EVM
pub const getBuildConfig = EvmConfig.fromBuildOptions;
pub const BuildConfiguredEvm = Evm(EvmConfig.fromBuildOptions());

// Pre-configured EVM types for FFI
// These are concrete types that can be stored at runtime
pub const MainnetEvm = Evm(.{});

pub const MainnetEvmWithTracer = Evm(EvmConfig{
    .eips = .{ .hardfork = @import("eips_and_hardforks/eips.zig").Hardfork.CANCUN },
    .tracer_config = @import("tracer/tracer.zig").TracerConfig{
        .enabled = true,
        .enable_validation = true, // Enable validation for step capture
        .enable_step_capture = true, // Enable step capture for JSON-RPC trace
        .enable_pc_tracking = true,
        .enable_gas_tracking = true,
        .enable_debug_logging = false, // Disable debug logging to reduce noise
        .enable_advanced_trace = false, // Disable advanced trace to simplify
    },
});

pub const TestEvm = Evm(EvmConfig{
    .eips = .{ .hardfork = @import("eips_and_hardforks/eips.zig").Hardfork.CANCUN },
    .tracer_config = @import("tracer/tracer.zig").TracerConfig{
        .enabled = true,
        .enable_validation = true,
        .enable_pc_tracking = true,
        .enable_gas_tracking = true,
        .enable_debug_logging = false, // Disable debug logging to reduce noise
    },
    .disable_gas_checks = true,
});

// Fixtures for testing - not included in package distribution
// Only available when building from git repository with fixtures/ directory
// pub const FixtureContract = @import("fixtures").FixtureContract;
// pub const ContractName = @import("fixtures").ContractName;

// Default EVM types - now uses build configuration
pub const DefaultEvm = BuildConfiguredEvm;

// Tracer modules
pub const tracer = @import("tracer/tracer.zig");
pub const Tracer = @import("tracer/tracer.zig").Tracer;
pub const TracerConfig = @import("tracer/tracer.zig").TracerConfig;
pub const MinimalEvm = @import("tracer/minimal_evm.zig").MinimalEvm;
// Compatibility alias - to be removed later
pub const DefaultTracer = Tracer;
// differential_tracer removed - using MinimalEvm for differential testing
pub const JSONRPCTracer = @import("tracer/tracer.zig").JSONRPCTracer;

// Logging
pub const log = @import("log.zig");

// Bytecode modules
pub const BytecodeConfig = @import("bytecode/bytecode_config.zig").BytecodeConfig;
pub const Bytecode = @import("bytecode/bytecode.zig").Bytecode;
pub const BytecodeStats = @import("bytecode/bytecode_stats.zig").BytecodeStats;
pub const bytecode = @import("bytecode/bytecode.zig");

// Dispatch module
pub const dispatch = @import("preprocessor/dispatch.zig");

// Opcode and instruction data
pub const Opcode = @import("opcodes/opcode.zig").Opcode;
pub const OpcodeData = @import("opcodes/opcode_data.zig");
pub const OpcodeSynthetic = @import("opcodes/opcode_synthetic.zig");
pub const opcode_synthetic = @import("opcodes/opcode_synthetic.zig");
pub const opcode_data = @import("opcodes/opcode_data.zig");

// Precompiles module (from primitives package)
pub const precompiles = @import("precompiles");

// Database and state modules
pub const BlockInfo = @import("block/block_info.zig").BlockInfo(.{});
pub const CompactBlockInfo = @import("block/block_info.zig").BlockInfo(.{ .use_compact_types = true });
pub const DefaultBlockInfo = BlockInfo; // Alias for compatibility
pub const BlockInfoConfig = @import("frame/block_info_config.zig").BlockInfoConfig;
pub const CallParams = @import("frame/call_params.zig").CallParams({});
pub const CallResult = @import("frame/call_result.zig").CallResult({});
pub const CreatedContracts = @import("storage/created_contracts.zig").CreatedContracts;
pub const Database = @import("storage/database.zig").Database;
pub const Account = @import("storage/database_interface_account.zig").Account;
pub const AccessList = @import("storage/access_list.zig").AccessList;
pub const Hardfork = @import("eips_and_hardforks/eips.zig").Hardfork;
pub const Eips = @import("eips_and_hardforks/eips.zig").Eips;
pub const MemoryDatabase = @import("storage/memory_database.zig").MemoryDatabase;
pub const SelfDestruct = @import("storage/self_destruct.zig").SelfDestruct;
pub const Log = @import("primitives").logs.Log;
pub const TransactionContext = @import("block/transaction_context.zig").TransactionContext;
pub const AuthorizationProcessor = @import("eips_and_hardforks/authorization_processor.zig").AuthorizationProcessor;
pub const AuthorizationError = @import("eips_and_hardforks/authorization_processor.zig").AuthorizationError;
// KZG setup from primitives package crypto module
pub const kzg_setup = @import("crypto").kzg_setup;

// Re-export from evm module for compatibility
pub const Primitives = @import("primitives");
pub const Provider = @import("provider");
pub const dispatch_pretty_print = @import("preprocessor/dispatch_pretty_print.zig");

// Run tests
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
    _ = @import("tracer/minimal_evm_precompile_test.zig");

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
