/**
 * WASM bindings for Ethereum primitives
 * Uses WebAssembly bindings to Zig implementation for browser compatibility
 */

// Address operations
import { Address as AddressClass } from "./address.wasm.js";

// Keccak-256 hashing
import { Hash as HashClass, keccak256 as keccak256Fn, eip191HashMessage as eip191HashMessageFn } from "./keccak.wasm.js";

// Bytecode operations
import {
	type JumpDestination,
	analyzeJumpDestinations as analyzeJumpDestinationsFn,
	isBytecodeBoundary as isBytecodeBoundaryFn,
	isValidJumpDest as isValidJumpDestFn,
	validateBytecode as validateBytecodeFn,
} from "./bytecode.wasm.js";

// Hash algorithms
import {
	sha256 as sha256Fn,
	ripemd160 as ripemd160Fn,
	blake2b as blake2bFn,
	solidityKeccak256 as solidityKeccak256Fn,
	soliditySha256 as soliditySha256Fn,
} from "./hash.wasm.js";

// Hex utilities
import { hexToBytes as hexToBytesFn, bytesToHex as bytesToHexFn } from "./hex.wasm.js";

// RLP encoding
import {
	encodeBytes as rlpEncodeBytesFn,
	encodeUint as rlpEncodeUintFn,
	encodeUintFromBigInt as rlpEncodeUintFromBigIntFn,
	toHex as rlpToHexFn,
	fromHex as rlpFromHexFn,
} from "./rlp.wasm.js";

// Signature operations (secp256k1)
import {
	type ParsedSignature,
	secp256k1RecoverPubkey as secp256k1RecoverPubkeyFn,
	secp256k1RecoverAddress as secp256k1RecoverAddressFn,
	secp256k1PubkeyFromPrivate as secp256k1PubkeyFromPrivateFn,
	secp256k1ValidateSignature as secp256k1ValidateSignatureFn,
	signatureNormalize as signatureNormalizeFn,
	signatureIsCanonical as signatureIsCanonicalFn,
	signatureParse as signatureParseFn,
	signatureSerialize as signatureSerializeFn,
} from "./signature.wasm.js";

// Transaction operations
import {
	TransactionType as TransactionTypeEnum,
	detectTransactionType as detectTransactionTypeFn,
} from "./transaction.wasm.js";

// U256 operations
import {
	u256FromHex as u256FromHexFn,
	u256ToHex as u256ToHexFn,
	u256FromBigInt as u256FromBigIntFn,
	u256ToBigInt as u256ToBigIntFn,
} from "./uint256.wasm.js";

// Wallet key generation
import { generatePrivateKey as generatePrivateKeyFn, compressPublicKey as compressPublicKeyFn } from "./wallet.wasm.js";

// Re-export all with original names
export { AddressClass as Address };
export { HashClass as Hash, keccak256Fn as keccak256, eip191HashMessageFn as eip191HashMessage };
export { type JumpDestination, analyzeJumpDestinationsFn as analyzeJumpDestinations, isBytecodeBoundaryFn as isBytecodeBoundary, isValidJumpDestFn as isValidJumpDest, validateBytecodeFn as validateBytecode };
export { sha256Fn as sha256, ripemd160Fn as ripemd160, blake2bFn as blake2b, solidityKeccak256Fn as solidityKeccak256, soliditySha256Fn as soliditySha256 };
export { hexToBytesFn as hexToBytes, bytesToHexFn as bytesToHex };
export { rlpEncodeBytesFn as rlpEncodeBytes, rlpEncodeUintFn as rlpEncodeUint, rlpEncodeUintFromBigIntFn as rlpEncodeUintFromBigInt, rlpToHexFn as rlpToHex, rlpFromHexFn as rlpFromHex };
export { type ParsedSignature, secp256k1RecoverPubkeyFn as secp256k1RecoverPubkey, secp256k1RecoverAddressFn as secp256k1RecoverAddress, secp256k1PubkeyFromPrivateFn as secp256k1PubkeyFromPrivate, secp256k1ValidateSignatureFn as secp256k1ValidateSignature, signatureNormalizeFn as signatureNormalize, signatureIsCanonicalFn as signatureIsCanonical, signatureParseFn as signatureParse, signatureSerializeFn as signatureSerialize };
export { TransactionTypeEnum as TransactionType, detectTransactionTypeFn as detectTransactionType };
export { u256FromHexFn as u256FromHex, u256ToHexFn as u256ToHex, u256FromBigIntFn as u256FromBigInt, u256ToBigIntFn as u256ToBigInt };
export { generatePrivateKeyFn as generatePrivateKey, compressPublicKeyFn as compressPublicKey };

// Re-export everything as default
export default {
	Address: AddressClass,
	Hash: HashClass,
	keccak256: keccak256Fn,
	eip191HashMessage: eip191HashMessageFn,
	analyzeJumpDestinations: analyzeJumpDestinationsFn,
	isBytecodeBoundary: isBytecodeBoundaryFn,
	isValidJumpDest: isValidJumpDestFn,
	validateBytecode: validateBytecodeFn,
	sha256: sha256Fn,
	ripemd160: ripemd160Fn,
	blake2b: blake2bFn,
	solidityKeccak256: solidityKeccak256Fn,
	soliditySha256: soliditySha256Fn,
	hexToBytes: hexToBytesFn,
	bytesToHex: bytesToHexFn,
	rlpEncodeBytes: rlpEncodeBytesFn,
	rlpEncodeUint: rlpEncodeUintFn,
	rlpEncodeUintFromBigInt: rlpEncodeUintFromBigIntFn,
	rlpToHex: rlpToHexFn,
	rlpFromHex: rlpFromHexFn,
	secp256k1RecoverPubkey: secp256k1RecoverPubkeyFn,
	secp256k1RecoverAddress: secp256k1RecoverAddressFn,
	secp256k1PubkeyFromPrivate: secp256k1PubkeyFromPrivateFn,
	secp256k1ValidateSignature: secp256k1ValidateSignatureFn,
	signatureNormalize: signatureNormalizeFn,
	signatureIsCanonical: signatureIsCanonicalFn,
	signatureParse: signatureParseFn,
	signatureSerialize: signatureSerializeFn,
	TransactionType: TransactionTypeEnum,
	detectTransactionType: detectTransactionTypeFn,
	u256FromHex: u256FromHexFn,
	u256ToHex: u256ToHexFn,
	u256FromBigInt: u256FromBigIntFn,
	u256ToBigInt: u256ToBigIntFn,
	generatePrivateKey: generatePrivateKeyFn,
	compressPublicKey: compressPublicKeyFn,
};
