#!/usr/bin/env bash
# Record the outer environment (the GitHub-hosted runner) before any FV8 or
# control runtime is built or run. Writes, separately from anything the
# probe can see:
#   <out>/environment-metadata.json
#   <out>/logs/github-host.txt        (raw command output)
#
# Records only names and versions: no environment variable values other
# than the GitHub/runner identifiers listed below.
#
# Usage: record-environment.sh <out-dir> <variant> <runtime-build-method>
set -uo pipefail

OUT=$1
VARIANT=$2
BUILD_METHOD=$3

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
mkdir -p "$OUT/logs"

or_null() { if [ -n "$1" ]; then jq -cn --arg v "$1" '$v'; else echo null; fi; }
first_line() { "$@" 2>/dev/null | head -1; }

{
  echo "=== TIMESTAMP ==="; date -u --iso-8601=seconds
  echo; echo "=== GITHUB ACTIONS ==="
  echo "GITHUB_WORKFLOW=${GITHUB_WORKFLOW:-}"
  echo "GITHUB_RUN_ID=${GITHUB_RUN_ID:-}"
  echo "GITHUB_RUN_ATTEMPT=${GITHUB_RUN_ATTEMPT:-}"
  echo "GITHUB_SHA=${GITHUB_SHA:-}"
  echo; echo "=== RUNNER ==="
  echo "RUNNER_OS=${RUNNER_OS:-}"
  echo "RUNNER_ARCH=${RUNNER_ARCH:-}"
  echo "RUNNER_ENVIRONMENT=${RUNNER_ENVIRONMENT:-}"
  echo "ImageOS=${ImageOS:-}"
  echo "ImageVersion=${ImageVersion:-}"
  echo; echo "=== OS ==="; cat /etc/os-release
  echo; echo "=== KERNEL ==="; uname -a
  echo; echo "=== CPU ==="; lscpu
  echo; echo "=== MEMORY ==="; free -h
  echo; echo "=== FILESYSTEM ==="; df -Th
  echo; echo "=== TOOLS ==="
  echo "node $(node --version 2>&1) at $(command -v node)"
  echo "npm $(npm --version 2>&1) at $(command -v npm)"
  gcc --version | head -1
  g++ --version | head -1
  python3 --version
  make --version | head -1
  echo; echo "=== DOCKER ==="
  echo "Docker is not used by this experiment."
  docker version --format 'client {{.Client.Version}} / server {{.Server.Version}}' 2>&1 || true
} > "$OUT/logs/github-host.txt" 2>&1

os_release=$(jq -Rn '[inputs | select(test("^[A-Z_]+=")) | capture("^(?<k>[A-Z_]+)=(?<v>.*)$") | {key: .k, value: (.v | ltrimstr("\"") | rtrimstr("\""))}] | from_entries' < /etc/os-release)
cpu_model=$(lscpu | sed -n 's/^Model name: *//p' | head -1)
mem_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)

jq -n \
  --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg variant "$VARIANT" \
  --arg run_id "${GITHUB_RUN_ID:-}" \
  --arg run_attempt "${GITHUB_RUN_ATTEMPT:-}" \
  --arg workflow "${GITHUB_WORKFLOW:-}" \
  --arg repo_commit "${GITHUB_SHA:-$(git -C "$REPO" rev-parse HEAD)}" \
  --arg runner_os "${RUNNER_OS:-}" \
  --arg runner_arch "${RUNNER_ARCH:-}" \
  --argjson runner_environment "$(or_null "${RUNNER_ENVIRONMENT:-}")" \
  --argjson image_os "$(or_null "${ImageOS:-}")" \
  --argjson image_version "$(or_null "${ImageVersion:-}")" \
  --argjson os_release "$os_release" \
  --arg uname "$(uname -a)" \
  --arg machine "$(uname -m)" \
  --arg cpu_model "$cpu_model" \
  --arg cpus "$(nproc)" \
  --arg mem_total_kb "$mem_total_kb" \
  --argjson docker "$(or_null "$(docker version --format '{{.Server.Version}}' 2>/dev/null)")" \
  --argjson node "$(or_null "$(first_line node --version)")" \
  --argjson npm "$(or_null "$(first_line npm --version)")" \
  --arg fv8_commit "$(git -C "$REPO/tools/fv8" rev-parse HEAD 2>/dev/null)" \
  --arg build_method "$BUILD_METHOD" \
  '{
    recorded_at: $recorded_at,
    recorded_before_analysis_runtime: true,
    experiment_variant: $variant,
    github: { workflow: $workflow, run_id: $run_id, run_attempt: $run_attempt, repository_commit: $repo_commit },
    runner: {
      provider: "GitHub Actions",
      hosted: true,
      os: $runner_os,
      architecture: $runner_arch,
      environment: $runner_environment,
      image_os: $image_os,
      image_version: $image_version
    },
    os_release: $os_release,
    uname: $uname,
    machine: $machine,
    cpu: { model: $cpu_model, logical_cpus: ($cpus | tonumber) },
    memory: { mem_total_kb: ($mem_total_kb | tonumber) },
    docker: { used_by_experiment: false, server_version_on_runner: $docker },
    outer_node: { version: $node, npm_version: $npm, source: "actions/setup-node@v4 node-version 22 (runner tool cache)" },
    fv8: { repository: "https://github.com/wspr-ncsu/FV8", commit: (if $fv8_commit == "" then null else $fv8_commit end) },
    runtime_build_method: $build_method
  }' > "$OUT/environment-metadata.json"

cat "$OUT/environment-metadata.json"
