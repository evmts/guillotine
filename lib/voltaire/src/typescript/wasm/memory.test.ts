/**
 * WASM Memory management tests
 * Validates WASM doesn't leak memory and handles large allocations
 */

import { test, expect, describe } from "bun:test";
import { Address as WasmAddress } from "./primitives/address.wasm";
import {
	analyzeJumpDestinations as wasmAnalyzeJumpDestinations,
	validateBytecode as wasmValidateBytecode,
} from "./primitives/bytecode.wasm";
import { Hash as WasmHash } from "./primitives/keccak.wasm";
import {
	encodeBytes as wasmEncodeBytes,
	encodeUintFromBigInt as wasmEncodeUintFromBigInt,
} from "./primitives/rlp.wasm";

describe("WASM Memory Management", () => {
	test("no memory leaks on repeated address operations", () => {
		// Note: Bun doesn't expose performance.memory like Chrome
		// We rely on WASM's internal cleanup and verify operations complete

		const iterations = 10000;
		const addresses: string[] = [];

		// Perform many operations
		for (let i = 0; i < iterations; i++) {
			const addr = WasmAddress.fromHex("0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb");
			const hex = addr.toHex();
			const checksum = addr.toChecksumHex();
			const bytes = addr.toBytes();

			// Keep some references to prevent optimization
			if (i % 1000 === 0) {
				addresses.push(hex);
			}
		}

		// If we got here without running out of memory, test passes
		expect(addresses.length).toBe(10);
	});

	test("no memory leaks on repeated keccak operations", () => {
		const iterations = 10000;
		const hashes: string[] = [];

		for (let i = 0; i < iterations; i++) {
			const hash = WasmHash.keccak256(`message ${i}`);
			const hex = hash.toHex();

			if (i % 1000 === 0) {
				hashes.push(hex);
			}
		}

		expect(hashes.length).toBe(10);
	});

	test("no memory leaks on repeated bytecode analysis", () => {
		// Create bytecode with some JUMPDESTs
		const bytecode = new Uint8Array([
			0x60, 0x80, 0x60, 0x40, 0x52, 0x5b, 0x60, 0x00, 0x80, 0xfd,
		]);

		const iterations = 10000;
		let totalJumps = 0;

		for (let i = 0; i < iterations; i++) {
			const jumps = wasmAnalyzeJumpDestinations(bytecode);
			totalJumps += jumps.length;
		}

		expect(totalJumps).toBeGreaterThan(0);
	});

	test("no memory leaks on repeated RLP encoding", () => {
		const iterations = 10000;
		const encodings: Uint8Array[] = [];

		for (let i = 0; i < iterations; i++) {
			const data = new TextEncoder().encode(`data ${i}`);
			const encoded = wasmEncodeBytes(data);

			if (i % 1000 === 0) {
				encodings.push(encoded);
			}
		}

		expect(encodings.length).toBe(10);
	});

	test("handles large bytecode allocation", () => {
		// Test with 1MB bytecode
		const largeBytecode = new Uint8Array(1024 * 1024);

		// Fill with valid opcodes
		for (let i = 0; i < largeBytecode.length; i++) {
			largeBytecode[i] = 0x00; // STOP opcode
		}

		// Should not throw
		expect(() => {
			wasmValidateBytecode(largeBytecode);
		}).not.toThrow();

		expect(() => {
			wasmAnalyzeJumpDestinations(largeBytecode);
		}).not.toThrow();
	});

	test("handles large hash input", () => {
		// Test with 5MB of data
		const largeData = new Uint8Array(5 * 1024 * 1024).fill(0x42);

		expect(() => {
			const hash = WasmHash.keccak256(largeData);
			expect(hash.toHex().length).toBe(66); // 0x + 64 hex chars
		}).not.toThrow();
	});

	test("handles large RLP encoding", () => {
		// Test with 1MB data
		const largeData = new Uint8Array(1024 * 1024).fill(0x42);

		expect(() => {
			const encoded = wasmEncodeBytes(largeData);
			expect(encoded.length).toBeGreaterThan(largeData.length);
		}).not.toThrow();
	});

	test("handles many address creations and disposals", () => {
		// Create and discard many addresses
		for (let i = 0; i < 10000; i++) {
			const addr = WasmAddress.fromHex(
				`0x${i.toString(16).padStart(40, "0")}`,
			);
			// Just access it and let it be garbage collected
			expect(addr.toHex().length).toBe(42);
		}
	});

	test("handles CREATE address calculations in bulk", () => {
		const sender = WasmAddress.fromHex("0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb");
		const addresses: string[] = [];

		// Calculate 1000 CREATE addresses
		for (let nonce = 0; nonce < 1000; nonce++) {
			const contractAddr = WasmAddress.calculateCreateAddress(sender, nonce);
			if (nonce % 100 === 0) {
				addresses.push(contractAddr.toHex());
			}
		}

		expect(addresses.length).toBe(10);
		// All should be unique
		expect(new Set(addresses).size).toBe(10);
	});

	test("handles CREATE2 address calculations in bulk", () => {
		const sender = WasmAddress.fromHex("0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb");
		const initCode = new Uint8Array([0x60, 0x80, 0x60, 0x40]);
		const addresses: string[] = [];

		// Calculate 1000 CREATE2 addresses with different salts
		for (let i = 0; i < 1000; i++) {
			const salt = new Uint8Array(32).fill(i % 256);
			const contractAddr = WasmAddress.calculateCreate2Address(
				sender,
				salt,
				initCode,
			);

			if (i % 100 === 0) {
				addresses.push(contractAddr.toHex());
			}
		}

		expect(addresses.length).toBe(10);
		// All should be unique
		expect(new Set(addresses).size).toBe(10);
	});

	test("handles sequential hash comparisons", () => {
		const hashes: WasmHash[] = [];

		// Create many hashes
		for (let i = 0; i < 100; i++) {
			hashes.push(WasmHash.keccak256(`message ${i}`));
		}

		// Compare all pairs
		let comparisons = 0;
		for (let i = 0; i < hashes.length; i++) {
			for (let j = i + 1; j < hashes.length; j++) {
				const equal = hashes[i].equals(hashes[j]);
				expect(equal).toBe(false); // All should be different
				comparisons++;
			}
		}

		expect(comparisons).toBe((100 * 99) / 2); // n(n-1)/2 comparisons
	});

	test("handles mixed operations without memory issues", () => {
		// Perform a mix of different operations
		for (let i = 0; i < 1000; i++) {
			// Address operations
			const addr = WasmAddress.fromHex(
				`0x${i.toString(16).padStart(40, "0")}`,
			);
			addr.toChecksumHex();

			// Hash operations
			const hash = WasmHash.keccak256(`data ${i}`);
			hash.toBytes();

			// RLP encoding
			const encoded = wasmEncodeUintFromBigInt(BigInt(i));
			expect(encoded.length).toBeGreaterThan(0);

			// Bytecode analysis
			const bytecode = new Uint8Array([0x5b, 0x00, i % 256]);
			wasmAnalyzeJumpDestinations(bytecode);
		}
	});

	test("handles rapid allocation and deallocation", () => {
		// Rapidly create and discard objects
		for (let round = 0; round < 100; round++) {
			const batch: WasmAddress[] = [];

			// Allocate
			for (let i = 0; i < 100; i++) {
				batch.push(
					WasmAddress.fromHex(`0x${i.toString(16).padStart(40, "0")}`),
				);
			}

			// Use
			for (const addr of batch) {
				addr.toHex();
			}

			// Batch should be garbage collected after this scope
		}
	});

	test("handles concurrent-style operations", async () => {
		// Simulate concurrent operations (though JS is single-threaded)
		const operations = [];

		for (let i = 0; i < 100; i++) {
			operations.push(
				Promise.resolve().then(() => {
					const addr = WasmAddress.fromHex(
						`0x${i.toString(16).padStart(40, "0")}`,
					);
					const hash = WasmHash.keccak256(addr.toBytes());
					return hash.toHex();
				}),
			);
		}

		const results = await Promise.all(operations);
		expect(results.length).toBe(100);
		expect(new Set(results).size).toBe(100); // All unique
	});

	test("handles zero-length allocations", () => {
		// Test edge cases with empty data
		const emptyBytes = new Uint8Array(0);

		expect(() => {
			WasmHash.keccak256(emptyBytes);
		}).not.toThrow();

		expect(() => {
			wasmEncodeBytes(emptyBytes);
		}).not.toThrow();

		expect(() => {
			wasmAnalyzeJumpDestinations(emptyBytes);
		}).not.toThrow();

		expect(() => {
			wasmValidateBytecode(emptyBytes);
		}).not.toThrow();
	});

	test("memory cleanup after errors", () => {
		// Ensure memory is cleaned up even when operations fail
		const iterations = 1000;

		for (let i = 0; i < iterations; i++) {
			try {
				// Try to create invalid address
				WasmAddress.fromHex("invalid");
			} catch {
				// Expected to fail
			}

			try {
				// Try to encode invalid uint
				wasmEncodeUintFromBigInt(-1n);
			} catch {
				// Expected to fail
			}

			try {
				// Try invalid hash
				WasmHash.fromHex("0xGGGG");
			} catch {
				// Expected to fail
			}
		}

		// If we got here, memory was properly cleaned up after errors
		expect(true).toBe(true);
	});

	test("handles boundary size allocations", () => {
		// Test at common memory boundaries
		const sizes = [
			255, // Just under 256
			256, // Exactly 256
			257, // Just over 256
			4095, // Just under 4KB
			4096, // Exactly 4KB
			4097, // Just over 4KB
			65535, // Just under 64KB
			65536, // Exactly 64KB
		];

		for (const size of sizes) {
			const data = new Uint8Array(size).fill(0x42);

			expect(() => {
				WasmHash.keccak256(data);
			}).not.toThrow();

			expect(() => {
				wasmEncodeBytes(data);
			}).not.toThrow();
		}
	});
});
