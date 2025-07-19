const std = @import("std");
const Hardfork = @import("hardfork.zig").Hardfork;
const Log = @import("../log.zig");

/// Ethereum protocol rules and EIP activations for different hardforks.
/// Defaults to latest stable hardfork (Cancun). Use for_hardfork() for historical forks.
pub const ChainRules = @This();

/// Homestead (Mar 2016): DELEGATECALL opcode, difficulty adjustment
is_homestead: bool = true,

/// EIP-150 (Oct 2016): Gas repricing, 63/64 rule, DoS attack mitigation
is_eip150: bool = true,

/// EIP-158 (Nov 2016): Empty account deletion, state cleaning
/// - Replay attack protection via chain ID
///
/// ## State Impact
is_eip158: bool = true,

/// EIP-1559: Base fee burning, priority fees, BASEFEE opcode
is_eip1559: bool = true,

/// Constantinople (Feb 2019): Shift opcodes, EXTCODEHASH, CREATE2
is_constantinople: bool = true,

/// Petersburg (Feb 2019): Constantinople with EIP-1283 disabled
is_petersburg: bool = true,

/// Istanbul (Dec 2019): CHAINID, SELFBALANCE opcodes, gas repricing
is_istanbul: bool = true,

/// Berlin (Apr 2021): Gas repricing, access lists, cold/warm state access
is_berlin: bool = true,

/// London (Aug 2021): EIP-1559 fee market, BASEFEE opcode, 0xEF prefix rejection
is_london: bool = true,

/// The Merge (Sep 2022): PoW to PoS, DIFFICULTY→PREVRANDAO
is_merge: bool = true,

/// Shanghai (Apr 2023): PUSH0 opcode, validator withdrawals, initcode limits
is_shanghai: bool = true,

/// Cancun (Mar 2024): Proto-danksharding, transient storage, MCOPY
/// - EIP-6780: SELFDESTRUCT only in same transaction
/// - EIP-7516: BLOBBASEFEE opcode (0x4A)
///
/// ## Blob Transactions
/// New transaction type carrying data blobs (4096 field elements)
/// for L2 data availability at ~10x lower cost.
///
/// ## Transient Storage
/// Storage that persists only within a transaction, enabling
/// reentrancy locks and other patterns without permanent storage.
is_cancun: bool = true,

/// Prague hardfork activation flag (future upgrade).
///
/// ## Status
/// Not yet scheduled or fully specified. Expected to include:
/// - EOF (EVM Object Format) implementation
/// - Account abstraction improvements
/// - Further gas optimizations
///
/// ## Note
/// This flag is reserved for future use and should remain
/// false until Prague specifications are finalized.
is_prague: bool = false,

/// Verkle trees activation flag (future upgrade).
///
/// ## Purpose
/// Fundamental change to Ethereum's state storage using Verkle trees
/// instead of Merkle Patricia tries for massive witness size reduction.
///
/// ## Expected Benefits
/// - Witness sizes reduced from ~10MB to ~200KB
/// - Enables stateless clients
/// - Improved sync times and network efficiency
///
/// ## Status
/// Under active research and development. Will require extensive
/// testing before mainnet deployment.
is_verkle: bool = false,

/// Byzantium hardfork activation (October 2017).
///
/// ## Purpose
/// Major protocol upgrade adding privacy features and improving
/// smart contract capabilities.
///
/// ## Key Changes
/// - New opcodes: REVERT (0xFD), RETURNDATASIZE (0x3D), RETURNDATACOPY (0x3E)
/// - New opcode: STATICCALL (0xFA) for read-only calls
/// - Added precompiles for zkSNARK verification (alt_bn128)
/// - Difficulty bomb delay by 18 months
/// - Block reward reduced from 5 to 3 ETH
///
/// ## REVERT Impact
/// Allows contracts to revert with data, enabling better error
/// messages while still refunding remaining gas.
///
/// ## Privacy Features
/// zkSNARK precompiles enable privacy-preserving applications
/// like private transactions and scalability solutions.
is_byzantium: bool = true,

/// EIP-2930 optional access lists activation (Berlin hardfork).
///
/// ## Purpose
/// Introduces Type 1 transactions with optional access lists,
/// allowing senders to pre-declare state they'll access.
///
/// ## Benefits
/// - Mitigates breaking changes from EIP-2929 gas increases
/// - Allows gas savings by pre-warming storage slots
/// - Provides predictable gas costs for complex interactions
///
/// ## Transaction Format
/// Type 1 transactions include an access list of:
/// - Addresses to be accessed
/// - Storage keys per address to be accessed
///
/// ## Gas Savings
/// Pre-declaring access saves ~2000 gas per address and
/// ~2000 gas per storage slot on first access.
is_eip2930: bool = true,

