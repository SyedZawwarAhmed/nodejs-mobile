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

# Patch 1: V8 trap handler — unconditionally disable it.
# The upstream android-patches/ mechanism uses `patch` which fails when the
# file content doesn't exactly match the diff. We apply it directly instead.
echo "  [1/2] V8 trap-handler patch (direct edit — version-agnostic)"
python3 - "$NODEJS_SRC/deps/v8/src/trap-handler/trap-handler.h" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Idempotent: already patched if the block is absent
if '#define V8_TRAP_HANDLER_SUPPORTED false' in content and '#if V8_HOST_ARCH_X64' not in content:
    print("      -> already patched, skipping")
    sys.exit(0)

# Replace the whole conditional block with an unconditional false.
# The block starts at the first architecture-guard comment and ends at #endif.
patched = re.sub(
    r'// X64 on Linux.*?^#endif',
    '#define V8_TRAP_HANDLER_SUPPORTED false',
    content,
    count=1,
    flags=re.DOTALL | re.MULTILINE
)
if patched == content:
    print("      -> WARNING: pattern not found, file may be in unexpected state")
    sys.exit(0)

with open(path, 'w') as f:
    f.write(patched)
print("      -> done")
PYEOF

# Patch 2: node-mobile bridge native module registration (injected at link time)
# No source patch needed — we use node::AddLinkedBinding() from the JNI bridge.
echo "  [2/2] Bridge module: injected via AddLinkedBinding at build time (no patch needed)"

echo "==> All patches applied."
