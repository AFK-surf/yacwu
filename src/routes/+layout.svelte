<script lang="ts">
	import { onMount, tick, untrack } from 'svelte';
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import type { JsonRpcNotification, ThreadItem, ThreadSummary, Turn } from '$lib/protocol';
	import { parseSlash, SLASH_HELP } from '$lib/slash';

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
		error: string | null;
		goal: Goal | null;
	}

	interface SelectedImage {
		id: string;
		file: File;
		name: string;
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
	let sessionsLoaded = $state(false);
	let threads = $state<Record<string, ThreadState>>({});
	let input = $state('');
	let selectedImages = $state<SelectedImage[]>([]);
	let sendingMessage = $state(false);
	let connected = $state(false);
	let loadingHistory = $state(false);
	let cwds = $state<Record<string, string>>({});
	let conflict = $state<{ id: string; holders: { pid: number; command: string }[] } | null>(null);
	let mobileSidebarOpen = $state(false);
	let mobileViewport = $state(false);
	let imageInputEl = $state<HTMLInputElement | null>(null);
	let transcriptScrollTop = $state(0);
	let transcriptViewportHeight = $state(0);
	let transcriptHeightVersion = $state(0);
	const rowHeights = new Map<string, number>();
	const ESTIMATED_ROW_HEIGHT = 72;
	const VIRTUAL_OVERSCAN_PX = 700;

	// The active session is whatever is in the URL (/s/<id>); / shows the welcome.
	const activeId = $derived(page.params.id ?? null);
	const active = $derived(activeId ? threads[activeId] : null);
	const activeSummary = $derived(sessions.find((s) => s.id === activeId) ?? null);
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
	const composerPlaceholder = $derived(
		mobileViewport ? 'message codex' : 'message codex…  (Enter to send, Shift+Enter for newline)'
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
				error: null,
				goal: null
			};
		}
		return threads[id];
	}

	function upsertItem(id: string, item: ThreadItem & { id: string }) {
		const t = ensureThread(id);
		if (!t.byId[item.id]) t.order.push(item.id);
		// Preserve any locally-accumulated streamed text across updates.
		const prev = t.byId[item.id] as any;
		const next = { ...item } as any;
		if (prev) {
			if (next.text === '' && prev.text) next.text = prev.text;
			if (next._reason === undefined && prev._reason) next._reason = prev._reason;
			if (next._out === undefined && prev._out) next._out = prev._out;
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

	function upsertSession(thr: any) {
		if (!thr?.id) return;
		if (thr.cwd) cwds[thr.id] = thr.cwd;
		const now = Date.now();
		// Preserve relationship metadata when a payload omits it (codex reports
		// forkedFromId only in the thread/fork response, not on later reads).
		const existing = sessions.find((s) => s.id === thr.id);
		const summary: ThreadSummary = {
			id: thr.id,
			preview: thr.preview ?? '',
			name: thr.name ?? null,
			createdAt: thr.createdAt ?? now,
			updatedAt: thr.updatedAt ?? thr.createdAt ?? now,
			cwd: thr.cwd,
			forkedFromId: thr.forkedFromId ?? existing?.forkedFromId ?? null,
			ephemeral: thr.ephemeral ?? existing?.ephemeral ?? false
		};
		sessions = [summary, ...sessions.filter((s) => s.id !== thr.id)];
	}

	function removeSession(id: string) {
		sessions = sessions.filter((s) => s.id !== id);
		delete threads[id];
		delete cwds[id];
		sessionStorage.removeItem(sideParentKey(id));
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
			case 'turn/started': {
				if (tid) {
					const t = ensureThread(tid);
					t.status = 'running';
					t.turnId = p.turn?.id ?? null;
					t.error = null;
				}
				break;
			}
			case 'turn/completed': {
				if (tid) {
					const t = ensureThread(tid);
					t.status = 'idle';
					t.turnId = null;
					if (p.turn?.status === 'failed' && p.turn?.error?.message) {
						t.error = p.turn.error.message;
					}
				}
				break;
			}
			case 'item/started':
			case 'item/completed': {
				if (tid && p.item?.id) upsertItem(tid, p.item);
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
					t.tokens = p.tokenUsage?.total?.totalTokens ?? t.tokens;
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

		if (shouldScroll) scrollToBottom();
	}

	function isTranscriptAtBottom(): boolean {
		if (!transcriptEl) return true;
		const remaining = transcriptEl.scrollHeight - transcriptEl.scrollTop - transcriptEl.clientHeight;
		return remaining <= 24;
	}

	async function scrollToBottom() {
		await tick();
		if (!transcriptEl) return;
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
					if (thr?.ephemeral) {
						const parentId = sessionStorage.getItem(sideParentKey(thr.id));
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
		creating = true;
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

	async function newSession(cwd?: string) {
		createError = null;
		const profile = newProfile.trim();
		const res = await fetch('/api/threads', {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({ ...(cwd ? { cwd } : {}), ...(profile ? { profile } : {}) })
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
			upsertSession(data.thread);
			goto(`/s/${id}`);
			mobileSidebarOpen = false;
		}
	}

	// Open the session named in the URL whenever it changes. Only the URL id is a
	// reactive dependency; the rest runs untracked so item updates don't re-trigger.
	$effect(() => {
		const id = page.params.id ?? null;
		untrack(() => {
			conflict = null;
			if (!id) return;
			const t = ensureThread(id);
			if (t.order.length > 0) {
				scrollToBottom();
				return;
			}
			openSession(id, false);
		});
	});

	async function openSession(id: string, force: boolean) {
		loadingHistory = true;
		try {
			const res = await fetch(`/api/threads/${id}/open`, {
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
			// Only sync the transcript when the server actually returned history.
			// A failed open (e.g. a brand-new thread with no rollout yet) must not
			// wipe locally rendered items — the response can arrive late, after
			// the user has already run slash commands in this session.
			if (thr) replaceItems(id, thr.turns ?? []);
			// Surface any persisted goal for this session.
			fetch(`/api/threads/${id}/goal`)
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
			return fetch(`/api/threads/${id}/message`, { method: 'POST', body });
		}

		return fetch(`/api/threads/${id}/message`, {
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
		lines.push(`  state     ${t?.status ?? 'idle'}`);
		try {
			const res = await fetch(`/api/threads/${id}/model`);
			const settings = (await res.json()) as Partial<ModelState> & { error?: string };
			if (!res.ok) throw new Error(settings.error ?? 'model settings unavailable');
			if (settings.model) lines.push(`  model     ${settings.model}`);
			if (settings.effort) lines.push(`  effort    ${settings.effort}`);
		} catch {
			lines.push('  model     unavailable');
			lines.push('  effort    unavailable');
		}
		try {
			const res = await fetch(`/api/threads/${id}/profile`);
			const data = await res.json();
			if (res.ok && data.profile) lines.push(`  profile   ${data.profile}`);
		} catch {
			/* no profile line */
		}
		if (t?.tokens) lines.push(`  tokens    ${t.tokens.toLocaleString()}`);
		if (t?.goal) lines.push(`  goal      ${t.goal.objective} (${t.goal.status})`);
		try {
			const acc = await (await fetch('/api/account')).json();
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
		const res = await fetch(`/api/threads/${id}/${path}`, {
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

			case 'model-show': {
				try {
					const res = await fetch(`/api/threads/${id}/model`);
					const data = await res.json();
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
				break;
			}

			case 'profile-show': {
				try {
					const res = await fetch(`/api/threads/${id}/profile`);
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
				break;
			}

			case 'profile-clear': {
				const { ok, data } = await postCmd(id, 'profile', { clear: true });
				addLocalNote(
					id,
					ok ? 'profile cleared (base config)' : data.error ?? 'failed to clear profile',
					ok ? 'info' : 'err'
				);
				break;
			}

			case 'goal-show': {
				let g = threads[id]?.goal;
				try {
					const res = await fetch(`/api/threads/${id}/goal`);
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
					upsertSession(data.thread);
					ensureThread(data.thread.id);
					addLocalNote(id, `forked into ${data.thread.id.slice(0, 8)}`);
					goto(`/s/${data.thread.id}`);
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
				upsertSession({ ...data.thread, forkedFromId: id, ephemeral: true });
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
				goto(`/s/${sideId}`);
				break;
			}

			case 'archive': {
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
		await fetch(`/api/threads/${activeId}/interrupt`, {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({ turnId: t?.turnId })
		});
	}

	async function deleteSession(id: string) {
		const session = sessions.find((s) => s.id === id);
		const label = session ? shortLabel(session) : id.slice(0, 8);
		if (!confirm(`Delete session "${label}"?`)) return;
		const res = await fetch(`/api/threads/${id}/archive`, {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({})
		});
		if (!res.ok) {
			const data = await res.json().catch(() => ({}));
			alert(data.error ?? 'failed to delete session');
			return;
		}
		removeSession(id);
		if (activeId === id) goto('/');
	}

	function onKeydown(e: KeyboardEvent) {
		if (e.key === 'Enter' && !e.shiftKey) {
			e.preventDefault();
			send();
		}
	}

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
		const mobileQuery = window.matchMedia('(max-width: 760px)');
		const updateMobileViewport = () => (mobileViewport = mobileQuery.matches);
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
			mobileQuery.removeEventListener('change', updateMobileViewport);
		};
	});
</script>

<svelte:head>
	<link rel="preconnect" href="https://fonts.googleapis.com" />
</svelte:head>

<div class={mobileSidebarOpen ? 'app sidebar-open' : 'app'}>
	<button
		class="sidebar-toggle"
		aria-label={mobileSidebarOpen ? 'close sessions' : 'open sessions'}
		aria-expanded={mobileSidebarOpen}
		onclick={() => (mobileSidebarOpen = !mobileSidebarOpen)}
	>
		{mobileSidebarOpen ? '×' : '☰'}
	</button>
	<button
		class="sidebar-scrim"
		aria-label="close sessions"
		onclick={() => (mobileSidebarOpen = false)}
	></button>

	<aside class="sidebar" class:open={mobileSidebarOpen}>
		<div class="brand">
			<span class="prompt">$</span> yacwu
			<span class="dot" class:on={connected} title={connected ? 'connected' : 'disconnected'}></span>
		</div>
		{#if creating}
			<div class="create">
				<div class="create-row">
					<span class="prompt">cd</span>
					<input
						class="cwd-input"
						bind:this={cwdInputEl}
						bind:value={newCwd}
						onkeydown={onCwdKeydown}
						placeholder={defaultCwd || 'working directory'}
						spellcheck="false"
						autocapitalize="off"
						autocomplete="off"
					/>
				</div>
				{#if profileChoices.length > 0}
					<div class="create-row">
						<span class="prompt">-p</span>
						<select class="profile-input" bind:value={newProfile}>
							<option value="">(base config)</option>
							{#each profileChoices as p (p.name)}
								<option value={p.name}>{p.name}{p.model ? ` · ${p.model}` : ''}</option>
							{/each}
						</select>
					</div>
				{/if}
				<div class="create-actions">
					<button class="mini" onclick={() => newSession(newCwd.trim() || undefined)}>start</button>
					<button class="mini ghost" onclick={cancelCreating}>esc</button>
					<span class="create-hint">blank = default</span>
				</div>
				{#if createError}<div class="create-err">{createError}</div>{/if}
			</div>
		{:else}
			<button class="new" onclick={startCreating}>+ new session</button>
		{/if}
		<nav class="sessions" data-loaded={sessionsLoaded}>
			{#each topSessions as s (s.id)}
				<div class="session-row">
					<a
						class="session"
						class:active={s.id === activeId}
						data-id={s.id}
						href={`/s/${s.id}`}
						onclick={() => (mobileSidebarOpen = false)}
					>
						<span class="run-dot" class:running={threads[s.id]?.status === 'running'}></span>
						<span class="label">{#if isSideChat(s)}⎇ {/if}{shortLabel(s)}</span>
						{#if s.cwd}<span class="cwd">{s.cwd}</span>{/if}
					</a>
					<button
						class="delete-session"
						type="button"
						aria-label={`delete session ${shortLabel(s)}`}
						onclick={() => deleteSession(s.id)}
					>
						×
					</button>
				</div>
				{#each sideChatsOf(s.id) as side (side.id)}
					<div class="session-row side-row">
						<a
							class="session side"
							class:active={side.id === activeId}
							data-id={side.id}
							href={`/s/${side.id}`}
							onclick={() => (mobileSidebarOpen = false)}
						>
							<span class="run-dot" class:running={threads[side.id]?.status === 'running'}></span>
							<span class="label">⎇ {shortLabel(side)}</span>
						</a>
						<button
							class="delete-session"
							type="button"
							aria-label={`delete session ${shortLabel(side)}`}
							onclick={() => deleteSession(side.id)}
						>
							×
						</button>
					</div>
				{/each}
			{:else}
				<div class="empty">no sessions yet</div>
			{/each}
		</nav>
		<div class="hint">{topSessions.length} session{topSessions.length === 1 ? '' : 's'}</div>
	</aside>

	<main class="chat">
		{#if !activeId}
			<div class="welcome">
				<pre>{`
 _   _  __ _  ___ __      ___   _
| | | |/ _\` |/ __|\\ \\ /\\ / / | | |
| |_| | (_| | (__  \\ V  V /| |_| |
 \\__, |\\__,_|\\___|  \\_/\\_/  \\__,_|
 |___/      yet another codex web ui
`}</pre>
				<p>Select a session on the left, or start a <button class="inline" onclick={startCreating}>new one</button>.</p>
			</div>
		{:else}
			<div class="topbar">
				{#if activeParent}
					<span class="tid dim">{activeParent.id.slice(0, 8)}</span>
					<span class="tid-sep">⎇</span>
				{/if}
				<span class="tid">{activeId.slice(0, 8)}</span>
				{#if cwds[activeId]}<span class="meta">{cwds[activeId]}</span>{/if}
				{#if active?.goal}
					<span class="goal" title={active.goal.objective}>
						◎ {active.goal.objective}{#if active.goal.tokenBudget}
							<span class="goal-budget"
								>{Math.round(active.goal.tokensUsed / 1000)}k/{Math.round(
									active.goal.tokenBudget / 1000
								)}k</span
							>{/if}
					</span>
				{/if}
				<span class="spacer"></span>
				<div class="session-state">
					{#if active?.tokens}<span class="meta tokens">{active.tokens.toLocaleString()} tok</span>{/if}
					{#if active?.status === 'running'}
						<span class="status running">● running</span>
						<button class="stop" onclick={interrupt}>stop</button>
					{:else}
						<span class="status">● idle</span>
					{/if}
				</div>
			</div>

			{#if activeIsSide}
				<div class="side-banner">
					<span class="side-banner-label">⎇ side conversation · ephemeral — not saved</span>
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
					<div class="conflict-head">⚠ session in use by another codex instance</div>
					<div class="conflict-body">
						This conversation's rollout is open in
						{#each conflict.holders as h, i}{i > 0 ? ', ' : ' '}<code>{h.command} (pid {h.pid})</code>{/each}.
						Opening it here too can corrupt its history.
					</div>
					<div class="conflict-actions">
						<button class="mini danger" onclick={forceOpen}>open anyway</button>
						<button class="mini ghost" onclick={dismissConflict}>cancel</button>
					</div>
				</div>
			{:else}
				<div class="transcript" bind:this={transcriptEl} onscroll={onTranscriptScroll}>
					{#if loadingHistory}
						<div class="sys">loading history…</div>
					{/if}
					<div class="transcript-spacer" style={`height: ${virtualTranscript.before}px`}></div>
					{#each virtualTranscript.items as item (item.id)}
						<div class="virtual-row" use:measureTranscriptRow={transcriptRowKey(item)}>
							{#if item.type === 'userMessage'}
								<div class="item user">
									<span class="gutter">›</span>
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
								<div class="item agent">
									<div class="body media-body">
										{#each agentParts((item as any).text ?? '') as part}
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
							{:else if item.type === 'reasoning'}
								{#if reasoningText(item)}
									<div class="item reason">
										<span class="gutter">∴</span>
										<div class="body">{reasoningText(item)}</div>
									</div>
								{/if}
							{:else if item.type === 'commandExecution'}
								<div class="item cmd">
									<div class="cmd-line">
										<span class="gutter">$</span>
										<span class="cmd-text">{(item as any).command}</span>
										<span class="cmd-status {(item as any).status}">{(item as any).status}{#if (item as any).exitCode !== undefined && (item as any).exitCode !== null}({(item as any).exitCode}){/if}</span>
									</div>
									{#if (item as any)._out || (item as any).aggregatedOutput}
										<pre class="cmd-out">{(item as any)._out || (item as any).aggregatedOutput}</pre>
									{/if}
								</div>
							{:else if item.type === 'fileChange'}
								<div class="item file">
									<span class="gutter">±</span>
									<div class="body">
										{#each (item as any).changes ?? [] as ch}
											<div class="fc">
												<span class="kind {fileChangeClass(ch)}">{fileChangeKind(ch)}</span>
												{fileChangePath(ch)}
											</div>
										{/each}
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
						<div class="item agent"><div class="body blink">▍</div></div>
					{/if}
					{#if active?.error}
						<div class="item err"><span class="gutter">✗</span><div class="body">{active.error}</div></div>
					{/if}
				</div>

				<div class="composer">
					<span class="prompt">›</span>
					<input
						bind:this={imageInputEl}
						class="image-input"
						type="file"
						accept="image/*"
						multiple
						onchange={onImagesSelected}
					/>
					<button class="attach" type="button" onclick={chooseImages} title="Attach images">img</button>
					<textarea
						placeholder={composerPlaceholder}
						bind:value={input}
						onkeydown={onKeydown}
						rows="1"
					></textarea>
					<button class="send" onclick={send} disabled={sendingMessage || (!input.trim() && selectedImages.length === 0)}>
						send
					</button>
				</div>
				{#if selectedImages.length > 0}
					<div class="attachments">
						{#each selectedImages as image (image.id)}
							<button class="attachment" type="button" onclick={() => removeSelectedImage(image.id)}>
								<span>{image.name}</span>
								<span aria-hidden="true">×</span>
							</button>
						{/each}
					</div>
				{/if}
			{/if}
		{/if}
	</main>
</div>

{@render children()}

<style>
	:global(:root) {
		--bg: #0a0e14;
		--bg-alt: #0d1117;
		--panel: #11161d;
		--border: #1c2530;
		--fg: #c9d1d9;
		--fg-dim: #6b7681;
		--accent: #39d353;
		--accent-dim: #2ea043;
		--user: #58a6ff;
		--reason: #8b6f9e;
		--cmd: #d29922;
		--err: #f85149;
		--mono: ui-monospace, 'SF Mono', 'JetBrains Mono', 'Fira Code', Menlo, Consolas, monospace;
	}
	:global(*) {
		box-sizing: border-box;
	}
	:global(html, body) {
		margin: 0;
		padding: 0;
		height: 100%;
		background: var(--bg);
		color: var(--fg);
		font-family: var(--mono);
		font-size: 13px;
		line-height: 1.55;
	}
	:global(body) {
		overflow: hidden;
	}
	:global(::-webkit-scrollbar) {
		width: 10px;
		height: 10px;
	}
	:global(::-webkit-scrollbar-thumb) {
		background: var(--border);
		border-radius: 5px;
	}
	:global(::-webkit-scrollbar-track) {
		background: transparent;
	}

	.app {
		display: grid;
		grid-template-columns: 260px 1fr;
		height: 100vh;
		height: 100dvh;
		width: 100vw;
	}

	.sidebar-toggle,
	.sidebar-scrim {
		display: none;
	}

	.sidebar {
		border-right: 1px solid var(--border);
		background: var(--bg-alt);
		display: flex;
		flex-direction: column;
		min-height: 0;
	}
	.brand {
		padding: 14px 16px;
		font-weight: 600;
		letter-spacing: 0.5px;
		border-bottom: 1px solid var(--border);
		display: flex;
		align-items: center;
		gap: 7px;
	}
	.brand .prompt {
		color: var(--accent);
	}
	.dot {
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: var(--err);
		margin-left: auto;
	}
	.dot.on {
		background: var(--accent);
		box-shadow: 0 0 6px var(--accent);
	}
	.new {
		margin: 10px;
		padding: 8px;
		background: transparent;
		border: 1px dashed var(--border);
		color: var(--fg-dim);
		border-radius: 6px;
		cursor: pointer;
		font-family: var(--mono);
		font-size: 12px;
	}
	.new:hover {
		color: var(--accent);
		border-color: var(--accent-dim);
	}
	.create {
		margin: 10px;
		padding: 8px;
		border: 1px solid var(--border);
		border-radius: 6px;
		background: var(--panel);
		display: flex;
		flex-direction: column;
		gap: 7px;
	}
	.create-row {
		display: flex;
		align-items: center;
		gap: 6px;
	}
	.create-row .prompt {
		color: var(--accent);
		font-size: 12px;
	}
	.cwd-input {
		flex: 1;
		min-width: 0;
		background: var(--bg);
		border: 1px solid var(--border);
		border-radius: 4px;
		color: var(--fg);
		font-family: var(--mono);
		font-size: 12px;
		padding: 5px 7px;
	}
	.cwd-input:focus {
		outline: none;
		border-color: var(--accent-dim);
	}
	.profile-input {
		flex: 1;
		min-width: 0;
		background: var(--bg);
		border: 1px solid var(--border);
		border-radius: 4px;
		color: var(--fg);
		font-family: var(--mono);
		font-size: 12px;
		padding: 5px 7px;
	}
	.profile-input:focus {
		outline: none;
		border-color: var(--accent-dim);
	}
	.cwd-input::placeholder {
		color: var(--fg-dim);
		opacity: 0.6;
	}
	.create-actions {
		display: flex;
		align-items: center;
		gap: 6px;
	}
	.mini {
		background: var(--accent-dim);
		border: none;
		color: #02110a;
		font-weight: 600;
		border-radius: 4px;
		padding: 4px 10px;
		cursor: pointer;
		font-family: var(--mono);
		font-size: 11px;
	}
	.mini.ghost {
		background: transparent;
		border: 1px solid var(--border);
		color: var(--fg-dim);
		font-weight: 400;
	}
	.mini.danger {
		background: transparent;
		border: 1px solid var(--err);
		color: var(--err);
	}
	.conflict {
		margin: 14px 18px 0;
		padding: 12px 14px;
		border: 1px solid var(--err);
		border-radius: 6px;
		background: rgba(248, 81, 73, 0.08);
		display: flex;
		flex-direction: column;
		gap: 8px;
	}
	.conflict-head {
		color: var(--err);
		font-weight: 600;
	}
	.conflict-body {
		color: var(--fg);
		font-size: 12px;
		line-height: 1.5;
	}
	.conflict-body code {
		color: var(--cmd);
		word-break: break-all;
	}
	.conflict-actions {
		display: flex;
		gap: 8px;
	}
	.create-hint {
		margin-left: auto;
		color: var(--fg-dim);
		font-size: 10px;
		opacity: 0.7;
	}
	.create-err {
		color: var(--err);
		font-size: 11px;
		word-break: break-word;
	}
	.sessions {
		flex: 1;
		overflow-y: auto;
		padding: 0 8px;
		min-height: 0;
	}
	.session-row {
		position: relative;
		margin-bottom: 2px;
	}
	.session {
		width: 100%;
		text-align: left;
		text-decoration: none;
		background: transparent;
		border: none;
		color: var(--fg-dim);
		padding: 8px 10px;
		border-radius: 6px;
		cursor: pointer;
		font-family: var(--mono);
		font-size: 12px;
		display: flex;
		flex-direction: column;
		gap: 2px;
		padding-right: 34px;
	}
	.session:hover {
		background: var(--panel);
		color: var(--fg);
	}
	.session.active {
		background: var(--panel);
		color: var(--fg);
		box-shadow: inset 2px 0 0 var(--accent);
	}
	.session .label {
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.session .cwd {
		font-size: 10px;
		color: var(--fg-dim);
		opacity: 0.6;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.session-row.side-row .session {
		padding-left: 26px;
	}
	.session.side .label {
		font-style: italic;
		opacity: 0.85;
	}
	.side-banner {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 6px 18px;
		border-bottom: 1px solid var(--border);
		background: var(--bg-alt);
		font-size: 12px;
		color: var(--fg-dim);
	}
	.side-banner .meta {
		color: var(--fg-dim);
		opacity: 0.7;
	}
	.delete-session {
		position: absolute;
		top: 6px;
		right: 6px;
		display: grid;
		place-items: center;
		width: 24px;
		height: 24px;
		background: transparent;
		border: 1px solid transparent;
		border-radius: 5px;
		color: var(--fg-dim);
		cursor: pointer;
		font-family: var(--mono);
		font-size: 16px;
		line-height: 1;
		opacity: 0.65;
	}
	.delete-session:hover {
		border-color: var(--err);
		color: var(--err);
		opacity: 1;
	}
	.run-dot {
		display: inline-block;
		width: 6px;
		height: 6px;
		border-radius: 50%;
		background: transparent;
	}
	.run-dot.running {
		background: var(--cmd);
		box-shadow: 0 0 6px var(--cmd);
		animation: pulse 1s infinite;
	}
	.empty {
		color: var(--fg-dim);
		padding: 16px 10px;
		font-size: 12px;
		opacity: 0.6;
	}
	.hint {
		padding: 10px 16px;
		border-top: 1px solid var(--border);
		color: var(--fg-dim);
		font-size: 11px;
	}

	.chat {
		display: flex;
		flex-direction: column;
		min-width: 0;
		min-height: 0;
	}
	.welcome {
		margin: auto;
		text-align: center;
		color: var(--fg-dim);
	}
	.welcome pre {
		color: var(--accent);
		font-size: 12px;
		line-height: 1.3;
	}
	.inline {
		background: none;
		border: none;
		color: var(--accent);
		cursor: pointer;
		font-family: var(--mono);
		font-size: inherit;
		text-decoration: underline;
		padding: 0;
	}

	.topbar {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 10px 18px;
		border-bottom: 1px solid var(--border);
		font-size: 12px;
	}
	.topbar .tid {
		color: var(--accent);
	}
	.topbar .tid.dim {
		color: var(--fg-dim);
	}
	.topbar .tid-sep {
		color: var(--accent);
	}
	.topbar .meta {
		color: var(--fg-dim);
	}
	.goal {
		color: var(--accent);
		max-width: 40%;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.goal-budget {
		color: var(--fg-dim);
		margin-left: 6px;
	}
	.goal-tracker {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 16px;
		padding: 10px 18px;
		border-bottom: 1px solid var(--border);
		background: rgba(65, 184, 131, 0.07);
		font-size: 12px;
	}
	.goal-main {
		display: flex;
		align-items: center;
		gap: 9px;
		min-width: 0;
	}
	.goal-marker,
	.goal-state {
		flex: 0 0 auto;
		color: var(--accent);
	}
	.goal-objective {
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		color: var(--fg);
	}
	.goal-state {
		border: 1px solid rgba(65, 184, 131, 0.35);
		border-radius: 5px;
		padding: 2px 6px;
		font-size: 11px;
	}
	.goal-metrics {
		display: flex;
		align-items: center;
		gap: 10px;
		flex: 0 0 auto;
		color: var(--fg-dim);
		white-space: nowrap;
	}
	.goal-progress {
		width: 120px;
		height: 5px;
		overflow: hidden;
		border-radius: 999px;
		background: rgba(255, 255, 255, 0.08);
	}
	.goal-progress span {
		display: block;
		height: 100%;
		background: var(--accent);
	}
	.spacer {
		flex: 1;
	}
	.session-state {
		display: flex;
		align-items: center;
		gap: 12px;
	}
	.status {
		color: var(--fg-dim);
	}
	.status.running {
		color: var(--cmd);
	}
	.stop {
		background: transparent;
		border: 1px solid var(--err);
		color: var(--err);
		border-radius: 5px;
		padding: 3px 9px;
		cursor: pointer;
		font-family: var(--mono);
		font-size: 11px;
	}

	.transcript {
		flex: 1;
		overflow-y: auto;
		padding: 18px;
		min-height: 0;
		overflow-anchor: none;
	}
	.transcript-spacer {
		flex: none;
	}
	.virtual-row {
		padding-bottom: 10px;
	}
	.sys {
		color: var(--fg-dim);
		font-style: italic;
		padding-bottom: 10px;
	}
	.item {
		display: flex;
		gap: 10px;
		align-items: flex-start;
	}
	.gutter {
		flex: none;
		width: 12px;
		text-align: center;
		color: var(--fg-dim);
		user-select: none;
	}
	.body {
		white-space: pre-wrap;
		word-break: break-word;
		flex: 1;
		min-width: 0;
	}
	.item.user .gutter {
		color: var(--user);
	}
	.item.user .body {
		color: var(--user);
	}
	.item.agent .body {
		color: var(--fg);
	}
	.media-body {
		display: flex;
		flex-direction: column;
		gap: 8px;
		white-space: pre-wrap;
	}
	.message-image {
		width: fit-content;
		max-width: 100%;
		color: var(--fg-dim);
		text-decoration: none;
		font-size: 11px;
	}
	.message-image img {
		display: block;
		max-width: min(520px, 100%);
		max-height: 360px;
		border: 1px solid var(--border);
		border-radius: 6px;
		background: #06090d;
		object-fit: contain;
	}
	.message-image span {
		display: block;
		margin-top: 4px;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.item.reason .body {
		color: var(--reason);
		font-style: italic;
		opacity: 0.85;
	}
	.item.reason .gutter {
		color: var(--reason);
	}
	.item.cmd {
		flex-direction: column;
		gap: 2px;
		align-items: stretch;
	}
	.cmd-line {
		display: flex;
		gap: 8px;
		align-items: baseline;
	}
	.cmd-text {
		color: var(--cmd);
		flex: 1;
		white-space: pre-wrap;
		word-break: break-word;
	}
	.cmd-status {
		font-size: 11px;
		color: var(--fg-dim);
	}
	.cmd-status.completed {
		color: var(--accent);
	}
	.cmd-status.failed {
		color: var(--err);
	}
	.cmd-out {
		margin: 4px 0 0 20px;
		padding: 6px 10px;
		background: #06090d;
		border-left: 2px solid var(--border);
		color: var(--fg-dim);
		font-size: 12px;
		max-height: 320px;
		overflow: auto;
		white-space: pre-wrap;
		word-break: break-word;
	}
	.item.file .gutter {
		color: var(--accent);
	}
	.fc .kind {
		color: var(--accent);
		text-transform: uppercase;
		font-size: 10px;
		margin-right: 6px;
	}
	.item.plan .gutter {
		color: var(--cmd);
	}
	.step {
		color: var(--fg-dim);
	}
	.step.completed {
		color: var(--accent);
	}
	.step.inProgress {
		color: var(--cmd);
	}
	.item.err .gutter,
	.item.err .body {
		color: var(--err);
	}
	.item.generic .body {
		color: var(--fg-dim);
		font-size: 11px;
	}
	.item.note .gutter,
	.item.note .body {
		color: var(--fg-dim);
	}
	.item.note .body {
		font-style: italic;
		white-space: pre-wrap;
	}
	.item.note.err .gutter,
	.item.note.err .body {
		color: var(--err);
		font-style: normal;
	}
	.item.review .gutter {
		color: var(--accent);
	}
	.item.review .body {
		color: var(--fg);
		border-left: 2px solid var(--accent-dim);
		padding-left: 10px;
	}
	.item.subagent .gutter {
		color: var(--accent);
	}
	.item.subagent .body {
		color: var(--fg-dim);
	}
	.item.subagent .agent-path {
		color: var(--accent);
	}
	.item.collab {
		flex-direction: column;
		gap: 2px;
		align-items: stretch;
	}
	.item.collab .gutter {
		color: var(--accent);
	}
	.collab-line {
		display: flex;
		gap: 8px;
		align-items: baseline;
	}
	.collab-text {
		flex: 1;
		color: var(--fg);
		white-space: pre-wrap;
		word-break: break-word;
	}
	.collab-detail {
		margin-left: 20px;
		color: var(--fg-dim);
		font-size: 12px;
		white-space: pre-wrap;
		word-break: break-word;
	}
	.blink {
		animation: blink 1s step-start infinite;
		color: var(--accent);
	}

	.composer {
		display: flex;
		align-items: flex-end;
		gap: 8px;
		padding: 12px 18px;
		border-top: 1px solid var(--border);
		background: var(--bg-alt);
	}
	.composer .prompt {
		color: var(--accent);
		padding-bottom: 8px;
	}
	.image-input {
		display: none;
	}
	.attach {
		background: transparent;
		border: 1px solid var(--border);
		color: var(--fg-dim);
		border-radius: 6px;
		padding: 9px 12px;
		cursor: pointer;
		font-family: var(--mono);
		font-size: 12px;
	}
	.attach:hover {
		color: var(--accent);
		border-color: var(--accent-dim);
	}
	textarea {
		flex: 1;
		resize: none;
		background: var(--panel);
		border: 1px solid var(--border);
		color: var(--fg);
		border-radius: 6px;
		padding: 8px 10px;
		font-family: var(--mono);
		font-size: 13px;
		line-height: 1.5;
		max-height: 180px;
		min-height: 38px;
	}
	textarea:focus {
		outline: none;
		border-color: var(--accent-dim);
	}
	.send {
		background: var(--accent-dim);
		border: none;
		color: #02110a;
		font-weight: 600;
		border-radius: 6px;
		padding: 9px 16px;
		cursor: pointer;
		font-family: var(--mono);
		font-size: 12px;
	}
	.send:disabled {
		opacity: 0.4;
		cursor: not-allowed;
	}
	.attachments {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
		padding: 0 18px 12px 38px;
		background: var(--bg-alt);
		border-top: 1px solid transparent;
	}
	.attachment {
		display: inline-flex;
		align-items: center;
		max-width: min(260px, 100%);
		gap: 8px;
		background: var(--panel);
		border: 1px solid var(--border);
		border-radius: 6px;
		color: var(--fg-dim);
		cursor: pointer;
		font-family: var(--mono);
		font-size: 11px;
		padding: 5px 8px;
	}
	.attachment span:first-child {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	@media (max-width: 760px) {
		:global(html, body) {
			font-size: 12px;
		}

		.app {
			grid-template-columns: 1fr;
			overflow: hidden;
		}

		.sidebar-toggle {
			position: fixed;
			top: calc(8px + env(safe-area-inset-top));
			left: 8px;
			z-index: 40;
			display: grid;
			place-items: center;
			width: 38px;
			height: 38px;
			background: var(--panel);
			border: 1px solid var(--border);
			border-radius: 6px;
			color: var(--fg);
			cursor: pointer;
			font-family: var(--mono);
			font-size: 20px;
			line-height: 1;
		}

		.sidebar-scrim {
			position: fixed;
			inset: 0;
			z-index: 20;
			display: block;
			background: rgba(0, 0, 0, 0.45);
			border: 0;
			padding: 0;
			opacity: 0;
			pointer-events: none;
			transition: opacity 160ms ease;
		}

		.app.sidebar-open .sidebar-scrim {
			opacity: 1;
			pointer-events: auto;
		}

		.sidebar {
			position: fixed;
			top: 0;
			bottom: 0;
			left: 0;
			z-index: 30;
			width: min(82vw, 300px);
			min-height: 100vh;
			min-height: 100dvh;
			padding-top: env(safe-area-inset-top);
			transform: translateX(-100%);
			transition: transform 180ms ease;
			box-shadow: 16px 0 40px rgba(0, 0, 0, 0.35);
		}

		.sidebar.open {
			transform: translateX(0);
		}

		.brand {
			min-height: 54px;
			padding-left: 54px;
		}

		.new {
			min-height: 42px;
			padding: 8px 12px;
		}

		.create {
			margin: 10px;
		}

		.create-actions {
			flex-wrap: wrap;
		}

		.create-hint {
			margin-left: 0;
		}

		.sessions {
			overflow-y: auto;
			padding-bottom: 10px;
		}

		.session {
			min-height: 48px;
			padding: 8px 10px;
			padding-right: 42px;
		}

		.delete-session {
			top: 7px;
			right: 7px;
			width: 34px;
			height: 34px;
		}

		.empty {
			padding: 12px 10px;
		}

		.hint {
			display: none;
		}

		.chat {
			width: 100vw;
		}

		.welcome {
			width: 100%;
			margin: auto 0;
			padding: 72px 12px 24px;
			overflow: auto;
		}

		.welcome pre {
			max-width: 100%;
			overflow-x: auto;
			font-size: 10px;
			text-align: left;
		}

		.topbar {
			flex-wrap: wrap;
			gap: 6px 10px;
			min-height: 54px;
			padding: calc(8px + env(safe-area-inset-top)) 12px 8px 54px;
		}

		.topbar .meta {
			min-width: 0;
			max-width: 100%;
			overflow: hidden;
			text-overflow: ellipsis;
			white-space: nowrap;
		}

		.goal {
			order: 2;
			flex: 1 0 100%;
			max-width: 100%;
		}

		.goal-tracker {
			align-items: flex-start;
			flex-direction: column;
			gap: 8px;
			padding: 9px 12px;
		}

		.goal-main,
		.goal-metrics {
			width: 100%;
		}

		.goal-metrics {
			flex-wrap: wrap;
		}

		.spacer {
			display: none;
		}

		.session-state {
			order: 3;
			flex: 1 0 100%;
			gap: 10px;
		}

		.status {
			margin-left: auto;
		}

		.stop {
			min-height: 34px;
			padding: 6px 10px;
		}

		.conflict {
			margin: 12px;
		}

		.transcript {
			padding: 12px;
		}

		.virtual-row {
			padding-bottom: 12px;
		}

		.item {
			gap: 7px;
		}

		.gutter {
			width: 10px;
		}

		.cmd-line {
			flex-wrap: wrap;
			gap: 4px 8px;
		}

		.cmd-status {
			margin-left: 18px;
		}

		.cmd-out {
			margin-left: 0;
			font-size: 11px;
			max-height: 40dvh;
		}

		.message-image img {
			max-height: 42dvh;
		}

		.composer {
			align-items: stretch;
			gap: 7px;
			padding: 10px 12px calc(10px + env(safe-area-inset-bottom));
		}

		.composer .prompt {
			display: none;
		}

		textarea {
			min-width: 0;
			min-height: 44px;
			max-height: 35dvh;
			font-size: 16px;
		}

		.attach {
			min-width: 48px;
			min-height: 44px;
			padding: 0 10px;
		}

		.send {
			align-self: flex-end;
			min-width: 64px;
			min-height: 44px;
			padding: 0 12px;
		}

		.attachments {
			padding: 0 12px calc(10px + env(safe-area-inset-bottom));
		}
	}

	@media (max-width: 420px) {
		.topbar {
			font-size: 11px;
		}

		.transcript {
			padding: 10px;
		}
	}

	@keyframes blink {
		50% {
			opacity: 0;
		}
	}
	@keyframes pulse {
		50% {
			opacity: 0.3;
		}
	}
</style>
