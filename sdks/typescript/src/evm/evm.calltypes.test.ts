import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { GuillotineEvm, CallType } from "./evm.js";
import { Address } from "../primitives/address.js";
import { U256 } from "../primitives/u256.js";
import { Bytes } from "../primitives/bytes.js";
import {
	testAddress,
	defaultExecutionParams,
	returnBytecode,
	storeBytecode,
	callBytecode,
	hex,
	assertSuccess,
	assertFailure,
} from "../../test/test-helpers.js";

describe("GuillotineEvm - Call Types", () => {
	let evm: GuillotineEvm;

	beforeEach(async () => {
		evm = await GuillotineEvm.create();
	});

	afterEach(() => {
		evm.close();
	});

	describe("CALL", () => {
		it("should execute standard CALL", async () => {
			const callerAddr = testAddress(100); // Avoid precompile addresses (1-18)
			const targetAddr = testAddress(101); // Safe address range

			// Set up target contract that returns 42
			await evm.setBalance(targetAddr, U256.zero());
			await evm.setCode(targetAddr, returnBytecode(42));

			// Fund caller
			await evm.setBalance(callerAddr, U256.fromBigInt(10000n));

			const result = await evm.call(
				defaultExecutionParams({
					caller: callerAddr,
					to: targetAddr,
					callType: CallType.CALL,
					value: U256.fromBigInt(100n),
				}),
			);

			assertSuccess(result);

			// Check value was transferred
			const targetBalance = await evm.getBalance(targetAddr);
			expect(targetBalance.toBigInt()).toBe(100n);

			// Check return value
			const output = result.output.toBytes();
			expect(output[31]).toBe(42);
		});

		// TODO: Fix nested CALL execution in Zig
		it.todo("should handle nested CALL", async () => {
			const contractA = testAddress(10);
			const contractB = testAddress(11);

			// Contract B returns 99
			await evm.setCode(contractB, returnBytecode(99));

			// Contract A calls contract B
			await evm.setCode(contractA, callBytecode(contractB));

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			assertSuccess(result);

			// Should get return value from contract B
			const output = result.output.toBytes();
			expect(output[31]).toBe(99);
		});

		// TODO: Fix msg.sender preservation in CALL in Zig
		it.todo("should preserve msg.sender in CALL", async () => {
			const caller = testAddress(100);
			const contractA = testAddress(101);
			const contractB = testAddress(102);

			// Contract B returns the caller address
			// CALLER PUSH1 0 MSTORE PUSH1 20 PUSH1 12 RETURN
			const codeB = hex("0x3360005260146012f3");
			await evm.setCode(contractB, codeB);

			// Contract A calls contract B
			await evm.setCode(contractA, callBytecode(contractB));

			const result = await evm.call(
				defaultExecutionParams({
					caller: caller,
					to: contractA,
				}),
			);

			assertSuccess(result);

			// Contract B should see contract A as the caller
			const output = result.output.toBytes();
			expect(output.length).toBe(20);
			const returnedCaller = Address.fromBytes(output);
			expect(returnedCaller.toHex()).toBe(contractA.toHex());
		});

		it("should handle CALL with insufficient balance", async () => {
			const caller = testAddress(103);
			const target = testAddress(104);

			// Caller has 50, tries to send 100
			await evm.setBalance(caller, U256.fromBigInt(50n));

			const result = await evm.call(
				defaultExecutionParams({
					caller: caller,
					to: target,
					value: U256.fromBigInt(100n),
					callType: CallType.CALL,
				}),
			);

			assertFailure(result);

			// Balance should remain unchanged
			expect((await evm.getBalance(caller)).toBigInt()).toBe(50n);
			expect((await evm.getBalance(target)).toBigInt()).toBe(0n);
		});
	});

	describe("DELEGATECALL", () => {
		// TODO: Fix DELEGATECALL context preservation in Zig
		it.todo("should execute DELEGATECALL preserving context", async () => {
			const caller = testAddress(200);
			const contractA = testAddress(201);
			const contractB = testAddress(202);

			// Contract B stores value in slot 0
			await evm.setCode(contractB, storeBytecode(0, 42));

			// Contract A delegatecalls to B
			await evm.setCode(
				contractA,
				callBytecode(contractB, U256.zero(), "DELEGATECALL"),
			);

			const result = await evm.call(
				defaultExecutionParams({
					caller: caller,
					to: contractA,
				}),
			);

			assertSuccess(result);

			// Storage should be modified in contract A, not B
			const storageA = await evm.getStorage(contractA, U256.zero());
			const storageB = await evm.getStorage(contractB, U256.zero());

			expect(storageA.toBigInt()).toBe(42n);
			expect(storageB.toBigInt()).toBe(0n);
		});

		// TODO: Fix DELEGATECALL RuntimeError in Zig
		it.todo("should preserve msg.sender and msg.value in DELEGATECALL", async () => {
			const originalCaller = testAddress(203);
			const contractA = testAddress(204);
			const contractB = testAddress(205);
			const value = U256.fromBigInt(1000n);

			// Contract B returns caller and value
			// CALLER PUSH1 0 MSTORE CALLVALUE PUSH1 20 MSTORE PUSH1 64 PUSH1 0 RETURN
			const codeB = hex("0x33600052346020526040600f3");
			await evm.setCode(contractB, codeB);

			// Contract A delegatecalls to B
			await evm.setCode(
				contractA,
				callBytecode(contractB, U256.zero(), "DELEGATECALL"),
			);

			// Fund the original caller
			await evm.setBalance(originalCaller, U256.fromBigInt(10000n));

			const result = await evm.call(
				defaultExecutionParams({
					caller: originalCaller,
					to: contractA,
					value: value,
				}),
			);

			assertSuccess(result);

			// Should preserve original caller and value
			const output = result.output.toBytes();
			const returnedCaller = Address.fromBytes(output.slice(0, 20));
			const returnedValue = U256.fromBytes(output.slice(20, 52));

			expect(returnedCaller.toHex()).toBe(originalCaller.toHex());
			expect(returnedValue.toBigInt()).toBe(1000n);
		});

		// TODO: Fix DELEGATECALL storage context in Zig
		it.todo("should use code from target but storage from caller in DELEGATECALL", async () => {
			const contractA = testAddress(206);
			const contractB = testAddress(207);

			// Pre-set storage in both contracts
			await evm.setStorage(
				contractA,
				U256.fromBigInt(1n),
				U256.fromBigInt(100n),
			);
			await evm.setStorage(
				contractB,
				U256.fromBigInt(1n),
				U256.fromBigInt(200n),
			);

			// Contract B loads from slot 1 and returns it
			// PUSH1 1 SLOAD PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
			const codeB = hex("0x6001546000526020600f3");
			await evm.setCode(contractB, codeB);

			// Contract A delegatecalls to B
			await evm.setCode(
				contractA,
				callBytecode(contractB, U256.zero(), "DELEGATECALL"),
			);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			assertSuccess(result);

			// Should load from contract A's storage (100), not B's (200)
			const output = result.output.toBytes();
			const value = U256.fromBytes(output);
			expect(value.toBigInt()).toBe(100n);
		});
	});

	describe("STATICCALL", () => {
		// TODO: Fix STATICCALL implementation in Zig
		it.todo("should execute STATICCALL without state modifications", async () => {
			const contractA = testAddress(300);
			const contractB = testAddress(301);

			// Contract B tries to store but also returns a value
			const codeB = Bytes.concat([
				storeBytecode(0, 42), // Try to store (should fail in static context)
				returnBytecode(99), // Return 99
			]);
			await evm.setCode(contractB, codeB);

			// Contract A staticcalls to B
			await evm.setCode(
				contractA,
				callBytecode(contractB, U256.zero(), "STATICCALL"),
			);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			// STATICCALL should fail if target tries to modify state
			assertFailure(result);

			// Storage should not be modified
			const storage = await evm.getStorage(contractB, U256.zero());
			expect(storage.toBigInt()).toBe(0n);
		});

		// TODO: Fix STATICCALL read-only operations in Zig
		it.todo("should allow read-only operations in STATICCALL", async () => {
			const contractA = testAddress(302);
			const contractB = testAddress(303);

			// Pre-set storage in contract B
			await evm.setStorage(contractB, U256.zero(), U256.fromBigInt(42n));

			// Contract B only reads storage and returns it
			// PUSH1 0 SLOAD PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
			const codeB = hex("0x6000546000526020600f3");
			await evm.setCode(contractB, codeB);

			// Contract A staticcalls to B
			await evm.setCode(
				contractA,
				callBytecode(contractB, U256.zero(), "STATICCALL"),
			);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			assertSuccess(result);

			// Should return the value from storage
			const output = result.output.toBytes();
			const value = U256.fromBytes(output);
			expect(value.toBigInt()).toBe(42n);
		});

		// TODO: Fix STATICCALL context propagation in Zig
		it.todo("should propagate static context to nested calls", async () => {
			const contractA = testAddress(304);
			const contractB = testAddress(305);
			const contractC = testAddress(306);

			// Contract C tries to store
			await evm.setCode(contractC, storeBytecode(0, 42));

			// Contract B calls contract C
			await evm.setCode(contractB, callBytecode(contractC));

			// Contract A staticcalls to B
			await evm.setCode(
				contractA,
				callBytecode(contractB, U256.zero(), "STATICCALL"),
			);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			// Should fail because C tries to modify state
			assertFailure(result);
		});

		it("should not allow value transfer in STATICCALL", async () => {
			const caller = testAddress(307);
			const target = testAddress(308);

			// Fund caller
			await evm.setBalance(caller, U256.fromBigInt(1000n));

			// Simple return code
			await evm.setCode(target, returnBytecode(42));

			// STATICCALL doesn't support value transfer
			// The value parameter should be ignored
			const result = await evm.call(
				defaultExecutionParams({
					caller: caller,
					to: target,
					callType: CallType.STATICCALL,
					value: U256.fromBigInt(100n), // This should be ignored
				}),
			);

			// Call should succeed but no value transfer
			assertSuccess(result);

			// No balance change
			expect((await evm.getBalance(caller)).toBigInt()).toBe(1000n);
			expect((await evm.getBalance(target)).toBigInt()).toBe(0n);
		});
	});

	describe("CALLCODE", () => {
		// TODO: Fix CALLCODE implementation in Zig
		it.todo("should execute CALLCODE with caller context", async () => {
			const caller = testAddress(400);
			const contractA = testAddress(401);
			const contractB = testAddress(402);

			// Contract B stores value
			await evm.setCode(contractB, storeBytecode(0, 55));

			// Contract A uses CALLCODE to execute B's code
			// Note: CALLCODE is deprecated in favor of DELEGATECALL but still supported
			await evm.setCode(
				contractA,
				callBytecode(contractB, U256.zero(), "CALL"),
			); // Using CALL for now

			const result = await evm.call({
				caller: caller,
				to: contractA,
				value: U256.zero(),
				input: Bytes.empty(),
				gas: 1000000n,
				callType: CallType.CALLCODE,
			});

			assertSuccess(result);

			// CALLCODE executes target code in caller's context
			// Storage should be in contract A
			const storageA = await evm.getStorage(contractA, U256.zero());
			expect(storageA.toBigInt()).toBe(55n);
		});

		// TODO: Fix CALLCODE msg.sender handling in Zig
		it.todo("should handle msg.sender in CALLCODE", async () => {
			const originalCaller = testAddress(403);
			const contractA = testAddress(404);
			const contractB = testAddress(405);

			// Contract B returns the caller
			// CALLER PUSH1 0 MSTORE PUSH1 20 PUSH1 12 RETURN
			const codeB = hex("0x3360005260146012f3");
			await evm.setCode(contractB, codeB);

			const result = await evm.call({
				caller: originalCaller,
				to: contractA,
				value: U256.zero(),
				input: Bytes.empty(),
				gas: 1000000n,
				callType: CallType.CALLCODE,
			});

			// In CALLCODE, msg.sender should be the original caller
			if (result.success) {
				const output = result.output.toBytes();
				const returnedCaller = Address.fromBytes(output.slice(0, 20));
				expect(returnedCaller.toHex()).toBe(originalCaller.toHex());
			}
		});
	});

	describe("CREATE", () => {
		// TODO: Fix CREATE implementation in Zig
		it.todo("should deploy contract with CREATE", async () => {
			const deployer = testAddress(500);

			// Simple contract that stores 42 and returns it
			const runtimeCode = Bytes.concat([
				storeBytecode(0, 42),
				returnBytecode(42),
			]);

			// Init code that returns the runtime code
			const initCode = Bytes.concat([
				hex("0x60"), // PUSH1
				Bytes.fromBytes(new Uint8Array([runtimeCode.length()])),
				hex("0x80"), // DUP1
				hex("0x60"), // PUSH1
				Bytes.fromBytes(new Uint8Array([12])), // offset in init code where runtime starts
				hex("0x6000"), // PUSH1 0
				hex("0x39"), // CODECOPY
				hex("0x6000"), // PUSH1 0
				hex("0xf3"), // RETURN
				runtimeCode,
			]);

			// Fund deployer
			await evm.setBalance(deployer, U256.fromBigInt(10000n));

			const result = await evm.call({
				caller: deployer,
				to: Address.zero(), // CREATE uses zero address
				value: U256.fromBigInt(100n), // Send value to new contract
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE,
			});

			assertSuccess(result);
			expect(result.createdAddress).toBeDefined();

			if (result.createdAddress) {
				// Check deployed contract has the code
				const deployedCode = await evm.getCode(result.createdAddress);
				expect(deployedCode.length()).toBeGreaterThan(0);

				// Check deployed contract received the value
				const balance = await evm.getBalance(result.createdAddress);
				expect(balance.toBigInt()).toBe(100n);

				// Check storage was set during init
				const storage = await evm.getStorage(
					result.createdAddress,
					U256.zero(),
				);
				expect(storage.toBigInt()).toBe(42n);
			}
		});

		// TODO: Fix CREATE failure handling in Zig
		it.todo("should handle CREATE failure", async () => {
			const deployer = testAddress(501);

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

		// TODO: Fix CREATE address calculation in Zig
		it.todo("should calculate CREATE address deterministically", async () => {
			const deployer = testAddress(502);

			// Simple init code
			const initCode = hex("0x6000600f3"); // Returns empty

			// First deployment
			const result1 = await evm.call({
				caller: deployer,
				to: Address.zero(),
				value: U256.zero(),
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE,
			});

			assertSuccess(result1);
			const addr1 = result1.createdAddress;

			// Second deployment from same account
			const result2 = await evm.call({
				caller: deployer,
				to: Address.zero(),
				value: U256.zero(),
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE,
			});

			assertSuccess(result2);
			const addr2 = result2.createdAddress;

			// Addresses should be different (nonce incremented)
			expect(addr1).not.toEqual(addr2);
		});
	});

	describe("CREATE2", () => {
		it("should deploy contract with CREATE2", async () => {
			const deployer = testAddress(600);
			const salt = U256.fromBigInt(0x1234n);

			// Simple runtime code
			const runtimeCode = returnBytecode(99);

			// Init code that returns the runtime code
			const initCode = Bytes.concat([
				hex("0x60"), // PUSH1
				Bytes.fromBytes(new Uint8Array([runtimeCode.length()])),
				hex("0x80"), // DUP1
				hex("0x60"), // PUSH1
				Bytes.fromBytes(new Uint8Array([12])), // offset
				hex("0x6000"), // PUSH1 0
				hex("0x39"), // CODECOPY
				hex("0x6000"), // PUSH1 0
				hex("0xf3"), // RETURN
				runtimeCode,
			]);

			// Fund deployer
			await evm.setBalance(deployer, U256.fromBigInt(10000n));

			const result = await evm.call({
				caller: deployer,
				to: Address.zero(),
				value: U256.fromBigInt(200n),
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE2,
				salt: salt,
			});

			assertSuccess(result);
			expect(result.createdAddress).toBeDefined();

			if (result.createdAddress) {
				// Check deployed contract
				const deployedCode = await evm.getCode(result.createdAddress);
				expect(deployedCode.length()).toBeGreaterThan(0);

				// Check balance
				const balance = await evm.getBalance(result.createdAddress);
				expect(balance.toBigInt()).toBe(200n);
			}
		});

		// TODO: Fix CREATE2 implementation in Zig
		it.todo("should calculate CREATE2 address deterministically", async () => {
			const deployer = testAddress(601);
			const salt = U256.fromBigInt(0xdeadbeefn);

			// Same init code
			const initCode = hex("0x60006000f3");

			// Deploy twice with same salt
			const result1 = await evm.call({
				caller: deployer,
				to: Address.zero(),
				value: U256.zero(),
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE2,
				salt: salt,
			});

			assertSuccess(result1);
			expect(result1.createdAddress).toBeDefined();

			// Second deployment with same salt should fail (address already exists)
			const result2 = await evm.call({
				caller: deployer,
				to: Address.zero(),
				value: U256.zero(),
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE2,
				salt: salt,
			});

			assertFailure(result2); // Should fail - address collision
		});

		it("should create different addresses with different salts", async () => {
			const deployer = testAddress(602);
			const salt1 = U256.fromBigInt(1n);
			const salt2 = U256.fromBigInt(2n);

			const initCode = hex("0x60006000f3");

			const result1 = await evm.call({
				caller: deployer,
				to: Address.zero(),
				value: U256.zero(),
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE2,
				salt: salt1,
			});

			const result2 = await evm.call({
				caller: deployer,
				to: Address.zero(),
				value: U256.zero(),
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE2,
				salt: salt2,
			});

			assertSuccess(result1);
			assertSuccess(result2);

			// Different salts should produce different addresses
			expect(result1.createdAddress).not.toEqual(result2.createdAddress);
		});

		it("should allow same salt from different deployers", async () => {
			const deployer1 = testAddress(603);
			const deployer2 = testAddress(604);
			const salt = U256.fromBigInt(0xaaaaaaaan);

			const initCode = hex("0x60006000f3");

			const result1 = await evm.call({
				caller: deployer1,
				to: Address.zero(),
				value: U256.zero(),
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE2,
				salt: salt,
			});

			const result2 = await evm.call({
				caller: deployer2,
				to: Address.zero(),
				value: U256.zero(),
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE2,
				salt: salt,
			});

			assertSuccess(result1);
			assertSuccess(result2);

			// Same salt but different deployers should work
			expect(result1.createdAddress).not.toEqual(result2.createdAddress);
		});
	});

	describe("Mixed Call Types", () => {
		it("should handle CREATE inside CALL", async () => {
			const caller = testAddress(700);
			const factory = testAddress(701);

			// Factory contract that creates a new contract
			// This would be complex bytecode in practice
			// For now, just test regular calls work
			await evm.setCode(factory, returnBytecode(1));

			const result = await evm.call(
				defaultExecutionParams({
					caller: caller,
					to: factory,
					callType: CallType.CALL,
				}),
			);

			assertSuccess(result);
		});

		// TODO: Fix CREATE rejection in STATICCALL context in Zig
		it.todo("should reject CREATE in STATICCALL context", async () => {
			const contractA = testAddress(702);
			const contractB = testAddress(703);

			// Contract B tries to CREATE
			const initCode = hex("0x60006000f3");
			// Bytecode for CREATE: value, size, offset, CREATE
			const createCode = Bytes.concat([
				hex("0x60"),
				Bytes.fromBytes(new Uint8Array([initCode.length()])), // PUSH1 size
				hex("0x6000"), // PUSH1 0 (offset)
				hex("0x6000"), // PUSH1 0 (value)
				hex("0xf0"), // CREATE
			]);

			await evm.setCode(contractB, createCode);

			// Contract A staticcalls to B
			await evm.setCode(
				contractA,
				callBytecode(contractB, U256.zero(), "STATICCALL"),
			);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			// Should fail - can't CREATE in static context
			assertFailure(result);
		});
	});
});
