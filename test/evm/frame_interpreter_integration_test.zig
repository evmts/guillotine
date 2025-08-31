const std = @import("std");
const frame_interpreter = @import("frame_interpreter.zig");
const evm = @import("evm.zig");
const database_interface = @import("database_interface.zig");
const memory_database = @import("memory_database.zig");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const host_mod = @import("host.zig");
const CallParams = @import("call_params.zig").CallParams;
const CallResult = @import("call_result.zig").CallResult;
const block_info = @import("block_info.zig");
const transaction_context = @import("transaction_context.zig");
const Hardfork = @import("hardfork.zig").Hardfork;

// Test addresses
const TEST_ADDRESS: Address = [_]u8{0x01} ** 20;
const DEPLOYER_ADDRESS: Address = [_]u8{0x02} ** 20;
const NEW_CONTRACT_ADDRESS: Address = [_]u8{0x03} ** 20;

// Custom host implementation that simulates real CREATE behavior
const TestHost = struct {
    allocator: std.mem.Allocator,
    evm: *evm.Evm(evm.DefaultEvmConfig),
    create_count: usize = 0,
    created_addresses: std.ArrayList(Address),
    
    pub fn init(allocator: std.mem.Allocator, evm_instance: *evm.Evm(evm.DefaultEvmConfig)) TestHost {
        return .{
            .allocator = allocator,
            .evm = evm_instance,
            .created_addresses = std.ArrayList(Address).init(allocator),
        };
    }
    
    pub fn deinit(self: *TestHost) void {
        self.created_addresses.deinit();
    }
    
    pub fn get_balance(self: *TestHost, address: Address) u256 {
        return self.evm.get_balance(address);
    }
    
    pub fn account_exists(self: *TestHost, address: Address) bool {
        return self.evm.account_exists(address);
    }
    
    pub fn get_code(self: *TestHost, address: Address) []const u8 {
        return self.evm.get_code(address);
    }
    
    pub fn get_block_info(self: *TestHost) block_info.DefaultBlockInfo {
        return self.evm.context.block_info;
    }
    
    pub fn emit_log(self: *TestHost, contract_address: Address, topics: []const u256, data: []const u8) void {
        _ = self;
        _ = contract_address;
        _ = topics;
        _ = data;
        // For testing, we just ignore logs
    }
    
    pub fn inner_call(self: *TestHost, params: CallParams) !CallResult {
        self.create_count += 1;
        
        // For CREATE operations, simulate deployment
        if (params.isCreate()) {
            const create_params = params.create;
            
            // Calculate deterministic address for testing
            var new_address = NEW_CONTRACT_ADDRESS;
            new_address[19] = @intCast(self.create_count);
            
            try self.created_addresses.append(new_address);
            
            // Deploy empty contract for testing
            try self.evm.database.set_account(new_address, .{
                .nonce = 1,
                .balance = create_params.value,
                .code_hash = [_]u8{0} ** 32,
                .code = &[_]u8{}, // Empty deployed code
            });
            
            // Return the created address
            var result_data = try self.allocator.alloc(u8, 20);
            @memcpy(result_data, &new_address);
            
            return CallResult{
                .success = true,
                .gas_left = create_params.gas / 2, // Simulate some gas usage
                .output = result_data,
            };
        }
        
        // For other call types, return empty success
        return CallResult{
            .success = true,
            .gas_left = params.getGas() / 2,
            .output = &[_]u8{},
        };
    }
    
    // Implement remaining required methods with stubs
    pub fn register_created_contract(self: *TestHost, address: Address) !void {
        _ = self;
        _ = address;
    }
    
    pub fn was_created_in_tx(self: *TestHost, address: Address) bool {
        _ = self;
        _ = address;
        return false;
    }
    
    pub fn create_snapshot(self: *TestHost) u32 {
        _ = self;
        return 0;
    }
    
    pub fn revert_to_snapshot(self: *TestHost, snapshot_id: u32) void {
        _ = self;
        _ = snapshot_id;
    }
    
    pub fn record_storage_change(self: *TestHost, address: Address, slot: u256, original_value: u256) !void {
        _ = self;
        _ = address;
        _ = slot;
        _ = original_value;
    }
    
    pub fn get_original_storage(self: *TestHost, address: Address, slot: u256) ?u256 {
        _ = self;
        _ = address;
        _ = slot;
        return null;
    }
    
    pub fn access_address(self: *TestHost, address: Address) !u64 {
        _ = self;
        _ = address;
        return 2600; // Cold access cost
    }
    
    pub fn access_storage_slot(self: *TestHost, contract_address: Address, slot: u256) !u64 {
        _ = self;
        _ = contract_address;
        _ = slot;
        return 2100; // Cold storage access cost
    }
    
    pub fn mark_for_destruction(self: *TestHost, contract_address: Address, recipient: Address) !void {
        _ = self;
        _ = contract_address;
        _ = recipient;
    }
    
    pub fn get_input(self: *TestHost) []const u8 {
        _ = self;
        return &.{};
    }
    
    pub fn is_hardfork_at_least(self: *TestHost, target: Hardfork) bool {
        _ = self;
        _ = target;
        return true;
    }
    
    pub fn get_hardfork(self: *TestHost) Hardfork {
        _ = self;
        return .CANCUN;
    }
    
    pub fn get_is_static(self: *TestHost) bool {
        _ = self;
        return false;
    }
    
    pub fn get_depth(self: *TestHost) u11 {
        _ = self;
        return 1;
    }
    
    pub fn get_storage(self: *TestHost, address: Address, slot: u256) u256 {
        return self.evm.get_storage(address, slot);
    }
    
    pub fn set_storage(self: *TestHost, address: Address, slot: u256, value: u256) !void {
        try self.evm.set_storage(address, slot, value);
    }
    
    pub fn get_gas_price(self: *TestHost) u256 {
        _ = self;
        return 20_000_000_000; // 20 gwei
    }
    
    pub fn get_return_data(self: *TestHost) []const u8 {
        _ = self;
        return &.{};
    }
    
    pub fn get_chain_id(self: *TestHost) u16 {
        _ = self;
        return 1;
    }
    
    pub fn get_block_hash(self: *TestHost, block_number: u64) ?[32]u8 {
        _ = self;
        _ = block_number;
        return [_]u8{0} ** 32;
    }
    
    pub fn get_blob_hash(self: *TestHost, index: u256) ?[32]u8 {
        _ = self;
        _ = index;
        return null;
    }
    
    pub fn get_blob_base_fee(self: *TestHost) u256 {
        _ = self;
        return 0;
    }
    
    pub fn to_host(self: *TestHost) host_mod.Host {
        return host_mod.Host.init(self);
    }
};

