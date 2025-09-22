/// Minimal EVM implementation for tracing and validation
/// This is a simplified, unoptimized EVM that orchestrates execution.
/// Architecture mirrors evm.zig - MinimalEvm orchestrates, MinimalFrame executes
const std = @import("std");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
const MinimalFrame = @import("minimal_frame.zig").MinimalFrame;
const Hardfork = @import("../eips_and_hardforks/eips.zig").Hardfork;
const minimal_host = @import("minimal_host.zig");
const precompiles = @import("../precompiles/precompiles.zig");

const Address = primitives.Address.Address;

// Re-export host types for compatibility
pub const HostInterface = minimal_host.HostInterface;
pub const CallResult = minimal_host.CallResult;
pub const Host = minimal_host.Host;

/// Storage slot key for tracking
pub const StorageSlotKey = struct {
    address: Address,
    slot: u256,

    pub fn hash(key: StorageSlotKey) u32 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(&key.address.bytes);
        hasher.update(std.mem.asBytes(&key.slot));
        return @truncate(hasher.final());
    }

    pub fn eql(a: StorageSlotKey, b: StorageSlotKey) bool {
        return a.address.equals(b.address) and a.slot == b.slot;
    }
};

const PRECOMPILE_ADDRESSES = [_]Address{
    precompiles.ECRECOVER_ADDRESS,
    precompiles.SHA256_ADDRESS,
    precompiles.RIPEMD160_ADDRESS,
    precompiles.IDENTITY_ADDRESS,
    precompiles.MODEXP_ADDRESS,
    precompiles.ECADD_ADDRESS,
    precompiles.ECMUL_ADDRESS,
    precompiles.ECPAIRING_ADDRESS,
    precompiles.BLAKE2F_ADDRESS,
    precompiles.POINT_EVALUATION_ADDRESS,
    precompiles.BLS12_381_G1_ADD_ADDRESS,
    precompiles.BLS12_381_G1_MSM_ADDRESS,
    precompiles.BLS12_381_G2_ADD_ADDRESS,
    precompiles.BLS12_381_G2_MSM_ADDRESS,
    precompiles.BLS12_381_PAIRING_ADDRESS,
    precompiles.BLS12_381_MAP_FP_TO_G1_ADDRESS,
    precompiles.BLS12_381_MAP_FP2_TO_G2_ADDRESS,
};

/// Get ECRECOVER gas cost (fixed across all hardforks)
fn getEcrecoverGasCost() u64 {
    return GasConstants.ECRECOVER_COST;
}

/// Get SHA256 gas cost based on input length
fn getSha256GasCost(input_len: usize) u64 {
    const word_count = (input_len + 31) / 32;
    return GasConstants.SHA256_BASE_COST + word_count * GasConstants.SHA256_WORD_COST;
}

/// Get RIPEMD160 gas cost based on input length
fn getRipemd160GasCost(input_len: usize) u64 {
    const word_count = (input_len + 31) / 32;
    return GasConstants.RIPEMD160_BASE_COST + word_count * GasConstants.RIPEMD160_WORD_COST;
}

/// Get IDENTITY gas cost based on input length
fn getIdentityGasCost(input_len: usize) u64 {
    const word_count = (input_len + 31) / 32;
    return GasConstants.IDENTITY_BASE_COST + word_count * GasConstants.IDENTITY_WORD_COST;
}

/// Right pad input with zeros to get a 32-byte slice starting at offset
fn rightPadWithOffset(input: []const u8, offset: usize) [32]u8 {
    var result = [_]u8{0} ** 32;
    if (offset >= input.len) return result;
    
    const bytes_to_copy = @min(32, input.len - offset);
    @memcpy(result[0..bytes_to_copy], input[offset..offset + bytes_to_copy]);
    return result;
}

/// Left pad bytes with zeros to make 32 bytes
fn leftPad(bytes: []const u8) [32]u8 {
    var result = [_]u8{0} ** 32;
    const len = @min(bytes.len, 32);
    const start_pos = 32 - len;
    @memcpy(result[start_pos..start_pos + len], bytes[0..len]);
    return result;
}

/// Extract a u64 value from input at given offset (reads 32 bytes as big-endian u256, then converts to u64)
fn extractU64FromInput(input: []const u8, offset: usize) u64 {
    const padded = rightPadWithOffset(input, offset);
    // Read 32 bytes as big-endian u256
    const value = std.mem.readInt(u256, &padded, .big);
    // Saturate to u64 max if value exceeds it
    return @min(value, std.math.maxInt(u64));
}

