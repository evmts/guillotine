## Review: execution/arithmetic.zig (ADD/MUL/SUB/DIV/SDIV/MOD/SMOD/ADDMOD/MULMOD/EXP/SIGNEXTEND)

### Critical correctness issues

- Operand order is reversed in several handlers. EVM semantics are `a op b` with `a = second_from_top`, `b = top`. Current code often computes `top op second_from_top`.
  - Affected: `SUB`, `DIV`, `SDIV`, `MOD`, `SMOD`, `ADDMOD`, `MULMOD`, `EXP`.
  - Example: `SUB` should compute `a - b`, current code computes `b - a`.
  - Example: `EXP` base and exponent are swapped; dynamic gas uses wrong operand.

### High-signal findings

- Good use of unsafe stack ops (`pop_unsafe`/`set_top_unsafe`) and `U256` helpers; early exits in `EXP` look efficient once operands are corrected.
- `SIGNEXTEND` special-case for `b >= 31` is harmless but consider using `b >= 32` to match spec wording; behavior for `b == 31` is effectively identity either way.

### Required fixes (proposed)

- Binary ops: adopt a consistent pattern:
  - `const b = stack.pop_unsafe(); const a = stack.peek_unsafe().*; stack.set_top_unsafe(a op b);`
- `SUB`: `a -% b`.
- `DIV`: `b == 0 ? 0 : a / b` (no wrapping needed).
- `SDIV`: handle `a = MIN_I256, b = -1` by returning `MIN_I256`; otherwise `@divTrunc(a_i256, b_i256)`; map back to `u256`.
- `MOD`: `b == 0 ? 0 : a % b` (using `U256` div_rem okay, but with correct operands).
- `SMOD`: `b == 0 ? 0 : @rem(a_i256, b_i256)`.
- `ADDMOD`: `n == 0 ? 0 : add_mod(a, b, n)` with `a = third`, `b = second`, `n = top`.
- `MULMOD`: `n == 0 ? 0 : mul_mod(a, b, n)` with `a = third`, `b = second`, `n = top`.
- `EXP`: `base = second_from_top`, `exponent = top`; dynamic gas uses byte length of exponent; compute `base^exponent` (square-and-multiply ok).

Pseudocode pattern:

```
// Generic binary op pattern
const b = stack.pop_unsafe();
const a = stack.peek_unsafe().*;
const r = a OP b; // with op-specific guards
stack.set_top_unsafe(r);

// addmod/mulmod pattern
const n = stack.pop_unsafe();
const b = stack.pop_unsafe();
const a = stack.peek_unsafe().*;
stack.set_top_unsafe(n == 0 ? 0 : op_mod(a, b, n));

// exp pattern
const exponent = stack.pop_unsafe();
const base = stack.peek_unsafe().*;
charge_gas_per_exponent_byte(exponent);
stack.set_top_unsafe(pow(base, exponent));
```

### Tests to add/adjust

- Deterministic unit tests for operand order across all ops (small integers that make order visible: e.g., `5 - 3 = 2` vs `3 - 5 = 2^256-2`).
- `ADDMOD`/`MULMOD` with simple values to confirm `(a,b,n)` mapping: e.g., `a=5,b=10,n=7 -> addmod=1`.
- `EXP` gas accounting: exponents at 0, 255, 256 boundaries; validate byte counting and result for swapped operands.
- SDIV/SMOD corner cases including `MIN_I256/-1`, sign behavior.

### Opportunities

1) Micro-fusion paths - ✅ COMPLETED
- Fuse short sequences (e.g., `PUSH/PUSH/ADD`) during decode/analysis to reduce dispatch overhead in arithmetic-heavy traces.
- **IMPLEMENTED in synthetic.zig**: PUSH+ADD, PUSH+SUB, PUSH+MUL, PUSH+DIV fusions
- **IMPLEMENTED in synthetic.zig**: PUSH+PUSH+arithmetic precomputation
- **IMPLEMENTED in synthetic.zig**: Identity eliminations (PUSH 0 + ADD, PUSH 1 + MUL, etc.)

2) U256 helpers
- Ensure `wrapping_mul`, `add_mod`, `mul_mod` inline well. If needed, add minimal helpers that return `u256` directly without intermediate structs.

### Action items

- [ ] Fix operand order in listed handlers and re-enable/extend unit tests.
- [ ] Add targeted tests for `ADDMOD/MULMOD/EXP` operand mapping and `EXP` gas bytes.
- [x] Consider micro-fusion in analysis for arithmetic sequences. (COMPLETED in synthetic.zig)

### Comparison to evmone/revm

- Correctness parity requires operand order fixes. After that, fusion/inlining are the main perf levers to close remaining gaps.

