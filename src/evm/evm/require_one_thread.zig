const std = @import("std");
const Evm = @import("../evm.zig");
const builtin = @import("builtin");
const Log = @import("../log.zig");

const SAFE = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub inline fn require_one_thread(self: *@This()) void {
    if (comptime SAFE) {
        if (self.initial_thread_id != std.Thread.getCurrentId()) {
            Log.err("Detected the EVM running on more than one thread. The current architecture of the EVM simplifies itself by assuming there is no concurrency. Everywhere in the EVM depending on this assumption is clearly commented. This restriction will be removed before Beta release", .{});
        }
    }
}
