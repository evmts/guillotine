const primitives = @import("voltaire");
const AccessList = @import("../storage/access_list.zig").AccessList;
const GasConstants = primitives.GasConstants;
pub const Hardfork = primitives.Hardfork;

/// EIP Override entry - allows enabling/disabling specific EIPs
pub const EipOverride = struct {
    eip: u16,
    enabled: bool,
};

pub const BlobValidationError = error{
    BlobTransactionsDisabled,
    NoBlobs,
    TooManyBlobs,
    MaxFeePerBlobGasTooLow,
    InvalidVersionedHash,
    BlobContractCreation,
};

// ============================================================================
// EIP-7702 (Prague): delegation designator
// Source: https://eips.ethereum.org/EIPS/eip-7702
// ============================================================================

/// First three bytes of a delegated EOA's code; the delegate address follows.
pub const DELEGATION_PREFIX = [3]u8{ 0xef, 0x01, 0x00 };
/// Length of the code `0xef0100 || delegate` that EXTCODE* see on a delegated EOA.
pub const DELEGATION_DESIGNATOR_LENGTH: usize = DELEGATION_PREFIX.len + 20;

// ============================================================================
// EIP-7825 (Osaka): transaction gas limit cap
// Source: https://eips.ethereum.org/EIPS/eip-7825
// ============================================================================

/// Maximum gas limit of a single transaction from Osaka, 2^24.
/// A transaction with `gas_limit > TX_GAS_LIMIT_CAP` is invalid; equal is valid.
pub const TX_GAS_LIMIT_CAP: u64 = 16_777_216;

pub const TransactionValidationError = error{
    /// EIP-7825: the transaction gas limit exceeds TX_GAS_LIMIT_CAP.
    GasLimitExceedsCap,
};

/// EIP-7825: reject a transaction whose gas limit exceeds TX_GAS_LIMIT_CAP on Osaka+.
pub fn validateTransactionGasLimit(hardfork: Hardfork, gas_limit: u64) TransactionValidationError!void {
    return (Eips{ .hardfork = hardfork }).validate_transaction_gas_limit(gas_limit);
}

// ============================================================================
// EIP-7934 (Osaka): RLP execution block size limit
// Source: https://eips.ethereum.org/EIPS/eip-7934
// ============================================================================

/// Maximum block size in bytes (10 MiB).
pub const MAX_BLOCK_SIZE: usize = 10_485_760;
/// Margin reserved for the beacon block (2 MiB).
pub const SAFETY_MARGIN: usize = 2_097_152;
/// Maximum RLP-encoded execution block size: MAX_BLOCK_SIZE - SAFETY_MARGIN.
pub const MAX_RLP_BLOCK_SIZE: usize = MAX_BLOCK_SIZE - SAFETY_MARGIN;

pub const BlockValidationError = error{
    /// EIP-7934: the RLP-encoded block is larger than MAX_RLP_BLOCK_SIZE.
    RlpBlockSizeExceedsLimit,
};

/// EIP-7934: reject an RLP-encoded block longer than MAX_RLP_BLOCK_SIZE on Osaka+.
pub fn validateRlpBlockSize(hardfork: Hardfork, rlp_block_size: usize) BlockValidationError!void {
    return (Eips{ .hardfork = hardfork }).validate_rlp_block_size(rlp_block_size);
}

// ============================================================================
// EIP-7918 (Osaka): blob base fee bounded by execution cost
// Source: https://eips.ethereum.org/EIPS/eip-7918
// ============================================================================

/// Reserve price ratio numerator: BLOB_BASE_COST * base_fee_per_gas.
pub const BLOB_BASE_COST: u64 = 8192;
/// Blob gas per blob (2^17), defined by EIP-4844 and used by EIP-7918.
pub const GAS_PER_BLOB: u64 = 131072;

// ============================================================================
// EIP-7892 (Osaka): blob parameter only (BPO) forks and the blob schedule
// ============================================================================

/// Per-fork blob parameters, counted in blobs, as in the EIP-7840 `blobSchedule`.
///
/// Sources:
/// - Cancun 3/6/3338477: EIP-4844 and the EIP-7892 example schedule.
/// - Prague 6/9/5007716: EIP-7691 (TARGET_BLOBS_PER_BLOCK_ELECTRA,
///   MAX_BLOBS_PER_BLOCK_ELECTRA, BLOB_BASE_FEE_UPDATE_FRACTION_PRAGUE).
/// - Osaka 6/9/5007716: Osaka keeps Prague's schedule (EIP-7892 example schedule).
/// - BPO1 10/15/8346193 and BPO2 14/21/11684671: go-ethereum params/config.go
///   DefaultBPO1BlobConfig and DefaultBPO2BlobConfig (mainnet).
/// - BPO mainnet timestamps: EIP-7607 (BPO1 epoch 412672, BPO2 epoch 419072).
pub const BlobScheduleParams = struct {
    target: u64,
    max: u64,
    base_fee_update_fraction: u64,

    pub const CANCUN = BlobScheduleParams{ .target = 3, .max = 6, .base_fee_update_fraction = 3338477 };
    pub const PRAGUE = BlobScheduleParams{ .target = 6, .max = 9, .base_fee_update_fraction = 5007716 };
    pub const OSAKA = BlobScheduleParams{ .target = 6, .max = 9, .base_fee_update_fraction = 5007716 };
    pub const BPO1 = BlobScheduleParams{ .target = 10, .max = 15, .base_fee_update_fraction = 8346193 };
    pub const BPO2 = BlobScheduleParams{ .target = 14, .max = 21, .base_fee_update_fraction = 11684671 };

    /// Target blob gas per block.
    pub fn target_blob_gas(self: BlobScheduleParams) u64 {
        return self.target * GAS_PER_BLOB;
    }

    /// Maximum blob gas per block.
    pub fn max_blob_gas(self: BlobScheduleParams) u64 {
        return self.max * GAS_PER_BLOB;
    }

    /// Schedule a named hardfork starts with. Forks before Cancun return the
    /// Cancun schedule, used only when EIP-4844 is enabled by override.
    /// AMSTERDAM has no schedule of its own yet; per EIP-7892 a fork inherits
    /// the latest schedule entry, which on mainnet is BPO2.
    pub fn forHardfork(hardfork: Hardfork) BlobScheduleParams {
        if (hardfork.isAtLeast(.AMSTERDAM)) return BPO2;
        if (hardfork.isAtLeast(.OSAKA)) return OSAKA;
        if (hardfork.isAtLeast(.PRAGUE)) return PRAGUE;
        return CANCUN;
    }
};

/// Every blob schedule entry, including the BPO forks that are not EVM hardforks.
pub const BlobScheduleFork = enum {
    CANCUN,
    PRAGUE,
    OSAKA,
    BPO1,
    BPO2,

    pub fn params(self: BlobScheduleFork) BlobScheduleParams {
        return switch (self) {
            .CANCUN => BlobScheduleParams.CANCUN,
            .PRAGUE => BlobScheduleParams.PRAGUE,
            .OSAKA => BlobScheduleParams.OSAKA,
            .BPO1 => BlobScheduleParams.BPO1,
            .BPO2 => BlobScheduleParams.BPO2,
        };
    }

    /// Mainnet activation timestamp of this schedule entry.
    pub fn mainnetActivationTimestamp(self: BlobScheduleFork) u64 {
        return switch (self) {
            .CANCUN => 1710338135,
            .PRAGUE => 1746612311,
            .OSAKA => 1764798551,
            .BPO1 => 1765290071,
            .BPO2 => 1767747671,
        };
    }

    /// Mainnet schedule entry active at `timestamp`, or null before Cancun.
    pub fn mainnetAt(timestamp: u64) ?BlobScheduleFork {
        const ordered = [_]BlobScheduleFork{ .BPO2, .BPO1, .OSAKA, .PRAGUE, .CANCUN };
        for (ordered) |fork| {
            if (timestamp >= fork.mainnetActivationTimestamp()) return fork;
        }
        return null;
    }
};

// ============================================================================
// EIP-7685 (Prague): general purpose execution layer requests
// Sources: https://eips.ethereum.org/EIPS/eip-7685, EIP-6110, EIP-7002, EIP-7251
// ============================================================================

/// EIP-6110 mainnet deposit contract.
pub const DEPOSIT_CONTRACT_ADDRESS = @import("validator_deposits.zig").DEPOSIT_CONTRACT_ADDRESS;
/// EIP-7002 withdrawal request predeploy.
pub const WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS = @import("validator_withdrawals.zig").WITHDRAWAL_REQUEST_ADDRESS;
/// EIP-7251 consolidation request predeploy, 0x0000BBdDc7CE488642fb579F8B00f3a590007251.
pub const CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS = primitives.Address.Address{
    .bytes = [_]u8{
        0x00, 0x00, 0xBB, 0xdD, 0xc7, 0xCE, 0x48, 0x86,
        0x42, 0xfb, 0x57, 0x9F, 0x8B, 0x00, 0xf3, 0xa5,
        0x90, 0x00, 0x72, 0x51,
    },
};

/// EIP-7685 request types.
pub const RequestType = enum(u8) {
    /// EIP-6110 deposit requests.
    deposit = 0x00,
    /// EIP-7002 withdrawal requests.
    withdrawal = 0x01,
    /// EIP-7251 consolidation requests.
    consolidation = 0x02,
};

pub const RequestsError = error{
    /// A request has no request_type byte.
    MissingRequestType,
    /// Requests are not ordered by request_type ascending.
    RequestTypesNotAscending,
};

/// sha256("") — the requests_hash of a block with no request data (EIP-7685 Rationale).
pub const EMPTY_REQUESTS_HASH: [32]u8 = .{
    0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
    0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
};

/// Encode a request as `request_type ++ request_data`. The caller owns the result.
pub fn encodeRequest(allocator: std.mem.Allocator, request_type: RequestType, request_data: []const u8) std.mem.Allocator.Error![]u8 {
    const encoded = try allocator.alloc(u8, request_data.len + 1);
    encoded[0] = @intFromEnum(request_type);
    @memcpy(encoded[1..], request_data);
    return encoded;
}

/// EIP-7685 `compute_requests_hash`: sha256 over sha256(request) of every request
/// longer than its type byte. Each request is `request_type ++ request_data`.
pub fn computeRequestsHash(requests: []const []const u8) RequestsError![32]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var outer = Sha256.init(.{});
    var previous_type: ?u8 = null;
    for (requests) |request| {
        if (request.len == 0) return RequestsError.MissingRequestType;
        if (previous_type) |previous| {
            if (request[0] < previous) return RequestsError.RequestTypesNotAscending;
        }
        previous_type = request[0];
        if (request.len == 1) continue;
        var inner: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(request, &inner, .{});
        outer.update(&inner);
    }
    return outer.finalResult();
}

