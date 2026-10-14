#!/usr/bin/env bash
# Build the Node.js runtime for the FV8 experiment or its matched control.
#
#   fv8      Node.js main@07f481cf (bundled V8 12.2.281.27) with FV8's
#            released V8 patch applied verbatim (patch -F0: no fuzz allowed)
#            plus a build-compatibility header (compat/build/build_config.h).
#   control  The same Node.js commit, configure options and toolchain, with
#            no FV8 patch and no compatibility header.
#
# Both variants are installed to <runtime-dir> (bin/node, bin/npm,
# lib/node_modules/npm, ...) with `make install`. Build provenance is written
# to <runtime-dir>/fv8-experiment/ so it is restored together with the
# runtime from the actions/cache entry.
#
# Usage: build-node-runtime.sh <fv8|control> <work-dir> <runtime-dir> <v8-options|none> \
#          <snapshot|no-snapshot> [none|property-case]
#
# The optional 6th argument selects researcher fixes to FV8's released patch
# (default none = FV8 exactly as released). property-case applies
# patches/fv8-astnode-property-case.patch after the FV8 patch (see that file);
# it only applies to the fv8 variant.
#
# no-snapshot adds --without-node-snapshot. Node's build runs the freshly
# built engine (node_mksnapshot) over Node's bootstrap code; this option exists
# in case FV8's forced execution breaks that step. Use the same value for the
# FV8 and control builds.
set -euo pipefail

VARIANT=$1
WORK=$2
RUNTIME=$3
V8_OPTIONS=$4
SNAPSHOT=$5
FV8_FIXES=${6:-none}

# Pins. Changing any of these changes the actions/cache key (the key hashes
# this file).
NODE_REPO=https://github.com/nodejs/node.git
# Last nodejs/node main commit on V8 12.2 (parent of "deps: update V8 to
# 12.3.219.16", nodejs/node#52293). V8 12.2 is the branch FV8 targets
# (the authors' Chromium 122 build embeds V8 12.2.281.21).
NODE_COMMIT=07f481cfcf1153336534dc5d3cd4c5c9770a72be
NODE_V8_VERSION=12.2.281.27
FV8_COMMIT=57fc2b2699563316958603934aba572907171162
FV8_PATCH_SHA256=6dc767202b59eb770feeea27135ffd9455b4b6b2f1f0b9e97752de34880a3c39
FIX_PROPERTY_CASE_SHA256=7a40be232b78e9a9fb6a8c3a9a4a2564f383bc0537c24cb135af42da24d09169

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
FV8="$REPO/tools/fv8"
PATCH="$FV8/patches/V8_patch_122.diff"
COMPAT="$HERE/compat/build/build_config.h"
SRC="$WORK/node"
INFO="$RUNTIME/fv8-experiment"

case "$VARIANT" in fv8|control) ;; *) echo "variant must be fv8 or control" >&2; exit 2 ;; esac
case "$SNAPSHOT" in snapshot|no-snapshot) ;; *) echo "snapshot must be snapshot or no-snapshot" >&2; exit 2 ;; esac
case "$FV8_FIXES" in none|property-case) ;; *) echo "fv8 fixes must be none or property-case" >&2; exit 2 ;; esac
if [ "$VARIANT" = control ] && [ "$FV8_FIXES" != none ]; then
  echo "fv8 fixes apply to the fv8 variant only" >&2; exit 2
fi
if [ -e "$SRC" ] || [ -e "$RUNTIME" ]; then
  echo "$SRC or $RUNTIME already exists; refusing to build over it" >&2
  exit 2
fi
mkdir -p "$WORK" "$INFO"
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "=== Fetch Node.js $NODE_COMMIT"
git init -q "$SRC"
git -C "$SRC" fetch -q --depth 1 "$NODE_REPO" "$NODE_COMMIT"
git -C "$SRC" checkout -q FETCH_HEAD
actual=$(git -C "$SRC" rev-parse HEAD)
[ "$actual" = "$NODE_COMMIT" ] || { echo "Node.js checkout is $actual, expected $NODE_COMMIT" >&2; exit 1; }

v8h="$SRC/deps/v8/include/v8-version.h"
v8_version=$(awk '/define V8_MAJOR_VERSION/{a=$3} /define V8_MINOR_VERSION/{b=$3} /define V8_BUILD_NUMBER/{c=$3} /define V8_PATCH_LEVEL/{d=$3} END{print a"."b"."c"."d}' "$v8h")
echo "Bundled V8: $v8_version"
[ "$v8_version" = "$NODE_V8_VERSION" ] || { echo "Bundled V8 is $v8_version, expected $NODE_V8_VERSION" >&2; exit 1; }

