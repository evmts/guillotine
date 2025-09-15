/**
 * Common type for all Evm precompile functions
 * 
 * @param inputPtr - Pointer to input data in WASM memory
 * @param inputLen - Length of input data in bytes
 * @param outputPtr - Pointer to output buffer in WASM memory
 * @param outputLenPtr - Pointer to output length in WASM memory
 * @returns 0 for success, non-zero for error
 */
export type PrecompileFunction = (
  inputPtr: number,
  inputLen: number,
  outputPtr: number,
  outputLenPtr: number
) => number;

/**
 * Result codes for precompile functions
 */
export const PrecompileResult = {
  SUCCESS: 0,
  ERROR: 1,
  NOT_IMPLEMENTED: 2,
} as const;

export type PrecompileResultType = typeof PrecompileResult[keyof typeof PrecompileResult];