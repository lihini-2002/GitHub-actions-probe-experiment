# Integrating Packj `audit --trace` into a GitHub Actions Ubuntu VM

How Packj's dynamic-analysis mode (`audit --trace`) was run on a GitHub-hosted Ubuntu
runner, so that the environment-probing package could be installed under Packj's tracing
and compared with a plain-npm install on the same kind of runner. Written as source
material for the methods, results and threats-to-validity sections of the paper.

Implementation: `.github/workflows/github-actions-ubuntu-packj-trace.yml` and
`experiments/packj/` (the technical README there lists every file and the patch).
Reference run: GitHub Actions run `37590896326`, 2026-10-07, all checks passed.
Packj's sandbox mode is a separate condition, described in
`packj-sandbox-github-actions-integration.md`.

---

## 1. Purpose and study design

The study measures which environmental properties an npm package can observe during
installation, across different execution environments. Packj (Ossillate) is an
open-source tool that audits packages for risky attributes. Its `--trace` flag adds
dynamic analysis: the package is installed under `strace`, and the system calls are
summarized. The question for this condition: **what does a package see when it is
installed under Packj's dynamic tracing?**

| | Experiment A: baseline | Packj trace |
| --- | --- | --- |
| Workflow | `probe.yml` | `github-actions-ubuntu-packj-trace.yml` |
| Host | GitHub-hosted `ubuntu-24.04` VM | GitHub-hosted `ubuntu-24.04` VM |
| Isolation | none | none (Packj trace mode does not isolate) |
| Package manager | runner npm 10.9.9 (`npm ci` in this repository) | runner npm 10.9.9 (`npm install <tarball>` in an empty directory, started by Packj) |
| Node.js | 22.23.3 (`actions/setup-node`) | 22.23.3 (`actions/setup-node`) |
| Lifecycle execution | `sh -c` | `strace -f -e trace=network,file,process … npm install`, so `sh -c` runs traced |
| Probe | `npm-probing-package-0.1.0.tgz` | same file (sha256 `8ba84a1e…084ba4`) |
| Output | probe JSON | probe JSON + Packj audit report + strace log + Packj syscall summary |

The probe is a benign package whose `postinstall` hook records 200 catalogued
environment properties into `install-<uuid>.json`. It reports only the presence of
credential-like variables and files, never their contents, and it does not change
behavior based on what it finds. It makes no network connections.

## 2. Packj `audit --trace` as published

Packj repository `ossillate-inc/packj`, pinned at commit `dfd2c70` (version 0.15, the
`main` branch head on 2026-09-17). The command is
`python3 main.py audit --trace -p <ecosystem>:<package>`, and runs:

```text
metadata checks (registry, repository, author, CVEs via OSV)
→ static analysis of the package archive (API usage, composition)
→ trace stage: strace -f -e trace=network,file,process -ttt -T -o <dir>/trace_*.log \
                 npm install --silent --no-progress --no-update-notifier <package>
→ strace log parsed into a syscall summary (<dir>/summary_*.json)
→ per-package report (report_*.json) and HTML summary
```

The trace stage runs `npm install` from Packj's own working directory. Outside
Docker/Podman, Packj first asks on stdin whether to continue. Its README recommends
`--trace` only inside a container or VM; the GitHub VM satisfies that.

### Gaps found in the published code

1. **Every stage failure is swallowed.** Each stage catches its own exceptions, prints
   `FAIL [...]`, and the audit continues. Packj exits 0 even when the trace stage failed,
   so a static-only run looks like a successful dynamic analysis from the exit status.
