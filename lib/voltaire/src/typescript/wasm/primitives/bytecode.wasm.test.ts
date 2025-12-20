/**
 * WASM Bytecode parity tests
 * Validates WASM implementation produces identical results to native FFI
 */

import { test, expect, describe } from "bun:test";
import {
	analyzeJumpDestinations as nativeAnalyzeJumpDestinations,
	isBytecodeBoundary as nativeIsBytecodeBoundary,
	isValidJumpDest as nativeIsValidJumpDest,
	validateBytecode as nativeValidateBytecode,
} from "../../native/primitives/bytecode.native";
import {
	analyzeJumpDestinations as wasmAnalyzeJumpDestinations,
	isBytecodeBoundary as wasmIsBytecodeBoundary,
	isValidJumpDest as wasmIsValidJumpDest,
	validateBytecode as wasmValidateBytecode,
} from "./bytecode.wasm";

describe("WASM Bytecode parity", () => {
	test("analyzeJumpDestinations produces identical results for simple bytecode", () => {
		// Simple bytecode with JUMPDEST (0x5b) at position 1
		const simpleBytecode = new Uint8Array([0x00, 0x5b, 0x00]);

		const nativeResults = nativeAnalyzeJumpDestinations(simpleBytecode);
		const wasmResults = wasmAnalyzeJumpDestinations(simpleBytecode);

		expect(nativeResults.length).toBe(wasmResults.length);

		for (let i = 0; i < nativeResults.length; i++) {
			expect(nativeResults[i].position).toBe(wasmResults[i].position);
			expect(nativeResults[i].valid).toBe(wasmResults[i].valid);
		}
	});

	test("analyzeJumpDestinations detects multiple JUMPDESTs", () => {
		// Bytecode with JUMPDEST at positions 0, 2, 4
		const bytecode = new Uint8Array([0x5b, 0x00, 0x5b, 0x00, 0x5b]);

		const nativeResults = nativeAnalyzeJumpDestinations(bytecode);
		const wasmResults = wasmAnalyzeJumpDestinations(bytecode);

		expect(nativeResults.length).toBe(wasmResults.length);
		expect(nativeResults.length).toBe(3);

		// Verify positions match
		const nativePositions = nativeResults.map((r) => r.position).sort((a, b) => a - b);
		const wasmPositions = wasmResults.map((r) => r.position).sort((a, b) => a - b);

		expect(nativePositions).toEqual(wasmPositions);
		expect(nativePositions).toEqual([0, 2, 4]);
	});

	test("analyzeJumpDestinations ignores JUMPDEST inside PUSH data", () => {
		// PUSH1 0x5b (JUMPDEST opcode as data, should be ignored)
		// 0x60 = PUSH1, 0x5b = data (looks like JUMPDEST but is not)
		const bytecode = new Uint8Array([0x60, 0x5b, 0x00, 0x5b]);

		const nativeResults = nativeAnalyzeJumpDestinations(bytecode);
		const wasmResults = wasmAnalyzeJumpDestinations(bytecode);

		expect(nativeResults.length).toBe(wasmResults.length);

		// Only position 3 should be detected (position 1 is inside PUSH1 data)
		const nativePositions = nativeResults.map((r) => r.position);
		const wasmPositions = wasmResults.map((r) => r.position);

		expect(nativePositions).toEqual(wasmPositions);
		expect(nativePositions).toEqual([3]);
	});

	test("analyzeJumpDestinations handles PUSH32", () => {
		// PUSH32 followed by 32 bytes of data, then JUMPDEST
		const pushData = new Uint8Array(32).fill(0x5b); // Fill with JUMPDEST bytes
		const bytecode = new Uint8Array([0x7f, ...pushData, 0x5b]);

		const nativeResults = nativeAnalyzeJumpDestinations(bytecode);
		const wasmResults = wasmAnalyzeJumpDestinations(bytecode);

		expect(nativeResults.length).toBe(wasmResults.length);

		// Only the last position (after PUSH32 data) should be detected
		const nativePositions = nativeResults.map((r) => r.position);
		const wasmPositions = wasmResults.map((r) => r.position);

		expect(nativePositions).toEqual(wasmPositions);
		expect(nativePositions).toEqual([33]);
	});

	test("analyzeJumpDestinations handles empty bytecode", () => {
		const emptyBytecode = new Uint8Array(0);

		const nativeResults = nativeAnalyzeJumpDestinations(emptyBytecode);
		const wasmResults = wasmAnalyzeJumpDestinations(emptyBytecode);

		expect(nativeResults.length).toBe(0);
		expect(wasmResults.length).toBe(0);
	});

	test("analyzeJumpDestinations handles large bytecode", () => {
		// Create bytecode with many JUMPDESTs
		const size = 10000;
		const bytecode = new Uint8Array(size);

		// Place JUMPDEST every 100 bytes
		for (let i = 0; i < size; i += 100) {
			bytecode[i] = 0x5b;
		}

		const nativeResults = nativeAnalyzeJumpDestinations(bytecode);
		const wasmResults = wasmAnalyzeJumpDestinations(bytecode);

		expect(nativeResults.length).toBe(wasmResults.length);

		const nativePositions = nativeResults.map((r) => r.position).sort((a, b) => a - b);
		const wasmPositions = wasmResults.map((r) => r.position).sort((a, b) => a - b);

		expect(nativePositions).toEqual(wasmPositions);
	});

	test("isBytecodeBoundary matches native for valid boundaries", () => {
		// Simple bytecode: STOP, JUMPDEST, STOP
		const bytecode = new Uint8Array([0x00, 0x5b, 0x00]);

		for (let pos = 0; pos < bytecode.length; pos++) {
			const nativeBoundary = nativeIsBytecodeBoundary(bytecode, pos);
			const wasmBoundary = wasmIsBytecodeBoundary(bytecode, pos);

			expect(nativeBoundary).toBe(wasmBoundary);
			// All positions should be boundaries in this simple case
			expect(nativeBoundary).toBe(true);
		}
	});

	test("isBytecodeBoundary detects non-boundaries in PUSH data", () => {
		// PUSH2 with 2 bytes of data
		// Position 0: PUSH2 (boundary)
		// Position 1-2: data (not boundaries)
		// Position 3: STOP (boundary)
		const bytecode = new Uint8Array([0x61, 0xaa, 0xbb, 0x00]);

		expect(nativeIsBytecodeBoundary(bytecode, 0)).toBe(true);
		expect(wasmIsBytecodeBoundary(bytecode, 0)).toBe(true);

		expect(nativeIsBytecodeBoundary(bytecode, 1)).toBe(
			wasmIsBytecodeBoundary(bytecode, 1),
		);
		expect(nativeIsBytecodeBoundary(bytecode, 1)).toBe(false);

		expect(nativeIsBytecodeBoundary(bytecode, 2)).toBe(
			wasmIsBytecodeBoundary(bytecode, 2),
		);
		expect(nativeIsBytecodeBoundary(bytecode, 2)).toBe(false);

		expect(nativeIsBytecodeBoundary(bytecode, 3)).toBe(true);
		expect(wasmIsBytecodeBoundary(bytecode, 3)).toBe(true);
	});

	test("isBytecodeBoundary handles out of bounds positions", () => {
		const bytecode = new Uint8Array([0x00, 0x5b, 0x00]);

		// Position beyond bytecode length
		const nativeBoundary = nativeIsBytecodeBoundary(bytecode, 100);
		const wasmBoundary = wasmIsBytecodeBoundary(bytecode, 100);

		expect(nativeBoundary).toBe(wasmBoundary);
		expect(nativeBoundary).toBe(false);
	});

	test("isValidJumpDest matches native for valid JUMPDEST", () => {
		// JUMPDEST at position 1
		const bytecode = new Uint8Array([0x00, 0x5b, 0x00]);

		const nativeValid = nativeIsValidJumpDest(bytecode, 1);
		const wasmValid = wasmIsValidJumpDest(bytecode, 1);

		expect(nativeValid).toBe(wasmValid);
		expect(nativeValid).toBe(true);
	});

	test("isValidJumpDest rejects non-JUMPDEST opcodes", () => {
		// STOP at position 0 (not JUMPDEST)
		const bytecode = new Uint8Array([0x00, 0x5b, 0x00]);

		const nativeValid = nativeIsValidJumpDest(bytecode, 0);
		const wasmValid = wasmIsValidJumpDest(bytecode, 0);

		expect(nativeValid).toBe(wasmValid);
		expect(nativeValid).toBe(false);
	});

	test("isValidJumpDest rejects JUMPDEST inside PUSH data", () => {
		// PUSH1 0x5b (JUMPDEST as data)
		const bytecode = new Uint8Array([0x60, 0x5b]);

		const nativeValid = nativeIsValidJumpDest(bytecode, 1);
		const wasmValid = wasmIsValidJumpDest(bytecode, 1);

		expect(nativeValid).toBe(wasmValid);
		expect(nativeValid).toBe(false);
	});

	test("isValidJumpDest handles multiple valid JUMPDESTs", () => {
		// Multiple JUMPDESTs at different positions
		const bytecode = new Uint8Array([0x5b, 0x00, 0x5b, 0x60, 0xaa, 0x5b]);

		// Position 0: valid JUMPDEST
		expect(nativeIsValidJumpDest(bytecode, 0)).toBe(true);
		expect(wasmIsValidJumpDest(bytecode, 0)).toBe(true);

		// Position 2: valid JUMPDEST
		expect(nativeIsValidJumpDest(bytecode, 2)).toBe(true);
		expect(wasmIsValidJumpDest(bytecode, 2)).toBe(true);

		// Position 5: valid JUMPDEST
		expect(nativeIsValidJumpDest(bytecode, 5)).toBe(true);
		expect(wasmIsValidJumpDest(bytecode, 5)).toBe(true);

		// Position 4: inside PUSH1 data (not valid)
		expect(nativeIsValidJumpDest(bytecode, 4)).toBe(
			wasmIsValidJumpDest(bytecode, 4),
		);
		expect(nativeIsValidJumpDest(bytecode, 4)).toBe(false);
	});

	test("validateBytecode accepts valid bytecode", () => {
		const validBytecodes = [
			new Uint8Array([0x00]), // STOP
			new Uint8Array([0x5b, 0x00]), // JUMPDEST, STOP
			new Uint8Array([0x60, 0xaa, 0x00]), // PUSH1 0xaa, STOP
			new Uint8Array([0x61, 0xaa, 0xbb, 0x00]), // PUSH2 0xaabb, STOP
		];

		for (const bytecode of validBytecodes) {
			expect(() => nativeValidateBytecode(bytecode)).not.toThrow();
			expect(() => wasmValidateBytecode(bytecode)).not.toThrow();
		}
	});

	test("validateBytecode rejects incomplete PUSH", () => {
		// PUSH1 without data byte
		const incompletePush = new Uint8Array([0x60]);

		let nativeError: Error | null = null;
		let wasmError: Error | null = null;

		try {
			nativeValidateBytecode(incompletePush);
		} catch (e) {
			nativeError = e as Error;
		}

		try {
			wasmValidateBytecode(incompletePush);
		} catch (e) {
			wasmError = e as Error;
		}

		// Both should throw
		expect(nativeError).not.toBeNull();
		expect(wasmError).not.toBeNull();
	});

	test("validateBytecode rejects incomplete PUSH32", () => {
		// PUSH32 with only 30 bytes of data (needs 32)
		const incompletePush32 = new Uint8Array([0x7f, ...new Uint8Array(30)]);

		let nativeError: Error | null = null;
		let wasmError: Error | null = null;

		try {
			nativeValidateBytecode(incompletePush32);
		} catch (e) {
			nativeError = e as Error;
		}

		try {
			wasmValidateBytecode(incompletePush32);
		} catch (e) {
			wasmError = e as Error;
		}

		// Both should throw
		expect(nativeError).not.toBeNull();
		expect(wasmError).not.toBeNull();
	});

	test("validateBytecode handles empty bytecode", () => {
		const emptyBytecode = new Uint8Array(0);

		expect(() => nativeValidateBytecode(emptyBytecode)).not.toThrow();
		expect(() => wasmValidateBytecode(emptyBytecode)).not.toThrow();
	});

	test("real-world contract bytecode parity", () => {
		// Simplified ERC20 constructor bytecode pattern
		const realWorldBytecode = new Uint8Array([
			0x60, 0x80, 0x60, 0x40, 0x52, 0x34, 0x80, 0x15, 0x61, 0x00, 0x10, 0x57,
			0x60, 0x00, 0x80, 0xfd, 0x5b, 0x50, 0x60, 0x40, 0x51, 0x80, 0x82, 0x03,
			0x90, 0x91, 0xf3,
		]);

		// Both should analyze without errors
		expect(() => nativeValidateBytecode(realWorldBytecode)).not.toThrow();
		expect(() => wasmValidateBytecode(realWorldBytecode)).not.toThrow();

		// Analyze jump destinations
		const nativeJumps = nativeAnalyzeJumpDestinations(realWorldBytecode);
		const wasmJumps = wasmAnalyzeJumpDestinations(realWorldBytecode);

		expect(nativeJumps.length).toBe(wasmJumps.length);

		const nativePositions = nativeJumps.map((j) => j.position).sort((a, b) => a - b);
		const wasmPositions = wasmJumps.map((j) => j.position).sort((a, b) => a - b);

		expect(nativePositions).toEqual(wasmPositions);
	});
});
