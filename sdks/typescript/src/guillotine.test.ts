import { describe, expect, it } from 'bun:test'
import { Address, Bytes, CallType, GuillotineEvm, U256 } from './index.js'

// End-to-end tests of the public SDK against the native libguillotine_ffi library.

const deployer = Address.fromHex('0x00000000000000000000000000000000000000d1')
const alice = Address.fromHex('0x00000000000000000000000000000000000000a1')
const TRANSFER_TOPIC = U256.fromHex('0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef')
const GAS = 1_000_000n

type Op = number | { push: bigint; size: number } | { label: string } | { ref: string }

/** Two-pass assembler: `{ label }` marks a JUMPDEST position, `{ ref }` emits PUSH2 <label offset>. */
function assemble(ops: Op[]): Uint8Array {
	const labels = new Map<string, number>()
	let pc = 0
	for (const op of ops) {
		if (typeof op === 'number') pc += 1
		else if ('push' in op) pc += 1 + op.size
		else if ('label' in op) {
			labels.set(op.label, pc)
			pc += 1
		} else pc += 3
	}
	const out: number[] = []
	for (const op of ops) {
		if (typeof op === 'number') out.push(op)
		else if ('push' in op) {
			out.push(0x5f + op.size)
			for (let i = op.size - 1; i >= 0; i--) out.push(Number((op.push >> BigInt(i * 8)) & 0xffn))
		} else if ('label' in op) out.push(0x5b)
		else {
			const target = labels.get(op.ref)
			if (target === undefined) throw new Error(`unknown label ${op.ref}`)
			out.push(0x61, target >> 8, target & 0xff)
		}
	}
	return new Uint8Array(out)
}

const p1 = (v: number): Op => ({ push: BigInt(v), size: 1 })
const [STOP, ADD, SUB, LT, EQ, SHR, CALLER, CALLDATALOAD, CODECOPY, POP, MSTORE, SLOAD, SSTORE, JUMPI] = [
	0x00, 0x01, 0x03, 0x10, 0x14, 0x1c, 0x33, 0x35, 0x39, 0x50, 0x52, 0x54, 0x55, 0x57,
]
const [DUP1, DUP2, DUP3, SWAP1, LOG3, RETURN, REVERT] = [0x80, 0x81, 0x82, 0x90, 0xa3, 0xf3, 0xfd]

/** Minimal token: balances[address] lives at storage slot `address`. */
const TOKEN_RUNTIME = assemble([
	p1(0),
	CALLDATALOAD,
	p1(0xe0),
	SHR,
	DUP1,
	{ push: 0xa9059cbbn, size: 4 },
	EQ,
	{ ref: 'transfer' },
	JUMPI,
	DUP1,
	{ push: 0x70a08231n, size: 4 },
	EQ,
	{ ref: 'balanceOf' },
	JUMPI,
	p1(0),
	DUP1,
	REVERT,
	{ label: 'transfer' },
	POP,
	p1(0x24),
	CALLDATALOAD, // [amount]
	CALLER,
	SLOAD, // [fromBalance, amount]
	DUP2,
	DUP2,
	LT,
	{ ref: 'fail' },
	JUMPI, // fromBalance < amount → revert
	DUP2,
	SWAP1,
	SUB,
	CALLER,
	SSTORE, // balances[caller] -= amount; [amount]
	p1(0x04),
	CALLDATALOAD,
	DUP1,
	SLOAD,
	DUP3,
	ADD,
	SWAP1,
	SSTORE, // balances[to] += amount; [amount]
	p1(0),
	MSTORE, // memory[0..32] = amount
	p1(0x04),
	CALLDATALOAD,
	CALLER,
	{ push: TRANSFER_TOPIC.toBigInt(), size: 32 },
	p1(0x20),
	p1(0),
	LOG3,
	p1(1),
	p1(0),
	MSTORE,
	p1(0x20),
	p1(0),
	RETURN,
	{ label: 'fail' },
	p1(0),
	DUP1,
	REVERT,
	{ label: 'balanceOf' },
	POP,
	p1(0x04),
	CALLDATALOAD,
	SLOAD,
	p1(0),
	MSTORE,
	p1(0x20),
	p1(0),
	RETURN,
	STOP,
])

