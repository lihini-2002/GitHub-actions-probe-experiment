# GitHub Ubuntu VM + Packj `audit --trace`

Workflow: [`.github/workflows/github-actions-ubuntu-packj-trace.yml`](../../.github/workflows/github-actions-ubuntu-packj-trace.yml)
("Environment Probe - GitHub Ubuntu + Packj Trace", manual `workflow_dispatch`).

```text
Experiment A (probe.yml)                This experiment
GitHub ubuntu-24.04 VM                  GitHub ubuntu-24.04 VM (no job container)
→ npm (setup-node 22)                   → Packj 0.15 (Python 3.10 venv)
→ npm-probing-package-0.1.0.tgz         → packj audit --trace
→ postinstall                           → strace -f … npm install <tarball>   (npm from setup-node 22)
→ install-<uuid>.json                   → npm-probing-package-0.1.0.tgz
                                        → postinstall, traced
                                        → install-<uuid>.json + Packj trace/audit output
```

Both install the same tarball, `packages/npm-probing-package-0.1.0.tgz`, and the probe
writes its report with its default mechanism (`results/` inside the installed package).
Packj's sandbox mode (`packj sandbox …`) is not used. Nothing here changes the other
experiments.

## Pinned sources

| Component | Where | Pin |
| --- | --- | --- |
| Packj | `tools/packj` (submodule) | `ossillate-inc/packj@dfd2c70c4b6dde0327888d62fa7d3df0661d0dfc` (main, 2026-09-17; `__version__ = "0.15"`) |
| Packj Python deps | `requirements-lock.txt` | upstream `requirements.txt` pins plus all transitive deps, resolved on Python 3.10 |
| Python | runner tool cache | newest `3.10.x` in `$RUNNER_TOOL_CACHE/Python`, exact version recorded |
| Node.js / npm | `actions/setup-node@v4`, `node-version: "22"` | same as Experiment A; exact versions recorded |
| strace | Ubuntu 24.04 apt | version recorded |

The workflow fails if `tools/packj` is not at the pinned commit.

## How `audit --trace` works (upstream code)

`python3 main.py audit --trace -p <pm>:<pkg>` → `packj/audit/main.py`:

1. `parse_request_args` creates a report directory `tempfile.mkdtemp(prefix='packj_audit_')`
   (`/tmp/packj_audit_*` on the runner). Outside Docker/Podman, `--trace` first asks
   `Continue (N/y)` on stdin.
2. `audit()` runs metadata checks, then static analysis (`analyze_apis`, `analyze_composition`)
   on the package archive.
3. `trace_installation()` builds the install command with `pm_util.get_pm_install_cmd` and runs
   `strace -f -e trace=network,file,process -ttt -T -o <report_dir>/trace_*.log <install command>`
   from Packj's own working directory, then parses the log into `<report_dir>/summary_*.json`.
4. `report.py` writes `report_*.json` (per package) and `report_*.html` (summary).

**Every failure inside a stage is caught and printed as `FAIL [...]`, and Packj still exits 0.**
A run where the trace failed looks like a successful audit from the exit status alone.

## Targeting a local tarball: the limitation

The probe is not on npm (`https://registry.npmjs.org/npm-probing-package` returns 404).

- `npm:<name>` fetches metadata from the hard-coded `https://registry.npmjs.org`, so the audit
  stops at `package not found!` and the trace never runs. It would also be unsafe: if anyone
  later published that name, Packj would install their package. The probe is **not** published.
- `local_nodejs:<path>` (documented for local packages) accepts only a directory, and at the
  pinned commit it cannot trace at all. Tested against unmodified upstream with the extracted
  probe directory:
  - the audit aborts with exit 1 in `analyze_repo_url` (`local variable 'repo_url' referenced
    before assignment`) because the probe has no `repository` field;
  - with only that fixed, the trace stage prints
    `Installing package and tracing code.....FAIL [Package manager local_nodejs is not supported]`,
    Packj exits 0, and nothing is installed (`get_pm_install_cmd` has no `local_nodejs` branch).

## Workaround: `patches/packj-local-nodejs-trace.patch`

