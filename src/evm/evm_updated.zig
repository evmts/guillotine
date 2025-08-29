//! Transaction-level EVM execution and state management.
//!
//! The EVM orchestrates contract execution, managing:
//! - Call depth tracking and nested execution contexts
//! - State journaling for transaction reverts
//! - Gas accounting and metering
//! - Contract creation (CREATE/CREATE2)
//! - Cross-contract calls (CALL/DELEGATECALL/STATICCALL)
//! - Integration with Host interface for environment queries
//!
//! This module provides the entry point for all EVM operations,
//! coordinating between Frames, the Planner, and state storage.
//!
//! The EVM utilizes Planners to analyze bytecode and produce optimized execution data structures
//! The EVM utilizes the Frame struct to track the evm state and implement all low level execution details
//! EVM passes itself as a host to the Frame so Frame can get data from EVM that is not on frame and execute inner calls
const std = @import("std");
const primitives = @import("primitives");
const BlockInfo = @import("block_info.zig").DefaultBlockInfo; // Default for backward compatibility
const DatabaseInterface = @import("database_interface.zig").DatabaseInterface;
const Account = @import("database_interface_account.zig").Account;
const SelfDestruct = @import("self_destruct.zig").SelfDestruct;
const CreatedContracts = @import("created_contracts.zig").CreatedContracts;
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
const AccessList = @import("access_list.zig").AccessList;
const Hardfork = @import("hardfork.zig").Hardfork;
const precompiles = @import("precompiles.zig");
const EvmConfig = @import("evm_config.zig").EvmConfig;
const TransactionContext = @import("transaction_context.zig").TransactionContext;
pub const CallResult: type = @import("call_result.zig").CallResult;
pub const CallParams: type = @import("call_params.zig").CallParams;
const log = @import("log.zig");

