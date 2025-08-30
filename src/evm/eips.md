# EVM EIPs Implementation Status

This document tracks all EVM-related EIPs and their implementation status in the Guillotine EVM.

## Legend
- ✅ Fully implemented
- ⚠️ Partially implemented
- ❌ Not implemented
- 🚧 TODO - Needs implementation

## Hardfork: Frontier (July 2015)
| EIP | Title | Status | Location | Notes |
|-----|-------|--------|----------|-------|
| - | Initial EVM | ✅ | frame.zig, opcodes | Base opcodes and gas model |

## Hardfork: Homestead (March 2016)
| EIP | Title | Status | Location | Notes |
|-----|-------|--------|----------|-------|
| EIP-2 | Homestead Hard-fork Changes | ✅ | eips.zig:123-124 | Active EIPs list |
| EIP-7 | DELEGATECALL | ✅ | handlers_system.zig | Opcode 0xf4 implemented |
| EIP-8 | Devp2p Forward Compatibility | N/A | - | Not EVM related |

## Hardfork: Tangerine Whistle (October 2016)
| EIP | Title | Status | Location | Notes |
|-----|-------|--------|----------|-------|
| EIP-150 | Gas cost changes for IO-heavy operations | ⚠️ | opcode_data.zig | Gas costs partially updated |

## Hardfork: Spurious Dragon (November 2016)
| EIP | Title | Status | Location | Notes |
|-----|-------|--------|----------|-------|
| EIP-155 | Simple replay attack protection | N/A | - | Transaction signing, not EVM |
| EIP-160 | EXP cost increase | 🚧 TODO | opcode_data.zig:37 | Needs dynamic gas calculation |
| EIP-161 | State trie clearing | ⚠️ | eips.zig:125 | Listed but not fully implemented |
| EIP-170 | Contract code size limit | ✅ | bytecode.zig, evm.zig:908-909 | 24KB limit enforced |

## Hardfork: Byzantium (October 2017)
| EIP | Title | Status | Location | Notes |
|-----|-------|--------|----------|-------|
| EIP-100 | Change difficulty adjustment | N/A | - | Consensus, not EVM |
| EIP-140 | REVERT instruction | ✅ | frame.zig | Opcode 0xfd implemented |
| EIP-196 | Precompiled contracts for elliptic curve | ⚠️ | precompiles.zig | Partial implementation |
| EIP-197 | Precompiled contracts for elliptic curve pairing | ⚠️ | precompiles.zig | Partial implementation |
| EIP-198 | Big integer modular exponentiation | ⚠️ | precompiles.zig | Partial implementation |
| EIP-211 | RETURNDATASIZE, RETURNDATACOPY | ✅ | frame.zig | Opcodes 0x3d, 0x3e |
| EIP-214 | STATICCALL | ✅ | handlers_system.zig:655, evm.zig:829 | Opcode 0xfa with static context |
| EIP-649 | Metropolis Difficulty Bomb Delay | N/A | - | Consensus, not EVM |
| EIP-658 | Embedding transaction status | N/A | - | Receipt format, not EVM |

## Hardfork: Constantinople/Petersburg (February 2019)
| EIP | Title | Status | Location | Notes |
|-----|-------|--------|----------|-------|
| EIP-145 | Bitwise shifting instructions | ✅ | frame.zig | SHL, SHR, SAR opcodes |
| EIP-1014 | Skinny CREATE2 | ✅ | handlers_system.zig:473 | Opcode 0xf5 |
| EIP-1052 | EXTCODEHASH | ✅ | frame.zig | Opcode 0x3f |
| EIP-1283 | Net gas metering for SSTORE | ❌ | - | Removed in Petersburg |

## Hardfork: Istanbul (December 2019)
| EIP | Title | Status | Location | Notes |
|-----|-------|--------|----------|-------|
| EIP-152 | Blake2 precompile | 🚧 TODO | precompiles.zig | Not implemented |
| EIP-1108 | Reduce alt_bn128 gas costs | ⚠️ | eips.zig:129 | Listed but needs implementation |
| EIP-1344 | CHAINID opcode | ✅ | frame.zig | Opcode 0x46 |
| EIP-1884 | Repricing for trie-size-dependent opcodes | ⚠️ | opcode_data.zig | SELFBALANCE added, gas costs need update |
| EIP-2028 | Transaction data gas cost reduction | 🚧 TODO | - | Needs implementation |
| EIP-2200 | Structured Definitions for Net Gas Metering | 🚧 TODO | - | SSTORE gas calculation |

## Hardfork: Berlin (April 2021)
| EIP | Title | Status | Location | Notes |
|-----|-------|--------|----------|-------|
| EIP-2565 | ModExp Gas Cost | 🚧 TODO | precompiles.zig | Needs implementation |
| EIP-2718 | Typed Transaction Envelope | N/A | - | Transaction format |
| EIP-2929 | Gas cost increases for state access opcodes | ✅ | eips.zig:35-64, access_list.zig, evm.zig:1110-1115 | Cold/warm access implemented |
| EIP-2930 | Optional access lists | ✅ | access_list.zig, eips.zig:13-16 | Pre-warming implemented |

## Hardfork: London (August 2021)
| EIP | Title | Status | Location | Notes |
|-----|-------|--------|----------|-------|
| EIP-1559 | Fee market change | ⚠️ | eips.zig:66-70, context.zig:30 | Base fee tracked but not fully integrated |
| EIP-3198 | BASEFEE opcode | ⚠️ | eips.zig:72-76, opcode_data.zig:86 | Opcode 0x48 listed but needs handler |
| EIP-3529 | Reduction in refunds | ✅ | eips.zig:23-31, evm.zig:325-329 | Gas refund cap implemented |
| EIP-3541 | Reject new contracts with 0xEF byte | ⚠️ | evm.zig:108,119,128,137,146,155 | Flag exists but validation needed |

