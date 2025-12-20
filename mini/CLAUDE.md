# Guillotine Mini - EVM Implementation

Minimal, correct, and well-tested Ethereum Virtual Machine (EVM) implementation in Zig, prioritizing specification compliance, clarity, and hardfork support (Berlin through Prague).

## Quick Start

```bash
zig build              # Build all modules
zig build test         # Run unit + spec tests
zig build specs        # Run ethereum/tests validation
zig build wasm         # Build WebAssembly library
zig build test-watch   # Interactive test runner

# Debug failing tests (RECOMMENDED)
bun scripts/isolate-test.ts "test_name"  # Max debug output + analysis
bun scripts/test-subset.ts "pattern"     # Filter test categories
```

**Prerequisites**:
- **Zig 0.15.1+** (core build system)
- **Cargo** (Rust package manager - **required** for building BN254/ARK cryptographic dependencies)
- **Python 3.8+** (for test generation and reference implementation)
- **uv** (Python package manager for spec fixture generation): `brew install uv`
- **Bun** (for TS helpers/agents): `brew install bun`

---

## Architecture

```
src/
├── evm.zig               # Orchestrator: state, storage, gas refunds, nested calls
├── frame.zig             # Bytecode interpreter: stack, memory, PC, per-opcode logic
├── host.zig              # Abstract state backend interface
├── hardfork.zig          # Hardfork detection and feature flags
├── opcode.zig            # Opcode definitions and utilities
├── trace.zig             # EIP-3155 trace generation
└── errors.zig            # Error types

External Dependencies (fetched via zig build):
├── primitives            # Ethereum types (Address, u256, gas constants, RLP, ABI, etc.)
│                         # Source: https://github.com/evmts/primitives
├── crypto                # Cryptographic primitives (keccak256, secp256k1, BLS12-381)
└── precompiles           # Ethereum precompiled contracts
```

### Key Design Principles

| Component | Responsibility |
|-----------|----------------|
| **Evm** | State management, storage, gas refunds, warm/cold tracking, nested calls |
| **Frame** | Stack, memory, PC, bytecode interpretation, opcode execution |
| **Host** | Pluggable state backend (balances, nonces, code, logs, self-destruct) |
| **Hardfork** | Gas cost adjustments, feature flag guards (`isAtLeast()`, `isBefore()`) |

**Allocation strategy**: Arena allocator for transaction-scoped memory (all freed at transaction end)

---

## Testing & Debugging

### Test Types

| Type | Purpose | Command |
|------|---------|---------|
| **Unit tests** | Inline `test` blocks | `zig build test` |
| **Spec tests** | ethereum/tests GeneralStateTests | `zig build specs` |
| **Filtered tests** | By hardfork/EIP/opcode | `TEST_FILTER="Cancun" zig build specs` |
| **Trace tests** | EIP-3155 trace capture/comparison | `zig build test-trace` |
| **Watch mode** | Auto-reload on changes | `zig build test-watch` |
| **Engine tests** | Consensus-layer format tests | `INCLUDE_ENGINE_TESTS=1 zig build specs` |

**Prerequisites:**
- Zig 0.15.1 or later
- Python 3.8+ (for test generation and reference implementation)
- uv (Python package manager) for spec fixture generation: `brew install uv`
- Bun (for TS helpers/agents): `brew install bun`

### Test Scope and Filtering

**Engine API Tests (Optional)**

