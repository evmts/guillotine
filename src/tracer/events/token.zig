const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;

// Standard ERC20 event signatures (topic[0] values)
pub const ERC20_TRANSFER_SIGNATURE: [32]u8 = [32]u8{
    0xdd, 0xf2, 0x52, 0xad, 0x1b, 0xe2, 0xc8, 0x9b,
    0x69, 0xc2, 0xb0, 0x68, 0xfc, 0x37, 0x8d, 0xaa,
    0x95, 0x2b, 0xa7, 0xf1, 0x63, 0xc4, 0xa1, 0x16,
    0x28, 0xf5, 0x5a, 0x4d, 0xf5, 0x23, 0xb3, 0xef,
}; // Transfer(address,address,uint256)

pub const ERC20_APPROVAL_SIGNATURE: [32]u8 = [32]u8{
    0x8c, 0x5b, 0xe1, 0xe5, 0xeb, 0xec, 0x7d, 0x5b,
    0xd1, 0x4f, 0x71, 0x42, 0x7d, 0x1e, 0x84, 0xf3,
    0xdd, 0x03, 0x14, 0xc0, 0xf7, 0xb2, 0x29, 0x1e,
    0x5b, 0x20, 0x0a, 0xc8, 0xc7, 0xc3, 0xb9, 0x25,
}; // Approval(address,address,uint256)

// Standard ERC20 function selectors
pub const ERC20_SELECTORS = struct {
    pub const transfer: [4]u8 = [4]u8{ 0xa9, 0x05, 0x9c, 0xbb }; // transfer(address,uint256)
    pub const transfer_from: [4]u8 = [4]u8{ 0x23, 0xb8, 0x72, 0xdd }; // transferFrom(address,address,uint256)
    pub const approve: [4]u8 = [4]u8{ 0x09, 0x5e, 0xa7, 0xb3 }; // approve(address,uint256)
    pub const balance_of: [4]u8 = [4]u8{ 0x70, 0xa0, 0x82, 0x31 }; // balanceOf(address)
    pub const total_supply: [4]u8 = [4]u8{ 0x18, 0x16, 0x0d, 0xdd }; // totalSupply()
    pub const allowance: [4]u8 = [4]u8{ 0xdd, 0x62, 0xed, 0x3e }; // allowance(address,address)
    pub const decimals: [4]u8 = [4]u8{ 0x31, 0x3c, 0xe5, 0x67 }; // decimals()
    pub const symbol: [4]u8 = [4]u8{ 0x95, 0xd8, 0x9b, 0x41 }; // symbol()
    pub const name: [4]u8 = [4]u8{ 0x06, 0xfd, 0xde, 0x03 }; // name()
};

// ERC721 event signatures
pub const ERC721_TRANSFER_SIGNATURE: [32]u8 = [32]u8{
    0xdd, 0xf2, 0x52, 0xad, 0x1b, 0xe2, 0xc8, 0x9b,
    0x69, 0xc2, 0xb0, 0x68, 0xfc, 0x37, 0x8d, 0xaa,
    0x95, 0x2b, 0xa7, 0xf1, 0x63, 0xc4, 0xa1, 0x16,
    0x28, 0xf5, 0x5a, 0x4d, 0xf5, 0x23, 0xb3, 0xef,
}; // Same as ERC20 but with indexed tokenId

pub const ERC721_APPROVAL_SIGNATURE: [32]u8 = [32]u8{
    0x8c, 0x5b, 0xe1, 0xe5, 0xeb, 0xec, 0x7d, 0x5b,
    0xd1, 0x4f, 0x71, 0x42, 0x7d, 0x1e, 0x84, 0xf3,
    0xdd, 0x03, 0x14, 0xc0, 0xf7, 0xb2, 0x29, 0x1e,
    0x5b, 0x20, 0x0a, 0xc8, 0xc7, 0xc3, 0xb9, 0x25,
}; // Same signature, different params

// Helper function to check if a topic matches ERC20 Transfer
pub fn isErc20TransferTopic(topic: [32]u8) bool {
    return std.mem.eql(u8, &topic, &ERC20_TRANSFER_SIGNATURE);
}

