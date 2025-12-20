//! Guillotine Mini - EVM implementation
const std = @import("std");

// Export configuration
pub const evm_config = @import("evm_config.zig");
pub const EvmConfig = evm_config.EvmConfig;
pub const OpcodeOverride = evm_config.OpcodeOverride;
pub const PrecompileOverride = evm_config.PrecompileOverride;
pub const PrecompileOutput = evm_config.PrecompileOutput;

// Export the main EVM module
pub const evm = @import("evm.zig");
pub const Evm = evm.Evm;
pub const StorageSlotKey = evm.StorageSlotKey;
// AccessListParam removed - use primitives.AccessList.AccessList instead
// AccessListStorageKey is now primitives.AccessList.StorageSlotKey
pub const BlockContext = evm.BlockContext;

// Export CallParams and CallResult (polymorphic API with guillotine core)
pub const call_params = @import("call_params.zig");
pub const call_result = @import("call_result.zig");
pub const Log = call_result.Log;
pub const SelfDestructRecord = call_result.SelfDestructRecord;
pub const StorageAccess = call_result.StorageAccess;
pub const TraceStep = call_result.TraceStep;
pub const ExecutionTrace = call_result.ExecutionTrace;

// Export Frame function
pub const frame = @import("frame.zig");
pub const Frame = frame.Frame;

// Export Host interface and types
pub const host = @import("host.zig");
pub const HostInterface = host.HostInterface;

// Export Hardfork from primitives
const primitives = @import("primitives");
pub const Hardfork = primitives.Hardfork;
pub const ForkTransition = primitives.ForkTransition;

// Export errors
pub const errors = @import("errors.zig");
pub const CallError = errors.CallError;

// Export tracing functionality (EIP-3155)
pub const trace = @import("trace.zig");
pub const Tracer = trace.Tracer;
pub const TraceEntry = trace.TraceEntry;

// Export opcode utilities
pub const opcode = @import("opcode.zig");
pub const getOpName = opcode.getOpName;

// Export instruction dispatcher
pub const dispatcher = @import("instructions/dispatcher.zig");
pub const Dispatcher = dispatcher.Dispatcher;

test {
    std.testing.refAllDecls(@This());
    _ = @import("evm_test.zig");
    _ = @import("instructions/handlers_stack_test.zig");
    _ = @import("instructions/handlers_arithmetic_test.zig");
    _ = @import("instructions/handlers_comparison_test.zig");
    _ = @import("instructions/handlers_keccak_test.zig");
    _ = @import("instructions/handlers_memory_test.zig");
    _ = @import("instructions/handlers_log_test.zig");
    _ = @import("instructions/handlers_control_flow_test.zig");
    _ = @import("instructions/handlers_storage_test.zig");
    _ = @import("instructions/handlers_system_test.zig");
    _ = @import("instructions/handlers_context_test.zig");
    _ = @import("instructions/handlers_block_test.zig");
    _ = @import("instructions/dispatcher.zig");
    _ = @import("instructions/test_helpers.zig");
    _ = @import("instructions/test_helpers_examples.test.zig");
}
