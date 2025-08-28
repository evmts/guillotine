import { isMobile } from '@solid-primitives/platform'
import CopyIcon from 'lucide-solid/icons/copy'
import MinusIcon from 'lucide-solid/icons/minus'
import PencilIcon from 'lucide-solid/icons/pencil'
import PlusIcon from 'lucide-solid/icons/plus'
import RectangleEllipsisIcon from 'lucide-solid/icons/rectangle-ellipsis'
import { type Component, createMemo, For, type JSX, Show } from 'solid-js'
import { toast } from 'solid-sonner'
import Code from '~/components/Code'
import InfoTooltip from '~/components/InfoTooltip'
import { Button } from '~/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '~/components/ui/card'
import { cn } from '~/lib/cn'
import { type EvmState, formatHex } from '~/lib/types'
import { copyToClipboard } from '~/lib/utils'

interface StateDiffProps {
	state: EvmState
}

interface AccountDiff {
	address: string
	status: 'read-only' | 'modified' | 'created' | 'deleted'
	balanceChanged: boolean
	balanceBefore?: string
	balanceAfter?: string
	nonceChanged: boolean
	nonceBefore?: number
	nonceAfter?: number
	codeChanged: boolean
	codeBefore?: string
	codeAfter?: string
	storageChanges: Array<{
		key: string
		status: 'read-only' | 'modified' | 'created' | 'deleted'
		valueBefore?: string
		valueAfter?: string
	}>
}

const hexToDecimal = (hex?: string): string => {
	if (!hex) return '0'
	try {
		const clean = hex.startsWith('0x') ? hex : `0x${hex}`
		return BigInt(clean).toString(10)
	} catch {
		return hex
	}
}

