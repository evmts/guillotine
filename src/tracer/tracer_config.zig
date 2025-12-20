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
