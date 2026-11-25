# EIPs and Hardforks

Feature flags and hardfork configuration for the EVM.

## Overview

This module centralizes protocol evolution: hardfork selection, EIP feature gating, and fork‑specific behavior that other components (opcodes, gas, storage) consult at compile time or runtime.

## Components and Architecture

### Core Files

- **`eips.zig`** - Central EIP configuration system with feature flags
- **`hardfork.zig`** - Hardfork enumeration and version management  

### EIP Modules

- `eips.zig` — feature checks and fork‑aware helpers (e.g., gas rules)
- `hardfork.zig` — fork enum
- `beacon_roots.zig` — EIP‑4788 (Cancun)
- `historical_block_hashes.zig` — EIP‑2935 (Prague)
- `validator_deposits.zig` — EIP‑6110 (Prague)
- `validator_withdrawals.zig` — EIP‑7002 (Prague)
- `authorization_processor.zig` — EIP‑7702

## Key Features

### Hardfork Management
- **Protocol Evolution**: Support for all major Ethereum hardforks from Frontier to Prague
- **Backward Compatibility**: Ensures correct behavior across different network states
- **Feature Gating**: Compile-time and runtime feature flags based on hardfork activation
- **Gas Cost Management**: Hardfork-specific gas pricing and operation costs

### EIP Implementation
- **Modular Design**: Each EIP implemented as a separate, focused module
- **State Consistency**: Proper state transitions for protocol upgrades
- **Validation Logic**: Comprehensive validation for new protocol features
- **Integration Points**: Clean interfaces with the main EVM execution engine

### Configuration
```zig
const eips_mod = @import("eips.zig");
const Eips = eips_mod.Eips;

// Select a fork
const cfg = Eips{ .hardfork = .CANCUN };

if (cfg.eip_4788_beacon_roots_enabled()) {
    // use beacon_roots helpers
}
```

## Integration Points

### EVM Core Integration
- **Opcode Dispatch**: Hardfork-specific opcode availability and gas costs
- **State Access**: Integration with state management for EIP-specific storage
- **Transaction Processing**: Support for new transaction types and validation rules
- **Precompile System**: EIP-specific precompiled contract implementations

### Host Interface
- **Block Context**: Access to block-level data for EIP implementations
- **State Queries**: Read/write access to world state for protocol operations
- **Event Emission**: Log generation for protocol-level events

### Database Integration
- **State Persistence**: Proper storage of EIP-specific state data
- **Migration Support**: State migration logic for protocol upgrades
- **Consistency Guarantees**: Atomic updates during protocol transitions

## Usage Examples

### Basic Hardfork Configuration
```zig
const eips_and_hardforks = @import("eips_and_hardforks");

// Create EIP configuration for Cancun hardfork
const eips = eips_and_hardforks.Eips{ .hardfork = .CANCUN };

// Check if EIP-4788 is active
if (eips.eip_4788_beacon_roots_enabled()) {
    // Process beacon root storage
    try eips_and_hardforks.beacon_roots.store_beacon_root(
        host, block_timestamp, beacon_root
    );
}
```

### Historical Data Access
```zig
if (cfg.eip_2935_historical_block_hashes_enabled()) {
    const hash = try historical_block_hashes.get_block_hash(host, block_number);
}
```

### Validator Operations
```zig
if (cfg.eip_6110_validator_deposits_enabled()) {
    try validator_deposits.process_deposits(host, deposit_data);
}

if (cfg.eip_7002_validator_exits_enabled()) {
    try validator_withdrawals.process_exit_request(host, validator_index);
}
```

### Account Authorization (EIP‑7702)
```zig
if (cfg.eip_7702_eoa_code_enabled()) {
    try authorization_processor.set_eoa_code(host, eoa, code, auth_list);
}
```

## Design Principles

### Modularity
Each EIP is implemented as an independent module with clear boundaries and minimal coupling to other components.

### Performance
- **Compile-time Optimization**: Feature flags resolved at compile time where possible
- **Minimal Runtime Overhead**: Efficient hardfork checks and EIP dispatch
- **Memory Efficiency**: Careful allocation management in protocol operations

### Correctness
- **Specification Compliance**: Strict adherence to EIP specifications
- **Test Coverage**: Comprehensive test suites for all EIP implementations
- **Edge Case Handling**: Robust error handling for protocol edge cases

### Maintainability
- **Clear Documentation**: Each EIP module documents its purpose and behavior
- **Version Tracking**: Clear mapping between EIPs and hardfork activations
- **Future Compatibility**: Architecture supports easy addition of new EIPs

## Testing Strategy

The module includes extensive tests covering:
- **Hardfork Transitions**: Verify correct behavior across protocol upgrades
- **EIP Functionality**: Unit tests for each EIP implementation
- **Integration Tests**: End-to-end testing with EVM execution
- **Edge Cases**: Boundary conditions and error scenarios
- **Consensus Compatibility**: Validation against reference implementations

## Future Extensibility

The architecture is designed to easily support future EIPs:
1. Add new EIP module following established patterns
2. Update `eips.zig` with feature flag method
3. Integrate with relevant EVM components
4. Add comprehensive test coverage
5. Update documentation and examples

This modular approach ensures that Guillotine can quickly adapt to new Ethereum protocol upgrades while maintaining backward compatibility and performance.
