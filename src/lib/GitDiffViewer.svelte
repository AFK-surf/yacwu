<script lang="ts">
	import { onDestroy, tick, untrack } from 'svelte';
	import { loadMonaco, type Monaco } from '$lib/monaco';

	type Scope = 'all' | 'staged' | 'unstaged';

	interface ChangeSummary {
		path: string;
		oldPath: string | null;
		status: 'modified' | 'added' | 'deleted' | 'renamed' | 'copied' | 'conflicted';
		staged: boolean;
		unstaged: boolean;
		additions: number | null;
		deletions: number | null;
	}

	type ChangesState =
		| { status: 'loading' }
		| { status: 'error'; message: string }
		| { status: 'ready'; available: boolean; branch: string; comparison: string; files: ChangeSummary[] };

	type DiffState =
		| { status: 'loading'; path: string }
		| { status: 'error'; path: string; message: string }
		| { status: 'ready'; path: string; patch: string; binary: boolean; original: string | null; modified: string | null };

	let {
		threadId,
		cwd,
		reveal = null,
		refreshNonce = 0,
		onfiles,
		onviewfile,
		onclose
	}: {
		threadId: string;
		cwd: string;
		reveal?: { path: string; nonce: number } | null;
		refreshNonce?: number;
		onfiles: () => void;
		onviewfile: (path: string) => void;
		onclose: () => void;
	} = $props();

	let scope = $state<Scope>('all');
	let changes = $state<ChangesState>({ status: 'loading' });
	let refreshing = $state(false);
	let selectedPath = $state<string | null>(null);
	let diff = $state<DiffState | null>(null);
	let closeEl = $state<HTMLButtonElement | null>(null);
	let viewerEl = $state<HTMLDivElement | null>(null);
	let monacoLoading = $state(false);
	let viewerError = $state<string | null>(null);
	let copied = $state(false);
	let lastRevealNonce = 0;
	let lastRefreshNonce = 0;
	let changesRequest = 0;
	let diffRequest = 0;
	let copyTimer: ReturnType<typeof setTimeout> | null = null;
	let monacoRef: Monaco = null;
	let diffEditor: any = null;
	let originalModel: any = null;
	let modifiedModel: any = null;
	let monacoRender = 0;

	const selectedChange = $derived(
		changes.status === 'ready'
			? (changes.files.find((file) => file.path === selectedPath) ?? null)
			: null
	);

	function statusMark(status: ChangeSummary['status']): string {
		return { modified: 'M', added: 'A', deleted: 'D', renamed: 'R', copied: 'C', conflicted: 'U' }[status];
	}

	function stageLabel(change: ChangeSummary): string {
		if (change.staged && change.unstaged) return 'staged + unstaged';
		if (change.staged) return 'staged';
		return 'unstaged';
	}

	function pathName(path: string): string {
		return path.split('/').at(-1) ?? path;
	}

	function pathParent(path: string): string {
		const parts = path.split('/');
		parts.pop();
		return parts.join('/');
	}

	async function loadChanges(preferredPath: string | null = selectedPath) {
		const request = ++changesRequest;
		if (changes.status === 'ready') refreshing = true;
		else changes = { status: 'loading' };
		try {
			const res = await fetch(
				`/api/threads/${threadId}/git/changes?scope=${encodeURIComponent(scope)}`
			);
			const data = await res.json();
			if (request !== changesRequest) return;
			if (!res.ok) throw new Error(data.error ?? `failed to inspect changes (${res.status})`);
			changes = {
				status: 'ready',
				available: data.available === true,
				branch: String(data.branch ?? ''),
				comparison: String(data.comparison ?? ''),
				files: Array.isArray(data.files) ? data.files : []
			};
			const path = preferredPath && changes.files.some((file) => file.path === preferredPath)
				? preferredPath
				: null;
			selectedPath = path;
			if (path) await loadDiff(path);
			else diff = null;
		} catch (error) {
			if (request !== changesRequest) return;
			changes = {
				status: 'error',
				message: error instanceof Error ? error.message : 'failed to inspect changes'
			};
		} finally {
			if (request === changesRequest) refreshing = false;
		}
	}

	async function loadDiff(path: string) {
		selectedPath = path;
		const request = ++diffRequest;
		monacoRender += 1;
		viewerError = null;
		diff = { status: 'loading', path };
		try {
			const res = await fetch(
				`/api/threads/${threadId}/git/diff?scope=${encodeURIComponent(scope)}&path=${encodeURIComponent(path)}`
			);
			const data = await res.json();
			if (request !== diffRequest) return;
			if (!res.ok) throw new Error(data.error ?? `failed to load diff (${res.status})`);
			const patch = String(data.patch ?? '');
			diff = {
				status: 'ready',
				path,
				patch,
				binary: data.binary === true,
				original: typeof data.original === 'string' ? data.original : null,
				modified: typeof data.modified === 'string' ? data.modified : null
			};
		} catch (error) {
			if (request !== diffRequest) return;
			diff = {
				status: 'error',
				path,
				message: error instanceof Error ? error.message : 'failed to load diff'
			};
		}
	}

	async function showInDiffViewer(
		el: HTMLDivElement,
		path: string,
		original: string,
		modified: string
	) {
		const render = ++monacoRender;
		viewerError = null;
		if (!monacoRef) {
			monacoLoading = true;
			try {
				monacoRef = await loadMonaco();
			} catch {
				if (render === monacoRender) viewerError = 'The Monaco diff viewer could not be loaded.';
				return;
			} finally {
				if (render === monacoRender) monacoLoading = false;
			}
		}
		if (render !== monacoRender) return;
		if (diffEditor && diffEditor.getContainerDomNode() !== el) {
			diffEditor.dispose();
			diffEditor = null;
		}
		if (!diffEditor) {
			diffEditor = monacoRef.editor.createDiffEditor(el, {
				readOnly: true,
				originalEditable: false,
				domReadOnly: true,
				theme: 'yacwu-paper',
				automaticLayout: true,
				renderSideBySide: false,
				diffAlgorithm: 'advanced',
				ignoreTrimWhitespace: false,
				hideUnchangedRegions: {
					enabled: true,
					contextLineCount: 3,
					minimumLineCount: 3,
					revealLineCount: 5
				},
				minimap: { enabled: false },
				scrollBeyondLastLine: false,
				stickyScroll: { enabled: false },
				contextmenu: false,
				links: false,
				fontSize: 13,
				fontFamily: "'JetBrains Mono Variable', ui-monospace, monospace",
				lineNumbersMinChars: 3,
				padding: { top: 8, bottom: 8 }
			});
		}
		diffEditor.setModel(null);
		originalModel?.dispose();
		modifiedModel?.dispose();
		originalModel = monacoRef.editor.createModel(
			original,
			undefined,
			monacoRef.Uri.file(`/__yacwu_git__/original/${path}`)
		);
		modifiedModel = monacoRef.editor.createModel(
			modified,
			undefined,
			monacoRef.Uri.file(`/__yacwu_git__/modified/${path}`)
		);
		diffEditor.setModel({ original: originalModel, modified: modifiedModel });
	}

	async function copyPatch() {
		if (!diff || diff.status !== 'ready' || !diff.patch) return;
		await navigator.clipboard.writeText(diff.patch);
		copied = true;
		if (copyTimer) clearTimeout(copyTimer);
		copyTimer = setTimeout(() => (copied = false), 1500);
	}

	function closeDiff() {
		selectedPath = null;
		diff = null;
	}

	$effect(() => {
		threadId;
		scope;
		untrack(() => {
			void loadChanges();
			void tick().then(() => closeEl?.focus());
		});
	});

	$effect(() => {
		if (refreshNonce === lastRefreshNonce) return;
		lastRefreshNonce = refreshNonce;
		untrack(() => void loadChanges());
	});

	$effect(() => {
		const request = reveal;
		if (!request || request.nonce === lastRevealNonce) return;
		lastRevealNonce = request.nonce;
		untrack(() => void loadChanges(request.path));
	});

	$effect(() => {
		const current = diff;
		const el = viewerEl;
		if (
			!el ||
			!current ||
			current.status !== 'ready' ||
			current.binary ||
			current.original === null ||
			current.modified === null ||
			current.original === current.modified
		) return;
		untrack(() => void showInDiffViewer(el, current.path, current.original!, current.modified!));
	});

	function onWindowKeydown(event: KeyboardEvent) {
		if (event.key === 'Escape') {
			event.preventDefault();
			onclose();
		}
	}

	onDestroy(() => {
		if (copyTimer) clearTimeout(copyTimer);
		diffEditor?.dispose();
		originalModel?.dispose();
		modifiedModel?.dispose();
	});
