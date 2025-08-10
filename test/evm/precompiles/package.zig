// Precompile tests module

pub const blake2f_test = @import("blake2f_test.zig");
pub const bls12_381_g2msm_test = @import("bls12_381_g2msm_test.zig");
pub const bn254_rust_test = @import("bn254_rust_test.zig");
pub const ecadd_test = @import("ecadd_test.zig");
pub const ecrecover_production_test = @import("ecrecover_production_test.zig");
pub const ecrecover_test = @import("ecrecover_test.zig");
pub const identity_test = @import("identity_test.zig");
pub const modexp_test = @import("modexp_test.zig");
pub const ripemd160_test = @import("ripemd160_test.zig");
pub const sha256_test = @import("sha256_test.zig");

test {
    _ = blake2f_test;
    _ = bls12_381_g2msm_test;
    _ = bn254_rust_test;
    _ = ecadd_test;
    _ = ecrecover_production_test;
    _ = ecrecover_test;
    _ = identity_test;
    _ = modexp_test;
    _ = ripemd160_test;
    _ = sha256_test;
}
