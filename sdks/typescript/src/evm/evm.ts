import type { Pointer } from 'bun:ffi'
import { GuillotineError } from '../errors.js'
import {
	addressOf,
	copyNative,
	lastError,
	loadNative,
	type NativeSymbols,
	pointerAt,
	readCString,
	readPointer,
	readSize,
	readU8,
	readU64,
	toPointer,
} from '../native/library.js'
import { Address } from '../primitives/address.js'
import { Bytes } from '../primitives/bytes.js'
import { U256 } from '../primitives/u256.js'
import {
	decodeUtf8,
	ExecutionResult,
	type LogEntry,
	type SelfDestructRecord,
	type StorageAccessRecord,
} from './execution-result.js'

/** Block context copied into the native EVM at creation. */
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

export interface CreateOptions {
	/**
	 * Create a tracing EVM. Tracing handles support setBalance, setNonce, setCode and call
	 * (which returns `traceJson`); storage and state reads are not available natively.
	 */
	tracing?: boolean
	/** Path to `libguillotine_ffi`. Defaults to `GUILLOTINE_LIB_PATH`, then the bundled prebuild. */
	libraryPath?: string
}

const U64_MAX = (1n << 64n) - 1n

// LP64 layouts of the extern structs in src/evm_c_api.zig (checked by sdks/c/tests/simple_test.c).
const BLOCK_INFO_SIZE = 104
const CALL_PARAMS_SIZE = 136
const LOG_ENTRY_SIZE = 56
const SELFDESTRUCT_SIZE = 40
const STORAGE_ACCESS_SIZE = 52

/** Non-optional Zig pointers need valid storage even for zero-length buffers. */
const SENTINEL = new Uint8Array(1)

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

/**
 * Native handle shared by a `GuillotineEvm` and the finalization registry. It holds no
 * reference to the wrapper, so an unreachable wrapper can be collected and its handle destroyed.
 */
interface NativeHandle {
	readonly id: number
	readonly native: NativeSymbols
	readonly tracing: boolean
	handle: Pointer | null
}

const liveHandles = new Set<number>()
let nextHandleId = 1
let spuriousFinalizations = 0

/** Destroy the native handle once. Returns false if it was already released. */
function release(state: NativeHandle): boolean {
	const handle = state.handle
	if (handle === null) return false
	state.handle = null
	liveHandles.delete(state.id)
	if (state.tracing) {
		state.native.guillotine_evm_destroy_tracing(handle)
	} else {
		state.native.guillotine_evm_destroy(handle)
	}
	return true
}

// Safety net for EVMs dropped without dispose(). dispose() unregisters first, and release()
// clears the handle before destroying it, so a handle is never destroyed twice.
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
 * A Guillotine EVM instance backed by the native `libguillotine_ffi` library through Bun FFI.
 * Each instance owns separate state. Release it with `dispose()`, `close()` or a `using` declaration.
 * An instance that becomes unreachable without being released is destroyed when it is garbage
 * collected; do not rely on that timing.
 */
export class GuillotineEvm implements Disposable {
	private readonly state: NativeHandle
	private readonly native: NativeSymbols
	readonly tracing: boolean

	private constructor(native: NativeSymbols, handle: Pointer, tracing: boolean) {
		this.native = native
		this.tracing = tracing
		this.state = { id: nextHandleId++, native, tracing, handle }
		liveHandles.add(this.state.id)
		finalizer.register(this, this.state, this)
	}

	/** Create an EVM with the given block context. */
	static async create(blockInfo: BlockInfo = {}, options: CreateOptions = {}): Promise<GuillotineEvm> {
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

		const native = loadNative(options.libraryPath)
		const tracing = options.tracing ?? false
		const handle = toPointer(
			tracing ? native.guillotine_evm_create_tracing(block) : native.guillotine_evm_create(block),
		)
		if (handle === null) {
			throw GuillotineError.vmCreationFailed(`Failed to create EVM: ${lastError(native)}`)
		}
		return new GuillotineEvm(native, handle, tracing)
	}

	/** True until `dispose()` or `close()` releases the native handle. */
	get isOpen(): boolean {
		return this.state.handle !== null
	}

	/** Execute a message call or contract creation and commit its state changes. */
	async call(params: ExecutionParams): Promise<ExecutionResult> {
		const handle = this.open()
		return this.execute(params, (block) =>
			this.tracing ? this.native.guillotine_call_tracing(handle, block) : this.native.guillotine_call(handle, block),
		)
	}

