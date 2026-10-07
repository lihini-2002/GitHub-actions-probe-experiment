# GitHub Ubuntu VM + Packj sandbox

Workflow: [`.github/workflows/github-actions-ubuntu-packj-sandbox.yml`](../../.github/workflows/github-actions-ubuntu-packj-sandbox.yml)
("Environment Probe - GitHub Ubuntu + Packj Sandbox", manual `workflow_dispatch`).

```text
Normal (probe.yml)        Packj trace (…-packj-trace.yml)        Packj sandbox (this directory)
ubuntu-24.04 VM           ubuntu-24.04 VM                         ubuntu-24.04 VM (no job container)
→ npm                     → packj audit --trace                   → packj sandbox npm install <tarball>
→ probe postinstall       → strace -f npm install <tarball>       → Packj strace 5.19 + LD_PRELOAD libsbox.so
                          → probe postinstall (traced)            → npm install, writes redirected to a COW layer
                                                                  → probe postinstall under the sandbox rules
```

All three install `packages/npm-probing-package-0.1.0.tgz`. This workflow never runs
`audit --trace`. The two Packj modes are separate runs.

## Pinned sources (shared with the trace experiment)

| Component | Pin |
| --- | --- |
| Packj | `tools/packj` @ `dfd2c70c4b6dde0327888d62fa7d3df0661d0dfc` (0.15), **same commit as the trace experiment** |
| Packj install | `experiments/packj/install-packj.sh` + `requirements-lock.txt`, unchanged and shared. Its patch (`experiments/packj/patches/packj-local-nodejs-trace.patch`) touches only `packj/audit/`; nothing on the sandbox code path. |
| Sandbox strace | built by Packj's `packj/sandbox/install.sh` from strace tag `v5.19` (`9b00bd51c9040931803c6d6d1718a0faef7d7d59`, checked) |
| `sandbox.o` | upstream's prebuilt x86-64 object (closed source); sha256 recorded |
| Python | newest 3.10.x from the runner tool cache, as in the trace experiment |
| Node.js | 22.23.3 `linux-x64` from nodejs.org, sha256 `df450af8…02de` (same pin as `latch-probe.yml`), unpacked under `/usr/local/lib/nodejs` |

## How Packj's sandbox works (upstream code at the pinned commit)

`python3 main.py sandbox <pm_tool> install <args…>` (`packj/options.py`, `packj/sandbox/main.py`):

1. **Policy.** `sandbox.rules` from `.packj.yaml` (cwd, else `~/.packj.yaml`) is turned into a
   rules profile. Filesystem `block` becomes `hide`, network `block` becomes `kill`. Domains are
   resolved to IPs, and the system DNS servers are added as `allow`.
2. **Run.** It sets `LD_PRELOAD=<sandbox>/libsbox.so`, `LD_LIBRARY_PATH=<sandbox>`,
   `SANDBOX_ROOT=/tmp/packj_sandbox_*/root_*`, `SANDBOX_RULES=<profile>` in its own environment
   and runs
   `<sandbox>/strace -fc --quiet=attach,personality -o <dir>/trace_*.log <pm_tool> install <args…>`.
   `libsbox.so` (from `sandbox.o`) hooks strace's syscall entry/exit and rewrites path arguments
   so writes land in the copy-on-write layer. It hides paths outside the allow list and kills a
   process that connects to a blocked address (`Attempting to connect … [rule: KILL]`,
   `Killing process`). Events go to `root_*.csv` (`open,…` and `connect,…,ALLOW|BLOCK|LOG`).
3. **Exit codes.** If the command exits non-zero, or the event log is missing, Packj prints
   `Failed: <strace stderr or "installation error (N)">!` and exits **1**, keeping the layer. On
   success, the strace/npm output is captured and **not** printed.
4. **Review.** It prints network connections (with ALLOW/BLOCK) and the filesystem changes in the
   layer, then asks `[C]ommit all changes, [Q|q]uit & discard changes, [L|l]ist details`. `C`
   copies new files to the host ("actually install"). Either way it then deletes the layer and
   exits **0**.

There is no npm-specific policy. `.packj.yaml` has one `sandbox.rules` block for every package
manager. The default:

