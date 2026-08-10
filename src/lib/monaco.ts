/**
 * Lazy Monaco loader. Monaco is not vendored: it loads on demand from
 * jsDelivr (pinned version) via its AMD loader the first time the file
 * viewer needs it, so sessions that never open the file browser pay nothing.
 *
 * Workers are cross-origin, so `getWorkerUrl` returns the documented
 * same-origin data: URL shim that `importScripts` the CDN worker.
 */

const MONACO_VERSION = '0.56.0';
const MONACO_BASE = `https://cdn.jsdelivr.net/npm/monaco-editor@${MONACO_VERSION}/min`;

// Monaco's types are not installed (nothing is vendored), so the handle is
// deliberately untyped.
export type Monaco = any;

let monacoPromise: Promise<Monaco> | null = null;

export function loadMonaco(): Promise<Monaco> {
	if (!monacoPromise) {
		monacoPromise = load().catch((error) => {
			// A CDN hiccup should not poison every later attempt.
			monacoPromise = null;
			throw error;
		});
	}
	return monacoPromise;
}

async function load(): Promise<Monaco> {
	await injectScript(`${MONACO_BASE}/vs/loader.js`);
	const amdRequire = (window as any).require;
	amdRequire.config({ paths: { vs: `${MONACO_BASE}/vs` } });
	(window as any).MonacoEnvironment = {
		getWorkerUrl: () =>
			`data:text/javascript;charset=utf-8,${encodeURIComponent(
				`self.MonacoEnvironment={baseUrl:'${MONACO_BASE}/'};importScripts('${MONACO_BASE}/vs/base/worker/workerMain.js');`
			)}`
	};
	const monaco = await new Promise<Monaco>((resolve, reject) => {
		amdRequire(
			['vs/editor/editor.main'],
			() => resolve((window as any).monaco),
			(error: unknown) => reject(error instanceof Error ? error : new Error('failed to load Monaco'))
		);
	});
	defineTheme(monaco);
	// Grammars Monaco lacks (TOML, Gleam) live in their own lazy chunk.
	const { registerExtraLanguages } = await import('$lib/monaco-grammars');
	registerExtraLanguages(monaco);
	return monaco;
}

function injectScript(src: string): Promise<void> {
	return new Promise((resolve, reject) => {
		const script = document.createElement('script');
		script.src = src;
		script.onload = () => resolve();
		script.onerror = () => reject(new Error(`failed to load ${src}`));
		document.head.appendChild(script);
	});
}

/** A light editor theme on the app's paper surface (tokens.css palette). */
function defineTheme(monaco: Monaco) {
	monaco.editor.defineTheme('yacwu-paper', {
		base: 'vs',
		inherit: true,
		rules: [
			{ token: 'comment', foreground: '8a8071', fontStyle: 'italic' },
			{ token: 'keyword', foreground: '9a3d1d' },
			{ token: 'string', foreground: '5c6e3c' },
			{ token: 'number', foreground: '7a4a9e' },
			{ token: 'type', foreground: '2f5d8a' },
			{ token: 'key', foreground: '2f5d8a' },
			{ token: 'constant', foreground: '7a4a9e' },
			{ token: 'annotation', foreground: '8a8071' }
		],
		colors: {
			'editor.background': '#faf8f1',
			'editor.foreground': '#2e2a24',
			'editor.lineHighlightBackground': '#f3efe3',
			'editorLineNumber.foreground': '#a89d8a',
			'editorLineNumber.activeForeground': '#5c5546',
			'editor.selectionBackground': '#efd9c4',
			'diffEditor.insertedLineBackground': '#edf6e9',
			'diffEditor.removedLineBackground': '#fae9e5',
			'diffEditor.insertedTextBackground': '#cfe8c788',
			'diffEditor.removedTextBackground': '#f0c7bf88',
			'diffEditor.diagonalFill': '#ded5c266',
			'editorWidget.background': '#f6f2e7',
			'editorWidget.border': '#ded5c2',
			'scrollbarSlider.background': '#ded5c266',
			'scrollbarSlider.hoverBackground': '#ded5c2aa',
			'scrollbarSlider.activeBackground': '#ded5c2dd'
		}
	});
}