By default, `blockchain_test_engine` format tests are **disabled** because they test consensus-layer functionality (block validation, Engine API payloads) rather than core EVM execution. These tests are out of scope for an EVM library like guillotine-mini (similar to how REVM doesn't implement Engine API).

To include them for comprehensive testing:
```bash
INCLUDE_ENGINE_TESTS=1 zig build specs
```

**What's tested:**
- ✅ **Default**: Pure EVM execution (opcodes, gas, state transitions, precompiles)
- ✅ **Default**: Transaction processing and hardfork-specific EVM changes
- ❌ **Disabled**: Block validation, consensus rules, Engine API server implementation
- ❌ **Disabled**: Withdrawal timing edge cases (consensus-layer concern)

### Helper Scripts

<details>
<summary><b>🔬 isolate-test.ts</b> - Test Isolation Helper (⭐ RECOMMENDED)</summary>

```bash
bun scripts/isolate-test.ts "exact_test_name"
```

**Features:**
- Runs single test with maximum debug output
- Automatic failure type detection (crash/gas/behavior)
- Trace divergence analysis (PC, opcode, gas, stack)
- Next-step debugging guidance
- Quick reference commands

</details>

<details>
<summary><b>🎯 test-subset.ts</b> - Test Subset Runner</summary>

# Using helper scripts
bun scripts/test-subset.ts Cancun
bun scripts/test-subset.ts transientStorage
bun scripts/test-subset.ts MCOPY

# Or using shell scripts
./scripts/test-subset.sh Cancun
./scripts/test-subset.sh "exact_test_name"

# Direct filtering with zig build
TEST_FILTER="Cancun" zig build specs
TEST_FILTER="transientStorage" zig build specs
TEST_FILTER="push0" zig build specs
```

#### Granular Spec Targets

Large hardforks are split into smaller sub-targets for faster iteration:

```bash
# Berlin
zig build specs-berlin-acl
zig build specs-berlin-intrinsic-gas-cost
zig build specs-berlin-intrinsic-type0
zig build specs-berlin-intrinsic-type1

# Frontier
zig build specs-frontier-precompiles
zig build specs-frontier-identity
zig build specs-frontier-create
zig build specs-frontier-call
zig build specs-frontier-calldata
zig build specs-frontier-dup
zig build specs-frontier-push
zig build specs-frontier-stack
zig build specs-frontier-opcodes

# Shanghai
zig build specs-shanghai-push0
zig build specs-shanghai-warmcoinbase
zig build specs-shanghai-initcode
zig build specs-shanghai-withdrawals

# Cancun
zig build specs-cancun-tstore-basic
zig build specs-cancun-tstore-reentrancy
zig build specs-cancun-tstore-contexts
zig build specs-cancun-mcopy
zig build specs-cancun-selfdestruct
zig build specs-cancun-blobbasefee
zig build specs-cancun-blob-precompile
zig build specs-cancun-blob-opcodes
zig build specs-cancun-blob-tx-small
zig build specs-cancun-blob-tx-subtraction
zig build specs-cancun-blob-tx-insufficient
zig build specs-cancun-blob-tx-sufficient
zig build specs-cancun-blob-tx-valid-combos

# Prague
zig build specs-prague-calldata-cost-type0
zig build specs-prague-calldata-cost-type1-2
zig build specs-prague-calldata-cost-type3
zig build specs-prague-calldata-cost-type4
zig build specs-prague-calldata-cost-refunds
zig build specs-prague-bls-g1
zig build specs-prague-bls-g2
zig build specs-prague-bls-pairing
zig build specs-prague-bls-map
zig build specs-prague-bls-misc
zig build specs-prague-setcode-calls
zig build specs-prague-setcode-gas
zig build specs-prague-setcode-txs
zig build specs-prague-setcode-advanced

# Osaka
zig build specs-osaka-modexp-variable-gas
zig build specs-osaka-modexp-vectors-eip
zig build specs-osaka-modexp-vectors-legacy
zig build specs-osaka-modexp-misc
zig build specs-osaka-other
```

**Use for:** Running entire test categories by hardfork, EIP, or pattern

</details>

<details>
<summary><b>🤖 fix-specs.ts</b> - Automated Spec Fixer</summary>

```bash
bun run scripts/fix-specs.ts               # Fix all test suites
bun run scripts/fix-specs.ts suite <name>  # Fix specific suite
```

**Features:**
- AI-powered systematic test fixing
- 7-checkpoint methodology (no guesswork)
- Historical context injection (known-issues.json)
- Auto-commit on success
- Comprehensive reporting (reports/spec-fixes/)

</details>

### Debugging Workflow

```bash
# 1. Find failures
bun scripts/test-subset.ts transientStorage

# 2. Isolate and debug (get automated analysis)
bun scripts/isolate-test.ts "transStorageReset"

# 3. Review divergence output (PC, opcode, gas, stack)
# 4. Fix in src/frame.zig or src/evm.zig
# 5. Verify
bun scripts/isolate-test.ts "transStorageReset"
```

**Test filtering patterns:**
- **Hardfork**: `Cancun`, `Shanghai`, `London`, `Berlin`, `Merge`, `Prague`
- **EIP**: `transientStorage`, `push0`, `MCOPY`, `warmcoinbase`
- **Opcode**: `add`, `mul`, `sstore`, `sload`, `call`, `create2`
- **Category**: `vmArithmeticTest`, `vmBitwiseLogicOperation`, `vmIOandFlowOperations`

---

### Spec Fixer (AI-Assisted)

Use an agent to iterate on failing specs and generate focused reports:

Prereqs:
- `bun` installed and `cd scripts && bun install`
- `ANTHROPIC_API_KEY` exported in your shell (or `.env` at repo root)

Run:
```bash
# All suites
bun run scripts/fix-specs.ts

# One suite
bun run scripts/fix-specs.ts suite shanghai-push0
```

The script runs tests, invokes the agent on failure, and saves reports in `reports/spec-fixes/` with a summary at the end. If no API key is set, it skips auto-fix and just runs the tests.

## Core Components

<details>
<summary><b>Evm (src/evm.zig)</b></summary>

**Orchestrates:**
- State management (storage, balances, nonces, code)
- Call stack (nested CALL/CREATE, max depth 1024)
- Gas accounting (refunds, warm/cold access via EIP-2929)
- Transient storage (EIP-1153, transaction-scoped)
- Hardfork rules (automatic gas adjustment)

**Key methods:**
- `call()` - Main entry point
- `inner_call()` - CALL/STATICCALL/DELEGATECALL
- `inner_create()` - CREATE/CREATE2
- `accessAddress()`, `accessStorageSlot()` - EIP-2929 tracking
- `get_storage()`, `set_storage()` - Persistent storage
- `get_transient_storage()`, `set_transient_storage()` - EIP-1153

</details>

<details>
<summary><b>Frame (src/frame.zig)</b></summary>

**Manages single execution context:**
- 256-word stack (ArrayList of u256)
- Expandable memory (byte array)
- Program counter (PC) and gas tracking
- Bytecode interpretation

**Key methods:**
- `execute()` - Main execution loop
- `step()` - Single instruction (for tracing)
- Opcode implementations (arithmetic, bitwise, storage, control flow, calls)

</details>

<details>
<summary><b>Host Interface (src/host.zig)</b></summary>

Abstract interface for external state access:

```zig
pub const HostInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        getBalance: *const fn (ptr: *anyopaque, address: Address) u256,
        setBalance: *const fn (ptr: *anyopaque, address: Address, balance: u256) void,
        getCode: *const fn (ptr: *anyopaque, address: Address) []const u8,
        setCode: *const fn (ptr: *anyopaque, address: Address, code: []const u8) void,
        getStorage: *const fn (ptr: *anyopaque, address: Address, slot: u256) u256,
        setStorage: *const fn (ptr: *anyopaque, address: Address, slot: u256, value: u256) void,
        getNonce: *const fn (ptr: *anyopaque, address: Address) u64,
        setNonce: *const fn (ptr: *anyopaque, address: Address, nonce: u64) void,
    };
};
```

**Note:** The host interface is used only for external state backends. Nested calls (CALL, DELEGATECALL, etc.) are handled internally by `Evm.inner_call()` and do not use this interface.

Test implementation: `test/specs/test_host.zig`

</details>

<details>
<summary><b>Hardfork Support (src/hardfork.zig)</b></summary>

```zig
pub const Hardfork = enum(u8) {
    FRONTIER, HOMESTEAD, TANGERINE, SPURIOUS, BYZANTIUM,
    CONSTANTINOPLE, ISTANBUL, BERLIN, LONDON, MERGE,
    SHANGHAI, CANCUN, PRAGUE,
    pub const DEFAULT = Hardfork.CANCUN;
};
```

**Methods:** `isAtLeast(fork)`, `isBefore(fork)`, `fromString(name)`

</details>

<details>
<summary><b>Primitives Module (External Dependency)</b></summary>

The primitives library is now an external dependency fetched via `zig fetch` from https://github.com/evmts/primitives. It is no longer included as a git submodule.

**Modules provided:**
- **Address** - 20-byte Ethereum address
- **Uint(N)** - Arbitrary precision (u256, u512)
- **GasConstants** - Per-opcode costs, hardfork-aware
- **Rlp** - RLP encoding/decoding
- **Abi** - ABI encoding/decoding
- **Transaction** - Legacy, EIP-2930, EIP-1559, EIP-4844
- **AccessList** - EIP-2930 support
- **Blob** - EIP-4844 blob transactions
- **Hex** - Hex encoding/decoding
- **Crypto** - Cryptographic primitives (keccak256, secp256k1, BLS12-381)
- **Precompiles** - Ethereum precompiled contracts

</details>

---

## EIP Support

| EIP | Feature | Hardfork | Status |
|-----|---------|----------|--------|
| EIP-2929 | State access gas costs | Berlin | ✅ |
| EIP-2930 | Access lists | Berlin | ✅ |
| EIP-1559 | Fee market | London | ✅ |
| EIP-3198 | BASEFEE opcode | London | ✅ |
| EIP-3529 | Reduced gas refunds | London | ✅ |
| EIP-3541 | Reject code starting with 0xEF | London | ✅ |
| EIP-3651 | Warm coinbase | Shanghai | ✅ |
| EIP-3855 | PUSH0 instruction | Shanghai | ✅ |
| EIP-3860 | Limit init code size | Shanghai | ✅ |
| EIP-1153 | Transient storage (TLOAD/TSTORE) | Cancun | ✅ |
| EIP-4844 | Blob transactions (BLOBHASH/BLOBBASEFEE) | Cancun | ✅ |
| EIP-5656 | MCOPY instruction | Cancun | ✅ |
| EIP-6780 | SELFDESTRUCT only in same tx | Cancun | ✅ |
| EIP-7516 | BLOBBASEFEE opcode | Cancun | ✅ |

---

## Gas Metering

**Location:** `src/primitives/gas_constants.zig`

- **Base costs** - Per-opcode execution (ADD, MUL, SSTORE)
- **Memory expansion** - Quadratic cost for growth
- **Call stipend** - 2300 gas for value transfers
- **Warm/Cold access** - EIP-2929 (Berlin+): warm=100, cold=2600
- **Gas refunds** - Capped at 1/2 (pre-London) or 1/5 (London+)
- **Intrinsic gas** - 21000 + calldata costs

---

## Tracing

Full EIP-3155 trace support:
```bash
zig build test-trace
```

**Includes:** PC, opcode, gas remaining, stack, memory, storage changes

Compare traces against reference implementations (geth, execution-specs) to identify divergences.

---

## WASM Build

```bash
zig build wasm
# Output: zig-out/bin/guillotine_mini.wasm (~100-200 KB)
```

<details>
<summary><b>Exported C API Functions</b></summary>

- `evm_create()`, `evm_destroy()`
- `evm_set_bytecode()`, `evm_set_execution_context()`, `evm_set_blockchain_context()`
- `evm_execute()`, `evm_get_gas_remaining()`, `evm_get_gas_used()`
- `evm_is_success()`, `evm_get_output_len()`, `evm_get_output()`
- `evm_set_storage()`, `evm_get_storage()`, `evm_set_balance()`, `evm_set_code()`

See `src/root_c.zig` for full API.

</details>

---

## Development Workflow

### Build Targets

| Command | Purpose |
|---------|---------|
| `zig build` | Build all modules |
| `zig build test` | Unit + spec tests |
| `zig build specs` | Spec tests only |
| `zig build wasm` | WASM library + size report |
| `zig build test-watch` | Interactive test runner |
| `zig build test-trace` | Trace capture tests |

### Adding New Features

1. **Implement**: `src/frame.zig` (opcodes) or `src/evm.zig` (behavior)
2. **Update gas**: `src/primitives/gas_constants.zig` if needed
3. **Add guards**: `self.hardfork.isAtLeast(.FORK_NAME)`
4. **Test**: Run relevant spec tests
5. **Debug**: Use trace divergence analysis

### Code Style

- **Naming**: `snake_case` (functions/variables), `PascalCase` (types)
- **Errors**: Explicit unions, propagate with `try`
- **Comments**: Explain "why", not "what"
- **Docs**: Use `///` for public APIs
- **Format**: Run `zig fmt` before commit

