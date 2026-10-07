#!/usr/bin/env bash
# Validate the Packj sandbox experiment. Packj's exit status is recorded but
# never taken as evidence: each check looks at what Packj and the probe
# actually produced.
#
# Usage:
#   verify-sandbox-run.sh sandbox  <out-dir>   Packj's sandbox started, with the default policy
#   verify-sandbox-run.sh install  <out-dir>   npm installed the probe inside the sandbox layer
#   verify-sandbox-run.sh probe    <out-dir> <expected-npm-version>
#   verify-sandbox-run.sh classify <out-dir>   outcome label; exit 0 only for a valid outcome
#
# sandbox/install/probe write <out-dir>/metadata/checks/<check>.json;
# classify writes <out-dir>/metadata/outcome.json.
set -uo pipefail

CHECK=$1
OUT=$2

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
PROBE_NAME=npm-probing-package
PROBE_VERSION=0.1.0
PROBE_KEY="$PROBE_NAME@$PROBE_VERSION"
LOGS="$OUT/packj/logs"
ACT="$OUT/packj/activity"
POLICY="$OUT/packj/policy"

mkdir -p "$OUT/metadata/checks"
RESULTS=()
FAILED=0

pass() { echo "PASS: $1"; RESULTS+=("$(jq -cn --arg c "$1" '{check:$c, passed:true}')"); }
fail() { echo "::error::FAIL: $1"; RESULTS+=("$(jq -cn --arg c "$1" '{check:$c, passed:false}')"); FAILED=1; }
expect() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }

finish() {
  printf '%s\n' "${RESULTS[@]}" | jq -s --arg check "$CHECK" --argjson failed "$FAILED" \
    '{check:$check, passed:($failed == 0), results:.}' > "$OUT/metadata/checks/$CHECK.json"
  exit "$FAILED"
}

