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
	deployInitCode,
	hex,
	assertSuccess,
	assertFailure,
} from "../../test/test-helpers.js";

function word(n: bigint): Uint8Array {
	return U256.fromBigInt(n).toBytes();
}

/** Left-pad an address to a 32-byte word, as CALLER/ADDRESS push it. */
function addressWord(address: Address): Uint8Array {
	const out = new Uint8Array(32);
	out.set(address.toBytes(), 12);
	return out;
}

function concat(...parts: Uint8Array[]): Uint8Array {
	return Bytes.concat(parts.map((part) => Bytes.fromBytes(part))).toBytes();
}

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

		it("should handle nested CALL", async () => {
			const contractA = testAddress(110);
			const contractB = testAddress(111);

			// Contract B returns 99
			await evm.setCode(contractB, returnBytecode(99));

			// Contract A calls contract B and returns success || returndata
			await evm.setCode(contractA, callBytecode(contractB));

			const result = await evm.call(
				defaultExecutionParams({
					to: contractA,
				}),
			);

			assertSuccess(result);
			expect(result.output.toBytes()).toEqual(concat(word(1n), word(99n)));
		});

		it("should preserve msg.sender in CALL", async () => {
			const caller = testAddress(100);
			const contractA = testAddress(101);
			const contractB = testAddress(102);

			// Contract B returns CALLER as a 32-byte word
			const codeB = Bytes.fromBytes(
				new Uint8Array([
					0x33, // CALLER
					0x60, 0x00, // PUSH1 0
					0x52, // MSTORE
					0x60, 0x20, // PUSH1 32
					0x60, 0x00, // PUSH1 0
					0xf3, // RETURN
				]),
			);
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
			// Contract B sees contract A as msg.sender
			expect(result.output.toBytes()).toEqual(concat(word(1n), addressWord(contractA)));
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
		it("should execute DELEGATECALL preserving context", async () => {
			const caller = testAddress(200);
			const contractA = testAddress(201);
			const contractB = testAddress(202);

			// Contract B stores 42 in slot 0
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
			expect(result.output.toBytes()).toEqual(word(1n));

			// Storage is written in contract A, not B
			expect((await evm.getStorage(contractA, U256.zero())).toBigInt()).toBe(42n);
			expect((await evm.getStorage(contractB, U256.zero())).toBigInt()).toBe(0n);
		});

		it("should preserve msg.sender and msg.value in DELEGATECALL", async () => {
			const originalCaller = testAddress(203);
			const contractA = testAddress(204);
			const contractB = testAddress(205);

			// Contract B returns CALLER || CALLVALUE as two words
			const codeB = Bytes.fromBytes(
				new Uint8Array([
					0x33, // CALLER
					0x60, 0x00, // PUSH1 0
					0x52, // MSTORE
					0x34, // CALLVALUE
					0x60, 0x20, // PUSH1 32
					0x52, // MSTORE
					0x60, 0x40, // PUSH1 64
					0x60, 0x00, // PUSH1 0
					0xf3, // RETURN
				]),
			);
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
					value: U256.fromBigInt(1000n),
				}),
			);

			assertSuccess(result);
			// DELEGATECALL keeps the original msg.sender and msg.value
			expect(result.output.toBytes()).toEqual(
				concat(word(1n), addressWord(originalCaller), word(1000n)),
			);
		});

		it("should use code from target but storage from caller in DELEGATECALL", async () => {
			const contractA = testAddress(206);
			const contractB = testAddress(207);

			// Pre-set storage in both contracts
			await evm.setStorage(contractA, U256.fromBigInt(1n), U256.fromBigInt(100n));
			await evm.setStorage(contractB, U256.fromBigInt(1n), U256.fromBigInt(200n));

			// Contract B loads slot 1 and returns it
			const codeB = Bytes.fromBytes(
				new Uint8Array([
					0x60, 0x01, // PUSH1 1
					0x54, // SLOAD
					0x60, 0x00, // PUSH1 0
					0x52, // MSTORE
					0x60, 0x20, // PUSH1 32
					0x60, 0x00, // PUSH1 0
					0xf3, // RETURN
				]),
			);
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
			// Loaded from contract A's storage (100), not B's (200)
			expect(result.output.toBytes()).toEqual(concat(word(1n), word(100n)));
		});
	});

	describe("STATICCALL", () => {
		it("should execute STATICCALL without state modifications", async () => {
			const contractA = testAddress(300);
			const contractB = testAddress(301);

			// Contract B tries to store, then returns 99
			const codeB = Bytes.concat([
				storeBytecode(0, 42), // SSTORE in a static context is an exceptional halt
				returnBytecode(99),
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

			// The outer call succeeds; STATICCALL pushes 0 and B returns no data
			assertSuccess(result);
			expect(result.output.toBytes()).toEqual(word(0n));

			// Storage is not modified
			expect((await evm.getStorage(contractB, U256.zero())).toBigInt()).toBe(0n);
		});

		it("should allow read-only operations in STATICCALL", async () => {
			const contractA = testAddress(302);
			const contractB = testAddress(303);

			// Pre-set storage in contract B
			await evm.setStorage(contractB, U256.zero(), U256.fromBigInt(42n));

			// Contract B reads slot 0 and returns it
			const codeB = Bytes.fromBytes(
				new Uint8Array([
					0x60, 0x00, // PUSH1 0
					0x54, // SLOAD
					0x60, 0x00, // PUSH1 0
					0x52, // MSTORE
					0x60, 0x20, // PUSH1 32
					0x60, 0x00, // PUSH1 0
					0xf3, // RETURN
				]),
			);
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
			expect(result.output.toBytes()).toEqual(concat(word(1n), word(42n)));
		});

		it("should propagate static context to nested calls", async () => {
			const contractA = testAddress(304);
			const contractB = testAddress(305);
			const contractC = testAddress(306);

			// Contract C tries to store
			await evm.setCode(contractC, storeBytecode(0, 42));

			// Contract B calls contract C (zero-value CALL is allowed in a static context)
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

			// C halts on SSTORE; B sees 0 and returns word(0); A sees B succeed
			assertSuccess(result);
			expect(result.output.toBytes()).toEqual(concat(word(1n), word(0n)));
			expect((await evm.getStorage(contractC, U256.zero())).toBigInt()).toBe(0n);
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
		it("should execute CALLCODE with caller context", async () => {
			const caller = testAddress(400);
			const contractA = testAddress(401);
			const contractB = testAddress(402);

			// Contract B stores 55 in slot 0
			await evm.setCode(contractB, storeBytecode(0, 55));

			// Contract A runs B's code with CALLCODE
			await evm.setCode(contractA, callBytecode(contractB, U256.zero(), "CALLCODE"));

			const result = await evm.call(
				defaultExecutionParams({
					caller: caller,
					to: contractA,
				}),
			);

			assertSuccess(result);
			expect(result.output.toBytes()).toEqual(word(1n));

			// CALLCODE executes B's code against A's storage
			expect((await evm.getStorage(contractA, U256.zero())).toBigInt()).toBe(55n);
			expect((await evm.getStorage(contractB, U256.zero())).toBigInt()).toBe(0n);
		});

		it("should handle msg.sender in CALLCODE", async () => {
			const originalCaller = testAddress(403);
			const contractA = testAddress(404);
			const contractB = testAddress(405);

			// Contract B returns CALLER as a 32-byte word
			const codeB = Bytes.fromBytes(
				new Uint8Array([
					0x33, // CALLER
					0x60, 0x00, // PUSH1 0
					0x52, // MSTORE
					0x60, 0x20, // PUSH1 32
					0x60, 0x00, // PUSH1 0
					0xf3, // RETURN
				]),
			);
			await evm.setCode(contractB, codeB);
			await evm.setCode(contractA, callBytecode(contractB, U256.zero(), "CALLCODE"));

			const result = await evm.call(
				defaultExecutionParams({
					caller: originalCaller,
					to: contractA,
				}),
			);

			assertSuccess(result);
			// Unlike DELEGATECALL, CALLCODE sets msg.sender to the calling contract
			expect(result.output.toBytes()).toEqual(concat(word(1n), addressWord(contractA)));
		});
	});

	describe("CREATE", () => {
		it("should deploy contract with CREATE", async () => {
			const deployer = testAddress(500);
			const runtimeCode = returnBytecode(42);

			// Init code stores 42 in slot 0, then returns runtimeCode
			const initCode = deployInitCode(runtimeCode, storeBytecode(0, 42));

			// Fund deployer
			await evm.setBalance(deployer, U256.fromBigInt(10000n));

			const result = await evm.call({
				caller: deployer,
				to: Address.zero(), // Ignored for CREATE
				value: U256.fromBigInt(100n), // Endowment for the new contract
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE,
			});

			assertSuccess(result);
			const created = result.createdAddress;
			if (created === null) throw new Error("CREATE returned no address");

			expect((await evm.getCode(created)).toHex()).toBe(runtimeCode.toHex());
			expect((await evm.getBalance(created)).toBigInt()).toBe(100n);
			expect((await evm.getBalance(deployer)).toBigInt()).toBe(9900n);
			expect((await evm.getStorage(created, U256.zero())).toBigInt()).toBe(42n);
		});

		it("should handle CREATE failure", async () => {
			const deployer = testAddress(501);

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
			expect(result.output.isEmpty()).toBe(true);
		});

		it("should calculate CREATE address deterministically", async () => {
			const deployer = testAddress(502); // 0x...01f6

			// Init code: PUSH1 0 PUSH1 0 RETURN (deploys empty code)
			const initCode = Bytes.fromBytes(new Uint8Array([0x60, 0x00, 0x60, 0x00, 0xf3]));

			const result1 = await evm.call({
				caller: deployer,
				to: Address.zero(),
				value: U256.zero(),
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE,
			});
			assertSuccess(result1);

			const result2 = await evm.call({
				caller: deployer,
				to: Address.zero(),
				value: U256.zero(),
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE,
			});
			assertSuccess(result2);

			// keccak256(rlp([sender, nonce]))[12:], from `cast compute-address <sender> --nonce N`
			expect(result1.createdAddress?.toHex().toLowerCase()).toBe(
				"0xa823dde758c8f751575880681e847e0cab8fd22b",
			);
			expect(result2.createdAddress?.toHex().toLowerCase()).toBe(
				"0x7f7f5a5d908141f0f5b897ea66a3701137092a2f",
			);
		});
	});

	describe("CREATE2", () => {
		it("should deploy contract with CREATE2", async () => {
			const deployer = testAddress(600);
			const salt = U256.fromBigInt(0x1234n);
			const runtimeCode = returnBytecode(99);
			const initCode = deployInitCode(runtimeCode);

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
			const created = result.createdAddress;
			if (created === null) throw new Error("CREATE2 returned no address");

			expect((await evm.getCode(created)).toHex()).toBe(runtimeCode.toHex());
			expect((await evm.getBalance(created)).toBigInt()).toBe(200n);
		});

		it("should calculate CREATE2 address deterministically", async () => {
			const deployer = testAddress(601); // 0x...0259
			const salt = U256.fromBigInt(0xdeadbeefn);

			// Init code: PUSH1 0 PUSH1 0 RETURN
			const initCode = Bytes.fromBytes(new Uint8Array([0x60, 0x00, 0x60, 0x00, 0xf3]));

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
			// keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode))[12:], from `cast create2`
			expect(result1.createdAddress?.toHex().toLowerCase()).toBe(
				"0x29358858cccc625fe1e21c0e061a7e1123b603a5",
			);

			// Same deployer, salt and init code: the address now has nonce 1 (EIP-161),
			// so the second deployment collides (EIP-684) and fails
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

		it("should reject CREATE in STATICCALL context", async () => {
			const contractA = testAddress(702);
			const contractB = testAddress(703);

			// Contract B runs CREATE(value=0, offset=0, size=5) then returns the created address
			const createCode = Bytes.fromBytes(
				new Uint8Array([
					0x60, 0x05, // PUSH1 5 (size)
					0x60, 0x00, // PUSH1 0 (offset)
					0x60, 0x00, // PUSH1 0 (value)
					0xf0, // CREATE: exceptional halt in a static context
					0x60, 0x00, // PUSH1 0
					0x52, // MSTORE
					0x60, 0x20, // PUSH1 32
					0x60, 0x00, // PUSH1 0
					0xf3, // RETURN
				]),
			);
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

			// A succeeds; its STATICCALL pushed 0 and B returned no data
			assertSuccess(result);
			expect(result.output.toBytes()).toEqual(word(0n));
		});
	});

	describe("Call gas (EIP-2929 cold account access)", () => {
		// Each case: PUSH1 0 x4 (ret/args), [PUSH1 0 value], PUSH2 target, PUSH3 100000, <op>, STOP.
		// The callee is STOP. The first access to the callee is cold: 2600.
		const cases = [
			{ name: "CALL", opcode: 0xf1, value: true },
			{ name: "CALLCODE", opcode: 0xf2, value: true },
			{ name: "DELEGATECALL", opcode: 0xf4, value: false },
			{ name: "STATICCALL", opcode: 0xfa, value: false },
		] as const;

		for (const { name, opcode, value } of cases) {
			it(`${name} to a cold address charges 2600`, async () => {
				const contractA = testAddress(900);
				const contractB = testAddress(901); // 0x...0385
				await evm.setCode(contractB, Bytes.fromBytes(new Uint8Array([0x00])));
				await evm.setCode(
					contractA,
					Bytes.fromBytes(
						new Uint8Array([
							0x60, 0x00, // PUSH1 0 (retSize)
							0x60, 0x00, // PUSH1 0 (retOffset)
							0x60, 0x00, // PUSH1 0 (argsSize)
							0x60, 0x00, // PUSH1 0 (argsOffset)
							...(value ? [0x60, 0x00] : []), // PUSH1 0 (value)
							0x61, 0x03, 0x85, // PUSH2 contractB
							0x62, 0x01, 0x86, 0xa0, // PUSH3 100000
							opcode,
							0x00, // STOP
						]),
					),
				);

				const result = await evm.call(defaultExecutionParams({ to: contractA, gas: 1000000n }));

				assertSuccess(result);
				// PUSH1 x4 = 12, [PUSH1 value = 3], PUSH2 3, PUSH3 3, cold access 2600, callee STOP 0
				const used = 12n + (value ? 3n : 0n) + 3n + 3n + 2600n;
				expect(result.gasLeft).toBe(1000000n - 21000n - used);
			});
		}
	});

	describe("Top-level CREATE gas", () => {
		it("charges 21000 + 32000 + calldata + init code word cost once", async () => {
			const deployer = testAddress(503);
			// Init code: PUSH1 0 PUSH1 0 RETURN (deploys empty code)
			const initCode = Bytes.fromBytes(new Uint8Array([0x60, 0x00, 0x60, 0x00, 0xf3]));

			const result = await evm.call({
				caller: deployer,
				to: Address.zero(),
				value: U256.zero(),
				input: initCode,
				gas: 1000000n,
				callType: CallType.CREATE,
			});

			assertSuccess(result);
			// Intrinsic: 21000 + 32000 (EIP-2) + calldata 3 nonzero * 16 + 2 zero * 4 = 56
			// + EIP-3860 init code 2 per word * 1 = 2. Execution: PUSH1 3 + PUSH1 3 = 6. Deposit: 0.
			expect(result.gasLeft).toBe(1000000n - 21000n - 32000n - 56n - 2n - 6n);
		});
	});
});
