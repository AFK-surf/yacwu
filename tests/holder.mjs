// Test helper: simulates a *separate* codex instance using a session.
// Spawns its own `codex app-server` and either resumes an existing thread (when
// a thread id is passed as argv[2]) or creates a new one. Either way it keeps
// the rollout file open, prints `READY <id>` to stdout, and stays alive until
// it receives SIGTERM. Used to exercise yacwu's "session in use" detection.
import { spawn } from 'node:child_process';
import readline from 'node:readline';

const resumeId = process.argv[2];

const proc = spawn('codex', ['app-server'], { stdio: ['pipe', 'pipe', 'inherit'] });
const rl = readline.createInterface({ input: proc.stdout });
const send = (m) => proc.stdin.write(JSON.stringify(m) + '\n');

rl.on('line', (line) => {
	let m;
	try {
		m = JSON.parse(line);
	} catch {
		return;
	}
	if (m.id === 1 && m.result?.thread?.id) {
		process.stdout.write(`READY ${m.result.thread.id}\n`);
	}
});

send({ method: 'initialize', id: 0, params: { clientInfo: { name: 'holder', version: '0.1.0' } } });
send({ method: 'initialized', params: {} });
if (resumeId) {
	send({ method: 'thread/resume', id: 1, params: { threadId: resumeId } });
} else {
	send({
		method: 'thread/start',
		id: 1,
		params: { approvalPolicy: 'never', sandbox: 'workspace-write' }
	});
}

const shutdown = () => {
	try {
		proc.kill('SIGKILL');
	} catch {
		/* ignore */
	}
	process.exit(0);
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
