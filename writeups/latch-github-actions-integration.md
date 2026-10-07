# Integrating LATCH into a GitHub Actions Ubuntu VM

How the LATCH npm install-time analysis system was reproduced on a GitHub-hosted
Ubuntu runner, so that the environment-probing package could be installed under LATCH
and compared with a plain-npm install on the same kind of runner. Written as source
material for the methods, results and threats-to-validity sections of the paper.

Implementation: `.github/workflows/latch-probe.yml` and `experiments/latch/`
(the technical README there lists every file and patch).
Reference run: GitHub Actions run `37551729431`, 2026-10-07, all checks passed.

---

## 1. Purpose and study design

The study measures which environmental properties an npm package can observe during
installation, across different execution environments. LATCH is a published research
system that analyzes install-time behavior of npm packages by tracing lifecycle scripts.
The question for this condition: **what does a package see when it is installed
under LATCH?**

Two conditions run on the same host type with the same probe artifact:

| | Experiment A: baseline | Experiment B: LATCH |
| --- | --- | --- |
| Workflow | `probe.yml` | `latch-probe.yml` |
| Host | GitHub-hosted `ubuntu-24.04` VM | GitHub-hosted `ubuntu-24.04` VM |
| Isolation | none | Apptainer 1.5.4 → LATCH image (Ubuntu 20.04) |
| Package manager | runner npm (10.x) | LATCH-modified npm 6.14.8 |
| Node.js | 22 (`actions/setup-node`) | 22.23.3 (inside the LATCH image) |
| Lifecycle execution | `sh -c` | `strace -ff -ttt -yy … sh -c` |
| Probe | `npm-probing-package-0.1.0.tgz` | same file (sha256 `8ba84a1e…084ba4`) |
| Output | probe JSON | probe JSON + strace traces + LATCH manifest |

The probe is a benign package whose `postinstall` hook records 200 catalogued
environment properties into `install-<uuid>.json`. It reports only the presence of
credential-like variables and files, never their contents, and it does not change
behavior based on what it finds.

## 2. LATCH as published

LATCH (repository `elizabethwyss/Latch`) analyzes npm packages in this order:

```text
npm install
→ modified npm lifecycle handling (npm-lifecycle)
→ each lifecycle script executed under strace
→ per-process system-call traces
→ strace parser (extended b3 PEG grammar)
→ syscall analyzer (OS-state model: processes, fd tables, IPC)
→ per-script permission/behavior manifest
→ (optional) policy evaluation, AppArmor enforcement
```

This study uses the **analysis / manifest-generation path** only. The policy engine and
AppArmor enforcement are not used.

The artifact was built for the authors' environment: a Singularity image of Ubuntu
20.04 with Node 12 and a large set of toolchains, batch jobs on a SLURM cluster, and
hard-coded paths from the authors' machines.

### Gaps found in the published artifact

Inspecting the repository at commit `a57345f` showed three gaps that block a direct
reproduction:

1. **The modified npm is not in the artifact.** The README says one file was modified,
   `cli/node_modules/npm-lifecycle/index.js` (function `createExec`). In the repository,
   `cli` is a git submodule entry (gitlink) with no `.gitmodules` URL. It points to
   `npm/cli@bd2721d`, an *unmodified* npm commit (v6.14.8 plus one documentation
   commit). That commit's `npm-lifecycle/index.js` is byte-identical to the stock
   `npm-lifecycle@3.1.5`. The modified file is not publicly available.
2. **Manifests are never written.** `Analyzer.Analyze()` builds the manifest object, but
   the call that saves it (`this.WriteToFile(manifest, …)`) is commented out.
3. **Runtime incompatibility with a modern package.** The probe declares
   `engines.node >= 22` and uses top-level `await`, `?.` and `??`. Under LATCH's Node 12
   (tested with 12.22.12) its postinstall fails to parse
   (`SyntaxError: Unexpected reserved word`). LATCH's analyzer itself runs on Node 12
   and Node 22.

## 3. Reproduction on GitHub Actions

### 3.1 Environment stack

