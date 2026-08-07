# ModExp precompile (0x05)

Input consists of three 32-byte, big-endian operand lengths followed by base,
exponent and modulus. Missing bytes are right-padded with zero. The result has
exactly the declared modulus length, including when the modulus is zero.

Osaka activates EIP-7823: each declared operand may contain at most 1,024 bytes.
The bound is checked before any empty-output shortcut. EIP-7883 charges at least
500 gas, uses complexity 16 through 32 bytes or twice the squared eight-byte
word count above that, and adds sixteen iterations per exponent byte after 32.
The exponent head contributes `max(bitLength(head) - 1, 0)` iterations.

Berlin through Prague retain EIP-2565's 200-gas minimum; older forks use EIP-198.
Insufficient gas or oversized Osaka operands cause exceptional call failure and
consume the entire forwarded gas budget. `MIN_GAS_OSAKA` and
`MAX_INPUT_LENGTH_OSAKA` expose the new constants.

```zig
const std = @import("std");
const precompiles = @import("precompiles");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const result = try precompiles.modexp.execute(allocator, &.{}, 500, .OSAKA);
    defer result.deinit(allocator);
    std.debug.assert(result.output.len == 0);
    std.debug.assert(result.gas_used == 500);
}
```

The vendor is synchronized from canonical Voltaire's ModExp implementation,
with imports adapted to the older module name. The dispatcher retains active
precompiles through successor forks, including Osaka. The STATICCALL regression
in `test/evm/opcodes/fa_test.zig` exercises both full and reference interpreters,
with fusion enabled and disabled.
