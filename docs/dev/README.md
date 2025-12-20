# Developer Documentation

Deep dive documentation for understanding and contributing to Guillotine. These docs contain actual code excerpts, detailed architecture explanations, and step-by-step execution traces.

```
                           GUILLOTINE EVM
    ┌─────────────────────────────────────────────────────────┐
    │                                                         │
    │   ┌─────────────┐              ┌─────────────────────┐  │
    │   │  Mini EVM   │              │  Performance EVM    │  │
    │   │  (Clarity)  │              │  (Speed)            │  │
    │   │             │              │                     │  │
    │   │  PC-based   │              │  Dispatch-based     │  │
    │   │  46 files   │              │  158 files          │  │
    │   │  ~25KB      │              │  ~270KB             │  │
    │   └─────────────┘              └─────────────────────┘  │
    │          │                              │               │
    │          └──────────────┬───────────────┘               │
    │                         │                               │
    │                    Shared Primitives                    │
    │              (Address, U256, Gas, Hardfork)             │
    └─────────────────────────────────────────────────────────┘
```

## Quick Start for New Developers

### 1. Understand the Two EVMs

| Aspect | Mini EVM | Performance EVM |
|--------|----------|-----------------|
| **Location** | `mini/src/` | `src/` |
| **Philosophy** | Clarity first | Speed first |
| **Execution** | Sequential PC loop | Tail-call dispatch |
| **Use case** | Learning, testing | Production |
| **Start here** | `mini/src/frame.zig` | `src/frame/frame.zig` |

### 2. Read in This Order

```
START HERE
    │
    ▼
┌─────────────────────────────────┐
│ 1. ARCHITECTURE.md              │  ← Understand the structure
│    - Core components            │
│    - How pieces fit together    │
└─────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────┐
│ 2. EXECUTION-MODELS.md          │  ← See both EVMs side-by-side
│    - Mini: while loop           │
│    - Performance: tail calls    │
└─────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────┐
│ 3. STATE-MANAGEMENT.md          │  ← How storage works
│    - Storage, journal           │
│    - Warm/cold access           │
└─────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────┐
│ 4. GAS-METERING.md              │  ← Gas calculation rules
│    - Static/dynamic costs       │
│    - SSTORE gas table           │
└─────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────┐
│ 5. CONTRIBUTING.md              │  ← Ready to contribute
│    - Code patterns              │
│    - Adding opcodes             │
└─────────────────────────────────┘
```

### 3. Run Your First Test

```bash
# Build the project
zig build

# Run all tests (should pass with no output)
zig build test

# Run a specific opcode test
zig build test-opcodes -Dtest-filter='ADD'

# No output = success!
```

## Documentation Index

| Document | Description | Read When... |
|----------|-------------|--------------|
| [ARCHITECTURE.md](./ARCHITECTURE.md) | Unified architecture with code excerpts | Understanding codebase structure |
| [EXECUTION-MODELS.md](./EXECUTION-MODELS.md) | Side-by-side Mini vs Performance | Comparing implementations |
| [STATE-MANAGEMENT.md](./STATE-MANAGEMENT.md) | Storage, journal, warm/cold tracking | Working with storage |
| [GAS-METERING.md](./GAS-METERING.md) | Gas calculation patterns and costs | Debugging gas issues |
| [TESTING.md](./TESTING.md) | Test organization and debugging | Running/writing tests |
| [HARDFORKS.md](./HARDFORKS.md) | EIP support matrix and feature flags | Adding hardfork features |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | Development workflow and conventions | Making contributions |

## Quick Navigation by Topic

### "How does X work?"

