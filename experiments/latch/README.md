# Experiment B: GitHub Ubuntu VM + LATCH

Workflow: [`.github/workflows/latch-probe.yml`](../../.github/workflows/latch-probe.yml)
("Environment Probe - GitHub Ubuntu + LATCH", manual `workflow_dispatch`).

```text
Experiment A (probe.yml)                Experiment B (this directory)
GitHub ubuntu-24.04 VM                  GitHub ubuntu-24.04 VM
→ npm (runner, Node 22)                 → Apptainer 1.5.4
→ npm-probing-package-0.1.0.tgz         → LATCH image (Ubuntu 20.04, debootstrap)
→ postinstall                           → LATCH npm 6.14.8 (lifecycle under strace)
→ install-<uuid>.json                   → npm-probing-package-0.1.0.tgz
                                        → postinstall, traced
                                        → install-<uuid>.json + straces + manifests
```

Both experiments install the same tarball, `packages/npm-probing-package-0.1.0.tgz`,
and the probe writes its report with its own default mechanism (`results/` inside the
installed package). Nothing here changes Experiment A or the container-job experiment.

## Pinned sources

| Component | Where | Pin |
| --- | --- | --- |
| LATCH | `tools/latch` (submodule) | `elizabethwyss/Latch@a57345fba86a176bf32c888592582f194fafa5bb` |
| LATCH's npm base | `tools/npm-cli` (submodule) | `npm/cli@bd2721dbc3de13a5ba889eba50644475d80f6948` (npm 6.14.8, `npm-lifecycle@3.1.5`) |
| Apptainer | workflow | 1.5.4 `.deb`, sha256 `281cf9bd…a97f7` |
| Node.js in image | workflow input | 22.23.3 (default) or 12.22.12, nodejs.org tarballs, sha256 verified |
| Analyzer deps | `analyzer-deps/package-lock.json` | glob 7.1.6, n-readlines 1.0.1, pegjs 0.10.0, pegjs-backtrace 0.1.2, debug 4.3.1, node-exceptions 4.0.1 |

The workflow checks that both submodules are at these commits, and that LATCH's own
`cli` gitlink points to the `tools/npm-cli` commit.

## What upstream LATCH provides, and what it does not

LATCH's single-package analysis path (upstream file → role):

- `singularity/container.def`: Ubuntu 20.04 image with many toolchains, Node 12 and `/cli`.
- `singularity/containerScriptSingle.js`: inside the image, `npm install <pkg>` then
  `npm uninstall <pkg>` with `node /cli/bin/npm-cli.js`.
- `singularity/containerWorker.js`: on the host, `singularity run --bind … -H … container.sif`,
  then `analyzer.Analyze(pkg)`.
- `cli/node_modules/npm-lifecycle/index.js`: per the README, the only modified npm file;
  runs each lifecycle script under strace.
- `analyzer/*.js` + `parser/b3`: parses `straces/<pkg>/<pkg>_<script>.<pid>` and builds a
  manifest per script.

Three gaps had to be filled:

1. **The modified npm is not published.** `cli` is a gitlink with no `.gitmodules` entry,
   and it points to a stock `npm/cli` commit (`bd2721d`, one docs commit after v6.14.8). Its
   `npm-lifecycle/index.js` is byte-identical to `npm-lifecycle@3.1.5`. The README's
   `createExec` function does not exist anywhere public.
2. **The manifest is never written.** `Analyzer.Analyze` builds the manifest, but the
   `this.WriteToFile(manifest, …)` call is commented out.
3. **The probe cannot run on Node 12.** It requires Node ≥22 and uses top-level `await`,
   `?.` and `??`. Under Node 12.22.12 `scripts/postinstall.js` fails to parse
   (`SyntaxError: Unexpected reserved word`). LATCH's analyzer does run on Node 12.

## Deviations from upstream

Upstream files in `tools/` are never edited. `build-image.sh` exports them with
`git archive` and applies the patches below to the exported copy.