const SUPPLY = 1_000_000n
// Init code: balances[deployer] = SUPPLY, then return the runtime appended after this 19-byte header.
const INIT_HEADER = assemble([
	{ push: SUPPLY, size: 3 },
	CALLER,
	SSTORE,
	{ push: BigInt(TOKEN_RUNTIME.length), size: 2 },
	DUP1,
	{ push: 19n, size: 2 },
	p1(0),
	CODECOPY,
	p1(0),
	RETURN,
])
const TOKEN_INIT = Bytes.concat([INIT_HEADER, TOKEN_RUNTIME])

function word(value: bigint): Uint8Array {
	return U256.fromBigInt(value).toBytes()
}

function transferCall(to: Address, amount: bigint): Bytes {
	return Bytes.concat([new Uint8Array([0xa9, 0x05, 0x9c, 0xbb]), word(BigInt(to.toHex())), word(amount)])
}

function balanceOfCall(owner: Address): Bytes {
	return Bytes.concat([new Uint8Array([0x70, 0xa0, 0x82, 0x31]), word(BigInt(owner.toHex()))])
}

async function deployToken(evm: GuillotineEvm): Promise<Address> {
	await evm.setBalance(deployer, U256.fromBigInt(10n ** 18n))
	const result = await evm.call({
		caller: deployer,
		to: Address.zero(),
		value: U256.zero(),
		input: TOKEN_INIT,
		gas: GAS,
		callType: CallType.CREATE,
	})
	expect(result.success).toBe(true)
	expect(result.createdAddress).not.toBeNull()
	if (result.createdAddress === null) throw new Error('CREATE returned no address')
	return result.createdAddress
}

/** Install the token runtime directly and mint SUPPLY to the deployer. */
async function installToken(evm: GuillotineEvm): Promise<Address> {
	const token = Address.fromHex('0x00000000000000000000000000000000000000e2')
	await evm.setCode(token, Bytes.fromBytes(TOKEN_RUNTIME))
	await evm.setStorage(token, U256.fromHex(deployer.toHex()), U256.fromBigInt(SUPPLY))
	return token
}

/** 0x42 deployed by MSTORE + RETURN; contains no jumps. */
const TINY_INIT = Bytes.fromHex('0x60426000526001601ff3') // PUSH1 0x42 PUSH1 0 MSTORE PUSH1 1 PUSH1 31 RETURN

describe('assembler', () => {
	it('places the init header length correctly', () => {
		expect(INIT_HEADER.length).toBe(19)
	})
})

