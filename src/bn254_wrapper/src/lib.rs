use ark_bn254::{Bn254, G1Affine, G2Affine};
use ark_bls12_381::{Bls12_381, G1Affine as BlsG1Affine, G2Affine as BlsG2Affine};
use ark_ec::{pairing::Pairing, AffineRepr, CurveGroup};
use ark_ff::{BigInteger, One, PrimeField, Zero};
/// BN254 Wrapper Library for Zig Integration
///
/// This library provides C-compatible bindings for BN254 elliptic curve operations
/// using the arkworks library. It's designed to be called from Zig code
/// for ECMUL and ECPAIRING precompile implementations.
///
/// Based on arkworks algebra library for production-grade BN254 operations.
use std::os::raw::{c_int, c_uchar, c_uint};

/// Result codes for BN254 operations
#[repr(C)]
pub enum Bn254Result {
    Success = 0,
    InvalidInput = 1,
    InvalidPoint = 2,
    InvalidScalar = 3,
    ComputationFailed = 4,
}

/// Initialize the BN254 library
/// This function can be called multiple times safely
#[no_mangle]
pub extern "C" fn bn254_init() -> c_int {
    // ethereum-bn128 doesn't require explicit initialization
    Bn254Result::Success as c_int
}

/// Perform elliptic curve scalar multiplication (ECMUL)
///
/// Input format (96 bytes):
/// - Bytes 0-31: x coordinate (big-endian)
/// - Bytes 32-63: y coordinate (big-endian)  
/// - Bytes 64-95: scalar (big-endian)
///
/// Output format (64 bytes):
/// - Bytes 0-31: result x coordinate (big-endian)
/// - Bytes 32-63: result y coordinate (big-endian)
///
/// Returns Bn254Result::Success on success, error code otherwise
///
/// # Safety
///
/// This function dereferences raw pointers and requires:
/// - `input` must be valid for reads of `input_len` bytes
/// - `output` must be valid for writes of `output_len` bytes
/// - Pointers must not be null when lengths are non-zero
/// - Caller must ensure input/output buffers don't overlap
#[no_mangle]
pub unsafe extern "C" fn bn254_ecmul(
    input: *const c_uchar,
    input_len: c_uint,
    output: *mut c_uchar,
    output_len: c_uint,
) -> c_int {
    // Validate input parameters
    if input.is_null() || output.is_null() {
        return Bn254Result::InvalidInput as c_int;
    }

    if input_len < 96 || output_len < 64 {
        return Bn254Result::InvalidInput as c_int;
    }

    // Convert pointers to slices
    let input_slice = std::slice::from_raw_parts(input, input_len as usize);
    let output_slice = std::slice::from_raw_parts_mut(output, output_len as usize);

    // Ensure we have exactly 96 bytes of input
    let mut padded_input = [0u8; 96];
    let copy_len = std::cmp::min(input_slice.len(), 96);
    padded_input[..copy_len].copy_from_slice(&input_slice[..copy_len]);

    // Parse the G1 point coordinates (64 bytes)
    let x_bytes = &padded_input[0..32];
    let y_bytes = &padded_input[32..64];

    // Parse the scalar (32 bytes)
    let scalar_bytes = &padded_input[64..96];

    // Convert bytes to field elements
    use ark_bn254::{Fq, Fr};

    let x_coord = Fq::from_be_bytes_mod_order(x_bytes);

    let y_coord = Fq::from_be_bytes_mod_order(y_bytes);

    let scalar = Fr::from_be_bytes_mod_order(scalar_bytes);

    // Create G1 point from coordinates
    let point = match G1Affine::new_unchecked(x_coord, y_coord) {
        p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
        _ => {
            // Invalid point, return point at infinity
            output_slice[..64].fill(0);
            return Bn254Result::Success as c_int;
        }
    };

    // Perform scalar multiplication
    let result_proj = point * scalar;
    let result = result_proj.into_affine();

    // Handle point at infinity
    if result.is_zero() {
        output_slice[..64].fill(0);
        return Bn254Result::Success as c_int;
    }

    // Convert result to bytes (big-endian)
    let x_result = result.x();
    let y_result = result.y();

    let x_bytes = x_result
        .expect("x coordinate should exist")
        .into_bigint()
        .to_bytes_be();
    let y_bytes = y_result
        .expect("y coordinate should exist")
        .into_bigint()
        .to_bytes_be();

    // Pad to 32 bytes and copy to output
    let x_start = 32 - x_bytes.len();

    output_slice[..32].fill(0);
    output_slice[32..64].fill(0);
    output_slice[x_start..32].copy_from_slice(&x_bytes);
    output_slice[32 + (32 - y_bytes.len())..64].copy_from_slice(&y_bytes);

    Bn254Result::Success as c_int
}

