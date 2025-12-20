/**
 * Keccak-256 Assembly-Optimized Wrapper - C Header
 *
 * High-performance Keccak-256 implementation using assembly optimizations
 * Designed for integration with Zig code for Ethereum hashing
 */

#ifndef KECCAK_WRAPPER_H
#define KECCAK_WRAPPER_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Result codes for Keccak operations
 */
typedef enum {
    KECCAK_SUCCESS = 0,
    KECCAK_INVALID_INPUT = 1,
    KECCAK_INVALID_OUTPUT_SIZE = 2,
} KeccakResult;

/**
 * Compute Keccak-256 hash
 *
 * @param input Input data pointer
 * @param input_len Length of input data in bytes
 * @param output Output buffer pointer (must be at least 32 bytes)
 * @param output_len Length of output buffer (must be at least 32)
 * @return KECCAK_SUCCESS on success, error code otherwise
 */
KeccakResult keccak256(
    const unsigned char* input,
    unsigned long input_len,
    unsigned char* output,
    unsigned long output_len
);

/**
 * Batch compute Keccak-256 for multiple inputs
 *
 * @param inputs Array of input data pointers
 * @param input_lens Array of input lengths
 * @param outputs Array of output buffer pointers (each must be at least 32 bytes)
 * @param count Number of inputs to process
 * @return KECCAK_SUCCESS on success, error code otherwise
 */
KeccakResult keccak256_batch(
    const unsigned char** inputs,
    const unsigned long* input_lens,
    unsigned char** outputs,
    unsigned long count
);

/**
 * Get the output size for Keccak-256
 * @return 32 bytes
 */
unsigned long keccak256_output_size(void);

#ifdef __cplusplus
}
#endif

#endif /* KECCAK_WRAPPER_H */
