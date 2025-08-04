const FpMont = @import("FpMont.zig");
const Fp2Mont = @import("Fp2Mont.zig");
const Fr = @import("Fr.zig");
const curve_parameters = @import("curve_parameters.zig");

pub const G2 = @This();
x: Fp2Mont,
y: Fp2Mont,
z: Fp2Mont,

pub const INFINITY = curve_parameters.G2_INFINITY;
pub const GENERATOR = curve_parameters.G2_GENERATOR;

pub const FROBENIUS_X_COEFF = curve_parameters.FROBENIUS_G2_X_COEFF;
pub const FROBENIUS_Y_COEFF = curve_parameters.FROBENIUS_G2_Y_COEFF;

pub fn isInfinity(self: *const G2) bool {
    return self.z.u0.value == 0 and self.z.u1.value == 0;
}

pub fn initUnchecked(x: *const Fp2Mont, y: *const Fp2Mont, z: *const Fp2Mont) G2 {
    return G2{ .x = x.*, .y = y.*, .z = z.* };
}

// Checked constructor - validates point is on curve
// WARNING: DOES NOT CHECK IF POINT IS IN RIGHT SUBGROUP
pub fn init(x: *const Fp2Mont, y: *const Fp2Mont, z: *const Fp2Mont) !G2 {
    const point = G2{ .x = x.*, .y = y.*, .z = z.* };
    if (!point.isOnCurve()) {
        return error.InvalidPoint;
    }
    return point;
}

pub fn toAffine(self: *const G2) G2 {
    if (self.isInfinity()) {
        return INFINITY;
    }
    const z_inv = self.z.inv() catch unreachable;
    const z_inv_sq = z_inv.mul(&z_inv);
    const z_inv_cubed = z_inv_sq.mul(&z_inv);

    return G2{
        .x = self.x.mul(&z_inv_sq),
        .y = self.y.mul(&z_inv_cubed),
        .z = Fp2Mont.ONE,
    };
}

pub fn isOnCurve(self: *const G2) bool {
    if (self.isInfinity()) return true;
    const xi = curve_parameters.XI;
    const xi_inv = xi.inv() catch unreachable;
    const z_factor = Fp2Mont.init_from_int(3, 0).mul(&xi_inv);

    // BN254 Jacobian equation: Y² = X³ + (3/xi)Z⁶
    const y_squared = self.y.mul(&self.y);
    const x_cubed = self.x.mul(&self.x).mul(&self.x);
    const z_squared = self.z.mul(&self.z);
    const z_sixth = z_squared.mul(&z_squared).mul(&z_squared);
    const rhs = x_cubed.add(&z_sixth.mul(&z_factor));

    return y_squared.equal(&rhs);
}

pub fn isInSubgroup(self: *const G2) bool {
    _ = self;
    @panic("TODO: implement isInSubgroup");
}

pub fn neg(self: *const G2) G2 {
    return G2{
        .x = self.x,
        .y = self.y.neg(),
        .z = self.z,
    };
}

pub fn negAssign(self: *G2) void {
    self.* = self.neg();
}

pub fn equal(self: *const G2, other: *const G2) bool {
    const selfInf = self.isInfinity();
    const otherInf = other.isInfinity();

    if (selfInf and otherInf) {
        return true;
    }
    if (selfInf != otherInf) {
        return false;
    }

    // Both not infinity: cross-multiply to compare
    // For X coordinates: X1/Z1² = X2/Z2² => X1 * Z2² = X2 * Z1²
    const Z1_sq = self.z.mul(&self.z);
    const Z2_sq = other.z.mul(&other.z);
    const X1_Z2_sq = self.x.mul(&Z2_sq);
    const X2_Z1_sq = other.x.mul(&Z1_sq);

    // For Y coordinates: Y1/Z1³ = Y2/Z2³ => Y1 * Z2³ = Y2 * Z1³
    const Z1_cubed = Z1_sq.mul(&self.z);
    const Z2_cubed = Z2_sq.mul(&other.z);
    const Y1_Z2_cubed = self.y.mul(&Z2_cubed);
    const Y2_Z1_cubed = other.y.mul(&Z1_cubed);

    return X1_Z2_sq.equal(&X2_Z1_sq) and Y1_Z2_cubed.equal(&Y2_Z1_cubed);
}

