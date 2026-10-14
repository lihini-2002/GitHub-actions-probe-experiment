#!/usr/bin/env bash
# Decide, from harness-side evidence only, whether the probe package really ran
# through Pack-A-Mal's dynamic-analysis path, and write the experiment manifest.
#
# Usage: verify-pack-a-mal-run.sh <result-dir> <pack-a-mal-sha>
#
# Inputs (written by the workflow):
#   <result-dir>/pack-a-mal/analysis-exit-code.txt   exit code of run_analysis.sh
#   <result-dir>/pack-a-mal/analyze-help.txt         `analyze -help` of the built image
# Exit status: 0 only if a probe report was recovered from the Pack-A-Mal sandbox.
set -uo pipefail

RESULT_DIR=$(realpath "$1")
PAM_SHA=$2
PAM="$RESULT_DIR/pack-a-mal"
OUT="$RESULT_DIR/verification"
mkdir -p "$OUT"

exit_code=$(cat "$PAM/analysis-exit-code.txt" 2>/dev/null || echo "missing")

# Probe reports are named install-<uuid>.json; look only in Pack-A-Mal output dirs.
# Reports reassembled from Pack-A-Mal file-write results land in probe/.
find "$PAM" "$RESULT_DIR/probe" -type f -name 'install-*.json' ! -name '*.tmp' > "$OUT/probe-reports-in-pack-a-mal-output.txt"
if [ -s "$OUT/probe-reports-in-pack-a-mal-output.txt" ]; then recovered=true; else recovered=false; fi

# Did Pack-A-Mal ever start its inner (podman) sandbox? Look for sandbox lifecycle in its logs.
if grep -rqiE 'podman (run|create|exec)|runsc|Dynamic analysis (aborted|completed)|Starting dynamic analysis' "$PAM/logs" 2>/dev/null; then
  inner_started=true
else
  inner_started=false
fi

# Which ecosystems does the built binary accept?
supported=$(grep -oE 'Available: [a-z, ]+' "$PAM/analyze-help.txt" 2>/dev/null | head -1 | sed 's/Available: //')

# npm lifecycle execution can only be claimed if the report came out of the sandbox.
lifecycle=$recovered

{
  echo "run_analysis.sh exit code:      $exit_code"
  echo "ecosystems accepted by binary:  ${supported:-unknown}"
  echo "inner sandbox started:          $inner_started"
  echo "probe report recovered:         $recovered"
  echo "lifecycle execution verified:   $lifecycle"
} | tee "$OUT/verification-summary.txt"

jq -n \
  --arg run_id "${GITHUB_RUN_ID:-local}" \
  --arg attempt "${GITHUB_RUN_ATTEMPT:-0}" \
  --arg arch "${RUNNER_ARCH:-unknown}" \
  --arg sha "$PAM_SHA" \
  --arg supported "${supported:-unknown}" \
  --arg exit_code "$exit_code" \
  --argjson inner "$inner_started" \
  --argjson recovered "$recovered" \
  --argjson lifecycle "$lifecycle" '
{
  experiment: "pack-a-mal-github-actions-vm",
  run_id: $run_id,
  run_attempt: $attempt,
  outer_environment: {
    type: "github-actions-ubuntu-hosted-vm",
    runner_label: "ubuntu-24.04",
    architecture: $arch,
    job_container_used: false
  },
  scanner: {
    name: "Pack-A-Mal",
    repository: "https://github.com/lyvd/Pack-A-Mal",
    commit: $sha,
    openssf_derived: true,
    openssf_commit_or_version: "not recorded upstream; closest identified base ossf/package-analysis 2539ef69223780040e5d50dc2fa115b20a0c95df (2024-10-14)",
    ecosystems_supported_by_built_binary: $supported
  },
  sandbox: {
    runtime: "docker (outer analysis container); podman + gVisor runsc inside it per source, not reached if inner_sandbox_started is false",
    inner_sandbox_started: $inner,
    gvisor_used: $inner,
    nested_container_used: $inner,
    privileged_execution_used: true,
    privileged_note: "scripts/run_analysis.sh hard-codes `docker run --privileged` for the analysis container"
  },
  package: {
    ecosystem: "npm",
    probe_version: "0.1.0",
    lifecycle_execution_verified: $lifecycle,
    probe_output_recovered: $recovered,
    run_analysis_exit_code: $exit_code
  },
  modification: {
    researcher_modified: true,
    description: "npm ecosystem restored from ossf/package-analysis 2539ef6; upstream gcr.io/ossf-malware-analysis/dynamic-analysis sandbox via -sandbox-image; gVisor release 20260216; runsc strace-log-size 1048576",
    patch: "setup/pack-a-mal-modifications.patch"
  },
  outcome: (if $recovered then "success-researcher-modified" else "failed-no-probe-report-from-sandbox" end)
}' > "$RESULT_DIR/experiment-manifest.json"

[ "$recovered" = true ]
