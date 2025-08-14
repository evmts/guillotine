import { createEffect, createSignal, onCleanup, onMount } from 'solid-js'
import { createStore } from 'solid-js/store'
import EvmDebugger from '~/components/evm-debugger/EvmDebugger'
import { Toaster } from '~/components/ui/sonner'
import { type EvmState, sampleContracts } from '~/lib/types'
import { loadBytecode, resetEvm, stepEvm } from '~/lib/utils'

declare global {
	interface Window {
		hello_world: (name: string) => Promise<string>
		load_bytecode: (bytecode: string) => Promise<string>
		reset_evm: () => Promise<string>
		step_evm: () => Promise<string>
		get_evm_state: () => Promise<string>
		handleRunPause: () => void
		handleStep: () => void
		handleReset: () => void
		on_web_ui_ready: () => void
	}
}

function App() {
	const [isDarkMode, setIsDarkMode] = createSignal(false)
	const [isRunning, setIsRunning] = createSignal(false)
	const [error, setError] = createSignal<string>('')
	const [bytecode, setBytecode] = createSignal(sampleContracts[7].bytecode)
	const [state, setState] = createStore<EvmState>({
		gasLeft: 0,
		depth: 0,
		stack: [],
		memory: '0x',
		storage: [],
		logs: [],
		returnData: '0x',
		completed: false,
		currentInstructionIndex: 0,
		currentBlockStartIndex: 0,
		blocks: [],
	})

	const handleRunPause = () => {
		setIsRunning(!isRunning())
	}

	const handleStep = async () => {
		try {
			setError('')
			const newState = await stepEvm()
			setState(newState)
		} catch (err) {
			setError(`${err}`)
		}
	}

	const handleReset = async () => {
		try {
			setError('')
			setIsRunning(false)
			const newState = await resetEvm()
			setState(newState)
		} catch (err) {
			setError(`${err}`)
		}
	}

	onMount(async () => {
		window.handleRunPause = handleRunPause
		window.handleStep = handleStep
		window.handleReset = handleReset

		// Wait for WebUI connection event
		window.on_web_ui_ready = async () => {
			try {
				await loadBytecode(bytecode())
				const initialState = await resetEvm()
				setState(initialState)
			} catch (err) {
				setError(err instanceof Error ? err.message : 'Unknown error')
			}
		}

		const handleKeyDown = (event: KeyboardEvent) => {
			if (event.code === 'Space') {
				event.preventDefault()
				handleRunPause()
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
		if (isRunning() && bytecode()) {
			const intervalId = setInterval(async () => {
				try {
					const newState = await stepEvm()
					if (newState.completed) {
						setIsRunning(false)
					}
					setState(newState)
				} catch (err) {
					setError(`${err}`)
					setIsRunning(false)
				}
			}, 200)
			onCleanup(() => {
				clearInterval(intervalId)
			})
		}
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
				error={error}
				setError={setError}
				state={state}
				setState={setState}
				bytecode={bytecode}
				setBytecode={setBytecode}
				handleRunPause={handleRunPause}
				handleStep={handleStep}
				handleReset={handleReset}
			/>
			<Toaster />
		</>
	)
}

export default App
