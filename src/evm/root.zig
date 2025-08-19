//! EVM (Ethereum Virtual Machine) module - Core execution engine
//!
//! This is the main entry point for the EVM implementation. It exports all
//! the components needed to execute Ethereum bytecode, manage state, and
//! handle the complete lifecycle of smart contract execution.
//!
//! ## Architecture Overview
//!
//! The EVM is structured into several key components:
//!
//! ### Core Execution
//! - **VM**: The main virtual machine that orchestrates execution
//! - **Frame**: Execution contexts for calls and creates
//! - **Stack**: 256-bit word stack (max 1024 elements)
//! - **Memory**: Byte-addressable memory (expands as needed)
//! - **Contract**: Code and storage management
//!
//! ### Opcodes
//! - **Opcode**: Enumeration of all EVM instructions
//! - **Operation**: Metadata about each opcode (gas, stack effects)
//! - **OpcodeMetadata**: Maps opcodes to their implementations
//! - **execution/**: Individual opcode implementations
//!
//! ### Error Handling
//! - **ExecutionError**: Unified error type for all execution failures
//! - Strongly typed errors for each component
//! - Error mapping utilities for consistent handling
//!
//! ### Utilities
//! - **SimpleAnalysis**: Simplified bytecode analysis for tailcall dispatch
//! - **Hardfork**: Fork-specific behavior configuration
//! - **gas_constants**: Gas cost calculations
//! - **chain_rules**: Chain-specific validation rules
//!
//! ## Usage Example
//!
//! ```zig
//! const evm = @import("evm");
//!
//! // Create a VM instance
//! var vm = try evm.Evm.init(allocator, config);
//! defer vm.deinit();
//!
//! // Execute bytecode
//! const result = try vm.run(bytecode, context);
//! ```
//!
//! ## Design Principles
//!
//! 1. **Correctness**: Strict adherence to Ethereum Yellow Paper
//! 2. **Performance**: Efficient execution with minimal allocations
//! 3. **Safety**: Strong typing and comprehensive error handling
//! 4. **Modularity**: Clear separation of concerns
//! 5. **Testability**: Extensive test coverage for all components

const std = @import("std");
const primitives_internal = @import("primitives");

// Import external modules
/// Address utilities for Ethereum addresses
pub const primitives = @import("primitives");

// Import all EVM modules

/// Simplified bytecode analysis for tailcall dispatch
pub const SimpleAnalysis = @import("evm/analysis2.zig").SimpleAnalysis;
/// Compatibility wrapper for the old CodeAnalysis interface
pub const CodeAnalysis = @import("analysis.zig").CodeAnalysis;

/// Unified error types for EVM execution
pub const ExecutionError = @import("execution/execution_error.zig");

/// Execution result type
pub const ExecutionResult = @import("execution/execution_result.zig");

/// Execution context providing transaction and block information
pub const Context = @import("access_list/context.zig");

/// Ethereum hardfork configuration
pub const Hardfork = @import("hardforks/hardfork.zig");

/// Centralized EVM configuration system
pub const config = @import("config.zig");
pub const EvmConfig = config.EvmConfig;
pub const EipFlags = config.EipFlags;
pub const EipOverrides = config.EipOverrides;

/// Opcode to implementation mapping
pub const OpcodeMetadata = @import("opcode_metadata/opcode_metadata.zig");

/// Struct-of-arrays opcode metadata for improved cache locality
pub const SoaOpcodeMetadata = @import("opcode_metadata/soa_opcode_metadata.zig").SoaOpcodeMetadata;

/// Byte-addressable memory implementation
pub const Memory = @import("memory/memory.zig");
/// Memory module package for additional memory utilities
pub const memory = @import("memory/package.zig");

/// Opcode metadata (gas costs, stack effects)
pub const Operation = @import("opcodes/operation.zig");

/// Backwards compatibility alias for test files
pub const OperationModule = Operation;

/// 256-bit word stack implementation
pub const Stack = @import("stack/stack.zig");

/// Stack depth validation utilities
pub const stack_validation = @import("stack/stack_validation.zig");

/// Main virtual machine implementation
pub const Evm = @import("evm.zig");

