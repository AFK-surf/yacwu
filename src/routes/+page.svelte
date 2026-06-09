<script lang="ts">
	import { onMount, tick } from 'svelte';
	import type {
		JsonRpcNotification,
		ThreadItem,
		ThreadSummary,
		Turn
	} from '$lib/protocol';
	import { parseSlash, SLASH_HELP } from '$lib/slash';

	interface Goal {
		objective: string;
		status: string;
		tokenBudget: number | null;
		tokensUsed: number;
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

	let localCounter = 0;

	let sessions = $state<ThreadSummary[]>([]);
	let activeId = $state<string | null>(null);
	let threads = $state<Record<string, ThreadState>>({});
	let input = $state('');
	let connected = $state(false);
	let loadingHistory = $state(false);
	let cwds = $state<Record<string, string>>({});
	let conflict = $state<{ id: string; holders: { pid: number; command: string }[] } | null>(null);

	// New-session working-directory picker.
	let creating = $state(false);
	let createError = $state<string | null>(null);
	let newCwd = $state('');
	let defaultCwd = $state('');
	let cwdInputEl = $state<HTMLInputElement | null>(null);

	let transcriptEl = $state<HTMLDivElement | null>(null);

	const active = $derived(activeId ? threads[activeId] : null);

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
		const summary: ThreadSummary = {
			id: thr.id,
			preview: thr.preview ?? '',
			name: thr.name ?? null,
			createdAt: thr.createdAt ?? now,
			updatedAt: thr.updatedAt ?? thr.createdAt ?? now,
			cwd: thr.cwd
		};
		sessions = [summary, ...sessions.filter((s) => s.id !== thr.id)];
	}

	function removeSession(id: string) {
		sessions = sessions.filter((s) => s.id !== id);
		delete threads[id];
		delete cwds[id];
		if (activeId === id) activeId = null;
	}

	/** Append a client-side note (slash-command echo / help / errors). */
	function addLocalNote(id: string, text: string, tone: 'info' | 'err' = 'info') {
		const t = ensureThread(id);
		const noteId = `local-${++localCounter}`;
		t.order.push(noteId);
		t.byId[noteId] = { type: 'localNote', id: noteId, text, tone } as any;
		scrollToBottom();
	}

	function handleNotification(msg: JsonRpcNotification) {
		const p: any = msg.params ?? {};
		const tid: string | undefined = p.threadId;

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

		scrollToBottom();
	}

	async function scrollToBottom() {
		await tick();
		if (transcriptEl) transcriptEl.scrollTop = transcriptEl.scrollHeight;
	}

	async function loadSessions() {
		const res = await fetch('/api/threads');
		const data = await res.json();
		sessions = data.data ?? [];
		defaultCwd = data.defaultCwd ?? '';
	}

	async function startCreating() {
		createError = null;
		newCwd = '';
		creating = true;
		await tick();
		cwdInputEl?.focus();
	}

	function cancelCreating() {
		creating = false;
		createError = null;
	}

	async function newSession(cwd?: string) {
		createError = null;
		const res = await fetch('/api/threads', {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify(cwd ? { cwd } : {})
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
			activeId = id;
		}
	}

	async function selectSession(id: string) {
		activeId = id;
		conflict = null;
		const t = ensureThread(id);
		// Already loaded history? skip refetch.
		if (t.order.length > 0) {
			scrollToBottom();
			return;
		}
		await openSession(id, false);
	}

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
			const turns: Turn[] = thr?.turns ?? [];
			replaceItems(id, turns);
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
		activeId = null;
	}

	async function send() {
		const text = input.trim();
		if (!text || !activeId) return;
		const id = activeId;
		input = '';

		// Slash commands are handled client-side and dispatched to dedicated RPCs,
		// mirroring the Codex TUI. Everything else is a normal model turn.
		if (text.startsWith('/')) {
			await handleSlash(id, text);
			return;
		}

		const t = ensureThread(id);
		t.status = 'running';
		await fetch(`/api/threads/${id}/message`, {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({ text })
		});
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

	async function buildStatus(id: string): Promise<string> {
		const t = threads[id];
		const sess = sessions.find((s) => s.id === id);
		const lines = ['status'];
		lines.push(`  session   ${id}`);
		const cwd = cwds[id] ?? sess?.cwd;
		if (cwd) lines.push(`  cwd       ${cwd}`);
		lines.push(`  state     ${t?.status ?? 'idle'}`);
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
					const thread = data.thread;
					upsertSession(thread);
					ensureThread(thread.id);
					activeId = thread.id;
					addLocalNote(thread.id, `forked from ${id.slice(0, 8)}`);
					await openSession(thread.id, false);
				} else {
					addLocalNote(id, data.error ?? 'failed to fork session', 'err');
				}
				break;
			}

			case 'archive': {
				const { ok, data } = await postCmd(id, 'archive', {});
				if (ok) removeSession(id);
				else addLocalNote(id, data.error ?? 'failed to archive session', 'err');
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

	function userText(item: any): string {
		return (item.content ?? [])
			.map((c: any) => c.text ?? '')
			.join('')
			.trim();
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

	onMount(() => {
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
		return () => es.close();
	});
</script>

<div class="app">
	<aside class="sidebar">
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
		<div class="sessions">
			{#each sessions as s (s.id)}
				<button
					class="session"
					class:active={s.id === activeId}
					data-id={s.id}
					onclick={() => selectSession(s.id)}
				>
					<span class="run-dot" class:running={threads[s.id]?.status === 'running'}></span>
					<span class="label">{shortLabel(s)}</span>
					{#if s.cwd}<span class="cwd">{s.cwd}</span>{/if}
				</button>
			{:else}
				<div class="empty">no sessions yet</div>
			{/each}
		</div>
		<div class="hint">{sessions.length} session{sessions.length === 1 ? '' : 's'}</div>
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
				{#if active?.tokens}<span class="meta">{active.tokens.toLocaleString()} tok</span>{/if}
				{#if active?.status === 'running'}
					<span class="status running">● running</span>
					<button class="stop" onclick={interrupt}>stop</button>
				{:else}
					<span class="status">● idle</span>
				{/if}
			</div>

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
				<div class="transcript" bind:this={transcriptEl}>
				{#if loadingHistory}
					<div class="sys">loading history…</div>
				{/if}
				{#each itemsOf(active) as item (item.id)}
					{#if item.type === 'userMessage'}
						<div class="item user">
							<span class="gutter">›</span>
							<div class="body">{userText(item)}</div>
						</div>
					{:else if item.type === 'agentMessage'}
						<div class="item agent">
							<div class="body">{(item as any).text}</div>
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
									<div class="fc"><span class="kind {ch.kind}">{ch.kind}</span> {ch.path}</div>
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
					{:else}
						<div class="item generic">
							<span class="gutter">·</span>
							<div class="body">{item.type}</div>
						</div>
					{/if}
				{/each}
				{#if active?.status === 'running'}
					<div class="item agent"><div class="body blink">▍</div></div>
				{/if}
				{#if active?.error}
					<div class="item err"><span class="gutter">✗</span><div class="body">{active.error}</div></div>
				{/if}
			</div>

			<div class="composer">
				<span class="prompt">›</span>
				<textarea
					placeholder="message codex…  (Enter to send, Shift+Enter for newline)"
					bind:value={input}
					onkeydown={onKeydown}
					rows="1"
				></textarea>
				<button class="send" onclick={send} disabled={!input.trim()}>send</button>
				</div>
			{/if}
		{/if}
	</main>
</div>

<style>
	.app {
		display: grid;
		grid-template-columns: 260px 1fr;
		height: 100vh;
		width: 100vw;
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
	.session {
		width: 100%;
		text-align: left;
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
		margin-bottom: 2px;
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
	.spacer {
		flex: 1;
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
		display: flex;
		flex-direction: column;
		gap: 10px;
	}
	.sys {
		color: var(--fg-dim);
		font-style: italic;
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
	.item.reason .body {
		color: var(--reason);
		font-style: italic;
		opacity: 0.85;
	}
	.item.reason .gutter {
		color: var(--reason);
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
