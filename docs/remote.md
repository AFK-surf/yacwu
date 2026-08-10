# Remote hosts

yacwu can drive `codex app-server` on other machines over SSH, alongside the
local one. Sessions pick their machine at creation time, and every machine's
sessions share the same rail, transcript surface, and event stream.

## How it works

The key property comes from codex itself: `codex app-server --listen
unix://PATH` accepts **WebSocket connections over a Unix socket, with the
`initialize` handshake done per connection**. That is exactly the persistence
model a remote setup needs:

- One long-lived app-server runs detached on the remote machine and owns all
  loaded threads.
- Each yacwu connection — the first one, after an SSH drop, after a yacwu
  restart — is just a new WebSocket connection plus a fresh `initialize`.
- An in-flight turn keeps running server-side while yacwu is disconnected;
  codex keeps persisting to the rollout. yacwu reconciles on reconnect.

So there is no custom remote daemon. Per remote host, yacwu manages three
things (`server/src/yacwu/remote.gleam`):

1. **Bootstrap** — `ssh <host> "exec sh"` runs an idempotent script over
   stdin: if no app-server is alive it starts one with
   `setsid nohup codex app-server --listen unix://~/.cache/yacwu/app-server.sock`
   and reports the pid, remote home, and socket path. Nothing happens when the
   server is already running (even one started weeks earlier).
2. **Forward** — a long-lived `ssh -N -L local.sock:remote.sock <host>`
   child (OpenSSH streamlocal forwarding, no TCP ports exposed anywhere),
   with `ServerAliveInterval` so dead links are noticed.
3. **Attach** — connect to the local socket, perform the WebSocket client
   handshake (`server/src/yacwu/ws.gleam`), and hand the socket to the
   manager actor (`server/src/yacwu/codex.gleam`), which multiplexes the
   JSON-RPC traffic exactly as it does for the local stdio child.

### Host discovery: `~/.ssh/config`, nothing else

yacwu has no host registry and stores nothing on disk. The set of remote
machines is the set of concrete `Host` aliases in `~/.ssh/config` (following
`Include`), re-read on demand. Authentication, usernames, ports, jump hosts —
all of it stays in ssh's hands; yacwu only ever passes the alias to the `ssh`
binary, with `BatchMode=yes` so a host that would prompt fails fast and
visibly instead of hanging a server process.

Pattern aliases (`*`, `?`, `!…`) are skipped, as is anything unsafe to place
in argv or a socket filename.

### Reconnects

On a dropped connection the manager fails in-flight requests, tells the UI
(`yacwu/host/status` on the SSE stream), and reconnects with exponential
backoff (1s doubling to 30s) for as long as it has threads open. After the
fresh `initialize` it **re-resumes every thread it had open** so
notifications flow again — including for a turn that kept running while the
link was down. The frontend re-fetches open transcripts on the `connected`
transition; `thread/read` is the reconciliation source of truth for anything
missed mid-gap.

A yacwu restart is the same story with an empty resume set: sessions come
back via `thread/list` from the still-running remote server.

### Thread routing

Thread ids are only meaningful to their host, and yacwu keeps its no-database
principle: a thread→host routing map is rebuilt at runtime from listings,
creations, and opens (`server/src/yacwu/hosts.gleam`). API calls can pass an
explicit `?host=` hint — the frontend does so wherever it knows the session's
host, and deep links carry the host in the URL (`/s/<id>?host=<name>`), so a
remote session opens correctly even into a freshly started yacwu.

`GET /api/hosts` lists local plus all discovered aliases with their live
connection state, and never connects to anything; a host is only contacted
when the user addresses it (picks it in the create form, opens one of its
sessions).

## Requirements on the remote machine

- `codex` on the PATH of a login shell (common user-level locations like
  `~/.local/bin` are also probed), and configured — the server uses the
  *remote* `$CODEX_HOME` config and credentials. The bootstrap sources
  `~/.profile` before starting the server, so PATH additions and environment
  the provider needs (API-key variables like a custom provider's `env_key`)
  belong there.
- SSH key/agent auth that works non-interactively (`ssh <host>` with no
  prompts). Hosts needing passwords or touch prompts will show a clear error.
- OpenSSH ≥ 6.7 on both sides (Unix-socket forwarding).
- On systemd distributions that set `KillUserProcesses=yes`, run
  `loginctl enable-linger` once on the remote machine so the detached
  app-server survives the last SSH session closing.

The remote server writes its socket, pidfile, and log under
`~/.cache/yacwu/` on the remote machine (`app-server.log` is the first place
to look when a host errors at startup). yacwu never stops a remote server —
outliving yacwu is the point; stop it manually with the pidfile if needed.

## Current limitations (deliberate, staged)

These return clear errors/hide themselves in the UI for remote sessions, and
have protocol-level paths forward (mostly the app-server `fs/*` API):

- the file browser (reads yacwu's local filesystem today);
- image attachments (staged as local temp files codex reads by path);
- codex profiles (files in the *local* `$CODEX_HOME`);
- "session in use elsewhere" detection (scans local `/proc`).

Everything else — messages, streaming, interrupts, goals, models, fast mode,
reviews, shell commands, forks, side conversations, rollback, archive —
works identically on remote sessions.

## Security notes

- All traffic rides SSH; nothing listens on TCP. The remote socket lives in
  a `0700` directory, as does the local forwarded socket.
- yacwu holds no remote credentials; it inherits the user's ssh setup.
- yacwu runs codex with `approvalPolicy: "never"` (the web UI cannot answer
  interactive approvals). With remote hosts that trust now extends to every
  machine you connect: a session on `gpu01` edits files and runs commands on
  `gpu01` unattended, same as the local trust model.
