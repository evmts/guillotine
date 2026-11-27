# Rules

Uphill writes these rules from each metric's `description`. Write code that meets them. `uphill` scores each metric against its target, and `uphill --compare HEAD --compact` lists what a change made worse.

## Safety & TigerStyle

Mission-critical EVM safety invariants from CLAUDE.md and TigerStyle across Zig and Rust FFI code.

- Never use @panic or unreachable in production src/**/*.zig; validate inputs and return typed errors instead.
- Never use std.debug.assert or std.debug.print in production src/**/*.zig; use tracer.assert() and log.zig.
- Never swallow errors with empty catch or return error.NotImplemented stubs in production src/**/*.zig.
- Add tracer.assert() invariant checks to production EVM functions to raise assertion density toward TigerStyle levels. At least 25.
- Replace .unwrap() and .expect() in Rust FFI crates (lib/ark, lib/foundry-compilers) with Result propagation.
- Minimize and encapsulate unsafe FFI blocks in lib/ark and lib/foundry-compilers behind safe wrappers. At most 1.

## Style & Limits

TigerStyle structural bounds (70-line functions, 120-char lines) and canonical Zig formatting.

- Keep all Zig files in src/ formatted with `zig fmt`.
- Keep every production Zig runtime function at or below 70 lines (TigerStyle limit); decompose large handlers. At most 70.
- Keep production Zig lines at or below 120 characters (TigerStyle limit).
- Resolve TODO, FIXME, XXX, and HACK markers in production src/**/*.zig instead of deferring work.

## Footprint & Modularity

Source file and subsystem modularity limits to keep the EVM auditable.

- Keep production Zig files focused and under 500 lines; split monolithic modules like src/evm.zig. At most 500.
- Keep each src/ subsystem compact and modular; split sprawling subsystems into cohesive packages. At most 80 kB.

## Verification & Tests

Formal verification proofs (Lean 4 & SMT-LIB2) and inline Zig unit test coverage.

- Never commit `sorry` or unproved `axiom` declarations in verify/lean/**/*.lean; close every formal proof.
- Expand Lean 4 theorem and lemma coverage in verify/lean/ for EVM opcodes, gas rules, and fusion passes. At least 100.
- Add SMT-LIB2 equivalence and overflow-safety proofs in verify/smt/proofs/ for arithmetic and fusion optimizations. At least 80.
- Add inline `test` blocks inside production src/**/*.zig files (CLAUDE.md requires tests in source files). At least 95.

## Documentation

Documentation link integrity and subsystem README coverage.

- Fix broken relative and root-relative links in root Markdown files and docs/**/*.md.
- Maintain a concise README.md in every production subsystem directory under src/.
