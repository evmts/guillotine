# GHCCC Implementation Report

## Objective
Implement the `ghccc` (GHC calling convention) in Zig to optimize the EVM interpreter's tail call performance, similar to the `preserve_none` calling convention that enabled 2+ GB/s protobuf parsing.

## What Was Accomplished

### 1. Successfully Modified Zig Fork
- Created a fork at `github.com/evmts/zig` with ghccc support
- Added `x86_64_ghccc` and `aarch64_ghccc` calling conventions to Zig's standard library
- Mapped these to LLVM's `ghccc` in the codegen layer
- Changes are in the `ghccc-llvm20` branch

### 2. Updated All Instruction Handlers
- Modified all instruction handlers in `src/instructions/` to use the new calling convention
- Created `getInterpreterCallConv()` function in `frame.zig` for centralized calling convention control
- Currently returns `.auto` for compatibility with standard Zig

### 3. Created Build Infrastructure
- Developed `scripts/build_zig_and_project.sh` to build custom Zig from source
- Script handles LLVM/LLD detection and configuration
- Ready to use once Zig compilation succeeds

## What Failed

### 1. Version Compatibility Issues
- Latest Zig requires LLVM 21, but only LLVM 20 is available in Homebrew
- Attempted to use older Zig version compatible with LLVM 20
- Hit API incompatibilities between Zig's C++ code and LLVM 20's headers

### 2. Compilation Errors
```
- DiagnosticsEngine constructor signature mismatch
- TextDiagnosticPrinter constructor signature mismatch  
- createAsmStreamer API changes
- Missing err_drv_print_header_env_var_invalid_format diagnostic
```

## Technical Insights

### Why GHCCC Matters for Interpreters
The ghccc calling convention:
- Has NO callee-saved registers (all registers are caller-saved)
- Maximizes available registers for code generation
- Reduces register spilling in hot interpreter loops
- Enables efficient tail call optimization

### Implementation Strategy
The approach was correct:
1. Add calling convention to Zig's builtin types
2. Map to LLVM's backend in codegen
3. Apply to all interpreter dispatch functions
4. Use tail calls for opcode chaining

### Code Changes Made

#### In `lib/zig/lib/std/builtin.zig`:
```zig
pub const ghccc: CallingConvention = switch (builtin.target.cpu.arch) {
    .x86_64 => .{ .x86_64_ghccc = .{} },
    .aarch64, .aarch64_be => .{ .aarch64_ghccc = .{} },
    else => @compileError("ghccc not supported on this architecture"),
};
```

#### In `lib/zig/src/codegen/llvm.zig`:
```zig
.x86_64_ghccc => .ghccc,
.aarch64_ghccc => .ghccc,
```

#### In `src/frame/frame.zig`:
```zig
pub inline fn getInterpreterCallConv() std.builtin.CallingConvention {
    // TODO: Once we're using the custom Zig build with ghccc support,
    // uncomment the following lines:
    // const builtin = @import("builtin");
    // return switch (builtin.target.cpu.arch) {
    //     .x86_64 => .{ .x86_64_ghccc = .{} },
    //     .aarch64, .aarch64_be => .{ .aarch64_ghccc = .{} },
    //     else => .auto,
    // };
    return .auto;
}
```

## Next Steps to Complete Implementation

### Option 1: Wait for LLVM 21
- Wait for Homebrew to package LLVM 21
- Use the existing ghccc-llvm20 branch as-is
- Build should work once LLVM 21 is available

### Option 2: Fix Zig's LLVM 20 Compatibility
- Debug and fix the C++ API incompatibilities
- Update `zig_clang_driver.cpp` and `zig_clang_cc1as_main.cpp`
- Requires deep knowledge of LLVM/Clang internals

### Option 3: Use LLVM IR Post-Processing
- Build with standard Zig
- Post-process LLVM IR to change calling conventions
- More fragile but doesn't require custom Zig

### Option 4: Use Inline Assembly
- Implement custom calling convention using inline assembly
- Manual register management
- Platform-specific implementations needed

## Performance Impact (Theoretical)
Based on the protobuf parsing article:
- Could potentially double interpreter performance
- Reduces function call overhead to near zero
- Enables better CPU branch prediction
- Maximizes register utilization in hot paths

## Conclusion
The implementation strategy was sound and most of the work is complete. The blocker is the mismatch between Zig's requirements (LLVM 21) and available tools (LLVM 20). The infrastructure is in place and ready to use once this version mismatch is resolved.

All instruction handlers have been updated to use the new calling convention infrastructure, so once a working Zig compiler with ghccc support is available, it's a simple matter of:
1. Building Zig with `./scripts/build_zig_and_project.sh`
2. Updating `getInterpreterCallConv()` to return ghccc
3. Running benchmarks to measure the performance improvement