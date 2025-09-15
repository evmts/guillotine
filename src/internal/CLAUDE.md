# CLAUDE.md - Internal Module

## MISSION CRITICAL: Infrastructure Safety and Security
**Safety counter bugs enable DoS attacks.** Bulletproof protection against resource exhaustion.

## Safety Counter Architecture
- **DoS Prevention**: Protect against infinite loops, resource abuse
- **Configurable Limits**: Set bounds per operation type
- **Zero-Cost**: Compile-time enable/disable
- **Platform Aware**: WASM trap vs native panic
- **Graceful Failure**: Controlled failure modes

## Key Responsibilities
- **Loop Bounds**: Prevent infinite loops in bytecode analysis
- **Recursion Depth**: Enforce call depth (1024 max)
- **Resource Monitoring**: Track allocations, gas consumption
- **Attack Prevention**: Detect resource exhaustion

## Critical Implementation
```zig
pub fn inc(self: *Self) void {
    if (mode == .disabled) return;
    self.count += 1;
    if (self.count >= self.limit) {
        log.err("SafetyCounter limit: count={d}, limit={d}", .{ self.count, self.limit });
        if (builtin.target.cpu.arch == .wasm32) {
            unreachable; // WASM trap
        } else {
            @panic("SafetyCounter exceeded"); // Native panic
        }
    }
}
```

## Usage Patterns
```zig
// Bytecode analysis
var counter = SafetyCounter(u32, .enabled).init(10000);
while (pc < bytecode.len) {
    counter.inc();
    // analysis logic
}

// Call depth
var call_counter = SafetyCounter(u16, .enabled).init(1024);
fn execute_call(frame: *Frame) !void {
    call_counter.inc();
    defer call_counter.count -= 1;
    // call logic
}
```

## Configuration
- **Development**: Always `.enabled`
- **Testing**: `.enabled` with generous limits
- **Production**: Consider `.disabled` for stable paths
- **Fuzzing**: `.enabled` with tight limits

## Standard Limits
```zig
const BYTECODE_ANALYSIS_LIMIT = 50_000;
const CALL_DEPTH_LIMIT = 1024;
const MEMORY_ALLOC_LIMIT = 10_000;
const LOOP_ITERATION_LIMIT = 100_000;
```

## Security & Testing
- First line defense against DoS
- Test all behaviors and edge cases
- Monitor violations for analysis
- Performance overhead measurement
- Platform-specific behavior validation

**Safety counters are EVM immune system. Must be robust and well-configured.**