patch_applied=false
compat_installed=false
if [ "$VARIANT" = fv8 ]; then
  echo "=== Apply FV8 patch"
  fv8_actual=$(git -C "$FV8" rev-parse HEAD)
  [ "$fv8_actual" = "$FV8_COMMIT" ] || { echo "tools/fv8 is at $fv8_actual, expected $FV8_COMMIT" >&2; exit 1; }
  echo "$FV8_PATCH_SHA256  $PATCH" | sha256sum -c -

  # The patch is a `diff -ru srcA srcB` of V8's src/ directory
  # (paths ./srcA/<file>, ./srcB/<file>), hence -p2 from deps/v8/src.
  # -F0: every hunk must match its context exactly. --forward: never
  # reverse-apply. Any failed hunk fails the build.
  (cd "$SRC/deps/v8/src" && patch -p2 -F0 --forward --batch --no-backup-if-mismatch < "$PATCH") \
    | tee "$INFO/patch-apply.log"
  if find "$SRC/deps/v8" -name '*.rej' | grep . ; then
    echo "FV8 patch did not apply cleanly" >&2
    exit 1
  fi
  # -F0 already rejects any hunk whose context does not match exactly. An
  # "offset" only means a hunk's exact context was found at a different line
  # number (Node's deps/v8 has a few more/fewer lines above it than the
  # authors' srcA). With GNU patch 2.7.6 at the pinned commits, two hunks
  # apply at an offset: ast/ast.h (+8) and parsing/parser.cc (-1).
  if grep -i 'fuzz' "$INFO/patch-apply.log"; then
    echo "FV8 patch applied with fuzz" >&2
    exit 1
  fi
  grep -i 'offset' "$INFO/patch-apply.log" || true
  expected_files=$(grep -c '^Differences in ' "$PATCH")
  changed_files=$(git -C "$SRC" diff --name-only -- deps/v8/src | wc -l)
  echo "Patch sections: $expected_files, files changed: $changed_files"
  [ "$expected_files" = "$changed_files" ] || { echo "Patch changed $changed_files files, expected $expected_files" >&2; exit 1; }
  grep -q 'Found match for API: ' "$SRC/deps/v8/src/interpreter/bytecode-generator.cc"
  grep -q 'vv8-%ld-%d-%d-%s.%%d.log' "$SRC/deps/v8/src/runtime/runtime-test.cc"
  patch_applied=true

  fixes_json='[]'
  if [ "$FV8_FIXES" = property-case ]; then
    echo "=== Apply researcher fix (not FV8): fv8-astnode-property-case.patch"
    fix="$HERE/patches/fv8-astnode-property-case.patch"
    echo "$FIX_PROPERTY_CASE_SHA256  $fix" | sha256sum -c -
    (cd "$SRC/deps/v8" && patch -p1 -F0 --forward --batch --no-backup-if-mismatch < "$fix") \
      | tee "$INFO/researcher-fix-apply.log"
    if grep -i 'fuzz\|offset\|FAILED' "$INFO/researcher-fix-apply.log"; then
      echo "researcher fix did not apply exactly" >&2
      exit 1
    fi
    grep -q 'case 45: { // case 45: {' "$SRC/deps/v8/src/interpreter/bytecode-generator.cc"
    if grep -q 'case 44: { // case 45: {' "$SRC/deps/v8/src/interpreter/bytecode-generator.cc"; then
      echo "researcher fix left the original case 44 label in place" >&2
      exit 1
    fi
    fixes_json=$(jq -cn --arg sha "$FIX_PROPERTY_CASE_SHA256" \
      '[{name: "property-case", patch: "experiments/fv8/patches/fv8-astnode-property-case.patch", sha256: $sha,
         change: "AstTraversal: case 44 -> case 45 (Property is 45 in V8 12.2; 44 is OptionalChain, which made AsProperty() return nullptr)"}]')
  fi

  echo "=== Install build-compatibility header"
  target="$SRC/deps/v8/build/build_config.h"
  [ ! -e "$target" ] || { echo "$target already exists; not overriding it" >&2; exit 1; }
  mkdir -p "$(dirname "$target")"
  cp "$COMPAT" "$target"
  compat_installed=true

  git -C "$SRC" add -A deps/v8
  git -C "$SRC" diff --cached --stat > "$INFO/source-changes.stat"
  git -C "$SRC" diff --cached > "$INFO/source-changes.diff"
else
  echo "=== Control: Node.js sources left unmodified"
  if [ -n "$(git -C "$SRC" status --porcelain)" ]; then
    echo "Control source tree is not clean" >&2
    exit 1
  fi
  : > "$INFO/source-changes.diff"
  : > "$INFO/source-changes.stat"
