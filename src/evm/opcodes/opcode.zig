//! EVM opcode definitions and utilities
//!
//! This module defines all EVM opcodes as specified in the Ethereum Yellow Paper
//! and various EIPs. Each opcode is a single byte instruction that the EVM
//! interpreter executes.
//!
//! ## Opcode Categories
//! - Arithmetic: ADD, MUL, SUB, DIV, MOD, EXP, etc.
//! - Comparison: LT, GT, EQ, ISZERO
//! - Bitwise: AND, OR, XOR, NOT, SHL, SHR, SAR
//! - Environmental: ADDRESS, BALANCE, CALLER, CALLVALUE
//! - Block Information: BLOCKHASH, COINBASE, TIMESTAMP, NUMBER
//! - Stack Operations: POP, PUSH1-PUSH32, DUP1-DUP16, SWAP1-SWAP16
//! - Memory Operations: MLOAD, MSTORE, MSTORE8, MSIZE
//! - Storage Operations: SLOAD, SSTORE, TLOAD, TSTORE
//! - Flow Control: JUMP, JUMPI, PC, JUMPDEST
//! - System Operations: CREATE, CALL, RETURN, REVERT, SELFDESTRUCT
//! - Logging: LOG0-LOG4
//!
//! ## Opcode Encoding
//! Opcodes are encoded as single bytes (0x00-0xFF). Not all byte values
//! are assigned; unassigned values are treated as INVALID operations.
//!
//! ## Hardfork Evolution
//! New opcodes are introduced through EIPs and activated at specific
//! hardforks. Examples:
//! - PUSH0 (EIP-3855): Shanghai hardfork
//! - TLOAD/TSTORE (EIP-1153): Cancun hardfork
//! - MCOPY (EIP-5656): Cancun hardfork
//!
//! ## Usage Example
//! ```zig
//! const opcode = Opcode.Enum.ADD;
//! const byte_value = opcode.to_u8(); // 0x01
//! const name = opcode.get_name(); // "ADD"
//! ```

pub const MemorySize = @import("memory_size.zig");
const evm_limits = @import("../constants/evm_limits.zig");

