import { type Accessor, createEffect, createSignal, type Setter, Show } from 'solid-js'
import Breakpoints from '~/components/evm-debugger/Breakpoints'
import BytecodeBlocksMap from '~/components/evm-debugger/BytecodeBlocksMap'
import BytecodeLoader from '~/components/evm-debugger/BytecodeLoader'
import Controls from '~/components/evm-debugger/Controls'
import ErrorAlert from '~/components/evm-debugger/ErrorAlert'
import ExecutionStepsView from '~/components/evm-debugger/ExecutionStepsView'
import GasUsage from '~/components/evm-debugger/GasUsage'
import Header from '~/components/evm-debugger/Header'
import LogsAndReturn from '~/components/evm-debugger/LogsAndReturn'
import Memory from '~/components/evm-debugger/Memory'
import Stack from '~/components/evm-debugger/Stack'
import StateDiff from '~/components/evm-debugger/StateDiff'
import StateSummary from '~/components/evm-debugger/StateSummary'
import type { EvmState } from '~/lib/types'
import { addBreakpoint, getBreakpoints, removeBreakpoint } from '~/lib/utils'

interface EvmDebuggerProps {
	isDarkMode: Accessor<boolean>
	setIsDarkMode: Setter<boolean>
	isRunning: Accessor<boolean>
	setIsRunning: Setter<boolean>
	state: EvmState
	setState: Setter<EvmState>
	handleRun: () => void
	handleBlock: () => void
	handleStep: () => void
	handleReset: () => void
}

const EvmDebugger = (props: EvmDebuggerProps) => {
	const [activePanel, setActivePanel] = createSignal('all')
	const [breakpoints, setBreakpoints] = createSignal<number[]>([])

	const refreshBreakpoints = async () => {
		try {
			setBreakpoints(await getBreakpoints())
		} catch {
			setBreakpoints([])
		}
	}

	// Keep breakpoints refreshed on first load and when instruction advances
	createEffect(() => {
		void props.state.currentInstructionIndex
		void props.state.pc
		void refreshBreakpoints()
	})

	const togglePcBreakpoint = async (pc: number) => {
		if (breakpoints().includes(pc)) {
			await removeBreakpoint(pc)
		} else {
			await addBreakpoint(pc)
		}
		await refreshBreakpoints()
	}

	return (
		<div class="min-h-screen bg-background text-foreground">
			<Header
				isDarkMode={props.isDarkMode}
				setIsDarkMode={props.setIsDarkMode}
				activePanel={activePanel()}
				setActivePanel={setActivePanel}
			/>
			<Controls
				setState={props.setState as Setter<EvmState>}
				handleRun={props.handleRun}
				handleBlock={props.handleBlock}
				handleStep={props.handleStep}
				handleReset={props.handleReset}
				bytecode={props.state.bytecode}
				isExecutionComplete={props.state.completed}
				error={props.state.error}
			/>
			<BytecodeLoader loadedBytecode={props.state.bytecode} setState={props.setState as Setter<EvmState>} />
			<div class="mx-auto flex max-w-7xl flex-col gap-6 px-3 pb-6 sm:px-6">
				<ErrorAlert state={props.state} />
				<StateSummary state={props.state as EvmState} isUpdating={props.isRunning()} />
				<Breakpoints
					bytecode={props.state.bytecode}
					state={props.state as EvmState}
					breakpoints={breakpoints()}
					refreshBreakpoints={refreshBreakpoints}
					togglePcBreakpoint={togglePcBreakpoint}
				/>
				<Show when={activePanel() === 'all' || activePanel() === 'execution'}>
					<BytecodeBlocksMap
						codeHex={props.state.bytecode}
						blocks={props.state.preanalyzedBlocks}
						currentBlockStartIndex={props.state.currentPreanalyzedBlockStartIndex}
					/>
					<ExecutionStepsView
						preanalyzedBlocks={props.state.preanalyzedBlocks}
						currentPreanalyzedBlockStartIndex={props.state.currentPreanalyzedBlockStartIndex}
						currentInstructionIndex={props.state.currentInstructionIndex}
						rawBytecode={props.state.bytecode}
						breakpoints={breakpoints()}
						togglePcBreakpoint={togglePcBreakpoint}
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
					<Show when={activePanel() === 'all' || activePanel() === 'state'}>
						<StateDiff state={props.state as EvmState} />
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
