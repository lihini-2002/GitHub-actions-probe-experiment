#!/usr/bin/env bash
# Validate one stage of the FV8 experiment (or its matched control) from the
# artifacts the runtime, npm and the probe actually produced. Exit statuses
# are recorded but never taken as evidence on their own.
#
# Usage:
#   verify-fv8-run.sh runtime <out-dir> <fv8|control> <expected-v8-options|none>
#   verify-fv8-run.sh smoke   <out-dir> <fv8|control>
#   verify-fv8-run.sh probe   <out-dir> <fv8|control>
#
# Each stage writes <out-dir>/checks/<stage>.json and exits non-zero on
# failure. Expectations differ by variant: the FV8 runtime must show FV8
# behaviour (forced branches, VisibleV8 logs); the control must show none.
set -uo pipefail

CHECK=$1
OUT=$2
VARIANT=$3

PROBE_NAME=npm-probing-package
PROBE_VERSION=0.1.0
FORCED_MARKERS='["forced:constant-false-if","forced:runtime-false-if","forced:never-entered-while"]'

mkdir -p "$OUT/checks"
RESULTS=()
FAILED=0

pass() { echo "PASS: $1"; RESULTS+=("$(jq -cn --arg c "$1" '{check:$c, passed:true}')"); }
fail() { echo "::error::FAIL: $1"; RESULTS+=("$(jq -cn --arg c "$1" '{check:$c, passed:false}')"); FAILED=1; }
expect() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }
finish() {
  printf '%s\n' "${RESULTS[@]}" | jq -s --arg check "$CHECK" --arg variant "$VARIANT" --argjson failed "$FAILED" \
    '{check:$check, variant:$variant, passed:($failed == 0), results:.}' > "$OUT/checks/$CHECK.json"
  exit "$FAILED"
}

RT="$OUT/runtime"
runtime_version() { jq -r '.version // empty' "$RT/runtime-info.json" 2>/dev/null; }
runtime_v8() { jq -r '.versions.v8 // empty' "$RT/runtime-info.json" 2>/dev/null; }
# The probe reports process.versions.node (no leading "v").
runtime_versions_node() { jq -r '.versions.node // empty' "$RT/runtime-info.json" 2>/dev/null; }
count_files() { find "$1" -type f 2>/dev/null | wc -l; }
# Does any VisibleV8 log in <dir> contain a '$' script record
# ("$<id>:<name>:<source>") whose name ends in <path-suffix>? ES modules are
# named by file:// URL, CommonJS scripts by absolute path.
vv8_names_script() { grep -lsaE "^\\\$[0-9]+:(file://)?/[^:]*$2:" "$1"/vv8-*.log | grep -q .; }
vv8_log_for_pid() { jq -e --arg p "$2" 'any(.[]; .pid == $p)' "$1/index.json"; }

