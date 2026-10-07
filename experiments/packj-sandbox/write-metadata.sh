#!/usr/bin/env bash
# Write experiment/run metadata for the Packj sandbox experiment. Kept
# separate from the probe's own report and from Packj's output; it runs after
# the probe has finished, so nothing here is visible to the probe.
#
# Same layered experiment.json as experiments/packj/write-metadata.sh. Fields
# that cannot be determined (e.g. Packj failed to install) are null.
#
# Expects EXPERIMENT_ENV_ID, EXPERIMENT_ENV_NAME, EXPERIMENT_STUDY_ROLE and
# EXPERIMENT_RUNNER in the environment.
#
# Usage: write-metadata.sh <out-dir> <packj-build-dir> <node-bin-dir> <probe.tgz>
set -uo pipefail

OUT=$1
BUILD=$2
NODE_BIN=$3
TARBALL=$4

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SBOX="$BUILD/packj/packj/sandbox"
mkdir -p "$OUT/metadata"

check() {
  local f="$OUT/metadata/checks/$1.json"
  if [ -f "$f" ]; then jq -c . "$f"; else echo null; fi
}
or_null() { if [ -n "$1" ]; then jq -cn --arg v "$1" '$v'; else echo null; fi; }
first_line() { "$@" 2>/dev/null | head -1; }
sha() { [ -f "$1" ] && sha256sum "$1" | cut -d' ' -f1; }

python_version=""
packj_version=""
if [ -x "$BUILD/venv/bin/python" ]; then
  python_version=$("$BUILD/venv/bin/python" -c 'import platform; print(platform.python_version())' 2>/dev/null)
  packj_version=$(cd "$BUILD/packj" && "$BUILD/venv/bin/python" -c 'from packj import __version__; print(__version__)' 2>/dev/null)
fi
[ -f "$BUILD/pip-freeze.txt" ] && cp "$BUILD/pip-freeze.txt" "$OUT/metadata/packj-pip-freeze.txt"

# Packj's own strace (built by install.sh), not the system one.
sandbox_strace=""
[ -x "$SBOX/strace" ] && sandbox_strace=$(LD_LIBRARY_PATH="$SBOX" first_line "$SBOX/strace" --version)
strace_commit=$(git -C /tmp/packj-strace rev-parse HEAD 2>/dev/null)

