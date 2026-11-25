use ark_bls12_381::{Bls12_381, G1Affine as BlsG1Affine, G2Affine as BlsG2Affine};
use ark_bn254::{Bn254, G1Affine, G2Affine};
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

// The caller owns the returned Vec; a failed second allocation drops the first.
fn reserved<T>(count: usize) -> Result<Vec<T>, std::collections::TryReserveError> {
    let mut values = Vec::new();
    values.try_reserve_exact(count)?;
    Ok(values)
}

// Arkworks fields used here fit in six limbs. Encode without heap allocation.
fn field_bytes<const N: usize>(value: impl BigInteger) -> [u8; N] {
    let mut bytes = [0u8; N];
    for (index, limb) in value.as_ref().iter().enumerate() {
        let end = N - index * 8;
        bytes[end - 8..end].copy_from_slice(&limb.to_be_bytes());
    }
    bytes
}

// Arkworks' big-endian decoder copies into a Vec. Reverse these bounded
// encodings on the stack and use its allocation-free little-endian decoder.
fn field_from_be<F: PrimeField>(bytes: &[u8]) -> F {
    let mut buffer = [0u8; 48];
    let value = &mut buffer[..bytes.len()];
    value.copy_from_slice(bytes);
    value.reverse();
    F::from_le_bytes_mod_order(value)
}

// Reject noncanonical field encodings before arkworks can reduce them.
fn canonical<F: PrimeField>(bytes: &[u8]) -> Option<F> {
    let encoded = field_bytes::<48>(F::MODULUS);
    let modulus = &encoded[48 - F::BigInt::NUM_LIMBS * 8..];
    if bytes.len() < modulus.len() {
        return None;
    }
    let padding = bytes.len() - modulus.len();
    if bytes[..padding].iter().any(|byte| *byte != 0) || bytes[padding..] >= modulus[..] {
        return None;
    }
    Some(field_from_be::<F>(&bytes[padding..]))
}

macro_rules! field {
    ($bytes:expr, $result:ident) => {
        match canonical::<Fq>($bytes) {
            Some(value) => value,
            None => return $result::InvalidPoint as c_int,
        }
    };
}

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
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });

        // ethereum-bn128 doesn't require explicit initialization
        Bn254Result::Success as c_int
    })) {
        Ok(result) => result,
        Err(payload) => {
            // A user panic payload can itself panic on Drop. Retain it rather
            // than risk a second unwind crossing the C boundary.
            std::mem::forget(payload);
            Bn254Result::ComputationFailed as c_int
        }
    }
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
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });

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

        let x_coord = field!(x_bytes, Bn254Result);

        let y_coord = field!(y_bytes, Bn254Result);

        let scalar = field_from_be::<Fr>(scalar_bytes);

        // Create G1 point from coordinates
        let point = if x_coord.is_zero() && y_coord.is_zero() {
            G1Affine::zero()
        } else {
            match G1Affine::new_unchecked(x_coord, y_coord) {
                p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
                _ => {
                    return Bn254Result::InvalidPoint as c_int;
                }
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

        let x_bytes = field_bytes::<32>(result.x.into_bigint());
        let y_bytes = field_bytes::<32>(result.y.into_bigint());

        // Pad to 32 bytes and copy to output
        let x_start = 32 - x_bytes.len();

        output_slice[..32].fill(0);
        output_slice[32..64].fill(0);
        output_slice[x_start..32].copy_from_slice(&x_bytes);
        output_slice[32 + (32 - y_bytes.len())..64].copy_from_slice(&y_bytes);

        Bn254Result::Success as c_int
    })) {
        Ok(result) => result,
        Err(payload) => {
            // A user panic payload can itself panic on Drop. Retain it rather
            // than risk a second unwind crossing the C boundary.
            std::mem::forget(payload);
            Bn254Result::ComputationFailed as c_int
        }
    }
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
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });

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
        let mut g1_points = match reserved(num_pairs) {
            Ok(values) => values,
            Err(_) => return Bn254Result::ComputationFailed as c_int,
        };
        let mut g2_points = match reserved(num_pairs) {
            Ok(values) => values,
            Err(_) => return Bn254Result::ComputationFailed as c_int,
        };

        // Parse input pairs
        for i in 0..num_pairs {
            let pair_start = i * 192;

            // Parse G1 point (64 bytes)
            let g1_x_bytes = &input_slice[pair_start..pair_start + 32];
            let g1_y_bytes = &input_slice[pair_start + 32..pair_start + 64];

            let g1_x = field!(g1_x_bytes, Bn254Result);
            let g1_y = field!(g1_y_bytes, Bn254Result);

            // Check if this is the point at infinity (both coordinates are zero)
            if g1_x.is_zero() && g1_y.is_zero() {
                g1_points.push(G1Affine::zero());
            } else {
                let g1_point = match G1Affine::new_unchecked(g1_x, g1_y) {
                    p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
                    _ => {
                        return Bn254Result::InvalidPoint as c_int;
                    }
                };
                g1_points.push(g1_point);
            }

            // Parse G2 point (128 bytes)
            // EIP-197 encodes Fp2 as imaginary component first, then real (32 bytes each).
            let g2_x_c0_bytes = &input_slice[pair_start + 96..pair_start + 128];
            let g2_x_c1_bytes = &input_slice[pair_start + 64..pair_start + 96];
            let g2_y_c0_bytes = &input_slice[pair_start + 160..pair_start + 192];
            let g2_y_c1_bytes = &input_slice[pair_start + 128..pair_start + 160];

            let g2_x_c0 = field!(g2_x_c0_bytes, Bn254Result);
            let g2_x_c1 = field!(g2_x_c1_bytes, Bn254Result);
            let g2_y_c0 = field!(g2_y_c0_bytes, Bn254Result);
            let g2_y_c1 = field!(g2_y_c1_bytes, Bn254Result);

            let g2_x = Fq2::new(g2_x_c0, g2_x_c1);
            let g2_y = Fq2::new(g2_y_c0, g2_y_c1);

            // Check if this is the point at infinity (both coordinates are zero)
            if g2_x.is_zero() && g2_y.is_zero() {
                g2_points.push(G2Affine::zero());
            } else {
                let g2_point = match G2Affine::new_unchecked(g2_x, g2_y) {
                    p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
                    _ => {
                        return Bn254Result::InvalidPoint as c_int;
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
    })) {
        Ok(result) => result,
        Err(payload) => {
            // A user panic payload can itself panic on Drop. Retain it rather
            // than risk a second unwind crossing the C boundary.
            std::mem::forget(payload);
            Bn254Result::ComputationFailed as c_int
        }
    }
}