describe('ERC20-style token', () => {
	it('deploys with CREATE and stores the runtime and initial supply', async () => {
		using evm = await GuillotineEvm.create()
		const token = await deployToken(evm)
		expect((await evm.getCode(token)).toBytes()).toEqual(TOKEN_RUNTIME)
		expect((await evm.getStorage(token, U256.fromHex(deployer.toHex()))).toBigInt()).toBe(SUPPLY)
	})

	it('transfers, emits Transfer, and updates storage', async () => {
		using evm = await GuillotineEvm.create()
		const token = await installToken(evm)

		const result = await evm.call({
			caller: deployer,
			to: token,
			value: U256.zero(),
			input: transferCall(alice, 250n),
			gas: GAS,
		})

		expect(result.success).toBe(true)
		expect(result.errorMessage).toBeNull()
		expect(U256.fromBytes(result.output.toBytes()).toBigInt()).toBe(1n)
		expect(result.gasLeft).toBeLessThan(GAS)
		expect(result.getGasUsed(GAS)).toBeGreaterThan(20_000n) // at least one fresh SSTORE
		expect(result.logs).toHaveLength(1)
		const log = result.logs[0]
		if (log === undefined) throw new Error('missing log')
		expect(log.address.equals(token)).toBe(true)
		expect(log.topics.map((t) => t.toBigInt())).toEqual([
			TRANSFER_TOPIC.toBigInt(),
			BigInt(deployer.toHex()),
			BigInt(alice.toHex()),
		])
		expect(U256.fromBytes(log.data.toBytes()).toBigInt()).toBe(250n)

		expect((await evm.getStorage(token, U256.fromHex(deployer.toHex()))).toBigInt()).toBe(SUPPLY - 250n)
		expect((await evm.getStorage(token, U256.fromHex(alice.toHex()))).toBigInt()).toBe(250n)

		const balance = await evm.call({
			caller: alice,
			to: token,
			value: U256.zero(),
			input: balanceOfCall(alice),
			gas: GAS,
		})
		expect(balance.success).toBe(true)
		expect(U256.fromBytes(balance.output.toBytes()).toBigInt()).toBe(250n)
	})

	it('reverts an overdraft without changing storage or emitting logs', async () => {
		using evm = await GuillotineEvm.create()
		const token = await installToken(evm)

		const result = await evm.call({
			caller: alice,
			to: token,
			value: U256.zero(),
			input: transferCall(deployer, 1n),
			gas: GAS,
		})

		expect(result.success).toBe(false)
		expect(result.output.isEmpty()).toBe(true)
		expect(result.logs).toHaveLength(0)
		expect(result.gasLeft).toBeGreaterThan(0n) // REVERT refunds unused gas
		expect((await evm.getStorage(token, U256.fromHex(deployer.toHex()))).toBigInt()).toBe(SUPPLY)
		expect((await evm.getStorage(token, U256.fromHex(alice.toHex()))).toBigInt()).toBe(0n)
	})

	it('simulate executes without committing state', async () => {
		using evm = await GuillotineEvm.create()
		const token = await installToken(evm)

		const result = await evm.simulate({
			caller: deployer,
			to: token,
			value: U256.zero(),
			input: transferCall(alice, 400n),
			gas: GAS,
		})

		expect(result.success).toBe(true)
		expect(result.logs).toHaveLength(1)
		expect((await evm.getStorage(token, U256.fromHex(alice.toHex()))).toBigInt()).toBe(0n)
		expect((await evm.getStorage(token, U256.fromHex(deployer.toHex()))).toBigInt()).toBe(SUPPLY)
	})
})

describe('arithmetic and value transfer', () => {
	it('returns 2 + 3 from an ADD contract', async () => {
		using evm = await GuillotineEvm.create()
		const contract = Address.fromHex('0x00000000000000000000000000000000000000c0')
		await evm.setCode(contract, Bytes.fromBytes(assemble([p1(2), p1(3), ADD, p1(0), MSTORE, p1(0x20), p1(0), RETURN])))
		const result = await evm.call({ caller: alice, to: contract, value: U256.zero(), input: Bytes.empty(), gas: GAS })
		expect(result.success).toBe(true)
		expect(U256.fromBytes(result.output.toBytes()).toBigInt()).toBe(5n)
	})

	it('moves value between balances', async () => {
		using evm = await GuillotineEvm.create()
		await evm.setBalance(alice, U256.fromBigInt(1_000n))
		const result = await evm.call({
			caller: alice,
			to: deployer,
			value: U256.fromBigInt(300n),
			input: Bytes.empty(),
			gas: GAS,
		})
		expect(result.success).toBe(true)
		expect((await evm.getBalance(alice)).toBigInt()).toBe(700n)
		expect((await evm.getBalance(deployer)).toBigInt()).toBe(300n)
	})

	it('setNonce changes the CREATE address', async () => {
		using first = await GuillotineEvm.create()
		using second = await GuillotineEvm.create()
		await second.setNonce(deployer, 7n)
		const deploy = async (evm: GuillotineEvm) => {
			const result = await evm.call({
				caller: deployer,
				to: Address.zero(),
				value: U256.zero(),
				input: TINY_INIT,
				gas: GAS,
				callType: CallType.CREATE,
			})
			expect(result.success).toBe(true)
			expect((await evm.getCode(result.createdAddress ?? Address.zero())).toBytes()).toEqual(new Uint8Array([0x42]))
			return result.createdAddress
		}
		const a = await deploy(first)
		const b = await deploy(second)
		expect(a).not.toBeNull()
		expect(b).not.toBeNull()
		expect(a?.equals(b ?? Address.zero())).toBe(false)
	})
})

