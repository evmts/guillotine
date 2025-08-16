const std = @import("std");
const Evm = @import("../evm.zig");
const builtin = @import("builtin");
const Log = @import("../log.zig");

const SAFE = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub fn require_one_thread(self: *Evm) void {
    if (comptime SAFE) {
        // Skip thread checking on WASM freestanding (no thread support)
        if (comptime (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding)) {
            return;
        }
        if (self.initial_thread_id != std.Thread.getCurrentId()) {
            Log.err("Detected the EVM running on more than one thread. The current architecture of the EVM simplifies itself by assuming there is no concurrency. Everywhere in the EVM depending on this assumption is clearly commented. This restriction will be removed before Beta release", .{});
        }
    }
}
