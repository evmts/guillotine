# EVM Opcode Performance Audit: Guillotine vs evmone

This document compares the implementation of each EVM opcode between our Zig implementation (Guillotine) and evmone's C++ implementation to identify performance optimization opportunities.

## Arithmetic Opcodes

### ADD (0x01)

**evmone implementation:**

```cpp
inline void add(StackTop stack) noexcept
{
    stack.top() += stack.pop();
}
```

**Guillotine implementation:**

```zig
const b = frame.stack.pop_unsafe();
const a = frame.stack.peek_unsafe().*;
const result = a +% b;
frame.stack.set_top_unsafe(result);

// change to this
// frame.stack.set_top_unsafe(frame.stack.peek_unsafe().* +% frame.stack.pop_unsafe());
```

**Performance Issues:**

- ❌ **Extra peek operation**: We peek then set_top instead of direct modification
- **Recommendation**: Use in-place modification like evmone

### MUL (0x02)

**evmone implementation:**

```cpp
inline void mul(StackTop stack) noexcept
{
    stack.top() *= stack.pop();
}
```

**Guillotine implementation:**

```zig
const b = frame.stack.pop_unsafe();
const a = frame.stack.peek_unsafe().*;
const product = a *% b;
frame.stack.set_top_unsafe(product);
```

**Performance Issues:**

- ❌ **Same issues as ADD**: Extra peek operation
- **Recommendation**: Use in-place multiplication

### SUB (0x03)

**evmone implementation:**

```cpp
inline void sub(StackTop stack) noexcept
{
    stack[1] = stack[0] - stack[1];
}
```

**Guillotine implementation:**

```zig
const b = frame.stack.pop_unsafe();
const a = frame.stack.peek_unsafe().*;
const result = b -% a;  // Note: operands reversed!
frame.stack.set_top_unsafe(result);
```

**Performance Issues:**

- ❌ **Operand order confusion**: Our implementation has `b - a` instead of `a - b`
- **Recommendation**: Use direct array indexing like evmone

### DIV (0x04)

**evmone implementation:**

```cpp
inline void div(StackTop stack) noexcept
{
    auto& v = stack[1];
    v = v != 0 ? stack[0] / v : 0;
}
```

**Guillotine implementation:**

```zig
const b = frame.stack.pop_unsafe();
const a = frame.stack.peek_unsafe().*;
const result = if (a == 0) blk: {
    @branchHint(.unlikely);
    break :blk 0;
} else b / a;
frame.stack.set_top_unsafe(result);
```

**Performance Issues:**

- ❌ **Operand confusion**: We check if divisor (a) is 0, but then do b/a (wrong order)
- ✅ **Good**: Uses @branchHint for unlikely zero case
- **Recommendation**: Fix operand order and use in-place modification

### SDIV (0x05)

**evmone implementation:**

```cpp
inline void sdiv(StackTop stack) noexcept
{
    auto& v = stack[1];
    v = v != 0 ? intx::sdivrem(stack[0], v).quot : 0;
}
```

**Guillotine implementation:**

```zig
const b = frame.stack.pop_unsafe();
const a = frame.stack.peek_unsafe().*;
var result: u256 = undefined;
if (a == 0) {
    @branchHint(.unlikely);
    result = 0;
} else {
    const a_i256 = @as(i256, @bitCast(a));
    const b_i256 = @as(i256, @bitCast(b));
    const min_i256 = std.math.minInt(i256);
    if (b_i256 == min_i256 and a_i256 == -1) {
        @branchHint(.unlikely);
        result = b;
    } else {
        const result_i256 = @divTrunc(b_i256, a_i256);
        result = @as(u256, @bitCast(result_i256));
    }
}
frame.stack.set_top_unsafe(result);
```

**Performance Issues:**

- ❌ **Much more complex than evmone**: evmone uses single sdivrem call
- ❌ **Multiple type conversions**: Converting between u256 and i256
- ✅ **Good**: Handles overflow case explicitly
- **Recommendation**: Consider using a single optimized signed division function

### MOD (0x06)

**evmone implementation:**

```cpp
inline void mod(StackTop stack) noexcept
{
    auto& v = stack[1];
    v = v != 0 ? stack[0] % v : 0;
}
```

**Guillotine implementation:**

```zig
const b = frame.stack.pop_unsafe();
const a = frame.stack.peek_unsafe().*;
const result = if (a == 0) blk: {
    @branchHint(.unlikely);
    break :blk 0;
} else b % a;
frame.stack.set_top_unsafe(result);
```

**Performance Issues:**

- ❌ **Not in-place**: Should modify stack top directly
- **Recommendation**: Use in-place modification

### SMOD (0x07)

**evmone implementation:**

```cpp
inline void smod(StackTop stack) noexcept
{
    auto& v = stack[1];
    v = v != 0 ? intx::sdivrem(stack[0], v).rem : 0;
}
```

**Guillotine implementation:**

```zig
const b = frame.stack.pop_unsafe();
const a = frame.stack.peek_unsafe().*;
var result: u256 = undefined;
if (a == 0) {
    @branchHint(.unlikely);
    result = 0;
} else {
    const a_i256 = @as(i256, @bitCast(a));
    const b_i256 = @as(i256, @bitCast(b));
    const result_i256 = @rem(b_i256, a_i256);
    result = @as(u256, @bitCast(result_i256));
}
frame.stack.set_top_unsafe(result);
```

**Performance Issues:**

- ❌ **Type conversions**: Multiple bitcasts between u256 and i256
- ❌ **Not using combined div/rem**: evmone uses sdivrem which can be more efficient
- **Recommendation**: Implement combined signed div/rem operation

### ADDMOD (0x08)

**evmone implementation:**

```cpp
inline void addmod(StackTop stack) noexcept
{
    const auto& x = stack.pop();
    const auto& y = stack.pop();
    auto& m = stack.top();
    m = m != 0 ? intx::addmod(x, y, m) : 0;
}
```

**Guillotine implementation:**

```zig
const b = frame.stack.pop_unsafe();
const a = frame.stack.pop_unsafe();
const n = frame.stack.peek_unsafe().*;
var result: u256 = undefined;
if (n == 0) {
    result = 0;
} else {
    const sum = a +% b;
    result = sum % n;
}
frame.stack.set_top_unsafe(result);
```

