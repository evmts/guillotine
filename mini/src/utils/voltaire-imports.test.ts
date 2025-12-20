/**
 * Tests for voltaire imports setup
 *
 * NOTE: Currently using placeholder implementations until voltaire is built.
 * See src/utils/voltaire-imports.ts for details.
 */
import { describe, it, expect } from "vitest";
import {
	Address,
	Hash,
	Hex,
	Uint,
	Hardfork,
	GasConstants,
	Opcode,
} from "./voltaire-imports";

describe("Voltaire Imports (Placeholder)", () => {
	it("should import Address type with basic functionality", () => {
		const addr = Address.fromHex(
			"0xa0cf798816d4b9b9866b5330eea46a18382f251e",
		);
		expect(addr).toBeDefined();
		expect(addr.length).toBe(20); // Address is 20 bytes
		expect(Address.toHex(addr)).toMatch(/^0x[a-f0-9]{40}$/);
	});

	it("should import Uint types with basic operations", () => {
		// Test U256
		const value = Uint.U256.fromNumber(42);
		expect(value).toBeDefined();
		expect(Uint.U256.toBigInt(value)).toBe(42n);

		// Test hex conversion
		const hexValue = Uint.U256.fromHex("0xff");
		expect(Uint.U256.toBigInt(hexValue)).toBe(255n);
	});

	it("should import Hex utilities", () => {
		const hex = Hex.fromString("0x1234");
		expect(hex).toBeDefined();
		expect(hex).toBe("0x1234");

		const hex2 = Hex.fromString("1234");
		expect(hex2).toBe("0x1234");
	});

	it("should import Hardfork with basic methods", () => {
		expect(Hardfork).toBeDefined();
		const fork = Hardfork.fromString("Cancun");
		expect(fork).toBe("Cancun");

		// Test hardfork comparison
		const isCancun = Hardfork.isAtLeast("Cancun", "Berlin");
		expect(isCancun).toBe(true);

		const isBerlin = Hardfork.isAtLeast("Berlin", "Cancun");
		expect(isBerlin).toBe(false);
	});

	it("should import GasConstants", () => {
		expect(GasConstants).toBeDefined();
		expect(GasConstants.G_ZERO).toBe(0n);
		expect(GasConstants.G_SLOAD).toBe(2100n);
		expect(GasConstants.G_SSET).toBe(20000n);
	});

	it("should import Opcode constants", () => {
		expect(Opcode).toBeDefined();
		expect(Opcode.STOP).toBe(0x00);
		expect(Opcode.ADD).toBe(0x01);
		expect(Opcode.MUL).toBe(0x02);
	});

	it("should handle bigint values for U256", () => {
		const maxU256 = (1n << 256n) - 1n;
		const value = Uint.U256.fromBigInt(maxU256);
		expect(Uint.U256.toBigInt(value)).toBe(maxU256);
	});

	it("should work with zero address", () => {
		const zero = Address.fromHex("0x0000000000000000000000000000000000000000");
		expect(Address.isZero(zero)).toBe(true);

		const nonZero = Address.fromHex(
			"0xa0cf798816d4b9b9866b5330eea46a18382f251e",
		);
		expect(Address.isZero(nonZero)).toBe(false);
	});
});
