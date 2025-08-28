import { createEffect, createSignal, onCleanup, onMount } from 'solid-js'
import { createStore } from 'solid-js/store'
import EvmDebugger from '~/components/evm-debugger/EvmDebugger'
import { Toaster } from '~/components/ui/sonner'
import { type EvmState, sampleContracts } from '~/lib/types'
import { blockEvm, loadBytecode, resetEvm, runEvm, stepEvm } from '~/lib/utils'

declare global {
	interface Window {
		hello_world: (name: string) => Promise<string>
		load_bytecode: (bytecode: string) => Promise<string>
		reset_evm: () => Promise<string>
		step_evm: () => Promise<string>
		get_evm_state: () => Promise<string>
		run_evm: () => Promise<string>
		block_evm: () => Promise<string>
		add_breakpoint: (pc: number | string) => Promise<string>
		remove_breakpoint: (pc: number | string) => Promise<string>
		get_breakpoints: () => Promise<string>
		get_available_breakpoints: () => Promise<string>
		clear_breakpoints: () => Promise<string>
		on_web_ui_ready: () => void
	}
}

function App() {
	const [isDarkMode, setIsDarkMode] = createSignal(false)
	const [isRunning, setIsRunning] = createSignal(false)
	const [state, setState] = createStore<EvmState>({
		gasLeft: 0,
		depth: 0,
		stack: [],
		memory: '0x',
		bytecode: '0x',
		logs: [],
		returnData: '0x',
		completed: false,
		currentInstructionIndex: 0,
		pc: 0,
		steps: [],
		state: {
			pre: [],
			post: [],
		},
		preanalyzedBlocks: [],
		currentPreanalyzedBlockStartIndex: 0,
	})

	const handleRun = async () => {
		try {
			setIsRunning(true)
			const newState = await runEvm()
			setIsRunning(false)
			setState(newState)
		} catch (err) {
			console.error('Run error:', err)
			setIsRunning(false)
		}
	}

	const handleBlock = async () => {
		try {
			const newState = await blockEvm()
			setState(newState)
		} catch (err) {
			console.error('Block error:', err)
		}
	}

	const handleStep = async () => {
		try {
			const newState = await stepEvm()
			setState(newState)
		} catch (err) {
			console.error('Step error:', err)
		}
	}

	const handleReset = async () => {
		try {
			setIsRunning(false)
			const newState = await resetEvm()
			setState(newState)
		} catch (err) {
			console.error('Reset error:', err)
		}
	}

	onMount(async () => {
		// Wait for WebUI connection event
		window.on_web_ui_ready = async () => {
			try {
				const initialState = await loadBytecode(sampleContracts[7].bytecode)
				setState(initialState)
			} catch (err) {
				console.error('Initial load error:', err)
			}
		}

		const handleKeyDown = (event: KeyboardEvent) => {
			switch (event.code) {
				case 'Space':
					event.preventDefault()
					handleRun()
					break
				case 'KeyR':
					event.preventDefault()
					handleReset()
					break
				case 'KeyS':
					event.preventDefault()
					handleStep()
					break
				case 'KeyB':
					event.preventDefault()
					handleBlock()
					break
			}
		}
		window.addEventListener('keydown', handleKeyDown)

		const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)')
		setIsDarkMode(mediaQuery.matches)
		const listener = (event: MediaQueryListEvent) => {
			setIsDarkMode(event.matches)
		}
		mediaQuery.addEventListener('change', listener)
		onCleanup(() => {
			window.removeEventListener('keydown', handleKeyDown)
			mediaQuery.removeEventListener('change', listener)
		})
	})

	createEffect(() => {
		if (isDarkMode()) {
			document.documentElement.classList.add('dark')
		} else {
			document.documentElement.classList.remove('dark')
		}
	})

	return (
		<>
			<EvmDebugger
				isDarkMode={isDarkMode}
				setIsDarkMode={setIsDarkMode}
				isRunning={isRunning}
				setIsRunning={setIsRunning}
				state={state}
				setState={setState}
				handleRun={handleRun}
				handleBlock={handleBlock}
				handleStep={handleStep}
				handleReset={handleReset}
			/>
			<Toaster />
		</>
	)
}

export default App
