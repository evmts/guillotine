const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const UnifiedOpcode = @import("../../opcodes/opcode.zig").UnifiedOpcode;

/// Comprehensive EVM event system for tracing and observability
pub const EvmEvent = union(enum) {
    // Import all event modules as namespaced types
    pub const lifecycle = @import("lifecycle.zig");
    pub const state = @import("state.zig");
    pub const gas_and_execution = @import("gas_and_execution.zig");
    pub const token = @import("token.zig");
    pub const defi = @import("defi.zig");
    pub const proxy_and_contracts = @import("proxy_and_contracts.zig");
    pub const mainnet_and_layer2 = @import("mainnet_and_layer2.zig");
    pub const metadata = @import("metadata.zig");

    // Transaction lifecycle events
    transaction_start: lifecycle.TransactionStart,
    transaction_end: lifecycle.TransactionEnd,
    block_context: lifecycle.BlockContext,
    
    // Execution events
    vm_step: lifecycle.VmStep,
    execution_halt: lifecycle.ExecutionHalt,
    opcode_frequency: lifecycle.OpcodeFrequency,
    
    // Call frame events
    call_enter: lifecycle.CallEnter,
    call_exit: lifecycle.CallExit,
    create_enter: lifecycle.CreateEnter,
    create_exit: lifecycle.CreateExit,
    
    // State change events
    storage_read: state.StorageRead,
    storage_write: state.StorageWrite,
    storage_cold_access: state.StorageColdAccess,
    transient_storage_read: state.TransientStorageRead,
    transient_storage_write: state.TransientStorageWrite,
    balance_change: state.BalanceChange,
    nonce_change: state.NonceChange,
    code_change: state.CodeChange,
    account_created: state.AccountCreated,
    account_deleted: state.AccountDeleted,
    state_committed: state.StateCommitted,
    
    // Contract events
    selfdestruct: lifecycle.Selfdestruct,
    log_emitted: lifecycle.LogEmitted,
    
    // Gas events
    gas_refund: gas_and_execution.GasRefund,
    gas_stipend: gas_and_execution.GasStipend,
    intrinsic_gas: gas_and_execution.IntrinsicGas,
    memory_expansion: gas_and_execution.MemoryExpansion,
    
    // Function/ABI events
    function_selector: gas_and_execution.FunctionSelector,
    function_call: gas_and_execution.FunctionCall,
    event_decoded: gas_and_execution.EventDecoded,
    
    // External code events
    external_code_copy: gas_and_execution.ExternalCodeCopy,
    external_code_size: gas_and_execution.ExternalCodeSize,
    external_code_hash: gas_and_execution.ExternalCodeHash,
    return_data_copy: gas_and_execution.ReturnDataCopy,
    
    // Jump analysis events
    jump_destination: gas_and_execution.JumpDestination,
    jump_analysis: gas_and_execution.JumpAnalysis,
    push_data: gas_and_execution.PushData,
    
    // Precompile events
    precompile_call: lifecycle.PrecompileCall,
    precompile_result: lifecycle.PrecompileResult,
    
    // Error events
    revert: lifecycle.Revert,
    invalid_opcode: lifecycle.InvalidOpcode,
    out_of_gas: lifecycle.OutOfGas,
    stack_error: lifecycle.StackError,
    memory_error: lifecycle.MemoryError,
    
    // Access list events (EIP-2929/2930)
    account_accessed: state.AccountAccessed,
    storage_accessed: state.StorageAccessed,
    account_warmed: state.AccountWarmed,
    storage_warmed: state.StorageWarmed,
    
    // EIP-1559 events
    base_fee_change: gas_and_execution.BaseFeeChange,
    priority_fee: gas_and_execution.PriorityFee,
    
    // EIP-4844 blob events
    blob_hash_access: gas_and_execution.BlobHashAccess,
    blob_base_fee: gas_and_execution.BlobBaseFee,
    
    // MEV/DeFi events
    swap_detected: defi.SwapDetected,
    flash_loan: defi.FlashLoan,
    arbitrage_opportunity: defi.ArbitrageOpportunity,
    sandwich_attack: defi.SandwichAttack,
    
    // Coinbase/miner events
    coinbase_touch: gas_and_execution.CoinbaseTouch,
    coinbase_payment: gas_and_execution.CoinbasePayment,
    
    // ERC20 detection events
    erc20_transfer: token.Erc20Transfer,
    erc20_approval: token.Erc20Approval,
    erc20_mint: token.Erc20Mint,
    erc20_burn: token.Erc20Burn,
    erc20_function_detected: token.Erc20FunctionDetected,
    erc20_contract_detected: token.Erc20ContractDetected,
    
    // ERC721/1155 detection events
    erc721_transfer: token.Erc721Transfer,
    erc721_approval: token.Erc721Approval,
    erc1155_transfer: token.Erc1155Transfer,
    
    // Token pattern detection
    token_pattern_detected: token.TokenPatternDetected,
    
    // Proxy and notable contract detection
    diamond_proxy_detected: proxy_and_contracts.DiamondProxyDetected,
    proxy_pattern_detected: proxy_and_contracts.ProxyPatternDetected,
    multi_sig_detected: proxy_and_contracts.MultiSigDetected,
    timelock_detected: proxy_and_contracts.TimelockDetected,
    
    // ENS events
    ens_name_registered: proxy_and_contracts.EnsNameRegistered,
    ens_name_renewed: proxy_and_contracts.EnsNameRenewed,
    ens_name_transferred: proxy_and_contracts.EnsNameTransferred,
    ens_resolver_changed: proxy_and_contracts.EnsResolverChanged,
    ens_reverse_claimed: proxy_and_contracts.EnsReverseClaimed,
    ens_text_changed: proxy_and_contracts.EnsTextChanged,
    ens_address_changed: proxy_and_contracts.EnsAddressChanged,
    ens_contenthash_changed: proxy_and_contracts.EnsContenthashChanged,
    
    // DeFi protocol detection
    uniswap_detected: defi.UniswapDetected,
    compound_detected: defi.CompoundDetected,
    aave_detected: defi.AaveDetected,
    maker_detected: defi.MakerDetected,
    curve_detected: defi.CurveDetected,
    
    // Ethereum mainnet-specific events (post-merge)
    beacon_deposit: mainnet_and_layer2.BeaconDeposit,
    validator_withdrawal: mainnet_and_layer2.ValidatorWithdrawal,
    withdrawal_request: mainnet_and_layer2.WithdrawalRequest,
    partial_withdrawal: mainnet_and_layer2.PartialWithdrawal,
    full_withdrawal: mainnet_and_layer2.FullWithdrawal,
    slashing_event: mainnet_and_layer2.SlashingEvent,
    sync_committee_update: mainnet_and_layer2.SyncCommitteeUpdate,
    
    // Layer 2 bridge events
    bridge_deposit: mainnet_and_layer2.BridgeDeposit,
    bridge_withdrawal: mainnet_and_layer2.BridgeWithdrawal,
    bridge_message: mainnet_and_layer2.BridgeMessage,
    rollup_batch: mainnet_and_layer2.RollupBatch,
    state_root_published: mainnet_and_layer2.StateRootPublished,
};

