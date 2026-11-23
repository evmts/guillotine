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
		it("should handle SELFDESTRUCT", async () => {
			const contract = testAddress(100);
			const beneficiary = testAddress(101);

			await evm.setBalance(contract, U256.fromBigInt(1000n));
			const code = selfDestructBytecode(beneficiary);
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertSuccess(result);

			// EIP-6780 (Cancun): a contract not created in this transaction only sends its
			// balance; the account and its code survive, so nothing is destroyed
			expect(result.selfdestructs).toEqual([]);
			expect((await evm.getBalance(beneficiary)).toBigInt()).toBe(1000n);
			expect((await evm.getBalance(contract)).toBigInt()).toBe(0n);
			expect((await evm.getCode(contract)).toHex()).toBe(code.toHex());

			// PUSH20 3 + SELFDESTRUCT 5000 + cold beneficiary 2600 (EIP-2929)
			// + 25000 for sending value to an empty account (EIP-161)
			expect(result.gasLeft).toBe(1000000n - 21000n - 3n - 5000n - 2600n - 25000n);
		});

		it("should destroy a contract that self-destructs in its creating transaction (EIP-6780)", async () => {
			const deployer = testAddress(106);
			const beneficiary = testAddress(107);
			await evm.setBalance(deployer, U256.fromBigInt(1000n));

			// Init code self-destructs immediately, sending its 300 wei endowment to beneficiary
			const result = await evm.call({
				caller: deployer,
				to: Address.zero(),
				value: U256.fromBigInt(300n),
				input: selfDestructBytecode(beneficiary),
				gas: 1000000n,
				callType: CallType.CREATE,
			});

			assertSuccess(result);
			const created = result.createdAddress;
			if (created === null) throw new Error("CREATE returned no address");

			expect(result.selfdestructs).toHaveLength(1);
			const record = first(result.selfdestructs, "self-destruct record");
			expect(record.contract.toHex()).toBe(created.toHex());
			expect(record.beneficiary.toHex()).toBe(beneficiary.toHex());

			expect((await evm.getBalance(beneficiary)).toBigInt()).toBe(300n);
			expect((await evm.getBalance(created)).toBigInt()).toBe(0n);
			expect((await evm.getCode(created)).isEmpty()).toBe(true);
		});

		it("should handle SELFDESTRUCT to self", async () => {
			const contract = testAddress(102);
			const code = selfDestructBytecode(contract);

			await evm.setBalance(contract, U256.fromBigInt(500n));
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertSuccess(result);

			// EIP-6780: a pre-existing contract that names itself as beneficiary keeps its
			// balance and code; nothing is burned or destroyed
			expect(result.selfdestructs).toEqual([]);
			expect((await evm.getBalance(contract)).toBigInt()).toBe(500n);
			expect((await evm.getCode(contract)).toHex()).toBe(code.toHex());

			// PUSH20 3 + SELFDESTRUCT 5000; the executing address is already warm
			expect(result.gasLeft).toBe(1000000n - 21000n - 3n - 5000n);
		});

		// TODO: Fix SELFDESTRUCT tracking in Zig implementation
		it("should handle multiple SELFDESTRUCT in one transaction", async () => {
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

			// EIP-6780: neither contract was created in this transaction, so neither is destroyed
			expect(result.selfdestructs).toEqual([]);
			expect((await evm.getCode(contractA)).toHex()).toBe(codeA.toHex());
			expect((await evm.getCode(contractB)).isEmpty()).toBe(false);

			// Beneficiary receives both balances
			expect((await evm.getBalance(beneficiary)).toBigInt()).toBe(1000n); // 300 + 700
			expect((await evm.getBalance(contractA)).toBigInt()).toBe(0n);
			expect((await evm.getBalance(contractB)).toBigInt()).toBe(0n);
		});
	});

	describe("Access Lists", () => {
		// TODO: Fix access list tracking in Zig implementation
		it("should track accessed addresses", async () => {
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
		it("should track accessed storage slots", async () => {
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
		it("should track warm/cold access patterns", async () => {
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
		it("should handle deep call stack", async () => {
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

			// Each caller returns success || callee output: four success words, then 99
			const expected = new Uint8Array(5 * 32);
			for (let i = 0; i < 4; i++) expected[i * 32 + 31] = 1;
			expected[4 * 32 + 31] = 99;
			expect(result.output.toBytes()).toEqual(expected);

			// All contracts should be in accessed addresses
			const accessedHexes = result.accessedAddresses.map((a) => a.toHex());
			contracts.forEach((contract) => {
				expect(accessedHexes).toContain(contract.toHex());
			});
		});

		it("should handle reentrancy", async () => {
			const contractA = testAddress(310);
			const contractB = testAddress(311);

			// Contract B calls back into A with all its gas
			const codeB = Bytes.fromBytes(
				new Uint8Array([
					0x60, 0x00, // PUSH1 0 (retSize)
					0x60, 0x00, // PUSH1 0 (retOffset)
					0x60, 0x00, // PUSH1 0 (argsSize)
					0x60, 0x00, // PUSH1 0 (argsOffset)
					0x60, 0x00, // PUSH1 0 (value)
					0x73, ...contractA.toBytes(), // PUSH20 contractA
					0x5a, // GAS
					0xf1, // CALL
					0x00, // STOP
				]),
			);
			await evm.setCode(contractB, codeB);

			// Contract A: counter = SLOAD(0) + 1; SSTORE(0, counter); if counter < 3, call B
			const codeA = Bytes.fromBytes(
				new Uint8Array([
					0x60, 0x00, // 0: PUSH1 0
					0x54, // 2: SLOAD
					0x60, 0x01, // 3: PUSH1 1
					0x01, // 5: ADD
					0x80, // 6: DUP1
					0x60, 0x00, // 7: PUSH1 0
					0x55, // 9: SSTORE           stack: [counter]
					0x60, 0x03, // 10: PUSH1 3
					0x81, // 12: DUP2            stack: [counter, 3, counter]
					0x10, // 13: LT              counter < 3
					0x15, // 14: ISZERO
					0x60, 0x34, // 15: PUSH1 52
					0x57, // 17: JUMPI           counter >= 3: jump to end
					0x60, 0x00, // 18: PUSH1 0 (retSize)
					0x60, 0x00, // 20: PUSH1 0 (retOffset)
					0x60, 0x00, // 22: PUSH1 0 (argsSize)
					0x60, 0x00, // 24: PUSH1 0 (argsOffset)
					0x60, 0x00, // 26: PUSH1 0 (value)
					0x73, ...contractB.toBytes(), // 28: PUSH20 contractB
					0x5a, // 49: GAS
					0xf1, // 50: CALL (re-enters A through B)
					0x50, // 51: POP
					0x5b, // 52: JUMPDEST
					0x00, // 53: STOP
				]),
			);
			await evm.setCode(contractA, codeA);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			assertSuccess(result);

			// A runs three times: tx -> A(1) -> B -> A(2) -> B -> A(3)
			expect((await evm.getStorage(contractA, U256.zero())).toBigInt()).toBe(3n);
		});

		// TODO: Fix value transfer in call chains in Zig implementation
		it("should handle call with value transfer in chain", async () => {
			const contractA = testAddress(320);
			const contractB = testAddress(321);
			const contractC = testAddress(322);

			// Fund contract A
			await evm.setBalance(contractA, U256.fromBigInt(1000n));

			// Contract C just accepts value
			await evm.setCode(contractC, hex("0x00")); // STOP

			// Contract B forwards half value to C
			const codeB: number[] = [];

			// Call C with value CALLVALUE / 2
			codeB.push(0x60, 0x00); // retSize
			codeB.push(0x60, 0x00); // retOffset
			codeB.push(0x60, 0x00); // argsSize
			codeB.push(0x60, 0x00); // argsOffset
			codeB.push(0x60, 0x02); // PUSH1 2 (divisor)
			codeB.push(0x34); // CALLVALUE (dividend, top of stack)
			codeB.push(0x04); // DIV: CALLVALUE / 2
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
			expect(result.output.isEmpty()).toBe(true);

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
		it("should handle out of gas in nested call", async () => {
			const contractA = testAddress(400);
			const contractB = testAddress(401);

			// Contract B loops forever: JUMPDEST PUSH1 0 JUMP
			await evm.setCode(contractB, Bytes.fromBytes(new Uint8Array([0x5b, 0x60, 0x00, 0x56])));

			// Contract A calls B with 10000 gas and returns ISZERO(success)
			const codeA = Bytes.fromBytes(
				new Uint8Array([
					0x60, 0x00, // 0: PUSH1 0 (retSize)
					0x60, 0x00, // 2: PUSH1 0 (retOffset)
					0x60, 0x00, // 4: PUSH1 0 (argsSize)
					0x60, 0x00, // 6: PUSH1 0 (argsOffset)
					0x60, 0x00, // 8: PUSH1 0 (value)
					0x73, ...contractB.toBytes(), // 10: PUSH20 contractB
					0x61, 0x27, 0x10, // 31: PUSH2 10000 (gas)
					0xf1, // 34: CALL
					0x15, // 35: ISZERO
					0x60, 0x00, // 36: PUSH1 0
					0x52, // 38: MSTORE
					0x60, 0x20, // 39: PUSH1 32
					0x60, 0x00, // 41: PUSH1 0
					0xf3, // 43: RETURN
				]),
			);
			await evm.setCode(contractA, codeA);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
					gas: 100000n,
				}),
			);

			// A succeeds and reports that B's call failed
			assertSuccess(result);
			expect(U256.fromBytes(result.output.toBytes()).toBigInt()).toBe(1n);

			// A: 5 x PUSH1 15 + PUSH20 3 + PUSH2 3 + CALL cold 2600 + ISZERO 3 + PUSH1 3 + MSTORE 3
			//    + memory 3 + PUSH1 3 + PUSH1 3 = 2639; B consumes all 10000 forwarded gas
			expect(result.gasLeft).toBe(100000n - 21000n - 2639n - 10000n);
		});

		// TODO: Fix gas stipend handling in Zig implementation
		it("should handle gas stipend for value transfers", async () => {
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
		it("should handle large memory expansion", async () => {
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
		it("should handle stack depth limits", async () => {
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

			// Stack overflow is an exceptional halt: all gas consumed, no data, no reason string
			assertFailure(result);
			expect(result.errorMessage).toBeNull();
			expect(result.output.isEmpty()).toBe(true);
			expect(result.gasLeft).toBe(0n);
		});
	});

	describe("Bytecode Analysis", () => {
		it("should handle contracts with jumps", async () => {
			const contract = testAddress(600);

			// Return 2 if calldata is empty, else 1
			const code = Bytes.fromBytes(
				new Uint8Array([
					0x36, // 0: CALLDATASIZE
					0x15, // 1: ISZERO
					0x60, 0x0d, // 2: PUSH1 13 (empty branch)
					0x57, // 4: JUMPI
					0x60, 0x01, // 5: PUSH1 1
					0x60, 0x00, // 7: PUSH1 0
					0x52, // 9: MSTORE
					0x60, 0x13, // 10: PUSH1 19 (return)
					0x56, // 12: JUMP
					0x5b, // 13: JUMPDEST (empty branch)
					0x60, 0x02, // 14: PUSH1 2
					0x60, 0x00, // 16: PUSH1 0
					0x52, // 18: MSTORE
					0x5b, // 19: JUMPDEST (return)
					0x60, 0x20, // 20: PUSH1 32
					0x60, 0x00, // 22: PUSH1 0
					0xf3, // 24: RETURN
				]),
			);
			await evm.setCode(contract, code);

			let result = await evm.call(
				defaultExecutionParams({
					to: contract,
					input: Bytes.empty(),
				}),
			);

			assertSuccess(result);
			expect(U256.fromBytes(result.output.toBytes()).toBigInt()).toBe(2n);

			result = await evm.call(
				defaultExecutionParams({
					to: contract,
					input: hex("0x1234"),
				}),
			);

			assertSuccess(result);
			expect(U256.fromBytes(result.output.toBytes()).toBigInt()).toBe(1n);
		});

		it("should handle contracts with loops", async () => {
			const contract = testAddress(601);

			// Return 1 + 2 + ... + N, where N is the first calldata byte (5 if calldata is empty)
			const code = Bytes.fromBytes(
				new Uint8Array([
					0x36, // 0: CALLDATASIZE
					0x15, // 1: ISZERO
					0x60, 0x0e, // 2: PUSH1 14 (default)
					0x57, // 4: JUMPI
					0x60, 0x00, // 5: PUSH1 0
					0x35, // 7: CALLDATALOAD
					0x60, 0xf8, // 8: PUSH1 248
					0x1c, // 10: SHR (first calldata byte)
					0x60, 0x11, // 11: PUSH1 17 (init)
					0x56, // 13: JUMP
					0x5b, // 14: JUMPDEST (default)
					0x60, 0x05, // 15: PUSH1 5
					0x5b, // 17: JUMPDEST (init)      stack: [N]
					0x60, 0x00, // 18: PUSH1 0 (sum)
					0x60, 0x01, // 20: PUSH1 1 (i)    stack: [i, sum, N]
					0x5b, // 22: JUMPDEST (loop)
					0x82, // 23: DUP3                 [N, i, sum, N]
					0x81, // 24: DUP2                 [i, N, i, sum, N]
					0x11, // 25: GT                   i > N
					0x60, 0x27, // 26: PUSH1 39 (exit)
					0x57, // 28: JUMPI
					0x80, // 29: DUP1                 [i, i, sum, N]
					0x91, // 30: SWAP2                [sum, i, i, N]
					0x01, // 31: ADD                  [sum + i, i, N]
					0x90, // 32: SWAP1                [i, sum, N]
					0x60, 0x01, // 33: PUSH1 1
					0x01, // 35: ADD                  [i + 1, sum, N]
					0x60, 0x16, // 36: PUSH1 22 (loop)
					0x56, // 38: JUMP
					0x5b, // 39: JUMPDEST (exit)      [i, sum, N]
					0x50, // 40: POP                  [sum, N]
					0x60, 0x00, // 41: PUSH1 0
					0x52, // 43: MSTORE
					0x60, 0x20, // 44: PUSH1 32
					0x60, 0x00, // 46: PUSH1 0
					0xf3, // 48: RETURN
				]),
			);
			await evm.setCode(contract, code);

			// Default N = 5: 15
			let result = await evm.call(
				defaultExecutionParams({
					to: contract,
					input: Bytes.empty(),
				}),
			);

			assertSuccess(result);
			expect(U256.fromBytes(result.output.toBytes()).toBigInt()).toBe(15n);

			// N = 10: 55
			result = await evm.call(
				defaultExecutionParams({
					to: contract,
					input: hex("0x0a"),
				}),
			);

			assertSuccess(result);
			expect(U256.fromBytes(result.output.toBytes()).toBigInt()).toBe(55n);
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
