/**
 * Monarch grammars for languages Monaco does not ship (TOML, Gleam).
 *
 * Registration is metadata-only; each tokenizer attaches lazily via
 * `monaco.languages.onLanguage`, so a grammar is only constructed when a
 * file of that language is actually opened. This module itself is loaded
 * with a dynamic import alongside Monaco, keeping it out of the app bundle.
 */

import type { Monaco } from '$lib/monaco';

export function registerExtraLanguages(monaco: Monaco) {
	register(monaco, { id: 'toml', extensions: ['.toml'], aliases: ['TOML'] }, tomlLanguage);
	register(monaco, { id: 'gleam', extensions: ['.gleam'], aliases: ['Gleam'] }, gleamLanguage);
}

function register(monaco: Monaco, definition: { id: string; extensions: string[]; aliases: string[] }, language: unknown) {
	const registered = monaco.languages.getLanguages().some((l: { id: string }) => l.id === definition.id);
	if (registered) return;
	monaco.languages.register(definition);
	monaco.languages.onLanguage(definition.id, () => {
		monaco.languages.setMonarchTokensProvider(definition.id, language);
	});
}

const tomlLanguage = {
	defaultToken: '',
	tokenPostfix: '.toml',
	tokenizer: {
		root: [
			[/#.*$/, 'comment'],
			// [table] and [[array-of-tables]] headers.
			[/^\s*\[\[?[^\]]*\]\]?/, 'type'],
			// Bare or quoted keys before an equals sign.
			[/([A-Za-z0-9_.-]+)(\s*)(=)/, ['key', '', 'delimiter']],
			[/("[^"]*"|'[^']*')(\s*)(=)/, ['key', '', 'delimiter']],
			{ include: '@value' }
		],
		value: [
			[/"""/, { token: 'string', next: '@tripleString' }],
			[/"(\\.|[^"\\])*"/, 'string'],
			[/'''/, { token: 'string', next: '@tripleLiteral' }],
			[/'[^']*'/, 'string'],
			[/\b(true|false)\b/, 'keyword'],
			// Dates before numbers: 1979-05-27T07:32:00Z, 07:32:00, 1979-05-27.
			[/\d{4}-\d{2}-\d{2}([Tt ]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})?)?/, 'number'],
			[/\d{2}:\d{2}:\d{2}(\.\d+)?/, 'number'],
			[/[+-]?(0x[0-9A-Fa-f_]+|0o[0-7_]+|0b[01_]+|inf|nan|\d[\d_]*(\.[\d_]+)?([eE][+-]?[\d_]+)?)/, 'number'],
			[/[,{}[\]]/, 'delimiter'],
			[/#.*$/, 'comment']
		],
		tripleString: [
			[/"""/, { token: 'string', next: '@pop' }],
			[/./, 'string']
		],
		tripleLiteral: [
			[/'''/, { token: 'string', next: '@pop' }],
			[/./, 'string']
		]
	}
};

const gleamLanguage = {
	defaultToken: '',
	tokenPostfix: '.gleam',
	keywords: [
		'as',
		'assert',
		'auto',
		'case',
		'const',
		'delegate',
		'derive',
		'echo',
		'else',
		'fn',
		'if',
		'implement',
		'import',
		'let',
		'macro',
		'opaque',
		'panic',
		'pub',
		'test',
		'todo',
		'type',
		'use'
	],
	tokenizer: {
		root: [
			[/\/\/.*$/, 'comment'],
			[/@[a-z_]+/, 'annotation'],
			[/"(\\.|[^"\\])*"/, 'string'],
			[/\b(True|False|Nil)\b/, 'constant'],
			[/\b0[bB][01_]+\b/, 'number'],
			[/\b0[oO][0-7_]+\b/, 'number'],
			[/\b0[xX][0-9a-fA-F_]+\b/, 'number'],
			[/\b\d[\d_]*(\.[\d_]+)?(e-?[\d_]+)?\b/, 'number'],
			// Type names and constructors are capitalized.
			[/[A-Z][A-Za-z0-9_]*/, 'type'],
			[/[a-z_][a-z0-9_]*/, { cases: { '@keywords': 'keyword', '@default': 'identifier' } }],
			[/<<|>>|<-|->|\|>|\|\||&&|[=+\-*/<>!.]=?|%/, 'operator'],
			[/[{}()[\],.:#]/, 'delimiter']
		]
	}
};
