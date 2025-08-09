const std = @import("std");
const builtin = @import("builtin");
const Hardfork = @import("hardforks/hardfork.zig").Hardfork;
const Stack = @import("stack/stack.zig");
const operation_config = @import("opcode_metadata/operation_config.zig");
const operation_module = @import("opcodes/operation.zig");
const ExecutionFunc = @import("execution_func.zig").ExecutionFunc;
const GasFunc = operation_module.GasFunc;
const MemorySizeFunc = operation_module.MemorySizeFunc;
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
const execution = @import("execution/package.zig");

// Import new EIP configuration modules
const eip_flags = @import("config/eip_flags.zig");
const overrides = @import("config/overrides.zig");
pub const EipFlags = eip_flags.EipFlags;
pub const EipOverrides = overrides.EipOverrides;
pub const GasCostOverrides = overrides.GasCostOverrides;
pub const ChainBehavior = overrides.ChainBehavior;

/// Centralized configuration for the EVM runtime.
/// 
/// This struct consolidates all scattered configuration constants and provides
/// compile-time configuration management with zero runtime overhead. All fields
/// are evaluated at compile time, allowing for optimal code generation.
pub const EvmConfig = struct {
    // Execution limits
    max_call_depth: u11 = 1024,
    max_stack_buffer_size: usize = 43008,
    stack_allocation_threshold: usize = 12800,
    max_input_size: u18 = 128 * 1024,
    max_iterations: usize = 10_000_000,
    
    // Memory configuration  
    memory_limit: u64 = 32 * 1024 * 1024, // 32MB
    initial_memory_capacity: usize = 4096,
    
    // Runtime behavior flags
    clear_on_pop: bool = builtin.mode != .ReleaseFast,
    optional_balance_check: bool = false,  // Disable balance validation for testing
    optional_nonce_check: bool = false,    // Disable nonce validation for testing  
    optional_base_fee: bool = false,       // Disable EIP-1559 base fee for testing
    
    // Chain configuration  
    chain_id: u64 = 1, // Mainnet default
    
    // Hardfork specification
    hardfork: Hardfork = .CANCUN,
    
    // EIP overrides for L2s and custom chains
    eip_overrides: ?EipOverrides = null,
    
    // Opcode metadata
    opcodes: OpcodeMetadata,
    
    /// Initialize config for specific hardfork
    pub fn init(comptime hardfork: Hardfork) EvmConfig {
        return EvmConfig{
            .hardfork = hardfork,
            .opcodes = OpcodeMetadata.initFromHardfork(hardfork),
        };
    }
    
    /// Initialize config with L2 overrides
    pub fn initWithOverrides(comptime hardfork: Hardfork, comptime eip_overrides: EipOverrides) EvmConfig {
        return EvmConfig{
            .hardfork = hardfork,
            .eip_overrides = eip_overrides,
            .opcodes = OpcodeMetadata.initFromConfig(EvmConfig{
                .hardfork = hardfork,
                .eip_overrides = eip_overrides,
                .opcodes = undefined, // Will be set by initFromConfig
            }),
        };
    }
    
    /// Initialize with optional features for testing
    pub fn initWithFeatures(
        comptime hardfork: Hardfork,
        comptime features: struct {
            optional_balance_check: bool = false,
            optional_nonce_check: bool = false,
            optional_base_fee: bool = false,
        }
    ) EvmConfig {
        return EvmConfig{
            .hardfork = hardfork,
            .opcodes = OpcodeMetadata.initFromHardfork(hardfork),
            .optional_balance_check = features.optional_balance_check,
            .optional_nonce_check = features.optional_nonce_check,
            .optional_base_fee = features.optional_base_fee,
        };
    }
    
    /// Calculate initial allocation size based on config
    pub fn calculateInitialSize(comptime self: EvmConfig) usize {
        return self.max_stack_buffer_size + self.initial_memory_capacity;
    }
    
    /// Validate configuration at compile time
    pub fn validate(comptime self: EvmConfig) void {
        if (self.max_call_depth > 1024) @compileError("max_call_depth cannot exceed 1024");
        if (self.max_iterations < 1000) @compileError("max_iterations too low for practical use");
        if (self.memory_limit > 1 << 32) @compileError("memory_limit exceeds 32-bit addressing");
        if (self.chain_id == 0) @compileError("chain_id cannot be zero");
        if (self.max_stack_buffer_size < self.stack_allocation_threshold) {
            @compileError("max_stack_buffer_size must be >= stack_allocation_threshold");
        }
    }
    
    /// Get EIP flags for this configuration
    pub fn getEipFlags(comptime self: EvmConfig) EipFlags {
        var flags = eip_flags.deriveEipFlagsFromHardfork(self.hardfork);
        
        // Apply optional base fee override
        if (self.optional_base_fee) {
            flags.eip1559_base_fee = false;
            flags.eip3198_basefee = false;
        }
        
        // Apply L2/custom overrides if present
        if (self.eip_overrides) |eip_overrides| {
            overrides.applyOverrides(&flags, eip_overrides);
        }
        
        return flags;
    }
    
    /// Check if specific EIP is enabled for this configuration  
    pub fn hasEip(comptime self: EvmConfig, comptime eip: u16) bool {
        const flags = self.getEipFlags();
        return flags.isEnabled(eip);
    }
    
    /// Get gas cost for operation considering hardfork
    pub fn getGasCost(comptime self: EvmConfig, comptime op: GasOperation) u64 {
        return switch (op) {
            .sload => if (@intFromEnum(self.hardfork) >= @intFromEnum(Hardfork.BERLIN)) 0 
                      else if (@intFromEnum(self.hardfork) >= @intFromEnum(Hardfork.ISTANBUL)) 800
                      else if (@intFromEnum(self.hardfork) >= @intFromEnum(Hardfork.TANGERINE_WHISTLE)) 200
                      else 50,
            .balance => if (@intFromEnum(self.hardfork) >= @intFromEnum(Hardfork.BERLIN)) 0
                        else if (@intFromEnum(self.hardfork) >= @intFromEnum(Hardfork.ISTANBUL)) 700
                        else if (@intFromEnum(self.hardfork) >= @intFromEnum(Hardfork.TANGERINE_WHISTLE)) 400
                        else 20,
            else => op.base_cost(),
        };
    }
    
    // Predefined configurations  
    pub const DEFAULT = init(.CANCUN);
    
    pub const DEBUG = blk: {
        var config = init(.CANCUN);
        config.optional_balance_check = true;
        config.optional_nonce_check = true;
        config.clear_on_pop = true;
        break :blk config;
    };
    
    pub const PERFORMANCE = blk: {
        var config = init(.CANCUN);
        config.clear_on_pop = false;
        break :blk config;
    };
    
    pub const TESTING = initWithFeatures(.CANCUN, .{ 
        .optional_balance_check = true,
        .optional_nonce_check = true,
        .optional_base_fee = true,
    });
    
    pub const MINIMAL = blk: {
        var config = init(.FRONTIER);
        config.memory_limit = 1024 * 1024; // 1MB
        config.max_iterations = 100_000;
        break :blk config;
    };
    
    // L2 configurations
    pub const OPTIMISM = initWithOverrides(.CANCUN, EipOverrides.OPTIMISM);
    pub const POLYGON = initWithOverrides(.CANCUN, EipOverrides.POLYGON);
    pub const ARBITRUM = initWithOverrides(.CANCUN, EipOverrides.ARBITRUM);
    pub const BASE = initWithOverrides(.CANCUN, EipOverrides.BASE);
    pub const ZKSYNC = initWithOverrides(.CANCUN, EipOverrides.ZKSYNC);
};