---

## Agent Quick Reference: Python Reference vs Zig Implementation

> **Critical for debugging**: Python execution-specs are the authoritative source. When in doubt, trust Python code over intuition, docs, or Yellow Paper.

> **⚠️ IMPORTANT**: The `execution-specs/` directory is a git submodule containing the official Ethereum execution specifications. **NEVER commit, clean, or modify any files within this submodule.** It should be managed separately and left untouched during normal development.

### File Location Mapping

| Problem Area | Python Reference | Zig Implementation |
|--------------|------------------|-------------------|
| Opcode logic | `execution-specs/.../vm/instructions/*.py` | `src/frame.zig` |
| Gas calculation | `execution-specs/.../vm/gas.py` | `src/primitives/gas_constants.zig` + `src/frame.zig` |
| Call/Create | `execution-specs/.../vm/instructions/system.py` | `src/evm.zig` (`inner_call`, `inner_create`) |
| Storage ops | `execution-specs/.../vm/instructions/storage.py` | `src/evm.zig` (get/set storage) |
| Transient storage | `execution-specs/forks/cancun/.../storage.py` | `src/evm.zig` (get/set transient) |
| State management | `execution-specs/.../state.py` | `src/evm.zig` (balances, nonces, code) |
| Hardfork activation | `execution-specs/forks/<hardfork>/` | `src/hardfork.zig` |
| Warm/cold tracking | `execution-specs/.../vm/__init__.py` | `src/evm.zig` (warm_addresses, warm_storage_slots) |
| Memory ops | `execution-specs/.../vm/memory.py` | `src/frame.zig` (expandMemory) |
| Stack ops | `execution-specs/.../vm/stack.py` | `src/frame.zig` (pushStack, popStack) |

