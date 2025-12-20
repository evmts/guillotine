// ABI encoding and decoding functionality
// Re-exports from the ABI module

pub const mod = @import("abi_encoding.zig");

// Re-export main types and functions
pub const AbiType = mod.AbiType;
pub const AbiValue = mod.AbiValue;
pub const AbiError = mod.AbiError;
pub const Selector = mod.Selector;
pub const Address = mod.Address;
pub const Hash = mod.Hash;
pub const FunctionDefinition = mod.FunctionDefinition;
pub const StateMutability = mod.StateMutability;
pub const CommonSelectors = mod.CommonSelectors;
pub const CommonPatterns = mod.CommonPatterns;

// Helper functions
pub const uint256Value = mod.uint256Value;
pub const boolValue = mod.boolValue;
pub const addressValue = mod.addressValue;
pub const stringValue = mod.stringValue;
pub const bytesValue = mod.bytesValue;

// Core encoding functions
pub const encodeAbiParameters = mod.encodeAbiParameters;
pub const encodeFunctionData = mod.encodeFunctionData;
pub const encodeEventTopics = mod.encodeEventTopics;
pub const encodePacked = mod.encodePacked;

// Core decoding functions
pub const decodeAbiParameters = mod.decodeAbiParameters;
pub const decodeFunctionData = mod.decodeFunctionData;

// Utility functions
pub const computeSelector = mod.computeSelector;
pub const createFunctionSignature = mod.createFunctionSignature;
pub const estimateGasForData = mod.estimateGasForData;
