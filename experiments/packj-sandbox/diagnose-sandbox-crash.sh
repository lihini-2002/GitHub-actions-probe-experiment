#!/usr/bin/env bash
# Diagnose a failed Packj sandbox run (e.g. "Failed: installation error (-11)",
# i.e. Packj's strace died of SIGSEGV). Runs after the probe has finished, so
# nothing here can affect what the probe observed.
#
# Reproduces Packj's own invocation (packj/sandbox/main.py run_sandbox):
#   LD_LIBRARY_PATH=<sandbox> LD_PRELOAD=<sandbox>/libsbox.so
#   SANDBOX_ROOT=<fresh dir> SANDBOX_RULES=<the profile Packj generated>
#   <sandbox>/strace -fc --quiet=attach,personality -o <log> <command>
# on increasingly complex commands, plus a control without LD_PRELOAD, the
# kernel's segfault records, symbolised crash addresses and a gdb backtrace.
#
# Usage: diagnose-sandbox-crash.sh <packj-build-dir> <node-bin-dir> <out-dir>
set -uo pipefail

BUILD=$(realpath "$1")
NODE_BIN=$(realpath "$2")
OUT=$(realpath "$3")

SBOX="$BUILD/packj/packj/sandbox"
DIAG="$OUT/packj/diagnostics"
WORK=/tmp/packj-diag
mkdir -p "$DIAG" "$WORK"
PROFILE=$(find "$OUT/packj/policy" -maxdepth 1 -name 'rules_*.profile' | head -1)
[ -n "$PROFILE" ] || PROFILE="$OUT/packj/policy/expected-rules.profile"

echo "=== kernel segfault records (before) ===" > "$DIAG/dmesg.txt"
sudo dmesg 2>&1 | grep -iE 'segfault|general protection|traps:|strace' >> "$DIAG/dmesg.txt" || true

# One sandboxed run. Prints "<name> exit=<code>"; logs in $DIAG/runs/<name>.*
run_case() {
  local name=$1 preload=$2; shift 2
  local root="$WORK/root-$name" log="$DIAG/runs/$name"
  mkdir -p "$DIAG/runs" "$root"
  local env=(LD_LIBRARY_PATH="$SBOX" SANDBOX_ROOT="$root" SANDBOX_RULES="$PROFILE" PATH="$NODE_BIN:$PATH")
  [ "$preload" = yes ] && env+=(LD_PRELOAD="$SBOX/libsbox.so")
  (cd "$WORK" && timeout 300 env "${env[@]}" "$SBOX/strace" -fc --quiet=attach,personality \
      -o "$log.strace-c.log" "$@" > "$log.stdout" 2> "$log.stderr" < /dev/null)
  local code=$?
  [ -f "$root.csv" ] && cp "$root.csv" "$log.events.csv"
  echo "$name exit=$code" | tee -a "$DIAG/cases.txt"
}

: > "$DIAG/cases.txt"
run_case control-true          no  /bin/true
run_case control-npm-version   no  npm --version
run_case sandbox-true          yes /bin/true
run_case sandbox-usr-bin-true  yes /usr/bin/true
run_case sandbox-ls-tmp        yes /bin/ls /tmp
run_case sandbox-sh            yes /bin/sh -c 'echo hi > /tmp/packj-diag-sh.txt'
run_case sandbox-node          yes node -e 'require("fs").readdirSync("/tmp")'
run_case sandbox-npm-version   yes npm --version

echo "=== kernel segfault records (after) ===" >> "$DIAG/dmesg.txt"
sudo dmesg 2>&1 | grep -iE 'segfault|general protection|traps:|strace' >> "$DIAG/dmesg.txt" || true

