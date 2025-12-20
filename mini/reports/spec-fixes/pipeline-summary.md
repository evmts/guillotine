# Guillotine Spec Fixer Pipeline - Summary Report

**Generated**: 2025-10-17T17:10:17.257Z

## Overview

- **Total Test Suites**: 67
- **Passed**: 66
- **Failed**: 1
- **Total Agent Attempts**: 2
- **Total Cost**: $7.1646
- **Total Duration**: 58.6 minutes

## Test Suite Results

### ✅ Passed (66)

- paris
- homestead
- shanghai-withdrawals
- shanghai-push0
- cancun-tstore-basic
- cancun-tstore-reentrancy
- cancun-tstore-contexts-execution
- cancun-tstore-contexts-tload-reentrancy
- cancun-tstore-contexts-reentrancy
- cancun-tstore-contexts-create
- cancun-tstore-contexts-selfdestruct
- cancun-tstore-contexts-clear
- cancun-mcopy
- cancun-blobbasefee
- cancun-blob-precompile-basic
- cancun-blob-precompile-gas
- cancun-blob-opcodes-basic
- cancun-blob-opcodes-contexts
- cancun-blob-tx-small
- cancun-blob-tx-subtraction
- cancun-blob-tx-insufficient
- cancun-blob-tx-sufficient
- cancun-blob-tx-valid-combos
- prague-calldata-cost-type0
- prague-calldata-cost-type1-2
- prague-calldata-cost-type3
- prague-calldata-cost-type4
- prague-calldata-cost-refunds
- prague-bls-g1
- prague-bls-g2
- prague-bls-pairing
- prague-bls-map
- prague-bls-misc
- prague-setcode-calls
- prague-setcode-gas
- prague-setcode-txs
- prague-setcode-advanced
- osaka-modexp-variable-gas
- osaka-modexp-vectors-eip
- osaka-modexp-vectors-legacy
- osaka-modexp-misc
- osaka-other
- shanghai-warmcoinbase
- shanghai-initcode-basic
- shanghai-initcode-eof
- byzantium-modexp
- berlin-acl
- berlin-intrinsic-gas-cost
- berlin-intrinsic-type0
- berlin-intrinsic-type1
- frontier-precompiles
- frontier-identity
- frontier-create
- frontier-call
- frontier-calldata
- frontier-dup
- frontier-push
- frontier-stack
- frontier-opcodes
- constantinople-bitshift
- constantinople-create2
- istanbul-blake2
- istanbul-chainid
- cancun-selfdestruct-collision
- cancun-selfdestruct-reentrancy
- cancun-selfdestruct-revert

### ❌ Failed (1)

- cancun-selfdestruct-basic

## Agent Fix Attempts

| Suite | Attempt | Success | Cost | Turns | Duration |
|-------|---------|---------|------|-------|----------|
| cancun-selfdestruct-basic | 1 | ✅ | $3.4962 | 400 | 1225.6s |
| cancun-selfdestruct-basic | 2 | ✅ | $3.6684 | 323 | 1194.1s |

## Next Steps

1. Review failed test suites and agent reports
2. Manually investigate remaining failures
3. Consider increasing maxTurns or maxAttempts for complex fixes
