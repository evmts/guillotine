const Fp2Mont = @import("Fp2Mont.zig");
const FpMont = @import("FpMont.zig");
const Fp6Mont = @import("Fp6Mont.zig");
const G1 = @import("G1.zig");
const G2 = @import("G2.zig");

//This file contains parameters and precomputed values for the BN254 curve.

// Field moduli
pub const FP_MOD = 0x30644E72E131A029B85045B68181585D97816A916871CA8D3C208C16D87CFD47;
pub const FR_MOD = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;
pub const CURVE_PARAM_T = 4965661367192848881;
pub const CURVE_PARAM_T_NAF = &[_]i2{ 1, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1, 0, -1, 0, 1, 0, 1, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, -1, 0, -1, 0, -1, 0, 1, 0, 1, 0, 0, -1, 0, 1, 0, 1, 0, -1, 0, 0, 1, 0, 1, 0, 0, 0, 1 };

// Pairing constants
pub const miller_loop_constant_signed = &[_]i2{ 0, 0, 0, 1, 0, 1, 0, -1, 0, 0, -1, 0, 0, 0, 1, 0, 0, -1, 0, -1, 0, 0, 0, 1, 0, -1, 0, 0, 0, 0, -1, 0, 0, 1, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, -1, 0, 0, -1, 0, 1, 0, -1, 0, 0, 0, -1, 0, -1, 0, 0, 0, 1, 0, 1, 1 };
pub const miller_loop_iterations = 64;
//_______________________________________ALL VALUES IN MONTGOMERY FORM_______________________________________

// Montgomery precomputed values
// R = 2^256 mod p
pub const MONTGOMERY_R_MOD_P = 6350874878119819312338956282401532409788428879151445726012394534686998597021;
// R^2 mod p
pub const MONTGOMERY_R2_MOD_P = 3096616502983703923843567936837374451735540968419076528771170197431451843209;
// R^3 mod p
pub const MONTGOMERY_R3_MOD_P = 14921786541159648185948152738563080959093619838510245177710943249661917737183;
// -p^(-1) mod R
pub const MONTGOMERY_MINUS_P_INV_MOD_R = 111032442853175714102588374283752698368366046808579839647964533820976443843465;

// Mathematical constants used in tower field arithmetic

pub const XI = Fp2Mont{ .u0 = FpMont{ .value = 0x1d9598e8a7e398572943337e3940c6d12f3d6f4dd31bd011f60647ce410d7ff7 }, .u1 = FpMont{ .value = 0xe0a77c19a07df2f666ea36f7879462c0a78eb28f5c70b3dd35d438dc58f0d9d } }; // ξ = 9 + u, used in Fp6 and G2 arithmetic
pub const V = Fp6Mont{ .v0 = Fp2Mont{ .u0 = FpMont{ .value = 0x0 }, .u1 = FpMont{ .value = 0x0 } }, .v1 = Fp2Mont{ .u0 = FpMont{ .value = 0xe0a77c19a07df2f666ea36f7879462c0a78eb28f5c70b3dd35d438dc58f0d9d }, .u1 = FpMont{ .value = 0x0 } }, .v2 = Fp2Mont{ .u0 = FpMont{ .value = 0x0 }, .u1 = FpMont{ .value = 0x0 } } }; // v used in Fp12 arithmetic

// G1 generator point
pub const G1_GENERATOR = G1{ .x = FpMont{ .value = 0xe0a77c19a07df2f666ea36f7879462c0a78eb28f5c70b3dd35d438dc58f0d9d }, .y = FpMont{ .value = 0x1c14ef83340fbe5eccdd46def0f28c5814f1d651eb8e167ba6ba871b8b1e1b3a }, .z = FpMont{ .value = 0xe0a77c19a07df2f666ea36f7879462c0a78eb28f5c70b3dd35d438dc58f0d9d } };
pub const G1_INFINITY = G1{ .x = FpMont{ .value = 0x0 }, .y = FpMont{ .value = 0xe0a77c19a07df2f666ea36f7879462c0a78eb28f5c70b3dd35d438dc58f0d9d }, .z = FpMont{ .value = 0x0 } };