// Helper function to check if a selector matches any ERC20 function
pub fn isErc20Selector(selector: [4]u8) bool {
    return std.mem.eql(u8, &selector, &ERC20_SELECTORS.transfer) or
        std.mem.eql(u8, &selector, &ERC20_SELECTORS.transfer_from) or
        std.mem.eql(u8, &selector, &ERC20_SELECTORS.approve) or
        std.mem.eql(u8, &selector, &ERC20_SELECTORS.balance_of) or
        std.mem.eql(u8, &selector, &ERC20_SELECTORS.total_supply) or
        std.mem.eql(u8, &selector, &ERC20_SELECTORS.allowance) or
        std.mem.eql(u8, &selector, &ERC20_SELECTORS.decimals) or
        std.mem.eql(u8, &selector, &ERC20_SELECTORS.symbol) or
        std.mem.eql(u8, &selector, &ERC20_SELECTORS.name);
}

/// ERC20 Transfer event detected
pub const Erc20Transfer = struct {
    token: Address,
    from: Address,
    to: Address,
    amount: u256,
    log_index: u32,
    detected_by: DetectionMethod,
    confidence: ConfidenceLevel,
};

/// ERC20 Approval event detected
pub const Erc20Approval = struct {
    token: Address,
    owner: Address,
    spender: Address,
    amount: u256,
    log_index: u32,
    detected_by: DetectionMethod,
    confidence: ConfidenceLevel,
};

/// ERC20 Mint detected (transfer from zero address)
pub const Erc20Mint = struct {
    token: Address,
    to: Address,
    amount: u256,
    total_supply_after: ?u256,
    detected_by: DetectionMethod,
};

/// ERC20 Burn detected (transfer to zero address)
pub const Erc20Burn = struct {
    token: Address,
    from: Address,
    amount: u256,
    total_supply_after: ?u256,
    detected_by: DetectionMethod,
};

/// ERC20 function call detected
pub const Erc20FunctionDetected = struct {
    contract: Address,
    function_selector: [4]u8,
    function_name: Erc20Function,
    caller: Address,
    success: bool,
    return_data: []const u8,
};

/// ERC20 contract detected through heuristics
pub const Erc20ContractDetected = struct {
    contract: Address,
    detection_score: u8,
    detected_functions: u32,
    has_transfer_event: bool,
    has_approval_event: bool,
    has_decimals: bool,
    has_symbol: bool,
    has_name: bool,
    probable_decimals: ?u8,
    probable_symbol: ?[]const u8,
    probable_name: ?[]const u8,
};

/// ERC721 Transfer event detected
pub const Erc721Transfer = struct {
    token: Address,
    from: Address,
    to: Address,
    token_id: u256,
    log_index: u32,
    detected_by: DetectionMethod,
};

/// ERC721 Approval event detected
pub const Erc721Approval = struct {
    token: Address,
    owner: Address,
    approved: Address,
    token_id: u256,
    log_index: u32,
    detected_by: DetectionMethod,
};

/// ERC1155 Transfer event detected
pub const Erc1155Transfer = struct {
    token: Address,
    operator: Address,
    from: Address,
    to: Address,
    id: u256,
    value: u256,
    log_index: u32,
    is_batch: bool,
    detected_by: DetectionMethod,
};

/// Generic token pattern detected
pub const TokenPatternDetected = struct {
    contract: Address,
    pattern_type: TokenPattern,
    confidence: ConfidenceLevel,
    evidence: TokenEvidence,
};

// Supporting types
pub const DetectionMethod = enum {
    event_signature,
    function_selector,
    bytecode_pattern,
    storage_pattern,
    heuristic,
    combined,
};

pub const ConfidenceLevel = enum {
    certain,
    high,
    medium,
    low,
    uncertain,
};

pub const Erc20Function = enum {
    transfer,
    transfer_from,
    approve,
    balance_of,
    total_supply,
    allowance,
    decimals,
    symbol,
    name,
    mint,
    burn,
    permit,
    increase_allowance,
    decrease_allowance,
    unknown,
};

pub const TokenPattern = enum {
    erc20,
    erc721,
    erc777,
    erc1155,
    erc4626,
    wrapped_token,
    stablecoin,
    rebase_token,
    fee_on_transfer,
    pausable_token,
    upgradeable_token,
    governance_token,
    unknown,
};

pub const TokenEvidence = struct {
    has_standard_events: bool,
    has_standard_functions: bool,
    follows_storage_pattern: bool,
    decimals_in_range: bool,
    symbol_looks_valid: bool,
    name_looks_valid: bool,
    total_supply_reasonable: bool,
    balance_mapping_detected: bool,
    allowance_mapping_detected: bool,
};