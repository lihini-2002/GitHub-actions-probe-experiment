#!/usr/bin/env bash
# Install one package tarball with npm, with the experiment runtime's
# bin/ first on PATH, so that the lifecycle command `node ...` (run by npm
# via `sh -c`) resolves to the experiment runtime (FV8 or control).
#
#   npm host fv8-node     npm itself runs on the experiment runtime
#                         ($RUNTIME/bin/npm, the npm bundled with the pinned
#                         Node.js commit). Everything is on one runtime.
#   npm host system-node  npm runs on the runner's setup-node Node.js 22;
#                         only lifecycle scripts run on the experiment
#                         runtime.
#
# The command is `npm install <tarball> --foreground-scripts`, run from a
# fresh, empty directory. Nothing else is added to the environment.
#
# Outputs in <out-dir>:
#   npm-install.log            npm stdout+stderr (lifecycle output included)
#   npm-exit-status.txt
#   run-paths.json             work dir, installed package dir, npm command
#   npm-logs/                  npm debug logs written by this install
#   vv8-logs/lifecycle/        VisibleV8 logs written in the installed package
#                              dir (the lifecycle script's cwd)
#   vv8-logs/npm/*.gz          VisibleV8 logs written in the work dir (npm's cwd)
#   vv8-logs/index.json        file -> pid/thread/size
#   forced-execution-markers.txt   every "Found match for API" line
#   postinstall-window.log     npm output from the postinstall banner to the
#                              end of the lifecycle step
#   package-dir-listing.txt
# Package reports are copied to <report-dest> (results/install-*.json for the
# probe, markers.json for the smoke package).
#
# Usage: run-npm-install.sh <runtime-dir> <fv8-node|system-node> <tarball> \
#          <work-dir> <out-dir> <package-name> <report-dest>
set -uo pipefail

RUNTIME=$1
NPM_HOST=$2
TARBALL=$3
WORK=$4
OUT=$5
PKG=$6
REPORT_DEST=$7

if [ -e "$WORK" ]; then echo "$WORK already exists" >&2; exit 2; fi
mkdir -p "$WORK" "$OUT/npm-logs" "$OUT/vv8-logs/lifecycle" "$OUT/vv8-logs/npm" "$REPORT_DEST"
TARBALL=$(readlink -f "$TARBALL")

case "$NPM_HOST" in
  fv8-node)
    npm_cmd=("$RUNTIME/bin/npm")
    npm_version=$(jq -r .version "$RUNTIME/lib/node_modules/npm/package.json")
    npm_node="$RUNTIME/bin/node"
    ;;
  system-node)
    system_node=$(command -v node)
    system_npm_cli=$(readlink -f "$(command -v npm)")
    npm_cmd=("$system_node" "$system_npm_cli")
    npm_version=$(npm --version)
    npm_node="$system_node"
    ;;
  *) echo "npm host must be fv8-node or system-node" >&2; exit 2 ;;
esac

stamp="$OUT/.started"
touch "$stamp"
echo "npm command: ${npm_cmd[*]} install $TARBALL --foreground-scripts"
echo "PATH prefix: $RUNTIME/bin"
(
  cd "$WORK" &&
  PATH="$RUNTIME/bin:$PATH" timeout 1800 "${npm_cmd[@]}" install "$TARBALL" --foreground-scripts
) > "$OUT/npm-install.log" 2>&1
status=$?
echo "$status" > "$OUT/npm-exit-status.txt"
cat "$OUT/npm-install.log"
echo "npm exit status: $status"

installed="$WORK/node_modules/$PKG"
find "$HOME/.npm/_logs" -type f -newer "$stamp" -exec cp {} "$OUT/npm-logs/" \; 2>/dev/null
rm -f "$stamp"
ls -la "$installed" > "$OUT/package-dir-listing.txt" 2>&1
cp "$WORK/package.json" "$OUT/npm-work-package.json" 2>/dev/null
cp "$WORK/package-lock.json" "$OUT/npm-work-package-lock.json" 2>/dev/null

# VisibleV8 logs. Lifecycle processes run with cwd = the installed package
# dir; npm itself runs in the work dir. Any other location is recorded too.
find "$installed" -maxdepth 1 -type f -name 'vv8-*.log' -exec cp {} "$OUT/vv8-logs/lifecycle/" \; 2>/dev/null
find "$WORK" -maxdepth 1 -type f -name 'vv8-*.log' -exec sh -c 'gzip -c "$1" > "$2/$(basename "$1").gz"' _ {} "$OUT/vv8-logs/npm" \;
find "$WORK" -mindepth 2 -type f -name 'vv8-*.log' -not -path "$installed/vv8-*.log" > "$OUT/vv8-logs/other-locations.txt"
find "$WORK" -type f -name 'vv8-*.log' -printf '%P\t%s\n' \
  | jq -Rn '[inputs | split("\t") | {path: .[0], bytes: (.[1] | tonumber)}
             | . + ((.path | split("/") | last | capture("^vv8-(?<ms>[0-9]+)-(?<pid>[0-9]+)-(?<tid>[0-9]+)-(?<thread>.*)\\.(?<n>[0-9]+)\\.log$")) // {})]' \
  > "$OUT/vv8-logs/index.json"

grep -a 'Found match for API: ' "$OUT/npm-install.log" > "$OUT/forced-execution-markers.txt" || true
# npm --foreground-scripts prints "> <pkg>@<ver> postinstall" before running
# the script and resumes its own output ("added 1 package", "npm error", ...)
# when the script has exited.
awk -v pkg="$PKG" '
  index($0, "> " pkg "@") == 1 && $NF == "postinstall" { on = 1 }
  on && /^(added|changed|removed|up to date|npm (error|ERR!)|audited|found|[0-9]+ packages? (is|are) looking)/ { exit }
  on { print }
' "$OUT/npm-install.log" > "$OUT/postinstall-window.log"

# Package reports.
case "$PKG" in
  npm-probing-package)
    find "$installed/results" -maxdepth 1 -type f -name 'install-*.json' -exec cp {} "$REPORT_DEST/" \; 2>/dev/null
    # The probe falls back to <tmpdir>/npm-probing-package-results when its
    # package dir is not writable; record (not merge) anything found there.
    fallback=$(find "${TMPDIR:-/tmp}/npm-probing-package-results" -maxdepth 1 -type f -name 'install-*.json' -newer "$TARBALL" 2>/dev/null | wc -l)
    ;;
  *)
    [ -f "$installed/markers.json" ] && cp "$installed/markers.json" "$REPORT_DEST/markers.json"
    fallback=0
    ;;
esac

jq -n \
  --arg tarball "$TARBALL" \
  --arg work "$WORK" \
  --arg installed "$installed" \
  --arg npm_host "$NPM_HOST" \
  --arg npm_node "$npm_node" \
  --arg npm_version "$npm_version" \
  --arg runtime_node "$RUNTIME/bin/node" \
  --arg cmd "${npm_cmd[*]} install $TARBALL --foreground-scripts" \
  --argjson installed_exists "$([ -d "$installed" ] && echo true || echo false)" \
  --argjson fallback "$fallback" \
  '{
    tarball: $tarball,
    work_dir: $work,
    installed_package_dir: $installed,
    installed_package_dir_exists: $installed_exists,
    npm_host: $npm_host,
    npm_runs_on: $npm_node,
    npm_version: $npm_version,
    lifecycle_node_expected: $runtime_node,
    command: $cmd,
    path_prefix: ($runtime_node | rtrimstr("/node")),
    probe_reports_in_tmpdir_fallback: $fallback
  }' > "$OUT/run-paths.json"

exit "$status"
