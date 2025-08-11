## Review: execution/comparison.zig (LT/GT/SLT/SGT/EQ/ISZERO)

### Critical correctness issues

- Operand order is reversed in `LT/GT/SLT/SGT`. EVM requires `a ? b` with `a = second_from_top`, `b = top`; handlers currently compare `top ? second_from_top`.

### High-signal findings (after fix)

- Stack handling is lean (pop then set_top). Signed ops correctly bitcast to `i256`.
- `EQ` and `ISZERO` use correct operands.

### Required fixes (proposed)

- Use uniform extraction: `const b = stack.pop_unsafe(); const a = stack.peek_unsafe().*;` then compare `a` vs `b`.

Pseudocode:
```
// LT
const b = stack.pop_unsafe();
const a = stack.peek_unsafe().*;
stack.set_top_unsafe(@intFromBool(a < b));

// SLT
const bi = @as(i256, @bitCast(b));
const ai = @as(i256, @bitCast(a));
stack.set_top_unsafe(@intFromBool(ai < bi));
```

### Tests to add/adjust

- Visible-order checks: `(5 < 10)=1`, `(10 < 5)=0`, `(5 > 10)=0`, `(10 > 5)=1`.
- Signed boundaries: `(-1 < 0)=1`, `(-2^255 < 0)=1`, `(0 < -2^255)=0`.

### Opportunities

- Consider inlining `ISZERO` (and possibly `EQ`) in hot-op set.
- Add property tests comparing unsigned vs signed near boundaries.
- ✅ Pattern fusion: DUP1 + PUSH 0 + EQ → ISZERO (IMPLEMENTED in synthetic.zig)

### Action items

- [ ] Correct operand order in `LT/GT/SLT/SGT` and update tests.
- [ ] Evaluate inlining for `ISZERO` and `EQ` with profiling.
- [x] Add DUP1 + PUSH 0 + EQ → ISZERO fusion (COMPLETED in synthetic.zig)

### Comparison to evmone/revm

- After fixing operand order, parity expected; minor wins via inlining and reducing stack traffic.

