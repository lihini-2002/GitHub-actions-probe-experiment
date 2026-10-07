#!/usr/bin/env bash
# Install the probe tarball with `packj sandbox` and collect Packj's output.
#
# Upstream flow (packj/sandbox/main.py):
#   1. build a rules profile from ~/.packj.yaml (sandbox.rules) plus DNS servers;
#   2. run, with LD_PRELOAD=libsbox.so, SANDBOX_ROOT and SANDBOX_RULES set,
#        <sandbox>/strace -fc --quiet=attach,personality -o <dir>/trace_*.log npm install <args>
#      writes go to a copy-on-write layer <dir>/root_*, events to <dir>/root_*.csv;
#   3. print the network/filesystem review and ask
#      "[C]ommit all changes, [Q|q]uit & discard changes, [L|l]ist details";
#   4. copy new files to the host on C, then delete root_* either way.
#
# The prompt is answered through a FIFO. Before answering, the copy-on-write
# layer is snapshotted, because Packj deletes it afterwards and it holds what
# the install (and the probe) wrote inside the sandbox. The answer is C, the
# step upstream calls "actually install the package". Packj's policy file is
# upstream's .packj.yaml, unchanged.
#
# Packj runs from an empty working directory, which is also npm's project
# root and the "." of the fs allow rule. The tarball is staged in /tmp, which
# the default policy allows; $RUNNER_TEMP is under ~/, which it hides.
#
# Usage: run-packj-sandbox.sh <packj-build-dir> <node-bin-dir> <package.tgz> <out-dir>
set -euo pipefail

BUILD=$(realpath "$1")
NODE_BIN=$(realpath "$2")
TARBALL=$(realpath "$3")
OUT=$4

PKG_NAME=npm-probing-package
STAGE=/tmp/packj-sandbox-input
WORK="${RUNNER_TEMP:-/tmp}/packj-sandbox-work"
CONTROL="${RUNNER_TEMP:-/tmp}/packj-sandbox-control"
MENU='[C]ommit all changes, [Q|q]uit & discard changes, [L|l]ist details:'
TIMEOUT=1500

mkdir -p "$OUT/probe" "$OUT/packj/activity" "$OUT/packj/policy" "$OUT/packj/logs"
OUT=$(realpath "$OUT")
LOGS="$OUT/packj/logs"
LOG="$OUT/packj/sandbox.log"

for dir in "$STAGE" "$WORK" "$CONTROL"; do
  if [ -e "$dir" ]; then
    echo "::error::$dir already exists; each run must start clean"
    exit 1
  fi
done
if ls -d /tmp/packj_sandbox_* >/dev/null 2>&1; then
  echo "::error::A /tmp/packj_sandbox_* directory already exists; each run must start clean"
  exit 1
fi
mkdir -p "$STAGE" "$WORK" "$CONTROL"

INPUT="$STAGE/$(basename "$TARBALL")"
cp "$TARBALL" "$INPUT"
# The policy Packj loads: main.py looks for .packj.yaml in its working
# directory (empty) and then in ~.
cp "$HOME/.packj.yaml" "$OUT/packj/policy/packj.yaml"

echo "Package:   $INPUT"
echo "Work dir:  $WORK"
echo "Node:      $NODE_BIN/node ($("$NODE_BIN/node" --version))"
echo "Command:   python3 main.py sandbox npm install $INPUT"

mkfifo "$CONTROL/stdin"
# Held open read-write so Packj's stdin never sees EOF before the answer.
exec 3<>"$CONTROL/stdin"

cd "$WORK"
PATH="$NODE_BIN:$PATH" "$BUILD/venv/bin/python" "$BUILD/packj/main.py" \
  sandbox npm install "$INPUT" \
  <"$CONTROL/stdin" >"$LOG" 2>&1 &
pid=$!
cd - >/dev/null
tail -n +1 -f --pid="$pid" "$LOG" &
tail_pid=$!

menu_reached=false
timed_out=false
waited=0
while kill -0 "$pid" 2>/dev/null; do
  if grep -qF "$MENU" "$LOG"; then
    menu_reached=true
    break
  fi
  if [ "$waited" -ge "$TIMEOUT" ]; then
    timed_out=true
    echo "::error::Packj sandbox did not finish within ${TIMEOUT}s"
    kill "$pid" 2>/dev/null || true
    break
  fi
  sleep 2
  waited=$((waited + 2))
done