/// Get the expected output size for ECMUL
#[no_mangle]
pub extern "C" fn bn254_ecmul_output_size() -> c_uint {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });

        64
    })) {
        Ok(result) => result,
        Err(payload) => {
            // A user panic payload can itself panic on Drop. Retain it rather
            // than risk a second unwind crossing the C boundary.
            std::mem::forget(payload);
            0
        }
    }
}

/// Get the expected output size for ECPAIRING  
#[no_mangle]
pub extern "C" fn bn254_ecpairing_output_size() -> c_uint {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });

        32
    })) {
        Ok(result) => result,
        Err(payload) => {
            // A user panic payload can itself panic on Drop. Retain it rather
            // than risk a second unwind crossing the C boundary.
            std::mem::forget(payload);
            0
        }
    }
}

/// Validate ECMUL input format
#[no_mangle]
pub extern "C" fn bn254_ecmul_validate_input(input: *const c_uchar, input_len: c_uint) -> c_int {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });

        if input.is_null() {
            return Bn254Result::InvalidInput as c_int;
        }

        if input_len < 96 {
            return Bn254Result::InvalidInput as c_int;
        }

        Bn254Result::Success as c_int
    })) {
        Ok(result) => result,
        Err(payload) => {
            // A user panic payload can itself panic on Drop. Retain it rather
            // than risk a second unwind crossing the C boundary.
            std::mem::forget(payload);
            Bn254Result::ComputationFailed as c_int
        }
    }
}

/// Validate ECPAIRING input format
#[no_mangle]
pub extern "C" fn bn254_ecpairing_validate_input(
    input: *const c_uchar,
    input_len: c_uint,
) -> c_int {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });

        if input.is_null() {
            return Bn254Result::InvalidInput as c_int;
        }

        if input_len % 192 != 0 {
            return Bn254Result::InvalidInput as c_int;
        }

        Bn254Result::Success as c_int
    })) {
        Ok(result) => result,
        Err(payload) => {
            // A user panic payload can itself panic on Drop. Retain it rather
            // than risk a second unwind crossing the C boundary.
            std::mem::forget(payload);
            Bn254Result::ComputationFailed as c_int
        }
    }
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

/// EIP-2537 encoding: each Fp is 16 zero bytes followed by 48 big-endian bytes.
/// Fp2 components are c0, c1; scalars are 32 big-endian bytes.
/// ADD requires curve membership; multiplication/MSM/pairing also require subgroup membership.
///
/// # Safety
/// Input and output must be valid, nonoverlapping buffers for the supplied lengths.
#[no_mangle]
pub unsafe extern "C" fn bls12_381_g1_add(
    input: *const c_uchar,
    input_len: c_uint,
    output: *mut c_uchar,
    output_len: c_uint,
) -> c_int {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });

        if input.is_null() || output.is_null() {
            return Bls12381Result::InvalidInput as c_int;
        }

        if input_len != 256 || output_len < 128 {
            return Bls12381Result::InvalidInput as c_int;
        }

        let input_slice = std::slice::from_raw_parts(input, input_len as usize);
        let output_slice = std::slice::from_raw_parts_mut(output, output_len as usize);

        // Parse first G1 point (128 bytes)
        let p1_x_bytes = &input_slice[0..64];
        let p1_y_bytes = &input_slice[64..128];

        // Parse second G1 point (128 bytes)
        let p2_x_bytes = &input_slice[128..192];
        let p2_y_bytes = &input_slice[192..256];

        use ark_bls12_381::Fq;

        let p1_x = field!(p1_x_bytes, Bls12381Result);
        let p1_y = field!(p1_y_bytes, Bls12381Result);
        let p2_x = field!(p2_x_bytes, Bls12381Result);
        let p2_y = field!(p2_y_bytes, Bls12381Result);

        // Check for point at infinity
        let p1 = if p1_x.is_zero() && p1_y.is_zero() {
            BlsG1Affine::zero()
        } else {
            match BlsG1Affine::new_unchecked(p1_x, p1_y) {
                p if p.is_on_curve() => p,
                _ => return Bls12381Result::InvalidPoint as c_int,
            }
        };

        let p2 = if p2_x.is_zero() && p2_y.is_zero() {
            BlsG1Affine::zero()
        } else {
            match BlsG1Affine::new_unchecked(p2_x, p2_y) {
                p if p.is_on_curve() => p,
                _ => return Bls12381Result::InvalidPoint as c_int,
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
        let x_result = result.x;
        let y_result = result.y;

        let x_bytes = field_bytes::<48>(x_result.into_bigint());
        let y_bytes = field_bytes::<48>(y_result.into_bigint());

        // Pad and copy to output
        output_slice[..128].fill(0);
        output_slice[64 - x_bytes.len()..64].copy_from_slice(&x_bytes);
        output_slice[128 - y_bytes.len()..128].copy_from_slice(&y_bytes);

        Bls12381Result::Success as c_int
    })) {
        Ok(result) => result,
        Err(payload) => {
            // A user panic payload can itself panic on Drop. Retain it rather
            // than risk a second unwind crossing the C boundary.
            std::mem::forget(payload);
            Bls12381Result::ComputationFailed as c_int
        }
    }
}