**Performance Issues:**

- ❌ **Incorrect implementation**: Simple (a+b)%n doesn't handle overflow correctly
- ❌ **evmone uses specialized addmod**: Handles cases where a+b > 2^256
- **Critical Bug**: Our implementation is mathematically incorrect for large values
- **Recommendation**: Implement proper addmod algorithm

### MULMOD (0x09)

**evmone implementation:**

```cpp
inline void mulmod(StackTop stack) noexcept
{
    const auto& x = stack[0];
    const auto& y = stack[1];
    auto& m = stack[2];
    m = m != 0 ? intx::mulmod(x, y, m) : 0;
}
```

**Guillotine implementation:**

```zig
// Uses Russian peasant multiplication algorithm
result = 0;
var x = a % n;
var y = b % n;
while (y > 0) {
    if ((y & 1) == 1) {
        const sum = result +% x;
        result = sum % n;
    }
    x = (x +% x) % n;
    y >>= 1;
}
```

**Performance Issues:**

- ✅ **Good**: Correctly implements mulmod for overflow cases
- ❌ **Potentially slower**: Loop-based vs evmone's optimized intx::mulmod
- ❌ **More operations**: Many modulo operations in the loop
- **Recommendation**: Consider optimized mulmod implementation

### EXP (0x0A)

**evmone implementation:**

```cpp
inline Result exp(StackTop stack, int64_t gas_left, ExecutionState& state) noexcept
{
    const auto& base = stack.pop();
    auto& exponent = stack.top();

    const auto exponent_significant_bytes =
        static_cast<int>(intx::count_significant_bytes(exponent));
    const auto exponent_cost = state.rev >= EVMC_SPURIOUS_DRAGON ? 50 : 10;
    const auto additional_cost = exponent_significant_bytes * exponent_cost;
    if ((gas_left -= additional_cost) < 0)
        return {EVMC_OUT_OF_GAS, gas_left};

    exponent = intx::exp(base, exponent);
    return {EVMC_SUCCESS, gas_left};
}
```

**Guillotine implementation:**

```zig
// Manual byte counting
var exp_copy = exp;
var byte_size: u64 = 0;
while (exp_copy > 0) : (exp_copy >>= 8) {
    byte_size += 1;
}
// ... gas calculation ...
// Square-and-multiply algorithm
var result: u256 = 1;
var b = base;
var e = exp;
while (e > 0) {
    if ((e & 1) == 1) {
        const mul_result = @mulWithOverflow(result, b);
        result = mul_result[0];
    }
    if (e > 1) {
        const square_result = @mulWithOverflow(b, b);
        b = square_result[0];
    }
    e >>= 1;
}
```

**Performance Issues:**

- ❌ **Manual byte counting**: evmone uses optimized count_significant_bytes
- ❌ **Manual square-and-multiply**: evmone uses optimized intx::exp
- ✅ **Good**: Early exit optimizations for special cases
- **Recommendation**: Implement optimized byte counting function

### SIGNEXTEND (0x0B)

**evmone implementation:**

```cpp
inline void signextend(StackTop stack) noexcept
{
    const auto& ext = stack.pop();
    auto& x = stack.top();

    if (ext < 31)
    {
        const auto e = ext[0];
        const auto sign_word_index = static_cast<size_t>(e / sizeof(e));
        const auto sign_byte_index = e % sizeof(e);
        auto& sign_word = x[sign_word_index];

        const auto sign_byte_offset = sign_byte_index * 8;
        const auto sign_byte = sign_word >> sign_byte_offset;

        const auto sext_byte = static_cast<uint64_t>(int64_t{static_cast<int8_t>(sign_byte)});
        const auto sext = sext_byte << sign_byte_offset;

        const auto sign_mask = ~uint64_t{0} << sign_byte_offset;
        const auto value = sign_word & ~sign_mask;
        sign_word = sext | value;

        const auto sign_ex = static_cast<uint64_t>(static_cast<int64_t>(sext_byte) >> 8);

        for (size_t i = 3; i > sign_word_index; --i)
            x[i] = sign_ex;
    }
}
```

**Guillotine implementation:**

```zig
const byte_num = frame.stack.pop_unsafe();
const x = frame.stack.peek_unsafe().*;
var result: u256 = undefined;
if (byte_num >= 31) {
    @branchHint(.unlikely);
    result = x;
} else {
    const byte_index = @as(u8, @intCast(byte_num));
    const sign_bit_pos = byte_index * 8 + 7;
    const sign_bit = (x >> @intCast(sign_bit_pos)) & 1;
    const keep_bits = sign_bit_pos + 1;
    if (sign_bit == 1) {
        if (keep_bits >= 256) {
            result = x;
        } else {
            const ones_mask = ~((@as(u256, 1) << @intCast(keep_bits)) - 1);
            result = x | ones_mask;
        }
    } else {
        if (keep_bits >= 256) {
            result = x;
        } else {
            const zero_mask = (@as(u256, 1) << @intCast(keep_bits)) - 1;
            result = x & zero_mask;
        }
    }
}
frame.stack.set_top_unsafe(result);
```

**Performance Issues:**

- ❌ **Works on full u256**: evmone works on individual 64-bit words (more efficient)
- ❌ **More branching**: Multiple if statements vs evmone's direct word manipulation
- ❌ **Bit manipulation on u256**: Less efficient than word-level operations
- **Recommendation**: Implement word-level sign extension

## Summary of Critical Issues

1. **ADDMOD is incorrect** - Doesn't handle overflow properly
2. **SUB has wrong operand order** - Computing b-a instead of a-b
3. **DIV has wrong operand order** - Computing b/a instead of a/b
4. **Most arithmetic ops don't use in-place modification** - Should modify stack directly
5. **Signed operations use many type conversions** - Should use optimized functions
6. **SIGNEXTEND operates on full u256** - Should use word-level operations

## General Optimization Patterns from evmone

1. **In-place stack operations**: Modify stack values directly using references
2. **Direct array indexing**: Use stack[0], stack[1] instead of pop/peek/push
3. **Specialized integer library**: evmone uses intx library with optimized operations
4. **Word-level operations**: Work with 64-bit words instead of full 256-bit values
5. **Combined operations**: sdivrem returns both quotient and remainder
6. **Optimized bit counting**: count_significant_bytes for gas calculations

