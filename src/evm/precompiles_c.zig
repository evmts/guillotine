// ============================================================================
// PRECOMPILES C API - FFI interface for Ethereum precompiled contracts
// ============================================================================

const std = @import("std");
const evm = @import("evm");
const precompiles = evm.precompiles;
const primitives = @import("primitives");
const Address = primitives.Address.Address;

const allocator = std.heap.c_allocator;

// ============================================================================
// ERROR CODES
// ============================================================================

pub const EVM_PRECOMPILE_SUCCESS: c_int = 0;
pub const EVM_PRECOMPILE_ERROR_NULL_POINTER: c_int = -1;
pub const EVM_PRECOMPILE_ERROR_INVALID_INPUT: c_int = -2;
pub const EVM_PRECOMPILE_ERROR_OUT_OF_GAS: c_int = -3;
pub const EVM_PRECOMPILE_ERROR_EXECUTION_ERROR: c_int = -4;
pub const EVM_PRECOMPILE_ERROR_OUT_OF_MEMORY: c_int = -5;
pub const EVM_PRECOMPILE_ERROR_NOT_PRECOMPILE: c_int = -6;
pub const EVM_PRECOMPILE_ERROR_NOT_IMPLEMENTED: c_int = -7;

// ============================================================================
// C TYPES
// ============================================================================

/// C-compatible address type
pub const CAddress = extern struct {
    bytes: [20]u8,
};

/// C-compatible precompile execution result
pub const CPrecompileResult = extern struct {
    success: c_int,
    gas_used: u64,
    output_ptr: [*]u8,
    output_len: usize,
    error_code: c_int,
};

/// Known precompile addresses as constants
pub const PRECOMPILE_ECRECOVER: u8 = 1;
pub const PRECOMPILE_SHA256: u8 = 2;
pub const PRECOMPILE_RIPEMD160: u8 = 3;
pub const PRECOMPILE_IDENTITY: u8 = 4;
pub const PRECOMPILE_MODEXP: u8 = 5;
pub const PRECOMPILE_ECADD: u8 = 6;
pub const PRECOMPILE_ECMUL: u8 = 7;
pub const PRECOMPILE_ECPAIRING: u8 = 8;
pub const PRECOMPILE_BLAKE2F: u8 = 9;
pub const PRECOMPILE_POINT_EVALUATION: u8 = 10;

// ============================================================================
// ADDRESS UTILITIES
// ============================================================================

/// Check if an address is a precompile
/// @param address Pointer to 20-byte address
/// @return 1 if precompile, 0 otherwise
pub export fn evm_is_precompile(address: ?*const CAddress) c_int {
    const addr = address orelse return 0;
    
    const native_addr: Address = addr.bytes;
    return if (precompiles.is_precompile(native_addr)) 1 else 0;
}

/// Get precompile ID from address (last byte if valid precompile)
/// @param address Pointer to 20-byte address
/// @return Precompile ID (1-10), or 0 if not a precompile
pub export fn evm_get_precompile_id(address: ?*const CAddress) u8 {
    const addr = address orelse return 0;
    
    const native_addr: Address = addr.bytes;
    if (!precompiles.is_precompile(native_addr)) return 0;
    
    return native_addr[19]; // Last byte is the precompile ID
}

/// Create a precompile address from ID
/// @param precompile_id Precompile ID (1-10)
/// @param address_out Output address
/// @return Error code
pub export fn evm_create_precompile_address(precompile_id: u8, address_out: ?*CAddress) c_int {
    const addr = address_out orelse return EVM_PRECOMPILE_ERROR_NULL_POINTER;
    
    if (precompile_id == 0 or precompile_id > 10) {
        return EVM_PRECOMPILE_ERROR_INVALID_INPUT;
    }
    
    // Create address: 19 zero bytes + precompile_id
    @memset(&addr.bytes, 0);
    addr.bytes[19] = precompile_id;
    
    return EVM_PRECOMPILE_SUCCESS;
}

// ============================================================================
// PRECOMPILE EXECUTION
// ============================================================================