/// Perform elliptic curve pairing check (ECPAIRING)
///
/// Input format (multiple of 192 bytes):
/// Each 192-byte group contains:
/// - Bytes 0-63: G1 point (x, y coordinates, 32 bytes each)
/// - Bytes 64-191: G2 point (x and y in Fp2, 64 bytes each)
///
/// Output format (32 bytes):
/// - 32-byte boolean result (0x00...00 for false, 0x00...01 for true)
///
/// Returns Bn254Result::Success on success, error code otherwise
///
/// # Safety
///
/// This function dereferences raw pointers and requires:
/// - `input` must be valid for reads of `input_len` bytes
/// - `output` must be valid for writes of `output_len` bytes
/// - Pointers must not be null when lengths are non-zero
/// - Caller must ensure input/output buffers don't overlap
#[no_mangle]
pub unsafe extern "C" fn bn254_ecpairing(
    input: *const c_uchar,
    input_len: c_uint,
    output: *mut c_uchar,
    output_len: c_uint,
) -> c_int {
    // Validate input parameters
    if input.is_null() || output.is_null() {
        return Bn254Result::InvalidInput as c_int;
    }

    if output_len < 32 {
        return Bn254Result::InvalidInput as c_int;
    }

    // Input must be a multiple of 192 bytes
    if input_len % 192 != 0 {
        return Bn254Result::InvalidInput as c_int;
    }

    // Convert pointers to slices
    let input_slice = std::slice::from_raw_parts(input, input_len as usize);
    let output_slice = std::slice::from_raw_parts_mut(output, output_len as usize);

    use ark_bn254::{Fq, Fq2};

    // Handle empty input (should return true according to EIP-197)
    if input_len == 0 {
        output_slice[..32].fill(0);
        output_slice[31] = 1; // Return true for empty input
        return Bn254Result::Success as c_int;
    }

    let num_pairs = (input_len as usize) / 192;
    let mut g1_points = Vec::with_capacity(num_pairs);
    let mut g2_points = Vec::with_capacity(num_pairs);

    // Parse input pairs
    for i in 0..num_pairs {
        let pair_start = i * 192;

        // Parse G1 point (64 bytes)
        let g1_x_bytes = &input_slice[pair_start..pair_start + 32];
        let g1_y_bytes = &input_slice[pair_start + 32..pair_start + 64];

        let g1_x = Fq::from_be_bytes_mod_order(g1_x_bytes);
        let g1_y = Fq::from_be_bytes_mod_order(g1_y_bytes);

        // Check if this is the point at infinity (both coordinates are zero)
        if g1_x.is_zero() && g1_y.is_zero() {
            g1_points.push(G1Affine::zero());
        } else {
            let g1_point = match G1Affine::new_unchecked(g1_x, g1_y) {
                p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
                _ => {
                    // Invalid G1 point
                    output_slice[..32].fill(0);
                    return Bn254Result::Success as c_int;
                }
            };
            g1_points.push(g1_point);
        }

        // Parse G2 point (128 bytes)
        // G2 coordinates are in Fp2, represented as (a + b*i) where each component is 32 bytes
        let g2_x_c0_bytes = &input_slice[pair_start + 64..pair_start + 96];
        let g2_x_c1_bytes = &input_slice[pair_start + 96..pair_start + 128];
        let g2_y_c0_bytes = &input_slice[pair_start + 128..pair_start + 160];
        let g2_y_c1_bytes = &input_slice[pair_start + 160..pair_start + 192];

        let g2_x_c0 = Fq::from_be_bytes_mod_order(g2_x_c0_bytes);
        let g2_x_c1 = Fq::from_be_bytes_mod_order(g2_x_c1_bytes);
        let g2_y_c0 = Fq::from_be_bytes_mod_order(g2_y_c0_bytes);
        let g2_y_c1 = Fq::from_be_bytes_mod_order(g2_y_c1_bytes);

        let g2_x = Fq2::new(g2_x_c0, g2_x_c1);
        let g2_y = Fq2::new(g2_y_c0, g2_y_c1);

        // Check if this is the point at infinity (both coordinates are zero)
        if g2_x.is_zero() && g2_y.is_zero() {
            g2_points.push(G2Affine::zero());
        } else {
            let g2_point = match G2Affine::new_unchecked(g2_x, g2_y) {
                p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
                _ => {
                    // Invalid G2 point
                    output_slice[..32].fill(0);
                    return Bn254Result::Success as c_int;
                }
            };
            g2_points.push(g2_point);
        }
    }

    // Compute multi-pairing
    let pairing_result = Bn254::multi_pairing(&g1_points, &g2_points);

    // Check if result equals 1 (identity element in GT)
    // For the pairing check, we need to see if the result equals the identity element
    // The identity element in GT for BN254 is represented as 1, not 0
    use ark_ec::pairing::PairingOutput;
    let identity = PairingOutput::<Bn254>(ark_bn254::Fq12::one());
    let is_one = pairing_result == identity;

    // Set output
    output_slice[..32].fill(0);
    if is_one {
        output_slice[31] = 1;
    }

    Bn254Result::Success as c_int
}

