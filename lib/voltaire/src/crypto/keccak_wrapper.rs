// Use assembly-optimized version for native targets, portable for WASM
#[cfg(feature = "asm")]
use keccak_asm::{Digest, Keccak256};

#[cfg(feature = "portable")]
use tiny_keccak::{Hasher, Keccak};

/// Result codes for Keccak operations
#[repr(C)]
pub enum KeccakResult {
    Success = 0,
    InvalidInput = 1,
    InvalidOutputSize = 2,
}

/// Compute Keccak-256 hash of input data
///
/// # Safety
///
/// This function is safe to call from C/Zig as long as:
/// - `input` points to valid memory of at least `input_len` bytes
/// - `output` points to valid memory of at least `output_len` bytes
/// - `output_len` is at least 32 bytes
#[no_mangle]
pub unsafe extern "C" fn keccak256(
    input: *const u8,
    input_len: usize,
    output: *mut u8,
    output_len: usize,
) -> KeccakResult {
    if input.is_null() || output.is_null() {
        return KeccakResult::InvalidInput;
    }

    if output_len < 32 {
        return KeccakResult::InvalidOutputSize;
    }

    let input_slice = std::slice::from_raw_parts(input, input_len);
    let output_slice = std::slice::from_raw_parts_mut(output, 32);

    #[cfg(feature = "asm")]
    {
        let mut hasher = Keccak256::new();
        hasher.update(input_slice);
        let result = hasher.finalize();
        output_slice.copy_from_slice(&result);
    }

    #[cfg(feature = "portable")]
    {
        let mut hasher = Keccak::v256();
        hasher.update(input_slice);
        hasher.finalize(output_slice);
    }

    KeccakResult::Success
}

/// Batch compute Keccak-256 for multiple inputs
///
/// # Safety
///
/// This function is safe to call from C/Zig as long as:
/// - `inputs` points to valid array of pointers
/// - `input_lens` points to valid array of lengths
/// - `outputs` points to valid array of output buffers
/// - All arrays have at least `count` elements
/// - Each input/output pointer is valid for its specified length
#[no_mangle]
pub unsafe extern "C" fn keccak256_batch(
    inputs: *const *const u8,
    input_lens: *const usize,
    outputs: *mut *mut u8,
    count: usize,
) -> KeccakResult {
    if inputs.is_null() || input_lens.is_null() || outputs.is_null() {
        return KeccakResult::InvalidInput;
    }

    let inputs_slice = std::slice::from_raw_parts(inputs, count);
    let lens_slice = std::slice::from_raw_parts(input_lens, count);
    let outputs_slice = std::slice::from_raw_parts_mut(outputs, count);

    for i in 0..count {
        if inputs_slice[i].is_null() || outputs_slice[i].is_null() {
            return KeccakResult::InvalidInput;
        }

        let input = std::slice::from_raw_parts(inputs_slice[i], lens_slice[i]);
        let output = std::slice::from_raw_parts_mut(outputs_slice[i], 32);

        #[cfg(feature = "asm")]
        {
            let mut hasher = Keccak256::new();
            hasher.update(input);
            let result = hasher.finalize();
            output.copy_from_slice(&result);
        }

        #[cfg(feature = "portable")]
        {
            let mut hasher = Keccak::v256();
            hasher.update(input);
            hasher.finalize(output);
        }
    }

    KeccakResult::Success
}

/// Get the output size for Keccak-256 (always 32 bytes)
#[no_mangle]
pub extern "C" fn keccak256_output_size() -> usize {
    32
}