/// Execute a precompile by address
/// @param address Pointer to precompile address
/// @param input Pointer to input data
/// @param input_len Length of input data
/// @param gas_limit Gas limit for execution
/// @param result Output result structure
/// @return Error code
pub export fn evm_execute_precompile(
    address: ?*const CAddress,
    input: ?[*]const u8,
    input_len: usize,
    gas_limit: u64,
    result: ?*CPrecompileResult
) c_int {
    const addr = address orelse return EVM_PRECOMPILE_ERROR_NULL_POINTER;
    const res = result orelse return EVM_PRECOMPILE_ERROR_NULL_POINTER;
    
    // Initialize result
    res.success = 0;
    res.gas_used = 0;
    res.output_ptr = undefined;
    res.output_len = 0;
    res.error_code = EVM_PRECOMPILE_SUCCESS;
    
    const native_addr: Address = addr.bytes;
    const input_slice = if (input) |ptr| ptr[0..input_len] else &[_]u8{};
    
    // Execute precompile
    const output = precompiles.execute_precompile(allocator, native_addr, input_slice, gas_limit) catch |err| {
        res.error_code = switch (err) {
            error.InvalidInput => EVM_PRECOMPILE_ERROR_INVALID_INPUT,
            error.OutOfGas => EVM_PRECOMPILE_ERROR_OUT_OF_GAS,
            error.ExecutionError => EVM_PRECOMPILE_ERROR_EXECUTION_ERROR,
            error.OutOfMemory => EVM_PRECOMPILE_ERROR_OUT_OF_MEMORY,
            error.NotImplemented => EVM_PRECOMPILE_ERROR_NOT_IMPLEMENTED,
            else => EVM_PRECOMPILE_ERROR_EXECUTION_ERROR,
        };
        return res.error_code;
    };
    
    // Fill result
    res.success = if (output.success) 1 else 0;
    res.gas_used = output.gas_used;
    res.output_ptr = @constCast(output.output.ptr);
    res.output_len = output.output.len;
    
    return EVM_PRECOMPILE_SUCCESS;
}

/// Execute a precompile by ID (convenience function)
/// @param precompile_id Precompile ID (1-10)
/// @param input Pointer to input data
/// @param input_len Length of input data
/// @param gas_limit Gas limit for execution
/// @param result Output result structure
/// @return Error code
pub export fn evm_execute_precompile_by_id(
    precompile_id: u8,
    input: ?[*]const u8,
    input_len: usize,
    gas_limit: u64,
    result: ?*CPrecompileResult
) c_int {
    var address: CAddress = undefined;
    const addr_result = evm_create_precompile_address(precompile_id, &address);
    if (addr_result != EVM_PRECOMPILE_SUCCESS) return addr_result;
    
    return evm_execute_precompile(&address, input, input_len, gas_limit, result);
}

// ============================================================================
// INDIVIDUAL PRECOMPILE FUNCTIONS
// ============================================================================

/// Execute ecRecover precompile (0x01)
/// @param input Hash(32) + v(32) + r(32) + s(32) = 128 bytes
/// @param input_len Length of input (should be 128)
/// @param gas_limit Gas limit
/// @param result Output result
/// @return Error code
pub export fn evm_ecrecover(
    input: ?[*]const u8,
    input_len: usize,
    gas_limit: u64,
    result: ?*CPrecompileResult
) c_int {
    return evm_execute_precompile_by_id(PRECOMPILE_ECRECOVER, input, input_len, gas_limit, result);
}

/// Execute SHA256 precompile (0x02)
/// @param input Arbitrary input data
/// @param input_len Length of input
/// @param gas_limit Gas limit
/// @param result Output result (32-byte hash)
/// @return Error code
pub export fn evm_sha256(
    input: ?[*]const u8,
    input_len: usize,
    gas_limit: u64,
    result: ?*CPrecompileResult
) c_int {
    return evm_execute_precompile_by_id(PRECOMPILE_SHA256, input, input_len, gas_limit, result);
}

/// Execute RIPEMD160 precompile (0x03)
/// @param input Arbitrary input data
/// @param input_len Length of input
/// @param gas_limit Gas limit
/// @param result Output result (32-byte with 20-byte hash + 12 zero padding)
/// @return Error code
pub export fn evm_ripemd160(
    input: ?[*]const u8,
    input_len: usize,
    gas_limit: u64,
    result: ?*CPrecompileResult
) c_int {
    return evm_execute_precompile_by_id(PRECOMPILE_RIPEMD160, input, input_len, gas_limit, result);
}

