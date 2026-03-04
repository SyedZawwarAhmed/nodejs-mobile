#!/usr/bin/env bash
# setup.sh — Clone Node.js v24.14.0 source into nodejs-src/
# Run this once after cloning the repository.
set -euo pipefail

NODE_VERSION="v24.14.0"
NODE_REPO="https://github.com/nodejs/node.git"
TARGET="$(dirname "$0")/../nodejs-src"

if [ -d "$TARGET/.git" ]; then
  echo "nodejs-src already exists ($(git -C "$TARGET" describe --tags 2>/dev/null || echo 'unknown')). Nothing to do."
  exit 0
fi

echo "==> Cloning Node.js $NODE_VERSION (shallow)..."
git clone --depth 1 --branch "$NODE_VERSION" "$NODE_REPO" "$TARGET"
echo "==> Done. nodejs-src is ready."
