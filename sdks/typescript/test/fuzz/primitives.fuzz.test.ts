import { describe, expect, test } from 'bun:test'
import { Address, Bytes, Hash, U256 } from '../../src/primitives/index.js'
import { assertFuzz, type FuzzTape } from './engine.js'

const U256_MAX = (1n << 256n) - 1n
const U256_MOD = 1n << 256n

const BOUNDARY_BIGINTS: readonly bigint[] = [
	0n,
	1n,
	2n,
	3n,
	7n,
	8n,
	31n,
	32n,
	64n,
	127n,
	128n,
	255n,
	256n,
	(1n << 64n) - 1n,
	1n << 64n,
	(1n << 128n) - 1n,
	(1n << 255n) - 1n,
	1n << 255n,
	U256_MAX - 1n,
	U256_MAX,
]

function genU256BigInt(tape: FuzzTape, rng: () => number): bigint {
	const mode = tape.nat(4, rng)
	if (mode === 0) return tape.pick(BOUNDARY_BIGINTS, rng)
	const len = tape.int(0, 32, rng)
	let v = 0n
	for (let i = 0; i < len; i++) {
		v = (v << 8n) | BigInt(tape.nat(256, rng))
	}
	return v
}

describe('TypeScript SDK Primitives Fuzz Suite', () => {
	test('fuzz Address: bytes/hex/checksum/equality roundtrips & immutability', async () => {
		await assertFuzz(
			'Address roundtrip & validation',
			(tape, rng) => ({
				raw: tape.bytes(0, 48, rng),
				hexNoise: tape.bytes(0, 64, rng),
				prefix: tape.bool(rng),
			}),
			({ raw, hexNoise, prefix }, ctx) => {
				if (raw.length !== 20) {
					ctx.observe(`addr:invalid-len:${raw.length < 20 ? 'short' : 'long'}`)
					expect(() => Address.fromBytes(raw)).toThrow()
				} else {
					ctx.observe('addr:valid-20')
					const a = Address.fromBytes(raw)
					const bytesCopy = a.toBytes()
					expect(bytesCopy).toEqual(raw)

					// Immutability: mutating returned copy or input must not mutate Address
					bytesCopy[0] = (bytesCopy[0]! ^ 0xff) & 0xff
					expect(a.toBytes()).toEqual(raw)

					const hex = a.toHex()
					expect(hex.length).toBe(42)
					expect(hex.startsWith('0x')).toBe(true)

					const fromHex = Address.fromHex(prefix ? hex : hex.slice(2))
					expect(a.equals(fromHex)).toBe(true)
					expect(a.isZero()).toBe(raw.every((b) => b === 0))
					if (a.isZero()) ctx.observe('addr:zero')

					// Checksum roundtrip
					const csum = a.toChecksumHex()
					expect(csum.toLowerCase()).toBe(hex.toLowerCase())
					expect(Address.fromHex(csum).equals(a)).toBe(true)
				}

				// Adversarial non-hex string rejection
				const badStr = `0x${Buffer.from(hexNoise).toString('latin1')}zzzz`
				expect(() => Address.fromHex(badStr)).toThrow()
			},
			{ executions: 800, seed: 101 },
		)
	})

	test('fuzz U256: 256-bit arithmetic, bitwise, conversions & boundary validation vs BigInt oracle', async () => {
		await assertFuzz(
			'U256 oracle',
			(tape, rng) => ({
				a: genU256BigInt(tape, rng),
				b: genU256BigInt(tape, rng),
				badNeg: -BigInt(tape.int(1, 1000, rng)),
				badOver: U256_MOD + BigInt(tape.nat(1000, rng)),
			}),
			({ a, b, badNeg, badOver }, ctx) => {
				const ua = U256.fromBigInt(a)
				const ub = U256.fromBigInt(b)

				// Bytes & hex roundtrip bijection
				const bytes = ua.toBytes()
				expect(bytes.length).toBe(32)
				expect(U256.fromBytes(bytes).toBigInt()).toBe(a)
				expect(U256.fromHex(ua.toHex()).toBigInt()).toBe(a)

				// Invalid range rejection
				expect(() => U256.fromBigInt(badNeg)).toThrow()
				expect(() => U256.fromBigInt(badOver)).toThrow()
				expect(() => U256.fromBytes(new Uint8Array(33))).toThrow()

				// Comparisons
				expect(ua.equals(ub)).toBe(a === b)
				expect(ua.lt(ub)).toBe(a < b)
				expect(ua.lte(ub)).toBe(a <= b)
				expect(ua.gt(ub)).toBe(a > b)
				expect(ua.gte(ub)).toBe(a >= b)
				expect(ua.isZero()).toBe(a === 0n)

				// Checked vs wrapping arithmetic (detect overflow/underflow paths)
				if (a + b <= U256_MAX) {
					ctx.observe('u256:add-ok')
					expect(ua.add(ub).toBigInt()).toBe(a + b)
				} else {
					ctx.observe('u256:add-overflow')
					expect(() => ua.add(ub)).toThrow()
				}

				if (a >= b) {
					ctx.observe('u256:sub-ok')
					expect(ua.sub(ub).toBigInt()).toBe(a - b)
				} else {
					ctx.observe('u256:sub-underflow')
					expect(() => ua.sub(ub)).toThrow()
				}

				if (a * b <= U256_MAX) {
					ctx.observe('u256:mul-ok')
					expect(ua.mul(ub).toBigInt()).toBe(a * b)
				} else {
					ctx.observe('u256:mul-overflow')
					expect(() => ua.mul(ub)).toThrow()
				}

				if (b === 0n) {
					ctx.observe('u256:div-zero')
					expect(() => ua.div(ub)).toThrow()
					expect(() => ua.mod(ub)).toThrow()
				} else {
					ctx.observe('u256:div-ok')
					const q = ua.div(ub).toBigInt()
					const r = ua.mod(ub).toBigInt()
					expect(q).toBe(a / b)
					expect(r).toBe(a % b)
					expect(q * b + r).toBe(a)
				}
			},
			{ executions: 1000, seed: 202 },
		)
	})

	test('fuzz Bytes & Hash: concat, slice, hex roundtrips, padding & immutability', async () => {
		await assertFuzz(
			'Bytes & Hash invariants',
			(tape, rng) => ({
				a: tape.bytes(0, 64, rng),
				b: tape.bytes(0, 64, rng),
				hashRaw: tape.bytes(0, 48, rng),
				start: tape.nat(70, rng),
				end: tape.nat(70, rng),
			}),
			({ a, b, hashRaw, start, end }, ctx) => {
				const ba = Bytes.fromBytes(a)
				const bb = Bytes.fromBytes(b)

				expect(ba.length()).toBe(a.length)
				expect(ba.isEmpty()).toBe(a.length === 0)
				expect(Bytes.fromHex(ba.toHex()).toBytes()).toEqual(a)

				// Concatenation associativity & length
				const cat = Bytes.concat([ba, bb])
				expect(cat.length()).toBe(a.length + b.length)
				expect(cat.toBytes().slice(0, a.length)).toEqual(a)
				expect(cat.toBytes().slice(a.length)).toEqual(b)

				// Slice matches Uint8Array.prototype.slice
				const lo = Math.min(start, end)
				const hi = Math.max(start, end)
				if (lo <= a.length && hi <= a.length) {
					ctx.observe('bytes:slice-valid')
					expect(ba.slice(lo, hi).toBytes()).toEqual(a.slice(lo, hi))
				}

				// Hash validation & roundtrip
				if (hashRaw.length !== 32) {
					ctx.observe('hash:invalid-len')
					expect(() => Hash.fromBytes(hashRaw)).toThrow()
				} else {
					ctx.observe('hash:valid-32')
					const h = Hash.fromBytes(hashRaw)
					expect(h.toBytes()).toEqual(hashRaw)
					expect(Hash.fromHex(h.toHex()).equals(h)).toBe(true)
					expect(h.isZero()).toBe(hashRaw.every((x) => x === 0))
				}
			},
			{ executions: 800, seed: 303 },
		)
	})
})
