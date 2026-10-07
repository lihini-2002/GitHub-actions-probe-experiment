# Integrating Packj sandbox mode into a GitHub Actions Ubuntu VM

How Packj's sandboxed installation mode (`packj sandbox`) was run on a GitHub-hosted
Ubuntu runner, so that the environment-probing package could be installed under Packj's
sandbox and compared with a plain-npm install and with Packj's trace mode on the same kind
of runner. Written as source material for the methods, results and threats-to-validity
sections of the paper.

Implementation: `.github/workflows/github-actions-ubuntu-packj-sandbox.yml` and
`experiments/packj-sandbox/` (the technical README there lists every file and patch).
Reference run: GitHub Actions run `37619271727`, 2026-10-07, all checks passed.
Packj's trace mode is a separate condition, described in
`packj-trace-github-actions-integration.md`.

---

## 1. Purpose and study design

The study measures which environmental properties an npm package can observe during
installation, across different execution environments. Besides auditing, Packj offers a
"lightweight sandbox" for installing packages. It interposes on system calls with strace,
redirects file writes into a copy-on-write layer, hides paths outside an allow list, and
kills processes that connect to blocked addresses. The question for this condition:
**what does a package see when it is installed inside Packj's sandbox?**

Three conditions run on the same host type with the same probe artifact:

| | Experiment A: baseline | Packj trace | Packj sandbox |
| --- | --- | --- | --- |
| Workflow | `probe.yml` | `…-packj-trace.yml` | `…-packj-sandbox.yml` |
| Host | GitHub `ubuntu-24.04` VM | same | same |
| Mechanism | none | `strace -f` (observe only) | Packj's strace 5.19 + `libsbox.so` (interpose, rewrite, hide, kill) |
| npm invocation | `npm ci` in a project | `npm install --silent … <tarball>` in an empty dir | `npm install <tarball>` in an empty dir |
| Node.js / npm | 22.23.3 / 10.9.9 (setup-node, `/opt`) | 22.23.3 / 10.9.9 (setup-node, `/opt`) | 22.23.3 / 10.9.9 (nodejs.org tarball, `/usr/local`) |
| Packj | — | 0.15 @ `dfd2c70` | 0.15 @ `dfd2c70` (same build) |
| Output | probe JSON | probe JSON + trace + audit report | probe JSON + sandbox events + copy-on-write layer + policy |

The probe is a benign package whose `postinstall` hook records 200 catalogued
environment properties into `install-<uuid>.json`. It reports only the presence of
credential-like variables and files, never their contents, and it does not change
behavior based on what it finds. Its only active operations are reading `/proc` and
`/sys`, listing directories, and creating and deleting one temporary file. It makes no
network connections.

## 2. Packj sandbox as published

Packj repository `ossillate-inc/packj` at commit `dfd2c70` (version 0.15), the same
commit as the trace condition. The command is
`python3 main.py sandbox <pm_tool> install <args…>`. From `packj/sandbox/main.py`:

```text
policy: sandbox.rules in .packj.yaml → rules profile
        (fs "block" → hide, network "block" → kill; domains resolved to IPs; DNS servers allowed)
→ LD_PRELOAD=libsbox.so, SANDBOX_ROOT=/tmp/packj_sandbox_*/root_*, SANDBOX_RULES=<profile>
→ <sandbox>/strace -fc --quiet=attach,personality -o <dir>/trace_*.log npm install <args…>
     libsbox.so hooks strace's syscall entry/exit: rewrites paths into the copy-on-write layer,
     hides paths outside the allow list, kills processes connecting to blocked addresses,
     logs events to root_*.csv
→ review: network connections (ALLOW/BLOCK) and filesystem changes in the layer
→ prompt "[C]ommit all changes, [Q|q]uit & discard changes, [L|l]ist details"
→ on C, new files are copied to the host; the layer is then deleted
```

`libsbox.so` is linked from **`sandbox.o`, a prebuilt, closed-source x86-64 object**
("we are not ready to open source this small piece yet", per the sandbox README). Packj's
`install.sh` builds the strace it hooks: strace **v5.19** (2022) from source, as a
library plus executable. The sandbox is install-time only. It is not a container: the
process tree, kernel and environment are the host's.

There is one policy for all package managers, in `.packj.yaml`. The default, used
unchanged here:

