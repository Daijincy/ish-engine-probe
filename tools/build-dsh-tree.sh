#!/usr/bin/env bash
# Builds the DSH node_modules tree for the guest (Alpine aarch64) on the host.
#
# The guest kernel interprets every instruction, so `npm install` inside the
# guest is not practical. Instead the dependency tree is resolved on the host
# with npm's platform flags, and only JavaScript plus musl/arm64 native
# artifacts are copied into the image.
#
# Usage: tools/build-dsh-tree.sh <output-dir>
#
# Requires Node >= 24.9 in PATH (DSH refuses older runtimes).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:?usage: build-dsh-tree.sh <output-dir>}"
REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
NODE_MINOR="$(node -p 'process.versions.node.split(".")[1]')"
if [ "$NODE_MAJOR" -lt 24 ] || { [ "$NODE_MAJOR" -eq 24 ] && [ "$NODE_MINOR" -lt 9 ]; }; then
    echo "error: Node >= 24.9 is required (found $(node -v))" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$HERE/dsh-lock/package.json" "$HERE/dsh-lock/package-lock.json" "$WORK/"
(
    cd "$WORK"
    # --ignore-scripts keeps node-pty from trying to compile on the host. The
    # only native module the web profile loads lazily is node-pty (terminal),
    # which is not needed to serve the UI.
    npm ci \
        --os=linux --cpu=arm64 --libc=musl \
        --ignore-scripts --no-audit --no-fund \
        --registry="$REGISTRY"
)

rm -rf "$OUT"
mkdir -p "$OUT"
mv "$WORK/node_modules" "$OUT/node_modules"

# Source maps and type declarations are never read at runtime.
find "$OUT/node_modules" -name '*.map' -delete
find "$OUT/node_modules" -name '*.d.ts' -delete
find "$OUT/node_modules" -name '*.d.mts' -delete
find "$OUT/node_modules" -name '*.d.cts' -delete
find "$OUT/node_modules" -type d -name 'test' -prune -exec rm -rf {} + 2>/dev/null || true
find "$OUT/node_modules" -type d -name '__tests__' -prune -exec rm -rf {} + 2>/dev/null || true

# Keep only artifacts that can load on the guest.
rm -rf "$OUT/node_modules"/@img/sharp-linux-arm64 \
       "$OUT/node_modules"/@img/sharp-libvips-linux-arm64 \
       "$OUT/node_modules"/@koromix/koffi-linux-arm64/linux_arm64 \
       "$OUT/node_modules"/node-pty/prebuilds/darwin-* \
       "$OUT/node_modules"/node-pty/prebuilds/win32-* \
       "$OUT/node_modules"/node-pty/prebuilds/linux-x64 2>/dev/null || true

test -f "$OUT/node_modules/@deepseek-ai/dsh/lib/bin.js" || {
    echo "error: @deepseek-ai/dsh is missing from the tree" >&2
    exit 1
}
test -f "$OUT/node_modules/@koromix/koffi-linux-arm64/musl_arm64/koffi.node" || {
    echo "error: koffi musl arm64 binary is missing" >&2
    exit 1
}

PACKAGES="$(find "$OUT/node_modules" -name package.json -not -path '*/node_modules/*/node_modules/*' | wc -l | tr -d ' ')"
echo "dsh tree: $PACKAGES package manifests, $(du -sh "$OUT/node_modules" | cut -f1)"