```text
L1  GitHub-hosted VM            ubuntu-24.04 (Ubuntu 24.04.5 LTS, kernel 6.17.0-1022-azure, x86_64)
L2  Container runtime           Apptainer 1.5.4 (unprivileged run; image built with sudo)
L3  LATCH analysis image        Ubuntu 20.04 via debootstrap, upstream package list
L4  LATCH npm                   npm 6.14.8 + reconstructed lifecycle hook, on Node.js 22.23.3
L5  Lifecycle tracing           strace 4.26 (-ff -ttt -yy), one trace file per process
L6  Package                     npm-probing-package 0.1.0, postinstall hook
```

Apptainer was chosen as the maintained continuation of Singularity, which LATCH was
built for. No GitHub Actions job container (`container:`) and no Docker nesting are
used.

### 3.2 Source pinning

| Component | Pin |
| --- | --- |
| LATCH | `elizabethwyss/Latch@a57345fba86a176bf32c888592582f194fafa5bb` (git submodule `tools/latch`) |
| npm base for LATCH | `npm/cli@bd2721dbc3de13a5ba889eba50644475d80f6948`, the commit LATCH's own gitlink names (submodule `tools/npm-cli`) |
| Apptainer | 1.5.4 release `.deb`, sha256-verified |
| Node.js in image | 22.23.3 nodejs.org tarball, sha256-verified (12.22.12 available as an alternative) |
| Analyzer dependencies | pinned lockfile (glob 7.1.6, n-readlines 1.0.1, pegjs 0.10.0, pegjs-backtrace 0.1.2, debug 4.3.1, node-exceptions 4.0.1) |

The workflow checks that both submodules sit at these commits, and that LATCH's own
`cli` gitlink matches the npm submodule. Upstream files are never edited in place:
they are exported with `git archive`, and the reproduction patches are applied to
that copy at image build time.

### 3.3 Adaptations to LATCH

Each change is the smallest one that let the experiment run. Changes to what LATCH
observes and analyzes are marked as such.

| # | Change | Reason | Effect on LATCH semantics |
| --- | --- | --- | --- |
| A1 | **Reconstructed lifecycle hook.** Each lifecycle script runs as `strace -ff -ttt -yy -o /straces/<name@version>/<name@version>_<stage> sh -c <cmd>`. The hook writes `_finished` on exit 0, `_killed` after a 10-minute timeout, and `_exit` with the status. | Gap 1. Flags and file layout come from what the analyzer and grammar consume: per-pid files (`-ff`, pid taken from the file suffix), epoch timestamps (`-ttt`, used to merge processes in time order), decoded file descriptors (`-yy`, read from fd arguments and results), and the `_finished` / `_killed` markers the analyzer checks. The `name@version` key matches upstream's package lists and published results. | Intended to match the analyzer's input contract. **It is a reconstruction, not the authors' code**: unpublished details such as the string-length limit or the timeout value may differ. |
| A2 | Re-enabled the commented-out `WriteToFile` call. | Gap 2. | None. Upstream's own serializer, file name and JSON format are used. |
| A3 | The analyzer's initial working directory can be set by an environment variable, with upstream's hard-coded path as the fallback. | Removes the authors' machine path (`/home/user/Documents/research/malicious_packages/<pkg>`), so relative paths resolve against the real lifecycle directory. The variable is set only in the analyzer process, after the probe has finished. | Fixes path attribution; no other change. |
| A4 | The analyzer prints swallowed exceptions to stderr. | Upstream recorded only `analyzer_failed`. | None (diagnostic only). |
| A5 | Node.js installed from the official tarball into `/usr` instead of the NodeSource `setup_12.x` script. | That script is retired; the tarball is pinned and checksum-verified. `/usr` matches the NodeSource layout. | None on LATCH code. |
| A6 | **Node 22.23.3 inside the image (upstream: Node 12).** | Gap 3. With Node 12 the probe cannot run, so nothing can be measured. Node 22 also matches the baseline condition. LATCH's npm (6.14.8) and analyzer are unchanged. | Runtime deviation. The Node 12 runtime remains available as a control condition. |
| A7 | `strace` installed explicitly; babel global packages pinned; non-interactive apt at build time only. | Hook dependency, unattended build, pinning. | None. |
| A8 | Analyzer and its dependencies added to the image; manifests generated inside the image. | Upstream ran the analyzer on the cluster host and shipped no dependency list. | None intended. |
| A9 | Single-package script takes the tarball path, uninstall name and trace key separately. It copies the probe report out between install and uninstall, and exits non-zero on install failure. | Upstream installed by `name@version` from a registry mirror; uninstall deletes the probe's output. | None. The copy happens after `npm install` returns. |
| A10 | Image `%files` sources come from a staged build directory, not the authors' paths. | Hard-coded paths. | None. |