| # | Change | Why | Where |
| --- | --- | --- | --- |
| D1 | **Reconstructed** the LATCH lifecycle hook: `createExec()` wraps each script as `strace -ff -ttt -yy -o /straces/<name@version>/<name@version>_<stage> sh -c <cmd>`. It writes `<…>_finished` on exit 0, `<…>_killed` on a 10-minute timeout, and `<…>_exit` with the exit status. | Upstream file unpublished (gap 1). The flags and file layout come from what `analyzer.js` and the b3 grammar read: per-pid files with a `.pid` suffix, epoch timestamps (`-ttt`), decoded fds (`-yy`), and the `_finished` / `_killed` markers. The `name@version` key matches `getPkgVerList.js` and `policy/results`. **This is a reproduction, not the authors' code.** | `patches/npm-cli-lifecycle-strace.patch` |
| D2 | Re-enabled `this.WriteToFile(manifest, …)`. | Manifest serialization: upstream generated the manifest object but did not persist it in the checked-in code (gap 2). Output format and file name (`manifests/<name@version>_<script>`, JSON) are upstream's own `WriteToFile`. | `patches/latch-analyzer-reproduction.patch` |
| D3 | `OSstate` initial cwd reads `LATCH_INITIAL_CWD` first, then falls back to the hard-coded `/home/user/Documents/research/malicious_packages/<pkg>`. | Removes the authors' machine path. Relative paths in the trace now resolve against the real lifecycle directory. The variable is set only in the analyzer process, after the probe has finished. | same patch |
| D4 | Analyzer `catch` also prints the error stack to stderr. | Upstream swallowed it; only `analyzer_failed` was recorded. Diagnostic only. | same patch |
| D5 | Node.js is installed from a pinned nodejs.org tarball into `/usr`, not from `deb.nodesource.com/setup_12.x`. | The NodeSource setup script is retired. `/usr` matches the NodeSource layout (`/usr/bin/node`). | `container-github.def` |
| D6 | **Node version is a workflow input; the default is 22.23.3, not 12.** | Gap 3: under Node 12 the probe cannot produce output. 22 matches the probe's `engines` and Experiment A's `node-version: "22"`. LATCH's own code is unchanged: npm stays 6.14.8 and the analyzer runs on either version. Choose `12.22.12` to run upstream's runtime as a control. | workflow input `node_version` |
| D7 | `strace` and `xz-utils` installed explicitly; `babel-cli@6.26.0`/`babel-core@6.26.3` pinned. `DEBIAN_FRONTEND=noninteractive` at build time only. | Hook needs `/usr/bin/strace`; unattended build; pin what upstream left floating. | `container-github.def` |
| D8 | Analyzer + pinned deps added to the image at `/latch`; manifests generated inside the image, not on the host. | Upstream shipped no dependency manifest and ran the analyzer with the cluster's own Node. | `analyzer-deps/`, `generate-manifest.js` |
| D9 | Container script takes the install spec (tarball path), uninstall name and strace key separately. It copies the probe report out between install and uninstall, and exits non-zero if install failed. | Upstream used one `name@version` string for registry installs; uninstall deletes the probe's `results/`. The copy happens after `npm install` returns. | `container-script-single.js` |
| D10 | `%files` source paths come from a staged build context, not `/home/user/Documents/research/…`. | Authors' hard-coded paths. | `build-image.sh`, `container-github.def` |

Unchanged from upstream: Ubuntu 20.04 via `debootstrap` from `us.archive.ubuntu.com`, the
full `%post` package list (including the Go backports PPA), `/package.json`, the
`%runscript` steps (`mkdir`, blank `package.json`, `npm config set cache ./cache`), the
`singularity run`-style invocation with `-H <home>` and `/straces`, `/packages` and
`/InstancePkgs` binds, the work directory under `/dev/shm/Instances/`, inherited host
environment, install followed by uninstall, and all analyzer semantics.

AppArmor enforcement (`apparmor/`) and the policy engine (`policy/`) are not used.

## Measurement hygiene

- Apptainer passes the host environment through, as upstream's `singularity run` did.
  The workflow therefore sets no job-level `env:` and never writes `$GITHUB_ENV`.
  Experiment labels are given only to the metadata step. The probe sees the same
  GitHub-provided variables as in Experiment A, plus whatever Apptainer itself sets.
- No extra mounts are added for the probe run. Reports are handed back through
  `/dev/shm`, which Apptainer already shares.
- The smoke-test package runs first in its own instance, and its directories are deleted
  before the probe runs.
- No fake credentials, configuration, history, caches or tools are added. The only
  pre-install state is upstream's own (`package.json`, `npm config set cache`).

## Files

| File | Purpose |
| --- | --- |
| `container-github.def` | Apptainer definition adapted from upstream `singularity/container.def`. |
| `build-image.sh` | Stages the build context from the submodules, applies the patches, runs `sudo apptainer build`. |
| `patches/npm-cli-lifecycle-strace.patch` | D1: reconstructed LATCH hook for `npm-lifecycle/index.js`. |
| `patches/latch-analyzer-reproduction.patch` | D2–D4. |
| `container-script-single.js` | `/start.js` in the image; adapted `containerScriptSingle.js` (D9). |
| `run-latch-single.sh` | Host side: `apptainer run` with upstream's binds; collects logs and the probe report. |
| `generate-manifest.js` | Runs `Analyzer.Analyze(pkg)` in the image and summarizes per-script traces and manifests. |
| `verify-latch-run.sh` | `smoke` / `probe` / `trace` / `manifest` checks; each writes `metadata/checks/<name>.json`. |
| `write-metadata.sh` | `metadata/experiment.json`. |
| `analyzer-deps/` | Pinned dependencies for `analyzer/` and `parser/b3`. |
| `smoke-package/` | Minimal package with a postinstall, used to test the hook before the probe. |

