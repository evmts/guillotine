/**
 * WASM Address parity tests
 * Validates WASM implementation produces identical results to native FFI
 */

import { test, expect, describe } from "bun:test";
import { Address as NativeAddress } from "../../native/primitives/address.native";
import { Address as WasmAddress } from "./address.wasm";

describe("WASM Address parity", () => {
	test("fromHex produces identical results", () => {
		const testCases = [
			"0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
			"0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb",
			"0x0000000000000000000000000000000000000000",
			"0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
			"d8dA6BF26964aF9D7eEd9e03E53415D37aA96045", // without 0x prefix
		];

		for (const hex of testCases) {
			const native = NativeAddress.fromHex(hex);
			const wasm = WasmAddress.fromHex(hex);

			expect(native.toHex()).toBe(wasm.toHex());
			expect(native.toChecksumHex()).toBe(wasm.toChecksumHex());
			expect(native.toString()).toBe(wasm.toString());
		}
	});

	test("fromBytes produces identical results", () => {
		const testBytes = [
			new Uint8Array(20).fill(0),
			new Uint8Array(20).fill(0xff),
			new Uint8Array([
				0xd8, 0xda, 0x6b, 0xf2, 0x69, 0x64, 0xaf, 0x9d, 0x7e, 0xed,
				0x9e, 0x03, 0xe5, 0x34, 0x15, 0xd3, 0x7a, 0xa9, 0x60, 0x45,
			]),
		];

		for (const bytes of testBytes) {
			const native = NativeAddress.fromBytes(bytes);
			const wasm = WasmAddress.fromBytes(bytes);

			expect(native.toHex()).toBe(wasm.toHex());
			expect(native.toChecksumHex()).toBe(wasm.toChecksumHex());
		}
	});

	test("toHex produces identical results", () => {
		const addresses = [
			"0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
			"0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb",
			"0x0000000000000000000000000000000000000000",
		];

		for (const addr of addresses) {
			const native = NativeAddress.fromHex(addr);
			const wasm = WasmAddress.fromHex(addr);

			const nativeHex = native.toHex();
			const wasmHex = wasm.toHex();

			expect(nativeHex).toBe(wasmHex);
			expect(nativeHex.startsWith("0x")).toBe(true);
			expect(nativeHex.length).toBe(42);
		}
	});

	test("toChecksumHex produces identical results", () => {
		const addresses = [
			"0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
			"0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb",
			"0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
			"0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
		];

		for (const addr of addresses) {
			const native = NativeAddress.fromHex(addr);
			const wasm = WasmAddress.fromHex(addr);

			const nativeChecksum = native.toChecksumHex();
			const wasmChecksum = wasm.toChecksumHex();

			expect(nativeChecksum).toBe(wasmChecksum);
			// Verify it matches the input (already checksummed)
			expect(nativeChecksum).toBe(addr);
		}
	});

	test("checksum validation matches native", () => {
		const testCases = [
			{ hex: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", valid: true },
			{ hex: "0xD8DA6BF26964AF9D7EED9E03E53415D37AA96045", valid: false },
			{ hex: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb", valid: true },
			{ hex: "0x742D35CC6634C0532925A3B844BC9E7595F0BEB", valid: false },
			{ hex: "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", valid: true },
			{ hex: "0x5AAEB6053F3E94C9B9A09F33669435E7EF1BEAED", valid: false },
		];

		for (const { hex, valid } of testCases) {
			const nativeValid = NativeAddress.validateChecksum(hex);
			const wasmValid = WasmAddress.validateChecksum(hex);

			expect(nativeValid).toBe(wasmValid);
			expect(nativeValid).toBe(valid);
		}
	});

	test("isZero matches native", () => {
		const zeroAddr = "0x0000000000000000000000000000000000000000";
		const nonZeroAddr = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";

		const nativeZero = NativeAddress.fromHex(zeroAddr);
		const wasmZero = WasmAddress.fromHex(zeroAddr);
		expect(nativeZero.isZero()).toBe(wasmZero.isZero());
		expect(nativeZero.isZero()).toBe(true);

		const nativeNonZero = NativeAddress.fromHex(nonZeroAddr);
		const wasmNonZero = WasmAddress.fromHex(nonZeroAddr);
		expect(nativeNonZero.isZero()).toBe(wasmNonZero.isZero());
		expect(nativeNonZero.isZero()).toBe(false);
	});

	test("equals matches native", () => {
		const addr1 = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
		const addr2 = "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb";
		const addr3 = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"; // same as addr1

		const native1 = NativeAddress.fromHex(addr1);
		const native2 = NativeAddress.fromHex(addr2);
		const native3 = NativeAddress.fromHex(addr3);

		const wasm1 = WasmAddress.fromHex(addr1);
		const wasm2 = WasmAddress.fromHex(addr2);
		const wasm3 = WasmAddress.fromHex(addr3);

		// Same address equality
		expect(native1.equals(native1)).toBe(wasm1.equals(wasm1));
		expect(native1.equals(native1)).toBe(true);

		// Different addresses
		expect(native1.equals(native2)).toBe(wasm1.equals(wasm2));
		expect(native1.equals(native2)).toBe(false);

		// Equal addresses (different instances)
		expect(native1.equals(native3)).toBe(wasm1.equals(wasm3));
		expect(native1.equals(native3)).toBe(true);
	});

	test("CREATE address calculation matches", () => {
		const testCases = [
			{ sender: "0x6ac7ea33f8831ea9dcc53393aaa88b25a785dbf0", nonce: 0 },
			{ sender: "0x6ac7ea33f8831ea9dcc53393aaa88b25a785dbf0", nonce: 1 },
			{ sender: "0x6ac7ea33f8831ea9dcc53393aaa88b25a785dbf0", nonce: 255 },
			{ sender: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", nonce: 0 },
			{ sender: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", nonce: 100 },
		];

		for (const { sender, nonce } of testCases) {
			const nativeSender = NativeAddress.fromHex(sender);
			const wasmSender = WasmAddress.fromHex(sender);

			const nativeCreate = NativeAddress.calculateCreateAddress(nativeSender, nonce);
			const wasmCreate = WasmAddress.calculateCreateAddress(wasmSender, nonce);

			expect(nativeCreate.toHex()).toBe(wasmCreate.toHex());
			expect(nativeCreate.toChecksumHex()).toBe(wasmCreate.toChecksumHex());
		}
	});

	test("CREATE2 address calculation matches", () => {
		const sender = "0x0000000000000000000000000000000000000000";
		const salt = new Uint8Array(32).fill(0);
		const initCode = new Uint8Array([0x00]); // Simple init code

		const nativeSender = NativeAddress.fromHex(sender);
		const wasmSender = WasmAddress.fromHex(sender);

		const nativeCreate2 = NativeAddress.calculateCreate2Address(
			nativeSender,
			salt,
			initCode,
		);
		const wasmCreate2 = WasmAddress.calculateCreate2Address(
			wasmSender,
			salt,
			initCode,
		);

		expect(nativeCreate2.toHex()).toBe(wasmCreate2.toHex());
		expect(nativeCreate2.toChecksumHex()).toBe(wasmCreate2.toChecksumHex());
	});

	test("CREATE2 with different salts and init codes", () => {
		const sender = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
		const nativeSender = NativeAddress.fromHex(sender);
		const wasmSender = WasmAddress.fromHex(sender);

		// Test with different salts
		const salts = [
			new Uint8Array(32).fill(0),
			new Uint8Array(32).fill(0xff),
			new Uint8Array(32).fill(0x42),
		];

		// Test with different init codes
		const initCodes = [
			new Uint8Array([0x60, 0x80, 0x60, 0x40]), // Simple contract
			new Uint8Array([0x00]), // Minimal
			new Uint8Array(100).fill(0x60), // Larger code
		];

		for (const salt of salts) {
			for (const initCode of initCodes) {
				const nativeCreate2 = NativeAddress.calculateCreate2Address(
					nativeSender,
					salt,
					initCode,
				);
				const wasmCreate2 = WasmAddress.calculateCreate2Address(
					wasmSender,
					salt,
					initCode,
				);

				expect(nativeCreate2.toHex()).toBe(wasmCreate2.toHex());
			}
		}
	});

	test("toBytes produces identical results", () => {
		const addresses = [
			"0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
			"0x0000000000000000000000000000000000000000",
			"0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
		];

		for (const addr of addresses) {
			const native = NativeAddress.fromHex(addr);
			const wasm = WasmAddress.fromHex(addr);

			const nativeBytes = native.toBytes();
			const wasmBytes = wasm.toBytes();

			expect(nativeBytes.length).toBe(20);
			expect(wasmBytes.length).toBe(20);
			expect(Buffer.from(nativeBytes)).toEqual(Buffer.from(wasmBytes));
		}
	});

	test("error handling matches native", () => {
		const invalidInputs = [
			"not-hex",
			"0x",
			"0xGGGG",
			"0x123", // too short
			"0x" + "F".repeat(41), // too long
			"0x-1234567890123456789012345678901234567890",
		];

		for (const invalid of invalidInputs) {
			let nativeError: Error | null = null;
			let wasmError: Error | null = null;

			try {
				NativeAddress.fromHex(invalid);
			} catch (e) {
				nativeError = e as Error;
			}

			try {
				WasmAddress.fromHex(invalid);
			} catch (e) {
				wasmError = e as Error;
			}

			// Both should throw errors
			expect(nativeError).not.toBeNull();
			expect(wasmError).not.toBeNull();
		}
	});

	test("invalid byte length throws error", () => {
		const invalidLengths = [
			new Uint8Array(19),
			new Uint8Array(21),
			new Uint8Array(0),
			new Uint8Array(32),
		];

		for (const bytes of invalidLengths) {
			expect(() => NativeAddress.fromBytes(bytes)).toThrow();
			expect(() => WasmAddress.fromBytes(bytes)).toThrow();
		}
	});
});
