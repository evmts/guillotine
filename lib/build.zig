const std = @import("std");

// Import individual library build configurations
pub const Bn254Lib = @import("bn254.zig");
pub const FoundryLib = @import("foundry.zig");

// Re-export the main functions for convenience
pub const createBn254Library = Bn254Lib.createBn254Library;
pub const createFoundryLibrary = FoundryLib.createFoundryLibrary;
pub const createRustBuildStep = FoundryLib.createRustBuildStep;