/// Extract the high part of the exponent for iteration count calculation (matches REVM logic)
fn extractExpHighp(input: []const u8, base_len: u64, exp_len: u64) u256 {
    // Header is 96 bytes (3 x 32-byte length fields)
    const header_length = 96;
    
    // Get how many bytes we need from the exponent (max 32)
    const exp_highp_len: usize = @intCast(@min(exp_len, 32));
    
    // Skip the header
    const input_after_header = if (input.len > header_length) 
        input[header_length..] 
    else 
        &[_]u8{};
    
    // Get right-padded bytes from the exponent position
    // This handles the case where input is shorter than expected
    const right_padded_highp = rightPadWithOffset(input_after_header, @intCast(base_len));
    
    // If exp_len is less than 32 bytes, get only exp_len bytes and left-pad
    const exp_bytes = right_padded_highp[0..exp_highp_len];
    const left_padded = leftPad(exp_bytes);
    
    // Convert to u256 from big-endian bytes
    var result: u256 = 0;
    for (left_padded) |byte| {
        result = (result << 8) | byte;
    }
    
    return result;
}

/// Count the number of bits in a u256 value
fn bitLen256(value: u256) u64 {
    if (value == 0) return 0;
    // For u256, we need to count leading zeros and subtract from 256
    return 256 - @clz(value);
}

/// Calculate iteration count for MODEXP (same for all hardforks)
fn calculateIterationCount(exp_len: u64, exp_highp: u256, multiplier: u64) u64 {
    var iteration_count: u64 = 0;
    
    if (exp_len <= 32 and exp_highp == 0) {
        iteration_count = 0;
    } else if (exp_len <= 32) {
        const bit_length = bitLen256(exp_highp);
        iteration_count = if (bit_length > 0) bit_length - 1 else 0;
    } else {
        // exp_len > 32
        const bit_length = bitLen256(exp_highp);
        const adjusted_bit_len = @max(1, bit_length);
        iteration_count = multiplier *% (exp_len - 32) +% (adjusted_bit_len - 1);
    }
    
    return @max(iteration_count, 1);
}

/// Calculate multiplication complexity for Byzantium
fn byzantiumMultiplicationComplexity(max_len: u64) u64 {
    if (max_len <= 64) {
        return max_len *% max_len;
    } else if (max_len <= 1024) {
        return (max_len *% max_len / 4) +% (96 *% max_len) -% 3072;
    } else {
        // Use 128-bit arithmetic to prevent overflow
        const x = @as(u128, max_len);
        const x_sq = x * x;
        const result = (x_sq / 16) + (480 * x) - 199680;
        return @intCast(@min(result, std.math.maxInt(u64)));
    }
}

/// Calculate multiplication complexity for Berlin
fn berlinMultiplicationComplexity(max_len: u64) u64 {
    const words = (max_len + 7) / 8; // div_ceil
    return words *% words;
}

/// Calculate multiplication complexity for Osaka (EIP-7883)
fn osakaMultiplicationComplexity(max_len: u64) u64 {
    if (max_len <= 32) {
        return 16; // Fixed cost for small inputs
    }
    const words = (max_len + 7) / 8; // div_ceil
    return 2 *% words *% words; // 2x multiplier for larger inputs
}

/// Get MODEXP gas cost based on hardfork and input
fn getModexpGasCost(hardfork: Hardfork, input: []const u8) u64 {
    // Extract base_len, exp_len, mod_len from first 96 bytes (as u256 then convert to u64)
    const base_len = extractU64FromInput(input, 0);
    const exp_len = extractU64FromInput(input, 32);
    const mod_len = extractU64FromInput(input, 64);
    
    // Special case: both base and mod length being 0
    if (base_len == 0 and mod_len == 0) {
        // Return minimum gas for the hardfork
        if (hardfork.isAtLeast(.BERLIN)) {
            return GasConstants.MODEXP_MIN_GAS; // 200
        }
        return 0; // Byzantium has no minimum
    }
    
    // TODO: When we add the Osaka hardfork, enforce size limits:
    // if (hardfork.isAtLeast(.OSAKA)) {
    //     const INPUT_SIZE_LIMIT = 1024; // EIP-7823
    //     if (base_len > INPUT_SIZE_LIMIT or exp_len > INPUT_SIZE_LIMIT or mod_len > INPUT_SIZE_LIMIT) {
    //         // In real EVM this would be an error, for now return max gas
    //         return std.math.maxInt(u64);
    //     }
    // }
    
    // Extract high part of exponent for iteration count (as u256)
    const exp_highp = extractExpHighp(input, base_len, exp_len);
    
    // Calculate gas based on hardfork
    const max_len = @max(base_len, mod_len);
    
    // TODO: When we add the Osaka hardfork, uncomment:
    // if (hardfork.isAtLeast(.OSAKA)) {
    //     // Osaka (EIP-7883): MIN_PRICE=500, MULTIPLIER=16, GAS_DIVISOR=3
    //     const multiplication_complexity = osakaMultiplicationComplexity(max_len);
    //     const iteration_count = calculateIterationCount(exp_len, exp_highp, 16);
    //     const gas = (multiplication_complexity *% iteration_count) / 3;
    //     return @max(500, gas);
    // }
    
    if (hardfork.isAtLeast(.BERLIN)) {
        // Berlin (EIP-2565): MIN_PRICE=200, MULTIPLIER=8, GAS_DIVISOR=3
        const multiplication_complexity = berlinMultiplicationComplexity(max_len);
        const iteration_count = calculateIterationCount(exp_len, exp_highp, 8);
        const gas = (multiplication_complexity *% iteration_count) / 3;
        return @max(GasConstants.MODEXP_MIN_GAS, gas);
    } else {
        // Byzantium (EIP-198): MIN_PRICE=0, MULTIPLIER=8, GAS_DIVISOR=20
        const multiplication_complexity = byzantiumMultiplicationComplexity(max_len);
        const iteration_count = calculateIterationCount(exp_len, exp_highp, 8);
        const gas = (multiplication_complexity *% iteration_count) / 20;
        return gas; // No minimum for Byzantium
    }
}

