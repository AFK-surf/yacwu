# yacwu

**Yet Another Codex Web UI** — a minimalist, CLI-style web front-end for
[Codex](https://developers.openai.com/codex), built with **Bun + SvelteKit + TypeScript**.

It talks to Codex over the [app-server protocol](docs/codex-app-server.md)
(JSON-RPC 2.0 over stdio) and keeps **no database of its own** — multi-session
state lives entirely in Codex's own persistent sessions, read back via
`thread/list` / `thread/read` and continued via `thread/resume`.

## Features

- 🖥️ Minimalist CLI/terminal aesthetic, dark background
- 🧵 Multi-session: list, create (in a chosen working directory), switch, and resume Codex threads
- 🔒 In-use detection: warns before opening a session another codex instance
  already has loaded (so two processes don't corrupt one conversation)
- ⚡ Live streaming of agent messages, reasoning, command runs, file changes & plans
- ⌨️ Slash commands mirroring the Codex TUI (see below)
- 🔌 Single `codex app-server` process multiplexed over one connection; events
  fan out to the browser via Server-Sent Events
- 🗄️ No storage layer — Codex is the source of truth

## Slash commands

Type these in the composer (anything not starting with `/` is a normal model turn):

| command | action |
| --- | --- |
| `/status` | show account, rate limits & session info |
| `/goal <objective>` | set the thread goal (`--budget N` to add a token budget) |
| `/goal` / `/goal clear` | show / clear the current goal |
| `/compact` | compact conversation history |
| `/review [notes]` | review uncommitted changes (or run a custom review) |
| `/shell <command>` | run a user-initiated shell command in the thread |
| `/rollback [turns]` | roll back the last N turns (default 1) |
| `/fork` | branch this thread into a new session |
| `/archive` | archive this session |
| `/help` | list the commands |

## Requirements

- [Bun](https://bun.sh) ≥ 1.3
- [`codex`](https://developers.openai.com/codex) CLI on `PATH`, already
  authenticated (`codex login`)

## Develop

```bash
bun install
bun run dev          # http://127.0.0.1:5173
```

Optionally set `YACWU_CWD` to choose the working directory Codex runs in
(defaults to your home directory).

## Single-binary distribution

```bash
bun run build:bin    # produces a self-contained ./yacwu executable
./yacwu              # listens on 127.0.0.1:3000 by default
./yacwu 0.0.0.0:8080 # or specify the listening address
./yacwu --host 0.0.0.0 --port 8080
./yacwu --unix /run/yacwu.sock
./yacwu --help
```

The binary accepts `-H/--host`, `-p/--port`, a positional `host:port`, or
`--unix <path>` for a Unix socket (CLI flags override the `HOST`/`PORT` env
vars). `YACWU_CWD` still selects the working directory for new sessions.

`build:bin` builds with the Bun SvelteKit adapter, embeds the static client
assets into the executable (`bun build --compile`), and emits a single `yacwu`
binary — no Node, no `node_modules`, no separate assets. It still needs the
`codex` CLI on `PATH` at runtime.

## Forward auth

yacwu has no auth of its own; put it behind a reverse proxy that authenticates
users and injects a `Remote-User` header (Authelia, Traefik forward-auth,
oauth2-proxy, …). Pass an allowlist to require that header:

## License

MIT

```bash
./yacwu --remote-user alice,bob       # or: YACWU_REMOTE_USERS=alice,bob ./yacwu
```

When enabled, every request must carry `Remote-User: <user>` matching one of the
listed users — otherwise it's rejected (`401` if the header is missing, `403` if
the user isn't allowed). This is enforced for pages, the API, and static assets.
When unset, auth is disabled. The same `YACWU_REMOTE_USERS` env var enables it
for `bun run dev` / `bun run start`.

## Other commands

```bash
bun run check        # svelte-check / TypeScript
bun run build        # production build (svelte-adapter-bun)
bun run start        # run the built server (bun ./build/index.js)
bunx playwright test # end-to-end verification (drives the live app)
```

## Architecture

```
browser ──HTTP/SSE──> SvelteKit (Bun)
                         │  src/lib/server/codex.ts  (JSON-RPC manager, singleton)
                         └──stdio──> codex app-server ──> Codex sessions on disk
```

- `src/lib/server/codex.ts` — spawns and manages the single `codex app-server`
  process, correlates request/response ids, and broadcasts notifications.
- `src/routes/api/*` — thin REST/SSE endpoints over the protocol
  (`/api/threads`, `/api/threads/[id]/open|message|interrupt`, `/api/events`).
- `src/routes/+page.svelte` — the terminal-style UI; routes streamed events to
  the right session by `threadId`.
- `src/lib/server/sessionLock.ts` — detects whether another codex process has a
  session's rollout file open before we resume it.

Threads run in "yolo" mode — `approvalPolicy: "never"` and
`sandbox: "danger-full-access"` — so the web UI never blocks on an interactive
approval prompt and commands run with full access.

### In-use detection

codex keeps an open file descriptor on a session's rollout `.jsonl` for as long
as the thread is loaded (resumed) — even while idle. Before resuming, the open
endpoint scans `/proc/*/fd` for any process (outside our own app-server's process
tree) holding that path; if one exists it returns `409` and the UI shows a
warning with the offending process so you can cancel or "open anyway". This is
Linux-only; on platforms without `/proc` it degrades to no detection rather than
blocking.
