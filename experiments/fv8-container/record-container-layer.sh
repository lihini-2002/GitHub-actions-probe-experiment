#!/usr/bin/env bash
# Record what the current process sees of its execution layer: OS, kernel,
# PID 1, cgroup and limits, mounts, hostname, container marker files. Run from
# workflow steps of the FV8 container experiment at several points
# (before-build, after-build, before-probe) to show that each stage ran inside
# the GitHub Actions job container. Harness metadata only: nothing here is
# visible to the probe, and no environment variable values are recorded.
#
# Writes <out>/container/<label>.json and <out>/container/<label>.txt.
#
# Usage: record-container-layer.sh <out-dir> <label>
set -uo pipefail

OUT=$1
LABEL=$2
mkdir -p "$OUT/container"

read_file() { if [ -r "$1" ]; then tr -d '\0' < "$1" | head -c 4096; fi; }
or_null() { if [ -n "$1" ]; then jq -cn --arg v "$1" '$v'; else echo null; fi; }

pid1_cmdline=$(tr '\0' ' ' < /proc/1/cmdline 2>/dev/null | sed 's/ $//')
pid1_exe=$(readlink /proc/1/exe 2>/dev/null)
pid1_comm=$(read_file /proc/1/comm)
root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null)
cgroup_fs=$(stat -f -c %T /sys/fs/cgroup 2>/dev/null)
cgroup_version=null
[ "$cgroup_fs" = cgroup2fs ] && cgroup_version='"v2"'
[ "$cgroup_fs" = tmpfs ] && cgroup_version='"v1"'

{
  echo "=== LABEL ==="; echo "$LABEL"
  echo; echo "=== TIMESTAMP ==="; date -u --iso-8601=seconds
  echo; echo "=== /etc/os-release ==="; cat /etc/os-release
  echo; echo "=== uname -a ==="; uname -a
  echo; echo "=== hostname ==="; hostname 2>/dev/null || cat /proc/sys/kernel/hostname
  echo; echo "=== id ==="; id
  echo; echo "=== marker files ==="
  ls -la /.dockerenv /run/.containerenv 2>&1
  echo; echo "=== PID 1 ==="; echo "exe: $pid1_exe"; echo "cmdline: $pid1_cmdline"
  echo; echo "=== /proc/self/cgroup ==="; cat /proc/self/cgroup
  echo; echo "=== /proc/1/cgroup ==="; cat /proc/1/cgroup 2>&1
  echo; echo "=== cgroup limits ==="
  for f in cpu.max cpuset.cpus.effective memory.max pids.max; do
    printf '%s: %s\n' "$f" "$(read_file "/sys/fs/cgroup/$f")"
  done
  echo; echo "=== processes ==="; ps -eo pid,ppid,user,comm,args --width 200 2>&1
  echo; echo "=== findmnt ==="; findmnt 2>&1
  echo; echo "=== df -Th ==="; df -Th 2>&1
  echo; echo "=== namespaces (self) ==="; ls -l /proc/self/ns 2>&1
} > "$OUT/container/$LABEL.txt" 2>&1

hostname_value=$(cat /proc/sys/kernel/hostname 2>/dev/null)
jq -n \
  --arg label "$LABEL" \
  --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg os "$(. /etc/os-release && echo "$PRETTY_NAME")" \
  --arg os_id "$(. /etc/os-release && echo "$ID")" \
  --arg os_version "$(. /etc/os-release && echo "$VERSION_ID")" \
  --arg kernel "$(uname -r)" \
  --arg machine "$(uname -m)" \
  --arg hostname "$hostname_value" \
  --argjson dockerenv "$([ -e /.dockerenv ] && echo true || echo false)" \
  --argjson containerenv "$([ -e /run/.containerenv ] && echo true || echo false)" \
  --argjson pid1_exe "$(or_null "$pid1_exe")" \
  --argjson pid1_comm "$(or_null "$pid1_comm")" \
  --argjson pid1_cmdline "$(or_null "$pid1_cmdline")" \
  --arg self_cgroup "$(read_file /proc/self/cgroup)" \
  --argjson cgroup_version "$cgroup_version" \
  --argjson cpu_max "$(or_null "$(read_file /sys/fs/cgroup/cpu.max | tr -d '\n')")" \
  --argjson cpuset "$(or_null "$(read_file /sys/fs/cgroup/cpuset.cpus.effective | tr -d '\n')")" \
  --argjson memory_max "$(or_null "$(read_file /sys/fs/cgroup/memory.max | tr -d '\n')")" \
  --argjson pids_max "$(or_null "$(read_file /sys/fs/cgroup/pids.max | tr -d '\n')")" \
  --argjson root_fstype "$(or_null "$root_fstype")" \
  --arg mounts "$(wc -l < /proc/self/mountinfo)" \
  --arg nproc "$(nproc)" \
  --arg mem_total_kb "$(awk '/^MemTotal:/{print $2}' /proc/meminfo)" \
  --argjson user_gitconfig "$([ -e "$HOME/.gitconfig" ] && echo true || echo false)" \
  --arg uid "$(id -u)" \
  --arg user "$(id -un 2>/dev/null)" \
  '{
    label: $label,
    recorded_at: $recorded_at,
    os: $os, os_id: $os_id, os_version: $os_version,
    kernel: $kernel,
    machine: $machine,
    hostname: $hostname,
    hostname_is_12_hex: ($hostname | test("^[0-9a-f]{12}$")),
    docker_marker_file: $dockerenv,
    podman_marker_file: $containerenv,
    pid1: { exe: $pid1_exe, comm: $pid1_comm, cmdline: $pid1_cmdline },
    cgroup: {
      version: $cgroup_version,
      self: ($self_cgroup | split("\n") | map(select(length > 0))),
      cpu_max: $cpu_max,
      cpuset_cpus_effective: $cpuset,
      memory_max: $memory_max,
      pids_max: $pids_max
    },
    root_filesystem_type: $root_fstype,
    mountinfo_entries: ($mounts | tonumber),
    logical_cpus: ($nproc | tonumber),
    mem_total_kb: ($mem_total_kb | tonumber),
    user: { uid: ($uid | tonumber), name: $user },
    user_gitconfig_present: $user_gitconfig
  }' > "$OUT/container/$LABEL.json"

cat "$OUT/container/$LABEL.json"
