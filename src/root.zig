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

// Fixtures for testing
pub const FixtureContract = @import("_test_utils/fixtures/popular_contracts.zig").FixtureContract;
pub const ContractName = @import("_test_utils/fixtures/popular_contracts.zig").ContractName;
pub const FixtureRunner = @import("_test_utils/fixture_runner.zig").FixtureRunner;

// Default EVM types - now uses build configuration
pub const DefaultEvm = BuildConfiguredEvm;

// Tracer modules
pub const tracer = @import("tracer/tracer.zig");
pub const Tracer = @import("tracer/tracer.zig").Tracer;
pub const DetailedStructLog = @import("tracer/tracer.zig").DetailedStructLog;
pub const TracerConfig = @import("tracer/tracer.zig").TracerConfig;
pub const MemoryCaptureMode = @import("tracer/tracer.zig").MemoryCaptureMode;
pub const LoggingTracer = @import("tracer/tracer.zig").LoggingTracer;
pub const FileTracer = @import("tracer/tracer.zig").FileTracer;
pub const DefaultTracer = @import("tracer/tracer.zig").DefaultTracer;
pub const DebuggingTracer = @import("tracer/tracer.zig").DebuggingTracer;
// differential_tracer removed - using MinimalEvm for differential testing
pub const trace_comparer = @import("_test_utils/trace_comparer.zig");
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

// Precompiles module
pub const precompiles = @import("precompiles/precompiles.zig");

// Database and state modules
pub const BlockInfo = @import("block/block_info.zig").DefaultBlockInfo;
pub const CompactBlockInfo = @import("block/block_info.zig").CompactBlockInfo;
pub const BlockInfoConfig = @import("frame/block_info_config.zig").BlockInfoConfig;
pub const CallParams = @import("frame/call_params.zig").CallParams({});
pub const CallResult = @import("frame/call_result.zig").CallResult({});
pub const CreatedContracts = @import("storage/created_contracts.zig").CreatedContracts;
pub const Database = @import("storage/database.zig").Database;
pub const Account = @import("storage/database_interface_account.zig").Account;
pub const AccessList = @import("storage/access_list.zig").AccessList;
pub const Hardfork = @import("eips_and_hardforks/hardfork.zig").Hardfork;
pub const Eips = @import("eips_and_hardforks/eips.zig").Eips;
pub const MemoryDatabase = @import("storage/memory_database.zig").MemoryDatabase;
pub const SelfDestruct = @import("storage/self_destruct.zig").SelfDestruct;
pub const Log = @import("primitives").logs.Log;
pub const TransactionContext = @import("block/transaction_context.zig").TransactionContext;
pub const AuthorizationProcessor = @import("eips_and_hardforks/authorization_processor.zig").AuthorizationProcessor;
pub const AuthorizationError = @import("eips_and_hardforks/authorization_processor.zig").AuthorizationError;
pub const kzg_setup = @import("precompiles/kzg_setup.zig");

// Re-export from evm module for compatibility
pub const Primitives = @import("primitives");
pub const Provider = @import("provider");

// Run tests
test {
    // Test EVM modules
    _ = @import("evm_tests.zig");
    _ = @import("preprocessor/dispatch.zig");
    _ = @import("instructions/handlers_arithmetic.zig");
    _ = @import("instructions/handlers_bitwise.zig");
    _ = @import("instructions/handlers_comparison.zig");
    _ = @import("instructions/handlers_context.zig");
    _ = @import("instructions/handlers_jump.zig");
    _ = @import("instructions/handlers_keccak.zig");
    _ = @import("instructions/handlers_log.zig");
    _ = @import("instructions/handlers_memory.zig");
    _ = @import("instructions/handlers_stack.zig");
    _ = @import("instructions/handlers_storage.zig");
    _ = @import("instructions/handlers_system.zig");

    // Test bytecode modules
    _ = @import("bytecode/bytecode_tests.zig");
    _ = @import("bytecode/bytecode_jump_validation_test.zig");

    // Test internal modules
    _ = @import("internal/safety_counter.zig");

    // C API modules are not compiled in tests in this configuration
    // _ = @import("root_c.zig");
}
