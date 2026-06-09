/**
 * Default config applied to every thread we create.
 *
 * Sessions run in "yolo" mode: `approvalPolicy: "never"` so the web UI never
 * blocks on a terminal-style approval prompt, and `sandbox: "danger-full-access"`
 * so commands run with full access and no sandboxing.
 */
export const THREAD_DEFAULTS: Record<string, unknown> = {
	approvalPolicy: 'never',
	sandbox: 'danger-full-access'
};