path_of() { jq -r --arg k "$1" '.[$k] // empty' "$LOGS/run-paths.json" 2>/dev/null; }
first() { find "$1" -maxdepth 1 -type f -name "$2" 2>/dev/null | sort | head -1; }
probe_report() { first "$OUT/probe" 'install-*.json'; }
# Packj's console output without colour codes.
console() { sed 's/\x1b\[[0-9;]*m//g' "$OUT/packj/sandbox.log" 2>/dev/null; }
npm_logs() { cat "$LOGS"/npm-logs/*.log 2>/dev/null; }
# A file from the copy-on-write layer snapshot, by path suffix.
from_layer() { tar -xOzf "$ACT/sandbox-root.tar.gz" --wildcards "*$1" 2>/dev/null; }
count() { grep -cE "$1" 2>/dev/null || true; }

WORK=$(path_of work_dir)
LAYER_PKG="$WORK/node_modules/$PROBE_NAME"
LIFECYCLE_START="run $PROBE_KEY postinstall node_modules/$PROBE_NAME node scripts/postinstall.js"

case "$CHECK" in
  sandbox)
    expect "sandbox: console log was captured" test -s "$OUT/packj/sandbox.log"
    expect "sandbox: run paths were recorded" jq -e . "$LOGS/run-paths.json"
    expect "sandbox: Packj created its sandbox directory (/tmp/packj_sandbox_*)" \
      test -n "$(path_of sandbox_dir)"
    expect "sandbox: Packj loaded upstream's unmodified .packj.yaml" \
      test "$(sha256sum < "$POLICY/packj.yaml" | cut -d' ' -f1)" = "$(sha256sum < "$REPO/tools/packj/.packj.yaml" | cut -d' ' -f1)"
    profile=$(first "$POLICY" 'rules_*.profile')
    expect "sandbox: Packj generated a rules profile" test -s "$profile"
    if [ -n "$profile" ]; then
      expect "sandbox: profile hides ~/ and / (default fs block rule)" \
        sh -c "grep -qxF '	hide:~/' '$profile' && grep -qxF '	hide:/' '$profile'"
      expect "sandbox: profile allows . (the npm project dir)" grep -qxF '	allow:.' "$profile"
      expect "sandbox: profile kills connections to 0.0.0.0 (default network block rule)" \
        grep -q '^	kill:0\.0\.0\.0:' "$profile"
      cat "$profile"
    fi
    expect "sandbox: no setup error (strace/libsbox/make) from Packj" \
      sh -c "! sed 's/\x1b\[[0-9;]*m//g' '$OUT/packj/sandbox.log' | grep -qE 'not found\. (Re-)?[Rr]un|\"make\" failed|Failed to parse rules'"
    events=$(first "$ACT" 'root_*.csv')
    expect "sandbox: sandbox event log (root_*.csv) exists and is non-empty" test -s "$events"
    trace=$(first "$ACT" 'trace_*.log')
    expect "sandbox: Packj's strace -fc summary (trace_*.log) exists and is non-empty" test -s "$trace"
    expect "sandbox: copy-on-write layer was captured" test -s "$ACT/sandbox-root.tar.gz"
    finish
    ;;

  install)
    expect "install: Packj staged the probe tarball for npm" test -s "$(path_of input)"
    expect "install: npm wrote $PROBE_NAME into the sandbox layer (not the host)" \
      grep -qF "./${LAYER_PKG#/}/package.json" "$ACT/sandbox-root-files.txt"
    manifest=$(from_layer "${LAYER_PKG}/package.json")
    expect "install: package installed in the sandbox layer is $PROBE_KEY" \
      jq -e --arg n "$PROBE_NAME" --arg v "$PROBE_VERSION" '.name == $n and .version == $v' <<<"$manifest"
    expect "install: sandbox event log records files of the installed probe" \
      grep -qF "$LAYER_PKG" "$(first "$ACT" 'root_*.csv')"
    expect "install: npm logged the probe's postinstall starting (lifecycle attempted)" \
      grep -qF "$LIFECYCLE_START" <(npm_logs)
    grep -hE "run $PROBE_KEY postinstall" <(npm_logs) || true
    expect "install: Packj reached its review (activity summary printed)" \
      test "$(path_of review_menu_reached)" = true
    console | sed -n '/^# Review changes/,$p' | head -60
    finish
    ;;

  probe)
    EXPECTED_NPM=$3
    report=$(probe_report)
    count_reports=$(find "$OUT/probe" -maxdepth 1 -type f -name 'install-*.json' 2>/dev/null | wc -l)
    echo "Probe reports recovered: $count_reports"
    expect "probe: an install-*.json report was recovered" test -n "$report"
    if [ -z "$report" ]; then finish; fi
    expect "probe: exactly one report (one postinstall run)" test "$count_reports" -eq 1
    expect "probe: report was written inside the sandbox layer" \
      grep -qF "${LAYER_PKG#/}/results/$(basename "$report")" "$ACT/sandbox-root-files.txt"
    expect "probe: report is valid JSON" jq -e . "$report"
    expect "probe: report phase is postinstall" jq -e '.phase == "postinstall"' "$report"
    expect "probe: report is from $PROBE_KEY" \
      jq -e --arg n "$PROBE_NAME" --arg v "$PROBE_VERSION" '.package.name == $n and .package.version == $v' "$report"
    expect "probe: report has properties" jq -e '.properties | length > 0' "$report"
    expect "probe: npm lifecycle event seen by the probe is postinstall" \
      jq -e '.properties["npm lifecycle event name"].value == "postinstall"' "$report"
    expect "probe: package manager seen by the probe is npm $EXPECTED_NPM" \
      jq -e --arg v "$EXPECTED_NPM" '.properties["Package-manager identity"].value == "npm" and .properties["Package-manager version"].value == $v' "$report"
    expect "probe: probe process was being traced (TracerPid != 0)" \
      jq -e '.properties["Own process tracer status"].value == true' "$report"
    expect "probe: LD_PRELOAD was present (Packj preloads libsbox.so)" \
      jq -e '.properties["LD_PRELOAD variable presence"].value == true' "$report"
    expect "probe: probe's ancestors include strace started by Packj's Python" \
      jq -e '.properties["Bounded ancestor-process executable basename sequence"].value as $a
             | ($a | index("strace")) as $i
             | $i != null and ($a[$i + 1:] | any(startswith("python")))' "$report"
    jq '{
      "Package-manager version": .properties["Package-manager version"],
      "Node.js version": .properties["Node.js version"],
      "Own process tracer status": .properties["Own process tracer status"],
      "LD_PRELOAD variable presence": .properties["LD_PRELOAD variable presence"],
      "Bounded ancestor-process executable basename sequence": .properties["Bounded ancestor-process executable basename sequence"],
      status_counts: ([.properties[].status] | group_by(.) | map({key: .[0], value: length}) | from_entries)
    }' "$report"
    finish
    ;;

  classify)
    passed() { jq -e '.passed' "$OUT/metadata/checks/$1.json" >/dev/null 2>&1 && echo true || echo false; }
    sandbox_ok=$(passed sandbox)
    probe_ok=$(passed probe)
    report=$(probe_report)
    events=$(first "$ACT" 'root_*.csv')

    lifecycle_attempted=false
    { grep -qF "$LIFECYCLE_START" <(npm_logs) || [ -n "$report" ] \
      || ls "$OUT"/probe/partial/install-*.json.tmp >/dev/null 2>&1; } && lifecycle_attempted=true
    lifecycle_result=$(grep -ohE "run $PROBE_KEY postinstall \{ code: [^}]*\}" <(npm_logs) | tail -1)

    # What Packj itself recorded as blocked. Filesystem "hide" rules are not
    # logged by Packj; their effect shows only in the probe's statuses.
    net_block=$(count ',BLOCK$' < "${events:-/dev/null}")
    net_allow=$(count ',ALLOW$' < "${events:-/dev/null}")
    kills=$(console | count 'Killing process|rule: KILL')
    not_allowed=$(console | count 'is not allowed|not allowed to call')
    packj_failed=$(console | grep -m1 '^Failed: ' || true)
    blocked=false
    [ "$net_block" -gt 0 ] || [ "$kills" -gt 0 ] || [ "$not_allowed" -gt 0 ] && blocked=true

    status_counts=null
    [ -n "$report" ] && status_counts=$(jq -c '[.properties[].status] | group_by(.) | map({key: .[0], value: length}) | from_entries' "$report" 2>/dev/null || echo null)

    outside=$(path_of probe_ran_outside_sandbox)
    # Packj reports a signal-killed strace as "installation error (-<signal>)".
    tracer_signal=$(sed -nE 's/^Failed: installation error \((-[0-9]+)\)!$/\1/p' <<<"$packj_failed")

    if [ "$sandbox_ok" != true ]; then
      if [ "$outside" = true ]; then
        # Packj's tracer failed and npm finished unconfined: not sandbox data.
        outcome=sandbox_failed_package_ran_outside
      else
        outcome=infrastructure_failure
      fi
    elif [ "$lifecycle_attempted" != true ]; then
      # Packj ran, but the probe's lifecycle script never started.
      if [ "$blocked" = true ] || [ -n "$packj_failed" ]; then
        outcome=sandbox_prevented_lifecycle
      else
        outcome=lifecycle_not_reached_unexplained
      fi
    elif [ "$probe_ok" = true ] && [ "$blocked" = false ]; then
      outcome=probe_completed_under_sandbox
    elif [ "$blocked" = true ]; then
      outcome=sandbox_blocked_probe_behavior
    elif [ "$probe_ok" = true ]; then
      outcome=probe_completed_under_sandbox
    else
      outcome=probe_checks_failed
    fi

    case "$outcome" in
      probe_completed_under_sandbox|sandbox_blocked_probe_behavior) valid=true ;;
      *) valid=false ;;
    esac

    jq -n \
      --arg outcome "$outcome" \
      --argjson valid "$valid" \
      --argjson sandbox_ok "$sandbox_ok" \
      --argjson probe_ok "$probe_ok" \
      --argjson lifecycle_attempted "$lifecycle_attempted" \
      --arg lifecycle_result "$lifecycle_result" \
      --argjson probe_output "$([ -n "$report" ] && echo true || echo false)" \
      --argjson partial "$(ls "$OUT"/probe/partial/* >/dev/null 2>&1 && echo true || echo false)" \
      --argjson activity "$([ -s "${events:-/dev/null}" ] && echo true || echo false)" \
      --argjson blocked "$blocked" \
      --argjson net_block "$net_block" \
      --argjson net_allow "$net_allow" \
      --argjson kills "$kills" \
      --argjson not_allowed "$not_allowed" \
      --arg packj_failed "$packj_failed" \
      --argjson status_counts "$status_counts" \
      --argjson outside "${outside:-false}" \
      --arg tracer_signal "$tracer_signal" \
      '{outcome: $outcome, experiment_valid: $valid,
        packj_sandbox_active: $sandbox_ok,
        packj_tracer_killed_by_signal: (if $tracer_signal == "" then null else ($tracer_signal | tonumber | -.) end),
        probe_ran_outside_sandbox: $outside,
        probe_lifecycle_attempted: $lifecycle_attempted,
        probe_lifecycle_result: (if $lifecycle_result == "" then null else $lifecycle_result end),
        probe_output_recovered: $probe_output,
        probe_checks_passed: $probe_ok,
        partial_probe_output: $partial,
        packj_activity_recovered: $activity,
        operations_blocked: $blocked,
        packj_blocks: {network_block_events: $net_block, network_allow_events: $net_allow,
                       process_kill_messages: $kills, not_allowed_messages: $not_allowed,
                       packj_failure_message: (if $packj_failed == "" then null else $packj_failed end)},
        probe_status_counts: $status_counts}' > "$OUT/metadata/outcome.json"
    cat "$OUT/metadata/outcome.json"
    echo "Outcome: $outcome"
    if [ "$valid" != true ]; then
      case "$outcome" in
        sandbox_prevented_lifecycle)
          echo "::error::Packj sandbox worked but prevented the probe's postinstall from running (not an infrastructure failure)" ;;
        sandbox_failed_package_ran_outside)
          echo "::error::Packj's sandbox failed${tracer_signal:+ (strace killed by signal ${tracer_signal#-})} and npm ran the probe OUTSIDE the sandbox; see probe-outside-sandbox/ and packj/diagnostics/" ;;
        *)
          echo "::error::No valid experiment outcome ($outcome)" ;;
      esac
      exit 1
    fi
    exit 0
    ;;

  *)
    echo "Unknown check: $CHECK" >&2
    exit 2
    ;;
esac
