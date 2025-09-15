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
} from "../../test/test-helpers.js";

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
		// TODO: Fix invalid opcode error message propagation in Zig
		it.todo("should handle invalid opcode", async () => {
			const contract = testAddress(100);
			// 0xfe is INVALID opcode
			const code = hex("0xfe");

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertFailure(result);
			expect(result.errorMessage).toBeDefined();
			expect(result.errorMessage?.toLowerCase()).toContain("invalid");
		});

		// TODO: Fix stack underflow not returning error in Zig
		it.todo("should handle stack underflow", async () => {
			const contract = testAddress(101);
			// ADD without enough values on stack
			const code = hex("0x6001"); // PUSH1 1, ADD (missing second operand)

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertFailure(result);
			expect(result.errorMessage?.toLowerCase()).toContain("stack");
		});

		// TODO: Fix stack overflow RuntimeError in Zig
		it.todo("should handle stack overflow", async () => {
			const contract = testAddress(102);

			// Push 1025 values (stack limit is 1024)
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

			assertFailure(result);
			expect(result.errorMessage?.toLowerCase()).toContain("stack");
		});

		// TODO: Fix out of gas error message in Zig
		it.todo("should handle out of gas", async () => {
			const contract = testAddress(103);
			// Infinite loop
			const code = hex("0x5b6000565b"); // JUMPDEST PUSH1 0 JUMP JUMPDEST

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
					gas: 1000n, // Very low gas
				}),
			);

			assertFailure(result);
			expect(result.gasLeft).toBe(0n);
			expect(result.errorMessage?.toLowerCase()).toContain("gas");
		});

		// TODO: Fix invalid jump causing null table entry error in Zig
		it.todo("should handle invalid jump destination", async () => {
			const contract = testAddress(104);
			// Jump to non-JUMPDEST
			const code = hex("0x600556"); // PUSH1 5 JUMP (no JUMPDEST at 5)

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertFailure(result);
			expect(result.errorMessage?.toLowerCase()).toContain("jump");
		});

		// TODO: Fix insufficient balance error message in Zig
		it.todo("should handle insufficient balance for value transfer", async () => {
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
			expect(result.errorMessage?.toLowerCase()).toContain("balance");
		});
	});

	describe("Static Call Violations", () => {
		// TODO: Fix static context violations detection in Zig
		it.todo("should error on state modification in static context", async () => {
			const contract = testAddress(200);
			// Try to SSTORE in static call
			const code = storeBytecode(0, 42);

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call({
				caller: testAddress(1),
				to: contract,
				value: U256.zero(),
				input: Bytes.empty(),
				gas: 1000000n,
				callType: CallType.STATICCALL,
			});

			assertFailure(result);
			expect(result.errorMessage?.toLowerCase()).toContain("static");
		});

		// TODO: Fix CREATE in static context detection in Zig
		it.todo("should error on CREATE in static context", async () => {
			const contract = testAddress(201);
			// Try to CREATE in static call
			const code = hex("0x60006000600f0"); // PUSH1 0 PUSH1 0 PUSH1 0 CREATE

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call({
				caller: testAddress(1),
				to: contract,
				value: U256.zero(),
				input: Bytes.empty(),
				gas: 1000000n,
				callType: CallType.STATICCALL,
			});

			assertFailure(result);
			expect(result.errorMessage?.toLowerCase()).toContain("static");
		});

		// TODO: Fix SELFDESTRUCT in static context detection in Zig
		it.todo("should error on SELFDESTRUCT in static context", async () => {
			const contract = testAddress(202);
			// Try to SELFDESTRUCT in static call
			const code = Bytes.concat([
				hex("0x73"),
				Bytes.fromBytes(testAddress(999).toBytes()),
				hex("0xff"),
			]);

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call({
				caller: testAddress(1),
				to: contract,
				value: U256.zero(),
				input: Bytes.empty(),
				gas: 1000000n,
				callType: CallType.STATICCALL,
			});

			assertFailure(result);
			expect(result.errorMessage?.toLowerCase()).toContain("static");
		});

		// TODO: Fix LOG in static context detection in Zig
		it.todo("should error on LOG in static context", async () => {
			const contract = testAddress(203);
			// Try to emit LOG0 in static call
			const code = hex("0x60006000a0"); // PUSH1 0 PUSH1 0 LOG0

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call({
				caller: testAddress(1),
				to: contract,
				value: U256.zero(),
				input: Bytes.empty(),
				gas: 1000000n,
				callType: CallType.STATICCALL,
			});

			assertFailure(result);
			expect(result.errorMessage?.toLowerCase()).toContain("static");
		});
	});

	describe("Revert Handling", () => {
		// TODO: Fix REVERT with no data handling in Zig
		it.todo("should handle REVERT with no data", async () => {
			const contract = testAddress(300);
			// PUSH1 0 PUSH1 0 REVERT
			const code = hex("0x600060fd");

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertFailure(result);
			expect(result.errorMessage?.toLowerCase()).toContain("revert");
			expect(result.output.isEmpty()).toBe(true);
		});

		// TODO: Fix REVERT with error message handling in Zig
		it.todo("should handle REVERT with error message", async () => {
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
			expect(result.errorMessage?.toLowerCase()).toContain("revert");

			// Check revert data
			const revertData = result.output.toBytes();
			const revertString = new TextDecoder().decode(revertData);
			expect(revertString).toBe(errorMsg);
		});

		// TODO: Fix nested revert propagation in Zig
		it.todo("should handle nested revert propagation", async () => {
			const contractA = testAddress(302);
			const contractB = testAddress(303);

			// Contract B reverts
			await evm.setCode(contractB, hex("0x600060fd"));

			// Contract A calls B
			const codeA: number[] = [];
			codeA.push(0x60, 0x00); // retSize
			codeA.push(0x60, 0x00); // retOffset
			codeA.push(0x60, 0x00); // argsSize
			codeA.push(0x60, 0x00); // argsOffset
			codeA.push(0x60, 0x00); // value
			codeA.push(0x73); // PUSH20
			codeA.push(...contractB.toBytes());
			codeA.push(0x5a); // GAS
			codeA.push(0xf1); // CALL

			// Check if call succeeded
			codeA.push(0x15); // ISZERO
			codeA.push(0x60, codeA.length + 4); // PUSH1 jump dest
			codeA.push(0x57); // JUMPI
			// Success path (shouldn't reach)
			codeA.push(0x60, 0x01); // PUSH1 1
			codeA.push(0x60, codeA.length + 5); // PUSH1 jump dest
			codeA.push(0x56); // JUMP
			// Failure path - also revert
			codeA.push(0x5b); // JUMPDEST
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

			assertFailure(result);
			expect(result.errorMessage?.toLowerCase()).toContain("revert");
		});
	});

	describe("Memory Errors", () => {
		it("should handle memory out of bounds read", async () => {
			const contract = testAddress(400);
			// Try to return huge amount of memory
			const code = hex("0x7fffffffff6000f3"); // PUSH32 max_value PUSH1 0 RETURN

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
					gas: 100000n,
				}),
			);

			assertFailure(result);
		});

		it("should handle excessive memory expansion", async () => {
			const contract = testAddress(401);
			// Try to write at extremely high memory offset
			const code = hex("0x60017fffffffff52"); // PUSH1 1 PUSH32 max_offset MSTORE

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
					gas: 100000n, // Limited gas
				}),
			);

			assertFailure(result);
			expect(result.gasLeft).toBe(0n); // Should run out of gas
		});

		it("should handle RETURNDATACOPY out of bounds", async () => {
			const contract = testAddress(402);
			// Try to copy more return data than available
			const code = hex("0x6064600060003e"); // PUSH1 100 PUSH1 0 PUSH1 0 RETURNDATACOPY

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertFailure(result);
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
		it.todo("should handle CREATE2 collision", async () => {
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
		it.todo("should handle CREATE with init code failure", async () => {
			const deployer = testAddress(502);

			// Init code that reverts
			const initCode = hex("0x600060fd"); // PUSH1 0 PUSH1 0 REVERT

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
		// TODO: Fix maximum call depth detection in Zig
		it.todo("should handle maximum call depth", async () => {
			// Create a chain of contracts that call each other
			// Evm call depth limit is 1024

			// This is a simplified test - in practice, reaching max depth
			// requires careful gas management
			const contract = testAddress(600);

			// Contract that calls itself recursively
			const code: number[] = [];

			// Call self
			code.push(0x60, 0x00); // retSize
			code.push(0x60, 0x00); // retOffset
			code.push(0x60, 0x00); // argsSize
			code.push(0x60, 0x00); // argsOffset
			code.push(0x60, 0x00); // value
			code.push(0x73); // PUSH20
			code.push(...contract.toBytes()); // self address
			code.push(0x61, 0x27, 0x10); // PUSH2 10000 (limited gas per call)
			code.push(0xf1); // CALL

			await evm.setCode(contract, Bytes.fromBytes(new Uint8Array(code)));

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
					gas: 10000000n, // High initial gas
				}),
			);

			// Should eventually fail due to depth or gas
			assertFailure(result);
		});
	});

	describe("Invalid Bytecode", () => {
		it("should handle truncated PUSH instruction", async () => {
			const contract = testAddress(700);
			// PUSH2 with only 1 byte of data
			const code = hex("0x6101"); // PUSH2 incomplete

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertFailure(result);
		});

		it("should handle code ending with incomplete instruction", async () => {
			const contract = testAddress(701);
			// Code that ends mid-instruction
			const code = hex("0x600160"); // PUSH1 1 PUSH1 (incomplete)

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertFailure(result);
		});

		// TODO: Fix jump to out of bounds causing null table entry in Zig
		it.todo("should handle jump to out of bounds", async () => {
			const contract = testAddress(702);
			// Jump beyond code size
			const code = hex("0x61ffff56"); // PUSH2 0xFFFF JUMP

			// Ensure account exists and set code
			await evm.setBalance(contract, U256.zero());
			await evm.setCode(contract, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contract,
				}),
			);

			assertFailure(result);
			expect(result.errorMessage?.toLowerCase()).toContain("jump");
		});
	});

	describe("Error Recovery", () => {
		// TODO: Fix state consistency after errors in Zig
		it.todo("should maintain state consistency after error", async () => {
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

			// B succeeds, C fails
			await evm.setCode(contractB, hex("0x6001600052602060f3")); // Return 1
			await evm.setCode(contractC, hex("0x600060fd")); // Revert

			// A calls B then C
			const codeA: number[] = [];

			// Call B (succeeds)
			codeA.push(0x60, 0x20); // retSize
			codeA.push(0x60, 0x00); // retOffset
			codeA.push(0x60, 0x00); // argsSize
			codeA.push(0x60, 0x00); // argsOffset
			codeA.push(0x60, 0x00); // value
			codeA.push(0x73); // PUSH20
			codeA.push(...contractB.toBytes());
			codeA.push(0x5a); // GAS
			codeA.push(0xf1); // CALL
			codeA.push(0x50); // POP

			// Store result from B
			codeA.push(0x60, 0x00); // PUSH1 0
			codeA.push(0x51); // MLOAD
			codeA.push(0x60, 0x00); // PUSH1 0
			codeA.push(0x55); // SSTORE

			// Call C (fails)
			codeA.push(0x60, 0x00); // retSize
			codeA.push(0x60, 0x00); // retOffset
			codeA.push(0x60, 0x00); // argsSize
			codeA.push(0x60, 0x00); // argsOffset
			codeA.push(0x60, 0x00); // value
			codeA.push(0x73); // PUSH20
			codeA.push(...contractC.toBytes());
			codeA.push(0x5a); // GAS
			codeA.push(0xf1); // CALL

			// If C fails, revert
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

			assertFailure(result);

			// Storage should not be modified (transaction reverted)
			const storage = await evm.getStorage(contractA, U256.zero());
			expect(storage.toBigInt()).toBe(0n);
		});
	});

	describe("Error Messages", () => {
		// TODO: Fix error message clarity with RuntimeError in Zig
		it.todo("should provide clear error messages", async () => {
			const testCases = [
				{
					name: "Stack underflow",
					code: hex("0x50"), // POP on empty stack
					expectedError: "stack",
				},
				{
					name: "Invalid opcode",
					code: hex("0xfe"), // INVALID
					expectedError: "invalid",
				},
				{
					name: "Out of gas",
					code: hex("0x5b6000565b"), // Infinite loop
					expectedError: "gas",
					gas: 1000n,
				},
				{
					name: "Invalid jump",
					code: hex("0x600a56"), // Jump to invalid destination
					expectedError: "jump",
				},
			];

			for (const testCase of testCases) {
				const contract = testAddress(900 + testCases.indexOf(testCase));
				await evm.setCode(contract, testCase.code);

				const result = await evm.call(
					defaultExecutionParams({
						to: contract,
						gas: testCase.gas || 1000000n,
					}),
				);

				assertFailure(result);
				expect(result.errorMessage).toBeDefined();
				expect(result.errorMessage?.toLowerCase()).toContain(
					testCase.expectedError,
				);
			}
		});
	});
});