/// Get the expected output size for ECMUL
#[no_mangle]
pub extern "C" fn bn254_ecmul_output_size() -> c_uint {
    64
}

/// Get the expected output size for ECPAIRING  
#[no_mangle]
pub extern "C" fn bn254_ecpairing_output_size() -> c_uint {
    32
}

/// Validate ECMUL input format
#[no_mangle]
pub extern "C" fn bn254_ecmul_validate_input(input: *const c_uchar, input_len: c_uint) -> c_int {
    if input.is_null() {
        return Bn254Result::InvalidInput as c_int;
    }

    if input_len < 96 {
        return Bn254Result::InvalidInput as c_int;
    }

    Bn254Result::Success as c_int
}

/// Validate ECPAIRING input format
#[no_mangle]
pub extern "C" fn bn254_ecpairing_validate_input(
    input: *const c_uchar,
    input_len: c_uint,
) -> c_int {
    if input.is_null() {
        return Bn254Result::InvalidInput as c_int;
    }

    if input_len % 192 != 0 {
        return Bn254Result::InvalidInput as c_int;
    }

    Bn254Result::Success as c_int
}

/// Result codes for BLS12-381 operations
#[repr(C)]
pub enum Bls12381Result {
    Success = 0,
    InvalidInput = 1,
    InvalidPoint = 2,
    InvalidScalar = 3,
    ComputationFailed = 4,
}

