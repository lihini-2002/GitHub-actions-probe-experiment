#!/usr/bin/env bash
# Add the job-container layer to the metadata written by the hosted-VM
# experiment's experiments/fv8/write-metadata.sh (reused unchanged):
#   <out>/container-metadata.json   two-layer record: outer hosted runner,
#                                   job container, analysis environment
#   <out>/experiment-manifest.json  same schema as the VM experiment, with
#                                   `experiment` renamed and the container
#                                   layer added (`execution_environment`)
#   <out>/README.md                 rewritten for the container layering
# Values come from files recorded during the run; anything not observable from
# inside the container is null.
#
# Usage: write-container-metadata.sh <out-dir> <fv8|control> <runner-label> \
#          <image-ref> <image-platform-digest>
set -uo pipefail

OUT=$1
VARIANT=$2
RUNNER_LABEL=$3
IMAGE_REF=$4
IMAGE_DIGEST=$5

json_or_null() { if [ -f "$1" ] && jq -e . "$1" >/dev/null 2>&1; then jq -c . "$1"; else echo null; fi; }
or_null() { if [ -n "$1" ]; then jq -cn --arg v "$1" '$v'; else echo null; fi; }

if [ "$VARIANT" = fv8 ]; then experiment=fv8-container; else experiment=fv8-container-control; fi
before_probe=$(json_or_null "$OUT/container/before-probe.json")
build_layer=$(json_or_null "$OUT/container/runtime-build.json")
container_check=$(json_or_null "$OUT/checks/container.json")
manifest=$(json_or_null "$OUT/experiment-manifest.json")
meta=$(json_or_null "$OUT/fv8-metadata.json")
cls=$(json_or_null "$OUT/harness-classification.json")
envmeta=$(json_or_null "$OUT/environment-metadata.json")

jq -n \
  --arg experiment "$experiment" \
  --arg variant "$VARIANT" \
  --arg runner_label "$RUNNER_LABEL" \
  --arg image_ref "$IMAGE_REF" \
  --arg image_digest "$IMAGE_DIGEST" \
  --arg run_id "${GITHUB_RUN_ID:-}" \
  --arg run_attempt "${GITHUB_RUN_ATTEMPT:-}" \
  --argjson runner_os "$(or_null "${RUNNER_OS:-}")" \
  --argjson runner_arch "$(or_null "${RUNNER_ARCH:-}")" \
  --argjson runner_environment "$(or_null "${RUNNER_ENVIRONMENT:-}")" \
  --argjson image_os "$(or_null "${ImageOS:-}")" \
  --argjson image_version "$(or_null "${ImageVersion:-}")" \
  --argjson job_container_id "$(or_null "${JOB_CONTAINER_ID:-}")" \
  --argjson layer "$before_probe" \
  --argjson build_layer "$build_layer" \
  --argjson container_check "$container_check" \
  --argjson manifest "$manifest" \
  --argjson meta "$meta" \
  --argjson cls "$cls" \
  --argjson envmeta "$envmeta" \
  '{
    experiment: $experiment,
    github: { run_id: $run_id, run_attempt: $run_attempt },
    outer_environment: {
      type: "github-actions-hosted-runner",
      runner_label: $runner_label,
      runner_os: $runner_os,
      runner_arch: $runner_arch,
      runner_environment: $runner_environment,
      runner_image_os: $image_os,
      runner_image_version: $image_version,
      kernel_shared_with_container: ($layer.kernel),
      logical_cpus_visible: ($layer.logical_cpus),
      mem_total_kb_visible: ($layer.mem_total_kb),
      note: "All steps run inside the job container. Host values are those the runner passes into the container or that the shared kernel exposes; null means not observable from the container."
    },
    execution_environment: {
      type: "github-actions-job-container",
      container_image: $image_ref,
      container_image_digest: $image_digest,
      container_image_digest_kind: "linux/amd64 platform manifest",
      job_container_id: $job_container_id,
      os: ($layer.os),
      os_id: ($layer.os_id),
      os_version: ($layer.os_version),
      architecture: ($layer.machine),
      kernel: ($layer.kernel),
      hostname: ($layer.hostname),
      hostname_is_12_hex: ($layer.hostname_is_12_hex),
      pid1: ($layer.pid1),
      docker_marker_file: ($layer.docker_marker_file),
      root_filesystem_type: ($layer.root_filesystem_type),
      mountinfo_entries: ($layer.mountinfo_entries),
      cgroup: ($layer.cgroup),
      user: ($layer.user),
      user_gitconfig_present: ($layer.user_gitconfig_present),
      outer_node: ($envmeta.outer_node),
      runtime_built_in_container: (if $build_layer == null then null
        else ($build_layer.docker_marker_file == true and $build_layer.root_filesystem_type == "overlay") end),
      runtime_build_container_hostname: ($build_layer.hostname),
      container_layer_verified: ($container_check.passed)
    },
    analysis_environment: {
      scanner: (if $variant == "fv8" then "FV8" else "none (matched control: same Node.js build without the FV8 patch)" end),
      fv8_commit: ($manifest.fv8_commit),
      fv8_patch_applied: ($manifest.fv8_patch_applied),
      fv8_patch_as_released: ($manifest.fv8_patch_as_released),
      fv8_researcher_fixes: ($manifest.fv8_researcher_fixes),
      base_v8_version: ($manifest.base_v8_version),
      base_chromium_version: ($manifest.base_chromium_version),
      runtime_v8_version: ($manifest.runtime_v8_version),
      node_commit: ($manifest.node_commit),
      node_version: ($manifest.node_version),
      npm_version: ($manifest.npm_version),
      npm_host: ($manifest.npm_host),
      v8_options: ($manifest.v8_options),
      forced_execution_enabled: ($cls.forced_execution_enabled),
      npm_harness_type: ($manifest.npm_harness_type),
      runtime_restored_from_cache: ($manifest.runtime_restored_from_cache)
    }
  }' > "$OUT/container-metadata.json"