```yaml
fs:
  block: ~/, /
  allow: ., ~/.cache, ~/.npm, ~/.local, ~/.ruby, /tmp, /proc, /etc, /var, /bin, /usr/include,
         /usr/local, /usr/bin, /usr/lib, /usr/share, /lib
network:
  block: 0.0.0.0
  allow: pythonhosted.org:443, pypi.org:443, rubygems.org:443, npmjs.org:0, npmjs.com:0
```

**This experiment uses that policy unchanged.** The workflow checks that the loaded file is
byte-identical to `tools/packj/.packj.yaml`, and that the generated profile hides `/` and `~/`.

## The command

```bash
cd $RUNNER_TEMP/packj-sandbox-work            # empty dir: npm project root and the policy's "."
PATH=/usr/local/lib/nodejs/node-v22.23.3-linux-x64/bin:$PATH \
  $RUNNER_TEMP/packj-build/venv/bin/python $RUNNER_TEMP/packj-build/packj/main.py \
  sandbox npm install /tmp/packj-sandbox-input/npm-probing-package-0.1.0.tgz
# then, at Packj's review prompt:  C
```

Local tarballs are supported as they are: `install_args` is passed to npm verbatim
(`npm install /tmp/…/npm-probing-package-0.1.0.tgz`). No Packj change is needed for that. The
npm command is the plain documented form, without the quiet flags Packj's trace mode adds.

## Choices forced by the default policy (not policy changes)

- **Tarball in `/tmp`**: `$RUNNER_TEMP` is under `~/`, which the policy hides. `/tmp` is allowed.
- **Node.js under `/usr/local`**: `actions/setup-node` installs to `/opt/hostedtoolcache`, which
  the policy hides, so npm/node themselves would be invisible inside the sandbox. Allowing `/opt`
  would weaken the policy. Instead, the same pinned Node 22 as the LATCH experiment is unpacked
  under `/usr/local/lib/nodejs` (allowed) and put first on `PATH` for the Packj command only,
  the same way setup-node prepends its directory in Experiment A. The probe sees a different
  Node path from Experiments A and trace, and Node 22.23.3 instead of setup-node's current 22.x.
- **Working directory**: an empty directory under `$RUNNER_TEMP`. It is the policy's `.` and the
  npm project root, as in the trace experiment.
- **Review answer `C`**: the prompt is answered through a FIFO. Before answering, the run script
  copies the copy-on-write layer, because Packj deletes it afterwards and the probe's report is
  written there. `C` is upstream's "commit = actually install" step.

## Compatibility patches

Two, both in the **build** of Packj's sandbox tool. `build-sandbox.sh` applies them to the
exported copy; `tools/packj` is never edited. Neither touches `sandbox/main.py`, the code in
`sandbox.o`, or the policy.

### 1. `patches/packj-sandbox-strace-bundled-headers.patch`

| | |
| --- | --- |
| **Problem** | Packj's `install.sh` builds strace **v5.19** (2022). On Ubuntu 24.04 (GCC 13.3, `linux-libc-dev` 6.8) it fails with `Failed to build strace`. The real error, kept by rerunning the same steps: `xlat/btrfs_key_types.h:167: error: 'BTRFS_EXTENT_REF_V0_KEY' undeclared`. Kernel 6.x headers removed that constant. strace's configure defaults to `--enable-bundled=check`, which picks the system headers when they are newer than 5.19. |
| **Change** | One flag on install.sh's strace `configure` line: `--enable-bundled=yes`. strace is then compiled against the Linux UAPI headers bundled in its own 5.19 source tree, which define the constant (`bundled/linux/include/uapi/linux/btrfs_tree.h`). |
| **Not changed** | strace version/source, `sandbox/main.py`, `sandbox.o`, the policy, the run command. |
| **Effect on the probe** | None expected on what the sandbox enforces. The headers only decide how strace *decodes* syscall arguments for display (constant names, struct layouts). Interception, path rewriting and kills come from ptrace and `sandbox.o`. Newer kernel features unknown to the 5.19 headers would be decoded as raw numbers, as they would be by any strace 5.19 build. |