/// EIP-3198 BASEFEE opcode activation (London hardfork).
///
/// ## Purpose
/// Provides smart contracts access to the current block's base fee,
/// enabling on-chain fee market awareness.
///
/// ## Opcode Details
/// - BASEFEE (0x48): Pushes current block's base fee onto stack
/// - Gas cost: 2 (same as other block context opcodes)
///
/// ## Use Cases
/// - Fee estimation within contracts
/// - Conditional execution based on network congestion
/// - MEV-aware contract patterns
/// - Gas price oracles
///
/// ## Complementary to EIP-1559
/// Essential for contracts to interact properly with the
/// new fee market mechanism.
is_eip3198: bool = true,

/// EIP-3651 warm COINBASE activation (Shanghai hardfork).
///
/// ## Purpose
/// Pre-warms the COINBASE address (block producer) to reduce gas costs
/// for common patterns, especially in MEV transactions.
///
/// ## Gas Impact
/// - Before: First COINBASE access costs 2600 gas (cold)
/// - After: COINBASE always costs 100 gas (warm)
///
/// ## MEV Considerations
/// Critical for MEV searchers and builders who frequently
/// interact with the block producer address for payments.
///
/// ## Implementation
/// The COINBASE address is added to the warm address set
/// at the beginning of transaction execution.
is_eip3651: bool = true,

/// EIP-3855 PUSH0 instruction activation (Shanghai hardfork).
///
/// ## Purpose
/// Introduces dedicated opcode for pushing zero onto the stack,
/// optimizing a very common pattern in smart contracts.
///
/// ## Opcode Details
/// - PUSH0 (0x5F): Pushes 0 onto the stack
/// - Gas cost: 2 (base opcode cost)
/// - Replaces: PUSH1 0x00 (costs 3 gas)
///
/// ## Benefits
/// - 33% gas reduction for pushing zero
/// - Smaller bytecode (1 byte vs 2 bytes)
/// - Cleaner assembly code
///
/// ## Usage Statistics
/// Analysis showed ~11% of all PUSH operations push zero,
/// making this a significant optimization.
is_eip3855: bool = true,

/// EIP-3860 initcode size limit activation (Shanghai hardfork).
///
/// ## Purpose
/// Introduces explicit limits and gas metering for contract creation
/// code to prevent DoS vectors and ensure predictable costs.
///
/// ## Key Limits
/// - Maximum initcode size: 49152 bytes (2x max contract size)
/// - Gas cost: 2 gas per 32-byte word of initcode
is_eip3860: bool = true,

/// EIP-4895: Beacon chain validator withdrawals
is_eip4895: bool = true,

/// EIP-4844: Blob transactions for L2 data availability
///
/// ## L2 Impact
/// Dramatically reduces costs for rollups by providing
/// dedicated data availability layer.
is_eip4844: bool = true,

/// EIP-1153 transient storage activation (Cancun hardfork).
///
/// ## Purpose
/// Introduces transaction-scoped storage that automatically clears
/// after execution, enabling efficient temporary data patterns.
///
/// ## New Opcodes
/// - TLOAD (0x5C): Load from transient storage
/// - TSTORE (0x5D): Store to transient storage
/// - Gas costs: 100 for TLOAD, 100 for TSTORE
///
/// ## Key Properties
/// - Cleared after each transaction (not persisted)
/// - Reverted on transaction failure
/// - Separate namespace from persistent storage
/// - More gas efficient than SSTORE/SLOAD for temporary data
///
/// ## Use Cases
/// - Reentrancy guards without storage slots
/// - Temporary computation results
/// - Cross-contract communication within transaction
is_eip1153: bool = true,

/// EIP-5656 MCOPY instruction activation (Cancun hardfork).
///
/// ## Purpose
/// Native memory copying instruction replacing inefficient
/// loop-based implementations in smart contracts.
///
/// ## Opcode Details
/// - MCOPY (0x5E): Copy memory regions
/// - Stack: [dest_offset, src_offset, length]
/// - Gas: 3 + 3 * ceil(length / 32) + memory expansion
///
/// ## Performance Impact
/// - ~10x faster than Solidity's loop-based copying
/// - Reduces bytecode size for memory operations
/// - Critical for data-heavy operations
///
/// ## Common Patterns
/// Optimizes array copying, string manipulation, and
/// data structure operations in smart contracts.
is_eip5656: bool = true,