## Running it

GitHub → **Actions** → **Environment Probe - GitHub Ubuntu + LATCH** → **Run workflow**,
pick the branch and `node_version`, then **Run workflow**. From the CLI:

```sh
gh workflow run latch-probe.yml --ref <branch> -f node_version=22.23.3
gh run watch
gh run download <run-id> -n github-actions-ubuntu-latch-<run-id>-<attempt>
```

The workflow must be on the default branch for the button to show up. Building the image
takes most of the run time.

## Output

Artifact `github-actions-ubuntu-latch-<run_id>-<run_attempt>`:

```text
experiment-output/
├── probe/
│   └── install-<uuid>.json                    probe report (unchanged format)
├── latch/
│   ├── straces/npm-probing-package@0.1.0/
│   │   ├── npm-probing-package@0.1.0_postinstall.<pid>   one per traced process
│   │   ├── npm-probing-package@0.1.0_postinstall_finished
│   │   └── npm-probing-package@0.1.0_postinstall_exit
│   ├── manifests/
│   │   └── npm-probing-package@0.1.0_postinstall         LATCH manifest (JSON)
│   ├── manifest-summary.json                  per-script trace/manifest summary
│   ├── smoke/straces/latch-smoke-package@1.0.0/…
│   └── logs/  image-build.log, latch-run.log, analyzer.log, analyzer-errors.txt,
│              npm-logs/ (on npm failure), instance-package.json, lifecycle-cwd.txt
└── metadata/
    ├── experiment.json                        run metadata (layers, versions, outcome)
    ├── github-host.txt                        runner host details
    └── checks/{smoke,probe,trace,manifest}.json
```

## How a run is judged

The job fails unless all of these hold. A successful `npm install` alone is never enough.

- **probe**: a report was recovered with `phase: "postinstall"`. Inside it,
  `npm lifecycle event name = postinstall`, `Package-manager version = 6.14.8`, and
  `Own process tracer status = true` (TracerPid ≠ 0).
- **trace**: postinstall strace files exist and are non-empty, and the `_finished` marker
  exists. The trace shows `execve(…/sh, ["sh", "-c", "node scripts/postinstall.js"])` and a
  successful `execve(…/node, ["node", "scripts/postinstall.js"])`. **The recovered report's
  file name (with its random UUID) appears in those traces**, which ties that exact report
  to the traced process.
- **manifest**: the analyzer reported every traced script as usable. The postinstall
  manifest is valid JSON with all 25 `CreateManifest` keys, it lists `node
  scripts/postinstall.js` among executed programs, and it records the creation or rename
  of the recovered report.

## Telling a LATCH run from normal npm

Compare `experiment-output/probe/install-*.json` with Experiment A's
`collected-results/install-*.json`:

| Property | Experiment A | Experiment B |
| --- | --- | --- |
| `Package-manager version` | runner npm (10.x) | `6.14.8` |
| `Own process tracer status` | `false` | `true` |
| `Bounded ancestor-process executable basename sequence` | no `strace` | contains `strace` |
| `Operating system distribution version` | `24.04` | `20.04` |

Independently of the probe, the report's UUID file name appears in
`latch/straces/…_postinstall.<pid>` and in the postinstall manifest. A report that LATCH
did not trace cannot appear there.

## Not yet verified

All of this was written without access to a Linux host, Apptainer or strace. Tested
locally on macOS:

- the patches apply to the pinned sources;
- patched npm 6.14.8 installs the real probe tarball through the hook (with a stand-in
  `strace`) and the report is collected before uninstall;
- the patched analyzer and `generate-manifest.js` produce a manifest from hand-written
  `strace -ttt -yy` lines on Node 24 and Node 12.22.12;
- `verify-latch-run.sh` passes on good input and fails on an untraced report, a wrong npm
  version, a missing `_finished` marker and a report name absent from the trace.

The first real run will be the first test of the Apptainer build (including the full
upstream package list on today's focal archive), ptrace inside Apptainer on a GitHub
runner, and real strace output through the b3 grammar.
