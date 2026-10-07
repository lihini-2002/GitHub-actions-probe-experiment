#!/usr/bin/env bash
# Install one package tarball through LATCH's npm inside the LATCH image.
#
# Mirrors the upstream invocation in tools/latch/singularity/containerWorker.js:
#   singularity run --bind <packages>:/packages,<instances>:/InstancePkgs \
#     -H <home> container.sif <pkg> /dev/shm/Instances/<instance>
# plus a /straces bind, which upstream's container.def asks for. As upstream,
# the host environment is inherited (no --cleanenv / --containall).
#
# Nothing experiment-specific is put into the environment the package sees:
# all parameters are positional arguments to the runscript.
#
# Usage: run-latch-single.sh <latch.sif> <package.tgz> <package-name> \
#          <name@version> <instance> <latch-out-dir> [<probe-out-dir>]
set -euo pipefail

SIF=$(realpath "$1")
TARBALL=$(realpath "$2")
PKG_NAME=$3
PKG_KEY=$4
INSTANCE=$5
LATCH_OUT=$6
PROBE_OUT=${7:-}

INSTANCES=/dev/shm/Instances
WORK_DIR="$INSTANCES/$INSTANCE"
# Probe reports are copied to /dev/shm (already shared with the container)
# instead of adding a bind mount the probe could observe.
COLLECT_DIR="$INSTANCES/$INSTANCE-collect"
HOME_DIR="${RUNNER_TEMP:-/tmp}/latch-home-$INSTANCE"
EMPTY_INSTANCE_PKGS="${RUNNER_TEMP:-/tmp}/latch-instancepkgs-$INSTANCE"

# Resolve output paths now: the apptainer call below runs from $HOME_DIR.
mkdir -p "$LATCH_OUT/straces" "$LATCH_OUT/logs"
LATCH_OUT=$(realpath "$LATCH_OUT")
if [ -n "$PROBE_OUT" ]; then
  mkdir -p "$PROBE_OUT"
  PROBE_OUT=$(realpath "$PROBE_OUT")
fi
for dir in "$WORK_DIR" "$COLLECT_DIR" "$HOME_DIR" "$EMPTY_INSTANCE_PKGS"; do
  if [ -e "$dir" ]; then
    echo "::error::$dir already exists; each instance must start clean"
    exit 1
  fi
done
mkdir -p "$INSTANCES" "$COLLECT_DIR" "$HOME_DIR" "$EMPTY_INSTANCE_PKGS"

echo "Package:      $TARBALL"
echo "strace key:   $PKG_KEY"
echo "Work dir:     $WORK_DIR"
echo "Straces out:  $LATCH_OUT/straces"

# Run from the home dir so Apptainer's automatic CWD bind adds no new mount.
cd "$HOME_DIR"
set +e
apptainer run \
  --bind "$LATCH_OUT/straces:/straces" \
  --bind "$(dirname "$TARBALL"):/packages" \
  --bind "$EMPTY_INSTANCE_PKGS:/InstancePkgs" \
  -H "$HOME_DIR" \
  "$SIF" \
  "/packages/$(basename "$TARBALL")" "$WORK_DIR" "$PKG_NAME" "$PKG_KEY" "$COLLECT_DIR" \
  2>&1 | tee "$LATCH_OUT/logs/latch-run.log"
status=${PIPESTATUS[0]}
set -e

# Debugging material: npm logs, the instance package.json/lock, and the
# lifecycle exit-status markers are already in straces/.
if [ -d "$HOME_DIR/.npm/_logs" ]; then
  cp -r "$HOME_DIR/.npm/_logs" "$LATCH_OUT/logs/npm-logs"
fi
for f in package.json package-lock.json; do
  [ -f "$WORK_DIR/$f" ] && cp "$WORK_DIR/$f" "$LATCH_OUT/logs/instance-$f"
done
echo "$WORK_DIR/node_modules/$PKG_NAME" > "$LATCH_OUT/logs/lifecycle-cwd.txt"

if [ -n "$PROBE_OUT" ]; then
  find "$COLLECT_DIR" -maxdepth 1 -type f -name 'install-*.json' -exec cp {} "$PROBE_OUT/" \;
fi

echo "Collected:"
find "$LATCH_OUT" ${PROBE_OUT:+"$PROBE_OUT"} -type f | sort

if [ "$status" -ne 0 ]; then
  echo "::error::LATCH npm install of $PKG_KEY exited with status $status (see $LATCH_OUT/logs/latch-run.log and straces/*_FAILED)"
fi
exit "$status"