/// Enum for gas operation types
pub const GasOperation = enum {
    sload,
    balance,
    extcodesize,
    extcodecopy,
    extcodehash,
    
    pub fn base_cost(self: GasOperation) u64 {
        return switch (self) {
            .sload => 50,
            .balance => 20,
            .extcodesize => 20,
            .extcodecopy => 20,
            .extcodehash => 400,
        };
    }
};

/// CPU cache line size for optimal memory alignment.
/// Most modern x86/ARM processors use 64-byte cache lines.
const CACHE_LINE_SIZE = 64;

/// Opcode metadata for EVM execution
/// Contains execution functions, gas costs, and stack requirements for each opcode
pub const OpcodeMetadata = struct {
    // Hot path arrays - accessed every opcode execution
    execute_funcs: [256]ExecutionFunc align(CACHE_LINE_SIZE),    // 2KB, hot path
    constant_gas: [256]u64 align(CACHE_LINE_SIZE),               // 2KB, hot path
    
    // Validation arrays - accessed for stack checks
    min_stack: [256]u32 align(CACHE_LINE_SIZE),                  // 1KB, validation
    max_stack: [256]u32 align(CACHE_LINE_SIZE),                  // 1KB, validation
    
    // Cold path arrays - rarely accessed
    dynamic_gas: [256]?GasFunc align(CACHE_LINE_SIZE),           // 2KB, rare
    memory_size: [256]?MemorySizeFunc align(CACHE_LINE_SIZE),    // 2KB, rare  
    undefined_flags: [256]bool align(CACHE_LINE_SIZE),           // 256 bytes, rare
    
    /// Build opcode metadata from configuration
    pub fn initFromConfig(comptime config: EvmConfig) OpcodeMetadata {
        const eip_flags_value = config.getEipFlags();
        return initFromEipFlags(eip_flags_value);
    }
    
    /// Build opcode metadata from hardfork using existing OpSpec system
    pub fn initFromHardfork(comptime hardfork: Hardfork) OpcodeMetadata {
        const flags = eip_flags.deriveEipFlagsFromHardfork(hardfork);
        return initFromEipFlags(flags);
    }
    
    /// Build opcode metadata from EIP flags
    pub fn initFromEipFlags(comptime flags: EipFlags) OpcodeMetadata {
        @setEvalBranchQuota(10000);
        var metadata = OpcodeMetadata.init();
        
        // Use existing ALL_OPERATIONS from operation_config.zig
        inline for (operation_config.ALL_OPERATIONS) |spec| {
            const op_hardfork = spec.variant orelse Hardfork.FRONTIER;
            
            // Check if operation should be included based on EIP flags
            const include_op = switch (spec.opcode) {
                0x3d => flags.eip211_returndatasize, // RETURNDATASIZE
                0x3e => flags.eip211_returndatacopy, // RETURNDATACOPY
                0xfa => flags.eip214_staticcall, // STATICCALL
                0xf5 => flags.eip1014_create2, // CREATE2
                0x3f => flags.eip1052_extcodehash, // EXTCODEHASH
                0x46 => flags.eip1344_chainid, // CHAINID
                0x48 => flags.eip3198_basefee, // BASEFEE
                0x5c => flags.eip1153_transient_storage, // TLOAD
                0x5d => flags.eip1153_transient_storage, // TSTORE
                0x5e => flags.eip5656_mcopy, // MCOPY
                0x4a => flags.eip7516_blobbasefee, // BLOBBASEFEE
                else => true, // Default: check hardfork
            };
            
            // Only include operations valid for this hardfork and enabled by EIPs
            if (include_op and @intFromEnum(op_hardfork) <= @intFromEnum(Hardfork.CANCUN)) {
                const op = operation_config.generate_operation(spec);
                metadata.execute_funcs[spec.opcode] = op.execute;
                metadata.constant_gas[spec.opcode] = op.constant_gas;
                metadata.min_stack[spec.opcode] = op.min_stack;
                metadata.max_stack[spec.opcode] = op.max_stack;
                metadata.undefined_flags[spec.opcode] = false;
                
                // Handle dynamic gas if present
                if (op.dynamic_gas) |dyn_gas| {
                    metadata.dynamic_gas[spec.opcode] = dyn_gas;
                }
                
                // Handle memory size if present
                if (op.memory_size) |mem_size| {
                    metadata.memory_size[spec.opcode] = mem_size;
                }
            }
        }
        
        // Generate PUSH/DUP/SWAP/LOG operations
        comptime var i: u8 = 0;
        
        // PUSH0 - EIP-3855
        if (flags.eip3855_push0) {
            metadata.execute_funcs[0x5f] = execution.null_opcode.op_invalid;
            metadata.constant_gas[0x5f] = GasConstants.GasQuickStep;
            metadata.min_stack[0x5f] = 0;
            metadata.max_stack[0x5f] = Stack.CAPACITY - 1;
            metadata.undefined_flags[0x5f] = false;
        }
        
        // PUSH1 through PUSH32
        // Note: PUSH operations are executed inline by the interpreter using
        // pre-decoded push_value from analysis. We still set metadata here
        // so stack validation and block gas accounting have correct values.
        i = 0;
        while (i < 32) : (i += 1) {
            const opcode = 0x60 + i;
            metadata.execute_funcs[opcode] = execution.null_opcode.op_invalid;
            metadata.constant_gas[opcode] = GasConstants.GasFastestStep;
            metadata.min_stack[opcode] = 0;
            metadata.max_stack[opcode] = Stack.CAPACITY - 1;
            metadata.undefined_flags[opcode] = false;
        }
        
        // DUP1 through DUP16
        const dup_functions = [_]ExecutionFunc{
            execution.stack.op_dup1,
            execution.stack.op_dup2,
            execution.stack.op_dup3,
            execution.stack.op_dup4,
            execution.stack.op_dup5,
            execution.stack.op_dup6,
            execution.stack.op_dup7,
            execution.stack.op_dup8,
            execution.stack.op_dup9,
            execution.stack.op_dup10,
            execution.stack.op_dup11,
            execution.stack.op_dup12,
            execution.stack.op_dup13,
            execution.stack.op_dup14,
            execution.stack.op_dup15,
            execution.stack.op_dup16,
        };
        i = 0;
        while (i < 16) : (i += 1) {
            const opcode = 0x80 + i;
            metadata.execute_funcs[opcode] = dup_functions[i];
            metadata.constant_gas[opcode] = GasConstants.GasFastestStep;
            metadata.min_stack[opcode] = @intCast(i + 1);
            metadata.max_stack[opcode] = Stack.CAPACITY - 1;
            metadata.undefined_flags[opcode] = false;
        }
        
        // SWAP1 through SWAP16
        const swap_functions = [_]ExecutionFunc{
            execution.stack.op_swap1,
            execution.stack.op_swap2,
            execution.stack.op_swap3,
            execution.stack.op_swap4,
            execution.stack.op_swap5,
            execution.stack.op_swap6,
            execution.stack.op_swap7,
            execution.stack.op_swap8,
            execution.stack.op_swap9,
            execution.stack.op_swap10,
            execution.stack.op_swap11,
            execution.stack.op_swap12,
            execution.stack.op_swap13,
            execution.stack.op_swap14,
            execution.stack.op_swap15,
            execution.stack.op_swap16,
        };
        i = 0;
        while (i < 16) : (i += 1) {
            const opcode = 0x90 + i;
            metadata.execute_funcs[opcode] = swap_functions[i];
            metadata.constant_gas[opcode] = GasConstants.GasFastestStep;
            metadata.min_stack[opcode] = @intCast(i + 2);
            metadata.max_stack[opcode] = Stack.CAPACITY;
            metadata.undefined_flags[opcode] = false;
        }
        
        // LOG0 through LOG4
        const log_functions = [_]ExecutionFunc{
            execution.log.log_0,
            execution.log.log_1,
            execution.log.log_2,
            execution.log.log_3,
            execution.log.log_4,
        };
        i = 0;
        while (i <= 4) : (i += 1) {
            const opcode = 0xa0 + i;
            metadata.execute_funcs[opcode] = log_functions[i];
            metadata.constant_gas[opcode] = GasConstants.LogGas + i * GasConstants.LogTopicGas;
            metadata.min_stack[opcode] = @intCast(2 + i);
            metadata.max_stack[opcode] = Stack.CAPACITY;
            metadata.undefined_flags[opcode] = false;
        }
        
        return metadata;
    }
    
    /// Create an empty metadata table with all entries set to defaults
    pub fn init() OpcodeMetadata {
        const undefined_execute = operation_module.NULL_OPERATION.execute;
        return OpcodeMetadata{
            .execute_funcs = [_]ExecutionFunc{undefined_execute} ** 256,
            .constant_gas = [_]u64{0} ** 256,
            .min_stack = [_]u32{0} ** 256,
            .max_stack = [_]u32{Stack.CAPACITY} ** 256,
            .dynamic_gas = [_]?GasFunc{null} ** 256,
            .memory_size = [_]?MemorySizeFunc{null} ** 256,
            .undefined_flags = [_]bool{true} ** 256,
        };
    }
    
    /// Get operation metadata for opcode (maintains compatibility)
    pub inline fn get_operation(self: *const OpcodeMetadata, opcode: u8) OperationView {
        return OperationView{
            .execute = self.execute_funcs[opcode],
            .constant_gas = self.constant_gas[opcode],
            .min_stack = self.min_stack[opcode],
            .max_stack = self.max_stack[opcode],
            .undefined = self.undefined_flags[opcode],
            .dynamic_gas = self.dynamic_gas[opcode],
            .memory_size = self.memory_size[opcode],
        };
    }
};

