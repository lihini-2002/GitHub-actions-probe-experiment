#!/usr/bin/env bash
# Write the run's FV8 metadata, harness classification, experiment manifest
# and README. Runs after the probe has finished (if: always()), from files
# the earlier steps produced; any value that could not be determined is null.
#
#   <out>/fv8-metadata.json          what runtime was used and where it came from
#   <out>/harness-classification.json  what the harness could verify
#   <out>/experiment-manifest.json   summary record for the study
#   <out>/README.md
#
# Usage: write-metadata.sh <out-dir> <fv8|control> <npm-host> <v8-options|none> \
#          <runtime-cache-hit:true|false> <probe.tgz>
set -uo pipefail

OUT=$1
VARIANT=$2
NPM_HOST=$3
V8_OPTIONS=$4
CACHE_HIT=$5
TARBALL=$6

json_or_null() { if [ -f "$1" ] && jq -e . "$1" >/dev/null 2>&1; then jq -c . "$1"; else echo null; fi; }
check_passed() { if [ -f "$OUT/checks/$1.json" ]; then jq '.passed' "$OUT/checks/$1.json"; else echo null; fi; }
count_matches() { local n; n=$(grep -ac "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
check_named() {  # <stage> <substring of check name> -> true/false/null
  if [ -f "$OUT/checks/$1.json" ]; then
    jq --arg s "$2" '[.results[] | select(.check | contains($s)) | .passed] | if length == 0 then null else all end' "$OUT/checks/$1.json"
  else echo null; fi
}

report=$(find "$OUT/probe" -maxdepth 1 -type f -name 'install-*.json' 2>/dev/null | sort | head -1)
reports=$(find "$OUT/probe" -maxdepth 1 -type f -name 'install-*.json' 2>/dev/null | wc -l)
P="$OUT/install/probe"

build_info=$(json_or_null "$OUT/runtime/build-info.json")
runtime_info=$(json_or_null "$OUT/runtime/runtime-info.json")
released=$(json_or_null "$OUT/fv8/released-build.json")
run_paths=$(json_or_null "$P/run-paths.json")
probe_versions=null
[ -n "$report" ] && probe_versions=$(jq -c '{node: .properties["Node.js version"].value, v8: .properties["V8 engine version"].value,
  npm: .properties["Package-manager version"].value, lifecycle_event: .properties["npm lifecycle event name"].value,
  phase, package}' "$report" 2>/dev/null || echo null)

banner=false
grep -qxF '> npm-probing-package@0.1.0 postinstall' "$P/npm-install.log" 2>/dev/null && banner=true
window_markers=$(count_matches 'Found match for API: ' "$P/postinstall-window.log")
total_markers=$(count_matches 'Found match for API: ' "$P/npm-install.log")
lifecycle_vv8=$(find "$P/vv8-logs/lifecycle" -type f 2>/dev/null | wc -l)
npm_vv8=$(find "$P/vv8-logs/npm" -type f 2>/dev/null | wc -l)

jq -n \
  --arg variant "$VARIANT" \
  --arg npm_host "$NPM_HOST" \
  --arg v8_options "$V8_OPTIONS" \
  --argjson cache_hit "$CACHE_HIT" \
  --argjson build_info "$build_info" \
  --argjson runtime_info "$runtime_info" \
  --argjson released "$released" \
  --argjson run_paths "$run_paths" \
  --argjson probe_versions "$probe_versions" \
  --argjson reports "$reports" \
  --argjson banner "$banner" \
  --argjson window_markers "$window_markers" \
  --argjson total_markers "$total_markers" \
  --argjson lifecycle_vv8 "$lifecycle_vv8" \
  --argjson npm_vv8 "$npm_vv8" \
  --argjson runtime_ok "$(check_passed runtime)" \
  --argjson smoke_ok "$(check_passed smoke)" \
  --argjson probe_ok "$(check_passed probe)" \
  --argjson rt_forced "$(check_named runtime 'force-executed all never-taken canary branches')" \
  --argjson rt_not_forced "$(check_named runtime 'no canary branch was force-executed')" \
  --argjson smoke_forced "$(check_named smoke 'force-executed all never-taken branches')" \
  --argjson smoke_not_forced "$(check_named smoke 'no branch was force-executed')" \
  --argjson probe_on_runtime "$(check_named probe 'probe ran on the experiment runtime')" \
  --argjson probe_vv8 "$(check_named probe 'VisibleV8 log records npm-probing-package/scripts/postinstall.js')" \
  --argjson probe_no_vv8 "$(check_named probe 'no VisibleV8 logs anywhere')" \
  '
  ($runtime_info != null) as $runtime_available
  | (($run_paths // {}).installed_package_dir_exists // false) as $installed
  | ($reports > 0) as $report
  | (if $variant == "fv8" then
       (if $rt_forced == true and $smoke_forced == true then true
        elif $rt_forced == false or $smoke_forced == false then false else null end)
     else
       (if $rt_not_forced == true and $smoke_not_forced == true then false else null end)
     end) as $forced
  | (if $variant == "fv8" then
       (if $probe_on_runtime == true and $probe_vv8 == true and $runtime_ok == true then true
        elif $report then false else null end)
     else false end) as $under_fv8
  | {
      variant: $variant,
      runtime_available: $runtime_available,
      package_installed: $installed,
      postinstall_banner_seen: $banner,
      probe_report_recovered: $report,
      probe_reports_recovered: $reports,
      probe_ran_on_experiment_runtime: $probe_on_runtime,
      probe_visiblev8_trace_found: (if $variant == "fv8" then $probe_vv8 else false end),
      forced_execution_enabled: $forced,
      forced_execution_evidence: {
        runtime_canary_forced_all_branches: $rt_forced,
        lifecycle_canary_forced_all_branches: $smoke_forced,
        control_runtime_canary_forced_nothing: $rt_not_forced,
        control_lifecycle_canary_forced_nothing: $smoke_not_forced,
        found_match_lines_in_probe_install_log: $total_markers,
        found_match_lines_in_postinstall_window: $window_markers,
        postinstall_window_note: "Lines between npm'"'"'s \"> npm-probing-package@0.1.0 postinstall\" banner and npm'"'"'s next own output. FV8 prints these when it force-compiles a branch that references a targeted API; attribution to the probe process is positional, not exact."
      },
      visiblev8_logs: { lifecycle_dir: $lifecycle_vv8, npm_work_dir: $npm_vv8 },
      probe_executed_under_fv8: $under_fv8,
      checks_passed: { runtime: $runtime_ok, smoke: $smoke_ok, probe: $probe_ok },
      experiment_valid: ($runtime_ok == true and $smoke_ok == true and $probe_ok == true),
      label: (
        if $runtime_available | not then "runtime_unavailable"
        elif $installed | not then "install_failed"
        elif ($report | not) and ($banner | not) then "installed_lifecycle_not_executed"
        elif $report | not then "lifecycle_ran_no_probe_output"
        elif $probe_on_runtime != true then "probe_executed_under_ordinary_node"
        elif $variant == "control" then
          (if $probe_no_vv8 == true and $runtime_ok == true then "probe_executed_under_control_runtime_verified"
           else "probe_executed_under_control_runtime_unverified" end)
        elif $under_fv8 == true and $forced == true then "probe_executed_under_fv8_instrumentation_forced_execution_active"
        elif $under_fv8 == true then "probe_executed_under_fv8_instrumentation_forced_execution_unverified"
        else "probe_executed_on_fv8_runtime_build_instrumentation_unverified" end
      ),
      label_meanings: {
        runtime_unavailable: "The runtime was not built/restored or does not start.",
        install_failed: "npm did not install the package.",
        installed_lifecycle_not_executed: "Package installed; npm never started its postinstall.",
        lifecycle_ran_no_probe_output: "npm started the postinstall but no probe report was produced.",
        probe_executed_under_ordinary_node: "A report exists but the Node.js/V8 versions it saw are not the experiment runtime.",
        probe_executed_on_fv8_runtime_build_instrumentation_unverified: "Report came from the FV8-patched Node.js but no VisibleV8 record of the probe script was found.",
        probe_executed_under_fv8_instrumentation_forced_execution_unverified: "Probe script recorded by VisibleV8 inside the FV8 runtime; forced execution not demonstrated by the canaries.",
        probe_executed_under_fv8_instrumentation_forced_execution_active: "Probe script recorded by VisibleV8 inside the FV8 runtime, and the same runtime force-executed never-taken branches both directly and through the npm lifecycle.",
        probe_executed_under_control_runtime_verified: "Control: report came from the unpatched build and no FV8 instrumentation was observed.",
        probe_executed_under_control_runtime_unverified: "Control: report came from the control build but a control check failed."
      }
    }' > "$OUT/harness-classification.json"

jq -n \
  --arg variant "$VARIANT" \
  --arg npm_host "$NPM_HOST" \
  --arg v8_options "$V8_OPTIONS" \
  --argjson cache_hit "$CACHE_HIT" \
  --argjson build_info "$build_info" \
  --argjson runtime_info "$runtime_info" \
  --argjson released "$released" \
  '{
    variant: $variant,
    fv8_upstream: {
      repository: "https://github.com/wspr-ncsu/FV8",
      commit: ($build_info.fv8_commit // null),
      paper: "FV8: A Forced Execution JavaScript Engine for Detecting Evasive Techniques (Pantelaios & Kapravelos, USENIX Security 2024, arXiv:2405.13175)",
      released_build: $released
    },
    runtime: {
      kind: (if $variant == "fv8" then "Node.js built with FV8 V8 patch (researcher reconstruction)" else "Node.js built without FV8 (matched control)" end),
      node_repository: ($build_info.node_repository // null),
      node_commit: ($build_info.node_commit // null),
      node_version: ($runtime_info.version // null),
      v8_version: ($runtime_info.versions.v8 // null),
      node_bundled_v8_version: ($build_info.node_bundled_v8_version // null),
      fv8_patch: ($build_info.fv8_patch // null),
      fv8_patch_sha256: ($build_info.fv8_patch_sha256 // null),
      fv8_patch_applied: (if $build_info == null then null else $build_info.fv8_patch_applied end),
      fv8_patch_as_released: (if $build_info == null then null
        elif ($build_info | has("fv8_patch_as_released")) then $build_info.fv8_patch_as_released
        else $build_info.fv8_patch_applied end),
      researcher_fv8_fixes: (if $build_info == null then null else ($build_info.researcher_fv8_fixes // []) end),
      fv8_patch_apply_options: ($build_info.fv8_patch_apply_options // null),
      compat_header: ($build_info.compat_header // null),
      compat_header_sha256: ($build_info.compat_header_sha256 // null),
      v8_options_baked_in: ($runtime_info.node_v8_options // null),
      v8_options_requested: (if $v8_options == "none" then null else $v8_options end),
      configure: ($build_info.configure // null),
      toolchain: ($build_info.toolchain // null),
      node_binary_sha256: ($build_info.node_binary_sha256 // null),
      bundled_npm_version: ($build_info.bundled_npm_version // null),
      built_in_run: ($build_info.built_in_run // null),
      restored_from_actions_cache: $cache_hit,
      build_method: (if $cache_hit then "restored from actions/cache (built by run \($build_info.built_in_run // "?") with the same pinned inputs)" else "built from source in this run" end),
      forced_execution_runtime_flag: "none: FV8 forced execution is compiled into V8'"'"'s bytecode generator and is always on in the patched build",
      visiblev8_property_tracing: "VV8_TRACE_PROPERTIES not defined (the patch does not define it); API calls and script records are logged, property get/set tracing is compiled out"
    },
    npm_harness: {
      npm_host: $npm_host,
      npm_runs_under: (if $npm_host == "fv8-node" then "the experiment runtime" else "the runner'"'"'s setup-node Node.js 22" end),
      lifecycle_node: "the experiment runtime (its bin/ is first on PATH for the npm process)",
      command: "npm install <npm-probing-package-0.1.0.tgz> --foreground-scripts (fresh empty directory)"
    },
    provenance: {
      from_fv8_authors_unmodified: ["tools/fv8/patches/V8_patch_122.diff (applied verbatim, no fuzz)"],
      inspected_not_executed: ["tools/fv8/deb_files/chromium-browser-stable_122.0.6261.111-1_amd64.deb"],
      researcher_reconstruction: ([
        "choice of Node.js main@07f481cf (V8 12.2.281.27) as the host for the patch",
        "experiments/fv8/compat/build/build_config.h (Chromium BUILDFLAG macros; no FV8 logic)",
        "V8 flags baked in with configure --v8-options (authors pass --js-flags in Chromium)",
        "npm harness: PATH-based lifecycle node selection, canary smoke package, verification"
      ] + [($build_info.researcher_fv8_fixes // [])[] | "researcher fix to FV8 code: \(.patch) (\(.change))"])
    }
  }' > "$OUT/fv8-metadata.json"

cls="$OUT/harness-classification.json"
jq -n \
  --arg variant "$VARIANT" \
  --arg arch "$(uname -m)" \
  --arg runner_arch "${RUNNER_ARCH:-}" \
  --arg run_id "${GITHUB_RUN_ID:-}" \
  --arg run_attempt "${GITHUB_RUN_ATTEMPT:-}" \
  --arg npm_host "$NPM_HOST" \
  --arg tarball "$(basename "$TARBALL")" \
  --arg tarball_sha "$(sha256sum "$TARBALL" | cut -d' ' -f1)" \
  --argjson cls "$(json_or_null "$cls")" \
  --argjson meta "$(json_or_null "$OUT/fv8-metadata.json")" \
  --argjson run_paths "$run_paths" \
  --argjson probe_versions "$probe_versions" \
  '{
    experiment: (if $variant == "fv8" then "fv8" else "fv8-control" end),
    outer_environment: "github-actions-ubuntu-hosted-vm",
    analysis_family: (if $variant == "fv8" then "FV8" else "FV8 matched control (no FV8)" end),
    run_id: $run_id,
    run_attempt: $run_attempt,
    fv8_commit: $meta.fv8_upstream.commit,
    base_v8_version: $meta.fv8_upstream.released_build.embedded_v8_version,
    base_chromium_version: $meta.fv8_upstream.released_build.chromium_version,
    runtime_v8_version: $meta.runtime.v8_version,
    node_commit: $meta.runtime.node_commit,
    node_version: $meta.runtime.node_version,
    npm_version: ($run_paths.npm_version // null),
    npm_host: $npm_host,
    architecture: $arch,
    runner_architecture: $runner_arch,
    fv8_patch_applied: $meta.runtime.fv8_patch_applied,
    fv8_patch_as_released: $meta.runtime.fv8_patch_as_released,
    fv8_researcher_fixes: ($meta.runtime.researcher_fv8_fixes // [] | map(.name)),
    v8_options: $meta.runtime.v8_options_baked_in,
    runtime_restored_from_cache: $meta.runtime.restored_from_actions_cache,
    forced_execution_enabled: $cls.forced_execution_enabled,
    npm_harness_type: "researcher_reconstructed_fv8_npm_harness",
    probe_execution_verified: ($cls.probe_report_recovered and ($probe_versions.lifecycle_event == "postinstall") and ($probe_versions.phase == "postinstall")),
    probe_executed_under_fv8: $cls.probe_executed_under_fv8,
    reconstruction_required: true,
    harness_label: $cls.label,
    experiment_valid: $cls.experiment_valid,
    package: { name: "npm-probing-package", version: "0.1.0", tarball: $tarball, tarball_sha256: $tarball_sha },
    probe_saw: $probe_versions
  }' > "$OUT/experiment-manifest.json"

if [ "$VARIANT" = fv8 ]; then
  title="FV8 experiment run"
  layers='GitHub infrastructure
→ GitHub Actions ubuntu-24.04 hosted VM (x64)
→ Node.js main@07f481cf with FV8 patch (V8 12.2.281.27 + FV8 forced execution + VisibleV8 logging)
→ npm install <tarball> --foreground-scripts   (npm host: '"$NPM_HOST"')
→ sh -c "node scripts/postinstall.js"  (node = FV8 runtime)
→ npm-probing-package postinstall'
else
  title="FV8 matched-control run"
  layers='GitHub infrastructure
→ GitHub Actions ubuntu-24.04 hosted VM (x64)
→ Node.js main@07f481cf, unmodified (V8 12.2.281.27), same build options as the FV8 run
→ npm install <tarball> --foreground-scripts   (npm host: '"$NPM_HOST"')
→ sh -c "node scripts/postinstall.js"  (node = control runtime)
→ npm-probing-package postinstall'
fi

cat > "$OUT/README.md" <<EOF
# $title (${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0})

Harness label: \`$(jq -r .label "$cls" 2>/dev/null)\`
Experiment valid: \`$(jq -r .experiment_valid "$cls" 2>/dev/null)\`

\`\`\`text
$layers
\`\`\`

FV8 (https://github.com/wspr-ncsu/FV8) is released as an instrumented Chromium
build plus a V8 source patch. It has no Node.js runtime and no npm workflow.
This run is a researcher reconstruction: the authors' V8 patch, applied
unmodified, compiled into Node.js. See docs/fv8-setup-notes.md in the
experiment repository.

| Path | Contents |
| --- | --- |
| \`probe/install-*.json\` | the probe's own report (what the package observed) |
| \`environment-metadata.json\` | runner/OS/CPU/memory, recorded before the runtime was built or run |
| \`fv8-metadata.json\` | runtime provenance: FV8 commit, patch, Node.js commit, versions, cache |
| \`harness-classification.json\` | what the harness verified, and the run label |
| \`experiment-manifest.json\` | one-record summary of the run |
| \`checks/{runtime,smoke,probe}.json\` | individual verification checks |
| \`fv8/released-build.json\` | the authors' Chromium .deb, inspected (not run) |
| \`runtime/\` | build info, patch-apply log, source diff, runtime self-test and canary |
| \`install/smoke/\` | npm install of the harness canary package (not the probe) |
| \`install/probe/npm-install.log\` | execution log of the probe install |
| \`install/probe/vv8-logs/\` | VisibleV8 logs (lifecycle process; npm process gzipped) |
| \`install/probe/forced-execution-markers.txt\` | FV8 "Found match for API" lines |
| \`logs/setup-build.log\` | runtime build log (from the build run if restored from cache) |
| \`logs/github-host.txt\` | raw runner inspection output |

The probe's report and the experiment metadata are kept in separate files; no
experiment metadata was made visible to the probe.
EOF

cat "$OUT/harness-classification.json" "$OUT/experiment-manifest.json"
