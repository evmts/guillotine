/**
 * WASM Keccak parity tests
 * Validates WASM implementation produces identical results to native FFI
 */

import { test, expect, describe } from "bun:test";
import {
	Hash as NativeHash,
	keccak256 as nativeKeccak256,
	eip191HashMessage as nativeEip191HashMessage,
} from "../../native/primitives/keccak.native";
import {
	Hash as WasmHash,
	keccak256 as wasmKeccak256,
	eip191HashMessage as wasmEip191HashMessage,
} from "./keccak.wasm";

describe("WASM Keccak parity", () => {
	test("keccak256 produces identical results for empty input", () => {
		const emptyBytes = new Uint8Array(0);

		const nativeHash = NativeHash.keccak256(emptyBytes);
		const wasmHash = WasmHash.keccak256(emptyBytes);

		expect(nativeHash.toHex()).toBe(wasmHash.toHex());
		// Known hash of empty string
		expect(nativeHash.toHex()).toBe(
			"0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
		);
	});

	test("keccak256 produces identical results for string input", () => {
		const testStrings = [
			"",
			"hello",
			"hello world",
			"The quick brown fox jumps over the lazy dog",
			"a".repeat(1000), // Long string
		];

		for (const str of testStrings) {
			const nativeHash = NativeHash.keccak256(str);
			const wasmHash = WasmHash.keccak256(str);

			expect(nativeHash.toHex()).toBe(wasmHash.toHex());
			expect(Buffer.from(nativeHash.toBytes())).toEqual(
				Buffer.from(wasmHash.toBytes()),
			);
		}
	});

	test("keccak256 produces identical results for byte arrays", () => {
		const testBytes = [
			new Uint8Array([0x00]),
			new Uint8Array([0xff]),
			new Uint8Array([0x00, 0x01, 0x02, 0x03]),
			new Uint8Array(100).fill(0x42),
			new Uint8Array(1000).fill(0xaa),
		];

		for (const bytes of testBytes) {
			const nativeHash = NativeHash.keccak256(bytes);
			const wasmHash = WasmHash.keccak256(bytes);

			expect(nativeHash.toHex()).toBe(wasmHash.toHex());
		}
	});

	test("keccak256 convenience function matches Hash.keccak256", () => {
		const testInputs = [
			"hello",
			new Uint8Array([0x42, 0x43, 0x44]),
			"",
			"The quick brown fox",
		];

		for (const input of testInputs) {
			const nativeHashHex = nativeKeccak256(input);
			const wasmHashHex = wasmKeccak256(input);

			expect(nativeHashHex).toBe(wasmHashHex);

			// Also verify it matches the class method
			const nativeHashClass = NativeHash.keccak256(input).toHex();
			const wasmHashClass = WasmHash.keccak256(input).toHex();

			expect(nativeHashHex).toBe(nativeHashClass);
			expect(wasmHashHex).toBe(wasmHashClass);
		}
	});

	test("known test vectors match native and WASM", () => {
		const testVectors = [
			{
				input: "",
				expected: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
			},
			{
				input: "hello",
				expected: "0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8",
			},
		];

		for (const { input, expected } of testVectors) {
			const nativeHash = nativeKeccak256(input);
			const wasmHash = wasmKeccak256(input);

			expect(nativeHash).toBe(wasmHash);
			expect(nativeHash).toBe(expected);
		}
	});

	test("fromHex produces identical results", () => {
		const testHexStrings = [
			"0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
			"0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8",
			"c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", // without 0x
		];

		for (const hex of testHexStrings) {
			const nativeHash = NativeHash.fromHex(hex);
			const wasmHash = WasmHash.fromHex(hex);

			expect(nativeHash.toHex()).toBe(wasmHash.toHex());
			expect(Buffer.from(nativeHash.toBytes())).toEqual(
				Buffer.from(wasmHash.toBytes()),
			);
		}
	});

	test("fromBytes produces identical results", () => {
		const testBytes = [
			new Uint8Array(32).fill(0),
			new Uint8Array(32).fill(0xff),
			new Uint8Array([
				0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c,
				0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
				0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b,
				0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
			]),
		];

		for (const bytes of testBytes) {
			const nativeHash = NativeHash.fromBytes(bytes);
			const wasmHash = WasmHash.fromBytes(bytes);

			expect(nativeHash.toHex()).toBe(wasmHash.toHex());
			expect(Buffer.from(nativeHash.toBytes())).toEqual(
				Buffer.from(wasmHash.toBytes()),
			);
		}
	});

	test("toHex produces identical results", () => {
		const testInputs = ["hello", "world", "", "test"];

		for (const input of testInputs) {
			const nativeHash = NativeHash.keccak256(input);
			const wasmHash = WasmHash.keccak256(input);

			const nativeHex = nativeHash.toHex();
			const wasmHex = wasmHash.toHex();

			expect(nativeHex).toBe(wasmHex);
			expect(nativeHex.startsWith("0x")).toBe(true);
			expect(nativeHex.length).toBe(66); // 0x + 64 hex chars
		}
	});

	test("toBytes produces identical results", () => {
		const testInputs = ["hello", "world", "", "test"];

		for (const input of testInputs) {
			const nativeHash = NativeHash.keccak256(input);
			const wasmHash = WasmHash.keccak256(input);

			const nativeBytes = nativeHash.toBytes();
			const wasmBytes = wasmHash.toBytes();

			expect(nativeBytes.length).toBe(32);
			expect(wasmBytes.length).toBe(32);
			expect(Buffer.from(nativeBytes)).toEqual(Buffer.from(wasmBytes));
		}
	});

	test("equals matches native for identical hashes", () => {
		const input = "hello world";

		const nativeHash1 = NativeHash.keccak256(input);
		const nativeHash2 = NativeHash.keccak256(input);

		const wasmHash1 = WasmHash.keccak256(input);
		const wasmHash2 = WasmHash.keccak256(input);

		expect(nativeHash1.equals(nativeHash2)).toBe(wasmHash1.equals(wasmHash2));
		expect(nativeHash1.equals(nativeHash2)).toBe(true);
	});

	test("equals matches native for different hashes", () => {
		const nativeHash1 = NativeHash.keccak256("hello");
		const nativeHash2 = NativeHash.keccak256("world");

		const wasmHash1 = WasmHash.keccak256("hello");
		const wasmHash2 = WasmHash.keccak256("world");

		expect(nativeHash1.equals(nativeHash2)).toBe(wasmHash1.equals(wasmHash2));
		expect(nativeHash1.equals(nativeHash2)).toBe(false);
	});

	test("toString matches toHex", () => {
		const input = "test string";

		const nativeHash = NativeHash.keccak256(input);
		const wasmHash = WasmHash.keccak256(input);

		expect(nativeHash.toString()).toBe(nativeHash.toHex());
		expect(wasmHash.toString()).toBe(wasmHash.toHex());
		expect(nativeHash.toString()).toBe(wasmHash.toString());
	});

	test("eip191HashMessage produces identical results", () => {
		const testMessages = [
			"Hello, Ethereum!",
			"",
			"Test message",
			"A".repeat(1000),
		];

		for (const message of testMessages) {
			const nativeHash = nativeEip191HashMessage(message);
			const wasmHash = wasmEip191HashMessage(message);

			expect(nativeHash.toHex()).toBe(wasmHash.toHex());
			expect(Buffer.from(nativeHash.toBytes())).toEqual(
				Buffer.from(wasmHash.toBytes()),
			);
		}
	});

	test("eip191HashMessage with byte arrays", () => {
		const testBytes = [
			new Uint8Array([0x48, 0x65, 0x6c, 0x6c, 0x6f]), // "Hello"
			new Uint8Array(0),
			new Uint8Array(100).fill(0x42),
		];

		for (const bytes of testBytes) {
			const nativeHash = nativeEip191HashMessage(bytes);
			const wasmHash = wasmEip191HashMessage(bytes);

			expect(nativeHash.toHex()).toBe(wasmHash.toHex());
		}
	});

	test("eip191HashMessage differs from plain keccak256", () => {
		const message = "Test message";

		const nativePlain = NativeHash.keccak256(message);
		const nativeEip191 = nativeEip191HashMessage(message);

		const wasmPlain = WasmHash.keccak256(message);
		const wasmEip191 = wasmEip191HashMessage(message);

		// EIP-191 hash should differ from plain hash
		expect(nativePlain.toHex()).not.toBe(nativeEip191.toHex());
		expect(wasmPlain.toHex()).not.toBe(wasmEip191.toHex());

		// But native and WASM should match
		expect(nativeEip191.toHex()).toBe(wasmEip191.toHex());
	});

	test("hash roundtrip via hex", () => {
		const testInputs = ["hello", "world", "test"];

		for (const input of testInputs) {
			// Native roundtrip
			const nativeHash1 = NativeHash.keccak256(input);
			const nativeHex = nativeHash1.toHex();
			const nativeHash2 = NativeHash.fromHex(nativeHex);

			expect(nativeHash1.equals(nativeHash2)).toBe(true);

			// WASM roundtrip
			const wasmHash1 = WasmHash.keccak256(input);
			const wasmHex = wasmHash1.toHex();
			const wasmHash2 = WasmHash.fromHex(wasmHex);

			expect(wasmHash1.equals(wasmHash2)).toBe(true);

			// Native and WASM should match
			expect(nativeHex).toBe(wasmHex);
		}
	});

	test("hash roundtrip via bytes", () => {
		const testInputs = ["hello", "world", "test"];

		for (const input of testInputs) {
			// Native roundtrip
			const nativeHash1 = NativeHash.keccak256(input);
			const nativeBytes = nativeHash1.toBytes();
			const nativeHash2 = NativeHash.fromBytes(nativeBytes);

			expect(nativeHash1.equals(nativeHash2)).toBe(true);

			// WASM roundtrip
			const wasmHash1 = WasmHash.keccak256(input);
			const wasmBytes = wasmHash1.toBytes();
			const wasmHash2 = WasmHash.fromBytes(wasmBytes);

			expect(wasmHash1.equals(wasmHash2)).toBe(true);

			// Native and WASM bytes should match
			expect(Buffer.from(nativeBytes)).toEqual(Buffer.from(wasmBytes));
		}
	});

	test("error handling for invalid hash length", () => {
		const invalidLengths = [
			new Uint8Array(0),
			new Uint8Array(16),
			new Uint8Array(31),
			new Uint8Array(33),
			new Uint8Array(64),
		];

		for (const bytes of invalidLengths) {
			expect(() => NativeHash.fromBytes(bytes)).toThrow();
			expect(() => WasmHash.fromBytes(bytes)).toThrow();
		}
	});

	test("error handling for invalid hex", () => {
		const invalidHex = [
			"not-hex",
			"0xGGGG",
			"0x123", // too short
			"0x" + "F".repeat(65), // too long
		];

		for (const hex of invalidHex) {
			let nativeError: Error | null = null;
			let wasmError: Error | null = null;

			try {
				NativeHash.fromHex(hex);
			} catch (e) {
				nativeError = e as Error;
			}

			try {
				WasmHash.fromHex(hex);
			} catch (e) {
				wasmError = e as Error;
			}

			// Both should throw
			expect(nativeError).not.toBeNull();
			expect(wasmError).not.toBeNull();
		}
	});

	test("handles large data inputs", () => {
		// Test with 1MB of data
		const largeData = new Uint8Array(1024 * 1024).fill(0x42);

		const nativeHash = NativeHash.keccak256(largeData);
		const wasmHash = WasmHash.keccak256(largeData);

		expect(nativeHash.toHex()).toBe(wasmHash.toHex());
	});

	test("hashing ethereum address produces identical results", () => {
		// Simulate hashing an address for checksum calculation
		const addressBytes = new Uint8Array([
			0xd8, 0xda, 0x6b, 0xf2, 0x69, 0x64, 0xaf, 0x9d, 0x7e, 0xed,
			0x9e, 0x03, 0xe5, 0x34, 0x15, 0xd3, 0x7a, 0xa9, 0x60, 0x45,
		]);

		const nativeHash = NativeHash.keccak256(addressBytes);
		const wasmHash = WasmHash.keccak256(addressBytes);

		expect(nativeHash.toHex()).toBe(wasmHash.toHex());
	});

	test("sequential hashing produces independent results", () => {
		// Ensure each hash is independent (no state pollution)
		const inputs = ["first", "second", "third"];

		for (const input of inputs) {
			const nativeHash = NativeHash.keccak256(input);
			const wasmHash = WasmHash.keccak256(input);

			expect(nativeHash.toHex()).toBe(wasmHash.toHex());
		}

		// Hash the same input again - should get same result
		const firstAgainNative = NativeHash.keccak256("first");
		const firstAgainWasm = WasmHash.keccak256("first");

		expect(firstAgainNative.toHex()).toBe(firstAgainWasm.toHex());
		expect(firstAgainNative.toHex()).toBe(NativeHash.keccak256("first").toHex());
	});
});