// EIPs is a comptime known configuration of Eip and hardfork specific behavior
// This struct consolidates all EIP-specific logic for the EVM
pub const Eips = struct {
    const Self = @This();

    hardfork: Hardfork,

    /// Overrides for specific EIPs - applied on top of the base hardfork
    /// Use this to enable future EIPs or disable existing ones for testing
    overrides: []const EipOverride = &.{},

    /// EIP-7892: blob schedule override, used to select a BPO fork
    /// (for example `BlobScheduleParams.BPO2`). Null uses `BlobScheduleParams.forHardfork`.
    blob_schedule_override: ?BlobScheduleParams = null,

    /// EIP-7825: reject a gas limit above TX_GAS_LIMIT_CAP when EIP-7825 is active.
    pub fn validate_transaction_gas_limit(self: Self, gas_limit: u64) TransactionValidationError!void {
        if (!self.is_eip_active(7825)) return;
        if (gas_limit > TX_GAS_LIMIT_CAP) return TransactionValidationError.GasLimitExceedsCap;
    }

    /// EIP-7934: reject an RLP-encoded block above MAX_RLP_BLOCK_SIZE when EIP-7934 is active.
    pub fn validate_rlp_block_size(self: Self, rlp_block_size: usize) BlockValidationError!void {
        if (!self.is_eip_active(7934)) return;
        if (rlp_block_size > MAX_RLP_BLOCK_SIZE) return BlockValidationError.RlpBlockSizeExceedsLimit;
    }

    /// EIP-7892: active blob schedule, or null when EIP-4844 is inactive.
    pub fn blob_schedule(self: Self) ?BlobScheduleParams {
        if (!self.is_eip_active(4844)) return null;
        return self.blob_schedule_override orelse BlobScheduleParams.forHardfork(self.hardfork);
    }

    /// EIP-7702: Set EOA account code (Prague)
    /// Allows EOAs to temporarily execute smart contract code for one transaction
    pub fn eip_7702_eoa_code_enabled(self: Self) bool {
        return self.is_eip_active(7702);
    }

    /// EIP-2537: BLS12-381 precompile operations (Prague)
    /// Adds precompiled contracts for BLS12-381 curve operations
    pub fn eip_2537_bls_precompiles_enabled(self: Self) bool {
        return self.is_eip_active(2537);
    }

    /// EIP-2935: Serve historical block hashes from state (Prague)
    /// Stores historical block hashes in the state for easier access
    pub fn eip_2935_historical_block_hashes_enabled(self: Self) bool {
        return self.is_eip_active(2935);
    }

    /// EIP-6110: Supply validator deposits on chain (Prague)
    /// Validator deposits handled directly on execution layer
    pub fn eip_6110_validator_deposits_enabled(self: Self) bool {
        return self.is_eip_active(6110);
    }

    /// EIP-7002: Execution layer triggerable exits (Prague)
    /// Allows triggering validator exits from execution layer
    pub fn eip_7002_validator_exits_enabled(self: Self) bool {
        return self.is_eip_active(7002);
    }

    /// EIP-2929 & EIP-3651: Pre-warm addresses for top-level calls
    /// Warms tx.origin, target address, and coinbase (EIP-3651 for Shanghai+)
    pub fn pre_warm_transaction_addresses(
        self: Self,
        access_list: *AccessList,
        origin: primitives.Address,
        target: ?primitives.Address,
        coinbase: primitives.Address,
    ) !void {
        // Build array of addresses to warm
        var warm_addresses: [3]primitives.Address = undefined;
        var warm_count: usize = 0;

        // Always warm origin
        warm_addresses[warm_count] = origin;
        warm_count += 1;

        // Warm target if provided (not a create operation)
        if (target) |t| {
            warm_addresses[warm_count] = t;
            warm_count += 1;
        }

        // EIP-3651: Warm coinbase for Shanghai+
        if (self.is_eip_active(3651)) {
            warm_addresses[warm_count] = coinbase;
            warm_count += 1;
        }

        if (warm_count > 0) try access_list.pre_warm_addresses(warm_addresses[0..warm_count]);
    }

    /// EIP-3651: Warm COINBASE address at the start of transaction
    /// Shanghai hardfork introduced this optimization
    pub fn eip_3651_warm_coinbase_address(self: Self, access_list: *AccessList, coinbase: primitives.Address.Address) !void {
        if (!self.hardfork.isAtLeast(.SHANGHAI)) return;
        try access_list.pre_warm_addresses(&[_]primitives.Address{coinbase});
    }

    /// EIP-3529: Reduction in refunds & gas refunds for SELFDESTRUCT
    /// London hardfork changed gas refund behavior
    /// - Sets refund counter to gas_used / 5
    /// - No longer fully refunds SELFDESTRUCT
    /// Returns the refund amount to be applied
    pub fn eip_3529_gas_refund_cap(self: Self, gas_used: u64, refund_counter: u64) u64 {
        if (!self.hardfork.isAtLeast(.LONDON)) return @min(refund_counter, gas_used / 2);
        return @min(refund_counter, gas_used / 5);
    }

    /// EIP-2929: Gas cost increases for state access opcodes
    /// Berlin hardfork introduced access lists and changed gas costs
    pub fn eip_2929_cold_sload_cost(self: Self) u64 {
        if (!self.hardfork.isAtLeast(.BERLIN)) return 200;
        return 2100;
    }

    /// EIP-2929: Warm storage access cost
    pub fn eip_2929_warm_storage_read_cost(self: Self) u64 {
        if (!self.hardfork.isAtLeast(.BERLIN)) return 200;
        return 100;
    }

    /// EIP-2929: Cold account access cost
    pub fn eip_2929_cold_account_access_cost(self: Self) u64 {
        if (!self.hardfork.isAtLeast(.BERLIN)) return 700;
        return 2600;
    }

    /// EIP-2929: Warm account access cost
    pub fn eip_2929_warm_account_access_cost(self: Self) u64 {
        if (!self.hardfork.isAtLeast(.BERLIN)) return 700;
        return 100;
    }

    /// EIP-1559: Fee market change for ETH 1.0 chain
    /// London hardfork introduced base fee per gas
    pub fn eip_1559_is_enabled(self: Self) bool {
        return self.is_eip_active(1559);
    }

    /// EIP-3198: BASEFEE opcode
    /// London hardfork added BASEFEE opcode
    pub fn eip_3198_basefee_opcode_enabled(self: Self) bool {
        return self.is_eip_active(3198);
    }

    /// EIP-1153: Transient storage opcodes (TLOAD/TSTORE)
    /// Cancun hardfork added transient storage
    pub fn eip_1153_transient_storage_enabled(self: Self) bool {
        return self.is_eip_active(1153);
    }

    /// EIP-4844: Shard Blob Transactions
    /// Cancun hardfork introduced blob transactions
    pub fn eip_4844_blob_transactions_enabled(self: Self) bool {
        return self.is_eip_active(4844);
    }

    /// EIP-6780: SELFDESTRUCT only in same transaction
    /// Cancun hardfork restricted SELFDESTRUCT behavior
    pub fn eip_6780_selfdestruct_same_transaction_only(self: Self) bool {
        return self.is_eip_active(6780);
    }

    /// EIP-3855: PUSH0 instruction
    /// Shanghai hardfork added PUSH0 instruction
    pub fn eip_3855_push0_enabled(self: Self) bool {
        return self.is_eip_active(3855);
    }

    /// EIP-3860: Limit and meter initcode
    /// Shanghai hardfork added initcode size limit and gas metering
    // Pre-Shanghai: 24KB limit (EIP-170)
    // Post-Shanghai: 48KB limit
    pub fn size_limit(self: Self) u64 {
        if (self.is_eip_active(3860)) return 0xC000;
        return 0x6000;
    }

    /// EIP-3860: Initcode gas cost per word
    // Pre-Shanghai: no additional cost
    // Post-Shanghai: 2 gas per word
    pub fn word_cost(self: Self) u64 {
        if (self.is_eip_active(3860)) return 2;
        return 0;
    }

    /// EIP-7702: Base gas cost per authorization
    /// Prague hardfork introduced authorization lists
    pub fn eip_7702_per_auth_base_cost(self: Self) i64 {
        if (!self.hardfork.isAtLeast(.PRAGUE)) return 0;
        return 12500;
    }

    /// EIP-7702: Additional gas cost for empty account
    /// Prague hardfork introduced authorization lists
    pub fn eip_7702_per_empty_account_cost(self: Self) i64 {
        if (!self.hardfork.isAtLeast(.PRAGUE)) return 0;
        return 25000;
    }

    /// Get all active EIPs for the current hardfork
    pub fn get_active_eips(self: Self) []const u16 {
        return switch (self.hardfork) {
            .FRONTIER => &[_]u16{},
            .HOMESTEAD => &[_]u16{ 2, 7, 8 },
            .DAO => &[_]u16{ 2, 7, 8 }, // DAO fork had no EVM changes
            .TANGERINE_WHISTLE => &[_]u16{ 2, 7, 8, 150 },
            .SPURIOUS_DRAGON => &[_]u16{ 2, 7, 8, 150, 155, 160, 161, 170 },
            .BYZANTIUM => &[_]u16{ 2, 7, 8, 150, 155, 160, 161, 170, 100, 140, 196, 197, 198, 211, 214, 649, 658 },
            .CONSTANTINOPLE => &[_]u16{ 2, 7, 8, 150, 155, 160, 161, 170, 100, 140, 196, 197, 198, 211, 214, 649, 658, 145, 1014, 1052, 1283 },
            .PETERSBURG => &[_]u16{ 2, 7, 8, 150, 155, 160, 161, 170, 100, 140, 196, 197, 198, 211, 214, 649, 658, 145, 1014, 1052, 1283 },
            .ISTANBUL => &[_]u16{ 2, 7, 8, 150, 155, 160, 161, 170, 100, 140, 196, 197, 198, 211, 214, 649, 658, 145, 1014, 1052, 1283, 152, 1108, 1344, 1884, 2028, 2200 },
            .MUIR_GLACIER => &[_]u16{ 2, 7, 8, 150, 155, 160, 161, 170, 100, 140, 196, 197, 198, 211, 214, 649, 658, 145, 1014, 1052, 1283, 152, 1108, 1344, 1884, 2028, 2200 },
            .BERLIN => &[_]u16{ 2, 7, 8, 150, 155, 160, 161, 170, 100, 140, 196, 197, 198, 211, 214, 649, 658, 145, 1014, 1052, 1283, 152, 1108, 1344, 1884, 2028, 2200, 2565, 2718, 2929, 2930 },
            .LONDON => &[_]u16{ 2, 7, 8, 150, 155, 160, 161, 170, 100, 140, 196, 197, 198, 211, 214, 649, 658, 145, 1014, 1052, 1283, 152, 1108, 1344, 1884, 2028, 2200, 2565, 2718, 2929, 2930, 1559, 3198, 3529, 3541 },
            .ARROW_GLACIER => &[_]u16{ 2, 7, 8, 150, 155, 160, 161, 170, 100, 140, 196, 197, 198, 211, 214, 649, 658, 145, 1014, 1052, 1283, 152, 1108, 1344, 1884, 2028, 2200, 2565, 2718, 2929, 2930, 1559, 3198, 3529, 3541, 4345 },
            .GRAY_GLACIER => &[_]u16{ 2, 7, 8, 150, 155, 160, 161, 170, 100, 140, 196, 197, 198, 211, 214, 649, 658, 145, 1014, 1052, 1283, 152, 1108, 1344, 1884, 2028, 2200, 2565, 2718, 2929, 2930, 1559, 3198, 3529, 3541, 4345, 5133 },
            .MERGE => &[_]u16{ 2, 7, 8, 150, 155, 160, 161, 170, 100, 140, 196, 197, 198, 211, 214, 649, 658, 145, 1014, 1052, 1283, 152, 1108, 1344, 1884, 2028, 2200, 2565, 2718, 2929, 2930, 1559, 3198, 3529, 3541, 4345, 5133, 3675, 4399 },
            .SHANGHAI => &[_]u16{ 2, 7, 8, 150, 155, 160, 161, 170, 100, 140, 196, 197, 198, 211, 214, 649, 658, 145, 1014, 1052, 1283, 152, 1108, 1344, 1884, 2028, 2200, 2565, 2718, 2929, 2930, 1559, 3198, 3529, 3541, 4345, 5133, 3675, 4399, 3651, 3855, 3860, 4895 },
            .CANCUN => &[_]u16{ 2, 7, 8, 150, 155, 160, 161, 170, 100, 140, 196, 197, 198, 211, 214, 649, 658, 145, 1014, 1052, 1283, 152, 1108, 1344, 1884, 2028, 2200, 2565, 2718, 2929, 2930, 1559, 3198, 3529, 3541, 4345, 5133, 3675, 4399, 3651, 3855, 3860, 4895, 1153, 4788, 4844, 5656, 6780, 7516 },
            .PRAGUE => &[_]u16{ 2, 7, 8, 150, 155, 160, 161, 170, 100, 140, 196, 197, 198, 211, 214, 649, 658, 145, 1014, 1052, 1283, 152, 1108, 1344, 1884, 2028, 2200, 2565, 2718, 2929, 2930, 1559, 3198, 3529, 3541, 4345, 5133, 3675, 4399, 3651, 3855, 3860, 4895, 1153, 4788, 4844, 5656, 6780, 7516, 2537, 2935, 6110, 7002, 7251, 7623, 7685, 7691, 7702 },
            .OSAKA => &[_]u16{ 2, 7, 8, 150, 155, 160, 161, 170, 100, 140, 196, 197, 198, 211, 214, 649, 658, 145, 1014, 1052, 1283, 152, 1108, 1344, 1884, 2028, 2200, 2565, 2718, 2929, 2930, 1559, 3198, 3529, 3541, 4345, 5133, 3675, 4399, 3651, 3855, 3860, 4895, 1153, 4788, 4844, 5656, 6780, 7516, 2537, 2935, 6110, 7002, 7251, 7623, 7685, 7691, 7702, 7594, 7823, 7825, 7883, 7892, 7918, 7934, 7939, 7951 },
            // Glamsterdam has no scheduled EIPs yet; it keeps Osaka's set.
            .AMSTERDAM => &[_]u16{ 2, 7, 8, 150, 155, 160, 161, 170, 100, 140, 196, 197, 198, 211, 214, 649, 658, 145, 1014, 1052, 1283, 152, 1108, 1344, 1884, 2028, 2200, 2565, 2718, 2929, 2930, 1559, 3198, 3529, 3541, 4345, 5133, 3675, 4399, 3651, 3855, 3860, 4895, 1153, 4788, 4844, 5656, 6780, 7516, 2537, 2935, 6110, 7002, 7251, 7623, 7685, 7691, 7702, 7594, 7823, 7825, 7883, 7892, 7918, 7934, 7939, 7951 },
        };
    }

    /// Check if a specific EIP is active
    pub fn is_eip_active(self: Self, eip: u16) bool {
        // First check overrides
        for (self.overrides) |override| {
            if (override.eip == eip) return override.enabled;
        }

        // Then check base hardfork
        const active_eips = self.get_active_eips();
        for (active_eips) |active_eip| if (active_eip == eip) return true;
        return false;
    }

    /// EIP-170: Get maximum contract code size based on hardfork
    pub fn eip_170_max_code_size(self: Self) u32 {
        // EIP-170: Contract code size limit (Spurious Dragon)
        if (!self.is_eip_active(170)) return 0xFFFFFF; // No limit
        return 0x6000; // 24KB limit
    }

    /// EIP-3541: Check if bytecode starting with 0xEF should be rejected
    pub fn eip_3541_should_reject_ef_bytecode(self: Self) bool {
        return self.is_eip_active(3541);
    }

    /// EIP-160: Get gas cost for EXP opcode exponent byte
    pub fn eip_160_exp_byte_gas_cost(self: Self) u64 {
        if (!self.is_eip_active(160)) return 10; // Pre-EIP-160
        return 50; // Post-EIP-160
    }

    /// Get CREATE opcode gas cost
    pub fn create_gas_cost(_: Self) u64 {
        return 32000;
    }

    /// EIP-4399: Check if PREVRANDAO should be used instead of DIFFICULTY
    pub fn eip_4399_use_prevrandao(self: Self) bool {
        return self.is_eip_active(4399);
    }

    /// EIP-2028: Get calldata gas costs (reduced non-zero byte cost)
    pub fn eip_2028_calldata_gas_cost(self: Self, is_zero: bool) u64 {
        if (is_zero) return GasConstants.TxDataZeroGas;
        if (!self.is_eip_active(2028)) return GasConstants.TxDataNonZeroGasPreIstanbul;
        return GasConstants.TxDataNonZeroGas;
    }

    /// EIP-2028: Get calldata gas cost multiplier for non-zero bytes
    pub fn eip_2028_calldata_gas_cost_multiplier(self: Self) u64 {
        if (!self.is_eip_active(2028)) return GasConstants.TxDataNonZeroGasMultiplierPreIstanbul;
        return GasConstants.TxDataNonZeroGasMultiplier;
    }

    /// EIP-1153: Check if transient storage is available
    pub fn eip_1153_has_transient_storage(self: Self) bool {
        return self.is_eip_active(1153);
    }

    /// EIP-3855: Check if PUSH0 opcode is available
    pub fn eip_3855_has_push0(self: Self) bool {
        return self.is_eip_active(3855);
    }

    /// EIP-3198: Check if BASEFEE opcode is available
    pub fn eip_3198_has_basefee(self: Self) bool {
        return self.is_eip_active(3198);
    }

    /// EIP-5656: Check if MCOPY opcode is available
    pub fn eip_5656_has_mcopy(self: Self) bool {
        return self.is_eip_active(5656);
    }

    /// EIP-4844: Check if blob transactions are supported
    pub fn eip_4844_has_blob_transactions(self: Self) bool {
        return self.is_eip_active(4844);
    }

    /// Get SSTORE gas costs based on hardfork and state
    ///
    /// Implements:
    /// - Frontier-Byzantium and Petersburg: Simple gas model
    /// - EIP-1283 (Constantinople): Net gas metering for SSTORE
    /// - EIP-2200 (Istanbul): Reentrancy protection (2300 gas minimum)
    /// - EIP-2929 (Berlin): Cold storage access costs
    /// - EIP-3529 (London): Reduced gas refunds
    ///
    /// Parameters:
    /// - current: Current value in storage slot
    /// - new: New value being written
    /// - original: Original value at start of transaction
    /// - is_cold: Whether this is a cold storage access (EIP-2929)
    ///
    /// Returns: SstoreGasCost with gas cost and signed change to the refund counter
    pub fn sstore_gas_cost(self: Self, current: u256, new: u256, original: u256, is_cold: bool) SstoreGasCost {
        return @import("../frame/fork_gas.zig").sstoreCost(self.hardfork, original, current, new, is_cold);
    }

    pub const SstoreGasCost = @import("../frame/fork_gas.zig").SstoreCost;

    /// EIP-4788: Check if address is the beacon roots contract
    pub fn eip_4788_is_beacon_roots_address(self: Self, address: primitives.Address) bool {
        if (!self.hardfork.isAtLeast(.CANCUN)) return false;
        const beacon_roots = @import("beacon_roots.zig");
        return std.mem.eql(u8, &address.bytes, &beacon_roots.BEACON_ROOTS_ADDRESS.bytes);
    }

    /// EIP-2935: Check if address is the historical block hashes contract
    pub fn eip_2935_is_historical_block_hashes_address(self: Self, address: primitives.Address) bool {
        if (!self.hardfork.isAtLeast(.PRAGUE)) return false;
        const historical_block_hashes = @import("historical_block_hashes.zig");
        return std.mem.eql(u8, &address.bytes, &historical_block_hashes.HISTORY_CONTRACT_ADDRESS.bytes);
    }

    /// EIP-7702: Get effective code address handling delegation
    pub fn eip_7702_get_effective_code_address(self: Self, account: ?@import("../storage/database_interface_account.zig").Account, address: primitives.Address) primitives.Address {
        if (!self.hardfork.isAtLeast(.PRAGUE)) return address;
        if (account) |acc| {
            if (acc.get_effective_code_address()) |delegated| {
                return delegated;
            }
        }
        return address;
    }

    /// EIP-3541: Should reject bytecode starting with 0xEF
    pub fn eip_3541_should_reject_create_with_ef_bytecode(self: Self, bytecode: []const u8) bool {
        if (!self.is_eip_active(3541)) return false;
        return bytecode.len > 0 and bytecode[0] == 0xEF;
    }

    /// EIP-2929: Warm contract address for execution
    pub fn warm_contract_for_execution(self: Self, access_list: anytype, address: primitives.Address) !void {
        if (!self.is_eip_active(2929)) return;
        _ = try access_list.access_address(address);
    }

    /// EIP-211: Clear returndata buffer after CREATE/CREATE2
    /// Byzantium hardfork introduced RETURNDATA opcodes and clearing rules
    pub fn eip_211_should_clear_returndata_on_create(self: Self) bool {
        return self.is_eip_active(211);
    }

    /// EIP-214: Check if log emission is allowed (not in static context)
    pub fn is_log_emission_allowed(is_static: bool) bool {
        return !is_static;
    }

    /// EIP-6780: Handle SELFDESTRUCT based on creation in same transaction
    pub fn handle_selfdestruct(
        self: Self,
        created_in_tx: bool,
        contract_address: primitives.Address,
        recipient: primitives.Address,
        self_destruct: anytype,
        database: anytype,
        journal: anytype,
        snapshot_id: anytype,
    ) !void {
        if (!self.hardfork.isAtLeast(.CANCUN)) {
            // Pre-Cancun: always mark for full destruction
            try self_destruct.mark_for_destruction(contract_address, recipient);
            return;
        }

        // EIP-6780: Only destroy if created in same transaction
        if (created_in_tx) {
            // Full destruction: transfer balance and mark for deletion
            try self_destruct.mark_for_destruction(contract_address, recipient);
        } else {
            // Only transfer balance, don't destroy the contract
            const contract_account = try database.get_account(contract_address.bytes);
            if (contract_account) |account| {
                if (account.balance > 0) {
                    // Transfer balance to recipient
                    try journal.record_balance_change(snapshot_id, contract_address, account.balance);
                    try journal.record_balance_change(snapshot_id, recipient, 0);

                    // Update balances
                    var sender_account = account;
                    sender_account.balance = 0;
                    try database.set_account(contract_address.bytes, sender_account);

                    const Account = @import("../storage/database_interface_account.zig").Account;
                    var recipient_account = (try database.get_account(recipient.bytes)) orelse Account.zero();
                    recipient_account.balance +%= account.balance;
                    try database.set_account(recipient.bytes, recipient_account);
                }
            }
        }
    }

    /// EIP-3529: Apply gas refund after transaction
    pub fn eip_3529_apply_gas_refund(self: Self, initial_gas: u64, gas_left: u64, gas_refund_counter: u64) u64 {
        const gas_used = initial_gas - gas_left;
        const capped_refund = self.eip_3529_gas_refund_cap(gas_used, gas_refund_counter);
        return @min(initial_gas, gas_left + capped_refund);
    }

    /// Target blob gas per block for the active blob schedule.
    pub fn target_blob_gas(self: Self) u64 {
        const schedule = self.blob_schedule() orelse return 0;
        return schedule.target_blob_gas();
    }

    /// Maximum blob gas per block for the active blob schedule.
    pub fn max_blob_gas(self: Self) u64 {
        const schedule = self.blob_schedule() orelse return 0;
        return schedule.max_blob_gas();
    }

    /// Blob base-fee update fraction for the active blob schedule.
    pub fn blob_base_fee_update_fraction(self: Self) u64 {
        const schedule = self.blob_schedule() orelse return 0;
        return schedule.base_fee_update_fraction;
    }

    /// Calculate the current blob gas price from excess blob gas.
    pub fn blob_gas_price(self: Self, excess_gas: u64) u64 {
        if (!self.is_eip_active(4844)) return 0;
        return primitives.Blob.calculateBlobGasPriceWithFraction(
            excess_gas,
            self.blob_base_fee_update_fraction(),
        );
    }

    /// Validate all EIP-4844 transaction-level constraints available to the EVM.
    pub fn validate_blob_gas(
        self: Self,
        is_blob_transaction: bool,
        blob_versioned_hashes: []const [32]u8,
        max_fee_per_blob_gas: u256,
        current_blob_base_fee: u256,
        to: ?primitives.Address,
    ) BlobValidationError!void {
        if (!is_blob_transaction) return;
        if (!self.is_eip_active(4844)) return BlobValidationError.BlobTransactionsDisabled;
        if (to == null) return BlobValidationError.BlobContractCreation;
        if (blob_versioned_hashes.len == 0) return BlobValidationError.NoBlobs;

        const max_blobs = self.max_blob_gas() / primitives.Blob.BLOB_GAS_PER_BLOB;
        if (blob_versioned_hashes.len > max_blobs) return BlobValidationError.TooManyBlobs;
        if (max_fee_per_blob_gas < current_blob_base_fee) return BlobValidationError.MaxFeePerBlobGasTooLow;

        for (blob_versioned_hashes) |hash| {
            if (!primitives.Blob.isValidVersionedHash(.{ .bytes = hash })) {
                return BlobValidationError.InvalidVersionedHash;
            }
        }
    }

    /// Actual burned blob fee for a transaction.
    pub fn blob_gas_cost(self: Self, base_fee: u256, blob_count: usize) u256 {
        if (!self.is_eip_active(4844)) return 0;
        const blob_gas = @as(u256, blob_count) * primitives.Blob.BLOB_GAS_PER_BLOB;
        return blob_gas *| base_fee;
    }

    /// Maximum blob cost used only for the upfront affordability check.
    pub fn max_blob_gas_cost(self: Self, max_fee_per_blob_gas: u256, blob_count: usize) u256 {
        if (!self.is_eip_active(4844)) return 0;
        const blob_gas = @as(u256, blob_count) * primitives.Blob.BLOB_GAS_PER_BLOB;
        return blob_gas *| max_fee_per_blob_gas;
    }

    /// `calc_excess_blob_gas`: excess blob gas of the next block from its parent header.
    ///
    /// EIP-7918 (Osaka): when the execution cost of blob gas
    /// (`BLOB_BASE_COST * parent_base_fee_per_gas`) exceeds the parent blob fee
    /// (`GAS_PER_BLOB * get_base_fee_per_blob_gas(parent)`), excess grows by
    /// `parent_blob_gas_used * (max - target) / max` instead of falling.
    /// The result saturates at maxInt(u64), the width of the header field.
    pub fn excess_blob_gas(self: Self, parent_excess: u64, parent_blob_gas_used: u64, parent_base_fee_per_gas: u256) u64 {
        const schedule = self.blob_schedule() orelse return 0;
        const target_blob_gas_value: u128 = schedule.target_blob_gas();
        const parent_total = @as(u128, parent_excess) + parent_blob_gas_used;
        if (parent_total < target_blob_gas_value) return 0;

        if (self.is_eip_active(7918)) {
            const parent_blob_base_fee = primitives.Blob.calculateBlobGasPriceWithFractionU256(
                parent_excess,
                schedule.base_fee_update_fraction,
            );
            const execution_cost = std.math.mulWide(u256, BLOB_BASE_COST, parent_base_fee_per_gas);
            const blob_cost = std.math.mulWide(u256, GAS_PER_BLOB, parent_blob_base_fee);
            if (execution_cost > blob_cost) {
                const growth = @as(u128, parent_blob_gas_used) * (schedule.max - schedule.target) / schedule.max;
                return std.math.cast(u64, @as(u128, parent_excess) + growth) orelse std.math.maxInt(u64);
            }
        }

        return std.math.cast(u64, parent_total - target_blob_gas_value) orelse std.math.maxInt(u64);
    }

    /// Count calldata tokens using the byte prices active for this hardfork.
    pub fn tokens_in_calldata(self: Self, input: []const u8) u64 {
        const zero_bytes_count = std.mem.count(u8, input, "\x00");
        const non_zero_bytes_count = input.len - zero_bytes_count;
        return @as(u64, @intCast(zero_bytes_count)) + @as(u64, @intCast(non_zero_bytes_count)) * self.eip_2028_calldata_gas_cost_multiplier();
    }

    /// EIP-3860: Get initcode word cost.
    pub fn eip_3860_initcode_word_cost(self: Self, input_len: usize) u64 {
        if (!self.is_eip_active(3860)) return 0;
        return GasConstants.wordCount(input_len) * GasConstants.InitcodeWordGas;
    }

    /// Get intrinsic gas cost for a transaction depending on whether it creates a contract.
    pub fn intrinsic_gas_cost(_: Self, is_create: bool) u64 {
        return if (is_create) GasConstants.TxGasContractCreation else GasConstants.TxGas;
    }

    /// Get calldata gas cost, including EIP-3860 initcode word metering for creation transactions.
    pub fn calldata_gas_cost(self: Self, calldata_tokens: u64, is_create: bool, input_len: usize) u64 {
        const initcode_cost = if (is_create) self.eip_3860_initcode_word_cost(input_len) else 0;
        return calldata_tokens * GasConstants.TxDataZeroGas + initcode_cost;
    }

    /// Get the EIP-7623 floor gas a transaction is forced to consume.
    pub fn floor_gas_cost(self: Self, calldata_tokens: u64) u64 {
        if (!self.is_eip_active(7623)) return 0;
        return GasConstants.TxGas + calldata_tokens * GasConstants.TxDataFloorTokenGas;
    }

    /// Calculate the effective gas price and miner tip for a transaction.
    pub fn effective_gas_price(self: Self, base_fee_per_gas: u256, max_fee_per_gas: u256, max_priority_fee_per_gas: u256) struct { effective_gas_price: u256, miner_fee: u256 } {
        if (!self.is_eip_active(1559)) {
            return .{ .effective_gas_price = max_fee_per_gas, .miner_fee = max_fee_per_gas };
        }

        if (max_fee_per_gas < base_fee_per_gas) {
            return .{ .effective_gas_price = max_fee_per_gas, .miner_fee = 0 };
        }

        const max_priority_fee = @min(max_priority_fee_per_gas, max_fee_per_gas - base_fee_per_gas);
        return .{ .effective_gas_price = base_fee_per_gas + max_priority_fee, .miner_fee = max_priority_fee };
    }
};