/// View of operation metadata for compatibility with existing code
pub const OperationView = struct {
    execute: ExecutionFunc,
    constant_gas: u64,
    min_stack: u32,
    max_stack: u32,
    undefined: bool,
    dynamic_gas: ?GasFunc,
    memory_size: ?MemorySizeFunc,
};

test "EvmConfig validation" {
    const testing = std.testing;
    
    // Test default config
    const default_config = EvmConfig.DEFAULT;
    try testing.expectEqual(@as(u11, 1024), default_config.max_call_depth);
    try testing.expectEqual(@as(u64, 1), default_config.chain_id);
    try testing.expectEqual(Hardfork.CANCUN, default_config.hardfork);
    
    // Test debug config
    const debug_config = EvmConfig.DEBUG;
    try testing.expect(debug_config.optional_balance_check);
    try testing.expect(debug_config.optional_nonce_check);
    try testing.expect(debug_config.clear_on_pop);
    
    // Test testing config
    const test_config = EvmConfig.TESTING;
    try testing.expect(test_config.optional_balance_check);
    try testing.expect(test_config.optional_nonce_check);
    try testing.expect(test_config.optional_base_fee);
    
    // Test minimal config
    const minimal_config = EvmConfig.MINIMAL;
    try testing.expectEqual(@as(u64, 1024 * 1024), minimal_config.memory_limit);
    try testing.expectEqual(@as(usize, 100_000), minimal_config.max_iterations);
    try testing.expectEqual(Hardfork.FRONTIER, minimal_config.hardfork);
}

