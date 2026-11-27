import { GuillotineError } from '../errors.js'
import type { HandleToken, NativeBackend, RawExecutionResult } from '../native/backend.js'
import { loadNativeBackend } from '../native/library.js'
import { Address } from '../primitives/address.js'
import { Bytes } from '../primitives/bytes.js'
import { U256 } from '../primitives/u256.js'
import {
	ExecutionResult,
	type LogEntry,
	type SelfDestructRecord,
	type StorageAccessRecord,
} from './execution-result.js'

/** Block context copied into the native EVM at creation or updated via `setBlockInfo`. */
export interface BlockInfo {
	number?: bigint
	/** Defaults to the current Unix time in seconds. */
	timestamp?: bigint
	gasLimit?: bigint
	coinbase?: Address
	baseFee?: bigint
	/** 0 to 2^64-1 as a bigint, or a non-negative safe integer number. Defaults to 1. */
	chainId?: bigint | number
	difficulty?: bigint
	/** Exactly 32 bytes. */
	prevRandao?: Bytes
}

/** Native `call_type` tags from `guillotine.h`. */
export enum CallType {
	CALL = 0,
	CALLCODE = 1,
	DELEGATECALL = 2,
	STATICCALL = 3,
	CREATE = 4,
	CREATE2 = 5,
}

/** Supported hardforks for runtime fork selection (`guillotine_evm_create_with_fork`). */
export type Hardfork = 'shanghai' | 'cancun' | 'prague' | 'osaka'

const HARDFORK_IDS: Record<Hardfork, number> = {
	shanghai: 15,
	cancun: 16,
	prague: 17,
	osaka: 18,
}

/** Parameters for one top-level message call or contract creation. */
export interface ExecutionParams {
	caller: Address
	/** Ignored by the native EVM for CREATE and CREATE2. */
	to: Address
	value: U256
	/** Calldata for calls, init code for CREATE/CREATE2. */
	input: Bytes
	/** Gas limit, 0 to 2^64-1. */
	gas: bigint
	/** Defaults to CALL. */
	callType?: CallType
	/** CREATE2 salt; defaults to zero. */
	salt?: U256
}

/** Parameters for full Ethereum transaction execution (`executeTx`). */
export interface TransactionParams {
	/** 0=legacy, 1=EIP-2930, 2=EIP-1559, 3=EIP-4844, 4=EIP-7702. Defaults to 2 when maxFeePerGas is set, else 0. */
	txType?: number
	from: Address
	/** Omit or pass null for contract creation (CREATE). */
	to?: Address | null
	/** When set, enforces strict sender nonce equality before incrementing. */
	nonce?: bigint
	gasLimit: bigint
	value?: U256
	gasPrice?: U256
	maxFeePerGas?: U256
	maxPriorityFeePerGas?: U256
	input?: Bytes
	/** Skip sender balance deduction (useful for eth_call / simulation). */
	disableBalanceCheck?: boolean
}

export interface CreateOptions {
	/** Enable full per-opcode `structLogs` trace JSON on calls. */
	tracing?: boolean
	/** Enable structured Geth `callTracer` JSON without per-opcode `structLogs` overhead. */
	callTracer?: boolean
	/** Select a specific Ethereum hardfork (`shanghai`, `cancun`, `prague`, `osaka`). Defaults to `osaka`. */
	hardfork?: Hardfork
	/** Path to `guillotine.node` or `libguillotine_ffi`. Defaults to env vars, then bundled prebuilds. */
	libraryPath?: string
}

const U64_MAX = (1n << 64n) - 1n
const BLOCK_INFO_SIZE = 104
const CONFIG_MAINNET = 0
const CONFIG_TRACER = 1
const CONFIG_CALL_TRACER = 3

function u64(name: string, value: bigint, max: bigint = U64_MAX): bigint {
	if (value < 0n || value > max) {
		throw GuillotineError.invalidValue(`${name} must be between 0 and ${max}, got ${value}`)
	}
	return value
}

function chainId(value: bigint | number): bigint {
	if (typeof value === 'number') {
		if (!Number.isSafeInteger(value) || value < 0) {
			throw GuillotineError.invalidValue(
				`chainId must be an integer between 0 and ${Number.MAX_SAFE_INTEGER} when given as a number (use a bigint up to ${U64_MAX}), got ${value}`,
			)
		}
		return BigInt(value)
	}
	if (typeof value !== 'bigint') {
		throw GuillotineError.invalidValue(`chainId must be a bigint or number, got ${typeof value}`)
	}
	return u64('chainId', value)
}