test "Frame interpreter CREATE integration - deploy simple contract" {
    const allocator = std.testing.allocator;
    
    // Set up EVM instance
    var memory_db = memory_database.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm_instance = try evm.Evm(evm.DefaultEvmConfig).init(
        allocator,
        db_interface,
        block_info.DefaultBlockInfo{
            .chain_id = 1,
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = Address{0} ** 20,
            .base_fee = 1_000_000_000,
            .prev_randao = [_]u8{0} ** 32,
        },
        transaction_context.TransactionContext{
            .nonce = 0,
            .gas_price = 20_000_000_000,
            .gas_limit = 1_000_000,
            .to = null,
            .value = 0,
            .data = &[_]u8{},
            .chain_id = 1,
            .origin = DEPLOYER_ADDRESS,
            .blob_hashes = &[_][32]u8{},
            .max_fee_per_blob_gas = null,
        },
        20_000_000_000,
        DEPLOYER_ADDRESS,
        .CANCUN,
    );
    defer evm_instance.deinit();
    
    // Set up deployer account with balance
    try evm_instance.database.set_account(DEPLOYER_ADDRESS, .{
        .nonce = 1,
        .balance = 1_000_000_000_000_000_000, // 1 ETH
        .code_hash = [_]u8{0} ** 32,
        .code = &[_]u8{},
    });
    
    // Set up test host
    var test_host = TestHost.init(allocator, &evm_instance);
    defer test_host.deinit();
    
    // Bytecode that deploys a simple contract
    // PUSH1 5 (init code size)
    // PUSH1 0 (offset) 
    // PUSH1 0 (value)
    // CREATE
    // STOP
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xf0,       // CREATE
        0x00,       // STOP
    };
    
    // Store init code in memory first (simple contract that returns empty code)
    // This would be done by previous opcodes in a real scenario
    
    const FrameInterpreterType = frame_interpreter.FrameInterpreter(.{});
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 500_000, void{}, null);
    defer interpreter.deinit(allocator);
    
    // Set the host
    interpreter.frame.host = test_host.to_host();
    interpreter.frame.contract_address = DEPLOYER_ADDRESS;
    
    // Store some init code in memory for CREATE to use
    const init_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xF3 }; // PUSH1 0 PUSH1 0 RETURN
    try interpreter.frame.memory.set_data(0, &init_code);
    
    // Execute
    try interpreter.interpret();
    
    // Verify results
    try std.testing.expectEqual(@as(usize, 1), test_host.create_count);
    try std.testing.expectEqual(@as(usize, 1), test_host.created_addresses.items.len);
    
    // Check that contract was deployed
    const deployed_address = test_host.created_addresses.items[0];
    try std.testing.expect(evm_instance.account_exists(deployed_address));
    
    // Stack should have the deployed contract address
    const stack_result = interpreter.frame.stack.peek_unsafe();
    const expected_addr = primitives.Address.to_u256(deployed_address);
    try std.testing.expectEqual(expected_addr, stack_result);
    
    // Verify gas was consumed
    try std.testing.expect(interpreter.frame.gas_remaining < 500_000);
}

