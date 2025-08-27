import { isMobile } from '@solid-primitives/platform'
import PlayIcon from 'lucide-solid/icons/play'
import RotateCcwIcon from 'lucide-solid/icons/rotate-ccw'
import SkipForwardIcon from 'lucide-solid/icons/skip-forward'
import StepForwardIcon from 'lucide-solid/icons/step-forward'
import type { Component, Setter } from 'solid-js'
import { Badge } from '~/components/ui/badge'
import { Button } from '~/components/ui/button'
import type { EvmState } from '~/lib/types'

interface ControlsProps {
	setError: Setter<string>
	setState: Setter<EvmState>
	handleRun: () => void
	handleBlock: () => void
	handleStep: () => void
	handleReset: () => void
	bytecode: string
	isExecutionComplete: boolean
}

const Controls: Component<ControlsProps> = (props) => {
	const onReset = () => props.handleReset()
	const onStep = () => props.handleStep()
	const onRun = () => props.handleRun()
	const onBlock = () => props.handleBlock()

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
					disabled={!props.bytecode || props.isExecutionComplete}
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
					variant="outline"
					size="sm"
					onClick={onBlock}
					disabled={!props.bytecode || props.isExecutionComplete}
					aria-label="Run block (B)"
					class="flex items-center gap-2"
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
					disabled={!props.bytecode || props.isExecutionComplete}
					aria-label={'Run EVM (Space)'}
					class="flex items-center gap-2"
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
		</div>
	)
}

export default Controls