// G2 generator point
pub const G2_GENERATOR = G2{ .x = Fp2Mont{ .u0 = FpMont{ .value = 0x19573841af96503bfbb8264797811adfdceb1935497b01728e83b5d102bc2026 }, .u1 = FpMont{ .value = 0x14fef0833aea7b6b09e950fc52a02f866043dd5a5802d8c4afb4737da84c6140 } }, .y = Fp2Mont{ .u0 = FpMont{ .value = 0x28fd7eebae9e4206ff9e1a62231b7dfefe7fd297f59e9b78619dfa9d886be9f6 }, .u1 = FpMont{ .value = 0xda4a0e693fd648255f935be33351076dc57f922327d3cbb64095b56c71856ee } }, .z = Fp2Mont{ .u0 = FpMont{ .value = 0xe0a77c19a07df2f666ea36f7879462c0a78eb28f5c70b3dd35d438dc58f0d9d }, .u1 = FpMont{ .value = 0x0 } } };
pub const G2_INFINITY = G2{ .x = Fp2Mont{ .u0 = FpMont{ .value = 0x0 }, .u1 = FpMont{ .value = 0x0 } }, .y = Fp2Mont{ .u0 = FpMont{ .value = 0xe0a77c19a07df2f666ea36f7879462c0a78eb28f5c70b3dd35d438dc58f0d9d }, .u1 = FpMont{ .value = 0x0 } }, .z = Fp2Mont{ .u0 = FpMont{ .value = 0x0 }, .u1 = FpMont{ .value = 0x0 } } };

// recomputed values for Frobenius coefficients in Montgomery form
// Frobenius coefficients for Fp6
pub const FROBENIUS_COEFF_FP6_V1 = Fp2Mont{ .u0 = FpMont{ .value = 0x1956bcd8118214ec7a007127242e0991347f91c8a9aa6454b5773b104563ab30 }, .u1 = FpMont{ .value = 0x26694fbb4e82ebc3b6e713cdfae0ca3aaa1c7b6d89f891416e849f1ea0aa4757 } };
pub const FROBENIUS_COEFF_FP6_V2 = Fp2Mont{ .u0 = FpMont{ .value = 0x15df9cddbb9fd3ec9c941f314b3e2399a5bb2bd3273411fb7361d77f843abe92 }, .u1 = FpMont{ .value = 0x24830a9d3171f0fd37bc870a0c7dd2b962cb29a5a4445b605dddfd154bd8c949 } };

// Frobenius coefficients for G2
pub const FROBENIUS_G2_X_COEFF = Fp2Mont{ .u0 = FpMont{ .value = 0x1956bcd8118214ec7a007127242e0991347f91c8a9aa6454b5773b104563ab30 }, .u1 = FpMont{ .value = 0x26694fbb4e82ebc3b6e713cdfae0ca3aaa1c7b6d89f891416e849f1ea0aa4757 } };
pub const FROBENIUS_G2_Y_COEFF = Fp2Mont{ .u0 = FpMont{ .value = 0x253570bea500f8dd31a9d1b6f9645366bb30f162e133bacbe4bbdd0c2936b629 }, .u1 = FpMont{ .value = 0x2c87200285defecc6d16bd27bb7edc6b07affd117826d1dba1d77ce45ffe77c7 } };

// Frobenius coefficients for Fp12
pub const FROBENIUS_COEFF_FP12 = Fp2Mont{ .u0 = FpMont{ .value = 0x2f34d751a1f3a7c11bded5ef08a2087ca6b1d7387afb78aaf9ba69633144907 }, .u1 = FpMont{ .value = 0x10a75716b3899551dc2ff3a253dfc926d00f02a4565de15ba222ae234c492d72 } };

// GLS constants grouped for G1 scalar decompositions
pub const G1_SCALAR = struct {
    pub const cube_root: u256 = 2203960485148121921418603742825762020974279258880205651966;
    pub const lambda: u256 = 4407920970296243842393367215006156084916469457145843978461;
    pub const lattice_basis = [_]struct { x: i128, y: i128 }{
        .{ .x = 9931322734385697763, .y = 147946756881789319000765030803803410728 },
        .{ .x = 147946756881789319010696353538189108491, .y = 9931322734385697763 },
    };
};