test "Frame interpreter CREATE integration - with value transfer" {
    const allocator = std.testing.allocator;
    
    // Set up EVM instance
    var memory_db = memory_database.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm_instance = try evm.Evm(evm.DefaultEvmConfig).init(
        allocator,
        db_interface,
        block_info.DefaultBlockInfo{
            .chain_id = 1,
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = Address{0} ** 20,
            .base_fee = 1_000_000_000,
            .prev_randao = [_]u8{0} ** 32,
        },
        transaction_context.TransactionContext{
            .nonce = 0,
            .gas_price = 20_000_000_000,
            .gas_limit = 1_000_000,
            .to = null,
            .value = 0,
            .data = &[_]u8{},
            .chain_id = 1,
            .origin = DEPLOYER_ADDRESS,
            .blob_hashes = &[_][32]u8{},
            .max_fee_per_blob_gas = null,
        },
        20_000_000_000,
        DEPLOYER_ADDRESS,
        .CANCUN,
    );
    defer evm_instance.deinit();
    
    // Set up deployer account with balance
    try evm_instance.database.set_account(DEPLOYER_ADDRESS, .{
        .nonce = 1,
        .balance = 1_000_000_000_000_000_000, // 1 ETH
        .code_hash = [_]u8{0} ** 32,
        .code = &[_]u8{},
    });
    
    // Set up test host
    var test_host = TestHost.init(allocator, &evm_instance);
    defer test_host.deinit();
    
    // Bytecode that deploys contract with 1000 wei value
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x61, 0x03, 0xE8, // PUSH2 1000 (value)
        0xf0,       // CREATE
        0x00,       // STOP
    };
    
    const FrameInterpreterType = frame_interpreter.FrameInterpreter(.{});
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 500_000, void{}, null);
    defer interpreter.deinit(allocator);
    
    interpreter.frame.host = test_host.to_host();
    interpreter.frame.contract_address = DEPLOYER_ADDRESS;
    
    // Execute
    try interpreter.interpret();
    
    // Verify contract was created with value
    const deployed_address = test_host.created_addresses.items[0];
    const deployed_balance = evm_instance.get_balance(deployed_address);
    try std.testing.expectEqual(@as(u256, 1000), deployed_balance);
}