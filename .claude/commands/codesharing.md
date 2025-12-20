# EVM Code Sharing Refactor

Systematic refactoring to eliminate code duplication between Guillotine's EVM implementations while maintaining zero-cost abstractions for Performance EVM and trace reliability for Mini EVM.

---

## Pre-flight Checks

<preflight>
Before ANY work, validate baseline:

1. **Build check**: `zig build` must succeed
2. **Test check**: `zig build test-unit && zig build test-opcodes` must pass
3. **Mini build**: `cd mini && zig build` must succeed
4. **Mini tests**: `cd mini && zig build test` must pass

If ANY check fails:
- Create `docs/reports/codesharing-blocked-YYYY-MM-DD.md` documenting failures
- Output: "BLOCKED: [failure description]. Fix build/tests before codesharing refactor."
- ABORT immediately
</preflight>

---

## Architecture Context

<architecture>
### Three EVM Codebases (Currently)

| Component | Location | Purpose | Lines |
|-----------|----------|---------|-------|
| **Performance EVM** | `src/frame/`, `src/instructions/` | Dispatch-based, tail-calls, max performance | ~20K |
| **Mini EVM** | `mini/src/` | PC-based, modular handlers, spec-compliant reference | ~8K |
| **Stale Tracer Copy** | `src/tracer/minimal_frame.zig` | DUPLICATE - should import mini/ | ~2.4K |

### Shared Infrastructure (Voltaire)

| Component | Location | Status |
|-----------|----------|--------|
| Primitives | `lib/voltaire/src/primitives/` | Shared (Address, Opcode, GasConstants) |
| Crypto | `lib/voltaire/src/crypto/` | Shared |
| Precompiles | `lib/voltaire/src/precompiles/` | Shared |

### Key Duplication Found

1. **Stale tracer copy** (`src/tracer/minimal_frame.zig`): 2,447 lines duplicating `mini/src/`
2. **Opcode enum**: `src/opcodes/opcode.zig` duplicates `lib/voltaire/src/primitives/opcode.zig`
3. **`next_instruction()`**: Identical 5-line function in 11 handler files
4. **Address conversions**: `to_u256()`/`from_u256()` in handlers_context.zig AND handlers_system.zig
5. **Opcode logic**: Arithmetic/bitwise/comparison logic duplicated between Performance EVM and Mini EVM
</architecture>

---

## Phased Implementation Plan

<phases>
### Phase 0: Fast Test Suite (PREREQUISITE)

**Goal**: Create fast validation suite before any refactoring.

<tasks phase="0">
1. Create `test/fast/` directory with subset of critical tests
2. Add `zig build test-fast` target (~30 seconds max)
3. Include:
   - All arithmetic opcodes (ADD, SUB, MUL, DIV, SDIV, MOD, EXP)
   - All comparison opcodes (LT, GT, EQ, SLT, SGT)
   - Stack operations (PUSH, POP, DUP, SWAP)
   - Memory operations (MLOAD, MSTORE)
   - Control flow (JUMP, JUMPI)
   - Basic CALL/CREATE
4. Mirror tests for both `src/` (Performance) and `mini/` (Mini)
5. Document in `docs/dev/TESTING.md`
</tasks>

**Validation**: `zig build test-fast` passes for both EVMs.

---

### Phase 1: Eliminate Stale Tracer Copy

**Goal**: Make tracer use `mini/` instead of duplicate `minimal_frame.zig`.

<tasks phase="1">
1. **Analyze compatibility**:
   - Compare `src/tracer/minimal_frame.zig` vs `mini/src/frame.zig`
   - Identify any tracer-specific additions
   - Document differences in checklist

2. **Update imports** (3 files):
   - `src/tracer/minimal_evm.zig`: Change `@import("minimal_frame.zig")` to mini
   - `src/tracer/tracer.zig`: Same
   - `src/tracer/tracer_config.zig`: Same

3. **Handle mini as dependency**:
   - Update `build.zig` to expose mini as module
   - Or use relative imports if in same repo

4. **Delete stale file**: Remove `src/tracer/minimal_frame.zig` (~2,400 lines)

5. **Validate**:
   - `zig build test-fast`
   - `zig build test-opcodes` (differential tests use tracer)
</tasks>

**Success metric**: Tracer works, ~2,400 lines deleted.

---

### Phase 2: Consolidate Opcode Enum

**Goal**: Single source of truth for opcode definitions.

<tasks phase="2">
1. **Audit differences**:
   - `src/opcodes/opcode.zig` vs `lib/voltaire/src/primitives/opcode.zig`
   - Document any unique functionality in either

2. **Merge into Voltaire**:
   - Add any missing utilities to voltaire's opcode.zig
   - Ensure synthetic opcodes handled

