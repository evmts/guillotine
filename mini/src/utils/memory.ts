/**
 * Memory expansion utilities for EVM
 *
 * Implements EVM memory expansion with quadratic cost formula:
 * memory_cost = 3 * word_size + (word_size ** 2) / 512
 *
 * Where:
 * - word_size is the number of 32-byte words
 * - Costs are only charged for expansion beyond current size
 * - All sizes are word-aligned (multiples of 32 bytes)
 */

/** Memory gas cost per word (linear term) */
const MEMORY_GAS = 3;

/** Quadratic divisor for memory cost formula */
const QUAD_COEFF_DIV = 512;

/** Word size in bytes (EVM uses 32-byte words) */
const WORD_SIZE = 32;

/** Maximum reasonable memory size (16MB to prevent overflow) */
const MAX_MEMORY = 0x1000000;

/**
 * Calculate word count from byte size (rounds up to next word)
 * @param bytes Number of bytes
 * @returns Number of 32-byte words needed
 */
export function wordCount(bytes: number): number {
  return Math.ceil(bytes / WORD_SIZE);
}

/**
 * Calculate word-aligned size (round up to 32-byte boundary)
 * @param bytes Number of bytes
 * @returns Word-aligned size in bytes
 */
export function wordAlignedSize(bytes: number): number {
  const words = wordCount(bytes);
  return words * WORD_SIZE;
}

/**
 * Calculate total memory gas cost for a given word size
 * Formula: 3 * words + (words ** 2) / 512
 * @param wordSize Number of 32-byte words
 * @returns Total gas cost
 */
export function memoryGasCost(wordSize: number): number {
  const linear = MEMORY_GAS * wordSize;
  const quadratic = Math.floor((wordSize * wordSize) / QUAD_COEFF_DIV);
  return linear + quadratic;
}

/**
 * Calculate gas cost for expanding memory from current size to new size
 * Only charges for the expansion (difference between new and current costs)
 * @param currentSize Current memory size in bytes
 * @param newSize New memory size in bytes
 * @returns Gas cost for expansion (0 if no expansion needed)
 */
export function calculateMemoryExpansionCost(
  currentSize: number,
  newSize: number
): number {
  // No expansion needed
  if (newSize <= currentSize) {
    return 0;
  }

  // Cap memory size to prevent overflow
  if (newSize > MAX_MEMORY) {
    return Number.MAX_SAFE_INTEGER;
  }

  const currentWords = wordCount(currentSize);
  const newWords = wordCount(newSize);

  // Check for overflow in word * word calculation
  if (newWords * newWords > Number.MAX_SAFE_INTEGER) {
    return Number.MAX_SAFE_INTEGER;
  }

  const currentCost = memoryGasCost(currentWords);
  const newCost = memoryGasCost(newWords);

  return newCost - currentCost;
}

/**
 * Expand memory to accommodate the specified size
 * @param memory Current memory buffer
 * @param targetSize Target size in bytes
 * @returns New memory buffer (word-aligned)
 */
export function expandMemory(
  memory: Uint8Array,
  targetSize: number
): Uint8Array {
  const alignedSize = wordAlignedSize(targetSize);

  // Already large enough
  if (memory.length >= alignedSize) {
    return memory;
  }

  // Create new buffer and copy existing data
  const newMemory = new Uint8Array(alignedSize);
  newMemory.set(memory);
  return newMemory;
}

/**
 * Read bytes from memory with bounds checking
 * Returns zeros for out-of-bounds reads (EVM behavior)
 * @param memory Memory buffer
 * @param offset Starting offset
 * @param length Number of bytes to read
 * @returns Byte slice (zeros if out of bounds)
 */
export function readMemory(
  memory: Uint8Array,
  offset: number,
  length: number
): Uint8Array {
  // Zero-length read
  if (length === 0) {
    return new Uint8Array(0);
  }

  // Overflow check
  if (offset + length > Number.MAX_SAFE_INTEGER) {
    throw new Error("Memory offset overflow");
  }

  const result = new Uint8Array(length);

  // Read bytes, returning zeros for out-of-bounds
  for (let i = 0; i < length; i++) {
    const idx = offset + i;
    result[i] = idx < memory.length ? memory[idx] : 0;
  }

  return result;
}

/**
 * Write bytes to memory with automatic expansion
 * @param memory Current memory buffer
 * @param offset Starting offset
 * @param data Data to write
 * @returns New memory buffer (expanded if necessary)
 */
export function writeMemory(
  memory: Uint8Array,
  offset: number,
  data: Uint8Array
): Uint8Array {
  // Zero-length write
  if (data.length === 0) {
    return memory;
  }

  // Overflow check
  if (offset + data.length > Number.MAX_SAFE_INTEGER) {
    throw new Error("Memory offset overflow");
  }

  const endOffset = offset + data.length;
  const newMemory = expandMemory(memory, endOffset);

  // Write data
  newMemory.set(data, offset);

  return newMemory;
}

/**
 * Copy memory within the same buffer (MCOPY opcode)
 * Handles overlapping regions correctly
 * @param memory Current memory buffer
 * @param destOffset Destination offset
 * @param srcOffset Source offset
 * @param length Number of bytes to copy
 * @returns New memory buffer (expanded if necessary)
 */
export function copyMemory(
  memory: Uint8Array,
  destOffset: number,
  srcOffset: number,
  length: number
): Uint8Array {
  // Zero-length copy
  if (length === 0) {
    return memory;
  }

  // Overflow checks
  if (destOffset + length > Number.MAX_SAFE_INTEGER) {
    throw new Error("Memory destination overflow");
  }
  if (srcOffset + length > Number.MAX_SAFE_INTEGER) {
    throw new Error("Memory source overflow");
  }

  // Expand memory to accommodate destination
  const destEndOffset = destOffset + length;
  const newMemory = expandMemory(memory, destEndOffset);

  // Read source data (may be out of bounds, returns zeros)
  const srcData = readMemory(newMemory, srcOffset, length);

  // Write to destination
  newMemory.set(srcData, destOffset);

  return newMemory;
}