const std = @import("std");

test "eip_3529_gas_refund_cap pre-London" {
    const eips = Eips{ .hardfork = Hardfork.ISTANBUL };

    // Pre-London: refund up to half of gas used
    try std.testing.expectEqual(@as(u64, 50), eips.eip_3529_gas_refund_cap(100, 100)); // min(100, 100/2)
    try std.testing.expectEqual(@as(u64, 50), eips.eip_3529_gas_refund_cap(100, 60)); // min(60, 100/2)
    try std.testing.expectEqual(@as(u64, 25), eips.eip_3529_gas_refund_cap(100, 25)); // min(25, 100/2)
}

test "eip_3529_gas_refund_cap post-London" {
    const eips = Eips{ .hardfork = Hardfork.LONDON };

    // Post-London: refund up to one fifth of gas used
    try std.testing.expectEqual(@as(u64, 20), eips.eip_3529_gas_refund_cap(100, 100)); // min(100, 100/5)
    try std.testing.expectEqual(@as(u64, 20), eips.eip_3529_gas_refund_cap(100, 60)); // min(60, 100/5)
    try std.testing.expectEqual(@as(u64, 10), eips.eip_3529_gas_refund_cap(100, 10)); // min(10, 100/5)
}

test "eip_3529_gas_refund_cap edge cases" {
    const pre_london = Eips{ .hardfork = Hardfork.ISTANBUL };
    const post_london = Eips{ .hardfork = Hardfork.LONDON };

    // Zero gas used
    try std.testing.expectEqual(@as(u64, 0), pre_london.eip_3529_gas_refund_cap(0, 100));
    try std.testing.expectEqual(@as(u64, 0), post_london.eip_3529_gas_refund_cap(0, 100));

    // Zero refund counter
    try std.testing.expectEqual(@as(u64, 0), pre_london.eip_3529_gas_refund_cap(1000, 0));
    try std.testing.expectEqual(@as(u64, 0), post_london.eip_3529_gas_refund_cap(1000, 0));

    // Large gas amounts
    const large_gas = 1_000_000_000;
    try std.testing.expectEqual(@as(u64, large_gas / 2), pre_london.eip_3529_gas_refund_cap(large_gas, large_gas));
    try std.testing.expectEqual(@as(u64, large_gas / 5), post_london.eip_3529_gas_refund_cap(large_gas, large_gas));

    // Odd numbers (test division)
    try std.testing.expectEqual(@as(u64, 75), pre_london.eip_3529_gas_refund_cap(151, 100)); // min(100, 151/2=75)
    try std.testing.expectEqual(@as(u64, 30), post_london.eip_3529_gas_refund_cap(151, 100)); // min(100, 151/5=30)
}

