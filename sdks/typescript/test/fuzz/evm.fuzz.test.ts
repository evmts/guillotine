import { describe, expect, test } from 'bun:test'
import { GuillotineError } from '../../src/errors.js'
import { CallType, GuillotineEvm } from '../../src/evm/evm.js'
import { Address, Bytes, U256 } from '../../src/primitives/index.js'
import { assertFuzz, type FuzzTape } from './engine.js'

const U64_MAX = (1n << 64n) - 1n

function makeAddress(id: number): Address {
	const bytes = new Uint8Array(20)
	bytes[19] = (id & 0xff) || 1
	bytes[18] = (id >>> 8) & 0xff
	return Address.fromBytes(bytes)
}

function genU256(tape: FuzzTape, rng: () => number): U256 {
	const mode = tape.nat(4, rng)
	if (mode === 0) {
		const picks = [0n, 1n, 2n, 42n, 1_000_000n, (1n << 64n) - 1n, (1n << 128n) - 1n, (1n << 256n) - 1n]
		return U256.fromBigInt(tape.pick(picks, rng))
	}
	return U256.fromBytes(tape.bytes(1, 32, rng))
}

/** Generate structure-aware EVM bytecode that explores arithmetic, memory, storage, logs, reverts, and calls. */
function genEvmBytecode(tape: FuzzTape, rng: () => number): Uint8Array {
	const mode = tape.nat(5, rng)
	if (mode === 0) {
		// Raw arbitrary bytes (fuzzes decoder/invalid opcodes/truncated PUSH across FFI)
		return tape.bytes(0, 96, rng)
	}

	const ops: number[] = []
	const steps = tape.int(1, 16, rng)

	if (mode === 1) {
		// Arithmetic & bitwise returning 32-byte word
		ops.push(0x60, tape.nat(256, rng), 0x60, tape.nat(256, rng))
		const binOps = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x10, 0x11, 0x14, 0x16, 0x17, 0x18]
		for (let i = 0; i < steps; i++) {
			ops.push(0x60, tape.nat(256, rng), tape.pick(binOps, rng))
		}
		ops.push(0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3)
	} else if (mode === 2) {
		// Storage + logs + optional revert
		for (let i = 0; i < steps; i++) {
			const slot = tape.nat(6, rng)
			const val = tape.nat(256, rng)
			const kind = tape.nat(4, rng)
			if (kind === 0) ops.push(0x60, val, 0x60, slot, 0x55) // SSTORE
			else if (kind === 1) ops.push(0x60, slot, 0x54, 0x60, 0x00, 0x52) // SLOAD
			else if (kind === 2) ops.push(0x60, val, 0x60, 0x20, 0x60, 0x00, 0xa1) // LOG1
			else ops.push(0x60, val, 0x60, slot, 0x5d) // TSTORE
		}
		const revert = tape.nat(4, rng) === 0
		ops.push(0x60, 0x20, 0x60, 0x00, revert ? 0xfd : 0xf3)
	} else if (mode === 3) {
		// Memory & MCOPY & CALLDATALOAD
		for (let i = 0; i < steps; i++) {
			const off = tape.nat(64, rng)
			const val = tape.nat(256, rng)
			const k = tape.nat(4, rng)
			if (k === 0) ops.push(0x60, val, 0x60, off, 0x52) // MSTORE
			else if (k === 1) ops.push(0x60, val, 0x60, off, 0x53) // MSTORE8
			else if (k === 2) ops.push(0x60, off, 0x35, 0x60, 0x00, 0x52) // CALLDATALOAD
			else ops.push(0x60, 0x10, 0x60, off, 0x60, (off + 3) & 0x3f, 0x5e) // MCOPY
		}
		ops.push(0x60, 0x40, 0x60, 0x00, 0xf3)
	} else {
		// Minimal deployable init code returning small runtime code
		const runtimeByte = tape.nat(256, rng)
		ops.push(0x60, runtimeByte, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3)
	}

	return new Uint8Array(ops)
}

