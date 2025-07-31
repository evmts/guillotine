const std = @import("std");
const primitives = @import("primitives");
const Vm = @import("../evm.zig");

pub const EmitLogError = std.mem.Allocator.Error;

/// Emit an event log (LOG0-LOG4 opcodes).
/// Records an event that will be included in the transaction receipt.
pub fn emit_log(self: *Vm, address: primitives.Address.Address, topics: []const u256, data: []const u8) EmitLogError!void {
    try self.state.emit_log(self.allocator, address, topics, data);
}
