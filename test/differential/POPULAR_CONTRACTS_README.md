# Popular Contracts Differential Testing

This directory contains differential tests for real-world popular Ethereum contracts. These tests compare Guillotine EVM execution against revm to identify differences and bugs.

## Test Structure

### Fixtures (`src/evm/fixtures/`)

Each contract has its own fixture directory containing:
- `bytecode.txt` - The runtime bytecode of the deployed contract (hex-encoded)
- `address.txt` - The mainnet address of the contract

### Contracts Tested

1. **WETH (Wrapped Ether)** - `weth-mainnet/`
   - Address: `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
   - Tests: Deployment, deposit (fallback), balanceOf

2. **USDC Proxy** - `usdc-proxy/`
   - Address: `0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48`
   - Tests: Deployment, implementation() call

3. **Uniswap V2 Router** - `uniswap-v2-router/`
   - Address: `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D`
   - Tests: Deployment, factory() call

4. **Uniswap V3 Pool (ETH/USDC)** - `uniswap-v3-pool-eth-usdc/`
   - Address: `0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8`
   - Tests: Deployment, token0() call

5. **Compound cUSDC** - `compound-cusdc/`
   - Address: `0x39AA39c021dfbaE8faC545936693aC917d5E7563`
   - Tests: Deployment, totalSupply() call

## Running Tests

### Individual Contract Tests
```bash
# Test specific contracts
zig build test --summary all -- --test-filter "WETH contract differential test"
zig build test --summary all -- --test-filter "USDC proxy differential test"
zig build test --summary all -- --test-filter "Uniswap V2 Router differential test"
zig build test --summary all -- --test-filter "Uniswap V3 Pool differential test"
zig build test --summary all -- --test-filter "Compound cUSDC differential test"
```

### Full Test Suite
```bash
# Run all popular contract tests
zig build test --summary all -- --test-filter "Popular contracts differential testing"
```

### All Differential Tests
```bash
# Run all differential tests including popular contracts
zig build test --summary all test/differential/
```

## Expected Results

**During Development Phase**: Most tests are expected to fail as Guillotine EVM is still under development. The tests will:

1. **Log warnings** for failed comparisons (expected during development)
2. **Show gas differences** between revm and Guillotine
3. **Identify execution divergence points** for debugging
4. **Provide detailed trace comparisons** when mismatches occur

## Test Benefits

### For Development
- **Bug Detection**: Finds EVM implementation bugs early
- **Performance Comparison**: Gas usage comparison with revm
- **Correctness Validation**: Ensures spec compliance
- **Regression Prevention**: Catches regressions during development

### For Confidence
- **Real-World Coverage**: Tests against actual mainnet contracts
- **Complex Scenarios**: Covers edge cases not in simple unit tests
- **Integration Testing**: Tests full EVM stack together
- **Production Readiness**: Validates against battle-tested contracts

## Contract Selection Rationale

These contracts were chosen for their:

1. **High Usage**: Most popular contracts on Ethereum mainnet
2. **Diverse Complexity**: Range from simple (WETH) to complex (Uniswap V3)
3. **Different Patterns**: Covers proxies, AMMs, lending protocols
4. **Opcode Coverage**: Exercises different EVM opcodes and features
5. **Gas Optimization**: Real contracts optimized for gas efficiency

## Debugging Failed Tests

When tests fail (expected during development):

1. **Check Gas Differences**: Large gas differences may indicate missing opcodes
2. **Review Execution Traces**: Compare step-by-step execution
3. **Validate Bytecode**: Ensure fixtures contain correct bytecode
4. **State Requirements**: Some contracts may need pre-initialized state
5. **External Dependencies**: Contracts may require other deployed contracts

## Future Enhancements

- **State Initialization**: Pre-deploy dependent contracts
- **Multi-transaction Tests**: Test contract interactions
- **Storage State Comparison**: Compare final storage state
- **Event Log Comparison**: Validate emitted events
- **Error Handling Tests**: Test revert scenarios
- **Fork Testing**: Test against historical blockchain state

## Maintenance

To update contract bytecode:
1. Use `cast code <address> --rpc-url <rpc-url>` to fetch latest bytecode
2. Update corresponding `bytecode.txt` file in fixtures
3. Verify tests still pass with updated bytecode
4. Update this documentation if contract addresses change

## Contributing

When adding new popular contracts:

1. Create fixture directory: `src/evm/fixtures/<contract-name>/`
2. Add `bytecode.txt` and `address.txt` files
3. Implement test functions in `popular_contracts_test.zig`
4. Add test to the full test suite
5. Update this documentation
6. Ensure tests follow existing patterns and error handling