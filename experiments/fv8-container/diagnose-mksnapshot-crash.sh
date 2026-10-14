#!/usr/bin/env bash
# Opt-in diagnostics for a runtime build that failed in Node.js's snapshot
# step (node_mksnapshot). Re-runs the exact command make ran, under gdb, in the
# same build tree, and saves:
#   <out>/diagnostics/node_mksnapshot-backtrace.txt   gdb: crashing frame, all thread backtraces, registers
#   <out>/diagnostics/node_mksnapshot-stdout.txt      the program's own output (e.g. FV8 "Found match" lines)
#   <out>/diagnostics/vv8-logs/*.gz                   VisibleV8 logs the gdb replay wrote in its cwd
#   <out>/diagnostics/vv8-logs/plain-replay/*.gz      VisibleV8 logs of the replay without gdb
#   <out>/diagnostics/vv8-log-tails*.txt              last lines of each VisibleV8 log (what ran last)
#   <out>/diagnostics/summary.json
# Harness-only: nothing in FV8 or Node.js is changed, and this runs only after
# the build has already failed (the result is never used as a runtime).
#
# Usage: diagnose-mksnapshot-crash.sh <node-source-dir> <build-log> <out-dir>
set -uo pipefail

SRC=$1
LOG=$2
OUT=$3
D="$OUT/diagnostics"
mkdir -p "$D/vv8-logs"

REL="$SRC/out/Release"
MKSNAP="$REL/node_mksnapshot"
TARGET="$REL/obj/gen/node_snapshot.cc"

crashed_in_mksnapshot=false
grep -q 'node_snapshot.cc\] Error' "$LOG" 2>/dev/null && crashed_in_mksnapshot=true
if [ "$crashed_in_mksnapshot" != true ] || [ ! -x "$MKSNAP" ]; then
  echo "The build did not fail in node_mksnapshot (or the binary is missing); nothing to replay." | tee "$D/node_mksnapshot-backtrace.txt"
  jq -n --argjson c "$crashed_in_mksnapshot" --argjson b "$([ -x "$MKSNAP" ] && echo true || echo false)" \
    '{crashed_in_node_mksnapshot: $c, node_mksnapshot_binary_present: $b, replayed: false}' > "$D/summary.json"
  exit 0
fi

echo "=== Install gdb (diagnostics only)"
install_gdb() { DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gdb >> "$D/gdb-install.log" 2>&1; }
if ! install_gdb; then
  echo "retrying after apt-get update" >> "$D/gdb-install.log"
  apt-get update >> "$D/gdb-install.log" 2>&1
  install_gdb
fi
gdb_available=false
if command -v gdb >/dev/null; then
  gdb_available=true
  gdb --version | head -1 | tee -a "$D/gdb-install.log"
else
  echo "::error::gdb could not be installed; see diagnostics/gdb-install.log"
fi

# The command make ran (see node.target.mk / the build log): from the Node.js
# source root, with the build's library path. Fresh output file and a clean
# working directory listing, so any VisibleV8 logs found are from this replay.
find "$SRC" -maxdepth 1 -name 'vv8-*.log' -delete
export LD_LIBRARY_PATH="$REL/lib.host:$REL/lib.target:${LD_LIBRARY_PATH:-}"

echo "=== Replay without gdb (exit status and output)"
(cd "$SRC" && "$MKSNAP" "$TARGET.diag") > "$D/node_mksnapshot-stdout.txt" 2>&1
plain_status=$?
echo "exit status: $plain_status" | tee -a "$D/node_mksnapshot-stdout.txt"
# Keep this replay's VisibleV8 logs (useful even if gdb is unavailable).
mkdir -p "$D/vv8-logs/plain-replay"
for f in "$SRC"/vv8-*.log; do
  [ -f "$f" ] || continue
  gzip -c "$f" > "$D/vv8-logs/plain-replay/$(basename "$f").gz"
  {
    echo "=== plain replay: $(basename "$f") ($(wc -c < "$f") bytes)"
    tail -40 "$f" | cut -c1-300
    echo
  } >> "$D/vv8-log-tails.plain-replay.txt"
  rm -f "$f"
