# StaticDatabase Integration Issue

## Problem Summary

PR #751 attempted to fix EIP-214 static context enforcement but was rejected because it added runtime branching to hot paths that hurts performance. The PR added explicit `if (evm.get_is_static())` checks in handlers, which is inefficient.

## The Rejected Approach

The rejected PR added runtime checks in handlers:

```zig
// In handlers_storage.zig:82-85 (REJECTED approach)
if (evm.get_is_static()) {
    return Error.WriteProtection;
}
```

This approach is problematic because:
1. **Performance Impact**: Adds branching to every storage operation and LOG emission
2. **Runtime Overhead**: Checks happen in hot paths during execution
3. **Poor Design**: Mixes concerns - handlers shouldn't check execution context

## The Existing Solution: StaticDatabase

There's already a proper solution implemented in `src/storage/static_wrappers.zig` (lines 27-189):

### What StaticDatabase Provides

1. **Type-Level Guarantees**: Encodes static context constraints in the type system
2. **Zero Runtime Branching**: No runtime checks in hot paths  
3. **Clean Separation**: Database wrapper handles permissions, not handlers
4. **Complete EIP-214 Compliance**: Prevents all state modifications

### StaticDatabase Implementation

The `StaticDatabase` wrapper:
- Returns `PermissionDenied` errors for all write operations
- Forwards read operations to the underlying database
- Provides compile-time safety without runtime overhead

Key methods that return errors in static context:
- `set_storage()` - Prevents SSTORE
- `set_transient_storage()` - Prevents TSTORE  
- `create_contract()` - Prevents CREATE/CREATE2
- `self_destruct()` - Prevents SELFDESTRUCT
- `insert_account()` - Prevents account creation
- `set_code()` - Prevents code modification

## The Current Bug: Missing StaticDatabase Usage

### Storage Operations
The EVM correctly tracks static context in `call_stack[].is_static` but **doesn't wrap the database with StaticDatabase** when entering STATICCALL contexts. This allows SSTORE and TSTORE operations to succeed when they should fail.

### LOG Operations
LOG operations (LOG0-LOG4) are also incorrectly allowed in static contexts. The handlers in `handlers_log.zig` directly call `evm.emit_log()` without any static context validation. The `emit_log` method itself doesn't check static context either.

## The Correct Solution

Instead of runtime branching in handlers, the EVM should:

1. **When entering STATICCALL**: Wrap the database with `StaticDatabase`
2. **For LOG operations**: Either:
   - Add a `StaticHost` wrapper that prevents `emit_log()` calls, OR
   - Make `emit_log()` check the database type and fail for `StaticDatabase`
3. **Handlers remain unchanged**: No branching, just call operations normally
4. **Type system enforces safety**: Compile-time guarantees, runtime performance

### Implementation Location

In `src/evm.zig` when processing STATICCALL:
```zig
// Pseudo-code for the fix
fn execute_staticcall(self: *Self, params: CallParams) !CallResult {
    // Wrap database for static context
    var static_db = StaticDatabase.init(self.database);
    
    // Create frame with static database
    var frame = Frame.init(..., &static_db, ...);
    
    // Execute - all writes will fail with PermissionDenied
    return frame.execute();
}
```

For LOG operations, we need a similar pattern:
```zig
// Either wrap the host interface
var static_host = StaticHost.init(self.host);
// OR check in emit_log if database is StaticDatabase type
```

## Why This Matters

1. **Performance**: No branching in hot paths = better performance
2. **Correctness**: Type-level guarantees = compile-time safety
3. **Maintainability**: Clean separation of concerns
4. **EVM Compliance**: Proper EIP-214 implementation

## Related Links

- **Rejected PR**: #751 - Added runtime branching (performance issue)
- **StaticDatabase Implementation**: `src/storage/static_wrappers.zig:27-189`
- **EIP-214 Specification**: [EIP-214: STATICCALL opcode](https://eips.ethereum.org/EIPS/eip-214)

## Action Items

1. Remove runtime static context checks from handlers
2. Implement StaticDatabase wrapping in EVM for STATICCALL
3. Add static context handling for LOG operations (via StaticHost or database type checking)
4. Update tests to verify StaticDatabase prevents all state modifications including LOGs
5. Ensure no performance regression from runtime branching