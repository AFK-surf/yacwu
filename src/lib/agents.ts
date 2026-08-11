// Sub-agent (multi-agent collaboration) tracking.
//
// Codex models every spawned agent as a real thread. The parent transcript's
// `collabAgentToolCall` and `subAgentActivity` items carry the agent thread
// ids, and `thread/read` on an agent thread reports its nickname, role, and
// parent. This module keeps a small client-side registry of those agent
// threads so the UI can offer per-agent transcripts. Pure functions only —
// the layout owns the reactive state and passes its registry in.

export interface AgentInfo {
	id: string;
	/** Thread that spawned (or first mentioned) this agent. */
	parentId: string;
	/** Human-friendly nickname codex assigns to spawned agents (e.g. "Scout"). */
	nickname: string | null;
	/** Agent role (e.g. "worker", "explorer"). */
	role: string | null;
	/** Canonical agent path from subAgentActivity (e.g. "root/worker-1"). */
	path: string | null;
	/** Last collab-reported lifecycle state (running, completed, errored…). */
	state: string | null;
	/** The agent was closed (closeAgent / shutdown) and won't run again. */
	closed: boolean;
}

/** Keyed by agent thread id. Insertion order is the display order. */
export type AgentRegistry = Record<string, AgentInfo>;

function ensureAgent(registry: AgentRegistry, id: string, parentId: string): AgentInfo {
	if (!registry[id]) {
		registry[id] = {
			id,
			parentId,
			nickname: null,
			role: null,
			path: null,
			state: null,
			closed: false
		};
	}
	return registry[id];
}

function applyCollabState(agent: AgentInfo, status: string) {
	agent.state = status;
	if (status === 'shutdown' || status === 'notFound') agent.closed = true;
	else if (status === 'running' || status === 'pendingInit') agent.closed = false;
}

/**
 * Fold one transcript item into the registry. `ownerThreadId` is the thread
 * whose transcript contains the item (the spawner's side of the call).
 * Returns true when the item concerned agents at all.
 */
export function trackAgentItem(
	registry: AgentRegistry,
	ownerThreadId: string,
	item: unknown
): boolean {
	const it = item as Record<string, any> | null;
	if (!it || typeof it !== 'object') return false;

	if (it.type === 'subAgentActivity') {
		const agentId = typeof it.agentThreadId === 'string' ? it.agentThreadId : '';
		if (!agentId || agentId === ownerThreadId) return false;
		const agent = ensureAgent(registry, agentId, ownerThreadId);
		if (typeof it.agentPath === 'string' && it.agentPath) agent.path = it.agentPath;
		if (it.kind === 'started') applyCollabState(agent, 'running');
		else if (it.kind === 'interrupted') agent.state = 'interrupted';
		return true;
	}

	if (it.type !== 'collabAgentToolCall') return false;

	const parentId =
		typeof it.senderThreadId === 'string' && it.senderThreadId
			? it.senderThreadId
			: ownerThreadId;
	const receivers: string[] = Array.isArray(it.receiverThreadIds)
		? it.receiverThreadIds.filter((r: unknown) => typeof r === 'string' && r !== parentId)
		: [];
	for (const receiver of receivers) ensureAgent(registry, receiver, parentId);

	const completed = it.status === 'completed';
	if (completed && (it.tool === 'spawnAgent' || it.tool === 'resumeAgent')) {
		for (const receiver of receivers) applyCollabState(registry[receiver], 'running');
	} else if (completed && it.tool === 'closeAgent') {
		for (const receiver of receivers) applyCollabState(registry[receiver], 'shutdown');
	}

	// `wait` (and failed calls) report per-agent states keyed by thread id.
	const states = it.agentsStates;
	if (states && typeof states === 'object') {
		for (const [agentId, state] of Object.entries(states as Record<string, any>)) {
			if (agentId === parentId) continue;
			const agent = ensureAgent(registry, agentId, parentId);
			if (typeof state?.status === 'string') applyCollabState(agent, state.status);
		}
	}
	return true;
}

/** Whether a `thread` payload (thread/read, thread/started) is a sub-agent thread. */
export function isSubAgentThread(thr: unknown): boolean {
	const t = thr as Record<string, any> | null;
	if (!t || typeof t !== 'object') return false;
	if (typeof t.parentThreadId === 'string' && t.parentThreadId) return true;
	return Boolean(t.source && typeof t.source === 'object' && 'subAgent' in t.source);
}

/**
 * Merge metadata from a `thread` payload into the registry. Registers the
 * thread when it is a sub-agent (or `fallbackParentId` is given); otherwise
 * only updates an already-registered entry.
 */
export function mergeAgentThreadMeta(
	registry: AgentRegistry,
	thr: unknown,
	fallbackParentId?: string
): AgentInfo | null {
	const t = thr as Record<string, any> | null;
	if (!t || typeof t !== 'object' || typeof t.id !== 'string' || !t.id) return null;
	const parentId =
		typeof t.parentThreadId === 'string' && t.parentThreadId ? t.parentThreadId : null;
	let agent = registry[t.id];
	if (!agent) {
		const parent = parentId ?? fallbackParentId ?? null;
		if (!parent) return null;
		agent = ensureAgent(registry, t.id, parent);
	} else if (parentId) {
		agent.parentId = parentId;
	}
	if (typeof t.agentNickname === 'string' && t.agentNickname) agent.nickname = t.agentNickname;
	if (typeof t.agentRole === 'string' && t.agentRole) agent.role = t.agentRole;
	// The TUI treats a not-loaded agent thread as closed: collab agents only
	// run while their parent turn holds them in memory.
	if (t.status?.type === 'notLoaded') agent.closed = true;
	else if (t.status?.type === 'active') applyCollabState(agent, 'running');
	return agent;
}

/** The session at the root of an agent's spawn chain. */
export function agentRootId(registry: AgentRegistry, agent: AgentInfo): string {
	const seen = new Set<string>([agent.id]);
	let root = agent.parentId;
	while (registry[root] && !seen.has(root)) {
		seen.add(root);
		root = registry[root].parentId;
	}
	return root;
}

/** All agents descending from `sessionId`, in registration (spawn) order. */
export function agentsForSession(registry: AgentRegistry, sessionId: string): AgentInfo[] {
	return Object.values(registry).filter(
		(agent) => agentRootId(registry, agent) === sessionId
	);
}

/** Short display label: nickname, else the agent path's last segment, else id. */
export function agentLabel(agent: AgentInfo): string {
	if (agent.nickname) return agent.nickname;
	const tail = agent.path?.split('/').filter(Boolean).pop();
	if (tail) return tail;
	return agent.id.slice(0, 8);
}
