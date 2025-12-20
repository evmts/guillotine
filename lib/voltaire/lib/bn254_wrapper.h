/**
 * BN254 and BLS12-381 Wrapper Library - C Header
 * 
 * C-compatible API for BN254 and BLS12-381 elliptic curve operations
 * Designed for integration with Zig code for Ethereum precompiles
 */

#ifndef BN254_WRAPPER_H
#define BN254_WRAPPER_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Result codes for BN254 operations
 */
typedef enum {
    BN254_SUCCESS = 0,
    BN254_INVALID_INPUT = 1,
    BN254_INVALID_POINT = 2,
    BN254_INVALID_SCALAR = 3,
    BN254_COMPUTATION_FAILED = 4,
} Bn254Result;

/**
 * Initialize the BN254 library
 * This function can be called multiple times safely
 * 
 * @return BN254_SUCCESS on success
 */
int bn254_init(void);

/**
 * Perform elliptic curve scalar multiplication (ECMUL)
 * 
 * Input format (96 bytes):
 * - Bytes 0-31: x coordinate (big-endian)
 * - Bytes 32-63: y coordinate (big-endian)  
 * - Bytes 64-95: scalar (big-endian)
 *
 * Output format (64 bytes):
 * - Bytes 0-31: result x coordinate (big-endian)
 * - Bytes 32-63: result y coordinate (big-endian)
 *
 * @param input Input data pointer
 * @param input_len Length of input data (must be >= 96)
 * @param output Output buffer pointer
 * @param output_len Length of output buffer (must be >= 64)
 * @return BN254_SUCCESS on success, error code otherwise
 */
int bn254_ecmul(
    const unsigned char* input,
    unsigned int input_len,
    unsigned char* output,
    unsigned int output_len
);

/**
 * Perform elliptic curve pairing check (ECPAIRING)
 * 
 * Input format (multiple of 192 bytes):
 * Each 192-byte group contains:
 * - Bytes 0-63: G1 point (x, y coordinates, 32 bytes each)
 * - Bytes 64-191: G2 point (x and y in Fp2, 64 bytes each)
 *
 * Output format (32 bytes):
 * - 32-byte boolean result (0x00...00 for false, 0x00...01 for true)
 *
 * @param input Input data pointer
 * @param input_len Length of input data (must be multiple of 192)
 * @param output Output buffer pointer  
 * @param output_len Length of output buffer (must be >= 32)
 * @return BN254_SUCCESS on success, error code otherwise
 */
int bn254_ecpairing(
    const unsigned char* input,
    unsigned int input_len,
    unsigned char* output,
    unsigned int output_len
);

/**
 * Get the expected output size for ECMUL
 * @return 64 bytes
 */
unsigned int bn254_ecmul_output_size(void);

/**
 * Get the expected output size for ECPAIRING  
 * @return 32 bytes
 */
unsigned int bn254_ecpairing_output_size(void);

/**
 * Validate ECMUL input format
 * @param input Input data pointer
 * @param input_len Length of input data
 * @return BN254_SUCCESS if valid, error code otherwise
 */
int bn254_ecmul_validate_input(
    const unsigned char* input,
    unsigned int input_len
);

/**
 * Validate ECPAIRING input format
 * @param input Input data pointer
 * @param input_len Length of input data
 * @return BN254_SUCCESS if valid, error code otherwise
 */
int bn254_ecpairing_validate_input(
    const unsigned char* input,
    unsigned int input_len
);

/**
 * Result codes for BLS12-381 operations
 */
typedef enum {
    BLS12_381_SUCCESS = 0,
    BLS12_381_INVALID_INPUT = 1,
    BLS12_381_INVALID_POINT = 2,
    BLS12_381_INVALID_SCALAR = 3,
    BLS12_381_COMPUTATION_FAILED = 4,
} Bls12381Result;

