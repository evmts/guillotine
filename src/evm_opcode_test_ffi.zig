//! FFI bindings for opcode testing
//! This module provides a minimal interface for testing opcodes from external tools

const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

// Minimal FFI interface for opcode testing
export fn evm_opcode_test_version() u32 {
    return 1;
}

// Test harness placeholder
export fn evm_opcode_test_execute() i32 {
    return 0;
}