/// Main call function using interpret2 (tailcall dispatch)
pub const call2 = @import("evm/call2.zig").call;

/// Execution context and frame management
pub const Frame = @import("stack_frame.zig").StackFrame;
pub const ExecutionContext = @import("stack_frame.zig").StackFrame;
/// Backwards-compatibility builder used by older tests
pub const EvmBuilder = struct {
    allocator: std.mem.Allocator,
    database: @import("state/database_interface.zig").DatabaseInterface,

    pub fn init(allocator: std.mem.Allocator, database: @import("state/database_interface.zig").DatabaseInterface) EvmBuilder {
        return .{ .allocator = allocator, .database = database };
    }

    pub fn build(self: *EvmBuilder) !Evm {
        return Evm.init(self.allocator, self.database, null, null, null, 0, false, null);
    }
};

/// EVM state management (accounts, storage, logs)
pub const EvmState = @import("state/state.zig");

/// Database interface for pluggable state storage
pub const DatabaseInterface = @import("state/database_interface.zig").DatabaseInterface;

/// Database error types
pub const DatabaseError = @import("state/database_interface.zig").DatabaseError;

/// Account state structure
pub const Account = @import("state/database_interface.zig").Account;

/// Memory database implementation
pub const MemoryDatabase = @import("state/memory_database.zig").MemoryDatabase;

/// Database factory for creating different implementations
pub const DatabaseFactory = @import("state/database_factory.zig");

/// Host interface for external EVM operations (CALL, BALANCE, etc.)
pub const Host = @import("host.zig").Host;
pub const CallParams = @import("host.zig").CallParams;
pub const BlockInfo = @import("host.zig").BlockInfo;
pub const MockHost = @import("host.zig").MockHost;

/// Precompiled contracts implementation (IDENTITY, SHA256, etc.)
pub const Precompiles = @import("precompiles/precompiles_optimized.zig");

/// Precompiles namespace for easier access
pub const precompiles = struct {
    pub const precompiles = @import("precompiles/precompiles.zig");
    pub const identity = @import("precompiles/identity.zig");
    pub const sha256 = @import("precompiles/sha256.zig");
    pub const ripemd160 = @import("precompiles/ripemd160.zig");
    pub const blake2f = @import("precompiles/blake2f.zig");
    pub const ecadd = @import("precompiles/ecadd.zig");
    pub const ecmul = @import("precompiles/ecmul.zig");
    pub const ecpairing = @import("precompiles/ecpairing.zig");
    pub const precompile_result = @import("precompiles/precompile_result.zig");
    pub const PrecompileOutput = @import("precompiles/precompile_result.zig").PrecompileOutput;
    pub const PrecompileError = @import("precompiles/precompile_result.zig").PrecompileError;
};

/// ECADD precompile (0x06)
pub const ecadd = @import("precompiles/ecadd.zig");

/// ECMUL precompile (0x07)
pub const ecmul = @import("precompiles/ecmul.zig");

/// ECPAIRING precompile (0x08)
pub const ecpairing = @import("precompiles/ecpairing.zig");

/// Tailcall interpreter prototype (simplified version)
pub const interpret2 = @import("evm/interpret2_simple.zig");

/// EIP-4844 blob transaction support (blobs, KZG verification, gas market)
pub const blob = @import("blob/index.zig");

/// Transaction types including EIP-4844 blob transactions
pub const transaction = @import("transaction/index.zig");

// Import execution
/// All opcode implementations (arithmetic, stack, memory, etc.)
pub const execution = @import("execution/package.zig");

// Backwards compatibility alias
pub const opcodes = execution;

// Import utility modules

/// Chain-specific validation rules
pub const chain_rules = @import("hardforks/chain_rules.zig").ChainRules;
pub const ChainRules = @import("hardforks/chain_rules.zig").ChainRules;

/// Self destruct tracking
pub const SelfDestruct = @import("self_destruct.zig").SelfDestruct;

/// Created contracts tracking
pub const CreatedContracts = @import("created_contracts.zig").CreatedContracts;

/// Call journal for revertible operations
pub const CallJournal = @import("call_frame_stack.zig").CallJournal;