Kept as published: Ubuntu 20.04 image built with `debootstrap` from
`us.archive.ubuntu.com`, and the full `%post` package list (about 60 packages, including
JDK, Rust, Go, Haskell, Ruby, Elixir, Erlang, clang and build-essential). Also kept: the
`%runscript` (fresh directory, blank `package.json`, `npm config set cache ./cache`), the
`singularity run`-style launch with a custom home and `/straces`, `/packages` and
`/InstancePkgs` binds, the work directory under `/dev/shm/Instances/`, inheritance of
the host environment, install followed by uninstall, and the analyzer's logic.

### 3.4 Execution procedure

The workflow (`workflow_dispatch`) runs these steps, each as a separately reported step:

1. Check out the repository; fetch the two pinned submodules (non-recursive, because
   LATCH's `cli` gitlink cannot be resolved).
2. Verify the submodule commits and that the LATCH gitlink matches the npm pin.
3. Record host metadata (OS, kernel, CPU, memory, disks, user-namespace and ptrace sysctls).
4. **Prerequisite check:** strace can trace a process on the runner.
5. Install and verify Apptainer (pinned `.deb`; load its AppArmor profile, which Ubuntu
   24.04 needs for unprivileged user namespaces).
6. Build `latch.sif` (most of the roughly 10-minute run).
7. Verify the image: OS, Node version, LATCH npm version 6.14.8, hook and manifest patch
   present, strace works for an unprivileged user inside Apptainer.
8. Smoke test: install a minimal package with a `postinstall` through LATCH and check
   that its trace was produced. Its instance is then deleted.
9. Install the probe tarball through LATCH npm inside the image.
10. Validate the probe report, the traces and the manifest (Section 4).
11. Write `metadata/experiment.json` and upload all outputs as an artifact
    (`github-actions-ubuntu-latch-<run_id>-<attempt>`) even when a step fails.

### 3.5 Measurement hygiene

- Apptainer passes the host environment into the image, as upstream's `singularity run`
  did. The workflow therefore defines no job-level variables and never writes
  `$GITHUB_ENV`, and experiment labels exist only in the metadata step. The probe sees
  the same GitHub-provided variables as in the baseline, plus whatever Apptainer sets.
- No mounts beyond upstream's are added for the probe run. The report is returned
  through `/dev/shm`, which Apptainer already shares.
- No synthetic credentials, configuration files, shell history, caches or tools are
  added. The only state created before installation is upstream's own (`package.json`,
  npm cache configuration).
- Experiment metadata is stored separately from the probe's report and never
  inserted into it.

## 4. Validation: establishing that the probe ran under LATCH

A successful `npm install` is not accepted as evidence. A run counts as valid only if
the probe report, the traces and the manifest each pass their checks, and if they
corroborate each other:

**Probe report.** A report was recovered with `phase = postinstall`. In it:
- `npm lifecycle event name = postinstall`
- `Package-manager version = 6.14.8` (LATCH's npm, not the runner's)
- `Own process tracer status = true` (`TracerPid ≠ 0` in `/proc/self/status`)

**Trace.**
- Postinstall trace files exist and are non-empty.
- The `_finished` marker is present.
- The trace contains `execve(…/sh, ["sh","-c","node scripts/postinstall.js"])` and a
  successful `execve(…/node, ["node","scripts/postinstall.js"])`.
- **The recovered report's file name, which contains a random UUID, appears in the
  trace** (open, write, rename). This links that specific report to the traced process.

**Manifest.**
- The analyzer reported every traced script as usable.
- The postinstall manifest is valid JSON with all 25 manifest fields.
- It lists `node scripts/postinstall.js` among executed programs.
- It records the creation and rename of the same report file.

