/**
 * WASM RLP parity tests
 * Validates WASM implementation produces identical results to native FFI
 */

import { test, expect, describe } from "bun:test";
import {
	encodeBytes as nativeEncodeBytes,
	encodeUint as nativeEncodeUint,
	encodeUintFromBigInt as nativeEncodeUintFromBigInt,
	toHex as nativeToHex,
	fromHex as nativeFromHex,
} from "../../native/primitives/rlp.native";
import {
	encodeBytes as wasmEncodeBytes,
	encodeUint as wasmEncodeUint,
	encodeUintFromBigInt as wasmEncodeUintFromBigInt,
	toHex as wasmToHex,
	fromHex as wasmFromHex,
} from "./rlp.wasm";

describe("WASM RLP parity", () => {
	test("encodeBytes produces identical results for empty bytes", () => {
		const emptyBytes = new Uint8Array(0);

		const nativeEncoded = nativeEncodeBytes(emptyBytes);
		const wasmEncoded = wasmEncodeBytes(emptyBytes);

		expect(Buffer.from(nativeEncoded)).toEqual(Buffer.from(wasmEncoded));
		// Empty bytes should encode to 0x80
		expect(nativeEncoded[0]).toBe(0x80);
		expect(wasmEncoded[0]).toBe(0x80);
	});

	test("encodeBytes produces identical results for single byte", () => {
		const testCases = [
			new Uint8Array([0x00]),
			new Uint8Array([0x01]),
			new Uint8Array([0x7f]),
			new Uint8Array([0x80]),
			new Uint8Array([0xff]),
		];

		for (const bytes of testCases) {
			const nativeEncoded = nativeEncodeBytes(bytes);
			const wasmEncoded = wasmEncodeBytes(bytes);

			expect(Buffer.from(nativeEncoded)).toEqual(Buffer.from(wasmEncoded));
		}
	});

	test("encodeBytes produces identical results for short strings", () => {
		const testStrings = [
			"dog",
			"cat",
			"hello",
			"",
			"a",
			"Lorem ipsum dolor sit amet, consectetur", // 55 bytes (long string)
		];

		for (const str of testStrings) {
			const bytes = new TextEncoder().encode(str);
			const nativeEncoded = nativeEncodeBytes(bytes);
			const wasmEncoded = wasmEncodeBytes(bytes);

			expect(Buffer.from(nativeEncoded)).toEqual(Buffer.from(wasmEncoded));
		}
	});

	test("encodeBytes produces identical results for long strings", () => {
		// Create a string longer than 55 bytes
		const longString = "a".repeat(100);
		const bytes = new TextEncoder().encode(longString);

		const nativeEncoded = nativeEncodeBytes(bytes);
		const wasmEncoded = wasmEncodeBytes(bytes);

		expect(Buffer.from(nativeEncoded)).toEqual(Buffer.from(wasmEncoded));
	});

	test("encodeBytes produces identical results for various lengths", () => {
		const lengths = [0, 1, 10, 55, 56, 100, 255, 256, 1000];

		for (const len of lengths) {
			const bytes = new Uint8Array(len).fill(0x42);
			const nativeEncoded = nativeEncodeBytes(bytes);
			const wasmEncoded = wasmEncodeBytes(bytes);

			expect(Buffer.from(nativeEncoded)).toEqual(Buffer.from(wasmEncoded));
		}
	});

	test("encodeUint produces identical results for zero", () => {
		const zero = new Uint8Array(32).fill(0);

		const nativeEncoded = nativeEncodeUint(zero);
		const wasmEncoded = wasmEncodeUint(zero);

		expect(Buffer.from(nativeEncoded)).toEqual(Buffer.from(wasmEncoded));
	});

	test("encodeUint produces identical results for small numbers", () => {
		const testValues = [
			1n,
			127n,
			128n,
			255n,
			256n,
			65535n,
			65536n,
		];

		for (const value of testValues) {
			// Convert bigint to 32-byte buffer
			const hex = value.toString(16).padStart(64, "0");
			const bytes = new Uint8Array(32);
			for (let i = 0; i < 32; i++) {
				bytes[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
			}

			const nativeEncoded = nativeEncodeUint(bytes);
			const wasmEncoded = wasmEncodeUint(bytes);

			expect(Buffer.from(nativeEncoded)).toEqual(Buffer.from(wasmEncoded));
		}
	});

	test("encodeUint produces identical results for large numbers", () => {
		const testValues = [
			2n ** 64n - 1n,
			2n ** 128n - 1n,
			2n ** 255n - 1n,
			2n ** 256n - 1n,
		];

		for (const value of testValues) {
			const hex = value.toString(16).padStart(64, "0");
			const bytes = new Uint8Array(32);
			for (let i = 0; i < 32; i++) {
				bytes[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
			}

			const nativeEncoded = nativeEncodeUint(bytes);
			const wasmEncoded = wasmEncodeUint(bytes);

			expect(Buffer.from(nativeEncoded)).toEqual(Buffer.from(wasmEncoded));
		}
	});

	test("encodeUint rejects non-32-byte input", () => {
		const invalidSizes = [
			new Uint8Array(0),
			new Uint8Array(16),
			new Uint8Array(31),
			new Uint8Array(33),
			new Uint8Array(64),
		];

		for (const bytes of invalidSizes) {
			expect(() => nativeEncodeUint(bytes)).toThrow();
			expect(() => wasmEncodeUint(bytes)).toThrow();
		}
	});

	test("encodeUintFromBigInt produces identical results", () => {
		const testValues = [
			0n,
			1n,
			127n,
			128n,
			255n,
			256n,
			1000n,
			65535n,
			2n ** 64n - 1n,
			2n ** 128n - 1n,
			2n ** 255n - 1n,
		];

		for (const value of testValues) {
			const nativeEncoded = nativeEncodeUintFromBigInt(value);
			const wasmEncoded = wasmEncodeUintFromBigInt(value);

			expect(Buffer.from(nativeEncoded)).toEqual(Buffer.from(wasmEncoded));
		}
	});

	test("toHex produces identical results", () => {
		const testBytes = [
			new Uint8Array([0x80]), // Empty string encoding
			new Uint8Array([0x01]), // Single byte
			new Uint8Array([0x82, 0x64, 0x6f, 0x67]), // "dog"
			new Uint8Array([0x00, 0xff, 0xaa, 0x55]),
		];

		for (const bytes of testBytes) {
			const nativeHex = nativeToHex(bytes);
			const wasmHex = wasmToHex(bytes);

			expect(nativeHex).toBe(wasmHex);
			expect(nativeHex.startsWith("0x")).toBe(true);
		}
	});

	test("fromHex produces identical results", () => {
		const testHexStrings = [
			"0x80", // Empty string
			"0x01",
			"0x8264ab67", // Random bytes
			"0x00ff",
			"80", // Without 0x prefix
		];

		for (const hex of testHexStrings) {
			const nativeBytes = nativeFromHex(hex);
			const wasmBytes = wasmFromHex(hex);

			expect(Buffer.from(nativeBytes)).toEqual(Buffer.from(wasmBytes));
		}
	});

	test("roundtrip encoding and hex conversion", () => {
		const testData = [
			new Uint8Array([0x64, 0x6f, 0x67]), // "dog"
			new Uint8Array([0x68, 0x65, 0x6c, 0x6c, 0x6f]), // "hello"
			new Uint8Array(0), // empty
			new Uint8Array(100).fill(0x42), // large data
		];

		for (const data of testData) {
			// Native roundtrip
			const nativeEncoded = nativeEncodeBytes(data);
			const nativeHex = nativeToHex(nativeEncoded);
			const nativeDecoded = nativeFromHex(nativeHex);

			// WASM roundtrip
			const wasmEncoded = wasmEncodeBytes(data);
			const wasmHex = wasmToHex(wasmEncoded);
			const wasmDecoded = wasmFromHex(wasmHex);

			// Verify roundtrip consistency
			expect(Buffer.from(nativeEncoded)).toEqual(Buffer.from(wasmEncoded));
			expect(nativeHex).toBe(wasmHex);
			expect(Buffer.from(nativeDecoded)).toEqual(Buffer.from(wasmDecoded));
		}
	});

	test("known RLP test vectors match native and WASM", () => {
		// Standard RLP test vectors
		const testVectors = [
			{
				input: new Uint8Array([]),
				expected: "0x80",
			},
			{
				input: new TextEncoder().encode("dog"),
				expected: "0x83646f67",
			},
			{
				input: new Uint8Array([0x0f]),
				expected: "0x0f",
			},
			{
				input: new Uint8Array([0x04, 0x00]),
				expected: "0x820400",
			},
		];

		for (const { input, expected } of testVectors) {
			const nativeEncoded = nativeEncodeBytes(input);
			const wasmEncoded = wasmEncodeBytes(input);

			const nativeHex = nativeToHex(nativeEncoded);
			const wasmHex = wasmToHex(wasmEncoded);

			expect(nativeHex).toBe(wasmHex);
			expect(nativeHex).toBe(expected);
		}
	});

	test("uint encoding matches known test vectors", () => {
		const testVectors = [
			{ value: 0n, expected: "0x80" },
			{ value: 15n, expected: "0x0f" },
			{ value: 1024n, expected: "0x820400" },
		];

		for (const { value, expected } of testVectors) {
			const nativeEncoded = nativeEncodeUintFromBigInt(value);
			const wasmEncoded = wasmEncodeUintFromBigInt(value);

			const nativeHex = nativeToHex(nativeEncoded);
			const wasmHex = wasmToHex(wasmEncoded);

			expect(nativeHex).toBe(wasmHex);
			expect(nativeHex).toBe(expected);
		}
	});

	test("handles maximum uint256 value", () => {
		const maxUint256 = 2n ** 256n - 1n;

		const nativeEncoded = nativeEncodeUintFromBigInt(maxUint256);
		const wasmEncoded = wasmEncodeUintFromBigInt(maxUint256);

		expect(Buffer.from(nativeEncoded)).toEqual(Buffer.from(wasmEncoded));

		// Both should produce same hex
		const nativeHex = nativeToHex(nativeEncoded);
		const wasmHex = wasmToHex(wasmEncoded);

		expect(nativeHex).toBe(wasmHex);
	});

	test("encodes ethereum transaction fields identically", () => {
		// Simulate encoding typical transaction fields
		const nonce = 0n;
		const gasPrice = 20000000000n; // 20 gwei
		const gasLimit = 21000n;
		const to = new Uint8Array(20).fill(0x42); // Example address
		const value = 1000000000000000000n; // 1 ETH
		const data = new Uint8Array(0);

		const fields = [
			nonce,
			gasPrice,
			gasLimit,
			to,
			value,
			data,
		];

		for (const field of fields) {
			if (typeof field === "bigint") {
				const nativeEncoded = nativeEncodeUintFromBigInt(field);
				const wasmEncoded = wasmEncodeUintFromBigInt(field);
				expect(Buffer.from(nativeEncoded)).toEqual(Buffer.from(wasmEncoded));
			} else {
				const nativeEncoded = nativeEncodeBytes(field);
				const wasmEncoded = wasmEncodeBytes(field);
				expect(Buffer.from(nativeEncoded)).toEqual(Buffer.from(wasmEncoded));
			}
		}
	});

	test("error handling matches native for invalid hex", () => {
		const invalidHexStrings = [
			"not-hex",
			"0xGGGG",
			"0x",
			"",
		];

		for (const invalid of invalidHexStrings) {
			let nativeError: Error | null = null;
			let wasmError: Error | null = null;

			try {
				nativeFromHex(invalid);
			} catch (e) {
				nativeError = e as Error;
			}

			try {
				wasmFromHex(invalid);
			} catch (e) {
				wasmError = e as Error;
			}

			// Both should throw errors (or neither should)
			expect(nativeError !== null).toBe(wasmError !== null);
		}
	});
});
