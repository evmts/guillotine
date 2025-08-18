//! Memory subsystem package for the EVM
//!
//! This module re-exports all memory-related functionality including:
//! - Core memory implementation with checkpointing
//! - Memory constants and gas calculations
//! - Read/write operations with bounds checking
//! - Error types for memory operations

/// Main memory implementation
pub const memory = @import("./memory.zig");

// Re-export individual modules for direct access if needed
pub const constants = @import("constants.zig");
pub const errors = @import("errors.zig");
pub const read = @import("read.zig");
pub const write = @import("write.zig");
pub const slice = @import("slice.zig");