const StateDiff: Component<StateDiffProps> = ({ state }) => {
	const handleCopy = (value: string, label: string) => {
		copyToClipboard(value)
		toast.info(
			<>
				Copied {label} <Code>{formatHex(value)}</Code> to clipboard
			</>,
		)
	}

	const accountDiffs = createMemo(() => {
		const diffs: AccountDiff[] = []

		const preMap = new Map(state.state.pre.map((a) => [a.address, a]))
		const postMap = new Map(state.state.post.map((a) => [a.address, a]))
		const allAddresses = new Set([...preMap.keys(), ...postMap.keys()])

		for (const address of allAddresses) {
			const pre = preMap.get(address)
			const post = postMap.get(address)

			let status: AccountDiff['status'] = 'read-only'
			if (!pre && post) {
				status = 'created'
			} else if (pre && !post) {
				status = 'deleted'
			} else if (pre && post) {
				const balanceChanged = pre.balance !== post.balance
				const nonceChanged = pre.nonce !== post.nonce
				const codeChanged = pre.code !== post.code
				const storageChanged = JSON.stringify(pre.storage) !== JSON.stringify(post.storage)
				if (balanceChanged || nonceChanged || codeChanged || storageChanged) {
					status = 'modified'
				}
			}

			const diff: AccountDiff = {
				address,
				status,
				balanceChanged: pre?.balance !== post?.balance,
				balanceBefore: pre?.balance,
				balanceAfter: post?.balance,
				nonceChanged: pre?.nonce !== post?.nonce,
				nonceBefore: pre?.nonce,
				nonceAfter: post?.nonce,
				codeChanged: pre?.code !== post?.code,
				codeBefore: pre?.code,
				codeAfter: post?.code,
				storageChanges: [],
			}

			const preStorage = new Map((pre?.storage || []).map((s) => [s.key, s.value]))
			const postStorage = new Map((post?.storage || []).map((s) => [s.key, s.value]))
			const allKeys = new Set([...preStorage.keys(), ...postStorage.keys()])

			for (const key of allKeys) {
				const valueBefore = preStorage.get(key)
				const valueAfter = postStorage.get(key)

				let slotStatus: 'read-only' | 'modified' | 'created' | 'deleted' = 'read-only'
				if (!valueBefore && valueAfter) {
					slotStatus = 'created'
				} else if (valueBefore && !valueAfter) {
					slotStatus = 'deleted'
				} else if (valueBefore !== valueAfter) {
					slotStatus = 'modified'
				}

				if (slotStatus !== 'read-only') {
					diff.storageChanges.push({
						key,
						status: slotStatus,
						valueBefore,
						valueAfter,
					})
				}
			}

			diffs.push(diff)
		}

		// Drop unchanged accounts; sort interesting ones first
		return diffs
			.filter((d) => d.status !== 'read-only')
			.sort((a, b) => {
				const order = {
					modified: 0,
					created: 1,
					deleted: 2,
					'read-only': 3,
				} as const
				return order[a.status] - order[b.status]
			})
	})

	const getStatusIcon = (status: AccountDiff['status']) => {
		switch (status) {
			case 'modified':
				return <PencilIcon class="h-3 w-3 text-blue-500" />
			case 'created':
				return <PlusIcon class="h-3 w-3 text-green-500" />
			case 'deleted':
				return <MinusIcon class="h-3 w-3 text-red-500" />
		}
	}

	const getStatusLabel = (status: AccountDiff['status']) => {
		switch (status) {
			case 'modified':
				return 'Modified'
			case 'created':
				return 'Created'
			case 'deleted':
				return 'Deleted'
		}
	}

	return (
		<Card class="overflow-hidden">
			<CardHeader class="border-b p-3">
				<div class="flex items-center justify-between">
					<CardTitle class="text-sm">State Diff ({accountDiffs().length})</CardTitle>
					<InfoTooltip>
						<div class="space-y-1">
							<div class="flex items-center gap-2">
								<PencilIcon class="h-3 w-3 text-blue-500" />
								<span class="text-xs">Modified (diff left/right)</span>
							</div>
							<div class="flex items-center gap-2">
								<PlusIcon class="h-3 w-3 text-green-500" />
								<span class="text-xs">Created (right side only)</span>
							</div>
							<div class="flex items-center gap-2">
								<MinusIcon class="h-3 w-3 text-red-500" />
								<span class="text-xs">Deleted (left side only)</span>
							</div>
						</div>
					</InfoTooltip>
				</div>
			</CardHeader>
			<CardContent class="max-h-[540px] overflow-y-auto p-0">
				<Show
					when={accountDiffs().length > 0}
					fallback={
						<div class="flex items-center justify-center gap-2 p-8 text-muted-foreground text-sm italic">
							<RectangleEllipsisIcon class="h-5 w-5" />
							No state accessed
						</div>
					}
				>
					<div class="divide-y">
						<For each={accountDiffs()}>
							{(account) => {
								const preLine =
									'flex items-center rounded-xs px-2 min-h-6 bg-red-100/70 text-red-900 dark:bg-red-900/50 dark:text-red-100'
								const postLine =
									'flex items-center rounded-xs px-2 min-h-6 bg-green-100/70 text-green-900 dark:bg-green-900/50 dark:text-green-100'

								const showPre = account.status !== 'created'
								const showPost = account.status !== 'deleted'

								const showBalancePre =
									showPre &&
									(account.status === 'deleted'
										? account.balanceBefore !== undefined && account.balanceBefore !== '0x0'
										: account.balanceChanged)
								const showNoncePre =
									showPre &&
									(account.status === 'deleted'
										? account.nonceBefore !== undefined && account.nonceBefore !== 0
										: account.nonceChanged)
								const showCodePre =
									showPre &&
									(account.status === 'deleted'
										? account.codeBefore !== undefined && account.codeBefore !== '0x'
										: account.codeChanged)

								const showBalancePost =
									showPost &&
									(account.status === 'created'
										? account.balanceAfter !== undefined && account.balanceAfter !== '0x0'
										: account.balanceChanged)
								const showNoncePost =
									showPost &&
									(account.status === 'created'
										? account.nonceAfter !== undefined && account.nonceAfter !== 0
										: account.nonceChanged)
								const showCodePost =
									showPost &&
									(account.status === 'created'
										? account.codeAfter !== undefined && account.codeAfter !== '0x'
										: account.codeChanged)

								const storageKeys = account.storageChanges
									.map((c) => c.key)
									.filter((v, i, a) => a.indexOf(v) === i)
									.sort()

								type Row = { left?: JSX.Element; right?: JSX.Element }
								const blocks: Array<{ label: string; rows: Row[] }> = []

								// Balance
								if (showBalancePre || showBalancePost) {
									blocks.push({
										label: 'Balance',
										rows: [
											{
												left: showBalancePre ? (
													<div class={`${preLine} group/line`}>
														<div class="flex w-full items-center gap-2">
															<Code variant="outline" class="border-transparent text-inherit text-xs">
																{hexToDecimal(account.balanceBefore || '0x0')}
															</Code>
															<Button
																variant="ghost"
																size="icon"
																onClick={() =>
																	handleCopy(hexToDecimal(account.balanceBefore || '0x0'), 'balance (pre)')
																}
																class={cn(
																	'ml-auto h-5 w-5 rounded-sm hover:bg-white/40 hover:backdrop-blur-sm dark:hover:bg-neutral-900/40',
																	!isMobile && 'opacity-0 transition-opacity group-hover/line:opacity-100',
																)}
																aria-label="Copy balance pre"
															>
																<CopyIcon class="h-3 w-3" />
															</Button>
														</div>
													</div>
												) : undefined,
												right: showBalancePost ? (
													<div class={`${postLine} group/line`}>
														<div class="flex w-full items-center gap-2">
															<Code variant="outline" class="border-transparent text-inherit text-xs">
																{hexToDecimal(account.balanceAfter || '0x0')}
															</Code>
															<Button
																variant="ghost"
																size="icon"
																onClick={() =>
																	handleCopy(hexToDecimal(account.balanceAfter || '0x0'), 'balance (post)')
																}
																class={cn(
																	'ml-auto h-5 w-5 rounded-sm hover:bg-white/40 hover:backdrop-blur-sm dark:hover:bg-neutral-900/40',
																	!isMobile && 'opacity-0 transition-opacity group-hover/line:opacity-100',
																)}
																aria-label="Copy balance post"
															>
																<CopyIcon class="h-3 w-3" />
															</Button>
														</div>
													</div>
												) : undefined,
											},
										],
									})
								}

								// Nonce
								if (showNoncePre || showNoncePost) {
									blocks.push({
										label: 'Nonce',
										rows: [
											{
												left: showNoncePre ? (
													<div class={`${preLine} group/line`}>
														<div class="flex w-full items-center gap-2">
															<Code variant="outline" class="border-transparent text-inherit text-xs">
																{account.nonceBefore || 0}
															</Code>
															<Button
																variant="ghost"
																size="icon"
																onClick={() => handleCopy(String(account.nonceBefore ?? 0), 'nonce (pre)')}
																class={cn(
																	'ml-auto h-5 w-5 rounded-sm hover:bg-white/40 hover:backdrop-blur-sm dark:hover:bg-neutral-900/40',
																	!isMobile && 'opacity-0 transition-opacity group-hover/line:opacity-100',
																)}
																aria-label="Copy nonce pre"
															>
																<CopyIcon class="h-3 w-3" />
															</Button>
														</div>
													</div>
												) : undefined,
												right: showNoncePost ? (
													<div class={`${postLine} group/line`}>
														<div class="flex w-full items-center gap-2">
															<Code variant="outline" class="border-transparent text-inherit text-xs">
																{account.nonceAfter || 0}
															</Code>
															<Button
																variant="ghost"
																size="icon"
																onClick={() => handleCopy(String(account.nonceAfter ?? 0), 'nonce (post)')}
																class={cn(
																	'ml-auto h-5 w-5 rounded-sm hover:bg-white/40 hover:backdrop-blur-sm dark:hover:bg-neutral-900/40',
																	!isMobile && 'opacity-0 transition-opacity group-hover/line:opacity-100',
																)}
																aria-label="Copy nonce post"
															>
																<CopyIcon class="h-3 w-3" />
															</Button>
														</div>
													</div>
												) : undefined,
											},
										],
									})
								}

								// Code
								if (showCodePre || showCodePost) {
									blocks.push({
										label: 'Code',
										rows: [
											{
												left: showCodePre ? (
													<div class={`${preLine} group/line`}>
														<div class="flex w-full items-center gap-2">
															{account.codeBefore && account.codeBefore !== '0x' ? (
																<>
																	<Code variant="outline" class="border-transparent text-inherit text-xs">
																		{formatHex(account.codeBefore)}
																	</Code>
																	<Button
																		variant="ghost"
																		size="icon"
																		onClick={() => handleCopy(account.codeBefore || '0x', 'code (pre)')}
																		class={cn(
																			'ml-auto h-5 w-5 rounded-sm hover:bg-white/40 hover:backdrop-blur-sm dark:hover:bg-neutral-900/40',
																			!isMobile && 'opacity-0 transition-opacity group-hover/line:opacity-100',
																		)}
																		aria-label="Copy code pre"
																	>
																		<CopyIcon class="h-3 w-3" />
																	</Button>
																</>
															) : (
																<span class="text-muted-foreground">empty</span>
															)}
														</div>
													</div>
												) : undefined,
												right: showCodePost ? (
													<div class={`${postLine} group/line`}>
														<div class="flex w-full items-center gap-2">
															{account.codeAfter && account.codeAfter !== '0x' ? (
																<>
																	<Code variant="outline" class="border-transparent text-inherit text-xs">
																		{formatHex(account.codeAfter)}
																	</Code>
																	<Button
																		variant="ghost"
																		size="icon"
																		onClick={() => handleCopy(account.codeAfter || '0x', 'code (post)')}
																		class={cn(
																			'ml-auto h-5 w-5 rounded-sm hover:bg-white/40 hover:backdrop-blur-sm dark:hover:bg-neutral-900/40',
																			!isMobile && 'opacity-0 transition-opacity group-hover/line:opacity-100',
																		)}
																		aria-label="Copy code post"
																	>
																		<CopyIcon class="h-3 w-3" />
																	</Button>
																</>
															) : (
																<span class="text-muted-foreground">empty</span>
															)}
														</div>
													</div>
												) : undefined,
											},
										],
									})
								}

								// Storage (aligned by union of keys)
								const storageRows: Row[] = []
								for (const key of storageKeys) {
									const change = account.storageChanges.find((c) => c.key === key)
									if (!change) continue
									const leftVisible = showPre && (change.status === 'modified' || change.status === 'deleted')
									const rightVisible = showPost && (change.status === 'modified' || change.status === 'created')
									if (!leftVisible && !rightVisible) continue
									storageRows.push({
										left: leftVisible ? (
											<div class={`${preLine} group/line`}>
												<div class="flex w-full items-center gap-2">
													<Code variant="outline" class="border-transparent text-inherit text-xs">
														{formatHex(key)}
													</Code>
													<span class="text-muted-foreground">=</span>
													<Code variant="outline" class="border-transparent text-inherit text-xs">
														{formatHex(change.valueBefore || '0x')}
													</Code>
													<Button
														variant="ghost"
														size="icon"
														onClick={() => handleCopy(change.valueBefore || '0x', 'storage value (pre)')}
														class={cn(
															'ml-auto h-5 w-5 rounded-sm hover:bg-white/40 hover:backdrop-blur-sm dark:hover:bg-neutral-900/40',
															!isMobile && 'opacity-0 transition-opacity group-hover/line:opacity-100',
														)}
														aria-label="Copy storage pre"
													>
														<CopyIcon class="h-3 w-3" />
													</Button>
												</div>
											</div>
										) : undefined,
										right: rightVisible ? (
											<div class={`${postLine} group/line`}>
												<div class="flex w-full items-center gap-2">
													<Code variant="outline" class="border-transparent text-inherit text-xs">
														{formatHex(key)}
													</Code>
													<span class="text-muted-foreground">=</span>
													<Code variant="outline" class="border-transparent text-inherit text-xs">
														{formatHex(change.valueAfter || '0x')}
													</Code>
													<Button
														variant="ghost"
														size="icon"
														onClick={() => handleCopy(change.valueAfter || '0x', 'storage value (post)')}
														class={cn(
															'ml-auto h-5 w-5 rounded-sm hover:bg-white/40 hover:backdrop-blur-sm dark:hover:bg-neutral-900/40',
															!isMobile && 'opacity-0 transition-opacity group-hover/line:opacity-100',
														)}
														aria-label="Copy storage post"
													>
														<CopyIcon class="h-3 w-3" />
													</Button>
												</div>
											</div>
										) : undefined,
									})
								}
								if (storageRows.length > 0) {
									blocks.push({ label: 'Storage', rows: storageRows })
								}

								return (
									<div class="group px-4 py-3">
										<div class="mb-2 flex items-center justify-between">
											<div class="flex items-center gap-2">
												{getStatusIcon(account.status)}
												<Code class="text-sm">{formatHex(account.address)}</Code>
												<span class="text-muted-foreground text-xs">({getStatusLabel(account.status)})</span>
											</div>
											<Button
												variant="ghost"
												size="sm"
												onClick={() => handleCopy(account.address, 'address')}
												class={cn('h-7', !isMobile && 'opacity-0 transition-opacity group-hover:opacity-100')}
												aria-label="Copy address"
											>
												<CopyIcon class="h-4 w-4" />
											</Button>
										</div>
										<div class="space-y-3">
											<For each={blocks}>
												{(block) => (
													<div>
														<div class="px-1 text-[11px] text-muted-foreground">{block.label}</div>
														<div class="mt-1 space-y-1.5">
															<For each={block.rows}>
																{(row) => (
																	<div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
																		<div>
																			{row.left ?? (
																				<div class="min-h-6 rounded-xs bg-muted/40 px-2 dark:bg-muted/20">
																					<div class="flex items-center gap-2">
																						<Code variant="outline" class="invisible border-transparent text-xs">
																							0
																						</Code>
																					</div>
																				</div>
																			)}
																		</div>
																		<div>
																			{row.right ?? (
																				<div class="min-h-6 rounded-xs bg-muted/40 px-2 dark:bg-muted/20">
																					<div class="flex items-center gap-2">
																						<Code variant="outline" class="invisible border-transparent text-xs">
																							0
																						</Code>
																					</div>
																				</div>
																			)}
																		</div>
																	</div>
																)}
															</For>
														</div>
													</div>
												)}
											</For>
										</div>
									</div>
								)
							}}
						</For>
					</div>
				</Show>
			</CardContent>
		</Card>
	)
}

export default StateDiff
