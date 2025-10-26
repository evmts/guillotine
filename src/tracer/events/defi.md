# Code Review: defi.zig

**Reviewed:** 2025-10-26
**Mission-Critical Status:** Financial Infrastructure - Zero Error Tolerance

## Overview

This file defines event structures for DeFi protocol detection and MEV (Maximal Extractable Value) monitoring. It covers protocol detection for Uniswap, Compound, Aave, MakerDAO, Curve, plus MEV events like swaps, flash loans, arbitrage, and sandwich attacks. The module is purely declarative with struct/enum definitions and no runtime logic.

## Code Quality: **C+ (Adequate but with significant gaps)**

### Strengths
- **Comprehensive Protocol Coverage**: Covers major DeFi protocols (Uniswap, Compound, Aave, Maker, Curve)
- **MEV Awareness**: Includes sophisticated MEV detection (sandwich attacks, arbitrage)
- **Logical Organization**: Protocols and MEV events clearly separated
- **Version Tracking**: Distinguishes protocol versions (Uniswap V1-V4, Aave V1-V3)

### Weaknesses
- **NO TESTS**: Zero test coverage despite financial operations
- **Memory Safety Issues**: Multiple slices without ownership documentation
- **Incomplete Enums**: Missing common contract types and pool variants
- **No Detection Logic**: Struct definitions without implementation
- **No Constants**: Missing function selectors, event signatures, known addresses

## Issues Found

### CRITICAL: Zero Test Coverage
**Severity:** Critical
**Lines:** Entire file

**Issues:**
1. No tests for struct sizes (must fit in `EvmEvent` union)
2. No validation of enum completeness
3. No tests for protocol version compatibility
4. No edge case validation (null optionals, empty slices)

**Impact:**
- Cannot verify structs are reasonable
- No validation that enums cover all cases
- Risk of runtime panics from unexpected states

**Required Tests:**
```zig
test "defi event structs fit in EvmEvent union" {
    const max_size = @sizeOf(EvmEvent);
    try testing.expect(@sizeOf(SwapDetected) <= max_size);
    try testing.expect(@sizeOf(FlashLoan) <= max_size);
    try testing.expect(@sizeOf(UniswapDetected) <= max_size);
    // ... all other structs
}

test "protocol version enums complete" {
    // Verify we have latest versions
    try testing.expect(@hasField(UniswapVersion, "v4"));
    try testing.expect(@hasField(AaveVersion, "v3"));
}

test "sandwich attack struct validation" {
    // Test that all required fields are present
    // Test hash types are [32]u8
}

test "optional fields handle null safely" {
    const uniswap = UniswapDetected{
        .contract = undefined,
        .version = .v3,
        .contract_type = .pool,
        .token0 = null,
        .token1 = null,
        .fee_tier = null,
        .liquidity = null,
    };
    // Verify no crashes on null access patterns
}
```

### CRITICAL: Slice Memory Ownership Undocumented
**Severity:** Critical
**Lines:** 26, 86

```zig
// Line 26
path: []const Address,

// Line 86
tokens: []const Address,
```

**Issues:**
1. No documentation on who allocates these slices
2. No lifetime guarantees
3. Arbitrage path length unbounded (could be megabytes)
4. Curve pool tokens unbounded

**Security Risk:**
- **Path validation bypass**: Attacker could craft path with circular references
- **Memory exhaustion**: Unbounded slices could cause OOM
- **Use-after-free**: If referencing temporary memory

**Recommendation:**
Add bounds and ownership:
```zig
/// Arbitrage path through DEX contracts. Max reasonable path: 4 hops.
/// Memory: Owned by event collector, must be freed when event discarded.
/// Validation: MUST check for cycles before construction.
path: []const Address,  // TODO: Add max_path_length = 10

/// Pool tokens in Curve pool. Typical: 2-4, max observed: 8.
/// Memory: Borrowed from pool contract state, valid until next state change.
tokens: []const Address,  // TODO: Consider [8]Address fixed array
```