</script>

<svelte:window onkeydown={onWindowKeydown} />

<aside class="git-viewer" class:file-open={selectedPath !== null} aria-label="Git changes">
	<header class="gv-header">
		<div class="gv-tabs" role="tablist" aria-label="Workspace inspector">
			<button type="button" role="tab" aria-selected="false" onclick={onfiles}>Files</button>
			<button type="button" role="tab" aria-selected="true">Changes</button>
		</div>
		{#if changes.status === 'ready' && changes.available}
			<span class="gv-branch" title={`${changes.branch} · ${cwd}`}>{changes.branch}</span>
		{/if}
		<button type="button" class="gv-icon" class:refreshing onclick={() => loadChanges()} aria-label={refreshing ? 'Refreshing changes' : 'Refresh changes'} title="Refresh changes">
			<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 12a8 8 0 1 1-2.34-5.66M20 4v4h-4" /></svg>
		</button>
		<button type="button" class="gv-icon" bind:this={closeEl} onclick={onclose} aria-label="Close changes" title="Close changes">
			<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6 6 18" /></svg>
		</button>
	</header>

	<div class="gv-toolbar">
		<div class="gv-scopes" aria-label="Diff scope">
			{#each ['all', 'staged', 'unstaged'] as option}
				<button type="button" class:active={scope === option} aria-pressed={scope === option} onclick={() => (scope = option as Scope)}>{option === 'all' ? 'All' : option[0].toUpperCase() + option.slice(1)}</button>
			{/each}
		</div>
		{#if changes.status === 'ready' && changes.available}
			<span class="gv-summary">{changes.files.length} {changes.files.length === 1 ? 'file' : 'files'} · {changes.comparison}</span>
		{/if}
	</div>

	<div class="gv-body">
		<nav class="gv-files" aria-label="Changed files">
			{#if changes.status === 'loading'}
				<div class="gv-placeholder">Inspecting working tree…</div>
			{:else if changes.status === 'error'}
				<div class="gv-placeholder err">{changes.message}</div>
			{:else if !changes.available}
				<div class="gv-placeholder">This session directory is not in a Git worktree.</div>
			{:else if changes.files.length === 0}
				<div class="gv-placeholder">No {scope === 'all' ? '' : `${scope} `}changes.</div>
			{:else}
				{#each changes.files as change (change.path)}
					<button type="button" class="gv-file" class:active={selectedPath === change.path} onclick={() => loadDiff(change.path)}>
						<span class="gv-status {change.status}" aria-label={change.status}>{statusMark(change.status)}</span>
						<span class="gv-file-copy">
							<span class="gv-name">{pathName(change.path)}</span>
							{#if pathParent(change.path)}<span class="gv-parent">{pathParent(change.path)}</span>{/if}
							{#if change.oldPath}<span class="gv-parent">from {change.oldPath}</span>{/if}
						</span>
						<span class="gv-file-stats" aria-label={change.additions === null || change.deletions === null ? 'Binary change' : `${change.additions} additions, ${change.deletions} deletions`}>
							{#if change.additions === null || change.deletions === null}
								<span class="binary">binary</span>
							{:else}
								<span class="additions">+{change.additions}</span>
								<span class="deletions">−{change.deletions}</span>
							{/if}
						</span>
						<span class="gv-stage">{stageLabel(change)}</span>
					</button>
				{/each}
			{/if}
		</nav>

		<section class="gv-diff" aria-label="Selected file diff">
			{#if !selectedPath}
				<div class="gv-placeholder">Select a changed file to review it.</div>
			{:else}
				<header class="gv-diff-header">
					<button type="button" class="gv-back" onclick={closeDiff} aria-label="Back to changed files">
						<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M14 6l-6 6 6 6" /></svg>
					</button>
					<span class="gv-path" title={selectedPath}>{selectedPath}</span>
					{#if diff?.status === 'ready' && selectedChange && selectedChange.additions !== null && selectedChange.deletions !== null}
						<span class="gv-stats"><span>+{selectedChange.additions}</span> <span>−{selectedChange.deletions}</span></span>
					{/if}
					{#if diff?.status === 'ready'}
						<button type="button" class="gv-action" onclick={copyPatch} disabled={!diff.patch} aria-label="Copy patch">{copied ? 'Copied' : 'Copy patch'}</button>
					{/if}
					{#if selectedChange?.status !== 'deleted'}
						<button type="button" class="gv-action" onclick={() => onviewfile(selectedPath!)}>View file</button>
					{/if}
				</header>
				{#if !diff || diff.status === 'loading'}
					<div class="gv-placeholder">Loading diff…</div>
				{:else if diff.status === 'error'}
					<div class="gv-placeholder err">{diff.message}</div>
				{:else if diff.binary}
					<div class="gv-placeholder">Binary file changed. A textual diff is not available.</div>
				{:else if diff.original === null || diff.modified === null}
					<div class="gv-placeholder err">The complete file contents are unavailable for Monaco.</div>
				{:else if diff.original === diff.modified}
					<div class="gv-placeholder">No textual changes in this scope.</div>
				{:else if viewerError}
					<div class="gv-placeholder err">{viewerError}</div>
				{:else if monacoLoading}
					<div class="gv-placeholder">Loading Monaco diff viewer…</div>
				{/if}
				<div
					class="gv-monaco"
					bind:this={viewerEl}
					class:hidden={!diff ||
						diff.status !== 'ready' ||
						diff.binary ||
						diff.original === null ||
						diff.modified === null ||
						diff.original === diff.modified ||
						monacoLoading ||
						viewerError !== null}
				></div>
			{/if}
		</section>
	</div>
</aside>

<style>
	.git-viewer { position: fixed; inset-block: 0; inset-inline-end: 0; z-index: var(--z-dropdown); display: flex; flex-direction: column; width: min(64rem, 100%); border-inline-start: var(--rule-hair) solid var(--color-rule); background: var(--color-paper); box-shadow: var(--shadow-drawer); }
	.gv-header { display: flex; align-items: center; gap: var(--space-2xs); min-height: var(--rail-header-height); padding: calc(var(--space-3xs) + env(safe-area-inset-top)) var(--space-sm) var(--space-3xs); border-block-end: var(--rule-hair) solid var(--color-rule); }
	.gv-tabs { display: flex; gap: var(--space-3xs); }
	.gv-tabs button, .gv-scopes button, .gv-action { min-height: var(--control-height-compact); padding-inline: var(--space-xs); border: var(--rule-hair) solid transparent; border-radius: var(--radius-sm); background: transparent; color: var(--color-muted); cursor: pointer; font: inherit; font-size: var(--text-sm); }
	.gv-tabs button[aria-selected='true'], .gv-scopes button.active { border-color: var(--color-rule); background: var(--color-paper-3); color: var(--color-ink); }
	.gv-branch { flex: 1; min-width: 0; overflow: hidden; color: var(--color-muted); font-family: var(--font-outlier); font-size: var(--text-xs); text-overflow: ellipsis; white-space: nowrap; }
	.gv-icon, .gv-back { display: grid; flex: none; place-items: center; width: var(--control-height-compact); height: var(--control-height-compact); padding: 0; border: var(--rule-hair) solid transparent; border-radius: var(--radius-input); background: transparent; color: var(--color-neutral); cursor: pointer; }
	.gv-icon svg, .gv-back svg { width: var(--space-sm); height: var(--space-sm); fill: none; stroke: currentColor; stroke-linecap: round; stroke-linejoin: round; stroke-width: 2; }
	.gv-icon.refreshing { opacity: .55; }
	.gv-toolbar { display: flex; align-items: center; gap: var(--space-sm); min-height: var(--control-height); padding: var(--space-3xs) var(--space-sm); border-block-end: var(--rule-hair) solid var(--color-rule); }
	.gv-scopes { display: flex; gap: var(--space-3xs); }
	.gv-summary { margin-inline-start: auto; color: var(--color-muted); font-family: var(--font-outlier); font-size: var(--text-xs); white-space: nowrap; }
	.gv-body { display: grid; flex: 1; grid-template-columns: minmax(14rem, 19rem) minmax(0, 1fr); min-height: 0; }
	.gv-files { min-height: 0; padding: var(--space-2xs); overflow: auto; border-inline-end: var(--rule-hair) solid var(--color-rule); background: var(--color-paper-2); }
	.gv-file { display: grid; grid-template-columns: var(--space-md) minmax(0, 1fr) auto; gap: 0 var(--space-2xs); width: 100%; min-height: var(--control-height-compact); padding: var(--space-2xs); border: 0; border-radius: var(--radius-sm); background: transparent; color: var(--color-neutral); cursor: pointer; text-align: start; }
	.gv-file.active { background: var(--color-paper-3); color: var(--color-ink); }
	.gv-status { grid-row: 1 / 3; padding-block-start: 1px; color: var(--color-accent-active); font-family: var(--font-outlier); font-size: var(--text-sm); font-weight: 600; }
	.gv-status.added { color: var(--color-success); }
	.gv-status.deleted, .gv-status.conflicted { color: var(--color-error); }
	.gv-file-copy { display: flex; min-width: 0; gap: var(--space-2xs); align-items: baseline; }
	.gv-name { overflow: hidden; font-family: var(--font-outlier); font-size: var(--text-sm); text-overflow: ellipsis; white-space: nowrap; }
	.gv-parent, .gv-stage, .gv-file-stats { overflow: hidden; color: var(--color-muted); font-family: var(--font-outlier); font-size: var(--text-xs); text-overflow: ellipsis; white-space: nowrap; }
	.gv-file-stats { display: flex; gap: var(--space-3xs); justify-self: end; font-variant-numeric: tabular-nums; }
	.gv-file-stats .additions { color: var(--color-success); }
	.gv-file-stats .deletions { color: var(--color-error); }
	.gv-file-stats .binary { color: var(--color-muted); }
	.gv-stage { grid-column: 2 / -1; }
	.gv-diff { display: flex; flex-direction: column; min-width: 0; min-height: 0; }
	.gv-diff-header { display: flex; align-items: center; gap: var(--space-2xs); min-height: var(--control-height); padding: var(--space-3xs) var(--space-sm); border-block-end: var(--rule-hair) solid var(--color-rule); }
	.gv-back { display: none; }
	.gv-path { flex: 1; min-width: 0; overflow: hidden; color: var(--color-ink-2); font-family: var(--font-outlier); font-size: var(--text-sm); text-overflow: ellipsis; white-space: nowrap; }
	.gv-stats { display: flex; gap: var(--space-2xs); color: var(--color-muted); font-family: var(--font-outlier); font-size: var(--text-xs); white-space: nowrap; }
	.gv-stats span:first-child { color: var(--color-success); }
	.gv-stats span:last-child { color: var(--color-error); }
	.gv-action { border-color: var(--color-rule); color: var(--color-neutral); white-space: nowrap; }
	.gv-action:disabled { cursor: default; opacity: .5; }
	.gv-placeholder { padding: var(--space-lg) var(--space-sm); color: var(--color-muted); font-size: var(--text-sm); text-align: center; }
	.gv-placeholder.err { color: var(--color-error); }
	.gv-monaco { flex: 1; min-height: 0; }
	.gv-monaco.hidden { display: none; }
	@media (hover: hover) and (pointer: fine) { .gv-file:hover, .gv-icon:hover, .gv-back:hover, .gv-action:hover:not(:disabled), .gv-tabs button:hover, .gv-scopes button:hover { background: var(--color-paper-3); color: var(--color-ink); } }
	@media (max-width: 59.999rem) {
		.git-viewer { width: 100%; border-inline-start: 0; }
		.gv-body { grid-template-columns: minmax(0, 1fr); }
		.git-viewer.file-open .gv-files { display: none; }
		.git-viewer:not(.file-open) .gv-diff { display: none; }
		.gv-back { display: grid; }
		.gv-summary { display: none; }
		.gv-toolbar { overflow-x: auto; }
		.gv-action { padding-inline: var(--space-2xs); }
	}
	@media (pointer: coarse) { .gv-file, .gv-icon, .gv-back, .gv-tabs button, .gv-scopes button, .gv-action { min-height: var(--control-height); } }
</style>
