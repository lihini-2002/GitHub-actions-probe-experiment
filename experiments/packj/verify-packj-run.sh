#!/usr/bin/env bash
# Validate one stage of the Packj trace experiment. Packj exits 0 even when
# its trace stage fails (the error is only printed as "FAIL [...]"), so its
# exit status is never taken as evidence: each check looks at the artifacts
# Packj and the probe actually produced, and links them to each other.
#
# Usage:
#   verify-packj-run.sh packj <out-dir>
#   verify-packj-run.sh trace <out-dir>
#   verify-packj-run.sh probe <out-dir> <expected-npm-version>
#
# Each check writes <out-dir>/metadata/checks/<check>.json and exits non-zero
# on failure.
set -uo pipefail

CHECK=$1
OUT=$2

PROBE_NAME=npm-probing-package
PROBE_VERSION=0.1.0
LOGS="$OUT/packj/logs"

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
audit_log() { sed 's/\x1b\[[0-9;]*m//g' "$LOGS/packj-audit.log"; }

INPUT=$(path_of input)
INSTALLED=$(path_of installed_package_dir)

case "$CHECK" in
  packj)
    expect "packj: console log was captured" test -s "$LOGS/packj-audit.log"
    expect "packj: run paths were recorded" jq -e . "$LOGS/run-paths.json"
    if [ ! -s "$LOGS/packj-audit.log" ]; then finish; fi
    expect "packj: exited 0 (not sufficient on its own)" \
      test "$(cat "$LOGS/packj-exit-status.txt" 2>/dev/null)" = 0
    expect "packj: audited local_nodejs package $INPUT" \
      grep -qxF "Auditing local_nodejs package $INPUT (ver: latest)" <(audit_log)
    expect "packj: trace stage ran (--trace honoured)" \
      grep -qE '^\[\+\] Installing package and tracing code' <(audit_log)
    expect "packj: trace stage reported PASS, not FAIL" \
      grep -qE '^PASS \[found .* syscalls\]$|Installing package and tracing code\.*PASS \[found .* syscalls\]' <(audit_log)
    grep -E 'Installing package and tracing code|syscalls\]' <(audit_log) | grep -v 'unlink failed'
    report=$(first "$OUT/packj/audit" 'report_*.json')
    expect "packj: audit report (report_*.json) was written" test -n "$report"
    if [ -n "$report" ]; then
      expect "packj: audit report is valid JSON" jq -e . "$report"
      expect "packj: audit report is for local_nodejs $INPUT @ $PROBE_VERSION" \
        jq -e --arg p "$INPUT" --arg v "$PROBE_VERSION" \
          '.pm_name == "local_nodejs" and .pkg_name == $p and .pkg_ver == $v' "$report"
      jq '{pm_name, pkg_name, pkg_ver, risks}' "$report"
    fi
    expect "packj: HTML summary (report_*.html) was written" test -n "$(first "$OUT/packj/audit" 'report_*.html')"
    finish
    ;;

  trace)
    trace=$(first "$OUT/packj/trace" 'trace_*.log')
    count=$(find "$OUT/packj/trace" -maxdepth 1 -type f -name 'trace_*.log' 2>/dev/null | wc -l)
    echo "Packj strace logs: $count"
    expect "trace: Packj wrote an strace log (trace_*.log)" test -n "$trace"
    if [ -z "$trace" ]; then finish; fi
    expect "trace: exactly one strace log (one traced installation)" test "$count" -eq 1
    expect "trace: strace log is non-empty" test -s "$trace"
    echo "strace log lines: $(wc -l < "$trace")"
    # strace's default -s 32 truncates argv strings, so the tarball argument is
    # matched through the files npm opened instead.
    expect "trace: traced root process is npm install" \
      grep -qE '^[0-9]+ +[0-9.]+ execve\("[^"]*/npm", \["npm", "install", "--silent", "--no-progress", "--no-update-notifier", ' <(head -1 "$trace")
    expect "trace: npm opened the staged probe tarball" \
      grep -qF "\"$INPUT\"" "$trace"
    expect "trace: npm ran the probe's postinstall via sh -c" \
      grep -qE 'execve\("[^"]*/sh", \["sh", "-c", "node scripts/postinstall.js"\], .*\) = 0' "$trace"
    expect "trace: node executed scripts/postinstall.js" \
      grep -qE 'execve\("[^"]*/node", \["node", "scripts/postinstall.js"\]' "$trace"
    report=$(probe_report)
    if [ -n "$report" ] && [ -n "$INSTALLED" ]; then
      target="$INSTALLED/results/$(basename "$report")"
      # Matches "<target>.tmp" (created) and "<target>" (renamed into place).
      expect "trace: the recovered report was created at $target inside the traced install" \
        grep -qE '(openat|renameat2?)\(' <(grep -F "\"$target" "$trace")
    else
      fail "trace: no recovered probe report to match against the trace"
    fi
    summary=$(first "$OUT/packj/trace" 'summary_*.json')
    expect "trace: Packj parsed the trace (summary_*.json written)" test -n "$summary"
    if [ -n "$summary" ]; then
      expect "trace: Packj's summary is valid JSON" jq -e . "$summary"
      expect "trace: Packj's summary has process and file syscalls" \
        jq -e '(.process | length) > 0 and (.files | length) > 0' "$summary"
      jq 'with_entries(.value |= length)' "$summary"
    fi
    finish
    ;;

  probe)
    EXPECTED_NPM=$3
    report=$(probe_report)
    count=$(find "$OUT/probe" -maxdepth 1 -type f -name 'install-*.json' 2>/dev/null | wc -l)
    echo "Probe reports recovered: $count"
    expect "probe: an install-*.json report was recovered" test -n "$report"
    if [ -z "$report" ]; then finish; fi
    expect "probe: exactly one report (one postinstall run)" test "$count" -eq 1
    expect "probe: report came from the package npm installed under Packj" \
      test "$(path_of probe_report_source_dir)" = "$INSTALLED/results"
    expect "probe: report is valid JSON" jq -e . "$report"
    expect "probe: report phase is postinstall" jq -e '.phase == "postinstall"' "$report"
    expect "probe: report is from $PROBE_NAME@$PROBE_VERSION" \
      jq -e --arg n "$PROBE_NAME" --arg v "$PROBE_VERSION" '.package.name == $n and .package.version == $v' "$report"
    expect "probe: report has properties" jq -e '.properties | length > 0' "$report"
    expect "probe: npm lifecycle event seen by the probe is postinstall" \
      jq -e '.properties["npm lifecycle event name"].value == "postinstall"' "$report"
    expect "probe: package manager seen by the probe is npm $EXPECTED_NPM" \
      jq -e --arg v "$EXPECTED_NPM" '.properties["Package-manager identity"].value == "npm" and .properties["Package-manager version"].value == $v' "$report"
    expect "probe: probe process was being traced (TracerPid != 0)" \
      jq -e '.properties["Own process tracer status"].value == true' "$report"
    expect "probe: probe's ancestors include strace started by Packj's Python" \
      jq -e '.properties["Bounded ancestor-process executable basename sequence"].value as $a
             | ($a | index("strace")) as $i
             | $i != null and ($a[$i + 1:] | any(startswith("python")))' "$report"
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

  *)
    echo "Unknown check: $CHECK" >&2
    exit 2
    ;;
esac
