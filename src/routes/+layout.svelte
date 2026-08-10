<script lang="ts">
	import '@fontsource-variable/newsreader';
	import '@fontsource-variable/newsreader/wght-italic.css';
	import '@fontsource-variable/inter';
	import '@fontsource-variable/jetbrains-mono';
	import { onMount, tick, untrack } from 'svelte';
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import {
		currentContextTokens,
		hostQuery,
		isRemoteHost,
		LOCAL_HOST,
		type HostInfo,
		type JsonRpcNotification,
		type ThreadItem,
		type ThreadSummary,
		type Turn
	} from '$lib/protocol';
	import { parseSlash, SLASH_HELP, filterSlashCommands, type SlashCommandInfo } from '$lib/slash';
	import { ComposerHistory } from '$lib/history';
	import FileBrowser from '$lib/FileBrowser.svelte';
	import GitDiffViewer from '$lib/GitDiffViewer.svelte';
	import { parseCodexMarkdown, type MarkdownBlock, type MarkdownInline } from '$lib/markdown';

	let { children } = $props();

	interface Goal {
		objective: string;
		status: string;
		tokenBudget: number | null;
		tokensUsed: number;
		timeUsedSeconds: number;
	}

	interface ThreadState {
		order: string[];
		byId: Record<string, ThreadItem>;
		status: 'idle' | 'running';
		turnId: string | null;
		tokens: number | null;
		contextWindow: number | null;
		error: string | null;
		goal: Goal | null;
	}

	interface SelectedImage {
		id: string;
		file: File;
		name: string;
	}

	interface ArchivedSessionSnapshot {
		id: string;
		label: string;
		index: number;
		summary: ThreadSummary;
		thread: ThreadState | undefined;
		config: { model: string; effort: string; profile: string | null } | undefined;
		cwd: string | undefined;
	}

	interface ArchiveNotice {
		tone: 'undo' | 'info' | 'error';
		message: string;
		snapshot?: ArchivedSessionSnapshot;
	}

	interface ModelChoice {
		id: string;
		displayName: string;
		defaultEffort: string;
		efforts: string[];
	}

	interface ModelState {
		model: string;
		effort: string;
		models: ModelChoice[];
	}

	interface ProfileChoice {
		name: string;
		model: string | null;
	}

	type RenderPart =
		| { type: 'text'; text: string }
		| { type: 'image'; path: string; source: 'local' | 'remote' };

	let localCounter = 0;

	let sessions = $state<ThreadSummary[]>([]);
	// Host picker: local plus the remote machines found in ~/.ssh/config.
	let newHost = $state(LOCAL_HOST);
	let hostChoices = $state<HostInfo[]>([]);
	// Live connection state per remote host, fed by yacwu/host/status events.
	let hostStates = $state<Record<string, string>>({});
	let hostDefaultCwds = $state<Record<string, string>>({});
	let sessionsLoaded = $state(false);
	let threads = $state<Record<string, ThreadState>>({});
	let sessionConfigs = $state<Record<string, { model: string; effort: string; profile: string | null }>>({});
	let fastSessions = $state<Record<string, boolean>>({});
	let input = $state('');
	let selectedImages = $state<SelectedImage[]>([]);
	let sendingMessage = $state(false);
	let connected = $state(false);
	let loadingHistory = $state(false);
	let cwds = $state<Record<string, string>>({});
	let conflict = $state<{ id: string; holders: { pid: number; command: string }[] } | null>(null);
	let mobileSidebarOpen = $state(false);
	let mobileViewport = $state(false);
	let desktopSidebarHidden = $state(false);
	let unseenActivity = $state(false);
	let archiveNotice = $state<ArchiveNotice | null>(null);
	let sessionInfoDialog = $state<HTMLDialogElement | null>(null);
	// Read-only file browser (FileBrowser.svelte), rooted at the session cwd.
	let filesOpen = $state(false);
	let filesReveal = $state<{ path: string; line: number | null; nonce: number } | null>(null);
	let filesRefresh = $state(0);
	let filesToggleEl = $state<HTMLButtonElement | null>(null);
	let changesOpen = $state(false);
	let changesReveal = $state<{ path: string; nonce: number } | null>(null);
	let sidebarEl = $state<HTMLElement | null>(null);
	let sidebarToggleEl = $state<HTMLButtonElement | null>(null);
	let imageInputEl = $state<HTMLInputElement | null>(null);
	let composerTextareaEl = $state<HTMLTextAreaElement | null>(null);
	let transcriptScrollTop = $state(0);
	let transcriptViewportHeight = $state(0);
	let transcriptHeightVersion = $state(0);
	let commandOutputExpanded = $state<Record<string, boolean>>({});
	// Per-message toggle between rendered and raw Markdown for Codex replies.
	let agentRawShown = $state<Record<string, boolean>>({});
	// Touch devices have no hover: a tap on a message stands in for it,
	// revealing that message's raw-Markdown toggle until a tap elsewhere.
	let hoverPointer = $state(true);
	let tappedAgentKey = $state<string | null>(null);
	const rowHeights = new Map<string, number>();
	// Per-session Up/Down message recall (codex TUI semantics; see $lib/history).
	const composerHistories = new Map<string, ComposerHistory>();
	const ESTIMATED_ROW_HEIGHT = 72;
	const VIRTUAL_OVERSCAN_PX = 700;
	const COMMAND_OUTPUT_COLLAPSE_LINES = 10;
	const COMMAND_OUTPUT_COLLAPSE_CHARS = 1200;
	const FAST_SESSIONS_KEY = 'yacwu-fast-sessions';
	let archiveNoticeTimer: ReturnType<typeof setTimeout> | null = null;

	// The active session is whatever is in the URL (/s/<id>); / shows the welcome.
	const activeId = $derived(page.params.id ?? null);
	const active = $derived(activeId ? threads[activeId] : null);
	const activeSummary = $derived(sessions.find((s) => s.id === activeId) ?? null);
	const activeConfig = $derived(activeId ? sessionConfigs[activeId] : null);
	const activeHost = $derived(activeId ? sessionHost(activeId) : LOCAL_HOST);
	const activeRemote = $derived(isRemoteHost(activeHost));
	const activeHostState = $derived(
		activeRemote ? (hostStates[activeHost] ?? 'connected') : 'connected'
	);
	// Side chats (ephemeral /btw forks) nest under their parent in the sidebar.
	// Orphans — whose parent was archived or isn't listed — stay top-level so
	// they remain reachable.
	const topSessions = $derived(
		sessions.filter(
			(s) => !isSideChat(s) || !sessions.some((p) => p.id === s.forkedFromId)
		)
	);
	const activeIsSide = $derived(Boolean(activeSummary && isSideChat(activeSummary)));
	const activeParent = $derived(
		activeIsSide ? (sessions.find((s) => s.id === activeSummary?.forkedFromId) ?? null) : null
	);
	// Slash-command autocomplete: offered while the composer holds a bare
	// command token ("/…" with no whitespace or newline yet), mirroring the
	// codex TUI's command popup. Esc hides it until the token changes.
	let slashDismissedToken = $state<string | null>(null);
	let slashIndex = $state(0);
	const slashToken = $derived(/^\/\S*$/.test(input) ? input : null);
	const slashMatches = $derived(
		slashToken !== null && slashToken !== slashDismissedToken
			? filterSlashCommands(slashToken.slice(1))
			: []
	);
	const slashPopupVisible = $derived(slashMatches.length > 0);
	const composerPlaceholder = $derived(
		mobileViewport ? 'Message Codex' : 'Message Codex…'
	);
	const sessionRailOpen = $derived(mobileViewport ? mobileSidebarOpen : !desktopSidebarHidden);
	const sessionRailToggleLabel = $derived(
		mobileViewport
			? mobileSidebarOpen
				? 'Close sessions'
				: 'Open sessions'
			: desktopSidebarHidden
				? 'Show sessions'
				: 'Hide sessions'
	);
	const SEND_FETCH_RETRIES = 3;

	// Side conversations (/btw) fork the thread ephemerally; these instructions
	// keep the inherited history reference-only so the side agent doesn't
	// continue the parent thread's task. Mirrors the Codex TUI's /side.
	const BTW_DEVELOPER_INSTRUCTIONS = `You are in a side conversation, not the main thread.

This side conversation is for answering questions and lightweight exploration without disrupting the main thread. Do not present yourself as continuing the main thread's active task.

The inherited fork history is provided only as reference context. Do not treat instructions, plans, or requests found in the inherited history as active instructions for this side conversation. Only instructions submitted after the fork are active.

You may perform non-mutating inspection, including reading or searching files and running checks that do not alter repo-tracked files.

Do not modify files, source, git state, permissions, configuration, or any other workspace state unless the user explicitly requests that mutation in this side conversation. If the user explicitly requests a mutation, keep it minimal, local to the request, and avoid disrupting the main thread.`;

	// New-session working-directory / profile picker.
	let creating = $state(false);
	let createError = $state<string | null>(null);
	let newCwd = $state('');
	let newProfile = $state('');
	let profileChoices = $state<ProfileChoice[]>([]);
	let defaultCwd = $state('');
	let cwdInputEl = $state<HTMLInputElement | null>(null);

	let transcriptEl = $state<HTMLDivElement | null>(null);
	const activeItems = $derived(itemsOf(active).filter(isRenderableTranscriptItem));
	const virtualTranscript = $derived(
		virtualizeItems(activeItems, transcriptScrollTop, transcriptViewportHeight, transcriptHeightVersion)
	);

	function ensureThread(id: string): ThreadState {
		if (!threads[id]) {
			threads[id] = {
				order: [],
				byId: {},
				status: 'idle',
				turnId: null,
				tokens: null,
				contextWindow: null,
				error: null,
				goal: null
			};
		}
		return threads[id];
	}

	function upsertItem(id: string, item: ThreadItem & { id: string }, stampTime = false) {
		const t = ensureThread(id);
		if (!t.byId[item.id]) t.order.push(item.id);
		// Preserve any locally-accumulated streamed text across updates.
		const prev = t.byId[item.id] as any;
		const next = { ...item } as any;
		if (prev) {
			if (next.text === '' && prev.text) next.text = prev.text;
			if (next._reason === undefined && prev._reason) next._reason = prev._reason;
			if (next._out === undefined && prev._out) next._out = prev._out;
			if (next._at === undefined && prev._at) next._at = prev._at;
		} else if (stampTime) {
			// The protocol has no per-item timestamps; live items are stamped
			// with arrival time. Restored history stays unstamped.
			next._at = Date.now();
		}
		t.byId[item.id] = next;
	}

	function replaceItems(id: string, turns: Turn[]) {
		const t = ensureThread(id);
		t.order = [];
		t.byId = {};
		for (const turn of turns) {
			for (const item of turn.items ?? []) {
				if ((item as any).id) upsertItem(id, item as any);
			}
		}
	}

	/** The host a session runs on: its summary's tag, the URL hint, or local. */
	function sessionHost(id: string | null): string {
		if (!id) return LOCAL_HOST;
		const summary = sessions.find((s) => s.id === id);
		if (summary?.host) return summary.host;
		if (page.params.id === id) {
			const hinted = page.url.searchParams.get('host');
			if (hinted) return hinted;
		}
		return LOCAL_HOST;
	}

	/** Thread API URL carrying the session's host as a routing hint. */
	function threadApi(id: string, path = ''): string {
		return `/api/threads/${id}${path}${hostQuery(sessionHost(id))}`;
	}

	function upsertSession(thr: any) {
		if (!thr?.id) return;
		if (thr.cwd) cwds[thr.id] = thr.cwd;
		const now = Math.floor(Date.now() / 1000);
		// Preserve relationship metadata when a payload omits it (codex reports
		// forkedFromId only in the thread/fork response, not on later reads).
		const existing = sessions.find((s) => s.id === thr.id);
		const summary: ThreadSummary = {
			id: thr.id,
			preview: thr.preview ?? '',
			name: thr.name ?? null,
			createdAt: thr.createdAt ?? existing?.createdAt ?? now,
			updatedAt: thr.updatedAt ?? thr.createdAt ?? existing?.updatedAt ?? now,
			cwd: thr.cwd,
			forkedFromId: thr.forkedFromId ?? existing?.forkedFromId ?? null,
			ephemeral: thr.ephemeral ?? existing?.ephemeral ?? false,
			host: thr.host ?? existing?.host ?? undefined
		};
		sessions = [summary, ...sessions.filter((s) => s.id !== thr.id)];
	}

	function touchSession(id: string, timestamp: unknown) {
		const updatedAt =
			typeof timestamp === 'number' && Number.isFinite(timestamp) && timestamp > 0
				? Math.floor(timestamp)
				: Math.floor(Date.now() / 1000);
		sessions = sessions.map((session) =>
			session.id === id ? { ...session, updatedAt } : session
		);
	}

	function removeSession(id: string) {
		sessions = sessions.filter((s) => s.id !== id);
		delete threads[id];
		delete sessionConfigs[id];
		delete fastSessions[id];
		persistFastSessions();
		delete cwds[id];
		composerHistories.delete(id);
		for (const key of Object.keys(commandOutputExpanded)) {
			if (key.startsWith(`${id}:`)) delete commandOutputExpanded[key];
		}
		for (const key of Object.keys(agentRawShown)) {
			if (key.startsWith(`${id}:`)) delete agentRawShown[key];
		}
		sessionStorage.removeItem(sideParentKey(id));
	}

	function persistFastSessions() {
		localStorage.setItem(
			FAST_SESSIONS_KEY,
			JSON.stringify(Object.keys(fastSessions).filter((id) => fastSessions[id]))
		);
	}

	function setFastSession(id: string, enabled: boolean) {
		fastSessions[id] = enabled;
		persistFastSessions();
	}

	/** Append a client-side note (slash-command echo / help / errors). */
	function addLocalNote(id: string, text: string, tone: 'info' | 'err' = 'info') {
		const shouldScroll = id === activeId && isTranscriptAtBottom();
		const t = ensureThread(id);
		const noteId = `local-${++localCounter}`;
		t.order.push(noteId);
		t.byId[noteId] = { type: 'localNote', id: noteId, text, tone } as any;
		if (shouldScroll) scrollToBottom();
	}

	function handleNotification(msg: JsonRpcNotification) {
		const p: any = msg.params ?? {};
		const tid: string | undefined = p.threadId;
		const affectedThreadId: string | undefined = tid ?? p.thread?.id;
		const shouldScroll = affectedThreadId === activeId && isTranscriptAtBottom();

		switch (msg.method) {
			case 'yacwu/host/status': {
				const host = String(p.host ?? '');
				if (!host) break;
				const previous = hostStates[host];
				hostStates[host] = String(p.state ?? 'disconnected');
				// A host coming back means notifications were missed while it was
				// away: refresh the rail and resync the open transcript from
				// thread/read, the reconciliation source of truth.
				if (hostStates[host] === 'connected' && previous && previous !== 'connected') {
					void loadSessions();
					if (activeId && sessionHost(activeId) === host) void openSession(activeId, false);
				}
				break;
			}

			case 'thread/started': {
				const thr = p.thread;
				if (thr?.id) {
					ensureThread(thr.id);
					upsertSession(thr);
				}
				break;
			}
			case 'thread/archived': {
				if (tid) removeSession(tid);
				break;
			}
			case 'thread/closed': {
				if (tid) removeSession(tid);
				break;
			}
			case 'thread/unarchived': {
				if (p.thread) upsertSession(p.thread);
				else void loadSessions();
				break;
			}
			case 'turn/started': {
				if (tid) {
					const t = ensureThread(tid);
					t.status = 'running';
					t.turnId = p.turn?.id ?? null;
					t.error = null;
					touchSession(tid, p.turn?.startedAt);
				}
				break;
			}
			case 'turn/completed': {
				if (tid) {
					const t = ensureThread(tid);
					t.status = 'idle';
					t.turnId = null;
					touchSession(tid, p.turn?.completedAt);
					if (p.turn?.status === 'failed' && p.turn?.error?.message) {
						t.error = p.turn.error.message;
					}
				}
				break;
			}
			case 'item/started':
			case 'item/completed': {
				if (tid && p.item?.id) upsertItem(tid, p.item, true);
				// The file browser refreshes what it is showing when the agent
				// touches files in the viewed session.
				if (tid === activeId && p.item?.type === 'fileChange') filesRefresh += 1;
				break;
			}
			case 'turn/diff/updated': {
				if (tid === activeId) filesRefresh += 1;
				break;
			}
			case 'item/agentMessage/delta': {
				if (tid && p.itemId) {
					const t = ensureThread(tid);
					const it = t.byId[p.itemId] as any;
					if (it) it.text = (it.text ?? '') + (p.delta ?? '');
				}
				break;
			}
			case 'item/reasoning/summaryTextDelta': {
				if (tid && p.itemId) {
					const t = ensureThread(tid);
					const it = t.byId[p.itemId] as any;
					if (it) it._reason = (it._reason ?? '') + (p.delta ?? '');
				}
				break;
			}
			case 'item/commandExecution/outputDelta': {
				if (tid && p.itemId) {
					const t = ensureThread(tid);
					const it = t.byId[p.itemId] as any;
					if (it) it._out = (it._out ?? '') + (p.delta ?? '');
				}
				break;
			}
			case 'thread/tokenUsage/updated': {
				if (tid) {
					const t = ensureThread(tid);
					const tokens = currentContextTokens(p.tokenUsage);
					if (tokens !== null) t.tokens = tokens;
					t.contextWindow = p.tokenUsage?.modelContextWindow ?? t.contextWindow;
				}
				break;
			}
			case 'thread/goal/updated': {
				if (tid && p.goal) ensureThread(tid).goal = p.goal as Goal;
				break;
			}
			case 'thread/goal/cleared': {
				if (tid) ensureThread(tid).goal = null;
				break;
			}
			case 'thread/settings/updated': {
				if (tid && p.threadSettings) {
					setFastSession(tid, p.threadSettings.serviceTier === 'priority');
				}
				break;
			}
			case 'turn/error':
			case 'error': {
				if (tid) {
					const t = ensureThread(tid);
					t.error = p.error?.message ?? 'error';
					t.status = 'idle';
				}
				break;
			}
		}

		if (shouldScroll) {
			scrollToBottom();
		} else if (
			affectedThreadId === activeId &&
			(msg.method.startsWith('item/') || msg.method.startsWith('turn/'))
		) {
			unseenActivity = true;
		}
	}

	function isTranscriptAtBottom(): boolean {
		if (!transcriptEl) return true;
		const remaining = transcriptEl.scrollHeight - transcriptEl.scrollTop - transcriptEl.clientHeight;
		return remaining <= 24;
	}

	async function scrollToBottom() {
		await tick();
		if (!transcriptEl) return;
		unseenActivity = false;
		transcriptEl.scrollTop = transcriptEl.scrollHeight;
		requestAnimationFrame(() => {
			if (transcriptEl) transcriptEl.scrollTop = transcriptEl.scrollHeight;
		});
	}

	function transcriptRowKey(item: ThreadItem): string {
		return `${activeId ?? 'none'}:${(item as any).id ?? ''}`;
	}

	function measuredRowHeight(item: ThreadItem): number {
		return rowHeights.get(transcriptRowKey(item)) ?? ESTIMATED_ROW_HEIGHT;
	}

	function virtualizeItems(
		items: ThreadItem[],
		scrollTop: number,
		viewportHeight: number,
		_heightVersion: number
	): { items: ThreadItem[]; before: number; after: number; total: number } {
		if (items.length === 0) return { items: [], before: 0, after: 0, total: 0 };

		const startOffset = Math.max(0, scrollTop - VIRTUAL_OVERSCAN_PX);
		const endOffset = scrollTop + viewportHeight + VIRTUAL_OVERSCAN_PX;
		let before = 0;
		let start = 0;

		while (start < items.length) {
			const h = measuredRowHeight(items[start]);
			if (before + h >= startOffset) break;
			before += h;
			start += 1;
		}

		let renderedHeight = 0;
		let end = start;
		while (end < items.length) {
			const h = measuredRowHeight(items[end]);
			renderedHeight += h;
			end += 1;
			if (before + renderedHeight > endOffset) break;
		}

		let after = 0;
		for (let i = end; i < items.length; i += 1) after += measuredRowHeight(items[i]);
		return { items: items.slice(start, end), before, after, total: before + renderedHeight + after };
	}

	function updateTranscriptViewport() {
		if (!transcriptEl) {
			transcriptViewportHeight = 0;
			transcriptScrollTop = 0;
			return;
		}
		transcriptViewportHeight = transcriptEl.clientHeight;
		transcriptScrollTop = transcriptEl.scrollTop;
	}

	function onTranscriptScroll() {
		updateTranscriptViewport();
		if (isTranscriptAtBottom()) unseenActivity = false;
	}

	function measureTranscriptRow(node: HTMLElement, key: string) {
		const measure = () => {
			const next = node.getBoundingClientRect().height;
			if (next <= 0) return;
			const prev = rowHeights.get(key);
			if (prev === undefined || Math.abs(prev - next) > 0.5) {
				rowHeights.set(key, next);
				transcriptHeightVersion += 1;
			}
		};
		measure();
		const observer = new ResizeObserver(measure);
		observer.observe(node);
		return {
			update(nextKey: string) {
				key = nextKey;
				measure();
			},
			destroy() {
				observer.disconnect();
			}
		};
	}

	async function loadSessions() {
		try {
			const res = await fetch('/api/threads');
			const data = await res.json();
			const fetched: ThreadSummary[] = data.data ?? [];
			// Merge instead of replacing: sessions created or forked after this
			// fetch started (and not yet visible to thread/list) must survive.
			const extras = sessions.filter((s) => !fetched.some((f) => f.id === s.id));
			sessions = [...extras, ...fetched];
			defaultCwd = data.defaultCwd ?? '';
			await recoverSideChats();
		} finally {
			sessionsLoaded = true;
		}
	}

	// Ephemeral side chats are never persisted, so thread/list omits them.
	// Re-attach any still loaded in codex memory to their parent sessions.
	// Codex only reports forkedFromId in the thread/fork response, so the
	// parent link is bridged through sessionStorage (same lifetime as the
	// ephemeral thread: this browser session).
	async function recoverSideChats() {
		try {
			const res = await fetch('/api/threads/loaded');
			const data = await res.json();
			const loaded: string[] = data.data ?? [];
			const missing = loaded.filter((id) => !sessions.some((s) => s.id === id));
			for (const id of missing) {
				try {
					const res = await fetch(`/api/threads/${id}`);
					const data = await res.json();
					const thr = data.thread;
					const parentId = thr?.id ? sessionStorage.getItem(sideParentKey(thr.id)) : null;
					if (thr?.ephemeral && parentId) {
						upsertSession({ ...thr, forkedFromId: thr.forkedFromId ?? parentId ?? null });
					}
				} catch {
					/* unreadable thread — skip */
				}
			}
		} catch {
			/* loaded list unavailable — skip recovery */
		}
	}

	async function startCreating() {
		createError = null;
		newCwd = '';
		newProfile = '';
		newHost = LOCAL_HOST;
		creating = true;
		// Hosts come from ~/.ssh/config, re-read by the backend on demand.
		fetch('/api/hosts')
			.then((r) => r.json())
			.then((d) => {
				hostChoices = (d.hosts ?? []) as HostInfo[];
				for (const h of hostChoices) {
					if (h.kind === 'remote' && !(h.name in hostStates)) hostStates[h.name] = h.state;
				}
			})
			.catch(() => (hostChoices = []));
		// The create form lives in the session rail; surface it if it's hidden
		// (welcome-screen CTA on mobile, or desktop with the rail collapsed).
		if (mobileViewport) {
			mobileSidebarOpen = true;
		} else if (desktopSidebarHidden) {
			desktopSidebarHidden = false;
			localStorage.setItem('yacwu-sidebar-hidden', 'false');
		}
		// Always re-fetch: the backend reads profile files fresh from disk.
		fetch('/api/profiles')
			.then((r) => r.json())
			.then((d) => (profileChoices = (d.profiles ?? []) as ProfileChoice[]))
			.catch(() => (profileChoices = []));
		await tick();
		cwdInputEl?.focus();
	}

	function cancelCreating() {
		creating = false;
		createError = null;
	}

	async function openSidebar() {
		mobileSidebarOpen = true;
		await tick();
		const target =
			sidebarEl?.querySelector<HTMLElement>('.session.active') ??
			sidebarEl?.querySelector<HTMLElement>('.new') ??
			sidebarEl?.querySelector<HTMLElement>('a, button:not(:disabled)');
		target?.focus();
	}

	async function closeSidebar(restoreFocus = true) {
		mobileSidebarOpen = false;
		await tick();
		if (restoreFocus) sidebarToggleEl?.focus();
	}

	async function toggleSidebar() {
		if (mobileViewport) {
			if (mobileSidebarOpen) await closeSidebar();
			else await openSidebar();
			return;
		}
		desktopSidebarHidden = !desktopSidebarHidden;
		localStorage.setItem('yacwu-sidebar-hidden', desktopSidebarHidden ? 'true' : 'false');
		await tick();
		if (desktopSidebarHidden) sidebarToggleEl?.focus();
		else sidebarEl?.querySelector<HTMLElement>('.drawer-close')?.focus();
	}

	function onWindowKeydown(event: KeyboardEvent) {
		if (!mobileViewport || !mobileSidebarOpen) return;
		if (event.key === 'Escape') {
			event.preventDefault();
			void closeSidebar();
			return;
		}
		if (event.key === 'Tab') {
			const focusable = Array.from(
				sidebarEl?.querySelectorAll<HTMLElement>(
					'a[href], button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex]:not([tabindex="-1"])'
				) ?? []
			).filter((element) => element.getClientRects().length > 0);
			if (focusable.length === 0) return;
			const first = focusable[0];
			const last = focusable[focusable.length - 1];
			if (event.shiftKey && document.activeElement === first) {
				event.preventDefault();
				last.focus();
			} else if (!event.shiftKey && document.activeElement === last) {
				event.preventDefault();
				first.focus();
			}
		}
	}

	/**
	 * Connect to a remote host and pull its sessions into the rail (plus its
	 * default working directory for the create form). Triggered by picking a
	 * host — the connection may take a few seconds while ssh bootstraps the
	 * remote app-server; state updates arrive over the event stream.
	 */
	async function loadHostSessions(host: string) {
		try {
			const res = await fetch(`/api/threads${hostQuery(host)}`);
			const data = await res.json();
			if (!res.ok) {
				if (newHost === host) createError = data.error ?? `could not reach ${host}`;
				return;
			}
			if (newHost === host) createError = null;
			hostDefaultCwds[host] = data.defaultCwd ?? '';
			const fetched: ThreadSummary[] = data.data ?? [];
			const others = sessions.filter((s) => !fetched.some((f) => f.id === s.id));
			sessions = [...others, ...fetched];
		} catch {
			if (newHost === host) createError = `could not reach ${host}`;
		}
	}

	function onNewHostChange() {
		createError = null;
		if (isRemoteHost(newHost) && hostDefaultCwds[newHost] === undefined) {
			void loadHostSessions(newHost);
		}
	}

	async function newSession(cwd?: string) {
		createError = null;
		const profile = newProfile.trim();
		const host = newHost;
		const remote = isRemoteHost(host);
		const res = await fetch('/api/threads', {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({
				...(cwd ? { cwd } : {}),
				...(profile && !remote ? { profile } : {}),
				...(remote ? { host } : {})
			})
		});
		const data = await res.json();
		if (!res.ok) {
			createError = data.error ?? 'failed to create session';
			return;
		}
		creating = false;
		const id = data.thread?.id;
		if (id) {
			ensureThread(id);
			upsertSession({ ...data.thread, host: data.host ?? host });
			setFastSession(id, data.serviceTier === 'priority');
			goto(`/s/${id}${hostQuery(data.host ?? host)}`);
			mobileSidebarOpen = false;
		}
	}

	// Open the session named in the URL whenever it changes. Only the URL id is a
	// reactive dependency; the rest runs untracked so item updates don't re-trigger.
	$effect(() => {
		const id = page.params.id ?? null;
		untrack(() => {
			conflict = null;
			unseenActivity = false;
			if (!id) return;
			// Stale browsing state must not leak across visits to a session.
			composerHistories.get(id)?.resetNavigation();
			slashDismissedToken = null;
			void loadSessionConfig(id);
			const t = ensureThread(id);
			if (t.order.length > 0) {
				scrollToBottom();
				return;
			}
			openSession(id, false);
		});
	});

	async function loadSessionConfig(id: string) {
		const previous = sessionConfigs[id];
		const [modelResult, profileResult] = await Promise.allSettled([
			fetch(threadApi(id, '/model')).then(async (res) => {
				if (!res.ok) throw new Error('model settings unavailable');
				return (await res.json()) as ModelState;
			}),
			fetch(threadApi(id, '/profile')).then(async (res) => {
				if (!res.ok) throw new Error('profile unavailable');
				return (await res.json()) as { profile?: string | null };
			})
		]);
		const model = modelResult.status === 'fulfilled' ? modelResult.value : null;
		const profile = profileResult.status === 'fulfilled' ? profileResult.value.profile ?? null : previous?.profile ?? null;
		if (!model && !previous) return;
		sessionConfigs[id] = {
			model: model?.model ?? previous.model,
			effort: model?.effort ?? previous.effort,
			profile
		};
	}

	async function openSession(id: string, force: boolean) {
		loadingHistory = true;
		try {
			const res = await fetch(threadApi(id, '/open'), {
				method: 'POST',
				headers: { 'content-type': 'application/json' },
				body: JSON.stringify({ force })
			});
			const data = await res.json();
			if (res.status === 409 && data.conflict) {
				conflict = { id, holders: data.holders ?? [] };
				return;
			}
			conflict = null;
			const thr = data.thread;
			if (thr?.cwd) cwds[id] = thr.cwd;
			if ('serviceTier' in data) setFastSession(id, data.serviceTier === 'priority');
			// Only sync the transcript when the server actually returned history.
			// A failed open (e.g. a brand-new thread with no rollout yet) must not
			// wipe locally rendered items — the response can arrive late, after
			// the user has already run slash commands in this session.
			if (thr) replaceItems(id, thr.turns ?? []);
			// Surface any persisted goal for this session.
			fetch(threadApi(id, '/goal'))
				.then((r) => r.json())
				.then((g) => {
					ensureThread(id).goal = (g?.goal ?? null) as Goal | null;
				})
				.catch(() => {});
		} finally {
			loadingHistory = false;
			scrollToBottom();
		}
	}

	function forceOpen() {
		if (conflict) openSession(conflict.id, true);
	}

	function dismissConflict() {
		conflict = null;
		goto('/');
	}

	function isFailedFetch(err: unknown): boolean {
		return err instanceof TypeError && err.message === 'Failed to fetch';
	}

	function retryDelay(attempt: number): Promise<void> {
		return new Promise((resolve) => setTimeout(resolve, 250 * 2 ** attempt));
	}

	async function sendMessageRequest(id: string, text: string, images: File[]): Promise<Response> {
		if (images.length > 0) {
			const body = new FormData();
			body.set('text', text);
			for (const image of images) body.append('images', image, image.name);
			return fetch(threadApi(id, '/message'), { method: 'POST', body });
		}

		return fetch(threadApi(id, '/message'), {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({ text })
		});
	}

	async function sendMessageWithRetries(id: string, text: string, images: File[]): Promise<Response> {
		for (let attempt = 0; ; attempt += 1) {
			try {
				return await sendMessageRequest(id, text, images);
			} catch (err) {
				if (!isFailedFetch(err) || attempt >= SEND_FETCH_RETRIES) throw err;
				await retryDelay(attempt);
			}
		}
	}

	async function send() {
		if (sendingMessage) return;
		const draftInput = input;
		const draftImages = selectedImages;
		const text = draftInput.trim();
		if ((!text && selectedImages.length === 0) || !activeId) return;
		const id = activeId;
		const images = draftImages.map((img) => img.file);

		// Slash commands are handled client-side and dispatched to dedicated RPCs,
		// mirroring the Codex TUI. Everything else is a normal model turn.
		if (text.startsWith('/') && images.length === 0) {
			input = '';
			composerHistoryOf(id).record(text);
			await handleSlash(id, text);
			return;
		}

		const t = ensureThread(id);
		t.status = 'running';
		sendingMessage = true;
		try {
			const res = await sendMessageWithRetries(id, text, images);

			if (!res.ok) {
				const data = await res.json().catch(() => ({}));
				throw new Error(data.error ?? `failed to send message (${res.status})`);
			}

			if (input === draftInput) input = '';
			if (selectedImages === draftImages) selectedImages = [];
			composerHistoryOf(id).record(text);
		} catch (err) {
			t.status = 'idle';
			addLocalNote(id, err instanceof Error ? err.message : 'failed to send message', 'err');
		} finally {
			sendingMessage = false;
		}
	}

	function fmtDuration(sec: number): string {
		const d = Math.floor(sec / 86400);
		const h = Math.floor((sec % 86400) / 3600);
		const m = Math.floor((sec % 3600) / 60);
		if (d) return `${d}d ${h}h`;
		if (h) return `${h}h ${m}m`;
		if (m) return `${m}m`;
		return `${Math.max(0, sec)}s`;
	}

	function sessionTimestampDate(timestamp: number | null | undefined): Date | null {
		if (typeof timestamp !== 'number' || !Number.isFinite(timestamp) || timestamp <= 0) return null;
		const date = new Date(timestamp * 1000);
		return Number.isNaN(date.getTime()) ? null : date;
	}

	function fmtSessionTimestamp(timestamp: number | null | undefined): string {
		const date = sessionTimestampDate(timestamp);
		if (!date) return '—';
		return new Intl.DateTimeFormat(undefined, {
			dateStyle: 'medium',
			timeStyle: 'short'
		}).format(date);
	}

	function sessionTimestampIso(timestamp: number | null | undefined): string | undefined {
		return sessionTimestampDate(timestamp)?.toISOString();
	}

	function fmtReset(resetsAt: number): string {
		const diff = resetsAt - Math.floor(Date.now() / 1000);
		return diff <= 0 ? 'now' : fmtDuration(diff);
	}

	function windowLabel(mins: number): string {
		if (mins % 1440 === 0) return `${mins / 1440}d`;
		if (mins % 60 === 0) return `${mins / 60}h`;
		return `${mins}m`;
	}

	function fmtTokens(tokens: number): string {
		if (tokens >= 1_000_000) return `${(tokens / 1_000_000).toFixed(1)}m`;
		if (tokens >= 1_000) return `${Math.round(tokens / 1_000)}k`;
		return tokens.toLocaleString();
	}

	function goalBudgetPercent(goal: Goal): number {
		if (!goal.tokenBudget) return 0;
		return Math.min(100, Math.round((goal.tokensUsed / goal.tokenBudget) * 100));
	}

	async function buildStatus(id: string): Promise<string> {
		const t = threads[id];
		const sess = sessions.find((s) => s.id === id);
		const lines = ['status'];
		lines.push(`  session   ${id}`);
		const cwd = cwds[id] ?? sess?.cwd;
		if (cwd) lines.push(`  cwd       ${cwd}`);
		const host = sessionHost(id);
		if (isRemoteHost(host)) {
			lines.push(`  host      ${host} (${hostStates[host] ?? 'connected'})`);
		}
		lines.push(`  state     ${t?.status ?? 'idle'}`);
		lines.push(`  fast      ${fastSessions[id] ? 'on' : 'off'}`);
		try {
			const res = await fetch(threadApi(id, '/model'));
			const settings = (await res.json()) as Partial<ModelState> & { error?: string };
			if (!res.ok) throw new Error(settings.error ?? 'model settings unavailable');
			if (settings.model) lines.push(`  model     ${settings.model}`);
			if (settings.effort) lines.push(`  effort    ${settings.effort}`);
		} catch {
			lines.push('  model     unavailable');
			lines.push('  effort    unavailable');
		}
		try {
			const res = await fetch(threadApi(id, '/profile'));
			const data = await res.json();
			if (res.ok && data.profile) lines.push(`  profile   ${data.profile}`);
		} catch {
			/* no profile line */
		}
		if (t?.tokens != null && t.contextWindow != null && t.contextWindow > 0) {
			const percent = ((t.tokens / t.contextWindow) * 100).toFixed(1);
			lines.push(
				`  context   ${t.tokens.toLocaleString()} / ${t.contextWindow.toLocaleString()} tokens (${percent}%)`
			);
		} else {
			lines.push('  context   unavailable');
		}
		if (t?.goal) lines.push(`  goal      ${t.goal.objective} (${t.goal.status})`);
		try {
			const acc = await (await fetch(`/api/account${hostQuery(sessionHost(id))}`)).json();
			const a = acc.account;
			if (a) lines.push(`  account   ${a.email ?? a.type}${a.planType ? ` · ${a.planType}` : ''}`);
			for (const win of [acc.rateLimits?.primary, acc.rateLimits?.secondary]) {
				if (win) {
					const label = `${windowLabel(win.windowDurationMins)} limit`.padEnd(9);
					lines.push(`  ${label} ${win.usedPercent}% used · resets in ${fmtReset(win.resetsAt)}`);
				}
			}
			const credits = acc.rateLimits?.credits;
			if (credits && !credits.unlimited) lines.push(`  credits   ${credits.balance ?? '0'}`);
		} catch {
			lines.push('  (account info unavailable)');
		}
		return lines.join('\n');
	}

	function formatModelState(settings: ModelState): string {
		const lines = [`model: ${settings.model}`, `effort: ${settings.effort}`, '', 'available models'];
		for (const model of settings.models) {
			const efforts = model.efforts.length > 0 ? model.efforts.join(', ') : model.defaultEffort;
			lines.push(`  ${model.id.padEnd(24)} ${efforts}`);
		}
		lines.push('', 'usage: /model <model> [effort]');
		lines.push('       /model --effort <effort>');
		return lines.join('\n');
	}

	async function postCmd(id: string, path: string, body: unknown): Promise<any> {
		const res = await fetch(threadApi(id, `/${path}`), {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify(body ?? {})
		});
		return { ok: res.ok, data: await res.json().catch(() => ({})) };
	}

	async function handleSlash(id: string, text: string) {
		const parsed = parseSlash(text);
		addLocalNote(id, text);

		switch (parsed.kind) {
			case 'help':
				addLocalNote(id, SLASH_HELP);
				break;

			case 'status':
				addLocalNote(id, await buildStatus(id));
				break;

			case 'fast': {
				const enabled = !fastSessions[id];
				const { ok, data } = await postCmd(id, 'fast', { enabled });
				if (ok) setFastSession(id, Boolean(data.enabled));
				addLocalNote(
					id,
					ok ? `Fast mode ${data.enabled ? 'enabled' : 'disabled'}` : data.error ?? 'failed to change Fast mode',
					ok ? 'info' : 'err'
				);
				break;
			}

			case 'model-show': {
				try {
					const res = await fetch(threadApi(id, '/model'));
					const data = await res.json();
					if (res.ok) {
						const settings = data as ModelState;
						sessionConfigs[id] = {
							model: settings.model,
							effort: settings.effort,
							profile: sessionConfigs[id]?.profile ?? null
						};
					}
					addLocalNote(
						id,
						res.ok ? formatModelState(data as ModelState) : data.error ?? 'failed to read model settings',
						res.ok ? 'info' : 'err'
					);
				} catch {
					addLocalNote(id, 'failed to read model settings', 'err');
				}
				break;
			}

			case 'model-set': {
				const { ok, data } = await postCmd(id, 'model', {
					...(parsed.model ? { model: parsed.model } : {}),
					...(parsed.effort ? { effort: parsed.effort } : {})
				});
				addLocalNote(
					id,
					ok ? `model set: ${data.model} · effort ${data.effort}` : data.error ?? 'failed to change model settings',
					ok ? 'info' : 'err'
				);
				if (ok) {
					sessionConfigs[id] = {
						model: data.model,
						effort: data.effort,
						profile: sessionConfigs[id]?.profile ?? null
					};
				}
				break;
			}

			case 'profile-show': {
				try {
					const res = await fetch(threadApi(id, '/profile'));
					const data = await res.json();
					if (!res.ok) throw new Error(data.error);
					const lines = [`profile: ${data.profile ?? '(base config)'}`];
					const choices = (data.profiles ?? []) as ProfileChoice[];
					if (choices.length > 0) {
						lines.push('', 'available profiles');
						for (const p of choices) {
							lines.push(`  ${p.name.padEnd(24)} ${p.model ?? ''}`.trimEnd());
						}
					} else {
						lines.push('', 'no profiles found ($CODEX_HOME/<name>.config.toml)');
					}
					lines.push('', 'usage: /profile <name>', '       /profile clear');
					addLocalNote(id, lines.join('\n'));
				} catch {
					addLocalNote(id, 'failed to read profile', 'err');
				}
				break;
			}

			case 'profile-set': {
				const { ok, data } = await postCmd(id, 'profile', { profile: parsed.profile });
				addLocalNote(
					id,
					ok ? `profile set: ${data.profile}` : data.error ?? 'failed to set profile',
					ok ? 'info' : 'err'
				);
				if (ok) void loadSessionConfig(id);
				break;
			}

			case 'profile-clear': {
				const { ok, data } = await postCmd(id, 'profile', { clear: true });
				addLocalNote(
					id,
					ok ? 'profile cleared (base config)' : data.error ?? 'failed to clear profile',
					ok ? 'info' : 'err'
				);
				if (ok) void loadSessionConfig(id);
				break;
			}

			case 'goal-show': {
				let g = threads[id]?.goal;
				try {
					const res = await fetch(threadApi(id, '/goal'));
					const data = await res.json();
					if (res.ok) {
						g = (data.goal ?? null) as Goal | null;
						ensureThread(id).goal = g;
					}
				} catch {
					/* use locally cached goal */
				}
				addLocalNote(id, g ? `goal: ${g.objective} (${g.status})` : 'no goal set');
				break;
			}

			case 'goal-clear': {
				const { ok, data } = await postCmd(id, 'goal', { clear: true });
				if (ok) ensureThread(id).goal = null;
				addLocalNote(id, ok ? 'goal cleared' : data.error ?? 'failed to clear goal', ok ? 'info' : 'err');
				break;
			}

			case 'goal-set': {
				const body =
					parsed.tokenBudget === undefined
						? { objective: parsed.objective }
						: { objective: parsed.objective, tokenBudget: parsed.tokenBudget };
				const { ok, data } = await postCmd(id, 'goal', body);
				if (ok && data.goal) ensureThread(id).goal = data.goal as Goal;
				addLocalNote(
					id,
					ok ? `goal set: ${parsed.objective}` : data.error ?? 'failed to set goal',
					ok ? 'info' : 'err'
				);
				break;
			}

			case 'compact': {
				const t = ensureThread(id);
				t.status = 'running';
				const { ok, data } = await postCmd(id, 'compact', {});
				if (!ok) t.status = 'idle';
				addLocalNote(id, ok ? 'compacting history…' : data.error ?? 'failed to compact', ok ? 'info' : 'err');
				break;
			}

			case 'review': {
				const t = ensureThread(id);
				t.status = 'running';
				const { ok, data } = await postCmd(
					id,
					'review',
					parsed.instructions ? { instructions: parsed.instructions } : {}
				);
				if (!ok) {
					t.status = 'idle';
					addLocalNote(id, data.error ?? 'failed to start review', 'err');
				} else {
					addLocalNote(id, 'review started');
				}
				break;
			}

			case 'shell': {
				const t = ensureThread(id);
				t.status = 'running';
				const { ok, data } = await postCmd(id, 'shell', { command: parsed.command });
				if (!ok) t.status = 'idle';
				addLocalNote(id, ok ? 'shell command started' : data.error ?? 'failed to start shell command', ok ? 'info' : 'err');
				break;
			}

			case 'rollback': {
				const { ok, data } = await postCmd(id, 'rollback', { numTurns: parsed.numTurns });
				if (ok) {
					replaceItems(id, data.thread?.turns ?? []);
					addLocalNote(id, `rolled back ${parsed.numTurns} turn${parsed.numTurns === 1 ? '' : 's'}`);
				} else {
					addLocalNote(id, data.error ?? 'failed to roll back', 'err');
				}
				break;
			}

			case 'fork': {
				const { ok, data } = await postCmd(id, 'fork', {});
				if (ok && data.thread?.id) {
					upsertSession({ ...data.thread, host: data.host ?? sessionHost(id) });
					ensureThread(data.thread.id);
					addLocalNote(id, `forked into ${data.thread.id.slice(0, 8)}`);
					goto(`/s/${data.thread.id}${hostQuery(data.host ?? sessionHost(id))}`);
				} else {
					addLocalNote(id, data.error ?? 'failed to fork session', 'err');
				}
				break;
			}

			case 'btw': {
				if (isSideChat(sessions.find((s) => s.id === id))) {
					addLocalNote(id, 'already in a side conversation — go back first', 'err');
					break;
				}
				const { ok, data } = await postCmd(id, 'fork', {
					ephemeral: true,
					developerInstructions: BTW_DEVELOPER_INSTRUCTIONS
				});
				if (!ok || !data.thread?.id) {
					addLocalNote(id, data.error ?? 'failed to start side conversation', 'err');
					break;
				}
				const sideId: string = data.thread.id;
				sessionStorage.setItem(sideParentKey(sideId), id);
				upsertSession({
					...data.thread,
					forkedFromId: id,
					ephemeral: true,
					host: data.host ?? sessionHost(id)
				});
				ensureThread(sideId);
				addLocalNote(id, `side conversation started: ${sideId.slice(0, 8)}`);
				if (parsed.message) {
					const t = ensureThread(sideId);
					t.status = 'running';
					const res = await sendMessageWithRetries(sideId, parsed.message, []);
					if (!res.ok) {
						t.status = 'idle';
						const err = await res.json().catch(() => ({}));
						addLocalNote(sideId, err.error ?? 'failed to send message', 'err');
					}
				}
				goto(`/s/${sideId}${hostQuery(data.host ?? sessionHost(id))}`);
				break;
			}

			case 'archive': {
				const session = sessions.find((session) => session.id === id);
				if (session && isSideChat(session)) {
					const result = await closeSideChat(session);
					if (result.ok) {
						showArchiveNotice({ tone: 'info', message: `Deleted ${shortLabel(session)}` });
					} else {
						addLocalNote(id, result.error ?? 'failed to delete side conversation', 'err');
					}
					break;
				}
				const { ok, data } = await postCmd(id, 'archive', {});
				if (ok) {
					removeSession(id);
					if (activeId === id) goto('/');
				} else {
					addLocalNote(id, data.error ?? 'failed to archive session', 'err');
				}
				break;
			}

			default:
				addLocalNote(id, `unknown command: ${parsed.command} — try /help`, 'err');
		}
	}

	async function interrupt() {
		if (!activeId) return;
		const t = threads[activeId];
		await fetch(threadApi(activeId, '/interrupt'), {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({ turnId: t?.turnId })
		});
	}

	function showArchiveNotice(notice: ArchiveNotice, duration = 8000) {
		if (archiveNoticeTimer) clearTimeout(archiveNoticeTimer);
		archiveNotice = notice;
		archiveNoticeTimer = setTimeout(() => {
			archiveNotice = null;
			archiveNoticeTimer = null;
		}, duration);
	}

	async function deleteSession(id: string) {
		const session = sessions.find((s) => s.id === id);
		if (!session) return;
		const label = shortLabel(session);
		if (isSideChat(session)) {
			const result = await closeSideChat(session);
			if (!result.ok) {
				showArchiveNotice(
					{ tone: 'error', message: result.error ?? 'Could not delete the side conversation.' },
					6000
				);
				return;
			}
			showArchiveNotice({ tone: 'info', message: `Deleted ${label}` });
			return;
		}
		const snapshot: ArchivedSessionSnapshot = {
			id,
			label,
			index: sessions.findIndex((s) => s.id === id),
			summary: session,
			thread: threads[id],
			config: sessionConfigs[id],
			cwd: cwds[id]
		};
		const res = await fetch(threadApi(id, '/archive'), {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({})
		});
		if (!res.ok) {
			const data = await res.json().catch(() => ({}));
			showArchiveNotice({ tone: 'error', message: data.error ?? 'Could not archive the session.' }, 6000);
			return;
		}
		removeSession(id);
		showArchiveNotice({ tone: 'undo', message: `Archived ${label}`, snapshot });
		if (activeId === id) goto('/');
	}

	async function closeSideChat(
		session: ThreadSummary
	): Promise<{ ok: true } | { ok: false; error?: string }> {
		const res = await fetch(threadApi(session.id, '/unsubscribe'), {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({})
		});
		if (!res.ok) {
			const data = await res.json().catch(() => ({}));
			return { ok: false, error: data.error };
		}
		const wasActive = activeId === session.id;
		const parentId = session.forkedFromId;
		removeSession(session.id);
		if (wasActive) {
			await goto(parentId && sessions.some((item) => item.id === parentId) ? `/s/${parentId}` : '/');
		}
		return { ok: true };
	}

	async function undoArchivedSession() {
		const snapshot = archiveNotice?.snapshot;
		if (!snapshot) return;
		if (archiveNoticeTimer) clearTimeout(archiveNoticeTimer);
		archiveNoticeTimer = null;
		const res = await fetch(threadApi(snapshot.id, '/unarchive'), {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({})
		});
		if (!res.ok) {
			const data = await res.json().catch(() => ({}));
			showArchiveNotice({ tone: 'error', message: data.error ?? 'Could not restore the session.' }, 6000);
			return;
		}
		const data = await res.json().catch(() => ({}));
		if (snapshot.thread) threads[snapshot.id] = snapshot.thread;
		if (snapshot.config) sessionConfigs[snapshot.id] = snapshot.config;
		if (snapshot.cwd) cwds[snapshot.id] = snapshot.cwd;
		const restored = { ...snapshot.summary, ...(data.thread ?? {}) } as ThreadSummary;
		const next = sessions.filter((session) => session.id !== snapshot.id);
		next.splice(Math.min(Math.max(snapshot.index, 0), next.length), 0, restored);
		sessions = next;
		archiveNotice = null;
	}

	function onKeydown(e: KeyboardEvent) {
		// The slash popup owns its keys while visible (codex TUI precedence:
		// command popup before history navigation and submission).
		if (slashPopupVisible && handleSlashPopupKey(e)) return;
		// Mobile keyboards use Return for multiline composition; the adjacent
		// send button stays in thumb reach. Desktop keeps the fast Enter-to-send
		// convention, with Shift+Enter for a newline.
		if (e.key === 'Enter' && !e.shiftKey && !mobileViewport) {
			e.preventDefault();
			send();
			return;
		}
		if ((e.key === 'ArrowUp' || e.key === 'ArrowDown') && !e.isComposing) {
			handleHistoryNavigation(e);
		}
	}

	function handleSlashPopupKey(e: KeyboardEvent): boolean {
		if (e.isComposing) return false;
		const matches = slashMatches;
		const moveUp = (e.key === 'ArrowUp' && !e.ctrlKey) || (e.key === 'p' && e.ctrlKey);
		const moveDown = (e.key === 'ArrowDown' && !e.ctrlKey) || (e.key === 'n' && e.ctrlKey);
		if ((moveUp || moveDown) && !e.altKey && !e.metaKey && !e.shiftKey) {
			e.preventDefault();
			slashIndex = (slashIndex + (moveDown ? 1 : -1) + matches.length) % matches.length;
			void tick().then(() =>
				document
					.getElementById(slashOptionId(matches[slashIndex]))
					?.scrollIntoView({ block: 'nearest' })
			);
			return true;
		}
		if (e.key === 'Tab' && !e.shiftKey) {
			e.preventDefault();
			acceptSlashCompletion(matches[slashIndex], false);
			return true;
		}
		if (e.key === 'Enter' && !e.shiftKey) {
			// Enter runs the highlighted command, like the codex TUI.
			e.preventDefault();
			acceptSlashCompletion(matches[slashIndex], true);
			return true;
		}
		if (e.key === 'Escape') {
			// Dismiss without touching the draft; the popup stays hidden until
			// the typed command token changes.
			e.preventDefault();
			slashDismissedToken = slashToken;
			return true;
		}
		return false;
	}

	function slashOptionId(cmd: SlashCommandInfo): string {
		return `slash-option-${cmd.name.slice(1)}`;
	}

	function acceptSlashCompletion(cmd: SlashCommandInfo, submit: boolean) {
		slashDismissedToken = null;
		// Tab completion leaves a trailing space when the command takes
		// arguments, so typing continues naturally.
		input = submit ? cmd.name : cmd.name + (cmd.args ? ' ' : '');
		if (submit) {
			void send();
			return;
		}
		void tick().then(() => {
			if (!composerTextareaEl) return;
			composerTextareaEl.focus();
			resizeComposer();
			const end = composerTextareaEl.value.length;
			composerTextareaEl.setSelectionRange(end, end);
		});
	}

	// Prior user messages for a resumed thread, oldest first — the seed for
	// Up/Down recall (the codex TUI's replayed-submission history).
	function transcriptUserTexts(id: string): string[] {
		const t = threads[id];
		if (!t) return [];
		const texts: string[] = [];
		for (const itemId of t.order) {
			const item = t.byId[itemId] as any;
			if (item?.type !== 'userMessage') continue;
			const text = ((item.content ?? []) as any[])
				.map((c) => (typeof c?.text === 'string' ? c.text : ''))
				.filter(Boolean)
				.join('\n')
				.trim();
			if (text) texts.push(text);
		}
		return texts;
	}

	function composerHistoryOf(id: string): ComposerHistory {
		let history = composerHistories.get(id);
		if (!history) {
			history = new ComposerHistory();
			composerHistories.set(id, history);
		}
		if (history.isEmpty) history.seed(transcriptUserTexts(id));
		return history;
	}

	function handleHistoryNavigation(e: KeyboardEvent) {
		if (!activeId || !composerTextareaEl) return;
		if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return;
		// A live selection means the arrows should collapse it, not recall.
		if (composerTextareaEl.selectionStart !== composerTextareaEl.selectionEnd) return;

		const history = composerHistoryOf(activeId);
		if (!history.shouldHandleNavigation(input, composerTextareaEl.selectionStart)) return;

		const nav = e.key === 'ArrowUp' ? history.navigateUp() : history.navigateDown();
		if (nav.kind === 'ignored') return;
		e.preventDefault();
		input = nav.kind === 'recall' ? nav.text : '';
		// Recall places the caret at the end, like shell history.
		void tick().then(() => {
			if (!composerTextareaEl) return;
			resizeComposer();
			const end = composerTextareaEl.value.length;
			composerTextareaEl.setSelectionRange(end, end);
		});
	}

	function resizeComposer() {
		if (!composerTextareaEl) return;
		composerTextareaEl.style.height = 'auto';
		const maxHeight = Number.parseFloat(getComputedStyle(composerTextareaEl).maxHeight);
		const nextHeight = Math.min(composerTextareaEl.scrollHeight, maxHeight);
		composerTextareaEl.style.height = `${nextHeight}px`;
		composerTextareaEl.style.overflowY = composerTextareaEl.scrollHeight > maxHeight ? 'auto' : 'hidden';
	}

	$effect(() => {
		input;
		void tick().then(resizeComposer);
	});

	// Selection restarts at the top match whenever the typed token changes.
	$effect(() => {
		slashToken;
		slashIndex = 0;
	});

	function onCwdKeydown(e: KeyboardEvent) {
		if (e.key === 'Enter') {
			e.preventDefault();
			newSession(newCwd.trim() || undefined);
		} else if (e.key === 'Escape') {
			e.preventDefault();
			cancelCreating();
		}
	}

	function itemsOf(t: ThreadState | null): ThreadItem[] {
		if (!t) return [];
		return t.order.map((id) => t.byId[id]).filter(Boolean);
	}

	function isRenderableTranscriptItem(item: ThreadItem): boolean {
		return item.type !== 'reasoning' || Boolean(reasoningText(item));
	}

	function imageSrc(path: string): string {
		if (/^https?:\/\//i.test(path)) return path;
		return `/api/images?path=${encodeURIComponent(path)}`;
	}

	function imageLabel(path: string): string {
		return path.split('/').filter(Boolean).at(-1) ?? path;
	}

	function userParts(item: any): RenderPart[] {
		const parts: RenderPart[] = [];
		for (const c of item.content ?? []) {
			if (typeof c?.text === 'string' && c.text) parts.push({ type: 'text', text: c.text });
			if (c?.type === 'localImage' && typeof c.path === 'string') {
				parts.push({ type: 'image', path: c.path, source: 'local' });
			}
			if (c?.type === 'image' && typeof c.url === 'string') {
				parts.push({ type: 'image', path: c.url, source: 'remote' });
			}
		}
		return parts;
	}

	function agentParts(text: string): RenderPart[] {
		const parts: RenderPart[] = [];
		const re = /<agent-img>\s*([\s\S]*?)\s*<\/agent-img>/g;
		let last = 0;
		let match: RegExpExecArray | null;
		while ((match = re.exec(text))) {
			if (match.index > last) parts.push({ type: 'text', text: text.slice(last, match.index) });
			const path = match[1]?.trim();
			if (path) parts.push({ type: 'image', path, source: /^https?:\/\//i.test(path) ? 'remote' : 'local' });
			last = re.lastIndex;
		}
		if (last < text.length) parts.push({ type: 'text', text: text.slice(last) });
		return parts;
	}

	function chooseImages() {
		imageInputEl?.click();
	}

	function onImagesSelected(e: Event) {
		const files = Array.from((e.currentTarget as HTMLInputElement).files ?? []);
		selectedImages = [
			...selectedImages,
			...files
				.filter((file) => file.type.startsWith('image/'))
				.map((file) => ({ id: `${file.name}-${file.size}-${file.lastModified}-${Math.random()}`, file, name: file.name }))
		];
		if (imageInputEl) imageInputEl.value = '';
	}

	function removeSelectedImage(id: string) {
		selectedImages = selectedImages.filter((img) => img.id !== id);
	}

	async function openSessionInfo() {
		if (!sessionInfoDialog) return;
		sessionInfoDialog.showModal();
		await tick();
		sessionInfoDialog.focus();
	}

	function closeSessionInfoOnBackdrop(event: MouseEvent) {
		if (event.target === event.currentTarget) sessionInfoDialog?.close();
	}

	function reasoningText(item: any): string {
		if (item._reason) return item._reason;
		const s = item.summary;
		if (Array.isArray(s)) return s.map((x: any) => x?.text ?? '').join('\n');
		if (typeof s === 'string') return s;
		return '';
	}

	function shortLabel(s: ThreadSummary): string {
		if (s.name) return s.name;
		if (s.preview) return s.preview.slice(0, 48);
		return s.id.slice(0, 8);
	}

	function workspaceLabel(path: string | null | undefined): string {
		const normalized = path?.replace(/[\\/]+$/, '');
		return normalized?.split(/[\\/]/).pop() || 'Conversation';
	}

	function headerLabel(summary: ThreadSummary | null, id: string, cwd: string | undefined): string {
		if (summary?.name || summary?.preview) return shortLabel(summary);
		return cwd ? workspaceLabel(cwd) : id.slice(0, 8);
	}

	function isSideChat(s: ThreadSummary | null | undefined): boolean {
		return Boolean(s?.ephemeral);
	}

	function sideParentKey(sideId: string): string {
		return `yacwu:side:${sideId}`;
	}

	function sideChatsOf(parentId: string): ThreadSummary[] {
		return sessions.filter((s) => isSideChat(s) && s.forkedFromId === parentId);
	}

	function fileChangeKind(ch: any): string {
		const kind = ch?.kind;
		if (typeof kind === 'string' && kind.trim()) return kind;
		if (kind && typeof kind === 'object') {
			const label = kind.type ?? kind.kind ?? kind.action ?? kind.operation;
			if (typeof label === 'string' && label.trim()) return label;
			const keys = Object.keys(kind);
			if (keys.length === 1) return keys[0];
		}
		return 'changed';
	}

	function fileChangeClass(ch: any): string {
		return fileChangeKind(ch)
			.toLowerCase()
			.replace(/[^a-z0-9_-]+/g, '-')
			.replace(/^-|-$/g, '') || 'changed';
	}

	function fileChangePath(ch: any): string {
		const path = ch?.path;
		if (typeof path === 'string') return path;
		if (path && typeof path === 'object' && typeof path.path === 'string') return path.path;
		return String(path ?? '');
	}

	function fileChangeSymbol(ch: any): string {
		const kind = fileChangeKind(ch).toLowerCase();
		if (kind.includes('add') || kind.includes('create')) return '+';
		if (kind.includes('delete') || kind.includes('remove')) return '−';
		return '~';
	}

	function toggleFilesPanel() {
		if (filesOpen || changesOpen) {
			filesOpen = false;
			changesOpen = false;
			filesToggleEl?.focus();
		} else {
			filesOpen = true;
		}
	}

	function openFilesPanel() {
		changesOpen = false;
		filesOpen = true;
	}

	function closeFilesPanel() {
		filesOpen = false;
		filesToggleEl?.focus();
	}

	/** Open the file browser at a session-relative path, optionally on a line. */
	function openFileInBrowser(rel: string, line: number | null = null) {
		changesOpen = false;
		filesOpen = true;
		filesReveal = { path: rel, line, nonce: ++localCounter };
	}

	function openChangesPanel(path: string | null = null) {
		filesOpen = false;
		changesOpen = true;
		if (path) changesReveal = { path, nonce: ++localCounter };
	}

	function closeChangesPanel() {
		changesOpen = false;
		filesToggleEl?.focus();
	}

	/**
	 * The session-relative path (and optional line) to open when a code span
	 * in a Codex message looks like a workspace file, or null to leave it
	 * plain. Requires a directory separator so identifiers like
	 * `next.access_token` stay text; a `:line(:col)` suffix becomes the line
	 * to reveal; absolute paths must sit inside the session's working
	 * directory.
	 */
	function agentPathTarget(
		text: string,
		requireSeparator = true
	): { path: string; line: number | null } | null {
		if (!activeId) return null;
		let candidate = text.trim();
		try {
			candidate = decodeURIComponent(candidate);
		} catch {
			/* not URL-encoded — use as written */
		}
		let line: number | null = null;
		const withLine = candidate.match(/^(.*?):(\d+)(?::\d+)?$/);
		if (withLine) {
			candidate = withLine[1];
			line = Number(withLine[2]) || null;
		}
		if (candidate.startsWith('/')) {
			const cwd = (cwds[activeId] ?? activeSummary?.cwd)?.replace(/[\\/]+$/, '');
			if (!cwd || !candidate.startsWith(`${cwd}/`)) return null;
			candidate = candidate.slice(cwd.length + 1);
		} else if (candidate.startsWith('./')) {
			candidate = candidate.slice(2);
		}
		// Markdown link hrefs may name a single file; bare code spans need a
		// separator so ordinary identifiers stay plain.
		const pattern = requireSeparator
			? /^[\w.@+-]+(?:\/[\w.@+-]+)+$/
			: /^[\w.@+-]+(?:\/[\w.@+-]+)*$/;
		if (!pattern.test(candidate)) return null;
		// The character class admits dots, so rule out ".."-style segments.
		if (candidate.split('/').some((segment) => /^\.+$/.test(segment))) return null;
		return { path: candidate, line };
	}

	function displayFileChangePath(ch: any): string {
		const path = fileChangePath(ch);
		const cwd = activeId ? (cwds[activeId] ?? activeSummary?.cwd) : null;
		if (!cwd) return path;
		const root = cwd.replace(/[\\/]+$/, '');
		return path.startsWith(`${root}/`) ? path.slice(root.length + 1) : path;
	}

	function displayCommand(command: unknown): string {
		const text = String(command ?? '');
		const wrapped = text.match(/^(?:\/bin\/)?(?:ba|z|fi)?sh\s+-lc\s+([\s\S]+)$/);
		if (!wrapped) return text;
		const body = wrapped[1].trim();
		const quote = body[0];
		return (quote === '"' || quote === "'") && body.endsWith(quote) ? body.slice(1, -1) : body;
	}

	function commandStatusLabel(item: any): string {
		if (item.status === 'completed') {
			return item.exitCode === undefined || item.exitCode === null
				? 'Completed'
				: `Completed with exit code ${item.exitCode}`;
		}
		if (item.status === 'failed') {
			return item.exitCode === undefined || item.exitCode === null
				? 'Failed'
				: `Failed with exit code ${item.exitCode}`;
		}
		return 'In progress';
	}

	function commandOutput(item: any): string {
		return String(item._out || item.aggregatedOutput || '');
	}

	function commandOutputLineCount(output: string): number {
		if (!output) return 0;
		return output.endsWith('\n') ? output.slice(0, -1).split('\n').length : output.split('\n').length;
	}

	function commandOutputIsLong(output: string): boolean {
		return commandOutputLineCount(output) > COMMAND_OUTPUT_COLLAPSE_LINES || output.length > COMMAND_OUTPUT_COLLAPSE_CHARS;
	}

	function agentRawKey(item: any): string {
		return `${activeId ?? 'none'}:${String(item.id ?? '')}`;
	}

	function toggleAgentRaw(item: any) {
		const key = agentRawKey(item);
		agentRawShown[key] = !agentRawShown[key];
	}

	function agentTime(item: any): { label: string; iso: string; full: string } | null {
		const at = (item as any)._at;
		if (typeof at !== 'number') return null;
		const date = new Date(at);
		return {
			label: date.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' }),
			iso: date.toISOString(),
			full: date.toLocaleString()
		};
	}

	function onAgentMessageTap(item: any) {
		if (hoverPointer) return;
		tappedAgentKey = agentRawKey(item);
	}

	function onWindowClick(e: MouseEvent) {
		if (hoverPointer || tappedAgentKey === null) return;
		const target = e.target as Element | null;
		if (!target?.closest?.('.item.agent')) tappedAgentKey = null;
	}

	function commandOutputStateKey(item: any): string {
		return `${activeId ?? 'none'}:${String(item.id ?? '')}`;
	}

	function commandOutputIsExpanded(item: any, output: string): boolean {
		const saved = commandOutputExpanded[commandOutputStateKey(item)];
		if (saved !== undefined) return saved;
		return item.status === 'inProgress' || !commandOutputIsLong(output);
	}

	function toggleCommandOutput(item: any, output: string) {
		const key = commandOutputStateKey(item);
		commandOutputExpanded[key] = !commandOutputIsExpanded(item, output);
	}

	function commandOutputId(item: any): string {
		return `command-output-${commandOutputStateKey(item).replace(/[^a-zA-Z0-9_-]+/g, '-')}`;
	}

	function commandOutputCountLabel(output: string): string {
		const lines = commandOutputLineCount(output);
		if (lines === 1 && output.length > COMMAND_OUTPUT_COLLAPSE_CHARS) return `${output.length} chars`;
		return `${lines} ${lines === 1 ? 'line' : 'lines'}`;
	}

	function safeWebUrl(value: unknown): string | null {
		if (typeof value !== 'string' || !value) return null;
		try {
			const url = new URL(value);
			return url.protocol === 'http:' || url.protocol === 'https:' ? url.href : null;
		} catch {
			return null;
		}
	}

	function webSearchPresentation(item: any): {
		label: string;
		detail: string;
		href: string | null;
		resultCount: number;
	} {
		const action = item.action;
		const resultCount = Array.isArray(item.results) ? item.results.length : 0;
		if (!action) {
			return {
				label: 'Searching the web',
				detail: item.query || '',
				href: null,
				resultCount
			};
		}
		switch (action.type) {
			case 'search': {
				const detail =
					action.query ||
					(Array.isArray(action.queries) ? action.queries.filter(Boolean).join(', ') : '') ||
					item.query ||
					'';
				return { label: 'Searched the web for', detail, href: null, resultCount };
			}
			case 'openPage': {
				const detail = action.url || item.query || '';
				return { label: 'Opened', detail, href: safeWebUrl(action.url), resultCount };
			}
			case 'findInPage': {
				const pattern = action.pattern ? `“${action.pattern}”` : '';
				const url = action.url || '';
				return {
					label: 'Searched in page for',
					detail: [pattern, url].filter(Boolean).join(' · ') || item.query || '',
					href: null,
					resultCount
				};
			}
			default:
				return { label: 'Used web search', detail: item.query || '', href: null, resultCount };
		}
	}

	function subAgentActivityParts(item: any): { prefix: string; path: string } {
		const path = item.agentPath ?? item.agentThreadId ?? 'agent';
		switch (item.kind) {
			case 'started':
				return { prefix: 'Started', path };
			case 'interacted':
				return { prefix: 'Interacted with', path };
			case 'interrupted':
				return { prefix: 'Interrupted', path };
			default:
				return { prefix: 'Sub-agent activity:', path };
		}
	}

	function truncateText(text: string, max: number): string {
		return text.length > max ? text.slice(0, max).trimEnd() + '…' : text;
	}

	// Summaries mirror the Codex TUI's collab tool-call rows.
	function collabSummary(item: any): string {
		const receivers: string[] = item.receiverThreadIds ?? [];
		const target = receivers[0] ? receivers[0].slice(0, 8) : null;
		const inProgress = item.status === 'inProgress';
		switch (item.tool) {
			case 'spawnAgent':
				if (inProgress) return 'Spawning agent…';
				return target ? `Spawned agent ${target}` : 'Agent spawn failed';
			case 'sendInput':
				return `${inProgress ? 'Sending input to' : 'Sent input to'} ${target ?? 'agent'}`;
			case 'resumeAgent':
				return `${inProgress ? 'Resuming' : 'Resumed'} ${target ?? 'agent'}`;
			case 'wait':
				if (inProgress) {
					return receivers.length > 1
						? `Waiting for ${receivers.length} agents…`
						: `Waiting for ${target ?? 'agents'}…`;
				}
				return 'Finished waiting';
			case 'closeAgent':
				return `${inProgress ? 'Closing' : 'Closed'} ${target ?? 'agent'}`;
			default:
				return `agent tool: ${item.tool ?? 'unknown'}`;
		}
	}

	function collabAgentStates(item: any): Array<{ id: string; status: string; message: string | null }> {
		const states = item.agentsStates ?? {};
		return Object.entries(states).map(([id, state]: [string, any]) => ({
			id: id.slice(0, 8),
			status: state?.status ?? 'unknown',
			message: state?.message ?? null
		}));
	}

	onMount(() => {
		const mobileQuery = window.matchMedia('(max-width: 59.999rem)');
		const updateMobileViewport = () => {
			mobileViewport = mobileQuery.matches;
			if (!mobileViewport) mobileSidebarOpen = false;
		};
		const hoverQuery = window.matchMedia('(hover: hover) and (pointer: fine)');
		const updateHoverPointer = () => {
			hoverPointer = hoverQuery.matches;
			if (hoverPointer) tappedAgentKey = null;
		};
		updateHoverPointer();
		hoverQuery.addEventListener('change', updateHoverPointer);
		desktopSidebarHidden = localStorage.getItem('yacwu-sidebar-hidden') === 'true';
		try {
			const savedFastSessions = JSON.parse(localStorage.getItem(FAST_SESSIONS_KEY) ?? '[]');
			if (Array.isArray(savedFastSessions)) {
				fastSessions = Object.fromEntries(
					savedFastSessions.filter((id): id is string => typeof id === 'string').map((id) => [id, true])
				);
			}
		} catch {
			fastSessions = {};
		}
		updateMobileViewport();
		mobileQuery.addEventListener('change', updateMobileViewport);

		loadSessions();
		const es = new EventSource('/api/events');
		es.onopen = () => (connected = true);
		es.onerror = () => (connected = false);
		es.onmessage = (e) => {
			try {
				const msg = JSON.parse(e.data) as JsonRpcNotification;
				if (msg.method === 'yacwu/connected') {
					connected = true;
					return;
				}
				handleNotification(msg);
			} catch {
				/* ignore */
			}
		};
		return () => {
			es.close();
			if (archiveNoticeTimer) clearTimeout(archiveNoticeTimer);
			mobileQuery.removeEventListener('change', updateMobileViewport);
			hoverQuery.removeEventListener('change', updateHoverPointer);
		};
	});
</script>

<svelte:window onkeydown={onWindowKeydown} onclick={onWindowClick} />

{#snippet fastMark()}
	<span class="fast-mark" role="img" aria-label="Fast mode enabled" title="Fast mode enabled">
		<svg viewBox="0 0 16 16" aria-hidden="true" focusable="false">
			<path d="M9.1 1.5 3.7 8.7h3.6L6.8 14.5l5.5-7.4H8.7z" />
		</svg>
	</span>
{/snippet}

{#snippet commandResult(item: any)}
	<span
		class="cmd-result {item.status}"
		role="img"
		aria-label={commandStatusLabel(item)}
		title={commandStatusLabel(item)}
	>
		{#if item.status === 'completed'}
			<svg viewBox="0 0 16 16" aria-hidden="true"><path d="m3 8 3 3 7-7" /></svg>
		{:else if item.status === 'failed'}
			<svg viewBox="0 0 16 16" aria-hidden="true"><path d="m4 4 8 8M12 4l-8 8" /></svg>
		{:else}
			<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M2 8h3l2-4 3 8 2-4h2" /></svg>
		{/if}
	</span>
{/snippet}

{#snippet markdownInlines(tokens: MarkdownInline[])}
	{#each tokens as token}
		{#if token.type === 'text'}
			{token.text}
		{:else if token.type === 'strong'}
			<strong>{@render markdownInlines(token.children)}</strong>
		{:else if token.type === 'em'}
			<em>{@render markdownInlines(token.children)}</em>
		{:else if token.type === 'del'}
			<del>{@render markdownInlines(token.children)}</del>
		{:else if token.type === 'code'}
			{@const pathTarget = agentPathTarget(token.text)}
			{#if pathTarget !== null}
				<button
					type="button"
					class="code-path"
					title={pathTarget.line ? `Open in file browser at line ${pathTarget.line}` : 'Open in file browser'}
					onclick={() => openFileInBrowser(pathTarget.path, pathTarget.line)}
				><code>{token.text}</code></button>
			{:else}
				<code>{token.text}</code>
			{/if}
		{:else if token.type === 'break'}
			<br />
		{:else if token.type === 'link'}
			{#if token.href}
				{@const fileTarget = token.external ? null : agentPathTarget(token.href, false)}
				{#if fileTarget !== null}
					<button
						type="button"
						class="link-path"
						title={fileTarget.line
							? `Open ${fileTarget.path} at line ${fileTarget.line}`
							: `Open ${fileTarget.path} in file browser`}
						onclick={() => openFileInBrowser(fileTarget.path, fileTarget.line)}
					>{@render markdownInlines(token.children)}</button>
				{:else}
					<a
						href={token.href}
						title={token.title ?? undefined}
						target={token.external ? '_blank' : undefined}
						rel={token.external ? 'noreferrer noopener' : undefined}
					>{@render markdownInlines(token.children)}</a>
				{/if}
			{:else}
				{@render markdownInlines(token.children)}
			{/if}
		{:else if token.type === 'image'}
			{#if token.src}
				<img class="markdown-image" src={token.src} alt={token.alt} title={token.title ?? undefined} loading="lazy" />
			{:else}
				<span>{token.alt}</span>
			{/if}
		{/if}
	{/each}
{/snippet}

{#snippet markdownBlocks(blocks: MarkdownBlock[])}
	{#each blocks as block}
		{#if block.type === 'paragraph'}
			<p>{@render markdownInlines(block.children)}</p>
		{:else if block.type === 'heading'}
			<div class="markdown-heading" role="heading" aria-level={Math.min(block.depth, 6)}>
				<span class="markdown-hash" aria-hidden="true">{'#'.repeat(Math.min(block.depth, 6))}</span>
				<strong>{@render markdownInlines(block.children)}</strong>
			</div>
		{:else if block.type === 'code'}
			<div class="markdown-code">
				{#if block.language}<span class="markdown-language">{block.language}</span>{/if}
				<pre><code>{block.text}</code></pre>
			</div>
		{:else if block.type === 'blockquote'}
			<blockquote>{@render markdownBlocks(block.children)}</blockquote>
		{:else if block.type === 'list'}
			{#if block.ordered}
				<ol start={block.start ?? 1}>
					{#each block.items as item}
						<li class:task={item.checked !== null}>
							{#if item.checked !== null}<input type="checkbox" checked={item.checked} disabled aria-label={item.checked ? 'Completed' : 'Not completed'} />{/if}
							{@render markdownBlocks(item.children)}
						</li>
					{/each}
				</ol>
			{:else}
				<ul>
					{#each block.items as item}
						<li class:task={item.checked !== null}>
							{#if item.checked !== null}<input type="checkbox" checked={item.checked} disabled aria-label={item.checked ? 'Completed' : 'Not completed'} />{/if}
							{@render markdownBlocks(item.children)}
						</li>
					{/each}
				</ul>
			{/if}
		{:else if block.type === 'table'}
			<div class="markdown-table-wrap">
				<table>
					<thead>
						<tr>
							{#each block.header as cell}
								<th class:align-center={cell.align === 'center'} class:align-right={cell.align === 'right'}>{@render markdownInlines(cell.children)}</th>
							{/each}
						</tr>
					</thead>
					<tbody>
						{#each block.rows as row}
							<tr>
								{#each row as cell}
									<td class:align-center={cell.align === 'center'} class:align-right={cell.align === 'right'}>{@render markdownInlines(cell.children)}</td>
								{/each}
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
		{:else if block.type === 'rule'}
			<hr />
		{/if}
	{/each}
{/snippet}

<div class="app" class:sidebar-open={mobileSidebarOpen} class:rail-hidden={desktopSidebarHidden}>
	{#if !activeId && !mobileSidebarOpen}
		<button
			class="sidebar-toggle welcome-menu"
			bind:this={sidebarToggleEl}
			aria-controls="session-sidebar"
			aria-label={sessionRailToggleLabel}
			aria-expanded={sessionRailOpen}
			onclick={toggleSidebar}
		>
			<svg class="control-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
				{#if mobileSidebarOpen}
					<path d="M6 6l12 12M18 6 6 18" />
				{:else if !mobileViewport}
					<rect x="3.5" y="4.5" width="17" height="15" rx="1.5" />
					<path d="M9 5v14M12 9l3 3-3 3" />
				{:else}
					<path d="M4 7h16M4 12h16M4 17h16" />
				{/if}
			</svg>
		</button>
	{/if}
	<button
		class="sidebar-scrim"
		aria-label="Close sessions"
		aria-hidden={!mobileSidebarOpen}
		disabled={!mobileSidebarOpen}
		onclick={() => closeSidebar()}
	></button>

	<aside
		id="session-sidebar"
		class="sidebar"
		class:open={mobileSidebarOpen}
		bind:this={sidebarEl}
		inert={(mobileViewport && !mobileSidebarOpen) || (!mobileViewport && desktopSidebarHidden)}
	>
		<div class="brand">
			<button
				class="drawer-close"
				type="button"
				onclick={toggleSidebar}
				aria-controls="session-sidebar"
				aria-expanded={sessionRailOpen}
				aria-label={sessionRailToggleLabel}
				title={sessionRailToggleLabel}
			>
				<svg class="control-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
					{#if mobileViewport}
						<path d="M6 6l12 12M18 6 6 18" />
					{:else}
						<rect x="3.5" y="4.5" width="17" height="15" rx="1.5" />
						<path d="M9 5v14M15 9l-3 3 3 3" />
					{/if}
				</svg>
			</button>
			<span class="connection" title={connected ? 'Connected to Codex' : 'Disconnected from Codex'}>
				<span class="dot" class:on={connected}></span>
				<span>{connected ? 'Online' : 'Offline'}</span>
			</span>
		</div>
		{#if creating}
			<div class="create" role="group" aria-labelledby="create-title">
				<div class="create-heading">
					<h2 id="create-title">Start a session</h2>
					<button class="mini ghost" onclick={cancelCreating}>Cancel</button>
				</div>
				{#if hostChoices.length > 1}
					<div class="create-row">
						<label for="new-host">Machine</label>
						<select id="new-host" class="profile-input" bind:value={newHost} onchange={onNewHostChange}>
							{#each hostChoices as h (h.name)}
								<option value={h.name}>
									{h.name === LOCAL_HOST ? 'This machine' : h.name}{h.kind === 'remote' &&
									(hostStates[h.name] ?? h.state) !== 'disconnected'
										? ` · ${hostStates[h.name] ?? h.state}`
										: ''}
								</option>
							{/each}
						</select>
					</div>
				{/if}
				<div class="create-row">
					<label for="new-cwd">Working directory</label>
					<input
						id="new-cwd"
						class="cwd-input"
						bind:this={cwdInputEl}
						bind:value={newCwd}
						onkeydown={onCwdKeydown}
						placeholder={(isRemoteHost(newHost) ? hostDefaultCwds[newHost] : defaultCwd) ||
							'/path/to/project'}
						aria-invalid={Boolean(createError)}
						aria-describedby="create-helper"
						spellcheck="false"
						autocapitalize="off"
						autocomplete="off"
					/>
				</div>
				{#if profileChoices.length > 0 && !isRemoteHost(newHost)}
					<div class="create-row">
						<label for="new-profile">Profile</label>
						<select id="new-profile" class="profile-input" bind:value={newProfile}>
							<option value="">Base configuration</option>
							{#each profileChoices as p (p.name)}
								<option value={p.name}>{p.name}{p.model ? ` · ${p.model}` : ''}</option>
							{/each}
						</select>
					</div>
				{/if}
				<div class="create-actions">
					<button class="mini" onclick={() => newSession(newCwd.trim() || undefined)}>Start session</button>
				</div>
				{#if createError}
					<div id="create-helper" class="create-err" role="alert">{createError}</div>
				{:else}
					<span id="create-helper" class="create-hint">Leave blank to use the default directory.</span>
				{/if}
			</div>
		{:else}
			<div class="rail-heading">
				<span>Sessions</span>
				<button class="new" type="button" onclick={startCreating} aria-label="New session" title="New session">
					<svg class="control-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
						<path d="M12 5v14" />
						<path d="M5 12h14" />
					</svg>
				</button>
			</div>
		{/if}
		<nav class="sessions" data-loaded={sessionsLoaded}>
			{#each topSessions as s (s.id)}
				<div class="session-row">
					<a
						class="session"
						class:active={s.id === activeId}
						data-id={s.id}
						href={`/s/${s.id}${hostQuery(s.host)}`}
						onclick={() => closeSidebar(false)}
					>
						<span
							class="run-dot"
							class:running={threads[s.id]?.status === 'running'}
							class:error={Boolean(threads[s.id]?.error)}
							role="img"
							aria-label={threads[s.id]?.error ? 'Error' : threads[s.id]?.status === 'running' ? 'Running' : 'Idle'}
							title={threads[s.id]?.error ? 'Error' : threads[s.id]?.status === 'running' ? 'Running' : 'Idle'}
						></span>
						<span class="label">{#if isSideChat(s)}⎇ {/if}{shortLabel(s)}</span>
						{#if isRemoteHost(s.host)}
							<span class="host-badge" title={`Runs on ${s.host}`}>{s.host}</span>
						{/if}
						{#if fastSessions[s.id]}{@render fastMark()}{/if}
					</a>
					<button
						class="delete-session"
						type="button"
						aria-label={`delete session ${shortLabel(s)}`}
						title="Delete session"
						onclick={() => deleteSession(s.id)}
					>
						<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
							<path d="M4 7h16M9 7V4h6v3M7 7l1 13h8l1-13M10 11v5M14 11v5" />
						</svg>
					</button>
				</div>
				{#each sideChatsOf(s.id) as side (side.id)}
					<div class="session-row side-row">
						<a
							class="session side"
							class:active={side.id === activeId}
							data-id={side.id}
							href={`/s/${side.id}${hostQuery(side.host)}`}
							onclick={() => closeSidebar(false)}
						>
							<span
								class="run-dot"
								class:running={threads[side.id]?.status === 'running'}
								class:error={Boolean(threads[side.id]?.error)}
								role="img"
								aria-label={threads[side.id]?.error ? 'Error' : threads[side.id]?.status === 'running' ? 'Running' : 'Idle'}
								title={threads[side.id]?.error ? 'Error' : threads[side.id]?.status === 'running' ? 'Running' : 'Idle'}
							></span>
							<span class="label">⎇ {shortLabel(side)}</span>
							{#if fastSessions[side.id]}{@render fastMark()}{/if}
						</a>
						<button
							class="delete-session"
							type="button"
							aria-label={`delete session ${shortLabel(side)}`}
							title="Delete session"
							onclick={() => deleteSession(side.id)}
						>
							<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
								<path d="M4 7h16M9 7V4h6v3M7 7l1 13h8l1-13M10 11v5M14 11v5" />
							</svg>
						</button>
					</div>
				{/each}
			{:else}
				<div class="empty">
					<strong>No sessions yet</strong>
					<span>Start one to begin working with Codex.</span>
				</div>
			{/each}
		</nav>
		<div class="hint">
			<span>{topSessions.length} session{topSessions.length === 1 ? '' : 's'}</span>
		</div>
	</aside>

	<main class="chat">
		{#if !activeId}
			<div class="welcome">
				<div class="welcome-copy">
					<h1>Work through the hard parts.</h1>
					<p>
						Start a Codex session in any project, follow the work as it happens, and return to the
						conversation when you need it.
					</p>
					<button class="welcome-action" onclick={startCreating}>
						Start a session <span aria-hidden="true">→</span>
					</button>
				</div>
				<div class="welcome-details" aria-label="yacwu capabilities">
					<div>
						<strong>Keep context close</strong>
						<span>Move between persistent sessions without losing the thread.</span>
					</div>
					<div>
						<strong>See the work</strong>
						<span>Messages, commands, plans, and file changes arrive as they happen.</span>
					</div>
					<div>
						<strong>Stay in control</strong>
						<span>Set goals, switch models, fork conversations, or interrupt a running turn.</span>
					</div>
				</div>
			</div>
		{:else}
			<header class="topbar">
				<button
					class="sidebar-toggle header-menu"
					bind:this={sidebarToggleEl}
					aria-controls="session-sidebar"
					aria-label={sessionRailToggleLabel}
					aria-expanded={sessionRailOpen}
					onclick={toggleSidebar}
				>
					<svg class="control-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
						{#if mobileViewport && mobileSidebarOpen}
							<path d="M6 6l12 12M18 6 6 18" />
						{:else if !mobileViewport}
							<rect x="3.5" y="4.5" width="17" height="15" rx="1.5" />
							<path d="M9 5v14M12 9l3 3-3 3" />
						{:else}
							<path d="M4 7h16M4 12h16M4 17h16" />
						{/if}
					</svg>
				</button>
				<div class="session-heading">
					<h1>{headerLabel(activeSummary, activeId, cwds[activeId] ?? activeSummary?.cwd)}</h1>
					<div class="session-meta">
						{#if activeParent}
							<span class="tid dim">From {activeParent.id.slice(0, 8)}</span>
							<span class="meta-sep" aria-hidden="true">·</span>
						{/if}
						<span class="tid">{activeId.slice(0, 8)}</span>
						{#if cwds[activeId] ?? activeSummary?.cwd}
							<span class="meta-sep" aria-hidden="true">·</span>
							<span class="meta cwd" title={cwds[activeId] ?? activeSummary?.cwd}>{cwds[activeId] ?? activeSummary?.cwd}</span>
						{/if}
					</div>
				</div>
				<div class="session-facts" aria-label="session configuration">
					{#if fastSessions[activeId]}{@render fastMark()}{/if}
					{#if activeRemote}
						<span
							class="fact host"
							class:degraded={activeHostState !== 'connected'}
							title={activeHostState === 'connected'
								? `Session runs on ${activeHost}`
								: `Connection to ${activeHost} interrupted — the remote session keeps running; reconnecting`}
						>
							{activeHost}{activeHostState === 'connected' ? '' : ` · ${activeHostState}`}
						</span>
					{/if}
					{#if activeConfig?.model}
						<span class="fact model" title={`Model ${activeConfig.model}, ${activeConfig.effort} reasoning`}>
							{activeConfig.model}<span class="fact-detail">/{activeConfig.effort}</span>
						</span>
					{/if}
					{#if activeConfig?.profile}
						<span class="fact profile" title={`Profile ${activeConfig.profile}`}>{activeConfig.profile}</span>
					{/if}
					{#if active?.tokens}
						<span class="fact tokens" title={`${active.tokens.toLocaleString()} tokens used`}>{fmtTokens(active.tokens)} tok</span>
					{/if}
				</div>
				<div class="session-state">
					{#if !activeRemote}
					<button
						class="files-trigger"
						type="button"
						bind:this={filesToggleEl}
						onclick={toggleFilesPanel}
						aria-pressed={filesOpen || changesOpen}
						aria-label={filesOpen || changesOpen ? 'Close workspace inspector' : 'Open workspace inspector'}
						title={filesOpen || changesOpen ? 'Close workspace inspector' : 'Files and changes'}
					>
						<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
							<path d="M3.5 6.5a1.5 1.5 0 0 1 1.5-1.5h4l2 2.5h8a1.5 1.5 0 0 1 1.5 1.5v9a1.5 1.5 0 0 1-1.5 1.5H5a1.5 1.5 0 0 1-1.5-1.5z" />
						</svg>
					</button>
					{/if}
					<button
						class="session-info-trigger"
						type="button"
						onclick={openSessionInfo}
						aria-label={`Session details, ${active?.error ? 'error' : active?.status === 'running' ? 'running' : 'idle'}`}
						title={`Session details · ${active?.error ? 'Error' : active?.status === 'running' ? 'Running' : 'Idle'}`}
					>
						<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
							<circle cx="12" cy="12" r="9" />
							<path d="M12 11v6" />
							<circle cx="12" cy="7.5" r=".75" class="info-dot" />
						</svg>
						<span
							class="session-state-dot"
							class:running={active?.status === 'running'}
							class:error={Boolean(active?.error)}
							aria-hidden="true"
						></span>
					</button>
					{#if active?.status === 'running'}
						<button class="stop" type="button" onclick={interrupt} aria-label="Stop current turn" title="Stop current turn">
							<svg class="stop-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
								<rect x="7" y="7" width="10" height="10" rx="1" />
							</svg>
						</button>
					{/if}
				</div>
			</header>

			{#if filesOpen}
				{#key activeId}
					<FileBrowser
						threadId={activeId}
						cwd={cwds[activeId] ?? activeSummary?.cwd ?? ''}
						reveal={filesReveal}
						refreshNonce={filesRefresh}
						onchanges={() => openChangesPanel()}
						onclose={closeFilesPanel}
					/>
				{/key}
			{/if}

			{#if changesOpen}
				{#key activeId}
					<GitDiffViewer
						threadId={activeId}
						cwd={cwds[activeId] ?? activeSummary?.cwd ?? ''}
						reveal={changesReveal}
						refreshNonce={filesRefresh}
						onfiles={openFilesPanel}
						onviewfile={(path) => openFileInBrowser(path)}
						onclose={closeChangesPanel}
					/>
				{/key}
			{/if}

			<dialog
				class="session-info-dialog"
				bind:this={sessionInfoDialog}
				aria-labelledby="session-info-title"
				tabindex="-1"
				onclick={closeSessionInfoOnBackdrop}
			>
				<div class="session-info-panel">
					<div class="session-info-heading">
						<h2 id="session-info-title">Session details</h2>
						<button class="session-info-close" type="button" onclick={() => sessionInfoDialog?.close()} aria-label="Close session details" title="Close">
							<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
								<path d="M6 6l12 12M18 6 6 18" />
							</svg>
						</button>
					</div>
					<dl class="session-info-list">
						<div>
							<dt>Session</dt>
							<dd>{activeId}</dd>
						</div>
						<div>
							<dt>Directory</dt>
							<dd>{cwds[activeId] ?? activeSummary?.cwd ?? '—'}</dd>
						</div>
						<div>
							<dt>Last modified</dt>
							<dd>
								<time datetime={sessionTimestampIso(activeSummary?.updatedAt)}>{fmtSessionTimestamp(activeSummary?.updatedAt)}</time>
							</dd>
						</div>
						<div>
							<dt>Model</dt>
							<dd>{activeConfig?.model ?? '—'}</dd>
						</div>
						<div>
							<dt>Reasoning</dt>
							<dd>{activeConfig?.effort ?? '—'}</dd>
						</div>
						<div>
							<dt>Profile</dt>
							<dd>{activeConfig?.profile ?? 'Base configuration'}</dd>
						</div>
						<div>
							<dt>Fast mode</dt>
							<dd>{fastSessions[activeId] ? 'Enabled' : 'Disabled'}</dd>
						</div>
						<div>
							<dt>Tokens</dt>
							<dd>{active?.tokens?.toLocaleString() ?? '—'}</dd>
						</div>
						<div>
							<dt>State</dt>
							<dd>{active?.status ?? 'idle'}</dd>
						</div>
						{#if activeParent}
							<div>
								<dt>Parent</dt>
								<dd>{activeParent.id}</dd>
							</div>
						{/if}
					</dl>
				</div>
			</dialog>

			{#if activeIsSide}
				<div class="side-banner">
					<span class="side-banner-label">Side conversation · ephemeral — not saved</span>
					<span class="spacer"></span>
					{#if activeParent}
						<button class="mini ghost" onclick={() => goto(`/s/${activeParent.id}`)}>
							← {shortLabel(activeParent)}
						</button>
					{:else}
						<span class="meta">parent unavailable</span>
					{/if}
				</div>
			{/if}

			{#if active?.goal}
				<div class="goal-tracker" aria-label="active goal">
					<div class="goal-main">
						<span class="goal-marker">◎</span>
						<span class="goal-objective" title={active.goal.objective}>{active.goal.objective}</span>
						<span class="goal-state">{active.goal.status}</span>
					</div>
					<div class="goal-metrics">
						{#if active.goal.tokenBudget}
							<div class="goal-progress" aria-label={`${goalBudgetPercent(active.goal)}% of token budget used`}>
								<span style={`width: ${goalBudgetPercent(active.goal)}%`}></span>
							</div>
							<span
								>{fmtTokens(active.goal.tokensUsed)} / {fmtTokens(active.goal.tokenBudget)}
								tok</span
							>
						{:else}
							<span>{fmtTokens(active.goal.tokensUsed)} tok</span>
						{/if}
						<span>{fmtDuration(active.goal.timeUsedSeconds ?? 0)}</span>
					</div>
				</div>
			{/if}

			{#if conflict && conflict.id === activeId}
				<div class="conflict">
					<div class="conflict-head">Session already open elsewhere</div>
					<div class="conflict-body">
						This conversation's rollout is open in
						{#each conflict.holders as h, i}{i > 0 ? ', ' : ' '}<code>{h.command} (pid {h.pid})</code>{/each}.
						Opening it here too can corrupt its history. Close the other instance first, or accept the risk.
					</div>
					<div class="conflict-actions">
						<button class="mini danger" onclick={forceOpen}>Open anyway</button>
						<button class="mini ghost" onclick={dismissConflict}>Cancel</button>
					</div>
				</div>
			{:else}
				<div class="transcript" bind:this={transcriptEl} onscroll={onTranscriptScroll}>
					{#if loadingHistory}
						<div class="sys">loading history…</div>
					{:else if activeItems.length === 0 && active?.status !== 'running' && !active?.error}
						<div class="transcript-empty">
							<p class="transcript-empty-lede">This session is ready.</p>
							<p class="transcript-empty-hint">
								Describe what you want done in
								<strong>{workspaceLabel(cwds[activeId] ?? activeSummary?.cwd)}</strong>, or type
								<code>/</code> for a command.
							</p>
						</div>
					{/if}
					<div class="transcript-spacer" style={`height: ${virtualTranscript.before}px`}></div>
					{#each virtualTranscript.items as item (item.id)}
						<div class="virtual-row" use:measureTranscriptRow={transcriptRowKey(item)}>
							{#if item.type === 'userMessage'}
								<div class="item user">
									<div class="body media-body">
										{#each userParts(item) as part}
											{#if part.type === 'text'}
												<span>{part.text}</span>
											{:else}
												<a class="message-image" href={imageSrc(part.path)} target="_blank" rel="noreferrer">
													<img src={imageSrc(part.path)} alt={imageLabel(part.path)} loading="lazy" />
													<span>{imageLabel(part.path)}</span>
												</a>
											{/if}
										{/each}
									</div>
								</div>
							{:else if item.type === 'agentMessage'}
								{@const rawShown = Boolean(agentRawShown[agentRawKey(item)])}
								{@const time = agentTime(item)}
								<!-- The tap handler is a touch-only hover surrogate; keyboard
								     users reach the toggle directly via focus. -->
								<!-- svelte-ignore a11y_no_static_element_interactions, a11y_click_events_have_key_events -->
								<div
									class="item agent"
									class:tapped={tappedAgentKey === agentRawKey(item)}
									onclick={() => onAgentMessageTap(item)}
								>
									<div class="body media-body">
									{#if rawShown}
										<pre class="agent-raw">{(item as any).text ?? ''}</pre>
									{:else}
										{#each agentParts((item as any).text ?? '') as part}
											{#if part.type === 'text'}
												<div class="markdown-body">{@render markdownBlocks(parseCodexMarkdown(part.text))}</div>
											{:else}
												<a class="message-image" href={imageSrc(part.path)} target="_blank" rel="noreferrer">
													<img src={imageSrc(part.path)} alt={imageLabel(part.path)} loading="lazy" />
													<span>{imageLabel(part.path)}</span>
												</a>
											{/if}
										{/each}
									{/if}
									</div>
									<div class="agent-meta">
										{#if time}
											<time class="agent-time" datetime={time.iso} title={time.full}>{time.label}</time>
										{/if}
										<button
											type="button"
											class="raw-toggle"
											aria-pressed={rawShown}
											aria-label={rawShown ? 'Show rendered Markdown' : 'Show raw Markdown'}
											title={rawShown ? 'Show rendered Markdown' : 'Show raw Markdown'}
											onclick={() => toggleAgentRaw(item)}
										>
											<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
												{#if rawShown}
													<path d="M4 7h16M4 12h10M4 17h13" />
												{:else}
													<path d="m9 8-4 4 4 4M15 8l4 4-4 4" />
												{/if}
											</svg>
										</button>
									</div>
								</div>
							{:else if item.type === 'reasoning'}
								{#if reasoningText(item)}
									<div class="item reason">
										<span class="gutter">∴</span>
										<div class="body">{reasoningText(item)}</div>
									</div>
								{/if}
							{:else if item.type === 'commandExecution'}
								{@const output = commandOutput(item)}
								{@const outputExpanded = commandOutputIsExpanded(item, output)}
								<div class="item cmd">
									{#if output}
										<button
											type="button"
											class="cmd-line cmd-toggle"
											aria-expanded={outputExpanded}
											aria-controls={commandOutputId(item)}
											title={outputExpanded ? 'Collapse command output' : 'Expand command output'}
											onclick={() => toggleCommandOutput(item, output)}
										>
											<span class="gutter">$</span>
											<span class="cmd-text">{displayCommand((item as any).command)}</span>
											<span class="cmd-meta">
												{#if commandOutputIsLong(output)}
													<span class="cmd-output-count">{commandOutputCountLabel(output)}</span>
												{/if}
												{@render commandResult(item)}
												<svg class="cmd-disclosure" class:expanded={outputExpanded} viewBox="0 0 16 16" aria-hidden="true"><path d="m6 3.5 4.5 4.5L6 12.5" /></svg>
											</span>
										</button>
										<div id={commandOutputId(item)} class="cmd-output-region" hidden={!outputExpanded}>
											{#if outputExpanded}<pre class="cmd-out">{output}</pre>{/if}
										</div>
									{:else}
										<div class="cmd-line">
											<span class="gutter">$</span>
											<span class="cmd-text">{displayCommand((item as any).command)}</span>
											<span class="cmd-meta">{@render commandResult(item)}</span>
										</div>
									{/if}
								</div>
							{:else if item.type === 'fileChange'}
								<div class="item file">
									<div class="body">
										{#each (item as any).changes ?? [] as ch}
											{@const rel = displayFileChangePath(ch)}
											<div class="fc">
												<span class="kind {fileChangeClass(ch)}" aria-label={fileChangeKind(ch)} title={fileChangeKind(ch)}>{fileChangeSymbol(ch)}</span>
												{#if !rel.startsWith('/')}
													<button
														type="button"
														class="path path-link"
														title="Review current diff"
														onclick={() => openChangesPanel(rel)}
													>{rel}</button>
												{:else}
													<span class="path">{rel}</span>
												{/if}
											</div>
										{/each}
									</div>
								</div>
							{:else if item.type === 'webSearch'}
								{@const search = webSearchPresentation(item)}
								<div class="item web-search">
									<span class="gutter web-search-icon" aria-hidden="true">
										<svg viewBox="0 0 16 16" focusable="false">
											<circle cx="7" cy="7" r="4.25" />
											<path d="m10.25 10.25 3 3" />
										</svg>
									</span>
									<div class="body">
										<span>{search.label}</span>{#if search.detail}
											{' '}{#if search.href}<a href={search.href} target="_blank" rel="noreferrer noopener">{search.detail}</a>{:else}<span class="web-search-detail">{search.detail}</span>{/if}
										{/if}{#if search.resultCount > 0}<span class="web-search-count"> · {search.resultCount} {search.resultCount === 1 ? 'result' : 'results'}</span>{/if}
									</div>
								</div>
							{:else if item.type === 'plan'}
								<div class="item plan">
									<span class="gutter">◇</span>
									<div class="body">
										{#if (item as any).plan}
											{#each (item as any).plan as step}
												<div class="step {step.status}">[{step.status === 'completed' ? '✓' : step.status === 'inProgress' ? '~' : ' '}] {step.step}</div>
											{/each}
										{:else}{(item as any).text}{/if}
									</div>
								</div>
							{:else if item.type === 'localNote'}
								<div class="item note {(item as any).tone}">
									<span class="gutter">/</span>
									<div class="body">{(item as any).text}</div>
								</div>
							{:else if item.type === 'enteredReviewMode'}
								<div class="item note">
									<span class="gutter">⚑</span>
									<div class="body">review started: {(item as any).review}</div>
								</div>
							{:else if item.type === 'exitedReviewMode'}
								<div class="item review">
									<span class="gutter">⚑</span>
									<div class="body">{(item as any).review}</div>
								</div>
							{:else if item.type === 'contextCompaction'}
								<div class="item note">
									<span class="gutter">⤳</span>
									<div class="body">history compacted</div>
								</div>
							{:else if item.type === 'subAgentActivity'}
								{@const activity = subAgentActivityParts(item)}
								<div class="item subagent" title={`agent thread ${(item as any).agentThreadId ?? ''}`}>
									<span class="gutter">⎇</span>
									<div class="body">{activity.prefix} <span class="agent-path">{activity.path}</span></div>
								</div>
							{:else if item.type === 'collabAgentToolCall'}
								<div class="item collab">
									<div class="collab-line">
										<span class="gutter">⇄</span>
										<span class="collab-text">{collabSummary(item)}</span>
										<span class="cmd-status {(item as any).status}">{(item as any).status}</span>
									</div>
									{#if (item as any).prompt}
										<div class="collab-detail">{truncateText((item as any).prompt, 160)}</div>
									{/if}
									{#if (item as any).tool === 'spawnAgent' && ((item as any).model || (item as any).reasoningEffort)}
										<div class="collab-detail">
											{(item as any).model ?? ''}{#if (item as any).reasoningEffort} · {(item as any).reasoningEffort}{/if}
										</div>
									{/if}
									{#if (item as any).tool === 'wait' && (item as any).status !== 'inProgress'}
										{#each collabAgentStates(item) as agent}
											<div class="collab-detail">
												{agent.id}: {agent.status}{#if agent.message} — {truncateText(agent.message, 160)}{/if}
											</div>
										{/each}
									{/if}
								</div>
							{:else}
								<div class="item generic">
									<span class="gutter">·</span>
									<div class="body">{item.type}</div>
								</div>
							{/if}
						</div>
					{/each}
					<div class="transcript-spacer" style={`height: ${virtualTranscript.after}px`}></div>
					{#if active?.status === 'running'}
						<div class="item agent pending">
							<div class="body">Working…</div>
						</div>
					{/if}
					{#if active?.error}
						<div class="item err"><span class="gutter">✗</span><div class="body">{active.error}</div></div>
					{/if}
				</div>
				{#if unseenActivity}
					<div class="activity-jump">
						<button class="new-activity" type="button" onclick={scrollToBottom}>
							New activity
							<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2v11M4 9l4 4 4-4" /></svg>
						</button>
					</div>
				{/if}

				<div class="composer-shell">
					<span class="composer-state" aria-live="polite">
						{selectedImages.length > 0 ? `${selectedImages.length} image${selectedImages.length === 1 ? '' : 's'} attached` : ''}
					</span>
					{#if selectedImages.length > 0}
						<div class="attachments" aria-label="Attached images">
							{#each selectedImages as image (image.id)}
								<button
									class="attachment"
									type="button"
									onclick={() => removeSelectedImage(image.id)}
									aria-label={`Remove ${image.name}`}
									title={`Remove ${image.name}`}
								>
									<span>{image.name}</span>
									<svg viewBox="0 0 16 16" aria-hidden="true" focusable="false">
										<path d="M4 4l8 8M12 4l-8 8" />
									</svg>
								</button>
							{/each}
						</div>
					{/if}
					<div class="composer-anchor">
						{#if slashPopupVisible}
							<div class="slash-popup" id="slash-popup" role="listbox" aria-label="Slash commands">
								{#each slashMatches as cmd, i (cmd.name)}
									<button
										type="button"
										class="slash-option"
										class:selected={i === slashIndex}
										id={slashOptionId(cmd)}
										role="option"
										aria-selected={i === slashIndex}
										onmousedown={(e) => e.preventDefault()}
										onclick={() => acceptSlashCompletion(cmd, false)}
										onpointerenter={() => (slashIndex = i)}
									>
										<span class="slash-name">{cmd.name}</span>
										{#if cmd.args}<span class="slash-args">{cmd.args}</span>{/if}
										<span class="slash-desc">{cmd.description}</span>
									</button>
								{/each}
							</div>
						{/if}
					</div>
					<div class="composer">
						<input
							bind:this={imageInputEl}
							class="image-input"
							type="file"
							accept="image/*"
							multiple
							onchange={onImagesSelected}
						/>
						<button
							class="attach"
							type="button"
							onclick={chooseImages}
							disabled={activeRemote}
							title={activeRemote ? 'Image attachments are not yet supported for remote sessions' : 'Attach images'}
							aria-label="Attach images"
						>
							<svg class="control-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
								<path d="m21.44 11.05-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48" />
							</svg>
						</button>
						<textarea
							bind:this={composerTextareaEl}
							aria-label="Message Codex"
							placeholder={composerPlaceholder}
							bind:value={input}
							oninput={resizeComposer}
							onkeydown={onKeydown}
							enterkeyhint={mobileViewport ? 'enter' : 'send'}
							autocapitalize="sentences"
							autocomplete="off"
							spellcheck="true"
							rows="1"
							role="combobox"
							aria-autocomplete="list"
							aria-haspopup="listbox"
							aria-expanded={slashPopupVisible}
							aria-controls={slashPopupVisible ? 'slash-popup' : undefined}
							aria-activedescendant={slashPopupVisible && slashMatches[slashIndex]
								? slashOptionId(slashMatches[slashIndex])
								: undefined}
						></textarea>
						<button
							class="send"
							type="button"
							onclick={send}
							disabled={sendingMessage || (!input.trim() && selectedImages.length === 0)}
							aria-label={sendingMessage ? 'Sending message' : 'Send message'}
							aria-busy={sendingMessage}
						>
							<svg class="control-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
								<path d="m18 15-6-6-6 6" />
								<path d="M12 9v12" />
							</svg>
						</button>
					</div>
					<div class="composer-hint">Enter to send · Shift+Enter for a new line · ↑ for history · Slash commands supported</div>
				</div>
			{/if}
		{/if}
	</main>
</div>

{#if archiveNotice}
	<div class="archive-toast {archiveNotice.tone}" role={archiveNotice.tone === 'error' ? 'alert' : 'status'}>
		<span>{archiveNotice.message}</span>
		{#if archiveNotice.snapshot}
			<button type="button" onclick={undoArchivedSession}>Undo</button>
		{/if}
	</div>
{/if}

{@render children()}

<style>
	/* Hallmark · pre-emit critique: P5 H5 E5 S5 R5 V5
	 * genre: modern-minimal · macrostructure: Workbench · nav: N3 session rail · tone: warm editorial utility
	 * anchor hue: coral · density: compact-workbench · design-system: design.md · designed-as-app · contrast: pass (40–41)
	 * slop: pass (42–45) · honest: pass (46) · chrome: pass (47) · tokens: pass (48)
	 * responsive: pass (34, 49) · icons: pass (30) · mobile: pass (34, 49, 50–57)
	 */
	@import '../../tokens.css';

	:global(*) {
		box-sizing: border-box;
	}

	:global(html),
	:global(body) {
		margin: 0;
		min-width: 20rem;
		height: 100%;
		overflow-x: clip;
		background: var(--color-paper);
		color: var(--color-ink);
		font-family: var(--font-body);
		font-size: var(--text-base);
		line-height: 1.55;
		text-rendering: optimizeLegibility;
	}

	:global(body) {
		overflow-y: hidden;
	}

	:global(button),
	:global(input),
	:global(select),
	:global(textarea) {
		font: inherit;
	}

	:global(button),
	:global(a) {
		-webkit-tap-highlight-color: transparent;
	}

	:global(::selection) {
		background: var(--color-accent-soft);
		color: var(--color-ink);
	}

	:global(*) {
		scrollbar-color: var(--color-rule-2) transparent;
		scrollbar-width: thin;
	}

	:global(::-webkit-scrollbar) {
		width: var(--space-xs);
		height: var(--space-xs);
	}

	:global(::-webkit-scrollbar-thumb) {
		background: var(--color-rule-2);
		border: var(--space-3xs) solid transparent;
		border-radius: var(--radius-pill);
		background-clip: padding-box;
	}

	:global(::-webkit-scrollbar-track) {
		background: transparent;
	}

	:global(:focus) {
		outline: none;
	}

	:global(:focus-visible) {
		outline: var(--rule-fine) solid var(--color-focus);
		outline-offset: var(--focus-offset);
	}

	.app {
		display: grid;
		grid-template-columns: minmax(0, 1fr);
		width: 100%;
		height: 100dvh;
		min-height: 0;
		overflow: clip;
		background: var(--color-paper);
	}

	.sidebar-toggle {
		position: fixed;
		inset-block-start: calc(var(--space-3xs) + env(safe-area-inset-top));
		inset-inline-start: var(--space-xs);
		z-index: var(--z-toast);
		display: grid;
		place-items: center;
		width: var(--control-height);
		height: var(--control-height);
		padding: 0;
		border: var(--rule-hair) solid var(--color-rule);
		border-radius: var(--radius-input);
		background: transparent;
		color: var(--color-ink);
		cursor: pointer;
		white-space: nowrap;
		box-shadow: var(--shadow-card);
		transition:
			color var(--dur-micro) var(--ease-out),
			transform var(--dur-micro) var(--ease-out);
	}

	.header-menu {
		position: static;
		inset: auto;
		z-index: auto;
		border-color: transparent;
		background: transparent;
		box-shadow: none;
	}

	.sidebar-scrim {
		position: fixed;
		inset: 0;
		z-index: var(--z-sticky);
		display: block;
		padding: 0;
		border: 0;
		background: var(--color-overlay);
		visibility: hidden;
		opacity: 0;
		pointer-events: none;
		transition: opacity var(--dur-short) var(--ease-in);
	}

	.sidebar-scrim:disabled {
		opacity: 0;
		cursor: default;
	}

	.app.sidebar-open .sidebar-scrim {
		visibility: visible;
		opacity: 1;
		pointer-events: auto;
		transition-timing-function: var(--ease-out);
	}

	.sidebar {
		position: fixed;
		inset-block: 0;
		inset-inline-start: 0;
		z-index: var(--z-modal);
		display: flex;
		flex-direction: column;
		width: min(88%, var(--rail-width));
		min-width: 0;
		min-height: 0;
		padding-block-start: env(safe-area-inset-top);
		border-inline-end: var(--rule-hair) solid var(--color-rule);
		background: var(--color-paper-2);
		box-shadow: none;
		transform: translateX(-100%);
		transition: transform var(--dur-short) var(--ease-in);
	}

	.sidebar.open {
		box-shadow: var(--shadow-drawer);
		transform: translateX(0);
		transition-timing-function: var(--ease-out);
	}

	.brand {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--space-sm);
		min-height: var(--rail-header-height);
		padding: var(--space-xs) var(--space-sm);
		border-block-end: var(--rule-hair) solid var(--color-rule);
	}

	.drawer-close {
		display: grid;
		place-items: center;
		width: var(--control-height);
		height: var(--control-height);
		padding: 0;
		border: var(--rule-hair) solid transparent;
		border-radius: var(--radius-input);
		background: transparent;
		color: var(--color-ink);
		cursor: pointer;
	}

	.connection {
		display: inline-flex;
		align-items: center;
		gap: var(--space-2xs);
		color: var(--color-muted);
		font-size: var(--text-xs);
		font-weight: 500;
		white-space: nowrap;
	}

	.dot,
	.run-dot {
		flex: none;
		width: var(--space-2xs);
		height: var(--space-2xs);
		border-radius: var(--radius-pill);
		background: var(--color-error);
	}

	.dot.on {
		background: var(--color-success);
	}

	.rail-heading {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--space-sm);
		padding: var(--space-sm) var(--space-sm) var(--space-2xs);
		color: var(--color-neutral);
		font-size: var(--text-sm);
		font-weight: 600;
	}

	.new,
	.mini,
	.stop,
	.attach,
	.send,
	.welcome-action {
		min-height: var(--control-height);
		border: var(--rule-hair) solid transparent;
		border-radius: var(--radius-input);
		cursor: pointer;
		font-weight: 600;
		white-space: nowrap;
		transition:
			background-color var(--dur-micro) var(--ease-out),
			transform var(--dur-micro) var(--ease-out);
	}

	.new {
		display: grid;
		place-items: center;
		width: var(--control-height);
		min-width: var(--control-height);
		padding: 0;
		background: var(--color-accent);
		color: var(--color-accent-ink);
	}

	.create {
		display: flex;
		flex-direction: column;
		gap: var(--space-xs);
		margin: var(--space-sm);
		padding: var(--space-sm);
		border-radius: var(--radius-card);
		background: var(--color-paper-3);
		color: var(--color-ink);
	}

	.create-heading {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--space-sm);
	}

	.create-heading h2 {
		margin: 0;
		min-width: 0;
		overflow-wrap: anywhere;
		font-family: var(--font-display);
		font-size: var(--text-md);
		font-style: normal;
		font-weight: var(--display-weight);
		letter-spacing: var(--tracking-display);
		line-height: 1.15;
	}

	.create-row {
		display: flex;
		flex-direction: column;
		gap: var(--space-2xs);
	}

	.create-row label {
		color: var(--color-neutral);
		font-size: var(--text-xs);
		font-weight: 600;
	}

	.cwd-input,
	.profile-input,
	textarea {
		width: 100%;
		min-width: 0;
		border: var(--rule-hair) solid var(--color-rule-2);
		border-radius: var(--radius-input);
		outline: var(--rule-fine) solid transparent;
		outline-offset: var(--focus-offset);
		background: var(--color-paper);
		color: var(--color-ink);
	}

	.cwd-input,
	.profile-input {
		min-height: var(--control-height);
		padding-inline: var(--space-sm);
		font-size: var(--text-sm);
	}

	.cwd-input {
		font-family: var(--font-outlier);
	}

	.cwd-input::placeholder,
	textarea::placeholder {
		color: var(--color-muted);
		opacity: 1;
	}

	.cwd-input:focus-visible,
	.profile-input:focus-visible,
	textarea:focus-visible {
		border-color: var(--color-rule-2);
		outline-color: var(--color-focus);
	}

	.cwd-input[aria-invalid='true'] {
		border-color: var(--color-error);
	}

	.cwd-input:disabled,
	.profile-input:disabled,
	textarea:disabled,
	button:disabled {
		opacity: 0.52;
		cursor: not-allowed;
	}

	.create-actions {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: var(--space-xs);
	}

	.mini {
		padding-inline: var(--space-sm);
		background: var(--color-accent);
		color: var(--color-accent-ink);
		font-size: var(--text-sm);
	}

	.mini.ghost {
		border-color: var(--color-rule-2);
		background: var(--color-paper);
		color: var(--color-neutral);
	}

	.mini.danger {
		border-color: var(--color-error);
		background: var(--color-error);
		color: var(--color-accent-ink);
	}

	.create-hint {
		display: block;
		min-height: 1lh;
		color: var(--color-muted);
		font-size: var(--text-xs);
		line-height: 1.45;
	}

	.create-err {
		min-height: 1lh;
		padding: var(--space-xs);
		border-radius: var(--radius-input);
		background: var(--color-error-soft);
		color: var(--color-error);
		font-size: var(--text-sm);
		overflow-wrap: anywhere;
	}

	.sessions {
		flex: 1;
		min-height: 0;
		overflow-y: auto;
		padding: 0 var(--space-2xs) var(--space-sm);
	}

	.session-row {
		position: relative;
		display: grid;
		grid-template-columns: minmax(0, 1fr) auto;
		align-items: center;
		margin-block-end: var(--space-3xs);
	}

	.session {
		position: relative;
		display: grid;
		grid-template-columns: var(--space-xs) minmax(0, 1fr) auto;
		gap: var(--space-2xs);
		align-items: center;
		width: 100%;
		min-height: var(--control-height-compact);
		padding: var(--space-3xs) var(--space-xs);
		border: var(--rule-hair) solid transparent;
		border-radius: var(--radius-input);
		background: transparent;
		color: var(--color-muted);
		text-align: start;
		text-decoration: none;
		white-space: nowrap;
		transition: background-color var(--dur-micro) var(--ease-out);
	}

	.session.active {
		border-color: var(--color-rule);
		background: var(--color-paper);
		color: var(--color-ink);
	}

	.run-dot {
		background: var(--color-success);
	}

	.run-dot.running {
		background: var(--color-warning);
		animation: pulse-status 1.8s var(--ease-in-out) infinite;
	}

	.run-dot.error {
		background: var(--color-error);
		animation: none;
	}

	.session .label {
		grid-column: 2;
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		font-size: var(--text-sm);
		font-weight: 500;
	}

	.fast-mark {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: var(--space-sm);
		height: var(--space-sm);
		color: var(--color-warning);
		line-height: 1;
	}

	.fast-mark svg {
		width: var(--space-sm);
		height: var(--space-sm);
		fill: currentColor;
	}

	.session .host-badge {
		max-width: 6.5rem;
		overflow: hidden;
		padding-inline: var(--space-2xs);
		border: var(--rule-hair) solid var(--color-rule);
		border-radius: var(--radius-pill);
		font-family: var(--font-outlier);
		font-size: var(--text-xs);
		line-height: 1.6;
		color: var(--color-muted);
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.session-row.side-row .session {
		width: 100%;
	}

	.session-row.side-row {
		padding-inline-start: var(--space-md);
	}

	.session.side .label {
		color: var(--color-neutral);
	}

	.delete-session {
		position: static;
		display: grid;
		place-items: center;
		width: var(--space-md);
		height: var(--space-md);
		padding: 0;
		border: var(--rule-hair) solid transparent;
		border-radius: var(--radius-sm);
		background: transparent;
		color: var(--color-muted);
		cursor: pointer;
		opacity: 1;
		pointer-events: auto;
		white-space: nowrap;
		transform: none;
		transition:
			background-color var(--dur-micro) var(--ease-out),
			opacity var(--dur-micro) var(--ease-out),
			transform var(--dur-micro) var(--ease-out);
	}

	.delete-session svg {
		display: block;
		width: var(--space-sm);
		height: var(--space-sm);
		fill: none;
		stroke: currentColor;
		stroke-linecap: round;
		stroke-linejoin: round;
		stroke-width: 1.75;
	}

	.delete-session:focus-visible {
		opacity: 1;
		pointer-events: auto;
		transition: none;
	}

	.empty {
		display: flex;
		flex-direction: column;
		gap: var(--space-2xs);
		padding: var(--space-lg) var(--space-sm);
		color: var(--color-muted);
		font-size: var(--text-sm);
	}

	.empty strong {
		color: var(--color-ink-2);
		font-weight: 600;
	}

	.hint {
		display: flex;
		justify-content: flex-start;
		gap: var(--space-sm);
		padding: var(--space-xs) var(--space-sm) calc(var(--space-xs) + env(safe-area-inset-bottom));
		border-block-start: var(--rule-hair) solid var(--color-rule);
		color: var(--color-muted);
		font-size: var(--text-xs);
	}

	.chat {
		display: flex;
		flex-direction: column;
		min-width: 0;
		min-height: 0;
		background: var(--color-paper);
		color: var(--color-ink);
	}

	.welcome {
		display: grid;
		grid-template-columns: minmax(0, 1fr);
		gap: var(--space-xl);
		width: min(100%, var(--measure-reading));
		max-height: 100%;
		/* Block-auto margins center the welcome in the viewport; they collapse
		   to 0 when the content is taller than the screen. */
		margin: auto;
		padding: calc(var(--space-2xl) + env(safe-area-inset-top)) var(--space-md) var(--space-xl);
		overflow-y: auto;
	}

	.welcome-copy {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: var(--space-sm);
		min-width: 0;
	}

	.welcome h1 {
		margin: 0;
		min-width: 0;
		max-width: 11ch;
		overflow-wrap: anywhere;
		font-family: var(--font-display);
		font-size: clamp(var(--text-2xl), 10vw, var(--text-display));
		font-style: normal;
		font-weight: var(--display-weight);
		letter-spacing: var(--tracking-display);
		line-height: 0.98;
	}

	.welcome-copy p {
		margin: 0;
		max-width: var(--measure-lede);
		color: var(--color-neutral);
		font-size: var(--text-base);
		line-height: 1.5;
	}

	.welcome-action {
		display: inline-flex;
		align-items: center;
		gap: var(--space-xs);
		padding-inline: var(--space-md);
		background: var(--color-accent);
		color: var(--color-accent-ink);
	}

	.welcome-action span {
		font-size: var(--text-md);
	}

	.welcome-details {
		align-self: end;
		border-block-start: var(--rule-hair) solid var(--color-rule-2);
	}

	.welcome-details > div {
		display: grid;
		grid-template-columns: minmax(7rem, 0.42fr) minmax(0, 1fr);
		gap: var(--space-sm);
		padding-block: var(--space-sm);
		border-block-end: var(--rule-hair) solid var(--color-rule);
	}

	.welcome-details strong {
		color: var(--color-ink-2);
		font-size: var(--text-sm);
		font-weight: 600;
	}

	.welcome-details span {
		color: var(--color-muted);
		font-size: var(--text-sm);
		line-height: 1.45;
	}

	.topbar {
		display: grid;
		grid-template-columns: auto minmax(0, 1fr) auto;
		align-items: center;
		gap: var(--space-2xs);
		padding: calc(var(--space-3xs) + env(safe-area-inset-top)) var(--space-2xs) var(--space-3xs);
		border-block-end: var(--rule-hair) solid var(--color-rule);
		background: var(--color-paper);
	}

	.session-heading {
		min-width: 0;
	}

	.session-heading h1 {
		margin: 0;
		min-width: 0;
		overflow: hidden;
		overflow-wrap: anywhere;
		color: var(--color-ink);
		font-family: var(--font-body);
		font-size: var(--text-sm);
		font-style: normal;
		font-weight: 600;
		letter-spacing: normal;
		line-height: 1.25;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.session-meta {
		display: none;
		flex-wrap: wrap;
		align-items: center;
		gap: var(--space-2xs) var(--space-xs);
		margin-block-start: var(--space-2xs);
		color: var(--color-muted);
		font-family: var(--font-outlier);
		font-size: var(--text-xs);
	}

	.session-facts {
		display: none;
		grid-column: 1 / -1;
		align-items: center;
		gap: var(--space-2xs);
		min-width: 0;
		overflow: hidden;
		color: var(--color-neutral);
		font-family: var(--font-outlier);
		font-size: var(--text-xs);
		white-space: nowrap;
	}

	.fact {
		display: inline-flex;
		align-items: baseline;
		min-width: 0;
	}

	.fact + .fact::before {
		content: '·';
		margin-inline-end: var(--space-2xs);
		color: var(--color-rule-2);
	}

	.fact-detail {
		color: var(--color-muted);
	}

	.fact.profile {
		color: var(--color-accent-active);
	}

	.fact.host {
		font-family: var(--font-outlier);
		color: var(--color-muted);
	}

	.fact.host.degraded {
		color: var(--color-warning);
	}

	.topbar .tid,
	.topbar .meta {
		min-width: 0;
		max-width: 100%;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.topbar .tid {
		color: var(--color-neutral);
	}

	.topbar .tid.dim,
	.topbar .meta-sep,
	.topbar .meta {
		color: var(--color-muted);
	}

	.topbar .cwd {
		flex: 1 1 auto;
	}

	.session-state {
		display: flex;
		align-items: center;
		gap: var(--space-3xs);
		justify-self: end;
	}

	.files-trigger,
	.session-info-trigger,
	.session-info-close {
		display: grid;
		place-items: center;
		width: var(--control-height);
		min-width: var(--control-height);
		height: var(--control-height);
		padding: 0;
		border: var(--rule-hair) solid transparent;
		border-radius: var(--radius-input);
		background: transparent;
		color: var(--color-neutral);
		cursor: pointer;
		transition:
			background-color var(--dur-micro) var(--ease-out),
			transform var(--dur-micro) var(--ease-out);
	}

	.files-trigger[aria-pressed='true'] {
		border-color: var(--color-rule);
		background: var(--color-paper-3);
		color: var(--color-ink);
	}

	.session-info-trigger {
		position: relative;
	}

	.files-trigger svg,
	.session-info-trigger svg,
	.session-info-close svg {
		display: block;
		width: var(--space-md);
		height: var(--space-md);
		fill: none;
		stroke: currentColor;
		stroke-linecap: round;
		stroke-linejoin: round;
		stroke-width: 1.75;
	}

	.session-info-trigger .info-dot {
		fill: currentColor;
		stroke: none;
	}

	.session-state-dot {
		position: absolute;
		inset-block-start: var(--space-2xs);
		inset-inline-end: var(--space-2xs);
		width: var(--space-2xs);
		height: var(--space-2xs);
		border: var(--rule-hair) solid var(--color-paper);
		border-radius: var(--radius-pill);
		background: var(--color-success);
	}

	.session-state-dot.running {
		background: var(--color-warning);
		animation: pulse-status 1.8s var(--ease-in-out) infinite;
	}

	.session-state-dot.error {
		background: var(--color-error);
		animation: none;
	}

	.stop {
		display: grid;
		place-items: center;
		width: var(--control-height);
		min-width: var(--control-height);
		min-height: var(--control-height);
		padding: 0;
		border-color: var(--color-error);
		background: var(--color-paper);
		color: var(--color-error);
	}

	.stop-icon {
		display: block;
		width: var(--space-sm);
		height: var(--space-sm);
		fill: currentColor;
	}

	.session-info-dialog {
		position: fixed;
		inset: 0;
		width: min(calc(100% - var(--space-lg)), 32rem);
		max-width: none;
		max-height: calc(100dvh - var(--space-xl));
		margin: auto;
		padding: 0;
		overflow: auto;
		border: var(--rule-hair) solid var(--color-rule-2);
		border-radius: var(--radius-card);
		background: var(--color-paper);
		box-shadow: var(--shadow-card);
		color: var(--color-ink);
	}

	.session-info-dialog::backdrop {
		background: var(--color-overlay);
	}

	.session-info-panel {
		padding: var(--space-sm);
	}

	.session-info-heading {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--space-sm);
		padding-block-end: var(--space-xs);
		border-block-end: var(--rule-hair) solid var(--color-rule);
	}

	.session-info-heading h2 {
		margin: 0;
		font-family: var(--font-display);
		font-size: var(--text-lg);
		font-style: normal;
		font-weight: var(--display-weight);
		letter-spacing: var(--tracking-display);
		line-height: 1.1;
	}

	.session-info-list {
		margin: 0;
	}

	.session-info-list > div {
		display: grid;
		grid-template-columns: minmax(5rem, 0.35fr) minmax(0, 1fr);
		gap: var(--space-sm);
		padding-block: var(--space-2xs);
		border-block-end: var(--rule-hair) solid var(--color-rule);
	}

	.session-info-list > div:last-child {
		border-block-end: 0;
	}

	.session-info-list dt,
	.session-info-list dd {
		margin: 0;
		font-size: var(--text-sm);
		line-height: 1.45;
	}

	.session-info-list dt {
		color: var(--color-muted);
		font-family: var(--font-body);
		font-weight: 500;
	}

	.session-info-list dd {
		min-width: 0;
		overflow-wrap: anywhere;
		color: var(--color-ink-2);
		font-family: var(--font-outlier);
	}

	.side-banner,
	.goal-tracker {
		display: flex;
		align-items: center;
		gap: var(--space-xs);
		padding: var(--space-2xs) var(--space-sm);
		border-block-end: var(--rule-hair) solid var(--color-rule);
		font-size: var(--text-xs);
	}

	.side-banner {
		background: var(--color-warning-soft);
		color: var(--color-neutral);
	}

	.side-banner-label {
		font-weight: 600;
	}

	.side-banner .meta {
		color: var(--color-muted);
	}

	.spacer {
		flex: 1;
	}

	.goal-tracker {
		flex-direction: column;
		align-items: stretch;
		background: var(--color-accent-soft);
		color: var(--color-ink);
	}

	.goal-main,
	.goal-metrics {
		display: flex;
		align-items: center;
		gap: var(--space-xs);
		min-width: 0;
	}

	.goal-marker {
		color: var(--color-accent-active);
	}

	.goal-objective {
		min-width: 0;
		flex: 1;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.goal-state {
		padding: var(--space-3xs) var(--space-xs);
		border: var(--rule-hair) solid var(--color-accent);
		border-radius: var(--radius-pill);
		color: var(--color-accent-active);
		font-size: var(--text-xs);
		font-weight: 600;
		white-space: nowrap;
	}

	.goal-metrics {
		flex-wrap: wrap;
		color: var(--color-neutral);
		font-family: var(--font-outlier);
		font-size: var(--text-xs);
		font-variant-numeric: tabular-nums;
	}

	.goal-progress {
		flex: 1;
		min-width: 7rem;
		height: var(--space-2xs);
		overflow: hidden;
		border-radius: var(--radius-pill);
		background: var(--color-rule);
	}

	.goal-progress span {
		display: block;
		height: 100%;
		background: var(--color-accent-active);
	}

	.conflict {
		display: flex;
		flex-direction: column;
		gap: var(--space-xs);
		margin: var(--space-sm);
		padding: var(--space-sm);
		border: var(--rule-hair) solid var(--color-error);
		border-radius: var(--radius-card);
		background: var(--color-error-soft);
		color: var(--color-ink);
	}

	.conflict-head {
		color: var(--color-error);
		font-family: var(--font-display);
		font-size: var(--text-md);
		font-style: normal;
		font-weight: var(--display-weight);
		letter-spacing: var(--tracking-display);
	}

	.conflict-body {
		max-width: var(--measure-prose);
		color: var(--color-neutral);
		font-size: var(--text-sm);
		line-height: 1.5;
	}

	.conflict-body code {
		color: var(--color-error);
		font-family: var(--font-outlier);
		overflow-wrap: anywhere;
	}

	.conflict-actions {
		display: flex;
		flex-wrap: wrap;
		gap: var(--space-xs);
	}

	.transcript {
		flex: 1;
		min-height: 0;
		overflow-y: auto;
		overflow-anchor: none;
		padding: var(--space-xs) var(--space-sm) var(--space-lg);
		scroll-padding-block-end: var(--space-lg);
	}

	.activity-jump {
		position: relative;
		z-index: var(--z-raised);
		display: flex;
		height: 0;
		justify-content: center;
	}

	.new-activity {
		display: inline-flex;
		align-items: center;
		gap: var(--space-2xs);
		min-height: var(--control-height-compact);
		padding-inline: var(--space-xs);
		border: var(--rule-hair) solid var(--color-rule-2);
		border-radius: var(--radius-pill);
		background: var(--color-paper);
		box-shadow: var(--shadow-card);
		color: var(--color-neutral);
		cursor: pointer;
		font-size: var(--text-xs);
		font-weight: 600;
		transform: translateY(calc(-100% - var(--space-2xs)));
		transition:
			background-color var(--dur-micro) var(--ease-out),
			transform var(--dur-micro) var(--ease-out);
	}

	.new-activity svg {
		width: var(--space-sm);
		height: var(--space-sm);
		fill: none;
		stroke: currentColor;
		stroke-linecap: round;
		stroke-linejoin: round;
		stroke-width: 1.75;
	}

	.transcript-spacer {
		flex: none;
	}

	.virtual-row,
	.transcript > .item,
	.sys {
		width: min(100%, var(--measure-reading));
		margin-inline: auto;
	}

	.virtual-row {
		padding-block-end: var(--space-xs);
	}

	/* Agent messages already end with their compact meta row, so their
	   wrapper needs less trailing space than other transcript rows. */
	.virtual-row:has(> .item.agent) {
		padding-block-end: var(--space-2xs);
	}

	.sys {
		padding-block-end: var(--space-xs);
		color: var(--color-muted);
		font-size: var(--text-sm);
	}

	.transcript-empty {
		display: grid;
		align-content: center;
		justify-items: center;
		gap: var(--space-2xs);
		width: min(100%, var(--measure-reading));
		min-height: 100%;
		margin-inline: auto;
		padding-block-end: var(--space-2xl);
		text-align: center;
	}

	.transcript-empty p {
		margin: 0;
	}

	.transcript-empty-lede {
		color: var(--color-ink-2);
		font-family: var(--font-display);
		font-size: var(--text-lg);
		font-weight: var(--display-weight);
		letter-spacing: var(--tracking-display);
	}

	.transcript-empty-hint {
		max-width: var(--measure-lede);
		color: var(--color-muted);
		font-size: var(--text-sm);
		line-height: 1.5;
	}

	.transcript-empty-hint strong {
		color: var(--color-neutral);
		font-weight: 600;
	}

	.transcript-empty-hint code {
		padding: 0 var(--space-3xs);
		border: var(--rule-hair) solid var(--color-rule);
		border-radius: var(--radius-xs);
		background: var(--color-paper-2);
		font-family: var(--font-outlier);
		font-size: 0.85em;
	}

	.item {
		display: grid;
		grid-template-columns: var(--space-sm) minmax(0, 1fr);
		gap: var(--space-2xs);
		align-items: start;
		min-width: 0;
	}

	.body {
		min-width: 0;
		overflow-wrap: anywhere;
		white-space: pre-wrap;
	}

	.item.user {
		display: block;
		/* Size to the prompt, matching the agent's prose measure, instead of
		   stretching a short line across the full reading column. */
		width: fit-content;
		min-width: min(100%, 16rem);
		max-width: min(100%, var(--measure-prose));
		padding: var(--space-xs) var(--space-sm);
		border-radius: var(--radius-input);
		background: var(--color-paper-3);
		color: var(--color-ink);
	}

	.item.agent {
		grid-template-columns: minmax(0, 1fr);
		gap: 0;
		/* The meta row supplies the trailing whitespace; no extra padding. */
		padding: var(--space-3xs) var(--space-sm) 0;
		color: var(--color-ink);
	}

	.agent-raw {
		margin: 0;
		overflow-wrap: anywhere;
		color: var(--color-ink-2);
		font-family: var(--font-outlier);
		font-size: var(--text-sm);
		line-height: 1.55;
		white-space: pre-wrap;
	}

	/* Message footer: timestamp always visible at the start, quiet controls
	   after it; kept to a single compact line so message rhythm stays tight. */
	.agent-meta {
		display: flex;
		align-items: center;
		gap: var(--space-2xs);
		justify-self: start;
		min-height: calc(var(--space-sm) + var(--space-3xs));
	}

	.agent-time {
		color: var(--color-muted);
		font-family: var(--font-body);
		font-size: var(--text-xs);
		font-variant-numeric: tabular-nums;
		line-height: 1.2;
	}

	.raw-toggle {
		display: grid;
		place-items: center;
		width: calc(var(--space-sm) + var(--space-3xs));
		height: calc(var(--space-sm) + var(--space-3xs));
		padding: 0;
		border: 0;
		border-radius: var(--radius-sm);
		background: transparent;
		color: var(--color-muted);
		cursor: pointer;
		transition:
			background-color var(--dur-micro) var(--ease-out),
			color var(--dur-micro) var(--ease-out),
			opacity var(--dur-micro) var(--ease-out);
	}

	.raw-toggle svg {
		display: block;
		width: var(--space-xs);
		height: var(--space-xs);
		fill: none;
		stroke: currentColor;
		stroke-linecap: round;
		stroke-linejoin: round;
		stroke-width: 1.75;
	}

	.raw-toggle[aria-pressed='true'] {
		background: var(--color-paper-3);
		color: var(--color-neutral);
	}

	.item.agent .body {
		width: 100%;
		max-width: none;
		font-family: var(--font-display);
		font-size: var(--text-md);
		font-style: normal;
		font-weight: var(--display-weight);
		letter-spacing: -0.01em;
		line-height: 1.45;
	}

	.markdown-body {
		display: flex;
		flex-direction: column;
		gap: var(--space-2xs);
		min-width: 0;
		white-space: normal;
	}

	.markdown-body p,
	.markdown-body ul,
	.markdown-body ol,
	.markdown-body blockquote,
	.markdown-body pre,
	.markdown-body table {
		margin: 0;
	}

	.markdown-heading {
		display: flex;
		align-items: baseline;
		gap: var(--space-2xs);
		font-size: inherit;
		line-height: inherit;
	}

	.markdown-heading strong,
	.markdown-body strong,
	.markdown-body th {
		font-weight: 700;
	}

	.markdown-hash {
		flex: none;
		color: var(--color-muted);
		font-family: inherit;
		font-size: inherit;
		font-weight: 700;
		letter-spacing: 0;
	}

	.markdown-body ul,
	.markdown-body ol {
		display: flex;
		flex-direction: column;
		gap: var(--space-3xs);
		padding-inline-start: var(--space-md);
	}

	.markdown-body li {
		padding-inline-start: var(--space-3xs);
	}

	/* Task-list items: the checkbox replaces the bullet, GitHub-style. */
	.markdown-body li.task {
		list-style: none;
	}

	.markdown-body li > p {
		display: inline;
	}

	.markdown-body input[type='checkbox'] {
		margin: 0 var(--space-2xs) 0 0;
		accent-color: var(--color-accent-active);
		vertical-align: middle;
	}

	.markdown-body blockquote {
		padding-inline-start: var(--space-sm);
		border-inline-start: var(--rule-hair) solid var(--color-rule-2);
		color: var(--color-neutral);
	}

	.markdown-body :not(pre) > code {
		padding: 0 var(--space-3xs);
		border-radius: var(--radius-sm);
		background: var(--color-paper-3);
		font-family: var(--font-outlier);
		font-size: 0.78em;
	}

	/* Code spans that resolve to workspace files open the file browser. */
	.markdown-body .code-path {
		padding: 0;
		border: 0;
		background: transparent;
		color: inherit;
		cursor: pointer;
		font: inherit;
		text-align: start;
	}

	.markdown-body .code-path code {
		text-decoration: underline;
		text-decoration-color: var(--color-rule-2);
		text-decoration-thickness: var(--rule-hair);
		text-underline-offset: var(--space-3xs);
		transition: color var(--dur-micro) var(--ease-out);
	}

	.markdown-body .code-path:hover code,
	.markdown-body .code-path:focus-visible code {
		color: var(--color-accent-active);
		text-decoration-color: currentColor;
	}

	.markdown-code {
		display: flex;
		flex-direction: column;
		gap: 0;
		min-width: 0;
		overflow: hidden;
		border-radius: var(--radius-input);
		background: var(--color-code-surface);
		color: var(--color-code-ink);
	}

	.markdown-language {
		padding: var(--space-2xs) var(--space-sm);
		border-block-end: var(--rule-hair) solid var(--color-code-rule);
		color: var(--color-code-muted);
		font-family: var(--font-outlier);
		font-size: var(--text-xs);
	}

	.markdown-code pre {
		max-width: 100%;
		padding: var(--space-xs) var(--space-sm);
		overflow-x: auto;
		white-space: pre;
	}

	.markdown-code code {
		font-family: var(--font-outlier);
		font-size: var(--text-sm);
	}

	.markdown-body a,
	.markdown-body .link-path {
		color: var(--color-accent-active);
		text-decoration: underline;
		text-decoration-thickness: var(--rule-hair);
		text-underline-offset: var(--space-3xs);
	}

	/* Markdown links that resolve to workspace files open the file browser. */
	.markdown-body .link-path {
		padding: 0;
		border: 0;
		background: transparent;
		cursor: pointer;
		font: inherit;
		text-align: start;
	}

	.markdown-image {
		display: block;
		width: auto;
		max-width: 100%;
		max-height: 18rem;
		border: var(--rule-hair) solid var(--color-rule);
		border-radius: var(--radius-card);
		object-fit: contain;
	}

	.markdown-table-wrap {
		max-width: 100%;
		overflow-x: auto;
	}

	.markdown-body table {
		width: 100%;
		border-collapse: collapse;
		font-variant-numeric: tabular-nums;
	}

	.markdown-body th,
	.markdown-body td {
		padding: var(--space-2xs) var(--space-xs);
		border-block-end: var(--rule-hair) solid var(--color-rule);
		text-align: start;
		vertical-align: top;
	}

	.markdown-body .align-center {
		text-align: center;
	}

	.markdown-body .align-right {
		text-align: end;
	}

	.markdown-body hr {
		width: 100%;
		margin: var(--space-2xs) 0;
		border: 0;
		border-block-start: var(--rule-hair) solid var(--color-rule-2);
	}

	.item.pending .body {
		color: var(--color-muted);
	}

	.media-body {
		display: flex;
		flex-direction: column;
		gap: var(--space-xs);
	}

	.message-image {
		display: inline-flex;
		flex-direction: column;
		gap: var(--space-2xs);
		width: fit-content;
		max-width: 100%;
		color: var(--color-muted);
		font-family: var(--font-body);
		font-size: var(--text-xs);
		text-decoration: none;
	}

	.message-image img {
		display: block;
		width: auto;
		max-width: min(100%, 32.5rem);
		max-height: 18rem;
		border: var(--rule-hair) solid var(--color-rule);
		border-radius: var(--radius-card);
		background: var(--color-paper-2);
		object-fit: contain;
	}

	.message-image span {
		max-width: 100%;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.gutter {
		color: var(--color-muted);
		font-family: var(--font-outlier);
		font-size: var(--text-xs);
		user-select: none;
	}

	.item.reason,
	.item.file,
	.item.web-search,
	.item.plan,
	.item.note,
	.item.review,
	.item.subagent,
	.item.collab,
	.item.generic {
		padding: var(--space-2xs) var(--space-sm);
		border: 0;
		border-radius: 0;
		background: transparent;
		color: var(--color-neutral);
	}

	/* Gutter glyphs are a size down from their body text; share the first
	   baseline so the pair doesn't sit visibly askew. */
	.item.reason,
	.item.plan,
	.item.note,
	.item.review,
	.item.subagent,
	.item.generic,
	.item.err {
		align-items: baseline;
	}

	.item.reason .body {
		font-style: italic;
	}

	.item.reason .gutter,
	.item.plan .gutter {
		color: var(--color-warning);
	}

	.item.file .gutter,
	.item.web-search .gutter,
	.item.review .gutter,
	.item.subagent .gutter,
	.item.collab .gutter {
		color: var(--color-accent-active);
	}

	.item.file {
		display: block;
	}

	.web-search-icon {
		display: grid;
		place-items: center;
		width: var(--space-sm);
		height: var(--space-sm);
	}

	.web-search-icon svg {
		display: block;
		width: 100%;
		height: 100%;
		fill: none;
		stroke: currentColor;
		stroke-linecap: round;
		stroke-linejoin: round;
		stroke-width: 1.5;
	}

	.item.web-search .body {
		min-width: 0;
		color: var(--color-muted);
		font-size: var(--text-sm);
		white-space: normal;
	}

	.web-search-detail,
	.item.web-search a {
		color: var(--color-ink-2);
		overflow-wrap: anywhere;
	}

	.item.web-search a {
		text-decoration-thickness: var(--rule-hair);
		text-underline-offset: var(--space-3xs);
	}

	.web-search-count {
		white-space: nowrap;
	}

	.item.cmd {
		display: flex;
		flex-direction: column;
		gap: 0;
		overflow: visible;
		border-radius: 0;
		background: transparent;
		color: var(--color-neutral);
	}

	.cmd-line {
		display: grid;
		grid-template-columns: auto minmax(0, 1fr) auto;
		gap: var(--space-2xs);
		align-items: center;
		min-height: var(--control-height-compact);
		padding: var(--space-2xs) var(--space-sm);
	}

	.cmd-toggle {
		width: 100%;
		border: 0;
		border-radius: 0;
		background: transparent;
		color: inherit;
		font: inherit;
		text-align: start;
		cursor: pointer;
	}

	.cmd-toggle:focus-visible {
		outline: 2px solid var(--color-focus);
		outline-offset: -2px;
	}

	.cmd-toggle:active {
		opacity: 0.72;
	}

	.item.cmd .gutter,
	.cmd-text,
	.cmd-result,
	.cmd-out {
		font-family: var(--font-outlier);
	}

	/* The $ prompt shares the command's type size so the centered pair can't
	   drift apart vertically. */
	.item.cmd .gutter {
		color: var(--color-warning);
		font-size: var(--text-sm);
	}

	.cmd-text {
		min-width: 0;
		color: var(--color-ink-2);
		font-size: var(--text-sm);
		overflow-wrap: anywhere;
		white-space: pre-wrap;
	}

	.cmd-status {
		color: var(--color-muted);
		font-size: var(--text-xs);
		white-space: nowrap;
	}

	.cmd-status.completed {
		color: var(--color-success);
	}

	.cmd-status.failed {
		color: var(--color-error);
	}

	.cmd-result {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		flex: none;
		width: var(--space-sm);
		height: var(--space-sm);
		color: var(--color-warning);
	}

	.cmd-result.completed {
		color: var(--color-success);
	}

	.cmd-result.failed {
		color: var(--color-error);
	}

	.cmd-result svg {
		display: block;
		width: 100%;
		height: 100%;
		fill: none;
		stroke: currentColor;
		stroke-linecap: round;
		stroke-linejoin: round;
		stroke-width: 1.75;
	}

	.cmd-meta {
		display: inline-flex;
		align-items: center;
		justify-content: flex-end;
		gap: var(--space-2xs);
		min-height: var(--space-sm);
	}

	.cmd-output-count {
		color: var(--color-muted);
		font-family: var(--font-outlier);
		font-size: var(--text-xs);
		white-space: nowrap;
	}

	.cmd-disclosure {
		flex: none;
		width: var(--space-sm);
		height: var(--space-sm);
		fill: none;
		stroke: var(--color-muted);
		stroke-linecap: round;
		stroke-linejoin: round;
		stroke-width: 1.5;
		transition: transform var(--dur-micro) var(--ease-in-out);
	}

	.cmd-disclosure.expanded {
		transform: rotate(90deg);
	}

	.cmd-out {
		width: 100%;
		margin: 0;
		padding: var(--space-2xs) var(--space-sm) var(--space-xs) calc(var(--space-md) + var(--space-xs));
		border-block-start: var(--rule-hair) solid var(--color-rule);
		background: transparent;
		color: var(--color-muted);
		font-size: var(--text-sm);
		line-height: 1.45;
		max-height: 15rem;
		overflow: auto;
		overflow-wrap: anywhere;
		white-space: pre-wrap;
	}

	.fc {
		display: grid;
		grid-template-columns: max-content minmax(0, 1fr);
		gap: var(--space-2xs);
		align-items: baseline;
		font-family: var(--font-outlier);
		font-size: var(--text-sm);
		overflow-wrap: anywhere;
	}

	.fc + .fc,
	.step + .step {
		margin-block-start: var(--space-2xs);
	}

	.fc .kind {
		color: var(--color-accent-active);
		font-size: var(--text-sm);
		font-weight: 500;
	}

	.fc .path {
		min-width: 0;
	}

	.fc .path-link {
		padding: 0;
		border: 0;
		background: transparent;
		color: inherit;
		cursor: pointer;
		font: inherit;
		text-align: start;
		text-decoration: underline;
		text-decoration-color: transparent;
		text-decoration-thickness: var(--rule-hair);
		text-underline-offset: var(--space-3xs);
		overflow-wrap: anywhere;
		transition: color var(--dur-micro) var(--ease-out);
	}

	.fc .path-link:hover,
	.fc .path-link:focus-visible {
		color: var(--color-accent-active);
		text-decoration-color: currentColor;
	}

	.step {
		color: var(--color-muted);
		font-family: var(--font-outlier);
		font-size: var(--text-sm);
	}

	.step.completed {
		color: var(--color-success);
	}

	.step.inProgress {
		color: var(--color-warning);
	}

	.item.note .body,
	.item.generic .body,
	.collab-detail {
		font-size: var(--text-sm);
	}

	/* Slash-command echoes and their output are TUI-style text whose column
	   alignment (/help, /status) depends on a fixed-pitch face. */
	.item.note .body,
	.item.generic .body {
		font-family: var(--font-outlier);
		line-height: 1.5;
	}

	.item.note.err,
	.item.err {
		padding: var(--space-xs) var(--space-sm);
		border: var(--rule-hair) solid var(--color-error);
		border-radius: var(--radius-input);
		background: var(--color-error-soft);
		color: var(--color-error);
	}

	.item.review {
		color: var(--color-ink);
	}

	.item.subagent .agent-path {
		color: var(--color-accent-active);
		font-family: var(--font-outlier);
	}

	.item.collab {
		display: flex;
		flex-direction: column;
		gap: var(--space-2xs);
	}

	.collab-line {
		display: grid;
		grid-template-columns: auto minmax(0, 1fr) auto;
		gap: var(--space-xs);
		align-items: baseline;
	}

	.collab-text {
		min-width: 0;
		color: var(--color-ink-2);
		overflow-wrap: anywhere;
	}

	.collab-detail {
		margin-inline-start: calc(var(--space-md) + var(--space-xs));
		color: var(--color-muted);
		overflow-wrap: anywhere;
		white-space: pre-wrap;
	}

	.composer-shell {
		padding: var(--space-2xs) var(--space-2xs) calc(var(--space-2xs) + env(safe-area-inset-bottom));
		border-block-start: var(--rule-hair) solid var(--color-rule);
		background: var(--color-paper);
	}

	.composer-state {
		position: absolute;
		width: 1px;
		height: 1px;
		padding: 0;
		margin: -1px;
		overflow: hidden;
		clip: rect(0, 0, 0, 0);
		white-space: nowrap;
		border: 0;
	}

	.composer,
	.composer-anchor,
	.attachments,
	.composer-hint {
		width: min(100%, var(--measure-reading));
		margin-inline: auto;
	}

	/* Zero-height anchor so the slash popup floats above the composer,
	   overlaying the transcript instead of pushing layout. */
	.composer-anchor {
		position: relative;
		height: 0;
	}

	.slash-popup {
		position: absolute;
		inset-inline: 0;
		inset-block-end: var(--space-xs);
		z-index: var(--z-dropdown);
		display: flex;
		flex-direction: column;
		max-height: min(16rem, 40dvh);
		padding: var(--space-3xs);
		overflow-y: auto;
		border: var(--rule-hair) solid var(--color-rule-2);
		border-radius: var(--radius-input);
		background: var(--color-paper);
		box-shadow: var(--shadow-card);
	}

	.slash-option {
		display: grid;
		grid-template-columns: max-content max-content minmax(0, 1fr);
		gap: var(--space-2xs) var(--space-xs);
		align-items: baseline;
		width: 100%;
		min-height: var(--control-height-compact);
		padding: var(--space-2xs) var(--space-xs);
		border: 0;
		border-inline-start: var(--rule-fine) solid transparent;
		border-radius: var(--radius-sm);
		background: transparent;
		color: var(--color-neutral);
		cursor: pointer;
		font: inherit;
		text-align: start;
	}

	.slash-option.selected {
		border-inline-start-color: var(--color-accent);
		background: var(--color-paper-3);
		color: var(--color-ink);
	}

	.slash-name {
		color: var(--color-ink-2);
		font-family: var(--font-outlier);
		font-size: var(--text-sm);
		white-space: nowrap;
	}

	.slash-option.selected .slash-name {
		color: var(--color-ink);
	}

	.slash-args {
		color: var(--color-muted);
		font-family: var(--font-outlier);
		font-size: var(--text-xs);
		white-space: nowrap;
	}

	.slash-desc {
		grid-column: 3;
		justify-self: end;
		max-width: 100%;
		overflow: hidden;
		color: var(--color-muted);
		font-size: var(--text-xs);
		text-align: end;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.composer {
		display: grid;
		grid-template-areas: 'attach message send';
		grid-template-columns: auto minmax(0, 1fr) auto;
		gap: var(--space-3xs);
		align-items: end;
		padding: var(--space-3xs);
		border: var(--rule-hair) solid var(--color-rule-2);
		border-radius: var(--radius-card);
		background: var(--color-paper);
	}

	.composer:focus-within {
		border-color: var(--color-focus);
	}

	.image-input {
		display: none;
	}

	.attach {
		grid-area: attach;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		gap: var(--space-2xs);
		justify-self: start;
		width: var(--control-height);
		min-width: var(--control-height);
		padding-inline: 0;
		border-color: var(--color-rule);
		background: var(--color-paper);
		color: var(--color-neutral);
		font-size: var(--text-sm);
	}

	textarea {
		grid-area: message;
		min-height: var(--control-height);
		max-height: min(9rem, 36dvh);
		/* Block padding centers a single 1.4em line inside the control height,
		   so the placeholder and caret sit flush with the attach/send icons. */
		padding: calc((var(--control-height) - 1.4em) / 2) var(--space-xs);
		border-color: transparent;
		background: transparent;
		font-family: var(--font-body);
		font-size: var(--text-base);
		line-height: 1.4;
		overflow-y: hidden;
		resize: none;
	}

	textarea:focus-visible {
		border-color: transparent;
		outline-color: transparent;
	}

	.send {
		grid-area: send;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		gap: var(--space-2xs);
		width: var(--control-height);
		min-width: var(--control-height);
		padding-inline: 0;
		background: var(--color-accent);
		color: var(--color-accent-ink);
		font-size: var(--text-sm);
	}

	.send:disabled {
		border-color: var(--color-rule);
		background: var(--color-paper-3);
		color: var(--color-muted);
		opacity: 1;
	}

	.control-icon {
		flex: none;
		width: var(--space-sm);
		height: var(--space-sm);
		fill: none;
		stroke: currentColor;
		stroke-linecap: round;
		stroke-linejoin: round;
		stroke-width: 2;
	}

	.send:focus-visible,
	.welcome-action:focus-visible,
	.new:focus-visible,
	.mini:not(.ghost):focus-visible {
		outline-color: var(--color-ink);
	}

	.attachments {
		display: flex;
		flex-wrap: nowrap;
		gap: var(--space-2xs);
		padding-block-end: var(--space-2xs);
		overflow-x: auto;
		scrollbar-width: none;
	}

	.attachments::-webkit-scrollbar {
		display: none;
	}

	.attachment {
		display: inline-flex;
		align-items: center;
		gap: var(--space-xs);
		max-width: 100%;
		min-height: var(--control-height);
		padding-inline: var(--space-sm);
		border: var(--rule-hair) solid var(--color-rule);
		border-radius: var(--radius-input);
		background: var(--color-paper-3);
		color: var(--color-neutral);
		cursor: pointer;
		font-size: var(--text-sm);
		white-space: nowrap;
	}

	.attachment span:first-child {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.attachment svg {
		flex: none;
		width: var(--space-sm);
		height: var(--space-sm);
		fill: none;
		stroke: currentColor;
		stroke-linecap: round;
		stroke-width: 1.75;
	}

	.composer-hint {
		display: none;
		padding-block-start: var(--space-2xs);
		color: var(--color-muted);
		font-size: var(--text-xs);
		text-align: end;
	}

	.archive-toast {
		position: fixed;
		inset-inline: var(--space-sm);
		inset-block-end: calc(var(--space-sm) + env(safe-area-inset-bottom));
		z-index: var(--z-toast);
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--space-sm);
		max-width: 26rem;
		min-height: var(--control-height);
		margin-inline: auto;
		padding: var(--space-2xs) var(--space-sm);
		border: var(--rule-hair) solid var(--color-rule-2);
		border-radius: var(--radius-input);
		background: var(--color-ink-2);
		box-shadow: var(--shadow-card);
		color: var(--color-paper);
		font-size: var(--text-sm);
	}

	.archive-toast.error {
		border-color: var(--color-error);
		background: var(--color-error-soft);
		color: var(--color-error);
	}

	.archive-toast button {
		min-height: var(--control-height-compact);
		padding-inline: var(--space-xs);
		border: var(--rule-hair) solid currentColor;
		border-radius: var(--radius-sm);
		background: transparent;
		color: inherit;
		cursor: pointer;
		font-size: var(--text-xs);
		font-weight: 600;
		transition:
			background-color var(--dur-micro) var(--ease-out),
			transform var(--dur-micro) var(--ease-out);
	}

	@media (hover: hover) and (pointer: fine) {
		.cmd-toggle:hover .cmd-text {
			color: var(--color-ink);
		}

		.delete-session {
			opacity: 0;
			pointer-events: none;
		}

		.session-row:hover .delete-session,
		.session-row:focus-within .delete-session {
			opacity: 1;
			pointer-events: auto;
		}

		.raw-toggle {
			opacity: 0;
			pointer-events: none;
		}

		.item.agent:hover .raw-toggle,
		.item.agent:focus-within .raw-toggle,
		.raw-toggle[aria-pressed='true'] {
			opacity: 1;
			pointer-events: auto;
		}

		.cwd-input:hover,
		.profile-input:hover {
			background: var(--color-paper-2);
		}

		.mini.ghost:hover,
		.attach:hover,
		.stop:hover,
		.raw-toggle:hover,
		.files-trigger:hover,
		.session-info-trigger:hover,
		.session-info-close:hover,
		.delete-session:hover,
		.new-activity:hover,
		.archive-toast button:hover {
			background: var(--color-paper-3);
		}

		.sidebar-toggle:hover,
		.drawer-close:hover {
			background: transparent;
			color: var(--color-accent-active);
		}

		.new:hover,
		.mini:not(.ghost):hover,
		.send:hover,
		.welcome-action:hover {
			background: var(--color-accent-active);
		}

		.session:hover {
			background: var(--color-paper-3);
			color: var(--color-ink);
		}

		.message-image:hover {
			color: var(--color-accent-active);
		}
	}

	.sidebar-toggle:active,
	.drawer-close:active,
	.new:active,
	.mini:active,
	.stop:active,
	.files-trigger:active,
	.session-info-trigger:active,
	.session-info-close:active,
	.attach:active,
	.send:active,
	.welcome-action:active,
	.sidebar-scrim:active,
	.session:active,
	.attachment:active {
		transform: translateY(1px);
	}

	/* .new-activity is normally lifted above the composer; :active keeps the
	   lift and adds the shared 1px press. */
	.new-activity:active {
		transform: translateY(calc(-100% - var(--space-2xs) + 1px));
	}

	.archive-toast button:active,
	.delete-session:active {
		transform: translateY(1px);
	}

	.message-image:active {
		opacity: 0.72;
	}

	@media (min-width: 40rem) {
		.welcome {
			padding-inline: var(--space-xl);
		}

		.goal-tracker {
			flex-direction: row;
			align-items: center;
			justify-content: space-between;
		}

		.goal-metrics {
			flex: 0 0 auto;
		}

		.transcript {
			padding-inline: var(--space-lg);
		}

		.composer-shell {
			padding-inline: var(--space-lg);
		}

		.attachments {
			flex-wrap: wrap;
			overflow-x: visible;
		}

		.composer {
			grid-template-areas: 'attach message send';
		}

	}

	@media (min-width: 60rem) {
		.app {
			grid-template-columns: var(--rail-width) minmax(0, 1fr);
		}

		.app.rail-hidden {
			grid-template-columns: minmax(0, 1fr);
		}

		.sidebar-scrim,
		.app:not(.rail-hidden) .welcome-menu,
		.app:not(.rail-hidden) .header-menu {
			display: none;
		}

		.app.rail-hidden .sidebar {
			display: none;
		}

		.sidebar,
		.sidebar.open {
			position: relative;
			inset: auto;
			z-index: var(--z-base);
			width: auto;
			padding-block-start: 0;
			box-shadow: none;
			transform: none;
			transition: none;
		}

		.brand {
			padding-inline: var(--space-sm);
		}

		.topbar {
			grid-template-columns: minmax(16rem, 1fr) auto auto;
			gap: var(--space-2xs) var(--space-xs);
			padding: calc(var(--space-xs) + env(safe-area-inset-top)) var(--space-xs) var(--space-xs);
		}

		.app.rail-hidden .topbar {
			grid-template-columns: auto minmax(16rem, 1fr) auto auto;
		}

		.session-meta,
		.session-facts {
			display: flex;
		}

		.session-facts {
			grid-column: auto;
			justify-self: end;
		}

		.session-state {
			flex: none;
		}

		.welcome {
			grid-template-columns: minmax(0, 1.18fr) minmax(0, 0.82fr);
			align-items: end;
			gap: var(--space-2xl);
			padding-block: var(--space-2xl);
		}

		.welcome h1 {
			font-size: var(--text-display);
		}

		.message-image img {
			max-width: 32.5rem;
		}

		.composer-hint {
			display: block;
		}
	}

	@media (min-width: 90rem) {
		.welcome {
			gap: var(--space-3xl);
		}

		.transcript {
			padding-block-start: var(--space-sm);
		}
	}

	@media (min-width: 60rem) and (hover: hover) and (pointer: fine) {
		.new,
		.mini,
		.stop,
		.files-trigger,
		.session-info-trigger,
		.session-info-close,
		.attach,
		.send,
		.attachment,
		.cwd-input,
		.profile-input,
		textarea {
			min-height: var(--control-height-compact);
		}

		.attach,
		.send,
		.new,
		.stop,
		.files-trigger,
		.session-info-trigger,
		.session-info-close {
			width: var(--control-height-compact);
			min-width: var(--control-height-compact);
			height: var(--control-height-compact);
		}

		textarea {
			padding-block: calc((var(--control-height-compact) - 1.4em) / 2);
		}

		.session {
			min-height: var(--control-height-compact);
		}
	}

	@media (hover: none), (pointer: coarse) {
		.raw-toggle {
			opacity: 0;
			pointer-events: none;
		}

		.item.agent.tapped .raw-toggle,
		.item.agent:focus-within .raw-toggle,
		.raw-toggle[aria-pressed='true'] {
			opacity: 1;
			pointer-events: auto;
		}
	}

	@media (pointer: coarse) {
		.cmd-toggle {
			min-height: var(--control-height);
		}

		.sidebar-toggle,
		.drawer-close,
		.new,
		.mini,
		.stop,
		.files-trigger,
		.session-info-trigger,
		.session-info-close,
		.attach,
		.send,
		.welcome-action,
		.delete-session,
		.attachment,
		.new-activity,
		.archive-toast button,
		.slash-option,
		.raw-toggle,
		.session {
			min-height: var(--control-height);
		}

		.delete-session,
		.raw-toggle {
			width: var(--control-height);
		}
	}

	@media (prefers-reduced-motion: reduce) {
		*,
		*::before,
		*::after {
			animation-duration: var(--dur-micro) !important;
			animation-iteration-count: 1 !important;
			transition-duration: var(--dur-micro) !important;
		}

		.run-dot.running,
		.session-state-dot.running {
			animation: none;
		}
	}

	@keyframes pulse-status {
		50% {
			opacity: 0.38;
		}
	}
</style>