/// Perform BLS12-381 G1 addition
///
/// Input format (128 bytes):
/// - Bytes 0-47: first point x coordinate (big-endian)
/// - Bytes 48-95: first point y coordinate (big-endian)
/// - Bytes 96-143: second point x coordinate (big-endian)
/// - Bytes 144-191: second point y coordinate (big-endian)
///
/// Output format (96 bytes):
/// - Bytes 0-47: result x coordinate (big-endian)
/// - Bytes 48-95: result y coordinate (big-endian)
///
/// # Safety
///
/// This function dereferences raw pointers and requires:
/// - `input` must be valid for reads of `input_len` bytes
/// - `output` must be valid for writes of `output_len` bytes
#[no_mangle]
pub unsafe extern "C" fn bls12_381_g1_add(
    input: *const c_uchar,
    input_len: c_uint,
    output: *mut c_uchar,
    output_len: c_uint,
) -> c_int {
    if input.is_null() || output.is_null() {
        return Bls12381Result::InvalidInput as c_int;
    }

    if input_len < 256 || output_len < 128 {
        return Bls12381Result::InvalidInput as c_int;
    }

    let input_slice = std::slice::from_raw_parts(input, input_len as usize);
    let output_slice = std::slice::from_raw_parts_mut(output, output_len as usize);

    // Parse first G1 point (128 bytes)
    let p1_x_bytes = &input_slice[0..48];
    let p1_y_bytes = &input_slice[48..96];
    
    // Parse second G1 point (128 bytes)
    let p2_x_bytes = &input_slice[128..176];
    let p2_y_bytes = &input_slice[176..224];

    use ark_bls12_381::Fq;
    
    let p1_x = Fq::from_be_bytes_mod_order(p1_x_bytes);
    let p1_y = Fq::from_be_bytes_mod_order(p1_y_bytes);
    let p2_x = Fq::from_be_bytes_mod_order(p2_x_bytes);
    let p2_y = Fq::from_be_bytes_mod_order(p2_y_bytes);

    // Check for point at infinity
    let p1 = if p1_x.is_zero() && p1_y.is_zero() {
        BlsG1Affine::zero()
    } else {
        match BlsG1Affine::new_unchecked(p1_x, p1_y) {
            p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
            _ => {
                output_slice[..128].fill(0);
                return Bls12381Result::Success as c_int;
            }
        }
    };

    let p2 = if p2_x.is_zero() && p2_y.is_zero() {
        BlsG1Affine::zero()
    } else {
        match BlsG1Affine::new_unchecked(p2_x, p2_y) {
            p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
            _ => {
                output_slice[..128].fill(0);
                return Bls12381Result::Success as c_int;
            }
        }
    };

    // Perform addition
    let result = (p1 + p2).into_affine();

    // Handle point at infinity
    if result.is_zero() {
        output_slice[..128].fill(0);
        return Bls12381Result::Success as c_int;
    }

    // Convert result to bytes
    let x_result = result.x().expect("x coordinate should exist");
    let y_result = result.y().expect("y coordinate should exist");

    let x_bytes = x_result.into_bigint().to_bytes_be();
    let y_bytes = y_result.into_bigint().to_bytes_be();

    // Pad and copy to output
    output_slice[..128].fill(0);
    output_slice[48 - x_bytes.len()..48].copy_from_slice(&x_bytes);
    output_slice[96 - y_bytes.len()..96].copy_from_slice(&y_bytes);

    Bls12381Result::Success as c_int
}

