/**
 * Default config applied to every thread we create.
 *
 * Sessions run in "yolo" mode: `approvalPolicy: "never"` so the web UI never
 * blocks on a terminal-style approval prompt, and `sandbox: "danger-full-access"`
 * so commands run with full access and no sandboxing.
 */
export const IMAGE_OUTPUT_INSTRUCTIONS =
	'When you need to show an image to the user, save it to a local file and include exactly one XML block containing its absolute path: <agent-img>/absolute/path/to/image.png</agent-img>. Put no markdown image syntax inside the block.';

export const THREAD_DEFAULTS: Record<string, unknown> = {
	approvalPolicy: 'never',
	sandbox: 'danger-full-access',
	developerInstructions: IMAGE_OUTPUT_INSTRUCTIONS
};
