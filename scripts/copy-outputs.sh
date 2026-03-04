#!/usr/bin/env bash
# copy-outputs.sh — Copy prebuilt libnode.so files into the Android AAR jniLibs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PREBUILT_DIR="$ROOT_DIR/prebuilt"
JNILIBS_DIR="$ROOT_DIR/android/lib/src/main/jniLibs"

ABIS=("arm64-v8a" "armeabi-v7a" "x86_64" "x86")

echo "==> Copying prebuilt binaries to Android jniLibs..."

for ABI in "${ABIS[@]}"; do
  SRC="$PREBUILT_DIR/$ABI/libnode.so"
  DST="$JNILIBS_DIR/$ABI/libnode.so"
  if [ -f "$SRC" ]; then
    mkdir -p "$JNILIBS_DIR/$ABI"
    cp "$SRC" "$DST"
    echo "  -> $DST"
  else
    echo "  SKIP $ABI (not built yet)"
  fi
done

# Copy headers for JNI compilation
if [ -d "$PREBUILT_DIR/include" ]; then
  mkdir -p "$ROOT_DIR/android/lib/src/main/cpp/include"
  cp -r "$PREBUILT_DIR/include/"* "$ROOT_DIR/android/lib/src/main/cpp/include/"
  echo "  -> android/lib/src/main/cpp/include/"
fi

echo "==> Done."