```yaml
fs:
  block: ~/, /
  allow: ., ~/.cache, ~/.npm, ~/.local, ~/.ruby, /tmp, /proc, /etc, /var, /bin,
         /usr/include, /usr/local, /usr/bin, /usr/lib, /usr/share, /lib
network:
  block: 0.0.0.0
  allow: pythonhosted.org:443, pypi.org:443, rubygems.org:443, npmjs.org:0, npmjs.com:0
```

Local packages need no change: `install_args` is passed to npm verbatim, so
`sandbox npm install /path/to/package.tgz` works as documented.

### Problems found on a current runner

1. **The sandbox tool does not build.** On Ubuntu 24.04 (GCC 13.3, kernel headers 6.8),
   `install.sh` fails with `Failed to build strace`. The cause, found by rerunning its steps
   with the build tree kept: `xlat/btrfs_key_types.h:167: error:
   'BTRFS_EXTENT_REF_V0_KEY' undeclared`. Kernel 6.x headers dropped that constant, and
   strace's configure (`--enable-bundled=check`) uses the system headers whenever they are
   newer than its own.
2. **The sandbox crashes as soon as npm runs.** With the build fixed (first reference
   attempt, run `37591778929`), Packj printed `Failed: installation error (-11)!`: its strace
   died of SIGSEGV. Diagnosis (run `37593610922`):
   - the kernel logged a general-protection fault in `libc.so.6` (`__getdelim`);
   - gdb showed `__getdelim(lineptr=tcp, …)` ← `syscall_entering_finish` (`sandbox.o`,
     `main.c:90`) ← strace `trace_syscall`;
   - disassembly of `sandbox.o`: `packj_syscall_enter` and `packj_syscall_exit` do
     `handler = table[tcp->scno]; if (handler) handler(tcp)` on a **346-entry table with no
     bounds check**;
   - every newer x86-64 syscall (`clone3` 435, `close_range` 436, `openat2` 437,
     `faccessat2` 439, `fchmodat2` 452, …) reads past the table into `.dynamic`, `.got` and
     `.got.plt`, and jumps through a libc pointer.

   Linking `sandbox.o` with Ubuntu 22.04's ld (upstream's Dockerfile base) gives the same
   layout, so this is a latent upstream bug. A current glibc and Node 22 trigger it:
   Packj's own syscall summary of a working run counts 21 `clone3` calls.
3. **When the sandbox crashes, the package runs unconfined.** In run `37591778929` the
   probe still produced a report, on the host. The tracer had died and its tracees were
   detached, so npm finished the install outside the sandbox. That report shows
   `TracerPid = 0` and the ancestor chain `dash ← node ← systemd` (npm reparented to
   init). It also shows full visibility: 160 processes and 5 files in the home directory.
   Packj printed only the failure message and exited 1. For a user, a crashed sandbox is
   therefore not a blocked install: an install script would still run with full access.

## 3. Reproduction on GitHub Actions

### 3.1 Environment stack

```text
L1  GitHub-hosted VM     ubuntu-24.04 (Ubuntu 24.04.5 LTS, kernel 6.17.0-1022-azure, x86_64), no job container
L2  Packj                0.15 @ dfd2c70, Python 3.10 venv, same build as the trace condition
L3  Sandbox tracer       Packj's strace 5.19 (built by install.sh) + LD_PRELOAD libsbox.so (sandbox.o)
L4  Sandbox layer        copy-on-write root /tmp/packj_sandbox_*/root_*, default .packj.yaml policy
L5  npm                  npm 10.9.9 on Node.js 22.23.3 under /usr/local/lib/nodejs
L6  Package              npm-probing-package 0.1.0, postinstall hook
```

### 3.2 Source pinning

| Component | Pin |
| --- | --- |
| Packj | `ossillate-inc/packj@dfd2c70c4b6dde0327888d62fa7d3df0661d0dfc` (submodule `tools/packj`), **same commit and install script as the trace condition** |
| Sandbox strace | tag `v5.19`, commit `9b00bd51c9040931803c6d6d1718a0faef7d7d59` (cloned by `install.sh`; the commit is checked) |
| `sandbox.o` | upstream object, sha256 `a73d6940…80ecd4` |
| Policy | upstream `.packj.yaml`, sha256 `25a60f59…423066`; checked byte-identical every run |
| Python | newest 3.10.x in the runner tool cache (3.10.22 in the reference run) |
| Node.js | 22.23.3 `linux-x64` from nodejs.org, sha256-verified (same pin as the LATCH condition) |

