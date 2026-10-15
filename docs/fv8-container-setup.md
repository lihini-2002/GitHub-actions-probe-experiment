# FV8 in a GitHub Actions job container (Experiment B)

Workflow: [`.github/workflows/fv8-container-probe.yml`](../.github/workflows/fv8-container-probe.yml)
("Environment Probe - GitHub Ubuntu container job + FV8", manual `workflow_dispatch`).
Container-specific scripts: [`experiments/fv8-container/`](../experiments/fv8-container/).
Everything else is the hosted-VM FV8 experiment, reused unchanged: see
[`docs/fv8-setup-notes.md`](fv8-setup-notes.md) for what FV8 is and how the Node.js/npm
reconstruction works.

| | Experiment A (existing) | Experiment B (this) |
| --- | --- | --- |
| Workflows | `fv8-probe.yml`, `fv8-control-probe.yml` (shared job `fv8-node-experiment.yml`) | `fv8-container-probe.yml` (`variant: fv8` or `control`) |
| Layers | hosted VM → FV8 → probe | hosted VM → **job container** → FV8 → probe |
| Results | `results/fv8/<run-id>/`, `results/fv8-control/<run-id>/` | `results/fv8-container/<run-id>/`, `results/fv8-container-control/<run-id>/` |
| Artifact | `fv8-probe-…`, `fv8-control-probe-…` | `fv8-container-<run_id>-<attempt>`, `fv8-container-control-<run_id>-<attempt>` |