test "eip_3651_warm_coinbase_address" {
    const pre_shanghai = Eips{ .hardfork = Hardfork.LONDON };
    const post_shanghai = Eips{ .hardfork = Hardfork.SHANGHAI };

    const allocator = std.testing.allocator;
    var access_list = AccessList.init(allocator);
    defer access_list.deinit();

    const coinbase = primitives.Address.from_hex("0x1234567890123456789012345678901234567890") catch unreachable;

    // Pre-Shanghai: should not warm coinbase (no-op)
    try pre_shanghai.eip_3651_warm_coinbase_address(&access_list, coinbase);
    try std.testing.expect(!access_list.is_address_warm(coinbase));

    // Post-Shanghai: should warm coinbase
    try post_shanghai.eip_3651_warm_coinbase_address(&access_list, coinbase);
    try std.testing.expect(access_list.is_address_warm(coinbase));
}

test "eip_2929_storage_costs pre-Berlin" {
    const eips = Eips{ .hardfork = Hardfork.ISTANBUL };

    try std.testing.expectEqual(@as(u64, 200), eips.eip_2929_cold_sload_cost());
    try std.testing.expectEqual(@as(u64, 200), eips.eip_2929_warm_storage_read_cost());
    try std.testing.expectEqual(@as(u64, 700), eips.eip_2929_cold_account_access_cost());
    try std.testing.expectEqual(@as(u64, 700), eips.eip_2929_warm_account_access_cost());
}

test "eip_2929_storage_costs post-Berlin" {
    const eips = Eips{ .hardfork = Hardfork.BERLIN };

    try std.testing.expectEqual(@as(u64, 2100), eips.eip_2929_cold_sload_cost());
    try std.testing.expectEqual(@as(u64, 100), eips.eip_2929_warm_storage_read_cost());
    try std.testing.expectEqual(@as(u64, 2600), eips.eip_2929_cold_account_access_cost());
    try std.testing.expectEqual(@as(u64, 100), eips.eip_2929_warm_account_access_cost());
}

test "eip_1559_fee_market" {
    const pre_london = Eips{ .hardfork = Hardfork.BERLIN };
    const post_london = Eips{ .hardfork = Hardfork.LONDON };

    try std.testing.expect(!pre_london.eip_1559_is_enabled());
    try std.testing.expect(post_london.eip_1559_is_enabled());
}

test "eip_3198_basefee_opcode" {
    const pre_london = Eips{ .hardfork = Hardfork.BERLIN };
    const post_london = Eips{ .hardfork = Hardfork.LONDON };

    try std.testing.expect(!pre_london.eip_3198_basefee_opcode_enabled());
    try std.testing.expect(post_london.eip_3198_basefee_opcode_enabled());
}

test "eip_1153_transient_storage" {
    const pre_cancun = Eips{ .hardfork = Hardfork.SHANGHAI };
    const post_cancun = Eips{ .hardfork = Hardfork.CANCUN };

    try std.testing.expect(!pre_cancun.eip_1153_transient_storage_enabled());
    try std.testing.expect(post_cancun.eip_1153_transient_storage_enabled());
}

test "eip_4844_blob_transactions" {
    const pre_cancun = Eips{ .hardfork = Hardfork.SHANGHAI };
    const post_cancun = Eips{ .hardfork = Hardfork.CANCUN };

    try std.testing.expect(!pre_cancun.eip_4844_blob_transactions_enabled());
    try std.testing.expect(post_cancun.eip_4844_blob_transactions_enabled());
}

test "eip_6780_selfdestruct_restriction" {
    const pre_cancun = Eips{ .hardfork = Hardfork.SHANGHAI };
    const post_cancun = Eips{ .hardfork = Hardfork.CANCUN };

    try std.testing.expect(!pre_cancun.eip_6780_selfdestruct_same_transaction_only());
    try std.testing.expect(post_cancun.eip_6780_selfdestruct_same_transaction_only());
}

test "eip_3855_push0_instruction" {
    const pre_shanghai = Eips{ .hardfork = Hardfork.LONDON };
    const post_shanghai = Eips{ .hardfork = Hardfork.SHANGHAI };

    try std.testing.expect(!pre_shanghai.eip_3855_push0_enabled());
    try std.testing.expect(post_shanghai.eip_3855_push0_enabled());
}

test "eip_3860_initcode_limits" {
    const pre_shanghai = Eips{ .hardfork = Hardfork.LONDON };
    const post_shanghai = Eips{ .hardfork = Hardfork.SHANGHAI };

    // Size limits
    try std.testing.expectEqual(@as(u64, 0x6000), pre_shanghai.size_limit()); // 24KB
    try std.testing.expectEqual(@as(u64, 0xC000), post_shanghai.size_limit()); // 48KB

    // Gas costs
    try std.testing.expectEqual(@as(u64, 2), pre_shanghai.word_cost());
    try std.testing.expectEqual(@as(u64, 2), post_shanghai.word_cost());
}

test "get_active_eips frontier" {
    const eips = Eips{ .hardfork = Hardfork.FRONTIER };
    const active = eips.get_active_eips();
    try std.testing.expectEqual(@as(usize, 0), active.len);
}

test "get_active_eips homestead" {
    const eips = Eips{ .hardfork = Hardfork.HOMESTEAD };
    const active = eips.get_active_eips();
    try std.testing.expectEqual(@as(usize, 3), active.len);

    // Should contain EIPs 2, 7, 8
    try std.testing.expect(eips.is_eip_active(2));
    try std.testing.expect(eips.is_eip_active(7));
    try std.testing.expect(eips.is_eip_active(8));
    try std.testing.expect(!eips.is_eip_active(150)); // Not in Homestead
}

test "get_active_eips berlin" {
    const eips = Eips{ .hardfork = Hardfork.BERLIN };

    // Berlin should include EIP-2929 and EIP-2930
    try std.testing.expect(eips.is_eip_active(2929));
    try std.testing.expect(eips.is_eip_active(2930));
    try std.testing.expect(!eips.is_eip_active(1559)); // Not yet in Berlin
}

test "get_active_eips london" {
    const eips = Eips{ .hardfork = Hardfork.LONDON };

    // London should include EIP-1559, EIP-3198, EIP-3529
    try std.testing.expect(eips.is_eip_active(1559));
    try std.testing.expect(eips.is_eip_active(3198));
    try std.testing.expect(eips.is_eip_active(3529));
    try std.testing.expect(!eips.is_eip_active(3651)); // Not yet in London
}

test "get_active_eips shanghai" {
    const eips = Eips{ .hardfork = Hardfork.SHANGHAI };

    // Shanghai should include EIP-3651, EIP-3855, EIP-3860
    try std.testing.expect(eips.is_eip_active(3651));
    try std.testing.expect(eips.is_eip_active(3855));
    try std.testing.expect(eips.is_eip_active(3860));
    try std.testing.expect(!eips.is_eip_active(1153)); // Not yet in Shanghai
}

test "get_active_eips cancun" {
    const eips = Eips{ .hardfork = Hardfork.CANCUN };

    // Cancun should include EIP-1153, EIP-4844, EIP-6780
    try std.testing.expect(eips.is_eip_active(1153));
    try std.testing.expect(eips.is_eip_active(4844));
    try std.testing.expect(eips.is_eip_active(6780));
    try std.testing.expect(eips.is_eip_active(7516)); // BLOBBASEFEE

    // Should also include all previous EIPs
    try std.testing.expect(eips.is_eip_active(2)); // From Homestead
    try std.testing.expect(eips.is_eip_active(1559)); // From London
    try std.testing.expect(eips.is_eip_active(3855)); // From Shanghai
}

test "get_active_eips prague" {
    const eips = Eips{ .hardfork = Hardfork.PRAGUE };

    // Prague should include new EIPs
    try std.testing.expect(eips.is_eip_active(2537)); // BLS precompiles
    try std.testing.expect(eips.is_eip_active(7702)); // EOA code execution
    try std.testing.expect(eips.is_eip_active(7002)); // Validator exits

    // Should also include all Cancun EIPs
    try std.testing.expect(eips.is_eip_active(1153));
    try std.testing.expect(eips.is_eip_active(4844));
    try std.testing.expect(eips.is_eip_active(6780));
}

test "is_eip_active non-existent EIP" {
    const eips = Eips{ .hardfork = Hardfork.CANCUN };
    const prague = Eips{ .hardfork = Hardfork.PRAGUE };

    // Test non-existent EIP numbers
    try std.testing.expect(!eips.is_eip_active(9999));
    try std.testing.expect(!eips.is_eip_active(0));
    try std.testing.expect(!eips.is_eip_active(1));
    try std.testing.expect(!prague.is_eip_active(9999));
}

test "prague eip features" {
    const pre_prague = Eips{ .hardfork = Hardfork.CANCUN };
    const prague = Eips{ .hardfork = Hardfork.PRAGUE };

    // Test Prague-specific EIP features
    try std.testing.expect(!pre_prague.eip_7702_eoa_code_enabled());
    try std.testing.expect(prague.eip_7702_eoa_code_enabled());

    try std.testing.expect(!pre_prague.eip_2537_bls_precompiles_enabled());
    try std.testing.expect(prague.eip_2537_bls_precompiles_enabled());

    try std.testing.expect(!pre_prague.eip_7002_validator_exits_enabled());
    try std.testing.expect(prague.eip_7002_validator_exits_enabled());
}

test "hardfork progression" {
    // Test that later hardforks include features from earlier ones
    const istanbul = Eips{ .hardfork = Hardfork.ISTANBUL };
    const berlin = Eips{ .hardfork = Hardfork.BERLIN };
    const london = Eips{ .hardfork = Hardfork.LONDON };
    const shanghai = Eips{ .hardfork = Hardfork.SHANGHAI };
    const cancun = Eips{ .hardfork = Hardfork.CANCUN };
    const prague = Eips{ .hardfork = Hardfork.PRAGUE };

    // EIP-2929 should be active from Berlin onwards
    try std.testing.expect(!istanbul.is_eip_active(2929));
    try std.testing.expect(berlin.is_eip_active(2929));
    try std.testing.expect(london.is_eip_active(2929));
    try std.testing.expect(shanghai.is_eip_active(2929));
    try std.testing.expect(cancun.is_eip_active(2929));
    try std.testing.expect(prague.is_eip_active(2929));

    // EIP-1559 should be active from London onwards
    try std.testing.expect(!berlin.is_eip_active(1559));
    try std.testing.expect(london.is_eip_active(1559));
    try std.testing.expect(shanghai.is_eip_active(1559));
    try std.testing.expect(cancun.is_eip_active(1559));
    try std.testing.expect(prague.is_eip_active(1559));

    // EIP-7702 should only be active from Prague onwards
    try std.testing.expect(!cancun.is_eip_active(7702));
    try std.testing.expect(prague.is_eip_active(7702));
}

