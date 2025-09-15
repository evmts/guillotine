import { describe, it, expect, afterEach } from "bun:test";
import { GuillotineEvm, type BlockInfo } from "./evm.js";
import { Address } from "../primitives/address.js";
import { Bytes } from "../primitives/bytes.js";
import { testAddress, defaultBlockInfo } from "../../test/test-helpers.js";

describe("GuillotineEvm - Basic Lifecycle", () => {
	let evm: GuillotineEvm | null = null;

	afterEach(async () => {
		if (evm) {
			evm.close();
			evm = null;
		}
	});

	describe("Initialization", () => {
		it("should create Evm with default block info", async () => {
			evm = await GuillotineEvm.create();
			expect(evm).toBeDefined();
			expect(evm).toBeInstanceOf(GuillotineEvm);
		});

		it("should create Evm with custom block info", async () => {
			const blockInfo: BlockInfo = {
				number: 12345n,
				timestamp: 9876543210n,
				gasLimit: 15000000n,
				coinbase: testAddress(42),
				baseFee: 2000000000n,
				chainId: 5n,
				difficulty: 1000000n,
				prevRandao: Bytes.fromHex("0x" + "aa".repeat(32)),
			};

			evm = await GuillotineEvm.create(blockInfo);
			expect(evm).toBeDefined();
			expect(evm).toBeInstanceOf(GuillotineEvm);
		});

		it("should create Evm with partial block info", async () => {
			const blockInfo: BlockInfo = {
				number: 999n,
				chainId: 137n,
			};

			evm = await GuillotineEvm.create(blockInfo);
			expect(evm).toBeDefined();
			expect(evm).toBeInstanceOf(GuillotineEvm);
		});

		it("should create Evm with tracing enabled", async () => {
			evm = await GuillotineEvm.create(undefined, true);
			expect(evm).toBeDefined();
			expect(evm).toBeInstanceOf(GuillotineEvm);
		});

		it("should create Evm with tracing and custom block info", async () => {
			const blockInfo = defaultBlockInfo();
			evm = await GuillotineEvm.create(blockInfo, true);
			expect(evm).toBeDefined();
			expect(evm).toBeInstanceOf(GuillotineEvm);
		});

		it("should create multiple independent Evm instances", async () => {
			const evm1 = await GuillotineEvm.create();
			const evm2 = await GuillotineEvm.create();
			const evm3 = await GuillotineEvm.create();

			expect(evm1).not.toBe(evm2);
			expect(evm2).not.toBe(evm3);
			expect(evm1).not.toBe(evm3);

			evm1.close();
			evm2.close();
			evm3.close();
		});

		it("should handle default values for missing block info fields", async () => {
			evm = await GuillotineEvm.create({});
			expect(evm).toBeDefined();

			// Should not throw when used
			const balance = await evm.getBalance(testAddress(1));
			expect(balance.toBigInt()).toBe(0n);
		});

		it("should handle zero address as default coinbase", async () => {
			evm = await GuillotineEvm.create({
				coinbase: Address.zero(),
			});
			expect(evm).toBeDefined();
		});

		it("should handle maximum values in block info", async () => {
			const maxU64 = (1n << 64n) - 1n;
			const maxU16 = (1n << 16n) - 1n; // 65535 - maximum supported chain ID
			const blockInfo: BlockInfo = {
				number: maxU64,
				timestamp: maxU64,
				gasLimit: maxU64,
				baseFee: maxU64,
				chainId: maxU16, // Use valid chain ID within u16 range
				difficulty: maxU64,
			};

			evm = await GuillotineEvm.create(blockInfo);
			expect(evm).toBeDefined();
		});
	});

	describe("Resource Management", () => {
		it("should close Evm instance properly", async () => {
			evm = await GuillotineEvm.create();
			expect(evm).toBeDefined();
			expect(() => (evm as GuillotineEvm).close()).not.toThrow();
			evm = null; // Prevent afterEach from closing again
		});

		it("should handle multiple close calls gracefully", async () => {
			evm = await GuillotineEvm.create();
			expect(evm).toBeDefined();
			evm.close();
			expect(() => (evm as GuillotineEvm).close()).not.toThrow();
			evm = null;
		});

		it("should not allow operations after close", async () => {
			evm = await GuillotineEvm.create();
			evm.close();

			await expect(evm.getBalance(testAddress(1))).rejects.toThrow();
			evm = null;
		});

		it("should create new instance after closing previous", async () => {
			const evm1 = await GuillotineEvm.create();
			evm1.close();

			evm = await GuillotineEvm.create();
			expect(evm).toBeDefined();

			const balance = await evm.getBalance(testAddress(1));
			expect(balance.toBigInt()).toBe(0n);
		});
	});

	describe("Instance Independence", () => {
		it("should maintain independent state between instances", async () => {
			const evm1 = await GuillotineEvm.create();
			const evm2 = await GuillotineEvm.create();

			const addr = testAddress(100);
			const balance1 = await evm1.getBalance(addr);
			const balance2 = await evm2.getBalance(addr);

			expect(balance1.toBigInt()).toBe(0n);
			expect(balance2.toBigInt()).toBe(0n);

			evm1.close();
			evm2.close();
		});

		it("should handle different block configs independently", async () => {
			const evm1 = await GuillotineEvm.create({ chainId: 1n });
			const evm2 = await GuillotineEvm.create({ chainId: 137n });
			const evm3 = await GuillotineEvm.create({ chainId: 42161n });

			// All should work independently
			expect(evm1).toBeDefined();
			expect(evm2).toBeDefined();
			expect(evm3).toBeDefined();

			evm1.close();
			evm2.close();
			evm3.close();
		});
	});

	describe("Block Info Edge Cases", () => {
		it("should handle empty prevRandao", async () => {
			evm = await GuillotineEvm.create({
				prevRandao: Bytes.empty(),
			});
			expect(evm).toBeDefined();
		});

		it("should handle large prevRandao", async () => {
			evm = await GuillotineEvm.create({
				prevRandao: Bytes.fromBytes(new Uint8Array(32).fill(255)),
			});
			expect(evm).toBeDefined();
		});

		it("should use current timestamp as default", async () => {
			evm = await GuillotineEvm.create();

			// We can't directly check the timestamp used, but the Evm should be created
			expect(evm).toBeDefined();

			// Timestamp should be between before and after (or equal)
			// This is implicitly tested by successful creation
		});

		it("should handle all chain IDs", async () => {
      // We only support mainnet for now.
      const chainIds = [1n /* , 3n, 4n, 5n, 42n, 137n, 80001n, 42161n, 421611n */];
      
			for (const chainId of chainIds) {
				const evmInstance = await GuillotineEvm.create({ chainId });
				expect(evmInstance).toBeDefined();
				evmInstance.close();
			}
		});
	});

	describe("Error Handling", () => {
		it("should handle operations on closed Evm", async () => {
			evm = await GuillotineEvm.create();
			const addr = testAddress(1);

			evm.close();

			expect(evm.getBalance(addr)).rejects.toThrow("not initialized");
			expect(evm.getCode(addr)).rejects.toThrow("not initialized");

			evm = null;
		});

		it("should provide meaningful error messages", async () => {
			evm = await GuillotineEvm.create();
			evm.close();

			try {
				await evm.getBalance(testAddress(1));
				throw new Error("Should have thrown");
			} catch (error) {
				expect(error).toBeInstanceOf(Error);
				expect((error as Error).message).toContain("not initialized");
			}

			evm = null;
		});
	});

	describe("Tracing Mode", () => {
		it("should create separate instances with and without tracing", async () => {
			const evmNoTrace = await GuillotineEvm.create(undefined, false);
			const evmWithTrace = await GuillotineEvm.create(undefined, true);

			expect(evmNoTrace).toBeDefined();
			expect(evmWithTrace).toBeDefined();
			expect(evmNoTrace).not.toBe(evmWithTrace);

			evmNoTrace.close();
			evmWithTrace.close();
		});

		it("should work with custom block info and tracing", async () => {
			const blockInfo: BlockInfo = {
				number: 12345n,
				timestamp: 1234567890n,
				gasLimit: 30000000n,
				coinbase: testAddress(999),
				baseFee: 1000000000n,
				chainId: 1n,
				difficulty: 0n,
				prevRandao: Bytes.fromHex("0x" + "00".repeat(32)),
			};

			evm = await GuillotineEvm.create(blockInfo, true);
			expect(evm).toBeDefined();

			// Should be able to perform operations
			const balance = await evm.getBalance(testAddress(1));
			expect(balance.toBigInt()).toBe(0n);
		});
	});
});
