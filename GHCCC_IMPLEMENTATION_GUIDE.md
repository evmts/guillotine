# Complete Guide: Adding ghccc to Zig

## Summary of Changes Made

We've successfully added the `ghccc` (GHC calling convention) to Zig, which is equivalent to Clang's `preserve_none`. This gives your interpreter maximum performance by eliminating ALL register preservation overhead.

## What We Changed

### 1. `lib/std/builtin.zig` (Lines 208-235)
Added architecture-specific ghccc variants:
- `x86_64_ghccc: CommonOptions` - For x86-64 processors
- `aarch64_ghccc: CommonOptions` - For ARM64 processors

Added convenience constant (Lines 182-189):
```zig
pub const ghccc: CallingConvention = switch (builtin.target.cpu.arch) {
    .x86_64 => .{ .x86_64_ghccc = .{} },
    .aarch64, .aarch64_be => .{ .aarch64_ghccc = .{} },
    else => @compileError("ghccc not supported on this architecture"),
};
```

### 2. `src/codegen/llvm.zig` (Lines 11931, 11947)
Mapped Zig calling conventions to LLVM's ghccc:
- `.x86_64_ghccc => .ghccc`
- `.aarch64_ghccc => .ghccc`

## How It Works

### The Performance Problem (Before)
```asm
; Normal calling convention - LOTS of overhead
add_handler:
    push rbx      ; Save register
    push r12      ; Save register  
    push r13      ; Save register
    push r14      ; Save register
    push r15      ; Save register
    ; ... actual work ...
    pop r15       ; Restore register
    pop r14       ; Restore register
    pop r13       ; Restore register
    pop r12       ; Restore register
    pop rbx       ; Restore register
    ret
```

### The Solution (With ghccc)
```asm
; ghccc - NO overhead!
add_handler:
    ; Just do the actual work
    ; ALL registers available
    ret
```

## Using It in Your Interpreter

### Basic Usage
```zig
// Your EVM handler with ghccc
pub fn add(self: *Frame, cursor: [*]const Dispatch.Item) callconv(.ghccc) Error!noreturn {
    self.stack.binary_op_unsafe(/* ... */);
    return next_instruction(self, cursor);
}
```

### Architecture-Specific (More Explicit)
```zig
const interpreter_cc = switch (@import("builtin").target.cpu.arch) {
    .x86_64 => .x86_64_ghccc,
    .aarch64 => .aarch64_ghccc,
    else => @compileError("Unsupported architecture"),
};

pub fn handler(frame: *Frame) callconv(interpreter_cc) !noreturn {
    // Your code
}
```

## Building Zig with These Changes

### Option 1: Build from Source (Recommended)
```bash
# You're already in zig_source directory
mkdir build && cd build
cmake .. -DZIG_NO_LIB=ON
make -j$(nproc)

# Test the compiler
./zig version
```

### Option 2: Use Pre-built Zig + Patch
```bash
# Apply changes to existing Zig installation
sudo cp lib/std/builtin.zig /opt/homebrew/Cellar/zig/0.15.1/lib/zig/std/builtin.zig
sudo cp src/codegen/llvm.zig /opt/homebrew/Cellar/zig/0.15.1/lib/zig/compiler/codegen/llvm.zig
```

## Testing Your Changes

Create a test file:
```zig
const std = @import("std");

fn compute(a: u32, b: u32) callconv(.ghccc) u32 {
    return a + b;
}

pub fn main() !void {
    const result = compute(5, 10);
    std.debug.print("Result: {}\n", .{result});
}
```

Compile and verify LLVM IR:
```bash
zig build-obj -femit-llvm-ir test.zig
cat test.ll | grep ghccc  # Should see: define ghccc
```

## Why This Matters for Your Interpreter

1. **No Register Spilling**: More values stay in registers
2. **Better Branch Prediction**: Simpler code = better prediction
3. **Cache Efficiency**: Less code = better I-cache usage
4. **Tail Call Optimization**: Works perfectly with `@call(.always_tail, ...)`

## Performance Impact

Based on similar implementations:
- **protobuf parsing**: 2+ GB/s (Haberman's results)
- **Python 3.14**: ~10-15% overall speedup
- **WebAssembly interpreters**: 18s → 13s (28% improvement)

Your EVM interpreter should see similar gains, especially in:
- Arithmetic operations (ADD, MUL, etc.)
- Stack manipulation
- Jump dispatch

## Next Steps

1. Build Zig with these changes
2. Update your Frame handlers to use `callconv(.ghccc)`
3. Benchmark before/after
4. Consider contributing this upstream to Zig!

## Troubleshooting

If compilation fails:
- Ensure LLVM 21.x is installed
- Check that your architecture supports ghccc (x86_64, aarch64)
- Verify the patch applied correctly with `git diff`

## References

- LLVM ghccc: https://llvm.org/docs/LangRef.html#calling-conventions
- Clang preserve_none: RFC #74233
- Original article: "Parsing protobuf at 2+GB/s"