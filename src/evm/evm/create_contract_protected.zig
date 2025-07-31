const primitives = @import("primitives");
const CreateResult = @import("create_result.zig").CreateResult;
const Vm = @import("../evm.zig");
const ValidateStaticContextError = @import("validate_static_context.zig").ValidateStaticContextError;
const CreateContractError = @import("create_contract.zig").CreateContractError;

pub const CreateContractProtectedError = ValidateStaticContextError || CreateContractError;

/// Create a contract with static context protection.
/// Prevents contract creation during static calls.
pub fn create_contract_protected(self: *Vm, creator: primitives.Address.Address, value: u256, init_code: []const u8, gas: u64) CreateContractProtectedError!CreateResult {
    try self.validate_static_context();
    return self.create_contract(self.allocator, creator, value, init_code, gas);
}
