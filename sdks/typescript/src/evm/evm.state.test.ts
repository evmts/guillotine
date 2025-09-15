import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { GuillotineEvm } from "./evm.js";
import { Address } from "../primitives/address.js";
import { U256 } from "../primitives/u256.js";
import { Bytes } from "../primitives/bytes.js";
import { testAddress, hex } from "../../test/test-helpers.js";

describe("GuillotineEvm - State Management", () => {
	let evm: GuillotineEvm;

	beforeEach(async () => {
		evm = await GuillotineEvm.create();
	});

	afterEach(() => {
		evm.close();
	});

	describe("Balance Management", () => {
		it("should set and get account balance", async () => {
			const addr = testAddress(1);
			const balance = U256.fromBigInt(1000000n);

			await evm.setBalance(addr, balance);
			const retrieved = await evm.getBalance(addr);

			expect(retrieved.toBigInt()).toBe(1000000n);
		});

		it("should handle zero balance", async () => {
			const addr = testAddress(2);

			// Default should be zero
			const initial = await evm.getBalance(addr);
			expect(initial.toBigInt()).toBe(0n);

			// Explicitly set to zero
			await evm.setBalance(addr, U256.zero());
			const retrieved = await evm.getBalance(addr);
			expect(retrieved.toBigInt()).toBe(0n);
		});

		it("should handle maximum U256 balance", async () => {
			const addr = testAddress(3);
			const maxBalance = U256.fromBigInt((1n << 256n) - 1n);

			await evm.setBalance(addr, maxBalance);
			const retrieved = await evm.getBalance(addr);

			expect(retrieved.toBigInt()).toBe(maxBalance.toBigInt());
		});

		it("should update existing balance", async () => {
			const addr = testAddress(4);

			await evm.setBalance(addr, U256.fromBigInt(100n));
			let balance = await evm.getBalance(addr);
			expect(balance.toBigInt()).toBe(100n);

			await evm.setBalance(addr, U256.fromBigInt(200n));
			balance = await evm.getBalance(addr);
			expect(balance.toBigInt()).toBe(200n);

			await evm.setBalance(addr, U256.zero());
			balance = await evm.getBalance(addr);
			expect(balance.toBigInt()).toBe(0n);
		});

		it("should maintain separate balances for different accounts", async () => {
			const addr1 = testAddress(10);
			const addr2 = testAddress(20);
			const addr3 = testAddress(30);

			await evm.setBalance(addr1, U256.fromBigInt(100n));
			await evm.setBalance(addr2, U256.fromBigInt(200n));
			await evm.setBalance(addr3, U256.fromBigInt(300n));

			expect((await evm.getBalance(addr1)).toBigInt()).toBe(100n);
			expect((await evm.getBalance(addr2)).toBigInt()).toBe(200n);
			expect((await evm.getBalance(addr3)).toBigInt()).toBe(300n);
		});

		it("should handle wei amounts correctly", async () => {
			const addr = testAddress(5);
			const oneEther = U256.fromBigInt(1000000000000000000n); // 1 ETH in wei

			await evm.setBalance(addr, oneEther);
			const balance = await evm.getBalance(addr);

			expect(balance.toBigInt()).toBe(1000000000000000000n);
		});
	});

	describe("Code Management", () => {
		it("should set and get contract code", async () => {
			const addr = testAddress(100);
			const code = hex("0x6080604052348015600f57600080fd5b50");

			await evm.setCode(addr, code);
			const retrieved = await evm.getCode(addr);

			expect(retrieved.toHex()).toBe(code.toHex());
		});

		it("should handle empty code", async () => {
			const addr = testAddress(101);

			// Default should be empty
			const initial = await evm.getCode(addr);
			expect(initial.isEmpty()).toBe(true);
			expect(initial.length()).toBe(0);

			// Explicitly set empty
			await evm.setCode(addr, Bytes.empty());
			const retrieved = await evm.getCode(addr);
			expect(retrieved.isEmpty()).toBe(true);
		});

		it("should handle large bytecode", async () => {
			const addr = testAddress(102);
			// Create 10KB of bytecode
			const largeCode = Bytes.fromBytes(new Uint8Array(10240).fill(0x60));

			await evm.setCode(addr, largeCode);
			const retrieved = await evm.getCode(addr);

			expect(retrieved.length()).toBe(10240);
			expect(retrieved.toBytes()).toEqual(largeCode.toBytes());
		});

		it("should update existing code", async () => {
			const addr = testAddress(103);
			const code1 = hex("0x6001");
			const code2 = hex("0x600260030160005260206000f3");

			await evm.setCode(addr, code1);
			let retrieved = await evm.getCode(addr);
			expect(retrieved.toHex()).toBe(code1.toHex());

			await evm.setCode(addr, code2);
			retrieved = await evm.getCode(addr);
			expect(retrieved.toHex()).toBe(code2.toHex());
		});

		it("should clear code when setting empty", async () => {
			const addr = testAddress(104);
			const code = hex("0x608060405260043610");

			await evm.setCode(addr, code);
			let retrieved = await evm.getCode(addr);
			expect(retrieved.isEmpty()).toBe(false);

			await evm.setCode(addr, Bytes.empty());
			retrieved = await evm.getCode(addr);
			expect(retrieved.isEmpty()).toBe(true);
		});

		it("should maintain separate code for different accounts", async () => {
			const addr1 = testAddress(110);
			const addr2 = testAddress(111);
			const code1 = hex("0x6001");
			const code2 = hex("0x6002");

			await evm.setCode(addr1, code1);
			await evm.setCode(addr2, code2);

			expect((await evm.getCode(addr1)).toHex()).toBe(code1.toHex());
			expect((await evm.getCode(addr2)).toHex()).toBe(code2.toHex());
		});

		it("should handle bytecode with all possible byte values", async () => {
			const addr = testAddress(105);
			const allBytes = new Uint8Array(256);
			for (let i = 0; i < 256; i++) {
				allBytes[i] = i;
			}
			const code = Bytes.fromBytes(allBytes);

			await evm.setCode(addr, code);
			const retrieved = await evm.getCode(addr);

			expect(retrieved.toBytes()).toEqual(allBytes);
		});
	});

	describe("Storage Management", () => {
		it("should set and get storage slot", async () => {
			const addr = testAddress(200);
			const key = U256.fromBigInt(1n);
			const value = U256.fromBigInt(42n);

			await evm.setStorage(addr, key, value);
			const retrieved = await evm.getStorage(addr, key);

			expect(retrieved.toBigInt()).toBe(42n);
		});

		it("should handle zero storage values", async () => {
			const addr = testAddress(201);
			const key = U256.fromBigInt(5n);

			// Default should be zero
			const initial = await evm.getStorage(addr, key);
			expect(initial.toBigInt()).toBe(0n);

			// Set to non-zero then back to zero
			await evm.setStorage(addr, key, U256.fromBigInt(100n));
			await evm.setStorage(addr, key, U256.zero());
			const retrieved = await evm.getStorage(addr, key);
			expect(retrieved.toBigInt()).toBe(0n);
		});

		it("should handle maximum U256 storage values", async () => {
			const addr = testAddress(202);
			const key = U256.fromBigInt(0n);
			const maxValue = U256.fromBigInt((1n << 256n) - 1n);

			await evm.setStorage(addr, key, maxValue);
			const retrieved = await evm.getStorage(addr, key);

			expect(retrieved.toBigInt()).toBe(maxValue.toBigInt());
		});

		it("should handle multiple storage slots", async () => {
			const addr = testAddress(203);

			// Set multiple slots
			for (let i = 0; i < 10; i++) {
				const key = U256.fromBigInt(BigInt(i));
				const value = U256.fromBigInt(BigInt(i * 100));
				await evm.setStorage(addr, key, value);
			}

			// Verify all slots
			for (let i = 0; i < 10; i++) {
				const key = U256.fromBigInt(BigInt(i));
				const retrieved = await evm.getStorage(addr, key);
				expect(retrieved.toBigInt()).toBe(BigInt(i * 100));
			}
		});

		it("should maintain separate storage for different accounts", async () => {
			const addr1 = testAddress(210);
			const addr2 = testAddress(211);
			const key = U256.fromBigInt(1n);

			await evm.setStorage(addr1, key, U256.fromBigInt(100n));
			await evm.setStorage(addr2, key, U256.fromBigInt(200n));

			expect((await evm.getStorage(addr1, key)).toBigInt()).toBe(100n);
			expect((await evm.getStorage(addr2, key)).toBigInt()).toBe(200n);
		});

		it("should handle storage with large keys", async () => {
			const addr = testAddress(204);
			const largeKey = U256.fromBigInt((1n << 255n) + 12345n);
			const value = U256.fromBigInt(999n);

			await evm.setStorage(addr, largeKey, value);
			const retrieved = await evm.getStorage(addr, largeKey);

			expect(retrieved.toBigInt()).toBe(999n);
		});

		it("should update existing storage slots", async () => {
			const addr = testAddress(205);
			const key = U256.fromBigInt(10n);

			await evm.setStorage(addr, key, U256.fromBigInt(1n));
			expect((await evm.getStorage(addr, key)).toBigInt()).toBe(1n);

			await evm.setStorage(addr, key, U256.fromBigInt(2n));
			expect((await evm.getStorage(addr, key)).toBigInt()).toBe(2n);

			await evm.setStorage(addr, key, U256.fromBigInt(3n));
			expect((await evm.getStorage(addr, key)).toBigInt()).toBe(3n);
		});

		it("should handle keccak256 derived storage slots", async () => {
			const addr = testAddress(206);
			// Common pattern for mapping storage
			const mappingKey = U256.fromHex(
				"0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563",
			);
			const value = U256.fromBigInt(0xdeadbeefn);

			await evm.setStorage(addr, mappingKey, value);
			const retrieved = await evm.getStorage(addr, mappingKey);

			expect(retrieved.toBigInt()).toBe(0xdeadbeefn);
		});
	});

	describe("Combined State Operations", () => {
		it("should handle account with balance, code, and storage", async () => {
			const addr = testAddress(300);

			// Set all state components
			await evm.setBalance(addr, U256.fromBigInt(1000n));
			await evm.setCode(addr, hex("0x6080604052"));
			await evm.setStorage(addr, U256.fromBigInt(0n), U256.fromBigInt(100n));
			await evm.setStorage(addr, U256.fromBigInt(1n), U256.fromBigInt(200n));

			// Verify all components
			expect((await evm.getBalance(addr)).toBigInt()).toBe(1000n);
			expect((await evm.getCode(addr)).toHex()).toBe("0x6080604052");
			expect((await evm.getStorage(addr, U256.fromBigInt(0n))).toBigInt()).toBe(
				100n,
			);
			expect((await evm.getStorage(addr, U256.fromBigInt(1n))).toBigInt()).toBe(
				200n,
			);
		});

		it("should handle EOA (externally owned account)", async () => {
			const addr = testAddress(301);

			// EOA has balance but no code
			await evm.setBalance(addr, U256.fromBigInt(5000n));

			expect((await evm.getBalance(addr)).toBigInt()).toBe(5000n);
			expect((await evm.getCode(addr)).isEmpty()).toBe(true);
			expect((await evm.getStorage(addr, U256.zero())).toBigInt()).toBe(0n);
		});

		it("should preserve state across multiple operations", async () => {
			const addr = testAddress(302);

			// Initial setup
			await evm.setBalance(addr, U256.fromBigInt(1000n));
			await evm.setCode(addr, hex("0x6001"));
			await evm.setStorage(addr, U256.zero(), U256.fromBigInt(42n));

			// Verify initial state
			expect((await evm.getBalance(addr)).toBigInt()).toBe(1000n);
			expect((await evm.getCode(addr)).toHex()).toBe("0x6001");
			expect((await evm.getStorage(addr, U256.zero())).toBigInt()).toBe(42n);

			// Modify balance only
			await evm.setBalance(addr, U256.fromBigInt(2000n));

			// Code and storage should remain unchanged
			expect((await evm.getBalance(addr)).toBigInt()).toBe(2000n);
			expect((await evm.getCode(addr)).toHex()).toBe("0x6001");
			expect((await evm.getStorage(addr, U256.zero())).toBigInt()).toBe(42n);
		});

		it("should handle state for precompiled addresses", async () => {
			// Precompiled addresses (0x01 - 0x09)
			const precompileAddr = Address.fromBytes(
				new Uint8Array(20).fill(0, 0, 19).fill(1, 19, 20),
			);

			// Should be able to set balance for precompiles
			await evm.setBalance(precompileAddr, U256.fromBigInt(1000n));
			const balance = await evm.getBalance(precompileAddr);
			expect(balance.toBigInt()).toBe(1000n);

			// Code should be empty (precompiles have implicit code)
			const code = await evm.getCode(precompileAddr);
			expect(code.isEmpty()).toBe(true);
		});
	});

	describe("Edge Cases", () => {
		it("should handle Address.zero()", async () => {
			const zeroAddr = Address.zero();

			await evm.setBalance(zeroAddr, U256.fromBigInt(100n));
			await evm.setCode(zeroAddr, hex("0x00"));
			await evm.setStorage(zeroAddr, U256.zero(), U256.fromBigInt(1n));

			expect((await evm.getBalance(zeroAddr)).toBigInt()).toBe(100n);
			expect((await evm.getCode(zeroAddr)).toHex()).toBe("0x00");
			expect((await evm.getStorage(zeroAddr, U256.zero())).toBigInt()).toBe(1n);
		});

		it("should handle operations in rapid succession", async () => {
			const addr = testAddress(400);

			// Rapid balance updates
			const promises = [];
			for (let i = 0; i < 10; i++) {
				promises.push(evm.setBalance(addr, U256.fromBigInt(BigInt(i))));
			}
			await Promise.all(promises);

			// Last value should win
			const balance = await evm.getBalance(addr);
			expect(balance.toBigInt()).toBe(9n);
		});

		it("should handle interleaved state operations", async () => {
			const addr1 = testAddress(401);
			const addr2 = testAddress(402);

			// Interleave operations on different accounts
			await evm.setBalance(addr1, U256.fromBigInt(100n));
			await evm.setBalance(addr2, U256.fromBigInt(200n));
			await evm.setCode(addr1, hex("0x01"));
			await evm.setCode(addr2, hex("0x02"));
			await evm.setStorage(addr1, U256.zero(), U256.fromBigInt(10n));
			await evm.setStorage(addr2, U256.zero(), U256.fromBigInt(20n));

			// Verify all state is correct
			expect((await evm.getBalance(addr1)).toBigInt()).toBe(100n);
			expect((await evm.getBalance(addr2)).toBigInt()).toBe(200n);
			expect((await evm.getCode(addr1)).toHex()).toBe("0x01");
			expect((await evm.getCode(addr2)).toHex()).toBe("0x02");
			expect((await evm.getStorage(addr1, U256.zero())).toBigInt()).toBe(10n);
			expect((await evm.getStorage(addr2, U256.zero())).toBigInt()).toBe(20n);
		});
	});
});