3. **Update src/opcodes/**:
   - Replace with re-export: `pub usingnamespace @import("voltaire").primitives.opcode;`
   - Or delete and update all imports

4. **Update all imports across codebase**

5. **Validate**: `zig build test-fast`
</tasks>

**Success metric**: Single opcode enum, all tests pass.

---

### Phase 3: Extract Common Helpers

**Goal**: Deduplicate small utilities without architectural changes.

<tasks phase="3">
1. **Extract `next_instruction()`**:
   - Create `src/instructions/dispatch_next.zig`
   - Single implementation, import in all 11 handler files
   - ~55 lines consolidated

2. **Extract address conversions**:
   - Create `src/primitives/address_word.zig` (or add to voltaire)
   - `to_u256(Address)` and `from_u256(u256)`
   - Update handlers_context.zig and handlers_system.zig

3. **Validate**: `zig build test-fast && zig build test-opcodes`
</tasks>

**Success metric**: No duplicate utility functions in handlers.

---

### Phase 4: Shared Opcode Logic Layer (OPTIONAL - Higher Risk)

**Goal**: Extract pure opcode logic usable by both EVMs.

<tasks phase="4">
1. **Create `lib/voltaire/src/evm_ops/`**:
   - `arithmetic.zig`: Pure ADD, SUB, MUL, DIV, EXP logic
   - `bitwise.zig`: AND, OR, XOR, SHL, SHR, SAR
   - `comparison.zig`: LT, GT, EQ, SLT, SGT

2. **Design constraint**: Functions take values, return values (no stack/gas/pc):
   ```zig
   pub inline fn add(a: u256, b: u256) u256 { return a +% b; }
   pub inline fn sdiv(a: u256, b: u256) u256 { /* signed div */ }
   ```

3. **Update both EVMs to use shared ops**

4. **Extensive validation**: Full test suite for both EVMs
</tasks>

**Success metric**: Shared logic, both EVMs pass all tests.
</phases>

---

## Validation Protocol

<validation>
After EACH phase:

1. **Build**: `zig build` (Performance EVM)
2. **Fast tests**: `zig build test-fast`
3. **Opcode tests**: `zig build test-opcodes`
4. **Mini build**: `cd mini && zig build`
5. **Mini tests**: `cd mini && zig build test`

If ANY fails: STOP, diagnose, fix before continuing.

Before final commit:
1. **Full unit tests**: `zig build test-unit`
2. **Integration tests**: `zig build test-integration`
3. **(Optional) Spec subset**: `zig build specs -Dtest-filter='vmArithmetic'`
</validation>

---

## Progress Tracking

<checklist>
Maintain in-memory checklist. Update after each task:

```
## Codesharing Refactor Progress

### Phase 0: Fast Test Suite
- [ ] Create test/fast/ directory
- [ ] Add zig build test-fast target
- [ ] Add arithmetic opcode tests
- [ ] Add comparison opcode tests
- [ ] Add stack operation tests
- [ ] Add memory operation tests
- [ ] Add control flow tests
- [ ] Mirror tests for mini/
- [ ] Update docs/dev/TESTING.md
- [ ] Validation: test-fast passes

### Phase 1: Eliminate Stale Tracer
- [ ] Analyze minimal_frame.zig vs mini/src/frame.zig
- [ ] Document differences
- [ ] Update build.zig for mini module
- [ ] Update src/tracer/minimal_evm.zig import
- [ ] Update src/tracer/tracer.zig import
- [ ] Update src/tracer/tracer_config.zig import
- [ ] Delete src/tracer/minimal_frame.zig
- [ ] Validation: all tests pass

### Phase 2: Consolidate Opcode Enum
- [ ] Audit opcode.zig differences
- [ ] Merge utilities into voltaire
- [ ] Update src/opcodes/ to re-export
- [ ] Update all imports
- [ ] Validation: all tests pass

### Phase 3: Extract Common Helpers
- [ ] Create dispatch_next.zig
- [ ] Update 11 handler files
- [ ] Create address_word.zig
- [ ] Update handlers_context.zig
- [ ] Update handlers_system.zig
- [ ] Validation: all tests pass

### Phase 4: Shared Opcode Logic (Optional)
- [ ] Create lib/voltaire/src/evm_ops/
- [ ] Implement arithmetic.zig
- [ ] Implement bitwise.zig
- [ ] Implement comparison.zig
- [ ] Update Performance EVM handlers
- [ ] Update Mini EVM handlers
- [ ] Validation: full test suite
```
</checklist>

---

## Documentation Updates

<documentation>
After completion, update:

1. **`docs/dev/ARCHITECTURE.md`**: Update component diagram, remove stale tracer reference
2. **`docs/dev/TESTING.md`**: Document test-fast target
3. **`docs/README.md`**: Update if structure changed
4. **`CLAUDE.md`**: Update module references if paths changed

Create report:
- **`docs/reports/codesharing-refactor-YYYY-MM-DD.md`**:
  - Lines deleted/consolidated
  - Files changed
  - Test results before/after
  - Any issues encountered
</documentation>

---

## Constraints

<constraints>
### Performance EVM Requirements (MUST preserve)
- Tail-call dispatch pattern
- `@call(.always_tail, ...)` optimization
- Unsafe stack operations (pre-validated)
- Gas batching per basic block
- Zero-cost abstractions only

### Mini EVM Requirements (MUST preserve)
- PC-based execution (traditional interpreter)
- Explicit error handling with `try`
- Per-operation gas consumption
- Trace generation capability
- Spec compliance

### Voltaire Requirements
- Remains pure primitives library
- No execution-specific code
- Shared by both EVMs
</constraints>

---

## Error Handling

<errors>
If blocked at any point:

1. Document current state in checklist
2. Create `docs/reports/codesharing-blocked-YYYY-MM-DD.md`
3. List:
   - What was completed
   - What failed
   - Error messages
   - Suggested next steps
4. Commit any safe partial progress
5. Output blocking reason to user
</errors>

---

## Commit Protocol

<commits>
Commit after each phase completion:

```
git add -A
git commit -m "$(cat <<'EOF'
refactor(evm): [Phase N] Description

- Bullet point changes
- Lines added/removed
- Tests validated

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

Final commit updates docs and creates report.
</commits>