function encodeBlockInfo(blockInfo: BlockInfo): Uint8Array {
	const block = new Uint8Array(BLOCK_INFO_SIZE)
	const view = new DataView(block.buffer)
	view.setBigUint64(0, u64('number', blockInfo.number ?? 0n), true)
	view.setBigUint64(8, u64('timestamp', blockInfo.timestamp ?? BigInt(Math.floor(Date.now() / 1000))), true)
	view.setBigUint64(16, u64('gasLimit', blockInfo.gasLimit ?? 30_000_000n), true)
	block.set((blockInfo.coinbase ?? Address.zero()).toBytes(), 24)
	view.setBigUint64(48, u64('baseFee', blockInfo.baseFee ?? 0n), true)
	view.setBigUint64(56, chainId(blockInfo.chainId ?? 1n), true)
	view.setBigUint64(64, u64('difficulty', blockInfo.difficulty ?? 0n), true)
	if (blockInfo.prevRandao !== undefined) {
		if (blockInfo.prevRandao.length() !== 32) {
			throw GuillotineError.invalidValue(`prevRandao must be 32 bytes, got ${blockInfo.prevRandao.length()}`)
		}
		block.set(blockInfo.prevRandao.toBytes(), 72)
	}
	return block
}

function toExecutionResult(raw: RawExecutionResult): ExecutionResult {
	const logs: LogEntry[] = raw.logs.map((entry) => ({
		address: Address.fromBytes(entry.address),
		topics: entry.topics.map((t) => U256.fromBytes(t)),
		data: Bytes.fromBytes(entry.data),
	}))
	const selfdestructs: SelfDestructRecord[] = raw.selfdestructs.map((sd) => ({
		contract: Address.fromBytes(sd.contract),
		beneficiary: Address.fromBytes(sd.beneficiary),
	}))
	const accessedAddresses: Address[] = raw.accessedAddresses.map((addr) => Address.fromBytes(addr))
	const accessedStorage: StorageAccessRecord[] = raw.accessedStorage.map((st) => ({
		address: Address.fromBytes(st.address),
		slot: U256.fromBytes(st.slot),
	}))
	const createdAddress = raw.createdAddress !== null ? Address.fromBytes(raw.createdAddress) : null
	return new ExecutionResult(
		raw.success,
		raw.gasLeft,
		Bytes.fromBytes(raw.output),
		raw.errorMessage,
		logs,
		selfdestructs,
		accessedAddresses,
		accessedStorage,
		createdAddress,
		raw.traceJson,
	)
}

interface NativeHandle {
	readonly id: number
	readonly backend: NativeBackend
	handle: HandleToken | null
}

const liveHandles = new Set<number>()
let nextHandleId = 1
let spuriousFinalizations = 0

function release(state: NativeHandle): boolean {
	const handle = state.handle
	if (handle === null) return false
	state.handle = null
	liveHandles.delete(state.id)
	state.backend.destroyEvm(handle)
	return true
}

const finalizer = new FinalizationRegistry<NativeHandle>((state) => {
	if (!release(state)) spuriousFinalizations++
})

/**
 * Internal diagnostics for tests: ids of native handles not yet destroyed, and the number of
 * finalizer callbacks that found their handle already released (always 0 unless unregister failed).
 */
export function nativeHandleStats(): { live: ReadonlySet<number>; spuriousFinalizations: number } {
	return { live: new Set(liveHandles), spuriousFinalizations }
}

function cause(error: unknown): Error {
	return error instanceof Error ? error : new Error(String(error))
}

/**
 * A Guillotine EVM instance backed by either the zero-node-gyp Node-API addon
 * (`guillotine.node`, working in Node.js >=20, Bun >=1.1, and Deno) or Bun FFI
 * (`libguillotine_ffi`). Each instance owns separate state; release it with
 * `dispose()`, `close()`, or a `using` declaration.
 */
export class GuillotineEvm implements Disposable {
	private readonly state: NativeHandle
	private readonly backend: NativeBackend
	readonly tracing: boolean
	readonly callTracer: boolean

	private constructor(backend: NativeBackend, handle: HandleToken, tracing: boolean, callTracer: boolean) {
		this.backend = backend
		this.tracing = tracing
		this.callTracer = callTracer
		this.state = { id: nextHandleId++, backend, handle }
		liveHandles.add(this.state.id)
		finalizer.register(this, this.state, this)
	}