2. **A local package cannot be traced.** `npm:<name>` fetches metadata from the
   hard-coded `registry.npmjs.org`. The probe is not published (the registry returns 404),
   so the audit stops before tracing. Publishing it was ruled out: it would also be
   unsafe, since anyone could later claim the name. `local_nodejs:<path>`, the documented
   form for local packages, cannot trace at this commit. Tested against unmodified
   upstream with the extracted probe directory:
   - the audit aborts with exit 1 in `analyze_repo_url` (`local variable 'repo_url'
     referenced before assignment`), because the probe has no `repository` field;
   - with only that fixed, the trace stage prints
     `FAIL [Package manager local_nodejs is not supported]`, Packj exits 0, and nothing is
     installed. `get_pm_install_cmd` has no `local_nodejs` branch.

## 3. Reproduction on GitHub Actions

### 3.1 Environment stack

```text
L1  GitHub-hosted VM     ubuntu-24.04 (Ubuntu 24.04.5 LTS, kernel 6.17.0-1022-azure, x86_64), no job container
L2  Packj                0.15 @ dfd2c70, Python 3.10 venv, run from source (main.py)
L3  Tracer               system strace 6.8 (apt), started by Packj
L4  npm                  runner npm 10.9.9 on Node.js 22.23.3 (actions/setup-node)
L5  Package              npm-probing-package 0.1.0, postinstall hook
```

### 3.2 Source pinning

| Component | Pin |
| --- | --- |
| Packj | `ossillate-inc/packj@dfd2c70c4b6dde0327888d62fa7d3df0661d0dfc` (git submodule `tools/packj`; the workflow fails on any other commit) |
| Packj Python dependencies | upstream `requirements.txt` (direct pins), plus a constraints file pinning all 38 resolved packages; exact `pip freeze` saved per run |
| Python | newest 3.10.x in the runner tool cache (3.10.21 in the reference run) |
| Node.js / npm | `actions/setup-node`, `node-version: "22"`, as in the baseline (22.23.3 / 10.9.9 in the reference run) |
| strace | Ubuntu 24.04 package (6.8) |

Upstream files are never edited in place. `tools/packj` is exported with `git archive`
and the patch below is applied to that copy.

### 3.3 Adaptations to Packj

