#!/bin/sh
# Builds dist/yacwu-<architecture>.AppImage for the Docker host architecture.
#
# Everything runs in an Ubuntu 20.04 (glibc 2.31) container — see
# scripts/appimage/ — so the resulting AppImage runs on distros at least that
# old. Requires Docker (or podman with the docker CLI shim).
#
# The AppImage bundles the compiled Gleam backend (gleam export
# erlang-shipment), the Erlang runtime, and the built web UI. It still
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

echo "Built AppImage in dist/"
