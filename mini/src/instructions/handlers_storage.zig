/// Storage opcode handlers for the EVM
const std = @import("std");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;

/// Handlers struct - provides storage operation handlers for a Frame type
/// The FrameType must have methods: consumeGas, popStack, pushStack, getEvm
/// and fields: pc, address, is_static
pub fn Handlers(FrameType: type) type {
    return struct {
        /// SLOAD opcode (0x54) - Load word from storage
        pub fn sload(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();
            const key = try frame.popStack();

            // EIP-2929: charge warm/cold storage access cost and warm the slot
            const access_cost = try evm.accessStorageSlot(frame.address, key);
            // Access cost already includes the full SLOAD gas cost (100 for warm, 2100 for cold)
            try frame.consumeGas(access_cost);

            const value = try evm.storage.get(frame.address, key);
            try frame.pushStack(value);
            frame.pc += 1;
        }

        /// SSTORE opcode (0x55) - Save word to storage
        pub fn sstore(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();

            // EIP-214: SSTORE cannot modify state in static call context
            if (frame.is_static) return error.StaticCallViolation;

            // EIP-2200 (Istanbul+): SSTORE sentry gas check
            // SSTORE requires at least GAS_CALL_STIPEND (2300) gas remaining
            if (evm.hardfork.isAtLeast(.ISTANBUL)) {
                if (frame.gas_remaining <= GasConstants.SstoreSentryGas) {
                    return error.OutOfGas;
                }
            }

            const key = try frame.popStack();
            const value = try frame.popStack();

            // Get current value for gas calculation
            const current_value = try evm.storage.get(frame.address, key);

            // Calculate gas cost based on hardfork
            const gas_cost = if (evm.hardfork.isAtLeast(.ISTANBUL)) blk: {
                // EIP-2200 (Istanbul+): Complex storage gas metering with dirty tracking
                const original_value = evm.storage.getOriginal(frame.address, key);

                // EIP-2929 (Berlin+): Check if storage slot is cold and warm it
                const access_cost = try evm.accessStorageSlot(frame.address, key);
                const is_cold = access_cost == GasConstants.ColdSloadCost;

                // Use EIP-2200/EIP-3529 logic with hardfork-aware gas costs
                const is_berlin_or_later = evm.hardfork.isAtLeast(.BERLIN);
                const is_istanbul_or_later = evm.hardfork.isAtLeast(.ISTANBUL);
                break :blk GasConstants.sstoreGasCostWithHardfork(
                    current_value,
                    original_value,
                    value,
                    is_cold,
                    is_berlin_or_later,
                    is_istanbul_or_later,
                );
            } else blk: {
                // Pre-Istanbul (Constantinople, Petersburg): Simple storage gas rules
                // If setting zero to non-zero: 20,000 gas
                // Otherwise: 5,000 gas
                break :blk if (current_value == 0 and value != 0)
                    GasConstants.SstoreSetGas // 20,000
                else
                    GasConstants.SstoreResetGas; // 5,000
            };

            try frame.consumeGas(gas_cost);

            // Refund logic (hardfork-dependent)
            if (evm.hardfork.isAtLeast(.ISTANBUL) and evm.hardfork.isBefore(.LONDON)) {
                // EIP-2200 (Istanbul-London): Complex net gas metering refund logic
                const original_value = evm.storage.getOriginal(frame.address, key);

                if (current_value != value) {
                    // Case 1: Clearing storage for the first time in the transaction
                    if (original_value != 0 and current_value != 0 and value == 0) {
                        evm.add_refund(15000); // GAS_STORAGE_CLEAR_REFUND
                    }

                    // Case 2: Reversing a previous clear (was cleared earlier, now non-zero)
                    if (original_value != 0 and current_value == 0) {
                        // Subtract the refund that was given earlier
                        if (evm.gas_refund >= 15000) {
                            evm.gas_refund -= 15000;
                        }
                    }

                    // Case 3: Restoring to original value
                    if (original_value == value) {
                        if (original_value == 0) {
                            // Slot was originally empty and was SET earlier (cost 20000)
                            // Now restored to 0, refund the difference: 20000 - 100 = 19900
                            evm.add_refund(20000 - 100); // GAS_STORAGE_SET - GAS_SLOAD
                        } else {
                            // Slot was originally non-empty and was UPDATED earlier (cost 5000)
                            // Now restored to original, refund: 5000 - 100 = 4900
                            evm.add_refund(5000 - 100); // GAS_STORAGE_UPDATE - GAS_SLOAD
                        }
                    }
                }
            } else if (evm.hardfork.isAtLeast(.LONDON)) {
                // EIP-3529 (London+): Refund logic matching Python cancun/vm/instructions/storage.py lines 106-124
                // IMPORTANT: All three refund cases are independent checks (not else-if), matching Python
                const original_value = evm.storage.getOriginal(frame.address, key);

                // Refund Counter Calculation (only when value changes)
                if (current_value != value) {
                    // Case 1: Clearing storage for the first time in the transaction (line 107-109)
                    if (original_value != 0 and current_value != 0 and value == 0) {
                        evm.add_refund(GasConstants.SstoreRefundGas); // 4,800 (GAS_STORAGE_CLEAR_REFUND)
                    }

                    // Case 2: Reversing a previous clear (line 111-113)
                    // This is a separate independent check, not else-if
                    if (original_value != 0 and current_value == 0) {
                        // Subtract the refund that was given earlier
                        if (evm.gas_refund >= GasConstants.SstoreRefundGas) {
                            evm.gas_refund -= GasConstants.SstoreRefundGas;
                        }
                    }

                    // Case 3: Restoring to original value (line 115-124)
                    // This is also a separate independent check, not else-if
                    if (original_value == value) {
                        if (original_value == 0) {
                            // Slot was originally empty and was SET earlier (cost 20000)
                            // Now restored to 0, refund: 20000 - 100 = 19900
                            evm.add_refund(GasConstants.SstoreSetGas - GasConstants.WarmStorageReadCost);
                        } else {
                            // Slot was originally non-empty and was UPDATED earlier
                            // Now restored to original, refund: 5000 - 2100 - 100 = 2800
                            evm.add_refund(GasConstants.SstoreResetGas - GasConstants.ColdSloadCost - GasConstants.WarmStorageReadCost);
                        }
                    }
                }
            } else {
                // Pre-Istanbul (Frontier-Constantinople-Petersburg): Simple clear refund
                if (current_value != 0 and value == 0) {
                    evm.add_refund(15000); // GAS_STORAGE_CLEAR_REFUND
                }
            }

            try evm.storage.set(frame.address, key, value);
            frame.pc += 1;
        }

        /// TLOAD opcode (0x5c) - Load word from transient storage (EIP-1153)
        pub fn tload(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();

            // EIP-1153: TLOAD was introduced in Cancun hardfork
            if (evm.hardfork.isBefore(.CANCUN)) return error.InvalidOpcode;

            try frame.consumeGas(GasConstants.TLoadGas);
            const key = try frame.popStack();
            const value = evm.storage.getTransient(frame.address, key);
            try frame.pushStack(value);
            frame.pc += 1;
        }

        /// TSTORE opcode (0x5d) - Save word to transient storage (EIP-1153)
        pub fn tstore(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();

            // EIP-1153: TSTORE was introduced in Cancun hardfork
            if (evm.hardfork.isBefore(.CANCUN)) return error.InvalidOpcode;

            // EIP-1153: TSTORE cannot modify state in static call context
            if (frame.is_static) return error.StaticCallViolation;

            try frame.consumeGas(GasConstants.TStoreGas);
            const key = try frame.popStack();
            const value = try frame.popStack();
            try evm.storage.setTransient(frame.address, key, value);
            frame.pc += 1;
        }
    };
}