The trace condition's patch is applied by the shared install script but changes only
`packj/audit/`, which `packj sandbox` does not import.

### 3.3 Adaptations

| # | Change | Reason | Effect on Packj semantics |
| --- | --- | --- | --- |
| S1 | `install.sh` configures strace with `--enable-bundled=yes`: it is built against the Linux UAPI headers shipped in strace 5.19's own source tree. | Problem 1. With Ubuntu 22.04's 5.15 headers (upstream's Dockerfile), the default `check` already selects the bundled headers, so this restores upstream's effective configuration. | None on enforcement. Headers only affect how strace decodes arguments for display. |
| S2 | `libsbox.so` is linked with 8,192 zero bytes directly after `sandbox.o`'s handler table (a 14-line `table-pad.s` plus one Makefile line). | Problem 2. Lookups for syscalls 346–1369 then read NULL, which the blob treats as "no handler". The build checks the table size and that the stack stays non-executable. | **Syscalls ≥ 346 pass through without Packj interposition**, as do the 252 lower-numbered syscalls Packj has no handler for. Paths given to `openat2`, `faccessat2` and `fchmodat2` are not rewritten or hidden. Node's `access`, `statx` and `openat` (21, 332, 257) are still interposed. Without S2, the first such syscall crashes the sandbox and the package runs outside it (problem 3). |
| S3 | Node.js 22.23.3 unpacked under `/usr/local/lib/nodejs` and put first on `PATH` for the Packj command only. | The default policy hides `/opt`, where `actions/setup-node` installs Node, so npm would be invisible inside the sandbox. Allowing `/opt` would weaken the policy. `/usr/local` is allowed. | None on Packj. The probe sees a different Node path from the other conditions; the version is the same. |
| S4 | The probe tarball is staged in `/tmp`. | `$RUNNER_TEMP` is under `~/`, which the policy hides. | None. |
| S5 | Packj's review prompt is answered `C` through a named pipe, after the copy-on-write layer has been archived. | Packj is interactive and deletes the layer after the prompt. The layer holds what the install wrote, including the probe's report. `C` is upstream's "actually install" step. | None. The archive is a read-only copy taken after npm has finished. |
| S6 | Python 3.10, venv, `libmagic1t64`, no Ruby gems; `autoconf automake build-essential gawk` for the strace build. | As in the trace condition, plus the sandbox README's build prerequisites. | None. |

No sandbox rule was added, removed or relaxed. `sandbox/main.py` and the code in
`sandbox.o` are upstream's.

### 3.4 Execution procedure

The workflow (`workflow_dispatch`) runs these steps, each as a separately reported step:

1. Check out the repository; fetch and verify the pinned Packj submodule (same commit as
   the trace condition).
2. Record host metadata; **prerequisite check:** the system strace can trace `/bin/echo`.
3. Install Packj (shared script). Build the sandbox tool with S1 and S2, then check the
   strace commit, the built files, the handler-table size and the stack flag.
4. Print the Packj version, commit and binary hashes; verify the sandbox CLI. Packj's own
   strace must trace `/bin/echo`, and the profile generated from the default policy must
   hide `/`.
5. Install the pinned Node.js under `/usr/local/lib/nodejs` (S3).
6. Locate and validate the probe tarball (the file the baseline installs).
7. From an empty directory under `$RUNNER_TEMP`, run
   `python3 main.py sandbox npm install /tmp/packj-sandbox-input/npm-probing-package-0.1.0.tgz`.
   When the review prompt appears, archive the sandbox directory, then answer `C`.
8. Validate the sandbox, the install and the probe report, and classify the outcome
   (Section 4).
9. Only after a failure, and after the probe has run: reproduce Packj's sandboxed strace
   on simple commands and collect kernel fault records and a gdb backtrace.
10. Write `metadata/experiment.json` and upload all outputs
    (`github-actions-ubuntu-packj-sandbox-<run_id>-<attempt>`) even when a step fails.

### 3.5 Measurement hygiene

- As in the other conditions: no job-level variables, nothing written to `$GITHUB_ENV`
  or `$GITHUB_PATH`, Python from the tool cache, and experiment labels only in the
  metadata step. The only variable change for the Packj process is the Node directory
  prepended to `PATH`. This mirrors what setup-node does in the baseline.
- The policy is upstream's default, unmodified. The workflow does not make the probe
  succeed by relaxing rules. Blocked operations would be recorded, not removed.
- Packj's `audit --trace` is never run in this workflow. The two Packj modes are separate
  runs.
- No synthetic credentials, configuration files, shell history, caches or tools are
  added. Packj's output, the archived layer and the probe's report are kept in separate
  directories.

## 4. Validation and outcome classification

Packj's exit status is recorded but not accepted as evidence. Three check groups (29
checks) run, and an outcome is assigned from them:

