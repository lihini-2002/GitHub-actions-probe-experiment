#!/usr/bin/env bash
# Run `packj audit --trace` on one local npm tarball and collect its outputs.
#
# Packj's trace stage runs, from its own working directory:
#   strace -f -e trace=network,file,process -ttt -T -o <report_dir>/trace_*.log \
#     npm install --silent --no-progress --no-update-notifier <package>
# so Packj is started from an empty directory that becomes the npm project
# root, as `npm install <tarball>` in a fresh directory. Without that, npm
# would install into whatever project Packj happened to be started from.
#
# Packj asks "We recommend running in Docker/Podman. Continue (N/y)" when it is
# not in a container; the answer is given on stdin, which Packj does not pass
# on to npm. Nothing experiment-specific is added to the environment.
#
# Packj writes all of its output into a fresh /tmp/packj_audit_* directory and
# prints its path. Its outputs go to <out>/packj/{audit,trace,logs}, and the
# probe's own report to <out>/probe; the two are never merged.
#
# Usage: run-packj-trace.sh <build-dir> <package.tgz> <out-dir>
set -euo pipefail

BUILD=$(realpath "$1")
TARBALL=$(realpath "$2")
OUT=$3

PKG_NAME=npm-probing-package
STAGE="${RUNNER_TEMP:-/tmp}/packj-input"
WORK="${RUNNER_TEMP:-/tmp}/packj-work"

mkdir -p "$OUT/probe" "$OUT/packj/audit/static" "$OUT/packj/trace" "$OUT/packj/logs"
OUT=$(realpath "$OUT")
LOGS="$OUT/packj/logs"

for dir in "$STAGE" "$WORK"; do
  if [ -e "$dir" ]; then
    echo "::error::$dir already exists; each run must start clean"
    exit 1
  fi
done
mkdir -p "$STAGE" "$WORK"

# Packj's static stage writes <package>.out and <package>.out.json next to its
# input, so it gets a copy of the tarball rather than the one in the repository.
INPUT="$STAGE/$(basename "$TARBALL")"
cp "$TARBALL" "$INPUT"

echo "Package:   $INPUT"
echo "Work dir:  $WORK"
echo "Command:   python3 main.py audit --debug --trace -p local_nodejs:$INPUT"

npm_log_marker="$LOGS/.npm-log-marker"
touch "$npm_log_marker"

cd "$WORK"
set +e
printf 'y\n' | "$BUILD/venv/bin/python" "$BUILD/packj/main.py" \
  audit --debug --trace -p "local_nodejs:$INPUT" \
  2>&1 | tee "$LOGS/packj-audit.log"
status=${PIPESTATUS[1]}
set -e
cd - >/dev/null
echo "$status" > "$LOGS/packj-exit-status.txt"
echo "Packj exit status: $status"

# Packj's report directory, from "=> Complete report: <dir>/report_*.json".
report_json=$(sed -n 's/^=> Complete report: //p' "$LOGS/packj-audit.log" | tail -1)
report_dir=""
[ -n "$report_json" ] && report_dir=$(dirname "$report_json")
if [ -n "$report_dir" ] && [ -d "$report_dir" ]; then
  echo "Packj report dir: $report_dir"
  find "$report_dir" -maxdepth 1 -type f -name 'report_*' -exec cp {} "$OUT/packj/audit/" \;
  find "$report_dir" -maxdepth 1 -type f \( -name 'trace_*.log' -o -name 'summary_*.json' \) \
    -exec cp {} "$OUT/packj/trace/" \;
  find "$report_dir" -maxdepth 1 -type f -name 'debug_*.log' -exec cp {} "$LOGS/" \;
  ls -la "$report_dir" > "$LOGS/packj-report-dir-listing.txt"
else
  echo "::error::Packj did not print a usable report path ('$report_json')"
fi

for f in "$INPUT.out" "$INPUT.out.json"; do
  [ -f "$f" ] && cp "$f" "$OUT/packj/audit/static/"
done

# npm's view of the install Packj ran.
for f in package.json package-lock.json; do
  [ -f "$WORK/$f" ] && cp "$WORK/$f" "$LOGS/npm-work-$f"
done
if [ -d "$HOME/.npm/_logs" ]; then
  mkdir -p "$LOGS/npm-logs"
  find "$HOME/.npm/_logs" -type f -newer "$npm_log_marker" -exec cp {} "$LOGS/npm-logs/" \;
fi
rm -f "$npm_log_marker"

# The probe writes to <installed package>/results/, falling back to
# $TMPDIR/npm-probing-package-results when that is not writable.
installed="$WORK/node_modules/$PKG_NAME"
probe_source=""
for dir in "$installed/results" "${TMPDIR:-/tmp}/npm-probing-package-results"; do
  if ls "$dir"/install-*.json >/dev/null 2>&1; then
    cp "$dir"/install-*.json "$OUT/probe/"
    probe_source=$dir
    break
  fi
done

jq -n \
  --arg input "$INPUT" \
  --arg work_dir "$WORK" \
  --arg report_dir "$report_dir" \
  --arg installed_package_dir "$installed" \
  --arg probe_report_source_dir "$probe_source" \
  --argjson packj_exit_status "$status" \
  '{input: $input, work_dir: $work_dir, report_dir: $report_dir,
    installed_package_dir: $installed_package_dir,
    probe_report_source_dir: $probe_report_source_dir,
    packj_exit_status: $packj_exit_status}' > "$LOGS/run-paths.json"
cat "$LOGS/run-paths.json"

echo "Collected:"
find "$OUT/probe" "$OUT/packj" -type f | sort

if [ "$status" -ne 0 ]; then
  echo "::error::Packj exited with status $status (see $LOGS/packj-audit.log)"
fi
exit "$status"
