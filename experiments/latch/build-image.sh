#!/usr/bin/env bash
# Stage a build context from the pinned submodules, apply the documented
# reproduction patches, and build the LATCH analysis image with Apptainer.
#
# The submodule working trees are never modified: sources are exported with
# `git archive` into the build directory and patched there.
#
# Usage: build-image.sh <build-dir> <output.sif> <node-version> <node-sha256>
set -euo pipefail

BUILD_DIR=$1
OUTPUT_SIF=$2
NODE_VERSION=$3
NODE_SHA256=$4

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
LATCH_SRC="$REPO/tools/latch"
NPM_CLI_SRC="$REPO/tools/npm-cli"

LATCH_COMMIT=$(git -C "$LATCH_SRC" rev-parse HEAD)
NPM_CLI_COMMIT=$(git -C "$NPM_CLI_SRC" rev-parse HEAD)

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/cli" "$BUILD_DIR/latch/experiment"

echo "== Exporting npm/cli@$NPM_CLI_COMMIT (base of LATCH's cli/ gitlink)"
git -C "$NPM_CLI_SRC" archive --format=tar HEAD | tar -x -C "$BUILD_DIR/cli"

echo "== Applying LATCH lifecycle hook (patches/npm-cli-lifecycle-strace.patch)"
patch -p1 --forward --directory "$BUILD_DIR/cli" < "$HERE/patches/npm-cli-lifecycle-strace.patch"

echo "== Exporting LATCH@$LATCH_COMMIT analyzer and parser"
git -C "$LATCH_SRC" archive --format=tar HEAD analyzer parser singularity/package.json \
  | tar -x -C "$BUILD_DIR/latch"

echo "== Applying analyzer reproduction patch (patches/latch-analyzer-reproduction.patch)"
patch -p1 --forward --directory "$BUILD_DIR/latch" < "$HERE/patches/latch-analyzer-reproduction.patch"

# Upstream copies singularity/package.json to /package.json unchanged.
mv "$BUILD_DIR/latch/singularity/package.json" "$BUILD_DIR/package.json"
rmdir "$BUILD_DIR/latch/singularity"

cp "$HERE/analyzer-deps/package.json" "$HERE/analyzer-deps/package-lock.json" "$BUILD_DIR/latch/"
cp "$HERE/generate-manifest.js" "$BUILD_DIR/latch/experiment/"
cp "$HERE/container-script-single.js" "$BUILD_DIR/start.js"
cp "$HERE/container-github.def" "$BUILD_DIR/container.def"

echo "== Building $OUTPUT_SIF (Node.js $NODE_VERSION)"
cd "$BUILD_DIR"
# Bootstrap: debootstrap needs root, as upstream's `sudo singularity build`.
# sudo resets the environment, so pass the scratch directory through explicitly.
sudo env ${APPTAINER_TMPDIR:+APPTAINER_TMPDIR="$APPTAINER_TMPDIR"} apptainer build --force \
  --build-arg "NODE_VERSION=$NODE_VERSION" \
  --build-arg "NODE_SHA256=$NODE_SHA256" \
  --build-arg "LATCH_COMMIT=$LATCH_COMMIT" \
  --build-arg "NPM_CLI_COMMIT=$NPM_CLI_COMMIT" \
  "$OUTPUT_SIF" container.def
sudo chown "$(id -u):$(id -g)" "$OUTPUT_SIF"
