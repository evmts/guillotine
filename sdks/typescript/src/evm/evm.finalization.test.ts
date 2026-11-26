import { describe, expect, it } from 'bun:test'
import { Address } from '../primitives/address.js'
import { U256 } from '../primitives/u256.js'
import { GuillotineEvm, nativeHandleStats } from './evm.js'

// Handle ids are unique per process, so these tests stay correct while EVMs leaked by
// other test files are finalized concurrently.

const COUNT = 20

function liveIds(): Set<number> {
	return new Set(nativeHandleStats().live)
}

/** Create EVMs in a separate frame, drop every reference, and return their handle ids. */
async function leak(tracing: boolean): Promise<number[]> {
	const before = liveIds()
	for (let i = 0; i < COUNT; i++) {
		const evm = await GuillotineEvm.create({}, { tracing })
		await evm.setBalance(Address.fromHex('0x00000000000000000000000000000000000000a1'), U256.fromBigInt(BigInt(i)))
	}
	return [...liveIds()].filter((id) => !before.has(id))
}

async function collect(rounds: number, done: () => boolean = () => false): Promise<void> {
	for (let i = 0; i < rounds && !done(); i++) {
		Bun.gc(true)
		await Bun.sleep(1)
	}
}

function stillLive(ids: number[]): number[] {
	const live = nativeHandleStats().live
	return ids.filter((id) => live.has(id))
}

describe('FinalizationRegistry safety net', () => {
	for (const tracing of [false, true]) {
		it(`destroys native handles of ${tracing ? 'tracing' : 'mainnet'} EVMs collected without dispose()`, async () => {
			const ids = await leak(tracing)
			expect(ids).toHaveLength(COUNT)
			await collect(300, () => stillLive(ids).length === 0)
			expect(stillLive(ids)).toEqual([])
			expect(nativeHandleStats().spuriousFinalizations).toBe(0)
		})
	}

	it('unregisters on explicit dispose so a collection never finalizes a released handle', async () => {
		const before = liveIds()
		const ids: number[] = []
		for (let i = 0; i < COUNT; i++) {
			const evm = await GuillotineEvm.create({}, { tracing: i % 3 === 0 })
			ids.push(...[...liveIds()].filter((id) => !before.has(id) && !ids.includes(id)))
			if (i % 2 === 0) evm.close()
			else evm.dispose()
			expect(evm.isOpen).toBe(false)
			evm[Symbol.dispose]()
		}
		expect(ids).toHaveLength(COUNT)
		expect(stillLive(ids)).toEqual([])
		await collect(30)
		// The finalizer counts every callback that finds its handle already released.
		expect(nativeHandleStats().spuriousFinalizations).toBe(0)
	})

	it('keeps a reachable EVM usable across collections', async () => {
		using evm = await GuillotineEvm.create()
		const addr = Address.fromHex('0x00000000000000000000000000000000000000b2')
		await evm.setBalance(addr, U256.fromBigInt(7n))
		await collect(10)
		expect(evm.isOpen).toBe(true)
		expect((await evm.getBalance(addr)).toBigInt()).toBe(7n)
	})
})
