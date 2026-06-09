<script>
	let { children } = $props();
</script>

<svelte:head>
	<link rel="preconnect" href="https://fonts.googleapis.com" />
</svelte:head>

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
</style>
