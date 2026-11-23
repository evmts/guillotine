import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { GuillotineEvm } from "./evm.js";
import { Address } from "../primitives/address.js";
import { U256 } from "../primitives/u256.js";
import { Bytes } from "../primitives/bytes.js";
import {
	testAddress,
	defaultExecutionParams,
	returnBytecode,
	addBytecode,
	storeBytecode,
	revertBytecode,
	infiniteLoopBytecode,
	hex,
	assertSuccess,
	assertFailure,
} from "../../test/test-helpers.js";

describe("GuillotineEvm - Execution", () => {
	let evm: GuillotineEvm;

	beforeEach(async () => {
		evm = await GuillotineEvm.create();
	});

	afterEach(() => {
		evm.close();
	});

	describe("Basic Execution", () => {
		it("should execute simple bytecode that returns a value", async () => {
			const code = returnBytecode(42);
			const contractAddr = testAddress(100);

			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);
			expect(result.gasLeft).toBeGreaterThan(0n);
			expect(result.gasLeft).toBeLessThan(1000000n);

			// The return value should be 42 padded to 32 bytes
			const output = result.output.toBytes();
			expect(output.length).toBe(32);
			expect(output[31]).toBe(42);
		});

		it("should execute bytecode that performs addition", async () => {
			const code = addBytecode();
			const contractAddr = testAddress(101);

			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);

			// 2 + 3 = 5
			const output = result.output.toBytes();
			expect(output.length).toBe(32);
			expect(output[31]).toBe(5);
		});

		it("should handle empty bytecode", async () => {
			const contractAddr = testAddress(102);

			// Initialize the account with zero balance and empty code to ensure it exists
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, Bytes.empty());

			// No code set (empty)
			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);
			expect(result.output.isEmpty()).toBe(true);
			expect(result.gasLeft).toBe(979000n); // 21000 intrinsic gas deducted (1000000 - 21000)
		});

		it("should execute bytecode with input data", async () => {
			// CALLDATASIZE PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
			const code = hex("0x3660005260206000f3");
			const contractAddr = testAddress(103);

			await evm.setCode(contractAddr, code);

			const inputData = hex("0x1234567890abcdef");
			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
					input: inputData,
				}),
			);

			assertSuccess(result);

			// Should return the size of input data (8 bytes)
			const output = result.output.toBytes();
			expect(output[31]).toBe(8);
		});

		it("should track gas consumption correctly", async () => {
			const code = addBytecode();
			const contractAddr = testAddress(104);

			await evm.setCode(contractAddr, code);

			const initialGas = 100000n;
			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
					gas: initialGas,
				}),
			);

			assertSuccess(result);
			expect(result.gasLeft).toBeLessThan(initialGas);
			expect(result.gasLeft).toBeGreaterThan(0n);

			const gasUsed = initialGas - result.gasLeft;
			expect(gasUsed).toBeGreaterThan(0n);
			expect(gasUsed).toBeLessThan(50000n); // Simple operation shouldn't use much gas
		});

		it("should handle STOP opcode", async () => {
			// PUSH1 42 STOP
			const code = hex("0x602a00");
			const contractAddr = testAddress(105);

			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);
			expect(result.output.isEmpty()).toBe(true); // STOP doesn't return data
		});

		it("should handle INVALID opcode", async () => {
			// INVALID (0xfe)
			const code = hex("0xfe");
			const contractAddr = testAddress(106);

			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			// INVALID is an exceptional halt: all gas consumed, no return data.
			assertFailure(result);
			expect(result.gasLeft).toBe(0n);
			expect(result.output.isEmpty()).toBe(true);
		});
	});

	describe("Value Transfers", () => {
		it("should transfer value with call", async () => {
			const sender = testAddress(200);
			const receiver = testAddress(201);
			const value = U256.fromBigInt(1000n);

			// Fund sender and ensure receiver exists with empty code (EOA)
			await evm.setBalance(sender, U256.fromBigInt(10000n));
			await evm.setCode(sender, Bytes.empty());
			await evm.setBalance(receiver, U256.zero());
			await evm.setCode(receiver, Bytes.empty());

			const result = await evm.call(
				defaultExecutionParams({
					caller: sender,
					to: receiver,
					value: value,
				}),
			);

			assertSuccess(result);

			// Check balances
			const senderBalance = await evm.getBalance(sender);
			const receiverBalance = await evm.getBalance(receiver);

			expect(senderBalance.toBigInt()).toBe(9000n);
			expect(receiverBalance.toBigInt()).toBe(1000n);
		});

		it("should fail transfer with insufficient balance", async () => {
			const sender = testAddress(202);
			const receiver = testAddress(203);

			// Sender has 100, tries to send 1000
			await evm.setBalance(sender, U256.fromBigInt(100n));
			await evm.setCode(sender, Bytes.empty());
			await evm.setBalance(receiver, U256.zero());
			await evm.setCode(receiver, Bytes.empty());

			const result = await evm.call(
				defaultExecutionParams({
					caller: sender,
					to: receiver,
					value: U256.fromBigInt(1000n),
				}),
			);

			assertFailure(result);

			// Balances should remain unchanged
			expect((await evm.getBalance(sender)).toBigInt()).toBe(100n);
			expect((await evm.getBalance(receiver)).toBigInt()).toBe(0n);
		});

		it("should handle zero value transfer", async () => {
			const sender = testAddress(204);
			const receiver = testAddress(205);

			await evm.setBalance(sender, U256.fromBigInt(1000n));
			await evm.setCode(sender, Bytes.empty());
			await evm.setBalance(receiver, U256.zero());
			await evm.setCode(receiver, Bytes.empty());

			const result = await evm.call(
				defaultExecutionParams({
					caller: sender,
					to: receiver,
					value: U256.zero(),
				}),
			);

			assertSuccess(result);

			// Balance unchanged except for gas
			expect((await evm.getBalance(sender)).toBigInt()).toBe(1000n);
			expect((await evm.getBalance(receiver)).toBigInt()).toBe(0n);
		});

		// TODO: Fix self-transfer value accounting in Zig implementation
		it("should handle self-transfer", async () => {
			const addr = testAddress(206);
			await evm.setBalance(addr, U256.fromBigInt(1000n));
			await evm.setCode(addr, Bytes.empty());

			const result = await evm.call(
				defaultExecutionParams({
					caller: addr,
					to: addr,
					value: U256.fromBigInt(100n),
				}),
			);

			assertSuccess(result);

			// Balance should remain the same (transfer to self)
			expect((await evm.getBalance(addr)).toBigInt()).toBe(1000n);
		});
	});

	describe("Storage Operations", () => {
		// TODO: Fix SSTORE persistence in Zig implementation
		it("should execute SSTORE and persist storage", async () => {
			const contractAddr = testAddress(300);
			const code = storeBytecode(5, 42); // Store 42 at slot 5

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);

			// Verify storage was set
			const value = await evm.getStorage(contractAddr, U256.fromBigInt(5n));
			expect(value.toBigInt()).toBe(42n);
		});

		// TODO: Fix SLOAD RuntimeError in Zig implementation
		it("should read storage with SLOAD", async () => {
			const contractAddr = testAddress(301);
			const code = Bytes.fromBytes(
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

			// Ensure account exists, set code and storage
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);
			await evm.setStorage(contractAddr, U256.zero(), U256.fromBigInt(99n));

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);

			// Should return the stored value
			const output = result.output.toBytes();
			expect(output[31]).toBe(99);
		});

		// TODO: Fix SSTORE persistence in Zig implementation
		it("should handle multiple storage operations", async () => {
			const contractAddr = testAddress(302);
			// Store multiple values
			const code = Bytes.concat([
				hex("0x6001600055"), // Store 1 at slot 0
				hex("0x6002600155"), // Store 2 at slot 1
				hex("0x6003600255"), // Store 3 at slot 2
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

			// Verify all storage slots
			expect(
				(await evm.getStorage(contractAddr, U256.fromBigInt(0n))).toBigInt(),
			).toBe(1n);
			expect(
				(await evm.getStorage(contractAddr, U256.fromBigInt(1n))).toBigInt(),
			).toBe(2n);
			expect(
				(await evm.getStorage(contractAddr, U256.fromBigInt(2n))).toBigInt(),
			).toBe(3n);
		});
	});

	describe("Revert and Error Handling", () => {
		// TODO: Fix REVERT error message propagation in Zig implementation
		it("should handle REVERT opcode", async () => {
			const contractAddr = testAddress(400);
			const code = revertBytecode();

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			// REVERT(offset=0, size=4) of fresh memory: 4 zero bytes, unused gas refunded.
			// Gas: PUSH1 3 + PUSH1 3 + memory expansion to 1 word 3 = 9.
			assertFailure(result);
			expect(result.errorMessage).toBeNull();
			expect(result.output.toBytes()).toEqual(new Uint8Array(4));
			expect(result.gasLeft).toBe(1000000n - 21000n - 9n);
		});

		// TODO: Fix REVERT with data not returning data in Zig
		it("should revert with data", async () => {
			const contractAddr = testAddress(401);
			// Store error message and revert with it
			const code = Bytes.fromBytes(
				new Uint8Array([
					0x63, 0x46, 0x41, 0x49, 0x4c, // PUSH4 "FAIL"
					0x60, 0x00, // PUSH1 0
					0x52, // MSTORE (word at 0, "FAIL" in bytes 28..31)
					0x60, 0x04, // PUSH1 4 (size)
					0x60, 0x1c, // PUSH1 28 (offset)
					0xfd, // REVERT
				]),
			);

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertFailure(result);
			expect(result.output.toBytes()).toEqual(new Uint8Array([70, 65, 73, 76])); // "FAIL"
			// REVERT refunds unused gas: PUSH4 3 + PUSH1 3 + MSTORE 3 + memory 3 + PUSH1 3 + PUSH1 3 = 18
			expect(result.gasLeft).toBe(1000000n - 21000n - 18n);
		});

		// TODO: Fix out of gas error message in Zig
		it("should handle out of gas", async () => {
			const contractAddr = testAddress(402);
			const code = infiniteLoopBytecode();

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
					gas: 10000n, // Low gas limit
				}),
			);

			assertFailure(result);
			// Exceptional halt consumes all gas and returns no data.
			expect(result.gasLeft).toBe(0n);
			expect(result.output.isEmpty()).toBe(true);
		});

		// TODO: Fix stack underflow RuntimeError in Zig implementation
		it("should handle stack underflow", async () => {
			const contractAddr = testAddress(403);
			// POP without anything on stack
			const code = hex("0x50");

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			// Exceptional halt consumes all gas and returns no data.
			assertFailure(result);
			expect(result.gasLeft).toBe(0n);
			expect(result.output.isEmpty()).toBe(true);
		});

		// TODO: Fix invalid jump RuntimeError in Zig implementation
		it("should handle invalid jump destination", async () => {
			const contractAddr = testAddress(404);
			// PUSH1 99 JUMP (jump to invalid location)
			const code = hex("0x606356");

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			// Exceptional halt consumes all gas and returns no data.
			assertFailure(result);
			expect(result.gasLeft).toBe(0n);
			expect(result.output.isEmpty()).toBe(true);
		});
	});

	describe("Context Information", () => {
		// TODO: Fix CALLER opcode RuntimeError in Zig implementation
		it("should provide correct CALLER", async () => {
			const contractAddr = testAddress(500);
			const caller = testAddress(999);
			const code = Bytes.fromBytes(
				new Uint8Array([
					0x33, // CALLER
					0x60, 0x00, // PUSH1 0
					0x52, // MSTORE (address in bytes 12..31)
					0x60, 0x14, // PUSH1 20 (size)
					0x60, 0x0c, // PUSH1 12 (offset)
					0xf3, // RETURN
				]),
			);

			// Ensure accounts exist and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setBalance(caller, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					caller: caller,
					to: contractAddr,
				}),
			);

			assertSuccess(result);

			const output = result.output.toBytes();
			expect(output.length).toBe(20);
			expect(Address.fromBytes(output).toHex()).toBe(caller.toHex());
		});

		// TODO: Fix ADDRESS opcode RuntimeError in Zig implementation
		it("should provide correct ADDRESS", async () => {
			const contractAddr = testAddress(501);
			const code = Bytes.fromBytes(
				new Uint8Array([
					0x30, // ADDRESS
					0x60, 0x00, // PUSH1 0
					0x52, // MSTORE (address in bytes 12..31)
					0x60, 0x14, // PUSH1 20 (size)
					0x60, 0x0c, // PUSH1 12 (offset)
					0xf3, // RETURN
				]),
			);

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);

			const output = result.output.toBytes();
			expect(output.length).toBe(20);
			const returnedAddr = Address.fromBytes(output);
			expect(returnedAddr.toHex()).toBe(contractAddr.toHex());
		});

		it("should provide correct CALLVALUE", async () => {
			const contractAddr = testAddress(502);
			const value = U256.fromBigInt(123456n);
			// CALLVALUE PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
			const code = hex("0x3460005260206000f3");

			// Ensure accounts exist and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);
			await evm.setBalance(testAddress(1), U256.fromBigInt(1000000n));

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
					value: value,
				}),
			);

			assertSuccess(result);

			const output = result.output.toBytes();
			const returnedValue = U256.fromBytes(output);
			expect(returnedValue.toBigInt()).toBe(123456n);
		});

		it("should provide correct CALLDATASIZE", async () => {
			const contractAddr = testAddress(503);
			// CALLDATASIZE PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
			const code = hex("0x3660005260206000f3");

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const inputData = Bytes.fromBytes(new Uint8Array(64));
			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
					input: inputData,
				}),
			);

			assertSuccess(result);

			const output = result.output.toBytes();
			expect(output[31]).toBe(64);
		});

		// TODO: Fix CALLDATACOPY returning empty data in Zig implementation
		it("should copy CALLDATA correctly", async () => {
			const contractAddr = testAddress(504);
			const code = Bytes.fromBytes(
				new Uint8Array([
					0x60, 0x20, // PUSH1 32 (size)
					0x60, 0x00, // PUSH1 0 (calldata offset)
					0x60, 0x00, // PUSH1 0 (memory offset)
					0x37, // CALLDATACOPY
					0x60, 0x20, // PUSH1 32 (size)
					0x60, 0x00, // PUSH1 0 (offset)
					0xf3, // RETURN
				]),
			);

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const inputData = hex(
				"0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
			);
			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
					input: inputData,
				}),
			);

			assertSuccess(result);
			expect(result.output.toHex()).toBe(inputData.toHex());
		});
	});

	describe("Simulate vs Call", () => {
		// TODO: Fix storage persistence affecting simulate in Zig implementation
		it("should simulate without modifying state", async () => {
			const contractAddr = testAddress(600);
			const code = storeBytecode(0, 99);

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			// First check initial storage
			const initialValue = await evm.getStorage(contractAddr, U256.zero());
			expect(initialValue.toBigInt()).toBe(0n);

			// Simulate the call
			const result = await evm.simulate(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);

			// Storage should remain unchanged
			const afterSimulate = await evm.getStorage(contractAddr, U256.zero());
			expect(afterSimulate.toBigInt()).toBe(0n);

			// Now actually call it
			const callResult = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(callResult);

			// Now storage should be changed
			const afterCall = await evm.getStorage(contractAddr, U256.zero());
			expect(afterCall.toBigInt()).toBe(99n);
		});
	});

	describe("Complex Execution Scenarios", () => {
		it("should handle bytecode with all stack operations", async () => {
			const contractAddr = testAddress(700);
			// Complex stack manipulation
			const code = hex("0x600160026003600460050101010160005260206000f3");

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);
			expect(result.output.length()).toBe(32);
		});

		// TODO: Fix memory expansion RuntimeError in Zig implementation
		it("should handle memory expansion", async () => {
			const contractAddr = testAddress(701);
			// Write to high memory address
			const code = Bytes.fromBytes(
				new Uint8Array([
					0x60, 0x2a, // PUSH1 42
					0x61, 0x10, 0x00, // PUSH2 0x1000
					0x52, // MSTORE
				]),
			);

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
					gas: 1000000n,
				}),
			);

			assertSuccess(result);
			// Memory grows to 0x1020 bytes = 129 words: 129*3 + floor(129^2/512) = 419.
			// Total: PUSH1 3 + PUSH2 3 + MSTORE 3 + 419 = 428, after 21000 intrinsic.
			expect(result.gasLeft).toBe(1000000n - 21000n - 428n);
		});

		it("should handle conditional jumps", async () => {
			const contractAddr = testAddress(702);
			// PUSH1 1 PUSH1 1 EQ PUSH1 13 JUMPI PUSH1 0 PUSH1 0 REVERT JUMPDEST PUSH1 42 PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
			const code = hex("0x6001600114600d5760006000fd5b602a60005260206000f3");

			// Ensure account exists and set code
			await evm.setBalance(contractAddr, U256.zero());
			await evm.setCode(contractAddr, code);

			const result = await evm.call(
				defaultExecutionParams({
					to: contractAddr,
				}),
			);

			assertSuccess(result);
			const output = result.output.toBytes();
			expect(output[31]).toBe(42);
		});
	});

	describe("GAS opcode", () => {
		// Yellow Paper: GAS pushes μ'g after GAS's own cost (2) is charged, not after later
		// opcodes in the same basic block. Frame gas = params.gas - 21000 intrinsic.
		it("GAS returns remaining gas after its own cost, not after later opcodes in the block", async () => {
			const contractAddr = testAddress(800);
			const code = Bytes.fromBytes(
				new Uint8Array([
					0x5a, // GAS
					0x60, 0x00, // PUSH1 0
					0x52, // MSTORE
					0x60, 0x20, // PUSH1 32
					0x60, 0x00, // PUSH1 0
					0xf3, // RETURN
				]),
			);
			await evm.setCode(contractAddr, code);

			const result = await evm.call(defaultExecutionParams({ to: contractAddr, gas: 1000000n }));

			assertSuccess(result);
			expect(U256.fromBytes(result.output.toBytes()).toBigInt()).toBe(1000000n - 21000n - 2n);
		});

		it("GAS is not reduced by a cold SLOAD later in the same block", async () => {
			const contractAddr = testAddress(801);
			const code = Bytes.fromBytes(
				new Uint8Array([
					0x5a, // GAS
					0x60, 0x00, // PUSH1 0
					0x54, // SLOAD (cold)
					0x50, // POP
					0x60, 0x00, // PUSH1 0
					0x52, // MSTORE
					0x60, 0x20, // PUSH1 32
					0x60, 0x00, // PUSH1 0
					0xf3, // RETURN
				]),
			);
			await evm.setCode(contractAddr, code);

			const result = await evm.call(defaultExecutionParams({ to: contractAddr, gas: 1000000n }));

			assertSuccess(result);
			expect(U256.fromBytes(result.output.toBytes()).toBigInt()).toBe(1000000n - 21000n - 2n);
		});
	});

	describe("SLOAD gas (EIP-2929)", () => {
		it("charges 2100 for a cold SLOAD and 100 for a warm SLOAD", async () => {
			const contractAddr = testAddress(802);
			const code = Bytes.fromBytes(
				new Uint8Array([
					0x60, 0x00, // PUSH1 0
					0x54, // SLOAD (cold: 2100)
					0x60, 0x00, // PUSH1 0
					0x54, // SLOAD (warm: 100)
					0x00, // STOP
				]),
			);
			await evm.setCode(contractAddr, code);

			const result = await evm.call(defaultExecutionParams({ to: contractAddr, gas: 1000000n }));

			assertSuccess(result);
			// PUSH1 3 + SLOAD 2100 + PUSH1 3 + SLOAD 100 = 2206
			expect(result.gasLeft).toBe(1000000n - 21000n - 2206n);
		});
	});

	describe("JUMP and JUMPI gas", () => {
		it("charges 8 for JUMP and 1 for JUMPDEST", async () => {
			const contractAddr = testAddress(803);
			const code = Bytes.fromBytes(
				new Uint8Array([
					0x60, 0x03, // 0: PUSH1 3
					0x56, // 2: JUMP
					0x5b, // 3: JUMPDEST
					0x00, // 4: STOP
				]),
			);
			await evm.setCode(contractAddr, code);

			const result = await evm.call(defaultExecutionParams({ to: contractAddr, gas: 1000000n }));

			assertSuccess(result);
			// PUSH1 3 + JUMP 8 + JUMPDEST 1
			expect(result.gasLeft).toBe(1000000n - 21000n - 12n);
		});

		it("charges 10 for a JUMPI that is not taken", async () => {
			const contractAddr = testAddress(804);
			const code = Bytes.fromBytes(
				new Uint8Array([
					0x60, 0x00, // 0: PUSH1 0 (condition)
					0x60, 0x06, // 2: PUSH1 6 (destination)
					0x57, // 4: JUMPI
					0x00, // 5: STOP
					0x5b, // 6: JUMPDEST
					0x00, // 7: STOP
				]),
			);
			await evm.setCode(contractAddr, code);

			const result = await evm.call(defaultExecutionParams({ to: contractAddr, gas: 1000000n }));

			assertSuccess(result);
			// PUSH1 3 + PUSH1 3 + JUMPI 10
			expect(result.gasLeft).toBe(1000000n - 21000n - 16n);
		});

		it("charges 10 for a taken JUMPI and 1 for JUMPDEST", async () => {
			const contractAddr = testAddress(805);
			const code = Bytes.fromBytes(
				new Uint8Array([
					0x60, 0x01, // 0: PUSH1 1 (condition)
					0x60, 0x06, // 2: PUSH1 6 (destination)
					0x57, // 4: JUMPI
					0x00, // 5: STOP
					0x5b, // 6: JUMPDEST
					0x00, // 7: STOP
				]),
			);
			await evm.setCode(contractAddr, code);

			const result = await evm.call(defaultExecutionParams({ to: contractAddr, gas: 1000000n }));

			assertSuccess(result);
			// PUSH1 3 + PUSH1 3 + JUMPI 10 + JUMPDEST 1
			expect(result.gasLeft).toBe(1000000n - 21000n - 17n);
		});
	});
});
