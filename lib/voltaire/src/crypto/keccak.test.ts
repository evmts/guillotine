import { describe, expect, test } from "bun:test";
import { keccak256, keccak256Empty } from "./keccak.ts";

describe("keccak256", () => {
	test("should hash empty bytes", () => {
		const result = keccak256(new Uint8Array([]));
		expect(result).toBe(
			"0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
		);
	});

	test("should hash simple string via hex", () => {
		// "hello" = 0x68656c6c6f
		const result = keccak256("0x68656c6c6f");
		expect(result).toBe(
			"0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8",
		);
	});

	test("should hash Uint8Array", () => {
		// "hello" as bytes
		const data = new Uint8Array([0x68, 0x65, 0x6c, 0x6c, 0x6f]);
		const result = keccak256(data);
		expect(result).toBe(
			"0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8",
		);
	});

	test("should match NIST test vector 1", () => {
		// Empty message
		const result = keccak256(new Uint8Array([]));
		expect(result).toBe(
			"0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
		);
	});

	test("should match NIST test vector 2", () => {
		// Single byte 0xcc
		const data = new Uint8Array([0xcc]);
		const result = keccak256(data);
		expect(result).toBe(
			"0xeead6dbfc7340a56caedc044696a168870549a6a7f6f56961e84a54bd9970b8a",
		);
	});

	test("should match NIST test vector 3", () => {
		// Three bytes: 0x41fb
		const data = new Uint8Array([0x41, 0xfb]);
		const result = keccak256(data);
		expect(result).toBe(
			"0xa8eaceda4d47b3281a795ad9e1ea2122b407baf9aabcb9e18b5717b7873537d2",
		);
	});

	test("should handle hex string without 0x prefix", () => {
		const result = keccak256("68656c6c6f");
		expect(result).toBe(
			"0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8",
		);
	});

	test("should handle long data", () => {
		// 200 bytes of 0xa3
		const data = new Uint8Array(200).fill(0xa3);
		const result = keccak256(data);
		expect(result).toBe(
			"0x3a57666b048777f2c953dc4456f45a2588e1cb6f2da760122d530ac2ce607d4a",
		);
	});
});

describe("keccak256Empty", () => {
	test("should return pre-computed empty hash", () => {
		const result = keccak256Empty();
		expect(result).toBe(
			"0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
		);
	});

	test("should match keccak256 of empty bytes", () => {
		const emptyHash = keccak256Empty();
		const computedHash = keccak256(new Uint8Array([]));
		expect(emptyHash).toBe(computedHash);
	});
});