### 2. `patches/packj-sandbox-syscall-table-pad.patch`

Found from the first two GitHub runs (37591778929, 37593610922) and `diagnose-sandbox-crash.sh`.

| | |
| --- | --- |
| **Problem** | With patch 1 only, Packj printed `Failed: installation error (-11)!`: its strace died of SIGSEGV as soon as npm ran. The kernel logged a general-protection fault in `libc.so.6` (`__getdelim`). gdb: `__getdelim (lineptr=tcp, …)` ← `syscall_entering_finish` (`sandbox.o` `main.c:90`) ← strace `trace_syscall`. Disassembly of `sandbox.o`: `packj_syscall_enter` and `packj_syscall_exit` do `handler = table[tcp->scno]; if (handler) handler(tcp)`, where the table (`sandbox.o`'s `.data.rel.ro`) has 346 entries (0xad0 bytes) and there is **no bounds check**. Every x86-64 syscall added since (`clone3` 435, `close_range` 436, `openat2` 437, `faccessat2` 439, `futex_waitv` 449, `fchmodat2` 452, …) reads past the table. In the linked `libsbox.so` the table is followed by `.dynamic`, `.got` and `.got.plt` (same layout with Ubuntu 22.04's ld 2.38, upstream's Dockerfile base, and 24.04's ld 2.42), so those syscalls jump through a libc pointer with strace's `tcp` as argument. This is a latent upstream bug that modern glibc/Node trigger. |
| **Change** | A new 14-line `table-pad.s` emits 8192 zero bytes in `.data.rel.ro` (and a non-executable-stack note, like `sandbox.o`), and the Makefile links it directly after `sandbox.o` (`OBJS := sandbox.o table-pad.o`). Table lookups for syscalls 346–1369 then read NULL, which the blob itself treats as "no handler". `build-sandbox.sh` checks that `libsbox.so`'s `.data.rel.ro` is 0xad0 + 8192 bytes. |
| **Not changed** | `sandbox.o`'s code and its 346 table entries (94 handlers), `main.py`, the policy, strace. |
| **Effect on the probe** | Syscalls ≥ 346 are passed through **without Packj interposition**, as Packj already does for the 252 syscalls below 346 that it has no handler for. Packj does not rewrite or hide paths given to `openat2`, `faccessat2` or `fchmodat2`, and does not see `clone3`. Without the patch, the first such syscall crashes strace, and npm then runs entirely outside the sandbox (outcome `sandbox_failed_package_ran_outside`). Node's `fs.access`/`fs.stat`/`open` use `access`/`statx`/`openat` (21/332/257), which remain interposed. |

Local tarballs needed no patch (see "The command"). The trace experiment's patch
(`experiments/packj/patches/…`) is still applied by the shared install script, but it changes only
`packj/audit/` files, which the sandbox command does not import.

## Outcomes

`verify-sandbox-run.sh classify` writes `metadata/outcome.json`:

| Outcome | Meaning | Workflow |
| --- | --- | --- |
| `probe_completed_under_sandbox` | sandbox active, postinstall ran, probe JSON recovered from the sandbox layer, no Packj block recorded | pass |
| `sandbox_blocked_probe_behavior` | sandbox active, postinstall attempted, Packj recorded blocks (`,BLOCK` events, kills, "not allowed"); probe JSON preserved if written | pass |
| `sandbox_prevented_lifecycle` | Packj worked but the postinstall never started (e.g. npm killed by a network rule) | fail, labelled as **not** an infrastructure failure |
| `probe_checks_failed` / `lifecycle_not_reached_unexplained` | lifecycle evidence without a passing probe report and no recorded block, or no lifecycle and no block | fail |
| `sandbox_failed_package_ran_outside` | Packj's sandbox failed (e.g. its strace died) and npm went on to install the probe **on the host, unconfined**. That report is kept in `probe-outside-sandbox/`, never in `probe/` | fail |
| `infrastructure_failure` | Packj's sandbox did not start (no sandbox dir, profile, event log, or strace summary) | fail |

Filesystem `hide` rules are not logged by Packj. Their effect shows up only in the probe's own
statuses (`absent`, `permission_denied`, …), which are counted in `probe_status_counts`.

