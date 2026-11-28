const std = @import("std");
const log = @import("../log.zig");
const primitives = @import("voltaire");
const pc_tracker_mod = @import("pc_tracker.zig");
pub const MinimalEvm = @import("minimal_evm.zig").MinimalEvm;
const MinimalFrame = @import("minimal_frame.zig").MinimalFrame;
const Host = @import("minimal_evm.zig").Host;
const UnifiedOpcode = @import("../opcodes/opcode.zig").UnifiedOpcode;
const Opcode = @import("../opcodes/opcode.zig").Opcode;
const SafetyCounter = @import("../internal/safety_counter.zig").SafetyCounter;

pub const TracerConfig = struct {
    /// Enable the tracer system entirely (default: false)
    /// Must be explicitly enabled when needed
    enabled: bool = false,

    enable_validation: bool = false,
    enable_step_capture: bool = false,
    enable_pc_tracking: bool = false,
    enable_gas_tracking: bool = false,
    enable_debug_logging: bool = false,
    enable_advanced_trace: bool = false,

    /// Most records kept per capture list (`Tracer.steps` and `Tracer.advanced_steps`
    /// each). Capture stops at the bound and the trace is marked truncated; execution
    /// continues unaffected. Null removes the bound.
    max_steps: ?usize = default_max_steps,
    /// Most bytes the captured records may own, counting each record and the stack copy
    /// or fusion description it holds. Capture stops at the bound and the trace is
    /// marked truncated; execution continues unaffected. Null removes the bound.
    max_bytes: ?usize = default_max_bytes,

    /// One million records covers a 30M-gas transaction of 3-gas instructions ten
    /// times over without letting a hostile loop grow the trace without limit.
    pub const default_max_steps: usize = 1_000_000;
    /// 256 MiB of retained trace data.
    pub const default_max_bytes: usize = 256 * 1024 * 1024;

    /// Why a trace stopped short of the whole execution.
    pub const TruncationReason = enum(u8) {
        /// The trace is complete.
        none = 0,
        /// `max_steps` records were already captured.
        max_steps = 1,
        /// The next record would have exceeded `max_bytes`.
        max_bytes = 2,
        /// The allocator could not hold the next record.
        out_of_memory = 3,
    };

    pub const disabled = TracerConfig{ .enabled = false };

    pub const debug = TracerConfig{
        .enabled = true,
        .enable_validation = true,
        .enable_pc_tracking = true,
        .enable_gas_tracking = true,
        .enable_debug_logging = true,
    };

    pub const full = TracerConfig{
        .enabled = true,
        .enable_validation = true,
        .enable_step_capture = true,
        .enable_pc_tracking = true,
        .enable_gas_tracking = true,
        .enable_debug_logging = true,
        .enable_advanced_trace = true,
    };
};

test "TracerConfig presets match expected defaults" {
    try std.testing.expect(!TracerConfig.disabled.enabled);
    try std.testing.expect(TracerConfig.debug.enabled);
    try std.testing.expect(TracerConfig.debug.enable_validation);
    try std.testing.expect(!TracerConfig.debug.enable_step_capture);
    try std.testing.expect(TracerConfig.full.enable_step_capture);
    try std.testing.expect(TracerConfig.full.enable_advanced_trace);
}

test "W3-15: TracerConfig capture budget is bounded by default and can be lifted" {
    const defaults = TracerConfig{};
    try std.testing.expectEqual(@as(?usize, TracerConfig.default_max_steps), defaults.max_steps);
    try std.testing.expectEqual(@as(?usize, TracerConfig.default_max_bytes), defaults.max_bytes);
    try std.testing.expectEqual(@as(?usize, TracerConfig.default_max_steps), TracerConfig.full.max_steps);
    const unbounded = TracerConfig{ .max_steps = null, .max_bytes = null };
    try std.testing.expect(unbounded.max_steps == null);
    try std.testing.expect(unbounded.max_bytes == null);
    try std.testing.expectEqual(@as(u8, 0), @backingInt(TracerConfig.TruncationReason.none));
}
