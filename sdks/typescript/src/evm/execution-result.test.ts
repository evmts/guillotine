import { describe, expect, it } from 'bun:test'
import { GuillotineError } from '../errors.js'
import { Address } from '../primitives/address.js'
import { Bytes } from '../primitives/bytes.js'
import { U256 } from '../primitives/u256.js'
import { GuillotineEvm } from './evm.js'
import { decodeUtf8, ExecutionResult } from './execution-result.js'

describe('decodeUtf8', () => {
	it('decodes valid UTF-8 including multi-byte characters', () => {
		expect(decodeUtf8(new TextEncoder().encode('revert: résumé ✓'), 'error message')).toBe('revert: résumé ✓')
		expect(decodeUtf8(new Uint8Array(0), 'error message')).toBe('')
	})

	it('throws a typed InvalidUtf8 error instead of inserting U+FFFD', () => {
		for (const bad of [[0xff], [0xc3], [0xe2, 0x82], [0xed, 0xa0, 0x80], [0x61, 0x80, 0x62]]) {
			let thrown: unknown
			try {
				decodeUtf8(new Uint8Array(bad), 'native error message')
			} catch (error) {
				thrown = error
			}
			expect(thrown).toBeInstanceOf(GuillotineError)
			expect(thrown).toMatchObject({ type: 'InvalidUtf8' })
			expect((thrown as GuillotineError).message).toContain('native error message')
			expect((thrown as GuillotineError).cause).toBeInstanceOf(TypeError)
		}
	})
})

describe('ExecutionResult.getOutputString', () => {
	it('returns null for empty output and the decoded string for valid UTF-8', () => {
		expect(ExecutionResult.success(0n).getOutputString()).toBeNull()
		expect(ExecutionResult.success(0n, Bytes.fromString('hello ✓')).getOutputString()).toBe('hello ✓')
	})

	it('throws InvalidUtf8 for invalid output bytes instead of returning null or replacement characters', () => {
		const result = ExecutionResult.success(0n, Bytes.fromBytes(new Uint8Array([0x68, 0xff, 0x69])))
		expect(() => result.getOutputString()).toThrow(GuillotineError)
		expect(() => result.getOutputString()).toThrow(expect.objectContaining({ type: 'InvalidUtf8' }))
	})

	it('surfaces invalid UTF-8 returned by native execution', async () => {
		using evm = await GuillotineEvm.create()
		const contract = Address.fromHex('0x00000000000000000000000000000000000000f1')
		// PUSH1 0xff PUSH1 0 MSTORE8 PUSH1 1 PUSH1 0 RETURN
		await evm.setCode(
			contract,
			Bytes.fromBytes(new Uint8Array([0x60, 0xff, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3])),
		)
		const caller = Address.fromHex('0x00000000000000000000000000000000000000a1')
		const result = await evm.call({ caller, to: contract, value: U256.zero(), input: Bytes.empty(), gas: 100_000n })
		expect(result.success).toBe(true)
		expect(result.output.toBytes()).toEqual(new Uint8Array([0xff]))
		expect(() => result.getOutputString()).toThrow(expect.objectContaining({ type: 'InvalidUtf8' }))
	})
})
