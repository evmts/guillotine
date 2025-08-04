const std = @import("std");

pub const Uint = @import("uint.zig").Uint;

pub const nlimbs = @import("uint.zig").nlimbs;
pub const mask = @import("uint.zig").mask;

pub const U64 = Uint(64, 1);
pub const U128 = Uint(128, 2);
pub const U256 = Uint(256, 4);
pub const U512 = Uint(512, 8);
pub const U1024 = Uint(1024, 16);
pub const U2048 = Uint(2048, 32);
pub const U4096 = Uint(4096, 64);

test {
    _ = @import("uint.zig");
}