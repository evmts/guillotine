import { isMobile } from '@solid-primitives/platform'
import PlayIcon from 'lucide-solid/icons/play'
import RotateCcwIcon from 'lucide-solid/icons/rotate-ccw'
import SkipForwardIcon from 'lucide-solid/icons/skip-forward'
import StepForwardIcon from 'lucide-solid/icons/step-forward'
import { type Component, type Setter, Show } from 'solid-js'
import AlertTooltip from '~/components/AlertTooltip'
import { Badge } from '~/components/ui/badge'
import { Button } from '~/components/ui/button'
import type { ErrorInfo, EvmState } from '~/lib/types'

interface ControlsProps {
	setState: Setter<EvmState>
	handleRun: () => void
	handleBlock: () => void
	handleStep: () => void
	handleReset: () => void
	bytecode: string
	isExecutionComplete: boolean
	error?: ErrorInfo | null
}

const Controls: Component<ControlsProps> = (props) => {
	const onReset = () => props.handleReset()
	const onStep = () => props.handleStep()
	const onRun = () => props.handleRun()
	const onBlock = () => props.handleBlock()

	// Determine if controls should be disabled
	const shouldDisableControls = () => {
		if (!props.bytecode) return true
		if (props.isExecutionComplete) return true
		return false
	}

	const getErrorMessage = () => {
		if (!props.error) return ''

		switch (props.error.kind) {
			case 'ExecutionError':
				return `Execution error: ${props.error.message}`
			case 'Revert':
				return `Revert: ${props.error.message}`
			case 'BytecodeError':
				return `Bytecode error: ${props.error.message}`
			default:
				return props.error.message
		}
	}

	const getErrorButtonClass = () => {
		if (!props.error) return ''
		// Light red background tint for any error
		return 'bg-red-50 hover:bg-red-100 border-red-200 dark:bg-red-950/30 dark:hover:bg-red-950/50 dark:border-red-800/50'
	}

	return (
		<div class="sticky top-18 z-50 flex w-full justify-center px-4">
			<div class="flex items-center gap-3">
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
						disabled={shouldDisableControls()}
						aria-label="Step EVM (S)"
						class={`flex items-center gap-2 ${getErrorButtonClass()}`}
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
						variant="outline"
						size="sm"
						onClick={onBlock}
						disabled={shouldDisableControls()}
						aria-label="Run block (B)"
						class={`flex items-center gap-2 ${getErrorButtonClass()}`}
					>
						<SkipForwardIcon class="h-4 w-4" />
						Block
						{!isMobile && (
							<Badge variant="outline" class="px-1.5 py-0.5 font-mono font-normal text-muted-foreground text-xs">
								B
							</Badge>
						)}
					</Button>
					<Button
						variant={'outline'}
						size="sm"
						onClick={onRun}
						disabled={shouldDisableControls()}
						aria-label={'Run EVM (Space)'}
						class={`flex items-center gap-2 ${getErrorButtonClass()}`}
					>
						<PlayIcon class="h-4 w-4" />
						Run
						{!isMobile && (
							<Badge variant="outline" class="px-1.5 py-0.5 font-mono font-normal text-muted-foreground text-xs">
								Space
							</Badge>
						)}
					</Button>
				</div>
				<Show when={props.error}>
					<AlertTooltip>
						<span>{getErrorMessage()}</span>
					</AlertTooltip>
				</Show>
			</div>
		</div>
	)
}

export default Controls
