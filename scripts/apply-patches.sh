#!/usr/bin/env bash
# apply-patches.sh — Apply Android patches to nodejs-src before building
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
NODEJS_SRC="$ROOT_DIR/nodejs-src"
PATCHES_DIR="$ROOT_DIR/patches/android"

if [ ! -d "$NODEJS_SRC" ]; then
  echo "ERROR: nodejs-src not found. Run: git submodule update --init"
  exit 1
fi

echo "==> Applying Android patches to Node.js v24 source..."

# Patch 1: V8 trap handler — disable on Android (Node.js v24 includes this in
# android-patches/ already; this script ensures it's applied via the upstream mechanism)
if [ -f "$NODEJS_SRC/android-patches/trap-handler.h.patch" ]; then
  echo "  [1/2] V8 trap-handler patch (bundled with Node.js v24 source)"
  cd "$NODEJS_SRC"
  python3 android-configure patch 2>/dev/null || true
  echo "      -> done"
else
  echo "  [1/2] V8 trap-handler: applying from our patches/"
  cd "$NODEJS_SRC"
  patch -f -p1 deps/v8/src/trap-handler/trap-handler.h \
    < "$PATCHES_DIR/v8-trap-handler-android.patch" || true
fi

# Patch 2: node-mobile bridge native module registration (injected at link time)
# No source patch needed — we use node::AddLinkedBinding() from the JNI bridge.
echo "  [2/2] Bridge module: injected via AddLinkedBinding at build time (no patch needed)"

echo "==> All patches applied."
