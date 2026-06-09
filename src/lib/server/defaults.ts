/**
 * Default config applied to every thread we create. We run non-interactively
 * (approvalPolicy "never") so the web UI never blocks on a terminal-style
 * approval prompt, with workspace-write sandboxing.
 */
export const THREAD_DEFAULTS: Record<string, unknown> = {
	approvalPolicy: 'never',
	sandbox: 'workspace-write'
};
