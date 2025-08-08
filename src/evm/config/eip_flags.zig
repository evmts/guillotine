/// EIP (Ethereum Improvement Proposal) flags for EVM configuration
/// These flags control which EIPs are enabled for a given EVM instance
/// Each flag corresponds to a specific EIP that modifies EVM behavior

const std = @import("std");
const Hardfork = @import("../hardforks/hardfork.zig").Hardfork;

/// EIP flags that control EVM behavior
/// Each field represents whether a specific EIP is enabled
pub const EipFlags = struct {
    // ============================================================================
    // Frontier EIPs (base functionality)
    // ============================================================================
    
    // ============================================================================
    // Homestead EIPs
    // ============================================================================
    
    /// EIP-2: Contract creation via transaction
    eip2_homestead_transactions: bool = false,
    
    /// EIP-7: DELEGATECALL opcode
    eip7_delegatecall: bool = false,
    
    /// EIP-8: Forward compatibility requirements
    eip8_forward_compat: bool = false,
    
    // ============================================================================
    // Tangerine Whistle EIPs
    // ============================================================================
    
    /// EIP-150: Gas cost changes for IO-heavy operations
    eip150_gas_costs: bool = false,
    
    // ============================================================================
    // Spurious Dragon EIPs
    // ============================================================================
    
    /// EIP-155: Simple replay attack protection (chain ID)
    eip155_chain_id: bool = false,
    
    /// EIP-160: EXP cost increase
    eip160_exp_cost: bool = false,
    
    /// EIP-161: State trie clearing (empty account removal)
    eip161_state_clear: bool = false,
    
    /// EIP-170: Contract code size limit (24576 bytes)
    eip170_code_size_limit: bool = false,
    
    // ============================================================================
    // Byzantium EIPs
    // ============================================================================
    
    /// EIP-100: Change difficulty adjustment to target mean block time
    eip100_difficulty_adjustment: bool = false,
    
    /// EIP-140: REVERT instruction
    eip140_revert: bool = false,
    
    /// EIP-196: Precompiled contracts for addition and scalar multiplication on elliptic curve
    eip196_ec_add_mul: bool = false,
    
    /// EIP-197: Precompiled contracts for optimal Ate pairing check
    eip197_ec_pairing: bool = false,
    
    /// EIP-198: Big integer modular exponentiation precompile
    eip198_modexp: bool = false,
    
    /// EIP-211: New opcodes: RETURNDATASIZE and RETURNDATACOPY
    eip211_returndatasize: bool = false,
    eip211_returndatacopy: bool = false,
    
    /// EIP-214: New opcode STATICCALL
    eip214_staticcall: bool = false,
    
    /// EIP-649: Metropolis difficulty bomb delay and block reward reduction
    eip649_difficulty_bomb_delay: bool = false,
    
    /// EIP-658: Embedding transaction status code in receipts
    eip658_receipt_status: bool = false,
    
    // ============================================================================
    // Constantinople EIPs
    // ============================================================================
    
    /// EIP-145: Bitwise shifting instructions in EVM
    eip145_bitwise_shifting: bool = false,
    
    /// EIP-1014: Skinny CREATE2
    eip1014_create2: bool = false,
    
    /// EIP-1052: EXTCODEHASH opcode
    eip1052_extcodehash: bool = false,
    
    /// EIP-1234: Constantinople difficulty bomb delay and block reward adjustment
    eip1234_difficulty_bomb_delay: bool = false,
    
    /// EIP-1283: Net gas metering for SSTORE without dirty maps (removed in Petersburg)
    eip1283_sstore_gas_metering: bool = false,
    
    // ============================================================================
    // Petersburg EIPs
    // ============================================================================
    
    /// Removal of EIP-1283 (reverted due to reentrancy concerns)
    petersburg_eip1283_removal: bool = false,
    
    // ============================================================================
    // Istanbul EIPs
    // ============================================================================
    
    /// EIP-152: Add BLAKE2 compression function precompile
    eip152_blake2: bool = false,
    
    /// EIP-1108: Reduce alt_bn128 precompile gas costs
    eip1108_bn128_gas_reduction: bool = false,
    
    /// EIP-1344: ChainID opcode
    eip1344_chainid: bool = false,
    
    /// EIP-1884: Repricing for trie-size-dependent opcodes
    eip1884_repricing: bool = false,
    
    /// EIP-2028: Transaction data gas cost reduction
    eip2028_calldata_gas: bool = false,
    
    /// EIP-2200: Structured definitions for net gas metering
    eip2200_sstore_net_gas: bool = false,
    
    // ============================================================================
    // Berlin EIPs
    // ============================================================================
    
    /// EIP-2565: ModExp gas cost
    eip2565_modexp_gas: bool = false,
    
    /// EIP-2718: Typed transaction envelope
    eip2718_typed_transactions: bool = false,
    
    /// EIP-2929: Gas cost increases for state access opcodes
    eip2929_gas_costs: bool = false,
    
    /// EIP-2930: Optional access lists
    eip2930_access_lists: bool = false,
    
    // ============================================================================
    // London EIPs
    // ============================================================================
    
    /// EIP-1559: Fee market change
    eip1559_fee_market: bool = false,
    
    /// EIP-3198: BASEFEE opcode
    eip3198_basefee: bool = false,
    
    /// EIP-3529: Reduction in refunds
    eip3529_refund_reduction: bool = false,
    
    /// EIP-3541: Reject new contracts starting with 0xEF byte
    eip3541_reject_ef_contracts: bool = false,
    
    /// EIP-3554: Difficulty bomb delay
    eip3554_difficulty_bomb_delay: bool = false,
    
    // ============================================================================
    // Merge EIPs
    // ============================================================================
    
    /// EIP-3675: Upgrade consensus to Proof-of-Stake
    eip3675_pos_upgrade: bool = false,
    
    /// EIP-4399: Supplant DIFFICULTY opcode with PREVRANDAO
    eip4399_prevrandao: bool = false,
    
    // ============================================================================
    // Shanghai EIPs
    // ============================================================================
    
    /// EIP-3651: Warm COINBASE
    eip3651_warm_coinbase: bool = false,
    
    /// EIP-3855: PUSH0 instruction
    eip3855_push0: bool = false,
    
    /// EIP-3860: Limit and meter initcode
    eip3860_limit_initcode: bool = false,
    
    /// EIP-4895: Beacon chain push withdrawals as operations
    eip4895_withdrawals: bool = false,
    
    // ============================================================================
    // Cancun EIPs
    // ============================================================================
    
    /// EIP-1153: Transient storage opcodes
    eip1153_transient_storage: bool = false,
    
    /// EIP-4788: Beacon block root in the EVM
    eip4788_beacon_root: bool = false,
    
    /// EIP-4844: Shard blob transactions
    eip4844_blob_transactions: bool = false,
    
    /// EIP-5656: MCOPY - Memory copying instruction
    eip5656_mcopy: bool = false,
    
    /// EIP-6780: SELFDESTRUCT only in same transaction
    eip6780_selfdestruct_restriction: bool = false,
    
    /// EIP-7516: BLOBBASEFEE opcode
    eip7516_blobbasefee: bool = false,
    
    // ============================================================================
    // Utility Functions
    // ============================================================================
    
    /// Create EipFlags for a specific hardfork
    /// All EIPs up to and including the hardfork are enabled
    pub fn from_hardfork(hardfork: Hardfork) EipFlags {
        var flags = EipFlags{};
        
        // Enable EIPs based on hardfork progression
        // Each hardfork includes all previous hardfork EIPs
        
        if (hardfork.gte(.HOMESTEAD)) {
            flags.eip2_homestead_transactions = true;
            flags.eip7_delegatecall = true;
            flags.eip8_forward_compat = true;
        }
        
        if (hardfork.gte(.TANGERINE_WHISTLE)) {
            flags.eip150_gas_costs = true;
        }
        
        if (hardfork.gte(.SPURIOUS_DRAGON)) {
            flags.eip155_chain_id = true;
            flags.eip160_exp_cost = true;
            flags.eip161_state_clear = true;
            flags.eip170_code_size_limit = true;
        }
        
        if (hardfork.gte(.BYZANTIUM)) {
            flags.eip100_difficulty_adjustment = true;
            flags.eip140_revert = true;
            flags.eip196_ec_add_mul = true;
            flags.eip197_ec_pairing = true;
            flags.eip198_modexp = true;
            flags.eip211_returndatasize = true;
            flags.eip211_returndatacopy = true;
            flags.eip214_staticcall = true;
            flags.eip649_difficulty_bomb_delay = true;
            flags.eip658_receipt_status = true;
        }
        
        if (hardfork.gte(.CONSTANTINOPLE)) {
            flags.eip145_bitwise_shifting = true;
            flags.eip1014_create2 = true;
            flags.eip1052_extcodehash = true;
            flags.eip1234_difficulty_bomb_delay = true;
            // Note: EIP-1283 was added in Constantinople but removed in Petersburg
            if (!hardfork.gte(.PETERSBURG)) {
                flags.eip1283_sstore_gas_metering = true;
            }
        }
        
        if (hardfork.gte(.PETERSBURG)) {
            // Petersburg removed EIP-1283
            flags.eip1283_sstore_gas_metering = false;
            flags.petersburg_eip1283_removal = true;
        }
        
        if (hardfork.gte(.ISTANBUL)) {
            flags.eip152_blake2 = true;
            flags.eip1108_bn128_gas_reduction = true;
            flags.eip1344_chainid = true;
            flags.eip1884_repricing = true;
            flags.eip2028_calldata_gas = true;
            flags.eip2200_sstore_net_gas = true;
        }
        
        if (hardfork.gte(.BERLIN)) {
            flags.eip2565_modexp_gas = true;
            flags.eip2718_typed_transactions = true;
            flags.eip2929_gas_costs = true;
            flags.eip2930_access_lists = true;
        }
        
        if (hardfork.gte(.LONDON)) {
            flags.eip1559_fee_market = true;
            flags.eip3198_basefee = true;
            flags.eip3529_refund_reduction = true;
            flags.eip3541_reject_ef_contracts = true;
            flags.eip3554_difficulty_bomb_delay = true;
        }
        
        if (hardfork.gte(.MERGE)) {
            flags.eip3675_pos_upgrade = true;
            flags.eip4399_prevrandao = true;
        }
        
        if (hardfork.gte(.SHANGHAI)) {
            flags.eip3651_warm_coinbase = true;
            flags.eip3855_push0 = true;
            flags.eip3860_limit_initcode = true;
            flags.eip4895_withdrawals = true;
        }
        
        if (hardfork.gte(.CANCUN)) {
            flags.eip1153_transient_storage = true;
            flags.eip4788_beacon_root = true;
            flags.eip4844_blob_transactions = true;
            flags.eip5656_mcopy = true;
            flags.eip6780_selfdestruct_restriction = true;
            flags.eip7516_blobbasefee = true;
        }
        
        return flags;
    }
    
    /// Apply overrides to EIP flags
    /// This allows enabling/disabling specific EIPs regardless of hardfork
    pub fn apply_overrides(self: *EipFlags, enable: []const u32, disable: []const u32) void {
        // Enable specific EIPs
        for (enable) |eip_num| {
            self.set_eip(eip_num, true);
        }
        
        // Disable specific EIPs
        for (disable) |eip_num| {
            self.set_eip(eip_num, false);
        }
    }
    
    /// Set a specific EIP flag by number
    fn set_eip(self: *EipFlags, eip_num: u32, enabled: bool) void {
        switch (eip_num) {
            2 => self.eip2_homestead_transactions = enabled,
            7 => self.eip7_delegatecall = enabled,
            8 => self.eip8_forward_compat = enabled,
            140 => self.eip140_revert = enabled,
            145 => self.eip145_bitwise_shifting = enabled,
            150 => self.eip150_gas_costs = enabled,
            152 => self.eip152_blake2 = enabled,
            155 => self.eip155_chain_id = enabled,
            160 => self.eip160_exp_cost = enabled,
            161 => self.eip161_state_clear = enabled,
            170 => self.eip170_code_size_limit = enabled,
            196 => self.eip196_ec_add_mul = enabled,
            197 => self.eip197_ec_pairing = enabled,
            198 => self.eip198_modexp = enabled,
            211 => {
                self.eip211_returndatasize = enabled;
                self.eip211_returndatacopy = enabled;
            },
            214 => self.eip214_staticcall = enabled,
            1014 => self.eip1014_create2 = enabled,
            1052 => self.eip1052_extcodehash = enabled,
            1108 => self.eip1108_bn128_gas_reduction = enabled,
            1153 => self.eip1153_transient_storage = enabled,
            1283 => self.eip1283_sstore_gas_metering = enabled,
            1344 => self.eip1344_chainid = enabled,
            1559 => self.eip1559_fee_market = enabled,
            1884 => self.eip1884_repricing = enabled,
            2028 => self.eip2028_calldata_gas = enabled,
            2200 => self.eip2200_sstore_net_gas = enabled,
            2565 => self.eip2565_modexp_gas = enabled,
            2718 => self.eip2718_typed_transactions = enabled,
            2929 => self.eip2929_gas_costs = enabled,
            2930 => self.eip2930_access_lists = enabled,
            3198 => self.eip3198_basefee = enabled,
            3529 => self.eip3529_refund_reduction = enabled,
            3541 => self.eip3541_reject_ef_contracts = enabled,
            3651 => self.eip3651_warm_coinbase = enabled,
            3675 => self.eip3675_pos_upgrade = enabled,
            3855 => self.eip3855_push0 = enabled,
            3860 => self.eip3860_limit_initcode = enabled,
            4399 => self.eip4399_prevrandao = enabled,
            4788 => self.eip4788_beacon_root = enabled,
            4844 => self.eip4844_blob_transactions = enabled,
            4895 => self.eip4895_withdrawals = enabled,
            5656 => self.eip5656_mcopy = enabled,
            6780 => self.eip6780_selfdestruct_restriction = enabled,
            7516 => self.eip7516_blobbasefee = enabled,
            else => {}, // Unknown EIP, ignore
        }
    }
};