### Architectural Differences

**Python: Single `Evm` Class**
- Location: `execution-specs/.../vm/__init__.py`
- One dataclass: `evm.stack`, `evm.memory`, `evm.pc`, `evm.gas_left`, `evm.message.block_env.state`

**Zig: Split `Evm` + `Frame`**
- **Evm** (`src/evm.zig`): State, storage, gas refunds, nested calls
  - Storage maps: `storage`, `transient_storage`, `original_storage`
  - Warm/cold tracking: `warm_addresses`, `warm_storage_slots`
  - Gas: `gas_refund`
- **Frame** (`src/frame.zig`): Single call frame execution
  - Stack, memory, PC, gas, bytecode
  - Per-frame context: caller, address, value, calldata

> **Key insight**: Python's `evm.stack` → Zig's `frame.stack`. Python's `evm.message.block_env.state` → Zig's `evm.storage`/`evm.balances`

---

## Common Bug Patterns

<details>
<summary><b>1. Gas Metering Bugs (SSTORE example)</b></summary>

**Python pattern:**
```python
def sstore(evm: Evm) -> None:
    key = pop(evm.stack).to_be_bytes32()
    new_value = pop(evm.stack)

    # Check gas stipend FIRST
    if evm.gas_left <= GAS_CALL_STIPEND:
        raise OutOfGasError

    # Then calculate dynamic cost
    gas_cost = Uint(0)
    if (target, key) not in evm.accessed_storage_keys:
        evm.accessed_storage_keys.add((target, key))
        gas_cost += GAS_COLD_SLOAD

    if original_value == current_value and current_value != new_value:
        if original_value == 0:
            gas_cost += GAS_STORAGE_SET
        else:
            gas_cost += GAS_STORAGE_UPDATE - GAS_COLD_SLOAD
    else:
        gas_cost += GAS_WARM_ACCESS

    charge_gas(evm, gas_cost)
```

