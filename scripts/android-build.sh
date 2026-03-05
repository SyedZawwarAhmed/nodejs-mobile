#!/usr/bin/env bash
# android-build.sh — Cross-compile Node.js v24 for Android
#
# Usage:
#   ./scripts/android-build.sh <NDK_PATH> [ARCH]
#
# Arguments:
#   NDK_PATH  Path to Android NDK root (e.g. ~/Android/Sdk/ndk/27.1.12297006)
#   ARCH      Target architecture: arm64 (default), arm, x86, x86_64
#
# Requirements:
#   - Android NDK r27.1 or newer
#   - Python 3.9+
#   - make, ninja
#
# Output:
#   prebuilt/<ARCH>/libnode.so
#   prebuilt/include/  (Node.js headers)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
NODEJS_SRC="$ROOT_DIR/nodejs-src"

NDK_PATH="${1:?Usage: $0 <NDK_PATH> [ARCH]}"
ARCH="${2:-arm64}"
ANDROID_API=24   # Android 7.0 minimum — required for Node.js v24

# Map arch to ABI folder name
case "$ARCH" in
  arm64|aarch64) ABI="arm64-v8a" ;;
  arm)           ABI="armeabi-v7a" ;;
  x86)           ABI="x86" ;;
  x86_64|x64)   ABI="x86_64" ;;
  *)
    echo "ERROR: Unknown arch '$ARCH'. Use: arm64, arm, x86, x86_64"
    exit 1
    ;;
esac

PREBUILT_DIR="$ROOT_DIR/prebuilt/$ABI"
mkdir -p "$PREBUILT_DIR"

echo "======================================="
echo " Building Node.js v24 for Android"
echo " NDK:  $NDK_PATH"
echo " Arch: $ARCH ($ABI)"
echo " API:  $ANDROID_API"
echo "======================================="

# Apply patches
"$SCRIPT_DIR/apply-patches.sh"

# Set up Android toolchain environment (mirrors what android_configure.py does)
TOOLCHAIN_PATH="$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64"
case "$ARCH" in
  arm64|aarch64) DEST_CPU="arm64"; TOOLCHAIN_PREFIX="aarch64-linux-android" ;;
  arm)           DEST_CPU="arm";   TOOLCHAIN_PREFIX="armv7a-linux-androideabi" ;;
  x86)           DEST_CPU="ia32";  TOOLCHAIN_PREFIX="i686-linux-android" ;;
  x86_64|x64)   DEST_CPU="x64";   TOOLCHAIN_PREFIX="x86_64-linux-android" ;;
esac
export PATH="$PATH:$TOOLCHAIN_PATH/bin"
export CC="$TOOLCHAIN_PATH/bin/${TOOLCHAIN_PREFIX}${ANDROID_API}-clang"
export CXX="$TOOLCHAIN_PATH/bin/${TOOLCHAIN_PREFIX}${ANDROID_API}-clang++"
# Host tools run on the build machine — use the system's native compiler, not the NDK cross-compiler
export CC_host="${CC_host:-$(which clang || which gcc || which cc)}"
export CXX_host="${CXX_host:-$(which clang++ || which g++ || which c++)}"
export GYP_DEFINES="target_arch=$DEST_CPU v8_target_arch=$DEST_CPU android_target_arch=$DEST_CPU host_os=linux OS=android android_ndk_path=$NDK_PATH"

# Clean stale build artifacts to avoid conflicting ninja rules
cd "$NODEJS_SRC"
if [ -d "out" ]; then
  echo ""
  echo "==> Cleaning stale build artifacts..."
  rm -rf out/
fi

echo ""
echo "==> Configuring with Android toolchain and --shared flag..."
./configure \
  --dest-cpu="$DEST_CPU" \
  --dest-os=android \
  --openssl-no-asm \
  --cross-compiling \
  --shared \
  --without-inspector \
  --without-intl \
  --ninja

# Fix GYP cross-compilation bug: when cross-compiling, both the host and target
# toolchains generate files into the same gen/ directory, causing ninja
# "multiple rules" errors. Strip all 'build gen/...' blocks from host ninja
# files — the target toolchain will build those files authoritatively.
HOST_NINJA_DIR="out/Release/obj.host"
if [ -d "$HOST_NINJA_DIR" ]; then
  echo ""
  echo "==> Patching host ninja files to fix duplicate gen/ rules..."
  python3 - "$HOST_NINJA_DIR" <<'PYEOF'
