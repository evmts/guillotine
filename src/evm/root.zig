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
//! - **JumpTable**: Maps opcodes to their implementations
//! - **execution/**: Individual opcode implementations
//!
//! ### Error Handling
//! - **ExecutionError**: Unified error type for all execution failures
//! - Strongly typed errors for each component
//! - Error mapping utilities for consistent handling
//!
//! ### Utilities
//! - **CodeAnalysis**: Bytecode analysis and jump destination detection
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

// Import external modules
/// Address utilities for Ethereum addresses
pub const primitives = @import("primitives");

// Import all EVM modules

/// Bytecode analysis for jump destination detection
pub const CodeAnalysis = @import("frame/code_analysis.zig");

/// Contract code and storage management
pub const Contract = @import("frame/contract.zig");

/// Unified error types for EVM execution
pub const ExecutionError = @import("execution/execution_error.zig");

/// Execution result type
pub const ExecutionResult = @import("execution/execution_result.zig");

/// Execution frame/context management
pub const Frame = @import("frame/frame.zig");

/// Execution context providing transaction and block information
pub const Context = @import("access_list/context.zig");

/// Ethereum hardfork configuration
pub const Hardfork = @import("hardforks/hardfork.zig");

/// Opcode to implementation mapping
pub const JumpTable = @import("jump_table/jump_table.zig");

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

/// Storage slot pooling for gas optimization
pub const StoragePool = @import("frame/storage_pool.zig");

/// Main virtual machine implementation
pub const Evm = @import("evm.zig");

/// Builder pattern for constructing EVM instances
pub const EvmBuilder = @import("evm_builder.zig").EvmBuilder;

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

/// Precompiled contracts implementation (IDENTITY, SHA256, etc.)
pub const Precompiles = @import("precompiles/precompiles.zig");

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

/// Tracy profiler support
pub const tracy_support = @import("tracy_support.zig");

/// ECADD precompile (0x06)
pub const ecadd = @import("precompiles/ecadd.zig");

/// ECMUL precompile (0x07)
pub const ecmul = @import("precompiles/ecmul.zig");

/// ECPAIRING precompile (0x08)
pub const ecpairing = @import("precompiles/ecpairing.zig");

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

/// Bit vector utilities for jump destination tracking
pub const bitvec = @import("frame/bitvec.zig");

/// Chain-specific validation rules
pub const chain_rules = @import("hardforks/chain_rules.zig");

/// Hardforks namespace for easier access
pub const hardforks = struct {
    pub const chain_rules = @import("hardforks/chain_rules.zig");
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

// Contract error types
/// General contract operation errors
pub const ContractError = Contract.ContractError;
/// Storage access errors
pub const StorageOperationError = Contract.StorageOperationError;
/// Bytecode analysis errors
pub const CodeAnalysisError = Contract.CodeAnalysisError;
/// Storage warming errors (EIP-2929)
pub const MarkStorageSlotWarmError = Contract.MarkStorageSlotWarmError;

// Access List error types (imported via import statement to avoid circular deps)
/// Access list module for EIP-2929/2930 support
const AccessListModule = @import("access_list/access_list.zig");
/// Error accessing addresses in access list
pub const AccessAddressError = AccessListModule.AccessAddressError;
/// Error accessing storage slots in access list
pub const AccessStorageSlotError = AccessListModule.AccessStorageSlotError;
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
test "Frame module" {
    std.testing.refAllDecls(Frame);
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
test "Contract module" {
    std.testing.refAllDecls(Contract);
}
test "JumpTable module" {
    std.testing.refAllDecls(JumpTable);
}
test "Execution module" {
    std.testing.refAllDecls(execution);
}
