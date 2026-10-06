#!/usr/bin/env bash
# Validate one stage of the LATCH experiment. A successful `npm install` is not
# treated as evidence on its own: each check looks at the artifacts LATCH and
# the probe actually produced, and links them to each other.
#
# Usage:
#   verify-latch-run.sh smoke    <out-dir>
#   verify-latch-run.sh probe    <out-dir> <expected-latch-npm-version>
#   verify-latch-run.sh trace    <out-dir>
#   verify-latch-run.sh manifest <out-dir>
#
# Each check writes <out-dir>/metadata/checks/<check>.json and exits non-zero
# on failure.
set -uo pipefail

CHECK=$1
OUT=$2

PROBE_NAME=npm-probing-package
PROBE_KEY=npm-probing-package@0.1.0
SMOKE_KEY=latch-smoke-package@1.0.0

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

# Per-process strace files for one lifecycle script: <key>_<script>.<pid>
strace_files() {
  find "$1/straces/$2" -maxdepth 1 -type f -name "$2_$3.*" 2>/dev/null | grep -E '\.[0-9]+$' | sort
}

# Read the strace file list into the global array `files` (bash 3 compatible).
load_files() {
  files=()
  while IFS= read -r f; do files+=("$f"); done < <(strace_files "$@")
}

probe_report() {
  find "$OUT/probe" -maxdepth 1 -type f -name 'install-*.json' 2>/dev/null | sort | head -1
}

case "$CHECK" in
  smoke)
    LATCH="$OUT/latch/smoke"
    load_files "$LATCH" "$SMOKE_KEY" postinstall
    echo "Smoke postinstall strace files: ${#files[@]}"
    expect "smoke: LATCH wrote postinstall strace files" test "${#files[@]}" -gt 0
    if [ "${#files[@]}" -eq 0 ]; then finish; fi
    expect "smoke: postinstall strace files are non-empty" test -n "$(cat "${files[@]}" 2>/dev/null)"
    expect "smoke: postinstall exited 0 under strace (_finished marker)" \
      test -f "$LATCH/straces/$SMOKE_KEY/${SMOKE_KEY}_postinstall_finished"
    expect "smoke: trace shows sh -c running the lifecycle command" \
      grep -qhE 'execve\("[^"]*/sh", \["sh", "-c", "node -e' "${files[@]}"
    expect "smoke: trace shows the script reading package.json" \
      grep -qhE 'open(at)?\(.*"package.json"' "${files[@]}"
    finish
    ;;

  probe)
    EXPECTED_NPM=$3
    report=$(probe_report)
    count=$(find "$OUT/probe" -maxdepth 1 -type f -name 'install-*.json' 2>/dev/null | wc -l)
    echo "Probe reports recovered: $count"
    expect "probe: an install-*.json report was recovered" test -n "$report"
    if [ -z "$report" ]; then finish; fi
    [ "$count" -gt 1 ] && echo "::warning::$count probe reports found; checking $report"
    expect "probe: report is valid JSON" jq -e . "$report"
    expect "probe: report phase is postinstall" jq -e '.phase == "postinstall"' "$report"
    expect "probe: report is from $PROBE_NAME" jq -e --arg n "$PROBE_NAME" '.package.name == $n' "$report"
    expect "probe: report has properties" jq -e '.properties | length > 0' "$report"
    expect "probe: npm lifecycle event seen by the probe is postinstall" \
      jq -e '.properties["npm lifecycle event name"].value == "postinstall"' "$report"
    expect "probe: package manager seen by the probe is LATCH's npm $EXPECTED_NPM" \
      jq -e --arg v "$EXPECTED_NPM" '.properties["Package-manager version"].value == $v' "$report"
    expect "probe: probe process was being traced (TracerPid != 0)" \
      jq -e '.properties["Own process tracer status"].value == true' "$report"
    jq '{
      "Package-manager identity": .properties["Package-manager identity"],
      "Package-manager version": .properties["Package-manager version"],
      "npm lifecycle event name": .properties["npm lifecycle event name"],
      "Node.js version": .properties["Node.js version"],
      "Own process tracer status": .properties["Own process tracer status"],
      "Bounded ancestor-process executable basename sequence": .properties["Bounded ancestor-process executable basename sequence"]
    }' "$report"
    finish
    ;;

  trace)
    LATCH="$OUT/latch"
    for script in preinstall install postinstall preuninstall uninstall postuninstall; do
      n=$(strace_files "$LATCH" "$PROBE_KEY" "$script" | wc -l)
      echo "strace files for $script: $n"
    done
    load_files "$LATCH" "$PROBE_KEY" postinstall
    expect "trace: LATCH wrote postinstall strace files for $PROBE_KEY" test "${#files[@]}" -gt 0
    if [ "${#files[@]}" -eq 0 ]; then finish; fi
    expect "trace: postinstall strace files are non-empty" test -n "$(cat "${files[@]}")"
    expect "trace: postinstall exited 0 under strace (_finished marker)" \
      test -f "$LATCH/straces/$PROBE_KEY/${PROBE_KEY}_postinstall_finished"
    expect "trace: trace shows sh -c running the probe's postinstall command" \
      grep -qhE 'execve\("[^"]*/sh", \["sh", "-c", "node scripts/postinstall.js"\]' "${files[@]}"
    expect "trace: trace shows node executing scripts/postinstall.js" \
      grep -qhE 'execve\("[^"]*/node", \["node", "scripts/postinstall.js"\], .*\) = 0$' "${files[@]}"
    report=$(probe_report)
    if [ -n "$report" ]; then
      name=$(basename "$report")
      expect "trace: the recovered report $name was written inside the traced postinstall" \
        grep -qhF "/$name" "${files[@]}"
    else
      fail "trace: no recovered probe report to match against the trace"
    fi
    finish
    ;;

  manifest)
    LATCH="$OUT/latch"
    summary="$LATCH/manifest-summary.json"
    manifest="$LATCH/manifests/${PROBE_KEY}_postinstall"
    expect "manifest: analyzer summary exists" test -s "$summary"
    expect "manifest: analyzer reported every traced script as usable" jq -e '.ok == true' "$summary"
    expect "manifest: postinstall manifest was written" test -s "$manifest"
    expect "manifest: postinstall manifest is valid JSON" jq -e . "$manifest"
    expect "manifest: manifest records node running scripts/postinstall.js" \
      jq -e 'any(.lowerExecs[]?, .elevatedExecs[]?; (.args // []) | any(. == "scripts/postinstall.js"))' "$manifest"
    report=$(probe_report)
    if [ -n "$report" ]; then
      name=$(basename "$report")
      expect "manifest: manifest records creation of the recovered report $name" \
        jq -e --arg n "/$name" 'any(.create[]?, .rename[]?, .openWrite[]?; endswith($n) or endswith($n + ".tmp"))' "$manifest"
    else
      fail "manifest: no recovered probe report to match against the manifest"
    fi
    jq '{successful, timedOut, runtime,
         counts: (to_entries | map(select(.value | type == "array")) | map({key, value: (.value | length)}) | from_entries)}' \
      "$manifest" 2>/dev/null
    finish
    ;;

  *)
    echo "Unknown check: $CHECK" >&2
    exit 2
    ;;
esac