| # | Change | Reason | Effect on Packj semantics |
| --- | --- | --- | --- |
| P1 | `get_pm_install_cmd` gets a `local_nodejs` branch: the npm branch's exact command, `npm install --silent --no-progress --no-update-notifier <path>`, without the `@<version>` suffix. | Gap 2: without it the trace stage cannot install a local package. | None on tracing. npm's argument is a tarball path instead of `name@version`. |
| P2 | `local_nodejs` accepts a `.tgz`: `package.json` and `README.md` are read from `package/` inside the tarball. | A directory would make npm 10 create a symlink and run the postinstall in the source directory. A tarball is extracted into `node_modules/`, as in the baseline and the LATCH condition. | None on tracing. Metadata checks read the same fields from the tarball. |
| P3 | `audit()` uses a local `.tgz` as the static-analysis input instead of trying to download it. | So static analysis runs on the same tarball that is installed. | None. |
| P4 | `analyze_repo_url` initializes `repo_url = None`. | Upstream bug (gap 2): the audit aborts for any package without a `repository` field. | None. |
| P5 | Python 3.10 instead of the runner's 3.12. | Packj pins 2020–2022 packages (`PyYAML 6.0`, `protobuf 3.19.4`, `Django 4.1.1`) that do not install on 3.12. Upstream's Dockerfile uses Ubuntu 22.04, which has Python 3.10. | None. |
| P6 | `bundle install` (Ruby gems) skipped; `libmagic1t64` installed. | Ruby gems are used only for Ruby packages; `python-magic` needs libmagic (upstream's Dockerfile installs it). | None for npm. |

P1–P4 are a patch of 33 added lines and 1 changed line across three files (`packj/audit/main.py`,
`packj/audit/pm_util.py`, `packj/audit/pm_proxy/local_nodejs.py`). The strace command, its
flags, the trace parser and the report writers are upstream's.

### 3.4 Execution procedure

The workflow (`workflow_dispatch`) runs these steps, each as a separately reported step:

1. Check out the repository; fetch and verify the pinned Packj submodule.
2. Set up Node.js 22 as in the baseline.
3. Record host metadata (OS, kernel, ptrace scope, tool versions, CPU, memory, disks).
4. **Prerequisite check:** strace can trace `/bin/echo` on the runner.
5. Select Python 3.10 from the tool cache, export Packj, apply the patch, install
   dependencies into a venv, and copy `.packj.yaml` to `~` (as Packj's `setup.py` does).
6. Verify the Packj CLI: `audit --help` offers `--trace`, the dependencies import, and the
   patched code builds the expected `npm install` command for a tarball.
7. Locate and validate the probe tarball: it is the file the baseline installs, and its
   `postinstall` is `node scripts/postinstall.js`.
8. Run `printf 'y\n' | python3 main.py audit --debug --trace -p local_nodejs:<tarball>` from
   an empty directory under `$RUNNER_TEMP`. Packj's own working directory is npm's project
   root; started from this repository, `npm install` would also install the repository's
   dependencies.
9. Collect Packj's output directory (`/tmp/packj_audit_*`, found through the path Packj
   prints) and the probe report from `<workdir>/node_modules/npm-probing-package/results/`.
10. Validate Packj, the trace and the probe report (Section 4).
11. Write `metadata/experiment.json` and upload all outputs
    (`github-actions-ubuntu-packj-trace-<run_id>-<attempt>`) even when a step fails.

### 3.5 Measurement hygiene

- Packj runs npm with its own environment, which is the step's environment. The workflow
  therefore defines no job-level variables and never writes `$GITHUB_ENV`. Python comes
  from the tool cache rather than `actions/setup-python`, which would export
  `pythonLocation` and related variables. Experiment labels exist only in the metadata step.
- The `y` for Packj's prompt is given on stdin. Packj does not pass its stdin on to npm.
- No synthetic credentials, configuration files, shell history, caches or tools are added.
  The state created before installation is Packj's (`~/.packj.yaml`, its venv and build
  under `$RUNNER_TEMP`) and the apt packages above.
- Packj's output and the probe's report are kept in separate directories. Experiment
  metadata is never inserted into the probe's report.

## 4. Validation: establishing that the probe ran under Packj's trace

Packj's exit status is recorded but not accepted as evidence (gap 1). A run counts as
valid only if three groups of checks pass, 32 in total:

**Packj (10 checks).**
- Packj audited `local_nodejs:<staged tarball>`.
- The trace stage ran and printed `PASS [found … syscalls]`, not `FAIL`.
- `report_*.json` is for that tarball at version 0.1.0, and the HTML summary exists.

**Trace (11 checks).**
- Exactly one non-empty strace log exists, and its first event is the `npm install` execve.
- npm opened the staged tarball. strace's default 32-byte string limit truncates npm's
  argument, so this is matched through the file opens.
- The log contains `execve(…/sh, ["sh","-c","node scripts/postinstall.js"]) = 0` and
  `execve(…/node, ["node","scripts/postinstall.js"])`.
- **The recovered report's file name, which contains a random UUID, appears in the log**
  (`openat` of `<name>.tmp`, `renameat` to `<name>`) inside the installed package. This
  links that specific report to the traced install.
- Packj's parsed summary has process and file syscalls.

**Probe (11 checks).**
- One report was recovered from the package npm installed under Packj.
- Its `phase` and `npm lifecycle event name` are `postinstall`.
- `Package-manager version` = the runner's npm.
- `Own process tracer status = true` (`TracerPid ≠ 0`).
- The ancestor chain contains `strace` followed by Packj's `python3.10`.

Negative cases were tested: a trace stage reporting `FAIL`, a missing trace log, and an
untraced probe report each fail validation.

## 5. Results of the reference run (37590896326)

All 32 checks passed. Packj exited 0. The whole job took 42 s.

**Packj's view of the package.**