// Event with metadata wrapper
pub const TracedEvent = struct {
    metadata: EvmEvent.metadata.EventMetadata,
    event: EvmEvent,
};

// Helper to categorize events
pub fn getEventCategory(event: EvmEvent) EvmEvent.metadata.EventCategory {
    return switch (event) {
        .transaction_start, .transaction_end, .block_context => .transaction,
        .vm_step, .execution_halt, .opcode_frequency => .execution,
        .call_enter, .call_exit, .create_enter, .create_exit => .call_frame,
        .storage_read, .storage_write, .storage_cold_access, .transient_storage_read, .transient_storage_write, .balance_change, .nonce_change, .code_change, .account_created, .account_deleted, .state_committed => .state_change,
        .selfdestruct, .log_emitted => .contract,
        .precompile_call, .precompile_result => .precompile,
        .revert, .invalid_opcode, .out_of_gas, .stack_error, .memory_error => .@"error",
        .account_accessed, .storage_accessed, .account_warmed, .storage_warmed => .access_list,
        .gas_refund, .gas_stipend, .intrinsic_gas, .memory_expansion => .gas,
        .function_selector, .function_call, .event_decoded => .function_abi,
        .external_code_copy, .external_code_size, .external_code_hash, .return_data_copy => .external_code,
        .jump_destination, .jump_analysis, .push_data => .jump_analysis,
        .base_fee_change, .priority_fee => .eip1559,
        .blob_hash_access, .blob_base_fee => .eip4844,
        .swap_detected, .flash_loan, .arbitrage_opportunity, .sandwich_attack => .mev_defi,
        .coinbase_touch, .coinbase_payment => .coinbase,
        .erc20_transfer, .erc20_approval, .erc20_mint, .erc20_burn, .erc20_function_detected, .erc20_contract_detected, .erc721_transfer, .erc721_approval, .erc1155_transfer, .token_pattern_detected => .token,
        .diamond_proxy_detected, .proxy_pattern_detected, .multi_sig_detected, .timelock_detected => .proxy,
        .ens_name_registered, .ens_name_renewed, .ens_name_transferred, .ens_resolver_changed, .ens_reverse_claimed, .ens_text_changed, .ens_address_changed, .ens_contenthash_changed => .ens,
        .uniswap_detected, .compound_detected, .aave_detected, .maker_detected, .curve_detected => .defi_protocol,
        .beacon_deposit, .validator_withdrawal, .withdrawal_request, .partial_withdrawal, .full_withdrawal, .slashing_event, .sync_committee_update => .beacon_chain,
        .bridge_deposit, .bridge_withdrawal, .bridge_message, .rollup_batch, .state_root_published => .layer2,
    };
}

