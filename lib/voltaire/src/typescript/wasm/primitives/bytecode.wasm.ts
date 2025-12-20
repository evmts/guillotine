/**
 * WASM implementation of EVM bytecode operations
 * Uses WebAssembly bindings to Zig implementation
 */

import * as loader from "../../../../wasm/loader.js";

/**
 * Jump destination found in bytecode
 */
export interface JumpDestination {
	/** Position in bytecode */
	position: number;
	/** Whether this is a valid JUMPDEST opcode */
	valid: boolean;
}

/**
 * Analyze bytecode to find all valid JUMPDEST locations
 * @param code - EVM bytecode
 * @returns Array of JUMPDEST positions
 */
export function analyzeJumpDestinations(code: Uint8Array): JumpDestination[] {
	const input = new Uint8Array(code);
	const positions = loader.bytecodeAnalyzeJumpdests(input);

	return positions.map((position) => ({
		position,
		valid: true,
	}));
}

/**
 * Check if a position is at a bytecode boundary (not inside PUSH data)
 * @param code - EVM bytecode
 * @param position - Position to check
 * @returns true if position is a valid instruction boundary
 */
export function isBytecodeBoundary(code: Uint8Array, position: number): boolean {
	const input = new Uint8Array(code);
	return loader.bytecodeIsBoundary(input, position);
}

/**
 * Check if a position is a valid JUMPDEST
 * @param code - EVM bytecode
 * @param position - Position to check
 * @returns true if position contains a valid JUMPDEST opcode
 */
export function isValidJumpDest(code: Uint8Array, position: number): boolean {
	const input = new Uint8Array(code);
	return loader.bytecodeIsValidJumpdest(input, position);
}

/**
 * Validate bytecode for basic correctness
 * Checks that PUSH instructions have enough data bytes
 * @param code - EVM bytecode
 * @throws Error if bytecode is invalid
 */
export function validateBytecode(code: Uint8Array): void {
	const input = new Uint8Array(code);
	loader.bytecodeValidate(input);
}
