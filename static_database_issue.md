# StaticDatabase Implementation Not Working - Needs Integration

## Problem

The existing `StaticDatabase` implementation that was designed to handle EIP-214 static context enforcement is not currently integrated or working properly. This was discovered during PR #751 where branching was added to storage handlers for static context checks, which was rejected due to performance concerns.

## Background

PR #751 attempted to fix EIP-214 compliance by adding runtime checks in the storage handlers:
- Added `if (evm.is_static_context())` checks before SSTORE operations
- Similar checks for LOG operations
- This introduced unnecessary branching in hot paths, hurting performance

## Existing Solution - StaticDatabase

A better solution already exists in the codebase at [`src/storage/static_wrappers.zig`](https://github.com/evmts/guillotine/blob/main/src/storage/static_wrappers.zig):

The `StaticDatabase` wrapper implementation:
- Returns `Database.Error.PermissionDenied` for all write operations
- Forwards read operations to the underlying database
- Provides type-level guarantees without runtime branching
- Located at lines 27-189 in `static_wrappers.zig`

Key characteristics:
- All write methods (`set_storage`, `set_account`, `set_transient_storage`, etc.) return `PermissionDenied`
- All read methods forward to the underlying database
- Also includes a `StaticHost` wrapper for host operations

## The Issue

The `StaticDatabase` exists but is not being used when executing STATICCALL operations. Currently:
1. The EVM tracks static context in `call_stack[].is_static`
2. Handlers check this flag at runtime (causing branching)
3. The `StaticDatabase` wrapper is defined but not instantiated/used

## Required Fix

Instead of runtime checks, the EVM should:
1. When entering a STATICCALL context, wrap the database with `StaticDatabase`
2. Pass this wrapped database to the frame/handlers
3. Remove all `is_static_context()` checks from handlers
4. Let the database wrapper handle permission enforcement

This would:
- Eliminate branching in hot paths
- Provide compile-time guarantees where possible
- Follow data-oriented design principles
- Improve performance

## References

- PR #751: https://github.com/evmts/guillotine/pull/751
- StaticDatabase implementation: [`src/storage/static_wrappers.zig:27-189`](https://github.com/evmts/guillotine/blob/main/src/storage/static_wrappers.zig#L27-L189)
- Review comment rejecting runtime branching: https://github.com/evmts/guillotine/pull/751#discussion_r1755935850

## Action Items

- [ ] Integrate `StaticDatabase` wrapper when entering STATICCALL contexts
- [ ] Remove runtime `is_static_context()` checks from handlers
- [ ] Update frame execution to use the wrapped database
- [ ] Test that EIP-214 compliance is maintained without performance regression