import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { GuillotineEvm } from "./evm.js";
import { U256 } from "../primitives/u256.js";
import { Bytes } from "../primitives/bytes.js";
import {
	testAddress,
	defaultExecutionParams,
	logBytecode,
	returnBytecode,
	hex,
	assertSuccess,
} from "../../test/test-helpers.js";
import { first, getElement } from "../../test/test-assertions.js";

describe("GuillotineEvm - Logs and Events", () => {
	let evm: GuillotineEvm;

	beforeEach(async () => {
		evm = await GuillotineEvm.create();
	});

	afterEach(() => {
		evm.close();
	});

	describe("Basic Logging", () => {
		it("should emit LOG0 with no topics", async () => {
			const contractAddr = testAddress(100);
			const code = logBytecode(0); // LOG0

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);
			expect(result.logs).toHaveLength(1);

			const log = first(result.logs, "log");
			expect(log.address.toHex()).toBe(contractAddr.toHex());
			expect(log.topics).toHaveLength(0);
			expect(log.data.toBytes()[31]).toBe(0xab); // Our test data (raw bytes from Evm memory)
		});

		it("should emit LOG1 with one topic", async () => {
			const contractAddr = testAddress(101);
			const code = logBytecode(1); // LOG1

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);
			expect(result.logs).toHaveLength(1);

			const log = first(result.logs, "log");
			expect(log.address.toHex()).toBe(contractAddr.toHex());
			expect(log.topics).toHaveLength(1);
			const topic0 = first(log.topics, "topic");
			expect(topic0.toBytes()[31]).toBe(0x10); // Topic value (U256 big-endian)
			expect(log.data.toBytes()[31]).toBe(0xab); // Log data (raw Evm memory)
		});

		it("should emit LOG2 with two topics", async () => {
			const contractAddr = testAddress(102);
			const code = logBytecode(2); // LOG2

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);
			expect(result.logs).toHaveLength(1);

			const log = first(result.logs, "log");
			expect(log.topics).toHaveLength(2);
			expect(getElement(log.topics, 0, "topic").toBytes()[31]).toBe(0x11); // Stack LIFO: last pushed (0x11) is first topic  
			expect(getElement(log.topics, 1, "topic").toBytes()[31]).toBe(0x10);
		});

		it("should emit LOG3 with three topics", async () => {
			const contractAddr = testAddress(103);
			const code = logBytecode(3); // LOG3

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);
			expect(result.logs).toHaveLength(1);

			const log = first(result.logs, "log");
			expect(log.topics).toHaveLength(3);
			expect(getElement(log.topics, 0, "topic").toBytes()[31]).toBe(0x12); // Stack LIFO: [0x12, 0x11, 0x10]
			expect(getElement(log.topics, 1, "topic").toBytes()[31]).toBe(0x11);
			expect(getElement(log.topics, 2, "topic").toBytes()[31]).toBe(0x10);
		});

		it("should emit LOG4 with four topics", async () => {
			const contractAddr = testAddress(104);
			const code = logBytecode(4); // LOG4

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);
			expect(result.logs).toHaveLength(1);

			const log = first(result.logs, "log");
			expect(log.topics).toHaveLength(4);
			expect(getElement(log.topics, 0, "topic").toBytes()[31]).toBe(0x13); // Stack LIFO: [0x13, 0x12, 0x11, 0x10]
			expect(getElement(log.topics, 1, "topic").toBytes()[31]).toBe(0x12);
			expect(getElement(log.topics, 2, "topic").toBytes()[31]).toBe(0x11);
			expect(getElement(log.topics, 3, "topic").toBytes()[31]).toBe(0x10);
		});
	});

	describe("Multiple Logs", () => {
		it("should emit multiple logs in order", async () => {
			const contractAddr = testAddress(200);

			// Emit 3 different logs
			const code = Bytes.concat([
				logBytecode(0), // LOG0
				logBytecode(1), // LOG1
				logBytecode(2), // LOG2
			]);

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);
			expect(result.logs).toHaveLength(3);

			// Verify each log
			expect(getElement(result.logs, 0, "log").topics).toHaveLength(0);
			expect(getElement(result.logs, 1, "log").topics).toHaveLength(1);
			expect(getElement(result.logs, 2, "log").topics).toHaveLength(2);

			// All from same address
			result.logs.forEach((log) => {
				expect(log.address.toHex()).toBe(contractAddr.toHex());
			});
		});

		it("should handle large number of logs", async () => {
			const contractAddr = testAddress(201);

			// Create bytecode that emits 10 logs
			const codes: Bytes[] = [];
			for (let i = 0; i < 10; i++) {
				codes.push(logBytecode(i % 5)); // Cycle through LOG0-LOG4
			}
			const code = Bytes.concat(codes);

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
					gas: 1000000n, // Enough gas for many logs
				}),
			);

			assertSuccess(result);
			expect(result.logs).toHaveLength(10);

			// Verify topic counts
			for (let i = 0; i < 10; i++) {
				const log = getElement(result.logs, i, "log");
				expect(log.topics).toHaveLength(i % 5);
			}
		});
	});

	describe("Log Data", () => {
		it("should emit log with empty data", async () => {
			const contractAddr = testAddress(300);

			// LOG0 with no data: PUSH1 0 PUSH1 0 LOG0
			const code = hex("0x60006000a0");

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);
			expect(result.logs).toHaveLength(1);
			expect(first(result.logs, "log").data.isEmpty()).toBe(true);
		});

		it("should emit log with large data", async () => {
			const contractAddr = testAddress(301);

			// Store 256 bytes of data and emit it
			const code: number[] = [];

			// Fill memory with pattern
			for (let i = 0; i < 256; i++) {
				code.push(0x60, i % 256); // PUSH1 value
				code.push(0x61, i >> 8, i & 0xff); // PUSH2 offset
				code.push(0x53); // MSTORE8
			}

			// LOG0 with 256 bytes
			code.push(0x61, 0x01, 0x00); // PUSH2 256 (size)
			code.push(0x60, 0x00); // PUSH1 0 (offset)
			code.push(0xa0); // LOG0

			await evm.setCode(contractAddr, Bytes.fromBytes(new Uint8Array(code)));

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
					gas: 1000000n,
				}),
			);

			assertSuccess(result);
			expect(result.logs).toHaveLength(1);
			const log = first(result.logs, "log");
			expect(log.data.length()).toBe(256);

			// Verify pattern
			const data = log.data.toBytes();
			for (let i = 0; i < 256; i++) {
				expect(data[i]).toBe(i % 256);
			}
		});

		// TODO: Fix RuntimeError in log data handling in Zig implementation
		it.todo("should emit log with specific data patterns", async () => {
			const contractAddr = testAddress(302);

			// Store specific pattern: 0xDEADBEEF
			// PUSH4 0xDEADBEEF PUSH1 0 MSTORE PUSH1 4 PUSH1 28 LOG0
			const code = hex("0x63deadbeef60005260046001ca0");

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);
			expect(result.logs).toHaveLength(1);

			const data = first(result.logs, "log").data.toBytes();
			expect(data).toEqual(new Uint8Array([0xde, 0xad, 0xbe, 0xef]));
		});
	});

	describe("Complex Topics", () => {
		it("should emit log with hash topics", async () => {
			const contractAddr = testAddress(400);

			// Common pattern: event signature as topic[0]
			// Transfer(address,address,uint256) signature
			const signature =
				"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";

			const code: number[] = [];

			// Store some data
			code.push(0x60, 0x10); // PUSH1 16 (amount)
			code.push(0x60, 0x00); // PUSH1 0
			code.push(0x52); // MSTORE

			// Push topics (in reverse order for stack)
			// Topic 2: amount
			code.push(0x60, 0x10); // PUSH1 16

			// Topic 1: to address
			code.push(0x73); // PUSH20
			for (let i = 0; i < 20; i++) {
				code.push(0x22); // Example address bytes
			}

			// Topic 0: event signature (would be keccak256 hash in practice)
			code.push(0x7f); // PUSH32
			const sigBytes = hex(signature).toBytes();
			code.push(...sigBytes);

			// Emit LOG3
			code.push(0x60, 0x20); // PUSH1 32 (data size)
			code.push(0x60, 0x00); // PUSH1 0 (data offset)
			code.push(0xa3); // LOG3

			await evm.setCode(contractAddr, Bytes.fromBytes(new Uint8Array(code)));

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);
			expect(result.logs).toHaveLength(1);
			const log = first(result.logs, "log");
			expect(log.topics).toHaveLength(3);

			// First topic should be the signature
			const topic0 = first(log.topics, "topic");
			expect(topic0.toHex()).toBe(signature);
		});

		it("should handle indexed parameters as topics", async () => {
			const contractAddr = testAddress(401);

			// Simulate: event Approval(address indexed owner, address indexed spender, uint256 value)
			// Topics: [signature, owner, spender], Data: [value]

			const owner = testAddress(10);
			const spender = testAddress(20);
			const value = U256.fromBigInt(1000n);

			const code: number[] = [];

			// Store value in memory for data
			const valueBytes = value.toBytes();
			for (let i = 0; i < 32; i++) {
				code.push(0x60, valueBytes[i] ?? 0); // PUSH1 byte
				code.push(0x60, i); // PUSH1 offset
				code.push(0x53); // MSTORE8
			}

			// Push topics (reverse order)
			// Topic 2: spender
			code.push(0x73); // PUSH20
			code.push(...spender.toBytes());

			// Topic 1: owner
			code.push(0x73); // PUSH20
			code.push(...owner.toBytes());

			// Topic 0: signature (mock)
			code.push(0x60, 0xaa); // PUSH1 0xAA (simplified)

			// LOG3
			code.push(0x60, 0x20); // PUSH1 32 (data size)
			code.push(0x60, 0x00); // PUSH1 0 (data offset)
			code.push(0xa3); // LOG3

			await evm.setCode(contractAddr, Bytes.fromBytes(new Uint8Array(code)));

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);
			expect(result.logs).toHaveLength(1);

			const log = first(result.logs, "log");
			expect(log.topics).toHaveLength(3);

			// Verify indexed addresses are in topics
			const ownerTopic = getElement(log.topics, 1, "owner topic").toBytes();
			const spenderTopic = getElement(log.topics, 2, "spender topic").toBytes();

			// Topics contain addresses as U256 values, compare the U256 representations
			const ownerU256 = U256.fromBytes(owner.toBytes()); // Address to U256
			const spenderU256 = U256.fromBytes(spender.toBytes()); // Address to U256
			
			expect(Array.from(ownerTopic)).toEqual(Array.from(ownerU256.toBytes()));
			expect(Array.from(spenderTopic)).toEqual(Array.from(spenderU256.toBytes()));

			// Value is in data
			expect(log.data.toBytes()).toEqual(valueBytes);
		});
	});

	describe("Nested Call Logs", () => {
		it("should collect logs from nested calls", async () => {
			const contractA = testAddress(500);
			const contractB = testAddress(501);

			// Contract B emits a log
			await evm.setCode(contractB, logBytecode(1));

			// Contract A calls B then emits its own log
			const codeA = Bytes.concat([
				// Call contract B
				hex("0x6000"), // PUSH1 0 (retSize)
				hex("0x6000"), // PUSH1 0 (retOffset)
				hex("0x6000"), // PUSH1 0 (argsSize)
				hex("0x6000"), // PUSH1 0 (argsOffset)
				hex("0x6000"), // PUSH1 0 (value)
				hex("0x73"), // PUSH20 address
				contractB.toBytes(),
				hex("0x5a"), // GAS
				hex("0xf1"), // CALL
				hex("0x50"), // POP (ignore result)
				// Emit own log
				logBytecode(2),
			]);

			await evm.setCode(contractA, codeA);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			assertSuccess(result);
			expect(result.logs).toHaveLength(2);

			// First log from B, second from A
			const logB = getElement(result.logs, 0, "log from B");
			const logA = getElement(result.logs, 1, "log from A");

			expect(logB.address.toHex()).toBe(contractB.toHex());
			expect(logB.topics).toHaveLength(1);

			expect(logA.address.toHex()).toBe(contractA.toHex());
			expect(logA.topics).toHaveLength(2);
		});

		// TODO: Fix revert not canceling logs in Zig implementation
		it.todo("should not emit logs on revert", async () => {
			const contractAddr = testAddress(502);

			// Emit log then revert
			const code = Bytes.concat([
				logBytecode(1), // LOG1
				hex("0x600060fd"), // PUSH1 0 PUSH1 0 REVERT
			]);

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			// Call should fail
			expect(result.success).toBe(false);

			// Logs should be empty (reverted)
			expect(result.logs).toHaveLength(0);
		});

		// TODO: Fix log persistence on partial revert in Zig implementation
		it.todo("should keep logs from successful calls even if later call fails", async () => {
			const contractA = testAddress(503);
			const contractB = testAddress(504);
			const contractC = testAddress(505);

			// Contract B emits log and succeeds
			await evm.setCode(contractB, logBytecode(1));

			// Contract C reverts
			await evm.setCode(contractC, hex("0x600060fd"));

			// Contract A calls B (success) then C (fails)
			const codeA: number[] = [];

			// Call B
			codeA.push(0x60, 0x00); // retSize
			codeA.push(0x60, 0x00); // retOffset
			codeA.push(0x60, 0x00); // argsSize
			codeA.push(0x60, 0x00); // argsOffset
			codeA.push(0x60, 0x00); // value
			codeA.push(0x73); // PUSH20
			codeA.push(...contractB.toBytes());
			codeA.push(0x5a); // GAS
			codeA.push(0xf1); // CALL
			codeA.push(0x50); // POP

			// Call C (will fail)
			codeA.push(0x60, 0x00); // retSize
			codeA.push(0x60, 0x00); // retOffset
			codeA.push(0x60, 0x00); // argsSize
			codeA.push(0x60, 0x00); // argsOffset
			codeA.push(0x60, 0x00); // value
			codeA.push(0x73); // PUSH20
			codeA.push(...contractC.toBytes());
			codeA.push(0x5a); // GAS
			codeA.push(0xf1); // CALL
			// Check if call failed and revert if it did
			codeA.push(0x15); // ISZERO
			codeA.push(0x60, codeA.length + 4); // PUSH1 jump dest
			codeA.push(0x57); // JUMPI
			codeA.push(0x60, 0x00); // PUSH1 0
			codeA.push(0x60, 0x00); // PUSH1 0
			codeA.push(0xfd); // REVERT
			codeA.push(0x5b); // JUMPDEST

			await evm.setCode(contractA, Bytes.fromBytes(new Uint8Array(codeA)));

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			// The whole transaction should fail
			expect(result.success).toBe(false);

			// No logs should be kept (transaction reverted)
			expect(result.logs).toHaveLength(0);
		});
	});

	describe("Tracing", () => {
		it("should include trace JSON when tracing enabled", async () => {
			const evmWithTrace = await GuillotineEvm.create(undefined, true);

			const contractAddr = testAddress(600);
			const code = logBytecode(1);

			await evmWithTrace.setCode(contractAddr, code);

			const result = await evmWithTrace.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);

			// Should have trace data
			expect(result.traceJson).toBeDefined();
			expect(result.traceJson).not.toBeNull();

			if (result.traceJson) {
				// Parse and verify trace structure
				const trace = JSON.parse(result.traceJson);
				expect(trace).toBeDefined();
				// Trace should contain execution details
				// The exact structure depends on the tracer implementation
			}

			evmWithTrace.close();
		});

		it("should not include trace when tracing disabled", async () => {
			const contractAddr = testAddress(601);
			const code = logBytecode(0);

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);

			// Should not have trace data
			expect(result.traceJson).toBeNull();
		});

		it("should trace nested calls", async () => {
			const evmWithTrace = await GuillotineEvm.create(undefined, true);

			const contractA = testAddress(602);
			const contractB = testAddress(603);

			// Contract B
			await evmWithTrace.setCode(contractB, returnBytecode(42));

			// Contract A calls B
			const codeA = Bytes.concat([
				hex("0x6000"), // retSize
				hex("0x6000"), // retOffset
				hex("0x6000"), // argsSize
				hex("0x6000"), // argsOffset
				hex("0x6000"), // value
				hex("0x73"), // PUSH20
				contractB.toBytes(),
				hex("0x5a"), // GAS
				hex("0xf1"), // CALL
			]);

			await evmWithTrace.setCode(contractA, codeA);

			const result = await evmWithTrace.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			assertSuccess(result);
			expect(result.traceJson).toBeDefined();

			if (result.traceJson) {
				const trace = JSON.parse(result.traceJson);
				// Trace should show the nested call structure
				expect(trace).toBeDefined();
			}

			evmWithTrace.close();
		});
	});

	describe("Log Edge Cases", () => {
		it("should handle maximum topics and data", async () => {
			const contractAddr = testAddress(700);

			const code: number[] = [];

			// Store max data (using 1KB for test)
			for (let i = 0; i < 1024; i++) {
				code.push(0x60, 0xff); // PUSH1 0xFF
				code.push(0x61, i >> 8, i & 0xff); // PUSH2 offset
				code.push(0x53); // MSTORE8
			}

			// Push 4 topics (max)
			for (let i = 0; i < 4; i++) {
				code.push(0x60, 0xf0 + i); // PUSH1 topic
			}

			// LOG4 with 1KB data
			code.push(0x61, 0x04, 0x00); // PUSH2 1024
			code.push(0x60, 0x00); // PUSH1 0
			code.push(0xa4); // LOG4

			await evm.setCode(contractAddr, Bytes.fromBytes(new Uint8Array(code)));

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
					gas: 1000000n,
				}),
			);

			assertSuccess(result);
			expect(result.logs).toHaveLength(1);
			const log = first(result.logs, "log");
			expect(log.topics).toHaveLength(4);
			expect(log.data.length()).toBe(1024);
		});

		it("should handle logs at gas limit", async () => {
			const contractAddr = testAddress(701);

			// Create many logs to consume gas
			const codes: Bytes[] = [];
			for (let i = 0; i < 100; i++) {
				codes.push(logBytecode(0));
			}
			const code = Bytes.concat(codes);

			await evm.setCode(contractAddr, code);

			// Low gas limit
			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
					gas: 50000n,
				}),
			);

			// Should run out of gas
			expect(result.success).toBe(false);
			expect(result.gasLeft).toBe(0n);

			// No logs on failure
			expect(result.logs).toHaveLength(0);
		});

		it("should handle logs with all zero values", async () => {
			const contractAddr = testAddress(702);

			// LOG1 with zero topic and zero data
			// PUSH1 0 PUSH1 0 PUSH1 0 LOG1
			const code = hex("0x600060006000a1");

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);
			expect(result.logs).toHaveLength(1);

			const log = first(result.logs, "log");
			expect(log.topics).toHaveLength(1);
			const topic = first(log.topics, "topic");
			expect(topic.toBigInt()).toBe(0n);
			expect(log.data.isEmpty()).toBe(true);
		});
	});
});