/// EIP-2537 encoding: each Fp is 16 zero bytes followed by 48 big-endian bytes.
/// Fp2 components are c0, c1; scalars are 32 big-endian bytes.
/// ADD requires curve membership; multiplication/MSM/pairing also require subgroup membership.
///
/// # Safety
/// Input and output must be valid, nonoverlapping buffers for the supplied lengths.
#[no_mangle]
pub unsafe extern "C" fn bls12_381_g1_mul(
    input: *const c_uchar,
    input_len: c_uint,
    output: *mut c_uchar,
    output_len: c_uint,
) -> c_int {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });

        if input.is_null() || output.is_null() {
            return Bls12381Result::InvalidInput as c_int;
        }

        if input_len != 160 || output_len < 128 {
            return Bls12381Result::InvalidInput as c_int;
        }

        let input_slice = std::slice::from_raw_parts(input, input_len as usize);
        let output_slice = std::slice::from_raw_parts_mut(output, output_len as usize);

        // Parse G1 point (128 bytes)
        let x_bytes = &input_slice[0..64];
        let y_bytes = &input_slice[64..128];

        // Parse scalar (32 bytes)
        let scalar_bytes = &input_slice[128..160];

        use ark_bls12_381::{Fq, Fr};

        let x_coord = field!(x_bytes, Bls12381Result);
        let y_coord = field!(y_bytes, Bls12381Result);
        let scalar = field_from_be::<Fr>(scalar_bytes);

        // Check for point at infinity
        let point = if x_coord.is_zero() && y_coord.is_zero() {
            BlsG1Affine::zero()
        } else {
            match BlsG1Affine::new_unchecked(x_coord, y_coord) {
                p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
                _ => return Bls12381Result::InvalidPoint as c_int,
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
        let x_result = result.x;
        let y_result = result.y;

        let x_bytes = field_bytes::<48>(x_result.into_bigint());
        let y_bytes = field_bytes::<48>(y_result.into_bigint());

        // Pad and copy to output
        output_slice[..128].fill(0);
        output_slice[64 - x_bytes.len()..64].copy_from_slice(&x_bytes);
        output_slice[128 - y_bytes.len()..128].copy_from_slice(&y_bytes);

        Bls12381Result::Success as c_int
    })) {
        Ok(result) => result,
        Err(payload) => {
            // A user panic payload can itself panic on Drop. Retain it rather
            // than risk a second unwind crossing the C boundary.
            std::mem::forget(payload);
            Bls12381Result::ComputationFailed as c_int
        }
    }
}

/// EIP-2537 encoding: each Fp is 16 zero bytes followed by 48 big-endian bytes.
/// Fp2 components are c0, c1; scalars are 32 big-endian bytes.
/// ADD requires curve membership; multiplication/MSM/pairing also require subgroup membership.
///
/// # Safety
/// Input and output must be valid, nonoverlapping buffers for the supplied lengths.
#[no_mangle]
pub unsafe extern "C" fn bls12_381_g1_multiexp(
    input: *const c_uchar,
    input_len: c_uint,
    output: *mut c_uchar,
    output_len: c_uint,
) -> c_int {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });

        if input.is_null() || output.is_null() {
            return Bls12381Result::InvalidInput as c_int;
        }

        if input_len == 0 || input_len % 160 != 0 || output_len < 128 {
            return Bls12381Result::InvalidInput as c_int;
        }

        let input_slice = std::slice::from_raw_parts(input, input_len as usize);
        let output_slice = std::slice::from_raw_parts_mut(output, output_len as usize);

        use ark_bls12_381::{Fq, Fr, G1Projective};
        use ark_ec::VariableBaseMSM;

        let num_pairs = (input_len as usize) / 160;
        let mut points = match reserved(num_pairs) {
            Ok(values) => values,
            Err(_) => return Bls12381Result::ComputationFailed as c_int,
        };
        let mut scalars = match reserved(num_pairs) {
            Ok(values) => values,
            Err(_) => return Bls12381Result::ComputationFailed as c_int,
        };

        for i in 0..num_pairs {
            let offset = i * 160;
            let x_bytes = &input_slice[offset + 0..offset + 64];
            let y_bytes = &input_slice[offset + 64..offset + 128];
            let scalar_bytes = &input_slice[offset + 128..offset + 160];

            let x_coord = field!(x_bytes, Bls12381Result);
            let y_coord = field!(y_bytes, Bls12381Result);
            let scalar = field_from_be::<Fr>(scalar_bytes);

            // Skip point at infinity
            if x_coord.is_zero() && y_coord.is_zero() {
                continue;
            }

            let point = match BlsG1Affine::new_unchecked(x_coord, y_coord) {
                p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
                _ => return Bls12381Result::InvalidPoint as c_int,
            };

            points.push(point);
            scalars.push(scalar);
        }

        // Perform multi-scalar multiplication
        let result = if points.is_empty() {
            BlsG1Affine::zero()
        } else {
            match G1Projective::msm(&points, &scalars) {
                Ok(result) => result.into_affine(),
                Err(_) => return Bls12381Result::ComputationFailed as c_int,
            }
        };

        // Handle point at infinity
        if result.is_zero() {
            output_slice[..128].fill(0);
            return Bls12381Result::Success as c_int;
        }

        // Convert result to bytes
        let x_result = result.x;
        let y_result = result.y;

        let x_bytes = field_bytes::<48>(x_result.into_bigint());
        let y_bytes = field_bytes::<48>(y_result.into_bigint());

        // Pad and copy to output
        output_slice[..128].fill(0);
        output_slice[64 - x_bytes.len()..64].copy_from_slice(&x_bytes);
        output_slice[128 - y_bytes.len()..128].copy_from_slice(&y_bytes);

        Bls12381Result::Success as c_int
    })) {
        Ok(result) => result,
        Err(payload) => {
            // A user panic payload can itself panic on Drop. Retain it rather
            // than risk a second unwind crossing the C boundary.
            std::mem::forget(payload);
            Bls12381Result::ComputationFailed as c_int
        }
    }
}

