comptime {
    _ = @import("layer2_config.zig");
    _ = @import("optimism/spec.zig");
    _ = @import("optimism/constants.zig");
    _ = @import("optimism/l1_block_info.zig");
    _ = @import("optimism/transaction.zig");
    _ = @import("optimism/deposit.zig");
    _ = @import("optimism/da_footprint.zig");
    _ = @import("optimism/eip1559.zig");
    _ = @import("optimism/fast_lz.zig");
    _ = @import("optimism/precompiles.zig");
    _ = @import("base/config.zig");
    _ = @import("base/hardforks.zig");
    _ = @import("base/fees.zig");
    _ = @import("base/precompiles.zig");
}

test {
    @import("std").testing.refAllDecls(@import("mod.zig"));
}

comptime {
    _ = @import("executor.zig");
}
