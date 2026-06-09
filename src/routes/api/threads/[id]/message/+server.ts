import { json } from '@sveltejs/kit';
import { writeFile } from 'node:fs/promises';
import { extname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { codex } from '$lib/server/codex';
import type { RequestHandler } from './$types';

function imageExtension(file: File): string {
	const byType: Record<string, string> = {
		'image/png': '.png',
		'image/jpeg': '.jpg',
		'image/webp': '.webp',
		'image/gif': '.gif'
	};
	const fromType = byType[file.type.toLowerCase()];
	if (fromType) return fromType;
	const fromName = extname(file.name).toLowerCase();
	return /^[a-z0-9.]{1,10}$/.test(fromName) ? fromName : '.img';
}

async function stageImage(file: File): Promise<string> {
	if (!file.type.toLowerCase().startsWith('image/')) {
		throw new Error(`${file.name || 'upload'} is not an image`);
	}
	const path = join(tmpdir(), `yacwu-${randomUUID()}${imageExtension(file)}`);
	await writeFile(path, new Uint8Array(await file.arrayBuffer()));
	return path;
}

/** Send user input, starting a new turn on the thread. */
export const POST: RequestHandler = async ({ params, request }) => {
	await codex.start();
	const contentType = request.headers.get('content-type') ?? '';
	const input: unknown[] = [];

	if (contentType.includes('multipart/form-data')) {
		const form = await request.formData();
		const text = (form.get('text') ?? '').toString();
		if (text.trim()) input.push({ type: 'text', text });
		for (const value of form.getAll('images')) {
			if (!(value instanceof File) || value.size === 0) continue;
			let path: string;
			try {
				path = await stageImage(value);
			} catch (err) {
				return json({ error: err instanceof Error ? err.message : 'invalid image' }, { status: 400 });
			}
			input.push({ type: 'localImage', path });
		}
	} else {
		const body = await request.json().catch(() => ({}));
		const text = (body.text ?? '').toString();
		if (text.trim()) input.push({ type: 'text', text });
	}

	if (input.length === 0) return json({ error: 'empty message' }, { status: 400 });

	const result = await codex.request('turn/start', {
		threadId: params.id,
		input
	});
	return json(result);
};