/// EIP-2537 encoding: each Fp is 16 zero bytes followed by 48 big-endian bytes.
/// Fp2 components are c0, c1; scalars are 32 big-endian bytes.
/// ADD requires curve membership; multiplication/MSM/pairing also require subgroup membership.
///
/// # Safety
/// Input and output must be valid, nonoverlapping buffers for the supplied lengths.
#[no_mangle]
pub unsafe extern "C" fn bls12_381_pairing(
    input: *const c_uchar,
    input_len: c_uint,
    output: *mut c_uchar,
    output_len: c_uint,
) -> c_int {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });

        if input.is_null() || output.is_null() {
            return Bls12381Result::InvalidInput as c_int;
        }

        if input_len == 0 || input_len % 384 != 0 || output_len < 32 {
            return Bls12381Result::InvalidInput as c_int;
        }

        let input_slice = std::slice::from_raw_parts(input, input_len as usize);
        let output_slice = std::slice::from_raw_parts_mut(output, output_len as usize);

        use ark_bls12_381::{Fq, Fq12, Fq2};

        let num_pairs = (input_len as usize) / 384;
        let mut g1_points = match reserved(num_pairs) {
            Ok(values) => values,
            Err(_) => return Bls12381Result::ComputationFailed as c_int,
        };
        let mut g2_points = match reserved(num_pairs) {
            Ok(values) => values,
            Err(_) => return Bls12381Result::ComputationFailed as c_int,
        };

        for i in 0..num_pairs {
            let offset = i * 384;

            // Parse G1 point (128 bytes)
            let g1_x_bytes = &input_slice[offset + 0..offset + 64];
            let g1_y_bytes = &input_slice[offset + 64..offset + 128];

            let g1_x = field!(g1_x_bytes, Bls12381Result);
            let g1_y = field!(g1_y_bytes, Bls12381Result);

            let g1_point = if g1_x.is_zero() && g1_y.is_zero() {
                BlsG1Affine::zero()
            } else {
                match BlsG1Affine::new_unchecked(g1_x, g1_y) {
                    p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
                    _ => return Bls12381Result::InvalidPoint as c_int,
                }
            };
            g1_points.push(g1_point);

            // Parse G2 point (256 bytes)
            // G2 coordinates are in Fp2
            let g2_x_c0_bytes = &input_slice[offset + 128..offset + 192];
            let g2_x_c1_bytes = &input_slice[offset + 192..offset + 256];
            let g2_y_c0_bytes = &input_slice[offset + 256..offset + 320];
            let g2_y_c1_bytes = &input_slice[offset + 320..offset + 384];

            let g2_x_c0 = field!(g2_x_c0_bytes, Bls12381Result);
            let g2_x_c1 = field!(g2_x_c1_bytes, Bls12381Result);
            let g2_y_c0 = field!(g2_y_c0_bytes, Bls12381Result);
            let g2_y_c1 = field!(g2_y_c1_bytes, Bls12381Result);

            let g2_x = Fq2::new(g2_x_c0, g2_x_c1);
            let g2_y = Fq2::new(g2_y_c0, g2_y_c1);

            let g2_point = if g2_x.is_zero() && g2_y.is_zero() {
                BlsG2Affine::zero()
            } else {
                match BlsG2Affine::new_unchecked(g2_x, g2_y) {
                    p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
                    _ => return Bls12381Result::InvalidPoint as c_int,
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
    })) {
        Ok(result) => result,
        Err(payload) => {
            // A user panic payload can itself panic on Drop. Retain it rather
            // than risk a second unwind crossing the C boundary.
            std::mem::forget(payload);
            Bls12381Result::ComputationFailed as c_int
        }
    }
}

/// Get the expected output size for BLS12-381 G1 operations
#[no_mangle]
pub extern "C" fn bls12_381_g1_output_size() -> c_uint {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });

        128
    })) {
        Ok(result) => result,
        Err(payload) => {
            // A user panic payload can itself panic on Drop. Retain it rather
            // than risk a second unwind crossing the C boundary.
            std::mem::forget(payload);
            0
        }
    }
}

/// Get the expected output size for BLS12-381 pairing
#[no_mangle]
pub extern "C" fn bls12_381_pairing_output_size() -> c_uint {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });

        32
    })) {
        Ok(result) => result,
        Err(payload) => {
            // A user panic payload can itself panic on Drop. Retain it rather
            // than risk a second unwind crossing the C boundary.
            std::mem::forget(payload);
            0
        }
    }
}