describe('jump validation', () => {
	// Jump targets are validated only when the jump executes (Yellow Paper section 9.4.3).
	it('does not fail on an unreachable jump to a non-JUMPDEST', async () => {
		using evm = await GuillotineEvm.create()
		const contract = Address.fromHex('0x00000000000000000000000000000000000000c3')
		await evm.setCode(contract, Bytes.fromHex('0x0061000356')) // STOP; PUSH2 3; JUMP
		const result = await evm.call({
			caller: alice,
			to: contract,
			value: U256.zero(),
			input: Bytes.empty(),
			gas: 100_000n,
		})
		expect(result.success).toBe(true)
		expect(result.gasLeft).toBe(79_000n)
	})
})

describe('resource lifecycle', () => {
	it('dispose is idempotent and closes the handle', async () => {
		const evm = await GuillotineEvm.create()
		expect(evm.isOpen).toBe(true)
		evm.dispose()
		evm.dispose()
		evm.close()
		expect(evm.isOpen).toBe(false)
		await expect(evm.getBalance(alice)).rejects.toMatchObject({ type: 'VMNotInitialized' })
	})

	it('using releases the handle at scope exit', async () => {
		let captured: GuillotineEvm | undefined
		{
			using evm = await GuillotineEvm.create()
			captured = evm
			expect(evm.isOpen).toBe(true)
		}
		expect(captured.isOpen).toBe(false)
	})

	it('tracing handles return trace JSON and support state reads and simulate', async () => {
		using evm = await GuillotineEvm.create({}, { tracing: true })
		expect(evm.tracing).toBe(true)
		const contract = Address.fromHex('0x00000000000000000000000000000000000000c1')
		await evm.setCode(contract, Bytes.fromBytes(assemble([p1(2), p1(3), ADD, STOP])))
		await evm.setStorage(contract, U256.zero(), U256.one())
		expect((await evm.getStorage(contract, U256.zero())).toBigInt()).toBe(1n)
		const result = await evm.call({ caller: alice, to: contract, value: U256.zero(), input: Bytes.empty(), gas: GAS })
		expect(result.success).toBe(true)
		const trace: { structLogs: { op: string }[] } = JSON.parse(result.traceJson ?? 'null')
		expect(trace.structLogs.map((s) => s.op)).toEqual(['PUSH1', 'PUSH1', 'ADD', 'STOP'])
		const sim = await evm.simulate({ caller: alice, to: contract, value: U256.zero(), input: Bytes.empty(), gas: GAS })
		expect(sim.success).toBe(true)
		expect(sim.traceJson).not.toBeNull()
	})

	it('supports setBlockInfo, getNonce, callTracer, hardfork, and executeTx', async () => {
		using evm = await GuillotineEvm.create({ number: 10n, baseFee: 10n, coinbase: deployer })
		const target = Address.fromHex('0x0000000000000000000000000000000000001020')
		// NUMBER PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
		await evm.setCode(target, Bytes.fromBytes(new Uint8Array([0x43, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3])))
		const r1 = await evm.call({ caller: alice, to: target, value: U256.zero(), input: Bytes.empty(), gas: GAS })
		expect(U256.fromBytes(r1.output.toBytes()).toBigInt()).toBe(10n)

		await evm.setBlockInfo({ number: 777n, baseFee: 10n, coinbase: deployer })
		const r2 = await evm.call({ caller: alice, to: target, value: U256.zero(), input: Bytes.empty(), gas: GAS })
		expect(U256.fromBytes(r2.output.toBytes()).toBigInt()).toBe(777n)

		await evm.setBalance(alice, U256.fromBigInt(1_000_000_000n))
		expect(await evm.getNonce(alice)).toBe(2n)
		const txRes = await evm.executeTx({
			from: alice,
			to: target,
			nonce: 2n,
			gasLimit: 100_000n,
			maxFeePerGas: U256.fromBigInt(20n),
			maxPriorityFeePerGas: U256.fromBigInt(5n),
		})
		expect(txRes.success).toBe(true)
		expect(U256.fromBytes(txRes.output.toBytes()).toBigInt()).toBe(777n)
		expect(await evm.getNonce(alice)).toBe(3n)

		using ctEvm = await GuillotineEvm.create({}, { callTracer: true })
		expect(ctEvm.callTracer).toBe(true)
		await ctEvm.setCode(target, Bytes.fromBytes(new Uint8Array([0x60, 0x01, 0x00])))
		const ctRes = await ctEvm.call({ caller: alice, to: target, value: U256.zero(), input: Bytes.empty(), gas: GAS })
		expect(ctRes.success).toBe(true)
		expect(ctRes.traceJson).toContain('"type":"CALL"')

		using shanghai = await GuillotineEvm.create({}, { hardfork: 'shanghai' })
		await shanghai.setCode(target, Bytes.fromBytes(new Uint8Array([0x60, 0x01, 0x60, 0x00, 0x5d, 0x00]))) // TSTORE
		const shanghaiRes = await shanghai.call({
			caller: alice,
			to: target,
			value: U256.zero(),
			input: Bytes.empty(),
			gas: GAS,
		})
		expect(shanghaiRes.success).toBe(false)
	})

	it('mainnet calls carry no trace', async () => {
		using evm = await GuillotineEvm.create()
		const result = await evm.call({ caller: alice, to: deployer, value: U256.zero(), input: Bytes.empty(), gas: GAS })
		expect(result.traceJson).toBeNull()
	})
})