**Common mistakes:**
- ❌ Forgetting `SstoreSentryGas` (2300) check
- ❌ Not tracking `original_storage` separately from `storage`
- ❌ Wrong gas refund calculation
- ❌ Not adding cold access cost before warm/set/update

</details>

<details>
<summary><b>2. Warm/Cold Access Tracking (EIP-2929)</b></summary>

**Python:**
```python
accessed_addresses: Set[Address]
accessed_storage_keys: Set[Tuple[Address, Bytes]]

if address not in evm.accessed_addresses:
    evm.accessed_addresses.add(address)
    charge_gas(evm, GAS_COLD_ACCOUNT_ACCESS)
else:
    charge_gas(evm, GAS_WARM_ACCESS)
```

**Zig:**
```zig
warm_addresses: ArrayHashMap(Address, void, AddressContext, false)
warm_storage_slots: ArrayHashMap(StorageSlotKey, void, StorageSlotKeyContext, false)

if (!self.warm_addresses.contains(address)) {
    try self.warm_addresses.put(address, {});
    return ColdAccountAccessCost;
} else {
    return WarmStorageReadCost;
}
```

**Key difference**: Python uses sets, Zig uses hash maps with `void` values.

</details>

<details>
<summary><b>3. Transient Storage (EIP-1153)</b></summary>

