const std = @import("std");
const EvmModule = @import("../evm.zig");
const EvmConfig = @import("../config.zig").EvmConfig;
const ExecutionError = @import("../execution/execution_error.zig");
const CallResult = @import("call_result.zig").CallResult;
const CallParams = @import("../host.zig").CallParams;
const primitives = @import("primitives");
const Log = @import("../log.zig");

/// Generate all EVM methods for a specific configuration
pub fn methods(comptime config: EvmConfig) type {
    return struct {
        const EvmType = EvmModule.Evm(config);

        // Import the actual implementations
        const call_impl = @import("call.zig").call(config);

        // Export the methods with the correct signatures
        pub const call = call_impl.callImpl;

        // call_contract
        pub fn call_contract(self: *EvmType, caller: primitives.Address.Address, to: primitives.Address.Address, value: u256, input: []const u8, gas: u64, is_static: bool) !CallResult {
            return @import("call_contract.zig").call_contract(self, caller, to, value, input, gas, is_static);
        }

        // staticcall_contract
        pub fn staticcall_contract(self: *EvmType, caller: primitives.Address.Address, to: primitives.Address.Address, input: []const u8, gas: u64) !CallResult {
            return @import("staticcall_contract.zig").staticcall_contract(self, caller, to, input, gas);
        }

        // execute_precompile_call
        pub fn execute_precompile_call(self: *EvmType, to: primitives.Address.Address, input: []const u8, gas: u64, is_static: bool) !CallResult {
            return @import("execute_precompile_call.zig").execute_precompile_call(self, to, input, gas, is_static);
        }

        pub fn execute_precompile_call_by_id(self: *EvmType, precompile_id: u8, input: []const u8, gas: u64, is_static: bool) !CallResult {
            return @import("execute_precompile_call.zig").execute_precompile_call_by_id(self, precompile_id, input, gas, is_static);
        }

        // set_context
        pub fn set_context(self: *EvmType, context: @import("../access_list/context.zig").Context) void {
            return @import("set_context.zig").set_context(self, context);
        }

        // validate_static_context
        pub fn validate_static_context(self: *const EvmType) ExecutionError.Error!void {
            return @import("validate_static_context.zig").validate_static_context(self);
        }

        // set_storage_protected
        pub fn set_storage_protected(self: *EvmType, address: primitives.Address.Address, key: primitives.StorageKey.StorageKey, value: u256) !void {
            return @import("set_storage_protected.zig").set_storage_protected(self, address, key, value);
        }

        // set_transient_storage_protected
        pub fn set_transient_storage_protected(self: *EvmType, address: primitives.Address.Address, key: primitives.StorageKey.StorageKey, value: u256) !void {
            return @import("set_transient_storage_protected.zig").set_transient_storage_protected(self, address, key, value);
        }

        // set_balance_protected
        pub fn set_balance_protected(self: *EvmType, address: primitives.Address.Address, balance: u256) !void {
            return @import("set_balance_protected.zig").set_balance_protected(self, address, balance);
        }

        // set_code_protected
        pub fn set_code_protected(self: *EvmType, address: primitives.Address.Address, code: []const u8) !void {
            return @import("set_code_protected.zig").set_code_protected(self, address, code);
        }

        // emit_log_protected
        pub fn emit_log_protected(self: *EvmType, address: primitives.Address.Address, topics: []u256, data: []const u8) !void {
            return @import("emit_log_protected.zig").emit_log_protected(self, address, topics, data);
        }

        // validate_value_transfer
        pub fn validate_value_transfer(self: *const EvmType, value: u256) ExecutionError.Error!void {
            return @import("validate_value_transfer.zig").validate_value_transfer(self, value);
        }

        // selfdestruct_protected
        pub fn selfdestruct_protected(self: *EvmType, contract: primitives.Address.Address, beneficiary: primitives.Address.Address) !void {
            return @import("selfdestruct_protected.zig").selfdestruct_protected(self, contract, beneficiary);
        }

        // require_one_thread
        pub fn require_one_thread(self: *EvmType) void {
            return @import("require_one_thread.zig").require_one_thread(self);
        }

        // interpret
        pub fn interpret(self: *EvmType, frame: *@import("../frame.zig").Frame) !void {
            return @import("interpret.zig").interpret(self, frame);
        }
    };
}