## Comparison & Bitwise Opcodes

### LT (0x10)

**evmone implementation:**

```cpp
inline void lt(StackTop stack) noexcept
{
    const auto& x = stack.pop();
    stack[0] = x < stack[0];
}
```

**Guillotine implementation:**

```zig
const b = frame.stack.pop_unsafe();
const a = frame.stack.peek_unsafe().*;
const result: u256 = switch (std.math.order(b, a)) {
    .lt => 1,
    .eq, .gt => 0,
};
frame.stack.set_top_unsafe(result);
```

**Performance Issues:**

- ❌ **Using std.math.order**: More complex than simple comparison
- ❌ **Switch statement**: Unnecessary branching for simple < comparison
- **Recommendation**: Use direct comparison like evmone

### GT (0x11)

**evmone implementation:**

```cpp
inline void gt(StackTop stack) noexcept
{
    const auto& x = stack.pop();
    stack[0] = stack[0] < x;  // Swapped for GT
}
```

**Guillotine implementation:**

```zig
const b = frame.stack.pop_unsafe();
const a = frame.stack.peek_unsafe().*;
const result: u256 = switch (std.math.order(b, a)) {
    .gt => 1,
    .eq, .lt => 0,
};
frame.stack.set_top_unsafe(result);
```

**Performance Issues:**

- ❌ **Same issues as LT**: Switch statement and std.math.order
- ✅ **Correct**: evmone cleverly uses `a < b` for `b > a`
- **Recommendation**: Use swapped comparison like evmone

### SLT (0x12)

**evmone implementation:**

```cpp
inline void slt(StackTop stack) noexcept
{
    const auto& x = stack.pop();
    stack[0] = slt(x, stack[0]);
}
```

**Guillotine implementation:**

```zig
const b = frame.stack.pop_unsafe();
const a = frame.stack.peek_unsafe().*;
const a_i256 = @as(i256, @bitCast(a));
const b_i256 = @as(i256, @bitCast(b));
const result: u256 = switch (std.math.order(b_i256, a_i256)) {
    .lt => 1,
    .eq, .gt => 0,
};
frame.stack.set_top_unsafe(result);
```

**Performance Issues:**

- ❌ **Type conversions**: Multiple bitcasts
- ❌ **Switch statement**: Unnecessary for simple comparison
- **Recommendation**: Use direct signed comparison

### SGT (0x13)

**evmone implementation:**

```cpp
inline void sgt(StackTop stack) noexcept
{
    const auto& x = stack.pop();
    stack[0] = slt(stack[0], x);  // Swapped SLT
}
```

**Guillotine implementation:**

```zig
const b = frame.stack.pop_unsafe();
const a = frame.stack.peek_unsafe().*;
const a_i256 = @as(i256, @bitCast(a));
const b_i256 = @as(i256, @bitCast(b));
const result: u256 = if (b_i256 > a_i256) 1 else 0;
frame.stack.set_top_unsafe(result);
```

**Performance Issues:**

- ❌ **Type conversions**: Bitcasts could be avoided
- ✅ **Better than SLT**: At least uses direct if/else
- **Recommendation**: Use swapped SLT like evmone

### EQ (0x14)

**evmone implementation:**

```cpp
inline void eq(StackTop stack) noexcept
{
    stack[1] = stack[0] == stack[1];
}
```

**Guillotine implementation:**

```zig
const b = frame.stack.pop_unsafe();
const a = frame.stack.peek_unsafe().*;
const result: u256 = if (a == b) 1 else 0;
frame.stack.set_top_unsafe(result);
```

**Performance Issues:**

- ❌ **Not using direct array indexing**: Could compare stack slots directly
- **Recommendation**: Use direct comparison on stack slots

### ISZERO (0x15)

**evmone implementation:**

```cpp
inline void iszero(StackTop stack) noexcept
{
    stack.top() = stack.top() == 0;
}
```

**Guillotine implementation:**

```zig
const value = frame.stack.peek_unsafe().*;
const result: u256 = @intFromBool(value == 0);
frame.stack.set_top_unsafe(result);
```

**Performance Issues:**

- ✅ **Good**: Uses @intFromBool for efficient conversion
- ❌ **Not in-place**: Could modify top directly
- **Recommendation**: Direct in-place modification

### AND (0x16)

**evmone implementation:**

```cpp
inline void and_(StackTop stack) noexcept
{
    stack.top() &= stack.pop();
}
```

**Guillotine implementation:**

```zig
const b = frame.stack.pop_unsafe();
const a = frame.stack.peek_unsafe().*;
frame.stack.set_top_unsafe(a & b);
```

**Performance Issues:**

- ❌ **Not using compound assignment**: Should use in-place &=
- **Recommendation**: Use compound assignment

### OR (0x17)

**evmone implementation:**

```cpp
inline void or_(StackTop stack) noexcept
{
    stack.top() |= stack.pop();
}
```

**Guillotine implementation:**

```zig
const b = frame.stack.pop_unsafe();
const a = frame.stack.peek_unsafe().*;
frame.stack.set_top_unsafe(a | b);
```

**Performance Issues:**

- ❌ **Same as AND**: Should use |= operator
- **Recommendation**: Use compound assignment

### XOR (0x18)

**evmone implementation:**

```cpp
inline void xor_(StackTop stack) noexcept
{
    stack.top() ^= stack.pop();
}
```

**Guillotine implementation:**

```zig
const b = frame.stack.pop_unsafe();
const a = frame.stack.peek_unsafe().*;
frame.stack.set_top_unsafe(a ^ b);
```

**Performance Issues:**

- ❌ **Same pattern**: Should use ^= operator
- **Recommendation**: Use compound assignment

### NOT (0x19)

**evmone implementation:**

```cpp
inline void not_(StackTop stack) noexcept
{
    stack.top() = ~stack.top();
}
```

**Guillotine implementation:**

```zig
const a = frame.stack.peek_unsafe().*;
frame.stack.set_top_unsafe(~a);
```

**Performance Issues:**

- ❌ **Not in-place**: Should modify top directly
- **Recommendation**: Direct modification

### BYTE (0x1a)

**evmone implementation:**

