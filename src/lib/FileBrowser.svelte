<!--
	Read-only file browser for the active session, rooted at the session's
	working directory. A lazy tree fetches one directory per expand; text
	files render in a Monaco viewer that loads from the CDN on first use
	($lib/monaco). Desktop shows tree and viewer side by side; narrow
	viewports switch between them, file-manager style.
-->
<script lang="ts">
	import { onDestroy, tick, untrack } from 'svelte';
	import { loadMonaco, type Monaco } from '$lib/monaco';

	interface FileEntry {
		name: string;
		kind: 'dir' | 'file' | 'other';
		size: number;
		symlink: boolean;
	}

	type DirState =
		| { status: 'loading' }
		| { status: 'error'; message: string }
		| { status: 'ready'; entries: FileEntry[] };

	type FileState =
		| { status: 'loading'; path: string }
		| { status: 'error'; path: string; message: string }
		| { status: 'ready'; path: string; kind: 'text' | 'binary' | 'toolarge' | 'image'; size: number; content: string };

	let {
		threadId,
		cwd,
		reveal = null,
		refreshNonce = 0,
		onclose
	}: {
		threadId: string;
		cwd: string;
		reveal?: { path: string; line?: number | null; nonce: number } | null;
		refreshNonce?: number;
		onclose: () => void;
	} = $props();

	// Prefer the root the server reports; the cwd prop covers the first paint.
	let serverRoot = $state<string | null>(null);
	const root = $derived(serverRoot ?? cwd);
	let dirs = $state<Record<string, DirState>>({});
	let expanded = $state<Record<string, boolean>>({});
	let selectedPath = $state<string | null>(null);
	let file = $state<FileState | null>(null);
	let monacoLoading = $state(false);
	let viewerError = $state<string | null>(null);
	let viewerEl = $state<HTMLDivElement | null>(null);
	let closeEl = $state<HTMLButtonElement | null>(null);

	let monacoRef: Monaco = null;
	let editor: any = null;
	let model: any = null;
	let lineDecorations: any = null;
	// The line to reveal once the currently loading file reaches the viewer.
	let targetLine: number | null = null;
	let fileRequest = 0;
	let lastRevealNonce = 0;
	let lastRefreshNonce = 0;

	const IMAGE_RE = /\.(png|jpe?g|gif|webp)$/i;

	function fmtBytes(size: number): string {
		if (size >= 1_048_576) return `${(size / 1_048_576).toFixed(1)} MB`;
		if (size >= 1024) return `${Math.round(size / 1024)} kB`;
		return `${size} B`;
	}

	function absolutePath(rel: string): string {
		const base = root.replace(/[\\/]+$/, '');
		return rel ? `${base}/${rel}` : base;
	}

	async function loadDir(path: string, force = false) {
		if (!force && dirs[path]) return;
		dirs[path] = { status: 'loading' };
		try {
			const res = await fetch(
				`/api/threads/${threadId}/files?path=${encodeURIComponent(path)}`
			);
			const data = await res.json();
			if (!res.ok) throw new Error(data.error ?? `failed to list directory (${res.status})`);
			if (typeof data.root === 'string' && data.root) serverRoot = data.root;
			dirs[path] = { status: 'ready', entries: (data.entries ?? []) as FileEntry[] };
		} catch (error) {
			dirs[path] = {
				status: 'error',
				message: error instanceof Error ? error.message : 'failed to list directory'
			};
		}
	}

	function toggleDir(path: string) {
		expanded[path] = !expanded[path];
		if (expanded[path]) void loadDir(path);
	}

	async function selectFile(path: string, line: number | null = null) {
		selectedPath = path;
		targetLine = line;
		const request = ++fileRequest;
		if (IMAGE_RE.test(path)) {
			file = { status: 'ready', path, kind: 'image', size: 0, content: '' };
			return;
		}
		file = { status: 'loading', path };
		try {
			const res = await fetch(
				`/api/threads/${threadId}/file?path=${encodeURIComponent(path)}`
			);
			const data = await res.json();
			if (request !== fileRequest) return;
			if (!res.ok) throw new Error(data.error ?? `failed to read file (${res.status})`);
			if (data.binary) file = { status: 'ready', path, kind: 'binary', size: data.size ?? 0, content: '' };
			else if (data.tooLarge)
				file = { status: 'ready', path, kind: 'toolarge', size: data.size ?? 0, content: '' };
			else
				file = {
					status: 'ready',
					path,
					kind: 'text',
					size: data.size ?? 0,
					content: String(data.content ?? '')
				};
		} catch (error) {
			if (request !== fileRequest) return;
			file = {
				status: 'error',
				path,
				message: error instanceof Error ? error.message : 'failed to read file'
			};
		}
	}

	function closeFile() {
		selectedPath = null;
		file = null;
	}

	// Expand every ancestor of a transcript file-change path, then open it.
	async function revealPath(path: string, line: number | null = null) {
		const parts = path.split('/').filter(Boolean);
		let dir = '';
		for (const part of parts.slice(0, -1)) {
			dir = dir ? `${dir}/${part}` : part;
			expanded[dir] = true;
			await loadDir(dir);
		}
		await selectFile(parts.join('/'), line);
	}

	// Session root loads on mount; reveal/refresh props arrive as nonces so
	// repeated requests for the same path still take effect.
	$effect(() => {
		threadId;
		untrack(() => {
			void loadDir('');
			void tick().then(() => closeEl?.focus());
		});
	});

	$effect(() => {
		const request = reveal;
		if (!request || request.nonce === lastRevealNonce) return;
		lastRevealNonce = request.nonce;
		untrack(() => void revealPath(request.path, request.line ?? null));
	});

	$effect(() => {
		if (refreshNonce === lastRefreshNonce) return;
		lastRefreshNonce = refreshNonce;
		untrack(() => {
			for (const path of Object.keys(dirs)) {
				if (path === '' || expanded[path]) void loadDir(path, true);
			}
			if (selectedPath && !IMAGE_RE.test(selectedPath)) void selectFile(selectedPath);
		});
	});

	$effect(() => {
		const current = file;
		const el = viewerEl;
		if (!el || !current || current.status !== 'ready' || current.kind !== 'text') return;
		untrack(() => void showInViewer(el, current.path, current.content));
	});

	async function showInViewer(el: HTMLDivElement, path: string, content: string) {
		viewerError = null;
		if (!monacoRef) {
			monacoLoading = true;
			try {
				monacoRef = await loadMonaco();
			} catch {
				viewerError = 'The code viewer could not be loaded from the CDN.';
				return;
			} finally {
				monacoLoading = false;
			}
		}
		// If the host node was ever replaced, the old editor is orphaned.
		if (editor && editor.getContainerDomNode() !== el) {
			editor.dispose();
			editor = null;
		}
		if (!editor) {
			editor = monacoRef.editor.create(el, {
				readOnly: true,
				domReadOnly: true,
				theme: 'yacwu-paper',
				automaticLayout: true,
				minimap: { enabled: false },
				scrollBeyondLastLine: false,
				renderLineHighlight: 'none',
				occurrencesHighlight: 'off',
				selectionHighlight: false,
				stickyScroll: { enabled: false },
				contextmenu: false,
				links: false,
				fontSize: 13,
				fontFamily: "'JetBrains Mono Variable', ui-monospace, monospace",
				padding: { top: 8, bottom: 8 }
			});
		}
		const uri = monacoRef.Uri.file(`/${path}`);
		const previous = model;
		model = monacoRef.editor.getModel(uri) ?? monacoRef.editor.createModel(content, undefined, uri);
		if (model.getValue() !== content) model.setValue(content);
		editor.setModel(model);
		if (previous && previous !== model) previous.dispose();

		// Jump to a requested line (path:123 links), marking it quietly.
		lineDecorations?.clear();
		if (targetLine !== null) {
			const line = Math.max(1, Math.min(targetLine, model.getLineCount()));
			targetLine = null;
			editor.revealLineInCenter(line);
			editor.setPosition({ lineNumber: line, column: 1 });
			lineDecorations = editor.createDecorationsCollection([
				{
					range: new monacoRef.Range(line, 1, line, 1),
					options: { isWholeLine: true, className: 'fb-target-line' }
				}
			]);
		}
	}

	onDestroy(() => {
		editor?.dispose();
		model?.dispose();
	});

	function onWindowKeydown(e: KeyboardEvent) {
		if (e.key === 'Escape') {
			e.preventDefault();
			onclose();
		}
	}