test "EvmConfig compile-time validation" {
    // This should compile successfully
    const valid_config = EvmConfig.init(.CANCUN);
    comptime valid_config.validate();
    
    // Test that calculateInitialSize works
    const initial_size = comptime valid_config.calculateInitialSize();
    try std.testing.expect(initial_size > 0);
}

test "EIP detection" {
    const testing = std.testing;
    
    const cancun_config = EvmConfig.init(.CANCUN);
    try testing.expect(comptime cancun_config.hasEip(155));  // SPURIOUS_DRAGON
    try testing.expect(comptime cancun_config.hasEip(1014)); // CONSTANTINOPLE
    try testing.expect(comptime cancun_config.hasEip(1559)); // LONDON
    try testing.expect(comptime cancun_config.hasEip(3855)); // SHANGHAI
    try testing.expect(comptime cancun_config.hasEip(4844)); // CANCUN
    
    const frontier_config = EvmConfig.init(.FRONTIER);
    try testing.expect(!comptime frontier_config.hasEip(155));
    try testing.expect(!comptime frontier_config.hasEip(1014));
    try testing.expect(!comptime frontier_config.hasEip(1559));
    
    // Test optional base fee disabling
    const no_base_fee = EvmConfig.initWithFeatures(.LONDON, .{ .optional_base_fee = true });
    try testing.expect(!comptime no_base_fee.hasEip(1559));
}

test "Gas cost calculation" {
    const testing = std.testing;
    
    const cancun_config = EvmConfig.init(.CANCUN);
    const frontier_config = EvmConfig.init(.FRONTIER);
    
    // SLOAD gas costs
    try testing.expectEqual(@as(u64, 0), comptime cancun_config.getGasCost(.sload));
    try testing.expectEqual(@as(u64, 50), comptime frontier_config.getGasCost(.sload));
    
    // BALANCE gas costs
    try testing.expectEqual(@as(u64, 0), comptime cancun_config.getGasCost(.balance));
    try testing.expectEqual(@as(u64, 20), comptime frontier_config.getGasCost(.balance));
}