fi

echo "=== Configure"
configure_args=(--prefix="$RUNTIME")
if [ "$V8_OPTIONS" != none ]; then
  # Baked into the binary (node_v8_options); applied at every startup, so
  # the lifecycle `node` gets the flags without NODE_OPTIONS or a wrapper.
  configure_args+=(--v8-options="$V8_OPTIONS")
fi
if [ "$SNAPSHOT" = no-snapshot ]; then
  configure_args+=(--without-node-snapshot)
fi
printf '%s\n' "${configure_args[@]}" > "$INFO/configure-args.txt"
gcc --version | head -1
g++ --version | head -1
python3 --version
(cd "$SRC" && ./configure "${configure_args[@]}")

echo "=== Build"
jobs=$(nproc)
(cd "$SRC" && make -j"$jobs")

echo "=== Install"
(cd "$SRC" && make install -j"$jobs")
test -x "$RUNTIME/bin/node"
test -f "$RUNTIME/lib/node_modules/npm/bin/npm-cli.js"

# FV8 prints "Found match for API" when it force-compiles a branch; V8's
# mksnapshot and Node's node_mksnapshot run the freshly built engine during
# the build. VisibleV8 logs go to the working directory of those tools.
build_vv8_logs=$(find "$SRC" -name 'vv8-*.log' 2>/dev/null | wc -l)
find "$SRC" -name 'vv8-*.log' -delete 2>/dev/null || true

jq -n \
  --arg variant "$VARIANT" \
  --arg built_in_run "${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}" \
  --arg started "$started" \
  --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg node_repo "$NODE_REPO" \
  --arg node_commit "$NODE_COMMIT" \
  --arg node_v8 "$v8_version" \
  --arg fv8_commit "$(git -C "$FV8" rev-parse HEAD)" \
  --arg patch "tools/fv8/patches/V8_patch_122.diff" \
  --arg patch_sha "$(sha256sum "$PATCH" | cut -d' ' -f1)" \
  --argjson patch_applied "$patch_applied" \
  --arg compat_sha "$(sha256sum "$COMPAT" | cut -d' ' -f1)" \
  --argjson compat_installed "$compat_installed" \
  --argjson fixes "${fixes_json:-[]}" \
  --arg v8_options "$V8_OPTIONS" \
  --arg snapshot "$SNAPSHOT" \
  --arg configure "./configure $(printf '%s ' "${configure_args[@]}" | sed "s|--prefix=$RUNTIME|--prefix=<runtime-dir>|")" \
  --arg cc "$(gcc --version | head -1)" \
  --arg cxx "$(g++ --version | head -1)" \
  --arg python "$(python3 --version 2>&1)" \
  --arg os "$(. /etc/os-release && echo "$PRETTY_NAME")" \
  --arg jobs "$jobs" \
  --argjson build_vv8_logs "$build_vv8_logs" \
  --arg node_sha "$(sha256sum "$RUNTIME/bin/node" | cut -d' ' -f1)" \
  --arg npm_version "$(jq -r .version "$RUNTIME/lib/node_modules/npm/package.json")" \
  '{
    variant: $variant,
    built_in_run: $built_in_run,
    build_started: $started,
    build_finished: $finished,
    node_repository: $node_repo,
    node_commit: $node_commit,
    node_bundled_v8_version: $node_v8,
    fv8_commit: $fv8_commit,
    fv8_patch: (if $patch_applied then $patch else null end),
    fv8_patch_sha256: (if $patch_applied then $patch_sha else null end),
    fv8_patch_applied: $patch_applied,
    fv8_patch_apply_options: (if $patch_applied then "patch -p2 -F0 --forward (from deps/v8/src)" else null end),
    compat_header: (if $compat_installed then "experiments/fv8/compat/build/build_config.h -> deps/v8/build/build_config.h" else null end),
    compat_header_sha256: (if $compat_installed then $compat_sha else null end),
    fv8_patch_as_released: ($patch_applied and ($fixes | length == 0)),
    researcher_fv8_fixes: $fixes,
    v8_options_baked_in: (if $v8_options == "none" then null else $v8_options end),
    node_snapshot: ($snapshot == "snapshot"),
    configure: ($configure | rtrimstr(" ")),
    toolchain: { cc: $cc, cxx: $cxx, python: $python, os: $os, make_jobs: ($jobs | tonumber) },
    vv8_logs_written_during_build: $build_vv8_logs,
    node_binary_sha256: $node_sha,
    bundled_npm_version: $npm_version
  }' > "$INFO/build-info.json"
cat "$INFO/build-info.json"
