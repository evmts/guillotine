comptime {
    _ = @import("layer2_config.zig");
    _ = @import("optimism/mod.zig");
    _ = @import("optimism/spec.zig");
    _ = @import("optimism/constants.zig");
    _ = @import("optimism/l1_block_info.zig");
    _ = @import("optimism/transaction.zig");
    _ = @import("optimism/fast_lz.zig");
    _ = @import("optimism/precompiles.zig");
}

test {
    @import("std").testing.refAllDecls(@This());
}