```cpp
inline void byte(StackTop stack) noexcept
{
    const auto& n = stack.pop();
    auto& x = stack.top();

    const bool n_valid = n < 32;
    const uint64_t byte_mask = (n_valid ? 0xff : 0);

    const auto index = 31 - static_cast<unsigned>(n[0] % 32);
    const auto word = x[index / 8];
    const auto byte_index = index % 8;
    const auto byte = (word >> (byte_index * 8)) & byte_mask;
    x = byte;
}
```

**Guillotine implementation:**

```zig
const i = frame.stack.pop_unsafe();
const val = frame.stack.peek_unsafe().*;
const result = if (i >= 32) 0 else blk: {
    const i_usize = @as(usize, @intCast(i));
    const shift_amount = (31 - i_usize) * 8;
    break :blk (val >> @intCast(shift_amount)) & 0xFF;
};
frame.stack.set_top_unsafe(result);
```

**Performance Issues:**

- ❌ **Works on full u256**: evmone works on 64-bit words
- ✅ **Simpler logic**: Our version is actually cleaner
- **Recommendation**: Consider word-level access for very large shifts

### SHL (0x1b)

**evmone implementation:**

```cpp
inline void shl(StackTop stack) noexcept
{
    stack.top() <<= stack.pop();
}
```

**Guillotine implementation:**

```zig
const shift = frame.stack.pop_unsafe();
const value = frame.stack.peek_unsafe().*;
const result = if (shift >= 256) 0 else value << @intCast(shift);
frame.stack.set_top_unsafe(result);
```

**Performance Issues:**

- ❌ **Extra branching**: evmone handles >= 256 internally
- **Recommendation**: Use compound assignment if possible

### SHR (0x1c)

**evmone implementation:**

```cpp
inline void shr(StackTop stack) noexcept
{
    stack.top() >>= stack.pop();
}
```

**Guillotine implementation:**

```zig
const shift = frame.stack.pop_unsafe();
const value = frame.stack.peek_unsafe().*;
const result = if (shift >= 256) 0 else value >> @intCast(shift);
frame.stack.set_top_unsafe(result);
```

**Performance Issues:**

- ❌ **Same as SHL**: Extra branching
- **Recommendation**: Use compound assignment

### SAR (0x1d)

**evmone implementation:**

```cpp
inline void sar(StackTop stack) noexcept
{
    const auto& y = stack.pop();
    auto& x = stack.top();

    const bool is_neg = static_cast<int64_t>(x[3]) < 0;
    const auto sign_mask = is_neg ? ~uint256{} : uint256{};

    const auto mask_shift = (y < 256) ? (256 - y[0]) : 0;
    x = (x >> y) | (sign_mask << mask_shift);
}
```

**Guillotine implementation:**

```zig
const shift = frame.stack.pop_unsafe();
const value = frame.stack.peek_unsafe().*;
const result = if (shift >= 256) blk: {
    const sign_bit = value >> 255;
    break :blk if (sign_bit == 1) @as(u256, std.math.maxInt(u256)) else @as(u256, 0);
} else blk: {
    const shift_amount = @as(u8, @intCast(shift));
    const value_i256 = @as(i256, @bitCast(value));
    const result_i256 = value_i256 >> shift_amount;
    break :blk @as(u256, @bitCast(result_i256));
};
frame.stack.set_top_unsafe(result);
```

**Performance Issues:**

- ❌ **Type conversions**: Converting to i256 for arithmetic shift
- ❌ **Complex branching**: evmone's approach is more elegant
- **Recommendation**: Use mask-based approach like evmone

## Summary of Comparison & Bitwise Issues

1. **Unnecessary std.math.order usage** in LT/GT/SLT comparisons
2. **Not using in-place modifications** - Should modify stack top directly
3. **Missing compound assignments** - Not using &=, |=, ^=, <<=, >>=
4. **Type conversions in signed ops** - Could use more efficient approaches
5. **SAR implementation is overly complex** - evmone's mask approach is cleaner
6. **BYTE could use word-level access** for better performance on large indices

## Keccak256 Opcode

### KECCAK256 (0x20)

**evmone implementation:**

```cpp
inline Result keccak256(StackTop stack, int64_t gas_left, ExecutionState& state) noexcept
{
    const auto& index = stack.pop();
    auto& size = stack.top();

    if (!check_memory(gas_left, state.memory, index, size))
        return {EVMC_OUT_OF_GAS, gas_left};

    const auto i = static_cast<size_t>(index);
    const auto s = static_cast<size_t>(size);
    const auto w = num_words(s);
    const auto cost = w * 6;
    if ((gas_left -= cost) < 0)
        return {EVMC_OUT_OF_GAS, gas_left};

    auto data = s != 0 ? &state.memory[i] : nullptr;
    size = intx::be::load<uint256>(ethash::keccak256(data, s));
    return {EVMC_SUCCESS, gas_left};
}
```

**Guillotine implementation:**

```zig
const offset = try frame.stack.pop();
const size = try frame.stack.pop();

// Multiple bounds checks
if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
    return ExecutionError.Error.OutOfOffset;
}

// Special case for size 0
if (size == 0) {
    // Additional offset validation
    // Hardcoded empty hash
    const empty_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    try frame.stack.append(empty_hash);
    return Operation.ExecutionResult{};
}

// Gas calculation
const word_size = (size_usize + 31) / 32;
const gas_cost = 6 * word_size;
try frame.consume_gas(gas_cost);

// Memory handling
_ = try frame.memory.ensure_context_capacity(offset_usize + size_usize);
const data = try frame.memory.get_slice(offset_usize, size_usize);

// Tiered stack buffer optimization
const hash = hash_with_stack_buffer(data);
const result = std.mem.readInt(u256, &hash, .big);
try frame.stack.append(result);
```

**Performance Issues:**

- ❌ **Stack operations**: Using pop() for both values instead of modifying top
- ❌ **Multiple bounds checks**: Redundant checks for offset and size
- ❌ **Special case for size=0**: Complex logic for empty hash
- ❌ **Memory API differences**: Using ensure_context_capacity + get_slice vs direct access
- ✅ **Good**: Tiered stack buffer optimization for small inputs
- ❌ **Result handling**: Converting hash to u256 manually vs intx::be::load

**Optimization Opportunities:**

