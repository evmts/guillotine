const std = @import("std");
const primitives = @import("primitives");
const CallResult = @import("call_result.zig").CallResult;
const Log = @import("../log.zig");
const EvmModule = @import("../evm.zig");
const EvmConfig = @import("../config.zig").EvmConfig;

const DatabaseError = @import("../state/database_interface.zig").DatabaseError;
pub const StaticcallContractError = std.mem.Allocator.Error || DatabaseError;

/// Execute a STATICCALL operation.
/// Executes the target contract in guaranteed read-only mode (no state changes allowed).
pub fn staticcall_contract(comptime config: EvmConfig) type {
    return struct {
        pub fn staticcallContractImpl(self: *EvmModule.Evm(config), caller: primitives.Address.Address, to: primitives.Address.Address, input: []const u8, gas: u64) StaticcallContractError!CallResult {
            Log.debug("VM.staticcall_contract: STATICCALL from {any} to {any}, gas={}", .{ caller, to, gas });

            // STATICCALL is equivalent to CALL with value=0 and is_static=true
            return self.call_contract(caller, to, 0, input, gas, true) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return CallResult{ .success = false, .gas_left = 0, .output = null },
            };
        }
    };
}
