//! Protocol limits and implementation safeguards used by the EVM.
const std = @import("std");

/// Maximum operand stack height in words (Yellow Paper, exceptional halting).
pub const stack_capacity = 1024;

/// Maximum message-call and contract-creation depth (Yellow Paper).
pub const max_call_depth = 1024;

/// EIP-170 maximum deployed contract size in bytes.
pub const max_code_size = 24_576;

/// EIP-3860 allows twice the deployed code size for initcode.
pub const max_initcode_size = 2 * max_code_size;

/// Largest memory range end representable by Guillotine's u24 addressing limit.
pub const max_memory_size = std.math.maxInt(u24);

/// Instruction count at which Guillotine's execution safety counter trips.
pub const max_instructions = 300_000_000;
