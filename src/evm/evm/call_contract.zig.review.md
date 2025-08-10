## Review: evm/call_contract.zig (internal call execution)

### High-signal findings

- Handles value transfer, code fetch, frame setup, and execution; integrates with journal and created contracts.

### Opportunities

- Validate value transfer and stipend handling with exhaustive tests; ensure revert unwinds both storage and balance changes.


