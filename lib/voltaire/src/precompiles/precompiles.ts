/**
 * EVM Precompile implementations
 */

import type { Hardfork } from "../primitives/hardfork";

export enum PrecompileAddress {
	ECRECOVER = "0x0000000000000000000000000000000000000001",
	SHA256 = "0x0000000000000000000000000000000000000002",
	RIPEMD160 = "0x0000000000000000000000000000000000000003",
	IDENTITY = "0x0000000000000000000000000000000000000004",
	MODEXP = "0x0000000000000000000000000000000000000005",
	BN254_ADD = "0x0000000000000000000000000000000000000006",
	BN254_MUL = "0x0000000000000000000000000000000000000007",
	BN254_PAIRING = "0x0000000000000000000000000000000000000008",
	BLAKE2F = "0x0000000000000000000000000000000000000009",
	POINT_EVALUATION = "0x000000000000000000000000000000000000000a",
	BLS12_G1_ADD = "0x000000000000000000000000000000000000000b",
	BLS12_G1_MUL = "0x000000000000000000000000000000000000000c",
	BLS12_G1_MSM = "0x000000000000000000000000000000000000000d",
	BLS12_G2_ADD = "0x000000000000000000000000000000000000000e",
	BLS12_G2_MUL = "0x000000000000000000000000000000000000000f",
	BLS12_G2_MSM = "0x0000000000000000000000000000000000000010",
	BLS12_PAIRING = "0x0000000000000000000000000000000000000011",
	BLS12_MAP_FP_TO_G1 = "0x0000000000000000000000000000000000000012",
	BLS12_MAP_FP2_TO_G2 = "0x0000000000000000000000000000000000000013",
}

export interface PrecompileResult {
	success: boolean;
	output: Uint8Array;
	gasUsed: bigint;
	error?: string;
}

import { isAtLeast } from "../primitives/hardfork";

/**
 * Check if an address is a precompile for a given hardfork
 */
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: precompile checks require branching per hardfork
export function isPrecompile(address: string, hardfork: Hardfork): boolean {
	const normalized = address.toLowerCase();

	// Available in all hardforks
	if (normalized === PrecompileAddress.ECRECOVER.toLowerCase()) return true;
	if (normalized === PrecompileAddress.SHA256.toLowerCase()) return true;
	if (normalized === PrecompileAddress.RIPEMD160.toLowerCase()) return true;
	if (normalized === PrecompileAddress.IDENTITY.toLowerCase()) return true;

	// Available from Byzantium
	if (normalized === PrecompileAddress.MODEXP.toLowerCase()) {
		return isAtLeast(hardfork, Hardfork.BYZANTIUM);
	}
	if (normalized === PrecompileAddress.BN254_ADD.toLowerCase()) {
		return isAtLeast(hardfork, Hardfork.BYZANTIUM);
	}
	if (normalized === PrecompileAddress.BN254_MUL.toLowerCase()) {
		return isAtLeast(hardfork, Hardfork.BYZANTIUM);
	}
	if (normalized === PrecompileAddress.BN254_PAIRING.toLowerCase()) {
		return isAtLeast(hardfork, Hardfork.BYZANTIUM);
	}

	// Available from Istanbul
	if (normalized === PrecompileAddress.BLAKE2F.toLowerCase()) {
		return isAtLeast(hardfork, Hardfork.ISTANBUL);
	}

	// Available from Cancun
	if (normalized === PrecompileAddress.POINT_EVALUATION.toLowerCase()) {
		return isAtLeast(hardfork, Hardfork.CANCUN);
	}

	// BLS precompiles from Prague
	if (normalized === PrecompileAddress.BLS12_G1_ADD.toLowerCase()) {
		return isAtLeast(hardfork, Hardfork.PRAGUE);
	}
	if (normalized === PrecompileAddress.BLS12_G1_MUL.toLowerCase()) {
		return isAtLeast(hardfork, Hardfork.PRAGUE);
	}
	if (normalized === PrecompileAddress.BLS12_G1_MSM.toLowerCase()) {
		return isAtLeast(hardfork, Hardfork.PRAGUE);
	}
	if (normalized === PrecompileAddress.BLS12_G2_ADD.toLowerCase()) {
		return isAtLeast(hardfork, Hardfork.PRAGUE);
	}
	if (normalized === PrecompileAddress.BLS12_G2_MUL.toLowerCase()) {
		return isAtLeast(hardfork, Hardfork.PRAGUE);
	}
	if (normalized === PrecompileAddress.BLS12_G2_MSM.toLowerCase()) {
		return isAtLeast(hardfork, Hardfork.PRAGUE);
	}
	if (normalized === PrecompileAddress.BLS12_PAIRING.toLowerCase()) {
		return isAtLeast(hardfork, Hardfork.PRAGUE);
	}
	if (normalized === PrecompileAddress.BLS12_MAP_FP_TO_G1.toLowerCase()) {
		return isAtLeast(hardfork, Hardfork.PRAGUE);
	}
	if (normalized === PrecompileAddress.BLS12_MAP_FP2_TO_G2.toLowerCase()) {
		return isAtLeast(hardfork, Hardfork.PRAGUE);
	}

	return false;
}

