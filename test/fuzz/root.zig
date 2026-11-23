//! Guillotine EVM Comprehensive Fuzz Testing Suite
//!
//! Aggregates all Zig `std.testing.fuzz` targets across every EVM subsystem:
//! - Bytecode analysis, JUMPDEST reference oracle, fusion invariants, Dispatch schedule, OOM
//! - Stateful Stack model checker (1024-slot, 32-slot overflow stress, borrowed)
//! - Stateful Memory & quadratic gas expansion model checker + nested child checkpoints
//! - Stateful Database, Journal O(1) index, nested snapshots, ephemeral views, AccessList
//! - 256-bit arithmetic, signed div/mod, 512-bit addmod/mulmod, exp, shifts vs BigInt oracle
//! - Multi-oracle differential EVM execution (fusion ON vs OFF vs simulate() across hardforks)
//! - All 19 Ethereum precompiles (0x01..0x13) + BigInt ModExp & BN254 group axioms
//! - Merkle Patricia Trie stateful model + cryptographic root order-independence
//! - EIP-4844 blob gas, EIP-1559, EIP-3529, EIP-2200/2929, EIP-7623, EIP-7702
//! - C ABI / FFI boundary (`libguillotine_ffi`)
//!
//! Usage:
//! - macOS / Linux corpus + regression check: `zig build test-fuzz`
//! - Linux / Ubuntu coverage-guided fuzzing:  `zig build test-fuzz --fuzz`
//! - Cross-platform multi-threaded campaign:  `zig build fuzz-campaign`

const std = @import("std");

pub const std_options: std.Options = .{
    .log_level = .err,
};

pub const bytecode_fuzz = @import("bytecode_fuzz.zig");
pub const stack_fuzz = @import("stack_fuzz.zig");
pub const memory_fuzz = @import("memory_fuzz.zig");
pub const storage_journal_fuzz = @import("storage_journal_fuzz.zig");
pub const arithmetic_u256_fuzz = @import("arithmetic_u256_fuzz.zig");
pub const differential_evm_fuzz = @import("differential_evm_fuzz.zig");
pub const precompiles_fuzz = @import("precompiles_fuzz.zig");
pub const trie_fuzz = @import("trie_fuzz.zig");
pub const eip_hardfork_fuzz = @import("eip_hardfork_fuzz.zig");
pub const c_api_fuzz = @import("c_api_fuzz.zig");

test {
    _ = bytecode_fuzz;
    _ = stack_fuzz;
    _ = memory_fuzz;
    _ = storage_journal_fuzz;
    _ = arithmetic_u256_fuzz;
    _ = differential_evm_fuzz;
    _ = precompiles_fuzz;
    _ = trie_fuzz;
    _ = eip_hardfork_fuzz;
    _ = c_api_fuzz;
}