/// EIP-3541 contract code prefix restriction (London hardfork).
///
/// ## Purpose
/// Reserves the 0xEF byte prefix for future EVM Object Format (EOF),
/// preventing deployment of contracts with this prefix.
///
/// ## Restrictions
/// - New contracts cannot start with 0xEF byte
/// - Applies to CREATE, CREATE2, and deployment transactions
/// - Existing contracts with 0xEF prefix remain valid
///
/// ## EOF Preparation
/// This reservation enables future introduction of:
/// - Structured contract format with metadata
/// - Separate code and data sections
/// - Static jumps and improved analysis
/// - Versioning for EVM upgrades
///
/// ## Developer Impact
/// Extremely rare in practice as 0xEF was not a valid opcode,
/// making accidental conflicts unlikely.
is_eip3541: bool = true,

/// Creates a ChainRules configuration for a specific Ethereum hardfork.
///
/// This factory function generates the appropriate set of protocol rules
/// for any supported hardfork, enabling the EVM to execute transactions
/// according to historical consensus rules.
///
/// ## Parameters
/// - `hardfork`: The target hardfork to configure rules for
///
/// ## Returns
/// A fully configured ChainRules instance with all flags set appropriately
/// for the specified hardfork.
///
/// ## Algorithm
/// The function starts with all features enabled (latest hardfork) and then
/// selectively disables features that weren't available at the specified
/// hardfork. This approach ensures new features are automatically included
/// in the latest configuration.
///
/// ## Example
/// ```zig
/// // Configure EVM for London hardfork rules
/// const london_rules = ChainRules.for_hardfork(.LONDON);
///
/// // Configure EVM for historical execution (e.g., replaying old blocks)
/// const byzantium_rules = ChainRules.for_hardfork(.BYZANTIUM);
/// ```
///
/// ## Hardfork Ordering
/// Each hardfork case disables all features introduced after it,
/// maintaining historical accuracy for transaction replay and testing.
/// Mapping of chain rule fields to the hardfork in which they were introduced.
const HardforkRule = struct {
    field_name: []const u8,
    introduced_in: Hardfork,
};

/// Comptime-generated mapping of all chain rules to their introduction hardforks.
/// This data-driven approach replaces the massive switch statement.
/// Default chain rules for the latest hardfork (CANCUN).
/// Pre-generated at compile time for zero runtime overhead.
pub const DEFAULT = for_hardfork(.DEFAULT);

const HARDFORK_RULES = [_]HardforkRule{
    .{ .field_name = "is_homestead", .introduced_in = .HOMESTEAD },
    .{ .field_name = "is_eip150", .introduced_in = .TANGERINE_WHISTLE },
    .{ .field_name = "is_eip158", .introduced_in = .SPURIOUS_DRAGON },
    .{ .field_name = "is_byzantium", .introduced_in = .BYZANTIUM },
    .{ .field_name = "is_constantinople", .introduced_in = .CONSTANTINOPLE },
    .{ .field_name = "is_petersburg", .introduced_in = .PETERSBURG },
    .{ .field_name = "is_istanbul", .introduced_in = .ISTANBUL },
    .{ .field_name = "is_berlin", .introduced_in = .BERLIN },
    .{ .field_name = "is_london", .introduced_in = .LONDON },
    .{ .field_name = "is_merge", .introduced_in = .MERGE },
    .{ .field_name = "is_shanghai", .introduced_in = .SHANGHAI },
    .{ .field_name = "is_cancun", .introduced_in = .CANCUN },
    // EIPs grouped by their hardfork
    .{ .field_name = "is_eip1559", .introduced_in = .LONDON },
    .{ .field_name = "is_eip2930", .introduced_in = .BERLIN },
    .{ .field_name = "is_eip3198", .introduced_in = .LONDON },
    .{ .field_name = "is_eip3541", .introduced_in = .LONDON },
    .{ .field_name = "is_eip3651", .introduced_in = .SHANGHAI },
    .{ .field_name = "is_eip3855", .introduced_in = .SHANGHAI },
    .{ .field_name = "is_eip3860", .introduced_in = .SHANGHAI },
    .{ .field_name = "is_eip4895", .introduced_in = .SHANGHAI },
    .{ .field_name = "is_eip4844", .introduced_in = .CANCUN },
    .{ .field_name = "is_eip1153", .introduced_in = .CANCUN },
    .{ .field_name = "is_eip5656", .introduced_in = .CANCUN },
};

pub fn for_hardfork(hardfork: Hardfork) ChainRules {
    var rules = ChainRules{}; // All fields default to true

    // Disable features that were introduced after the target hardfork
    inline for (HARDFORK_RULES) |rule| {
        // Use branch hint for the common case (later hardforks with more features)
        if (@intFromEnum(hardfork) < @intFromEnum(rule.introduced_in)) {
            @branchHint(.cold);
            @field(rules, rule.field_name) = false;
        } else {
            @branchHint(.likely);
        }
    }

    return rules;
}