// G2 GLS constants grouped similarly
pub const G2_SCALAR = struct {
    pub const cube_root: u256 = 2203960485148121921418603742825762020974279258880205651966;
    pub const gamma: u256 = 21888242871839275217838484774961031246007050428528088939761107053157389710902;
    pub const lambda: u256 = 21888242871839275217838484774961031246154997185409878258781734729429964517155;
    pub const gamma_lambda: u256 = 21888242871839275222246405745257275088400417643534245024707370478506390782651;
    pub const lattice_basis = [_][4]i128{
        .{ 14896984101578546644, -1, -14896984101578546643, 0 },
        .{ 24828306835964244406, 4965661367192848880, -4965661367192848880, 4965661367192848881 },
        .{ 14896984101578546643, 0, 14896984101578546644, -1 },
        .{ 4965661367192848880, -4965661367192848881, 24828306835964244406, 4965661367192848880 },
    };
    pub const projection_coeffs = [_]i512{
        @as(i512, 734653495049373973658254490726798021309097738054686593284),
        @as(i512, 147946756881789319005730692170996259609),
        @as(i512, 734653495049373973658254490726798021328960383523457988809),
        @as(i512, -14896984101578546644),
    };
};

// ============================================================================
// TESTS - BN254 Curve Parameters Validation
// ============================================================================

const std = @import("std");

test "curve parameters FP_MOD is prime-like" {
    try std.testing.expect(FP_MOD > 1);
    try std.testing.expect(FP_MOD & 1 == 1);
}

test "curve parameters FR_MOD is prime-like" {
    try std.testing.expect(FR_MOD > 1);
    try std.testing.expect(FR_MOD & 1 == 1);
}

test "curve parameters FP_MOD matches BN254 specification" {
    const expected: u256 = 0x30644E72E131A029B85045B68181585D97816A916871CA8D3C208C16D87CFD47;
    try std.testing.expectEqual(expected, FP_MOD);
}

test "curve parameters FR_MOD matches BN254 specification" {
    const expected: u256 = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;
    try std.testing.expectEqual(expected, FR_MOD);
}

test "curve parameters FP_MOD and FR_MOD are different" {
    try std.testing.expect(FP_MOD != FR_MOD);
}

test "curve parameters FP_MOD is larger than FR_MOD" {
    try std.testing.expect(FP_MOD > FR_MOD);
}

test "curve parameters G1_GENERATOR is on curve" {
    const gen = G1_GENERATOR;
    try std.testing.expect(gen.isOnCurve());
}

test "curve parameters G1_GENERATOR is not infinity" {
    const gen = G1_GENERATOR;
    try std.testing.expect(!gen.isInfinity());
}

test "curve parameters G1_INFINITY is on curve" {
    const inf = G1_INFINITY;
    try std.testing.expect(inf.isOnCurve());
}

test "curve parameters G1_INFINITY is infinity" {
    const inf = G1_INFINITY;
    try std.testing.expect(inf.isInfinity());
}

test "curve parameters G2_GENERATOR is on curve" {
    const gen = G2_GENERATOR;
    try std.testing.expect(gen.isOnCurve());
}

test "curve parameters G2_GENERATOR is not infinity" {
    const gen = G2_GENERATOR;
    try std.testing.expect(!gen.isInfinity());
}

test "curve parameters G2_INFINITY is on curve" {
    const inf = G2_INFINITY;
    try std.testing.expect(inf.isOnCurve());
}

test "curve parameters G2_INFINITY is infinity" {
    const inf = G2_INFINITY;
    try std.testing.expect(inf.isInfinity());
}

test "curve parameters G1_GENERATOR has correct z coordinate" {
    const gen = G1_GENERATOR;
    const expected_z = FpMont.init(MONTGOMERY_R_MOD_P);
    try std.testing.expect(gen.z.equal(&expected_z));
}

test "curve parameters G1_INFINITY has z equals zero" {
    const inf = G1_INFINITY;
    try std.testing.expectEqual(@as(u256, 0), inf.z.value);
}

test "curve parameters G2_INFINITY has z equals zero" {
    const inf = G2_INFINITY;
    try std.testing.expectEqual(@as(u256, 0), inf.z.u0.value);
    try std.testing.expectEqual(@as(u256, 0), inf.z.u1.value);
}

