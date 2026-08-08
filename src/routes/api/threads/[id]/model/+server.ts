import { json } from '@sveltejs/kit';
import { codex } from '$lib/server/codex';
import { getThreadModelState, setThreadModelState } from '$lib/server/threadModel';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async ({ params }) => {
	await codex.start();
	try {
		return json(await getThreadModelState(params.id));
	} catch (err) {
		return json(
			{ error: err instanceof Error ? err.message : 'failed to read model settings' },
			{ status: 500 }
		);
	}
};

export const POST: RequestHandler = async ({ params, request }) => {
	await codex.start();
	const body = await request.json().catch(() => ({}));
	const model = typeof body.model === 'string' && body.model.trim() ? body.model.trim() : undefined;
	const effort =
		typeof body.effort === 'string' && body.effort.trim() ? body.effort.trim().toLowerCase() : undefined;
	if (!model && !effort) return json({ error: 'model or effort is required' }, { status: 400 });

	try {
		return json(await setThreadModelState(params.id, { model, effort }));
	} catch (err) {
		return json(
			{ error: err instanceof Error ? err.message : 'failed to change model settings' },
			{ status: 400 }
		);
	}
};