| Stage | Result |
| --- | --- |
| Metadata checks | mostly `FAIL`/`N/A` for a local package: no release history, author, downloads or repository; CVE check "not supported for local_nodejs" |
| Static analysis | `no perms found`; 27 files (24 `.js`), **0 functions**, 3,461 LoC |
| Trace stage | `PASS [found 23 process, 197 files, 11 network syscalls]` |
| Risks reported | *suspicious*: "inconsistent with repo source: repo does not exist"; *undesirable*: "noisy package: dummy/empty or troll package" |

- **Static analysis.** Packj's JavaScript analyzer (the Python `esprima` 4.0.1 port) found
  no functions in the probe, probably because it does not parse ES modules or top-level
  `await`. It then classified the probe as a "dummy/empty or troll package". Its static
  analysis therefore saw none of the probe's behavior.
- **Network syscalls.** The 11 "network syscalls" in Packj's summary are not internet
  traffic: a `NETLINK_ROUTE` socket (the probe enumerating network interfaces), data sent
  on it, and two `connect` attempts to the local `nscd` Unix socket (user lookups). The
  trace (12,666 lines) contains no IP connection.
- **Process tree.** The trace shows npm (`/opt/hostedtoolcache/node/22.23.3/x64/bin/npm`),
  then `sh -c "node scripts/postinstall.js"` (npm searches `PATH` for `sh`: 20 failed
  `execve` attempts before `/usr/bin/sh`), then `node scripts/postinstall.js`.
- **npm's log:** `run npm-probing-package@0.1.0 postinstall { code: 0, signal: null }`.

**What the probe observed under Packj trace**, compared with the baseline (Experiment A
run `37257701116`, same tarball). Only properties that differ are shown, excluding
per-VM noise (uptime, free memory, free disk):

| Property | Baseline | Packj trace |
| --- | --- | --- |
| Own process tracer status | `false` | **`true`** |
| Ancestor process chain | `dash ← node ← bash ← Runner.Worker ← Runner.Listener ← …` | `dash ← node ← `**`strace ← python3.10`**` ← bash ← bash ← Runner.Worker ← …` |
| npm command | `ci` | `install` |
| Ancestor project `package.json` / lockfile / `.git` | present / present / present | absent / absent / absent |
| Ancestor project dependency counts | 1 / 0 | absent |
| User npm log directory file count | 6 | 1 |
| Environment-variable count | 144 | 149 |
| Cgroup current memory usage | 459 MB | 1,287 MB |
| Home top-level files / subdirectories | 4 / 10 | 5 / 11 |
| User cache-directory entry count | absent | 1 |

Same in both conditions (selection): Node.js 22.23.3 at the same setup-node path;
npm 10.9.9; OS, kernel, CPU and cgroup limits; `LD_PRELOAD` absent; no container
indicators; 188 vs 189 properties with status `ok`.

## 6. Signals that distinguish the Packj trace environment

- **Tracing is directly visible:** `TracerPid ≠ 0`, and `strace` appears in the ancestor
  chain immediately above npm.
- **The analysis tool is visible through ancestry:** `python3.10` (Packj) sits between
  strace and the CI shells. A developer's `npm install` would not run under a Python
  parent and a tracer.
- **Installation context is synthetic:** an empty project directory (no `package.json`,
  lockfile or `.git` above the package), a direct `npm install <tarball>`, and a fresh npm
  log directory.
- **Side effects of the analysis tool:** the home directory gains `~/.packj.yaml`, and
  `~/.cache` gains pip's cache from installing Packj. Memory in use is higher (Packj's
  Python process).
- **What does not change:** the OS, kernel, cgroups, file-system visibility, CI
  variables and network are those of the plain runner. Trace mode observes but does not
  isolate, so everything visible in the baseline stays visible.

## 7. Threats to validity and limitations