/// Perform BLS12-381 G1 scalar multiplication
///
/// Input format (144 bytes):
/// - Bytes 0-47: x coordinate (big-endian)
/// - Bytes 48-95: y coordinate (big-endian)
/// - Bytes 96-127: scalar (big-endian)
///
/// Output format (128 bytes):
/// - Bytes 0-47: result x coordinate (big-endian)
/// - Bytes 48-95: result y coordinate (big-endian)
///
/// # Safety
///
/// This function dereferences raw pointers and requires:
/// - `input` must be valid for reads of `input_len` bytes
/// - `output` must be valid for writes of `output_len` bytes
#[no_mangle]
pub unsafe extern "C" fn bls12_381_g1_mul(
    input: *const c_uchar,
    input_len: c_uint,
    output: *mut c_uchar,
    output_len: c_uint,
) -> c_int {
    if input.is_null() || output.is_null() {
        return Bls12381Result::InvalidInput as c_int;
    }

    if input_len < 160 || output_len < 128 {
        return Bls12381Result::InvalidInput as c_int;
    }

    let input_slice = std::slice::from_raw_parts(input, input_len as usize);
    let output_slice = std::slice::from_raw_parts_mut(output, output_len as usize);

    // Parse G1 point (128 bytes)
    let x_bytes = &input_slice[0..48];
    let y_bytes = &input_slice[48..96];
    
    // Parse scalar (32 bytes)
    let scalar_bytes = &input_slice[128..160];

    use ark_bls12_381::{Fq, Fr};
    
    let x_coord = Fq::from_be_bytes_mod_order(x_bytes);
    let y_coord = Fq::from_be_bytes_mod_order(y_bytes);
    let scalar = Fr::from_be_bytes_mod_order(scalar_bytes);

    // Check for point at infinity
    let point = if x_coord.is_zero() && y_coord.is_zero() {
        BlsG1Affine::zero()
    } else {
        match BlsG1Affine::new_unchecked(x_coord, y_coord) {
            p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
            _ => {
                output_slice[..128].fill(0);
                return Bls12381Result::Success as c_int;
            }
        }
    };

    // Perform scalar multiplication
    let result = (point * scalar).into_affine();

    // Handle point at infinity
    if result.is_zero() {
        output_slice[..128].fill(0);
        return Bls12381Result::Success as c_int;
    }

    // Convert result to bytes
    let x_result = result.x().expect("x coordinate should exist");
    let y_result = result.y().expect("y coordinate should exist");

    let x_bytes = x_result.into_bigint().to_bytes_be();
    let y_bytes = y_result.into_bigint().to_bytes_be();

    // Pad and copy to output
    output_slice[..128].fill(0);
    output_slice[48 - x_bytes.len()..48].copy_from_slice(&x_bytes);
    output_slice[96 - y_bytes.len()..96].copy_from_slice(&y_bytes);

    Bls12381Result::Success as c_int
}

/// Perform BLS12-381 G1 multi-scalar multiplication
///
/// Input format (variable, 160 * k bytes for k points):
/// Each 160-byte group contains:
/// - Bytes 0-47: x coordinate (big-endian)
/// - Bytes 48-95: y coordinate (big-endian)
/// - Bytes 96-127: scalar (big-endian)
/// - Bytes 128-159: padding (ignored)
///
/// Output format (128 bytes):
/// - Bytes 0-47: result x coordinate (big-endian)
/// - Bytes 48-95: result y coordinate (big-endian)
///
/// # Safety
///
/// This function dereferences raw pointers and requires:
/// - `input` must be valid for reads of `input_len` bytes
/// - `output` must be valid for writes of `output_len` bytes
#[no_mangle]
pub unsafe extern "C" fn bls12_381_g1_multiexp(
    input: *const c_uchar,
    input_len: c_uint,
    output: *mut c_uchar,
    output_len: c_uint,
) -> c_int {
    if input.is_null() || output.is_null() {
        return Bls12381Result::InvalidInput as c_int;
    }

    if input_len % 160 != 0 || output_len < 128 {
        return Bls12381Result::InvalidInput as c_int;
    }

    let input_slice = std::slice::from_raw_parts(input, input_len as usize);
    let output_slice = std::slice::from_raw_parts_mut(output, output_len as usize);

    use ark_bls12_381::{Fq, Fr, G1Projective};
    use ark_ec::VariableBaseMSM;
    
    let num_pairs = (input_len as usize) / 160;
    let mut points = Vec::with_capacity(num_pairs);
    let mut scalars = Vec::with_capacity(num_pairs);

    for i in 0..num_pairs {
        let offset = i * 160;
        let x_bytes = &input_slice[offset..offset + 48];
        let y_bytes = &input_slice[offset + 48..offset + 96];
        let scalar_bytes = &input_slice[offset + 128..offset + 160];

        let x_coord = Fq::from_be_bytes_mod_order(x_bytes);
        let y_coord = Fq::from_be_bytes_mod_order(y_bytes);
        let scalar = Fr::from_be_bytes_mod_order(scalar_bytes);

        // Skip point at infinity
        if x_coord.is_zero() && y_coord.is_zero() {
            continue;
        }

        let point = match BlsG1Affine::new_unchecked(x_coord, y_coord) {
            p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
            _ => continue,
        };

        points.push(point);
        scalars.push(scalar);
    }

    // Perform multi-scalar multiplication
    let result = if points.is_empty() {
        BlsG1Affine::zero()
    } else {
        G1Projective::msm(&points, &scalars).unwrap().into_affine()
    };

    // Handle point at infinity
    if result.is_zero() {
        output_slice[..128].fill(0);
        return Bls12381Result::Success as c_int;
    }

    // Convert result to bytes
    let x_result = result.x().expect("x coordinate should exist");
    let y_result = result.y().expect("y coordinate should exist");

    let x_bytes = x_result.into_bigint().to_bytes_be();
    let y_bytes = y_result.into_bigint().to_bytes_be();

    // Pad and copy to output
    output_slice[..128].fill(0);
    output_slice[48 - x_bytes.len()..48].copy_from_slice(&x_bytes);
    output_slice[96 - y_bytes.len()..96].copy_from_slice(&y_bytes);

    Bls12381Result::Success as c_int
}