/// Access list for EIP-2929 and EIP-2930
pub const AccessList = @import("access_list/access_list.zig");

/// Hardforks namespace for easier access
pub const hardforks = struct {
    pub const chain_rules = @import("hardforks/chain_rules.zig").ChainRules;
    pub const hardfork = @import("hardforks/hardfork.zig");
};

/// EVM opcode definitions and utilities
pub const opcode = @import("opcodes/opcode.zig");

/// Logger for EVM operations
pub const Log = @import("log.zig");

/// Tracer for capturing execution traces
pub const Tracer = @import("tracer.zig").Tracer;

/// EIP-7702 EOA delegation bytecode format
pub const eip_7702_bytecode = @import("frame/eip_7702_bytecode.zig");

/// Instruction type for block-based execution
pub const Instruction = @import("instruction.zig").Instruction;
const instruction_module = @import("instruction.zig");

/// Block execution metrics and performance analysis
pub const block_metrics = @import("block_metrics.zig");
pub const BlockExecutionMetrics = block_metrics.BlockExecutionMetrics;
pub const BlockCache = block_metrics.BlockCache;

/// Fee market calculations (EIP-1559)
pub const fee_market = @import("primitives").FeeMarket;

/// Gas cost constants from primitives
pub const GasConstants = @import("primitives").GasConstants;

/// Alias for backwards compatibility with test files
pub const gas_constants = @import("primitives").GasConstants;

/// Memory size limits and expansion rules
pub const memory_limits = @import("constants/memory_limits.zig");

// EIP-4844 blob exports for convenience
/// Blob data structure from EIP-4844
pub const Blob = blob.Blob;
/// KZG commitment structure
pub const KZGCommitment = blob.KZGCommitment;
/// KZG proof structure
pub const KZGProof = blob.KZGProof;
/// Versioned hash for blob commitments
pub const VersionedHash = blob.VersionedHash;
/// Blob gas market implementation
pub const BlobGasMarket = blob.BlobGasMarket;
/// Blob transaction type
pub const BlobTransaction = transaction.BlobTransaction;

// Export all error types for strongly typed error handling
///
/// These error types provide fine-grained error handling throughout
/// the EVM. Each error type corresponds to a specific failure mode,
/// allowing precise error handling and recovery strategies.

// VM error types
/// Errors from VM contract creation operations
pub const CreateContractError = Evm.CreateContractError;
pub const CallContractError = Evm.CallContractError;
pub const ConsumeGasError = Evm.ConsumeGasError;
pub const Create2ContractError = Evm.Create2ContractError;
pub const CallcodeContractError = Evm.CallcodeContractError;
pub const DelegatecallContractError = Evm.DelegatecallContractError;
pub const StaticcallContractError = Evm.StaticcallContractError;
pub const EmitLogError = Evm.EmitLogError;
pub const InitTransactionAccessListError = Evm.InitTransactionAccessListError;
pub const PreWarmAddressesError = Evm.PreWarmAddressesError;
pub const PreWarmStorageSlotsError = Evm.PreWarmStorageSlotsError;
pub const GetAddressAccessCostError = Evm.GetAddressAccessCostError;
pub const GetStorageAccessCostError = Evm.GetStorageAccessCostError;
pub const GetCallCostError = Evm.GetCallCostError;
pub const ValidateStaticContextError = Evm.ValidateStaticContextError;
pub const SetStorageProtectedError = Evm.SetStorageProtectedError;
pub const SetTransientStorageProtectedError = Evm.SetTransientStorageProtectedError;
pub const SetBalanceProtectedError = Evm.SetBalanceProtectedError;
pub const SetCodeProtectedError = Evm.SetCodeProtectedError;
pub const EmitLogProtectedError = Evm.EmitLogProtectedError;
pub const CreateContractProtectedError = Evm.CreateContractProtectedError;
pub const Create2ContractProtectedError = Evm.Create2ContractProtectedError;
pub const ValidateValueTransferError = Evm.ValidateValueTransferError;
pub const SelfdestructProtectedError = Evm.SelfdestructProtectedError;