**Sandbox (12 checks).**
- Packj created its sandbox directory and loaded the unmodified upstream policy.
- The generated profile hides `~/` and `/`, allows `.`, and kills `0.0.0.0`.
- No setup error was printed.
- The event log (`root_*.csv`) and Packj's strace summary (`trace_*.log`) are non-empty.
- The copy-on-write layer was captured.

**Install (6 checks).**
- npm wrote `npm-probing-package@0.1.0` **into the layer, not the host**, and the event
  log records its files.
- npm's own log (inside the layer) records the postinstall starting.
- Packj reached its review.

**Probe (11 checks).**
- One report was recovered **from inside the layer**, at
  `<workdir>/node_modules/npm-probing-package/results/`. Only the sandbox's path
  rewriting puts it there.
- It is valid, from the probe, with phase and lifecycle event `postinstall`.
- It records the npm version used.
- `Own process tracer status = true`.
- The ancestor chain has `strace` followed by Packj's `python3.10`.

Outcomes:

| Outcome | Meaning |
| --- | --- |
| `probe_completed_under_sandbox` | sandbox active, postinstall ran, report recovered from the layer, no Packj block recorded |
| `sandbox_blocked_probe_behavior` | sandbox active, postinstall attempted, Packj recorded blocks (`BLOCK` events, kills, "not allowed"); any report kept |
| `sandbox_prevented_lifecycle` | Packj worked but the postinstall never started |
| `sandbox_failed_package_ran_outside` | the sandbox failed and npm installed the probe on the host (report kept apart, never counted as sandbox data) |
| `infrastructure_failure` | the sandbox never started |

Packj does not log filesystem `hide` decisions. Their effect is measured through the
probe's own statuses.

## 5. Results of the reference run (37619271727)

Outcome **`probe_completed_under_sandbox`**: all 29 checks passed, and Packj exited 0.
The postinstall finished with `{ code: 0, signal: null }`. The whole job took about 2 min,
mostly building strace.

**Packj's view of the install.**