## Artifact: `github-actions-ubuntu-packj-sandbox-<run_id>-<run_attempt>`

```text
probe/install-<uuid>.json                 probe report, copied from the sandbox layer
probe/partial/install-<uuid>.json.tmp     only if the report was started but not completed
probe-outside-sandbox/                    only if Packj failed but npm still ran the probe on the host
packj/diagnostics/                        only after a failure: diagnose-sandbox-crash.sh output
packj/sandbox.log                         Packj console output (review summary, Failed: …)
packj/activity/root_*.csv                 Packj sandbox event log (open/connect, ALLOW/BLOCK)
packj/activity/trace_*.log                Packj's strace -fc syscall summary
packj/activity/sandbox-root.tar.gz        the copy-on-write layer (everything written during install)
packj/activity/sandbox-root-files.txt     its file list with sizes
packj/policy/packj.yaml                   policy file Packj loaded (= upstream .packj.yaml)
packj/policy/rules_*.profile              rules profile Packj generated and used
packj/policy/expected-rules.profile       the same, generated before the run (CLI check)
packj/logs/run-paths.json                 paths, review answer, exit status
packj/logs/packj-exit-status.txt          Packj exit status
packj/logs/npm-logs/                      npm debug logs from the sandbox layer
packj/logs/npm-work-package*.json         package.json / lock npm wrote in the layer
packj/logs/sandbox-dir-listing.txt        /tmp/packj_sandbox_* listing before cleanup
packj/logs/packj-install.log, sandbox-build.log, packj-sandbox-help.txt
metadata/github-host.txt, experiment.json, outcome.json, packj-pip-freeze.txt, checks/*.json
```

## Telling a sandboxed install from ordinary npm

1. **Copy-on-write layer.** `probe/install-<uuid>.json` was found in `sandbox-root.tar.gz` at
   `<workdir>/node_modules/npm-probing-package/results/`, i.e. libsbox redirected the probe's write.
   Ordinary npm writes to the host path.
2. **The probe saw Packj's mechanism.** `Own process tracer status` = `true`, and ancestors
   containing `strace` then `python3.10` (run 3: `dash, node, strace, python3.10, bash, …`).
   `LD_PRELOAD variable presence` is **`false`**: Packj sets it for its strace, but the variable
   does not reach the traced npm/probe (`sandbox.o` references `unsetenv` and `LD_PRELOAD`).
3. **Packj's own records.** `root_*.csv` lists the install's files and connections, and
   `rules_*.profile` is the policy in force.
4. **npm's own log** (inside the layer) shows `run npm-probing-package@0.1.0 postinstall …` and
   its `{ code: …, signal: … }` result.

## What the probe can observe that is due to Packj, not the experiment

Being ptraced by Packj's strace 5.19 (`LD_PRELOAD` is set for that strace but was not visible to
the probe; whether `LD_LIBRARY_PATH`, `SANDBOX_ROOT` or `SANDBOX_RULES` reach it is not something
the probe records); hidden paths (everything outside the allow list, including
`~/` apart from `~/.npm`/`~/.cache`/`~/.local`/`~/.ruby`, `/opt`, `/home/runner/work`, `/sys`,
`/dev`, `/run`, `/mnt`); redirected writes; network kills; stdin closed by Packj.

Due to the experiment setup: the Node location (`/usr/local/lib/nodejs/…` first on `PATH`), the
staged tarball in `/tmp`, `~/.packj.yaml`, and the build tools installed with apt (`strace`,
`libmagic1t64`, `autoconf automake build-essential gawk`).

## Testing status

`sandbox.o` is x86-64 only, and ptrace does not work under the amd64 emulation available on the
machine this was written on. Packj's sandbox could therefore **not** be run locally. What was tested:

- the CLI parsing and the generated default rules profile (real Packj code);
- the run/verify/classify scripts, against a stub reproducing Packj's observable protocol
  (sandbox dir layout, review prompt, layer deletion), for all four outcome paths;
- the sandbox build (`install.sh`) in an emulated Ubuntu 24.04 x86-64 container (see above).

The first GitHub run is the first real execution of the sandbox.