// VM result types
/// Result of running EVM bytecode
pub const RunResult = Evm.RunResult;
/// Result of CREATE/CREATE2 operations
pub const CreateResult = Evm.CreateResult;
/// Result of CALL/DELEGATECALL/STATICCALL operations
pub const CallResult = Evm.CallResult;

// Memory error types
/// Errors from memory operations (expansion, access)
pub const MemoryError = Memory.MemoryError;

// Stack error types
/// Errors from stack operations (overflow, underflow)
pub const StackError = Stack.Error;

// Access List error types (imported via import statement to avoid circular deps)
/// Access list module for EIP-2929/2930 support
const AccessListModule = @import("access_list/access_list.zig");
/// Error accessing addresses in access list
pub const AccessAddressError = AccessListModule.AccessAddressError;
/// Error accessing storage slots in access list
pub const AccessStorageSlotError = AccessListModule.AccessStorageSlotError;

/// Legacy Contract struct for test compatibility
/// This is a temporary compatibility layer for tests that use the old Contract API
pub const Contract = struct {
    caller: primitives_internal.Address.Address,
    address: primitives_internal.Address.Address,
    value: u256,
    gas: u64,
    bytecode: []const u8,
    input: []const u8,
    is_static: bool,

    pub fn init(
        caller: primitives_internal.Address.Address,
        value: u256,
        bytecode: []const u8,
        gas: u64,
    ) Contract {
        return .{
            .caller = caller,
            .address = primitives_internal.Address.ZERO,
            .value = value,
            .gas = gas,
            .bytecode = bytecode,
            .input = &[_]u8{},
            .is_static = false,
        };
    }

    pub fn init_at_address(
        caller: primitives_internal.Address.Address,
        address: primitives_internal.Address.Address,
        value: u256,
        gas: u64,
        bytecode: []const u8,
        input: []const u8,
        is_static: bool,
    ) Contract {
        return .{
            .caller = caller,
            .address = address,
            .value = value,
            .gas = gas,
            .bytecode = bytecode,
            .input = input,
            .is_static = is_static,
        };
    }

    pub fn init_deployment(
        caller: primitives_internal.Address.Address,
        value: u256,
        bytecode: []const u8,
        gas: u64,
    ) Contract {
        return .{
            .caller = caller,
            .address = primitives_internal.Address.ZERO,
            .value = value,
            .gas = gas,
            .bytecode = bytecode,
            .input = &[_]u8{},
            .is_static = false,
        };
    }

    pub fn deinit(self: *Contract, allocator: std.mem.Allocator, result: ?*anyopaque) void {
        _ = self;
        _ = allocator;
        _ = result;
        // No-op for compatibility
    }
};
/// Error pre-warming addresses
pub const PreWarmAddressesAccessListError = AccessListModule.PreWarmAddressesError;
/// Error pre-warming storage slots
pub const PreWarmStorageSlotsAccessListError = AccessListModule.PreWarmStorageSlotsError;
/// Error initializing transaction access list
pub const InitTransactionError = AccessListModule.InitTransactionError;
/// Error calculating call costs with access list
pub const GetCallCostAccessListError = AccessListModule.GetCallCostError;

// Address error types
/// Error calculating CREATE address
pub const CalculateAddressError = primitives.Address.CalculateAddressError;
/// Error calculating CREATE2 address
pub const CalculateCreate2AddressError = primitives.Address.CalculateCreate2AddressError;

// Execution error
/// Main execution error enumeration used throughout EVM
pub const ExecutionErrorEnum = ExecutionError.Error;

test "Evm module" {
    std.testing.refAllDecls(Evm);
}
test "Stack module" {
    std.testing.refAllDecls(Stack);
}
test "Memory module" {
    std.testing.refAllDecls(Memory);
}
test "ExecutionError module" {
    std.testing.refAllDecls(ExecutionError);
}
test "OpcodeMetadata module" {
    std.testing.refAllDecls(OpcodeMetadata);
}
test "Execution module" {
    std.testing.refAllDecls(execution);
}
test "Instruction module" {
    std.testing.refAllDecls(instruction_module);
}

// Import instruction tag tests
test {
    _ = @import("instruction_tag_test.zig");
}

// Import jumpdest validation tests
test {
    _ = @import("jumpdest_validation_test.zig");
}