- **Patched to analyze a local package.** Packj at the pinned commit cannot trace a local
  package at all (gap 2). P1–P4 make the trace stage install the probe tarball with the
  npm command Packj uses for registry packages. npm's command line therefore shows a
  tarball path, not `name@version`. Everything after install-command construction is
  upstream.
- **Different npm invocation from the baseline.** Packj runs `npm install <tarball>` in an
  empty directory; the baseline runs `npm ci` in a project. Project-context properties
  (ancestor `package.json`, lockfile, `.git`, npm command) differ by design of the two
  conditions, not because of tracing.
- **Packj's own flags.** `--silent --no-progress --no-update-notifier` come from Packj.
  npm exports non-default configuration to lifecycle scripts as `npm_config_*` variables,
  which may explain part of the higher environment-variable count. The probe records only
  the count, so this is not confirmed.
- **Python 3.10 from the tool cache.** The exact patch version follows the runner image
  (3.10.21 in the reference run). Packj's direct dependencies are upstream's pins.
  Transitive ones are pinned by this study.
- **Static analysis did not parse the probe.** Packj's audit report reflects metadata
  checks and the trace, not code analysis. This is an upstream limitation, recorded but
  not worked around.
- **Single run, one VM.** Results come from one reference run (six successful runs in
  total). Volatile properties (uptime, memory, CPU model) vary between GitHub VMs and
  need repeated runs before any stability claim.

## 8. Reproducibility record

| Item | Value (reference run) |
| --- | --- |
| Runner label / image / OS / kernel | `ubuntu-24.04` / `ubuntu24` 20260927.320.1 / Ubuntu 24.04.5 LTS / 6.17.0-1022-azure, x86_64 |
| strace | 6.8 |
| Packj commit / version | `dfd2c70c4b6dde0327888d62fa7d3df0661d0dfc` / 0.15 |
| Packj mode / command | `audit --trace` / `python3 main.py audit --debug --trace -p local_nodejs:/home/runner/work/_temp/packj-input/npm-probing-package-0.1.0.tgz` |
| Patch | `experiments/packj/patches/packj-local-nodejs-trace.patch`, sha256 `0e89dfb9…e2e226` |
| Python | 3.10.21 (venv; `metadata/packj-pip-freeze.txt`) |
| Node.js / npm | v22.23.3 / 10.9.9 |
| Probe | npm-probing-package 0.1.0, tarball sha256 `8ba84a1e7145dd5024380a9177cd24939591c0822b06afb37568f661ea084ba4` |
| Repository commit | `394b68426f5036d40a6034f873640b835956a088` |
| Run | GitHub Actions run `37590896326`, attempt 1, 2026-10-07 |
| Outputs | artifact `github-actions-ubuntu-packj-trace-37590896326-1` |

Full per-run metadata is in `metadata/experiment.json` in each artifact.

## 9. Draft methods paragraph

> To observe the install-time environment presented by an open-source package-auditing
> tool, we ran Packj (commit dfd2c70, version 0.15) in its dynamic-analysis mode
> (`audit --trace`) on a GitHub-hosted Ubuntu 24.04 runner. In this mode, Packj installs
> the package with `npm install` under `strace -f` (network, file and process system
> calls) and summarizes the trace. Because the published code cannot trace an
> unpublished local package, we added the missing `npm install` command for local
> packages (the command Packj uses for registry packages), let the local-package handler
> read a tarball, and fixed a bug that aborted audits of packages without a repository
> field. Tracing, parsing and reporting were unchanged. Packj installed the same probe
> tarball used in the baseline condition, with the runner's Node.js 22 and npm 10. Packj
> reports success even when its trace stage fails. A run was therefore accepted only if:
> (i) Packj's trace stage reported success for that tarball; (ii) the strace log
> contained the probe's postinstall execution and the creation of that specific report
> (identified by its random file name); and (iii) the probe report recorded the runner's
> npm, an active tracer, and strace under Packj's Python process in its ancestry.
