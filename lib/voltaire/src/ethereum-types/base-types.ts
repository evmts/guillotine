/**
 * Base Ethereum Types
 *
 * Common type aliases used across Ethereum specifications
 * Based on: https://github.com/ethereum/execution-apis
 */

/**
 * Byte - Single byte as hex string
 * Example: "0xff"
 */
export type Byte = `0x${string}`;

/**
 * Bytes - Variable-length byte array as hex string
 * Example: "0x1234abcd"
 */
export type Bytes = `0x${string}`;

/**
 * Bytes32 - 32-byte fixed-length data (topics, hashes)
 * Example: "0x0000000000000000000000000000000000000000000000000000000000000001"
 */
export type Bytes32 = `0x${string}`;

/**
 * Bytes256 - 256-byte fixed-length data (logs bloom)
 */
export type Bytes256 = `0x${string}`;

/**
 * Address - 20-byte Ethereum address
 * Example: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0"
 */
export type Address = `0x${string}`;

/**
 * Hash32 - 32-byte hash (transaction hash, block hash)
 */
export type Hash32 = `0x${string}`;

/**
 * Uint - Unsigned integer as hex string
 * Example: "0x64" (100 in decimal)
 */
export type Uint = `0x${string}`;

/**
 * Uint64 - 64-bit unsigned integer
 */
export type Uint64 = `0x${string}`;

/**
 * Uint256 - 256-bit unsigned integer
 */
export type Uint256 = `0x${string}`;

/**
 * Block identifier - can be a number, hash, or tag
 */
export type BlockTag = "latest" | "earliest" | "pending" | "safe" | "finalized";
export type BlockNumber = Uint;
export type BlockIdentifier = BlockNumber | BlockTag | Hash32;