| Question | Document | Section |
|----------|----------|---------|
| How does the EVM execute bytecode? | [EXECUTION-MODELS.md](./EXECUTION-MODELS.md) | Execution Loop |
| What is dispatch-based execution? | [ARCHITECTURE.md](./ARCHITECTURE.md#dispatch-system) | Dispatch System |
| How do synthetic opcodes work? | [../performance/SYNTHETIC-OPCODES.md](../performance/SYNTHETIC-OPCODES.md) | All |
| How is storage managed? | [STATE-MANAGEMENT.md](./STATE-MANAGEMENT.md#storage-architecture) | Storage Architecture |
| What is the journal system? | [STATE-MANAGEMENT.md](./STATE-MANAGEMENT.md#journal-system-performance-only) | Journal System |
| How does warm/cold tracking work? | [STATE-MANAGEMENT.md](./STATE-MANAGEMENT.md#access-list-eip-2929) | Access List |
| How is gas calculated? | [GAS-METERING.md](./GAS-METERING.md) | All |
| What are memory expansion costs? | [GAS-METERING.md](./GAS-METERING.md#memory-expansion) | Memory Expansion |
| How do SSTORE refunds work? | [GAS-METERING.md](./GAS-METERING.md#sstore-gas-eip-22003529) | SSTORE Gas |

### "How do I..."

| Task | Document | Section |
|------|----------|---------|
| Run tests? | [TESTING.md](./TESTING.md#running-tests) | Running Tests |
| Debug a failing test? | [TESTING.md](./TESTING.md#debugging-tests) | Debugging Tests |
| Add a new opcode? | [CONTRIBUTING.md](./CONTRIBUTING.md#adding-a-new-opcode) | Adding a New Opcode |
| Add hardfork support? | [HARDFORKS.md](./HARDFORKS.md#implementation-checklist) | Implementation Checklist |
| Write a handler? | [CONTRIBUTING.md](./CONTRIBUTING.md#handler-patterns) | Handler Patterns |

## Key File Map

```
src/                              mini/src/
├── evm.zig (270KB)               ├── evm.zig (94KB)
│   └── Orchestrates execution    │   └── Complete EVM
│                                 │
├── frame/                        ├── frame.zig (25KB)
│   └── frame.zig (50KB)          │   └── Execution loop
│       └── Dispatch execution    │
│                                 │
├── instructions/                 ├── instructions/
│   ├── handlers_arithmetic.zig   │   ├── handlers_arithmetic.zig
│   ├── handlers_storage.zig      │   ├── handlers_storage.zig
│   ├── handlers_system.zig       │   ├── handlers_system.zig
│   └── handlers_*_synthetic.zig  │   └── (no synthetics)
│                                 │
├── preprocessor/                 └── (no preprocessor)
│   └── dispatch.zig (20KB)
│       └── Schedule builder
│
├── storage/
│   ├── database.zig (88KB)
│   ├── journal.zig (34KB)
│   └── access_list.zig
│
└── tracer/
    └── tracer.zig (50KB)
```

## Core Concepts at a Glance

### Execution Flow

```
                    MINI EVM                           PERFORMANCE EVM
                    ────────                           ───────────────
                        │                                    │
              ┌─────────▼──────────┐              ┌─────────▼──────────┐
              │  Read bytecode[PC] │              │  Preprocess once   │
              └─────────┬──────────┘              │  into schedule     │
                        │                         └─────────┬──────────┘
              ┌─────────▼──────────┐                        │
              │  Switch on opcode  │              ┌─────────▼──────────┐
              │  (256 cases)       │              │  schedule[0].gas   │
              └─────────┬──────────┘              │  (block metadata)  │
                        │                         └─────────┬──────────┘
              ┌─────────▼──────────┐                        │
              │  Execute handler   │              ┌─────────▼──────────┐
              └─────────┬──────────┘              │  handler(cursor)   │
                        │                         │  tail-call next    │
              ┌─────────▼──────────┐              └─────────┬──────────┘
              │  PC += 1           │                        │
              │  Continue loop     │                        │
              └─────────┬──────────┘              ┌─────────▼──────────┐
                        │                         │  Never returns     │
                   Loop back                      │  Error = exit      │
                                                  └────────────────────┘
```

### Stack Operations

```
LIFO Stack (both implementations)
─────────────────────────────────

   pushStack(5)  pushStack(3)  popStack()   Result
        │              │            │
        ▼              ▼            ▼
   ┌─────────┐   ┌─────────┐   ┌─────────┐
   │    5    │   │    3    │ ←─│ returns │   Stack now: [5]
   ├─────────┤   ├─────────┤   │    3    │
   │  empty  │   │    5    │   └─────────┘
   └─────────┘   └─────────┘

   First pop = top of stack (most recently pushed)
```

### Gas Metering

```
MINI: Per-operation                PERFORMANCE: Per-block
─────────────────                  ────────────────────

  ADD: check 3 gas                  Block entry:
  SUB: check 3 gas                    check 9 gas (3+3+3)
  MUL: check 5 gas
                                    ADD: no check
  Total: 3 checks                   SUB: no check
                                    MUL: no check

                                    Total: 1 check
```

## Code Conventions Quick Reference

### Do This

```zig
// Logging
const log = @import("log.zig");
log.debug("Op: {}", .{opcode});

// Assertions
self.getTracer().assert(cond, "message");

// Error handling
try operation();  // Always propagate

// Memory
const x = try alloc.create(T);
defer alloc.destroy(x);
```

### Never Do This

```zig
// NEVER: std.debug.print
std.debug.print("debug", .{});  // Use log module

// NEVER: std.debug.assert
std.debug.assert(cond);  // Use tracer.assert

// NEVER: Swallow errors
operation() catch {};  // Propagate or handle!

// NEVER: Skip tests
// test "broken" { }  // Fix it or delete it
```

## Related Documentation

- **[CLAUDE.md](../../CLAUDE.md)** - Project-level instructions and rules
- **[mini/CLAUDE.md](../../mini/CLAUDE.md)** - Mini EVM specific instructions
- **[Performance EVM](../performance/)** - Performance-specific deep dives
- **[Mini EVM](../mini/)** - Mini-specific documentation
- **[TypeScript Port](../mini/typescript/)** - TypeScript implementation docs

## Building Mental Models

### The EVM is a Stack Machine

```
Bytecode: PUSH1 05  PUSH1 03  ADD
          ─────────────────────────
              │         │       │
              ▼         ▼       ▼
Stack:      [5]      [3,5]    [8]
```

### Storage is Address-Scoped

```
Contract A (0xAAA...)           Contract B (0xBBB...)
├── slot[0] = 100               ├── slot[0] = 200
├── slot[1] = 42                └── slot[1] = 0
└── slot[2] = 0

Same slot number, different values per contract
```

### Frames Create Isolation

```
CALL creates new frame
──────────────────────

Frame 1 (caller)              Frame 2 (callee)
├── stack: [...]              ├── stack: []         ← Fresh
├── memory: [...]             ├── memory: []        ← Fresh
├── gas: 90000                ├── gas: 60000        ← Subset
└── address: 0xAAA            └── address: 0xBBB    ← Different

On RETURN: Frame 2 destroyed, Frame 1 continues
On REVERT: Frame 2 state rolled back
```
