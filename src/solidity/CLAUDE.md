# CLAUDE.md - Solidity Module

## MISSION CRITICAL: Solidity Integration and ABI Handling
**ABI encoding/decoding errors cause incorrect contract interactions and fund loss.**

## ABI Handling
- **Function Selectors**: 4-byte keccak256 hash of function signature
- **Parameter Encoding**: Solidity ABI encoding specification
- **Event Log Decoding**: Parse contract events from transaction logs
- **Error Handling**: Decode revert reasons and custom errors
- **Type Mapping**: Convert between Solidity and EVM types

## Key Responsibilities
- **Contract Compilation**: Interface with Solidity compiler
- **ABI Generation**: Generate interface definitions from source
- **Bytecode Analysis**: Analyze Solidity compiler output
- **Debug Information**: Map EVM execution to Solidity source
- **Type Safety**: Ensure type-safe contract interactions

## Critical ABI Operations
```zig
// Function call encoding
pub fn encode_function_call(function_signature: []const u8, params: []const AbiValue) ![]u8 {
    const selector = keccak256(function_signature)[0..4];
    const encoded_params = try abi.encode(params);
    var result = try allocator.alloc(u8, 4 + encoded_params.len);
    @memcpy(result[0..4], selector);
    @memcpy(result[4..], encoded_params);
    return result;
}

// Event log decoding
pub fn decode_event_log(log: *const EventLog, event_abi: *const EventAbi) !DecodedEvent {
    const signature_hash = log.topics[0];
    if (!std.mem.eql(u8, &signature_hash, &event_abi.signature_hash)) {
        return AbiError.SignatureMismatch;
    }
    return abi.decode_event(log.data, log.topics[1..], event_abi);
}
```

## Compatibility & Types
- **Solidity Versions**: Detect version from metadata, handle ABI format evolution
- **Type System**: Elementary (uint, int, bool, address, bytes), complex (arrays, structs), dynamic (string, bytes, arrays)
- **Storage Layout**: Mappings, packed structs, inheritance patterns

## Critical Safety
- Validate all ABI data before decoding
- Handle malformed/truncated data gracefully
- Ensure type safety in conversions
- Validate function signatures match interfaces
- Prevent buffer overflows in encoding/decoding

## Debug Integration
- **Source Mapping**: Map EVM PC to Solidity source lines
- **Variable Inspection**: Access variable values during execution
- **Call Stack**: Solidity-level call stack information
- **Coverage Analysis**: Track code coverage

## Performance & Testing
- Cache compiled artifacts, optimize common types, precompile signatures
- Test all Solidity versions, ABI round trips, edge cases, official spec compliance
- Fuzz test malformed ABI data

## Emergency Procedures
- Handle compiler bugs/workarounds
- Detect ABI compatibility issues
- Fallback for unsupported features
- Safe degradation for corrupted metadata

**ABI compatibility affects all contract interactions. Errors break calls/events/debug info.**