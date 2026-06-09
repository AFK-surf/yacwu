import { json } from '@sveltejs/kit';
import { codex } from '$lib/server/codex';
import { THREAD_DEFAULTS } from '$lib/server/defaults';
import type { RequestHandler } from './$types';

/** List stored codex sessions (newest first). */
export const GET: RequestHandler = async () => {
	await codex.start();
	const result = await codex.request('thread/list', { limit: 100, sortKey: 'updated_at' });
	return json(result);
};

/** Create a new thread (session). */
export const POST: RequestHandler = async ({ request }) => {
	await codex.start();
	const body = await request.json().catch(() => ({}));
	const params: Record<string, unknown> = { ...THREAD_DEFAULTS };
	if (body.cwd) params.cwd = body.cwd;
	if (body.model) params.model = body.model;
	const result = await codex.request('thread/start', params);
	return json(result);
};
