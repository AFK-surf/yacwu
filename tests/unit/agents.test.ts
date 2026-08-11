/// <reference types="bun" />
import { expect, test } from 'bun:test';
import {
	agentLabel,
	agentRootId,
	agentsForSession,
	isSubAgentThread,
	mergeAgentThreadMeta,
	trackAgentItem,
	type AgentRegistry
} from '../../src/lib/agents';

const SESSION = 'thr-session';
const AGENT_A = 'thr-agent-a';
const AGENT_B = 'thr-agent-b';

function spawn(receivers: string[], status = 'completed', sender = SESSION) {
	return {
		type: 'collabAgentToolCall',
		id: 'item-1',
		tool: 'spawnAgent',
		status,
		senderThreadId: sender,
		receiverThreadIds: receivers
	};
}

test('spawnAgent registers receivers under the sender, running once completed', () => {
	const registry: AgentRegistry = {};
	trackAgentItem(registry, SESSION, spawn([AGENT_A], 'inProgress'));
	expect(registry[AGENT_A]).toBeDefined();
	expect(registry[AGENT_A].parentId).toBe(SESSION);
	expect(registry[AGENT_A].state).toBeNull();

	trackAgentItem(registry, SESSION, spawn([AGENT_A], 'completed'));
	expect(registry[AGENT_A].state).toBe('running');
	expect(registry[AGENT_A].closed).toBe(false);
});

test('closeAgent marks receivers closed; resumeAgent reopens them', () => {
	const registry: AgentRegistry = {};
	trackAgentItem(registry, SESSION, spawn([AGENT_A]));
	trackAgentItem(registry, SESSION, {
		type: 'collabAgentToolCall',
		id: 'item-2',
		tool: 'closeAgent',
		status: 'completed',
		senderThreadId: SESSION,
		receiverThreadIds: [AGENT_A]
	});
	expect(registry[AGENT_A].closed).toBe(true);

	trackAgentItem(registry, SESSION, {
		type: 'collabAgentToolCall',
		id: 'item-3',
		tool: 'resumeAgent',
		status: 'completed',
		senderThreadId: SESSION,
		receiverThreadIds: [AGENT_A]
	});
	expect(registry[AGENT_A].closed).toBe(false);
});

test('wait folds per-agent states, closing shut-down agents', () => {
	const registry: AgentRegistry = {};
	trackAgentItem(registry, SESSION, spawn([AGENT_A, AGENT_B]));
	trackAgentItem(registry, SESSION, {
		type: 'collabAgentToolCall',
		id: 'item-4',
		tool: 'wait',
		status: 'completed',
		senderThreadId: SESSION,
		receiverThreadIds: [AGENT_A, AGENT_B],
		agentsStates: {
			[AGENT_A]: { status: 'completed', message: 'done' },
			[AGENT_B]: { status: 'shutdown' }
		}
	});
	expect(registry[AGENT_A].state).toBe('completed');
	expect(registry[AGENT_A].closed).toBe(false);
	expect(registry[AGENT_B].closed).toBe(true);
});

test('subAgentActivity registers the agent thread with its path', () => {
	const registry: AgentRegistry = {};
	trackAgentItem(registry, SESSION, {
		type: 'subAgentActivity',
		id: 'item-5',
		kind: 'started',
		agentThreadId: AGENT_A,
		agentPath: 'root/worker-1'
	});
	expect(registry[AGENT_A].path).toBe('root/worker-1');
	expect(registry[AGENT_A].state).toBe('running');
	expect(agentLabel(registry[AGENT_A])).toBe('worker-1');
});

test('unrelated items and self-references are ignored', () => {
	const registry: AgentRegistry = {};
	expect(trackAgentItem(registry, SESSION, { type: 'agentMessage', id: 'x', text: 'hi' })).toBe(
		false
	);
	trackAgentItem(registry, SESSION, spawn([SESSION]));
	expect(Object.keys(registry)).toEqual([]);
});

test('nested agents chain to the root session and list in spawn order', () => {
	const registry: AgentRegistry = {};
	trackAgentItem(registry, SESSION, spawn([AGENT_A]));
	// AGENT_A spawns AGENT_B (depth 2): the item lives in AGENT_A's transcript.
	trackAgentItem(registry, AGENT_A, spawn([AGENT_B], 'completed', AGENT_A));
	expect(agentRootId(registry, registry[AGENT_B])).toBe(SESSION);
	expect(agentsForSession(registry, SESSION).map((a) => a.id)).toEqual([AGENT_A, AGENT_B]);
	expect(agentsForSession(registry, 'other')).toEqual([]);
});

test('thread metadata merges nickname, role, and closed state', () => {
	const registry: AgentRegistry = {};
	trackAgentItem(registry, SESSION, spawn([AGENT_A]));
	const merged = mergeAgentThreadMeta(registry, {
		id: AGENT_A,
		parentThreadId: SESSION,
		agentNickname: 'Scout',
		agentRole: 'explorer',
		status: { type: 'notLoaded' }
	});
	expect(merged?.nickname).toBe('Scout');
	expect(registry[AGENT_A].role).toBe('explorer');
	expect(registry[AGENT_A].closed).toBe(true);
	expect(agentLabel(registry[AGENT_A])).toBe('Scout');
});

test('thread metadata can register an unseen sub-agent thread', () => {
	const registry: AgentRegistry = {};
	const merged = mergeAgentThreadMeta(registry, {
		id: AGENT_A,
		parentThreadId: SESSION,
		agentNickname: 'Atlas',
		status: { type: 'active', activeFlags: [] }
	});
	expect(merged?.parentId).toBe(SESSION);
	expect(registry[AGENT_A].state).toBe('running');
	// Without a parent hint, a plain thread payload is not an agent.
	expect(mergeAgentThreadMeta(registry, { id: 'thr-plain' })).toBeNull();
	// With a fallback parent (deep link), registration is explicit.
	expect(mergeAgentThreadMeta(registry, { id: AGENT_B }, SESSION)?.parentId).toBe(SESSION);
});

test('isSubAgentThread detects parentThreadId and subAgent sources', () => {
	expect(isSubAgentThread({ id: 'x', parentThreadId: SESSION })).toBe(true);
	expect(isSubAgentThread({ id: 'x', source: { subAgent: { thread_spawn: {} } } })).toBe(true);
	expect(isSubAgentThread({ id: 'x', source: 'cli' })).toBe(false);
	expect(isSubAgentThread(null)).toBe(false);
});

test('agent cycles cannot hang the root walk', () => {
	const registry: AgentRegistry = {};
	trackAgentItem(registry, AGENT_B, spawn([AGENT_A], 'completed', AGENT_B));
	trackAgentItem(registry, AGENT_A, spawn([AGENT_B], 'completed', AGENT_A));
	// Malformed cycle: the walk terminates and reports some in-cycle node.
	expect(typeof agentRootId(registry, registry[AGENT_A])).toBe('string');
});
