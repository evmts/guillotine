//! BN254 and BLS12-381 FFI built as `libbn254_wrapper.a` for the root build and
//! fuzzed by `lib/ark/fuzz`. The implementation is shared with the Voltaire
//! crypto wrappers; edit `lib/voltaire/src/crypto/bn254_wrapper.rs`.
#[path = "../../voltaire/src/crypto/bn254_wrapper.rs"]
mod wrapper;
pub use wrapper::*;
