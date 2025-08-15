const FpMont = @import("FpMont.zig");
const Fp2Mont = @import("Fp2Mont.zig");
const curve_parameters = @import("curve_parameters.zig");

//
// Field extension: F_p4 = F_p2[y] / (y^2 - ξ)
// Elements: a = a0 + a1*y, where a0, a1 ∈ F_p2 and y^2 = ξ
//

pub const Fp4Mont = @This();

y0: Fp2Mont,
y1: Fp2Mont,

pub const ZERO = Fp4Mont{ .y0 = Fp2Mont.ZERO, .y1 = Fp2Mont.ZERO };
pub const ONE = Fp4Mont{ .y0 = Fp2Mont.ONE, .y1 = Fp2Mont.ZERO };

pub fn init(y0: *const Fp2Mont, y1: *const Fp2Mont) Fp4Mont {
    return Fp4Mont{ .y0 = y0.*, .y1 = y1.* };
}

pub fn init_from_int(y0_v0_real: u256, y0_v0_imag: u256, y0_v1_real: u256, y0_v1_imag: u256, y1_v0_real: u256, y1_v0_imag: u256, y1_v1_real: u256, y1_v1_imag: u256) Fp4Mont {
    const y0 = Fp2Mont.init_from_int(y0_v0_real, y0_v0_imag, y0_v1_real, y0_v1_imag);
    const y1 = Fp2Mont.init_from_int(y1_v0_real, y1_v0_imag, y1_v1_real, y1_v1_imag);
    return Fp4Mont{
        .y0 = y0,
        .y1 = y1,
    };
}

pub fn add(self: *const Fp4Mont, other: *const Fp4Mont) Fp4Mont {
    return Fp4Mont{
        .y0 = self.y0.add(&other.y0),
        .y1 = self.y1.add(&other.y1),
    };
}

pub fn addAssign(self: *Fp4Mont, other: *const Fp4Mont) void {
    self.* = self.add(other);
}

pub fn neg(self: *const Fp4Mont) Fp4Mont {
    return Fp4Mont{
        .y0 = self.y0.neg(),
        .y1 = self.y1.neg(),
    };
}

pub fn negAssign(self: *Fp4Mont) void {
    self.* = self.neg();
}

pub fn sub(self: *const Fp4Mont, other: *const Fp4Mont) Fp4Mont {
    return Fp4Mont{
        .y0 = self.y0.sub(&other.y0),
        .y1 = self.y1.sub(&other.y1),
    };
}

pub fn subAssign(self: *Fp4Mont, other: *const Fp4Mont) void {
    self.* = self.sub(other);
}

pub fn mulByY(self: *const Fp4Mont) Fp4Mont {
    const xi = curve_parameters.XI;
    return Fp4Mont{
        .y0 = self.y1.mul(&xi),
        .y1 = self.y0,
    };
}

//we use double and add to multiply by a small integer
pub fn mulBySmallInt(self: *const Fp4Mont, other: u8) Fp4Mont {
    var result = ZERO;
    var base = self.*;
    var exp = other;
    while (exp > 0) : (exp >>= 1) {
        if (exp & 1 == 1) {
            result.addAssign(&base);
        }
        base.addAssign(&base);
    }
    return result;
}

pub fn mulBySmallIntAssign(self: *Fp4Mont, other: u8) void {
    self.* = self.mulBySmallInt(other);
}

/// Complex squaring: (a0 + a1*y)² = (a0 + a1)(a0 + ξ*a1) - a0*a1 - ξ*a0*a1 + 2*a0*a1*y
pub fn square(self: *const Fp4Mont) Fp4Mont {
    const xi = curve_parameters.XI;

    // a = a0 + a1*y, where y² = ξ
    const a0_a1 = self.y0.mul(&self.y1);
    const a0_plus_a1 = self.y0.add(&self.y1);
    const a0_plus_y_a1 = self.y0.add(&self.y1.mul(&xi));

    const c0 = a0_plus_a1.mul(&a0_plus_y_a1).sub(&a0_a1).sub(&a0_a1.mul(&xi)); // (a0+a1)(a0+ξ*a1) - a0*a1 - ξ*a0*a1
    const c1 = a0_a1.mulBySmallInt(2); // 2*a0*a1

    return Fp4Mont{
        .y0 = c0,
        .y1 = c1,
    };
}

pub fn squareAssign(self: *Fp4Mont) void {
    self.* = self.square();
}

pub fn conj(self: *const Fp4Mont) Fp4Mont {
    return Fp4Mont{
        .y0 = self.y0,
        .y1 = self.y1.neg(),
    };
}