1. **Stack optimization**: Pop one, modify top like evmone
2. **Simplified bounds checking**: check_memory handles all cases
3. **Direct memory access**: Avoid extra API calls
4. **Empty hash handling**: Let keccak256 handle empty input naturally

**Tiered Buffer Analysis:**
The Guillotine implementation has an interesting optimization with tiered stack buffers:

- Small (≤64 bytes): Stack buffer - good for addresses
- Medium (≤256 bytes): Stack buffer - good for events
- Large (≤1024 bytes): Stack buffer - reasonable max
- Very large (>1024): Direct from memory

This is actually a **clever optimization** not present in evmone, potentially beneficial for common small inputs like addresses (20 bytes) and function selectors (4 bytes).

**Recommendation**: Keep the tiered buffer optimization but simplify the other aspects to match evmone's cleaner approach.

## Environment Opcodes

[Content from previous environment opcodes section]

## Block Opcodes

### BLOCKHASH (0x40)
**evmone implementation:**
```cpp
inline Result blockhash(StackTop stack, int64_t gas_left, ExecutionState& state) noexcept
{
    auto& number = stack.top();
    
    const auto upper_bound = state.get_tx_context().block_number;
    const auto lower_bound = (upper_bound >= 256) ? upper_bound - 256 : 0;
    const auto n = static_cast<uint64_t>(number);
    const auto header = (number < upper_bound && n >= lower_bound) ?
        state.host.get_block_hash(n) : evmc::bytes32{};
    number = intx::be::load<uint256>(header);
    return {EVMC_SUCCESS, gas_left};
}
```

**Guillotine implementation:**
```zig
const block_number = try frame.stack.pop();
const current_block = vm.context.block_number;

if (block_number >= current_block) {
    @branchHint(.unlikely);
    try frame.stack.append(0);
} else if (current_block > block_number + 256) {
    @branchHint(.unlikely);
    try frame.stack.append(0);
} else if (block_number == 0) {
    @branchHint(.unlikely);
    try frame.stack.append(0);
} else {
    // Pseudo-hash for testing
    const hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&block_number));
    try frame.stack.append(hash);
}
```

**Performance Issues:**
- ❌ **Stack operations**: Pop then push instead of modifying top
- ❌ **Multiple branches**: evmone uses cleaner conditional expression
- ❌ **Pseudo-hash implementation**: Not using actual block hash retrieval
- ✅ **Good**: Uses @branchHint for unlikely cases
- **Recommendation**: Modify stack top and simplify conditional logic

### COINBASE (0x41)
**evmone implementation:**
```cpp
inline void coinbase(StackTop stack, ExecutionState& state) noexcept
{
    stack.push(intx::be::load<uint256>(state.get_tx_context().block_coinbase));
}
```

**Guillotine implementation:**
```zig
try frame.stack.append(primitives.Address.to_u256(vm.context.block_coinbase));
```

**Performance Issues:**
- ✅ **Clean implementation**: Direct push
- **No significant issues**

### TIMESTAMP (0x42)
**evmone implementation:**
```cpp
inline void timestamp(StackTop stack, ExecutionState& state) noexcept
{
    stack.push(state.get_tx_context().block_timestamp);
}
```

**Guillotine implementation:**
```zig
try frame.stack.append(@as(u256, @intCast(vm.context.block_timestamp)));
```

**Performance Issues:**
- ✅ **Clean implementation**: Direct conversion and push
- **No significant issues**

### NUMBER (0x43)
**evmone implementation:**
```cpp
inline void number(StackTop stack, ExecutionState& state) noexcept
{
    stack.push(state.get_tx_context().block_number);
}
```

**Guillotine implementation:**
```zig
try frame.stack.append(@as(u256, @intCast(vm.context.block_number)));
```

**Performance Issues:**
- ✅ **Clean implementation**: Direct conversion and push
- **No significant issues**

### DIFFICULTY/PREVRANDAO (0x44)
**evmone implementation:**
```cpp
inline void difficulty(StackTop stack, ExecutionState& state) noexcept
{
    stack.push(intx::be::load<uint256>(state.get_tx_context().block_difficulty));
}
```

**Guillotine implementation:**
```zig
// DIFFICULTY
try frame.stack.append(vm.context.block_difficulty);

// PREVRANDAO (same as difficulty post-merge)
pub fn op_prevrandao(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    return op_difficulty(pc, interpreter, state);
}
```

**Performance Issues:**
- ✅ **Clean implementation**: Direct push
- ✅ **Good**: Correctly aliases PREVRANDAO to DIFFICULTY
- **No significant issues**

### GASLIMIT (0x45)
**evmone implementation:**
```cpp
inline void gaslimit(StackTop stack, ExecutionState& state) noexcept
{
    stack.push(state.get_tx_context().block_gas_limit);
}
```

**Guillotine implementation:**
```zig
try frame.stack.append(@as(u256, @intCast(vm.context.block_gas_limit)));
```

**Performance Issues:**
- ✅ **Clean implementation**: Direct conversion and push
- **No significant issues**

### BASEFEE (0x48)
**evmone implementation:**
```cpp
inline void basefee(StackTop stack, ExecutionState& state) noexcept
{
    stack.push(intx::be::load<uint256>(state.get_tx_context().block_base_fee));
}
```

**Guillotine implementation:**
```zig
try frame.stack.append(vm.context.block_base_fee);
```

**Performance Issues:**
- ✅ **Clean implementation**: Direct push
- **No significant issues**

### BLOBHASH (0x49)
**evmone implementation:**
```cpp
inline Result blobhash(StackTop stack, int64_t gas_left, ExecutionState& state) noexcept
{
    auto& index = stack.top();
    
    const auto tx_context = state.get_tx_context();
    const auto blob_hashes_count = tx_context.blob_hashes_count;
    if (blob_hashes_count == 0 || index >= blob_hashes_count)
    {
        index = 0;
    }
    else
    {
        const auto n = static_cast<size_t>(index);
        index = intx::be::load<uint256>(tx_context.blob_hashes[n]);
    }
    return {EVMC_SUCCESS, gas_left};
}
```

**Guillotine implementation:**
```zig
const index = try frame.stack.pop();

// EIP-4844: Get blob hash at index
if (index >= vm.context.blob_hashes.len) {
    @branchHint(.unlikely);
    try frame.stack.append(0);
} else {
    const idx = @as(usize, @intCast(index));
    try frame.stack.append(vm.context.blob_hashes[idx]);
}
```

