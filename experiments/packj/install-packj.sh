#!/usr/bin/env bash
# Build a runnable Packj from the pinned tools/packj submodule.
#
# Follows Packj's documented source install ("pip3 install -r requirements.txt",
# then "python3 main.py"), with three differences:
#   - the upstream tree is exported with `git archive` and the experiment patch
#     is applied to the exported copy; tools/packj itself is never edited;
#   - Python packages go into a venv, constrained by requirements-lock.txt;
#   - `bundle install` (Ruby gems for Ruby static analysis) is skipped: it is
#     not used when auditing an npm package.
# As Packj's setup.py does, .packj.yaml is copied to ~/.packj.yaml.
#
# Usage: install-packj.sh <python3.10-interpreter> <build-dir>
set -euo pipefail

PYTHON=$1
BUILD=$2

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

if [ -e "$BUILD" ]; then
  echo "::error::$BUILD already exists"
  exit 1
fi
mkdir -p "$BUILD/packj"

echo "Exporting tools/packj @ $(git -C "$REPO/tools/packj" rev-parse HEAD)"
git -C "$REPO/tools/packj" archive HEAD | tar -x -C "$BUILD/packj"

echo "Applying patches/packj-local-nodejs-trace.patch"
(cd "$BUILD/packj" && git apply --verbose "$HERE/patches/packj-local-nodejs-trace.patch")
grep -q 'PackageManagerEnum.local_nodejs:' "$BUILD/packj/packj/audit/pm_util.py" \
  || { echo "::error::Patch did not apply to pm_util.py"; exit 1; }

"$PYTHON" -m venv "$BUILD/venv"
"$BUILD/venv/bin/python" -m pip install --disable-pip-version-check --no-input \
  -r "$BUILD/packj/requirements.txt" \
  -c "$HERE/requirements-lock.txt"
"$BUILD/venv/bin/python" -m pip freeze --all > "$BUILD/pip-freeze.txt"

cp "$BUILD/packj/.packj.yaml" "$HOME/.packj.yaml"
echo "Installed Packj into $BUILD (config: ~/.packj.yaml)"