**Python:**
```python
def tload(evm: Evm) -> None:
    key = pop(evm.stack).to_be_bytes32()
    charge_gas(evm, GAS_WARM_ACCESS)  # Always warm, never cold
    value = get_transient_storage(...)
    push(evm.stack, value)

def tstore(evm: Evm) -> None:
    key = pop(evm.stack).to_be_bytes32()
    new_value = pop(evm.stack)
    charge_gas(evm, GAS_WARM_ACCESS)  # Always warm
    if evm.message.is_static:
        raise WriteInStaticContext
    set_transient_storage(...)
```

**Critical rules:**
- ✅ Transient storage is ALWAYS warm (100 gas), never cold
- ✅ Cleared at transaction boundaries, NOT call boundaries
- ✅ Must check `is_static` for TSTORE
- ✅ No gas refunds

</details>

<details>
<summary><b>4. Hardfork-Specific Behavior</b></summary>

**Python**: Separate directories (`execution-specs/forks/berlin/`, `cancun/`), each fork inherits and overrides.

**Zig**: Runtime checks in one codebase:
```zig
if (self.hardfork.isAtLeast(.CANCUN)) {
    // Cancun-specific (EIP-1153, EIP-4844)
} else if (self.hardfork.isAtLeast(.SHANGHAI)) {
    // Shanghai-specific (PUSH0, warm coinbase)
}
```

**Common mistakes:**
- ❌ Wrong hardfork for feature (e.g., PUSH0 before Shanghai)
- ❌ Not using `isAtLeast` for backward compatibility
- ❌ Breaking earlier hardforks when adding new feature

</details>

---

## Gas Constant Reference

> **Must match exactly** between Python and Zig.

<details>
<summary><b>Gas Constants Table</b></summary>

| Operation | Python | Zig | Value | Hardfork |
|-----------|--------|-----|-------|----------|
| Warm storage read | `GAS_WARM_ACCESS` | `WarmStorageReadCost` | 100 | Berlin+ |
| Cold SLOAD | `GAS_COLD_SLOAD` | `ColdSloadCost` | 2100 | Berlin+ |
| Cold account access | `GAS_COLD_ACCOUNT_ACCESS` | `ColdAccountAccessCost` | 2600 | Berlin+ |
| SSTORE set (0→nonzero) | `GAS_STORAGE_SET` | `SstoreSetGas` | 20000 | All |
| SSTORE update (nonzero→nonzero) | `GAS_STORAGE_UPDATE` | `SstoreResetGas` | 5000 | All |
| SSTORE clear refund | `GAS_STORAGE_CLEAR_REFUND` | `SstoreClearRefund` | 4800 | London+ |
| SSTORE stipend check | `GAS_CALL_STIPEND` | `SstoreSentryGas` | 2300 | All |
| Call value transfer | `GAS_CALL_VALUE` | `CallValueCost` | 9000 | All |
| Call stipend | `GAS_CALL_STIPEND` | `CallStipend` | 2300 | All |

**Locations:**
- Python: `execution-specs/src/ethereum/forks/<hardfork>/vm/gas.py`
- Zig: `src/primitives/gas_constants.zig`