	/** Execute a CALL without committing state. Not available on tracing EVMs. */
	async simulate(params: ExecutionParams): Promise<ExecutionResult> {
		const handle = this.open()
		this.requireMainnet('simulate')
		const callType = params.callType ?? CallType.CALL
		if (callType !== CallType.CALL) {
			throw GuillotineError.unsupportedOperation(`simulate supports CALL only, got ${CallType[callType] ?? callType}`)
		}
		return this.execute(params, (block) => this.native.guillotine_simulate(handle, block))
	}

	async setBalance(address: Address, balance: U256): Promise<void> {
		const handle = this.open()
		const ok = this.tracing
			? this.native.guillotine_set_balance_tracing(handle, address.toBytes(), balance.toBytes())
			: this.native.guillotine_set_balance(handle, address.toBytes(), balance.toBytes())
		this.check(ok, 'set balance')
	}

	async setNonce(address: Address, nonce: bigint): Promise<void> {
		const handle = this.open()
		const value = u64('nonce', nonce)
		const ok = this.tracing
			? this.native.guillotine_set_nonce_tracing(handle, address.toBytes(), value)
			: this.native.guillotine_set_nonce(handle, address.toBytes(), value)
		this.check(ok, 'set nonce')
	}

	async setCode(address: Address, code: Bytes): Promise<void> {
		const handle = this.open()
		const bytes = code.isEmpty() ? SENTINEL : code.toBytes()
		const len = code.length()
		const ok = this.tracing
			? this.native.guillotine_set_code_tracing(handle, address.toBytes(), bytes, len)
			: this.native.guillotine_set_code(handle, address.toBytes(), bytes, len)
		this.check(ok, 'set code')
	}

	/** Not available on tracing EVMs. */
	async setStorage(address: Address, key: U256, value: U256): Promise<void> {
		const handle = this.open()
		this.requireMainnet('setStorage')
		this.check(
			this.native.guillotine_set_storage(handle, address.toBytes(), key.toBytes(), value.toBytes()),
			'set storage',
		)
	}

	/** Not available on tracing EVMs. */
	async getBalance(address: Address): Promise<U256> {
		const handle = this.open()
		this.requireMainnet('getBalance')
		const out = new Uint8Array(32)
		this.check(this.native.guillotine_get_balance(handle, address.toBytes(), out), 'get balance')
		return U256.fromBytes(out)
	}

	/** Not available on tracing EVMs. */
	async getStorage(address: Address, key: U256): Promise<U256> {
		const handle = this.open()
		this.requireMainnet('getStorage')
		const out = new Uint8Array(32)
		this.check(this.native.guillotine_get_storage(handle, address.toBytes(), key.toBytes(), out), 'get storage')
		return U256.fromBytes(out)
	}