Negative cases were tested: an untraced report, a wrong npm version, a missing
`_finished` marker and a report name absent from the trace each fail validation.

## 5. Results of the reference run (37551729431)

All checks (smoke, probe, trace, manifest) passed.

**LATCH output.** The postinstall phase produced 12 per-process trace files (2.98 MB)
and one manifest. The analyzer reported no errors. Manifest summary:

| Field | Value |
| --- | --- |
| successful / timedOut | true / false |
| runtime (trace span) | 2.35 s |
| executed programs (`lowerExecs`) | 1: `/usr/bin/node node scripts/postinstall.js` |
| elevated executions | 0 |
| metadata requests | 1,677 paths |
| files opened for reading | 2,223 |
| files read | 1,462 |
| files opened for writing / written / created / renamed / deleted | 2 / 1 / 4 / 1 / 1 |
| network hosts (public / private / local) | 0 / 0 / 0 |

LATCH thus describes the probe as reading a large part of the visible filesystem and
`/proc` metadata, writing a single report, and making no network connections. This
matches the probe's actual behavior.

**What the probe observed under LATCH** (selected properties):

| Property | Value under LATCH |
| --- | --- |
| OS distribution / version | `ubuntu` / `20.04` (image), while kernel release is `6.17.0-1022-azure` (host) |
| Package manager | `npm 6.14.8`; user agent `npm/6.14.8 node/22.23.3 linux x64` |
| Node.js version | 22.23.3 |
| Lifecycle event | `postinstall` |
| Own process tracer status | `true` |
| Parent process | `dash` |
| Ancestor process chain | `dash ← strace ← node ← dash ← node ← dash ← starter ← bash ← bash ← Runner.Worker ← Runner.Listener` (truncated by the probe's limit) |
| NoNewPrivs | `true` |
| Seccomp mode | `0` |
| Effective UID | 1001 (unprivileged runner user) |
| Container environment variable present | `false` |
| Hostname container-like pattern | `false` |
| Cgroup | v2, path template `/system.slice/<group>`, memory limit unlimited |
| Ancestor project | `package.json` and `node_modules` present; no lockfile, `.git` or `.npmrc` |

The ancestor chain exposes the whole analysis stack, from inner to outer:
1. the lifecycle shell (`dash`);
2. LATCH's tracer (`strace`);
3. LATCH's npm (`node`);
4. the container script and runscript (`dash`, `node`, `dash`);
5. Apptainer's `starter`;
6. the workflow shells (`bash`, `bash`);
7. the GitHub runner agent (`Runner.Worker`, `Runner.Listener`).

## 6. Signals that distinguish the LATCH environment

Compared with the baseline (Experiment A), these properties differ in ways a package
could observe at install time:

- **Tracing is directly visible:** `TracerPid ≠ 0`, and `strace` appears in the
  ancestor chain.
- **Container runtime is visible through ancestry** (`starter`) and through
  `NoNewPrivs = true`, even though no container environment variable is detected.
- **Package-manager version is out of date** (npm 6.14.8 with Node 22), an unusual
  combination for a developer machine or CI system in 2026.
- **Distribution and kernel disagree:** the userland reports Ubuntu 20.04 while the
  kernel is a 2026 Azure kernel. A native 20.04 system would have a 5.x kernel.
- **Installation context is synthetic:** a project directory under
  `/dev/shm/Instances/…`, a blank `package.json` and no lockfile.
- **CI variables are inherited:** because the host environment passes through, the
  probe still sees it is running on GitHub Actions. (The original artifact passed
  through its cluster's environment in the same way.)

(Baseline values for the same properties should be taken from Experiment A's report
when writing the comparison. They are not repeated here.)

## 7. Threats to validity and limitations

- **Reconstructed hook.** The authors' modified `npm-lifecycle` is unpublished.
  Ours follows the analyzer's input contract and the README's description, but
  unpublished details may differ, such as strace's default 32-byte string limit or
  the timeout value. Manifest content depends on these only marginally; probe-visible
  properties do not depend on them, except for the shape of the process tree.
- **Runtime deviation (Node 22 vs 12).** Needed for the probe to run at all.
  Properties tied to the Node runtime (Node and V8 versions, ABI, module search paths)
  therefore reflect Node 22, not LATCH's original runtime. Running with Node 12 confirms
  the probe cannot execute there.
- **The image Node install overlays a distro package.** The upstream package list pulls
  in Ubuntu's `nodejs` 10.19 as a dependency of other tools (e.g. `node-typescript`,
  `webpack`). The pinned Node 22 tarball replaces `/usr/bin/node` but leaves the distro
  package's other files. Upstream had the same layering, with NodeSource Node 12 over
  the distro package.
- **Ubuntu release pocket only.** As in the upstream definition, the image is
  bootstrapped from `focal` without `focal-updates` or `focal-security`, so it carries
  2020 release versions (e.g. strace 4.26). This matches the artifact but is not a
  patched 20.04 system.
- **Present-day packages from a moving source.** The Go backports PPA provides today's
  Go (1.25), not the 2020–2021 version. Apart from the pinned items, apt packages are
  whatever the focal archive serves at build time. The image digest of each run is
  recorded (reference run: sha256 `664f377d…bb2f8`).
- **Outer environment differs from the original.** A GitHub-hosted VM with Apptainer
  replaces a university cluster with Singularity. Kernel, CPU, cgroup layout and the
  outer process tree come from GitHub's runner.
- **Analysis path only.** Policy evaluation and AppArmor enforcement were not
  reproduced. Results say nothing about LATCH's enforcement mode.
- **Single run so far.** Results come from one reference run. Repeated runs are needed
  before claiming stability of volatile properties such as uptime, memory or hostnames.

## 8. Reproducibility record

| Item | Value (reference run) |
| --- | --- |
| Runner label / OS / kernel | `ubuntu-24.04` / Ubuntu 24.04.5 LTS / 6.17.0-1022-azure, x86_64 |
| Host strace | 6.8 |
| Apptainer | 1.5.4 |
| LATCH commit | `a57345fba86a176bf32c888592582f194fafa5bb` |
| npm/cli commit (LATCH npm) | `bd2721dbc3de13a5ba889eba50644475d80f6948` → npm 6.14.8 |
| Image OS / Node / bundled npm / strace | Ubuntu 20.04 LTS / v22.23.3 / 10.9.9 / 4.26 |
| Image sha256 | `664f377d9eccd17323882cf279ca433edd488fae49e6f5d9a5d9fb01c6bbb2f8` |
| Probe | npm-probing-package 0.1.0, tarball sha256 `8ba84a1e7145dd5024380a9177cd24939591c0822b06afb37568f661ea084ba4` |
| Run | GitHub Actions run `37551729431`, attempt 1, 2026-10-07 |
| Outputs | artifact `github-actions-ubuntu-latch-37551729431-1` |

Full per-run metadata is in `metadata/experiment.json` in each artifact.

## 9. Draft methods paragraph

> To observe the install-time environment presented by an academic npm analysis
> system, we reproduced LATCH's analysis pipeline on a GitHub-hosted Ubuntu 24.04
> runner. LATCH (commit a57345f) runs npm lifecycle scripts under strace and derives
> per-script behavior manifests from the system-call traces. Because the published
> artifact omits its modified npm lifecycle module and does not persist manifests, we
> reconstructed the lifecycle hook from the analyzer's input format (`strace -ff -ttt
> -yy` per lifecycle script, on the npm 6.14.8 commit the artifact references), and
> re-enabled the artifact's own manifest serializer. We kept the original Ubuntu
> 20.04 analysis image definition, building it with Apptainer 1.5.4 in place of
> Singularity, and replaced only the unavailable Node.js 12 installer. We ran Node.js
> 22 inside the image because the probe requires it; Node.js 12 cannot execute the
> probe. The same probe tarball used in the baseline condition was installed with
> LATCH's npm inside the image. A run was accepted only if:
> (i) the probe report recorded LATCH's npm version and an active tracer;
> (ii) the postinstall traces contained the probe's execution and the creation of
> that specific report (identified by its random file name); and
> (iii) the generated manifest recorded the same execution and file creation.
