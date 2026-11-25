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
/** Assert CHAINID returns exactly `chainId` through the native u64 TransactionContext.chain_id. */
async function expectChainIdOpcode(chainId: bigint | number): Promise<void> {
	using evm = await GuillotineEvm.create({ chainId })
	expect(evm.isOpen).toBe(true)
	await evm.setCode(contract, Bytes.fromBytes(CHAINID_RETURNER))
	const result = await evm.call({ caller, to: contract, value: U256.zero(), input: Bytes.empty(), gas: 100_000n })
	expect(result.success).toBe(true)
	expect(U256.fromBytes(result.output.toBytes()).toBigInt()).toBe(BigInt(chainId))
}

describe('chainId validation', () => {
	it('accepts u64 chain ids above the old u16 cap as bigint and number', async () => {
		for (const chainId of [65_536n, 84_532n, 11_155_111n, U64_MAX, 84_532, 11_155_111, Number.MAX_SAFE_INTEGER]) {
			await expectChainIdOpcode(chainId)
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

	it('returns Base Sepolia 84532 (bigint and number)', async () => {
		await expectChainIdOpcode(84_532n)
		await expectChainIdOpcode(84_532)
	})

	it('returns Sepolia 11155111 (bigint and number)', async () => {
		await expectChainIdOpcode(11_155_111n)
		await expectChainIdOpcode(11_155_111)
	})

	it('returns the u64 maximum', async () => {
		await expectChainIdOpcode(U64_MAX)
	})
})