Or use fixed-size arrays:
```zig
path: std.BoundedArray(Address, 10),  // Max 10 hops
tokens: std.BoundedArray(Address, 8),  // Max 8 tokens in pool
```

### CRITICAL: SandwichAttack Detection Incomplete
**Severity:** Critical
**Lines:** 33-39

```zig
pub const SandwichAttack = struct {
    attacker: Address,
    victim_tx: [32]u8,
    front_run_tx: [32]u8,
    back_run_tx: [32]u8,
    profit: u256,
};
```

**Issues:**
1. **No victim address** - Can't identify who was sandwiched
2. **No DEX address** - Can't identify where attack occurred
3. **No timestamp/block** - Can't correlate with block ordering
4. **No victim loss** - Only tracks attacker profit
5. **No pool/pair info** - Can't identify affected liquidity pool

**Impact:** Incomplete data for:
- Victim refunds/compensation
- MEV relay monitoring
- Pool-specific attack patterns
- Regulatory reporting

**Recommendation:**
```zig
pub const SandwichAttack = struct {
    attacker: Address,
    victim: Address,              // WHO was attacked
    dex_address: Address,         // WHERE attack occurred
    pool_pair: [2]Address,        // WHICH pool (token0, token1)
    victim_tx: [32]u8,
    front_run_tx: [32]u8,
    back_run_tx: [32]u8,
    block_number: u64,
    victim_loss: u256,            // How much victim lost
    attacker_profit: u256,        // Attacker's net profit (after gas)
    gas_cost: u64,                // Total gas used for attack
};
```

### HIGH: Missing Critical DeFi Protocols
**Severity:** High
**Lines:** 91-166

**Missing Protocols:**
1. **Balancer** - Major AMM with multi-asset pools
2. **SushiSwap** - Major Uniswap fork
3. **PancakeSwap** - Largest BSC DEX (if multi-chain)
4. **Yearn Finance** - Yield aggregator
5. **Convex Finance** - Curve wrapper
6. **Lido** - Largest liquid staking
7. **Rocket Pool** - Decentralized liquid staking
8. **Euler** - Lending protocol
9. **Radiant** - Cross-chain lending

**Justification:** These protocols collectively handle >$10B TVL.

**Recommendation:**
Add missing protocol structs:
```zig
pub const BalancerDetected = struct {
    contract: Address,
    pool_type: BalancerPoolType,
    tokens: []const Address,
    weights: ?[]const u256,
    swap_fee: ?u256,
};

pub const LidoDetected = struct {
    contract: Address,
    contract_type: LidoContractType,
    steth_address: ?Address,
    wsteth_address: ?Address,
};
```

### HIGH: Flash Loan Struct Missing Critical Fields
**Severity:** High
**Lines:** 16-22

```zig
pub const FlashLoan = struct {
    lender: Address,
    borrower: Address,
    token: Address,
    amount: u256,
    fee: u256,
};
```

**Missing Fields:**
1. **success: bool** - Did the flash loan succeed or revert?
2. **loan_initiator** - Who initiated the loan (may differ from borrower)
3. **callback_contract** - Where was the loan executed?
4. **protocol** - Which protocol (Aave, Uniswap, dYdX)?
5. **repay_amount** - Total repayment (amount + fee)

**Impact:**
- Can't distinguish failed flash loans (MEV attempt vs. successful trade)
- Can't track flash loan source
- Can't correlate with other events in same tx

**Recommendation:**
```zig
pub const FlashLoan = struct {
    protocol: FlashLoanProtocol,  // NEW
    lender: Address,
    borrower: Address,
    initiator: Address,           // NEW
    receiver: Address,            // NEW: callback contract
    token: Address,
    amount: u256,
    fee: u256,
    repay_amount: u256,           // NEW: amount + fee
    success: bool,                // NEW: did loan complete?
};

pub const FlashLoanProtocol = enum {
    aave_v2,
    aave_v3,
    uniswap_v2,
    uniswap_v3,
    dydx,
    maker,
    balancer,
    euler,
};
```

