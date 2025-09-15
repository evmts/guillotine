import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { GuillotineEvm, CallType } from "./evm.js";
import { Address } from "../primitives/address.js";
import { U256 } from "../primitives/u256.js";
import { Bytes } from "../primitives/bytes.js";
import {
	testAddress,
	defaultExecutionParams,
	returnBytecode,
	selfDestructBytecode,
	callBytecode,
	hex,
	assertSuccess,
	assertFailure,
} from "../../test/test-helpers.js";
import { first, getElement } from "../../test/test-assertions.js";

describe("GuillotineEvm - Complex Interactions", () => {
	let evm: GuillotineEvm;

	beforeEach(async () => {
		evm = await GuillotineEvm.create();
	});

	afterEach(() => {
		evm.close();
	});

	describe("Self-Destruct Operations", () => {
		// TODO: Fix SELFDESTRUCT tracking in Zig implementation
		it.todo("should handle SELFDESTRUCT", async () => {
			const contract = testAddress(100);
			const beneficiary = testAddress(101);

			// Fund the contract and beneficiary
			await evm.setBalance(contract, U256.fromBigInt(1000n));
			await evm.setBalance(beneficiary, U256.zero());

			// Set self-destruct code
			const code = selfDestructBytecode(beneficiary);
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertSuccess(result);

			// Check self-destruct record
			expect(result.selfdestructs).toHaveLength(1);
			const record = first(result.selfdestructs, "self-destruct record");
			expect(record.contract.toHex()).toBe(contract.toHex());
			expect(record.beneficiary.toHex()).toBe(beneficiary.toHex());

			// Funds should be transferred to beneficiary
			const beneficiaryBalance = await evm.getBalance(beneficiary);
			expect(beneficiaryBalance.toBigInt()).toBe(1000n);

			// Contract balance should be zero
			const contractBalance = await evm.getBalance(contract);
			expect(contractBalance.toBigInt()).toBe(0n);
		});

		// TODO: Fix SELFDESTRUCT tracking in Zig implementation
		it.todo("should handle SELFDESTRUCT to self", async () => {
			const contract = testAddress(102);

			await evm.setBalance(contract, U256.fromBigInt(500n));
			await evm.setCode(contract, selfDestructBytecode(contract));

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertSuccess(result);

			// Self-destruct to self should burn the funds
			expect(result.selfdestructs).toHaveLength(1);
			const record = first(result.selfdestructs, "self-destruct record");
			expect(record.contract.toHex()).toBe(contract.toHex());
			expect(record.beneficiary.toHex()).toBe(contract.toHex());

			// Balance should be zero (burned)
			const balance = await evm.getBalance(contract);
			expect(balance.toBigInt()).toBe(0n);
		});

		// TODO: Fix SELFDESTRUCT tracking in Zig implementation
		it.todo("should handle multiple SELFDESTRUCT in one transaction", async () => {
			const contractA = testAddress(103);
			const contractB = testAddress(104);
			const beneficiary = testAddress(105);

			// Fund both contracts
			await evm.setBalance(contractA, U256.fromBigInt(300n));
			await evm.setBalance(contractB, U256.fromBigInt(700n));

			// Contract B self-destructs to beneficiary
			await evm.setCode(contractB, selfDestructBytecode(beneficiary));

			// Contract A calls B then self-destructs
			const codeA = Bytes.concat([
				// Call contract B
				hex("0x6000"), // retSize
				hex("0x6000"), // retOffset
				hex("0x6000"), // argsSize
				hex("0x6000"), // argsOffset
				hex("0x6000"), // value
				hex("0x73"), // PUSH20
				contractB.toBytes(),
				hex("0x5a"), // GAS
				hex("0xf1"), // CALL
				hex("0x50"), // POP
				// Self-destruct to beneficiary
				selfDestructBytecode(beneficiary),
			]);

			await evm.setCode(contractA, codeA);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			assertSuccess(result);

			// Should have two self-destruct records
			expect(result.selfdestructs).toHaveLength(2);

			// Beneficiary should receive funds from both
			const beneficiaryBalance = await evm.getBalance(beneficiary);
			expect(beneficiaryBalance.toBigInt()).toBe(1000n); // 300 + 700
		});
	});

	describe("Access Lists", () => {
		// TODO: Fix access list tracking in Zig implementation
		it.todo("should track accessed addresses", async () => {
			const contractA = testAddress(200);
			const contractB = testAddress(201);
			const contractC = testAddress(202);

			// Contract A calls B and checks balance of C
			const codeA: number[] = [];

			// Get balance of C
			codeA.push(0x73); // PUSH20
			codeA.push(...contractC.toBytes());
			codeA.push(0x31); // BALANCE
			codeA.push(0x50); // POP

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

			await evm.setCode(contractA, Bytes.fromBytes(new Uint8Array(codeA)));
			await evm.setCode(contractB, returnBytecode(42));

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			assertSuccess(result);

			// Should track all accessed addresses
			expect(result.accessedAddresses.length).toBeGreaterThanOrEqual(3);

			const accessedHexes = result.accessedAddresses.map((a) => a.toHex());
			expect(accessedHexes).toContain(contractA.toHex());
			expect(accessedHexes).toContain(contractB.toHex());
			expect(accessedHexes).toContain(contractC.toHex());
		});

		// TODO: Fix access list tracking in Zig implementation
		it.todo("should track accessed storage slots", async () => {
			const contract = testAddress(203);

			// Access multiple storage slots
			const code: number[] = [];

			// SLOAD from slot 0
			code.push(0x60, 0x00); // PUSH1 0
			code.push(0x54); // SLOAD
			code.push(0x50); // POP

			// SLOAD from slot 5
			code.push(0x60, 0x05); // PUSH1 5
			code.push(0x54); // SLOAD
			code.push(0x50); // POP

			// SSTORE to slot 10
			code.push(0x60, 0x42); // PUSH1 66
			code.push(0x60, 0x0a); // PUSH1 10
			code.push(0x55); // SSTORE

			await evm.setCode(contract, Bytes.fromBytes(new Uint8Array(code)));

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertSuccess(result);

			// Should track all accessed storage
			expect(result.accessedStorage.length).toBeGreaterThanOrEqual(3);

			const slots = result.accessedStorage.filter(
				(s) => s.address.toHex() === contract.toHex(),
			);

			const slotNumbers = slots.map((s) => s.slot.toBigInt());
			expect(slotNumbers).toContain(0n);
			expect(slotNumbers).toContain(5n);
			expect(slotNumbers).toContain(10n);
		});

		// TODO: Fix access list tracking in Zig implementation
		it.todo("should track warm/cold access patterns", async () => {
			const contract = testAddress(204);

			// Access same slot multiple times
			const code: number[] = [];

			// First SLOAD from slot 0 (cold)
			code.push(0x60, 0x00); // PUSH1 0
			code.push(0x54); // SLOAD
			code.push(0x50); // POP

			// Second SLOAD from slot 0 (warm)
			code.push(0x60, 0x00); // PUSH1 0
			code.push(0x54); // SLOAD
			code.push(0x50); // POP

			// SLOAD from slot 1 (cold)
			code.push(0x60, 0x01); // PUSH1 1
			code.push(0x54); // SLOAD

			// Return the value
			code.push(0x60, 0x00); // PUSH1 0
			code.push(0x52); // MSTORE
			code.push(0x60, 0x20); // PUSH1 32
			code.push(0x60, 0x00); // PUSH1 0
			code.push(0xf3); // RETURN

			await evm.setCode(contract, Bytes.fromBytes(new Uint8Array(code)));

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertSuccess(result);

			// Gas consumption should reflect warm/cold access
			const gasUsed = 1000000n - result.gasLeft;
			expect(gasUsed).toBeGreaterThan(0n);

			// Storage access should be tracked
			const slots = result.accessedStorage.filter(
				(s) => s.address.toHex() === contract.toHex(),
			);
			expect(slots.length).toBeGreaterThanOrEqual(2);
		});
	});

	describe("Complex Call Chains", () => {
		// TODO: Fix deep call stack handling in Zig implementation
		it.todo("should handle deep call stack", async () => {
			const depth = 5;
			const contracts: Address[] = [];

			// Create chain of contracts
			for (let i = 0; i < depth; i++) {
				contracts.push(testAddress(300 + i));
			}

			// Last contract returns a value
			const lastContract = getElement(contracts, depth - 1, "last contract");
			await evm.setCode(lastContract, returnBytecode(99));

			// Each contract calls the next
			for (let i = depth - 2; i >= 0; i--) {
				const currentContract = getElement(contracts, i, "current contract");
				const nextContract = getElement(contracts, i + 1, "next contract");
				await evm.setCode(currentContract, callBytecode(nextContract));
			}

			const firstContract = first(contracts, "contract");
			const result = await evm.call(
				defaultExecutionParams({
					to: firstContract,
				}),
			);

			assertSuccess(result);

			// Should get value from deepest contract
			const output = result.output.toBytes();
			expect(output[31]).toBe(99);

			// All contracts should be in accessed addresses
			const accessedHexes = result.accessedAddresses.map((a) => a.toHex());
			contracts.forEach((contract) => {
				expect(accessedHexes).toContain(contract.toHex());
			});
		});

		// TODO: Fix reentrancy handling in Zig implementation
		it.todo("should handle reentrancy", async () => {
			const contractA = testAddress(310);
			const contractB = testAddress(311);

			// Contract A has a counter in storage
			await evm.setStorage(contractA, U256.zero(), U256.fromBigInt(0n));

			// Contract B calls back to A
			const codeB: number[] = [];

			// Call A's increment function (simplified - just store 2)
			codeB.push(0x60, 0x00); // retSize
			codeB.push(0x60, 0x00); // retOffset
			codeB.push(0x60, 0x00); // argsSize
			codeB.push(0x60, 0x00); // argsOffset
			codeB.push(0x60, 0x00); // value
			codeB.push(0x73); // PUSH20
			codeB.push(...contractA.toBytes());
			codeB.push(0x5a); // GAS
			codeB.push(0xf1); // CALL

			await evm.setCode(contractB, Bytes.fromBytes(new Uint8Array(codeB)));

			// Contract A increments counter and calls B (if counter < 2)
			const codeA: number[] = [];

			// Load counter
			codeA.push(0x60, 0x00); // PUSH1 0
			codeA.push(0x54); // SLOAD

			// Increment
			codeA.push(0x60, 0x01); // PUSH1 1
			codeA.push(0x01); // ADD

			// Store back
			codeA.push(0x80); // DUP1
			codeA.push(0x60, 0x00); // PUSH1 0
			codeA.push(0x55); // SSTORE

			// Check if < 2
			codeA.push(0x60, 0x02); // PUSH1 2
			codeA.push(0x10); // LT

			// Jump if >= 2
			codeA.push(0x15); // ISZERO
			codeA.push(0x60, codeA.length + 20); // PUSH1 jump dest
			codeA.push(0x57); // JUMPI

			// Call B (will cause reentrancy)
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

			codeA.push(0x5b); // JUMPDEST

			await evm.setCode(contractA, Bytes.fromBytes(new Uint8Array(codeA)));

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			assertSuccess(result);

			// Counter should be incremented
			const counter = await evm.getStorage(contractA, U256.zero());
			expect(counter.toBigInt()).toBeGreaterThan(0n);
		});

		// TODO: Fix value transfer in call chains in Zig implementation
		it.todo("should handle call with value transfer in chain", async () => {
			const contractA = testAddress(320);
			const contractB = testAddress(321);
			const contractC = testAddress(322);

			// Fund contract A
			await evm.setBalance(contractA, U256.fromBigInt(1000n));

			// Contract C just accepts value
			await evm.setCode(contractC, hex("0x00")); // STOP

			// Contract B forwards half value to C
			const codeB: number[] = [];

			// Get call value and divide by 2
			codeB.push(0x34); // CALLVALUE
			codeB.push(0x60, 0x02); // PUSH1 2
			codeB.push(0x04); // DIV

			// Call C with half value
			codeB.push(0x60, 0x00); // retSize
			codeB.push(0x60, 0x00); // retOffset
			codeB.push(0x60, 0x00); // argsSize
			codeB.push(0x60, 0x00); // argsOffset
			// value already on stack
			codeB.push(0x73); // PUSH20
			codeB.push(...contractC.toBytes());
			codeB.push(0x5a); // GAS
			codeB.push(0xf1); // CALL

			await evm.setCode(contractB, Bytes.fromBytes(new Uint8Array(codeB)));

			// Contract A calls B with 600 wei
			const codeA: number[] = [];

			codeA.push(0x60, 0x00); // retSize
			codeA.push(0x60, 0x00); // retOffset
			codeA.push(0x60, 0x00); // argsSize
			codeA.push(0x60, 0x00); // argsOffset
			codeA.push(0x61, 0x02, 0x58); // PUSH2 600 (value)
			codeA.push(0x73); // PUSH20
			codeA.push(...contractB.toBytes());
			codeA.push(0x5a); // GAS
			codeA.push(0xf1); // CALL

			await evm.setCode(contractA, Bytes.fromBytes(new Uint8Array(codeA)));

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			assertSuccess(result);

			// Check final balances
			const balanceA = await evm.getBalance(contractA);
			const balanceB = await evm.getBalance(contractB);
			const balanceC = await evm.getBalance(contractC);

			expect(balanceA.toBigInt()).toBe(400n); // 1000 - 600
			expect(balanceB.toBigInt()).toBe(300n); // 600 - 300
			expect(balanceC.toBigInt()).toBe(300n); // Received 300
		});
	});

	describe("Gas Metering", () => {
		// TODO: Fix gas handling in nested calls in Zig implementation
		it.todo("should handle out of gas in nested call", async () => {
			const contractA = testAddress(400);
			const contractB = testAddress(401);

			// Contract B has infinite loop
			const codeB = hex("0x5b6000565b"); // JUMPDEST PUSH1 0 JUMP JUMPDEST
			await evm.setCode(contractB, codeB);

			// Contract A calls B with limited gas
			const codeA: number[] = [];

			codeA.push(0x60, 0x00); // retSize
			codeA.push(0x60, 0x00); // retOffset
			codeA.push(0x60, 0x00); // argsSize
			codeA.push(0x60, 0x00); // argsOffset
			codeA.push(0x60, 0x00); // value
			codeA.push(0x73); // PUSH20
			codeA.push(...contractB.toBytes());
			codeA.push(0x61, 0x27, 0x10); // PUSH2 10000 (gas)
			codeA.push(0xf1); // CALL

			// Check if call failed (should be 0)
			codeA.push(0x15); // ISZERO
			codeA.push(0x60, codeA.length + 6); // PUSH1 jump dest
			codeA.push(0x57); // JUMPI
			// If call succeeded (shouldn't happen)
			codeA.push(0x60, 0x01); // PUSH1 1
			codeA.push(0x60, 0x00); // PUSH1 0
			codeA.push(0xfd); // REVERT
			codeA.push(0x5b); // JUMPDEST
			// Return success
			codeA.push(0x60, 0x01); // PUSH1 1
			codeA.push(0x60, 0x00); // PUSH1 0
			codeA.push(0x52); // MSTORE
			codeA.push(0x60, 0x20); // PUSH1 32
			codeA.push(0x60, 0x00); // PUSH1 0
			codeA.push(0xf3); // RETURN

			await evm.setCode(contractA, Bytes.fromBytes(new Uint8Array(codeA)));

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
					gas: 100000n,
				}),
			);

			assertSuccess(result);

			// A should succeed but return that B failed
			const output = result.output.toBytes();
			expect(output[31]).toBe(1); // Indicating B's call failed
		});

		// TODO: Fix gas stipend handling in Zig implementation
		it.todo("should handle gas stipend for value transfers", async () => {
			const contractA = testAddress(410);
			const contractB = testAddress(411);

			// Fund A
			await evm.setBalance(contractA, U256.fromBigInt(1000n));

			// Contract B uses some gas
			const codeB: number[] = [];
			for (let i = 0; i < 10; i++) {
				codeB.push(0x60, i); // PUSH1 i
				codeB.push(0x60, i); // PUSH1 i
				codeB.push(0x01); // ADD
				codeB.push(0x50); // POP
			}

			await evm.setCode(contractB, Bytes.fromBytes(new Uint8Array(codeB)));

			// Contract A calls B with value (gets gas stipend)
			const codeA: number[] = [];

			codeA.push(0x60, 0x00); // retSize
			codeA.push(0x60, 0x00); // retOffset
			codeA.push(0x60, 0x00); // argsSize
			codeA.push(0x60, 0x00); // argsOffset
			codeA.push(0x60, 0x01); // PUSH1 1 (value)
			codeA.push(0x73); // PUSH20
			codeA.push(...contractB.toBytes());
			codeA.push(0x5a); // GAS
			codeA.push(0xf1); // CALL

			await evm.setCode(contractA, Bytes.fromBytes(new Uint8Array(codeA)));

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			assertSuccess(result);

			// B should have received the value
			const balanceB = await evm.getBalance(contractB);
			expect(balanceB.toBigInt()).toBe(1n);
		});
	});

	describe("Memory and Stack Limits", () => {
		// TODO: Fix memory expansion limits in Zig implementation
		it.todo("should handle large memory expansion", async () => {
			const contract = testAddress(500);

			// Write to increasingly high memory addresses
			const code: number[] = [];

			const offsets = [0x100, 0x1000, 0x10000];
			for (const offset of offsets) {
				code.push(0x60, 0x42); // PUSH1 66
				code.push(0x62, offset >> 8, offset & 0xff, 0x00); // PUSH3 offset
				code.push(0x52); // MSTORE
			}

			await evm.setCode(contract, Bytes.fromBytes(new Uint8Array(code)));

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
					gas: 10000000n, // High gas limit for memory expansion
				}),
			);

			assertSuccess(result);

			// Should consume significant gas for memory expansion
			const gasUsed = 10000000n - result.gasLeft;
			expect(gasUsed).toBeGreaterThan(100000n);
		});

		// TODO: Fix stack depth limit handling in Zig implementation
		it.todo("should handle stack depth limits", async () => {
			const contract = testAddress(501);

			// Push many values to stack
			const code: number[] = [];

			// Push 1024 values (stack limit)
			for (let i = 0; i < 1024; i++) {
				code.push(0x60, i & 0xff); // PUSH1 value
			}

			// Try to push one more (should fail)
			code.push(0x60, 0xff); // PUSH1 255

			await evm.setCode(contract, Bytes.fromBytes(new Uint8Array(code)));

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
					gas: 1000000n,
				}),
			);

			// Should fail due to stack overflow
			assertFailure(result);
			expect(result.errorMessage?.toLowerCase()).toContain("stack");
		});
	});

	describe("Bytecode Analysis", () => {
		// TODO: Fix jump handling in Zig implementation
		it.todo("should handle contracts with jumps", async () => {
			const contract = testAddress(600);

			// Conditional jump based on input
			const code: number[] = [];

			// Check if calldata is empty
			code.push(0x36); // CALLDATASIZE
			code.push(0x15); // ISZERO
			code.push(0x60, 0x0a); // PUSH1 10 (jump dest if empty)
			code.push(0x57); // JUMPI

			// Not empty - return 1
			code.push(0x60, 0x01); // PUSH1 1
			code.push(0x60, 0x00); // PUSH1 0
			code.push(0x52); // MSTORE
			code.push(0x60, 0x0e); // PUSH1 14 (jump to return)
			code.push(0x56); // JUMP

			// Empty - return 2
			code.push(0x5b); // JUMPDEST (offset 10)
			code.push(0x60, 0x02); // PUSH1 2
			code.push(0x60, 0x00); // PUSH1 0
			code.push(0x52); // MSTORE

			// Return
			code.push(0x5b); // JUMPDEST (offset 14)
			code.push(0x60, 0x20); // PUSH1 32
			code.push(0x60, 0x00); // PUSH1 0
			code.push(0xf3); // RETURN

			await evm.setCode(contract, Bytes.fromBytes(new Uint8Array(code)));

			// Call with no input
			let result = await evm.call(
				defaultExecutionParams({
					to: contract,
					input: Bytes.empty(),
				}),
			);

			assertSuccess(result);
			expect(result.output.toBytes()[0]).toBe(2);

			// Call with input
			result = await evm.call(
				defaultExecutionParams({
					to: contract,
					input: hex("0x1234"),
				}),
			);

			assertSuccess(result);
			expect(result.output.toBytes()[0]).toBe(1);
		});

		// TODO: Fix loop handling in Zig implementation
		it.todo("should handle contracts with loops", async () => {
			const contract = testAddress(601);

			// Sum numbers from 1 to N (N from calldata)
			const code: number[] = [];

			// Load N from calldata (default to 5 if no input)
			code.push(0x36); // CALLDATASIZE
			code.push(0x15); // ISZERO
			code.push(0x60, 0x08); // PUSH1 8 (jump if empty)
			code.push(0x57); // JUMPI

			// Has input - load first byte
			code.push(0x60, 0x00); // PUSH1 0
			code.push(0x35); // CALLDATALOAD
			code.push(0x60, 0x0a); // PUSH1 10 (skip default)
			code.push(0x56); // JUMP

			// No input - use 5
			code.push(0x5b); // JUMPDEST
			code.push(0x60, 0x05); // PUSH1 5

			// Initialize sum = 0, i = 1
			code.push(0x5b); // JUMPDEST
			code.push(0x60, 0x00); // PUSH1 0 (sum)
			code.push(0x60, 0x01); // PUSH1 1 (i)

			// Loop start
			code.push(0x5b); // JUMPDEST (loop)
			code.push(0x81); // DUP2 (i)
			code.push(0x83); // DUP4 (N)
			code.push(0x11); // GT (i > N)
			code.push(0x60, 0x1a); // PUSH1 26 (exit)
			code.push(0x57); // JUMPI

			// sum += i
			code.push(0x81); // DUP2 (i)
			code.push(0x01); // ADD
			code.push(0x91); // SWAP2 (update sum)
			code.push(0x50); // POP

			// i++
			code.push(0x60, 0x01); // PUSH1 1
			code.push(0x01); // ADD

			// Continue loop
			code.push(0x60, 0x0f); // PUSH1 15 (loop start)
			code.push(0x56); // JUMP

			// Exit - return sum
			code.push(0x5b); // JUMPDEST
			code.push(0x91); // SWAP2
			code.push(0x50); // POP
			code.push(0x50); // POP
			code.push(0x60, 0x00); // PUSH1 0
			code.push(0x52); // MSTORE
			code.push(0x60, 0x20); // PUSH1 32
			code.push(0x60, 0x00); // PUSH1 0
			code.push(0xf3); // RETURN

			await evm.setCode(contract, Bytes.fromBytes(new Uint8Array(code)));

			// Test with default (sum 1 to 5 = 15)
			let result = await evm.call(
				defaultExecutionParams({
					to: contract,
					input: Bytes.empty(),
				}),
			);

			assertSuccess(result);
			expect(result.output.toBytes()[0]).toBe(15);

			// Test with N=10 (sum 1 to 10 = 55)
			result = await evm.call(
				defaultExecutionParams({
					to: contract,
					input: hex("0x0a"),
				}),
			);

			assertSuccess(result);
			expect(result.output.toBytes()[0]).toBe(55);
		});
	});

	describe("Created Contracts", () => {
		it("should track created contract address", async () => {
			const deployer = testAddress(700);

			// Simple init code that returns empty runtime code
			const initCode = hex("0x60006000f3");

			const result = await evm.call({
				caller: deployer,
				to: Address.zero(),
				value: U256.zero(),
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE,
			});

			assertSuccess(result);
			expect(result.createdAddress).toBeDefined();
			expect(result.createdAddress).not.toBeNull();

			// Created address should exist
			if (result.createdAddress) {
				const code = await evm.getCode(result.createdAddress);
				expect(code).toBeDefined();
			}
		});

		it("should handle factory pattern", async () => {
			const factory = testAddress(701);

			// Factory that creates multiple contracts
			const factoryCode: number[] = [];

			// Create first contract
			factoryCode.push(0x60, 0x03); // PUSH1 3 (size of init code)
			factoryCode.push(0x60, 0x00); // PUSH1 0 (offset - will store init code here)
			factoryCode.push(0x60, 0x00); // PUSH1 0 (value)
			factoryCode.push(0xf0); // CREATE
			factoryCode.push(0x50); // POP (ignore address)

			// Create second contract
			factoryCode.push(0x60, 0x03); // PUSH1 3
			factoryCode.push(0x60, 0x00); // PUSH1 0
			factoryCode.push(0x60, 0x00); // PUSH1 0
			factoryCode.push(0xf0); // CREATE

			// Return second address
			factoryCode.push(0x60, 0x00); // PUSH1 0
			factoryCode.push(0x52); // MSTORE
			factoryCode.push(0x60, 0x20); // PUSH1 32
			factoryCode.push(0x60, 0x00); // PUSH1 0
			factoryCode.push(0xf3); // RETURN

			await evm.setCode(factory, Bytes.fromBytes(new Uint8Array(factoryCode)));

			const result = await evm.call(
				defaultExecutionParams({
					to: factory,
				}),
			);

			assertSuccess(result);

			// Factory itself doesn't create, but the CREATE opcodes inside do
			// The result should contain the address of the last created contract
			expect(result.output.length()).toBe(32);
		});
	});
});
