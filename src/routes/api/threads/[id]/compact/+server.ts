import { json } from '@sveltejs/kit';
import { codex } from '$lib/server/codex';
import type { RequestHandler } from './$types';

/** Trigger conversation history compaction (the TUI's /compact). */
export const POST: RequestHandler = async ({ params }) => {
	await codex.start();
	const result = await codex.request('thread/compact/start', { threadId: params.id });
	return json(result);
};
