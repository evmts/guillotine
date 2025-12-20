const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const ConfidenceLevel = @import("token.zig").ConfidenceLevel;

/// Diamond proxy pattern detected (EIP-2535)
pub const DiamondProxyDetected = struct {
    diamond: Address,
    facets_detected: u32,
    selectors_mapped: u32,
    diamond_cut_selector: ?[4]u8,
    diamond_loupe_detected: bool,
    owner: ?Address,
    confidence: ConfidenceLevel,
};

/// Generic proxy pattern detected
pub const ProxyPatternDetected = struct {
    proxy: Address,
    implementation: ?Address,
    proxy_type: ProxyType,
    admin: ?Address,
    beacon: ?Address,
    storage_slot: ?u256,
    confidence: ConfidenceLevel,
};

/// Multi-signature wallet detected
pub const MultiSigDetected = struct {
    wallet: Address,
    owners_count: u32,
    threshold: u32,
    wallet_type: MultiSigType,
    pending_transactions: u32,
};

/// Timelock contract detected
pub const TimelockDetected = struct {
    timelock: Address,
    admin: Address,
    pending_admin: ?Address,
    minimum_delay: u256,
    maximum_delay: ?u256,
    proposer_role: ?[32]u8,
    executor_role: ?[32]u8,
    canceller_role: ?[32]u8,
};

/// ENS name registration
pub const EnsNameRegistered = struct {
    name_hash: [32]u8,
    label: [32]u8,
    owner: Address,
    cost: u256,
    expires: u256,
    name: ?[]const u8,
};

/// ENS name renewal
pub const EnsNameRenewed = struct {
    name_hash: [32]u8,
    label: [32]u8,
    cost: u256,
    expires: u256,
};

/// ENS name transfer
pub const EnsNameTransferred = struct {
    node: [32]u8,
    from: Address,
    to: Address,
};

/// ENS resolver change
pub const EnsResolverChanged = struct {
    node: [32]u8,
    resolver: Address,
};

/// ENS reverse record claimed
pub const EnsReverseClaimed = struct {
    addr: Address,
    node: [32]u8,
};

/// ENS text record changed
pub const EnsTextChanged = struct {
    node: [32]u8,
    key: []const u8,
    value: []const u8,
};

/// ENS address record changed
pub const EnsAddressChanged = struct {
    node: [32]u8,
    coin_type: u256,
    new_address: []const u8,
};

/// ENS content hash changed
pub const EnsContenthashChanged = struct {
    node: [32]u8,
    hash: []const u8,
};

// Supporting types
pub const ProxyType = enum {
    transparent,
    uups,
    beacon,
    diamond,
    minimal,
    gnosis_safe,
    eip1967,
    eip1822,
    eip897,
    master_copy,
    clone,
    unknown,
};

pub const MultiSigType = enum {
    gnosis_safe,
    gnosis_safe_l2,
    argent,
    multi_sig_wallet,
    timelock_multi_sig,
    unknown,
};