test "EipFlags from hardfork - Frontier" {
    const flags = EipFlags.from_hardfork(.FRONTIER);
    
    // Frontier should have no EIPs enabled
    try std.testing.expect(!flags.eip2_homestead_transactions);
    try std.testing.expect(!flags.eip7_delegatecall);
    try std.testing.expect(!flags.eip150_gas_costs);
}

test "EipFlags from hardfork - Homestead" {
    const flags = EipFlags.from_hardfork(.HOMESTEAD);
    
    // Homestead EIPs should be enabled
    try std.testing.expect(flags.eip2_homestead_transactions);
    try std.testing.expect(flags.eip7_delegatecall);
    try std.testing.expect(flags.eip8_forward_compat);
    
    // Later EIPs should not be enabled
    try std.testing.expect(!flags.eip150_gas_costs);
    try std.testing.expect(!flags.eip140_revert);
}

test "EipFlags from hardfork - Cancun" {
    const flags = EipFlags.from_hardfork(.CANCUN);
    
    // All EIPs up to Cancun should be enabled
    try std.testing.expect(flags.eip2_homestead_transactions);
    try std.testing.expect(flags.eip150_gas_costs);
    try std.testing.expect(flags.eip140_revert);
    try std.testing.expect(flags.eip1014_create2);
    try std.testing.expect(flags.eip2929_gas_costs);
    try std.testing.expect(flags.eip3855_push0);
    try std.testing.expect(flags.eip1153_transient_storage);
    try std.testing.expect(flags.eip4844_blob_transactions);
    try std.testing.expect(flags.eip6780_selfdestruct_restriction);
}

test "EipFlags apply overrides" {
    var flags = EipFlags.from_hardfork(.BERLIN);
    
    // Berlin should not have PUSH0 (Shanghai) or transient storage (Cancun)
    try std.testing.expect(!flags.eip3855_push0);
    try std.testing.expect(!flags.eip1153_transient_storage);
    
    // Apply overrides to enable these EIPs
    const enable = [_]u32{ 3855, 1153 };
    const disable = [_]u32{ 2929 }; // Disable an existing Berlin EIP
    
    flags.apply_overrides(&enable, &disable);
    
    // Check overrides were applied
    try std.testing.expect(flags.eip3855_push0);
    try std.testing.expect(flags.eip1153_transient_storage);
    try std.testing.expect(!flags.eip2929_gas_costs);
}