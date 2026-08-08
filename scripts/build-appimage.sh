#!/bin/sh
# Builds dist/yacwu-x86_64.AppImage.
#
# Everything runs in a Debian bullseye (glibc 2.31) container — see
# scripts/appimage/ — so the resulting AppImage runs on distros at least that
# old. Requires Docker (or podman with the docker CLI shim).
#
# The AppImage bundles the compiled Gleam backend (gleam export
# erlang-shipment), a pruned Erlang runtime, and the built web UI. It still
# needs the `codex` CLI on PATH at runtime.
set -eu

cd "$(dirname "$0")/.."
mkdir -p dist

docker build -t yacwu-appimage-builder scripts/appimage
docker run --rm \
  -v "$PWD:/src:ro" \
  -v "$PWD/dist:/out" \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  yacwu-appimage-builder

echo "Built dist/yacwu-x86_64.AppImage"