test "gas_cost_consistency" {
    // Test that gas costs are consistent across different EIPs
    const pre_berlin = Eips{ .hardfork = Hardfork.ISTANBUL };
    const post_berlin = Eips{ .hardfork = Hardfork.BERLIN };

    // Before Berlin, cold and warm costs should be the same
    try std.testing.expectEqual(pre_berlin.eip_2929_cold_account_access_cost(), pre_berlin.eip_2929_warm_account_access_cost());

    // After Berlin, cold costs should be higher than warm costs
    try std.testing.expect(post_berlin.eip_2929_cold_account_access_cost() >
        post_berlin.eip_2929_warm_account_access_cost());

    try std.testing.expect(post_berlin.eip_2929_cold_sload_cost() >
        post_berlin.eip_2929_warm_storage_read_cost());
}

test "edge_case_hardforks" {
    // Test edge case hardforks like PETERSBURG (reverts Constantinople features)
    const constantinople = Eips{ .hardfork = Hardfork.CONSTANTINOPLE };
    const petersburg = Eips{ .hardfork = Hardfork.PETERSBURG };

    // Both should have the same active EIPs (Petersburg == Constantinople without CREATE2)
    const const_eips = constantinople.get_active_eips();
    const petersburg_eips = petersburg.get_active_eips();
    try std.testing.expectEqualSlices(u16, const_eips, petersburg_eips);

    // Test glacier hardforks (only difficulty bomb delays)
    const arrow_glacier = Eips{ .hardfork = Hardfork.ARROW_GLACIER };
    const gray_glacier = Eips{ .hardfork = Hardfork.GRAY_GLACIER };

    // Should include difficulty bomb delay EIPs
    try std.testing.expect(arrow_glacier.is_eip_active(4345));
    try std.testing.expect(gray_glacier.is_eip_active(5133));
}

test "comprehensive_eip_coverage" {
    const cancun = Eips{ .hardfork = Hardfork.CANCUN };
    const prague = Eips{ .hardfork = Hardfork.PRAGUE };

    // Test a comprehensive set of important EIPs are active in Cancun
    const cancun_eips = [_]u16{
        2, // Homestead
        150, // Tangerine Whistle
        155, // Spurious Dragon
        658, // Byzantium
        1014, // Constantinople
        2929, // Berlin
        1559, // London
        3651, // Shanghai
        1153, // Cancun
        4844, // Cancun
        6780, // Cancun
    };

    for (cancun_eips) |eip| {
        try std.testing.expect(cancun.is_eip_active(eip));
    }

    // Test Prague includes Cancun EIPs plus new ones
    for (cancun_eips) |eip| {
        try std.testing.expect(prague.is_eip_active(eip));
    }
    try std.testing.expect(prague.is_eip_active(7702)); // Prague-specific
}

test "initcode_size_boundaries" {
    const pre_shanghai = Eips{ .hardfork = Hardfork.LONDON };
    const post_shanghai = Eips{ .hardfork = Hardfork.SHANGHAI };

    // Test exact boundary values
    try std.testing.expectEqual(@as(u64, 24576), pre_shanghai.size_limit()); // 0x6000
    try std.testing.expectEqual(@as(u64, 49152), post_shanghai.size_limit()); // 0xC000

    // Test that the limit doubled
    try std.testing.expectEqual(pre_shanghai.size_limit() * 2, post_shanghai.size_limit());
}

test "specific eip helper functions" {
    const frontier = Eips{ .hardfork = Hardfork.FRONTIER };
    const spurious = Eips{ .hardfork = Hardfork.SPURIOUS_DRAGON };
    const london = Eips{ .hardfork = Hardfork.LONDON };
    const shanghai = Eips{ .hardfork = Hardfork.SHANGHAI };
    const cancun = Eips{ .hardfork = Hardfork.CANCUN };
    const merge = Eips{ .hardfork = Hardfork.MERGE };

    // Test max code size
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), frontier.eip_170_max_code_size());
    try std.testing.expectEqual(@as(u32, 0x6000), spurious.eip_170_max_code_size());

    // Test 0xEF bytecode rejection
    try std.testing.expect(!frontier.eip_3541_should_reject_ef_bytecode());
    try std.testing.expect(london.eip_3541_should_reject_ef_bytecode());

    // Test EXP gas cost
    try std.testing.expectEqual(@as(u64, 10), frontier.eip_160_exp_byte_gas_cost());
    try std.testing.expectEqual(@as(u64, 50), spurious.eip_160_exp_byte_gas_cost());

    // Test PREVRANDAO vs DIFFICULTY
    try std.testing.expect(!london.eip_4399_use_prevrandao());
    try std.testing.expect(merge.eip_4399_use_prevrandao());

    // Test opcode availability
    try std.testing.expect(!london.eip_3855_has_push0());
    try std.testing.expect(shanghai.eip_3855_has_push0());

    try std.testing.expect(!shanghai.eip_5656_has_mcopy());
    try std.testing.expect(cancun.eip_5656_has_mcopy());

    try std.testing.expect(!frontier.eip_3198_has_basefee());
    try std.testing.expect(london.eip_3198_has_basefee());

    try std.testing.expect(!shanghai.eip_1153_has_transient_storage());
    try std.testing.expect(cancun.eip_1153_has_transient_storage());

    try std.testing.expect(!shanghai.eip_4844_has_blob_transactions());
    try std.testing.expect(cancun.eip_4844_has_blob_transactions());
}

test "calldata gas costs" {
    const homestead = Eips{ .hardfork = Hardfork.HOMESTEAD };
    const istanbul = Eips{ .hardfork = Hardfork.ISTANBUL };

    // Zero bytes always cost 4 gas
    try std.testing.expectEqual(@as(u64, 4), homestead.eip_2028_calldata_gas_cost(true));
    try std.testing.expectEqual(@as(u64, 4), istanbul.eip_2028_calldata_gas_cost(true));

    // Non-zero bytes: 68 pre-Istanbul, 16 post-Istanbul
    try std.testing.expectEqual(@as(u64, 68), homestead.eip_2028_calldata_gas_cost(false));
    try std.testing.expectEqual(@as(u64, 16), istanbul.eip_2028_calldata_gas_cost(false));
}

test "sstore gas costs - pre-Constantinople" {
    const frontier = Eips{ .hardfork = Hardfork.FRONTIER };
    const byzantium = Eips{ .hardfork = Hardfork.BYZANTIUM };

    // Set from zero to non-zero
    var cost = frontier.sstore_gas_cost(0, 1, 0, false);
    try std.testing.expectEqual(@as(u64, 20000), cost.gas);
    try std.testing.expectEqual(@as(i64, 0), cost.refund);

    // Clear from non-zero to zero (refund differs by hardfork)
    cost = byzantium.sstore_gas_cost(1, 0, 1, false);
    try std.testing.expectEqual(@as(u64, 5000), cost.gas);
    try std.testing.expectEqual(@as(i64, 15000), cost.refund);

    // Modify non-zero value
    cost = frontier.sstore_gas_cost(1, 2, 1, false);
    try std.testing.expectEqual(@as(u64, 5000), cost.gas);
    try std.testing.expectEqual(@as(i64, 0), cost.refund);
}

test "sstore gas costs - Constantinople EIP-1283" {
    const constantinople = Eips{ .hardfork = Hardfork.CONSTANTINOPLE };

    // No-op: storing same value
    var cost = constantinople.sstore_gas_cost(42, 42, 42, false);
    try std.testing.expectEqual(@as(u64, 200), cost.gas);
    try std.testing.expectEqual(@as(i64, 0), cost.refund);

    // Set from zero to non-zero (first time in tx)
    cost = constantinople.sstore_gas_cost(0, 1, 0, false);
    try std.testing.expectEqual(@as(u64, 20000), cost.gas);
    try std.testing.expectEqual(@as(i64, 0), cost.refund);

    // Clear non-zero to zero (first time in tx)
    cost = constantinople.sstore_gas_cost(42, 0, 42, false);
    try std.testing.expectEqual(@as(u64, 5000), cost.gas);
    try std.testing.expectEqual(@as(i64, 15000), cost.refund);

    // Dirty write (already modified in tx)
    cost = constantinople.sstore_gas_cost(1, 2, 0, false);
    try std.testing.expectEqual(@as(u64, 200), cost.gas);

    // Revert to original value
    cost = constantinople.sstore_gas_cost(2, 0, 0, false);
    try std.testing.expectEqual(@as(u64, 200), cost.gas);
    try std.testing.expectEqual(@as(i64, 19800), cost.refund);
}

test "sstore gas costs - Berlin EIP-2929 cold/warm" {
    const berlin = Eips{ .hardfork = Hardfork.BERLIN };

    // Warm access (no-op)
    var cost = berlin.sstore_gas_cost(42, 42, 42, false);
    try std.testing.expectEqual(@as(u64, 100), cost.gas);

    // Cold access (no-op)
    cost = berlin.sstore_gas_cost(42, 42, 42, true);
    try std.testing.expectEqual(@as(u64, 2200), cost.gas); // 2100 + 100

    // Cold access + set zero to non-zero
    cost = berlin.sstore_gas_cost(0, 1, 0, true);
    try std.testing.expectEqual(@as(u64, 22100), cost.gas); // 2100 + 20000

    // Warm access + modify
    cost = berlin.sstore_gas_cost(1, 2, 1, false);
    try std.testing.expectEqual(@as(u64, 2900), cost.gas);
}

test "sstore gas costs - London EIP-3529 reduced refunds" {
    const istanbul = Eips{ .hardfork = Hardfork.ISTANBUL };
    const london = Eips{ .hardfork = Hardfork.LONDON };

    // Clear storage - Istanbul gives 15000 refund
    var cost = istanbul.sstore_gas_cost(42, 0, 42, false);
    try std.testing.expectEqual(@as(i64, 15000), cost.refund);

    // Clear storage - London gives 4800 refund (EIP-3529)
    cost = london.sstore_gas_cost(42, 0, 42, false);
    try std.testing.expectEqual(@as(i64, 4800), cost.refund);
}

test "sstore gas costs - complex state transitions" {
    const london = Eips{ .hardfork = Hardfork.LONDON };

    // Scenario: 0 -> 1 -> 2 in same transaction
    // First write: 0 -> 1 (original=0, current=0, new=1)
    var cost = london.sstore_gas_cost(0, 1, 0, false);
    try std.testing.expectEqual(@as(u64, 20000), cost.gas);
    try std.testing.expectEqual(@as(i64, 0), cost.refund);

    // Second write: 1 -> 2 (original=0, current=1, new=2)
    cost = london.sstore_gas_cost(1, 2, 0, false);
    try std.testing.expectEqual(@as(u64, 100), cost.gas); // Dirty write

    // Scenario: 42 -> 0 -> 10 in same transaction
    // First write: 42 -> 0 (original=42, current=42, new=0)
    cost = london.sstore_gas_cost(42, 0, 42, false);
    try std.testing.expectEqual(@as(u64, 2900), cost.gas);
    try std.testing.expectEqual(@as(i64, 4800), cost.refund);

    // Second write: 0 -> 10 (original=42, current=0, new=10)
    // This removes the refund we gave earlier
    cost = london.sstore_gas_cost(0, 10, 42, false);
    try std.testing.expectEqual(@as(u64, 100), cost.gas); // Dirty write
    // Refund should be negative (removing previous refund)
    try std.testing.expectEqual(@as(i64, -4800), cost.refund);

    // Scenario: 42 -> 10 -> 42 in same transaction (revert to original)
    // First write: 42 -> 10 (original=42, current=42, new=10)
    cost = london.sstore_gas_cost(42, 10, 42, false);
    try std.testing.expectEqual(@as(u64, 2900), cost.gas);

    // Second write: 10 -> 42 (original=42, current=10, new=42) - reverting!
    cost = london.sstore_gas_cost(10, 42, 42, false);
    try std.testing.expectEqual(@as(u64, 100), cost.gas); // Dirty write
    try std.testing.expectEqual(@as(i64, 2800), cost.refund); // Refund for reverting
}

test "sstore gas costs - all hardfork transitions" {
    // Test gas costs across all major hardforks
    const frontier = Eips{ .hardfork = Hardfork.FRONTIER };
    const constantinople = Eips{ .hardfork = Hardfork.CONSTANTINOPLE };
    const istanbul = Eips{ .hardfork = Hardfork.ISTANBUL };
    const berlin = Eips{ .hardfork = Hardfork.BERLIN };
    const london = Eips{ .hardfork = Hardfork.LONDON };

    // Test case: No-op (same value write)
    // Frontier: 5000 gas
    var cost = frontier.sstore_gas_cost(42, 42, 42, false);
    try std.testing.expectEqual(@as(u64, 5000), cost.gas);

    // Constantinople: 200 gas (EIP-1283)
    cost = constantinople.sstore_gas_cost(42, 42, 42, false);
    try std.testing.expectEqual(@as(u64, 200), cost.gas);

    // Berlin: 100 gas (EIP-2929 warm)
    cost = berlin.sstore_gas_cost(42, 42, 42, false);
    try std.testing.expectEqual(@as(u64, 100), cost.gas);

    // Test case: Set zero to non-zero
    // All hardforks: 20000 gas (+ cold access in Berlin+)
    cost = frontier.sstore_gas_cost(0, 1, 0, false);
    try std.testing.expectEqual(@as(u64, 20000), cost.gas);
    cost = berlin.sstore_gas_cost(0, 1, 0, true);
    try std.testing.expectEqual(@as(u64, 22100), cost.gas); // 2100 cold + 20000

    // Test case: Clear storage (non-zero to zero)
    // Frontier: 5000 gas, 15000 refund
    cost = frontier.sstore_gas_cost(42, 0, 42, false);
    try std.testing.expectEqual(@as(u64, 5000), cost.gas);
    try std.testing.expectEqual(@as(i64, 15000), cost.refund);

    // Istanbul: 5000 gas, 15000 refund (unchanged)
    cost = istanbul.sstore_gas_cost(42, 0, 42, false);
    try std.testing.expectEqual(@as(i64, 15000), cost.refund);

    // London: 2900 gas, 4800 refund (EIP-3529)
    cost = london.sstore_gas_cost(42, 0, 42, false);
    try std.testing.expectEqual(@as(i64, 4800), cost.refund);
}