/// Enumeration of all EVM opcodes with their byte values.
///
/// Each opcode is assigned a specific byte value that remains
/// constant across all EVM implementations. The enum ensures
/// type safety when working with opcodes.
pub const Enum = enum(u8) {
    /// Halts execution (0x00)
    STOP = 0x00,
    /// Addition operation: a + b (0x01)
    ADD = 0x01,
    /// Multiplication operation: a * b (0x02)
    MUL = 0x02,
    /// Subtraction operation: a - b (0x03)
    SUB = 0x03,
    /// Integer division operation: a / b (0x04)
    DIV = 0x04,
    /// Signed integer division operation (0x05)
    SDIV = 0x05,
    /// Modulo operation: a % b (0x06)
    MOD = 0x06,
    /// Signed modulo operation (0x07)
    SMOD = 0x07,
    /// Addition modulo: (a + b) % N (0x08)
    ADDMOD = 0x08,
    /// Multiplication modulo: (a * b) % N (0x09)
    MULMOD = 0x09,
    /// Exponential operation: a ** b (0x0A)
    EXP = 0x0A,
    /// Sign extend operation (0x0B)
    SIGNEXTEND = 0x0B,
    /// Less-than comparison: a < b (0x10)
    LT = 0x10,
    /// Greater-than comparison: a > b (0x11)
    GT = 0x11,
    /// Signed less-than comparison (0x12)
    SLT = 0x12,
    /// Signed greater-than comparison (0x13)
    SGT = 0x13,
    /// Equality comparison: a == b (0x14)
    EQ = 0x14,
    /// Check if value is zero (0x15)
    ISZERO = 0x15,
    /// Bitwise AND operation (0x16)
    AND = 0x16,
    /// Bitwise OR operation (0x17)
    OR = 0x17,
    /// Bitwise XOR operation (0x18)
    XOR = 0x18,
    /// Bitwise NOT operation (0x19)
    NOT = 0x19,
    /// Retrieve single byte from word (0x1A)
    BYTE = 0x1A,
    /// Logical shift left (0x1B)
    SHL = 0x1B,
    /// Logical shift right (0x1C)
    SHR = 0x1C,
    /// Arithmetic shift right (0x1D)
    SAR = 0x1D,
    /// Compute Keccak-256 hash (0x20)
    KECCAK256 = 0x20,
    /// Get address of currently executing account (0x30)
    ADDRESS = 0x30,
    /// Get balance of the given account (0x31)
    BALANCE = 0x31,
    /// Get execution origination address (0x32)
    ORIGIN = 0x32,
    /// Get caller address (0x33)
    CALLER = 0x33,
    /// Get deposited value by the caller (0x34)
    CALLVALUE = 0x34,
    /// Load input data of current call (0x35)
    CALLDATALOAD = 0x35,
    /// Get size of input data in current call (0x36)
    CALLDATASIZE = 0x36,
    /// Copy input data to memory (0x37)
    CALLDATACOPY = 0x37,
    /// Get size of code running in current environment (0x38)
    CODESIZE = 0x38,
    /// Copy code to memory (0x39)
    CODECOPY = 0x39,
    /// Get price of gas in current environment (0x3A)
    GASPRICE = 0x3A,
    EXTCODESIZE = 0x3B,
    EXTCODECOPY = 0x3C,
    RETURNDATASIZE = 0x3D,
    RETURNDATACOPY = 0x3E,
    EXTCODEHASH = 0x3F,
    BLOCKHASH = 0x40,
    COINBASE = 0x41,
    TIMESTAMP = 0x42,
    NUMBER = 0x43,
    PREVRANDAO = 0x44,
    GASLIMIT = 0x45,
    CHAINID = 0x46,
    SELFBALANCE = 0x47,
    BASEFEE = 0x48,
    BLOBHASH = 0x49,
    BLOBBASEFEE = 0x4A,
    POP = 0x50,
    MLOAD = 0x51,
    MSTORE = 0x52,
    MSTORE8 = 0x53,
    /// Load word from storage (0x54)
    SLOAD = 0x54,
    /// Store word to storage (0x55)
    SSTORE = 0x55,
    /// Unconditional jump (0x56)
    JUMP = 0x56,
    /// Conditional jump (0x57)
    JUMPI = 0x57,
    /// Get current program counter (0x58)
    PC = 0x58,
    /// Get size of active memory in bytes (0x59)
    MSIZE = 0x59,
    /// Get amount of available gas (0x5A)
    GAS = 0x5A,
    /// Mark valid jump destination (0x5B)
    JUMPDEST = 0x5B,
    /// Load word from transient storage (0x5C)
    TLOAD = 0x5C,
    /// Store word to transient storage (0x5D)
    TSTORE = 0x5D,
    /// Copy memory areas (0x5E)
    MCOPY = 0x5E,
    /// Push zero onto stack (0x5F)
    PUSH0 = 0x5F,
    PUSH1 = 0x60,
    PUSH2 = 0x61,
    PUSH3 = 0x62,
    PUSH4 = 0x63,
    PUSH5 = 0x64,
    PUSH6 = 0x65,
    PUSH7 = 0x66,
    PUSH8 = 0x67,
    PUSH9 = 0x68,
    PUSH10 = 0x69,
    PUSH11 = 0x6A,
    PUSH12 = 0x6B,
    PUSH13 = 0x6C,
    PUSH14 = 0x6D,
    PUSH15 = 0x6E,
    PUSH16 = 0x6F,
    PUSH17 = 0x70,
    PUSH18 = 0x71,
    PUSH19 = 0x72,
    PUSH20 = 0x73,
    PUSH21 = 0x74,
    PUSH22 = 0x75,
    PUSH23 = 0x76,
    PUSH24 = 0x77,
    PUSH25 = 0x78,
    PUSH26 = 0x79,
    PUSH27 = 0x7A,
    PUSH28 = 0x7B,
    PUSH29 = 0x7C,
    PUSH30 = 0x7D,
    PUSH31 = 0x7E,
    PUSH32 = 0x7F,
    DUP1 = 0x80,
    DUP2 = 0x81,
    DUP3 = 0x82,
    DUP4 = 0x83,
    DUP5 = 0x84,
    DUP6 = 0x85,
    DUP7 = 0x86,
    DUP8 = 0x87,
    DUP9 = 0x88,
    DUP10 = 0x89,
    DUP11 = 0x8A,
    DUP12 = 0x8B,
    DUP13 = 0x8C,
    DUP14 = 0x8D,
    DUP15 = 0x8E,
    DUP16 = 0x8F,
    SWAP1 = 0x90,
    SWAP2 = 0x91,
    SWAP3 = 0x92,
    SWAP4 = 0x93,
    SWAP5 = 0x94,
    SWAP6 = 0x95,
    SWAP7 = 0x96,
    SWAP8 = 0x97,
    SWAP9 = 0x98,
    SWAP10 = 0x99,
    SWAP11 = 0x9A,
    SWAP12 = 0x9B,
    SWAP13 = 0x9C,
    SWAP14 = 0x9D,
    SWAP15 = 0x9E,
    SWAP16 = 0x9F,
    LOG0 = 0xA0,
    LOG1 = 0xA1,
    LOG2 = 0xA2,
    LOG3 = 0xA3,
    LOG4 = 0xA4,
    /// Create new contract (0xF0)
    CREATE = 0xF0,
    /// Message-call into account (0xF1)
    CALL = 0xF1,
    /// Message-call with current code (0xF2)
    CALLCODE = 0xF2,
    /// Halt execution returning output data (0xF3)
    RETURN = 0xF3,
    /// Call with current sender and value (0xF4)
    DELEGATECALL = 0xF4,
    /// Create with deterministic address (0xF5)
    CREATE2 = 0xF5,
    /// Load return data (0xF7)
    RETURNDATALOAD = 0xF7,
    /// Extended call (EOF) (0xF8)
    EXTCALL = 0xF8,
    /// Extended delegate call (EOF) (0xF9)
    EXTDELEGATECALL = 0xF9,
    /// Static message-call (0xFA)
    STATICCALL = 0xFA,
    /// Extended static call (EOF) (0xFB)
    EXTSTATICCALL = 0xFB,
    /// Halt execution reverting state changes (0xFD)
    REVERT = 0xFD,
    /// Invalid instruction (0xFE)
    INVALID = 0xFE,
    /// Destroy current contract (0xFF)
    SELFDESTRUCT = 0xFF,
};