done

echo "=== Replay under gdb"
if [ "$gdb_available" != true ]; then
  echo "gdb unavailable; no backtrace" > "$D/node_mksnapshot-backtrace.txt"
  jq -n --argjson plain_status "$plain_status" \
    '{crashed_in_node_mksnapshot: true, replayed: true, replay_exit_status: $plain_status, gdb_available: false}' > "$D/summary.json"
  cat "$D/summary.json"
  exit 1
fi
(
  cd "$SRC" && timeout 1800 gdb -q -batch \
    -ex 'set pagination off' \
    -ex 'set print thread-events off' \
    -ex 'set disable-randomization off' \
    -ex 'handle SIGPIPE nostop noprint pass' \
    -ex run \
    -ex 'echo \n=== crashing thread backtrace\n' -ex 'bt 60' \
    -ex 'echo \n=== crashing frame\n' -ex 'info frame' -ex 'x/12i $pc' \
    -ex 'echo \n=== registers\n' -ex 'info registers' \
    -ex 'echo \n=== all threads\n' -ex 'thread apply all bt 25' \
    --args "$MKSNAP" "$TARGET.diag"
) > "$D/node_mksnapshot-backtrace.txt" 2>&1
gdb_status=$?
echo "gdb exit status: $gdb_status" >> "$D/node_mksnapshot-backtrace.txt"

# VisibleV8 logs written by the gdb replay (in the source root, its cwd).
: > "$D/vv8-log-tails.txt"
vv8_count=0
for f in "$SRC"/vv8-*.log; do
  [ -f "$f" ] || continue
  vv8_count=$((vv8_count + 1))
  {
    echo "=== $(basename "$f") ($(wc -c < "$f") bytes, $(wc -l < "$f") lines)"
    echo "--- script records (\$<id>:<name>), last 15:"
    grep -a '^\$[0-9]' "$f" | cut -d: -f1-2 | cut -c1-200 | tail -15
    echo "--- last 40 lines (truncated to 300 chars):"
    tail -40 "$f" | cut -c1-300
    echo
  } >> "$D/vv8-log-tails.txt"
  gzip -c "$f" > "$D/vv8-logs/$(basename "$f").gz"
done

signal=$(grep -m1 -oE 'received signal [A-Z]+' "$D/node_mksnapshot-backtrace.txt" | awk '{print $3}')
first_frames=$(sed -n '/^=== crashing thread backtrace/,/^=== crashing frame/p' "$D/node_mksnapshot-backtrace.txt" \
  | grep -E '^#[0-9]+ ' | head -12 | jq -Rn '[inputs]')
jq -n \
  --argjson plain_status "$plain_status" \
  --argjson gdb_status "$gdb_status" \
  --argjson signal "$(if [ -n "$signal" ]; then jq -cn --arg s "$signal" '$s'; else echo null; fi)" \
  --argjson frames "$first_frames" \
  --argjson vv8 "$vv8_count" \
  --argjson found "$(grep -ac 'Found match for API' "$D/node_mksnapshot-stdout.txt" 2>/dev/null || true)" \
  '{
    crashed_in_node_mksnapshot: true,
    replayed: true,
    gdb_available: true,
    replay_exit_status: $plain_status,
    gdb_exit_status: $gdb_status,
    signal: $signal,
    first_frames: $frames,
    found_match_lines_in_replay: $found,
    visiblev8_logs_from_gdb_replay: $vv8
  }' > "$D/summary.json"

cat "$D/summary.json"
echo; echo "=== Backtrace (head)"; sed -n '/=== crashing thread backtrace/,/=== crashing frame/p' "$D/node_mksnapshot-backtrace.txt" | head -70
