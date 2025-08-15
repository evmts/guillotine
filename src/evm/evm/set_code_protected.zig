const std = @import("std");
const Vm = @import("../evm.zig");
const ExecutionError = @import("../execution/execution_error.zig");
const primitives = @import("primitives");

/// Error type for set_code_protected operation
pub const SetCodeProtectedError = ExecutionError.Error;

/// Set contract code with static context protection.
/// In static context (read-only mode), code modifications are not allowed.
///
/// @param self The VM instance
/// @param address The address to set code for
/// @param code The bytecode to store
/// @return SetCodeProtectedError if in static context, otherwise void
///
/// Example:
/// ```zig
/// // In normal context
/// vm.read_only = false;
/// try vm.set_code_protected(address, code); // Succeeds
///
/// // In static context
/// vm.read_only = true;
/// const result = vm.set_code_protected(address, code); // Returns error.WriteProtection
/// ```
pub fn set_code_protected(self: *Vm, address: primitives.Address.Address, code: []const u8) SetCodeProtectedError!void {
    if (self.is_read_only()) {
        return ExecutionError.Error.WriteProtection;
    }

    try self.state.set_code(address, code);
}
