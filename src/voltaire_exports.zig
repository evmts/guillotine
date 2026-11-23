//! Lightweight src-rooted re-exports for Voltaire-dependent subsystem benchmarks
//! (storage, eips, layer2) without pulling in the full EVM dispatch graph.
pub const Stack = @import("stack/stack.zig").Stack;
pub const Database = @import("storage/database.zig").Database;
pub const Journal = @import("storage/journal.zig").Journal;
pub const AccessList = @import("storage/access_list.zig").AccessList;
pub const LruCache = @import("storage/lru_cache.zig").LruCache;
pub const Eips = @import("eips_and_hardforks/eips.zig").Eips;
pub const layer2 = @import("layer2/mod.zig");