/// Execute identity precompile (0x04)
/// @param input Arbitrary input data
/// @param input_len Length of input
/// @param gas_limit Gas limit
/// @param result Output result (exact copy of input)
/// @return Error code
pub export fn evm_identity(
    input: ?[*]const u8,
    input_len: usize,
    gas_limit: u64,
    result: ?*CPrecompileResult
) c_int {
    return evm_execute_precompile_by_id(PRECOMPILE_IDENTITY, input, input_len, gas_limit, result);
}

/// Execute modular exponentiation precompile (0x05)
/// @param input base_len(32) + exp_len(32) + mod_len(32) + base + exp + mod
/// @param input_len Length of input
/// @param gas_limit Gas limit
/// @param result Output result ((base^exp) % mod)
/// @return Error code
pub export fn evm_modexp(
    input: ?[*]const u8,
    input_len: usize,
    gas_limit: u64,
    result: ?*CPrecompileResult
) c_int {
    return evm_execute_precompile_by_id(PRECOMPILE_MODEXP, input, input_len, gas_limit, result);
}

/// Execute BN254 elliptic curve addition precompile (0x06)
/// @param input x1(32) + y1(32) + x2(32) + y2(32) = 128 bytes
/// @param input_len Length of input (should be 128)
/// @param gas_limit Gas limit
/// @param result Output result (x(32) + y(32) = 64 bytes)
/// @return Error code
pub export fn evm_ecadd(
    input: ?[*]const u8,
    input_len: usize,
    gas_limit: u64,
    result: ?*CPrecompileResult
) c_int {
    return evm_execute_precompile_by_id(PRECOMPILE_ECADD, input, input_len, gas_limit, result);
}

/// Execute BN254 elliptic curve multiplication precompile (0x07)
/// @param input x(32) + y(32) + scalar(32) = 96 bytes
/// @param input_len Length of input (should be 96)
/// @param gas_limit Gas limit
/// @param result Output result (x(32) + y(32) = 64 bytes)
/// @return Error code
pub export fn evm_ecmul(
    input: ?[*]const u8,
    input_len: usize,
    gas_limit: u64,
    result: ?*CPrecompileResult
) c_int {
    return evm_execute_precompile_by_id(PRECOMPILE_ECMUL, input, input_len, gas_limit, result);
}

/// Execute BN254 pairing check precompile (0x08)
/// @param input Pairs of G1+G2 points (192 bytes per pair)
/// @param input_len Length of input (must be multiple of 192)
/// @param gas_limit Gas limit
/// @param result Output result (32 bytes: 1 if valid pairing, 0 otherwise)
/// @return Error code
pub export fn evm_ecpairing(
    input: ?[*]const u8,
    input_len: usize,
    gas_limit: u64,
    result: ?*CPrecompileResult
) c_int {
    return evm_execute_precompile_by_id(PRECOMPILE_ECPAIRING, input, input_len, gas_limit, result);
}

/// Execute BLAKE2F compression precompile (0x09)
/// @param input rounds(4) + h(64) + m(128) + t(16) + f(1) = 213 bytes
/// @param input_len Length of input (must be 213)
/// @param gas_limit Gas limit
/// @param result Output result (64-byte BLAKE2b state)
/// @return Error code
pub export fn evm_blake2f(
    input: ?[*]const u8,
    input_len: usize,
    gas_limit: u64,
    result: ?*CPrecompileResult
) c_int {
    return evm_execute_precompile_by_id(PRECOMPILE_BLAKE2F, input, input_len, gas_limit, result);
}

/// Execute KZG point evaluation precompile (0x0A)
/// @param input versioned_hash(32) + z(32) + y(32) + commitment(48) + proof(48) = 192 bytes
/// @param input_len Length of input (must be 192)
/// @param gas_limit Gas limit
/// @param result Output result (64 bytes)
/// @return Error code
pub export fn evm_point_evaluation(
    input: ?[*]const u8,
    input_len: usize,
    gas_limit: u64,
    result: ?*CPrecompileResult
) c_int {
    return evm_execute_precompile_by_id(PRECOMPILE_POINT_EVALUATION, input, input_len, gas_limit, result);
}

