export interface BlockJson {
	beginIndex: number
	gasCost: number
	stackReq: number
	stackMaxGrowth: number
	pcs: number[]
	opcodes: string[]
	hex: string[]
	data: string[]
}

export interface EvmState {
	gasLeft: number
	depth: number
	stack: string[]
	memory: string
	storage: Array<{ key: string; value: string }>
	logs: string[]
	returnData: string
	completed: boolean
	currentInstructionIndex: number
	currentBlockStartIndex: number
	blocks: BlockJson[]
}

export interface SampleContract {
	name: string
	description: string
	bytecode: string
}

export const sampleContracts: SampleContract[] = [
	{
		name: 'Basic Arithmetic',
		description: 'Simple arithmetic: PUSH1 5, PUSH1 10, ADD, PUSH1 3, MUL (Result: 45)',
		bytecode: '0x6005600a01600302',
	},
	{
		name: 'Memory Operations',
		description: 'Memory store/load: Store 0xdeadbeef at offset 0x00, then load it back',
		bytecode: '0x63deadbeef6000526000516000556000546001600055600154',
	},
	{
		name: 'Storage Operations',
		description: 'Storage read/write: Store values in slots 0 and 1, then read them',
		bytecode: '0x600a600055601e600155600054600154600255600254',
	},
	{
		name: 'PUSH Variations',
		description: 'Different PUSH sizes: PUSH1(0xff), PUSH2(0xffff), PUSH3(0xffffff), PUSH4(0xffffffff)',
		bytecode: '0x60ff61ffff62ffffff63ffffffff',
	},
	{
		name: 'Stack Operations',
		description: 'DUP, SWAP operations: Build stack, duplicate, swap elements',
		bytecode: '0x600160026003808081905090',
	},
	{
		name: 'Comparison & Logic',
		description: 'Comparison ops: LT, GT, EQ, ISZERO, AND, OR, XOR, NOT',
		bytecode: '0x600560031060ff600016600a600514601560001915600019',
	},
	{
		name: 'Hash Operations',
		description: 'KECCAK256: Hash "Hello" stored in memory',
		bytecode: '0x7f48656c6c6f000000000000000000000000000000000000000000000000000000600052600560002060005260206000f3',
	},
	{
		name: 'Comprehensive Test',
		description: 'Full EVM showcase: arithmetic, memory, storage, events, returns, comparisons, jumps',
		bytecode:
			'0x6005600a01806000526003600202600155600154600302600455604260005260206000a06008600a166009600b176001600055600054600c602014610093576020600052602060006001a15b602060005260206000f3',
	},
	{
		name: 'Jump and Control Flow',
		description: 'JUMP, JUMPI, PC: Conditional and unconditional jumps with PC checks',
		bytecode: '0x600a565b6001600101600a14610012575b00',
	},
	{
		name: 'Memory Expansion',
		description: 'Test memory expansion costs: Write to increasing offsets',
		bytecode:
			'0x6001600052600160205260016040526001606052600160805260ff60a05260ff60c05260ff60e05260ff6101005260ff610120525960005960205960405960605960805960a05960c05960e05961010059610120595050505050505050',
	},
	{
		name: 'Bitwise Operations',
		description: 'AND, OR, XOR, NOT, SHL, SHR, SAR: Full bitwise operation suite',
		bytecode: '0x60ff60aa166055601760aa60ff18196003601b6003601c600360041d',
	},
	{
		name: 'Address and Balance',
		description: 'ADDRESS, BALANCE, CALLER, ORIGIN: Get contract and account info',
		bytecode: '0x3033313234',
	},
	{
		name: 'Block Information',
		description: 'TIMESTAMP, NUMBER, COINBASE, GASLIMIT, CHAINID: Get block info',
		bytecode: '0x4243414546',
	},
	{
		name: 'Modular Arithmetic',
		description: 'ADDMOD, MULMOD: (5 + 10) % 7 = 1, (5 * 10) % 7 = 1',
		bytecode: '0x6005600a600708600560096007085050',
	},
	{
		name: 'Return and Revert',
		description: 'Store data in memory and RETURN it',
		bytecode: '0x7f48656c6c6f20576f726c642100000000000000000000000000000000000000006000526020600052600c6014f3',
	},
	{
		name: 'Event Emission',
		description: 'LOG1 with topic: Emit event with data and one topic',
		bytecode:
			'0x7f48656c6c6f20576f726c642100000000000000000000000000000000000000006000527faaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa6020600052600c6014a1',
	},
	{
		name: 'Advanced Storage Pattern',
		description: 'Mapping simulation: Store at computed slots like mapping[key] = value',
		bytecode:
			'0x60016000526000602052604060002060019055600260005260016020526040600020600190556001600052600060205260406000205460026000526001602052604060002054505000',
	},
	{
		name: 'Error Handling',
		description: 'Division by zero and other error cases',
		bytecode: '0x6001600004600060020460016000065050',
	},
]

export const formatHex = (hex: string): string => {
	if (!hex.startsWith('0x')) return hex
	return hex.length > 10 ? `${hex.slice(0, 6)}...${hex.slice(-4)}` : hex
}

export const formatMemory = (memory: string): string[] => {
	if (memory === '0x' || memory.length <= 2) return []

	// Remove 0x prefix
	const hex = memory.slice(2)

	// Group by 32 bytes (64 chars) for readability
	const chunks: string[] = []
	for (let i = 0; i < hex.length; i += 64) {
		chunks.push(hex.slice(i, i + 64))
	}

	return chunks
}
