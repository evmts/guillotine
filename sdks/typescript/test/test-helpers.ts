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
 * Create a test address from a number: n as a big-endian u32 in the last 4 bytes.
 */
export function testAddress(n: number): Address {
	if (!Number.isInteger(n) || n < 0 || n > 0xffffffff) {
		throw new Error(`testAddress expects a u32, got ${n}`);
	}
	const bytes = new Uint8Array(20);
	new DataView(bytes.buffer).setUint32(16, n);
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
	const initCode = deployInitCode(code);

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
 * Create bytecode that calls another contract and returns
 * `success (32-byte word) || returndata`.
 *
 * The CALL itself copies up to 256 bytes of return data to memory[32..288]; the contract then
 * returns memory[0 .. 32 + RETURNDATASIZE]. Return data longer than 256 bytes is not supported.
 *
 * Forwarded gas comes from the GAS opcode unless `gas` is given.
 */
export function callBytecode(
	target: Address,
	value: U256 = U256.zero(),
	callType: "CALL" | "CALLCODE" | "DELEGATECALL" | "STATICCALL" = "CALL",
	gas?: number,
): Bytes {
	const code: number[] = [];

	// CALL/CALLCODE pop: gas, addr, value, argsOffset, argsSize, retOffset, retSize
	// DELEGATECALL/STATICCALL pop: gas, addr, argsOffset, argsSize, retOffset, retSize
	code.push(0x61, 0x01, 0x00); // PUSH2 256 (retSize)
	code.push(0x60, 0x20); // PUSH1 32 (retOffset)
	code.push(0x60, 0x00); // PUSH1 0 (argsSize)
	code.push(0x60, 0x00); // PUSH1 0 (argsOffset)

	if (callType === "CALL" || callType === "CALLCODE") {
		code.push(0x7f, ...value.toBytes()); // PUSH32 value
	}

	code.push(0x73, ...target.toBytes()); // PUSH20 target

	if (gas === undefined) {
		code.push(0x5a); // GAS
	} else {
		if (!Number.isInteger(gas) || gas < 0 || gas > 0xffffffff) {
			throw new Error(`callBytecode gas must be a u32, got ${gas}`);
		}
		code.push(0x63, (gas >>> 24) & 0xff, (gas >>> 16) & 0xff, (gas >>> 8) & 0xff, gas & 0xff); // PUSH4 gas
	}

	const opcodes = { CALL: 0xf1, CALLCODE: 0xf2, DELEGATECALL: 0xf4, STATICCALL: 0xfa } as const;
	code.push(opcodes[callType]);

	code.push(0x60, 0x00); // PUSH1 0
	code.push(0x52); // MSTORE (success flag at memory[0..32])
	code.push(0x3d); // RETURNDATASIZE
	code.push(0x60, 0x20); // PUSH1 32
	code.push(0x01); // ADD (size = 32 + returndata size)
	code.push(0x60, 0x00); // PUSH1 0 (offset)
	code.push(0xf3); // RETURN

	return Bytes.fromBytes(new Uint8Array(code));
}

/**
 * Init code that copies `runtime` out of itself and returns it, so CREATE deploys exactly `runtime`.
 * `prefix` runs first (it must leave the stack empty and not touch memory it relies on).
 */
export function deployInitCode(runtime: Bytes, prefix: Bytes = Bytes.empty()): Bytes {
	const length = runtime.length();
	if (length > 0xffff) throw new Error(`runtime code too long: ${length}`);
	// PUSH2 len DUP1 PUSH2 start PUSH1 0 CODECOPY PUSH1 0 RETURN = 13 bytes
	const start = prefix.length() + 13;
	const copier = new Uint8Array([
		0x61, length >> 8, length & 0xff, // PUSH2 len (size)
		0x80, // DUP1 (kept for RETURN)
		0x61, start >> 8, start & 0xff, // PUSH2 start (code offset)
		0x60, 0x00, // PUSH1 0 (memory offset)
		0x39, // CODECOPY
		0x60, 0x00, // PUSH1 0 (offset)
		0xf3, // RETURN (offset 0, size len)
	]);
	return Bytes.concat([prefix, Bytes.fromBytes(copier), runtime]);
}
