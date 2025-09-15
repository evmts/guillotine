# CLAUDE.md - Stack Module

## MISSION CRITICAL: EVM Stack Invariants
**Stack violations cause consensus failures and fund loss.** Must maintain exact EVM compliance.

### EVM Stack Specs
- **Capacity**: 1024 elements max
- **Element Size**: 256-bit words (u256)
- **Behavior**: LIFO with strict overflow/underflow checking
- **Growth**: Downward for cache performance

### Core Files
- `stack.zig` - Main implementation, safe/unsafe variants
- `stack_config.zig` - Configuration validation, index types
- `stack_c.zig` - C FFI interface
- `stack_bench.zig` - Performance benchmarks

## Memory Safety

**Allocation Pattern**:
```zig
buf_ptr: [*]align(64) WordType = try allocator.alignedAlloc(WordType, 64, capacity);
defer allocator.free(buf_ptr[0..capacity]);
stack_ptr: [*]WordType = buf_ptr + capacity; // Downward growth
```

**Rules**: Stack owns aligned buffer, buffer lives entire lifetime, MUST free on destruction, 64-byte alignment

## Stack Operations
- **Push**: Check overflow before decrement/assign (unsafe: assertions)
- **Pop**: Check underflow before read/increment (unsafe: assertions)
- **Length**: `capacity_ptr - self.stack_ptr` pointer arithmetic
- **DUP/SWAP**: Position-based operations with bounds checking

## Performance
- 64-byte alignment for cache lines
- Downward growth with pointer arithmetic
- Index types: u4/u8/u12 based on capacity
- Safe: bounds checking, unsafe: assertions only

## Critical Errors
- **Overflow**: Check `len() >= capacity` before push
- **Underflow**: Check `len() == 0` before pop
- **Allocation**: Handle `alignedAlloc` failure

## EVM Operations
- **PUSH (0x60-0x7F)**: 1-32 bytes, left-padded to 256 bits
- **POP (0x50)**: Remove top element
- **DUP (0x80-0x8F)**: Duplicate at position N (1-16)
- **SWAP (0x90-0x9F)**: Exchange with position N+1 (1-16)

## Testing & Security
- Test all operations at all positions
- Boundary conditions: empty/full stack
- Performance: throughput, cache efficiency
- Memory safety: bounds checking, no overflows
- Consensus security: exact EVM compliance

**The EVM stack is not negotiable. Any deviation causes consensus failures.**