### HIGH: Swap Detection Insufficient
**Severity:** High
**Lines:** 6-13

```zig
pub const SwapDetected = struct {
    dex_address: Address,
    token_in: Address,
    token_out: Address,
    amount_in: u256,
    amount_out: u256,
    caller: Address,
};
```

**Missing Fields:**
1. **recipient** - Where tokens were sent (may differ from caller)
2. **protocol** - Which DEX (Uniswap V2 vs V3 vs Curve)
3. **pool_address** - Specific pool used
4. **price_impact** - How much price moved
5. **slippage** - Actual vs expected
6. **deadline** - Transaction deadline
7. **route** - Multi-hop swap path

**Impact:**
- Can't distinguish direct swaps from routed swaps
- Can't calculate price impact
- Can't detect slippage attacks
- Can't correlate swaps with specific pools

**Recommendation:**
```zig
pub const SwapDetected = struct {
    protocol: DexProtocol,           // NEW
    dex_address: Address,
    pool_address: Address,           // NEW
    token_in: Address,
    token_out: Address,
    amount_in: u256,
    amount_out: u256,
    caller: Address,
    recipient: Address,              // NEW
    route: ?[]const Address,         // NEW: for multi-hop
    price_before: ?u256,             // NEW
    price_after: ?u256,              // NEW
    price_impact_bps: ?u16,          // NEW: basis points
};
```

### MEDIUM: Arbitrage Opportunity Struct Unrealistic
**Severity:** Medium
**Lines:** 25-30

```zig
pub const ArbitrageOpportunity = struct {
    path: []const Address,
    profit: u256,
    gas_cost: u64,
    block_number: u64,
};
```

**Issues:**
1. **No token information** - What token is being arbitraged?
2. **No required capital** - How much capital needed?
3. **No time sensitivity** - How long is opportunity valid?
4. **No competition** - Is this already being exploited?
5. **gas_cost: u64** - This is gas units, not cost in ETH/wei
6. **No DEX information** - Where is the arbitrage?

**Use Case Problems:**
- Can't execute arbitrage without knowing:
  - Which token to trade
  - How much capital required
  - Which DEXes to use
  - If opportunity still exists

**Recommendation:**
Either rename to `ArbitrageDetected` (past tense, detected after execution) or add:
```zig
pub const ArbitrageOpportunity = struct {
    path: []const Address,          // DEX addresses
    tokens: []const Address,        // Token sequence in path
    profit: u256,
    profit_token: Address,          // NEW
    required_capital: u256,         // NEW
    gas_estimate: u64,              // Gas units
    gas_cost_wei: u256,             // NEW: Gas cost in wei
    net_profit: i256,               // NEW: profit - gas_cost
    block_number: u64,
    expiry_block: u64,              // NEW: when opportunity expires
    detected_at: u64,               // NEW: timestamp
    pools: []const Address,         // NEW: specific pool addresses
};
```

### MEDIUM: UniswapDetected Missing V2 Router Variants
**Severity:** Medium
**Lines:** 100-109

**Missing Contract Types:**
1. **router02** - Main V2 router (different from router01)
2. **migrator** - V2 to V3 migration contract
3. **pair** - V2 pair contract (distinct from V3 pool)

**Recommendation:**
```zig
pub const UniswapContractType = enum {
    factory,
    router,
    router02,        // NEW: V2 router (most common)
    pool,            // V3 pool
    pair,            // NEW: V2 pair
    position_manager,
    swap_router,
    quoter,
    oracle,
    staker,
    migrator,        // NEW: V2->V3 migration
};
```

### MEDIUM: Compound Enum Missing Gov Alpha
**Severity:** Medium
**Lines:** 111-119

Missing: `governance_alpha` (original governance contract, still in use)

### MEDIUM: MakerDAO Enum Missing Critical Contracts
**Severity:** Medium
**Lines:** 139-155