/// Get BLAKE2F gas cost based on rounds
fn getBlake2fGasCost(input: []const u8) u64 {
    if (input.len < 4) return 0;
    // First 4 bytes are the number of rounds (big-endian)
    const rounds = (@as(u32, input[0]) << 24) |
                   (@as(u32, input[1]) << 16) |
                   (@as(u32, input[2]) << 8) |
                   @as(u32, input[3]);
    return rounds * GasConstants.BLAKE2F_PER_ROUND;
}

/// Get KZG point evaluation gas cost (fixed)
fn getPointEvaluationGasCost() u64 {
    return GasConstants.POINT_EVALUATION_COST;
}

/// Get BLS12-381 G1 ADD gas cost (fixed)
fn getBls12381G1AddGasCost() u64 {
    return GasConstants.BLS12_381_G1_ADD;
}

/// Get BLS12-381 G1 MSM (Multi-Scalar Multiplication) gas cost
/// Note: G1_MUL uses MSM with k=1 (single scalar multiplication)
/// IMPORTANT: The precompile execution MUST validate that input_len % 160 == 0
/// and perform point/scalar validation before consuming gas
fn getBls12381G1MsmGasCost(input_len: usize) u64 {
    // Each pair is 160 bytes (128 bytes G1 point + 32 bytes scalar)
    // For invalid input lengths, we still calculate gas based on truncated pairs
    // The precompile will fail with this gas consumed if input is invalid
    const num_pairs = input_len / 160;
    
    // Empty input (k=0) returns 0 gas per REVM formula
    if (num_pairs == 0) {
        return 0;
    }
    
    // Apply discount table for MSM operations
    const discount_index = @min(num_pairs - 1, GasConstants.BLS12_381_G1_MSM_DISCOUNT.len - 1);
    const discount = GasConstants.BLS12_381_G1_MSM_DISCOUNT[discount_index];
    
    // Formula: (k * BASE_GAS * DISCOUNT[k]) / MSM_MULTIPLIER
    return (@as(u64, num_pairs) * GasConstants.BLS12_381_G1_MSM * discount) / GasConstants.MSM_MULTIPLIER;
}

/// Get BLS12-381 G2 ADD gas cost (fixed)
fn getBls12381G2AddGasCost() u64 {
    return GasConstants.BLS12_381_G2_ADD;
}

/// Get BLS12-381 G2 MSM (Multi-Scalar Multiplication) gas cost
/// Note: G2_MUL uses MSM with k=1 (single scalar multiplication)
/// IMPORTANT: The precompile execution MUST validate that input_len % 288 == 0
/// and perform point/scalar validation before consuming gas
fn getBls12381G2MsmGasCost(input_len: usize) u64 {
    // Each pair is 288 bytes (256 bytes G2 point + 32 bytes scalar)
    // For invalid input lengths, we still calculate gas based on truncated pairs
    // The precompile will fail with this gas consumed if input is invalid
    const num_pairs = input_len / 288;
    
    // Empty input (k=0) returns 0 gas per REVM formula
    if (num_pairs == 0) {
        return 0;
    }
    
    // Apply discount table for MSM operations
    const discount_index = @min(num_pairs - 1, GasConstants.BLS12_381_G2_MSM_DISCOUNT.len - 1);
    const discount = GasConstants.BLS12_381_G2_MSM_DISCOUNT[discount_index];
    
    // Formula: (k * BASE_GAS * DISCOUNT[k]) / MSM_MULTIPLIER
    return (@as(u64, num_pairs) * GasConstants.BLS12_381_G2_MSM * discount) / GasConstants.MSM_MULTIPLIER;
}

