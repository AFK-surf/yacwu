import { spawn, type ChildProcessByStdio } from 'node:child_process';
import type { Writable, Readable } from 'node:stream';
import readline from 'node:readline';
import { EventEmitter } from 'node:events';
import os from 'node:os';
import type { JsonRpcNotification } from '$lib/protocol';

interface PendingRequest {
	resolve: (value: unknown) => void;
	reject: (reason: unknown) => void;
}

type NotificationListener = (msg: JsonRpcNotification) => void;

/**
 * Singleton manager for a single `codex app-server` process.
 *
 * Multiplexes many threads (sessions) over one stdio JSON-RPC connection.
 * Every codex notification carries `params.threadId`, so the frontend can route
 * events to the right session. There is no database here: codex persists its own
 * sessions on disk and we read them back via `thread/list` / `thread/read`.
 */
class CodexManager {
	private proc: ChildProcessByStdio<Writable, Readable, null> | null = null;
	private rl: readline.Interface | null = null;
	private nextId = 1;
	private pending = new Map<number, PendingRequest>();
	private emitter = new EventEmitter();
	private ready: Promise<unknown> | null = null;

	constructor() {
		this.emitter.setMaxListeners(0);
	}

	start(): Promise<unknown> {
		if (this.ready) return this.ready;

		const cwd = process.env.YACWU_CWD || os.homedir();
		const proc = spawn('codex', ['app-server'], {
			stdio: ['pipe', 'pipe', 'inherit'],
			cwd
		});
		this.proc = proc;

		proc.on('exit', (code) => {
			console.error(`[codex] app-server exited with code ${code}`);
			for (const { reject } of this.pending.values()) {
				reject(new Error('codex app-server exited'));
			}
			this.pending.clear();
			this.proc = null;
			this.rl = null;
			this.ready = null;
		});

		this.rl = readline.createInterface({ input: proc.stdout });
		this.rl.on('line', (line) => this.onLine(line));

		this.ready = (async () => {
			const init = await this.request('initialize', {
				clientInfo: { name: 'yacwu', title: 'yacwu', version: '0.1.0' }
			});
			this.notify('initialized', {});
			return init;
		})();

		return this.ready;
	}

	private onLine(line: string): void {
		let msg: any;
		try {
			msg = JSON.parse(line);
		} catch {
			return;
		}

		// Response to one of our requests.
		if (msg.id !== undefined && (msg.result !== undefined || msg.error !== undefined)) {
			const p = this.pending.get(msg.id);
			if (p) {
				this.pending.delete(msg.id);
				if (msg.error) p.reject(new Error(msg.error.message || 'codex error'));
				else p.resolve(msg.result);
			}
			return;
		}

		// Server-initiated request (has both id and method) — e.g. approvals.
		if (msg.id !== undefined && msg.method) {
			this.handleServerRequest(msg);
			return;
		}

		// Notification.
		if (msg.method) {
			this.emitter.emit('notification', msg as JsonRpcNotification);
		}
	}

	private handleServerRequest(msg: JsonRpcNotification): void {
		// We run codex with approvalPolicy "never", so approvals shouldn't normally
		// be requested. If anything does come through, auto-accept so turns never hang.
		let result: Record<string, unknown> = {};
		if (typeof msg.method === 'string' && msg.method.includes('requestApproval')) {
			result = { decision: 'accept' };
		}
		this.write({ id: msg.id, result });
		// Surface it to clients too so the UI can show what happened.
		this.emitter.emit('notification', msg);
	}

	private write(obj: unknown): void {
		if (!this.proc) throw new Error('codex app-server not running');
		this.proc.stdin.write(JSON.stringify(obj) + '\n');
	}

	request<T = any>(method: string, params: Record<string, unknown> = {}): Promise<T> {
		const id = this.nextId++;
		return new Promise<T>((resolve, reject) => {
			this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
			try {
				this.write({ method, id, params });
			} catch (err) {
				this.pending.delete(id);
				reject(err);
			}
		});
	}

	notify(method: string, params: Record<string, unknown> = {}): void {
		this.write({ method, params });
	}

	/** Subscribe to all codex notifications. Returns an unsubscribe function. */
	subscribe(listener: NotificationListener): () => void {
		this.emitter.on('notification', listener);
		return () => this.emitter.off('notification', listener);
	}
}

// Survive Vite HMR / module reloads in dev by stashing on globalThis.
const g = globalThis as typeof globalThis & { __yacwu_codex?: CodexManager };
export const codex: CodexManager = g.__yacwu_codex ?? (g.__yacwu_codex = new CodexManager());