/// Convert an opcode to its byte representation.
///
/// Returns the underlying byte value of the opcode for use in
/// bytecode encoding/decoding and jump table lookups.
///
/// @param self The opcode to convert
/// @return The byte value (0x00-0xFF)
///
/// Example:
/// ```zig
/// const add_byte = Opcode.Enum.ADD.to_u8(); // Returns 0x01
/// const push1_byte = Opcode.Enum.PUSH1.to_u8(); // Returns 0x60
/// ```
pub fn to_u8(self: Enum) u8 {
    return @intFromEnum(self);
}

/// Get the human-readable name of an opcode.
///
/// Returns the mnemonic string representation of the opcode
/// as used in assembly code and debugging output.
///
/// @param self The opcode to get the name of
/// @return Static string containing the opcode mnemonic
///
/// Example:
/// ```zig
/// const name = Opcode.Enum.ADD.get_name(); // Returns "ADD"
/// std.debug.print("Executing opcode: {s}\n", .{name});
/// ```
pub fn get_name(self: Enum) []const u8 {
    // Build a lookup table at comptime
    const names = comptime blk: {
        var n: [256][]const u8 = undefined;

        // Initialize all to "UNDEFINED"
        for (&n) |*name| {
            name.* = "UNDEFINED";
        }

        // Map enum values to their names using reflection
        const enum_info = @typeInfo(Enum);
        switch (enum_info) {
            .@"enum" => |e| {
                for (e.fields) |field| {
                    const value = @field(Enum, field.name);
                    n[@intFromEnum(value)] = field.name;
                }
            },
            else => @compileError("get_name requires an enum type"),
        }

        break :blk n;
    };

    return names[@intFromEnum(self)];
}