/// Get BLS12-381 PAIRING gas cost based on number of pairs
/// IMPORTANT: The precompile execution MUST validate that input_len % 384 == 0
/// and perform G1/G2 point validation before consuming gas
fn getBls12381PairingGasCost(input_len: usize) u64 {
    // Each pair is 384 bytes (128 bytes G1 + 256 bytes G2)
    // For invalid input lengths, we still calculate gas based on truncated pairs
    // The precompile will fail with this gas consumed if input is invalid
    const num_pairs = input_len / 384;
    
    // Pairing always has base cost even for zero pairs (empty pairing returns 1)
    return GasConstants.BLS12_381_PAIRING_BASE + @as(u64, num_pairs) * GasConstants.BLS12_381_PAIRING_PER_PAIR;
}

/// Get BLS12-381 MAP_FP_TO_G1 gas cost (fixed)
fn getBls12381MapFpToG1GasCost() u64 {
    return GasConstants.BLS12_381_MAP_FP_TO_G1;
}

/// Get BLS12-381 MAP_FP2_TO_G2 gas cost (fixed)
fn getBls12381MapFp2ToG2GasCost() u64 {
    return GasConstants.BLS12_381_MAP_FP2_TO_G2;
}

/// Get ECADD gas cost based on hardfork
fn getEcaddGasCost(hardfork: Hardfork) u64 {
    if (hardfork.isAtLeast(.ISTANBUL)) {
        @branchHint(.likely);
        return GasConstants.ECADD_GAS_COST; // 150 gas
    }
    return GasConstants.ECADD_GAS_COST_BYZANTIUM; // 500 gas
}

/// Get ECMUL gas cost based on hardfork
fn getEcmulGasCost(hardfork: Hardfork) u64 {
    if (hardfork.isAtLeast(.ISTANBUL)) {
        @branchHint(.likely);
        return GasConstants.ECMUL_GAS_COST; // 6,000 gas
    }
    return GasConstants.ECMUL_GAS_COST_BYZANTIUM; // 40,000 gas
}

/// Get ECPAIRING gas cost based on hardfork and input length
fn getEcpairingGasCost(hardfork: Hardfork, input_len: usize) u64 {
    // Each pair is 192 bytes (64 bytes G1 + 128 bytes G2)
    const pair_count = input_len / 192;
    
    if (hardfork.isAtLeast(.ISTANBUL)) {
        @branchHint(.likely);
        return GasConstants.ECPAIRING_BASE_GAS_COST + 
               @as(u64, pair_count) * GasConstants.ECPAIRING_PER_PAIR_GAS_COST;
    }
    return GasConstants.ECPAIRING_BASE_GAS_COST_BYZANTIUM + 
           @as(u64, pair_count) * GasConstants.ECPAIRING_PER_PAIR_GAS_COST_BYZANTIUM;
}

// Context for Address ArrayHashMap
const AddressContext = std.array_hash_map.AutoContext(Address);

// Context for hashing/equality of StorageSlotKey for ArrayHashMap
const StorageSlotKeyContext = struct {
    pub fn hash(self: @This(), key: StorageSlotKey) u32 {
        _ = self;
        return StorageSlotKey.hash(key);
    }

    pub fn eql(self: @This(), a: StorageSlotKey, b: StorageSlotKey, b_index: usize) bool {
        _ = self;
        _ = b_index;
        return StorageSlotKey.eql(a, b);
    }
};