/**
 * Execute a precompile
 * @param address - Precompile address
 * @param input - Input data
 * @param gasLimit - Gas limit for execution
 * @param hardfork - Current hardfork
 * @returns Precompile execution result
 */
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: precompile execution requires branching per type
export function execute(
	address: string,
	input: Uint8Array,
	gasLimit: bigint,
	hardfork: Hardfork,
): PrecompileResult {
	const normalized = address.toLowerCase();

	if (normalized === PrecompileAddress.ECRECOVER.toLowerCase()) {
		return ecrecover(input, gasLimit);
	}
	if (normalized === PrecompileAddress.SHA256.toLowerCase()) {
		return sha256(input, gasLimit);
	}
	if (normalized === PrecompileAddress.RIPEMD160.toLowerCase()) {
		return ripemd160(input, gasLimit);
	}
	if (normalized === PrecompileAddress.IDENTITY.toLowerCase()) {
		return identity(input, gasLimit);
	}
	if (normalized === PrecompileAddress.MODEXP.toLowerCase()) {
		return modexp(input, gasLimit);
	}
	if (normalized === PrecompileAddress.BN254_ADD.toLowerCase()) {
		return bn254Add(input, gasLimit);
	}
	if (normalized === PrecompileAddress.BN254_MUL.toLowerCase()) {
		return bn254Mul(input, gasLimit);
	}
	if (normalized === PrecompileAddress.BN254_PAIRING.toLowerCase()) {
		return bn254Pairing(input, gasLimit);
	}
	if (normalized === PrecompileAddress.BLAKE2F.toLowerCase()) {
		return blake2f(input, gasLimit);
	}
	if (normalized === PrecompileAddress.POINT_EVALUATION.toLowerCase()) {
		return pointEvaluation(input, gasLimit);
	}

	// BLS precompiles
	if (normalized === PrecompileAddress.BLS12_G1_ADD.toLowerCase()) {
		return bls12G1Add(input, gasLimit);
	}
	if (normalized === PrecompileAddress.BLS12_G1_MUL.toLowerCase()) {
		return bls12G1Mul(input, gasLimit);
	}
	if (normalized === PrecompileAddress.BLS12_G1_MSM.toLowerCase()) {
		return bls12G1Msm(input, gasLimit);
	}
	if (normalized === PrecompileAddress.BLS12_G2_ADD.toLowerCase()) {
		return bls12G2Add(input, gasLimit);
	}
	if (normalized === PrecompileAddress.BLS12_G2_MUL.toLowerCase()) {
		return bls12G2Mul(input, gasLimit);
	}
	if (normalized === PrecompileAddress.BLS12_G2_MSM.toLowerCase()) {
		return bls12G2Msm(input, gasLimit);
	}
	if (normalized === PrecompileAddress.BLS12_PAIRING.toLowerCase()) {
		return bls12Pairing(input, gasLimit);
	}
	if (normalized === PrecompileAddress.BLS12_MAP_FP_TO_G1.toLowerCase()) {
		return bls12MapFpToG1(input, gasLimit);
	}
	if (normalized === PrecompileAddress.BLS12_MAP_FP2_TO_G2.toLowerCase()) {
		return bls12MapFp2ToG2(input, gasLimit);
	}

	return {
		success: false,
		output: new Uint8Array(0),
		gasUsed: 0n,
		error: `Unknown precompile: ${address}`,
	};
}

/**
 * ECRECOVER precompile (0x01)
 * Recover signer address from signature
 */
export function ecrecover(
	input: Uint8Array,
	gasLimit: bigint,
): PrecompileResult {
	const gas = 3000n;
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	// Simplified - would need actual ECDSA recovery
	return { success: true, output: new Uint8Array(32), gasUsed: gas };
}

/**
 * SHA256 precompile (0x02)
 */
export function sha256(input: Uint8Array, gasLimit: bigint): PrecompileResult {
	const gas = 60n + BigInt(Math.ceil(input.length / 32)) * 12n;
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	// Would use actual SHA256
	return { success: true, output: new Uint8Array(32), gasUsed: gas };
}

/**
 * RIPEMD160 precompile (0x03)
 */
export function ripemd160(
	input: Uint8Array,
	gasLimit: bigint,
): PrecompileResult {
	const gas = 600n + BigInt(Math.ceil(input.length / 32)) * 120n;
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	// Would use actual RIPEMD160
	return { success: true, output: new Uint8Array(32), gasUsed: gas };
}

/**
 * IDENTITY precompile (0x04)
 * Returns input data unchanged
 */
export function identity(
	input: Uint8Array,
	gasLimit: bigint,
): PrecompileResult {
	const gas = 15n + BigInt(Math.ceil(input.length / 32)) * 3n;
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	return { success: true, output: new Uint8Array(input), gasUsed: gas };
}

/**
 * MODEXP precompile (0x05)
 * Modular exponentiation
 */
