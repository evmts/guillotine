# ModExp arithmetic and gas calculation

`ModExp.modexp(allocator, base, exponent, modulus)` computes a modulus-sized,
big-endian result owned by the caller. A zero modulus is an arithmetic error;
the EVM precompile handles that case by returning zero-filled output.
The custom arithmetic remains unaudited.

`ModExp.calculateGas(base_len, exp_len, mod_len, exponent_head, hardfork)` uses
EIP-198 before Berlin, EIP-2565 from Berlin, and EIP-7883 from Osaka. The head
contains at most 32 right-padded exponent bytes. Gas saturates at `maxInt(u64)`.
Length enforcement belongs to the precompile.

The vendored implementation synchronizes the canonical Voltaire ModExp pricing,
padding, overflow-safe u64 multiplication, modulus-one behavior, odd-width
hexadecimal output handling, and regression vectors. The vendor retains its
existing zero-byte comparison because it does not contain canonical Voltaire's
`constant_time` module. This does not claim a constant-time implementation.

```zig
const std = @import("std");
const ModExp = @import("crypto").ModExp;
const Hardfork = @import("voltaire").Hardfork;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const result = try ModExp.modexp(allocator, &.{3}, &.{10}, &.{13});
    defer allocator.free(result);
    std.debug.assert(result[0] == 3);
    std.debug.assert(ModExp.calculateGas(1, 1, 1, &.{10}, Hardfork.OSAKA) == 500);
}
```
