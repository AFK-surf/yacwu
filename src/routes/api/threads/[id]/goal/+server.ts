import { json } from '@sveltejs/kit';
import { codex } from '$lib/server/codex';
import type { RequestHandler } from './$types';

/** Read a thread's current goal (null if none). */
export const GET: RequestHandler = async ({ params }) => {
	await codex.start();
	try {
		const result = await codex.request('thread/goal/get', { threadId: params.id });
		return json(result);
	} catch {
		return json({ goal: null });
	}
};

/** Set or clear a thread's goal (the same state the TUI's /goal manages). */
export const POST: RequestHandler = async ({ params, request }) => {
	await codex.start();
	const threadId = params.id;
	const body = await request.json().catch(() => ({}));

	if (body?.clear) {
		const result = await codex.request('thread/goal/clear', { threadId });
		return json(result);
	}

	const objective = (body?.objective ?? '').toString().trim();
	if (!objective) return json({ error: 'goal objective is required' }, { status: 400 });
	if (objective.length > 4000) {
		return json({ error: 'goal objective must be at most 4000 characters' }, { status: 400 });
	}

	const setParams: Record<string, unknown> = { threadId, objective, status: 'active' };
	if (typeof body.tokenBudget === 'number') setParams.tokenBudget = body.tokenBudget;

	const result = await codex.request('thread/goal/set', setParams);
	return json(result);
};
