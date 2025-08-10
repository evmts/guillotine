## Review: evm/evm.zig (VM orchestration and lifecycle)

### High-signal findings

- Integrates `OpcodeMetadata` and `ChainRules` cleanly; arena allocator for temporaries is good for locality. Access list, journal, created contracts, and refunds are initialized with clear ownership.
- Analysis cache is pre-initialized and reused; good for repeated calls. Host methods delegate into state; emit_log path handles errors without panicking.

### Opportunities

- Replace debug prints in hot init paths with compile-time-gated logs; ensure no logs in ReleaseFast.
- Consider exposing a compact hot context for interpreter (pointers to stack/memory/metadata hot arrays) to minimize repeated derefs.
- Validate all allocs have `errdefer` until ownership moves; ensure frame stack arrays are consistently freed on reset/deinit.

### Action items

- [ ] Add comptime guards to logging (disable in ReleaseFast); audit for stray prints.
- [ ] Add tests that simulate early-error paths to assert no leaks (allocator counters if available).

### Comparison to evmone/revm

- Similar lifecycle orchestration; metadata integration and arena temp allocator should be competitive. Ensure minimal runtime logging and lean init for perf parity.