pub fn double(self: *const G2) G2 {
    // Compute intermediate values
    const X_squared = self.x.mul(&self.x); // X²
    const Y_squared = self.y.mul(&self.y); // Y²
    const Y_fourth = Y_squared.mul(&Y_squared); // Y⁴

    // S = 4XY²
    const S = self.x.mul(&Y_squared).mulBySmallInt(4);

    // M = 3X²
    const M = X_squared.mulBySmallInt(3);

    // X' = M² - 2S
    const M_squared = M.mul(&M);
    const two_S = S.mulBySmallInt(2);
    const x_result = M_squared.sub(&two_S);

    // Y' = M(S - X') - 8Y⁴
    const S_minus_X = S.sub(&x_result);
    const eight_Y_fourth = Y_fourth.mulBySmallInt(8);
    const y_result = M.mul(&S_minus_X).sub(&eight_Y_fourth);

    // Z' = 2YZ
    const z_result = self.y.mul(&self.z).mulBySmallInt(2);

    return G2{ .x = x_result, .y = y_result, .z = z_result };
}

pub fn doubleAssign(self: *G2) void {
    self.* = self.double();
}

pub fn add(self: *const G2, other: *const G2) G2 {
    if (self.isInfinity()) {
        return other.*;
    }
    if (other.isInfinity()) {
        return self.*;
    }

    // Compute U1 = X1 * Z2² and U2 = X2 * Z1²
    const Z1_sq = self.z.mul(&self.z);
    const Z2_sq = other.z.mul(&other.z);
    const U1 = self.x.mul(&Z2_sq);
    const U2 = other.x.mul(&Z1_sq);

    // Compute S1 = Y1 * Z2³ and S2 = Y2 * Z1³
    const Z1_cubed = Z1_sq.mul(&self.z);
    const Z2_cubed = Z2_sq.mul(&other.z);
    const S1 = self.y.mul(&Z2_cubed);
    const S2 = other.y.mul(&Z1_cubed);

    // Check if points are equal or negatives
    if (U1.equal(&U2)) {
        if (S1.equal(&S2)) {
            return self.double();
        }
        return INFINITY;
    }

    // Compute H = U2 - U1 and R = S2 - S1
    const H = U2.sub(&U1);
    const R = S2.sub(&S1);

    // Compute H², H³, and intermediate values
    const H_sq = H.mul(&H);
    const H_cubed = H_sq.mul(&H);
    const U1_H_sq = U1.mul(&H_sq);

    // X3 = R² - H³ - 2*U1*H²
    const R_sq = R.mul(&R);
    const two_U1_H_sq = U1_H_sq.mulBySmallInt(2);
    const result_x = R_sq.sub(&H_cubed).sub(&two_U1_H_sq);

    // Y3 = R*(U1*H² - X3) - S1*H³
    const result_y = R.mul(&U1_H_sq.sub(&result_x)).sub(&S1.mul(&H_cubed));

    // Z3 = Z1 * Z2 * H
    const result_z = self.z.mul(&other.z).mul(&H);

    return G2{ .x = result_x, .y = result_y, .z = result_z };
}

pub fn addAssign(self: *G2, other: *const G2) void {
    self.* = self.add(other);
}

pub fn mul(self: *const G2, scalar: *const Fr) G2 {
    return self.mul_by_int(scalar.value);
}

pub fn mul_by_int(self: *const G2, scalar: u256) G2 {
    if (self.isInfinity()) {
        return INFINITY;
    }
    var result = INFINITY;
    var base = self.*;
    var exp = scalar;
    while (exp > 0) : (exp >>= 1) {
        if (exp & 1 == 1) {
            result.addAssign(&base);
        }
        base.doubleAssign();
    }
    return result;
}

pub fn mulAssign(self: *G2, scalar: *const Fr) void {
    self.* = self.mul(scalar);
}

pub fn frobenius(self: *const G2) G2 {
    return G2{
        .x = self.x.frobeniusMap().mul(&FROBENIUS_X_COEFF),
        .y = self.y.frobeniusMap().mul(&FROBENIUS_Y_COEFF),
        .z = self.z.frobeniusMap(),
    };
}

