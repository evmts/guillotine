# Task Dependencies for Block-Based EVM Migration

## Dependency Graph

### Foundation Layer (No dependencies)
These can be started immediately:
- **INST-001**: Define Instruction struct
- **INST-002**: Verify BlockMetrics struct exists
- **MSG-001**: Update Message struct
- **PAT-001**: Create pattern_compression.zig file
- **MISC-004**: Add MAX_INSTRUCTIONS constant
- **OPX-001**: Create opx.zig file

### Layer 1 (Depends on Foundation)
**Blocked by INST-001:**
- **INST-004**: Implement Instruction.execute() method
- **TRANS-001**: Create instruction_translator.zig structure
- **TEST-001**: Test Instruction struct

**Blocked by INST-002:**
- **INST-003**: Add instruction array to CodeAnalysis

**Blocked by OPX-001:**
- **OPX-002**: Implement opx_beginblock handler

### Layer 2 (Depends on Layer 1)
**Blocked by INST-003:**
- **FRAME-001**: Add vm reference to Frame

**Blocked by INST-004:**
- **TRANS-002** through **TRANS-012**: All translate_bytecode implementations

**Blocked by OPX-002:**
- **OPX-003**: Add OPX_BEGINBLOCK to jump table

**Blocked by TRANS-001:**
- **BLOCK-001**: JUMPI block splitting
- **BLOCK-002**: Dead code skipping
- **BLOCK-003**: Store gas costs for dynamic instructions

### Layer 3 (Depends on Layer 2)
**Blocked by TRANS-002 through TRANS-012:**
- **OPX-004**: Insert OPX_BEGINBLOCK at boundaries
- **TEST-002**: Test single opcode translation
- **TEST-003**: Test PUSH translation
- **JUMP-001**: Handle jump destination lookup
- **JUMP-002**: Handle JUMPI conditional logic

**Blocked by FRAME-001:**
- **INTERP-001**: Create interpret_fast() skeleton

**Blocked by OPX-003 & OPX-004:**
- **TEST-007**: Test OPX_BEGINBLOCK execution

### Layer 4 (Integration)
**Blocked by INTERP-001:**
- **INTERP-002**: Call analyze_bytecode_blocks
- **INTERP-003**: Call translate_bytecode
- **INTERP-004**: Implement execution loop
- **INTERP-005**: Handle error propagation

**Blocked by BLOCK-001, BLOCK-002, BLOCK-003:**
- **TEST-004**: Test block boundary detection
- **TEST-005**: Test JUMPI splitting
- **TEST-006**: Test dead code skipping

**Blocked by JUMP-001 through JUMP-004:**
- **JUMP-003**: Validate jump destinations
- **JUMP-004**: Handle dynamic jumps

### Layer 5 (Final Integration)
**Blocked by INTERP-002 through INTERP-005:**
- **INTERP-006**: Add entry point to evm.zig
- **INTERP-007**: Create feature flag
- **TEST-008**: Test instruction stream execution
- **TEST-009**: Test gas cost tracking
- **TEST-010**: Test stack validation

**Blocked by MSG-001:**
- **MSG-002**: Convert CALL to Message
- **MSG-003**: Convert CREATE to Message
- **MSG-004**: Update frame init

### Layer 6 (Testing & Validation)
**Blocked by INTERP-006:**
- **TEST-011**: Differential testing
- **TEST-012**: Benchmarking
- **MISC-001**: Handle precompiles
- **MISC-002**: Update debugging/tracing

### Pattern Compression (Parallel Track)
Can be developed independently:

**Blocked by PAT-001:**
- **PAT-002**: Define pattern structures

**Blocked by PAT-002:**
- **PAT-003** through **PAT-011**: Individual patterns
- **PAT-012**: Synthetic opcode handlers

**Blocked by PAT-012:**
- **PAT-013**: Feature flag
- **PAT-015**: Add to jump table

**Blocked by PAT-013 & completion of main interpreter:**
- **PAT-014**: Integrate in translator
- **PAT-016**: Test pattern detection
- **PAT-017**: Benchmark impact

### Final Optimization (After everything works)
**Blocked by TEST-011 & TEST-012:**
- **OPT-001**: Profile hot paths
- **OPT-002**: Optimize dispatch
- **OPT-003**: Measure cache misses
- **OPT-004**: Run official benchmarks
- **MISC-003**: Document architecture
- **MISC-005**: Ensure null terminators

## Critical Path
The longest dependency chain (critical path) is:
1. INST-001 → INST-004 → TRANS-002-012 → INTERP-001 → INTERP-002-005 → INTERP-006 → TEST-011

## Parallel Work Streams
These can be worked on simultaneously:
1. **Core Instruction Stream**: INST-* tasks
2. **Translation Logic**: TRANS-* and BLOCK-* tasks
3. **Message API**: MSG-* tasks
4. **Pattern Compression**: PAT-* tasks (independent)
5. **Testing Infrastructure**: TEST-001 through TEST-003 early tests

## Recommended Starting Points
Start with these tasks first as they unblock the most work:
1. **INST-001**: Define Instruction struct (unblocks 3 tasks)
2. **INST-002**: Verify BlockMetrics (unblocks 1 task)
3. **OPX-001**: Create opx.zig (unblocks chain)
4. **MSG-001**: Update Message struct (unblocks chain)
5. **PAT-001**: Start pattern compression (parallel track)
6. **MISC-004**: Define constants (needed everywhere)