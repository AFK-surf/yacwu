import type { Handle } from '@sveltejs/kit';
import { checkRemoteUser } from '$lib/server/auth';

/** Enforce forward-auth (Remote-User header) on every request when enabled. */
export const handle: Handle = async ({ event, resolve }) => {
	const denied = checkRemoteUser(event.request.headers);
	if (denied) return new Response(denied.message, { status: denied.status });
	return resolve(event);
};
