import { isMobile } from '@solid-primitives/platform'
import GaugeIcon from 'lucide-solid/icons/gauge'
import PauseIcon from 'lucide-solid/icons/pause'
import PlayIcon from 'lucide-solid/icons/play'
import RotateCcwIcon from 'lucide-solid/icons/rotate-ccw'
import StepForwardIcon from 'lucide-solid/icons/step-forward'
import { type Component, type Setter, Show } from 'solid-js'
import { Badge } from '~/components/ui/badge'
import { Button } from '~/components/ui/button'
import type { EvmState } from '~/lib/types'

interface ControlsProps {
	isRunning: boolean
	setIsRunning: Setter<boolean>
	setError: Setter<string>
	setState: Setter<EvmState>
	isUpdating: boolean
	setIsUpdating: Setter<boolean>
	executionSpeed: number
	setExecutionSpeed: Setter<number>
	handleRunPause: () => void
	handleStep: () => void
	handleReset: () => void
	bytecode: string
	isExecutionComplete: boolean
}

const Controls: Component<ControlsProps> = (props) => {
	const onReset = () => props.handleReset()
	const onStep = () => props.handleStep()
	const onRunPause = () => props.handleRunPause()

	return (
		<div class="sticky top-18 z-50 flex w-full justify-center px-4">
			<div class="grid grid-cols-2 xs:grid-cols-4 gap-x-4 gap-y-2 rounded-sm border border-border/30 bg-amber-50/50 p-2 backdrop-blur-md dark:bg-amber-950/30">
				<Button
					variant="outline"
					size="sm"
					onClick={onReset}
					disabled={!props.bytecode}
					aria-label="Reset EVM (R)"
					class="flex items-center gap-2"
				>
					<RotateCcwIcon class="h-4 w-4" />
					Reset
					{!isMobile && (
						<Badge variant="outline" class="px-1.5 py-0.5 font-mono font-normal text-muted-foreground text-xs">
							R
						</Badge>
					)}
				</Button>
				<Button
					variant="outline"
					size="sm"
					onClick={onStep}
					disabled={props.isRunning || !props.bytecode || props.isExecutionComplete}
					aria-label="Step EVM (S)"
					class="flex items-center gap-2"
				>
					<StepForwardIcon class="h-4 w-4" />
					Step
					{!isMobile && (
						<Badge variant="outline" class="px-1.5 py-0.5 font-mono font-normal text-muted-foreground text-xs">
							S
						</Badge>
					)}
				</Button>
				<Button
					variant={props.isRunning ? 'secondary' : 'outline'}
					size="sm"
					onClick={onRunPause}
					disabled={!props.bytecode}
					aria-label={props.isRunning ? 'Pause EVM (Space)' : 'Run EVM (Space)'}
					class="flex items-center gap-2"
				>
					<Show when={props.isRunning} fallback={<PlayIcon class="h-4 w-4" />}>
						<PauseIcon class="h-4 w-4" />
					</Show>
					{props.isRunning ? 'Pause' : 'Run'}
					{!isMobile && (
						<Badge variant="outline" class="px-1.5 py-0.5 font-mono font-normal text-muted-foreground text-xs">
							Space
						</Badge>
					)}
				</Button>
				<Button
					variant="outline"
					size="sm"
					disabled={!props.isRunning || !props.bytecode}
					onClick={onRunPause}
					aria-label="Speed"
					class="flex items-center gap-2"
				>
					<GaugeIcon class="h-4 w-4" />
					Speed
				</Button>
			</div>
		</div>
	)
}

export default Controls
