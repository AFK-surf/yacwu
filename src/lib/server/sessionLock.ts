import { readdirSync, readlinkSync, readFileSync } from 'node:fs';

/**
 * Detect whether another codex process on this machine has a session's rollout
 * file open. codex keeps an open file descriptor on the rollout `.jsonl` for as
 * long as a thread is loaded (resumed) — even while idle — so scanning open fds
 * for that path tells us if some *other* codex instance is using the session.
 *
 * Linux-only (relies on /proc). On platforms without /proc this degrades to "no
 * detection" (returns an empty holder list) rather than blocking the user.
 */

export interface SessionHolder {
	pid: number;
	command: string;
}

/** Read a process's parent pid from /proc/<pid>/stat, or null if unavailable. */
function parentPid(pid: number): number | null {
	try {
		const stat = readFileSync(`/proc/${pid}/stat`, 'utf8');
		// Format: pid (comm) state ppid ... — comm may contain spaces/parens,
		// so parse after the last ')'.
		const close = stat.lastIndexOf(')');
		const rest = stat.slice(close + 2).split(' ');
		const ppid = Number(rest[1]); // state, ppid, ...
		return Number.isFinite(ppid) ? ppid : null;
	} catch {
		return null;
	}
}

/** Best-effort short command name for a pid (e.g. "codex"). */
function commandOf(pid: number): string {
	try {
		const comm = readFileSync(`/proc/${pid}/comm`, 'utf8').trim();
		if (comm) return comm;
	} catch {
		/* fall through */
	}
	try {
		const parts = readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0').filter(Boolean);
		if (parts.length) {
			const base = parts[0].split('/').pop() || parts[0];
			return base.slice(0, 40);
		}
	} catch {
		/* fall through */
	}
	return `pid ${pid}`;
}

/** All pids in the subtree rooted at `root` (inclusive), built from /proc. */
function processSubtree(root: number): Set<number> {
	const subtree = new Set<number>([root]);
	let pids: number[];
	try {
		pids = readdirSync('/proc')
			.map((n) => Number(n))
			.filter((n) => Number.isInteger(n));
	} catch {
		return subtree;
	}
	const parents = new Map<number, number>();
	for (const pid of pids) {
		const ppid = parentPid(pid);
		if (ppid !== null) parents.set(pid, ppid);
	}
	// Repeatedly absorb any pid whose ancestor chain reaches root.
	let changed = true;
	while (changed) {
		changed = false;
		for (const [pid, ppid] of parents) {
			if (!subtree.has(pid) && subtree.has(ppid)) {
				subtree.add(pid);
				changed = true;
			}
		}
	}
	return subtree;
}

/** Pids (any) that currently hold `targetPath` open. */
function holdersOf(targetPath: string): Set<number> {
	const holders = new Set<number>();
	let pids: string[];
	try {
		pids = readdirSync('/proc');
	} catch {
		return holders; // no /proc — cannot detect
	}
	for (const name of pids) {
		const pid = Number(name);
		if (!Number.isInteger(pid)) continue;
		let fds: string[];
		try {
			fds = readdirSync(`/proc/${pid}/fd`);
		} catch {
			continue; // not ours / gone
		}
		for (const fd of fds) {
			try {
				if (readlinkSync(`/proc/${pid}/fd/${fd}`) === targetPath) {
					holders.add(pid);
					break;
				}
			} catch {
				/* fd vanished */
			}
		}
	}
	return holders;
}

/**
 * Return processes — other than our own app-server's process tree and this
 * server process — that hold the given rollout file open.
 */
export function detectExternalHolders(
	rolloutPath: string,
	ownAppServerPid: number | null
): SessionHolder[] {
	if (!rolloutPath) return [];

	const excluded = new Set<number>([process.pid]);
	if (ownAppServerPid) {
		for (const pid of processSubtree(ownAppServerPid)) excluded.add(pid);
	}

	const result: SessionHolder[] = [];
	for (const pid of holdersOf(rolloutPath)) {
		if (excluded.has(pid)) continue;
		result.push({ pid, command: commandOf(pid) });
	}
	return result;
}
