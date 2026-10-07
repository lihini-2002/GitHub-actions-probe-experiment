#!/usr/bin/env bash
# Write experiment/run metadata for the Packj trace experiment. Kept separate
# from the probe's own report and from Packj's output; nothing here is visible
# to the probe (it runs after the probe has finished).
#
# Same layered experiment.json as experiments/latch/write-metadata.sh. Fields
# that cannot be determined (e.g. Packj failed to install) are null.
#
# Expects EXPERIMENT_ENV_ID, EXPERIMENT_ENV_NAME, EXPERIMENT_STUDY_ROLE and
# EXPERIMENT_RUNNER in the environment.
#
# Usage: write-metadata.sh <out-dir> <packj-build-dir> <probe.tgz>
set -uo pipefail

OUT=$1
BUILD=$2
TARBALL=$3

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
PATCH="$HERE/patches/packj-local-nodejs-trace.patch"
mkdir -p "$OUT/metadata"

check() {
  local f="$OUT/metadata/checks/$1.json"
  if [ -f "$f" ]; then jq -c . "$f"; else echo null; fi
}
check_passed() {
  local f="$OUT/metadata/checks/$1.json"
  if [ -f "$f" ]; then jq '.passed' "$f"; else echo false; fi
}
or_null() { if [ -n "$1" ]; then jq -cn --arg v "$1" '$v'; else echo null; fi; }
first_line() { "$@" 2>/dev/null | head -1; }

python_version=""
packj_version=""
if [ -x "$BUILD/venv/bin/python" ]; then
  python_version=$("$BUILD/venv/bin/python" -c 'import platform; print(platform.python_version())' 2>/dev/null)
  packj_version=$(cd "$BUILD/packj" && "$BUILD/venv/bin/python" -c 'from packj import __version__; print(__version__)' 2>/dev/null)
fi
[ -f "$BUILD/pip-freeze.txt" ] && cp "$BUILD/pip-freeze.txt" "$OUT/metadata/packj-pip-freeze.txt"

packj_exit=$(cat "$OUT/packj/logs/packj-exit-status.txt" 2>/dev/null)
input=$(jq -r '.input // empty' "$OUT/packj/logs/run-paths.json" 2>/dev/null)
host_os=$( (. /etc/os-release && echo "$PRETTY_NAME") 2>/dev/null)

probe_reports=$(find "$OUT/probe" -maxdepth 1 -type f -name 'install-*.json' 2>/dev/null | wc -l)
trace_logs=$(find "$OUT/packj/trace" -maxdepth 1 -type f -name 'trace_*.log' 2>/dev/null | wc -l)
trace_lines=0
for f in "$OUT"/packj/trace/trace_*.log; do [ -f "$f" ] && trace_lines=$((trace_lines + $(wc -l < "$f"))); done

