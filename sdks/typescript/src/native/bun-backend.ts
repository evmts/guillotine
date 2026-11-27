import type { Pointer } from 'bun:ffi'
import { GuillotineError } from '../errors.js'
import { decodeUtf8 } from '../evm/execution-result.js'
import type {
	HandleToken,
	NativeBackend,
	RawExecutionResult,
	RawLogEntry,
	RawSelfDestructRecord,
	RawStorageAccessRecord,
} from './backend.js'

const CALL_PARAMS_SIZE = 136
const TX_PARAMS_SIZE = 224
const LOG_ENTRY_SIZE = 56
const SELFDESTRUCT_SIZE = 40
const STORAGE_ACCESS_SIZE = 52
const SENTINEL = new Uint8Array(1)

function toPointer(value: bigint | Pointer | null): Pointer | null {
	if (value === null || value === 0 || value === 0n) return null
	if (typeof value === 'bigint') {
		if (value > BigInt(Number.MAX_SAFE_INTEGER)) {
			throw GuillotineError.memoryError(`Native pointer 0x${value.toString(16)} exceeds Number.MAX_SAFE_INTEGER`)
		}
		return Number(value) as Pointer
	}
	return value
}

function asPointer(handle: HandleToken): Pointer {
	const p = toPointer(handle as bigint | Pointer)
	if (p === null) throw GuillotineError.vmNotInitialized('EVM handle is null')
	return p
}