</details>

---

## Debugging Workflow Cheat Sheet

**When a test fails:**

1. **Run with trace**
   ```bash
   TEST_FILTER="exact_test_name" zig build specs
   # Or use: bun scripts/isolate-test.ts "exact_test_name"
   ```

2. **Identify divergence**
   - Find "Trace divergence at step N"
   - Note: PC, opcode, gas remaining, stack state

3. **Find Python reference**
   ```bash
   cd execution-specs/src/ethereum/forks/cancun/vm/instructions/
   grep -r "def <opcode_name>" .
   ```

4. **Read Python implementation**
   - Note gas charge order (matters!)
   - Note state modifications
   - Note refund updates
   - Note error conditions

5. **Compare Zig implementation**
   - Opcodes: `src/frame.zig`
   - Calls/creates: `src/evm.zig`
   - Storage: `src/evm.zig`

6. **Fix minimally**
   - Match Python exactly
   - Keep gas calculation order identical
   - Preserve hardfork guards

7. **Verify**
   ```bash
   TEST_FILTER="exact_test_name" zig build specs
   ```

---

## Pro Tips

1. **Gas calculation order matters** - Match Python's exact sequence (e.g., SSTORE: stipend → cold access → value comparison → refunds)
2. **Original vs Current storage** - Track both for refund calculations
3. **Warm/cold is cumulative** - Once warm, stays warm for entire transaction
4. **Refund counter can go negative** - Gets capped at transaction end, don't clamp prematurely
5. **Static context propagates** - STATICCALL → all child calls inherit `is_static`
6. **Memory expansion is quadratic** - `size_in_words ** 2 // 512` (match Python exactly)
7. **Call depth limit is 1024** - Check before any CALL/CREATE

---

## Anti-Patterns

> **Things NOT to do:**

