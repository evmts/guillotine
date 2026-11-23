#![no_main]

use libfuzzer_sys::fuzz_target;
use std::os::raw::c_uint;

fuzz_target!(|data: &[u8]| {
    if data.is_empty() {
        return;
    }

    let selector = data[0] % 6;
    let payload = &data[1..];
    let len = payload.len() as c_uint;
    let ptr = if payload.is_empty() {
        std::ptr::null()
    } else {
        payload.as_ptr()
    };

    let mut out64 = [0u8; 64];
    let mut out32 = [0u8; 32];
    let mut out128 = [0u8; 128];

    unsafe {
        match selector {
            0 => {
                let _ = bn254_wrapper::bn254_ecmul(ptr, len, out64.as_mut_ptr(), 64);
            }
            1 => {
                let _ = bn254_wrapper::bn254_ecpairing(ptr, len, out32.as_mut_ptr(), 32);
            }
            2 => {
                let _ = bn254_wrapper::bls12_381_g1_add(ptr, len, out128.as_mut_ptr(), 128);
            }
            3 => {
                let _ = bn254_wrapper::bls12_381_g1_mul(ptr, len, out128.as_mut_ptr(), 128);
            }
            4 => {
                let _ = bn254_wrapper::bls12_381_g1_multiexp(ptr, len, out128.as_mut_ptr(), 128);
            }
            _ => {
                let _ = bn254_wrapper::bls12_381_pairing(ptr, len, out32.as_mut_ptr(), 32);
            }
        }
    }
});
