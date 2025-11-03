/// Shared storage instruction implementations
/// Phase 4 - Generic over FrameType, no static gas charging, no PC manipulation
///
/// Source of truth: guillotine-mini/src/instructions/handlers_storage.zig
/// These implementations access persistent and transient storage
///
/// NOTE: These are STUBS requiring EVM integration (Phase 12)
/// Real implementation needs: frame.getEvm().storage, frame.getEvm().accessStorageSlot()

const std = @import("std");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;

/// SLOAD opcode (0x54) - Load word from storage
/// Note: This is a STUB - requires EVM integration
/// Caller must charge warm/cold access cost (accessStorageSlot)
pub fn SloadInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const key = try frame.stack.pop();

            // TODO: Real implementation (Phase 12):
            // const evm = frame.getEvm();
            // const access_cost = try evm.accessStorageSlot(frame.address, key);
            // try frame.consumeGas(access_cost);
            // const value = try evm.storage.get(frame.address, key);

            // Stub: Return 0 for all storage slots
            _ = key;
            const value: u256 = 0;

            try frame.stack.push(value);
        }
    };
}

/// SSTORE opcode (0x55) - Save word to storage
/// Note: This is a STUB - requires EVM integration
/// Caller must:
/// - Check is_static (EIP-214: cannot modify in static context)
/// - Check gas_remaining > SstoreSentryGas (EIP-2200, Istanbul+)
/// - Charge complex hardfork-aware gas cost
/// - Handle refund logic (EIP-2200, EIP-3529)
pub fn SstoreInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            // TODO: EIP-214 check (Phase 12)
            // if (frame.is_static) return error.StaticCallViolation;

            // TODO: EIP-2200 sentry check (Phase 12)
            // if (hardfork.isAtLeast(.ISTANBUL)) {
            //     if (frame.gas_remaining <= GasConstants.SstoreSentryGas) {
            //         return error.OutOfGas;
            //     }
            // }

            const key = try frame.stack.pop();
            const value = try frame.stack.pop();

            // TODO: Real implementation (Phase 12):
            // const evm = frame.getEvm();
            // const current_value = try evm.storage.get(frame.address, key);
            // const original_value = evm.storage.getOriginal(frame.address, key);
            // const access_cost = try evm.accessStorageSlot(frame.address, key);
            //
            // Calculate hardfork-aware gas cost:
            // - Berlin+: EIP-2929 cold/warm + EIP-2200/3529 logic
            // - Istanbul-London: EIP-2200 dirty tracking
            // - Pre-Istanbul: Simple set/reset (20k/5k)
            //
            // Handle refund logic:
            // - London+: EIP-3529 (4800 gas clear refund, restore refunds)
            // - Istanbul-London: EIP-2200 (15000 gas clear refund, restore refunds)
            // - Pre-Istanbul: Simple 15000 gas clear refund
            //
            // try evm.storage.set(frame.address, key, value);

            // Stub: Do nothing
            _ = key;
            _ = value;
        }
    };
}

/// TLOAD opcode (0x5c) - Load word from transient storage (EIP-1153, Cancun+)
/// Note: This is a STUB - requires EVM integration
/// Transient storage is cleared at end of transaction (not call)
pub fn TloadInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            // EIP-1153: TLOAD was introduced in Cancun hardfork
            if (frame.hardfork.isBefore(.CANCUN)) return error.InvalidOpcode;

            // Transient storage is always warm (100 gas, not 2100)
            try frame.consumeGas(GasConstants.TLoadGas); // 100

            const key = try frame.stack.pop();

            // TODO: Real implementation (Phase 12):
            // const evm = frame.getEvm();
            // const value = evm.storage.getTransient(frame.address, key);

            // Stub: Return 0 for all transient slots
            _ = key;
            const value: u256 = 0;

            try frame.stack.push(value);
        }
    };
}

/// TSTORE opcode (0x5d) - Save word to transient storage (EIP-1153, Cancun+)
/// Note: This is a STUB - requires EVM integration
/// Transient storage is cleared at end of transaction (not call)
pub fn TstoreInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            // EIP-1153: TSTORE was introduced in Cancun hardfork
            if (frame.hardfork.isBefore(.CANCUN)) return error.InvalidOpcode;

            // TODO: EIP-1153 check (Phase 12)
            // if (frame.is_static) return error.StaticCallViolation;

            // Transient storage is always warm (100 gas, not 2100)
            try frame.consumeGas(GasConstants.TStoreGas); // 100

            const key = try frame.stack.pop();
            const value = try frame.stack.pop();

            // TODO: Real implementation (Phase 12):
            // const evm = frame.getEvm();
            // try evm.storage.setTransient(frame.address, key, value);

            // Stub: Do nothing
            _ = key;
            _ = value;
        }
    };
}
