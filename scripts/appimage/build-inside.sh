#!/bin/sh
# Runs inside the builder container (see Dockerfile). Expects the repository
# mounted read-only at /src and writes the finished AppImage to /out.
set -eu

ARCH=x86_64
SRC=/src
OUT=/out
WORK=/work
APPDIR="$WORK/AppDir"

echo "==> Copying source"
mkdir -p "$WORK/repo"
(cd "$SRC" && tar -cf - \
    --exclude=./.git \
    --exclude=./node_modules \
    --exclude=./build \
    --exclude=./.svelte-kit \
    --exclude=./server/build \
    --exclude=./test-results \
    --exclude=./dist \
    .) | tar -xf - -C "$WORK/repo"
cd "$WORK/repo"

echo "==> Building web UI"
bun install
bun run build

echo "==> Building backend shipment"
(cd server && gleam export erlang-shipment)

echo "==> Assembling AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/share/yacwu" "$APPDIR/usr/lib" "$APPDIR/usr/erlang"

cp -r server/build/erlang-shipment "$APPDIR/usr/share/yacwu/shipment"
cp -r build "$APPDIR/usr/share/yacwu/build"

# Bundle the Erlang runtime (a release-style tree: bin/, erts-*/, lib/),
# pruned to the applications the server loads.
cp -r /opt/erlang/. "$APPDIR/usr/erlang"
ERL_ROOT="$APPDIR/usr/erlang"
for app in "$ERL_ROOT"/lib/*; do
  case "$(basename "$app" | cut -d- -f1)" in
    kernel | stdlib | crypto | ssl | public_key | asn1 | sasl | runtime_tools) ;;
    *) rm -rf "$app" ;;
  esac
done
rm -rf "$ERL_ROOT"/lib/*/src "$ERL_ROOT"/lib/*/include "$ERL_ROOT"/lib/*/examples \
  "$ERL_ROOT"/misc "$ERL_ROOT"/man "$ERL_ROOT"/doc "$ERL_ROOT"/usr \
  "$ERL_ROOT"/Install \
  "$ERL_ROOT"/erts-*/src "$ERL_ROOT"/erts-*/doc "$ERL_ROOT"/erts-*/man \
  "$ERL_ROOT"/erts-*/include "$ERL_ROOT"/erts-*/lib

# The `erl` wrapper written by `Install -minimal` hardcodes its prefix;
# rewrite ROOTDIR so the runtime is relocatable inside the mounted AppImage.
sed -i 's|^ROOTDIR=.*$|ROOTDIR="$(dirname "$(readlink -f "$0")")/.."|' \
  "$ERL_ROOT/bin/erl"

# Bundle the non-glibc shared libraries the runtime links against (libtinfo
# and friends). glibc itself is deliberately taken from the host — that's why
# this builds on an old distro.
for bin in "$ERL_ROOT"/erts-*/bin/beam.smp "$ERL_ROOT"/erts-*/bin/erl_child_setup \
  "$ERL_ROOT"/erts-*/bin/inet_gethost "$ERL_ROOT"/lib/crypto-*/priv/lib/crypto.so; do
  [ -e "$bin" ] || continue
  ldd "$bin" 2>/dev/null | awk '$3 ~ /^\// {print $3}' | while read -r lib; do
    case "$lib" in
      */libc.so* | */libm.so* | */libdl.so* | */libpthread.so* | \
        */librt.so* | */libutil.so* | */ld-linux*) ;;
      *) cp -n "$lib" "$APPDIR/usr/lib/" ;;
    esac
  done
done

# Desktop metadata appimagetool requires. The icon is drawn with ImageMagick
# primitives (a green prompt chevron on the UI's dark background) so the
# build needs no font or asset files.
cat > "$APPDIR/yacwu.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=yacwu
Comment=Minimalist Codex web UI
Exec=yacwu
Icon=yacwu
Terminal=true
Categories=Development;
EOF
convert -size 256x256 xc:'#0a0e14' \
  -stroke '#3fb950' -strokewidth 16 -fill none \
  -draw "polyline 64,84 120,128 64,172" \
  -draw "line 140,176 200,176" \
  "$APPDIR/yacwu.png"

cp /opt/appimage/AppRun "$APPDIR/AppRun"
chmod +x "$APPDIR/AppRun"

echo "==> Packing AppImage"
mkdir -p "$OUT"
ARCH="$ARCH" appimagetool "$APPDIR" "$OUT/yacwu-$ARCH.AppImage"
chown "${HOST_UID:-0}:${HOST_GID:-0}" "$OUT/yacwu-$ARCH.AppImage" 2>/dev/null || true

echo "==> Done: yacwu-$ARCH.AppImage"