/// Creates a configured EVM instance type.
///
/// The EVM is parameterized by compile-time configuration for optimal
/// performance and minimal runtime overhead. Configuration controls
/// stack size, memory limits, call depth, and optimization strategies.
pub fn Evm(comptime config: EvmConfig) type {
    return struct {
        const Self = @This();

        /// Frame type for the evm (NEW: using stack_frame.zig)
        pub const Frame = @import("stack_frame.zig").Frame(config.frame_config);
        /// Planner/preanalysis processes the bytecode for the interpreter
        pub const Planner: type = @import("planner.zig").Planner(.{
            .WordType = config.frame_config.WordType,
            .maxBytecodeSize = config.frame_config.max_bytecode_size,
            .stack_size = config.frame_config.stack_size,
        });
        /// Journal handles reverting state when state needs to be reverted
        pub const Journal: type = @import("journal.zig").Journal(.{
            .SnapshotIdType = if (config.max_call_depth <= 255) u8 else u16,
            .WordType = config.frame_config.WordType,
            .NonceType = u64,
            .initial_capacity = 128,
        });

        /// Call stack entry to track caller and value for DELEGATECALL
        const CallStackEntry = struct {
            caller: primitives.Address,
            value: config.frame_config.WordType,
        };

        pub const Success = enum {
            Stop,
            Return,
            SelfDestruct,
            Jump, // Added for fusion support
        };

        pub const Error = error{
            InvalidJump,
            OutOfGas,
            StackUnderflow,
            StackOverflow,
            ContractNotFound,
            PrecompileError,
            MemoryError,
            StorageError,
            CallDepthExceeded,
            InsufficientBalance,
            ContractCollision,
            InvalidBytecode,
            StaticCallViolation,
            InvalidOpcode,
            RevertExecution,
            OutOfMemory,
            // Removed Stop error - it's a success case
            AllocationError,
            AccountNotFound,
            InvalidJumpDestination,
            MissingJumpDestMetadata,
            InitcodeTooLarge,
            TruncatedPush,
            OutOfBounds,
            WriteProtection,
            BytecodeTooLarge,
        };

        // CACHE LINE 1 - HOT PATH (frequently accessed during execution)
        /// Current call depth (0 = root call)
        depth: config.get_depth_type(),
        /// Current snapshot ID for the active call frame
        current_snapshot_id: Journal.SnapshotIdType,
        /// Database interface for state storage
        database: DatabaseInterface,
        /// Journal for tracking state changes and snapshots
        journal: Journal,
        /// Allocator for dynamic memory
        allocator: std.mem.Allocator,

        // CACHE LINE 2 - TRANSACTION EXECUTION STATE
        /// Access list for tracking warm/cold access (EIP-2929)
        access_list: AccessList,
        /// Tracks contracts created in current transaction (EIP-6780)
        created_contracts: CreatedContracts,
        /// Contracts marked for self-destruction
        self_destruct: SelfDestruct,
        /// Current call input data
        current_input: []const u8,
        /// Current return data
        return_data: []const u8,

        // CACHE LINE 3 - TRANSACTION CONTEXT
        /// Block information
        block_info: BlockInfo,
        /// Transaction context
        context: TransactionContext,
        /// Gas price for the transaction
        gas_price: u256,
        /// Origin address (sender of the transaction)
        origin: primitives.Address,
        /// Active EIPs configuration
        eips: EipsConfig,
        /// Disable gas checking (for testing/debugging)
        disable_gas_checking: bool,

        // CACHE LINE 4+ - COLD PATH (less frequently accessed)
        /// Planner instance for bytecode analysis and optimization
        planner: Planner,
        /// Logs emitted during the current call
        logs: std.ArrayList(@import("call_result.zig").Log),
        /// Static context stack - tracks if each call depth is static
        static_stack: [config.max_call_depth]bool,
        /// Call stack - tracks caller and value for each call depth
        call_stack: [config.max_call_depth]CallStackEntry,
        /// Arena allocator for per-call temporary allocations
        call_arena: std.heap.ArenaAllocator,
        /// Small reusable buffer for fixed-size outputs (e.g., 32-byte address)
        small_output_buf: [64]u8 = undefined,

        /// EIPs configuration based on hardfork
        const EipsConfig = struct {
            eip_2929: bool, // Access list
            eip_3541: bool, // 0xEF prefix
            eip_3855: bool, // PUSH0
            eip_3860: bool, // Initcode size limit
            eip_4844: bool, // Blob transactions
            eip_5656: bool, // MCOPY
            eip_6780: bool, // SELFDESTRUCT changes

            pub fn fromHardfork(fork: Hardfork) EipsConfig {
                return switch (fork) {
                    .FRONTIER => .{
                        .eip_2929 = false,
                        .eip_3541 = false,
                        .eip_3855 = false,
                        .eip_3860 = false,
                        .eip_4844 = false,
                        .eip_5656 = false,
                        .eip_6780 = false,
                    },
                    .HOMESTEAD => .{
                        .eip_2929 = false,
                        .eip_3541 = false,
                        .eip_3855 = false,
                        .eip_3860 = false,
                        .eip_4844 = false,
                        .eip_5656 = false,
                        .eip_6780 = false,
                    },
                    .TANGERINE_WHISTLE => .{
                        .eip_2929 = false,
                        .eip_3541 = false,
                        .eip_3855 = false,
                        .eip_3860 = false,
                        .eip_4844 = false,
                        .eip_5656 = false,
                        .eip_6780 = false,
                    },
                    .SPURIOUS_DRAGON => .{
                        .eip_2929 = false,
                        .eip_3541 = false,
                        .eip_3855 = false,
                        .eip_3860 = false,
                        .eip_4844 = false,
                        .eip_5656 = false,
                        .eip_6780 = false,
                    },
                    .BYZANTIUM => .{
                        .eip_2929 = false,
                        .eip_3541 = false,
                        .eip_3855 = false,
                        .eip_3860 = false,
                        .eip_4844 = false,
                        .eip_5656 = false,
                        .eip_6780 = false,
                    },
                    .CONSTANTINOPLE => .{
                        .eip_2929 = false,
                        .eip_3541 = false,
                        .eip_3855 = false,
                        .eip_3860 = false,
                        .eip_4844 = false,
                        .eip_5656 = false,
                        .eip_6780 = false,
                    },
                    .PETERSBURG => .{
                        .eip_2929 = false,
                        .eip_3541 = false,
                        .eip_3855 = false,
                        .eip_3860 = false,
                        .eip_4844 = false,
                        .eip_5656 = false,
                        .eip_6780 = false,
                    },
                    .ISTANBUL => .{
                        .eip_2929 = false,
                        .eip_3541 = false,
                        .eip_3855 = false,
                        .eip_3860 = false,
                        .eip_4844 = false,
                        .eip_5656 = false,
                        .eip_6780 = false,
                    },
                    .MUIR_GLACIER => .{
                        .eip_2929 = false,
                        .eip_3541 = false,
                        .eip_3855 = false,
                        .eip_3860 = false,
                        .eip_4844 = false,
                        .eip_5656 = false,
                        .eip_6780 = false,
                    },
                    .BERLIN => .{
                        .eip_2929 = true, // Access list
                        .eip_3541 = false,
                        .eip_3855 = false,
                        .eip_3860 = false,
                        .eip_4844 = false,
                        .eip_5656 = false,
                        .eip_6780 = false,
                    },
                    .LONDON => .{
                        .eip_2929 = true,
                        .eip_3541 = true, // 0xEF prefix
                        .eip_3855 = false,
                        .eip_3860 = false,
                        .eip_4844 = false,
                        .eip_5656 = false,
                        .eip_6780 = false,
                    },
                    .ARROW_GLACIER => .{
                        .eip_2929 = true,
                        .eip_3541 = true,
                        .eip_3855 = false,
                        .eip_3860 = false,
                        .eip_4844 = false,
                        .eip_5656 = false,
                        .eip_6780 = false,
                    },
                    .GRAY_GLACIER => .{
                        .eip_2929 = true,
                        .eip_3541 = true,
                        .eip_3855 = false,
                        .eip_3860 = false,
                        .eip_4844 = false,
                        .eip_5656 = false,
                        .eip_6780 = false,
                    },
                    .MERGE => .{
                        .eip_2929 = true,
                        .eip_3541 = true,
                        .eip_3855 = false,
                        .eip_3860 = false,
                        .eip_4844 = false,
                        .eip_5656 = false,
                        .eip_6780 = false,
                    },
                    .SHANGHAI => .{
                        .eip_2929 = true,
                        .eip_3541 = true,
                        .eip_3855 = true, // PUSH0
                        .eip_3860 = true, // Initcode size limit
                        .eip_4844 = false,
                        .eip_5656 = false,
                        .eip_6780 = false,
                    },
                    .CANCUN => .{
                        .eip_2929 = true,
                        .eip_3541 = true,
                        .eip_3855 = true,
                        .eip_3860 = true,
                        .eip_4844 = true, // Blob transactions
                        .eip_5656 = true, // MCOPY
                        .eip_6780 = true, // SELFDESTRUCT changes
                    },
                };
            }
        };

        /// Initialize a new EVM instance.
        ///
        /// Sets up the execution environment with state storage, block context,
        /// and transaction parameters. The planner cache is initialized with
        /// a default size for bytecode optimization.
        pub fn init(allocator: std.mem.Allocator, database: DatabaseInterface, block_info: BlockInfo, context: TransactionContext, gas_price: u256, origin: primitives.Address, hardfork_config: Hardfork) !Self {
            var access_list = AccessList.init(allocator);
            errdefer access_list.deinit();
            var planner = try Planner.init(allocator, 32); // 32 plans cache
            errdefer planner.deinit();
            return Self{
                .depth = 0,
                .static_stack = [_]bool{false} ** config.max_call_depth,
                .call_stack = [_]CallStackEntry{CallStackEntry{ .caller = primitives.Address.ZERO_ADDRESS, .value = 0 }} ** config.max_call_depth,
                .allocator = allocator,
                .database = database,
                .journal = Journal.init(allocator),
                .created_contracts = CreatedContracts.init(allocator),
                .self_destruct = SelfDestruct.init(allocator),
                .access_list = access_list,
                .block_info = block_info,
                .context = context,
                .current_input = &.{},
                .return_data = &.{},
                .gas_price = gas_price,
                .origin = origin,
                .eips = EipsConfig.fromHardfork(hardfork_config),
                .disable_gas_checking = false,
                .planner = planner,
                .current_snapshot_id = 0,
                .logs = std.ArrayList(@import("call_result.zig").Log){},
                .call_arena = std.heap.ArenaAllocator.init(allocator),
            };
        }

        /// Clean up all resources.
        pub fn deinit(self: *Self) void {
            self.journal.deinit();
            self.created_contracts.deinit();
            self.self_destruct.deinit();
            self.access_list.deinit();
            self.planner.deinit();
            self.logs.deinit(self.allocator);
            self.call_arena.deinit();
        }

        /// Get the arena allocator for temporary allocations during the current call.
        /// This allocator is reset after each root call completes.
        pub fn getCallArenaAllocator(self: *Self) std.mem.Allocator {
            return self.call_arena.allocator();
        }

        /// Execute an EVM operation.
        ///
        /// This is the main entry point that routes to specific handlers based
        /// on the operation type (CALL, CREATE, etc). Manages transaction-level
        /// state including logs and ensures proper cleanup.
        pub fn call(self: *Self, params: CallParams) CallResult {
            params.validate() catch return CallResult.failure(0);
            defer self.depth = 0;
            defer _ = self.call_arena.reset(.retain_capacity);
            defer self.logs.clearRetainingCapacity();
            
            // Check gas unless disabled
            const gas = switch (params) {
                inline else => |p| p.gas,
            };
            if (!self.disable_gas_checking and gas == 0) return CallResult.failure(0);
            if (self.depth >= config.max_call_depth) return CallResult.failure(0);
            
            // Route to appropriate handler
            var result = switch (params) {
                .call => |p| self.executeCall(p),
                .callcode => |p| self.executeCallcode(p),
                .delegatecall => |p| self.executeDelegatecall(p),
                .staticcall => |p| self.executeStaticcall(p),
                .create => |p| self.executeCreate(p),
                .create2 => |p| self.executeCreate2(p),
            };
            
            result.logs = self.takeLogs();
            // TODO: add selfdestruct and access list data to result
            return result;
        }

        /// Execute CALL operation (inlined from call_handler)
        fn executeCall(self: *Self, params: CallParams.CallData) CallResult {
            const snapshot_id = self.journal.create_snapshot();
            
            // Transfer value if needed
            if (params.value > 0) {
                self.doTransfer(params.caller, params.to, params.value, snapshot_id) catch |err| {
                    log.debug("Call value transfer failed: {}", .{err});
                    self.journal.revert_to_snapshot(snapshot_id);
                    return CallResult.failure(0);
                };
            }

            // Handle precompiles
            if (config.enable_precompiles and precompiles.is_precompile(params.to)) {
                const result = self.executePrecompileInline(params.to, params.input, params.gas, false, snapshot_id) catch {
                    self.journal.revert_to_snapshot(snapshot_id);
                    return CallResult.failure(0);
                };
                return result;
            }

            // Get contract code
            const code = self.database.get_code_by_address(params.to.bytes) catch &.{};
            if (code.len == 0) {
                log.debug("Call to empty account: {}", .{params.to});
                return CallResult.success_empty(params.gas);
            }

            // Execute frame
            const result = self.execute_frame(
                code,
                params.input,
                params.gas,
                params.to,
                params.caller,
                params.value,
                false, // is_static
                snapshot_id,
            ) catch {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            };

            if (!result.success) self.journal.revert_to_snapshot(snapshot_id);
            return result;
        }

        /// Execute CALLCODE operation (inlined)
        fn executeCallcode(self: *Self, params: CallParams.CallcodeData) CallResult {
            const snapshot_id = self.journal.create_snapshot();
            
            // Check balance for value transfer
            if (params.value > 0) {
                const caller_account = self.database.get_account(params.caller.bytes) catch {
                    self.journal.revert_to_snapshot(snapshot_id);
                    return CallResult.failure(0);
                };
                
                if (caller_account == null or caller_account.?.balance < params.value) {
                    self.journal.revert_to_snapshot(snapshot_id);
                    return CallResult.failure(0);
                }
            }

            const code = self.database.get_code_by_address(params.to.bytes) catch &.{};
            if (code.len == 0) return CallResult.success_empty(params.gas);

            // CALLCODE executes target's code in caller's context
            const result = self.execute_frame(
                code,
                params.input,
                params.gas,
                params.caller, // Execute in caller's context
                params.caller, // msg.sender is still the caller
                params.value,
                false,
                snapshot_id,
            ) catch {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            };

            if (!result.success) self.journal.revert_to_snapshot(snapshot_id);
            return result;
        }

        /// Execute DELEGATECALL operation (inlined)
        fn executeDelegatecall(self: *Self, params: CallParams.DelegatecallData) CallResult {
            const snapshot_id = self.journal.create_snapshot();

            // Handle precompiles
            if (config.enable_precompiles and precompiles.is_precompile(params.to)) {
                const result = self.executePrecompileInline(params.to, params.input, params.gas, false, snapshot_id) catch {
                    self.journal.revert_to_snapshot(snapshot_id);
                    return CallResult.failure(0);
                };
                return result;
            }

            const code = self.database.get_code_by_address(params.to.bytes) catch &.{};
            if (code.len == 0) return CallResult.success_empty(params.gas);

            // DELEGATECALL preserves caller and value from parent context
            const current_value = if (self.depth > 0) self.call_stack[self.depth - 1].value else 0;
            const result = self.execute_frame(
                code,
                params.input,
                params.gas,
                params.to,
                params.caller, // Preserve original caller
                current_value, // Preserve value from parent context
                false,
                snapshot_id,
            ) catch {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            };

            if (!result.success) self.journal.revert_to_snapshot(snapshot_id);
            return result;
        }

        /// Execute STATICCALL operation (inlined)
        fn executeStaticcall(self: *Self, params: CallParams.StaticcallData) CallResult {
            const snapshot_id = self.journal.create_snapshot();

            // Handle precompiles
            if (config.enable_precompiles and precompiles.is_precompile(params.to)) {
                const result = self.executePrecompileInline(params.to, params.input, params.gas, true, snapshot_id) catch {
                    self.journal.revert_to_snapshot(snapshot_id);
                    return CallResult.failure(0);
                };
                return result;
            }

            const code = self.database.get_code_by_address(params.to.bytes) catch &.{};
            if (code.len == 0) return CallResult.success_empty(params.gas);

            // Execute in static mode
            const result = self.execute_frame(
                code,
                params.input,
                params.gas,
                params.to,
                params.caller,
                0, // No value in static call
                true, // is_static = true
                snapshot_id,
            ) catch {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            };

            if (!result.success) self.journal.revert_to_snapshot(snapshot_id);
            return result;
        }

        /// Execute CREATE operation (inlined)
        fn executeCreate(self: *Self, params: CallParams.CreateData) CallResult {
            const snapshot_id = self.journal.create_snapshot();

            // Get caller account
            var caller_account = self.database.get_account(params.caller.bytes) catch {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            } orelse Account.zero();

            // Check balance
            if (caller_account.balance < params.value) {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            }

            // Calculate contract address
            const contract_address = primitives.Address.get_contract_address(params.caller, caller_account.nonce);

            // Check collision
            const existed_before = self.database.account_exists(contract_address.bytes);
            if (existed_before) {
                const existing = self.database.get_account(contract_address.bytes) catch null;
                if (existing != null and !std.mem.eql(u8, &existing.?.code_hash, &[_]u8{0} ** 32)) {
                    self.journal.revert_to_snapshot(snapshot_id);
                    return CallResult.failure(0);
                }
            }

            // Increment nonce
            try self.journal.record_nonce_change(snapshot_id, params.caller, caller_account.nonce);
            caller_account.nonce += 1;
            self.database.set_account(params.caller.bytes, caller_account) catch {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            };

            // Track created contract
            try self.created_contracts.mark_created(contract_address);

            // Check gas
            const GasConstants = primitives.GasConstants;
            const create_gas = GasConstants.CreateGas;
            if (params.gas < create_gas) {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            }

            const remaining_gas = params.gas - create_gas;

            // Transfer value
            if (params.value > 0) {
                self.doTransfer(params.caller, contract_address, params.value, snapshot_id) catch {
                    self.journal.revert_to_snapshot(snapshot_id);
                    return CallResult.failure(0);
                };
            }

            // Execute init code
            const result = self.execute_init_code(
                params.init_code,
                remaining_gas,
                contract_address,
                snapshot_id,
            ) catch {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            };

            if (!result.success) {
                self.journal.revert_to_snapshot(snapshot_id);
                return result;
            }

            // Finalize contract
            var contract_account = self.database.get_account(contract_address.bytes) catch {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            } orelse Account.zero();

            if (!existed_before) {
                try self.journal.record_account_created(snapshot_id, contract_address);
            }

            if (contract_account.nonce != 1) {
                try self.journal.record_nonce_change(snapshot_id, contract_address, contract_account.nonce);
                contract_account.nonce = 1;
            }

            if (result.output.len > 0) {
                const code_hash_bytes = self.database.set_code(result.output) catch {
                    self.journal.revert_to_snapshot(snapshot_id);
                    return CallResult.failure(0);
                };
                try self.journal.record_code_change(snapshot_id, contract_address, contract_account.code_hash);
                contract_account.code_hash = code_hash_bytes;
            }

            self.database.set_account(contract_address.bytes, contract_account) catch {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            };

            // Return contract address
            const out32 = self.small_output_buf[0..32];
            @memset(out32[0..12], 0);
            @memcpy(out32[12..32], &contract_address.bytes);
            return CallResult.success_with_output(result.gas_left, out32);
        }

        /// Execute CREATE2 operation (inlined)
        fn executeCreate2(self: *Self, params: CallParams.Create2Data) CallResult {
            if (self.depth >= config.max_call_depth) return CallResult.failure(0);
            
            const snapshot_id = self.journal.create_snapshot();

            // Get caller account
            const caller_account = self.database.get_account(params.caller.bytes) catch {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            } orelse Account.zero();

            // Check balance
            if (caller_account.balance < params.value) {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            }

            // Calculate contract address
            const keccak_asm = @import("keccak_asm.zig");
            var init_code_hash_bytes: [32]u8 = undefined;
            try keccak_asm.keccak256(params.init_code, &init_code_hash_bytes);
            const salt_bytes = @as([32]u8, @bitCast(params.salt));
            const contract_address = primitives.Address.get_create2_address(params.caller, salt_bytes, init_code_hash_bytes);

            // Check collision
            const existed_before = self.database.account_exists(contract_address.bytes);
            if (existed_before) {
                const existing = self.database.get_account(contract_address.bytes) catch null;
                if (existing != null and !std.mem.eql(u8, &existing.?.code_hash, &[_]u8{0} ** 32)) {
                    self.journal.revert_to_snapshot(snapshot_id);
                    return CallResult.failure(0);
                }
            }

            // Track created contract
            try self.created_contracts.mark_created(contract_address);

            // Calculate gas
            const GasConstants = primitives.GasConstants;
            const create_gas = GasConstants.CreateGas;
            const hash_cost = @as(u64, @intCast(params.init_code.len)) * GasConstants.Keccak256WordGas / 32;
            const total_gas = create_gas + hash_cost;

            if (params.gas < total_gas) {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            }

            const remaining_gas = params.gas - total_gas;

            // Transfer value
            if (params.value > 0) {
                self.doTransfer(params.caller, contract_address, params.value, snapshot_id) catch {
                    self.journal.revert_to_snapshot(snapshot_id);
                    return CallResult.failure(0);
                };
            }

            // Execute init code
            const result = self.execute_init_code(
                params.init_code,
                remaining_gas,
                contract_address,
                snapshot_id,
            ) catch {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            };

            if (!result.success) {
                self.journal.revert_to_snapshot(snapshot_id);
                return result;
            }

            // Finalize contract
            var contract_account = self.database.get_account(contract_address.bytes) catch {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            } orelse Account.zero();

            if (!existed_before) {
                try self.journal.record_account_created(snapshot_id, contract_address);
            }

            if (contract_account.nonce != 1) {
                try self.journal.record_nonce_change(snapshot_id, contract_address, contract_account.nonce);
                contract_account.nonce = 1;
            }

            if (result.output.len > 0) {
                const stored_hash = self.database.set_code(result.output) catch {
                    self.journal.revert_to_snapshot(snapshot_id);
                    return CallResult.failure(0);
                };
                try self.journal.record_code_change(snapshot_id, contract_address, contract_account.code_hash);
                contract_account.code_hash = stored_hash;
            }

            self.database.set_account(contract_address.bytes, contract_account) catch {
                self.journal.revert_to_snapshot(snapshot_id);
                return CallResult.failure(0);
            };

            // Return contract address
            const out32 = self.small_output_buf[0..32];
            @memset(out32[0..12], 0);
            @memcpy(out32[12..32], &contract_address.bytes);
            return CallResult.success_with_output(result.gas_left, out32);
        }

        /// Execute frame using the new Frame implementation
        fn execute_frame(
            self: *Self,
            code: []const u8,
            input: []const u8,
            gas: u64,
            address: primitives.Address,
            caller: primitives.Address,
            value: u256,
            is_static: bool,
            snapshot_id: Journal.SnapshotIdType,
        ) !CallResult {
            // Bind snapshot and call input for this frame duration
            const prev_snapshot = self.current_snapshot_id;
            self.current_snapshot_id = snapshot_id;
            defer self.current_snapshot_id = prev_snapshot;

            const prev_input = self.current_input;
            self.current_input = input;
            defer self.current_input = prev_input;

            // Increment depth and track static context
            self.depth += 1;
            defer self.depth -= 1;

            // Store caller and value in call stack
            self.call_stack[self.depth - 1] = CallStackEntry{ .caller = caller, .value = value };

            // Track static context
            self.static_stack[self.depth - 1] = is_static;

            // Convert gas to appropriate type
            const gas_i32 = @as(i32, @intCast(@min(gas, std.math.maxInt(i32))));

            // Create host interface
            const host = @import("host.zig").Host.init(self);

            // Get or create optimized plan
            const plan = try self.planner.analyze(code);
            
            // Create and execute frame using new Frame
            var frame = try Frame.init(
                self.allocator,
                code,
                gas_i32,
                self.database,
                host,
            );
            frame.contract_address = address;
            defer frame.deinit(self.allocator);

            // Execute using the optimized instruction stream
            const schedule_ptr: [*]const Frame.Schedule.Item = @ptrCast(plan.instructionStream.ptr);
            
            // Start execution at first handler
            const first_handler = schedule_ptr[0].opcode_handler;
            const result = first_handler(frame, schedule_ptr + 1) catch |err| {
                const gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
                var out_slice: []const u8 = &.{};
                if (frame.output_data.items.len > 0) {
                    const buf = try self.allocator.alloc(u8, frame.output_data.items.len);
                    @memcpy(buf, frame.output_data.items);
                    out_slice = buf;
                }
                self.return_data = out_slice;
                return switch (err) {
                    error.STOP => CallResult.success_with_output(gas_left, out_slice),
                    error.REVERT => CallResult.revert_with_data(gas_left, out_slice),
                    else => CallResult.failure(0),
                };
            };

            // Handle success cases
            const gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
            var out_slice: []const u8 = &.{};
            if (frame.output_data.items.len > 0) {
                const buf = try self.allocator.alloc(u8, frame.output_data.items.len);
                @memcpy(buf, frame.output_data.items);
                out_slice = buf;
            }
            self.return_data = out_slice;
            
            return switch (result) {
                .Stop => CallResult.success_with_output(gas_left, out_slice),
                .Return => CallResult.success_with_output(gas_left, out_slice),
                .SelfDestruct => CallResult.success_with_output(gas_left, out_slice),
                .Jump => CallResult.failure(0), // Jump should be handled internally
            };
        }

        /// Execute initialization code
        fn execute_init_code(
            self: *Self,
            code: []const u8,
            gas: u64,
            address: primitives.Address,
            snapshot_id: Journal.SnapshotIdType,
        ) !CallResult {
            // Check initcode size limit (EIP-3860)
            if (self.eips.eip_3860 and code.len > 49152) {
                return CallResult.failure(0);
            }

            const prev_snapshot = self.current_snapshot_id;
            self.current_snapshot_id = snapshot_id;
            defer self.current_snapshot_id = prev_snapshot;

            const host = @import("host.zig").Host.init(self);
            const gas_i32 = @as(i32, @intCast(@min(gas, std.math.maxInt(i32))));

            // Use Frame for init code execution
            var frame = try Frame.init(self.allocator, code, gas_i32, self.database, host);
            defer frame.deinit(self.allocator);
            frame.contract_address = address;

            // Get plan and execute
            const plan = try self.planner.analyze(code);
            const schedule_ptr: [*]const Frame.Schedule.Item = @ptrCast(plan.instructionStream.ptr);
            const first_handler = schedule_ptr[0].opcode_handler;
            
            const result = first_handler(frame, schedule_ptr + 1) catch |err| {
                const gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
                var out_slice: []const u8 = &.{};
                if (frame.output_data.items.len > 0) {
                    const buf = try self.allocator.alloc(u8, frame.output_data.items.len);
                    @memcpy(buf, frame.output_data.items);
                    out_slice = buf;
                }
                self.return_data = out_slice;
                return switch (err) {
                    error.STOP => CallResult.success_with_output(gas_left, out_slice),
                    error.REVERT => CallResult.revert_with_data(gas_left, out_slice),
                    else => CallResult.failure(0),
                };
            };

            _ = result;
            const gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
            var out_slice: []const u8 = &.{};
            if (frame.output_data.items.len > 0) {
                const buf = try self.allocator.alloc(u8, frame.output_data.items.len);
                @memcpy(buf, frame.output_data.items);
                out_slice = buf;
            }
            self.return_data = out_slice;
            return CallResult.success_with_output(gas_left, out_slice);
        }

        /// Execute nested EVM call - used for calls from within the EVM
        pub fn inner_call(self: *Self, params: CallParams) !CallResult {
            return self.call(params);
        }

        /// Execute a precompile call (inlined)
        fn executePrecompileInline(self: *Self, address: primitives.Address, input: []const u8, gas: u64, is_static: bool, snapshot_id: Journal.SnapshotIdType) !CallResult {
            _ = is_static;
            _ = snapshot_id;

            if (!precompiles.is_precompile(address)) {
                return CallResult{ .success = false, .gas_left = gas, .output = &.{} };
            }

            const precompile_id = address.bytes[19];
            if (precompile_id < 1 or precompile_id > 10) {
                return CallResult{ .success = false, .gas_left = gas, .output = &.{} };
            }

            const result = precompiles.execute_precompile(self.allocator, address, input, gas) catch {
                return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
            };

            var out_slice: []const u8 = &.{};
            if (result.output.len > 0) {
                const buf = try self.allocator.dupe(u8, result.output);
                self.allocator.free(result.output);
                out_slice = buf;
            }

            if (result.success) {
                return CallResult{ .success = true, .gas_left = gas - result.gas_used, .output = out_slice };
            } else {
                return CallResult{ .success = false, .gas_left = 0, .output = out_slice };
            }
        }

        /// Transfer value between accounts (renamed from transferValue)
        fn doTransfer(self: *Self, from: primitives.Address, to: primitives.Address, value: u256, snapshot_id: Journal.SnapshotIdType) !void {
            var from_account = try self.database.get_account(from.bytes) orelse Account.zero();
            if (from_account.balance < value) return error.InsufficientBalance;
            var to_account = try self.database.get_account(to.bytes) orelse Account.zero();
            try self.journal.record_balance_change(snapshot_id, from, from_account.balance);
            try self.journal.record_balance_change(snapshot_id, to, to_account.balance);
            from_account.balance -= value;
            to_account.balance += value;
            try self.database.set_account(from.bytes, from_account);
            try self.database.set_account(to.bytes, to_account);
        }

        // ===== Host Interface Implementation =====

        /// Get account balance
        pub fn get_balance(self: *Self, address: primitives.Address) u256 {
            return self.database.get_balance(address.bytes) catch 0;
        }

        /// Check if account exists
        pub fn account_exists(self: *Self, address: primitives.Address) bool {
            return self.database.account_exists(address.bytes);
        }

        /// Get account code
        pub fn get_code(self: *Self, address: primitives.Address) []const u8 {
            return self.database.get_code_by_address(address.bytes) catch &.{};
        }

        /// Get block information
        pub fn get_block_info(self: *Self) BlockInfo {
            return self.block_info;
        }

        /// Emit log event
        pub fn emit_log(self: *Self, contract_address: primitives.Address, topics: []const u256, data: []const u8) void {
            const topics_copy = self.allocator.dupe(u256, topics) catch return;
            const data_copy = self.allocator.dupe(u8, data) catch return;

            self.logs.append(self.allocator, @import("call_result.zig").Log{
                .address = contract_address,
                .topics = topics_copy,
                .data = data_copy,
            }) catch return;
        }

        /// Execute nested EVM call - for Host interface
        pub fn host_inner_call(self: *Self, params: CallParams) !CallResult {
            return self.inner_call(params);
        }

        /// Register a contract as created in the current transaction
        pub fn register_created_contract(self: *Self, address: primitives.Address) !void {
            try self.created_contracts.mark_created(address);
        }

        /// Check if a contract was created in the current transaction
        pub fn was_created_in_tx(self: *Self, address: primitives.Address) bool {
            return self.created_contracts.was_created_in_tx(address);
        }

        /// Create a new journal snapshot
        pub fn create_snapshot(self: *Self) Journal.SnapshotIdType {
            return self.journal.create_snapshot();
        }

        /// Revert state changes to a previous snapshot
        pub fn revert_to_snapshot(self: *Self, snapshot_id: Journal.SnapshotIdType) void {
            // Get the journal entries that need to be reverted
            var entries_to_revert = std.ArrayList(Journal.EntryType){};
            defer entries_to_revert.deinit(self.allocator);

            // Collect entries that belong to snapshots newer than or equal to target
            for (self.journal.entries.items) |entry| {
                if (entry.snapshot_id >= snapshot_id) {
                    entries_to_revert.append(self.allocator, entry) catch break;
                }
            }

            // Remove the journal entries first
            self.journal.revert_to_snapshot(snapshot_id);

            // Apply the changes in reverse order
            var i = entries_to_revert.items.len;
            while (i > 0) : (i -= 1) {
                const entry = entries_to_revert.items[i - 1];
                self.apply_journal_entry_revert(entry) catch |err| {
                    log.err("Failed to revert journal entry: {}", .{err});
                };
            }
        }

        /// Apply a single journal entry to revert database state
        fn apply_journal_entry_revert(self: *Self, entry: Journal.EntryType) !void {
            switch (entry.data) {
                .storage_change => |sc| {
                    try self.database.set_storage(sc.address.bytes, sc.key, sc.original_value);
                },
                .balance_change => |bc| {
                    var account = (try self.database.get_account(bc.address.bytes)) orelse {
                        const reverted_account = Account{
                            .balance = bc.original_balance,
                            .nonce = 0,
                            .code_hash = [_]u8{0} ** 32,
                            .storage_root = [_]u8{0} ** 32,
                        };
                        return self.database.set_account(bc.address.bytes, reverted_account);
                    };
                    account.balance = bc.original_balance;
                    try self.database.set_account(bc.address.bytes, account);
                },
                .nonce_change => |nc| {
                    var account = (try self.database.get_account(nc.address.bytes)) orelse return;
                    account.nonce = nc.original_nonce;
                    try self.database.set_account(nc.address.bytes, account);
                },
                .code_change => |cc| {
                    var account = (try self.database.get_account(cc.address.bytes)) orelse return;
                    account.code_hash = cc.original_code_hash;
                    try self.database.set_account(cc.address.bytes, account);
                },
                .account_created => |ac| {
                    try self.database.delete_account(ac.address.bytes);
                },
                .account_destroyed => |ad| {
                    const restored_account = Account{
                        .balance = ad.balance,
                        .nonce = 0,
                        .code_hash = [_]u8{0} ** 32,
                        .storage_root = [_]u8{0} ** 32,
                    };
                    try self.database.set_account(ad.address.bytes, restored_account);
                },
            }
        }

        /// Record a storage change in the journal
        pub fn record_storage_change(self: *Self, address: primitives.Address, slot: u256, original_value: u256) !void {
            try self.journal.record_storage_change(self.current_snapshot_id, address, slot, original_value);
        }

        /// Get the original storage value from the journal
        pub fn get_original_storage(self: *Self, address: primitives.Address, slot: u256) ?u256 {
            return self.journal.get_original_storage(address, slot);
        }

        /// Access an address and return the gas cost (EIP-2929)
        pub fn access_address(self: *Self, address: primitives.Address) !u64 {
            return try self.access_list.access_address(address);
        }

        /// Access a storage slot and return the gas cost (EIP-2929)
        pub fn access_storage_slot(self: *Self, contract_address: primitives.Address, slot: u256) !u64 {
            return try self.access_list.access_storage_slot(contract_address, slot);
        }

        /// Mark a contract for destruction
        pub fn mark_for_destruction(self: *Self, contract_address: primitives.Address, recipient: primitives.Address) !void {
            try self.self_destruct.mark_for_destruction(contract_address, recipient);
        }

        /// Get current call input/calldata
        pub fn get_input(self: *Self) []const u8 {
            return self.current_input;
        }

        /// Check if hardfork is at least the target
        pub fn is_hardfork_at_least(self: *Self, target: Hardfork) bool {
            _ = target;
            _ = self;
            // Use EIPs config instead
            return true;
        }

        /// Get current hardfork (deprecated - use EIPs)
        pub fn get_hardfork(self: *Self) Hardfork {
            _ = self;
            return .CANCUN; // Default to latest
        }

        /// Get whether the current frame is static
        pub fn get_is_static(self: *Self) bool {
            if (self.depth == 0) return false;
            return self.static_stack[self.depth - 1];
        }

        /// Get the call depth for the current frame
        pub fn get_depth(self: *Self) u11 {
            return @intCast(self.depth);
        }

        /// Get transaction origin (original sender)
        pub fn get_tx_origin(self: *Self) primitives.Address {
            return self.origin;
        }

        /// Get current caller address
        pub fn get_caller(self: *Self) primitives.Address {
            if (self.depth == 0) return self.origin;
            return self.call_stack[self.depth - 1].caller;
        }

        /// Get current call value
        pub fn get_call_value(self: *Self) u256 {
            if (self.depth == 0) return 0;
            return self.call_stack[self.depth - 1].value;
        }

        /// Get storage value
        pub fn get_storage(self: *Self, address: primitives.Address, slot: u256) u256 {
            return self.database.get_storage(address.bytes, slot) catch 0;
        }

        /// Set storage value
        pub fn set_storage(self: *Self, address: primitives.Address, slot: u256, value: u256) !void {
            const original_value = self.get_storage(address, slot);
            try self.record_storage_change(address, slot, original_value);
            try self.database.set_storage(address.bytes, slot, value);
        }

        /// Get transaction gas price
        pub fn get_gas_price(self: *Self) u256 {
            return self.gas_price;
        }

        /// Get return data from last call
        pub fn get_return_data(self: *Self) []const u8 {
            return self.return_data;
        }

        /// Get chain ID
        pub fn get_chain_id(self: *Self) u16 {
            return self.context.chain_id;
        }

        /// Get block hash by number
        pub fn get_block_hash(self: *Self, block_number: u64) ?[32]u8 {
            const current_block = self.block_info.number;

            // EVM BLOCKHASH rules
            if (block_number >= current_block or
                current_block > block_number + 256 or
                block_number == 0)
            {
                return null;
            }

            // Generate deterministic hash for testing
            var hash: [32]u8 = undefined;
            hash[0..8].* = std.mem.toBytes(block_number);
            hash[8..16].* = std.mem.toBytes(current_block);

            var i: usize = 16;
            while (i < 32) : (i += 1) {
                hash[i] = @as(u8, @truncate(block_number +% i));
            }

            return hash;
        }

        /// Get blob hash for the given index (EIP-4844)
        pub fn get_blob_hash(self: *Self, index: u256) ?[32]u8 {
            if (index >= self.context.blob_versioned_hashes.len) {
                return null;
            }
            const idx = @as(usize, @intCast(index));
            return self.context.blob_versioned_hashes[idx];
        }

        /// Get blob base fee (EIP-4844)
        pub fn get_blob_base_fee(self: *Self) u256 {
            return self.context.blob_base_fee;
        }

        /// Take all logs and clear the log list
        fn takeLogs(self: *Self) []const @import("call_result.zig").Log {
            const logs = self.logs.toOwnedSlice(self.allocator) catch &.{};
            self.logs = std.ArrayList(@import("call_result.zig").Log){};
            return logs;
        }
    };
}

// Re-export for backward compatibility
pub const DefaultEvm = Evm(.{});

// Tests remain the same...
