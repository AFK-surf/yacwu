// Minimal shared types for the subset of the codex app-server protocol we use.
// Full schema: docs/codex-app-server.md

export interface JsonRpcNotification {
	method: string;
	params?: Record<string, unknown> & { threadId?: string };
	/** Present only on server-initiated requests (e.g. approvals). */
	id?: number;
}

export interface ThreadSummary {
	id: string;
	preview: string;
	name: string | null;
	createdAt: number;
	updatedAt: number;
	cwd?: string;
	status?: { type: string };
	/** Source thread id when this thread was created by forking another. */
	forkedFromId?: string | null;
	/** Ephemeral threads (side conversations) are never persisted. */
	ephemeral?: boolean;
	/** Which machine the session's codex app-server runs on ("local" or an ~/.ssh/config alias). */
	host?: string;
}

/** A machine sessions can run on: local, or an ~/.ssh/config alias. */
export interface HostInfo {
	name: string;
	kind: 'local' | 'remote';
	state: 'connected' | 'connecting' | 'disconnected';
	error?: string | null;
}

export const LOCAL_HOST = 'local';

export function isRemoteHost(host: string | undefined | null): boolean {
	return typeof host === 'string' && host !== '' && host !== LOCAL_HOST;
}

/**
 * Query-string suffix routing an /api/threads request to a session's host.
 * Empty for local (and unknown) hosts, so existing local behaviour and URLs
 * are untouched.
 */
export function hostQuery(host: string | undefined | null): string {
	return isRemoteHost(host) ? `?host=${encodeURIComponent(host as string)}` : '';
}

export interface TextContent {
	type: 'text';
	text: string;
}

export interface UserMessageItem {
	type: 'userMessage';
	id: string;
	content: Array<{ type: string; text?: string; path?: string; url?: string }>;
}

export interface AgentMessageItem {
	type: 'agentMessage';
	id: string;
	text: string;
	phase?: string;
}

export interface ReasoningItem {
	type: 'reasoning';
	id: string;
	summary?: unknown;
	content?: unknown;
}

export interface CommandExecutionItem {
	type: 'commandExecution';
	id: string;
	command: string;
	cwd?: string;
	status: string;
	aggregatedOutput?: string;
	exitCode?: number;
}

export interface FileChangeItem {
	type: 'fileChange';
	id: string;
	status: string;
	changes: Array<{ path: string; kind: unknown; diff?: string }>;
}

export type WebSearchAction =
	| { type: 'search'; query?: string | null; queries?: string[] | null }
	| { type: 'openPage'; url?: string | null }
	| { type: 'findInPage'; url?: string | null; pattern?: string | null }
	| { type: 'other' };

export interface WebSearchItem {
	type: 'webSearch';
	id: string;
	query: string;
	action?: WebSearchAction | null;
	results?: unknown[] | null;
}

export interface PlanItem {
	type: 'plan';
	id: string;
	text?: string;
	plan?: Array<{ step: string; status: string }>;
}

export interface SubAgentActivityItem {
	type: 'subAgentActivity';
	id: string;
	kind: 'started' | 'interacted' | 'interrupted';
	agentThreadId: string;
	agentPath: string;
}

export interface CollabAgentState {
	status:
		| 'pendingInit'
		| 'running'
		| 'interrupted'
		| 'completed'
		| 'errored'
		| 'shutdown'
		| 'notFound';
	message?: string | null;
}

export interface CollabAgentToolCallItem {
	type: 'collabAgentToolCall';
	id: string;
	tool: 'spawnAgent' | 'sendInput' | 'resumeAgent' | 'wait' | 'closeAgent';
	status: 'inProgress' | 'completed' | 'failed';
	senderThreadId: string;
	receiverThreadIds: string[];
	prompt?: string | null;
	model?: string | null;
	reasoningEffort?: string | null;
	agentsStates?: Record<string, CollabAgentState>;
}

export interface GenericItem {
	type: string;
	id: string;
	[key: string]: unknown;
}

export type ThreadItem =
	| UserMessageItem
	| AgentMessageItem
	| ReasoningItem
	| CommandExecutionItem
	| FileChangeItem
	| WebSearchItem
	| PlanItem
	| SubAgentActivityItem
	| CollabAgentToolCallItem
	| GenericItem;

export interface Turn {
	id: string;
	status: string;
	items?: ThreadItem[];
}

/** Codex reports cumulative thread usage in `total` and active-context usage in `last`. */
export function currentContextTokens(tokenUsage: unknown): number | null {
	if (!tokenUsage || typeof tokenUsage !== 'object') return null;
	const last = (tokenUsage as { last?: unknown }).last;
	if (!last || typeof last !== 'object') return null;
	const tokens = (last as { totalTokens?: unknown }).totalTokens;
	return typeof tokens === 'number' && Number.isFinite(tokens) && tokens >= 0 ? tokens : null;
}