/// Perform BLS12-381 pairing check
///
/// Input format (variable, 384 * k bytes for k pairs):
/// Each 384-byte group contains:
/// - Bytes 0-127: G1 point (x, y coordinates, 48 bytes each + 32 bytes padding)
/// - Bytes 128-383: G2 point (x and y in Fp2, 96 bytes each + 64 bytes padding)
///
/// Output format (32 bytes):
/// - 32-byte boolean result (0x00...00 for false, 0x00...01 for true)
///
/// # Safety
///
/// This function dereferences raw pointers and requires:
/// - `input` must be valid for reads of `input_len` bytes
/// - `output` must be valid for writes of `output_len` bytes
#[no_mangle]
pub unsafe extern "C" fn bls12_381_pairing(
    input: *const c_uchar,
    input_len: c_uint,
    output: *mut c_uchar,
    output_len: c_uint,
) -> c_int {
    if input.is_null() || output.is_null() {
        return Bls12381Result::InvalidInput as c_int;
    }

    if input_len % 384 != 0 || output_len < 32 {
        return Bls12381Result::InvalidInput as c_int;
    }

    let input_slice = std::slice::from_raw_parts(input, input_len as usize);
    let output_slice = std::slice::from_raw_parts_mut(output, output_len as usize);

    use ark_bls12_381::{Fq, Fq2, Fq12};
    
    let num_pairs = (input_len as usize) / 384;
    let mut g1_points = Vec::with_capacity(num_pairs);
    let mut g2_points = Vec::with_capacity(num_pairs);

    // Handle empty input (should return true according to EIP-2537)
    if input_len == 0 {
        output_slice[..32].fill(0);
        output_slice[31] = 1;
        return Bls12381Result::Success as c_int;
    }

    for i in 0..num_pairs {
        let offset = i * 384;
        
        // Parse G1 point (128 bytes)
        let g1_x_bytes = &input_slice[offset..offset + 48];
        let g1_y_bytes = &input_slice[offset + 48..offset + 96];

        let g1_x = Fq::from_be_bytes_mod_order(g1_x_bytes);
        let g1_y = Fq::from_be_bytes_mod_order(g1_y_bytes);

        let g1_point = if g1_x.is_zero() && g1_y.is_zero() {
            BlsG1Affine::zero()
        } else {
            match BlsG1Affine::new_unchecked(g1_x, g1_y) {
                p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
                _ => {
                    output_slice[..32].fill(0);
                    return Bls12381Result::Success as c_int;
                }
            }
        };
        g1_points.push(g1_point);

        // Parse G2 point (256 bytes)
        // G2 coordinates are in Fp2
        let g2_x_c0_bytes = &input_slice[offset + 128..offset + 176];
        let g2_x_c1_bytes = &input_slice[offset + 176..offset + 224];
        let g2_y_c0_bytes = &input_slice[offset + 224..offset + 272];
        let g2_y_c1_bytes = &input_slice[offset + 272..offset + 320];

        let g2_x_c0 = Fq::from_be_bytes_mod_order(g2_x_c0_bytes);
        let g2_x_c1 = Fq::from_be_bytes_mod_order(g2_x_c1_bytes);
        let g2_y_c0 = Fq::from_be_bytes_mod_order(g2_y_c0_bytes);
        let g2_y_c1 = Fq::from_be_bytes_mod_order(g2_y_c1_bytes);

        let g2_x = Fq2::new(g2_x_c0, g2_x_c1);
        let g2_y = Fq2::new(g2_y_c0, g2_y_c1);

        let g2_point = if g2_x.is_zero() && g2_y.is_zero() {
            BlsG2Affine::zero()
        } else {
            match BlsG2Affine::new_unchecked(g2_x, g2_y) {
                p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
                _ => {
                    output_slice[..32].fill(0);
                    return Bls12381Result::Success as c_int;
                }
            }
        };
        g2_points.push(g2_point);
    }

    // Compute multi-pairing
    let pairing_result = Bls12_381::multi_pairing(&g1_points, &g2_points);

    // Check if result equals 1 (identity element in GT)
    use ark_ec::pairing::PairingOutput;
    let identity = PairingOutput::<Bls12_381>(Fq12::one());
    let is_one = pairing_result == identity;

    // Set output
    output_slice[..32].fill(0);
    if is_one {
        output_slice[31] = 1;
    }

    Bls12381Result::Success as c_int
}