test "sstore gas costs - edge cases" {
    const london = Eips{ .hardfork = Hardfork.LONDON };

    // Edge case: Writing zero to zero (no-op)
    var cost = london.sstore_gas_cost(0, 0, 0, false);
    try std.testing.expectEqual(@as(u64, 100), cost.gas);
    try std.testing.expectEqual(@as(i64, 0), cost.refund);

    // Edge case: Maximum u256 values
    const max = std.math.maxInt(u256);
    cost = london.sstore_gas_cost(0, max, 0, false);
    try std.testing.expectEqual(@as(u64, 20000), cost.gas);

    cost = london.sstore_gas_cost(max, 0, max, false);
    try std.testing.expectEqual(@as(u64, 2900), cost.gas);
    try std.testing.expectEqual(@as(i64, 4800), cost.refund);

    // Edge case: Cold access adds exactly 2100 gas
    cost = london.sstore_gas_cost(42, 42, 42, true);
    const warm_cost = london.sstore_gas_cost(42, 42, 42, false);
    try std.testing.expectEqual(warm_cost.gas + 2100, cost.gas);
}

test "sstore gas costs - EIP-1283 refund scenarios" {
    const istanbul = Eips{ .hardfork = Hardfork.ISTANBUL };

    // Scenario 1: Revert to original zero
    // original=0, current=10, new=0 (reverting to original)
    var cost = istanbul.sstore_gas_cost(10, 0, 0, false);
    try std.testing.expectEqual(@as(u64, 800), cost.gas); // Dirty write
    try std.testing.expectEqual(@as(i64, 19200), cost.refund); // Refund for reverting

    // Scenario 2: Revert to original non-zero
    // original=42, current=10, new=42 (reverting to original)
    cost = istanbul.sstore_gas_cost(10, 42, 42, false);
    try std.testing.expectEqual(@as(u64, 800), cost.gas); // Dirty write
    try std.testing.expectEqual(@as(i64, 4200), cost.refund); // Refund for reverting

    // Scenario 3: Clear then set (remove refund)
    // original=42, current=0, new=10 (was cleared, now setting)
    cost = istanbul.sstore_gas_cost(0, 10, 42, false);
    try std.testing.expectEqual(@as(u64, 800), cost.gas); // Dirty write
    try std.testing.expectEqual(@as(i64, -15000), cost.refund);
}

test "sstore gas costs - comprehensive state matrix" {
    const london = Eips{ .hardfork = Hardfork.LONDON };

    // Matrix of all possible state transitions:
    // (original, current, new) -> (gas, refund)

    // Row 1: original = 0
    var cost = london.sstore_gas_cost(0, 0, 0, false); // 0->0->0
    try std.testing.expectEqual(@as(u64, 100), cost.gas); // No-op

    cost = london.sstore_gas_cost(0, 1, 0, false); // 0->0->1
    try std.testing.expectEqual(@as(u64, 20000), cost.gas); // Set

    cost = london.sstore_gas_cost(1, 0, 0, false); // 0->1->0
    try std.testing.expectEqual(@as(u64, 100), cost.gas); // Dirty revert
    try std.testing.expectEqual(@as(i64, 19900), cost.refund); // Refund

    cost = london.sstore_gas_cost(1, 2, 0, false); // 0->1->2
    try std.testing.expectEqual(@as(u64, 100), cost.gas); // Dirty write

    // Row 2: original = 42 (non-zero)
    cost = london.sstore_gas_cost(42, 42, 42, false); // 42->42->42
    try std.testing.expectEqual(@as(u64, 100), cost.gas); // No-op

    cost = london.sstore_gas_cost(42, 0, 42, false); // 42->42->0
    try std.testing.expectEqual(@as(u64, 2900), cost.gas); // Clear
    try std.testing.expectEqual(@as(i64, 4800), cost.refund); // Refund

    cost = london.sstore_gas_cost(42, 10, 42, false); // 42->42->10
    try std.testing.expectEqual(@as(u64, 2900), cost.gas); // Reset

    cost = london.sstore_gas_cost(0, 42, 42, false); // 42->0->42
    try std.testing.expectEqual(@as(u64, 100), cost.gas); // Dirty revert

    cost = london.sstore_gas_cost(10, 42, 42, false); // 42->10->42
    try std.testing.expectEqual(@as(u64, 100), cost.gas); // Dirty revert
    try std.testing.expectEqual(@as(i64, 2800), cost.refund); // Refund

    cost = london.sstore_gas_cost(10, 20, 42, false); // 42->10->20
    try std.testing.expectEqual(@as(u64, 100), cost.gas); // Dirty write
}

test "sstore gas costs - Berlin cold access combinations" {
    const berlin = Eips{ .hardfork = Hardfork.BERLIN };

    // All operations with cold access should add 2100 gas
    const cold_access_cost: u64 = 2100;

    // No-op with cold access
    var cost = berlin.sstore_gas_cost(42, 42, 42, true);
    try std.testing.expectEqual(@as(u64, 2200), cost.gas); // 2100 + 100

    // Set from zero with cold access
    cost = berlin.sstore_gas_cost(0, 1, 0, true);
    try std.testing.expectEqual(@as(u64, 22100), cost.gas); // 2100 + 20000

    // Clear with cold access
    cost = berlin.sstore_gas_cost(42, 0, 42, true);
    try std.testing.expectEqual(@as(u64, 5000), cost.gas); // 2100 + 2900

    // Dirty write with cold access
    cost = berlin.sstore_gas_cost(1, 2, 0, true);
    try std.testing.expectEqual(@as(u64, 2200), cost.gas); // 2100 + 100

    // Verify cold access cost is exactly 2100 for all cases
    const warm = berlin.sstore_gas_cost(42, 42, 42, false);
    const cold = berlin.sstore_gas_cost(42, 42, 42, true);
    try std.testing.expectEqual(warm.gas + cold_access_cost, cold.gas);
}

test "EIP overrides - enable future EIPs" {
    // Test enabling Shanghai features on London
    const london_with_push0 = Eips{
        .hardfork = Hardfork.LONDON,
        .overrides = &[_]EipOverride{
            .{ .eip = 3855, .enabled = true }, // PUSH0
            .{ .eip = 3651, .enabled = true }, // Warm COINBASE
        },
    };

    // London doesn't normally have these
    const plain_london = Eips{ .hardfork = Hardfork.LONDON };
    try std.testing.expect(!plain_london.is_eip_active(3855));
    try std.testing.expect(!plain_london.is_eip_active(3651));

    // But with overrides, they're enabled
    try std.testing.expect(london_with_push0.is_eip_active(3855));
    try std.testing.expect(london_with_push0.is_eip_active(3651));
    try std.testing.expect(london_with_push0.eip_3855_push0_enabled());

    // Other London features still work
    try std.testing.expect(london_with_push0.is_eip_active(1559));
    try std.testing.expect(london_with_push0.eip_1559_is_enabled());
}

test "EIP overrides - disable existing EIPs" {
    // Test disabling Cancun features
    const cancun_restricted = Eips{
        .hardfork = Hardfork.CANCUN,
        .overrides = &[_]EipOverride{
            .{ .eip = 4844, .enabled = false }, // Disable blob transactions
            .{ .eip = 6780, .enabled = false }, // Disable SELFDESTRUCT restriction
            .{ .eip = 1153, .enabled = false }, // Disable transient storage
        },
    };

    // Cancun normally has these
    const plain_cancun = Eips{ .hardfork = Hardfork.CANCUN };
    try std.testing.expect(plain_cancun.is_eip_active(4844));
    try std.testing.expect(plain_cancun.is_eip_active(6780));
    try std.testing.expect(plain_cancun.is_eip_active(1153));

    // But with overrides, they're disabled
    try std.testing.expect(!cancun_restricted.is_eip_active(4844));
    try std.testing.expect(!cancun_restricted.is_eip_active(6780));
    try std.testing.expect(!cancun_restricted.is_eip_active(1153));
    try std.testing.expect(!cancun_restricted.eip_4844_blob_transactions_enabled());
    try std.testing.expect(!cancun_restricted.eip_6780_selfdestruct_same_transaction_only());
    try std.testing.expect(!cancun_restricted.eip_1153_transient_storage_enabled());

    // Other Cancun features still enabled
    try std.testing.expect(cancun_restricted.is_eip_active(3855)); // PUSH0 from Shanghai
    try std.testing.expect(cancun_restricted.is_eip_active(1559)); // Fee market from London
}

test "EIP overrides - mixed enable/disable" {
    // Complex scenario: Berlin base with some London features enabled, some Berlin features disabled
    const custom_berlin = Eips{
        .hardfork = Hardfork.BERLIN,
        .overrides = &[_]EipOverride{
            // Enable London features
            .{ .eip = 1559, .enabled = true }, // Fee market
            .{ .eip = 3198, .enabled = true }, // BASEFEE
            .{ .eip = 3529, .enabled = true }, // Refund reduction
            // Disable a Berlin feature
            .{ .eip = 2929, .enabled = false }, // Access list gas changes
        },
    };

    // Check enabled London features
    try std.testing.expect(custom_berlin.is_eip_active(1559));
    try std.testing.expect(custom_berlin.is_eip_active(3198));
    try std.testing.expect(custom_berlin.is_eip_active(3529));
    try std.testing.expect(custom_berlin.eip_1559_is_enabled());
    try std.testing.expect(custom_berlin.eip_3198_basefee_opcode_enabled());

    // Check disabled Berlin feature
    try std.testing.expect(!custom_berlin.is_eip_active(2929));
    // Gas costs should revert to pre-Berlin values
    try std.testing.expectEqual(@as(u64, 200), custom_berlin.eip_2929_cold_sload_cost());
    try std.testing.expectEqual(@as(u64, 700), custom_berlin.eip_2929_cold_account_access_cost());

    // Check that overrides affect dependent functionality
    try std.testing.expectEqual(@as(u64, 20), custom_berlin.eip_3529_gas_refund_cap(100, 100)); // 1/5 due to EIP-3529
}

test "EIP overrides - gas cost implications" {
    // Test that overrides properly affect gas calculations
    const istanbul_with_berlin_gas = Eips{
        .hardfork = Hardfork.ISTANBUL,
        .overrides = &[_]EipOverride{
            .{ .eip = 2929, .enabled = true }, // Enable Berlin gas changes
        },
    };

    const plain_istanbul = Eips{ .hardfork = Hardfork.ISTANBUL };

    // Istanbul normally has old gas costs
    try std.testing.expectEqual(@as(u64, 200), plain_istanbul.eip_2929_cold_sload_cost());

    // With override, should have Berlin gas costs
    try std.testing.expectEqual(@as(u64, 2100), istanbul_with_berlin_gas.eip_2929_cold_sload_cost());
    try std.testing.expectEqual(@as(u64, 100), istanbul_with_berlin_gas.eip_2929_warm_storage_read_cost());
    try std.testing.expectEqual(@as(u64, 2600), istanbul_with_berlin_gas.eip_2929_cold_account_access_cost());
    try std.testing.expectEqual(@as(u64, 100), istanbul_with_berlin_gas.eip_2929_warm_account_access_cost());
}

test "EIP overrides - no overrides" {
    // Test that empty overrides don't affect behavior
    const cancun_no_overrides = Eips{
        .hardfork = Hardfork.CANCUN,
        .overrides = &.{}, // Empty overrides
    };

    const cancun_default = Eips{ .hardfork = Hardfork.CANCUN };

    // Both should behave identically
    try std.testing.expectEqual(cancun_default.is_eip_active(1559), cancun_no_overrides.is_eip_active(1559));
    try std.testing.expectEqual(cancun_default.is_eip_active(3855), cancun_no_overrides.is_eip_active(3855));
    try std.testing.expectEqual(cancun_default.is_eip_active(4844), cancun_no_overrides.is_eip_active(4844));
    try std.testing.expectEqual(cancun_default.eip_1559_is_enabled(), cancun_no_overrides.eip_1559_is_enabled());
    try std.testing.expectEqual(cancun_default.eip_3855_push0_enabled(), cancun_no_overrides.eip_3855_push0_enabled());
}

test "eip_2028_calldata_gas_cost pre and post Istanbul" {
    const pre_istanbul = Eips{
        .hardfork = .BERLIN,
        .overrides = &.{.{ .eip = 2028, .enabled = false }},
    };
    const istanbul = Eips{ .hardfork = .ISTANBUL };

    try std.testing.expectEqual(@as(u64, 4), pre_istanbul.eip_2028_calldata_gas_cost(true));
    try std.testing.expectEqual(@as(u64, 68), pre_istanbul.eip_2028_calldata_gas_cost(false));
    try std.testing.expectEqual(@as(u64, 16), istanbul.eip_2028_calldata_gas_cost(false));
}