/** Dynamically load `bun:ffi` and bind `libguillotine_ffi`. Only invoked under Bun. */
export async function loadBunBackend(path: string): Promise<NativeBackend> {
	const ffi = await import('bun:ffi')
	const { dlopen, FFIType, ptr, read, toArrayBuffer } = ffi

	const symbols = {
		guillotine_init: { args: [], returns: FFIType.void },
		guillotine_get_last_error: { args: [], returns: FFIType.ptr },
		guillotine_evm_create_with_config: { args: [FFIType.ptr, FFIType.u8], returns: FFIType.ptr },
		guillotine_evm_create_with_fork: { args: [FFIType.ptr, FFIType.u8], returns: FFIType.ptr },
		guillotine_evm_destroy: { args: [FFIType.ptr], returns: FFIType.void },
		guillotine_set_block_info: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
		guillotine_set_balance: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
		guillotine_set_nonce: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.bool },
		guillotine_get_nonce: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
		guillotine_set_code: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.bool },
		guillotine_set_storage: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
		guillotine_get_balance: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
		guillotine_get_storage: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
		guillotine_get_code: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
		guillotine_free_code: { args: [FFIType.ptr, FFIType.u64], returns: FFIType.void },
		guillotine_call: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
		guillotine_simulate: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
		guillotine_execute_tx: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
		guillotine_free_result: { args: [FFIType.ptr], returns: FFIType.void },
	} as const

	let lib: ReturnType<typeof dlopen<typeof symbols>>
	try {
		lib = dlopen(path, symbols)
	} catch (error) {
		throw GuillotineError.initializationFailed(
			`Failed to load ${path}`,
			error instanceof Error ? error : new Error(String(error)),
		)
	}
	const sym = lib.symbols
	sym.guillotine_init()

	function copyNative(address: Pointer, offset: number, len: number): Uint8Array {
		if (len === 0) return new Uint8Array(0)
		if (address === 0) throw GuillotineError.memoryError(`Native buffer of ${len} bytes has a null pointer`)
		return new Uint8Array(toArrayBuffer(address, offset, len)).slice()
	}

	function readSize(address: Pointer, offset: number): number {
		const value = read.u64(address, offset)
		if (value > BigInt(Number.MAX_SAFE_INTEGER)) {
			throw GuillotineError.memoryError(`Native length ${value} exceeds Number.MAX_SAFE_INTEGER`)
		}
		return Number(value)
	}

	function readCString(address: Pointer, what: string): string {
		if (address === 0) throw GuillotineError.memoryError(`${what} has a null pointer`)
		let len = 0
		while (read.u8(address, len) !== 0) len++
		return decodeUtf8(copyNative(address, 0, len), what)
	}

	function readResult(result: Pointer): RawExecutionResult {
		const success = read.u8(result, 0) !== 0
		const gasLeft = read.u64(result, 8)
		const output = copyNative(read.ptr(result, 16) as Pointer, 0, readSize(result, 24))
		const errorPtr = read.ptr(result, 32) as Pointer
		const nativeError = errorPtr === 0 ? '' : readCString(errorPtr, 'Native error message')
		const errorMessage = success || nativeError === '' ? null : nativeError

		const logs: RawLogEntry[] = []
		const logsPtr = read.ptr(result, 40) as Pointer
		const logsLen = readSize(result, 48)
		for (let i = 0; i < logsLen; i++) {
			const entry = copyNative(logsPtr, i * LOG_ENTRY_SIZE, LOG_ENTRY_SIZE)
			const fields = new DataView(entry.buffer)
			const topicsPtr = Number(fields.getBigUint64(24, true)) as Pointer
			const topicsLen = Number(fields.getBigUint64(32, true))
			const dataPtr = Number(fields.getBigUint64(40, true)) as Pointer
			const dataLen = Number(fields.getBigUint64(48, true))
			const topics: Uint8Array[] = []
			for (let t = 0; t < topicsLen; t++) {
				topics.push(copyNative(topicsPtr, t * 32, 32))
			}
			logs.push({
				address: entry.subarray(0, 20).slice(),
				topics,
				data: copyNative(dataPtr, 0, dataLen),
			})
		}

		const selfdestructs: RawSelfDestructRecord[] = []
		const sdBytes = copyNative(read.ptr(result, 56) as Pointer, 0, readSize(result, 64) * SELFDESTRUCT_SIZE)
		for (let offset = 0; offset < sdBytes.length; offset += SELFDESTRUCT_SIZE) {
			selfdestructs.push({
				contract: sdBytes.subarray(offset, offset + 20).slice(),
				beneficiary: sdBytes.subarray(offset + 20, offset + 40).slice(),
			})
		}

		const accessedAddresses: Uint8Array[] = []
		const addrBytes = copyNative(read.ptr(result, 72) as Pointer, 0, readSize(result, 80) * 20)
		for (let offset = 0; offset < addrBytes.length; offset += 20) {
			accessedAddresses.push(addrBytes.subarray(offset, offset + 20).slice())
		}

		const accessedStorage: RawStorageAccessRecord[] = []
		const storageBytes = copyNative(read.ptr(result, 88) as Pointer, 0, readSize(result, 96) * STORAGE_ACCESS_SIZE)
		for (let offset = 0; offset < storageBytes.length; offset += STORAGE_ACCESS_SIZE) {
			accessedStorage.push({
				address: storageBytes.subarray(offset, offset + 20).slice(),
				slot: storageBytes.subarray(offset + 20, offset + 52).slice(),
			})
		}

		const createdAddress = read.u8(result, 124) !== 0 ? copyNative(result, 104, 20) : null
		const traceLen = readSize(result, 136)
		const traceJson =
			traceLen === 0 ? null : decodeUtf8(copyNative(read.ptr(result, 128) as Pointer, 0, traceLen), 'Native trace JSON')

		return {
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
		}
	}

	function runCall(
		handle: HandleToken,
		caller: Uint8Array,
		to: Uint8Array,
		value: Uint8Array,
		input: Uint8Array,
		gas: bigint,
		callType: number,
		salt: Uint8Array,
		isSimulate: boolean,
	): RawExecutionResult | null {
		const inputBuf = input.length === 0 ? SENTINEL : input
		const block = new Uint8Array(CALL_PARAMS_SIZE)
		const view = new DataView(block.buffer)
		block.set(caller, 0)
		block.set(to, 20)
		block.set(value, 40)
		view.setBigUint64(72, BigInt(ptr(inputBuf)), true)
		view.setBigUint64(80, BigInt(input.length), true)
		view.setBigUint64(88, gas, true)
		view.setUint8(96, callType)
		block.set(salt, 97)

		const h = asPointer(handle)
		const resultPtr = toPointer(isSimulate ? sym.guillotine_simulate(h, block) : sym.guillotine_call(h, block))
		void inputBuf
		if (resultPtr === null) return null
		try {
			return readResult(resultPtr)
		} finally {
			sym.guillotine_free_result(resultPtr)
		}
	}

	return {
		runtime: 'bun-ffi',
		path,
		getLastError(): string {
			const message = toPointer(sym.guillotine_get_last_error())
			return message === null ? 'unknown native error' : readCString(message, 'Native last-error message')
		},
		createEvm(blockInfoBuf, configByte, hardforkId): HandleToken | null {
			const raw =
				hardforkId !== undefined
					? sym.guillotine_evm_create_with_fork(blockInfoBuf, hardforkId)
					: sym.guillotine_evm_create_with_config(blockInfoBuf, configByte)
			return toPointer(raw)
		},
		destroyEvm(handle): void {
			sym.guillotine_evm_destroy(asPointer(handle))
		},
		setBlockInfo(handle, blockInfoBuf): boolean {
			return sym.guillotine_set_block_info(asPointer(handle), blockInfoBuf)
		},
		setBalance(handle, address, balance): boolean {
			return sym.guillotine_set_balance(asPointer(handle), address, balance)
		},
		setNonce(handle, address, nonce): boolean {
			return sym.guillotine_set_nonce(asPointer(handle), address, nonce)
		},
		getNonce(handle, address): bigint | null {
			const out = new BigUint64Array(1)
			const ok = sym.guillotine_get_nonce(asPointer(handle), address, new Uint8Array(out.buffer))
			return ok ? (out[0] ?? 0n) : null
		},
		setCode(handle, address, code): boolean {
			const buf = code.length === 0 ? SENTINEL : code
			return sym.guillotine_set_code(asPointer(handle), address, buf, code.length)
		},
		setStorage(handle, address, key, value): boolean {
			return sym.guillotine_set_storage(asPointer(handle), address, key, value)
		},
		getBalance(handle, address): Uint8Array | null {
			const out = new Uint8Array(32)
			return sym.guillotine_get_balance(asPointer(handle), address, out) ? out : null
		},
		getStorage(handle, address, key): Uint8Array | null {
			const out = new Uint8Array(32)
			return sym.guillotine_get_storage(asPointer(handle), address, key, out) ? out : null
		},
		getCode(handle, address): Uint8Array | null {
			const codeOut = new BigUint64Array(1)
			const lenOut = new BigUint64Array(1)
			const ok = sym.guillotine_get_code(
				asPointer(handle),
				address,
				new Uint8Array(codeOut.buffer),
				new Uint8Array(lenOut.buffer),
			)
			if (!ok) return null
			const len = lenOut[0] ?? 0n
			const codePtr = toPointer(codeOut[0] ?? 0n)
			if (len === 0n) return new Uint8Array(0)
			if (codePtr === null) throw GuillotineError.memoryError(`Native code buffer of ${len} bytes has a null pointer`)
			try {
				if (len > BigInt(Number.MAX_SAFE_INTEGER)) {
					throw GuillotineError.memoryError(`Native code length ${len} exceeds Number.MAX_SAFE_INTEGER`)
				}
				return copyNative(codePtr, 0, Number(len))
			} finally {
				sym.guillotine_free_code(codePtr, len)
			}
		},
		call(handle, caller, to, value, input, gas, callType, salt): RawExecutionResult | null {
			return runCall(handle, caller, to, value, input, gas, callType, salt, false)
		},
		simulate(handle, caller, to, value, input, gas, callType, salt): RawExecutionResult | null {
			return runCall(handle, caller, to, value, input, gas, callType, salt, true)
		},
		executeTx(
			handle,
			txType,
			from,
			to,
			nonce,
			gasLimit,
			value,
			gasPrice,
			maxFeePerGas,
			maxPriorityFeePerGas,
			input,
			disableBalanceCheck,
		): RawExecutionResult | null {
			// LP64 layout of TxParamsFFI in sdks/c/include/guillotine.h:
			// 0: tx_type (1), 1: from (20), 21: to (20), 41: has_to (1), pad(6)
			// 48: nonce (8), 56: has_nonce (1), pad(7)
			// 64: gas_limit (8), 72: value (32), 104: gas_price (32), 136: max_fee (32), 168: has_max_fee (1),
			// 169: max_priority (32), pad(7), 208: input_ptr (8), 216: input_len (8) -> wait: check offsets!
			// Let's keep exact C natural alignment:
			// 169 + 32 = 201 -> align 8 => 208 (input_ptr: 8), 216 (input_len: 8), 224 (disable_balance_check: 1), total padded = 232!
			const buf = new Uint8Array(TX_PARAMS_SIZE + 8)
			const view = new DataView(buf.buffer)
			const inputBuf = input.length === 0 ? SENTINEL : input
			buf[0] = txType
			buf.set(from, 1)
			if (to !== null) {
				buf.set(to, 21)
				buf[41] = 1
			}
			if (nonce !== null) {
				view.setBigUint64(48, nonce, true)
				buf[56] = 1
			}
			view.setBigUint64(64, gasLimit, true)
			buf.set(value, 72)
			buf.set(gasPrice, 104)
			if (maxFeePerGas !== null) {
				buf.set(maxFeePerGas, 136)
				buf[168] = 1
			}
			buf.set(maxPriorityFeePerGas, 169)
			view.setBigUint64(208, BigInt(ptr(inputBuf)), true)
			view.setBigUint64(216, BigInt(input.length), true)
			buf[224] = disableBalanceCheck ? 1 : 0

			const resultPtr = toPointer(sym.guillotine_execute_tx(asPointer(handle), buf))
			void inputBuf
			if (resultPtr === null) return null
			try {
				return readResult(resultPtr)
			} finally {
				sym.guillotine_free_result(resultPtr)
			}
		},
	}
}