/// Minimal EVM - Orchestrates execution like evm.zig
pub const MinimalEvm = struct {
    /// Error set for MinimalEvm operations
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
        AllocationError,
        AccountNotFound,
        InvalidJumpDestination,
        MissingJumpDestMetadata,
        InitcodeTooLarge, // this one is never used anywhere
        TruncatedPush,
        OutOfBounds,
        WriteProtection,
        BytecodeTooLarge, // we use CreateInitCodeSizeLimit instead for conventions
        InvalidPush,
        // EIP-3860: Init code exceeds size limit
        CreateInitCodeSizeLimit,
        // EIP-170: Deployed contract code exceeds size limit
        CreateContractSizeLimit,
    };

    const Self = @This();

    frames: std.ArrayList(*MinimalFrame),
    storage: std.AutoHashMap(StorageSlotKey, u256),
    original_storage: std.AutoHashMap(StorageSlotKey, u256),
    balances: std.AutoHashMap(Address, u256),
    code: std.AutoHashMap(Address, []const u8),
    // EIP-2929 warm/cold tracking (minimal)
    warm_addresses: std.array_hash_map.ArrayHashMap(Address, void, AddressContext, false),
    warm_storage_slots: std.array_hash_map.ArrayHashMap(StorageSlotKey, void, StorageSlotKeyContext, false),

    // Transaction-scoped gas refund counter
    gas_refund: u64,

    // Active hardfork configuration for gas rules
    hardfork: Hardfork,

    // Blockchain context
    chain_id: u64,
    block_number: u64,
    block_timestamp: u64,
    block_difficulty: u256,
    block_prevrandao: u256,
    block_coinbase: Address,
    block_gas_limit: u64,
    block_base_fee: u256,
    blob_base_fee: u256,
    origin: Address,
    gas_price: u256,
    host: ?HostInterface,
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Self {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        const storage_map = std.AutoHashMap(StorageSlotKey, u256).init(arena_allocator);
        const balances_map = std.AutoHashMap(Address, u256).init(arena_allocator);
        const code_map = std.AutoHashMap(Address, []const u8).init(arena_allocator);
        const warm_addresses = std.array_hash_map.ArrayHashMap(Address, void, AddressContext, false).init(arena_allocator);
        const warm_storage_slots = std.array_hash_map.ArrayHashMap(StorageSlotKey, void, StorageSlotKeyContext, false).init(arena_allocator);
        var frames_list = std.ArrayList(*MinimalFrame){};
        try frames_list.ensureTotalCapacity(arena_allocator, 16);

        const original_storage_map = std.AutoHashMap(StorageSlotKey, u256).init(arena_allocator);

        return Self{
            .frames = frames_list,
            .storage = storage_map,
            .original_storage = original_storage_map,
            .balances = balances_map,
            .code = code_map,
            .warm_addresses = warm_addresses,
            .warm_storage_slots = warm_storage_slots,
            .gas_refund = 0,
            .hardfork = Hardfork.DEFAULT,
            .chain_id = 1,
            .block_number = 0,
            .block_timestamp = 0,
            .block_difficulty = 0,
            .block_prevrandao = 0,
            .block_coinbase = primitives.ZERO_ADDRESS,
            .block_gas_limit = 30_000_000,
            .block_base_fee = 0,
            .blob_base_fee = 0,
            .origin = primitives.ZERO_ADDRESS,
            .gas_price = 0,
            .host = null,
            .arena = arena,
            .allocator = arena_allocator,
        };
    }

    /// Initialize as a pointer to avoid arena corruption from struct copies
    /// @deprecated Use init() with proper lifetime management instead
    pub fn initPtr(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();

        const arena_allocator = self.arena.allocator();

        self.frames = std.ArrayList(*MinimalFrame){}; // Unmanaged ArrayList, default init
        self.storage = std.AutoHashMap(StorageSlotKey, u256).init(arena_allocator);
        self.original_storage = std.AutoHashMap(StorageSlotKey, u256).init(arena_allocator);
        self.balances = std.AutoHashMap(Address, u256).init(arena_allocator);
        self.code = std.AutoHashMap(Address, []const u8).init(arena_allocator);
        self.warm_addresses = std.array_hash_map.ArrayHashMap(Address, void, AddressContext, false).init(arena_allocator);
        self.warm_storage_slots = std.array_hash_map.ArrayHashMap(StorageSlotKey, void, StorageSlotKeyContext, false).init(arena_allocator);
        self.gas_refund = 0;
        self.hardfork = Hardfork.DEFAULT;
        self.chain_id = 1;
        self.block_number = 0;
        self.block_timestamp = 0;
        self.block_difficulty = 0;
        self.block_prevrandao = 0;
        self.block_coinbase = primitives.ZERO_ADDRESS;
        self.block_gas_limit = 30_000_000;
        self.block_base_fee = 0;
        self.blob_base_fee = 0;
        self.origin = primitives.ZERO_ADDRESS;
        self.gas_price = 0;
        self.host = null;
        self.allocator = arena_allocator;

        return self;
    }

    /// Initialize with a host interface
    pub fn initWithHost(allocator: std.mem.Allocator, host: HostInterface) !Self {
        var self = try init(allocator);
        self.host = host;
        return self;
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Clean up pointer-allocated MinimalEvm
    pub fn deinitPtr(self: *Self, allocator: std.mem.Allocator) void {
        self.deinit();
        allocator.destroy(self);
    }

    /// Set blockchain context
    pub fn setBlockchainContext(
        self: *Self,
        chain_id: u64,
        block_number: u64,
        block_timestamp: u64,
        block_difficulty: u256,
        block_prevrandao: u256,
        block_coinbase: Address,
        block_gas_limit: u64,
        block_base_fee: u256,
        blob_base_fee: u256,
    ) void {
        self.chain_id = chain_id;
        self.block_number = block_number;
        self.block_timestamp = block_timestamp;
        self.block_difficulty = block_difficulty;
        self.block_prevrandao = block_prevrandao;
        self.block_coinbase = block_coinbase;
        self.block_gas_limit = block_gas_limit;
        self.block_base_fee = block_base_fee;
        self.blob_base_fee = blob_base_fee;
    }

    pub fn setTransactionContext(self: *Self, origin: Address, gas_price: u256) void {
        self.origin = origin;
        self.gas_price = gas_price;
    }

    /// Configure hardfork for gas and access list rules
    pub fn setHardfork(self: *Self, hardfork: Hardfork) void {
        self.hardfork = hardfork;
    }

    /// Set account code
    pub fn setCode(self: *Self, address: Address, code: []const u8) !void {
        const code_copy = try self.allocator.alloc(u8, code.len);
        @memcpy(code_copy, code);
        try self.code.put(address, code_copy);
    }

    pub fn setBalance(self: *Self, address: Address, balance: u256) !void {
        try self.balances.put(address, balance);
    }

    pub fn access_address(self: *Self, address: Address) !u64 {
        if (self.hardfork.isBefore(.BERLIN)) {
            @branchHint(.cold);
            return GasConstants.CallCodeCost;
        }

        const entry = try self.warm_addresses.getOrPut(address);
        return if (entry.found_existing)
            GasConstants.WarmStorageReadCost
        else
            GasConstants.ColdAccountAccessCost;
    }

    /// Access a storage slot and return the gas cost (EIP-2929 warm/cold)
    pub fn access_storage_slot(self: *Self, contract_address: Address, slot: u256) !u64 {
        if (self.hardfork.isBefore(.BERLIN)) {
            @branchHint(.cold);
            return GasConstants.SloadGas;
        }

        const key = StorageSlotKey{ .address = contract_address, .slot = slot };
        const entry = try self.warm_storage_slots.getOrPut(key);
        return if (entry.found_existing)
            GasConstants.WarmStorageReadCost
        else
            GasConstants.ColdSloadCost;
    }

    /// Pre-warm addresses for transaction initialization
    fn pre_warm_addresses(self: *Self, addresses: []const Address) !void {
        for (addresses) |address| {
            _ = self.warm_addresses.getOrPut(address) catch {
                return Error.StorageError;
            };
        }
    }

    fn pre_warm_transaction(self: *Self, target: Address) Error!void {
        var warm: [3]Address = undefined;
        var count: usize = 0;

        warm[count] = self.origin;
        count += 1;

        if (!target.equals(primitives.ZERO_ADDRESS)) {
            warm[count] = target;
            count += 1;
        }

        if (self.hardfork.isAtLeast(.SHANGHAI)) {
            @branchHint(.likely);
            warm[count] = self.block_coinbase;
            count += 1;
        }

        // Pre-warm origin, target, and coinbase
        try self.pre_warm_addresses(warm[0..count]);

        // Pre-warm precompiles if Berlin+
        if (!self.hardfork.isAtLeast(.BERLIN)) return;
        try self.pre_warm_addresses(&PRECOMPILE_ADDRESSES);
    }

    /// Execute bytecode (main entry point like evm.execute)
    pub fn execute(
        self: *Self,
        bytecode: []const u8,
        gas: i64,
        caller: Address,
        address: Address,
        value: u256,
        calldata: []const u8,
    ) Error!CallResult {        
        // Pre-warm transaction, including precompiles depending on hardfork
        try self.pre_warm_transaction(address);

        const intrinsic_gas: i64 = @intCast(GasConstants.TxGas);
        if (gas < intrinsic_gas) {
            @branchHint(.cold);
            return CallResult{
                .success = false,
                .gas_left = 0,
                .output = &[_]u8{},
            };
        }
        const execution_gas = gas - intrinsic_gas;
        const execution_gas_limit: u64 = @as(u64, @intCast(execution_gas));

        const frame = try self.allocator.create(MinimalFrame);
        frame.* = try MinimalFrame.init(
            self.allocator,
            bytecode,
            execution_gas,
            caller,
            address,
            value,
            calldata,
            @as(*anyopaque, @ptrCast(self)),
            self.hardfork,
        );

        // Push frame onto stack
        try self.frames.append(self.allocator, frame);
        defer _ = self.frames.pop();

        // Execute the frame
        frame.execute() catch {
            // Error case - return failure (arena will clean up)
            return CallResult{
                .success = false,
                .gas_left = 0,
                .output = &[_]u8{},
            };
        };

        // Frame was popped, current frame is automatically updated via getCurrentFrame()

        const output = try self.allocator.alloc(u8, frame.output.len);
        @memcpy(output, frame.output);

        var gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
        // Apply gas refund if the call was successful
        if (!frame.reverted) {
            // Calculate total gas used including intrinsic gas (TxGas)
            // The refund cap should be based on total gas used, not just execution gas
            const execution_gas_used = if (execution_gas_limit > gas_left) execution_gas_limit - gas_left else 0;
            const total_gas_used = GasConstants.TxGas + execution_gas_used;
            
            // Pre-London: refund up to half of gas used; post-London: refund up to one fifth of gas used
            const capped_refund = if (self.hardfork.isBefore(.LONDON)) blk: {
                @branchHint(.cold);
                break :blk @min(self.gas_refund, total_gas_used / 2);
            } else blk: {
                @branchHint(.likely);
                break :blk @min(self.gas_refund, total_gas_used / 5);
            };
            
            // Apply the refund
            gas_left = gas_left + capped_refund;
            self.gas_refund = 0;
        }

        // Return result
        const result = CallResult{
            .success = !frame.reverted,
            .gas_left = gas_left,
            .output = output,
        };

        // Reset transaction-scoped caches
        self.warm_addresses.clearRetainingCapacity();
        self.warm_storage_slots.clearRetainingCapacity();

        // No cleanup needed - arena handles it
        return result;
    }

    /// Handle inner call from frame (like evm.inner_call)
    pub fn inner_call(
        self: *Self,
        address: Address,
        value: u256,
        input: []const u8,
        gas: u64,
    ) Error!CallResult {
        if (self.frames.items.len >= 1024) {
            return CallResult{
                .success = false,
                .gas_left = 0,
                .output = &[_]u8{},
            };
        }

        // Get code for the target address
        const code = self.get_code(address);
        if (code.len == 0) {
            // Check if this is a precompile address
            if (self.is_precompile(address)) {
                var precompile_gas: u64 = 0;
                
                // Calculate gas cost based on precompile type
                if (address.equals(precompiles.ECRECOVER_ADDRESS)) {
                    precompile_gas = getEcrecoverGasCost();
                } else if (address.equals(precompiles.SHA256_ADDRESS)) {
                    precompile_gas = getSha256GasCost(input.len);
                } else if (address.equals(precompiles.RIPEMD160_ADDRESS)) {
                    precompile_gas = getRipemd160GasCost(input.len);
                } else if (address.equals(precompiles.IDENTITY_ADDRESS)) {
                    precompile_gas = getIdentityGasCost(input.len);
                } else if (address.equals(precompiles.MODEXP_ADDRESS)) {
                    precompile_gas = getModexpGasCost(self.hardfork, input);
                } else if (address.equals(precompiles.ECADD_ADDRESS)) {
                    precompile_gas = getEcaddGasCost(self.hardfork);
                } else if (address.equals(precompiles.ECMUL_ADDRESS)) {
                    precompile_gas = getEcmulGasCost(self.hardfork);
                } else if (address.equals(precompiles.ECPAIRING_ADDRESS)) {
                    precompile_gas = getEcpairingGasCost(self.hardfork, input.len);
                } else if (address.equals(precompiles.BLAKE2F_ADDRESS)) {
                    precompile_gas = getBlake2fGasCost(input);
                } else if (address.equals(precompiles.POINT_EVALUATION_ADDRESS)) {
                    precompile_gas = getPointEvaluationGasCost();
                } else if (address.equals(precompiles.BLS12_381_G1_ADD_ADDRESS)) {
                    precompile_gas = getBls12381G1AddGasCost();
                } else if (address.equals(precompiles.BLS12_381_G1_MSM_ADDRESS)) {
                    // G1 MSM (Multi-Scalar Multiplication)
                    // Input is 160*k bytes (128 bytes G1 point + 32 bytes scalar per pair)
                    precompile_gas = getBls12381G1MsmGasCost(input.len);
                } else if (address.equals(precompiles.BLS12_381_G2_ADD_ADDRESS)) {
                    precompile_gas = getBls12381G2AddGasCost();
                } else if (address.equals(precompiles.BLS12_381_G2_MSM_ADDRESS)) {
                    // G2 MSM (Multi-Scalar Multiplication)
                    // Input is 288*k bytes (256 bytes G2 point + 32 bytes scalar per pair)
                    precompile_gas = getBls12381G2MsmGasCost(input.len);
                } else if (address.equals(precompiles.BLS12_381_PAIRING_ADDRESS)) {
                    precompile_gas = getBls12381PairingGasCost(input.len);
                } else if (address.equals(precompiles.BLS12_381_MAP_FP_TO_G1_ADDRESS)) {
                    precompile_gas = getBls12381MapFpToG1GasCost();
                } else if (address.equals(precompiles.BLS12_381_MAP_FP2_TO_G2_ADDRESS)) {
                    precompile_gas = getBls12381MapFp2ToG2GasCost();
                }
                
                if (gas < precompile_gas) {
                    return CallResult{
                        .success = false,
                        .gas_left = 0,
                        .output = &[_]u8{},
                    };
                }
                
                // TODO: Implement actual precompile logic and output
                // For now, return dummy output with correct gas consumption
                const output = if (address.equals(precompiles.SHA256_ADDRESS) or
                                   address.equals(precompiles.ECRECOVER_ADDRESS) or
                                   address.equals(precompiles.RIPEMD160_ADDRESS)) blk: {
                    // These return 32 bytes
                    const result = try self.allocator.alloc(u8, 32);
                    @memset(result, 0);
                    break :blk result;
                } else if (address.equals(precompiles.IDENTITY_ADDRESS)) blk: {
                    // Identity returns the input
                    const result = try self.allocator.alloc(u8, input.len);
                    @memcpy(result, input);
                    break :blk result;
                } else &[_]u8{};
                
                return CallResult{
                    .success = true,
                    .gas_left = gas - precompile_gas,
                    .output = output,
                };
            }
            
            // Empty account - just return success
            return CallResult{
                .success = true,
                .gas_left = gas,
                .output = &[_]u8{},
            };
        }

        // Get caller from current frame
        const caller = if (self.getCurrentFrame()) |frame| frame.address else self.origin;

        // Create a new frame for the inner call
        const frame = try self.allocator.create(MinimalFrame);
        frame.* = try MinimalFrame.init(
            self.allocator,
            code,
            @intCast(gas),
            caller,
            address,
            value,
            input,
            @as(*anyopaque, @ptrCast(self)),
            self.hardfork,
        );

        try self.frames.append(self.allocator, frame);
        errdefer _ = self.frames.pop();

        frame.execute() catch {
            _ = self.frames.pop();
            return CallResult{
                .success = false,
                .gas_left = 0,
                .output = &[_]u8{},
            };
        };

        // Pop frame from stack
        _ = self.frames.pop();

        // Store return data
        const output = if (frame.output.len > 0) blk: {
            const output_copy = try self.allocator.alloc(u8, frame.output.len);
            @memcpy(output_copy, frame.output);
            break :blk output_copy;
        } else &[_]u8{};

        // Return result
        const result = CallResult{
            .success = !frame.reverted,
            .gas_left = @as(u64, @intCast(@max(frame.gas_remaining, 0))),
            .output = output,
        };

        // No cleanup needed - arena handles it
        return result;
    }

    /// Get balance of an address (called by frame)
    pub fn get_balance(self: *Self, address: Address) u256 {
        if (self.host) |host| {
            return host.getBalance(address);
        }
        return self.balances.get(address) orelse 0;
    }

    /// Get code for an address
    pub fn get_code(self: *Self, address: Address) []const u8 {
        if (self.host) |host| {
            return host.getCode(address);
        }
        return self.code.get(address) orelse &[_]u8{};
    }

    /// Get storage value (called by frame)
    pub fn get_storage(self: *Self, address: Address, slot: u256) u256 {
        if (self.host) |host| {
            return host.getStorage(address, slot);
        }
        const key = StorageSlotKey{ .address = address, .slot = slot };
        return self.storage.get(key) orelse 0;
    }

    /// Set storage value (called by frame)
    pub fn set_storage(self: *Self, address: Address, slot: u256, value: u256) !void {
        if (self.host) |host| {
            host.setStorage(address, slot, value);
            return;
        }
        const key = StorageSlotKey{ .address = address, .slot = slot };

        // Track original value on first write in transaction
        if (!self.original_storage.contains(key)) {
            const current = self.storage.get(key) orelse 0;
            try self.original_storage.put(key, current);
        }

        try self.storage.put(key, value);
    }

    /// Get original storage value (before transaction modifications)
    pub fn get_original_storage(self: *Self, address: Address, slot: u256) u256 {
        const key = StorageSlotKey{ .address = address, .slot = slot };
        // If we have tracked the original, return it
        if (self.original_storage.get(key)) |original| {
            return original;
        }
        // Otherwise return current value (unchanged in this transaction)
        return self.storage.get(key) orelse 0;
    }

    /// Add gas refund
    pub fn add_refund(self: *Self, amount: u64) void {
        self.gas_refund +%= amount;
    }

    /// Check if an address is a precompile
    pub fn is_precompile(self: *const Self, address: Address) bool {
        _ = self;
        for (PRECOMPILE_ADDRESSES) |precompile| {
            if (address.equals(precompile)) return true;
        }
        return false;
    }

    /// Get current frame (top of the frame stack)
    pub fn getCurrentFrame(self: *const Self) ?*MinimalFrame {
        if (self.frames.items.len > 0) {
            return self.frames.items[self.frames.items.len - 1];
        }
        return null;
    }

    /// Get current frame's PC (for tracer)
    pub fn getPC(self: *const Self) u32 {
        if (self.getCurrentFrame()) |frame| {
            return frame.pc;
        }
        return 0;
    }

    /// Get current frame's bytecode (for tracer)
    pub fn getBytecode(self: *const Self) []const u8 {
        if (self.getCurrentFrame()) |frame| {
            return frame.bytecode;
        }
        return &[_]u8{};
    }

    /// Execute a single step (for tracer)
    pub fn step(self: *Self) !void {
        if (self.getCurrentFrame()) |frame| {
            try frame.step();
        }
    }
};
