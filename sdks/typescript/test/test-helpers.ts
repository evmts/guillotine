import { Address } from "../src/primitives/address.js";
import { U256 } from "../src/primitives/u256.js";
import { Bytes } from "../src/primitives/bytes.js";
import {
	type GuillotineEvm,
	CallType,
	type ExecutionParams,
	type BlockInfo,
} from "../src/evm/evm.js";
import type { ExecutionResult } from "../src/evm/execution-result.js";

// Re-export test assertions for convenience
export * from "./test-assertions.js";

/**
 * Test helper utilities for Evm testing
 */

/**
 * Create a test address from a number
 */
export function testAddress(n: number): Address {
	const bytes = new Uint8Array(20);
	bytes[19] = n;
	return Address.fromBytes(bytes);
}

/**
 * Create test bytecode that returns a value
 */
export function returnBytecode(value: number): Bytes {
	// PUSH1 value PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
	const code = new Uint8Array([
		0x60,
		value, // PUSH1 value
		0x60,
		0x00, // PUSH1 0
		0x52, // MSTORE
		0x60,
		0x20, // PUSH1 32
		0x60,
		0x00, // PUSH1 0
		0xf3, // RETURN
	]);
	return Bytes.fromBytes(code);
}

/**
 * Create test bytecode that adds two numbers
 */
export function addBytecode(): Bytes {
	// PUSH1 2 PUSH1 3 ADD PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
	const code = new Uint8Array([
		0x60,
		0x02, // PUSH1 2
		0x60,
		0x03, // PUSH1 3
		0x01, // ADD
		0x60,
		0x00, // PUSH1 0
		0x52, // MSTORE
		0x60,
		0x20, // PUSH1 32
		0x60,
		0x00, // PUSH1 0
		0xf3, // RETURN
	]);
	return Bytes.fromBytes(code);
}

/**
 * Create test bytecode that stores a value
 */
export function storeBytecode(slot: number, value: number): Bytes {
	// PUSH1 value PUSH1 slot SSTORE
	const code = new Uint8Array([
		0x60,
		value, // PUSH1 value
		0x60,
		slot, // PUSH1 slot
		0x55, // SSTORE
	]);
	return Bytes.fromBytes(code);
}

/**
 * Create test bytecode that emits a log
 */
export function logBytecode(numTopics: number = 1): Bytes {
	const code: number[] = [];

	// Push log data
	code.push(0x60, 0xab); // PUSH1 0xAB (data)
	code.push(0x60, 0x00); // PUSH1 0 (memory offset)
	code.push(0x52); // MSTORE

	// Push topics
	for (let i = 0; i < numTopics; i++) {
		code.push(0x60, 0x10 + i); // PUSH1 topic_value
	}

	// Push data length and offset
	code.push(0x60, 0x20); // PUSH1 32 (data length)
	code.push(0x60, 0x00); // PUSH1 0 (data offset)

	// LOG opcode
	code.push(0xa0 + numTopics); // LOG0, LOG1, LOG2, LOG3, or LOG4

	return Bytes.fromBytes(new Uint8Array(code));
}

/**
 * Create test bytecode that reverts with a message
 */
export function revertBytecode(): Bytes {
	// Store "FAIL" in memory and revert
	const code = new Uint8Array([
		0x60,
		0x04, // PUSH1 4 (length)
		0x60,
		0x00, // PUSH1 0 (offset)
		0xfd, // REVERT
	]);
	return Bytes.fromBytes(code);
}

/**
 * Create test bytecode that self-destructs
 */
export function selfDestructBytecode(beneficiary: Address): Bytes {
	const beneficiaryBytes = beneficiary.toBytes();
	const code: number[] = [];

	// PUSH20 beneficiary address
	code.push(0x73); // PUSH20
	code.push(...beneficiaryBytes);
	code.push(0xff); // SELFDESTRUCT

	return Bytes.fromBytes(new Uint8Array(code));
}

/**
 * Create test bytecode that deploys a contract (CREATE)
 */
export function createBytecode(initCode: Bytes): Bytes {
	const initBytes = initCode.toBytes();
	const code: number[] = [];

	// Store init code in memory
	for (let i = 0; i < initBytes.length; i++) {
		code.push(0x60, initBytes[i] ?? 0); // PUSH1 byte
		code.push(0x60, i); // PUSH1 offset
		code.push(0x53); // MSTORE8
	}

	// CREATE: value, size, offset
	code.push(0x60, initBytes.length); // PUSH1 size
	code.push(0x60, 0x00); // PUSH1 offset
	code.push(0x60, 0x00); // PUSH1 value
	code.push(0xf0); // CREATE

	// Return created address
	code.push(0x60, 0x00); // PUSH1 0
	code.push(0x52); // MSTORE
	code.push(0x60, 0x20); // PUSH1 32
	code.push(0x60, 0x00); // PUSH1 0
	code.push(0xf3); // RETURN

	return Bytes.fromBytes(new Uint8Array(code));
}

