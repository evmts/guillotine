const std = @import("std");

/// Maximum size of EVM contract bytecode in bytes (24KB)
/// This is the limit enforced by EIP-170
pub const MAX_CONTRACT_SIZE = 24_576;

/// Maximum number of basic blocks in a contract
/// Most contracts have < 1000 blocks, but we allocate conservatively
/// for pathological cases with many small blocks
pub const MAX_BLOCKS = 4096;

/// Maximum number of instructions after translation
/// Conservative estimate: 2 instructions per bytecode byte worst case
pub const MAX_INSTRUCTIONS = MAX_CONTRACT_SIZE * 2;