test "eip_2028_calldata_gas_cost_multiplier" {
    const pre_istanbul = Eips{
        .hardfork = .BERLIN,
        .overrides = &.{.{ .eip = 2028, .enabled = false }},
    };

    try std.testing.expectEqual(@as(u64, 17), pre_istanbul.eip_2028_calldata_gas_cost_multiplier());
    try std.testing.expectEqual(@as(u64, 4), (Eips{ .hardfork = .ISTANBUL }).eip_2028_calldata_gas_cost_multiplier());
    try std.testing.expectEqual(@as(u64, 4), (Eips{ .hardfork = .LONDON }).eip_2028_calldata_gas_cost_multiplier());
    try std.testing.expectEqual(@as(u64, 4), (Eips{ .hardfork = .CANCUN }).eip_2028_calldata_gas_cost_multiplier());
}

test "tokens_in_calldata - empty" {
    try std.testing.expectEqual(@as(u64, 0), (Eips{ .hardfork = .ISTANBUL }).tokens_in_calldata(&.{}));
}

test "tokens_in_calldata - all zeros" {
    try std.testing.expectEqual(@as(u64, 10), (Eips{ .hardfork = .ISTANBUL }).tokens_in_calldata(&(@as([10]u8, @splat(0x00)))));
}

test "tokens_in_calldata - all non-zeros" {
    try std.testing.expectEqual(@as(u64, 40), (Eips{ .hardfork = .ISTANBUL }).tokens_in_calldata(&(@as([10]u8, @splat(0xff)))));
}

test "tokens_in_calldata - mixed data" {
    const input = [_]u8{ 0x00, 0xff, 0x00, 0x12, 0x00, 0x00, 0xab, 0xcd, 0x00, 0xef };
    try std.testing.expectEqual(@as(u64, 25), (Eips{ .hardfork = .ISTANBUL }).tokens_in_calldata(&input));
}

test "tokens_in_calldata - pre vs post Istanbul" {
    const pre_istanbul = Eips{
        .hardfork = .BERLIN,
        .overrides = &.{.{ .eip = 2028, .enabled = false }},
    };
    const input = [_]u8{ 0x00, 0x00, 0xff, 0xff, 0xff };

    try std.testing.expectEqual(@as(u64, 53), pre_istanbul.tokens_in_calldata(&input));
    try std.testing.expectEqual(@as(u64, 14), (Eips{ .hardfork = .ISTANBUL }).tokens_in_calldata(&input));
}

test "eip_3860_initcode_word_cost - pre-Shanghai" {
    const london = Eips{ .hardfork = .LONDON };
    for ([_]usize{ 0, 1, 32, 1000 }) |size| {
        try std.testing.expectEqual(@as(u64, 0), london.eip_3860_initcode_word_cost(size));
    }
}

test "eip_3860_initcode_word_cost - post-Shanghai" {
    const shanghai = Eips{ .hardfork = .SHANGHAI };
    const sizes = [_]usize{ 0, 1, 31, 32, 33, 64, 1024 };
    const costs = [_]u64{ 0, 2, 2, 2, 4, 4, 64 };
    for (sizes, costs) |size, cost| {
        try std.testing.expectEqual(cost, shanghai.eip_3860_initcode_word_cost(size));
    }
}

test "intrinsic_gas_cost" {
    const cancun = Eips{ .hardfork = .CANCUN };
    try std.testing.expectEqual(@as(u64, 21000), cancun.intrinsic_gas_cost(false));
    try std.testing.expectEqual(@as(u64, 53000), cancun.intrinsic_gas_cost(true));
}

test "calldata_gas_cost - call with empty data" {
    try std.testing.expectEqual(@as(u64, 0), (Eips{ .hardfork = .ISTANBUL }).calldata_gas_cost(0, false, 0));
}

test "calldata_gas_cost - call with data" {
    try std.testing.expectEqual(@as(u64, 100), (Eips{ .hardfork = .ISTANBUL }).calldata_gas_cost(25, false, 10));
}

test "calldata_gas_cost - create pre-Shanghai" {
    try std.testing.expectEqual(@as(u64, 40), (Eips{ .hardfork = .LONDON }).calldata_gas_cost(10, true, 100));
}

test "calldata_gas_cost - create post-Shanghai" {
    const shanghai = Eips{ .hardfork = .SHANGHAI };
    try std.testing.expectEqual(@as(u64, 40), shanghai.calldata_gas_cost(10, true, 0));
    try std.testing.expectEqual(@as(u64, 42), shanghai.calldata_gas_cost(10, true, 32));
    try std.testing.expectEqual(@as(u64, 44), shanghai.calldata_gas_cost(10, true, 33));
    try std.testing.expectEqual(@as(u64, 44), shanghai.calldata_gas_cost(10, true, 64));
}

test "calldata_gas_cost - hardfork transitions" {
    try std.testing.expectEqual(@as(u64, 100), (Eips{ .hardfork = .LONDON }).calldata_gas_cost(25, true, 1024));
    try std.testing.expectEqual(@as(u64, 164), (Eips{ .hardfork = .SHANGHAI }).calldata_gas_cost(25, true, 1024));
    try std.testing.expectEqual(@as(u64, 164), (Eips{ .hardfork = .CANCUN }).calldata_gas_cost(25, true, 1024));
}

test "floor_gas_cost - pre-Prague" {
    const cancun = Eips{ .hardfork = .CANCUN };
    try std.testing.expectEqual(@as(u64, 0), cancun.floor_gas_cost(0));
    try std.testing.expectEqual(@as(u64, 0), cancun.floor_gas_cost(100));
    try std.testing.expectEqual(@as(u64, 0), cancun.floor_gas_cost(10000));
}

test "floor_gas_cost - Prague" {
    const prague = Eips{ .hardfork = .PRAGUE };
    try std.testing.expectEqual(@as(u64, 21000), prague.floor_gas_cost(0));
    try std.testing.expectEqual(@as(u64, 22000), prague.floor_gas_cost(100));
    try std.testing.expectEqual(@as(u64, 31000), prague.floor_gas_cost(1000));
    try std.testing.expectEqual(@as(u64, 121000), prague.floor_gas_cost(10000));
}

test "integration - full gas calculation flow" {
    const shanghai = Eips{ .hardfork = .SHANGHAI };
    const prague = Eips{ .hardfork = .PRAGUE };
    const input = [_]u8{ 0x00, 0x00, 0xff, 0xff, 0xff, 0x00, 0xab, 0xcd };
    const tokens = shanghai.tokens_in_calldata(&input);

    try std.testing.expectEqual(@as(u64, 23), tokens);
    try std.testing.expectEqual(@as(u64, 53000), shanghai.intrinsic_gas_cost(true));
    try std.testing.expectEqual(@as(u64, 100), shanghai.calldata_gas_cost(tokens, true, 100));
    try std.testing.expectEqual(@as(u64, 0), shanghai.floor_gas_cost(tokens));
    try std.testing.expectEqual(@as(u64, 21230), prague.floor_gas_cost(tokens));
}

test "edge cases - word boundaries" {
    const shanghai = Eips{ .hardfork = .SHANGHAI };
    const sizes = [_]usize{ 0, 1, 31, 32, 33, 63, 64, 65, 95, 96, 97 };
    const costs = [_]u64{ 0, 2, 2, 2, 4, 4, 4, 6, 6, 6, 8 };
    for (sizes, costs) |size, cost| {
        try std.testing.expectEqual(cost, shanghai.eip_3860_initcode_word_cost(size));
    }
}

test "edge cases - large calldata" {
    var input: [10000]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = if (i % 2 == 0) 0 else 0xff;

    const prague = Eips{ .hardfork = .PRAGUE };
    const tokens = prague.tokens_in_calldata(&input);
    try std.testing.expectEqual(@as(u64, 25000), tokens);
    try std.testing.expectEqual(@as(u64, 271000), prague.floor_gas_cost(tokens));
}

test "regression - hardfork ordering" {
    const cases = [_]struct { hardfork: Hardfork, eip_2028: bool, eip_3860: bool, eip_7623: bool }{
        .{ .hardfork = .FRONTIER, .eip_2028 = false, .eip_3860 = false, .eip_7623 = false },
        .{ .hardfork = .ISTANBUL, .eip_2028 = true, .eip_3860 = false, .eip_7623 = false },
        .{ .hardfork = .SHANGHAI, .eip_2028 = true, .eip_3860 = true, .eip_7623 = false },
        .{ .hardfork = .CANCUN, .eip_2028 = true, .eip_3860 = true, .eip_7623 = false },
        .{ .hardfork = .PRAGUE, .eip_2028 = true, .eip_3860 = true, .eip_7623 = true },
        .{ .hardfork = .OSAKA, .eip_2028 = true, .eip_3860 = true, .eip_7623 = true },
    };
    for (cases) |case| {
        const active = Eips{ .hardfork = case.hardfork };
        try std.testing.expectEqual(case.eip_2028, active.is_eip_active(2028));
        try std.testing.expectEqual(case.eip_3860, active.is_eip_active(3860));
        try std.testing.expectEqual(case.eip_7623, active.is_eip_active(7623));
    }
}

test "effective_gas_price - pre-EIP-1559" {
    const result = (Eips{ .hardfork = .BERLIN }).effective_gas_price(0, 20_000_000_000, 0);
    try std.testing.expectEqual(@as(u256, 20_000_000_000), result.effective_gas_price);
    try std.testing.expectEqual(@as(u256, 20_000_000_000), result.miner_fee);
}

test "effective_gas_price - EIP-1559 normal case" {
    const result = (Eips{ .hardfork = .LONDON }).effective_gas_price(1_000_000_000, 3_000_000_000, 500_000_000);
    try std.testing.expectEqual(@as(u256, 1_500_000_000), result.effective_gas_price);
    try std.testing.expectEqual(@as(u256, 500_000_000), result.miner_fee);
}

test "effective_gas_price - EIP-1559 capped priority fee" {
    const result = (Eips{ .hardfork = .LONDON }).effective_gas_price(1_000_000_000, 1_200_000_000, 500_000_000);
    try std.testing.expectEqual(@as(u256, 1_200_000_000), result.effective_gas_price);
    try std.testing.expectEqual(@as(u256, 200_000_000), result.miner_fee);
}

test "effective_gas_price - EIP-1559 max fee below base fee" {
    const result = (Eips{ .hardfork = .LONDON }).effective_gas_price(1_000_000_000, 800_000_000, 500_000_000);
    try std.testing.expectEqual(@as(u256, 800_000_000), result.effective_gas_price);
    try std.testing.expectEqual(@as(u256, 0), result.miner_fee);
}

test "effective_gas_price - EIP-1559 zero priority fee" {
    const result = (Eips{ .hardfork = .LONDON }).effective_gas_price(1_000_000_000, 2_000_000_000, 0);
    try std.testing.expectEqual(@as(u256, 1_000_000_000), result.effective_gas_price);
    try std.testing.expectEqual(@as(u256, 0), result.miner_fee);
}

test "effective_gas_price - hardfork progression" {
    const hardforks = [_]struct { hardfork: Hardfork, eip_1559: bool }{
        .{ .hardfork = .FRONTIER, .eip_1559 = false },
        .{ .hardfork = .HOMESTEAD, .eip_1559 = false },
        .{ .hardfork = .BERLIN, .eip_1559 = false },
        .{ .hardfork = .LONDON, .eip_1559 = true },
        .{ .hardfork = .SHANGHAI, .eip_1559 = true },
        .{ .hardfork = .CANCUN, .eip_1559 = true },
        .{ .hardfork = .PRAGUE, .eip_1559 = true },
    };
    for (hardforks) |hardfork| {
        const result = (Eips{ .hardfork = hardfork.hardfork }).effective_gas_price(1_000_000_000, 2_000_000_000, 500_000_000);
        const expected_price: u256 = if (hardfork.eip_1559) 1_500_000_000 else 2_000_000_000;
        const expected_miner_fee: u256 = if (hardfork.eip_1559) 500_000_000 else 2_000_000_000;
        try std.testing.expectEqual(expected_price, result.effective_gas_price);
        try std.testing.expectEqual(expected_miner_fee, result.miner_fee);
    }
}

test "PRAGUE active EIPs drop 3074 and include the Pectra set" {
    const prague = Eips{ .hardfork = .PRAGUE };
    try std.testing.expect(!prague.is_eip_active(3074));
    for ([_]u16{ 2537, 2935, 6110, 7002, 7251, 7623, 7685, 7691, 7702 }) |eip| {
        try std.testing.expect(prague.is_eip_active(eip));
    }
    for ([_]u16{ 7594, 7823, 7825, 7883, 7892, 7918, 7934, 7939, 7951 }) |eip| {
        try std.testing.expect(!prague.is_eip_active(eip));
    }
}

test "OSAKA and AMSTERDAM active EIPs include the Fusaka set and every Prague EIP" {
    for ([_]Hardfork{ .OSAKA, .AMSTERDAM }) |fork| {
        const eips = Eips{ .hardfork = fork };
        try std.testing.expect(!eips.is_eip_active(3074));
        for ([_]u16{ 7594, 7823, 7825, 7883, 7892, 7918, 7934, 7939, 7951 }) |eip| {
            try std.testing.expect(eips.is_eip_active(eip));
        }
        for ((Eips{ .hardfork = .PRAGUE }).get_active_eips()) |eip| {
            try std.testing.expect(eips.is_eip_active(eip));
        }
    }
}