// ============================================================================
// TESTS - Adapted from g2.zig for Montgomery form
// ============================================================================

const std = @import("std");

fn expectG2Equal(expected: G2, actual: G2) !void {
    try std.testing.expect(expected.equal(&actual));
}

test "G2.add opposite" {
    const Gen = G2.GENERATOR;
    const minusG = Gen.neg();
    const G_plus_minusG = Gen.add(&minusG);
    try std.testing.expect(G_plus_minusG.isInfinity());
}

test "G2.add" {
    const Gen = G2.GENERATOR;
    const Gen2 = G2{
        .x = Fp2Mont.init_from_int(8068064665578754444291054647125927633989259848632494988160623383584150338969, 10201766053784902393624440516579763048402213644202139977240562962104124808534),
        .y = Fp2Mont.init_from_int(18350387758438165722514006433324734852126505429007818091896560652419680779208, 2361120538552305763462588552289584032113666280040005078430227626567900900889),
        .z = Fp2Mont.init_from_int(16991307846246862835209946494978544876836381174527200297540561298613916203860, 8164735751726867362664406806290871136633702655186802416211482152428240187062),
    };
    const expected_result = G2{
        .x = Fp2Mont.init_from_int(16964963043016842499038600092728359482547221737098759962437502895503860098956, 9802038328124067467167916831831108021770181501290579378159059786039834492047),
        .y = Fp2Mont.init_from_int(16820779252272725671048206721551654470547449467959363398932701258504709733061, 18729480042507864736551419171906659760696723842014658768251241386616345560593),
        .z = Fp2Mont.init_from_int(394855990771205946776485094759919347105338213653118418588150452214006819405, 8586553845205426076950860668862984318775103285308506851115128319666650804540),
    };
    try expectG2Equal(expected_result, Gen.add(&Gen2));
}

test "G2.double expected" {
    const Gen = G2.GENERATOR;
    const doubleG = Gen.double();
    const expected_result = G2{
        .x = Fp2Mont.init_from_int(8068064665578754444291054647125927633989259848632494988160623383584150338969, 10201766053784902393624440516579763048402213644202139977240562962104124808534),
        .y = Fp2Mont.init_from_int(18350387758438165722514006433324734852126505429007818091896560652419680779208, 2361120538552305763462588552289584032113666280040005078430227626567900900889),
        .z = Fp2Mont.init_from_int(16991307846246862835209946494978544876836381174527200297540561298613916203860, 8164735751726867362664406806290871136633702655186802416211482152428240187062),
    };

    try expectG2Equal(expected_result, doubleG);
}

test "G2.mul" {
    const Gen = G2.GENERATOR;
    const minus_G = Gen.mul(&Fr.init(1).neg());
    const G_plus_minus_G = Gen.add(&minus_G);
    try std.testing.expect(G_plus_minus_G.isInfinity());
}

test "G2.isOnCurve generator" {
    const gen = G2.GENERATOR;
    try std.testing.expect(gen.isOnCurve());
}

test "G2.isOnCurve identity" {
    const identity = G2.INFINITY;
    try std.testing.expect(identity.isOnCurve());
}

test "G2.isOnCurve random point" {
    const k = 7; // example scalar
    const random_point = G2.GENERATOR.mul(&Fr.init(k));
    try std.testing.expect(random_point.isOnCurve());
}

test "G2.equal generator to itself" {
    const gen = G2.GENERATOR;
    try std.testing.expect(gen.equal(&gen));
}

test "G2.toAffine random point" {
    const k = 13; // example scalar
    const random_point = G2.GENERATOR.mul(&Fr.init(k));
    const affine = random_point.toAffine();

    const expected_result = G2{
        .x = Fp2Mont.init_from_int(16137324789686743234629608741537369181251990815455155257427276976918350071287, 280672898440571232725436467950720547829638241593507531241322547969961007057),
        .y = Fp2Mont.init_from_int(12136420650226457477690750437223209427924916790606163705631661913973995426040, 17641806683785498955878869918183868440783188556637975525088932771694068429840),
        .z = Fp2Mont.ONE, // affine points have z = 1
    };

    try expectG2Equal(expected_result, affine);
    try std.testing.expect(affine.isOnCurve());
}

