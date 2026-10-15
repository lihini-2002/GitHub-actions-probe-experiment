# GitHub Ubuntu VM + FV8 (reconstructed for npm) and matched control

Workflows:
[`fv8-probe.yml`](../../.github/workflows/fv8-probe.yml) ("Environment Probe - GitHub Ubuntu + FV8") and
[`fv8-control-probe.yml`](../../.github/workflows/fv8-control-probe.yml) ("… + FV8 matched control"),
both manual `workflow_dispatch`, both running the shared job
[`fv8-node-experiment.yml`](../../.github/workflows/fv8-node-experiment.yml).

Full background, the evidence behind each design decision, and limitations:
[`docs/fv8-setup-notes.md`](../../docs/fv8-setup-notes.md).

```text
Baseline (probe.yml)            FV8 (fv8-probe.yml)                         Control (fv8-control-probe.yml)
GitHub ubuntu-24.04 VM          GitHub ubuntu-24.04 VM                      GitHub ubuntu-24.04 VM
→ npm (setup-node 22)           → Node.js main@07f481cf + FV8 V8 patch       → Node.js main@07f481cf, unmodified
                                  (V8 12.2.281.27, --no-lazy)                 (V8 12.2.281.27, --no-lazy)
                                → npm install <tgz> --foreground-scripts    → npm install <tgz> --foreground-scripts
→ npm-probing-package-0.1.0.tgz → npm-probing-package-0.1.0.tgz              → npm-probing-package-0.1.0.tgz
→ postinstall                   → postinstall on the FV8 runtime             → postinstall on the control runtime
```

**What is FV8's and what is not.** FV8 (`wspr-ncsu/FV8`) releases an instrumented *Chromium*
and a V8 source patch; it has no Node.js runtime and no npm workflow. The only FV8 component
used here is `tools/fv8/patches/V8_patch_122.diff`, applied unmodified. Choosing Node.js as the
host, `compat/build/build_config.h`, baking `--no-lazy` into the binary, and the whole npm harness
are this study's reconstruction (`npm_harness_type: researcher_reconstructed_fv8_npm_harness`).

## Pinned sources

| Component | Where | Pin |
| --- | --- | --- |
| FV8 | `tools/fv8` (submodule) | `wspr-ncsu/FV8@57fc2b2699563316958603934aba572907171162`; patch SHA-256 `6dc767202b59eb770feeea27135ffd9455b4b6b2f1f0b9e97752de34880a3c39` |
| Node.js | fetched by `build-node-runtime.sh` | `nodejs/node@07f481cfcf1153336534dc5d3cd4c5c9770a72be` (last `main` commit on V8 12.2; V8 12.2.281.27; npm 10.5.2) |
| Toolchain | Ubuntu 24.04 runner | GCC 13, Python 3.12, GNU make (versions recorded) |
| Outer Node.js | `actions/setup-node@v4`, `node-version: "22"` | as in the baseline; used for `npm_host: system-node` |

The workflow fails if any pin, the patch hash, or the bundled V8 version differs.

## Files

| File | Role |
| --- | --- |
| `build-node-runtime.sh` | Fetch Node.js, apply the FV8 patch (fv8) or nothing (control), configure, build, install; writes `fv8-experiment/build-info.json` into the runtime |
| `patches/fv8-astnode-property-case.patch` | Opt-in researcher fix to FV8's `case 44` (not FV8; see docs/fv8-setup-notes.md §9a) |
| `patches/fv8-parser-reset-declared-functions.patch` | Opt-in researcher fix: clear FV8's global function lists per parse (dangling-pointer crash; not FV8; §9a) |
| `compat/build/build_config.h` | Chromium `BUILDFLAG` macros the patch includes (not FV8 code; FV8 variant only) |
| `record-environment.sh` | Outer environment, before any runtime is built or run → `environment-metadata.json` |
| `inspect-fv8-release.sh` | Reads the authors' Chromium `.deb` (versions, hashes, FV8 strings); never runs it |
| `run-runtime-selftest.sh` | Runtime versions, FV8 code in the binary, forced-execution canary |
| `smoke-package/` | Harness-only canary package; its `postinstall` runs `canary.cjs` |
| `run-npm-install.sh` | `npm install <tgz> --foreground-scripts` in a fresh directory with the runtime first on `PATH`; collects logs, VisibleV8 logs, reports |
| `verify-fv8-run.sh` | Checks `runtime`, `smoke`, `probe` (variant-aware) → `checks/*.json` |
| `write-metadata.sh` | `fv8-metadata.json`, `harness-classification.json`, `experiment-manifest.json`, `README.md` |