## Hardfork: Merge/Paris (September 2022)
| EIP | Title | Status | Location | Notes |
|-----|-------|--------|----------|-------|
| EIP-3675 | Upgrade consensus to PoS | N/A | - | Consensus change |
| EIP-4399 | DIFFICULTY → PREVRANDAO | ⚠️ | eips.zig:135 | Listed but needs implementation |

## Hardfork: Shanghai/Capella (April 2023)
| EIP | Title | Status | Location | Notes |
|-----|-------|--------|----------|-------|
| EIP-3651 | Warm COINBASE | ✅ | eips.zig:13-16, access_list.zig | Pre-warming coinbase address |
| EIP-3855 | PUSH0 instruction | ⚠️ | eips.zig:96-100, evm.zig:109,120,129,138,147,156 | Flag exists, opcode needs implementation |
| EIP-3860 | Limit and meter initcode | ⚠️ | eips.zig:102-117, evm.zig:908-909 | Size limit enforced, gas metering partial |
| EIP-4895 | Beacon chain push withdrawals | N/A | - | Consensus layer |

## Hardfork: Cancun/Deneb (March 2024)
| EIP | Title | Status | Location | Notes |
|-----|-------|--------|----------|-------|
| EIP-1153 | Transient storage opcodes | ⚠️ | eips.zig:78-82, database.zig:167-173 | Interface exists, needs implementation |
| EIP-4788 | Beacon block root in EVM | 🚧 TODO | - | Not implemented |
| EIP-4844 | Shard Blob Transactions | ⚠️ | eips.zig:84-88, transaction_context.zig:18-21, evm.zig:1235-1245 | Partial - blob hash/fee tracking |
| EIP-5656 | MCOPY - Memory copying instruction | ⚠️ | eips.zig:137, evm.zig:112,123,132,141,150,159 | Flag exists, opcode needs implementation |
| EIP-6780 | SELFDESTRUCT only in same transaction | ⚠️ | eips.zig:90-94, created_contracts.zig, handlers_system.zig:677 | Partial - tracking but not enforcing |
| EIP-7516 | BLOBBASEFEE opcode | ⚠️ | opcode_data.zig:88, evm.zig:1245 | Interface exists, needs handler |

## Hardfork: Prague/Electra (Expected 2025) - NOT IMPLEMENTED
| EIP | Title | Status | Location | Notes |
|-----|-------|--------|----------|-------|
| EIP-2537 | BLS12-381 precompiles | ❌ | - | TODO: Add BLS curve operations |
| EIP-3074 | AUTH and AUTHCALL opcodes | ❌ | - | TODO: Account abstraction opcodes |
| EIP-7002 | Execution layer triggerable exits | ❌ | - | TODO: Validator exit operations |
| EIP-7251 | Increase MAX_EFFECTIVE_BALANCE | N/A | - | Consensus layer |
| EIP-7702 | Set EOA account code for one transaction | ❌ | - | TODO: Major feature - EOA code execution |

## EVM Object Format (EOF) - NOT IMPLEMENTED
| EIP | Title | Status | Location | Notes |
|-----|-------|--------|----------|-------|
| EIP-3540 | EOF - EVM Object Format v1 | ❌ | - | TODO: New bytecode format |
| EIP-3670 | EOF - Code Validation | ❌ | - | TODO: Bytecode validation |
| EIP-4200 | EOF - Static relative jumps | ❌ | - | TODO: New jump opcodes |
| EIP-4750 | EOF - Functions | ❌ | - | TODO: Function abstraction |
| EIP-5450 | EOF - Stack Validation | ❌ | - | TODO: Stack depth validation |

## Summary

### Implementation Status
- ✅ Fully implemented: 15 EIPs
- ⚠️ Partially implemented: 22 EIPs
- ❌ Not implemented: 8 EIPs
- 🚧 TODO: 6 EIPs
- N/A (not EVM): 10 EIPs

### Critical Missing Features
1. **EIP-7702** (Prague) - EOA code execution for account abstraction
2. **EOF Suite** (EIP-3540, 3670, 4200, 4750, 5450) - Major bytecode format upgrade
3. **EIP-2537** (Prague) - BLS12-381 precompiles for cryptography
4. **Complete EIP-1153** - Transient storage TLOAD/TSTORE implementation
5. **Complete EIP-5656** - MCOPY opcode implementation
6. **Complete EIP-3855** - PUSH0 opcode implementation

### Partially Implemented (Needs Completion)
1. **Gas cost updates** for various hardforks (EIP-150, 160, 1884, 2028, 2200, 2565)
2. **Precompiles** (EIP-196, 197, 198, 152, 2537)
3. **BASEFEE opcode** handler (EIP-3198)
4. **0xEF bytecode validation** (EIP-3541)
5. **EIP-6780 enforcement** for SELFDESTRUCT restrictions

### Next Steps
1. Implement missing opcodes (PUSH0, MCOPY, BASEFEE)
2. Complete transient storage implementation
3. Update gas costs to match latest hardfork specifications
4. Implement Prague hardfork features (EIP-7702, EIP-2537)
5. Consider EOF implementation for future compatibility
6. Consolidate all EIP-specific behavior into eips.zig as a compile-time configuration