	/** Active native transport (`'napi'` in Node.js / Node-API mode, `'bun-ffi'` for Bun FFI). */
	get runtime(): 'napi' | 'bun-ffi' {
		return this.backend.runtime
	}

	/** Create an EVM with the given block context. */
	static async create(blockInfo: BlockInfo = {}, options: CreateOptions = {}): Promise<GuillotineEvm> {
		const block = encodeBlockInfo(blockInfo)
		const tracing = options.tracing ?? false
		const callTracer = options.callTracer ?? false
		if (tracing && callTracer) {
			throw GuillotineError.invalidValue('Cannot enable both tracing (structLogs) and callTracer at the same time')
		}
		if (options.hardfork !== undefined && (tracing || callTracer)) {
			throw GuillotineError.unsupportedOperation(
				'Custom hardfork cannot currently be combined with tracing or callTracer',
			)
		}
		const forkId = options.hardfork !== undefined ? HARDFORK_IDS[options.hardfork] : undefined
		if (options.hardfork !== undefined && forkId === undefined) {
			throw GuillotineError.invalidValue(`Unknown hardfork: ${String(options.hardfork)}`)
		}

		const backend = await loadNativeBackend(options.libraryPath)
		const configByte = tracing ? CONFIG_TRACER : callTracer ? CONFIG_CALL_TRACER : CONFIG_MAINNET
		const handle = backend.createEvm(block, configByte, forkId)
		if (handle === null) {
			throw GuillotineError.vmCreationFailed(`Failed to create EVM: ${backend.getLastError()}`)
		}
		return new GuillotineEvm(backend, handle, tracing, callTracer)
	}

	/** True until `dispose()` or `close()` releases the native handle. */
	get isOpen(): boolean {
		return this.state.handle !== null
	}

	/** Update block context in place without recreating the EVM or discarding its dispatch cache. */
	async setBlockInfo(blockInfo: BlockInfo): Promise<void> {
		const handle = this.open()
		const block = encodeBlockInfo(blockInfo)
		this.check(this.backend.setBlockInfo(handle, block), 'set block info')
	}

	/** Execute a message call or contract creation and commit its state changes. */
	async call(params: ExecutionParams): Promise<ExecutionResult> {
		const handle = this.open()
		return this.runCall(params, (caller, to, value, input, gas, callType, salt) =>
			this.backend.call(handle, caller, to, value, input, gas, callType, salt),
		)
	}

	/** Execute a CALL without committing database changes. */
	async simulate(params: ExecutionParams): Promise<ExecutionResult> {
		const handle = this.open()
		const callType = params.callType ?? CallType.CALL
		if (callType !== CallType.CALL) {
			throw GuillotineError.unsupportedOperation(`simulate supports CALL only, got ${CallType[callType] ?? callType}`)
		}
		return this.runCall(params, (caller, to, value, input, gas, ct, salt) =>
			this.backend.simulate(handle, caller, to, value, input, gas, ct, salt),
		)
	}

	/**
	 * Execute a full Ethereum transaction (intrinsic gas, EIP-1559 fee validation,
	 * EIP-7623 calldata floor, EIP-3529 refund cap, EIP-7825 gas cap, coinbase tip).
	 */
	async executeTx(params: TransactionParams): Promise<ExecutionResult> {
		const handle = this.open()
		const txType = params.txType ?? (params.maxFeePerGas !== undefined ? 2 : 0)
		const gasLimit = u64('gasLimit', params.gasLimit)
		const nonce = params.nonce !== undefined ? u64('nonce', params.nonce) : null
		const toBytes = params.to !== undefined && params.to !== null ? params.to.toBytes() : null
		const valueBytes = (params.value ?? U256.zero()).toBytes()
		const gasPriceBytes = (params.gasPrice ?? U256.zero()).toBytes()
		const maxFeeBytes = params.maxFeePerGas !== undefined ? params.maxFeePerGas.toBytes() : null
		const maxPriorityBytes = (params.maxPriorityFeePerGas ?? U256.zero()).toBytes()
		const inputBytes = (params.input ?? Bytes.empty()).toBytes()

		let raw: RawExecutionResult | null
		try {
			raw = this.backend.executeTx(
				handle,
				txType,
				params.from.toBytes(),
				toBytes,
				nonce,
				gasLimit,
				valueBytes,
				gasPriceBytes,
				maxFeeBytes,
				maxPriorityBytes,
				inputBytes,
				params.disableBalanceCheck ?? false,
			)
		} catch (error) {
			throw GuillotineError.executionFailed('Native executeTx threw', cause(error))
		}
		if (raw === null) {
			throw GuillotineError.executionFailed(`Transaction execution failed: ${this.backend.getLastError()}`)
		}
		return toExecutionResult(raw)
	}

