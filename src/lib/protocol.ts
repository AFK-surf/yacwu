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
	| PlanItem
	| SubAgentActivityItem
	| GenericItem;

export interface Turn {
	id: string;
	status: string;
	items?: ThreadItem[];
}