# Same manifest schema as the VM experiment, plus the container layer.
if [ "$manifest" != null ]; then
  jq --arg experiment "$experiment" --slurpfile cm "$OUT/container-metadata.json" '
    .experiment = $experiment
    | .analysis_family = (if $experiment == "fv8-container" then "FV8" else "FV8 matched control (no FV8)" end)
    | .execution_environment = {
        type: "github-actions-job-container",
        container_image: $cm[0].execution_environment.container_image,
        container_image_digest: $cm[0].execution_environment.container_image_digest,
        os: $cm[0].execution_environment.os,
        architecture: $cm[0].execution_environment.architecture,
        runtime_built_in_container: $cm[0].execution_environment.runtime_built_in_container,
        container_layer_verified: $cm[0].execution_environment.container_layer_verified
      }
    | .experiment_valid = (.experiment_valid == true and $cm[0].execution_environment.container_layer_verified == true)
  ' "$OUT/experiment-manifest.json" > "$OUT/experiment-manifest.json.tmp" \
    && mv "$OUT/experiment-manifest.json.tmp" "$OUT/experiment-manifest.json"
fi

if [ "$VARIANT" = fv8 ]; then
  runtime_line="→ FV8 runtime: Node.js main@07f481cf + FV8 V8 patch (V8 12.2.281.27, forced execution, VisibleV8 logs), built in the container"
  title="FV8 job-container experiment run"
else
  runtime_line="→ control runtime: Node.js main@07f481cf, unmodified (V8 12.2.281.27), built in the container"
  title="FV8 job-container matched-control run"
fi
cat > "$OUT/README.md" <<EOF
# $title (${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0})

Harness label: \`$(jq -r .label "$OUT/harness-classification.json" 2>/dev/null)\`
Container layer verified: \`$(jq -r .passed "$OUT/checks/container.json" 2>/dev/null)\`
Experiment valid: \`$(jq -r .experiment_valid "$OUT/experiment-manifest.json" 2>/dev/null)\`

\`\`\`text
GitHub infrastructure
→ GitHub Actions $RUNNER_LABEL hosted VM (outer layer)
→ GitHub Actions job container: $IMAGE_REF
$runtime_line
→ npm install <npm-probing-package-0.1.0.tgz> --foreground-scripts
→ sh -c "node scripts/postinstall.js"  (node = the experiment runtime)
→ npm-probing-package postinstall
\`\`\`

Same harness and file layout as the hosted-VM FV8 experiment
(docs/fv8-setup-notes.md), with the job-container layer added
(docs/fv8-container-setup.md).

| Path | Contents |
| --- | --- |
| \`probe/install-*.json\` | the probe's own report |
| \`container-metadata.json\` | two-layer record: outer hosted runner, job container, analysis environment |
| \`container/{before-build,before-probe,runtime-build}.{json,txt}\` | layer snapshots (OS, PID 1, cgroup/limits, mounts, hostname, marker files) |
| \`checks/container.json\` | checks that build, runtime, npm and probe ran inside the container |
| \`environment-metadata.json\` | runner/OS/CPU/memory as seen from the container, before the runtime |
| \`fv8-metadata.json\`, \`harness-classification.json\`, \`experiment-manifest.json\` | as in the VM experiment |
| \`checks/{runtime,smoke,probe}.json\` | as in the VM experiment |
| \`runtime/\`, \`install/\`, \`fv8/\` | as in the VM experiment |
| \`logs/container-setup.log\` | apt packages installed into the container |
| \`logs/setup-build.log\` | runtime build log |
EOF

cat "$OUT/container-metadata.json"