// Helper to get event severity
pub fn getEventSeverity(event: EvmEvent) EvmEvent.metadata.EventSeverity {
    return switch (event) {
        .vm_step, .storage_read, .account_accessed, .storage_accessed, .push_data, .opcode_frequency, .transient_storage_read, .external_code_size, .external_code_hash => .trace,
        .account_warmed, .storage_warmed, .execution_halt, .jump_destination, .jump_analysis, .function_selector, .return_data_copy, .gas_stipend, .intrinsic_gas => .debug,
        .transaction_start, .transaction_end, .block_context, .call_enter, .call_exit, .create_enter, .create_exit, .log_emitted, .selfdestruct, .storage_write, .balance_change, .nonce_change, .code_change, .account_created, .account_deleted, .state_committed, .storage_cold_access, .transient_storage_write, .memory_expansion, .gas_refund, .base_fee_change, .priority_fee, .blob_hash_access, .blob_base_fee, .coinbase_touch, .coinbase_payment => .info,
        .precompile_call, .precompile_result, .function_call, .event_decoded, .external_code_copy => .debug,
        .revert, .swap_detected, .flash_loan => .warn,
        .invalid_opcode, .out_of_gas, .stack_error, .memory_error => .err,
        .arbitrage_opportunity, .sandwich_attack => .warn,
        .erc20_transfer, .erc20_approval, .erc721_transfer, .erc721_approval, .erc1155_transfer => .info,
        .erc20_mint, .erc20_burn => .info,
        .erc20_function_detected, .erc20_contract_detected, .token_pattern_detected => .debug,
        .diamond_proxy_detected, .proxy_pattern_detected, .multi_sig_detected, .timelock_detected => .info,
        .ens_name_registered, .ens_name_renewed, .ens_name_transferred, .ens_resolver_changed => .info,
        .ens_reverse_claimed, .ens_text_changed, .ens_address_changed, .ens_contenthash_changed => .debug,
        .uniswap_detected, .compound_detected, .aave_detected, .maker_detected, .curve_detected => .info,
        .beacon_deposit, .validator_withdrawal, .full_withdrawal => .info,
        .withdrawal_request, .partial_withdrawal, .sync_committee_update => .debug,
        .slashing_event => .warn,
        .bridge_deposit, .bridge_withdrawal, .rollup_batch, .state_root_published => .info,
        .bridge_message => .debug,
    };
}

// Test helper
test "event size and alignment" {
    const testing = std.testing;
    
    // Ensure reasonable event sizes
    try testing.expect(@sizeOf(EvmEvent) <= 512);
    try testing.expect(@alignOf(EvmEvent) <= 16);
    
    // Verify event categorization
    const step_event = EvmEvent{ .vm_step = undefined };
    try testing.expectEqual(EvmEvent.metadata.EventCategory.execution, getEventCategory(step_event));
    try testing.expectEqual(EvmEvent.metadata.EventSeverity.trace, getEventSeverity(step_event));
    
    const revert_event = EvmEvent{ .revert = undefined };
    try testing.expectEqual(EvmEvent.metadata.EventCategory.@"error", getEventCategory(revert_event));
    try testing.expectEqual(EvmEvent.metadata.EventSeverity.warn, getEventSeverity(revert_event));
}