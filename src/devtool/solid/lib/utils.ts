import type { EvmState } from '~/lib/types'

export async function loadBytecode(bytecodeHex: string): Promise<void> {
	try {
		console.log('load_bytecode', { bytecodeHex })
		const response = await window.load_bytecode(bytecodeHex)
		console.log('load_bytecode response:', response)

		// Check if response contains error
		if (typeof response === 'string') {
			const parsed = JSON.parse(response)
			if (parsed.error) {
				throw new Error(parsed.error)
			}
		}
	} catch (err) {
		throw new Error(`Failed to load bytecode: ${err}`)
	}
}

export async function resetEvm(): Promise<EvmState> {
	try {
		console.log('reset_evm')
		const response = await window.reset_evm()
		console.log('reset_evm response:', response)

		if (typeof response === 'string') {
			const parsed = JSON.parse(response)
			if (parsed.error) {
				throw new Error(parsed.error)
			}
			return parsed
		}
		return response
	} catch (err) {
		throw new Error(`Failed to reset EVM: ${err}`)
	}
}

export async function stepEvm(): Promise<EvmState> {
	try {
		console.log('step_evm')
		const response = await window.step_evm()
		console.log('step_evm response:', response)

		if (typeof response === 'string') {
			const parsed = JSON.parse(response)
			if (parsed.error) {
				throw new Error(parsed.error)
			}
			return parsed
		}
		return response
	} catch (err) {
		throw new Error(`Failed to step: ${err}`)
	}
}

export async function toggleRunPause(): Promise<EvmState> {
	try {
		console.log('toggle_run_pause')
		// For now, just get the current state since we don't have continuous execution yet
		return await getEvmState()
	} catch (err) {
		throw new Error(`Failed to toggle run/pause: ${err}`)
	}
}

export async function getEvmState(): Promise<EvmState> {
	try {
		console.log('get_evm_state')
		const response = await window.get_evm_state()
		console.log('get_evm_state response:', response)

		if (typeof response === 'string') {
			const parsed = JSON.parse(response)
			if (parsed.error) {
				throw new Error(parsed.error)
			}

			// Map fields from Zig JSON to frontend state
			return {
				gasLeft: parsed.gasLeft,
				depth: parsed.depth,
				stack: parsed.stack || [],
				memory: parsed.memory || '0x',
				storage: parsed.storage || [],
				logs: parsed.logs || [],
				returnData: parsed.returnData || '0x',
				completed: parsed.completed || false,
				currentInstructionIndex: parsed.currentInstructionIndex || 0,
				currentBlockStartIndex: parsed.currentBlockStartIndex || 0,
				blocks: parsed.blocks || [],
			}
		}
		return response
	} catch (err) {
		throw new Error(`Failed to get state: ${err}`)
	}
}

export const copyToClipboard = (text: string): void => {
	navigator.clipboard.writeText(text)
}

export const opcodeToString = (opcode: number): string => {
	const opcodes: Record<number, string> = {
		0: 'STOP',
		1: 'ADD',
		2: 'MUL',
		3: 'SUB',
		4: 'DIV',
		5: 'SDIV',
		6: 'MOD',
		7: 'SMOD',
		8: 'ADDMOD',
		9: 'MULMOD',
		10: 'EXP',
		11: 'SIGNEXTEND',
		16: 'LT',
		17: 'GT',
		18: 'SLT',
		19: 'SGT',
		20: 'EQ',
		21: 'ISZERO',
		22: 'AND',
		23: 'OR',
		24: 'XOR',
		25: 'NOT',
		26: 'BYTE',
		27: 'SHL',
		28: 'SHR',
		29: 'SAR',
		32: 'KECCAK256',
		48: 'ADDRESS',
		49: 'BALANCE',
		50: 'ORIGIN',
		51: 'CALLER',
		52: 'CALLVALUE',
		53: 'CALLDATALOAD',
		54: 'CALLDATASIZE',
		55: 'CALLDATACOPY',
		56: 'CODESIZE',
		57: 'CODECOPY',
		58: 'GASPRICE',
		59: 'EXTCODESIZE',
		60: 'EXTCODECOPY',
		61: 'RETURNDATASIZE',
		62: 'RETURNDATACOPY',
		63: 'EXTCODEHASH',
		64: 'BLOCKHASH',
		65: 'COINBASE',
		66: 'TIMESTAMP',
		67: 'NUMBER',
		68: 'PREVRANDAO',
		69: 'GASLIMIT',
		70: 'CHAINID',
		71: 'SELFBALANCE',
		72: 'BASEFEE',
		80: 'POP',
		81: 'MLOAD',
		82: 'MSTORE',
		83: 'MSTORE8',
		84: 'SLOAD',
		85: 'SSTORE',
		86: 'JUMP',
		87: 'JUMPI',
		88: 'PC',
		89: 'MSIZE',
		90: 'GAS',
		91: 'JUMPDEST',
		95: 'PUSH0',
		96: 'PUSH1',
		97: 'PUSH2',
		98: 'PUSH3',
		99: 'PUSH4',
		100: 'PUSH5',
		101: 'PUSH6',
		102: 'PUSH7',
		103: 'PUSH8',
		104: 'PUSH9',
		105: 'PUSH10',
		106: 'PUSH11',
		107: 'PUSH12',
		108: 'PUSH13',
		109: 'PUSH14',
		110: 'PUSH15',
		111: 'PUSH16',
		112: 'PUSH17',
		113: 'PUSH18',
		114: 'PUSH19',
		115: 'PUSH20',
		116: 'PUSH21',
		117: 'PUSH22',
		118: 'PUSH23',
		119: 'PUSH24',
		120: 'PUSH25',
		121: 'PUSH26',
		122: 'PUSH27',
		123: 'PUSH28',
		124: 'PUSH29',
		125: 'PUSH30',
		126: 'PUSH31',
		127: 'PUSH32',
		128: 'DUP1',
		129: 'DUP2',
		130: 'DUP3',
		131: 'DUP4',
		132: 'DUP5',
		133: 'DUP6',
		134: 'DUP7',
		135: 'DUP8',
		136: 'DUP9',
		137: 'DUP10',
		138: 'DUP11',
		139: 'DUP12',
		140: 'DUP13',
		141: 'DUP14',
		142: 'DUP15',
		143: 'DUP16',
		144: 'SWAP1',
		145: 'SWAP2',
		146: 'SWAP3',
		147: 'SWAP4',
		148: 'SWAP5',
		149: 'SWAP6',
		150: 'SWAP7',
		151: 'SWAP8',
		152: 'SWAP9',
		153: 'SWAP10',
		154: 'SWAP11',
		155: 'SWAP12',
		156: 'SWAP13',
		157: 'SWAP14',
		158: 'SWAP15',
		159: 'SWAP16',
		160: 'LOG0',
		161: 'LOG1',
		162: 'LOG2',
		163: 'LOG3',
		164: 'LOG4',
		240: 'CREATE',
		241: 'CALL',
		242: 'CALLCODE',
		243: 'RETURN',
		244: 'DELEGATECALL',
		245: 'CREATE2',
		250: 'STATICCALL',
		253: 'REVERT',
		254: 'INVALID',
		255: 'SELFDESTRUCT',
	}

	return opcodes[opcode] || 'UNKNOWN'
}