/**
 * Perform BLS12-381 G1 addition
 * 
 * Input format (256 bytes):
 * - Bytes 0-47: first point x coordinate (big-endian)
 * - Bytes 48-95: first point y coordinate (big-endian)
 * - Bytes 128-175: second point x coordinate (big-endian)
 * - Bytes 176-223: second point y coordinate (big-endian)
 *
 * Output format (128 bytes):
 * - Bytes 0-47: result x coordinate (big-endian)
 * - Bytes 48-95: result y coordinate (big-endian)
 *
 * @param input Input data pointer
 * @param input_len Length of input data (must be >= 256)
 * @param output Output buffer pointer
 * @param output_len Length of output buffer (must be >= 128)
 * @return BLS12_381_SUCCESS on success, error code otherwise
 */
int bls12_381_g1_add(
    const unsigned char* input,
    unsigned int input_len,
    unsigned char* output,
    unsigned int output_len
);

/**
 * Perform BLS12-381 G1 scalar multiplication
 * 
 * Input format (160 bytes):
 * - Bytes 0-47: x coordinate (big-endian)
 * - Bytes 48-95: y coordinate (big-endian)
 * - Bytes 128-159: scalar (big-endian)
 *
 * Output format (128 bytes):
 * - Bytes 0-47: result x coordinate (big-endian)
 * - Bytes 48-95: result y coordinate (big-endian)
 *
 * @param input Input data pointer
 * @param input_len Length of input data (must be >= 160)
 * @param output Output buffer pointer
 * @param output_len Length of output buffer (must be >= 128)
 * @return BLS12_381_SUCCESS on success, error code otherwise
 */
int bls12_381_g1_mul(
    const unsigned char* input,
    unsigned int input_len,
    unsigned char* output,
    unsigned int output_len
);

/**
 * Perform BLS12-381 G1 multi-scalar multiplication
 * 
 * Input format (variable, 160 * k bytes for k points):
 * Each 160-byte group contains:
 * - Bytes 0-47: x coordinate (big-endian)
 * - Bytes 48-95: y coordinate (big-endian)
 * - Bytes 128-159: scalar (big-endian)
 *
 * Output format (128 bytes):
 * - Bytes 0-47: result x coordinate (big-endian)
 * - Bytes 48-95: result y coordinate (big-endian)
 *
 * @param input Input data pointer
 * @param input_len Length of input data (must be multiple of 160)
 * @param output Output buffer pointer
 * @param output_len Length of output buffer (must be >= 128)
 * @return BLS12_381_SUCCESS on success, error code otherwise
 */
int bls12_381_g1_multiexp(
    const unsigned char* input,
    unsigned int input_len,
    unsigned char* output,
    unsigned int output_len
);

/**
 * Perform BLS12-381 pairing check
 * 
 * Input format (variable, 384 * k bytes for k pairs):
 * Each 384-byte group contains:
 * - Bytes 0-127: G1 point (x, y coordinates, 48 bytes each + padding)
 * - Bytes 128-383: G2 point (x and y in Fp2, 96 bytes each + padding)
 *
 * Output format (32 bytes):
 * - 32-byte boolean result (0x00...00 for false, 0x00...01 for true)
 *
 * @param input Input data pointer
 * @param input_len Length of input data (must be multiple of 384)
 * @param output Output buffer pointer  
 * @param output_len Length of output buffer (must be >= 32)
 * @return BLS12_381_SUCCESS on success, error code otherwise
 */
int bls12_381_pairing(
    const unsigned char* input,
    unsigned int input_len,
    unsigned char* output,
    unsigned int output_len
);

/**
 * Get the expected output size for BLS12-381 G1 operations
 * @return 128 bytes
 */
unsigned int bls12_381_g1_output_size(void);

/**
 * Get the expected output size for BLS12-381 pairing
 * @return 32 bytes
 */
unsigned int bls12_381_pairing_output_size(void);

#ifdef __cplusplus
}
#endif

#endif /* BN254_WRAPPER_H */