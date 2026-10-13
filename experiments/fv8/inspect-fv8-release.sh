#!/usr/bin/env bash
# Inspect the authors' released FV8 build (the Chromium .deb in tools/fv8) and
# record what it is built from. The .deb is only inspected, never installed or
# run: it is a browser and cannot execute npm lifecycle scripts. The values
# recorded here (Chromium version, embedded V8 version, FV8 markers) are read
# from the authors' binary, not assumed.
#
# Writes <out>/fv8/released-build.json.
#
# Usage: inspect-fv8-release.sh <out-dir> <scratch-dir>
set -euo pipefail

OUT=$1
SCRATCH=$2

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
FV8="$REPO/tools/fv8"
DEB="$FV8/deb_files/chromium-browser-stable_122.0.6261.111-1_amd64.deb"
# The worker image installs celery_workers/chromium_122_fv8_Apr24.deb; it is
# the same file.
WORKER_DEB="$FV8/celery_workers/chromium_122_fv8_Apr24.deb"
mkdir -p "$OUT/fv8" "$SCRATCH"

deb_sha=$(sha256sum "$DEB" | cut -d' ' -f1)
worker_sha=$(sha256sum "$WORKER_DEB" | cut -d' ' -f1)
package=$(dpkg-deb -f "$DEB" Package)
version=$(dpkg-deb -f "$DEB" Version)

dpkg-deb --fsys-tarfile "$DEB" | tar -x -C "$SCRATCH" ./opt/chromium.org/chromium/chrome
chrome="$SCRATCH/opt/chromium.org/chromium/chrome"

# V8 version strings embedded in the binary (V8 12.2 is what the patch is
# named after; the exact build is read from the binary).
scan=$(python3 - "$chrome" <<'PY'
import collections, json, re, sys
data = open(sys.argv[1], 'rb').read()
versions = collections.Counter(
    m.group().decode() for m in re.finditer(rb'(?<![0-9.])12\.2\.\d+\.\d+(?![0-9.])', data))
print(json.dumps({
    'v8_versions': [v for v, _ in versions.most_common()],
    'forced': data.count(b'Found match for API: '),
    'vv8': data.count(b'vv8-%ld-%d-%d-%s'),
}))
PY
)
v8_versions=$(jq -c .v8_versions <<< "$scan")
marker_forced=$(jq .forced <<< "$scan")
marker_vv8=$(jq .vv8 <<< "$scan")

jq -n \
  --arg deb "tools/fv8/deb_files/$(basename "$DEB")" \
  --arg deb_sha "$deb_sha" \
  --arg worker_deb "tools/fv8/celery_workers/$(basename "$WORKER_DEB")" \
  --arg worker_sha "$worker_sha" \
  --arg package "$package" \
  --arg version "$version" \
  --argjson v8_versions "$v8_versions" \
  --argjson marker_forced "$marker_forced" \
  --argjson marker_vv8 "$marker_vv8" \
  '{
    released_artifact: $deb,
    released_artifact_sha256: $deb_sha,
    worker_image_artifact: $worker_deb,
    worker_image_artifact_sha256: $worker_sha,
    worker_image_artifact_identical: ($deb_sha == $worker_sha),
    deb_package: $package,
    chromium_version: ($version | sub("-[0-9]+$"; "")),
    deb_version: $version,
    embedded_v8_versions: $v8_versions,
    embedded_v8_version: ($v8_versions[0] // null),
    fv8_forced_execution_string_present: ($marker_forced > 0),
    visiblev8_log_name_pattern_present: ($marker_vv8 > 0),
    used_to_run_npm: false,
    why_not_used: "Chromium browser build: no Node.js runtime, no npm, no node:* modules; npm lifecycle scripts cannot run in it."
  }' > "$OUT/fv8/released-build.json"

rm -rf "$SCRATCH/opt"
cat "$OUT/fv8/released-build.json"