/// EIP-2537 encoding: each Fp is 16 zero bytes followed by 48 big-endian bytes.
/// Fp2 components are c0, c1; scalars are 32 big-endian bytes.
/// ADD requires curve membership; multiplication/MSM/pairing also require subgroup membership.
///
/// # Safety
/// Input and output must be valid, nonoverlapping buffers for the supplied lengths.
#[no_mangle]
pub unsafe extern "C" fn bls12_381_g2_add(
    input: *const c_uchar,
    input_len: c_uint,
    output: *mut c_uchar,
    output_len: c_uint,
) -> c_int {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });

        if input.is_null() || output.is_null() {
            return Bls12381Result::InvalidInput as c_int;
        }

        if input_len != 512 || output_len < 256 {
            return Bls12381Result::InvalidInput as c_int;
        }

        let input_slice = std::slice::from_raw_parts(input, input_len as usize);
        let output_slice = std::slice::from_raw_parts_mut(output, output_len as usize);

        use ark_bls12_381::{Fq, Fq2};

        // Parse first G2 point (256 bytes)
        let p1_x_c0_bytes = &input_slice[0..64];
        let p1_x_c1_bytes = &input_slice[64..128];
        let p1_y_c0_bytes = &input_slice[128..192];
        let p1_y_c1_bytes = &input_slice[192..256];

        // Parse second G2 point (256 bytes)
        let p2_x_c0_bytes = &input_slice[256..320];
        let p2_x_c1_bytes = &input_slice[320..384];
        let p2_y_c0_bytes = &input_slice[384..448];
        let p2_y_c1_bytes = &input_slice[448..512];

        let p1_x_c0 = field!(p1_x_c0_bytes, Bls12381Result);
        let p1_x_c1 = field!(p1_x_c1_bytes, Bls12381Result);
        let p1_y_c0 = field!(p1_y_c0_bytes, Bls12381Result);
        let p1_y_c1 = field!(p1_y_c1_bytes, Bls12381Result);
        let p1_x = Fq2::new(p1_x_c0, p1_x_c1);
        let p1_y = Fq2::new(p1_y_c0, p1_y_c1);

        let p2_x_c0 = field!(p2_x_c0_bytes, Bls12381Result);
        let p2_x_c1 = field!(p2_x_c1_bytes, Bls12381Result);
        let p2_y_c0 = field!(p2_y_c0_bytes, Bls12381Result);
        let p2_y_c1 = field!(p2_y_c1_bytes, Bls12381Result);
        let p2_x = Fq2::new(p2_x_c0, p2_x_c1);
        let p2_y = Fq2::new(p2_y_c0, p2_y_c1);

        // Check for point at infinity
        let p1 = if p1_x.is_zero() && p1_y.is_zero() {
            BlsG2Affine::zero()
        } else {
            match BlsG2Affine::new_unchecked(p1_x, p1_y) {
                p if p.is_on_curve() => p,
                _ => return Bls12381Result::InvalidPoint as c_int,
            }
        };

        let p2 = if p2_x.is_zero() && p2_y.is_zero() {
            BlsG2Affine::zero()
        } else {
            match BlsG2Affine::new_unchecked(p2_x, p2_y) {
                p if p.is_on_curve() => p,
                _ => return Bls12381Result::InvalidPoint as c_int,
            }
        };

        // Perform addition
        let result = (p1 + p2).into_affine();

        // Handle point at infinity
        if result.is_zero() {
            output_slice[..256].fill(0);
            return Bls12381Result::Success as c_int;
        }

        // Convert result to bytes
        let x_result = result.x;
        let y_result = result.y;

        let x_c0_bytes = field_bytes::<48>(x_result.c0.into_bigint());
        let x_c1_bytes = field_bytes::<48>(x_result.c1.into_bigint());
        let y_c0_bytes = field_bytes::<48>(y_result.c0.into_bigint());
        let y_c1_bytes = field_bytes::<48>(y_result.c1.into_bigint());

        // Pad and copy to output
        output_slice[..256].fill(0);
        output_slice[64 - x_c0_bytes.len()..64].copy_from_slice(&x_c0_bytes);
        output_slice[128 - x_c1_bytes.len()..128].copy_from_slice(&x_c1_bytes);
        output_slice[192 - y_c0_bytes.len()..192].copy_from_slice(&y_c0_bytes);
        output_slice[256 - y_c1_bytes.len()..256].copy_from_slice(&y_c1_bytes);

        Bls12381Result::Success as c_int
    })) {
        Ok(result) => result,
        Err(payload) => {
            // A user panic payload can itself panic on Drop. Retain it rather
            // than risk a second unwind crossing the C boundary.
            std::mem::forget(payload);
            Bls12381Result::ComputationFailed as c_int
        }
    }
}

/// EIP-2537 encoding: each Fp is 16 zero bytes followed by 48 big-endian bytes.
/// Fp2 components are c0, c1; scalars are 32 big-endian bytes.
/// ADD requires curve membership; multiplication/MSM/pairing also require subgroup membership.
///
/// # Safety
/// Input and output must be valid, nonoverlapping buffers for the supplied lengths.
#[no_mangle]
pub unsafe extern "C" fn bls12_381_g2_mul(
    input: *const c_uchar,
    input_len: c_uint,
    output: *mut c_uchar,
    output_len: c_uint,
) -> c_int {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });

        if input.is_null() || output.is_null() {
            return Bls12381Result::InvalidInput as c_int;
        }

        if input_len != 288 || output_len < 256 {
            return Bls12381Result::InvalidInput as c_int;
        }

        let input_slice = std::slice::from_raw_parts(input, input_len as usize);
        let output_slice = std::slice::from_raw_parts_mut(output, output_len as usize);

        use ark_bls12_381::{Fq, Fq2, Fr};

        // Parse G2 point (256 bytes)
        let x_c0_bytes = &input_slice[0..64];
        let x_c1_bytes = &input_slice[64..128];
        let y_c0_bytes = &input_slice[128..192];
        let y_c1_bytes = &input_slice[192..256];

        // Parse scalar (32 bytes)
        let scalar_bytes = &input_slice[256..288];

        let x_c0 = field!(x_c0_bytes, Bls12381Result);
        let x_c1 = field!(x_c1_bytes, Bls12381Result);
        let y_c0 = field!(y_c0_bytes, Bls12381Result);
        let y_c1 = field!(y_c1_bytes, Bls12381Result);
        let x_coord = Fq2::new(x_c0, x_c1);
        let y_coord = Fq2::new(y_c0, y_c1);
        let scalar = field_from_be::<Fr>(scalar_bytes);

        // Check for point at infinity
        let point = if x_coord.is_zero() && y_coord.is_zero() {
            BlsG2Affine::zero()
        } else {
            match BlsG2Affine::new_unchecked(x_coord, y_coord) {
                p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
                _ => return Bls12381Result::InvalidPoint as c_int,
            }
        };

        // Perform scalar multiplication
        let result = (point * scalar).into_affine();

        // Handle point at infinity
        if result.is_zero() {
            output_slice[..256].fill(0);
            return Bls12381Result::Success as c_int;
        }

        // Convert result to bytes
        let x_result = result.x;
        let y_result = result.y;

        let x_c0_bytes = field_bytes::<48>(x_result.c0.into_bigint());
        let x_c1_bytes = field_bytes::<48>(x_result.c1.into_bigint());
        let y_c0_bytes = field_bytes::<48>(y_result.c0.into_bigint());
        let y_c1_bytes = field_bytes::<48>(y_result.c1.into_bigint());

        // Pad and copy to output
        output_slice[..256].fill(0);
        output_slice[64 - x_c0_bytes.len()..64].copy_from_slice(&x_c0_bytes);
        output_slice[128 - x_c1_bytes.len()..128].copy_from_slice(&x_c1_bytes);
        output_slice[192 - y_c0_bytes.len()..192].copy_from_slice(&y_c0_bytes);
        output_slice[256 - y_c1_bytes.len()..256].copy_from_slice(&y_c1_bytes);

        Bls12381Result::Success as c_int
    })) {
        Ok(result) => result,
        Err(payload) => {
            // A user panic payload can itself panic on Drop. Retain it rather
            // than risk a second unwind crossing the C boundary.
            std::mem::forget(payload);
            Bls12381Result::ComputationFailed as c_int
        }
    }
}

