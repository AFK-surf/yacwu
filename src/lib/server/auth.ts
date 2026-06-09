// Forward-auth support.
//
// When `YACWU_REMOTE_USERS` is set to a comma-separated allowlist, every request
// must carry a `Remote-User` header whose value is in the list. This is the
// header reverse proxies (Authelia, Traefik forward-auth, oauth2-proxy, …) inject
// after authenticating the user. When the variable is empty/unset, auth is off.
//
// The binary's `--remote-user` flag sets `YACWU_REMOTE_USERS`, so the same code
// path covers dev, `bun run start`, and the compiled binary.

/** The configured allowlist (empty set = auth disabled). Read per-request. */
export function allowedRemoteUsers(): Set<string> {
	const raw = process.env.YACWU_REMOTE_USERS ?? '';
	return new Set(raw.split(',').map((u) => u.trim()).filter(Boolean));
}

export interface AuthDenial {
	status: number;
	message: string;
}

/**
 * Returns `null` when the request is allowed, or an HTTP status + message when it
 * must be rejected. No-op when no allowlist is configured.
 */
export function checkRemoteUser(headers: Headers): AuthDenial | null {
	const allowed = allowedRemoteUsers();
	if (allowed.size === 0) return null; // auth disabled

	const user = headers.get('remote-user')?.trim();
	if (!user) return { status: 401, message: 'Missing Remote-User header' };
	if (!allowed.has(user)) return { status: 403, message: 'Forbidden' };
	return null;
}
