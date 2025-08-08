const std = @import("std");
const JumpTable = @import("jump_table/jump_table.zig").JumpTable;
const Hardfork = @import("hardforks/hardfork.zig").Hardfork;
const ChainRules = @import("frame.zig").ChainRules;
const Frame = @import("frame.zig").Frame;

/// Centralized comptime configuration for the EVM.
/// All configurable constants and parameters are consolidated here.
/// This struct is evaluated at comptime for optimal performance.
pub const ComptimeConfig = struct {
    // Type Configuration
    /// The word type used for EVM stack and arithmetic operations
    /// Standard EVM uses u256, but this can be configured for different use cases
    word_type: type = u256,
    // Execution Limits
    /// Maximum call depth (EIP-150)
    max_call_depth: u11 = 1024,
    /// Maximum stack size
    max_stack_size: usize = 1024,
    /// Maximum stack buffer size for contract analysis
    max_stack_buffer_size: usize = 43008, // 42KB with alignment padding
    /// Stack allocation threshold for using stack vs heap
    stack_allocation_threshold: usize = 12800, // bytes of bytecode
    /// Maximum input size for calls
    max_input_size: u32 = 128 * 1024, // 128 KB
    /// Maximum iterations for interpreter loop
    max_iterations: u32 = 10_000_000,
    /// Maximum code size (EIP-170)
    max_code_size: u32 = 24576,
    /// Maximum precompiles
    max_precompiles: u8 = 10,

    // Memory Configuration
    /// Initial memory capacity
    initial_memory_capacity: usize = 4 * 1024, // 4 KB
    /// Default memory limit
    default_memory_limit: u64 = 32 * 1024 * 1024, // 32 MB
    /// Maximum memory size
    max_memory_size: u64 = 32 * 1024 * 1024, // 32 MB
    /// Initial arena capacity for temporary allocations (256KB)
    /// This covers most common contract executions without reallocation
    arena_initial_capacity: usize = 256 * 1024,

    // Stack Configuration
    /// Stack capacity (must match max_stack_size for consistency)
    stack_capacity: usize = 1024,
    /// Whether to clear stack values on pop (debug/safe modes)
    clear_on_pop: bool = @import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe,

    // Gas Configuration
    /// Gas retention divisor for CALL operations
    call_gas_retention_divisor: u64 = 64,
    /// Gas stipend for value transfers
    gas_stipend_value_transfer: u64 = 2300,
    /// Deploy code gas per byte
    deploy_code_gas_per_byte: u64 = 200,

    // Blob Configuration (EIP-4844)
    /// Maximum blobs per transaction
    max_blobs_per_transaction: u8 = 6,
    /// Gas per blob
    gas_per_blob: u32 = 131072,
    /// Maximum blob gas per block
    max_blob_gas_per_block: u64 = 786432, // 6 blobs * 131072
    /// Target blob gas per block
    target_blob_gas_per_block: u64 = 393216, // 3 blobs * 131072
    /// Blob base fee update fraction
    blob_base_fee_update_fraction: u64 = 3338477,

    // Code Analysis Limits
    /// Maximum contract size for analysis
    max_contract_size: usize = 24576,
    /// Maximum blocks for analysis
    max_blocks: usize = 4096,
    /// Maximum instructions for analysis
    max_instructions: usize = 24576 * 2,

    // Runtime Behavior Flags
    /// Enable stack validation
    enable_stack_validation: bool = true,
    /// Enable memory limit checks
    enable_memory_limits: bool = true,
    /// Enable gas accounting
    enable_gas_accounting: bool = true,
    /// Enable safety checks (equivalent to Debug/ReleaseSafe modes)
    enable_safety_checks: bool = @import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe,
    /// Enable thread safety checks
    enable_thread_checks: bool = @import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe,
    /// Optimize for size (ReleaseSmall mode)
    optimize_for_size: bool = @import("builtin").mode == .ReleaseSmall,
    /// Optimize for speed (ReleaseFast mode)
    optimize_for_speed: bool = @import("builtin").mode == .ReleaseFast,

    // Chain Configuration
    /// Hardfork version
    hardfork: Hardfork = .CANCUN,
    /// Chain ID
    chain_id: u64 = 1, // Mainnet by default

    // Jump Table (comptime data)
    /// Opcode dispatch table for the configured hardfork
    jump_table: JumpTable = JumpTable.CANCUN,
    /// Chain rules for the configured hardfork
    chain_rules: ChainRules = Frame.chainRulesForHardfork(.CANCUN),

    /// Create a default configuration for mainnet Cancun
    pub fn default() ComptimeConfig {
        return .{};
    }

    /// Create a configuration for a specific hardfork
    pub fn forHardfork(hardfork: Hardfork) ComptimeConfig {
        return .{
            .hardfork = hardfork,
            .jump_table = JumpTable.init_from_hardfork(hardfork),
            .chain_rules = Frame.chainRulesForHardfork(hardfork),
        };
    }

    /// Create a test configuration with relaxed limits
    pub fn forTesting() ComptimeConfig {
        return .{
            .max_iterations = 1_000_000,
            .enable_stack_validation = false,
            .enable_memory_limits = false,
            .enable_gas_accounting = false,
            .clear_on_pop = true,
            .enable_safety_checks = true,
            .enable_thread_checks = false, // Disable for test performance
            .optimize_for_size = false,
            .optimize_for_speed = false,
        };
    }

    /// Create a configuration with custom chain ID
    pub fn withChainId(self: ComptimeConfig, chain_id: u64) ComptimeConfig {
        var config = self;
        config.chain_id = chain_id;
        return config;
    }

    /// Create a configuration with custom memory limits
    pub fn withMemoryLimits(self: ComptimeConfig, initial: usize, max: u64) ComptimeConfig {
        var config = self;
        config.initial_memory_capacity = initial;
        config.default_memory_limit = max;
        config.max_memory_size = max;
        return config;
    }

    /// Validate configuration consistency
    pub fn validate(self: ComptimeConfig) !void {
        if (self.stack_capacity != self.max_stack_size) {
            return error.InconsistentStackConfig;
        }
        if (self.max_memory_size < self.initial_memory_capacity) {
            return error.InvalidMemoryConfig;
        }
        if (self.max_blob_gas_per_block < self.target_blob_gas_per_block) {
            return error.InvalidBlobConfig;
        }
    }
};

/// Global default configuration (comptime)
pub const DEFAULT_CONFIG = ComptimeConfig.default();

/// Cancun configuration (comptime)
pub const CANCUN_CONFIG = ComptimeConfig.forHardfork(.CANCUN);

/// Test configuration (comptime)
pub const TEST_CONFIG = ComptimeConfig.forTesting();