/**
 * Create a default test block info
 */
export function defaultBlockInfo(): BlockInfo {
	return {
		number: 1000n,
		timestamp: 1234567890n,
		gasLimit: 30000000n,
		coinbase: testAddress(999),
		baseFee: 1000000000n,
		chainId: 1n,
		difficulty: 0n,
		prevRandao: Bytes.fromHex("0x" + "42".repeat(32)),
	};
}

/**
 * Create default execution parameters
 */
export function defaultExecutionParams(
	overrides?: Partial<ExecutionParams>,
): ExecutionParams {
	return {
		caller: testAddress(1),
		to: testAddress(2),
		value: U256.zero(),
		input: Bytes.empty(),
		gas: 1000000n,
		callType: CallType.CALL,
		...overrides,
	};
}

/**
 * Deploy a contract and return its address
 */
export async function deployContract(
	evm: GuillotineEvm,
	code: Bytes,
	deployer: Address = testAddress(1),
): Promise<Address> {
	// Simple init code that returns the runtime code
	const initCode = Bytes.concat([
		hex("0x60"), // PUSH1
		Bytes.fromBytes(new Uint8Array([code.length()])),
		hex("0x6000"), // PUSH1 0
		hex("0xf3"), // RETURN
	]);

	const result = await evm.call({
		caller: deployer,
		to: Address.zero(),
		value: U256.zero(),
		input: initCode,
		gas: 1000000n,
		callType: CallType.CREATE,
	});

	if (!result.success || !result.createdAddress) {
		throw new Error("Contract deployment failed");
	}

	return result.createdAddress;
}

/**
 * Assert execution was successful
 */
export function assertSuccess(result: ExecutionResult, message?: string): void {
	if (!result.success) {
		throw new Error(
			message ?? `Execution failed: ${result.errorMessage ?? "Unknown error"}`,
		);
	}
}

/**
 * Assert execution failed
 */
export function assertFailure(result: ExecutionResult, message?: string): void {
	if (result.success) {
		throw new Error(message ?? "Expected execution to fail but it succeeded");
	}
}

/**
 * Convert hex string to Bytes
 */
export function hex(str: string): Bytes {
	return Bytes.fromHex(str.startsWith("0x") ? str : "0x" + str);
}

/**
 * Create infinite loop bytecode for gas testing
 */
export function infiniteLoopBytecode(): Bytes {
	// JUMPDEST PUSH1 0 JUMP
	const code = new Uint8Array([
		0x5b, // JUMPDEST
		0x60,
		0x00, // PUSH1 0
		0x56, // JUMP
	]);
	return Bytes.fromBytes(code);
}

/**
 * Create bytecode that calls another contract
 */
export function callBytecode(
	target: Address,
	value: U256 = U256.zero(),
	callType: "CALL" | "DELEGATECALL" | "STATICCALL" = "CALL",
): Bytes {
	const targetBytes = target.toBytes();
	const valueBytes = value.toBytes();
	const code: number[] = [];

	// Arguments for CALL: gas, addr, value, argsOffset, argsSize, retOffset, retSize
	code.push(0x60, 0x20); // PUSH1 32 (retSize)
	code.push(0x60, 0x00); // PUSH1 0 (retOffset)
	code.push(0x60, 0x00); // PUSH1 0 (argsSize)
	code.push(0x60, 0x00); // PUSH1 0 (argsOffset)

	if (callType !== "DELEGATECALL" && callType !== "STATICCALL") {
		// Push value for CALL
		if (valueBytes.every((b) => b === 0)) {
			code.push(0x60, 0x00); // PUSH1 0
		} else {
			code.push(0x7f); // PUSH32
			code.push(...valueBytes);
		}
	}

	// Push address
	code.push(0x73); // PUSH20
	code.push(...targetBytes);

	// Push gas
	code.push(0x5a); // GAS

	// Call opcode
	if (callType === "CALL") {
		code.push(0xf1); // CALL
	} else if (callType === "DELEGATECALL") {
		code.push(0xf4); // DELEGATECALL
	} else if (callType === "STATICCALL") {
		code.push(0xfa); // STATICCALL
	}

	// Return the result
	code.push(0x60, 0x20); // PUSH1 32
	code.push(0x60, 0x00); // PUSH1 0
	code.push(0xf3); // RETURN

	return Bytes.fromBytes(new Uint8Array(code));
}