test "curve parameters montgomery R mod p is valid" {
    try std.testing.expect(MONTGOMERY_R_MOD_P > 0);
    try std.testing.expect(MONTGOMERY_R_MOD_P < FP_MOD);
}

test "curve parameters montgomery R2 mod p is valid" {
    try std.testing.expect(MONTGOMERY_R2_MOD_P > 0);
    try std.testing.expect(MONTGOMERY_R2_MOD_P < FP_MOD);
}

test "curve parameters montgomery R3 mod p is valid" {
    try std.testing.expect(MONTGOMERY_R3_MOD_P > 0);
    try std.testing.expect(MONTGOMERY_R3_MOD_P < FP_MOD);
}

test "curve parameters XI is non-zero" {
    const xi = XI;
    try std.testing.expect(xi.u0.value != 0 or xi.u1.value != 0);
}

test "curve parameters V is valid" {
    const v = V;
    try std.testing.expect(v.v1.u0.value != 0 or v.v1.u1.value != 0);
}

test "curve parameters CURVE_PARAM_T is non-zero" {
    try std.testing.expect(CURVE_PARAM_T != 0);
}

test "curve parameters miller loop iterations is reasonable" {
    try std.testing.expect(miller_loop_iterations > 0);
    try std.testing.expect(miller_loop_iterations < 256);
}

test "curve parameters miller loop constant length matches iterations" {
    try std.testing.expectEqual(miller_loop_iterations + 1, miller_loop_constant_signed.len);
}

test "curve parameters frobenius coefficients are non-zero" {
    try std.testing.expect(FROBENIUS_COEFF_FP6_V1.u0.value != 0 or FROBENIUS_COEFF_FP6_V1.u1.value != 0);
    try std.testing.expect(FROBENIUS_COEFF_FP6_V2.u0.value != 0 or FROBENIUS_COEFF_FP6_V2.u1.value != 0);
}

test "curve parameters G1 scalar constants are valid" {
    try std.testing.expect(G1_SCALAR.cube_root > 0);
    try std.testing.expect(G1_SCALAR.cube_root < FR_MOD);
    try std.testing.expect(G1_SCALAR.lambda > 0);
    try std.testing.expect(G1_SCALAR.lambda < FR_MOD);
}

test "curve parameters G2 scalar constants are valid" {
    try std.testing.expect(G2_SCALAR.cube_root > 0);
    try std.testing.expect(G2_SCALAR.cube_root < FR_MOD);
    try std.testing.expect(G2_SCALAR.gamma > 0);
    try std.testing.expect(G2_SCALAR.lambda > 0);
    try std.testing.expect(G2_SCALAR.gamma_lambda > 0);
}

test "curve parameters G1 lattice basis has correct size" {
    try std.testing.expectEqual(@as(usize, 2), G1_SCALAR.lattice_basis.len);
}

test "curve parameters G2 lattice basis has correct size" {
    try std.testing.expectEqual(@as(usize, 4), G2_SCALAR.lattice_basis.len);
}

test "curve parameters G2 projection coefficients has correct size" {
    try std.testing.expectEqual(@as(usize, 4), G2_SCALAR.projection_coeffs.len);
}

test "curve parameters G1 equation verification on generator" {
    const gen_affine = G1_GENERATOR.toAffine();

    const y_squared = gen_affine.y.mul(&gen_affine.y);
    const x_cubed = gen_affine.x.mul(&gen_affine.x).mul(&gen_affine.x);
    const three = FpMont.init(3);
    const rhs = x_cubed.add(&three);

    try std.testing.expect(y_squared.equal(&rhs));
}

test "curve parameters G1 generator order is FR_MOD" {
    const Fr = @import("Fr.zig").Fr;
    const scalar = Fr{ .value = FR_MOD };
    const result = G1_GENERATOR.mul(&scalar);
    try std.testing.expect(result.isInfinity());
}

test "curve parameters G2 generator order is FR_MOD" {
    const Fr = @import("Fr.zig").Fr;
    const scalar = Fr{ .value = FR_MOD };
    const result = G2_GENERATOR.mul(&scalar);
    try std.testing.expect(result.isInfinity());
}