/// Checks if an opcode is a PUSH operation (PUSH1-PUSH32).
///
/// PUSH operations place N bytes of immediate data onto the stack,
/// where N is determined by the specific PUSH opcode.
///
/// ## Parameters
/// - `op`: The opcode byte to check
///
/// ## Returns
/// - `true` if the opcode is between PUSH1 (0x60) and PUSH32 (0x7F)
/// - `false` otherwise
///
/// ## Example
/// ```zig
/// if (is_push(opcode)) {
///     const data_size = get_push_size(opcode);
///     // Read `data_size` bytes following the opcode
/// }
/// ```
pub fn is_push(op: u8) bool {
    return op >= @intFromEnum(Enum.PUSH1) and op <= @intFromEnum(Enum.PUSH32);
}

/// Returns the number of immediate data bytes for a PUSH opcode.
///
/// PUSH1 pushes 1 byte, PUSH2 pushes 2 bytes, etc., up to PUSH32
/// which pushes 32 bytes of immediate data from the bytecode.
///
/// ## Parameters
/// - `op`: The opcode byte to analyze
///
/// ## Returns
/// - 1-32 for valid PUSH opcodes (PUSH1-PUSH32)
/// - 0 for non-PUSH opcodes
///
/// ## Algorithm
/// For valid PUSH opcodes: size = opcode - 0x60 + 1
///
/// ## Example
/// ```zig
/// const size = get_push_size(@intFromEnum(Opcode.Enum.PUSH20)); // Returns 20
/// const size2 = get_push_size(@intFromEnum(Opcode.Enum.ADD));   // Returns 0
/// ```
pub fn get_push_size(op: u8) u8 {
    if (!is_push(op)) return 0;
    return op - @intFromEnum(Enum.PUSH1) + 1;
}

/// Checks if an opcode is a DUP operation (DUP1-DUP16).
///
/// DUP operations duplicate a stack item and push the copy onto the stack.
/// DUP1 duplicates the top item, DUP2 the second item, etc.
///
/// ## Parameters
/// - `op`: The opcode byte to check
///
/// ## Returns
/// - `true` if the opcode is between DUP1 (0x80) and DUP16 (0x8F)
/// - `false` otherwise
///
/// ## Stack Effect
/// DUPn: [... vn ... v1] -> [... vn ... v1 vn]
pub fn is_dup(op: u8) bool {
    return op >= @intFromEnum(Enum.DUP1) and op <= @intFromEnum(Enum.DUP16);
}

/// Get the stack position for a DUP opcode
/// Returns 0 for non-DUP opcodes
pub fn get_dup_position(op: u8) u8 {
    if (!is_dup(op)) return 0;
    return op - @intFromEnum(Enum.DUP1) + 1;
}

/// Check if an opcode is a SWAP operation
pub fn is_swap(op: u8) bool {
    return op >= @intFromEnum(Enum.SWAP1) and op <= @intFromEnum(Enum.SWAP16);
}

/// Get the stack position for a SWAP opcode
/// Returns 0 for non-SWAP opcodes
pub fn get_swap_position(op: u8) u8 {
    if (!is_swap(op)) return 0;
    return op - @intFromEnum(Enum.SWAP1) + 1;
}

/// Check if an opcode is a LOG operation
pub fn is_log(op: u8) bool {
    return op >= @intFromEnum(Enum.LOG0) and op <= @intFromEnum(Enum.LOG4);
}

/// Get the number of topics for a LOG opcode
/// Returns 0 for non-LOG opcodes
pub fn get_log_topic_count(op: u8) u8 {
    if (!is_log(op)) return 0;
    return op - @intFromEnum(Enum.LOG0);
}

/// Checks if an opcode terminates execution of the current context.
///
/// Terminating operations end the current execution context and cannot
/// be followed by any other operations in the execution flow.
///
/// ## Parameters
/// - `op`: The opcode byte to check
///
/// ## Returns
/// - `true` for STOP, RETURN, REVERT, SELFDESTRUCT, INVALID
/// - `false` otherwise
///
/// ## Terminating Opcodes
/// - STOP (0x00): Halts execution successfully
/// - RETURN (0xF3): Returns data and halts successfully
/// - REVERT (0xFD): Reverts state changes and returns data
/// - SELFDESTRUCT (0xFF): Destroys contract and sends balance
/// - INVALID (0xFE): Invalid operation, always reverts
///
/// ## Usage
/// ```zig
/// if (is_terminating(opcode)) {
///     // This is the last operation in this context
///     return;
/// }
/// ```
pub fn is_terminating(op: u8) bool {
    return op == @intFromEnum(Enum.STOP) or op == @intFromEnum(Enum.RETURN) or
        op == @intFromEnum(Enum.REVERT) or op == @intFromEnum(Enum.SELFDESTRUCT) or
        op == @intFromEnum(Enum.INVALID);
}