	async setBalance(address: Address, balance: U256): Promise<void> {
		const handle = this.open()
		this.check(this.backend.setBalance(handle, address.toBytes(), balance.toBytes()), 'set balance')
	}

	async setNonce(address: Address, nonce: bigint): Promise<void> {
		const handle = this.open()
		this.check(this.backend.setNonce(handle, address.toBytes(), u64('nonce', nonce)), 'set nonce')
	}

	async getNonce(address: Address): Promise<bigint> {
		const handle = this.open()
		const nonce = this.backend.getNonce(handle, address.toBytes())
		if (nonce === null) {
			throw GuillotineError.stateError(`Failed to get nonce: ${this.backend.getLastError()}`)
		}
		return nonce
	}

	async setCode(address: Address, code: Bytes): Promise<void> {
		const handle = this.open()
		this.check(this.backend.setCode(handle, address.toBytes(), code.toBytes()), 'set code')
	}

	async setStorage(address: Address, key: U256, value: U256): Promise<void> {
		const handle = this.open()
		this.check(this.backend.setStorage(handle, address.toBytes(), key.toBytes(), value.toBytes()), 'set storage')
	}

	async getBalance(address: Address): Promise<U256> {
		const handle = this.open()
		const out = this.backend.getBalance(handle, address.toBytes())
		if (out === null) {
			throw GuillotineError.stateError(`Failed to get balance: ${this.backend.getLastError()}`)
		}
		return U256.fromBytes(out)
	}

	async getStorage(address: Address, key: U256): Promise<U256> {
		const handle = this.open()
		const out = this.backend.getStorage(handle, address.toBytes(), key.toBytes())
		if (out === null) {
			throw GuillotineError.stateError(`Failed to get storage: ${this.backend.getLastError()}`)
		}
		return U256.fromBytes(out)
	}

	async getCode(address: Address): Promise<Bytes> {
		const handle = this.open()
		const out = this.backend.getCode(handle, address.toBytes())
		if (out === null) {
			throw GuillotineError.stateError(`Failed to get code: ${this.backend.getLastError()}`)
		}
		return out.length === 0 ? Bytes.empty() : Bytes.fromBytes(out)
	}

	/** Release the native handle. Safe to call more than once. */
	dispose(): void {
		if (this.state.handle === null) return
		finalizer.unregister(this)
		release(this.state)
	}

	/** Alias of `dispose()`. */
	close(): void {
		this.dispose()
	}

	[Symbol.dispose](): void {
		this.dispose()
	}

	private open(): HandleToken {
		const handle = this.state.handle
		if (handle === null) throw GuillotineError.vmNotInitialized('EVM instance is not initialized: it was closed')
		return handle
	}

	private check(ok: boolean, operation: string): void {
		if (!ok) throw GuillotineError.stateError(`Failed to ${operation}: ${this.backend.getLastError()}`)
	}

	private runCall(
		params: ExecutionParams,
		invoke: (
			caller: Uint8Array,
			to: Uint8Array,
			value: Uint8Array,
			input: Uint8Array,
			gas: bigint,
			callType: number,
			salt: Uint8Array,
		) => RawExecutionResult | null,
	): ExecutionResult {
		const callType = params.callType ?? CallType.CALL
		if (CallType[callType] === undefined) {
			throw GuillotineError.invalidValue(`Unknown call type ${callType}`)
		}
		const gas = u64('gas', params.gas)
		let raw: RawExecutionResult | null
		try {
			raw = invoke(
				params.caller.toBytes(),
				params.to.toBytes(),
				params.value.toBytes(),
				params.input.toBytes(),
				gas,
				callType,
				(params.salt ?? U256.zero()).toBytes(),
			)
		} catch (error) {
			throw GuillotineError.executionFailed('Native call threw', cause(error))
		}
		if (raw === null) {
			throw GuillotineError.executionFailed(`EVM execution failed: ${this.backend.getLastError()}`)
		}
		return toExecutionResult(raw)
	}
}