/// EIP-2537 encoding: each Fp is 16 zero bytes followed by 48 big-endian bytes.
/// Fp2 components are c0, c1; scalars are 32 big-endian bytes.
/// ADD requires curve membership; multiplication/MSM/pairing also require subgroup membership.
///
/// # Safety
/// Input and output must be valid, nonoverlapping buffers for the supplied lengths.
#[no_mangle]
pub unsafe extern "C" fn bls12_381_g2_multiexp(
    input: *const c_uchar,
    input_len: c_uint,
    output: *mut c_uchar,
    output_len: c_uint,
) -> c_int {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });

        if input.is_null() || output.is_null() {
            return Bls12381Result::InvalidInput as c_int;
        }

        if input_len == 0 || input_len % 288 != 0 || output_len < 256 {
            return Bls12381Result::InvalidInput as c_int;
        }

        let input_slice = std::slice::from_raw_parts(input, input_len as usize);
        let output_slice = std::slice::from_raw_parts_mut(output, output_len as usize);

        use ark_bls12_381::{Fq, Fq2, Fr, G2Projective};
        use ark_ec::VariableBaseMSM;

        let num_pairs = (input_len as usize) / 288;
        let mut points = match reserved(num_pairs) {
            Ok(values) => values,
            Err(_) => return Bls12381Result::ComputationFailed as c_int,
        };
        let mut scalars = match reserved(num_pairs) {
            Ok(values) => values,
            Err(_) => return Bls12381Result::ComputationFailed as c_int,
        };

        for i in 0..num_pairs {
            let offset = i * 288;
            let x_c0_bytes = &input_slice[offset + 0..offset + 64];
            let x_c1_bytes = &input_slice[offset + 64..offset + 128];
            let y_c0_bytes = &input_slice[offset + 128..offset + 192];
            let y_c1_bytes = &input_slice[offset + 192..offset + 256];
            let scalar_bytes = &input_slice[offset + 256..offset + 288];

            let x_c0 = field!(x_c0_bytes, Bls12381Result);
            let x_c1 = field!(x_c1_bytes, Bls12381Result);
            let y_c0 = field!(y_c0_bytes, Bls12381Result);
            let y_c1 = field!(y_c1_bytes, Bls12381Result);
            let x_coord = Fq2::new(x_c0, x_c1);
            let y_coord = Fq2::new(y_c0, y_c1);
            let scalar = field_from_be::<Fr>(scalar_bytes);

            // Skip point at infinity
            if x_coord.is_zero() && y_coord.is_zero() {
                continue;
            }

            let point = match BlsG2Affine::new_unchecked(x_coord, y_coord) {
                p if p.is_on_curve() && p.is_in_correct_subgroup_assuming_on_curve() => p,
                _ => return Bls12381Result::InvalidPoint as c_int,
            };

            points.push(point);
            scalars.push(scalar);
        }

        // Perform multi-scalar multiplication
        let result = if points.is_empty() {
            BlsG2Affine::zero()
        } else {
            match G2Projective::msm(&points, &scalars) {
                Ok(result) => result.into_affine(),
                Err(_) => return Bls12381Result::ComputationFailed as c_int,
            }
        };

        // Handle point at infinity
        if result.is_zero() {
            output_slice[..256].fill(0);
            return Bls12381Result::Success as c_int;
        }

        // Convert result to bytes
        let x_result = result.x;
        let y_result = result.y;

        let x_c0_bytes = field_bytes::<48>(x_result.c0.into_bigint());
        let x_c1_bytes = field_bytes::<48>(x_result.c1.into_bigint());
        let y_c0_bytes = field_bytes::<48>(y_result.c0.into_bigint());
        let y_c1_bytes = field_bytes::<48>(y_result.c1.into_bigint());

        // Pad and copy to output
        output_slice[..256].fill(0);
        output_slice[64 - x_c0_bytes.len()..64].copy_from_slice(&x_c0_bytes);
        output_slice[128 - x_c1_bytes.len()..128].copy_from_slice(&x_c1_bytes);
        output_slice[192 - y_c0_bytes.len()..192].copy_from_slice(&y_c0_bytes);
        output_slice[256 - y_c1_bytes.len()..256].copy_from_slice(&y_c1_bytes);

        Bls12381Result::Success as c_int
    })) {
        Ok(result) => result,
        Err(payload) => {
            // A user panic payload can itself panic on Drop. Retain it rather
            // than risk a second unwind crossing the C boundary.
            std::mem::forget(payload);
            Bls12381Result::ComputationFailed as c_int
        }
    }
}

/// Get the expected output size for BLS12-381 G2 operations
#[no_mangle]
pub extern "C" fn bls12_381_g2_output_size() -> c_uint {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });

        256
    })) {
        Ok(result) => result,
        Err(payload) => {
            // A user panic payload can itself panic on Drop. Retain it rather
            // than risk a second unwind crossing the C boundary.
            std::mem::forget(payload);
            0
        }
    }
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

#[cfg(test)]
mod security_regressions {
    use super::*;
    use ark_ff::Field;

    #[test]
    fn bn254_rejects_noncanonical_and_off_curve_and_accepts_infinity() {
        let mut input = [0u8; 96];
        let mut output = [0xa5u8; 64];
        input[95] = 1;
        unsafe {
            assert_eq!(bn254_ecmul(input.as_ptr(), 96, output.as_mut_ptr(), 64), 0);
        }
        assert_eq!(output, [0; 64]);
        input[31] = 1;
        input[63] = 3;
        unsafe {
            assert_eq!(bn254_ecmul(input.as_ptr(), 96, output.as_mut_ptr(), 64), 2);
        }
        input[..32].copy_from_slice(&ark_bn254::Fq::MODULUS.to_bytes_be());
        input[63] = 2;
        unsafe {
            assert_eq!(bn254_ecmul(input.as_ptr(), 96, output.as_mut_ptr(), 64), 2);
        }
        input[..32].fill(0);
        input[31] = 1;
        unsafe {
            assert_eq!(bn254_ecmul(input.as_ptr(), 96, output.as_mut_ptr(), 64), 0);
        }
        assert_eq!(output, input[..64]);
    }

