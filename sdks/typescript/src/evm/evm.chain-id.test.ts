import { describe, expect, it } from 'bun:test'
import { Address } from '../primitives/address.js'
import { Bytes } from '../primitives/bytes.js'
import { U256 } from '../primitives/u256.js'
import { GuillotineEvm } from './evm.js'

// CHAINID PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
const CHAINID_RETURNER = new Uint8Array([0x46, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3])
const contract = Address.fromHex('0x00000000000000000000000000000000000c4a1d')
const caller = Address.fromHex('0x00000000000000000000000000000000000000a1')
const U64_MAX = (1n << 64n) - 1n
/** Native message when CHAINID is still u16 (before TransactionContext.chain_id is widened to u64). */
const NARROW_NATIVE = /^Failed to create EVM: chain_id (\d+) exceeds the supported maximum 65535$/

/**
 * Create an EVM, or return null when the native library has a u16 CHAINID and
 * rejects `chainId` explicitly instead of truncating it. Any other failure, or
 * a rejection of an id that fits in u16, fails the test. With a u64 native
 * CHAINID the rejection branch is unreachable, so every caller then asserts a
 * full round-trip.
 */
async function createOrNarrowNative(chainId: bigint | number): Promise<GuillotineEvm | null> {
	try {
		return await GuillotineEvm.create({ chainId })
	} catch (error) {
		expect(error).toMatchObject({ type: 'VMCreationFailed' })
		const match = NARROW_NATIVE.exec((error as Error).message)
		expect(match).not.toBeNull()
		expect(BigInt(match?.[1] ?? -1)).toBe(BigInt(chainId))
		expect(BigInt(chainId) > 65_535n).toBe(true)
		return null
	}
}

/** Assert CHAINID returns `chainId`, unless the native build rejects it as above. */
async function expectChainIdOpcode(chainId: bigint | number): Promise<void> {
	const created = await createOrNarrowNative(chainId)
	if (created === null) return
	using evm = created
	await evm.setCode(contract, Bytes.fromBytes(CHAINID_RETURNER))
	const result = await evm.call({ caller, to: contract, value: U256.zero(), input: Bytes.empty(), gas: 100_000n })
	expect(result.success).toBe(true)
	expect(U256.fromBytes(result.output.toBytes()).toBigInt()).toBe(BigInt(chainId))
}

describe('chainId validation', () => {
	it('accepts u64 chain ids above the old u16 cap as bigint and number', async () => {
		for (const chainId of [65_536n, 84_532n, 11_155_111n, U64_MAX, 84_532, 11_155_111, Number.MAX_SAFE_INTEGER]) {
			const evm = await createOrNarrowNative(chainId)
			if (evm === null) continue
			expect(evm.isOpen).toBe(true)
			evm.close()
		}
	})

	it('rejects chain ids outside u64 before native code', async () => {
		for (const chainId of [-1n, U64_MAX + 1n, 1n << 80n]) {
			await expect(GuillotineEvm.create({ chainId })).rejects.toMatchObject({ type: 'InvalidValue' })
		}
	})

	it('rejects numbers that are negative, fractional, non-finite or unsafe', async () => {
		for (const chainId of [-1, 1.5, Number.NaN, Number.POSITIVE_INFINITY, Number.MAX_SAFE_INTEGER + 1, 2 ** 64]) {
			await expect(GuillotineEvm.create({ chainId })).rejects.toMatchObject({ type: 'InvalidValue' })
		}
	})
})

describe('CHAINID round-trip through the native EVM', () => {
	it('returns Ethereum mainnet 1', async () => {
		await expectChainIdOpcode(1n)
	})

	it('returns Base Mainnet 8453 (bigint and number)', async () => {
		await expectChainIdOpcode(8453n)
		await expectChainIdOpcode(8453)
	})

	it('returns Base Sepolia 84532', async () => {
		await expectChainIdOpcode(84_532n)
	})

	it('returns Sepolia 11155111', async () => {
		await expectChainIdOpcode(11_155_111)
	})
})