export function modexp(input: Uint8Array, gasLimit: bigint): PrecompileResult {
	// Simplified gas calculation
	const gas = 200n;
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	// Would perform actual modexp
	return { success: true, output: new Uint8Array(32), gasUsed: gas };
}

/**
 * BN254_ADD precompile (0x06)
 * BN254 elliptic curve addition
 */
export function bn254Add(
	input: Uint8Array,
	gasLimit: bigint,
): PrecompileResult {
	const gas = 150n;
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	return { success: true, output: new Uint8Array(64), gasUsed: gas };
}

/**
 * BN254_MUL precompile (0x07)
 * BN254 elliptic curve multiplication
 */
export function bn254Mul(
	input: Uint8Array,
	gasLimit: bigint,
): PrecompileResult {
	const gas = 6000n;
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	return { success: true, output: new Uint8Array(64), gasUsed: gas };
}

/**
 * BN254_PAIRING precompile (0x08)
 * BN254 pairing check
 */
export function bn254Pairing(
	input: Uint8Array,
	gasLimit: bigint,
): PrecompileResult {
	const k = input.length / 192;
	const gas = 45000n + BigInt(k) * 34000n;
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	return { success: true, output: new Uint8Array(32), gasUsed: gas };
}

/**
 * BLAKE2F precompile (0x09)
 * Blake2 compression function
 */
export function blake2f(input: Uint8Array, gasLimit: bigint): PrecompileResult {
	if (input.length !== 213) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: 0n,
			error: "Invalid input length",
		};
	}
	const rounds = new DataView(input.buffer).getUint32(0, false);
	const gas = BigInt(rounds);
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	return { success: true, output: new Uint8Array(64), gasUsed: gas };
}

/**
 * POINT_EVALUATION precompile (0x0a)
 * KZG point evaluation (EIP-4844)
 */
export function pointEvaluation(
	input: Uint8Array,
	gasLimit: bigint,
): PrecompileResult {
	const gas = 50000n;
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	return { success: true, output: new Uint8Array(64), gasUsed: gas };
}

/**
 * BLS12_G1_ADD precompile (0x0b)
 */
export function bls12G1Add(
	input: Uint8Array,
	gasLimit: bigint,
): PrecompileResult {
	const gas = 500n;
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	return { success: true, output: new Uint8Array(128), gasUsed: gas };
}

/**
 * BLS12_G1_MUL precompile (0x0c)
 */
export function bls12G1Mul(
	input: Uint8Array,
	gasLimit: bigint,
): PrecompileResult {
	const gas = 12000n;
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	return { success: true, output: new Uint8Array(128), gasUsed: gas };
}

/**
 * BLS12_G1_MSM precompile (0x0d)
 */
export function bls12G1Msm(
	input: Uint8Array,
	gasLimit: bigint,
): PrecompileResult {
	const k = input.length / 160;
	const gas = 12000n * BigInt(k);
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	return { success: true, output: new Uint8Array(128), gasUsed: gas };
}

/**
 * BLS12_G2_ADD precompile (0x0e)
 */
export function bls12G2Add(
	input: Uint8Array,
	gasLimit: bigint,
): PrecompileResult {
	const gas = 800n;
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	return { success: true, output: new Uint8Array(256), gasUsed: gas };
}

/**
 * BLS12_G2_MUL precompile (0x0f)
 */
export function bls12G2Mul(
	input: Uint8Array,
	gasLimit: bigint,
): PrecompileResult {
	const gas = 45000n;
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	return { success: true, output: new Uint8Array(256), gasUsed: gas };
}

/**
 * BLS12_G2_MSM precompile (0x10)
 */
export function bls12G2Msm(
	input: Uint8Array,
	gasLimit: bigint,
): PrecompileResult {
	const k = input.length / 288;
	const gas = 45000n * BigInt(k);
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	return { success: true, output: new Uint8Array(256), gasUsed: gas };
}

/**
 * BLS12_PAIRING precompile (0x11)
 */
export function bls12Pairing(
	input: Uint8Array,
	gasLimit: bigint,
): PrecompileResult {
	const k = input.length / 384;
	const gas = 115000n + BigInt(k) * 23000n;
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	return { success: true, output: new Uint8Array(32), gasUsed: gas };
}

/**
 * BLS12_MAP_FP_TO_G1 precompile (0x12)
 */
export function bls12MapFpToG1(
	input: Uint8Array,
	gasLimit: bigint,
): PrecompileResult {
	const gas = 5500n;
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	return { success: true, output: new Uint8Array(128), gasUsed: gas };
}

/**
 * BLS12_MAP_FP2_TO_G2 precompile (0x13)
 */
export function bls12MapFp2ToG2(
	input: Uint8Array,
	gasLimit: bigint,
): PrecompileResult {
	const gas = 75000n;
	if (gasLimit < gas) {
		return {
			success: false,
			output: new Uint8Array(0),
			gasUsed: gas,
			error: "Out of gas",
		};
	}
	return { success: true, output: new Uint8Array(256), gasUsed: gas };
}
