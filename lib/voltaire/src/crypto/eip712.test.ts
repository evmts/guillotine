import { describe, expect, test } from "bun:test";
import {
	type TypedData,
	type TypedDataDomain,
	hashDomain,
	hashTypedData,
} from "./eip712.ts";

describe("EIP-712 Type Hashing", () => {
	test("should hash simple domain separator", () => {
		const domain: TypedDataDomain = {
			name: "Ether Mail",
			version: "1",
			chainId: 1,
			verifyingContract:
				"0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC" as `0x${string}`,
		};

		const hash = hashDomain(domain);
		expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
		expect(hash).not.toBe(
			"0x0000000000000000000000000000000000000000000000000000000000000000",
		);
	});

	test("should produce consistent domain hashes", () => {
		const domain: TypedDataDomain = {
			name: "Test App",
			version: "1",
			chainId: 1,
		};

		const hash1 = hashDomain(domain);
		const hash2 = hashDomain(domain);
		expect(hash1).toBe(hash2);
	});

	test("should handle minimal domain", () => {
		const domain: TypedDataDomain = {
			name: "MinimalDomain",
		};

		const hash = hashDomain(domain);
		expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
	});

	test("should handle full domain with all fields", () => {
		const domain: TypedDataDomain = {
			name: "Full Domain",
			version: "2.0",
			chainId: 1,
			verifyingContract:
				"0x1111111111111111111111111111111111111111" as `0x${string}`,
			salt: "0x0000000000000000000000000000000000000000000000000000000000000001" as `0x${string}`,
		};

		const hash = hashDomain(domain);
		expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
	});
});

describe("EIP-712 Typed Data Hashing", () => {
	test("should hash simple typed message", () => {
		const typedData: TypedData = {
			types: {
				Person: [
					{ name: "name", type: "string" },
					{ name: "wallet", type: "address" },
				],
			},
			primaryType: "Person",
			domain: {
				name: "Ether Mail",
				version: "1",
				chainId: 1,
			},
			message: {
				name: "Bob",
				wallet: "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB",
			},
		};

		const hash = hashTypedData(typedData);
		expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
		expect(hash).not.toBe(
			"0x0000000000000000000000000000000000000000000000000000000000000000",
		);
	});

	test("should produce consistent hashes", () => {
		const typedData: TypedData = {
			types: {
				Message: [{ name: "content", type: "string" }],
			},
			primaryType: "Message",
			domain: {
				name: "Test",
				version: "1",
			},
			message: {
				content: "Hello, EIP-712!",
			},
		};

		const hash1 = hashTypedData(typedData);
		const hash2 = hashTypedData(typedData);
		expect(hash1).toBe(hash2);
	});

	test("should handle nested structures", () => {
		const typedData: TypedData = {
			types: {
				Person: [
					{ name: "name", type: "string" },
					{ name: "wallet", type: "address" },
				],
				Mail: [
					{ name: "from", type: "Person" },
					{ name: "to", type: "Person" },
					{ name: "contents", type: "string" },
				],
			},
			primaryType: "Mail",
			domain: {
				name: "Ether Mail",
				version: "1",
				chainId: 1,
			},
			message: {
				from: {
					name: "Alice",
					wallet: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
				},
				to: {
					name: "Bob",
					wallet: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
				},
				contents: "Hello, Bob!",
			},
		};

		const hash = hashTypedData(typedData);
		expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
	});

	test("should handle different data types", () => {
		const typedData: TypedData = {
			types: {
				Transaction: [
					{ name: "to", type: "address" },
					{ name: "value", type: "uint256" },
					{ name: "gas", type: "uint256" },
					{ name: "nonce", type: "uint256" },
					{ name: "data", type: "bytes" },
				],
			},
			primaryType: "Transaction",
			domain: {
				name: "MyDApp",
				version: "1",
				chainId: 1,
			},
			message: {
				to: "0x1111111111111111111111111111111111111111",
				value: "1000000000000000000",
				gas: "21000",
				nonce: "0",
				data: "0x",
			},
		};

		const hash = hashTypedData(typedData);
		expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
	});

	test("should handle boolean and number types", () => {
		const typedData: TypedData = {
			types: {
				Settings: [
					{ name: "enabled", type: "bool" },
					{ name: "count", type: "uint256" },
				],
			},
			primaryType: "Settings",
			domain: {
				name: "Settings",
				version: "1",
			},
			message: {
				enabled: true,
				count: 42,
			},
		};

		const hash = hashTypedData(typedData);
		expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
	});

	test("should handle arrays", () => {
		const typedData: TypedData = {
			types: {
				Numbers: [{ name: "values", type: "uint256[]" }],
			},
			primaryType: "Numbers",
			domain: {
				name: "Arrays",
				version: "1",
			},
			message: {
				values: [1, 2, 3, 4, 5],
			},
		};

		const hash = hashTypedData(typedData);
		expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
	});

	test("EIP-712 example from specification", () => {
		// Example from EIP-712 specification
		const typedData: TypedData = {
			types: {
				Person: [
					{ name: "name", type: "string" },
					{ name: "wallet", type: "address" },
				],
				Mail: [
					{ name: "from", type: "Person" },
					{ name: "to", type: "Person" },
					{ name: "contents", type: "string" },
				],
			},
			primaryType: "Mail",
			domain: {
				name: "Ether Mail",
				version: "1",
				chainId: 1,
				verifyingContract:
					"0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC" as `0x${string}`,
			},
			message: {
				from: {
					name: "Cow",
					wallet: "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826",
				},
				to: {
					name: "Bob",
					wallet: "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB",
				},
				contents: "Hello, Bob!",
			},
		};

		const hash = hashTypedData(typedData);
		expect(hash).toMatch(/^0x[0-9a-f]{64}$/);

		// The hash should be deterministic
		const hash2 = hashTypedData(typedData);
		expect(hash).toBe(hash2);
	});

	test("should handle multiple levels of nesting", () => {
		const typedData: TypedData = {
			types: {
				Address: [
					{ name: "street", type: "string" },
					{ name: "city", type: "string" },
				],
				Person: [
					{ name: "name", type: "string" },
					{ name: "home", type: "Address" },
				],
				Mail: [
					{ name: "sender", type: "Person" },
					{ name: "message", type: "string" },
				],
			},
			primaryType: "Mail",
			domain: {
				name: "Nested Test",
				version: "1",
			},
			message: {
				sender: {
					name: "Alice",
					home: {
						street: "123 Main St",
						city: "New York",
					},
				},
				message: "Deep nesting test",
			},
		};

		const hash = hashTypedData(typedData);
		expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
	});

	test("different messages should produce different hashes", () => {
		const domain = {
			name: "Test",
			version: "1",
		};

		const typedData1: TypedData = {
			types: {
				Message: [{ name: "text", type: "string" }],
			},
			primaryType: "Message",
			domain,
			message: {
				text: "Message 1",
			},
		};

		const typedData2: TypedData = {
			types: {
				Message: [{ name: "text", type: "string" }],
			},
			primaryType: "Message",
			domain,
			message: {
				text: "Message 2",
			},
		};

		const hash1 = hashTypedData(typedData1);
		const hash2 = hashTypedData(typedData2);
		expect(hash1).not.toBe(hash2);
	});

	test("should handle bytes32 type", () => {
		const typedData: TypedData = {
			types: {
				Data: [{ name: "hash", type: "bytes32" }],
			},
			primaryType: "Data",
			domain: {
				name: "Bytes Test",
				version: "1",
			},
			message: {
				hash: "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
			},
		};

		const hash = hashTypedData(typedData);
		expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
	});
});

