# Pack-A-Mal on a GitHub Actions Ubuntu VM

Workflow: `.github/workflows/pack-a-mal-probe.yml` (manual `workflow_dispatch`).
Helper: `experiments/pack-a-mal/verify-pack-a-mal-run.sh`.
Pinned source: submodule `tools/pack-a-mal`.

## Bottom line

**Exact Pack-A-Mal cannot analyse an npm package.** At the pinned commit the npm
ecosystem is gone and the sandbox image has no Node. The workflow therefore runs a
**researcher-modified reproduction**: `experiments/pack-a-mal/restore-npm-support.sh`
restores npm from upstream OpenSSF and the workflow supplies upstream's Node sandbox
image, so the probe does run through Pack-A-Mal's own `run_analysis.sh`, analysis
container, podman and gVisor. The exact diff is saved as
`setup/pack-a-mal-modifications.patch` and the manifest records
`researcher_modified: true`. Report these results as modified, and note that the
package-visible environment is then essentially OpenSSF's.

Status: the workflow has **not been run on GitHub yet**, and the modified Go code has
not been compiled outside the CI image build (the first run will show whether it does).
The job fails (red) if no probe report comes out of the sandbox.

Modifications applied:
1. npm restored: `NPM` in `pkgecosystem`, `internal/pkgmanager/npm.go` from ossf/package-analysis `2539ef6`, entries in the package-manager map and default analysis command.
2. Sandbox image: `gcr.io/ossf-malware-analysis/dynamic-analysis:latest` (Node + `analyze-node.js`), passed with `-sandbox-image` / `-analysis-command`. Not pinned by digest because Pack-A-Mal appends `:tag`; the digest seen at run time is in `metadata/npm-sandbox-image.txt`.
3. gVisor apt release `20240212` -> `20260216` (upstream's fix for newer kernels).
4. `runsc --strace-log-size=1048576` so the ~21 KB probe `write()` is captured whole (same as the OpenSSF workflow).
5. Probe JSON is reassembled from the file-write results with `scripts/reassemble-probe.mjs`, as in the OpenSSF experiment.

## Pinning

| Item | Value |
|---|---|
| Repository | https://github.com/lyvd/Pack-A-Mal (branch `master`) |
| Commit | `9af1cfb8868512021317b8a1901adea53db3d28b` (2025-02-21, "Update systemcall interface report") |
| Mechanism | git submodule `tools/pack-a-mal`; the workflow fails if HEAD differs from `EXPECTED_PAM_SHA` |
| Runner | `ubuntu-24.04` (same as the OpenSSF and Packj experiments), no job-level `container:` |
| Analysis image base | `ubuntu:22.04@sha256:42ba2dfc...`, Go builder `golang:1.23.1@sha256:4a3c2bcd...` |
| gVisor | apt release `20240212` (pinned in `cmd/analyze/Dockerfile`) |
| podman / runsc exact versions, image digests | recorded at run time in `metadata/analysis-image-tools.txt` and `metadata/docker-images.txt` |

Note the apt `runsc` release is from Feb 2024. Upstream OpenSSF later bumped gVisor
"to run on newer kernels" (ossf/package-analysis `be18ab7`, 2026-02), so the old
runsc may also fail on the runner's kernel. This only matters if the npm blocker is
resolved.

## Provenance versus OpenSSF Package Analysis

Pack-A-Mal is a fork of `github.com/ossf/package-analysis` (Go module path is still
`github.com/ossf/package-analysis`). No fork point is recorded. Comparing file hashes
puts the base at about `2539ef69223780040e5d50dc2fa115b20a0c95df` (2024-10-14,
"Bump Go to v1.23.1"); several nearby upstream commits match equally well, so treat
this as approximate.

### Inherited from OpenSSF (active)
- `scripts/run_analysis.sh` structure: `docker run --cgroupns=host --privileged --rm`, mounts for `/var/lib/containers`, results, file writes, logs, strace.
- Outer analysis image (`cmd/analyze/Dockerfile`): Ubuntu 22.04 + podman + iptables-legacy + gVisor `runsc`, with `runsc_compat.sh`, `iptables.rules`, `podman-analysis.conflist`.
- `internal/sandbox` (podman-driven inner sandbox with strace and packet capture), `internal/strace`, `internal/worker`, result stores, static analysis.
- File-write capture (the mechanism the OpenSSF experiment uses to recover the probe JSON).

### Pack-A-Mal modifications (active)
- Ecosystems reduced to a single value, `wolfi` (`pkg/api/pkgecosystem/ecosystem.go`); `internal/pkgmanager` keeps only `wolfi.go`. `npm.go`, `pypi.go`, `rubygems.go`, `packagist.go`, `crates.io.go` are deleted.
- `analyze` defaults the ecosystem to `wolfi`.
- Image registry renamed to `wolfi-apk` (`wolfi-apk/analysis`, `wolfi-apk/dynamic-analysis`).
- Dynamic sandbox (`sandboxes/dynamicanalysis/Dockerfile`) rebuilt on `cgr.dev/chainguard/wolfi-base` with only Python/pip; the only analysis script is `analyze_wolfi_apk.py` (`apk add --allow-untrusted`, then execute the binary). `analyze-node.js` and the other language scripts were deleted.
- Added `scripts/run_analysis.py`, `web/` (Django dashboard), `INSTALLATION`, system-call interface report.

### Proposed but not implemented (README only)
- Windows sandbox, Java/Maven support, service simulation (INetSim/FakeNet-NG), YARA/ML/LLM malware detection. The README's own checklist marks service simulation, Java and Windows unchecked.
- The README "Multi-language support" text still names npm, PyPI, RubyGems, Packagist and crates.io, but that describes upstream; none of those paths exist in the code.

## Answers to the inspection questions

1. **Implemented**: the Wolfi APK dynamic path (syscall recording via gVisor strace) and a dashboard.
2. **Inherited**: the container/sandbox machinery listed above.
3. **npm runnable?** No. `pkgecosystem.Parse("npm")` returns `ecosystem unsupported`; `pkgmanager.Manager` only knows `wolfi`; `dynamicanalysis.defaultCommand` only has `analyze_wolfi_apk.py`.
4. **Submission**: `scripts/run_analysis.sh -ecosystem <e> -package <p> -local <file>`; the file is bind-mounted into the analysis container at `/<basename>` and copied into the inner sandbox.
5. **Lifecycle scripts**: no npm is ever invoked, so none execute. The sandbox image contains no `node`/`npm`.
6. **Isolation**: Docker (outer, `--privileged`) -> podman -> gVisor `runsc` (inner).
7. **Nested containers**: yes, by design, via the outer container's own podman and `/var/lib/containers`.
8. **Proposals vs implemented**: see lists above.

## Intended architecture (from source; the inner layers were not reached)

GitHub Actions infrastructure -> GitHub-hosted `ubuntu-24.04` VM (owns Docker)
-> Docker container `wolfi-apk/analysis` (privileged; owns podman and runsc)
-> podman container `wolfi-apk/dynamic-analysis` under gVisor `runsc`
-> `analyze_wolfi_apk.py` -> `apk add` -> execute.

In the modified run the last steps become `analyze-node.js` -> `npm install` ->
lifecycle script -> probe (to be confirmed by the first run). Unmodified, the chain
stops at `analyze` rejecting `npm`.

## Prerequisites actually needed on the host

Docker and `make` (both preinstalled on `ubuntu-24.04`). Go, podman and gVisor are
installed inside the analysis image by its Dockerfile. No Node setup is done, because
nothing on the host runs the probe.

## Is it effectively just OpenSSF?

Infrastructure-wise yes: the outer container, podman, gVisor and recovery mechanism
are the OpenSSF ones (older gVisor). The only differences in the package-visible
environment are the Wolfi sandbox image and the missing npm path, so there is no
npm environment to compare. A like-for-like comparison with the OpenSSF run cannot
be made without a researcher-modified build.

## Metadata and secrets

- `experiment-manifest.json` and `metadata/` are research metadata only. They are not part of the probe JSON and must not be used as classifier features.
- No secrets are passed: workflow permissions are `contents: read`, no job `env` carries tokens, and `docker run` is given no `-e` flags.

## Result layout

`results/pack-a-mal-vm/<run-id>-<attempt>/` -> `experiment-manifest.json`, `metadata/`, `setup/` (image build log), `pack-a-mal/` (run log, dry-run command, exit code, analyzer help, result subdirectories), `verification/`, `probe/` (empty unless recovery succeeds). Uploaded as artifact `pack-a-mal-vm-<run-id>-<attempt>`.