sandbox_dir=$(ls -d /tmp/packj_sandbox_* 2>/dev/null | head -1 || true)
sandbox_root=""
snapshot() {
  [ -n "$sandbox_dir" ] && [ -d "$sandbox_dir" ] || return 0
  ls -laR "$sandbox_dir" > "$LOGS/sandbox-dir-listing.txt" 2>&1 || true
  find "$sandbox_dir" -maxdepth 1 -type f -name 'root_*.csv' -exec cp {} "$OUT/packj/activity/" \;
  find "$sandbox_dir" -maxdepth 1 -type f -name 'trace_*.log' -exec cp {} "$OUT/packj/activity/" \;
  find "$sandbox_dir" -maxdepth 1 -type f -name 'rules_*.profile' -exec cp {} "$OUT/packj/policy/" \;
  sandbox_root=$(find "$sandbox_dir" -maxdepth 1 -type d -name 'root_*' | head -1)
  if [ -n "$sandbox_root" ]; then
    (cd "$sandbox_root" && find . \( -type f -o -type l \) -printf '%s\t%p\n' | sort -k2) \
      > "$OUT/packj/activity/sandbox-root-files.txt"
    tar -C "$sandbox_dir" -czf "$OUT/packj/activity/sandbox-root.tar.gz" "$(basename "$sandbox_root")"
    # What the install wrote inside the sandbox layer, at its sandboxed path.
    layer_pkg="$sandbox_root$WORK/node_modules/$PKG_NAME"
    for dir in "$layer_pkg/results" "$sandbox_root/tmp/npm-probing-package-results"; do
      if ls "$dir"/install-*.json >/dev/null 2>&1; then
        cp "$dir"/install-*.json "$OUT/probe/"
        echo "$dir" > "$LOGS/probe-report-source.txt"
        break
      fi
    done
    # A report that was started but never renamed into place.
    if ls "$layer_pkg"/results/install-*.json.tmp >/dev/null 2>&1; then
      mkdir -p "$OUT/probe/partial"
      cp "$layer_pkg"/results/install-*.json.tmp "$OUT/probe/partial/"
    fi
    if [ -d "$sandbox_root$HOME/.npm/_logs" ]; then
      mkdir -p "$LOGS/npm-logs"
      cp "$sandbox_root$HOME/.npm/_logs"/* "$LOGS/npm-logs/" 2>/dev/null || true
    fi
    for f in package.json package-lock.json; do
      [ -f "$sandbox_root$WORK/$f" ] && cp "$sandbox_root$WORK/$f" "$LOGS/npm-work-$f"
    done
  fi
  return 0
}

answer=""
if [ "$menu_reached" = true ]; then
  snapshot
  answer=C
  printf 'C\n' >&3
fi

set +e
wait "$pid"
status=$?
set -e
exec 3>&-
wait "$tail_pid" 2>/dev/null || true
echo "$status" > "$LOGS/packj-exit-status.txt"
echo
echo "Packj exit status: $status"

# Without a review (e.g. npm failed), Packj exits before deleting the layer.
[ "$menu_reached" = true ] || snapshot

# After C, Packj copied new files to the host.
committed_report=""
if ls "$WORK/node_modules/$PKG_NAME/results"/install-*.json >/dev/null 2>&1; then
  committed_report=$(ls "$WORK/node_modules/$PKG_NAME/results"/install-*.json | head -1)
fi

jq -n \
  --arg input "$INPUT" \
  --arg work_dir "$WORK" \
  --arg node_bin "$NODE_BIN" \
  --arg sandbox_dir "$sandbox_dir" \
  --arg sandbox_root "$sandbox_root" \
  --argjson menu_reached "$menu_reached" \
  --argjson timed_out "$timed_out" \
  --arg answer "$answer" \
  --arg probe_report_source "$(cat "$LOGS/probe-report-source.txt" 2>/dev/null)" \
  --arg committed_report "$committed_report" \
  --argjson packj_exit_status "$status" \
  '{input: $input, work_dir: $work_dir, node_bin: $node_bin,
    sandbox_dir: $sandbox_dir, sandbox_root: $sandbox_root,
    review_menu_reached: $menu_reached, timed_out: $timed_out, review_answer: $answer,
    probe_report_source_dir: $probe_report_source,
    committed_probe_report: $committed_report,
    packj_exit_status: $packj_exit_status}' > "$LOGS/run-paths.json"
cat "$LOGS/run-paths.json"

echo "Collected:"
find "$OUT/probe" "$OUT/packj" -type f | sort

# A non-zero status can be Packj doing its job (e.g. npm killed by a network
# rule); the verify step decides. It is recorded, not hidden.
if [ "$status" -ne 0 ]; then
  echo "::warning::Packj sandbox exited with status $status (see $LOG)"
fi
exit 0