describe('input validation', () => {
	it('rejects out-of-range block fields before native code', async () => {
		await expect(GuillotineEvm.create({ chainId: 1n << 64n })).rejects.toMatchObject({ type: 'InvalidValue' })
		await expect(GuillotineEvm.create({ number: -1n })).rejects.toMatchObject({ type: 'InvalidValue' })
		await expect(GuillotineEvm.create({ gasLimit: 1n << 64n })).rejects.toMatchObject({ type: 'InvalidValue' })
	})

	it('keeps explicit zero block fields', async () => {
		using evm = await GuillotineEvm.create({ timestamp: 0n, number: 0n })
		const contract = Address.fromHex('0x00000000000000000000000000000000000000c2')
		// TIMESTAMP PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
		await evm.setCode(contract, Bytes.fromBytes(new Uint8Array([0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3])))
		const result = await evm.call({ caller: alice, to: contract, value: U256.zero(), input: Bytes.empty(), gas: GAS })
		expect(result.success).toBe(true)
		expect(U256.fromBytes(result.output.toBytes()).toBigInt()).toBe(0n)
	})

	it('rejects bad gas, nonce, and call types', async () => {
		using evm = await GuillotineEvm.create()
		const base = { caller: alice, to: deployer, value: U256.zero(), input: Bytes.empty() }
		await expect(evm.call({ ...base, gas: -1n })).rejects.toMatchObject({ type: 'InvalidValue' })
		await expect(evm.call({ ...base, gas: 1n << 64n })).rejects.toMatchObject({ type: 'InvalidValue' })
		await expect(evm.call({ ...base, gas: GAS, callType: 9 as CallType })).rejects.toMatchObject({
			type: 'InvalidValue',
		})
		await expect(evm.setNonce(alice, -1n)).rejects.toMatchObject({ type: 'InvalidValue' })
		await expect(evm.simulate({ ...base, gas: GAS, callType: CallType.STATICCALL })).rejects.toMatchObject({
			type: 'UnsupportedOperation',
		})
	})

	it('reports a missing native library', async () => {
		// Only meaningful before the library is loaded in this process; afterwards a different path is rejected.
		await expect(
			GuillotineEvm.create({}, { libraryPath: '/nonexistent/libguillotine_ffi.dylib' }),
		).rejects.toMatchObject({
			type: 'InitializationFailed',
		})
	})
})
