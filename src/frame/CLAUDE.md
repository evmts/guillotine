# CLAUDE.md - Frame Module

## MISSION CRITICAL: Execution Context Integrity
**Frame bugs cause execution errors, consensus failures, fund loss.**

### EVM Frame Specs
- **Call Depth**: Max 1024 nested calls
- **Context**: Isolated stack/memory/storage per frame
- **Gas**: Precise accounting and forwarding
- **Return Data**: Proper call return handling
- **Exceptions**: Correct revert/failure propagation

### Core Files
- `frame.zig` - Main execution frame
- `call_params.zig` - Call parameters/validation
- `call_result.zig` - Call result handling
- `frame_handlers.zig` - Opcode dispatch
- `frame_config.zig` - Configuration/limits

## Frame Lifecycle

**Creation (CRITICAL)**:
```zig
pub fn create_frame(allocator: std.mem.Allocator, call_params: CallParams, parent_frame: ?*Frame) !*Frame {
    const depth = if (parent_frame) |parent| parent.depth + 1 else 0;
    if (depth >= MAX_CALL_DEPTH) return FrameError.CallDepthExceeded;

    const frame = try allocator.create(Frame);
    errdefer allocator.destroy(frame);
    frame.* = Frame{ .depth = depth, .call_params = call_params, /* ... */ };
    return frame;
}
```

**Cleanup**:
```zig
pub fn destroy_frame(allocator: std.mem.Allocator, frame: *Frame) void {
    frame.stack.deinit(allocator);
    frame.memory.deinit(allocator);
    frame.* = undefined;
    allocator.destroy(frame);
}
```

## Call Management

**Types**: CALL, CALLCODE, DELEGATECALL, STATICCALL, CREATE, CREATE2

**Gas Forwarding (EIP-150)**:
```zig
pub fn forward_gas(available_gas: u64, requested_gas: u64) u64 {
    const max_forward = available_gas - (available_gas / 64); // 63/64 rule
    return @min(requested_gas, max_forward);
}
```

## Gas Accounting (CONSENSUS CRITICAL)
```zig
pub fn calculate_call_gas(frame: *Frame, call_type: CallType, to: Address, value: u256) u64 {
    var gas_cost: u64 = if (frame.storage.access_list.contains_address(to))
        WARM_ACCOUNT_ACCESS else COLD_ACCOUNT_ACCESS;

    if (value > 0) {
        gas_cost += CALL_VALUE_TRANSFER_GAS;
        if (!frame.storage.account_exists(to)) gas_cost += NEW_ACCOUNT_GAS;
    }
    return gas_cost;
}
```

## Static Call Enforcement
```zig
pub fn check_static_violation(frame: *Frame, opcode: u8) FrameError!void {
    if (frame.is_static) {
        switch (opcode) {
            0x54 => return FrameError.StateChangeInStaticContext, // SSTORE
            0xA0...0xA4 => return FrameError.StateChangeInStaticContext, // LOG*
            0xF1, 0xF2 => return FrameError.StateChangeInStaticContext, // CALL/CALLCODE
            0xFF => return FrameError.StateChangeInStaticContext, // SELFDESTRUCT
            else => {},
        }
    }
}
```

## Critical Safety
- Check call depth (1024 max)
- Validate gas limits before operations
- Enforce static context restrictions
- Proper resource cleanup
- Accurate gas refund tracking (EIP-3529: 1/5 limit)

## Performance & Testing
- **Optimization**: Minimize allocations, cache data, jump tables
- **Tests**: All call types, gas accounting, depth limits, static violations
- **Integration**: Complex call chains, error propagation, memory isolation

**Frame management is EVM execution backbone. Strict bounds checking and resource cleanup required.**