test "G2.add generator to identity" {
    const gen = G2.GENERATOR;
    const identity = G2.INFINITY;
    const result = gen.add(&identity);
    try expectG2Equal(gen, result);
}

test "G2.add random points" {
    const k1 = 3; // example scalar
    const k2 = 5; // example scalar
    const point1 = G2.GENERATOR.mul(&Fr.init(k1));
    const point2 = G2.GENERATOR.mul(&Fr.init(k2));
    const result = point1.add(&point2);

    const expected_result = G2{
        .x = Fp2Mont.init_from_int(12338822787986259899292241915605503554934128188921556766068436962878160930396, 7873988026505017611181106612809016613872895048560600031197901192282892195467),
        .y = Fp2Mont.init_from_int(15022180381621582952906644413383285972184526146125412741587595613615896914712, 19921033716458048718332470098885436883122273955056609736463017767128109247250),
        .z = Fp2Mont.init_from_int(1774573728518825553032624160373027001804770585936131378855038206560263646397, 16540582363439390354595677887183297241579373102577794439755118116102427771932),
    };

    try expectG2Equal(expected_result, result);
    try std.testing.expect(result.isOnCurve());
}

test "G2.add commutativity" {
    const k1 = 11; // example scalar
    const k2 = 17; // example scalar
    const point1 = G2.GENERATOR.mul(&Fr.init(k1));
    const point2 = G2.GENERATOR.mul(&Fr.init(k2));

    const result1 = point1.add(&point2);
    const result2 = point2.add(&point1);
    try expectG2Equal(result1, result2);
}

test "G2.double identity" {
    const identity = G2.INFINITY;
    const result = identity.double();
    try std.testing.expect(result.isInfinity());
}

test "G2.double random point" {
    const k = 9; // example scalar
    const random_point = G2.GENERATOR.mul(&Fr.init(k));
    const doubled = random_point.double();

    const expected_result = G2{
        .x = Fp2Mont.init_from_int(9010315763217961467479503725255056756346217638634836905524514729866798122782, 12713521549126352466862126562479899179793375378918102927559864838005817848258),
        .y = Fp2Mont.init_from_int(2938963071173997916611155186588796442091168500216583928241941802670927160507, 4637911005980597202814535267161061392968887007349473417306059045353733452774),
        .z = Fp2Mont.init_from_int(21027050538969145131013453157421638377169363093479560088903524997919820324535, 16346656561829046745170627665889413954208741171200634938000383914340115265265),
    };

    try expectG2Equal(expected_result, doubled);
    try std.testing.expect(doubled.isOnCurve());
}

test "G2.chain operations" {
    const gen = G2.GENERATOR;
    const doubled = gen.double();
    const quadrupled = doubled.double();
    const gen_times_four = gen.add(&gen).add(&gen).add(&gen);
    try expectG2Equal(quadrupled, gen_times_four);
}

// check that the frobenius map is correct
test "G2.frobenius" {
    const scalars = [_]u64{
        1, 3, 5, 7, 11, 19, 123, 999, 10007, 123456, 987654321, 3141592653, 9007199254740991, 18446744073709551557,
    };
    for (scalars) |k| {
        const point = G2.GENERATOR.mul(&Fr.init(k));
        const frob_point = point.frobenius();
        const p_point = point.mul(&Fr.init(curve_parameters.FP_MOD));
        try expectG2Equal(p_point, frob_point);
    }
}

// Additional tests for assignment methods
test "G2.addAssign basic assignment" {
    var a = G2.GENERATOR;
    const b = G2.GENERATOR.double();
    const expected = a.add(&b);
    a.addAssign(&b);
    try expectG2Equal(expected, a);
}

test "G2.doubleAssign basic assignment" {
    var a = G2.GENERATOR;
    const expected = a.double();
    a.doubleAssign();
    try expectG2Equal(expected, a);
}

test "G2.negAssign basic assignment" {
    var a = G2.GENERATOR;
    const expected = a.neg();
    a.negAssign();
    try expectG2Equal(expected, a);
}

test "G2.mulAssign basic assignment" {
    var a = G2.GENERATOR;
    const scalar = Fr.init(7);
    const expected = a.mul(&scalar);
    a.mulAssign(&scalar);
    try expectG2Equal(expected, a);
}
