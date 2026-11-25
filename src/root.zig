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

// Build-configured EVM: `zig build -Devm-hardfork=... -Devm-enable-fusion=...`
// select the configuration of DefaultEvm. Modules created without these
// options (for example by external build files) get the EvmConfig defaults.
const build_options = @import("build_options");

/// Value of `-Devm-optimize`. EvmConfig has no strategy field yet, so the
/// value is validated and exported for callers that select code by strategy.
pub const OptimizeStrategy = enum { fast, small, safe };
pub const optimize_strategy: OptimizeStrategy = parseOptimizeStrategy(buildOption([]const u8, "optimize_strategy", "safe"));

fn buildOption(comptime T: type, comptime name: []const u8, comptime default: T) T {
    return if (@hasDecl(build_options, name)) @field(build_options, name) else default;
}

/// Accept enum tag names (`OSAKA`, `TANGERINE_WHISTLE`) and EEST fork names
/// (`Osaka`, `TangerineWhistle`). An unknown name is a compile error.
pub fn parseHardfork(comptime name: []const u8) Hardfork {
    @setEvalBranchQuota(10_000);
    if (std.meta.stringToEnum(Hardfork, name)) |fork| return fork;
    if (Hardfork.fromString(name)) |fork| return fork;
    @compileError("invalid -Devm-hardfork value: " ++ name);
}

fn parseOptimizeStrategy(comptime name: []const u8) OptimizeStrategy {
    return std.meta.stringToEnum(OptimizeStrategy, name) orelse
        @compileError("invalid -Devm-optimize value (expected fast, small or safe): " ++ name);
}

pub fn getBuildConfig() EvmConfig {
    const defaults = EvmConfig{};
    return EvmConfig{
        .eips = .{ .hardfork = if (@hasDecl(build_options, "hardfork")) parseHardfork(build_options.hardfork) else defaults.eips.hardfork },
        .enable_fusion = buildOption(bool, "enable_fusion", defaults.enable_fusion),
        .disable_gas_checks = buildOption(bool, "disable_gas_checks", defaults.disable_gas_checks),
        .disable_balance_checks = buildOption(bool, "disable_balance_checks", defaults.disable_balance_checks),
        .max_call_depth = buildOption(u11, "max_call_depth", defaults.max_call_depth),
        .stack_size = buildOption(u12, "stack_size", defaults.stack_size),
        .max_bytecode_size = buildOption(u32, "max_bytecode_size", defaults.max_bytecode_size),
        .max_initcode_size = buildOption(u32, "max_initcode_size", defaults.max_initcode_size),
        .block_gas_limit = buildOption(u64, "block_gas_limit", defaults.block_gas_limit),
        .memory_initial_capacity = buildOption(usize, "memory_initial_capacity", defaults.memory_initial_capacity),
        .memory_limit = buildOption(u64, "memory_limit", defaults.memory_limit),
        .arena_capacity_limit = buildOption(usize, "arena_capacity_limit", defaults.arena_capacity_limit),
        .tracer_config = if (buildOption(bool, "enable_tracing", false)) TracerConfig.debug else defaults.tracer_config,
    };
}

pub const BuildConfiguredEvm = Evm(getBuildConfig());

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

// Default EVM type: the build-configured EVM (OSAKA unless -Devm-hardfork is set)
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
/// EIP constants and validators (EIP-7825, EIP-7934, EIP-7918, EIP-7892, EIP-7685).
pub const eips = @import("eips_and_hardforks/eips.zig");
pub const MemoryDatabase = @import("storage/memory_database.zig").MemoryDatabase;
pub const SelfDestruct = @import("storage/self_destruct.zig").SelfDestruct;
pub const Log = @import("voltaire").logs.Log;
pub const TransactionContext = @import("block/transaction_context.zig").TransactionContext;
pub const AuthorizationProcessor = @import("eips_and_hardforks/authorization_processor.zig").AuthorizationProcessor;
pub const AuthorizationError = @import("eips_and_hardforks/authorization_processor.zig").AuthorizationError;
pub const trie = @import("trie/root.zig");
/// Ethereum state root over a Database (used by Database.get_state_root).
pub const state_root = @import("storage/state_root.zig");
// KZG setup from primitives package crypto module
pub const kzg_setup = @import("crypto").kzg_setup;

// Re-export from evm module for compatibility
pub const Primitives = @import("voltaire");
pub const Provider = @import("provider");
pub const dispatch_pretty_print = @import("preprocessor/dispatch_pretty_print.zig");
pub const verified_ops = @import("core/verified_ops.zig");

// Unit tests: every src module whose inline tests compile and pass on Zig 0.17.1.
//
// Not imported yet, because their inline tests use pre-0.17 APIs (for example
// `address.from_hex`, `BlockInfo.base_fee_per_gas`, `AccessList` without a
// config, `Frame` with one argument) and fail to compile: evm_tests.zig,
// evm_config.zig, preprocessor/dispatch_test.zig, every other
// instructions/handlers_*.zig, bytecode/bytecode_tests.zig,
// bytecode/bytecode_jump_validation_test{,s}.zig, tracer/minimal_frame.zig,
// tracer/minimal_evm_precompile_test.zig and root_c.zig.
// These compile but fail: tracer/pc_tracker.zig (logs an error),
// tracer/events/{events,lifecycle}.zig (1 failure each), and
// trie/{test_simple_update,known_roots_test}.zig (3 failures and 1 crash), and
// trie/trie.zig (2 failures: Leaf/Extension/Branch `encode` RLP-encode each item
// twice, and proof.zig/merkle_trie.zig decode that same non-Ethereum format, so
// the encoders and the proof verifier must be fixed together).
// Repair a file's tests before importing it here.
test {
    _ = @import("preprocessor/dispatch.zig");
    _ = @import("preprocessor/handler_abi.zig");
    _ = @import("instructions/handlers_advanced_synthetic.zig");
    _ = @import("bytecode/bytecode_bench_test.zig");
    _ = @import("memory/frame_memory_pool.zig");
    _ = @import("native_stack.zig");
    _ = @import("internal/safety_counter.zig");
    _ = @import("core/verified_ops.zig");
    _ = @import("trie/hash_builder_complete.zig");
    _ = @import("trie/known_roots_test.zig");
    _ = @import("trie/test_simple_update.zig");
}
