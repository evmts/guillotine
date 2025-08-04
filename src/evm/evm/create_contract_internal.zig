const std = @import("std");
const primitives = @import("primitives");
const Contract = @import("../frame/contract.zig");
const ExecutionError = @import("../execution/execution_error.zig");
const CreateResult = @import("create_result.zig").CreateResult;
const Keccak256 = std.crypto.hash.sha3.Keccak256;
const opcode = @import("../opcodes/opcode.zig");
const Log = @import("../log.zig");
const Vm = @import("../evm.zig");

pub fn create_contract_internal(self: *Vm, creator: primitives.Address.Address, value: u256, init_code: []const u8, gas: u64, new_address: primitives.Address.Address) (std.mem.Allocator.Error || @import("../state/database_interface.zig").DatabaseError || ExecutionError.Error)!CreateResult {
    Log.debug("VM.create_contract_internal: Creating contract from {any} to {any}, value={}, gas={}", .{ creator, new_address, value, gas });
    if (self.state.get_code(new_address).len > 0) {
        @branchHint(.unlikely);
        // Contract already exists at this address - fail
        return CreateResult.init_failure(gas, null);
    }

    const creator_balance = self.state.get_balance(creator);
    if (creator_balance < value) {
        @branchHint(.unlikely);
        // Insufficient balance - fail
        return CreateResult.init_failure(gas, null);
    }

    if (value > 0) {
        try self.state.set_balance(creator, creator_balance - value);
        try self.state.set_balance(new_address, value);
    }

    if (init_code.len == 0) {
        // No init code means empty contract
        return CreateResult{
            .success = true,
            .address = new_address,
            .gas_left = gas,
            .output = null,
        };
    }

    var init_contract = Contract.init_deployment(
        creator, // caller (who is creating this contract)
        value, // value being sent to this contract
        gas, // gas available for init code execution
        init_code, // the init code to execute
        null, // no salt for CREATE (only for CREATE2)
    );
    init_contract.address = new_address; // Set the computed address
    defer init_contract.deinit(self.allocator, null);

    // Execute the init code - this should return the deployment bytecode
    Log.debug("create_contract_internal: Executing init code, size: {}", .{init_code.len});
    const init_result = self.interpret(&init_contract, &[_]u8{}, false) catch |err| {
        Log.debug("Init code execution failed with error: {}", .{err});
        if (err == ExecutionError.Error.REVERT) {
            // On revert, consume partial gas
            return CreateResult.init_failure(init_contract.gas, null);
        }

        // Most initcode failures should return 0 address and consume all gas
        return CreateResult.init_failure(0, null);
    };

    Log.debug("create_contract_internal: Init code execution completed: status={}, gas_used={}, output_size={}, output_ptr={any}", .{
        init_result.status,
        init_result.gas_used,
        if (init_result.output) |o| o.len else 0,
        init_result.output,
    });

    // Check if init code reverted
    if (init_result.status == .Revert) {
        Log.debug("create_contract_internal: Init code reverted, contract creation failed", .{});
        return CreateResult.init_failure(init_result.gas_left, init_result.output);
    }

    const deployment_code = init_result.output orelse &[_]u8{};

    if (deployment_code.len == 0) {
        Log.debug("create_contract_internal: WARNING: Init code returned empty deployment code! init_result.output={any}", .{init_result.output});
    } else {
        Log.debug("create_contract_internal: Got deployment code, size={}", .{deployment_code.len});
    }

    // Check EIP-170 MAX_CODE_SIZE limit on the returned bytecode (24,576 bytes)
    if (deployment_code.len > opcode.MAX_CODE_SIZE) {
        return CreateResult.init_failure(0, null);
    }

    const deploy_code_gas = @as(u64, @intCast(deployment_code.len)) * opcode.DEPLOY_CODE_GAS_PER_BYTE;

    if (deploy_code_gas > init_result.gas_left) {
        return CreateResult.init_failure(0, null);
    }

    try self.state.set_code(new_address, deployment_code);
    Log.debug("Contract code deployed at {any}, size: {}", .{ new_address, deployment_code.len });

    const gas_left = init_result.gas_left - deploy_code_gas;

    Log.debug("Contract creation successful! Address: {any}, gas_left: {}", .{ new_address, gas_left });

    return CreateResult{
        .success = true,
        .address = new_address,
        .gas_left = gas_left,
        .output = deployment_code,
    };
}