## Running it

GitHub → **Actions** → **Environment Probe - GitHub Ubuntu + FV8** → **Run workflow**, then the
same for **… + FV8 matched control** with the same inputs. Or:

```bash
gh workflow run fv8-probe.yml --ref main
gh workflow run fv8-control-probe.yml --ref main
```

Inputs (use the same values for both workflows):

| Input | Default | Meaning |
| --- | --- | --- |
| `npm_host` | `fv8-node` | `fv8-node`: npm also runs on the experiment runtime. `system-node`: npm runs on setup-node 22, only lifecycle scripts on the experiment runtime. |
| `v8_options` | `--no-lazy` | V8 flags baked into the runtime (`--no-lazy` is the authors' README example), or `none` |
| `node_snapshot` | `snapshot` | `no-snapshot` builds with `--without-node-snapshot`, only if the build's snapshot step fails under FV8 |
| `fv8_fixes` (FV8 workflow only) | `none` | `property-case`: one-line fix `patches/fv8-astnode-property-case.patch`. `property-case+parser-reset`: also `patches/fv8-parser-reset-declared-functions.patch`. With `none` and with `property-case` Node's build crashes in `node_mksnapshot`. See docs/fv8-setup-notes.md §9a |
| `rebuild_runtime` | `false` | Ignore the cached runtime |

The first run of each variant/input combination builds Node.js (~1.5–2 h); later runs restore it
from `actions/cache` and re-verify it.

## Artifact

`fv8-probe-<run_id>-<run_attempt>` → `results/fv8/<run_id>/`;
`fv8-control-probe-<run_id>-<run_attempt>` → `results/fv8-control/<run_id>/`.
The probe JSON is `probe/install-<uuid>.json`. Layout:
[docs/fv8-setup-notes.md §11](../../docs/fv8-setup-notes.md#11-artifact-layout).

## Differences from the baseline that the probe can observe

From FV8 itself (absent in the control):

- `vv8-*.log` files in the probe's working directory (its package directory) and in npm's
  working directory, created by VisibleV8 logging;
- `Found match for API: …` lines on standard output when FV8 force-compiles a branch;
- forced execution of untaken branches that mention FV8's targeted APIs, in the probe, in Node.js
  internals and (with `fv8-node`) in npm.

From the reconstruction (present in both FV8 and control):

- Node.js `v22.0.0-pre` / V8 `12.2.281.27-node.*` instead of setup-node's Node.js 22 / V8 12.4,
  with `--no-lazy` in effect; with `fv8-node`, npm 10.5.2 and npm's `node` is the same runtime;
- `<runtime>/bin` first on `PATH`; npm runs `npm install <tarball> --foreground-scripts` in a fresh
  directory (`$RUNNER_TEMP/install-probe`), not `npm ci` in this repository;
- a possible npm `EBADENGINE` warning (prerelease Node.js vs the probe's `engines: >=22`);
- no setup-node npm cache restore.

The workflows add no job-level `env:`, no `$GITHUB_ENV` entries, no secrets and no files the
probe would not otherwise see. The canary package is installed and removed (with `~/.npm` if it
did not exist before) before the probe runs.