/// Check if an opcode is a call operation
pub fn is_call(op: u8) bool {
    return op == @intFromEnum(Enum.CALL) or op == @intFromEnum(Enum.CALLCODE) or
        op == @intFromEnum(Enum.DELEGATECALL) or op == @intFromEnum(Enum.STATICCALL) or
        op == @intFromEnum(Enum.EXTCALL) or op == @intFromEnum(Enum.EXTDELEGATECALL) or
        op == @intFromEnum(Enum.EXTSTATICCALL);
}

/// Check if an opcode is a create operation
pub fn is_create(op: u8) bool {
    return op == @intFromEnum(Enum.CREATE) or op == @intFromEnum(Enum.CREATE2);
}

/// Checks if an opcode can modify blockchain state.
///
/// State-modifying operations are restricted in static calls and
/// require special handling for gas accounting and rollback.
///
/// ## Parameters
/// - `op`: The opcode byte to check
///
/// ## Returns
/// - `true` for operations that modify storage, create contracts, or emit logs
/// - `false` for read-only operations
///
/// ## State-Modifying Opcodes
/// - SSTORE: Modifies contract storage
/// - CREATE/CREATE2: Deploys new contracts
/// - SELFDESTRUCT: Destroys contract and transfers balance
/// - LOG0-LOG4: Emits events (modifies receipts)
///
/// ## Note
/// CALL can also modify state indirectly if it transfers value,
/// but this function only checks direct state modifications.
///
/// ## Static Call Protection
/// These operations will fail with an error if executed within
/// a STATICCALL context.
pub fn modifies_state(op: u8) bool {
    return op == @intFromEnum(Enum.SSTORE) or op == @intFromEnum(Enum.CREATE) or
        op == @intFromEnum(Enum.CREATE2) or op == @intFromEnum(Enum.SELFDESTRUCT) or
        op == @intFromEnum(Enum.LOG0) or op == @intFromEnum(Enum.LOG1) or
        op == @intFromEnum(Enum.LOG2) or op == @intFromEnum(Enum.LOG3) or
        op == @intFromEnum(Enum.LOG4);
}

/// Check if an opcode is valid
pub fn is_valid(op: u8) bool {
    return op != @intFromEnum(Enum.INVALID);
}

// ============================================================================
// Contract Size and Gas Constants
// ============================================================================

/// Maximum allowed size for deployed contract bytecode.
///
/// ## Value
/// 24,576 bytes (24 KB)
///
/// ## Origin
/// Defined by EIP-170 (activated in Spurious Dragon hardfork)
///
/// ## Rationale
/// - Prevents excessive blockchain growth from large contracts
/// - Ensures contracts can be loaded into memory efficiently
/// - Encourages modular contract design
///
/// ## Implications
/// - Contract creation fails if initcode returns bytecode larger than this
/// - Does NOT limit initcode size (see EIP-3860 for that)
/// - Libraries and proxy patterns help work around this limit
///
/// Reference: https://eips.ethereum.org/EIPS/eip-170
pub const MAX_CODE_SIZE: u32 = evm_limits.MAX_CODE_SIZE;

/// Gas cost per byte of deployed contract code.
///
/// ## Value
/// 200 gas per byte
///
/// ## Usage
/// Charged during contract creation (CREATE/CREATE2) based on the
/// size of the returned bytecode that will be stored on-chain.
///
/// ## Calculation
/// `deployment_gas_cost = len(returned_code) * 200`
///
/// ## Example
/// A 1000-byte contract costs an additional 200,000 gas to deploy
/// beyond the execution costs.
///
/// ## Note
/// This is separate from the initcode gas cost introduced in EIP-3860.
pub const DEPLOY_CODE_GAS_PER_BYTE: u64 = evm_limits.DEPLOY_CODE_GAS_PER_BYTE;