describe("EIP-712 Edge Cases", () => {
	test("should handle empty strings", () => {
		const typedData: TypedData = {
			types: {
				Message: [{ name: "text", type: "string" }],
			},
			primaryType: "Message",
			domain: {
				name: "Empty Test",
				version: "1",
			},
			message: {
				text: "",
			},
		};

		const hash = hashTypedData(typedData);
		expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
	});

	test("should handle zero values", () => {
		const typedData: TypedData = {
			types: {
				Numbers: [{ name: "value", type: "uint256" }],
			},
			primaryType: "Numbers",
			domain: {
				name: "Zero Test",
				version: "1",
			},
			message: {
				value: 0,
			},
		};

		const hash = hashTypedData(typedData);
		expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
	});

	test("should handle false boolean", () => {
		const typedData: TypedData = {
			types: {
				Flag: [{ name: "enabled", type: "bool" }],
			},
			primaryType: "Flag",
			domain: {
				name: "Bool Test",
				version: "1",
			},
			message: {
				enabled: false,
			},
		};

		const hash = hashTypedData(typedData);
		expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
	});

	test("should handle large numbers", () => {
		const typedData: TypedData = {
			types: {
				BigNumber: [{ name: "value", type: "uint256" }],
			},
			primaryType: "BigNumber",
			domain: {
				name: "Large Number Test",
				version: "1",
			},
			message: {
				value:
					"115792089237316195423570985008687907853269984665640564039457584007913129639935", // max uint256
			},
		};

		const hash = hashTypedData(typedData);
		expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
	});

	test("should handle domain with only name", () => {
		const typedData: TypedData = {
			types: {
				Simple: [{ name: "value", type: "uint256" }],
			},
			primaryType: "Simple",
			domain: {
				name: "MinimalDomain",
			},
			message: {
				value: 42,
			},
		};

		const hash = hashTypedData(typedData);
		expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
	});
});
