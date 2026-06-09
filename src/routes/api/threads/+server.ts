import { json } from '@sveltejs/kit';
import { statSync } from 'node:fs';
import { resolve } from 'node:path';
import { homedir } from 'node:os';
import { codex } from '$lib/server/codex';
import { THREAD_DEFAULTS } from '$lib/server/defaults';
import type { RequestHandler } from './$types';

/** Working directory codex uses when none is specified. */
const defaultCwd = process.env.YACWU_CWD || homedir();

/** List stored codex sessions (newest first), plus the default working dir. */
export const GET: RequestHandler = async () => {
	await codex.start();
	const result = await codex.request<{ data: unknown[] }>('thread/list', {
		limit: 100,
		sortKey: 'updated_at'
	});
	return json({ ...result, defaultCwd });
};

/** Create a new thread (session), optionally in a specific working directory. */
export const POST: RequestHandler = async ({ request }) => {
	await codex.start();
	const body = await request.json().catch(() => ({}));
	const params: Record<string, unknown> = { ...THREAD_DEFAULTS };

	if (body.cwd) {
		// Resolve relative paths against the default cwd and verify the directory exists.
		const cwd = resolve(defaultCwd, String(body.cwd).replace(/^~(?=$|\/)/, homedir()));
		try {
			if (!statSync(cwd).isDirectory()) {
				return json({ error: `Not a directory: ${cwd}` }, { status: 400 });
			}
		} catch {
			return json({ error: `Directory does not exist: ${cwd}` }, { status: 400 });
		}
		params.cwd = cwd;
	}
	if (body.model) params.model = body.model;

	const result = await codex.request('thread/start', params);
	return json(result);
};