case "$CHECK" in
  runtime)
    EXPECTED_V8_OPTIONS=$4
    info="$RT/runtime-info.json"
    expect "runtime: build provenance recorded" jq -e . "$RT/build-info.json"
    expect "runtime: built as variant '$VARIANT'" jq -e --arg v "$VARIANT" '.variant == $v' "$RT/build-info.json"
    expect "runtime: node binary is the one recorded at build time (cache integrity)" \
      test "$(cat "$RT/node-binary-sha256.txt" 2>/dev/null)" = "$(jq -r .node_binary_sha256 "$RT/build-info.json" 2>/dev/null)"
    expect "runtime: built from the pinned Node.js commit" \
      jq -e '.node_commit == "07f481cfcf1153336534dc5d3cd4c5c9770a72be"' "$RT/build-info.json"
    expect "runtime: started and reported its versions" jq -e '.version' "$info"
    expect "runtime: Node.js is v22.0.0-pre (pinned main commit)" jq -e '.version == "v22.0.0-pre"' "$info"
    expect "runtime: V8 is 12.2.281.27 (Node.js embedder build)" jq -e '.versions.v8 | startswith("12.2.281.27")' "$info"
    if [ "$EXPECTED_V8_OPTIONS" = none ]; then
      expect "runtime: no V8 options baked in" jq -e '.node_v8_options == null or .node_v8_options == ""' "$info"
    else
      expect "runtime: V8 options '$EXPECTED_V8_OPTIONS' baked in" \
        jq -e --arg o "$EXPECTED_V8_OPTIONS" '.node_v8_options == $o' "$info"
    fi
    expect "runtime: canary exited 0" test "$(cat "$RT/canary-exit-status.txt" 2>/dev/null)" = 0
    expect "runtime: canary reached its end" jq -e '.markers | index("start") != null and index("end") != null' "$RT/canary-markers.json"
    if [ "$VARIANT" = fv8 ]; then
      expect "runtime: FV8 patch applied at build time" jq -e '.fv8_patch_applied == true' "$RT/build-info.json"
      expect "runtime: binary contains FV8 forced-execution code" jq -e '.fv8_forced_execution_string' "$RT/binary-markers.json"
      expect "runtime: binary contains VisibleV8 logging code" jq -e '.visiblev8_log_name_pattern' "$RT/binary-markers.json"
      expect "runtime: FV8 force-executed all never-taken canary branches" \
        jq -e --argjson f "$FORCED_MARKERS" '. as $r | all($f[]; . as $m | $r.markers | index($m) != null)' "$RT/canary-markers.json"
      expect "runtime: FV8 reported force-compiling setTimeout branches" \
        grep -qa 'Found match for API: setTimeout' "$RT/canary.stdout.log"
      expect "runtime: canary run wrote a VisibleV8 log" test "$(count_files "$RT/canary-vv8-logs")" -gt 0
      expect "runtime: VisibleV8 log records the canary script" vv8_names_script "$RT/canary-vv8-logs" 'canary\.cjs'
    else
      expect "runtime: no FV8 patch applied" jq -e '.fv8_patch_applied == false' "$RT/build-info.json"
      expect "runtime: binary has no FV8 forced-execution code" jq -e '.fv8_forced_execution_string | not' "$RT/binary-markers.json"
      expect "runtime: binary has no VisibleV8 logging code" jq -e '.visiblev8_log_name_pattern | not' "$RT/binary-markers.json"
      expect "runtime: no canary branch was force-executed" jq -e '.markers == ["start","end"]' "$RT/canary-markers.json"
      expect "runtime: canary run wrote no VisibleV8 log" test "$(count_files "$RT/canary-vv8-logs")" -eq 0
    fi
    finish
    ;;

  smoke)
    S="$OUT/install/smoke"
    markers="$S/report/markers.json"
    expect "smoke: npm exited 0" test "$(cat "$S/npm-exit-status.txt" 2>/dev/null)" = 0
    expect "smoke: package installed" jq -e '.installed_package_dir_exists' "$S/run-paths.json"
    expect "smoke: postinstall ran and wrote its markers" jq -e . "$markers"
    [ -f "$markers" ] || finish
    expect "smoke: ran as the npm postinstall lifecycle event" jq -e '.npm_lifecycle_event == "postinstall"' "$markers"
    expect "smoke: lifecycle node was the experiment runtime ($(runtime_version), V8 $(runtime_v8))" \
      jq -e --arg n "$(runtime_version)" --arg v "$(runtime_v8)" '.node_version == $n and .v8_version == $v' "$markers"
    expect "smoke: lifecycle node executable is <runtime>/bin/node" \
      test "$(jq -r .exec_path "$markers")" = "$(jq -r .lifecycle_node_expected "$S/run-paths.json")"
    pid=$(jq -r .pid "$markers")
    if [ "$VARIANT" = fv8 ]; then
      expect "smoke: FV8 force-executed all never-taken branches in the lifecycle script" \
        jq -e --argjson f "$FORCED_MARKERS" '. as $r | all($f[]; . as $m | $r.markers | index($m) != null)' "$markers"
      expect "smoke: lifecycle process (pid $pid) wrote a VisibleV8 log" vv8_log_for_pid "$S/vv8-logs" "$pid"
      expect "smoke: VisibleV8 log records the lifecycle script canary.cjs" vv8_names_script "$S/vv8-logs/lifecycle" 'canary\.cjs'
    else
      expect "smoke: no branch was force-executed" jq -e '.markers == ["start","end"]' "$markers"
      expect "smoke: no VisibleV8 logs anywhere in the install" jq -e 'length == 0' "$S/vv8-logs/index.json"
    fi
    finish
    ;;

  probe)
    P="$OUT/install/probe"
    count=$(find "$OUT/probe" -maxdepth 1 -type f -name 'install-*.json' 2>/dev/null | wc -l)
    report=$(find "$OUT/probe" -maxdepth 1 -type f -name 'install-*.json' 2>/dev/null | sort | head -1)
    echo "Probe reports recovered: $count"
    expect "probe: npm exited 0" test "$(cat "$P/npm-exit-status.txt" 2>/dev/null)" = 0
    expect "probe: package installed under node_modules" jq -e '.installed_package_dir_exists' "$P/run-paths.json"
    expect "probe: npm ran the postinstall lifecycle step" \
      grep -qxF "> $PROBE_NAME@$PROBE_VERSION postinstall" "$P/npm-install.log"
    expect "probe: an install-*.json report was recovered" test -n "$report"
    [ -n "$report" ] || finish
    expect "probe: exactly one report (one postinstall run)" test "$count" -eq 1
    expect "probe: report is valid JSON" jq -e . "$report"
    expect "probe: report phase is postinstall" jq -e '.phase == "postinstall"' "$report"
    expect "probe: report is from $PROBE_NAME@$PROBE_VERSION" \
      jq -e --arg n "$PROBE_NAME" --arg v "$PROBE_VERSION" '.package.name == $n and .package.version == $v' "$report"
    expect "probe: npm lifecycle event seen by the probe is postinstall" \
      jq -e '.properties["npm lifecycle event name"].value == "postinstall"' "$report"
    expect "probe: package manager seen by the probe is npm $(jq -r .npm_version "$P/run-paths.json")" \
      jq -e --arg v "$(jq -r .npm_version "$P/run-paths.json")" \
        '.properties["Package-manager identity"].value == "npm" and .properties["Package-manager version"].value == $v' "$report"
    expect "probe: probe ran on the experiment runtime, not the runner's Node.js ($(runtime_versions_node), V8 $(runtime_v8))" \
      jq -e --arg n "$(runtime_versions_node)" --arg v "$(runtime_v8)" \
        '.properties["Node.js version"].value == $n and .properties["V8 engine version"].value == $v' "$report"
    if [ "$VARIANT" = fv8 ]; then
      expect "probe: the probe's lifecycle process wrote VisibleV8 logs in its package dir" \
        test "$(count_files "$P/vv8-logs/lifecycle")" -gt 0
      expect "probe: VisibleV8 log records $PROBE_NAME/scripts/postinstall.js (executed under FV8 instrumentation)" \
        vv8_names_script "$P/vv8-logs/lifecycle" "$PROBE_NAME/scripts/postinstall\\.js"
    else
      expect "probe: no VisibleV8 logs anywhere in the install" jq -e 'length == 0' "$P/vv8-logs/index.json"
    fi
    jq '{
      "Node.js version": .properties["Node.js version"],
      "V8 engine version": .properties["V8 engine version"],
      "Node.js executable normalized path template": .properties["Node.js executable normalized path template"],
      "Package-manager identity": .properties["Package-manager identity"],
      "Package-manager version": .properties["Package-manager version"],
      "npm lifecycle event name": .properties["npm lifecycle event name"]
    }' "$report"
    finish
    ;;

  *)
    echo "Unknown check: $CHECK" >&2
    exit 2
    ;;
esac