/// Get the expected output size for BLS12-381 G1 operations
#[no_mangle]
pub extern "C" fn bls12_381_g1_output_size() -> c_uint {
    128
}

/// Get the expected output size for BLS12-381 pairing
#[no_mangle]
pub extern "C" fn bls12_381_pairing_output_size() -> c_uint {
    32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bn254_init() {
        let result = bn254_init();
        assert_eq!(result, Bn254Result::Success as c_int);
    }

    #[test]
    fn test_output_sizes() {
        assert_eq!(bn254_ecmul_output_size(), 64);
        assert_eq!(bn254_ecpairing_output_size(), 32);
    }

    #[test]
    fn test_input_validation() {
        // Test null pointer
        assert_eq!(
            bn254_ecmul_validate_input(std::ptr::null(), 96),
            Bn254Result::InvalidInput as c_int
        );

        // Test invalid size
        let dummy_data = [0u8; 50];
        assert_eq!(
            bn254_ecmul_validate_input(dummy_data.as_ptr(), 50),
            Bn254Result::InvalidInput as c_int
        );

        // Test valid size
        let dummy_data = [0u8; 96];
        assert_eq!(
            bn254_ecmul_validate_input(dummy_data.as_ptr(), 96),
            Bn254Result::Success as c_int
        );
    }

    #[test]
    fn test_pairing_input_validation() {
        // Test invalid size (not multiple of 192)
        let dummy_data = [0u8; 100];
        assert_eq!(
            bn254_ecpairing_validate_input(dummy_data.as_ptr(), 100),
            Bn254Result::InvalidInput as c_int
        );

        // Test valid size (multiple of 192)
        let dummy_data = [0u8; 192];
        assert_eq!(
            bn254_ecpairing_validate_input(dummy_data.as_ptr(), 192),
            Bn254Result::Success as c_int
        );
    }
}
