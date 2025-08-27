import { isMobile } from '@solid-primitives/platform'
import CopyIcon from 'lucide-solid/icons/copy'
import RectangleEllipsisIcon from 'lucide-solid/icons/rectangle-ellipsis'
import { type Component, For, Show } from 'solid-js'
import { toast } from 'solid-sonner'
import Code from '~/components/Code'
import InfoTooltip from '~/components/InfoTooltip'
import { Button } from '~/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '~/components/ui/card'
import { cn } from '~/lib/cn'
import { type EvmState, formatHex } from '~/lib/types'
import { copyToClipboard } from '~/lib/utils'

interface StackProps {
	state: EvmState
}

const Stack: Component<StackProps> = ({ state }) => {
	// Create a reversed copy without mutating the original
	const stack = [...state.stack].reverse()

	const handleCopy = (item: string, index: number) => {
		copyToClipboard(item)
		toast.info(`Copied item at index ${stack.length - 1 - index} to clipboard`)
	}

	return (
		<Card class="overflow-hidden">
			<CardHeader class="border-b p-3">
				<div class="flex items-center justify-between">
					<CardTitle class="text-sm">Stack ({stack.length})</CardTitle>
					<InfoTooltip>Top of stack at bottom</InfoTooltip>
				</div>
			</CardHeader>
			<CardContent class="max-h-[300px] overflow-y-auto p-0">
				<Show
					when={stack.length > 0}
					fallback={
						<div class="flex items-center justify-center gap-2 p-8 text-muted-foreground text-sm italic">
							<RectangleEllipsisIcon class="h-5 w-5" />
							Stack is empty
						</div>
					}
				>
					<div class="divide-y">
						<For each={stack}>
							{(item, index) => (
								<div class="group flex justify-between px-4 py-1.5 transition-colors hover:bg-muted/50">
									<div class="flex items-center">
										<span class="w-16 font-medium text-muted-foreground text-xs">{stack.length - 1 - index()}:</span>
										<Code class="break-all text-sm">{isMobile ? formatHex(item) : item}</Code>
									</div>
									<Button
										variant="ghost"
										size="icon"
										onClick={() => handleCopy(item, index())}
										class={cn('h-7 w-7', !isMobile && 'opacity-0 transition-opacity group-hover:opacity-100')}
										aria-label="Copy to clipboard"
									>
										<CopyIcon class="h-4 w-4" />
									</Button>
								</div>
							)}
						</For>
					</div>
				</Show>
			</CardContent>
		</Card>
	)
}

export default Stack
