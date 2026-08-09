import { marked, type Token, type Tokens } from 'marked';

export type MarkdownInline =
	| { type: 'text'; text: string }
	| { type: 'strong' | 'em' | 'del'; children: MarkdownInline[] }
	| { type: 'code'; text: string }
	| { type: 'break' }
	| { type: 'link'; href: string | null; title: string | null; external: boolean; children: MarkdownInline[] }
	| { type: 'image'; src: string | null; alt: string; title: string | null };

export interface MarkdownListItem {
	checked: boolean | null;
	children: MarkdownBlock[];
}

export interface MarkdownTableCell {
	align: 'center' | 'left' | 'right' | null;
	children: MarkdownInline[];
}

export type MarkdownBlock =
	| { type: 'paragraph'; children: MarkdownInline[] }
	| { type: 'heading'; depth: number; children: MarkdownInline[] }
	| { type: 'code'; text: string; language: string | null }
	| { type: 'blockquote'; children: MarkdownBlock[] }
	| { type: 'list'; ordered: boolean; start: number | null; items: MarkdownListItem[] }
	| { type: 'table'; header: MarkdownTableCell[]; rows: MarkdownTableCell[][] }
	| { type: 'rule' };

function safeResource(value: string): { value: string | null; external: boolean } {
	const href = value.trim();
	if (!href) return { value: null, external: false };
	if (/^(?:https?):\/\//i.test(href)) return { value: href, external: true };
	if (/^\/\//.test(href)) return { value: href, external: true };
	if (/^mailto:/i.test(href)) return { value: href, external: true };
	if (/^(?:\/|\.\/|\.\.\/|#|\?)/.test(href)) return { value: href, external: false };
	if (/^[a-z][a-z\d+.-]*:/i.test(href)) return { value: null, external: false };
	return { value: href, external: false };
}

function inlineTokens(tokens: Token[]): MarkdownInline[] {
	const result: MarkdownInline[] = [];
	for (const token of tokens) {
		switch (token.type) {
			case 'text': {
				const text = token as Tokens.Text;
				if (text.tokens?.length) result.push(...inlineTokens(text.tokens));
				else if (text.text) result.push({ type: 'text', text: text.text });
				break;
			}
			case 'escape':
				result.push({ type: 'text', text: (token as Tokens.Escape).text });
				break;
			case 'html':
				// Raw HTML is deliberately rendered as text; Svelte never receives an HTML string.
				result.push({ type: 'text', text: (token as Tokens.HTML).text });
				break;
			case 'strong':
			case 'em':
			case 'del':
				result.push({ type: token.type, children: inlineTokens((token as Tokens.Strong | Tokens.Em | Tokens.Del).tokens) });
				break;
			case 'codespan':
				result.push({ type: 'code', text: (token as Tokens.Codespan).text });
				break;
			case 'br':
				result.push({ type: 'break' });
				break;
			case 'link': {
				const link = token as Tokens.Link;
				const safe = safeResource(link.href);
				result.push({
					type: 'link',
					href: safe.value,
					title: link.title ?? null,
					external: safe.external,
					children: inlineTokens(link.tokens)
				});
				break;
			}
			case 'image': {
				const image = token as Tokens.Image;
				result.push({
					type: 'image',
					src: safeResource(image.href).value,
					alt: image.text,
					title: image.title
				});
				break;
			}
		}
	}
	return result;
}

function tableCell(cell: Tokens.TableCell): MarkdownTableCell {
	return { align: cell.align, children: inlineTokens(cell.tokens) };
}

function blockTokens(tokens: Token[]): MarkdownBlock[] {
	const result: MarkdownBlock[] = [];
	for (const token of tokens) {
		switch (token.type) {
			case 'space':
			case 'def':
				break;
			case 'paragraph':
				result.push({ type: 'paragraph', children: inlineTokens((token as Tokens.Paragraph).tokens) });
				break;
			case 'text': {
				const text = token as Tokens.Text;
				result.push({ type: 'paragraph', children: text.tokens?.length ? inlineTokens(text.tokens) : [{ type: 'text', text: text.text }] });
				break;
			}
			case 'html':
				result.push({ type: 'paragraph', children: [{ type: 'text', text: (token as Tokens.HTML).text }] });
				break;
			case 'heading': {
				const heading = token as Tokens.Heading;
				result.push({ type: 'heading', depth: heading.depth, children: inlineTokens(heading.tokens) });
				break;
			}
			case 'code': {
				const code = token as Tokens.Code;
				result.push({ type: 'code', text: code.text, language: code.lang?.trim() || null });
				break;
			}
			case 'blockquote':
				result.push({ type: 'blockquote', children: blockTokens((token as Tokens.Blockquote).tokens) });
				break;
			case 'list': {
				const list = token as Tokens.List;
				result.push({
					type: 'list',
					ordered: list.ordered,
					start: typeof list.start === 'number' ? list.start : null,
					items: list.items.map((item) => ({
						checked: item.task ? Boolean(item.checked) : null,
						children: blockTokens(item.tokens)
					}))
				});
				break;
			}
			case 'table': {
				const table = token as Tokens.Table;
				result.push({
					type: 'table',
					header: table.header.map(tableCell),
					rows: table.rows.map((row) => row.map(tableCell))
				});
				break;
			}
			case 'hr':
				result.push({ type: 'rule' });
				break;
		}
	}
	return result;
}

export function parseCodexMarkdown(markdown: string): MarkdownBlock[] {
	return blockTokens(marked.lexer(markdown.replace(/^[\u200B-\u200F\uFEFF]/, ''), { gfm: true }));
}
