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
pub const layer2 = @import("layer2/mod.zig");

// Build-configured EVM
pub const getBuildConfig = EvmConfig{};
pub const BuildConfiguredEvm = Evm(EvmConfig{});

// Pre-configured EVM types for FFI
// These are concrete types that can be stored at runtime
pub const MainnetEvm = Evm(.{});

pub const MainnetEvmWithTracer = Evm(EvmConfig{
    .eips = .{ .hardfork = @import("eips_and_hardforks/eips.zig").Hardfork.DEFAULT },
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
pub const DatabaseProxy = @import("storage/database_proxy.zig").DatabaseProxy;
pub const ProxyMode = @import("storage/database_proxy.zig").ProxyMode;
pub const Account = @import("storage/database_interface_account.zig").Account;
pub const AccessList = @import("storage/access_list.zig").AccessList;
pub const Hardfork = @import("eips_and_hardforks/eips.zig").Hardfork;
pub const Eips = @import("eips_and_hardforks/eips.zig").Eips;
/// EIP constants and validators (EIP-7825, EIP-7934, EIP-7918, EIP-7892, EIP-7685).
pub const eips = @import("eips_and_hardforks/eips.zig");
pub const MemoryDatabase = @import("storage/memory_database.zig").MemoryDatabase;
pub const SelfDestruct = @import("storage/self_destruct.zig").SelfDestruct;
pub const Log = @import("voltaire").logs.Log;
pub const TransactionContext = @import("block/transaction_context.zig").TransactionContext;
pub const AuthorizationProcessor = @import("eips_and_hardforks/authorization_processor.zig").AuthorizationProcessor;
pub const AuthorizationError = @import("eips_and_hardforks/authorization_processor.zig").AuthorizationError;
pub const trie = @import("trie/root.zig");
// KZG setup from primitives package crypto module
pub const kzg_setup = @import("crypto").kzg_setup;

// Re-export from evm module for compatibility
pub const Primitives = @import("voltaire");
pub const Provider = @import("provider");
pub const dispatch_pretty_print = @import("preprocessor/dispatch_pretty_print.zig");
pub const verified_ops = @import("verified_ops.zig");

// Run tests
test {
    // Test EVM config / bytecode / tracer / trie / internal unit tests
    // Note: evm.zig & instructions/handlers_*.zig inline unit tests still reference
    // pre-refactor 1-arg Frame(cfg) / Address.from_u256 and are covered by test-opcodes
    // and test-integration (1,017 tests).
    _ = @import("bytecode/bytecode_bench_test.zig");
    _ = @import("internal/safety_counter.zig");
    _ = @import("verified_ops.zig");
    _ = @import("storage/database_proxy.zig");

    // Tracer modules with tests
    _ = @import("tracer/pc_tracker.zig");
    _ = @import("tracer/events/events.zig");
    _ = @import("tracer/events/lifecycle.zig");
    // minimal_frame.zig / minimal_evm_precompile_test.zig import eips.zig -> access_list.zig -> evm.zig
    // (whose inline handlers_* unit tests still use the legacy 1-arg Frame(cfg) signature).

    // Trie tests (core node types, RLP encoding, and nibble helpers)
    _ = @import("trie/trie.zig");

    // Provider tests - removed to avoid module conflict
    // Provider module handles its own tests

    // C API modules are not compiled in tests in this configuration
    // _ = @import("root_c.zig");
}
