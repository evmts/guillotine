import { describe, it, expect } from "bun:test";
import { GuillotineEvm } from "./evm.js";
import { U256 } from "../primitives/u256.js";
import { testAddress } from "../../test/test-helpers.js";

describe("GuillotineEvm - Lifecycle Management", () => {
	describe("Multiple Instance Coexistence", () => {
		it("should allow multiple Evm instances to coexist", async () => {
			const evm1 = await GuillotineEvm.create();
			const evm2 = await GuillotineEvm.create();
			const evm3 = await GuillotineEvm.create();

			const addr = testAddress(42);
			const balance = U256.fromBigInt(1000n);

			// Set different balances in each instance
			await evm1.setBalance(addr, balance);
			await evm2.setBalance(addr, U256.fromBigInt(2000n));
			await evm3.setBalance(addr, U256.fromBigInt(3000n));

			// Verify each instance maintains its own state
			expect((await evm1.getBalance(addr)).toBigInt()).toBe(1000n);
			expect((await evm2.getBalance(addr)).toBigInt()).toBe(2000n);
			expect((await evm3.getBalance(addr)).toBigInt()).toBe(3000n);

			// Close instances
			evm1.close();
			evm2.close();
			evm3.close();
		});

		it("should allow new instances after closing others", async () => {
			const evm1 = await GuillotineEvm.create();
			const addr = testAddress(1);
			await evm1.setBalance(addr, U256.fromBigInt(100n));
			expect((await evm1.getBalance(addr)).toBigInt()).toBe(100n);
			evm1.close();

			// Create new instance after closing first
			const evm2 = await GuillotineEvm.create();
			expect((await evm2.getBalance(addr)).toBigInt()).toBe(0n);
			await evm2.setBalance(addr, U256.fromBigInt(200n));
			expect((await evm2.getBalance(addr)).toBigInt()).toBe(200n);
			evm2.close();
		});

		it("should not affect other instances when one is closed", async () => {
			const evm1 = await GuillotineEvm.create();
			const evm2 = await GuillotineEvm.create();
			const evm3 = await GuillotineEvm.create();

			const addr = testAddress(99);
			await evm1.setBalance(addr, U256.fromBigInt(111n));
			await evm2.setBalance(addr, U256.fromBigInt(222n));
			await evm3.setBalance(addr, U256.fromBigInt(333n));

			// Close middle instance
			evm2.close();

			// Other instances should still work
			expect((await evm1.getBalance(addr)).toBigInt()).toBe(111n);
			expect((await evm3.getBalance(addr)).toBigInt()).toBe(333n);

			// Can still modify state in active instances
			await evm1.setBalance(addr, U256.fromBigInt(444n));
			expect((await evm1.getBalance(addr)).toBigInt()).toBe(444n);

			evm1.close();
			evm3.close();
		});

		it("should handle rapid creation and destruction", async () => {
			const instances = [];
			
			// Create 10 instances
			for (let i = 0; i < 10; i++) {
				const evm = await GuillotineEvm.create();
				const addr = testAddress(i);
				await evm.setBalance(addr, U256.fromBigInt(BigInt(i * 100)));
				instances.push({ evm, addr, expectedBalance: BigInt(i * 100) });
			}

			// Verify all states
			for (const { evm, addr, expectedBalance } of instances) {
				const balance = await evm.getBalance(addr);
				expect(balance.toBigInt()).toBe(expectedBalance);
			}

			// Close all instances
			for (const { evm } of instances) {
				evm.close();
			}

			// Create new instances and verify they start fresh
			const newEvm = await GuillotineEvm.create();
			for (const { addr } of instances) {
				const balance = await newEvm.getBalance(addr);
				expect(balance.toBigInt()).toBe(0n);
			}
			newEvm.close();
		});

		it("should handle mixed tracing and non-tracing instances", async () => {
			const evmNoTrace1 = await GuillotineEvm.create(undefined, false);
			const evmWithTrace = await GuillotineEvm.create(undefined, true);
			const evmNoTrace2 = await GuillotineEvm.create(undefined, false);

			const addr = testAddress(77);
			
			await evmNoTrace1.setBalance(addr, U256.fromBigInt(100n));
			await evmWithTrace.setBalance(addr, U256.fromBigInt(200n));
			await evmNoTrace2.setBalance(addr, U256.fromBigInt(300n));

			expect((await evmNoTrace1.getBalance(addr)).toBigInt()).toBe(100n);
			expect((await evmWithTrace.getBalance(addr)).toBigInt()).toBe(200n);
			expect((await evmNoTrace2.getBalance(addr)).toBigInt()).toBe(300n);

			evmNoTrace1.close();
			evmWithTrace.close();
			evmNoTrace2.close();
		});
	});

	describe("Error Handling", () => {
		it("should properly handle errors without affecting other instances", async () => {
			const evm1 = await GuillotineEvm.create();
			const evm2 = await GuillotineEvm.create();

			const addr = testAddress(1);
			await evm1.setBalance(addr, U256.fromBigInt(100n));
			await evm2.setBalance(addr, U256.fromBigInt(200n));

			// Close one instance
			evm1.close();

			// Operations on closed instance should fail
			await expect(evm1.getBalance(addr)).rejects.toThrow();

			// Other instance should still work
			expect((await evm2.getBalance(addr)).toBigInt()).toBe(200n);
			
			evm2.close();
		});
	});
});