import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { GuillotineEvm, CallType } from "./evm.js";
import { Address } from "../primitives/address.js";
import { U256 } from "../primitives/u256.js";
import { Bytes } from "../primitives/bytes.js";
import { GuillotineError } from "../errors.js";
import {
	testAddress,
	defaultExecutionParams,
	storeBytecode,
	hex,
	assertFailure,
	assertSuccess,
} from "../../test/test-helpers.js";

/** Exceptional halt (Yellow Paper Z): no reason string, no return data, all gas consumed. */
function expectExceptionalHalt(result: { success: boolean; gasLeft: bigint; output: Bytes; errorMessage: string | null }): void {
	expect(result.success).toBe(false);
	expect(result.errorMessage).toBeNull();
	expect(result.output.isEmpty()).toBe(true);
	expect(result.gasLeft).toBe(0n);
}

describe("GuillotineEvm - Error Handling", () => {
	let evm: GuillotineEvm;

	beforeEach(async () => {
		evm = await GuillotineEvm.create();
	});

	afterEach(() => {
		if (evm) {
			evm.close();
		}
	});

	describe("Initialization Errors", () => {
		it("should throw error when using closed Evm", async () => {
			const addr = testAddress(1);
			evm.close();

			await expect(evm.getBalance(addr)).rejects.toThrow(GuillotineError);
			await expect(evm.getBalance(addr)).rejects.toThrow("not initialized");
		});

		it("should throw error for all operations on closed Evm", async () => {
			const addr = testAddress(2);
			const key = U256.zero();
			const value = U256.fromBigInt(100n);

			evm.close();

			// All operations should fail
			await expect(evm.getBalance(addr)).rejects.toThrow(GuillotineError);
			await expect(evm.setBalance(addr, value)).rejects.toThrow(
				GuillotineError,
			);
			await expect(evm.getCode(addr)).rejects.toThrow(GuillotineError);
			await expect(evm.setCode(addr, Bytes.empty())).rejects.toThrow(
				GuillotineError,
			);
			await expect(evm.getStorage(addr, key)).rejects.toThrow(GuillotineError);
			await expect(evm.setStorage(addr, key, value)).rejects.toThrow(
				GuillotineError,
			);
			await expect(evm.call(defaultExecutionParams())).rejects.toThrow(
				GuillotineError,
			);
			await expect(evm.simulate(defaultExecutionParams())).rejects.toThrow(
				GuillotineError,
			);
		});

		it("should provide specific error types", async () => {
			evm.close();

			try {
				await evm.getBalance(testAddress(3));
				throw new Error("Should have thrown");
			} catch (error) {
				expect(error).toBeInstanceOf(GuillotineError);
				if (error instanceof GuillotineError) {
					expect(error.type).toBe("VMNotInitialized");
				}
			}
		});
	});

	describe("Execution Errors", () => {
		it("should handle invalid opcode", async () => {
			const contract = testAddress(100);
			// INVALID (0xfe)
			const code = Bytes.fromBytes(new Uint8Array([0xfe]));

			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			expectExceptionalHalt(result);
		});

		it("should handle stack underflow", async () => {
			const contract = testAddress(101);
			// PUSH1 1, ADD: ADD needs two operands
			const code = Bytes.fromBytes(new Uint8Array([0x60, 0x01, 0x01]));

			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			expectExceptionalHalt(result);
		});

		it("should handle stack overflow", async () => {
			const contract = testAddress(102);

			// 1025 x PUSH1: the 1025th push exceeds the 1024-item stack limit
			const code: number[] = [];
			for (let i = 0; i < 1025; i++) {
				code.push(0x60, i & 0xff); // PUSH1 value
			}

			await evm.setCode(contract, Bytes.fromBytes(new Uint8Array(code)));

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
					gas: 1000000n,
				}),
			);

			expectExceptionalHalt(result);
		});

		it("should handle out of gas", async () => {
			const contract = testAddress(103);
			// JUMPDEST PUSH1 0 JUMP: infinite loop
			const code = Bytes.fromBytes(new Uint8Array([0x5b, 0x60, 0x00, 0x56]));

			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
					gas: 30000n,
				}),
			);

			expectExceptionalHalt(result);
		});

		it("should handle invalid jump destination", async () => {
			const contract = testAddress(104);
			// PUSH1 5 JUMP: offset 5 is past the end of the code, not a JUMPDEST
			const code = Bytes.fromBytes(new Uint8Array([0x60, 0x05, 0x56]));

			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			expectExceptionalHalt(result);
		});

		it("should handle insufficient balance for value transfer", async () => {
			const sender = testAddress(105);
			const receiver = testAddress(106);

			// Sender has 50, tries to send 100
			await evm.setBalance(sender, U256.fromBigInt(50n));

			const result = await evm.call(
				defaultExecutionParams({
					caller: sender,
					to: receiver,
					value: U256.fromBigInt(100n),
				}),
			);

			assertFailure(result);
			expect(result.output.isEmpty()).toBe(true);
			expect((await evm.getBalance(sender)).toBigInt()).toBe(50n);
			expect((await evm.getBalance(receiver)).toBigInt()).toBe(0n);
		});
	});

	describe("Static Call Violations", () => {
		it("should error on state modification in static context", async () => {
			const contract = testAddress(200);
			// PUSH1 42 PUSH1 0 SSTORE
			const code = storeBytecode(0, 42);

			await evm.setBalance(contract, U256.fromBigInt(1000n));
			await evm.setCode(contract, code);

			const result = await evm.call({
				caller: testAddress(1),
				to: contract,
				value: U256.zero(),
				input: Bytes.empty(),
				gas: 1000000n,
				callType: CallType.STATICCALL,
			});

			// State modification in a static context is an exceptional halt (EIP-214)
			expectExceptionalHalt(result);
			expect((await evm.getStorage(contract, U256.zero())).toBigInt()).toBe(0n);
		});

		it("should error on CREATE in static context", async () => {
			const contract = testAddress(201);
			// PUSH1 0 (size) PUSH1 0 (offset) PUSH1 0 (value) CREATE
			const code = Bytes.fromBytes(new Uint8Array([0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0xf0]));

			await evm.setBalance(contract, U256.fromBigInt(1000n));
			await evm.setCode(contract, code);

			const result = await evm.call({
				caller: testAddress(1),
				to: contract,
				value: U256.zero(),
				input: Bytes.empty(),
				gas: 1000000n,
				callType: CallType.STATICCALL,
			});

			// State modification in a static context is an exceptional halt (EIP-214)
			expectExceptionalHalt(result);
			expect(result.createdAddress).toBeNull();
			expect((await evm.getBalance(contract)).toBigInt()).toBe(1000n);
		});

		it("should error on SELFDESTRUCT in static context", async () => {
			const contract = testAddress(202);
			// PUSH20 beneficiary SELFDESTRUCT
			const code = Bytes.fromBytes(new Uint8Array([0x73, ...testAddress(999).toBytes(), 0xff]));

			await evm.setBalance(contract, U256.fromBigInt(1000n));
			await evm.setCode(contract, code);

			const result = await evm.call({
				caller: testAddress(1),
				to: contract,
				value: U256.zero(),
				input: Bytes.empty(),
				gas: 1000000n,
				callType: CallType.STATICCALL,
			});

			// State modification in a static context is an exceptional halt (EIP-214)
			expectExceptionalHalt(result);
			expect(result.selfdestructs).toEqual([]);
			expect((await evm.getBalance(contract)).toBigInt()).toBe(1000n);
			expect((await evm.getBalance(testAddress(999))).toBigInt()).toBe(0n);
			expect((await evm.getCode(contract)).toHex()).toBe(code.toHex());
		});

		it("should error on LOG in static context", async () => {
			const contract = testAddress(203);
			// PUSH1 0 (size) PUSH1 0 (offset) LOG0
			const code = Bytes.fromBytes(new Uint8Array([0x60, 0x00, 0x60, 0x00, 0xa0]));

			await evm.setBalance(contract, U256.fromBigInt(1000n));
			await evm.setCode(contract, code);

			const result = await evm.call({
				caller: testAddress(1),
				to: contract,
				value: U256.zero(),
				input: Bytes.empty(),
				gas: 1000000n,
				callType: CallType.STATICCALL,
			});

			// State modification in a static context is an exceptional halt (EIP-214)
			expectExceptionalHalt(result);
			expect(result.logs).toEqual([]);
		});
	});

	describe("Revert Handling", () => {
		it("should handle REVERT with no data", async () => {
			const contract = testAddress(300);
			// PUSH1 0 (size) PUSH1 0 (offset) REVERT
			const code = Bytes.fromBytes(new Uint8Array([0x60, 0x00, 0x60, 0x00, 0xfd]));

			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertFailure(result);
			expect(result.errorMessage).toBeNull();
			expect(result.output.isEmpty()).toBe(true);
			// REVERT returns unused gas: PUSH1 3 + PUSH1 3 = 6
			expect(result.gasLeft).toBe(1000000n - 21000n - 6n);
		});

		// TODO: Fix REVERT with error message handling in Zig
		it("should handle REVERT with error message", async () => {
			const contract = testAddress(301);
			// Store "ERROR" and revert with it
			const errorMsg = "ERROR";
			const code: number[] = [];

			// Store error message in memory
			for (let i = 0; i < errorMsg.length; i++) {
				code.push(0x60, errorMsg.charCodeAt(i)); // PUSH1 char
				code.push(0x60, i); // PUSH1 offset
				code.push(0x53); // MSTORE8
			}

			// REVERT with the message
			code.push(0x60, errorMsg.length); // PUSH1 length
			code.push(0x60, 0x00); // PUSH1 0 (offset)
			code.push(0xfd); // REVERT

			await evm.setCode(contract, Bytes.fromBytes(new Uint8Array(code)));

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertFailure(result);
			expect(result.errorMessage).toBeNull();
			expect(new TextDecoder().decode(result.output.toBytes())).toBe(errorMsg);
			// 5 x (PUSH1 3 + PUSH1 3 + MSTORE8 3) = 45, memory 1 word 3, PUSH1 3 + PUSH1 3 = 54
			expect(result.gasLeft).toBe(1000000n - 21000n - 54n);
		});

		it("should handle nested revert propagation", async () => {
			const contractA = testAddress(302);
			const contractB = testAddress(303);

			// Contract B: PUSH1 0 PUSH1 0 REVERT
			await evm.setCode(contractB, Bytes.fromBytes(new Uint8Array([0x60, 0x00, 0x60, 0x00, 0xfd])));

			// Contract A calls B and reverts if the call failed
			const codeA = Bytes.fromBytes(
				new Uint8Array([
					0x60, 0x00, // 0: PUSH1 0 (retSize)
					0x60, 0x00, // 2: PUSH1 0 (retOffset)
					0x60, 0x00, // 4: PUSH1 0 (argsSize)
					0x60, 0x00, // 6: PUSH1 0 (argsOffset)
					0x60, 0x00, // 8: PUSH1 0 (value)
					0x73, ...contractB.toBytes(), // 10: PUSH20 contractB
					0x5a, // 31: GAS
					0xf1, // 32: CALL
					0x15, // 33: ISZERO
					0x60, 0x26, // 34: PUSH1 38
					0x57, // 36: JUMPI
					0x00, // 37: STOP (not reached)
					0x5b, // 38: JUMPDEST
					0x60, 0x00, // 39: PUSH1 0
					0x60, 0x00, // 41: PUSH1 0
					0xfd, // 43: REVERT
				]),
			);
			await evm.setCode(contractA, codeA);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			assertFailure(result);
			expect(result.errorMessage).toBeNull();
			expect(result.output.isEmpty()).toBe(true);
			// A: 5 x PUSH1 15 + PUSH20 3 + GAS 2 + CALL cold 2600 + ISZERO 3 + PUSH1 3 + JUMPI 10
			//    + JUMPDEST 1 + PUSH1 3 + PUSH1 3 = 2643; B: 6 (unused forwarded gas is returned)
			expect(result.gasLeft).toBe(1000000n - 21000n - 2643n - 6n);
		});
	});

	describe("Memory Errors", () => {
		it("should handle memory out of bounds read", async () => {
			const contract = testAddress(400);
			// PUSH32 2^256-1 (size) PUSH1 0 (offset) RETURN: memory expansion cost exceeds any gas
			const code = Bytes.fromBytes(new Uint8Array([0x7f, ...new Uint8Array(32).fill(0xff), 0x60, 0x00, 0xf3]));

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
					gas: 100000n,
				}),
			);

			expectExceptionalHalt(result);
		});

		it("should handle excessive memory expansion", async () => {
			const contract = testAddress(401);
			// PUSH1 1 (value) PUSH32 2^256-1 (offset) MSTORE
			const code = Bytes.fromBytes(new Uint8Array([0x60, 0x01, 0x7f, ...new Uint8Array(32).fill(0xff), 0x52]));

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
					gas: 100000n, // Limited gas
				}),
			);

			expectExceptionalHalt(result);
		});

		it("should handle RETURNDATACOPY out of bounds", async () => {
			const contract = testAddress(402);
			// PUSH1 100 (size) PUSH1 0 (offset) PUSH1 0 (destOffset) RETURNDATACOPY with empty return data
			const code = Bytes.fromBytes(new Uint8Array([0x60, 0x64, 0x60, 0x00, 0x60, 0x00, 0x3e]));

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			// EIP-211: reading past the return data buffer is an exceptional halt
			expectExceptionalHalt(result);
		});
	});

	describe("CREATE Errors", () => {
		it("should handle CREATE with insufficient balance", async () => {
			const deployer = testAddress(500);

			// Deployer has 50, tries to create with 100
			await evm.setBalance(deployer, U256.fromBigInt(50n));

			const initCode = hex("0x60006000f3");

			const result = await evm.call({
				caller: deployer,
				to: Address.zero(),
				value: U256.fromBigInt(100n),
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE,
			});

			assertFailure(result);
			expect(result.createdAddress).toBeNull();
		});

		// TODO: Fix CREATE2 collision detection in Zig
		it("should handle CREATE2 collision", async () => {
			const deployer = testAddress(501);
			const salt = U256.fromBigInt(0x1234n);
			const initCode = hex("0x60006000f3");

			// First deployment should succeed
			const result1 = await evm.call({
				caller: deployer,
				to: Address.zero(),
				value: U256.zero(),
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE2,
				salt: salt,
			});

			expect(result1.success).toBe(true);

			// Second deployment with same salt should fail (collision)
			const result2 = await evm.call({
				caller: deployer,
				to: Address.zero(),
				value: U256.zero(),
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE2,
				salt: salt,
			});

			assertFailure(result2);
			expect(result2.createdAddress).toBeNull();
		});

		// TODO: Fix CREATE init code failure detection in Zig
		it("should handle CREATE with init code failure", async () => {
			const deployer = testAddress(502);

			// Init code: PUSH1 0 PUSH1 0 REVERT
			const initCode = Bytes.fromBytes(new Uint8Array([0x60, 0x00, 0x60, 0x00, 0xfd]));

			const result = await evm.call({
				caller: deployer,
				to: Address.zero(),
				value: U256.zero(),
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE,
			});

			assertFailure(result);
			expect(result.createdAddress).toBeNull();
		});
	});

	describe("Call Depth Errors", () => {
		it("should contain failures of deeply recursive calls", async () => {
			// Since EIP-150 the 63/64 rule exhausts gas long before depth 1024, so the innermost
			// call fails out of gas. A failed CALL only pushes 0; the caller continues and succeeds.
			const contract = testAddress(600);

			// Contract calls itself with all available gas, then stores the CALL result
			const code = Bytes.fromBytes(
				new Uint8Array([
					0x60, 0x00, // PUSH1 0 (retSize)
					0x60, 0x00, // PUSH1 0 (retOffset)
					0x60, 0x00, // PUSH1 0 (argsSize)
					0x60, 0x00, // PUSH1 0 (argsOffset)
					0x60, 0x00, // PUSH1 0 (value)
					0x73, ...contract.toBytes(), // PUSH20 self
					0x5a, // GAS
					0xf1, // CALL
					0x00, // STOP
				]),
			);
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
					gas: 10000000n,
				}),
			);

			assertSuccess(result);
			expect(result.output.isEmpty()).toBe(true);
		});
	});

	describe("Invalid Bytecode", () => {
		it("should zero-pad a truncated PUSH instruction", async () => {
			const contract = testAddress(700);
			// PUSH2 with one data byte: Yellow Paper pads code with zeros, so this pushes 0x0100
			// and then executes the implicit STOP past the end of the code
			const code = Bytes.fromBytes(new Uint8Array([0x61, 0x01]));

			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertSuccess(result);
			expect(result.output.isEmpty()).toBe(true);
			// PUSH2 3
			expect(result.gasLeft).toBe(1000000n - 21000n - 3n);
		});

		it("should treat code ending with an incomplete PUSH as STOP", async () => {
			const contract = testAddress(701);
			// PUSH1 1, PUSH1 with no data byte (pushes 0), then implicit STOP
			const code = Bytes.fromBytes(new Uint8Array([0x60, 0x01, 0x60]));

			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertSuccess(result);
			expect(result.output.isEmpty()).toBe(true);
			// PUSH1 3 + PUSH1 3
			expect(result.gasLeft).toBe(1000000n - 21000n - 6n);
		});

		it("should handle jump to out of bounds", async () => {
			const contract = testAddress(702);
			// PUSH2 0xffff JUMP: past the end of the code
			const code = Bytes.fromBytes(new Uint8Array([0x61, 0xff, 0xff, 0x56]));

			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			expectExceptionalHalt(result);
		});
	});

	describe("Error Recovery", () => {
		// TODO: Fix state consistency after errors in Zig
		it("should maintain state consistency after error", async () => {
			const contract = testAddress(800);

			// Set initial state
			await evm.setBalance(contract, U256.fromBigInt(1000n));
			await evm.setStorage(contract, U256.zero(), U256.fromBigInt(42n));

			// Code that modifies state then reverts
			const code: number[] = [];

			// Store new value
			code.push(0x60, 0x99); // PUSH1 153
			code.push(0x60, 0x00); // PUSH1 0
			code.push(0x55); // SSTORE

			// Revert
			code.push(0x60, 0x00); // PUSH1 0
			code.push(0x60, 0x00); // PUSH1 0
			code.push(0xfd); // REVERT

			await evm.setCode(contract, Bytes.fromBytes(new Uint8Array(code)));

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertFailure(result);

			// State should be unchanged
			const balance = await evm.getBalance(contract);
			expect(balance.toBigInt()).toBe(1000n);

			const storage = await evm.getStorage(contract, U256.zero());
			expect(storage.toBigInt()).toBe(42n); // Original value
		});

		it("should handle partial execution before error", async () => {
			const contractA = testAddress(801);
			const contractB = testAddress(802);
			const contractC = testAddress(803);

			// B returns the word 1: PUSH1 1 PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
			await evm.setCode(
				contractB,
				Bytes.fromBytes(new Uint8Array([0x60, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3])),
			);
			// C reverts: PUSH1 0 PUSH1 0 REVERT
			await evm.setCode(contractC, Bytes.fromBytes(new Uint8Array([0x60, 0x00, 0x60, 0x00, 0xfd])));

			// A calls B, stores B's word in slot 0, calls C, and reverts if C failed
			const codeA = Bytes.fromBytes(
				new Uint8Array([
					0x60, 0x20, // 0: PUSH1 32 (retSize)
					0x60, 0x00, // 2: PUSH1 0 (retOffset)
					0x60, 0x00, // 4: PUSH1 0 (argsSize)
					0x60, 0x00, // 6: PUSH1 0 (argsOffset)
					0x60, 0x00, // 8: PUSH1 0 (value)
					0x73, ...contractB.toBytes(), // 10: PUSH20 contractB
					0x5a, // 31: GAS
					0xf1, // 32: CALL
					0x50, // 33: POP
					0x60, 0x00, // 34: PUSH1 0
					0x51, // 36: MLOAD
					0x60, 0x00, // 37: PUSH1 0
					0x55, // 39: SSTORE (slot 0 = 1)
					0x60, 0x00, // 40: PUSH1 0 (retSize)
					0x60, 0x00, // 42: PUSH1 0 (retOffset)
					0x60, 0x00, // 44: PUSH1 0 (argsSize)
					0x60, 0x00, // 46: PUSH1 0 (argsOffset)
					0x60, 0x00, // 48: PUSH1 0 (value)
					0x73, ...contractC.toBytes(), // 50: PUSH20 contractC
					0x5a, // 71: GAS
					0xf1, // 72: CALL
					0x60, 0x51, // 73: PUSH1 81
					0x57, // 75: JUMPI (jump if C succeeded)
					0x60, 0x00, // 76: PUSH1 0
					0x60, 0x00, // 78: PUSH1 0
					0xfd, // 80: REVERT
					0x5b, // 81: JUMPDEST
					0x00, // 82: STOP
				]),
			);
			await evm.setCode(contractA, codeA);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			assertFailure(result);
			expect(result.output.isEmpty()).toBe(true);

			// A's REVERT undoes its SSTORE
			expect((await evm.getStorage(contractA, U256.zero())).toBigInt()).toBe(0n);
		});
	});

	describe("Error Messages", () => {
		it("should report exceptional halts without a reason string", async () => {
			const testCases = [
				{ name: "Stack underflow", code: [0x50] }, // POP on empty stack
				{ name: "Invalid opcode", code: [0xfe] }, // INVALID
				{ name: "Out of gas", code: [0x5b, 0x60, 0x00, 0x56], gas: 30000n }, // infinite loop
				{ name: "Invalid jump", code: [0x60, 0x0a, 0x56] }, // PUSH1 10 JUMP
			];

			for (const [index, testCase] of testCases.entries()) {
				const contract = testAddress(900 + index);
				await evm.setCode(contract, Bytes.fromBytes(new Uint8Array(testCase.code)));

				const result = await evm.call(
					defaultExecutionParams({
						to: contract,
						gas: testCase.gas ?? 1000000n,
					}),
				);

				expectExceptionalHalt(result);
			}
		});
	});
});
