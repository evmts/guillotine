## Review: config/test_configs.zig (prebaked test configs)

### High-signal findings

- Provides convenient, compile-time configs for specific test scenarios (EIP-1559, CREATE2, transient storage, blob tx). Includes tests verifying EIP flags are set as expected.

### Opportunities

- Add a config emphasizing performance (ReleaseFast assumptions) for microbench and perf sanity tests.
- Consider a config that disables access list gas costs to validate legacy paths easily.


