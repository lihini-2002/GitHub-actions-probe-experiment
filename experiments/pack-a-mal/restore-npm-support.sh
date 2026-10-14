#!/usr/bin/env bash
# RESEARCHER MODIFICATION. Not part of Pack-A-Mal at the pinned commit.
#
# Restores the npm ecosystem that Pack-A-Mal removed from the OpenSSF
# package-analysis fork, using upstream ossf/package-analysis at the commit
# closest to Pack-A-Mal's fork point. Three more small changes make the run
# comparable with experiments/ (OpenSSF) runs:
#   - gVisor apt release bumped to the one upstream uses to support newer kernels
#   - runsc --strace-log-size raised so the ~21 KB probe write() is captured whole
# The npm sandbox image is NOT built here; the workflow passes upstream's
# gcr.io/ossf-malware-analysis/dynamic-analysis (Node + analyze-node.js) through
# Pack-A-Mal's own -sandbox-image flag.
#
# Usage: restore-npm-support.sh <pack-a-mal-dir> <scratch-dir>
set -euo pipefail

PAM=$(realpath "$1")
SCRATCH=$(realpath -m "$2")
UPSTREAM_SHA=2539ef69223780040e5d50dc2fa115b20a0c95df   # ossf/package-analysis, 2024-10-14
GVISOR_RELEASE=20260216                                  # ossf/package-analysis be18ab7

mkdir -p "$SCRATCH"
git clone --quiet --filter=blob:none https://github.com/ossf/package-analysis.git "$SCRATCH/upstream"
git -C "$SCRATCH/upstream" checkout --quiet "$UPSTREAM_SHA"
cp "$SCRATCH/upstream/internal/pkgmanager/npm.go" "$PAM/internal/pkgmanager/npm.go"

python3 - "$PAM" "$GVISOR_RELEASE" <<'PY'
import sys, pathlib
pam, gv = pathlib.Path(sys.argv[1]), sys.argv[2]

def sub(rel, old, new):
    p = pam / rel
    s = p.read_text()
    if s.count(old) != 1:
        sys.exit(f"anchor not found exactly once in {rel}: {old!r}")
    p.write_text(s.replace(old, new))

sub("pkg/api/pkgecosystem/ecosystem.go",
    '\tWolfi Ecosystem = "wolfi"',
    '\tNPM   Ecosystem = "npm"\n\tWolfi Ecosystem = "wolfi"')
sub("pkg/api/pkgecosystem/ecosystem.go",
    "var SupportedEcosystems = []Ecosystem{\n",
    "var SupportedEcosystems = []Ecosystem{\n\tNPM,\n")
sub("internal/pkgmanager/ecosystem.go",
    "\t\twolfiPkgManager.ecosystem: &wolfiPkgManager,",
    "\t\tnpmPkgManager.ecosystem:   &npmPkgManager,\n\t\twolfiPkgManager.ecosystem: &wolfiPkgManager,")
sub("internal/dynamicanalysis/sandbox_args.go",
    '\tpkgecosystem.Wolfi:',
    '\tpkgecosystem.NPM:   "/usr/local/bin/analyze-node.js",\n\tpkgecosystem.Wolfi:')
sub("cmd/analyze/Dockerfile", "releases 20240212 main", f"releases {gv} main")
sub("tools/gvisor/runsc_compat.sh", 'exec "$BIN" "$@"',
    'exec "$BIN" --strace-log-size=1048576 "$@"')
PY

echo "npm support restored from ossf/package-analysis $UPSTREAM_SHA"