	/** Not available on tracing EVMs. */
	async getCode(address: Address): Promise<Bytes> {
		const handle = this.open()
		this.requireMainnet('getCode')
		const codeOut = new BigUint64Array(1)
		const lenOut = new BigUint64Array(1)
		this.check(
			this.native.guillotine_get_code(
				handle,
				address.toBytes(),
				new Uint8Array(codeOut.buffer),
				new Uint8Array(lenOut.buffer),
			),
			'get code',
		)
		const len = lenOut[0] ?? 0n
		const codePtr = toPointer(codeOut[0] ?? 0n)
		if (len === 0n) return Bytes.empty()
		if (codePtr === null) throw GuillotineError.memoryError(`Native code buffer of ${len} bytes has a null pointer`)
		try {
			if (len > BigInt(Number.MAX_SAFE_INTEGER)) {
				throw GuillotineError.memoryError(`Native code length ${len} exceeds Number.MAX_SAFE_INTEGER`)
			}
			return Bytes.fromBytes(copyNative(codePtr, 0, Number(len)))
		} finally {
			this.native.guillotine_free_code(codePtr, len)
		}
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

	private open(): Pointer {
		const handle = this.state.handle
		if (handle === null) throw GuillotineError.vmNotInitialized('EVM instance is not initialized: it was closed')
		return handle
	}

	private requireMainnet(operation: string): void {
		if (this.tracing) {
			throw GuillotineError.unsupportedOperation(`${operation} is not available on a tracing EVM`)
		}
	}

	private check(ok: boolean, operation: string): void {
		if (!ok) throw GuillotineError.stateError(`Failed to ${operation}: ${lastError(this.native)}`)
	}

	private execute(params: ExecutionParams, run: (callParams: Uint8Array) => bigint | Pointer | null): ExecutionResult {
		const callType = params.callType ?? CallType.CALL
		if (CallType[callType] === undefined) {
			throw GuillotineError.invalidValue(`Unknown call type ${callType}`)
		}
		const input = params.input.isEmpty() ? SENTINEL : params.input.toBytes()
		const block = new Uint8Array(CALL_PARAMS_SIZE)
		const view = new DataView(block.buffer)
		block.set(params.caller.toBytes(), 0)
		block.set(params.to.toBytes(), 20)
		block.set(params.value.toBytes(), 40)
		view.setBigUint64(72, BigInt(addressOf(input)), true)
		view.setBigUint64(80, BigInt(params.input.length()), true)
		view.setBigUint64(88, u64('gas', params.gas), true)
		view.setUint8(96, callType)
		block.set((params.salt ?? U256.zero()).toBytes(), 97)

		let resultPtr: Pointer | null
		try {
			resultPtr = toPointer(run(block))
		} catch (error) {
			throw GuillotineError.executionFailed('Native call threw', cause(error))
		}
		// Keep `input` reachable until the native call has returned.
		void input
		if (resultPtr === null) {
			throw GuillotineError.executionFailed(`EVM execution failed: ${lastError(this.native)}`)
		}
		try {
			return readResult(resultPtr)
		} finally {
			this.native.guillotine_free_result(resultPtr)
		}
	}
}

/** Copy an `EvmResult` (LP64 layout) into JS-owned objects. The caller frees the native result. */
function readResult(result: Pointer): ExecutionResult {
	const success = readU8(result, 0) !== 0
	const gasLeft = readU64(result, 8)
	const output = Bytes.fromBytes(copyNative(readPointer(result, 16), 0, readSize(result, 24)))
	const errorPtr = readPointer(result, 32)
	const nativeError = errorPtr === 0 ? '' : readCString(errorPtr, 'Native error message')
	const errorMessage = success || nativeError === '' ? null : nativeError

	const logs: LogEntry[] = []
	const logsPtr = readPointer(result, 40)
	const logsLen = readSize(result, 48)
	for (let i = 0; i < logsLen; i++) {
		const entry = copyNative(logsPtr, i * LOG_ENTRY_SIZE, LOG_ENTRY_SIZE)
		const fields = new DataView(entry.buffer)
		const topicsPtr = pointerAt(Number(fields.getBigUint64(24, true)))
		const topicsLen = Number(fields.getBigUint64(32, true))
		const dataPtr = pointerAt(Number(fields.getBigUint64(40, true)))
		const dataLen = Number(fields.getBigUint64(48, true))
		const topics: U256[] = []
		for (let t = 0; t < topicsLen; t++) {
			topics.push(U256.fromBytes(copyNative(topicsPtr, t * 32, 32)))
		}
		logs.push({
			address: Address.fromBytes(entry.subarray(0, 20)),
			topics,
			data: Bytes.fromBytes(copyNative(dataPtr, 0, dataLen)),
		})
	}

	const selfdestructs: SelfDestructRecord[] = []
	const sdBytes = copyNative(readPointer(result, 56), 0, readSize(result, 64) * SELFDESTRUCT_SIZE)
	for (let offset = 0; offset < sdBytes.length; offset += SELFDESTRUCT_SIZE) {
		selfdestructs.push({
			contract: Address.fromBytes(sdBytes.subarray(offset, offset + 20)),
			beneficiary: Address.fromBytes(sdBytes.subarray(offset + 20, offset + 40)),
		})
	}

	const accessedAddresses: Address[] = []
	const addrBytes = copyNative(readPointer(result, 72), 0, readSize(result, 80) * 20)
	for (let offset = 0; offset < addrBytes.length; offset += 20) {
		accessedAddresses.push(Address.fromBytes(addrBytes.subarray(offset, offset + 20)))
	}

	const accessedStorage: StorageAccessRecord[] = []
	const storageBytes = copyNative(readPointer(result, 88), 0, readSize(result, 96) * STORAGE_ACCESS_SIZE)
	for (let offset = 0; offset < storageBytes.length; offset += STORAGE_ACCESS_SIZE) {
		accessedStorage.push({
			address: Address.fromBytes(storageBytes.subarray(offset, offset + 20)),
			slot: U256.fromBytes(storageBytes.subarray(offset + 20, offset + 52)),
		})
	}

	const createdAddress = readU8(result, 124) !== 0 ? Address.fromBytes(copyNative(result, 104, 20)) : null

	const traceLen = readSize(result, 136)
	const traceJson =
		traceLen === 0 ? null : decodeUtf8(copyNative(readPointer(result, 128), 0, traceLen), 'Native trace JSON')

	return new ExecutionResult(
		success,
		gasLeft,
		output,
		errorMessage,
		logs,
		selfdestructs,
		accessedAddresses,
		accessedStorage,
		createdAddress,
		traceJson,
	)
}