# Symbolise "... in <lib>[<base>+<size>]" faults. strip does not move code, so
# an unstripped link of the same sandbox.o has the same offsets as libsbox.so.
ld -shared -L"$SBOX" -lstrace -ldl -o "$WORK/libsbox-unstripped.so" "$SBOX/sandbox.o" 2>>"$DIAG/symbolise.txt"
{
  echo "=== faults symbolised (ip - mapping base) ==="
  # Kernel formats: "in lib[<start>+<size>]" (old) or "in lib[<pgoff>,<start>+<size>]" (6.x).
  # "segfault at … ip <addr> …" and "traps: … ip:<addr> …" both occur.
  grep -oE 'ip[ :][0-9a-f]+ .* in [^ ]+\[([0-9a-f]+,)?[0-9a-f]+\+[0-9a-f]+\]' "$DIAG/dmesg.txt" | sort -u | while read -r line; do
    ip=$(sed -E 's/^ip[ :]([0-9a-f]+).*/\1/' <<<"$line")
    lib=$(sed -E 's/.* in ([^[]+)\[.*/\1/' <<<"$line")
    inner=$(sed -E 's/.*\[([^]]+)\]$/\1/' <<<"$line")
    pgoff=0
    case "$inner" in *,*) pgoff=$((16#${inner%%,*})); inner=${inner#*,} ;; esac
    base=${inner%%+*}
    off=$(printf '0x%x' $((16#$ip - 16#$base + pgoff)))
    case "$lib" in
      libsbox.so) obj="$WORK/libsbox-unstripped.so" ;;
      libstrace.so) obj="$SBOX/libstrace.so" ;;
      strace) obj="$SBOX/strace" ;;
      *) obj="" ;;
    esac
    echo "$line  -> file offset $off"
    # For these objects the text segment's vaddr equals its file offset.
    [ -n "$obj" ] && addr2line -f -C -e "$obj" "$off" | sed 's/^/    /'
  done
} >> "$DIAG/symbolise.txt" 2>&1

# gdb backtrace of the first crashing case.
first=$(grep -E 'sandbox-.* exit=(139|-11)$' "$DIAG/cases.txt" | head -1 | cut -d' ' -f1)
if [ -n "$first" ]; then
  case "$first" in
    sandbox-true) cmd=(/bin/true) ;;
    sandbox-ls-tmp) cmd=(/bin/ls /tmp) ;;
    sandbox-sh) cmd=(/bin/sh -c 'echo hi > /tmp/packj-diag-sh.txt') ;;
    sandbox-node) cmd=(node -e 'require("fs").readdirSync("/tmp")') ;;
    *) cmd=(npm --version) ;;
  esac
  sudo apt-get install -y gdb > "$DIAG/gdb-install.log" 2>&1
  root="$WORK/root-gdb"; mkdir -p "$root"
  (cd "$WORK" && timeout 300 gdb -q -batch \
     -ex "set environment LD_LIBRARY_PATH=$SBOX" \
     -ex "set environment LD_PRELOAD=$SBOX/libsbox.so" \
     -ex "set environment SANDBOX_ROOT=$root" \
     -ex "set environment SANDBOX_RULES=$PROFILE" \
     -ex "set environment PATH=$NODE_BIN:$PATH" \
     -ex 'set follow-fork-mode parent' \
     -ex 'set detach-on-fork on' \
     -ex 'handle SIGCHLD nostop noprint pass' \
     -ex run -ex bt -ex 'info sharedlibrary' -ex 'info registers rip' -ex 'x/8i $pc' \
     --args "$SBOX/strace" -fc --quiet=attach,personality -o "$WORK/gdb-strace.log" "${cmd[@]}" \
     < /dev/null) > "$DIAG/gdb-backtrace.txt" 2>&1
  # Same backtrace with symbols from the unstripped library.
  (cd "$WORK" && timeout 300 gdb -q -batch \
     -ex "set environment LD_LIBRARY_PATH=$SBOX" \
     -ex "set environment LD_PRELOAD=$WORK/libsbox-unstripped.so" \
     -ex "set environment SANDBOX_ROOT=$root-2" \
     -ex "set environment SANDBOX_RULES=$PROFILE" \
     -ex "set environment PATH=$NODE_BIN:$PATH" \
     -ex 'handle SIGCHLD nostop noprint pass' \
     -ex run -ex bt \
     --args "$SBOX/strace" -fc --quiet=attach,personality -o "$WORK/gdb-strace-2.log" "${cmd[@]}" \
     < /dev/null) > "$DIAG/gdb-backtrace-unstripped.txt" 2>&1
fi

{
  echo "kernel: $(uname -r)"
  echo "glibc: $(ldd --version | sed -n 1p)"
  ldd "$SBOX/strace"
  ldd "$SBOX/libsbox.so"
  sha256sum "$SBOX/sandbox.o" "$SBOX/libsbox.so" "$SBOX/libstrace.so" "$SBOX/strace"
} > "$DIAG/binaries.txt" 2>&1

echo "Diagnostics in $DIAG:"
cat "$DIAG/cases.txt"
grep -E 'segfault|traps' "$DIAG/dmesg.txt" | tail -5
exit 0
