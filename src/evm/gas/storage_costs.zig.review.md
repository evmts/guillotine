## Review: gas/storage_costs.zig (storage gas & refunds)

### High-signal findings

- Central place for SLOAD/SSTORE costs and refunds across forks.

### Opportunities

- Implement full EIP-2200/3529 transition matrix and expose helpers used by storage handlers; unit tests for each transition.


