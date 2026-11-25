const std = @import("std");
const builtin = @import("builtin");
const SafetyCounter = @import("../internal/safety_counter.zig").SafetyCounter;
const Mode = @import("../internal/safety_counter.zig").Mode;

pub const FrameConfig = struct {
    const Self = @This();
    /// Execution fork for opcode activation. Propagated from EvmConfig so a
    /// specialized frame never reads fork rules through a default-EVM cast.
    hardfork: @import("../eips_and_hardforks/eips.zig").Hardfork = .CANCUN,
    /// The maximum stack size for the evm. Defaults to 1024
    stack_size: u12 = 1024,

    /// The size of a single word in the EVM - Defaults to u256
    WordType: type = u256,

    /// The maximum amount of bytes allowed in contract code
    max_bytecode_size: u32 = 24576,

    /// The maximum amount of bytes allowed in contract deployment
    max_initcode_size: u32 = 49152,

    /// The maximum gas limit for a block
    block_gas_limit: u64 = 30_000_000,

    /// The initial allocation created by the EVM. Defaults to 4096
    memory_initial_capacity: usize = 4096,

    /// The limit on how much the EVM should be allowed to allocate. Default is 0xffffff. This should be plenty for most bytecode and gas limits
    memory_limit: u64 = 0xFFFFFF,

    /// Database implementation type for storage operations (always required).
    DatabaseType: type,

    /// Block info configuration for the frame
    block_info_config: @import("block_info_config.zig").BlockInfoConfig = .{},

    /// Disable gas checks for testing/development (default: false)
    /// When enabled, gas consumption methods become no-ops
    disable_gas_checks: bool = false,

    /// Disable balance checks for testing/development (default: false)
    /// When enabled, balance checks always return 0
    disable_balance_checks: bool = false,

    /// Disable fusion optimizations (default: false)
    /// When enabled, bytecode fusion handlers are not registered
    disable_fusion: bool = false,

    /// SIMD vector length for optimized operations
    /// Value of 1 means scalar operations (no SIMD)
    vector_length: comptime_int = 1,

    /// Loop quota for safety counters to prevent infinite loops
    /// null = disabled (default for optimized builds)
    /// value = maximum iterations before panic (default for debug/safe builds)
    loop_quota: ?u32 = if (builtin.mode == .debug or builtin.mode == .safe) 1_000_000 else null,

    /// Custom opcode handler overrides
    /// These will override the default handlers in frame_handlers.zig
    opcode_overrides: []const struct { opcode: u8, handler: *const anyopaque } = &.{},

    pub fn validate(self: Self) void {
        if (self.stack_size > 4095) @compileError("stack_size cannot exceed 4095");
        if (@bitSizeOf(self.WordType) > 512) @compileError("WordType cannot exceed u512");
        if (self.max_bytecode_size > 65535) @compileError("max_bytecode_size must be at most 65535");

        // Validate gas limit fits in i64
        if (self.block_gas_limit > std.math.maxInt(i64)) {
            @compileError(std.fmt.comptimePrint("block_gas_limit ({d}) must fit in i64 (max {d})", .{
                self.block_gas_limit,
                std.math.maxInt(i64),
            }));
        }

        // Validate memory configuration
        const min_memory_for_stack = self.get_requested_alloc();
        if (self.memory_limit < min_memory_for_stack) {
            @compileError(std.fmt.comptimePrint("memory_limit ({d}) is too small for stack_size ({d}) * WordType ({d} bytes) = {d} bytes minimum required", .{
                self.memory_limit,
                self.stack_size,
                @sizeOf(self.WordType),
                min_memory_for_stack,
            }));
        }

        if (self.memory_initial_capacity > self.memory_limit) {
            @compileError(std.fmt.comptimePrint("memory_initial_capacity ({d}) cannot exceed memory_limit ({d})", .{
                self.memory_initial_capacity,
                self.memory_limit,
            }));
        }

        // Ensure memory limit is reasonable for initcode size
        const min_memory_for_initcode = self.max_initcode_size * 2; // Account for code + potential memory expansion
        if (self.memory_limit < min_memory_for_initcode) {
            @compileError(std.fmt.comptimePrint("memory_limit ({d}) may be insufficient for max_initcode_size ({d}). Consider at least {d} bytes", .{
                self.memory_limit,
                self.max_initcode_size,
                min_memory_for_initcode,
            }));
        }
    }
    // Below are derived properties that are derived from other config options

    /// PcType: chosen PC integer type from max_bytecode_size
    pub fn PcType(self: Self) type {
        return if (self.max_bytecode_size <= std.math.maxInt(u8))
            u8
        else if (self.max_bytecode_size <= std.math.maxInt(u12))
            u12
        else if (self.max_bytecode_size <= std.math.maxInt(u16))
            u16
        else if (self.max_bytecode_size <= std.math.maxInt(u32))
            u32
        else
            @compileError("Bytecode size too large! It must have under u32 bytes");
    }

    /// StackIndexType: minimal integer type to index the configured stack
    pub fn StackIndexType(self: Self) type {
        return if (self.stack_size <= std.math.maxInt(u4))
            u4
        else if (self.stack_size <= std.math.maxInt(u8))
            u8
        else if (self.stack_size <= std.math.maxInt(u12))
            u12
        else
            @compileError("FrameConfig stack_size is too large! It must fit in a u12 bytes");
    }
    /// GasType: signed integer type to track gas remaining.
    /// 64-bit targets always use i64: it is the native word, and a transaction gas
    /// limit is a u64 that can exceed i32 even when the configured block limit fits.
    /// 32-bit targets keep i32 when `block_gas_limit` fits in it.
    pub fn GasType(self: Self) type {
        return if (@sizeOf(usize) < 8 and self.block_gas_limit <= std.math.maxInt(i32))
            i32
        else
            i64;
    }

    /// The amount of data the frame plans on allocating based on config
    pub fn get_requested_alloc(self: Self) u32 {
        return @as(u32, self.stack_size) * @as(u32, @intCast(@sizeOf(self.WordType)));
    }

    /// Create a loop safety counter based on the configuration
    /// Returns either an enabled or disabled counter depending on loop_quota
    /// Automatically selects the smallest type that can hold the quota
    pub fn createLoopSafetyCounter(self: Self) type {
        const mode: Mode = if (self.loop_quota != null) .enabled else .disabled;
        const limit = self.loop_quota orelse 0;

        // Choose the smallest type that can hold the limit
        const T = if (limit <= std.math.maxInt(u8))
            u8
        else if (limit <= std.math.maxInt(u16))
            u16
        else if (limit <= std.math.maxInt(u32))
            u32
        else
            u64;

        const Counter = SafetyCounter(T, mode);
        return Counter;
    }
};

test "GasType is i64 on 64-bit targets and i32 only for small limits on 32-bit targets" {
    const Db = struct {};
    const small = FrameConfig{ .DatabaseType = Db, .block_gas_limit = 30_000_000 };
    const large = FrameConfig{ .DatabaseType = Db, .block_gas_limit = @as(u64, std.math.maxInt(i32)) + 1 };
    try std.testing.expectEqual(i64, large.GasType());
    if (@sizeOf(usize) >= 8) {
        try std.testing.expectEqual(i64, small.GasType());
    } else {
        try std.testing.expectEqual(i32, small.GasType());
    }
}
