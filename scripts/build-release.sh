#!/bin/sh
# Builds dist/yacwu-<version>.tar.gz: the backend as a single-file escript
# (gleam export escript) plus the web UI bundle and a launcher.
#
# Unlike scripts/build-appimage.sh this uses the local toolchain directly —
# no Docker. The result is portable BEAM bytecode: the target machine needs a
# compatible Erlang/OTP (>= the version pinned in .tool-versions) and the
# codex CLI on PATH, but no Gleam or Bun.
set -eu

cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^version *= *"\(.*\)"/\1/p' server/gleam.toml)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "==> Building web UI"
bun install
bun run build

echo "==> Building backend escript"
(cd server && gleam export escript)

echo "==> Assembling archive"
mkdir -p "$STAGE/yacwu" dist
cp server/yacwu_server "$STAGE/yacwu/yacwu_server"
cp -r build "$STAGE/yacwu/build"
cat > "$STAGE/yacwu/yacwu" <<'EOF'
#!/bin/sh
# Launcher: run the escript, serving the bundled web UI unless YACWU_STATIC
# points elsewhere.
HERE=$(dirname "$(readlink -f "$0")")
export YACWU_STATIC="${YACWU_STATIC:-$HERE/build}"
exec "$HERE/yacwu_server" "$@"
EOF
chmod +x "$STAGE/yacwu/yacwu" "$STAGE/yacwu/yacwu_server"

OUT="dist/yacwu-$VERSION.tar.gz"
tar -czf "$OUT" -C "$STAGE" yacwu
echo "==> Built $OUT"
echo "    run:  tar -xzf $OUT && ./yacwu/yacwu"
echo "    (needs Erlang/OTP and the codex CLI on the target)"
