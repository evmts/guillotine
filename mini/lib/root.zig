//! Library test aggregator
//! This file imports all library tests

const std = @import("std");

test {
    // Library modules with external dependencies are tested through integration tests
    // This file is kept as a placeholder for future library tests that don't have
    // external module dependencies.
    
    // Currently all library modules have external dependencies:
    // - blst.zig, bn254.zig, c-kzg.zig, foundry.zig depend on build config
    // - foundry-compilers modules depend on src/log.zig
    // - revm modules depend on missing revm.zig
    
    // These are tested through integration tests instead.
}