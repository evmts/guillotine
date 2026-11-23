//! Lightweight src-rooted re-exports for pure-Zig subsystem benchmarks
//! that need relative imports inside src/ without pulling in Rust/FFI deps.
pub const Stack = @import("stack/stack.zig").Stack;
pub const Memory = @import("memory/memory.zig").Memory;
pub const Bytecode = @import("bytecode/bytecode.zig").Bytecode;
pub const RingBuffer = @import("tracer/ring_buffer.zig").RingBuffer;