    #[test]
    fn bn254_pairing_validates_even_with_infinity_partner() {
        let mut input = [0u8; 192];
        let mut output = [0u8; 32];
        unsafe {
            assert_eq!(
                bn254_ecpairing(input.as_ptr(), 192, output.as_mut_ptr(), 32),
                0
            );
        }
        assert_eq!(output[31], 1);
        for slot in 0..6 {
            input.fill(0);
            input[slot * 32..(slot + 1) * 32]
                .copy_from_slice(&ark_bn254::Fq::MODULUS.to_bytes_be());
            unsafe {
                assert_eq!(
                    bn254_ecpairing(input.as_ptr(), 192, output.as_mut_ptr(), 32),
                    2
                );
            }
        }
        input.fill(0);
        input[31] = 1;
        input[63] = 3;
        unsafe {
            assert_eq!(
                bn254_ecpairing(input.as_ptr(), 192, output.as_mut_ptr(), 32),
                2
            );
        }
        // Deterministically find an on-curve twist point outside the prime subgroup.
        let mut point = None;
        for n in 0..1024u64 {
            let x = ark_bn254::Fq2::new(n.into(), 1u64.into());
            let rhs = x.square() * x
                + <ark_bn254::g2::Config as ark_ec::short_weierstrass::SWCurveConfig>::COEFF_B;
            if let Some(y) = rhs.sqrt() {
                let candidate = G2Affine::new_unchecked(x, y);
                if !candidate.is_in_correct_subgroup_assuming_on_curve() {
                    point = Some(candidate);
                    break;
                }
            }
        }
        let point = point.expect("bounded deterministic subgroup fixture");
        assert!(point.is_on_curve());
        input.fill(0);
        for (slot, value) in [point.x.c1, point.x.c0, point.y.c1, point.y.c0]
            .iter()
            .enumerate()
        {
            input[64 + slot * 32..96 + slot * 32]
                .copy_from_slice(&value.into_bigint().to_bytes_be());
        }
        unsafe {
            assert_eq!(
                bn254_ecpairing(input.as_ptr(), 192, output.as_mut_ptr(), 32),
                2
            );
        }
        // EIP-197 uses imaginary component first; generator is a valid pairing input.
        let point = G2Affine::generator();
        for (slot, value) in [point.x.c1, point.x.c0, point.y.c1, point.y.c0]
            .iter()
            .enumerate()
        {
            input[64 + slot * 32..96 + slot * 32]
                .copy_from_slice(&value.into_bigint().to_bytes_be());
        }
        unsafe {
            assert_eq!(
                bn254_ecpairing(input.as_ptr(), 192, output.as_mut_ptr(), 32),
                0
            );
        }
        assert_eq!(output[31], 1);
    }

    #[test]
    fn bls_g1_padded_encoding_and_error_paths() {
        let mut input = [0u8; 256];
        let mut output = [0xa5u8; 128];
        let point = BlsG1Affine::generator();
        input[16..64].copy_from_slice(&point.x.into_bigint().to_bytes_be());
        input[80..128].copy_from_slice(&point.y.into_bigint().to_bytes_be());
        unsafe {
            assert_eq!(
                bls12_381_g1_add(input.as_ptr(), 256, output.as_mut_ptr(), 128),
                0
            );
        }
        assert_eq!(output, input[..128]);
        for slot in 0..4 {
            let mut invalid = input;
            invalid[slot * 64] = 1;
            unsafe {
                assert_eq!(
                    bls12_381_g1_add(invalid.as_ptr(), 256, output.as_mut_ptr(), 128),
                    2
                );
            }
        }
        input[..64].fill(0);
        input[16..64].copy_from_slice(&ark_bls12_381::Fq::MODULUS.to_bytes_be());
        unsafe {
            assert_eq!(
                bls12_381_g1_add(input.as_ptr(), 256, output.as_mut_ptr(), 128),
                2
            );
        }
        input.fill(0);
        input[63] = 1;
        input[127] = 1;
        unsafe {
            assert_eq!(
                bls12_381_g1_add(input.as_ptr(), 256, output.as_mut_ptr(), 128),
                2
            );
        }
    }
}

#[cfg(test)]
mod bls_security_regressions {
    use super::*;

    #[test]
    fn g1_msm_rejects_wrong_subgroup_and_invalid_coordinates_even_with_zero_scalar() {
        let mut input = [0u8; 160];
        let mut output = [0u8; 128];
        // (0, 2) is on y^2 = x^3 + 4, but outside the prime-order subgroup.
        input[127] = 2;
        let point = BlsG1Affine::new_unchecked(0u64.into(), 2u64.into());
        assert!(point.is_on_curve());
        assert!(!point.is_in_correct_subgroup_assuming_on_curve());
        unsafe {
            assert_eq!(
                bls12_381_g1_multiexp(input.as_ptr(), 160, output.as_mut_ptr(), 128),
                2
            );
        }
        let mut add = [0u8; 256];
        add[..128].copy_from_slice(&input[..128]);
        unsafe {
            assert_eq!(
                bls12_381_g1_add(add.as_ptr(), 256, output.as_mut_ptr(), 128),
                0
            );
        }
        assert_eq!(output, input[..128]);
        input[63] = 1;
        input[127] = 1;
        unsafe {
            assert_eq!(
                bls12_381_g1_multiexp(input.as_ptr(), 160, output.as_mut_ptr(), 128),
                2
            );
        }
        input.fill(0);
        input[16..64].copy_from_slice(&ark_bls12_381::Fq::MODULUS.to_bytes_be());
        unsafe {
            assert_eq!(
                bls12_381_g1_multiexp(input.as_ptr(), 160, output.as_mut_ptr(), 128),
                2
            );
        }
    }
}

#[cfg(test)]
mod g2_security_regressions {
    use super::*;
    use ark_ff::Field;

