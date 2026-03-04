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

# Configure
cd "$NODEJS_SRC"
echo ""
echo "==> Running android-configure..."
python3 android_configure.py "$NDK_PATH" "$ANDROID_API" "$ARCH"

# Inject --shared into the generated Makefile flags so we build libnode.so
# android_configure.py already ran ./configure; we re-run with --shared
echo ""
echo "==> Re-configuring with --shared flag..."
python3 configure.py \
  --dest-cpu="$(python3 -c "
a='$ARCH'
m={'arm64':'arm64','aarch64':'arm64','arm':'arm','x86':'ia32','x86_64':'x64','x64':'x64'}
print(m.get(a,a))
")" \
  --dest-os=android \
  --openssl-no-asm \
  --cross-compiling \
  --shared \
  --without-inspector \
  --without-intl \
  --ninja

# Build
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
echo ""
echo "==> Building with $JOBS parallel jobs..."
make -j"$JOBS"

# Copy outputs
echo ""
echo "==> Copying outputs..."

# libnode.so location varies by build system
SO_PATH=""
for candidate in \
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