| Record | Content |
| --- | --- |
| Review: network connections | none (no `connect` syscall at all in Packj's summary) |
| Review: filesystem changes | new `node_modules/` (35 files, 233 KB), `package.json`, `package-lock.json` in the work directory; `~/.npm/` (16 files); 483 files of Node 22's compile cache in `/tmp/node-compile-cache/` |
| Event log | 518 entries, all `open` (file creations), matching the 518 files in the layer, including `results/install-19be54d4-…json` (23,050 bytes) |
| Blocks | 0 network `BLOCK` events, 0 kills, 0 "not allowed" messages |
| Syscall summary (`strace -fc`) | 30,119 syscalls, 5,999 errors. Most frequent: `futex` 6,457; `statx` 8,986 (4,381 failed); `openat` 2,253 (769 failed); `rename` 485; `clone3` 21; `execve` 24 (20 failed: npm's `PATH` search for `sh`) |

The sandbox therefore classified the probe's install as harmless: no network activity,
and writes only inside the project, npm's cache and `/tmp`. The default policy blocked
nothing that Packj logs.

**What the probe observed in the sandbox**, compared with the baseline (Experiment A run
`37257701116`) and Packj trace (run `37590896326`), all with the same tarball. Per-VM
noise (uptime, CPU model, free memory and disk) is excluded:

| Property | Baseline | Packj trace | Packj sandbox |
| --- | --- | --- | --- |
| Own process tracer status | `false` | `true` | `true` |
| Ancestor chain (inner part) | `dash ← node ← bash ← Runner.Worker` | `dash ← node ← strace ← python3.10 ← bash` | `dash ← node ← strace ← python3.10 ← bash` |
| Visible process count (`/proc` listing) | 157 | 160 | **0** |
| Analysis-tool process matches | (list) | (list) | **empty** |
| Cgroup controllers / limits / usage (`/sys/fs/cgroup`) | present | present | **absent** (8 properties) |
| Home top-level files / subdirectories | 4 / 10 | 5 / 11 | **0 / 3** |
| User configuration directory (`~/.config`) | present | present | **absent** |
| User cache-directory entry count | absent | 1 | 0 |
| `PATH` entries that do not exist | 12 | 12 | **19** |
| Node.js / npm prefix path template | `/opt/…` | `/opt/…` | `/usr/local/…` |
| npm command | `ci` | `install` | `install` |
| Ancestor project `package.json` / lockfile / `.git` | present | absent | absent |
| `LD_PRELOAD` present | `false` | `false` | `false` |
| Environment-variable count | 144 | 149 | 148 |
| Properties with status `ok` / `absent` | 189 / 9 | 188 / 10 | 180 / 19 |

**Directory listings come from the copy-on-write layer.** The probe's home directory
showed exactly what the layer's `/home/runner` contains: three directories (`.cache`,
`.npm`, `work`) and no files. Its `/proc` listing was empty, like the layer's empty
`/proc` mirror. Reads of existing files are not affected: the probe read
`/proc/self/status` (hence `TracerPid`), `/etc/os-release` and its own package files
normally. Paths outside the allow list, such as `/sys`, `~/.config`, `/opt` and `/snap`,
do not exist from inside the sandbox. That explains the eight missing cgroup properties and the seven
extra nonexistent `PATH` entries.

**`LD_PRELOAD` is not visible.** Packj sets `LD_PRELOAD=libsbox.so` for its strace, but
the probe saw no `LD_PRELOAD`. `sandbox.o` references `unsetenv` and the string
`LD_PRELOAD`, which suggests it removes the variable before the traced program starts.

## 6. Signals that distinguish the Packj sandbox environment

- **Tracing is directly visible**, as in trace mode: `TracerPid ≠ 0`, and
  `strace ← python3.10` in the ancestor chain.
- **The visible filesystem is inconsistent:**
  - `/proc` lists no processes, yet `/proc/self` is readable;
  - the home directory lists only `.cache`, `.npm` and `work`, with no dotfiles at all;
  - `/sys` does not exist;
  - seven directories on `PATH` (e.g. `/opt/…`, `/snap/bin`) are missing.

  No real Linux system looks like this, and a package can test it cheaply.
- **Cgroup information is missing** while the kernel is a current Azure kernel, a
  combination unusual outside sandboxes.
- **Installation context is synthetic**, as in trace mode: an empty project, a direct
  `npm install <tarball>`, a fresh npm log directory.
- **Network policy did not fire** for this package. With no connections attempted, the
  probe cannot tell from the network side that it is sandboxed. A package that did
  connect to a non-allowed address would have its process killed.

## 7. Threats to validity and limitations

- **Two compatibility patches to the sandbox build (S1, S2).** S1 restores upstream's
  effective header configuration. S2 changes behavior only for syscalls that crash the
  unpatched sandbox. It makes them pass through un-interposed rather than crash, which
  leaves the sandbox somewhat weaker than its authors may have intended for those
  syscalls (`openat2`, `faccessat2`, `fchmodat2`). Without S2 no sandboxed observation
  is possible on this runner: the sandbox fails and the package runs outside it.
- **Closed-source component.** `sandbox.o`'s behavior was inferred from its symbols, its
  disassembly and its effects. Its exact rules (e.g. how listings and hidden paths are
  served) may be more complex than observed with this one package.
- **Node location differs (S3).** The baseline and trace conditions use setup-node's
  `/opt/hostedtoolcache`; the sandbox condition uses `/usr/local/lib/nodejs`, because the
  default policy hides `/opt`. The Node and npm versions are the same.
- **npm invocation differs** from the baseline (`npm install <tarball>` in an empty
  directory versus `npm ci` in a project). It also differs from trace mode, which adds
  Packj's quiet flags. Project-context properties differ by design.
- **Commit step.** Answering `C` is the documented way to complete an install. The
  probe's report is taken from the layer before the commit. The probe runs before the
  prompt, so answering `Q` would not change what it observed.
- **Escaped installs depend on strace's detach behavior.** The unconfined run in problem 3
  was observed once, before S2. It shows what happens when the sandbox's tracer dies; it
  is not part of the sandbox measurements.
- **Single package behavior.** The probe triggers no network rule and no write outside
  allowed paths. Packj's enforcement against such behavior was therefore not exercised
  by this package.
- **Single run, one VM.** Results come from one reference run (five successful runs in
  total). Volatile properties vary between GitHub VMs. The reference run landed on an
  AMD EPYC 7763 host; the baseline and trace runs landed on EPYC 9V45 hosts.

## 8. Reproducibility record

| Item | Value (reference run) |
| --- | --- |
| Runner label / image / OS / kernel | `ubuntu-24.04` / `ubuntu24` 20261004.327.1 / Ubuntu 24.04.5 LTS / 6.17.0-1022-azure, x86_64 |
| System strace (prerequisite check only) | 6.8 |
| Packj commit / version | `dfd2c70c4b6dde0327888d62fa7d3df0661d0dfc` / 0.15 |
| Packj mode / command | `sandbox` / `python3 main.py sandbox npm install /tmp/packj-sandbox-input/npm-probing-package-0.1.0.tgz`, review answer `C` |
| Policy | upstream `.packj.yaml`, sha256 `25a60f59add50814a24def44894878e14ab927dbc0643ad41d8fe719f0423066`; generated profile in `packj/policy/` |
| Sandbox strace | 5.19, source commit `9b00bd51c9040931803c6d6d1718a0faef7d7d59` |
| `sandbox.o` / `libsbox.so` sha256 | `a73d6940b9137825ee29321029b3db44dc3e54128f4f08d6022dfceb2e80ecd4` / `332eca9d84749fc40698150e9106b77f65b3a2206344c0f4568f3f6d53cdd85e` |
| Patches | `packj-sandbox-strace-bundled-headers.patch` (`887351e4…54ff34`), `packj-sandbox-syscall-table-pad.patch` (`e1ffcf6a…80f230`) |
| Python | 3.10.22 (venv; `metadata/packj-pip-freeze.txt`) |
| Node.js / npm | v22.23.3 at `/usr/local/lib/nodejs/node-v22.23.3-linux-x64` / 10.9.9 |
| Probe | npm-probing-package 0.1.0, tarball sha256 `8ba84a1e7145dd5024380a9177cd24939591c0822b06afb37568f661ea084ba4` |
| Repository commit | `29b86b43e06aa56c050f8059c0cf7d8fccd714d0` |
| Run | GitHub Actions run `37619271727`, attempt 1, 2026-10-07 |
| Outputs | artifact `github-actions-ubuntu-packj-sandbox-37619271727-1` |
| Earlier runs | `37591778929` (sandbox crash, probe ran outside the sandbox), `37593610922` (crash diagnostics), `37600732144` (validation-script errors, fixed) |

Full per-run metadata is in `metadata/experiment.json` and `metadata/outcome.json` in each
artifact.

## 9. Draft methods paragraph

> To observe the install-time environment presented by a sandboxing package installer, we
> ran Packj's sandbox mode (commit dfd2c70, version 0.15, the same build as our Packj
> trace condition) on a GitHub-hosted Ubuntu 24.04 runner, with Packj's default policy
> unchanged. Packj's sandbox runs the package manager under its own build of strace 5.19
> and a preloaded, closed-source interposition library. The library redirects writes into
> a copy-on-write layer, hides paths outside an allow list, and kills processes that
> connect to blocked addresses. On the current runner, two compatibility changes were
> needed. We built strace against the kernel headers bundled in its own source tree, as
> upstream's Ubuntu 22.04 environment effectively did. We also linked zero padding after
> the interposition library's syscall handler table: the library indexes the table by
> syscall number without a bounds check, and every syscall added after the table was
> written (e.g. `clone3`) crashed the sandbox. With the padding, such syscalls pass
> through un-interposed, as Packj already does for syscalls it has no handler for.
> Without the padding, the sandbox crashed and npm completed the installation outside it.
> Because Packj's default policy hides `/opt`, Node.js 22 was installed under
> `/usr/local` rather than with setup-node. The same probe tarball used in the other
> conditions was installed with `packj sandbox npm install <tarball>`. A run was accepted
> only if:
> (i) the unmodified policy was in force and Packj's event log and syscall summary were
> produced;
> (ii) npm installed the probe into Packj's copy-on-write layer and logged its
> postinstall; and
> (iii) the probe's report was found inside that layer and recorded an active tracer,
> with strace under Packj's Python process in its ancestry.