test "Cancun through Amsterdam keep every EIP of the previous fork" {
    const forks = [_]Hardfork{ .CANCUN, .PRAGUE, .OSAKA, .AMSTERDAM };
    for (forks[1..], forks[0 .. forks.len - 1]) |fork, previous| {
        for ((Eips{ .hardfork = previous }).get_active_eips()) |eip| {
            try std.testing.expect((Eips{ .hardfork = fork }).is_eip_active(eip));
        }
    }
}

test "EIP-7825 transaction gas limit cap" {
    try std.testing.expectEqual(@as(u64, 1 << 24), TX_GAS_LIMIT_CAP);
    try validateTransactionGasLimit(.OSAKA, TX_GAS_LIMIT_CAP);
    try std.testing.expectError(error.GasLimitExceedsCap, validateTransactionGasLimit(.OSAKA, TX_GAS_LIMIT_CAP + 1));
    try std.testing.expectError(error.GasLimitExceedsCap, validateTransactionGasLimit(.AMSTERDAM, std.math.maxInt(u64)));
    try validateTransactionGasLimit(.PRAGUE, TX_GAS_LIMIT_CAP + 1);
    try validateTransactionGasLimit(.CANCUN, std.math.maxInt(u64));

    const disabled = Eips{ .hardfork = .OSAKA, .overrides = &.{.{ .eip = 7825, .enabled = false }} };
    try disabled.validate_transaction_gas_limit(TX_GAS_LIMIT_CAP + 1);
}

test "EIP-7934 RLP block size limit" {
    try std.testing.expectEqual(@as(usize, 8_388_608), MAX_RLP_BLOCK_SIZE);
    try std.testing.expectEqual(MAX_BLOCK_SIZE - SAFETY_MARGIN, MAX_RLP_BLOCK_SIZE);
    try validateRlpBlockSize(.OSAKA, MAX_RLP_BLOCK_SIZE);
    try std.testing.expectError(error.RlpBlockSizeExceedsLimit, validateRlpBlockSize(.OSAKA, MAX_RLP_BLOCK_SIZE + 1));
    try validateRlpBlockSize(.PRAGUE, MAX_RLP_BLOCK_SIZE + 1);
}

test "EIP-7892 blob schedule values and lookups" {
    const cases = [_]struct { fork: BlobScheduleFork, target: u64, max: u64, fraction: u64 }{
        .{ .fork = .CANCUN, .target = 3, .max = 6, .fraction = 3338477 },
        .{ .fork = .PRAGUE, .target = 6, .max = 9, .fraction = 5007716 },
        .{ .fork = .OSAKA, .target = 6, .max = 9, .fraction = 5007716 },
        .{ .fork = .BPO1, .target = 10, .max = 15, .fraction = 8346193 },
        .{ .fork = .BPO2, .target = 14, .max = 21, .fraction = 11684671 },
    };
    for (cases) |case| {
        const params = case.fork.params();
        try std.testing.expectEqual(case.target, params.target);
        try std.testing.expectEqual(case.max, params.max);
        try std.testing.expectEqual(case.fraction, params.base_fee_update_fraction);
    }

    // The schedule reproduces the EIP-4844 and EIP-7691 per-block constants.
    try std.testing.expectEqual(GAS_PER_BLOB, primitives.Blob.BLOB_GAS_PER_BLOB);
    try std.testing.expectEqual(@as(u64, primitives.Blob.TARGET_BLOB_GAS_PER_BLOCK_CANCUN), (Eips{ .hardfork = .CANCUN }).target_blob_gas());
    try std.testing.expectEqual(@as(u64, primitives.Blob.MAX_BLOB_GAS_PER_BLOCK_CANCUN), (Eips{ .hardfork = .CANCUN }).max_blob_gas());
    try std.testing.expectEqual(@as(u64, primitives.Blob.TARGET_BLOB_GAS_PER_BLOCK_PRAGUE), (Eips{ .hardfork = .PRAGUE }).target_blob_gas());
    try std.testing.expectEqual(@as(u64, primitives.Blob.MAX_BLOB_GAS_PER_BLOCK_PRAGUE), (Eips{ .hardfork = .PRAGUE }).max_blob_gas());
    try std.testing.expectEqual(@as(u64, primitives.Blob.BLOB_BASE_FEE_UPDATE_FRACTION_PRAGUE), (Eips{ .hardfork = .OSAKA }).blob_base_fee_update_fraction());

    try std.testing.expectEqual(BlobScheduleParams.CANCUN, BlobScheduleParams.forHardfork(.CANCUN));
    try std.testing.expectEqual(BlobScheduleParams.PRAGUE, BlobScheduleParams.forHardfork(.PRAGUE));
    try std.testing.expectEqual(BlobScheduleParams.OSAKA, BlobScheduleParams.forHardfork(.OSAKA));
    try std.testing.expectEqual(BlobScheduleParams.BPO2, BlobScheduleParams.forHardfork(.AMSTERDAM));
    try std.testing.expectEqual(@as(?BlobScheduleParams, null), (Eips{ .hardfork = .SHANGHAI }).blob_schedule());

    // BPO selection through the Eips override.
    const bpo1 = Eips{ .hardfork = .OSAKA, .blob_schedule_override = BlobScheduleFork.BPO1.params() };
    try std.testing.expectEqual(@as(u64, 10 * GAS_PER_BLOB), bpo1.target_blob_gas());
    try std.testing.expectEqual(@as(u64, 15 * GAS_PER_BLOB), bpo1.max_blob_gas());
    try std.testing.expectEqual(@as(u64, 8346193), bpo1.blob_base_fee_update_fraction());
    const bpo2 = Eips{ .hardfork = .OSAKA, .blob_schedule_override = BlobScheduleParams.BPO2 };
    try std.testing.expectEqual(@as(u64, 21 * GAS_PER_BLOB), bpo2.max_blob_gas());

    // Mainnet selection by timestamp, at each activation boundary.
    try std.testing.expectEqual(@as(?BlobScheduleFork, null), BlobScheduleFork.mainnetAt(1710338134));
    try std.testing.expectEqual(@as(?BlobScheduleFork, .CANCUN), BlobScheduleFork.mainnetAt(1710338135));
    try std.testing.expectEqual(@as(?BlobScheduleFork, .CANCUN), BlobScheduleFork.mainnetAt(1746612310));
    try std.testing.expectEqual(@as(?BlobScheduleFork, .PRAGUE), BlobScheduleFork.mainnetAt(1746612311));
    try std.testing.expectEqual(@as(?BlobScheduleFork, .OSAKA), BlobScheduleFork.mainnetAt(1764798551));
    try std.testing.expectEqual(@as(?BlobScheduleFork, .OSAKA), BlobScheduleFork.mainnetAt(1765290070));
    try std.testing.expectEqual(@as(?BlobScheduleFork, .BPO1), BlobScheduleFork.mainnetAt(1765290071));
    try std.testing.expectEqual(@as(?BlobScheduleFork, .BPO1), BlobScheduleFork.mainnetAt(1767747670));
    try std.testing.expectEqual(@as(?BlobScheduleFork, .BPO2), BlobScheduleFork.mainnetAt(1767747671));
    try std.testing.expectEqual(@as(?BlobScheduleFork, .BPO2), BlobScheduleFork.mainnetAt(std.math.maxInt(u64)));
    // Blob schedule timestamps agree with the hardfork activation table.
    try std.testing.expectEqual(Hardfork.PRAGUE.mainnetActivationTimestamp().?, BlobScheduleFork.PRAGUE.mainnetActivationTimestamp());
    try std.testing.expectEqual(Hardfork.OSAKA.mainnetActivationTimestamp().?, BlobScheduleFork.OSAKA.mainnetActivationTimestamp());
    try std.testing.expectEqual(Hardfork.CANCUN.mainnetActivationTimestamp().?, BlobScheduleFork.CANCUN.mainnetActivationTimestamp());
}

test "EIP-7918 excess blob gas uses the reserve-price branch when execution cost dominates" {
    try std.testing.expectEqual(@as(u64, 8192), BLOB_BASE_COST);
    const osaka = Eips{ .hardfork = .OSAKA };
    const target = osaka.target_blob_gas();
    const max = osaka.max_blob_gas();
    // Parent blob fee is 1 wei (excess 0 + target); execution base fee 1 gwei.
    // 8192 * 1e9 > 131072 * 1, so excess grows by used * (9 - 6) / 9.
    const parent_excess: u64 = 0;
    const used = max;
    const expected = parent_excess + used * (9 - 6) / 9;
    try std.testing.expectEqual(expected, osaka.excess_blob_gas(parent_excess, used, 1_000_000_000));
    // The normal rule would have given used - target; the reserve price differs.
    try std.testing.expect(expected != used - target);

    // Below target still returns zero, even with a high execution base fee.
    try std.testing.expectEqual(@as(u64, 0), osaka.excess_blob_gas(0, target - 1, 1_000_000_000));

    // Boundary: execution cost equal to blob cost is not "greater", so the normal rule applies.
    // Parent blob fee at excess 0 is 1, so blob cost is 131072 = 8192 * 16.
    try std.testing.expectEqual(used - target, osaka.excess_blob_gas(0, used, 16));
    try std.testing.expectEqual(expected, osaka.excess_blob_gas(0, used, 17));

    // BPO2 schedule: growth uses (21 - 14) / 21.
    const bpo2 = Eips{ .hardfork = .OSAKA, .blob_schedule_override = BlobScheduleParams.BPO2 };
    const bpo2_used = bpo2.max_blob_gas();
    try std.testing.expectEqual(bpo2_used * 7 / 21, bpo2.excess_blob_gas(0, bpo2_used, 1_000_000_000));
}

test "EIP-7918 excess blob gas uses the normal rule when blob fee dominates" {
    const osaka = Eips{ .hardfork = .OSAKA };
    const target = osaka.target_blob_gas();
    const max = osaka.max_blob_gas();
    // Excess 104_000_000 gives a parent blob fee of 1_045_698_476 wei; blob cost
    // 131072 * 1_045_698_476 exceeds 8192 * 1 gwei, so excess follows target.
    const parent_excess: u64 = 104_000_000;
    try std.testing.expectEqual(parent_excess + max - target, osaka.excess_blob_gas(parent_excess, max, 1_000_000_000));
    try std.testing.expectEqual(parent_excess - target, osaka.excess_blob_gas(parent_excess, 0, 1_000_000_000));

    // Prague ignores the reserve price even when execution cost dominates.
    const prague = Eips{ .hardfork = .PRAGUE };
    try std.testing.expectEqual(max - target, prague.excess_blob_gas(0, max, 1_000_000_000));
    // Saturates instead of overflowing the u64 header field.
    try std.testing.expectEqual(std.math.maxInt(u64), prague.excess_blob_gas(std.math.maxInt(u64), max, 0));
}

test "EIP-7685 requests hash and encoding" {
    const allocator = std.testing.allocator;
    const Sha256 = std.crypto.hash.sha2.Sha256;

    var empty_digest: [32]u8 = undefined;
    Sha256.hash("", &empty_digest, .{});
    try std.testing.expectEqualSlices(u8, &empty_digest, &EMPTY_REQUESTS_HASH);
    try std.testing.expectEqualSlices(u8, &EMPTY_REQUESTS_HASH, &(try computeRequestsHash(&.{})));

    // Requests holding only a type byte are skipped.
    const type_only = [_][]const u8{ &.{0x00}, &.{0x01}, &.{0x02} };
    try std.testing.expectEqualSlices(u8, &EMPTY_REQUESTS_HASH, &(try computeRequestsHash(&type_only)));

    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(RequestType.deposit));
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(RequestType.withdrawal));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(RequestType.consolidation));

    const deposit = try encodeRequest(allocator, .deposit, &.{ 0xaa, 0xbb });
    defer allocator.free(deposit);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0xaa, 0xbb }, deposit);
    const consolidation = try encodeRequest(allocator, .consolidation, &.{0xcc});
    defer allocator.free(consolidation);
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0xcc }, consolidation);

    // sha256(sha256(0x00aabb) ++ sha256(0x02cc)), with the empty withdrawal skipped.
    var deposit_digest: [32]u8 = undefined;
    Sha256.hash(deposit, &deposit_digest, .{});
    var consolidation_digest: [32]u8 = undefined;
    Sha256.hash(consolidation, &consolidation_digest, .{});
    var expected: [32]u8 = undefined;
    Sha256.hash(&(deposit_digest ++ consolidation_digest), &expected, .{});
    const requests = [_][]const u8{ deposit, &.{0x01}, consolidation };
    try std.testing.expectEqualSlices(u8, &expected, &(try computeRequestsHash(&requests)));

    try std.testing.expectError(error.MissingRequestType, computeRequestsHash(&.{&.{}}));
    try std.testing.expectError(error.RequestTypesNotAscending, computeRequestsHash(&.{ consolidation, deposit }));
}

test "Prague request predeploy and deposit contract addresses" {
    const cases = [_]struct { actual: primitives.Address.Address, hex: []const u8 }{
        .{ .actual = DEPOSIT_CONTRACT_ADDRESS, .hex = "0x00000000219ab540356cBB839Cbe05303d7705Fa" },
        .{ .actual = WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, .hex = "0x00000961Ef480Eb55e80D19ad83579A64c007002" },
        .{ .actual = CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS, .hex = "0x0000BBdDc7CE488642fb579F8B00f3a590007251" },
    };
    for (cases) |case| {
        const expected = try primitives.Address.fromHex(case.hex);
        try std.testing.expectEqualSlices(u8, &expected.bytes, &case.actual.bytes);
    }
}