    #[test]
    fn g2_padded_add_mul_msm_and_pairing() {
        let point = BlsG2Affine::generator();
        let mut input = [0u8; 512];
        for (slot, value) in [point.x.c0, point.x.c1, point.y.c0, point.y.c1]
            .iter()
            .enumerate()
        {
            input[16 + slot * 64..64 + slot * 64]
                .copy_from_slice(&value.into_bigint().to_bytes_be());
        }
        let mut output = [0xa5u8; 256];
        unsafe {
            assert_eq!(
                bls12_381_g2_add(input.as_ptr(), 512, output.as_mut_ptr(), 256),
                0
            );
        }
        assert_eq!(output, input[..256]);
        input[287] = 1;
        unsafe {
            assert_eq!(
                bls12_381_g2_mul(input.as_ptr(), 288, output.as_mut_ptr(), 256),
                0
            );
            assert_eq!(
                bls12_381_g2_multiexp(input.as_ptr(), 288, output.as_mut_ptr(), 256),
                0
            );
        }
        assert_eq!(output, input[..256]);
        for slot in 0..4 {
            let mut invalid = input;
            invalid[slot * 64] = 1;
            unsafe {
                assert_eq!(
                    bls12_381_g2_multiexp(invalid.as_ptr(), 288, output.as_mut_ptr(), 256),
                    2
                );
            }
        }
        // Validate a non-subgroup G2 even when its G1 pairing partner is infinity.
        let mut candidate = None;
        for n in 0..1024u64 {
            let x = ark_bls12_381::Fq2::new(n.into(), 1u64.into());
            let rhs = x.square() * x
                + <ark_bls12_381::g2::Config as ark_ec::short_weierstrass::SWCurveConfig>::COEFF_B;
            if let Some(y) = rhs.sqrt() {
                let point = BlsG2Affine::new_unchecked(x, y);
                if !point.is_in_correct_subgroup_assuming_on_curve() {
                    candidate = Some(point);
                    break;
                }
            }
        }
        let point = candidate.expect("bounded deterministic subgroup fixture");
        assert!(point.is_on_curve());
        let mut pair = [0u8; 384];
        for (slot, value) in [point.x.c0, point.x.c1, point.y.c0, point.y.c1]
            .iter()
            .enumerate()
        {
            pair[144 + slot * 64..192 + slot * 64]
                .copy_from_slice(&value.into_bigint().to_bytes_be());
        }
        let mut result = [0u8; 32];
        unsafe {
            assert_eq!(
                bls12_381_pairing(pair.as_ptr(), 384, result.as_mut_ptr(), 32),
                2
            );
        }
        let mut msm = [0u8; 288];
        msm[..256].copy_from_slice(&pair[128..]);
        unsafe {
            assert_eq!(
                bls12_381_g2_multiexp(msm.as_ptr(), 288, output.as_mut_ptr(), 256),
                2
            );
        }
    }
}

#[cfg(test)]
std::thread_local! { static INJECT_PANIC: std::cell::Cell<bool> = const { std::cell::Cell::new(false) }; }

#[cfg(test)]
#[test]
fn every_export_contains_panics() {
    INJECT_PANIC.with(|flag| flag.set(true));
    assert_eq!(bn254_init() as usize, 4);
    INJECT_PANIC.with(|flag| flag.set(true));
    assert_eq!(
        unsafe { bn254_ecmul(std::ptr::null(), 0, std::ptr::null_mut(), 0) } as usize,
        4
    );
    INJECT_PANIC.with(|flag| flag.set(true));
    assert_eq!(
        unsafe { bn254_ecpairing(std::ptr::null(), 0, std::ptr::null_mut(), 0) } as usize,
        4
    );
    INJECT_PANIC.with(|flag| flag.set(true));
    assert_eq!(bn254_ecmul_output_size() as usize, 0);
    INJECT_PANIC.with(|flag| flag.set(true));
    assert_eq!(bn254_ecpairing_output_size() as usize, 0);
    INJECT_PANIC.with(|flag| flag.set(true));
    assert_eq!(bn254_ecmul_validate_input(std::ptr::null(), 0) as usize, 4);
    INJECT_PANIC.with(|flag| flag.set(true));
    assert_eq!(
        bn254_ecpairing_validate_input(std::ptr::null(), 0) as usize,
        4
    );
    INJECT_PANIC.with(|flag| flag.set(true));
    assert_eq!(
        unsafe { bls12_381_g1_add(std::ptr::null(), 0, std::ptr::null_mut(), 0) } as usize,
        4
    );
    INJECT_PANIC.with(|flag| flag.set(true));
    assert_eq!(
        unsafe { bls12_381_g1_mul(std::ptr::null(), 0, std::ptr::null_mut(), 0) } as usize,
        4
    );
    INJECT_PANIC.with(|flag| flag.set(true));
    assert_eq!(
        unsafe { bls12_381_g1_multiexp(std::ptr::null(), 0, std::ptr::null_mut(), 0) } as usize,
        4
    );
    INJECT_PANIC.with(|flag| flag.set(true));
    assert_eq!(
        unsafe { bls12_381_pairing(std::ptr::null(), 0, std::ptr::null_mut(), 0) } as usize,
        4
    );
    INJECT_PANIC.with(|flag| flag.set(true));
    assert_eq!(bls12_381_g1_output_size() as usize, 0);
    INJECT_PANIC.with(|flag| flag.set(true));
    assert_eq!(bls12_381_pairing_output_size() as usize, 0);
    INJECT_PANIC.with(|flag| flag.set(true));
    assert_eq!(
        unsafe { bls12_381_g2_add(std::ptr::null(), 0, std::ptr::null_mut(), 0) } as usize,
        4
    );
    INJECT_PANIC.with(|flag| flag.set(true));
    assert_eq!(
        unsafe { bls12_381_g2_mul(std::ptr::null(), 0, std::ptr::null_mut(), 0) } as usize,
        4
    );
    INJECT_PANIC.with(|flag| flag.set(true));
    assert_eq!(
        unsafe { bls12_381_g2_multiexp(std::ptr::null(), 0, std::ptr::null_mut(), 0) } as usize,
        4
    );
    INJECT_PANIC.with(|flag| flag.set(true));
    assert_eq!(bls12_381_g2_output_size() as usize, 0);
}

#[test]
fn fallible_reservation_rejects_capacity_overflow() {
    assert!(reserved::<u8>(usize::MAX).is_err());
    assert!(reserved::<G1Affine>(usize::MAX).is_err());
    assert!(reserved::<BlsG2Affine>(usize::MAX).is_err());
    assert!(reserved::<u8>(0).unwrap().is_empty());
}