> **Status of Experiment A (2026-10-13).** The successful hosted-VM runs in this repository
> (e.g. run 38428556729) are all **`fv8-control-probe.yml`**, the matched control: Node.js built
> *without* the FV8 patch (`fv8_patch_applied: false`, `forced_execution_enabled: false`, label
> `probe_executed_under_control_runtime_verified`). `fv8-probe.yml`, the FV8-patched build, has not
> been run yet. The first FV8 build (this experiment, run 38494602753, 2026-10-14) compiled but
> **crashed in Node's `node_mksnapshot`** with the FV8 patch as released; see
> [fv8-setup-notes.md §9a](fv8-setup-notes.md#9a-fv8s-released-patch-crashes-nodejss-build-optional-one-line-fix).
> With `fv8_fixes: property-case` it crashed again; gdb (`crash_diagnostics: true`, run 38532680501)
> traced the crash to a dangling pointer in FV8's `AstTraversal`. Both experiments take
> `fv8_fixes: property-case+parser-reset`, which applies two documented researcher fixes (setup
> notes §9a). Use the same value in A and B when comparing them.

## 1. What a GitHub Actions container job is

A job with a `container:` key. GitHub starts a normal hosted VM, starts the named Docker image
on it as a long-running container (its PID 1 is `tail -f /dev/null`), and runs **every `run:`
step and every action of the job inside that container** with `docker exec`. The workspace and
`$RUNNER_TEMP` are bind-mounted from the VM into the container as `/__w/…`, the tool cache as
`/__t`, and `$HOME` is `/github/home`. Steps run as root. This is not a `docker run` inside a step:
there is no step that executes on the VM.

## 2–5. Layers: where everything runs

```text
GitHub infrastructure
→ GitHub Actions ubuntu-24.04 hosted VM                  outer layer: hosts the container, runs nothing of the experiment
→ GitHub Actions job container  ubuntu:24.04@sha256:f610ab94…   every step below runs here
→ FV8 runtime: Node.js main@07f481cf + FV8 V8 patch (V8 12.2.281.27, --no-lazy), compiled in this container
→ npm install <npm-probing-package-0.1.0.tgz> --foreground-scripts   (npm 10.5.2 on the FV8 runtime)
→ sh -c "node scripts/postinstall.js"   (node = the FV8 runtime, first on PATH)
→ npm-probing-package postinstall → results/install-<uuid>.json
```

- **The outer VM** is the same `runs-on: ubuntu-24.04` as Experiment A. It only hosts the
  container. Nothing is installed on it by the workflow.
- **The job container** is where the dependencies are installed, Node.js is compiled (with or
  without the FV8 patch), and the runtime, npm, the canary and the probe run.
- **FV8** runs inside the container: the Node.js binary containing FV8 is built by a step in the
  container and executed by later steps in the container.
- **npm and the package's JavaScript** run inside the container. With the default
  `npm_host: fv8-node`, npm itself runs on the FV8 runtime; with `system-node` it runs on
  setup-node's Node.js 22 (from the tool cache mounted at `/__t`), still inside the container.
- **No nested container.** FV8 does not need Docker, and none is used.

## 6–8. Versions

Values marked "VM run" are from the successful Experiment A control run 38428556729 (runtime
built in run 38414344669). Values for Experiment B are recorded by each run; see
`container-metadata.json`.

| | Value |
| --- | --- |
| FV8 commit | `wspr-ncsu/FV8@57fc2b2699563316958603934aba572907171162` (submodule `tools/fv8`, verified) |
| FV8 patch | `patches/V8_patch_122.diff`, SHA-256 `6dc76720…0a3c39`, applied unmodified (`patch -p2 -F0 --forward`) |
| Authors' build (inspected, not run) | Chromium 122.0.6261.111, V8 12.2.281.21 |
| Node.js | `nodejs/node@07f481cf`, `v22.0.0-pre`, V8 `12.2.281.27-node.10` (VM run) |
| npm | 10.5.2, bundled with that commit (`npm_host: fv8-node`) |
| Outer Node.js (setup-node 22) | v22.23.3 / npm 10.9.9 on the VM run; same action and version spec in the container |
| Container image | `ubuntu:24.04`, pinned to the **linux/amd64 platform manifest** `sha256:f610ab94648195aa356059f5b41d6085c9d4d903c072430cdd1af7bdb646106b` (multi-arch index at the time of pinning: `sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55`; image created 2026-09-17) |
| Architecture | linux/amd64 (x86_64) |

**Why `ubuntu:24.04`.** Experiment A built and ran Node.js on Ubuntu 24.04.5 with GCC 13.3 and
Python 3.12 (recorded in `build-info.json` of run 38414344669). `ubuntu:24.04` gives the same
release, glibc, GCC 13 and Python 3.12 from the same archive. Alpine (musl), `node:*-slim`
(Debian) or Ubuntu 22.04 (GCC 11, glibc 2.35) would change the toolchain and C library the
runtime is built against.

## 9. Changes compared with the VM experiment

**FV8 itself: none.** The `fv8_fixes` input (section 9a of the setup notes) exists in both
experiments, with the same patch and default. Same FV8 commit, same patch file (hash-checked), same patch options, same
compatibility header, same Node.js commit, same configure options (`--v8-options=--no-lazy`,
snapshot on), same canary, same npm command and same probe tarball, with the same input defaults.
The scripts in `experiments/fv8/` are used byte-for-byte.

Changes, all caused by the container layer (marked `CONTAINER:` in the workflow):

| Change | Why |
| --- | --- |
| `apt-get install git ca-certificates python3 g++ make patch jq xz-utils procps` | The image has none of the runner's preinstalled tools. The list is exactly what the scripts, `actions/checkout` and `actions/setup-node` call. Installed versions are in `logs/container-setup.log`. |
| `defaults.run.shell: bash` | Container jobs default to `sh`; the scripts are Bash. (The VM job also sets Bash.) |
| `GIT_CONFIG_COUNT/KEY_0/VALUE_0` = `safe.directory=*` on the steps that run git | The workspace belongs to the runner's uid and steps run as root, so git refuses it ("dubious ownership"; reproduced locally). Passed as step variables instead of `git config --global`, because the probe records whether `~/.gitconfig` exists. The probe-install step does not get them. |
| Build directory `$RUNNER_TEMP/node-build` (`/__w/_temp`) instead of `/mnt/node-build` | No `sudo`, and `/mnt` is not mounted into the container. Adding a mount would change what the probe sees. |
| The runtime is **compiled in the container**, with its own cache key (`node-runtime-v1-container-ubuntu24.04-f610ab946481-…`) | So the FV8 binary is never one built on a hosted VM. Toolchain packages come from the image's apt archive, so their exact versions may differ from the VM image's preinstalled GCC; both are recorded. The binary hash will differ from the VM build. |
| Layer snapshots, container checks, `container-metadata.json` | Added (section 10). |

The probe is unchanged, and no experiment-specific environment variables reach it.

Differences the probe will observe that come from **being in a container**, not from FV8: user
`root` with `HOME=/github/home`; PID 1 `tail`; `/.dockerenv`; overlay root; container hostname;
container cgroup; far fewer tools (no Docker CLI, browsers, language toolchains) and a shorter
`PATH`; the workspace at `/__w`. These are the effects this experiment measures.

## 10. How execution inside the container is verified

`experiments/fv8-container/verify-container-layer.sh` → `checks/container.json`:

1. **Harness snapshots** (`record-container-layer.sh`) taken in the container steps before the
   build and just before the probe install: `/.dockerenv` present, overlay root filesystem, PID 1
   is not `systemd`/`init` (in a job container it is `tail`), Ubuntu 24.04 userland. On the hosted
   VM the probe recorded PID 1 `systemd`, no Docker marker file and no overlay mount.
2. **Build provenance**: the same snapshot is taken in the build step and stored with the runtime
   (`<runtime>/fv8-experiment/container/runtime-build.json`), so even a runtime restored from the
   cache proves it was compiled inside a job container. The cache key namespace also excludes
   VM-built runtimes.
3. **Paths**: the runtime, the install directory and npm's `node` are under the container's
   `/__w` or `/__t` mounts.
4. **The lifecycle process**: the canary package's `postinstall` reports `process.execPath` =
   the container's runtime binary.
5. **The probe's own view** (read from its unchanged report): `Docker marker-file presence` =
   true, `Overlay filesystem mount presence` = true, `PID 1 executable basename` = the container's
   PID 1 (`tail`), not `systemd`.

FV8 is verified exactly as in Experiment A (`checks/runtime.json`, `smoke.json`, `probe.json`):
FV8 code in the binary, all never-taken canary branches force-executed directly and through the
npm lifecycle, `Found match for API` output, VisibleV8 logs, and a VisibleV8 record of
`npm-probing-package/scripts/postinstall.js` from the probe's process. The probe check also
requires the probe's own `Node.js version` / `V8 engine version` to equal the runtime's
(`22.0.0-pre` / `12.2.281.27-node.*`). setup-node's Node.js 22 reports V8 12.4, so a fallback
to ordinary Node fails. If the container stops FV8 from working, these checks fail and the run is
labelled accordingly. Nothing falls back.

`experiment-manifest.json` → `experiment_valid` is true only if all four check groups pass
(runtime, smoke, probe, container).

## 11. How the probe JSON is recovered

As in Experiment A: the probe writes
`$RUNNER_TEMP/install-probe/node_modules/npm-probing-package/results/install-<uuid>.json`
(`/__w/_temp/…` in the container) with its default mechanism; the harness copies it to
`results/fv8-container/<run-id>/probe/`. A missing report fails the probe check; nothing is
created in its place.

## 12. Artifacts

`actions/upload-artifact@v4`, `if: always()`, so logs and metadata are kept when a step fails.
Name `fv8-container-<run_id>-<run_attempt>` (control: `fv8-container-control-<run_id>-<run_attempt>`),
containing `results/fv8-container/<run_id>/`:

```text
probe/install-<uuid>.json            the probe's report                     ← dataset
container-metadata.json              outer runner / job container / analysis layers ← dataset
experiment-manifest.json             VM-experiment schema + execution_environment   ← dataset
environment-metadata.json            runner/OS/CPU/memory seen from the container, before the runtime
fv8-metadata.json                    FV8 + runtime provenance
harness-classification.json          verification summary and label
checks/{runtime,smoke,probe,container}.json
container/{before-build,before-probe,runtime-build}.{json,txt}   layer snapshots
runtime/                             build info, patch log, self-test, canary
install/probe/                       npm-install.log (execution log), vv8-logs/, forced-execution markers, npm-logs/
install/smoke/                       canary package install
fv8/released-build.json              authors' Chromium .deb, inspected
logs/setup-build.log                 Node.js build log (from the building run if cached)
logs/container-setup.log             apt packages installed in the container
diagnostics/                         only with crash_diagnostics=true and a build that failed in node_mksnapshot:
                                     gdb backtrace, VisibleV8 log tails, summary.json
logs/github-host.txt, runtime-source.txt, credential-scan.txt
```

The same credential-string check as Experiment A runs before upload. No secrets are passed to the
job, and permissions are `contents: read`.

## 13. Running it

GitHub → **Actions** → **Environment Probe - GitHub Ubuntu container job + FV8** → **Run workflow**
→ branch `main`, `variant: fv8`, `fv8_fixes: property-case+parser-reset` (with `none` or `property-case` the build crashes, see above),
other inputs at their defaults (the same defaults as Experiment A)
→ **Run workflow**. For the matched control in the container, run it again with `variant: control`.

```bash
gh workflow run fv8-container-probe.yml --ref main -f variant=fv8 -f fv8_fixes=property-case+parser-reset -f crash_diagnostics=true
gh workflow run fv8-container-probe.yml --ref main -f variant=control
gh run download <run-id> -n fv8-container-<run-id>-1
```

The first run of each variant compiles Node.js in the container (about 70–80 minutes, as on the
VM); later runs restore it from the container cache and re-verify it.

## 14. Configuration comparison

| Property | FV8 on hosted VM (A) | FV8 in job container (B) |
| --- | --- | --- |
| Outer GitHub runner | `ubuntu-24.04` (image 20261004.327.1 on run 38428556729) | `ubuntu-24.04` (image version recorded when the runner passes it) |
| Container layer | No | Yes: `ubuntu:24.04@sha256:f610ab94…` (amd64) |
| FV8 commit | `57fc2b26…` | `57fc2b26…` |
| FV8 patch | `V8_patch_122.diff` verbatim | same file, same hash, same options |
| Researcher fixes (`fv8_fixes`) | `none`, `property-case` or `property-case+parser-reset` | same input, same patch files; must match A when comparing |
| FV8 forced execution | always on in the patched build; `--no-lazy`; verified by canary (only the control has run so far) | same build options; verified by the same canary |
| V8 / Chromium base | runtime V8 12.2.281.27; authors' build Chromium 122.0.6261.111 / V8 12.2.281.21 | same |
| Node.js | `v22.0.0-pre` (`07f481cf`) | `v22.0.0-pre` (`07f481cf`), compiled in the container |
| Toolchain | runner GCC 13.3.0-6ubuntu2~24.04.1, Python 3.12.3 | `ubuntu:24.04` apt `g++`/`gcc` 13.x, Python 3.12 (exact versions in `build-info.json` and `logs/container-setup.log`) |
| npm | 10.5.2 (`npm_host: fv8-node`) | 10.5.2 (`npm_host: fv8-node`) |
| Probe | `npm-probing-package@0.1.0`, `packages/npm-probing-package-0.1.0.tgz` | same tarball (hash recorded in the manifest) |
| FV8 harness | `experiments/fv8/*`, `npm install <tgz> --foreground-scripts`, runtime first on PATH | same scripts, same command |
| User / HOME | `runner` / `/home/runner` | `root` / `/github/home` |
| Runtime path | `/home/runner/work/_temp/node-runtime` | `/__w/_temp/node-runtime` |

Check before analysis: compare `runtime/build-info.json` (toolchain, configure, node commit) and
`experiment-manifest.json` of an A run and a B run of the same variant. The rows above that differ
(container, toolchain package build, user/HOME, paths) are the intended or unavoidable
differences.