// ============================================================================
// GAS COST QUERIES
// ============================================================================

/// Get base gas cost for a precompile
/// @param precompile_id Precompile ID (1-10)
/// @return Base gas cost, or 0 if invalid
pub export fn evm_precompile_base_gas_cost(precompile_id: u8) u64 {
    return switch (precompile_id) {
        PRECOMPILE_ECRECOVER => precompiles.GasCosts.ECRECOVER,
        PRECOMPILE_SHA256 => precompiles.GasCosts.SHA256_BASE,
        PRECOMPILE_RIPEMD160 => precompiles.GasCosts.RIPEMD160_BASE,
        PRECOMPILE_IDENTITY => precompiles.GasCosts.IDENTITY_BASE,
        PRECOMPILE_MODEXP => precompiles.GasCosts.MODEXP_MIN,
        PRECOMPILE_ECADD => precompiles.GasCosts.ECADD,
        PRECOMPILE_ECMUL => precompiles.GasCosts.ECMUL,
        PRECOMPILE_ECPAIRING => precompiles.GasCosts.ECPAIRING_BASE,
        PRECOMPILE_BLAKE2F => 0, // Dynamic based on rounds
        PRECOMPILE_POINT_EVALUATION => precompiles.GasCosts.POINT_EVALUATION,
        else => 0,
    };
}

/// Calculate gas cost for SHA256 precompile based on input size
/// @param input_len Length of input data
/// @return Total gas cost
pub export fn evm_sha256_gas_cost(input_len: usize) u64 {
    const word_count = (input_len + 31) / 32;
    return precompiles.GasCosts.SHA256_BASE + word_count * precompiles.GasCosts.SHA256_PER_WORD;
}

/// Calculate gas cost for RIPEMD160 precompile based on input size
/// @param input_len Length of input data
/// @return Total gas cost
pub export fn evm_ripemd160_gas_cost(input_len: usize) u64 {
    const word_count = (input_len + 31) / 32;
    return precompiles.GasCosts.RIPEMD160_BASE + word_count * precompiles.GasCosts.RIPEMD160_PER_WORD;
}

/// Calculate gas cost for identity precompile based on input size
/// @param input_len Length of input data
/// @return Total gas cost
pub export fn evm_identity_gas_cost(input_len: usize) u64 {
    const word_count = (input_len + 31) / 32;
    return precompiles.GasCosts.IDENTITY_BASE + word_count * precompiles.GasCosts.IDENTITY_PER_WORD;
}

/// Calculate gas cost for BLAKE2F precompile based on rounds
/// @param rounds Number of compression rounds
/// @return Total gas cost
pub export fn evm_blake2f_gas_cost(rounds: u32) u64 {
    return @as(u64, rounds) * precompiles.GasCosts.BLAKE2F_PER_ROUND;
}

/// Calculate gas cost for BN254 pairing precompile based on pair count
/// @param pair_count Number of G1/G2 pairs
/// @return Total gas cost
pub export fn evm_ecpairing_gas_cost(pair_count: usize) u64 {
    return precompiles.GasCosts.ECPAIRING_BASE + pair_count * precompiles.GasCosts.ECPAIRING_PER_PAIR;
}

// ============================================================================
// RESULT MANAGEMENT
// ============================================================================

/// Free output data from precompile result
/// @param result Precompile result with output to free
pub export fn evm_precompile_free_result(result: ?*CPrecompileResult) void {
    if (result) |res| {
        if (res.output_len > 0) {
            const output_slice = res.output_ptr[0..res.output_len];
            allocator.free(output_slice);
            res.output_ptr = undefined;
            res.output_len = 0;
        }
    }
}

// ============================================================================
// ERROR HANDLING
// ============================================================================

/// Convert error code to human-readable string
pub export fn evm_precompile_error_string(error_code: c_int) [*:0]const u8 {
    return switch (error_code) {
        EVM_PRECOMPILE_SUCCESS => "Success",
        EVM_PRECOMPILE_ERROR_NULL_POINTER => "Null pointer",
        EVM_PRECOMPILE_ERROR_INVALID_INPUT => "Invalid input",
        EVM_PRECOMPILE_ERROR_OUT_OF_GAS => "Out of gas",
        EVM_PRECOMPILE_ERROR_EXECUTION_ERROR => "Execution error",
        EVM_PRECOMPILE_ERROR_OUT_OF_MEMORY => "Out of memory",
        EVM_PRECOMPILE_ERROR_NOT_PRECOMPILE => "Not a precompile address",
        EVM_PRECOMPILE_ERROR_NOT_IMPLEMENTED => "Not implemented",
        else => "Unknown error",
    };
}

