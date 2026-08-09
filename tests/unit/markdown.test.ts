/// <reference types="bun" />
import { expect, test } from 'bun:test';
import { parseCodexMarkdown } from '../../src/lib/markdown';

test('preserves heading depth and inline emphasis without generating HTML', () => {
	const blocks = parseCodexMarkdown('# Result\n\nUse **bold** and `code`.');
	expect(blocks).toEqual([
		{ type: 'heading', depth: 1, children: [{ type: 'text', text: 'Result' }] },
		{
			type: 'paragraph',
			children: [
				{ type: 'text', text: 'Use ' },
				{ type: 'strong', children: [{ type: 'text', text: 'bold' }] },
				{ type: 'text', text: ' and ' },
				{ type: 'code', text: 'code' },
				{ type: 'text', text: '.' }
			]
		}
	]);
});

test('keeps raw HTML inert and rejects executable URLs', () => {
	const blocks = parseCodexMarkdown('<script>alert(1)</script>\n\n[unsafe](javascript:alert(1))');
	expect(blocks[0]).toEqual({
		type: 'paragraph',
		children: [{ type: 'text', text: '<script>alert(1)</script>' }]
	});
	expect(blocks[1]).toMatchObject({
		type: 'paragraph',
		children: [{ type: 'link', href: null, external: false }]
	});
});

test('parses lists, fenced code, and GitHub-flavored tables', () => {
	const blocks = parseCodexMarkdown('- one\n- two\n\n```ts\nconst ok = true;\n```\n\n| File | State |\n| --- | --- |\n| app.ts | changed |');
	expect(blocks.map((block) => block.type)).toEqual(['list', 'code', 'table']);
	expect(blocks[1]).toMatchObject({ type: 'code', language: 'ts', text: 'const ok = true;' });
});