**Performance Issues:**
- ❌ **Stack operations**: Pop then push instead of modifying top
- ✅ **Good**: Uses @branchHint for unlikely case
- **Recommendation**: Modify stack top in-place

### BLOBBASEFEE (0x4a)
**evmone implementation:**
```cpp
inline void blobbasefee(StackTop stack, ExecutionState& state) noexcept
{
    stack.push(intx::be::load<uint256>(state.get_tx_context().blob_base_fee));
}
```

**Guillotine implementation:**
```zig
try frame.stack.append(vm.context.blob_base_fee);
```

**Performance Issues:**
- ✅ **Clean implementation**: Direct push
- **No significant issues**

## Summary of Block Opcode Issues

1. **BLOCKHASH**: Pop/push pattern and multiple branches instead of cleaner conditional
2. **BLOBHASH**: Pop/push pattern instead of modifying stack top
3. **Pseudo-hash in BLOCKHASH**: Using Wyhash instead of actual block hash retrieval
4. **Most block opcodes are well-optimized**: Direct push operations with no issues

## Stack Opcodes

### POP (0x50)
**evmone implementation:**
```cpp
inline void pop(StackTop stack) noexcept
{
    stack.pop();
}
```

**Guillotine implementation:**
```zig
pub fn op_pop(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = state;
    _ = try frame.stack.pop();

    return Operation.ExecutionResult{};
}
```

**Performance Issues:**
- ✅ **Clean implementation**: Direct pop operation
- **No significant issues**

### PUSH0 (0x5f)
**evmone implementation:**
```cpp
inline void push0(StackTop stack) noexcept
{
    stack.push({});
}
```

**Guillotine implementation:**
```zig
try StackValidation.validateStackRequirements(0, 1, frame.stack.size());
frame.stack.append_unsafe(0);
```

**Performance Issues:**
- ❌ **Stack validation overhead**: Runtime validation vs compile-time
- **Recommendation**: Consider compile-time validation only

### PUSH1-PUSH32 (0x60-0x7f)
**evmone implementation:**
```cpp
template <uint8_t N>
inline void push(StackTop stack, ExecutionState& state) noexcept
{
    constexpr auto num_push_bytes = N;
    const auto src = &state.code[state.pc + 1];
    const auto data = intx::be::unsafe::load<intx::uint256>(src);
    stack.push(data >> (8 * (32 - num_push_bytes)));
}
```

**Guillotine implementation:**
```zig
// For PUSH1
const code = frame.contract.code;
const value: u256 = if (pc + 1 < code.len) code[pc + 1] else 0;
frame.stack.append_unsafe(value);

// For PUSH2-PUSH8 (optimized with u64)
var value: u64 = 0;
for (0..n) |i| {
    if (pc + 1 + i < code.len) {
        value = (value << 8) | code[pc + 1 + i];
    } else {
        value = value << 8;
    }
}
frame.stack.append_unsafe(@as(u256, value));

// For larger PUSH operations
var value: u256 = 0;
for (0..n) |i| {
    if (pc + 1 + i < code.len) {
        value = (value << 8) | code[pc + 1 + i];
    } else {
        value = value << 8;
    }
}
```

**Performance Issues:**
- ❌ **Loop-based byte loading**: evmone uses single intx::be::unsafe::load
- ❌ **Bounds checking in loop**: evmone assumes valid code layout
- ✅ **Good**: Optimized path for PUSH2-PUSH8 using u64
- **Recommendation**: Use single load operation for all PUSH sizes

### DUP1-DUP16 (0x80-0x8f)
**evmone implementation:**
```cpp
template <int N>
inline void dup(StackTop stack) noexcept
{
    static_assert(N >= 1 && N <= 16);
    stack.push(stack[N - 1]);
}
```

**Guillotine implementation:**
```zig
try StackValidation.validateStackRequirements(0, 1, frame.stack.size());

// Additional runtime check for DUP depth
if (frame.stack.size() < n) {
    @branchHint(.cold);
    return ExecutionError.Error.StackUnderflow;
}

frame.stack.dup_unsafe(n);
```

**Performance Issues:**
- ❌ **Runtime validation**: Stack validation at runtime
- ❌ **Additional underflow check**: evmone assumes valid stack state
- **Recommendation**: Remove runtime validation for performance

### SWAP1-SWAP16 (0x90-0x9f)
**evmone implementation:**
```cpp
template <int N>
inline void swap(StackTop stack) noexcept
{
    static_assert(N >= 1 && N <= 16);
    std::swap(stack.top(), stack[N]);
}
```

**Guillotine implementation:**
```zig
if (frame.stack.size() < n + 1) {
    unreachable;
}
frame.stack.swap_unsafe(n);
```

**Performance Issues:**
- ✅ **Good**: Uses unreachable for impossible condition
- ✅ **Clean implementation**: Direct swap operation
- **Minimal issues**

## Summary of Stack Opcode Issues

1. **PUSH operations use loops**: Should use single load like evmone's intx::be::unsafe::load
2. **Runtime stack validation**: Adds overhead compared to compile-time assumptions
3. **Bounds checking in PUSH loops**: evmone assumes valid bytecode
4. **DUP has extra validation**: Runtime checks that could be compile-time
5. **Overall stack operations are reasonable**: Main issue is PUSH byte loading

## Memory Opcodes

### MLOAD (0x51)
**evmone implementation:**
```cpp
inline Result mload(StackTop stack, int64_t gas_left, ExecutionState& state) noexcept
{
    auto& index = stack.top();
    if (!check_memory(gas_left, state.memory, index, 32))
        return {EVMC_OUT_OF_GAS, gas_left};
    index = intx::be::unsafe::load<uint256>(&state.memory[static_cast<size_t>(index)]);
    return {EVMC_SUCCESS, gas_left};
}
```

**Guillotine implementation:**
```zig
const offset = frame.stack.peek_unsafe().*;

// Check offset bounds
if (offset > std.math.maxInt(usize)) {
    return ExecutionError.Error.OutOfOffset;
}

// Calculate memory expansion gas cost
const new_size_u64 = @as(u64, @intCast(new_size));
const gas_cost = frame.memory.get_expansion_cost(new_size_u64);
try frame.consume_gas(gas_cost);

// Ensure memory is available
_ = try frame.memory.ensure_context_capacity(aligned_size);

// Read 32 bytes from memory
const value = try frame.memory.get_u256(offset_usize);
frame.stack.set_top_unsafe(value);
```

