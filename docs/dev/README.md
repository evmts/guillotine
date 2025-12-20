# Developer Documentation

Deep dive documentation for understanding and contributing to Guillotine. These docs contain actual code excerpts, detailed architecture explanations, and step-by-step execution traces.

## Purpose

This documentation enables you to:
- Understand the codebase architecture without reading all source files
- Drive architectural changes with full context
- Debug issues with knowledge of execution flow
- Contribute with understanding of patterns and conventions

## Documentation Index

| Document | Description |
|----------|-------------|
| [ARCHITECTURE.md](./ARCHITECTURE.md) | Unified architecture of both EVMs with code excerpts |
| [EXECUTION-MODELS.md](./EXECUTION-MODELS.md) | Side-by-side comparison of Mini vs Performance |
| [STATE-MANAGEMENT.md](./STATE-MANAGEMENT.md) | Storage, journal, warm/cold tracking |
| [GAS-METERING.md](./GAS-METERING.md) | Gas calculation patterns and costs |
| [TESTING.md](./TESTING.md) | Test organization, running, and debugging |
| [HARDFORKS.md](./HARDFORKS.md) | EIP support matrix and hardfork handling |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | Development workflow and conventions |

## Quick Navigation by Topic

### Execution
- How does the EVM execute bytecode? → [EXECUTION-MODELS.md](./EXECUTION-MODELS.md)
- What is dispatch-based execution? → [ARCHITECTURE.md#dispatch-system](./ARCHITECTURE.md#dispatch-system)
- How do synthetic opcodes work? → [../performance/SYNTHETIC-OPCODES.md](../performance/SYNTHETIC-OPCODES.md)

### State
- How is storage managed? → [STATE-MANAGEMENT.md#storage](./STATE-MANAGEMENT.md#storage)
- What is the journal system? → [STATE-MANAGEMENT.md#journal](./STATE-MANAGEMENT.md#journal)
- How does warm/cold tracking work? → [STATE-MANAGEMENT.md#access-list](./STATE-MANAGEMENT.md#access-list)

### Gas
- How is gas calculated? → [GAS-METERING.md](./GAS-METERING.md)
- What are memory expansion costs? → [GAS-METERING.md#memory-expansion](./GAS-METERING.md#memory-expansion)
- How do SSTORE refunds work? → [GAS-METERING.md#sstore-gas](./GAS-METERING.md#sstore-gas)

### Testing
- How do I run tests? → [TESTING.md#running-tests](./TESTING.md#running-tests)
- How do I debug a failing test? → [TESTING.md#debugging](./TESTING.md#debugging)
- What are spec tests? → [TESTING.md#spec-tests](./TESTING.md#spec-tests)

### Contributing
- What are the coding conventions? → [CONTRIBUTING.md#conventions](./CONTRIBUTING.md#conventions)
- How do I add an opcode? → [CONTRIBUTING.md#adding-opcodes](./CONTRIBUTING.md#adding-opcodes)
- What patterns should I follow? → [CONTRIBUTING.md#patterns](./CONTRIBUTING.md#patterns)

## Key File References

### Performance EVM Core
| File | Size | Purpose |
|------|------|---------|
| `src/evm.zig` | 270KB | EVM orchestrator |
| `src/frame/frame.zig` | ~50KB | Dispatch-based executor |
| `src/preprocessor/dispatch.zig` | ~20KB | Schedule builder |
| `src/bytecode/bytecode.zig` | 115KB | Analysis & schedule generation |
| `src/storage/database.zig` | 88KB | World state |
| `src/storage/journal.zig` | 34KB | Transaction isolation |
| `src/tracer/tracer.zig` | ~50KB | Execution monitoring |

### Mini EVM Core
| File | Size | Purpose |
|------|------|---------|
| `mini/src/evm.zig` | 94KB | Complete orchestrator |
| `mini/src/frame.zig` | 25KB | Traditional interpreter |
| `mini/src/storage.zig` | 16KB | Simple storage model |
| `mini/src/bytecode.zig` | 6KB | JUMPDEST analysis |

### Instruction Handlers
| Category | Performance | Mini |
|----------|-------------|------|
| Arithmetic | `src/instructions/handlers_arithmetic.zig` | `mini/src/instructions/handlers_arithmetic.zig` |
| Storage | `src/instructions/handlers_storage.zig` | `mini/src/instructions/handlers_storage.zig` |
| System | `src/instructions/handlers_system.zig` | `mini/src/instructions/handlers_system.zig` |
| Synthetic | `src/instructions/handlers_*_synthetic.zig` | N/A |

## Code Conventions

### Logging
```zig
// Use log module, not std.debug.print
const log = @import("log.zig");
log.debug("Message: {}", .{value});
```

### Assertions
```zig
// Use tracer assertions, not std.debug.assert
self.getTracer().assert(condition, "message");
```

### Error Handling
```zig
// NEVER swallow errors
// BAD:
slots.append(allocator, key) catch {};

// GOOD:
try slots.append(allocator, key);
```

### Memory Management
```zig
// Pattern 1: Same scope cleanup
const thing = try allocator.create(Thing);
defer allocator.destroy(thing);

// Pattern 2: Ownership transfer
const thing = try allocator.create(Thing);
errdefer allocator.destroy(thing);
thing.* = try Thing.init(allocator);
return thing;
```

## Related Documentation

- [CLAUDE.md](../../CLAUDE.md) - Project-level instructions
- [mini/CLAUDE.md](../../mini/CLAUDE.md) - Mini EVM instructions
- [Performance EVM](../performance/) - Performance-specific docs
- [Mini EVM](../mini/) - Mini-specific docs