- ❌ Guess gas costs (must match Python exactly)
- ❌ Skip trace comparison (shows exact divergence point)
- ❌ Mix hardfork behaviors (use `isAtLeast` guards)
- ❌ Ignore error conditions (Python's `raise` must map to Zig errors)
- ❌ Hardcode test-specific logic (fix general implementation)
- ❌ Forget to charge gas before operations (Python charges first)
- ❌ Modify test files (only change `src/` implementations)
- ❌ **CRITICAL: Silently ignore errors with `catch {}`** - ALL errors MUST be handled and/or propagated properly. Never use `catch {}` to suppress errors (e.g., `slots_to_remove.append(allocator, key) catch {}` is forbidden). Either handle the error meaningfully or propagate it with `try`. The only exception is when the function signature explicitly cannot return errors (non-error-union return type), in which case the function design should be reconsidered.
- ❌ **NEVER create .backup files** - We use git for version control. Never create files with .backup, .bak, .old, or similar extensions. Use git branches/stashes instead.

---

## Essential Python Reference Files

**Cancun (latest tested hardfork):**
- `execution-specs/src/ethereum/forks/cancun/vm/interpreter.py` - Main loop
- `execution-specs/src/ethereum/forks/cancun/vm/gas.py` - Gas calculations
- `execution-specs/src/ethereum/forks/cancun/vm/instructions/storage.py` - SLOAD/SSTORE/TLOAD/TSTORE
- `execution-specs/src/ethereum/forks/cancun/vm/instructions/system.py` - CALL/CREATE/SELFDESTRUCT
- `execution-specs/src/ethereum/forks/cancun/vm/instructions/arithmetic.py` - ADD/MUL/EXP
- `execution-specs/src/ethereum/forks/cancun/vm/instructions/memory.py` - MLOAD/MSTORE/MCOPY
- `execution-specs/src/ethereum/forks/cancun/state.py` - State primitives

**For other hardforks:** Replace `cancun` with `shanghai`, `paris`, `london`, `berlin`, etc.

---

## 🤖 Automated Spec Fixer: 7-Checkpoint System

The `scripts/fix-specs.ts` pipeline enforces a **mandatory 7-checkpoint methodology** for systematic, evidence-based debugging.

### Checkpoints

Each checkpoint requires **actual data** (no placeholders):

1. **✅ Run Test and Confirm Failure** - Execute, capture output, identify failing tests
2. **✅ Generate Trace Comparison** - Use `bun scripts/isolate-test.ts`, identify divergence (PC, opcode, gas, stack)
3. **✅ Read Python Reference** - Navigate to `execution-specs/.../`, quote actual code (not summaries)
4. **✅ Compare Zig Implementation** - Read current code, quote actual Zig, identify discrepancies
5. **✅ Diagnose Root Cause and Propose Fix** - Based on checkpoints 2-4, propose specific fix
6. **✅ Implement Fix** - Make minimal changes, preserve hardfork compatibility
7. **✅ Verify Fix** - Re-run test, confirm pass (if failing, return to Checkpoint 2)

### Enforcement Rules

- ✅ ALL checkpoints MUST be explicitly confirmed with actual data
- ✅ NO placeholders: `[TODO]`, `[TBD]`, `[value]`
- ✅ Iteration required if tests fail
- ❌ DO NOT skip checkpoints
- ❌ DO NOT proceed to fixes without analysis (1-5)
- ❌ DO NOT use summaries instead of code quotes

### Usage

```bash
bun run scripts/fix-specs.ts               # Fix all suites
bun run scripts/fix-specs.ts suite <name>  # Fix specific suite

# Reports: reports/spec-fixes/
#   - pipeline-summary.md: Overall results
#   - pipeline-summary-ai.md: AI narrative summary
#   - {suite}-attempt{N}.md: Per-suite debugging reports
```

### Known Issues Database

**Location:** `scripts/known-issues.json`

Tracks historical debugging insights:
- Common failure patterns and root causes
- Relevant file locations (with line ranges)
- Python reference locations
- Key invariants
- Expected gas costs

**Schema:**
```json
{
  "test-suite-name": {
    "test_suite": "test-suite-name",
    "description": "Brief description",
    "common_causes": ["Cause 1", "Cause 2"],
    "relevant_files": ["src/file.zig:function", "src/other.zig:line-range"],
    "python_ref": "execution-specs/.../reference.py",
    "key_invariants": ["Invariant 1", "Invariant 2"],
    "gas_costs": { "OPERATION": 100 }
  }
}
```

---

## Resources

- **ethereum/tests**: https://github.com/ethereum/tests
- **execution-specs**: https://github.com/ethereum/execution-specs
- **EIP Index**: https://eips.ethereum.org/
- **EIP-3155 (Trace Format)**: https://eips.ethereum.org/EIPS/eip-3155
- **Yellow Paper**: https://ethereum.github.io/yellowpaper/paper.pdf
- **Zig Documentation**: https://ziglang.org/documentation/

---

## File Summary

<details>
<summary><b>Core Implementation Files</b></summary>

| File | Purpose | Key Exports |
|------|---------|-------------|
| `src/root.zig` | Main module | Evm, Frame, Host, Hardfork, Tracer |
| `src/evm.zig` | EVM orchestrator | Evm struct, call(), inner_call(), inner_create() |
| `src/frame.zig` | Bytecode interpreter | Frame struct, execute(), step() |
| `src/host.zig` | Host interface | HostInterface, CallResult, CallType |
| `src/hardfork.zig` | Hardfork logic | Hardfork enum, isAtLeast(), fromString() |
| `src/opcode.zig` | Opcode utilities | getOpName(), opcode constants |
| `src/trace.zig` | EIP-3155 tracing | Tracer, TraceEntry |
| `src/errors.zig` | Error types | CallError enum |
| `src/primitives/root.zig` | Primitives exports | All primitive types |
| `build.zig` | Build config | Build targets, dependencies |
| `test_runner.zig` | Test runner | Test execution, reporting |
| `test/specs/runner.zig` | Spec test execution | runJsonTest(), trace comparison |

</details>

---

## Contributing

When making changes:

1. Ensure all tests pass (`zig build test`)
2. Run spec tests for affected hardfork
3. Format code (`zig fmt src/ test/`)
4. Add tests for new features
5. Update documentation

**For questions:** Refer to test output and trace divergence analysis.

**License:** See LICENSE file.