**Missing:**
1. **proxy_actions** - DSProxy actions library
2. **cdp_manager** - CDP management
3. **migration** - SAI to DAI migration
4. **end** - Emergency shutdown module
5. **esm** - Emergency shutdown module v2

### LOW: CurvePoolType Missing Recent Variants
**Severity:** Low
**Lines:** 157-166

**Missing:**
1. **stable_swap_ng** - New generation stable pools
2. **twocrypto_ng** - New generation 2-token volatile pools
3. **tricrypto_ng** - New generation 3-token volatile pools

### LOW: No Protocol Constants
**Severity:** Low

File has NO constants:
- No known contract addresses
- No function selectors
- No event signatures
- No protocol-specific magic numbers

**Impact:** Detection logic (when implemented) will need these elsewhere.

**Recommendation:**
Add constants file or section:
```zig
pub const KNOWN_CONTRACTS = struct {
    pub const UNISWAP_V2_FACTORY = Address.fromHex("0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f");
    pub const UNISWAP_V3_FACTORY = Address.fromHex("0x1F98431c8aD98523631AE4a59f267346ea31F984");
    // ... more known addresses
};

pub const UNISWAP_V3_SELECTORS = struct {
    pub const swap: [4]u8 = [4]u8{ 0x12, 0x8a, 0xcb, 0x08 };
    pub const mint: [4]u8 = [4]u8{ 0x6a, 0x62, 0x7b, 0x01 };
    // ... more selectors
};
```

## Missing Features / Incomplete Implementation

### 1. No Detection Logic
Like `token.zig`, this file defines WHAT to detect but not HOW. Missing:
- Function to identify Uniswap contracts
- Function to parse swap events
- Heuristics for protocol detection
- Function selector matching

### 2. No Event Construction
No code in codebase constructs these structs. They're dead definitions.

**Evidence:**
```bash
$ grep -r "SwapDetected{" --include="*.zig" | grep -v defi.zig | grep -v events.zig
# No matches
```

### 3. No MEV Detection Algorithm
Sophisticated structs like `SandwichAttack` and `ArbitrageOpportunity` exist but:
- No algorithm to detect sandwiches from transaction ordering
- No algorithm to identify arbitrage from price differences
- No mempool monitoring integration

### 4. No Protocol Versioning Logic
Enums have versions (V1, V2, V3) but no:
- Function to detect version from bytecode
- Mapping of versions to features/selectors
- Compatibility checks between versions

## Security Concerns

### 1. Unbounded Arbitrage Paths
**Severity:** High

`ArbitrageOpportunity.path` is unbounded:
```zig
path: []const Address,
```

**Attack Vector:**
1. Attacker crafts circular path: A→B→C→A→B→C... (infinite loop)
2. Event collector allocates unbounded memory
3. OOM or performance degradation

**Mitigation:**
```zig
pub const MAX_ARBITRAGE_HOPS = 10;
path: std.BoundedArray(Address, MAX_ARBITRAGE_HOPS),
```

### 2. Sandwich Attack False Positives
**Severity:** Medium