describe('TypeScript SDK GuillotineEvm Live FFI Fuzz Suite', () => {
	test('fuzz state roundtrips across Bun FFI: balances, nonces, storage slots, and bytecodes', async () => {
		const evm = await GuillotineEvm.create({ number: 20_000_000n, chainId: 1n })
		try {
			await assertFuzz(
				'FFI state roundtrips',
				(tape, rng) => ({
					addr: makeAddress(tape.int(1, 12, rng)),
					balance: genU256(tape, rng),
					nonce: BigInt(tape.nextU32(rng)),
					slot: genU256(tape, rng),
					slotVal: genU256(tape, rng),
					code: tape.bytes(0, 128, rng),
				}),
				async ({ addr, balance, nonce, slot, slotVal, code }, ctx) => {
					await evm.setBalance(addr, balance)
					const gotBal = await evm.getBalance(addr)
					expect(gotBal.equals(balance)).toBe(true)

					await evm.setNonce(addr, nonce)

					await evm.setStorage(addr, slot, slotVal)
					const gotSlot = await evm.getStorage(addr, slot)
					expect(gotSlot.equals(slotVal)).toBe(true)

					const codeBytes = Bytes.fromBytes(code)
					await evm.setCode(addr, codeBytes)
					const gotCode = await evm.getCode(addr)
					expect(gotCode.toBytes()).toEqual(code)

					ctx.observe(code.length === 0 ? 'code:empty' : 'code:nonempty')
					ctx.observe(balance.isZero() ? 'bal:zero' : 'bal:nonzero')
					ctx.observe(slotVal.isZero() ? 'slot:zero' : 'slot:nonzero')
				},
				{ executions: 250, seed: 404 },
			)
		} finally {
			evm.dispose()
		}
	})

	test('fuzz feedback-guided EVM execution, simulate() isolation, and all CallTypes across FFI', async () => {
		await assertFuzz(
			'FFI execution & simulate isolation',
			(tape, rng) => ({
				code: genEvmBytecode(tape, rng),
				calldata: tape.bytes(0, 48, rng),
				gas: BigInt(tape.pick([21_000, 30_000, 80_000, 300_000, 1_000_000], rng)),
				callType: tape.pick(
					[
						CallType.CALL,
						CallType.CALLCODE,
						CallType.DELEGATECALL,
						CallType.STATICCALL,
						CallType.CREATE,
						CallType.CREATE2,
					],
					rng,
				),
				salt: U256.fromBigInt(BigInt(tape.nextU32(rng))),
				initSlot0: U256.fromBigInt(BigInt(tape.nat(256, rng))),
			}),
			async ({ code, calldata, gas, callType, salt, initSlot0 }, ctx) => {
				const caller = makeAddress(0x11)
				const target = makeAddress(0x22)
				const evm = await GuillotineEvm.create({ number: 20_000_000n, timestamp: 1_700_000_000n, chainId: 1n })
				try {
					await evm.setBalance(caller, U256.fromBigInt(10_000_000_000_000n))
					await evm.setCode(target, Bytes.fromBytes(code))
					await evm.setStorage(target, U256.zero(), initSlot0)

					const params = {
						caller,
						to: target,
						value: U256.zero(),
						input: Bytes.fromBytes(
							callType === CallType.CREATE || callType === CallType.CREATE2 ? code : calldata,
						),
						gas,
						callType,
						salt,
					}

					// 1. simulate() supports CALL only: verify CALL parity + zero mutation, and clean rejection for others
					if (callType === CallType.CALL) {
						const sim = await evm.simulate(params)
						const slotAfterSim = await evm.getStorage(target, U256.zero())
						expect(slotAfterSim.equals(initSlot0)).toBe(true)

						const res = await evm.call(params)
						expect(res.success).toBe(sim.success)
						expect(res.gasLeft).toBe(sim.gasLeft)
						expect(res.output.toBytes()).toEqual(sim.output.toBytes())
						expect(res.gasLeft <= gas).toBe(true)

						ctx.observe(`callType:${callType}:${res.success ? 'ok' : 'fail'}`)
						if (res.logs.length > 0) ctx.observe('outcome:logs')
						if (res.selfdestructs.length > 0) ctx.observe('outcome:selfdestruct')
						if (res.output.length() > 0) ctx.observe('outcome:returndata')
						ctx.score('gasUsed', Number(gas - res.gasLeft))
					} else {
						await expect(evm.simulate(params)).rejects.toThrow(GuillotineError)
						const res = await evm.call(params)
						expect(res.gasLeft <= gas).toBe(true)

						ctx.observe(`callType:${callType}:${res.success ? 'ok' : 'fail'}`)
						if (res.logs.length > 0) ctx.observe('outcome:logs')
						if (res.createdAddress) ctx.observe('outcome:created')
						if (res.selfdestructs.length > 0) ctx.observe('outcome:selfdestruct')
						if (res.output.length() > 0) ctx.observe('outcome:returndata')
						ctx.score('gasUsed', Number(gas - res.gasLeft))
					}
				} finally {
					evm.dispose()
				}
			},
			{ executions: 250, seed: 505 },
		)
	})

	test('fuzz tracing EVM produces valid JSON traces across random bytecode', async () => {
		await assertFuzz(
			'FFI tracing JSON validity',
			(tape, rng) => ({
				code: genEvmBytecode(tape, rng),
				calldata: tape.bytes(0, 32, rng),
			}),
			async ({ code, calldata }, ctx) => {
				const caller = makeAddress(0x11)
				const target = makeAddress(0x22)
				const evm = await GuillotineEvm.create({ number: 1n, chainId: 1n }, { tracing: true })
				try {
					await evm.setBalance(caller, U256.fromBigInt(1_000_000_000n))
					await evm.setCode(target, Bytes.fromBytes(code))
					const res = await evm.call({
						caller,
						to: target,
						value: U256.zero(),
						input: Bytes.fromBytes(calldata),
						gas: 100_000n,
					})
					expect(res.gasLeft <= 100_000n).toBe(true)
					if (res.traceJson != null && res.traceJson.length > 0) {
						ctx.observe('trace:present')
						const parsed = JSON.parse(res.traceJson)
						expect(parsed).toBeDefined()
					} else {
						ctx.observe('trace:empty')
					}
				} finally {
					evm.dispose()
				}
			},
			{ executions: 100, seed: 606 },
		)
	})

	test('fuzz FFI boundary validation rejects out-of-range BlockInfo, ExecutionParams, and post-dispose calls cleanly', async () => {
		await assertFuzz(
			'FFI validation boundaries',
			(tape, rng) => ({
				badGas: tape.bool(rng) ? -BigInt(tape.int(1, 1000, rng)) : U64_MAX + BigInt(tape.int(1, 1000, rng)),
				badChainId: U64_MAX + 1n + BigInt(tape.nat(100_000, rng)),
				badRandaoLen: tape.pick([0, 1, 16, 31, 33, 64], rng),
			}),
			async ({ badGas, badChainId, badRandaoLen }, ctx) => {
				await expect(GuillotineEvm.create({ chainId: badChainId })).rejects.toThrow(GuillotineError)
				await expect(
					GuillotineEvm.create({ prevRandao: Bytes.zeros(badRandaoLen) }),
				).rejects.toThrow(GuillotineError)

				const evm = await GuillotineEvm.create()
				try {
					await expect(
						evm.call({
							caller: Address.zero(),
							to: makeAddress(1),
							value: U256.zero(),
							input: Bytes.empty(),
							gas: badGas,
						}),
					).rejects.toThrow(GuillotineError)
					ctx.observe('validation:rejected')
				} finally {
					evm.dispose()
				}

				// Post-dispose operations must throw cleanly, never use-after-free!
				await expect(evm.getBalance(Address.zero())).rejects.toThrow(GuillotineError)
				// Double dispose must be an idempotent no-op
				evm.dispose()
				ctx.observe('lifecycle:double-dispose-safe')
			},
			{ executions: 120, seed: 707 },
		)
	})

	test('fuzz stateful multi-transaction sequences on a single persistent GuillotineEvm instance', async () => {
		await assertFuzz(
			'Stateful multi-tx FFI sequence',
			(tape, rng) => {
				const len = tape.int(3, 10, rng)
				const steps: Array<
					| { kind: 'setBalance'; acct: number; val: bigint }
					| { kind: 'setStorage'; acct: number; slot: bigint; val: bigint }
					| { kind: 'setCode'; acct: number; code: Uint8Array }
					| { kind: 'call'; caller: number; to: number; gas: bigint; calldata: Uint8Array }
					| { kind: 'simulate'; caller: number; to: number; gas: bigint; calldata: Uint8Array }
				> = []
				for (let i = 0; i < len; i++) {
					const k = tape.nat(5, rng)
					if (k === 0) {
						steps.push({ kind: 'setBalance', acct: tape.int(1, 4, rng), val: BigInt(tape.nextU32(rng)) * 1000n })
					} else if (k === 1) {
						steps.push({
							kind: 'setStorage',
							acct: tape.int(1, 4, rng),
							slot: BigInt(tape.nat(4, rng)),
							val: BigInt(tape.nextU32(rng)),
						})
					} else if (k === 2) {
						steps.push({ kind: 'setCode', acct: tape.int(1, 4, rng), code: genEvmBytecode(tape, rng) })
					} else if (k === 3) {
						steps.push({
							kind: 'call',
							caller: tape.int(1, 4, rng),
							to: tape.int(1, 4, rng),
							gas: BigInt(tape.pick([21_000, 60_000, 200_000], rng)),
							calldata: tape.bytes(0, 32, rng),
						})
					} else {
						steps.push({
							kind: 'simulate',
							caller: tape.int(1, 4, rng),
							to: tape.int(1, 4, rng),
							gas: BigInt(tape.pick([21_000, 60_000, 200_000], rng)),
							calldata: tape.bytes(0, 32, rng),
						})
					}
				}
				return steps
			},
			async (steps, ctx) => {
				const evm = await GuillotineEvm.create({ number: 20_000_000n, chainId: 1n })
				try {
					for (const step of steps) {
						if (step.kind === 'setBalance') {
							const a = makeAddress(step.acct)
							await evm.setBalance(a, U256.fromBigInt(step.val))
							expect((await evm.getBalance(a)).toBigInt()).toBe(step.val)
						} else if (step.kind === 'setStorage') {
							const a = makeAddress(step.acct)
							await evm.setStorage(a, U256.fromBigInt(step.slot), U256.fromBigInt(step.val))
							expect((await evm.getStorage(a, U256.fromBigInt(step.slot))).toBigInt()).toBe(step.val)
						} else if (step.kind === 'setCode') {
							const a = makeAddress(step.acct)
							await evm.setCode(a, Bytes.fromBytes(step.code))
							expect((await evm.getCode(a)).toBytes()).toEqual(step.code)
						} else if (step.kind === 'call') {
							const res = await evm.call({
								caller: makeAddress(step.caller),
								to: makeAddress(step.to),
								value: U256.zero(),
								input: Bytes.fromBytes(step.calldata),
								gas: step.gas,
							})
							expect(res.gasLeft <= step.gas).toBe(true)
							ctx.observe(`seq:call:${res.success ? 'ok' : 'fail'}`)
						} else {
							const target = makeAddress(step.to)
							const before = await evm.getStorage(target, U256.zero())
							const sim = await evm.simulate({
								caller: makeAddress(step.caller),
								to: target,
								value: U256.zero(),
								input: Bytes.fromBytes(step.calldata),
								gas: step.gas,
							})
							expect(sim.gasLeft <= step.gas).toBe(true)
							expect((await evm.getStorage(target, U256.zero())).equals(before)).toBe(true)
							ctx.observe(`seq:sim:${sim.success ? 'ok' : 'fail'}`)
						}
					}
				} finally {
					evm.dispose()
				}
			},
			{ executions: 120, seed: 808 },
		)
	})
})