import sys, os, glob

host_dir = sys.argv[1]
patched = 0

for path in glob.glob(os.path.join(host_dir, '**', '*.ninja'), recursive=True):
    with open(path) as f:
        lines = f.readlines()

    # Resolve line continuations to find which build blocks target gen/
    # A ninja build block starts with 'build' and ends at the first line
    # that does NOT end with ' $'.
    # We need to skip any build block whose first output path is under gen/.

    result = []
    i = 0
    changed = False

    while i < len(lines):
        line = lines[i]
        stripped = line.rstrip('\n')

        # Detect start of a build block (may use line continuation)
        if stripped == 'build $' or stripped.startswith('build gen/') or stripped.startswith('build\t'):
            # Collect the full block (all continuation lines)
            block = [line]
            j = i + 1
            while stripped.endswith('$') and j < len(lines):
                stripped = lines[j].rstrip('\n')
                block.append(lines[j])
                j += 1

            # Check if any output in this block is under gen/
            # Outputs appear before the first ':' in the build statement.
            outputs_gen = False
            past_colon = False
            for bline in block:
                bstripped = bline.strip().rstrip(' $')
                if past_colon:
                    break
                if ':' in bstripped:
                    past_colon = True
                # Match 'gen/...' directly or as part of 'build gen/...'
                if bstripped.startswith('gen/') or bstripped.startswith('build gen/'):
                    outputs_gen = True
                    break

            if outputs_gen:
                changed = True
                i = j  # skip the whole block
                continue
            else:
                result.extend(block)
                i = j
                continue

        result.append(line)
        i += 1

    if changed:
        with open(path, 'w') as f:
            f.writelines(result)
        patched += 1

print(f"      -> patched {patched} host ninja file(s)")
PYEOF

  # Also add -latomic to host link targets that use __atomic builtins
  # (needed for mksnapshot and similar host tools on Linux with clang)
  python3 - "$HOST_NINJA_DIR" <<'PYEOF'
import sys, os, glob

host_dir = sys.argv[1]
patched = 0
for path in glob.glob(os.path.join(host_dir, '**', '*.ninja'), recursive=True):
    with open(path) as f:
        content = f.read()
    if 'libs = ' in content and '-latomic' not in content:
        new_content = content.replace('libs = -ldl', 'libs = -ldl -latomic')
        if new_content != content:
            with open(path, 'w') as f:
                f.write(new_content)
            patched += 1

print(f"      -> added -latomic to {patched} host ninja file(s)")
PYEOF
fi

# Build
JOBS=$(nproc 2>/dev/null || echo 4)
echo ""
echo "==> Building with $JOBS parallel jobs..."
ninja -C out/Release -j"$JOBS" libnode

# Copy outputs
echo ""
echo "==> Copying outputs..."

# libnode.so location varies by build system
SO_PATH=""
for candidate in \
    "out/Release/lib/libnode.so" \
    "out/Release/lib.target/libnode.so" \
    "out/Release/libnode.so" \
    "out/Release/obj.target/node/libnode.so"
do
  if [ -f "$NODEJS_SRC/$candidate" ]; then
    SO_PATH="$NODEJS_SRC/$candidate"
    break
  fi
done

if [ -z "$SO_PATH" ]; then
  echo "ERROR: libnode.so not found after build. Check out/ directory:"
  find "$NODEJS_SRC/out" -name "*.so" 2>/dev/null | head -10
  exit 1
fi

cp "$SO_PATH" "$PREBUILT_DIR/libnode.so"
echo "  -> $PREBUILT_DIR/libnode.so"

# Copy headers (only needed once, same for all ABIs)
INCLUDE_DIR="$ROOT_DIR/prebuilt/include"
if [ ! -d "$INCLUDE_DIR" ]; then
  mkdir -p "$INCLUDE_DIR"
  cp -r "$NODEJS_SRC/out/Release/obj.target/include/node" "$INCLUDE_DIR/" 2>/dev/null || \
  cp -r "$NODEJS_SRC/src/node.h" "$INCLUDE_DIR/" 2>/dev/null || \
  cp -r "$NODEJS_SRC/include/node" "$INCLUDE_DIR/" 2>/dev/null || true
  echo "  -> $INCLUDE_DIR/"
fi

echo ""
echo "==> Build complete: $PREBUILT_DIR/libnode.so"
echo "    Size: $(du -sh "$PREBUILT_DIR/libnode.so" | cut -f1)"