**Performance Issues:**
- ❌ **Separate gas calculation**: evmone's check_memory handles gas and bounds
- ❌ **Multiple API calls**: ensure_context_capacity + get_u256 vs direct access
- ✅ **Good**: Modifies stack top in-place
- **Recommendation**: Unified memory check like evmone

### MSTORE (0x52)
**evmone implementation:**
```cpp
inline Result mstore(StackTop stack, int64_t gas_left, ExecutionState& state) noexcept
{
    const auto& index = stack.pop();
    const auto& value = stack.pop();
    if (!check_memory(gas_left, state.memory, index, 32))
        return {EVMC_OUT_OF_GAS, gas_left};
    intx::be::unsafe::store(&state.memory[static_cast<size_t>(index)], value);
    return {EVMC_SUCCESS, gas_left};
}
```

**Guillotine implementation:**
```zig
const popped = frame.stack.pop2_unsafe();
const value = popped.a;
const offset = popped.b;

// Bounds check, gas calculation, memory expansion
// ... similar to MLOAD ...

// Write 32 bytes to memory (big-endian)
var bytes: [32]u8 = undefined;
std.mem.writeInt(u256, &bytes, value, .big);
try frame.memory.set_data(offset_usize, &bytes);
```

**Performance Issues:**
- ✅ **Good**: Uses pop2_unsafe for batch pop
- ❌ **Manual byte conversion**: evmone uses intx::be::unsafe::store
- ❌ **Intermediate buffer**: Creates 32-byte array vs direct write
- **Recommendation**: Direct memory write without intermediate buffer

### MSTORE8 (0x53)
**evmone implementation:**
```cpp
inline Result mstore8(StackTop stack, int64_t gas_left, ExecutionState& state) noexcept
{
    const auto& index = stack.pop();
    const auto& value = stack.pop();
    if (!check_memory(gas_left, state.memory, index, 1))
        return {EVMC_OUT_OF_GAS, gas_left};
    state.memory[static_cast<size_t>(index)] = static_cast<uint8_t>(value);
    return {EVMC_SUCCESS, gas_left};
}
```

**Guillotine implementation:**
```zig
// Similar pattern to MSTORE
const byte_value = @as(u8, @truncate(value));
const bytes = [_]u8{byte_value};
try frame.memory.set_data(offset_usize, &bytes);
```

**Performance Issues:**
- ❌ **Creates single-byte array**: evmone uses direct assignment
- ❌ **API call for single byte**: set_data vs direct memory access
- **Recommendation**: Direct byte assignment

### MSIZE (0x59)
**evmone implementation:**
```cpp
inline void msize(StackTop stack, ExecutionState& state) noexcept
{
    stack.push(state.memory.size());
}
```

**Guillotine implementation:**
```zig
const size = frame.memory.context_size();
const aligned_size = std.mem.alignForward(usize, size, 32);
frame.stack.append_unsafe(@as(u256, @intCast(aligned_size)));
```

**Performance Issues:**
- ✅ **Correct**: Properly aligns to 32-byte boundary
- ✅ **Clean implementation**
- **No significant issues**

### MCOPY (0x5e)
**evmone implementation:**
```cpp
inline Result mcopy(StackTop stack, int64_t gas_left, ExecutionState& state) noexcept
{
    const auto& dst_index = stack.pop();
    const auto& src_index = stack.pop(); 
    const auto& size = stack.pop();
    
    if (!check_memory(gas_left, state.memory, std::max(dst_index, src_index), size))
        return {EVMC_OUT_OF_GAS, gas_left};
        
    const auto dst = static_cast<size_t>(dst_index);
    const auto src = static_cast<size_t>(src_index);
    const auto n = static_cast<size_t>(size);
    
    if (const auto cost = copy_cost(n); (gas_left -= cost) < 0)
        return {EVMC_OUT_OF_GAS, gas_left};
        
    if (n > 0)
        std::memmove(&state.memory[dst], &state.memory[src], n);
        
    return {EVMC_SUCCESS, gas_left};
}
```

**Guillotine implementation:**
```zig
// Complex overlap detection
if (dest_usize > src_usize and dest_usize < src_usize + length_usize) {
    // Forward overlap: copy backwards
    std.mem.copyBackwards(...);
} else if (src_usize > dest_usize and src_usize < dest_usize + length_usize) {
    // Backward overlap: copy forwards
    std.mem.copyForwards(...);
} else {
    // No overlap
    std.mem.copyForwards(...);
}
```

**Performance Issues:**
- ❌ **Manual overlap detection**: evmone uses std::memmove which handles all cases
- ❌ **Multiple branches**: memmove is optimized for all overlap scenarios
- **Recommendation**: Use single memmove-equivalent function

## Summary of Memory Opcode Issues

1. **Separate gas calculations**: evmone's check_memory unifies bounds and gas checks
2. **Intermediate buffers**: MSTORE/MSTORE8 create temporary arrays
3. **API overhead**: Multiple memory API calls vs direct memory access
4. **MCOPY overlap handling**: Manual detection vs optimized memmove
5. **Overall reasonable but could be more direct**: Main issue is API abstraction overhead

## Overall Audit Summary

### Critical Correctness Issues
1. **ADDMOD is mathematically incorrect** - Doesn't handle overflow (a+b > 2^256)
2. **SUB has wrong operand order** - Computing b-a instead of a-b
3. **DIV has wrong operand order** - Computing b/a instead of a/b

### Major Performance Opportunities
1. **Stack operations**: Not using in-place modifications (modify top vs pop/push)
2. **PUSH operations**: Loop-based byte loading vs single load operation
3. **Memory API overhead**: Multiple calls vs direct memory access
4. **Type conversions**: Signed operations use many bitcasts
5. **Missing optimizations**: No compound assignments (+=, &=, etc.)

### Good Optimizations Already Present
1. **Tiered buffer optimization in KECCAK256**: Clever optimization for small inputs
2. **Branch hints**: Good use of @branchHint for unlikely cases
3. **Batch operations**: pop2_unsafe for efficient dual pops
4. **Special paths**: PUSH2-PUSH8 optimized with u64

