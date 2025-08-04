const Fp2Mont = @import("Fp2Mont.zig");
const FpMont = @import("FpMont.zig");
const Fp6Mont = @import("Fp6Mont.zig");
const G1 = @import("G1.zig");
const G2 = @import("G2.zig");

//This file contains parameters and precomputed values for the BN254 curve.

// Field moduli
pub const FP_MOD = 0x30644E72E131A029B85045B68181585D97816A916871CA8D3C208C16D87CFD47;
pub const FR_MOD = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

// Pairing constants
pub const miller_loop_constant_signed = &[_]i2{ 0, 0, 0, 1, 0, 1, 0, -1, 0, 0, -1, 0, 0, 0, 1, 0, 0, -1, 0, -1, 0, 0, 0, 1, 0, -1, 0, 0, 0, 0, -1, 0, 0, 1, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, -1, 0, 0, -1, 0, 1, 0, -1, 0, 0, 0, -1, 0, -1, 0, 0, 0, 1, 0, 1, 1 };

//pub const miller_loop_constant = 29793968203157093288;
pub const miller_loop_iterations = 64;
pub const final_exponentiation_constant = 552484233613224096312617126783173147097382103762957654188882734314196910839907541213974502761540629817009608548654680343627701153829446747810907373256841551006201639677726139946029199968412598804882391702273019083653272047566316584365559776493027495458238373902875937659943504873220554161550525926302303331747463515644711876653177129578303191095900909191624817826566688241804408081892785725967931714097716709526092261278071952560171111444072049229123565057483750161460024353346284167282452756217662335528813519139808291170539072125381230815729071544861602750936964829313608137325426383735122175229541155376346436093930287402089517426973178917569713384748081827255472576937471496195752727188261435633271238710131736096299798168852925540549342330775279877006784354801422249722573783561685179618816480037695005515426162362431072245638324744480;
pub const final_exponentiation_constant_hard_part = 10486551571378427818905133077457505975217533156541166536005452068033223782873764572151541189142778783267711471998854717549389605644966361077867290379973073897271417449614939788000730910148473503528371060814157528868116901618729649;

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
