# yacwu

**Yet Another Codex Web UI** — a minimalist, CLI-style web front-end for
[Codex](https://developers.openai.com/codex), with a **Gleam (BEAM/OTP)**
backend and a **Svelte** SPA front-end.

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
| `/model` | show the current model, reasoning effort, and available choices |
| `/model <model> [effort]` | change the model and optional reasoning effort (`--effort <effort>` changes effort only) |
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

- [Gleam](https://gleam.run) ≥ 1.18 with Erlang/OTP ≥ 27 (and `rebar3` on
  `PATH` for compiling one transitive Erlang dependency)
- [Bun](https://bun.sh) ≥ 1.3 (builds the web UI)
- [`codex`](https://developers.openai.com/codex) CLI on `PATH`, already
  authenticated (`codex login`)

## Run

```bash
bun install
bun run build        # build the web UI into ./build
bun run start        # serve UI + API on http://127.0.0.1:3000
```

`bun run start` runs the Gleam server (`server/`), which serves the static UI
build, the REST/SSE API, and spawns/manages the single `codex app-server`
process. The listening address is configurable:

```bash
cd server
gleam run -- 0.0.0.0:8080            # positional host:port
gleam run -- --host 0.0.0.0 --port 8080
gleam run -- --unix /run/yacwu.sock  # Unix domain socket instead of TCP
gleam run -- --help
```

The server accepts `-H/--host`, `-p/--port`, a positional `host:port`, or
`--unix <path>` (CLI flags override the `HOST`/`PORT` env vars). `YACWU_CWD`
selects the working directory for new sessions; `YACWU_STATIC` points at the
web UI build directory (default `./build`, relative to where the server runs —
the `bun run` scripts set it for you). Set `YACWU_DEBUG=1` for a per-request
timing log on stderr.

For a deployable artifact, `cd server && gleam export erlang-shipment`
produces a self-contained BEAM release (needs only Erlang on the target), and
`bun run build` supplies the static `build/` directory to serve next to it.

## AppImage

```bash
./scripts/build-appimage.sh   # produces dist/yacwu-x86_64.AppImage
```

Requires Docker (or podman with the docker CLI shim). The whole build runs in
an Ubuntu 20.04 (glibc 2.31) container so the resulting AppImage works on
distros at least that old: it pulls the prebuilt Erlang/OTP for that distro
from hex.pm's build service (the same builds `erlef/setup-beam` uses), exports
the backend with `gleam export erlang-shipment`, and bundles the pruned Erlang
runtime, the web UI build, and the non-glibc shared libraries the runtime
needs (libssl, libtinfo, …).

```bash
./dist/yacwu-x86_64.AppImage --help
./dist/yacwu-x86_64.AppImage 0.0.0.0:8080
```

The AppImage accepts the same flags/env as the server. It still needs the
`codex` CLI on `PATH` at runtime (and `libfuse2`, like any AppImage — or run
it with `--appimage-extract-and-run`).

## Develop

```bash
bun install
bun run dev:server   # Gleam API backend on http://127.0.0.1:3000
bun run dev          # Vite dev server on http://127.0.0.1:5173 (proxies /api)
```

The front-end dev server proxies `/api/*` (including the SSE stream) to the
backend, so edit Svelte code with hot reload while the Gleam server runs
unchanged. Set `YACWU_API` to proxy to a backend on a different address.

## Forward auth

yacwu has no auth of its own; put it behind a reverse proxy that authenticates
users and injects a `Remote-User` header (Authelia, Traefik forward-auth,
oauth2-proxy, …). Pass an allowlist to require that header:

```bash
cd server
gleam run -- --remote-user alice,bob  # or: YACWU_REMOTE_USERS=alice,bob
```

When enabled, every request must carry `Remote-User: <user>` matching one of the
listed users — otherwise it's rejected (`401` if the header is missing, `403` if
the user isn't allowed). This is enforced for pages, the API, and static assets.
When unset, auth is disabled.

## Other commands

```bash
bun run check        # svelte-check / TypeScript (front-end)
bun run test:unit    # front-end unit tests (bun test)
bun run test:server  # backend unit tests (gleeunit)
bunx playwright test # end-to-end verification (builds the UI, runs the Gleam server, drives the live app)
```

## Architecture

```
browser ──HTTP/SSE──> Gleam server (mist, server/)
                         │  server/src/yacwu/codex.gleam  (JSON-RPC manager actor)
                         └──stdio──> codex app-server ──> Codex sessions on disk
```

- `server/src/yacwu/codex.gleam` — OTP actor owning the single
  `codex app-server` port: correlates request/response ids, broadcasts
  notifications to SSE subscribers, respawns the process if it exits.
- `server/src/yacwu/router.gleam` — thin REST/SSE endpoints over the protocol
  (`/api/threads`, `/api/threads/[id]/open|message|interrupt`, `/api/events`),
  plus static serving of the built SPA with an `index.html` fallback.
- `server/src/yacwu/session_lock.gleam` — detects whether another codex
  process has a session's rollout file open before we resume it.
- `server/src/yacwu/model_state.gleam` — per-thread model/effort overrides and
  the model catalog.
- `src/routes/+layout.svelte` — the terminal-style UI; routes streamed events
  to the right session by `threadId`.

The backend is pure Gleam: interop with the VM (spawning the codex port,
`/proc` symlink reads, Unix sockets) goes through typed `@external` bindings
to Erlang built-ins — no Erlang source files, no NIFs.

Threads run in "yolo" mode — `approvalPolicy: "never"` and
`sandbox: "danger-full-access"` — so the web UI never blocks on an interactive
approval prompt and commands run with full access.

### In-use detection

codex keeps an open file descriptor on a session's rollout `.jsonl` for as long
as the thread is loaded (resumed) — even while idle. Before resuming, the open
endpoint checks whether any process (outside our own app-server's process tree)
holds that path open; if one exists it returns `409` and the UI shows a warning
with the offending process so you can cancel or "open anyway".

The scan is platform-specific: on Linux it reads `/proc/*/fd` symlinks; on
OpenBSD (which has no `/proc`) it runs `fstat(1)` on the rollout file and
`ps` for the process tree. Other platforms degrade to no detection rather
than blocking.

### Unix socket listening

`--unix <path>` accepts connections on a Unix domain socket and relays them
byte-for-byte to the HTTP listener bound on a loopback ephemeral port (mist
itself only speaks TCP). HTTP, SSE, and forward-auth headers pass through
unchanged.

## License

MIT