</script>

<svelte:window onkeydown={onWindowKeydown} />

{#snippet dirRows(dirPath: string, depth: number)}
	{@const state = dirs[dirPath]}
	{#if !state || state.status === 'loading'}
		<div class="fb-note" style:--fb-depth={depth}>loading…</div>
	{:else if state.status === 'error'}
		<div class="fb-note err" style:--fb-depth={depth}>{state.message}</div>
	{:else if state.entries.length === 0}
		<div class="fb-note" style:--fb-depth={depth}>empty</div>
	{:else}
		{#each state.entries as entry (entry.name)}
			{@const path = dirPath ? `${dirPath}/${entry.name}` : entry.name}
			{#if entry.kind === 'dir'}
				<button
					type="button"
					class="fb-row dir"
					class:dot={entry.name.startsWith('.')}
					style:--fb-depth={depth}
					aria-expanded={Boolean(expanded[path])}
					onclick={() => toggleDir(path)}
				>
					<svg class="fb-caret" class:open={expanded[path]} viewBox="0 0 16 16" aria-hidden="true">
						<path d="m6 3.5 4.5 4.5L6 12.5" />
					</svg>
					<span class="fb-name">{entry.name}</span>
					{#if entry.symlink}<span class="fb-sym" aria-label="symbolic link">⤳</span>{/if}
				</button>
				{#if expanded[path]}
					{@render dirRows(path, depth + 1)}
				{/if}
			{:else if entry.kind === 'file'}
				<button
					type="button"
					class="fb-row file"
					class:active={selectedPath === path}
					class:dot={entry.name.startsWith('.')}
					style:--fb-depth={depth}
					onclick={() => selectFile(path)}
				>
					<span class="fb-name">{entry.name}</span>
					{#if entry.symlink}<span class="fb-sym" aria-label="symbolic link">⤳</span>{/if}
					<span class="fb-size">{fmtBytes(entry.size)}</span>
				</button>
			{:else}
				<div class="fb-row other" style:--fb-depth={depth}>
					<span class="fb-name">{entry.name}</span>
					<span class="fb-size">special</span>
				</div>
			{/if}
		{/each}
	{/if}
{/snippet}

<aside class="file-browser" class:file-open={selectedPath !== null} aria-label="Session files">
	<header class="fb-header">
		<div class="fb-heading">
			<h2>Files</h2>
			<span class="fb-root" title={root}>{root}</span>
		</div>
		<button
			type="button"
			class="fb-icon"
			onclick={() => {
				dirs = {};
				void loadDir('');
				if (selectedPath) void selectFile(selectedPath);
			}}
			aria-label="Refresh files"
			title="Refresh files"
		>
			<svg viewBox="0 0 24 24" aria-hidden="true">
				<path d="M20 12a8 8 0 1 1-2.34-5.66M20 4v4h-4" />
			</svg>
		</button>
		<button
			type="button"
			class="fb-icon"
			bind:this={closeEl}
			onclick={onclose}
			aria-label="Close file browser"
			title="Close file browser"
		>
			<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6 6 18" /></svg>
		</button>
	</header>
	<div class="fb-body">
		<nav class="fb-tree" aria-label="Directory tree">
			{@render dirRows('', 0)}
		</nav>
		<section class="fb-view" aria-label="File contents">
			{#if !selectedPath || !file}
				<div class="fb-placeholder">Select a file to view it.</div>
			{:else}
				<div class="fb-view-header">
					<button type="button" class="fb-back" onclick={closeFile} aria-label="Back to file list">
						<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M14 6l-6 6 6 6" /></svg>
					</button>
					<span class="fb-view-path" title={file.path}>{file.path}</span>
					{#if file.status === 'ready' && file.kind !== 'image'}
						<span class="fb-view-size">{fmtBytes(file.size)}</span>
					{/if}
				</div>
				{#if file.status === 'loading'}
					<div class="fb-placeholder">loading…</div>
				{:else if file.status === 'error'}
					<div class="fb-placeholder err">{file.message}</div>
				{:else if file.kind === 'image'}
					<div class="fb-image">
						<img src={`/api/images?path=${encodeURIComponent(absolutePath(file.path))}`} alt={file.path} />
					</div>
				{:else if file.kind === 'binary'}
					<div class="fb-placeholder">Binary file · {fmtBytes(file.size)}</div>
				{:else if file.kind === 'toolarge'}
					<div class="fb-placeholder">
						File is too large to display ({fmtBytes(file.size)}).
					</div>
				{:else if viewerError}
					<div class="fb-placeholder err">{viewerError}</div>
					<pre class="fb-plain">{file.content}</pre>
				{:else if monacoLoading}
					<div class="fb-placeholder">Loading code viewer…</div>
				{/if}
			{/if}
			<!-- Persistent Monaco host: the editor instance is created once and
			     must never be torn down by per-file state changes above. -->
			<div
				class="fb-editor"
				bind:this={viewerEl}
				class:hidden={!file ||
					file.status !== 'ready' ||
					file.kind !== 'text' ||
					monacoLoading ||
					viewerError !== null}
			></div>
		</section>
	</div>
</aside>

<style>
	.file-browser {
		position: fixed;
		inset-block: 0;
		inset-inline-end: 0;
		z-index: var(--z-dropdown);
		display: flex;
		flex-direction: column;
		width: min(64rem, 100%);
		border-inline-start: var(--rule-hair) solid var(--color-rule);
		background: var(--color-paper);
		box-shadow: var(--shadow-drawer);
	}

	.fb-header {
		display: flex;
		align-items: center;
		gap: var(--space-2xs);
		min-height: var(--rail-header-height);
		padding: calc(var(--space-3xs) + env(safe-area-inset-top)) var(--space-sm) var(--space-3xs);
		border-block-end: var(--rule-hair) solid var(--color-rule);
	}

	.fb-heading {
		display: flex;
		flex: 1;
		align-items: baseline;
		gap: var(--space-xs);
		min-width: 0;
	}

	.fb-heading h2 {
		margin: 0;
		font-family: var(--font-display);
		font-size: var(--text-md);
		font-weight: var(--display-weight);
		letter-spacing: var(--tracking-display);
	}

	.fb-root {
		min-width: 0;
		overflow: hidden;
		color: var(--color-muted);
		font-family: var(--font-outlier);
		font-size: var(--text-xs);
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.fb-icon {
		display: grid;
		flex: none;
		place-items: center;
		width: var(--control-height-compact);
		height: var(--control-height-compact);
		padding: 0;
		border: var(--rule-hair) solid transparent;
		border-radius: var(--radius-input);
		background: transparent;
		color: var(--color-neutral);
		cursor: pointer;
	}

	.fb-icon svg {
		width: var(--space-sm);
		height: var(--space-sm);
		fill: none;
		stroke: currentColor;
		stroke-linecap: round;
		stroke-linejoin: round;
		stroke-width: 2;
	}

	.fb-body {
		display: grid;
		flex: 1;
		grid-template-columns: minmax(14rem, 19rem) minmax(0, 1fr);
		min-height: 0;
	}

	.fb-tree {
		min-height: 0;
		padding: var(--space-2xs);
		overflow: auto;
		border-inline-end: var(--rule-hair) solid var(--color-rule);
		background: var(--color-paper-2);
	}

	.fb-row {
		display: flex;
		align-items: center;
		gap: var(--space-2xs);
		width: 100%;
		min-height: var(--control-height-compact);
		padding-block: var(--space-3xs);
		padding-inline: calc(var(--space-2xs) + var(--fb-depth, 0) * var(--space-sm)) var(--space-2xs);
		border: 0;
		border-radius: var(--radius-sm);
		background: transparent;
		color: var(--color-neutral);
		cursor: pointer;
		font-family: var(--font-outlier);
		font-size: var(--text-sm);
		text-align: start;
	}

	.fb-row.other {
		color: var(--color-muted);
		cursor: default;
	}

	.fb-row.dot {
		color: var(--color-muted);
	}

	.fb-row.active {
		background: var(--color-paper-3);
		color: var(--color-ink);
	}

	.fb-row.file {
		padding-inline-start: calc(
			var(--space-2xs) + var(--fb-depth, 0) * var(--space-sm) + var(--space-sm) + var(--space-2xs)
		);
	}

	.fb-caret {
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

	.fb-caret.open {
		transform: rotate(90deg);
	}

	.fb-name {
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.fb-sym {
		flex: none;
		color: var(--color-muted);
	}

	.fb-size {
		flex: none;
		margin-inline-start: auto;
		color: var(--color-muted);
		font-size: var(--text-xs);
	}

	.fb-note {
		padding-block: var(--space-3xs);
		padding-inline-start: calc(var(--space-2xs) + var(--fb-depth, 0) * var(--space-sm));
		color: var(--color-muted);
		font-size: var(--text-xs);
	}

	.fb-note.err {
		color: var(--color-error);
	}

	.fb-view {
		display: flex;
		flex-direction: column;
		min-width: 0;
		min-height: 0;
	}

	.fb-view-header {
		display: flex;
		align-items: center;
		gap: var(--space-2xs);
		padding: var(--space-3xs) var(--space-sm);
		border-block-end: var(--rule-hair) solid var(--color-rule);
	}

	.fb-back {
		display: none;
		place-items: center;
		width: var(--control-height-compact);
		height: var(--control-height-compact);
		padding: 0;
		border: 0;
		border-radius: var(--radius-input);
		background: transparent;
		color: var(--color-neutral);
		cursor: pointer;
	}

	.fb-back svg {
		width: var(--space-sm);
		height: var(--space-sm);
		fill: none;
		stroke: currentColor;
		stroke-linecap: round;
		stroke-linejoin: round;
		stroke-width: 2;
	}

	.fb-view-path {
		min-width: 0;
		overflow: hidden;
		color: var(--color-ink-2);
		font-family: var(--font-outlier);
		font-size: var(--text-sm);
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.fb-view-size {
		margin-inline-start: auto;
		color: var(--color-muted);
		font-family: var(--font-outlier);
		font-size: var(--text-xs);
		white-space: nowrap;
	}

	.fb-placeholder {
		padding: var(--space-lg) var(--space-sm);
		color: var(--color-muted);
		font-size: var(--text-sm);
		text-align: center;
	}

	.fb-placeholder.err {
		color: var(--color-error);
	}

	.fb-editor {
		flex: 1;
		min-height: 0;
	}

	.fb-editor.hidden {
		visibility: hidden;
	}

	/* Monaco renders decorations outside Svelte's scoping. */
	.fb-editor :global(.fb-target-line) {
		background: var(--color-accent-soft);
	}

	.fb-plain {
		flex: 1;
		margin: 0;
		padding: var(--space-xs) var(--space-sm);
		overflow: auto;
		font-family: var(--font-outlier);
		font-size: var(--text-sm);
		white-space: pre;
	}

	.fb-image {
		display: grid;
		flex: 1;
		place-items: center;
		min-height: 0;
		padding: var(--space-sm);
		overflow: auto;
	}

	.fb-image img {
		max-width: 100%;
		max-height: 100%;
		border: var(--rule-hair) solid var(--color-rule);
		border-radius: var(--radius-card);
		object-fit: contain;
	}

	@media (hover: hover) and (pointer: fine) {
		.fb-row:hover:not(.other),
		.fb-icon:hover,
		.fb-back:hover {
			background: var(--color-paper-3);
			color: var(--color-ink);
		}
	}

	@media (max-width: 59.999rem) {
		.file-browser {
			width: 100%;
			border-inline-start: 0;
		}

		.fb-body {
			grid-template-columns: minmax(0, 1fr);
		}

		/* Narrow viewports show either the tree or the open file. */
		.file-browser.file-open .fb-tree {
			display: none;
		}

		.file-browser:not(.file-open) .fb-view {
			display: none;
		}

		.fb-back {
			display: grid;
		}
	}

	@media (pointer: coarse) {
		.fb-row,
		.fb-icon,
		.fb-back {
			min-height: var(--control-height);
		}
	}
</style>
