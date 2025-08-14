import { type Accessor, createSignal, type Setter, Show } from 'solid-js'
import BytecodeLoader from '~/components/evm-debugger/BytecodeLoader'
import Controls from '~/components/evm-debugger/Controls'
import ErrorAlert from '~/components/evm-debugger/ErrorAlert'
import ExecutionStepsView from '~/components/evm-debugger/ExecutionStepsView'
import GasUsage from '~/components/evm-debugger/GasUsage'
import Header from '~/components/evm-debugger/Header'
import LogsAndReturn from '~/components/evm-debugger/LogsAndReturn'
import Memory from '~/components/evm-debugger/Memory'
import Stack from '~/components/evm-debugger/Stack'
import StateSummary from '~/components/evm-debugger/StateSummary'
import Storage from '~/components/evm-debugger/Storage'
import type { EvmState } from '~/lib/types'

interface EvmDebuggerProps {
	isDarkMode: Accessor<boolean>
	setIsDarkMode: Setter<boolean>
	isRunning: Accessor<boolean>
	setIsRunning: Setter<boolean>
	error: Accessor<string>
	setError: Setter<string>
	state: EvmState
	setState: Setter<EvmState>
	bytecode: Accessor<string>
	setBytecode: Setter<string>
	handleRunPause: () => void
	handleStep: () => void
	handleReset: () => void
}

const EvmDebugger = (props: EvmDebuggerProps) => {
	const [isUpdating, setIsUpdating] = createSignal(false)
	const [activePanel, setActivePanel] = createSignal('all')
	const [executionSpeed, setExecutionSpeed] = createSignal(100)

	return (
		<div class="min-h-screen bg-background text-foreground">
			<Header
				isDarkMode={props.isDarkMode}
				setIsDarkMode={props.setIsDarkMode}
				activePanel={activePanel()}
				setActivePanel={setActivePanel}
			/>
			<Controls
				isRunning={props.isRunning()}
				setIsRunning={props.setIsRunning}
				setError={props.setError}
				setState={props.setState as Setter<EvmState>}
				isUpdating={isUpdating()}
				setIsUpdating={setIsUpdating}
				executionSpeed={executionSpeed()}
				setExecutionSpeed={setExecutionSpeed}
				handleRunPause={props.handleRunPause}
				handleStep={props.handleStep}
				handleReset={props.handleReset}
				bytecode={props.bytecode()}
			/>
			<BytecodeLoader
				bytecode={props.bytecode()}
				setBytecode={props.setBytecode}
				setError={props.setError}
				setIsRunning={props.setIsRunning}
				setState={props.setState as Setter<EvmState>}
			/>
			<div class="mx-auto flex max-w-7xl flex-col gap-6 px-3 pb-6 sm:px-6">
				<ErrorAlert error={props.error()} setError={props.setError} />
				<StateSummary state={props.state as EvmState} isUpdating={isUpdating()} />
				<Show when={activePanel() === 'all' || activePanel() === 'bytecode'}>
					<ExecutionStepsView
						blocks={props.state.blocks}
						currentBlockStartIndex={props.state.currentBlockStartIndex}
						currentInstructionIndex={props.state.currentInstructionIndex}
						rawBytecode={props.bytecode()}
					/>
				</Show>

				<Show when={activePanel() === 'all' || activePanel() === 'gas'}>
					<GasUsage state={props.state as EvmState} />
				</Show>
				<div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
					<Show when={activePanel() === 'all' || activePanel() === 'stack'}>
						<Stack state={props.state as EvmState} />
					</Show>
					<Show when={activePanel() === 'all' || activePanel() === 'memory'}>
						<Memory state={props.state as EvmState} />
					</Show>
					<Show when={activePanel() === 'all' || activePanel() === 'storage'}>
						<Storage state={props.state as EvmState} />
					</Show>
					<Show when={activePanel() === 'all' || activePanel() === 'logs'}>
						<LogsAndReturn state={props.state as EvmState} />
					</Show>
				</div>
			</div>
		</div>
	)
}

export default EvmDebugger
