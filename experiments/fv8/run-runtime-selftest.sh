#!/usr/bin/env bash
# Harness self-test of the built runtime, run before any npm install:
#   - version/config of the runtime, written by the runtime to a file (an
#     FV8 runtime may print "Found match for API" lines on stdout, so stdout
#     is never parsed for values);
#   - whether the node binary contains FV8/VisibleV8 code;
#   - the forced-execution canary (smoke-package/canary.cjs) run directly;
#   - VisibleV8 logs the canary run produced.
# verify-fv8-run.sh runtime checks the results.
#
# Writes <out>/runtime/.
#
# Usage: run-runtime-selftest.sh <runtime-dir> <out-dir> <scratch-dir>
set -uo pipefail

RUNTIME=$1
OUT=$2
SCRATCH=$3

# The runtime is run from scratch directories (it may write VisibleV8 logs to
# its cwd), so every path handed to it must be absolute.
mkdir -p "$OUT" "$SCRATCH"
RUNTIME=$(cd "$RUNTIME" && pwd)
OUT=$(cd "$OUT" && pwd)
SCRATCH=$(cd "$SCRATCH" && pwd)

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NODE="$RUNTIME/bin/node"
DEST="$OUT/runtime"
mkdir -p "$DEST/canary-vv8-logs"

cp "$RUNTIME/fv8-experiment/build-info.json" "$DEST/build-info.json"
cp "$RUNTIME/fv8-experiment/configure-args.txt" "$DEST/configure-args.txt"
for f in patch-apply.log source-changes.stat source-changes.diff; do
  [ -s "$RUNTIME/fv8-experiment/$f" ] && cp "$RUNTIME/fv8-experiment/$f" "$DEST/$f"
done
sha256sum "$NODE" | cut -d' ' -f1 > "$DEST/node-binary-sha256.txt"

# Runtime info (fresh directory: the runtime may write VisibleV8 logs to its cwd).
work="$SCRATCH/selftest-info"
rm -rf "$work"; mkdir -p "$work"
(cd "$work" && "$NODE" -e '
  require("fs").writeFileSync(process.argv[1], JSON.stringify({
    exec_path: process.execPath,
    version: process.version,
    versions: process.versions,
    exec_argv: process.execArgv,
    node_v8_options: process.config.variables.node_v8_options ?? null,
    arch: process.arch,
    platform: process.platform
  }, null, 2) + "\n")' "$DEST/runtime-info.json") > "$DEST/runtime-info.stdout.log" 2>&1
echo "runtime-info exit: $?" >> "$DEST/runtime-info.stdout.log"
find "$work" -maxdepth 1 -name 'vv8-*.log' | wc -l > "$DEST/runtime-info-vv8-log-count.txt"

# FV8/VisibleV8 strings compiled into the binary.
python3 - "$NODE" > "$DEST/binary-markers.json" <<'PY'
import json, sys
data = open(sys.argv[1], 'rb').read()
print(json.dumps({
    'fv8_forced_execution_string': data.count(b'Found match for API: ') > 0,
    'visiblev8_log_name_pattern': data.count(b'vv8-%ld-%d-%d-%s') > 0,
}, indent=2))
PY

# Forced-execution canary, run directly.
work="$SCRATCH/selftest-canary"
rm -rf "$work"; mkdir -p "$work"
cp "$HERE/smoke-package/canary.cjs" "$work/canary.cjs"
(cd "$work" && "$NODE" canary.cjs "$DEST/canary-markers.json") > "$DEST/canary.stdout.log" 2>&1
echo $? > "$DEST/canary-exit-status.txt"
find "$work" -maxdepth 1 -name 'vv8-*.log' -exec cp {} "$DEST/canary-vv8-logs/" \;

cat "$DEST/runtime-info.json" "$DEST/binary-markers.json" "$DEST/canary-markers.json" 2>/dev/null
echo "canary stdout:"; cat "$DEST/canary.stdout.log"
echo "canary VisibleV8 logs: $(find "$DEST/canary-vv8-logs" -type f | wc -l)"