`install-packj.sh` exports `tools/packj` with `git archive` and applies this patch to the
exported copy. Upstream files in `tools/` are never edited.

| # | Change | File | Why |
| --- | --- | --- | --- |
| P1 | `get_pm_install_cmd` gets a `local_nodejs` branch: `npm install --silent --no-progress --no-update-notifier <path>`, the npm branch's exact command without the `@<version>` suffix. | `packj/audit/pm_util.py` | Without it, `--trace` cannot install a local package. |
| P2 | `local_nodejs` accepts a `.tgz` file: `package.json` and `README.md` are read from `package/` inside the tarball. | `packj/audit/pm_proxy/local_nodejs.py` | A directory would make npm create a symlink and run the postinstall in the source directory instead of `node_modules/` (`install-links=false`). A tarball is installed exactly as in Experiment A and LATCH. |
| P3 | `audit()` uses a local `.tgz` as the analysis file instead of trying to download it. | `packj/audit/main.py` | So static analysis runs on the same tarball that is installed. |
| P4 | `analyze_repo_url` initialises `repo_url = None`. | `packj/audit/main.py` | Upstream bug: it aborts the audit for any package without a `repository` field. |

Nothing in the trace itself changes: the strace command, its flags, the trace parser and the
report writers are upstream's. P1 only supplies the npm command line that upstream's npm
branch would use.

**Could the patch change what the probe observes?** P2–P4 run in Packj's Python process
before the install and are not visible to npm. P1 decides the npm command line. It installs a
tarball path instead of `name@version`, which changes npm's argv (the probe can see its parent
process). The flags are upstream's.

## Running it

GitHub → **Actions** → **Environment Probe - GitHub Ubuntu + Packj Trace** → **Run workflow**
(the workflow file must be on the default branch), or:

```bash
gh workflow run github-actions-ubuntu-packj-trace.yml --ref main
```

Command executed (from an empty working directory, `$RUNNER_TEMP/packj-work`):

```bash
printf 'y\n' | $RUNNER_TEMP/packj-build/venv/bin/python $RUNNER_TEMP/packj-build/packj/main.py \
  audit --debug --trace -p local_nodejs:$RUNNER_TEMP/packj-input/npm-probing-package-0.1.0.tgz
```

which makes Packj run:

```bash
strace -f -e trace=network,file,process -ttt -T -o /tmp/packj_audit_*/trace_*.log \
  npm install --silent --no-progress --no-update-notifier $RUNNER_TEMP/packj-input/npm-probing-package-0.1.0.tgz
```

`--debug` only adds Packj's `debug_*.log`. The `y` answers Packj's "not in Docker/Podman"
prompt. The GitHub VM is the isolation Packj recommends.

## Artifact: `github-actions-ubuntu-packj-trace-<run_id>-<run_attempt>`

```text
probe/install-<uuid>.json              probe report: "what environment did the package observe?"
packj/audit/report_*.json              Packj audit report (risks, permissions, composition)
packj/audit/report_*.html              Packj HTML summary
packj/audit/static/<tgz>.out[.json]    Packj static-analysis intermediates
packj/trace/trace_*.log                raw strace log of the traced npm install: "what did the package do?"
packj/trace/summary_*.json             Packj's parsed syscall summary (process/files/network)
packj/logs/packj-audit.log             Packj console output
packj/logs/debug_*.log                 Packj debug log
packj/logs/packj-exit-status.txt       Packj exit status
packj/logs/run-paths.json              input, npm working dir, report dir, where the probe report was found
packj/logs/npm-work-package*.json      package.json / lock npm created in the working dir
packj/logs/npm-logs/                   npm debug logs from this install
packj/logs/packj-install.log           Packj installation (pip) log
packj/logs/packj-audit-help.txt        `audit --help` of the installed Packj
metadata/github-host.txt               runner/OS/kernel/tool versions
metadata/experiment.json               run metadata and outcome
metadata/packj-pip-freeze.txt          exact Python packages in Packj's venv
metadata/checks/{packj,probe,trace}.json  individual check results
```

The probe report and Packj's output are in separate directories and are never merged.
Experiment labels are only in `metadata/`.

