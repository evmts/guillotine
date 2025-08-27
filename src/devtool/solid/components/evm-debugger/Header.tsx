import MoonIcon from 'lucide-solid/icons/moon'
import SettingsIcon from 'lucide-solid/icons/settings'
import SunIcon from 'lucide-solid/icons/sun'
import { type Accessor, type Component, type Setter, Show } from 'solid-js'
import { Button } from '~/components/ui/button'
import { ToggleButton } from '~/components/ui/toggle'

interface HeaderProps {
	isDarkMode: Accessor<boolean>
	setIsDarkMode: Setter<boolean>
	activePanel: string
	setActivePanel: Setter<string>
}

const Header: Component<HeaderProps> = (props) => {
	return (
		<header class="sticky top-2 z-20 mx-auto w-min">
			<div class="flex items-center justify-between gap-8 rounded-sm border border-border/30 bg-amber-50/50 px-4 py-2 backdrop-blur-md dark:bg-amber-950/30">
				<div class="flex items-center gap-12">
					<div class="flex items-center gap-3">
						<div class="flex h-7 w-7 items-center justify-center rounded-sm bg-gradient-to-br from-amber-200 to-amber-600 text-white shadow-md">
							<svg
								xmlns="http://www.w3.org/2000/svg"
								class="h-4 w-4"
								viewBox="0 0 24 24"
								fill="none"
								stroke="currentColor"
								stroke-width="2"
								stroke-linecap="round"
								stroke-linejoin="round"
								aria-label="EVM Debugger icon"
							>
								<title>EVM Debugger icon</title>
								<path d="M20 16V7a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v9m16 0H4m16 0 1.28 2.55a1 1 0 0 1-.9 1.45H3.62a1 1 0 0 1-.9-1.45L4 16" />
								<path d="M8 7h.01M12 7h.01M16 7h.01" />
							</svg>
						</div>
						<h1 class="whitespace-nowrap font-medium tracking-wide">svvy</h1>
					</div>

					<div class="hidden gap-1 md:flex">
						<ToggleButton
							pressed={props.activePanel === 'all'}
							onChange={() => props.setActivePanel('all')}
							size="sm"
							class="whitespace-nowrap hover:bg-amber-100 data-[pressed]:bg-amber-100 dark:data-[pressed]:bg-amber-950 dark:hover:bg-amber-950"
						>
							All panels
						</ToggleButton>
						<ToggleButton
							pressed={props.activePanel === 'execution'}
							onChange={() => props.setActivePanel('execution')}
							size="sm"
							class="whitespace-nowrap hover:bg-amber-100 data-[pressed]:bg-amber-100 dark:data-[pressed]:bg-amber-950 dark:hover:bg-amber-950"
						>
							Execution
						</ToggleButton>
						<ToggleButton
							pressed={props.activePanel === 'stack'}
							onChange={() => props.setActivePanel('stack')}
							size="sm"
							class="whitespace-nowrap hover:bg-amber-100 data-[pressed]:bg-amber-100 dark:data-[pressed]:bg-amber-950 dark:hover:bg-amber-950"
						>
							Stack
						</ToggleButton>
						<ToggleButton
							pressed={props.activePanel === 'memory'}
							onChange={() => props.setActivePanel('memory')}
							size="sm"
							class="whitespace-nowrap hover:bg-amber-100 data-[pressed]:bg-amber-100 dark:data-[pressed]:bg-amber-950 dark:hover:bg-amber-950"
						>
							Memory
						</ToggleButton>
						<ToggleButton
							pressed={props.activePanel === 'state'}
							onChange={() => props.setActivePanel('state')}
							size="sm"
							class="whitespace-nowrap hover:bg-amber-100 data-[pressed]:bg-amber-100 dark:data-[pressed]:bg-amber-950 dark:hover:bg-amber-950"
						>
							State
						</ToggleButton>
						<ToggleButton
							pressed={props.activePanel === 'logs'}
							onChange={() => props.setActivePanel('logs')}
							size="sm"
							class="whitespace-nowrap hover:bg-amber-100 data-[pressed]:bg-amber-100 dark:data-[pressed]:bg-amber-950 dark:hover:bg-amber-950"
						>
							Logs
						</ToggleButton>
						<ToggleButton
							pressed={props.activePanel === 'gas'}
							onChange={() => props.setActivePanel('gas')}
							size="sm"
							class="whitespace-nowrap hover:bg-amber-100 data-[pressed]:bg-amber-100 dark:data-[pressed]:bg-amber-950 dark:hover:bg-amber-950"
						>
							Gas
						</ToggleButton>
					</div>
				</div>
				<div class="flex items-center gap-3 border-border/50 border-l pl-4">
					<Button
						variant="ghost"
						size="icon"
						onClick={() => props.setIsDarkMode(!props.isDarkMode())}
						aria-label="Toggle dark mode"
					>
						<Show when={props.isDarkMode} fallback={<MoonIcon class="h-4 w-4" />}>
							<SunIcon class="h-4 w-4" />
						</Show>
					</Button>
					<Button variant="ghost" size="icon">
						<SettingsIcon class="h-4 w-4" />
					</Button>
				</div>
			</div>
		</header>
	)
}

export default Header
