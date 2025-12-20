import { describe, expect, test } from "bun:test";
import { hashMessage } from "./eip191.ts";

describe("hashMessage", () => {
	test("should hash simple message from string", () => {
		const result = hashMessage("hello");
		// "\x19Ethereum Signed Message:\n5hello"
		expect(result).toBe(
			"0x50b2c43fd39106bafbba0da34fc430e1f91e3c96ea2acee2bc34119f92b37750",
		);
	});

	test("should hash message from Uint8Array", () => {
		const message = new TextEncoder().encode("hello");
		const result = hashMessage(message);
		expect(result).toBe(
			"0x50b2c43fd39106bafbba0da34fc430e1f91e3c96ea2acee2bc34119f92b37750",
		);
	});

	test("should hash longer message", () => {
		const message = "Hello, World!";
		const result = hashMessage(message);
		// Computed using the C implementation
		expect(result).toBe(
			"0xc8ee0d506e864589b799a645ddb88b08f5d39e8049f9f702b3b61fa15e55fc73",
		);
	});

	test("should handle unicode characters", () => {
		const message = "Hello 👋";
		const result = hashMessage(message);
		// Unicode should be properly encoded
		expect(result).toMatch(/^0x[0-9a-f]{64}$/);
	});

	test("should produce consistent hashes", () => {
		const message = "test message";
		const hash1 = hashMessage(message);
		const hash2 = hashMessage(message);
		expect(hash1).toBe(hash2);
	});
});