test "curve parameters G1 generator doubled is on curve" {
    const doubled = G1_GENERATOR.double();
    try std.testing.expect(doubled.isOnCurve());
}

test "curve parameters G2 generator doubled is on curve" {
    const doubled = G2_GENERATOR.double();
    try std.testing.expect(doubled.isOnCurve());
}

test "curve parameters G1 cube root cubed equals one mod FR" {
    const cube_root = G1_SCALAR.cube_root;
    const Fr = @import("Fr.zig").Fr;

    const cr_fr = Fr.init(cube_root);
    const cr_squared = cr_fr.mul(&cr_fr);
    const cr_cubed = cr_squared.mul(&cr_fr);

    try std.testing.expect(cr_cubed.equal(&Fr.ONE));
}

test "curve parameters G2 cube root cubed equals one mod FR" {
    const cube_root = G2_SCALAR.cube_root;
    const Fr = @import("Fr.zig").Fr;

    const cr_fr = Fr.init(cube_root);
    const cr_squared = cr_fr.mul(&cr_fr);
    const cr_cubed = cr_squared.mul(&cr_fr);

    try std.testing.expect(cr_cubed.equal(&Fr.ONE));
}

test "curve parameters montgomery minus p inv is valid" {
    try std.testing.expect(MONTGOMERY_MINUS_P_INV_MOD_R != 0);
}

test "curve parameters NAF representation has valid bits" {
    for (CURVE_PARAM_T_NAF) |bit| {
        try std.testing.expect(bit == -1 or bit == 0 or bit == 1);
    }
}

test "curve parameters G1 small multiples are on curve" {
    const Fr = @import("Fr.zig").Fr;
    const scalars = [_]u256{ 1, 2, 3, 5, 7, 11, 13 };

    for (scalars) |s| {
        const scalar = Fr.init(s);
        const point = G1_GENERATOR.mul(&scalar);
        try std.testing.expect(point.isOnCurve());
    }
}

test "curve parameters G2 small multiples are on curve" {
    const Fr = @import("Fr.zig").Fr;
    const scalars = [_]u256{ 1, 2, 3, 5, 7, 11, 13 };

    for (scalars) |s| {
        const scalar = Fr.init(s);
        const point = G2_GENERATOR.mul(&scalar);
        try std.testing.expect(point.isOnCurve());
    }
}

test "curve parameters G2 generator is in correct subgroup" {
    try std.testing.expect(G2_GENERATOR.isInSubgroup());
}

test "curve parameters frobenius G2 coefficients are valid" {
    const x_coeff = FROBENIUS_G2_X_COEFF;
    const y_coeff = FROBENIUS_G2_Y_COEFF;

    try std.testing.expect(x_coeff.u0.value != 0 or x_coeff.u1.value != 0);
    try std.testing.expect(y_coeff.u0.value != 0 or y_coeff.u1.value != 0);
}

test "curve parameters FROBENIUS_COEFF_FP12 is valid" {
    const coeff = FROBENIUS_COEFF_FP12;
    try std.testing.expect(coeff.u0.value != 0 or coeff.u1.value != 0);
}

test "curve parameters G1 and G2 same cube root" {
    try std.testing.expectEqual(G1_SCALAR.cube_root, G2_SCALAR.cube_root);
}

test "curve parameters field arithmetic in bounds" {
    const x1 = FpMont.init(12345);
    const x2 = FpMont.init(67890);

    const sum = x1.add(&x2);
    const prod = x1.mul(&x2);

    try std.testing.expect(sum.value < FP_MOD);
    try std.testing.expect(prod.value < FP_MOD);
}

test "curve parameters G1 affine generator coordinates in field" {
    const gen_affine = G1_GENERATOR.toAffine();
    try std.testing.expect(gen_affine.x.value < FP_MOD);
    try std.testing.expect(gen_affine.y.value < FP_MOD);
}

test "curve parameters G2 affine generator coordinates in field" {
    const gen_affine = G2_GENERATOR.toAffine();
    try std.testing.expect(gen_affine.x.u0.value < FP_MOD);
    try std.testing.expect(gen_affine.x.u1.value < FP_MOD);
    try std.testing.expect(gen_affine.y.u0.value < FP_MOD);
    try std.testing.expect(gen_affine.y.u1.value < FP_MOD);
}