### Recommendations Summary
1. **Fix critical bugs first**: ADDMOD, SUB, DIV operand order
2. **Implement in-place stack operations**: Modify top directly
3. **Use single load for PUSH**: Like evmone's intx::be::unsafe::load
4. **Simplify memory access**: Direct access vs API abstraction
5. **Consider specialized integer library**: For operations like addmod, mulmod

---

# Precompile Implementation Audit

## Overview

Comparing Guillotine's Zig precompile implementation (`src/evm/precompiles/`) with evmone's C++ implementation (`evmone/test/state/precompiles.cpp`).

## Key Architectural Differences

### 1. **Gas Calculation Strategy**

**evmone**: Inline gas calculation with immediate return
```cpp
PrecompileAnalysis sha256_analyze(bytes_view input, evmc_revision /*rev*/) noexcept
{
    return {cost_per_input_word<60, 12>(input.size()), 32};
}
```

**Guillotine**: Separate gas calculation functions with overflow checking
```zig
pub fn calculate_gas(input_size: usize) u64 {
    const word_count = GasConstants.wordCount(input_size);
    return SHA256_BASE_COST + SHA256_WORD_COST * word_count;
}

pub fn calculate_gas_checked(input_size: usize) !u64 {
    // Overflow checking logic...
}
```

**Performance Impact**: evmone's approach is more direct with less function call overhead. The separate overflow checking in Guillotine adds safety but at a performance cost for the common case.

### 2. **Precompile Dispatch**

**evmone**: Direct array indexing with traits
```cpp
inline constexpr std::array<PrecompileTraits, NumPrecompiles> traits{{
    {ecrecover_analyze, ecrecover_execute},
    {sha256_analyze, sha256_execute},
    // ...
}};

const auto [analyze, execute] = traits[id];
```

**Guillotine**: Union-based dispatch with comptime table
```zig
const PrecompileHandler = union(enum) {
    standard: PrecompileFn,
    with_chain_rules: PrecompileFnWithChainRules,
};

const PRECOMPILE_TABLE = blk: {
    var table: [10]?PrecompileHandler = .{null} ** 10;
    // ... populate table
};
```

**Performance Impact**: evmone's direct array indexing is simpler and likely faster than Guillotine's union dispatch which requires an additional switch.

### 3. **Memory Management**

**evmone**: Stack allocation for small buffers, direct output writing
```cpp
ExecutionResult sha256_execute(const uint8_t* input, size_t input_size, uint8_t* output,
    [[maybe_unused]] size_t output_size) noexcept
{
    crypto::sha256(reinterpret_cast<std::byte*>(output), 
                   reinterpret_cast<const std::byte*>(input), input_size);
    return {EVMC_SUCCESS, 32};
}
```

**Guillotine**: Generic template with intermediate buffers
```zig
var hash_buffer: [64]u8 = undefined; // Generous size for any hash
hash_fn(input, hash_buffer[0..]);
format_output(hash_buffer[0..], output);
```

**Performance Impact**: evmone writes directly to output, while Guillotine uses an intermediate buffer and formatting step, adding unnecessary copies.

### 4. **Input Parsing for Complex Precompiles**

**evmone (MODEXP)**: Direct unsafe loads with minimal copying
```cpp
const auto base_len256 = be::unsafe::load<uint256>(&input_header[0]);
const auto exp_len256 = be::unsafe::load<uint256>(&input_header[32]);
const auto mod_len256 = be::unsafe::load<uint256>(&input_header[64]);
```

**Guillotine (MODEXP)**: Function call for parsing
```zig
const base_len = parse_u256_to_usize(input[0..32]);
const exp_len = parse_u256_to_usize(input[32..64]);
const mod_len = parse_u256_to_usize(input[64..96]);
```

**Performance Impact**: evmone's unsafe loads are more direct, while Guillotine's function calls add overhead.

### 5. **Error Handling**

**evmone**: Simple status codes
```cpp
if (v != 27 && v != 28)
    return {EVMC_SUCCESS, 0};  // Return empty output for invalid input
```

**Guillotine**: Structured error types
```zig
return PrecompileOutput.failure_result(PrecompileError.OutOfGas);
```

**Performance Impact**: Guillotine's structured errors are cleaner but add slight overhead compared to evmone's simple status returns.

### 6. **Hardware Acceleration**

**Guillotine**: Explicit hardware acceleration usage
```zig
crypto.SHA256_Accel.SHA256_Accel.hash(input, &hash_output);
```

**evmone**: Library handles acceleration internally
```cpp
crypto::sha256(...);  // Library determines best implementation
```

**Performance Impact**: Both can use hardware acceleration, but evmone's approach may have better automatic selection.

## Performance Opportunities

### 1. **Direct Output Writing**
Eliminate intermediate buffers in hash precompiles. Write directly to output like evmone.

### 2. **Inline Gas Calculation**
Move simple gas calculations inline to reduce function call overhead.

### 3. **Simplify Dispatch**
Consider using simple array indexing instead of union-based dispatch.

### 4. **Unsafe Loads for Parsing**
Use direct memory loads for parsing fixed-size inputs in MODEXP and EC operations.

### 5. **Remove Generic Templates**
The `executeHashPrecompile` template adds complexity without clear performance benefit over direct implementations.

### 6. **Optimize Availability Checks**
Combine `is_precompile` and `is_available` checks to avoid redundant address comparisons.

## Good Design Choices in Guillotine

1. **Overflow Protection**: Explicit overflow checking in gas calculations
2. **Type Safety**: Structured error types provide better debugging
3. **Modularity**: Each precompile in its own file aids maintenance
4. **Hardware Acceleration**: Explicit use of hardware-accelerated implementations
5. **Compile-time Tables**: Precompile dispatch table built at compile time

## Recommendations for Precompiles

1. **Simplify hash precompiles** by removing generic template and writing directly to output
2. **Inline simple gas calculations** to reduce function call overhead
3. **Use unsafe loads** for parsing fixed-size integer inputs
4. **Consider simpler dispatch** mechanism using direct array indexing
5. **Combine availability checks** to reduce redundant operations
6. **Remove intermediate buffers** where possible
6. **Remove runtime validations**: Where compile-time assumptions suffice
