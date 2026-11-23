# C SDK tests

Run from the repository root:

```sh
make -f sdks/c/Makefile simple
make -f sdks/c/Makefile basic
make -f sdks/c/Makefile test
```

`simple_test.c` compiles the public header and checks inline array widths,
byte-sized enum representations, and common 64-bit layouts. It does not load
the library or prove native execution.

`basic_test.c` links the shared native library and exercises initialization,
EVM creation/destruction, balances, contract execution, CREATE deployment
with deployed-code readback, trace JSON (tracing handles only), and revert
output with a bounded error string.
`basic` builds `zig build shared` first; `test` runs both programs. Native
crypto dependencies must be built for the selected target.

For other architectures, compare all struct sizes, alignment, and field offsets
against the Zig `extern struct` declarations, not just the common 64-bit sizes.
See [Building custom SDKs](../../../docs/building-custom-sdks.md) for the ABI,
ownership rules, and the repository's required build/opcode checks.
