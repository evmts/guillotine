# CLAUDE.md - Opcodes Module

## MISSION CRITICAL: EVM Specification Compliance
**ANY deviation from Ethereum Yellow Paper = consensus failures and fund loss.**

## Core Files
- `opcode.zig` - Canonical EVM opcodes (0x00-0xFF), MUST match Yellow Paper exactly
- `opcode_data.zig` - Static metadata for all 256 opcodes, gas costs, stack I/O
- `opcode_synthetic.zig` - Fusion opcodes for performance, preserve EVM semantics

## Opcode Categories - ZERO TOLERANCE

**Arithmetic (0x00-0x0F)**: ALL overflow wraps, div/mod by zero returns 0, signed = two's complement
**Gas**: ADD/SUB (3), MUL/DIV (5), ADDMOD/MULMOD (8), EXP (dynamic)

**Comparison (0x10-0x1F)**: Return 0/1, 256-bit operations, out-of-range shifts return 0

**Crypto (0x20-0x2F)**: KECCAK256 (NOT SHA-3), memory expansion costs

**Environment (0x30-0x3F)**: Context-sensitive, BALANCE (2600+ gas), external access can fail

**Block (0x40-0x4F)**: Hash (last 256 blocks only), timestamp (block not current time)

**Stack (0x50-0x5F, 0x80-0x8F, 0x90-0x9F)**: 1024 max, underflow/overflow fails, PUSH immediates, DUP/SWAP indices 1-16

**Memory (0x51-0x53)**: Quadratic expansion costs, 32-byte words, MSTORE8 single bytes

**Storage (0x54-0x55)**: Cold (2100), warm (100), EIP-2929/2200 gas, refund mechanisms

**Control (0x56-0x5B)**: JUMPDEST only valid targets, validate before jump, PC tracking

**Logs (0xA0-0xA4)**: 0-4 topics, memory expansion, preserve order

**System (0xF0-0xFF)**: CREATE/CALL/DELEGATECALL/SELFDESTRUCT - extreme caution

## Synthetic Opcodes
**Fusions**: PUSH+arithmetic, PUSH+memory, ISZERO+JUMPI
**Requirements**: Identical semantics, stack effects, gas costs, no observable differences
**Static Jumps**: Pre-computed destinations, eliminate binary search

## Gas Costs
- **Static**: Base costs in `opcode_data.zig`, match EIPs exactly
- **Dynamic**: Memory expansion, storage access (cold/warm), calls, EXP

## Critical Properties
- **Consensus**: Exact specification compliance, deterministic execution
- **DoS Prevention**: Gas limits, stack/memory bounds, call depth (1024)
- **Performance**: O(1) dispatch, cache-friendly layout, fusion optimization

## Testing
- **Unit**: All 256 opcodes, edge cases, gas calculations, error conditions
- **Integration**: Complete sequences, real transactions, cross-opcode interactions
- **Differential**: Compare with revm/geth, official Ethereum tests

## Emergency Procedures
1. **Bug Discovery**: Assess fund impact, verify other implementations, minimal fix
2. **Performance Regression**: Profile, benchmark, optimize while maintaining correctness

**EVM specification is sacred law. Specification compliance over performance always.**