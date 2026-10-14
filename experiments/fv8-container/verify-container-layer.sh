#!/usr/bin/env bash
# Check that the FV8 container experiment's stages ran inside the GitHub
# Actions job container and not on the outer hosted VM:
#   - the runtime was built inside a container (evidence recorded at build
#     time and stored with the runtime, so it survives an actions/cache restore);
#   - the harness steps that ran the runtime, npm and the probe ran in the
#     container (layer snapshots taken by record-container-layer.sh);
#   - the probe itself saw the container: its own report (unchanged probe)
#     shows the Docker marker file, the container's PID 1 and an overlay root.
# The outer VM, as recorded by the hosted-VM experiment, has no /.dockerenv,
# systemd as PID 1 and an ext4 root.
#
# Writes <out>/checks/container.json; exits non-zero on failure.
#
# Usage: verify-container-layer.sh <out-dir> <expected-image-os-version>
set -uo pipefail

OUT=$1
EXPECTED_OS_VERSION=$2
C="$OUT/container"

mkdir -p "$OUT/checks"
RESULTS=()
FAILED=0
pass() { echo "PASS: $1"; RESULTS+=("$(jq -cn --arg c "$1" '{check:$c, passed:true}')"); }
fail() { echo "::error::FAIL: $1"; RESULTS+=("$(jq -cn --arg c "$1" '{check:$c, passed:false}')"); FAILED=1; }
expect() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }
finish() {
  printf '%s\n' "${RESULTS[@]}" | jq -s --argjson failed "$FAILED" \
    '{check:"container", passed:($failed == 0), results:.}' > "$OUT/checks/container.json"
  exit "$FAILED"
}

in_container() {  # <snapshot.json>
  jq -e '.docker_marker_file == true
         and .root_filesystem_type == "overlay"
         and (.pid1.comm // "") != "systemd" and (.pid1.comm // "") != "init"' "$1"
}

for label in before-build before-probe; do
  f="$C/$label.json"
  expect "layer ($label): snapshot recorded" jq -e . "$f"
  expect "layer ($label): /.dockerenv present, overlay root, PID 1 is not systemd/init" in_container "$f"
  expect "layer ($label): Ubuntu $EXPECTED_OS_VERSION userland (the job container image)" \
    jq -e --arg v "$EXPECTED_OS_VERSION" '.os_id == "ubuntu" and .os_version == $v' "$f"
done

build="$C/runtime-build.json"
expect "build: build-time layer evidence stored with the runtime" jq -e . "$build"
expect "build: Node.js runtime was compiled inside a job container" in_container "$build"
expect "build: runtime was built from the same pinned commit/variant (build-info)" \
  jq -e '.node_commit == "07f481cfcf1153336534dc5d3cd4c5c9770a72be"' "$OUT/runtime/build-info.json"

run_paths="$OUT/install/probe/run-paths.json"
expect "harness: runtime and install directories are on the container's /__w mapping" \
  jq -e '(.lifecycle_node_expected | startswith("/__w/")) and (.work_dir | startswith("/__w/"))' "$run_paths"
expect "harness: npm ran from the container (npm host is under /__w or the container tool cache /__t)" \
  jq -e '.npm_runs_on | startswith("/__w/") or startswith("/__t/")' "$run_paths"
smoke="$OUT/install/smoke/report/markers.json"
expect "smoke: lifecycle process ran the container's runtime binary" \
  jq -e --slurpfile rp "$OUT/install/smoke/run-paths.json" '.exec_path == $rp[0].lifecycle_node_expected' "$smoke"

report=$(find "$OUT/probe" -maxdepth 1 -type f -name 'install-*.json' 2>/dev/null | sort | head -1)
if [ -z "$report" ]; then
  fail "probe: no report to check the probe's own view of the container"
  finish
fi
pid1=$(jq -r '.pid1.exe // .pid1.comm // ""' "$C/before-probe.json")
pid1=${pid1##*/}
expect "probe: probe saw the Docker marker file (/.dockerenv)" \
  jq -e '.properties["Docker marker-file presence"].value == true' "$report"
expect "probe: probe saw an overlay root filesystem" \
  jq -e '.properties["Overlay filesystem mount presence"].value == true' "$report"
expect "probe: probe saw the container's PID 1 ($pid1), not the VM's systemd" \
  jq -e --arg p "$pid1" '.properties["PID 1 executable basename"].value == $p and $p != "systemd"' "$report"
jq '{
  "Docker marker-file presence": .properties["Docker marker-file presence"].value,
  "Overlay filesystem mount presence": .properties["Overlay filesystem mount presence"].value,
  "PID 1 executable basename": .properties["PID 1 executable basename"].value,
  "Hostname container-like pattern": .properties["Hostname container-like pattern"].value,
  "Cgroup path normalized template": .properties["Cgroup path normalized template"].value
}' "$report"
finish