outcome=null
[ -f "$OUT/metadata/outcome.json" ] && outcome=$(jq -c . "$OUT/metadata/outcome.json")
input=$(jq -r '.input // empty' "$OUT/packj/logs/run-paths.json" 2>/dev/null)
packj_exit=$(cat "$OUT/packj/logs/packj-exit-status.txt" 2>/dev/null)
answer=$(jq -r '.review_answer // empty' "$OUT/packj/logs/run-paths.json" 2>/dev/null)
profile=$(find "$OUT/packj/policy" -maxdepth 1 -name 'rules_*.profile' 2>/dev/null | head -1)
host_os=$( (. /etc/os-release && echo "$PRETTY_NAME") 2>/dev/null)

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
  --argjson host_strace "$(or_null "$(first_line strace --version)")" \
  --argjson sandbox_strace "$(or_null "$sandbox_strace")" \
  --argjson strace_commit "$(or_null "$strace_commit")" \
  --argjson libsbox_sha "$(or_null "$(sha "$SBOX/libsbox.so")")" \
  --argjson sandbox_o_sha "$(or_null "$(sha "$SBOX/sandbox.o")")" \
  --argjson node "$(or_null "$(first_line "$NODE_BIN/node" --version)")" \
  --argjson npm "$(or_null "$(PATH="$NODE_BIN:$PATH" first_line npm --version)")" \
  --arg node_bin "$NODE_BIN" \
  --argjson python "$(or_null "$python_version")" \
  --argjson packj_version "$(or_null "$packj_version")" \
  --arg packj_commit "$(git -C "$REPO/tools/packj" rev-parse HEAD 2>/dev/null)" \
  --argjson policy_sha "$(or_null "$(sha "$OUT/packj/policy/packj.yaml")")" \
  --argjson sandbox_patch_sha "$(or_null "$(sha "$HERE/patches/packj-sandbox-strace-bundled-headers.patch")")" \
  --argjson table_pad_sha "$(or_null "$(sha "$HERE/patches/packj-sandbox-syscall-table-pad.patch")")" \
  --argjson profile "$(or_null "${profile:+packj/policy/$(basename "$profile")}")" \
  --argjson input "$(or_null "$input")" \
  --argjson answer "$(or_null "$answer")" \
  --argjson packj_exit "$(or_null "$packj_exit")" \
  --arg tarball "$(basename "$TARBALL")" \
  --arg tarball_sha256 "$(sha256sum "$TARBALL" | cut -d' ' -f1)" \
  --argjson check_sandbox "$(check sandbox)" \
  --argjson check_install "$(check install)" \
  --argjson check_probe "$(check probe)" \
  --argjson outcome "$outcome" \
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
      strace_version: $host_strace
    },
    scanner_layer: {
      tool: "Packj",
      upstream: "https://github.com/ossillate-inc/packj",
      packj_commit: $packj_commit,
      packj_version: $packj_version,
      packj_mode: "sandbox",
      command: ("python3 main.py sandbox npm install " + ($input // "<tarball>")),
      sandboxed_command: ("<packj>/sandbox/strace -fc --quiet=attach,personality -o <dir>/trace_*.log npm install " + ($input // "<tarball>") + "  (LD_PRELOAD=libsbox.so, SANDBOX_ROOT, SANDBOX_RULES)"),
      review_answer: $answer,
      policy: {
        file: "packj/policy/packj.yaml",
        source: "tools/packj/.packj.yaml (upstream, unmodified)",
        sha256: $policy_sha,
        generated_profile: $profile
      },
      sandbox_strace_version: $sandbox_strace,
      sandbox_strace_source_commit: $strace_commit,
      sandbox_o_sha256: $sandbox_o_sha,
      libsbox_sha256: $libsbox_sha,
      python_version: $python,
      python_requirements: "tools/packj/requirements.txt constrained by experiments/packj/requirements-lock.txt (see metadata/packj-pip-freeze.txt)",
      node_version: $node,
      node_bin: $node_bin,
      npm_version: $npm,
      trace_mode_used: false,
      packj_tree_patch: "experiments/packj/patches/packj-local-nodejs-trace.patch (applied by the shared install script; touches packj/audit only, not packj/sandbox)",
      sandbox_modified_from_stock: true,
      sandbox_patches: {
        "experiments/packj-sandbox/patches/packj-sandbox-strace-bundled-headers.patch": $sandbox_patch_sha,
        "experiments/packj-sandbox/patches/packj-sandbox-syscall-table-pad.patch": $table_pad_sha
      },
      sandbox_modifications: [
        "install.sh configures strace v5.19 with --enable-bundled=yes (build against strace 5.19 bundled kernel UAPI headers; it does not compile against Ubuntu 24.04 linux-libc-dev 6.8: BTRFS_EXTENT_REF_V0_KEY undeclared).",
        "libsbox.so is linked with 8192 zero bytes after the 346-entry syscall handler table of sandbox.o (Makefile + table-pad.s). sandbox.o indexes the table by syscall number without a bounds check; syscalls >= 346 (clone3, close_range, openat2, faccessat2, ...) otherwise jump through .got.plt and crash strace (SIGSEGV observed on the runner). With the padding they read NULL, which the blob treats as no handler, and pass through without Packj interposition, like the 252 unhooked syscalls below 346.",
        "main.py, sandbox.o code and the policy are unchanged."
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
    outcome: (($outcome // {}) + {
      sandbox_exit_code: (if $packj_exit == null then null else ($packj_exit | tonumber) end),
      checks: {sandbox: $check_sandbox, install: $check_install, probe: $check_probe}
    })
  }' > "$OUT/metadata/experiment.json"

cat "$OUT/metadata/experiment.json"
