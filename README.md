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
- 🔌 Single `codex app-server` process multiplexed over one connection; events
  fan out to the browser via Server-Sent Events
- 🗄️ No storage layer — Codex is the source of truth

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

## Other commands

```bash
bun run check        # svelte-check / TypeScript
bun run build        # production build (adapter-node)
bun run start        # run the built server (node build)
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

Threads run with `approvalPolicy: "never"` and a `workspace-write` sandbox so the
web UI never blocks on an interactive approval prompt.

### In-use detection

codex keeps an open file descriptor on a session's rollout `.jsonl` for as long
as the thread is loaded (resumed) — even while idle. Before resuming, the open
endpoint scans `/proc/*/fd` for any process (outside our own app-server's process
tree) holding that path; if one exists it returns `409` and the UI shows a
warning with the offending process so you can cancel or "open anyway". This is
Linux-only; on platforms without `/proc` it degrades to no detection rather than
blocking.
