## Review: execution/environment.zig (ADDRESS/BALANCE/ORIGIN/CALLER/CALLVALUE/...)

### High-signal findings

- Reads from frame/VM context and host as expected; warm/cold charges (e.g., BALANCE) should follow EIP‑2929 via access list.

### Opportunities

- Ensure BALANCE/EXT* ops apply warm/cold costs via the access list consistently and are tested for both states.
- Consider prewarming self where spec allows to reduce costs on common paths.

### Action items

- [ ] Add warm/cold coverage for BALANCE/EXTCODESIZE/EXTCODEHASH.
- [ ] Audit for consistent access_list usage across env ops.

### Comparison to evmone/revm

- Parity expected; just ensure warm/cold behavior is precise and covered.


