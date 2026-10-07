#!/usr/bin/env bash
# Build Packj's sandbox tool inside a Packj build made by
# experiments/packj/install-packj.sh, exactly as upstream documents it
# (packj/sandbox/README.md, Dockerfile, setup.py): `./install.sh -v` in the
# sandbox directory. That script clones strace v5.19, builds it as
# libstrace.so plus an `strace` executable, and links Packj's prebuilt
# sandbox.o into libsbox.so. Two compatibility patches (below and README);
# main.py, the sandbox.o code and the policy are upstream's.
#
# Usage: build-sandbox.sh <packj-build-dir> <log-file>
set -euo pipefail

BUILD=$(realpath "$1")
LOG=$2

SBOX="$BUILD/packj/packj/sandbox"
# install.sh clones strace with `--branch v5.19`; this is that tag's commit.
STRACE_COMMIT=9b00bd51c9040931803c6d6d1718a0faef7d7d59
STRACE_SRC=/tmp/packj-strace

test -f "$SBOX/install.sh" || { echo "::error::$SBOX/install.sh not found"; exit 1; }
if [ -e "$STRACE_SRC" ]; then
  echo "::error::$STRACE_SRC already exists; install.sh would reuse a stale strace build"
  exit 1
fi

# Compatibility patches (see README):
#  1. strace v5.19 does not compile against Ubuntu 24.04's kernel headers;
#     build it against its own bundled headers.
#  2. sandbox.o indexes its 346-entry syscall table without a bounds check;
#     link zeroed entries after it so syscalls >= 346 find "no handler"
#     instead of jumping through .got.plt (SIGSEGV on the runner).
PATCHES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patches"
for p in packj-sandbox-strace-bundled-headers.patch packj-sandbox-syscall-table-pad.patch; do
  (cd "$BUILD/packj" && git apply --verbose "$PATCHES/$p")
done
grep -q -- '--enable-bundled=yes' "$SBOX/install.sh" \
  || { echo "::error::Patch did not apply to install.sh"; exit 1; }
grep -q '^OBJS := sandbox.o table-pad.o$' "$SBOX/Makefile" \
  || { echo "::error::Patch did not apply to the sandbox Makefile"; exit 1; }

# install.sh must be run from its own directory, and needs -v under its own
# `set -u` (it reads "$1" unconditionally).
set +e
(cd "$SBOX" && ./install.sh -v) 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e
# install.sh prints "Failed" and exits 1 on errors; double-check its products.
for f in strace libstrace.so libsbox.so; do
  if [ ! -s "$SBOX/$f" ]; then
    echo "::error::Packj sandbox build did not produce $f (install.sh exit $status)"
    exit 1
  fi
done
[ "$status" -eq 0 ] || { echo "::error::install.sh exited $status"; exit 1; }

actual=$(git -C "$STRACE_SRC" rev-parse HEAD)
if [ "$actual" != "$STRACE_COMMIT" ]; then
  echo "::error::install.sh built strace $actual, expected v5.19 ($STRACE_COMMIT)"
  exit 1
fi
echo "strace source: $actual (v5.19)"

# sandbox.o's handler table is 0xad0 bytes; the padding must follow it.
relro=$(readelf -S -W "$SBOX/libsbox.so" | awk '{for (i = 1; i <= NF; i++) if ($i == ".data.rel.ro") print $(i + 4)}')
if [ -z "$relro" ] || [ $((16#$relro)) -lt $((0xad0 + 8192)) ]; then
  echo "::error::libsbox.so .data.rel.ro is 0x${relro:-?} bytes; expected the 0xad0-byte table plus 8192 bytes of padding"
  exit 1
fi
echo "libsbox.so .data.rel.ro: 0x$relro bytes (handler table 0xad0 + padding)"
if readelf -l -W "$SBOX/libsbox.so" | grep -E 'GNU_STACK' | grep -qE ' RWE '; then
  echo "::error::libsbox.so requests an executable stack; the padding must not change that"
  exit 1
fi
ls -la "$SBOX"
