const std = @import("std");
const Opcode = @import("opcodes/opcode.zig");
const DynamicGasFunc = @import("instruction.zig").DynamicGasFunc;
const dynamic_gas = @import("gas/dynamic_gas.zig");

/// Get the dynamic gas function for a specific opcode
pub fn getDynamicGasFunction(opcode: Opcode.Enum) ?DynamicGasFunc {
    return switch (opcode) {
        .CALL => @ptrCast(&dynamic_gas.call_dynamic_gas),
        .CALLCODE => @ptrCast(&dynamic_gas.callcode_dynamic_gas),
        .DELEGATECALL => @ptrCast(&dynamic_gas.delegatecall_dynamic_gas),
        .STATICCALL => @ptrCast(&dynamic_gas.staticcall_dynamic_gas),
        .CREATE => @ptrCast(&dynamic_gas.create_dynamic_gas),
        .CREATE2 => @ptrCast(&dynamic_gas.create2_dynamic_gas),
        .SSTORE => @ptrCast(&dynamic_gas.sstore_dynamic_gas),
        .GAS => @ptrCast(&dynamic_gas.gas_dynamic_gas),
        else => null,
    };
}