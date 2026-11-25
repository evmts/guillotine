# C SDK tests

Run from the repository root:

```sh
make -f sdks/c/Makefile simple
make -f sdks/c/Makefile basic
make -f sdks/c/Makefile safety
make -f sdks/c/Makefile test    # simple, basic, and safety
```

`simple_test.c` compiles the public header and checks inline array widths,
byte-sized enum representations, and 64-bit struct sizes and offsets. It does
not load the library or prove native execution.

`basic_test.c` links the shared library and exercises initialization, handle
creation and destruction, balances, contract execution, CREATE deployment
with deployed-code readback, trace JSON from tracing handles, and revert
output with a bounded error string.

`safety_test.c` is the conformance reference for language bindings. It checks
that NULL, foreign, destroyed, and cleaned-up handles are rejected without a
crash; invalid configuration bytes return NULL; double destroy is reported;
each handle has isolated state; ORIGIN matches the caller in both
`guillotine_call` and `guillotine_simulate`; test-mode and tracing handles
work through the unsuffixed functions; repeated large calls and invalid
bytecode do not grow resident memory; and chain ids 1, 8453, 84532, and
11155111 either round-trip through CHAINID or are rejected with
`exceeds the supported maximum`.

`basic` and `safety` run `zig build shared` first. Native crypto
dependencies must be available for the selected target.

For other architectures, compare all struct sizes, alignment, and field
offsets against the Zig `extern struct` declarations, not only the 64-bit
sizes. See [Building custom SDKs](../../../docs/building-custom-sdks.md) for
the ABI and ownership rules.