## What counts as a valid run

`metadata/experiment.json` → `outcome.experiment_valid` is true only when all three check
groups (`verify-packj-run.sh`) pass:

- **packj**: Packj audited `local_nodejs:<staged tarball>`; the trace stage ran and printed
  `PASS [found … syscalls]` (not `FAIL`); `report_*.json` is for that tarball at version
  0.1.0; the HTML summary exists. Exit status 0 is recorded but is not enough.
- **trace**: exactly one non-empty `trace_*.log`; its first event is the `npm install` execve;
  npm opened the staged tarball; `sh -c "node scripts/postinstall.js"` and
  `node scripts/postinstall.js` were executed; the recovered `install-<uuid>.json` was
  created and renamed inside `<workdir>/node_modules/npm-probing-package/results/`;
  Packj's `summary_*.json` has process and file syscalls.
- **probe**: exactly one report, recovered from the package npm installed under Packj; phase
  and lifecycle event are `postinstall`; package manager is the runner's npm version.

### Telling a Packj-traced run from ordinary npm

Three independent signals:

1. **The trace contains the report's own creation.** The UUID in `probe/install-<uuid>.json`
   appears in `openat`/`renameat` lines in `packj/trace/trace_*.log`. A report from another
   install would not be there.
2. **The probe saw itself traced**: `properties["Own process tracer status"].value == true`
   (`TracerPid != 0`). Under ordinary npm (Experiment A) it should be `false`; compare with
   that run's report.
3. **The probe's ancestors include Packj**:
   `properties["Bounded ancestor-process executable basename sequence"]` reads like
   `["dash", "node", "strace", "python3.10", "bash", …]`, i.e. sh → npm → strace → Packj.

## Differences from Experiment A that the probe can observe

These come from running Packj as documented. They are not instrumentation added by the
experiment:

- the process is traced by strace, and its ancestors are `strace` and Packj's `python3.10`;
- npm's argv and working directory: `npm install … <tarball>` in a fresh directory, not
  `npm ci` in this repository. Packj installs from its own working directory, which must not be
  this repository: `npm install` there would also install the root `package.json`'s `file:`
  dependency;
- npm config from Packj's flags (`--silent --no-progress --no-update-notifier`); npm 7+ exports
  non-default config to lifecycle scripts as `npm_config_*` variables;
- stdin is a pipe that Packj closes;
- `~/.packj.yaml` exists (Packj's `setup.py` installs it there), and Packj's venv/build is
  under `$RUNNER_TEMP/packj-build`;
- `strace` and `libmagic1t64` are installed with apt (Packj prerequisites);
- no `actions/setup-node` npm cache restore (Experiment A uses `cache: "npm"`).

The workflow adds no job-level `env:`, no `$GITHUB_ENV`/`$GITHUB_PATH` entries, no fake
credentials or files, and no tracing beyond Packj's own strace (the strace self-check traces
only `/bin/echo` and runs before Packj).

## Other notes

- Packj's metadata checks (release history, downloads, CVEs via OSV, repo) are registry
  oriented; for `local_nodejs` most report `FAIL`/`N/A` (e.g. `CVE checking for package manager
  local_nodejs not supported`). That is expected and does not affect the trace.
- Packj's static JavaScript analysis (pypi `esprima` 4.0.1) reports `0 funcs` for the probe,
  probably because it does not parse ES modules/top-level `await`. Packj then flags it as a
  "dummy/empty or troll package". That is an upstream static-analysis limitation and does not
  affect the trace.
- Packj's strace parser prints `unlink failed for …` lines while parsing. They are console noise
  from upstream and not errors.
- Python 3.10, not the runner's 3.12: Packj's pins (`PyYAML==6.0`, `protobuf==3.19.4`,
  `Django==4.1.1`, …) predate 3.12. Upstream's Dockerfile is Ubuntu 22.04 (Python 3.10). Packj's
  `bundle install` (Ruby gems) is skipped because it is only used for Ruby packages.
- `packj --version` exits 1 by design upstream, so the CLI check uses `audit --help` and
  `packj.__version__`.