// ============================================================================
// UTILITIES
// ============================================================================

/// Get precompile name by ID
/// @param precompile_id Precompile ID (1-10)
/// @return Precompile name
pub export fn evm_precompile_name(precompile_id: u8) [*:0]const u8 {
    return switch (precompile_id) {
        PRECOMPILE_ECRECOVER => "ecRecover",
        PRECOMPILE_SHA256 => "SHA256",
        PRECOMPILE_RIPEMD160 => "RIPEMD160",
        PRECOMPILE_IDENTITY => "identity",
        PRECOMPILE_MODEXP => "modexp",
        PRECOMPILE_ECADD => "ecAdd",
        PRECOMPILE_ECMUL => "ecMul",
        PRECOMPILE_ECPAIRING => "ecPairing",
        PRECOMPILE_BLAKE2F => "blake2f",
        PRECOMPILE_POINT_EVALUATION => "pointEvaluation",
        else => "unknown",
    };
}

// ============================================================================
// TESTING
// ============================================================================

/// Test precompile address utilities
pub export fn evm_precompile_test_address() c_int {
    // Test address creation and recognition
    for (1..11) |id| {
        var addr: CAddress = undefined;
        if (evm_create_precompile_address(@intCast(id), &addr) != EVM_PRECOMPILE_SUCCESS) return -1;
        
        if (evm_is_precompile(&addr) != 1) return -2;
        if (evm_get_precompile_id(&addr) != id) return -3;
    }
    
    // Test invalid address
    var invalid_addr: CAddress = undefined;
    @memset(&invalid_addr.bytes, 0xFF);
    if (evm_is_precompile(&invalid_addr) != 0) return -4;
    
    return 0;
}

/// Test identity precompile execution
pub export fn evm_precompile_test_identity() c_int {
    const test_data = "Hello, World!";
    var result: CPrecompileResult = undefined;
    
    const ret = evm_identity(test_data.ptr, test_data.len, 1000, &result);
    if (ret != EVM_PRECOMPILE_SUCCESS) return -1;
    
    defer evm_precompile_free_result(&result);
    
    if (result.success != 1) return -2;
    if (result.output_len != test_data.len) return -3;
    
    const output_slice = result.output_ptr[0..result.output_len];
    if (!std.mem.eql(u8, test_data, output_slice)) return -4;
    
    return 0;
}

/// Test SHA256 precompile execution
pub export fn evm_precompile_test_sha256() c_int {
    const test_data = "abc";
    var result: CPrecompileResult = undefined;
    
    const ret = evm_sha256(test_data.ptr, test_data.len, 1000, &result);
    if (ret != EVM_PRECOMPILE_SUCCESS) return -1;
    
    defer evm_precompile_free_result(&result);
    
    if (result.success != 1) return -2;
    if (result.output_len != 32) return -3;
    
    // Check that we got some hash output (not all zeros)
    const output_slice = result.output_ptr[0..result.output_len];
    var all_zero = true;
    for (output_slice) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) return -4;
    
    return 0;
}

/// Test gas cost calculations
pub export fn evm_precompile_test_gas_costs() c_int {
    // Test base gas costs
    if (evm_precompile_base_gas_cost(PRECOMPILE_ECRECOVER) != precompiles.GasCosts.ECRECOVER) return -1;
    if (evm_precompile_base_gas_cost(PRECOMPILE_ECADD) != precompiles.GasCosts.ECADD) return -2;
    
    // Test dynamic gas costs
    if (evm_sha256_gas_cost(64) <= evm_sha256_gas_cost(32)) return -3; // Larger input should cost more
    if (evm_identity_gas_cost(64) <= evm_identity_gas_cost(32)) return -4;
    
    return 0;
}

test "Precompiles C API compilation" {
    std.testing.refAllDecls(@This());
}