Current struct can't distinguish:
- True sandwich attack
- Coincidental ordering
- Intentional MEV protection (user's own front-run)

**Missing Fields:** Intent detection, timing analysis, profit threshold.

### 3. Flash Loan Reentrancy Not Tracked
**Severity:** Medium

`FlashLoan` struct has no:
- Reentrancy depth
- Nested loan detection
- Callback validation

**Risk:** Can't detect complex flash loan attacks with multiple nested loans.

### 4. No Profit Validation
**Severity:** Low

`profit: u256` and `fee: u256` have no validation:
- Fee > amount (invalid)
- Profit > total supply (impossible)
- Negative profit (should be separate field)

## Performance Issues

### 1. Large Struct Sizes
**Severity:** Medium

Structs with slices and optional fields may be large:
```zig
pub const CurveDetected = struct {
    contract: Address,        // 20 bytes
    pool_type: CurvePoolType, // 1 byte
    tokens: []const Address,  // 16 bytes (slice)
    amplification: ?u256,     // 33 bytes (optional u256)
    fee: ?u256,               // 33 bytes
    admin_fee: ?u256,         // 33 bytes
};
// Total: ~136 bytes + slice data
```

**Impact:** Large union size in `EvmEvent`.

**Recommendation:**
Use fixed arrays where reasonable:
```zig
tokens: [8]?Address,  // Most pools have ≤8 tokens
```

### 2. Optional Field Overhead
**Severity:** Low

Most structs use 5+ optional fields. Each optional adds 1 byte overhead.

**Impact:** Minimal but compounds in large trace collections.

## Adherence to CLAUDE.md Standards

### ✅ **Compliant:**
- Direct imports: `Address = primitives.Address.Address` ✅
- No stub implementations (technically)
- No commented code
- No swallowed errors (no error handling at all)

### ❌ **Non-Compliant:**
- **Tests in source files**: ZERO tests ❌
- **Zero Tolerance**: Unused structs are effectively stubs ❌
- **TDD**: No tests = not following TDD ❌

## Recommendations (Prioritized)

### Priority 1: CRITICAL - Add Comprehensive Tests
**Effort:** Medium | **Impact:** Critical

```zig
test "all DeFi structs fit in EvmEvent union"
test "protocol version enums are complete"
test "sandwich attack has required fields"
test "unbounded slices are documented"
test "optional field combinations valid"
```

### Priority 2: CRITICAL - Fix SandwichAttack Struct
**Effort:** Low | **Impact:** Critical

Add victim, DEX, pool, timestamp, and loss tracking.

### Priority 3: CRITICAL - Document Slice Ownership
**Effort:** Low | **Impact:** High

Add clear documentation for all `[]const Address` fields.

### Priority 4: HIGH - Complete Flash Loan Detection
**Effort:** Medium | **Impact:** High

Add success flag, protocol field, and repayment tracking.

### Priority 5: HIGH - Enhance Swap Detection
**Effort:** Medium | **Impact:** High

Add recipient, protocol, pool, and price impact fields.

### Priority 6: HIGH - Add Missing Protocols
**Effort:** High | **Impact:** Medium

Add Balancer, Lido, Yearn, and other major protocols.

### Priority 7: MEDIUM - Fix Arbitrage Struct
**Effort:** Medium | **Impact:** Medium

Add capital requirements, token info, and expiry.

### Priority 8: MEDIUM - Add Protocol Constants
**Effort:** High | **Impact:** Medium

Add known addresses, selectors, and event signatures.

### Priority 9: LOW - Complete Enums
**Effort:** Low | **Impact:** Low

Add missing contract types for all protocols.

## Testing Requirements

Minimum tests required:
1. ✅ **Struct size validation** (fit in EvmEvent union)
2. ✅ **Optional field combinations** (all valid states)
3. ✅ **Enum completeness** (cover all protocol versions)
4. ✅ **Slice bounds** (no unbounded allocations)
5. ✅ **Field validation** (fee < amount, profit reasonable)
6. ✅ **Address validation** (non-zero where required)

**Test Command:**
```bash
zig build test-unit -Dtest-filter='defi'
```

## Conclusion

**Overall Assessment:** The file defines an ambitious DeFi monitoring system but is **CRITICALLY INCOMPLETE** and has **SECURITY ISSUES**.

**Risk Level:** **HIGH**
- Unbounded slices (memory exhaustion risk)
- No tests for financial operations
- Sandwich attack detection incomplete (can't identify victims)
- Flash loan tracking insufficient

**Action Required:** **STOP** DeFi detection feature development until:
1. All structs have comprehensive tests
2. Slice ownership is documented and bounded
3. SandwichAttack struct is complete
4. FlashLoan and SwapDetected have full context

**Blocker Issues:**
1. Zero test coverage (violates Zero Tolerance)
2. Unbounded slices (security risk)
3. Incomplete sandwich attack detection (can't track victims for refunds)

This module is **NOT READY** for production use in mission-critical financial infrastructure.