jq -n \
  --arg env_id "$EXPERIMENT_ENV_ID" \
  --arg env_name "$EXPERIMENT_ENV_NAME" \
  --arg study_role "$EXPERIMENT_STUDY_ROLE" \
  --arg runner "$EXPERIMENT_RUNNER" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg run_id "${GITHUB_RUN_ID:-}" \
  --arg run_attempt "${GITHUB_RUN_ATTEMPT:-}" \
  --arg workflow "${GITHUB_WORKFLOW:-}" \
  --arg repo_commit "${GITHUB_SHA:-$(git -C "$REPO" rev-parse HEAD)}" \
  --arg arch "${RUNNER_ARCH:-}" \
  --arg machine "$(uname -m)" \
  --arg kernel "$(uname -r)" \
  --arg host_os "$host_os" \
  --argjson image_os "$(or_null "${ImageOS:-}")" \
  --argjson image_version "$(or_null "${ImageVersion:-}")" \
  --argjson strace "$(or_null "$(first_line strace --version)")" \
  --argjson node "$(or_null "$(first_line node --version)")" \
  --argjson npm "$(or_null "$(first_line npm --version)")" \
  --argjson python "$(or_null "$python_version")" \
  --argjson packj_version "$(or_null "$packj_version")" \
  --arg packj_commit "$(git -C "$REPO/tools/packj" rev-parse HEAD 2>/dev/null)" \
  --arg patch_sha256 "$(sha256sum "$PATCH" | cut -d' ' -f1)" \
  --argjson input "$(or_null "$input")" \
  --argjson packj_exit "$(or_null "$packj_exit")" \
  --arg tarball "$(basename "$TARBALL")" \
  --arg tarball_sha256 "$(sha256sum "$TARBALL" | cut -d' ' -f1)" \
  --argjson probe_reports "$probe_reports" \
  --argjson trace_logs "$trace_logs" \
  --argjson trace_lines "$trace_lines" \
  --argjson check_packj "$(check packj)" \
  --argjson check_trace "$(check trace)" \
  --argjson check_probe "$(check probe)" \
  --argjson packj_ok "$(check_passed packj)" \
  --argjson trace_ok "$(check_passed trace)" \
  --argjson probe_ok "$(check_passed probe)" \
  '{
    experiment: $env_name,
    environment_id: $env_id,
    environment_name: $env_name,
    study_role: $study_role,
    timestamp: $timestamp,
    run_id: $run_id,
    run_attempt: $run_attempt,
    workflow: $workflow,
    repository_commit: $repo_commit,
    host_layer: {
      provider: "GitHub Actions",
      runner: "GitHub-hosted",
      os_label: $runner,
      runner_image_os: $image_os,
      runner_image_version: $image_version,
      os: $host_os,
      kernel: $kernel,
      architecture: $arch,
      machine: $machine,
      container: false,
      strace_version: $strace
    },
    scanner_layer: {
      tool: "Packj",
      upstream: "https://github.com/ossillate-inc/packj",
      packj_commit: $packj_commit,
      packj_version: $packj_version,
      packj_mode: "audit --trace",
      command: ("python3 main.py audit --debug --trace -p local_nodejs:" + ($input // "<tarball>")),
      traced_install_command: ("strace -f -e trace=network,file,process -ttt -T -o <report_dir>/trace_*.log npm install --silent --no-progress --no-update-notifier " + ($input // "<tarball>")),
      python_version: $python,
      python_requirements: "tools/packj/requirements.txt constrained by experiments/packj/requirements-lock.txt (see metadata/packj-pip-freeze.txt)",
      node_version: $node,
      npm_version: $npm,
      sandbox_mode_used: false,
      modified_from_stock: true,
      patch: "experiments/packj/patches/packj-local-nodejs-trace.patch",
      patch_sha256: $patch_sha256,
      modifications: [
        "get_pm_install_cmd supports local_nodejs (upstream raised \"not supported\", so --trace never ran for local packages)",
        "local_nodejs accepts a .tgz: package.json and README.md read from the tarball, static analysis run on it",
        "analyze_repo_url initialises repo_url (upstream crashed the audit for packages without a repository field)"
      ]
    },
    package_layer: {
      ecosystem: "npm",
      package: "npm-probing-package",
      version: "0.1.0",
      source: "local-tarball",
      tarball: $tarball,
      tarball_sha256: $tarball_sha256
    },
    outcome: {
      probe_execution_succeeded: $probe_ok,
      probe_output_recovered: ($probe_reports > 0),
      packj_trace_output_recovered: $trace_ok,
      packj_audit_completed: $packj_ok,
      experiment_valid: ($probe_ok and $trace_ok and $packj_ok),
      packj_exit_status: (if $packj_exit == null then null else ($packj_exit | tonumber) end),
      probe_reports_found: $probe_reports,
      packj_trace_logs_found: $trace_logs,
      packj_trace_log_lines: $trace_lines,
      checks: {
        packj: $check_packj,
        trace: $check_trace,
        probe: $check_probe
      }
    }
  }' > "$OUT/metadata/experiment.json"

cat "$OUT/metadata/experiment.json"
